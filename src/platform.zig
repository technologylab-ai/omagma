const std = @import("std");

fn timer(io: std.Io, duration: std.Io.Clock.Duration) std.Io.Cancelable!void {
    try duration.sleep(io);
}

/// Joins cancellation before returning: argument and result borrows cannot escape.
pub fn deadline(io: std.Io, duration: std.Io.Clock.Duration, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) anyerror!@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Event = union(enum) { operation: Result, timeout: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.operation, function, args);
    try select.concurrent(.timeout, timer, .{ io, duration });
    return switch (try select.await()) {
        .operation => |r| r,
        .timeout => |r| {
            try r;
            return error.Timeout;
        },
    };
}

pub fn seconds(n: i64) std.Io.Clock.Duration {
    return .{ .clock = .awake, .raw = .fromSeconds(n) };
}

/// Child pipes are caller-owned. Ensure termination and reaping on every exit.
pub fn closePipes(child: *std.process.Child, io: std.Io) void {
    if (child.stdin) |f| {
        f.close(io);
        child.stdin = null;
    }
    if (child.stdout) |f| {
        f.close(io);
        child.stdout = null;
    }
    if (child.stderr) |f| {
        f.close(io);
        child.stderr = null;
    }
}

pub fn checkedExit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
}

var launch_strings: [32 * 1024]u8 = undefined;
var launch_environment: [64 * 1024]u8 = undefined;
var launch_active = std.atomic.Value(bool).init(false);

/// Linux double fork. The short intermediary is reaped; its child reports exec
/// failure on a CLOEXEC pipe. No allocation, locks or std.Io run after fork.
pub fn launchDetached(io: std.Io, argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > 16 or !std.mem.startsWith(u8, argv[0], "/")) return error.InvalidArgv;
    if (launch_active.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.LaunchBusy;
    defer launch_active.store(false, .release);
    var strings_used: usize = 0;
    var argv_z: [17:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |arg, i| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null or arg.len + 1 > launch_strings.len - strings_used) return error.ArgvTooLarge;
        @memcpy(launch_strings[strings_used..][0..arg.len], arg);
        launch_strings[strings_used + arg.len] = 0;
        argv_z[i] = @ptrCast(launch_strings[strings_used..].ptr);
        strings_used += arg.len + 1;
    }
    defer std.crypto.secureZero(u8, launch_strings[0..strings_used]);
    const env = try std.Io.Dir.cwd().readFile(io, "/proc/self/environ", &launch_environment);
    if (env.len == launch_environment.len) return error.EnvironmentTooLarge;
    defer std.crypto.secureZero(u8, launch_environment[0..env.len]);
    var env_z: [513:null]?[*:0]const u8 = @splat(null);
    var start: usize = 0;
    var entries: usize = 0;
    while (start < env.len) {
        if (entries == 512) return error.EnvironmentTooLarge;
        const end = std.mem.indexOfScalarPos(u8, env, start, 0) orelse return error.InvalidEnvironment;
        env_z[entries] = @ptrCast(env.ptr + start);
        entries += 1;
        start = end + 1;
    }
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    if (std.posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.LaunchPipeFailed;
    const fork_result = linux.fork();
    if (std.posix.errno(fork_result) != .SUCCESS) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return error.LaunchForkFailed;
    }
    if (fork_result == 0) {
        _ = linux.close(fds[0]);
        if (std.posix.errno(linux.setsid()) != .SUCCESS) launchFailure(fds[1]);
        const second = linux.fork();
        if (std.posix.errno(second) != .SUCCESS) launchFailure(fds[1]);
        if (second != 0) linux.exit_group(0);
        const pid: i32 = @intCast(linux.getpid());
        if (linux.write(fds[1], std.mem.asBytes(&pid).ptr, 4) != 4) linux.exit_group(127);
        const null_fd = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (std.posix.errno(null_fd) != .SUCCESS) launchFailure(fds[1]);
        for (0..3) |n| if (std.posix.errno(linux.dup2(@intCast(null_fd), @intCast(n))) != .SUCCESS) launchFailure(fds[1]);
        // Zig 0.16's CLOSE_RANGE packed flag positions differ from Linux's
        // installed UAPI. CLOSE_RANGE_CLOEXEC is (1U << 2), not bit 1.
        if (std.posix.errno(linux.syscall3(.close_range, 3, std.math.maxInt(i32), 4)) != .SUCCESS) launchFailure(fds[1]);
        _ = linux.execve(argv_z[0].?, @ptrCast(&argv_z), @ptrCast(&env_z));
        launchFailure(fds[1]);
    }
    _ = linux.close(fds[1]);
    const pipe: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer pipe.close(io);
    var child: std.process.Child = .{ .id = @intCast(fork_result), .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
    defer if (child.id != null) child.kill(io);
    var launched_pid: ?i32 = null;
    var success = false;
    defer if (!success) {
        if (launched_pid) |pid| _ = linux.kill(pid, .KILL);
    };
    try deadline(io, seconds(3), launchHandshake, .{ io, pipe, &child, &launched_pid });
    success = true;
}
fn launchFailure(fd: i32) noreturn {
    const byte: [1]u8 = .{1};
    _ = std.os.linux.write(fd, &byte, 1);
    std.os.linux.exit_group(127);
}
fn launchHandshake(io: std.Io, pipe: std.Io.File, child: *std.process.Child, pid_out: *?i32) anyerror!void {
    var pid_bytes: [4]u8 = undefined;
    var used: usize = 0;
    while (used < 4) {
        const n = pipe.readStreaming(io, &.{pid_bytes[used..]}) catch |err| switch (err) {
            error.EndOfStream => return error.ExecFailed,
            else => return err,
        };
        used += n;
    }
    const pid: i32 = @bitCast(pid_bytes);
    if (pid <= 0) return error.ExecFailed;
    pid_out.* = pid;
    var error_byte: [1]u8 = undefined;
    const count = pipe.readStreaming(io, &.{&error_byte}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    try checkedExit(try child.wait(io));
    if (count != 0) return error.ExecFailed;
}

pub const reservation_bytes = @sizeOf(@TypeOf(launch_strings)) + @sizeOf(@TypeOf(launch_environment)) + @sizeOf(@TypeOf(launch_active)) + 64;
