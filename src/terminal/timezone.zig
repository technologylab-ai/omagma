//! Linux display-time snapshot, independent of linked libc and process globals.
//! TZif transitions/footer: RFC 9636. Gmail/cache epochs remain POSIX UTC.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const max_file_bytes = 128 * 1024;
const max_transitions = 4096;
const max_seconds = 253402300799;
const Name = struct {
    bytes: [32]u8 = @splat(0),
    len: u8 = 0,
    fn init(raw: []const u8) !Name {
        if (raw.len == 0 or raw.len > 32) return error.InvalidTimezoneName;
        for (raw) |byte| if (byte < 33 or byte > 126) return error.InvalidTimezoneName;
        var name: Name = .{};
        @memcpy(name.bytes[0..raw.len], raw);
        name.len = @intCast(raw.len);
        return name;
    }
    fn value(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};
const Offset = struct { seconds: i32, name: Name };
const Rule = struct {
    kind: enum { month, julian, julian_no_leap },
    day: u16 = 0,
    month: u8 = 0,
    week: u8 = 0,
    weekday: u8 = 0,
    seconds: i32 = 7200,
    basis: enum { wall, standard, utc } = .wall,
    fn instant(self: Rule, year: i64, wall_offset: i32, standard_offset: i32) i64 {
        const ordinal: i64 = switch (self.kind) {
            .julian => self.day,
            .julian_no_leap => @as(i64, self.day) - 1 + @as(i64, if (leap(year) and self.day >= 60) 1 else 0),
            .month => blk: {
                const first = civilDays(year, self.month, 1);
                const first_weekday = @mod(first + 4, 7);
                var day = 1 + @mod(@as(i64, self.weekday) - first_weekday, 7) + (@as(i64, self.week) - 1) * 7;
                const length = monthDays(year, self.month);
                if (day > length) day -= 7;
                break :blk civilDays(year, self.month, @intCast(day)) - civilDays(year, 1, 1);
            },
        };
        const offset = switch (self.basis) {
            .wall => wall_offset,
            .standard => standard_offset,
            .utc => 0,
        };
        return (civilDays(year, 1, 1) + ordinal) * 86400 + self.seconds - offset;
    }
};
const Posix = struct {
    standard: Offset,
    daylight: ?Offset = null,
    start: ?Rule = null,
    end: ?Rule = null,
    fn at(self: *const Posix, seconds: i64) !Offset {
        const daylight = self.daylight orelse return self.standard;
        if (seconds < -62135596800 or seconds > max_seconds) return error.TimezoneRangeUnavailable;
        const year = civilDate(@divFloor(seconds, 86400)).year;
        var latest: i64 = std.math.minInt(i64);
        var dst = false;
        // Rule times/offsets can cross a year boundary. Choose the latest
        // actual transition, rather than assuming the UTC year is local year.
        // Both year-end rules may roll into January (signed times allow167h),
        // so the last preceding pair can belong to two nominal years ago.
        for ([_]i64{ year - 2, year - 1, year, year + 1 }) |candidate| {
            const start = self.start.?.instant(candidate, self.standard.seconds, self.standard.seconds);
            const end = self.end.?.instant(candidate, daylight.seconds, self.standard.seconds);
            if (start <= seconds and start >= latest) {
                latest = start;
                dst = true;
            }
            if (end <= seconds and end > latest) {
                latest = end;
                dst = false;
            }
        }
        return if (dst) daylight else self.standard;
    }
};
const Parser = struct {
    input: []const u8,
    at: usize = 0,
    fn peek(self: *const Parser) u8 {
        return if (self.at < self.input.len) self.input[self.at] else 0;
    }
    fn take(self: *Parser, wanted: u8) !void {
        if (self.peek() != wanted) return error.InvalidPosixTimezone;
        self.at += 1;
    }
    fn number(self: *Parser, maximum: u16) !u16 {
        const start = self.at;
        var value: u32 = 0;
        while (std.ascii.isDigit(self.peek())) {
            value = value * 10 + self.peek() - '0';
            if (value > maximum) return error.InvalidPosixTimezone;
            self.at += 1;
        }
        if (self.at == start) return error.InvalidPosixTimezone;
        return @intCast(value);
    }
    fn name(self: *Parser) !Name {
        const quoted = self.peek() == '<';
        if (quoted) self.at += 1;
        const start = self.at;
        while (std.ascii.isAlphabetic(self.peek()) or (quoted and (std.ascii.isDigit(self.peek()) or self.peek() == '+' or self.peek() == '-'))) self.at += 1;
        const result = try Name.init(self.input[start..self.at]);
        if (result.len < 3) return error.InvalidPosixTimezone;
        if (quoted) try self.take('>');
        return result;
    }
    fn clock(self: *Parser, maximum_hour: u16) !i32 {
        var sign: i32 = 1;
        if (self.peek() == '-' or self.peek() == '+') {
            if (self.peek() == '-') sign = -1;
            self.at += 1;
        }
        const hours = try self.number(maximum_hour);
        var minutes: u16 = 0;
        var seconds: u16 = 0;
        if (self.peek() == ':') {
            self.at += 1;
            minutes = try self.number(59);
            if (self.peek() == ':') {
                self.at += 1;
                seconds = try self.number(59);
            }
        }
        return sign * (@as(i32, hours) * 3600 + @as(i32, minutes) * 60 + seconds);
    }
    fn rule(self: *Parser) !Rule {
        var result: Rule = undefined;
        if (self.peek() == 'M') {
            self.at += 1;
            const month = try self.number(12);
            try self.take('.');
            const week = try self.number(5);
            try self.take('.');
            const weekday = try self.number(6);
            if (month == 0 or week == 0) return error.InvalidPosixTimezone;
            result = .{ .kind = .month, .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday) };
        } else if (self.peek() == 'J') {
            self.at += 1;
            const day = try self.number(365);
            if (day == 0) return error.InvalidPosixTimezone;
            result = .{ .kind = .julian_no_leap, .day = day };
        } else result = .{ .kind = .julian, .day = try self.number(365) };
        if (self.peek() == '/') {
            self.at += 1;
            result.seconds = try self.clock(167);
            result.basis = switch (self.peek()) {
                's' => .standard,
                'u', 'g', 'z' => .utc,
                'w' => .wall,
                else => return result,
            };
            self.at += 1;
        }
        return result;
    }
};
fn posix(raw: []const u8) !Posix {
    if (raw.len == 0 or raw.len > 512 or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPosixTimezone;
    var parser: Parser = .{ .input = raw };
    const standard_name = try parser.name();
    var result: Posix = .{ .standard = .{ .seconds = -(try parser.clock(24)), .name = standard_name } };
    if (parser.at == raw.len) return result;
    const daylight_name = try parser.name();
    const daylight_seconds = if (parser.peek() == ',') result.standard.seconds + 3600 else -(try parser.clock(24));
    result.daylight = .{ .seconds = daylight_seconds, .name = daylight_name };
    // A bare DST designation has implementation-specific default rules. A
    // matching IANA file is preferred by load(); otherwise refuse to guess.
    try parser.take(',');
    result.start = try parser.rule();
    try parser.take(',');
    result.end = try parser.rule();
    if (parser.at != raw.len) return error.InvalidPosixTimezone;
    return result;
}
const Header = struct {
    version: u8,
    transitions: usize,
    types: usize,
    names: usize,
    standard: usize,
    universal: usize,
    fn parse(bytes: []const u8) !Header {
        if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "TZif")) return error.InvalidTimezoneFile;
        if (bytes[4] != 0 and bytes[4] != '2' and bytes[4] != '3' and bytes[4] != '4') return error.UnsupportedTimezoneVersion;
        for (bytes[5..20]) |reserved| if (reserved != 0) return error.InvalidTimezoneFile;
        const result: Header = .{ .version = bytes[4], .transitions = be32(bytes[32..36]), .types = be32(bytes[36..40]), .names = be32(bytes[40..44]), .standard = be32(bytes[24..28]), .universal = be32(bytes[20..24]) };
        if (be32(bytes[28..32]) != 0) return error.LeapTimezoneUnsupported;
        if (result.transitions > max_transitions or result.types == 0 or result.types > 256 or result.names == 0 or result.names > 8192) return error.TimezoneFileTooLarge;
        if ((result.standard != 0 and result.standard != result.types) or (result.universal != 0 and result.universal != result.types)) return error.InvalidTimezoneFile;
        return result;
    }
    fn size(self: Header, width: usize) usize {
        return self.transitions * (width + 1) + self.types * 6 + self.names + self.standard + self.universal;
    }
};
fn be32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}
const Table = struct {
    width: usize = 8,
    times: []const u8 = &.{},
    indices: []const u8 = &.{},
    records: []const u8 = &.{},
    names: []const u8 = &.{},
    footer: ?Posix = null,
    fn instant(self: *const Table, index: usize) i64 {
        const raw = self.times[index * self.width ..];
        return if (self.width == 8) std.mem.readInt(i64, raw[0..8], .big) else std.mem.readInt(i32, raw[0..4], .big);
    }
    fn offset(self: *const Table, index: usize) !Offset {
        const record = self.records[index * 6 ..][0..6];
        const start = record[5];
        if (start >= self.names.len) return error.InvalidTimezoneFile;
        const length = std.mem.indexOfScalar(u8, self.names[start..], 0) orelse return error.InvalidTimezoneFile;
        const name = try Name.init(self.names[start..][0..length]);
        if (std.mem.eql(u8, name.value(), "-00")) return error.TimezoneRangeUnavailable;
        return .{ .seconds = std.mem.readInt(i32, record[0..4], .big), .name = name };
    }
    fn at(self: *const Table, seconds: i64) !Offset {
        if (self.indices.len == 0) return if (self.footer) |*footer| footer.at(seconds) else self.offset(0);
        if (seconds >= self.instant(self.indices.len - 1)) {
            if (self.footer) |*footer| return footer.at(seconds);
            return error.TimezoneRangeUnavailable;
        }
        var low: usize = 0;
        var high = self.indices.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.instant(middle) <= seconds) low = middle + 1 else high = middle;
        }
        return self.offset(if (low == 0) 0 else self.indices[low - 1]);
    }
};
pub const Zone = struct {
    owned: ?[]u8 = null,
    table: ?Table = null,
    rules: ?Posix = null,
    unavailable: bool = false,
    pub fn deinit(self: *Zone, allocator: Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
        self.* = .{};
    }
    pub fn fromPosix(raw: []const u8) !Zone {
        return .{ .rules = try posix(raw) };
    }
    pub fn parse(allocator: Allocator, raw: []const u8) !Zone {
        if (raw.len > max_file_bytes) return error.TimezoneFileTooLarge;
        const bytes = try allocator.dupe(u8, raw);
        errdefer allocator.free(bytes);
        return parseOwned(bytes);
    }
    fn parseOwned(bytes: []u8) !Zone {
        const first = try Header.parse(bytes);
        const first_end = 44 + first.size(4);
        if (first_end > bytes.len) return error.InvalidTimezoneFile;
        const width: usize = if (first.version == 0) 4 else 8;
        const header = if (width == 4) first else try Header.parse(bytes[first_end..]);
        if (header.version != first.version) return error.InvalidTimezoneFile;
        const start = if (width == 4) 44 else first_end + 44;
        const end = start + header.size(width);
        if (end > bytes.len) return error.InvalidTimezoneFile;
        const times_end = start + header.transitions * width;
        const indices_end = times_end + header.transitions;
        const records_end = indices_end + header.types * 6;
        var table: Table = .{ .width = width, .times = bytes[start..times_end], .indices = bytes[times_end..indices_end], .records = bytes[indices_end..records_end], .names = bytes[records_end..][0..header.names] };
        for (table.indices, 0..) |index, i| {
            if (index >= header.types or (i > 0 and table.instant(i) <= table.instant(i - 1))) return error.InvalidTimezoneFile;
        }
        for (0..header.types) |index| {
            const record = table.records[index * 6 ..][0..6];
            const gmtoff = std.mem.readInt(i32, record[0..4], .big);
            if (gmtoff < -89999 or gmtoff > 93599 or record[4] > 1) return error.InvalidTimezoneFile;
            _ = table.offset(index) catch |err| {
                if (err == error.TimezoneRangeUnavailable) continue;
                return err;
            };
        }
        for (bytes[records_end + header.names .. end]) |indicator| if (indicator > 1) return error.InvalidTimezoneFile;
        if (width == 4) {
            if (end != bytes.len) return error.InvalidTimezoneFile;
        } else {
            const tail = bytes[end..];
            if (tail.len < 2 or tail[0] != '\n' or tail[tail.len - 1] != '\n') return error.InvalidTimezoneFile;
            if (tail.len > 2) table.footer = try posix(tail[1 .. tail.len - 1]);
        }
        return .{ .owned = bytes, .table = table };
    }
    fn offset(self: *const Zone, seconds: i64) !Offset {
        if (self.unavailable) return error.TimezoneUnavailable;
        const resolved = if (self.table) |*table|
            try table.at(seconds)
        else if (self.rules) |*rules|
            try rules.at(seconds)
        else
            Offset{ .seconds = 0, .name = try Name.init("UTC") };
        // RFC9636's unspecified designation also applies when selected by a
        // POSIX footer (notably the installed Factory zone), not only ttinfo.
        if (std.mem.eql(u8, resolved.name.value(), "-00")) return error.TimezoneRangeUnavailable;
        return resolved;
    }
    pub fn format(self: *const Zone, allocator: Allocator, milliseconds: i64) ![]const u8 {
        if (milliseconds <= 0 or milliseconds > max_seconds * 1000 + 999) return "";
        const seconds = @divTrunc(milliseconds, 1000);
        var fallback = false;
        var resolved = self.offset(seconds) catch blk: {
            fallback = true;
            break :blk Offset{ .seconds = 0, .name = try Name.init("UTC") };
        };
        var local = seconds + resolved.seconds;
        var date = civilDate(@divFloor(local, 86400));
        if (date.year < 1 or date.year > 9999) {
            fallback = true;
            resolved = .{ .seconds = 0, .name = try Name.init("UTC") };
            local = seconds;
            date = civilDate(@divFloor(local, 86400));
        }
        const day_seconds = @mod(local, 86400);
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {s}{s}", .{ @as(u16, @intCast(date.year)), date.month, date.day, @as(u8, @intCast(@divTrunc(day_seconds, 3600))), @as(u8, @intCast(@divTrunc(@mod(day_seconds, 3600), 60))), resolved.name.value(), if (fallback) " (TZ unavailable)" else "" });
    }
};
pub fn load(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map) !Zone {
    const selected = environ.get("TZ") orelse return loadFile(io, allocator, "/etc/localtime");
    if (selected.len == 0) return .{}; // POSIX explicitly empty TZ means UTC.
    const value = if (selected[0] == ':') selected[1..] else selected;
    if (value.len == 0 or value.len > 4096 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidTimezoneName;
    if (value[0] == '/') return loadFile(io, allocator, value);
    if (zoneIdentifier(value)) {
        const directory = environ.get("TZDIR") orelse "/usr/share/zoneinfo";
        if (directory.len == 0 or directory[0] != '/' or directory.len > 4096) return error.InvalidTimezoneDirectory;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, value });
        defer allocator.free(path);
        return loadFile(io, allocator, path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => Zone.fromPosix(value),
            else => return err,
        };
    }
    return Zone.fromPosix(value);
}
fn zoneIdentifier(raw: []const u8) bool {
    if (raw.len == 0) return false;
    for (raw) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '/' and byte != '_' and byte != '-' and byte != '+' and byte != '.') return false;
    var parts = std.mem.splitScalar(u8, raw, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn loadFile(io: Io, allocator: Allocator, path: []const u8) !Zone {
    if (path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidTimezoneName;
    const name = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(name);
    // /etc/localtime and IANA aliases are normally symlinks. Follow them, but
    // open nonblocking and validate that same descriptor before reading.
    const linux = std.os.linux;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true };
    const fd: std.posix.fd_t = while (true) {
        const raw = linux.openat(Io.Dir.cwd().handle, name, flags, 0);
        switch (linux.errno(raw)) {
            .SUCCESS => break @intCast(raw),
            .INTR => try io.checkCancel(),
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            else => return error.TimezoneOpenFailed,
        }
    };
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularTimezoneFile;
    if (stat.size > max_file_bytes) return error.TimezoneFileTooLarge;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(max_file_bytes));
    errdefer allocator.free(bytes);
    return Zone.parseOwned(bytes);
}
const Date = struct { year: i64, month: u8, day: u8 };
fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}
fn monthDays(year: i64, month: u8) i64 {
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return lengths[month - 1] + @as(i64, if (month == 2 and leap(year)) 1 else 0);
}
fn civilDays(year: i64, month: u8, day: u8) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const shifted = @as(i64, month) + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * shifted + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}
fn civilDate(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + @as(i64, if (mp < 10) 3 else -9);
    return .{ .year = y + @as(i64, if (month <= 2) 1 else 0), .month = @intCast(month), .day = @intCast(day) };
}

fn expectStamp(zone: *const Zone, milliseconds: i64, expected: []const u8) !void {
    const rendered = try zone.format(std.testing.allocator, milliseconds);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}
test "timezone: POSIX DST transitions use the message instant and future footer rules" {
    const zone = try Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    try expectStamp(&zone, 1794054840000, "2026-11-07 13:34 CET");
    try expectStamp(&zone, 1780835640000, "2026-06-07 14:34 CEST");
    try expectStamp(&zone, 1774745999000, "2026-03-29 01:59 CET");
    try expectStamp(&zone, 1774746000000, "2026-03-29 03:00 CEST");
    try expectStamp(&zone, 1792889999000, "2026-10-25 02:59 CEST");
    try expectStamp(&zone, 1792890000000, "2026-10-25 02:00 CET");
    try expectStamp(&zone, 2525860800000, "2050-01-15 13:00 CET");
    try expectStamp(&zone, 2538907200000, "2050-06-15 14:00 CEST");
}
test "timezone: fractional offsets signs and local date rollover are literal expectations" {
    const east = try Zone.fromPosix("<+0545>-5:45");
    try expectStamp(&east, 1780835640000, "2026-06-07 18:19 +0545");
    const west = try Zone.fromPosix("EST5");
    try expectStamp(&west, 1000, "1969-12-31 19:00 EST");
    const utc = try Zone.fromPosix("UTC0");
    try expectStamp(&utc, 1794054840000, "2026-11-07 12:34 UTC");
    try std.testing.expectEqualStrings("", try utc.format(std.testing.allocator, -1));
    try std.testing.expectEqualStrings("", try utc.format(std.testing.allocator, 253402300800000));
    const edge = try Zone.fromPosix("EAST-1");
    try expectStamp(&edge, 253402300799999, "9999-12-31 23:59 UTC (TZ unavailable)");
}
test "timezone: southern and negative DST and leap day rules stay per instant" {
    const south = try Zone.fromPosix("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try expectStamp(&south, 1767268800000, "2026-01-01 23:00 AEDT");
    try expectStamp(&south, 1782907200000, "2026-07-01 22:00 AEST");
    const ireland = try Zone.fromPosix("IST-1GMT0,M10.5.0,M3.5.0/1");
    try expectStamp(&ireland, 1794054840000, "2026-11-07 12:34 GMT");
    try expectStamp(&ireland, 1780835640000, "2026-06-07 13:34 IST");
    const no_leap: Rule = .{ .kind = .julian_no_leap, .day = 60, .seconds = 0 };
    try std.testing.expectEqual(@as(i64, 1709251200), no_leap.instant(2024, 0, 0)); // March1
    const ordinal: Rule = .{ .kind = .julian, .day = 59, .seconds = 0 };
    try std.testing.expectEqual(@as(i64, 1709164800), ordinal.instant(2024, 0, 0)); // February29
    const rolled = try Zone.fromPosix("STD0DST,J365/167,J365/166");
    try expectStamp(&rolled, 1767268800000, "2026-01-01 13:00 DST");
}
test "timezone: malformed POSIX data and unsupported implicit DST do not guess" {
    for ([_][]const u8{ "Bad/Zone", "XX0", "UTC25", "CET-1CEST", "ABC0DEF,M0.1.0,M11.1.0", "ABC0DEF,M3.1.7,M11.1.0", "ABC0DEF,M3.1.0/168,M11.1.0", "ABC0DEF,M3.1.0,M11.1.0,trailing" }) |raw| {
        const parsed = Zone.fromPosix(raw);
        try std.testing.expect(std.meta.isError(parsed));
    }
    const unavailable: Zone = .{ .unavailable = true };
    try expectStamp(&unavailable, 1794054840000, "2026-11-07 12:34 UTC (TZ unavailable)");
    try std.testing.expect(!zoneIdentifier("../Europe/Vienna"));
    try std.testing.expect(!zoneIdentifier("Europe//Vienna"));
    try std.testing.expect(zoneIdentifier("America/Argentina/Buenos_Aires"));
}

const wire_header = "TZif\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x03\x00\x00\x00\x02\x00\x00\x00\x09";
const wire32 = "\xff\xff\xff\xff\x00\x00\x00\x00\x01\x02\x03\x04";
const wire64 = "\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x00\x01\x02\x03\x04";
const wire_types = "\x00\x01\x00" ++ "\x00\x00\x0e\x10\x00\x00\x00\x00\x1c\x20\x01\x04" ++ "CET\x00CEST\x00";
test "timezone: literal TZif wire signed transitions type zero and exact tail refusal" {
    var zone = try Zone.parse(std.testing.allocator, wire_header ++ wire32 ++ wire_types);
    defer zone.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 3600), (try zone.offset(-2)).seconds);
    try std.testing.expectEqual(@as(i32, 3600), (try zone.offset(-1)).seconds);
    try std.testing.expectEqual(@as(i32, 7200), (try zone.offset(0)).seconds);
    try std.testing.expectEqual(@as(i32, 7200), (try zone.offset(16909059)).seconds);
    try std.testing.expectError(error.TimezoneRangeUnavailable, zone.offset(16909060));
    try expectStamp(&zone, 16909060000, "1970-07-15 16:57 UTC (TZ unavailable)");
}
test "timezone: literal TZif64 uses future footer and owns one bounded snapshot" {
    var second = wire_header.*;
    second[4] = '3';
    const raw = try std.mem.concat(std.testing.allocator, u8, &.{ &second, wire32, wire_types, &second, wire64, wire_types, "\nCET-1CEST,M3.5.0,M10.5.0/3\n" });
    defer std.testing.allocator.free(raw);
    var zone = try Zone.parse(std.testing.allocator, raw);
    defer zone.deinit(std.testing.allocator);
    @memset(raw, 0); // Parser indices borrow its owned duplicate, not input.
    try expectStamp(&zone, 2525860800000, "2050-01-15 13:00 CET");
    try expectStamp(&zone, 2538907200000, "2050-06-15 14:00 CEST");
    try std.testing.expect(zone.owned.?.len <= max_file_bytes);
}
test "timezone: TZif count ordering designation and leap-clock refusals are bounded" {
    const allocator = std.testing.allocator;
    const raw = try allocator.dupe(u8, wire_header ++ wire32 ++ wire_types);
    defer allocator.free(raw);
    raw[35] = 255;
    try std.testing.expectError(error.InvalidTimezoneFile, Zone.parse(allocator, raw));
    @memcpy(raw, wire_header ++ wire32 ++ wire_types);
    raw[31] = 1;
    try std.testing.expectError(error.LeapTimezoneUnsupported, Zone.parse(allocator, raw));
    @memcpy(raw, wire_header ++ wire32 ++ wire_types);
    raw[56] = 2;
    try std.testing.expectError(error.InvalidTimezoneFile, Zone.parse(allocator, raw));
    @memcpy(raw, wire_header ++ wire32 ++ wire_types);
    @memcpy(raw[48..52], raw[44..48]);
    try std.testing.expectError(error.InvalidTimezoneFile, Zone.parse(allocator, raw));
    for (0..raw.len) |length| {
        try std.testing.expect(std.meta.isError(Zone.parse(allocator, raw[0..length])));
    }
}

test "timezone: unspecified POSIX and Factory footer zones explicitly fall back" {
    const rules = try Zone.fromPosix("<-00>0");
    try std.testing.expectError(error.TimezoneRangeUnavailable, rules.offset(1794054840));
    try expectStamp(&rules, 1794054840000, "2026-11-07 12:34 UTC (TZ unavailable)");
    // Literal v2 zero-transition file: one type and the unspecified name.
    const header = "TZif2\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x04";
    const record = "\x00\x00\x00\x00\x00\x00-00\x00";
    var zone = try Zone.parse(std.testing.allocator, header ++ record ++ header ++ record ++ "\n<-00>0\n");
    defer zone.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), zone.table.?.indices.len);
    try expectStamp(&zone, 1794054840000, "2026-11-07 12:34 UTC (TZ unavailable)");
}
