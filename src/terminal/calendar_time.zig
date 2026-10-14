//! Calendar time semantics. DATE values are civil dates, never UTC midnight.
//! Conversion remains explicit when a source is floating or embeds VTIMEZONE.
const std = @import("std");
const timezone = @import("timezone.zig");
pub const Stamp = struct {
    raw: []const u8,
    parameters: []const u8,
    civil: timezone.CivilTime,
    kind: enum { date, utc, floating, zoned },
    zone: []const u8 = "",
};
pub const Point = struct {
    kind: enum { date, instant },
    /// Days since epoch for DATE, milliseconds since epoch for an instant.
    value: i64,
    zone: []const u8 = "",

    pub fn eql(self: Point, other: Point) bool {
        return self.kind == other.kind and self.value == other.value;
    }
};
pub const Duration = struct { days: u32 = 0, seconds: u32 = 0 };
pub const Binding = struct {
    id: []const u8,
    zone: *const timezone.Zone,
    /// The UI must disclose that selecting a zone fixes a floating wall time.
    accept_floating: bool = false,
    /// A resolver verified source VTIMEZONE rules, or the user reviewed an
    /// explicit reinterpretation. An IANA-looking TZID alone is not evidence.
    embedded_rules_verified: bool = false,
};

pub fn parse(raw: []const u8, parameters: []const u8) !Stamp {
    const value_type = try parameter(parameters, "VALUE");
    const zone = (try parameter(parameters, "TZID")) orelse "";
    const date = raw.len == 8;
    if (date) {
        if (zone.len != 0 or value_type == null or !std.ascii.eqlIgnoreCase(value_type.?, "DATE")) return error.InvalidCalendarTime;
    } else {
        if ((raw.len != 15 and raw.len != 16) or raw[8] != 'T' or (raw.len == 16 and raw[15] != 'Z')) return error.InvalidCalendarTime;
        if (value_type) |value| if (!std.ascii.eqlIgnoreCase(value, "DATE-TIME")) return error.InvalidCalendarTime;
        if (raw.len == 16 and zone.len != 0) return error.InvalidCalendarTime;
    }
    for (raw, 0..) |byte, index| if ((date or (index != 8 and index != 15)) and !std.ascii.isDigit(byte)) return error.InvalidCalendarTime;
    const civil: timezone.CivilTime = .{
        .year = try number(u16, raw[0..4]),
        .month = try number(u8, raw[4..6]),
        .day = try number(u8, raw[6..8]),
        .hour = if (date) 0 else try number(u8, raw[9..11]),
        .minute = if (date) 0 else try number(u8, raw[11..13]),
        .second = if (date) 0 else try number(u8, raw[13..15]),
    };
    _ = civil.seconds() catch return error.InvalidCalendarTime;
    if (zone.len > 512) return error.InvalidCalendarTime;
    return .{ .raw = raw, .parameters = parameters, .civil = civil, .kind = if (date) .date else if (raw.len == 16) .utc else if (zone.len != 0) .zoned else .floating, .zone = zone };
}

pub fn resolve(stamp: Stamp, binding: ?Binding, has_timezones: bool) !Point {
    switch (stamp.kind) {
        .date => return .{ .kind = .date, .value = @divExact(try stamp.civil.seconds(), 86400) },
        .utc => return .{ .kind = .instant, .value = (try stamp.civil.seconds()) * 1000, .zone = "UTC" },
        .floating, .zoned => {
            const resolved = binding orelse return error.CalendarTimezoneRequired;
            try validateZoneName(resolved.id);
            if (stamp.kind == .floating and !resolved.accept_floating) return error.FloatingTimezoneRequired;
            if (stamp.kind == .zoned and !std.mem.eql(u8, stamp.zone, resolved.id) and !resolved.embedded_rules_verified) return error.CalendarTimezoneMismatch;
            if (stamp.kind == .zoned and has_timezones and !resolved.embedded_rules_verified) return error.EmbeddedTimezoneUnresolved;
            // Strict first-slice conversion deliberately refuses fold/gap
            // choices. A later RFC5545 resolver may implement first/pre-gap
            // selection without changing strict compose-time validation.
            return .{ .kind = .instant, .value = try resolved.zone.fromLocal(stamp.civil), .zone = resolved.id };
        },
    }
}

pub fn parseDuration(raw: []const u8) !Duration {
    var position: usize = if (std.mem.startsWith(u8, raw, "+")) 1 else 0;
    if (position >= raw.len or raw[position] != 'P') return error.InvalidCalendarDuration;
    position += 1;
    var result: Duration = .{};
    var in_time = false;
    var rank: u8 = 0;
    var parts: usize = 0;
    while (position < raw.len) {
        if (raw[position] == 'T') {
            if (in_time or position + 1 == raw.len) return error.InvalidCalendarDuration;
            in_time = true;
            position += 1;
            continue;
        }
        const start = position;
        while (position < raw.len and std.ascii.isDigit(raw[position])) position += 1;
        if (position == start or position == raw.len) return error.InvalidCalendarDuration;
        const amount = std.fmt.parseInt(u32, raw[start..position], 10) catch return error.InvalidCalendarDuration;
        const unit = raw[position];
        position += 1;
        const next_rank: u8 = switch (unit) {
            'W' => if (!in_time and parts == 0 and position == raw.len) 1 else return error.InvalidCalendarDuration,
            'D' => if (!in_time) 2 else return error.InvalidCalendarDuration,
            'H' => if (in_time) 3 else return error.InvalidCalendarDuration,
            'M' => if (in_time) 4 else return error.InvalidCalendarDuration,
            'S' => if (in_time) 5 else return error.InvalidCalendarDuration,
            else => return error.InvalidCalendarDuration,
        };
        if (next_rank <= rank) return error.InvalidCalendarDuration;
        rank = next_rank;
        const factor: u32 = switch (unit) {
            'W' => 7,
            'H' => 3600,
            'M' => 60,
            else => 1,
        };
        const value = std.math.mul(u32, amount, factor) catch return error.InvalidCalendarDuration;
        if (unit == 'W' or unit == 'D') result.days = value else result.seconds = std.math.add(u32, result.seconds, value) catch return error.InvalidCalendarDuration;
        parts += 1;
    }
    if (parts == 0 or result.days > 36600 or result.seconds > 36600 * 86400) return error.InvalidCalendarDuration;
    return result;
}

/// RFC 5545 duration arithmetic adds nominal days in the original wall clock
/// before accurate hours/minutes/seconds. P1D can therefore span 23 or 25 hours.
/// Derived wall-clock endpoints retain the same strict gap/fold handling as
/// DTSTART, and never acquire an unrelated DTEND timezone binding.
pub fn durationEnd(stamp: Stamp, duration: Duration, binding: ?Binding, has_timezones: bool) !Point {
    if (duration.days > 36600 or duration.seconds > 36600 * 86400 or (stamp.kind == .date and duration.seconds != 0)) return error.InvalidCalendarDuration;
    var nominal = try resolve(stamp, binding, has_timezones);
    if (duration.days != 0) {
        var end_stamp = stamp;
        const first_day = @divFloor(try stamp.civil.seconds(), 86400);
        end_stamp.civil = try dateFromDays(first_day + duration.days);
        end_stamp.civil.hour = stamp.civil.hour;
        end_stamp.civil.minute = stamp.civil.minute;
        end_stamp.civil.second = stamp.civil.second;
        nominal = try resolve(end_stamp, binding, has_timezones);
    }
    if (nominal.kind == .instant) nominal.value += @as(i64, duration.seconds) * 1000;
    _ = try dateFromDays(if (nominal.kind == .date) nominal.value else @divFloor(nominal.value, 86400000));
    return nominal;
}

/// Parse provider RFC3339 instants. An explicit offset is mandatory: never
/// inherit the machine timezone from a server response. Milliseconds survive.
pub fn rfc3339(raw: []const u8) !i64 {
    if (raw.len < 20 or raw.len > 40 or raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or raw[13] != ':' or raw[16] != ':') return error.InvalidCalendarTime;
    const date = timezone.parseDate(raw[0..10]) catch return error.InvalidCalendarTime;
    var civil = date;
    civil.hour = try number(u8, raw[11..13]);
    civil.minute = try number(u8, raw[14..16]);
    civil.second = try number(u8, raw[17..19]);
    const seconds = civil.seconds() catch return error.InvalidCalendarTime;
    var pos: usize = 19;
    var millis: i64 = 0;
    if (raw[pos] == '.') {
        pos += 1;
        const start = pos;
        while (pos < raw.len and std.ascii.isDigit(raw[pos])) : (pos += 1) {
            if (pos - start < 3) millis = millis * 10 + raw[pos] - '0';
        }
        if (pos == start) return error.InvalidCalendarTime;
        var digits = pos - start;
        while (digits < 3) : (digits += 1) millis *= 10;
    }
    var offset: i64 = 0;
    if (pos < raw.len and raw[pos] == 'Z' and pos + 1 == raw.len) {} else {
        if (pos + 6 != raw.len or (raw[pos] != '+' and raw[pos] != '-') or raw[pos + 3] != ':') return error.InvalidCalendarTime;
        const hours = try number(u8, raw[pos + 1 .. pos + 3]);
        const minutes = try number(u8, raw[pos + 4 .. pos + 6]);
        if (hours > 23 or minutes > 59) return error.InvalidCalendarTime;
        offset = (@as(i64, hours) * 3600 + @as(i64, minutes) * 60) * (if (raw[pos] == '-') @as(i64, -1) else 1);
    }
    return (seconds - offset) * 1000 + millis;
}

pub fn validateZoneName(value: []const u8) !void {
    if (value.len == 0 or value.len > 512 or value[0] == '/' or std.mem.indexOf(u8, value, "..") != null) return error.InvalidTimezoneName;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '/' and byte != '_' and byte != '-' and byte != '+' and byte != '.') return error.InvalidTimezoneName;
}

pub fn format(a: std.mem.Allocator, point: Point) ![]const u8 {
    const days = if (point.kind == .date) point.value else @divFloor(point.value, 86400000);
    const civil = try dateFromDays(days);
    if (point.kind == .date) return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ civil.year, civil.month, civil.day });
    const seconds = @divFloor(@mod(point.value, 86400000), 1000);
    const hour: u8 = @intCast(@divFloor(seconds, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(seconds, 3600), 60));
    const second: u8 = @intCast(@mod(seconds, 60));
    const millis: u16 = @intCast(@mod(point.value, 1000));
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ civil.year, civil.month, civil.day, hour, minute, second, millis });
}

fn dateFromDays(days: i64) !timezone.CivilTime {
    if (days < -719162 or days > 2932896) return error.InvalidCalendarTime;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + @as(i64, if (mp < 10) 3 else -9);
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

pub fn parameter(parameters: []const u8, wanted: []const u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos < parameters.len) {
        if (parameters[pos] != ';') return error.InvalidCalendarParameter;
        pos += 1;
        const start = pos;
        while (pos < parameters.len and parameters[pos] != '=') : (pos += 1) if (parameters[pos] == ';') return error.InvalidCalendarParameter;
        if (pos == start or pos == parameters.len) return error.InvalidCalendarParameter;
        const name = parameters[start..pos];
        pos += 1;
        var value_start = pos;
        var value_end = pos;
        if (pos < parameters.len and parameters[pos] == '"') {
            pos += 1;
            value_start = pos;
            while (pos < parameters.len and parameters[pos] != '"') : (pos += 1) {}
            if (pos == parameters.len) return error.InvalidCalendarParameter;
            value_end = pos;
            pos += 1;
            if (pos < parameters.len and parameters[pos] != ';') return error.InvalidCalendarParameter;
        } else {
            while (pos < parameters.len and parameters[pos] != ';') : (pos += 1) {}
            value_end = pos;
        }
        if (std.ascii.eqlIgnoreCase(name, wanted)) {
            if (result != null or value_start == value_end) return error.InvalidCalendarParameter;
            result = parameters[value_start..value_end];
        }
    }
    return result;
}

fn number(comptime T: type, raw: []const u8) !T {
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidCalendarTime;
    return std.fmt.parseInt(T, raw, 10) catch return error.InvalidCalendarTime;
}

test "calendar: RFC3339 fractional offset instants and date types remain distinct" {
    try std.testing.expectEqual(try rfc3339("2026-10-13T07:15:00Z"), try rfc3339("2026-10-13T13:00:00+05:45"));
    try std.testing.expectEqual(@as(i64, 125), try rfc3339("1970-01-01T00:00:00.125Z"));
    try std.testing.expectError(error.InvalidCalendarTime, rfc3339("2026-10-13T10:00:00"));
    const day = try resolve(try parse("20261013", ";VALUE=DATE"), null, false);
    try std.testing.expectEqual(.date, day.kind);
    try std.testing.expectError(error.InvalidCalendarTime, parse("20261013T080000Z", ";TZID=Europe/Vienna"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "1970-01-01T00:00:00.000Z", "1969-12-31T23:59:59.999Z", "2026-10-13T14:00:00.000Z", "2000-02-29T01:02:03.004Z", "0001-01-01T00:00:00.000Z", "9999-12-31T23:59:59.999Z" }) |input| {
        const rendered = try format(arena.allocator(), .{ .kind = .instant, .value = try rfc3339(input) });
        try std.testing.expectEqualStrings(input, rendered);
    }
}

test "calendar: timezone conversion requires floating and embedded decisions and refuses DST guesses" {
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const binding: Binding = .{ .id = "Europe/Vienna", .zone = &zone };
    try std.testing.expectError(error.FloatingTimezoneRequired, resolve(try parse("20261013T100000", ""), binding, false));
    try std.testing.expectError(error.EmbeddedTimezoneUnresolved, resolve(try parse("20261013T100000", ";TZID=Europe/Vienna"), binding, true));
    try std.testing.expectError(error.NonexistentLocalTime, resolve(try parse("20260329T023000", ";TZID=Europe/Vienna"), binding, false));
    try std.testing.expectError(error.AmbiguousLocalTime, resolve(try parse("20261025T023000", ";TZID=Europe/Vienna"), binding, false));
    const nominal = try parseDuration("P1D");
    const elapsed = try parseDuration("PT24H");
    try std.testing.expectEqual(@as(u32, 1), nominal.days);
    try std.testing.expectEqual(@as(u32, 0), nominal.seconds);
    try std.testing.expectEqual(@as(u32, 0), elapsed.days);
    try std.testing.expectEqual(@as(u32, 86400), elapsed.seconds);
}
