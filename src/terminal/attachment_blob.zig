const std = @import("std");
const t = @import("types.zig");
const storage = @import("store.zig");
const mime = @import("mime.zig");

pub fn validateId(id: []const u8) !void {
    return @import("draft_codec.zig").validateAttachmentHandle(id);
}
pub fn filename(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    try validateId(id);
    return std.fmt.allocPrint(a, "blob-{s}.bin", .{id});
}
fn unchanged(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.inode == after.inode and before.size == after.size and before.mtime.toNanoseconds() == after.mtime.toNanoseconds() and before.ctime.toNanoseconds() == after.ctime.toNanoseconds();
}
fn digestFile(io: std.Io, file: std.Io.File, expected: usize) ![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        if (offset + count > expected) return error.AttachmentChanged;
        hash.update(buffer[0..count]);
        offset += count;
    }
    if (offset != expected) return error.AttachmentChanged;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn importFile(store: *storage.Store, path: []const u8, requested_mime: []const u8) !t.Attachment {
    return importBounded(store, path, requested_mime, t.Limits.attachment_bytes);
}
pub fn importDelivery(store: *storage.Store, path: []const u8, requested_mime: []const u8, delivery: ?t.AttachmentDelivery) !t.Attachment {
    var result = try importBounded(store, path, requested_mime, t.Limits.disk_hard);
    result.delivery = delivery;
    return result;
}
fn importBounded(store: *storage.Store, path: []const u8, requested_mime: []const u8, max_bytes: usize) !t.Attachment {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAttachmentPath;
    const name = std.fs.path.basename(path);
    const mime_type = if (requested_mime.len != 0) requested_mime else "application/octet-stream";
    try mime.validateAttachment(name, mime_type);
    const input = try @import("../native_file.zig").openAt(store.io, .cwd(), try store.allocator.dupeSentinel(u8, path, 0), .{});
    defer input.close(store.io);
    const before = try input.stat(store.io);
    if (before.kind != .file) return error.InvalidAttachmentFile;
    if (before.size > max_bytes) return error.AttachmentsTooLarge;
    const size: usize = @intCast(before.size);
    const digest = try digestFile(store.io, input, size);
    if (!unchanged(before, try input.stat(store.io))) return error.AttachmentChanged;
    const id = try store.allocator.dupe(u8, &digest);
    const target = try filename(store.allocator, id);
    if (store.vault != null) {
        const descriptor: t.Attachment = .{ .id = id, .filename = name, .mimeType = mime_type, .size = size, .blobId = id };
        if (try store.hasVaultBlob(target)) {
            try verify(store, descriptor);
            return descriptor;
        }
        var output: @import("vault_stream.zig").Writer = undefined;
        const handle = try store.beginVaultStream(&output, .attachment, size);
        defer output.deinit();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [64 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        var offset: usize = 0;
        while (true) {
            const count = try input.readPositional(store.io, &.{&buffer}, offset);
            if (count == 0) break;
            if (count > size -| offset) return error.AttachmentChanged;
            try output.interface.writeAll(buffer[0..count]);
            hash.update(buffer[0..count]);
            offset += count;
        }
        var copied: [32]u8 = undefined;
        hash.final(&copied);
        if (offset != size or !std.mem.eql(u8, &std.fmt.bytesToHex(copied, .lower), id) or !unchanged(before, try input.stat(store.io))) return error.AttachmentChanged;
        try output.finish();
        try store.adoptVaultBlob(target, handle);
        return descriptor;
    }
    const existing = store.dir.statFile(store.io, target, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) null else return err;
    if (existing == null) {
        try store.reserveBytes(size);
        var atomic = try store.dir.createFileAtomic(store.io, target, .{ .permissions = .fromMode(0o600), .replace = false });
        defer atomic.deinit(store.io);
        var copied = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const count = try input.readPositional(store.io, &.{&buffer}, offset);
            if (count == 0) break;
            if (offset + count > size) return error.AttachmentChanged;
            copied.update(buffer[0..count]);
            try atomic.file.writeStreamingAll(store.io, buffer[0..count]);
            offset += count;
        }
        var bytes: [32]u8 = undefined;
        copied.final(&bytes);
        if (offset != size or !std.mem.eql(u8, &std.fmt.bytesToHex(bytes, .lower), id) or !unchanged(before, try input.stat(store.io))) return error.AttachmentChanged;
        try atomic.file.sync(store.io);
        try atomic.link(store.io);
        const parent: std.Io.File = .{ .handle = store.dir.handle, .flags = .{ .nonblocking = false } };
        try parent.sync(store.io);
        // reserveBytes may have evicted cached bodies. Persist those references.
        try store.save();
    } else {
        const file = try open(store, id, size);
        defer file.close(store.io);
        if (!std.mem.eql(u8, &try digestFile(store.io, file, size), id)) return error.AttachmentChanged;
    }
    try store.adoptPlainBlob(target, size);
    return .{ .id = id, .filename = name, .mimeType = mime_type, .size = size, .blobId = id };
}
pub fn open(store: *storage.Store, id: []const u8, size: usize) !std.Io.File {
    try store.requirePlainFiles();
    const path = try filename(store.allocator, id);
    const file = @import("../native_file.zig").openAt(store.io, store.dir, try store.allocator.dupeSentinel(u8, path, 0), .{}) catch |err| if (err == error.FileNotFound) return error.AttachmentHandleNotFound else return err;
    errdefer file.close(store.io);
    const stat = try file.stat(store.io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureAttachmentFile;
    // Incoming and outgoing handles share storage. Import and MIME validation
    // independently retain the smaller outgoing-file limit.
    if (stat.size != size or stat.size > t.Limits.disk_hard) return error.AttachmentChanged;
    return file;
}
pub fn discard(store: *storage.Store, id: []const u8) !void {
    const path = try filename(store.allocator, id);
    if (try store.blobReferencedVerified(id)) return error.AttachmentInUse;
    if (store.vault != null) return store.discardVaultBlob(path);
    if (try @import("operation_history.zig").deleteBlob(store, id)) return;
    const stat = try store.dir.statFile(store.io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureAttachmentFile;
    try store.dir.deleteFile(store.io, path);
}

/// A descriptor borrowed by MIME for one serialization. Every byte contributes
/// to the frozen content hash; corruption fails before the spool is submitted.
pub const Stream = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    sealed: ?@import("vault_stream.zig").Reader = null,
    account: ?*@import("vault_catalog.zig").Account = null,
    expected: []const u8,
    size: usize,
    offset: u64 = 0,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    verified: bool = false,
    pub fn init(store: *storage.Store, attachment: t.Attachment) !Stream {
        const id = attachment.blobId orelse return error.InvalidAttachmentHandle;
        if (attachment.data.len != 0) return error.InvalidAttachmentHandle;
        try validateId(id);
        if (attachment.size > t.Limits.disk_hard) return error.AttachmentsTooLarge;
        if (store.vault != null) {
            var sealed = try store.openVaultStream(try filename(store.allocator, id));
            errdefer sealed.close();
            if (sealed.size != attachment.size) return error.AttachmentChanged;
            return .{ .io = store.io, .sealed = sealed, .account = store.vault, .expected = id, .size = attachment.size };
        }
        return .{ .io = store.io, .file = try open(store, id, attachment.size), .expected = id, .size = attachment.size };
    }
    pub fn close(self: *Stream) void {
        if (self.sealed) |*sealed| sealed.close();
        if (self.file) |file| file.close(self.io);
    }
    pub fn reset(self: *Stream) !void {
        if (self.sealed) |*sealed| try sealed.reset();
        self.offset = 0;
        self.hasher = std.crypto.hash.sha2.Sha256.init(.{});
        self.verified = false;
    }
    pub fn read(ctx: *anyopaque, out: []u8) !usize {
        const self: *Stream = @ptrCast(@alignCast(ctx));
        if (self.verified) return 0;
        if (out.len == 0) return 0;
        if (self.account) |account| try account.requireActive();
        const count = if (self.sealed) |*sealed| try sealed.read(out) else try self.file.?.readPositional(self.io, &.{out}, self.offset);
        if (self.offset + count > self.size) return error.AttachmentChanged;
        if (count != 0) {
            self.hasher.update(out[0..count]);
            self.offset += count;
            return count;
        }
        if (self.offset != self.size) return error.AttachmentChanged;
        var digest: [32]u8 = undefined;
        self.hasher.final(&digest);
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), self.expected)) return error.AttachmentChanged;
        self.verified = true;
        return 0;
    }
};

pub fn verify(store: *storage.Store, attachment: t.Attachment) !void {
    var stream = try Stream.init(store, attachment);
    defer stream.close();
    var buffer: [64 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    while (try Stream.read(&stream, &buffer) != 0) {}
}

pub const Incoming = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: ?std.Io.File = null,
    sealed: ?@import("vault_download.zig").Download = null,
    name: []const u8,
    size: usize,
    moved: bool = false,
    pub fn create(store: *storage.Store, size: usize) !Incoming {
        if (size > t.Limits.incoming_attachment_bytes) return error.AttachmentsTooLarge;
        if (store.vault != null) {
            const account = try store.vaultContext();
            // Admission covers the staging reservation AND final encrypted
            // record together, plus the full replacement index and one map-entry allowance.
            const download = @import("vault_download.zig").Download;
            try store.reserveVaultCiphertext(try download.reservation(size) + try @import("vault_types.zig").sealedSize(size) + try store.vaultIndexStagingBytes());
            return .{ .io = store.io, .dir = store.dir, .name = "", .size = size, .sealed = try download.create(account, size) };
        }
        try store.reserveBytes(size);
        var nonce: [16]u8 = undefined;
        try store.io.randomSecure(&nonce);
        const name = try std.fmt.allocPrint(store.allocator, "download-spool-{s}.bin", .{std.fmt.bytesToHex(nonce, .lower)});
        const dir = try store.dir.openDir(store.io, ".", .{ .follow_symlinks = false });
        errdefer dir.close(store.io);
        const file = try dir.createFile(store.io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive });
        errdefer {
            file.close(store.io);
            dir.deleteFile(store.io, name) catch {};
        }
        // Logical size reserves the quota across releasing/reopening the store
        // while the owned network worker downloads into this private file.
        try file.setLength(store.io, size);
        try store.save();
        return .{ .io = store.io, .dir = dir, .file = file, .name = name, .size = size };
    }
    pub fn close(self: *Incoming) void {
        if (self.sealed) |*sealed| {
            sealed.close();
            return;
        }
        self.file.?.close(self.io);
        if (!self.moved) self.dir.deleteFile(self.io, self.name) catch {};
        self.dir.close(self.io);
    }
    pub fn writer(self: *Incoming, buffer: []u8) Writer {
        return .{ .incoming = self, .interface = .{ .vtable = &.{ .drain = Writer.drain }, .buffer = buffer } };
    }
    pub const Writer = struct {
        incoming: *Incoming,
        interface: std.Io.Writer,
        failure: ?anyerror = null,
        fn part(self: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
            self.incoming.write(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
        }
        fn drain(writer_interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", writer_interface));
            try self.part(writer_interface.buffer[0..writer_interface.end]);
            writer_interface.end = 0;
            var count: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try self.part(bytes);
                count += bytes.len;
            }
            for (0..splat) |_| {
                try self.part(data[data.len - 1]);
                count += data[data.len - 1].len;
            }
            return count;
        }
        pub fn flush(self: *Writer) !void {
            self.interface.flush() catch |err| return self.failure orelse err;
        }
    };
    pub fn write(self: *Incoming, bytes: []const u8) !void {
        if (self.sealed) |*sealed| return sealed.write(bytes);
        try self.file.?.writeStreamingAll(self.io, bytes);
    }
    pub fn finish(self: *Incoming, exact: usize) !void {
        if (exact > self.size) return error.BodySizeMismatch;
        if (self.sealed) |*sealed| try sealed.finish(exact) else try self.file.?.setLength(self.io, exact);
        self.size = exact;
    }
    pub fn reader(self: *Incoming) !Reader {
        return .{ .incoming = self, .sealed = if (self.sealed) |*sealed| try @import("vault_download.zig").Reader.init(sealed) else null };
    }
    pub const Reader = struct {
        incoming: *Incoming,
        offset: usize = 0,
        sealed: ?@import("vault_download.zig").Reader,
        pub fn close(self: *Reader) void {
            if (self.sealed) |*sealed| sealed.close();
        }
        pub fn read(context: *anyopaque, bytes: []u8) !usize {
            const self: *Reader = @ptrCast(@alignCast(context));
            if (self.sealed) |*sealed| return sealed.read(bytes);
            const count = try self.incoming.file.?.readPositional(self.incoming.io, &.{bytes}, self.offset);
            self.offset += count;
            return count;
        }
    };
    fn commitSealed(self: *Incoming, store: *storage.Store, expected: t.Attachment) !t.Attachment {
        const account = try store.vaultContext();
        if (account != self.sealed.?.account or !self.sealed.?.finished) return error.VaultIdentityMismatch;
        if (expected.size != self.size) return error.BodySizeMismatch;
        var buffer: [64 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        {
            var source = try self.reader();
            defer source.close();
            while (true) {
                const count = try Reader.read(&source, &buffer);
                if (count == 0) break;
                hash.update(buffer[0..count]);
            }
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        const id = try store.allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        const name = try filename(store.allocator, id);
        var result = expected;
        result.data = "";
        result.blobId = id;
        if (try store.hasVaultBlob(name)) {
            try verify(store, result);
            return result;
        }
        var source = try self.reader();
        defer source.close();
        var output: @import("vault_stream.zig").Writer = undefined;
        const handle = try store.beginVaultStream(&output, .attachment, self.size);
        defer output.deinit();
        while (true) {
            const count = try Reader.read(&source, &buffer);
            if (count == 0) break;
            output.interface.writeAll(buffer[0..count]) catch |err| return output.failure orelse err;
        }
        try output.finish();
        source.close();
        try store.adoptVaultBlob(name, handle);
        return result;
    }
    pub fn commit(self: *Incoming, store: *storage.Store, expected: t.Attachment) !t.Attachment {
        if (self.sealed != null) return self.commitSealed(store, expected);
        try store.requirePlainFiles();
        if (expected.size != self.size) return error.BodySizeMismatch;
        try self.file.?.sync(self.io);
        const digest = try digestFile(self.io, self.file.?, self.size);
        const id = try store.allocator.dupe(u8, &digest);
        const target = try filename(store.allocator, id);
        self.dir.renamePreserve(self.name, store.dir, target, self.io) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            const existing = try open(store, id, self.size);
            defer existing.close(self.io);
            if (!std.mem.eql(u8, &try digestFile(self.io, existing, self.size), id)) return error.AttachmentChanged;
            var result = expected;
            result.data = "";
            result.blobId = id;
            try store.adoptPlainBlob(target, self.size);
            return result;
        };
        self.moved = true;
        const parent: std.Io.File = .{ .handle = store.dir.handle, .flags = .{ .nonblocking = false } };
        try parent.sync(self.io);
        try store.adoptPlainBlob(target, self.size);
        var result = expected;
        result.data = "";
        result.blobId = id;
        return result;
    }
};

test "UX backend: incoming reservations survive concurrent opens and orphan spools are reclaimed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/incoming", .{tmp.sub_path});
    const account = "self@example.test";
    const options: t.Options = .{ .fixtures = true };
    var store = try storage.Store.open(std.testing.io, a, root, account, options);
    defer store.close();
    var incoming = try Incoming.create(&store, 3);
    defer incoming.close();
    store.release();
    {
        var concurrent = try storage.Store.open(std.testing.io, a, root, account, options);
        defer concurrent.close();
        try std.testing.expectEqual(@as(u64, 3), (try concurrent.dir.statFile(std.testing.io, incoming.name, .{})).size);
    }
    store.close();
    store = try storage.Store.open(std.testing.io, a, root, account, options);
    try incoming.file.?.writeStreamingAll(std.testing.io, "abc");
    const attached = try incoming.commit(&store, .{ .id = "provider-token", .filename = "small.bin", .size = 3 });
    try std.testing.expectEqualStrings("provider-token", attached.id);
    try std.testing.expectEqualStrings(&storage.Store.hash("abc"), attached.blobId.?);
    var source = try Stream.init(&store, attached);
    defer source.close();
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try Stream.read(&source, &bytes));
    try std.testing.expectEqual(@as(usize, 0), try Stream.read(&source, &bytes));
    const orphan = "download-spool-00000000000000000000000000000000.bin";
    const scratch = try store.dir.createFile(std.testing.io, orphan, .{ .permissions = .fromMode(0o600) });
    try scratch.writeStreamingAll(std.testing.io, "partial");
    scratch.close(std.testing.io);
    store.close();
    store = try storage.Store.open(std.testing.io, a, root, account, options);
    try std.testing.expectError(error.FileNotFound, store.dir.statFile(std.testing.io, orphan, .{}));
    try std.testing.expectError(error.AttachmentsTooLarge, Incoming.create(&store, t.Limits.incoming_attachment_bytes + 1));
    try discard(&store, attached.blobId.?);
    try std.testing.expectError(error.AttachmentHandleNotFound, open(&store, attached.blobId.?, 3));
}

test "attachment streaming: 30 MiB incoming blob survives reopen within account quota and bounded allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = std.testing.allocator, .limit = t.Limits.runtime_bytes };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/incoming-large", .{tmp.sub_path});
    const options: t.Options = .{ .fixtures = true };
    var store = try storage.Store.open(std.testing.io, a, root, "self@example.test", options);
    defer store.close();
    const size = 30 * 1024 * 1024;
    var block: [64 * 1024]u8 = undefined;
    for (&block, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    var expected_hash = std.crypto.hash.sha2.Sha256.init(.{});
    const attached = blk: {
        var incoming = try Incoming.create(&store, size);
        defer incoming.close();
        for (0..size / block.len) |_| {
            try incoming.file.?.writeStreamingAll(std.testing.io, &block);
            expected_hash.update(&block);
        }
        break :blk try incoming.commit(&store, .{ .id = "provider-large", .filename = "received.bin", .size = size });
    };
    var expected_digest: [32]u8 = undefined;
    expected_hash.final(&expected_digest);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(expected_digest, .lower), attached.blobId.?);
    try std.testing.expectEqualStrings("", attached.data);
    store.close();
    store = try storage.Store.open(std.testing.io, a, root, "self@example.test", options);
    {
        var source = try Stream.init(&store, attached);
        defer source.close();
        const stat = try source.file.?.stat(std.testing.io);
        try std.testing.expectEqual(.file, stat.kind);
        try std.testing.expectEqual(@as(u64, size), stat.size);
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
        var output: [64 * 1024]u8 = undefined;
        var count: usize = 0;
        while (true) {
            const n = try Stream.read(&source, &output);
            if (n == 0) break;
            const offset = count % block.len;
            const first = @min(n, block.len - offset);
            try std.testing.expectEqualSlices(u8, block[offset..][0..first], output[0..first]);
            try std.testing.expectEqualSlices(u8, block[0 .. n - first], output[first..n]);
            count += n;
        }
        try std.testing.expectEqual(@as(usize, size), count);
        try std.testing.expect(source.verified);
    }
    {
        var other = try storage.Store.open(std.testing.io, a, root, "other@example.test", options);
        defer other.close();
        try std.testing.expectError(error.AttachmentHandleNotFound, Stream.init(&other, attached));
    }
    const before = try store.diskBytes();
    {
        var boundary = try Incoming.create(&store, 50 * 1024 * 1024);
        defer boundary.close();
        try std.testing.expectEqual(@as(u64, 50 * 1024 * 1024), (try boundary.file.?.stat(std.testing.io)).size);
        try std.testing.expect((try store.diskBytes()) >= before + 50 * 1024 * 1024);
    }
    try std.testing.expectEqual(before, try store.diskBytes());
    try std.testing.expectError(error.AttachmentsTooLarge, Incoming.create(&store, 50 * 1024 * 1024 + 1));
    store.options.disk_limit = before + 1024;
    try std.testing.expectError(error.DiskQuotaExceeded, Incoming.create(&store, 2 * 1024 * 1024));
    try std.testing.expectEqual(before, try store.diskBytes());
    const outgoing = try tmp.dir.createFile(std.testing.io, "outgoing-too-large.bin", .{ .permissions = .fromMode(0o600) });
    try outgoing.setLength(std.testing.io, size);
    outgoing.close(std.testing.io);
    const outgoing_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/outgoing-too-large.bin", .{tmp.sub_path});
    try std.testing.expectError(error.AttachmentsTooLarge, importFile(&store, outgoing_path, "application/octet-stream"));
    try std.testing.expect(cap.peak < 2 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
}
