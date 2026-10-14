//! Durable encrypted key slots, deliberately outside the disposable mail
//! cache. This API requires the caller's config/data path; it chooses no path.
//! The checksum detects damage, not passwords. Slot AEAD authenticates secrets.
const std = @import("std");
const t = @import("vault_types.zig");
const crypto = @import("vault_crypto.zig");
const storage = @import("vault_storage.zig");
const Hash = std.crypto.hash.sha2.Sha256;

pub const filename = "vault.header";
pub const backup_filename = "vault.header.bak";
const magic = "OMAVHDR\x00";
const slots_offset = 76;
const checksum_offset = slots_offset + 2 * t.keyslot_bytes;
pub const wire_bytes = checksum_offset + Hash.digest_length;
pub const Wire = [wire_bytes]u8;
pub const Header = struct {
    vault_id: t.Id,
    key_id: t.Id,
    /// Nonsecret bootstrap reference; account names and account-index handles
    /// exist only inside this encrypted catalog. The checksum is not an
    /// authenticator: callers must unwrap a slot and authenticate rootRecord().
    root_record: storage.Handle,
    password: t.KeySlot,
    recovery: t.KeySlot,

    pub fn rootRecord(self: Header) storage.Record {
        return .{ .account = "omagma-vault-catalog-v1", .kind = .catalog, .handle = self.root_record };
    }

    pub fn encode(self: Header) !Wire {
        try validateSlot(&self.password, .password, self.vault_id, self.key_id);
        try validateSlot(&self.recovery, .recovery, self.vault_id, self.key_id);
        var result: Wire = @splat(0);
        @memcpy(result[0..8], magic);
        std.mem.writeInt(u16, result[8..10], t.format_version, .little);
        @memcpy(result[12..28], &self.vault_id);
        @memcpy(result[28..44], &self.key_id);
        @memcpy(result[44..76], &self.root_record.bytes);
        @memcpy(result[slots_offset..][0..t.keyslot_bytes], &self.password);
        @memcpy(result[slots_offset + t.keyslot_bytes ..][0..t.keyslot_bytes], &self.recovery);
        Hash.hash(result[0..checksum_offset], result[checksum_offset..], .{});
        return result;
    }
    pub fn decode(wire: []const u8) !Header {
        if (wire.len != wire_bytes or !std.mem.eql(u8, wire[0..8], magic)) return error.InvalidVaultHeader;
        if (std.mem.readInt(u16, wire[8..10], .little) != t.format_version) return error.UnsupportedVaultVersion;
        if (wire[10] != 0 or wire[11] != 0) return error.InvalidVaultHeader;
        var digest: [Hash.digest_length]u8 = undefined;
        Hash.hash(wire[0..checksum_offset], &digest, .{});
        if (!std.mem.eql(u8, &digest, wire[checksum_offset..])) return error.InvalidVaultHeader;
        const result: Header = .{
            .vault_id = wire[12..28].*,
            .key_id = wire[28..44].*,
            .root_record = .{ .bytes = wire[44..76].* },
            .password = wire[slots_offset..][0..t.keyslot_bytes].*,
            .recovery = wire[slots_offset + t.keyslot_bytes ..][0..t.keyslot_bytes].*,
        };
        try validateSlot(&result.password, .password, result.vault_id, result.key_id);
        try validateSlot(&result.recovery, .recovery, result.vault_id, result.key_id);
        return result;
    }
};

fn validateSlot(slot: *const t.KeySlot, kind: t.SlotKind, vault_id: t.Id, key_id: t.Id) !void {
    // Structural validation only. crypto.unwrapPassword owns the persistent
    // KDF allowlist and rejects hostile parameters before deriving anything.
    if (!std.mem.eql(u8, slot[0..8], t.keyslot_magic) or std.mem.readInt(u16, slot[8..10], .little) != t.format_version or slot[10] != @backingInt(kind) or slot[11] != 1 or !std.mem.eql(u8, slot[24..40], &vault_id) or !std.mem.eql(u8, slot[40..56], &key_id)) return error.InvalidVaultHeader;
    if (kind == .recovery) {
        for (slot[12..24]) |byte| if (byte != 0) return error.InvalidVaultHeader;
        for (slot[56..88]) |byte| if (byte != 0) return error.InvalidVaultHeader;
    }
}

pub const Loaded = struct { header: Header, used_backup: bool };
pub const Unlocked = struct { header: Header, key: t.DataKey };
pub const Store = struct {
    directory: storage.Directory,
    pub fn open(io: std.Io, durable_config_data_path: []const u8, create_directory: bool) !Store {
        return .{ .directory = try storage.Directory.open(io, durable_config_data_path, create_directory) };
    }
    pub fn close(self: *Store) void {
        self.directory.close();
    }
    fn read(self: *Store, name: [*:0]const u8) !Header {
        const file = try storage.openPrivate(self.directory.io, self.directory.dir, name);
        defer file.close(self.directory.io);
        if ((try file.stat(self.directory.io)).size != wire_bytes) return error.InvalidVaultHeader;
        var wire: Wire = undefined;
        if (try file.readPositionalAll(self.directory.io, &wire, 0) != wire_bytes) return error.InvalidVaultHeader;
        var extra: [1]u8 = undefined;
        if (try file.readPositional(self.directory.io, &.{&extra}, wire_bytes) != 0) return error.InvalidVaultHeader;
        return Header.decode(&wire);
    }
    /// Password/recovery unwrap happens AFTER this operation. Authentication
    /// failure can never select an older backup slot or an older password.
    /// Unknown versions fail closed rather than downgrading to an old backup.
    pub fn load(self: *Store) !Loaded {
        const header = self.read(filename) catch |err| switch (err) {
            error.FileNotFound => return .{ .header = try self.read(backup_filename), .used_backup = true },
            error.InvalidVaultHeader => return .{ .header = self.read(backup_filename) catch |backup_error| return if (backup_error == error.FileNotFound) error.InvalidVaultHeader else backup_error, .used_backup = true },
            else => return err,
        };
        return .{ .header = header, .used_backup = false };
    }
    fn write(self: *Store, name: []const u8, wire: *const Wire, replace: bool, faults: storage.Faults) !void {
        var output = try storage.AtomicFile.init(self.directory.io, self.directory.dir, name, wire_bytes, replace, faults);
        defer output.deinit();
        try output.write(wire);
        try output.commit();
    }
    /// Initialization never reinterprets damaged files as an empty vault.
    /// Either existing name, including a symlink or malformed header, refuses
    /// creation. A failed partial create requires authenticated recovery.
    pub fn create(self: *Store, header: Header, faults: storage.Faults) !void {
        const wire = try header.encode();
        for ([_][]const u8{ filename, backup_filename }) |name| {
            if (self.directory.dir.statFile(self.directory.io, name, .{ .follow_symlinks = false })) |_| return error.PathAlreadyExists else |err| if (err != error.FileNotFound) return err;
        }
        try self.write(backup_filename, &wire, false, faults);
        try self.write(filename, &wire, false, faults);
    }
    pub fn save(self: *Store, header: Header, faults: storage.Faults) !void {
        const wire = try header.encode();
        const current = try self.load();
        if (current.used_backup) return error.VaultHeaderRepairRequired;
        if (!std.mem.eql(u8, &current.header.vault_id, &header.vault_id) or !std.mem.eql(u8, &current.header.key_id, &header.key_id) or !std.mem.eql(u8, &current.header.root_record.bytes, &header.root_record.bytes)) return error.VaultIdentityMismatch;
        const previous = try current.header.encode();
        // A complete, synced backup exists before the primary changes. Both
        // copies contain only encrypted slots; neither is a password verifier.
        try self.write(backup_filename, &previous, true, faults);
        try self.write(filename, &wire, true, faults);
        // Success must retire the previous slots in BOTH managed copies.
        // If this final refresh fails, the new primary is already published:
        // report uncertainty and reconcile on the next authenticated unlock.
        self.write(backup_filename, &wire, true, faults) catch return error.VaultDurabilityUncertain;
    }
    pub fn unlockPassword(self: *Store, scratch: []u8, password: []const u8) !Unlocked {
        const loaded = try self.load();
        const key = try crypto.unwrapPassword(self.directory.io, scratch, password, &loaded.header.password, loaded.header.vault_id, loaded.header.key_id);
        return self.finishUnlock(loaded, key);
    }
    pub fn unlockRecovery(self: *Store, recovery: *const t.RecoveryKey) !Unlocked {
        const loaded = try self.load();
        const key = try crypto.unwrapRecovery(recovery, &loaded.header.recovery, loaded.header.vault_id, loaded.header.key_id);
        return self.finishUnlock(loaded, key);
    }
    // Private: only successful slot AEAD unwrap reaches disk repair. Neither
    // load(), a header checksum nor a failed password can modify either copy.
    // The daemon must still authenticate rootRecord before using its catalog.
    fn finishUnlock(self: *Store, loaded: Loaded, unwrapped: t.DataKey) !Unlocked {
        var key = unwrapped;
        errdefer key.wipe();
        const wire = try loaded.header.encode();
        const other_name = if (loaded.used_backup) filename else backup_filename;
        const other = self.read(other_name) catch |err| switch (err) {
            error.FileNotFound, error.InvalidVaultHeader => null,
            else => return err,
        };
        if (other == null or !std.mem.eql(u8, &(try other.?.encode()), &wire)) try self.write(other_name, &wire, true, .{});
        return .{ .header = loaded.header, .key = key };
    }
};
