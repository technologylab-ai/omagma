//! Explicit, owner-only credential storage for unattended agent processes.
//! Values never enter filenames, argv, JSON replies or diagnostics.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("native_file.zig");
const limits = @import("limits.zig");

pub const Identity = struct { terminal: bool, account: []const u8, client: []const u8, grant: []const u8 = "gmail.readonly" };
pub const Namespace = enum { bar, terminal };
const Metadata = struct { uid: u32, mode: u32, links: u64, size: u64, inode: u64, device: u64 };
extern "c" fn acl_get_fd_np(c_int, c_int) ?*anyopaque;
extern "c" fn acl_get_entry(*anyopaque, c_int, *?*anyopaque) c_int;
extern "c" fn acl_free(*anyopaque) c_int;
extern "c" fn acl_init(c_int) ?*anyopaque;

fn metadata(io: std.Io, fd: std.posix.fd_t) !Metadata {
    while (true) {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var value: linux.Statx = std.mem.zeroes(linux.Statx);
            const code = linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .SIZE = true, .INO = true }, &value));
            if (code == .INTR) {
                try io.checkCancel();
                continue;
            }
            if (code != .SUCCESS or !value.mask.UID or !value.mask.MODE or !value.mask.TYPE or !value.mask.NLINK or !value.mask.SIZE or !value.mask.INO) return error.CredentialMetadataUnavailable;
            return .{ .uid = value.uid, .mode = value.mode, .links = value.nlink, .size = value.size, .inode = value.ino, .device = (@as(u64, value.dev_major) << 32) | value.dev_minor };
        } else if (builtin.os.tag == .macos) {
            var value: std.c.Stat = undefined;
            const code = std.posix.errno(std.c.fstat(fd, &value));
            if (code == .INTR) {
                try io.checkCancel();
                continue;
            }
            if (code != .SUCCESS) return error.CredentialMetadataUnavailable;
            return .{ .uid = value.uid, .mode = value.mode, .links = value.nlink, .size = @intCast(value.size), .inode = value.ino, .device = @as(u32, @bitCast(value.dev)) };
        } else return error.UnsupportedPlatform;
    }
}
fn uid() u32 {
    return if (builtin.os.tag == .linux) std.os.linux.geteuid() else std.c.geteuid();
}
fn noAcl(io: std.Io, fd: std.posix.fd_t, is_directory: bool) !void {
    if (builtin.os.tag == .linux) {
        var buffer: [1]u8 = undefined;
        for ([_][*:0]const u8{ "system.posix_acl_access", "system.posix_acl_default" }, 0..) |name, index| {
            if (index == 1 and !is_directory) continue;
            while (true) {
                const code = std.os.linux.errno(std.os.linux.fgetxattr(fd, name, &buffer, buffer.len));
                switch (code) {
                    .NODATA, .OPNOTSUPP => break,
                    .INTR => {
                        try io.checkCancel();
                        continue;
                    },
                    .ACCES, .PERM => return error.CredentialStorageAccessDenied,
                    else => return error.UnsafeCredentialAcl,
                }
            }
        }
    } else if (builtin.os.tag == .macos) {
        const acl = acl_get_fd_np(fd, 0x00000100) orelse {
            const code = std.posix.errno(@as(c_int, -1));
            if (code == .NOENT or code == .OPNOTSUPP) return;
            return error.CredentialMetadataUnavailable;
        };
        defer _ = acl_free(acl);
        try checkAclEntries(acl);
    }
}
fn checkAclEntries(acl: *anyopaque) !void {
    var entry: ?*anyopaque = null;
    const found = acl_get_entry(acl, 0, &entry);
    if (found < 0) {
        if (entry == null and std.posix.errno(@as(c_int, -1)) == .INVAL) return;
        return error.CredentialMetadataUnavailable;
    }
    if (entry != null) return error.UnsafeCredentialAcl;
}
pub fn sameDirectory(io: std.Io, left: std.Io.Dir, right: std.Io.Dir) !bool {
    const first = try metadata(io, left.handle);
    const second = try metadata(io, right.handle);
    return first.inode == second.inode and first.device == second.device;
}
fn validateMetadata(value: Metadata, owner_uid: u32, is_directory: bool) !void {
    if (value.uid != owner_uid) return error.UnsafeCredentialOwner;
    const kind: u32 = if (is_directory) std.posix.S.IFDIR else std.posix.S.IFREG;
    if (value.mode & std.posix.S.IFMT != kind) return error.UnsafeCredentialFileType;
    if (value.mode & 0o7777 != (if (is_directory) @as(u32, 0o700) else @as(u32, 0o600))) return error.UnsafeCredentialPermissions;
    if (!is_directory and value.links != 1) return error.UnsafeCredentialFile;
}
fn private(io: std.Io, fd: std.posix.fd_t, is_directory: bool) !void {
    try validateMetadata(try metadata(io, fd), uid(), is_directory);
    try noAcl(io, fd, is_directory);
}
pub fn privateFile(io: std.Io, file: std.Io.File) !void {
    try private(io, file.handle, false);
}
fn failure(err: anyerror) anyerror {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.CredentialStorageAccessDenied,
        else => err,
    };
}

/// Walk each component on pinned descriptors; never traverse a symlink.
pub fn directory(io: std.Io, path: []const u8, create: bool) !std.Io.Dir {
    if (path.len < 2 or path.len > 4096 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCredentialDirectory;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    var current = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    errdefer current.close(io);
    var component = parts.next() orelse return error.InvalidCredentialDirectory;
    while (true) {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidCredentialDirectory;
        const next = parts.next();
        const parent = try metadata(io, current.handle);
        if (parent.uid != 0 and parent.uid != uid()) return error.UnsafeCredentialOwner;
        if (parent.mode & 0o022 != 0 and !(parent.uid == 0 and parent.mode & 0o1000 != 0)) return error.UnsafeCredentialPermissions;
        if (next == null and create) current.createDir(io, component, .fromMode(0o700)) catch |err| {
            if (err != error.PathAlreadyExists) return failure(err);
        };
        const opened = current.openDir(io, component, .{ .follow_symlinks = false, .iterate = next == null }) catch |err| return failure(err);
        current.close(io);
        current = opened;
        if (next) |value| component = value else break;
    }
    try private(io, current.handle, true);
    return current;
}
fn digest(parts: []const []const u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        hash.update(part);
        hash.update(&.{0});
    }
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}
fn accountDirectory(io: std.Io, root: std.Io.Dir, account: []const u8, create: bool) !std.Io.Dir {
    const name = digest(&.{ "omagma-credential-account-v1", account });
    if (create) root.createDir(io, &name, .fromMode(0o700)) catch |err| {
        if (err != error.PathAlreadyExists) return failure(err);
    };
    const dir = root.openDir(io, &name, .{ .follow_symlinks = false, .iterate = true }) catch |err| return failure(err);
    errdefer dir.close(io);
    try private(io, dir.handle, true);
    return dir;
}
fn filename(identity: Identity, buffer: *[96]u8) ![]const u8 {
    const hash = digest(&.{ "omagma-credential-value-v1", if (identity.terminal) "terminal" else "bar", identity.account, identity.client, identity.grant });
    return std.fmt.bufPrint(buffer, "{s}-{s}.token", .{ if (identity.terminal) "terminal" else "bar", hash });
}
fn open(io: std.Io, dir: std.Io.Dir, name: []const u8) !std.Io.File {
    var buffer: [128]u8 = undefined;
    if (name.len >= buffer.len) return error.InvalidCredentialFile;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    const terminated = buffer[0..name.len :0];
    const file = native.openAt(io, dir, terminated, .{}) catch |err| return failure(err);
    errdefer file.close(io);
    try privateFile(io, file);
    return file;
}
pub fn lookup(io: std.Io, path: []const u8, identity: Identity, out: []u8) !?[]const u8 {
    if (out.len == 0 or out.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out);
    var root = directory(io, path, false) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer root.close(io);
    var dir = accountDirectory(io, root, identity.account, false) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer dir.close(io);
    var name_buffer: [96]u8 = undefined;
    const file = open(io, dir, try filename(identity, &name_buffer)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    defer std.crypto.secureZero(u8, &buffer);
    const size = try reader.interface.readSliceShort(out);
    if (size == out.len) {
        if (reader.interface.takeByte()) |_| return error.InvalidCredentialFile else |err| if (err != error.EndOfStream) return err;
    }
    if (size == 0) return error.InvalidCredentialFile;
    for (out[0..size]) |byte| if (byte <= 32 or byte >= 127) return error.InvalidCredentialFile;
    return out[0..size];
}
pub fn store(io: std.Io, path: []const u8, identity: Identity, secret: []const u8) !void {
    if (secret.len == 0 or secret.len > limits.secret) return error.InvalidToken;
    for (secret) |byte| if (byte <= 32 or byte >= 127) return error.InvalidToken;
    var root = try directory(io, path, true);
    defer root.close(io);
    var dir = try accountDirectory(io, root, identity.account, true);
    defer dir.close(io);
    var name_buffer: [96]u8 = undefined;
    const name = try filename(identity, &name_buffer);
    if (open(io, dir, name)) |existing| existing.close(io) else |err| if (err != error.FileNotFound) return err;
    var atomic = try dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try privateFile(io, atomic.file);
    try atomic.file.writeStreamingAll(io, secret);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
pub fn clear(io: std.Io, path: []const u8, account: []const u8, namespace: Namespace) !void {
    var root = directory(io, path, false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer root.close(io);
    var dir = accountDirectory(io, root, account, false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    var names: [64][96]u8 = undefined;
    var lengths: [64]usize = undefined;
    var count: usize = 0;
    var scanned: usize = 0;
    const prefix = if (namespace == .bar) "bar-" else "terminal-";
    while (try iterator.next(io)) |entry| {
        scanned += 1;
        if (scanned > 64) return error.TooManyCredentialFiles;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (entry.name.len != prefix.len + 64 + 6 or !std.mem.endsWith(u8, entry.name, ".token")) return error.InvalidCredentialFile;
        for (entry.name[prefix.len..][0..64]) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return error.InvalidCredentialFile;
        const existing = try open(io, dir, entry.name);
        existing.close(io);
        @memcpy(names[count][0..entry.name.len], entry.name);
        lengths[count] = entry.name.len;
        count += 1;
    }
    for (0..count) |index| try dir.deleteFile(io, names[index][0..lengths[index]]);
}

test "file credentials: real descriptor ownership and namespace tuple isolation" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fmt.allocPrint(a, "{s}/credentials", .{parent});
    defer a.free(path);
    const first: Identity = .{ .terminal = true, .account = "a@example.test", .client = "client-one", .grant = &@as([64]u8, @splat('a')) };
    var other = first;
    other.client = "client-two";
    const bar: Identity = .{ .terminal = false, .account = first.account, .client = first.client };
    try store(io, path, first, "synthetic-first");
    try store(io, path, other, "synthetic-other-client");
    try store(io, path, bar, "synthetic-readonly");
    var out: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &out);
    try std.testing.expectEqualStrings("synthetic-first", (try lookup(io, path, first, &out)).?);
    try std.testing.expectEqualStrings("synthetic-other-client", (try lookup(io, path, other, &out)).?);
    try std.testing.expectEqualStrings("synthetic-readonly", (try lookup(io, path, bar, &out)).?);
    other.grant = &@as([64]u8, @splat('b'));
    try std.testing.expect(try lookup(io, path, other, &out) == null);
    other = first;
    other.account = "b@example.test";
    try std.testing.expect(try lookup(io, path, other, &out) == null);
    try clear(io, path, first.account, .terminal);
    try std.testing.expect(try lookup(io, path, first, &out) == null);
    try std.testing.expectEqualStrings("synthetic-readonly", (try lookup(io, path, bar, &out)).?);
    var dir = try directory(io, path, false);
    defer dir.close(io);
    const actual = try metadata(io, dir.handle);
    try std.testing.expectEqual(uid(), actual.uid);
    try std.testing.expectEqual(@as(u32, 0o700), actual.mode & 0o7777);
    var wrong = actual;
    wrong.uid += 1;
    try std.testing.expectError(error.UnsafeCredentialOwner, validateMetadata(wrong, uid(), true));
}

test "file credentials: reject broad permissions symlinks malformed and oversized values" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fmt.allocPrint(a, "{s}/credentials", .{parent});
    defer a.free(path);
    const identity: Identity = .{ .terminal = false, .account = "a@example.test", .client = "fixture-client" };
    try store(io, path, identity, "synthetic-secret");
    var root = try directory(io, path, false);
    defer root.close(io);
    var dir = try accountDirectory(io, root, identity.account, false);
    defer dir.close(io);
    var name_buffer: [96]u8 = undefined;
    const name = try filename(identity, &name_buffer);
    var output: [4096]u8 = @splat('x');
    defer std.crypto.secureZero(u8, &output);
    {
        const record = try dir.openFile(io, name, .{ .mode = .read_write });
        defer record.close(io);
        try record.setPermissions(io, .fromMode(0o644));
    }
    try std.testing.expectError(error.UnsafeCredentialPermissions, lookup(io, path, identity, &output));
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try dir.deleteFile(io, name);
    try dir.symLink(io, "unrelated-file", name, .{});
    if (lookup(io, path, identity, &output)) |_| return error.SymlinkWasAccepted else |_| {}
    if (store(io, path, identity, "replacement")) |_| return error.SymlinkWasOverwritten else |_| {}
    try dir.deleteFile(io, name);
    {
        const record = try dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        defer record.close(io);
        try record.writeStreamingAll(io, "bad\nsecret");
    }
    try std.testing.expectError(error.InvalidCredentialFile, lookup(io, path, identity, &output));
    try dir.deleteFile(io, name);
    {
        const record = try dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        defer record.close(io);
        const too_large: [4097]u8 = @splat('x');
        try record.writeStreamingAll(io, &too_large);
    }
    try std.testing.expectError(error.InvalidCredentialFile, lookup(io, path, identity, &output));
    try tmp.dir.symLink(io, "credentials", "alias", .{ .is_directory = true });
    const alias = try std.fmt.allocPrint(a, "{s}/alias", .{parent});
    defer a.free(alias);
    if (directory(io, alias, false)) |accepted| {
        accepted.close(io);
        return error.SymlinkDirectoryWasAccepted;
    } else |_| {}
    try std.testing.expectError(error.InvalidCredentialDirectory, directory(io, "relative/credentials", false));
    var wrong = try metadata(io, root.handle);
    wrong.mode = std.posix.S.IFDIR | 0o755;
    try std.testing.expectError(error.UnsafeCredentialPermissions, validateMetadata(wrong, uid(), true));
    wrong.mode = std.posix.S.IFREG | 0o600;
    wrong.links = 2;
    try std.testing.expectError(error.UnsafeCredentialFile, validateMetadata(wrong, uid(), false));
    wrong.mode = std.posix.S.IFIFO | 0o600;
    wrong.links = 1;
    try std.testing.expectError(error.UnsafeCredentialFileType, validateMetadata(wrong, uid(), false));
}

test "file credentials: native empty Darwin ACL is accepted" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const empty = acl_init(0) orelse return error.CredentialMetadataUnavailable;
    defer _ = acl_free(empty);
    try checkAclEntries(empty);
}
