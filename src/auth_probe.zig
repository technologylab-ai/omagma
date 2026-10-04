const std = @import("std");
const oauth = @import("oauth.zig");
const keyring = @import("keyring.zig");
const platform = @import("platform.zig");
pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse return error.ModeRequired;
    if (std.mem.eql(u8, mode, "keyring")) {
        try keyring.syntheticProbe(init.io);
        try keyring.failureProbe(init.io);
        std.debug.print("synthetic keyring store/lookup/clear passed; child maxrss={d}\n", .{keyring.last_child_peak_rss});
    } else if (std.mem.eql(u8, mode, "launch")) {
        try platform.launchDetached(init.io, &.{"/usr/bin/true"});
        try std.testing.expectError(error.ExecFailed, platform.launchDetached(init.io, &.{"/nonexistent/omagma-test"}));
        try platform.closeRangeProbe(init.io);
        std.debug.print("detached success, exec-failure and kernel FD inheritance checks passed\n", .{});
    } else if (std.mem.eql(u8, mode, "fd-inheritance-probe")) {
        const closed_fd = try std.fmt.parseInt(i32, args.next() orelse return error.Args, 10);
        const open_fd = try std.fmt.parseInt(i32, args.next() orelse return error.Args, 10);
        if (args.next() != null) return error.Args;
        platform.verifyFdInheritanceProbe(closed_fd, open_fd) catch |err| {
            std.debug.print("{s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, mode, "callback")) {
        try oauth.callbackProbe(init.io);
        std.debug.print("callback timeout, stalled read, strict state and listener close passed\n", .{});
    } else if (std.mem.eql(u8, mode, "auth")) {
        try oauth.authorize(init.io, args.next() orelse return error.Args, args.next() orelse return error.Args, args.next() orelse return error.Args, args.next() orelse return error.Args);
    } else return error.Mode;
}
