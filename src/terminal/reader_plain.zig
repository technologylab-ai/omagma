//! A sparse, bounded plaintext layout index. Checkpoints retain the complete
//! iterator state, including soft-wrap whitespace and partial tab expansion.
const std = @import("std");
const vaxis = @import("vaxis");
const layout = @import("text_layout.zig");
const reader_tools = @import("reader_tools.zig");

pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    text: []const u8,
    links: []const reader_tools.LinkRange,
    quotes: bool,
    signatures: bool,
    width: u16 = 0,
    method: vaxis.gwidth.Method = .unicode,
    ready: bool = false,
    rows: usize = 0,
    builds: usize = 0,
    checkpoints: std.ArrayList(Checkpoint) = .empty,
    const Checkpoint = struct { row: usize, iterator: layout.Iterator };
    // At most one checkpoint per 1 KiB of source, additionally capped per body.
    // The retained conversation has a separate 4 MiB serialized-body budget.
    const max_checkpoints = 2048;

    pub fn init(allocator: std.mem.Allocator, clean: []const u8, quotes: bool, signatures: bool) !Prepared {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const source = try a.dupe(u8, clean);
        const folded = try reader_tools.fold(a, source, quotes, signatures);
        const shown = try reader_tools.displayLinks(a, folded.text);
        return .{ .arena = arena, .allocator = allocator, .text = shown.text, .links = shown.ranges, .quotes = quotes, .signatures = signatures };
    }
    pub fn deinit(self: *Prepared) void {
        self.checkpoints.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn ensure(self: *Prepared, width: u16, method: vaxis.gwidth.Method) !void {
        if (self.ready and self.width == width and self.method == method) return;
        self.ready = false;
        self.checkpoints.clearRetainingCapacity();
        self.width = width;
        self.method = method;
        var iterator = layout.Iterator.init(self.text, width, method, .{});
        var next_byte: usize = 1024;
        var next_row: usize = 32;
        while (true) {
            const before = iterator;
            const glyph = iterator.next() orelse break;
            if (glyph.position.row > before.position.row and glyph.position.row >= next_row and glyph.byte_offset >= next_byte and self.checkpoints.items.len < max_checkpoints) {
                try self.checkpoints.append(self.allocator, .{ .row = glyph.position.row, .iterator = before });
                next_byte = glyph.byte_offset +| 1024;
                next_row = glyph.position.row +| 32;
            }
        }
        self.rows = iterator.position.row + 1;
        self.builds += 1;
        self.ready = true;
    }
    pub fn iteratorAt(self: *const Prepared, row: usize) layout.Iterator {
        var lo: usize = 0;
        var hi = self.checkpoints.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.checkpoints.items[mid].row <= row) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) layout.Iterator.init(self.text, self.width, self.method, .{}) else self.checkpoints.items[lo - 1].iterator;
    }
};

test "prepared reader: sparse viewport preserves Unicode tabs whitespace and exact rows" {
    const a = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..800) |_| try text.appendSlice(a, "words  onboarding a\u{301}界 👩‍💻\n\tcode\n\n");
    var prepared = try Prepared.init(a, text.items, false, false);
    defer prepared.deinit();
    for ([_]u16{ 3, 23, 71 }) |width| {
        try prepared.ensure(width, .unicode);
        const builds = prepared.builds;
        try prepared.ensure(width, .unicode);
        try std.testing.expectEqual(builds, prepared.builds);
        var full = layout.Iterator.init(prepared.text, width, .unicode, .{});
        const target = prepared.rows / 2;
        var sparse = prepared.iteratorAt(target);
        try std.testing.expect(sparse.offset > 0);
        var expected = full.next();
        while (expected != null and expected.?.position.row < target) expected = full.next();
        var actual = sparse.next();
        while (actual != null and actual.?.position.row < target) actual = sparse.next();
        for (0..100) |_| {
            try std.testing.expectEqual(expected.?.position, actual.?.position);
            try std.testing.expectEqual(expected.?.byte_offset, actual.?.byte_offset);
            try std.testing.expectEqualStrings(expected.?.text, actual.?.text);
            expected = full.next();
            actual = sparse.next();
        }
        while (full.next()) |_| {}
        try std.testing.expectEqual(full.position.row + 1, prepared.rows);
        try std.testing.expect(prepared.checkpoints.items.len <= Prepared.max_checkpoints);
    }
}
