//! Direct-argv external editing of temporary drafts or received-mail snapshots.
//! No shell/multiplexer. The caller suspends/restores its renderer; received
//! snapshot edits are discarded, while compose retains its existing readback.
const std = @import("std");
const types = @import("types.zig");
const files = @import("files.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const darwin = struct {
    extern "c" fn tcgetpgrp(fd: c_int) c_int;
    extern "c" fn tcsetpgrp(fd: c_int, group: c_int) c_int;
};

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
    return @import("../platform.zig").waitOwned(io, child);
}
fn waitCancellation(io: Io, cancellation: *Io.Event) !void {
    try cancellation.wait(io);
}

// Linux ioctl ABI is identical for native and musl builds. Exact0.17's
// std.posix wrappers select std.c with libc but its declarations are absent;
// do not pass the Linux pointer signature to a libc value-signature function.
fn foregroundGroup(fd: std.posix.fd_t) !std.posix.pid_t {
    if (@import("builtin").os.tag == .macos) while (true) {
        const group = darwin.tcgetpgrp(fd);
        switch (std.posix.errno(group)) {
            .SUCCESS => return group,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .BADF => return error.BadFileDescriptor,
            else => return error.TerminalControlFailed,
        }
    };
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
    if (@import("builtin").os.tag == .macos) while (true) {
        switch (std.posix.errno(darwin.tcsetpgrp(fd, group))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            .BADF => return error.BadFileDescriptor,
            .PERM => return error.NotAPgrpMember,
            .INVAL => return error.InvalidForegroundGroup,
            else => return error.TerminalControlFailed,
        }
    };
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

/// Shared direct-argv launch, terminal ownership, signal restoration and reap.
/// No text readback happens here: compose and received snapshots differ there.
fn run(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map, command: []const u8, filename: []const u8, tty_fd: std.posix.fd_t, cancellation: *Io.Event) !u8 {
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
        if (child.id != null) @import("../platform.zig").killOwned(io, &child);
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
            // The caller decides whether to retain draft readback or discard a
            // received-mail snapshot after the owned editor has been interrupted.
            break :blk .{ .exited = 130 };
        },
    };
    return switch (term) {
        .exited => |code| code,
        else => 128,
    };
}

fn validateSnapshotSize(length: usize) !void {
    if (length > types.Limits.compose_body_bytes + 64 * 1024) return error.InvalidEditorBody;
}

const Snapshot = struct {
    allocator: Allocator,
    parent: Io.Dir,
    dir: Io.Dir,
    filename: []u8,
    name: [46]u8,

    fn create(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map, text: []const u8) !Snapshot {
        // Allow the native body plus bounded textual envelope headers.
        try validateSnapshotSize(text.len);
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidEditorBody;
        const base = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
        if (!std.fs.path.isAbsolute(base)) return error.InvalidRuntimeDirectory;
        // /tmp is a system alias on macOS. Resolve that trusted base once, then
        // hold its directory for creation/removal rather than re-following it.
        const canonical = try Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
        defer allocator.free(canonical);
        var parent = try Io.Dir.openDirAbsolute(io, canonical, .{ .follow_symlinks = false });
        errdefer parent.close(io);
        var nonce: [16]u8 = undefined;
        try io.randomSecure(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        var name: [46]u8 = undefined;
        _ = try std.fmt.bufPrint(&name, "omagma-reader-{s}", .{nonce_hex});
        try parent.createDir(io, &name, .fromMode(0o700));
        errdefer removeSnapshotTree(io, parent, &name) catch {};
        const filename = try std.fmt.allocPrint(allocator, "{s}/{s}/message.txt", .{ canonical, name });
        errdefer allocator.free(filename);
        const directory = std.fs.path.dirname(filename).?;
        // Reuse descriptor-based private-file metadata checks (owner/mode/ACL),
        // without reading or using any credential records.
        const private_files = @import("../keyring_file.zig");
        var dir = try private_files.directory(io, directory, false);
        errdefer dir.close(io);
        const file = try dir.createFile(io, "message.txt", .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try private_files.privateFile(io, file);
        try file.writeStreamingAll(io, text);
        return .{ .allocator = allocator, .parent = parent, .dir = dir, .filename = filename, .name = name };
    }

    fn remove(self: *const Snapshot, io: Io) !void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        // The editor can change the temp directory's mode; restore access on
        // its held descriptor, never through a substituted path.
        try self.dir.setPermissions(io, .fromMode(0o700));
        try self.parent.deleteTree(io, &self.name);
    }

    fn deinit(self: *Snapshot, io: Io) void {
        self.dir.close(io);
        self.parent.close(io);
        self.allocator.free(self.filename);
        self.* = undefined;
    }
};

fn removeSnapshotTree(io: Io, parent: Io.Dir, name: []const u8) !void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // deleteTree unlinks symlinks and special files without opening their
    // contents. Directory replacements and editor backup/swap files go too.
    try parent.deleteTree(io, name);
}

/// Open an immutable received-message copy in the configured external editor.
/// The caller prepares a sanitized plaintext envelope/body and owns terminal
/// renderer suspension/restoration. Local editor changes are never read back.
pub fn view(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map, snapshot: []const u8, tty_fd: std.posix.fd_t, cancellation: *Io.Event) !u8 {
    const command = try choose(io, environ);
    var temporary = try Snapshot.create(io, allocator, environ, snapshot);
    defer temporary.deinit(io);
    // Capture launch failure/cancellation as well as success, and remove the
    // complete private tree before propagating any result. Compose's recovery
    // preservation is deliberately absent from this disposable snapshot path.
    const result = run(io, allocator, environ, command, temporary.filename, tty_fd, cancellation);
    try temporary.remove(io);
    return result;
}

pub fn edit(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map, body: []const u8, tty_fd: std.posix.fd_t, cancellation: *Io.Event) !Result {
    if (body.len > types.Limits.compose_body_bytes or !std.unicode.utf8ValidateSlice(body)) return error.InvalidEditorBody;
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
    const exit_code = try run(io, allocator, environ, command, filename, tty_fd, cancellation);
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
    if (stat.kind != .file or stat.nlink != 1 or stat.size > types.Limits.compose_body_bytes) {
        preserve = true;
        return error.InvalidEditorBody;
    }
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const updated = reader.interface.allocRemaining(allocator, .limited(types.Limits.compose_body_bytes)) catch |err| {
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

fn snapshotTestFile(io: Io, dir: Io.Dir, name: []const u8, text: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

test "received editor snapshot is private and removes replacements without following symlinks" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    const original = "From: Alex <alex@example.org>\nSubject: Fictional received mail\n\nCafé 👋 — full plain text.\n";
    const outside = try std.fs.path.join(allocator, &.{ base, "outside-sentinel.txt" });
    defer allocator.free(outside);
    try snapshotTestFile(io, tmp.dir, "outside-sentinel.txt", "untouched sentinel");

    const Replacement = enum { atomic_file, deleted, invalid_bytes, symlink, directory };
    inline for (std.meta.tags(Replacement)) |replacement| {
        var temporary = try Snapshot.create(io, allocator, &environ, original);
        defer temporary.deinit(io);
        try std.testing.expectEqualStrings("message.txt", std.fs.path.basename(temporary.filename));
        const directory_stat = try temporary.dir.stat(io);
        try std.testing.expectEqual(@as(u32, 0o700), directory_stat.permissions.toMode() & 0o777);
        const file_stat = try temporary.dir.statFile(io, "message.txt", .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
        const copied = try files.readBounded(io, allocator, temporary.dir, "message.txt", types.Limits.compose_body_bytes + 64 * 1024);
        defer allocator.free(copied);
        try std.testing.expectEqualStrings(original, copied);
        // Editors can leave other files or replace the initial file atomically.
        try snapshotTestFile(io, temporary.dir, "message.txt~", "private editor backup");
        switch (replacement) {
            .atomic_file => {
                try snapshotTestFile(io, temporary.dir, "replacement", "changed snapshot only");
                try temporary.dir.rename("replacement", temporary.dir, "message.txt", io);
            },
            .deleted => try temporary.dir.deleteFile(io, "message.txt"),
            .invalid_bytes => try snapshotTestFile(io, temporary.dir, "message.txt", &.{ 0xff, 0x00 }),
            .symlink => {
                try temporary.dir.deleteFile(io, "message.txt");
                try temporary.dir.symLink(io, outside, "message.txt", .{});
            },
            .directory => {
                try temporary.dir.deleteFile(io, "message.txt");
                try temporary.dir.createDir(io, "message.txt", .fromMode(0o700));
                try snapshotTestFile(io, temporary.dir, "message.txt/nested", "private nested editor artifact");
            },
        }
        // A private directory made unreadable by the editor must still be
        // discarded using the held descriptor, without widening other paths.
        try temporary.dir.setPermissions(io, .fromMode(0o000));
        try temporary.remove(io);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &temporary.name, .{}));
        const sentinel = try files.readBounded(io, allocator, tmp.dir, "outside-sentinel.txt", 64);
        defer allocator.free(sentinel);
        try std.testing.expectEqualStrings("untouched sentinel", sentinel);
    }
}

fn testSnapshotAllocationFailures(allocator: Allocator, environ: *const std.process.Environ.Map) !void {
    var temporary = try Snapshot.create(std.testing.io, allocator, environ, "Subject: Fixture\n\nReceived plaintext snapshot\n");
    defer temporary.deinit(std.testing.io);
    try temporary.remove(std.testing.io);
}

test "received editor snapshot allocation failures leave no private copies" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    try std.testing.checkAllAllocationFailures(allocator, testSnapshotAllocationFailures, .{&environ});
    // This fails before tty handoff/spawn, after the private snapshot exists.
    // A viewer failure must discard it rather than use compose preservation.
    try environ.put("EDITOR", "nvim; touch must-not-run");
    var cancellation: Io.Event = .unset;
    try std.testing.expectError(error.InvalidEditor, view(io, allocator, &environ, "Received copy\n", -1, &cancellation));
    var entries = tmp.dir.iterate();
    try std.testing.expectEqual(@as(?Io.Dir.Entry, null), try entries.next(io));
}

test "received editor snapshot refuses invalid or oversized input before creating files" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try std.testing.expectError(error.InvalidEditorBody, Snapshot.create(std.testing.io, allocator, &environ, &.{0xff}));
    try std.testing.expectError(error.InvalidEditorBody, Snapshot.create(std.testing.io, allocator, &environ, "text\x00hidden"));
    try std.testing.expectError(error.InvalidEditorBody, validateSnapshotSize(types.Limits.compose_body_bytes + 64 * 1024 + 1));
}
