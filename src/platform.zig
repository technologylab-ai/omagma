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

/// Threaded child.wait clears the POSIX ownership handle even on Canceled.
/// Canceled is returned before any successful reap; retain that exact still-
/// owned child so the caller's cleanup can terminate and reap it uncancelably.
pub fn waitOwned(io: std.Io, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    const owned = child.id;
    return child.wait(io) catch |err| {
        if (err == error.Canceled and (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos)) child.id = owned;
        return err;
    };
}

/// Force termination before the uncancelable reap; TERM alone can be ignored.
/// child.id is held only while this process still owns the unreaped child.
pub fn killOwned(io: std.Io, child: *std.process.Child) void {
    if (child.id) |pid| {
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) std.posix.kill(pid, .KILL) catch {};
        child.kill(io);
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
// Exact Zig 0.17.0 includes the leading reserved bit in CLOSE_RANGE. Keep the
// exec-status pipe open until exec while marking inherited descriptors CLOEXEC.
const inherited_descriptor_flags: std.os.linux.CLOSE_RANGE = .{ .UNSHARE = false, .CLOEXEC = true };

/// Linux double fork. The short intermediary is reaped; its child reports exec
/// failure on a CLOEXEC pipe. No allocation, locks or std.Io run after fork.
pub fn launchDetached(io: std.Io, argv: []const []const u8) !void {
    if (@import("builtin").os.tag == .macos) return launchDarwin(io, argv);
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
    // All calls below use the raw Linux ABI, including when libc is linked.
    // std.posix.errno follows libc's -1/TLS-errno convention in a musl build.
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.LaunchPipeFailed;
    const fork_result = linux.fork();
    if (linux.errno(fork_result) != .SUCCESS) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return error.LaunchForkFailed;
    }
    if (fork_result == 0) {
        _ = linux.close(fds[0]);
        if (linux.errno(linux.setsid()) != .SUCCESS) launchFailure(fds[1]);
        const second = linux.fork();
        if (linux.errno(second) != .SUCCESS) launchFailure(fds[1]);
        if (second != 0) linux.exit_group(0);
        const pid: i32 = @intCast(linux.getpid());
        if (linux.write(fds[1], std.mem.asBytes(&pid).ptr, 4) != 4) linux.exit_group(127);
        const null_fd = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(null_fd) != .SUCCESS) launchFailure(fds[1]);
        for (0..3) |n| if (linux.errno(linux.dup2(@intCast(null_fd), @intCast(n))) != .SUCCESS) launchFailure(fds[1]);
        if (linux.errno(linux.close_range(3, std.math.maxInt(i32), inherited_descriptor_flags)) != .SUCCESS) launchFailure(fds[1]);
        _ = linux.execve(argv_z[0].?, @ptrCast(&argv_z), @ptrCast(&env_z));
        launchFailure(fds[1]);
    }
    _ = linux.close(fds[1]);
    const pipe: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer pipe.close(io);
    var child: std.process.Child = .{ .id = @intCast(fork_result), .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
    defer if (child.id != null) killOwned(io, &child);
    var launched_pid: ?i32 = null;
    var success = false;
    defer if (!success) {
        if (launched_pid) |pid| _ = linux.kill(pid, .KILL);
    };
    try deadline(io, seconds(3), launchHandshake, .{ io, pipe, &child, &launched_pid });
    success = true;
}

/// A short exec-self owner performs native spawn, then exits so the actual
/// desktop process is adopted by launchd. No application fork-child code runs.
fn launchDarwin(io: std.Io, argv: []const []const u8) !void {
    if (@import("builtin").os.tag != .macos) return error.UnsupportedPlatform;
    if (argv.len == 0 or argv.len > 16 or !std.fs.path.isAbsolute(argv[0])) return error.InvalidArgv;
    if (launch_active.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.LaunchBusy;
    defer launch_active.store(false, .release);
    var total: usize = 0;
    for (argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgv;
        total += arg.len + 1;
        if (total > launch_strings.len) return error.ArgvTooLarge;
    }
    var executable: [4096]u8 = undefined;
    const n = try std.process.executablePath(io, &executable);
    var command: [18][]const u8 = undefined;
    command[0] = executable[0..n];
    command[1] = "__launch-worker";
    @memcpy(command[2..][0..argv.len], argv);
    var child = try std.process.spawn(io, .{ .argv = command[0 .. argv.len + 2], .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer {
        closePipes(&child, io);
        if (child.id != null) killOwned(io, &child);
    }
    try deadline(io, seconds(3), launchDarwinHandshake, .{ io, &child });
}

const Darwin = struct {
    extern "c" fn posix_spawnattr_setsigdefault(attr: *std.c.posix_spawnattr_t, mask: *const std.posix.sigset_t) c_int;
    extern "c" fn posix_spawnattr_setsigmask(attr: *std.c.posix_spawnattr_t, mask: *const std.posix.sigset_t) c_int;
};
/// Internal worker. The parent captures only a native PID, not user/mail data.
pub fn launchDarwinWorker(io: std.Io, argv: []const []const u8) !void {
    if (@import("builtin").os.tag != .macos) return error.UnsupportedPlatform;
    if (argv.len == 0 or argv.len > 16 or !std.fs.path.isAbsolute(argv[0])) return error.InvalidArgv;
    var used: usize = 0;
    var terminated: [17:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |arg, index| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null or arg.len + 1 > launch_strings.len - used) return error.ArgvTooLarge;
        @memcpy(launch_strings[used..][0..arg.len], arg);
        launch_strings[used + arg.len] = 0;
        terminated[index] = @ptrCast(launch_strings[used..].ptr);
        used += arg.len + 1;
    }
    defer std.crypto.secureZero(u8, launch_strings[0..used]);
    var attr: std.c.posix_spawnattr_t = undefined;
    if (std.c.posix_spawnattr_init(&attr) != 0) return error.LaunchSpawnFailed;
    defer _ = std.c.posix_spawnattr_destroy(&attr);
    if (std.c.posix_spawnattr_setflags(&attr, .{ .SETSID = true, .CLOEXEC_DEFAULT = true, .SETSIGMASK = true, .SETSIGDEF = true }) != 0) return error.LaunchSpawnFailed;
    const mask = std.posix.sigemptyset();
    if (Darwin.posix_spawnattr_setsigmask(&attr, &mask) != 0) return error.LaunchSpawnFailed;
    const defaults = std.posix.sigfillset();
    if (Darwin.posix_spawnattr_setsigdefault(&attr, &defaults) != 0) return error.LaunchSpawnFailed;
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.LaunchSpawnFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    for (0..3) |fd| if (std.c.posix_spawn_file_actions_addopen(&actions, @intCast(fd), "/dev/null", 2, 0) != 0) return error.LaunchSpawnFailed;
    var pid: std.c.pid_t = undefined;
    if (std.c.posix_spawn(&pid, terminated[0].?, &actions, &attr, @ptrCast(&terminated), @ptrCast(std.c.environ)) != 0) return error.ExecFailed;
    var acknowledged = false;
    // This worker remains the direct parent until ACK, pinning even an exited
    // child PID. Failure cleanup can never signal a recycled desktop PID.
    defer if (!acknowledged) {
        _ = std.c.kill(pid, .KILL);
        while (std.c.waitpid(pid, null, 0) < 0) {
            if (std.posix.errno(-1) != .INTR) break;
        }
    };
    try std.Io.File.stdout().writeStreamingAll(io, std.mem.asBytes(&pid));
    try deadline(io, seconds(3), launchDarwinAck, .{io});
    acknowledged = true;
}
fn launchDarwinAck(io: std.Io) !void {
    var acknowledgement: [1]u8 = undefined;
    const count = std.Io.File.stdin().readStreaming(io, &.{&acknowledgement}) catch |err| switch (err) {
        error.EndOfStream => return error.InvalidLaunchAcknowledgement,
        else => return err,
    };
    if (count != 1 or acknowledgement[0] != 1) return error.InvalidLaunchAcknowledgement;
}
fn launchDarwinHandshake(io: std.Io, child: *std.process.Child) !void {
    var pid_bytes: [4]u8 = undefined;
    var used: usize = 0;
    while (used < pid_bytes.len) {
        const count = child.stdout.?.readStreaming(io, &.{pid_bytes[used..]}) catch |err| switch (err) {
            error.EndOfStream => return error.ExecFailed,
            else => return err,
        };
        if (count == 0) return error.ExecFailed;
        used += count;
    }
    _ = try decodeLaunchPid(&pid_bytes);
    try child.stdin.?.writeStreamingAll(io, &.{1});
    child.stdin.?.close(io);
    child.stdin = null;
    var extra: [1]u8 = undefined;
    const count = child.stdout.?.readStreaming(io, &.{&extra}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (count != 0) return error.ExecFailed;
    try checkedExit(try waitOwned(io, child));
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
    const pid = try decodeLaunchPid(&pid_bytes);
    pid_out.* = pid;
    var error_byte: [1]u8 = undefined;
    const count = pipe.readStreaming(io, &.{&error_byte}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    const term = try waitOwned(io, child);
    // A known failed exec has already exited; never signal its reusable PID.
    if (count != 0) {
        pid_out.* = null;
        return error.ExecFailed;
    }
    try checkedExit(term);
}

fn decodeLaunchPid(bytes: *const [4]u8) !i32 {
    // The forked sender writes std.mem.asBytes(&pid), a native-memory value.
    // Zig 0.17's logical array bit conversion does not preserve that intent.
    const pid = std.mem.readInt(i32, bytes, std.lang.Endian.native);
    if (pid <= 0) return error.ExecFailed;
    return pid;
}

/// Kernel and exec regression probe. auth_probe supplies the child mode below;
/// production launch code still performs only raw syscalls after its fork.
pub fn closeRangeProbe(io: std.Io) !void {
    if (@import("builtin").os.tag != .linux) return error.UnsupportedPlatform;
    try deadline(io, seconds(3), closeRangeProbeInner, .{io});
}

fn closeRangeProbeInner(io: std.Io) anyerror!void {
    const linux = std.os.linux;
    var sentinel: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&sentinel, .{ .CLOEXEC = false })) != .SUCCESS) return error.ProbePipeFailed;
    defer {
        _ = linux.close(sentinel[0]);
        _ = linux.close(sentinel[1]);
    }
    // High dedicated descriptors avoid the child's stdin/stdout/progress setup.
    const closed_result = linux.fcntl(sentinel[1], linux.F.DUPFD, 128);
    if (linux.errno(closed_result) != .SUCCESS) return error.ProbeDupFailed;
    const closed_fd: i32 = @intCast(closed_result);
    defer _ = linux.close(closed_fd);
    const open_result = linux.fcntl(sentinel[1], linux.F.DUPFD, 128);
    if (linux.errno(open_result) != .SUCCESS) return error.ProbeDupFailed;
    const open_fd: i32 = @intCast(open_result);
    defer _ = linux.close(open_fd);
    try std.testing.expectEqual(@as(usize, 0), linux.fcntl(closed_fd, linux.F.GETFD, 0));
    try std.testing.expectEqual(@as(usize, 0), linux.fcntl(open_fd, linux.F.GETFD, 0));
    // Limit the syscall to one newly duplicated FD; never sweep parent FDs.
    if (linux.errno(linux.close_range(closed_fd, closed_fd, inherited_descriptor_flags)) != .SUCCESS) return error.ProbeCloseRangeFailed;
    // Independent kernel oracle: F_GETFD must return literal FD_CLOEXEC=1.
    try std.testing.expectEqual(@as(usize, 1), linux.fcntl(closed_fd, linux.F.GETFD, 0));
    try std.testing.expectEqual(@as(usize, 0), linux.fcntl(open_fd, linux.F.GETFD, 0));
    const marker: [1]u8 = .{0x7b};
    try std.testing.expectEqual(@as(usize, 1), linux.write(closed_fd, &marker, 1));
    var received: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), linux.read(sentinel[0], &received, 1));
    try std.testing.expectEqual(@as(u8, 0x7b), received[0]);

    var closed_text: [16]u8 = undefined;
    var open_text: [16]u8 = undefined;
    const closed_arg = try std.fmt.bufPrint(&closed_text, "{d}", .{closed_fd});
    const open_arg = try std.fmt.bufPrint(&open_text, "{d}", .{open_fd});
    // std.process.spawn prepares argv/environment before fork. All test logic
    // in verifyFdInheritanceProbe executes after the fresh Zig executable starts.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/proc/self/exe", "fd-inheritance-probe", closed_arg, open_arg },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer {
        closePipes(&child, io);
        if (child.id != null) killOwned(io, &child);
    }
    var diagnostic: [512]u8 = undefined;
    var diagnostic_len: usize = 0;
    while (diagnostic_len < diagnostic.len) {
        const count = child.stderr.?.readStreaming(io, &.{diagnostic[diagnostic_len..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        diagnostic_len += count;
    }
    if (diagnostic_len == diagnostic.len) return error.ProbeDiagnosticTooLarge;
    const term = try waitOwned(io, &child);
    checkedExit(term) catch |err| {
        std.debug.print("FD inheritance child failed: {s}\n", .{diagnostic[0..diagnostic_len]});
        return err;
    };
}

/// Called only by auth_probe after exec; the unflagged FD is a positive control.
pub fn verifyFdInheritanceProbe(closed_fd: i32, open_fd: i32) !void {
    if (@import("builtin").os.tag != .linux) return error.UnsupportedPlatform;
    if (closed_fd < 3 or open_fd < 3 or closed_fd == open_fd) return error.InvalidProbeFd;
    const linux = std.os.linux;
    if (linux.errno(linux.fcntl(closed_fd, linux.F.GETFD, 0)) != .BADF) return error.ProbeFdInherited;
    try std.testing.expectEqual(@as(usize, 0), linux.fcntl(open_fd, linux.F.GETFD, 0));
}

test "launch PID handshake decodes literal native bytes and rejects invalid PID" {
    const bytes: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    // Independent numeric oracle: no encode/decode or inverse-bitCast roundtrip.
    const expected: i32 = switch (std.lang.Endian.native) {
        .little => 0x78563412,
        .big => 0x12345678,
    };
    try std.testing.expectEqual(expected, try decodeLaunchPid(&bytes));
    try std.testing.expectError(error.ExecFailed, decodeLaunchPid(&.{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.ExecFailed, decodeLaunchPid(&.{ 0xff, 0xff, 0xff, 0xff }));
}

test "Linux inherited-descriptor flags match literal kernel CLOEXEC values" {
    // Linux UAPI: CLOSE_RANGE_UNSHARE=(1U<<1), CLOSE_RANGE_CLOEXEC=(1U<<2).
    try std.testing.expectEqual(@as(u32, 4), @backingInt(inherited_descriptor_flags));
    const combined: std.os.linux.CLOSE_RANGE = .{ .UNSHARE = true, .CLOEXEC = true };
    try std.testing.expectEqual(@as(u32, 6), @backingInt(combined));
}

test "raw Linux syscall errors retain kernel errno when libc is linked" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    // Literal kernel errno encodings, independent of libc's thread-local errno.
    try std.testing.expectEqual(linux.E.BADF, linux.errno(@as(usize, 0) -% 9));
    try std.testing.expectEqual(linux.E.INVAL, linux.errno(@as(usize, 0) -% 22));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(@as(usize, 128)));
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(-1, linux.F.GETFD, 0)));
}

pub const reservation_bytes = @sizeOf(@TypeOf(launch_strings)) + @sizeOf(@TypeOf(launch_environment)) + @sizeOf(@TypeOf(launch_active)) + 64;

/// Synthetic exec-self child closes stdout, then remains live beyond the
/// owner's deadline. This forces cancellation inside child.wait, after EOF.
pub fn waitCancellationChild(io: std.Io) !void {
    // A hostile/held child may ignore TERM; cleanup must force KILL then reap.
    var action: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &action, null);
    const pid: i32 = if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else std.c.getpid();
    try std.Io.File.stdout().writeStreamingAll(io, std.mem.asBytes(&pid));
    std.Io.File.stdout().close(io);
    try seconds(20).sleep(io);
}
pub fn waitCancellationProbe(io: std.Io) !void {
    // Independent control demonstrates the std ownership loss, then compares
    // the adapter while both actual children are still alive after stdout EOF.
    try waitCancellationCase(io, false);
    try waitCancellationCase(io, true);
}
fn waitStandard(io: std.Io, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}
fn waitCancellationCase(io: std.Io, comptime preserving: bool) !void {
    var executable: [4096]u8 = undefined;
    const length = try std.process.executablePath(io, &executable);
    var child = try std.process.spawn(io, .{ .argv = &.{ executable[0..length], "__wait-probe-child" }, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    defer {
        closePipes(&child, io);
        if (child.id != null) killOwned(io, &child);
    }
    var wire: [4]u8 = undefined;
    var used: usize = 0;
    while (used < wire.len) used += try child.stdout.?.readStreaming(io, &.{wire[used..]});
    const pid = try decodeLaunchPid(&wire);
    try std.testing.expectEqual(pid, child.id.?);
    var extra: [1]u8 = undefined;
    const count = child.stdout.?.readStreaming(io, &.{&extra}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 0), count);
    closePipes(&child, io);
    const short: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(100) };
    try std.testing.expectError(error.Timeout, deadline(io, short, if (preserving) waitOwned else waitStandard, .{ io, &child }));
    if (preserving) try std.testing.expectEqual(pid, child.id.?) else {
        try std.testing.expect(child.id == null);
        child.id = pid; // Control cleanup retains the separately captured PID.
    }
    // WNOHANG==0 proves this exact direct child is still live, not reaped/reused.
    if (@import("builtin").link_libc) {
        try std.testing.expectEqual(@as(std.c.pid_t, 0), std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG)));
    } else {
        var wait_status: i32 = 0;
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.wait4(pid, &wait_status, std.os.linux.W.NOHANG, null));
    }
    killOwned(io, &child);
    try std.testing.expect(child.id == null);
    // An independent OS wait must now report ECHILD, proving no zombie remains.
    if (@import("builtin").link_libc) {
        try std.testing.expectEqual(@as(std.c.pid_t, -1), std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG)));
        try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(-1));
    } else {
        var wait_status: i32 = 0;
        const result = std.os.linux.wait4(pid, &wait_status, std.os.linux.W.NOHANG, null);
        try std.testing.expectEqual(std.os.linux.E.CHILD, std.os.linux.errno(result));
    }
}
