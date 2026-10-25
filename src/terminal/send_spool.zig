const std = @import("std");
const t = @import("types.zig");
const mime = @import("mime.zig");
const storage = @import("store.zig");
const blob = @import("attachment_blob.zig");

pub const Spool = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: ?std.Io.File = null,
    account: ?*@import("vault_catalog.zig").Account = null,
    handle: ?@import("vault_storage.zig").Handle = null,
    name: []const u8 = "",
    size: usize,
    hash: [64]u8,
    pub fn close(self: *Spool) void {
        if (self.account) |account| {
            const claimed = !account.active;
            if (claimed) account.claim() catch return;
            defer if (claimed) account.release();
            account.remove(self.handle.?) catch {};
            return;
        }
        self.file.?.close(self.io);
        self.dir.deleteFile(self.io, self.name) catch {};
    }
    pub fn reader(self: *const Spool) !Reader {
        if (self.account) |account| {
            try account.pinWorkspace();
            errdefer account.unpinWorkspace();
            var sealed = try @import("vault_stream.zig").Reader.init(&account.directory, account.owner.key, account.record(.send_spool, self.handle.?), &account.owner.workspace.ciphertext, &account.reader_owner);
            errdefer sealed.close();
            if (sealed.size != self.size) return error.AttachmentChanged;
            return .{ .spool = self, .sealed = sealed };
        }
        return .{ .spool = self };
    }
    pub const Reader = struct {
        spool: *const Spool,
        sealed: ?@import("vault_stream.zig").Reader = null,
        offset: usize = 0,
        hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
        verified: bool = false,
        pub fn close(self: *Reader) void {
            if (self.sealed) |*sealed| {
                sealed.close();
                self.spool.account.?.unpinWorkspace();
            }
        }
        pub fn reset(self: *Reader) !void {
            if (self.sealed) |*sealed| try sealed.reset();
            self.offset = 0;
            self.hash = .init(.{});
            self.verified = false;
        }
        pub fn read(context: *anyopaque, bytes: []u8) !usize {
            const self: *Reader = @ptrCast(@alignCast(context));
            if (self.verified or bytes.len == 0) return 0;
            const count = if (self.sealed) |*sealed| try sealed.read(bytes) else try self.spool.file.?.readPositional(self.spool.io, &.{bytes}, self.offset);
            if (count > self.spool.size -| self.offset) return error.AttachmentChanged;
            self.hash.update(bytes[0..count]);
            self.offset += count;
            if (count == 0) {
                var digest: [32]u8 = undefined;
                self.hash.final(&digest);
                if (self.offset != self.spool.size or !std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), &self.spool.hash)) return error.AttachmentChanged;
                self.verified = true;
            }
            return count;
        }
    };
};
pub fn required(attachments: []const t.Attachment) bool {
    for (attachments) |attachment| if (attachment.blobId != null) return true;
    return false;
}
const Sink = struct {
    writer: std.Io.Writer,
    io: std.Io,
    file: ?std.Io.File = null,
    sealed: ?*@import("vault_stream.zig").Writer = null,
    count: usize = 0,
    limit: usize,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    failure: ?anyerror = null,
    fn part(self: *Sink, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > self.limit - self.count) {
            self.failure = error.FormTooLarge;
            return error.WriteFailed;
        }
        if (self.sealed) |sealed| {
            sealed.interface.writeAll(bytes) catch |err| {
                self.failure = sealed.failure orelse err;
                return error.WriteFailed;
            };
        } else self.file.?.writeStreamingAll(self.io, bytes) catch |err| {
            self.failure = err;
            return error.WriteFailed;
        };
        self.count += bytes.len;
        self.hasher.update(bytes);
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("writer", writer));
        try self.part(writer.buffer[0..writer.end]);
        writer.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.part(bytes);
            consumed += bytes.len;
        }
        for (0..splat) |_| {
            try self.part(data[data.len - 1]);
            consumed += data[data.len - 1].len;
        }
        return consumed;
    }
};

/// MIME emits parts sequentially. Retain only descriptors between reads and
/// keep one verified stream open, rather than one file per accumulated image.
/// Each pass reopens the immutable blob and verifies size/hash through EOF.
const SourcePool = struct {
    store: *storage.Store,
    active: ?*LazySource = null,
    stream: ?blob.Stream = null,

    fn close(self: *SourcePool) void {
        if (self.stream) |*stream| stream.close();
        self.stream = null;
        self.active = null;
    }
};
const LazySource = struct {
    pool: *SourcePool,
    attachment: t.Attachment,
    complete: bool = false,

    fn read(ctx: *anyopaque, out: []u8) !usize {
        const self: *LazySource = @ptrCast(@alignCast(ctx));
        if (out.len == 0 or self.complete) return 0;
        const pool = self.pool;
        if (pool.active) |active| {
            if (active != self) return error.AttachmentStreamInUse;
        } else {
            pool.stream = try blob.Stream.init(pool.store, self.attachment);
            pool.active = self;
        }
        const count = blob.Stream.read(&pool.stream.?, out) catch |err| {
            pool.close();
            return err;
        };
        if (count == 0) {
            // Stream.read returns zero only after exact size/hash validation.
            pool.close();
            self.complete = true;
        }
        return count;
    }
};

const Prepared = struct {
    sources: []LazySource,
    source_count: usize,
    parts: []mime.Attachment,
};
fn prepare(a: std.mem.Allocator, pool: *SourcePool, attachments: []const t.Attachment, related: []const t.Attachment) !Prepared {
    if (attachments.len > t.Limits.attachments or related.len > t.Limits.related_resources) return error.TooManyAttachments;
    const sources = try a.alloc(LazySource, attachments.len + related.len);
    var source_count: usize = 0;
    const parts = try a.alloc(mime.Attachment, attachments.len + related.len);
    var cursor: usize = 0;
    for ([_][]const t.Attachment{ attachments, related }) |list| for (list) |attachment| {
        const part = &parts[cursor];
        cursor += 1;
        if (attachment.blobId != null) {
            const source_index = source_count;
            sources[source_index] = .{ .pool = pool, .attachment = attachment };
            source_count += 1;
            part.* = .{ .filename = attachment.filename, .mime_type = attachment.mimeType, .content_id = if (attachment.contentId) |id| try mime.contentId(id) else "", .disposition = attachment.disposition orelse "", .content_location = attachment.contentLocation orelse "", .size = attachment.size, .source = .{ .ctx = &sources[source_index], .readFn = LazySource.read } };
        } else part.* = (try mime.composeAttachments(&.{attachment}, a))[0];
    };
    return .{ .sources = sources, .source_count = source_count, .parts = parts };
}
/// Exact encoded size with the same immutable sources and headers as send.
/// This reads/verifies one blob at a time and creates no output file.
pub fn measure(store: *storage.Store, input: mime.Compose, attachments: []const t.Attachment, related: []const t.Attachment) !usize {
    var pool: SourcePool = .{ .store = store };
    defer pool.close();
    const prepared = try prepare(store.allocator, &pool, attachments, related);
    var compose = input;
    compose.attachments = prepared.parts[0..attachments.len];
    compose.related = prepared.parts[attachments.len..];
    var buffer: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var counting = std.Io.Writer.Discarding.init(&buffer);
    try mime.measureTo(compose, &counting.writer);
    return @intCast(counting.fullCount());
}

pub fn create(store: *storage.Store, input: mime.Compose, attachments: []const t.Attachment, related: []const t.Attachment) !Spool {
    const a = store.allocator;
    var pool: SourcePool = .{ .store = store };
    defer pool.close();
    const prepared = try prepare(a, &pool, attachments, related);
    const sources = prepared.sources;
    const source_count = prepared.source_count;
    var compose = input;
    compose.attachments = prepared.parts[0..attachments.len];
    compose.related = prepared.parts[attachments.len..];
    // First pass counts the exact encoded size without allocating the MIME.
    // It also validates all source hashes before reserving disk or networking.
    var buffer: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var counting = std.Io.Writer.Discarding.init(&buffer);
    try mime.encodeTo(compose, &counting.writer);
    const count: usize = @intCast(counting.fullCount());
    if (count > t.Limits.mime_upload_bytes) return error.FormTooLarge;
    if (store.vault == null) try store.reserveBytes(count);
    for (sources[0..source_count]) |*source| {
        if (!source.complete) return error.AttachmentChanged;
        source.complete = false;
    }
    if (store.vault != null) {
        var output: @import("vault_stream.zig").Writer = undefined;
        const handle = try store.beginVaultStream(&output, .send_spool, count);
        defer output.deinit();
        var sink: Sink = .{ .writer = .{ .vtable = &.{ .drain = Sink.drain }, .buffer = &buffer }, .io = store.io, .sealed = &output, .limit = count };
        mime.encodeTo(compose, &sink.writer) catch |err| return sink.failure orelse err;
        sink.writer.flush() catch |err| return sink.failure orelse err;
        if (sink.count != count) return error.AttachmentChanged;
        try output.finish();
        var digest: [32]u8 = undefined;
        sink.hasher.final(&digest);
        return .{ .io = store.io, .dir = store.dir, .account = store.vault, .handle = handle, .size = count, .hash = std.fmt.bytesToHex(digest, .lower) };
    }
    var nonce: [16]u8 = undefined;
    try store.io.randomSecure(&nonce);
    const name = try std.fmt.allocPrint(a, "send-spool-{s}.mime", .{std.fmt.bytesToHex(nonce, .lower)});
    const file = try store.dir.createFile(store.io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive });
    errdefer {
        file.close(store.io);
        store.dir.deleteFile(store.io, name) catch {};
    }
    var sink: Sink = .{ .writer = .{ .vtable = &.{ .drain = Sink.drain }, .buffer = &buffer }, .io = store.io, .file = file, .limit = count };
    mime.encodeTo(compose, &sink.writer) catch |err| return sink.failure orelse err;
    sink.writer.flush() catch |err| return sink.failure orelse err;
    if (sink.count != count) return error.AttachmentChanged;
    try file.sync(store.io);
    var digest: [32]u8 = undefined;
    sink.hasher.final(&digest);
    return .{ .io = store.io, .dir = store.dir, .file = file, .name = name, .size = count, .hash = std.fmt.bytesToHex(digest, .lower) };
}

test "growing chain spool: all inline resources stream beside ordinary files with bounded open descriptors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const bytes = [_]u8{ 0, 255, 7, 9 };
    try tmp.dir.writeFile(io, .{ .sub_path = "screenshot.png", .data = &bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    const path = try tmp.dir.realPathFileAlloc(io, "screenshot.png", a);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/spool", .{tmp.sub_path});
    var store = try storage.Store.open(io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    const picture = try blob.importFile(&store, path, "image/png");
    const related = try a.alloc(t.Attachment, t.Limits.related_resources);
    var html: std.ArrayList(u8) = .empty;
    for (related, 0..) |*resource, index| {
        resource.* = picture;
        resource.contentId = try std.fmt.allocPrint(a, "screenshot-{d}@example.test", .{index});
        try html.appendSlice(a, try std.fmt.allocPrint(a, "<img src='cid:{s}'>", .{resource.contentId.?}));
    }
    const files: [t.Limits.portable_attachments]t.Attachment = @splat(picture);
    const recipients = @import("recipients.zig");
    var envelope: recipients.Envelope = .{};
    try recipients.parse("recipient@example.test", &envelope.to);
    var sender: recipients.Mailbox = .{};
    try sender.address.set("sender@example.test");
    const compose: mime.Compose = .{ .from = sender, .envelope = &envelope, .subject = "Synthetic growing chain", .body = "All screenshots retained", .html = html.items, .message_id = "<growing@example.test>", .date = "Thu, 08 Oct 2026 12:00:00 +0000" };
    var spool = try create(&store, compose, &files, related);
    defer spool.close();
    var reader = try spool.reader();
    defer reader.close();
    const raw = try a.alloc(u8, spool.size);
    var offset: usize = 0;
    while (offset < raw.len) {
        const count = try Spool.Reader.read(&reader, raw[offset..]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    var end: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try Spool.Reader.read(&reader, &end));
    try std.testing.expect(reader.verified);
    const parsed = try mime.parse(raw, a);
    try std.testing.expectEqual(related.len + files.len, parsed.attachments.len);
    for (parsed.attachments) |attachment| try std.testing.expectEqualSlices(u8, &bytes, attachment.data);
    for (parsed.attachments[0..related.len], related) |attachment, resource| try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "<{s}>", .{resource.contentId.?}), attachment.content_id);
}

test "growing chain spool: lazy sources close on hash failure and reopen for each verified pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var store = try storage.Store.open(io, a, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sources", .{tmp.sub_path}), "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    const id = try a.dupe(u8, &storage.Store.hash("good"));
    const filename = try blob.filename(a, id);
    try store.dir.writeFile(io, .{ .sub_path = filename, .data = "good", .flags = .{ .permissions = .fromMode(0o600) } });
    var pool: SourcePool = .{ .store = &store };
    defer pool.close();
    var source: LazySource = .{ .pool = &pool, .attachment = .{ .id = "test", .filename = "fixture.bin", .blobId = id, .size = 4 } };
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try LazySource.read(&source, &buffer));
    try std.testing.expect(pool.active != null);
    try std.testing.expectEqualStrings("good", &buffer);
    try std.testing.expectEqual(@as(usize, 0), try LazySource.read(&source, &buffer));
    try std.testing.expect(source.complete and pool.active == null and pool.stream == null);
    try store.dir.writeFile(io, .{ .sub_path = filename, .data = "evil", .flags = .{ .permissions = .fromMode(0o600) } });
    source.complete = false;
    try std.testing.expectEqual(@as(usize, 4), try LazySource.read(&source, &buffer));
    try std.testing.expectError(error.AttachmentChanged, LazySource.read(&source, &buffer));
    try std.testing.expect(!source.complete and pool.active == null and pool.stream == null);
}
