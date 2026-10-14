//! Standalone synthetic crypto gate. No real vault, mail, credentials or I/O
//! adapters are touched. Coordinator owns compilation/execution scheduling.
const std = @import("std");
const crypto = @import("terminal/vault_crypto.zig");
const t = @import("terminal/vault_types.zig");
const kdf_memory = @import("terminal/vault_kdf_memory.zig");
const io = std.testing.io;
const allocator = std.testing.allocator;
const identity: t.Binding = .{ .account = "self@example.test", .kind = .mail_body, .record_id = "synthetic-message", .revision = 1 };

fn zero(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
fn sameKey(left: *const t.DataKey, right: *const t.DataKey) !void {
    try std.testing.expectEqualSlices(u8, &left.vault_id, &right.vault_id);
    try std.testing.expectEqualSlices(u8, &left.key_id, &right.key_id);
    try std.testing.expectEqualSlices(u8, &left.bytes, &right.bytes);
}
fn testScratch() ![]u8 {
    return allocator.alloc(u8, try t.KdfParameters.fast_test.scratchBytes());
}

test "vault crypto: password key slots authenticate unwrap and reject wrong password or identity" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const scratch = try testScratch();
    defer allocator.free(scratch);
    @memset(scratch, 0xa5);
    const slot = try crypto.testing.wrapPassword(io, scratch, "synthetic long password", &key);
    try zero(scratch);
    try std.testing.expect(std.mem.indexOf(u8, &slot, &key.bytes) == null);
    try std.testing.expect(std.mem.indexOf(u8, &slot, "synthetic long password") == null);
    var recovered = try crypto.testing.unwrapPassword(io, scratch, "synthetic long password", &slot, key.vault_id, key.key_id);
    defer recovered.wipe();
    try sameKey(&key, &recovered);
    try zero(scratch);
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.testing.unwrapPassword(io, scratch, "wrong password", &slot, key.vault_id, key.key_id));
    try zero(scratch);
    var wrong_id = key.vault_id;
    wrong_id[0] ^= 1;
    try std.testing.expectError(error.VaultIdentityMismatch, crypto.testing.unwrapPassword(io, scratch, "synthetic long password", &slot, wrong_id, key.key_id));
    try std.testing.expectError(error.VaultIdentityMismatch, crypto.testing.unwrapPassword(io, scratch, "synthetic long password", &slot, key.vault_id, wrong_id));
    try std.testing.expectError(error.InvalidVaultKdf, crypto.unwrapPassword(io, scratch, "synthetic long password", &slot, key.vault_id, key.key_id));
    try std.testing.expectError(error.InvalidVaultPassword, crypto.testing.wrapPassword(io, scratch, "", &key));
    var too_long: [t.max_password_bytes + 1]u8 = @splat('x');
    defer std.crypto.secureZero(u8, &too_long);
    try std.testing.expectError(error.InvalidVaultPassword, crypto.testing.wrapPassword(io, scratch, &too_long, &key));
    try zero(scratch);
}

test "vault crypto: password rewrap preserves data key and recovery survives password replacement" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var recovery = try crypto.createRecoveryKey(io);
    defer recovery.wipe();
    const recovery_slot = try crypto.wrapRecovery(io, &recovery, &key);
    const scratch = try testScratch();
    defer allocator.free(scratch);
    const old_slot = try crypto.testing.wrapPassword(io, scratch, "previous synthetic password", &key);
    var unlocked = try crypto.testing.unwrapPassword(io, scratch, "previous synthetic password", &old_slot, key.vault_id, key.key_id);
    defer unlocked.wipe();
    const replacement = try crypto.testing.wrapPassword(io, scratch, "replacement synthetic password", &unlocked);
    try std.testing.expect(!std.mem.eql(u8, old_slot[56..88], replacement[56..88]));
    try std.testing.expect(!std.mem.eql(u8, old_slot[88..112], replacement[88..112]));
    var changed = try crypto.testing.unwrapPassword(io, scratch, "replacement synthetic password", &replacement, key.vault_id, key.key_id);
    defer changed.wipe();
    try sameKey(&key, &changed);
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.testing.unwrapPassword(io, scratch, "previous synthetic password", &replacement, key.vault_id, key.key_id));
    var rescued = try crypto.unwrapRecovery(&recovery, &recovery_slot, key.vault_id, key.key_id);
    defer rescued.wipe();
    try sameKey(&key, &rescued);
    var rotated = try crypto.rotateDataKey(io, &key);
    defer rotated.wipe();
    try std.testing.expectEqualSlices(u8, &key.vault_id, &rotated.vault_id);
    try std.testing.expect(!std.mem.eql(u8, &key.key_id, &rotated.key_id));
    try std.testing.expect(!std.mem.eql(u8, &key.bytes, &rotated.bytes));
    try std.testing.expectError(error.VaultIdentityMismatch, crypto.unwrapRecovery(&recovery, &recovery_slot, rotated.vault_id, rotated.key_id));
    recovery.bytes[0] ^= 1;
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.unwrapRecovery(&recovery, &recovery_slot, key.vault_id, key.key_id));
}

test "vault crypto: bounded keyslot parser rejects corruption truncation versions and hostile KDF before work" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const scratch = try testScratch();
    defer allocator.free(scratch);
    const original = try crypto.testing.wrapPassword(io, scratch, "synthetic password", &key);
    // Every byte in the fixed header, ciphertext and tag is checked. No
    // attacker-controlled parameter can request a larger allocation or pass.
    for (0..original.len) |offset| {
        var tampered = original;
        tampered[offset] ^= 0x80;
        if (crypto.testing.unwrapPassword(io, scratch, "synthetic password", &tampered, key.vault_id, key.key_id)) |value| {
            var unexpected = value;
            unexpected.wipe();
            return error.AcceptedCorruptVaultSlot;
        } else |_| {}
        try zero(scratch);
    }
    for (0..original.len) |length| try std.testing.expectError(error.InvalidVaultKeySlot, crypto.testing.unwrapPassword(io, scratch, "synthetic password", original[0..length], key.vault_id, key.key_id));
    var oversized: [t.keyslot_bytes + 1]u8 = @splat(0);
    @memcpy(oversized[0..t.keyslot_bytes], &original);
    try std.testing.expectError(error.InvalidVaultKeySlot, crypto.testing.unwrapPassword(io, scratch, "synthetic password", &oversized, key.vault_id, key.key_id));
    var bad = original;
    bad[8] = 2;
    try std.testing.expectError(error.UnsupportedVaultVersion, crypto.testing.unwrapPassword(io, scratch, "synthetic password", &bad, key.vault_id, key.key_id));
    for ([_]usize{ 12, 16, 20 }) |offset| {
        bad = original;
        @memset(bad[offset..][0..4], 0xff);
        try std.testing.expectError(error.InvalidVaultKdf, crypto.testing.unwrapPassword(io, scratch, "synthetic password", &bad, key.vault_id, key.key_id));
    }
    @memset(scratch, 0xa5);
    try std.testing.expectError(error.VaultKdfWorkspaceTooSmall, crypto.testing.unwrapPassword(io, scratch[0..16], "synthetic password", &original, key.vault_id, key.key_id));
    try zero(scratch[0..16]);
    std.crypto.secureZero(u8, scratch);
}

test "vault crypto: production KDF defaults and scratch contract cannot select test parameters" {
    try std.testing.expectEqual(@as(u32, 64 * 1024), t.KdfParameters.production.memory_kib);
    try std.testing.expectEqual(@as(u32, 3), t.KdfParameters.production.passes);
    try std.testing.expectEqual(@as(u32, 1), t.KdfParameters.production.lanes);
    try std.testing.expect(try t.KdfParameters.production.scratchBytes() < 65 * 1024 * 1024);
    // Reject insufficient borrowed scratch without attempting Argon2. The
    // separate production-profile test below exercises the real parameters.
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var scratch: [16]u8 = @splat(0xa5);
    try std.testing.expectError(error.VaultKdfWorkspaceTooSmall, crypto.wrapPassword(io, &scratch, "synthetic production password", &key));
    try zero(&scratch);
}

test "vault crypto production: real default derivation and password replacement reuse caller scratch" {
    var lease = try kdf_memory.Lease.acquire(.production);
    defer lease.release();
    const scratch = lease.bytes;
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const slot = try crypto.wrapPassword(io, scratch, "synthetic production password", &key);
    try zero(scratch);
    const changed = try crypto.changePassword(io, scratch, "synthetic production password", "synthetic replacement password", &slot, key.vault_id, key.key_id);
    var recovered = try crypto.unwrapPassword(io, scratch, "synthetic replacement password", &changed, key.vault_id, key.key_id);
    defer recovered.wipe();
    try sameKey(&key, &recovered);
    try zero(scratch);
}

test "vault crypto: binary and empty records preserve bytes and independently randomize nonces" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var encrypted: [1024]u8 = undefined;
    var another: [1024]u8 = undefined;
    var decoded: [1024]u8 = undefined;
    for ([_][]const u8{ "", "\x00\xff\x01\x80\r\nSynthetic bytes\x00", "private synthetic credential" }) |plaintext| {
        const wire = try crypto.sealRecord(io, &key, identity, plaintext, &encrypted, &workspace);
        try std.testing.expectEqual(try t.sealedSize(plaintext.len), wire.len);
        const duplicate = try crypto.sealRecord(io, &key, identity, plaintext, &another, &workspace);
        try std.testing.expect(!std.mem.eql(u8, wire[56..80], duplicate[56..80]));
        try std.testing.expectEqualSlices(u8, plaintext, try crypto.openRecord(io, &key, identity, wire, &decoded, &workspace));
        try zero(&workspace.plaintext);
        try zero(&workspace.ciphertext);
    }
}

test "vault crypto: account kind ID revision and data key are authenticated before publication" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var encrypted: [1024]u8 = undefined;
    const wire = try crypto.sealRecord(io, &key, identity, "private synthetic record", &encrypted, &workspace);
    var decoded: [1024]u8 = @splat(0xa5);
    const variations = [_]t.Binding{
        .{ .account = "another@example.test", .kind = identity.kind, .record_id = identity.record_id, .revision = identity.revision },
        .{ .account = identity.account, .kind = .credentials, .record_id = identity.record_id, .revision = identity.revision },
        .{ .account = identity.account, .kind = identity.kind, .record_id = "different-message", .revision = identity.revision },
        .{ .account = identity.account, .kind = identity.kind, .record_id = identity.record_id, .revision = 2 },
    };
    for (variations) |binding| {
        try std.testing.expectError(error.VaultAuthenticationFailed, crypto.openRecord(io, &key, binding, wire, &decoded, &workspace));
        try zero(&decoded);
    }
    // Length-prefixing prevents ambiguous concatenations of account and ID.
    var original = identity;
    original.account = "abc";
    original.record_id = "def";
    var collision = original;
    collision.account = "ab";
    collision.record_id = "cdef";
    const second = try crypto.sealRecord(io, &key, original, "private synthetic record", &encrypted, &workspace);
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.openRecord(io, &key, collision, second, &decoded, &workspace));
    var wrong_key = key;
    defer wrong_key.wipe();
    wrong_key.bytes[0] ^= 1;
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.openRecord(io, &wrong_key, original, second, &decoded, &workspace));
    wrong_key.vault_id[0] ^= 1;
    try std.testing.expectError(error.VaultIdentityMismatch, crypto.openRecord(io, &wrong_key, original, second, &decoded, &workspace));
    try zero(&decoded);
}

test "vault crypto: every record byte and final marker is authenticated and failures wipe output" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var encrypted: [1024]u8 = undefined;
    const wire = try crypto.sealRecord(io, &key, identity, "private record for corruption tests", &encrypted, &workspace);
    var altered: [1024]u8 = undefined;
    var decoded: [1024]u8 = undefined;
    for (0..wire.len) |offset| {
        @memcpy(altered[0..wire.len], wire);
        altered[offset] ^= 0x80;
        @memset(&decoded, 0xa5);
        if (crypto.openRecord(io, &key, identity, altered[0..wire.len], &decoded, &workspace)) |_| return error.AcceptedCorruptVaultRecord else |_| {}
        try zero(&decoded);
        try zero(&workspace.plaintext);
    }
    for (0..wire.len) |length| {
        @memset(&decoded, 0xa5);
        if (crypto.openRecord(io, &key, identity, wire[0..length], &decoded, &workspace)) |_| return error.AcceptedTruncatedVaultRecord else |_| {}
        try zero(&decoded);
    }
    @memcpy(altered[0..wire.len], wire);
    altered[wire.len] = 0;
    try std.testing.expectError(error.TrailingVaultData, crypto.openRecord(io, &key, identity, altered[0 .. wire.len + 1], &decoded, &workspace));
    try zero(&decoded);
    altered[8] = 2;
    try std.testing.expectError(error.UnsupportedVaultVersion, crypto.openRecord(io, &key, identity, altered[0..wire.len], &decoded, &workspace));
    try zero(&decoded);
    try std.testing.expectError(error.VaultOutputTooSmall, crypto.openRecord(io, &key, identity, wire, decoded[0..2], &workspace));
    try zero(decoded[0..2]);
}

const Source = struct {
    bytes: []const u8,
    offset: usize = 0,
    quantum: usize = 333,
    fail_at: ?usize = null,
    failure: anyerror = error.SyntheticReadFailure,
    fn read(context: *anyopaque, output: []u8) !usize {
        const self: *Source = @ptrCast(@alignCast(context));
        if (self.fail_at) |limit| if (self.offset >= limit) return self.failure;
        const count = @min(output.len, self.bytes.len - self.offset, self.quantum);
        @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
    fn adapter(self: *Source) t.Source {
        return .{ .context = self, .readFn = read };
    }
};
const Sink = struct {
    bytes: []u8,
    offset: usize = 0,
    commits: usize = 0,
    aborts: usize = 0,
    fail_write: bool = false,
    fail_commit: bool = false,
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *Sink = @ptrCast(@alignCast(context));
        if (self.fail_write) return error.SyntheticWriteFailure;
        if (bytes.len > self.bytes.len - self.offset) return error.SyntheticOutputTooSmall;
        @memcpy(self.bytes[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }
    fn commit(context: *anyopaque) !void {
        const self: *Sink = @ptrCast(@alignCast(context));
        if (self.fail_commit) return error.SyntheticCommitFailure;
        self.commits += 1;
    }
    fn abort(context: *anyopaque) void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.aborts += 1;
        std.crypto.secureZero(u8, self.bytes);
        self.offset = 0;
    }
    fn adapter(self: *Sink) t.StagingSink {
        return .{ .context = self, .writeFn = write, .commitFn = commit, .abortFn = abort };
    }
};

test "vault crypto: chunk boundaries reorder splice and final truncation never publish plaintext" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const plaintext = try allocator.alloc(u8, 2 * t.chunk_bytes + 37);
    defer allocator.free(plaintext);
    for (plaintext, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% (i / t.chunk_bytes));
    const encrypted = try allocator.alloc(u8, try t.sealedSize(plaintext.len));
    defer allocator.free(encrypted);
    const decoded = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(decoded);
    var source: Source = .{ .bytes = plaintext };
    var sink: Sink = .{ .bytes = encrypted };
    try crypto.sealStream(io, &key, identity, plaintext.len, source.adapter(), sink.adapter(), &workspace);
    try std.testing.expectEqual(@as(usize, 1), sink.commits);
    try std.testing.expectEqual(@as(usize, 0), sink.aborts);
    source = .{ .bytes = encrypted, .quantum = 17 };
    sink = .{ .bytes = decoded };
    try crypto.openStream(io, &key, identity, source.adapter(), sink.adapter(), &workspace);
    try std.testing.expectEqualSlices(u8, plaintext, decoded);
    try std.testing.expectEqual(@as(usize, 1), sink.commits);
    const altered = try allocator.dupe(u8, encrypted);
    defer allocator.free(altered);
    const first = t.record_header_bytes;
    const frame_size = t.chunk_bytes + t.tag_bytes;
    @memcpy(altered[first..][0..frame_size], encrypted[first + frame_size ..][0..frame_size]);
    @memcpy(altered[first + frame_size ..][0..frame_size], encrypted[first..][0..frame_size]);
    source = .{ .bytes = altered };
    sink = .{ .bytes = decoded };
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.openStream(io, &key, identity, source.adapter(), sink.adapter(), &workspace));
    try std.testing.expectEqual(@as(usize, 0), sink.commits);
    try std.testing.expectEqual(@as(usize, 1), sink.aborts);
    try zero(decoded);
    // Two full authenticated chunks have already reached private staging when
    // final validation fails. Abort removes them and commit is never called.
    for ([_]usize{ encrypted.len - 1, encrypted.len - t.tag_bytes, first + frame_size }) |length| {
        source = .{ .bytes = encrypted[0..length] };
        sink = .{ .bytes = decoded };
        try std.testing.expectError(error.TruncatedVaultRecord, crypto.openStream(io, &key, identity, source.adapter(), sink.adapter(), &workspace));
        try std.testing.expectEqual(@as(usize, 0), sink.commits);
        try std.testing.expectEqual(@as(usize, 1), sink.aborts);
        try zero(decoded);
    }
    // A ciphertext frame from another independently randomized record cannot
    // be pasted into this one, even with identical identity and plaintext.
    _ = try crypto.sealRecord(io, &key, identity, plaintext, altered, &workspace);
    @memcpy(altered[0..first], encrypted[0..first]);
    source = .{ .bytes = altered };
    sink = .{ .bytes = decoded };
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.openStream(io, &key, identity, source.adapter(), sink.adapter(), &workspace));
    try zero(decoded);
}

test "vault crypto: source destination and commit errors abort staging exactly once" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var encrypted: [1024]u8 = undefined;
    var decoded: [1024]u8 = undefined;
    const plaintext = "synthetic private file";
    var source: Source = .{ .bytes = plaintext, .fail_at = 0 };
    var sink: Sink = .{ .bytes = &encrypted };
    try std.testing.expectError(error.SyntheticReadFailure, crypto.sealStream(io, &key, identity, plaintext.len, source.adapter(), sink.adapter(), &workspace));
    try std.testing.expectEqual(@as(usize, 1), sink.aborts);
    try std.testing.expectEqual(@as(usize, 0), sink.commits);
    const wire = try crypto.sealRecord(io, &key, identity, plaintext, &encrypted, &workspace);
    source = .{ .bytes = wire, .fail_at = t.record_header_bytes, .failure = error.Canceled };
    sink = .{ .bytes = &decoded };
    try std.testing.expectError(error.Canceled, crypto.openStream(io, &key, identity, source.adapter(), sink.adapter(), &workspace));
    try std.testing.expectEqual(@as(usize, 1), sink.aborts);
    try std.testing.expectEqual(@as(usize, 0), sink.commits);
    try zero(&decoded);
    for ([_]bool{ true, false }) |fail_write| {
        source = .{ .bytes = wire };
        sink = .{ .bytes = &decoded, .fail_write = fail_write, .fail_commit = !fail_write };
        try std.testing.expectError(if (fail_write) error.SyntheticWriteFailure else error.SyntheticCommitFailure, crypto.openStream(io, &key, identity, source.adapter(), sink.adapter(), &workspace));
        try std.testing.expectEqual(@as(usize, 1), sink.aborts);
        try std.testing.expectEqual(@as(usize, 0), sink.commits);
        try zero(&decoded);
        try zero(&workspace.plaintext);
    }
    source = .{ .bytes = plaintext };
    sink = .{ .bytes = &encrypted };
    try std.testing.expectError(error.TrailingVaultData, crypto.sealStream(io, &key, identity, plaintext.len - 1, source.adapter(), sink.adapter(), &workspace));
    try std.testing.expectEqual(@as(usize, 1), sink.aborts);
    try zero(&encrypted);
    try std.testing.expectError(error.VaultRecordTooLarge, t.sealedSize(t.max_record_bytes + 1));
}

test "vault crypto: binding bounds fail without publishing or accepting unbounded headers" {
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var encrypted: [1024]u8 = undefined;
    var binding = identity;
    binding.revision = 0;
    try std.testing.expectError(error.InvalidVaultBinding, crypto.sealRecord(io, &key, binding, "", &encrypted, &workspace));
    try zero(&encrypted);
    binding = identity;
    const long_id: [t.max_record_id_bytes + 1]u8 = @splat('x');
    binding.record_id = &long_id;
    try std.testing.expectError(error.InvalidVaultBinding, crypto.sealRecord(io, &key, binding, "", &encrypted, &workspace));
    binding = identity;
    binding.account = "";
    try std.testing.expectError(error.InvalidVaultBinding, crypto.sealRecord(io, &key, binding, "", &encrypted, &workspace));
    const wire = try crypto.sealRecord(io, &key, identity, "", &encrypted, &workspace);
    @memset(encrypted[16..24], 0xff);
    var output: [1]u8 = @splat(0xa5);
    try std.testing.expectError(error.VaultRecordTooLarge, crypto.openRecord(io, &key, identity, wire, &output, &workspace));
    try zero(&output);
}

const stream_test_bytes = 50 * 1024 * 1024;
fn patternByte(offset: usize) u8 {
    return @truncate((offset *% 37) ^ (offset / 251));
}
const PatternSource = struct {
    offset: usize = 0,
    max_request: usize = 0,
    fn read(context: *anyopaque, output: []u8) !usize {
        const self: *PatternSource = @ptrCast(@alignCast(context));
        self.max_request = @max(self.max_request, output.len);
        const count = @min(output.len, stream_test_bytes - self.offset);
        for (output[0..count], self.offset..) |*byte, offset| byte.* = patternByte(offset);
        self.offset += count;
        return count;
    }
};
const CipherFile = struct {
    file: std.Io.File,
    offset: u64 = 0,
    committed: bool = false,
    fn read(context: *anyopaque, output: []u8) !usize {
        const self: *CipherFile = @ptrCast(@alignCast(context));
        const count = try self.file.readPositional(io, &.{output}, self.offset);
        self.offset += count;
        return count;
    }
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *CipherFile = @ptrCast(@alignCast(context));
        try self.file.writeStreamingAll(io, bytes);
    }
    fn commit(context: *anyopaque) !void {
        const self: *CipherFile = @ptrCast(@alignCast(context));
        try self.file.sync(io);
        self.committed = true;
    }
    fn abort(context: *anyopaque) void {
        const self: *CipherFile = @ptrCast(@alignCast(context));
        self.file.setLength(io, 0) catch {};
        self.committed = false;
    }
};
const PatternSink = struct {
    offset: usize = 0,
    max_write: usize = 0,
    committed: bool = false,
    aborted: bool = false,
    fn write(context: *anyopaque, input: []const u8) !void {
        const self: *PatternSink = @ptrCast(@alignCast(context));
        if (input.len > stream_test_bytes - self.offset) return error.SyntheticTooManyBytes;
        self.max_write = @max(self.max_write, input.len);
        for (input, self.offset..) |byte, offset| if (byte != patternByte(offset)) return error.SyntheticWrongBytes;
        self.offset += input.len;
    }
    fn commit(context: *anyopaque) !void {
        const self: *PatternSink = @ptrCast(@alignCast(context));
        if (self.offset != stream_test_bytes) return error.SyntheticWrongByteCount;
        self.committed = true;
    }
    fn abort(context: *anyopaque) void {
        const self: *PatternSink = @ptrCast(@alignCast(context));
        self.aborted = true;
        self.offset = 0;
    }
};

test "vault crypto streaming: 50 MiB synthetic file round-trips with fixed 128 KiB workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    try std.testing.expectEqual(@as(usize, 128 * 1024), @sizeOf(t.StreamWorkspace));
    var pattern: PatternSource = .{};
    var file: CipherFile = .{ .file = try tmp.dir.createFile(io, "synthetic-ciphertext.bin", .{ .read = true, .permissions = .fromMode(0o600) }) };
    defer file.file.close(io);
    const binding: t.Binding = .{ .account = "self@example.test", .kind = .attachment, .record_id = "synthetic-large-attachment", .revision = 1 };
    try crypto.sealStream(io, &key, binding, stream_test_bytes, .{ .context = &pattern, .readFn = PatternSource.read }, .{ .context = &file, .writeFn = CipherFile.write, .commitFn = CipherFile.commit, .abortFn = CipherFile.abort }, &workspace);
    try std.testing.expect(file.committed);
    try std.testing.expectEqual(@as(usize, stream_test_bytes), pattern.offset);
    try std.testing.expect(pattern.max_request <= t.chunk_bytes);
    try std.testing.expectEqual(@as(u64, @intCast(try t.sealedSize(stream_test_bytes))), (try file.file.stat(io)).size);
    var destination: PatternSink = .{};
    try crypto.openStream(io, &key, binding, .{ .context = &file, .readFn = CipherFile.read }, .{ .context = &destination, .writeFn = PatternSink.write, .commitFn = PatternSink.commit, .abortFn = PatternSink.abort }, &workspace);
    try std.testing.expect(destination.committed and !destination.aborted);
    try std.testing.expectEqual(@as(usize, stream_test_bytes), destination.offset);
    try std.testing.expect(destination.max_write <= t.chunk_bytes);
    try zero(&workspace.plaintext);
    try zero(&workspace.ciphertext);
}

test "vault crypto: standalone build information" {
    const builtin = @import("builtin");
    std.debug.print("vault-check compiler={s} mode={s} target={s}-{s}\n", .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
}
