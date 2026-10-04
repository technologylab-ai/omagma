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
        std.debug.print("detached success and exec-failure checks passed\n", .{});
    } else if (std.mem.eql(u8, mode, "callback")) {
        try oauth.callbackProbe(init.io);
        std.debug.print("callback timeout, stalled read, strict state and listener close passed\n", .{});
    } else if (std.mem.eql(u8, mode, "auth")) {
        try oauth.authorize(init.io, args.next() orelse return error.Args, args.next() orelse return error.Args, args.next() orelse return error.Args, args.next() orelse return error.Args);
    } else return error.Mode;
}
