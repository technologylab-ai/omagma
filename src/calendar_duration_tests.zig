const std = @import("std");
const time = @import("terminal/calendar_time.zig");
const timezone = @import("terminal/timezone.zig");
const invitation = @import("terminal/calendar_invitation.zig");
const provider = @import("terminal/calendar_provider.zig");
const plan = @import("terminal/calendar_plan.zig");
const j = @import("terminal/json.zig");

fn end(raw: []const u8, duration: []const u8, binding: ?time.Binding) !time.Point {
    return time.durationEnd(try time.parse(raw, ";TZID=Europe/Vienna"), try time.parseDuration(duration), binding, false);
}

test "calendar duration: nominal days and weeks preserve wall time across both DST changes" {
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const binding: time.Binding = .{ .id = "Europe/Vienna", .zone = &zone };
    const spring_start = try time.resolve(try time.parse("20260328T120000", ";TZID=Europe/Vienna"), binding, false);
    const spring_end = try end("20260328T120000", "P1D", binding);
    try std.testing.expectEqual(@as(i64, 23 * 3600000), spring_end.value - spring_start.value);
    try std.testing.expectEqual(try time.rfc3339("2026-03-29T10:00:00Z"), spring_end.value);
    const autumn_start = try time.resolve(try time.parse("20261024T120000", ";TZID=Europe/Vienna"), binding, false);
    const autumn_end = try end("20261024T120000", "P1D", binding);
    try std.testing.expectEqual(@as(i64, 25 * 3600000), autumn_end.value - autumn_start.value);
    try std.testing.expectEqual(try time.rfc3339("2026-10-25T11:00:00Z"), autumn_end.value);
    const week_start = try time.resolve(try time.parse("20260322T120000", ";TZID=Europe/Vienna"), binding, false);
    try std.testing.expectEqual(@as(i64, 167 * 3600000), (try end("20260322T120000", "P1W", binding)).value - week_start.value);
    // Days are resolved before adding accurate hour/minute/second components.
    try std.testing.expectEqual(try time.rfc3339("2026-03-29T12:30:15Z"), (try end("20260328T120000", "P1DT2H30M15S", binding)).value);
}

test "calendar duration: UTC elapsed and all-day values keep their distinct semantics" {
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const binding: time.Binding = .{ .id = "Europe/Vienna", .zone = &zone };
    const local_start = try time.resolve(try time.parse("20260328T120000", ";TZID=Europe/Vienna"), binding, false);
    try std.testing.expectEqual(@as(i64, 24 * 3600000), (try end("20260328T120000", "PT24H", binding)).value - local_start.value);
    const utc_stamp = try time.parse("20260328T120000Z", "");
    const utc_start = try time.resolve(utc_stamp, null, false);
    const utc_end = try time.durationEnd(utc_stamp, try time.parseDuration("P1D"), null, false);
    try std.testing.expectEqual(@as(i64, 24 * 3600000), utc_end.value - utc_start.value);
    try std.testing.expectEqualStrings("UTC", utc_end.zone);
    const day_stamp = try time.parse("20261024", ";VALUE=DATE");
    const day_start = try time.resolve(day_stamp, null, false);
    const day_end = try time.durationEnd(day_stamp, try time.parseDuration("P1W"), null, false);
    try std.testing.expectEqual(.date, day_end.kind);
    try std.testing.expectEqual(@as(i64, 7), day_end.value - day_start.value);
    try std.testing.expectError(error.InvalidCalendarDuration, time.durationEnd(day_stamp, try time.parseDuration("PT1H"), null, false));
}

test "calendar duration: derived gaps folds floating consent and range bounds remain explicit" {
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    var binding: time.Binding = .{ .id = "Europe/Vienna", .zone = &zone };
    try std.testing.expectError(error.NonexistentLocalTime, end("20260328T023000", "P1D", binding));
    try std.testing.expectError(error.AmbiguousLocalTime, end("20261024T023000", "P1D", binding));
    const floating = try time.parse("20260328T120000", "");
    try std.testing.expectError(error.FloatingTimezoneRequired, time.durationEnd(floating, try time.parseDuration("P1D"), binding, false));
    binding.accept_floating = true;
    try std.testing.expectEqual(try time.rfc3339("2026-03-29T10:00:00Z"), (try time.durationEnd(floating, try time.parseDuration("P1D"), binding, false)).value);
    try std.testing.expectError(error.CalendarTimezoneRequired, end("20260328T120000", "P1D", null));
    try std.testing.expectError(error.EmbeddedTimezoneUnresolved, time.durationEnd(try time.parse("20260328T120000", ";TZID=Europe/Vienna"), try time.parseDuration("P1D"), binding, true));
    try std.testing.expectError(error.InvalidCalendarDuration, time.parseDuration("P36601D"));
    try std.testing.expectError(error.InvalidCalendarDuration, time.durationEnd(floating, .{ .days = 36601 }, binding, false));
    try std.testing.expectError(error.InvalidCalendarTime, time.durationEnd(try time.parse("99991231T120000Z", ""), try time.parseDuration("P1D"), null, false));
    try std.testing.expectError(error.InvalidCalendarTime, time.durationEnd(try time.parse("99991231T235959Z", ""), try time.parseDuration("PT1S"), null, false));
}

test "calendar duration: parsed invitation import resolves derived end in the original start zone" {
    const raw = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n" ++
        "UID:duration@example.test\r\nDTSTAMP:20260320T090000Z\r\nSEQUENCE:1\r\n" ++
        "ORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\n" ++
        "DTSTART;TZID=Europe/Vienna:20260328T120000\r\nDURATION:P1D\r\n" ++
        "SUMMARY:Local calendar day\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try invitation.parse(a, raw, "self@example.test", &.{});
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const binding: time.Binding = .{ .id = "Europe/Vienna", .zone = &zone };
    const unrelated_zone: timezone.Zone = .{};
    const span = try invitation.resolveSpan(source, binding, .{ .id = "UTC", .zone = &unrelated_zone });
    try std.testing.expectEqual(@as(i64, 23 * 3600000), span.end.value - span.start.value);
    try std.testing.expectEqualStrings("Europe/Vienna", span.end.zone);
    const intent: plan.Intent = .{ .operation_id = "duration-import", .identity = .{ .target = .{ .account = source.account, .calendar_id = source.account }, .uid = source.uid }, .version = source.version, .kind = .import_event, .source_hash = source.source_hash, .payload_hash = @splat(0) };
    const request = try provider.prepareImport(a, source, intent, binding, null);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    try std.testing.expectEqualStrings("2026-03-29T10:00:00.000Z", j.text(j.get(body, "end").?, "dateTime"));
    try std.testing.expectEqualStrings("Europe/Vienna", j.text(j.get(body, "end").?, "timeZone"));
    var zero = source;
    zero.duration = try time.parseDuration("PT0S");
    try std.testing.expectError(error.CalendarEndRequiresReview, invitation.resolveSpan(zero, binding, null));
}
