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

/// Compact owned references protect file bytes independently of mutable
/// metadata and summaries, which deliberately omit the original snapshot.
pub fn blobReferences(a: std.mem.Allocator, attachments: []const t.Attachment) ![]const []const u8 {
    if (attachments.len > t.Limits.message_attachments) return error.TooManyAttachments;
    var selected: [t.Limits.message_attachments][]const u8 = undefined;
    var count: usize = 0;
    for (attachments) |attachment| if (attachment.blobId) |id| {
        try @import("draft_codec.zig").validateAttachmentHandle(id);
        var duplicate = false;
        for (selected[0..count]) |previous| duplicate = duplicate or std.mem.eql(u8, id, previous);
        if (!duplicate) {
            selected[count] = id;
            count += 1;
        }
    };
    const owned = try a.alloc([]const u8, count);
    for (owned, selected[0..count]) |*target, id| target.* = try a.dupe(u8, id);
    return owned;
}

/// Small fields retain the input lifetime, matching native Store previews.
pub fn fromDraft(a: std.mem.Allocator, input: t.Draft) !t.Draft {
    if (t.Limits.native) return .{
        .id = input.id,
        .from = input.from,
        .subject = input.subject,
        .bodyFormat = input.bodyFormat,
        .includeOriginal = input.includeOriginal,
        .threadId = input.threadId,
        .omittedAttachments = input.omittedAttachments,
        .summaryCounts = input.summaryCounts orelse counts(input),
    };
    return portablePreview(a, input);
}
fn portablePreview(a: std.mem.Allocator, input: t.Draft) !t.Draft {
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
    return portablePreview(a, try j.decode(t.Draft, a, summary));
}

/// Existing API callers receive the full saved draft. A controller which
/// already owns that content can request just its persisted identity.
pub fn savedResponse(a: std.mem.Allocator, draft: t.Draft, acknowledgement_only: bool) !j.Value {
    return if (acknowledgement_only) j.value(a, .{ .id = draft.id }) else j.value(a, draft);
}

/// List responses are navigation metadata, not editable draft DTOs. Keep
/// full descriptors in the exact saved source, with immutable pin records
/// separate from native summary counts. draft.read retrieves the full content.
pub const ListEntry = struct {
    id: []const u8,
    from: ?t.Address,
    subject: []const u8,
    bodyFormat: t.BodyFormat,
    includeOriginal: bool,
    toCount: usize,
    ccCount: usize,
    bccCount: usize,
    attachmentCount: usize,
    omittedAttachments: usize,
    summaryOnly: bool = true,
};
pub fn listEntry(input: t.Draft) ListEntry {
    const selected = input.summaryCounts orelse counts(input);
    return .{ .id = input.id, .from = input.from, .subject = input.subject, .bodyFormat = input.bodyFormat, .includeOriginal = input.includeOriginal, .toCount = selected.to, .ccCount = selected.cc, .bccCount = selected.bcc, .attachmentCount = selected.attachments, .omittedAttachments = input.omittedAttachments };
}
fn counts(input: t.Draft) t.DraftSummaryCounts {
    return .{ .to = input.to.len, .cc = input.cc.len, .bcc = input.bcc.len, .attachments = input.attachments.len };
}

// Reserve room for cursor, command correlation and response envelopes. This
// is an encoded-byte budget, not an allocation or draft-content quota.
pub const list_bytes = t.Limits.request_bytes - 4096;
pub fn encodedBytes(input: anytype) !usize {
    var buffer: [4096]u8 = undefined;
    var count: std.Io.Writer.Discarding = .init(&buffer);
    try std.json.Stringify.value(input, .{ .emit_null_optional_fields = false }, &count.writer);
    return @intCast(count.fullCount());
}

pub fn list(a: std.mem.Allocator, drafts: []const t.Draft, links: []const @import("draft_link.zig").Link, cursor: []const u8, limit: usize) !j.Value {
    if (limit == 0 or limit > t.Limits.page) return error.InvalidPageLimit;
    var start: usize = 0;
    if (cursor.len != 0) {
        if (!std.mem.startsWith(u8, cursor, "D:")) return error.InvalidDraftCursor;
        start = for (drafts, 0..) |draft, index| {
            if (std.mem.eql(u8, draft.id, cursor[2..])) break index + 1;
        } else return error.InvalidDraftCursor;
    }
    var rows: j.Value = .{ .array = .init(a) };
    var selected_links: j.Value = .{ .array = .init(a) };
    var bytes: usize = 0;
    var end = start;
    for (drafts[start..]) |draft| {
        const row = listEntry(draft);
        const link: ?@import("draft_link.zig").Link = for (links) |item| {
            if (std.mem.eql(u8, item.draftId, draft.id)) break item;
        } else null;
        const needed = try encodedBytes(row) + (if (link) |item| try encodedBytes(item) else @as(usize, 0)) + 2;
        if (needed > list_bytes) return error.DraftListEntryTooLarge;
        if (rows.array.items.len == limit or needed > list_bytes - bytes) break;
        try rows.array.append(try j.value(a, row));
        if (link) |item| try selected_links.array.append(try j.value(a, item));
        bytes += needed;
        end += 1;
    }
    var result = j.object(a);
    try result.object.put(a, "drafts", rows);
    try result.object.put(a, "gmailLinks", selected_links);
    try result.object.put(a, "cursor", .{ .string = try a.dupe(u8, cursor) });
    try result.object.put(a, "nextCursor", .{ .string = if (end < drafts.len) try std.fmt.allocPrint(a, "D:{s}", .{drafts[end - 1].id}) else "" });
    return result;
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
    try std.testing.expectEqualDeep(try portablePreview(a, input), summary);
    if (t.Limits.native) {
        const native = try fromDraft(a, input);
        try std.testing.expectEqual(@as(usize, 0), native.attachments.len);
        try std.testing.expectEqual(@as(usize, 0), native.to.len);
        try std.testing.expectEqual(@as(usize, 2), native.summaryCounts.?.attachments);
        try std.testing.expectEqual(@as(usize, 1), native.summaryCounts.?.to);
    }
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
