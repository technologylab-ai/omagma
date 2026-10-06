const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const storage = @import("store.zig");
const triage = @import("triage.zig");
const bounded = @import("../bounded.zig");

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
fn cloneLabels(a: std.mem.Allocator, labels: []const []const u8) ![]const []const u8 {
    if (labels.len > 64) return error.TooManyLabels;
    const cloned_labels = try a.alloc([]const u8, labels.len);
    for (labels, cloned_labels) |label, *copy| copy.* = try a.dupe(u8, label);
    return cloned_labels;
}
fn knownRejection(err: anyerror) bool {
    return switch (err) {
        error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.InvalidGrant, error.MessageNotFound, error.RateLimited, error.InvalidLabel, error.LabelNotFound, error.TooManyLabels, error.InvalidIdentifier, error.WrongAccount, error.GrantClientMismatch => true,
        else => false,
    };
}
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
fn modify(ctx: Context, token: []const u8, position: usize, id: []const u8, delta: triage.Delta, undoing: bool) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var before: []const []const u8 = undefined;
    {
        var read_arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer read_arena.deinit();
        var store = try storage.Store.open(ctx.io, read_arena.allocator(), ctx.root, ctx.account, ctx.options);
        defer store.close();
        store.release();
        const actual = ctx.provider.labelsFn(ctx.provider.context, a, &store, id) catch |err| {
            try commitResult(ctx, token, position, undoing, null, err, true);
            return;
        };
        before = try cloneLabels(a, actual);
    }
    if (delta.add.len + delta.remove.len == 0) {
        try commitResult(ctx, token, position, undoing, before, null, false);
        return;
    }
    {
        var journal_arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer journal_arena.deinit();
        var store = try storage.Store.open(ctx.io, journal_arena.allocator(), ctx.root, ctx.account, ctx.options);
        defer store.close();
        const item = &(try find(&store, token)).items[position];
        if (!undoing) item.* = try triage.inverse(journal_arena.allocator(), id, before, delta);
        // Durable pending/undo uncertainty is recorded before dispatch.
        if (undoing) item.errorCode = "UnknownOutcome";
        try store.save();
    }
    const updated = ctx.provider.modifyFn(ctx.provider.context, a, id, before, delta) catch |err| {
        try commitResult(ctx, token, position, undoing, null, err, false);
        return;
    };
    commitResult(ctx, token, position, undoing, updated, null, false) catch return error.UnknownOutcome;
}
fn result(ctx: Context, a: std.mem.Allocator, token: []const u8) !j.Value {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var store = try storage.Store.openCached(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options);
    defer store.close();
    const receipt = try find(&store, token);
    var applied: usize = 0;
    var restored: usize = 0;
    for (receipt.items) |item| {
        if (std.mem.eql(u8, item.outcome, "applied")) applied += 1;
        if (item.restored) restored += 1;
    }
    return j.value(a, .{ .undoToken = receipt.token, .outcomes = receipt.items, .appliedCount = applied, .restoredCount = restored, .partial = applied != receipt.items.len });
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
    for (receipt.items, 0..) |item, index| {
        if (!std.mem.eql(u8, item.outcome, "applied") or item.restored or std.mem.eql(u8, item.errorCode, "UnknownOutcome")) continue;
        try modify(ctx, token, index, item.messageId, .{ .add = item.addLabels, .remove = item.removeLabels }, true);
    }
    return result(ctx, a, token);
}
