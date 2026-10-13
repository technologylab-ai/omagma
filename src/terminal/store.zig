const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const draft_summary = @import("draft_summary.zig");
const mail_limits = @import("mail_limits.zig");
pub const index_read_bytes = 16 * 1024 * 1024;
pub const index_write_bytes = 8 * 1024 * 1024;
pub const Entry = struct { message: t.Message, bytes: usize = 0, bodyHash: []const u8 = "", bodyError: []const u8 = "" };
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

pub const Operation = struct { id: []const u8, hash: []const u8, outcome: []const u8 = "unknown", messageId: []const u8 = "", rfcMessageId: []const u8 = "", draftId: []const u8 = "", errorCode: []const u8 = "", icalendar: []const u8 = "", kind: []const u8 = "", label: ?Label = null, labelId: []const u8 = "", deleted: bool = false };
pub const View = struct { key: []const u8, query: []const u8, label: []const u8, labelId: []const u8 = "", ids: []const []const u8 = &.{}, remoteCursor: []const u8 = "", stale: bool = false, lastSyncAt: i64 = 0, lastSyncStartedAt: i64 = 0, incomplete: bool = false };
pub const QuotaFloor = struct { receivedAt: i64, id: []const u8 };
pub const FixtureProviderRecord = struct { id: []const u8, labels: []const []const u8 = &.{}, deleted: bool = false, sourceHistoryId: []const u8 = "1" };
pub const Label = struct { id: []const u8, name: []const u8, type: []const u8 = "user", color: ?t.LabelColor = null };
pub const Identity = struct { address: []const u8, name: []const u8 = "", signature: []const u8 = "", isDefault: bool = false };
/// Undo records only labels changed by this action. Other concurrent labels
/// survive undo. An unconfirmed mutation is never replayed automatically.
pub const UndoItem = struct { messageId: []const u8, addLabels: []const []const u8 = &.{}, removeLabels: []const []const u8 = &.{}, outcome: []const u8 = "pending", errorCode: []const u8 = "", restored: bool = false };
pub const Undo = struct { token: []const u8, items: []UndoItem = &.{} };
pub const SendState = enum { queued, canceled, submitting, applied, rejected, unknown };
pub const QueuedSend = struct {
    queueId: []const u8,
    draftId: []const u8,
    operationId: []const u8,
    hash: []const u8,
    state: SendState = .queued,
    createdAtMs: i64,
    dueAtMs: i64,
    errorCode: []const u8 = "",
};
/// Shared native/browser decoder revision and retry eligibility.
pub const decoder_revision = @import("decoder_policy.zig").decoder_revision;
const retriedByNewerDecoder = @import("decoder_policy.zig").retriedByNewerDecoder;

pub const State = struct {
    schema: u8 = 1,
    account: []const u8,
    generation: u64 = 1,
    serial: u64 = 0,
    entries: []Entry = &.{},
    drafts: []t.Draft = &.{},
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
    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options) !Store {
        return openMode(io, a, root, account, options, false);
    }
    pub fn openCached(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options) !Store {
        return openMode(io, a, root, account, options, true);
    }
    fn openMode(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options, readonly: bool) !Store {
        const dir = try openAccountDirectory(io, root, account, options, true);
        errdefer dir.close(io);
        const lock = try openPrivateLock(dir, io);
        errdefer lock.close(io);
        const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(if (readonly) 250 else 2000) });
        while (!try lock.tryLock(io, if (readonly) .shared else .exclusive)) {
            if (deadline.durationFromNow(io).raw.toNanoseconds() <= 0) return error.CacheBusy;
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(10) }).sleep(io);
        }
        if (!readonly) try cleanupScratch(dir, io, a);
        var state: State = .{ .account = account };
        const raw = readPrivate(dir, io, a, "index.json", index_read_bytes) catch |err| if (err == error.FileNotFound) null else return err;
        if (raw) |bytes| {
            // readPrivate owns this immutable buffer in the same caller arena
            // as State. Borrow unescaped strings instead of copying each field
            // on every short refresh commit; escaped strings still allocate.
            state = try std.json.parseFromSliceLeaky(State, a, bytes, .{ .allocate = .alloc_if_needed });
            if (state.schema != 1 or !std.mem.eql(u8, state.account, account)) return error.CacheIdentityMismatch;
            if (state.entries.len > t.Limits.metadata_hard or state.drafts.len > 128 or state.outbox.len > 128 or state.contacts.len > 1024 or state.operations.len > 1000 or state.sendQueue.len > 128 or state.fixtureProvider.len > 1024 or state.labels.len > 512 or state.fixtureDeletedLabels.len > 512 or state.identities.len > 32 or state.undo.len > 16) return error.CacheLimitExceeded;
            for (state.sendQueue) |entry| {
                if (entry.queueId.len == 0 or entry.queueId.len > 256 or entry.draftId.len == 0 or entry.draftId.len > 256 or entry.operationId.len == 0 or entry.operationId.len > 256 or entry.hash.len != 64 or entry.errorCode.len > 128 or entry.dueAtMs < entry.createdAtMs or entry.dueAtMs - entry.createdAtMs > 30000) return error.CacheLimitExceeded;
            }
            for (state.labels) |label| if (label.id.len > 256 or label.name.len > 512) return error.CacheLimitExceeded;
            for (state.fixtureDeletedLabels) |id| if (id.len == 0 or id.len > 256) return error.CacheLimitExceeded;
            for (state.operations) |operation| {
                if (operation.kind.len > 64 or operation.labelId.len > 256) return error.CacheLimitExceeded;
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
        var s: Store = .{ .io = io, .dir = dir, .lock = lock, .allocator = a, .state = state, .options = resolved, .entriesStorage = state.entries };
        if (state.views.len > 16 or state.historyId.len > 32) return error.CacheLimitExceeded;
        for (state.views) |view| if (view.ids.len > t.Limits.metadata_hard or view.query.len > 4096 or view.label.len > 256 or view.remoteCursor.len > 4096) return error.CacheLimitExceeded;
        for (state.entries) |entry| if (entry.bodyError.len > 64 or entry.message.bodyCacheError.len > 64 or entry.message.decodeWarning.len > 64) return error.CacheLimitExceeded;
        if (!options.fixtures and (state.fixtureProvider.len != 0 or state.fixtureLabelsReady or state.fixtureDeletedLabels.len != 0)) return error.CacheIdentityMismatch;
        for (state.fixtureProvider) |record| try validateFixtureRecord(record);
        // Persisted indexes already have this order. Keep the legacy fallback
        // without heap-sorting thousands of rows on every cached/body read.
        if (!entriesSorted(s.state.entries)) std.sort.heap(Entry, s.state.entries, {}, newestFirst);
        if (!readonly) try s.enforceLimits();
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
        if (s.lockHeld) s.lock.unlock(s.io);
        s.lockHeld = false;
    }
    pub fn close(s: *Store) void {
        if (s.closed) return;
        s.closed = true;
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
    pub fn write(s: *Store, name: []const u8, bytes: []const u8) !void {
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
    pub fn diskBytes(s: *Store) !usize {
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
        const st = s.dir.statFile(s.io, name, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return 0 else return err;
        return @intCast(st.size);
    }
    fn makeRoom(s: *Store, n: usize, replacing: []const u8) !void {
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
        try s.makeRoom(count, "");
    }
    pub fn blobReferenced(s: *const Store, id: []const u8) bool {
        for (s.state.drafts) |draft_value| for (draft_value.attachments) |attachment| if (attachment.blobId) |blob| if (std.mem.eql(u8, blob, id)) return true;
        for (s.state.outbox) |message| for (message.attachments) |attachment| if (attachment.blobId) |blob| if (std.mem.eql(u8, blob, id)) return true;
        for (s.state.entries) |entry| for (entry.message.attachments) |attachment| if (attachment.blobId) |blob| if (std.mem.eql(u8, blob, id)) return true;
        return false;
    }

    fn evict(s: *Store, i: usize) !void {
        const name = try s.fileName("mail", s.state.entries[i].message.id);
        s.dir.deleteFile(s.io, name) catch |err| if (err != error.FileNotFound) return err;
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
        if (message.bodyText.len > t.Limits.body_bytes) return error.BodyTooLarge;
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
    /// Attach immutable bytes only to retained metadata. Never resurrect an ID,
    /// update ordering/labels, or rewrite an already valid cached body.
    pub fn putBody(s: *Store, message: t.Message) !bool {
        if (message.bodyCacheError.len > 64 or message.decodeWarning.len > 64) return error.CacheLimitExceeded;
        var e = s.find(message.id) orelse return false;
        if (message.bodyText.len > t.Limits.body_bytes or (message.bodyHtml != null and message.bodyHtml.?.len > t.Limits.body_bytes)) return error.BodyTooLarge;
        // Conversation aggregate quotas never make an individual body a final
        // refusal. An ordinary read/prefetch may still fetch it independently.
        if (std.mem.eql(u8, message.bodyCacheError, "ThreadBodyBudgetExceeded")) return false;
        if (e.bytes != 0) if (try s.read(message.id)) |_| return false;
        if (message.bodyCacheError.len != 0) {
            e.bodyError = message.bodyCacheError;
            e.message.decodeWarning = message.decodeWarning;
            e.message.metadataPartial = true;
            return false;
        }
        e.bytes = 0;
        e.bodyHash = "";
        const raw = try std.json.Stringify.valueAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
        if (raw.len > 4 * t.Limits.body_bytes) return error.BodyTooLarge;
        const name = try s.fileName("mail", message.id);
        s.makeRoom(raw.len, name) catch |err| {
            if (err != error.DiskQuotaExceeded) return err;
            if (s.find(message.id)) |entry| entry.bodyError = "DiskQuotaExceeded";
            s.state.quotaDiskLimit = s.options.disk_limit;
            return false;
        };
        e = s.find(message.id) orelse return false;
        try s.write(name, raw);
        e.bodyError = "";
        e.bytes = raw.len;
        e.message.attachments = try attachmentMetadata(s.allocator, message.attachments);
        const digest = hash(raw);
        e.bodyHash = try s.allocator.dupe(u8, &digest);
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
        var named_calendar = false;
        for (previous.attachments) |part| named_calendar = named_calendar or @import("mime.zig").isCalendarPart(part.mimeType, part.filename);
        if (!named_calendar) return false;
        if (message.bodyText.len > t.Limits.body_bytes or (message.bodyHtml != null and message.bodyHtml.?.len > t.Limits.body_bytes)) return error.BodyTooLarge;
        const raw = try std.json.Stringify.valueAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
        if (raw.len > 4 * t.Limits.body_bytes) return error.BodyTooLarge;
        const name = try s.fileName("mail", message.id);
        try s.makeRoom(raw.len, name);
        const entry = s.find(message.id) orelse return false;
        const digest = hash(raw);
        const owned_hash = try s.allocator.dupe(u8, &digest);
        // The checked atomic write succeeds before the old reference changes.
        try s.write(name, raw);
        entry.bytes = raw.len;
        entry.bodyHash = owned_hash;
        entry.bodyError = "";
        return true;
    }
    pub fn read(s: *Store, id: []const u8) !?t.Message {
        return s.readWithAllocator(s.allocator, id);
    }
    pub fn readWithAllocator(s: *Store, allocator: std.mem.Allocator, id: []const u8) !?t.Message {
        const e = s.find(id) orelse return null;
        if (e.bytes == 0) return null;
        const key = hash(id);
        const raw = readPrivate(s.dir, s.io, allocator, try std.fmt.allocPrint(allocator, "mail-{s}.json", .{key}), 4 * t.Limits.body_bytes) catch |err| if (err == error.FileNotFound) return null else return err;
        const digest = hash(raw);
        const record = try std.json.parseFromSliceLeaky(BodyRecord, allocator, raw, .{ .allocate = .alloc_if_needed });
        if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.message.id, id)) return error.CacheIdentityMismatch;
        if (!std.mem.eql(u8, e.bodyHash, &digest)) {
            e.bytes = 0;
            e.bodyHash = "";
            return null;
        }
        return try @import("mail_display_fields.zig").canonicalizeMessageDisplay(allocator, record.message);
    }
    pub fn putOutbox(s: *Store, message: t.Message) !void {
        if (s.state.outbox.len == 128) return error.OutboxLimitExceeded;
        const name = try s.fileName("outbox", message.id);
        const raw = try std.json.Stringify.valueAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
        try s.makeRoom(raw.len, name);
        try s.write(name, raw);
        errdefer s.dir.deleteFile(s.io, name) catch {};
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
        for (s.state.outbox) |m| if (std.mem.eql(u8, m.id, id)) {
            const raw = try readPrivate(s.dir, s.io, allocator, try std.fmt.allocPrint(allocator, "outbox-{s}.json", .{hash(id)}), 4 * t.Limits.body_bytes);
            const record = try std.json.parseFromSliceLeaky(BodyRecord, allocator, raw, .{ .allocate = .alloc_if_needed });
            if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.message.id, id)) return error.CacheIdentityMismatch;
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
            const raw = try readPrivate(s.dir, s.io, s.allocator, try s.fileName("draft", id), 4 * t.Limits.body_bytes);
            const result = try std.json.parseFromSliceLeaky(t.Draft, s.allocator, raw, .{ .allocate = .alloc_always });
            if (!std.mem.eql(u8, result.id, id)) return error.CacheIdentityMismatch;
            return result;
        };
        return error.DraftNotFound;
    }
    pub fn putDraft(s: *Store, input: t.Draft, id: ?[]const u8) !t.Draft {
        if (input.bodyText.len > t.Limits.body_bytes) return error.BodyTooLarge;
        if (!std.unicode.utf8ValidateSlice(input.bodyText)) return error.InvalidUtf8;
        var d = input;
        for (d.attachments) |attachment| if (attachment.blobId) |blob_id| {
            const file = try @import("attachment_blob.zig").open(s, blob_id, attachment.size);
            file.close(s.io);
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
        if (id != null and index == null) return error.DraftNotFound;
        if (index == null and s.state.drafts.len == 128) return error.DraftLimitExceeded;
        var draft_value = try j.value(s.allocator, d);
        // Keep an unchanged legacy uncertain draft byte-for-byte compatible.
        if (d.bodyFormat == .plain) _ = draft_value.object.orderedRemove("bodyFormat");
        if (d.omittedAttachments == 0) _ = draft_value.object.orderedRemove("omittedAttachments");
        const raw = try std.json.Stringify.valueAlloc(s.allocator, draft_value, .{ .emit_null_optional_fields = false });
        const name = try s.fileName("draft", d.id);
        const previous = if (index != null) try readPrivate(s.dir, s.io, s.allocator, name, 4 * t.Limits.body_bytes) else null;
        if (previous) |old| for (s.state.operations) |operation| {
            if (std.mem.eql(u8, operation.draftId, d.id) and std.mem.eql(u8, operation.outcome, "unknown") and !std.mem.eql(u8, old, raw)) return error.UnknownOutcome;
        };
        if (previous) |old| if (!std.mem.eql(u8, old, raw)) try s.cancelDraftQueue(d.id);
        try s.makeRoom(raw.len, name);
        try s.write(name, raw);
        errdefer {
            if (previous) |old| s.write(name, old) catch {} else s.dir.deleteFile(s.io, name) catch {};
        }
        const preview = try draft_summary.fromDraft(s.allocator, d);
        if (index) |i| s.state.drafts[i] = preview else {
            var list: std.ArrayList(t.Draft) = .empty;
            try list.appendSlice(s.allocator, s.state.drafts);
            try list.append(s.allocator, preview);
            s.state.drafts = list.items;
        }
        try s.save();
        return d;
    }
    pub fn discardDraft(s: *Store, id: []const u8) !void {
        for (s.state.operations) |operation| if (std.mem.eql(u8, operation.draftId, id) and std.mem.eql(u8, operation.outcome, "unknown")) return error.UnknownOutcome;
        for (s.state.drafts, 0..) |draft_value, i| if (std.mem.eql(u8, draft_value.id, id)) {
            try s.cancelDraftQueue(id);
            // The account has one regenerable browser artifact. Removing a
            // draft must also remove any rendered copy of discarded content.
            s.dir.deleteFile(s.io, "preview.html") catch |err| if (err != error.FileNotFound) return err;
            std.mem.copyForwards(t.Draft, s.state.drafts[i .. s.state.drafts.len - 1], s.state.drafts[i + 1 ..]);
            s.state.drafts = s.state.drafts[0 .. s.state.drafts.len - 1];
            try s.save();
            try s.dir.deleteFile(s.io, try s.fileName("draft", id));
            return;
        };
        return error.DraftNotFound;
    }
    fn cancelDraftQueue(s: *Store, id: []const u8) !void {
        for (s.state.sendQueue) |entry| if (std.mem.eql(u8, entry.draftId, id) and (entry.state == .submitting or entry.state == .unknown)) return error.UnknownOutcome;
        for (s.state.sendQueue) |*entry| if (std.mem.eql(u8, entry.draftId, id) and entry.state == .queued) {
            entry.state = .canceled;
            entry.errorCode = "DraftChanged";
        };
    }
    pub fn clearMail(s: *Store) !void {
        while (s.state.entries.len > 0) try s.evict(0);
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
                    if (deleted.items.len == 512) return error.TooManyDeletedLabels;
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
    try std.testing.expectEqual(@as(usize, 32), store.find("broad").?.message.to.len);
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
    const original_file = try readPrivate(store.dir, std.testing.io, a, filename, 4 * t.Limits.body_bytes);
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
    try std.testing.expectEqualStrings(original_file, try readPrivate(cached.dir, std.testing.io, a, filename, 4 * t.Limits.body_bytes));
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
    const names = [_][]const u8{ "index.json", try original.fileName("mail", "older"), try original.fileName("mail", "newer"), try original.fileName("draft", draft.id), try original.fileName("outbox", "sent") };
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
    try std.testing.expectEqualStrings(old, try readPrivate(store.dir, store.io, a, name, t.Limits.body_bytes));
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
    const name = try store.fileName("draft", draft.id);
    const protected = try readPrivate(store.dir, store.io, a, name, t.Limits.body_bytes);
    draft.omittedAttachments = 0;
    try std.testing.expectError(error.UnknownOutcome, store.putDraft(draft, draft.id));
    try std.testing.expectEqualStrings(protected, try readPrivate(store.dir, store.io, a, name, t.Limits.body_bytes));
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
    try std.testing.expectEqual(@as(u32, 4), decoder_revision);
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
