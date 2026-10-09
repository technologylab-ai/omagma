const std = @import("std");
const t = @import("types.zig");
const mime = @import("mime.zig");
const storage = @import("store.zig");
const blob = @import("attachment_blob.zig");

pub const Spool = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    name: []const u8,
    size: usize,
    hash: [64]u8,
    pub fn close(self: *Spool) void {
        self.file.close(self.io);
        self.dir.deleteFile(self.io, self.name) catch {};
    }
};
pub fn required(attachments: []const t.Attachment) bool {
    for (attachments) |attachment| if (attachment.blobId != null) return true;
    return false;
}
const Sink = struct {
    writer: std.Io.Writer,
    io: std.Io,
    file: std.Io.File,
    count: usize = 0,
    limit: usize,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    failure: ?anyerror = null,
    fn part(self: *Sink, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > self.limit - self.count) {
            self.failure = error.FormTooLarge;
            return error.WriteFailed;
        }
        self.file.writeStreamingAll(self.io, bytes) catch |err| {
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
pub fn create(store: *storage.Store, input: mime.Compose, attachments: []const t.Attachment) !Spool {
    const a = store.allocator;
    if (attachments.len > 16) return error.TooManyAttachments;
    const sources = try a.alloc(blob.Stream, attachments.len);
    var source_count: usize = 0;
    defer for (sources[0..source_count]) |*source| source.close();
    const parts = try a.alloc(mime.Attachment, attachments.len);
    for (attachments, parts) |attachment, *part| {
        if (attachment.blobId != null) {
            sources[source_count] = try blob.Stream.init(store, attachment);
            part.* = .{ .filename = attachment.filename, .mime_type = attachment.mimeType, .size = attachment.size, .source = .{ .ctx = &sources[source_count], .readFn = blob.Stream.read } };
            source_count += 1;
        } else part.* = (try mime.composeAttachments(&.{attachment}, a))[0];
    }
    var compose = input;
    compose.attachments = parts;
    // First pass counts the exact encoded size without allocating the MIME.
    // It also validates all source hashes before reserving disk or networking.
    var buffer: [32 * 1024]u8 = undefined;
    var counting = std.Io.Writer.Discarding.init(&buffer);
    try mime.encodeTo(compose, &counting.writer);
    const count: usize = @intCast(counting.fullCount());
    if (count > t.Limits.mime_upload_bytes) return error.FormTooLarge;
    try store.reserveBytes(count);
    for (sources[0..source_count]) |*source| {
        source.offset = 0;
        source.hasher = std.crypto.hash.sha2.Sha256.init(.{});
        source.verified = false;
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
