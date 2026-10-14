//! Variable-length network staging: one private ciphertext-only temporary file.
//! Each 64 KiB segment is an existing v1 record with a distinct revision. No
//! segment is published in the index. EOF fixes the exact size before copying
//! to an ordinary immutable attachment record in a fresh Store transaction.
const std = @import("std");
const catalog = @import("vault_catalog.zig");
const crypto = @import("vault_crypto.zig");
const t = @import("vault_types.zig");
const storage = @import("vault_storage.zig");

pub const Download = struct {
    account: *catalog.Account,
    file: std.Io.File,
    name: [48:0]u8,
    handle: storage.Handle,
    limit: usize,
    accepted: usize = 0,
    buffered: usize = 0,
    segments: u64 = 0,
    finished: bool = false,
    closed: bool = false,
    pinned: bool = true,
    initial: ?std.Io.File.Stat = null,

    pub fn reservation(limit: usize) !usize {
        const chunks = std.math.divCeil(usize, limit, t.chunk_bytes) catch unreachable;
        return limit + chunks * (t.record_header_bytes + 2 * t.tag_bytes);
    }
    pub fn create(account: *catalog.Account, limit: usize) !Download {
        try account.pinWorkspace();
        errdefer account.unpinWorkspace();
        const io = account.directory.io;
        const handle = try storage.Handle.create(io);
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        var name: [48:0]u8 = undefined;
        @memcpy(name[0..11], ".vault-tmp-"[0..11]);
        @memcpy(name[43..48], ".part"[0..5]);
        name[48] = 0;
        var result: Download = .{ .account = account, .file = undefined, .name = name, .handle = handle, .limit = limit };
        @memcpy(result.name[11..43], &std.fmt.bytesToHex(random, .lower));
        result.file = try account.directory.dir.createFile(io, &result.name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive });
        // The logical reservation remains charged while Store is released.
        errdefer {
            result.file.close(io);
            account.directory.dir.deleteFile(io, &result.name) catch {};
        }
        try result.file.setLength(io, try reservation(limit));
        return result;
    }
    fn identity(self: *const Download, text: *const [64]u8, index: u64) t.Binding {
        return .{ .account = self.account.entry.address(), .kind = .attachment, .record_id = text, .revision = index + 2 };
    }
    fn sinkWrite(context: *anyopaque, bytes: []const u8) !void {
        const self: *Download = @ptrCast(@alignCast(context));
        try self.file.writeStreamingAll(self.account.directory.io, bytes);
    }
    fn sinkCommit(_: *anyopaque) !void {}
    fn sinkAbort(_: *anyopaque) void {}
    fn flush(self: *Download) !void {
        if (self.buffered == 0) return;
        const text = self.handle.text();
        const buffer = &self.account.owner.workspace.plaintext;
        var sealer = try crypto.PushSealer.initInPlace(self.account.directory.io, self.account.owner.key, self.identity(&text, self.segments), self.buffered, .{ .context = self, .writeFn = sinkWrite, .commitFn = sinkCommit, .abortFn = sinkAbort }, buffer);
        defer sealer.abort();
        try sealer.write(buffer[0..self.buffered]);
        try sealer.finish();
        self.buffered = 0;
        self.segments += 1;
    }
    pub fn write(self: *Download, bytes: []const u8) !void {
        if (self.closed or self.finished or !self.pinned or self.account.closed) return error.VaultStreamClosed;
        errdefer self.close();
        if (bytes.len > self.limit - self.accepted) return error.AttachmentsTooLarge;
        var rest = bytes;
        while (rest.len != 0) {
            const count = @min(rest.len, t.chunk_bytes - self.buffered);
            @memcpy(self.account.owner.workspace.plaintext[self.buffered..][0..count], rest[0..count]);
            self.buffered += count;
            self.accepted += count;
            rest = rest[count..];
            if (self.buffered == t.chunk_bytes) try self.flush();
        }
    }
    pub fn finish(self: *Download, exact: usize) !void {
        if (self.closed or self.finished) return error.VaultStreamClosed;
        errdefer self.close();
        if (exact != self.accepted) return error.BodySizeMismatch;
        try self.flush();
        const wire = self.accepted + self.segments * (t.record_header_bytes + 2 * t.tag_bytes);
        try self.file.setLength(self.account.directory.io, wire);
        try self.file.sync(self.account.directory.io);
        self.initial = try self.file.stat(self.account.directory.io);
        self.finished = true;
        self.account.unpinWorkspace();
        self.pinned = false;
    }
    pub fn close(self: *Download) void {
        if (self.closed) return;
        self.closed = true;
        self.file.close(self.account.directory.io);
        self.account.directory.dir.deleteFile(self.account.directory.io, &self.name) catch {};
        if (self.pinned) {
            std.crypto.secureZero(u8, &self.account.owner.workspace.plaintext);
            self.account.unpinWorkspace();
            self.pinned = false;
        }
    }
    fn unchanged(self: *Download) !void {
        if (self.closed or !self.finished or self.account.closed) return error.VaultStreamClosed;
        const now = try self.file.stat(self.account.directory.io);
        const initial = self.initial.?;
        if (initial.inode != now.inode or initial.size != now.size or initial.ctime.toNanoseconds() != now.ctime.toNanoseconds() or initial.mtime.toNanoseconds() != now.mtime.toNanoseconds()) return error.VaultRecordChanged;
        try @import("../keyring_file.zig").privateFile(self.account.directory.io, self.file);
    }
};

pub const Reader = struct {
    download: *Download,
    offset: u64 = 0,
    wire_left: usize = 0,
    index: u64 = 0,
    remaining: usize,
    part_size: usize = 0,
    pull: ?crypto.PullReader = null,
    failed: bool = false,
    pub fn init(download: *Download) !Reader {
        try download.account.requireActive();
        if (download.account.reader_owner != null) return error.VaultBusy;
        try download.unchanged();
        var result: Reader = .{ .download = download, .remaining = download.accepted };
        defer std.crypto.secureZero(u8, &download.account.owner.workspace.ciphertext);
        while (result.remaining != 0) {
            try result.begin();
            try result.pull.?.verifyAll();
            result.pull.?.close();
            result.pull = null;
            result.remaining -= result.part_size;
            result.index += 1;
        }
        try download.unchanged();
        return .{ .download = download, .remaining = download.accepted };
    }
    fn sourceRead(context: *anyopaque, bytes: []u8) !usize {
        const self: *Reader = @ptrCast(@alignCast(context));
        const count = try self.download.file.readPositional(self.download.account.directory.io, &.{bytes[0..@min(bytes.len, self.wire_left)]}, self.offset);
        self.offset += count;
        self.wire_left -= count;
        return count;
    }
    fn begin(self: *Reader) !void {
        const download = self.download;
        const text = download.handle.text();
        self.part_size = @min(self.remaining, t.chunk_bytes);
        self.wire_left = try t.sealedSize(self.part_size);
        self.pull = try crypto.PullReader.init(download.account.directory.io, download.account.owner.key, download.identity(&text, self.index), .{ .context = self, .readFn = sourceRead }, &download.account.owner.workspace.ciphertext);
        if (self.pull.?.size != self.part_size) return error.VaultLengthMismatch;
    }
    pub fn close(self: *Reader) void {
        if (self.download.account.reader_owner == @as(?*anyopaque, self)) {
            if (self.pull) |*pull| pull.close();
            self.download.account.reader_owner = null;
        }
        self.failed = true;
    }
    pub fn read(self: *Reader, bytes: []u8) !usize {
        if (self.failed) return error.VaultStreamClosed;
        try self.download.account.requireActive();
        if (bytes.len == 0) return 0;
        if (self.download.account.reader_owner) |other| if (other != @as(*anyopaque, self)) return error.VaultBusy;
        self.download.account.reader_owner = self;
        errdefer {
            std.crypto.secureZero(u8, bytes);
            self.close();
        }
        try self.download.unchanged();
        while (self.remaining != 0) {
            if (self.pull == null) try self.begin();
            const count = try self.pull.?.read(bytes);
            try self.download.unchanged();
            if (count != 0) return count;
            self.pull.?.close();
            self.pull = null;
            self.remaining -= self.part_size;
            self.index += 1;
        }
        self.download.account.reader_owner = null;
        return 0;
    }
};
