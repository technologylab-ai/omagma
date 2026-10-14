//! Default full Unicode case folding with original UTF-8 byte coordinates.
//! No normalization/accent removal or locale-specific Turkish tailoring. Match
//! boundaries remain complete source characters even when ß expands to ss.
const std = @import("std");
const data = @import("unicode/case_folding.zig");
pub const Range = struct { start: usize, end: usize };
pub const Unit = struct { value: u21, start: usize, end: usize, first: bool, last: bool };

pub const Iterator = struct {
    text: []const u8,
    offset: usize = 0,
    pending: [3]u21 = undefined,
    count: usize = 0,
    emitted: usize = 0,
    start: usize = 0,

    pub fn next(self: *Iterator) ?Unit {
        if (self.emitted == self.count) {
            if (self.offset == self.text.len) return null;
            self.start = self.offset;
            const size = std.unicode.utf8ByteSequenceLength(self.text[self.offset]) catch 1;
            // Invalid provider bytes cannot consume a following valid character
            // or compare equal to ordinary text. Query validation is stricter.
            const end = @min(self.text.len, self.offset + size);
            const cp = std.unicode.utf8Decode(self.text[self.offset..end]) catch bad: {
                const invalid: u21 = 0x110000 + @as(u21, self.text[self.offset]);
                self.offset += 1;
                break :bad invalid;
            };
            if (cp <= 0x10ffff) self.offset = end;
            self.count = fold(cp, &self.pending);
            self.emitted = 0;
        }
        const index = self.emitted;
        self.emitted += 1;
        return .{ .value = self.pending[index], .start = self.start, .end = self.offset, .first = index == 0, .last = self.emitted == self.count };
    }
};

pub fn fold(cp: u21, out: *[3]u21) usize {
    if (cp < 128) {
        out[0] = std.ascii.toLower(@intCast(cp));
        return 1;
    }
    var low: usize = 0;
    var high: usize = data.entries.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const item = data.entries[mid];
        if (item.source < cp) low = mid + 1 else if (item.source > cp) high = mid else {
            out.* = item.values;
            return item.len;
        }
    }
    out[0] = cp;
    return 1;
}

pub fn Pattern(comptime max_bytes: usize) type {
    return struct {
        const Self = @This();
        pub const capacity = max_bytes * 3;
        values: [capacity]u21 = undefined,
        prefix: [capacity]u16 = undefined,
        len: usize = 0,
        partial: usize = 0,

        pub fn init(query: []const u8) !Self {
            if (query.len > max_bytes) return error.FindQueryTooLong;
            if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
            var self: Self = .{};
            var iterator: Iterator = .{ .text = query };
            while (iterator.next()) |unit| {
                if (self.len == capacity) return error.FindQueryTooLong;
                self.values[self.len] = unit.value;
                self.len += 1;
            }
            if (self.len == 0) return self;
            self.prefix[0] = 0;
            var matched: usize = 0;
            for (1..self.len) |index| {
                while (matched > 0 and self.values[index] != self.values[matched]) matched = self.prefix[matched - 1];
                if (self.values[index] == self.values[matched]) matched += 1;
                self.prefix[index] = @intCast(matched);
            }
            return self;
        }

        /// Keep overlap state until the caller accepts complete boundaries.
        pub fn feed(self: *Self, cp: u21) bool {
            if (self.len == 0) return false;
            while (self.partial > 0 and cp != self.values[self.partial]) self.partial = self.prefix[self.partial - 1];
            if (cp == self.values[self.partial]) self.partial += 1;
            if (self.partial != self.len) return false;
            self.partial = self.prefix[self.len - 1];
            return true;
        }
    };
}

/// Immutable, exactly sized query data for repeated scans. The caller owns
/// its allocation lifetime and supplies a separate reusable boundary ring;
/// neither the needle nor its prefix table changes while matching fields.
pub const Boundary = struct { byte: usize, complete: bool };
pub const Needle = struct {
    values: []const u21,
    prefix: []const u16,

    pub fn init(a: std.mem.Allocator, query: []const u8) !Needle {
        if (query.len > 4096) return error.FindQueryTooLong;
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
        var count: usize = 0;
        var iterator: Iterator = .{ .text = query };
        while (iterator.next() != null) count += 1;
        const values = try a.alloc(u21, count);
        errdefer a.free(values);
        const prefix = try a.alloc(u16, count);
        errdefer a.free(prefix);
        iterator = .{ .text = query };
        var index: usize = 0;
        while (iterator.next()) |unit| : (index += 1) values[index] = unit.value;
        if (count != 0) {
            prefix[0] = 0;
            var matched: usize = 0;
            for (1..count) |i| {
                while (matched > 0 and values[i] != values[matched]) matched = prefix[matched - 1];
                if (values[i] == values[matched]) matched += 1;
                prefix[i] = @intCast(matched);
            }
        }
        return .{ .values = values, .prefix = prefix };
    }

    pub fn find(self: Needle, text: []const u8, boundaries: []Boundary) ?Range {
        if (self.values.len == 0) return null;
        std.debug.assert(boundaries.len >= self.values.len);
        var partial: usize = 0;
        var count: usize = 0;
        var iterator: Iterator = .{ .text = text };
        while (iterator.next()) |unit| {
            boundaries[count % self.values.len] = .{ .byte = unit.start, .complete = unit.first };
            count += 1;
            while (partial > 0 and unit.value != self.values[partial]) partial = self.prefix[partial - 1];
            if (unit.value == self.values[partial]) partial += 1;
            if (partial != self.values.len) continue;
            partial = self.prefix[partial - 1];
            if (unit.last) {
                const start = boundaries[(count - self.values.len) % self.values.len];
                if (start.complete) return .{ .start = start.byte, .end = unit.end };
            }
        }
        return null;
    }
};

pub fn find(text: []const u8, query: []const u8) ?Range {
    var pattern = Pattern(4096).init(query) catch return null;
    if (pattern.len == 0) return null;
    const Start = struct { byte: usize, complete: bool };
    var starts: [Pattern(4096).capacity]Start = undefined;
    var count: usize = 0;
    var iterator: Iterator = .{ .text = text };
    while (iterator.next()) |unit| {
        starts[count % pattern.len] = .{ .byte = unit.start, .complete = unit.first };
        count += 1;
        if (pattern.feed(unit.value) and unit.last) {
            const start = starts[(count - pattern.len) % pattern.len];
            if (start.complete) return .{ .start = start.byte, .end = unit.end };
        }
    }
    return null;
}

test "Unicode search: full folds preserve source byte ranges" {
    for ([_]struct { text: []const u8, query: []const u8, found: []const u8 }{
        .{ .text = "Zur STRAẞE am Fluss", .query = "strasse", .found = "STRAẞE" },
        .{ .text = "Zum Café", .query = "CAFÉ", .found = "Café" },
        .{ .text = "Νέο ΣΟΣ", .query = "σος", .found = "ΣΟΣ" },
        .{ .text = "Привет МИР", .query = "мир", .found = "МИР" },
        .{ .text = "an oﬃce", .query = "OFFICE", .found = "oﬃce" },
        .{ .text = "İstanbul", .query = "i\u{307}STANBUL", .found = "İstanbul" },
        .{ .text = "Maß", .query = "MASS", .found = "Maß" },
    }) |example| {
        const matched = find(example.text, example.query) orelse return error.MatchMissing;
        try std.testing.expectEqualStrings(example.found, example.text[matched.start..matched.end]);
    }
    try std.testing.expect(find("ß", "s") == null);
    try std.testing.expect(find("İ", "i") == null);
    try std.testing.expect(find("Café", "cafe") == null);
    try std.testing.expect(find("é", "e\u{301}") == null);
}

test "Unicode search: malformed text and empty queries never invent boundaries" {
    try std.testing.expectEqualDeep(Range{ .start = 2, .end = 7 }, find("\xff\xc3CAFÉ", "café").?);
    try std.testing.expect(find("data", "") == null);
    try std.testing.expect(find("data", "\xff") == null);
    try std.testing.expectEqualDeep(Range{ .start = 1, .end = 6 }, find("aaaaab", "aaaab").?);
}
