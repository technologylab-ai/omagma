//! Pure Calendar presentation and lenient-entry helpers for the native TUI.
//! Civil days are days since 1970-01-01 in the displayed zone; nothing here
//! reads a clock, a file or a provider, so every rule is directly testable.
const std = @import("std");
const tz = @import("timezone.zig");
const invitation = @import("invitation.zig");

pub const weekday_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const full_weekdays = [_][]const u8{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" };

/// Monday is 0. 1970-01-01 was a Thursday.
pub fn weekday(day: i64) usize {
    return @intCast(@mod(day + 3, 7));
}
/// Weeks start on Monday.
pub fn mondayOf(day: i64) i64 {
    return day - @as(i64, @intCast(weekday(day)));
}
pub const Civil = struct { year: i64, month: u8, day: u8 };
pub fn civil(days: i64) Civil {
    // Howard Hinnant's days-from-civil inverse, proleptic Gregorian.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @as(i64, @intFromBool(m <= 2)), .month = m, .day = d };
}
/// "Tue 10 Nov"
pub fn shortDate(a: std.mem.Allocator, day: i64) ![]const u8 {
    const value = civil(day);
    return std.fmt.allocPrint(a, "{s} {d} {s}", .{ weekday_names[weekday(day)], value.day, month_names[value.month - 1] });
}
/// Agenda day headers: "Today · Tue 10 Nov", "Tomorrow · Wed 11 Nov", or "Thu 12 Nov".
pub fn dayHeader(a: std.mem.Allocator, day: i64, today: ?i64) ![]const u8 {
    const date = try shortDate(a, day);
    const now = today orelse return date;
    const relative: []const u8 = if (day == now) "Today" else if (day == now + 1) "Tomorrow" else if (day == now - 1) "Yesterday" else return date;
    return std.fmt.allocPrint(a, "{s} · {s}", .{ relative, date });
}
/// Range heading: "Mon 9 Nov – Sun 15 Nov 2026" or "Tue 10 Nov 2026".
pub fn rangeText(a: std.mem.Allocator, first: i64, days: i64) ![]const u8 {
    const last = first + @max(days, 1) - 1;
    const year = civil(last).year;
    if (last == first) return std.fmt.allocPrint(a, "{s} {d}", .{ try shortDate(a, first), year });
    return std.fmt.allocPrint(a, "{s} – {s} {d}", .{ try shortDate(a, first), try shortDate(a, last), year });
}
pub fn durationText(a: std.mem.Allocator, minutes: i64) ![]const u8 {
    if (minutes <= 0) return "";
    if (minutes < 60) return std.fmt.allocPrint(a, "{d}m", .{minutes});
    if (@mod(minutes, 60) == 0) return std.fmt.allocPrint(a, "{d}h", .{@divFloor(minutes, 60)});
    return std.fmt.allocPrint(a, "{d}h {d}m", .{ @divFloor(minutes, 60), @mod(minutes, 60) });
}
/// Agenda column durations: "30m", "1h", "1h30", "12h".
pub fn compactDuration(a: std.mem.Allocator, minutes: i64) ![]const u8 {
    if (minutes <= 0) return "";
    if (minutes < 60) return std.fmt.allocPrint(a, "{d}m", .{minutes});
    if (@mod(minutes, 60) == 0) return std.fmt.allocPrint(a, "{d}h", .{@divFloor(minutes, 60)});
    return std.fmt.allocPrint(a, "{d}h{d:0>2}", .{ @divFloor(minutes, 60), @as(u8, @intCast(@mod(minutes, 60))) });
}
/// Right-pad to `width` codepoints (agenda text is narrow); longer stays.
pub fn padded(a: std.mem.Allocator, raw: []const u8, width: usize) ![]const u8 {
    const count = std.unicode.utf8CountCodepoints(raw) catch raw.len;
    if (count >= width) return raw;
    const out = try a.alloc(u8, raw.len + width - count);
    @memcpy(out[0..raw.len], raw);
    @memset(out[raw.len..], ' ');
    return out;
}
/// "next in 53 min", "next in 2h 5m", or "next now".
pub fn untilText(a: std.mem.Allocator, minutes: i64) ![]const u8 {
    if (minutes <= 0) return "next now";
    if (minutes < 60) return std.fmt.allocPrint(a, "next in {d} min", .{minutes});
    return std.fmt.allocPrint(a, "next in {s}", .{try durationText(a, minutes)});
}

/// Damaged invitations explain each recovery in words, deduplicated.
pub fn damageReasons(a: std.mem.Allocator, bits: u16) ![]const u8 {
    const D = invitation.Defect;
    var out: std.ArrayList(u8) = .empty;
    const reasons = [_]struct { u16, []const u8 }{
        .{ D.organizer, "organizer address unreadable" },
        .{ D.duplicate, "repeated fields, first value shown" },
        .{ D.timezone, "time-zone rules dropped, times unverified" },
        .{ D.syntax | D.structure | D.truncated, "malformed calendar data" },
        .{ D.stamp, "send time unreadable" },
        .{ D.sequence, "update number unreadable" },
        .{ D.reply, "stated response unreadable" },
    };
    for (reasons) |reason| if (bits & reason[0] != 0) {
        if (out.items.len > 0) try out.appendSlice(a, "; ");
        try out.appendSlice(a, reason[1]);
    };
    return out.toOwnedSlice(a);
}
/// "Fixture Host (address unreadable)", the address, or a name with address.
pub fn organizerText(a: std.mem.Allocator, address: []const u8, name: []const u8, unreadable: bool) ![]const u8 {
    if (address.len == 0) {
        if (!unreadable) return name;
        return if (name.len > 0) std.fmt.allocPrint(a, "{s} (address unreadable)", .{name}) else "(address unreadable)";
    }
    return address;
}

/// Calendar status sentences for backend error names. Null leaves the
/// caller's shared mail labels or a generic sentence in charge.
pub fn errorText(code: []const u8) ?[]const u8 {
    const Label = struct { []const u8, []const u8 };
    const labels = [_]Label{
        .{ "ConnectionRefused", "Connection temporarily unavailable" },
        .{ "ConnectionResetByPeer", "Connection temporarily unavailable" },
        .{ "ConnectionTimedOut", "Connection temporarily unavailable" },
        .{ "NetworkUnreachable", "Connection temporarily unavailable" },
        .{ "HostUnreachable", "Connection temporarily unavailable" },
        .{ "TemporaryNameServerFailure", "Connection temporarily unavailable" },
        .{ "UnknownHostName", "Connection temporarily unavailable" },
        .{ "TransientFailure", "Connection temporarily unavailable" },
        .{ "Timeout", "Calendar request timed out" },
        .{ "DeadlineExceeded", "Calendar request timed out" },
        .{ "CalendarUnavailable", "Google Calendar is unavailable right now" },
        .{ "CalendarRateLimited", "Calendar rate limit · try again shortly" },
        .{ "RateLimited", "Calendar rate limit · try again shortly" },
        .{ "CalendarReadPermissionRequired", "Calendar read access is needed for this account" },
        .{ "CalendarPermissionRequired", "Calendar access is needed for this account" },
        .{ "CalendarWritePermissionRequired", "Calendar write access is needed for this calendar" },
        .{ "CalendarReadOnly", "This calendar is read-only" },
        .{ "CalendarNotFound", "This calendar or event no longer exists" },
        .{ "CalendarListIncomplete", "Google returned only part of the calendar list" },
        .{ "CalendarDisplayLimit", "Too many events to show for this calendar window" },
        .{ "CalendarTooLarge", "Calendar data exceeds the supported size" },
        .{ "CalendarWindowMismatch", "Calendar returned a different date range" },
        .{ "InvalidCalendarResponse", "Calendar returned an unreadable response" },
        .{ "CacheMiss", "Not saved for offline use · connect to load this range" },
        .{ "CalendarTimezoneRequired", "The invitation has no usable time zone" },
        .{ "FloatingTimeRequiresReview", "The invitation has no time zone (floating time)" },
        .{ "EmbeddedTimezoneUnresolved", "The invitation's own time-zone rules are not recognised" },
        .{ "AmbiguousLocalTime", "The invitation's time occurs twice on this day (DST)" },
        .{ "NonexistentLocalTime", "The invitation's time is skipped by daylight saving" },
        .{ "UnsupportedCalendarAddress", "The invitation's organizer or attendee address is unreadable" },
        .{ "UnsupportedCalendarRecurrence", "Repeating invitations are reviewed in Google Calendar" },
        .{ "CalendarReviewStale", "The invitation changed · review the latest version" },
        .{ "InvalidCalendar", "The invitation's calendar data is damaged" },
        .{ "NotInvitation", "No calendar invitation found in this mail" },
        .{ "CalendarPrimaryUnavailable", "No writable primary calendar for this account" },
        .{ "UnknownOutcome", "Outcome unknown · check before retrying" },
    };
    for (labels) |label| if (std.mem.eql(u8, code, label[0])) return label[1];
    return null;
}
/// Network-class failures: offline, not a permission problem.
pub fn offline(code: []const u8) bool {
    const text = errorText(code) orelse return false;
    return std.mem.eql(u8, text, "Connection temporarily unavailable") or std.mem.eql(u8, code, "Timeout") or std.mem.eql(u8, code, "DeadlineExceeded") or std.mem.eql(u8, code, "CalendarUnavailable");
}

/// Ctrl+G accepts YYYY-MM-DD, MM-DD (this year), today/tomorrow/yesterday,
/// weekday names (the next such day, today included), and +Nd/-Nw offsets.
pub fn jumpDate(raw_in: []const u8, today: i64) !i64 {
    const raw = std.mem.trim(u8, raw_in, " \t");
    if (raw.len == 0) return error.InvalidCalendarDate;
    var lower_buffer: [16]u8 = undefined;
    if (raw.len > lower_buffer.len) return error.InvalidCalendarDate;
    const lower = std.ascii.lowerString(&lower_buffer, raw);
    if (std.mem.eql(u8, lower, "today") or std.mem.eql(u8, lower, "t")) return today;
    if (std.mem.eql(u8, lower, "tomorrow") or std.mem.eql(u8, lower, "tom")) return today + 1;
    if (std.mem.eql(u8, lower, "yesterday")) return today - 1;
    if (lower[0] == '+' or lower[0] == '-') {
        const negative = lower[0] == '-';
        var end: usize = 1;
        while (end < lower.len and std.ascii.isDigit(lower[end])) end += 1;
        if (end == 1 or end > 5) return error.InvalidCalendarDate;
        const count = std.fmt.parseInt(i64, lower[1..end], 10) catch return error.InvalidCalendarDate;
        const unit = lower[end..];
        const days: i64 = if (unit.len == 0 or std.mem.eql(u8, unit, "d")) count else if (std.mem.eql(u8, unit, "w")) count * 7 else return error.InvalidCalendarDate;
        return if (negative) today - days else today + days;
    }
    if (lower.len >= 2) for (full_weekdays, 0..) |name, index| {
        if (lower.len <= name.len and std.mem.startsWith(u8, name, lower) and (lower.len >= 3 or index != 5 and index != 6 and index != 1 and index != 3)) {
            return today + @as(i64, @intCast(@mod(@as(i64, @intCast(index)) - @as(i64, @intCast(weekday(today))), 7)));
        }
    };
    if (raw.len == 10) return tz.dateDay(raw) catch error.InvalidCalendarDate;
    if (raw.len == 5 and raw[2] == '-') {
        const year = civil(today).year;
        var buffer: [10]u8 = undefined;
        const full = std.fmt.bufPrint(&buffer, "{d:0>4}-{s}", .{ @as(u16, @intCast(@max(0, @min(year, 9999)))), raw }) catch return error.InvalidCalendarDate;
        return tz.dateDay(full) catch error.InvalidCalendarDate;
    }
    return error.InvalidCalendarDate;
}
/// ISO text for a civil day.
pub fn isoDate(buffer: *[10]u8, day: i64) []const u8 {
    const value = civil(day);
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u16, @intCast(@max(0, @min(value.year, 9999)))), value.month, value.day }) catch unreachable;
}

/// Lenient clock entry: "1430", "14:30", "9", "930", "2pm", "2:30 pm",
/// "12am". Returns minutes after midnight.
pub fn clockMinutes(raw_in: []const u8) !u16 {
    const raw = std.mem.trim(u8, raw_in, " \t");
    if (raw.len == 0 or raw.len > 8) return error.InvalidCalendarTime;
    var lower_buffer: [8]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buffer, raw);
    var body: []const u8 = lower;
    var meridiem: enum { none, am, pm } = .none;
    if (std.mem.endsWith(u8, body, "am") or std.mem.endsWith(u8, body, "pm")) {
        meridiem = if (body[body.len - 2] == 'a') .am else .pm;
        body = std.mem.trimEnd(u8, body[0 .. body.len - 2], " ");
    } else if (std.mem.endsWith(u8, body, "a") or std.mem.endsWith(u8, body, "p")) {
        meridiem = if (body[body.len - 1] == 'a') .am else .pm;
        body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " ");
    }
    var digits: [4]u8 = undefined;
    var count: usize = 0;
    var colon: ?usize = null;
    for (body) |byte| {
        if (byte == ':' or byte == '.') {
            if (colon != null or count == 0) return error.InvalidCalendarTime;
            colon = count;
        } else if (std.ascii.isDigit(byte)) {
            if (count == digits.len) return error.InvalidCalendarTime;
            digits[count] = byte - '0';
            count += 1;
        } else return error.InvalidCalendarTime;
    }
    if (count == 0) return error.InvalidCalendarTime;
    const hour_digits = colon orelse if (count <= 2) count else count - 2;
    if (hour_digits == 0 or hour_digits > 2 or count - hour_digits > 2 or (colon != null and count - hour_digits != 2)) return error.InvalidCalendarTime;
    var hour: u16 = 0;
    for (digits[0..hour_digits]) |digit| hour = hour * 10 + digit;
    var minute: u16 = 0;
    for (digits[hour_digits..count]) |digit| minute = minute * 10 + digit;
    if (count - hour_digits == 1) return error.InvalidCalendarTime;
    switch (meridiem) {
        .none => {},
        .am, .pm => {
            if (hour == 0 or hour > 12) return error.InvalidCalendarTime;
            hour = @mod(hour, 12) + @as(u16, if (meridiem == .pm) 12 else 0);
        },
    }
    if (hour > 23 or minute > 59) return error.InvalidCalendarTime;
    return hour * 60 + minute;
}
/// "+45m", "+1h", "+1h30m" or "+90" (minutes) after a start.
pub fn offsetMinutes(raw_in: []const u8) !?u16 {
    const raw = std.mem.trim(u8, raw_in, " \t");
    if (raw.len < 2 or raw[0] != '+') return null;
    var total: u32 = 0;
    var value: u32 = 0;
    var digits: usize = 0;
    var unit_seen = false;
    for (raw[1..]) |byte| {
        if (std.ascii.isDigit(byte)) {
            value = value * 10 + (byte - '0');
            digits += 1;
            if (digits > 4) return error.InvalidCalendarTime;
        } else if (byte == 'h' or byte == 'H' or byte == 'm' or byte == 'M') {
            if (digits == 0) return error.InvalidCalendarTime;
            total += if (byte == 'h' or byte == 'H') value * 60 else value;
            value = 0;
            digits = 0;
            unit_seen = true;
        } else if (byte != ' ') return error.InvalidCalendarTime;
    }
    if (digits > 0) total += value;
    if (total == 0 or total >= 24 * 60 or (!unit_seen and digits == 0)) return error.InvalidCalendarTime;
    return @intCast(total);
}
pub fn clockText(buffer: *[5]u8, minutes: u16) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ minutes / 60, minutes % 60 }) catch unreachable;
}
/// Normalize a composer clock field; exact HH:MM[:SS[.fff]] passes through.
pub fn normalizeClock(buffer: *[5]u8, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len >= 8 and trimmed[2] == ':' and trimmed[5] == ':') return trimmed;
    return clockText(buffer, try clockMinutes(trimmed));
}
/// Normalize a composer date field relative to today; ISO passes through.
pub fn normalizeDate(buffer: *[10]u8, raw: []const u8, today: i64) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 10 and trimmed[4] == '-' and trimmed[7] == '-') return trimmed;
    return isoDate(buffer, try jumpDate(trimmed, today));
}

test "calendar text: weekdays, Monday weeks and friendly headers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tuesday = try tz.dateDay("2026-11-10");
    try std.testing.expectEqual(@as(usize, 1), weekday(tuesday));
    try std.testing.expectEqual(try tz.dateDay("2026-11-09"), mondayOf(tuesday));
    try std.testing.expectEqual(try tz.dateDay("2026-11-09"), mondayOf(try tz.dateDay("2026-11-15")));
    try std.testing.expectEqual(try tz.dateDay("2026-11-16"), mondayOf(try tz.dateDay("2026-11-16")));
    try std.testing.expectEqualStrings("Today · Tue 10 Nov", try dayHeader(a, tuesday, tuesday));
    try std.testing.expectEqualStrings("Tomorrow · Wed 11 Nov", try dayHeader(a, tuesday + 1, tuesday));
    try std.testing.expectEqualStrings("Thu 12 Nov", try dayHeader(a, tuesday + 2, tuesday));
    try std.testing.expectEqualStrings("Mon 9 Nov – Sun 15 Nov 2026", try rangeText(a, tuesday - 1, 7));
    try std.testing.expectEqualStrings("Thu 31 Dec – Sat 2 Jan 2027", try rangeText(a, try tz.dateDay("2026-12-31"), 3));
    try std.testing.expectEqualStrings("Tue 10 Nov 2026", try rangeText(a, tuesday, 1));
    try std.testing.expectEqualStrings("1h 30m", try durationText(a, 90));
    try std.testing.expectEqualStrings("next in 53 min", try untilText(a, 53));
    try std.testing.expectEqualStrings("next in 2h 5m", try untilText(a, 125));
    try std.testing.expectEqualStrings("1h30", try compactDuration(a, 90));
    try std.testing.expectEqualStrings("30m", try compactDuration(a, 30));
    try std.testing.expectEqualStrings("2h", try compactDuration(a, 120));
    try std.testing.expectEqualStrings("all-day    ", try padded(a, "all-day", 11));
    try std.testing.expectEqualStrings("09:00–10:00", try padded(a, "09:00–10:00", 11));
    for ([_][]const u8{ "1970-01-01", "2000-02-29", "2026-11-10", "2100-03-01" }) |iso| {
        var buffer: [10]u8 = undefined;
        try std.testing.expectEqualStrings(iso, isoDate(&buffer, try tz.dateDay(iso)));
    }
}

test "calendar text: damaged invitations, organizer fallback and offline errors use words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const D = invitation.Defect;
    try std.testing.expectEqualStrings("organizer address unreadable; repeated fields, first value shown", try damageReasons(a, D.organizer | D.duplicate));
    try std.testing.expectEqualStrings("malformed calendar data", try damageReasons(a, D.syntax | D.truncated | D.structure));
    try std.testing.expectEqualStrings("time-zone rules dropped, times unverified", try damageReasons(a, D.timezone));
    try std.testing.expectEqualStrings("Fixture Host (address unreadable)", try organizerText(a, "", "Fixture Host", true));
    try std.testing.expectEqualStrings("(address unreadable)", try organizerText(a, "", "", true));
    try std.testing.expectEqualStrings("host@example.test", try organizerText(a, "host@example.test", "Host", false));
    try std.testing.expectEqualStrings("", try organizerText(a, "", "", false));
    try std.testing.expectEqualStrings("Connection temporarily unavailable", errorText("ConnectionRefused").?);
    try std.testing.expect(offline("ConnectionRefused") and offline("Timeout") and !offline("CalendarWritePermissionRequired"));
    try std.testing.expect(errorText("SomethingNew") == null);
}

test "calendar text: date jumps accept offsets, names and partial dates" {
    const today = try tz.dateDay("2026-11-10"); // Tuesday
    try std.testing.expectEqual(today + 3, try jumpDate("+3d", today));
    try std.testing.expectEqual(today + 3, try jumpDate("+3", today));
    try std.testing.expectEqual(today - 7, try jumpDate("-1w", today));
    try std.testing.expectEqual(today + 3, try jumpDate("fri", today));
    try std.testing.expectEqual(today + 3, try jumpDate("Friday", today));
    try std.testing.expectEqual(today, try jumpDate("tue", today));
    try std.testing.expectEqual(today + 6, try jumpDate("mon", today));
    try std.testing.expectEqual(today + 1, try jumpDate("tomorrow", today));
    try std.testing.expectEqual(try tz.dateDay("2026-12-24"), try jumpDate("12-24", today));
    try std.testing.expectEqual(try tz.dateDay("2027-01-05"), try jumpDate("2027-01-05", today));
    for ([_][]const u8{ "", "s", "+", "+3y", "13-01", "2026-02-30", "someday", "+99999d" }) |bad| try std.testing.expectError(error.InvalidCalendarDate, jumpDate(bad, today));
}

test "calendar text: lenient clock and end offsets normalize to HH:MM" {
    try std.testing.expectEqual(@as(u16, 14 * 60 + 30), try clockMinutes("1430"));
    try std.testing.expectEqual(@as(u16, 14 * 60 + 30), try clockMinutes("14:30"));
    try std.testing.expectEqual(@as(u16, 9 * 60), try clockMinutes("9"));
    try std.testing.expectEqual(@as(u16, 9 * 60 + 30), try clockMinutes("930"));
    try std.testing.expectEqual(@as(u16, 14 * 60), try clockMinutes("2pm"));
    try std.testing.expectEqual(@as(u16, 14 * 60 + 30), try clockMinutes("2:30 PM"));
    try std.testing.expectEqual(@as(u16, 0), try clockMinutes("12am"));
    try std.testing.expectEqual(@as(u16, 12 * 60), try clockMinutes("12pm"));
    for ([_][]const u8{ "", "25", "13pm", "9:5", "12345", "ab", "0am", "14:3x" }) |bad| try std.testing.expectError(error.InvalidCalendarTime, clockMinutes(bad));
    try std.testing.expectEqual(@as(?u16, 45), try offsetMinutes("+45m"));
    try std.testing.expectEqual(@as(?u16, 90), try offsetMinutes("+1h30m"));
    try std.testing.expectEqual(@as(?u16, 60), try offsetMinutes("+1h"));
    try std.testing.expectEqual(@as(?u16, 90), try offsetMinutes("+90"));
    try std.testing.expectEqual(@as(?u16, null), try offsetMinutes("10:00"));
    try std.testing.expectError(error.InvalidCalendarTime, offsetMinutes("+0m"));
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqualStrings("14:30", try normalizeClock(&buffer, "1430"));
    try std.testing.expectEqualStrings("09:00:00", try normalizeClock(&buffer, "09:00:00"));
    var date: [10]u8 = undefined;
    const today = try tz.dateDay("2026-11-10");
    try std.testing.expectEqualStrings("2026-11-11", try normalizeDate(&date, "tomorrow", today));
    try std.testing.expectEqualStrings("2026-11-13", try normalizeDate(&date, "fri", today));
    try std.testing.expectEqualStrings("2026-11-10", try normalizeDate(&date, "2026-11-10", today));
}
