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
        return commands.dispatch(instance, request, .{ .io = std.testing.io, .env = &env, .context = &inputs, .loadInvitationFn = Inputs.source, .loadReviewFn = Inputs.review, .loadReceiptFn = Inputs.receipt, .loadPendingFn = Inputs.pending });
    }
    fn rsvp(self: *Harness, operation: []const u8, status: provider.RsvpResponse, explicit_calendar: []const u8) !@import("terminal/calendar_rsvp.zig").Result {
        var backend = try self.transport();
        var local = self.storeHost();
        var inputs: Inputs = .{ .harness = self, .store = &local };
        var env: std.process.Environ.Map = .init(self.a);
        defer env.deinit();
        const instance: service.Service = .{ .a = self.a, .grants = backend.grants(), .transport = backend.transport(), .persistence = local.persistence(), .cache = local.cache(), .now_ms = now };
        return @import("terminal/calendar_rsvp.zig").sync(instance, try j.value(self.a, .{ .account = self.selected_account, .messageId = "synthetic-invitation", .operationId = operation, .calendarId = explicit_calendar }), .{ .io = std.testing.io, .env = &env, .context = &inputs, .loadInvitationFn = Inputs.source, .loadReviewFn = Inputs.review, .loadReceiptFn = Inputs.receipt, .loadPendingFn = Inputs.pending }, status);
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
    fn receipt(context: *anyopaque, a: std.mem.Allocator, requested: t.Target, operation_id: []const u8) anyerror!?service.Receipt {
        const self: *Inputs = @ptrCast(@alignCast(context));
        return self.store.loadReceipt(a, requested, operation_id);
    }
    fn pending(context: *anyopaque, a: std.mem.Allocator, requested: t.Target, event_id: []const u8) anyerror!?service.Pending {
        const self: *Inputs = @ptrCast(@alignCast(context));
        return self.store.loadPending(a, requested, event_id);
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

fn ordinaryRequest(a: std.mem.Allocator, operation: []const u8, guests: bool, meet: bool) !j.Value {
    var event = try j.value(a, .{ .summary = "Planning with guests", .start = "2026-10-22T10:00", .end = "2026-10-22T11:00", .timeZone = "UTC", .description = "Agenda\r\nRetained notes", .location = "Room A", .conference = if (meet) @as([]const u8, "google_meet") else "none" });
    if (guests) try event.object.put(a, "attendees", try j.value(a, [_][]const u8{"guest@example.test"}));
    return j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .operationId = operation, .sendUpdates = if (guests) @as([]const u8, "all") else "none", .event = event });
}

test "calendar ordinary: create guest Meet once then reschedule preserving conference and attendee states across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const reviewed = try h.run(try ordinaryRequest(a, "ordinary-create", true, true));
    try std.testing.expectEqualStrings("create_event", j.text(reviewed, "action"));
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    // A repeated unchanged review uses identical canonical bytes and hash.
    try std.testing.expectEqualStrings(j.text(reviewed, "reviewHash"), j.text(try h.run(try ordinaryRequest(a, "ordinary-create", true, true)), "reviewHash"));
    const applied = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    try std.testing.expectEqualStrings("applied", j.text(applied, "state"));
    const id = j.text(applied, "providerId");
    try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.event-apply", reviewed)), "state"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
    try std.testing.expect(try j.boolean(detail, "canEdit", false));
    const event = j.get(detail, "event").?;
    try std.testing.expectEqualStrings("https://meet.google.com/abc-defg-hij", j.text(event, "join_url"));
    try std.testing.expectEqualStrings("success", j.text(event, "conference_status"));
    var edited = try j.copyObject(a, j.get(detail, "eventDraft").?);
    _ = edited.object.swapRemove("attendees");
    try edited.object.put(a, "start", .{ .string = "2026-10-22T12:00" });
    try edited.object.put(a, "end", .{ .string = "2026-10-22T13:00" });
    const moved = try h.run(try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .eventId = id, .expectedEtag = j.text(event, "etag"), .operationId = "ordinary-move", .sendUpdates = "all", .event = edited }));
    // The exact native request leaves attendee/conference arrays untouched.
    var host = h.storeHost();
    const saved = try host.loadReview(a, target, "ordinary-move");
    const body = try parse(a, saved.request.body.?);
    try std.testing.expect(j.get(body, "attendees") == null and j.get(body, "conferenceData") == null);
    try std.testing.expect(std.mem.endsWith(u8, saved.request.url, "?sendUpdates=all&conferenceDataVersion=1"));
    try std.testing.expectEqualStrings(j.text(event, "etag"), saved.request.if_match.?);
    const result = try h.run(try h.executeRequest("calendar.event-apply", moved));
    try std.testing.expectEqualStrings("applied", j.text(result, "state"));
    const after = (try eventResponse(a, try h.send(try provider.get(a, target, id)))).event;
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-22T12:00:00Z"), after.start.?.value);
    try std.testing.expectEqualStrings("guest@example.test", after.attendees[0]);
    try std.testing.expectEqualStrings("https://meet.google.com/abc-defg-hij", after.join_url);
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
    // Applying an older conflicting edit never sends a second update.
    var stale = try ordinaryRequest(a, "ordinary-stale", false, false);
    try stale.object.put(a, "eventId", .{ .string = id });
    try stale.object.put(a, "expectedEtag", .{ .string = j.text(event, "etag") });
    try std.testing.expectError(error.CalendarReviewStale, h.run(stale));
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
}

test "calendar ordinary: uncertain create blocks new IDs and read-only recovery never sends invitations twice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .options = .{ .fixtures = true, .fixture_scenario = "calendar-lost-response" } };
    const reviewed = try h.run(try ordinaryRequest(a, "ordinary-uncertain", true, true));
    const unknown = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    try std.testing.expectEqualStrings("unknown", j.text(unknown, "state"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    try std.testing.expectError(error.CalendarOperationPending, h.run(try ordinaryRequest(a, "ordinary-bypass", true, true)));
    const result = try h.run(try h.executeRequest("calendar.event-reconcile", reviewed));
    try std.testing.expectEqualStrings("applied", j.text(result, "state"));
    try std.testing.expect(try j.boolean(result, "reconciled", false));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    try std.testing.expectError(error.CalendarReviewMismatch, h.run(try h.executeRequest("calendar.apply", reviewed)));
    var injected = try h.executeRequest("calendar.event-apply", reviewed);
    try injected.object.put(a, "event", try j.value(a, .{ .summary = "Injected" }));
    try std.testing.expectError(error.InvalidCalendarConfirmation, h.run(injected));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
}

test "calendar ordinary: all day exclusive dates link invitations and read-only permission are literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    var request = try ordinaryRequest(a, "all-day-link", true, false);
    var event = j.get(request, "event").?;
    try event.object.put(a, "allDay", .{ .bool = true });
    try event.object.put(a, "start", .{ .string = "2026-10-25" });
    try event.object.put(a, "end", .{ .string = "2026-10-26" });
    try event.object.put(a, "conference", .{ .string = "link" });
    try event.object.put(a, "joinUrl", .{ .string = "https://zoom.us/j/123?pwd=synthetic" });
    try request.object.put(a, "event", event);
    const reviewed = try h.run(request);
    const result = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    const after = j.get(result, "event").?;
    try std.testing.expectEqualStrings("date", j.text(j.get(after, "start").?, "kind"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(j.get(after, "end").?, "value", 0) - try j.integer(j.get(after, "start").?, "value", 0));
    try std.testing.expectEqualStrings("https://zoom.us/j/123?pwd=synthetic", j.text(after, "join_url"));
    var forbidden = try ordinaryRequest(a, "guests-silent", true, false);
    try forbidden.object.put(a, "sendUpdates", .{ .string = "none" });
    try std.testing.expectError(error.CalendarInvitationsRequireNotifications, h.run(forbidden));
    var read_only = try ordinaryRequest(a, "holiday-write", false, false);
    try read_only.object.put(a, "calendarId", .{ .string = "fixture-readonly" });
    try std.testing.expectError(error.CalendarReadOnly, h.run(read_only));
    var no_meet = try ordinaryRequest(a, "shared-meet", false, true);
    try no_meet.object.put(a, "calendarId", .{ .string = "fixture-shared-team" });
    try std.testing.expectError(error.CalendarMeetUnavailable, h.run(no_meet));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
}

test "calendar ordinary: timed all-day transitions clear opposite JSON fields and preserve pasted joins on note edits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    var request = try ordinaryRequest(a, "conversion-create", false, false);
    var draft = j.get(request, "event").?;
    try draft.object.put(a, "conference", .{ .string = "link" });
    try draft.object.put(a, "joinUrl", .{ .string = "https://teams.microsoft.com/meet/123?p=synthetic" });
    try request.object.put(a, "event", draft);
    const reviewed = try h.run(request);
    const created = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    const id = j.text(created, "providerId");
    const event = j.get(created, "event").?;
    const all_day = try j.value(a, .{ .summary = "Now all-day", .start = "2026-10-22", .end = "2026-10-23", .timeZone = "UTC", .allDay = true, .description = "Revised notes" });
    const change = try h.run(try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .operationId = "conversion-all-day", .eventId = id, .expectedEtag = j.text(event, "etag"), .sendUpdates = "none", .event = all_day }));
    try std.testing.expect(std.mem.indexOf(u8, j.text(j.get(change, "event").?, "description"), "https://teams.microsoft.com/meet/123?p=synthetic") != null);
    var host = h.storeHost();
    const saved = try host.loadReview(a, target, "conversion-all-day");
    const body = try parse(a, saved.request.body.?);
    const start = j.get(body, "start").?;
    try std.testing.expectEqualStrings("2026-10-22", j.text(start, "date"));
    try std.testing.expect(j.get(start, "dateTime").? == .null and j.get(start, "timeZone").? == .null);
    const changed = try h.run(try h.executeRequest("calendar.event-apply", change));
    try std.testing.expectEqualStrings("applied", j.text(changed, "state"));
    const changed_event = j.get(changed, "event").?;
    var timed = try ordinaryRequest(a, "conversion-timed", false, false);
    try timed.object.put(a, "eventId", .{ .string = id });
    try timed.object.put(a, "expectedEtag", .{ .string = j.text(changed_event, "etag") });
    const timed_review = try h.run(timed);
    const timed_saved = try host.loadReview(a, target, "conversion-timed");
    try std.testing.expect(j.get(j.get(try parse(a, timed_saved.request.body.?), "start").?, "date").? == .null);
    h.options.fixture_scenario = "calendar-lost-response";
    try std.testing.expectEqualStrings("unknown", j.text(try h.run(try h.executeRequest("calendar.event-apply", timed_review)), "state"));
    try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.event-reconcile", timed_review)), "state"));
    try std.testing.expectEqual(@as(i64, 3), try h.writes());
}

test "calendar ordinary: HTML notes remain byte exact and special event edit reasons are explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    var request = try ordinaryRequest(a, "html-create", false, false);
    var initial = j.get(request, "event").?;
    try initial.object.put(a, "description", .{ .string = "<p>Original <b>HTML</b> notes.</p>" });
    try request.object.put(a, "event", initial);
    const reviewed = try h.run(request);
    const created = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    const id = j.text(created, "providerId");
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
    try std.testing.expect(try j.boolean(detail, "htmlNotesReadOnly", false));
    var changed = try j.copyObject(a, j.get(detail, "eventDraft").?);
    try changed.object.put(a, "description", .{ .string = "Edited HTML" });
    const edit = try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .operationId = "html-edit", .eventId = id, .expectedEtag = j.text(j.get(detail, "event").?, "etag"), .sendUpdates = "none", .event = changed });
    try std.testing.expectError(error.CalendarHtmlNotesReadOnly, h.run(edit));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    const holiday = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = "fixture-readonly", .eventId = "fixture-day" }));
    try std.testing.expectEqualStrings("calendar_read_only", j.text(holiday, "canEditReason"));
}

test "calendar ordinary: actual composer requests pass commands and persistent provider for create then title-only edit" {
    const composer = @import("terminal/calendar_composer.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const zone: @import("terminal/timezone.zig").Zone = .{};
    const options: composer.Init = .{ .target = target, .day = try @import("terminal/timezone.zig").dateDay("2026-10-22"), .now_ms = now, .zone_name = "UTC", .zone = &zone, .supports_meet = true };
    var model = try composer.Model.init(a, options);
    try model.set(.summary, "Actual composer meeting");
    try model.set(.attendees, "colleague@example.test");
    model.send_updates = .all;
    model.conference = .google_meet;
    const request = try model.reviewRequest(a, "model-create");
    try std.testing.expect(j.get(request, "eventId") == null and j.get(request, "expectedEtag") == null);
    const reviewed = try h.run(request);
    const created = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    const id = j.text(created, "providerId");
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
    var editor = try composer.Model.initEdit(a, options, detail);
    try editor.set(.summary, "Changed title only");
    editor.send_updates = .all;
    const edit = try editor.reviewRequest(a, "model-edit");
    try std.testing.expect(j.get(j.get(edit, "event").?, "attendees") == null);
    const edit_review = try h.run(edit);
    const edited = try h.run(try h.executeRequest("calendar.event-apply", edit_review));
    try std.testing.expectEqualStrings("applied", j.text(edited, "state"));
    const result = j.get(edited, "event").?;
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-22T09:00:00Z"), try j.integer(j.get(result, "start").?, "value", -1));
    try std.testing.expectEqualStrings("Changed title only", j.text(result, "summary"));
    try std.testing.expectEqualStrings("https://meet.google.com/abc-defg-hij", j.text(result, "join_url"));
    try std.testing.expectEqualStrings("colleague@example.test", try j.string(j.get(result, "attendees").?.array.items[0]));
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
}

test "calendar ordinary: pending or failed Meet creation saves the event once without manufacturing a join URL" {
    for ([_]struct { scenario: []const u8, status: []const u8 }{ .{ .scenario = "calendar-meet-pending", .status = "pending" }, .{ .scenario = "calendar-meet-failure", .status = "failure" } }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .options = .{ .fixtures = true, .fixture_scenario = case.scenario } };
        const reviewed = try h.run(try ordinaryRequest(a, "async-meet", true, true));
        const saved = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
        try std.testing.expectEqualStrings("applied", j.text(saved, "state"));
        const event = j.get(saved, "event").?;
        try std.testing.expectEqualStrings(case.status, j.text(event, "conference_status"));
        try std.testing.expect(try j.boolean(event, "conference_present", false));
        try std.testing.expectEqualStrings("", j.text(event, "join_url"));
        try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.event-apply", reviewed)), "state"));
        try std.testing.expectEqual(@as(i64, 1), try h.writes());
    }
}

test "calendar upgrade: exact released 0.2.9 unknown update and RSVP reviews reconcile without resending" {
    for ([_][]const u8{ "legacy-029-update.json", "legacy-029-rsvp.json" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/fixtures/terminal/calendar/{s}", .{name}), a, .limited(1024 * 1024));
        const legacy = try parse(a, bytes);
        var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .selected_account = j.text(legacy, "account") };
        {
            var store = try storage.Store.open(std.testing.io, a, h.root, h.selected_account, h.options);
            defer store.close();
            try store.writeDocument("calendar-state.json", try std.json.Stringify.valueAlloc(a, j.get(legacy, "state").?, .{}));
            try store.writeDocument(fixture.document_name, try std.json.Stringify.valueAlloc(a, j.get(legacy, "provider").?, .{}));
        }
        const confirmation = j.get(legacy, "confirmation").?;
        const request = try j.value(a, .{ .cmd = "calendar.reconcile", .account = h.selected_account, .calendarId = h.selected_account, .operationId = j.text(confirmation, "operationId"), .reviewHash = j.text(confirmation, "reviewHash") });
        const result = try h.run(request);
        try std.testing.expectEqualStrings("applied", j.text(result, "state"));
        try std.testing.expect(try j.boolean(result, "reconciled", false));
        try std.testing.expectEqual(@as(i64, 2), try h.writes());
        // A changed confirmation never gains the compatibility path.
        var wrong = try j.copyObject(a, request);
        try wrong.object.put(a, "reviewHash", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" });
        try std.testing.expectError(error.CalendarReviewMismatch, h.run(wrong));
        // Newly populated metadata is not an old-shaped review and cannot
        // silently reuse an old hash, even though it is presentation-only.
        const state = j.get(legacy, "state").?;
        const entries = j.get(state, "entries").?.array.items;
        for (entries) |*entry| {
            var review = j.get(entry.*, "review") orelse continue;
            if (review == .null or !std.mem.eql(u8, j.text(j.get(review, "intent").?, "operation_id"), j.text(confirmation, "operationId"))) continue;
            var previous = j.get(review, "previous").?;
            try previous.object.put(a, "attendee_count", .{ .integer = 10 });
            try review.object.put(a, "previous", previous);
            try entry.object.put(a, "review", review);
        }
        {
            var store = try storage.Store.open(std.testing.io, a, h.root, h.selected_account, h.options);
            defer store.close();
            try store.writeDocument("calendar-state.json", try std.json.Stringify.valueAlloc(a, state, .{}));
        }
        try std.testing.expectError(error.CalendarReviewMismatch, h.run(request));
        try std.testing.expectEqual(@as(i64, 2), try h.writes());
    }
}

fn retryRequest(a: std.mem.Allocator, h: *Harness, reviewed: j.Value, attempt: u32) !j.Value {
    var value = try h.executeRequest("calendar.event-retry", reviewed);
    try value.object.put(a, "nextAttempt", .{ .integer = attempt });
    return value;
}
fn saveProvider(h: *Harness, state_value: j.Value) !void {
    var store = try storage.Store.open(std.testing.io, h.a, h.root, h.selected_account, h.options);
    defer store.close();
    try store.writeDocument(fixture.document_name, try std.json.Stringify.valueAlloc(h.a, state_value, .{}));
}
fn providerEvent(state_value: j.Value, id: []const u8) !j.Value {
    for (j.get(state_value, "events").?.array.items) |entry| {
        const event = j.get(entry, "value").?;
        if (std.mem.eql(u8, j.text(event, "id"), id)) return event;
    }
    return error.MissingProviderEvent;
}
fn replaceProviderEvent(a: std.mem.Allocator, state_value: *j.Value, event: j.Value) !void {
    const entries = j.get(state_value.*, "events").?.array.items;
    for (entries) |*entry| if (std.mem.eql(u8, j.text(j.get(entry.*, "value").?, "id"), j.text(event, "id"))) {
        try entry.object.put(a, "value", event);
        return;
    };
    return error.MissingProviderEvent;
}

test "calendar recovery: never-created 503 survives restart retries identical request once and replays terminal receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .options = .{ .fixtures = true, .fixture_scenario = "calendar-prewrite-unavailable" } };
    const reviewed = try h.run(try ordinaryRequest(a, "recovery-create", true, true));
    const unknown = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    try std.testing.expectEqualStrings("unknown", j.text(unknown, "state"));
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try h.state(), "dispatch_attempts", -1));
    // Reopening uses a fresh Host/Provider just as a new process would.
    const pending_request = try j.value(a, .{ .cmd = "calendar.event-pending", .account = account, .calendarId = account });
    const pending = j.get(try h.run(pending_request), "pending").?;
    try std.testing.expectEqualStrings(j.text(reviewed, "reviewHash"), j.text(j.get(pending, "review").?, "reviewHash"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(pending, "nextAttempt", -1));
    const checked = try h.run(try h.executeRequest("calendar.event-reconcile", reviewed));
    try std.testing.expectEqualStrings("unknown", j.text(checked, "state"));
    try std.testing.expect(try j.boolean(checked, "retryPossible", false));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try h.state(), "dispatch_attempts", -1));
    var host = h.storeHost();
    const original = try host.loadReview(a, target, "recovery-create");
    h.options.fixture_scenario = "";
    const applied = try h.run(try retryRequest(a, &h, reviewed, 1));
    try std.testing.expectEqualStrings("applied", j.text(applied, "state"));
    try std.testing.expectEqualStrings(original.intent.event_id, j.text(applied, "providerId"));
    try std.testing.expectEqual(@as(i64, 1), try h.writes());
    try std.testing.expectEqual(@as(i64, 2), try j.integer(try h.state(), "dispatch_attempts", -1));
    // Re-delivery of the same explicit retry token cannot invite again.
    try std.testing.expectEqualStrings("applied", j.text(try h.run(try retryRequest(a, &h, reviewed, 1)), "state"));
    try std.testing.expectEqualStrings("applied", j.text(try h.run(try h.executeRequest("calendar.event-apply", reviewed)), "state"));
    try std.testing.expectEqual(@as(i64, 2), try j.integer(try h.state(), "dispatch_attempts", -1));
    try std.testing.expect(j.get(try h.run(pending_request), "pending").? == .null);
}

test "calendar recovery: explicit archive records uncertainty locally frees create guard and never says not-sent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .options = .{ .fixtures = true, .fixture_scenario = "calendar-prewrite-unavailable" } };
    const reviewed = try h.run(try ordinaryRequest(a, "archive-create", true, false));
    _ = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    try std.testing.expectError(error.CalendarOperationPending, h.run(try ordinaryRequest(a, "blocked-create", false, false)));
    const archived = try h.run(try h.executeRequest("calendar.event-abandon", reviewed));
    try std.testing.expectEqualStrings("archived", j.text(archived, "state"));
    try std.testing.expectEqualStrings("UncertaintyArchived", j.text(archived, "errorCode"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try h.state(), "dispatch_attempts", -1));
    try std.testing.expectEqual(@as(i64, 0), try h.writes());
    try std.testing.expectEqualStrings("archived", j.text(try h.run(try h.executeRequest("calendar.event-apply", reviewed)), "state"));
    _ = try h.run(try ordinaryRequest(a, "allowed-create", false, false));
}

test "calendar recovery: lost response markers survive normalized title changes and later cancellation" {
    for ([_]bool{ false, true }) |cancelled| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp), .options = .{ .fixtures = true, .fixture_scenario = "calendar-lost-response" } };
        const reviewed = try h.run(try ordinaryRequest(a, "lost-create-later-edit", true, false));
        _ = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
        var state_value = try h.state();
        var event = try providerEvent(state_value, j.text(reviewed, "eventId"));
        try event.object.put(a, "summary", .{ .string = "Later change by organizer" });
        try event.object.put(a, "etag", .{ .string = "\"later-etag\"" });
        if (cancelled) try event.object.put(a, "status", .{ .string = "cancelled" });
        try replaceProviderEvent(a, &state_value, event);
        try saveProvider(&h, state_value);
        const result = try h.run(try h.executeRequest("calendar.event-reconcile", reviewed));
        try std.testing.expectEqualStrings("applied", j.text(result, "state"));
        try std.testing.expect(try j.boolean(result, "reconciled", false));
        try std.testing.expectEqual(@as(i64, 1), try h.writes());
        try std.testing.expectEqual(@as(i64, 1), try j.integer(try h.state(), "dispatch_attempts", -1));
    }
}

test "calendar recovery: unchanged ETag remains uncertain until explicit conditional retry and duplicate token is inert" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const initial = try h.run(try ordinaryRequest(a, "edit-initial", true, false));
    const created = try h.run(try h.executeRequest("calendar.event-apply", initial));
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = j.text(created, "providerId") }));
    var event = try j.copyObject(a, j.get(detail, "eventDraft").?);
    try event.object.put(a, "summary", .{ .string = "Explicit retry title" });
    const reviewed = try h.run(try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .eventId = j.text(created, "providerId"), .expectedEtag = j.text(j.get(detail, "event").?, "etag"), .operationId = "edit-uncertain", .sendUpdates = "all", .event = event }));
    h.options.fixture_scenario = "calendar-prewrite-unavailable";
    _ = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    const checked = try h.run(try h.executeRequest("calendar.event-reconcile", reviewed));
    try std.testing.expectEqualStrings("unknown", j.text(checked, "state"));
    try std.testing.expect(try j.boolean(checked, "retryPossible", false));
    try std.testing.expectEqualStrings("SavedVersionStillCurrent", j.text(checked, "recoveryReason"));
    const failed_retry = try h.run(try retryRequest(a, &h, reviewed, 1));
    try std.testing.expectEqualStrings("unknown", j.text(failed_retry, "state"));
    try std.testing.expectEqual(@as(i64, 3), try j.integer(try h.state(), "dispatch_attempts", -1));
    _ = try h.run(try retryRequest(a, &h, reviewed, 1));
    try std.testing.expectEqual(@as(i64, 3), try j.integer(try h.state(), "dispatch_attempts", -1));
    h.options.fixture_scenario = "";
    const applied = try h.run(try retryRequest(a, &h, reviewed, 2));
    try std.testing.expectEqualStrings("applied", j.text(applied, "state"));
    try std.testing.expectEqual(@as(i64, 2), try h.writes());
    try std.testing.expectEqual(@as(i64, 4), try j.integer(try h.state(), "dispatch_attempts", -1));
}

test "calendar ordinary: omitted notes and location preserve content independent endpoint zones and plain angle addresses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const initial = try h.run(try ordinaryRequest(a, "notes-initial", false, false));
    const created = try h.run(try h.executeRequest("calendar.event-apply", initial));
    const id = j.text(created, "providerId");
    var state_value = try h.state();
    var original = try providerEvent(state_value, id);
    try original.object.put(a, "description", .{ .string = "Contact <alice@example.test> and <peter@example.test>." });
    try original.object.put(a, "start", try j.value(a, .{ .dateTime = "2026-10-22T19:00:00+09:00", .timeZone = "Asia/Tokyo" }));
    try original.object.put(a, "end", try j.value(a, .{ .dateTime = "2026-10-22T07:00:00-04:00", .timeZone = "America/New_York" }));
    try replaceProviderEvent(a, &state_value, original);
    try saveProvider(&h, state_value);
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
    try std.testing.expect(!(try j.boolean(detail, "htmlNotesReadOnly", true)));
    var draft = try j.copyObject(a, j.get(detail, "eventDraft").?);
    try draft.object.put(a, "summary", .{ .string = "Title-only edit" });
    _ = draft.object.swapRemove("description");
    _ = draft.object.swapRemove("location");
    const reviewed = try h.run(try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .eventId = id, .expectedEtag = j.text(j.get(detail, "event").?, "etag"), .operationId = "notes-preserve", .sendUpdates = "none", .event = draft }));
    var host = h.storeHost();
    const saved = try host.loadReview(a, target, "notes-preserve");
    const body = try parse(a, saved.request.body.?);
    try std.testing.expectEqualStrings(j.text(original, "description"), j.text(body, "description"));
    try std.testing.expectEqualStrings("Room A", j.text(body, "location"));
    try std.testing.expect(j.get(body, "start") == null and j.get(body, "end") == null);
    _ = try h.run(try h.executeRequest("calendar.event-apply", reviewed));
    const after = try providerEvent(try h.state(), id);
    try std.testing.expectEqualStrings("America/New_York", j.text(j.get(after, "end").?, "timeZone"));
}

test "calendar ordinary: explicit organizer false prevents editing and unavailable local timezone does not prevent reading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const initial = try h.run(try ordinaryRequest(a, "owner-initial", false, false));
    const created = try h.run(try h.executeRequest("calendar.event-apply", initial));
    const id = j.text(created, "providerId");
    var state_value = try h.state();
    var event = try providerEvent(state_value, id);
    try event.object.put(a, "organizer", try j.value(a, .{ .email = account, .self = false }));
    try event.object.put(a, "start", try j.value(a, .{ .dateTime = "2026-10-22T10:00:00Z", .timeZone = "Etc/UnavailableSyntheticZone" }));
    try replaceProviderEvent(a, &state_value, event);
    try saveProvider(&h, state_value);
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
    try std.testing.expectEqualStrings("Planning with guests", j.text(j.get(detail, "event").?, "summary"));
    try std.testing.expectEqualStrings("not_organizer", j.text(detail, "canEditReason"));
    try std.testing.expect(!(try j.boolean(detail, "canEdit", true)));
    try std.testing.expect(j.text(detail, "draftError").len != 0);
}

test "calendar ordinary: moving offset-only endpoints omits empty timezone and HTML notes cannot be altered by pasted link" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = .{ .a = a, .root = try temporaryRoot(a, tmp) };
    const initial = try h.run(try ordinaryRequest(a, "offset-initial", false, false));
    const created = try h.run(try h.executeRequest("calendar.event-apply", initial));
    const id = j.text(created, "providerId");
    var state_value = try h.state();
    var event = try providerEvent(state_value, id);
    try event.object.put(a, "start", try j.value(a, .{ .dateTime = "2026-10-22T10:00:00Z" }));
    try event.object.put(a, "end", try j.value(a, .{ .dateTime = "2026-10-22T11:00:00Z" }));
    try event.object.put(a, "description", .{ .string = "<p>Exact formatted notes.</p>" });
    try replaceProviderEvent(a, &state_value, event);
    try saveProvider(&h, state_value);
    const detail = try h.run(try j.value(a, .{ .cmd = "calendar.event", .account = account, .calendarId = account, .eventId = id }));
    var draft = try j.copyObject(a, j.get(detail, "eventDraft").?);
    try draft.object.put(a, "start", .{ .string = "2026-10-22T12:00" });
    try draft.object.put(a, "end", .{ .string = "2026-10-22T13:00" });
    const request = try j.value(a, .{ .cmd = "calendar.event-review", .account = account, .calendarId = account, .eventId = id, .expectedEtag = j.text(j.get(detail, "event").?, "etag"), .operationId = "offset-move", .sendUpdates = "none", .event = draft });
    _ = try h.run(request);
    var host = h.storeHost();
    const body = try parse(a, (try host.loadReview(a, target, "offset-move")).request.body.?);
    try std.testing.expect(j.get(j.get(body, "start").?, "timeZone") == null);
    try std.testing.expect(j.get(j.get(body, "end").?, "timeZone") == null);
    try std.testing.expectEqualStrings("<p>Exact formatted notes.</p>", j.text(body, "description"));
    try draft.object.put(a, "conference", .{ .string = "link" });
    try draft.object.put(a, "joinUrl", .{ .string = "https://meet.example.test/room" });
    var pasted = try j.copyObject(a, request);
    try pasted.object.put(a, "operationId", .{ .string = "html-pasted" });
    try pasted.object.put(a, "event", draft);
    try std.testing.expectError(error.CalendarHtmlNotesReadOnly, h.run(pasted));
}
