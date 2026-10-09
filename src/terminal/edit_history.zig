//! Native field undo/redo. Snapshots are owned, count- and byte-bounded, and
//! contain cursor positions so a restoration never splits a UTF-8 character.
const std = @import("std");
pub const max_entries = 64;
pub const max_snapshot_bytes = 2 * 1024 * 1024;
pub const max_bytes = 4 * 1024 * 1024;
pub const Snapshot = struct { text: []const u8, cursor: usize };
pub const History = struct {
    past: [max_entries]Snapshot = undefined,
    future: [max_entries]Snapshot = undefined,
    past_count: usize = 0,
    future_count: usize = 0,
    bytes: usize = 0,
    restored: ?Snapshot = null,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }
    pub fn clear(self: *History, allocator: std.mem.Allocator) void {
        for (self.past[0..self.past_count]) |entry| allocator.free(entry.text);
        for (self.future[0..self.future_count]) |entry| allocator.free(entry.text);
        if (self.restored) |entry| allocator.free(entry.text);
        self.* = .{};
    }
    fn releaseRestored(self: *History, allocator: std.mem.Allocator) void {
        if (self.restored) |entry| {
            allocator.free(entry.text);
            self.bytes -= entry.text.len;
            self.restored = null;
        }
    }
    fn evict(self: *History, allocator: std.mem.Allocator, future: bool) void {
        const entries = if (future) &self.future else &self.past;
        const count = if (future) &self.future_count else &self.past_count;
        std.debug.assert(count.* > 0);
        allocator.free(entries[0].text);
        self.bytes -= entries[0].text.len;
        std.mem.copyForwards(Snapshot, entries[0 .. count.* - 1], entries[1..count.*]);
        count.* -= 1;
    }
    fn copy(allocator: std.mem.Allocator, text: []const u8, cursor: usize) !Snapshot {
        if (text.len > max_snapshot_bytes) return error.HistoryInputTooLarge;
        if (!std.unicode.utf8ValidateSlice(text) or cursor > text.len or (cursor < text.len and text[cursor] & 0xc0 == 0x80)) return error.InvalidHistoryCursor;
        return .{ .text = try allocator.dupe(u8, text), .cursor = cursor };
    }
    /// Record immediately before a content mutation, not cursor movement.
    /// A new edit always clears redo. Failed edits can use discardRecord().
    pub fn record(self: *History, allocator: std.mem.Allocator, text: []const u8, cursor: usize) !void {
        const entry = try copy(allocator, text, cursor);
        self.releaseRestored(allocator);
        for (self.future[0..self.future_count]) |old| {
            allocator.free(old.text);
            self.bytes -= old.text.len;
        }
        self.future_count = 0;
        while (self.past_count == max_entries or self.bytes + entry.text.len > max_bytes) self.evict(allocator, false);
        self.past[self.past_count] = entry;
        self.past_count += 1;
        self.bytes += entry.text.len;
    }
    pub fn discardRecord(self: *History, allocator: std.mem.Allocator) void {
        if (self.past_count == 0) return;
        self.past_count -= 1;
        const entry = self.past[self.past_count];
        allocator.free(entry.text);
        self.bytes -= entry.text.len;
    }
    /// Returned text belongs to History and lasts until its next mutation.
    /// Apply using a Field setter that does not record another edit.
    pub fn undo(self: *History, allocator: std.mem.Allocator, text: []const u8, cursor: usize) !?Snapshot {
        return self.restore(allocator, text, cursor, false);
    }
    pub fn redo(self: *History, allocator: std.mem.Allocator, text: []const u8, cursor: usize) !?Snapshot {
        return self.restore(allocator, text, cursor, true);
    }
    fn restore(self: *History, allocator: std.mem.Allocator, text: []const u8, cursor: usize, forward: bool) !?Snapshot {
        const source = if (forward) &self.future else &self.past;
        const source_count = if (forward) &self.future_count else &self.past_count;
        if (source_count.* == 0) return null;
        const current = try copy(allocator, text, cursor);
        self.releaseRestored(allocator);
        source_count.* -= 1;
        const target = source[source_count.*];
        // Target remains accounted for and owned by restored below.
        const destination = if (forward) &self.past else &self.future;
        const destination_count = if (forward) &self.past_count else &self.future_count;
        while (destination_count.* == max_entries) self.evict(allocator, !forward);
        while (self.bytes + current.text.len > max_bytes) {
            if (source_count.* > 0) self.evict(allocator, forward) else self.evict(allocator, !forward);
        }
        destination[destination_count.*] = current;
        destination_count.* += 1;
        self.bytes += current.text.len;
        self.restored = target;
        return target;
    }
};

test "native undo: cursor restoration redo branch and UTF8 remain correct" {
    const allocator = std.testing.allocator;
    var history: History = .{};
    defer history.deinit(allocator);
    try history.record(allocator, "Café", 3);
    try history.record(allocator, "Ca!fé", 3);
    const first = (try history.undo(allocator, "Ca!?fé", 4)).?;
    try std.testing.expectEqualStrings("Ca!fé", first.text);
    try std.testing.expectEqual(@as(usize, 3), first.cursor);
    const second = (try history.undo(allocator, first.text, first.cursor)).?;
    try std.testing.expectEqualStrings("Café", second.text);
    const again = (try history.redo(allocator, second.text, second.cursor)).?;
    try std.testing.expectEqualStrings("Ca!fé", again.text);
    try history.record(allocator, again.text, 2);
    try std.testing.expect((try history.redo(allocator, "New branch", 10)) == null);
    try std.testing.expectError(error.InvalidHistoryCursor, history.record(allocator, "Café", 4));
}
test "native undo: count and byte caps evict oldest snapshots" {
    const allocator = std.testing.allocator;
    var history: History = .{};
    defer history.deinit(allocator);
    for (0..max_entries + 5) |_| try history.record(allocator, "x", 1);
    try std.testing.expectEqual(max_entries, history.past_count);
    history.clear(allocator);
    const large = try allocator.alloc(u8, max_snapshot_bytes);
    defer allocator.free(large);
    @memset(large, 'x');
    for (0..4) |_| try history.record(allocator, large, large.len);
    try std.testing.expectEqual(@as(usize, 2), history.past_count);
    try std.testing.expectEqual(max_bytes, history.bytes);
    _ = try history.undo(allocator, large, large.len);
    try std.testing.expect(history.bytes <= max_bytes);
}
