//! User-selected files must not block on FIFOs or follow a substituted leaf.
//! Validate the opened descriptor, rather than stat/reopen a mutable path.
const std = @import("std");
const linux = std.os.linux;

pub fn openRegular(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFilePath;
    if (path.len > 4096) return error.NameTooLong;
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true };
    const fd: std.posix.fd_t = while (true) {
        const result = linux.openat(dir.handle, terminated, flags, 0);
        switch (linux.errno(result)) {
            .SUCCESS => break @intCast(result),
            .INTR => try io.checkCancel(),
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            .LOOP => return error.SymbolicLinkNotAllowed,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .IO => return error.InputOutput,
            else => return error.FileOpenFailed,
        }
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
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
