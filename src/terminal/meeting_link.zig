//! Shared bounded meeting-link selection. Results borrow the original text;
//! query parameters, escapes and case are never decoded or reconstructed.
const std = @import("std");
const tools = @import("reader_tools.zig");
pub const max_description_bytes = 128 * 1024;

pub fn plain(description: []const u8) []const u8 {
    return select(description, false);
}

/// HTML callers use this first, before their generic Join-labelled fallback.
pub fn plainKnown(description: []const u8) []const u8 {
    return select(description, true);
}

fn select(description: []const u8, known_only: bool) []const u8 {
    if (description.len > max_description_bytes) return "";
    var fallback: []const u8 = "";
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, description, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // A complete URI is not prose: preserve significant trailing bytes.
        if (knownUrl(line)) return line;
        if (std.ascii.startsWithIgnoreCase(line, "Join:")) {
            const exact = std.mem.trim(u8, line[5..], " \t");
            if (tools.safeUrl(exact)) {
                if (knownUrl(exact)) return exact;
                if (!known_only and fallback.len == 0) fallback = exact;
                count += 1;
                if (count == tools.max_links) return fallback;
                continue;
            }
        }
        const join_label = std.ascii.findIgnoreCase(line, "join") != null;
        var links: tools.LinkIterator = .{ .input = line };
        while (links.next()) |link| {
            count += 1;
            if (knownUrl(link.url)) return link.url;
            if (!known_only and join_label and fallback.len == 0) fallback = link.url;
            if (count == tools.max_links) return fallback;
        }
    }
    return fallback;
}

/// Recognize common video meeting routes, independently of invitation language.
/// Match domain boundaries, not substrings in unrelated hosts or query strings.
pub fn knownUrl(url: []const u8) bool {
    if (!tools.safeUrl(url)) return false;
    const uri = std.Uri.parse(url) catch return false;
    var buffer: [1024]u8 = undefined;
    const host = (uri.host orelse return false).toRaw(&buffer) catch return false;
    const path = uri.path.percent_encoded;
    if (std.ascii.eqlIgnoreCase(host, "meet.google.com")) return path.len > 1;
    if (hostIs(host, "zoom.us") or hostIs(host, "zoom.com")) return std.mem.startsWith(u8, path, "/j/") or std.mem.startsWith(u8, path, "/my/") or std.mem.startsWith(u8, path, "/wc/join/");
    if (std.ascii.eqlIgnoreCase(host, "teams.microsoft.com") or std.ascii.eqlIgnoreCase(host, "teams.cloud.microsoft")) return std.mem.startsWith(u8, path, "/l/meetup-join/") or std.mem.startsWith(u8, path, "/meet/");
    if (std.ascii.eqlIgnoreCase(host, "teams.live.com")) return std.mem.startsWith(u8, path, "/meet/");
    if (hostIs(host, "webex.com")) return std.mem.indexOf(u8, path, "/j.php") != null or std.mem.startsWith(u8, path, "/meet/");
    return false;
}

fn hostIs(host: []const u8, domain: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, domain) or (host.len > domain.len and host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain));
}

test "meeting Join: language-independent links retain exact URLs and prefer meetings over notes" {
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "Jetzt teilnehmen: https://teams.microsoft.com/meet/123?p=Ab%2Bcd&context=%7B%22Tid%22%3A%22fixture%22%7D", .expected = "https://teams.microsoft.com/meet/123?p=Ab%2Bcd&context=%7B%22Tid%22%3A%22fixture%22%7D" },
        .{ .text = "Rejoindre la réunion\nhttps://company.zoom.us/j/123?pwd=fixture", .expected = "https://company.zoom.us/j/123?pwd=fixture" },
        .{ .text = "https://meet.google.com/abc-defg-hij", .expected = "https://meet.google.com/abc-defg-hij" },
        .{ .text = "Join notes https://docs.example.test/notes\nhttps://teams.cloud.microsoft/meet/123?p=fixture", .expected = "https://teams.cloud.microsoft/meet/123?p=fixture" },
        .{ .text = "Join https://docs.example.test/notes then https://teams.live.com/meet/123", .expected = "https://teams.live.com/meet/123" },
        .{ .text = "Join: https://custom.example.test/room?token=fixture!", .expected = "https://custom.example.test/room?token=fixture!" },
        .{ .text = "https://company.zoom.us/my/room?token=fixture!", .expected = "https://company.zoom.us/my/room?token=fixture!" },
        .{ .text = "Join meeting https://custom.example.test/room", .expected = "https://custom.example.test/room" },
        .{ .text = "Meeting notes: https://docs.example.test/notes", .expected = "" },
        .{ .text = "https://notzoom.us/j/123", .expected = "" },
        .{ .text = "https://zoom.us.attacker.example.test/j/123", .expected = "" },
        .{ .text = "Join: https://user:password@meet.example.test/meet/123", .expected = "" },
        .{ .text = "Join: javascript:alert(1)", .expected = "" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, plain(case.text));
    try std.testing.expectEqualStrings("", plainKnown("Join: https://custom.example.test/room"));
}

test "meeting Join: description and candidate scans remain bounded" {
    const oversized = try std.testing.allocator.alloc(u8, max_description_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectEqualStrings("", plain(oversized));
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..tools.max_links - 1) |_| try input.appendSlice(std.testing.allocator, "https://docs.example.test/notes\n");
    const before_limit = input.items.len;
    const meeting = "https://meet.google.com/abc-defg-hij";
    try input.appendSlice(std.testing.allocator, meeting);
    try std.testing.expectEqualStrings(meeting, plain(input.items));
    input.shrinkRetainingCapacity(before_limit);
    try input.appendSlice(std.testing.allocator, "https://docs.example.test/last\n" ++ meeting);
    try std.testing.expectEqualStrings("", plain(input.items));
}

/// Detect actual inert HTML tags, not email-address angle brackets or plain
/// prose whose first letters happen to match a tag name.
pub fn htmlDescription(value: []const u8) bool {
    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, value, position, '<')) |start| {
        const first = start + 1 + @as(usize, if (start + 1 < value.len and value[start + 1] == '/') 1 else 0);
        for ([_][]const u8{ "a", "p", "div", "br", "table", "html", "span", "b", "i", "ul", "ol", "pre", "strong", "em", "blockquote", "h1", "h2", "h3", "li", "td", "tr" }) |tag| {
            const last = first + tag.len;
            if (last < value.len and std.ascii.eqlIgnoreCase(value[first..last], tag) and (value[last] == '>' or value[last] == '/' or std.ascii.isWhitespace(value[last]))) return true;
        }
        position = start + 1;
    }
    return false;
}
test "meeting Join: HTML detection distinguishes real tags from literal email addresses" {
    for ([_][]const u8{ "Alice <alice@example.test>", "<peter@example.test>", "Contact <olga@example.test>", "Math <bigger than>" }) |plain_text| try std.testing.expect(!htmlDescription(plain_text));
    for ([_][]const u8{ "<p>Notes</p>", "<A href=\"https://meet.example.test\">Join</a>", "<br />Next", "<table><tr><td>Meeting</td></tr></table>" }) |html| try std.testing.expect(htmlDescription(html));
}
