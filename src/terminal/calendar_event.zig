//! Ordinary event drafts and exact reviewed Google Calendar mutations.
//! No credentials or writes occur here. Civil times are strict: a fold needs
//! an explicit UTC offset; a gap is always refused.
const std = @import("std");
const t = @import("calendar_types.zig");
const p = @import("calendar_provider.zig");
const plan = @import("calendar_plan.zig");
const j = @import("json.zig");
const timezone = @import("timezone.zig");
const invitation = @import("calendar_invitation.zig");

pub const Draft = struct {
    summary: []const u8,
    start: []const u8,
    end: []const u8,
    timeZone: []const u8,
    allDay: bool = false,
    description: []const u8 = "",
    location: []const u8 = "",
    /// null preserves the complete provider list when editing.
    attendees: ?[]const []const u8 = null,
    conference: enum { none, google_meet, link } = .none,
    joinUrl: []const u8 = "",
    startOffset: []const u8 = "",
    endOffset: []const u8 = "",
};
pub const UpdatePolicy = enum { none, all };
pub const Prepared = struct { draft: Draft, span: invitation.Span, send_updates: UpdatePolicy };

pub fn parse(a: std.mem.Allocator, request: j.Value, zone: *const timezone.Zone) !Prepared {
    const value = j.get(request, "event") orelse return error.InvalidCalendarEvent;
    if (value != .object) return error.InvalidCalendarEvent;
    var fields = value.object.iterator();
    while (fields.next()) |field| {
        var valid = false;
        for ([_][]const u8{ "summary", "start", "end", "timeZone", "allDay", "description", "location", "attendees", "conference", "joinUrl", "startOffset", "endOffset" }) |name| valid = valid or std.mem.eql(u8, name, field.key_ptr.*);
        if (!valid) return error.InvalidCalendarEvent;
    }
    var draft: Draft = .{
        .summary = try j.required(value, "summary"),
        .start = try j.required(value, "start"),
        .end = try j.required(value, "end"),
        .timeZone = try j.required(value, "timeZone"),
        .allDay = try j.boolean(value, "allDay", false),
        .description = try optional(value, "description"),
        .location = try optional(value, "location"),
        .joinUrl = try optional(value, "joinUrl"),
        .startOffset = try optional(value, "startOffset"),
        .endOffset = try optional(value, "endOffset"),
    };
    try t.text(draft.summary, 4096, false);
    if (std.mem.trim(u8, draft.summary, " \t\r\n").len == 0) return error.CalendarTitleRequired;
    try t.text(draft.location, 4096, true);
    try multiline(draft.description);
    try t.time.validateZoneName(draft.timeZone);
    if (j.get(value, "conference")) |raw| if (raw != .null) {
        draft.conference = std.meta.stringToEnum(@TypeOf(draft.conference), try j.string(raw)) orelse return error.InvalidCalendarConference;
    };
    if (draft.conference == .link) {
        if (!std.mem.startsWith(u8, draft.joinUrl, "https://") or !@import("reader_tools.zig").safeUrl(draft.joinUrl)) return error.InvalidCalendarJoinUrl;
    } else if (draft.joinUrl.len != 0) return error.InvalidCalendarConference;
    if (j.get(value, "attendees")) |raw| if (raw != .null) {
        if (raw != .array or raw.array.items.len > 200) return error.TooManyCalendarAttendees;
        const emails = try a.alloc([]const u8, raw.array.items.len);
        for (raw.array.items, emails, 0..) |entry, *email, index| {
            email.* = try j.string(entry);
            try @import("../bounded.zig").address(email.*);
            for (emails[0..index]) |previous| if (std.ascii.eqlIgnoreCase(previous, email.*)) return error.DuplicateCalendarAttendee;
        }
        draft.attendees = emails;
    };
    const policy = std.meta.stringToEnum(UpdatePolicy, try j.required(request, "sendUpdates")) orelse return error.InvalidCalendarNotificationPolicy;
    const start = try resolve(draft.start, draft.startOffset, draft.allDay, draft.timeZone, zone);
    const end = try resolve(draft.end, draft.endOffset, draft.allDay, draft.timeZone, zone);
    if (end.value <= start.value) return error.CalendarEndBeforeStart;
    const duration = end.value - start.value;
    if (duration > (if (draft.allDay) @as(i64, 36600) else @as(i64, 36600 * 86400000))) return error.InvalidCalendarTime;
    return .{ .draft = draft, .span = .{ .start = start, .end = end }, .send_updates = policy };
}

fn optional(value: j.Value, field: []const u8) ![]const u8 {
    return if (j.get(value, field)) |raw| if (raw == .null) "" else try j.string(raw) else "";
}
fn multiline(value: []const u8) !void {
    if (value.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidCalendarField;
    for (value) |byte| if ((byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') or byte == 127) return error.InvalidCalendarField;
}
fn offset(raw: []const u8) !i32 {
    if (raw.len != 6 or (raw[0] != '+' and raw[0] != '-') or raw[3] != ':') return error.InvalidCalendarOffset;
    const hours = std.fmt.parseInt(u8, raw[1..3], 10) catch return error.InvalidCalendarOffset;
    const minutes = std.fmt.parseInt(u8, raw[4..6], 10) catch return error.InvalidCalendarOffset;
    if (hours > 23 or minutes > 59) return error.InvalidCalendarOffset;
    for ([_]usize{ 1, 2, 4, 5 }) |index| if (!std.ascii.isDigit(raw[index])) return error.InvalidCalendarOffset;
    return (@as(i32, hours) * 3600 + @as(i32, minutes) * 60) * (if (raw[0] == '-') @as(i32, -1) else 1);
}

pub fn resolve(raw: []const u8, selected_offset: []const u8, all_day: bool, zone_name: []const u8, zone: *const timezone.Zone) !t.time.Point {
    if (all_day) {
        if (selected_offset.len != 0) return error.InvalidCalendarOffset;
        return .{ .kind = .date, .value = try timezone.dateDay(raw) };
    }
    if (raw.len >= 20 and (raw[raw.len - 1] == 'Z' or (raw.len >= 25 and (raw[raw.len - 6] == '+' or raw[raw.len - 6] == '-')))) {
        if (selected_offset.len != 0) return error.InvalidCalendarOffset;
        const value = try t.time.rfc3339(raw);
        const explicit_offset: i32 = if (raw[raw.len - 1] == 'Z') 0 else try offset(raw[raw.len - 6 ..]);
        if (try zone.offsetSeconds(@divFloor(value, 1000)) != explicit_offset) return error.CalendarTimezoneMismatch;
        return .{ .kind = .instant, .value = value, .zone = zone_name };
    }
    if ((raw.len != 16 and raw.len != 19 and !(raw.len >= 21 and raw.len <= 23 and raw[19] == '.')) or raw[10] != 'T' or raw[13] != ':' or (raw.len >= 19 and raw[16] != ':')) return error.InvalidCalendarTime;
    var civil = try timezone.parseDate(raw[0..10]);
    civil.hour = std.fmt.parseInt(u8, raw[11..13], 10) catch return error.InvalidCalendarTime;
    civil.minute = std.fmt.parseInt(u8, raw[14..16], 10) catch return error.InvalidCalendarTime;
    civil.second = if (raw.len >= 19) std.fmt.parseInt(u8, raw[17..19], 10) catch return error.InvalidCalendarTime else 0;
    for (raw[11..@min(raw.len, 19)], 11..) |byte, index| if (index != 13 and index != 16 and !std.ascii.isDigit(byte)) return error.InvalidCalendarTime;
    var millis: i64 = 0;
    if (raw.len > 19) {
        for (raw[20..]) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidCalendarTime;
            millis = millis * 10 + byte - '0';
        }
        var digits = raw.len - 20;
        while (digits < 3) : (digits += 1) millis *= 10;
    }
    const seconds = try civil.seconds();
    const value = if (selected_offset.len != 0) chosen: {
        const adjustment = try offset(selected_offset);
        const instant = seconds - adjustment;
        if (try zone.offsetSeconds(instant) != adjustment) return error.CalendarTimezoneMismatch;
        break :chosen instant * 1000;
    } else try zone.fromLocal(civil);
    return .{ .kind = .instant, .value = value + millis, .zone = zone_name };
}

pub fn eventId(a: std.mem.Allocator, target: t.Target, operation_id: []const u8) ![]const u8 {
    const account = try std.ascii.allocLowerString(a, target.account);
    const bytes = try std.json.Stringify.valueAlloc(a, .{ t.Target{ .account = account, .calendar_id = target.calendar_id }, operation_id }, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.allocPrint(a, "omagma{s}", .{std.fmt.bytesToHex(hash, .lower)});
}

pub fn canEdit(calendar: t.Calendar, document: p.EventDocument) bool {
    return editReason(calendar, document).len == 0;
}
pub fn editReason(calendar: t.Calendar, document: p.EventDocument) []const u8 {
    const event = document.event;
    if (!calendar.writable()) return "calendar_read_only";
    if (event.cancelled) return "event_cancelled";
    if (event.locked) return "event_locked";
    if (event.private_copy) return "private_copy";
    if (event.etag.len == 0) return "no_etag";
    if (event.etag.len < 2 or event.etag[0] != '"' or event.etag[event.etag.len - 1] != '"') return "invalid_etag";
    for (event.etag[1 .. event.etag.len - 1]) |byte| if (byte < 33 or byte >= 127 or byte == '"') return "invalid_etag";
    const event_type = j.text(document.value, "eventType");
    if (event_type.len != 0 and !std.mem.eql(u8, event_type, "default")) return "special_event";
    const organizer = j.get(document.value, "organizer");
    const self_marker = if (organizer) |value| j.get(value, "self") else null;
    const own = if (self_marker) |value| value == .bool and value.bool else std.ascii.eqlIgnoreCase(event.organizer, calendar.target.calendar_id);
    if (!own) return "not_organizer";
    if (j.get(document.value, "recurrence")) |rules| if (rules != .array or rules.array.items.len != 0) return "recurring_series";
    if (event.recurring_event_id.len != 0 and event.original_start == null) return "recurring_instance_unbound";
    return "";
}
pub fn htmlDescription(description: []const u8) bool {
    return @import("meeting_link.zig").htmlDescription(description);
}

pub fn prepare(a: std.mem.Allocator, calendar: t.Calendar, prepared: Prepared, intent: plan.Intent, current: ?p.EventDocument) !p.Request {
    const draft = prepared.draft;
    if (draft.conference == .google_meet and !calendar.supports_meet) return error.CalendarMeetUnavailable;
    if (current) |document| {
        if (!canEdit(calendar, document)) return error.CalendarEventNotEditable;
        if (!std.mem.eql(u8, document.event.id, intent.event_id) or !std.mem.eql(u8, document.event.etag, intent.expected_etag)) return error.CalendarReviewStale;
        if (draft.conference != .none and (document.event.join_url.len != 0 or (j.get(document.value, "conferenceData") != null and !std.mem.eql(u8, document.event.conference_status, "failure")))) return error.CalendarConferenceAlreadyPresent;
        if (draft.attendees) |emails| {
            if (document.event.attendees_omitted) return error.CalendarAttendeesIncomplete;
            // Existing attendee properties and RSVP states must survive edits.
            // Full replacement is deliberately unavailable in the first editor.
            for (document.event.attendees) |existing| {
                var found = false;
                for (emails) |email| found = found or std.ascii.eqlIgnoreCase(email, existing);
                if (!found) return error.CalendarAttendeeRemovalUnsupported;
            }
        }
    }
    const adds_guests = if (draft.attendees) |emails| hasNewGuests(emails, if (current) |document| document.event.attendees else &.{}) else false;
    if (adds_guests and prepared.send_updates != .all) return error.CalendarInvitationsRequireNotifications;
    const description = if (draft.conference == .link) try std.fmt.allocPrint(a, "{s}\n\nJoin: {s}", .{ draft.description, draft.joinUrl }) else draft.description;
    try multiline(description);
    var body = try j.value(a, .{ .summary = draft.summary, .description = description, .location = draft.location, .start = try googleTime(a, prepared.span.start), .end = try googleTime(a, prepared.span.end) });
    if (current) |document| {
        const baseline_zone = if (document.event.start) |point| if (point.zone.len != 0) point.zone else calendar.time_zone else calendar.time_zone;
        const zone_changed = !std.mem.eql(u8, draft.timeZone, baseline_zone);
        for ([_][]const u8{ "start", "end" }, [_]?t.time.Point{ document.event.start, document.event.end }, [_]t.time.Point{ prepared.span.start, prepared.span.end }) |field, previous, wanted| if (previous) |old| {
            if (!zone_changed and old.eql(wanted)) {
                // Leave the complete provider object intact on a title/notes
                // edit, including an offset-only or separate end-zone value.
                _ = body.object.swapRemove(field);
            } else if (!zone_changed and old.kind == .instant and wanted.kind == .instant) {
                var adjusted = wanted;
                adjusted.zone = old.zone;
                try body.object.put(a, field, try j.value(a, try googleTime(a, adjusted)));
            }
        };
        if (document.event.start != null and document.event.start.?.kind != prepared.span.start.kind) {
            // PATCH merges nested objects: explicitly clear the opposite time
            // representation when changing between timed and all-day events.
            for ([_][]const u8{ "start", "end" }) |field| {
                var endpoint = j.get(body, field).?;
                try endpoint.object.put(a, if (prepared.span.start.kind == .date) "dateTime" else "date", .null);
                if (prepared.span.start.kind == .date) try endpoint.object.put(a, "timeZone", .null);
                try body.object.put(a, field, endpoint);
            }
        }
    }
    if (current == null) try body.object.put(a, "id", .{ .string = intent.event_id });
    if (draft.attendees) |emails| {
        var attendees: std.ArrayList(j.Value) = .empty;
        for (emails) |email| {
            var existing: ?j.Value = null;
            if (current) |document| if (j.get(document.value, "attendees")) |previous| {
                for (previous.array.items) |entry| if (std.ascii.eqlIgnoreCase(j.text(entry, "email"), email)) {
                    existing = entry;
                    break;
                };
            };
            try attendees.append(a, existing orelse try j.value(a, .{ .email = email, .responseStatus = "needsAction" }));
        }
        try body.object.put(a, "attendees", .{ .array = .fromOwnedSlice(a, try attendees.toOwnedSlice(a)) });
    }
    if (draft.conference == .google_meet) try body.object.put(a, "conferenceData", try j.value(a, .{ .createRequest = .{ .requestId = intent.operation_id, .conferenceSolutionKey = .{ .type = "hangoutsMeet" } } }));
    var properties = if (current) |document| if (j.get(document.value, "extendedProperties")) |value| try j.copyObject(a, value) else j.object(a) else j.object(a);
    var private = if (j.get(properties, "private")) |value| try j.copyObject(a, value) else j.object(a);
    const hash = std.fmt.bytesToHex(intent.source_hash, .lower);
    try private.object.put(a, "omagmaOperation", .{ .string = intent.operation_id });
    try private.object.put(a, "omagmaSource", .{ .string = try a.dupe(u8, &hash) });
    try properties.object.put(a, "private", private);
    try body.object.put(a, "extendedProperties", properties);
    const encoded = try std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false });
    if (encoded.len > t.Limits.source_bytes * 2) return error.CalendarTooLarge;
    const bound = try p.get(a, calendar.target, intent.event_id);
    const path = if (current == null) bound.url[0 .. bound.url.len - intent.event_id.len - 1] else bound.url;
    return .{ .target = calendar.target, .kind = if (current == null) .insert_event else .update_event, .method = if (current == null) .POST else .PATCH, .url = try std.fmt.allocPrint(a, "{s}?sendUpdates={s}&conferenceDataVersion=1", .{ path, @tagName(prepared.send_updates) }), .body = encoded, .if_match = if (current != null) intent.expected_etag else null };
}

fn hasNewGuests(emails: []const []const u8, previous: []const []const u8) bool {
    for (emails) |email| {
        var found = false;
        for (previous) |existing| found = found or std.ascii.eqlIgnoreCase(email, existing);
        if (!found) return true;
    }
    return false;
}
const GoogleTime = struct { date: ?[]const u8 = null, dateTime: ?[]const u8 = null, timeZone: ?[]const u8 = null };
fn googleTime(a: std.mem.Allocator, point: t.time.Point) !GoogleTime {
    const value = try t.time.format(a, point);
    return if (point.kind == .date) .{ .date = value } else .{ .dateTime = value, .timeZone = if (point.zone.len == 0) null else point.zone };
}

/// The provider copied these exact private markers from the immutable reviewed
/// request. Later legitimate edits/deletion do not erase the fact it applied.
pub fn receiptProof(event: t.Event, intent: plan.Intent) bool {
    const hash = std.fmt.bytesToHex(intent.source_hash, .lower);
    return event.target.eql(intent.identity.target) and std.mem.eql(u8, event.id, intent.event_id) and std.mem.eql(u8, event.operation_marker, intent.operation_id) and std.mem.eql(u8, event.source_marker, &hash);
}

pub fn proves(event: t.Event, prepared: Prepared, intent: plan.Intent) bool {
    const hash = std.fmt.bytesToHex(intent.source_hash, .lower);
    if (!event.target.eql(intent.identity.target) or !std.mem.eql(u8, event.id, intent.event_id) or event.cancelled or !std.mem.eql(u8, event.operation_marker, intent.operation_id) or !std.mem.eql(u8, event.source_marker, &hash) or !std.mem.eql(u8, event.summary, prepared.draft.summary)) return false;
    if (!std.mem.eql(u8, event.location, prepared.draft.location)) return false;
    if (prepared.draft.conference != .link and !std.mem.eql(u8, event.description, prepared.draft.description)) return false;
    if (prepared.draft.conference == .link and (std.mem.indexOf(u8, event.description, prepared.draft.joinUrl) == null or !std.mem.startsWith(u8, event.description, prepared.draft.description))) return false;
    if (event.start == null or event.end == null or !event.start.?.eql(prepared.span.start) or !event.end.?.eql(prepared.span.end)) return false;
    if (prepared.draft.attendees) |emails| for (emails) |email| {
        var found = false;
        for (event.attendees) |present| found = found or std.ascii.eqlIgnoreCase(email, present);
        if (!found) return false;
    };
    return true;
}

/// Local editor prefill carries explicit offsets, so an untouched event inside
/// a DST fold remains the exact original instant (including milliseconds).
pub fn prefill(a: std.mem.Allocator, event: t.Event, zone_name: []const u8, zone: *const timezone.Zone) !Draft {
    const first = event.start orelse return error.InvalidCalendarTime;
    const last = event.end orelse return error.InvalidCalendarTime;
    return .{ .summary = event.summary, .start = try localTime(a, first, zone), .end = try localTime(a, last, zone), .timeZone = zone_name, .allDay = first.kind == .date, .description = event.description, .location = event.location, .attendees = if (event.attendees_omitted) null else event.attendees, .startOffset = try localOffset(a, first, zone), .endOffset = try localOffset(a, last, zone) };
}
fn localTime(a: std.mem.Allocator, point: t.time.Point, zone: *const timezone.Zone) ![]const u8 {
    if (point.kind == .date) return t.time.format(a, point);
    const adjustment = try zone.offsetSeconds(@divFloor(point.value, 1000));
    const formatted = try t.time.format(a, .{ .kind = .instant, .value = point.value + @as(i64, adjustment) * 1000 });
    return formatted[0 .. formatted.len - 1];
}
fn localOffset(a: std.mem.Allocator, point: t.time.Point, zone: *const timezone.Zone) ![]const u8 {
    if (point.kind == .date) return "";
    const value = try zone.offsetSeconds(@divFloor(point.value, 1000));
    const magnitude = @abs(value);
    if (magnitude % 60 != 0) return error.InvalidCalendarOffset;
    return std.fmt.allocPrint(a, "{s}{d:0>2}:{d:0>2}", .{ if (value < 0) @as([]const u8, "-") else "+", magnitude / 3600, (magnitude % 3600) / 60 });
}

test "calendar ordinary: DST fold choices gaps fractional offsets and millisecond prefill preserve literal instants" {
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    try std.testing.expectError(error.NonexistentLocalTime, resolve("2026-03-29T02:30", "", false, "Europe/Vienna", &zone));
    try std.testing.expectError(error.AmbiguousLocalTime, resolve("2026-10-25T02:30", "", false, "Europe/Vienna", &zone));
    try std.testing.expectError(error.CalendarTimezoneMismatch, resolve("2026-03-29T02:30", "+01:00", false, "Europe/Vienna", &zone));
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-25T00:30:00Z"), (try resolve("2026-10-25T02:30", "+02:00", false, "Europe/Vienna", &zone)).value);
    const second = try resolve("2026-10-25T02:30:12.125", "+01:00", false, "Europe/Vienna", &zone);
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-25T01:30:12.125Z"), second.value);
    try std.testing.expectEqual(second.value, (try resolve("2026-10-25T02:30:12.125+01:00", "", false, "Europe/Vienna", &zone)).value);
    try std.testing.expectError(error.CalendarTimezoneMismatch, resolve("2026-10-25T02:30:12+03:00", "", false, "Europe/Vienna", &zone));
    const nepal = try timezone.Zone.fromPosix("NPT-5:45");
    try std.testing.expectEqual(try t.time.rfc3339("2026-10-22T04:15:00Z"), (try resolve("2026-10-22T10:00", "+05:45", false, "Asia/Kathmandu", &nepal)).value);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const draft = try prefill(a, .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .id = "fold-event", .summary = "Keep seconds", .start = second, .end = .{ .kind = .instant, .value = second.value + 60000 } }, "Europe/Vienna", &zone);
    try std.testing.expectEqualStrings("2026-10-25T02:30:12.125", draft.start);
    try std.testing.expectEqualStrings("+01:00", draft.startOffset);
    try std.testing.expectEqual(second.value, (try resolve(draft.start, draft.startOffset, false, draft.timeZone, &zone)).value);
}

test "calendar ordinary: edit preserves full guest attributes and rejects attendee copies recurrence series and conference replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };
    const calendar: t.Calendar = .{ .target = target, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true, .supports_meet = true };
    const raw = "{\"id\":\"event-id\",\"iCalUID\":\"existing@example.test\",\"etag\":\"\\\"version-1\\\"\",\"status\":\"confirmed\",\"organizer\":{\"email\":\"self@example.test\",\"self\":true},\"start\":{\"dateTime\":\"2026-10-22T10:00:00Z\"},\"end\":{\"dateTime\":\"2026-10-22T11:00:00Z\"},\"attendees\":[{\"email\":\"guest@example.test\",\"optional\":true,\"responseStatus\":\"accepted\",\"comment\":\"Keep this\"}],\"extendedProperties\":{\"private\":{\"other\":\"retained\"},\"shared\":{\"shared\":\"retained\"}},\"attachments\":[{\"fileUrl\":\"https://docs.example.test/notes\"}]}";
    var document = try p.decodeDocument(a, target, raw);
    const prepared: Prepared = .{ .draft = .{ .summary = "Moved", .start = "2026-10-22T12:00", .end = "2026-10-22T13:00", .timeZone = "UTC", .attendees = &.{ "guest@example.test", "new@example.test" } }, .span = .{ .start = .{ .kind = .instant, .value = try t.time.rfc3339("2026-10-22T12:00:00Z"), .zone = "UTC" }, .end = .{ .kind = .instant, .value = try t.time.rfc3339("2026-10-22T13:00:00Z"), .zone = "UTC" } }, .send_updates = .all };
    const intent: plan.Intent = .{ .operation_id = "move-event", .identity = .{ .target = target, .uid = "event:event-id" }, .version = .{ .sequence = 0, .dtstamp_ms = 0 }, .kind = .update_event, .source_hash = @splat(0), .payload_hash = @splat(0), .event_id = "event-id", .expected_etag = "\"version-1\"" };
    const request = try prepare(a, calendar, prepared, intent, document);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    const guests = j.get(body, "attendees").?.array.items;
    try std.testing.expectEqualStrings("accepted", j.text(guests[0], "responseStatus"));
    try std.testing.expect(try j.boolean(guests[0], "optional", false));
    try std.testing.expectEqualStrings("Keep this", j.text(guests[0], "comment"));
    try std.testing.expectEqualStrings("needsAction", j.text(guests[1], "responseStatus"));
    try std.testing.expect(j.get(body, "attachments") == null and j.get(body, "conferenceData") == null);
    const properties = j.get(body, "extendedProperties").?;
    try std.testing.expectEqualStrings("retained", j.text(j.get(properties, "private").?, "other"));
    try std.testing.expectEqualStrings("retained", j.text(j.get(properties, "shared").?, "shared"));
    var removing = prepared;
    removing.draft.attendees = &.{"new@example.test"};
    try std.testing.expectError(error.CalendarAttendeeRemovalUnsupported, prepare(a, calendar, removing, intent, document));
    try document.value.object.put(a, "recurrence", try j.value(a, [_][]const u8{"RRULE:FREQ=WEEKLY"}));
    try std.testing.expect(!canEdit(calendar, document));
    _ = document.value.object.swapRemove("recurrence");
    document.event.private_copy = true;
    try std.testing.expect(!canEdit(calendar, document));
    document.event.private_copy = false;
    document.event.organizer = "host@example.test";
    try document.value.object.put(a, "organizer", try j.value(a, .{ .email = "host@example.test", .self = false }));
    try std.testing.expect(!canEdit(calendar, document));
}
