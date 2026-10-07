//! Literal, bounded reader helpers. No markup execution or resource fetching.
const std = @import("std");
const html_document = @import("html_document.zig");
pub const max_links = 128;
pub const Links = struct {
    values: [max_links][]const u8 = @splat(""),
    count: usize = 0,
    truncated: bool = false,
    pub fn add(self: *Links, value: []const u8) void {
        if (!safeUrl(value)) return;
        for (self.values[0..self.count]) |old| if (std.mem.eql(u8, old, value)) return;
        if (self.count == max_links) {
            self.truncated = true;
            return;
        }
        self.values[self.count] = value;
        self.count += 1;
    }
};
pub fn safeUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096) return false;
    if (!(std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://"))) return false;
    for (value) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null) return false;
    const host = uri.host orelse return false;
    return switch (host) {
        .raw => |raw| raw.len > 0,
        .percent_encoded => |encoded| encoded.len > 0,
    };
}
pub const LinkRange = struct { start: usize, end: usize, url: []const u8 };
pub const LinkIterator = struct {
    input: []const u8,
    position: usize = 0,
    pub fn next(self: *LinkIterator) ?LinkRange {
        while (self.position < self.input.len) {
            const tail = self.input[self.position..];
            const https = std.mem.indexOf(u8, tail, "https://");
            const http = std.mem.indexOf(u8, tail, "http://");
            const relative = if (https) |a| if (http) |b| @min(a, b) else a else http orelse return null;
            const start = self.position + relative;
            var end = start;
            while (end < self.input.len and self.input[end] > 32 and std.mem.indexOfScalar(u8, "<>\"'", self.input[end]) == null) : (end += 1) {}
            var trimmed = end;
            while (trimmed > start and std.mem.indexOfScalar(u8, ".,;!)]}", self.input[trimmed - 1]) != null) trimmed -= 1;
            self.position = @max(end, start + 1);
            const url = self.input[start..trimmed];
            if (safeUrl(url)) return .{ .start = start, .end = trimmed, .url = url };
        }
        return null;
    }
};
pub fn findLinks(input: []const u8, result: *Links) void {
    var iterator: LinkIterator = .{ .input = input };
    while (iterator.next()) |range| result.add(range.url);
}

pub const display_url_bytes = 64;
/// Display only: the caller retains original bodies/targets for the link chooser.
/// Short results may borrow input; allocated results belong to the caller's arena.
pub fn compactUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (url.len <= display_url_bytes or !safeUrl(url)) return url;
    const content_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    var end = @min(content_end, display_url_bytes - "…".len);
    while (end > 0 and url[end] & 0xc0 == 0x80) end -= 1;
    return std.fmt.allocPrint(allocator, "{s}…", .{url[0..end]});
}
pub const DisplayLinks = struct { text: []const u8, ranges: []const LinkRange = &.{} };
pub fn displayLinks(allocator: std.mem.Allocator, input: []const u8) !DisplayLinks {
    var iterator: LinkIterator = .{ .input = input };
    var first = iterator.next() orelse return .{ .text = input };
    var output: std.ArrayList(u8) = .empty;
    var ranges: std.ArrayList(LinkRange) = .empty;
    errdefer output.deinit(allocator);
    errdefer ranges.deinit(allocator);
    var position: usize = 0;
    while (true) {
        try output.appendSlice(allocator, input[position..first.start]);
        const start = output.items.len;
        try output.appendSlice(allocator, try compactUrl(allocator, first.url));
        try ranges.append(allocator, .{ .start = start, .end = output.items.len, .url = first.url });
        position = first.end;
        if (ranges.items.len == html_document.Limits.spans) break;
        first = iterator.next() orelse break;
    }
    try output.appendSlice(allocator, input[position..]);
    return .{ .text = try output.toOwnedSlice(allocator), .ranges = try ranges.toOwnedSlice(allocator) };
}
pub fn links(text: []const u8, html: []const u8, allocator: std.mem.Allocator) !Links {
    var result: Links = .{};
    findLinks(text, &result);
    // Semantic parsing retains exact entity-decoded hrefs. Guessing them from
    // converted display text could remove meaningful terminal punctuation.
    if (html.len > 0) {
        const document = html_document.parse(html, allocator) catch return result;
        for (document.blocks) |block| {
            for (block.spans) |span| if (span.link) |url| result.add(url);
            if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| if (span.link) |url| result.add(url);
        }
    }
    return result;
}
pub const Folded = struct { text: []const u8, quotes: usize = 0, signature: bool = false };
pub fn fold(allocator: std.mem.Allocator, input: []const u8, hide_quotes: bool, hide_signature: bool) !Folded {
    if (!hide_quotes and !hide_signature) return .{ .text = input };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var result: Folded = .{ .text = "" };
    var quote_block = false;
    var signature = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (hide_signature and (signature or std.mem.eql(u8, line, "-- ") or std.mem.eql(u8, line, "-- \r"))) {
            if (!signature) try out.appendSlice(allocator, "[Signature folded · S shows it]\n");
            signature = true;
            result.signature = true;
            continue;
        }
        const quoted = trimmed.len > 0 and trimmed[0] == '>';
        const reply_header = std.ascii.startsWithIgnoreCase(trimmed, "On ") and std.mem.endsWith(u8, std.mem.trimEnd(u8, trimmed, "\r"), "wrote:");
        if (hide_quotes and (quoted or reply_header)) {
            if (!quote_block) try out.appendSlice(allocator, "[Quoted history folded · Q shows it]\n");
            quote_block = true;
            result.quotes += 1;
            continue;
        }
        quote_block = false;
        try out.appendSlice(allocator, line);
        if (lines.index != null) try out.append(allocator, '\n');
    }
    result.text = try out.toOwnedSlice(allocator);
    return result;
}
test "local reader: links refuse executable credentials and preserve safe literal targets" {
    try std.testing.expect(!safeUrl("javascript:alert(1)"));
    try std.testing.expect(!safeUrl("file:///private"));
    try std.testing.expect(!safeUrl("https://user:password@example.test/"));
    try std.testing.expect(!safeUrl("https://example.test/\x1b"));
    var found: Links = .{};
    findLinks("Visit <https://example.test/a?q=1&b=2> then https://example.test/a?q=1&b=2", &found);
    try std.testing.expectEqual(@as(usize, 1), found.count);
    try std.testing.expectEqualStrings("https://example.test/a?q=1&b=2", found.values[0]);
}
test "local reader: folding keeps authored text and reveals quoted history explicitly" {
    const allocator = std.testing.allocator;
    const source = "Fresh answer\nOn Monday someone wrote:\n> Old answer\n> History\nNew follow-up\n-- \nSignature";
    const folded = try fold(allocator, source, true, true);
    defer allocator.free(folded.text);
    try std.testing.expect(std.mem.indexOf(u8, folded.text, "Fresh answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded.text, "New follow-up") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded.text, "> Old answer") == null);
    try std.testing.expect(folded.signature and folded.quotes == 3);
    try std.testing.expectEqualStrings(source, (try fold(allocator, source, false, false)).text);
}

test "local reader: compact visible URLs preserve exact chooser targets and literal punctuation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const url = "https://example.test/guide?tracking=abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz";
    const source = try std.fmt.allocPrint(allocator, "Read <{s}>. Then https://example.test/end!", .{url});
    const display = try displayLinks(allocator, source);
    try std.testing.expectEqualStrings("Read <https://example.test/guide…>. Then https://example.test/end!", display.text);
    try std.testing.expectEqual(@as(usize, 2), display.ranges.len);
    try std.testing.expectEqualStrings(url, display.ranges[0].url);
    try std.testing.expectEqualStrings("https://example.test/guide…", display.text[display.ranges[0].start..display.ranges[0].end]);
    const targets = try links(source, "", allocator);
    try std.testing.expectEqualStrings(url, targets.values[0]);
    const unsafe = "Literal <div> and https://user:password@example.test/private remain literal.";
    const unchanged = try displayLinks(allocator, unsafe);
    try std.testing.expectEqualStrings(unsafe, unchanged.text);
    try std.testing.expectEqual(@as(usize, 0), unchanged.ranges.len);
    const unicode = try compactUrl(allocator, "https://example.test/über/über/über/über/über/über/über/über/über/über/über");
    try std.testing.expect(unicode.len <= display_url_bytes and std.unicode.utf8ValidateSlice(unicode));
    try std.testing.expect(std.mem.endsWith(u8, unicode, "…"));
}
