const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
pub const Entry = struct { message: t.Message, bytes: usize = 0, bodyHash: []const u8 = "" };
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
pub const Operation = struct { id: []const u8, hash: []const u8, outcome: []const u8 = "unknown", messageId: []const u8 = "", rfcMessageId: []const u8 = "", draftId: []const u8 = "", errorCode: []const u8 = "", icalendar: []const u8 = "" };
pub const State = struct {
    schema: u8 = 1,
    account: []const u8,
    generation: u64 = 1,
    serial: u64 = 0,
    entries: []Entry = &.{},
    drafts: []t.Draft = &.{},
    outbox: []t.Message = &.{},
    contacts: []t.Contact = &.{},
    operations: []Operation = &.{},
    fixtureCalls: u64 = 0,
    fixtureSends: u64 = 0,
};

pub const Store = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock: std.Io.File,
    allocator: std.mem.Allocator,
    state: State,
    options: t.Options,
    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, account: []const u8, options: t.Options) !Store {
        // Never use email addresses or provider IDs as path components.
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, root, .fromMode(0o700));
        var base = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
        defer base.close(io);
        if ((try base.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureCacheDirectory;
        // Mock and live stores cannot read or mutate each other's cached data,
        // even when the caller selects the same account and cache base.
        const namespace = if (options.fixtures) "fixtures" else "live";
        _ = try base.createDirPathStatus(io, namespace, .fromMode(0o700));
        var backend = try base.openDir(io, namespace, .{ .iterate = true, .follow_symlinks = false });
        defer backend.close(io);
        if ((try backend.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureCacheDirectory;
        const key = hash(account);
        _ = try backend.createDirPathStatus(io, &key, .fromMode(0o700));
        const dir = try backend.openDir(io, &key, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureCacheDirectory;
        const lock = try openPrivateLock(dir, io);
        errdefer lock.close(io);
        if (!try lock.tryLock(io, .exclusive)) return error.CacheBusy;
        var state: State = .{ .account = account };
        const raw = readPrivate(dir, io, a, "index.json", 16 * 1024 * 1024) catch |err| if (err == error.FileNotFound) null else return err;
        if (raw) |bytes| {
            state = try std.json.parseFromSliceLeaky(State, a, bytes, .{ .allocate = .alloc_always });
            if (state.schema != 1 or !std.mem.eql(u8, state.account, account)) return error.CacheIdentityMismatch;
            if (state.entries.len > t.Limits.metadata_hard or state.drafts.len > 128 or state.outbox.len > 128 or state.contacts.len > 1024 or state.operations.len > 1000) return error.CacheLimitExceeded;
        }
        var s: Store = .{ .io = io, .dir = dir, .lock = lock, .allocator = a, .state = state, .options = options };
        while (s.state.entries.len > options.metadata_limit) try s.evict(0);
        try s.save();
        return s;
    }
    pub fn close(s: *Store) void {
        s.lock.unlock(s.io);
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
        var raw = try std.json.Stringify.valueAlloc(s.allocator, s.state, .{});
        if (raw.len >= 16 * 1024 * 1024) return error.CacheLimitExceeded;
        try s.makeRoom(raw.len, "index.json");
        // Quota eviction changes body residency; serialize the resulting state.
        raw = try std.json.Stringify.valueAlloc(s.allocator, s.state, .{});
        try s.write("index.json", raw);
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
        var used = try s.diskBytes();
        // The old file remains while an atomic replacement is written. Include
        // that overlap rather than measuring only the final directory contents.
        var i: usize = 0;
        while (n > s.options.disk_limit - @min(used, s.options.disk_limit)) {
            while (i < s.state.entries.len and s.state.entries[i].bytes == 0) : (i += 1) {}
            if (i == s.state.entries.len) return error.DiskQuotaExceeded;
            const entry = &s.state.entries[i];
            const name = try s.fileName("mail", entry.message.id);
            if (!std.mem.eql(u8, name, replacing)) {
                const removed = try s.size(name);
                s.dir.deleteFile(s.io, name) catch |err| if (err != error.FileNotFound) return err;
                used -= @min(removed, used);
                entry.bytes = 0;
                entry.bodyHash = "";
            }
            i += 1;
        }
    }
    fn evict(s: *Store, i: usize) !void {
        const name = try s.fileName("mail", s.state.entries[i].message.id);
        s.dir.deleteFile(s.io, name) catch |err| if (err != error.FileNotFound) return err;
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
        if (message.bodyText.len > t.Limits.body_bytes) return error.BodyTooLarge;
        var metadata = message;
        metadata.bodyText = "";
        metadata.bodyHtml = null;
        metadata.to = &.{};
        metadata.cc = &.{};
        metadata.replyTo = &.{};
        metadata.attachments = &.{};
        metadata.invitation = null;
        var e = s.find(message.id);
        if (e == null) {
            if (s.state.entries.len == s.options.metadata_limit) try s.evict(0);
            var list: std.ArrayList(Entry) = .empty;
            try list.appendSlice(s.allocator, s.state.entries);
            try list.append(s.allocator, .{ .message = metadata });
            s.state.entries = list.items;
            e = &s.state.entries[s.state.entries.len - 1];
        } else e.?.message = metadata;
        if (full) {
            const raw = try std.json.Stringify.valueAlloc(s.allocator, BodyRecord{ .account = s.state.account, .message = message }, .{});
            if (raw.len > 4 * t.Limits.body_bytes) return error.BodyTooLarge;
            const name = try s.fileName("mail", message.id);
            try s.makeRoom(raw.len, name);
            try s.write(name, raw);
            e.?.bytes = raw.len;
            const digest = hash(raw);
            e.?.bodyHash = try s.allocator.dupe(u8, &digest);
        }
    }
    pub fn read(s: *Store, id: []const u8) !?t.Message {
        const e = s.find(id) orelse return null;
        if (e.bytes == 0) return null;
        const raw = readPrivate(s.dir, s.io, s.allocator, try s.fileName("mail", id), 4 * t.Limits.body_bytes) catch |err| if (err == error.FileNotFound) return null else return err;
        const digest = hash(raw);
        if (!std.mem.eql(u8, e.bodyHash, &digest)) return error.CacheIdentityMismatch;
        const record = try std.json.parseFromSliceLeaky(BodyRecord, s.allocator, raw, .{ .allocate = .alloc_always });
        if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.message.id, id)) return error.CacheIdentityMismatch;
        return record.message;
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
        metadata.attachments = &.{};
        metadata.invitation = null;
        try list.append(s.allocator, metadata);
        s.state.outbox = list.items;
        try s.save();
    }
    pub fn readOutbox(s: *Store, id: []const u8) !?t.Message {
        for (s.state.outbox) |m| if (std.mem.eql(u8, m.id, id)) {
            const raw = try readPrivate(s.dir, s.io, s.allocator, try s.fileName("outbox", id), 4 * t.Limits.body_bytes);
            const record = try std.json.parseFromSliceLeaky(BodyRecord, s.allocator, raw, .{ .allocate = .alloc_always });
            if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account) or !std.mem.eql(u8, record.message.id, id)) return error.CacheIdentityMismatch;
            var result = record.message;
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
        d.id = if (id) |x| x else try s.nextId("draft");
        var index: ?usize = null;
        for (s.state.drafts, 0..) |old, i| if (std.mem.eql(u8, old.id, d.id)) {
            index = i;
            break;
        };
        if (id != null and index == null) return error.DraftNotFound;
        if (index == null and s.state.drafts.len == 128) return error.DraftLimitExceeded;
        const raw = try std.json.Stringify.valueAlloc(s.allocator, d, .{});
        const name = try s.fileName("draft", d.id);
        const previous = if (index != null) try readPrivate(s.dir, s.io, s.allocator, name, 4 * t.Limits.body_bytes) else null;
        if (previous) |old| for (s.state.operations) |operation| {
            if (std.mem.eql(u8, operation.draftId, d.id) and std.mem.eql(u8, operation.outcome, "unknown") and !std.mem.eql(u8, old, raw)) return error.UnknownOutcome;
        };
        try s.makeRoom(raw.len, name);
        try s.write(name, raw);
        errdefer {
            if (previous) |old| s.write(name, old) catch {} else s.dir.deleteFile(s.io, name) catch {};
        }
        var preview = d;
        preview.bodyText = "";
        preview.attachments = &.{};
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
            std.mem.copyForwards(t.Draft, s.state.drafts[i .. s.state.drafts.len - 1], s.state.drafts[i + 1 ..]);
            s.state.drafts = s.state.drafts[0 .. s.state.drafts.len - 1];
            try s.save();
            try s.dir.deleteFile(s.io, try s.fileName("draft", id));
            return;
        };
        return error.DraftNotFound;
    }
    pub fn clearMail(s: *Store) !void {
        while (s.state.entries.len > 0) try s.evict(0);
        s.state.generation += 1;
        try s.save();
    }
};
