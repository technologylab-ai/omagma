//! One daemon owns the live data key, catalog, account descriptors and Core.
//! Keep Owner at a stable address until deinit. No secret is returned by execute.
const std = @import("std");
const t = @import("types.zig");
const vt = @import("vault_types.zig");
const crypto = @import("vault_crypto.zig");
const header = @import("vault_header.zig");
const catalog = @import("vault_catalog.zig");
const storage = @import("store.zig");
const core = @import("core.zig");

pub const Owner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    private_allocator: @import("vault_allocator.zig").WipingAllocator,
    env: *const std.process.Environ.Map,
    options: t.Options,
    path: []const u8,
    data_path: []const u8,
    key: vt.DataKey = undefined,
    workspace: vt.StreamWorkspace = undefined,
    catalog_owner: ?catalog.Owner = null,
    identity: ?@import("vault_identity.zig").State = null,
    accounts: [catalog.max_accounts]?catalog.Account = @splat(null),
    session: ?*core.Session = null,
    occupied: std.atomic.Value(bool) = .init(false),
    is_unlocked: std.atomic.Value(bool) = .init(false),
    locking: std.atomic.Value(bool) = .init(false),
    generation: u64 = 0,
    migration_only: bool = false,
    known_vault_id: ?vt.Id = null,

    pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8, options: t.Options) !Owner {
        return initMode(io, a, env, path, options, false);
    }
    pub fn initForMigration(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8, options: t.Options) !Owner {
        return initMode(io, a, env, path, options, true);
    }
    fn initMode(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8, options: t.Options, migration_only: bool) !Owner {
        const known_id = try peekId(io, path);
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        return .{ .io = io, .allocator = a, .private_allocator = .{ .backing = a }, .env = env, .options = options, .path = owned_path, .data_path = try std.fmt.allocPrint(a, "{s}/records", .{path}), .migration_only = migration_only, .known_vault_id = known_id };
    }
    fn peekId(io: std.Io, path: []const u8) !?vt.Id {
        var saved = header.Store.open(io, path, false) catch |err| if (err == error.FileNotFound) return null else return err;
        defer saved.close();
        const loaded = saved.load() catch |err| if (err == error.FileNotFound) return null else return err;
        return loaded.header.vault_id;
    }
    pub fn deinit(self: *Owner) void {
        std.debug.assert(!self.occupied.load(.acquire));
        self.clear();
        self.allocator.free(self.path);
        self.allocator.free(self.data_path);
        self.* = undefined;
    }
    fn claim(self: *Owner) !void {
        if (self.occupied.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.VaultBusy;
    }
    fn release(self: *Owner) void {
        self.occupied.store(false, .release);
    }
    pub fn unlocked(self: *const Owner) bool {
        return self.is_unlocked.load(.acquire);
    }
    fn clear(self: *Owner) void {
        self.is_unlocked.store(false, .release);
        if (self.session) |session| {
            session.deinit();
            std.crypto.secureZero(u8, std.mem.asBytes(session));
            self.allocator.destroy(session);
            self.session = null;
        }
        if (self.identity) |*identity| identity.deinit();
        self.identity = null;
        for (&self.accounts) |*account| {
            if (account.*) |*value| value.close();
            std.crypto.secureZero(u8, std.mem.asBytes(account));
            account.* = null;
        }
        if (self.catalog_owner) |*owner| owner.close();
        self.catalog_owner = null;
        self.key.wipe();
        self.workspace.wipe();
        self.generation +%= 1;
    }
    pub fn lock(self: *Owner) !void {
        if (self.locking.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.VaultBusy;
        defer self.locking.store(false, .release);
        try @import("../platform.zig").deadline(self.io, @import("../platform.zig").seconds(35), waitAndLock, .{self});
    }
    fn waitAndLock(self: *Owner) !void {
        while (self.occupied.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(10) }).sleep(self.io);
        }
        defer self.release();
        self.clear();
    }
    fn startSession(self: *Owner, create_accounts: bool, initial_config: ?*const @import("../config.zig").Config) !void {
        const session = try self.allocator.create(core.Session);
        errdefer self.allocator.destroy(session);
        const owner = &self.catalog_owner.?;
        if (create_accounts) {
            try session.initInto(self.io, self.private_allocator.allocator(), self.env, self.options, initial_config);
            errdefer session.deinit();
            var initial: [catalog.max_accounts]catalog.InitialAccount = undefined;
            var prepared: usize = 0;
            defer for (initial[0..prepared]) |entry| {
                std.crypto.secureZero(u8, @constCast(entry.initial_index));
                self.allocator.free(entry.initial_index);
            };
            for (session.config.accounts[0..session.config.count]) |*configured| {
                initial[prepared] = .{ .account = configured.address.slice(), .initial_index = try storage.Store.initialVaultIndex(self.allocator, configured.address.slice(), self.options), .disk_limit = self.options.disk_limit };
                prepared += 1;
            }
            session.config.credential_store = .vault;
            self.identity = try @import("vault_identity.zig").State.createWithAccounts(owner, self.allocator, &session.config, initial[0..prepared]);
            session.config.runtime_provider = self.identity.?.provider();
        } else {
            self.identity = try @import("vault_identity.zig").State.open(owner, self.allocator);
            // Config is large because it embeds the bar's fixed snapshots.
            // It and Session must never be returned by value on a 1 MiB worker.
            const config = try self.allocator.create(@import("../config.zig").Config);
            defer {
                std.crypto.secureZero(u8, std.mem.asBytes(config));
                self.allocator.destroy(config);
            }
            try self.identity.?.loadConfig(config);
            try session.initInto(self.io, self.private_allocator.allocator(), self.env, self.options, config);
        }
        session.vault_owner = self;
        self.session = session;
    }
    fn publishUnlocked(self: *Owner) void {
        self.is_unlocked.store(true, .release);
        self.generation +%= 1;
    }
    pub fn create(self: *Owner, password: []const u8, recovery: *const vt.RecoveryKey) !void {
        if (!self.options.fixtures or self.migration_only) return error.VaultUseMigration;
        return self.createInternal(password, recovery, null);
    }
    pub fn createConfigured(self: *Owner, password: []const u8, recovery: *const vt.RecoveryKey, config: *const @import("../config.zig").Config) !void {
        if (!self.migration_only or config.credential_store != .vault) return error.VaultMigrationOwnerRequired;
        return self.createInternal(password, recovery, config);
    }
    fn createInternal(self: *Owner, password: []const u8, recovery: *const vt.RecoveryKey, config: ?*const @import("../config.zig").Config) !void {
        try self.claim();
        defer self.release();
        if (self.unlocked()) return error.VaultAlreadyUnlocked;
        var saved = try header.Store.open(self.io, self.path, true);
        defer saved.close();
        try @import("vault_initialization.zig").begin(&saved.directory);
        self.key = try crypto.createDataKey(self.io);
        errdefer self.clear();
        var lease = try @import("vault_kdf_memory.zig").Lease.acquire(.production);
        defer lease.release();
        const descriptor: header.Header = .{
            .vault_id = self.key.vault_id,
            .key_id = self.key.key_id,
            .root_record = try @import("vault_storage.zig").Handle.create(self.io),
            .password = try crypto.wrapPassword(self.io, lease.bytes, password, &self.key),
            .recovery = try crypto.wrapRecovery(self.io, recovery, &self.key),
        };
        // Release the temporary 64 MiB mapping before mail initialization.
        lease.release();
        if (self.migration_only) {
            var migration = try @import("vault_migration_journal.zig").Journal.open(self.io, self.allocator, self.path, &self.key, &self.workspace, descriptor.root_record, true);
            migration.close();
        }
        self.catalog_owner = try catalog.Owner.create(self.io, self.data_path, descriptor, &self.key, &self.workspace);
        try self.startSession(true, config);
        try saved.create(descriptor, .{});
        self.known_vault_id = descriptor.vault_id;
        try @import("vault_initialization.zig").finish(&saved.directory);
        self.publishUnlocked();
    }
    pub fn unlock(self: *Owner, password: []const u8) !void {
        try self.claim();
        defer self.release();
        if (self.unlocked()) return error.VaultAlreadyUnlocked;
        var saved = try header.Store.open(self.io, self.path, false);
        defer saved.close();
        var lease = try @import("vault_kdf_memory.zig").Lease.acquire(.production);
        defer lease.release();
        var opened = try saved.unlockPassword(lease.bytes, password);
        defer opened.key.wipe();
        self.key = opened.key;
        errdefer self.clear();
        lease.release();
        self.catalog_owner = try catalog.Owner.open(self.io, self.data_path, opened.header, &self.key, &self.workspace);
        try self.startSession(false, null);
        try self.checkMigrationGate();
        try @import("vault_initialization.zig").finish(&saved.directory);
        self.publishUnlocked();
    }
    fn checkMigrationGate(self: *Owner) !void {
        if (self.migration_only) return;
        var arena: std.heap.ArenaAllocator = .init(self.private_allocator.allocator());
        defer arena.deinit();
        const a = arena.allocator();
        var migration = @import("vault_migration_journal.zig").Journal.open(self.io, a, self.path, &self.key, &self.workspace, self.catalog_owner.?.root.handle, false) catch |err| {
            if (err == error.FileNotFound and self.options.fixtures) return;
            return if (err == error.FileNotFound) error.VaultMigrationRequired else err;
        };
        defer migration.close();
        const manifest = migration.readManifest(a) catch |err| return if (err == error.FileNotFound) error.VaultMigrationIncomplete else err;
        const progress = try migration.readProgress(a, manifest);
        if (!progress.verified or manifest.accounts.len != self.catalog_owner.?.count) return error.VaultMigrationIncomplete;
        for (manifest.accounts) |planned| {
            var found = false;
            for (self.catalog_owner.?.entries[0..self.catalog_owner.?.count]) |*entry| if (std.mem.eql(u8, planned.account, entry.address())) {
                found = true;
                break;
            };
            if (!found) return error.VaultIdentityMismatch;
        }
        self.catalog_owner.?.live_enabled = true;
    }
    fn currentHeader(self: *Owner, saved: *header.Store) !header.Header {
        if (!self.unlocked()) return error.VaultLocked;
        const current = try saved.load();
        if (current.used_backup) return error.VaultHeaderRepairRequired;
        if (!std.mem.eql(u8, &current.header.vault_id, &self.key.vault_id) or !std.mem.eql(u8, &current.header.key_id, &self.key.key_id) or !std.mem.eql(u8, &current.header.root_record.bytes, &self.catalog_owner.?.root.handle.bytes)) return error.VaultIdentityMismatch;
        return current.header;
    }
    pub fn changePassword(self: *Owner, password: []const u8) !void {
        try self.claim();
        defer self.release();
        var saved = try header.Store.open(self.io, self.path, false);
        defer saved.close();
        var descriptor = try self.currentHeader(&saved);
        var lease = try @import("vault_kdf_memory.zig").Lease.acquire(.production);
        defer lease.release();
        descriptor.password = try crypto.wrapPassword(self.io, lease.bytes, password, &self.key);
        lease.release();
        saved.save(descriptor, .{}) catch |err| {
            self.clear();
            return err;
        };
    }
    pub fn changeRecovery(self: *Owner, recovery: *const vt.RecoveryKey) !void {
        try self.claim();
        defer self.release();
        var saved = try header.Store.open(self.io, self.path, false);
        defer saved.close();
        var descriptor = try self.currentHeader(&saved);
        descriptor.recovery = try crypto.wrapRecovery(self.io, recovery, &self.key);
        saved.save(descriptor, .{}) catch |err| {
            self.clear();
            return err;
        };
    }
    pub fn recover(self: *Owner, recovery: *const vt.RecoveryKey, new_password: []const u8) !void {
        try self.claim();
        defer self.release();
        if (self.unlocked()) return error.VaultAlreadyUnlocked;
        var saved = try header.Store.open(self.io, self.path, false);
        defer saved.close();
        var opened = try saved.unlockRecovery(recovery);
        defer opened.key.wipe();
        self.key = opened.key;
        errdefer self.clear();
        self.catalog_owner = try catalog.Owner.open(self.io, self.data_path, opened.header, &self.key, &self.workspace);
        try self.startSession(false, null); // Authenticate catalog and identity first.
        try self.checkMigrationGate();
        var lease = try @import("vault_kdf_memory.zig").Lease.acquire(.production);
        defer lease.release();
        opened.header.password = try crypto.wrapPassword(self.io, lease.bytes, new_password, &self.key);
        lease.release();
        try saved.save(opened.header, .{});
        self.publishUnlocked();
    }
    pub fn borrowAccount(self: *Owner, address: []const u8) !*catalog.Account {
        const owner = if (self.catalog_owner) |*value| value else return error.VaultLocked;
        for (&self.accounts) |*slot| if (slot.*) |*value| {
            if (std.mem.eql(u8, value.entry.address(), address)) return value;
        };
        for (&self.accounts) |*slot| if (slot.* == null) {
            slot.* = try owner.openAccount(address);
            return &slot.*.?;
        };
        return error.VaultAccountLimit;
    }
    pub fn openStore(self: *Owner, a: std.mem.Allocator, address: []const u8, readonly: bool) !storage.Store {
        return storage.Store.openVault(self.io, a, try self.borrowAccount(address), self.options, readonly);
    }
    pub fn cacheStamp(self: *Owner, address: []const u8) !?t.CacheStamp {
        const value = try self.borrowAccount(address);
        const stat = try value.directory.dir.statFile(self.io, &value.entry.index.filename(), .{ .follow_symlinks = false });
        return .{ .inode = @intCast(stat.inode), .size = stat.size, .mtime_ns = stat.mtime.toNanoseconds() };
    }
    pub fn execute(self: *Owner, out_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        return self.executeWithProgress(out_allocator, raw, null);
    }
    pub fn executeWithProgress(self: *Owner, out_allocator: std.mem.Allocator, raw: []const u8, sink: ?@import("types.zig").ProgressSink) ![]const u8 {
        try self.claim();
        defer self.release();
        if (self.migration_only) return error.VaultMigrationOwnerRequired;
        if (self.locking.load(.acquire)) return error.VaultLocked;
        const session = self.session orelse return error.VaultLocked;
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = try @import("vault_transport.zig").requestMetadata(fixed.allocator(), raw);
        if (meta.secret_field) return error.VaultSecretRequiresPrompt;
        if (meta.vault_id.len != 0 and !std.mem.eql(u8, meta.vault_id, &std.fmt.bytesToHex(self.key.vault_id, .lower))) return error.VaultIdentityMismatch;
        // Disabling an account or changing a capability must affect the next
        // request without a daemon restart. Grants/tokens are read through the
        // same current provider; no plaintext mtime substitutes for identity.
        try self.identity.?.loadConfig(&session.config);
        return if (sink) |target| session.executeWithProgress(out_allocator, raw, target) else session.execute(out_allocator, raw);
    }
};
