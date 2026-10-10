const std = @import("std");
const gmail = @import("gmail.zig");
const j = @import("json.zig");
const mime = @import("mime.zig");
const types = @import("types.zig");

const account = "synthetic@example.test";
const full_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1?format=full";
const pptx_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/attachments/ANGjdJ_synthetic_pptx";

/// Independent literal Gmail wire data. Any request other than the listed
/// GETs fails before a response is supplied.
const Peer = struct {
    steps: []const struct { url: []const u8, response: []const u8 },
    calls: usize = 0,
    writes: usize = 0,

    fn transport(self: *Peer) gmail.Transport {
        return .{ .context = self, .requestFn = request };
    }

    fn request(context: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *Peer = @ptrCast(@alignCast(context));
        if (method != .GET) self.writes += 1;
        if (self.calls == self.steps.len) return error.UnexpectedTransportRequest;
        const step = self.steps[self.calls];
        self.calls += 1;
        try std.testing.expectEqual(std.http.Method.GET, method);
        try std.testing.expect(body == null);
        try std.testing.expectEqualStrings(step.url, url);
        return std.json.parseFromSliceLeaky(j.Value, a, step.response, .{});
    }
};

const plain_text = "Hallo,\r\nhier ist der erste Entwurf für die Regeln.\r\nGrüße\r\n";
const pptx_bytes = "PK\x03\x04synthetic-presentation-bytes";

/// Shape of an Outlook message as Gmail returns it: both alternatives were
/// base64 UTF-8 with a byte order mark, so each declares three more bytes
/// than its returned data (62 + 3 and 120 + 3).
fn wire(a: std.mem.Allocator, plain_headers: []const u8, plain_size: usize) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"id":"m1","threadId":"t1","internalDate":"1791651960000","labelIds":["INBOX","UNREAD"],"snippet":"Hallo, hier ist der erste Entwurf","sizeEstimate":114736,
        \\"payload":{{"partId":"","mimeType":"multipart/mixed","filename":"","headers":[
        \\{{"name":"From","value":"Synthetic Sender <sender@example.test>"}},{{"name":"To","value":"synthetic@example.test"}},
        \\{{"name":"Subject","value":"Synthetic implementation rules"}},{{"name":"Date","value":"Sat, 10 Oct 2026 17:06:00 +0200"}},
        \\{{"name":"Message-ID","value":"<synthetic-bom@example.test>"}},{{"name":"Content-Type","value":"multipart/mixed; boundary=\"_mixed_\""}}],
        \\"body":{{"size":0}},"parts":[
        \\{{"partId":"0","mimeType":"multipart/alternative","filename":"","headers":[{{"name":"Content-Type","value":"multipart/alternative; boundary=\"_alt_\""}}],"body":{{"size":0}},"parts":[
        \\{{"partId":"0.0","mimeType":"text/plain","filename":"","headers":{s},"body":{{"size":{d},"data":"SGFsbG8sDQpoaWVyIGlzdCBkZXIgZXJzdGUgRW50d3VyZiBmw7xyIGRpZSBSZWdlbG4uDQpHcsO8w59lDQo"}}}},
        \\{{"partId":"0.1","mimeType":"text/html","filename":"","headers":[{{"name":"Content-Type","value":"text/html; charset=\"utf-8\""}},{{"name":"Content-Transfer-Encoding","value":"base64"}}],"body":{{"size":123,"data":"PGRpdj48cD5IYWxsbywgaGllciBpc3QgZGVyIGVyc3RlIEVudHd1cmYgZiZ1dW1sO3IgZGllIFJlZ2Vsbi48L3A-PGltZyBzcmM9ImNpZDppbWFnZTAwMS5wbmdAMDFEQzAwMDAuMDAwMDAwMDAiPjwvZGl2Pg0K"}}}}]}},
        \\{{"partId":"1","mimeType":"image/png","filename":"image001.png","headers":[{{"name":"Content-Type","value":"image/png; name=\"image001.png\""}},{{"name":"Content-Description","value":"image001.png"}},{{"name":"Content-Disposition","value":"inline; filename=\"image001.png\"; size=17"}},{{"name":"Content-ID","value":"<image001.png@01DC0000.00000000>"}},{{"name":"Content-Transfer-Encoding","value":"base64"}}],"body":{{"attachmentId":"ANGjdJ_synthetic_png","size":17}}}},
        \\{{"partId":"2","mimeType":"application/vnd.openxmlformats-officedocument.presentationml.presentation","filename":"Shared implementation rules.pptx","headers":[{{"name":"Content-Type","value":"application/vnd.openxmlformats-officedocument.presentationml.presentation; name=\"Shared implementation rules.pptx\""}},{{"name":"Content-Disposition","value":"attachment; filename=\"Shared implementation rules.pptx\"; size=32"}},{{"name":"Content-Transfer-Encoding","value":"base64"}}],"body":{{"attachmentId":"ANGjdJ_synthetic_pptx","size":32}}}}]}}}}
    , .{ plain_headers, plain_size });
}

const utf8_base64 = "[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=\\\"utf-8\\\"\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}]";

test "live message body: Gmail byte order mark sizes keep the reader and its attachments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = try wire(a, utf8_base64, plain_text.len + 3) }} };
    const result = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-read"}, peer.transport(), "mail.read", try j.value(a, .{ .messageId = "m1" }));
    try std.testing.expectEqual(@as(usize, 1), peer.calls);
    try std.testing.expectEqual(@as(usize, 0), peer.writes);
    const message = try j.decode(types.Message, a, result);
    try std.testing.expectEqualStrings("m1", message.id);
    try std.testing.expectEqualStrings("plain", @tagName(message.bodySource));
    try std.testing.expect(std.mem.indexOf(u8, message.bodyText, "erste Entwurf für die Regeln.") != null);
    try std.testing.expect(std.mem.indexOf(u8, message.bodyHtml.?, "erste Entwurf") != null);
    try std.testing.expectEqual(@as(usize, 2), message.attachments.len);
    const image = message.attachments[0];
    try std.testing.expectEqualStrings("image001.png", image.filename);
    try std.testing.expectEqualStrings("ANGjdJ_synthetic_png", image.id);
    try std.testing.expectEqualStrings("inline", image.disposition.?);
    try std.testing.expectEqual(@as(usize, 17), image.size);
    const pptx = message.attachments[1];
    try std.testing.expectEqualStrings("Shared implementation rules.pptx", pptx.filename);
    try std.testing.expectEqualStrings("application/vnd.openxmlformats-officedocument.presentationml.presentation", pptx.mimeType);
    try std.testing.expectEqualStrings("ANGjdJ_synthetic_pptx", pptx.id);
    try std.testing.expectEqualStrings("attachment", pptx.disposition.?);
    try std.testing.expectEqual(pptx_bytes.len, pptx.size);
    try std.testing.expectEqualStrings("", pptx.data);

    // The listed attachment downloads with its exact byte count.
    var download: Peer = .{ .steps = &.{.{ .url = pptx_url, .response = "{\"size\":32,\"data\":\"UEsDBHN5bnRoZXRpYy1wcmVzZW50YXRpb24tYnl0ZXM=\"}" }} };
    const saved = try gmail.attachmentAuthorized(a, account, &.{"mail-read"}, download.transport(), "m1", pptx);
    try std.testing.expectEqual(@as(usize, 1), download.calls);
    try std.testing.expectEqual(@as(usize, 0), download.writes);
    try std.testing.expectEqualStrings(pptx_bytes, try mime.decodeBase64Url(saved.data, a));
}

test "live message body: other short inline text stays an explicit refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { headers: []const u8, size: usize };
    for ([_]Case{
        // Two or four missing bytes cannot be a stripped byte order mark.
        .{ .headers = utf8_base64, .size = plain_text.len + 2 },
        .{ .headers = utf8_base64, .size = plain_text.len + 4 },
        // Exactly three missing bytes outside the observed base64 UTF-8 shape.
        .{ .headers = "[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=utf-8\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"quoted-printable\"}]", .size = plain_text.len + 3 },
        .{ .headers = "[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=windows-1252\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}]", .size = plain_text.len + 3 },
        .{ .headers = "[]", .size = plain_text.len + 3 },
    }) |case| {
        var peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = try wire(a, case.headers, case.size) }} };
        try std.testing.expectError(error.BodySizeMismatch, gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-read"}, peer.transport(), "mail.read", try j.value(a, .{ .messageId = "m1" })));
        try std.testing.expectEqual(@as(usize, 1), peer.calls);
        try std.testing.expectEqual(@as(usize, 0), peer.writes);
    }
}

const calendar_full_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/c1?format=full";
const calendar_ics_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/c1/attachments/ANGjdJ_synthetic_ics";
/// Outlook shape: inline REQUEST (SEQUENCE 3) alternative, a named external
/// invite.ics carrying SEQUENCE 4, and an ordinary named PDF.
const calendar_wire =
    \\{"id":"c1","threadId":"c1","internalDate":"1791651960000","labelIds":["INBOX"],"snippet":"Agenda attached.",
    \\"payload":{"mimeType":"multipart/mixed","filename":"","headers":[
    \\{"name":"From","value":"Synthetic Organizer <organizer@example.test>"},{"name":"To","value":"synthetic@example.test"},
    \\{"name":"Subject","value":"Synthetic planning"},{"name":"Message-ID","value":"<synthetic-calendar@example.test>"}],
    \\"body":{"size":0},"parts":[
    \\{"partId":"0","mimeType":"multipart/alternative","filename":"","headers":[],"body":{"size":0},"parts":[
    \\{"partId":"0.0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=utf-8"}],"body":{"size":18,"data":"QWdlbmRhIGF0dGFjaGVkLg0K"}},
    \\{"partId":"0.1","mimeType":"text/calendar","filename":"","headers":[{"name":"Content-Type","value":"text/calendar; charset=utf-8; method=REQUEST"}],"body":{"size":243,"data":"QkVHSU46VkNBTEVOREFSDQpWRVJTSU9OOjIuMA0KTUVUSE9EOlJFUVVFU1QNCkJFR0lOOlZFVkVOVA0KVUlEOnBsYW5uaW5nQGV4YW1wbGUudGVzdA0KU0VRVUVOQ0U6Mw0KRFRTVEFSVDoyMDI2MTAxMlQwODAwMDBaDQpPUkdBTklaRVI6bWFpbHRvOm9yZ2FuaXplckBleGFtcGxlLnRlc3QNCkFUVEVOREVFO1JTVlA9VFJVRTptYWlsdG86c3ludGhldGljQGV4YW1wbGUudGVzdA0KRU5EOlZFVkVOVA0KRU5EOlZDQUxFTkRBUg0K"}}]},
    \\{"partId":"1","mimeType":"application/octet-stream","filename":"invite.ics","headers":[{"name":"Content-Disposition","value":"attachment; filename=\"invite.ics\""}],"body":{"attachmentId":"ANGjdJ_synthetic_ics","size":243}},
    \\{"partId":"2","mimeType":"application/pdf","filename":"agenda.pdf","headers":[{"name":"Content-Disposition","value":"attachment; filename=\"agenda.pdf\""}],"body":{"attachmentId":"ANGjdJ_synthetic_pdf","size":18}}]}}
;
const calendar_ics_response = "{\"size\":243,\"data\":\"QkVHSU46VkNBTEVOREFSDQpWRVJTSU9OOjIuMA0KTUVUSE9EOlJFUVVFU1QNCkJFR0lOOlZFVkVOVA0KVUlEOnBsYW5uaW5nQGV4YW1wbGUudGVzdA0KU0VRVUVOQ0U6NA0KRFRTVEFSVDoyMDI2MTAxMlQwODAwMDBaDQpPUkdBTklaRVI6bWFpbHRvOm9yZ2FuaXplckBleGFtcGxlLnRlc3QNCkFUVEVOREVFO1JTVlA9VFJVRTptYWlsdG86c3ludGhldGljQGV4YW1wbGUudGVzdA0KRU5EOlZFVkVOVA0KRU5EOlZDQUxFTkRBUg0K\"}";

test "live message body: conflicting calendar parts keep the mail and files but offer no invitation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var peer: Peer = .{ .steps = &.{
        .{ .url = calendar_full_url, .response = calendar_wire },
        .{ .url = calendar_ics_url, .response = calendar_ics_response },
    } };
    const result = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-read"}, peer.transport(), "mail.read", try j.value(a, .{ .messageId = "c1" }));
    try std.testing.expectEqual(@as(usize, 2), peer.calls);
    try std.testing.expectEqual(@as(usize, 0), peer.writes);
    const message = try j.decode(types.Message, a, result);
    try std.testing.expect(message.invitation == null);
    try std.testing.expect(std.mem.indexOf(u8, message.bodyText, "Agenda attached.") != null);
    try std.testing.expectEqual(@as(usize, 2), message.attachments.len);
    try std.testing.expectEqualStrings("invite.ics", message.attachments[0].filename);
    try std.testing.expect(std.mem.indexOf(u8, try mime.decodeBase64Url(message.attachments[0].data, a), "SEQUENCE:4") != null);
    try std.testing.expectEqualStrings("agenda.pdf", message.attachments[1].filename);
    try std.testing.expectEqualStrings("ANGjdJ_synthetic_pdf", message.attachments[1].id);

    // An RSVP refuses before any send: the conflict names no single event.
    var rsvp: Peer = .{ .steps = &.{
        .{ .url = calendar_full_url, .response = calendar_wire },
        .{ .url = calendar_ics_url, .response = calendar_ics_response },
    } };
    try std.testing.expectError(error.NotInvitation, gmail.dispatchAuthorized(std.testing.io, a, account, &.{ "mail-read", "calendar-rsvp" }, rsvp.transport(), "invitation.reply", try j.value(a, .{ .messageId = "c1", .status = "accepted", .operationId = "synthetic-rsvp" })));
    try std.testing.expectEqual(@as(usize, 0), rsvp.writes);
}
