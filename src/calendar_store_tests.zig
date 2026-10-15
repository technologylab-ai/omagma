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

fn ordinaryReview(a: std.mem.Allocator, store: *persistence.Host, operation_id: []const u8, calendar_id: []const u8, notes: []const u8) !service.Review {
    var destination = calendar;
    destination.target.calendar_id = calendar_id;
    const prepared: @import("terminal/calendar_event.zig").Prepared = .{
        .draft = .{ .summary = "A normal meeting", .start = "2026-10-24T10:00", .end = "2026-10-24T11:00", .timeZone = "UTC", .description = notes },
        .span = .{ .start = .{ .kind = .instant, .value = try t.time.rfc3339("2026-10-24T10:00:00Z"), .zone = "UTC" }, .end = .{ .kind = .instant, .value = try t.time.rfc3339("2026-10-24T11:00:00Z"), .zone = "UTC" } },
        .send_updates = .none,
    };
    const instance: service.Service = .{ .a = a, .grants = .{ .account = target.account, .calendar_list = true, .read_events = true, .write_owned = true }, .transport = .{ .context = store, .sendFn = noNetwork }, .persistence = store.persistence(), .now_ms = 1000 };
    return instance.prepareEventReview(destination, prepared, operation_id, "", "");
}

test "calendar store: ordinary completed events recycle count capacity and preserve imported invitation tracking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ordinary-count", .{tmp.sub_path});
    var saved = host(a, root);
    const backend = saved.persistence();
    const imported = try review(a, &saved, "import-first");
    try backend.preserveFn(backend.context, imported);
    var imported_operation = (try backend.journal.claim(imported.intent)).operation;
    imported_operation.state = .applied;
    imported_operation.provider_id = "imported-provider-id";
    try backend.journal.record(imported_operation);
    const imported_receipt = (try saved.loadReceipt(a, target, "import-first")).?;
    try std.testing.expect(!imported_receipt.ordinary);
    try std.testing.expectEqualSlices(u8, &imported.review_hash, &imported_receipt.review_hash);
    for (0..persistence.max_identities + 8) |index| {
        var iteration = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer iteration.deinit();
        const ia = iteration.allocator();
        var current = host(ia, root);
        const store = current.persistence();
        const prepared = try ordinaryReview(ia, &current, try std.fmt.allocPrint(ia, "ordinary-{d}", .{index}), target.calendar_id, "");
        try store.preserveFn(store.context, prepared);
        var operation = (try store.journal.claim(prepared.intent)).operation;
        operation.state = .applied;
        operation.provider_id = prepared.intent.event_id;
        try store.journal.record(operation);
        try std.testing.expect((try store.load(ia, prepared.intent.identity)).tracked == null);
        const receipt = (try current.loadReceipt(ia, target, prepared.intent.operation_id)).?;
        try std.testing.expect(receipt.ordinary);
        try std.testing.expectEqualSlices(u8, &prepared.review_hash, &receipt.review_hash);
        try std.testing.expectError(error.CalendarReviewNotFound, current.loadReview(ia, target, prepared.intent.operation_id));
    }
    try std.testing.expect(try saved.loadReceipt(a, target, "ordinary-0") == null);
    const retained = try backend.load(a, imported.intent.identity);
    try std.testing.expectEqualStrings("imported-provider-id", retained.tracked.?.event_id);
    try std.testing.expectEqualSlices(u8, &imported.intent.source_hash, &retained.tracked.?.source_hash);
    // A new shared invitation still has room after more than 256 ordinary
    // operations; its older UID remains protected against resurrection.
    const shared = try review(a, &saved, "shared-invitation-later");
    try backend.preserveFn(backend.context, shared);
    try std.testing.expectError(error.CalendarReviewStale, backend.journal.claim(shared.intent));
}

test "calendar store: large notes evict drafts by bytes while an unknown request and its final receipt reservation survive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ordinary-bytes", .{tmp.sub_path});
    const notes = try a.alloc(u8, 40 * 1024);
    @memset(notes, 'n');
    var saved = host(a, root);
    const backend = saved.persistence();
    const pending = try ordinaryReview(a, &saved, "pending-large-notes", "pending-calendar", notes);
    try backend.preserveFn(backend.context, pending);
    var operation = (try backend.journal.claim(pending.intent)).operation;
    for (0..40) |index| {
        var iteration = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer iteration.deinit();
        const ia = iteration.allocator();
        var current = host(ia, root);
        const prepared = try ordinaryReview(ia, &current, try std.fmt.allocPrint(ia, "large-draft-{d}", .{index}), target.calendar_id, notes);
        const persistence_api = current.persistence();
        try persistence_api.preserveFn(persistence_api.context, prepared);
    }
    try std.testing.expectError(error.CalendarReviewNotFound, saved.loadReview(a, target, "large-draft-0"));
    const pending_target: t.Target = .{ .account = target.account, .calendar_id = "pending-calendar" };
    const exact = try saved.loadReview(a, pending_target, "pending-large-notes");
    try std.testing.expectEqualStrings(pending.request.body.?, exact.request.body.?);
    try std.testing.expectEqualSlices(u8, &pending.review_hash, &exact.review_hash);
    {
        var disk = try storage.Store.open(std.testing.io, a, root, target.account, saved.options);
        defer disk.close();
        const raw = (try disk.readDocument(a, "calendar-state.json", persistence.state_bytes)).?;
        try std.testing.expect(raw.len + persistence.final_receipt_reserve <= persistence.state_bytes);
        const value = try std.json.parseFromSliceLeaky(@import("terminal/json.zig").Value, a, raw, .{});
        const entries = @import("terminal/json.zig").get(value, "entries").?.array.items;
        try std.testing.expect(entries.len < 40 and entries.len > 1);
    }
    operation.state = .applied;
    operation.provider_id = pending.intent.event_id;
    try backend.journal.record(operation);
    const receipt = (try saved.loadReceipt(a, pending_target, "pending-large-notes")).?;
    try std.testing.expectEqual(.applied, receipt.operation.state);
    try std.testing.expect(try saved.loadPending(a, pending_target, "") == null);
}

test "calendar store: identical retry attempt is claimed once and survives restart before terminal compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ordinary-retry", .{tmp.sub_path});
    var saved = host(a, root);
    const backend = saved.persistence();
    const prepared = try ordinaryReview(a, &saved, "retry-saved-request", target.calendar_id, "Keep these exact notes.");
    try backend.preserveFn(backend.context, prepared);
    _ = try backend.journal.claim(prepared.intent);
    const retry = try backend.journal.retry(prepared.intent, 1);
    try std.testing.expect(retry.fresh);
    try std.testing.expectEqual(@as(u32, 1), retry.operation.attempt);
    var reopened = host(a, root);
    const later = reopened.persistence();
    try std.testing.expect(!(try later.journal.retry(prepared.intent, 1)).fresh);
    try std.testing.expectError(error.InvalidCalendarRetry, later.journal.retry(prepared.intent, 3));
    const pending = (try reopened.loadPending(a, target, "")).?;
    try std.testing.expectEqualStrings(prepared.request.body.?, pending.review.request.body.?);
    try std.testing.expectEqual(@as(u32, 1), pending.operation.attempt);
    var stale_refusal = pending.operation;
    stale_refusal.attempt = 0;
    stale_refusal.state = .rejected;
    try std.testing.expectError(error.UnknownOutcome, later.journal.record(stale_refusal));
    try std.testing.expectEqual(.unknown, (try later.load(a, prepared.intent.identity)).operation.?.state);
    var archived = pending.operation;
    archived.state = .archived;
    try later.journal.record(archived);
    try std.testing.expect(!(try later.journal.retry(prepared.intent, 2)).fresh);
    try std.testing.expect(try reopened.loadPending(a, target, "") == null);
    const receipt = (try reopened.loadReceipt(a, target, prepared.intent.operation_id)).?;
    try std.testing.expectEqual(.archived, receipt.operation.state);
    try std.testing.expectEqual(@as(u32, 1), receipt.operation.attempt);
}
