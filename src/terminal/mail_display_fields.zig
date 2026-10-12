//! Normalize legacy cached display headers without changing message identity,
//! threading syntax, source bytes, or participant selection.
const std = @import("std");
const t = @import("types.zig");
const limits = @import("mail_limits.zig");
const mime = @import("mime.zig");

fn displayField(comptime limit: usize, a: std.mem.Allocator, value: []const u8, oversized: anyerror) ![]const u8 {
    if (value.len > limit) return oversized;
    // Header sanitization only removes bytes or replaces whitespace. A fixed
    // stack workspace lets already canonical fields retain their owned slice
    // without accumulating another copy in the caller's retained arena.
    var storage: [limit]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const cleaned = try mime.sanitizeHeaderText(value, fixed.allocator());
    if (std.mem.eql(u8, cleaned, value)) return value;
    return a.dupe(u8, cleaned);
}

fn displayAddresses(a: std.mem.Allocator, values: []const t.Address) ![]const t.Address {
    if (values.len > limits.incoming_recipients) return error.TooManyIncomingRecipients;
    var changed: ?[]t.Address = null;
    for (values, 0..) |value, i| {
        const name = try displayField(limits.display_name_bytes, a, value.name, error.CapacityExceeded);
        if (name.ptr == value.name.ptr) continue;
        if (changed == null) changed = try a.dupe(t.Address, values);
        changed.?[i].name = name;
    }
    return changed orelse values;
}

/// The source DTO must already belong to the caller's lifetime. Unchanged
/// fields remain borrowed from it; changed display strings and their enclosing
/// arrays are copied into `a`. No body or raw protocol header is transformed.
pub fn canonicalizeMessageDisplay(a: std.mem.Allocator, message: t.Message) !t.Message {
    var result = message;
    result.subject = try displayField(limits.subject_bytes, a, message.subject, error.HeaderTooLarge);
    result.from.name = try displayField(limits.display_name_bytes, a, message.from.name, error.CapacityExceeded);
    result.to = try displayAddresses(a, message.to);
    result.cc = try displayAddresses(a, message.cc);
    result.replyTo = try displayAddresses(a, message.replyTo);
    if (message.attachments.len > mime.max_attachments) return error.TooManyAttachments;
    var attachments: ?[]t.Attachment = null;
    for (message.attachments, 0..) |attachment, i| {
        const filename = try displayField(limits.filename_bytes, a, attachment.filename, error.FilenameTooLarge);
        if (filename.ptr == attachment.filename.ptr) continue;
        if (attachments == null) attachments = try a.dupe(t.Attachment, message.attachments);
        attachments.?[i].filename = filename;
    }
    result.attachments = attachments orelse message.attachments;
    return result;
}

test "mail display cache: legacy headers normalize while addresses protocol headers and body stay exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: t.Message = .{
        .id = "legacy",
        .threadId = "legacy-thread",
        .from = .{ .address = "Sender@EXAMPLE.TEST", .name = "Sender\tName\n" },
        .to = &.{.{ .address = "Self@EXAMPLE.TEST", .name = "To\r\nName" }},
        .cc = &.{.{ .address = "Copy@EXAMPLE.TEST", .name = "Cc\tName" }},
        .replyTo = &.{.{ .address = "Reply@EXAMPLE.TEST", .name = "Reply\nName" }},
        .subject = "Legacy\tSubject\nwith\u{202e}controls",
        .messageId = "<literal\u{202e}@example.test>",
        .references = "<first@example.test>\t<literal\u{202e}@example.test>",
        .inReplyTo = "<literal\u{202e}@example.test>",
        .sentDate = "Tue,\t13 Oct 2026 09:00:00 +0000",
        .bodyText = "Full body\nwith\ttabs\u{202e}kept.",
        .bodyHtml = "<p>Full body\nwith\ttabs.</p>",
        .attachments = &.{.{ .id = "file", .filename = "Legacy\tfile\n.txt", .mimeType = "text/plain", .data = "YWJj", .size = 3 }},
    };
    const cleaned = try canonicalizeMessageDisplay(a, source);
    try std.testing.expectEqualStrings("Sender Name ", cleaned.from.name);
    try std.testing.expectEqualStrings("To Name", cleaned.to[0].name);
    try std.testing.expectEqualStrings("Cc Name", cleaned.cc[0].name);
    try std.testing.expectEqualStrings("Reply Name", cleaned.replyTo[0].name);
    try std.testing.expectEqualStrings("Legacy Subject withcontrols", cleaned.subject);
    try std.testing.expectEqualStrings("Legacy file .txt", cleaned.attachments[0].filename);
    try std.testing.expectEqualStrings(source.from.address, cleaned.from.address);
    for ([_][]const t.Address{ cleaned.to, cleaned.cc, cleaned.replyTo }, [_][]const t.Address{ source.to, source.cc, source.replyTo }) |actual, expected| {
        try std.testing.expectEqualStrings(expected[0].address, actual[0].address);
        _ = try @import("recipients.zig").formatIncomingDisplay(a, actual[0].address, actual[0].name);
    }
    _ = try @import("recipients.zig").formatIncomingDisplay(a, cleaned.from.address, cleaned.from.name);
    inline for (.{ "id", "threadId", "bodyText", "messageId", "references", "inReplyTo" }) |field| try std.testing.expectEqualStrings(@field(source, field), @field(cleaned, field));
    try std.testing.expectEqualStrings(source.sentDate.?, cleaned.sentDate.?);
    try std.testing.expectEqualStrings(source.bodyHtml.?, cleaned.bodyHtml.?);
    try std.testing.expectEqualStrings(source.attachments[0].data, cleaned.attachments[0].data);
    const quoted = try @import("conversation_draft.zig").quote(a, cleaned.bodyText);
    try std.testing.expectEqualStrings("\n\n> Full body\n> with\ttabs\u{202e}kept.\n", quoted);
    try std.testing.expectEqualStrings("Sender\tName\n", source.from.name);
    try std.testing.expectEqualStrings("To\r\nName", source.to[0].name);
}

test "mail display cache: canonical fields borrow without allocating and bounds remain explicit" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    var message: t.Message = .{ .id = "canonical", .threadId = "thread", .subject = "Subject", .from = .{ .address = "sender@example.test", .name = "Sender" }, .to = &.{.{ .address = "self@example.test", .name = "Self" }} };
    const copied = try canonicalizeMessageDisplay(a, message);
    try std.testing.expect(copied.subject.ptr == message.subject.ptr and copied.to.ptr == message.to.ptr);
    message.from.name = "Changed\tName";
    try std.testing.expectError(error.OutOfMemory, canonicalizeMessageDisplay(a, message));
    const too_large: [limits.display_name_bytes + 1]u8 = @splat('n');
    message.from.name = &too_large;
    try std.testing.expectError(error.CapacityExceeded, canonicalizeMessageDisplay(a, message));
}
