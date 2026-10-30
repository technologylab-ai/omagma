//! Standalone ciphertext persistence. Callers select a durable data directory
//! for retained mail and a separate durable config/data directory for headers.
//! There is no plaintext fallback, migration, path discovery or live integration.
const std = @import("std");
const builtin = @import("builtin");
const t = @import("vault_types.zig");
const crypto = @import("vault_crypto.zig");
const private = @import("../keyring_file.zig");
const native = @import("../native_file.zig");

comptime {
    if (t.max_record_bytes < @import("types.zig").Limits.incoming_attachment_bytes or
        t.max_record_bytes < @import("types.zig").Limits.mime_upload_bytes or
        t.max_record_bytes < @import("store.zig").index_read_bytes)
        @compileError("vault record cap must cover attachments, MIME and index reads");
}

pub const Handle = struct {
    bytes: [32]u8,
    pub fn create(io: std.Io) !Handle {
        var value: Handle = undefined;
        try io.randomSecure(&value.bytes);
        return value;
    }
    pub fn text(self: Handle) [64]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }
    pub fn parse(value: []const u8) !Handle {
        if (value.len != 64) return error.InvalidVaultHandle;
        for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidVaultHandle;
        var result: Handle = undefined;
        _ = std.fmt.hexToBytes(&result.bytes, value) catch return error.InvalidVaultHandle;
        return result;
    }
    pub fn filename(self: Handle) [73:0]u8 {
        var result: [73:0]u8 = undefined;
        @memcpy(result[0..5], "vrec-");
        @memcpy(result[5..69], &self.text());
        @memcpy(result[69..73], ".bin");
        result[73] = 0;
        return result;
    }
};

/// Random handle is the object identity, chosen before any plaintext arrives.
/// The encrypted index maps logical message/draft IDs to these handles. The
/// adapter pins revision 1 until an independently trusted counter exists.
pub const Record = struct { account: []const u8, kind: t.RecordKind, handle: Handle };
pub fn binding(record: Record, handle_text: *const [64]u8) t.Binding {
    return .{ .account = record.account, .kind = record.kind, .record_id = handle_text, .revision = 1 };
}

pub const PublishState = enum { staging, published, durable, aborted };
pub const Step = enum { created, write, file_synced, published, directory_synced };
/// Failure injection exists only in tests; no callbacks in production builds.
pub const Faults = if (builtin.is_test) struct {
    context: ?*anyopaque = null,
    visit: ?*const fn (?*anyopaque, Step) anyerror!void = null,
    fn at(self: @This(), step: Step) !void {
        if (self.visit) |visit| try visit(self.context, step);
    }
} else struct {
    fn at(_: @This(), _: Step) !void {}
};

pub fn syncDirectory(io: std.Io, dir: std.Io.Dir) !void {
    const file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

pub fn openPrivate(io: std.Io, dir: std.Io.Dir, name: [*:0]const u8) !std.Io.File {
    const file = try native.openAt(io, dir, name, .{});
    errdefer file.close(io);
    try private.privateFile(io, file);
    return file;
}

fn removeUncancelable(io: std.Io, dir: std.Io.Dir, name: []const u8) void {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    dir.deleteFile(io, name) catch {};
}

const temp_prefix = ".vault-tmp-";
const temp_suffix = ".part";
const temp_bytes = temp_prefix.len + 32 + temp_suffix.len;
fn tempName(name: []const u8) bool {
    if (name.len != temp_bytes or !std.mem.startsWith(u8, name, temp_prefix) or !std.mem.endsWith(u8, name, temp_suffix)) return false;
    for (name[temp_prefix.len..][0..32]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

/// Must hold the directory lease. Never deletes records, headers, unrelated
/// files or active writers; every matching orphan contains ciphertext only.
pub fn recoverTemps(io: std.Io, dir: std.Io.Dir) !void {
    var entries = dir.iterate();
    var removed = false;
    while (try entries.next(io)) |entry| {
        if (!tempName(entry.name)) continue;
        var name: [temp_bytes:0]u8 = undefined;
        @memcpy(&name, entry.name);
        name[temp_bytes] = 0;
        const file = try openPrivate(io, dir, &name);
        file.close(io);
        try dir.deleteFile(io, entry.name);
        removed = true;
    }
    if (removed) try syncDirectory(io, dir);
}

/// Shared persistence primitive for ciphertext records and encrypted headers.
/// All writes have an exact admitted length. Keep this object at a stable
/// address while a crypto StagingSink refers to it. deinit is always required.
pub const AtomicFile = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    /// Replacements hold the old inode exclusively until cleanup. Readers
    /// hold it shared, so a normal rename cannot invalidate an active export.
    previous: ?std.Io.File,
    target: [96:0]u8,
    target_len: usize,
    temp: [temp_bytes:0]u8,
    expected: usize,
    count: usize = 0,
    replace: bool,
    state: PublishState = .staging,
    file_open: bool = true,
    durability_cause: ?anyerror = null,
    faults: Faults = .{},

    pub fn init(io: std.Io, dir: std.Io.Dir, target: []const u8, size: usize, replace: bool, faults: Faults) !AtomicFile {
        if (target.len == 0 or target.len > 96 or std.mem.indexOfAny(u8, target, "/\\\x00") != null or std.mem.eql(u8, target, ".") or std.mem.eql(u8, target, "..")) return error.InvalidVaultPath;
        var destination: [96:0]u8 = @splat(0);
        @memcpy(destination[0..target.len], target);
        const previous: ?std.Io.File = openPrivate(io, dir, &destination) catch |err| if (err == error.FileNotFound) null else return err;
        if (previous) |old| {
            errdefer old.close(io);
            if (!replace) return error.PathAlreadyExists;
            if (!try old.tryLock(io, .exclusive)) return error.VaultBusy;
        }
        errdefer if (previous) |old| {
            old.unlock(io);
            old.close(io);
        };
        var nonce: [16]u8 = undefined;
        try io.randomSecure(&nonce);
        var temp: [temp_bytes:0]u8 = undefined;
        _ = try std.fmt.bufPrint(&temp, temp_prefix ++ "{s}" ++ temp_suffix, .{std.fmt.bytesToHex(nonce, .lower)});
        temp[temp_bytes] = 0;
        const file = try dir.createFile(io, &temp, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        errdefer {
            file.close(io);
            removeUncancelable(io, dir, &temp);
        }
        try private.privateFile(io, file);
        try faults.at(.created);
        return .{ .io = io, .dir = dir, .file = file, .previous = previous, .target = destination, .target_len = target.len, .temp = temp, .expected = size, .replace = replace, .faults = faults };
    }

    pub fn write(self: *AtomicFile, bytes: []const u8) !void {
        if (self.state != .staging) return error.VaultStreamClosed;
        if (bytes.len > self.expected - self.count) return error.VaultLengthMismatch;
        try self.file.writeStreamingAll(self.io, bytes);
        self.count += bytes.len;
        try self.faults.at(.write);
    }

    pub fn commit(self: *AtomicFile) !void {
        if (self.state != .staging) return error.VaultStreamClosed;
        if (self.count != self.expected) return error.VaultLengthMismatch;
        try self.file.sync(self.io);
        try self.faults.at(.file_synced);
        // If no target existed at admission, never replace a record that
        // appeared meanwhile: we hold no lock protecting that newer inode.
        if (self.replace and self.previous != null) {
            try self.dir.rename(&self.temp, self.dir, self.target[0..self.target_len], self.io);
        } else try self.dir.renamePreserve(&self.temp, self.dir, self.target[0..self.target_len], self.io);
        // From here the old value is gone. Never report/perform a rollback.
        self.state = .published;
        self.faults.at(.published) catch |err| return self.uncertain(err);
        syncDirectory(self.io, self.dir) catch |err| return self.uncertain(err);
        self.state = .durable;
        self.faults.at(.directory_synced) catch |err| return self.uncertain(err);
    }

    fn uncertain(self: *AtomicFile, cause: anyerror) error{VaultDurabilityUncertain} {
        self.durability_cause = cause;
        return error.VaultDurabilityUncertain;
    }
    pub fn abort(self: *AtomicFile) void {
        if (self.state != .staging) return;
        self.state = .aborted;
        removeUncancelable(self.io, self.dir, &self.temp);
    }
    pub fn deinit(self: *AtomicFile) void {
        self.abort();
        if (self.file_open) self.file.close(self.io);
        self.file_open = false;
        if (self.previous) |old| {
            old.unlock(self.io);
            old.close(self.io);
            self.previous = null;
        }
    }
    pub fn sink(self: *AtomicFile) t.StagingSink {
        return .{ .context = self, .writeFn = writeCallback, .commitFn = commitCallback, .abortFn = abortCallback };
    }
    fn writeCallback(context: *anyopaque, bytes: []const u8) !void {
        const self: *AtomicFile = @ptrCast(@alignCast(context));
        try self.write(bytes);
    }
    fn commitCallback(context: *anyopaque) !void {
        const self: *AtomicFile = @ptrCast(@alignCast(context));
        try self.commit();
    }
    fn abortCallback(context: *anyopaque) void {
        const self: *AtomicFile = @ptrCast(@alignCast(context));
        self.abort();
    }
    pub const testing = if (builtin.is_test) struct {
        /// Model process death: descriptor closes but no deferred unlink runs.
        pub fn crash(self: *AtomicFile) void {
            if (self.file_open) self.file.close(self.io);
            self.file_open = false;
            if (self.previous) |old| {
                old.unlock(self.io);
                old.close(self.io);
                self.previous = null;
            }
            self.state = .aborted;
        }
    } else struct {};
};

/// The single daemon owns this lease through pending writer cleanup. Reopening
/// after a crash recovers only orphaned ciphertext scratch. It is intentionally
/// nonblocking; independent sessions cannot race cleanup with a new writer.
pub const Directory = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lease: std.Io.File,
    closed: bool = false,
    pub fn open(io: std.Io, absolute_path: []const u8, create: bool) !Directory {
        const dir = try private.directory(io, absolute_path, create);
        errdefer dir.close(io);
        const lease = dir.createFile(io, ".vault-lock", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| if (err == error.PathAlreadyExists)
            try native.openAt(io, dir, ".vault-lock", .{ .read_write = true })
        else
            return err;
        errdefer lease.close(io);
        try private.privateFile(io, lease);
        if ((try lease.stat(io)).size != 0) return error.InvalidVaultLock;
        if (!try lease.tryLock(io, .exclusive)) return error.VaultBusy;
        errdefer lease.unlock(io);
        try recoverTemps(io, dir);
        if (create) {
            // Sync the directory's own name too. Syncing only its contents is
            // insufficient when this call has just created the directory.
            const parent = try dir.openDir(io, "..", .{ .follow_symlinks = false, .iterate = true });
            defer parent.close(io);
            try syncDirectory(io, dir);
            try syncDirectory(io, parent);
        }
        return .{ .io = io, .dir = dir, .lease = lease };
    }
    pub fn close(self: *Directory) void {
        if (self.closed) return;
        self.closed = true;
        self.lease.unlock(self.io);
        self.lease.close(self.io);
        self.dir.close(self.io);
    }
    pub fn begin(self: *Directory, handle: Handle, size: usize, replace: bool, faults: Faults) !AtomicFile {
        if (self.closed) return error.VaultStreamClosed;
        return AtomicFile.init(self.io, self.dir, &handle.filename(), try t.sealedStreamSize(size), replace, faults);
    }
    pub fn seal(self: *Directory, key: *const t.DataKey, record: Record, size: usize, source: t.Source, workspace: *t.StreamWorkspace, replace: bool) !void {
        defer workspace.wipe();
        if (size > t.recordLimit(record.kind)) return error.VaultRecordTooLarge;
        var output = try self.begin(record.handle, size, replace, .{});
        defer output.deinit();
        const handle_text = record.handle.text();
        try crypto.sealStream(self.io, key, binding(record, &handle_text), size, source, output.sink(), workspace);
    }
    pub fn reader(self: *Directory, handle: Handle) !Reader {
        if (self.closed) return error.VaultStreamClosed;
        const name = handle.filename();
        const file = try openPrivate(self.io, self.dir, &name);
        errdefer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > try t.sealedStreamSize(t.max_stream_record_bytes)) return error.VaultRecordTooLarge;
        if (!try file.tryLock(self.io, .shared)) return error.VaultBusy;
        return .{ .io = self.io, .file = file, .initial = stat };
    }
};

pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    initial: std.Io.File.Stat,
    offset: u64 = 0,
    closed: bool = false,
    pub fn close(self: *Reader) void {
        if (self.closed) return;
        self.closed = true;
        self.file.unlock(self.io);
        self.file.close(self.io);
    }
    pub fn unchanged(self: *Reader) !void {
        const now = try self.file.stat(self.io);
        if (now.inode != self.initial.inode or now.size != self.initial.size or now.mtime.toNanoseconds() != self.initial.mtime.toNanoseconds() or now.ctime.toNanoseconds() != self.initial.ctime.toNanoseconds()) return error.VaultRecordChanged;
        try private.privateFile(self.io, self.file);
    }
    pub fn source(self: *Reader) t.Source {
        return .{ .context = self, .readFn = read };
    }
    fn read(context: *anyopaque, bytes: []u8) !usize {
        const self: *Reader = @ptrCast(@alignCast(context));
        if (self.closed) return error.VaultStreamClosed;
        const count = try self.file.readPositional(self.io, &.{bytes}, self.offset);
        self.offset += count;
        return count;
    }
    pub fn verify(self: *Reader, key: *const t.DataKey, record: Record, workspace: *t.StreamWorkspace) !usize {
        defer workspace.wipe();
        try self.unchanged();
        self.offset = 0;
        const handle_text = record.handle.text();
        const count = try crypto.verifyStream(self.io, key, binding(record, &handle_text), self.source(), workspace);
        try self.unchanged();
        return count;
    }
    /// Consumers receive no bytes until a full verification pass succeeds.
    /// The pinned descriptor is re-read, authenticating each chunk again. All
    /// vault writes use atomic replacement, never mutation of published files.
    /// A replacement returns VaultBusy while this reader retains its shared
    /// lock, including the entire verification/export transaction.
    /// A malicious same-user writer can still modify an open inode; callers
    /// must treat a second-pass error as unknown outcome for network effects.
    pub fn exportVerified(self: *Reader, key: *const t.DataKey, record: Record, destination: t.StagingSink, workspace: *t.StreamWorkspace) !void {
        _ = self.verify(key, record, workspace) catch |err| {
            destination.abortFn(destination.context);
            return err;
        };
        self.offset = 0;
        const handle_text = record.handle.text();
        var guarded: GuardedSink = .{ .reader = self, .destination = destination };
        try crypto.openStream(self.io, key, binding(record, &handle_text), self.source(), guarded.sink(), workspace);
    }
    const GuardedSink = struct {
        reader: *Reader,
        destination: t.StagingSink,
        fn sink(self: *GuardedSink) t.StagingSink {
            return .{ .context = self, .writeFn = write, .commitFn = commit, .abortFn = abort };
        }
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *GuardedSink = @ptrCast(@alignCast(context));
            try self.reader.unchanged();
            try self.destination.writeFn(self.destination.context, bytes);
        }
        fn commit(context: *anyopaque) !void {
            const self: *GuardedSink = @ptrCast(@alignCast(context));
            try self.reader.unchanged();
            try self.destination.commitFn(self.destination.context);
        }
        fn abort(context: *anyopaque) void {
            const self: *GuardedSink = @ptrCast(@alignCast(context));
            self.destination.abortFn(self.destination.context);
        }
    };
};

/// Explicit plaintext boundary only: caller creates an empty private export
/// file and deletes its path after any failure. This adapter never chooses a
/// path. Abort truncates partial output, including a failed second pass.
pub const ExportFile = struct {
    io: std.Io,
    file: std.Io.File,
    count: u64 = 0,
    committed: bool = false,
    abort_error: ?anyerror = null,
    pub fn init(io: std.Io, file: std.Io.File) !ExportFile {
        try private.privateFile(io, file);
        if ((try file.stat(io)).size != 0) return error.VaultExportNotEmpty;
        return .{ .io = io, .file = file };
    }
    pub fn sink(self: *ExportFile) t.StagingSink {
        return .{ .context = self, .writeFn = write, .commitFn = commit, .abortFn = abort };
    }
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *ExportFile = @ptrCast(@alignCast(context));
        if (self.committed) return error.VaultStreamClosed;
        try self.file.writePositionalAll(self.io, bytes, self.count);
        self.count += bytes.len;
    }
    fn commit(context: *anyopaque) !void {
        const self: *ExportFile = @ptrCast(@alignCast(context));
        try self.file.sync(self.io);
        self.committed = true;
    }
    fn abort(context: *anyopaque) void {
        const self: *ExportFile = @ptrCast(@alignCast(context));
        if (self.committed) return;
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);
        self.file.setLength(self.io, 0) catch |err| {
            self.abort_error = err;
            return;
        };
        self.count = 0;
    }
};
