const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const storage = @import("store.zig");
const triage = @import("triage.zig");
const bounded = @import("../bounded.zig");
const item_engine = @import("batch_item.zig");

pub const Provider = struct {
    context: *anyopaque,
    labelsFn: *const fn (*anyopaque, std.mem.Allocator, *storage.Store, []const u8) anyerror![]const []const u8,
    modifyFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const []const u8, triage.Delta) anyerror![]const []const u8,
    fixtureCheckpoint: ?[]const u8 = null,
};
pub const Context = struct { io: std.Io, allocator: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, provider: Provider };

fn find(store: *storage.Store, token: []const u8) !*storage.Undo {
    for (store.state.undo) |*receipt| if (std.mem.eql(u8, receipt.token, token)) return receipt;
    return error.UndoNotFound;
}
const knownRejection = item_engine.knownRejection;
fn commitResult(ctx: Context, token: []const u8, position: usize, undoing: bool, labels: ?[]const []const u8, err: ?anyerror, preflight: bool) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var store = try storage.Store.open(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options);
    defer store.close();
    const item = &(try find(&store, token)).items[position];
    if (err) |failure| {
        item.errorCode = if (undoing and !preflight and !knownRejection(failure)) "UnknownOutcome" else @errorName(failure);
        if (!undoing) item.outcome = if (preflight or knownRejection(failure)) "rejected" else "unknown";
        if (!preflight and !knownRejection(failure)) {
            // Labels are uncertain; preserve immutable bytes but invalidate
            // filtered views until the next account refresh reconciles them.
            for (store.state.views) |*view| view.stale = true;
        }
    } else {
        item.errorCode = "";
        if (undoing) item.restored = true else item.outcome = "applied";
        if (labels) |updated| {
            store.applyLabels(item.messageId, updated);
            if (ctx.provider.fixtureCheckpoint) |checkpoint| {
                try store.setFixtureRecord(item.messageId, updated, checkpoint, false);
                store.state.fixtureCalls += 1;
            }
        }
        for (store.state.views) |*view| view.stale = true;
        store.state.generation += 1;
    }
    try store.save();
}
const ItemAdapter = struct {
    ctx: Context,
    token: []const u8,
    position: usize,
    fn labelsFn(raw: *anyopaque, a: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        var arena = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer arena.deinit();
        var store = try storage.Store.open(self.ctx.io, arena.allocator(), self.ctx.root, self.ctx.account, self.ctx.options);
        defer store.close();
        store.release();
        const actual = try self.ctx.provider.labelsFn(self.ctx.provider.context, a, &store, id);
        if (actual.len > 64) return error.TooManyLabels;
        const copied = try a.alloc([]const u8, actual.len);
        for (actual, copied) |label, *copy| copy.* = try a.dupe(u8, label);
        return copied;
    }
    fn prepareFn(raw: *anyopaque, id: []const u8, before: []const []const u8, delta: triage.Delta, undoing: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        var arena = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer arena.deinit();
        var store = try storage.Store.open(self.ctx.io, arena.allocator(), self.ctx.root, self.ctx.account, self.ctx.options);
        defer store.close();
        const item = &(try find(&store, self.token)).items[self.position];
        if (!undoing) item.* = try triage.inverse(arena.allocator(), id, before, delta);
        if (undoing) item.errorCode = "UnknownOutcome";
        try store.save();
    }
    fn modifyFn(raw: *anyopaque, a: std.mem.Allocator, id: []const u8, before: []const []const u8, delta: triage.Delta) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.ctx.provider.modifyFn(self.ctx.provider.context, a, id, before, delta);
    }
    fn commitFn(raw: *anyopaque, undoing: bool, labels: ?[]const []const u8, err: ?anyerror, preflight: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return commitResult(self.ctx, self.token, self.position, undoing, labels, err, preflight);
    }
};
fn modify(ctx: Context, token: []const u8, position: usize, id: []const u8, delta: triage.Delta, undoing: bool) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var adapter: ItemAdapter = .{ .ctx = ctx, .token = token, .position = position };
    try item_engine.run(.{ .context = &adapter, .labelsFn = ItemAdapter.labelsFn, .prepareFn = ItemAdapter.prepareFn, .modifyFn = ItemAdapter.modifyFn, .commitFn = ItemAdapter.commitFn }, arena.allocator(), id, delta, undoing);
}
fn result(ctx: Context, a: std.mem.Allocator, token: []const u8) !j.Value {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var store = try storage.Store.openCached(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options);
    defer store.close();
    const receipt = try find(&store, token);
    const summary = item_engine.summarize(receipt.items);
    return j.value(a, .{ .undoToken = receipt.token, .outcomes = receipt.items, .appliedCount = summary.appliedCount, .restoredCount = summary.restoredCount, .partial = summary.partial });
}
pub fn run(ctx: Context, a: std.mem.Allocator, request: j.Value, delta: triage.Delta) !j.Value {
    const values = j.get(request, "messageIds") orelse return error.MissingField;
    if (values != .array or values.array.items.len == 0 or values.array.items.len > 100) return error.InvalidBatchSize;
    const ids = try a.alloc([]const u8, values.array.items.len);
    for (values.array.items, ids, 0..) |value, *id, index| {
        id.* = try j.string(value);
        try bounded.identifier(id.*);
        for (ids[0..index]) |previous| if (std.mem.eql(u8, previous, id.*)) return error.DuplicateMessage;
    }
    const token = block: {
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const sa = arena.allocator();
        var store = try storage.Store.open(ctx.io, sa, ctx.root, ctx.account, ctx.options);
        defer store.close();
        const token = try store.nextId("undo");
        const items = try sa.alloc(storage.UndoItem, ids.len);
        for (ids, items) |id, *item| item.* = .{ .messageId = id };
        var receipts: std.ArrayList(storage.Undo) = .empty;
        try receipts.appendSlice(sa, store.state.undo[store.state.undo.len -| 15..]);
        try receipts.append(sa, .{ .token = token, .items = items });
        store.state.undo = receipts.items;
        try store.save();
        break :block try a.dupe(u8, token);
    };
    for (ids, 0..) |id, index| try modify(ctx, token, index, id, delta, false);
    return result(ctx, a, token);
}
pub fn undo(ctx: Context, a: std.mem.Allocator, request: j.Value) !j.Value {
    const token = try j.required(request, "undoToken");
    const receipt = snapshot: {
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        var store = try storage.Store.openCached(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options);
        defer store.close();
        break :snapshot try j.decode(storage.Undo, a, try j.value(a, (try find(&store, token)).*));
    };
    const selected = if (j.get(request, "messageIds") != null) try triage.pinned(a, request) else null;
    if (selected) |ids| for (ids) |id| {
        var found = false;
        for (receipt.items) |item| found = found or std.mem.eql(u8, item.messageId, id);
        if (!found) return error.UndoMessageNotFound;
    };
    for (receipt.items, 0..) |item, index| {
        if (selected) |ids| {
            var selected_item = false;
            for (ids) |id| selected_item = selected_item or std.mem.eql(u8, item.messageId, id);
            if (!selected_item) continue;
        }
        if (!item_engine.canUndo(item)) continue;
        try modify(ctx, token, index, item.messageId, .{ .add = item.addLabels, .remove = item.removeLabels }, true);
    }
    return result(ctx, a, token);
}
