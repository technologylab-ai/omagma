//! Native vault wire constants and adapter contracts. No runtime integration.
//! All integers in the v1 wire format are unsigned little-endian values.
const std = @import("std");

pub const format_version: u16 = 1;
pub const key_bytes = 32;
pub const id_bytes = 16;
pub const nonce_bytes = 24;
pub const tag_bytes = 16;
pub const salt_bytes = 32;
pub const chunk_bytes = 64 * 1024;
pub const max_record_bytes = 64 * 1024 * 1024;
pub const max_account_bytes = 254;
pub const max_record_id_bytes = 1024;
pub const max_password_bytes = 1024;
pub const keyslot_bytes = 160;
pub const keyslot_header_bytes = keyslot_bytes - key_bytes - tag_bytes;
pub const record_header_bytes = 80;
pub const record_magic = "OMAVREC\x00";
pub const keyslot_magic = "OMAVKEY\x00";
pub const Id = [id_bytes]u8;
pub const KeySlot = [keyslot_bytes]u8;

/// Caller-owned live secret. Never pass this type to JSON or log formatters.
/// The adapter owns its lifetime and calls wipe on lock, cancellation or exit.
/// key_id changes only when the actual data key changes; vault_id stays stable.
pub const DataKey = struct {
    vault_id: Id,
    key_id: Id,
    bytes: [key_bytes]u8,
    pub fn wipe(self: *DataKey) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
};

/// Random 256-bit recovery secret, shown/exported only by an explicit adapter
/// workflow. The encrypted key slot contains no unencrypted copy or verifier.
pub const RecoveryKey = struct {
    bytes: [key_bytes]u8,
    pub fn wipe(self: *RecoveryKey) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
};

pub const SlotKind = enum(u8) { password = 1, recovery = 2 };

pub const KdfParameters = struct {
    memory_kib: u32 = 64 * 1024,
    passes: u32 = 3,
    lanes: u32 = 1,
    pub const production: KdfParameters = .{};
    /// Deliberately weak. Only the crypto module's test-only entry points accept
    /// this profile; ordinary unwrap rejects it even in a test executable.
    pub const fast_test: KdfParameters = .{ .memory_kib = 64, .passes = 1 };
    pub const maximum_memory_kib: u32 = 64 * 1024;
    pub const maximum_passes: u32 = 6;

    /// FixedBufferAllocator may need up to 15 bytes to align Argon2 blocks.
    /// Native unlock uses vault_kdf_memory's temporary mapping: the regular
    /// mail heap cannot supply this whole workspace while it owns a session.
    /// Serialize KDF calls and wipe/release the mapping on every exit.
    pub fn scratchBytes(self: KdfParameters) !usize {
        if (self.memory_kib > maximum_memory_kib) return error.InvalidVaultKdf;
        return @as(usize, self.memory_kib) * 1024 + 15;
    }
};

/// Application roles are cryptographically distinct even if an ID is reused.
/// The kind, account and record ID are authenticated but absent from the wire.
pub const RecordKind = enum(u16) {
    config = 1,
    grants = 2,
    credentials = 3,
    cache_index = 4,
    mail_body = 5,
    draft = 6,
    outbox = 7,
    attachment = 8,
    send_spool = 9,
    contacts = 10,
    operation_ledger = 11,
    preferences = 12,
    catalog = 13,
    identity = 14,
};

/// The adapter supplies the expected identity, not values trusted from a file.
/// Shared records use an explicit stable account namespace chosen by the owner.
/// Revision detects replay only when the expected revision comes from trusted
/// state; encryption alone cannot prevent rollback of an entire saved vault.
pub const Binding = struct {
    account: []const u8,
    kind: RecordKind,
    record_id: []const u8,
    revision: u64,
};

pub const Source = struct {
    context: *anyopaque,
    /// Zero means EOF. A return larger than the output is rejected.
    readFn: *const fn (*anyopaque, []u8) anyerror!usize,
};

/// One private staging destination per call. write must not publish bytes.
/// commit publishes atomically. A filesystem sink can report uncertain
/// durability after publication if directory sync fails; it must expose that
/// state so the caller does not retry an assumed rollback. abort destroys only
/// unpublished staging and must succeed even during cancellation. Internal
/// vault adapters must not persist plaintext staging on disk. The core can
/// instead stage into bounded RAM or an explicitly authorized export target.
/// No callback may keep a borrowed crypto workspace slice.
pub const StagingSink = struct {
    context: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,
    commitFn: *const fn (*anyopaque) anyerror!void,
    abortFn: *const fn (*anyopaque) void,
};

/// Reusable caller-owned storage; no per-chunk allocation or whole-file copy.
/// Keep this disjoint from source/sink storage and KDF scratch. The crypto
/// functions wipe it on every exit. 50 MiB files use the same 128 KiB buffer.
pub const StreamWorkspace = struct {
    plaintext: [chunk_bytes]u8 = undefined,
    ciphertext: [chunk_bytes]u8 = undefined,
    pub fn wipe(self: *StreamWorkspace) void {
        std.crypto.secureZero(u8, &self.plaintext);
        std.crypto.secureZero(u8, &self.ciphertext);
    }
};

pub fn sealedSize(plaintext_bytes: usize) !usize {
    if (plaintext_bytes > max_record_bytes) return error.VaultRecordTooLarge;
    const chunks = (plaintext_bytes + chunk_bytes - 1) / chunk_bytes;
    return record_header_bytes + plaintext_bytes + (chunks + 1) * tag_bytes;
}
