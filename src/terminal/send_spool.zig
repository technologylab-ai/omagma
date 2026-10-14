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
pub fn create(store: *storage.Store, input: mime.Compose, attachments: []const t.Attachment, related: []const t.Attachment) !Spool {
    const a = store.allocator;
    if (attachments.len > t.Limits.attachments or related.len > t.Limits.related_resources) return error.TooManyAttachments;
    const sources = try a.alloc(blob.Stream, attachments.len + related.len);
    var source_count: usize = 0;
    defer for (sources[0..source_count]) |*source| source.close();
    const parts = try a.alloc(mime.Attachment, attachments.len + related.len);
    var cursor: usize = 0;
    for ([_][]const t.Attachment{ attachments, related }) |list| for (list) |attachment| {
        const part = &parts[cursor];
        cursor += 1;
        if (attachment.blobId != null) {
            const source_index = source_count;
            sources[source_index] = try blob.Stream.init(store, attachment);
            source_count += 1;
            part.* = .{ .filename = attachment.filename, .mime_type = attachment.mimeType, .content_id = if (attachment.contentId) |id| try mime.contentId(id) else "", .disposition = attachment.disposition orelse "", .content_location = attachment.contentLocation orelse "", .size = attachment.size, .source = .{ .ctx = &sources[source_index], .readFn = blob.Stream.read } };
        } else part.* = (try mime.composeAttachments(&.{attachment}, a))[0];
    };
    var compose = input;
    compose.attachments = parts[0..attachments.len];
    compose.related = parts[attachments.len..];
    // First pass counts the exact encoded size without allocating the MIME.
    // It also validates all source hashes before reserving disk or networking.
    var buffer: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var counting = std.Io.Writer.Discarding.init(&buffer);
    try mime.encodeTo(compose, &counting.writer);
    const count: usize = @intCast(counting.fullCount());
    if (count > t.Limits.mime_upload_bytes) return error.FormTooLarge;
    if (store.vault == null) try store.reserveBytes(count);
    for (sources[0..source_count]) |*source| try source.reset();
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
