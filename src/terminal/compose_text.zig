//! Retained, inert composer text and sparse layout checkpoints. A cursor move
//! or repaint visits the visible area instead of copying the complete body.
const std = @import("std");
const vaxis = @import("vaxis");
const layout = @import("text_layout.zig");
const Allocator = std.mem.Allocator;
const stride = 4096;
const Map = struct { raw: usize, clean: usize };
const Cap = struct { start: usize, end: usize, output: usize };
const Checkpoint = struct { iterator: layout.Iterator, previous: layout.Position, previous_end: usize };

const Token = struct { consumed: usize, bytes: []const u8 };
fn token(raw: []const u8) Token {
    const len = std.unicode.utf8ByteSequenceLength(raw[0]) catch return .{ .consumed = 1, .bytes = "?" };
    if (len > raw.len) return .{ .consumed = raw.len, .bytes = "" };
    const cp = std.unicode.utf8Decode(raw[0..len]) catch return .{ .consumed = 1, .bytes = "?" };
    const control = cp != '\n' and cp != '\t' and (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069));
    return .{ .consumed = len, .bytes = if (control) " " else raw[0..len] };
}

pub const Cache = struct {
    text_arena: ?std.heap.ArenaAllocator = null,
    layout_arena: ?std.heap.ArenaAllocator = null,
    text: []const u8 = "",
    maps: []const Map = &.{},
    caps: []const Cap = &.{},
    checkpoints: []const Checkpoint = &.{},
    revision: ?u64 = null,
    raw_pointer: usize = 0,
    raw_length: usize = 0,
    width: u16 = 0,
    method: vaxis.gwidth.Method = .unicode,
    rows: usize = 1,
    text_builds: usize = 0,
    layout_builds: usize = 0,

    pub fn deinit(self: *Cache) void {
        if (self.layout_arena) |*arena| arena.deinit();
        if (self.text_arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn ensure(self: *Cache, a: Allocator, raw: []const u8, revision: u64, width: u16, method: vaxis.gwidth.Method) !void {
        if (self.revision == null or self.revision.? != revision or self.raw_pointer != @intFromPtr(raw.ptr) or self.raw_length != raw.len) {
            try self.replaceText(a, raw);
            self.revision = revision;
            self.raw_pointer = @intFromPtr(raw.ptr);
            self.raw_length = raw.len;
        }
        if (self.layout_arena == null or self.width != width or self.method != method) try self.replaceLayout(a, width, method);
    }
    fn replaceText(self: *Cache, a: Allocator, raw: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const buffer = try owned.alloc(u8, raw.len);
        var maps: std.ArrayList(Map) = .empty;
        try maps.ensureTotalCapacityPrecise(owned, raw.len / stride + 2);
        try maps.append(owned, .{ .raw = 0, .clean = 0 });
        var input: usize = 0;
        var output: usize = 0;
        var checkpoint: usize = stride;
        while (input < raw.len) {
            const next = token(raw[input..]);
            @memcpy(buffer[output..][0..next.bytes.len], next.bytes);
            input += next.consumed;
            output += next.bytes.len;
            if (input >= checkpoint) {
                try maps.append(owned, .{ .raw = input, .clean = output });
                checkpoint = input + stride;
            }
        }
        // Bound a pathological grapheme without retaining a second body copy.
        // Only >128-byte spans need a map entry, so this metadata is bounded
        // by source bytes even for an adversarial combining-mark paragraph.
        var caps: std.ArrayList(Cap) = .empty;
        var graphemes = vaxis.unicode.graphemeIterator(buffer[0..output]);
        var written: usize = 0;
        while (graphemes.next()) |gr| {
            const shown = if (gr.len > 128) "�" else buffer[gr.start..][0..gr.len];
            if (gr.len > 128) try caps.append(owned, .{ .start = gr.start, .end = gr.start + gr.len, .output = written });
            std.mem.copyForwards(u8, buffer[written..][0..shown.len], shown);
            written += shown.len;
        }
        if (self.layout_arena) |*previous| previous.deinit();
        self.layout_arena = null;
        self.checkpoints = &.{};
        if (self.text_arena) |*previous| previous.deinit();
        self.text_arena = arena;
        self.text = buffer[0..written];
        self.maps = maps.items;
        self.caps = caps.items;
        self.text_builds += 1;
    }
    fn replaceLayout(self: *Cache, a: Allocator, width: u16, method: vaxis.gwidth.Method) !void {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var points: std.ArrayList(Checkpoint) = .empty;
        try points.ensureTotalCapacityPrecise(owned, self.text.len / stride + 2);
        var iterator = layout.Iterator.init(self.text, width, method, .{});
        var previous: layout.Position = .{};
        var previous_end: usize = 0;
        try points.append(owned, .{ .iterator = iterator, .previous = previous, .previous_end = previous_end });
        var checkpoint: usize = stride;
        while (iterator.next()) |glyph| {
            previous = glyph.position;
            previous.column +|= glyph.columns;
            previous_end = iterator.offset;
            if (iterator.offset >= checkpoint and iterator.tab_left == 0) {
                try points.append(owned, .{ .iterator = iterator, .previous = previous, .previous_end = previous_end });
                checkpoint = iterator.offset + stride;
            }
        }
        if (self.layout_arena) |*old| old.deinit();
        self.layout_arena = arena;
        self.checkpoints = points.items;
        self.rows = iterator.position.row + 1;
        self.width = width;
        self.method = method;
        self.layout_builds += 1;
    }
    pub fn cleanCursor(self: *const Cache, raw: []const u8, cursor: usize) usize {
        const at = @min(cursor, raw.len);
        var low: usize = 0;
        var high = self.maps.len;
        while (low + 1 < high) {
            const mid = (low + high) / 2;
            if (self.maps[mid].raw <= at) low = mid else high = mid;
        }
        var input = self.maps[low].raw;
        var output = self.maps[low].clean;
        while (input < at) {
            const next = token(raw[input..at]);
            input += next.consumed;
            output += next.bytes.len;
        }
        low = 0;
        high = self.caps.len;
        while (low < high) {
            const mid = (low + high) / 2;
            if (self.caps[mid].start <= output) low = mid + 1 else high = mid;
        }
        if (low == 0) return @min(output, self.text.len);
        const cap = self.caps[low - 1];
        if (output < cap.end) return cap.output;
        return @min(cap.output + "�".len + output - cap.end, self.text.len);
    }
    pub fn caret(self: *const Cache, raw: []const u8, cursor: usize) layout.Position {
        if (self.width == 0) return .{};
        const at = self.cleanCursor(raw, cursor);
        var low: usize = 0;
        var high = self.checkpoints.len;
        while (low + 1 < high) {
            const mid = (low + high) / 2;
            if (self.checkpoints[mid].iterator.offset <= at) low = mid else high = mid;
        }
        const point = self.checkpoints[low];
        var iterator = point.iterator;
        var previous = point.previous;
        var previous_end = point.previous_end;
        while (iterator.next()) |glyph| {
            if (at == glyph.byte_offset or (at > glyph.byte_offset and at < iterator.offset)) return glyph.position;
            if (at < glyph.byte_offset) break;
            previous = glyph.position;
            previous.column +|= glyph.columns;
            previous_end = iterator.offset;
        }
        for (self.text[@min(previous_end, at)..at]) |byte| if (byte == '\n') previous.newline();
        if (previous.column >= self.width) previous.newline();
        return previous;
    }
    pub fn viewport(self: *const Cache, row: usize) layout.Iterator {
        var low: usize = 0;
        var high = self.checkpoints.len;
        while (low + 1 < high) {
            const mid = (low + high) / 2;
            // Start before the first glyph in the requested row, even when
            // several checkpoints lie within the same long logical line.
            if (self.checkpoints[mid].iterator.position.row < row) low = mid else high = mid;
        }
        return self.checkpoints[low].iterator;
    }
};

test "compose text cache: cursor and viewport match complete Unicode layout without repaint allocation" {
    const a = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    for (0..2048) |_| try raw.appendSlice(a, "Words 界 é 👩‍💻\t a long line wraps here.\n\n");
    var cache: Cache = .{};
    defer cache.deinit();
    for ([_]u16{ 17, 38, 80 }) |width| {
        try cache.ensure(a, raw.items, 1, width, .unicode);
        for ([_]usize{ 0, 1, 4095, 4096, 8190, raw.items.len - 1, raw.items.len }) |at| {
            try std.testing.expectEqual(layout.caret(cache.text, cache.cleanCursor(raw.items, at), width, .unicode, .words), cache.caret(raw.items, at));
        }
        const first_row = cache.rows -| 12;
        var full = layout.Iterator.init(cache.text, width, .unicode, .{});
        var view = cache.viewport(first_row);
        var visited: usize = 0;
        var visible = view.next();
        while (visible != null and visible.?.position.row < first_row) {
            visited += 1;
            visible = view.next();
        }
        while (full.next()) |glyph| {
            if (glyph.position.row < first_row) continue;
            try std.testing.expectEqualDeep(glyph, visible.?);
            visible = view.next();
        }
        try std.testing.expect(visited < stride * 2);
    }
    const builds = cache.layout_builds;
    var failed = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    for (0..100) |at| {
        try cache.ensure(failed.allocator(), raw.items, 1, 80, .unicode);
        _ = cache.caret(raw.items, raw.items.len - at);
        _ = cache.viewport(cache.rows -| 8);
    }
    try std.testing.expectEqual(@as(usize, 1), cache.text_builds);
    try std.testing.expectEqual(builds, cache.layout_builds);
}

test "compose text cache: terminal controls invalid bytes and oversized graphemes preserve raw cursor mapping" {
    const a = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try raw.appendSlice(a, "A\x1bB\u{202e}C\xffD\n");
    try raw.appendSlice(a, "x");
    for (0..100) |_| try raw.appendSlice(a, "\u{301}");
    try raw.appendSlice(a, "END");
    var cache: Cache = .{};
    defer cache.deinit();
    try cache.ensure(a, raw.items, 1, 80, .unicode);
    try std.testing.expectEqualStrings("A B C?D\n�END", cache.text);
    try std.testing.expectEqualStrings("A\x1bB\u{202e}C\xffD\n", raw.items[0..10]);
    try std.testing.expectEqual(@as(usize, 4), cache.cleanCursor(raw.items, 6));
    try std.testing.expectEqual(@as(usize, 8), cache.cleanCursor(raw.items, 20));
    try std.testing.expectEqual(cache.text.len, cache.cleanCursor(raw.items, raw.items.len));
}
