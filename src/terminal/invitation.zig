const std = @import("std");
const b = @import("../bounded.zig");
const recipients = @import("recipients.zig");
const timezone = @import("timezone.zig");
const reader_tools = @import("reader_tools.zig");

test "invitation display: only the inspected attendee's stated response is shown" {
    var invite: Invitation = .{};
    try parse("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:status@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;PARTSTAT=DECLINED:mailto:other@example.test\r\nATTENDEE;PARTSTAT=tentative:mailto:self@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", "self@example.test", &.{}, &invite);
    try std.testing.expectEqualStrings("TENTATIVE", invite.attendee_status.slice());
    try parse("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:status@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", "self@example.test", &.{}, &invite);
    try std.testing.expectEqualStrings("", invite.attendee_status.slice());
}

pub const max_calendar_bytes = 128 * 1024;
pub const max_calendar_properties = 1024;
pub const Status = enum { accepted, tentative, declined };
pub const Invitation = struct {
    uid: b.Text(1024) = .{},
    organizer: b.Text(254) = .{},
    attendee: b.Text(254) = .{},
    attendee_status: b.Text(32) = .{},
    sequence: u32 = 0,
    recurrence_id: b.Text(1024) = .{},
    recurrence_parameters: b.Text(512) = .{},
    summary: b.Text(512) = .{},
    start: b.Text(128) = .{},
    start_parameters: b.Text(512) = .{},
    end: b.Text(128) = .{},
    end_parameters: b.Text(512) = .{},
    duration: b.Text(128) = .{},
    location: b.Text(1024) = .{},
    join_url: b.Text(4096) = .{},
    recurrence_rule: b.Text(1024) = .{},
    timezones: b.Text(32 * 1024) = .{},
};

/// A REQUEST for exactly one event/instance. Deliberately rejects ambiguous
/// calendars rather than choosing an event or attendee implicitly.
pub fn parse(ics: []const u8, account: []const u8, aliases: []const []const u8, out: *Invitation) !void {
    try parseMethod(ics, account, aliases, "REQUEST", out);
}
pub fn parseReply(ics: []const u8, account: []const u8, aliases: []const []const u8, out: *Invitation) !void {
    try parseMethod(ics, account, aliases, "REPLY", out);
}
fn parseMethod(ics: []const u8, account: []const u8, aliases: []const []const u8, expected_method: []const u8, out: *Invitation) !void {
    if (ics.len > max_calendar_bytes) return error.CalendarTooLarge;
    try recipients.validateAddress(account);
    if (aliases.len > recipients.max_recipients) return error.TooManyAliases;
    for (aliases) |alias| try recipients.validateAddress(alias);
    out.* = .{};
    var lines = Lines{ .input = ics };
    var unfolded: [4096]u8 = undefined;
    var calendar = false;
    var ended = false;
    var event = false;
    var events: usize = 0;
    var nested: usize = 0;
    var nested_names: [8]b.Text(64) = @splat(.{});
    var in_timezone = false;
    var timezone_count: usize = 0;
    var method = false;
    var version = false;
    var uid = false;
    var organizer = false;
    var sequence = false;
    var recurrence = false;
    var stamp = false;
    var attendee = false;
    var attendees: usize = 0;
    var properties: usize = 0;
    var start_seen = false;
    var end_seen = false;
    var duration_seen = false;
    var rule_seen = false;
    var join_priority: u8 = 0;
    while (try lines.next(&unfolded)) |line| {
        if (line.len == 0) continue;
        // Unfold first: RFC 5545 permits a physical fold to divide a UTF-8
        // sequence. The logical content line must still be valid UTF-8.
        if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
        properties += 1;
        if (properties > max_calendar_properties) return error.TooManyCalendarProperties;
        const prop = try property(line);
        if (in_timezone) try appendTimezone(out, line);
        if (std.ascii.eqlIgnoreCase(prop.name, "BEGIN")) {
            if (std.ascii.eqlIgnoreCase(prop.value, "VCALENDAR")) {
                if (calendar or ended) return error.InvalidCalendar;
                calendar = true;
            } else if (std.ascii.eqlIgnoreCase(prop.value, "VEVENT")) {
                if (!calendar or event or nested != 0) return error.InvalidCalendar;
                events += 1;
                if (events > 1) return error.AmbiguousInvitation;
                event = true;
            } else {
                if (!calendar or ended) return error.InvalidCalendar;
                if (std.ascii.eqlIgnoreCase(prop.value, "VTIMEZONE")) {
                    if (event or nested != 0) return error.InvalidCalendar;
                    timezone_count += 1;
                    if (timezone_count > 8) return error.TooManyTimezones;
                    in_timezone = true;
                    try appendTimezone(out, line);
                }
                if (nested == nested_names.len) return error.CalendarTooDeep;
                try nested_names[nested].set(prop.value);
                nested += 1;
            }
            continue;
        }
        if (std.ascii.eqlIgnoreCase(prop.name, "END")) {
            if (std.ascii.eqlIgnoreCase(prop.value, "VCALENDAR")) {
                if (!calendar or event or nested != 0) return error.InvalidCalendar;
                calendar = false;
                ended = true;
            } else if (std.ascii.eqlIgnoreCase(prop.value, "VEVENT")) {
                if (!event or nested != 0) return error.InvalidCalendar;
                event = false;
            } else {
                if (nested == 0) return error.InvalidCalendar;
                if (!std.ascii.eqlIgnoreCase(nested_names[nested - 1].slice(), prop.value)) return error.InvalidCalendar;
                nested -= 1;
                if (in_timezone and nested == 0) in_timezone = false;
            }
            continue;
        }
        if (!calendar or ended) return error.InvalidCalendar;
        if (nested != 0) continue;
        if (!event) {
            if (std.ascii.eqlIgnoreCase(prop.name, "METHOD")) {
                if (method) return error.AmbiguousInvitation;
                if (!std.ascii.eqlIgnoreCase(prop.value, expected_method)) return error.NotInvitationRequest;
                method = true;
            } else if (std.ascii.eqlIgnoreCase(prop.name, "VERSION")) {
                if (version or !std.mem.eql(u8, prop.value, "2.0")) return error.InvalidCalendar;
                version = true;
            }
            continue;
        }
        if (std.ascii.eqlIgnoreCase(prop.name, "UID")) {
            if (uid or prop.value.len == 0) return error.AmbiguousInvitation;
            try out.uid.set(prop.value);
            uid = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "ORGANIZER")) {
            if (organizer) return error.AmbiguousInvitation;
            try out.organizer.set(try mailto(prop.value));
            organizer = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "SEQUENCE")) {
            if (sequence) return error.AmbiguousInvitation;
            out.sequence = std.fmt.parseInt(u32, prop.value, 10) catch return error.InvalidSequence;
            if (out.sequence > std.math.maxInt(i32)) return error.InvalidSequence;
            sequence = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "RECURRENCE-ID")) {
            if (recurrence or prop.value.len == 0) return error.AmbiguousInvitation;
            try out.recurrence_id.set(prop.value);
            try out.recurrence_parameters.set(prop.parameters);
            recurrence = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "ATTENDEE")) {
            attendees += 1;
            // Incoming meetings can have more participants than an outgoing
            // mail envelope. This scan retains one responding identity and
            // stays bounded by the calendar property/byte budgets.
            const address = try mailto(prop.value);
            var selected = std.ascii.eqlIgnoreCase(address, account);
            for (aliases) |alias| selected = selected or std.ascii.eqlIgnoreCase(address, alias);
            if (selected) {
                if (attendee) return error.AmbiguousAttendee;
                if (std.mem.eql(u8, expected_method, "REPLY")) {
                    const partstat = @import("mime.zig").parameter(prop.parameters, "PARTSTAT") orelse return error.InvalidInvitationStatus;
                    if (!std.ascii.eqlIgnoreCase(partstat, "ACCEPTED") and !std.ascii.eqlIgnoreCase(partstat, "TENTATIVE") and !std.ascii.eqlIgnoreCase(partstat, "DECLINED")) return error.InvalidInvitationStatus;
                }
                try out.attendee.set(address);
                if (@import("mime.zig").parameter(prop.parameters, "PARTSTAT")) |partstat| {
                    for ([_][]const u8{ "NEEDS-ACTION", "ACCEPTED", "TENTATIVE", "DECLINED", "DELEGATED", "COMPLETED", "IN-PROCESS" }) |known| {
                        if (std.ascii.eqlIgnoreCase(partstat, known)) {
                            try out.attendee_status.set(known);
                            break;
                        }
                    }
                }
                attendee = true;
            }
        } else if (std.ascii.eqlIgnoreCase(prop.name, "DTSTAMP")) {
            if (stamp) return error.AmbiguousInvitation;
            try validateStamp(prop.value);
            stamp = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "SUMMARY")) {
            out.summary.display(unescapeText(prop.value, &unfolded));
        } else if (std.ascii.eqlIgnoreCase(prop.name, "DTSTART")) {
            if (start_seen) return error.AmbiguousInvitation;
            try out.start.set(prop.value);
            try out.start_parameters.set(prop.parameters);
            start_seen = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "DTEND")) {
            if (end_seen or duration_seen) return error.AmbiguousInvitation;
            try out.end.set(prop.value);
            try out.end_parameters.set(prop.parameters);
            end_seen = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "DURATION")) {
            if (duration_seen or end_seen) return error.AmbiguousInvitation;
            try out.duration.set(prop.value);
            duration_seen = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "RRULE")) {
            if (rule_seen) return error.AmbiguousInvitation;
            try out.recurrence_rule.set(prop.value);
            rule_seen = true;
        } else if (std.ascii.eqlIgnoreCase(prop.name, "LOCATION")) {
            const location = unescapeText(prop.value, &unfolded);
            out.location.display(location);
            offerJoin(out, &join_priority, std.mem.trim(u8, location, " \t"), 2);
        } else if (std.ascii.eqlIgnoreCase(prop.name, "CONFERENCE") or std.ascii.eqlIgnoreCase(prop.name, "X-MICROSOFT-SKYPETEAMSMEETINGURL") or std.ascii.eqlIgnoreCase(prop.name, "X-MICROSOFT-ONLINEMEETINGEXTERNALLINK")) {
            offerJoin(out, &join_priority, prop.value, 4);
        } else if (std.ascii.eqlIgnoreCase(prop.name, "URL")) {
            offerJoin(out, &join_priority, prop.value, 3);
        } else if (std.ascii.eqlIgnoreCase(prop.name, "DESCRIPTION")) {
            const description = unescapeText(prop.value, &unfolded);
            var paragraphs = std.mem.splitScalar(u8, description, '\n');
            while (paragraphs.next()) |paragraph| {
                if (std.ascii.findIgnoreCase(paragraph, "join") == null and std.ascii.findIgnoreCase(paragraph, "meeting") == null) continue;
                var urls: reader_tools.LinkIterator = .{ .input = paragraph };
                if (urls.next()) |url| offerJoin(out, &join_priority, url.url, 1);
            }
        }
    }
    if (calendar or event or nested != 0 or !ended or events != 1 or !method or !version or !uid or !organizer) return error.InvalidCalendar;
    if (!attendee) return error.NotAnAttendee;
    if (std.mem.eql(u8, expected_method, "REPLY") and (!stamp or attendees != 1)) return error.InvalidCalendar;
}
/// iCalendar TEXT escapes are presentation data, never header syntax. Input
/// may borrow a later part of output (the parser's unfolded line buffer).
fn unescapeText(input: []const u8, output: []u8) []const u8 {
    var read: usize = 0;
    var written: usize = 0;
    while (read < input.len and written < output.len) : (read += 1) {
        if (input[read] == '\\' and read + 1 < input.len) {
            const next = input[read + 1];
            if (next == 'n' or next == 'N' or next == '\\' or next == ',' or next == ';') {
                output[written] = if (next == 'n' or next == 'N') '\n' else next;
                read += 1;
                written += 1;
                continue;
            }
        }
        output[written] = input[read];
        written += 1;
    }
    return output[0..written];
}
fn offerJoin(out: *Invitation, priority: *u8, url: []const u8, offered: u8) void {
    if (offered <= priority.* or !reader_tools.safeUrl(url)) return;
    out.join_url.set(url) catch return;
    priority.* = offered;
}

pub const Friendly = struct {
    start: []const u8 = "",
    end: []const u8 = "",
    duration: []const u8 = "",
    location: []const u8 = "",
    join_url: []const u8 = "",
    recurrence: []const u8 = "",
    all_day: bool = false,
    timezone_unavailable: bool = false,
};
const CalendarTime = struct {
    civil: timezone.CivilTime,
    kind: enum { date, utc, floating, zoned },
    zone_id: []const u8 = "",
    fn parse(raw: []const u8, parameters: []const u8) !CalendarTime {
        const value_type = @import("mime.zig").parameter(parameters, "VALUE");
        const zone_id = @import("mime.zig").parameter(parameters, "TZID") orelse "";
        const date = raw.len == 8;
        if (date) {
            if (zone_id.len != 0 or value_type == null or !std.ascii.eqlIgnoreCase(value_type.?, "DATE")) return error.InvalidCalendarTimestamp;
        } else {
            if (raw.len != 15 and raw.len != 16) return error.InvalidCalendarTimestamp;
            if (raw[8] != 'T' or (raw.len == 16 and raw[15] != 'Z')) return error.InvalidCalendarTimestamp;
            if (value_type) |value| if (!std.ascii.eqlIgnoreCase(value, "DATE-TIME")) return error.InvalidCalendarTimestamp;
            if (raw.len == 16 and zone_id.len != 0) return error.InvalidCalendarTimestamp;
        }
        for (raw, 0..) |byte, index| if ((date or (index != 8 and index != 15)) and !std.ascii.isDigit(byte)) return error.InvalidCalendarTimestamp;
        const civil: timezone.CivilTime = .{
            .year = try std.fmt.parseInt(u16, raw[0..4], 10),
            .month = try std.fmt.parseInt(u8, raw[4..6], 10),
            .day = try std.fmt.parseInt(u8, raw[6..8], 10),
            .hour = if (date) 0 else try std.fmt.parseInt(u8, raw[9..11], 10),
            .minute = if (date) 0 else try std.fmt.parseInt(u8, raw[11..13], 10),
            .second = if (date) 0 else try std.fmt.parseInt(u8, raw[13..15], 10),
        };
        _ = civil.seconds() catch return error.InvalidCalendarTimestamp;
        return .{ .civil = civil, .kind = if (date) .date else if (raw.len == 16) .utc else if (zone_id.len > 0) .zoned else .floating, .zone_id = zone_id };
    }
};
pub fn eventTimezone(invite: *const Invitation) []const u8 {
    return @import("mime.zig").parameter(invite.start_parameters.slice(), "TZID") orelse "";
}
/// UTC times are converted with the reader's local zone. A named TZID can be
/// supplied through friendlyWithZone after loading zoneinfo once. Embedded
/// VTIMEZONE definitions remain authoritative: their wall times and TZID are
/// shown literally instead of substituting possibly different system rules.
pub fn friendly(allocator: std.mem.Allocator, invite: *const Invitation, local_zone: *const timezone.Zone) !Friendly {
    return friendlyWithZone(allocator, invite, local_zone, null);
}
pub fn friendlyWithZone(allocator: std.mem.Allocator, invite: *const Invitation, local_zone: *const timezone.Zone, event_zone: ?*const timezone.Zone) !Friendly {
    var result: Friendly = .{ .location = invite.location.slice(), .join_url = if (reader_tools.safeUrl(invite.join_url.slice())) invite.join_url.slice() else "" };
    const start = if (invite.start.len > 0) CalendarTime.parse(invite.start.slice(), invite.start_parameters.slice()) catch null else null;
    const end = if (invite.end.len > 0) CalendarTime.parse(invite.end.slice(), invite.end_parameters.slice()) catch null else null;
    result.all_day = if (start) |value| value.kind == .date else false;
    var start_ms: ?i64 = null;
    var end_ms: ?i64 = null;
    if (start) |value| {
        const rendered = try friendlyTime(allocator, value, local_zone, if (invite.timezones.len == 0) event_zone else null, eventTimezone(invite));
        result.start = rendered.text;
        start_ms = rendered.milliseconds;
        result.timezone_unavailable = rendered.unavailable;
    } else if (invite.start.len > 0) {
        result.start = try std.fmt.allocPrint(allocator, "{s} (unrecognized calendar time)", .{invite.start.slice()});
        result.timezone_unavailable = true;
    }
    if (end) |value| {
        const rendered = try friendlyTime(allocator, value, local_zone, if (invite.timezones.len == 0) event_zone else null, eventTimezone(invite));
        result.end = if (value.kind == .date) try std.fmt.allocPrint(allocator, "{s} (exclusive)", .{rendered.text}) else rendered.text;
        end_ms = rendered.milliseconds;
        result.timezone_unavailable = result.timezone_unavailable or rendered.unavailable;
    } else if (invite.end.len > 0) {
        result.end = try std.fmt.allocPrint(allocator, "{s} (unrecognized calendar time)", .{invite.end.slice()});
        result.timezone_unavailable = true;
    }
    if (start != null and end != null and start.?.kind == .date and end.?.kind == .date) {
        const days = @divExact((try end.?.civil.seconds()) - (try start.?.civil.seconds()), 86400);
        result.duration = if (days > 0) try std.fmt.allocPrint(allocator, "{d} day{s}", .{ days, if (days == 1) "" else "s" }) else "Invalid end date";
    } else if (start_ms != null and end_ms != null) {
        result.duration = if (end_ms.? >= start_ms.?) try formatDuration(allocator, @intCast(@divTrunc(end_ms.? - start_ms.?, 1000))) else "Invalid end time";
    } else if (invite.duration.len > 0) {
        const seconds = parseDuration(invite.duration.slice()) catch null;
        result.duration = if (seconds) |value| try formatDuration(allocator, value) else "Unrecognized duration";
    } else if (result.all_day and invite.end.len == 0) result.duration = "1 day";
    if (invite.recurrence_id.len > 0) {
        const instance = CalendarTime.parse(invite.recurrence_id.slice(), invite.recurrence_parameters.slice()) catch null;
        const instance_text = if (instance) |value| (try friendlyTime(allocator, value, local_zone, if (invite.timezones.len == 0) event_zone else null, eventTimezone(invite))).text else invite.recurrence_id.slice();
        result.recurrence = try std.fmt.allocPrint(allocator, "This occurrence: {s}", .{instance_text});
    } else if (invite.recurrence_rule.len > 0) {
        result.recurrence = try recurrenceLabel(allocator, invite.recurrence_rule.slice());
    }
    return result;
}
const FriendlyTime = struct { text: []const u8, milliseconds: ?i64 = null, unavailable: bool = false };
fn friendlyTime(allocator: std.mem.Allocator, value: CalendarTime, local_zone: *const timezone.Zone, event_zone: ?*const timezone.Zone, event_id: []const u8) !FriendlyTime {
    const date = value.civil;
    if (value.kind == .date) return .{ .text = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} (all day)", .{ date.year, date.month, date.day }) };
    var milliseconds: ?i64 = null;
    var detail: []const u8 = "";
    switch (value.kind) {
        .utc => milliseconds = (try date.seconds()) * 1000,
        .floating => {
            detail = "floating local time";
            milliseconds = local_zone.fromLocal(date) catch |err| failed: {
                detail = localTimeProblem(err);
                break :failed null;
            };
        },
        .zoned => {
            detail = value.zone_id;
            if (event_zone != null and std.mem.eql(u8, value.zone_id, event_id)) milliseconds = event_zone.?.fromLocal(date) catch |err| failed: {
                detail = try std.fmt.allocPrint(allocator, "{s}; {s}", .{ value.zone_id, localTimeProblem(err) });
                break :failed null;
            };
        },
        .date => unreachable,
    }
    if (milliseconds) |stamp| {
        if (value.kind != .floating and stamp > 0) {
            const text = try local_zone.format(allocator, stamp);
            if (text.len > 0) return .{ .text = text, .milliseconds = stamp, .unavailable = std.mem.indexOf(u8, text, "TZ unavailable") != null };
        }
        if (value.kind == .utc) detail = "UTC";
    }
    return .{ .text = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} ({s})", .{ date.year, date.month, date.day, date.hour, date.minute, detail }), .milliseconds = milliseconds, .unavailable = milliseconds == null and value.kind != .floating };
}
fn localTimeProblem(err: anyerror) []const u8 {
    return switch (err) {
        error.AmbiguousLocalTime => "ambiguous local time",
        error.NonexistentLocalTime => "nonexistent local time",
        else => "timezone unavailable",
    };
}
fn parseDuration(raw: []const u8) !u64 {
    if (raw.len < 2 or raw[0] != 'P') return error.InvalidCalendarDuration;
    var offset: usize = 1;
    var seconds: u64 = 0;
    var time = false;
    var previous: u8 = 0;
    var parts: usize = 0;
    while (offset < raw.len) {
        if (raw[offset] == 'T') {
            if (time or offset + 1 == raw.len) return error.InvalidCalendarDuration;
            time = true;
            offset += 1;
            continue;
        }
        const start = offset;
        while (offset < raw.len and std.ascii.isDigit(raw[offset])) offset += 1;
        if (start == offset or offset == raw.len) return error.InvalidCalendarDuration;
        const amount = std.fmt.parseInt(u64, raw[start..offset], 10) catch return error.InvalidCalendarDuration;
        const unit = raw[offset];
        offset += 1;
        const rank: u8 = switch (unit) {
            'W' => if (!time and parts == 0 and offset == raw.len) 1 else return error.InvalidCalendarDuration,
            'D' => if (!time) 2 else return error.InvalidCalendarDuration,
            'H' => if (time) 3 else return error.InvalidCalendarDuration,
            'M' => if (time) 4 else return error.InvalidCalendarDuration,
            'S' => if (time) 5 else return error.InvalidCalendarDuration,
            else => return error.InvalidCalendarDuration,
        };
        if (rank <= previous) return error.InvalidCalendarDuration;
        previous = rank;
        const factor: u64 = switch (unit) {
            'W' => 604800,
            'D' => 86400,
            'H' => 3600,
            'M' => 60,
            else => 1,
        };
        seconds = std.math.add(u64, seconds, std.math.mul(u64, amount, factor) catch return error.InvalidCalendarDuration) catch return error.InvalidCalendarDuration;
        parts += 1;
    }
    if (parts == 0 or seconds > 366 * 100 * 86400) return error.InvalidCalendarDuration;
    return seconds;
}
fn formatDuration(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
    if (seconds % 86400 == 0 and seconds >= 86400) return std.fmt.allocPrint(allocator, "{d} day{s}", .{ seconds / 86400, if (seconds == 86400) "" else "s" });
    const hours = seconds / 3600;
    const minutes = seconds % 3600 / 60;
    if (seconds % 60 != 0) return std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ hours, minutes, seconds % 60 });
    if (hours == 0) return std.fmt.allocPrint(allocator, "{d} min", .{minutes});
    if (minutes == 0) return std.fmt.allocPrint(allocator, "{d} hour{s}", .{ hours, if (hours == 1) "" else "s" });
    return std.fmt.allocPrint(allocator, "{d}h {d}m", .{ hours, minutes });
}
fn recurrenceLabel(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, raw, ';');
    var frequency: []const u8 = "";
    while (parts.next()) |part| if (std.ascii.startsWithIgnoreCase(part, "FREQ=")) {
        frequency = part[5..];
    };
    const label = if (std.ascii.eqlIgnoreCase(frequency, "DAILY")) "Daily" else if (std.ascii.eqlIgnoreCase(frequency, "WEEKLY")) "Weekly" else if (std.ascii.eqlIgnoreCase(frequency, "MONTHLY")) "Monthly" else if (std.ascii.eqlIgnoreCase(frequency, "YEARLY")) "Yearly" else "Recurring";
    // Keep the exact rule visible: INTERVAL/BYDAY/UNTIL/COUNT affect semantics
    // and this review does not pretend to expand the recurring event series.
    return std.fmt.allocPrint(allocator, "{s} · {s}", .{ label, raw });
}
fn appendTimezone(out: *Invitation, line: []const u8) !void {
    const len: usize = out.timezones.len;
    if (line.len + 2 > out.timezones.bytes.len - len) return error.TimezoneTooLarge;
    @memcpy(out.timezones.bytes[len..][0..line.len], line);
    @memcpy(out.timezones.bytes[len + line.len ..][0..2], "\r\n");
    out.timezones.len = @intCast(len + line.len + 2);
}

const Property = struct { name: []const u8, parameters: []const u8, value: []const u8 };
fn property(line: []const u8) !Property {
    for (line) |c| if (c < 32 or c == 127) return error.InvalidCalendar;
    var quoted = false;
    var escaped = false;
    var colon: ?usize = null;
    for (line, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') quoted = !quoted;
        if (c == ':' and !quoted) {
            colon = i;
            break;
        }
    }
    const split = colon orelse return error.InvalidCalendar;
    const semicolon = std.mem.indexOfScalar(u8, line[0..split], ';') orelse split;
    const name = line[0..semicolon];
    if (name.len == 0) return error.InvalidCalendar;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidCalendar;
    return .{ .name = name, .parameters = line[semicolon..split], .value = line[split + 1 ..] };
}
fn mailto(value: []const u8) ![]const u8 {
    if (value.len < 7 or !std.ascii.eqlIgnoreCase(value[0..7], "mailto:")) return error.UnsupportedCalendarAddress;
    const address = value[7..];
    try recipients.validateAddress(address);
    return address;
}

const Lines = struct {
    input: []const u8,
    offset: usize = 0,
    fn physical(self: *Lines) ![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.input, self.offset, '\n') orelse self.input.len;
        var line = self.input[self.offset..end];
        self.offset = if (end < self.input.len) end + 1 else end;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.InvalidCalendar;
        return line;
    }
    fn next(self: *Lines, out: []u8) !?[]const u8 {
        if (self.offset >= self.input.len) return null;
        const first = try self.physical();
        if (first.len > 0 and (first[0] == ' ' or first[0] == '\t')) return error.InvalidCalendar;
        if (first.len > out.len) return error.CalendarLineTooLarge;
        @memcpy(out[0..first.len], first);
        var len = first.len;
        while (self.offset < self.input.len and (self.input[self.offset] == ' ' or self.input[self.offset] == '\t')) {
            const continuation = try self.physical();
            if (continuation.len - 1 > out.len - len) return error.CalendarLineTooLarge;
            @memcpy(out[len..][0 .. continuation.len - 1], continuation[1..]);
            len += continuation.len - 1;
        }
        return out[0..len];
    }
};

fn folded(w: *std.Io.Writer, line: []const u8) !void {
    var offset: usize = 0;
    var limit: usize = 75;
    while (line.len - offset > limit) {
        var cut = offset + limit;
        while (cut > offset and (line[cut] & 0xc0) == 0x80) cut -= 1;
        if (cut == offset) return error.InvalidUtf8;
        try w.writeAll(line[offset..cut]);
        try w.writeAll("\r\n ");
        offset = cut;
        limit = 74;
    }
    try w.writeAll(line[offset..]);
    try w.writeAll("\r\n");
}

pub fn reply(invite: *const Invitation, status: Status, utc_stamp: []const u8, out: []u8) ![]const u8 {
    try validateStamp(utc_stamp);
    try recipients.validateAddress(invite.organizer.slice());
    try recipients.validateAddress(invite.attendee.slice());
    try recipients.validateHeader(invite.uid.slice());
    try recipients.validateHeader(invite.recurrence_id.slice());
    try recipients.validateHeader(invite.recurrence_parameters.slice());
    if (invite.uid.len == 0) return error.InvalidCalendar;
    var writer = std.Io.Writer.fixed(out);
    try writer.writeAll("BEGIN:VCALENDAR\r\nPRODID:-//technologylab.ai//Omagma//EN\r\nVERSION:2.0\r\nMETHOD:REPLY\r\n");
    var zones = std.mem.splitSequence(u8, invite.timezones.slice(), "\r\n");
    while (zones.next()) |zone| if (zone.len > 0) try folded(&writer, zone);
    try writer.writeAll("BEGIN:VEVENT\r\n");
    var line: [2048]u8 = undefined;
    try folded(&writer, try std.fmt.bufPrint(&line, "UID:{s}", .{invite.uid.slice()}));
    try folded(&writer, try std.fmt.bufPrint(&line, "DTSTAMP:{s}", .{utc_stamp}));
    try folded(&writer, try std.fmt.bufPrint(&line, "ORGANIZER:mailto:{s}", .{invite.organizer.slice()}));
    try folded(&writer, try std.fmt.bufPrint(&line, "ATTENDEE;PARTSTAT={s}:mailto:{s}", .{ switch (status) {
        .accepted => "ACCEPTED",
        .tentative => "TENTATIVE",
        .declined => "DECLINED",
    }, invite.attendee.slice() }));
    try folded(&writer, try std.fmt.bufPrint(&line, "SEQUENCE:{d}", .{invite.sequence}));
    if (invite.recurrence_id.len > 0) try folded(&writer, try std.fmt.bufPrint(&line, "RECURRENCE-ID{s}:{s}", .{ invite.recurrence_parameters.slice(), invite.recurrence_id.slice() }));
    try writer.writeAll("END:VEVENT\r\nEND:VCALENDAR\r\n");
    return writer.buffered();
}
fn validateStamp(utc_stamp: []const u8) !void {
    if (utc_stamp.len != 16 or utc_stamp[8] != 'T' or utc_stamp[15] != 'Z') return error.InvalidCalendarTimestamp;
    for (utc_stamp, 0..) |c, i| if (i != 8 and i != 15 and !std.ascii.isDigit(c)) return error.InvalidCalendarTimestamp;
    const year = std.fmt.parseInt(u32, utc_stamp[0..4], 10) catch return error.InvalidCalendarTimestamp;
    const month = std.fmt.parseInt(usize, utc_stamp[4..6], 10) catch return error.InvalidCalendarTimestamp;
    const day = std.fmt.parseInt(u32, utc_stamp[6..8], 10) catch return error.InvalidCalendarTimestamp;
    const hour = std.fmt.parseInt(u32, utc_stamp[9..11], 10) catch return error.InvalidCalendarTimestamp;
    const minute = std.fmt.parseInt(u32, utc_stamp[11..13], 10) catch return error.InvalidCalendarTimestamp;
    const second = std.fmt.parseInt(u32, utc_stamp[13..15], 10) catch return error.InvalidCalendarTimestamp;
    const month_days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (year == 0 or month == 0 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 60) return error.InvalidCalendarTimestamp;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    if (day > month_days[month - 1] + @as(u32, @intFromBool(month == 2 and leap))) return error.InvalidCalendarTimestamp;
}

test "invitation metadata: local readable times duration unescaped location and safe join links" {
    const calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:details@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nSUMMARY:Café\\, planning\r\nDTSTART:20261012T080000Z\r\nDTEND:20261012T093000Z\r\nLOCATION:Room 2\\, upstairs\\nEast wing\r\nDESCRIPTION:Join meeting https://example.test/meeting\r\nURL:javascript:alert(1)\r\nCONFERENCE:https://meet.example.test/room?token=fixture\r\nRRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: Invitation = .{};
    try parse(calendar, "self@example.test", &.{}, &invite);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    const display = try friendly(arena.allocator(), &invite, &zone);
    try std.testing.expectEqualStrings("Café, planning", invite.summary.slice());
    try std.testing.expectEqualStrings("2026-10-12 10:00 CEST", display.start);
    try std.testing.expectEqualStrings("2026-10-12 11:30 CEST", display.end);
    try std.testing.expectEqualStrings("1h 30m", display.duration);
    try std.testing.expectEqualStrings("Room 2, upstairs East wing", display.location);
    try std.testing.expectEqualStrings("https://meet.example.test/room?token=fixture", display.join_url);
    try std.testing.expectEqualStrings("Weekly · FREQ=WEEKLY;INTERVAL=2;COUNT=3", display.recurrence);
    try std.testing.expect(!display.all_day and !display.timezone_unavailable);
}
test "invitation metadata: all day exclusive dates and unknown TZID do not guess" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var invite: Invitation = .{};
    try invite.start.set("20261012");
    try invite.start_parameters.set(";VALUE=DATE");
    try invite.end.set("20261014");
    try invite.end_parameters.set(";VALUE=DATE");
    const display = try friendly(arena.allocator(), &invite, &.{});
    try std.testing.expect(display.all_day);
    try std.testing.expectEqualStrings("2026-10-12 (all day)", display.start);
    try std.testing.expectEqualStrings("2026-10-14 (all day) (exclusive)", display.end);
    try std.testing.expectEqualStrings("2 days", display.duration);
    invite = .{};
    try invite.start.set("20261012T100000");
    try invite.start_parameters.set(";TZID=\"Custom/Fixture\"");
    try invite.duration.set("PT45M");
    try invite.recurrence_id.set("20261012T100000");
    try invite.recurrence_parameters.set(";TZID=\"Custom/Fixture\"");
    try invite.join_url.set("https://user:pass@example.test/private");
    const unknown = try friendly(arena.allocator(), &invite, &.{});
    try std.testing.expectEqualStrings("Custom/Fixture", eventTimezone(&invite));
    try std.testing.expectEqualStrings("2026-10-12 10:00 (Custom/Fixture)", unknown.start);
    try std.testing.expectEqualStrings("45 min", unknown.duration);
    try std.testing.expectEqualStrings("This occurrence: 2026-10-12 10:00 (Custom/Fixture)", unknown.recurrence);
    try std.testing.expect(unknown.timezone_unavailable and unknown.join_url.len == 0);
}
test "invitation metadata: named zones DST ambiguity and embedded rules preserve source meaning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const event_zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    var invite: Invitation = .{};
    try invite.start.set("20261012T100000");
    try invite.start_parameters.set(";TZID=Europe/Vienna");
    const local = try friendlyWithZone(arena.allocator(), &invite, &.{}, &event_zone);
    try std.testing.expectEqualStrings("2026-10-12 08:00 UTC", local.start);
    try invite.start.set("20261025T023000");
    const fold = try friendlyWithZone(arena.allocator(), &invite, &.{}, &event_zone);
    try std.testing.expect(std.mem.indexOf(u8, fold.start, "ambiguous local time") != null);
    try std.testing.expect(fold.timezone_unavailable);
    try invite.start.set("20260329T023000");
    const gap = try friendlyWithZone(arena.allocator(), &invite, &.{}, &event_zone);
    try std.testing.expect(std.mem.indexOf(u8, gap.start, "nonexistent local time") != null);
    try invite.start.set("20261012T100000");
    try invite.timezones.set("BEGIN:VTIMEZONE\r\nTZID:Europe/Vienna\r\nEND:VTIMEZONE\r\n");
    const embedded = try friendlyWithZone(arena.allocator(), &invite, &.{}, &event_zone);
    try std.testing.expectEqualStrings("2026-10-12 10:00 (Europe/Vienna)", embedded.start);
    try std.testing.expect(embedded.timezone_unavailable);
}

test "iTIP preserves request identity sequence recurrence and responding attendee" {
    const request = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:meeting@example.test\r\nSEQUENCE:7\r\nORGANIZER;CN=Host:mailto:host@example.test\r\nATTENDEE;RSVP=TRUE:mailto:self@example.test\r\nRECURRENCE-ID;TZID=Europe/Vienna:20261012T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: Invitation = .{};
    try parse(request, "self@example.test", &.{}, &invite);
    var buffer: [4096]u8 = undefined;
    const response = try reply(&invite, .declined, "20261005T120000Z", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, response, "METHOD:REPLY\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "ATTENDEE;PARTSTAT=DECLINED:mailto:self@example.test\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "SEQUENCE:7\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "RECURRENCE-ID;TZID=Europe/Vienna:20261012T100000\r\n") != null);
    try std.testing.expectError(error.NotAnAttendee, parse(request, "other@example.test", &.{}, &invite));
}

test "calendar folding unfolds fixed literal bytes and refuses duplicate identities" {
    const request = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:meeting-\r\n continuation@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: Invitation = .{};
    try parse(request, "self@example.test", &.{}, &invite);
    try std.testing.expectEqualStrings("meeting-continuation@example.test", invite.uid.slice());
    const invalid = "BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:one\nUID:two\nEND:VEVENT\nEND:VCALENDAR\n";
    try std.testing.expectError(error.AmbiguousInvitation, parse(invalid, "self@example.test", &.{}, &invite));
}
test "RSVP replies validate PARTSTAT timestamp and balanced nested components" {
    const response = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:meeting@example.test\r\nDTSTAMP:20261005T120000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:self@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var parsed: Invitation = .{};
    try parseReply(response, "self@example.test", &.{}, &parsed);
    try std.testing.expectEqualStrings("meeting@example.test", parsed.uid.slice());
    try std.testing.expectError(error.InvalidCalendarTimestamp, validateStamp("20260230T120000Z"));
    try std.testing.expectError(error.InvalidCalendarTimestamp, validateStamp("20261005T250000Z"));
    const invalid = "BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:REQUEST\nBEGIN:VEVENT\nBEGIN:VALARM\nEND:VTIMEZONE\nEND:VEVENT\nEND:VCALENDAR\n";
    try std.testing.expectError(error.InvalidCalendar, parse(invalid, "self@example.test", &.{}, &parsed));
}
test "recurring RSVP preserves bounded VTIMEZONE component used by recurrence" {
    const request = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VTIMEZONE\r\nTZID:Custom/Fixture\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:timezone-instance@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nRECURRENCE-ID;TZID=Custom/Fixture:20261012T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: Invitation = .{};
    try parse(request, "self@example.test", &.{}, &invite);
    var buffer: [4096]u8 = undefined;
    const result = try reply(&invite, .accepted, "20261005T120000Z", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, result, "BEGIN:VTIMEZONE\r\nTZID:Custom/Fixture\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "RECURRENCE-ID;TZID=Custom/Fixture:20261012T100000\r\n") != null);
}

test "invitation parse: Outlook quoted parameters folds and large meetings select exactly one identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var calendar: std.ArrayList(u8) = .empty;
    try calendar.appendSlice(a, "BEGIN:VCALENDAR\r\nPRODID:-//Fixture//Outlook-shaped//EN\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:teams-meeting-\r\n fixture@example.test\r\nDTSTAMP:20261007T090000Z\r\nSEQUENCE:12\r\nORGANIZER;CN=\"Fixture Host: Team\":MAILTO:host@example.test\r\nDTSTART;TZID=\"W. Europe Standard Time\":20261012T100000\r\nRECURRENCE-ID;TZID=\"W. Europe Standard Time\":20261012T100000\r\nSUMMARY:Fixture Teams meeting\r\n");
    for (0..80) |number| try calendar.appendSlice(a, try std.fmt.allocPrint(a, "ATTENDEE;CN=\"Guest {d}\";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:guest{d}@example.test\r\n", .{ number, number }));
    try calendar.appendSlice(a, "ATTENDEE;CN=\"Fixture, Guest; Department\";ROLE=REQ-PARTICIPANT;RSVP=TRUE:MAILTO:alias@example.test\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");
    var invite: Invitation = .{};
    try parse(calendar.items, "self@example.test", &.{"alias@example.test"}, &invite);
    try std.testing.expectEqualStrings("teams-meeting-fixture@example.test", invite.uid.slice());
    try std.testing.expectEqualStrings("host@example.test", invite.organizer.slice());
    try std.testing.expectEqualStrings("alias@example.test", invite.attendee.slice());
    try std.testing.expectEqual(@as(u32, 12), invite.sequence);
    try std.testing.expectEqualStrings(";TZID=\"W. Europe Standard Time\"", invite.recurrence_parameters.slice());
    try std.testing.expectError(error.NotAnAttendee, parse(calendar.items, "absent@example.test", &.{}, &invite));
    // Both the primary identity and an alias must not silently choose one
    // membership when two calendar users could receive the response.
    try std.testing.expectError(error.AmbiguousAttendee, parse(calendar.items, "guest0@example.test", &.{"alias@example.test"}, &invite));
}

test "invitation reply: RFC5546 minimal replies omit DTSTART and preserve literal original identity" {
    const calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:provider-fixture@example.test\r\nDTSTAMP:20261007T090000Z\r\nDTSTART:20261012T080000Z\r\nDTEND:20261012T090000Z\r\nSUMMARY:Fixture meeting\r\nSEQUENCE:5\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;RSVP=TRUE:mailto:self@example.test\r\nATTENDEE:mailto:other@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: Invitation = .{};
    try parse(calendar, "self@example.test", &.{}, &invite);
    var output: [4096]u8 = undefined;
    for ([_]struct { status: Status, partstat: []const u8 }{
        .{ .status = .accepted, .partstat = "ATTENDEE;PARTSTAT=ACCEPTED:mailto:self@example.test\r\n" },
        .{ .status = .tentative, .partstat = "ATTENDEE;PARTSTAT=TENTATIVE:mailto:self@example.test\r\n" },
        .{ .status = .declined, .partstat = "ATTENDEE;PARTSTAT=DECLINED:mailto:self@example.test\r\n" },
    }) |expected| {
        const response = try reply(&invite, expected.status, "20261007T100000Z", &output);
        try std.testing.expect(std.mem.indexOf(u8, response, "METHOD:REPLY\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "UID:provider-fixture@example.test\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "DTSTAMP:20261007T100000Z\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "ORGANIZER:mailto:host@example.test\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "SEQUENCE:5\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, expected.partstat) != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "DTSTART:") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "other@example.test") == null);
    }
}

test "invitation parse: UTF8 folds property budget and unrelated event ambiguity stay bounded" {
    const divided = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:utf8-fixture@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nSUMMARY:Caf\xc3\r\n \xa9\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: Invitation = .{};
    try parse(divided, "self@example.test", &.{}, &invite);
    try std.testing.expectEqualStrings("Café", invite.summary.slice());
    try std.testing.expectError(error.AmbiguousInvitation, parse("BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:first@example.test\nORGANIZER:mailto:host@example.test\nATTENDEE:mailto:self@example.test\nEND:VEVENT\nBEGIN:VEVENT\nUID:second@example.test\nEND:VEVENT\nEND:VCALENDAR\n", "self@example.test", &.{}, &invite));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var properties: std.ArrayList(u8) = .empty;
    try properties.appendSlice(a, "BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:many@example.test\nORGANIZER:mailto:host@example.test\n");
    for (0..1024) |number| try properties.appendSlice(a, try std.fmt.allocPrint(a, "ATTENDEE:mailto:guest{d}@example.test\n", .{number}));
    try properties.appendSlice(a, "END:VEVENT\nEND:VCALENDAR\n");
    try std.testing.expectError(error.TooManyCalendarProperties, parse(properties.items, "self@example.test", &.{}, &invite));
    try std.testing.expectError(error.NotInvitationRequest, parse("BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:PUBLISH\nBEGIN:VEVENT\nUID:zoom-import@example.test\nEND:VEVENT\nEND:VCALENDAR\n", "self@example.test", &.{}, &invite));
}
