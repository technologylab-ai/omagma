//! Import inspection keeps the complete source and scheduling version. It is
//! independent of the deliberately smaller RSVP-email presentation parser.
const std = @import("std");
const t = @import("calendar_types.zig");
const time = t.time;
const recipients = @import("recipients.zig");

/// RSVP parsing always requires the selected account or a verified alias.
pub fn parse(a: std.mem.Allocator, raw: []const u8, account: []const u8, verified_aliases: []const []const u8) !t.Invitation {
    return parseWithPolicy(a, raw, account, verified_aliases, false);
}

/// An explicitly reviewed Calendar import may also copy an attendee-free
/// booking, PUBLISH event or ordinary event without METHOD. Listed-but-unmatched attendees remain an error; this
/// does not authorize a reply or alter the strict RSVP parser.
pub fn parseForCalendar(a: std.mem.Allocator, raw: []const u8, account: []const u8, verified_aliases: []const []const u8) !t.Invitation {
    return parseWithPolicy(a, raw, account, verified_aliases, true);
}

fn parseWithPolicy(a: std.mem.Allocator, raw: []const u8, account: []const u8, verified_aliases: []const []const u8, allow_unaddressed: bool) !t.Invitation {
    if (raw.len == 0 or raw.len > t.Limits.source_bytes) return error.CalendarTooLarge;
    try recipients.validateAddress(account);
    if (verified_aliases.len > recipients.max_recipients) return error.TooManyAliases;
    for (verified_aliases) |alias| try recipients.validateAddress(alias);
    const source = try a.dupe(u8, raw);
    const unfolded = try unfold(a, source);
    var source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &source_hash, .{});
    var result: t.Invitation = .{ .account = try a.dupe(u8, account), .source = source, .unfolded = unfolded, .source_hash = source_hash, .method = if (allow_unaddressed) .publish else .request, .uid = "", .organizer = "", .attendee = "", .version = .{ .sequence = 0, .dtstamp_ms = 0 } };
    var stack: [8][]const u8 = undefined;
    var depth: usize = 0;
    var events: usize = 0;
    var zones: usize = 0;
    var ended = false;
    var seen: u32 = 0;
    var attendees: usize = 0;
    var recurrence: std.ArrayList([]const u8) = .empty;
    var join_priority: u8 = 0;
    var alarm: Alarm = .{};
    var reminders: std.ArrayList(t.Reminder) = .empty;
    var unsupported_reminders: usize = 0;
    var lines = std.mem.splitScalar(u8, unfolded, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
        const p = try property(line);
        if (same(p.name, "BEGIN")) {
            if (depth == stack.len or ended) return error.InvalidCalendar;
            if (depth == 0) {
                if (!same(p.value, "VCALENDAR")) return error.InvalidCalendar;
            } else if (same(p.value, "VCALENDAR")) return error.InvalidCalendar else if (same(p.value, "VEVENT")) {
                if (depth != 1 or events != 0) return error.AmbiguousInvitation;
                events += 1;
            } else if (same(p.value, "VTIMEZONE")) {
                if (depth != 1) return error.InvalidCalendar;
                zones += 1;
                if (zones > 8) return error.TooManyTimezones;
                result.has_timezones = true;
            } else if (depth == 1 and !same(p.value, "VTODO") and !same(p.value, "VJOURNAL") and !std.ascii.startsWithIgnoreCase(p.value, "X-")) return error.UnsupportedCalendarComponent;
            // VTODO, VJOURNAL and X- components are carried in the retained
            // source but never inspected: only the single VEVENT is planned.
            if (depth == 2 and same(stack[1], "VEVENT") and same(p.value, "VALARM")) alarm = .{};
            if (depth > 2 and same(stack[2], "VALARM")) alarm.unsupported = true;
            stack[depth] = p.value;
            depth += 1;
            continue;
        }
        if (same(p.name, "END")) {
            if (depth == 0 or !same(stack[depth - 1], p.value)) return error.InvalidCalendar;
            if (depth == 3 and same(stack[1], "VEVENT") and same(stack[2], "VALARM")) {
                if (alarm.reminder()) |minutes| {
                    if (reminders.items.len < 5) try reminders.append(a, .{ .minutes = minutes }) else unsupported_reminders += 1;
                } else unsupported_reminders += 1;
            }
            depth -= 1;
            if (depth == 0) ended = true;
            continue;
        }
        if (depth == 0) return error.InvalidCalendar;
        if (depth == 1) {
            if (same(p.name, "VERSION")) {
                try unique(&seen, 0);
                if (!std.mem.eql(u8, p.value, "2.0")) return error.InvalidCalendar;
            } else if (same(p.name, "METHOD")) {
                try unique(&seen, 1);
                result.method = if (same(p.value, "REQUEST")) .request else if (same(p.value, "CANCEL")) .cancel else if (allow_unaddressed and same(p.value, "PUBLISH")) .publish else return error.UnsupportedCalendarMethod;
            }
            continue;
        }
        if (depth == 3 and same(stack[1], "VEVENT") and same(stack[2], "VALARM")) {
            alarm.property(p);
            continue;
        }
        if (depth != 2 or !same(stack[1], "VEVENT")) continue;
        if (same(p.name, "UID")) {
            try unique(&seen, 2);
            try t.text(p.value, 1024, false);
            result.uid = p.value;
        } else if (same(p.name, "ORGANIZER")) {
            try unique(&seen, 3);
            result.organizer = try mailto(p.value);
        } else if (same(p.name, "DTSTAMP")) {
            try unique(&seen, 4);
            const stamp = try time.parse(p.value, p.parameters);
            if (stamp.kind != .utc) return error.InvalidCalendarTime;
            result.version.dtstamp_ms = (try time.resolve(stamp, null, false)).value;
        } else if (same(p.name, "SEQUENCE")) {
            try unique(&seen, 5);
            result.version.sequence = std.fmt.parseInt(u32, p.value, 10) catch return error.InvalidSequence;
            if (result.version.sequence > std.math.maxInt(i32)) return error.InvalidSequence;
        } else if (same(p.name, "DTSTART")) {
            try unique(&seen, 6);
            result.start = try time.parse(p.value, p.parameters);
        } else if (same(p.name, "DTEND")) {
            try unique(&seen, 7);
            if (result.duration != null) return error.InvalidCalendarDuration;
            result.end = try time.parse(p.value, p.parameters);
        } else if (same(p.name, "DURATION")) {
            try unique(&seen, 8);
            if (result.end != null) return error.InvalidCalendarDuration;
            result.duration = try time.parseDuration(p.value);
        } else if (same(p.name, "RECURRENCE-ID")) {
            try unique(&seen, 9);
            result.recurrence_id = try time.parse(p.value, p.parameters);
            result.recurrence_range = (try time.parameter(p.parameters, "RANGE")) orelse "";
            if (result.recurrence_range.len > 0 and !same(result.recurrence_range, "THISANDFUTURE")) return error.UnsupportedRecurrenceRange;
        } else if (same(p.name, "RRULE") or same(p.name, "EXRULE") or same(p.name, "RDATE") or same(p.name, "EXDATE")) {
            if (recurrence.items.len == t.Limits.recurrence_lines) return error.TooManyRecurrenceLines;
            if (same(p.name, "RRULE")) try unique(&seen, 10);
            try recurrence.append(a, line);
        } else if (same(p.name, "ATTENDEE")) {
            attendees += 1;
            // A room, group URN or malformed address can never be the
            // selected identity; it still counts as a listed attendee.
            const address = mailto(p.value) catch continue;
            var selected = same(address, account);
            for (verified_aliases) |alias| selected = selected or same(address, alias);
            if (selected) {
                if (result.attendee.len != 0) return error.AmbiguousAttendee;
                result.attendee = address;
            }
        } else if (same(p.name, "SUMMARY")) {
            if (!first(&seen, 11)) continue;
            result.summary = try unescape(a, p.value);
        } else if (same(p.name, "DESCRIPTION")) {
            if (!first(&seen, 12)) continue;
            result.description = try unescape(a, p.value);
            offerJoin(&result, &join_priority, @import("meeting_link.zig").plain(result.description), 1);
        } else if (same(p.name, "LOCATION")) {
            if (!first(&seen, 13)) continue;
            result.location = try unescape(a, p.value);
            offerJoin(&result, &join_priority, result.location, 2);
        } else if (same(p.name, "URL")) {
            if (!first(&seen, 14)) continue;
            result.url = p.value;
            offerJoin(&result, &join_priority, p.value, 3);
        } else if (same(p.name, "CONFERENCE") or same(p.name, "X-MICROSOFT-SKYPETEAMSMEETINGURL") or same(p.name, "X-MICROSOFT-ONLINEMEETINGEXTERNALLINK")) {
            offerJoin(&result, &join_priority, p.value, 4);
        } else if (same(p.name, "STATUS")) {
            try unique(&seen, 15);
            // An unknown value keeps the default; the reviewed plan shows it.
            result.cancelled = same(p.value, "CANCELLED");
        } else if (same(p.name, "TRANSP")) {
            try unique(&seen, 16);
            result.transparent = same(p.value, "TRANSPARENT");
        } else if (same(p.name, "CLASS")) {
            try unique(&seen, 17);
            result.private = same(p.value, "PRIVATE") or same(p.value, "CONFIDENTIAL");
        }
    }
    // Scheduling messages retain all original required identity fields.
    // RFC 5545 ordinary events may omit METHOD and ORGANIZER; never infer REQUEST.
    const required: u32 = if (allow_unaddressed and result.method == .publish) 0x15 else 0x1f;
    if (!ended or depth != 0 or events != 1 or seen & required != required) return error.InvalidCalendar;
    if (result.method == .publish and attendees != 0) return error.UnsupportedCalendarAttendees;
    if (result.method == .publish) {
        result.reminders = try reminders.toOwnedSlice(a);
        result.unsupported_reminders = unsupported_reminders;
    }
    if (result.attendee.len == 0 and (attendees != 0 or (result.method == .request and !allow_unaddressed))) return error.NotAnAttendee;
    if (result.method != .cancel and result.start == null) return error.CalendarStartRequired;
    if (result.start) |start| {
        if (result.end) |end| if ((start.kind == .date) != (end.kind == .date)) return error.InvalidCalendarTime;
        if (result.duration) |duration| if (start.kind == .date and duration.seconds != 0) return error.InvalidCalendarDuration;
        if (result.recurrence_id) |instance| if ((start.kind == .date) != (instance.kind == .date)) return error.InvalidCalendarTime;
    }
    result.recurrence = try recurrence.toOwnedSlice(a);
    return result;
}

// Bounded, passive conversion only. EMAIL/AUDIO/absolute/repeating alarms never
// execute; the review discloses every alarm that cannot be copied faithfully.
const Alarm = struct {
    action_seen: bool = false,
    display: bool = false,
    trigger_seen: bool = false,
    minutes: ?u32 = null,
    unsupported: bool = false,

    fn property(self: *Alarm, p: Property) void {
        if (same(p.name, "ACTION")) {
            if (self.action_seen) self.unsupported = true;
            self.action_seen = true;
            self.display = same(p.value, "DISPLAY");
        } else if (same(p.name, "TRIGGER")) {
            if (self.trigger_seen) self.unsupported = true;
            self.trigger_seen = true;
            self.minutes = alarmMinutes(p.value, p.parameters);
        } else if (!same(p.name, "DESCRIPTION") and !std.ascii.startsWithIgnoreCase(p.name, "X-")) self.unsupported = true;
    }
    fn reminder(self: Alarm) ?u32 {
        return if (!self.unsupported and self.action_seen and self.display and self.trigger_seen) self.minutes else null;
    }
};
fn alarmMinutes(raw: []const u8, parameters: []const u8) ?u32 {
    if (time.parameter(parameters, "VALUE") catch return null) |value| if (!same(value, "DURATION")) return null;
    if (time.parameter(parameters, "RELATED") catch return null) |value| if (!same(value, "START")) return null;
    const negative = std.mem.startsWith(u8, raw, "-");
    const duration = time.parseDuration(if (negative) raw[1..] else raw) catch return null;
    // Nominal days/weeks may cross a DST change; Google accepts elapsed
    // minutes. Do not silently turn P1D into PT24H.
    if (duration.days != 0) return null;
    const seconds = @as(u64, duration.seconds);
    if ((!negative and seconds != 0) or seconds % 60 != 0 or seconds / 60 > 40320) return null;
    return @intCast(seconds / 60);
}

fn offerJoin(result: *t.Invitation, priority: *u8, value: []const u8, rank: u8) void {
    if (rank > priority.* and @import("reader_tools.zig").safeUrl(value)) {
        result.join_url = value;
        priority.* = rank;
    }
}

pub const Span = struct { start: time.Point, end: time.Point };
pub fn resolveSpan(invitation: t.Invitation, start_binding: ?time.Binding, end_binding: ?time.Binding) !Span {
    const start_stamp = invitation.start orelse return error.CalendarStartRequired;
    const start = try time.resolve(start_stamp, start_binding, invitation.has_timezones);
    const end = if (invitation.end) |stamp| try time.resolve(stamp, end_binding orelse start_binding, invitation.has_timezones) else blk: {
        if (invitation.duration) |duration| {
            break :blk try time.durationEnd(start_stamp, duration, start_binding, invitation.has_timezones);
        }
        break :blk time.Point{ .kind = start.kind, .value = start.value + (if (start.kind == .date) @as(i64, 1) else 0), .zone = start.zone };
    };
    // A zero-length instant (DTEND equal to DTSTART) is a valid event; an
    // all-day DATE needs an exclusive end after its start.
    if (start.kind != end.kind or end.value < start.value or (start.kind == .date and end.value == start.value)) return error.CalendarEndRequiresReview;
    return .{ .start = start, .end = end };
}

fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
fn unique(seen: *u32, comptime index: u5) !void {
    const bit = @as(u32, 1) << index;
    if (seen.* & bit != 0) return error.AmbiguousInvitation;
    seen.* |= bit;
}
/// Repeated presentation text: the first value is planned and reviewed.
fn first(seen: *u32, comptime index: u5) bool {
    const bit = @as(u32, 1) << index;
    if (seen.* & bit != 0) return false;
    seen.* |= bit;
    return true;
}
fn mailto(value: []const u8) ![]const u8 {
    if (!std.ascii.startsWithIgnoreCase(value, "mailto:")) return error.UnsupportedCalendarAddress;
    const address = value[7..];
    try recipients.validateAddress(address);
    return address;
}
const Property = struct { name: []const u8, parameters: []const u8, value: []const u8 };
fn property(line: []const u8) !Property {
    // RFC 5545 SAFE-CHAR includes WSP (space and horizontal tab).
    for (line) |byte| if ((byte < 32 and byte != '\t') or byte == 127) return error.InvalidCalendar;
    var quoted = false;
    for (line, 0..) |byte, index| {
        if (byte == '"') quoted = !quoted;
        if (byte == ':' and !quoted) {
            const semi = std.mem.indexOfScalar(u8, line[0..index], ';') orelse index;
            if (semi == 0) return error.InvalidCalendar;
            for (line[0..semi]) |name_byte| if (!std.ascii.isAlphanumeric(name_byte) and name_byte != '-') return error.InvalidCalendar;
            // Parameters are validated by the properties which read them; an
            // odd parameter on an ignored property must not refuse the event.
            return .{ .name = line[0..semi], .parameters = line[semi..index], .value = line[index + 1 ..] };
        }
    }
    return error.InvalidCalendar;
}
fn unfold(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const storage = try a.alloc(u8, raw.len + 1);
    var written: usize = 0;
    var line_start: usize = 0;
    var properties: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |physical| {
        const line = if (std.mem.endsWith(u8, physical, "\r")) physical[0 .. physical.len - 1] else physical;
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.InvalidCalendar;
        const continuation = line[0] == ' ' or line[0] == '\t';
        if (continuation) {
            if (written == 0) return error.InvalidCalendar;
            written -= 1;
        } else {
            properties += 1;
            if (properties > t.Limits.source_properties) return error.TooManyCalendarProperties;
            line_start = written;
        }
        const value = line[if (continuation) @as(usize, 1) else 0..];
        if (written - line_start + value.len > t.Limits.source_line_bytes) return error.CalendarLineTooLarge;
        @memcpy(storage[written..][0..value.len], value);
        written += value.len;
        storage[written] = '\n';
        written += 1;
    }
    return storage[0..written];
}
fn unescape(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const output = try a.alloc(u8, raw.len);
    var written: usize = 0;
    var pos: usize = 0;
    while (pos < raw.len) : (pos += 1) {
        var byte = raw[pos];
        // An unknown escape (Outlook writes "\:" and bare backslashes) keeps
        // its backslash and character literally; the plan is reviewed.
        if (byte == '\\' and pos + 1 < raw.len) switch (raw[pos + 1]) {
            'n', 'N' => {
                byte = '\n';
                pos += 1;
            },
            '\\', ',', ';' => {
                byte = raw[pos + 1];
                pos += 1;
            },
            else => {},
        };
        output[written] = byte;
        written += 1;
    }
    return output[0..written];
}
