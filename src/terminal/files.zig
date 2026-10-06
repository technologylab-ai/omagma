//! User-selected files must not block on FIFOs or follow a substituted leaf.
//! Validate the opened descriptor, rather than stat/reopen a mutable path.
const std = @import("std");
const native = @import("../native_file.zig");

pub fn openRegular(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFilePath;
    if (path.len > 4096) return error.NameTooLong;
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    const file = try native.openAt(io, dir, terminated, .{});
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    return file;
}

pub fn readBounded(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, limit: usize) ![]u8 {
    const file = try openRegular(io, allocator, dir, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > limit) return error.FileTooLarge;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit));
}
