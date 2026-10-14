//! Human recovery-key representation. The checksum catches transcription
//! mistakes; authentication still comes from the encrypted recovery slot.
const std = @import("std");
const t = @import("vault_types.zig");
const Hash = std.crypto.hash.sha2.Sha256;

pub const text_bytes = 85;
pub const input_bytes = 128;

fn checksum(key: *const t.RecoveryKey) [4]u8 {
    var hash: Hash = .init(.{});
    hash.update("omagma-recovery-display-v1");
    hash.update(&key.bytes);
    var digest: [Hash.digest_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    hash.final(&digest);
    return digest[0..4].*;
}

pub fn format(key: *const t.RecoveryKey) [text_bytes]u8 {
    var result: [text_bytes]u8 = undefined;
    @memcpy(result[0..5], "OMR1-");
    var hex = std.fmt.bytesToHex(key.bytes, .lower);
    defer std.crypto.secureZero(u8, &hex);
    var position: usize = 5;
    for (0..8) |group| {
        @memcpy(result[position..][0..8], hex[group * 8 ..][0..8]);
        position += 8;
        result[position] = '-';
        position += 1;
    }
    @memcpy(result[position..][0..8], &std.fmt.bytesToHex(checksum(key), .lower));
    return result;
}

pub fn parse(bytes: []const u8) !t.RecoveryKey {
    var result: t.RecoveryKey = undefined;
    errdefer result.wipe();
    // Earlier fixture vaults displayed ungrouped keys. Their authentication is
    // preserved; every newly displayed key includes the checksum below.
    if (bytes.len == 64) {
        _ = std.fmt.hexToBytes(&result.bytes, bytes) catch return error.InvalidRecoveryKey;
        return result;
    }
    if (bytes.len != text_bytes or !std.ascii.eqlIgnoreCase(bytes[0..5], "OMR1-")) return error.InvalidRecoveryKey;
    var hex: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &hex);
    for (0..8) |group| {
        const start = 5 + group * 9;
        @memcpy(hex[group * 8 ..][0..8], bytes[start..][0..8]);
        if (bytes[start + 8] != '-') return error.InvalidRecoveryKey;
    }
    _ = std.fmt.hexToBytes(&result.bytes, &hex) catch return error.InvalidRecoveryKey;
    var expected: [4]u8 = undefined;
    defer std.crypto.secureZero(u8, &expected);
    _ = std.fmt.hexToBytes(&expected, bytes[77..85]) catch return error.InvalidRecoveryKey;
    if (!std.mem.eql(u8, &expected, &checksum(&result))) return error.RecoveryChecksumMismatch;
    return result;
}

test "vault recovery: grouped key roundtrips and rejects transcription errors" {
    var key: t.RecoveryKey = .{ .bytes = undefined };
    defer key.wipe();
    for (&key.bytes, 0..) |*byte, index| byte.* = @intCast(index * 7);
    var encoded = format(&key);
    defer std.crypto.secureZero(u8, &encoded);
    var parsed = try parse(&encoded);
    defer parsed.wipe();
    try std.testing.expectEqualSlices(u8, &key.bytes, &parsed.bytes);
    encoded[5] = if (encoded[5] == '0') '1' else '0';
    try std.testing.expectError(error.RecoveryChecksumMismatch, parse(&encoded));
    encoded = format(&key);
    encoded[13] = ' ';
    try std.testing.expectError(error.InvalidRecoveryKey, parse(&encoded));
    var legacy = std.fmt.bytesToHex(key.bytes, .lower);
    defer std.crypto.secureZero(u8, &legacy);
    var old = try parse(&legacy);
    defer old.wipe();
    try std.testing.expectEqualSlices(u8, &key.bytes, &old.bytes);
}
