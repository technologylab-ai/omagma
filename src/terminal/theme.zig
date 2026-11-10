const std = @import("std");
const files = @import("files.zig");
const b = @import("../bounded.zig");

pub const Mode = enum { follow_omarchy, omagma };

pub fn name(mode: Mode) []const u8 {
    return switch (mode) {
        .follow_omarchy => "Follow Omarchy",
        .omagma => "Omagma",
    };
}

pub const Color = [3]u8;
pub const Palette = struct {
    foreground: Color = .{ 232, 235, 241 },
    background: Color = .{ 17, 22, 32 },
    muted: Color = .{ 139, 149, 171 },
    accent: Color = .{ 255, 158, 97 },
    selection: Color = .{ 57, 43, 48 },
    cyan: Color = .{ 92, 177, 255 },
    green: Color = .{ 133, 207, 149 },
    yellow: Color = .{ 255, 198, 98 },
    blue: Color = .{ 117, 156, 255 },
    magenta: Color = .{ 199, 149, 230 },
    orange: Color = .{ 255, 158, 97 },
    red: Color = .{ 255, 112, 112 },
    /// Derived roles: the bulk-selection tint, quiet unfocused pane borders
    /// (below muted text), muted text on the selection and bulk tints, the
    /// star flag and neutral label chips (foreground text on `chip`).
    /// deriveRoles keeps them at the contrast floors below.
    selection_inactive: Color = .{ 43, 48, 57 },
    border: Color = .{ 72, 79, 95 },
    selected_muted: Color = .{ 141, 151, 172 },
    star: Color = .{ 255, 198, 98 },
    chip: Color = .{ 72, 79, 95 },
    from_omarchy: bool = false,
};

/// WCAG floors for derived roles: text against the surface it sits on, the
/// star glyph, and tints that must stay visible against the background.
pub const text_floor = 4.5;
pub const star_floor = 3.0;
pub const tint_floor = 1.35;

/// WCAG relative luminance of an sRGB colour.
pub fn luminance(value: Color) f64 {
    var result: f64 = 0;
    for (value, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
        const scaled = @as(f64, @floatFromInt(channel)) / 255;
        result += (if (scaled <= 0.04045) scaled / 12.92 else std.math.pow(f64, (scaled + 0.055) / 1.055, 2.4)) * weight;
    }
    return result;
}
/// WCAG contrast ratio, 1 to 21.
pub fn contrast(left: Color, right: Color) f64 {
    const l = luminance(left);
    const r = luminance(right);
    return (@max(l, r) + 0.05) / (@min(l, r) + 0.05);
}
fn worst(value: Color, surfaces: []const Color) f64 {
    var result: f64 = 21;
    for (surfaces) |surface| result = @min(result, contrast(value, surface));
    return result;
}
/// The smallest mix of `toward` over `base`, from `start` percent, that
/// reaches `floor` against every surface; `toward` itself when none does.
fn mixUntil(base: Color, toward: Color, start: u8, surfaces: []const Color, floor: f64) Color {
    var percent = start;
    while (true) : (percent += 1) {
        const candidate = mix(base, toward, percent);
        if (percent >= 100 or worst(candidate, surfaces) >= floor) return candidate;
    }
}
/// Theme-authored colours stay as written; only derived roles move, and only
/// as far as their floor requires.
fn deriveRoles(palette: *Palette, has_selection: bool, border: ?Color) void {
    const background = palette.background;
    const foreground = palette.foreground;
    // A theme without its own selection gets a clearly visible accent tint.
    if (!has_selection) palette.selection = mixUntil(background, palette.accent, 18, &.{background}, tint_floor);
    palette.selection_inactive = mixUntil(background, foreground, 7, &.{background}, tint_floor);
    palette.border = border orelse mix(background, palette.muted, 45);
    palette.muted = mixUntil(palette.muted, foreground, 0, &.{background}, text_floor);
    palette.selected_muted = mixUntil(palette.muted, foreground, 0, &.{ palette.selection, palette.selection_inactive }, text_floor);
    const rows = [_]Color{ background, palette.selection, palette.selection_inactive };
    palette.star = for ([_]Color{ palette.yellow, palette.accent }) |candidate| {
        if (worst(candidate, &rows) >= star_floor) break candidate;
    } else foreground;
    palette.chip = mixUntil(palette.border, background, 0, &.{foreground}, text_floor);
}

/// Linear sRGB-channel mix: percent of `toward` over `base`.
pub fn mix(base: Color, toward: Color, percent: u8) Color {
    var result: Color = undefined;
    for (&result, base, toward) |*channel, from, to| channel.* = @intCast((@as(u16, from) * (100 - percent) + @as(u16, to) * percent + 50) / 100);
    return result;
}

/// The file is checked from existing UI wakeups at most once every two
/// seconds. Only a changed identity is read; idle frames never parse TOML.
pub const Watch = struct {
    const Stamp = struct { inode: std.Io.File.INode, size: u64, mtime: i96, ctime: i96 };
    path: b.Text(4096) = .{},
    previous: ?Stamp = null,
    initialized: bool = false,
    next_check_at: i64 = 0,

    pub fn configure(self: *Watch, environ: *const std.process.Environ.Map) !void {
        self.* = .{};
        var path_buffer: [4096]u8 = undefined;
        const value = if (environ.get("XDG_STATE_HOME")) |state|
            try std.fmt.bufPrint(&path_buffer, "{s}/omarchy/current/theme/colors.toml", .{state})
        else if (environ.get("HOME")) |home|
            try std.fmt.bufPrint(&path_buffer, "{s}/.local/state/omarchy/current/theme/colors.toml", .{home})
        else
            return;
        if (!std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidThemePath;
        try self.path.set(value);
    }

    pub fn changed(self: *Watch, io: std.Io, now: i64) !bool {
        if (now < self.next_check_at) return false;
        self.next_check_at = now +| 2000;
        const stamp: ?Stamp = if (self.path.len == 0) null else blk: {
            const stat = std.Io.Dir.cwd().statFile(io, self.path.slice(), .{}) catch |err| {
                if (err == error.Canceled) return err;
                break :blk null;
            };
            break :blk .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
        };
        const different = self.initialized and !std.meta.eql(stamp, self.previous);
        self.previous = stamp;
        self.initialized = true;
        return different;
    }
};

fn color(raw: []const u8) !Color {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len < 9 or value[0] != '"' or value[1] != '#' or value[8] != '"') return error.InvalidThemeColor;
    const suffix = std.mem.trimStart(u8, value[9..], " \t\r");
    if (suffix.len > 0 and suffix[0] != '#') return error.InvalidThemeColor;
    return .{ try std.fmt.parseInt(u8, value[2..4], 16), try std.fmt.parseInt(u8, value[4..6], 16), try std.fmt.parseInt(u8, value[6..8], 16) };
}

pub fn parse(bytes: []const u8) !Palette {
    if (bytes.len > 16 * 1024) return error.ThemeTooLarge;
    var palette: Palette = .{};
    var has_muted = false;
    var has_selection = false;
    var border: ?Color = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        // Omarchy's own "muted" is a border tone, distinct from dimmed text.
        if (std.mem.eql(u8, key, "muted")) {
            // Optional derived roles never invalidate an otherwise usable theme.
            border = color(line[separator + 1 ..]) catch continue;
            continue;
        }
        const target: ?*Color = if (std.mem.eql(u8, key, "foreground")) &palette.foreground else if (std.mem.eql(u8, key, "background")) &palette.background else if (std.mem.eql(u8, key, "dark_foreground")) &palette.muted else if (std.mem.eql(u8, key, "accent")) &palette.accent else if (std.mem.eql(u8, key, "selection")) &palette.selection else if (std.mem.eql(u8, key, "cyan")) &palette.cyan else if (std.mem.eql(u8, key, "green")) &palette.green else if (std.mem.eql(u8, key, "yellow")) &palette.yellow else if (std.mem.eql(u8, key, "red")) &palette.red else if (std.mem.eql(u8, key, "blue")) &palette.blue else if (std.mem.eql(u8, key, "magenta")) &palette.magenta else if (std.mem.eql(u8, key, "orange")) &palette.orange else null;
        if (target) |dest| {
            dest.* = try color(line[separator + 1 ..]);
            palette.from_omarchy = true;
            if (std.mem.eql(u8, key, "dark_foreground")) has_muted = true;
            if (std.mem.eql(u8, key, "selection")) has_selection = true;
        }
    }
    // Secondary text keeps the theme's hue while moving toward foreground
    // enough to remain legible on dark backgrounds.
    if (has_muted) for (&palette.muted, palette.foreground) |*channel, foreground| {
        channel.* = @intCast((@as(u16, channel.*) + foreground) / 2);
    };
    if (palette.from_omarchy) deriveRoles(&palette, has_selection, border);
    return palette;
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !Palette {
    var watcher: Watch = .{};
    try watcher.configure(environ);
    if (watcher.path.len == 0) return .{};
    const bytes = files.readBounded(io, allocator, .cwd(), watcher.path.slice(), 16 * 1024) catch |err| if (err == error.FileNotFound or err == error.NotDir) return .{} else return err;
    defer allocator.free(bytes);
    return parse(bytes);
}

pub fn loadMode(io: std.Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, mode: Mode) !Palette {
    return if (mode == .omagma) .{} else load(io, allocator, environ);
}

test "theme color roles parse independently and preserve bounded fallback" {
    const parsed = try parse("# harmless comment\naccent = \"#112233\"\nselection=\"#334455\" # trailing comment\nforeground = \"#AabbCC\"\nbackground=\"#010203\"\ndark_foreground=\"#556677\"\ncyan=\"#123456\"\ngreen=\"#246810\"\nyellow=\"#abcdef\"\nred=\"#fedcba\"\nunknown=\"arbitrary text\"\n");
    try std.testing.expectEqualSlices(u8, &.{ 17, 34, 51 }, &parsed.accent);
    try std.testing.expectEqualSlices(u8, &.{ 170, 187, 204 }, &parsed.foreground);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &parsed.background);
    try std.testing.expectEqualSlices(u8, &.{ 18, 52, 86 }, &parsed.cyan);
    try std.testing.expect(parsed.from_omarchy);
    const fallback = try parse("unknown=42\n");
    try std.testing.expect(!fallback.from_omarchy);
    try std.testing.expectEqualSlices(u8, &.{ 92, 177, 255 }, &fallback.cyan);
    try std.testing.expectError(error.InvalidThemeColor, parse("accent=\"#123\"\n"));
    try std.testing.expectError(error.InvalidThemeColor, parse("foreground=\"#112233\" bad\n"));
    try std.testing.expectError(error.InvalidCharacter, parse("accent=\"#zz2233\"\n"));
}

test "local UI: theme roles derive focus and border tones from Omarchy colors" {
    const tokyo = try parse("background = \"#1a1b26\"\nforeground = \"#a9b1d6\"\naccent = \"#7aa2f7\"\nselection = \"#292e42\"\nmuted = \"#414868\"\nlighter_background = \"#24283b\"\n");
    // An explicit theme selection is kept; derived roles never replace it.
    try std.testing.expectEqualSlices(u8, &.{ 41, 46, 66 }, &tokyo.selection);
    try std.testing.expectEqualSlices(u8, &.{ 65, 72, 104 }, &tokyo.border);
    // The bulk tint starts at 7% foreground and grows until it is visible.
    try std.testing.expectEqualSlices(u8, &mixUntil(.{ 26, 27, 38 }, .{ 169, 177, 214 }, 7, &.{.{ 26, 27, 38 }}, tint_floor), &tokyo.selection_inactive);
    try std.testing.expect(contrast(tokyo.selection_inactive, tokyo.background) >= tint_floor);
    // Without a selection key, the focused row uses an accent tint of at
    // least 18%, enough to stand out from the background.
    const plain = try parse("background = \"#000000\"\nforeground = \"#ffffff\"\naccent = \"#ff0000\"\nmuted = \"bad\"\n");
    try std.testing.expect(plain.selection[0] >= 46 and plain.selection[1] == 0 and plain.selection[2] == 0);
    try std.testing.expect(contrast(plain.selection, plain.background) >= tint_floor);
    try std.testing.expect(plain.selection_inactive[0] >= 18 and plain.selection_inactive[0] == plain.selection_inactive[2]);
    try std.testing.expect(plain.border[0] > plain.background[0] and plain.border[0] < plain.muted[0]);
    // The built-in palette keeps its exact published values.
    const builtin: Palette = .{};
    try std.testing.expectEqualSlices(u8, &.{ 57, 43, 48 }, &builtin.selection);
    try std.testing.expect(builtin.border[0] < builtin.muted[0] and builtin.border[0] > builtin.background[0]);
}

test "local UI: built-in theme keeps the exact video orange independently of desktop files" {
    const palette = try loadMode(undefined, std.testing.allocator, undefined, .omagma);
    try std.testing.expectEqualSlices(u8, &.{ 255, 158, 97 }, &palette.accent);
    try std.testing.expectEqualSlices(u8, &.{ 17, 22, 32 }, &palette.background);
    try std.testing.expectEqualSlices(u8, &.{ 57, 43, 48 }, &palette.selection);
    try std.testing.expect(!palette.from_omarchy);
    try std.testing.expectEqualStrings("Omagma", name(.omagma));
    try std.testing.expectEqualStrings("Follow Omarchy", name(.follow_omarchy));
}

test "local UI: theme watcher bounds metadata checks and detects removal and replacement" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const absolute = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(absolute);
    const filename = try std.fs.path.join(std.testing.allocator, &.{ absolute, "colors.toml" });
    defer std.testing.allocator.free(filename);
    var watcher: Watch = .{};
    try watcher.path.set(filename);
    try std.testing.expect(!try watcher.changed(io, 0));
    const file = try temporary.dir.createFile(io, "colors.toml", .{});
    try file.writeStreamingAll(io, "accent=\"#112233\"\n");
    file.close(io);
    try std.testing.expect(!try watcher.changed(io, 1999));
    try std.testing.expect(try watcher.changed(io, 2000));
    try std.testing.expect(!try watcher.changed(io, 4000));
    try temporary.dir.deleteFile(io, "colors.toml");
    try std.testing.expect(try watcher.changed(io, 6000));
    try std.testing.expect(!try watcher.changed(io, 8000));
}

fn expectFloors(palette: Palette) !void {
    const foreground = palette.foreground;
    // A role that falls back to foreground can be no better than foreground.
    try std.testing.expect(contrast(palette.selection_inactive, palette.background) >= tint_floor);
    try std.testing.expect(contrast(palette.muted, palette.background) >= @min(text_floor, contrast(foreground, palette.background)));
    for ([_]Color{ palette.selection, palette.selection_inactive }) |surface| try std.testing.expect(contrast(palette.selected_muted, surface) >= @min(text_floor, contrast(foreground, surface)));
    try std.testing.expect(contrast(foreground, palette.chip) >= @min(text_floor, contrast(foreground, palette.background)));
    for ([_]Color{ palette.background, palette.selection, palette.selection_inactive }) |surface| try std.testing.expect(contrast(palette.star, surface) >= @min(star_floor, contrast(foreground, surface)));
}

test "local UI: derived theme roles keep contrast floors in built-in and installed Omarchy themes" {
    try expectFloors(.{});
    try expectFloors(try parse("background = \"#000000\"\nforeground = \"#ffffff\"\naccent = \"#ff0000\"\n"));
    // A light theme whose yellow is unreadable as a star uses its accent, or
    // foreground when the accent is too light as well.
    const light = try parse("background = \"#faf4ed\"\nforeground = \"#575279\"\naccent = \"#7a3a52\"\nyellow = \"#ea9d34\"\nselection = \"#dfdad9\"\nmuted = \"#9893a5\"\ndark_foreground = \"#9893a5\"\n");
    try expectFloors(light);
    try std.testing.expectEqualSlices(u8, &light.accent, &light.star);
    const pale = try parse("background = \"#faf4ed\"\nforeground = \"#575279\"\naccent = \"#b4637a\"\nyellow = \"#ea9d34\"\nselection = \"#dfdad9\"\n");
    try expectFloors(pale);
    try std.testing.expectEqualSlices(u8, &pale.foreground, &pale.star);
    // Theme-authored colours are never rewritten.
    try std.testing.expectEqualSlices(u8, &.{ 0xea, 0x9d, 0x34 }, &light.yellow);
    try std.testing.expectEqualSlices(u8, &.{ 0xdf, 0xda, 0xd9 }, &light.selection);
    const io = std.testing.io;
    var themes = std.Io.Dir.cwd().openDir(io, "/usr/share/omarchy/themes", .{ .iterate = true }) catch return;
    defer themes.close(io);
    var iterator = themes.iterate();
    var checked: usize = 0;
    while (try iterator.next(io)) |entry| {
        var path_buffer: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/colors.toml", .{entry.name}) catch continue;
        const bytes = files.readBounded(io, std.testing.allocator, themes, path, 16 * 1024) catch continue;
        defer std.testing.allocator.free(bytes);
        // Unparseable themes fall back to the built-in palette at runtime.
        expectFloors(parse(bytes) catch continue) catch |err| {
            std.debug.print("theme {s} misses a contrast floor\n", .{entry.name});
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}
