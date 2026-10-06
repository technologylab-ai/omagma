//! Signal-safe, close-on-exec wake descriptors. Handlers never allocate, lock
//! or use std.Io; the macOS self-pipe writer cannot block when signals coalesce.
const std = @import("std");
const builtin = @import("builtin");
pub const Wake = struct {
    read: std.Io.File,
    write_fd: std.posix.fd_t,
    pub fn init(io: std.Io) !Wake {
        if (builtin.os.tag == .linux) {
            const raw = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
            if (std.os.linux.errno(raw) != .SUCCESS) return error.SignalWakeFailed;
            const fd: std.posix.fd_t = @intCast(raw);
            return .{ .read = .{ .handle = fd, .flags = .{ .nonblocking = false } }, .write_fd = fd };
        }
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        var pair: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&pair) != 0) return error.SignalWakeFailed;
        errdefer {
            _ = std.c.close(pair[0]);
            _ = std.c.close(pair[1]);
        }
        for (pair) |fd| if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) == -1) return error.SignalWakeFailed;
        const flags = std.c.fcntl(pair[1], std.c.F.GETFL);
        const nonblock: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (flags == -1 or std.c.fcntl(pair[1], std.c.F.SETFL, flags | nonblock) == -1) return error.SignalWakeFailed;
        _ = io;
        return .{ .read = .{ .handle = pair[0], .flags = .{ .nonblocking = false } }, .write_fd = pair[1] };
    }
    pub fn close(self: Wake, io: std.Io) void {
        self.read.close(io);
        if (self.write_fd != self.read.handle) (std.Io.File{ .handle = self.write_fd, .flags = .{ .nonblocking = true } }).close(io);
    }
};
pub fn notify(fd: std.posix.fd_t) void {
    const one: u64 = 1;
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.write(fd, std.mem.asBytes(&one).ptr, 8);
    } else if (builtin.os.tag == .macos) {
        const saved_errno = std.c._errno().*;
        _ = std.c.write(fd, std.mem.asBytes(&one).ptr, 8);
        std.c._errno().* = saved_errno;
    }
}
