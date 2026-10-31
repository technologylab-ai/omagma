//! Literal, bounded reader helpers. No markup execution or resource fetching.
const std = @import("std");
const html_document = @import("html_document.zig");
pub const max_links = 128;
/// Visible anchor text kept per destination, including any final ellipsis.
pub const max_title_bytes = 256;
pub const Links = struct {
    values: [max_links][]const u8 = @splat(""),
    /// Visible anchor text for values[i], or "" when none adds information.
    titles: [max_links][]const u8 = @splat(""),
    count: usize = 0,
    truncated: bool = false,
    pub fn add(self: *Links, value: []const u8) void {
        self.addTitled(value, "");
    }
    /// Destinations keep first-seen order and exact bytes. A repeat only
    /// supplies a missing title or replaces an image-only one (titleRank);
    /// it never adds a row, so upgrades still apply once the list is full.
    pub fn addTitled(self: *Links, value: []const u8, title: []const u8) void {
        self.insert(null, value, title) catch unreachable;
    }
    /// As addTitled, but copies only retained bytes into `allocator`, so the
    /// caller can release the per-message scratch `value`/`title` borrow.
    pub fn addCopy(self: *Links, allocator: std.mem.Allocator, value: []const u8, title: []const u8) !void {
        try self.insert(allocator, value, title);
    }
    fn insert(self: *Links, copy: ?std.mem.Allocator, value: []const u8, raw_title: []const u8) !void {
        if (!safeUrl(value)) return;
        const title = if (raw_title.len <= max_title_bytes and std.unicode.utf8ValidateSlice(raw_title)) raw_title else "";
        for (self.values[0..self.count], 0..) |old, index| if (std.mem.eql(u8, old, value)) {
            if (titleRank(title) > titleRank(self.titles[index])) self.titles[index] = if (copy) |a| try a.dupe(u8, title) else title;
            return;
        };
        if (self.count == max_links) {
            self.truncated = true;
            return;
        }
        const owned = if (copy) |a| try a.dupe(u8, value) else value;
        errdefer if (copy) |a| a.free(owned);
        self.titles[self.count] = if (copy != null and title.len > 0) try copy.?.dupe(u8, title) else title;
        self.values[self.count] = owned;
        self.count += 1;
    }
};
/// 0 no title, 1 only image placeholders such as "[Image: Logo]", 2 text.
fn titleRank(title: []const u8) u2 {
    if (title.len == 0) return 0;
    if (std.mem.startsWith(u8, title, "[Image") and std.mem.endsWith(u8, title, "]")) return 1;
    return 2;
}
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
/// Results borrow `text` and `allocator`; copy what must outlive them
/// (Links.addCopy). Titles are visible anchor text only: never a title
/// attribute, fetched page title or unwrapped redirect.
pub fn links(text: []const u8, html: []const u8, allocator: std.mem.Allocator) !Links {
    var result: Links = .{};
    findLinks(text, &result);
    // Semantic parsing retains exact entity-decoded hrefs. Guessing them from
    // converted display text could remove meaningful terminal punctuation.
    if (html.len > 0) {
        const document = html_document.parse(html, allocator) catch return result;
        var anchors: AnchorTitles = .{ .result = &result, .allocator = allocator };
        var container: usize = 0;
        for (document.blocks) |block| {
            container += 1;
            for (block.spans) |span| try anchors.span(container, span);
            if (block.table) |table| {
                for (table.rows) |row| {
                    for (row.cells) |cell| {
                        container += 1;
                        for (cell.spans) |span| try anchors.span(container, span);
                    }
                }
            }
        }
        try anchors.finish();
    }
    return result;
}
/// Groups the consecutive spans of one anchor. The parser shares one decoded
/// href slice across every span an anchor produces, so that identical slice
/// continues an anchor across blocks and table cells (joined by one space).
/// Distinct anchors stay separate even when their destinations match.
/// Spans join exactly as authored: Re<b>view</b> reads "Review", never "Re view".
const AnchorTitles = struct {
    result: *Links,
    allocator: std.mem.Allocator,
    link: ?[]const u8 = null,
    container: usize = 0,
    title: TitleBuilder = .{},
    fn span(self: *AnchorTitles, container: usize, value: html_document.Span) !void {
        const link = value.link orelse return self.finish();
        if (self.link) |current| {
            const same_slice = current.ptr == link.ptr and current.len == link.len;
            if (same_slice) {
                if (container != self.container) self.title.separate();
                self.container = container;
                self.title.append(value.text);
                return;
            }
            try self.finish();
        }
        self.link = link;
        self.container = container;
        self.title = .{ .url = link };
        self.title.append(value.text);
    }
    fn finish(self: *AnchorTitles) !void {
        const link = self.link orelse return;
        self.link = null;
        self.result.addTitled(link, try self.title.finish(self.allocator));
    }
};
/// Bounded literal anchor text. Whitespace runs and line breaks collapse to
/// one space; terminal, bidi and invisible format characters are dropped
/// even though the parser already removes most of them.
const TitleBuilder = struct {
    url: []const u8 = "",
    matched: usize = 0,
    differs: bool = false,
    bytes: [max_title_bytes]u8 = undefined,
    len: usize = 0,
    space: bool = false,
    full: bool = false,
    fn separate(self: *TitleBuilder) void {
        if (self.len > 0) self.space = true;
    }
    fn append(self: *TitleBuilder, text: []const u8) void {
        var position: usize = 0;
        while (position < text.len and !(self.full and self.differs)) {
            const length = std.unicode.utf8ByteSequenceLength(text[position]) catch {
                position += 1;
                continue;
            };
            if (length > text.len - position) return;
            const slice = text[position..][0..length];
            position += length;
            const cp = std.unicode.utf8Decode(slice) catch continue;
            if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0xa0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000) {
                self.separate();
            } else if (!hiddenCodepoint(cp)) self.put(slice);
        }
    }
    fn put(self: *TitleBuilder, slice: []const u8) void {
        // Compare the full normalized label even after its display buffer fills.
        // Safe destinations contain no spaces, so a pending internal space
        // proves a difference; trailing whitespace never reaches put().
        if (!self.differs) {
            if (self.space or slice.len > self.url.len - self.matched or !std.mem.eql(u8, slice, self.url[self.matched..][0..slice.len])) {
                self.differs = true;
            } else self.matched += slice.len;
        }
        if (self.full) {
            self.space = false;
            return;
        }
        const space: usize = @intFromBool(self.space);
        if (self.len + space + slice.len > max_title_bytes - "…".len) {
            self.full = true;
            return;
        }
        if (self.space) {
            self.bytes[self.len] = ' ';
            self.len += 1;
            self.space = false;
        }
        @memcpy(self.bytes[self.len..][0..slice.len], slice);
        self.len += slice.len;
    }
    fn finish(self: *const TitleBuilder, allocator: std.mem.Allocator) ![]const u8 {
        const value = self.bytes[0..self.len];
        if (value.len == 0 or (!self.differs and self.matched == self.url.len)) return "";
        if (self.full) return std.fmt.allocPrint(allocator, "{s}…", .{value});
        return allocator.dupe(u8, value);
    }
};
fn hiddenCodepoint(cp: u21) bool {
    return cp < 32 or (cp >= 127 and cp <= 159) or cp == 0xad or cp == 0x034f or cp == 0x061c or cp == 0x180e or
        cp == 0x200b or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or
        (cp >= 0x2060 and cp <= 0x2069) or cp == 0xfeff or (cp >= 0xfff9 and cp <= 0xfffb);
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

test "local reader: link titles join one anchor's styled spans, entities, breaks and table cells" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const html =
        "<p>Before <a href='https://example.test/keys' title='Attribute only'>Review <b>API</b> Keys</a> after.</p>" ++
        "<p><a href='https://example.test/re'>Re<b>view</b> API</a></p>" ++
        "<p><a href=\"https://example.test/q?a=1&amp;b=(2)!\">Tom &amp; Jerry&nbsp;&mdash;\n  <i>Season</i><br>Two</a></p>" ++
        "<table><tr><th>Name</th><th>Link</th></tr><tr><td>Plan</td><td><a href='https://example.test/cell'>Open <code>plan</code></a></td></tr></table>" ++
        "<a href='https://example.test/wrap'><p>Block one</p><p>Block two</p></a>" ++
        "<p><a href='https://example.test/image'><img src='https://example.test/logo.png' alt='Logo'></a></p>" ++
        "<p><a href='https://example.test/image'>Company home</a> <a href='https://example.test/keys'>Second label</a></p>";
    const found = try links("", html, arena.allocator());
    const expected = [_][2][]const u8{
        .{ "https://example.test/keys", "Review API Keys" },
        .{ "https://example.test/re", "Review API" },
        .{ "https://example.test/q?a=1&b=(2)!", "Tom & Jerry — Season Two" },
        .{ "https://example.test/cell", "Open plan" },
        .{ "https://example.test/wrap", "Block one Block two" },
        .{ "https://example.test/image", "Company home" },
    };
    try std.testing.expectEqual(expected.len, found.count);
    for (expected, 0..) |pair, index| {
        try std.testing.expectEqualStrings(pair[0], found.values[index]);
        try std.testing.expectEqualStrings(pair[1], found.titles[index]);
    }
}

test "local reader: plain URLs keep their place, gain one later label and never duplicate rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tracked = "https://example.test/report?id=7&sig=a%2Fb";
    const plain = "See " ++ tracked ++ ", https://example.test/plain and https://example.test/same/.";
    const html =
        "<p><a href='https://example.test/report?id=7&amp;sig=a%2Fb'>https://example.test/report?id=7&amp;sig=a%2Fb</a> " ++
        "<a href='https://example.test/report?id=7&amp;sig=a%2Fb'>Quarterly <em>report</em></a> " ++
        "<a href='https://example.test/report?id=7&amp;sig=a%2Fb'>Different later label</a> " ++
        "<a href='https://example.test/plain'>https://example.test/plain</a> " ++
        "<a href='https://example.test/same/'>EXAMPLE.test/same</a> " ++
        "<a href='https://example.test/punct?q=(1)!'>Punctuated</a></p>";
    const found = try links(plain, html, arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), found.count);
    try std.testing.expectEqualStrings(tracked, found.values[0]);
    try std.testing.expectEqualStrings("Quarterly report", found.titles[0]);
    try std.testing.expectEqualStrings("https://example.test/plain", found.values[1]);
    try std.testing.expectEqualStrings("", found.titles[1]);
    try std.testing.expectEqualStrings("https://example.test/same/", found.values[2]);
    try std.testing.expectEqualStrings("EXAMPLE.test/same", found.titles[2]);
    try std.testing.expectEqualStrings("https://example.test/punct?q=(1)!", found.values[3]);
    try std.testing.expectEqualStrings("Punctuated", found.titles[3]);
}

test "local reader: unsafe anchors stay out and titles drop controls within a UTF-8 byte bound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const long = comptime blk: {
        var bytes: [600]u8 = undefined;
        for (0..300) |index| @memcpy(bytes[index * 2 ..][0..2], "é");
        break :blk bytes;
    };
    const html =
        "<p><a href='javascript:alert(1)'>Run</a> <a href='https://user:pw@example.test/'>Credentials</a> " ++
        "<a href='mailto:someone@example.test'>Mail</a> <a href='file:///etc/passwd'>File</a> " ++
        "<a href='https://example.test/ctl'>Safe&#x1b;[31m&#x202e;txt.exe&#8203; name&#x2066;</a> " ++
        "<a href='https://example.test/long'>" ++ long ++ "</a></p>";
    const found = try links("", html, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), found.count);
    try std.testing.expectEqualStrings("https://example.test/ctl", found.values[0]);
    try std.testing.expectEqualStrings("Safe[31mtxt.exe name", found.titles[0]);
    try std.testing.expectEqualStrings("https://example.test/long", found.values[1]);
    const title = found.titles[1];
    try std.testing.expect(title.len <= max_title_bytes and std.unicode.utf8ValidateSlice(title));
    try std.testing.expect(std.mem.startsWith(u8, title, "éé") and std.mem.endsWith(u8, title, "…"));
}

test "local reader: title upgrades still reach a full list and retained copies outlive parse scratch" {
    var found: Links = .{};
    var names: [max_links + 1][32]u8 = undefined;
    for (0..max_links) |index| found.add(try std.fmt.bufPrint(&names[index], "https://example.test/{d}", .{index}));
    try std.testing.expect(found.count == max_links and !found.truncated);
    found.addTitled("https://example.test/5", "Fifth page");
    try std.testing.expectEqualStrings("Fifth page", found.titles[5]);
    try std.testing.expect(!found.truncated);
    found.addTitled(try std.fmt.bufPrint(&names[max_links], "https://example.test/{d}", .{max_links}), "Overflow");
    try std.testing.expect(found.truncated and found.count == max_links);
    found.addTitled("https://example.test/5", "[Image]");
    try std.testing.expectEqualStrings("Fifth page", found.titles[5]);

    var overlay: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer overlay.deinit();
    var retained: Links = .{};
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const parsed = try links("", "<p><a href='https://example.test/a?x=1&amp;y=2'><img src='https://example.test/i.png' alt='Logo'></a> <a href='https://example.test/a?x=1&amp;y=2'>Alpha <b>docs</b></a></p>", scratch.allocator());
    for (parsed.values[0..parsed.count], parsed.titles[0..parsed.count]) |url, title| try retained.addCopy(overlay.allocator(), url, title);
    scratch.deinit();
    try std.testing.expectEqual(@as(usize, 1), retained.count);
    try std.testing.expectEqualStrings("https://example.test/a?x=1&y=2", retained.values[0]);
    try std.testing.expectEqualStrings("Alpha docs", retained.titles[0]);
    var buffer: [16]u8 = undefined;
    try retained.addCopy(overlay.allocator(), "https://example.test/b", "");
    try retained.addCopy(overlay.allocator(), "https://example.test/b", try std.fmt.bufPrint(&buffer, "Beta", .{}));
    @memset(&buffer, 'x');
    try std.testing.expectEqualStrings("Beta", retained.titles[1]);
}

test "local reader: link titles preserve exact differences and independent adjacent anchors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const html = "<p><a href='https://example.test/Path'>https://example.test/path</a>" ++
        "<a href='https://example.test/?x=A'>https://example.test/?x=a</a>" ++
        "<a href='https://example.test/scheme'>http://example.test/scheme</a>" ++
        "<a href='https://example.test/slash/'>https://example.test/slash</a>" ++
        "<a href='https://example.test/exact'>https://example.test/exact</a>" ++
        "<a href='https://example.test/adjacent'>One</a><a href='https://example.test/adjacent'>Two</a></p>";
    const found = try links("", html, arena.allocator());
    try std.testing.expectEqual(@as(usize, 6), found.count);
    for ([_][]const u8{ "https://example.test/path", "https://example.test/?x=a", "http://example.test/scheme", "https://example.test/slash", "", "One" }, 0..) |title, index| {
        try std.testing.expectEqualStrings(title, found.titles[index]);
    }
    var long_html: std.ArrayList(u8) = .empty;
    defer long_html.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try long_html.appendSlice(a, "<a href='https://example.test/");
    for (0..300) |_| try long_html.append(a, 'x');
    try long_html.appendSlice(a, "A'>https://example.test/");
    for (0..300) |_| try long_html.append(a, 'x');
    try long_html.appendSlice(a, "B</a>");
    const long_found = try links("", long_html.items, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), long_found.count);
    try std.testing.expect(long_found.titles[0].len > 0 and std.mem.endsWith(u8, long_found.titles[0], "…"));
    // Identical long auto-link labels remain bare, including trailing whitespace.
    const equal_html = try std.fmt.allocPrint(arena.allocator(), "<a href='{s}'>{s} </a>", .{ long_found.values[0], long_found.values[0] });
    const equal_found = try links(long_found.values[0], equal_html, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), equal_found.count);
    try std.testing.expectEqualStrings("", equal_found.titles[0]);
}

test "local reader: link copies leave prior entries intact and free URL on title allocation failure" {
    var found: Links = .{};
    found.add("https://example.test/existing");
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, found.addCopy(failing.allocator(), "https://example.test/new", "New title"));
    try std.testing.expectEqual(@as(usize, 1), found.count);
    try std.testing.expectEqualStrings("https://example.test/existing", found.values[0]);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
}
