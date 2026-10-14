//! Search the text the reader actually lays out. Byte ranges refer to those
//! rendered lines, never raw HTML. Full Unicode folding preserves source bytes.
const std = @import("std");
const unicode_search = @import("unicode_search.zig");
const Pattern = unicode_search.Pattern(max_query_bytes);
pub const max_query_bytes = 256;
pub const max_matches = 256;
pub const max_scan_bytes = 2 * 1024 * 1024;
pub const Match = struct { row: usize, start: usize, end_row: usize, end: usize };
pub const Join = enum { separate, space, none };
const Point = struct { row: usize, byte: usize, complete: bool = true };
pub const Model = struct {
    query: [max_query_bytes]u8 = undefined,
    query_len: usize = 0,
    pattern: Pattern = .{},
    points: [Pattern.capacity]Point = undefined,
    scanned: usize = 0,
    fed: usize = 0,
    values: [max_matches]Match = undefined,
    count: usize = 0,
    selected: usize = 0,
    truncated: bool = false,

    pub fn reset(self: *Model, query: []const u8) !void {
        if (query.len > max_query_bytes) return error.FindQueryTooLong;
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
        for (query) |byte| if (byte < 32 or byte == 127) return error.InvalidFindQuery;
        self.* = .{};
        self.query_len = query.len;
        @memcpy(self.query[0..query.len], query);
        self.pattern = try Pattern.init(query);
    }
    pub fn clearMatches(self: *Model) void {
        self.pattern.partial = 0;
        self.fed = 0;
        self.scanned = 0;
        self.count = 0;
        self.truncated = false;
    }
    /// Use separate for explicit newlines/blocks; a soft wrap can join with a
    /// space (word wrapping) or none (a word split by the viewport edge).
    pub fn addWrappedLine(self: *Model, text: []const u8, row: usize, join: Join) void {
        self.addWrappedLineAt(text, row, join, 0);
    }
    /// Continuation prefixes belong to the layout, not the message. Retain
    /// their byte width in match coordinates while excluding them from text.
    pub fn addWrappedLineAt(self: *Model, text: []const u8, row: usize, join: Join, byte_base: usize) void {
        if (self.query_len == 0) return;
        switch (join) {
            .separate => self.pattern.partial = 0,
            .space => if (self.fed > 0) self.feed(' ', .{ .row = row, .byte = byte_base }, byte_base, true),
            .none => {},
        }
        var iterator: unicode_search.Iterator = .{ .text = text };
        while (iterator.next()) |unit| {
            if (unit.first) {
                if (unit.end - unit.start > max_scan_bytes - self.scanned) {
                    self.truncated = true;
                    return;
                }
                self.scanned += unit.end - unit.start;
            }
            self.feed(unit.value, .{ .row = row, .byte = byte_base + unit.start, .complete = unit.first }, byte_base + unit.end, unit.last);
        }
    }
    /// Preserve navigation while rebuilding after a redraw/resize. Clamping
    /// after each line would reset a later match before it was scanned again.
    pub fn finish(self: *Model) void {
        self.selected = @min(self.selected, self.count -| 1);
    }
    pub fn addLine(self: *Model, text: []const u8, row: usize) void {
        self.addWrappedLine(text, row, .separate);
    }
    fn feed(self: *Model, cp: u21, point: Point, end: usize, complete: bool) void {
        self.points[self.fed % Pattern.capacity] = point;
        self.fed += 1;
        if (self.pattern.feed(cp) and complete) {
            const start = self.points[(self.fed - self.pattern.len) % Pattern.capacity];
            if (!start.complete) return;
            if (self.count < max_matches) {
                self.values[self.count] = .{ .row = start.row, .start = start.byte, .end_row = point.row, .end = end };
                self.count += 1;
            } else self.truncated = true;
            // Conventional find advances after each complete source match.
            self.pattern.partial = 0;
        }
    }
    pub fn current(self: *const Model) ?Match {
        return if (self.count == 0) null else self.values[@min(self.selected, self.count - 1)];
    }
    pub fn next(self: *Model, forward: bool) ?Match {
        if (self.count == 0) return null;
        self.selected = if (forward) (self.selected + 1) % self.count else if (self.selected == 0) self.count - 1 else self.selected - 1;
        return self.current();
    }
    pub fn overlaps(match: Match, row: usize, start: usize, end: usize) bool {
        return row >= match.row and row <= match.end_row and (row != match.row or end > match.start) and (row != match.end_row or start < match.end);
    }
};

test "reader find: displayed lines Unicode wraps and next previous map exactly" {
    var model: Model = .{};
    try model.reset("Café report");
    model.addLine("Read Café", 4);
    model.addWrappedLine("report today", 5, .space);
    model.addLine("CAFé REPORT again", 9);
    try std.testing.expectEqual(@as(usize, 2), model.count);
    try std.testing.expectEqualDeep(Match{ .row = 4, .start = 5, .end_row = 5, .end = 6 }, model.current().?);
    try std.testing.expectEqual(@as(usize, 9), model.next(true).?.row);
    try std.testing.expectEqual(@as(usize, 4), model.next(true).?.row);
    try std.testing.expectEqual(@as(usize, 9), model.next(false).?.row);
    try std.testing.expect(Model.overlaps(model.values[0], 5, 0, 6));
    try std.testing.expect(!Model.overlaps(model.values[0], 5, 6, 12));
    model.clearMatches();
    model.addLine("Café", 0);
    model.addLine("report", 1);
    try std.testing.expectEqual(@as(usize, 0), model.count);
}
test "reader find: hard wraps and bounded matches remain predictable" {
    var model: Model = .{};
    try model.reset("repeated");
    model.addLine("repeat", 0);
    model.addWrappedLine("ed", 1, .none);
    try std.testing.expectEqual(@as(usize, 1), model.count);
    try model.reset("x");
    for (0..max_matches + 3) |row| model.addLine("x", row);
    try std.testing.expectEqual(max_matches, model.count);
    try std.testing.expect(model.truncated);
    try model.reset("");
    model.addLine("anything", 0);
    try std.testing.expect(model.current() == null);
}

test "reader find: continuation indentation preserves rendered byte positions" {
    var model: Model = .{};
    try model.reset("meeting notes");
    model.addLine("• meeting", 2);
    model.addWrappedLineAt("notes", 3, .space, 2);
    try std.testing.expectEqualDeep(Match{ .row = 2, .start = 4, .end_row = 3, .end = 7 }, model.current().?);
    try std.testing.expect(!Model.overlaps(model.current().?, 2, 0, 4));
    try std.testing.expect(Model.overlaps(model.current().?, 3, 2, 7));
}

test "reader find: rebuilding wrapped lines preserves selection until the full scan finishes" {
    var model: Model = .{};
    try model.reset("meeting notes");
    model.addLine("First meeting", 3);
    model.addWrappedLine("notes here", 4, .space);
    model.addLine("Second meeting notes here", 8);
    model.finish();
    try std.testing.expectEqual(@as(usize, 8), model.next(true).?.row);
    model.clearMatches();
    model.addLine("First meeting", 3);
    model.addWrappedLine("notes here", 4, .space);
    model.addLine("Second meeting notes here", 8);
    model.finish();
    try std.testing.expectEqual(@as(usize, 8), model.current().?.row);
    // Folding away the selected row clamps only after the remaining content
    // has been scanned, so the visible first match becomes the safe fallback.
    model.clearMatches();
    model.addLine("First meeting notes", 3);
    model.finish();
    try std.testing.expectEqual(@as(usize, 3), model.current().?.row);
}

test "reader find: expanded Unicode folds cross wraps with exact original coordinates" {
    var model: Model = .{};
    try model.reset("STRASSE CAFÉ");
    model.addLine("Die Straße", 2);
    model.addWrappedLineAt("café!", 3, .space, 4);
    try std.testing.expectEqualDeep(Match{ .row = 2, .start = 4, .end_row = 3, .end = 9 }, model.current().?);
    try model.reset("s");
    model.addLine("ß s", 7);
    try std.testing.expectEqual(@as(usize, 1), model.count);
    try std.testing.expectEqualDeep(Match{ .row = 7, .start = 3, .end_row = 7, .end = 4 }, model.current().?);
    try model.reset("СС");
    model.addLine("с", 8);
    model.addWrappedLine("с", 9, .none);
    try std.testing.expectEqualDeep(Match{ .row = 8, .start = 0, .end_row = 9, .end = 2 }, model.current().?);
}
