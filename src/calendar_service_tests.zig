const std = @import("std");
const t = @import("terminal/calendar_types.zig");
const provider = @import("terminal/calendar_provider.zig");
const plan = @import("terminal/calendar_plan.zig");
const svc = @import("terminal/calendar_service.zig");
const invitation = @import("terminal/calendar_invitation.zig");
const j = @import("terminal/json.zig");

test {
    std.testing.refAllDecls(svc);
}

const target: t.Target = .{ .account = "self@example.test", .calendar_id = "self@example.test" };
const calendar: t.Calendar = .{ .target = target, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true, .owned_scope_verified = true };
const empty = "{\"items\":[]}";
const Step = struct {
    kind: provider.OperationKind,
    body: []const u8 = empty,
    status: u16 = 200,
    lost: bool = false,
    account: []const u8 = target.account,
};
const Host = struct {
    steps: []const Step,
    index: usize = 0,
    writes: usize = 0,
    claims: usize = 0,
    preserves: usize = 0,
    cached_writes: usize = 0,
    state: svc.State = .{},
    cached: ?t.Snapshot = null,
    fail_claim: bool = false,
    fail_record: bool = false,
    fail_preserve: bool = false,
    fail_cache: bool = false,
    last_request: ?provider.Request = null,

    fn send(context: *anyopaque, a: std.mem.Allocator, request: provider.Request) anyerror!svc.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = a;
        if (self.index == self.steps.len) return error.UnexpectedCalendarRequest;
        const step = self.steps[self.index];
        self.index += 1;
        try std.testing.expectEqual(step.kind, request.kind);
        try std.testing.expect(request.target.eql(target) or request.kind == .calendar_list or request.kind == .free_busy);
        self.last_request = request;
        if (request.kind.mutating()) {
            try std.testing.expect(self.state.operation != null);
            try std.testing.expectEqual(.unknown, self.state.operation.?.state);
            try std.testing.expectEqual(@as(usize, 1), self.claims);
            try std.testing.expectEqual(@as(usize, 1), self.preserves);
            try std.testing.expect((try request.bindIntent(self.state.operation.?.intent)).eql(self.state.operation.?.intent));
            self.writes += 1;
        }
        if (step.lost) return error.ConnectionResetByPeer;
        return .{ .account = step.account, .status = step.status, .body = step.body };
    }
    fn load(context: *anyopaque, a: std.mem.Allocator, identity: plan.Identity) anyerror!svc.State {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = a;
        _ = identity;
        return self.state;
    }
    fn preserve(context: *anyopaque, review: svc.Review) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fail_preserve) return error.StorageUnavailable;
        try std.testing.expect(review.source.source.len != 0);
        self.preserves += 1;
    }
    fn claim(context: *anyopaque, intent: plan.Intent) anyerror!plan.Claim {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fail_claim) return error.StorageUnavailable;
        if (self.state.operation) |operation| {
            if (std.mem.eql(u8, operation.intent.operation_id, intent.operation_id)) return .{ .operation = operation, .fresh = false };
            if (operation.state == .unknown) return error.CalendarOperationPending;
        }
        self.claims += 1;
        self.state.operation = .{ .intent = intent };
        return .{ .operation = self.state.operation.?, .fresh = true };
    }
    fn record(context: *anyopaque, operation: plan.Operation) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fail_record) return error.StorageUnavailable;
        self.state.operation = operation;
        if (operation.state == .applied) self.state.tracked = .{ .identity = operation.intent.identity, .event_id = operation.provider_id, .version = operation.intent.version, .source_hash = operation.intent.source_hash };
    }
    fn cacheLoad(context: *anyopaque, a: std.mem.Allocator, requested_target: t.Target, window: t.Window) anyerror!?t.Snapshot {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = a;
        _ = requested_target;
        _ = window;
        return self.cached;
    }
    fn cacheSave(context: *anyopaque, snapshot: t.Snapshot) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expect(snapshot.complete and !snapshot.stale);
        if (self.fail_cache) return error.DiskQuotaExceeded;
        self.cached = snapshot;
        self.cached_writes += 1;
    }
    fn service(self: *@This(), a: std.mem.Allocator) svc.Service {
        return .{ .a = a, .grants = .{ .account = target.account, .calendar_list = true, .read_events = true, .write_owned = true }, .transport = .{ .context = self, .sendFn = send }, .persistence = .{ .context = self, .journal = .{ .context = self, .claimFn = claim, .recordFn = record }, .loadFn = load, .preserveFn = preserve }, .cache = .{ .context = self, .loadFn = cacheLoad, .saveFn = cacheSave }, .now_ms = 1000 };
    }
};
fn fixture(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/fixtures/terminal/calendar/{s}", .{name}), a, .limited(t.Limits.response_bytes));
}
fn prepare(host: *Host, a: std.mem.Allocator) !svc.Review {
    const service = host.service(a);
    return service.prepareReview(try service.invitationPlan(calendar, try fixture(a, "single-utc.ics"), &.{}, .{}), "calendar-service-1");
}
fn tracked(a: std.mem.Allocator) !plan.Tracked {
    const source = try invitation.parse(a, try fixture(a, "single-utc.ics"), target.account, &.{});
    return .{ .identity = .{ .target = target, .uid = source.uid }, .event_id = "fixture-imported-event", .version = source.version, .source_hash = source.source_hash };
}
fn page(a: std.mem.Allocator, event_bytes: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"items\":[{s}]}}", .{event_bytes});
}
fn dayWindow() !t.Window {
    return .{ .start_ms = try t.time.rfc3339("2026-10-13T00:00:00Z"), .end_ms = try t.time.rfc3339("2026-10-14T00:00:00Z"), .time_zone = "UTC" };
}

test "calendar service: calendar ownership and freebusy remain separate permission evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Host = .{ .steps = &.{.{ .kind = .calendar_list, .body = try fixture(a, "service-calendars.json") }} };
    var service = host.service(a);
    service.grants.read_events = false;
    const list = try service.list();
    try std.testing.expect(list.complete);
    try std.testing.expectEqual(@as(usize, 5), list.calendars.len);
    try std.testing.expect(service.grants.canWrite(list.calendars[0]));
    try std.testing.expect(service.grants.canWrite(list.calendars[1]));
    try std.testing.expect(!service.grants.canWrite(list.calendars[2]));
    try std.testing.expect(!service.grants.canRead(list.calendars[2]));
    service.grants.write_shared = true;
    try std.testing.expect(service.grants.canWrite(list.calendars[2]));
    try std.testing.expect(service.grants.canRead(list.calendars[3]));
    try std.testing.expect(!service.grants.canWrite(list.calendars[3]));
    try std.testing.expectError(error.CalendarReadPermissionRequired, service.agenda(list.calendars[4], try dayWindow()));
    try std.testing.expectError(error.CalendarFreeBusyPermissionRequired, service.freeBusy(list.calendars[4], try dayWindow()));
    var foreign = calendar;
    foreign.target.account = "other@example.test";
    try std.testing.expectError(error.CalendarAccountMismatch, service.event(foreign, "event"));
    try std.testing.expectEqual(@as(usize, 1), host.index);
}

test "calendar service: claim precedes dispatch and a repeated applied import never writes again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup }, .{ .kind = .event_lookup }, .{ .kind = .import_event, .body = try fixture(a, "service-imported.json") } } };
    const review = try prepare(&host, a);
    try std.testing.expectEqual(@as(usize, 0), host.claims);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
    const result = try host.service(a).apply(review, review.confirmation());
    try std.testing.expectEqual(.applied, result.operation.state);
    try std.testing.expectEqualStrings("fixture-imported-event", host.state.tracked.?.event_id);
    try std.testing.expectEqual(.applied, (try host.service(a).apply(review, review.confirmation())).operation.state);
    try std.testing.expectEqual(@as(usize, 1), host.writes);
    try std.testing.expectEqual(@as(usize, 3), host.index);
}

test "calendar service: source account destination version and bytes bind the reviewed write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Host = .{ .steps = &.{.{ .kind = .event_lookup }} };
    const review = try prepare(&host, a);
    var confirmation = review.confirmation();
    confirmation.target.calendar_id = "different-calendar";
    try std.testing.expectError(error.CalendarReviewMismatch, host.service(a).apply(review, confirmation));
    var changed = review;
    changed.intent.version.sequence += 1;
    try std.testing.expectError(error.CalendarReviewMismatch, host.service(a).apply(changed, review.confirmation()));
    changed = review;
    changed.request.body = "{}";
    try std.testing.expectError(error.CalendarReviewMismatch, host.service(a).apply(changed, review.confirmation()));
    changed = review;
    changed.source.source = "changed source bytes";
    try std.testing.expectError(error.CalendarReviewMismatch, host.service(a).apply(changed, review.confirmation()));
    changed = review;
    changed.previous = .{ .target = review.calendar.target, .id = "fabricated", .summary = "Misleading previous state" };
    try std.testing.expectError(error.CalendarReviewMismatch, host.service(a).apply(changed, review.confirmation()));
    confirmation = review.confirmation();
    confirmation.target.account = "another@example.test";
    try std.testing.expectError(error.CalendarReviewMismatch, host.service(a).apply(review, confirmation));
    try std.testing.expectEqual(@as(usize, 0), host.claims);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
}

test "calendar service: interrupted import stays unknown across missing lookup then reconciles exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup }, .{ .kind = .event_lookup }, .{ .kind = .import_event, .lost = true }, .{ .kind = .event_lookup }, .{ .kind = .event_lookup, .body = try page(a, try fixture(a, "service-imported.json")) } } };
    const review = try prepare(&host, a);
    try std.testing.expectEqual(.unknown, (try host.service(a).apply(review, review.confirmation())).operation.state);
    try std.testing.expectEqual(.unknown, (try host.service(a).apply(review, review.confirmation())).operation.state);
    const resolved = try host.service(a).reconcile(review);
    try std.testing.expectEqual(.applied, resolved.operation.state);
    try std.testing.expect(resolved.reconciled);
    try std.testing.expectEqual(@as(usize, 1), host.writes);
    try std.testing.expectEqual(@as(usize, 1), host.claims);
}

test "calendar service: storage failures prevent dispatch and preserve unknown after provider success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]enum { preserve, claim, record }{ .preserve, .claim, .record }) |failure| {
        var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup }, .{ .kind = .event_lookup }, .{ .kind = .import_event, .body = try fixture(a, "service-imported.json") } }, .fail_preserve = failure == .preserve, .fail_claim = failure == .claim, .fail_record = failure == .record };
        const review = try prepare(&host, a);
        if (failure == .record) {
            try std.testing.expectError(error.UnknownOutcome, host.service(a).apply(review, review.confirmation()));
            try std.testing.expectEqual(@as(usize, 1), host.writes);
            try std.testing.expectEqual(.unknown, host.state.operation.?.state);
            try std.testing.expect(host.state.tracked == null);
        } else {
            try std.testing.expectError(error.StorageUnavailable, host.service(a).apply(review, review.confirmation()));
            try std.testing.expectEqual(@as(usize, 0), host.writes);
            try std.testing.expect(host.state.operation == null);
        }
    }
}

test "calendar service: lookup exhausts empty pages and rejects cycles without inferring absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var steps: [t.Limits.pages]Step = undefined;
    for (&steps, 0..) |*step, index| step.* = .{ .kind = .event_lookup, .body = try std.fmt.allocPrint(a, "{{\"items\":[],\"nextPageToken\":\"page-{d}\"}}", .{index}) };
    var host: Host = .{ .steps = &steps };
    const planned = try host.service(a).invitationPlan(calendar, try fixture(a, "single-utc.ics"), &.{}, .{});
    try std.testing.expectEqual(.lookup_incomplete, std.meta.activeTag(planned.decision));
    try std.testing.expectError(error.CalendarActionUnavailable, host.service(a).prepareReview(planned, "no-absent-import"));
    try std.testing.expectEqual(t.Limits.pages, host.index);
    try std.testing.expect(std.mem.indexOf(u8, host.last_request.?.url, "showHiddenInvitations=true&showDeleted=true") != null);
    var cycling: Host = .{ .steps = &.{ .{ .kind = .event_lookup, .body = "{\"items\":[],\"nextPageToken\":\"A\"}" }, .{ .kind = .event_lookup, .body = "{\"items\":[],\"nextPageToken\":\"B\"}" }, .{ .kind = .event_lookup, .body = "{\"items\":[],\"nextPageToken\":\"A\"}" } } };
    try std.testing.expectError(error.CalendarPageMismatch, cycling.service(a).lookup(calendar, "uid"));
}

test "calendar service: Calendar HTTP errors and credential identity are never Gmail errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Host = .{ .steps = &.{ .{ .kind = .event_get, .status = 404, .body = "{\"error\":{\"errors\":[{\"reason\":\"notFound\"}]}}" }, .{ .kind = .event_get, .status = 403, .body = "{\"error\":{\"errors\":[{\"reason\":\"userRateLimitExceeded\"}]}}" }, .{ .kind = .event_get, .account = "other@example.test" } } };
    try std.testing.expectError(error.CalendarNotFound, host.service(a).event(calendar, "missing"));
    try std.testing.expectError(error.CalendarRateLimited, host.service(a).event(calendar, "limited"));
    try std.testing.expectError(error.CalendarAccountMismatch, host.service(a).event(calendar, "cross-account"));
}

test "calendar service: failed agenda refresh retains complete stale cache with explicit error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const window = try dayWindow();
    const old: t.Event = .{ .target = target, .id = "old-event", .summary = "Retained" };
    var host: Host = .{ .steps = &.{ .{ .kind = .agenda, .body = "{\"items\":[],\"nextPageToken\":\"next\"}" }, .{ .kind = .agenda, .status = 503 }, .{ .kind = .agenda } }, .cached = .{ .target = target, .window = window, .events = &.{old}, .fetched_at_ms = 100, .complete = true } };
    const result = try host.service(a).agenda(calendar, window);
    try std.testing.expect(result.snapshot.stale);
    try std.testing.expectEqualStrings("CalendarUnavailable", result.refresh_error);
    try std.testing.expectEqualStrings("old-event", result.snapshot.events[0].id);
    try std.testing.expectEqual(@as(usize, 0), host.cached_writes);
    const fresh = try host.service(a).agenda(calendar, window);
    try std.testing.expect(!fresh.snapshot.stale and fresh.snapshot.complete);
    try std.testing.expectEqual(@as(usize, 0), fresh.snapshot.events.len);
    try std.testing.expectEqual(@as(usize, 1), host.cached_writes);
    try std.testing.expect(std.mem.indexOf(u8, host.last_request.?.url, "singleEvents=true&orderBy=startTime") != null);
}

test "calendar service: day and week retain civil boundaries across DST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone = try @import("terminal/timezone.zig").Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const binding: t.time.Binding = .{ .id = "Europe/Vienna", .zone = &zone };
    const spring = try svc.windowForDays(a, "2026-03-29", .day, binding);
    const autumn = try svc.windowForDays(a, "2026-10-25", .day, binding);
    const week = try svc.windowForDays(a, "2026-10-19", .week, binding);
    try std.testing.expectEqual(@as(i64, 23 * 3600000), spring.end_ms - spring.start_ms);
    try std.testing.expectEqual(@as(i64, 25 * 3600000), autumn.end_ms - autumn.start_ms);
    try std.testing.expectEqual(@as(i64, (7 * 24 + 1) * 3600000), week.end_ms - week.start_ms);
}

test "calendar service: cache quota failure retains a complete fresh provider snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const window = try dayWindow();
    const old: t.Event = .{ .target = target, .id = "old-event", .summary = "Retained on disk" };
    var host: Host = .{ .steps = &.{.{ .kind = .agenda, .body = try page(a, try fixture(a, "service-imported.json")) }}, .fail_cache = true, .cached = .{ .target = target, .window = window, .events = &.{old}, .fetched_at_ms = 100, .complete = true } };
    const result = try host.service(a).agenda(calendar, window);
    try std.testing.expect(result.snapshot.complete and !result.snapshot.stale);
    try std.testing.expectEqualStrings("fixture-imported-event", result.snapshot.events[0].id);
    try std.testing.expectEqualStrings("DiskQuotaExceeded", result.cache_error);
    try std.testing.expectEqualStrings("", result.refresh_error);
    try std.testing.expectEqualStrings("old-event", host.cached.?.events[0].id);
    try std.testing.expectEqual(@as(usize, 0), host.cached_writes);
}

test "calendar service: nonpersistent reads skip failing saves and retain explicit stale errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const window = try dayWindow();
    const old: t.Event = .{ .target = target, .id = "old-event", .summary = "Foreground cache" };
    var host: Host = .{
        .steps = &.{ .{ .kind = .agenda }, .{ .kind = .agenda, .lost = true }, .{ .kind = .agenda, .lost = true } },
        .fail_cache = true,
        .cached = .{ .target = target, .window = window, .events = &.{old}, .fetched_at_ms = 100, .complete = true },
    };
    var instance = host.service(a);
    instance.persist_cache = false;
    const fresh = try instance.agenda(calendar, window);
    try std.testing.expect(fresh.snapshot.complete and !fresh.snapshot.stale);
    try std.testing.expectEqualStrings("", fresh.cache_error);
    try std.testing.expectEqualStrings("", fresh.refresh_error);
    try std.testing.expectEqualStrings("old-event", host.cached.?.events[0].id);
    const stale = try instance.agenda(calendar, window);
    try std.testing.expect(stale.snapshot.complete and stale.snapshot.stale);
    try std.testing.expectEqualStrings("ConnectionResetByPeer", stale.refresh_error);
    try std.testing.expectEqualStrings("old-event", stale.snapshot.events[0].id);
    host.cached = null;
    try std.testing.expectError(error.ConnectionResetByPeer, instance.agenda(calendar, window));
    try std.testing.expectEqual(@as(usize, 0), host.cached_writes);
}

test "calendar service: freebusy uses readonly POST and per-calendar failures remain incomplete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const busy_calendar: t.Calendar = .{ .target = .{ .account = target.account, .calendar_id = "busy-team@example.test" }, .summary = "Busy", .time_zone = "UTC", .access = .free_busy };
    var host: Host = .{ .steps = &.{ .{ .kind = .free_busy, .body = try fixture(a, "service-busy.json") }, .{ .kind = .free_busy, .body = "{\"timeMin\":\"2026-10-13T00:00:00Z\",\"timeMax\":\"2026-10-14T00:00:00Z\",\"calendars\":{\"busy-team@example.test\":{\"errors\":[{\"reason\":\"internalError\"}]}}}" } } };
    var service = host.service(a);
    service.grants.free_busy = true;
    const busy = try service.freeBusy(busy_calendar, try dayWindow());
    try std.testing.expect(busy.complete);
    try std.testing.expectEqual(@as(usize, 1), busy.ranges.len);
    try std.testing.expectEqual(std.http.Method.POST, host.last_request.?.method);
    const unavailable = try service.freeBusy(busy_calendar, try dayWindow());
    try std.testing.expect(!unavailable.complete);
    try std.testing.expectEqualStrings("internalError", unavailable.reason);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
    try std.testing.expectEqual(@as(usize, 0), host.claims);
}

test "calendar service: cancellation binds fresh etag and reconciles tombstone without replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const imported = try fixture(a, "service-imported.json");
    var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup, .body = try page(a, imported) }, .{ .kind = .event_get, .body = imported }, .{ .kind = .event_get, .body = imported }, .{ .kind = .cancel_event, .lost = true }, .{ .kind = .event_get, .status = 404 }, .{ .kind = .event_get, .body = "{\"id\":\"fixture-imported-event\",\"status\":\"cancelled\"}" } }, .state = .{ .tracked = try tracked(a) } };
    const service = host.service(a);
    const planned = try service.invitationPlan(calendar, try fixture(a, "cancellation.ics"), &.{}, .{});
    try std.testing.expectEqual(.review_cancel, std.meta.activeTag(planned.decision));
    const review = try service.prepareReview(planned, "calendar-service-cancel");
    try std.testing.expectEqualStrings("\"imported-version-4\"", review.request.if_match.?);
    try std.testing.expectEqual(std.http.Method.DELETE, review.request.method);
    try std.testing.expect(std.mem.endsWith(u8, review.request.url, "?sendUpdates=none"));
    try std.testing.expectEqual(.unknown, (try service.apply(review, review.confirmation())).operation.state);
    try std.testing.expectEqual(.unknown, (try service.reconcile(review)).operation.state);
    const resolved = try service.reconcile(review);
    try std.testing.expect(resolved.reconciled);
    try std.testing.expectEqual(.applied, resolved.operation.state);
    try std.testing.expectEqual(@as(usize, 1), host.writes);
}

test "calendar service: organizer updates preserve provider properties and conditional conflicts never retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const imported = try fixture(a, "service-imported.json");
    const old_source = try fixture(a, "single-utc.ics");
    const source = try std.mem.replaceOwned(u8, a, old_source, "SEQUENCE:4", "SEQUENCE:5");
    var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup, .body = try page(a, imported) }, .{ .kind = .event_get, .body = imported }, .{ .kind = .event_get, .body = imported }, .{ .kind = .update_event, .status = 412 } }, .state = .{ .tracked = try tracked(a) } };
    const service = host.service(a);
    const planned = try service.invitationPlan(calendar, source, &.{}, .{});
    try std.testing.expectEqual(.review_update, std.meta.activeTag(planned.decision));
    const review = try service.prepareReview(planned, "calendar-service-update");
    const changes = try std.json.parseFromSliceLeaky(j.Value, a, review.request.body.?, .{});
    try std.testing.expect(j.get(changes, "attendees") == null);
    try std.testing.expect(j.get(changes, "conferenceData") == null);
    const properties = j.get(changes, "extendedProperties").?;
    try std.testing.expectEqualStrings("retained", j.text(j.get(properties, "private").?, "unrelated"));
    try std.testing.expectEqualStrings("retained", j.text(j.get(properties, "shared").?, "otherClient"));
    const result = try service.apply(review, review.confirmation());
    try std.testing.expectEqual(.rejected, result.operation.state);
    try std.testing.expectEqual(provider.Failure.version_conflict, result.failure.?);
    try std.testing.expectEqual(.rejected, (try service.apply(review, review.confirmation())).operation.state);
    try std.testing.expectEqual(@as(usize, 1), host.writes);
}

test "calendar service: reconciliation needs exact source version marker and unique provider identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const imported = try fixture(a, "service-imported.json");
    const wrong_source = try std.mem.replaceOwned(u8, a, imported, "8ce15e0ad4c0ae0f8a68bc83660a24118ad3f53e3373c2a07d7b8ee435a2edb9", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const wrong_version = try std.mem.replaceOwned(u8, a, imported, "\"sequence\":4", "\"sequence\":3");
    const duplicate = try std.mem.replaceOwned(u8, a, imported, "fixture-imported-event", "another-imported-event");
    var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup }, .{ .kind = .event_lookup }, .{ .kind = .import_event, .body = wrong_source }, .{ .kind = .event_lookup, .body = try page(a, wrong_version) }, .{ .kind = .event_lookup, .body = try std.fmt.allocPrint(a, "{{\"items\":[{s},{s}]}}", .{ imported, duplicate }) }, .{ .kind = .event_lookup, .body = try page(a, imported) } } };
    const review = try prepare(&host, a);
    const service = host.service(a);
    try std.testing.expectEqual(.unknown, (try service.apply(review, review.confirmation())).operation.state);
    try std.testing.expectEqual(.unknown, (try service.reconcile(review)).operation.state);
    try std.testing.expectEqual(.unknown, (try service.reconcile(review)).operation.state);
    try std.testing.expectEqual(.applied, (try service.reconcile(review)).operation.state);
    try std.testing.expectEqual(@as(usize, 1), host.writes);
}

test "calendar service: a fresh operation ID cannot bypass an unknown receipt for the same UID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Host = .{ .steps = &.{.{ .kind = .event_lookup }} };
    const service = host.service(a);
    const planned = try service.invitationPlan(calendar, try fixture(a, "single-utc.ics"), &.{}, .{});
    const first = try service.prepareReview(planned, "calendar-pending-first");
    const second = try service.prepareReview(planned, "calendar-pending-second");
    host.state.operation = .{ .intent = first.intent };
    try std.testing.expectError(error.CalendarOperationPending, service.apply(second, second.confirmation()));
    try std.testing.expectEqual(@as(usize, 1), host.index);
    try std.testing.expectEqual(@as(usize, 0), host.claims);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
}

test "calendar service: recurring source can locate an existing master without rewriting source rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const master = "{\"items\":[{\"id\":\"recurring-master\",\"iCalUID\":\"weekly-2026@example.test\",\"status\":\"confirmed\",\"organizer\":{\"email\":\"host@example.test\"},\"start\":{\"dateTime\":\"2026-10-13T10:00:00+02:00\"},\"end\":{\"dateTime\":\"2026-10-13T11:00:00+02:00\"}}]}";
    var host: Host = .{ .steps = &.{ .{ .kind = .event_lookup }, .{ .kind = .event_lookup, .body = master } } };
    const service = host.service(a);
    const raw = try fixture(a, "recurring-zone.ics");
    const absent = try service.invitationPlan(calendar, raw, &.{}, .{});
    try std.testing.expectEqual(.unsupported_recurrence, std.meta.activeTag(absent.decision));
    try std.testing.expectError(error.CalendarActionUnavailable, service.prepareReview(absent, "cannot-import-recurrence"));
    const existing = try service.invitationPlan(calendar, raw, &.{}, .{});
    try std.testing.expectEqual(.existing, std.meta.activeTag(existing.decision));
    try std.testing.expectEqualStrings("recurring-master", existing.decision.existing.id);
    try std.testing.expectEqualStrings(raw, existing.source.source);
    try std.testing.expectEqual(@as(usize, 3), existing.source.recurrence.len);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
}
