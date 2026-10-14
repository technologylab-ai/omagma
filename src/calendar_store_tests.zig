const std = @import("std");
const persistence = @import("terminal/calendar_store.zig");
const service = @import("terminal/calendar_service.zig");
const provider = @import("terminal/calendar_provider.zig");
const plan = @import("terminal/calendar_plan.zig");
const invitation = @import("terminal/calendar_invitation.zig");
const t = @import("terminal/calendar_types.zig");
const storage = @import("terminal/store.zig");

const target: t.Target = .{ .account = "self@example.test", .calendar_id = "self@example.test" };
const calendar: t.Calendar = .{ .target = target, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true, .owned_scope_verified = true };

fn noNetwork(_: *anyopaque, _: std.mem.Allocator, _: provider.Request) anyerror!service.Response {
    return error.UnexpectedNetworkRequest;
}
fn host(a: std.mem.Allocator, root: []const u8) persistence.Host {
    return .{ .io = std.testing.io, .allocator = std.testing.allocator, .result_allocator = a, .root = root, .account = target.account, .options = .{ .fixtures = true } };
}
fn review(a: std.mem.Allocator, store: *persistence.Host, operation_id: []const u8) !service.Review {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/terminal/calendar/single-utc.ics", a, .limited(t.Limits.source_bytes));
    const source = try invitation.parse(a, raw, target.account, &.{});
    const prepared: service.InvitationPlan = .{
        .calendar = calendar,
        .source = source,
        .span = try invitation.resolveSpan(source, null, null),
        .time_error = "",
        .lookup = .{ .target = target, .uid = source.uid, .events = &.{}, .complete = true },
        .state = .{},
        .decision = .import_missing,
        .writable = true,
    };
    const instance: service.Service = .{ .a = a, .grants = .{ .account = target.account, .calendar_list = true, .read_events = true, .write_owned = true }, .transport = .{ .context = store, .sendFn = noNetwork }, .persistence = store.persistence(), .now_ms = 1000 };
    return instance.prepareReview(prepared, operation_id);
}

test "calendar store: review and uncertain claim survive restart and prevent a second write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/calendar", .{tmp.sub_path});
    var first = host(a, root);
    const prepared = try review(a, &first, "review-1");
    const before = first.persistence();
    try before.preserveFn(before.context, prepared);
    try std.testing.expect((try before.load(a, prepared.intent.identity)).operation == null);
    const claimed = try before.journal.claim(prepared.intent);
    try std.testing.expect(claimed.fresh);
    try std.testing.expectEqual(.unknown, claimed.operation.state);

    var reopened = host(a, root);
    const restored = try reopened.loadReview(a, target, "review-1");
    try std.testing.expectEqualSlices(u8, &prepared.review_hash, &restored.review_hash);
    try std.testing.expectEqualStrings(prepared.source.source, restored.source.source);
    try std.testing.expectEqualStrings(prepared.request.body.?, restored.request.body.?);
    const after = reopened.persistence();
    try std.testing.expect(!(try after.journal.claim(restored.intent)).fresh);
    const different = try review(a, &reopened, "review-2");
    try std.testing.expectError(error.CalendarOperationPending, after.preserveFn(after.context, different));
    try std.testing.expectError(error.OperationConflict, after.journal.claim(different.intent));
    var applied = claimed.operation;
    applied.state = .applied;
    applied.provider_id = "provider-event-1";
    try after.journal.record(applied);
    const recorded = try before.load(a, prepared.intent.identity);
    try std.testing.expectEqual(.applied, recorded.operation.?.state);
    try std.testing.expectEqualStrings("provider-event-1", recorded.tracked.?.event_id);
    try std.testing.expectEqualSlices(u8, &prepared.intent.source_hash, &recorded.tracked.?.source_hash);
    try after.journal.record(applied);
    applied.provider_id = "different-event";
    try std.testing.expectError(error.UnknownOutcome, after.journal.record(applied));
}

test "calendar store: account calendar operation and fixed document names stay isolated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/isolation", .{tmp.sub_path});
    var first = host(a, root);
    const prepared = try review(a, &first, "review-1");
    const backend = first.persistence();
    try backend.preserveFn(backend.context, prepared);
    try std.testing.expectError(error.CalendarReviewNotFound, first.loadReview(a, .{ .account = target.account, .calendar_id = "different-calendar" }, "review-1"));
    try std.testing.expectError(error.CalendarReviewNotFound, first.loadReview(a, target, "different-operation"));
    try std.testing.expectError(error.CalendarAccountMismatch, first.loadReview(a, .{ .account = "other@example.test", .calendar_id = target.calendar_id }, "review-1"));
    var other = first;
    other.account = "other@example.test";
    try std.testing.expectError(error.CalendarReviewNotFound, other.loadReview(a, .{ .account = other.account, .calendar_id = target.calendar_id }, "review-1"));
    var store = try storage.Store.open(std.testing.io, a, root, target.account, first.options);
    defer store.close();
    try std.testing.expectError(error.InvalidStoreDocument, store.readDocument(a, "../calendar-state.json", 1));
    try std.testing.expectError(error.InvalidStoreDocument, store.writeDocument("index.json", "{}"));
    const stat = try store.dir.statFile(std.testing.io, "calendar-state.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0), stat.permissions.toMode() & 0o077);
}

test "calendar store: a concurrent completed action invalidates an older import before claim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/race", .{tmp.sub_path});
    var client_a = host(a, root);
    var client_b = host(a, root);
    const stale = try review(a, &client_a, "client-a");
    const winner = try review(a, &client_b, "client-b");
    const b = client_b.persistence();
    try b.preserveFn(b.context, winner);
    var applied = (try b.journal.claim(winner.intent)).operation;
    applied.state = .applied;
    applied.provider_id = "already-imported";
    try b.journal.record(applied);
    const slower = client_a.persistence();
    try slower.preserveFn(slower.context, stale);
    try std.testing.expectError(error.CalendarReviewStale, slower.journal.claim(stale.intent));
    const unchanged = try b.load(a, winner.intent.identity);
    try std.testing.expectEqualStrings("client-b", unchanged.operation.?.intent.operation_id);
    try std.testing.expectEqualStrings("already-imported", unchanged.tracked.?.event_id);
}

fn snapshot(index: i64) t.Snapshot {
    return .{ .target = target, .window = .{ .start_ms = 1791849600000 + index * 86400000, .end_ms = 1791936000000 + index * 86400000, .time_zone = "UTC" }, .events = &.{}, .fetched_at_ms = 1000 + index, .complete = true };
}
test "calendar store: snapshots replace exact windows retain four and reject partial overwrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/snapshots", .{tmp.sub_path});
    var first = host(a, root);
    const cache = first.cache();
    for (0..5) |i| try cache.saveFn(cache.context, snapshot(@intCast(i)));
    var reopened = host(a, root);
    const fresh = reopened.cache();
    try std.testing.expect(try fresh.loadFn(fresh.context, a, target, snapshot(0).window) == null);
    for (1..5) |i| try std.testing.expect(try fresh.loadFn(fresh.context, a, target, snapshot(@intCast(i)).window) != null);
    var replacement = snapshot(2);
    replacement.fetched_at_ms = 3000;
    try fresh.saveFn(fresh.context, replacement);
    replacement.complete = false;
    try std.testing.expectError(error.CalendarCacheMismatch, fresh.saveFn(fresh.context, replacement));
    replacement.complete = true;
    replacement.stale = true;
    try std.testing.expectError(error.CalendarCacheMismatch, fresh.saveFn(fresh.context, replacement));
    try std.testing.expectEqual(@as(i64, 3000), (try cache.loadFn(cache.context, a, target, snapshot(2).window)).?.fetched_at_ms);
    var other_zone = snapshot(2).window;
    other_zone.time_zone = "Europe/Vienna";
    try std.testing.expect(try fresh.loadFn(fresh.context, a, target, other_zone) == null);
}

test "calendar store: failed durable claim cannot create an operation or replace the saved review" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/quota", .{tmp.sub_path});
    var first = host(a, root);
    first.options.disk_limit = 64 * 1024;
    first.options.disk_limit_set = true;
    const prepared = try review(a, &first, "review-1");
    const backend = first.persistence();
    try backend.preserveFn(backend.context, prepared);
    {
        var store = try storage.Store.open(std.testing.io, a, root, target.account, first.options);
        defer store.close();
        const remaining = first.options.disk_limit - try store.diskBytes();
        // Simulate other protected local data consuming the final free bytes.
        const occupied = try a.alloc(u8, remaining);
        @memset(occupied, 'x');
        try store.write("protected-fixture.bin", occupied);
    }
    try std.testing.expectError(error.DiskQuotaExceeded, backend.journal.claim(prepared.intent));
    const current = try backend.load(a, prepared.intent.identity);
    try std.testing.expect(current.operation == null);
    const saved = try first.loadReview(a, target, "review-1");
    try std.testing.expectEqualSlices(u8, &prepared.review_hash, &saved.review_hash);
}

test "calendar store: failed applied receipt retains durable uncertainty and exact review" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/receipt-failure", .{tmp.sub_path});
    var first = host(a, root);
    first.options.disk_limit = 64 * 1024;
    first.options.disk_limit_set = true;
    const prepared = try review(a, &first, "review-1");
    const backend = first.persistence();
    try backend.preserveFn(backend.context, prepared);
    var applied = (try backend.journal.claim(prepared.intent)).operation;
    applied.state = .applied;
    applied.provider_id = "remote-write-already-happened";
    {
        var store = try storage.Store.open(std.testing.io, a, root, target.account, first.options);
        defer store.close();
        const occupied = try a.alloc(u8, first.options.disk_limit - try store.diskBytes());
        @memset(occupied, 'x');
        try store.write("protected-fixture.bin", occupied);
    }
    try std.testing.expectError(error.UnknownOutcome, backend.journal.record(applied));
    var reopened = host(a, root);
    const after = reopened.persistence();
    const current = try after.load(a, prepared.intent.identity);
    try std.testing.expectEqual(.unknown, current.operation.?.state);
    try std.testing.expect(current.tracked == null);
    try std.testing.expect(!(try after.journal.claim(prepared.intent)).fresh);
    const exact = try reopened.loadReview(a, target, "review-1");
    try std.testing.expectEqualSlices(u8, &prepared.review_hash, &exact.review_hash);
    try std.testing.expectEqualStrings(prepared.source.source, exact.source.source);
}
