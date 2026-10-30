//! Private same-user Unix transport. One request per connection; never retry.
//! The wire carries command DTOs, never the daemon's data key or OAuth tokens.
const std = @import("std");
const test_allocator = @import("../cancel_neutral_test_allocator.zig");
const builtin = @import("builtin");
const t = @import("types.zig");
const platform = @import("../platform.zig");
const private = @import("../keyring_file.zig");
const native = @import("../native_file.zig");

pub const request_limit = @import("send_memory.zig").record_bytes;
pub const response_limit = request_limit + 64 * 1024;
pub const ordinary_response_limit = 32 * 1024 * 1024;
pub const header_bytes = 16;
// Control/status framing remains usable during an upgrade. Protected requests
// have a semantic generation independent of the application version: old
// daemons reject this magic before any data operation can be dispatched.
pub const magic = "OMAVIPC1";
pub const execution_magic = "OMAVIPC3";
pub const execution_protocol: u8 = 3;
pub const progress_limit: usize = 1024;
pub const mismatch_message = "Vault backend uses an incompatible execution protocol. Finish pending work and use the current executable to run omagma vault stop, omagma vault start, then omagma vault unlock; keep the existing vault and cache.";
pub fn protectedKind(kind: Kind) bool {
    return switch (kind) {
        .execute, .unlock, .password_change, .recovery_change, .recover => true,
        .lock, .status, .stop, .response, .progress => false,
    };
}
pub fn errorMessage(err: anyerror) []const u8 {
    return if (err == error.BackendProtocolMismatch) mismatch_message else @errorName(err);
}
pub fn requireExecutionProtocol(data: std.json.Value) !void {
    const generation = @import("json.zig").get(data, "executionProtocol") orelse return error.BackendProtocolMismatch;
    if (generation != .integer or generation.integer != execution_protocol) return error.BackendProtocolMismatch;
}
pub const Kind = enum(u8) { execute = 1, unlock = 2, lock = 3, status = 4, stop = 5, password_change = 6, recovery_change = 7, recover = 8, response = 128, progress = 129 };
pub const Frame = struct {
    kind: Kind,
    generation: u8 = execution_protocol,
    body: []u8,
    backing: ?std.mem.Allocator = null,
    pub fn deinit(self: *Frame, a: std.mem.Allocator) void {
        // Unlock passwords and private message DTOs both have bounded lives.
        std.crypto.secureZero(u8, self.body);
        (self.backing orelse a).free(self.body);
        self.body = &.{};
    }
};
pub fn uid() u32 {
    return if (builtin.os.tag == .linux) std.os.linux.geteuid() else std.c.geteuid();
}
pub fn defaultPath(buffer: []u8) ![]const u8 {
    // HOME/XDG_RUNTIME_DIR/login-session state must not change SSH discovery.
    return std.fmt.bufPrint(buffer, "{s}/omagma-{d}/daemon.sock", .{ @import("vault_paths.zig").temporary_root, uid() });
}
extern "c" fn getpeereid(c_int, *u32, *u32) c_int;
pub fn validatePeer(stream: std.Io.net.Stream) !void {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const Credentials = extern struct { pid: i32, uid: u32, gid: u32 };
        var credentials: Credentials = undefined;
        var length: linux.socklen_t = @sizeOf(Credentials);
        const code = linux.errno(linux.getsockopt(stream.socket.handle, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&credentials).ptr, &length));
        if (code != .SUCCESS or length != @sizeOf(Credentials)) return error.BackendPeerUnavailable;
        if (credentials.uid != uid()) return error.BackendPeerRejected;
    } else if (builtin.os.tag == .macos) {
        var peer_uid: u32 = undefined;
        var peer_gid: u32 = undefined;
        if (getpeereid(stream.socket.handle, &peer_uid, &peer_gid) != 0) return error.BackendPeerUnavailable;
        if (peer_uid != uid()) return error.BackendPeerRejected;
    } else return error.UnsupportedPlatform;
}

fn pathDirectory(io: std.Io, path: []const u8, create: bool) !std.Io.Dir {
    if (path.len == 0 or path[0] != '/' or path.len >= std.Io.net.UnixAddress.max_len or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidBackendPath;
    const directory = std.fs.path.dirname(path) orelse return error.InvalidBackendPath;
    return private.directory(io, directory, create);
}
pub const Listener = struct {
    io: std.Io,
    directory: std.Io.Dir,
    lease: std.Io.File,
    server: std.Io.net.Server,
    basename: []const u8,
    pub fn init(io: std.Io, path: []const u8) !Listener {
        const directory = try pathDirectory(io, path, true);
        errdefer directory.close(io);
        const lease = try native.openAt(io, directory, "daemon.lock", .{ .read_write = true, .create = true, .mode = 0o600 });
        errdefer lease.close(io);
        try private.privateFile(io, lease);
        if (!try lease.tryLock(io, .exclusive)) return error.BackendAlreadyRunning;
        errdefer lease.unlock(io);
        const basename = std.fs.path.basename(path);
        const prior = directory.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) null else return err;
        if (prior) |stat| {
            // Under the pinned private directory and daemon lease, only a
            // stale socket may be removed. Symlinks/ordinary files fail closed.
            if (stat.kind != .unix_domain_socket) return error.UnsafeBackendSocket;
            try directory.deleteFile(io, basename);
        }
        const address = try std.Io.net.UnixAddress.init(path);
        var server = try address.listen(io, .{ .kernel_backlog = 4 });
        errdefer server.deinit(io);
        // The surrounding 0700 directory protects the bind/chmod interval.
        try directory.setFilePermissions(io, basename, .fromMode(0o600), .{ .follow_symlinks = false });
        return .{ .io = io, .directory = directory, .lease = lease, .server = server, .basename = basename };
    }
    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
        self.directory.deleteFile(self.io, self.basename) catch {};
        self.lease.unlock(self.io);
        self.lease.close(self.io);
        self.directory.close(self.io);
    }
};

pub fn encodeHeader(kind: Kind, length: usize, limit: usize) ![header_bytes]u8 {
    if (length > limit or length > std.math.maxInt(u32)) return error.BackendFrameTooLarge;
    var bytes: [header_bytes]u8 = @splat(0);
    @memcpy(bytes[0..8], if (protectedKind(kind)) execution_magic else magic);
    bytes[8] = @backingInt(kind);
    std.mem.writeInt(u32, bytes[12..16], @intCast(length), .little);
    return bytes;
}
pub const Header = struct { kind: Kind, length: usize, generation: u8 };
pub fn decodeHeader(bytes: *const [header_bytes]u8, limit: usize) !Header {
    const generation: u8 = if (std.mem.eql(u8, bytes[0..8], execution_magic)) execution_protocol else if (std.mem.eql(u8, bytes[0..8], magic)) 1 else if (std.mem.eql(u8, bytes[0..8], "OMAVIPC2")) 2 else return error.InvalidBackendFrame;
    if (bytes[9] != 0 or bytes[10] != 0 or bytes[11] != 0) return error.InvalidBackendFrame;
    const kind = std.enums.fromInt(Kind, bytes[8]) orelse return error.InvalidBackendFrame;
    if (!protectedKind(kind) and generation != 1) return error.InvalidBackendFrame;
    const length = std.mem.readInt(u32, bytes[12..16], .little);
    if (length > limit or (kind == .progress and length > progress_limit)) return error.BackendFrameTooLarge;
    if ((kind == .unlock or kind == .password_change) and (length == 0 or length > @import("vault_types.zig").max_password_bytes)) return error.InvalidVaultPassword;
    if (kind == .recovery_change and length != 32) return error.InvalidRecoveryKey;
    if (kind == .recover and (length <= 32 or length > 32 + @import("vault_types.zig").max_password_bytes)) return error.InvalidVaultPassword;
    if ((kind == .lock or kind == .status or kind == .stop) and length != 0) return error.InvalidBackendFrame;
    return .{ .kind = kind, .length = length, .generation = generation };
}
pub fn readFrame(io: std.Io, a: std.mem.Allocator, stream: std.Io.net.Stream, limit: usize) !Frame {
    // This helper owns exactly one frame. A temporary read-ahead buffer can
    // consume the next progress/final header and discard it on return.
    var reader = stream.reader(io, &.{});
    const memory = @import("send_memory.zig");
    return readFrameReader(&reader.interface, a, if (memory.native) memory.allocator() else a, limit);
}
fn readFrameReader(reader: *std.Io.Reader, normal: std.mem.Allocator, expanded: std.mem.Allocator, limit: usize) !Frame {
    var bytes: [header_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    try reader.readSliceAll(&bytes);
    const decoded = try decodeHeader(&bytes, limit);
    if (protectedKind(decoded.kind) and decoded.generation != execution_protocol) return readIncompatibleFrame(reader, normal, decoded);
    const backing = if (decoded.kind == .execute and decoded.length > t.Limits.request_bytes) expanded else normal;
    const body = try readFrameBody(reader, backing, decoded.length);
    errdefer {
        std.crypto.secureZero(u8, body);
        backing.free(body);
    }
    if (decoded.kind == .execute and body.len > @import("send_memory.zig").requestLimit(body)) return error.InvalidRequest;
    return .{ .kind = decoded.kind, .generation = decoded.generation, .body = body, .backing = backing };
}
// Legacy bodies are never materialized or dispatched. Keep only correlation
// metadata so old clients can display the explicit refusal, even for large
// drafts; a malformed body still cannot turn into a data operation.
fn readIncompatibleFrame(reader: *std.Io.Reader, a: std.mem.Allocator, header: Header) !Frame {
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var limited = reader.limited(.limited(header.length), &buffer);
    var scratch: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    var scanner = std.json.Reader.init(fixed.allocator(), &limited.interface);
    defer scanner.deinit();
    const meta = if (header.kind == .execute) incompatibleMetadata(&scanner, fixed.allocator()) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedEndOfInput, error.ValueTooLong, error.InvalidRequest, error.InvalidCharacter, error.Overflow => Metadata{},
        // Socket cancellation is a one-shot ReadFailed. Propagate it (and
        // allocation failures) without another read which could block again.
        else => return err,
    } else Metadata{};
    var drain_buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &drain_buffer);
    var discard: std.Io.Writer.Discarding = .init(&drain_buffer);
    _ = try limited.interface.streamRemaining(&discard.writer);
    const body = try @import("json.zig").encodeAlloc(a, .{ .id = meta.id, .account = meta.account, .cmd = meta.command }, .{});
    return .{ .kind = header.kind, .generation = header.generation, .body = body, .backing = a };
}
fn incompatibleMetadata(scanner: *std.json.Reader, a: std.mem.Allocator) !Metadata {
    if (try scanner.next() != .object_begin) return error.InvalidRequest;
    var meta: Metadata = .{};
    while (true) {
        const key_token = try scanner.nextAllocMax(a, .alloc_always, 128);
        if (key_token == .object_end) break;
        const key = switch (key_token) {
            .string, .allocated_string => |value| value,
            else => return error.InvalidRequest,
        };
        if (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "account") or std.mem.eql(u8, key, "cmd")) {
            const value = try scanner.nextAllocMax(a, .alloc_always, 256);
            if (std.mem.eql(u8, key, "id")) {
                meta.id = switch (value) {
                    .string, .allocated_string => |text| .{ .string = text },
                    .number, .allocated_number => |text| .{ .integer = try std.fmt.parseInt(i64, text, 10) },
                    .null => .null,
                    else => return error.InvalidRequest,
                };
            } else {
                const text = switch (value) {
                    .string, .allocated_string => |text| text,
                    else => return error.InvalidRequest,
                };
                if (std.mem.eql(u8, key, "account")) meta.account = text else meta.command = text;
            }
        } else try scanner.skipValue();
        // Allocated metadata is short-lived fixed scratch. Free key storage
        // where possible; neither payload strings nor arrays are retained.
        if (key_token == .allocated_string) a.free(key_token.allocated_string);
    }
    if (try scanner.next() != .end_of_document) return error.InvalidRequest;
    return meta;
}
fn readFrameBody(reader: *std.Io.Reader, backing: std.mem.Allocator, length: usize) ![]u8 {
    if (length <= t.Limits.request_bytes) {
        const body = try backing.alloc(u8, length);
        errdefer {
            std.crypto.secureZero(u8, body);
            backing.free(body);
        }
        try reader.readSliceAll(body);
        return body;
    }
    // A peer can advertise a large valid frame and then send nothing. Grow
    // only after bytes arrive, so its arrival deadline cannot force a huge
    // allocation followed by wiping pages that never held received content.
    var secure: @import("vault_allocator.zig").WipingAllocator = .{ .backing = backing };
    const a = secure.allocator();
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(a);
    var chunk: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &chunk);
    while (body.items.len < length) {
        const wanted = @min(chunk.len, length - body.items.len);
        if (try reader.readSliceShort(chunk[0..wanted]) != wanted) return error.EndOfStream;
        const needed = body.items.len + wanted;
        if (needed > body.capacity) {
            const capacity = @min(length, @max(needed, body.capacity +| body.capacity / 2));
            try body.ensureTotalCapacityPrecise(a, capacity);
        }
        body.appendSliceAssumeCapacity(chunk[0..wanted]);
    }
    // The temporary wiping wrapper has no allocation header and must not
    // escape. The exact slice belongs to the original backing in Frame.
    return body.toOwnedSlice(a);
}
pub fn writeFrame(io: std.Io, stream: std.Io.net.Stream, kind: Kind, body: []const u8, limit: usize) !void {
    const bytes = try encodeHeader(kind, body.len, limit);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(&bytes);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

pub fn disconnectError(command: []const u8) anyerror {
    return if (@import("client_contract.zig").readOnlyCommand(command)) error.BackendStopped else error.UnknownOutcome;
}
pub fn disconnectRequestError(meta: Metadata) anyerror {
    return if (@import("client_contract.zig").readOnlyEnvelope(meta.command, meta.reconcile)) error.BackendStopped else error.UnknownOutcome;
}
pub fn executionSeconds(command: []const u8) i64 {
    // OAuth owns a180-second consent deadline inside auth.run, followed by a
    // durable identity commit. Lock interrupts this class explicitly.
    return if (std.mem.eql(u8, command, "auth.authorize")) 190 else @import("send_memory.zig").seconds(command);
}
pub const Metadata = struct { id: std.json.Value = .null, account: []const u8 = "", command: []const u8 = "", vault_id: []const u8 = "", secret_field: bool = false, reconcile: bool = false, progress: bool = false, cancel_disconnect: bool = false };
/// Read only the envelope with fixed scratch. Large body/recipient arrays are
/// skipped without allocating copies, including during an OOM error response.
pub fn requestMetadata(a: std.mem.Allocator, raw: []const u8) !Metadata {
    if (raw.len > @import("send_memory.zig").requestLimit(raw) or !@import("core.zig").boundedJson(raw)) return error.InvalidRequest;
    var scanner = std.json.Scanner.initCompleteInput(a, raw);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidRequest;
    var result: Metadata = .{};
    var reconcile_seen = false;
    var progress_seen = false;
    var cancel_seen = false;
    while (true) {
        const key_token = try scanner.nextAllocMax(a, .alloc_if_needed, 128);
        if (key_token == .object_end) break;
        const key = switch (key_token) {
            .string, .allocated_string => |value| value,
            else => return error.InvalidRequest,
        };
        if (secretField(key)) {
            result.secret_field = true;
            try scanner.skipValue();
        } else if (std.mem.eql(u8, key, "reconcile")) {
            if (reconcile_seen) return error.InvalidRequest;
            reconcile_seen = true;
            result.reconcile = switch (try scanner.next()) {
                .true => true,
                .false => false,
                else => return error.InvalidRequest,
            };
        } else if (std.mem.eql(u8, key, "_progress") or std.mem.eql(u8, key, "_cancelOnDisconnect")) {
            const is_progress = std.mem.eql(u8, key, "_progress");
            if ((is_progress and progress_seen) or (!is_progress and cancel_seen)) return error.InvalidRequest;
            const enabled = switch (try scanner.next()) {
                .true => true,
                .false => false,
                else => return error.InvalidRequest,
            };
            if (is_progress) {
                result.progress = enabled;
                progress_seen = true;
            } else {
                result.cancel_disconnect = enabled;
                cancel_seen = true;
            }
        } else if (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "account") or std.mem.eql(u8, key, "cmd") or std.mem.eql(u8, key, "_vaultId")) {
            const token = try scanner.nextAllocMax(a, .alloc_if_needed, 256);
            if (std.mem.eql(u8, key, "id")) {
                result.id = switch (token) {
                    .string, .allocated_string => |value| .{ .string = value },
                    .number, .allocated_number => |value| .{ .integer = try std.fmt.parseInt(i64, value, 10) },
                    .null => .null,
                    else => return error.InvalidRequest,
                };
            } else {
                const value = switch (token) {
                    .string, .allocated_string => |value| value,
                    else => return error.InvalidRequest,
                };
                if (std.mem.eql(u8, key, "account")) result.account = value else if (std.mem.eql(u8, key, "_vaultId")) result.vault_id = value else result.command = value;
            }
        } else try skipCheckedValue(&scanner, a, &result.secret_field);
        if (key_token == .allocated_string) a.free(key_token.allocated_string);
    }
    if (try scanner.next() != .end_of_document) return error.InvalidRequest;
    return result;
}
fn skipCheckedValue(scanner: *std.json.Scanner, a: std.mem.Allocator, secret: *bool) anyerror!void {
    switch (try scanner.peekNextTokenType()) {
        .object_begin => {
            _ = try scanner.next();
            while (try scanner.peekNextTokenType() != .object_end) {
                const token = try scanner.nextAllocMax(a, .alloc_if_needed, 256);
                defer if (token == .allocated_string) a.free(token.allocated_string);
                const key = switch (token) {
                    .string, .allocated_string => |value| value,
                    else => return error.InvalidRequest,
                };
                if (secretField(key)) {
                    secret.* = true;
                    try scanner.skipValue();
                } else try skipCheckedValue(scanner, a, secret);
            }
            _ = try scanner.next();
        },
        .array_begin => {
            _ = try scanner.next();
            while (try scanner.peekNextTokenType() != .array_end) try skipCheckedValue(scanner, a, secret);
            _ = try scanner.next();
        },
        else => try scanner.skipValue(),
    }
}
pub fn secretField(key: []const u8) bool {
    for ([_][]const u8{ "password", "newPassword", "currentPassword", "passwordConfirmation", "recoveryKey", "refreshToken", "clientSecret", "refresh_token", "client_secret", "access_token", "accessToken" }) |name| if (std.ascii.eqlIgnoreCase(key, name)) return true;
    return false;
}
pub const Client = struct {
    io: std.Io,
    socket_path: []const u8,
    expected_vault_id: ?@import("vault_types.zig").Id = null,
    pub fn client(self: *Client) t.Client {
        return .{ .ctx = self, .callFn = call, .cachedFn = cached, .callProgressFn = callProgress };
    }
    fn call(context: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.execute(a, raw) catch |err| {
            var scratch: [4096]u8 = undefined;
            defer std.crypto.secureZero(u8, &scratch);
            var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
            const meta = requestMetadata(fixed.allocator(), raw) catch Metadata{};
            const report = switch (err) {
                error.FileNotFound, error.ConnectionRefused => error.BackendRequired,
                else => err,
            };
            return failure(a, meta, report);
        };
    }
    fn callProgress(context: *anyopaque, a: std.mem.Allocator, raw: []const u8, sink: t.ProgressSink) ![]const u8 {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.executeWithProgress(a, raw, sink) catch |err| {
            var scratch: [4096]u8 = undefined;
            defer std.crypto.secureZero(u8, &scratch);
            var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
            const meta = requestMetadata(fixed.allocator(), raw) catch Metadata{};
            return failure(a, meta, switch (err) {
                error.FileNotFound, error.ConnectionRefused => error.BackendRequired,
                else => err,
            });
        };
    }
    fn failure(a: std.mem.Allocator, meta: Metadata, report: anyerror) ![]const u8 {
        return @import("json.zig").encodeAlloc(a, .{ .version = @as(u8, 1), .id = meta.id, .ok = false, .account = meta.account, .@"error" = .{ .code = @errorName(report), .message = if (report == error.UnknownOutcome) "Outcome is unknown; do not automatically retry" else errorMessage(report) } }, .{}) catch |err| {
            // Allocation failure while reporting an admitted mutation must
            // not replace the warning already established by the exchange.
            return if (report == error.UnknownOutcome) error.UnknownOutcome else err;
        };
    }
    fn execute(self: *Client, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        return self.executeWithProgress(a, raw, null);
    }
    fn executeWithProgress(self: *Client, a: std.mem.Allocator, raw: []const u8, sink: ?t.ProgressSink) ![]const u8 {
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = try requestMetadata(fixed.allocator(), raw);
        if (meta.secret_field) return error.VaultSecretRequiresPrompt;
        const cancel = cancellableSend(meta.command);
        if (self.expected_vault_id == null and sink == null and !cancel) return self.request(a, .execute, raw);
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        var value = try std.json.parseFromSliceLeaky(std.json.Value, temp, raw, .{ .allocate = .alloc_if_needed, .max_value_len = request_limit });
        if (self.expected_vault_id) |expected| {
            const hex = std.fmt.bytesToHex(expected, .lower);
            if (meta.vault_id.len != 0 and !std.mem.eql(u8, meta.vault_id, &hex)) return error.VaultIdentityMismatch;
            try value.object.put(temp, "_vaultId", .{ .string = try temp.dupe(u8, &hex) });
        }
        if (sink != null) try value.object.put(temp, "_progress", .{ .bool = true });
        if (cancel) try value.object.put(temp, "_cancelOnDisconnect", .{ .bool = true });
        return self.requestProgress(a, .execute, try @import("json.zig").encodeAlloc(temp, value, .{}), sink);
    }

    fn cached(context: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{ .allocate = .alloc_always });
        if (value != .object or !@import("client_contract.zig").cachedRequest(value)) return error.CacheUnsupported;
        var copy = value;
        try copy.object.put(arena.allocator(), "cacheOnly", .{ .bool = true });
        return call(context, a, try std.json.Stringify.valueAlloc(arena.allocator(), copy, .{}));
    }
    pub fn request(self: *Client, a: std.mem.Allocator, kind: Kind, body: []const u8) ![]const u8 {
        return self.requestProgress(a, kind, body, null);
    }
    fn requestProgress(self: *Client, a: std.mem.Allocator, kind: Kind, body: []const u8, sink: ?t.ProgressSink) ![]const u8 {
        var submitted = false;
        var response: ?[]const u8 = null;
        errdefer if (response) |bytes| {
            std.crypto.secureZero(u8, @constCast(bytes));
            a.free(bytes);
        };
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = if (kind == .execute) try requestMetadata(fixed.allocator(), body) else Metadata{};
        // Only transport waiting has this ceiling. The daemon retains the
        // ordinary deadline unless its authoritative plan admits Drive.
        const seconds = if (kind == .execute) (if (@import("send_budget.zig").eligible(meta.command)) @import("send_budget.zig").transport_seconds else executionSeconds(meta.command) + 15) else 45;
        platform.deadline(self.io, platform.seconds(seconds), exchange, .{ self, a, kind, body, &submitted, &response, sink, meta.progress }) catch |err| {
            if (kind != .execute or !submitted) return err;
            return disconnectRequestError(meta);
        };
        return response.?;
    }
    fn exchange(self: *Client, a: std.mem.Allocator, kind: Kind, body: []const u8, submitted: *bool, output: *?[]const u8, sink: ?t.ProgressSink, progress_allowed: bool) !void {
        _ = try decodeHeader(&(try encodeHeader(kind, body.len, request_limit)), request_limit);
        if (protectedKind(kind)) try self.checkExecutionProtocol(a);
        const stream = try self.connect();
        defer stream.close(self.io);
        submitted.* = true;
        try writeFrame(self.io, stream, kind, body, request_limit);
        var progress_count: usize = 0;
        while (true) {
            var response = try readFrame(self.io, a, stream, if (kind == .execute and @import("send_memory.zig").request(body)) response_limit else ordinary_response_limit);
            var returned = false;
            defer if (!returned) response.deinit(a);
            if (response.kind == .progress) {
                progress_count += 1;
                if (!progress_allowed or progress_count > 32768) return error.InvalidBackendFrame;
                var scratch: [4096]u8 = undefined;
                var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
                const progress = try std.json.parseFromSliceLeaky(t.FetchProgress, fixed.allocator(), response.body, .{});
                try validateProgress(progress);
                if (sink) |target| target.report(progress);
                continue;
            }
            if (response.kind != .response) return error.InvalidBackendFrame;
            output.* = response.body;
            returned = true;
            return;
        }
    }
    fn checkExecutionProtocol(self: *Client, a: std.mem.Allocator) !void {
        const stream = try self.connect();
        defer stream.close(self.io);
        try writeFrame(self.io, stream, .status, "", request_limit);
        var response = try readFrame(self.io, a, stream, 4096);
        defer response.deinit(a);
        if (response.kind != .response) return error.InvalidBackendFrame;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response.body, .{ .allocate = .alloc_if_needed });
        const data = @import("json.zig").get(value, "data") orelse return error.InvalidBackendFrame;
        if (self.expected_vault_id) |id| if (!std.mem.eql(u8, @import("json.zig").text(data, "vaultId"), &std.fmt.bytesToHex(id, .lower))) return error.VaultIdentityMismatch;
        try requireExecutionProtocol(data);
    }
    fn connect(self: *Client) !std.Io.net.Stream {
        var directory = try pathDirectory(self.io, self.socket_path, false);
        defer directory.close(self.io);
        const stat = try directory.statFile(self.io, std.fs.path.basename(self.socket_path), .{ .follow_symlinks = false });
        if (stat.kind != .unix_domain_socket or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeBackendSocket;
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        const stream = try address.connect(self.io);
        errdefer stream.close(self.io);
        try validatePeer(stream);
        return stream;
    }
};

test "vault transport: frame boundaries are shared and unknown commands are mutations" {
    const a = try encodeHeader(.execute, request_limit, request_limit);
    try std.testing.expectEqual(request_limit, (try decodeHeader(&a, request_limit)).length);
    try std.testing.expectError(error.BackendFrameTooLarge, encodeHeader(.execute, request_limit + 1, request_limit));
    const b = try encodeHeader(.response, response_limit, response_limit);
    try std.testing.expectEqual(response_limit, (try decodeHeader(&b, response_limit)).length);
    try std.testing.expectError(error.BackendFrameTooLarge, decodeHeader(&b, request_limit));
    try std.testing.expectError(error.InvalidBackendFrame, decodeHeader(&(try encodeHeader(.lock, 1, request_limit)), request_limit));
    try std.testing.expectError(error.InvalidVaultPassword, decodeHeader(&(try encodeHeader(.unlock, 1025, request_limit)), request_limit));
    try std.testing.expectEqual(error.BackendStopped, disconnectError("mail.read"));
    for ([_][]const u8{ "draft.create", "attachment.import", "cache.clear", "queue.cancel", "future.command" }) |command| try std.testing.expectEqual(error.UnknownOutcome, disconnectError(command));
}

const FrameReadAudit = struct {
    used: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,
    unwiped_free: bool = false,
    limit: usize = 16 * 1024 * 1024,

    fn allocator(self: *FrameReadAudit) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FrameReadAudit = @ptrCast(@alignCast(context));
        if (length > self.limit - self.used) return null;
        const bytes = std.testing.allocator.rawAlloc(length, alignment, ra) orelse return null;
        self.used += length;
        self.peak = @max(self.peak, self.used);
        self.allocations += 1;
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FrameReadAudit = @ptrCast(@alignCast(context));
        for (bytes) |byte| if (byte != 0) {
            self.unwiped_free = true;
            break;
        };
        self.used -= bytes.len;
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};

test "vault transport: largest missing frames allocate nothing and partial frames wipe only received storage" {
    for ([_]Kind{ .execute, .response }) |kind| {
        const limit = if (kind == .execute) request_limit else response_limit;
        const header = try encodeHeader(kind, limit, limit);
        var normal: FrameReadAudit = .{ .limit = 64 * 1024 };
        var expanded: FrameReadAudit = .{ .limit = 64 * 1024 };
        var empty = std.Io.Reader.fixed(&header);
        try std.testing.expectError(error.EndOfStream, readFrameReader(&empty, normal.allocator(), expanded.allocator(), limit));
        try std.testing.expectEqual(@as(usize, 0), normal.allocations + expanded.allocations);
        const partial = try std.testing.allocator.alloc(u8, header.len + 16 * 1024 + 9);
        defer std.testing.allocator.free(partial);
        @memcpy(partial[0..header.len], &header);
        @memset(partial[header.len..], 0x47);
        var short = std.Io.Reader.fixed(partial);
        try std.testing.expectError(error.EndOfStream, readFrameReader(&short, normal.allocator(), expanded.allocator(), limit));
        try std.testing.expectEqual(@as(usize, 16 * 1024), normal.peak + expanded.peak);
        try std.testing.expectEqual(@as(usize, 0), normal.used + expanded.used);
        try std.testing.expect(!normal.unwiped_free and !expanded.unwiped_free);
    }
}

test "vault transport: growing requests and responses preserve exact bytes original backing and command limits" {
    if (!@import("send_memory.zig").native) return error.SkipZigTest;
    const size = t.Limits.request_bytes + 257;
    const wire = try std.testing.allocator.alloc(u8, header_bytes + size);
    defer std.testing.allocator.free(wire);
    const prefix = "{\"cmd\":\"draft.preview\",\"padding\":\"";
    @memcpy(wire[header_bytes..][0..prefix.len], prefix);
    @memset(wire[header_bytes + prefix.len .. wire.len - 2], 'x');
    @memcpy(wire[wire.len - 2 ..], "\"}");
    for ([_]Kind{ .execute, .response }) |kind| {
        @memcpy(wire[0..header_bytes], &(try encodeHeader(kind, size, response_limit)));
        var normal: FrameReadAudit = .{};
        var expanded: FrameReadAudit = .{};
        var reader = std.Io.Reader.fixed(wire);
        var frame = try readFrameReader(&reader, normal.allocator(), expanded.allocator(), response_limit);
        try std.testing.expectEqualSlices(u8, wire[header_bytes..], frame.body);
        const owner = if (kind == .execute) &expanded else &normal;
        const unused = if (kind == .execute) &normal else &expanded;
        try std.testing.expectEqual(owner.allocator(), frame.backing.?);
        try std.testing.expectEqual(size, owner.used);
        try std.testing.expect(owner.allocations > 1);
        try std.testing.expectEqual(@as(usize, 0), unused.allocations);
        // Inspect every released growth block before the final high-level
        // free: std.mem.Allocator.free may poison its bytes after deinit's
        // explicit secureZero in Debug, before this audit sees rawFree.
        try std.testing.expect(!owner.unwiped_free);
        // The local wiping wrapper is gone: deinit must still use the caller's
        // original backing, even when the supplied fallback differs.
        frame.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), owner.used);
    }
    const ordinary = "{\"cmd\":\"mail.read\",\"padding\":\"";
    @memcpy(wire[0..header_bytes], &(try encodeHeader(.execute, size, request_limit)));
    @memcpy(wire[header_bytes..][0..ordinary.len], ordinary);
    @memset(wire[header_bytes + ordinary.len .. wire.len - 2], 'x');
    var audit: FrameReadAudit = .{};
    // A caller-owned wiping backing observes the final cleanup below the
    // allocator's Debug poison, just as native private backing does.
    var secure: @import("vault_allocator.zig").WipingAllocator = .{ .backing = audit.allocator() };
    var reader = std.Io.Reader.fixed(wire);
    try std.testing.expectError(error.InvalidRequest, readFrameReader(&reader, secure.allocator(), secure.allocator(), request_limit));
    try std.testing.expectEqual(@as(usize, 0), audit.used);
    try std.testing.expect(!audit.unwiped_free);
    var failing: FrameReadAudit = .{ .limit = 16 * 1024 };
    reader = std.Io.Reader.fixed(wire);
    try std.testing.expectError(error.OutOfMemory, readFrameReader(&reader, failing.allocator(), failing.allocator(), request_limit));
    try std.testing.expectEqual(@as(usize, 0), failing.used);
    try std.testing.expect(!failing.unwiped_free);
}

test "vault transport: envelope metadata uses bounded scratch for large escaped bodies" {
    const a = std.testing.allocator;
    const body = try a.alloc(u8, 2 * 1024 * 1024);
    defer a.free(body);
    @memset(body, 'x');
    const request = try std.fmt.allocPrint(a, "{{\"draft\":{{\"bodyText\":\"{s}\",\"to\":[{{\"address\":\"synthetic@example.test\"}}]}},\"id\":\"escaped\\tcorrelation\",\"account\":\"personal@example.com\",\"cmd\":\"draft.create\"}}", .{body});
    defer a.free(request);
    var scratch: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const meta = try requestMetadata(fixed.allocator(), request);
    try std.testing.expectEqualStrings("escaped\tcorrelation", meta.id.string);
    try std.testing.expectEqualStrings("personal@example.com", meta.account);
    try std.testing.expectEqualStrings("draft.create", meta.command);
}

test "vault transport: secret controls are bounded and generic nested secret fields never route" {
    try std.testing.expectEqual(@as(i64, 190), executionSeconds("auth.authorize"));
    try std.testing.expectEqual(@as(i64, 30), executionSeconds("mail.refresh"));
    for ([_]Kind{ .unlock, .password_change }) |kind| {
        try std.testing.expectError(error.InvalidVaultPassword, decodeHeader(&(try encodeHeader(kind, 0, request_limit)), request_limit));
        _ = try decodeHeader(&(try encodeHeader(kind, 1024, request_limit)), request_limit);
    }
    try std.testing.expectError(error.InvalidRecoveryKey, decodeHeader(&(try encodeHeader(.recovery_change, 31, request_limit)), request_limit));
    try std.testing.expectError(error.InvalidVaultPassword, decodeHeader(&(try encodeHeader(.recover, 32, request_limit)), request_limit));
    _ = try decodeHeader(&(try encodeHeader(.recover, 1056, request_limit)), request_limit);
    var scratch: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const nested = try requestMetadata(fixed.allocator(), "{\"id\":\"secret-check\",\"cmd\":\"accounts.list\",\"nested\":[{\"client_secret\":\"synthetic-secret\"}]}");
    try std.testing.expect(nested.secret_field);
    try std.testing.expectEqualStrings("secret-check", nested.id.string);
    var client: Client = .{ .io = std.testing.io, .socket_path = "/missing/vault/socket" };
    try std.testing.expectError(error.VaultSecretRequiresPrompt, client.execute(std.testing.allocator, "{\"cmd\":\"accounts.list\",\"nested\":{\"password\":\"synthetic\"}}"));
}

test "vault transport: invitation reconciliation disconnect retains mutation uncertainty" {
    const cases = [_]struct { request: []const u8, reconcile: bool }{
        .{ .request = "{\"cmd\":\"invitation.inspect\"}", .reconcile = false },
        .{ .request = "{\"cmd\":\"invitation.inspect\",\"reconcile\":false}", .reconcile = false },
        .{ .request = "{\"reconcile\":true,\"cmd\":\"invitation.inspect\"}", .reconcile = true },
    };
    for (cases) |case| {
        var scratch: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = try requestMetadata(fixed.allocator(), case.request);
        try std.testing.expectEqual(case.reconcile, meta.reconcile);
        try std.testing.expectEqual(if (case.reconcile) error.UnknownOutcome else error.BackendStopped, disconnectRequestError(meta));
    }
    var scratch: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    try std.testing.expectError(error.InvalidRequest, requestMetadata(fixed.allocator(), "{\"cmd\":\"invitation.inspect\",\"reconcile\":true,\"reconcile\":false}"));
    try std.testing.expectError(error.InvalidRequest, requestMetadata(fixed.allocator(), "{\"cmd\":\"invitation.inspect\",\"reconcile\":\"true\"}"));
    try std.testing.expectEqual(error.UnknownOutcome, disconnectError("invitation.inspect"));
    var client: Client = .{ .io = std.testing.io, .socket_path = "/missing/vault/socket" };
    try std.testing.expectError(error.CacheUnsupported, Client.cached(&client, std.testing.allocator, "{\"cmd\":\"invitation.inspect\",\"reconcile\":true}"));
}

test "post-dispatch receipt: vault error encoding cannot replace unknown mutation outcome" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const meta: Metadata = .{ .id = .{ .string = "request-7" }, .account = "self@example.test", .command = "draft.send" };
    try std.testing.expectError(error.UnknownOutcome, Client.failure(failing.allocator(), meta, error.UnknownOutcome));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectError(error.OutOfMemory, Client.failure(failing.allocator(), meta, error.BackendRequired));
    try std.testing.expectError(error.OutOfMemory, Client.failure(failing.allocator(), .{ .command = "mail.read" }, error.BackendStopped));
    const bytes = try Client.failure(std.testing.allocator, meta, error.UnknownOutcome);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const json = @import("json.zig");
    try std.testing.expectEqualStrings("request-7", json.text(parsed.value, "id"));
    try std.testing.expectEqualStrings(meta.account, json.text(parsed.value, "account"));
    try std.testing.expectEqualStrings("UnknownOutcome", json.text(json.get(parsed.value, "error").?, "code"));
}

test "vault protocol: protected headers reject old daemon parsing while controls remain compatible" {
    for ([_]Kind{ .execute, .unlock, .password_change, .recovery_change, .recover, .lock, .status, .stop, .response }) |kind| {
        const length: usize = switch (kind) {
            .unlock, .password_change => 1,
            .recovery_change => 32,
            .recover => 33,
            else => 0,
        };
        const header = try encodeHeader(kind, length, request_limit);
        try std.testing.expectEqualStrings(if (protectedKind(kind)) execution_magic else magic, header[0..8]);
        // Public v0.2.12 requires OMAVIPC1 before it decodes or dispatches any
        // command; this independent check also covers a swap after preflight.
        try std.testing.expectEqual(!protectedKind(kind), std.mem.eql(u8, header[0..8], "OMAVIPC1"));
        var legacy = header;
        @memcpy(legacy[0..8], "OMAVIPC1");
        try std.testing.expectEqual(@as(u8, 1), (try decodeHeader(&legacy, request_limit)).generation);
    }
}

test "vault protocol: legacy bodies retain only bounded refusal metadata and never payload" {
    const a = std.testing.allocator;
    const prefix = "{\"draft\":{\"bodyText\":\"";
    const suffix = "\"},\"id\":\"legacy-request\",\"account\":\"self@example.test\",\"cmd\":\"draft.create\"}";
    const body_size = prefix.len + 1024 * 1024 + suffix.len;
    const wire = try a.alloc(u8, header_bytes + body_size);
    defer a.free(wire);
    @memcpy(wire[0..header_bytes], &(try encodeHeader(.execute, body_size, request_limit)));
    @memcpy(wire[0..8], "OMAVIPC1");
    @memcpy(wire[header_bytes..][0..prefix.len], prefix);
    @memset(wire[header_bytes + prefix.len ..][0 .. 1024 * 1024], 'x');
    @memcpy(wire[wire.len - suffix.len ..], suffix);
    var reader: std.Io.Reader = .fixed(wire);
    var small: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&small);
    var frame = try readFrameReader(&reader, fixed.allocator(), std.testing.failing_allocator, request_limit);
    defer frame.deinit(fixed.allocator());
    try std.testing.expectEqual(@as(u8, 1), frame.generation);
    try std.testing.expect(frame.body.len < 256);
    var metadata_storage: [4096]u8 = undefined;
    var metadata_allocator: std.heap.FixedBufferAllocator = .init(&metadata_storage);
    const meta = try requestMetadata(metadata_allocator.allocator(), frame.body);
    try std.testing.expectEqualStrings("legacy-request", meta.id.string);
    try std.testing.expectEqualStrings("self@example.test", meta.account);
    try std.testing.expectEqualStrings("draft.create", meta.command);
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
    for ([_][]const u8{ "{", "not-json", "{\"id\":{}}" }) |bad| {
        var bytes: [128]u8 = undefined;
        @memcpy(bytes[0..header_bytes], &(try encodeHeader(.execute, bad.len, request_limit)));
        @memcpy(bytes[0..8], "OMAVIPC1");
        @memcpy(bytes[header_bytes..][0..bad.len], bad);
        var invalid: std.Io.Reader = .fixed(bytes[0 .. header_bytes + bad.len]);
        var refused = try readFrameReader(&invalid, a, std.testing.failing_allocator, request_limit);
        defer refused.deinit(a);
        try std.testing.expectEqual(@as(u8, 1), refused.generation);
    }
}

test "vault protocol: canceled legacy metadata reads propagate without a second socket read" {
    const Failing = struct {
        reader: std.Io.Reader,
        reads: usize = 0,
        fn stream(input: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *@This() = @fieldParentPtr("reader", input);
            self.reads += 1;
            // Stream.Reader translates the socket's one-shot Canceled into
            // ReadFailed. Any second call would block again on a real peer.
            return if (self.reads == 1) error.ReadFailed else error.EndOfStream;
        }
    };
    const prefix = "{\"draft\":{\"bodyText\":\"";
    var bytes: [header_bytes + prefix.len]u8 = undefined;
    @memcpy(bytes[0..header_bytes], &(try encodeHeader(.execute, 1024 * 1024, request_limit)));
    @memcpy(bytes[0..8], "OMAVIPC1");
    @memcpy(bytes[header_bytes..], prefix);
    var input: Failing = .{ .reader = .{ .vtable = &.{ .stream = Failing.stream }, .buffer = &bytes, .seek = 0, .end = bytes.len } };
    if (readFrameReader(&input.reader, std.testing.allocator, std.testing.failing_allocator, request_limit)) |frame| {
        var owned = frame;
        owned.deinit(std.testing.allocator);
        return error.TestExpectedReadFailure;
    } else |err| try std.testing.expectEqual(error.ReadFailed, err);
    try std.testing.expectEqual(@as(usize, 1), input.reads);
}

test "vault protocol: new client refuses old peers before execute but keeps status lock and stop" {
    test_allocator.install();
    const io = std.testing.io;
    const a = test_allocator.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.parent_dir.setFilePermissions(io, &tmp.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/socket", .{root});
    defer a.free(path);
    var listener = try Listener.init(io, path);
    defer listener.deinit();
    const Peer = struct {
        fn run(server: *Listener, seen: *std.atomic.Value(usize)) !void {
            const peer_io = std.testing.io;
            for ([_]Kind{ .status, .status, .status, .lock, .stop }) |expected| {
                const stream = try server.server.accept(peer_io);
                defer stream.close(peer_io);
                var buffer: [16]u8 = undefined;
                var input = stream.reader(peer_io, &.{});
                try input.interface.readSliceAll(&buffer);
                try std.testing.expectEqualStrings("OMAVIPC1", buffer[0..8]);
                try std.testing.expectEqual(@backingInt(expected), buffer[8]);
                try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buffer[12..16], .little));
                _ = seen.fetchAdd(1, .release);
                try writeFrame(peer_io, stream, .response, "{\"ok\":true,\"data\":{\"unlocked\":true}}", response_limit);
            }
        }
    };
    var seen: std.atomic.Value(usize) = .init(0);
    var peer = try io.concurrent(Peer.run, .{ &listener, &seen });
    defer peer.cancel(io) catch {};
    var client: Client = .{ .io = io, .socket_path = path };
    const refused = try client.client().call(a, "{\"id\":\"old-peer\",\"account\":\"self@example.test\",\"cmd\":\"draft.send\"}");
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "BackendProtocolMismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "omagma vault stop") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "old-peer") != null);
    try std.testing.expectError(error.BackendProtocolMismatch, client.request(a, .unlock, "never transmitted"));
    for ([_]Kind{ .status, .lock, .stop }) |kind| {
        const bytes = try client.request(a, kind, "");
        a.free(bytes);
    }
    try peer.await(io);
    try std.testing.expectEqual(@as(usize, 5), seen.load(.acquire));
}

test "vault protocol: daemon swap after preflight still cannot dispatch new semantics to an old peer" {
    test_allocator.install();
    const io = std.testing.io;
    const a = test_allocator.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.parent_dir.setFilePermissions(io, &tmp.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/socket", .{root});
    defer a.free(path);
    var listener = try Listener.init(io, path);
    defer listener.deinit();
    const Peer = struct {
        fn run(server: *Listener, dispatches: *std.atomic.Value(usize)) !void {
            const peer_io = std.testing.io;
            {
                const stream = try server.server.accept(peer_io);
                defer stream.close(peer_io);
                var frame = try readFrame(peer_io, test_allocator.allocator, stream, request_limit);
                defer frame.deinit(test_allocator.allocator);
                try std.testing.expectEqual(Kind.status, frame.kind);
                try writeFrame(peer_io, stream, .response, "{\"ok\":true,\"data\":{\"executionProtocol\":3}}", response_limit);
            }
            // The next connection is handled using the old daemon's exact
            // magic check, as if it replaced the daemon after status returned.
            const stream = try server.server.accept(peer_io);
            defer stream.close(peer_io);
            var input = stream.reader(peer_io, &.{});
            var header: [header_bytes]u8 = undefined;
            try input.interface.readSliceAll(&header);
            if (std.mem.eql(u8, header[0..8], "OMAVIPC2")) _ = dispatches.fetchAdd(1, .release);
            try std.testing.expectEqualStrings("OMAVIPC3", header[0..8]);
            try std.testing.expectEqual(@as(u8, 1), header[8]);
        }
    };
    var dispatches: std.atomic.Value(usize) = .init(0);
    var peer = try io.concurrent(Peer.run, .{ &listener, &dispatches });
    defer peer.cancel(io) catch {};
    var client: Client = .{ .io = io, .socket_path = path };
    // The client cannot prove what a disconnected peer did after submission;
    // its ordinary uncertainty rule remains intact, while the oracle proves
    // that an old parser cannot possibly reach dispatch with the new frame.
    try std.testing.expectError(error.UnknownOutcome, client.request(a, .execute, "{\"cmd\":\"draft.send\"}"));
    try peer.await(io);
    try std.testing.expectEqual(@as(usize, 0), dispatches.load(.acquire));
}

fn cancellableSend(command: []const u8) bool {
    for ([_][]const u8{ "mail.send", "draft.send", "queue.process", "queue.send-now" }) |name| if (std.mem.eql(u8, command, name)) return true;
    return false;
}
pub fn validateProgress(progress: t.FetchProgress) !void {
    if (progress.completed > progress.total or progress.total > t.Limits.disk_hard) return error.InvalidBackendFrame;
    if (progress.fileIndex) |index| if (index >= t.Limits.attachments) return error.InvalidBackendFrame;
    if (progress.fileCount) |count| if (count > @import("attachment_delivery.zig").max_drive_files) return error.InvalidBackendFrame;
}

test "vault protocol: V2 execution is drained without allocating its payload" {
    const body = "{\"id\":\"v2-attach\",\"cmd\":\"mail.send\",\"draft\":{\"attachments\":[{\"delivery\":\"drive\"}]}}";
    var wire: [header_bytes + body.len]u8 = undefined;
    @memcpy(wire[0..header_bytes], &(try encodeHeader(.execute, body.len, request_limit)));
    @memcpy(wire[0..8], "OMAVIPC2");
    @memcpy(wire[header_bytes..], body);
    var reader: std.Io.Reader = .fixed(&wire);
    var scratch: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    var frame = try readFrameReader(&reader, fixed.allocator(), std.testing.failing_allocator, request_limit);
    defer frame.deinit(fixed.allocator());
    try std.testing.expectEqual(@as(u8, 2), frame.generation);
    try std.testing.expect(std.mem.indexOf(u8, frame.body, "attachments") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame.body, "v2-attach") != null);
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
}

test "vault protocol: progress admission is strict and oversized frames allocate nothing" {
    for ([_][]const u8{
        "{\"cmd\":\"mail.send\",\"_progress\":1}",
        "{\"cmd\":\"mail.send\",\"_cancelOnDisconnect\":\"true\"}",
        "{\"_progress\":true,\"_progress\":false}",
        "{\"_cancelOnDisconnect\":false,\"_cancelOnDisconnect\":true}",
    }) |raw| {
        var scratch: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        try std.testing.expectError(error.InvalidRequest, requestMetadata(fixed.allocator(), raw));
    }
    var scratch: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const meta = try requestMetadata(fixed.allocator(), "{\"cmd\":\"draft.send\",\"_progress\":true,\"_cancelOnDisconnect\":true}");
    try std.testing.expect(meta.progress and meta.cancel_disconnect);
    const header = try encodeHeader(.progress, progress_limit + 1, response_limit);
    var reader: std.Io.Reader = .fixed(&header);
    try std.testing.expectError(error.BackendFrameTooLarge, readFrameReader(&reader, std.testing.failing_allocator, std.testing.failing_allocator, response_limit));
    try validateProgress(.{ .phase = .drive_uploading, .completed = 4096, .total = 8192, .fileIndex = 100, .fileCount = 16 });
    try std.testing.expectError(error.InvalidBackendFrame, validateProgress(.{ .phase = .drive_uploading, .completed = 2, .total = 1 }));
    try std.testing.expectError(error.InvalidBackendFrame, validateProgress(.{ .phase = .drive_uploading, .completed = 0, .total = t.Limits.disk_hard + 1 }));
    try std.testing.expectError(error.InvalidBackendFrame, validateProgress(.{ .phase = .drive_uploading, .completed = 0, .total = 1, .fileIndex = t.Limits.attachments }));
    try std.testing.expectError(error.InvalidBackendFrame, validateProgress(.{ .phase = .drive_uploading, .completed = 0, .total = 1, .fileCount = 17 }));
    try std.testing.expect(cancellableSend("draft.send") and !cancellableSend("draft.gmail-push") and !cancellableSend("mail.modify"));
}
