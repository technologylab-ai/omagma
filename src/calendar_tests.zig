const std = @import("std");
const t = @import("terminal/calendar_types.zig");
const invitation = @import("terminal/calendar_invitation.zig");
const provider = @import("terminal/calendar_provider.zig");
const plan = @import("terminal/calendar_plan.zig");
const agenda = @import("terminal/calendar_agenda.zig");
const j = @import("terminal/json.zig");
const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };

test {
    std.testing.refAllDecls(t);
    std.testing.refAllDecls(invitation);
    std.testing.refAllDecls(provider);
    std.testing.refAllDecls(plan);
    std.testing.refAllDecls(agenda);
    std.testing.refAllDecls(@import("terminal/calendar_permissions.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_composer.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_guest_picker.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_slot.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_grid.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_text.zig"));
    std.testing.refAllDecls(@import("terminal/meet_notes_provider.zig"));
    std.testing.refAllDecls(@import("terminal/meet_notes_types.zig"));
    std.testing.refAllDecls(@import("terminal/meet_notes_store.zig"));
}

fn fixture(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "tests/fixtures/terminal/calendar/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(t.Limits.source_bytes));
}
fn source(a: std.mem.Allocator, name: []const u8) !t.Invitation {
    return invitation.parse(a, try fixture(a, name), target.account, &.{});
}
fn intent(value: t.Invitation) plan.Intent {
    return .{ .operation_id = "fixture-operation-1", .identity = .{ .target = target, .uid = value.uid }, .version = value.version, .kind = .import_event, .source_hash = value.source_hash, .payload_hash = @splat(0) };
}
fn tag(value: plan.Decision) std.meta.Tag(plan.Decision) {
    return std.meta.activeTag(value);
}

test "calendar: import retains source version and original organizer without inviting other guests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try source(a, "single-utc.ics");
    try std.testing.expectEqualStrings("Planning, café", value.summary);
    try std.testing.expectEqual(@as(u32, 4), value.version.sequence);
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-12T09:00:00Z"), value.version.dtstamp_ms);
    try std.testing.expect(std.mem.indexOf(u8, value.source, "X-FICTIONAL-SOURCE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.source, "other@example.test") != null);
    const request = try provider.prepareImport(a, value, intent(value), null, null);
    try std.testing.expectEqualStrings("https://www.googleapis.com/calendar/v3/calendars/primary/events/import", request.url);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    try std.testing.expectEqualStrings(value.uid, j.text(body, "iCalUID"));
    try std.testing.expectEqualStrings("host@example.test", j.text(j.get(body, "organizer").?, "email"));
    try std.testing.expect(j.get(body, "id") == null);
    try std.testing.expect(j.get(body, "privateCopy") == null);
    try std.testing.expect(j.get(body, "conferenceData") == null);
    const attendees = j.get(body, "attendees").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), attendees.len);
    try std.testing.expectEqualStrings(target.account, j.text(attendees[0], "email"));
    try std.testing.expectEqualStrings("needsAction", j.text(attendees[0], "responseStatus"));
    try std.testing.expect(std.mem.indexOf(u8, j.text(body, "description"), value.join_url) != null);
    const properties = j.get(j.get(body, "extendedProperties").?, "private").?;
    const source_hex = std.fmt.bytesToHex(value.source_hash, .lower);
    try std.testing.expectEqualStrings(&source_hex, j.text(properties, "omagmaSource"));
    try std.testing.expectEqualStrings(intent(value).operation_id, j.text(properties, "omagmaOperation"));
    const unbound = intent(value);
    const bound = try request.bindIntent(unbound);
    try std.testing.expect(!std.mem.eql(u8, &bound.payload_hash, &unbound.payload_hash));
    const changed_request: provider.Request = .{ .target = request.target, .kind = request.kind, .method = request.method, .url = request.url, .body = "{}" };
    const changed_intent = try changed_request.bindIntent(unbound);
    try std.testing.expect(!std.mem.eql(u8, &changed_intent.payload_hash, &bound.payload_hash));
}

test "calendar: all-day import retains civil dates across DST and recurrence stays explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all_day = try source(a, "all-day.ics");
    const span = try invitation.resolveSpan(all_day, null, null);
    try std.testing.expectEqual(.date, span.start.kind);
    try std.testing.expectEqual(@as(i64, 3), span.end.value - span.start.value);
    const request = try provider.prepareImport(a, all_day, intent(all_day), null, null);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    try std.testing.expectEqualStrings("2026-10-27", j.text(j.get(body, "end").?, "date"));
    try std.testing.expect(j.get(j.get(body, "start").?, "dateTime") == null);
    const recurring = try source(a, "recurring-zone.ics");
    try std.testing.expect(recurring.has_timezones);
    try std.testing.expectEqual(@as(usize, 3), recurring.recurrence.len);
    try std.testing.expectEqualStrings("EXDATE;TZID=Europe/Vienna:20261020T100000", recurring.recurrence[1]);
    try std.testing.expectError(error.UnsupportedCalendarRecurrence, provider.prepareImport(a, recurring, intent(recurring), null, null));
    const canceled = try source(a, "cancellation.ics");
    try std.testing.expectEqual(.cancel, canceled.method);
    try std.testing.expect(canceled.start == null);
    try std.testing.expectError(error.CalendarCancelled, provider.prepareImport(a, canceled, intent(canceled), null, null));
}

test "calendar: independent parser rejects ambiguous identity and unfolds split UTF8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fold@example.test\r\nDTSTAMP:20261013T080000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nDTSTART:20261013T100000Z\r\nDTEND:20261013T110000Z\r\n";
    const suffix = "END:VEVENT\r\nEND:VCALENDAR\r\n";
    const folded = try invitation.parse(a, prefix ++ "SUMMARY:caf\xc3\r\n \xa9\r\n" ++ suffix, target.account, &.{});
    try std.testing.expectEqualStrings("café", folded.summary);
    try std.testing.expectError(error.AmbiguousInvitation, invitation.parse(a, prefix ++ "UID:second@example.test\r\n" ++ suffix, target.account, &.{}));
    try std.testing.expectError(error.AmbiguousAttendee, invitation.parse(a, prefix ++ "ATTENDEE:mailto:alias@example.test\r\n" ++ suffix, target.account, &.{"alias@example.test"}));
    try std.testing.expectError(error.NotAnAttendee, invitation.parse(a, prefix ++ suffix, "another@example.test", &.{}));
    try std.testing.expectError(error.InvalidCalendarParameter, invitation.parse(a, prefix ++ "RECURRENCE-ID;TZID=Europe/Vienna;TZID=America/New_York:20261013T100000\r\n" ++ suffix, target.account, &.{}));
    const invalid_end = try invitation.parse(a, prefix ++ suffix, target.account, &.{});
    var zero_length = invalid_end;
    zero_length.end = zero_length.start;
    // DTEND equal to DTSTART is a zero-length timed event, not a defect.
    const instant = try invitation.resolveSpan(zero_length, null, null);
    try std.testing.expect(instant.start.kind == .instant and instant.end.value == instant.start.value);
    const zero_intent: plan.Intent = .{ .operation_id = "zero-length", .identity = .{ .target = target, .uid = zero_length.uid }, .version = zero_length.version, .kind = .import_event, .source_hash = zero_length.source_hash, .payload_hash = @splat(0) };
    const zero_body = try std.json.parseFromSliceLeaky(j.Value, a, (try provider.prepareImport(a, zero_length, zero_intent, null, null)).body.?, .{});
    try std.testing.expectEqualStrings(j.text(j.get(zero_body, "start").?, "dateTime"), j.text(j.get(zero_body, "end").?, "dateTime"));
    // An end before its start, or an all-day end on its own start date, is
    // still not a span this client will write without review.
    var reversed = invalid_end;
    reversed.end = reversed.start;
    reversed.start = invalid_end.end;
    try std.testing.expectError(error.CalendarEndRequiresReview, invitation.resolveSpan(reversed, null, null));
    var all_day = invalid_end;
    all_day.start = try t.time.parse("20261013", ";VALUE=DATE");
    all_day.end = all_day.start;
    try std.testing.expectError(error.CalendarEndRequiresReview, invitation.resolveSpan(all_day, null, null));
}

test "calendar RSVP: long folded Outlook descriptions fit the complete source budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:long-description@example.test\r\nDTSTAMP:20261013T080000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nDTSTART:20261013T100000Z\r\nDTEND:20261013T110000Z\r\nSUMMARY:Teams planning\r\n";
    const suffix = "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    for ([_][]const u8{ "DESCRIPTION:", "X-ALT-DESC;FMTTYPE=text/html:" }) |property_name| {
        for ([_]usize{ 4095, 4096, 4097, 16 * 1024, 64 * 1024, 120 * 1024 }) |length| {
            const content = try a.alloc(u8, length);
            @memset(content, 'x');
            const raw = try std.mem.concat(a, u8, &.{ prefix, property_name, content, suffix });
            const parsed = try invitation.parse(a, raw, target.account, &.{});
            try std.testing.expectEqualStrings(raw, parsed.source);
            if (std.mem.eql(u8, property_name, "DESCRIPTION:")) try std.testing.expectEqualSlices(u8, content, parsed.description);
            try std.testing.expectEqualStrings("Teams planning", parsed.summary);
            const span = try invitation.resolveSpan(parsed, null, null);
            try std.testing.expectEqual(try t.time.rfc3339("2026-10-13T10:00:00Z"), span.start.value);
            // A compliant sender folds physical lines; neither their count nor
            // the unfolded description may impose the former 4 KiB limit.
            if (length == 16 * 1024) {
                var folded: std.ArrayList(u8) = .empty;
                try folded.appendSlice(a, prefix);
                try folded.appendSlice(a, property_name);
                var pos: usize = 0;
                while (pos < content.len) {
                    const end = @min(pos + 60, content.len);
                    if (pos != 0) try folded.appendSlice(a, "\r\n ");
                    try folded.appendSlice(a, content[pos..end]);
                    pos = end;
                }
                try folded.appendSlice(a, suffix);
                const unfolded = try invitation.parse(a, folded.items, target.account, &.{});
                try std.testing.expectEqualSlices(u8, parsed.unfolded, unfolded.unfolded);
            }
        }
    }
    const exact = try a.alloc(u8, t.Limits.source_bytes);
    @memcpy(exact[0..prefix.len], prefix);
    @memcpy(exact[prefix.len..][0.."DESCRIPTION:".len], "DESCRIPTION:");
    @memset(exact[prefix.len + "DESCRIPTION:".len .. exact.len - suffix.len], 'x');
    @memcpy(exact[exact.len - suffix.len ..], suffix);
    _ = try invitation.parse(a, exact, target.account, &.{});
    const excessive = try std.mem.concat(a, u8, &.{ exact, "x" });
    try std.testing.expectError(error.CalendarTooLarge, invitation.parse(a, excessive, target.account, &.{}));
}

test "calendar RSVP: prepared imports also fit provider read and reconciliation bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value = try source(a, "single-utc.ics");
    const description = try a.alloc(u8, 64 * 1024 + 1);
    @memset(description, 'x');
    value.description = description[0 .. 64 * 1024];
    value.join_url = "";
    _ = try provider.prepareImport(a, value, intent(value), null, null);
    value.description = description;
    try std.testing.expectError(error.CalendarDescriptionTooLarge, provider.prepareImport(a, value, intent(value), null, null));
    value.description = description[0 .. 64 * 1024];
    value.join_url = "https://teams.microsoft.com/meet/123456";
    try std.testing.expectError(error.CalendarDescriptionTooLarge, provider.prepareImport(a, value, intent(value), null, null));
    value.description = "Normal description";
    const text = try a.alloc(u8, 4097);
    @memset(text, 'x');
    value.summary = text;
    try std.testing.expectError(error.CalendarSummaryTooLarge, provider.prepareImport(a, value, intent(value), null, null));
    value.summary = "Normal title";
    value.location = text;
    try std.testing.expectError(error.CalendarLocationTooLarge, provider.prepareImport(a, value, intent(value), null, null));
}

test "calendar: duplicate update cancellation and account decisions cannot create a second event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try source(a, "single-utc.ics");
    var input: plan.Input = .{ .invitation = value, .target = target, .lookup = .{ .target = target, .uid = value.uid, .events = &.{}, .complete = true }, .times_resolved = true };
    try std.testing.expectEqual(.import_missing, tag(try plan.plan(input)));
    const existing: t.Event = .{ .target = target, .id = "known-event", .uid = value.uid, .etag = "\"v4\"", .organizer = value.organizer };
    input.lookup.events = &.{existing};
    try std.testing.expectEqual(.existing, tag(try plan.plan(input)));
    input.lookup.events = &.{ existing, existing };
    try std.testing.expectEqual(.ambiguous, tag(try plan.plan(input)));
    input.lookup.events = &.{existing};
    input.tracked = .{ .identity = .{ .target = target, .uid = value.uid }, .event_id = existing.id, .version = value.version, .source_hash = value.source_hash };
    input.invitation.version.sequence += 1;
    try std.testing.expectEqual(.review_update, tag(try plan.plan(input)));
    var newer_provider = existing;
    newer_provider.sequence = 99;
    input.lookup.events = &.{newer_provider};
    try std.testing.expectEqual(.stale_source, tag(try plan.plan(input)));
    input.lookup.events = &.{existing};
    input.invitation = try source(a, "cancellation.ics");
    try std.testing.expectEqual(.review_cancel, tag(try plan.plan(input)));
    input.invitation = value;
    input.invitation.version.sequence -= 1;
    try std.testing.expectEqual(.stale_source, tag(try plan.plan(input)));
    input.invitation = value;
    input.lookup.events = &.{};
    try std.testing.expectEqual(.identity_conflict, tag(try plan.plan(input)));
    input.target.account = "another@example.test";
    try std.testing.expectError(error.CalendarAccountMismatch, plan.plan(input));
}

test "calendar: provider pages retain original occurrence and reject unsafe meeting links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try provider.decodePage(a, target, try fixture(a, "agenda.json"), 1234);
    try std.testing.expect(page.complete());
    try std.testing.expectEqual(@as(usize, 3), page.events.len);
    try std.testing.expectEqual(@as(i64, 3600000), page.events[0].start.?.value - page.events[0].original_start.?.value);
    try std.testing.expectEqualStrings("planningmaster", page.events[0].recurring_event_id);
    try std.testing.expectEqual(.accepted, page.events[0].response);
    try std.testing.expectEqual(.date, page.events[1].start.?.kind);
    try std.testing.expectEqualStrings("", page.events[1].join_url);
    try std.testing.expect(page.events[2].cancelled);
    try std.testing.expect(page.events[2].start == null);
    const window: t.Window = .{ .start_ms = try t.time.rfc3339("2026-10-01T00:00:00Z"), .end_ms = try t.time.rfc3339("2026-11-01T00:00:00Z"), .time_zone = "Europe/Vienna" };
    var builder = try agenda.Builder.init(target, window);
    defer builder.deinit(a);
    try builder.append(a, page, "");
    const snapshot = try builder.snapshot();
    const overlap = try agenda.availability(&.{snapshot}, .{ .kind = .instant, .value = try t.time.rfc3339("2026-10-13T09:30:00Z") }, .{ .kind = .instant, .value = try t.time.rfc3339("2026-10-13T10:30:00Z") }, "");
    try std.testing.expectEqual(@as(usize, 1), overlap.overlaps);
    try std.testing.expect(!overlap.complete); // All-day resolution is explicit.
    var cross_account = page;
    cross_account.target.account = "another@example.test";
    var isolated = try agenda.Builder.init(target, window);
    defer isolated.deinit(a);
    try std.testing.expectError(error.CalendarAccountMismatch, isolated.append(a, cross_account, ""));
}

test "calendar: requests escape IDs include hidden invitations and keep range expansion bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shared: t.Target = .{ .account = target.account, .calendar_id = "shared+team@example.test" };
    const lookup = try provider.lookup(a, shared, "meeting?showDeleted=false&x=1", "opaque+page");
    try std.testing.expect(std.mem.indexOf(u8, lookup.url, "shared%2Bteam%40example.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, lookup.url, "iCalUID=meeting%3FshowDeleted%3Dfalse%26x%3D1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lookup.url, "showHiddenInvitations=true&showDeleted=true") != null);
    const request = try provider.agenda(a, target, .{ .start_ms = 0, .end_ms = 86400000, .time_zone = "UTC" }, "");
    try std.testing.expect(std.mem.indexOf(u8, request.url, "singleEvents=true&orderBy=startTime") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.url, "syncToken") == null);
    try std.testing.expectError(error.CalendarWindowTooLarge, provider.agenda(a, target, .{ .start_ms = 0, .end_ms = 366 * 86400000, .time_zone = "UTC" }, ""));
    try std.testing.expectError(error.InvalidCalendarResponse, provider.decodePage(a, target, "{\"items\":[{\"id\":\"bad\",\"status\":\"confirmed\",\"start\":{\"dateTime\":\"2026-10-13T10:00:00\"},\"end\":{\"dateTime\":\"2026-10-13T11:00:00Z\"}}]}", 0));
}

test "calendar: conditional changes preserve etags and exclude attendee array replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var edit = intent(try source(a, "single-utc.ics"));
    edit.kind = .update_event;
    edit.event_id = "known-event";
    edit.expected_etag = "\"version-4\"";
    const request = try provider.preparePatch(a, edit, try j.value(a, .{ .summary = "Reviewed replacement" }));
    try std.testing.expectEqualStrings(edit.expected_etag, request.if_match.?);
    try std.testing.expectEqual(std.http.Method.PATCH, request.method);
    try std.testing.expectError(error.InvalidCalendarMutation, provider.preparePatch(a, edit, try j.value(a, .{ .attendees = [_]u8{} })));
    edit.expected_etag = "";
    try std.testing.expectError(error.InvalidCalendarField, provider.preparePatch(a, edit, try j.value(a, .{ .summary = "Reviewed replacement" })));
}

test "calendar: journal permits one durable dispatch and rejects changed receipts" {
    const MemoryJournal = struct {
        receipt: ?plan.Operation = null,
        writes: usize = 0,
        fail_claim: bool = false,
        fail_record: bool = false,
        corrupt_receipt: bool = false,

        fn claim(context: *anyopaque, value: plan.Intent) anyerror!plan.Claim {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_claim) return error.StorageUnavailable;
            if (self.receipt) |receipt| return .{ .operation = receipt, .fresh = false };
            self.writes += 1;
            self.receipt = .{ .intent = value };
            if (self.corrupt_receipt) self.receipt.?.intent.version.sequence += 1;
            return .{ .operation = self.receipt.?, .fresh = true };
        }
        fn record(context: *anyopaque, operation: plan.Operation) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_record) return error.StorageUnavailable;
            self.receipt = operation;
        }
        fn adapter(self: *@This()) plan.Journal {
            return .{ .context = self, .claimFn = claim, .recordFn = record };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try source(a, "single-utc.ics");
    const request = try provider.prepareImport(a, value, intent(value), null, null);
    const bound = try request.bindIntent(intent(value));
    var store: MemoryJournal = .{};
    const first = try store.adapter().claim(bound);
    try std.testing.expect(first.fresh);
    try std.testing.expectEqual(.unknown, first.operation.state);
    try std.testing.expect(!(try store.adapter().claim(bound)).fresh);
    try std.testing.expectEqual(@as(usize, 1), store.writes);
    var changed = bound;
    changed.payload_hash[0] ^= 1;
    try std.testing.expectError(error.OperationConflict, store.adapter().claim(changed));
    store.fail_record = true;
    var applied = first.operation;
    applied.state = .applied;
    applied.provider_id = "calendar-event";
    try std.testing.expectError(error.UnknownOutcome, store.adapter().record(applied));
    try std.testing.expectEqual(.unknown, store.receipt.?.state);
    var unavailable: MemoryJournal = .{ .fail_claim = true };
    try std.testing.expectError(error.StorageUnavailable, unavailable.adapter().claim(bound));
    try std.testing.expectEqual(@as(usize, 0), unavailable.writes);
    var corrupt: MemoryJournal = .{ .corrupt_receipt = true };
    try std.testing.expectError(error.OperationConflict, corrupt.adapter().claim(bound));
}

test "calendar booking: attendee-free import keeps exact source without authorizing RSVP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n" ++
        "UID:booking@example.test\r\nDTSTAMP:20261101T090000Z\r\nORGANIZER:mailto:bookings@example.test\r\n" ++
        "DTSTART:20261110T091500Z\r\nDTEND:20261110T100500Z\r\nSUMMARY:Haircut booking\r\n" ++
        "LOCATION:12 Example Street\r\nURL:https://bookings.example.test/manage\r\nDESCRIPTION:Booked service\\nPlease arrive on time.\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    try std.testing.expectError(error.NotAnAttendee, invitation.parse(a, raw, target.account, &.{}));
    const booking = try invitation.parseForCalendar(a, raw, target.account, &.{});
    try std.testing.expectEqualStrings("", booking.attendee);
    try std.testing.expectEqualStrings("Booked service\nPlease arrive on time.", booking.description);
    const request = try provider.prepareImport(a, booking, intent(booking), null, null);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    try std.testing.expectEqualStrings("https://www.googleapis.com/calendar/v3/calendars/primary/events/import", request.url);
    try std.testing.expectEqualStrings("booking@example.test", j.text(body, "iCalUID"));
    try std.testing.expectEqualStrings(target.account, j.text(j.get(body, "organizer").?, "email"));
    try std.testing.expectEqualStrings("bookings@example.test", j.text(j.get(j.get(body, "extendedProperties").?, "private").?, "omagmaOriginalOrganizer"));
    try std.testing.expectEqualStrings("Booked service\nPlease arrive on time.\n\nJoin: https://bookings.example.test/manage", j.text(body, "description"));
    try std.testing.expectEqualStrings(try provider.importDescription(a, booking.description, booking.join_url), j.text(body, "description"));
    try std.testing.expect(j.get(body, "attendees") == null);
    try std.testing.expect(j.get(body, "sendUpdates") == null);
    try std.testing.expectEqualStrings("2026-11-10T09:15:00.000Z", j.text(j.get(body, "start").?, "dateTime"));
    try std.testing.expectEqualStrings("2026-11-10T10:05:00.000Z", j.text(j.get(body, "end").?, "dateTime"));
    const foreign = try std.mem.replaceOwned(u8, a, raw, "SUMMARY:", "ATTENDEE:mailto:someone@example.test\r\nSUMMARY:");
    try std.testing.expectError(error.NotAnAttendee, invitation.parseForCalendar(a, foreign, target.account, &.{}));
    const canceled = try std.mem.replaceOwned(u8, a, raw, "SUMMARY:", "STATUS:CANCELLED\r\nSUMMARY:");
    const canceled_booking = try invitation.parseForCalendar(a, canceled, target.account, &.{});
    try std.testing.expectError(error.CalendarCancelled, provider.prepareImport(a, canceled_booking, intent(canceled_booking), null, null));
}

test "calendar provider diagnostics: bounded structured rejection details survive without terminal controls" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const detail = try provider.errorDetail(arena.allocator(), 400,
        \\{"error":{"message":"Invalid value for start.timeZone\u001b[2J\n","errors":[{"reason":"invalid","location":"start.timeZone"}]}}
    );
    try std.testing.expectEqual(@as(u16, 400), detail.status);
    try std.testing.expectEqualStrings("invalid", detail.reason);
    try std.testing.expectEqualStrings("start.timeZone", detail.location);
    try std.testing.expectEqualStrings("Invalid value for start.timeZone[2J", detail.message);
    const bad = try provider.errorDetail(arena.allocator(), 400, "not JSON");
    try std.testing.expectEqualStrings("", bad.message);
    const long = try j.encodeAlloc(arena.allocator(), .{ .@"error" = .{ .message = @as([1000]u8, @splat('x'))[0..] } }, .{});
    const bounded = try provider.errorDetail(arena.allocator(), 400, long);
    try std.testing.expectEqual(@as(usize, 512), bounded.message.len);
}

test "calendar import: frozen organizer retains the invitation mailbox grammar" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/terminal/calendar/single-utc.ics", a, .limited(t.Limits.source_bytes));
    var value = try invitation.parse(a, raw, target.account, &.{});
    for ([_][]const u8{ "organizer+tag?x@example.test", "\"quoted.local\"@example.test" }) |organizer| {
        value.organizer = organizer;
        const request = try provider.prepareImport(a, value, intent(value), null, null);
        try std.testing.expectEqualStrings(organizer, try provider.importedOrganizer(a, request));
    }
}

test "calendar: published all-day attachment imports a personal event and passive reminder, never RSVP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try fixture(a, "published-payment.ics");
    try std.testing.expectError(error.UnsupportedCalendarMethod, invitation.parse(a, raw, target.account, &.{}));
    const value = try invitation.parseForCalendar(a, raw, target.account, &.{});
    try std.testing.expect(value.method == .publish);
    try std.testing.expectEqualStrings("", value.attendee);
    try std.testing.expectEqualStrings("billing@example.test", value.organizer);
    try std.testing.expectEqualStrings("\nUtility payment due", value.summary);
    try std.testing.expectEqualStrings("\nYour fictional utility payment is due.\nReference:\tEXAMPLE-42\nKeep this reminder for your records.", value.description);
    try std.testing.expectEqual(@as(usize, 1), value.reminders.len);
    try std.testing.expectEqual(@as(u32, 2160), value.reminders[0].minutes);
    try std.testing.expectEqual(@as(usize, 0), value.unsupported_reminders);
    const span = try invitation.resolveSpan(value, null, null);
    try std.testing.expectEqual(@as(@TypeOf(span.start.kind), .date), span.start.kind);
    try std.testing.expectEqual(@as(i64, 1), span.end.value - span.start.value);
    const request = try provider.prepareImport(a, value, intent(value), null, null);
    var body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    try std.testing.expectEqualStrings("2026-11-23", j.text(j.get(body, "start").?, "date"));
    try std.testing.expectEqualStrings("2026-11-24", j.text(j.get(body, "end").?, "date"));
    try std.testing.expectEqualStrings(target.account, j.text(j.get(body, "organizer").?, "email"));
    try std.testing.expect(j.get(body, "attendees") == null);
    // Google's import response must be readable immediately and after restart,
    // including source TEXT containing a leading escaped newline.
    try body.object.put(a, "id", .{ .string = "published-copy" });
    try body.object.put(a, "etag", .{ .string = "published-etag" });
    try body.object.put(a, "status", .{ .string = "confirmed" });
    try body.object.put(a, "location", .{ .string = "First floor\nExample office" });
    const document = try provider.decodeDocument(a, target, try j.encodeAlloc(a, body, .{}));
    try std.testing.expectEqualStrings("\nUtility payment due", document.event.summary);
    try std.testing.expectEqualStrings("First floor\nExample office", document.event.location);
    try body.object.put(a, "summary", .{ .string = "bad\x1b[2J" });
    try std.testing.expectError(error.InvalidCalendarResponse, provider.decodeDocument(a, target, try j.encodeAlloc(a, body, .{})));
    const reminders = j.get(body, "reminders").?;
    try std.testing.expect(!(try j.boolean(reminders, "useDefault", true)));
    const overrides = j.get(reminders, "overrides").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), overrides.len);
    try std.testing.expectEqualStrings("popup", j.text(overrides[0], "method"));
    try std.testing.expectEqual(@as(i64, 2160), overrides[0].object.get("minutes").?.integer);
    var notice: @import("terminal/invitation.zig").Invitation = .{};
    try @import("terminal/invitation.zig").parseDisplay(raw, target.account, &.{}, &notice);
    try std.testing.expect(!notice.canRespond());
    try std.testing.expectError(error.NotInvitationRequest, @import("terminal/invitation.zig").parse(raw, target.account, &.{}, &notice));
}

test "calendar: ordinary events without METHOD or organizer are personal copies, scheduling remains strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:personal-file@example.test\r\nDTSTAMP:20261109T080000Z\r\nDTSTART;VALUE=DATE:20261123\r\nSUMMARY:Personal reminder\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const value = try invitation.parseForCalendar(a, plain, target.account, &.{});
    try std.testing.expect(value.method == .publish and value.organizer.len == 0 and value.attendee.len == 0);
    try std.testing.expectEqual(@as(i64, 1), (try invitation.resolveSpan(value, null, null)).end.value - (try invitation.resolveSpan(value, null, null)).start.value);
    try std.testing.expectError(error.InvalidCalendar, invitation.parse(a, plain, target.account, &.{}));
    const with_attendee = try std.mem.replaceOwned(u8, a, plain, "SUMMARY:", "ATTENDEE:mailto:self@example.test\r\nSUMMARY:");
    try std.testing.expectError(error.UnsupportedCalendarAttendees, invitation.parseForCalendar(a, with_attendee, target.account, &.{}));
    const reply = try std.mem.replaceOwned(u8, a, plain, "VERSION:2.0", "VERSION:2.0\r\nMETHOD:REPLY");
    try std.testing.expectError(error.UnsupportedCalendarMethod, invitation.parseForCalendar(a, reply, target.account, &.{}));
}

test "calendar: unsupported active or inexact alarms are disclosed, not executed or silently copied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try fixture(a, "published-payment.ics");
    for ([_][]const u8{ "ACTION:EMAIL", "ACTION:AUDIO", "ACTION:DISPLAY\r\nREPEAT:2\r\nDURATION:PT5M" }) |action| {
        const changed = try std.mem.replaceOwned(u8, a, raw, "ACTION:DISPLAY", action);
        const value = try invitation.parseForCalendar(a, changed, target.account, &.{});
        try std.testing.expectEqual(@as(usize, 0), value.reminders.len);
        try std.testing.expectEqual(@as(usize, 1), value.unsupported_reminders);
    }
    for ([_][]const u8{ "TRIGGER;RELATED=END:-PT10M", "TRIGGER;VALUE=DATE-TIME:20261122T080000Z", "TRIGGER:-PT10S", "TRIGGER:-P29D", "TRIGGER:-P1D", "TRIGGER:-P1W", "TRIGGER:-PT40321M", "TRIGGER:PT10M", "TRIGGER:-Pbad" }) |trigger| {
        const changed = try std.mem.replaceOwned(u8, a, raw, "TRIGGER:-PT2160M", trigger);
        const value = try invitation.parseForCalendar(a, changed, target.account, &.{});
        try std.testing.expectEqual(@as(usize, 0), value.reminders.len);
        try std.testing.expectEqual(@as(usize, 1), value.unsupported_reminders);
    }
}

test "calendar: popup conversion respects provider time and count limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try fixture(a, "published-payment.ics");
    const boundary = try std.mem.replaceOwned(u8, a, raw, "TRIGGER:-PT2160M", "TRIGGER:-PT40320M");
    const maximum = try invitation.parseForCalendar(a, boundary, target.account, &.{});
    try std.testing.expectEqual(@as(u32, 40320), maximum.reminders[0].minutes);
    var extra: std.ArrayList(u8) = .empty;
    for (0..5) |_| try extra.appendSlice(a, "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT10M\r\nDESCRIPTION:Extra\r\nEND:VALARM\r\n");
    try extra.appendSlice(a, "END:VEVENT");
    const six = try std.mem.replaceOwned(u8, a, raw, "END:VEVENT", extra.items);
    const many = try invitation.parseForCalendar(a, six, target.account, &.{});
    try std.testing.expectEqual(@as(usize, 5), many.reminders.len);
    try std.testing.expectEqual(@as(usize, 1), many.unsupported_reminders);
}

test "parser tabs: calendar labels normalize presentation whitespace without changing identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const document = "{\"id\":\"primary\",\"summary\":\"Work\\tCalendar\\nTeam\",\"timeZone\":\"Europe/Vienna\",\"accessRole\":\"owner\",\"primary\":true}";
    const calendar = try provider.decodeCalendar(a, target, document);
    try std.testing.expectEqualStrings("Work Calendar Team", calendar.summary);
    try std.testing.expect(calendar.target.eql(target));
    // The normalized name can pass the unchanged private-cache field policy.
    try t.text(calendar.summary, 4096, true);
    const bad_id = "{\"id\":\"pri\\tmary\",\"summary\":\"Team\",\"timeZone\":\"Europe/Vienna\",\"accessRole\":\"owner\"}";
    try std.testing.expectError(error.InvalidCalendarField, provider.decodeCalendar(a, target, bad_id));
    const unsafe = "{\"id\":\"primary\",\"summary\":\"bad\\u001b[2J\",\"timeZone\":\"Europe/Vienna\",\"accessRole\":\"owner\"}";
    try std.testing.expectError(error.InvalidCalendarResponse, provider.decodeCalendar(a, target, unsafe));
}

const tolerant_event = "{\"id\":\"clean\",\"etag\":\"\\\"v1\\\"\",\"status\":\"confirmed\",\"summary\":\"Planning\",\"description\":\"Agenda\",\"location\":\"Room 4\",\"start\":{\"dateTime\":\"2026-10-14T10:00:00+02:00\",\"timeZone\":\"Europe/Vienna\"},\"end\":{\"dateTime\":\"2026-10-14T11:00:00+02:00\",\"timeZone\":\"Europe/Vienna\"},\"attendees\":[{\"email\":\"self@example.test\",\"self\":true,\"responseStatus\":\"accepted\"},{\"email\":\"guest@example.test\"}]}";
fn repeated(a: std.mem.Allocator, part: []const u8, count: usize) ![]const u8 {
    const out = try a.alloc(u8, part.len * count);
    for (0..count) |index| @memcpy(out[index * part.len ..][0..part.len], part);
    return out;
}
fn expectNoTerminalControls(text: []const u8, multiline: bool) !void {
    var view = try std.unicode.Utf8View.init(text);
    var points = view.iterator();
    while (points.nextCodepoint()) |cp| {
        if (multiline and (cp == '\n' or cp == '\r' or cp == '\t')) continue;
        if (!multiline and (cp == '\n' or cp == '\t')) continue;
        try std.testing.expect(cp >= 0x20 and !(cp >= 0x7f and cp <= 0x9f) and !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069));
    }
}

test "calendar tolerant: one undecodable agenda event becomes a locked placeholder and never fails the window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "{\"items\":[" ++ tolerant_event ++
        ",{\"id\":\"broken\",\"status\":\"confirmed\",\"sequence\":\"seven\",\"summary\":\"Hidden\",\"start\":{\"dateTime\":\"2026-10-14T12:00:00Z\"},\"end\":{\"dateTime\":\"2026-10-14T13:00:00Z\"}}" ++
        ",{\"id\":\"no-end\",\"status\":\"confirmed\",\"etag\":7,\"start\":{\"date\":\"2026-10-15\"},\"end\":{\"date\":\"yesterday\"}}" ++
        ",{\"status\":\"confirmed\",\"start\":{\"date\":\"2026-10-15\"},\"end\":{\"date\":\"2026-10-16\"}}" ++
        ",{\"id\":\"timeless\",\"status\":\"confirmed\",\"sequence\":-1}" ++
        ",\"not an event\"" ++
        ",{\"id\":\"clean\",\"status\":\"confirmed\",\"start\":{\"date\":\"2026-10-15\"},\"end\":{\"date\":\"2026-10-16\"}}" ++
        "]}";
    const page = try provider.decodeAgendaPage(a, target, body, 99);
    try std.testing.expectEqual(@as(usize, 3), page.events.len);
    try std.testing.expectEqual(@as(usize, 4), page.dropped);
    try std.testing.expect(!page.events[0].locked);
    try std.testing.expectEqualStrings("Planning", page.events[0].summary);
    const broken = page.events[1];
    try std.testing.expectEqualStrings("broken", broken.id);
    try std.testing.expectEqualStrings(provider.unavailable_summary, broken.summary);
    try std.testing.expect(broken.locked and broken.etag.len == 0 and broken.description.len == 0);
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-14T12:00:00Z"), broken.start.?.value);
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-14T13:00:00Z"), broken.end.?.value);
    // An unreadable end is shown at the start rather than invented.
    try std.testing.expect(page.events[2].locked and page.events[2].end.?.eql(page.events[2].start.?));
    const calendar: t.Calendar = .{ .target = target, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true, .owned_scope_verified = true };
    try std.testing.expect(@import("terminal/calendar_event.zig").editReason(calendar, .{ .event = broken, .value = .null }).len != 0);
    // Lookup pages and write targets keep refusing the same bytes.
    if (provider.decodePage(a, target, body, 99)) |_| return error.StrictDecodeAcceptedDefect else |_| {}
    // The page bound stays a refusal: nothing bounds an unpaged response.
    var oversized: std.ArrayList(u8) = .empty;
    try oversized.appendSlice(a, "{\"items\":[");
    for (0..t.Limits.page_events + 1) |index| try oversized.appendSlice(a, try std.fmt.allocPrint(a, "{s}{{\"id\":\"e{d}\"}}", .{ if (index == 0) "" else ",", index }));
    try oversized.appendSlice(a, "]}");
    try std.testing.expectError(error.TooManyCalendarEvents, provider.decodeAgendaPage(a, target, oversized.items, 99));
}

test "calendar tolerant: each defective event property is repaired alone and locks the event against writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calendar: t.Calendar = .{ .target = target, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true, .owned_scope_verified = true };
    const editReason = @import("terminal/calendar_event.zig").editReason;
    const clean = try provider.decodeDocumentForRead(a, target, tolerant_event);
    try std.testing.expect(!clean.event.locked);
    try std.testing.expectEqualStrings("Europe/Vienna", clean.event.start.?.zone);
    try std.testing.expectEqual(.accepted, clean.event.response);
    const points20 = try repeated(a, "{\"entryPointType\":\"phone\",\"uri\":\"tel:+10000000000\"},", 20);
    const Case = struct { from: []const u8, to: []const u8, strict_refuses: bool = true };
    const cases = [_]Case{
        .{ .from = "\"summary\":\"Planning\"", .to = "\"summary\":\"Plan\\u001b[31mning\\r\"" },
        .{ .from = "\"summary\":\"Planning\"", .to = "\"summary\":\"Plan\\u009bning\\u202e\"", .strict_refuses = false },
        .{ .from = "\"summary\":\"Planning\"", .to = "\"summary\":7" },
        .{ .from = "\"location\":\"Room 4\"", .to = "\"location\":\"Room\\u00004\\u007f\"" },
        .{ .from = "\"description\":\"Agenda\"", .to = "\"description\":\"Line one\\nLine\\u0008two\"" },
        .{ .from = "\"description\":\"Agenda\"", .to = "\"description\":\"" ++ (@as([64 * 1024 + 10]u8, @splat('n'))) ++ "\"" },
        .{ .from = "\"summary\":\"Planning\"", .to = "\"summary\":\"" ++ (@as([4100]u8, @splat('s'))) ++ "\"" },
        .{ .from = "\"timeZone\":\"Europe/Vienna\"},\"end\"", .to = "\"timeZone\":\"W. Europe Standard Time\"},\"end\"" },
        .{ .from = "\"status\":\"confirmed\"", .to = "\"status\":\"synthetic\"" },
        .{ .from = "\"status\":\"confirmed\",", .to = "" },
        .{ .from = "\"dateTime\":\"2026-10-14T11:00:00+02:00\"", .to = "\"dateTime\":\"2026-10-14T09:00:00+02:00\"" },
        .{ .from = "{\"email\":\"guest@example.test\"}", .to = "{\"displayName\":\"Room without address\"}" },
        .{ .from = "{\"email\":\"guest@example.test\"}", .to = "{\"email\":\"guest@example.test\",\"self\":true,\"responseStatus\":\"declined\"}" },
        .{ .from = "\"attendees\":[", .to = try std.mem.concat(a, u8, &.{ "\"conferenceData\":{\"entryPoints\":[", points20, "{\"entryPointType\":\"video\",\"uri\":\"https://meet.example.test/room\"},", points20, "{\"entryPointType\":\"phone\",\"uri\":\"tel:+10000000001\"}]},\"attendees\":[" }) },
    };
    for (cases, 0..) |case, index| {
        const raw = try std.mem.replaceOwned(u8, a, tolerant_event, case.from, case.to);
        try std.testing.expect(!std.mem.eql(u8, raw, tolerant_event));
        // Detail view and agenda agree; neither fails and neither can write.
        const page = try provider.decodeAgendaPage(a, target, try std.fmt.allocPrint(a, "{{\"items\":[{s}]}}", .{raw}), 1);
        try std.testing.expectEqual(@as(usize, 1), page.events.len);
        try std.testing.expectEqual(@as(usize, 0), page.dropped);
        const document = try provider.decodeDocumentForRead(a, target, raw);
        for ([_]t.Event{ page.events[0], document.event }) |event| {
            try std.testing.expectEqualStrings("clean", event.id);
            try expectNoTerminalControls(event.summary, false);
            try expectNoTerminalControls(event.location, false);
            try expectNoTerminalControls(event.description, true);
            try std.testing.expect(event.summary.len <= 4096 and event.location.len <= 4096 and event.description.len <= 64 * 1024);
            try std.testing.expect(!event.cancelled and event.start != null and event.end != null and event.end.?.value >= event.start.?.value);
            // 40 entry points only withholds nothing here: the video link is
            // among the first 32 and the event stays an ordinary one.
            if (index == cases.len - 1) {
                try std.testing.expect(!event.locked);
                try std.testing.expectEqualStrings("https://meet.example.test/room", event.join_url);
                continue;
            }
            // A missing attendee address makes the list incomplete; the
            // editor never replaces an incomplete list. It is not lossy text.
            if (index == 11) {
                try std.testing.expect(event.attendees_omitted and event.attendees.len == 1 and event.attendee_count == 2);
                continue;
            }
            try std.testing.expect(event.locked);
        }
        if (index != cases.len - 1 and index != 11) try std.testing.expectEqualStrings("event_locked", editReason(calendar, document));
        if (case.strict_refuses) {
            if (provider.decodeDocument(a, target, raw)) |_| return error.StrictDecodeAcceptedDefect else |_| {}
        } else {
            // Exact provider bytes: a write that copies them back loses nothing.
            try std.testing.expectEqualStrings("Plan\xc2\x9bning\xe2\x80\xae", (try provider.decodeDocument(a, target, raw)).event.summary);
        }
    }
    const read = struct {
        fn event(allocator: std.mem.Allocator, case: Case) !t.Event {
            return (try provider.decodeDocumentForRead(allocator, target, try std.mem.replaceOwned(u8, allocator, tolerant_event, case.from, case.to))).event;
        }
    }.event;
    try std.testing.expectEqualStrings("Plan [31mning ", (try read(a, cases[0])).summary);
    try std.testing.expectEqualStrings("Plan ning", (try read(a, cases[1])).summary);
    try std.testing.expectEqualStrings("", (try read(a, cases[2])).summary);
    try std.testing.expectEqualStrings("Room 4 ", (try read(a, cases[3])).location);
    try std.testing.expectEqualStrings("Line one\nLine two", (try read(a, cases[4])).description);
    try std.testing.expectEqual(@as(usize, 64 * 1024), (try read(a, cases[5])).description.len);
    try std.testing.expectEqual(@as(usize, 4096), (try read(a, cases[6])).summary.len);
    const relabelled = try read(a, cases[7]);
    try std.testing.expectEqualStrings("", relabelled.start.?.zone);
    try std.testing.expectEqualStrings("Europe/Vienna", relabelled.end.?.zone);
    try std.testing.expectEqual(clean.event.start.?.value, relabelled.start.?.value);
    const reversed = try read(a, cases[10]);
    try std.testing.expect(reversed.end.?.eql(reversed.start.?) and reversed.start.?.eql(clean.event.start.?));
    try std.testing.expectEqual(.unknown, (try read(a, cases[12])).response);
}

test "calendar tolerant: calendar discovery skips or downgrades one defective entry and write targets stay strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const solutions = try repeated(a, "\"eventHangout\",", 20);
    const head = "{\"items\":[" ++
        "{\"id\":\"self@example.test\",\"summary\":\"Personal\",\"timeZone\":\"Europe/Vienna\",\"accessRole\":\"owner\",\"primary\":true}" ++
        ",{\"id\":\"future-role\",\"summary\":\"Shared\",\"timeZone\":\"UTC\",\"accessRole\":\"commenter\"}" ++
        ",{\"id\":\"no-zone\",\"summary\":\"Imported\",\"accessRole\":\"owner\",\"dataOwner\":\"self@example.test\"}" ++
        ",{\"id\":\"bad-zone\",\"summary\":\"Legacy\",\"timeZone\":\"W. Europe Standard Time\",\"accessRole\":\"writer\"}" ++
        ",{\"id\":\"bad-owner\",\"summary\":\"Team\\u001b[2J\\u202e\",\"timeZone\":\"UTC\",\"accessRole\":\"owner\",\"dataOwner\":\"not an address\",\"selected\":\"yes\"}" ++
        ",{\"id\":\"many-solutions\",\"summary\":\"Rooms\",\"timeZone\":\"UTC\",\"accessRole\":\"reader\",\"conferenceProperties\":{\"allowedConferenceSolutionTypes\":[\"hangoutsMeet\",";
    const body = try std.mem.concat(a, u8, &.{ head, solutions, "7]}},{\"summary\":\"No identity\",\"timeZone\":\"UTC\",\"accessRole\":\"owner\"},42]}" });
    const page = try provider.decodeCalendars(a, target.account, body);
    try std.testing.expectEqual(@as(usize, 6), page.calendars.len);
    try std.testing.expectEqual(@as(usize, 2), page.skipped);
    try std.testing.expect(page.calendars[0].writable() and page.calendars[0].owned_scope_verified);
    try std.testing.expectEqual(t.Access.none, page.calendars[1].access);
    for (page.calendars[2..4]) |calendar| {
        try std.testing.expectEqualStrings(provider.fallback_time_zone, calendar.time_zone);
        try std.testing.expectEqual(t.Access.reader, calendar.access);
        try std.testing.expect(!calendar.writable());
    }
    try std.testing.expectEqualStrings("Team [2J", page.calendars[4].summary);
    try std.testing.expect(page.calendars[4].data_owner.len == 0 and !page.calendars[4].owned_scope_verified and !page.calendars[4].selected);
    try std.testing.expect(page.calendars[5].supports_meet and !page.calendars[5].writable());
    // The strict decoder still refuses each defective entry, and the read
    // decoder never turns a defect into write access or verified ownership.
    const items = j.get(try std.json.parseFromSliceLeaky(j.Value, a, body, .{}), "items").?.array.items;
    _ = try provider.decodeCalendar(a, target, try j.encodeAlloc(a, items[0], .{}));
    for (items[1..6], page.calendars[1..6]) |item, listed| {
        const raw = try j.encodeAlloc(a, item, .{});
        const named: t.Target = .{ .account = target.account, .calendar_id = listed.target.calendar_id };
        if (provider.decodeCalendar(a, named, raw)) |_| return error.StrictDecodeAcceptedDefect else |_| {}
        const readable = try provider.decodeCalendarForRead(a, named, raw);
        try std.testing.expectEqual(listed.access, readable.access);
        try std.testing.expect(std.mem.eql(u8, listed.target.calendar_id, "bad-owner") or !readable.writable());
        try std.testing.expect(std.mem.eql(u8, listed.target.calendar_id, "no-zone") or !readable.owned_scope_verified);
    }
    try std.testing.expectError(error.CalendarIdentityMismatch, provider.decodeCalendarForRead(a, .{ .account = target.account, .calendar_id = "another" }, try j.encodeAlloc(a, items[2], .{})));
}

test "calendar tolerant: import review accepts presentation quirks and keeps identity and time strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:quirks@example.test\r\nDTSTAMP:20261013T080000Z\r\nSEQUENCE:2\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nDTSTART:20261013T100000Z\r\nDTEND:20261013T110000Z\r\n";
    const event_end = "END:VEVENT\r\n";
    const calendar_end = "END:VCALENDAR\r\n";
    const quirks = "SUMMARY:C:\\Users\\fixture\\:notes \\x\r\nSUMMARY:Second title\r\nDESCRIPTION:Trailing\\\r\nDESCRIPTION:Second notes\r\nLOCATION:Room\\, 4\r\nLOCATION:Elsewhere\r\nURL:https://example.test/first\r\nURL:https://example.test/second\r\n" ++
        "ATTENDEE:invalid:nomail\r\nATTENDEE:urn:uuid:synthetic-room\r\nATTENDEE;CUTYPE=ROOM:mailto:not an address\r\n" ++
        "STATUS:NEEDS-ACTION\r\nTRANSP:SYNTHETIC\r\nCLASS:X-SYNTHETIC\r\nX-ODD;=broken;;:value\r\nCATEGORIES;LANGUAGE:Meeting\r\n";
    const components = "BEGIN:VTODO\r\nUID:todo@example.test\r\nSUMMARY:Not the event\r\nEND:VTODO\r\nBEGIN:VJOURNAL\r\nUID:journal@example.test\r\nEND:VJOURNAL\r\nBEGIN:X-VENDOR\r\nX-DATA:1\r\nEND:X-VENDOR\r\n";
    const parsed = try invitation.parse(a, prefix ++ quirks ++ event_end ++ components ++ calendar_end, target.account, &.{});
    // "\\" is the RFC escape for one backslash; "\:" and "\x" are not
    // escapes and keep both characters, as does a trailing backslash.
    try std.testing.expectEqualStrings("C:\\Users\\fixture\\:notes \\x", parsed.summary);
    try std.testing.expectEqualStrings("Trailing\\", parsed.description);
    try std.testing.expectEqualStrings("Room, 4", parsed.location);
    try std.testing.expectEqualStrings("https://example.test/first", parsed.url);
    try std.testing.expectEqualStrings("self@example.test", parsed.attendee);
    try std.testing.expectEqualStrings("quirks@example.test", parsed.uid);
    try std.testing.expect(!parsed.cancelled and !parsed.transparent and !parsed.private);
    // Unaddressed rooms never make the account an attendee.
    try std.testing.expectError(error.NotAnAttendee, invitation.parse(a, prefix ++ quirks ++ event_end ++ calendar_end, "another@example.test", &.{}));
    // Everything a write is bound to stays single-valued and exact.
    inline for (.{ "UID:second@example.test", "DTSTART:20261013T100000Z", "DTEND:20261013T120000Z", "SEQUENCE:2", "RECURRENCE-ID:20261013T100000Z\r\nRECURRENCE-ID:20261013T100000Z", "DTSTAMP:20261013T080000Z", "ORGANIZER:mailto:host@example.test", "STATUS:CONFIRMED\r\nSTATUS:CANCELLED" }) |line| {
        try std.testing.expectError(error.AmbiguousInvitation, invitation.parse(a, prefix ++ line ++ "\r\n" ++ event_end ++ calendar_end, target.account, &.{}));
    }
    try std.testing.expectError(error.AmbiguousAttendee, invitation.parse(a, prefix ++ "ATTENDEE:mailto:self@example.test\r\n" ++ event_end ++ calendar_end, target.account, &.{}));
    try std.testing.expectError(error.AmbiguousInvitation, invitation.parse(a, try std.mem.replaceOwned(u8, a, prefix ++ event_end ++ calendar_end, "METHOD:REQUEST", "METHOD:REQUEST\r\nMETHOD:REQUEST"), target.account, &.{}));
    try std.testing.expectError(error.InvalidCalendarTime, invitation.parse(a, try std.mem.replaceOwned(u8, a, prefix ++ event_end ++ calendar_end, "DTSTART:20261013T100000Z", "DTSTART;TZID=Europe/Vienna:20261013T100000Z"), target.account, &.{}));
    try std.testing.expectError(error.InvalidCalendarParameter, invitation.parse(a, try std.mem.replaceOwned(u8, a, prefix ++ event_end ++ calendar_end, "DTSTART:", "DTSTART;VALUE=DATE-TIME;VALUE=DATE:"), target.account, &.{}));
    try std.testing.expectError(error.UnsupportedCalendarComponent, invitation.parse(a, prefix ++ event_end ++ "BEGIN:VFREEBUSY\r\nEND:VFREEBUSY\r\n" ++ calendar_end, target.account, &.{}));
    try std.testing.expectError(error.AmbiguousInvitation, invitation.parse(a, prefix ++ event_end ++ "BEGIN:VEVENT\r\nUID:quirks@example.test\r\nEND:VEVENT\r\n" ++ calendar_end, target.account, &.{}));
    // Omitted VALUE=DATE: an all-day import with civil dates.
    const dated = try invitation.parse(a, try std.mem.replaceOwned(u8, a, prefix ++ event_end ++ calendar_end, "DTSTART:20261013T100000Z\r\nDTEND:20261013T110000Z", "DTSTART:20261013\r\nDTEND:20261015"), target.account, &.{});
    const span = try invitation.resolveSpan(dated, null, null);
    try std.testing.expect(span.start.kind == .date and span.end.value - span.start.value == 2);
}
