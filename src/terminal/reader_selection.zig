//! Selection over the reader's sanitized, displayed body lines. The caller
//! excludes other messages, decoration and folded content, and resets the model
//! whenever its pinned source, width, width method or folding generation changes.
//! A width-only rebuild may restore a mark if its pinned source stays unchanged.
//! Text is owned here; no frame-arena or provider slices survive addLine.
const std = @import("std");
const vaxis = @import("vaxis");
const text_layout = @import("text_layout.zig");

pub const max_text_bytes = 2 * 1024 * 1024;
pub const max_lines = 65536;
pub const Mode = enum { off, character, line };
pub const Join = enum { separate, space, none };
pub const Motion = enum { left, right, up, down, word_forward, word_backward, word_end, line_start, line_end, first, last };
pub const Position = struct { line: usize = 0, byte: usize = 0 };
/// A resize handoff within the same account/message/source scope. Offsets are
/// grapheme starts in logical text; the fingerprint is a change detector, not
/// an identity check. The caller must still pin the received-message identity.
pub const SelectionMark = struct { mode: Mode, anchor: usize, cursor: usize, fingerprint: u64 };
pub const LineOptions = struct {
    column: u16 = 0,
    byte_base: usize = 0,
    /// How this line follows the preceding displayed line. Continuation
    /// padding is excluded by the caller, but retains its column/byte offset.
    join: Join = .separate,
};
pub const Line = struct {
    row: usize,
    offset: usize,
    len: usize,
    column: u16,
    byte_base: usize,
    join: Join,
    // Filled once while collecting/finishing, keeping selection paint O(1)
    // in the number of wrapped rows in a logical paragraph.
    logical_start: u32,
    logical_end: u32,
};
pub const Range = struct {
    /// Exclusive end; both bytes include the supplied byte_base.
    start: usize,
    end: usize,
    start_column: usize,
    end_column: usize,
};
const Bounds = struct { start: Position, end: Position };

fn before(left: Position, right: Position) bool {
    return left.line < right.line or (left.line == right.line and left.byte < right.byte);
}
fn same(left: Position, right: Position) bool {
    return left.line == right.line and left.byte == right.byte;
}
fn graphemeEnd(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    var iterator = vaxis.unicode.graphemeIterator(text[at..]);
    const gr = iterator.next() orelse return text.len;
    return at + gr.len;
}

pub const Model = struct {
    bytes: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Line) = .empty,
    generation: u64 = 0,
    width: u16 = 0,
    method: vaxis.gwidth.Method = .unicode,
    mode: Mode = .off,
    anchor: Position = .{},
    cursor: Position = .{},
    ready: bool = false,
    failed: bool = false,
    preferred_column: ?usize = null,
    prefer_end: bool = false,

    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        self.lines.deinit(a);
        self.* = .{};
    }
    pub fn reset(self: *Model, a: std.mem.Allocator, generation: u64, width: u16, method: vaxis.gwidth.Method) void {
        _ = a;
        self.bytes.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.generation = generation;
        self.width = width;
        self.method = method;
        self.ready = false;
        self.failed = false;
        self.cancel();
    }
    pub fn cancel(self: *Model) void {
        self.mode = .off;
        self.anchor = .{};
        self.cursor = .{};
        self.preferred_column = null;
        self.prefer_end = false;
    }
    pub fn active(self: *const Model) bool {
        return self.mode != .off and self.ready and !self.failed and self.lines.items.len != 0;
    }
    pub fn count(self: *const Model) usize {
        return self.lines.items.len;
    }
    /// Lines arrive in increasing reader-body rows. They contain no newlines,
    /// tabs or terminal controls: layout has already expanded/sanitized those.
    /// A glyph extending beyond the viewport is omitted, just as in painting.
    pub fn addLine(self: *Model, a: std.mem.Allocator, row: usize, text: []const u8, options: LineOptions) !void {
        errdefer {
            self.failed = true;
            self.ready = false;
            self.cancel();
        }
        if (self.failed or self.ready) return error.InvalidReaderSelection;
        if (self.lines.items.len >= max_lines or text.len > max_text_bytes) return error.ReaderSelectionTooLarge;
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].row >= row) return error.InvalidReaderSelection;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        for (text) |byte| if (byte < 32 or byte == 127) return error.InvalidReaderSelection;
        if (options.byte_base > max_text_bytes or options.column > self.width) return error.InvalidReaderSelection;
        const offset = self.bytes.items.len;
        var column: usize = options.column;
        var iterator = vaxis.unicode.graphemeIterator(text);
        while (iterator.next()) |gr| {
            const shown = text_layout.cellGrapheme(gr.bytes(text), self.method);
            const columns = @max(vaxis.gwidth.gwidth(shown, self.method), 1);
            if (column + columns > self.width) break;
            // Reserve a byte per line for hard breaks/linewise trailing newline.
            if (shown.len > max_text_bytes -| self.bytes.items.len -| (self.lines.items.len + 1)) return error.ReaderSelectionTooLarge;
            try self.bytes.appendSlice(a, shown);
            column += columns;
        }
        const length = self.bytes.items.len - offset;
        if (length > max_text_bytes - options.byte_base) return error.InvalidReaderSelection;
        if (self.bytes.items.len + self.lines.items.len + 1 > max_text_bytes) return error.ReaderSelectionTooLarge;
        const index = self.lines.items.len;
        const logical_start: u32 = if (index == 0 or options.join == .separate) @intCast(index) else self.lines.items[index - 1].logical_start;
        try self.lines.append(a, .{ .row = row, .offset = offset, .len = length, .column = options.column, .byte_base = options.byte_base, .join = options.join, .logical_start = logical_start, .logical_end = @intCast(index) });
    }
    pub fn finish(self: *Model) void {
        self.ready = !self.failed;
        if (self.failed) return;
        var index = self.lines.items.len;
        var logical_end: u32 = 0;
        while (index > 0) {
            index -= 1;
            if (index + 1 == self.lines.items.len or self.lines.items[index + 1].join == .separate) logical_end = @intCast(index);
            self.lines.items[index].logical_end = logical_end;
        }
    }
    pub fn lineText(self: *const Model, index: usize) []const u8 {
        if (index >= self.lines.items.len) return "";
        const line = self.lines.items[index];
        return self.bytes.items[line.offset..][0..line.len];
    }
    fn lowerRow(self: *const Model, row: usize) usize {
        var low: usize = 0;
        var high = self.lines.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.lines.items[middle].row < row) low = middle + 1 else high = middle;
        }
        return low;
    }
    pub fn containsRow(self: *const Model, row: usize) bool {
        const index = self.lowerRow(row);
        return index < self.lines.items.len and self.lines.items[index].row == row;
    }
    fn lastByte(self: *const Model, index: usize) usize {
        var iterator = vaxis.unicode.graphemeIterator(self.lineText(index));
        var at: usize = 0;
        while (iterator.next()) |gr| at = gr.start;
        return at;
    }
    fn atColumn(self: *const Model, index: usize, column: usize) Position {
        var iterator = vaxis.unicode.graphemeIterator(self.lineText(index));
        var x: usize = self.lines.items[index].column;
        var last: usize = 0;
        while (iterator.next()) |gr| {
            const width = @max(vaxis.gwidth.gwidth(gr.bytes(self.lineText(index)), self.method), 1);
            if (column < x + width) return .{ .line = index, .byte = gr.start };
            x += width;
            last = gr.start;
        }
        return .{ .line = index, .byte = last };
    }
    /// Hit-testing clamps both outside rows and a wide glyph's trailing cells
    /// to a whole displayed grapheme. Use containsRow before starting a drag
    /// so non-body UI rows cannot start a selection.
    pub fn positionAt(self: *const Model, row: usize, column: usize) ?Position {
        if (!self.ready or self.failed or self.lines.items.len == 0) return null;
        var index = self.lowerRow(row);
        if (index == self.lines.items.len) index -= 1 else if (index > 0 and self.lines.items[index].row != row) {
            if (row - self.lines.items[index - 1].row < self.lines.items[index].row - row) index -= 1;
        }
        return self.atColumn(index, column);
    }
    fn columnAt(self: *const Model, index: usize, byte: usize) usize {
        const text = self.lineText(index);
        var column: usize = self.lines.items[index].column;
        var iterator = vaxis.unicode.graphemeIterator(text);
        while (iterator.next()) |gr| {
            if (gr.start >= byte) break;
            column += @max(vaxis.gwidth.gwidth(gr.bytes(text), self.method), 1);
        }
        return column;
    }
    pub fn cursorRow(self: *const Model) ?usize {
        return if (self.active()) self.lines.items[self.cursor.line].row else null;
    }
    pub fn cursorColumn(self: *const Model) ?usize {
        return if (self.active()) self.columnAt(self.cursor.line, self.cursor.byte) else null;
    }
    pub fn begin(self: *Model, mode: Mode, row: usize, column: usize) bool {
        if (mode == .off) {
            self.cancel();
            return false;
        }
        const point = self.positionAt(row, column) orelse return false;
        self.mode = mode;
        self.anchor = point;
        self.cursor = point;
        self.preferred_column = null;
        self.prefer_end = false;
        return true;
    }
    pub fn extend(self: *Model, row: usize, column: usize) void {
        if (!self.active()) return;
        self.cursor = self.positionAt(row, column) orelse return;
        self.preferred_column = null;
        self.prefer_end = false;
    }
    pub fn swapEnds(self: *Model) void {
        if (!self.active()) return;
        std.mem.swap(Position, &self.anchor, &self.cursor);
        self.preferred_column = null;
        self.prefer_end = false;
    }
    fn logicalStart(self: *const Model, line: usize) usize {
        return self.lines.items[line].logical_start;
    }
    fn logicalEnd(self: *const Model, line: usize) usize {
        return self.lines.items[line].logical_end;
    }
    fn bounds(self: *const Model) Bounds {
        var result: Bounds = if (before(self.cursor, self.anchor)) .{ .start = self.cursor, .end = self.anchor } else .{ .start = self.anchor, .end = self.cursor };
        if (self.mode == .line) {
            result.start = .{ .line = self.logicalStart(result.start.line) };
            const end = self.logicalEnd(result.end.line);
            result.end = .{ .line = end, .byte = self.lastByte(end) };
        }
        return result;
    }
    fn logicalOffset(self: *const Model, point: Position) usize {
        var offset: usize = point.byte;
        for (0..point.line) |index| offset += self.lines.items[index].len;
        for (1..point.line + 1) |index| if (self.lines.items[index].join != .none) {
            offset += 1;
        };
        return offset;
    }
    fn fingerprint(self: *const Model) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.lines.items, 0..) |line, index| {
            if (index > 0) switch (line.join) {
                .separate => hash.update("\n"),
                .space => hash.update(" "),
                .none => {},
            };
            hash.update(self.lineText(index));
        }
        return hash.final();
    }
    fn fromLogicalOffset(self: *const Model, wanted: usize) ?Position {
        var offset: usize = 0;
        for (self.lines.items, 0..) |line, index| {
            if (index > 0 and line.join != .none) offset += 1;
            if (wanted >= offset and (wanted < offset + line.len or (line.len == 0 and wanted == offset))) {
                const byte = wanted - offset;
                if (line.len == 0) return .{ .line = index };
                var iterator = vaxis.unicode.graphemeIterator(self.lineText(index));
                while (iterator.next()) |gr| {
                    if (gr.start == byte) return .{ .line = index, .byte = byte };
                    if (gr.start > byte) return null;
                }
                return null;
            }
            offset += line.len;
        }
        // An endpoint that became an omitted wrap separator is ambiguous.
        // Cancel rather than silently selecting an adjacent visible character.
        return null;
    }
    pub fn mark(self: *const Model) ?SelectionMark {
        if (!self.active()) return null;
        return .{ .mode = self.mode, .anchor = self.logicalOffset(self.anchor), .cursor = self.logicalOffset(self.cursor), .fingerprint = self.fingerprint() };
    }
    pub fn restore(self: *Model, saved: SelectionMark) bool {
        self.cancel();
        if (!self.ready or self.failed or self.lines.items.len == 0 or saved.mode == .off or saved.fingerprint != self.fingerprint()) return false;
        const anchor = self.fromLogicalOffset(saved.anchor) orelse return false;
        const cursor = self.fromLogicalOffset(saved.cursor) orelse return false;
        self.mode = saved.mode;
        self.anchor = anchor;
        self.cursor = cursor;
        return true;
    }
    pub fn range(self: *const Model, row: usize) ?Range {
        if (!self.active()) return null;
        const index = self.lowerRow(row);
        if (index == self.lines.items.len or self.lines.items[index].row != row) return null;
        const selected = self.bounds();
        if (index < selected.start.line or index > selected.end.line) return null;
        const line = self.lines.items[index];
        const text = self.lineText(index);
        const start = if (self.mode == .character and index == selected.start.line) selected.start.byte else 0;
        const end = if (self.mode == .character and index == selected.end.line) graphemeEnd(text, selected.end.byte) else text.len;
        return .{ .start = line.byte_base + start, .end = line.byte_base + end, .start_column = self.columnAt(index, start), .end_column = self.columnAt(index, end) };
    }
    pub fn move(self: *Model, motion: Motion) bool {
        if (!self.active()) return false;
        const prior = self.cursor;
        switch (motion) {
            .up, .down => {
                if (self.preferred_column == null) self.preferred_column = self.columnAt(self.cursor.line, self.cursor.byte);
                const index = if (motion == .up) self.cursor.line -| 1 else @min(self.cursor.line + 1, self.lines.items.len - 1);
                self.cursor = if (self.prefer_end) .{ .line = index, .byte = self.lastByte(index) } else self.atColumn(index, self.preferred_column.?);
            },
            else => {
                self.preferred_column = null;
                self.prefer_end = false;
                switch (motion) {
                    .left => {
                        var iterator = vaxis.unicode.graphemeIterator(self.lineText(self.cursor.line));
                        var previous: usize = 0;
                        while (iterator.next()) |gr| {
                            if (gr.start >= self.cursor.byte) break;
                            previous = gr.start;
                        }
                        self.cursor.byte = previous;
                    },
                    .right => self.cursor.byte = @min(graphemeEnd(self.lineText(self.cursor.line), self.cursor.byte), self.lastByte(self.cursor.line)),
                    .line_start => self.cursor = .{ .line = self.logicalStart(self.cursor.line) },
                    .line_end => {
                        self.cursor.line = self.logicalEnd(self.cursor.line);
                        self.cursor.byte = self.lastByte(self.cursor.line);
                        self.prefer_end = true;
                    },
                    .first => self.cursor = .{},
                    .last => self.cursor = .{ .line = self.lines.items.len - 1 },
                    .word_forward, .word_backward, .word_end => self.cursor = self.wordTarget(motion),
                    .up, .down => unreachable,
                }
            },
        }
        return !same(prior, self.cursor);
    }
    fn wordTarget(self: *const Model, motion: Motion) Position {
        var iterator: Words = .{ .model = self };
        var previous = self.cursor;
        while (iterator.next()) |word| {
            switch (motion) {
                .word_forward => if (before(self.cursor, word.start)) return word.start,
                .word_end => if (before(self.cursor, word.end)) return word.end,
                .word_backward => {
                    if (!before(word.start, self.cursor)) return previous;
                    previous = word.start;
                },
                else => unreachable,
            }
        }
        return if (motion == .word_backward) previous else .{ .line = self.lines.items.len - 1, .byte = self.lastByte(self.lines.items.len - 1) };
    }
    /// Caller owns the returned bytes. Soft wraps use the layout's join, hard
    /// breaks use LF, and linewise copies end with LF. No padding is invented.
    pub fn copy(self: *Model, a: std.mem.Allocator) ![]u8 {
        errdefer self.cancel();
        if (!self.active()) return error.NoReaderSelection;
        const selected = self.bounds();
        var length: usize = 0;
        for (selected.start.line..selected.end.line + 1) |index| {
            const line = self.lines.items[index];
            const part = self.range(line.row).?;
            length += part.end - part.start;
            if (index > selected.start.line and line.join != .none) length += 1;
        }
        if (self.mode == .line) length += 1;
        if (length == 0) return error.NoReaderSelection;
        if (length > max_text_bytes) return error.ReaderSelectionTooLarge;
        const result = try a.alloc(u8, length);
        var offset: usize = 0;
        for (selected.start.line..selected.end.line + 1) |index| {
            const line = self.lines.items[index];
            if (index > selected.start.line and line.join != .none) {
                result[offset] = if (line.join == .space) ' ' else '\n';
                offset += 1;
            }
            const part = self.range(line.row).?;
            const text = self.lineText(index)[part.start - line.byte_base .. part.end - line.byte_base];
            @memcpy(result[offset..][0..text.len], text);
            offset += text.len;
        }
        if (self.mode == .line) result[offset] = '\n';
        return result;
    }
};

const WordClass = enum { space, word, punctuation };
fn wordClass(text: []const u8) WordClass {
    const size = std.unicode.utf8ByteSequenceLength(text[0]) catch unreachable;
    const cp = std.unicode.utf8Decode(text[0..size]) catch unreachable;
    switch (cp) {
        ' ', 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => return .space,
        else => {},
    }
    if (cp < 128) return if (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_') .word else .punctuation;
    // Preserve Unicode graphemes; common typographic/CJK punctuation and emoji
    // form punctuation runs instead of swallowing the adjacent prose word.
    return switch (cp) {
        0x200b...0x206f,
        0x2e00...0x2e7f,
        0x3001...0x3004,
        0x3008...0x3020,
        0xfe10...0xfe1f,
        0xfe30...0xfe6f,
        0xff01...0xff0f,
        0xff1a...0xff20,
        0xff3b...0xff40,
        0xff5b...0xff65,
        0x1f000...0x1faff,
        => .punctuation,
        else => .word,
    };
}
const Word = struct { start: Position, end: Position, class: WordClass };
/// One bounded forward scan supports all word motions. In particular b never
/// repeatedly rescans a long line backwards one grapheme at a time.
const Words = struct {
    model: *const Model,
    line: usize = 0,
    byte: usize = 0,
    run: ?Word = null,
    fn take(self: *Words) ?Word {
        const result = self.run;
        self.run = null;
        return result;
    }
    fn next(self: *Words) ?Word {
        while (self.line < self.model.lines.items.len) {
            const text = self.model.lineText(self.line);
            if (self.byte == text.len) {
                self.line += 1;
                self.byte = 0;
                if (self.line == self.model.lines.items.len or self.model.lines.items[self.line].join != .none) {
                    if (self.run != null) return self.take();
                }
                continue;
            }
            const point: Position = .{ .line = self.line, .byte = self.byte };
            const end = graphemeEnd(text, self.byte);
            const class = wordClass(text[self.byte..end]);
            self.byte = end;
            if (class == .space) {
                if (self.run != null) return self.take();
            } else if (self.run) |*run| {
                if (run.class == class) run.end = point else {
                    const previous = run.*;
                    self.run = .{ .start = point, .end = point, .class = class };
                    return previous;
                }
            } else self.run = .{ .start = point, .end = point, .class = class };
        }
        return self.take();
    }
};

test "reader selection: mouse wide cells and motions preserve combined graphemes" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 1, 24, .unicode);
    try model.addLine(a, 7, "A界e\u{301}👩‍💻Z", .{ .column = 2, .byte_base = 4 });
    model.finish();
    try std.testing.expect(model.begin(.character, 7, 4)); // Right half of 界.
    var selected = model.range(7).?;
    try std.testing.expectEqualDeep(Range{ .start = 5, .end = 8, .start_column = 3, .end_column = 5 }, selected);
    try std.testing.expect(model.move(.right));
    try std.testing.expectEqual(@as(usize, 5), model.cursorColumn().?);
    try std.testing.expect(model.move(.right));
    selected = model.range(7).?;
    try std.testing.expectEqual(@as(usize, 8), selected.end_column);
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("界e\u{301}👩‍💻", copied);
    try std.testing.expect(model.move(.left));
    try std.testing.expectEqual(@as(usize, "A界".len), model.cursor.byte);
    model.extend(7, 9999);
    try std.testing.expectEqual(@as(usize, 8), model.cursorColumn().?);
}

test "reader selection: reverse multiline copies omit padding and rejoin soft wraps" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 4, 40, .unicode);
    try model.addLine(a, 10, "Alpha meeting", .{});
    try model.addLine(a, 11, "notes cont", .{ .column = 2, .byte_base = 2, .join = .space });
    try model.addLine(a, 12, "inue here", .{ .column = 2, .byte_base = 2, .join = .none });
    try model.addLine(a, 14, "Last line", .{});
    model.finish();
    try std.testing.expect(model.begin(.character, 14, 3));
    model.extend(10, 6);
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("meeting notes continue here\nLast", copied);
    try std.testing.expectEqual(@as(usize, 2), model.range(11).?.start);
    try std.testing.expectEqual(@as(usize, 2), model.range(11).?.start_column);
    try std.testing.expect(model.range(13) == null);
    try std.testing.expect(!model.containsRow(13));
}

test "reader selection: line mode and zero dollar follow logical lines across soft wraps" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 1, 20, .unicode);
    try model.addLine(a, 4, "Alpha meeting", .{});
    try model.addLine(a, 5, "notes cont", .{ .column = 2, .byte_base = 2, .join = .space });
    try model.addLine(a, 6, "inue here", .{ .column = 2, .byte_base = 2, .join = .none });
    try model.addLine(a, 7, "Next paragraph", .{});
    model.finish();
    try std.testing.expect(model.begin(.line, 5, 4));
    try std.testing.expect(model.range(4) != null and model.range(6) != null);
    try std.testing.expect(model.range(7) == null);
    const linewise = try model.copy(a);
    defer a.free(linewise);
    try std.testing.expectEqualStrings("Alpha meeting notes continue here\n", linewise);
    try std.testing.expect(model.begin(.character, 5, 4));
    _ = model.move(.line_start);
    try std.testing.expectEqualDeep(Position{ .line = 0 }, model.cursor);
    model.swapEnds();
    _ = model.move(.line_end);
    try std.testing.expectEqualDeep(Position{ .line = 2, .byte = 8 }, model.cursor);
    const whole = try model.copy(a);
    defer a.free(whole);
    try std.testing.expectEqualStrings("Alpha meeting notes continue here", whole);
}

test "reader selection: unchanged logical text reanchors Unicode and reversed selection after resize" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 7, 40, .unicode);
    try model.addLine(a, 4, "Alpha 界e\u{301} 👩‍💻 omega", .{});
    try model.addLine(a, 5, "Second", .{});
    model.finish();
    try std.testing.expect(model.begin(.character, 4, 6));
    model.extend(4, 11);
    model.swapEnds();
    const mark = model.mark().?;
    model.reset(a, 8, 12, .unicode);
    try model.addLine(a, 10, "Alpha", .{});
    try model.addLine(a, 20, "界e\u{301}", .{ .column = 2, .byte_base = 2, .join = .space });
    try model.addLine(a, 30, "👩‍💻 omega", .{ .column = 2, .byte_base = 2, .join = .space });
    try model.addLine(a, 40, "Second", .{});
    model.finish();
    try std.testing.expect(model.restore(mark));
    try std.testing.expectEqualDeep(Position{ .line = 2 }, model.anchor);
    try std.testing.expectEqualDeep(Position{ .line = 1 }, model.cursor);
    try std.testing.expectEqual(@as(usize, 20), model.cursorRow().?);
    try std.testing.expectEqual(@as(usize, 2), model.cursorColumn().?);
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("界e\u{301} 👩‍💻", copied);
    try std.testing.expectEqualDeep(mark, model.mark().?);
    // A linewise handoff still includes all soft continuations after reflow.
    model.mode = .line;
    const line_mark = model.mark().?;
    model.reset(a, 9, 40, .unicode);
    try model.addLine(a, 0, "Alpha 界e\u{301} 👩‍💻 omega", .{});
    try model.addLine(a, 1, "Second", .{});
    model.finish();
    try std.testing.expect(model.restore(line_mark));
    const linewise = try model.copy(a);
    defer a.free(linewise);
    try std.testing.expectEqualStrings("Alpha 界e\u{301} 👩‍💻 omega\n", linewise);
}

test "reader selection: changed text and ambiguous resize endpoints cancel the selection" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 0, 20, .unicode);
    try model.addLine(a, 0, "alpha beta", .{});
    model.finish();
    try std.testing.expect(model.begin(.character, 0, 5));
    model.extend(0, 8);
    const mark = model.mark().?;
    model.reset(a, 1, 5, .unicode);
    try model.addLine(a, 0, "alpha", .{});
    try model.addLine(a, 1, "beta", .{ .join = .space });
    model.finish();
    try std.testing.expect(!model.restore(mark)); // Selected space is now omitted.
    try std.testing.expect(!model.active());
    model.reset(a, 2, 20, .unicode);
    try model.addLine(a, 0, "alpha beto", .{});
    model.finish();
    try std.testing.expect(!model.restore(mark));
    model.reset(a, 3, 20, .unicode);
    try model.addLine(a, 0, "界", .{});
    model.finish();
    try std.testing.expect(model.begin(.character, 0, 0));
    var malformed = model.mark().?;
    malformed.anchor = 1;
    try std.testing.expect(!model.restore(malformed));
    try std.testing.expectError(error.NoReaderSelection, model.copy(a));
}

test "reader selection: visual lines and vertical goal columns survive short and empty rows" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 2, 20, .unicode);
    try model.addLine(a, 2, "abcdef", .{});
    try model.addLine(a, 3, "界", .{});
    try model.addLine(a, 4, "", .{});
    try model.addLine(a, 5, "uvwxyz", .{});
    model.finish();
    try std.testing.expect(model.begin(.line, 2, 4));
    _ = model.move(.down);
    try std.testing.expectEqual(@as(usize, 0), model.cursorColumn().?);
    _ = model.move(.down);
    _ = model.move(.down);
    try std.testing.expectEqual(@as(usize, 4), model.cursorColumn().?);
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("abcdef\n界\n\nuvwxyz\n", copied);
    _ = model.move(.line_end);
    _ = model.move(.up);
    _ = model.move(.up);
    _ = model.move(.up);
    try std.testing.expectEqual(@as(usize, 5), model.cursorColumn().?);
    _ = model.move(.first);
    try std.testing.expectEqual(@as(usize, 2), model.cursorRow().?);
    _ = model.move(.last);
    try std.testing.expectEqual(@as(usize, 5), model.cursorRow().?);
}

test "reader selection: Vim word motions cross wraps without splitting Unicode" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 9, 30, .unicode);
    try model.addLine(a, 0, "hello, café", .{});
    try model.addLine(a, 1, "report con", .{ .join = .space });
    try model.addLine(a, 2, "tinued 👩‍💻 done", .{ .join = .none });
    model.finish();
    try std.testing.expect(model.begin(.character, 0, 0));
    _ = model.move(.word_end);
    try std.testing.expectEqualDeep(Position{ .line = 0, .byte = 4 }, model.cursor);
    _ = model.move(.word_forward);
    try std.testing.expectEqualDeep(Position{ .line = 0, .byte = 5 }, model.cursor);
    _ = model.move(.word_forward);
    try std.testing.expectEqualDeep(Position{ .line = 0, .byte = 7 }, model.cursor);
    _ = model.move(.word_end);
    try std.testing.expectEqualDeep(Position{ .line = 0, .byte = 10 }, model.cursor);
    _ = model.move(.word_forward);
    try std.testing.expectEqualDeep(Position{ .line = 1, .byte = 0 }, model.cursor);
    _ = model.move(.word_forward);
    try std.testing.expectEqualDeep(Position{ .line = 1, .byte = 7 }, model.cursor);
    _ = model.move(.word_end);
    try std.testing.expectEqualDeep(Position{ .line = 2, .byte = 5 }, model.cursor);
    _ = model.move(.word_backward);
    try std.testing.expectEqualDeep(Position{ .line = 1, .byte = 7 }, model.cursor);
    _ = model.move(.word_backward);
    try std.testing.expectEqualDeep(Position{ .line = 1, .byte = 0 }, model.cursor);
}

test "reader selection: source generation reset cancels stale ranges and owns source bytes" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    var source = [_]u8{ 's', 'a', 'f', 'e' };
    model.reset(a, 10, 8, .unicode);
    try model.addLine(a, 4, &source, .{});
    source[0] = 'X';
    model.finish();
    try std.testing.expect(model.begin(.line, 4, 0));
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("safe\n", copied);
    model.reset(a, 11, 3, .unicode);
    try std.testing.expect(!model.active());
    try std.testing.expect(model.range(4) == null);
    try std.testing.expectError(error.NoReaderSelection, model.copy(a));
    try model.addLine(a, 8, "A界B", .{});
    model.finish();
    try std.testing.expect(model.begin(.line, 999, 999));
    const narrow = try model.copy(a);
    defer a.free(narrow);
    try std.testing.expectEqualStrings("A界\n", narrow);
    model.cancel();
    try std.testing.expect(!model.move(.right));
}

test "reader selection: terminal width methods retain the complete emoji on every occupied cell" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    const Case = struct { method: vaxis.gwidth.Method, emoji_width: usize };
    for ([_]Case{ .{ .method = .unicode, .emoji_width = 2 }, .{ .method = .wcwidth, .emoji_width = 4 }, .{ .method = .no_zwj, .emoji_width = 4 } }) |case| {
        model.reset(a, 1, 20, case.method);
        try model.addLine(a, 0, "Q👩‍💻Z", .{});
        model.finish();
        for (1..1 + case.emoji_width) |column| {
            try std.testing.expect(model.begin(.character, 0, column));
            try std.testing.expectEqual(@as(usize, 1), model.cursor.byte);
            try std.testing.expectEqual(@as(usize, 1 + case.emoji_width), model.range(0).?.end_column);
            const copied = try model.copy(a);
            defer a.free(copied);
            try std.testing.expectEqualStrings("👩‍💻", copied);
        }
    }
}

test "reader selection: aggregate displayed text and copy share a hard two MiB limit" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 0, 1023, .unicode);
    const line: [1023]u8 = @splat('x');
    for (0..2048) |row| try model.addLine(a, row, &line, .{});
    model.finish();
    try std.testing.expect(model.begin(.line, 0, 0));
    model.extend(2047, 1022);
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqual(max_text_bytes, copied.len);
    try std.testing.expectEqual(@as(u8, 'x'), copied[0]);
    try std.testing.expectEqual(@as(u8, '\n'), copied[copied.len - 1]);
    // Build a fresh generation to exercise overflow during real collection.
    model.reset(a, 1, 1023, .unicode);
    for (0..2048) |row| try model.addLine(a, row, &line, .{});
    try std.testing.expectError(error.ReaderSelectionTooLarge, model.addLine(a, 2048, "", .{}));
    model.finish();
    try std.testing.expect(!model.begin(.line, 0, 0));
    try std.testing.expectError(error.NoReaderSelection, model.copy(a));
}

test "reader selection: invalid or oversized projection never exposes a partial copy" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 0, 80, .unicode);
    try model.addLine(a, 1, "first", .{});
    try std.testing.expectError(error.InvalidReaderSelection, model.addLine(a, 1, "duplicate", .{}));
    model.finish();
    try std.testing.expect(!model.begin(.character, 1, 0));
    try std.testing.expectError(error.NoReaderSelection, model.copy(a));
    model.reset(a, 1, 80, .unicode);
    try std.testing.expectError(error.InvalidUtf8, model.addLine(a, 1, "\xff", .{}));
    model.reset(a, 2, 80, .unicode);
    try std.testing.expectError(error.InvalidReaderSelection, model.addLine(a, 1, "raw\tinput", .{}));
    model.reset(a, 3, 80, .unicode);
    const oversized = try a.alloc(u8, max_text_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.ReaderSelectionTooLarge, model.addLine(a, 1, oversized, .{}));
    model.finish();
    try std.testing.expect(!model.active());
}

test "reader selection: allocation failures cancel copying without invalidating owned storage" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    model.reset(a, 0, 20, .unicode);
    try model.addLine(a, 0, "owned text", .{});
    model.finish();
    try std.testing.expect(model.begin(.line, 0, 0));
    var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, model.copy(failing.allocator()));
    try std.testing.expect(!model.active());
    try std.testing.expectEqualStrings("owned text", model.lineText(0));
    try std.testing.expect(model.begin(.line, 0, 0));
    const copied = try model.copy(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("owned text\n", copied);
}
