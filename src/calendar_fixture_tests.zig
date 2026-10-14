const std = @import("std");
const fixture = @import("terminal/calendar_fixture.zig");
const commands = @import("terminal/calendar_commands.zig");
const service = @import("terminal/calendar_service.zig");
const provider = @import("terminal/calendar_provider.zig");
const persistence = @import("terminal/calendar_store.zig");
const storage = @import("terminal/store.zig");
const mail = @import("terminal/types.zig");
const t = @import("terminal/calendar_types.zig");
const j = @import("terminal/json.zig");

const account = "self@example.test";
const target: t.Target = .{ .account = account, .calendar_id = account };
const now = 1791849600000;

const Harness = struct {
    a: std.mem.Allocator,
    root: []const u8,
    options: mail.Options = .{ .fixtures = true },
    source: []const u8 = "",
    selected_account: []const u8 = account,

    fn transport(self: *Harness) !fixture.Provider {
        return fixture.Provider.init(.{ .io = std.testing.io, .allocator = std.testing.allocator, .root = self.root, .account = self.selected_account, .options = self.options, .now_ms = now });
    }
    fn storeHost(self: *Harness) persistence.Host {
        return .{ .io = std.testing.io, .allocator = std.testing.allocator, .result_allocator = self.a, .root = self.root, .account = self.selected_account, .options = self.options };
    }
    fn run(self: *Harness, request: j.Value) !j.Value {
        var backend = try self.transport();
        var local = self.storeHost();
        var inputs: Inputs = .{ .harness = self, .store = &local };
        var env: std.process.Environ.Map = .init(self.a);
        defer env.deinit();
        const instance: service.Service = .{ .a = self.a, .grants = backend.grants(), .transport = backend.transport(), .persistence = local.persistence(), .cache = local.cache(), .now_ms = now };
        return commands.dispatch(instance, request, .{ .io = std.testing.io, .env = &env, .context = &inputs, .loadInvitationFn = Inputs.source, .loadReviewFn = Inputs.review });
    }
    fn rsvp(self: *Harness, operation: []const u8, status: provider.RsvpResponse, explicit_calendar: []const u8) !@import("terminal/calendar_rsvp.zig").Result {
        var backend = try self.transport();
        var local = self.storeHost();
        var inputs: Inputs = .{ .harness = self, .store = &local };
        var env: std.process.Environ.Map = .init(self.a);
        defer env.deinit();
        const instance: service.Service = .{ .a = self.a, .grants = backend.grants(), .transport = backend.transport(), .persistence = local.persistence(), .cache = local.cache(), .now_ms = now };
        return @import("terminal/calendar_rsvp.zig").sync(instance, try j.value(self.a, .{ .account = self.selected_account, .messageId = "synthetic-invitation", .operationId = operation, .calendarId = explicit_calendar }), .{ .io = std.testing.io, .env = &env, .context = &inputs, .loadInvitationFn = Inputs.source, .loadReviewFn = Inputs.review }, status);
    }
    fn send(self: *Harness, request: provider.Request) !service.Response {
        var backend = try self.transport();
        const wire = backend.transport();
        return wire.sendFn(wire.context, self.a, request);
    }
    fn state(self: *Harness) !j.Value {
        var store = try storage.Store.open(std.testing.io, self.a, self.root, self.selected_account, self.options);
        defer store.close();
        const bytes = try store.readDocument(self.a, fixture.document_name, fixture.document_bytes) orelse return error.MissingProviderFixture;
        return parse(self.a, bytes);
    }
    fn writes(self: *Harness) !i64 {
        return j.integer(try self.state(), "writes", -1);
    }
    fn reviewRequest(self: *Harness, operation_id: []const u8) !j.Value {
        return j.value(self.a, .{ .cmd = "calendar.review", .account = self.selected_account, .calendarId = self.selected_account, .messageId = "synthetic-invitation", .operationId = operation_id });
    }
    fn executeRequest(self: *Harness, command: []const u8, reviewed: j.Value) !j.Value {
        return j.value(self.a, .{ .cmd = command, .account = self.selected_account, .calendarId = self.selected_account, .operationId = j.text(reviewed, "operationId"), .reviewHash = j.text(reviewed, "reviewHash") });
    }
};
const Inputs = struct {
    harness: *Harness,
    store: *persistence.Host,
    fn source(context: *anyopaque, a: std.mem.Allocator, requested_account: []const u8, request: j.Value) anyerror!commands.InvitationInput {
        const self: *Inputs = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings(self.harness.selected_account, requested_account);
        try std.testing.expectEqualStrings("synthetic-invitation", j.text(request, "messageId"));
        return .{ .source = try a.dupe(u8, self.harness.source) };
    }
    fn review(context: *anyopaque, a: std.mem.Allocator, requested: t.Target, operation_id: []const u8) anyerror!service.Review {
        const self: *Inputs = @ptrCast(@alignCast(context));
        return self.store.loadReview(a, requested, operation_id);
    }
};
fn parse(a: std.mem.Allocator, raw: []const u8) !j.Value {
    return std.json.parseFromSliceLeaky(j.Value, a, raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}
fn source(a: std.mem.Allocator, sequence: u32, cancel: bool) ![]const u8 {
    return std.fmt.allocPrint(
        a,
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:{s}\r\nBEGIN:VEVENT\r\n" ++
            "UID:planning-2026@example.test\r\nDTSTAMP:20261012T090000Z\r\nSEQUENCE:{d}\r\n" ++
            "ORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\n" ++
            "DTSTART:20261013T140000Z\r\nDTEND:20261013T150000Z\r\n" ++
            "SUMMARY:Synthetic planning version {d}\r\n{s}END:VEVENT\r\nEND:VCALENDAR\r\n",
        .{ if (cancel) @as([]const u8, "CANCEL") else "REQUEST", sequence, sequence, if (cancel) @as([]const u8, "STATUS:CANCELLED\r\n") else "" },
    );
}
fn temporaryRoot(a: std.mem.Allocator, tmp: std.testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/calendar-fixture", .{tmp.sub_path});
}
fn eventResponse(a: std.mem.Allocator, response: service.Response) !provider.EventDocument {
    try std.testing.expectEqual(@as(u16, 200), response.status);
    return provider.decodeDocument(a, target, response.body);
}

test "calendar fixture: live and cross-account requests stop before opening any directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try temporaryRoot(a, tmp);
    const config: fixture.Config = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = account, .options = .{}, .now_ms = now };
    try std.testing.expectError(error.FixtureOnly, fixture.Provider.init(config));
    var h: Harness = .{ .a = a, .root = root };
    try std.testing.expectError(error.CalendarAccountMismatch, h.send(try provider.listCalendars(a, "other@example.test", "")));
    var wrong_path = try provider.get(a, target, "fixture-planning");
    wrong_path.url = provider.base_url ++ "/calendars/another/events/fixture-planning";
    try std.testing.expectError(error.CalendarIdentityMismatch, h.send(wrong_path));
    var changed = try h.transport();
    changed.config.options.fixtures = false;
    const wire = changed.transport();
    try std.testing.expectError(error.FixtureOnly, wire.sendFn(wire.context, a, try provider.listCalendars(a, account, "")));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, root, .{}));
}

test "calendar fixture: calendar access day week recurrence details all-day and freebusy survive reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const listed = try h.run(try j.value(a, .{ .cmd = "calendar.list", .account = account }));
    const calendars = j.get(listed, "calendars").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), calendars.len);
    try std.testing.expect(try j.boolean(calendars[0], "canWrite", false));
    try std.testing.expect(try j.boolean(calendars[1], "canWrite", false));
    try std.testing.expect(!try j.boolean(j.get(calendars[1], "calendar").?, "owned_scope_verified", true));
    try std.testing.expect(!try j.boolean(calendars[2], "canWrite", true));
    const day = try h.run(try j.value(a, .{ .cmd = "calendar.agenda", .account = account, .calendarId = account, .date = "2026-10-13" }));
    try std.testing.expectEqual(@as(usize, 2), j.get(j.get(day, "snapshot").?, "events").?.array.items.len);
    const week = try h.run(try j.value(a, .{ .cmd = "calendar.agenda", .account = account, .calendarId = account, .date = "2026-10-13", .view = "week" }));
    const events = j.get(j.get(week, "snapshot").?, "events").?.array.items;
    try std.testing.expectEqual(@as(usize, 8), events.len);
    var occurrences: usize = 0;
    for (events) |event| {
        if (j.text(event, "recurring_event_id").len == 0) continue;
        occurrences += 1;
        const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = j.text(event, "id") }));
        try std.testing.expectEqualStrings(j.text(event, "id"), j.text(j.get(detail, "event").?, "id"));
        try std.testing.expect(j.get(j.get(detail, "event").?, "original_start").? != .null);
    }
    try std.testing.expectEqual(@as(usize, 7), occurrences);
    const all_day = try h.run(try j.value(a, .{ .cmd = "calendar.agenda", .account = account, .calendarId = "fixture-readonly", .date = "2026-10-13" }));
    const holiday = j.get(j.get(all_day, "snapshot").?, "events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), holiday.len);
    try std.testing.expectEqualStrings("date", j.text(j.get(holiday[0], "start").?, "kind"));
    const busy = try h.run(try j.value(a, .{ .cmd = "calendar.freebusy", .account = account, .calendarId = account, .date = "2026-10-13" }));
    try std.testing.expect(try j.boolean(busy, "complete", false));
    try std.testing.expectEqual(@as(usize, 2), j.get(busy, "ranges").?.array.items.len);
    var future = try h.transport();
    future.config.now_ms += 30 * 86400000;
    const wire = future.transport();
    const still_same = try eventResponse(a, try wire.sendFn(wire.context, a, try provider.get(a, target, "fixture-planning")));
    try std.testing.expectEqual(@as(i64, now + 9 * 3600000), still_same.event.start.?.value);
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
}

test "calendar fixture: separate command calls review import update cancel with durable receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .source = try source(a, 4, false) };
    const imported_review = try h.run(try h.reviewRequest("import-1"));
    try std.testing.expectEqualStrings("import_event", j.text(imported_review, "action"));
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    const imported = try h.run(try h.executeRequest("calendar.import", imported_review));
    try std.testing.expectEqualStrings("applied", j.text(imported, "state"));
    const id = j.text(imported, "providerId");
    try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.apply", imported_review)), "state"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());

    h.source = try source(a, 5, false);
    const update_review = try h.run(try h.reviewRequest("update-1"));
    try std.testing.expectEqualStrings("update_event", j.text(update_review, "action"));
    const updated = try h.run(try h.executeRequest("calendar.update", update_review));
    try std.testing.expectEqualStrings("applied", j.text(updated, "state"));
    try std.testing.expectEqualStrings(id, j.text(updated, "providerId"));
    const current = try eventResponse(a, try h.send(try provider.get(a, target, id)));
    try std.testing.expectEqualStrings("Synthetic planning version 5", current.event.summary);
    try std.testing.expectEqual(@as(u32, 5), current.event.sequence);

    h.source = try source(a, 6, true);
    const cancel_review = try h.run(try h.reviewRequest("cancel-1"));
    try std.testing.expectEqualStrings("cancel_event", j.text(cancel_review, "action"));
    try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.cancel", cancel_review)), "state"));
    try std.testing.expectEqual(@as(i64, 3), try h.writes());
    const deleted = try eventResponse(a, try h.send(try provider.get(a, target, id)));
    try std.testing.expect(deleted.event.cancelled);
    const lookup_response = try h.send(try provider.lookup(a, target, "planning-2026@example.test", ""));
    const found = try provider.decodePage(a, target, lookup_response.body, now);
    try std.testing.expectEqual(@as(usize, 1), found.events.len);
    try std.testing.expect(found.events[0].cancelled);

    var other = h;
    other.selected_account = "other@example.test";
    const empty = try other.send(try provider.lookup(a, .{ .account = other.selected_account, .calendar_id = other.selected_account }, "planning-2026@example.test", ""));
    try std.testing.expectEqual(@as(usize, 0), j.get(try parse(a, empty.body), "items").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), try other.writes());
}

test "calendar fixture: lost response is committed once and reconciles after every reopened write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .options = .{ .fixtures = true, .fixture_scenario = "calendar-lost-response" } };
    for ([_][]const u8{ "lost-import", "lost-update", "lost-cancel" }, 0..) |operation_id, index| {
        h.source = try source(a, @as(u32, @intCast(index)) + 4, index == 2);
        const reviewed = try h.run(try h.reviewRequest(operation_id));
        const uncertain = try h.run(try h.executeRequest("calendar.apply", reviewed));
        try std.testing.expectEqualStrings("unknown", j.text(uncertain, "state"));
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), try h.writes());
        const pending = try h.run(try j.value(a, .{ .cmd = "calendar.invitation-plan", .account = account, .calendarId = account, .messageId = "synthetic-invitation" }));
        const recovery = j.get(pending, "recovery").?;
        try std.testing.expectEqualStrings(j.text(reviewed, "reviewHash"), j.text(recovery, "reviewHash"));
        try std.testing.expectEqualStrings(operation_id, j.text(recovery, "operationId"));
        try std.testing.expectEqualStrings(account, j.text(recovery, "account"));
        try std.testing.expectEqualStrings(account, j.text(recovery, "calendarId"));
        const reconciled = try h.run(try h.executeRequest("calendar.reconcile", recovery));
        try std.testing.expectEqualStrings("applied", j.text(reconciled, "state"));
        try std.testing.expect(try j.boolean(reconciled, "reconciled", false));
        try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.apply", reviewed)), "state"));
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), try h.writes());
    }
}

test "calendar fixture: stale If-Match cannot patch or delete and unrelated event data is preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const get = try provider.get(a, target, "fixture-planning");
    const before = try eventResponse(a, try h.send(get));
    var patch: provider.Request = .{ .target = target, .kind = .update_event, .method = .PATCH, .url = get.url, .if_match = "\"wrong\"", .body = "{\"summary\":\"Changed once\",\"extendedProperties\":{\"private\":{\"newProperty\":\"new value\"}}}" };
    try std.testing.expectEqual(@as(u16, 412), (try h.send(patch)).status);
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    patch.if_match = before.event.etag;
    const changed = try eventResponse(a, try h.send(patch));
    try std.testing.expectEqualStrings("Changed once", changed.event.summary);
    try std.testing.expectEqualStrings(before.event.join_url, changed.event.join_url);
    const properties = j.get(j.get(changed.value, "extendedProperties").?, "private").?;
    try std.testing.expectEqualStrings("preserved", j.text(properties, "fixtureProperty"));
    try std.testing.expectEqualStrings("new value", j.text(properties, "newProperty"));
    try std.testing.expectEqual(@as(u16, 412), (try h.send(patch)).status);
    var remove: provider.Request = .{ .target = target, .kind = .cancel_event, .method = .DELETE, .url = get.url, .if_match = before.event.etag };
    try std.testing.expectEqual(@as(u16, 412), (try h.send(remove)).status);
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    remove.if_match = changed.event.etag;
    try std.testing.expectEqual(@as(u16, 204), (try h.send(remove)).status);
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
    h.options.fixture_scenario = "calendar-readonly";
    try std.testing.expectEqual(@as(u16, 403), (try h.send(patch)).status);
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
}

test "calendar fixture: paginated persisted events return a complete service snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    _ = try h.send(try provider.listCalendars(a, account, ""));
    var state = try h.state();
    const template = j.get(state, "events").?.array.items[0];
    var records: std.ArrayList(j.Value) = .empty;
    for (0..105) |index| {
        var record = try j.copyObject(a, template);
        var value = try j.copyObject(a, j.get(template, "value").?);
        try value.object.put(a, "id", .{ .string = try std.fmt.allocPrint(a, "paged-{d}", .{index}) });
        try record.object.put(a, "value", value);
        try records.append(a, record);
    }
    try state.object.put(a, "events", try j.value(a, records.items));
    {
        var local = try storage.Store.open(std.testing.io, a, h.root, account, h.options);
        defer local.close();
        try local.writeDocument(fixture.document_name, try std.json.Stringify.valueAlloc(a, state, .{}));
    }
    const window: t.Window = .{ .start_ms = now, .end_ms = now + 86400000, .time_zone = "UTC" };
    const first = try h.send(try provider.agenda(a, target, window, ""));
    const page = try provider.decodePage(a, target, first.body, now);
    try std.testing.expectEqual(@as(usize, 100), page.events.len);
    try std.testing.expect(page.next_page_token.len != 0);
    const second = try h.send(try provider.agenda(a, target, window, page.next_page_token));
    try std.testing.expectEqual(@as(usize, 5), (try provider.decodePage(a, target, second.body, now)).events.len);
    const result = try h.run(try j.value(a, .{ .cmd = "calendar.agenda", .account = account, .calendarId = account, .date = "2026-10-13" }));
    const snapshot = j.get(result, "snapshot").?;
    try std.testing.expect(try j.boolean(snapshot, "complete", false));
    try std.testing.expectEqual(@as(usize, 105), j.get(snapshot, "events").?.array.items.len);
}

test "calendar RSVP: accepted imports once and tentative changes only the attendee response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .source = try source(a, 1, false) };
    const first = try h.rsvp("mail-accepted", .accepted, "");
    try std.testing.expectEqual(.applied, first.state);
    try std.testing.expectEqualStrings(account, first.calendarId);
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    const before = try eventResponse(a, try h.send(try provider.get(a, target, first.eventId)));
    try std.testing.expect(provider.responseMatches(before, account, .accepted));
    const repeated = try h.rsvp("mail-accepted", .accepted, "");
    try std.testing.expectEqual(.applied, repeated.state);
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    const tentative = try h.rsvp("mail-tentative", .tentative, "");
    try std.testing.expectEqual(.applied, tentative.state);
    try std.testing.expectEqualStrings(first.eventId, tentative.eventId);
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
    const after = try eventResponse(a, try h.send(try provider.get(a, target, first.eventId)));
    try std.testing.expect(provider.responseMatches(after, account, .tentative));
    try std.testing.expectEqualStrings(before.event.organizer, after.event.organizer);
    try std.testing.expectEqualStrings(before.event.summary, after.event.summary);
    try std.testing.expectEqual(before.event.start.?.value, after.event.start.?.value);
    try std.testing.expectEqual(before.event.sequence, after.event.sequence);
}

test "calendar RSVP: lost mutation response reconciles read-only after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .source = try source(a, 1, false), .options = .{ .fixtures = true, .fixture_scenario = "calendar-lost-response" } };
    const lost = try h.rsvp("mail-accepted-lost", .accepted, "");
    try std.testing.expectEqual(.unknown, lost.state);
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    h.options.fixture_scenario = "";
    const resolved = try h.rsvp("mail-accepted-lost", .accepted, "");
    try std.testing.expectEqual(.applied, resolved.state);
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
}

test "calendar RSVP: readonly calendars permissions and recurrence cannot cause imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .source = try source(a, 1, false), .options = .{ .fixtures = true, .fixture_scenario = "calendar-readonly" } };
    try std.testing.expectError(error.CalendarWritePermissionRequired, h.rsvp("readonly", .accepted, ""));
    h.options.fixture_scenario = "";
    try std.testing.expectError(error.CalendarReadOnly, h.rsvp("reader", .accepted, "fixture-readonly"));
    h.source = try std.mem.replaceOwned(u8, a, h.source, "SUMMARY:", "RRULE:FREQ=DAILY\r\nSUMMARY:");
    const recurring = try h.rsvp("recurring", .accepted, "");
    try std.testing.expectEqual(.skipped, recurring.state);
    try std.testing.expectEqualStrings("UnsupportedCalendarRecurrence", recurring.errorCode);
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
}

test "calendar RSVP: existing untracked UID preserves other attendees and organizer fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .source = try source(a, 1, false) };
    _ = try h.run(try h.reviewRequest("prepare-provider-event"));
    var local = h.storeHost();
    const initial = try local.loadReview(a, target, "prepare-provider-event");
    var request = initial.request;
    var body = try parse(a, request.body.?);
    try body.object.put(a, "attendees", try j.value(a, .{ .{ .email = account, .responseStatus = "needsAction" }, .{ .email = "peer@example.test", .responseStatus = "accepted" } }));
    try body.object.put(a, "summary", .{ .string = "Organizer title retained" });
    request.body = try std.json.Stringify.valueAlloc(a, body, .{});
    const existing = try eventResponse(a, try h.send(request));
    const result = try h.rsvp("mail-existing", .tentative, "");
    try std.testing.expectEqual(.applied, result.state);
    try std.testing.expectEqualStrings(existing.event.id, result.eventId);
    const after = try eventResponse(a, try h.send(try provider.get(a, target, result.eventId)));
    try std.testing.expectEqualStrings("Organizer title retained", after.event.summary);
    try std.testing.expect(provider.responseMatches(after, account, .tentative));
    try std.testing.expect(provider.responseMatches(after, "peer@example.test", .accepted));
    try std.testing.expectEqual(@as(usize, 2), j.get(after.value, "attendees").?.array.items.len);
    try std.testing.expectEqual(existing.event.start.?.value, after.event.start.?.value);
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
}
