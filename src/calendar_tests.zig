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
    std.testing.refAllDecls(@import("terminal/calendar_week_rows.zig"));
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
    try std.testing.expectError(error.CalendarEndRequiresReview, invitation.resolveSpan(zero_length, null, null));
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
