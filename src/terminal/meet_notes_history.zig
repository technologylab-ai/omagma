//! Immutable settled Meet fences, owned by the companion document's root.
//! Active work stays bounded; settled confirmations are never forgotten merely
//! to admit another meeting. The account disk quota remains the storage bound.
const std = @import("std");
const records = @import("meet_notes_types.zig");
const storage = @import("store.zig");
const j = @import("json.zig");
const handles = @import("vault_storage.zig");
const history = @import("operation_history.zig");
const mail = @import("types.zig");

pub const bucket_count = 64;
pub const page_bytes = 256 * 1024;
pub const Root = struct { heads: [bucket_count][]const u8 = @splat(""), counts: [bucket_count]u64 = @splat(0) };
const Page = struct { schema: u8 = 1, account: []const u8, bucket: usize, sequence: u64, previous: []const u8 = "", entries: []const records.Entry };

fn bucket(id: []const u8) usize {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &hash, .{});
    return hash[0] % bucket_count;
}
pub fn validate(root: Root) !void {
    for (root.heads, root.counts) |head, count| {
        if ((head.len == 0) != (count == 0) or count > mail.Limits.disk_hard) return error.InvalidMeetHistory;
        if (head.len != 0) _ = try handles.Handle.parse(head);
    }
}
pub fn settled(entry: records.Entry) bool {
    return !entry.protected() and entry.calendar_review == null and switch (entry.phase) {
        .confirmed, .refused, .abandoned => true,
        else => false,
    };
}
fn readPage(store: *storage.Store, a: std.mem.Allocator, head: []const u8, selected: usize, remaining: u64) !Page {
    const raw = try store.readHistory(a, try history.fileName(a, "meet", head), page_bytes);
    const page = try std.json.parseFromSliceLeaky(Page, a, raw, .{ .allocate = .alloc_if_needed });
    if (page.schema != 1 or !std.mem.eql(u8, page.account, store.state.account) or page.bucket != selected or page.sequence != remaining or page.entries.len == 0 or page.entries.len > 32 or page.entries.len > remaining) return error.InvalidMeetHistory;
    if (page.previous.len != 0) _ = try handles.Handle.parse(page.previous);
    for (page.entries) |entry| {
        try entry.validate(a, store.state.account);
        if (!settled(entry) or bucket(entry.consent.operation_id) != selected) return error.InvalidMeetHistory;
    }
    return page;
}
pub fn find(store: *storage.Store, out: std.mem.Allocator, root: Root, operation_id: []const u8) !?records.Entry {
    try validate(root);
    const selected = bucket(operation_id);
    var next = root.heads[selected];
    var buffer: [64]u8 = undefined;
    var remaining = root.counts[selected];
    while (next.len != 0) {
        var arena = std.heap.ArenaAllocator.init(if (mail.Limits.native) @import("send_memory.zig").allocator() else store.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const page = try readPage(store, a, next, selected, remaining);
        for (page.entries) |entry| if (std.mem.eql(u8, entry.consent.operation_id, operation_id)) {
            return try std.json.parseFromSliceLeaky(records.Entry, out, try j.encodeAlloc(out, entry, .{}), .{ .allocate = .alloc_if_needed });
        };
        remaining -= page.entries.len;
        if (page.previous.len == 0) next = "" else {
            @memcpy(&buffer, page.previous);
            next = &buffer;
        }
    }
    if (remaining != 0) return error.InvalidMeetHistory;
    return null;
}
pub fn append(store: *storage.Store, root: Root, entries: []const records.Entry) !Root {
    try validate(root);
    // Validation hashes serialized consent/request bytes. Do it once per row
    // in reusable scratch, not once per bucket in the transaction arena.
    for (entries) |entry| {
        var scratch = std.heap.ArenaAllocator.init(if (mail.Limits.native) @import("send_memory.zig").allocator() else store.allocator);
        defer scratch.deinit();
        try entry.validate(scratch.allocator(), store.state.account);
        if (!settled(entry)) return error.InvalidMeetHistory;
    }
    var result = root;
    for (0..bucket_count) |selected| {
        var grouped: std.ArrayList(records.Entry) = .empty;
        for (entries) |entry| {
            if (bucket(entry.consent.operation_id) == selected) try grouped.append(store.allocator, entry);
        }
        var start: usize = 0;
        while (start < grouped.items.len) {
            var end = @min(start + 32, grouped.items.len);
            while (end > start + 1 and @import("gmail_decode.zig").serializedBytes(grouped.items[start..end]) > page_bytes - 4096) end -= 1;
            const sequence = try std.math.add(u64, result.counts[selected], end - start);
            const page: Page = .{ .account = store.state.account, .bucket = selected, .sequence = sequence, .previous = result.heads[selected], .entries = grouped.items[start..end] };
            var scratch = std.heap.ArenaAllocator.init(if (mail.Limits.native) @import("send_memory.zig").allocator() else store.allocator);
            defer scratch.deinit();
            const bytes = try j.encodeAlloc(scratch.allocator(), page, .{});
            if (bytes.len > page_bytes) return error.MeetContinuationFull;
            const handle = try handles.Handle.create(store.io);
            const text = try store.allocator.dupe(u8, &handle.text());
            try store.writeHistory(try history.fileName(store.allocator, "meet", text), bytes);
            result.heads[selected] = text;
            result.counts[selected] = sequence;
            start = end;
        }
    }
    return result;
}
pub fn verify(store: *storage.Store, root: Root) !void {
    try validate(root);
    for (root.heads, root.counts, 0..) |head, count, selected| {
        var next = head;
        var buffer: [64]u8 = undefined;
        var remaining = count;
        while (next.len != 0) {
            var arena = std.heap.ArenaAllocator.init(if (mail.Limits.native) @import("send_memory.zig").allocator() else store.allocator);
            defer arena.deinit();
            const page = try readPage(store, arena.allocator(), next, selected, remaining);
            remaining -= page.entries.len;
            if (page.previous.len == 0) next = "" else {
                @memcpy(&buffer, page.previous);
                next = &buffer;
            }
        }
        if (remaining != 0) return error.InvalidMeetHistory;
    }
}
