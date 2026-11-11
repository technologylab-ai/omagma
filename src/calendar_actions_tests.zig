//! Delete and RSVP actions on existing events through the shared command
//! boundary, the durable journal and the persistent synthetic provider. No
//! credentials, network, real calendar or mail are involved.
const std = @import("std");
const fixture = @import("terminal/calendar_fixture.zig");
const commands = @import("terminal/calendar_commands.zig");
const service = @import("terminal/calendar_service.zig");
const persistence = @import("terminal/calendar_store.zig");
const storage = @import("terminal/store.zig");
const mail = @import("terminal/types.zig");
const t = @import("terminal/calendar_types.zig");
const j = @import("terminal/json.zig");

test {
    std.testing.refAllDecls(@import("terminal/calendar_event_action.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_action_ui.zig"));
}

const account = "self@example.test";
const target: t.Target = .{ .account = account, .calendar_id = account };
const now = 1791849600000; // 2026-10-13T00:00Z
const today = "2026-10-13";
const standup_first = "fixture-standup_1791880200000";
const standup_second = "fixture-standup_1791966600000";
const office_first = "fixture-office_1791910800000";
const office_second = "fixture-office_1791997200000";
// Changed occurrences on the third day: the standup gained guests and a
// title; the office hours were answered while the series is unanswered.
const standup_exception = "fixture-standup_1792053000000";
const office_exception = "fixture-office_1792083600000";
const zero_hash: [64]u8 = @splat('0');

const Harness = struct {
    a: std.mem.Allocator,
    root: []const u8,
    options: mail.Options = .{ .fixtures = true, .fixture_scenario = "calendar-actions" },
    /// The operation behind the last CalendarOperationPending refusal.
    blocked: service.Blocked = .{},

    fn run(self: *Harness, request: j.Value) !j.Value {
        self.blocked.clear();
        var backend = try fixture.Provider.init(.{ .io = std.testing.io, .allocator = std.testing.allocator, .root = self.root, .account = account, .options = self.options, .now_ms = now });
        var local: persistence.Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .result_allocator = self.a, .root = self.root, .account = account, .options = self.options };
        var env: std.process.Environ.Map = .init(self.a);
        defer env.deinit();
        const instance: service.Service = .{ .a = self.a, .grants = backend.grants(), .transport = backend.transport(), .persistence = local.persistence(), .cache = local.cache(), .now_ms = now, .blocked = &self.blocked };
        return commands.dispatch(instance, request, .{ .io = std.testing.io, .env = &env, .context = &local, .loadReviewFn = review, .loadReceiptFn = receipt, .loadPendingFn = pending });
    }
    fn review(context: *anyopaque, a: std.mem.Allocator, requested: t.Target, operation_id: []const u8) anyerror!service.Review {
        const store: *persistence.Host = @ptrCast(@alignCast(context));
        return store.loadReview(a, requested, operation_id);
    }
    fn receipt(context: *anyopaque, a: std.mem.Allocator, requested: t.Target, operation_id: []const u8) anyerror!?service.Receipt {
        const store: *persistence.Host = @ptrCast(@alignCast(context));
        return store.loadReceipt(a, requested, operation_id);
    }
    fn pending(context: *anyopaque, a: std.mem.Allocator, requested: t.Target, event_id: []const u8) anyerror!?service.Pending {
        const store: *persistence.Host = @ptrCast(@alignCast(context));
        return store.loadPending(a, requested, event_id);
    }
    fn provider(self: *Harness) !j.Value {
        var store = try storage.Store.open(std.testing.io, self.a, self.root, account, self.options);
        defer store.close();
        const bytes = try store.readDocument(self.a, fixture.document_name, fixture.document_bytes) orelse return error.MissingProviderFixture;
        return std.json.parseFromSliceLeaky(j.Value, self.a, bytes, .{ .allocate = .alloc_always });
    }
    fn writes(self: *Harness) !i64 {
        return j.integer(try self.provider(), "writes", -1);
    }
    /// The mutating requests as they reached the synthetic wire, oldest first.
    fn sent(self: *Harness) ![]const j.Value {
        return (j.get(try self.provider(), "requests") orelse return &.{}).array.items;
    }
    fn expectSent(self: *Harness, index: usize, method: []const u8, event_id: []const u8, if_match: []const u8, send_updates: []const u8) !void {
        const requests = try self.sent();
        try std.testing.expect(index < requests.len);
        const request = requests[index];
        try std.testing.expectEqualStrings(method, j.text(request, "method"));
        try std.testing.expectEqualStrings(event_id, j.text(request, "eventId"));
        try std.testing.expectEqualStrings(if_match, j.text(request, "ifMatch"));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(self.a, "sendUpdates={s}", .{send_updates}), j.text(request, "query"));
    }
    fn stored(self: *Harness, id: []const u8) !?j.Value {
        for (j.get(try self.provider(), "events").?.array.items) |entry| {
            const value = j.get(entry, "value").?;
            if (std.mem.eql(u8, j.text(value, "id"), id)) return value;
        }
        return null;
    }
    /// Adds a synthetic event to the seeded provider document.
    fn inject(self: *Harness, value: j.Value) !void {
        const document = try self.provider();
        const entry = try j.value(self.a, .{ .calendar_id = account, .value = value });
        try document.object.getPtr("events").?.array.append(entry);
        var store = try storage.Store.open(std.testing.io, self.a, self.root, account, self.options);
        defer store.close();
        try store.writeDocument(fixture.document_name, try std.json.Stringify.valueAlloc(self.a, document, .{}));
    }
    /// A daily series organized here with one guest, starting today at `hour`.
    fn injectSeries(self: *Harness, id: []const u8, hour: i64) !void {
        const first = @divFloor(now, 86400000) * 86400000 + hour * 3600000;
        const Point = struct { dateTime: []const u8 };
        const Guest = struct { email: []const u8, self: bool = false, organizer: bool = false, responseStatus: []const u8 = "needsAction" };
        try self.inject(try j.value(self.a, .{ .id = id, .iCalUID = try std.fmt.allocPrint(self.a, "{s}@example.test", .{id}), .etag = try std.fmt.allocPrint(self.a, "\"seed-{s}\"", .{id}), .status = "confirmed", .organizer = .{ .email = account, .self = true }, .summary = id, .start = Point{ .dateTime = try t.time.format(self.a, .{ .kind = .instant, .value = first }) }, .end = Point{ .dateTime = try t.time.format(self.a, .{ .kind = .instant, .value = first + 1800000 }) }, .sequence = 0, .attendees = [_]Guest{ .{ .email = account, .self = true, .organizer = true, .responseStatus = "accepted" }, .{ .email = "guest-one@example.test" } }, .recurrence = [_][]const u8{"RRULE:FREQ=DAILY"} }));
    }
    fn occurrence(self: *Harness, series: []const u8, hour: i64, day: i64) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}_{d}", .{ series, @divFloor(now, 86400000) * 86400000 + hour * 3600000 + day * 86400000 });
    }
    fn pendingFor(self: *Harness, fields: anytype) !j.Value {
        var request = try j.value(self.a, fields);
        try request.object.put(self.a, "cmd", .{ .string = "calendar.event-pending" });
        try request.object.put(self.a, "account", .{ .string = account });
        try request.object.put(self.a, "calendarId", .{ .string = account });
        return self.run(request);
    }
    /// An edit review of an existing event from its own editor draft.
    fn editReview(self: *Harness, operation: []const u8, id: []const u8, summary: []const u8) !j.Value {
        const detail = try self.run(try j.value(self.a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
        var draft = try j.copyObject(self.a, j.get(detail, "eventDraft").?);
        try draft.object.put(self.a, "summary", .{ .string = summary });
        return self.run(try j.value(self.a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .eventId = id, .expectedEtag = j.text(j.get(detail, "event").?, "etag"), .sendUpdates = "none", .operationId = operation, .event = draft }));
    }
    fn event(self: *Harness, id: []const u8) !j.Value {
        return j.get(try self.run(try j.value(self.a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id })), "event").?;
    }
    fn agendaIds(self: *Harness, view: []const u8) ![]const []const u8 {
        const result = try self.run(try j.value(self.a, .{ .cmd = "calendar.agenda", .account = account, .calendarId = account, .date = today, .view = view, .timeZone = "UTC" }));
        const events = j.get(j.get(result, "snapshot").?, "events").?.array.items;
        const ids = try self.a.alloc([]const u8, events.len);
        for (events, ids) |value, *id| id.* = j.text(value, "id");
        return ids;
    }
    fn deleteReview(self: *Harness, operation: []const u8, event_id: []const u8, etag: ?[]const u8, scope: []const u8, updates: []const u8, dry_run: bool) !j.Value {
        return self.run(try j.value(self.a, .{ .cmd = "calendar.event-delete-review", .account = account, .calendarId = account, .eventId = event_id, .expectedEtag = etag, .scope = scope, .sendUpdates = updates, .operationId = operation, .dryRun = dry_run }));
    }
    fn respondReview(self: *Harness, operation: []const u8, event_id: []const u8, etag: ?[]const u8, scope: []const u8, response: ?[]const u8, updates: []const u8, dry_run: bool) !j.Value {
        return self.run(try j.value(self.a, .{ .cmd = "calendar.event-respond-review", .account = account, .calendarId = account, .eventId = event_id, .expectedEtag = etag, .scope = scope, .response = response, .sendUpdates = updates, .operationId = operation, .dryRun = dry_run }));
    }
    fn execute(self: *Harness, command: []const u8, reviewed: j.Value) !j.Value {
        return self.run(try j.value(self.a, .{ .cmd = command, .account = account, .calendarId = account, .operationId = j.text(reviewed, "operationId"), .reviewHash = j.text(reviewed, "reviewHash") }));
    }
};

fn harness(a: std.mem.Allocator, tmp: std.testing.TmpDir) !Harness {
    return .{ .a = a, .root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/calendar-actions", .{tmp.sub_path}) };
}
fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |value| if (std.mem.eql(u8, value, id)) return true;
    return false;
}

test "calendar actions: organizer delete reviews guests, emails only when chosen and applies exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    try std.testing.expect(contains(try h.agendaIds("day"), "fixture-hosted"));
    // The plan reads only: no review is saved, so its operation cannot apply.
    const plan = try h.deleteReview("plan-hosted", "fixture-hosted", null, "event", "none", true);
    try std.testing.expect(try j.boolean(plan, "dryRun", false));
    try std.testing.expect(j.get(plan, "reviewHash") == null);
    try std.testing.expectEqualStrings("organizer", j.text(plan, "role"));
    try std.testing.expectEqual(@as(i64, 2), try j.integer(plan, "guestCount", -1));
    try std.testing.expect(try j.boolean(j.get(j.get(plan, "options").?, "notify").?, "available", false));
    try std.testing.expectEqualStrings("not_recurring", j.text(j.get(j.get(plan, "options").?, "series").?, "reason"));
    try std.testing.expectError(error.CalendarReviewNotFound, h.run(try j.value(a, .{ .cmd = "calendar.event-apply", .account = account, .calendarId = account, .operationId = "plan-hosted", .reviewHash = &zero_hash })));
    // A real review needs the version the caller saw.
    try std.testing.expectError(error.CalendarExpectedEtagRequired, h.deleteReview("missing-etag", "fixture-hosted", null, "event", "all", false));
    try std.testing.expectError(error.CalendarReviewStale, h.deleteReview("old-etag", "fixture-hosted", "\"fixture-version-0\"", "event", "all", false));
    const reviewed = try h.deleteReview("delete-hosted", "fixture-hosted", j.text(plan, "expectedEtag"), "event", "all", false);
    try std.testing.expectEqualStrings("Deletes this event from Personal and emails 2 guests a cancellation.", j.text(reviewed, "consequence"));
    try std.testing.expectEqual(@as(usize, 64), j.text(reviewed, "reviewHash").len);
    // A dry run of apply performs the same checks and sends nothing.
    const dry = try h.run(try j.value(a, .{ .cmd = "calendar.event-apply", .account = account, .calendarId = account, .operationId = "delete-hosted", .reviewHash = j.text(reviewed, "reviewHash"), .dryRun = true }));
    try std.testing.expectEqualStrings("not_sent", j.text(dry, "state"));
    try std.testing.expectEqualStrings("DELETE", j.text(j.get(dry, "wouldSend").?, "method"));
    try std.testing.expectEqualStrings("all", j.text(j.get(dry, "wouldSend").?, "sendUpdates"));
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    const applied = try h.execute("calendar.event-apply", reviewed);
    try std.testing.expectEqualStrings("applied", j.text(applied, "state"));
    try std.testing.expectEqualStrings("fixture-hosted", j.text(applied, "providerId"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    // On the wire: the event, its reviewed version and the chosen email.
    try h.expectSent(0, "DELETE", "fixture-hosted", "\"fixture-seed-fixture-hosted\"", "all");
    try std.testing.expectEqualStrings("cancelled", j.text((try h.stored("fixture-hosted")).?, "status"));
    try std.testing.expect(!contains(try h.agendaIds("day"), "fixture-hosted"));
    // Replays return the receipt; nothing is deleted twice.
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    try std.testing.expectError(error.CalendarEventCancelled, h.deleteReview("again", "fixture-hosted", null, "event", "none", true));
}

test "calendar actions: a concurrent change is refused by If-Match and a stale review never deletes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    h.options.fixture_scenario = "calendar-actions-conflict";
    const seen = try h.event("fixture-focus");
    const reviewed = try h.deleteReview("delete-focus", "fixture-focus", j.text(seen, "etag"), "event", "none", false);
    try std.testing.expectEqualStrings("Deletes this event from Personal. It has no guests, so no email is sent.", j.text(reviewed, "consequence"));
    try std.testing.expectError(error.CalendarNotificationUnavailable, h.deleteReview("notify-nobody", "fixture-focus", j.text(seen, "etag"), "event", "all", false));
    const refused = try h.execute("calendar.event-apply", reviewed);
    try std.testing.expectEqualStrings("rejected", j.text(refused, "state"));
    try std.testing.expectEqualStrings("CalendarVersionConflict", j.text(refused, "errorCode"));
    const current = (try h.stored("fixture-focus")).?;
    try std.testing.expectEqualStrings("confirmed", j.text(current, "status"));
    try std.testing.expectEqualStrings("Moved by another client", j.text(current, "location"));
    // The changed version needs a fresh review; the old one stays refused.
    try std.testing.expectError(error.CalendarReviewStale, h.deleteReview("stale-focus", "fixture-focus", j.text(seen, "etag"), "event", "none", false));
    try std.testing.expectEqualStrings("rejected", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
}

test "calendar actions: a lost delete response stays unknown and blocks writes until reconcile proves it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    h.options.fixture_scenario = "calendar-actions-lost-response";
    const seen = try h.event("fixture-hosted");
    const reviewed = try h.deleteReview("lost-delete", "fixture-hosted", j.text(seen, "etag"), "event", "none", false);
    const unknown = try h.execute("calendar.event-apply", reviewed);
    try std.testing.expectEqualStrings("unknown", j.text(unknown, "state"));
    // Another write to the same event (even a plan) waits for the uncertain one.
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("second-delete", "fixture-hosted", null, "event", "none", true));
    const pending = j.get(try h.run(try j.value(a, .{ .cmd = "calendar.event-pending", .account = account, .calendarId = account, .eventId = "fixture-hosted" })), "pending").?;
    try std.testing.expectEqualStrings("delete_event", j.text(j.get(pending, "review").?, "action"));
    try std.testing.expectEqualStrings(j.text(reviewed, "reviewHash"), j.text(j.get(pending, "review").?, "reviewHash"));
    const checked = try h.execute("calendar.event-reconcile", reviewed);
    try std.testing.expectEqualStrings("applied", j.text(checked, "state"));
    try std.testing.expect(try j.boolean(checked, "reconciled", false));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    try std.testing.expect(j.get(try h.run(try j.value(a, .{ .cmd = "calendar.event-pending", .account = account, .calendarId = account, .eventId = "fixture-hosted" })), "pending").? == .null);
}

test "calendar actions: an unsent delete is retried only explicitly with the identical request, or archived" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const seen = try h.event("fixture-hosted");
    const focus = try h.event("fixture-focus");
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const reviewed = try h.deleteReview("retry-delete", "fixture-hosted", j.text(seen, "etag"), "event", "all", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    try std.testing.expectError(error.CalendarOperationPending, h.respondReview("blocked", "fixture-hosted", j.text(seen, "etag"), "event", "accepted", "none", false));
    const checked = try h.execute("calendar.event-reconcile", reviewed);
    try std.testing.expectEqualStrings("unknown", j.text(checked, "state"));
    try std.testing.expect(try j.boolean(checked, "retryPossible", false));
    try std.testing.expectEqualStrings("SavedVersionStillCurrent", j.text(checked, "recoveryReason"));
    h.options.fixture_scenario = "calendar-actions";
    const retried = try h.run(try j.value(a, .{ .cmd = "calendar.event-retry", .account = account, .calendarId = account, .operationId = "retry-delete", .reviewHash = j.text(reviewed, "reviewHash"), .nextAttempt = @as(i64, 1) }));
    try std.testing.expectEqualStrings("applied", j.text(retried, "state"));
    try std.testing.expectEqualStrings("cancelled", j.text((try h.stored("fixture-hosted")).?, "status"));
    // The retry is the identical request: same event, If-Match and email.
    try h.expectSent(0, "DELETE", "fixture-hosted", "\"fixture-seed-fixture-hosted\"", "all");
    try h.expectSent(1, "DELETE", "fixture-hosted", "\"fixture-seed-fixture-hosted\"", "all");
    // Archiving an uncertainty never claims the event was kept.
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const second = try h.deleteReview("archive-delete", "fixture-focus", j.text(focus, "etag"), "event", "none", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", second), "state"));
    const archived = try h.execute("calendar.event-abandon", second);
    try std.testing.expectEqualStrings("archived", j.text(archived, "state"));
    try std.testing.expectEqualStrings("The event may already be deleted in Calendar", j.text(archived, "recoveryReason"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
}

test "calendar actions: one occurrence or the whole series, never this-and-following" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const week = try h.agendaIds("week");
    try std.testing.expect(contains(week, standup_first) and contains(week, standup_second));
    const plan = try h.deleteReview("plan-standup", standup_first, null, "event", "none", true);
    try std.testing.expect(try j.boolean(plan, "recurring", false));
    const options = j.get(plan, "options").?;
    try std.testing.expect(try j.boolean(j.get(options, "series").?, "available", false));
    try std.testing.expectEqualStrings("fixture-standup", j.text(j.get(options, "series").?, "eventId"));
    try std.testing.expect(!try j.boolean(j.get(options, "thisAndFollowing").?, "available", true));
    try std.testing.expectError(error.CalendarSeriesScopeRequired, h.deleteReview("master-as-event", "fixture-standup", null, "event", "none", true));
    try std.testing.expectError(error.CalendarNotRecurring, h.deleteReview("single-as-series", "fixture-hosted", null, "series", "none", true));
    // This occurrence only: the series keeps its other days.
    const one = try h.deleteReview("delete-one", standup_first, j.text(plan, "expectedEtag"), "event", "all", false);
    try std.testing.expectEqualStrings(standup_first, j.text(one, "targetEventId"));
    try std.testing.expectEqualStrings("Deletes this occurrence only from Personal and emails 1 guest a cancellation.", j.text(one, "consequence"));
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", one), "state"));
    var after = try h.agendaIds("week");
    try std.testing.expect(!contains(after, standup_first) and contains(after, standup_second));
    // The whole series binds the series master's own version.
    const second = try h.event(standup_second);
    const series = try h.deleteReview("delete-series", standup_second, j.text(second, "etag"), "series", "none", false);
    try std.testing.expectEqualStrings("fixture-standup", j.text(series, "targetEventId"));
    try std.testing.expectEqualStrings("Deletes every event in this series from Personal without emailing 1 guest. Guests outside Google Calendar keep their copy.", j.text(series, "consequence"));
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", series), "state"));
    // Each occurrence has its own version; the series binds the series'.
    try h.expectSent(0, "DELETE", standup_first, "\"fixture-seed-fixture-standup-1791880200000\"", "all");
    try h.expectSent(1, "DELETE", "fixture-standup", "\"fixture-seed-fixture-standup\"", "none");
    after = try h.agendaIds("week");
    for (after) |id| try std.testing.expect(!std.mem.startsWith(u8, id, "fixture-standup"));
    try std.testing.expect(contains(after, office_first));
}

test "calendar actions: attendee copies are removed locally only and never email guests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const seen = try h.event("fixture-invite");
    try std.testing.expectError(error.CalendarNotificationUnavailable, h.deleteReview("notify-host", "fixture-invite", j.text(seen, "etag"), "event", "all", false));
    const reviewed = try h.deleteReview("remove-invite", "fixture-invite", j.text(seen, "etag"), "event", "none", false);
    try std.testing.expectEqualStrings("attendee", j.text(reviewed, "role"));
    try std.testing.expect(std.mem.indexOf(u8, j.text(reviewed, "consequence"), "decline it instead") != null);
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    // A copy of someone else's event (no guest entry for this calendar).
    const copy = try h.deleteReview("plan-copy", "fixture-planning", null, "event", "none", true);
    try std.testing.expectEqualStrings("copy", j.text(copy, "role"));
}

test "calendar actions: RSVP answers as this account, refuses organizers and unchanged answers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const plan = try h.respondReview("plan-invite", "fixture-invite", null, "event", null, "none", true);
    try std.testing.expectEqualStrings("needsAction", j.text(plan, "previousResponse"));
    try std.testing.expectEqualStrings(account, j.text(plan, "attendee"));
    try std.testing.expectEqualStrings("host@example.test", j.text(plan, "organizer"));
    try std.testing.expectError(error.CalendarResponseRequired, h.respondReview("no-answer", "fixture-invite", j.text(plan, "expectedEtag"), "event", null, "all", false));
    try std.testing.expectError(error.CalendarOrganizerCannotRespond, h.respondReview("host", "fixture-hosted", null, "event", "accepted", "all", true));
    try std.testing.expectError(error.NotAnAttendee, h.respondReview("copy", "fixture-planning", null, "event", "accepted", "all", true));
    const reviewed = try h.respondReview("accept-invite", "fixture-invite", j.text(plan, "expectedEtag"), "event", "accepted", "all", false);
    try std.testing.expectEqualStrings("Accepts this event as self@example.test. Google emails your answer to the organizer host@example.test.", j.text(reviewed, "consequence"));
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    // Only this calendar's own answer is sent, against the reviewed version.
    try h.expectSent(0, "PATCH", "fixture-invite", "\"fixture-seed-fixture-invite\"", "all");
    const body = try std.json.parseFromSliceLeaky(j.Value, a, j.text((try h.sent())[0], "body"), .{});
    try std.testing.expect(try j.boolean(body, "attendeesOmitted", false));
    try std.testing.expectEqual(@as(usize, 1), j.get(body, "attendees").?.array.items.len);
    try std.testing.expectEqualStrings("accepted", j.text(j.get(body, "attendees").?.array.items[0], "responseStatus"));
    const answered = try h.event("fixture-invite");
    try std.testing.expectEqualStrings("accepted", j.text(answered, "response"));
    // Only this calendar's response changed; the organizer's entry is kept.
    for (j.get((try h.stored("fixture-invite")).?, "attendees").?.array.items) |entry| {
        if (std.mem.eql(u8, j.text(entry, "email"), "host@example.test")) try std.testing.expectEqualStrings("accepted", j.text(entry, "responseStatus"));
    }
    try std.testing.expectError(error.CalendarResponseUnchanged, h.respondReview("accept-again", "fixture-invite", j.text(answered, "etag"), "event", "accepted", "none", false));
    const declined = try h.respondReview("decline-invite", "fixture-invite", j.text(answered, "etag"), "event", "declined", "none", false);
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", declined), "state"));
    try std.testing.expectEqualStrings("declined", j.text(try h.event("fixture-invite"), "response"));
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
}

test "calendar actions: RSVP to one occurrence or a whole series, and a lost answer reconciles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const first = try h.event(office_first);
    const one = try h.respondReview("maybe-one", office_first, j.text(first, "etag"), "event", "tentative", "none", false);
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", one), "state"));
    try std.testing.expectEqualStrings("tentative", j.text(try h.event(office_first), "response"));
    try std.testing.expectEqualStrings("needs_action", j.text(try h.event(office_second), "response"));
    h.options.fixture_scenario = "calendar-actions-lost-response";
    const second = try h.event(office_second);
    const series = try h.respondReview("accept-series", office_second, j.text(second, "etag"), "series", "accepted", "all", false);
    try std.testing.expectEqualStrings("fixture-office", j.text(series, "targetEventId"));
    try std.testing.expect(std.mem.indexOf(u8, j.text(series, "consequence"), "may keep their own answer") != null);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", series), "state"));
    const checked = try h.execute("calendar.event-reconcile", series);
    try std.testing.expectEqualStrings("applied", j.text(checked, "state"));
    h.options.fixture_scenario = "calendar-actions";
    // The series answer reaches unanswered days; the separate answer stays.
    try std.testing.expectEqualStrings("accepted", j.text(try h.event(office_second), "response"));
    try std.testing.expectEqualStrings("tentative", j.text(try h.event(office_first), "response"));
}

test "calendar actions: a changed occurrence and its series each show and bind their own facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    // The plan on the changed occurrence: its own three guests and title...
    const plan = try h.deleteReview("plan-exception", standup_exception, null, "event", "none", true);
    try std.testing.expectEqualStrings("Standup with partners", j.text(plan, "summary"));
    try std.testing.expectEqual(@as(i64, 3), try j.integer(plan, "guestCount", -1));
    try std.testing.expectEqualStrings("fixture-standup", j.text(plan, "seriesEventId"));
    // ...and the series' own facts for the series choice.
    const series = j.get(j.get(plan, "options").?, "series").?;
    try std.testing.expect(try j.boolean(series, "available", false));
    try std.testing.expectEqualStrings("Standup", j.text(series, "summary"));
    try std.testing.expectEqualStrings("organizer", j.text(series, "role"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(series, "guestCount", -1));
    try std.testing.expect(!try j.boolean(series, "guestsOmitted", true));
    try std.testing.expectEqualStrings("Repeats daily", j.text(series, "recurrence"));
    try std.testing.expectEqualStrings("\"fixture-seed-fixture-standup\"", j.text(series, "etag"));
    // The series begins on the first day, not on the selected occurrence.
    const series_start = try std.json.Stringify.valueAlloc(a, j.get(series, "start").?, .{});
    try std.testing.expect(!std.mem.eql(u8, series_start, try std.json.Stringify.valueAlloc(a, j.get(plan, "start").?, .{})));
    // The series review states and binds the series' facts.
    const reviewed = try h.deleteReview("delete-series", standup_exception, j.text(plan, "expectedEtag"), "series", "all", false);
    try std.testing.expectEqualStrings("fixture-standup", j.text(reviewed, "targetEventId"));
    try std.testing.expectEqualStrings("Standup", j.text(reviewed, "summary"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(reviewed, "guestCount", -1));
    try std.testing.expectEqualStrings("Repeats daily", j.text(reviewed, "recurrence"));
    try std.testing.expectEqualStrings(series_start, try std.json.Stringify.valueAlloc(a, j.get(reviewed, "start").?, .{}));
    try std.testing.expectEqualStrings("Deletes every event in this series from Personal and emails 1 guest a cancellation.", j.text(reviewed, "consequence"));
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    try h.expectSent(0, "DELETE", "fixture-standup", "\"fixture-seed-fixture-standup\"", "all");
    // An answered occurrence of an unanswered series: each answer is its own.
    const office = try h.respondReview("plan-office", office_exception, null, "event", null, "none", true);
    try std.testing.expectEqualStrings("accepted", j.text(office, "previousResponse"));
    try std.testing.expectEqualStrings("needsAction", j.text(j.get(j.get(office, "options").?, "series").?, "response"));
    try std.testing.expectError(error.CalendarResponseUnchanged, h.respondReview("accept-again", office_exception, j.text(office, "expectedEtag"), "event", "accepted", "none", false));
    const whole = try h.respondReview("accept-series", office_exception, j.text(office, "expectedEtag"), "series", "accepted", "none", false);
    try std.testing.expectEqualStrings("needsAction", j.text(whole, "previousResponse"));
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", whole), "state"));
    try h.expectSent(1, "PATCH", "fixture-office", "\"fixture-seed-fixture-office\"", "none");
}

test "calendar actions: an unconfirmed series write blocks and is found from every occurrence, and the reverse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const first = try h.event(standup_first);
    const second = try h.event(standup_second);
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const series = try h.deleteReview("delete-series", standup_first, j.text(first, "etag"), "series", "all", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", series), "state"));
    h.options.fixture_scenario = "calendar-actions";
    // A sibling occurrence can be deleted by that series write: no new write
    // to it (not even a plan), and its pending lookup finds the series write.
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("plan-sibling", standup_second, null, "event", "none", true));
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("delete-sibling", standup_second, j.text(second, "etag"), "event", "none", false));
    for ([_][]const u8{ standup_second, standup_exception, "fixture-standup" }) |id| {
        const found = j.get(try h.run(try j.value(a, .{ .cmd = "calendar.event-pending", .account = account, .calendarId = account, .eventId = id })), "pending").?;
        try std.testing.expectEqualStrings("delete-series", j.text(j.get(found, "review").?, "operationId"));
    }
    // Other events are not held back.
    try std.testing.expect(j.get(try h.run(try j.value(a, .{ .cmd = "calendar.event-pending", .account = account, .calendarId = account, .eventId = "fixture-hosted" })), "pending").? == .null);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-reconcile", series), "state"));
    try std.testing.expectEqualStrings("archived", j.text(try h.execute("calendar.event-abandon", series), "state"));
    // The reverse: an unconfirmed answer to one occurrence holds back the
    // series (found from the series too), but not a sibling occurrence.
    const office = try h.event(office_first);
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const one = try h.respondReview("maybe-one", office_first, j.text(office, "etag"), "event", "tentative", "none", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", one), "state"));
    h.options.fixture_scenario = "calendar-actions";
    const sibling = try h.event(office_second);
    try std.testing.expectError(error.CalendarOperationPending, h.respondReview("series", office_second, j.text(sibling, "etag"), "series", "accepted", "none", false));
    const plan = try h.respondReview("plan-sibling", office_second, null, "event", null, "none", true);
    const series_option = j.get(j.get(plan, "options").?, "series").?;
    try std.testing.expect(!try j.boolean(series_option, "available", true));
    try std.testing.expectEqualStrings("CalendarOperationPending", j.text(series_option, "reason"));
    try std.testing.expectEqualStrings("maybe-one", j.text(j.get(j.get(try h.run(try j.value(a, .{ .cmd = "calendar.event-pending", .account = account, .calendarId = account, .eventId = "fixture-office" })), "pending").?, "review").?, "operationId"));
    const answered = try h.respondReview("sibling", office_second, j.text(sibling, "etag"), "event", "accepted", "none", false);
    try std.testing.expectEqualStrings("applied", j.text(try h.execute("calendar.event-apply", answered), "state"));
}

test "calendar actions: a write whose journal record fails after dispatch is an unknown outcome, then reconciles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const seen = try h.event("fixture-focus");
    const reviewed = try h.deleteReview("journal-fail", "fixture-focus", j.text(seen, "etag"), "event", "none", false);
    h.options.fixture_scenario = "calendar-actions-journal-fail";
    try std.testing.expectError(error.UnknownOutcome, h.execute("calendar.event-apply", reviewed));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    h.options.fixture_scenario = "calendar-actions";
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("again", "fixture-focus", null, "event", "none", true));
    const checked = try h.execute("calendar.event-reconcile", reviewed);
    try std.testing.expectEqualStrings("applied", j.text(checked, "state"));
    try std.testing.expect(try j.boolean(checked, "reconciled", false));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
}

test "calendar actions: series membership comes from the provider, also for `_`-leading and `_R` split series IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    _ = try h.agendaIds("day");
    const split = "abc_R20261111T150000";
    try h.injectSeries("abc", 15);
    try h.injectSeries(split, 18);
    try h.injectSeries("_xyzseries", 20);
    const plain_one = try h.occurrence("abc", 15, 0);
    const split_one = try h.occurrence(split, 18, 0);
    const split_two = try h.occurrence(split, 18, 1);
    const leading_one = try h.occurrence("_xyzseries", 20, 0);
    const leading_two = try h.occurrence("_xyzseries", 20, 1);
    const week = try h.agendaIds("week");
    try std.testing.expect(contains(week, plain_one) and contains(week, split_two) and contains(week, leading_two));
    // An unconfirmed write to the series "abc" leaves the split series
    // "abc_R…" alone: they share an ID prefix, not a series.
    const plain = try h.event(plain_one);
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const plain_series = try h.deleteReview("plain-series", plain_one, j.text(plain, "etag"), "series", "none", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", plain_series), "state"));
    h.options.fixture_scenario = "calendar-actions";
    _ = try h.deleteReview("plan-split", split_two, null, "event", "none", true);
    try std.testing.expect(j.get(try h.pendingFor(.{ .eventId = split_two }), "pending").? == .null);
    // A whole split series: its other occurrences are held back and the
    // refusal names that write; the lookup finds it with or without the
    // caller's series ID (one read of the event otherwise), and by ID.
    const seen = try h.event(split_one);
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const split_series = try h.deleteReview("split-series", split_one, j.text(seen, "etag"), "series", "none", false);
    try std.testing.expectEqualStrings(split, j.text(split_series, "targetEventId"));
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", split_series), "state"));
    h.options.fixture_scenario = "calendar-actions";
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("plan-two", split_two, null, "event", "none", true));
    try std.testing.expectEqualStrings("split-series", h.blocked.slice());
    try std.testing.expect(h.blocked.journaled);
    for ([_]?[]const u8{ null, split }) |series_id| {
        const found = try h.pendingFor(.{ .eventId = split_two, .seriesEventId = series_id });
        try std.testing.expectEqualStrings("split-series", j.text(j.get(j.get(found, "pending").?, "review").?, "operationId"));
        try std.testing.expect(try j.boolean(found, "seriesChecked", false));
    }
    try std.testing.expectEqualStrings("split-series", j.text(j.get(j.get(try h.pendingFor(.{ .operationId = "split-series" }), "pending").?, "review").?, "operationId"));
    // A series ID that begins with `_`.
    const leading = try h.event(leading_one);
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const leading_series = try h.deleteReview("leading-series", leading_one, j.text(leading, "etag"), "series", "none", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", leading_series), "state"));
    h.options.fixture_scenario = "calendar-actions";
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("plan-leading", leading_two, null, "event", "none", true));
    try std.testing.expectEqualStrings("leading-series", j.text(j.get(j.get(try h.pendingFor(.{ .eventId = leading_two }), "pending").?, "review").?, "operationId"));
    // A lookup with the series supplied reads nothing from the provider.
    const reads = try j.integer(try h.provider(), "reads", -1);
    _ = try h.pendingFor(.{ .eventId = leading_two, .seriesEventId = "_xyzseries" });
    try std.testing.expectEqual(reads, try j.integer(try h.provider(), "reads", -1));
}

test "calendar actions: an edit never overtakes an unconfirmed series write, and the reverse is found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    // An edit reviewed first, then an unconfirmed delete of its series.
    const edit = try h.editReview("edit-second", standup_second, "Standup moved");
    const first = try h.event(standup_first);
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const series = try h.deleteReview("delete-series", standup_first, j.text(first, "etag"), "series", "none", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", series), "state"));
    h.options.fixture_scenario = "calendar-actions";
    try std.testing.expectError(error.CalendarOperationPending, h.execute("calendar.event-apply", edit));
    try std.testing.expectEqualStrings("delete-series", h.blocked.slice());
    try std.testing.expectError(error.CalendarOperationPending, h.editReview("edit-again", standup_second, "Standup moved again"));
    try std.testing.expectEqual(@as(usize, 1), (try h.sent()).len);
    try std.testing.expectEqualStrings("archived", j.text(try h.execute("calendar.event-abandon", series), "state"));
    // The reverse: an unconfirmed edit of one occurrence holds back a series
    // delete, and is found from another occurrence (relation series).
    const office_edit = try h.editReview("edit-office", standup_second, "Standup moved");
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", office_edit), "state"));
    h.options.fixture_scenario = "calendar-actions";
    const fresh = try h.event(standup_first);
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("delete-series-2", standup_first, j.text(fresh, "etag"), "series", "none", false));
    try std.testing.expectEqualStrings("edit-office", h.blocked.slice());
    const found = try h.pendingFor(.{ .eventId = standup_first });
    try std.testing.expectEqualStrings("edit-office", j.text(j.get(j.get(found, "pending").?, "review").?, "operationId"));
    try std.testing.expectEqualStrings("series", j.text(j.get(found, "pending").?, "relation"));
    // Its own occurrence and the series ID find it as a write to the event.
    try std.testing.expectEqualStrings("event", j.text(j.get(try h.pendingFor(.{ .eventId = standup_second }), "pending").?, "relation"));
    try std.testing.expectEqualStrings("edit-office", j.text(j.get(j.get(try h.pendingFor(.{ .eventId = "fixture-standup" }), "pending").?, "review").?, "operationId"));
    // An action on that very occurrence waits too; this-event actions on
    // other occurrences do not.
    try std.testing.expectError(error.CalendarOperationPending, h.deleteReview("delete-second", standup_second, null, "event", "none", true));
    _ = try h.deleteReview("delete-first", standup_first, null, "event", "none", true);
}

test "calendar actions: event-pending by a series alone finds the writes on that series, and \"\" alone is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    // An unconfirmed edit of one occurrence of the series.
    const edit = try h.editReview("edit-second", standup_second, "Standup moved");
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", edit), "state"));
    h.options.fixture_scenario = "calendar-actions";
    // The series alone finds it (never a creation lookup), reading nothing.
    const reads = try j.integer(try h.provider(), "reads", -1);
    const found = try h.pendingFor(.{ .seriesEventId = "fixture-standup" });
    try std.testing.expectEqualStrings("edit-second", j.text(j.get(j.get(found, "pending").?, "review").?, "operationId"));
    try std.testing.expect(try j.boolean(found, "seriesChecked", false));
    try std.testing.expectEqual(reads, try j.integer(try h.provider(), "reads", -1));
    // Another series has nothing pending.
    try std.testing.expect(j.get(try h.pendingFor(.{ .seriesEventId = "fixture-office" }), "pending").? == .null);
    // "" says "does not repeat", which means nothing without an event.
    try std.testing.expectError(error.InvalidCalendarRequest, h.pendingFor(.{ .seriesEventId = "" }));
}

test "calendar actions: an identical RSVP retry sends the same conditional answer on the wire" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const seen = try h.event("fixture-invite");
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const reviewed = try h.respondReview("retry-answer", "fixture-invite", j.text(seen, "etag"), "event", "tentative", "all", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    h.options.fixture_scenario = "calendar-actions";
    const checked = try h.execute("calendar.event-reconcile", reviewed);
    try std.testing.expect(try j.boolean(checked, "retryPossible", false));
    const retried = try h.run(try j.value(a, .{ .cmd = "calendar.event-retry", .account = account, .calendarId = account, .operationId = "retry-answer", .reviewHash = j.text(reviewed, "reviewHash"), .nextAttempt = @as(i64, 1) }));
    try std.testing.expectEqualStrings("applied", j.text(retried, "state"));
    const requests = try h.sent();
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    for (0..2) |index| try h.expectSent(index, "PATCH", "fixture-invite", "\"fixture-seed-fixture-invite\"", "all");
    try std.testing.expectEqualStrings(j.text(requests[0], "body"), j.text(requests[1], "body"));
    try std.testing.expectEqualStrings("tentative", j.text(try h.event("fixture-invite"), "response"));
}

test "calendar actions: an occurrence stored without its series is listed as it is" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    _ = try h.agendaIds("day");
    const start = @divFloor(now, 86400000) * 86400000 + 12 * 3600000;
    const Point = struct { dateTime: []const u8 };
    const at = try t.time.format(a, .{ .kind = .instant, .value = start });
    try h.inject(try j.value(a, .{ .id = "orphan-series_1", .iCalUID = "orphan@example.test", .etag = "\"orphan-1\"", .status = "confirmed", .organizer = .{ .email = "host@example.test" }, .summary = "Orphan occurrence", .start = Point{ .dateTime = at }, .end = Point{ .dateTime = try t.time.format(a, .{ .kind = .instant, .value = start + 1800000 }) }, .sequence = 0, .recurringEventId = "orphan-series", .originalStartTime = Point{ .dateTime = at } }));
    try std.testing.expect(contains(try h.agendaIds("day"), "orphan-series_1"));
    // A changed occurrence of a stored series still replaces its expansion.
    try std.testing.expect(contains(try h.agendaIds("week"), standup_exception));
}

test "calendar actions: a 0.2.18 reader refuses a journal with a saved action instead of misreading it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const seen = try h.event("fixture-hosted");
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    const reviewed = try h.deleteReview("downgrade", "fixture-hosted", j.text(seen, "etag"), "event", "all", false);
    try std.testing.expectEqualStrings("unknown", j.text(try h.execute("calendar.event-apply", reviewed), "state"));
    var store = try storage.Store.open(std.testing.io, a, h.root, account, h.options);
    defer store.close();
    const raw = (try store.readDocument(a, "calendar-state.json", persistence.state_bytes)).?;
    // The released 0.2.18 journal shapes, parsed as 0.2.18 parses them
    // (strictly). It fails closed on the whole journal, so it can neither
    // replay nor drop the unknown delete; reinstalling 0.2.19 resumes it.
    const Release0218 = struct {
        const Review = struct {
            calendar: t.Calendar,
            source: t.Invitation,
            span: ?@import("terminal/calendar_invitation.zig").Span,
            intent: @import("terminal/calendar_plan.zig").Intent,
            request: @import("terminal/calendar_provider.zig").Request,
            review_hash: [32]u8,
            previous: ?t.Event = null,
            rsvp_response: ?@import("terminal/calendar_provider.zig").RsvpResponse = null,
            response_only: bool = false,
            ordinary_event: ?@import("terminal/calendar_event.zig").Prepared = null,
        };
        const Entry = struct { identity: @import("terminal/calendar_plan.zig").Identity, state: service.State = .{}, review: ?Review = null, ordinary: bool = false, receipt_hash: ?[32]u8 = null, receipt_reserved: bool = false };
        const StateFile = struct { schema: u8 = 1, account: []const u8, entries: []Entry = &.{}, history: @import("terminal/calendar_identity_history.zig").Root = .{} };
    };
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"event_action\":{") != null);
    // Every saved review (any kind) already carries 0.2.19's invitation reminders.
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"reminders\":[]") != null);
    try std.testing.expectError(error.UnknownField, std.json.parseFromSliceLeaky(Release0218.StateFile, a, raw, .{ .allocate = .alloc_if_needed }));
}

test "calendar actions: a shared calendar's copy says who loses it, and nobody is 'you'" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    const plan = try h.run(try j.value(a, .{ .cmd = "calendar.event-delete-review", .account = account, .calendarId = "fixture-shared-team", .eventId = "fixture-team", .scope = "event", .sendUpdates = "none", .operationId = "plan-team", .dryRun = true }));
    try std.testing.expectEqualStrings("copy", j.text(plan, "role"));
    try std.testing.expect(!try j.boolean(plan, "ownCalendar", true));
    try std.testing.expectEqualStrings("Removes this event from Shared team, for everyone who sees that calendar. The organizer's event and its guests are not changed, and Omagma sends no email.", j.text(plan, "consequence"));
}

test "calendar actions: JSONL requests are strict, explain the field and next step, and dry runs write nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const core = @import("terminal/core.zig");
    const session = try std.testing.allocator.create(core.Session);
    defer std.testing.allocator.destroy(session);
    session.* = try core.Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .fixture_root = "tests/fixtures/terminal", .fixture_scenario = "calendar-actions", .cache_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/jsonl", .{tmp.sub_path}) });
    defer session.deinit();
    const Frame = struct {
        fn send(s: *core.Session, out: std.mem.Allocator, raw: []const u8) !j.Value {
            return std.json.parseFromSliceLeaky(j.Value, out, try s.execute(out, raw), .{});
        }
    };
    const user = "personal@example.com";
    // A misspelled field never reaches the executor.
    var reply = try Frame.send(session, a, "{\"cmd\":\"calendar.event-delete-review\",\"account\":\"personal@example.com\",\"calendarId\":\"personal@example.com\",\"eventId\":\"fixture-hosted\",\"scope\":\"event\",\"sendUpdate\":\"all\",\"operationId\":\"op-1\"}");
    try std.testing.expectEqualStrings("UnknownField", j.text(j.get(reply, "error").?, "code"));
    try std.testing.expectEqualStrings("sendUpdates", j.text(j.get(reply, "error").?, "didYouMean"));
    reply = try Frame.send(session, a, "{\"cmd\":\"calendar.event-delete-review\",\"account\":\"personal@example.com\",\"calendarId\":\"personal@example.com\",\"eventId\":\"fixture-hosted\",\"scope\":\"following\",\"sendUpdates\":\"all\",\"operationId\":\"op-1\"}");
    var failure = j.get(reply, "error").?;
    try std.testing.expectEqualStrings("InvalidCalendarScope", j.text(failure, "code"));
    try std.testing.expectEqualStrings("scope", j.text(failure, "field"));
    try std.testing.expect(j.get(failure, "enum") != null);
    reply = try Frame.send(session, a, "{\"cmd\":\"calendar.event-delete-review\",\"account\":\"personal@example.com\",\"calendarId\":\"personal@example.com\",\"eventId\":\"fixture-hosted\",\"scope\":\"event\",\"sendUpdates\":\"all\",\"operationId\":\"op-1\"}");
    failure = j.get(reply, "error").?;
    try std.testing.expectEqualStrings("CalendarExpectedEtagRequired", j.text(failure, "code"));
    try std.testing.expectEqualStrings("expectedEtag", j.text(failure, "field"));
    try std.testing.expect(j.text(failure, "hint").len > 0);
    // The plan saves nothing and the apply dry run sends nothing.
    reply = try Frame.send(session, a, "{\"cmd\":\"calendar.event-delete-review\",\"account\":\"personal@example.com\",\"calendarId\":\"personal@example.com\",\"eventId\":\"fixture-hosted\",\"scope\":\"event\",\"sendUpdates\":\"none\",\"operationId\":\"op-plan\",\"dryRun\":true}");
    const plan = j.get(reply, "data").?;
    try std.testing.expect(try j.boolean(plan, "dryRun", false) and !try j.boolean(plan, "saved", true));
    const real = try std.fmt.allocPrint(a, "{{\"cmd\":\"calendar.event-delete-review\",\"account\":\"{s}\",\"calendarId\":\"{s}\",\"eventId\":\"fixture-hosted\",\"expectedEtag\":{f},\"scope\":\"event\",\"sendUpdates\":\"all\",\"operationId\":\"op-delete\"}}", .{ user, user, std.json.fmt(j.text(plan, "expectedEtag"), .{}) });
    const reviewed = j.get(try Frame.send(session, a, real), "data").?;
    const dry = try std.fmt.allocPrint(a, "{{\"cmd\":\"calendar.event-apply\",\"account\":\"{s}\",\"calendarId\":\"{s}\",\"operationId\":\"op-delete\",\"reviewHash\":\"{s}\",\"dryRun\":true}}", .{ user, user, j.text(reviewed, "reviewHash") });
    const planned = j.get(try Frame.send(session, a, dry), "data").?;
    try std.testing.expectEqualStrings("not_sent", j.text(planned, "state"));
    const agenda = try std.fmt.allocPrint(a, "{{\"cmd\":\"calendar.event\",\"account\":\"{s}\",\"calendarId\":\"{s}\",\"eventId\":\"fixture-hosted\"}}", .{ user, user });
    try std.testing.expect(!try j.boolean(j.get(j.get(try Frame.send(session, a, agenda), "data").?, "event").?, "cancelled", true));
    // dryRun stays refused where it would mean nothing.
    reply = try Frame.send(session, a, "{\"cmd\":\"calendar.event-reconcile\",\"account\":\"personal@example.com\",\"calendarId\":\"personal@example.com\",\"operationId\":\"op-delete\",\"reviewHash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"dryRun\":true}");
    try std.testing.expectEqualStrings("UnknownField", j.text(j.get(reply, "error").?, "code"));
}

test "calendar actions: missing write permission, read-only calendars and unsafe events are refused before any write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try harness(a, tmp);
    try std.testing.expectError(error.CalendarReadOnly, h.run(try j.value(a, .{ .cmd = "calendar.event-delete-review", .account = account, .calendarId = "fixture-readonly", .eventId = "fixture-day", .scope = "event", .sendUpdates = "none", .operationId = "readonly", .dryRun = true })));
    h.options.fixture_scenario = "calendar-actions-readonly";
    try std.testing.expectError(error.CalendarWritePermissionRequired, h.deleteReview("no-scope", "fixture-hosted", null, "event", "none", true));
    try std.testing.expectError(error.CalendarWritePermissionRequired, h.respondReview("no-scope-rsvp", "fixture-invite", null, "event", "accepted", "all", true));
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    // Request validation names the field before anything runs.
    try std.testing.expectError(error.InvalidCalendarScope, commands.preflight(try j.value(a, .{ .cmd = "calendar.event-delete-review", .account = account, .calendarId = account, .eventId = "x", .scope = "following", .sendUpdates = "none", .operationId = "op" })));
    try std.testing.expectError(error.InvalidCalendarResponseStatus, commands.preflight(try j.value(a, .{ .cmd = "calendar.event-respond-review", .account = account, .calendarId = account, .eventId = "x", .scope = "event", .response = "maybe", .sendUpdates = "none", .operationId = "op" })));
    try std.testing.expectError(error.InvalidCalendarRequest, commands.preflight(try j.value(a, .{ .cmd = "calendar.event-delete-review", .account = account, .calendarId = account, .eventId = "x", .scope = "event", .response = "accepted", .sendUpdates = "none", .operationId = "op" })));
    try std.testing.expectError(error.DryRunUnsupported, commands.preflight(try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .operationId = "op", .sendUpdates = "none", .dryRun = true, .event = .{ .summary = "x", .start = "2026-10-13T10:00", .end = "2026-10-13T11:00", .timeZone = "UTC" } })));
}
