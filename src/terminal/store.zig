const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const draft_summary = @import("draft_summary.zig");
const mail_limits = @import("mail_limits.zig");
const vault_catalog = @import("vault_catalog.zig");
const vault_storage = @import("vault_storage.zig");
const vault_types = @import("vault_types.zig");
const VaultObject = struct { name: []const u8, kind: vault_types.RecordKind, handle: []const u8 };
const VaultIndex = struct { schema: u8 = 1, state: State, objects: []VaultObject = &.{} };
// Blob identity metadata scales independently of the 128 editable drafts.
// Actual retained file bytes remain governed by the account disk quota.
pub const blob_limit = 4096;
pub const vault_object_limit = t.Limits.metadata_hard + 2 * 128 + blob_limit + 16;
pub const mail_record_bytes = @import("send_memory.zig").record_bytes;
pub const MigrationObject = @import("store_migration.zig").Object;
fn vaultKind(name: []const u8) !vault_types.RecordKind {
    if (@import("operation_history.zig").direct(name)) {
        _ = try @import("operation_history.zig").handleOf(name);
        return if (std.mem.startsWith(u8, name, "history-draft-") or std.mem.startsWith(u8, name, "history-active-")) .draft else .operation_ledger;
    }
    if (std.mem.eql(u8, name, "follow-ups.json") or std.mem.eql(u8, name, "fixture-gmail-drafts.json")) return .preferences;
    if (std.mem.eql(u8, name, "calendar-state.json") or std.mem.eql(u8, name, "calendar-provider-fixture.json") or std.mem.eql(u8, name, "drive-uploads.json")) return .operation_ledger;
    if (std.mem.eql(u8, name, "calendar-agenda.json")) return .cache_index;
    const kind: vault_types.RecordKind = if (std.mem.startsWith(u8, name, "mail-")) .mail_body else if (std.mem.startsWith(u8, name, "draft-")) .draft else if (std.mem.startsWith(u8, name, "outbox-")) .outbox else if (std.mem.startsWith(u8, name, "blob-")) .attachment else return error.VaultOperationUnsupported;
    const prefix: usize = switch (kind) {
        .mail_body, .attachment => 5,
        .outbox => 7,
        else => 6,
    };
    const suffix: []const u8 = if (kind == .attachment) ".bin" else ".json";
    if (name.len != prefix + 64 + suffix.len or !std.mem.endsWith(u8, name, suffix)) return error.InvalidVaultObject;
    _ = try vault_storage.Handle.parse(name[prefix..][0..64]);
    return kind;
}
pub const index_read_bytes = 16 * 1024 * 1024;
pub const index_write_bytes = 8 * 1024 * 1024;
/// The plaintext cap excludes the sealed object map. Leave a separate bounded
/// allowance for that map, still below the authenticated index read ceiling.
pub const vault_index_write_bytes = 12 * 1024 * 1024;
pub const MigrationCapacity = struct {
    index_bytes: usize,
    sealed_bytes: usize,
    required_disk_bytes: usize,
    disk_limit: usize,
};
/// Revision 1 retains named zero-byte files in successful decoded bodies.
/// This is separate from retrying historical decoder refusals.
pub const body_decoder_revision: u32 = 1;
pub const Entry = struct {
    message: t.Message,
    bytes: usize = 0,
    bodyHash: []const u8 = "",
    bodyError: []const u8 = "",
    bodyDecoderRevision: u32 = 0,
    /// Null means a legacy body's references have not been inspected yet.
    /// These references belong to bodyHash, not the latest metadata tokens.
    bodyBlobIds: ?[]const []const u8 = null,
};
pub const DraftBlobReferences = struct { draftId: []const u8, blobs: []const []const u8 = &.{}, handle: []const u8 = "" };
const attachmentMetadata = draft_summary.attachmentMetadata;
// Address count alone allows tens of KiB per broad inbound header. Bound the
// compact To/Cc index independently; immutable full messages retain all data.
const participant_bytes = 4096;
fn participantPrefix(values: []const t.Address, remaining: *usize) []const t.Address {
    var count: usize = 0;
    for (values[0..@min(values.len, t.Limits.recipients)]) |address| {
        const bytes = address.address.len +| address.name.len;
        if (bytes > remaining.*) break;
        remaining.* -= bytes;
        count += 1;
    }
    return values[0..count];
}
const BodyRecord = struct { schema: u8 = 1, account: []const u8, message: t.Message };
fn readPrivate(dir: std.Io.Dir, io: std.Io, a: std.mem.Allocator, name: []const u8, limit: usize) ![]const u8 {
    const before = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (before.kind != .file or before.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
    if (before.size > limit) return error.CacheLimitExceeded;
    const file = try dir.openFile(io, name, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind != .file or st.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
    if (st.size > limit) return error.CacheLimitExceeded;
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(a, .limited(limit));
}
fn openPrivateLock(dir: std.Io.Dir, io: std.Io) !std.Io.File {
    const lock = dir.createFile(io, "lock", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| if (err == error.PathAlreadyExists) existing: {
        const before = try dir.statFile(io, "lock", .{ .follow_symlinks = false });
        if (before.kind != .file or before.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
        break :existing try dir.openFile(io, "lock", .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false });
    } else return err;
    errdefer lock.close(io);
    const stat = try lock.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
    return lock;
}
fn scratchName(name: []const u8) bool {
    const prefix: []const u8 = if (std.mem.startsWith(u8, name, "send-spool-")) "send-spool-" else if (std.mem.startsWith(u8, name, "download-spool-")) "download-spool-" else return false;
    const suffix: []const u8 = if (std.mem.eql(u8, prefix, "send-spool-")) ".mime" else ".bin";
    if (name.len != prefix.len + 32 + suffix.len or !std.mem.endsWith(u8, name, suffix)) return false;
    for (name[prefix.len..][0..32]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn cleanupScratch(dir: std.Io.Dir, io: std.Io, a: std.mem.Allocator) !void {
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| if (scratchName(entry.name)) {
        const file = try @import("../native_file.zig").openAt(io, dir, try a.dupeSentinel(u8, entry.name, 0), .{ .read_write = true });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
        if (try file.tryLock(io, .exclusive)) {
            defer file.unlock(io);
            try dir.deleteFile(io, entry.name);
        }
    };
}
fn openAccountDirectory(io: std.Io, root: []const u8, account: []const u8, options: t.Options, create: bool) !std.Io.Dir {
    if (create) _ = try std.Io.Dir.cwd().createDirPathStatus(io, root, .fromMode(0o700));
    var base = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
    defer base.close(io);
    if ((try base.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureCacheDirectory;
    const namespace = if (options.fixtures) "fixtures" else "live";
    if (create) _ = try base.createDirPathStatus(io, namespace, .fromMode(0o700));
    var backend = try base.openDir(io, namespace, .{ .iterate = true, .follow_symlinks = false });
    defer backend.close(io);
    if ((try backend.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureCacheDirectory;
    const key = Store.hash(account);
    if (create) _ = try backend.createDirPathStatus(io, &key, .fromMode(0o700));
    const dir = try backend.openDir(io, &key, .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureCacheDirectory;
    return dir;
}
/// Nonblocking and NOFOLLOW even if a path is swapped between stat and open.
/// Raw Linux errno decoding is required for static-musl raw syscall results.
fn openRefreshFile(dir: std.Io.Dir, io: std.Io, create: bool) !std.Io.File {
    const before = dir.statFile(io, "refresh.lock", .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound and create) null else return err;
    if (before) |stat| if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0 or stat.size != 0) return error.InsecureRefreshLease;
    const file = @import("../native_file.zig").openAt(io, dir, "refresh.lock", .{ .read_write = true, .create = create, .mode = 0o600 }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.Canceled => return err,
        error.SymbolicLinkNotAllowed, error.IsDir => return error.InsecureRefreshLease,
        else => return error.RefreshLeaseOpenFailed,
    };
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0 or stat.size != 0) return error.InsecureRefreshLease;
    return file;
}
pub const RefreshLease = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    closed: bool = false,
    pub fn acquire(io: std.Io, root: []const u8, account: []const u8, options: t.Options) !?RefreshLease {
        const dir = try openAccountDirectory(io, root, account, options, true);
        errdefer dir.close(io);
        const file = try openRefreshFile(dir, io, true);
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) {
            file.close(io);
            dir.close(io);
            return null;
        }
        return .{ .io = io, .dir = dir, .file = file };
    }
    pub fn release(self: *RefreshLease) void {
        if (self.closed) return;
        self.closed = true;
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.dir.close(self.io);
    }
};

/// A migration retains only these descriptors across account-sized arenas.
/// Shared cache access permits readers; the exclusive refresh lease prevents
/// a provider operation from starting while the exact source snapshot is held.
pub const MigrationLease = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock: std.Io.File,
    refresh: ?std.Io.File,
    account_hash: [64]u8,
    fixtures: bool,
    closed: bool = false,

    pub fn acquire(io: std.Io, root: []const u8, account: []const u8, options: t.Options, allow_create_leases: bool) !?MigrationLease {
        const account_hash = Store.hash(account);
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}/{s}", .{ root, if (options.fixtures) @as([]const u8, "fixtures") else "live", account_hash });
        const dir = @import("../keyring_file.zig").directory(io, path, false) catch |err| if (err == error.FileNotFound) return null else return err;
        errdefer dir.close(io);
        const index = vault_storage.openPrivate(io, dir, "index.json") catch |err| {
            if (err != error.FileNotFound) return err;
            var iterator = dir.iterate();
            while (try iterator.next(io)) |entry| {
                if (!std.mem.eql(u8, entry.name, "lock") and !std.mem.eql(u8, entry.name, "refresh.lock")) return error.MigrationIndexMissing;
            }
            dir.close(io);
            return null;
        };
        index.close(io);
        const refresh = openRefreshFile(dir, io, allow_create_leases) catch |err| if (err == error.FileNotFound and !allow_create_leases) null else return err;
        errdefer if (refresh) |file| file.close(io);
        if (refresh) |file| {
            try @import("../keyring_file.zig").privateFile(io, file);
            if (!try file.tryLock(io, .exclusive)) return error.CacheBusy;
        }
        errdefer if (refresh) |file| file.unlock(io);
        const lock = if (allow_create_leases) try openPrivateLock(dir, io) else vault_storage.openPrivate(io, dir, "lock") catch |err| if (err == error.FileNotFound) return error.MigrationLeaseRequired else return err;
        errdefer lock.close(io);
        try @import("../keyring_file.zig").privateFile(io, lock);
        if ((try lock.stat(io)).size != 0) return error.MigrationSourceInvalid;
        if (!try lock.tryLock(io, .shared)) return error.CacheBusy;
        return .{ .io = io, .dir = dir, .lock = lock, .refresh = refresh, .account_hash = account_hash, .fixtures = options.fixtures };
    }

    pub fn close(self: *MigrationLease) void {
        if (self.closed) return;
        self.closed = true;
        self.lock.unlock(self.io);
        self.lock.close(self.io);
        if (self.refresh) |file| {
            file.unlock(self.io);
            file.close(self.io);
        }
        self.dir.close(self.io);
    }
};
pub fn refreshActive(io: std.Io, root: []const u8, account: []const u8, options: t.Options) !bool {
    const dir = openAccountDirectory(io, root, account, options, false) catch |err| if (err == error.FileNotFound) return false else return err;
    defer dir.close(io);
    const file = openRefreshFile(dir, io, false) catch |err| if (err == error.FileNotFound) return false else return err;
    defer file.close(io);
    if (try file.tryLock(io, .shared)) {
        file.unlock(io);
        return false;
    }
    return true;
}

/// Observe atomic index replacement without parsing it, allocating or waiting
/// for a store/refresh lock. Missing caches are not created by a watch probe.
pub fn cacheStamp(io: std.Io, root: []const u8, account: []const u8, options: t.Options) !?t.CacheStamp {
    const dir = openAccountDirectory(io, root, account, options, false) catch |err| if (err == error.FileNotFound) return null else return err;
    defer dir.close(io);
    const stat = dir.statFile(io, "index.json", .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return null else return err;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
    if (stat.size >= index_read_bytes) return error.CacheLimitExceeded;
    return .{ .inode = @intCast(stat.inode), .size = stat.size, .mtime_ns = stat.mtime.toNanoseconds() };
}

pub const Operation = struct { id: []const u8, hash: []const u8, outcome: []const u8 = "unknown", messageId: []const u8 = "", rfcMessageId: []const u8 = "", draftId: []const u8 = "", errorCode: []const u8 = "", icalendar: []const u8 = "", sourceInvitationHash: []const u8 = "", invitationCalendarId: []const u8 = "", calendarSync: ?@import("calendar_rsvp.zig").Result = null, driveFiles: ?[]const t.DriveFileReceipt = null, kind: []const u8 = "", label: ?Label = null, labelId: []const u8 = "", deleted: bool = false };
pub const View = struct { key: []const u8, query: []const u8, label: []const u8, labelId: []const u8 = "", ids: []const []const u8 = &.{}, remoteCursor: []const u8 = "", stale: bool = false, lastSyncAt: i64 = 0, lastSyncStartedAt: i64 = 0, incomplete: bool = false };
pub const QuotaFloor = struct { receivedAt: i64, id: []const u8 };
pub const FixtureProviderRecord = struct { id: []const u8, labels: []const []const u8 = &.{}, deleted: bool = false, sourceHistoryId: []const u8 = "1" };
pub const Label = struct { id: []const u8, name: []const u8, type: []const u8 = "user", color: ?t.LabelColor = null };
pub const Identity = struct { address: []const u8, name: []const u8 = "", signature: []const u8 = "", isDefault: bool = false };
/// Undo records only labels changed by this action. Other concurrent labels
/// survive undo. An unconfirmed mutation is never replayed automatically.
pub const UndoItem = struct { messageId: []const u8, addLabels: []const []const u8 = &.{}, removeLabels: []const []const u8 = &.{}, outcome: []const u8 = "pending", errorCode: []const u8 = "", restored: bool = false };
pub const Undo = struct { token: []const u8, items: []UndoItem = &.{} };
pub const SendState = enum { queued, canceled, preparing, submitting, applied, rejected, unknown };
pub const QueuedSend = struct {
    queueId: []const u8,
    draftId: []const u8,
    operationId: []const u8,
    hash: []const u8,
    state: SendState = .queued,
    /// Migrated queued sends require a fresh explicit resume/send decision.
    resumeRequired: bool = false,
    preparationId: ?[]const u8 = null,
    createdAtMs: i64,
    dueAtMs: i64,
    errorCode: []const u8 = "",
};
/// Shared native/browser decoder revision and retry eligibility.
pub const decoder_revision = @import("decoder_policy.zig").decoder_revision;
const retriedByNewerDecoder = @import("decoder_policy.zig").retriedByNewerDecoder;

pub const DriveSource = struct { operationId: []const u8, hash: []const u8, draftId: []const u8 = "" };
pub const State = struct {
    schema: u8 = 1,
    history: @import("operation_history.zig").Root = .{},
    account: []const u8,
    generation: u64 = 1,
    serial: u64 = 0,
    entries: []Entry = &.{},
    /// Verified FULL-read descriptors survive index eviction and token rotation
    /// without adding mail to any folder or retaining its body bytes.
    attachmentReceipts: []const @import("attachment_receipts.zig").Receipt = &.{},
    drafts: []t.Draft = &.{},
    draftLinks: []@import("draft_link.zig").Link = &.{},
    driveSources: []DriveSource = &.{},
    relatedDraftBlobs: []const DraftBlobReferences = &.{},
    outbox: []t.Message = &.{},
    contacts: []t.Contact = &.{},
    contactsReady: bool = false,
    contactWarnings: t.ContactReadWarnings = .{},
    labels: []Label = &.{},
    /// Fixtures own one persistent provider collection after their first write.
    /// Baseline source files must not resurrect renamed or deleted labels.
    fixtureLabelsReady: bool = false,
    fixtureDeletedLabels: []const []const u8 = &.{},
    identities: []Identity = &.{},
    undo: []Undo = &.{},
    operations: []Operation = &.{},
    sendQueue: []QueuedSend = &.{},
    fixtureCalls: u64 = 0,
    fixtureSends: u64 = 0,
    fixtureProvider: []FixtureProviderRecord = &.{},
    historyId: []const u8 = "",
    lastSyncAt: i64 = 0,
    /// Cumulative incoming Inbox additions at successful history checkpoints.
    /// Default zero keeps old schema-1 indexes readable; cache.clear preserves it.
    inboxArrivalCount: u64 = 0,
    /// Decoder revision that recorded the stored body refusals. Zero for old
    /// schema-1 indexes; see `decoder_revision`.
    decoderRevision: u32 = 0,
    quotaFloor: ?QuotaFloor = null,
    indexQuotaFloor: ?QuotaFloor = null,
    quotaDiskLimit: usize = 0,
    metadataPolicy: usize = 0,
    diskPolicy: usize = 0,
    views: []View = &.{},
    syncCalls: u64 = 0,
    syncMetadataGets: u64 = 0,
    syncListCalls: u64 = 0,
    syncHistoryPages: u64 = 0,
    syncBodyGets: u64 = 0,
};

pub const Store = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock: std.Io.File,
    allocator: std.mem.Allocator,
    state: State,
    options: t.Options,
    lockHeld: bool = true,
    closed: bool = false,
    entriesStorage: []Entry = &.{},
    vault: ?*vault_catalog.Account = null,
    vaultObjects: []VaultObject = &.{},
    vaultRetired: std.ArrayList(vault_storage.Handle) = .empty,
    vaultFailed: bool = false,
    migration_source: bool = false,
    migration_inventory: ?[]const MigrationObject = null,
    migration_destination: bool = false,
    migration_refresh: ?std.Io.File = null,
    migration_lease: ?*const MigrationLease = null,
    /// Exact charged ciphertext while this migration owns its account lease.
    /// Ordinary Stores continue to scan because other write adapters exist.
    migration_disk_bytes: ?usize = null,
    disk_scan_count: usize = 0,
    owns_vault: bool = false,
    /// Synthetic publication faults never affect ordinary stores.
    history_fault: enum { none, before_publication, uncertain_publication, after_publication, after_cleanup } = .none,
    history_protected_draft: []const u8 = "",
    history_staged: std.ArrayList([]const u8) = .empty,
    history_publication_started: bool = false,
    history_publication_committed: bool = false,
    history_publication_uncertain: bool = false,
    /// The daemon keeps Account, key and workspace alive. This first bridge is
    /// fixture-only until Core routing, sealed attachments and migration land.
    pub fn openVault(io: std.Io, a: std.mem.Allocator, account: *vault_catalog.Account, options: t.Options, readonly: bool) !Store {
        if (!options.fixtures and !account.owner.live_enabled) return error.VaultIntegrationNotReady;
        try account.claim();
        errdefer account.release();
        return openCommon(io, a, "", account.entry.address(), options, readonly, account, null, false, null);
    }
    pub fn createVaultAccount(owner: *vault_catalog.Owner, a: std.mem.Allocator, account: []const u8, options: t.Options) !void {
        if (!options.fixtures) return error.VaultIntegrationNotReady;
        if (options.metadata_limit == 0 or options.metadata_limit > t.Limits.metadata_hard or options.disk_limit < 64 * 1024 or options.disk_limit > t.Limits.disk_hard) return error.CacheLimitExceeded;
        const bytes = try initialVaultIndex(a, account, options);
        defer {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        try owner.addAccount(account, bytes, options.disk_limit);
    }
    /// Prepare initial indexes for one atomic catalog + identity onboarding.
    pub fn initialVaultIndex(a: std.mem.Allocator, account: []const u8, options: t.Options) ![]u8 {
        if (options.metadata_limit == 0 or options.metadata_limit > t.Limits.metadata_hard or options.disk_limit < 64 * 1024 or options.disk_limit > t.Limits.disk_hard) return error.CacheLimitExceeded;
        const value: VaultIndex = .{ .state = .{ .account = account, .metadataPolicy = options.metadata_limit, .diskPolicy = options.disk_limit, .decoderRevision = decoder_revision } };
        return j.encodeAlloc(a, value, .{});
    }
    /// A migration inventory never creates missing data/cache directories,
    /// changes State, cleans scratch files or enforces a different policy.
    pub fn openMigration(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, allow_create_leases: bool) !?Store {
        return openCommon(io, a, root, account, options, true, null, allow_create_leases, true, null) catch |err| if (err == error.FileNotFound) null else err;
    }
    /// Borrow a pinned source without reacquiring its exclusive refresh lock.
    /// The caller must keep the lease alive after closing this parsed Store.
    pub fn openMigrationLeased(io: std.Io, a: std.mem.Allocator, lease: *const MigrationLease, account: []const u8, options: t.Options) !Store {
        if (lease.closed or lease.fixtures != options.fixtures or !std.mem.eql(u8, &lease.account_hash, &hash(account))) return error.MigrationSourceRequired;
        return openCommon(io, a, "", account, options, true, null, false, true, lease);
    }
    /// Internal local-migration entry point; normal openVault activation guards
    /// remain unchanged. Accounts must already exist in an atomic identity.
    pub fn openMigrationDestination(io: std.Io, a: std.mem.Allocator, owner: *vault_catalog.Owner, account: []const u8, options: t.Options) !Store {
        if (owner.identity == null) return error.VaultIdentityRequired;
        const selected = try a.create(vault_catalog.Account);
        errdefer a.destroy(selected);
        selected.* = try owner.openAccount(account);
        errdefer selected.close();
        try selected.claim();
        errdefer selected.release();
        var result = try openCommon(io, a, "", account, options, true, selected, null, true, null);
        // The coordinator passes the validated source policy; the empty
        // bootstrap index must not narrow an existing source account quota.
        result.options.metadata_limit = options.metadata_limit;
        result.options.disk_limit = options.disk_limit;
        result.owns_vault = true;
        result.migration_destination = true;
        result.migration_disk_bytes = try result.diskBytes();
        return result;
    }
    pub fn migrationTargetState(s: *const Store, a: std.mem.Allocator) !State {
        try s.migrationSourceReady();
        const capacity = try s.migrationCapacity(s.migration_inventory orelse return error.MigrationInventoryRequired);
        var state = s.state;
        if (capacity.disk_limit > s.options.disk_limit) state.diskPolicy = capacity.disk_limit;
        state.sendQueue = try a.dupe(QueuedSend, s.state.sendQueue);
        for (state.sendQueue) |*queued| if (queued.state == .queued) {
            queued.resumeRequired = true;
        };
        return state;
    }
    pub fn migrationSourceReady(s: *const Store) !void {
        if (!s.migration_source or s.closed or !s.lockHeld or (s.migration_lease != null and s.migration_lease.?.closed)) return error.MigrationSourceRequired;
    }
    /// Exact count-only admission: no serialized index or second object map is
    /// allocated. Two indexes cover the full initial and resumed replacement.
    pub fn migrationCapacity(s: *const Store, objects: []const MigrationObject) !MigrationCapacity {
        try s.migrationSourceReady();
        const count = @import("gmail_decode.zig").serializedBytes;
        var base = count(VaultIndex{ .state = s.state });
        for (s.state.sendQueue) |queued| if (queued.state == .queued and !queued.resumeRequired) {
            base -= 1; // false -> true
        };
        var object_bytes: usize = 0;
        var mapped_count: usize = 0;
        for (objects) |object| {
            const text = object.handle.text();
            if (object.mapped and !@import("operation_history.zig").direct(object.name)) {
                base = try std.math.add(usize, base, count(VaultObject{ .name = object.name, .kind = object.kind, .handle = &text }) + @intFromBool(mapped_count != 0));
                mapped_count += 1;
            }
            object_bytes = try std.math.add(usize, object_bytes, try vault_types.sealedStreamSize(object.size));
        }
        var policy = s.state.diskPolicy;
        while (true) {
            const index_bytes = base - count(s.state.diskPolicy) + count(policy);
            if (index_bytes >= vault_index_write_bytes) return error.MigrationIndexTooLarge;
            const sealed_index = try vault_types.sealedSize(index_bytes);
            const overlap = try std.math.mul(usize, 2, try vault_types.sealedSize(@max(index_bytes, 4096)));
            const required = try std.math.add(usize, object_bytes, overlap);
            if (required > t.Limits.disk_hard) return error.MigrationDiskQuotaExceeded;
            const limit = @max(s.options.disk_limit, required);
            if (limit > s.options.disk_limit and policy != limit) {
                policy = limit;
                continue;
            }
            return .{ .index_bytes = index_bytes, .sealed_bytes = try std.math.add(usize, object_bytes, sealed_index), .required_disk_bytes = required, .disk_limit = limit };
        }
    }
    pub fn migrationObjects(s: *Store, a: std.mem.Allocator) ![]MigrationObject {
        return @import("store_migration.zig").inventory(s, a);
    }
    pub fn migrationRecordKind(name: []const u8) !vault_types.RecordKind {
        return vaultKind(name);
    }
    pub fn migrationRecordLimit(s: *const Store, name: []const u8) !usize {
        if (std.mem.startsWith(u8, name, "history-calendar-")) return 256 * 1024;
        return switch (try vaultKind(name)) {
            .mail_body, .draft, .outbox => mail_record_bytes,
            .attachment => t.Limits.disk_hard,
            .operation_ledger, .cache_index, .preferences => s.documentLimit(name),
            else => error.MigrationSourceInvalid,
        };
    }
    pub fn copyMigrationObject(s: *Store, source: *Store, object: *const MigrationObject) !void {
        return @import("store_migration.zig").copy(s, source, object);
    }
    pub fn publishMigrationSnapshot(s: *Store, source: *const Store, objects: []const MigrationObject) !void {
        const account = try s.vaultReady();
        try account.requireSharedWorkspace();
        try source.migrationSourceReady();
        if (!s.migration_destination or !source.migration_source or source.closed or !source.lockHeld or !std.mem.eql(u8, s.state.account, source.state.account)) return error.MigrationSourceRequired;
        try @import("store_migration.zig").validatePlan(source, objects);
        if (migrationMappedCount(objects) > vault_object_limit or source.state.entries.len > s.options.metadata_limit) return error.CacheLimitExceeded;
        var names: std.StringHashMap(usize) = .init(s.allocator);
        defer names.deinit();
        var handles: std.AutoHashMap([32]u8, void) = .init(s.allocator);
        defer handles.deinit();
        const map = try s.allocator.alloc(VaultObject, migrationMappedCount(objects));
        var mapped_count: usize = 0;
        var blobs: usize = 0;
        for (objects, 0..) |*object, index| {
            const named = try names.getOrPut(object.name);
            if (named.found_existing or (try handles.getOrPut(object.handle.bytes)).found_existing) return error.MigrationSourceInvalid;
            named.value_ptr.* = std.math.maxInt(usize);
            _ = index;
            if (object.kind == .attachment and object.mapped) blobs += 1;
            if (blobs > blob_limit) return error.AttachmentLimitExceeded;
            try @import("store_migration.zig").verifyCiphertext(s, object);
            if (!object.mapped or @import("operation_history.zig").direct(object.name)) continue;
            named.value_ptr.* = mapped_count;
            map[mapped_count] = .{ .name = try s.allocator.dupe(u8, object.name), .kind = object.kind, .handle = try s.allocator.dupe(u8, &object.handle.text()) };
            mapped_count += 1;
        }
        // An existing published map must be this exact planned map. Resume
        // never retires unrelated ciphertext or replaces a different snapshot.
        for (s.vaultObjects) |existing| {
            const mapped_index = names.get(existing.name) orelse return error.MigrationSourceChanged;
            if (mapped_index >= map.len) return error.MigrationSourceChanged;
            const object = map[mapped_index];
            if (existing.kind != object.kind or !std.mem.eql(u8, existing.handle, object.handle)) return error.MigrationSourceChanged;
        }
        const target = try source.migrationTargetState(s.allocator);
        const value: VaultIndex = .{ .state = target, .objects = map };
        const size_bytes = @import("gmail_decode.zig").serializedBytes(value);
        if (size_bytes >= vault_index_write_bytes) return error.MigrationIndexTooLarge;
        const sealed_bytes = try vault_types.sealedSize(size_bytes);
        try s.reserveVaultCiphertext(sealed_bytes);
        const previous_bytes: usize = @intCast((try account.directory.dir.statFile(s.io, &account.entry.index.filename(), .{ .follow_symlinks = false })).size);
        var output: @import("vault_stream.zig").Writer = undefined;
        try output.init(&account.directory, account.owner.key, account.record(.cache_index, account.entry.index), size_bytes, account.owner.workspace, true, .{});
        defer output.deinit();
        std.json.Stringify.value(value, .{}, &output.interface) catch |err| return output.failure orelse err;
        output.finish() catch |err| {
            if (err == error.VaultDurabilityUncertain) account.owner.uncertain = true;
            return err;
        };
        try s.accountMigrationCiphertext(sealed_bytes, previous_bytes);
        s.state = target;
        s.entriesStorage = target.entries;
        s.vaultObjects = map;
    }
    pub fn requirePlainFiles(s: *const Store) !void {
        if (s.vault != null) return error.VaultOperationUnsupported;
    }
    pub fn migrationMappedCount(objects: []const MigrationObject) usize {
        var count: usize = 0;
        for (objects) |object| if (object.mapped and !@import("operation_history.zig").direct(object.name)) {
            count += 1;
        };
        return count;
    }
    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options) !Store {
        return openMode(io, a, root, account, options, false);
    }
    pub fn openCached(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options) !Store {
        return openMode(io, a, root, account, options, true);
    }
    fn openMode(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, readonly: bool) !Store {
        return openCommon(io, a, root, account, options, readonly, null, null, false, null);
    }
    fn openCommon(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, readonly: bool, sealed: ?*vault_catalog.Account, migration: ?bool, preserve_order: bool, borrowed: ?*const MigrationLease) !Store {
        const dir = if (borrowed) |lease| lease.dir else if (sealed) |vault| vault.directory.dir else if (migration != null)
            try @import("../keyring_file.zig").directory(io, try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ root, if (options.fixtures) @as([]const u8, "fixtures") else "live", hash(account) }), false)
        else
            try openAccountDirectory(io, root, account, options, true);
        errdefer if (sealed == null and borrowed == null) dir.close(io);
        if (migration != null) {
            const index = vault_storage.openPrivate(io, dir, "index.json") catch |err| {
                if (err != error.FileNotFound) return err;
                var iterator = dir.iterate();
                while (try iterator.next(io)) |entry| {
                    if (!std.mem.eql(u8, entry.name, "lock") and !std.mem.eql(u8, entry.name, "refresh.lock")) return error.MigrationIndexMissing;
                }
                return error.FileNotFound;
            };
            index.close(io);
        }
        var refresh: ?std.Io.File = null;
        errdefer if (refresh) |file| {
            file.unlock(io);
            file.close(io);
        };
        if (if (borrowed == null) migration else null) |create_lease| {
            refresh = openRefreshFile(dir, io, create_lease) catch |err| if (err == error.FileNotFound and !create_lease) null else return err;
            if (refresh) |file| {
                try @import("../keyring_file.zig").privateFile(io, file);
                if (!try file.tryLock(io, .exclusive)) {
                    file.close(io);
                    refresh = null;
                    return error.CacheBusy;
                }
            }
        }
        const lock = if (borrowed) |lease| lease.lock else if (sealed) |vault| vault.directory.lease else if (migration != null and !migration.?) vault_storage.openPrivate(io, dir, "lock") catch |err| if (err == error.FileNotFound) return error.MigrationLeaseRequired else return err else try openPrivateLock(dir, io);
        errdefer if (sealed == null and borrowed == null) lock.close(io);
        if (migration != null) try @import("../keyring_file.zig").privateFile(io, lock);
        const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(if (readonly) 250 else 2000) });
        while (sealed == null and borrowed == null and !try lock.tryLock(io, if (readonly) .shared else .exclusive)) {
            if (deadline.durationFromNow(io).raw.toNanoseconds() <= 0) return error.CacheBusy;
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(10) }).sleep(io);
        }
        if (!readonly and sealed == null) try cleanupScratch(dir, io, a);
        var state: State = .{ .account = account };
        var objects: []VaultObject = &.{};
        const raw: ?[]const u8 = if (sealed) |vault| try vault.read(a, .cache_index, vault.entry.index, index_read_bytes) else if (migration != null) try @import("store_migration.zig").readIndex(io, dir, a) else readPrivate(dir, io, a, "index.json", index_read_bytes) catch |err| if (err == error.FileNotFound) null else return err;
        if (raw) |bytes| {
            // readPrivate owns this immutable buffer in the same caller arena
            // as State. Borrow unescaped strings instead of copying each field
            // on every short refresh commit; escaped strings still allocate.
            if (sealed != null) {
                const envelope = try std.json.parseFromSliceLeaky(VaultIndex, a, bytes, .{ .allocate = .alloc_if_needed });
                if (envelope.schema != 1 or envelope.objects.len > vault_object_limit) return error.InvalidVaultIndex;
                state = envelope.state;
                objects = envelope.objects;
                var names: std.StringHashMap(void) = .init(a);
                defer names.deinit();
                var handles: std.StringHashMap(void) = .init(a);
                defer handles.deinit();
                var blob_count: usize = 0;
                for (objects) |object| {
                    if (try vaultKind(object.name) != object.kind) return error.InvalidVaultIndex;
                    if (object.kind == .attachment) blob_count += 1;
                    if (blob_count > blob_limit) return error.AttachmentLimitExceeded;
                    const handle = try vault_storage.Handle.parse(object.handle);
                    if (std.mem.eql(u8, &handle.bytes, &sealed.?.entry.index.bytes) or (try names.getOrPut(object.name)).found_existing or (try handles.getOrPut(object.handle)).found_existing) return error.InvalidVaultIndex;
                }
            } else state = try std.json.parseFromSliceLeaky(State, a, bytes, .{ .allocate = .alloc_if_needed });
            if ((state.schema != 1 and state.schema != 2) or !std.mem.eql(u8, state.account, account)) return error.CacheIdentityMismatch;
            try @import("operation_history.zig").validate(state.history);
            if (state.schema == 1 and state.history.pages != 0) return error.InvalidHistory;
            try @import("attachment_receipts.zig").validate(state.attachmentReceipts);
            try @import("draft_link.zig").validate(state.draftLinks);
            for (state.draftLinks) |link| {
                var found = false;
                for (state.drafts) |draft_value| found = found or std.mem.eql(u8, draft_value.id, link.draftId);
                if (!found) return error.CacheIdentityMismatch;
            }
            if (state.relatedDraftBlobs.len > 128) return error.CacheLimitExceeded;
            for (state.relatedDraftBlobs, 0..) |references, index| {
                if (references.blobs.len > t.Limits.related_resources) return error.CacheLimitExceeded;
                var found = false;
                for (state.drafts) |draft_value| found = found or std.mem.eql(u8, draft_value.id, references.draftId);
                if (!found) return error.CacheIdentityMismatch;
                for (state.relatedDraftBlobs[0..index]) |previous| if (std.mem.eql(u8, previous.draftId, references.draftId)) return error.CacheIdentityMismatch;
                for (references.blobs) |id| try @import("draft_codec.zig").validateAttachmentHandle(id);
                if (references.handle.len != 0) {
                    if (references.blobs.len != 0) return error.InvalidDraftPins;
                    _ = try vault_storage.Handle.parse(references.handle);
                }
            }
            for (state.drafts) |draft_value| if (draft_value.summaryCounts) |counts| {
                if (counts.to > t.Limits.recipients or counts.cc > t.Limits.recipients or counts.bcc > t.Limits.recipients or counts.to + counts.cc + counts.bcc > t.Limits.recipients or counts.attachments > t.Limits.attachments) return error.CacheLimitExceeded;
                var pinned = false;
                for (state.relatedDraftBlobs) |ref| pinned = pinned or (std.mem.eql(u8, ref.draftId, draft_value.id) and ref.handle.len != 0);
                if (!pinned) return error.InvalidDraftPins;
            };
            if (state.entries.len > t.Limits.metadata_hard or state.drafts.len > 128 or state.outbox.len > 128 or state.contacts.len > 1024 or state.operations.len > 1000 or state.sendQueue.len > 128 or state.fixtureProvider.len > 1024 or state.labels.len > t.Limits.labels or state.fixtureDeletedLabels.len > t.Limits.labels or state.identities.len > (if (@import("send_memory.zig").native) @as(usize, 1024) else 32) or state.undo.len > 16) return error.CacheLimitExceeded;
            if (state.driveSources.len > 128) return error.InvalidDriveLedger;
            for (state.driveSources, 0..) |source, source_index| {
                if (source.operationId.len == 0 or source.operationId.len > 256) return error.InvalidDriveLedger;
                try @import("draft_codec.zig").validateAttachmentHandle(source.hash);
                try @import("../bounded.zig").identifier(source.draftId);
                for (state.driveSources[0..source_index]) |previous| if (std.mem.eql(u8, previous.operationId, source.operationId)) return error.InvalidDriveLedger;
            }
            for (state.sendQueue) |entry| {
                if (entry.queueId.len == 0 or entry.queueId.len > 256 or entry.draftId.len == 0 or entry.draftId.len > 256 or entry.operationId.len == 0 or entry.operationId.len > 256 or entry.hash.len != 64 or entry.errorCode.len > 128 or entry.dueAtMs < entry.createdAtMs or entry.dueAtMs - entry.createdAtMs > 30000) return error.CacheLimitExceeded;
            }
            // Only preparation can be resumed after a process death. The
            // Gmail unknown receipt is published atomically with submitting.
            for (state.sendQueue) |*entry| if (entry.state == .preparing) {
                var submitted = false;
                for (state.operations) |operation| submitted = submitted or std.mem.eql(u8, operation.id, entry.operationId);
                entry.state = if (submitted) .unknown else .queued;
                entry.resumeRequired = true;
                if (!submitted and entry.errorCode.len == 0) entry.errorCode = "InterruptedPreparation";
            };
            for (state.labels) |label| if (label.id.len > 256 or label.name.len > 512) return error.CacheLimitExceeded;
            for (state.fixtureDeletedLabels) |id| if (id.len == 0 or id.len > 256) return error.CacheLimitExceeded;
            for (state.operations) |operation| {
                if (operation.kind.len > 64 or operation.labelId.len > 256 or (operation.sourceInvitationHash.len != 0 and operation.sourceInvitationHash.len != 64)) return error.CacheLimitExceeded;
                for (operation.sourceInvitationHash) |byte| if (!std.ascii.isHex(byte)) return error.CacheIdentityMismatch;
                if (operation.label) |label| if (label.id.len > 256 or label.name.len > 512 or label.type.len > 16) return error.CacheLimitExceeded;
            }
            for (state.identities) |identity| if (identity.address.len > mail_limits.outgoing_address_bytes or identity.name.len > mail_limits.display_name_bytes or identity.signature.len > 8192) return error.CacheLimitExceeded;
            for (state.undo) |receipt| {
                if (receipt.token.len > 256 or receipt.items.len > 100) return error.CacheLimitExceeded;
                for (receipt.items) |item| {
                    if (item.messageId.len > 256 or item.addLabels.len + item.removeLabels.len > 64 or item.errorCode.len > 64 or item.outcome.len > 16) return error.CacheLimitExceeded;
                    for (item.addLabels) |label| if (label.len > 256) return error.CacheLimitExceeded;
                    for (item.removeLabels) |label| if (label.len > 256) return error.CacheLimitExceeded;
                }
            }
        }
        var resolved = options;
        if (state.metadataPolicy != 0 and (state.metadataPolicy > t.Limits.metadata_hard or state.diskPolicy < 64 * 1024 or state.diskPolicy > t.Limits.disk_hard)) return error.CacheLimitExceeded;
        if (state.metadataPolicy != 0 and (readonly or options.use_persisted_policy or (!options.metadata_limit_set and options.metadata_limit == t.Limits.metadata))) resolved.metadata_limit = state.metadataPolicy;
        if (state.diskPolicy != 0 and (readonly or options.use_persisted_policy or (!options.disk_limit_set and options.disk_limit == t.Limits.disk_bytes))) resolved.disk_limit = state.diskPolicy;
        var s: Store = .{ .io = io, .dir = dir, .lock = lock, .allocator = a, .state = state, .options = resolved, .entriesStorage = state.entries, .vault = sealed, .vaultObjects = objects, .migration_source = migration != null, .migration_refresh = refresh, .migration_lease = borrowed };
        if (state.views.len > 16 or state.historyId.len > 32) return error.CacheLimitExceeded;
        for (state.views) |view| if (view.ids.len > t.Limits.metadata_hard or view.query.len > 4096 or view.label.len > 256 or view.remoteCursor.len > 4096) return error.CacheLimitExceeded;
        for (state.entries) |entry| {
            if (entry.bodyError.len > 64 or entry.message.bodyCacheError.len > 64 or entry.message.decodeWarning.len > 64) return error.CacheLimitExceeded;
            if (entry.bodyBlobIds) |ids| {
                if (ids.len > t.Limits.message_attachments) return error.CacheLimitExceeded;
                for (ids) |id| try @import("draft_codec.zig").validateAttachmentHandle(id);
            }
        }
        if (!options.fixtures and (state.fixtureProvider.len != 0 or state.fixtureLabelsReady or state.fixtureDeletedLabels.len != 0)) return error.CacheIdentityMismatch;
        for (state.fixtureProvider) |record| try validateFixtureRecord(record);
        // Persisted indexes already have this order. Keep the legacy fallback
        // without heap-sorting thousands of rows on every cached/body read.
        if (!preserve_order and !entriesSorted(s.state.entries)) std.sort.heap(Entry, s.state.entries, {}, newestFirst);
        if (!readonly) {
            try s.finishHistoryCleanup();
            try s.compactDraftIndex();
            try s.enforceLimits();
        }
        return s;
    }
    pub fn enforceLimits(s: *Store) !void {
        // Plan all pruning in save before deleting any body. In particular, a
        // lower policy must not destroy mail when the old/protected index
        // cannot coexist with even the smallest atomic replacement.
        var changed = s.state.metadataPolicy != s.options.metadata_limit or s.state.diskPolicy != s.options.disk_limit or
            s.state.entries.len > s.options.metadata_limit or try s.diskBytes() > s.options.disk_limit;
        s.state.metadataPolicy = s.options.metadata_limit;
        s.state.diskPolicy = s.options.disk_limit;
        if (s.state.quotaDiskLimit != 0 and s.options.disk_limit > s.state.quotaDiskLimit) {
            s.state.quotaFloor = null;
            for (s.state.entries) |*entry| if (std.mem.eql(u8, entry.bodyError, "DiskQuotaExceeded")) {
                entry.bodyError = "";
            };
            s.state.quotaDiskLimit = s.options.disk_limit;
            changed = true;
        }
        if (s.state.decoderRevision < decoder_revision) {
            for (s.state.entries) |*entry| if (retriedByNewerDecoder(entry.bodyError, s.state.decoderRevision)) {
                entry.bodyError = "";
            };
            s.state.decoderRevision = decoder_revision;
            changed = true;
        }
        if (changed) {
            s.state.generation += 1;
            try s.save();
        }
    }
    pub fn release(s: *Store) void {
        if (s.migration_lease != null) {
            s.lockHeld = false;
            return;
        }
        if (s.migration_refresh) |file| {
            file.unlock(s.io);
            file.close(s.io);
            s.migration_refresh = null;
        }
        if (s.vault) |vault| {
            if (s.lockHeld) vault.release();
            s.lockHeld = false;
            return;
        }
        if (s.lockHeld) s.lock.unlock(s.io);
        s.lockHeld = false;
    }
    pub fn close(s: *Store) void {
        if (s.closed) return;
        s.closed = true;
        if (s.migration_lease != null) {
            s.lockHeld = false;
            return;
        }
        if (s.migration_refresh) |file| {
            file.unlock(s.io);
            file.close(s.io);
            s.migration_refresh = null;
        }
        if (s.vault) |vault| {
            if (s.lockHeld) vault.release();
            s.lockHeld = false;
            if (s.owns_vault) {
                vault.close();
                s.allocator.destroy(vault);
            }
            return;
        }
        if (s.lockHeld) s.lock.unlock(s.io);
        s.lock.close(s.io);
        s.dir.close(s.io);
    }
    pub fn hash(bytes: []const u8) [64]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }
    pub fn fileName(s: *Store, prefix: []const u8, id: []const u8) ![]const u8 {
        const key = hash(id);
        return std.fmt.allocPrint(s.allocator, "{s}-{s}.json", .{ prefix, key });
    }
    fn vaultReady(s: *const Store) !*vault_catalog.Account {
        if (s.closed or !s.lockHeld) return error.VaultSessionClosed;
        if (s.vaultFailed) return error.VaultSessionFailed;
        const vault = s.vault orelse return error.VaultLocked;
        try vault.requireActive();
        if (vault.reader_owner != null) return error.VaultBusy;
        return vault;
    }
    fn vaultObject(s: *const Store, name: []const u8) ?VaultObject {
        for (s.vaultObjects) |object| if (std.mem.eql(u8, object.name, name)) return object;
        return null;
    }
    fn readRecord(s: *Store, a: std.mem.Allocator, name: []const u8, limit: usize) ![]const u8 {
        if (s.vault != null) {
            const vault = try s.vaultReady();
            _ = try vaultKind(name);
            const object = s.vaultObject(name) orelse return error.FileNotFound;
            return vault.read(a, object.kind, try vault_storage.Handle.parse(object.handle), limit) catch |err| if (err == error.FileNotFound) error.VaultRecordMissing else err;
        }
        return readPrivate(s.dir, s.io, a, name, limit);
    }
    fn removeRecord(s: *Store, name: []const u8) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        if (s.migration_source) return error.MigrationSourceReadOnly;
        if (s.vault != null) {
            _ = try s.vaultReady();
            const previous = s.vaultObject(name) orelse return;
            const next = try s.allocator.alloc(VaultObject, s.vaultObjects.len - 1);
            var count: usize = 0;
            for (s.vaultObjects) |object| if (!std.mem.eql(u8, object.name, name)) {
                next[count] = object;
                count += 1;
            };
            try s.vaultRetired.append(s.allocator, try vault_storage.Handle.parse(previous.handle));
            s.vaultObjects = next;
            return;
        }
        s.dir.deleteFile(s.io, name) catch |err| if (err != error.FileNotFound) return err;
    }
    fn writeVault(s: *Store, name: []const u8, bytes: []const u8) !void {
        const vault = try s.vaultReady();
        const kind = try vaultKind(name);
        const limit: usize = switch (kind) {
            .mail_body, .draft, .outbox => mail_record_bytes,
            .attachment => t.Limits.incoming_attachment_bytes,
            .operation_ledger => 4 * 1024 * 1024,
            .cache_index => 8 * 1024 * 1024,
            .preferences => 512 * 1024,
            else => unreachable,
        };
        if (bytes.len > limit) return error.CacheLimitExceeded;
        try s.makeRoom(bytes.len, name);
        const previous = s.vaultObject(name);
        const next = try s.allocator.alloc(VaultObject, s.vaultObjects.len + @intFromBool(previous == null));
        @memcpy(next[0..s.vaultObjects.len], s.vaultObjects);
        var position: usize = s.vaultObjects.len;
        for (s.vaultObjects, 0..) |object, index| if (std.mem.eql(u8, object.name, name)) {
            position = index;
            break;
        };
        const handle = try vault_storage.Handle.create(s.io);
        next[position] = .{ .name = try s.allocator.dupe(u8, name), .kind = kind, .handle = try s.allocator.dupe(u8, &handle.text()) };
        if (previous) |_| try s.vaultRetired.ensureUnusedCapacity(s.allocator, 1);
        try vault.write(kind, handle, bytes, false);
        if (previous) |old| s.vaultRetired.appendAssumeCapacity(try vault_storage.Handle.parse(old.handle));
        s.vaultObjects = next;
    }
    pub fn vaultContext(s: *const Store) !*vault_catalog.Account {
        return s.vaultReady();
    }
    pub fn vaultBlobCount(s: *const Store) usize {
        var count: usize = 0;
        for (s.vaultObjects) |object| if (object.kind == .attachment) {
            count += 1;
        };
        return count;
    }
    pub fn hasVaultBlob(s: *Store, name: []const u8) !bool {
        if (s.vaultObject(name) != null) return true;
        if (try vaultKind(name) != .attachment) return error.InvalidVaultObject;
        const value = (try @import("operation_history.zig").findBlob(s, s.allocator, name[5..69])) orelse return false;
        return !value.deleted;
    }
    pub fn openVaultStream(s: *Store, name: []const u8) !@import("vault_stream.zig").Reader {
        const vault = try s.vaultReady();
        if (try vaultKind(name) != .attachment) return error.InvalidVaultObject;
        const handle = if (s.vaultObject(name)) |object| try vault_storage.Handle.parse(object.handle) else blk: {
            const value = (try @import("operation_history.zig").findBlob(s, s.allocator, name[5..69])) orelse return error.AttachmentHandleNotFound;
            if (value.deleted) return error.AttachmentHandleNotFound;
            break :blk try vault_storage.Handle.parse(value.handle);
        };
        return @import("vault_stream.zig").Reader.init(&vault.directory, vault.owner.key, vault.record(.attachment, handle), &vault.owner.workspace.ciphertext, &vault.reader_owner) catch |err| if (err == error.FileNotFound) error.VaultRecordMissing else err;
    }
    /// Reserve the entire overlap, including existing/orphan/staging files.
    /// Used only by internal encrypted streaming adapters, never export paths.
    pub fn vaultIndexStagingBytes(s: *const Store) !usize {
        _ = try s.vaultReady();
        const current = @import("gmail_decode.zig").serializedBytes(VaultIndex{ .state = s.state, .objects = s.vaultObjects });
        // One opaque blob map entry fits within this conservative allowance.
        return vault_types.sealedSize(current + 512);
    }
    pub fn reserveVaultCiphertext(s: *Store, count: usize) !void {
        _ = try s.vaultReady();
        const used = s.migration_disk_bytes orelse try s.diskBytes();
        if (count > s.options.disk_limit -| used) return error.DiskQuotaExceeded;
    }
    /// Called only after a completed migration publication. Existing/reused
    /// objects were included in the single scan and are never charged twice.
    pub fn accountMigrationCiphertext(s: *Store, added: usize, removed: usize) !void {
        if (!s.migration_destination or s.migration_disk_bytes == null) return error.MigrationDestinationRequired;
        const used = s.migration_disk_bytes.?;
        if (removed > used) return error.InvalidVaultIndex;
        s.migration_disk_bytes = try std.math.add(usize, used - removed, added);
    }
    pub fn beginVaultStream(s: *Store, writer: *@import("vault_stream.zig").Writer, kind: vault_types.RecordKind, size_bytes: usize) !vault_storage.Handle {
        const vault = try s.vaultReady();
        try vault.requireSharedWorkspace();
        if (kind != .attachment and kind != .send_spool) return error.InvalidVaultObject;
        try s.makeRoom(size_bytes, "");
        const handle = try vault_storage.Handle.create(s.io);
        try writer.initOwnedInPlace(&vault.directory, vault.owner.key, vault.record(kind, handle), size_bytes, &vault.owner.workspace.plaintext, &vault.writer_owner, vault_catalog.Account.releaseWriter);
        return handle;
    }
    /// Publish a completed immutable blob and its map in one fresh index
    /// transaction. Failed index persistence leaves charged orphan ciphertext.
    pub fn adoptVaultBlob(s: *Store, name: []const u8, handle: vault_storage.Handle) !void {
        const vault = try s.vaultReady();
        if (try vaultKind(name) != .attachment or try s.hasVaultBlob(name)) return error.InvalidVaultObject;
        var reader = try @import("vault_stream.zig").Reader.init(&vault.directory, vault.owner.key, vault.record(.attachment, handle), &vault.owner.workspace.ciphertext, &vault.reader_owner);
        const bytes = reader.size;
        reader.close();
        try @import("operation_history.zig").putBlob(s, .{ .id = name[5..69], .handle = try s.allocator.dupe(u8, &handle.text()), .size = bytes, .references = 0 });
    }
    pub fn adoptPlainBlob(s: *Store, name: []const u8, bytes: usize) !void {
        try s.requirePlainFiles();
        if (try vaultKind(name) != .attachment) return error.InvalidVaultObject;
        if (try @import("operation_history.zig").findBlob(s, s.allocator, name[5..69])) |old| if (!old.deleted) {
            if (old.size != bytes) return error.AttachmentChanged;
            return;
        };
        const handle = try vault_storage.Handle.create(s.io);
        try @import("operation_history.zig").putBlob(s, .{ .id = name[5..69], .handle = try s.allocator.dupe(u8, &handle.text()), .size = bytes, .references = if (s.state.history.unindexedBlobPins) null else @as(u64, 0) });
    }
    pub fn discardVaultBlob(s: *Store, name: []const u8) !void {
        if (try vaultKind(name) != .attachment) return error.InvalidVaultObject;
        if (try @import("operation_history.zig").deleteBlob(s, name[5..69])) return;
        try s.removeRecord(name);
        try s.saveVault();
    }
    fn saveVault(s: *Store) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        const vault = try s.vaultReady();
        try vault.requireSharedWorkspace();
        errdefer s.vaultFailed = true;
        if (s.state.entries.len > s.options.metadata_limit) return error.DiskQuotaExceeded;
        const value: VaultIndex = .{ .state = s.state, .objects = s.vaultObjects };
        const bytes = @import("gmail_decode.zig").serializedBytes(value);
        if (bytes >= vault_index_write_bytes) return error.CacheLimitExceeded;
        try s.makeRoom(bytes, "index.json");
        var writer: @import("vault_stream.zig").Writer = undefined;
        try writer.init(&vault.directory, vault.owner.key, vault.record(.cache_index, vault.entry.index), bytes, vault.owner.workspace, true, .{});
        defer writer.deinit();
        std.json.Stringify.value(value, .{}, &writer.interface) catch |err| return writer.failure orelse err;
        writer.finish() catch |err| {
            if (err == error.VaultDurabilityUncertain) vault.owner.uncertain = true;
            return err;
        };
        // Delete only records this authenticated index has just retired. A
        // failed cleanup leaves charged ciphertext; no orphan sweep here.
        for (s.vaultRetired.items) |handle| vault.remove(handle) catch {};
        s.vaultRetired.clearRetainingCapacity();
    }
    fn documentLimit(s: *const Store, name: []const u8) !usize {
        if (std.mem.startsWith(u8, name, "history-calendar-")) return 256 * 1024;
        if (@import("operation_history.zig").direct(name)) return @import("operation_history.zig").page_bytes;
        if (std.mem.eql(u8, name, "follow-ups.json") or std.mem.eql(u8, name, "fixture-gmail-drafts.json")) return 512 * 1024;
        if (std.mem.eql(u8, name, "calendar-state.json")) return 4 * 1024 * 1024;
        if (std.mem.eql(u8, name, "drive-uploads.json")) return 1024 * 1024;
        if (std.mem.eql(u8, name, "calendar-agenda.json")) return 8 * 1024 * 1024;
        if (std.mem.eql(u8, name, "calendar-provider-fixture.json") and s.options.fixtures) return 4 * 1024 * 1024;
        return error.InvalidStoreDocument;
    }
    /// Internal account documents share the same private-file and quota policy.
    /// Accept fixed names only: request JSON must never select filesystem paths.
    pub fn readDocument(s: *Store, a: std.mem.Allocator, name: []const u8, max_bytes: usize) !?[]const u8 {
        const bound = try s.documentLimit(name);
        return s.readRecord(a, name, @min(bound, max_bytes)) catch |err| if (err == error.FileNotFound) null else err;
    }
    pub fn writeDocument(s: *Store, name: []const u8, bytes: []const u8) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        if (bytes.len > try s.documentLimit(name)) return error.CacheLimitExceeded;
        if (s.vault != null) {
            errdefer s.vaultFailed = true;
            try s.writeVault(name, bytes);
            return s.saveVault();
        }
        // Reserve the complete new file while the old copy still exists, and
        // persist any mail evictions before publishing this document.
        while (true) {
            try s.makeRoom(bytes.len, name);
            try s.save();
            // Saving an initially empty index or quota annotations can grow
            // it slightly. If that used the reserved room, evict and persist
            // again; every further iteration must remove a cache entry or fail.
            if (bytes.len <= s.options.disk_limit -| try s.diskBytes()) break;
        }
        try s.write(name, bytes);
    }
    pub fn write(s: *Store, name: []const u8, bytes: []const u8) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        if (s.migration_source) return error.MigrationSourceReadOnly;
        if (s.vault != null) return s.writeVault(name, bytes);
        var af = try s.dir.createFileAtomic(s.io, name, .{ .permissions = .fromMode(0o600), .replace = true });
        defer af.deinit(s.io);
        try af.file.writeStreamingAll(s.io, bytes);
        try af.file.sync(s.io);
        try af.replace(s.io);
        // Persist the rename as well as its contents before a send can occur.
        const parent: std.Io.File = .{ .handle = s.dir.handle, .flags = .{ .nonblocking = false } };
        try parent.sync(s.io);
    }
    pub fn save(s: *Store) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        if (s.migration_source) return error.MigrationSourceReadOnly;
        // New indexes fail closed in older clients which cannot consult the
        // permanent settled-operation fences.
        s.state.schema = 2;
        if (s.vault != null) return s.saveVault();
        try s.admitIndex();
        // The admitted state stays fixed through serialization. A small file
        // buffer avoids growing and retaining an index-sized arena allocation.
        var af = try s.dir.createFileAtomic(s.io, "index.json", .{ .permissions = .fromMode(0o600), .replace = true });
        defer af.deinit(s.io);
        var buffer: [8192]u8 = undefined;
        var writer = af.file.writer(s.io, &buffer);
        std.json.Stringify.value(s.state, .{}, &writer.interface) catch |err| return writer.err orelse err;
        try writer.flush();
        try af.file.sync(s.io);
        try af.replace(s.io);
        const parent: std.Io.File = .{ .handle = s.dir.handle, .flags = .{ .nonblocking = false } };
        try parent.sync(s.io);
    }
    pub fn rememberAttachments(s: *Store, message: t.Message) !void {
        s.state.attachmentReceipts = try @import("attachment_receipts.zig").remember(s.allocator, s.state.attachmentReceipts, message);
    }
    fn indexFits(s: *const Store, state: State, bytes: usize, used: usize) bool {
        return state.entries.len <= s.options.metadata_limit and bytes < index_write_bytes and
            bytes <= s.options.disk_limit - @min(used, s.options.disk_limit);
    }
    fn admitIndex(s: *Store) !void {
        const serializedBytes = @import("gmail_decode.zig").serializedBytes;
        var bytes = serializedBytes(s.state);
        var used = try s.diskBytes();
        if (s.indexFits(s.state, bytes, used)) return;

        // Borrow the retained entry prefix, but give the plan its own view-ID
        // arrays. A quota refusal leaves all state and body files untouched.
        // Non-mail files, including the old index and every protected draft,
        // outbox and receipt, remain charged throughout the atomic write.
        var planned = s.state;
        planned.views = try s.allocator.dupe(View, s.state.views);
        for (planned.views) |*view| view.ids = try s.allocator.dupe([]const u8, view.ids);
        planned.generation +|= 1;
        bytes = serializedBytes(planned);
        while (true) {
            if (s.indexFits(planned, bytes, used)) {
                // Verify the final count before any irreversible file work.
                bytes = serializedBytes(planned);
                if (s.indexFits(planned, bytes, used)) break;
            }
            if (planned.entries.len == 0) return if (bytes >= index_write_bytes) error.CacheLimitExceeded else error.DiskQuotaExceeded;
            const tail = planned.entries[planned.entries.len - 1].message;
            var name_buffer: [74]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buffer, "mail-{s}.json", .{hash(tail.id)}) catch unreachable;
            const removed_file_bytes = try s.size(name);
            const fields_before = serializedBytes(planned.indexQuotaFloor) + serializedBytes(planned.quotaFloor) + serializedBytes(planned.quotaDiskLimit);
            // A count-only trim does not establish a byte-quota floor.
            if (planned.entries.len <= s.options.metadata_limit) {
                if (bytes >= index_write_bytes) {
                    if (planned.indexQuotaFloor == null or newestFirst({}, .{ .message = tail }, .{ .message = .{ .id = planned.indexQuotaFloor.?.id, .threadId = "", .receivedAt = planned.indexQuotaFloor.?.receivedAt } })) planned.indexQuotaFloor = .{ .receivedAt = tail.receivedAt, .id = tail.id };
                } else {
                    planned.quotaFloor = .{ .receivedAt = tail.receivedAt, .id = tail.id };
                    planned.quotaDiskLimit = s.options.disk_limit;
                }
            }
            bytes = bytes - fields_before + serializedBytes(planned.indexQuotaFloor) + serializedBytes(planned.quotaFloor) + serializedBytes(planned.quotaDiskLimit);
            bytes -= pruneIndexTail(&planned);
            used -= @min(removed_file_bytes, used);
        }
        // Only the proven tail is removed. Planning never touches another
        // account, protected files or the original immutable entry contents.
        for (s.state.entries[planned.entries.len..]) |entry| {
            var name_buffer: [74]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buffer, "mail-{s}.json", .{hash(entry.message.id)}) catch unreachable;
            s.dir.deleteFile(s.io, name) catch |err| if (err != error.FileNotFound) return err;
        }
        s.state = planned;
    }
    /// Exact JSON size removed by one tail entry and its view memberships.
    /// Count deltas keep wide indexes linear in their metadata bytes instead
    /// of serializing the entire shrinking index after every eviction.
    fn pruneIndexTail(state: *State) usize {
        const serializedBytes = @import("gmail_decode.zig").serializedBytes;
        const last = state.entries.len - 1;
        const entry = state.entries[last];
        var removed = serializedBytes(entry) + @as(usize, @intFromBool(last != 0));
        for (state.views) |*view| {
            var kept: usize = 0;
            var removed_ids: usize = 0;
            for (view.ids) |id| {
                if (std.mem.eql(u8, id, entry.message.id)) {
                    removed += serializedBytes(id);
                    removed_ids += 1;
                } else {
                    @constCast(view.ids)[kept] = id;
                    kept += 1;
                }
            }
            if (removed_ids != 0) {
                removed += removed_ids - @as(usize, @intFromBool(kept == 0));
                if (!view.incomplete) removed += 1; // false -> true
                view.incomplete = true;
            }
            view.ids = view.ids[0..kept];
        }
        state.entries = state.entries[0..last];
        return removed;
    }
    pub const BlobStats = struct { count: usize = 0, bytes: usize = 0 };
    /// Sealed stats count indexed attachment ciphertext only; total diskBytes
    /// additionally charges all orphan and staging files whose role is unknown.
    pub fn blobStats(s: *Store) !BlobStats {
        var result: BlobStats = .{};
        if (s.vault != null) {
            _ = try s.vaultReady();
            result.count = @intCast(s.state.history.blobFiles);
            result.bytes = @intCast(s.state.history.blobBytes);
            for (s.vaultObjects) |object| if (object.kind == .attachment) {
                result.count += 1;
                result.bytes += try s.size(object.name);
            };
        } else {
            var iterator = s.dir.iterate();
            while (try iterator.next(s.io)) |entry| if (std.mem.startsWith(u8, entry.name, "blob-") and std.mem.endsWith(u8, entry.name, ".bin")) {
                const stat = try s.dir.statFile(s.io, entry.name, .{ .follow_symlinks = false });
                if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureAttachmentFile;
                result.count += 1;
                result.bytes = std.math.add(usize, result.bytes, @intCast(stat.size)) catch return error.CacheLimitExceeded;
            };
        }
        return result;
    }
    pub fn diskBytes(s: *Store) !usize {
        s.disk_scan_count +|= 1;
        var total: usize = 0;
        var it = s.dir.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file) return error.UnexpectedCacheEntry;
            const stat = try s.dir.statFile(s.io, e.name, .{ .follow_symlinks = false });
            total = std.math.add(usize, total, @intCast(stat.size)) catch return error.CacheLimitExceeded;
        }
        return total;
    }
    fn size(s: *Store, name: []const u8) !usize {
        if (s.vault != null) {
            const vault = try s.vaultReady();
            const object = s.vaultObject(name) orelse return 0;
            var reader = try vault.directory.reader(try vault_storage.Handle.parse(object.handle));
            defer reader.close();
            return @intCast((try reader.file.stat(s.io)).size);
        }
        const st = s.dir.statFile(s.io, name, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return 0 else return err;
        return @intCast(st.size);
    }
    fn makeRoom(s: *Store, n: usize, replacing: []const u8) !void {
        if (s.vault != null) {
            _ = try s.vaultReady();
            // Count EVERY directory file: current records, retired records,
            // interrupted complete writes, and concurrent ciphertext staging.
            const sealed_bytes = try vault_types.sealedStreamSize(n);
            const used = try s.diskBytes();
            if (sealed_bytes > s.options.disk_limit - @min(used, s.options.disk_limit)) return error.DiskQuotaExceeded;
            return;
        }
        if (n > s.options.disk_limit) return error.DiskQuotaExceeded;
        var used = try s.diskBytes();
        // The old file remains while an atomic replacement is written. Include
        // that overlap rather than measuring only the final directory contents.
        var remaining = s.state.entries.len;
        while (n > s.options.disk_limit - @min(used, s.options.disk_limit)) {
            if (remaining == 0) return error.DiskQuotaExceeded;
            remaining -= 1;
            const name = try s.fileName("mail", s.state.entries[remaining].message.id);
            if (std.mem.eql(u8, name, replacing)) return error.DiskQuotaExceeded;
            const removed = try s.size(name);
            s.state.quotaFloor = .{ .receivedAt = s.state.entries[remaining].message.receivedAt, .id = s.state.entries[remaining].message.id };
            s.state.quotaDiskLimit = s.options.disk_limit;
            try s.evict(remaining);
            used -= @min(removed, used);
        }
    }
    pub fn reserveBytes(s: *Store, count: usize) !void {
        try s.requirePlainFiles();
        try s.makeRoom(count, "");
    }
    pub fn blobReferenced(s: *const Store, id: []const u8) bool {
        for (s.state.drafts) |draft_value| for (draft_value.attachments) |attachment| if (attachment.blobId) |blob| if (std.mem.eql(u8, blob, id)) return true;
        for (s.state.outbox) |message| for (message.attachments) |attachment| if (attachment.blobId) |blob| if (std.mem.eql(u8, blob, id)) return true;
        for (s.state.entries) |entry| for (entry.message.attachments) |attachment| if (attachment.blobId) |blob| if (std.mem.eql(u8, blob, id)) return true;
        for (s.state.entries) |entry| if (entry.bytes != 0) if (entry.bodyBlobIds) |ids| for (ids) |blob| if (std.mem.eql(u8, blob, id)) return true;
        for (s.state.relatedDraftBlobs) |references| for (references.blobs) |blob| if (std.mem.eql(u8, blob, id)) return true;
        return false;
    }

    /// Discard discovers legacy references lazily, one verified body at a
    /// time. Missing/corrupt bodies fail closed; startup never scans bodies.
    pub fn blobReferencedVerified(s: *Store, id: []const u8) !bool {
        if (s.blobReferenced(id)) return true;
        for (s.state.relatedDraftBlobs) |reference| if (reference.handle.len != 0) {
            var phase: std.heap.ArenaAllocator = .init(if (@import("send_memory.zig").native) @import("send_memory.zig").allocator() else s.allocator);
            defer phase.deinit();
            for (try s.activeDraftPinIds(phase.allocator(), reference.draftId)) |key| if (std.mem.eql(u8, key, id)) return true;
        };
        if (try @import("operation_history.zig").blobReferenced(s, id)) return true;
        var changed = false;
        for (s.state.entries) |*entry| if (entry.bytes != 0 and entry.bodyBlobIds == null) {
            var ids: [t.Limits.message_attachments][64]u8 = undefined;
            var count: usize = 0;
            {
                var phase: std.heap.ArenaAllocator = .init(s.allocator);
                defer phase.deinit();
                const message = (try s.readWithAllocator(phase.allocator(), entry.message.id)) orelse return error.AttachmentReferenceUnavailable;
                if (!std.mem.eql(u8, message.threadId, entry.message.threadId)) return error.CacheIdentityMismatch;
                for (message.attachments) |attachment| if (attachment.blobId) |blob| {
                    try @import("draft_codec.zig").validateAttachmentHandle(blob);
                    var duplicate = false;
                    for (ids[0..count]) |previous| duplicate = duplicate or std.mem.eql(u8, &previous, blob);
                    if (!duplicate) {
                        if (count == ids.len) return error.CacheLimitExceeded;
                        @memcpy(&ids[count], blob);
                        count += 1;
                    }
                };
            }
            const owned = try s.allocator.alloc([]const u8, count);
            for (owned, ids[0..count]) |*target, blob| target.* = try s.allocator.dupe(u8, &blob);
            entry.bodyBlobIds = owned;
            changed = true;
            for (owned) |blob| if (std.mem.eql(u8, blob, id)) {
                try s.save();
                return true;
            };
        };
        if (changed) try s.save();
        return false;
    }

    pub fn bodyNeedsUpgrade(s: *Store, id: []const u8) bool {
        const entry = s.find(id) orelse return false;
        return entry.bytes != 0 and entry.bodyDecoderRevision < body_decoder_revision;
    }

    fn evict(s: *Store, i: usize) !void {
        const name = try s.fileName("mail", s.state.entries[i].message.id);
        try s.removeRecord(name);
        for (s.state.views) |*view| {
            var kept: usize = 0;
            for (view.ids) |id| if (!std.mem.eql(u8, id, s.state.entries[i].message.id)) {
                @constCast(view.ids)[kept] = id;
                kept += 1;
            };
            if (kept != view.ids.len) view.incomplete = true;
            view.ids = view.ids[0..kept];
        }
        std.mem.copyForwards(Entry, s.state.entries[i .. s.state.entries.len - 1], s.state.entries[i + 1 ..]);
        s.state.entries = s.state.entries[0 .. s.state.entries.len - 1];
    }
    pub fn find(s: *Store, id: []const u8) ?*Entry {
        for (s.state.entries) |*e| if (std.mem.eql(u8, e.message.id, id)) return e;
        return null;
    }
    pub fn invalidate(s: *Store, id: []const u8) !void {
        for (s.state.entries, 0..) |entry, i| if (std.mem.eql(u8, entry.message.id, id)) return s.evict(i);
    }
    pub fn put(s: *Store, message: t.Message, full: bool) !void {
        if (message.bodyCacheError.len > 64 or message.decodeWarning.len > 64) return error.CacheLimitExceeded;
        if (message.bodyText.len > t.Limits.compose_body_bytes) return error.BodyTooLarge;
        // A conversation-wide response quota says nothing about previously
        // verified metadata. Preserve its full subject/envelope and any body.
        if (std.mem.eql(u8, message.bodyCacheError, "ThreadBodyBudgetExceeded") and s.find(message.id) != null) return;
        if (std.mem.eql(u8, message.decodeWarning, "MetadataBudgetExceeded")) if (s.find(message.id)) |entry| {
            // Preserve the complete immutable envelope while retaining any
            // independently verified current folder and unread membership.
            entry.message.decodeWarning = "MetadataBudgetExceeded";
            entry.message.metadataPartial = true;
            entry.message.labelsVerified = message.labelsVerified;
            if (message.labelsVerified) {
                entry.message.labels = message.labels;
                entry.message.unread = message.unread;
            }
            return;
        };
        var metadata = message;
        if (std.mem.eql(u8, metadata.bodyCacheError, "ThreadBodyBudgetExceeded")) metadata.bodyCacheError = "";
        metadata.bodyText = "";
        metadata.bodyHtml = null;
        metadata.bodySource = .unknown;
        // Keep bounded participant metadata for cache-only completion,
        // including Sent recipients. Full body records preserve every header
        // participant for reply-all; this compact index is never a full read.
        var participant_budget: usize = participant_bytes;
        metadata.to = participantPrefix(message.to, &participant_budget);
        metadata.cc = participantPrefix(message.cc, &participant_budget);
        metadata.replyTo = &.{};
        metadata.attachments = try attachmentMetadata(s.allocator, message.attachments);
        metadata.invitation = null;
        metadata.fixtureRaw = null;
        var existing: ?usize = null;
        for (s.state.entries, 0..) |entry, i| if (std.mem.eql(u8, entry.message.id, message.id)) {
            existing = i;
            // A failed projection provides no evidence of folder removal.
            // Retain prior membership/order and mark it explicitly unverified.
            if (!metadata.labelsVerified) {
                metadata.labels = entry.message.labels;
                metadata.unread = entry.message.unread;
            }
            if (metadata.metadataPartial and metadata.receivedAt == 0) metadata.receivedAt = entry.message.receivedAt;
            // Gmail's metadata projection omits MIME parts. A label/header
            // refresh must retain the descriptors from the immutable body.
            if (!full and metadata.attachments.len == 0) metadata.attachments = entry.message.attachments;
            break;
        };
        if (existing == null) {
            if (s.state.quotaFloor) |floor| if (!newestFirst({}, .{ .message = metadata }, .{ .message = .{ .id = floor.id, .threadId = "", .receivedAt = floor.receivedAt } })) return;
            if (s.state.indexQuotaFloor) |floor| if (!newestFirst({}, .{ .message = metadata }, .{ .message = .{ .id = floor.id, .threadId = "", .receivedAt = floor.receivedAt } })) return;
            if (s.state.entries.len == s.options.metadata_limit) {
                const tail = s.state.entries[s.state.entries.len - 1];
                if (!newestFirst({}, .{ .message = metadata }, tail)) return;
                try s.evict(s.state.entries.len - 1);
            }
            const count = s.state.entries.len;
            if (count == s.entriesStorage.len) {
                const capacity = @min(s.options.metadata_limit, @max(count + 1, if (count == 0) @as(usize, 16) else count + count / 2));
                const storage = try s.allocator.alloc(Entry, capacity);
                @memcpy(storage[0..count], s.state.entries);
                s.allocator.free(s.entriesStorage);
                s.entriesStorage = storage;
            }
            const entry: Entry = .{ .message = metadata };
            const position = entryPosition(s.state.entries, entry);
            std.mem.copyBackwards(Entry, s.entriesStorage[position + 1 .. count + 1], s.entriesStorage[position..count]);
            s.entriesStorage[position] = entry;
            s.state.entries = s.entriesStorage[0 .. count + 1];
        } else {
            const i = existing.?;
            if (s.state.entries[i].message.receivedAt == metadata.receivedAt) {
                s.state.entries[i].message = metadata;
            } else {
                // Retain the immutable body's reference while repositioning a
                // changed timestamp. All other rows remain in sorted order.
                var entry = s.state.entries[i];
                entry.message = metadata;
                const count = s.state.entries.len;
                std.mem.copyForwards(Entry, s.state.entries[i .. count - 1], s.state.entries[i + 1 ..]);
                const position = entryPosition(s.state.entries[0 .. count - 1], entry);
                std.mem.copyBackwards(Entry, s.state.entries[position + 1 .. count], s.state.entries[position .. count - 1]);
                s.state.entries[position] = entry;
            }
        }
        if (message.bodyCacheError.len != 0 and !std.mem.eql(u8, message.bodyCacheError, "ThreadBodyBudgetExceeded")) {
            if (s.find(message.id)) |entry| if (entry.bytes == 0) {
                entry.bodyError = message.bodyCacheError;
            };
        }
        if (full) _ = try s.putBody(message);
    }
    /// Attach bytes only to retained metadata. Valid current-decoder bodies
    /// remain immutable; a complete FULL read may atomically upgrade legacy
    /// decoding without changing membership, ordering or labels.
    pub fn putBody(s: *Store, message: t.Message) !bool {
        if (message.bodyCacheError.len > 64 or message.decodeWarning.len > 64) return error.CacheLimitExceeded;
        var e = s.find(message.id) orelse return false;
        if (message.bodyText.len > t.Limits.compose_body_bytes or (message.bodyHtml != null and message.bodyHtml.?.len > t.Limits.compose_body_bytes)) return error.BodyTooLarge;
        // Conversation aggregate quotas never make an individual body a final
        // refusal. An ordinary read/prefetch may still fetch it independently.
        if (std.mem.eql(u8, message.bodyCacheError, "ThreadBodyBudgetExceeded")) return false;
        if (e.bytes != 0) if (try s.read(message.id)) |previous| {
            // Old caches can retain the named .ics file without its invitation
            // source. A complete thread read or refresh must persist the newly
            // decoded source too, not only an explicit invitation inspection.
            const adds_invitation = previous.invitation == null and message.invitation != null and hasCalendarAttachment(previous);
            if (e.bodyDecoderRevision >= body_decoder_revision and !adds_invitation) return false;
            if (!std.mem.eql(u8, previous.threadId, message.threadId)) return error.MessageIdentityMismatch;
            if (message.metadataPartial or message.bodyCacheError.len != 0) return false;
        };
        if (message.invitation) |calendar| if (calendar.len > @import("invitation.zig").max_calendar_bytes) return error.CalendarTooLarge;
        if (message.bodyCacheError.len != 0) {
            e.bodyError = message.bodyCacheError;
            e.message.decodeWarning = message.decodeWarning;
            e.message.metadataPartial = true;
            return false;
        }
        const raw = try j.encodeAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
        if (raw.len > mail_record_bytes) return error.BodyTooLarge;
        const name = try s.fileName("mail", message.id);
        s.makeRoom(raw.len, name) catch |err| {
            if (err != error.DiskQuotaExceeded) return err;
            if (s.find(message.id)) |entry| if (entry.bytes == 0) {
                entry.bodyError = "DiskQuotaExceeded";
            };
            s.state.quotaDiskLimit = s.options.disk_limit;
            return false;
        };
        const blobs = try draft_summary.blobReferences(s.allocator, message.attachments);
        const digest = hash(raw);
        const owned_hash = try s.allocator.dupe(u8, &digest);
        const metadata = try attachmentMetadata(s.allocator, message.attachments);
        e = s.find(message.id) orelse return false;
        try s.write(name, raw);
        e.bodyError = "";
        e.bytes = raw.len;
        e.message.attachments = metadata;
        e.bodyHash = owned_hash;
        e.bodyBlobIds = blobs;
        e.bodyDecoderRevision = if (message.metadataPartial) 0 else body_decoder_revision;
        return true;
    }
    /// Final per-message refusals remain readable as explicit placeholders;
    /// callers must not refetch them on every selection or cached thread read.
    pub fn refusedMessage(s: *Store, id: []const u8) ?t.Message {
        const entry = s.find(id) orelse return null;
        if (entry.bodyError.len == 0 or std.mem.eql(u8, entry.bodyError, "DiskQuotaExceeded")) return null;
        var message = entry.message;
        message.bodyCached = false;
        message.bodyCacheError = entry.bodyError;
        if (message.decodeWarning.len == 0) message.decodeWarning = entry.bodyError;
        message.metadataPartial = true;
        return message;
    }
    pub fn bodyAvailable(s: *Store, id: []const u8) !bool {
        const entry = s.find(id) orelse return false;
        if (entry.bytes == 0) return false;
        if (s.vault != null) return try s.size(try s.fileName("mail", id)) == try vault_types.sealedSize(entry.bytes);
        const stat = s.dir.statFile(s.io, try s.fileName("mail", id), .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return false else return err;
        if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureCacheFile;
        return stat.size == entry.bytes;
    }
    /// A narrowly scoped decoder upgrade for a legacy named calendar part.
    /// Normal reads keep immutable bodies. This explicit inspection adds the
    /// newly fetched calendar without removing metadata, labels or view IDs.
    pub fn upgradeInvitation(s: *Store, message: t.Message) !bool {
        const calendar = message.invitation orelse return false;
        if (calendar.len > @import("invitation.zig").max_calendar_bytes) return error.CalendarTooLarge;
        const previous = (try s.read(message.id)) orelse return false;
        if (previous.invitation != null) return false;
        if (!hasCalendarAttachment(previous)) return false;
        if (!std.mem.eql(u8, previous.threadId, message.threadId)) return error.MessageIdentityMismatch;
        if (message.metadataPartial or message.bodyCacheError.len != 0) return false;
        if (message.bodyText.len > t.Limits.compose_body_bytes or (message.bodyHtml != null and message.bodyHtml.?.len > t.Limits.compose_body_bytes)) return error.BodyTooLarge;
        const raw = try j.encodeAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
        if (raw.len > mail_record_bytes) return error.BodyTooLarge;
        const name = try s.fileName("mail", message.id);
        try s.makeRoom(raw.len, name);
        const entry = s.find(message.id) orelse return false;
        const digest = hash(raw);
        const owned_hash = try s.allocator.dupe(u8, &digest);
        const blobs = try draft_summary.blobReferences(s.allocator, message.attachments);
        // The checked atomic write succeeds before the old reference changes.
        try s.write(name, raw);
        entry.bytes = raw.len;
        entry.bodyHash = owned_hash;
        entry.bodyError = "";
        entry.bodyBlobIds = blobs;
        entry.bodyDecoderRevision = if (message.metadataPartial) 0 else body_decoder_revision;
        return true;
    }
    fn hasCalendarAttachment(message: t.Message) bool {
        for (message.attachments) |part| if (@import("mime.zig").isCalendarPart(part.mimeType, part.filename)) return true;
        return false;
    }
    fn composeOnly(metadata: t.Message) t.Message {
        var message = metadata;
        message.bodyText = "";
        message.bodyHtml = null;
        message.bodyCached = false;
        message.bodyCacheError = "ComposeSourceRequired";
        return message;
    }
    fn exceedsOrdinaryBody(message: t.Message) bool {
        const html_size = if (message.bodyHtml) |html| html.len else 0;
        if (message.bodyText.len > t.Limits.body_bytes or html_size > t.Limits.body_bytes) return true;
        // MIME counts received parts before deriving a plain fallback from an
        // HTML-only body. That fallback is not a second MIME alternative; the
        // established ordinary reader accepts a full 2 MiB HTML source plus
        // its derived text. Genuine plain/HTML alternatives count separately.
        var total = if (message.bodySource == .html) @max(message.bodyText.len, html_size) else message.bodyText.len + html_size;
        if (total > t.Limits.request_bytes) return true;
        for (message.attachments) |part| if (part.data.len != 0) {
            if (part.size > t.Limits.request_bytes - total) return true;
            total += part.size;
        };
        return false;
    }
    pub fn read(s: *Store, id: []const u8) !?t.Message {
        return s.readWithAllocator(s.allocator, id);
    }
    pub fn readWithAllocator(s: *Store, allocator: std.mem.Allocator, id: []const u8) !?t.Message {
        const e = s.find(id) orelse return null;
        // A compose capture may cache more source than the normal reader's
        // fixed window. Keep its ID/envelope usable for Reply/Forward without
        // eagerly expanding that whole record in a later ordinary read.
        if (e.bytes > 4 * t.Limits.body_bytes) return composeOnly(e.message);
        return s.readBoundedWithAllocator(allocator, id, false);
    }
    pub fn readExpandedWithAllocator(s: *Store, allocator: std.mem.Allocator, id: []const u8) !?t.Message {
        return s.readBoundedWithAllocator(allocator, id, true);
    }
    fn readBoundedWithAllocator(s: *Store, allocator: std.mem.Allocator, id: []const u8, expanded: bool) !?t.Message {
        const limit = if (expanded) mail_record_bytes else 4 * t.Limits.body_bytes;
        const e = s.find(id) orelse return null;
        if (e.bytes == 0) return null;
        const key = hash(id);
        const raw = s.readRecord(allocator, try std.fmt.allocPrint(allocator, "mail-{s}.json", .{key}), limit) catch |err| if (err == error.FileNotFound) return null else return err;
        const digest = hash(raw);
        const record = try std.json.parseFromSliceLeaky(BodyRecord, allocator, raw, .{ .allocate = .alloc_if_needed });
        if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.message.id, id)) return error.CacheIdentityMismatch;
        if (!std.mem.eql(u8, e.bodyHash, &digest)) {
            e.bytes = 0;
            e.bodyHash = "";
            e.bodyBlobIds = &.{};
            e.bodyDecoderRevision = 0;
            return null;
        }
        if (!expanded and exceedsOrdinaryBody(record.message)) return composeOnly(e.message);
        return try @import("mail_display_fields.zig").canonicalizeMessageDisplay(allocator, record.message);
    }
    pub fn putOutbox(s: *Store, message: t.Message) !void {
        errdefer if (s.vault != null) {
            s.vaultFailed = true;
        };
        if (s.state.outbox.len == 128) return error.OutboxLimitExceeded;
        const name = try s.fileName("outbox", message.id);
        const raw = try j.encodeAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
        try s.makeRoom(raw.len, name);
        try s.write(name, raw);
        errdefer if (s.vault == null) {
            s.dir.deleteFile(s.io, name) catch {};
        };
        var list: std.ArrayList(t.Message) = .empty;
        try list.appendSlice(s.allocator, s.state.outbox);
        var metadata = message;
        metadata.bodyText = "";
        metadata.bodyHtml = null;
        metadata.bodySource = .unknown;
        metadata.attachments = try attachmentMetadata(s.allocator, message.attachments);
        metadata.invitation = null;
        metadata.fixtureRaw = null;
        try list.append(s.allocator, metadata);
        s.state.outbox = list.items;
        try s.save();
    }
    pub fn readOutbox(s: *Store, id: []const u8) !?t.Message {
        return s.readOutboxWithAllocator(s.allocator, id);
    }
    pub fn readOutboxWithAllocator(s: *Store, allocator: std.mem.Allocator, id: []const u8) !?t.Message {
        return s.readOutboxBounded(allocator, id, false);
    }
    pub fn readOutboxExpandedWithAllocator(s: *Store, allocator: std.mem.Allocator, id: []const u8) !?t.Message {
        return s.readOutboxBounded(allocator, id, true);
    }
    fn readOutboxBounded(s: *Store, allocator: std.mem.Allocator, id: []const u8, expanded: bool) !?t.Message {
        for (s.state.outbox) |m| if (std.mem.eql(u8, m.id, id)) {
            const raw = s.readRecord(allocator, try std.fmt.allocPrint(allocator, "outbox-{s}.json", .{hash(id)}), if (expanded) mail_record_bytes else 4 * t.Limits.body_bytes) catch |err| {
                if (!expanded and err == error.CacheLimitExceeded) return composeOnly(m);
                return err;
            };
            const record = try std.json.parseFromSliceLeaky(BodyRecord, allocator, raw, .{ .allocate = .alloc_if_needed });
            if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.message.id, id)) return error.CacheIdentityMismatch;
            if (!expanded and exceedsOrdinaryBody(record.message)) return composeOnly(m);
            var result = try @import("mail_display_fields.zig").canonicalizeMessageDisplay(allocator, record.message);
            result.labels = m.labels;
            result.unread = m.unread;
            return result;
        };
        return null;
    }
    pub fn updateOutboxMetadata(s: *Store, message: t.Message) bool {
        for (s.state.outbox) |*m| if (std.mem.eql(u8, m.id, message.id)) {
            m.labels = message.labels;
            m.unread = message.unread;
            return true;
        };
        return false;
    }
    pub fn nextId(s: *Store, prefix: []const u8) ![]const u8 {
        s.state.serial += 1;
        const key = hash(s.state.account);
        return std.fmt.allocPrint(s.allocator, "{s}-{s}-{d}", .{ prefix, key[0..12], s.state.serial });
    }
    pub fn draft(s: *Store, id: []const u8) !t.Draft {
        for (s.state.drafts) |d| if (std.mem.eql(u8, d.id, id)) {
            const raw = try s.activeDraftBytes(s.allocator, id);
            const result = try std.json.parseFromSliceLeaky(t.Draft, s.allocator, raw, .{ .allocate = .alloc_if_needed });
            if (!std.mem.eql(u8, result.id, id)) return error.CacheIdentityMismatch;
            return result;
        };
        return (try @import("operation_history.zig").draft(s, s.allocator, id)) orelse error.DraftNotFound;
    }
    pub fn activeDraftSourceName(s: *Store, a: std.mem.Allocator, id: []const u8) ![]const u8 {
        if (try @import("draft_pins.zig").load(s, a, id)) |record| return @import("draft_pins.zig").sourceName(a, record);
        return std.fmt.allocPrint(a, "draft-{s}.json", .{hash(id)});
    }
    pub fn activeDraftBytes(s: *Store, a: std.mem.Allocator, id: []const u8) ![]const u8 {
        if (try @import("draft_pins.zig").load(s, a, id)) |record| {
            const name = try @import("draft_pins.zig").sourceName(a, record);
            const raw = if (record.source.len != 0) try s.readHistory(a, name, mail_record_bytes) else try s.readRecord(a, name, mail_record_bytes);
            if (!std.mem.eql(u8, &hash(raw), record.hash)) return error.DraftSourceChanged;
            return raw;
        }
        return s.readRecord(a, try s.fileName("draft", id), mail_record_bytes);
    }
    pub fn activeDraftOwnedRecords(s: *Store, a: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(a, try s.activeDraftSourceName(a, id));
        for (s.state.relatedDraftBlobs) |ref| if (std.mem.eql(u8, ref.draftId, id) and ref.handle.len != 0) try names.append(a, try @import("operation_history.zig").fileName(a, "pins", ref.handle));
        return names.items;
    }
    pub fn activeDraftPinIds(s: *Store, a: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        if (try @import("draft_pins.zig").load(s, a, id)) |record| return record.blobs;
        for (s.state.relatedDraftBlobs) |ref| if (std.mem.eql(u8, ref.draftId, id)) return ref.blobs;
        return &.{};
    }
    fn replaceDraftPins(s: *Store, id: []const u8, handle: ?[]const u8) !void {
        var references: std.ArrayList(DraftBlobReferences) = .empty;
        for (s.state.relatedDraftBlobs) |previous| if (!std.mem.eql(u8, previous.draftId, id)) try references.append(s.allocator, previous);
        if (handle) |value| try references.append(s.allocator, .{ .draftId = try s.allocator.dupe(u8, id), .handle = value });
        s.state.relatedDraftBlobs = references.items;
    }
    pub fn compactDraftIndex(s: *Store) !void {
        if (!@import("send_memory.zig").native) return;
        var needed = false;
        for (s.state.drafts) |draft_value| needed = needed or draft_value.summaryCounts == null;
        if (!needed) return;
        s.beginHistory();
        errdefer s.abortHistory();
        const before = s.state;
        errdefer if (!s.history_publication_started) {
            s.state = before;
        };
        const summaries = try s.allocator.dupe(t.Draft, s.state.drafts);
        var retired: std.ArrayList([]const u8) = .empty;
        for (summaries) |*summary| if (summary.summaryCounts == null) {
            var phase: std.heap.ArenaAllocator = .init(if (@import("send_memory.zig").native) @import("send_memory.zig").allocator() else s.allocator);
            defer phase.deinit();
            const a = phase.allocator();
            const old_pins = try @import("draft_pins.zig").load(s, a, summary.id);
            const raw = try s.activeDraftBytes(a, summary.id);
            const value = try std.json.parseFromSliceLeaky(t.Draft, a, raw, .{ .allocate = .alloc_if_needed });
            if (!std.mem.eql(u8, value.id, summary.id)) return error.CacheIdentityMismatch;
            const pin = try @import("draft_pins.zig").write(s, value, raw, if (old_pins) |old| old.source else "");
            for (s.state.relatedDraftBlobs) |ref| if (std.mem.eql(u8, ref.draftId, summary.id) and ref.handle.len != 0) try retired.append(s.allocator, try @import("operation_history.zig").fileName(s.allocator, "pins", ref.handle));
            try s.replaceDraftPins(summary.id, pin);
            const preview = try draft_summary.fromDraft(a, value);
            summary.* = try std.json.parseFromSliceLeaky(t.Draft, s.allocator, try j.encodeAlloc(s.allocator, preview, .{}), .{ .allocate = .alloc_if_needed });
        };
        s.state.drafts = summaries;
        try s.commitHistory(retired.items);
    }
    pub fn requireActiveDraft(s: *Store, id: []const u8) !void {
        for (s.state.drafts) |draft_value| if (std.mem.eql(u8, draft_value.id, id)) return;
        if (try @import("operation_history.zig").source(s, s.allocator, id) != null) return error.ArchivedDraftReadOnly;
        return error.DraftNotFound;
    }
    pub fn findOperation(s: *Store, a: std.mem.Allocator, id: []const u8) !?Operation {
        return @import("operation_history.zig").operation(s, a, id);
    }
    pub fn compactHistory(s: *Store) !void {
        return @import("operation_history.zig").compact(s, false);
    }
    /// History records are directly addressed and deliberately excluded from
    /// the flat active vault map. Record kind and account remain authenticated.
    pub fn readHistory(s: *Store, a: std.mem.Allocator, name: []const u8, bound: usize) ![]const u8 {
        const handle = try @import("operation_history.zig").handleOf(name);
        if (s.vault != null) {
            // A blob's history lookup can happen while an outgoing encrypted
            // spool holds partial MIME in the account's shared plaintext half.
            // Sequential lookups reuse bounded stack scratch, never the live
            // writer/reader workspace or a retained per-file allocation.
            var workspace: vault_types.StreamWorkspace = undefined;
            defer workspace.wipe();
            return (try s.vaultReady()).readWithWorkspace(a, try vaultKind(name), handle, bound, &workspace) catch |err| return if (err == error.FileNotFound) error.HistoryRecordMissing else err;
        }
        return readPrivate(s.dir, s.io, a, name, bound) catch |err| return if (err == error.FileNotFound) error.HistoryRecordMissing else err;
    }
    pub fn writeHistory(s: *Store, name: []const u8, bytes: []const u8) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        if (s.migration_source) return error.MigrationSourceReadOnly;
        const handle = try @import("operation_history.zig").handleOf(name);
        const bound = if (std.mem.startsWith(u8, name, "history-calendar-")) 256 * 1024 else if (std.mem.startsWith(u8, name, "history-draft-") or std.mem.startsWith(u8, name, "history-active-")) mail_record_bytes else @import("operation_history.zig").page_bytes;
        if (bytes.len > bound) return error.HistoryPageTooLarge;
        // History publication cannot evict or mutate the index it is planning
        // to replace. Reserve the overlap without destructive cache pruning.
        const needed = if (s.vault != null) try vault_types.sealedSize(bytes.len) else bytes.len;
        if (needed > s.options.disk_limit -| try s.diskBytes()) return error.DiskQuotaExceeded;
        try s.history_staged.append(s.allocator, try s.allocator.dupe(u8, name));
        if (s.vault != null) try (try s.vaultReady()).write(try vaultKind(name), handle, bytes, false) else try s.write(name, bytes);
        var phase: std.heap.ArenaAllocator = .init(if (@import("send_memory.zig").native) @import("send_memory.zig").allocator() else s.allocator);
        defer phase.deinit();
        const verified = try s.readHistory(phase.allocator(), name, bound);
        if (!std.mem.eql(u8, bytes, verified)) return error.HistorySourceChanged;
    }
    /// Publish immutable pages owned by a private document. Its atomic file
    /// replacement (or vault index commit) is the ownership boundary.
    pub fn publishDocumentRecords(s: *Store, name: []const u8, bytes: []const u8) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        if (s.history_fault == .before_publication) return error.InjectedHistoryPublication;
        s.history_publication_started = true;
        errdefer if (!s.history_publication_committed) {
            s.history_publication_uncertain = true;
        };
        try s.writeDocument(name, bytes);
        if (s.history_fault == .uncertain_publication) return error.InjectedHistoryPublication;
        s.history_publication_committed = true;
        s.history_staged.clearRetainingCapacity();
        if (s.history_fault == .after_publication) return error.InjectedHistoryPublication;
    }
    pub fn commitHistory(s: *Store, retired: []const []const u8) !void {
        // Once index publication starts, a failed fsync can mean either root
        // is durable. Keep both copies and forbid writes until a fresh open.
        errdefer if (s.history_publication_started and !s.history_publication_committed) {
            s.history_publication_uncertain = true;
        };
        if (s.history_fault == .before_publication) return error.InjectedHistoryPublication;
        const cleanup = try s.allocator.alloc(@import("operation_history.zig").Cleanup, retired.len);
        for (retired, cleanup) |name, *item| {
            item.* = .{ .name = name };
            if (s.vault != null) item.handle = if (@import("operation_history.zig").direct(name)) try s.allocator.dupe(u8, &(try @import("operation_history.zig").handleOf(name)).text()) else if (s.vaultObject(name)) |object| object.handle else if (std.mem.startsWith(u8, name, "blob-")) (try @import("operation_history.zig").findBlob(s, s.allocator, name[5..69])).?.handle else "";
        }
        s.state.history.cleanup = cleanup;
        if (s.vault != null) for (retired) |name| {
            if (!@import("operation_history.zig").direct(name)) try s.removeRecord(name);
        };
        // A failed fsync may still have published the new root. Once saving
        // starts, retain every staged record regardless of the returned error.
        s.history_publication_started = true;
        try s.save();
        if (s.history_fault == .uncertain_publication) return error.InjectedHistoryPublication;
        s.history_publication_committed = true;
        s.history_staged.clearRetainingCapacity();
        if (s.history_fault == .after_publication) return error.InjectedHistoryPublication;
        try s.finishHistoryCleanup();
    }
    pub fn beginHistory(s: *Store) void {
        s.history_staged.clearRetainingCapacity();
        s.history_publication_started = false;
        s.history_publication_committed = false;
    }
    pub fn abortHistory(s: *Store) void {
        if (s.history_publication_started) return;
        for (s.history_staged.items) |name| {
            if (s.vault) |vault| vault.remove(@import("operation_history.zig").handleOf(name) catch continue) catch {} else s.dir.deleteFile(s.io, name) catch {};
        }
        s.history_staged.clearRetainingCapacity();
    }
    pub fn finishHistoryCleanup(s: *Store) !void {
        if (s.history_publication_uncertain) return error.HistoryTransactionUncertain;
        const cleanup = s.state.history.cleanup;
        if (cleanup.len == 0) return;
        for (cleanup) |item| {
            if (s.vault) |vault| {
                if (item.handle.len != 0) {
                    vault.remove(try vault_storage.Handle.parse(item.handle)) catch |err| if (err != error.FileNotFound) return err;
                } else if (@import("operation_history.zig").direct(item.name)) {
                    vault.remove(try @import("operation_history.zig").handleOf(item.name)) catch |err| if (err != error.FileNotFound) return err;
                } else try s.removeRecord(item.name);
            } else s.dir.deleteFile(s.io, item.name) catch |err| if (err != error.FileNotFound) return err;
        }
        if (s.history_fault == .after_cleanup) return error.InjectedHistoryPublication;
        s.state.history.cleanup = &.{};
        errdefer s.state.history.cleanup = cleanup;
        try s.save();
    }
    const DraftImport = struct { sourceId: []const u8, expectedVersion: u64, remoteMessageId: []const u8 };
    pub fn putDraft(s: *Store, input: t.Draft, id: ?[]const u8) !t.Draft {
        return s.putDraftImpl(input, id, null, null, null);
    }
    /// Recovery identity and its new source publish in the same transaction.
    pub fn putPreparedDraft(s: *Store, input: t.Draft, operation_id: []const u8, digest: []const u8) !t.Draft {
        for (s.state.driveSources) |source| if (std.mem.eql(u8, source.operationId, operation_id)) {
            if (!std.mem.eql(u8, source.hash, digest)) return error.OperationConflict;
            const current = try s.draft(source.draftId);
            if (!std.mem.eql(u8, digest, &(try @import("send_outcome.zig").digest(s.allocator, current, s.state.account, null)))) return error.ReviewedDraftChanged;
            return current;
        };
        var retained: std.ArrayList(DriveSource) = .empty;
        for (s.state.driveSources) |source| {
            if (try s.findOperation(s.allocator, source.operationId)) |record| if (!std.mem.eql(u8, record.outcome, "unknown")) continue;
            try retained.append(s.allocator, source);
        }
        if (retained.items.len >= 128) return error.DrivePreparationFull;
        s.state.driveSources = retained.items;
        return s.putDraftImpl(input, null, null, null, .{ .operationId = operation_id, .hash = digest });
    }
    /// Bind a saved source to preparation before progress or provider effects.
    /// Unlike putDraft this does not edit a queued/claimed source.
    pub fn recordPreparedDraft(s: *Store, draft_id: []const u8, operation_id: []const u8, digest: []const u8) !void {
        // A fresh operation must not strand another stopped preparation when
        // this same source later becomes an immutable sent draft. Retry its
        // original operation, or explicitly change/discard the source first.
        for (s.state.driveSources) |source| if (std.mem.eql(u8, source.draftId, draft_id) and !std.mem.eql(u8, source.operationId, operation_id)) {
            if (try s.findOperation(s.allocator, source.operationId) == null) return error.DrivePreparationActive;
        };
        for (s.state.driveSources) |source| if (std.mem.eql(u8, source.operationId, operation_id)) {
            if (!std.mem.eql(u8, source.hash, digest) or !std.mem.eql(u8, source.draftId, draft_id)) return error.OperationConflict;
            return;
        };
        var retained: std.ArrayList(DriveSource) = .empty;
        for (s.state.driveSources) |source| {
            if (try s.findOperation(s.allocator, source.operationId)) |record| if (!std.mem.eql(u8, record.outcome, "unknown")) continue;
            try retained.append(s.allocator, source);
        }
        if (retained.items.len >= 128) return error.DrivePreparationFull;
        try retained.append(s.allocator, .{ .operationId = try s.allocator.dupe(u8, operation_id), .hash = try s.allocator.dupe(u8, digest), .draftId = try s.allocator.dupe(u8, draft_id) });
        const previous = s.state.driveSources;
        errdefer s.state.driveSources = previous;
        s.state.driveSources = retained.items;
        try s.save();
    }
    /// Preserve a known remote copy warning with local recovery content. This
    /// does not import/upload anything or modify the source link's provenance.
    pub fn putRecoveryCopy(s: *Store, input: t.Draft, source_id: []const u8) !t.Draft {
        return s.putDraftImpl(input, null, null, source_id, null);
    }
    /// Publish the new local copy and its duplicate-send guard in one index
    /// commit. The original local source and remote draft are retained.
    pub fn putImportedDraft(s: *Store, input: t.Draft, source_id: []const u8, expected_version: u64, remote_message_id: []const u8) !t.Draft {
        return s.putDraftImpl(input, null, .{ .sourceId = source_id, .expectedVersion = expected_version, .remoteMessageId = remote_message_id }, null, null);
    }
    fn putDraftImpl(s: *Store, input: t.Draft, id: ?[]const u8, imported: ?DraftImport, recovery_source: ?[]const u8, preparation: ?DriveSource) !t.Draft {
        // Import needs the source link through the same atomic publication.
        // Its settled source may otherwise disappear during capacity cleanup.
        const previous_protected = s.history_protected_draft;
        if (id) |draft_id| s.history_protected_draft = draft_id;
        if (imported) |selected| s.history_protected_draft = selected.sourceId;
        if (recovery_source) |source_id| s.history_protected_draft = source_id;
        defer s.history_protected_draft = previous_protected;
        try s.compactHistory();
        var recovery_link: ?@import("draft_link.zig").Link = null;
        if (recovery_source) |source_id| {
            if (try @import("operation_history.zig").gmailLink(s, s.allocator, source_id)) |link| {
                if (link.phase == .unknown) return error.GmailDraftOutcomeUnknown;
                if (link.paused) return error.DraftPausedInGmail;
                if (link.phase != .rejected) {
                    if (s.state.draftLinks.len >= @import("draft_link.zig").limit) return error.DraftLinkLimitReached;
                    recovery_link = link;
                }
            }
        }
        if (imported) |selected| {
            const link_index = @import("draft_link.zig").find(s.state.draftLinks, selected.sourceId) orelse return error.GmailDraftNotLinked;
            try s.state.draftLinks[link_index].expectVersion(selected.expectedVersion);
            if (s.state.draftLinks.len >= @import("draft_link.zig").limit) return error.DraftLinkLimitReached;
            if (s.state.draftLinks[link_index].phase == .unknown or s.state.draftLinks[link_index].remoteDraftId.len == 0) return error.GmailDraftOutcomeUnknown;
            try @import("../bounded.zig").identifier(selected.remoteMessageId);
        }
        if (id) |draft_id| if (@import("draft_link.zig").find(s.state.draftLinks, draft_id)) |index| {
            if (s.state.draftLinks[index].paused) return error.DraftPausedInGmail;
        };
        errdefer if (s.vault != null) {
            s.vaultFailed = true;
        };
        if (input.bodyText.len > t.Limits.compose_body_bytes) return error.BodyTooLarge;
        if (!std.unicode.utf8ValidateSlice(input.bodyText)) return error.InvalidUtf8;
        var d = input;
        d.summaryCounts = null;
        const related = if (d.original) |original| original.resources else &.{};
        if (d.attachments.len > t.Limits.attachments or related.len > t.Limits.related_resources) return error.TooManyAttachments;
        for ([_][]const t.Attachment{ d.attachments, related }) |list| for (list) |attachment| if (attachment.blobId != null) {
            try @import("attachment_blob.zig").verify(s, attachment);
        };
        if (d.from) |sender| if (sender.name.len == 0 and std.ascii.eqlIgnoreCase(sender.address, s.state.account)) {
            d.from = null;
        };
        d.id = if (id) |x| x else try s.nextId("draft");
        var index: ?usize = null;
        for (s.state.drafts, 0..) |old, i| if (std.mem.eql(u8, old.id, d.id)) {
            index = i;
            break;
        };
        if (id != null and index == null) return if (try @import("operation_history.zig").source(s, s.allocator, d.id) != null) error.ArchivedDraftReadOnly else error.DraftNotFound;
        if (index == null and s.state.drafts.len == 128) return error.DraftLimitExceeded;
        var draft_value = try @import("mail_response_value.zig").borrowed(s.allocator, d);
        // Keep an unchanged legacy uncertain draft byte-for-byte compatible.
        if (d.bodyFormat == .plain) _ = draft_value.object.orderedRemove("bodyFormat");
        if (d.includeOriginal) _ = draft_value.object.orderedRemove("includeOriginal");
        if (d.omittedAttachments == 0) _ = draft_value.object.orderedRemove("omittedAttachments");
        const raw = try j.encodeAlloc(s.allocator, draft_value, .{ .emit_null_optional_fields = false });
        if (raw.len > mail_record_bytes) return error.BodyTooLarge;
        const previous = if (index != null) try s.activeDraftBytes(s.allocator, d.id) else null;
        if (previous) |old| for (s.state.operations) |operation| {
            if (std.mem.eql(u8, operation.draftId, d.id) and std.mem.eql(u8, operation.outcome, "unknown") and !std.mem.eql(u8, old, raw)) return error.UnknownOutcome;
        };
        if (previous) |old| if (!std.mem.eql(u8, old, raw)) {
            if (try @import("operation_history.zig").immutableSource(s, d.id)) return error.ArchivedDraftReadOnly;
            try s.cancelDraftQueue(d.id);
            const next_digest = try @import("send_outcome.zig").digest(s.allocator, d, s.state.account, null);
            try @import("drive_retirement.zig").source(s, d.id, &next_digest, null);
            if (@import("draft_link.zig").find(s.state.draftLinks, d.id)) |link_index| {
                s.state.draftLinks[link_index].sendAcknowledgedDigest = "";
                try s.state.draftLinks[link_index].bump();
            }
        };
        try s.finishHistoryCleanup();
        try s.makeRoom(raw.len, "");
        s.beginHistory();
        errdefer s.abortHistory();
        var retired: std.ArrayList([]const u8) = .empty;
        if (index != null) try retired.appendSlice(s.allocator, try s.activeDraftOwnedRecords(s.allocator, d.id));
        const source_handle = try vault_storage.Handle.create(s.io);
        const source_identity = try s.allocator.dupe(u8, &source_handle.text());
        try s.writeHistory(try @import("operation_history.zig").fileName(s.allocator, "active", source_identity), raw);
        const pin = try @import("draft_pins.zig").write(s, d, raw, source_identity);
        const before = s.state;
        errdefer if (!s.history_publication_started) {
            s.state = before;
        };
        try s.replaceDraftPins(d.id, pin);
        const preview = try draft_summary.fromDraft(s.allocator, d);
        const previews = try s.allocator.alloc(t.Draft, s.state.drafts.len + @intFromBool(index == null));
        @memcpy(previews[0..s.state.drafts.len], s.state.drafts);
        previews[index orelse s.state.drafts.len] = preview;
        s.state.drafts = previews;
        if (preparation) |source| {
            var sources: std.ArrayList(DriveSource) = .empty;
            try sources.appendSlice(s.allocator, s.state.driveSources);
            try sources.append(s.allocator, .{ .operationId = try s.allocator.dupe(u8, source.operationId), .hash = try s.allocator.dupe(u8, source.hash), .draftId = try s.allocator.dupe(u8, d.id) });
            s.state.driveSources = sources.items;
        }

        if (imported) |selected| {
            const link_type = @import("draft_link.zig");
            const source_index = link_type.find(s.state.draftLinks, selected.sourceId).?;
            var source_link = s.state.draftLinks[source_index];
            source_link.lastImportedMessageId = try s.allocator.dupe(u8, selected.remoteMessageId);
            source_link.lastImportedDraftId = try s.allocator.dupe(u8, d.id);
            try source_link.bump();
            var copy_link = source_link;
            copy_link.draftId = try s.allocator.dupe(u8, d.id);
            copy_link.remoteMessageId = try s.allocator.dupe(u8, selected.remoteMessageId);
            copy_link.phase = .linked;
            copy_link.version = 1;
            copy_link.paused = false;
            copy_link.possiblySentElsewhere = false;
            copy_link.sendAcknowledgedDigest = "";
            copy_link.errorCode = "";
            copy_link.lastImportedMessageId = "";
            copy_link.lastImportedDraftId = "";
            copy_link.uploadedDigest = try s.allocator.dupe(u8, &(try link_type.contentDigest(s.allocator, d, s.state.account)));
            const new_links = try s.allocator.alloc(link_type.Link, s.state.draftLinks.len + 1);
            @memcpy(new_links[0..s.state.draftLinks.len], s.state.draftLinks);
            new_links[source_index] = source_link;
            new_links[s.state.draftLinks.len] = copy_link;
            s.state.draftLinks = new_links;
        }
        if (recovery_link) |retained| {
            var copy_link = retained;
            copy_link.draftId = try s.allocator.dupe(u8, d.id);
            copy_link.version = 1;
            copy_link.paused = false;
            copy_link.sendAcknowledgedDigest = "";
            copy_link.lastImportedMessageId = "";
            copy_link.lastImportedDraftId = "";
            const new_links = try s.allocator.alloc(@import("draft_link.zig").Link, s.state.draftLinks.len + 1);
            @memcpy(new_links[0..s.state.draftLinks.len], s.state.draftLinks);
            new_links[s.state.draftLinks.len] = copy_link;
            s.state.draftLinks = new_links;
        }
        try s.commitHistory(retired.items);
        return d;
    }
    pub fn discardDraft(s: *Store, id: []const u8) !void {
        const previous_protected = s.history_protected_draft;
        s.history_protected_draft = id;
        defer s.history_protected_draft = previous_protected;
        try s.compactHistory();
        const linked_index = @import("draft_link.zig").find(s.state.draftLinks, id);
        if (linked_index) |index| if (s.state.draftLinks[index].paused) return error.DraftPausedInGmail;
        errdefer if (s.vault != null) {
            s.vaultFailed = true;
        };
        for (s.state.operations) |operation| if (std.mem.eql(u8, operation.draftId, id) and std.mem.eql(u8, operation.outcome, "unknown")) return error.UnknownOutcome;
        for (s.state.drafts, 0..) |draft_value, i| if (std.mem.eql(u8, draft_value.id, id)) {
            if (try @import("operation_history.zig").immutableSource(s, id)) return error.ArchivedDraftReadOnly;
            try s.cancelDraftQueue(id);
            try @import("drive_retirement.zig").source(s, id, null, null);
            try @import("drive_retirement.zig").requireSourceRetired(s, id);
            try s.finishHistoryCleanup();
            s.beginHistory();
            errdefer s.abortHistory();
            const retired = try s.activeDraftOwnedRecords(s.allocator, id);
            // The account has one regenerable browser artifact. Removing a
            // draft must also remove any rendered copy of discarded content.
            if (s.vault == null) s.dir.deleteFile(s.io, "preview.html") catch |err| if (err != error.FileNotFound) return err;
            std.mem.copyForwards(t.Draft, s.state.drafts[i .. s.state.drafts.len - 1], s.state.drafts[i + 1 ..]);
            s.state.drafts = s.state.drafts[0 .. s.state.drafts.len - 1];

            try s.replaceDraftPins(id, null);
            if (linked_index) |index| {
                const links = s.state.draftLinks;
                std.mem.copyForwards(@import("draft_link.zig").Link, links[index .. links.len - 1], links[index + 1 ..]);
                s.state.draftLinks = links[0 .. links.len - 1];
            }
            try s.commitHistory(retired);
            return;
        };
        return if (try @import("operation_history.zig").source(s, s.allocator, id) != null) error.ArchivedDraftReadOnly else error.DraftNotFound;
    }
    fn cancelDraftQueue(s: *Store, id: []const u8) !void {
        for (s.state.sendQueue) |entry| if (std.mem.eql(u8, entry.draftId, id) and (entry.state == .preparing or entry.state == .submitting or entry.state == .unknown)) return error.UnknownOutcome;
        for (s.state.sendQueue) |*entry| if (std.mem.eql(u8, entry.draftId, id) and entry.state == .queued) {
            entry.state = .canceled;
            entry.errorCode = "DraftChanged";
        };
    }
    pub fn clearMail(s: *Store) !void {
        while (s.state.entries.len > 0) try s.evict(0);
        s.state.attachmentReceipts = &.{};
        s.state.generation += 1;
        s.state.historyId = "";
        s.state.quotaFloor = null;
        s.state.indexQuotaFloor = null;
        s.state.quotaDiskLimit = 0;
        s.state.lastSyncAt = 0;
        s.state.views = &.{};
        try s.save();
    }
    pub fn viewKey(a: std.mem.Allocator, account: []const u8, query: []const u8, label: []const u8) ![64]u8 {
        return hash(try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ account, query, label }));
    }
    pub fn findView(s: *Store, key: []const u8) ?*View {
        for (s.state.views) |*view| if (std.mem.eql(u8, view.key, key)) return view;
        return null;
    }
    pub fn recordView(s: *Store, query: []const u8, label: []const u8, label_id: []const u8, messages: []const t.Message, remote_cursor: []const u8, append: bool) !void {
        const key = try viewKey(s.allocator, s.state.account, query, label);
        var view = s.findView(&key);
        if (view == null) {
            var views: std.ArrayList(View) = .empty;
            if (s.state.views.len == 16) try views.appendSlice(s.allocator, s.state.views[1..]) else try views.appendSlice(s.allocator, s.state.views);
            try views.append(s.allocator, .{ .key = try s.allocator.dupe(u8, &key), .query = query, .label = label });
            s.state.views = views.items;
            view = &s.state.views[s.state.views.len - 1];
        }
        var ids: std.ArrayList([]const u8) = .empty;
        if (append) try ids.appendSlice(s.allocator, view.?.ids);
        var incomplete = if (append) view.?.incomplete else false;
        for (messages) |message| {
            incomplete = incomplete or message.metadataPartial;
            if (s.find(message.id) == null) {
                incomplete = true;
                continue;
            }
            var duplicate = false;
            for (ids.items) |id| if (std.mem.eql(u8, id, message.id)) {
                duplicate = true;
                break;
            };
            if (!duplicate and ids.items.len < s.options.metadata_limit) try ids.append(s.allocator, message.id);
        }
        view.?.ids = ids.items;
        view.?.remoteCursor = remote_cursor;
        view.?.labelId = label_id;
        view.?.stale = false;
        view.?.incomplete = incomplete;
    }
    pub fn fixtureRecord(s: *Store, id: []const u8) ?*FixtureProviderRecord {
        if (!s.options.fixtures) return null;
        for (s.state.fixtureProvider) |*record| if (std.mem.eql(u8, record.id, id)) return record;
        return null;
    }
    pub fn setFixtureRecord(s: *Store, id: []const u8, labels: []const []const u8, checkpoint: []const u8, deleted: bool) !void {
        if (!s.options.fixtures) return error.FixtureOnly;
        const record: FixtureProviderRecord = .{ .id = id, .labels = labels, .sourceHistoryId = checkpoint, .deleted = deleted };
        try validateFixtureRecord(record);
        if (s.fixtureRecord(id)) |existing| {
            existing.* = record;
            return;
        }
        if (s.state.fixtureProvider.len == 1024) return error.FixtureProviderLimitExceeded;
        var records: std.ArrayList(FixtureProviderRecord) = .empty;
        try records.appendSlice(s.allocator, s.state.fixtureProvider);
        try records.append(s.allocator, record);
        s.state.fixtureProvider = records.items;
    }
    pub fn clearFixtureRecord(s: *Store, id: []const u8) void {
        for (s.state.fixtureProvider, 0..) |record, i| if (std.mem.eql(u8, record.id, id)) {
            std.mem.copyForwards(FixtureProviderRecord, s.state.fixtureProvider[i .. s.state.fixtureProvider.len - 1], s.state.fixtureProvider[i + 1 ..]);
            s.state.fixtureProvider = s.state.fixtureProvider[0 .. s.state.fixtureProvider.len - 1];
            return;
        };
    }
    pub fn applyFixtureRecord(s: *Store, message: *t.Message) !void {
        if (s.fixtureRecord(message.id)) |record| {
            if (record.deleted) return error.MessageNotFound;
            message.labels = record.labels;
            message.unread = false;
            for (record.labels) |label| if (std.mem.eql(u8, label, "UNREAD")) {
                message.unread = true;
            };
        }
    }

    pub fn applyLabels(s: *Store, id: []const u8, labels: []const []const u8) void {
        const entry = s.find(id) orelse return;
        entry.message.labels = labels;
        entry.message.labelsVerified = true;
        entry.message.unread = false;
        for (labels) |label| if (std.mem.eql(u8, label, "UNREAD")) {
            entry.message.unread = true;
        };
    }

    /// Collection changes invalidate membership queries without touching any
    /// immutable message/body/draft records. Renames retain provider IDs.
    pub fn labelCollectionChanged(s: *Store, id: []const u8, old_name: []const u8, new_name: ?[]const u8) !void {
        const a = s.allocator;
        for (s.state.views) |*view| {
            view.stale = true;
            view.remoteCursor = "";
            if (view.query.len != 0) view.ids = &.{};
            if ((id.len != 0 and (std.mem.eql(u8, view.labelId, id) or std.mem.eql(u8, view.label, id))) or (old_name.len != 0 and std.mem.eql(u8, view.label, old_name))) {
                if (new_name) |name| {
                    if (std.mem.eql(u8, view.label, old_name)) view.label = name;
                    const key = try viewKey(a, s.state.account, view.query, view.label);
                    view.key = try a.dupe(u8, &key);
                } else {
                    // Keep an empty view scoped to its deleted identity. An
                    // empty labelId would turn the old key into All Mail.
                    view.labelId = id;
                    view.ids = &.{};
                }
            }
        }
        if (new_name == null) {
            if (s.options.fixtures) {
                var deleted: std.ArrayList([]const u8) = .empty;
                try deleted.appendSlice(a, s.state.fixtureDeletedLabels);
                var present = false;
                for (deleted.items) |known| present = present or std.mem.eql(u8, known, id);
                if (!present) {
                    if (deleted.items.len >= t.Limits.labels) return error.TooManyDeletedLabels;
                    try deleted.append(a, id);
                }
                s.state.fixtureDeletedLabels = deleted.items;
            }
            for (s.state.entries) |*entry| entry.message.labels = try withoutLabel(a, entry.message.labels, id);
            for (s.state.outbox) |*message| message.labels = try withoutLabel(a, message.labels, id);
            for (s.state.fixtureProvider) |*record| record.labels = try withoutLabel(a, record.labels, id);
            for (s.state.undo) |*receipt| for (receipt.items) |*item| {
                item.addLabels = try withoutLabel(a, item.addLabels, id);
                item.removeLabels = try withoutLabel(a, item.removeLabels, id);
            };
        }
        s.state.generation += 1;
    }
};
fn withoutLabel(a: std.mem.Allocator, ids: []const []const u8, removed: []const u8) ![]const []const u8 {
    var found = false;
    for (ids) |id| found = found or std.mem.eql(u8, id, removed);
    if (!found) return ids;
    var list: std.ArrayList([]const u8) = .empty;
    for (ids) |id| if (!std.mem.eql(u8, id, removed)) try list.append(a, id);
    return list.items;
}
fn validateFixtureRecord(record: FixtureProviderRecord) !void {
    try @import("../bounded.zig").identifier(record.id);
    if (record.labels.len > 64 or record.sourceHistoryId.len == 0 or record.sourceHistoryId.len > 32) return error.InvalidFixtureProviderState;
    for (record.sourceHistoryId) |c| if (!std.ascii.isDigit(c)) return error.InvalidFixtureProviderState;
    for (record.labels) |label| {
        if (label.len > 256) return error.InvalidLabels;
        try @import("recipients.zig").validateHeader(label);
    }
}

fn newestFirst(_: void, left: Entry, right: Entry) bool {
    return left.message.receivedAt > right.message.receivedAt or (left.message.receivedAt == right.message.receivedAt and std.mem.lessThan(u8, left.message.id, right.message.id));
}
fn entriesSorted(entries: []const Entry) bool {
    if (entries.len < 2) return true;
    for (1..entries.len) |i| if (newestFirst({}, entries[i], entries[i - 1])) return false;
    return true;
}
fn entryPosition(entries: []const Entry, entry: Entry) usize {
    var start: usize = 0;
    var end = entries.len;
    while (start < end) {
        const middle = start + (end - start) / 2;
        if (newestFirst({}, entries[middle], entry)) start = middle + 1 else end = middle;
    }
    return start;
}

test "legacy bodies: complete decoder upgrade is atomic and keeps membership and current bodies immutable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-empty", .{tmp.sub_path});
    const old: t.Message = .{ .id = "mail", .threadId = "thread", .bodyText = "Original body", .labels = &.{"INBOX"}, .unread = true };
    {
        var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
        defer store.close();
        try store.put(old, true);
        store.find(old.id).?.bodyDecoderRevision = 0;
        try store.save();
    }
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    try std.testing.expect(store.bodyNeedsUpgrade(old.id));
    const original_hash = try a.dupe(u8, store.find(old.id).?.bodyHash);
    var fresh = old;
    fresh.labels = &.{"SENT"};
    fresh.unread = false;
    fresh.attachments = &.{.{ .id = "empty-part", .filename = "empty.bin", .size = 0 }};
    fresh.metadataPartial = true;
    try std.testing.expect(!try store.putBody(fresh));
    fresh.metadataPartial = false;
    fresh.threadId = "neighbor-thread";
    try std.testing.expectError(error.MessageIdentityMismatch, store.putBody(fresh));
    fresh.threadId = old.threadId;
    const disk_limit = store.options.disk_limit;
    store.options.disk_limit = 1;
    try std.testing.expect(!try store.putBody(fresh));
    try std.testing.expectEqualStrings(original_hash, store.find(old.id).?.bodyHash);
    try std.testing.expectEqualStrings(old.bodyText, (try store.read(old.id)).?.bodyText);
    try std.testing.expect(store.bodyNeedsUpgrade(old.id));
    store.options.disk_limit = disk_limit;
    try std.testing.expect(try store.putBody(fresh));
    try std.testing.expect(!store.bodyNeedsUpgrade(old.id));
    try std.testing.expect(store.find(old.id).?.message.unread);
    try std.testing.expectEqualStrings("INBOX", store.find(old.id).?.message.labels[0]);
    try std.testing.expectEqual(@as(usize, 1), (try store.read(old.id)).?.attachments.len);
    fresh.bodyText = "Later provider version must not replace the current decoded body";
    try std.testing.expect(!try store.putBody(fresh));
    try store.save();
    store.close();
    var reopened = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer reopened.close();
    const retained = (try reopened.read(old.id)).?;
    try std.testing.expectEqualStrings(old.bodyText, retained.bodyText);
    try std.testing.expectEqualStrings("empty.bin", retained.attachments[0].filename);
    try std.testing.expectEqual(@as(usize, 0), retained.attachments[0].size);
    try std.testing.expect(!reopened.bodyNeedsUpgrade(old.id));
}

test "legacy invitations: fetched thread source upgrades only a complete matching calendar body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-invitation", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const old: t.Message = .{ .id = "mail", .threadId = "thread", .bodyText = "Meeting body", .labels = &.{"INBOX"}, .unread = true, .attachments = &.{.{ .id = "calendar", .filename = "invite.ics", .mimeType = "text/calendar" }} };
    try store.put(old, true);
    try std.testing.expect(!store.bodyNeedsUpgrade(old.id));
    var fresh = old;
    fresh.invitation = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n";
    fresh.metadataPartial = true;
    try std.testing.expect(!try store.putBody(fresh));
    fresh.metadataPartial = false;
    fresh.threadId = "other-thread";
    try std.testing.expectError(error.MessageIdentityMismatch, store.putBody(fresh));
    fresh.threadId = old.threadId;
    try std.testing.expect(try store.putBody(fresh));
    const digest = try a.dupe(u8, store.find(old.id).?.bodyHash);
    fresh.bodyText = "Later unrelated replacement";
    try std.testing.expect(!try store.putBody(fresh));
    try std.testing.expectEqualStrings(digest, store.find(old.id).?.bodyHash);
    try store.save();
    store.close();
    var reopened = try Store.openCached(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer reopened.close();
    const retained = (try reopened.read(old.id)).?;
    try std.testing.expectEqualStrings(old.bodyText, retained.bodyText);
    try std.testing.expectEqualStrings(fresh.invitation.?, retained.invitation.?);
    try std.testing.expectEqualStrings("INBOX", reopened.find(old.id).?.message.labels[0]);
    try std.testing.expect(reopened.find(old.id).?.message.unread);
}

test "related originals: body and draft blob references survive metadata rotation and cold reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/protected-blob", .{tmp.sub_path});
    const blob = @import("attachment_blob.zig");
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    var incoming = try blob.Incoming.create(&store, 3);
    defer incoming.close();
    try incoming.write("abc");
    const image = try incoming.commit(&store, .{ .id = "token-A", .filename = "photo.png", .mimeType = "image/png", .size = 3, .contentId = "photo" });
    const original: t.Message = .{ .id = "source", .threadId = "thread", .bodyText = "Old retained body", .bodyHtml = "<img src='cid:photo'>", .attachments = &.{image} };
    try store.put(original, true);
    var latest = original;
    latest.bodyText = "";
    latest.attachments = &.{.{ .id = "token-B", .filename = image.filename, .mimeType = image.mimeType, .size = image.size, .contentId = image.contentId }};
    try store.put(latest, false);
    try store.save();
    store.close();
    store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    try std.testing.expectEqualStrings("token-B", store.find(original.id).?.message.attachments[0].id);
    try std.testing.expect(store.blobReferenced(image.blobId.?));
    try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, image.blobId.?));
    // The same account opened from an older index discovers its immutable
    // body's exact hash-checked references before allowing an explicit delete.
    store.find(original.id).?.bodyBlobIds = null;
    try store.save();
    try std.testing.expect(!store.blobReferenced(image.blobId.?));
    try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, image.blobId.?));
    try std.testing.expect(store.blobReferenced(image.blobId.?));
    const draft = try store.putDraft(.{ .original = .{ .bodyHtml = original.bodyHtml.?, .resources = &.{image} } }, null);
    try std.testing.expect(store.state.drafts[0].original == null);
    try store.invalidate(original.id);
    try store.save();
    store.close();
    store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    try std.testing.expectEqualStrings(image.blobId.?, (try store.draft(draft.id)).original.?.resources[0].blobId.?);
    try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, image.blobId.?));
    var other = try Store.open(std.testing.io, a, root, "neighbor@example.test", .{ .fixtures = true });
    defer other.close();
    try std.testing.expectError(error.AttachmentHandleNotFound, other.putDraft(.{ .original = .{ .bodyHtml = original.bodyHtml.?, .resources = &.{image} } }, null));
    try store.discardDraft(draft.id);
    try blob.discard(&store, image.blobId.?);
    try std.testing.expectError(error.AttachmentHandleNotFound, blob.open(&store, image.blobId.?, image.size));
}

test "related originals: legacy corrupt body prevents deletion without inventing references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/corrupt-refs", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    try store.put(.{ .id = "source", .threadId = "thread", .bodyText = "Old body" }, true);
    store.find("source").?.bodyBlobIds = null;
    try store.write(try store.fileName("mail", "source"), try std.json.Stringify.valueAlloc(a, BodyRecord{ .account = "self@example.test", .message = .{ .id = "source", .threadId = "thread", .bodyText = "Corrupt replacement" } }, .{}));
    try std.testing.expectError(error.AttachmentReferenceUnavailable, store.blobReferencedVerified("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "recipient cache: compact To Cc persistence bounds counts and bytes without truncating full mail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/recipients", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true, .metadata_limit = 2 });
    defer store.close();
    var addresses: [33]t.Address = undefined;
    for (&addresses, 0..) |*address, index| address.* = .{ .address = try std.fmt.allocPrint(a, "person-{d}@example.test", .{index}) };
    try store.put(.{ .id = "broad", .threadId = "broad", .to = &addresses, .cc = &.{.{ .address = "copied@example.test" }}, .bodyText = "Full body", .receivedAt = 2 }, true);
    try std.testing.expectEqual(@as(usize, if (@import("send_memory.zig").native) 33 else 32), store.find("broad").?.message.to.len);
    try std.testing.expectEqual(@as(usize, 33), (try store.read("broad")).?.to.len);
    const long_name: [256]u8 = @splat('N');
    for (&addresses) |*address| address.name = &long_name;
    try store.put(.{ .id = "budget", .threadId = "budget", .to = &addresses, .cc = &addresses, .receivedAt = 1 }, false);
    const budget = store.find("budget").?.message;
    var bytes: usize = 0;
    for (budget.to) |address| bytes += address.address.len + address.name.len;
    for (budget.cc) |address| bytes += address.address.len + address.name.len;
    try std.testing.expect(bytes <= 4096);
    try std.testing.expectEqual(@as(usize, 14), budget.to.len);
    try std.testing.expectEqual(@as(usize, 0), budget.cc.len);
    try store.save();
    store.close();
    var cached = try Store.openCached(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer cached.close();
    try std.testing.expectEqualStrings("person-31@example.test", cached.find("broad").?.message.to[31].address);
    try std.testing.expectEqualStrings("copied@example.test", cached.find("broad").?.message.cc[0].address);
    try std.testing.expectEqual(@as(usize, 0), cached.find("budget").?.bytes);
}

test "mail count eviction removes received-time tail including body and ignores older paging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/private", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 2 });
    defer store.close();
    try store.put(.{ .id = "newest", .threadId = "thread", .receivedAt = 3000, .bodyText = "Newest body" }, true);
    try store.put(.{ .id = "oldest", .threadId = "thread", .receivedAt = 1000, .bodyText = "Oldest body" }, true);
    const old_name = try store.fileName("mail", "oldest");
    try store.put(.{ .id = "middle", .threadId = "thread", .receivedAt = 2000, .bodyText = "Middle body" }, true);
    try std.testing.expectEqual(@as(usize, 2), store.state.entries.len);
    try std.testing.expectEqualStrings("newest", store.state.entries[0].message.id);
    try std.testing.expectEqualStrings("middle", store.state.entries[1].message.id);
    try std.testing.expect(store.find("oldest") == null);
    try std.testing.expectError(error.FileNotFound, store.dir.access(std.testing.io, old_name, .{}));
    try store.put(.{ .id = "ancient", .threadId = "thread", .receivedAt = 0, .bodyText = "Ancient body" }, true);
    try std.testing.expect(store.find("ancient") == null);
    try std.testing.expectEqualStrings("Newest body", (try store.read("newest")).?.bodyText);
    try store.save();
    store.release();
    var first = try Store.openCached(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 2 });
    defer first.close();
    var second = try Store.openCached(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 2 });
    defer second.close();
    try std.testing.expectEqual(@as(usize, 2), second.state.entries.len);
    try std.testing.expectError(error.CacheBusy, Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 2 }));
    first.close();
    second.close();
    var lowered = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 1 });
    defer lowered.close();
    try std.testing.expectEqual(@as(usize, 1), lowered.state.entries.len);
    try std.testing.expectEqualStrings("newest", lowered.state.entries[0].message.id);
    try std.testing.expectEqualStrings("Newest body", (try lowered.read("newest")).?.bodyText);
}

test "message isolation: index byte budget evicts whole oldest mail and preserves wide subjects drafts and receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/wide-index", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true, .metadata_limit = 1000 });
    defer store.close();
    const draft = try store.putDraft(.{ .subject = "Protected draft", .bodyText = "Retain draft bytes" }, null);
    var receipt = [_]Operation{.{ .id = "receipt", .hash = "stable", .outcome = "applied" }};
    store.state.operations = &receipt;
    const subject = try a.alloc(u8, mail_limits.subject_bytes);
    @memset(subject, 's');
    for (0..600) |i| try store.put(.{ .id = try std.fmt.allocPrint(a, "wide-{d:0>3}", .{i}), .threadId = "wide-thread", .receivedAt = @intCast(i), .subject = subject }, false);
    try std.testing.expect(@import("gmail_decode.zig").serializedBytes(store.state) > index_write_bytes);
    try store.save();
    try std.testing.expect(store.state.entries.len < 600 and store.state.entries.len != 0);
    try std.testing.expect(store.find("wide-000") == null);
    try std.testing.expectEqualStrings(subject, store.find("wide-599").?.message.subject);
    try std.testing.expect((try store.dir.statFile(std.testing.io, "index.json", .{})).size < index_write_bytes);
    const retained = store.state.entries.len;
    try std.testing.expect(store.state.indexQuotaFloor != null);
    const floor = store.state.indexQuotaFloor.?;
    try store.put(.{ .id = "wide-000", .threadId = "wide-thread", .receivedAt = 0, .subject = subject, .bodyText = "Do not refetch an evicted old body" }, true);
    try std.testing.expect(store.find("wide-000") == null);
    try std.testing.expect(!try store.bodyAvailable("wide-000"));
    try std.testing.expectEqual(retained, store.state.entries.len);
    try store.save();
    store.close();
    var cached = try Store.openCached(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer cached.close();
    try std.testing.expectEqual(retained, cached.state.entries.len);
    try std.testing.expectEqualStrings(subject, cached.find("wide-599").?.message.subject);
    try std.testing.expectEqualStrings("Retain draft bytes", (try cached.draft(draft.id)).bodyText);
    try std.testing.expectEqualStrings("receipt", cached.state.operations[0].id);
    try std.testing.expectEqual(floor.receivedAt, cached.state.indexQuotaFloor.?.receivedAt);
    try std.testing.expectEqualStrings(floor.id, cached.state.indexQuotaFloor.?.id);
    cached.close();
    var writable = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer writable.close();
    try writable.clearMail();
    try std.testing.expect(writable.state.indexQuotaFloor == null);
    try std.testing.expectEqualStrings("Retain draft bytes", (try writable.draft(draft.id)).bodyText);
}

test "message isolation: oversized protected index does not delete cached bodies or drafts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/protected-index", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    try store.put(.{ .id = "retained", .threadId = "thread", .subject = "Retain complete mail", .bodyText = "Body still available" }, true);
    const draft = try store.putDraft(.{ .subject = "Protected draft", .bodyText = "Retain draft bytes" }, null);
    try store.save();
    const previous_index = try readPrivate(store.dir, std.testing.io, a, "index.json", index_read_bytes);
    const calendar = try a.alloc(u8, 128 * 1024);
    @memset(calendar, 'x');
    var receipts: [64]Operation = undefined;
    for (&receipts, 0..) |*receipt, i| receipt.* = .{ .id = try std.fmt.allocPrint(a, "protected-{d}", .{i}), .hash = "stable", .outcome = "applied", .icalendar = calendar };
    store.state.operations = &receipts;
    try std.testing.expectError(error.CacheLimitExceeded, store.save());
    try std.testing.expectEqual(@as(usize, 1), store.state.entries.len);
    try std.testing.expect(store.state.indexQuotaFloor == null);
    try std.testing.expect(try store.bodyAvailable("retained"));
    try std.testing.expectEqualStrings("Body still available", (try store.read("retained")).?.bodyText);
    try std.testing.expectEqualStrings("Retain draft bytes", (try store.draft(draft.id)).bodyText);
    try std.testing.expectEqual(@as(usize, 64), store.state.operations.len);
    try std.testing.expectEqualStrings(previous_index, try readPrivate(store.dir, std.testing.io, a, "index.json", index_read_bytes));
}

test "refresh lease is exclusive across handles and does not lock cached reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/lease", .{tmp.sub_path});
    var lease = (try RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true })).?;
    defer lease.release();
    try std.testing.expect(try refreshActive(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
    try std.testing.expect((try RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true })) == null);
    var writer = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    try writer.put(.{ .id = "mail", .threadId = "thread", .bodyText = "Cached fictional body" }, true);
    try writer.save();
    writer.close();
    var reader = try Store.openCached(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer reader.close();
    try std.testing.expectEqualStrings("Cached fictional body", (try reader.read("mail")).?.bodyText);
    var other = (try RefreshLease.acquire(std.testing.io, root, "other@example.test", .{ .fixtures = true })).?;
    defer other.release();
    var live = (try RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = false })).?;
    defer live.release();
    // Independent literal kernel/libc flag expectations for supported hosts.
    if (@import("builtin").os.tag == .linux) {
        const fd_flags = std.os.linux.fcntl(lease.file.handle, 1, 0);
        try std.testing.expectEqual(@as(usize, 1), fd_flags);
        const open_flags = std.os.linux.fcntl(lease.file.handle, 3, 0);
        try std.testing.expect(open_flags & 2048 != 0);
    } else if (@import("builtin").os.tag == .macos) {
        try std.testing.expectEqual(@as(c_int, 1), std.c.fcntl(lease.file.handle, std.c.F.GETFD));
        const open_flags = std.c.fcntl(lease.file.handle, std.c.F.GETFL);
        try std.testing.expect(open_flags >= 0 and open_flags & 4 != 0);
    }
    lease.release();
    try std.testing.expect(!try refreshActive(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
}

test "refresh lease rejects symlink directory fifo and public mode before blocking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/special", .{tmp.sub_path});
    const dir = try openAccountDirectory(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }, true);
    defer dir.close(std.testing.io);
    try dir.symLink(std.testing.io, "unrelated", "refresh.lock", .{});
    try std.testing.expectError(error.InsecureRefreshLease, RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
    try dir.deleteFile(std.testing.io, "refresh.lock");
    try dir.createDir(std.testing.io, "refresh.lock", .fromMode(0o700));
    try std.testing.expectError(error.InsecureRefreshLease, refreshActive(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
    try dir.deleteDir(std.testing.io, "refresh.lock");
    if (@import("builtin").os.tag == .macos) {
        const Native = struct {
            extern "c" fn mkfifoat(fd: c_int, path: [*:0]const u8, mode: std.c.mode_t) c_int;
        };
        try std.testing.expectEqual(@as(c_int, 0), Native.mkfifoat(dir.handle, "refresh.lock", 0o600));
    } else {
        const made = std.os.linux.mknodat(dir.handle, "refresh.lock", 0o010000 | 0o600, 0);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(made));
    }
    try std.testing.expectError(error.InsecureRefreshLease, RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
    try dir.deleteFile(std.testing.io, "refresh.lock");
    const file = try dir.createFile(std.testing.io, "refresh.lock", .{ .permissions = .fromMode(0o644) });
    // Creation is affected by the caller's umask; exercise the unsafe mode explicitly.
    try file.setPermissions(std.testing.io, .fromMode(0o644));
    file.close(std.testing.io);
    try std.testing.expectError(error.InsecureRefreshLease, RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
}
fn closeRawPair(pair: *[2]std.os.linux.fd_t) void {
    for (pair) |*fd| if (fd.* >= 0) {
        _ = std.os.linux.close(fd.*);
        fd.* = -1;
    };
}
test "refresh lease kernel ownership releases after a reaped child exits" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/crash", .{tmp.sub_path});
    var lease = (try RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true })).?;
    defer lease.release();
    var ready: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&ready, .{ .CLOEXEC = true })));
    defer closeRawPair(&ready);
    var done: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&done, .{ .CLOEXEC = true })));
    defer closeRawPair(&done);
    const forked = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(forked));
    if (forked == 0) {
        // Only raw kernel operations after fork: no allocation, locks or std.Io.
        _ = linux.close(ready[0]);
        _ = linux.close(done[1]);
        var byte: [1]u8 = .{1};
        _ = linux.write(ready[1], &byte, 1);
        _ = linux.read(done[0], &byte, 1);
        linux.exit(37);
    }
    var child: linux.pid_t = @intCast(forked);
    defer if (child > 0) {
        _ = linux.kill(child, linux.SIG.KILL);
        var status: i32 = 0;
        while (linux.errno(linux.wait4(child, &status, 0, null)) == .INTR) {}
    };
    _ = linux.close(ready[1]);
    ready[1] = -1;
    _ = linux.close(done[0]);
    done[0] = -1;
    // Parent drops its inherited open-file description WITHOUT unlocking the
    // child's lease. Child exit must close the final descriptor and release it.
    lease.file.close(std.testing.io);
    lease.dir.close(std.testing.io);
    lease.closed = true;
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), linux.read(ready[0], &byte, 1));
    try std.testing.expect(try refreshActive(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
    try std.testing.expect((try RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true })) == null);
    try std.testing.expectEqual(@as(usize, 1), linux.write(done[1], &byte, 1));
    var status: i32 = 0;
    var waited: usize = undefined;
    while (true) {
        waited = linux.wait4(child, &status, 0, null);
        if (linux.errno(waited) != .INTR) break;
    }
    try std.testing.expectEqual(@as(usize, @intCast(child)), waited);
    child = 0;
    try std.testing.expectEqual(@as(i32, 37 << 8), status);
    try std.testing.expect(!try refreshActive(std.testing.io, root, "fictional@example.test", .{ .fixtures = true }));
    var recovered = (try RefreshLease.acquire(std.testing.io, root, "fictional@example.test", .{ .fixtures = true })).?;
    recovered.release();
}

test "mail display cache: native warm reads normalize legacy names without rewriting immutable bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-display", .{tmp.sub_path});
    var participants: [40]t.Address = undefined;
    for (&participants, 0..) |*address, i| address.* = .{ .address = try std.fmt.allocPrint(a, "Recipient-{d}@example.test", .{i}), .name = "Legacy\tRecipient\n" };
    const legacy: t.Message = .{ .id = "legacy", .threadId = "thread", .from = .{ .address = "Sender@EXAMPLE.TEST", .name = "Old\tSender\n" }, .to = &participants, .cc = &.{.{ .address = "Cc@example.test", .name = "Copied\tPerson" }}, .replyTo = &.{.{ .address = "Reply@example.test", .name = "Actual\nReply" }}, .subject = "Legacy\nSubject", .bodyText = "Full immutable body\nwith\ttabs.", .references = "<root@example.test>\t<opaque\u{202e}@example.test>", .messageId = "<source@example.test>", .sentDate = "Tue,\t13 Oct 2026 09:00:00 +0000", .attachments = &.{.{ .id = "file", .filename = "Legacy\nfile.txt" }} };
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    try store.put(legacy, true);
    try store.save();
    const saved_hash = store.find(legacy.id).?.bodyHash;
    const generation = store.state.generation;
    const filename = try store.fileName("mail", legacy.id);
    const original_file = try readPrivate(store.dir, std.testing.io, a, filename, mail_record_bytes);
    store.close();
    var cached = try Store.openCached(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer cached.close();
    for (0..2) |_| {
        const message = (try cached.read(legacy.id)).?;
        try std.testing.expectEqualStrings("Old Sender ", message.from.name);
        try std.testing.expectEqualStrings("Legacy Subject", message.subject);
        try std.testing.expectEqualStrings("Actual Reply", message.replyTo[0].name);
        try std.testing.expectEqualStrings("Legacy file.txt", message.attachments[0].filename);
        try std.testing.expectEqual(@as(usize, 40), message.to.len);
        for (message.to, legacy.to) |actual, expected| {
            try std.testing.expectEqualStrings("Legacy Recipient ", actual.name);
            try std.testing.expectEqualStrings(expected.address, actual.address);
            _ = try @import("recipients.zig").formatIncomingDisplay(a, actual.address, actual.name);
        }
        try std.testing.expectEqualStrings(legacy.from.address, message.from.address);
        try std.testing.expectEqualStrings(legacy.replyTo[0].address, message.replyTo[0].address);
        try std.testing.expectEqualStrings(legacy.references, message.references);
        try std.testing.expectEqualStrings(legacy.sentDate.?, message.sentDate.?);
        try std.testing.expectEqualStrings(legacy.bodyText, message.bodyText);
        const quoted = try @import("conversation_draft.zig").quote(a, message.bodyText);
        try std.testing.expectEqualStrings("\n\n> Full immutable body\n> with\ttabs.\n", quoted);
    }
    try std.testing.expectEqualStrings(saved_hash, cached.find(legacy.id).?.bodyHash);
    try std.testing.expectEqualStrings("", cached.find(legacy.id).?.bodyError);
    try std.testing.expectEqual(generation, cached.state.generation);
    try std.testing.expectEqualStrings(original_file, try readPrivate(cached.dir, std.testing.io, a, filename, mail_record_bytes));
}

test "body repair preserves valid immutable bytes and rejects wrong-account data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/repair", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    const m: t.Message = .{ .id = "m", .threadId = "t", .bodyText = "Immutable body", .labels = &.{ "INBOX", "UNREAD" }, .unread = true };
    try store.put(m, true);
    try store.save();
    const gen = store.state.generation;
    const original = store.find("m").?.bodyHash;
    var changed = m;
    changed.bodyText = "Other body";
    changed.labels = &.{"INBOX"};
    changed.unread = false;
    store.applyLabels("m", changed.labels);
    try std.testing.expect(!try store.putBody(changed));
    try std.testing.expectEqualStrings(original, store.find("m").?.bodyHash);
    try std.testing.expectEqual(gen, store.state.generation);
    const name = try store.fileName("mail", "m");
    try store.dir.deleteFile(std.testing.io, name);
    try std.testing.expect(!try store.bodyAvailable("m"));
    try std.testing.expect((try store.read("m")) == null);
    try std.testing.expect(try store.putBody(m));
    const corrupt = try std.json.Stringify.valueAlloc(a, BodyRecord{ .account = store.state.account, .message = changed }, .{});
    try store.write(name, corrupt);
    try std.testing.expect((try store.read("m")) == null);
    try std.testing.expect(try store.putBody(m));
    const foreign = try std.json.Stringify.valueAlloc(a, BodyRecord{ .account = "other@example.test", .message = m }, .{});
    try store.write(name, foreign);
    try std.testing.expectError(error.CacheIdentityMismatch, store.read("m"));
    try std.testing.expect(!try store.putBody(.{ .id = "absent", .threadId = "t", .bodyText = "Never insert" }));
    try std.testing.expect(store.find("absent") == null);
}

test "message isolation: unknown metadata preserves labels and a final body refusal survives reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/message-isolation", .{tmp.sub_path});
    {
        var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
        defer store.close();
        try store.put(.{ .id = "odd", .threadId = "thread", .labels = &.{ "INBOX", "UNREAD" }, .unread = true, .receivedAt = 20 }, false);
        const partial: t.Message = .{ .id = "odd", .threadId = "thread", .labelsVerified = false, .metadataPartial = true, .decodeWarning = "JsonTooManyTokens", .bodyCacheError = "JsonTooManyTokens" };
        try store.put(partial, true);
        const entry = store.find("odd").?;
        try std.testing.expectEqual(@as(usize, 2), entry.message.labels.len);
        try std.testing.expectEqualStrings("INBOX", entry.message.labels[0]);
        try std.testing.expect(entry.message.unread and !entry.message.labelsVerified);
        try std.testing.expectEqual(@as(i64, 20), entry.message.receivedAt);
        try std.testing.expectEqual(@as(usize, 0), entry.bytes);
        try std.testing.expectEqualStrings("JsonTooManyTokens", entry.bodyError);
        try store.save();
    }
    var reopened = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer reopened.close();
    const message = reopened.refusedMessage("odd").?;
    try std.testing.expectEqualStrings("JsonTooManyTokens", message.bodyCacheError);
    try std.testing.expect(message.metadataPartial and !message.labelsVerified);
    try std.testing.expect((try reopened.read("odd")) == null);
}

test "message isolation: transient thread placeholders preserve verified metadata and allow individual bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/thread-placeholder", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const subject = try a.alloc(u8, 4000);
    @memset(subject, 's');
    const original: t.Message = .{ .id = "existing", .threadId = "thread", .from = .{ .address = "sender@example.test" }, .subject = subject, .bodyText = "Retained body", .labels = &.{"INBOX"} };
    try store.put(original, true);
    const placeholder = try @import("gmail_decode.zig").threadPlaceholder(original, a);
    try store.put(placeholder, true);
    try std.testing.expectEqualStrings(subject, store.find(original.id).?.message.subject);
    try std.testing.expectEqualStrings(original.from.address, store.find(original.id).?.message.from.address);
    try std.testing.expectEqualStrings("", store.find(original.id).?.message.decodeWarning);
    try std.testing.expectEqualStrings("Retained body", (try store.read(original.id)).?.bodyText);
    var metadata_placeholder = placeholder;
    metadata_placeholder.bodyCacheError = "";
    metadata_placeholder.decodeWarning = "MetadataBudgetExceeded";
    try store.put(metadata_placeholder, false);
    try std.testing.expectEqualStrings(subject, store.find(original.id).?.message.subject);
    try std.testing.expectEqualStrings(original.from.address, store.find(original.id).?.message.from.address);
    try std.testing.expect(store.find(original.id).?.message.labelsVerified);
    metadata_placeholder.labelsVerified = false;
    metadata_placeholder.labels = &.{};
    try store.put(metadata_placeholder, false);
    try std.testing.expect(!store.find(original.id).?.message.labelsVerified);
    try std.testing.expectEqualStrings("INBOX", store.find(original.id).?.message.labels[0]);
    try std.testing.expect(store.refusedMessage(original.id) == null);
    try std.testing.expectEqualStrings("Retained body", (try store.read(original.id)).?.bodyText);
    var new_placeholder = placeholder;
    new_placeholder.id = "new";
    try store.put(new_placeholder, true);
    try std.testing.expect(store.find("new") != null);
    try std.testing.expect(store.refusedMessage("new") == null);
    var independent = original;
    independent.id = "new";
    try std.testing.expect(try store.putBody(independent));
    try std.testing.expectEqualStrings("Retained body", (try store.read("new")).?.bodyText);
}

test "label collection: deletion preserves immutable bodies drafts outbox and independent labels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/label-collection", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    const message: t.Message = .{ .id = "retained", .threadId = "thread", .bodyText = "Immutable café body 🌋", .labels = &.{ "INBOX", "UNREAD", "Label_7", "Label_other" }, .unread = true };
    try store.put(message, true);
    try store.putOutbox(.{ .id = "outgoing", .threadId = "outgoing-thread", .bodyText = "Immutable outgoing body", .labels = &.{ "SENT", "Label_7" } });
    const draft = try store.putDraft(.{ .bodyText = "Keep this draft" }, null);
    try store.setFixtureRecord("remote-only", &.{ "INBOX", "Label_7", "STARRED" }, "1", false);
    const undo_items = try a.dupe(UndoItem, &.{.{ .messageId = "retained", .addLabels = &.{ "Label_7", "UNREAD" }, .removeLabels = &.{ "Label_7", "STARRED" }, .outcome = "applied" }});
    store.state.undo = try a.dupe(Undo, &.{.{ .token = "undo", .items = undo_items }});
    try store.recordView("", "Project", "Label_7", &.{message}, "opaque-remote-cursor", false);
    const body_hash = try a.dupe(u8, store.find("retained").?.bodyHash);
    const body_bytes = store.find("retained").?.bytes;
    try store.labelCollectionChanged("Label_7", "Project", "Renamed");
    try std.testing.expectEqualStrings("Label_7", store.find("retained").?.message.labels[2]);
    try std.testing.expectEqualStrings("Renamed", store.state.views[0].label);
    try std.testing.expectEqualStrings("Label_7", store.state.views[0].labelId);
    try store.labelCollectionChanged("Label_7", "Renamed", null);
    try std.testing.expectEqual(@as(usize, 1), store.state.entries.len);
    try std.testing.expectEqualStrings(body_hash, store.find("retained").?.bodyHash);
    try std.testing.expectEqual(body_bytes, store.find("retained").?.bytes);
    try std.testing.expectEqualStrings("Immutable café body 🌋", (try store.read("retained")).?.bodyText);
    try std.testing.expectEqualStrings("Keep this draft", (try store.draft(draft.id)).bodyText);
    try std.testing.expectEqualStrings("Immutable outgoing body", (try store.readOutbox("outgoing")).?.bodyText);
    try std.testing.expectEqual(@as(usize, 3), store.find("retained").?.message.labels.len);
    try std.testing.expectEqualStrings("Label_other", store.find("retained").?.message.labels[2]);
    try std.testing.expect(store.find("retained").?.message.unread);
    try std.testing.expectEqual(@as(usize, 1), store.state.outbox[0].labels.len);
    try std.testing.expectEqualStrings("SENT", store.state.outbox[0].labels[0]);
    try std.testing.expectEqual(@as(usize, 2), store.fixtureRecord("remote-only").?.labels.len);
    try std.testing.expectEqualStrings("STARRED", store.fixtureRecord("remote-only").?.labels[1]);
    try std.testing.expectEqualStrings("UNREAD", store.state.undo[0].items[0].addLabels[0]);
    try std.testing.expectEqualStrings("STARRED", store.state.undo[0].items[0].removeLabels[0]);
    try std.testing.expectEqualStrings("Label_7", store.state.fixtureDeletedLabels[0]);
    try std.testing.expect(store.state.views[0].stale and store.state.views[0].ids.len == 0 and store.state.views[0].remoteCursor.len == 0);
    try store.save();
}
test "quota refuses oversized writes and protected oldest replacement before destructive eviction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/quota", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .disk_limit = 64 * 1024 });
    defer store.close();
    for (0..3) |i| try store.put(.{ .id = try std.fmt.allocPrint(a, "m{d}", .{i}), .threadId = "t", .bodyText = "Body", .receivedAt = @intCast(i) }, true);
    try store.save();
    const before = try store.diskBytes();
    try std.testing.expectError(error.DiskQuotaExceeded, store.makeRoom(64 * 1024 + 1, "index.json"));
    try std.testing.expectEqual(before, try store.diskBytes());
    try std.testing.expectEqual(@as(usize, 3), store.state.entries.len);
    try std.testing.expectError(error.DiskQuotaExceeded, store.makeRoom(64 * 1024, try store.fileName("mail", "m0")));
    try std.testing.expectEqual(before, try store.diskBytes());
    try std.testing.expectEqual(@as(usize, 3), store.state.entries.len);
}

test "quota shrinking a metadata-only index retains the newest head and persists across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/shrinking-index", .{tmp.sub_path});
    const account = "fictional@example.test";
    const quota = 131072;
    var original = try Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
    defer original.close();
    const subject = try a.alloc(u8, 1000);
    @memset(subject, 's');
    for (0..60) |i| try original.put(.{ .id = try std.fmt.allocPrint(a, "row-{d:0>2}", .{i}), .threadId = "thread", .receivedAt = @intCast(i), .subject = subject }, false);
    var messages: [60]t.Message = undefined;
    for (original.state.entries, &messages) |entry, *message| message.* = entry.message;
    try original.recordView("subject:\"fictional\"", "", "", &messages, "", false);
    try original.save();
    const old_index_bytes = try original.size("index.json");
    try std.testing.expect(old_index_bytes < quota);
    var count_trimmed = original.state;
    count_trimmed.entries = count_trimmed.entries[0..30];
    // Even with every view ID removed, the initial replacement cannot fit
    // alongside the old file. Further metadata-only eviction is necessary.
    count_trimmed.views = &.{};
    try std.testing.expect(old_index_bytes + @import("gmail_decode.zig").serializedBytes(count_trimmed) > quota);
    original.close();

    var lowered = try Store.open(std.testing.io, a, root, account, .{ .fixtures = true, .metadata_limit = 30, .disk_limit = quota, .metadata_limit_set = true, .disk_limit_set = true });
    defer lowered.close();
    const retained = lowered.state.entries.len;
    try std.testing.expect(retained > 0 and retained < 30);
    try std.testing.expectEqual(@as(usize, 30), lowered.state.metadataPolicy);
    try std.testing.expectEqual(@as(usize, quota), lowered.state.diskPolicy);
    try std.testing.expect(old_index_bytes + try lowered.size("index.json") <= quota);
    try std.testing.expect(try lowered.diskBytes() <= quota);
    try std.testing.expect(lowered.state.views[0].incomplete);
    try std.testing.expectEqual(retained, lowered.state.views[0].ids.len);
    for (lowered.state.entries, 0..) |entry, i| {
        const expected = try std.fmt.allocPrint(a, "row-{d:0>2}", .{59 - i});
        try std.testing.expectEqualStrings(expected, entry.message.id);
        try std.testing.expectEqualStrings(expected, lowered.state.views[0].ids[i]);
        try std.testing.expectEqualStrings(subject, entry.message.subject);
    }
    const saved = try readPrivate(lowered.dir, std.testing.io, a, "index.json", index_read_bytes);
    lowered.close();
    for (0..2) |_| {
        var reopened = try Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
        defer reopened.close();
        try std.testing.expectEqual(retained, reopened.state.entries.len);
        try std.testing.expectEqual(@as(usize, 30), reopened.options.metadata_limit);
        try std.testing.expectEqual(@as(usize, quota), reopened.options.disk_limit);
        try std.testing.expectEqualStrings("row-59", reopened.state.entries[0].message.id);
        try std.testing.expectEqualStrings(saved, try readPrivate(reopened.dir, std.testing.io, a, "index.json", index_read_bytes));
    }
}

test "quota impossible protected index overlap preserves mail drafts outbox receipts and saved policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/protected-overlap", .{tmp.sub_path});
    const account = "fictional@example.test";
    const quota = 131072;
    var original = try Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
    defer original.close();
    const draft_body = try a.alloc(u8, 80 * 1024);
    @memset(draft_body, 'd');
    const draft = try original.putDraft(.{ .subject = "Protected draft", .bodyText = draft_body }, null);
    const sent_body = try a.alloc(u8, 8 * 1024);
    @memset(sent_body, 'o');
    try original.putOutbox(.{ .id = "sent", .threadId = "sent-thread", .bodyText = sent_body });
    const receipt = try a.alloc(u8, 20 * 1024);
    @memset(receipt, 'r');
    original.state.operations = try a.dupe(Operation, &.{.{ .id = "protected-operation", .hash = "stable", .outcome = "applied", .icalendar = receipt }});
    try original.put(.{ .id = "older", .threadId = "thread", .receivedAt = 1, .bodyText = "Older immutable body" }, true);
    try original.put(.{ .id = "newer", .threadId = "thread", .receivedAt = 2, .bodyText = "Newer immutable body" }, true);
    try original.save();
    const owned_source = try original.activeDraftOwnedRecords(a, draft.id);
    const names = [_][]const u8{ "index.json", try original.fileName("mail", "older"), try original.fileName("mail", "newer"), owned_source[0], owned_source[1], try original.fileName("outbox", "sent") };
    var saved: [names.len][]const u8 = undefined;
    for (names, &saved) |name, *raw| raw.* = try readPrivate(original.dir, std.testing.io, a, name, index_read_bytes);
    const used = try original.diskBytes();
    const without_mail = used - saved[1].len - saved[2].len;
    var protected = original.state;
    protected.entries = &.{};
    const protected_index_bytes = @import("gmail_decode.zig").serializedBytes(protected);
    // Final protected data would fit, but the old and new index must coexist.
    try std.testing.expect(without_mail - saved[0].len + protected_index_bytes < quota);
    try std.testing.expect(without_mail + protected_index_bytes > quota);
    const saved_policy = original.state.diskPolicy;
    const saved_metadata_policy = original.state.metadataPolicy;
    original.close();

    var other = try Store.open(std.testing.io, a, root, "other@example.test", .{ .fixtures = true });
    defer other.close();
    try other.put(.{ .id = "older", .threadId = "other-thread", .bodyText = "Other account body" }, true);
    try other.save();
    const other_index = try readPrivate(other.dir, std.testing.io, a, "index.json", index_read_bytes);
    other.close();

    try std.testing.expectError(error.DiskQuotaExceeded, Store.open(std.testing.io, a, root, account, .{ .fixtures = true, .metadata_limit = 1, .disk_limit = quota, .metadata_limit_set = true, .disk_limit_set = true }));
    var preserved = try Store.openCached(std.testing.io, a, root, account, .{ .fixtures = true });
    defer preserved.close();
    try std.testing.expectEqual(saved_policy, preserved.options.disk_limit);
    try std.testing.expectEqual(saved_metadata_policy, preserved.options.metadata_limit);
    try std.testing.expectEqual(@as(usize, 2), preserved.state.entries.len);
    try std.testing.expectEqual(used, try preserved.diskBytes());
    for (names, saved) |name, raw| try std.testing.expectEqualStrings(raw, try readPrivate(preserved.dir, std.testing.io, a, name, index_read_bytes));
    try std.testing.expectEqualStrings(draft_body, (try preserved.draft(draft.id)).bodyText);
    try std.testing.expectEqualStrings(sent_body, (try preserved.readOutbox("sent")).?.bodyText);
    try std.testing.expectEqualStrings(receipt, preserved.state.operations[0].icalendar);
    var other_reopened = try Store.openCached(std.testing.io, a, root, "other@example.test", .{ .fixtures = true });
    defer other_reopened.close();
    try std.testing.expectEqualStrings(other_index, try readPrivate(other_reopened.dir, std.testing.io, a, "index.json", index_read_bytes));
    try std.testing.expectEqualStrings("Other account body", (try other_reopened.read("older")).?.bodyText);
}

test "persisted cache policy is shared by default readers and automatic writers while explicit reset works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/policy", .{tmp.sub_path});
    {
        var configured = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 40, .disk_limit = 131072, .metadata_limit_set = true, .disk_limit_set = true });
        defer configured.close();
        try std.testing.expectEqual(@as(usize, 40), configured.state.metadataPolicy);
    }
    {
        var reader = try Store.openCached(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
        defer reader.close();
        try std.testing.expectEqual(@as(usize, 40), reader.options.metadata_limit);
        try std.testing.expectEqual(@as(usize, 131072), reader.options.disk_limit);
    }
    {
        var automatic = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 2000, .metadata_limit_set = true, .use_persisted_policy = true });
        defer automatic.close();
        try std.testing.expectEqual(@as(usize, 40), automatic.options.metadata_limit);
    }
    {
        var reset = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit_set = true, .disk_limit_set = true });
        defer reset.close();
        try std.testing.expectEqual(@as(usize, 2000), reset.options.metadata_limit);
        try std.testing.expectEqual(@as(usize, 268435456), reset.options.disk_limit);
    }
}

test "owned index strings preserve escaped metadata body references outbox and fixture state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var lifetime = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer lifetime.deinit();
    const a = lifetime.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/borrowed-index", .{tmp.sub_path});
    {
        var seed = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer seed.deinit();
        const sa = seed.allocator();
        var store = try Store.open(std.testing.io, sa, root, "fictional@example.test", .{ .fixtures = true });
        defer store.close();
        const references = try sa.alloc(u8, 8192);
        @memset(references, 'x');
        try store.put(.{ .id = "retained-body", .threadId = "thread", .subject = "Quoted \"subject\" café\nSecond line", .references = references, .bodyText = "Literal retained body\n", .receivedAt = 10, .labels = &.{"INBOX"} }, true);
        try store.putOutbox(.{ .id = "sent-fixture", .threadId = "sent-thread", .subject = "Literal sent subject", .bodyText = "Literal outbox body\n", .receivedAt = 20, .labels = &.{"SENT"} });
        try store.setFixtureRecord("provider-fixture", &.{ "INBOX", "STARRED" }, "1234", false);
        try store.save();
    }
    var snapshot = try Store.openCached(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer snapshot.close();
    // The seed arena is gone and unrelated heap and stack storage change.
    const unrelated = try a.alloc(u8, 32 * 1024);
    @memset(unrelated, 'z');
    var stack_noise: [8192]u8 = undefined;
    @memset(&stack_noise, 'q');
    std.mem.doNotOptimizeAway(&stack_noise);
    const entry = snapshot.find("retained-body").?;
    try std.testing.expectEqualStrings("Quoted \"subject\" café\nSecond line", entry.message.subject);
    try std.testing.expectEqual(@as(usize, 8192), entry.message.references.len);
    for (entry.message.references) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
    try std.testing.expectEqual(@as(usize, 64), entry.bodyHash.len);
    try std.testing.expectEqualStrings("Literal retained body\n", (try snapshot.read("retained-body")).?.bodyText);
    try std.testing.expectEqualStrings("Literal sent subject", snapshot.state.outbox[0].subject);
    try std.testing.expectEqualStrings("Literal outbox body\n", (try snapshot.readOutbox("sent-fixture")).?.bodyText);
    const record = snapshot.fixtureRecord("provider-fixture").?;
    try std.testing.expectEqualStrings("1234", record.sourceHistoryId);
    try std.testing.expectEqualStrings("STARRED", record.labels[1]);
}

test "sorted insertion replacement ties legacy fallback and lower count retain body references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ordered-index", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 3 });
    defer store.close();
    try store.put(.{ .id = "c", .threadId = "thread", .receivedAt = 10, .bodyText = "Body C" }, true);
    try store.put(.{ .id = "a", .threadId = "thread", .receivedAt = 10, .bodyText = "Body A" }, true);
    try store.put(.{ .id = "b", .threadId = "thread", .receivedAt = 20, .bodyText = "Body B" }, true);
    for ([_][]const u8{ "b", "a", "c" }, store.state.entries) |expected, entry| try std.testing.expectEqualStrings(expected, entry.message.id);
    const hash_c = try a.dupe(u8, store.find("c").?.bodyHash);
    const hash_b = try a.dupe(u8, store.find("b").?.bodyHash);
    try store.put(.{ .id = "d", .threadId = "thread", .receivedAt = 5, .bodyText = "Never retained" }, true);
    try std.testing.expect(store.find("d") == null);
    try store.put(.{ .id = "c", .threadId = "thread", .receivedAt = 30, .subject = "Changed metadata" }, false);
    for ([_][]const u8{ "c", "b", "a" }, store.state.entries) |expected, entry| try std.testing.expectEqualStrings(expected, entry.message.id);
    try std.testing.expectEqualStrings(hash_c, store.find("c").?.bodyHash);
    try store.put(.{ .id = "c", .threadId = "thread", .receivedAt = 10 }, false);
    try store.put(.{ .id = "a", .threadId = "thread", .receivedAt = 20 }, false);
    for ([_][]const u8{ "a", "b", "c" }, store.state.entries) |expected, entry| try std.testing.expectEqualStrings(expected, entry.message.id);
    try std.testing.expectEqualStrings("Body C", (try store.read("c")).?.bodyText);
    try store.put(.{ .id = "d", .threadId = "thread", .receivedAt = 20, .bodyText = "Body D" }, true);
    for ([_][]const u8{ "a", "b", "d" }, store.state.entries) |expected, entry| try std.testing.expectEqualStrings(expected, entry.message.id);
    try std.testing.expect(store.find("c") == null);
    try std.testing.expectEqualStrings(hash_b, store.find("b").?.bodyHash);
    // An unordered legacy vector still receives the same canonical order.
    std.mem.reverse(Entry, store.state.entries);
    try store.save();
    store.close();
    var legacy = try Store.openCached(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer legacy.close();
    for ([_][]const u8{ "a", "b", "d" }, legacy.state.entries) |expected, entry| try std.testing.expectEqualStrings(expected, entry.message.id);
    legacy.close();
    var lowered = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 2 });
    defer lowered.close();
    for ([_][]const u8{ "a", "b" }, lowered.state.entries) |expected, entry| try std.testing.expectEqualStrings(expected, entry.message.id);
    try std.testing.expectEqualStrings(hash_b, lowered.find("b").?.bodyHash);
    try std.testing.expectEqualStrings("Body B", (try lowered.read("b")).?.bodyText);
    try std.testing.expectError(error.FileNotFound, lowered.dir.access(std.testing.io, try lowered.fileName("mail", "d"), .{}));
}

test "wishlist: legacy protected draft retains literal bytes with primary sender" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-draft", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const old = "{\"id\":\"legacy-draft\",\"to\":[{\"address\":\"peer@example.test\",\"name\":\"\"}],\"cc\":[],\"bcc\":[],\"subject\":\"Hi\",\"bodyText\":\"Body\",\"threadId\":\"\",\"inReplyTo\":\"\",\"references\":\"\",\"attachments\":[]}";
    var draft = try std.json.parseFromSliceLeaky(t.Draft, a, old, .{});
    store.state.drafts = try a.dupe(t.Draft, &.{draft});
    store.state.operations = try a.dupe(Operation, &.{.{ .id = "old-operation", .hash = "old-fingerprint", .draftId = draft.id, .outcome = "unknown" }});
    const name = try store.fileName("draft", draft.id);
    try store.write(name, old);
    try store.save();
    draft.from = .{ .address = "self@example.test" };
    _ = try store.putDraft(draft, draft.id);
    try std.testing.expectEqualStrings(old, try store.activeDraftBytes(a, draft.id));
    draft.from = .{ .address = "different@example.test" };
    try std.testing.expectError(error.UnknownOutcome, store.putDraft(draft, draft.id));
}

test "draft omission metadata persists and remains protected after an uncertain send" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/omitted-draft", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    var draft = try store.putDraft(.{ .bodyText = "Forwarded note", .omittedAttachments = 2 }, null);
    try std.testing.expectEqual(@as(usize, 2), (try store.draft(draft.id)).omittedAttachments);
    store.state.operations = try a.dupe(Operation, &.{.{ .id = "uncertain-operation", .hash = "fingerprint", .draftId = draft.id, .outcome = "unknown" }});
    _ = try store.putDraft(draft, draft.id);
    const protected = try store.activeDraftBytes(a, draft.id);
    draft.omittedAttachments = 0;
    try std.testing.expectError(error.UnknownOutcome, store.putDraft(draft, draft.id));
    try std.testing.expectEqualStrings(protected, try store.activeDraftBytes(a, draft.id));
    try std.testing.expectEqual(@as(usize, 2), (try store.draft(draft.id)).omittedAttachments);
}

test "cache activity: legacy indexes baseline zero and secure stamps never parse or wait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try std.json.parseFromSliceLeaky(State, a, "{\"account\":\"legacy@example.test\"}", .{});
    try std.testing.expectEqual(@as(u64, 0), legacy.inboxArrivalCount);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/activity", .{tmp.sub_path});
    try std.testing.expect((try cacheStamp(std.testing.io, root, "self@example.test", .{ .fixtures = true })) == null);
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    store.state.inboxArrivalCount = 7;
    try store.save();
    const before = (try cacheStamp(std.testing.io, root, "self@example.test", .{ .fixtures = true })).?;
    try store.clearMail();
    try std.testing.expectEqual(@as(u64, 7), store.state.inboxArrivalCount);
    // Keep the exclusive writer lock held: a stamp must not take that lock.
    // Invalid JSON remains stat-able, demonstrating that the probe never parses.
    try store.write("index.json", "not json");
    const after = (try cacheStamp(std.testing.io, root, "self@example.test", .{ .fixtures = true })).?;
    try std.testing.expect(!std.meta.eql(before, after));
    try store.dir.deleteFile(std.testing.io, "index.json");
    try store.dir.symLink(std.testing.io, "unrelated", "index.json", .{});
    try std.testing.expectError(error.InsecureCacheFile, cacheStamp(std.testing.io, root, "self@example.test", .{ .fixtures = true }));
}

test "older decoder refusals are retried once on writable opens and current refusals stay final" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try std.json.parseFromSliceLeaky(State, a, "{\"account\":\"legacy@example.test\"}", .{});
    try std.testing.expectEqual(@as(u32, 0), legacy.decoderRevision);
    try std.testing.expect(retriedByNewerDecoder("BodySizeMismatch", 0));
    try std.testing.expect(retriedByNewerDecoder("MimeTooDeep", 0));
    try std.testing.expect(!retriedByNewerDecoder("DiskQuotaExceeded", 0));
    try std.testing.expect(!retriedByNewerDecoder("", 0));
    try std.testing.expect(!retriedByNewerDecoder("BodySizeMismatch", decoder_revision));
    try std.testing.expect(!retriedByNewerDecoder("MimeTooDeep", decoder_revision));
    // A cache migrated by an earlier revision retries only refusals that a
    // later revision accepts, once.
    try std.testing.expectEqual(@as(u32, 5), decoder_revision);
    for ([_][]const u8{ "AmbiguousCalendarPart", "InvalidEncodedWord", "InvalidQuotedPrintable" }) |code| {
        try std.testing.expect(retriedByNewerDecoder(code, 1));
        try std.testing.expect(!retriedByNewerDecoder(code, 2));
    }
    // Charset support changed again in revision four; envelope/header bounds
    // also get one new attempt, while current decoder refusals remain final.
    for ([_][]const u8{ "UnsupportedCharset", "AmbiguousSender", "InvalidAddress", "HeaderTooLarge", "ReferencesTooLarge" }) |code| {
        try std.testing.expect(retriedByNewerDecoder(code, 3));
        try std.testing.expect(!retriedByNewerDecoder(code, decoder_revision));
    }
    try std.testing.expect(retriedByNewerDecoder("BodyTooLarge", 1));
    try std.testing.expect(retriedByNewerDecoder("BodyTooLarge", 2));
    try std.testing.expect(!retriedByNewerDecoder("BodyTooLarge", 3));
    try std.testing.expect(!retriedByNewerDecoder("BodySizeMismatch", 1));
    try std.testing.expect(!retriedByNewerDecoder("BodySizeMismatch", 2));
    try std.testing.expect(!retriedByNewerDecoder("MimeTooDeep", 1));
    try std.testing.expect(!retriedByNewerDecoder("MimeTooDeep", 2));
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/decoder", .{tmp.sub_path});
    const options: t.Options = .{ .fixtures = true };
    var generation: u64 = 0;
    {
        var store = try Store.open(std.testing.io, a, root, "self@example.test", options);
        defer store.close();
        try std.testing.expectEqual(decoder_revision, store.state.decoderRevision);
        try store.put(.{ .id = "cached", .threadId = "thread", .receivedAt = 4000, .bodyText = "Cached body" }, true);
        try store.put(.{ .id = "mismatch", .threadId = "thread", .receivedAt = 3000 }, false);
        try store.put(.{ .id = "quota", .threadId = "thread", .receivedAt = 2000 }, false);
        try store.put(.{ .id = "older", .threadId = "thread", .receivedAt = 1000 }, false);
        store.find("mismatch").?.bodyError = "BodySizeMismatch";
        store.find("quota").?.bodyError = "DiskQuotaExceeded";
        // A refusal by an unknown older decoder that may since have been fixed.
        store.find("older").?.bodyError = "InvalidQuotedPrintable";
        store.state.decoderRevision = 0;
        try store.save();
        generation = store.state.generation;
    }
    {
        // A cached reader neither migrates nor writes the legacy index.
        var reader = try Store.openCached(std.testing.io, a, root, "self@example.test", options);
        defer reader.close();
        try std.testing.expectEqual(@as(u32, 0), reader.state.decoderRevision);
        try std.testing.expectEqualStrings("BodySizeMismatch", reader.find("mismatch").?.bodyError);
    }
    {
        var store = try Store.open(std.testing.io, a, root, "self@example.test", options);
        defer store.close();
        try std.testing.expectEqualStrings("", store.find("mismatch").?.bodyError);
        try std.testing.expectEqualStrings("DiskQuotaExceeded", store.find("quota").?.bodyError);
        try std.testing.expectEqualStrings("", store.find("older").?.bodyError);
        try std.testing.expectEqualStrings("Cached body", (try store.read("cached")).?.bodyText);
        try std.testing.expectEqual(decoder_revision, store.state.decoderRevision);
        // Cached list/view generations observe the cleared refusal.
        try std.testing.expect(store.state.generation > generation);
        // The retries still fail: the current decoder's refusals are final.
        store.find("mismatch").?.bodyError = "BodySizeMismatch";
        store.find("older").?.bodyError = "InvalidQuotedPrintable";
        try store.save();
    }
    var store = try Store.open(std.testing.io, a, root, "self@example.test", options);
    defer store.close();
    try std.testing.expectEqualStrings("BodySizeMismatch", store.find("mismatch").?.bodyError);
    try std.testing.expectEqualStrings("InvalidQuotedPrintable", store.find("older").?.bodyError);
    try std.testing.expectEqual(decoder_revision, store.state.decoderRevision);
}

test "native compose cache: enlarged original keeps ordinary reads bounded and expanded reads exact" {
    if (!@import("send_memory.zig").native) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    const root = try std.fmt.allocPrint(a, "{s}/cache", .{base});
    var store = try Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const plain = try a.alloc(u8, 5 * 1024 * 1024);
    @memset(plain, 'x');
    const html = try a.alloc(u8, 5 * 1024 * 1024);
    @memset(html, 'y');
    try store.put(.{ .id = "large-original", .threadId = "thread", .from = .{ .address = "reader@example.test" }, .bodyText = plain, .bodyHtml = html }, true);
    try store.save();
    var bytes: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&bytes);
    const ordinary = (try store.readWithAllocator(fixed.allocator(), "large-original")).?;
    try std.testing.expectEqualStrings("large-original", ordinary.id);
    try std.testing.expectEqualStrings("ComposeSourceRequired", ordinary.bodyCacheError);
    try std.testing.expectEqual(@as(usize, 0), ordinary.bodyText.len);
    const expanded = (try store.readExpandedWithAllocator(a, "large-original")).?;
    try std.testing.expectEqualStrings(plain, expanded.bodyText);
    try std.testing.expectEqualStrings(html, expanded.bodyHtml.?);
    const smaller: t.Message = .{ .id = "under-raw-limit", .threadId = "thread", .bodyText = plain[0 .. 3 * 1024 * 1024], .bodyHtml = html[0 .. 3 * 1024 * 1024] };
    try store.put(smaller, true);
    try store.putOutbox(.{ .id = "fixture-large-original", .threadId = "thread", .bodyText = smaller.bodyText, .bodyHtml = smaller.bodyHtml });
    try std.testing.expect(store.find(smaller.id).?.bytes < 4 * t.Limits.body_bytes);
    try std.testing.expectEqualStrings("ComposeSourceRequired", (try store.readWithAllocator(a, smaller.id)).?.bodyCacheError);
    try std.testing.expectEqualStrings("ComposeSourceRequired", (try store.readOutboxWithAllocator(a, "fixture-large-original")).?.bodyCacheError);
    try std.testing.expectEqualStrings(smaller.bodyText, (try store.readExpandedWithAllocator(a, smaller.id)).?.bodyText);
    try std.testing.expectEqualStrings(smaller.bodyHtml.?, (try store.readOutboxExpandedWithAllocator(a, "fixture-large-original")).?.bodyHtml.?);
}

test "native compose cache: HTML fallback preserves the ordinary MIME body budget" {
    const bytes = try std.testing.allocator.alloc(u8, t.Limits.body_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    // HTML-only decoding retains the original and a generated text fallback.
    // A separately supplied text/plain alternative has different accounting.
    var message: t.Message = .{ .id = "html-fallback", .threadId = "thread", .bodyText = bytes[0..t.Limits.body_bytes], .bodyHtml = bytes[0..t.Limits.body_bytes], .bodySource = .html };
    try std.testing.expect(!Store.exceedsOrdinaryBody(message));
    message.bodySource = .plain;
    try std.testing.expect(Store.exceedsOrdinaryBody(message));
    message.bodyText = bytes[0 .. t.Limits.request_bytes / 2];
    message.bodyHtml = bytes[0 .. t.Limits.request_bytes / 2];
    try std.testing.expect(!Store.exceedsOrdinaryBody(message));
    message.bodyHtml = bytes[0 .. t.Limits.request_bytes / 2 + 1];
    try std.testing.expect(Store.exceedsOrdinaryBody(message));
    // The fallback exemption does not weaken the per-field ceiling or allow
    // loaded attachment bytes beyond the ordinary decoded-message budget.
    message.bodySource = .html;
    message.bodyText = bytes[0..t.Limits.body_bytes];
    message.bodyHtml = bytes;
    try std.testing.expect(Store.exceedsOrdinaryBody(message));
    message.bodyText = bytes;
    message.bodyHtml = bytes[0..t.Limits.body_bytes];
    try std.testing.expect(Store.exceedsOrdinaryBody(message));
    message.bodyText = bytes[0..t.Limits.body_bytes];
    message.attachments = &.{.{ .id = "synthetic", .filename = "synthetic.bin", .size = t.Limits.request_bytes - t.Limits.body_bytes, .data = "synthetic-loaded-marker" }};
    try std.testing.expect(!Store.exceedsOrdinaryBody(message));
    message.attachments = &.{.{ .id = "synthetic", .filename = "synthetic.bin", .size = t.Limits.request_bytes - t.Limits.body_bytes + 1, .data = "synthetic-loaded-marker" }};
    try std.testing.expect(Store.exceedsOrdinaryBody(message));
}

test "attachment delivery: direct preparation reuses one atomic recovery source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, "{s}/cache", .{try tmp.dir.realPathFileAlloc(std.testing.io, ".", a)});
    var store = try Store.open(std.testing.io, a, base, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const draft: t.Draft = .{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Pending file preparation" };
    const digest = try @import("send_outcome.zig").digest(a, draft, store.state.account, null);
    const first = try store.putPreparedDraft(draft, "stable-preparation", &digest);
    const again = try store.putPreparedDraft(draft, "stable-preparation", &digest);
    try std.testing.expectEqualStrings(first.id, again.id);
    try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
    try std.testing.expectEqual(@as(usize, 1), store.state.driveSources.len);
    const different: [64]u8 = @splat('b');
    try std.testing.expectError(error.OperationConflict, store.putPreparedDraft(draft, "stable-preparation", &different));
    store.close();
    store = try Store.open(std.testing.io, a, base, "self@example.test", .{ .fixtures = true });
    const reopened = try store.putPreparedDraft(draft, "stable-preparation", &digest);
    try std.testing.expectEqualStrings(first.id, reopened.id);
    try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
    try store.discardDraft(first.id);
    try std.testing.expectEqual(@as(usize, 0), store.state.driveSources.len);
}
