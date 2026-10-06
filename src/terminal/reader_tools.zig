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
pub fn findLinks(input: []const u8, result: *Links) void {
    var position: usize = 0;
    while (position < input.len) {
        const tail = input[position..];
        const https = std.mem.indexOf(u8, tail, "https://");
        const http = std.mem.indexOf(u8, tail, "http://");
        const start = if (https) |a| if (http) |b| @min(a, b) else a else http orelse break;
        var end = position + start;
        while (end < input.len and input[end] > 32 and std.mem.indexOfScalar(u8, "<>\"'", input[end]) == null) : (end += 1) {}
        var trimmed = end;
        while (trimmed > position + start and std.mem.indexOfScalar(u8, ".,;!)]}", input[trimmed - 1]) != null) trimmed -= 1;
        result.add(input[position + start .. trimmed]);
        position = @max(end, position + start + 1);
    }
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
