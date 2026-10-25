//! Immutable source binding and blob pins for one editable draft. The hot
//! account index holds one handle; complete source/file metadata stays cold.
const std = @import("std");
const t = @import("types.zig");
const history = @import("operation_history.zig");
const Store = @import("store.zig").Store;
pub const max_blobs = t.Limits.attachments + t.Limits.related_resources;
pub const max_bytes = max_blobs * 67 + 4096;
pub const Record = struct {
    schema: u8 = 1,
    account: []const u8,
    draftId: []const u8,
    source: []const u8 = "",
    hash: []const u8,
    blobs: []const []const u8,
};
pub fn load(s: *Store, a: std.mem.Allocator, id: []const u8) !?Record {
    for (s.state.relatedDraftBlobs) |reference| if (std.mem.eql(u8, reference.draftId, id) and reference.handle.len != 0) {
        const raw = try s.readHistory(a, try history.fileName(a, "pins", reference.handle), max_bytes);
        const record = try std.json.parseFromSliceLeaky(Record, a, raw, .{ .allocate = .alloc_if_needed });
        if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.draftId, id) or record.blobs.len > max_blobs) return error.InvalidDraftPins;
        if (record.source.len != 0) _ = try @import("vault_storage.zig").Handle.parse(record.source);
        try @import("draft_codec.zig").validateAttachmentHandle(record.hash);
        for (record.blobs) |blob| try @import("draft_codec.zig").validateAttachmentHandle(blob);
        return record;
    };
    return null;
}
pub fn sourceName(a: std.mem.Allocator, record: Record) ![]const u8 {
    return if (record.source.len != 0) history.fileName(a, "active", record.source) else std.fmt.allocPrint(a, "draft-{s}.json", .{Store.hash(record.draftId)});
}
pub fn collect(a: std.mem.Allocator, draft: t.Draft) ![]const []const u8 {
    var ids: std.StringHashMap(void) = .init(a);
    defer ids.deinit();
    var values: std.ArrayList([]const u8) = .empty;
    const related = if (draft.original) |original| original.resources else &.{};
    if (draft.attachments.len > t.Limits.attachments or related.len > t.Limits.related_resources) return error.TooManyAttachments;
    for ([_][]const t.Attachment{ draft.attachments, related }) |list| for (list) |file| if (file.blobId) |id| {
        try @import("draft_codec.zig").validateAttachmentHandle(id);
        if (!(try ids.getOrPut(id)).found_existing) try values.append(a, try a.dupe(u8, id));
    };
    return values.items;
}
pub fn write(s: *Store, draft: t.Draft, raw: []const u8, source_handle: []const u8) ![]const u8 {
    const handle = try @import("vault_storage.zig").Handle.create(s.io);
    const identity = try s.allocator.dupe(u8, &handle.text());
    const record: Record = .{ .account = s.state.account, .draftId = draft.id, .source = source_handle, .hash = &Store.hash(raw), .blobs = try collect(s.allocator, draft) };
    const encoded = try @import("json.zig").encodeAlloc(s.allocator, record, .{});
    if (encoded.len > max_bytes) return error.InvalidDraftPins;
    try s.writeHistory(try history.fileName(s.allocator, "pins", identity), encoded);
    return identity;
}
