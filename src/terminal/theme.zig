const std = @import("std");
const files = @import("files.zig");

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
    red: Color = .{ 255, 112, 112 },
    from_omarchy: bool = false,
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
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const target: ?*Color = if (std.mem.eql(u8, key, "foreground")) &palette.foreground else if (std.mem.eql(u8, key, "background")) &palette.background else if (std.mem.eql(u8, key, "dark_foreground")) &palette.muted else if (std.mem.eql(u8, key, "accent")) &palette.accent else if (std.mem.eql(u8, key, "selection")) &palette.selection else if (std.mem.eql(u8, key, "cyan")) &palette.cyan else if (std.mem.eql(u8, key, "green")) &palette.green else if (std.mem.eql(u8, key, "yellow")) &palette.yellow else if (std.mem.eql(u8, key, "red")) &palette.red else null;
        if (target) |dest| {
            dest.* = try color(line[separator + 1 ..]);
            palette.from_omarchy = true;
            if (std.mem.eql(u8, key, "dark_foreground")) has_muted = true;
        }
    }
    // Secondary text keeps the theme's hue while moving toward foreground
    // enough to remain legible on dark backgrounds.
    if (has_muted) for (&palette.muted, palette.foreground) |*channel, foreground| {
        channel.* = @intCast((@as(u16, channel.*) + foreground) / 2);
    };
    return palette;
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !Palette {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    const home = environ.get("HOME") orelse return .{};
    const state = environ.get("XDG_STATE_HOME") orelse try std.fmt.allocPrint(temp, "{s}/.local/state", .{home});
    const path = try std.fmt.allocPrint(temp, "{s}/omarchy/current/theme/colors.toml", .{state});
    const bytes = files.readBounded(io, temp, .cwd(), path, 16 * 1024) catch |err| if (err == error.FileNotFound or err == error.NotDir) return .{} else return err;
    return parse(bytes);
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
