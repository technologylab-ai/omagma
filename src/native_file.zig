//! Nonblocking descriptor opens with native errno/flag contracts. Linux keeps
//! its raw kernel ABI; macOS uses libc's -1 plus thread-local errno contract.
const std = @import("std");
const builtin = @import("builtin");
pub const Options = struct {
    read_write: bool = false,
    create: bool = false,
    follow_symlinks: bool = false,
    mode: u32 = 0,
};
pub fn openAt(io: std.Io, dir: std.Io.Dir, path: [*:0]const u8, options: Options) !std.Io.File {
    const fd: std.posix.fd_t = while (true) {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const flags: linux.O = .{ .ACCMODE = if (options.read_write) .RDWR else .RDONLY, .CREAT = options.create, .CLOEXEC = true, .NOFOLLOW = !options.follow_symlinks, .NONBLOCK = true, .NOCTTY = true };
            const raw = linux.openat(dir.handle, path, flags, options.mode);
            if (linux.errno(raw) == .SUCCESS) break @intCast(raw);
            try failure(io, linux.errno(raw));
        } else if (builtin.os.tag == .macos) {
            const flags: std.posix.O = .{ .ACCMODE = if (options.read_write) .RDWR else .RDONLY, .CREAT = options.create, .CLOEXEC = true, .NOFOLLOW = !options.follow_symlinks, .NONBLOCK = true, .NOCTTY = true };
            const raw = std.c.openat(dir.handle, path, flags, @as(c_uint, options.mode));
            if (raw >= 0) break raw;
            try failure(io, std.posix.errno(raw));
        } else return error.UnsupportedPlatform;
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}
fn failure(io: std.Io, code: anytype) !void {
    switch (code) {
        .INTR => try io.checkCancel(),
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .LOOP => return error.SymbolicLinkNotAllowed,
        .ISDIR => return error.IsDir,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .IO => return error.InputOutput,
        else => return error.FileOpenFailed,
    }
}
