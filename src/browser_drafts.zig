//! Credential-free browser draft envelope. Only freshly verified actor bindings
//! may restore it. Shared codec validation remains the authority for mail data.
const std = @import("std");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const codec = @import("terminal/draft_codec.zig");
pub const Binding = @import("browser_cache.zig").Binding;
pub const per_actor = 8;
pub const total_bytes = 8 * 1024 * 1024;
pub const snapshot_bytes = total_bytes + 128 * 1024;
pub const operation_limit = 64;
pub const Phase = enum { paused, submitted };
pub const Outcome = enum { unknown, applied, rejected };
pub const Receipt = struct {
    id: []const u8,
    draftId: []const u8,
    hash: []const u8,
    phase: Phase,
    outcome: Outcome,
    errorCode: []const u8 = "",
    acknowledged: bool = false,
};
pub const Document = struct {
    version: u8,
    revision: u32,
    account: []const u8,
    clientId: []const u8,
    grantId: []const u8,
    drafts: []const t.Draft,
    operations: []const Receipt,
};
pub const Storage = struct {
    context: ?*anyopaque = null,
    saveFn: *const fn (?*anyopaque, u32, []const u8) anyerror!void,
};
fn text(value: []const u8, maximum: usize) !void {
    if (value.len > maximum or !std.unicode.utf8ValidateSlice(value)) return error.InvalidBrowserDrafts;
    try @import("terminal/recipients.zig").validateHeader(value);
}
pub fn decode(a: std.mem.Allocator, backing: std.mem.Allocator, binding: Binding, raw: []const u8) !Document {
    if (raw.len == 0 or raw.len > snapshot_bytes) return error.InvalidBrowserDrafts;
    // Strict typed parse rejects fields outside the passive envelope, including
    // provider metadata and credentials at every nested object level.
    const document = try std.json.parseFromSliceLeaky(Document, a, raw, .{ .allocate = .alloc_if_needed, .duplicate_field_behavior = .@"error", .max_value_len = t.Limits.request_bytes });
    if (document.version != 1 or document.revision == 0 or document.drafts.len > per_actor or document.operations.len > operation_limit or !std.mem.eql(u8, binding.account, document.account) or !std.mem.eql(u8, binding.clientId, document.clientId) or !std.mem.eql(u8, binding.grantId, document.grantId)) return error.InvalidBrowserDrafts;
    var draft_bytes: usize = 0;
    for (document.drafts, 0..) |draft, index| {
        if (draft.id.len == 0) return error.InvalidBrowserDrafts;
        try text(draft.id, 128);
        for (document.drafts[0..index]) |previous| if (std.mem.eql(u8, previous.id, draft.id)) return error.InvalidBrowserDrafts;
        try codec.validateDraft(draft, false);
        for (draft.attachments) |attachment| if (attachment.blobId != null) return error.BrowserAttachmentsUnavailable;
        // Exercise the same binary/original validation as an incoming update,
        // with disposable scratch copies released after each whole draft.
        var scratch: std.heap.ArenaAllocator = .init(backing);
        defer scratch.deinit();
        const value = try j.value(scratch.allocator(), draft);
        _ = try codec.decodeDraftWithScratch(scratch.allocator(), backing, value);
        var count_buffer: [256]u8 = undefined;
        var counter: std.Io.Writer.Discarding = .init(&count_buffer);
        try std.json.Stringify.value(draft, .{ .emit_null_optional_fields = false }, &counter.writer);
        const size: usize = @intCast(counter.fullCount());
        if (size > t.Limits.request_bytes - 16 * 1024) return error.BrowserDraftQuota;
        draft_bytes += size;
        if (draft_bytes > total_bytes) return error.BrowserDraftQuota;
    }
    for (document.operations, 0..) |operation, index| {
        try text(operation.id, 256);
        try text(operation.draftId, 128);
        try text(operation.errorCode, 64);
        if (operation.id.len == 0 or operation.draftId.len == 0 or operation.hash.len != 64 or (operation.acknowledged and operation.outcome != .unknown)) return error.InvalidBrowserDrafts;
        for (operation.hash) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidBrowserDrafts;
        for (document.operations[0..index]) |previous| if (std.mem.eql(u8, previous.id, operation.id)) return error.InvalidBrowserDrafts;
        if (operation.outcome == .unknown and !operation.acknowledged) {
            var found = false;
            for (document.drafts) |draft| found = found or std.mem.eql(u8, draft.id, operation.draftId);
            if (!found) return error.InvalidBrowserDrafts;
        }
    }
    return document;
}
