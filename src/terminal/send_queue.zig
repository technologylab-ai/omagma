const std = @import("std");
const storage = @import("store.zig");
const j = @import("json.zig");
const bounded = @import("../bounded.zig");

pub fn delay(request: j.Value) !i64 {
    const seconds = try j.integer(request, "delaySeconds", 10);
    if (seconds < 0 or seconds > 30) return error.InvalidSendDelay;
    return seconds * 1000;
}
pub fn find(store: *storage.Store, id: []const u8) !*storage.QueuedSend {
    try bounded.identifier(id);
    for (store.state.sendQueue) |*entry| if (std.mem.eql(u8, entry.queueId, id)) return entry;
    return error.QueueNotFound;
}
pub fn receipt(a: std.mem.Allocator, store: *storage.Store, entry: storage.QueuedSend) !j.Value {
    var operation: ?storage.Operation = null;
    for (store.state.operations) |candidate| if (std.mem.eql(u8, candidate.id, entry.operationId)) {
        operation = candidate;
        break;
    };
    return j.value(a, .{
        .queueId = entry.queueId,
        .draftId = entry.draftId,
        .operationId = entry.operationId,
        .state = entry.state,
        .createdAtMs = entry.createdAtMs,
        .dueAtMs = entry.dueAtMs,
        .errorCode = entry.errorCode,
        .operation = operation,
    });
}
pub fn stage(store: *storage.Store, draft_id: []const u8, operation_id: []const u8, digest: []const u8, now_ms: i64, delay_ms: i64) !*storage.QueuedSend {
    try bounded.identifier(draft_id);
    if (operation_id.len == 0 or operation_id.len > 256) return error.InvalidOperationId;
    try @import("recipients.zig").validateHeader(operation_id);
    for (store.state.sendQueue) |*entry| if (std.mem.eql(u8, entry.operationId, operation_id)) {
        if (!std.mem.eql(u8, entry.draftId, draft_id) or !std.mem.eql(u8, entry.hash, digest)) return error.OperationConflict;
        return entry;
    };
    for (store.state.operations) |operation| {
        if (std.mem.eql(u8, operation.id, operation_id)) return error.OperationConflict;
        if (std.mem.eql(u8, operation.outcome, "unknown") and (std.mem.eql(u8, operation.draftId, draft_id) or std.mem.eql(u8, operation.hash, digest))) return error.UnknownOutcome;
    }
    var active: usize = 0;
    for (store.state.sendQueue) |entry| {
        if (entry.state == .queued or entry.state == .submitting or entry.state == .unknown) {
            active += 1;
            if (std.mem.eql(u8, entry.draftId, draft_id) or std.mem.eql(u8, entry.hash, digest)) return if (entry.state == .queued) error.DraftQueued else error.UnknownOutcome;
        }
    }
    if (active >= 32) return error.SendQueueFull;
    var entries: std.ArrayList(storage.QueuedSend) = .empty;
    // Only terminal history can be evicted. Unknown/submitting intents remain
    // fenced even after a process crash and must never turn back into pending.
    var evict = store.state.sendQueue.len >= 128;
    for (store.state.sendQueue) |entry| {
        if (evict and (entry.state == .canceled or entry.state == .applied or entry.state == .rejected)) {
            evict = false;
            continue;
        }
        try entries.append(store.allocator, entry);
    }
    const entry: storage.QueuedSend = .{
        .queueId = try store.nextId("queue"),
        .draftId = draft_id,
        .operationId = operation_id,
        .hash = try store.allocator.dupe(u8, digest),
        .createdAtMs = now_ms,
        .dueAtMs = std.math.add(i64, now_ms, delay_ms) catch return error.InvalidSendDelay,
    };
    try entries.append(store.allocator, entry);
    store.state.sendQueue = entries.items;
    try store.save();
    return &store.state.sendQueue[store.state.sendQueue.len - 1];
}
pub fn cancel(store: *storage.Store, id: []const u8) !*storage.QueuedSend {
    const entry = try find(store, id);
    if (entry.state == .canceled) return entry;
    if (entry.state != .queued) return error.SendAlreadySubmitted;
    entry.state = .canceled;
    try store.save();
    return entry;
}
pub fn resumeEntry(store: *storage.Store, id: []const u8, now_ms: i64, delay_ms: i64) !*storage.QueuedSend {
    const entry = try find(store, id);
    if (entry.state != .queued) return error.SendAlreadySubmitted;
    entry.createdAtMs = now_ms;
    entry.dueAtMs = std.math.add(i64, now_ms, delay_ms) catch return error.InvalidSendDelay;
    try store.save();
    return entry;
}

test "send grace: delay range is bounded and zero remains explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(i64, 10000), try delay(j.object(a)));
    try std.testing.expectEqual(@as(i64, 0), try delay(try j.value(a, .{ .delaySeconds = 0 })));
    try std.testing.expectError(error.InvalidSendDelay, delay(try j.value(a, .{ .delaySeconds = 31 })));
    try std.testing.expectError(error.InvalidSendDelay, delay(try j.value(a, .{ .delaySeconds = -1 })));
}
