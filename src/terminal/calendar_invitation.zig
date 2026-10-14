//! Import inspection keeps the complete source and scheduling version. It is
//! independent of the deliberately smaller RSVP-email presentation parser.
const std = @import("std");
const t = @import("calendar_types.zig");
const time = t.time;
const recipients = @import("recipients.zig");

pub fn parse(a: std.mem.Allocator, raw: []const u8, account: []const u8, verified_aliases: []const []const u8) !t.Invitation {
    if (raw.len == 0 or raw.len > t.Limits.source_bytes) return error.CalendarTooLarge;
    try recipients.validateAddress(account);
    if (verified_aliases.len > recipients.max_recipients) return error.TooManyAliases;
    for (verified_aliases) |alias| try recipients.validateAddress(alias);
    const source = try a.dupe(u8, raw);
    const unfolded = try unfold(a, source);
    var source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &source_hash, .{});
    var result: t.Invitation = .{ .account = try a.dupe(u8, account), .source = source, .unfolded = unfolded, .source_hash = source_hash, .method = .request, .uid = "", .organizer = "", .attendee = "", .version = .{ .sequence = 0, .dtstamp_ms = 0 } };
    var stack: [8][]const u8 = undefined;
    var depth: usize = 0;
    var events: usize = 0;
    var zones: usize = 0;
    var ended = false;
    var seen: u32 = 0;
    var attendees: usize = 0;
    var recurrence: std.ArrayList([]const u8) = .empty;
    var join_priority: u8 = 0;
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
            } else if (depth == 1) return error.UnsupportedCalendarComponent;
            stack[depth] = p.value;
            depth += 1;
            continue;
        }
        if (same(p.name, "END")) {
            if (depth == 0 or !same(stack[depth - 1], p.value)) return error.InvalidCalendar;
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
                result.method = if (same(p.value, "REQUEST")) .request else if (same(p.value, "CANCEL")) .cancel else return error.UnsupportedCalendarMethod;
            }
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
            const address = try mailto(p.value);
            var selected = same(address, account);
            for (verified_aliases) |alias| selected = selected or same(address, alias);
            if (selected) {
                if (result.attendee.len != 0) return error.AmbiguousAttendee;
                result.attendee = address;
            }
        } else if (same(p.name, "SUMMARY")) {
            try unique(&seen, 11);
            result.summary = try unescape(a, p.value);
        } else if (same(p.name, "DESCRIPTION")) {
            try unique(&seen, 12);
            result.description = try unescape(a, p.value);
            offerJoin(&result, &join_priority, @import("meeting_link.zig").plain(result.description), 1);
        } else if (same(p.name, "LOCATION")) {
            try unique(&seen, 13);
            result.location = try unescape(a, p.value);
            offerJoin(&result, &join_priority, result.location, 2);
        } else if (same(p.name, "URL")) {
            try unique(&seen, 14);
            result.url = p.value;
            offerJoin(&result, &join_priority, p.value, 3);
        } else if (same(p.name, "CONFERENCE") or same(p.name, "X-MICROSOFT-SKYPETEAMSMEETINGURL") or same(p.name, "X-MICROSOFT-ONLINEMEETINGEXTERNALLINK")) {
            offerJoin(&result, &join_priority, p.value, 4);
        } else if (same(p.name, "STATUS")) {
            try unique(&seen, 15);
            if (!same(p.value, "CONFIRMED") and !same(p.value, "TENTATIVE") and !same(p.value, "CANCELLED")) return error.InvalidCalendarStatus;
            result.cancelled = same(p.value, "CANCELLED");
        } else if (same(p.name, "TRANSP")) {
            try unique(&seen, 16);
            if (!same(p.value, "OPAQUE") and !same(p.value, "TRANSPARENT")) return error.InvalidCalendar;
            result.transparent = same(p.value, "TRANSPARENT");
        } else if (same(p.name, "CLASS")) {
            try unique(&seen, 17);
            if (!same(p.value, "PUBLIC") and !same(p.value, "PRIVATE") and !same(p.value, "CONFIDENTIAL")) return error.InvalidCalendar;
            result.private = same(p.value, "PRIVATE") or same(p.value, "CONFIDENTIAL");
        }
    }
    if (!ended or depth != 0 or events != 1 or seen & 0x1f != 0x1f) return error.InvalidCalendar;
    if ((result.method == .request or attendees != 0) and result.attendee.len == 0) return error.NotAnAttendee;
    if (result.method == .request and result.start == null) return error.CalendarStartRequired;
    if (result.start) |start| {
        if (result.end) |end| if ((start.kind == .date) != (end.kind == .date)) return error.InvalidCalendarTime;
        if (result.duration) |duration| if (start.kind == .date and duration.seconds != 0) return error.InvalidCalendarDuration;
        if (result.recurrence_id) |instance| if ((start.kind == .date) != (instance.kind == .date)) return error.InvalidCalendarTime;
    }
    result.recurrence = try recurrence.toOwnedSlice(a);
    return result;
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
    if (start.kind != end.kind or end.value <= start.value) return error.CalendarEndRequiresReview;
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
fn mailto(value: []const u8) ![]const u8 {
    if (!std.ascii.startsWithIgnoreCase(value, "mailto:")) return error.UnsupportedCalendarAddress;
    const address = value[7..];
    try recipients.validateAddress(address);
    return address;
}
const Property = struct { name: []const u8, parameters: []const u8, value: []const u8 };
fn property(line: []const u8) !Property {
    for (line) |byte| if (byte < 32 or byte == 127) return error.InvalidCalendar;
    var quoted = false;
    for (line, 0..) |byte, index| {
        if (byte == '"') quoted = !quoted;
        if (byte == ':' and !quoted) {
            const semi = std.mem.indexOfScalar(u8, line[0..index], ';') orelse index;
            if (semi == 0) return error.InvalidCalendar;
            for (line[0..semi]) |name_byte| if (!std.ascii.isAlphanumeric(name_byte) and name_byte != '-') return error.InvalidCalendar;
            const parameters = line[semi..index];
            _ = try time.parameter(parameters, "__validate_parameters__");
            return .{ .name = line[0..semi], .parameters = parameters, .value = line[index + 1 ..] };
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
        if (byte == '\\') {
            pos += 1;
            if (pos == raw.len) return error.InvalidCalendarText;
            byte = switch (raw[pos]) {
                'n', 'N' => '\n',
                '\\', ',', ';' => raw[pos],
                else => return error.InvalidCalendarText,
            };
        }
        output[written] = byte;
        written += 1;
    }
    return output[0..written];
}
