//! Source-retaining local migration. No provider command runs here. An
//! authenticated manifest selects every ciphertext handle before the first
//! copy, and every restart verifies the source and any existing destination.
const std = @import("std");
const t = @import("types.zig");
const vt = @import("vault_types.zig");
const storage = @import("store.zig");
const records = @import("vault_storage.zig");
const stream = @import("vault_stream.zig");
const catalog = @import("vault_catalog.zig");
const journal = @import("vault_migration_journal.zig");
const identity = @import("vault_migration_identity.zig");
const Owner = @import("vault_owner.zig").Owner;
const WipingAllocator = @import("vault_allocator.zig").WipingAllocator;

/// Descriptor-only leases outlive each bounded parsed account snapshot.
pub const SourceLeases = struct {
    accounts: [3][]const u8 = @splat(""),
    leases: [3]?storage.MigrationLease = @splat(null),
    count: usize = 0,
    pub fn acquire(io: std.Io, a: std.mem.Allocator, metadata: identity.Metadata, options: t.Options, create_leases: bool) !SourceLeases {
        try requireNamespace(io, a, metadata.source, options);
        var result: SourceLeases = .{};
        errdefer result.close();
        for (metadata.config.accounts[0..metadata.config.count], 0..) |*configured, index| {
            result.accounts[index] = configured.address.slice();
            result.count += 1;
            result.leases[index] = try storage.MigrationLease.acquire(io, metadata.source.cache, configured.address.slice(), options, create_leases);
            if (result.leases[index] == null and !metadata.source.allow_empty_cache) return error.VaultMigrationAccountRequired;
        }
        return result;
    }
    pub fn close(self: *SourceLeases) void {
        for (self.leases[0..self.count]) |*lease| if (lease.*) |*value| value.close();
        self.count = 0;
    }
    fn open(self: *const SourceLeases, io: std.Io, a: std.mem.Allocator, account: []const u8, options: t.Options) !?storage.Store {
        for (self.accounts[0..self.count], 0..) |name, index| if (std.mem.eql(u8, name, account)) {
            if (self.leases[index]) |*lease| return try storage.Store.openMigrationLeased(io, a, lease, account, options);
            return null;
        };
        return error.VaultMigrationSourceChanged;
    }
};

pub const Inventory = struct {
    accounts: []const journal.Account,
    object_count: usize,
    plaintext_bytes: usize,
};
/// Caller owns the returned plan arena. Dry runs never fetch credentials and
/// ask the Store for existing leases only; actual migration may create leases.
pub fn inventory(io: std.Io, a: std.mem.Allocator, backing: std.mem.Allocator, metadata: identity.Metadata, options: t.Options, allow_create_leases: bool, leases: ?*const SourceLeases) !Inventory {
    try requireNamespace(io, backing, metadata.source, options);
    const accounts = try a.alloc(journal.Account, metadata.config.count);
    var total: usize = 0;
    var bytes: usize = 0;
    var wiping: WipingAllocator = .{ .backing = backing };
    for (metadata.config.accounts[0..metadata.config.count], accounts) |*configured, *output| {
        var temporary: std.heap.ArenaAllocator = .init(wiping.allocator());
        defer temporary.deinit();
        const scratch = temporary.allocator();
        var source = if (leases) |held| try held.open(io, scratch, configured.address.slice(), options) else try storage.Store.openMigration(io, scratch, metadata.source.cache, configured.address.slice(), options, allow_create_leases);
        defer if (source) |*value| value.close();
        if (source == null and !metadata.source.allow_empty_cache) return error.VaultMigrationAccountRequired;
        output.* = .{ .account = try a.dupe(u8, configured.address.slice()), .present = source != null, .state_sha256 = @splat(0), .target_state_sha256 = try journal.stateDigest(storage.State{ .account = configured.address.slice(), .metadataPolicy = options.metadata_limit, .diskPolicy = options.disk_limit, .decoderRevision = storage.decoder_revision }), .objects = &.{} };
        if (source) |*value| {
            output.state_sha256 = try journal.stateDigest(value.state);
            const objects = try value.migrationObjects(scratch);
            output.target_state_sha256 = try journal.stateDigest(try value.migrationTargetState(scratch));
            output.mail_count = value.state.entries.len;
            output.draft_count = value.state.drafts.len;
            for (value.state.sendQueue) |queued| if (queued.state == .queued) {
                output.queued_count += 1;
            };
            const copied = try a.alloc(journal.Object, objects.len);
            for (objects, copied) |object, *copied_object| {
                copied_object.* = .{ .name = try a.dupe(u8, object.name), .kind = object.kind, .size = object.size, .sha256 = object.sha256, .handle = object.handle, .mapped = object.mapped };
                bytes = try std.math.add(usize, bytes, object.size);
            }
            output.objects = copied;
            total = try std.math.add(usize, total, objects.len);
        }
    }
    return .{ .accounts = accounts, .object_count = total, .plaintext_bytes = bytes };
}

fn requireNamespace(io: std.Io, a: std.mem.Allocator, source: journal.Source, options: t.Options) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ source.cache, if (options.fixtures) "fixtures" else "live" });
    defer a.free(path);
    const directory = @import("../keyring_file.zig").directory(io, path, false) catch |err| {
        if (err == error.FileNotFound) {
            if (source.allow_empty_cache) return;
            return error.VaultMigrationCacheRequired;
        }
        return err;
    };
    directory.close(io);
}

/// Owner is local and migration-only. New destinations have their account set
/// and sealed identity created atomically; this function never overwrites a
/// populated vault without the matching authenticated migration manifest.
pub const CopyOptions = struct { fixture_stop_after: ?usize = null, leases: ?*const SourceLeases = null };
pub fn copy(owner: *Owner, a: std.mem.Allocator, metadata: identity.Metadata, captured: identity.Capture, options: CopyOptions) !void {
    if (options.fixture_stop_after != null and !owner.options.fixtures) return error.InvalidFixtureControl;
    if (!owner.migration_only or !owner.unlocked()) return error.VaultMigrationOwnerRequired;
    var owned_leases: ?SourceLeases = null;
    defer if (owned_leases) |*held| held.close();
    const leases = options.leases orelse blk: {
        owned_leases = try SourceLeases.acquire(owner.io, owner.allocator, metadata, owner.options, true);
        break :blk &owned_leases.?;
    };
    var log = try journal.Journal.open(owner.io, a, owner.path, &owner.key, &owner.workspace, owner.catalog_owner.?.root.handle, false);
    defer log.close();
    const manifest = log.readManifest(a) catch |err| if (err == error.FileNotFound) blk: {
        // Missing plan is only restartable while all initial indexes remain
        // empty. No orphaned/copy-created account object can be discarded.
        try requireEmpty(owner, a);
        try log.discardIncompletePlan();
        var journal_entries = log.directory.dir.iterate();
        while (try journal_entries.next(owner.io)) |entry| {
            if (entry.kind != .file or !std.mem.eql(u8, entry.name, ".vault-lock")) return error.VaultMigrationPlanRequired;
        }
        _ = try identityReady(owner, captured);
        var preparing: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
        defer preparing.deinit();
        const plan = try inventory(owner.io, preparing.allocator(), owner.allocator, metadata, owner.options, true, leases);
        const initial: journal.Manifest = .{ .vault_id = owner.key.vault_id, .source = metadata.source, .identity_sha256 = captured.digest, .accounts = plan.accounts };
        try log.createManifest(initial);
        break :blk try log.readManifest(a);
    } else return err;
    if (!std.mem.eql(u8, &manifest.identity_sha256, &captured.digest) or !sourceEqual(manifest.source, metadata.source)) return error.VaultMigrationSourceChanged;
    var progress = try log.readProgress(a, manifest);
    if (progress.verified) {
        var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
        defer temporary.deinit();
        const current = try inventory(owner.io, temporary.allocator(), owner.allocator, metadata, owner.options, true, leases);
        try sameAccounts(&log, temporary.allocator(), current.accounts, manifest.accounts);
        return verify(owner, a, &log, manifest, progress);
    }
    // The plan commits before identity publication. A restart can complete
    // exactly that captured snapshot, including a crash at this boundary.
    if (options.fixture_stop_after == 0) return error.VaultMigrationInterrupted;
    if (!try identityReady(owner, captured)) {
        try owner.identity.?.provider().apply(captured.changes);
        if (!try identityReady(owner, captured)) return error.InvalidVaultMigration;
    }
    var global_index: usize = 0;
    for (manifest.accounts, 0..) |planned, account_index| {
        // A published snapshot is parsed alone. Reopening a large source and
        // an already-published destination together doubles the bounded peak.
        if (try alreadyPublished(owner, planned)) {
            global_index += planned.objectCount();
            progress.next_object = @max(progress.next_object, global_index);
            progress.published_accounts |= @as(u8, 1) << @as(u3, @intCast(account_index));
            try log.saveProgress(progress, manifest);
            continue;
        }
        var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
        defer temporary.deinit();
        const scratch = temporary.allocator();
        var source = try leases.open(owner.io, scratch, planned.account, owner.options);
        defer if (source) |*value| value.close();
        if ((source != null) != planned.present) return error.VaultMigrationSourceChanged;
        if (source) |*value| {
            const current_digest = try journal.stateDigest(value.state);
            if (!std.mem.eql(u8, &current_digest, &planned.state_sha256)) return error.VaultMigrationSourceChanged;
            const current = try value.migrationObjects(scratch);
            try sameObjects(&log, scratch, current, planned);
            var target_options = value.options;
            target_options.disk_limit = (try value.migrationCapacity(current)).disk_limit;
            var destination = try storage.Store.openMigrationDestination(owner.io, scratch, &owner.catalog_owner.?, planned.account, target_options);
            defer destination.close();
            const page_count = std.math.divCeil(usize, planned.objectCount(), journal.objects_per_page) catch unreachable;
            for (0..page_count) |page_index| {
                var page_arena: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
                defer page_arena.deinit();
                for (try log.objectPage(page_arena.allocator(), planned, page_index)) |object| {
                    const descriptor = &current[try objectIndex(current, object.name)];
                    descriptor.handle = object.handle;
                    // Verification is unconditional even for checkpointed
                    // objects; only a complete verified account is published.
                    try destination.copyMigrationObject(value, descriptor);
                    global_index += 1;
                    if (global_index > progress.next_object) {
                        progress.next_object = global_index;
                        const stop = if (options.fixture_stop_after) |limit| global_index >= limit else false;
                        if (stop or global_index % 1024 == 0) try log.saveProgress(progress, manifest);
                        if (stop) return error.VaultMigrationInterrupted;
                    }
                }
            }
            try destination.publishMigrationSnapshot(value, current);
        }
        progress.published_accounts |= @as(u8, 1) << @as(u3, @intCast(account_index));
        try log.saveProgress(progress, manifest);
    }
    // The credentials/config and each source account are rechecked before the
    // verified checkpoint. Source changes never activate a mixed snapshot.
    {
        var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
        defer temporary.deinit();
        const fresh_meta = try identity.Metadata.load(owner.io, temporary.allocator(), owner.env, metadata.source);
        const fresh = try identity.capture(owner.io, temporary.allocator(), fresh_meta);
        if (!std.mem.eql(u8, &fresh.digest, &manifest.identity_sha256)) return error.VaultMigrationSourceChanged;
        const fresh_inventory = try inventory(owner.io, temporary.allocator(), owner.allocator, fresh_meta, owner.options, true, leases);
        try sameAccounts(&log, temporary.allocator(), fresh_inventory.accounts, manifest.accounts);
    }
    // Verify destination independently before publishing completion.
    progress.verified = true;
    try verify(owner, a, &log, manifest, progress);
    try log.saveProgress(progress, manifest);
}
fn alreadyPublished(owner: *Owner, planned: journal.Account) !bool {
    var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
    defer temporary.deinit();
    var destination = try storage.Store.openMigrationDestination(owner.io, temporary.allocator(), &owner.catalog_owner.?, planned.account, owner.options);
    defer destination.close();
    const actual = try journal.stateDigest(destination.state);
    if (std.mem.eql(u8, &actual, &planned.target_state_sha256) and destination.vaultObjects.len == planned.mappedCount()) return true;
    if (destination.vaultObjects.len != 0) return error.InvalidVaultMigration;
    return false;
}

/// Activation holds these read leases until its marker is durable. A removed
/// source requires explicit acknowledgement; changed available state never does.
pub const Freshness = struct {
    leases: SourceLeases = .{},
    unavailable: bool = false,
    pub fn close(self: *Freshness) void {
        self.leases.close();
    }
};
pub fn activationFreshness(owner: *Owner, manifest: journal.Manifest) !Freshness {
    var result: Freshness = .{};
    errdefer result.close();
    for (manifest.accounts, 0..) |planned, index| {
        result.leases.accounts[index] = planned.account;
        result.leases.count += 1;
        result.leases.leases[index] = try storage.MigrationLease.acquire(owner.io, manifest.source.cache, planned.account, owner.options, true);
        if (result.leases.leases[index]) |*lease| {
            if (!planned.present) return error.VaultMigrationSourceChanged;
            var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
            defer temporary.deinit();
            var source = try storage.Store.openMigrationLeased(owner.io, temporary.allocator(), lease, planned.account, owner.options);
            defer source.close();
            const current = try journal.stateDigest(source.state);
            if (!std.mem.eql(u8, &current, &planned.state_sha256)) return error.VaultMigrationSourceChanged;
        } else if (planned.present) result.unavailable = true;
    }
    return result;
}

/// The only unplanned identity accepted is the exact atomic bootstrap.
/// Never merge a changed capture with old client/token entries after a crash.
fn identityReady(owner: *Owner, captured: identity.Capture) !bool {
    const actual = try journal.digest(owner.identity.?.entries);
    if (std.mem.eql(u8, &actual, &captured.digest)) return true;
    if (captured.changes.len < 2 or captured.changes[0].kind != .configuration or captured.changes[0].value == null) return error.InvalidVaultMigration;
    const bootstrap = [_]@import("../native_identity.zig").Change{
        .{ .kind = .configuration, .value = captured.changes[0].value },
        .{ .kind = .grants, .value = "{\"version\":1,\"accounts\":[]}" },
    };
    const initial = try journal.digest(&bootstrap);
    if (!std.mem.eql(u8, &actual, &initial)) return error.VaultMigrationSourceChanged;
    return false;
}
fn sourceEqual(left: journal.Source, right: journal.Source) bool {
    return std.mem.eql(u8, left.config, right.config) and std.mem.eql(u8, left.grants, right.grants) and std.mem.eql(u8, left.cache, right.cache) and std.mem.eql(u8, left.preferences orelse "", right.preferences orelse "") and left.allow_empty_cache == right.allow_empty_cache and left.allow_missing_grants == right.allow_missing_grants and left.allow_missing_tokens == right.allow_missing_tokens;
}
fn objectIndex(current: anytype, name: []const u8) !usize {
    var low: usize = 0;
    var high = current.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, current[middle].name, name)) {
            .eq => return middle,
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return error.VaultMigrationSourceChanged;
}
fn sameObjects(log: *journal.Journal, a: std.mem.Allocator, current: anytype, planned: journal.Account) !void {
    if (current.len != planned.objectCount()) return error.VaultMigrationSourceChanged;
    const page_count = std.math.divCeil(usize, planned.objectCount(), journal.objects_per_page) catch unreachable;
    for (0..page_count) |index| {
        var phase: std.heap.ArenaAllocator = .init(a);
        defer phase.deinit();
        for (try log.objectPage(phase.allocator(), planned, index)) |expected| {
            const object = current[try objectIndex(current, expected.name)];
            if (object.kind != expected.kind or object.size != expected.size or object.mapped != expected.mapped or !std.mem.eql(u8, &object.sha256, &expected.sha256)) return error.VaultMigrationSourceChanged;
        }
    }
}
fn sameAccounts(log: *journal.Journal, a: std.mem.Allocator, current: []const journal.Account, planned: []const journal.Account) !void {
    if (current.len != planned.len) return error.VaultMigrationSourceChanged;
    for (current, planned) |actual, expected| {
        if (!std.mem.eql(u8, actual.account, expected.account) or actual.present != expected.present or !std.mem.eql(u8, &actual.state_sha256, &expected.state_sha256) or !std.mem.eql(u8, &actual.target_state_sha256, &expected.target_state_sha256)) return error.VaultMigrationSourceChanged;
        try sameObjects(log, a, actual.objects, expected);
    }
}
fn requireEmpty(owner: *Owner, a: std.mem.Allocator) !void {
    _ = a;
    for (owner.catalog_owner.?.entries[0..owner.catalog_owner.?.count]) |*entry| {
        var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
        defer temporary.deinit();
        var destination = try storage.Store.openMigrationDestination(owner.io, temporary.allocator(), &owner.catalog_owner.?, entry.address(), owner.options);
        defer destination.close();
        const initial = try journal.stateDigest(storage.State{ .account = entry.address(), .metadataPolicy = owner.options.metadata_limit, .diskPolicy = owner.options.disk_limit, .decoderRevision = storage.decoder_revision });
        const actual = try journal.stateDigest(destination.state);
        if (destination.vaultObjects.len != 0 or !std.mem.eql(u8, &initial, &actual)) return error.VaultMigrationPlanRequired;
        const index_name = entry.index.filename();
        var files = destination.dir.iterate();
        while (try files.next(owner.io)) |file| {
            if (file.kind != .file or (!std.mem.eql(u8, file.name, ".vault-lock") and !std.mem.eql(u8, file.name, &index_name))) return error.VaultMigrationPlanRequired;
        }
    }
}
/// Verify the authenticated destination independently of the source. Activation
/// additionally calls activationFreshness before publishing its marker.
pub fn verify(owner: *Owner, a: std.mem.Allocator, log: *journal.Journal, manifest: journal.Manifest, progress: journal.Progress) !void {
    if (!progress.verified or progress.next_object != manifest.objectCount() or manifest.accounts.len != owner.catalog_owner.?.count) return error.VaultMigrationIncomplete;
    const identity_digest = try journal.digest(owner.identity.?.entries);
    if (!std.mem.eql(u8, &identity_digest, &manifest.identity_sha256)) return error.InvalidVaultMigration;
    _ = a;
    for (manifest.accounts) |planned| {
        var temporary: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
        defer temporary.deinit();
        var destination = try storage.Store.openMigrationDestination(owner.io, temporary.allocator(), &owner.catalog_owner.?, planned.account, owner.options);
        defer destination.close();
        if (destination.vaultObjects.len != planned.mappedCount()) return error.InvalidVaultMigration;
        const state_digest = try journal.stateDigest(destination.state);
        if (!std.mem.eql(u8, &state_digest, &planned.target_state_sha256)) return error.InvalidVaultMigration;
        const account = destination.vault.?;
        var names: std.StringHashMap(usize) = .init(temporary.allocator());
        defer names.deinit();
        for (destination.vaultObjects, 0..) |mapped, index| {
            const result = try names.getOrPut(mapped.name);
            if (result.found_existing) return error.InvalidVaultMigration;
            result.value_ptr.* = index;
        }
        const page_count = std.math.divCeil(usize, planned.objectCount(), journal.objects_per_page) catch unreachable;
        for (0..page_count) |page_index| {
            var page_arena: std.heap.ArenaAllocator = .init(owner.private_allocator.allocator());
            defer page_arena.deinit();
            for (try log.objectPage(page_arena.allocator(), planned, page_index)) |object| {
                if (object.mapped and !@import("operation_history.zig").direct(object.name)) {
                    const mapped = destination.vaultObjects[names.get(object.name) orelse return error.InvalidVaultMigration];
                    if (mapped.kind != object.kind or !std.mem.eql(u8, mapped.handle, &object.handle.text())) return error.InvalidVaultMigration;
                } else if (object.kind == .attachment and !object.mapped) {
                    const blob = (try @import("operation_history.zig").findBlob(&destination, page_arena.allocator(), object.name[5..69])) orelse return error.InvalidVaultMigration;
                    if (blob.deleted or blob.size != object.size or !std.mem.eql(u8, blob.handle, &object.handle.text())) return error.InvalidVaultMigration;
                } else if (!std.mem.eql(u8, &(try @import("operation_history.zig").handleOf(object.name)).bytes, &object.handle.bytes)) return error.InvalidVaultMigration;
                var occupied: ?*anyopaque = null;
                var input = try stream.Reader.init(&account.directory, &owner.key, account.record(object.kind, object.handle), &owner.workspace.plaintext, &occupied);
                defer input.close();
                if (input.size != object.size) return error.InvalidVaultMigration;
                var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
                var buffer: [4096]u8 = undefined;
                defer std.crypto.secureZero(u8, &buffer);
                while (true) {
                    const count = try input.read(&buffer);
                    if (count == 0) break;
                    hash.update(buffer[0..count]);
                }
                var digest: [32]u8 = undefined;
                hash.final(&digest);
                if (!std.mem.eql(u8, &digest, &object.sha256)) return error.InvalidVaultMigration;
            }
        }
    }
}
