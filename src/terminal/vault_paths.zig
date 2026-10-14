//! Normalize local command paths before prompting or creating any vault data.
const std = @import("std");
/// Use the OS's real shared temporary root: macOS /tmp is a symlink, which
/// private vault directory walks intentionally refuse to traverse.
pub const temporary_root = if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp";
pub fn normalize(io: std.Io, a: std.mem.Allocator, value: []const u8, limit: usize) ![]const u8 {
    if (value.len == 0 or value.len > limit or !std.unicode.utf8ValidateSlice(value)) return error.InvalidVaultPath;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidVaultPath;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    const result = try std.fs.path.resolve(a, &.{ cwd, value });
    errdefer a.free(result);
    if (result.len < 2 or result.len > limit or result[0] != '/') return error.InvalidVaultPath;
    return result;
}

test "vault migration: paths normalize trailing separators and reject controls before prompting" {
    const a = std.testing.allocator;
    const path = try normalize(std.testing.io, a, "/tmp/synthetic-vault///", 4096);
    defer a.free(path);
    try std.testing.expectEqualStrings("/tmp/synthetic-vault", path);
    const relative = try normalize(std.testing.io, a, "synthetic-vault/", 4096);
    defer a.free(relative);
    try std.testing.expect(std.mem.endsWith(u8, relative, "/synthetic-vault"));
    try std.testing.expectError(error.InvalidVaultPath, normalize(std.testing.io, a, "bad\npath", 4096));
    try std.testing.expectError(error.InvalidVaultPath, normalize(std.testing.io, a, "/", 4096));
}
