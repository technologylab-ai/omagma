const std = @import("std");
const embedded = @import("terminal/calendar_embedded.zig");
const invitation = @import("terminal/calendar_invitation.zig");
const t = @import("terminal/calendar_types.zig");
const timezone = @import("terminal/timezone.zig");

test {
    std.testing.refAllDecls(embedded);
}
fn fixture(a: std.mem.Allocator) !t.Invitation {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/terminal/calendar/embedded-europe.ics", a, .limited(t.Limits.source_bytes));
    return invitation.parse(a, raw, "self@example.test", &.{});
}
fn matches(raw: []const u8, zone: *const timezone.Zone, start: []const u8, end: []const u8) !bool {
    return embedded.matches(raw, "Europe/Vienna", zone, try t.time.rfc3339(start), try t.time.rfc3339(end));
}

test "calendar embedded: common annual rules agree across both real transition boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try fixture(arena.allocator());
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    try std.testing.expect(try matches(source.unfolded, &zone, "2026-10-13T08:00:00Z", "2026-10-13T09:00:00Z"));
    const crlf = try std.mem.replaceOwned(u8, arena.allocator(), source.unfolded, "\n", "\r\n");
    try std.testing.expect(try matches(crlf, &zone, "2026-10-13T08:00:00Z", "2026-10-13T09:00:00Z"));
    try std.testing.expect(try matches(source.unfolded, &zone, "2026-03-28T08:00:00Z", "2026-03-30T08:00:00Z"));
    try std.testing.expect(try matches(source.unfolded, &zone, "2026-10-24T08:00:00Z", "2026-10-26T08:00:00Z"));
    try std.testing.expect(!embedded.matches(source.unfolded, "Europe/Paris", &zone, try t.time.rfc3339("2026-10-13T08:00:00Z"), try t.time.rfc3339("2026-10-13T09:00:00Z")));
}

test "calendar embedded: matching endpoint offsets do not hide different internal transitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try fixture(a);
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const earlier = try std.mem.replaceOwned(u8, a, source.unfolded, "BYMONTH=3;BYDAY=-1SU", "BYMONTH=3;BYDAY=-2SU");
    try std.testing.expect(!try matches(earlier, &zone, "2026-03-01T08:00:00Z", "2026-04-01T08:00:00Z"));
    // The reverse comparison proves that IANA-only discontinuities are also
    // visited, rather than checking just the embedded transition set.
    const earlier_zone = try timezone.Zone.fromPosix("CET-1CEST,M3.3.0/2,M10.5.0/3");
    try std.testing.expect(!try matches(source.unfolded, &earlier_zone, "2026-03-01T08:00:00Z", "2026-04-01T08:00:00Z"));
    const wrong_offset = try std.mem.replaceOwned(u8, a, source.unfolded, "TZOFFSETTO:+0200", "TZOFFSETTO:+0300");
    try std.testing.expect(!try matches(wrong_offset, &zone, "2026-10-13T08:00:00Z", "2026-10-13T09:00:00Z"));
}

test "calendar embedded: unsupported duplicate or oversized rules require review" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try fixture(a);
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const unsupported = try std.mem.replaceOwned(u8, a, source.unfolded, "BYDAY=-1SU", "BYDAY=-1SU;COUNT=100");
    try std.testing.expect(!try matches(unsupported, &zone, "2026-10-13T08:00:00Z", "2026-10-13T09:00:00Z"));
    const duplicate = try std.mem.concat(a, u8, &.{ source.unfolded, source.unfolded });
    try std.testing.expect(!try matches(duplicate, &zone, "2026-10-13T08:00:00Z", "2026-10-13T09:00:00Z"));
    try std.testing.expect(!try matches(source.unfolded, &zone, "2026-01-01T00:00:00Z", "2028-01-01T00:00:00Z"));
}

test "calendar embedded: matching rules never choose a DST gap or fold for the user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try fixture(a);
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const binding: t.time.Binding = .{ .id = "Europe/Vienna", .zone = &zone, .embedded_rules_verified = true };
    var changed = source;
    changed.start = try t.time.parse("20260329T023000", ";TZID=Europe/Vienna");
    try std.testing.expectError(error.NonexistentLocalTime, invitation.resolveSpan(changed, binding, binding));
    changed.start = try t.time.parse("20261025T023000", ";TZID=Europe/Vienna");
    try std.testing.expectError(error.AmbiguousLocalTime, invitation.resolveSpan(changed, binding, binding));
    changed.start = try t.time.parse("20261024", ";VALUE=DATE");
    changed.end = try t.time.parse("20261026", ";VALUE=DATE");
    const span = try invitation.resolveSpan(changed, null, null);
    try std.testing.expectEqual(.date, span.start.kind);
    try std.testing.expectEqual(@as(i64, 2), span.end.value - span.start.value);
}

const exchange_examples = [_]struct { file: []const u8, id: []const u8, posix: []const u8, spring: []const u8, autumn: []const u8 }{
    .{ .file = "exchange-europe-1601.ics", .id = "W. Europe Standard Time", .posix = "CET-1CEST,M3.5.0/2,M10.5.0/3", .spring = "2026-03-29T00:00:00Z", .autumn = "2026-10-25T00:00:00Z" },
    .{ .file = "exchange-gmt-1601.ics", .id = "GMT Standard Time", .posix = "GMT0BST,M3.5.0/1,M10.5.0/2", .spring = "2026-03-29T00:00:00Z", .autumn = "2026-10-25T00:00:00Z" },
    .{ .file = "exchange-australia-1601.ics", .id = "AUS Eastern Standard Time", .posix = "AEST-10AEDT-11,M10.1.0/2,M4.1.0/3", .spring = "2026-10-03T00:00:00Z", .autumn = "2026-04-04T00:00:00Z" },
};
fn exchangeFixture(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/fixtures/terminal/calendar/{s}", .{name}), a, .limited(t.Limits.source_bytes));
}
test "calendar embedded: Exchange 1601 anchors prove European GMT and Australian annual DST windows" {
    std.debug.print("Exchange embedded compiler={s} optimize={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (exchange_examples) |example| {
        const raw = try exchangeFixture(a, example.file);
        const source = try invitation.parse(a, raw, "self@example.test", &.{});
        const zone = try timezone.Zone.fromPosix(example.posix);
        for ([_][]const u8{ example.spring, example.autumn, "2026-01-15T00:00:00Z", "2026-07-15T00:00:00Z" }) |date| {
            const start = try t.time.rfc3339(date);
            try std.testing.expect(embedded.matches(source.unfolded, example.id, &zone, start, start + 2 * 86400000));
            // Direct CRLF input is the mail invitation parser's storage form.
            try std.testing.expect(embedded.matches(raw, example.id, &zone, start, start + 2 * 86400000));
        }
        const mail = @import("terminal/invitation.zig");
        var invite: mail.Invitation = .{};
        try mail.parseDisplay(raw, "self@example.test", &.{}, &invite);
        var env: std.process.Environ.Map = .init(a);
        defer env.deinit();
        try env.put("TZDIR", "/nonexistent/synthetic-zoneinfo");
        const start = try zone.fromLocal(source.start.?.civil);
        const end = try zone.fromLocal(source.end.?.civil);
        const proof = embedded.matches(invite.timezones.slice(), example.id, &zone, start, end);
        try std.testing.expect(proof);
        const display = try mail.friendlyNative(std.testing.io, a, &env, &invite, &zone);
        try std.testing.expect(!display.timezone_unavailable);
        try std.testing.expect(std.mem.indexOf(u8, display.original_start, example.id) != null);
    }
}

test "calendar embedded: Exchange anchors do not hide wrong rules or contradictory recent onsets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try exchangeFixture(a, exchange_examples[0].file);
    const zone = try timezone.Zone.fromPosix(exchange_examples[0].posix);
    const start = try t.time.rfc3339("2026-03-01T00:00:00Z");
    const end = try t.time.rfc3339("2026-04-01T00:00:00Z");
    const wrong = try std.mem.replaceOwned(u8, a, raw, "BYMONTH=3;BYDAY=-1SU", "BYMONTH=3;BYDAY=-2SU");
    try std.testing.expect(!embedded.matches(wrong, exchange_examples[0].id, &zone, start, end));
    const recent = try std.mem.replaceOwned(u8, a, raw, "16010101", "20260101");
    try std.testing.expect(!embedded.matches(recent, exchange_examples[0].id, &zone, start, end));
    const unsupported = try std.mem.replaceOwned(u8, a, raw, "INTERVAL=1", "INTERVAL=2");
    try std.testing.expect(!embedded.matches(unsupported, exchange_examples[0].id, &zone, start, end));
}

test "calendar embedded: Exchange verified annual rules still refuse European and Australian gaps and folds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { index: usize, gap: []const u8, fold: []const u8 }{
        .{ .index = 0, .gap = "20260329T023000", .fold = "20261025T023000" },
        .{ .index = 1, .gap = "20260329T013000", .fold = "20261025T013000" },
        .{ .index = 2, .gap = "20261004T023000", .fold = "20260405T023000" },
    }) |example| {
        const named = exchange_examples[example.index];
        const source = try invitation.parse(a, try exchangeFixture(a, named.file), "self@example.test", &.{});
        const zone = try timezone.Zone.fromPosix(named.posix);
        const binding: t.time.Binding = .{ .id = "Synthetic/Verified", .zone = &zone, .embedded_rules_verified = true };
        var changed = source;
        changed.start = try t.time.parse(example.gap, try std.fmt.allocPrint(a, ";TZID={s}", .{named.id}));
        try std.testing.expectError(error.NonexistentLocalTime, invitation.resolveSpan(changed, binding, binding));
        changed.start = try t.time.parse(example.fold, try std.fmt.allocPrint(a, ";TZID={s}", .{named.id}));
        try std.testing.expectError(error.AmbiguousLocalTime, invitation.resolveSpan(changed, binding, binding));
    }
}
