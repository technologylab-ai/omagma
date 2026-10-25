//! std.Io.Writer adapter for existing counted JSON and MIME serializers.
//! Initialize in place, borrow one workspace, finish, and always defer deinit.
const std = @import("std");
const crypto = @import("vault_crypto.zig");
const storage = @import("vault_storage.zig");
const t = @import("vault_types.zig");

pub const Writer = struct {
    interface: std.Io.Writer,
    output: storage.AtomicFile,
    sealer: crypto.PushSealer,
    failure: ?anyerror = null,
    workspace_lease: ?struct { owner: *?storage.Handle, token: storage.Handle, release: *const fn (*?storage.Handle, storage.Handle) void } = null,

    pub fn init(self: *Writer, directory: *storage.Directory, key: *const t.DataKey, record: storage.Record, size: usize, workspace: *t.StreamWorkspace, replace: bool, faults: storage.Faults) !void {
        errdefer workspace.wipe();
        self.output = try directory.begin(record.handle, size, replace, faults);
        errdefer self.output.deinit();
        const handle_text = record.handle.text();
        self.sealer = try crypto.PushSealer.init(directory.io, key, storage.binding(record, &handle_text), size, self.output.sink(), workspace);
        self.interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} };
        self.failure = null;
        self.workspace_lease = null;
    }
    pub fn initInPlace(self: *Writer, directory: *storage.Directory, key: *const t.DataKey, record: storage.Record, size: usize, buffer: *[t.chunk_bytes]u8) !void {
        errdefer std.crypto.secureZero(u8, buffer);
        self.output = try directory.begin(record.handle, size, false, .{});
        errdefer self.output.deinit();
        const handle_text = record.handle.text();
        self.sealer = try crypto.PushSealer.initInPlace(directory.io, key, storage.binding(record, &handle_text), size, self.output.sink(), buffer);
        self.interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} };
        self.failure = null;
        self.workspace_lease = null;
    }
    /// Register the plaintext half while the ciphertext half remains available
    /// for sequential source readers. A value token avoids a lease pointing at
    /// a temporary Writer. The account and owner must outlive the stream.
    pub fn initOwnedInPlace(self: *Writer, directory: *storage.Directory, key: *const t.DataKey, record: storage.Record, size: usize, buffer: *[t.chunk_bytes]u8, owner: *?storage.Handle, release: *const fn (*?storage.Handle, storage.Handle) void) !void {
        if (owner.* != null) return error.VaultBusy;
        try self.initInPlace(directory, key, record, size, buffer);
        self.workspace_lease = .{ .owner = owner, .token = record.handle, .release = release };
        owner.* = record.handle;
    }
    fn releaseWorkspace(self: *Writer) void {
        if (self.workspace_lease) |lease| {
            if (lease.owner.*) |token| if (std.mem.eql(u8, &token.bytes, &lease.token.bytes)) {
                lease.release(lease.owner, lease.token);
            };
            self.workspace_lease = null;
        }
    }
    pub fn deinit(self: *Writer) void {
        self.sealer.abort();
        self.output.deinit();
        self.releaseWorkspace();
    }
    pub fn finish(self: *Writer) !void {
        errdefer if (!self.sealer.active) self.releaseWorkspace();
        if (self.failure) |err| return err;
        try self.interface.flush();
        try self.sealer.finish();
        self.releaseWorkspace();
    }
    fn part(self: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
        self.sealer.write(bytes) catch |err| {
            self.failure = err;
            if (!self.sealer.active) self.releaseWorkspace();
            return error.WriteFailed;
        };
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", writer));
        try self.part(writer.buffer[0..writer.end]);
        writer.end = 0;
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
};

/// Movable until its first read. One reader owns the borrowed half-workspace
/// until EOF/reset/close; sequential MIME parts share it without per-part buffers.
/// A full authentication pass runs before the first byte can reach a consumer.
pub const Reader = struct {
    input: storage.Reader,
    key: *const t.DataKey,
    record: storage.Record,
    buffer: *[t.chunk_bytes]u8,
    occupied: *?*anyopaque,
    pull: ?crypto.PullReader = null,
    size: usize,
    failed: bool = false,
    pub fn init(directory: *storage.Directory, key: *const t.DataKey, record: storage.Record, buffer: *[t.chunk_bytes]u8, occupied: *?*anyopaque) !Reader {
        if (occupied.* != null) return error.VaultBusy;
        var input = try directory.reader(record.handle);
        errdefer input.close();
        const handle_text = record.handle.text();
        var verify = try crypto.PullReader.init(directory.io, key, storage.binding(record, &handle_text), input.source(), buffer);
        defer verify.close();
        try verify.verifyAll();
        try input.unchanged();
        input.offset = 0;
        return .{ .input = input, .key = key, .record = record, .buffer = buffer, .occupied = occupied, .size = verify.size };
    }
    pub fn reset(self: *Reader) !void {
        if (self.failed or self.input.closed) return error.VaultStreamClosed;
        if (self.occupied.*) |other| if (other != @as(*anyopaque, self)) return error.VaultBusy;
        if (self.pull) |*pull| pull.close();
        self.pull = null;
        if (self.occupied.* == @as(?*anyopaque, self)) self.occupied.* = null;
        self.input.offset = 0;
        try self.input.unchanged();
    }
    pub fn close(self: *Reader) void {
        if (self.occupied.* == @as(?*anyopaque, self)) {
            if (self.pull) |*pull| pull.close();
            self.occupied.* = null;
        }
        self.failed = true;
        self.input.close();
    }
    pub fn read(self: *Reader, out: []u8) !usize {
        if (self.failed or self.input.closed) return error.VaultStreamClosed;
        if (out.len == 0) return 0;
        if (self.occupied.*) |other| if (other != @as(*anyopaque, self)) return error.VaultBusy;
        errdefer {
            self.failed = true;
            std.crypto.secureZero(u8, out);
            if (self.pull) |*pull| pull.close();
            self.occupied.* = null;
        }
        try self.input.unchanged();
        if (self.pull == null) {
            const handle_text = self.record.handle.text();
            self.pull = try crypto.PullReader.init(self.input.io, self.key, storage.binding(self.record, &handle_text), self.input.source(), self.buffer);
        }
        self.occupied.* = self;
        const count = try self.pull.?.read(out);
        try self.input.unchanged();
        if (count == 0) self.occupied.* = null;
        return count;
    }
};
