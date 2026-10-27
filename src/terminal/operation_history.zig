//! Immutable, paged settled history. The active index owns only roots; all
//! publication happens under the Store lease. Receipts are never evicted.
const std = @import("std");
const storage = @import("store.zig");
const t = @import("types.zig");
const j = @import("json.zig");
pub const bucket_count = 64;
pub const page_limit = 32;
pub const page_bytes = 4 * 1024 * 1024;
pub const Root = struct {
    head: []const u8 = "",
    pages: u64 = 0,
    operations: u64 = 0,
    drafts: u64 = 0,
    queues: u64 = 0,
    blobs: u64 = 0,
    blobFiles: u64 = 0,
    blobBytes: u64 = 0,
    unindexedBlobPins: bool = false,
    buckets: [bucket_count][]const u8 = @splat(""),
    bucketEntries: [bucket_count]u64 = @splat(0),
    entries: u64 = 0,
    cleanup: []const Cleanup = &.{},
};
pub const Cleanup = struct { name: []const u8, handle: []const u8 = "" };
pub const Kind = enum { operation, draft, queue, blob };
pub const Source = struct {
    summary: t.Draft,
    handle: []const u8,
    hash: []const u8,
    blobs: []const []const u8 = &.{},
    deleted: bool = false,
    gmailLink: ?@import("draft_link.zig").Link = null,
};
pub const Blob = struct { id: []const u8, handle: []const u8, size: usize, deleted: bool = false, references: ?u64 = null };
pub const Record = union(Kind) { operation: storage.Operation, draft: Source, queue: storage.QueuedSend, blob: Blob };
pub const Page = struct { schema: u8 = 1, account: []const u8, previous: []const u8 = "", sequence: u64, records: []const Record };
pub const Location = struct { kind: Kind, id: []const u8, page: []const u8, slot: usize };
pub const Bucket = struct { schema: u8 = 1, account: []const u8, previous: []const u8 = "", entries: []const Location };

fn phaseBacking(normal: std.mem.Allocator) std.mem.Allocator {
    return if (@import("send_memory.zig").native) @import("send_memory.zig").allocator() else normal;
}
fn advance(next: *[]const u8, buffer: *[64]u8, value: []const u8) void {
    if (value.len == 0) {
        next.* = "";
        return;
    }
    @memcpy(buffer, value);
    next.* = buffer;
}
pub fn id(record: Record) []const u8 {
    return switch (record) {
        .operation => |v| v.id,
        .draft => |v| v.summary.id,
        .queue => |v| v.queueId,
        .blob => |v| v.id,
    };
}
fn bucket(kind: Kind, key: []const u8) usize {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(@tagName(kind));
    h.update(key);
    return h.finalResult()[0] % bucket_count;
}
pub fn direct(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "history-page-") or std.mem.startsWith(u8, name, "history-index-") or std.mem.startsWith(u8, name, "history-draft-") or std.mem.startsWith(u8, name, "history-active-") or std.mem.startsWith(u8, name, "history-pins-") or std.mem.startsWith(u8, name, "history-calendar-");
}
pub fn handleOf(name: []const u8) !@import("vault_storage.zig").Handle {
    if (!direct(name) or !std.mem.endsWith(u8, name, ".json")) return error.InvalidHistory;
    const prefix: usize = if (std.mem.startsWith(u8, name, "history-calendar-")) 17 else if (std.mem.startsWith(u8, name, "history-active-")) 15 else if (std.mem.startsWith(u8, name, "history-page-") or std.mem.startsWith(u8, name, "history-pins-")) 13 else 14;
    if (name.len != prefix + 64 + 5) return error.InvalidHistory;
    return @import("vault_storage.zig").Handle.parse(name[prefix..][0..64]);
}
pub fn validate(root: Root) !void {
    // Even a one-byte page could not exceed the account's absolute disk cap.
    // Bound corrupt counters before arithmetic/traversal, not retained age.
    if (root.pages > t.Limits.disk_hard or root.operations > root.pages * page_limit or root.drafts > root.pages * page_limit or root.queues > root.pages * page_limit or root.blobs > root.pages * page_limit or root.blobFiles > root.blobs or root.blobBytes > t.Limits.disk_hard) return error.InvalidHistory;
    if ((root.pages == 0) != (root.head.len == 0)) return error.InvalidHistory;
    if (root.head.len != 0) _ = try @import("vault_storage.zig").Handle.parse(root.head);
    if (root.entries > root.pages * page_limit * 2 or root.entries < root.operations + root.drafts + root.queues + root.blobs) return error.InvalidHistory;
    var counted: u64 = 0;
    for (root.buckets, root.bucketEntries) |head, entries| {
        if ((head.len == 0) != (entries == 0) or entries > root.entries) return error.InvalidHistory;
        counted = std.math.add(u64, counted, entries) catch return error.InvalidHistory;
        if (head.len != 0) _ = try @import("vault_storage.zig").Handle.parse(head);
    }
    if (counted != root.entries) return error.InvalidHistory;
    if (root.cleanup.len > 2 * 128 + bucket_count) return error.InvalidHistory;
    for (root.cleanup) |entry| {
        if (!direct(entry.name) and !std.mem.startsWith(u8, entry.name, "draft-") and !std.mem.startsWith(u8, entry.name, "blob-")) return error.InvalidHistory;
        _ = try storage.Store.migrationRecordKind(entry.name);
        if (entry.handle.len != 0) _ = try @import("vault_storage.zig").Handle.parse(entry.handle);
    }
}
pub fn fileName(a: std.mem.Allocator, role: []const u8, handle: []const u8) ![]const u8 {
    _ = try @import("vault_storage.zig").Handle.parse(handle);
    return std.fmt.allocPrint(a, "history-{s}-{s}.json", .{ role, handle });
}
pub fn readPage(s: *storage.Store, a: std.mem.Allocator, handle: []const u8) !Page {
    const raw = try s.readHistory(a, try fileName(a, "page", handle), page_bytes);
    const page = try std.json.parseFromSliceLeaky(Page, a, raw, .{ .allocate = .alloc_if_needed });
    if (page.schema != 1 or !std.mem.eql(u8, page.account, s.state.account) or page.sequence == 0 or page.records.len == 0 or page.records.len > page_limit) return error.InvalidHistory;
    if (page.previous.len != 0) _ = try @import("vault_storage.zig").Handle.parse(page.previous);
    return page;
}
fn readBucket(s: *storage.Store, a: std.mem.Allocator, handle: []const u8) !Bucket {
    const raw = try s.readHistory(a, try fileName(a, "index", handle), page_bytes);
    const result = try std.json.parseFromSliceLeaky(Bucket, a, raw, .{ .allocate = .alloc_if_needed });
    if (result.schema != 1 or !std.mem.eql(u8, result.account, s.state.account) or result.entries.len == 0 or result.entries.len > 128) return error.InvalidHistory;
    if (result.previous.len != 0) _ = try @import("vault_storage.zig").Handle.parse(result.previous);
    return result;
}
fn clone(comptime T: type, a: std.mem.Allocator, value: T) !T {
    return std.json.parseFromSliceLeaky(T, a, try j.encodeAlloc(a, value, .{}), .{ .allocate = .alloc_if_needed });
}
pub fn locate(s: *storage.Store, a: std.mem.Allocator, kind: Kind, key: []const u8) !?Location {
    const selected = bucket(kind, key);
    var next = s.state.history.buckets[selected];
    var next_buffer: [64]u8 = undefined;
    var remaining = s.state.history.bucketEntries[selected];
    while (next.len != 0) {
        if (remaining == 0) return error.InvalidHistory;
        var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
        defer phase.deinit();
        const found = try readBucket(s, phase.allocator(), next);
        if (found.entries.len > remaining) return error.InvalidHistory;
        remaining -= found.entries.len;
        var index = found.entries.len;
        while (index > 0) {
            index -= 1;
            const entry = found.entries[index];
            if (bucket(entry.kind, entry.id) != selected) return error.InvalidHistory;
            if (entry.kind == kind and std.mem.eql(u8, entry.id, key)) return try clone(Location, a, entry);
        }
        // Only the next fixed-size identity survives this page lifetime.
        advance(&next, &next_buffer, found.previous);
    }
    if (remaining != 0) return error.InvalidHistory;
    return null;
}
pub fn get(s: *storage.Store, a: std.mem.Allocator, kind: Kind, key: []const u8) !?Record {
    var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
    defer phase.deinit();
    const temporary = phase.allocator();
    const location = (try locate(s, temporary, kind, key)) orelse return null;
    const page = try readPage(s, temporary, location.page);
    if (location.slot >= page.records.len) return error.InvalidHistory;
    const record = page.records[location.slot];
    if (std.meta.activeTag(record) != kind or !std.mem.eql(u8, id(record), key)) return error.InvalidHistory;
    return try clone(Record, a, record);
}
pub fn operation(s: *storage.Store, a: std.mem.Allocator, key: []const u8) !?storage.Operation {
    for (s.state.operations) |value| if (std.mem.eql(u8, value.id, key)) return value;
    return if (try get(s, a, .operation, key)) |record| record.operation else null;
}
pub fn queueOperation(s: *storage.Store, a: std.mem.Allocator, key: []const u8) !?storage.QueuedSend {
    var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
    defer phase.deinit();
    const temporary = phase.allocator();
    const location = (try locate(s, temporary, .queue, try std.fmt.allocPrint(temporary, "\x00{s}", .{key}))) orelse return null;
    const page = try readPage(s, temporary, location.page);
    if (location.slot >= page.records.len or page.records[location.slot] != .queue) return error.InvalidHistory;
    const entry = page.records[location.slot].queue;
    if (!std.mem.eql(u8, entry.operationId, key)) return error.InvalidHistory;
    return try clone(storage.QueuedSend, a, entry);
}
pub fn findBlob(s: *storage.Store, a: std.mem.Allocator, key: []const u8) !?Blob {
    const value = (try get(s, a, .blob, key)) orelse return null;
    const result = value.blob;
    try @import("draft_codec.zig").validateAttachmentHandle(result.id);
    _ = try @import("vault_storage.zig").Handle.parse(result.handle);
    if (result.size > t.Limits.incoming_attachment_bytes) return error.InvalidHistory;
    return result;
}
/// Publish immutable blob lookup metadata outside the active object map. A
/// plaintext source reserves the same opaque handle for a later vault migration.
pub fn putBlob(s: *storage.Store, value: Blob) !void {
    try s.finishHistoryCleanup();
    const previous = try findBlob(s, s.allocator, value.id);
    if (previous) |old| if (!old.deleted) {
        if (value.deleted) {} else if (old.size == value.size and std.mem.eql(u8, old.handle, value.handle)) return else return error.AttachmentChanged;
    };
    s.beginHistory();
    errdefer s.abortHistory();
    var retired: std.ArrayList([]const u8) = .empty;
    var root = try append(s, &.{.{ .blob = value }}, &retired);
    if (previous == null) root.blobs += 1;
    if (previous) |old| if (!old.deleted) {
        root.blobFiles -= 1;
        root.blobBytes -= try @import("vault_types.zig").sealedSize(old.size);
    };
    if (!value.deleted) {
        root.blobFiles += 1;
        root.blobBytes += try @import("vault_types.zig").sealedSize(value.size);
    } else try retired.append(s.allocator, try @import("attachment_blob.zig").filename(s.allocator, value.id));
    const before = s.state.history;
    errdefer if (!s.history_publication_started) {
        s.state.history = before;
    };
    s.state.history = root;
    try s.commitHistory(retired.items);
}
pub fn deleteBlob(s: *storage.Store, key: []const u8) !bool {
    var value = (try findBlob(s, s.allocator, key)) orelse return false;
    if (!value.deleted) {
        if (value.references) |count| if (count != 0) return error.AttachmentInUse;
        value.deleted = true;
        try putBlob(s, value);
    } else {
        try s.finishHistoryCleanup();
        return error.FileNotFound;
    }
    return true;
}
pub fn latestInvitation(s: *storage.Store, a: std.mem.Allocator, source_hash: []const u8) !?storage.Operation {
    var active = s.state.operations.len;
    while (active > 0) {
        active -= 1;
        const op = s.state.operations[active];
        if (std.mem.eql(u8, op.sourceInvitationHash, source_hash) and op.icalendar.len != 0 and !std.mem.eql(u8, op.outcome, "rejected")) return op;
    }
    var next = s.state.history.head;
    var next_buffer: [64]u8 = undefined;
    var remaining = s.state.history.pages;
    while (next.len != 0) {
        var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
        defer phase.deinit();
        const page = try readPage(s, phase.allocator(), next);
        if (remaining == 0 or page.sequence != remaining) return error.InvalidHistory;
        remaining -= 1;
        var index = page.records.len;
        while (index > 0) {
            index -= 1;
            switch (page.records[index]) {
                .operation => |op| {
                    if (std.mem.eql(u8, op.sourceInvitationHash, source_hash) and op.icalendar.len != 0 and !std.mem.eql(u8, op.outcome, "rejected")) return try clone(storage.Operation, a, op);
                },
                else => {},
            }
        }
        advance(&next, &next_buffer, page.previous);
    }
    if (remaining != 0) return error.InvalidHistory;
    return null;
}
pub fn source(s: *storage.Store, a: std.mem.Allocator, key: []const u8) !?Source {
    return if (try get(s, a, .draft, key)) |record| record.draft else null;
}
pub fn gmailLink(s: *storage.Store, a: std.mem.Allocator, key: []const u8) !?@import("draft_link.zig").Link {
    for (s.state.draftLinks) |link| if (std.mem.eql(u8, link.draftId, key)) return link;
    return if (try source(s, a, key)) |retained| retained.gmailLink else null;
}
pub fn draft(s: *storage.Store, a: std.mem.Allocator, key: []const u8) !?t.Draft {
    const retained = (try source(s, a, key)) orelse return null;
    if (retained.deleted) return error.ArchivedSourceDeleted;
    const raw = try s.readHistory(a, try fileName(a, "draft", retained.handle), storage.mail_record_bytes);
    if (!std.mem.eql(u8, &storage.Store.hash(raw), retained.hash)) return error.HistorySourceChanged;
    const result = try std.json.parseFromSliceLeaky(t.Draft, a, raw, .{ .allocate = .alloc_if_needed });
    if (!std.mem.eql(u8, result.id, key)) return error.InvalidHistory;
    return result;
}
fn writeNew(s: *storage.Store, role: []const u8, value: anytype) ![]const u8 {
    const handle = try @import("vault_storage.zig").Handle.create(s.io);
    const identity = try s.allocator.dupe(u8, &handle.text());
    const bytes = try j.encodeAlloc(s.allocator, value, .{});
    if (bytes.len > page_bytes) return error.HistoryPageTooLarge;
    try s.writeHistory(try fileName(s.allocator, role, identity), bytes);
    return identity;
}
/// Build unpublished pages and bucket replacements. The caller publishes the
/// returned root together with active-state changes in one Store.save.
fn append(s: *storage.Store, input: []const Record, retired: *std.ArrayList([]const u8)) !Root {
    var root = s.state.history;
    var locations: std.ArrayList(Location) = .empty;
    var offset: usize = 0;
    while (offset < input.len) {
        var end = @min(input.len, offset + page_limit);
        while (end > offset + 1 and @import("gmail_decode.zig").serializedBytes(input[offset..end]) > page_bytes - 1024) end -= 1;
        const page: Page = .{ .account = s.state.account, .previous = root.head, .sequence = root.pages + 1, .records = input[offset..end] };
        const handle = try writeNew(s, "page", page);
        for (page.records, 0..) |record, slot| {
            try locations.append(s.allocator, .{ .kind = std.meta.activeTag(record), .id = id(record), .page = handle, .slot = slot });
            if (record == .queue) try locations.append(s.allocator, .{ .kind = .queue, .id = try std.fmt.allocPrint(s.allocator, "\x00{s}", .{record.queue.operationId}), .page = handle, .slot = slot });
        }
        root.head = handle;
        root.pages += 1;
        offset = end;
    }
    for (0..bucket_count) |selected| {
        var entries: std.ArrayList(Location) = .empty;
        for (locations.items) |location| if (bucket(location.kind, location.id) == selected) try entries.append(s.allocator, location);
        if (entries.items.len == 0) continue;
        root.bucketEntries[selected] += entries.items.len;
        root.entries += entries.items.len;
        const previous = root.buckets[selected];
        var prior = previous;
        var merged: std.ArrayList(Location) = .empty;
        if (previous.len != 0) {
            const old = try readBucket(s, s.allocator, previous);
            if (old.entries.len + entries.items.len <= 128) {
                try merged.appendSlice(s.allocator, old.entries);
                prior = old.previous;
                try retired.append(s.allocator, try fileName(s.allocator, "index", previous));
            }
        }
        try merged.appendSlice(s.allocator, entries.items);
        var start: usize = 0;
        while (start < merged.items.len) {
            const end = @min(start + 128, merged.items.len);
            prior = try writeNew(s, "index", Bucket{ .account = s.state.account, .previous = prior, .entries = merged.items[start..end] });
            start = end;
        }
        root.buckets[selected] = prior;
    }
    return root;
}
pub fn settled(operation_value: storage.Operation) bool {
    if (!std.mem.eql(u8, operation_value.outcome, "applied") and !std.mem.eql(u8, operation_value.outcome, "rejected")) return false;
    if (operation_value.icalendar.len != 0 and std.mem.eql(u8, operation_value.outcome, "applied")) {
        const result = operation_value.calendarSync orelse return false;
        if (result.canRetry or result.state == .unknown or (result.state == .skipped and !std.mem.eql(u8, result.errorCode, "DeclinedReplyOnly") and !std.mem.eql(u8, result.errorCode, "RsvpOnlyRequested"))) return false;
    }
    return true;
}
fn archivable(s: *storage.Store, op: storage.Operation) bool {
    if (!settled(op)) return false;
    for (s.state.draftLinks) |link| if (std.mem.eql(u8, link.draftId, op.draftId) and (link.paused or link.phase == .unknown)) return false;
    for (s.state.sendQueue) |entry| if (std.mem.eql(u8, entry.operationId, op.id) and (entry.state == .queued or entry.state == .submitting or entry.state == .unknown)) return false;
    return true;
}
fn sourceEligible(s: *storage.Store, draft_id: []const u8) bool {
    if (std.mem.eql(u8, s.history_protected_draft, draft_id)) return false;
    for (s.state.draftLinks) |link| if (std.mem.eql(u8, link.draftId, draft_id) and (link.paused or link.phase == .unknown)) return false;
    for (s.state.sendQueue) |entry| if (std.mem.eql(u8, entry.draftId, draft_id) and (entry.state == .queued or entry.state == .submitting or entry.state == .unknown)) return false;
    for (s.state.operations) |entry| if (std.mem.eql(u8, entry.draftId, draft_id) and !settled(entry)) return false;
    return true;
}
fn sourceMatches(a: std.mem.Allocator, value: t.Draft, account: []const u8, op: storage.Operation) !bool {
    var calendar: ?[]const u8 = null;
    if (op.icalendar.len != 0) {
        var lines = std.mem.splitSequence(u8, op.icalendar, "\r\n");
        var output: std.ArrayList(u8) = .empty;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "DTSTAMP:")) continue;
            try output.appendSlice(a, line);
            try output.appendSlice(a, "\r\n");
        }
        calendar = output.items;
    }
    return std.mem.eql(u8, op.hash, &(try @import("send_outcome.zig").digest(a, value, account, calendar)));
}
/// Cloning is an explicit new message from a settled sent source. It must not
/// shed an active queue, uncertain submission, Gmail handoff or unfinished
/// Calendar continuation by merely changing the local draft ID.
pub fn cloneableSource(s: *storage.Store, draft_id: []const u8) !bool {
    if (!sourceEligible(s, draft_id)) return false;
    if (try source(s, s.allocator, draft_id)) |retained| {
        if (retained.deleted) return error.ArchivedSourceDeleted;
        return true;
    }
    // A known applied source remains usable when post-send archival failed.
    return immutableSource(s, draft_id);
}
/// A durable applied receipt protects its exact source even if archival could
/// not finish (for example, because the disk filled after provider acceptance).
pub fn immutableSource(s: *storage.Store, draft_id: []const u8) !bool {
    var candidate = false;
    for (s.state.operations) |op| if (std.mem.eql(u8, op.outcome, "applied") and std.mem.eql(u8, op.draftId, draft_id)) {
        candidate = true;
        break;
    };
    if (!candidate) return false;
    var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
    defer phase.deinit();
    const a = phase.allocator();
    const raw = try s.activeDraftBytes(a, draft_id);
    const value = try std.json.parseFromSliceLeaky(t.Draft, a, raw, .{ .allocate = .alloc_if_needed });
    for (s.state.operations) |op| if (std.mem.eql(u8, op.outcome, "applied") and std.mem.eql(u8, op.draftId, draft_id) and try sourceMatches(a, value, s.state.account, op)) return true;
    return false;
}
fn adjustBlobPins(s: *storage.Store, updates: *std.StringHashMap(Blob), ids: []const []const u8, increase: bool) !void {
    for (ids, 0..) |key, index| {
        var duplicate = false;
        for (ids[0..index]) |previous| duplicate = duplicate or std.mem.eql(u8, previous, key);
        if (duplicate) continue;
        const current = updates.get(key) orelse (try findBlob(s, s.allocator, key)) orelse continue;
        if (current.deleted) return error.AttachmentHandleNotFound;
        var changed = current;
        if (changed.references) |count| {
            if (!increase and count == 0) return error.InvalidHistory;
            changed.references = if (increase) count + 1 else count - 1;
            try updates.put(changed.id, changed);
        }
    }
}
pub fn compact(s: *storage.Store, force: bool) !void {
    if (!@import("send_memory.zig").native) return;
    if (!force and s.state.operations.len < 64 and s.state.drafts.len < 64 and s.state.sendQueue.len < 64) return;
    try s.finishHistoryCleanup();
    s.beginHistory();
    errdefer s.abortHistory();
    var records: std.ArrayList(Record) = .empty;
    var unindexed_blob_pins = s.state.history.unindexedBlobPins;
    var blob_pins: std.StringHashMap(Blob) = .init(s.allocator);
    defer blob_pins.deinit();
    var retained_operations: std.ArrayList([]const u8) = .empty;
    var operations: std.ArrayList(storage.Operation) = .empty;
    var drafts: std.ArrayList(t.Draft) = .empty;
    var queues: std.ArrayList(storage.QueuedSend) = .empty;
    var references: std.ArrayList(storage.DraftBlobReferences) = .empty;
    var gmail_links: std.ArrayList(@import("draft_link.zig").Link) = .empty;
    var retired: std.ArrayList([]const u8) = .empty;
    for (s.state.drafts) |summary| {
        var archived = false;
        var candidate = false;
        for (s.state.operations) |op| if (settled(op) and std.mem.eql(u8, op.outcome, "applied") and std.mem.eql(u8, op.draftId, summary.id)) {
            candidate = true;
            break;
        };
        if (candidate) {
            var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
            defer phase.deinit();
            const a = phase.allocator();
            const raw = try s.activeDraftBytes(a, summary.id);
            const value = try std.json.parseFromSliceLeaky(t.Draft, a, raw, .{ .allocate = .alloc_if_needed });
            var operation_index = s.state.operations.len;
            while (operation_index != 0) {
                operation_index -= 1;
                const op = s.state.operations[operation_index];
                if (!settled(op) or !std.mem.eql(u8, op.outcome, "applied") or !std.mem.eql(u8, op.draftId, summary.id) or !try sourceMatches(a, value, s.state.account, op)) continue;
                if (!sourceEligible(s, summary.id)) {
                    // Keep one exact candidate while a queue/unknown/Gmail
                    // fence prevents source settlement; older receipts can page.
                    try retained_operations.append(s.allocator, op.id);
                    break;
                }
                const handle = try @import("vault_storage.zig").Handle.create(s.io);
                const identity = try s.allocator.dupe(u8, &handle.text());
                try s.writeHistory(try fileName(s.allocator, "draft", identity), raw);
                var blobs: std.ArrayList([]const u8) = .empty;
                for (value.attachments) |attachment| if (attachment.blobId) |blob| try blobs.append(s.allocator, try s.allocator.dupe(u8, blob));
                if (value.original) |original| for (original.resources) |file| if (file.blobId) |key| try blobs.append(s.allocator, try s.allocator.dupe(u8, key));
                for (blobs.items) |key| if (try findBlob(s, s.allocator, key) == null) {
                    unindexed_blob_pins = true;
                };
                try adjustBlobPins(s, &blob_pins, blobs.items, true);
                var retained_link: ?@import("draft_link.zig").Link = null;
                for (s.state.draftLinks) |link| if (std.mem.eql(u8, link.draftId, summary.id)) {
                    retained_link = link;
                    break;
                };
                try records.append(s.allocator, .{ .draft = .{ .summary = summary, .handle = identity, .hash = try s.allocator.dupe(u8, &storage.Store.hash(raw)), .blobs = blobs.items, .gmailLink = retained_link } });
                try retired.appendSlice(s.allocator, try s.activeDraftOwnedRecords(s.allocator, summary.id));
                archived = true;
                break;
            }
        }
        if (!archived) {
            try drafts.append(s.allocator, summary);
            for (s.state.draftLinks) |link| if (std.mem.eql(u8, link.draftId, summary.id)) try gmail_links.append(s.allocator, link);
            for (s.state.relatedDraftBlobs) |refs| if (std.mem.eql(u8, refs.draftId, summary.id)) try references.append(s.allocator, refs);
        }
    }
    for (s.state.operations) |op| {
        var retained = false;
        for (retained_operations.items) |operation_id| retained = retained or std.mem.eql(u8, operation_id, op.id);
        if (!retained and archivable(s, op)) try records.append(s.allocator, .{ .operation = op }) else try operations.append(s.allocator, op);
    }
    for (s.state.sendQueue) |entry| {
        if (entry.state == .canceled or entry.state == .applied or entry.state == .rejected) try records.append(s.allocator, .{ .queue = entry }) else try queues.append(s.allocator, entry);
    }
    if (records.items.len == 0) return;
    var pin_values = blob_pins.valueIterator();
    while (pin_values.next()) |value| try records.append(s.allocator, .{ .blob = value.* });
    var root = try append(s, records.items, &retired);
    root.unindexedBlobPins = unindexed_blob_pins;
    root.operations += s.state.operations.len - operations.items.len;
    root.drafts += s.state.drafts.len - drafts.items.len;
    root.queues += s.state.sendQueue.len - queues.items.len;
    const before = s.state;
    errdefer if (!s.history_publication_started) {
        s.state = before;
    };
    s.state.history = root;
    s.state.schema = 2;
    s.state.operations = operations.items;
    s.state.drafts = drafts.items;
    s.state.relatedDraftBlobs = references.items;
    s.state.draftLinks = gmail_links.items;
    s.state.sendQueue = queues.items;
    try s.commitHistory(retired.items);
}

pub fn deleteSource(s: *storage.Store, draft_id: []const u8) !bool {
    if (!sourceEligible(s, draft_id)) return error.HistorySourceInUse;
    var retained = (try source(s, s.allocator, draft_id)) orelse return error.DraftNotFound;
    if (retained.deleted) return false;
    try s.finishHistoryCleanup();
    s.beginHistory();
    errdefer s.abortHistory();
    var retired: std.ArrayList([]const u8) = .empty;
    try retired.append(s.allocator, try fileName(s.allocator, "draft", retained.handle));
    retained.deleted = true;
    var records: std.ArrayList(Record) = .empty;
    try records.append(s.allocator, .{ .draft = retained });
    var updates: std.StringHashMap(Blob) = .init(s.allocator);
    defer updates.deinit();
    try adjustBlobPins(s, &updates, retained.blobs, false);
    var values = updates.valueIterator();
    while (values.next()) |value| try records.append(s.allocator, .{ .blob = value.* });
    const root = try append(s, records.items, &retired);
    const before = s.state.history;
    errdefer if (!s.history_publication_started) {
        s.state.history = before;
    };
    s.state.history = root;
    try s.commitHistory(retired.items);
    return true;
}

/// Explicit source deletion may also remove its now-unreferenced files. Keep
/// their identities in the tombstone so interrupted cleanup is retryable.
pub fn pruneSourceFiles(s: *storage.Store, draft_id: []const u8) !usize {
    const retained = (try source(s, s.allocator, draft_id)) orelse return error.DraftNotFound;
    if (!retained.deleted) return error.HistoryDeletionRequiresConfirmation;
    var removed: usize = 0;
    for (retained.blobs, 0..) |blob, index| {
        var duplicate = false;
        for (retained.blobs[0..index]) |previous| duplicate = duplicate or std.mem.eql(u8, previous, blob);
        if (duplicate or try s.blobReferencedVerified(blob)) continue;
        @import("attachment_blob.zig").discard(s, blob) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        removed += 1;
    }
    return removed;
}

pub fn blobReferenced(s: *storage.Store, key: []const u8) !bool {
    if (try findBlob(s, s.allocator, key)) |value| if (value.references) |count| return count != 0;
    var next = s.state.history.head;
    var next_buffer: [64]u8 = undefined;
    var remaining = s.state.history.pages;
    while (next.len != 0) {
        var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
        defer phase.deinit();
        const a = phase.allocator();
        const page = try readPage(s, a, next);
        if (page.sequence != remaining or remaining == 0) return error.InvalidHistory;
        remaining -= 1;
        for (page.records) |record| switch (record) {
            .draft => |retained| if (!retained.deleted) {
                for (retained.blobs) |blob| if (std.mem.eql(u8, blob, key)) {
                    const latest = (try source(s, a, retained.summary.id)) orelse return error.InvalidHistory;
                    if (!latest.deleted) return true;
                };
            },
            else => {},
        };
        advance(&next, &next_buffer, page.previous);
    }
    if (remaining != 0) return error.InvalidHistory;
    return false;
}

/// Paginated retained history. A cursor names an immutable snapshot, so later
/// sends cannot reorder or duplicate rows already visited by this traversal.
pub fn list(s: *storage.Store, a: std.mem.Allocator, kind: Kind, cursor: []const u8, limit: usize) !j.Value {
    if (limit == 0 or limit > 100) return error.InvalidPageLimit;
    const summaries = @import("draft_summary.zig");
    const Response = struct {
        fn finish(allocator: std.mem.Allocator, rows: j.Value, next_cursor: []const u8) !j.Value {
            var result = j.object(allocator);
            try result.object.put(allocator, "items", rows);
            try result.object.put(allocator, "nextCursor", .{ .string = next_cursor });
            try result.object.put(allocator, "retained", .{ .bool = true });
            return result;
        }
        fn candidate(allocator: std.mem.Allocator, record: Record) !j.Value {
            return switch (record) {
                .operation => |v| if (try summaries.encodedBytes(v) < summaries.list_bytes) j.value(allocator, v) else j.value(allocator, .{
                    .id = v.id,
                    .hash = v.hash,
                    .draftId = v.draftId,
                    .outcome = v.outcome,
                    .messageId = v.messageId,
                    .rfcMessageId = v.rfcMessageId,
                    .errorCode = v.errorCode,
                    .kind = v.kind,
                    .summaryOnly = true,
                    .readCommand = "operation.read",
                    .icalendarBytes = v.icalendar.len,
                }),
                .draft => |v| j.value(allocator, .{ .draft = summaries.listEntry(v.summary), .sourceDeleted = v.deleted, .sourceHash = v.hash, .gmailLink = v.gmailLink }),
                .queue => |v| j.value(allocator, v),
                .blob => |v| j.value(allocator, v),
            };
        }
    };
    var next = s.state.history.head;
    var next_buffer: [64]u8 = undefined;
    var remaining = s.state.history.pages;
    var skip: usize = 0;
    if (cursor.len != 0) {
        var fields = std.mem.splitScalar(u8, cursor, ':');
        next = fields.next() orelse return error.InvalidHistoryCursor;
        _ = @import("vault_storage.zig").Handle.parse(next) catch return error.InvalidHistoryCursor;
        remaining = std.fmt.parseInt(u64, fields.next() orelse return error.InvalidHistoryCursor, 10) catch return error.InvalidHistoryCursor;
        skip = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryCursor, 10) catch return error.InvalidHistoryCursor;
        if (fields.next() != null or skip > page_limit or remaining > s.state.history.pages) return error.InvalidHistoryCursor;
    }
    var rows: j.Value = .{ .array = .init(a) };
    var bytes: usize = 0;
    while (next.len != 0) {
        var phase: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
        defer phase.deinit();
        const temporary = phase.allocator();
        const page = try readPage(s, temporary, next);
        if (page.sequence != remaining or remaining == 0 or skip > page.records.len) return error.InvalidHistoryCursor;
        var index = page.records.len - skip;
        while (index > 0) {
            index -= 1;
            const record = page.records[index];
            if (std.meta.activeTag(record) != kind) continue;
            if (kind == .draft) {
                const latest = (try locate(s, temporary, .draft, id(record))) orelse return error.InvalidHistory;
                if (latest.slot != index or !std.mem.eql(u8, latest.page, next)) continue;
            }
            // Scratch dies after each candidate. Only admitted rows are
            // copied into the caller's ordinary response arena.
            var candidate_arena: std.heap.ArenaAllocator = .init(phaseBacking(s.allocator));
            defer candidate_arena.deinit();
            const value = try Response.candidate(candidate_arena.allocator(), record);
            const needed = try summaries.encodedBytes(value) + 1;
            if (needed > summaries.list_bytes) return error.HistoryListEntryTooLarge;
            if (needed > summaries.list_bytes - bytes) {
                // This candidate has not been returned. Resume before it,
                // including when a page contains nonmatching record kinds.
                return Response.finish(a, rows, try std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ next, remaining, page.records.len - index - 1 }));
            }
            try rows.array.append(try j.value(a, value));
            bytes += needed;
            if (rows.array.items.len == limit) return Response.finish(a, rows, try std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ next, remaining, page.records.len - index }));
        }
        remaining -= 1;
        advance(&next, &next_buffer, page.previous);
        skip = 0;
    }
    if (remaining != 0) return error.InvalidHistory;
    return Response.finish(a, rows, "");
}
