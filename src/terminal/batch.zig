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
pub const Context = struct { io: std.Io, allocator: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, provider: Provider, access: @import("store_access.zig").Access = .{} };

fn find(store: *storage.Store, token: []const u8) !*storage.Undo {
    for (store.state.undo) |*receipt| if (std.mem.eql(u8, receipt.token, token)) return receipt;
    return error.UndoNotFound;
}
const knownRejection = item_engine.knownRejection;
const Progress = struct { may_have_mutated: bool = false };
fn commitResult(ctx: Context, token: []const u8, position: usize, undoing: bool, labels: ?[]const []const u8, err: ?anyerror, preflight: bool) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var store = try ctx.access.open(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options, false);
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
    progress: *Progress,
    fn labelsFn(raw: *anyopaque, a: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        var arena = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer arena.deinit();
        var store = try self.ctx.access.open(self.ctx.io, arena.allocator(), self.ctx.root, self.ctx.account, self.ctx.options, false);
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
        var store = try self.ctx.access.open(self.ctx.io, arena.allocator(), self.ctx.root, self.ctx.account, self.ctx.options, false);
        defer store.close();
        const item = &(try find(&store, self.token)).items[self.position];
        if (!undoing) item.* = try triage.inverse(arena.allocator(), id, before, delta);
        if (undoing) item.errorCode = "UnknownOutcome";
        try store.save();
    }
    fn modifyFn(raw: *anyopaque, a: std.mem.Allocator, id: []const u8, before: []const []const u8, delta: triage.Delta) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const previous = self.progress.may_have_mutated;
        self.progress.may_have_mutated = true;
        return self.ctx.provider.modifyFn(self.ctx.provider.context, a, id, before, delta) catch |err| {
            // A proven rejection does not make a later response allocation
            // ambiguous. Earlier successful or uncertain items still do.
            if (knownRejection(err)) self.progress.may_have_mutated = previous;
            return err;
        };
    }
    fn commitFn(raw: *anyopaque, undoing: bool, labels: ?[]const []const u8, err: ?anyerror, preflight: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return commitResult(self.ctx, self.token, self.position, undoing, labels, err, preflight);
    }
};
fn modify(ctx: Context, token: []const u8, position: usize, id: []const u8, delta: triage.Delta, undoing: bool, progress: *Progress) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var adapter: ItemAdapter = .{ .ctx = ctx, .token = token, .position = position, .progress = progress };
    try item_engine.run(.{ .context = &adapter, .labelsFn = ItemAdapter.labelsFn, .prepareFn = ItemAdapter.prepareFn, .modifyFn = ItemAdapter.modifyFn, .commitFn = ItemAdapter.commitFn }, arena.allocator(), id, delta, undoing);
}
fn result(ctx: Context, a: std.mem.Allocator, token: []const u8) !j.Value {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var store = try ctx.access.open(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options, true);
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
        var store = try ctx.access.open(ctx.io, sa, ctx.root, ctx.account, ctx.options, false);
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
    // An earlier item may already be applied when a later item or the final
    // receipt fails. Keep the durable token; never advertise a safe retry.
    var progress: Progress = .{};
    for (ids, 0..) |id, index| modify(ctx, token, index, id, delta, false, &progress) catch |err| return if (progress.may_have_mutated) error.UnknownOutcome else err;
    return result(ctx, a, token) catch |err| return if (progress.may_have_mutated) error.UnknownOutcome else err;
}
pub fn undo(ctx: Context, a: std.mem.Allocator, request: j.Value) !j.Value {
    const token = try j.required(request, "undoToken");
    const receipt = snapshot: {
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        var store = try ctx.access.open(ctx.io, arena.allocator(), ctx.root, ctx.account, ctx.options, true);
        defer store.close();
        break :snapshot try j.decode(storage.Undo, a, try j.value(a, (try find(&store, token)).*));
    };
    const selected = if (j.get(request, "messageIds") != null) try triage.pinned(a, request) else null;
    if (selected) |ids| for (ids) |id| {
        var found = false;
        for (receipt.items) |item| found = found or std.mem.eql(u8, item.messageId, id);
        if (!found) return error.UndoMessageNotFound;
    };
    var progress: Progress = .{};
    for (receipt.items, 0..) |item, index| {
        if (selected) |ids| {
            var selected_item = false;
            for (ids) |id| selected_item = selected_item or std.mem.eql(u8, item.messageId, id);
            if (!selected_item) continue;
        }
        if (!item_engine.canUndo(item)) continue;
        modify(ctx, token, index, item.messageId, .{ .add = item.addLabels, .remove = item.removeLabels }, true, &progress) catch |err| return if (progress.may_have_mutated) error.UnknownOutcome else err;
    }
    return result(ctx, a, token) catch |err| return if (progress.may_have_mutated) error.UnknownOutcome else err;
}

test "post-dispatch receipt: batch and undo retain durable results when output allocation fails" {
    const Peer = struct {
        output: *std.testing.FailingAllocator,
        writes: usize = 0,
        fn labels(_: *anyopaque, _: std.mem.Allocator, _: *storage.Store, _: []const u8) ![]const []const u8 {
            return &.{"INBOX"};
        }
        fn modify(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const []const u8, _: triage.Delta) ![]const []const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.writes += 1;
            self.output.fail_index = self.output.alloc_index;
            return &.{"STARRED"};
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/batch-receipt", .{tmp.sub_path});
    var failing = std.testing.FailingAllocator.init(a, .{});
    var peer: Peer = .{ .output = &failing };
    const context: Context = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = "self@example.test", .options = .{ .fixtures = true }, .provider = .{ .context = &peer, .labelsFn = Peer.labels, .modifyFn = Peer.modify } };
    const request = try j.value(a, .{ .messageIds = &.{"fixture-message"} });
    const delta: triage.Delta = .{ .add = &.{"STARRED"}, .remove = &.{} };
    try std.testing.expectError(error.UnknownOutcome, run(context, failing.allocator(), request, delta));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), peer.writes);
    const token = block: {
        var store = try storage.Store.openCached(std.testing.io, a, root, context.account, context.options);
        defer store.close();
        const receipt = store.state.undo[0];
        try std.testing.expectEqualStrings("fixture-message", receipt.items[0].messageId);
        try std.testing.expectEqualStrings("applied", receipt.items[0].outcome);
        break :block receipt.token;
    };
    failing = std.testing.FailingAllocator.init(a, .{});
    const undo_request = try j.value(a, .{ .undoToken = token });
    try std.testing.expectError(error.UnknownOutcome, undo(context, failing.allocator(), undo_request));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 2), peer.writes);
    {
        var store = try storage.Store.openCached(std.testing.io, a, root, context.account, context.options);
        defer store.close();
        try std.testing.expect((try find(&store, token)).items[0].restored);
    }
    _ = try undo(context, a, undo_request);
    try std.testing.expectEqual(@as(usize, 2), peer.writes);

    // Initial request allocation fails before the durable intent or provider.
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, run(context, unavailable.allocator(), request, delta));
    try std.testing.expectEqual(@as(usize, 2), peer.writes);
}

test "memory UX: batch allocation failure distinguishes first preflight from a prior mutation" {
    const Peer = struct {
        failing: *std.testing.FailingAllocator,
        reads: usize = 0,
        writes: usize = 0,
        fail_after_first: bool,
        fn labels(raw: *anyopaque, _: std.mem.Allocator, _: *storage.Store, _: []const u8) ![]const []const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            if (self.reads == (if (self.fail_after_first) @as(usize, 2) else 1)) {
                self.failing.fail_index = self.failing.alloc_index;
                return error.OutOfMemory;
            }
            return &.{"INBOX"};
        }
        fn modify(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const []const u8, _: triage.Delta) ![]const []const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.writes += 1;
            return &.{"STARRED"};
        }
    };
    for ([_]bool{ false, true }) |after_first| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/preflight", .{tmp.sub_path});
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer: Peer = .{ .failing = &failing, .fail_after_first = after_first };
        const ctx: Context = .{ .io = std.testing.io, .allocator = failing.allocator(), .root = root, .account = "self@example.test", .options = .{ .fixtures = true }, .provider = .{ .context = &peer, .labelsFn = Peer.labels, .modifyFn = Peer.modify } };
        const req = try j.value(a, .{ .messageIds = .{ "first", "second" } });
        try std.testing.expectError(if (after_first) error.UnknownOutcome else error.OutOfMemory, run(ctx, a, req, .{ .add = &.{"STARRED"}, .remove = &.{} }));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, @intFromBool(after_first)), peer.writes);
        var store = try storage.Store.openCached(std.testing.io, a, root, ctx.account, ctx.options);
        defer store.close();
        if (after_first) try std.testing.expectEqualStrings("applied", store.state.undo[0].items[0].outcome);
    }
}

test "memory UX: undo without eligible mutations keeps a result allocation failure ordinary" {
    const Peer = struct {
        root: []const u8,
        reads: usize = 0,
        fn open(raw: *anyopaque, a: std.mem.Allocator, account: []const u8, readonly: bool) !storage.Store {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (readonly) {
                self.reads += 1;
                if (self.reads == 2) return error.OutOfMemory;
            }
            return storage.Store.openCached(std.testing.io, a, self.root, account, .{ .fixtures = true });
        }
        fn labels(_: *anyopaque, _: std.mem.Allocator, _: *storage.Store, _: []const u8) ![]const []const u8 {
            return error.UnexpectedProviderCall;
        }
        fn modify(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const []const u8, _: triage.Delta) ![]const []const u8 {
            return error.UnexpectedProviderCall;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/empty-undo", .{tmp.sub_path});
    const account = "self@example.test";
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
        defer store.close();
        store.state.undo = try a.dupe(storage.Undo, &.{.{ .token = "nothing-applied", .items = &.{} }});
        try store.save();
    }
    var peer: Peer = .{ .root = root };
    const ctx: Context = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = account, .options = .{ .fixtures = true }, .provider = .{ .context = &peer, .labelsFn = Peer.labels, .modifyFn = Peer.modify }, .access = .{ .context = &peer, .openFn = Peer.open } };
    try std.testing.expectError(error.OutOfMemory, undo(ctx, a, try j.value(a, .{ .undoToken = "nothing-applied" })));
    try std.testing.expectEqual(@as(usize, 2), peer.reads);
}
