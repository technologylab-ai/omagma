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

/// A literal one-type TZif file with a POSIX footer keeps zone loading
/// independent of host tzdata.
fn writeZone(a: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, offset_seconds: u32, name: []const u8, footer: []const u8) !void {
    var header: [44]u8 = @splat(0);
    @memcpy(header[0..5], "TZif2");
    std.mem.writeInt(u32, header[36..40], 1, .big);
    std.mem.writeInt(u32, header[40..44], @intCast(name.len + 1), .big);
    var offset: [4]u8 = undefined;
    std.mem.writeInt(u32, &offset, offset_seconds, .big);
    const record = try std.mem.concat(a, u8, &.{ &offset, "\x00\x00", name, "\x00" });
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = try std.mem.concat(a, u8, &.{ &header, record, &header, record, "\n", footer, "\n" }) });
}

test "calendar embedded: verdict separates rules it cannot read from rules which disagree" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try fixture(a);
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const start = try t.time.rfc3339("2026-10-13T08:00:00Z");
    try std.testing.expectEqual(embedded.Verdict.match, embedded.verdict(source.unfolded, "Europe/Vienna", &zone, start, start + 3600000));
    // A zero-length event is one provable instant; a reversed one is not.
    try std.testing.expectEqual(embedded.Verdict.match, embedded.verdict(source.unfolded, "Europe/Vienna", &zone, start, start));
    try std.testing.expect(embedded.matches(source.unfolded, "Europe/Vienna", &zone, start, start));
    try std.testing.expectEqual(embedded.Verdict.mismatch, embedded.verdict(source.unfolded, "Europe/Vienna", &zone, start, start - 1));
    inline for (.{
        .{ "TZOFFSETTO:+0200", "TZOFFSETTO:+0300", embedded.Verdict.mismatch },
        .{ "BYMONTH=10;BYDAY=-1SU", "BYMONTH=10;BYDAY=2SU", embedded.Verdict.mismatch },
        .{ "TZOFFSETFROM:+0100", "TZOFFSETFROM:+01", embedded.Verdict.mismatch },
        .{ "BYMONTH=3;BYDAY=-1SU", "BYMONTH=3;BYDAY=-1SU;BYSETPOS=1", embedded.Verdict.unsupported },
        .{ "TZNAME:CEST", "X-COMMENT:1\nBEGIN:X-NESTED\nEND:X-NESTED", embedded.Verdict.unsupported },
        .{ "TZID:Europe/Vienna", "TZID:Europe/Elsewhere", embedded.Verdict.unsupported },
    }) |case| {
        const changed = try std.mem.replaceOwned(u8, a, source.unfolded, case[0], case[1]);
        try std.testing.expectEqual(case[2], embedded.verdict(changed, "Europe/Vienna", &zone, start, start + 3600000));
        // Only a match is ever evidence for a write.
        try std.testing.expect(!embedded.matches(changed, "Europe/Vienna", &zone, start, start + 3600000));
    }
}

test "calendar embedded: display resolves Windows names, vendor prefixes, unreadable rules and a separate end zone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDir(std.testing.io, "Europe", .default_dir);
    try tmp.dir.createDir(std.testing.io, "Asia", .default_dir);
    try writeZone(a, tmp.dir, "Europe/Vienna", 3600, "CET", "CET-1CEST,M3.5.0/2,M10.5.0/3");
    try writeZone(a, tmp.dir, "Europe/Berlin", 3600, "CET", "CET-1CEST,M3.5.0/2,M10.5.0/3");
    try writeZone(a, tmp.dir, "Asia/Tokyo", 32400, "JST", "JST-9");
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("TZDIR", try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    const mail = @import("terminal/invitation.zig");
    const local = try timezone.Zone.fromPosix("UTC0");
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/terminal/calendar/embedded-europe.ics", a, .limited(t.Limits.source_bytes));
    const zone_start = std.mem.indexOf(u8, raw, "BEGIN:VTIMEZONE").?;
    const zone_end = std.mem.indexOf(u8, raw, "BEGIN:VEVENT").?;
    const bare = try std.mem.concat(a, u8, &.{ raw[0..zone_start], raw[zone_end..] });
    const Case = struct { source: []const u8, from: []const u8 = "", to: []const u8 = "", start: []const u8, end: []const u8 = "2026-10-13 09:00 UTC", unavailable: bool = false, duration: []const u8 = "1 hour" };
    const literal = "2026-10-13 10:00 (Europe/Vienna)";
    const cases = [_]Case{
        // Proved embedded rules, as before.
        .{ .source = raw, .start = "2026-10-13 08:00 UTC" },
        // No embedded rules: a Windows name or vendor path names the zone.
        .{ .source = bare, .from = "TZID=Europe/Vienna", .to = "TZID=\"W. Europe Standard Time\"", .start = "2026-10-13 08:00 UTC" },
        .{ .source = bare, .from = "TZID=Europe/Vienna", .to = "TZID=/freeassociation.sourceforge.net/Tzfile/Europe/Vienna", .start = "2026-10-13 08:00 UTC" },
        .{ .source = bare, .from = "TZID=Europe/Vienna", .to = "TZID=/mozilla.org/20070129_1/Europe/Berlin", .start = "2026-10-13 08:00 UTC" },
        // Rules this reader cannot interpret leave the stated IANA zone.
        .{ .source = raw, .from = "BYMONTH=3;BYDAY=-1SU", .to = "BYMONTH=3;BYDAY=-1SU;BYSETPOS=1", .start = "2026-10-13 08:00 UTC" },
        .{ .source = raw, .from = "TZID:Europe/Vienna", .to = "TZID:Europe/Elsewhere", .start = "2026-10-13 08:00 UTC" },
        // Rules which contradict the system zone are never overridden.
        .{ .source = raw, .from = "TZOFFSETTO:+0200", .to = "TZOFFSETTO:+0300", .start = literal, .end = "2026-10-13 11:00 (Europe/Vienna)", .unavailable = true },
        // A zero-length event is still proved and converted.
        .{ .source = raw, .from = "DTEND;TZID=Europe/Vienna:20261013T110000", .to = "DTEND;TZID=Europe/Vienna:20261013T100000", .start = "2026-10-13 08:00 UTC", .end = "2026-10-13 08:00 UTC", .duration = "0 min" },
        // DTEND in another zone is resolved with its own TZID.
        .{ .source = bare, .from = "DTEND;TZID=Europe/Vienna:20261013T110000", .to = "DTEND;TZID=Asia/Tokyo:20261013T180000", .start = "2026-10-13 08:00 UTC" },
    };
    for (cases) |case| {
        const changed = if (case.from.len == 0) case.source else try std.mem.replaceOwned(u8, a, case.source, case.from, case.to);
        try std.testing.expect(case.from.len == 0 or !std.mem.eql(u8, changed, case.source));
        var invite: mail.Invitation = .{};
        try mail.parseDisplay(changed, "self@example.test", &.{}, &invite);
        try std.testing.expectEqual(@as(u16, 0), invite.defects);
        const display = try mail.friendlyNative(std.testing.io, a, &env, &invite, &local);
        try std.testing.expectEqualStrings(case.start, display.start);
        try std.testing.expectEqualStrings(case.end, display.end);
        try std.testing.expectEqual(case.unavailable, display.timezone_unavailable);
        if (!case.unavailable) try std.testing.expectEqualStrings(case.duration, display.duration);
    }
    // A Windows name with rules this reader cannot interpret has neither a
    // sender-stated IANA zone nor a proof: it stays as sent.
    const renamed = try std.mem.replaceOwned(u8, a, raw, "Europe/Vienna", "W. Europe Standard Time");
    const unreadable = try std.mem.replaceOwned(u8, a, renamed, "BYMONTH=3;BYDAY=-1SU", "BYMONTH=3;BYDAY=-1SU;BYSETPOS=1");
    var invite: mail.Invitation = .{};
    try mail.parseDisplay(unreadable, "self@example.test", &.{}, &invite);
    const unresolved = try mail.friendlyNative(std.testing.io, a, &env, &invite, &local);
    try std.testing.expect(unresolved.timezone_unavailable);
    try std.testing.expectEqualStrings("2026-10-13 10:00 (W. Europe Standard Time)", unresolved.start);
    // With readable rules the mapped candidate is proved and used.
    try mail.parseDisplay(renamed, "self@example.test", &.{}, &invite);
    const proved = try mail.friendlyNative(std.testing.io, a, &env, &invite, &local);
    try std.testing.expect(!proved.timezone_unavailable);
    try std.testing.expectEqualStrings("2026-10-13 08:00 UTC", proved.start);
    try std.testing.expectEqualStrings("2026-10-13 10:00 W. Europe Standard Time", proved.original_start);
}
