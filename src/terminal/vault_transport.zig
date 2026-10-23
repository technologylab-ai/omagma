//! Private same-user Unix transport. One request per connection; never retry.
//! The wire carries command DTOs, never the daemon's data key or OAuth tokens.
const std = @import("std");
const builtin = @import("builtin");
const t = @import("types.zig");
const platform = @import("../platform.zig");
const private = @import("../keyring_file.zig");
const native = @import("../native_file.zig");

pub const request_limit = @import("send_memory.zig").record_bytes;
pub const response_limit = request_limit + 64 * 1024;
pub const ordinary_response_limit = 32 * 1024 * 1024;
pub const header_bytes = 16;
pub const magic = "OMAVIPC1";
pub const Kind = enum(u8) { execute = 1, unlock = 2, lock = 3, status = 4, stop = 5, password_change = 6, recovery_change = 7, recover = 8, response = 128 };
pub const Frame = struct {
    kind: Kind,
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
    @memcpy(bytes[0..8], magic);
    bytes[8] = @backingInt(kind);
    std.mem.writeInt(u32, bytes[12..16], @intCast(length), .little);
    return bytes;
}
pub const Header = struct { kind: Kind, length: usize };
pub fn decodeHeader(bytes: *const [header_bytes]u8, limit: usize) !Header {
    if (!std.mem.eql(u8, bytes[0..8], magic) or bytes[9] != 0 or bytes[10] != 0 or bytes[11] != 0) return error.InvalidBackendFrame;
    const kind = std.enums.fromInt(Kind, bytes[8]) orelse return error.InvalidBackendFrame;
    const length = std.mem.readInt(u32, bytes[12..16], .little);
    if (length > limit) return error.BackendFrameTooLarge;
    if ((kind == .unlock or kind == .password_change) and (length == 0 or length > @import("vault_types.zig").max_password_bytes)) return error.InvalidVaultPassword;
    if (kind == .recovery_change and length != 32) return error.InvalidRecoveryKey;
    if (kind == .recover and (length <= 32 or length > 32 + @import("vault_types.zig").max_password_bytes)) return error.InvalidVaultPassword;
    if ((kind == .lock or kind == .status or kind == .stop) and length != 0) return error.InvalidBackendFrame;
    return .{ .kind = kind, .length = length };
}
pub fn readFrame(io: std.Io, a: std.mem.Allocator, stream: std.Io.net.Stream, limit: usize) !Frame {
    var read_buffer: [header_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var reader = stream.reader(io, &read_buffer);
    var bytes: [header_bytes]u8 = undefined;
    try reader.interface.readSliceAll(&bytes);
    const decoded = try decodeHeader(&bytes, limit);
    // Allocate only after validation, and precisely to the advertised length.
    const backing = if (decoded.kind == .execute and decoded.length > t.Limits.request_bytes) @import("send_memory.zig").allocator() else a;
    const body = try backing.alloc(u8, decoded.length);
    errdefer {
        std.crypto.secureZero(u8, body);
        backing.free(body);
    }
    try reader.interface.readSliceAll(body);
    if (decoded.kind == .execute and body.len > @import("send_memory.zig").requestLimit(body)) return error.InvalidRequest;
    return .{ .kind = decoded.kind, .body = body, .backing = backing };
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
pub const Metadata = struct { id: std.json.Value = .null, account: []const u8 = "", command: []const u8 = "", vault_id: []const u8 = "", secret_field: bool = false, reconcile: bool = false };
/// Read only the envelope with fixed scratch. Large body/recipient arrays are
/// skipped without allocating copies, including during an OOM error response.
pub fn requestMetadata(a: std.mem.Allocator, raw: []const u8) !Metadata {
    if (raw.len > @import("send_memory.zig").requestLimit(raw) or !@import("core.zig").boundedJson(raw)) return error.InvalidRequest;
    var scanner = std.json.Scanner.initCompleteInput(a, raw);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidRequest;
    var result: Metadata = .{};
    var reconcile_seen = false;
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
        return .{ .ctx = self, .callFn = call, .cachedFn = cached };
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
            return @import("json.zig").encodeAlloc(a, .{ .version = @as(u8, 1), .id = meta.id, .ok = false, .account = meta.account, .@"error" = .{ .code = @errorName(report), .message = if (report == error.UnknownOutcome) "Outcome is unknown; do not automatically retry" else @errorName(report) } }, .{});
        };
    }
    fn execute(self: *Client, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = try requestMetadata(fixed.allocator(), raw);
        if (meta.secret_field) return error.VaultSecretRequiresPrompt;
        const expected = self.expected_vault_id orelse return self.request(a, .execute, raw);
        const hex = std.fmt.bytesToHex(expected, .lower);
        if (meta.vault_id.len != 0 and !std.mem.eql(u8, meta.vault_id, &hex)) return error.VaultIdentityMismatch;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        var value = try std.json.parseFromSliceLeaky(std.json.Value, temp, raw, .{ .allocate = .alloc_if_needed, .max_value_len = request_limit });
        try value.object.put(temp, "_vaultId", .{ .string = &hex });
        return self.request(a, .execute, try @import("json.zig").encodeAlloc(temp, value, .{}));
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
        const seconds = if (kind == .execute) executionSeconds(meta.command) + 15 else 45;
        platform.deadline(self.io, platform.seconds(seconds), exchange, .{ self, a, kind, body, &submitted, &response }) catch |err| {
            if (kind != .execute or !submitted) return err;
            return disconnectRequestError(meta);
        };
        return response.?;
    }
    fn exchange(self: *Client, a: std.mem.Allocator, kind: Kind, body: []const u8, submitted: *bool, output: *?[]const u8) !void {
        _ = try decodeHeader(&(try encodeHeader(kind, body.len, request_limit)), request_limit);
        var directory = try pathDirectory(self.io, self.socket_path, false);
        defer directory.close(self.io);
        const stat = try directory.statFile(self.io, std.fs.path.basename(self.socket_path), .{ .follow_symlinks = false });
        if (stat.kind != .unix_domain_socket or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeBackendSocket;
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        const stream = try address.connect(self.io);
        defer stream.close(self.io);
        try validatePeer(stream);
        submitted.* = true;
        try writeFrame(self.io, stream, kind, body, request_limit);
        var response = try readFrame(self.io, a, stream, if (kind == .execute and @import("send_memory.zig").request(body)) response_limit else ordinary_response_limit);
        errdefer response.deinit(a);
        if (response.kind != .response) return error.InvalidBackendFrame;
        output.* = response.body;
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
