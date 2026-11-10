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
}

const account = "self@example.test";
const target: t.Target = .{ .account = account, .calendar_id = account };
const now = 1791849600000; // 2026-10-13T00:00Z
const today = "2026-10-13";
const standup_first = "fixture-standup_1791880200000";
const standup_second = "fixture-standup_1791966600000";
const office_first = "fixture-office_1791910800000";
const office_second = "fixture-office_1791997200000";
const zero_hash: [64]u8 = @splat('0');

const Harness = struct {
    a: std.mem.Allocator,
    root: []const u8,
    options: mail.Options = .{ .fixtures = true, .fixture_scenario = "calendar-actions" },

    fn run(self: *Harness, request: j.Value) !j.Value {
        var backend = try fixture.Provider.init(.{ .io = std.testing.io, .allocator = std.testing.allocator, .root = self.root, .account = account, .options = self.options, .now_ms = now });
        var local: persistence.Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .result_allocator = self.a, .root = self.root, .account = account, .options = self.options };
        var env: std.process.Environ.Map = .init(self.a);
        defer env.deinit();
        const instance: service.Service = .{ .a = self.a, .grants = backend.grants(), .transport = backend.transport(), .persistence = local.persistence(), .cache = local.cache(), .now_ms = now };
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
    fn stored(self: *Harness, id: []const u8) !?j.Value {
        for (j.get(try self.provider(), "events").?.array.items) |entry| {
            const value = j.get(entry, "value").?;
            if (std.mem.eql(u8, j.text(value, "id"), id)) return value;
        }
        return null;
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
