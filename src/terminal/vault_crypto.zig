//! Versioned authenticated encryption for native vault adapters.
//! This module does not choose a daemon, storage directory or unlock UI.
//! Passwords are neither persisted nor separately hashed for verification:
//! successful authenticated unwrap is the only password check.
const std = @import("std");
const builtin = @import("builtin");
pub const types = @import("vault_types.zig");
const t = types;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Argon2 = std.crypto.pwhash.argon2;
const Hash = std.crypto.hash.sha2.Sha256;
const Policy = enum { production, fast_test };

pub fn createDataKey(io: std.Io) !t.DataKey {
    var result: t.DataKey = undefined;
    errdefer result.wipe();
    try io.randomSecure(&result.vault_id);
    try io.randomSecure(&result.key_id);
    try io.randomSecure(&result.bytes);
    return result;
}

/// A compromised data key needs new ciphertext for every retained record.
/// This only creates the replacement; callers atomically migrate data before
/// retiring the old key. Rewrapping a password does not perform this rotation.
pub fn rotateDataKey(io: std.Io, previous: *const t.DataKey) !t.DataKey {
    var result = try createDataKey(io);
    result.vault_id = previous.vault_id;
    return result;
}

pub fn createRecoveryKey(io: std.Io) !t.RecoveryKey {
    var result: t.RecoveryKey = undefined;
    errdefer result.wipe();
    try io.randomSecure(&result.bytes);
    return result;
}

pub fn wrapPassword(io: std.Io, scratch: []u8, password: []const u8, data_key: *const t.DataKey) !t.KeySlot {
    return wrapPasswordPolicy(io, scratch, password, data_key, t.KdfParameters.production, .production);
}

pub fn unwrapPassword(io: std.Io, scratch: []u8, password: []const u8, wire: []const u8, vault_id: t.Id, key_id: t.Id) !t.DataKey {
    return unwrapPasswordPolicy(io, scratch, password, wire, vault_id, key_id, .production);
}

/// When already unlocked, wrapPassword(new_password, live_key) is sufficient.
/// This helper also authenticates the old slot for callers without a live key.
/// The returned slot wraps exactly the same DEK and IDs with fresh salt/nonce.
/// A copied old slot remains usable with its old password; revoking exposure
/// of that password/key requires data-key rotation and record re-encryption.
pub fn changePassword(io: std.Io, scratch: []u8, old_password: []const u8, new_password: []const u8, wire: []const u8, vault_id: t.Id, key_id: t.Id) !t.KeySlot {
    var key = try unwrapPassword(io, scratch, old_password, wire, vault_id, key_id);
    defer key.wipe();
    return wrapPassword(io, scratch, new_password, &key);
}

fn validateKdf(parameters: t.KdfParameters, policy: Policy) !void {
    if (policy == .fast_test and builtin.is_test and parameters.memory_kib == t.KdfParameters.fast_test.memory_kib and parameters.passes == 1 and parameters.lanes == 1) return;
    // Persistent profiles are an explicit allowlist independent of future
    // defaults. Never silently make an existing slot unreadable on an update.
    if (parameters.memory_kib == 64 * 1024 and parameters.lanes == 1) switch (parameters.passes) {
        3, 4, 5, 6 => return,
        else => {},
    };
    return error.InvalidVaultKdf;
}

fn derive(io: std.Io, scratch: []u8, output: *[t.key_bytes]u8, password: []const u8, salt: *const [t.salt_bytes]u8, parameters: t.KdfParameters, policy: Policy) !void {
    // The calling key-slot operation wipes all borrowed scratch on every exit,
    // including allocator failure and cancellation, after std Argon2 returns.
    errdefer std.crypto.secureZero(u8, output);
    try validateKdf(parameters, policy);
    if (password.len == 0 or password.len > t.max_password_bytes) return error.InvalidVaultPassword;
    if (scratch.len < try parameters.scratchBytes()) return error.VaultKdfWorkspaceTooSmall;
    try io.checkCancel();
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    try Argon2.kdf(fixed.allocator(), output, password, salt, .{ .m = parameters.memory_kib, .t = parameters.passes, .p = @intCast(parameters.lanes) }, .argon2id, io);
    // Zig's p=1 Argon2 implementation is synchronous. Cancellation is observed
    // before/after this bounded derivation, not midway through a pass.
    try io.checkCancel();
}

fn putInt(comptime T: type, output: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, output[offset..][0..@sizeOf(T)], value, .little);
}
fn getInt(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

// Slot layout: magic[8], format u16, kind u8, suite u8, Argon2 m/t/p u32,
// vault_id[16], key_id[16], salt[32], nonce[24], encrypted_DEK[32], tag[16].
fn slotHeader(io: std.Io, key: *const t.DataKey, kind: t.SlotKind, parameters: t.KdfParameters) !t.KeySlot {
    var result: t.KeySlot = @splat(0);
    @memcpy(result[0..8], t.keyslot_magic);
    putInt(u16, &result, 8, t.format_version);
    result[10] = @backingInt(kind);
    result[11] = 1; // XChaCha20-Poly1305; Argon2id v0x13 for password slots.
    putInt(u32, &result, 12, parameters.memory_kib);
    putInt(u32, &result, 16, parameters.passes);
    putInt(u32, &result, 20, parameters.lanes);
    @memcpy(result[24..40], &key.vault_id);
    @memcpy(result[40..56], &key.key_id);
    if (kind == .password) try io.randomSecure(result[56..88]);
    try io.randomSecure(result[88..112]);
    return result;
}
fn encryptSlot(slot: *t.KeySlot, key: *const t.DataKey, wrapping_key: *const [t.key_bytes]u8) void {
    Aead.encrypt(slot[112..144], slot[144..160], &key.bytes, slot[0..112], slot[88..112].*, wrapping_key.*);
}
fn validateSlot(wire: []const u8, kind: t.SlotKind, vault_id: t.Id, key_id: t.Id) !void {
    if (wire.len != t.keyslot_bytes) return error.InvalidVaultKeySlot;
    if (!std.mem.eql(u8, wire[0..8], t.keyslot_magic)) return error.InvalidVaultKeySlot;
    if (getInt(u16, wire, 8) != t.format_version or wire[11] != 1) return error.UnsupportedVaultVersion;
    if (wire[10] != @backingInt(kind)) return error.InvalidVaultKeySlot;
    if (!std.mem.eql(u8, wire[24..40], &vault_id) or !std.mem.eql(u8, wire[40..56], &key_id)) return error.VaultIdentityMismatch;
}
fn decryptSlot(wire: []const u8, wrapping_key: *const [t.key_bytes]u8, vault_id: t.Id, key_id: t.Id) !t.DataKey {
    var result: t.DataKey = .{ .vault_id = vault_id, .key_id = key_id, .bytes = undefined };
    errdefer result.wipe();
    Aead.decrypt(&result.bytes, wire[112..144], wire[144..160].*, wire[0..112], wire[88..112].*, wrapping_key.*) catch return error.VaultAuthenticationFailed;
    return result;
}
fn wrapPasswordPolicy(io: std.Io, scratch: []u8, password: []const u8, key: *const t.DataKey, parameters: t.KdfParameters, policy: Policy) !t.KeySlot {
    defer std.crypto.secureZero(u8, scratch);
    try validateKdf(parameters, policy);
    var result = try slotHeader(io, key, .password, parameters);
    var wrapping_key: [t.key_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &wrapping_key);
    try derive(io, scratch, &wrapping_key, password, result[56..88], parameters, policy);
    encryptSlot(&result, key, &wrapping_key);
    return result;
}
fn unwrapPasswordPolicy(io: std.Io, scratch: []u8, password: []const u8, wire: []const u8, vault_id: t.Id, key_id: t.Id, policy: Policy) !t.DataKey {
    defer std.crypto.secureZero(u8, scratch);
    try validateSlot(wire, .password, vault_id, key_id);
    const parameters: t.KdfParameters = .{ .memory_kib = getInt(u32, wire, 12), .passes = getInt(u32, wire, 16), .lanes = getInt(u32, wire, 20) };
    // Bounds are checked before Argon2, allocator use or any variable-size read.
    try validateKdf(parameters, policy);
    var wrapping_key: [t.key_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &wrapping_key);
    try derive(io, scratch, &wrapping_key, password, wire[56..88], parameters, policy);
    return decryptSlot(wire, &wrapping_key, vault_id, key_id);
}

pub fn wrapRecovery(io: std.Io, recovery: *const t.RecoveryKey, key: *const t.DataKey) !t.KeySlot {
    var result = try slotHeader(io, key, .recovery, .{ .memory_kib = 0, .passes = 0, .lanes = 0 });
    encryptSlot(&result, key, &recovery.bytes);
    return result;
}
pub fn unwrapRecovery(recovery: *const t.RecoveryKey, wire: []const u8, vault_id: t.Id, key_id: t.Id) !t.DataKey {
    try validateSlot(wire, .recovery, vault_id, key_id);
    for (wire[12..24]) |byte| if (byte != 0) return error.InvalidVaultKeySlot;
    for (wire[56..88]) |byte| if (byte != 0) return error.InvalidVaultKeySlot;
    return decryptSlot(wire, &recovery.bytes, vault_id, key_id);
}

fn bindingHash(binding: t.Binding) ![Hash.digest_length]u8 {
    if (binding.account.len == 0 or binding.account.len > t.max_account_bytes or binding.record_id.len == 0 or binding.record_id.len > t.max_record_id_bytes or binding.revision == 0) return error.InvalidVaultBinding;
    var hash = Hash.init(.{});
    hash.update("omagma-vault-record-binding-v1\x00");
    var integers: [14]u8 = undefined;
    putInt(u16, &integers, 0, @intCast(binding.account.len));
    putInt(u16, &integers, 2, @backingInt(binding.kind));
    putInt(u16, &integers, 4, @intCast(binding.record_id.len));
    putInt(u64, &integers, 6, binding.revision);
    hash.update(&integers);
    hash.update(binding.account);
    hash.update(binding.record_id);
    var result: [Hash.digest_length]u8 = undefined;
    hash.final(&result);
    return result;
}

// Record header: magic[8], format u16, suite u16, chunk_size u32,
// plaintext_length u64, vault_id[16], key_id[16], random_nonce[24].
// Each canonical chunk is followed by its tag. The final empty frame uses a
// different nonce domain and authenticates the header, expected identity,
// frame count and total length. No extra bytes may follow that final tag.
fn recordHeader(io: std.Io, key: *const t.DataKey, size: usize) ![t.record_header_bytes]u8 {
    _ = try t.sealedSize(size);
    var header: [t.record_header_bytes]u8 = @splat(0);
    @memcpy(header[0..8], t.record_magic);
    putInt(u16, &header, 8, t.format_version);
    putInt(u16, &header, 10, 1);
    putInt(u32, &header, 12, t.chunk_bytes);
    putInt(u64, &header, 16, size);
    @memcpy(header[24..40], &key.vault_id);
    @memcpy(header[40..56], &key.key_id);
    try io.randomSecure(header[56..80]);
    return header;
}
fn validateHeader(header: *const [t.record_header_bytes]u8, key: *const t.DataKey) !usize {
    if (!std.mem.eql(u8, header[0..8], t.record_magic)) return error.InvalidVaultRecord;
    if (getInt(u16, header, 8) != t.format_version or getInt(u16, header, 10) != 1) return error.UnsupportedVaultVersion;
    if (getInt(u32, header, 12) != t.chunk_bytes) return error.InvalidVaultRecord;
    if (!std.mem.eql(u8, header[24..40], &key.vault_id) or !std.mem.eql(u8, header[40..56], &key.key_id)) return error.VaultIdentityMismatch;
    const size = getInt(u64, header, 16);
    if (size > t.max_record_bytes) return error.VaultRecordTooLarge;
    return @intCast(size);
}
fn frameNonce(header: *const [t.record_header_bytes]u8, index: u64, final: bool) [t.nonce_bytes]u8 {
    var nonce = header[56..80].*;
    // XOR is injective within one record; high bit separates final from data.
    // A fresh random 192-bit base is generated independently for every record.
    const counter = index | (if (final) @as(u64, 1) << 63 else 0);
    putInt(u64, &nonce, 16, getInt(u64, &nonce, 16) ^ counter);
    return nonce;
}
fn frameAad(header: *const [t.record_header_bytes]u8, binding: *const [Hash.digest_length]u8, index: u64, size: usize, final: bool) [t.record_header_bytes + Hash.digest_length + 13]u8 {
    var aad: [t.record_header_bytes + Hash.digest_length + 13]u8 = undefined;
    @memcpy(aad[0..t.record_header_bytes], header);
    @memcpy(aad[t.record_header_bytes..][0..Hash.digest_length], binding);
    const offset = t.record_header_bytes + Hash.digest_length;
    putInt(u64, &aad, offset, index);
    putInt(u32, &aad, offset + 8, @intCast(size));
    aad[offset + 12] = @intFromBool(final);
    return aad;
}
fn readExact(source: t.Source, output: []u8) !void {
    var offset: usize = 0;
    while (offset != output.len) {
        const count = try source.readFn(source.context, output[offset..]);
        if (count == 0) return error.TruncatedVaultRecord;
        if (count > output.len - offset) return error.InvalidVaultSource;
        offset += count;
    }
}
fn requireEof(source: t.Source) !void {
    var extra: [1]u8 = undefined;
    defer std.crypto.secureZero(u8, &extra);
    const count = try source.readFn(source.context, &extra);
    if (count > extra.len) return error.InvalidVaultSource;
    if (count != 0) return error.TrailingVaultData;
}

pub fn sealStream(io: std.Io, key: *const t.DataKey, binding: t.Binding, plaintext_size: usize, source: t.Source, destination: t.StagingSink, workspace: *t.StreamWorkspace) !void {
    defer workspace.wipe();
    errdefer destination.abortFn(destination.context);
    const identity = try bindingHash(binding);
    const header = try recordHeader(io, key, plaintext_size);
    try io.checkCancel();
    try destination.writeFn(destination.context, &header);
    var remaining = plaintext_size;
    var index: u64 = 0;
    while (remaining != 0) : (index += 1) {
        try io.checkCancel();
        const size = @min(remaining, t.chunk_bytes);
        try readExact(source, workspace.plaintext[0..size]);
        const aad = frameAad(&header, &identity, index, size, false);
        var tag: [t.tag_bytes]u8 = undefined;
        Aead.encrypt(workspace.ciphertext[0..size], &tag, workspace.plaintext[0..size], &aad, frameNonce(&header, index, false), key.bytes);
        try destination.writeFn(destination.context, workspace.ciphertext[0..size]);
        try destination.writeFn(destination.context, &tag);
        remaining -= size;
    }
    try requireEof(source);
    const aad = frameAad(&header, &identity, index, 0, true);
    var tag: [t.tag_bytes]u8 = undefined;
    Aead.encrypt(workspace.ciphertext[0..0], &tag, "", &aad, frameNonce(&header, index, true), key.bytes);
    try destination.writeFn(destination.context, &tag);
    try io.checkCancel();
    try destination.commitFn(destination.context);
}

/// Push adapter for counted JSON/MIME writers. Call finish exactly once; defer
/// abort for every unfinished path. The only plaintext storage is workspace.
/// The key, destination and workspace must outlive this object and be disjoint.
pub const PushSealer = struct {
    io: std.Io,
    key: *const t.DataKey,
    destination: t.StagingSink,
    plaintext: []u8,
    ciphertext: []u8,
    identity: [Hash.digest_length]u8,
    header: [t.record_header_bytes]u8,
    expected: usize,
    accepted: usize = 0,
    buffered: usize = 0,
    index: u64 = 0,
    active: bool = true,

    pub fn init(io: std.Io, key: *const t.DataKey, binding: t.Binding, size: usize, destination: t.StagingSink, workspace: *t.StreamWorkspace) !PushSealer {
        return initBuffers(io, key, binding, size, destination, &workspace.plaintext, &workspace.ciphertext);
    }
    /// One half of a shared workspace, encrypted in place. The other half can
    /// simultaneously authenticate a source record during MIME serialization.
    pub fn initInPlace(io: std.Io, key: *const t.DataKey, binding: t.Binding, size: usize, destination: t.StagingSink, buffer: *[t.chunk_bytes]u8) !PushSealer {
        return initBuffers(io, key, binding, size, destination, buffer, buffer);
    }
    fn initBuffers(io: std.Io, key: *const t.DataKey, binding: t.Binding, size: usize, destination: t.StagingSink, plaintext: []u8, ciphertext: []u8) !PushSealer {
        errdefer {
            std.crypto.secureZero(u8, plaintext);
            std.crypto.secureZero(u8, ciphertext);
            destination.abortFn(destination.context);
        }
        const identity = try bindingHash(binding);
        const header = try recordHeader(io, key, size);
        try io.checkCancel();
        try destination.writeFn(destination.context, &header);
        return .{ .io = io, .key = key, .destination = destination, .plaintext = plaintext, .ciphertext = ciphertext, .identity = identity, .header = header, .expected = size };
    }
    fn wipe(self: *PushSealer) void {
        std.crypto.secureZero(u8, self.plaintext);
        if (self.ciphertext.ptr != self.plaintext.ptr) std.crypto.secureZero(u8, self.ciphertext);
    }

    fn flushChunk(self: *PushSealer) !void {
        try self.io.checkCancel();
        const size = self.buffered;
        const aad = frameAad(&self.header, &self.identity, self.index, size, false);
        var tag: [t.tag_bytes]u8 = undefined;
        Aead.encrypt(self.ciphertext[0..size], &tag, self.plaintext[0..size], &aad, frameNonce(&self.header, self.index, false), self.key.bytes);
        try self.destination.writeFn(self.destination.context, self.ciphertext[0..size]);
        try self.destination.writeFn(self.destination.context, &tag);
        std.crypto.secureZero(u8, self.plaintext[0..size]);
        self.buffered = 0;
        self.index += 1;
    }

    pub fn write(self: *PushSealer, bytes: []const u8) !void {
        if (!self.active) return error.VaultStreamClosed;
        errdefer self.abort();
        if (bytes.len > self.expected - self.accepted) return error.VaultLengthMismatch;
        var remaining = bytes;
        while (remaining.len != 0) {
            try self.io.checkCancel();
            const count = @min(remaining.len, t.chunk_bytes - self.buffered);
            if (self.plaintext[self.buffered..].ptr != remaining.ptr) @memcpy(self.plaintext[self.buffered..][0..count], remaining[0..count]);
            self.buffered += count;
            self.accepted += count;
            remaining = remaining[count..];
            if (self.buffered == t.chunk_bytes) try self.flushChunk();
        }
    }

    pub fn finish(self: *PushSealer) !void {
        if (!self.active) return error.VaultStreamClosed;
        errdefer self.abort();
        if (self.accepted != self.expected) return error.VaultLengthMismatch;
        if (self.buffered != 0) try self.flushChunk();
        const aad = frameAad(&self.header, &self.identity, self.index, 0, true);
        var tag: [t.tag_bytes]u8 = undefined;
        Aead.encrypt(self.ciphertext[0..0], &tag, "", &aad, frameNonce(&self.header, self.index, true), self.key.bytes);
        try self.destination.writeFn(self.destination.context, &tag);
        try self.io.checkCancel();
        try self.destination.commitFn(self.destination.context);
        self.active = false;
        self.wipe();
    }

    pub fn abort(self: *PushSealer) void {
        if (!self.active) return;
        self.active = false;
        self.wipe();
        self.destination.abortFn(self.destination.context);
    }
};

/// Incremental authenticated decoder. This low-level adapter does not do a
/// preliminary verification pass: filesystem consumers use vault_stream.Reader.
/// Exact in-place AEAD uses one chunk buffer; no byte is returned before its
/// complete chunk tag authenticates. Call close on every path.
pub const PullReader = struct {
    io: std.Io,
    key: *const t.DataKey,
    source: t.Source,
    buffer: *[t.chunk_bytes]u8,
    header: [t.record_header_bytes]u8,
    identity: [Hash.digest_length]u8,
    size: usize,
    remaining: usize,
    index: u64 = 0,
    buffered: usize = 0,
    position: usize = 0,
    finished: bool = false,
    failed: bool = false,
    pub fn init(io: std.Io, key: *const t.DataKey, binding: t.Binding, source: t.Source, buffer: *[t.chunk_bytes]u8) !PullReader {
        errdefer std.crypto.secureZero(u8, buffer);
        var header: [t.record_header_bytes]u8 = undefined;
        try readExact(source, &header);
        const size = try validateHeader(&header, key);
        return .{ .io = io, .key = key, .source = source, .buffer = buffer, .header = header, .identity = try bindingHash(binding), .size = size, .remaining = size };
    }
    pub fn close(self: *PullReader) void {
        std.crypto.secureZero(u8, self.buffer);
        self.failed = true;
    }
    fn fill(self: *PullReader) !void {
        try self.io.checkCancel();
        std.crypto.secureZero(u8, self.buffer);
        self.position = 0;
        self.buffered = 0;
        const count = @min(self.remaining, t.chunk_bytes);
        try readExact(self.source, self.buffer[0..count]);
        var tag: [t.tag_bytes]u8 = undefined;
        try readExact(self.source, &tag);
        const final = self.remaining == 0;
        const aad = frameAad(&self.header, &self.identity, self.index, count, final);
        Aead.decrypt(self.buffer[0..count], self.buffer[0..count], tag, &aad, frameNonce(&self.header, self.index, final), self.key.bytes) catch return error.VaultAuthenticationFailed;
        if (final) {
            try requireEof(self.source);
            self.finished = true;
        } else {
            self.buffered = count;
            self.remaining -= count;
            self.index += 1;
        }
    }
    pub fn verifyAll(self: *PullReader) !void {
        if (self.failed) return error.VaultStreamClosed;
        errdefer self.close();
        while (!self.finished) try self.fill();
        std.crypto.secureZero(u8, self.buffer);
    }
    pub fn read(self: *PullReader, out: []u8) !usize {
        if (self.failed) return error.VaultStreamClosed;
        if (out.len == 0) return 0;
        errdefer self.close();
        if (self.position == self.buffered and !self.finished) try self.fill();
        const count = @min(out.len, self.buffered - self.position);
        @memcpy(out[0..count], self.buffer[self.position..][0..count]);
        std.crypto.secureZero(u8, self.buffer[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

/// Authenticate the complete record, including final marker and EOF, without
/// handing plaintext to a consumer. A later export still authenticates again.
pub fn verifyStream(io: std.Io, key: *const t.DataKey, binding: t.Binding, source: t.Source, workspace: *t.StreamWorkspace) !usize {
    const Discard = struct {
        count: usize = 0,
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += bytes.len;
        }
        fn commit(_: *anyopaque) !void {}
        fn abort(_: *anyopaque) void {}
    };
    var discard: Discard = .{};
    try openStream(io, key, binding, source, .{ .context = &discard, .writeFn = Discard.write, .commitFn = Discard.commit, .abortFn = Discard.abort }, workspace);
    return discard.count;
}

pub fn openStream(io: std.Io, key: *const t.DataKey, binding: t.Binding, source: t.Source, destination: t.StagingSink, workspace: *t.StreamWorkspace) !void {
    defer workspace.wipe();
    errdefer destination.abortFn(destination.context);
    const identity = try bindingHash(binding);
    var header: [t.record_header_bytes]u8 = undefined;
    try io.checkCancel();
    try readExact(source, &header);
    var remaining = try validateHeader(&header, key);
    var index: u64 = 0;
    while (remaining != 0) : (index += 1) {
        try io.checkCancel();
        const size = @min(remaining, t.chunk_bytes);
        try readExact(source, workspace.ciphertext[0..size]);
        var tag: [t.tag_bytes]u8 = undefined;
        try readExact(source, &tag);
        const aad = frameAad(&header, &identity, index, size, false);
        Aead.decrypt(workspace.plaintext[0..size], workspace.ciphertext[0..size], tag, &aad, frameNonce(&header, index, false), key.bytes) catch return error.VaultAuthenticationFailed;
        try destination.writeFn(destination.context, workspace.plaintext[0..size]);
        remaining -= size;
    }
    var tag: [t.tag_bytes]u8 = undefined;
    try readExact(source, &tag);
    const aad = frameAad(&header, &identity, index, 0, true);
    Aead.decrypt(workspace.plaintext[0..0], "", tag, &aad, frameNonce(&header, index, true), key.bytes) catch return error.VaultAuthenticationFailed;
    try requireEof(source);
    try io.checkCancel();
    try destination.commitFn(destination.context);
}

const SliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn read(context: *anyopaque, output: []u8) !usize {
        const self: *SliceSource = @ptrCast(@alignCast(context));
        const count = @min(output.len, self.bytes.len - self.offset);
        @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
    fn adapter(self: *SliceSource) t.Source {
        return .{ .context = self, .readFn = read };
    }
};
const SliceSink = struct {
    bytes: []u8,
    offset: usize = 0,
    published: bool = false,
    fn write(context: *anyopaque, input: []const u8) !void {
        const self: *SliceSink = @ptrCast(@alignCast(context));
        if (input.len > self.bytes.len - self.offset) return error.VaultOutputTooSmall;
        @memcpy(self.bytes[self.offset..][0..input.len], input);
        self.offset += input.len;
    }
    fn commit(context: *anyopaque) !void {
        const self: *SliceSink = @ptrCast(@alignCast(context));
        self.published = true;
    }
    fn abort(context: *anyopaque) void {
        const self: *SliceSink = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, self.bytes);
        self.offset = 0;
        self.published = false;
    }
    fn adapter(self: *SliceSink) t.StagingSink {
        return .{ .context = self, .writeFn = write, .commitFn = commit, .abortFn = abort };
    }
};

/// Slice convenience adapters allocate nothing. Buffers and workspace must be
/// disjoint. On error the entire output is wiped, including partial plaintext.
pub fn sealRecord(io: std.Io, key: *const t.DataKey, binding: t.Binding, plaintext: []const u8, output: []u8, workspace: *t.StreamWorkspace) ![]const u8 {
    var source: SliceSource = .{ .bytes = plaintext };
    var sink: SliceSink = .{ .bytes = output };
    try sealStream(io, key, binding, plaintext.len, source.adapter(), sink.adapter(), workspace);
    return output[0..sink.offset];
}
pub fn openRecord(io: std.Io, key: *const t.DataKey, binding: t.Binding, wire: []const u8, output: []u8, workspace: *t.StreamWorkspace) ![]u8 {
    var source: SliceSource = .{ .bytes = wire };
    var sink: SliceSink = .{ .bytes = output };
    try openStream(io, key, binding, source.adapter(), sink.adapter(), workspace);
    return output[0..sink.offset];
}

/// These entry points do not exist in production builds. Fast test key slots
/// retain their weak parameter fields and production unwrap always rejects them.
pub const testing = if (builtin.is_test) struct {
    pub fn wrapPassword(io: std.Io, scratch: []u8, password: []const u8, key: *const t.DataKey) !t.KeySlot {
        return wrapPasswordPolicy(io, scratch, password, key, t.KdfParameters.fast_test, .fast_test);
    }
    pub fn unwrapPassword(io: std.Io, scratch: []u8, password: []const u8, wire: []const u8, vault_id: t.Id, key_id: t.Id) !t.DataKey {
        return unwrapPasswordPolicy(io, scratch, password, wire, vault_id, key_id, .fast_test);
    }
} else struct {};
