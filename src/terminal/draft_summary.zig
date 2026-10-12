//! Compact draft-list previews shared by native and browser storage.
//! Full bodies, recovery fields, original snapshots and file bytes stay only
//! in the stored draft. A summary keeps their existing identity metadata.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");

pub fn attachmentMetadata(a: std.mem.Allocator, input: []const t.Attachment) ![]const t.Attachment {
    const result = try a.dupe(t.Attachment, input);
    for (result) |*attachment| attachment.data = "";
    return result;
}

/// Small fields retain the input lifetime, matching native Store previews.
pub fn fromDraft(a: std.mem.Allocator, input: t.Draft) !t.Draft {
    var result = input;
    result.bodyText = "";
    result.recoveryFields = null;
    result.original = null;
    result.attachments = try attachmentMetadata(a, input.attachments);
    return result;
}

/// Strip heavy values before typed decoding would allocate copies of them.
/// Map storage is copied, so an immutable parsed stored draft stays intact.
pub fn fromValue(a: std.mem.Allocator, input: j.Value) !t.Draft {
    var summary = try j.copyObject(a, input);
    try summary.object.put(a, "bodyText", .{ .string = "" });
    try summary.object.put(a, "recoveryFields", .null);
    try summary.object.put(a, "original", .null);
    if (j.get(input, "attachments")) |files| {
        if (files != .array) return error.InvalidRequest;
        var metadata: j.Value = .{ .array = .init(a) };
        for (files.array.items) |file| {
            var item = try j.copyObject(a, file);
            try item.object.put(a, "data", .{ .string = "" });
            try metadata.array.append(item);
        }
        try summary.object.put(a, "attachments", metadata);
    }
    return fromDraft(a, try j.decode(t.Draft, a, summary));
}

/// Existing API callers receive the full saved draft. A controller which
/// already owns that content can request just its persisted identity.
pub fn savedResponse(a: std.mem.Allocator, draft: t.Draft, acknowledgement_only: bool) !j.Value {
    return if (acknowledgement_only) j.value(a, .{ .id = draft.id }) else j.value(a, draft);
}

test "draft summary: JSON previews strip payloads before decoding and match native metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const large = try a.alloc(u8, 1024 * 1024);
    @memset(large, 'A');
    const input: t.Draft = .{
        .id = "retained-draft",
        .from = .{ .address = "self@example.test", .name = "Sender" },
        .to = &.{.{ .address = "peer@example.test", .name = "Peer" }},
        .subject = "Large retained draft",
        .bodyText = large,
        .bodyFormat = .markdown,
        .threadId = "thread-id",
        .inReplyTo = "<source@example.test>",
        .references = "<earlier@example.test>",
        .omittedAttachments = 2,
        .recoveryFields = &.{ "unfinished address", "", "", "Recovered subject", large },
        .attachments = &.{
            .{ .id = "inline-file", .filename = "source.png", .mimeType = "image/png", .size = 768 * 1024, .data = large, .contentId = "source", .disposition = "attachment", .contentLocation = "https://example.test/source.png" },
            .{ .id = "blob-file", .filename = "archive.zip", .mimeType = "application/zip", .size = 20 * 1024 * 1024, .blobId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        },
        .original = .{ .bodyText = large, .bodyHtml = "<p>Frozen original</p>", .resources = &.{.{ .id = "resource", .filename = "logo.png", .mimeType = "image/png", .size = 768 * 1024, .data = large, .contentId = "logo" }} },
    };
    const value = try j.value(a, input);
    var buffer: [16 * 1024]u8 = undefined;
    var bounded: std.heap.FixedBufferAllocator = .init(&buffer);
    const summary = try fromValue(bounded.allocator(), value);
    try std.testing.expectEqualDeep(try fromDraft(a, input), summary);
    try std.testing.expectEqual(large.len, j.text(value, "bodyText").len);
    try std.testing.expectEqual(large.len, j.text(j.get(value, "attachments").?.array.items[0], "data").len);
    try std.testing.expect(j.get(value, "original").? != .null);
    try std.testing.expectEqual(large.len, j.get(value, "recoveryFields").?.array.items[4].string.len);
    var response_buffer: [4096]u8 = undefined;
    var response_allocator: std.heap.FixedBufferAllocator = .init(&response_buffer);
    const acknowledgement = try savedResponse(response_allocator.allocator(), input, true);
    try std.testing.expectEqual(@as(usize, 1), acknowledgement.object.count());
    try std.testing.expectEqualStrings(input.id, j.text(acknowledgement, "id"));
    const full_response = try savedResponse(a, input, false);
    try std.testing.expectEqual(large.len, j.text(full_response, "bodyText").len);
    try std.testing.expectEqual(large.len, j.text(j.get(full_response, "attachments").?.array.items[0], "data").len);
}
