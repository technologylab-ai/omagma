//! Settled Calendar identity and operation fences. The Calendar document owns
//! these immutable pages; it publishes their roots together with active work.
const std = @import("std");
const storage = @import("store.zig");
const mail = @import("types.zig");
const t = @import("calendar_types.zig");
const plan = @import("calendar_plan.zig");
const svc = @import("calendar_service.zig");
const j = @import("json.zig");
pub const bucket_count = 64;
pub const page_entries = 32;
pub const page_bytes = 256 * 1024;
pub const Entry = struct {
    identity: plan.Identity,
    state: svc.State = .{},
    review: ?svc.Review = null,
    ordinary: bool = false,
    receipt_hash: ?[32]u8 = null,
    receipt_reserved: bool = false,
};
const Index = struct { heads: [bucket_count][]const u8 = @splat(""), counts: [bucket_count]u64 = @splat(0) };
pub const Root = struct { identities: Index = .{}, receipts: Index = .{} };
pub fn empty(root: Root) bool {
    for (root.identities.counts, root.receipts.counts) |identities, receipts| if (identities != 0 or receipts != 0) return false;
    return true;
}
const Kind = enum { identity, receipt };
const Page = struct { schema: u8 = 1, account: []const u8, kind: Kind, bucket: usize, sequence: u64, previous: []const u8 = "", entries: []const Entry };

fn backing(a: std.mem.Allocator) std.mem.Allocator {
    return if (mail.Limits.native) @import("send_memory.zig").allocator() else a;
}
fn index(root: *Root, kind: Kind) *Index {
    return if (kind == .identity) &root.identities else &root.receipts;
}
fn part(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hash.update(&length);
    hash.update(value);
}
fn bucket(kind: Kind, identity: plan.Identity, operation_id: []const u8) usize {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var lower: [254]u8 = undefined;
    const account = identity.target.account;
    std.debug.assert(account.len <= lower.len);
    for (account, lower[0..account.len]) |byte, *out| out.* = std.ascii.toLower(byte);
    part(&hash, lower[0..account.len]);
    if (kind == .identity) {
        part(&hash, identity.target.calendar_id);
        part(&hash, identity.uid);
        part(&hash, identity.recurrence_key);
    } else part(&hash, operation_id);
    return hash.finalResult()[0] % bucket_count;
}
pub fn validate(root: Root) !void {
    for ([_]Index{ root.identities, root.receipts }) |lane| for (lane.heads, lane.counts) |head, count| {
        if ((head.len == 0) != (count == 0) or count > mail.Limits.disk_hard) return error.CalendarHistoryCorrupt;
        if (head.len != 0) _ = try @import("vault_storage.zig").Handle.parse(head);
    };
}
fn validateEntry(entry: Entry) !void {
    try entry.identity.target.validate();
    try t.text(entry.identity.uid, 1024, false);
    try t.text(entry.identity.recurrence_key, 1024, true);
    if (entry.review != null or entry.receipt_reserved) return error.CalendarHistoryCorrupt;
    if (entry.state.tracked == null and entry.state.operation == null) return error.CalendarHistoryCorrupt;
    if (entry.state.tracked) |tracked| {
        if (!tracked.identity.eql(entry.identity)) return error.CalendarHistoryCorrupt;
        try t.text(tracked.event_id, 1024, false);
    }
    if (entry.state.operation) |operation| {
        try operation.intent.validate();
        if (operation.state == .unknown or !operation.intent.identity.eql(entry.identity)) return error.CalendarHistoryCorrupt;
        try t.text(operation.provider_id, 1024, operation.state != .applied);
        try t.text(operation.error_code, 128, true);
    } else if (entry.receipt_hash != null) return error.CalendarHistoryCorrupt;
}
fn readPage(store: *storage.Store, a: std.mem.Allocator, handle: []const u8, kind: Kind, selected: usize, remaining: u64) !Page {
    const raw = try store.readHistory(a, try @import("operation_history.zig").fileName(a, "calendar", handle), page_bytes);
    const page = try std.json.parseFromSliceLeaky(Page, a, raw, .{ .allocate = .alloc_if_needed });
    if (page.schema != 1 or !std.mem.eql(u8, page.account, store.state.account) or page.kind != kind or page.bucket != selected or page.sequence != remaining or page.entries.len == 0 or page.entries.len > page_entries or page.entries.len > remaining) return error.CalendarHistoryCorrupt;
    if (page.previous.len != 0) _ = try @import("vault_storage.zig").Handle.parse(page.previous);
    for (page.entries) |entry| {
        try validateEntry(entry);
        if (!std.ascii.eqlIgnoreCase(entry.identity.target.account, store.state.account)) return error.CalendarHistoryCorrupt;
        const operation_id = if (entry.state.operation) |operation| operation.intent.operation_id else "";
        if (kind == .receipt and operation_id.len == 0) return error.CalendarHistoryCorrupt;
        if (bucket(kind, entry.identity, operation_id) != selected) return error.CalendarHistoryCorrupt;
    }
    return page;
}
fn find(store: *storage.Store, a: std.mem.Allocator, root: Root, kind: Kind, identity: plan.Identity, operation_id: []const u8) !?Entry {
    var copied = root;
    const lane = index(&copied, kind);
    const selected = bucket(kind, identity, operation_id);
    var next = lane.heads[selected];
    var next_buffer: [64]u8 = undefined;
    var remaining = lane.counts[selected];
    while (next.len != 0) {
        var phase: std.heap.ArenaAllocator = .init(backing(store.allocator));
        defer phase.deinit();
        const page = try readPage(store, phase.allocator(), next, kind, selected, remaining);
        var position = page.entries.len;
        while (position > 0) {
            position -= 1;
            const entry = page.entries[position];
            const matches = if (kind == .identity) entry.identity.eql(identity) else std.mem.eql(u8, entry.state.operation.?.intent.operation_id, operation_id);
            if (matches) return try std.json.parseFromSliceLeaky(Entry, a, try j.encodeAlloc(a, entry, .{}), .{ .allocate = .alloc_if_needed });
        }
        remaining -= page.entries.len;
        if (page.previous.len == 0) next = "" else {
            @memcpy(&next_buffer, page.previous);
            next = &next_buffer;
        }
    }
    if (remaining != 0) return error.CalendarHistoryCorrupt;
    return null;
}
pub fn loadIdentity(store: *storage.Store, a: std.mem.Allocator, root: Root, key: plan.Identity) !?Entry {
    return find(store, a, root, .identity, key, "");
}
pub fn receipt(store: *storage.Store, a: std.mem.Allocator, root: Root, operation_id: []const u8) !?Entry {
    return find(store, a, root, .receipt, .{ .target = .{ .account = store.state.account, .calendar_id = "" }, .uid = "" }, operation_id);
}
/// New roots are private until the enclosing Calendar document is published.
/// Older pages stay reachable, retaining every operation and UID fence.
pub fn append(store: *storage.Store, root: Root, entries: []const Entry) !Root {
    var result = root;
    for ([_]Kind{ .identity, .receipt }) |kind| for (0..bucket_count) |selected| {
        var grouped: std.ArrayList(Entry) = .empty;
        for (entries) |entry| {
            try validateEntry(entry);
            const operation_id = if (entry.state.operation) |operation| operation.intent.operation_id else "";
            if (kind == .receipt and operation_id.len == 0) continue;
            if (bucket(kind, entry.identity, operation_id) == selected) try grouped.append(store.allocator, entry);
        }
        const lane = index(&result, kind);
        var start: usize = 0;
        while (start < grouped.items.len) {
            var end = @min(start + page_entries, grouped.items.len);
            while (end > start + 1 and @import("gmail_decode.zig").serializedBytes(grouped.items[start..end]) > page_bytes - 4096) end -= 1;
            const sequence = lane.counts[selected] + end - start;
            const page: Page = .{ .account = store.state.account, .kind = kind, .bucket = selected, .sequence = sequence, .previous = lane.heads[selected], .entries = grouped.items[start..end] };
            const encoded = try j.encodeAlloc(store.allocator, page, .{});
            if (encoded.len > page_bytes) return error.CalendarHistoryCorrupt;
            const handle = try @import("vault_storage.zig").Handle.create(store.io);
            const text = try store.allocator.dupe(u8, &handle.text());
            try store.writeHistory(try @import("operation_history.zig").fileName(store.allocator, "calendar", text), encoded);
            lane.heads[selected] = text;
            lane.counts[selected] = sequence;
            start = end;
        }
    };
    return result;
}
pub fn verify(store: *storage.Store, root: Root) !void {
    try validate(root);
    var copied = root;
    for ([_]Kind{ .identity, .receipt }) |kind| {
        const lane = index(&copied, kind);
        for (lane.heads, lane.counts, 0..) |head, count, selected| {
            var next = head;
            var next_buffer: [64]u8 = undefined;
            var remaining = count;
            while (next.len != 0) {
                var phase: std.heap.ArenaAllocator = .init(backing(store.allocator));
                defer phase.deinit();
                const page = try readPage(store, phase.allocator(), next, kind, selected, remaining);
                remaining -= page.entries.len;
                if (page.previous.len == 0) next = "" else {
                    @memcpy(&next_buffer, page.previous);
                    next = &next_buffer;
                }
            }
            if (remaining != 0) return error.CalendarHistoryCorrupt;
        }
    }
}
