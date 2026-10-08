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
    red: Color = .{ 255, 112, 112 },
    from_omarchy: bool = false,
};

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
