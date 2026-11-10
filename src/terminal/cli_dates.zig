//! Relative civil dates for agent requests: today, tomorrow, yesterday, +Nd,
//! -Nd and weekday names. They resolve once, in the zone the command itself
//! uses for its civil date, and replies echo resolvedDate, so the exact civil
//! date that was used stays reviewable. Strict YYYY-MM-DD is unchanged.
//!
//! Zones: reminder.set uses the local zone (its due dates are local civil
//! days). calendar.agenda/calendar.freebusy resolve inside the Calendar
//! command, in the request timeZone, else the selected calendar's zone, else
//! the local zone — the same zone that turns the date into a window.
//!
//! Weekday names: for a calendar view a weekday equal to today means today
//! (the view starts on that day). For reminder.set a weekday equal to today
//! means the NEXT occurrence, one week ahead: a follow-up "on friday" set on
//! a Friday is for next Friday; use "today" for today.
const std = @import("std");
const j = @import("json.zig");
const timezone = @import("timezone.zig");
const weekdays = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
/// Fields whose civil date accepts relative forms.
pub const Field = struct { cmd: []const u8, field: []const u8 };
pub const fields = [_]Field{
    .{ .cmd = "calendar.agenda", .field = "date" },
    .{ .cmd = "calendar.freebusy", .field = "date" },
    .{ .cmd = "reminder.set", .field = "dueDate" },
};
pub fn field(command: []const u8) ?[]const u8 {
    for (fields) |entry| if (std.mem.eql(u8, entry.cmd, command)) return entry.field;
    return null;
}
/// Fields resolved by the executor before dispatch. Calendar dates resolve
/// in the Calendar command, which alone knows the selected calendar's zone.
pub fn preDispatch(command: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, command, "reminder.set")) return "dueDate";
    return null;
}
/// How a weekday name equal to today resolves.
pub const Weekday = enum { today_included, next_occurrence };
pub fn weekdayRule(command: []const u8) Weekday {
    return if (std.mem.eql(u8, command, "reminder.set")) .next_occurrence else .today_included;
}
/// Day offset from today for a relative form, or null for any other text.
pub fn offsetWith(text: []const u8, current_day: i64, rule: Weekday) ?i64 {
    if (std.ascii.eqlIgnoreCase(text, "today")) return 0;
    if (std.ascii.eqlIgnoreCase(text, "tomorrow")) return 1;
    if (std.ascii.eqlIgnoreCase(text, "yesterday")) return -1;
    if (text.len >= 3 and text.len <= 5 and (text[0] == '+' or text[0] == '-') and (text[text.len - 1] == 'd' or text[text.len - 1] == 'D')) {
        const days = std.fmt.parseInt(i64, text[1 .. text.len - 1], 10) catch return null;
        if (days > 366) return null;
        return if (text[0] == '-') -days else days;
    }
    const current: usize = @intCast(@mod(current_day + 4, 7)); // 1970-01-01 was a Thursday.
    for (weekdays, 0..) |name, index| if (std.ascii.eqlIgnoreCase(text, name) or (text.len == 3 and std.ascii.eqlIgnoreCase(text, name[0..3]))) {
        const ahead: i64 = @intCast((index + 7 - current) % 7);
        return if (ahead == 0 and rule == .next_occurrence) 7 else ahead;
    };
    return null;
}
pub fn offset(text: []const u8, current_day: i64) ?i64 {
    return offsetWith(text, current_day, .today_included);
}
pub fn relative(text: []const u8) bool {
    return offset(text, 0) != null;
}
/// YYYY-MM-DD for a relative form, evaluated against today's local day number.
pub fn resolveWith(a: std.mem.Allocator, text: []const u8, current_day: i64, rule: Weekday) !?[]const u8 {
    const days = offsetWith(text, current_day, rule) orelse return null;
    return try @import("follow_up.zig").dateForDay(a, current_day + days);
}
pub fn resolve(a: std.mem.Allocator, text: []const u8, current_day: i64) !?[]const u8 {
    return resolveWith(a, text, current_day, .today_included);
}
/// Today's civil day in the request's timeZone, else the local zone, else UTC.
pub fn today(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, request: j.Value, now_ms: i64) i64 {
    const named = j.text(request, "timeZone");
    var zone = (if (named.len != 0) timezone.loadNamed(io, a, environ, named) else timezone.load(io, a, environ)) catch timezone.Zone{};
    return zone.localDay(now_ms) catch @divFloor(now_ms, 86400000);
}

test "relative dates: keywords, offsets and weekday names resolve to strict civil dates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2026-11-10 is a Tuesday (day 20767 since the epoch).
    const day: i64 = 20767;
    try std.testing.expectEqualStrings("2026-11-10", (try resolve(a, "today", day)).?);
    try std.testing.expectEqualStrings("2026-11-11", (try resolve(a, "Tomorrow", day)).?);
    try std.testing.expectEqualStrings("2026-11-13", (try resolve(a, "+3d", day)).?);
    try std.testing.expectEqualStrings("2026-11-09", (try resolve(a, "-1d", day)).?);
    try std.testing.expectEqualStrings("2026-11-10", (try resolve(a, "tuesday", day)).?);
    try std.testing.expectEqualStrings("2026-11-16", (try resolve(a, "monday", day)).?);
    try std.testing.expectEqualStrings("2026-11-13", (try resolve(a, "fri", day)).?);
    for ([_][]const u8{ "2026-11-10", "next week", "+400d", "+d", "someday" }) |text| try std.testing.expect(try resolve(a, text, day) == null);
}
test "relative dates: a reminder on today's weekday means next week, today stays reachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tuesday: i64 = 20767; // 2026-11-10
    const rule = weekdayRule("reminder.set");
    try std.testing.expectEqual(Weekday.next_occurrence, rule);
    try std.testing.expectEqualStrings("2026-11-17", (try resolveWith(a, "tuesday", tuesday, rule)).?);
    try std.testing.expectEqualStrings("2026-11-17", (try resolveWith(a, "Tue", tuesday, rule)).?);
    try std.testing.expectEqualStrings("2026-11-10", (try resolveWith(a, "today", tuesday, rule)).?);
    try std.testing.expectEqualStrings("2026-11-11", (try resolveWith(a, "wednesday", tuesday, rule)).?);
    // A calendar view of "tuesday" on a Tuesday shows today.
    try std.testing.expectEqualStrings("2026-11-10", (try resolveWith(a, "tuesday", tuesday, weekdayRule("calendar.agenda"))).?);
    try std.testing.expect(preDispatch("calendar.agenda") == null and preDispatch("calendar.freebusy") == null);
    try std.testing.expectEqualStrings("dueDate", preDispatch("reminder.set").?);
}
