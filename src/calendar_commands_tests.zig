const std = @import("std");
const commands = @import("terminal/calendar_commands.zig");
const service = @import("terminal/calendar_service.zig");
const provider = @import("terminal/calendar_provider.zig");
const plan = @import("terminal/calendar_plan.zig");
const t = @import("terminal/calendar_types.zig");
const j = @import("terminal/json.zig");
const persistence = @import("terminal/calendar_store.zig");
const storage = @import("terminal/store.zig");

test {
    std.testing.refAllDecls(commands);
}

const target: t.Target = .{ .account = "self@example.test", .calendar_id = "self@example.test" };
const list = "{\"items\":[{\"id\":\"self@example.test\",\"summary\":\"Personal\",\"timeZone\":\"UTC\",\"accessRole\":\"owner\",\"primary\":true}]}";
const empty = "{\"items\":[]}";
const Step = struct { kind: provider.OperationKind, body: []const u8 = empty, lost: bool = false };
const Host = struct {
    steps: []const Step = &.{},
    index: usize = 0,
    writes: usize = 0,
    source_reads: usize = 0,
    review_reads: usize = 0,
    preserves: usize = 0,
    claims: usize = 0,
    source: []const u8 = "",
    state: service.State = .{},
    review: ?service.Review = null,
    ignore_review_binding: bool = false,
    last_request: ?provider.Request = null,

    fn send(context: *anyopaque, _: std.mem.Allocator, request: provider.Request) anyerror!service.Response {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.index >= self.steps.len) return error.UnexpectedCalendarRequest;
        const step = self.steps[self.index];
        try std.testing.expectEqual(step.kind, request.kind);
        try std.testing.expectEqualStrings(target.account, request.target.account);
        self.index += 1;
        self.last_request = request;
        if (request.kind.mutating()) {
            try std.testing.expect(self.state.operation != null);
            try std.testing.expectEqual(.unknown, self.state.operation.?.state);
            try std.testing.expectEqual(@as(usize, 1), self.claims);
            try std.testing.expectEqual(@as(usize, 2), self.preserves);
            self.writes += 1;
        }
        if (step.lost) return error.ConnectionResetByPeer;
        return .{ .account = target.account, .status = 200, .body = step.body };
    }
    fn loadSource(context: *anyopaque, _: std.mem.Allocator, account: []const u8, request: j.Value) anyerror!commands.InvitationInput {
        const self: *Host = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings(target.account, account);
        try std.testing.expectEqualStrings("fixture-message", try j.required(request, "messageId"));
        self.source_reads += 1;
        return .{ .source = self.source };
    }
    fn loadReview(context: *anyopaque, _: std.mem.Allocator, requested: t.Target, operation_id: []const u8) anyerror!service.Review {
        const self: *Host = @ptrCast(@alignCast(context));
        self.review_reads += 1;
        const review = self.review orelse return error.CalendarReviewNotFound;
        if (!self.ignore_review_binding and (!requested.eql(review.intent.identity.target) or !std.mem.eql(u8, operation_id, review.intent.operation_id))) return error.CalendarReviewNotFound;
        return review;
    }
    fn loadState(context: *anyopaque, _: std.mem.Allocator, identity: plan.Identity) anyerror!service.State {
        const self: *Host = @ptrCast(@alignCast(context));
        try std.testing.expect(identity.target.eql(target));
        return self.state;
    }
    fn preserve(context: *anyopaque, review: service.Review) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.review) |saved| if (!saved.intent.eql(review.intent)) return error.OperationConflict;
        self.review = review;
        self.preserves += 1;
    }
    fn claim(context: *anyopaque, intent: plan.Intent) anyerror!plan.Claim {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.state.operation) |operation| return .{ .operation = operation, .fresh = false };
        try std.testing.expect(self.review != null and self.review.?.intent.eql(intent));
        self.state.operation = .{ .intent = intent };
        self.claims += 1;
        return .{ .operation = self.state.operation.?, .fresh = true };
    }
    fn record(context: *anyopaque, operation: plan.Operation) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.state.operation = operation;
        if (operation.state == .applied) self.state.tracked = .{ .identity = operation.intent.identity, .event_id = operation.provider_id, .version = operation.intent.version, .source_hash = operation.intent.source_hash };
    }
    fn instance(self: *Host, a: std.mem.Allocator) service.Service {
        return .{ .a = a, .grants = .{ .account = target.account, .calendar_list = true, .read_events = true, .write_owned = true, .free_busy = true }, .transport = .{ .context = self, .sendFn = send }, .persistence = .{ .context = self, .loadFn = loadState, .preserveFn = preserve, .journal = .{ .context = self, .claimFn = claim, .recordFn = record } }, .now_ms = 1000 };
    }
    fn inputs(self: *Host, env: *const std.process.Environ.Map) commands.HostInputs {
        return .{ .io = std.testing.io, .env = env, .context = self, .loadInvitationFn = loadSource, .loadReviewFn = loadReview };
    }
};
fn fixture(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/fixtures/terminal/calendar/{s}", .{name}), a, .limited(t.Limits.response_bytes));
}
fn reviewRequest(a: std.mem.Allocator) !j.Value {
    return j.value(a, .{ .cmd = "calendar.review", .account = target.account, .calendarId = target.calendar_id, .messageId = "fixture-message", .operationId = "calendar-service-1" });
}
fn applyRequest(a: std.mem.Allocator, response: j.Value) !j.Value {
    return j.value(a, .{ .cmd = "calendar.apply", .account = target.account, .calendarId = target.calendar_id, .operationId = j.text(response, "operationId"), .reviewHash = j.text(response, "reviewHash") });
}

test "calendar commands: invalid and unsupported requests stop before source store or transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{};
    const instance = host.instance(a);
    const inputs = host.inputs(&env);
    try std.testing.expectError(error.UnsupportedCalendarCommand, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.delete-everything", .account = target.account }), inputs));
    try std.testing.expectError(error.MissingField, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.event", .account = target.account, .calendarId = target.calendar_id }), inputs));
    try std.testing.expectError(error.MissingField, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.agenda", .account = target.account, .date = "2026-10-13" }), inputs));
    try std.testing.expectError(error.InvalidCalendarView, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.agenda", .account = target.account, .calendarId = target.calendar_id, .date = "2026-10-13", .view = "forever" }), inputs));
    try std.testing.expectError(error.InvalidRequest, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.list", .account = target.account, .persistCache = "false" }), inputs));
    try std.testing.expectError(error.InvalidRequest, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.agenda", .account = target.account, .calendarId = target.calendar_id, .date = "2026-10-13", .persistCache = 0 }), inputs));
    try std.testing.expectError(error.InvalidCalendarRequest, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.review", .account = target.account, .calendarId = target.calendar_id, .messageId = "fixture-message", .operationId = "fixture", .persistCache = false }), inputs));
    try std.testing.expectError(error.CalendarAccountMismatch, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.list", .account = "other@example.test" }), inputs));
    try std.testing.expectError(error.MissingField, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.review", .account = target.account, .calendarId = target.calendar_id, .messageId = "fixture-message" }), inputs));
    try std.testing.expectError(error.InvalidCalendarConfirmation, commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.apply", .account = target.account, .calendarId = target.calendar_id, .operationId = "fixture", .reviewHash = "no-hash" }), inputs));
    try std.testing.expectEqual(@as(usize, 0), host.index + host.source_reads + host.review_reads + host.writes);
}

test "calendar commands: complete calendar list reports actual owned shared and busy access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{ .steps = &.{.{ .kind = .calendar_list, .body = try fixture(a, "service-calendars.json") }} };
    const response = try commands.dispatch(host.instance(a), try j.value(a, .{ .cmd = "calendar.list", .account = target.account }), host.inputs(&env));
    try std.testing.expect(try j.boolean(response, "complete", false));
    const calendars = j.get(response, "calendars").?.array.items;
    try std.testing.expect(try j.boolean(calendars[0], "canWrite", false));
    try std.testing.expect(try j.boolean(calendars[1], "canWrite", false));
    try std.testing.expect(!try j.boolean(calendars[2], "canWrite", true));
    try std.testing.expect(!try j.boolean(calendars[4], "canRead", true));
    try std.testing.expect(try j.boolean(calendars[4], "canFreeBusy", false));
    try std.testing.expectEqual(@as(usize, 1), host.index);
}

test "calendar commands: week window reaches server expansion and returns exact snapshot window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{ .steps = &.{ .{ .kind = .calendar_list, .body = list }, .{ .kind = .agenda } } };
    const response = try commands.dispatch(host.instance(a), try j.value(a, .{ .cmd = "calendar.agenda", .account = target.account, .calendarId = target.calendar_id, .date = "2026-10-13", .view = "week" }), host.inputs(&env));
    const snapshot = j.get(response, "snapshot").?;
    const window = j.get(snapshot, "window").?;
    try std.testing.expectEqual(@as(i64, 7 * 86400 * 1000), try j.integer(window, "end_ms", 0) - try j.integer(window, "start_ms", 0));
    try std.testing.expect(try j.boolean(snapshot, "complete", false));
    try std.testing.expect(std.mem.indexOf(u8, host.last_request.?.url, "singleEvents=true") != null);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
}

test "calendar commands: nonpersistent polls of five calendars preserve foreground offline windows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/poll-cache", .{tmp.sub_path});
    var store: persistence.Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .result_allocator = a, .root = root, .account = target.account, .options = .{ .fixtures = true } };

    const Listed = struct { id: []const u8, summary: []const u8 = "Viewed calendar", timeZone: []const u8 = "UTC", accessRole: []const u8 = "reader", selected: bool = true };
    var calendars: [5]Listed = undefined;
    for (&calendars, 0..) |*item, i| item.* = .{ .id = try std.fmt.allocPrint(a, "selected-{d}@example.test", .{i}) };
    const viewed_list = try j.encodeAlloc(a, .{ .items = calendars }, .{});
    for (&calendars) |*item| item.summary = "Updated during background poll";
    const polled_list = try j.encodeAlloc(a, .{ .items = calendars }, .{});
    var steps: std.ArrayList(Step) = .empty;
    for (0..persistence.max_snapshots) |_| try steps.appendSlice(a, &.{ .{ .kind = .calendar_list, .body = viewed_list }, .{ .kind = .agenda } });
    try steps.append(a, .{ .kind = .calendar_list, .body = polled_list });
    for (0..calendars.len + 1) |_| try steps.appendSlice(a, &.{ .{ .kind = .calendar_list, .body = polled_list }, .{ .kind = .agenda } });
    var host: Host = .{ .steps = steps.items };
    var instance = host.instance(a);
    instance.cache = store.cache();
    const inputs = host.inputs(&env);
    var requests: [persistence.max_snapshots]j.Value = undefined;
    var snapshots: [persistence.max_snapshots]t.Snapshot = undefined;
    const cache = store.cache();
    for (&requests, &snapshots, 0..) |*request, *saved, i| {
        request.* = try j.value(a, .{ .cmd = "calendar.agenda", .account = target.account, .calendarId = calendars[i].id, .date = "2026-10-13", .view = "day", .timeZone = "UTC" });
        // Exercise both the omitted default and an explicit foreground opt-in.
        if (i == requests.len - 1) try request.object.put(a, "persistCache", .{ .bool = true });
        const response = try commands.dispatch(instance, request.*, inputs);
        saved.* = try j.decode(t.Snapshot, a, j.get(response, "snapshot").?);
        try std.testing.expect(try cache.loadFn(cache.context, a, saved.target, saved.window) != null);
    }
    const before = blk: {
        var account_store = try storage.Store.open(std.testing.io, a, root, target.account, store.options);
        defer account_store.close();
        break :blk (try account_store.readDocument(a, "calendar-agenda.json", persistence.cache_bytes)).?;
    };
    instance.now_ms = 2000;
    const discovery = try commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.list", .account = target.account, .persistCache = false }), inputs);
    try std.testing.expect(try j.boolean(discovery, "complete", false));
    for (calendars) |item| {
        const response = try commands.dispatch(instance, try j.value(a, .{ .cmd = "calendar.agenda", .account = target.account, .calendarId = item.id, .date = "2026-10-13", .view = "week", .timeZone = "UTC", .persistCache = false }), inputs);
        const polled = try j.decode(t.Snapshot, a, j.get(response, "snapshot").?);
        try std.testing.expect(polled.complete and !polled.stale);
        try std.testing.expectEqualStrings("", j.text(response, "cacheError"));
        try std.testing.expect(try cache.loadFn(cache.context, a, polled.target, polled.window) == null);
    }
    // A poll of an exact foreground window must not overwrite it either.
    var same_window = try j.copyObject(a, requests[0]);
    try same_window.object.put(a, "persistCache", .{ .bool = false });
    _ = try commands.dispatch(instance, same_window, inputs);
    {
        var account_store = try storage.Store.open(std.testing.io, a, root, target.account, store.options);
        defer account_store.close();
        const after = (try account_store.readDocument(a, "calendar-agenda.json", persistence.cache_bytes)).?;
        try std.testing.expectEqualStrings(before, after);
    }
    // Reopen the persistent store and exercise the actual offline command path.
    var reopened = store;
    for (requests, snapshots) |request, saved| {
        const offline = try @import("terminal/calendar_cached.zig").dispatch(a, instance.grants, &reopened, request, inputs, "ConnectionRefused");
        const retained = try j.decode(t.Snapshot, a, j.get(offline, "snapshot").?);
        try std.testing.expect(retained.target.eql(saved.target) and retained.stale and retained.complete);
        try std.testing.expectEqual(saved.fetched_at_ms, retained.fetched_at_ms);
        try std.testing.expectEqualStrings("Viewed calendar", j.text(j.get(offline, "calendar").?, "summary"));
        try std.testing.expectEqualStrings("ConnectionRefused", j.text(offline, "refreshError"));
    }
    try std.testing.expectEqual(steps.items.len, host.index);
    try std.testing.expectEqual(@as(usize, 0), host.writes);
}

test "calendar commands: review persists exact request and one accepted import survives repeated commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{ .source = try fixture(a, "single-utc.ics"), .steps = &.{ .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup }, .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup }, .{ .kind = .import_event, .body = try fixture(a, "service-imported.json") }, .{ .kind = .calendar_list, .body = list } } };
    const instance = host.instance(a);
    const inputs = host.inputs(&env);
    const review = try commands.dispatch(instance, try reviewRequest(a), inputs);
    try std.testing.expectEqualStrings("import_event", j.text(review, "action"));
    try std.testing.expectEqual(@as(usize, 64), j.text(review, "reviewHash").len);
    try std.testing.expectEqual(@as(usize, 0), host.claims + host.writes);
    const confirmed = try applyRequest(a, review);
    try std.testing.expectEqualStrings("applied", j.text(try commands.dispatch(instance, confirmed, inputs), "state"));
    try std.testing.expectEqualStrings("applied", j.text(try commands.dispatch(instance, confirmed, inputs), "state"));
    try std.testing.expectEqual(@as(usize, 1), host.writes);
    try std.testing.expectEqual(host.steps.len, host.index);
}

test "calendar commands: review hash account calendar operation and action bind before network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{ .source = try fixture(a, "single-utc.ics"), .ignore_review_binding = true, .steps = &.{ .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup } } };
    const instance = host.instance(a);
    const inputs = host.inputs(&env);
    const review = try commands.dispatch(instance, try reviewRequest(a), inputs);
    const confirmed = try applyRequest(a, review);
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    for ([_]struct { name: []const u8, value: []const u8 }{ .{ .name = "reviewHash", .value = wrong }, .{ .name = "calendarId", .value = "other-calendar" }, .{ .name = "operationId", .value = "other-operation" }, .{ .name = "cmd", .value = "calendar.cancel" }, .{ .name = "cmd", .value = "calendar.update" } }) |change| {
        var altered = try j.copyObject(a, confirmed);
        try altered.object.put(a, change.name, .{ .string = change.value });
        try std.testing.expectError(error.CalendarReviewMismatch, commands.dispatch(instance, altered, inputs));
    }
    var injected = try j.copyObject(a, confirmed);
    try injected.object.put(a, "body", .{ .string = "{}" });
    try std.testing.expectError(error.InvalidCalendarConfirmation, commands.dispatch(instance, injected, inputs));
    try std.testing.expectEqual(@as(usize, 2), host.index);
    try std.testing.expectEqual(@as(usize, 0), host.writes + host.claims);
}

test "calendar commands: interrupted import remains unknown and explicit reconcile never replays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{ .source = try fixture(a, "single-utc.ics"), .steps = &.{ .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup }, .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup }, .{ .kind = .import_event, .lost = true }, .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup } } };
    const instance = host.instance(a);
    const inputs = host.inputs(&env);
    const review = try commands.dispatch(instance, try reviewRequest(a), inputs);
    const confirmed = try applyRequest(a, review);
    try std.testing.expectEqualStrings("unknown", j.text(try commands.dispatch(instance, confirmed, inputs), "state"));
    var reconcile = try j.copyObject(a, confirmed);
    try reconcile.object.put(a, "cmd", .{ .string = "calendar.reconcile" });
    try std.testing.expectEqualStrings("unknown", j.text(try commands.dispatch(instance, reconcile, inputs), "state"));
    try std.testing.expectEqual(@as(usize, 1), host.writes);
    try std.testing.expectEqual(host.steps.len, host.index);
}

test "calendar commands: caller aliases cannot broaden source attendee matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var host: Host = .{};
    var request = try reviewRequest(a);
    try request.object.put(a, "verifiedAliases", try j.value(a, &.{"other@example.test"}));
    try std.testing.expectError(error.InvalidCalendarRequest, commands.dispatch(host.instance(a), request, host.inputs(&env)));
    try std.testing.expectEqual(@as(usize, 0), host.index + host.source_reads);
    host.steps = &.{.{ .kind = .calendar_list, .body = list }};
    host.source = try std.mem.replaceOwned(u8, a, try fixture(a, "single-utc.ics"), "mailto:self@example.test", "mailto:unverified-alias@example.test");
    try std.testing.expectError(error.NotAnAttendee, commands.dispatch(host.instance(a), try reviewRequest(a), host.inputs(&env)));
    try std.testing.expectEqual(@as(usize, 1), host.index);
    try std.testing.expectEqual(@as(usize, 1), host.source_reads);
    try std.testing.expectEqual(@as(usize, 0), host.preserves + host.claims + host.writes);
}

test "calendar commands: named embedded rules prove a nominal duration before an import review" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A literal TZif file makes this command test independent of host tzdata.
    var header: [44]u8 = @splat(0);
    @memcpy(header[0..5], "TZif2");
    std.mem.writeInt(u32, header[36..40], 1, .big);
    std.mem.writeInt(u32, header[40..44], 4, .big);
    const record = "\x00\x00\x0e\x10\x00\x00CET\x00";
    const tzif = try std.mem.concat(a, u8, &.{ &header, record, &header, record, "\nCET-1CEST,M3.5.0/2,M10.5.0/3\n" });
    try tmp.dir.createDir(std.testing.io, "Europe", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Europe/Vienna", .data = tzif });
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("TZDIR", try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    const raw = try fixture(a, "embedded-europe.ics");
    const moved = try std.mem.replaceOwned(u8, a, raw, "DTSTART;TZID=Europe/Vienna:20261013T100000", "DTSTART;TZID=Europe/Vienna:20260328T120000");
    const duration = try std.mem.replaceOwned(u8, a, moved, "DTEND;TZID=Europe/Vienna:20261013T110000", "DURATION:P1D");
    var host: Host = .{ .source = duration, .steps = &.{ .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup }, .{ .kind = .calendar_list, .body = list }, .{ .kind = .event_lookup } } };
    const request = try j.value(a, .{ .cmd = "calendar.invitation-plan", .account = target.account, .calendarId = target.calendar_id, .messageId = "fixture-message" });
    const resolved = try commands.dispatch(host.instance(a), request, host.inputs(&env));
    try std.testing.expectEqualStrings("import_missing", j.text(resolved, "decision"));
    try std.testing.expectEqualStrings("", j.text(resolved, "timeError"));
    const span = j.get(resolved, "resolved").?;
    try std.testing.expectEqual(@as(i64, 23 * 3600000), try j.integer(j.get(span, "end").?, "value", 0) - try j.integer(j.get(span, "start").?, "value", 0));
    host.source = try std.mem.replaceOwned(u8, a, duration, "TZOFFSETTO:+0200", "TZOFFSETTO:+0300");
    const unresolved = try commands.dispatch(host.instance(a), request, host.inputs(&env));
    try std.testing.expectEqualStrings("EmbeddedTimezoneUnresolved", j.text(unresolved, "timeError"));
    try std.testing.expect(j.get(unresolved, "resolved") == null);
    try std.testing.expectEqual(@as(usize, 0), host.writes + host.claims);
}
