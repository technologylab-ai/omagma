//! Portable draft decoding and validation. No storage, filesystem, network or
//! credential helpers are needed to validate the data that a sender receives.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const recipients = @import("recipients.zig");
const mail_limits = @import("mail_limits.zig");
const Value = std.json.Value;
fn valueArray(value: Value) ![]Value {
    return if (value == .array) value.array.items else error.InvalidRequest;
}
pub fn validateAttachmentHandle(id: []const u8) !void {
    if (id.len != 64) return error.InvalidAttachmentHandle;
    for (id) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidAttachmentHandle;
}
pub fn decodeAddresses(a: std.mem.Allocator, v: Value) ![]const t.Address {
    var list: std.ArrayList(t.Address) = .empty;
    if (v == .string) {
        var parsed: recipients.List = .{};
        try recipients.parse(v.string, &parsed);
        return @import("conversation_draft.zig").listAddresses(a, &parsed);
    }
    const values = try valueArray(v);
    if (values.len > t.Limits.recipients) return error.TooManyRecipients;
    for (values) |item| {
        const address = if (item == .string) item.string else try j.required(item, "address");
        if (item == .object) if (j.get(item, "name")) |field| {
            if (field != .string) return error.InvalidRequest;
        };
        const name = if (item == .string) "" else j.text(item, "name");
        try recipients.validateAddress(address);
        try recipients.validateHeader(name);
        if (name.len > mail_limits.display_name_bytes) return error.InvalidAddress;
        try list.append(a, .{ .address = try a.dupe(u8, address), .name = try a.dupe(u8, name) });
    }
    return list.items;
}
pub fn decodeDraft(a: std.mem.Allocator, v: Value) !t.Draft {
    return decodeDraftAllocators(a, null, v);
}
/// Retain the decoded DTO in a, but release binary validation copies as soon
/// as they have been checked. The browser supplies its backing allocator so
/// those temporary bytes do not accumulate in a command's response arena.
pub fn decodeDraftWithScratch(a: std.mem.Allocator, backing: std.mem.Allocator, v: Value) !t.Draft {
    return decodeDraftAllocators(a, backing, v);
}
fn decodeDraftAllocators(a: std.mem.Allocator, backing: ?std.mem.Allocator, v: Value) !t.Draft {
    if (v != .object) return error.InvalidRequest;
    for ([_][]const u8{ "id", "subject", "bodyText", "threadId", "inReplyTo", "references" }) |key| if (j.get(v, key)) |field| {
        if (field != .string) return error.InvalidRequest;
    };
    var draft = try j.decode(t.Draft, a, try j.value(a, .{ .id = j.text(v, "id"), .subject = j.text(v, "subject"), .bodyText = j.text(v, "bodyText"), .threadId = j.text(v, "threadId"), .inReplyTo = j.text(v, "inReplyTo"), .references = j.text(v, "references") }));
    draft.bodyFormat = try requestBodyFormat(v);
    const omitted = try j.integer(v, "omittedAttachments", 0);
    if (omitted < 0 or omitted > t.Limits.omitted_attachment_count) return error.TooManyAttachments;
    draft.omittedAttachments = @intCast(omitted);
    draft.to = if (j.get(v, "to")) |x| try decodeAddresses(a, x) else &.{};
    draft.cc = if (j.get(v, "cc")) |x| try decodeAddresses(a, x) else &.{};
    draft.bcc = if (j.get(v, "bcc")) |x| try decodeAddresses(a, x) else &.{};
    if (j.get(v, "from")) |sender| if (sender != .null) {
        if (sender == .string) {
            const addresses = try decodeAddresses(a, sender);
            if (addresses.len != 1) return error.InvalidSender;
            draft.from = addresses[0];
        } else draft.from = try j.decode(t.Address, a, sender);
    };
    if (j.get(v, "recoveryFields")) |fields| if (fields != .null) {
        draft.recoveryFields = try j.decode([]const []const u8, a, fields);
        if (draft.recoveryFields.?.len != 5) return error.InvalidRecovery;
    };
    draft.attachments = if (j.get(v, "attachments")) |x| try j.decode([]const t.Attachment, a, x) else &.{};
    if (j.get(v, "original")) |original| {
        if (original != .null) draft.original = try j.decode(t.Original, a, original);
    }
    if (backing) |allocator| {
        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        try validateInlineBytes(scratch.allocator(), draft);
    } else try validateInlineBytes(a, draft);
    return draft;
}
fn validateInlineBytes(a: std.mem.Allocator, draft: t.Draft) !void {
    for (draft.attachments) |attachment| if (attachment.blobId == null) {
        _ = try @import("mime.zig").composeAttachments(&.{attachment}, a);
    };
    if (draft.original) |original| _ = try @import("mime.zig").composeAttachments(original.resources, a);
}
pub fn requestBodyFormat(v: Value) !t.BodyFormat {
    const field = j.get(v, "bodyFormat") orelse return .plain;
    const text = try j.string(field);
    return std.meta.stringToEnum(t.BodyFormat, text) orelse error.InvalidBodyFormat;
}
pub fn validateDraft(d: t.Draft, send: bool) !void {
    if (d.omittedAttachments > t.Limits.omitted_attachment_count) return error.TooManyAttachments;
    if (send and d.recoveryFields != null) return error.UnfinishedDraft;
    if (d.from) |sender| {
        try recipients.validateAddress(sender.address);
        try recipients.validateHeader(sender.name);
        if (sender.name.len > mail_limits.display_name_bytes) return error.InvalidSender;
    }
    if (d.to.len + d.cc.len + d.bcc.len > t.Limits.recipients) return error.TooManyRecipients;
    if (send and d.to.len + d.cc.len + d.bcc.len == 0) return error.MissingRecipient;
    if (d.bodyText.len > t.Limits.body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(d.bodyText)) return error.InvalidUtf8;
    const related = if (d.original) |original| original.resources else &.{};
    if (d.attachments.len > t.Limits.attachments or related.len > t.Limits.related_resources) return error.TooManyAttachments;
    if (d.original) |original| try @import("original_mail.zig").validate(original);
    var attachment_bytes: usize = 0;
    var embedded_bytes: usize = 0;
    for ([_][]const t.Attachment{ d.attachments, related }) |list| for (list) |attachment| {
        if (attachment.filename.len == 0 or attachment.filename.len > mail_limits.filename_bytes or std.mem.indexOfAny(u8, attachment.filename, "/\\") != null) return error.InvalidAttachment;
        try recipients.validateHeader(attachment.filename);
        try recipients.validateHeader(attachment.mimeType);
        if (attachment.mimeType.len == 0 or attachment.mimeType.len > 128 or std.mem.indexOfScalar(u8, attachment.mimeType, '/') == null) return error.InvalidAttachment;
        const n = if (attachment.blobId) |id| blk: {
            try validateAttachmentHandle(id);
            if (attachment.data.len != 0) return error.InvalidAttachmentHandle;
            break :blk attachment.size;
        } else std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(attachment.data) catch return error.InvalidAttachment;
        attachment_bytes = std.math.add(usize, attachment_bytes, n) catch return error.BodyTooLarge;
        if (attachment_bytes > t.Limits.attachment_bytes or n != attachment.size) return error.InvalidAttachment;
        if (attachment.blobId == null) {
            embedded_bytes = std.math.add(usize, embedded_bytes, n) catch return error.BodyTooLarge;
            if (embedded_bytes > t.Limits.body_bytes) return error.InvalidAttachment;
        }
        // Validate every encoded byte without allocating a second binary copy.
        for (attachment.data) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidAttachment;
        try @import("mime.zig").validateAttachment(attachment.filename, attachment.mimeType);
        if (attachment.contentId) |id| _ = try @import("mime.zig").contentId(id);
        if (attachment.disposition) |value| if (!std.mem.eql(u8, value, "inline") and !std.mem.eql(u8, value, "attachment")) return error.InvalidDisposition;
        if (attachment.contentLocation) |value| {
            try recipients.validateHeader(value);
            if (value.len == 0 or value.len > 2048) return error.InvalidContentLocation;
        }
    };
    for (related, 0..) |resource, index| {
        if (resource.blobId != null) return error.InvalidOriginalResource;
        if (std.ascii.startsWithIgnoreCase(resource.mimeType, "message/")) return error.UnsupportedRelatedType;
        if (resource.contentId == null and resource.contentLocation == null) return error.MissingRelatedIdentity;
        for (related[0..index]) |previous| {
            if (resource.contentId) |id| if (previous.contentId) |other| if (std.mem.eql(u8, id, other)) return error.AmbiguousContentId;
            if (resource.contentLocation) |location| if (previous.contentLocation) |other| if (std.mem.eql(u8, location, other)) return error.AmbiguousContentId;
        }
    }
    try recipients.validateHeader(d.subject);
    try recipients.validateHeader(d.inReplyTo);
    try recipients.validateHeader(d.references);
    try recipients.validateHeader(d.threadId);
    if (d.subject.len > mail_limits.subject_bytes or d.references.len > mail_limits.references_bytes) return error.HeaderTooLarge;
    for ([_][]const t.Address{ d.to, d.cc, d.bcc }) |list| for (list) |address| {
        try recipients.validateAddress(address.address);
        try recipients.validateHeader(address.name);
        if (address.name.len > mail_limits.display_name_bytes) return error.InvalidAddress;
    };
}

test "draft codec: incomplete recipients stay editable and send validation remains explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try decodeDraft(a, try j.value(a, .{ .subject = "Literal", .bodyText = "**plain source**" }));
    try std.testing.expectEqual(t.BodyFormat.plain, legacy.bodyFormat);
    try std.testing.expectEqual(@as(usize, 0), legacy.omittedAttachments);
    try validateDraft(legacy, false);
    try std.testing.expectError(error.MissingRecipient, validateDraft(legacy, true));
    const forward = try decodeDraft(a, try j.value(a, .{ .to = "Peer <peer@example.test>", .omittedAttachments = @as(usize, 2), .bodyFormat = "markdown", .bodyText = "Note" }));
    try std.testing.expectEqualStrings("peer@example.test", forward.to[0].address);
    try std.testing.expectEqual(@as(usize, 2), forward.omittedAttachments);
    try validateDraft(forward, true);
    try std.testing.expectError(error.TooManyAttachments, decodeDraft(a, try j.value(a, .{ .omittedAttachments = @as(i64, -1) })));
    try std.testing.expectError(error.InvalidAttachmentHandle, validateAttachmentHandle("not-a-blob"));
    try std.testing.expectError(error.HeaderInjection, validateDraft(.{ .subject = "Hi\r\nInjected: no" }, false));
}

test "draft codec: temporary attachment validation releases bytes without borrowing draft data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decoded_size = 64 * 1024;
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(decoded_size));
    @memset(encoded, 'A');
    const input = try j.value(a, t.Draft{
        .to = &.{.{ .address = "peer@example.test" }},
        .subject = "Owned draft",
        .attachments = &.{.{ .id = "file", .filename = "file.txt", .mimeType = "text/plain", .size = 3, .data = "YWJj" }},
        .original = .{
            .bodyHtml = "<img src=\"cid:logo\">",
            .resources = &.{.{ .id = "logo", .filename = "logo.png", .mimeType = "image/png", .size = decoded_size, .data = encoded, .contentId = "logo" }},
        },
    });
    var scratch: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const decoded = try decodeDraftWithScratch(a, scratch.allocator(), input);
    try std.testing.expect(scratch.allocated_bytes >= decoded_size);
    try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    try validateDraft(decoded, true);
    try std.testing.expectEqualStrings("Owned draft", decoded.subject);
    try std.testing.expectEqualStrings("YWJj", decoded.attachments[0].data);
    try std.testing.expectEqualStrings(encoded, decoded.original.?.resources[0].data);
    // Both entry points keep precisely the same strict binary validation.
    const invalid = try j.value(a, t.Draft{ .attachments = &.{.{ .id = "bad", .filename = "bad.bin", .size = 3, .data = "!!!!" }} });
    try std.testing.expectError(error.InvalidBase64, decodeDraft(a, invalid));
    try std.testing.expectError(error.InvalidBase64, decodeDraftWithScratch(a, scratch.allocator(), invalid));
    try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodeDraftWithScratch(a, failing.allocator(), input));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "mail metadata: draft round-trip shares subject name and filename byte limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subject: [mail_limits.subject_bytes]u8 = @splat('s');
    const name: [mail_limits.display_name_bytes]u8 = @splat('n');
    const filename: [mail_limits.filename_bytes]u8 = @splat('f');
    const source: t.Draft = .{
        .from = .{ .address = "sender@example.test", .name = &name },
        .to = &.{.{ .address = "peer@example.test", .name = &name }},
        .subject = &subject,
        .bodyText = "Saved note",
        .attachments = &.{.{ .id = "synthetic-file", .filename = &filename, .size = 1, .data = "YQ" }},
    };
    const decoded = try decodeDraft(a, try j.value(a, source));
    try validateDraft(decoded, true);
    try std.testing.expectEqualStrings(&subject, decoded.subject);
    try std.testing.expectEqualStrings(&name, decoded.to[0].name);
    try std.testing.expectEqualStrings(&filename, decoded.attachments[0].filename);

    const long_subject: [mail_limits.subject_bytes + 1]u8 = @splat('s');
    var invalid = decoded;
    invalid.subject = &long_subject;
    try std.testing.expectError(error.HeaderTooLarge, validateDraft(invalid, false));
    const long_name: [mail_limits.display_name_bytes + 1]u8 = @splat('n');
    invalid = decoded;
    invalid.from = .{ .address = "sender@example.test", .name = &long_name };
    try std.testing.expectError(error.InvalidSender, validateDraft(invalid, false));
    invalid = decoded;
    invalid.to = &.{.{ .address = "peer@example.test", .name = &long_name }};
    try std.testing.expectError(error.InvalidAddress, validateDraft(invalid, false));
    try std.testing.expectError(error.InvalidAddress, decodeAddresses(a, try j.value(a, invalid.to)));
    const long_filename: [mail_limits.filename_bytes + 1]u8 = @splat('f');
    var attachment = decoded.attachments[0];
    attachment.filename = &long_filename;
    invalid = decoded;
    invalid.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validateDraft(invalid, false));
}
