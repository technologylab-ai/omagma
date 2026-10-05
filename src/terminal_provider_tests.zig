const std = @import("std");
const gmail = @import("terminal/gmail.zig");
const auth = @import("terminal/auth.zig");
const j = @import("terminal/json.zig");
const mime = @import("terminal/mime.zig");

test {
    std.testing.refAllDecls(gmail);
    std.testing.refAllDecls(auth);
}

const Fake = struct {
    calls: usize = 0,
    send_raw: []const u8 = "",
    sent_thread: []const u8 = "",
    unknown: bool = false,
    bad_receipt: bool = false,
    patched: bool = false,
    listing: bool = false,
    fn transport(self: *Fake) gmail.Transport {
        return .{ .context = self, .requestFn = request };
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.listing and std.mem.indexOf(u8, url, "/messages?maxResults=") != null) {
            try std.testing.expect(std.mem.indexOf(u8, url, "includeSpamTrash=true") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "labelIds=TRASH") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "q=") == null);
            const Entry = struct { id: []const u8, threadId: []const u8 };
            const entries = try a.alloc(Entry, 33);
            for (entries, 0..) |*entry, index| entry.* = .{ .id = try std.fmt.allocPrint(a, "metadata-{d}", .{index}), .threadId = "thread-1" };
            return j.value(a, .{ .messages = entries, .nextPageToken = "opaque/+==" });
        }
        if (self.listing and std.mem.indexOf(u8, url, "?format=metadata&") != null) {
            try std.testing.expectEqual(std.http.Method.GET, method);
            const begin = std.mem.indexOf(u8, url, "/messages/").? + "/messages/".len;
            const end = std.mem.indexOfScalarPos(u8, url, begin, '?').?;
            return j.value(a, .{ .id = url[begin..end], .threadId = "thread-1", .internalDate = "42", .payload = .{ .headers = .{ .{ .name = "From", .value = "Sender <sender@example.test>" }, .{ .name = "Subject", .value = "Metadata only" } } } });
        }
        if (std.mem.endsWith(u8, url, "/messages/send")) {
            try std.testing.expectEqual(std.http.Method.POST, method);
            self.send_raw = try mime.decodeBase64Url(try j.required(body.?, "raw"), a);
            self.sent_thread = j.text(body.?, "threadId");
            if (self.unknown) return error.UnknownOutcome;
            return if (self.bad_receipt) j.value(a, .{ .accepted = true }) else j.value(a, .{ .id = "sent-42", .threadId = "thread-42" });
        }
        if (std.mem.indexOf(u8, url, "/settings/sendAs?") != null) return j.value(a, .{ .sendAs = .{.{ .sendAsEmail = "self@example.test", .verificationStatus = "accepted" }} });
        if (std.mem.indexOf(u8, url, "/people/contact-1:updateContact?") != null) {
            try std.testing.expectEqual(std.http.Method.PATCH, method);
            const sources = body.?.object.get("metadata").?.object.get("sources").?.array.items;
            try std.testing.expectEqualStrings("CONTACT", j.text(sources[0], "type"));
            try std.testing.expectEqualStrings("contact-etag-7", j.text(sources[0], "etag"));
            try std.testing.expectEqualStrings("people/contact-1", j.text(body.?, "resourceName"));
            self.patched = true;
            return j.value(a, .{ .resourceName = "people/contact-1", .names = .{.{ .displayName = "Changed Name" }}, .emailAddresses = .{.{ .value = "changed@example.test" }}, .metadata = .{ .sources = .{.{ .type = "CONTACT", .etag = "contact-etag-8" }} } });
        }
        if (std.mem.indexOf(u8, url, "/people/contact-1?") != null) {
            try std.testing.expectEqual(std.http.Method.GET, method);
            return j.value(a, .{ .resourceName = "people/contact-1", .etag = "person-etag-different", .names = .{.{ .displayName = "Original Name" }}, .emailAddresses = .{.{ .value = "original@example.test" }}, .metadata = .{ .sources = .{.{ .type = "CONTACT", .etag = "contact-etag-7" }} } });
        }
        return error.UnexpectedMockRequest;
    }
};

test "capability rejection precedes transport and readonly cannot mutate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    for ([_][]const u8{ "mail.send", "mail.trash", "mail.archive", "contacts.upsert", "invitation.reply" }) |cmd| {
        try std.testing.expectError(error.PermissionDenied, gmail.dispatchAuthorized(std.testing.io, arena.allocator(), "self@example.test", &.{"mail-read"}, fake.transport(), cmd, .null));
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "send wires explicit thread headers UTF8 body and Bcc recipient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    const req = try j.value(a, .{ .operationId = "send-op-1", .draft = .{ .to = .{.{ .address = "to@example.test" }}, .cc = .{.{ .address = "cc@example.test" }}, .bcc = .{.{ .address = "hidden@example.test" }}, .subject = "Re: café", .bodyText = "Hello 🌋\n", .threadId = "thread-1", .inReplyTo = "<source@example.test>", .references = "<root@example.test> <source@example.test>" } });
    const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "mail-send" }, fake.transport(), "mail.send", req);
    try std.testing.expectEqualStrings("applied", j.text(result, "outcome"));
    try std.testing.expectEqualStrings("sent-42", j.text(result, "messageId"));
    try std.testing.expectEqualStrings("thread-1", fake.sent_thread);
    try std.testing.expect(std.mem.indexOf(u8, fake.send_raw, "From: <self@example.test>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.send_raw, "Bcc: <hidden@example.test>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.send_raw, "In-Reply-To: <source@example.test>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.send_raw, "References:\r\n <root@example.test>\r\n <source@example.test>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.send_raw, "SGVsbG8g8J+Miw0K\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "uncertain and malformed successful sends return stable unknown receipt once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try j.value(a, .{ .operationId = "unknown-op", .draft = .{ .to = .{.{ .address = "to@example.test" }}, .subject = "Synthetic", .bodyText = "Fictional body" } });
    var failed: Fake = .{ .unknown = true };
    const first = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "mail-send" }, failed.transport(), "mail.send", req);
    var malformed: Fake = .{ .bad_receipt = true };
    const second = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "mail-send" }, malformed.transport(), "mail.send", req);
    try std.testing.expectEqualStrings("unknown", j.text(first, "outcome"));
    try std.testing.expectEqualStrings("unknown", j.text(second, "outcome"));
    try std.testing.expectEqualStrings("UnknownOutcome", j.text(first, "errorCode"));
    try std.testing.expectEqualStrings("InvalidProviderReceipt", j.text(second, "errorCode"));
    try std.testing.expectEqualStrings(j.text(first, "rfcMessageId"), j.text(second, "rfcMessageId"));
    try std.testing.expectEqual(@as(usize, 1), failed.calls);
    try std.testing.expectEqual(@as(usize, 1), malformed.calls);
}

test "People updates compare explicit CONTACT source etag before sending mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    const stale = try j.value(a, .{ .expectedEtag = "contact-etag-6", .contact = .{ .resourceName = "people/contact-1", .etag = "contact-etag-7", .name = "Changed Name", .emails = .{.{ .address = "changed@example.test" }} } });
    try std.testing.expectError(error.ContactConflict, gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "contacts-write" }, fake.transport(), "contacts.upsert", stale));
    try std.testing.expect(!fake.patched);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    const fresh = try j.value(a, .{ .expectedEtag = "contact-etag-7", .contact = .{ .resourceName = "people/contact-1", .etag = "ignored-fallback", .name = "Changed Name", .emails = .{.{ .address = "changed@example.test" }} } });
    const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "contacts-write" }, fake.transport(), "contacts.upsert", fresh);
    try std.testing.expect(fake.patched);
    try std.testing.expectEqualStrings("contact-etag-8", j.text(result, "etag"));
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

test "prepared RSVP is sent as exact reviewed iTIP reply with RSVP-only capability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    const calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:meeting-1@example.test\r\nDTSTAMP:20261005T120000Z\r\nSEQUENCE:7\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;PARTSTAT=TENTATIVE:mailto:self@example.test\r\nRECURRENCE-ID;TZID=Europe/Vienna:20261012T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const req = try j.value(a, .{ .operationId = "rsvp-op-1", .preparedCalendar = calendar, .draft = .{ .to = .{.{ .address = "host@example.test" }}, .subject = "tentative: Meeting", .bodyText = "Invitation response: tentative" } });
    const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "calendar-rsvp" }, fake.transport(), "invitation.reply", req);
    try std.testing.expectEqualStrings("applied", j.text(result, "outcome"));
    const parsed = try mime.parse(fake.send_raw, a);
    try std.testing.expectEqualStrings(calendar, parsed.calendar.?);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}
test "live list over thirty retrieves metadata only and passes opaque next cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .listing = true };
    const req = try j.value(a, .{ .limit = 33, .label = "TRASH" });
    const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, fake.transport(), "mail.list", req);
    const messages = result.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 33), messages.len);
    for (messages) |message| try std.testing.expectEqualStrings("", j.text(message, "bodyText"));
    try std.testing.expectEqualStrings("opaque/+==", j.text(result, "nextCursor"));
    try std.testing.expectEqual(@as(usize, 34), fake.calls);
}
test "live contact writes reject the same empty address book input as fixtures before IO" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"contact\":{\"name\":\"No email\",\"emails\":[]}}", .{});
    const req = input.value;
    try std.testing.expectError(error.InvalidContact, gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{ "mail-read", "contacts-write" }, fake.transport(), "contacts.upsert", req));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}
