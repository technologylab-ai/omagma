const std = @import("std");
const files = @import("files.zig");
const layout = @import("layout.zig");

pub const Preferences = struct { schema: u8 = 1, readerLayout: layout.ReaderLayout = .right };
const max_bytes = 4096;

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Preferences {
    if (bytes.len > max_bytes) return error.UiPreferencesTooLarge;
    const parsed = try std.json.parseFromSlice(Preferences, allocator, bytes, .{ .max_value_len = max_bytes });
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedUiPreferences;
    return parsed.value;
}

pub fn path(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, explicit: ?[]const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    const chosen = explicit orelse blk: {
        const home = environ.get("HOME") orelse return error.HomeRequired;
        const directory = environ.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(temp, "{s}/.config", .{home});
        break :blk try std.fmt.allocPrint(temp, "{s}/omagma/ui.json", .{directory});
    };
    if (!std.fs.path.isAbsolute(chosen) or chosen.len > 4096 or std.mem.indexOfScalar(u8, chosen, 0) != null) return error.InvalidUiPreferencesPath;
    return allocator.dupe(u8, chosen);
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, filename: []const u8) !Preferences {
    const file = files.openRegular(io, allocator, .cwd(), filename) catch |err| if (err == error.FileNotFound) return .{} else return err;
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureUiPreferences;
    if (stat.size > max_bytes) return error.UiPreferencesTooLarge;
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, filename: []const u8, value: Preferences) !void {
    if (!std.fs.path.isAbsolute(filename) or filename.len > 4096 or std.mem.indexOfScalar(u8, filename, 0) != null) return error.InvalidUiPreferencesPath;
    // Revalidate an existing file: malformed or insecure settings are never
    // silently replaced merely because the running UI chose its fallback.
    _ = try load(io, allocator, filename);
    const parent = std.fs.path.dirname(filename) orelse return error.InvalidUiPreferencesPath;
    const basename = std.fs.path.basename(filename);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidUiPreferencesPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureUiPreferencesDirectory;
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    var atomic = try dir.createFileAtomic(io, basename, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

test "reader preferences roundtrip only schema and validated layout" {
    const allocator = std.testing.allocator;
    const right = try parse(allocator, "{\"schema\":1,\"readerLayout\":\"right\"}");
    const below = try parse(allocator, "{\"schema\":1,\"readerLayout\":\"below\"}");
    try std.testing.expectEqual(layout.ReaderLayout.right, right.readerLayout);
    try std.testing.expectEqual(layout.ReaderLayout.below, below.readerLayout);
    const encoded = try std.json.Stringify.valueAlloc(allocator, below, .{});
    defer allocator.free(encoded);
    try std.testing.expectEqual(layout.ReaderLayout.below, (try parse(allocator, encoded)).readerLayout);
    try std.testing.expectError(error.UnsupportedUiPreferences, parse(allocator, "{\"schema\":2}"));
    try std.testing.expectError(error.InvalidEnumTag, parse(allocator, "{\"readerLayout\":\"overlay\"}"));
    try std.testing.expectError(error.UnknownField, parse(allocator, "{\"account\":\"personal@example.com\"}"));
}
