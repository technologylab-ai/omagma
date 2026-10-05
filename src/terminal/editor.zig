//! A direct-argv external editor and owner-only temporary draft. No shell or
//! terminal multiplexer is involved. The caller suspends/restores its renderer.
const std = @import("std");
const types = @import("types.zig");
const files = @import("files.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Result = struct {
    body: []u8,
    exit_code: u8,
};

fn appendWord(allocator: Allocator, words: *std.ArrayList([]const u8), bytes: []const u8) !void {
    const word = try allocator.dupe(u8, bytes);
    errdefer allocator.free(word);
    try words.append(allocator, word);
}

/// Quotes and backslash escapes are accepted; shell evaluation is not.
/// All returned words belong to the caller's allocator.
pub fn arguments(allocator: Allocator, command: []const u8, filename: []const u8) ![]const []const u8 {
    if (command.len == 0 or command.len > 4096) return error.InvalidEditor;
    var words: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(allocator);
    var quote: ?u8 = null;
    var escaped = false;
    var started = false;
    for (command) |c| {
        if (c == 0 or c == '\n' or c == '\r') return error.InvalidEditor;
        if (escaped) {
            try word.append(allocator, c);
            escaped = false;
            started = true;
        } else if (c == '\\' and quote != @as(?u8, '\'')) {
            escaped = true;
            started = true;
        } else if (quote) |q| {
            if (c == q) quote = null else try word.append(allocator, c);
        } else if (c == '\'' or c == '"') {
            quote = c;
            started = true;
        } else if (c == ' ' or c == '\t') {
            if (started) {
                if (words.items.len == 31) return error.EditorArgumentsTooMany;
                try appendWord(allocator, &words, word.items);
                word.clearRetainingCapacity();
                started = false;
            }
        } else {
            // These have shell semantics rather than argv semantics. Refuse
            // them unquoted instead of silently executing or interpreting them.
            if (std.mem.indexOfScalar(u8, "|;&<>`$", c) != null) return error.InvalidEditor;
            try word.append(allocator, c);
            started = true;
        }
    }
    if (quote != null or escaped) return error.InvalidEditor;
    if (started) try appendWord(allocator, &words, word.items);
    if (words.items.len == 0 or words.items[0].len == 0 or words.items.len > 31) return error.InvalidEditor;
    try appendWord(allocator, &words, filename);
    return words.toOwnedSlice(allocator);
}

pub fn choose(io: Io, environ: *const std.process.Environ.Map) ![]const u8 {
    for ([_][]const u8{ "EDITOR", "VISUAL" }) |name| {
        if (environ.get(name)) |value| {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len > 0) return trimmed;
        }
    }
    for ([_][]const u8{ "nvim", "vi", "nano" }) |name| {
        var dirs = std.mem.splitScalar(u8, environ.get("PATH") orelse "", ':');
        var path: [4096]u8 = undefined;
        while (dirs.next()) |dir| {
            const full = std.fmt.bufPrint(&path, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
            Io.Dir.cwd().access(io, full, .{ .execute = true }) catch continue;
            return name;
        }
    }
    return error.NoEditor;
}

fn ignoreSignal(_: std.posix.SIG) callconv(.c) void {}
fn replaceHandler(signal: std.posix.SIG, old: *std.posix.Sigaction) void {
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = ignoreSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &action, old);
}

fn waitChild(io: Io, child: *std.process.Child) !std.process.Child.Term {
    return child.wait(io);
}
fn waitCancellation(io: Io, cancellation: *Io.Event) !void {
    try cancellation.wait(io);
}

// Linux ioctl ABI is identical for native and musl builds. Exact0.17's
// std.posix wrappers select std.c with libc but its declarations are absent;
// do not pass the Linux pointer signature to a libc value-signature function.
fn foregroundGroup(fd: std.posix.fd_t) !std.posix.pid_t {
    while (true) {
        var group: std.os.linux.pid_t = undefined;
        switch (std.os.linux.errno(std.os.linux.tcgetpgrp(fd, &group))) {
            .SUCCESS => return group,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .BADF => return error.BadFileDescriptor,
            else => return error.TerminalControlFailed,
        }
    }
}
fn setForegroundGroup(fd: std.posix.fd_t, group: std.posix.pid_t) !void {
    while (true) {
        switch (std.os.linux.errno(std.os.linux.tcsetpgrp(fd, &group))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            .BADF => return error.BadFileDescriptor,
            .PERM => return error.NotAPgrpMember,
            .INVAL => return error.InvalidForegroundGroup,
            else => return error.TerminalControlFailed,
        }
    }
}

pub fn edit(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map, body: []const u8, tty_fd: std.posix.fd_t, cancellation: *Io.Event) !Result {
    if (body.len > types.Limits.body_bytes or !std.unicode.utf8ValidateSlice(body)) return error.InvalidEditorBody;
    const command = try choose(io, environ);
    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const base = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    if (!std.fs.path.isAbsolute(base)) return error.InvalidRuntimeDirectory;
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const directory = try std.fmt.allocPrint(allocator, "{s}/omagma-editor-{s}", .{ base, nonce_hex });
    defer allocator.free(directory);
    try Io.Dir.createDirAbsolute(io, directory, .fromMode(0o700));
    var preserve = false;
    defer if (!preserve) Io.Dir.deleteDirAbsolute(io, directory) catch {};
    var dir = try Io.Dir.openDirAbsolute(io, directory, .{ .follow_symlinks = false });
    defer dir.close(io);
    const filename = try std.fs.path.join(allocator, &.{ directory, "draft.txt" });
    defer allocator.free(filename);
    defer if (!preserve) dir.deleteFile(io, "draft.txt") catch {};
    {
        const file = try dir.createFile(io, "draft.txt", .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, body);
    }
    const argv = try arguments(allocator, command, filename);
    defer {
        for (argv) |word| allocator.free(word);
        allocator.free(argv);
    }

    var old_int: std.posix.Sigaction = undefined;
    var old_quit: std.posix.Sigaction = undefined;
    var old_ttou: std.posix.Sigaction = undefined;
    replaceHandler(.INT, &old_int);
    replaceHandler(.QUIT, &old_quit);
    defer std.posix.sigaction(.INT, &old_int, null);
    defer std.posix.sigaction(.QUIT, &old_quit, null);
    const foreground = try foregroundGroup(tty_fd);
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = environ, .pgid = 0 });
    const process_group = child.id.?;
    // A caught no-op is not SIG_IGN: an orphaned background process group
    // still gets EIO from tcsetpgrp. Ignore TTOU in the parent only after exec,
    // so the editor inherits the normal job-control disposition.
    var ttou_action: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TTOU, &ttou_action, &old_ttou);
    defer std.posix.sigaction(.TTOU, &old_ttou, null);
    // Exec has completed before spawn returns. If the child reached a tty read
    // first, SIGTTIN stopped it; give it the foreground and resume it now.
    defer {
        std.posix.kill(-process_group, .KILL) catch {};
        if (child.id != null) child.kill(io);
        setForegroundGroup(tty_fd, foreground) catch {};
    }
    try setForegroundGroup(tty_fd, process_group);
    std.posix.kill(-process_group, .CONT) catch {};
    const Event = union(enum) { child: anyerror!std.process.Child.Term, canceled: anyerror!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.child, waitChild, .{ io, &child });
    try select.concurrent(.canceled, waitCancellation, .{ io, cancellation });
    const term: std.process.Child.Term = blk: switch (try select.await()) {
        .child => |result| try result,
        .canceled => |result| {
            try result;
            std.posix.kill(-process_group, .KILL) catch {};
            // Read the last saved text after interrupting the editor too.
            // The caller persists it before honoring its termination signal.
            break :blk .{ .exited = 130 };
        },
    };
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 128,
    };
    // Vim-like editors may atomically replace the original file. Open it anew
    // relative to the held private directory, never through a symlink.
    const file = files.openRegular(io, allocator, dir, "draft.txt") catch |err| {
        preserve = true;
        return err;
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| {
        preserve = true;
        return err;
    };
    if (stat.kind != .file or stat.nlink != 1 or stat.size > types.Limits.body_bytes) {
        preserve = true;
        return error.InvalidEditorBody;
    }
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const updated = reader.interface.allocRemaining(allocator, .limited(types.Limits.body_bytes)) catch |err| {
        preserve = true;
        return err;
    };
    errdefer allocator.free(updated);
    if (!std.unicode.utf8ValidateSlice(updated) or std.mem.indexOfScalar(u8, updated, 0) != null) {
        preserve = true;
        return error.InvalidEditorBody;
    }
    return .{ .body = updated, .exit_code = exit_code };
}

test "editor argv quotes arguments and never evaluates shell text" {
    const allocator = std.testing.allocator;
    const argv = try arguments(allocator, "nvim -u 'a b' \"c d\"", "/tmp/private draft.txt");
    defer {
        for (argv) |word| allocator.free(word);
        allocator.free(argv);
    }
    try std.testing.expectEqualStrings("nvim", argv[0]);
    try std.testing.expectEqualStrings("a b", argv[2]);
    try std.testing.expectEqualStrings("c d", argv[3]);
    try std.testing.expectEqualStrings("/tmp/private draft.txt", argv[4]);
    try std.testing.expectError(error.InvalidEditor, arguments(allocator, "nvim; touch bad", "draft"));
    try std.testing.expectError(error.InvalidEditor, arguments(allocator, "nvim $(bad)", "draft"));
    try std.testing.expectError(error.InvalidEditor, arguments(allocator, "nvim 'unterminated", "draft"));
}

fn testArgumentAllocationFailures(allocator: Allocator) !void {
    const argv = try arguments(allocator, "nvim --cmd 'literal a b' \"$(literal)\" --flag", "/tmp/private draft.txt");
    defer {
        for (argv) |word| allocator.free(word);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("$(literal)", argv[3]);
}

test "editor argv releases every allocation at each failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testArgumentAllocationFailures, .{});
}
