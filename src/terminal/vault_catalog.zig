//! Daemon-owned catalog and account handles. The daemon lends one live key and
//! one workspace, and waits for the operation lease before locking either.
//! No password input, process protocol, plaintext fallback or migration.
const std = @import("std");
const t = @import("vault_types.zig");
const crypto = @import("vault_crypto.zig");
const header = @import("vault_header.zig");
const storage = @import("vault_storage.zig");
pub const max_accounts = 3;
pub const max_catalog_bytes = 4096;
pub const InitialAccount = struct { account: []const u8, initial_index: []const u8, disk_limit: usize };
const WireEntry = struct { account: []const u8, index: []const u8 };
const Wire = struct { schema: u8 = 1, accounts: []const WireEntry, identity: ?[]const u8 = null };

pub const Entry = struct {
    name: [t.max_account_bytes]u8 = @splat(0),
    name_len: usize,
    index: storage.Handle,
    pub fn address(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
    fn init(account: []const u8, index: storage.Handle) !Entry {
        if (account.len == 0 or account.len > t.max_account_bytes or !std.unicode.utf8ValidateSlice(account)) return error.InvalidVaultAccount;
        for (account) |byte| if (byte < 0x21 or byte == 0x7f) return error.InvalidVaultAccount;
        var result: Entry = .{ .name_len = account.len, .index = index };
        @memcpy(result.name[0..account.len], account);
        return result;
    }
};

/// Keep at a stable address while accounts borrow it. durable_data_path and
/// the key/workspace must outlive this owner; the owner never copies the key.
pub const Owner = struct {
    directory: storage.Directory,
    durable_data_path: []const u8,
    key: *const t.DataKey,
    workspace: *t.StreamWorkspace,
    root: storage.Record,
    identity: ?storage.Handle = null,
    entries: [max_accounts]Entry = undefined,
    count: usize = 0,
    occupied: std.atomic.Value(bool) = .init(false),
    uncertain: bool = false,
    /// Set only by the local owner after authenticating completed migration.
    live_enabled: bool = false,
    closed: bool = false,

    fn init(io: std.Io, path: []const u8, saved_header: header.Header, key: *const t.DataKey, workspace: *t.StreamWorkspace, create_directory: bool) !Owner {
        if (!std.mem.eql(u8, &saved_header.vault_id, &key.vault_id) or !std.mem.eql(u8, &saved_header.key_id, &key.key_id)) return error.VaultIdentityMismatch;
        return .{ .directory = try storage.Directory.open(io, path, create_directory), .durable_data_path = path, .key = key, .workspace = workspace, .root = saved_header.rootRecord() };
    }
    /// Write the empty root BEFORE the caller publishes its durable header.
    /// Refuses to replace an existing catalog, even with the same root handle.
    pub fn create(io: std.Io, path: []const u8, saved_header: header.Header, key: *const t.DataKey, workspace: *t.StreamWorkspace) !Owner {
        var self = try init(io, path, saved_header, key, workspace, true);
        errdefer self.close();
        try self.checkLayout(true);
        try self.save(false);
        return self;
    }
    /// Unwrapping a slot alone is insufficient: accept the clear root handle
    /// only after authenticating and validating its complete encrypted catalog.
    pub fn open(io: std.Io, path: []const u8, saved_header: header.Header, key: *const t.DataKey, workspace: *t.StreamWorkspace) !Owner {
        var self = try init(io, path, saved_header, key, workspace, false);
        errdefer self.close();
        var bytes: [max_catalog_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const plain = try readInto(&self.directory, key, self.root, &bytes, workspace);
        var parse_memory: [16 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &parse_memory);
        var fixed: std.heap.FixedBufferAllocator = .init(&parse_memory);
        const wire = try std.json.parseFromSliceLeaky(Wire, fixed.allocator(), plain, .{ .allocate = .alloc_if_needed });
        if (wire.schema != 1 or wire.accounts.len > max_accounts) return error.InvalidVaultCatalog;
        if (wire.identity) |value| {
            self.identity = try storage.Handle.parse(value);
            if (std.mem.eql(u8, &self.identity.?.bytes, &self.root.handle.bytes)) return error.InvalidVaultCatalog;
        }
        for (wire.accounts) |row| {
            const entry = try Entry.init(row.account, try storage.Handle.parse(row.index));
            if (self.identity) |identity| if (std.mem.eql(u8, &identity.bytes, &entry.index.bytes)) return error.InvalidVaultCatalog;
            for (self.entries[0..self.count]) |*existing| {
                if (std.ascii.eqlIgnoreCase(existing.address(), entry.address()) or std.mem.eql(u8, &existing.index.bytes, &entry.index.bytes)) return error.InvalidVaultCatalog;
            }
            self.entries[self.count] = entry;
            self.count += 1;
        }
        try self.recoverIdentityOrphans();
        return self;
    }
    pub fn close(self: *Owner) void {
        if (self.closed) return;
        std.debug.assert(!self.occupied.load(.acquire));
        self.closed = true;
        self.directory.close();
        std.crypto.secureZero(u8, std.mem.asBytes(&self.entries));
        self.count = 0;
    }
    fn claim(self: *Owner) !void {
        if (self.closed) return error.VaultLocked;
        if (self.uncertain) return error.VaultDurabilityUncertain;
        if (self.occupied.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.VaultBusy;
    }
    fn release(self: *Owner) void {
        self.workspace.wipe();
        self.occupied.store(false, .release);
    }
    fn lookup(self: *Owner, account: []const u8) ?*const Entry {
        for (self.entries[0..self.count]) |*entry| if (std.mem.eql(u8, entry.address(), account)) return entry;
        return null;
    }
    fn accountPath(self: *Owner, entry: Entry, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.durable_data_path, entry.index.text() });
    }
    /// An interrupted account addition can leave an opaque directory that no
    /// account quota owns yet. Refuse further allocation until authenticated
    /// inventory/recovery resolves it. Existing accounts remain readable and
    /// writable; never delete unknown directories or infer their ownership.
    fn checkLayout(self: *Owner, empty: bool) !void {
        const root_name = self.root.handle.filename();
        var entries = self.directory.dir.iterate();
        next_entry: while (try entries.next(self.directory.io)) |entry| {
            if (entry.kind == .file and std.mem.eql(u8, entry.name, ".vault-lock")) continue;
            if (!empty) {
                if (entry.kind == .file and std.mem.eql(u8, entry.name, &root_name)) continue;
                if (self.identity) |identity| if (entry.kind == .file and std.mem.eql(u8, entry.name, &identity.filename())) continue;
                if (entry.kind == .directory) for (self.entries[0..self.count]) |known| {
                    if (std.mem.eql(u8, entry.name, &known.index.text())) continue :next_entry;
                };
            }
            return error.VaultRecoveryRequired;
        }
    }
    /// Initial index must already have passed the Store's empty-state admission.
    /// Its ciphertext is durable before the root makes this account discoverable.
    pub fn addAccount(self: *Owner, account: []const u8, initial_index: []const u8, disk_limit: usize) !void {
        // Once an identity exists, its account set and this catalog must move
        // together. Bootstrap callers may still prepare an identity-less vault.
        if (self.identity != null) return error.VaultAtomicIdentityRequired;
        return self.publish(null, &.{.{ .account = account, .initial_index = initial_index, .disk_limit = disk_limit }});
    }
    fn cleanupAccount(self: *Owner, entry: Entry) !void {
        var path_buffer: [4096]u8 = undefined;
        var directory = try storage.Directory.open(self.directory.io, try self.accountPath(entry, &path_buffer), false);
        defer directory.close();
        const index_name = entry.index.filename();
        var index_present = false;
        var iterator = directory.dir.iterate();
        while (try iterator.next(self.directory.io)) |item| {
            if (item.kind != .file) return error.VaultRecoveryRequired;
            if (std.mem.eql(u8, item.name, ".vault-lock")) continue;
            if (!std.mem.eql(u8, item.name, &index_name)) return error.VaultRecoveryRequired;
            var reader = try directory.reader(entry.index);
            defer reader.close();
            _ = try reader.verify(self.key, .{ .account = entry.address(), .kind = .cache_index, .handle = entry.index }, self.workspace);
            index_present = true;
        }
        if (index_present) {
            const file = try storage.openPrivate(self.directory.io, directory.dir, &index_name);
            defer file.close(self.directory.io);
            if (!try file.tryLock(self.directory.io, .exclusive)) return error.VaultBusy;
            defer file.unlock(self.directory.io);
            try directory.dir.deleteFile(self.directory.io, &index_name);
        }
        try directory.dir.deleteFile(self.directory.io, ".vault-lock");
        directory.close();
        try self.directory.dir.deleteDir(self.directory.io, &entry.index.text());
        try storage.syncDirectory(self.directory.io, self.directory.dir);
    }
    fn cleanupUnpublished(self: *Owner, identity: ?storage.Handle, entries: []const Entry) void {
        const protection = self.directory.io.swapCancelProtection(.blocked);
        defer _ = self.directory.io.swapCancelProtection(protection);
        if (identity) |handle| self.retireIdentity(handle) catch {};
        for (entries) |entry| self.cleanupAccount(entry) catch {};
    }
    /// Durable indexes and the replacement identity become visible in one root
    /// rename. A pre-publication failure removes only this attempt's known
    /// records; a possibly published root is retained for authenticated reopen.
    fn publish(self: *Owner, identity_bytes: ?[]const u8, additions: []const InitialAccount) !void {
        try self.claim();
        defer self.release();
        if (additions.len > max_accounts - self.count) return error.VaultAccountLimit;
        if (identity_bytes) |bytes| {
            if (bytes.len == 0 or bytes.len > max_identity_bytes) return error.VaultIdentityTooLarge;
            try self.identityAdmission(try t.sealedSize(bytes.len) + try t.sealedSize(max_catalog_bytes));
        }
        try self.checkLayout(false);
        var planned: [max_accounts]Entry = undefined;
        for (additions, 0..) |addition, index| {
            for (self.entries[0..self.count]) |*existing| if (std.ascii.eqlIgnoreCase(existing.address(), addition.account)) return error.VaultAccountExists;
            for (planned[0..index]) |*existing| if (std.ascii.eqlIgnoreCase(existing.address(), addition.account)) return error.VaultAccountExists;
            if (addition.initial_index.len == 0 or addition.initial_index.len > @import("store.zig").index_read_bytes or try t.sealedSize(addition.initial_index.len) > addition.disk_limit) return error.DiskQuotaExceeded;
            planned[index] = try Entry.init(addition.account, try storage.Handle.create(self.directory.io));
        }
        var created: usize = 0;
        var next_identity: ?storage.Handle = null;
        var publication_uncertain = false;
        errdefer if (!publication_uncertain) self.cleanupUnpublished(next_identity, planned[0..created]);
        for (additions, planned[0..additions.len]) |addition, entry| {
            // Exclusive creation proves this cleanup scope belongs to us.
            try self.directory.dir.createDir(self.directory.io, &entry.index.text(), .fromMode(0o700));
            created += 1;
            var path_buffer: [4096]u8 = undefined;
            var directory = try storage.Directory.open(self.directory.io, try self.accountPath(entry, &path_buffer), false);
            defer directory.close();
            var source: SliceSource = .{ .bytes = addition.initial_index };
            try directory.seal(self.key, .{ .account = entry.address(), .kind = .cache_index, .handle = entry.index }, source.bytes.len, source.source(), self.workspace, false);
            // Persist the new directory's name before the catalog can refer to it.
            try storage.syncDirectory(self.directory.io, self.directory.dir);
        }
        if (identity_bytes) |bytes| {
            next_identity = try storage.Handle.create(self.directory.io);
            var source: SliceSource = .{ .bytes = bytes };
            try self.directory.seal(self.key, identityRecord(next_identity.?), bytes.len, source.source(), self.workspace, false);
        }
        const previous_count = self.count;
        const previous_identity = self.identity;
        @memcpy(self.entries[self.count..][0..additions.len], planned[0..additions.len]);
        self.count += additions.len;
        if (next_identity) |handle| self.identity = handle;
        self.save(true) catch |err| {
            if (err == error.VaultDurabilityUncertain) {
                self.uncertain = true;
                publication_uncertain = true;
            } else {
                self.count = previous_count;
                self.identity = previous_identity;
            }
            return err;
        };
        if (next_identity != null) if (previous_identity) |old| self.retireIdentity(old) catch {};
    }
    fn save(self: *Owner, replace: bool) !void {
        var handles: [max_accounts][64]u8 = undefined;
        var rows: [max_accounts]WireEntry = undefined;
        for (self.entries[0..self.count], 0..) |*entry, index| {
            handles[index] = entry.index.text();
            rows[index] = .{ .account = entry.address(), .index = &handles[index] };
        }
        var bytes: [max_catalog_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        var output: std.Io.Writer = .fixed(&bytes);
        const identity_text = if (self.identity) |identity| identity.text() else undefined;
        try std.json.Stringify.value(Wire{ .accounts = rows[0..self.count], .identity = if (self.identity != null) &identity_text else null }, .{}, &output);
        var source: SliceSource = .{ .bytes = output.buffered() };
        try self.directory.seal(self.key, self.root, source.bytes.len, source.source(), self.workspace, replace);
    }
    pub const max_identity_bytes = 768 * 1024;
    pub const identity_disk_limit = 2 * 1024 * 1024;
    fn identityRecord(handle: storage.Handle) storage.Record {
        return .{ .account = "omagma-vault-identity-v1", .kind = .identity, .handle = handle };
    }
    pub fn readIdentity(self: *Owner, a: std.mem.Allocator) ![]u8 {
        try self.claim();
        defer self.release();
        const handle = self.identity orelse return error.VaultIdentityRequired;
        var reader = try self.directory.reader(handle);
        defer reader.close();
        if (reader.initial.size > try t.sealedSize(t.max_record_bytes)) return error.VaultRecordTooLarge;
        const size = try reader.verify(self.key, identityRecord(handle), self.workspace);
        if (size > max_identity_bytes) return error.VaultIdentityTooLarge;
        const bytes = try a.alloc(u8, size);
        errdefer {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        reader.offset = 0;
        var sink: MemorySink = .{ .bytes = bytes };
        const text = handle.text();
        try crypto.openStream(self.directory.io, self.key, storage.binding(identityRecord(handle), &text), reader.source(), sink.sink(), self.workspace);
        if (sink.count != size) return error.VaultRecordChanged;
        return bytes;
    }
    /// Count all root ciphertext, including failed publications and staging.
    /// Unknown directories require authenticated recovery, never blind removal.
    fn identityAdmission(self: *Owner, additional: usize) !void {
        var total: u64 = additional;
        var iterator = self.directory.dir.iterate();
        next: while (try iterator.next(self.directory.io)) |entry| {
            if (entry.kind == .directory) {
                for (self.entries[0..self.count]) |known| if (std.mem.eql(u8, entry.name, &known.index.text())) continue :next;
                return error.VaultRecoveryRequired;
            }
            if (entry.kind != .file) return error.VaultRecoveryRequired;
            if (entry.name.len > 255) return error.VaultRecoveryRequired;
            var name_buffer: [255:0]u8 = undefined;
            @memcpy(name_buffer[0..entry.name.len], entry.name);
            name_buffer[entry.name.len] = 0;
            const file = try storage.openPrivate(self.directory.io, self.directory.dir, &name_buffer);
            defer file.close(self.directory.io);
            total += (try file.stat(self.directory.io)).size;
            if (total > identity_disk_limit) return error.DiskQuotaExceeded;
        }
    }
    pub fn writeIdentity(self: *Owner, bytes: []const u8) !void {
        return self.publish(bytes, &.{});
    }
    pub fn writeIdentityWithAccounts(self: *Owner, bytes: []const u8, additions: []const InitialAccount) !void {
        return self.publish(bytes, additions);
    }
    fn authenticateReferences(self: *Owner) !void {
        if (self.identity) |handle| {
            var reader = try self.directory.reader(handle);
            defer reader.close();
            if (try reader.verify(self.key, identityRecord(handle), self.workspace) > max_identity_bytes) return error.VaultIdentityTooLarge;
        }
        for (self.entries[0..self.count]) |entry| {
            var path_buffer: [4096]u8 = undefined;
            var directory = try storage.Directory.open(self.directory.io, try self.accountPath(entry, &path_buffer), false);
            defer directory.close();
            var reader = try directory.reader(entry.index);
            defer reader.close();
            if (try reader.verify(self.key, .{ .account = entry.address(), .kind = .cache_index, .handle = entry.index }, self.workspace) > @import("store.zig").index_read_bytes) return error.InvalidVaultIndex;
        }
    }
    /// Run only during open, before Accounts can borrow directory leases. The
    /// authenticated catalog, current identity and all account indexes must
    /// verify before any unreferenced identity ciphertext is removed. Unknown
    /// data remains untouched and still blocks new allocations in checkLayout.
    fn recoverIdentityOrphans(self: *Owner) !void {
        var references_verified = false;
        var iterator = self.directory.dir.iterate();
        while (try iterator.next(self.directory.io)) |entry| {
            if (entry.kind != .file or entry.name.len != 73 or !std.mem.startsWith(u8, entry.name, "vrec-") or !std.mem.endsWith(u8, entry.name, ".bin")) continue;
            const handle = storage.Handle.parse(entry.name[5..69]) catch continue;
            if (std.mem.eql(u8, &handle.bytes, &self.root.handle.bytes)) continue;
            if (self.identity) |current| if (std.mem.eql(u8, &handle.bytes, &current.bytes)) continue;
            var reader = try self.directory.reader(handle);
            const size = reader.verify(self.key, identityRecord(handle), self.workspace) catch |err| {
                reader.close();
                if (err == error.Canceled or err == error.Timeout) return err;
                continue;
            };
            reader.close();
            if (size > max_identity_bytes) continue;
            if (!references_verified) {
                try self.authenticateReferences();
                references_verified = true;
            }
            self.retireIdentity(handle) catch |err| switch (err) {
                error.VaultBusy => continue,
                else => return err,
            };
        }
    }
    fn retireIdentity(self: *Owner, handle: storage.Handle) !void {
        const name = handle.filename();
        const file = try storage.openPrivate(self.directory.io, self.directory.dir, &name);
        defer file.close(self.directory.io);
        if (!try file.tryLock(self.directory.io, .exclusive)) return error.VaultBusy;
        defer file.unlock(self.directory.io);
        try self.directory.dir.deleteFile(self.directory.io, &name);
        try storage.syncDirectory(self.directory.io, self.directory.dir);
    }
    pub fn openAccount(self: *Owner, account: []const u8) !Account {
        try self.claim();
        defer self.release();
        const entry = (self.lookup(account) orelse return error.VaultAccountNotFound).*;
        var path_buffer: [4096]u8 = undefined;
        const path = try self.accountPath(entry, &path_buffer);
        return .{ .owner = self, .entry = entry, .directory = try storage.Directory.open(self.directory.io, path, false) };
    }
};

pub const Account = struct {
    owner: *Owner,
    entry: Entry,
    directory: storage.Directory,
    active: bool = false,
    workspace_pinned: bool = false,
    reader_owner: ?*anyopaque = null,
    /// Immutable object token, independent of the Writer's stack address.
    writer_owner: ?storage.Handle = null,
    closed: bool = false,
    pub fn claim(self: *Account) !void {
        if (self.closed) return error.VaultLocked;
        if (self.workspace_pinned) return error.VaultBusy;
        try self.owner.claim();
        self.active = true;
    }
    pub fn release(self: *Account) void {
        if (!self.active) return;
        self.active = false;
        if (!self.workspace_pinned and self.writer_owner == null) self.owner.release();
    }
    /// Pins only bounded crypto scratch across an unlocked network operation.
    /// The owner and account must outlive the pin. Finish/abort before reopening
    /// a Store transaction; no nested Directory.open or Store lock is needed.
    pub fn pinWorkspace(self: *Account) !void {
        if (self.closed or self.owner.closed) return error.VaultLocked;
        if (self.workspace_pinned or self.reader_owner != null or self.writer_owner != null) return error.VaultBusy;
        if (!self.active) try self.owner.claim();
        self.workspace_pinned = true;
    }
    pub fn unpinWorkspace(self: *Account) void {
        if (!self.workspace_pinned) return;
        self.workspace_pinned = false;
        if (!self.active and self.writer_owner == null) self.owner.release();
    }
    /// The account outlives the in-place stream. Releasing a Store may drop
    /// its transaction while the stream still owns scratch; keep other
    /// accounts out until the matching stream finishes or aborts.
    pub fn releaseWriter(owner: *?storage.Handle, token: storage.Handle) void {
        const self: *Account = @alignCast(@fieldParentPtr("writer_owner", owner));
        const current = owner.* orelse return;
        if (!std.mem.eql(u8, &current.bytes, &token.bytes)) return;
        owner.* = null;
        if (!self.active and !self.workspace_pinned) self.owner.release();
    }
    pub fn close(self: *Account) void {
        if (self.closed) return;
        self.release();
        self.unpinWorkspace();
        self.closed = true;
        self.directory.close();
    }
    pub fn requireActive(self: *const Account) !void {
        if (self.closed or self.owner.closed) return error.VaultLocked;
        if (!self.active) return error.VaultBusy;
    }
    pub fn record(self: *const Account, kind: t.RecordKind, handle: storage.Handle) storage.Record {
        return .{ .account = self.entry.address(), .kind = kind, .handle = handle };
    }
    pub fn requireSharedWorkspace(self: *const Account) !void {
        try self.requireActive();
        if (self.workspace_pinned or self.reader_owner != null or self.writer_owner != null) return error.VaultBusy;
    }
    pub fn read(self: *Account, allocator: std.mem.Allocator, kind: t.RecordKind, handle: storage.Handle, limit: usize) ![]u8 {
        return self.readWithWorkspace(allocator, kind, handle, limit, self.owner.workspace);
    }
    /// Metadata lookups can run between writes to an in-place sealed stream.
    /// Such callers must supply disjoint scratch instead of wiping the stream's
    /// partially buffered plaintext. All scratch is wiped before returning.
    pub fn readWithWorkspace(self: *Account, allocator: std.mem.Allocator, kind: t.RecordKind, handle: storage.Handle, limit: usize, workspace: *t.StreamWorkspace) ![]u8 {
        try self.requireActive();
        if (self.workspace_pinned or self.reader_owner != null) return error.VaultBusy;
        if (workspace == self.owner.workspace) try self.requireSharedWorkspace();
        defer workspace.wipe();
        var reader = try self.directory.reader(handle);
        defer reader.close();
        const identity = self.record(kind, handle);
        const size = try reader.verify(self.owner.key, identity, workspace);
        if (size > limit) return error.CacheLimitExceeded;
        const output = try allocator.alloc(u8, size);
        errdefer {
            std.crypto.secureZero(u8, output);
            allocator.free(output);
        }
        // RAM is private staging. Verify once for exact allocation, then open
        // again into RAM and expose it only after the final marker succeeds.
        reader.offset = 0;
        var sink: MemorySink = .{ .bytes = output };
        const handle_text = handle.text();
        try crypto.openStream(self.directory.io, self.owner.key, storage.binding(identity, &handle_text), reader.source(), sink.sink(), workspace);
        if (sink.count != size) return error.VaultRecordChanged;
        return output;
    }
    pub fn write(self: *Account, kind: t.RecordKind, handle: storage.Handle, bytes: []const u8, replace: bool) !void {
        try self.requireSharedWorkspace();
        _ = try t.sealedSize(bytes.len);
        var source: SliceSource = .{ .bytes = bytes };
        try self.directory.seal(self.owner.key, self.record(kind, handle), bytes.len, source.source(), self.owner.workspace, replace);
    }
    pub fn remove(self: *Account, handle: storage.Handle) !void {
        try self.requireActive();
        const name = handle.filename();
        const file = try storage.openPrivate(self.directory.io, self.directory.dir, &name);
        defer file.close(self.directory.io);
        if (!try file.tryLock(self.directory.io, .exclusive)) return error.VaultBusy;
        defer file.unlock(self.directory.io);
        try self.directory.dir.deleteFile(self.directory.io, &name);
        try storage.syncDirectory(self.directory.io, self.directory.dir);
    }
};

fn readInto(directory: *storage.Directory, key: *const t.DataKey, identity: storage.Record, output: []u8, workspace: *t.StreamWorkspace) ![]u8 {
    var reader = try directory.reader(identity.handle);
    defer reader.close();
    var sink: MemorySink = .{ .bytes = output };
    const handle_text = identity.handle.text();
    try crypto.openStream(directory.io, key, storage.binding(identity, &handle_text), reader.source(), sink.sink(), workspace);
    return output[0..sink.count];
}
const SliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn source(self: *SliceSource) t.Source {
        return .{ .context = self, .readFn = read };
    }
    fn read(context: *anyopaque, output: []u8) !usize {
        const self: *SliceSource = @ptrCast(@alignCast(context));
        const count = @min(output.len, self.bytes.len - self.offset);
        @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};
const MemorySink = struct {
    bytes: []u8,
    count: usize = 0,
    fn sink(self: *MemorySink) t.StagingSink {
        return .{ .context = self, .writeFn = write, .commitFn = commit, .abortFn = abort };
    }
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *MemorySink = @ptrCast(@alignCast(context));
        if (bytes.len > self.bytes.len - self.count) return error.CacheLimitExceeded;
        @memcpy(self.bytes[self.count..][0..bytes.len], bytes);
        self.count += bytes.len;
    }
    fn commit(_: *anyopaque) !void {}
    fn abort(context: *anyopaque) void {
        const self: *MemorySink = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, self.bytes);
        self.count = 0;
    }
};
