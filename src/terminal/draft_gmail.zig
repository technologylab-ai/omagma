//! Explicit Gmail draft operations. Creates stream MIME once; all other
//! operations here are bounded reads. There is no update or delete fallback.
const std = @import("std");
const gmail = @import("gmail.zig");
const t = @import("types.zig");
const j = @import("json.zig");
const b = @import("../bounded.zig");
const oauth = @import("../oauth.zig");
const spool = @import("send_spool.zig");
const Config = @import("../config.zig").Config;

pub const Remote = struct {
    draftId: []const u8,
    messageId: []const u8,
    threadId: []const u8 = "",
    rfcMessageId: []const u8 = "",
};
pub const Reconciled = struct { state: enum { found, not_found, ambiguous }, remote: ?Remote = null };
fn request(transport: gmail.Transport, a: std.mem.Allocator, url: []const u8) !j.Value {
    return transport.requestFn(transport.context, a, .GET, url, null);
}
fn escaped(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len > 4096) return error.InvalidDraftLink;
    const buffer = try a.alloc(u8, value.len * 3);
    var writer: std.Io.Writer = .fixed(buffer);
    try oauth.percent(&writer, value);
    return writer.buffered();
}
fn header(message: j.Value, name: []const u8) ![]const u8 {
    const payload = j.get(message, "payload") orelse return "";
    const values = j.get(payload, "headers") orelse return "";
    if (values != .array or values.array.items.len > 256) return error.InvalidProviderResponse;
    var found: ?[]const u8 = null;
    for (values.array.items) |item| if (std.ascii.eqlIgnoreCase(j.text(item, "name"), name)) {
        if (found != null) return error.InvalidProviderResponse;
        const value = j.text(item, "value");
        if (value.len > 16384) return error.InvalidProviderResponse;
        found = value;
    };
    return found orelse "";
}
pub fn parse(value: j.Value) !Remote {
    const id = try j.required(value, "id");
    const message = j.get(value, "message") orelse return error.InvalidProviderResponse;
    const message_id = try j.required(message, "id");
    try b.identifier(id);
    try b.identifier(message_id);
    const thread = j.text(message, "threadId");
    if (thread.len > 0) try b.identifier(thread);
    return .{ .draftId = id, .messageId = message_id, .threadId = thread, .rfcMessageId = try header(message, "Message-ID") };
}
pub fn status(a: std.mem.Allocator, transport: gmail.Transport, id: []const u8) !?Remote {
    try b.identifier(id);
    const url = try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/drafts/{s}?format=metadata&fields=id,message(id,threadId,payload(headers))", .{try escaped(a, id)});
    const value = request(transport, a, url) catch |err| if (err == error.MessageNotFound) return null else return err;
    const remote = try parse(value);
    if (!std.mem.eql(u8, id, remote.draftId)) return error.MessageIdentityMismatch;
    return remote;
}
pub fn reconcile(a: std.mem.Allocator, transport: gmail.Transport, attempt: []const u8) !Reconciled {
    if (!@import("mime.zig").validMessageId(attempt) or attempt.len > 128) return error.InvalidDraftLink;
    const query = try std.fmt.allocPrint(a, "rfc822msgid:{s}", .{attempt});
    const url = try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/drafts?maxResults=5&q={s}&fields=drafts(id),nextPageToken", .{try escaped(a, query)});
    const result = try request(transport, a, url);
    if (j.text(result, "nextPageToken").len > 0) return .{ .state = .ambiguous };
    const drafts = j.get(result, "drafts") orelse return .{ .state = .not_found };
    if (drafts != .array or drafts.array.items.len > 5) return error.InvalidProviderResponse;
    var selected: ?Remote = null;
    for (drafts.array.items) |candidate| {
        const remote = try status(a, transport, try j.required(candidate, "id")) orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, remote.rfcMessageId, " \t"), attempt)) continue;
        if (selected != null) return .{ .state = .ambiguous };
        selected = remote;
    }
    return if (selected) |remote| .{ .state = .found, .remote = remote } else .{ .state = .not_found };
}
pub const Session = struct {
    native: gmail.NetworkSession,
    pub fn init(self: *Session, io: std.Io, a: std.mem.Allocator, temporary: std.mem.Allocator, config: *const Config, account: []const u8, input: j.Value) !void {
        try self.native.initRequiringAnyCapabilityWithAllocator(io, a, temporary, config, account, "mail.read", input, &.{ "mail-drafts", "mail-modify" });
    }
    pub fn close(self: *Session) void {
        self.native.close();
    }
    pub fn transport(self: *Session) gmail.Transport {
        return self.native.transport();
    }
    pub fn validateSender(self: *Session, a: std.mem.Allocator, draft: t.Draft) !void {
        const transport_value = self.transport();
        if (draft.from) |from| if (!std.ascii.eqlIgnoreCase(from.address, self.native.verified_account)) {
            const identities = try gmail.dispatchAuthorized(self.native.io, a, self.native.verified_account, self.native.capabilities, transport_value, "accounts.identities", try j.value(a, .{}));
            const values = j.get(identities, "identities") orelse return error.UnverifiedSender;
            if (values != .array) return error.InvalidProviderResponse;
            var verified = false;
            for (values.array.items) |identity| verified = verified or std.ascii.eqlIgnoreCase(j.text(identity, "address"), from.address);
            if (!verified) return error.UnverifiedSender;
        };
        if (draft.threadId.len > 0) {
            try b.identifier(draft.threadId);
            if (!@import("mime.zig").validMessageId(draft.inReplyTo)) return error.MissingMessageId;
        }
    }
    pub fn create(self: *Session, a: std.mem.Allocator, draft: t.Draft, source: *const spool.Spool) !Remote {
        const boundary = try std.fmt.allocPrint(a, "omagma-draft-upload-{s}", .{source.hash});
        const metadata = try j.encodeAlloc(a, .{ .message = .{ .threadId = if (draft.threadId.len > 0) draft.threadId else @as(?[]const u8, null) } }, .{ .emit_null_optional_fields = false });
        const prefix = try std.fmt.allocPrint(a, "--{s}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{s}\r\n--{s}\r\nContent-Type: message/rfc822\r\n\r\n", .{ boundary, metadata, boundary });
        const suffix = try std.fmt.allocPrint(a, "\r\n--{s}--\r\n", .{boundary});
        const content_type = try std.fmt.allocPrint(a, "multipart/related; boundary=\"{s}\"", .{boundary});
        var reader = try source.reader();
        defer reader.close();
        var body: Multipart = .{ .reader = &reader, .prefix = prefix, .suffix = suffix };
        const url = "https://gmail.googleapis.com/upload/gmail/v1/users/me/drafts?uploadType=multipart&fields=id,message(id,threadId)";
        const response = self.native.client.requestTerminalFile(url, .POST, self.native.network.access, content_type, .{ .ctx = &body, .readFn = Multipart.read }, prefix.len + source.size + suffix.len, self.native.response) catch return error.UnknownOutcome;
        if (response.status == 401) self.native.invalidateAccess();
        const value = try gmail.decodeResponse(a, .POST, url, response.status, response.body);
        return parse(value) catch return error.UnknownOutcome;
    }
};
const Multipart = struct {
    reader: *spool.Spool.Reader,
    prefix: []const u8,
    suffix: []const u8,
    prefix_offset: usize = 0,
    suffix_offset: usize = 0,
    body_done: bool = false,
    fn read(context: *anyopaque, bytes: []u8) !usize {
        const self: *Multipart = @ptrCast(@alignCast(context));
        if (bytes.len == 0) return 0;
        if (self.prefix_offset < self.prefix.len) {
            const count = @min(bytes.len, self.prefix.len - self.prefix_offset);
            @memcpy(bytes[0..count], self.prefix[self.prefix_offset..][0..count]);
            self.prefix_offset += count;
            return count;
        }
        if (!self.body_done) {
            const count = try spool.Spool.Reader.read(self.reader, bytes);
            if (count > 0) return count;
            self.body_done = true;
        }
        const count = @min(bytes.len, self.suffix.len - self.suffix_offset);
        @memcpy(bytes[0..count], self.suffix[self.suffix_offset..][0..count]);
        self.suffix_offset += count;
        return count;
    }
};

test "Gmail draft transport: reconciliation never creates and search absence remains uncertain" {
    const Oracle = struct {
        mode: enum { lag, one, duplicate, rewritten, missing } = .lag,
        requests: usize = 0,
        fn call(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.requests += 1;
            try std.testing.expectEqual(std.http.Method.GET, method);
            try std.testing.expect(body == null);
            if (std.mem.indexOf(u8, url, "drafts?maxResults=5") != null) {
                try std.testing.expect(std.mem.indexOf(u8, url, "rfc822msgid") != null);
                if (self.mode == .lag) return j.value(a, .{});
                if (self.mode == .duplicate) return j.value(a, .{ .drafts = .{ .{ .id = "remote-1" }, .{ .id = "remote-2" } } });
                return j.value(a, .{ .drafts = .{.{ .id = "remote-1" }} });
            }
            try std.testing.expect(std.mem.indexOf(u8, url, "format=metadata") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "format=raw") == null);
            if (self.mode == .missing) return error.MessageNotFound;
            return j.value(a, .{ .id = if (std.mem.indexOf(u8, url, "/remote-2?") != null) @as([]const u8, "remote-2") else "remote-1", .message = .{ .id = "version-1", .threadId = "thread", .payload = .{ .headers = .{.{ .name = "Message-ID", .value = if (self.mode == .rewritten) @as([]const u8, "<rewritten@example.test>") else "<owned-attempt@mail.invalid>" }} } } });
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var oracle: Oracle = .{};
    const wire: gmail.Transport = .{ .context = &oracle, .requestFn = Oracle.call };
    const a = arena.allocator();
    try std.testing.expectEqual(.not_found, (try reconcile(a, wire, "<owned-attempt@mail.invalid>")).state);
    oracle.mode = .one;
    const found = try reconcile(a, wire, "<owned-attempt@mail.invalid>");
    try std.testing.expectEqual(.found, found.state);
    try std.testing.expectEqualStrings("remote-1", found.remote.?.draftId);
    oracle.mode = .duplicate;
    try std.testing.expectEqual(.ambiguous, (try reconcile(a, wire, "<owned-attempt@mail.invalid>")).state);
    oracle.mode = .rewritten;
    try std.testing.expectEqual(.not_found, (try reconcile(a, wire, "<owned-attempt@mail.invalid>")).state);
    oracle.mode = .missing;
    try std.testing.expect((try status(a, wire, "remote-1")) == null);
}
