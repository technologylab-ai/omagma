//! Shared, allocation-free plaintext layout for measurement, rendering and caret.
const std = @import("std");
const vaxis = @import("vaxis");
pub const Mode = enum { words, literal };
pub const Position = struct {
    row: usize = 0,
    column: u16 = 0,
    pub fn wrap(self: *Position, columns: u16, available: u16) void {
        if (self.column +| columns > available) {
            self.row += 1;
            self.column = 0;
        }
    }
    pub fn advance(self: *Position, columns: u16, available: u16) void {
        self.wrap(columns, available);
        self.column +|= columns;
    }
    pub fn newline(self: *Position) void {
        self.row += 1;
        self.column = 0;
    }
};
pub const Options = struct { mode: Mode = .words, marker_at: ?usize = null, base_row: usize = 0 };
pub const Glyph = struct { text: []const u8, columns: u16, position: Position, byte_offset: usize, marker: bool = false };
fn standaloneAscii(input: []const u8, offset: usize) bool {
    // A following non-ASCII code point may join this ASCII character (combining
    // marks, variation selectors/keycaps or ZWJ). Keep those on the unchanged
    // Unicode path. Printable ASCII followed by ASCII/end is one cell in every
    // supported terminal width method; CR/LF/control clustering is excluded.
    return input[offset] >= 0x20 and input[offset] < 0x7f and (offset + 1 == input.len or input[offset + 1] < 0x80);
}
pub const Iterator = struct {
    text: []const u8,
    width: u16,
    method: vaxis.gwidth.Method,
    options: Options,
    offset: usize = 0,
    position: Position,
    marker_done: bool = false,
    token_end: usize = 0,
    literal_line: bool = false,
    line_start: bool = true,
    tab_left: u16 = 0,
    tab_offset: usize = 0,
    whitespace_end: usize = 0,
    next_word_end: usize = 0,
    next_word_columns: u16 = 0,
    pub fn init(text: []const u8, width: u16, method: vaxis.gwidth.Method, options: Options) Iterator {
        return .{ .text = text, .width = width, .method = method, .options = options, .position = .{ .row = options.base_row } };
    }
    fn white(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\r';
    }
    fn wordWidth(self: *const Iterator, start: usize, end: usize) u16 {
        var result: u16 = 0;
        const word = self.text[start..end];
        var prefix: usize = 0;
        while (prefix < word.len and standaloneAscii(word, prefix)) : (prefix += 1) {
            result +|= 1;
            if (result > self.width) break;
        }
        if (result <= self.width and prefix < word.len) {
            const tail = word[prefix..];
            var graphemes = vaxis.unicode.graphemeIterator(tail);
            while (graphemes.next()) |gr| {
                const raw = gr.bytes(tail);
                result +|= @max(vaxis.gwidth.gwidth(if (raw.len > 128) "�" else raw, self.method), 1);
                if (result > self.width) break;
            }
        }
        if (self.options.marker_at) |at| {
            if (!self.marker_done and at >= start and at <= end) result +|= 1;
        }
        return result;
    }
    fn prepareToken(self: *Iterator) void {
        if (self.offset >= self.text.len or white(self.text[self.offset]) or self.text[self.offset] == '\n' or self.offset < self.token_end) return;
        var end = self.offset;
        while (end < self.text.len and !white(self.text[end]) and self.text[end] != '\n') : (end += 1) {}
        self.token_end = end;
        if (self.options.mode == .literal or self.literal_line) return;
        const columns = self.wordWidth(self.offset, end);
        if (columns <= self.width and self.position.column > 0 and self.position.column +| columns > self.width) self.position.newline();
    }
    fn prepareLine(self: *Iterator) void {
        if (!self.line_start) return;
        self.line_start = false;
        const end = std.mem.indexOfScalarPos(u8, self.text, self.offset, '\n') orelse self.text.len;
        const line = self.text[self.offset..end];
        self.literal_line = self.options.mode == .literal or std.mem.startsWith(u8, line, "    ") or std.mem.indexOfScalar(u8, line, '\t') != null;
    }
    fn prepareWhitespace(self: *Iterator) void {
        // Overwide words keep their separating whitespace. Reuse the lookahead
        // while emitting that span instead of rescanning its remaining tail for
        // every space. The pending marker in the next word cannot be emitted
        // until this whitespace span has been consumed.
        if (self.offset < self.whitespace_end) return;
        var end = self.offset;
        while (end < self.text.len and white(self.text[end])) : (end += 1) {}
        self.whitespace_end = end;
        var word_end = end;
        while (word_end < self.text.len and !white(self.text[word_end]) and self.text[word_end] != '\n') : (word_end += 1) {}
        self.next_word_end = word_end;
        self.next_word_columns = self.wordWidth(end, word_end);
    }
    pub fn next(self: *Iterator) ?Glyph {
        if (self.width == 0) return null;
        while (true) {
            if (self.tab_left > 0) {
                self.tab_left -= 1;
                self.position.wrap(1, self.width);
                const position = self.position;
                self.position.column +|= 1;
                return .{ .text = " ", .columns = 1, .position = position, .byte_offset = self.tab_offset };
            }
            self.prepareLine();
            self.prepareToken();
            if (self.options.marker_at) |at| if (!self.marker_done and self.offset >= @min(at, self.text.len)) {
                self.marker_done = true;
                self.position.wrap(1, self.width);
                const position = self.position;
                self.position.column +|= 1;
                return .{ .text = "▏", .columns = 1, .position = position, .byte_offset = at, .marker = true };
            };
            if (self.offset >= self.text.len) return null;
            if (self.text[self.offset] == '\n') {
                self.offset += 1;
                self.position.newline();
                self.line_start = true;
                self.token_end = self.offset;
                continue;
            }
            if (self.text[self.offset] == '\t') {
                self.tab_offset = self.offset;
                self.offset += 1;
                self.tab_left = 4 - self.position.column % 4;
                continue;
            }
            if (white(self.text[self.offset]) and self.options.mode == .words and !self.literal_line and self.position.column > 0) {
                self.prepareWhitespace();
                if (self.next_word_end > self.whitespace_end and self.next_word_columns <= self.width and @as(usize, self.position.column) + (self.whitespace_end - self.offset) + self.next_word_columns > self.width) {
                    self.offset = self.whitespace_end;
                    self.position.newline();
                    self.token_end = self.offset;
                    continue; // A soft wrap omits only the separating whitespace.
                }
            }
            const raw = if (standaloneAscii(self.text, self.offset)) self.text[self.offset .. self.offset + 1] else blk: {
                var graphemes = vaxis.unicode.graphemeIterator(self.text[self.offset..]);
                const gr = graphemes.next() orelse return null;
                break :blk gr.bytes(self.text[self.offset..]);
            };
            const shown = if (raw.len > 128) "�" else raw;
            const columns = if (raw.len == 1 and raw[0] >= 0x20 and raw[0] < 0x7f) 1 else @max(vaxis.gwidth.gwidth(shown, self.method), 1);
            self.position.wrap(columns, self.width);
            const position = self.position;
            const byte_offset = self.offset;
            self.offset += raw.len;
            self.position.column +|= columns;
            return .{ .text = shown, .columns = columns, .position = position, .byte_offset = byte_offset };
        }
    }
};
pub fn after(text: []const u8, width: u16, method: vaxis.gwidth.Method, options: Options) Position {
    var iterator = Iterator.init(text, width, method, options);
    while (iterator.next()) |_| {}
    return iterator.position;
}
pub fn caret(text: []const u8, byte_cursor: usize, width: u16, method: vaxis.gwidth.Method, mode: Mode) Position {
    if (width == 0) return .{};
    // A cursor is an overlay on the ordinary text, never another glyph in its
    // word width. Inserting a virtual cell moves text and can reflow a whole
    // word even before any source bytes have changed.
    const at = @min(byte_cursor, text.len);
    var iterator = Iterator.init(text, width, method, .{ .mode = mode });
    var previous: Position = .{};
    var previous_byte_end: usize = 0;
    while (iterator.next()) |glyph| {
        if (at == glyph.byte_offset) return glyph.position;
        if (at < glyph.byte_offset) return gapCaret(text, previous_byte_end, at, previous, width);
        // Field cursors lie on grapheme boundaries. A caller supplying an
        // interior byte still gets its complete grapheme's leading cell.
        if (at < iterator.offset) return glyph.position;
        previous = glyph.position;
        previous.column +|= glyph.columns;
        previous_byte_end = iterator.offset;
    }
    return gapCaret(text, previous_byte_end, at, previous, width);
}

fn gapCaret(text: []const u8, start: usize, end: usize, previous: Position, width: u16) Position {
    var result = previous;
    // Iterator omits newline glyphs and separating whitespace at soft wraps.
    // Preserve each hard line break up to the cursor. Positions inside omitted
    // soft-wrap separators stay at the preceding text boundary; the next
    // actual glyph uses its wrapped position instead.
    for (text[@min(start, end)..end]) |byte| if (byte == '\n') result.newline();
    // A terminal cursor cannot occupy a column just beyond the right edge.
    // This extra cursor row does not add a source character or move any glyph.
    if (width > 0 and result.column >= width) result.newline();
    return result;
}

test "composer caret: ASCII column zero newline gaps and exact width use nonshifting coordinates" {
    const Case = struct { text: []const u8, at: usize, width: u16, expected: Position };
    const cases = [_]Case{
        .{ .text = "L\nnext", .at = 0, .width = 8, .expected = .{ .row = 0, .column = 0 } },
        .{ .text = "AL\nnext", .at = 1, .width = 8, .expected = .{ .row = 0, .column = 1 } },
        .{ .text = "AL\n\nNext", .at = 2, .width = 10, .expected = .{ .row = 0, .column = 2 } },
        .{ .text = "AL\n\nNext", .at = 3, .width = 10, .expected = .{ .row = 1, .column = 0 } },
        .{ .text = "AL\n\nNext", .at = 4, .width = 10, .expected = .{ .row = 2, .column = 0 } },
        .{ .text = "AL\n\nNext", .at = 99, .width = 10, .expected = .{ .row = 2, .column = 4 } },
        .{ .text = "ABCD", .at = 4, .width = 4, .expected = .{ .row = 1, .column = 0 } },
        .{ .text = "ABCD\nEF", .at = 4, .width = 4, .expected = .{ .row = 1, .column = 0 } },
        .{ .text = "ABCD\nEF", .at = 5, .width = 4, .expected = .{ .row = 1, .column = 0 } },
        .{ .text = "ABCD\nEF", .at = 7, .width = 4, .expected = .{ .row = 1, .column = 2 } },
        .{ .text = "\n", .at = 0, .width = 4, .expected = .{ .row = 0, .column = 0 } },
        .{ .text = "\n", .at = 1, .width = 4, .expected = .{ .row = 1, .column = 0 } },
        .{ .text = "", .at = 0, .width = 4, .expected = .{ .row = 0, .column = 0 } },
        .{ .text = "A\tB", .at = 1, .width = 8, .expected = .{ .row = 0, .column = 1 } },
        .{ .text = "A\tB", .at = 2, .width = 8, .expected = .{ .row = 0, .column = 4 } },
        .{ .text = "A\t", .at = 2, .width = 4, .expected = .{ .row = 1, .column = 0 } },
        .{ .text = "abc  def", .at = 3, .width = 5, .expected = .{ .row = 0, .column = 3 } },
        .{ .text = "abc  def", .at = 4, .width = 5, .expected = .{ .row = 0, .column = 3 } },
        .{ .text = "abc  def", .at = 5, .width = 5, .expected = .{ .row = 1, .column = 0 } },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, caret(case.text, case.at, case.width, .unicode, .words));
    // This independent rendered-cell oracle has no virtual caret or inserted
    // source whitespace: the user's expected A and L remain adjacent.
    var source = Iterator.init("AL\nnext", 8, .unicode, .{});
    const first = source.next().?;
    const second = source.next().?;
    try std.testing.expectEqualStrings("A", first.text);
    try std.testing.expectEqual(Position{ .row = 0, .column = 0 }, first.position);
    try std.testing.expectEqualStrings("L", second.text);
    try std.testing.expectEqual(Position{ .row = 0, .column = 1 }, second.position);
}

test "composer caret: normal word wrapping and complete Unicode graphemes ignore cursor width" {
    const input = "1234567890123 a\u{301}b";
    for ([_]vaxis.gwidth.Method{ .unicode, .wcwidth, .no_zwj }) |method| {
        try std.testing.expectEqual(Position{ .row = 0, .column = 15 }, caret(input, 17, 16, method, .words));
        var normal = Iterator.init(input, 16, method, .{});
        var last: Glyph = undefined;
        while (normal.next()) |glyph| last = glyph;
        try std.testing.expectEqualStrings("b", last.text);
        try std.testing.expectEqual(Position{ .row = 0, .column = 15 }, last.position);
    }
    try std.testing.expectEqual(Position{ .row = 0, .column = 0 }, caret("a\u{301}b", 1, 8, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 0, .column = 1 }, caret("a\u{301}b", 3, 8, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 0, .column = 1 }, caret("A界B", 1, 4, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 0, .column = 3 }, caret("A界B", 4, 4, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 1, .column = 0 }, caret("A界B", 5, 4, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 1, .column = 0 }, caret("ABC界", 3, 4, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 0, .column = 0 }, caret("👩‍💻!", 1, 8, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 0, .column = 2 }, caret("👩‍💻!", 11, 8, .unicode, .words));
    try std.testing.expectEqual(Position{ .row = 1, .column = 0 }, caret("👩‍💻!", 11, 2, .unicode, .words));
}
test "reader polish: plaintext words newlines indentation tabs and long tokens have one shared layout" {
    const allocator = std.testing.allocator;
    const input = "Hello onboarding instructions\n    code  keeps spacing\n\tafter tab\nhttps://example.test/verylongtoken";
    var iterator = Iterator.init(input, 16, .unicode, .{});
    var rows: [20]std.ArrayList(u8) = @splat(.empty);
    defer for (&rows) |*row| row.deinit(allocator);
    while (iterator.next()) |glyph| try rows[glyph.position.row].appendSlice(allocator, glyph.text);
    try std.testing.expectEqualStrings("Hello onboarding", rows[0].items);
    try std.testing.expectEqualStrings("instructions", rows[1].items);
    try std.testing.expect(std.mem.startsWith(u8, rows[2].items, "    code"));
    const measured = after(input, 16, .unicode, .{});
    try std.testing.expectEqual(iterator.position, measured);
}
test "reader polish: caret uses normal full word wrapping and legacy marker remains available" {
    const input = "1234567890 longword";
    const byte_cursor = 13;
    const expected = caret(input, byte_cursor, 16, .unicode, .words);
    try std.testing.expectEqual(@as(usize, 1), expected.row);
    try std.testing.expectEqual(@as(u16, 2), expected.column);
    var iterator = Iterator.init(input, 16, .unicode, .{ .marker_at = byte_cursor });
    var markers: usize = 0;
    while (iterator.next()) |glyph| if (glyph.marker) {
        markers += 1;
        try std.testing.expectEqual(expected, glyph.position);
    };
    try std.testing.expectEqual(@as(usize, 1), markers);
}
test "reader performance: guarded ASCII agrees with independent Unicode graphemes and numeric wrapping" {
    const corpus = [_][]const u8{
        "Fictional bounded navigation line.",
        "ASCII a\u{301} b 1\u{fe0f}\u{20e3} \u{600}c 🇦🇹 👩‍💻 界 z",
        "A\u{200d}B x\u{fe0f} z",
        "spaces  preserve literal spacing and trailing ASCII",
    };
    for ([_]vaxis.gwidth.Method{ .unicode, .wcwidth, .no_zwj }) |method| {
        for (corpus) |input| for ([_]u16{ 3, 7, 43 }) |width| {
            var measured = Iterator.init(input, width, method, .{ .mode = .literal });
            // Reference uses one unmodified dependency grapheme iterator,
            // independent of the optimized per-cell ASCII branch.
            var reference = vaxis.unicode.graphemeIterator(input);
            var row: usize = 0;
            var column: u16 = 0;
            while (reference.next()) |expected| {
                const raw = expected.bytes(input);
                const shown = if (raw.len > 128) "�" else raw;
                const columns = @max(vaxis.gwidth.gwidth(shown, method), 1);
                if (column +| columns > width) {
                    row += 1;
                    column = 0;
                }
                const actual = measured.next() orelse return error.MissingExpectedGlyph;
                try std.testing.expectEqualStrings(shown, actual.text);
                try std.testing.expectEqual(columns, actual.columns);
                try std.testing.expectEqual(expected.start, actual.byte_offset);
                try std.testing.expectEqual(row, actual.position.row);
                try std.testing.expectEqual(column, actual.position.column);
                column +|= columns;
            }
            try std.testing.expect(measured.next() == null);
            try std.testing.expectEqual(Position{ .row = row, .column = column }, measured.position);
        };
        // Combining bytes belong to their ASCII base. Cursor measurement uses
        // normal text and leaves an exactly fitting word on its original row.
        const input = "1234567890123 a\u{301}b";
        try std.testing.expectEqual(Position{ .row = 0, .column = 16 }, after(input, 16, method, .{}));
        try std.testing.expectEqual(Position{ .row = 0, .column = 15 }, caret(input, 17, 16, method, .words));
        try std.testing.expectEqual(Position{ .row = 1, .column = 0 }, caret(input, input.len, 16, method, .words));
    }
}
test "reader polish: long whitespace before an overwide token preserves every cell and caret" {
    const allocator = std.testing.allocator;
    const spaces = 100_000;
    const token_len = 100_000;
    const token_start = 3 + spaces;
    const input = try allocator.alloc(u8, token_start + token_len);
    defer allocator.free(input);
    @memcpy(input[0..3], "Hi ");
    @memset(input[3..token_start], ' ');
    @memset(input[token_start..], 'x');
    @memcpy(input[token_start .. token_start + 21], "https://example.test/");
    const marker_at = spaces / 2;
    const options: Options = .{ .marker_at = marker_at };
    var iterator = Iterator.init(input, 16, .unicode, options);
    var cells: usize = 0;
    var bytes: usize = 0;
    var markers: usize = 0;
    while (iterator.next()) |glyph| {
        try std.testing.expectEqual(Position{ .row = cells / 16, .column = @intCast(cells % 16) }, glyph.position);
        try std.testing.expectEqual(@as(u16, 1), glyph.columns);
        if (glyph.marker) {
            markers += 1;
            try std.testing.expectEqual(marker_at, bytes);
            try std.testing.expectEqualStrings("▏", glyph.text);
        } else {
            try std.testing.expectEqual(bytes, glyph.byte_offset);
            try std.testing.expectEqualStrings(input[bytes .. bytes + 1], glyph.text);
            bytes += 1;
        }
        if (bytes > 2 and bytes <= token_start) {
            try std.testing.expectEqual(token_start, iterator.whitespace_end);
            try std.testing.expectEqual(input.len, iterator.next_word_end);
            try std.testing.expect(iterator.next_word_columns > iterator.width);
        }
        cells += 1;
    }
    try std.testing.expectEqual(input.len, bytes);
    try std.testing.expectEqual(@as(usize, 1), markers);
    try std.testing.expectEqual(iterator.position, after(input, 16, .unicode, options));
    try std.testing.expectEqual(Position{ .row = marker_at / 16, .column = @intCast(marker_at % 16) }, caret(input, marker_at, 16, .unicode, .words));
}
