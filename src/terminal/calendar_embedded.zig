//! Bounded equivalence proof for common embedded VTIMEZONE observances.
//! This does not expand event recurrences or guess a timezone from its name.
//! Compare every discontinuity of both offset functions around the event;
//! unsupported rules require the existing explicit reinterpretation review.
const std = @import("std");
const t = @import("calendar_types.zig");
const timezone = @import("timezone.zig");

const max_observances = 16;
const max_dates = 16;
const Rule = struct { month: u8, ordinal: i8 = 0, weekday: u8 = 0, month_day: i8 = 0, until: ?i64 = null };
const Observance = struct {
    start: timezone.CivilTime,
    from: i32,
    to: i32,
    rule: ?Rule = null,
    dates: [max_dates]timezone.CivilTime = undefined,
    dates_len: usize = 0,
};
const Transition = struct { at: i64, from: i32, to: i32 };
const Transitions = struct {
    items: [512]Transition = undefined,
    len: usize = 0,
    fn add(self: *Transitions, value: Transition) !void {
        for (self.items[0..self.len]) |previous| if (previous.at == value.at) {
            if (previous.from != value.from or previous.to != value.to) return error.AmbiguousEmbeddedTimezone;
            return;
        };
        if (self.len == self.items.len) return error.EmbeddedTimezoneTooLarge;
        self.items[self.len] = value;
        self.len += 1;
    }
    fn at(self: *const Transitions, seconds: i64) !i32 {
        var selected: ?Transition = null;
        for (self.items[0..self.len]) |value| if (value.at <= seconds and (selected == null or value.at > selected.?.at)) {
            selected = value;
        };
        return (selected orelse return error.EmbeddedTimezoneRangeUnavailable).to;
    }
};

/// source is the parser's complete unfolded source. A proof covers the event
/// plus three days either side, so different nearby gap/fold behavior cannot be
/// hidden by an endpoint-only offset match. Larger intervals stay review-only.
pub fn matches(source: []const u8, id: []const u8, zone: *const timezone.Zone, start_ms: i64, end_ms: i64) bool {
    return prove(source, id, zone, start_ms, end_ms) catch false;
}
fn prove(source: []const u8, id: []const u8, zone: *const timezone.Zone, start_ms: i64, end_ms: i64) !bool {
    if (start_ms < -62072524800000 or end_ms > 253339228799000) return false;
    if (source.len > t.Limits.source_bytes or end_ms <= start_ms or end_ms - start_ms > 366 * 86400000) return false;
    const first = @divFloor(start_ms, 1000) - 3 * 86400;
    const last = @divFloor(end_ms, 1000) + 3 * 86400;
    // Keep all arithmetic and candidate-year generation inside CivilTime.
    if (first < -62072524800 or last > 253339228799) return false;
    const block = try findBlock(source, id) orelse return false;
    var observances: [max_observances]Observance = undefined;
    const count = try parseBlock(block, &observances);
    if (count == 0) return false;
    const first_year = yearOf(first);
    const last_year = yearOf(last);
    var transitions: Transitions = .{};
    for (observances[0..count]) |observance| {
        // Exchange uses 1601-01-01 as an RRULE anchor for both observances;
        // their dummy wall times can denote the same contradictory instant.
        // Annual instances below establish the offset before this proof's
        // window. Keep fixed onsets and nearby starts fully checked, and keep
        // expired rules' final instances through the UNTIL handling below.
        if (observance.rule == null or observance.start.year >= first_year - 1)
            try addDate(&transitions, observance.start, observance);
        for (observance.dates[0..observance.dates_len]) |date| try addDate(&transitions, date, observance);
        if (observance.rule) |rule| {
            var year: u16 = first_year - 1;
            while (year <= last_year + 1) : (year += 1) try addYear(&transitions, observance, rule, year);
            // An expired historical rule can still define the offset before a
            // later fixed observance, even when UNTIL predates this window.
            if (rule.until) |until| {
                const until_year = yearOf(until);
                if (until_year > 1 and until_year < first_year - 1) {
                    try addYear(&transitions, observance, rule, until_year - 1);
                    try addYear(&transitions, observance, rule, until_year);
                }
            }
        }
    }
    if (!try sameAt(&transitions, zone, first) or !try sameAt(&transitions, zone, last)) return false;
    for (transitions.items[0..transitions.len]) |value| if (value.at >= first and value.at <= last) {
        if (try transitions.at(value.at - 1) != value.from or !try sameAt(&transitions, zone, value.at - 1) or !try sameAt(&transitions, zone, value.at)) return false;
    };
    // TZif table transitions and its POSIX footer cover every possible IANA
    // discontinuity. Extra footer candidates within the table are harmless:
    // comparison still uses Zone.offsetSeconds, its authoritative selector.
    if (zone.table) |table| {
        for (0..table.indices.len) |index| {
            const raw = table.times[index * table.width ..];
            const instant: i64 = if (table.width == 8) std.mem.readInt(i64, raw[0..8], .big) else std.mem.readInt(i32, raw[0..4], .big);
            if (!try compareBoundary(&transitions, zone, instant, first, last)) return false;
        }
        if (table.footer) |rules| if (!try compareRules(&transitions, zone, rules, first, last, first_year, last_year)) return false;
    } else if (zone.rules) |rules| if (!try compareRules(&transitions, zone, rules, first, last, first_year, last_year)) return false;
    return true;
}
fn sameAt(transitions: *const Transitions, zone: *const timezone.Zone, instant: i64) !bool {
    return try transitions.at(instant) == try zone.offsetSeconds(instant);
}
fn compareBoundary(transitions: *const Transitions, zone: *const timezone.Zone, instant: i64, first: i64, last: i64) !bool {
    if (instant < first or instant > last) return true;
    return try sameAt(transitions, zone, instant - 1) and try sameAt(transitions, zone, instant);
}
fn compareRules(transitions: *const Transitions, zone: *const timezone.Zone, rules: anytype, first: i64, last: i64, first_year: u16, last_year: u16) !bool {
    const daylight = rules.daylight orelse return true;
    var year = first_year - 1;
    while (year <= last_year + 1) : (year += 1) {
        if (!try compareBoundary(transitions, zone, try posixInstant(rules.start.?, year, rules.standard.seconds, rules.standard.seconds), first, last)) return false;
        if (!try compareBoundary(transitions, zone, try posixInstant(rules.end.?, year, daylight.seconds, rules.standard.seconds), first, last)) return false;
    }
    return true;
}
fn posixInstant(rule: anytype, year: u16, wall_offset: i32, standard_offset: i32) !i64 {
    const base = try (timezone.CivilTime{ .year = year, .month = 1, .day = 1 }).seconds();
    const ordinal: i64 = switch (rule.kind) {
        .julian => rule.day,
        .julian_no_leap => @as(i64, rule.day) - 1 + @as(i64, if (leap(year) and rule.day >= 60) 1 else 0),
        .month => @divExact(try (timezone.CivilTime{ .year = year, .month = rule.month, .day = try nthDay(year, rule.month, if (rule.week == 5) -1 else @intCast(rule.week), rule.weekday) }).seconds() - base, 86400),
    };
    const offset: i64 = switch (rule.basis) {
        .wall => wall_offset,
        .standard => standard_offset,
        .utc => 0,
    };
    return base + ordinal * 86400 + rule.seconds - offset;
}
fn addDate(transitions: *Transitions, date: timezone.CivilTime, observance: Observance) !void {
    try transitions.add(.{ .at = try date.seconds() - observance.from, .from = observance.from, .to = observance.to });
}
fn addYear(transitions: *Transitions, observance: Observance, rule: Rule, year: u16) !void {
    if (year < observance.start.year) return;
    const length = monthDays(year, rule.month);
    const day: u8 = if (rule.ordinal != 0) nthDay(year, rule.month, rule.ordinal, rule.weekday) catch return else blk: {
        const month_date: i16 = if (rule.month_day > 0) rule.month_day else @as(i16, length) + rule.month_day + 1;
        if (month_date < 1 or month_date > length) return;
        break :blk @intCast(month_date);
    };
    var date = observance.start;
    date.year = year;
    date.month = rule.month;
    date.day = day;
    const local = try date.seconds();
    if (local < try observance.start.seconds()) return;
    const instant = local - observance.from;
    if (rule.until) |until| if (instant > until) return;
    try transitions.add(.{ .at = instant, .from = observance.from, .to = observance.to });
}

const Property = struct { name: []const u8, parameters: []const u8, value: []const u8 };
fn property(line: []const u8) !Property {
    var quoted = false;
    for (line, 0..) |byte, index| {
        if (byte == '"') quoted = !quoted;
        if (byte == ':' and !quoted) {
            const semi = std.mem.indexOfScalar(u8, line[0..index], ';') orelse index;
            return .{ .name = line[0..semi], .parameters = line[semi..index], .value = line[index + 1 ..] };
        }
    }
    return error.InvalidEmbeddedTimezone;
}
fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn findBlock(source: []const u8, id: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    var start: ?usize = null;
    var depth: usize = 0;
    var zone_id: ?[]const u8 = null;
    var found: ?[]const u8 = null;
    while (lines.next()) |raw_line| {
        const line_start = offset;
        offset = @min(source.len, offset + raw_line.len + 1);
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const value = try property(line);
        if (same(value.name, "BEGIN")) {
            if (same(value.value, "VTIMEZONE")) {
                if (start != null) return error.InvalidEmbeddedTimezone;
                start = line_start;
                zone_id = null;
                depth = 1;
            } else if (start != null) depth += 1;
        } else if (same(value.name, "END") and start != null) {
            depth -= 1;
            if (depth == 0) {
                if (zone_id) |name| if (std.mem.eql(u8, name, id)) {
                    if (found != null) return error.AmbiguousEmbeddedTimezone;
                    found = source[start.?..offset];
                };
                start = null;
            }
        } else if (start != null and depth == 1 and same(value.name, "TZID")) {
            if (zone_id != null) return error.AmbiguousEmbeddedTimezone;
            zone_id = value.value;
        }
    }
    return found;
}
fn parseBlock(block: []const u8, output: *[max_observances]Observance) !usize {
    var lines = std.mem.splitScalar(u8, block, '\n');
    var count: usize = 0;
    var current: ?Observance = null;
    var component: []const u8 = "";
    var seen: u4 = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const p = try property(line);
        if (same(p.name, "BEGIN")) {
            if (same(p.value, "VTIMEZONE")) continue;
            if (current != null or (!same(p.value, "STANDARD") and !same(p.value, "DAYLIGHT"))) return error.UnsupportedEmbeddedTimezone;
            current = .{ .start = undefined, .from = 0, .to = 0 };
            component = p.value;
            seen = 0;
        } else if (same(p.name, "END")) {
            if (same(p.value, "VTIMEZONE")) continue;
            if (current == null or !same(p.value, component) or seen & 7 != 7 or count == output.len) return error.InvalidEmbeddedTimezone;
            output[count] = current.?;
            count += 1;
            current = null;
        } else if (current) |*value| {
            if (same(p.name, "DTSTART")) {
                try unique(&seen, 1);
                value.start = try localDate(p.value, p.parameters);
            } else if (same(p.name, "TZOFFSETFROM")) {
                try unique(&seen, 2);
                value.from = try parseOffset(p.value);
            } else if (same(p.name, "TZOFFSETTO")) {
                try unique(&seen, 4);
                value.to = try parseOffset(p.value);
            } else if (same(p.name, "RRULE")) {
                try unique(&seen, 8);
                value.rule = try parseRule(p.value);
            } else if (same(p.name, "RDATE")) {
                var dates = std.mem.splitScalar(u8, p.value, ',');
                while (dates.next()) |date| {
                    if (value.dates_len == value.dates.len) return error.EmbeddedTimezoneTooLarge;
                    value.dates[value.dates_len] = try localDate(date, p.parameters);
                    value.dates_len += 1;
                }
            } else if (!same(p.name, "TZNAME") and !same(p.name, "COMMENT") and !std.ascii.startsWithIgnoreCase(p.name, "X-")) return error.UnsupportedEmbeddedTimezone;
        } else if (!same(p.name, "TZID") and !same(p.name, "LAST-MODIFIED") and !same(p.name, "TZURL") and !std.ascii.startsWithIgnoreCase(p.name, "X-")) return error.UnsupportedEmbeddedTimezone;
    }
    if (current != null) return error.InvalidEmbeddedTimezone;
    return count;
}
fn unique(seen: *u4, bit: u4) !void {
    if (seen.* & bit != 0) return error.AmbiguousEmbeddedTimezone;
    seen.* |= bit;
}
fn localDate(raw: []const u8, parameters: []const u8) !timezone.CivilTime {
    const stamp = try t.time.parse(raw, parameters);
    if (stamp.kind != .floating) return error.InvalidEmbeddedTimezone;
    return stamp.civil;
}
fn parseOffset(raw: []const u8) !i32 {
    if ((raw.len != 5 and raw.len != 7) or (raw[0] != '+' and raw[0] != '-')) return error.InvalidEmbeddedTimezone;
    const hours = try number(u8, raw[1..3]);
    const minutes = try number(u8, raw[3..5]);
    const seconds = if (raw.len == 7) try number(u8, raw[5..7]) else 0;
    if (hours > 23 or minutes > 59 or seconds > 59) return error.InvalidEmbeddedTimezone;
    const value = @as(i32, hours) * 3600 + @as(i32, minutes) * 60 + seconds;
    if (raw[0] == '-' and value == 0) return error.InvalidEmbeddedTimezone;
    return if (raw[0] == '-') -value else value;
}
fn parseRule(raw: []const u8) !Rule {
    var result: Rule = .{ .month = 0 };
    var frequency = false;
    var parts = std.mem.splitScalar(u8, raw, ';');
    var seen: u16 = 0;
    while (parts.next()) |part| {
        const equal = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidEmbeddedTimezone;
        const name = part[0..equal];
        const value = part[equal + 1 ..];
        const bit: u16 = if (same(name, "FREQ")) 1 else if (same(name, "BYMONTH")) 2 else if (same(name, "BYDAY")) 4 else if (same(name, "BYMONTHDAY")) 8 else if (same(name, "UNTIL")) 16 else if (same(name, "INTERVAL")) 32 else return error.UnsupportedEmbeddedTimezone;
        if (seen & bit != 0) return error.AmbiguousEmbeddedTimezone;
        seen |= bit;
        switch (bit) {
            1 => frequency = same(value, "YEARLY"),
            2 => result.month = try number(u8, value),
            4 => {
                if (value.len < 3 or value.len > 4) return error.UnsupportedEmbeddedTimezone;
                result.ordinal = try std.fmt.parseInt(i8, value[0 .. value.len - 2], 10);
                const name_day = value[value.len - 2 ..];
                result.weekday = for ([_][]const u8{ "SU", "MO", "TU", "WE", "TH", "FR", "SA" }, 0..) |day, index| {
                    if (same(day, name_day)) break @intCast(index);
                } else return error.InvalidEmbeddedTimezone;
                if (result.ordinal == 0 or result.ordinal < -5 or result.ordinal > 5) return error.InvalidEmbeddedTimezone;
            },
            8 => {
                result.month_day = try std.fmt.parseInt(i8, value, 10);
                if (result.month_day == 0 or result.month_day < -31 or result.month_day > 31) return error.InvalidEmbeddedTimezone;
            },
            16 => {
                const until = try t.time.parse(value, "");
                if (until.kind != .utc) return error.InvalidEmbeddedTimezone;
                result.until = try until.civil.seconds();
            },
            32 => if (!std.mem.eql(u8, value, "1")) return error.UnsupportedEmbeddedTimezone,
            else => unreachable,
        }
    }
    if (!frequency or result.month == 0 or result.month > 12 or (result.ordinal == 0) == (result.month_day == 0)) return error.UnsupportedEmbeddedTimezone;
    return result;
}
fn number(comptime T: type, raw: []const u8) !T {
    if (raw.len == 0) return error.InvalidEmbeddedTimezone;
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidEmbeddedTimezone;
    return std.fmt.parseInt(T, raw, 10);
}
fn leap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}
fn monthDays(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (leap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}
fn nthDay(year: u16, month: u8, ordinal: i8, weekday: u8) !u8 {
    const first = @divExact(try (timezone.CivilTime{ .year = year, .month = month, .day = 1 }).seconds(), 86400);
    const length = monthDays(year, month);
    const day = if (ordinal > 0) 1 + @mod(@as(i64, weekday) - @mod(first + 4, 7), 7) + (@as(i64, ordinal) - 1) * 7 else @as(i64, length) - @mod(@mod(first + length - 1 + 4, 7) - weekday, 7) + (@as(i64, ordinal) + 1) * 7;
    if (day < 1 or day > length) return error.InvalidEmbeddedTimezone;
    return @intCast(day);
}
fn yearOf(seconds: i64) u16 {
    const days = @divFloor(seconds, 86400) + 719468;
    const era = @divFloor(days, 146097);
    const doe = days - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const month = @divTrunc(5 * doy + 2, 153);
    return @intCast(yoe + era * 400 + @as(i64, if (month >= 10) 1 else 0));
}
