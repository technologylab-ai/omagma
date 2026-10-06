const std = @import("std");
const t = @import("types.zig");

/// Local queries inspect literal metadata and already downloaded plaintext.
/// Whitespace joins terms with AND; double quotes preserve a phrase. No HTML,
/// encoded attachments, remote request, or implicit body download is involved.
const Terms = struct {
    query: []const u8,
    offset: usize = 0,
    count: usize = 0,
    fn next(self: *Terms) !?[]const u8 {
        while (self.offset < self.query.len and std.ascii.isWhitespace(self.query[self.offset])) self.offset += 1;
        if (self.offset == self.query.len) return null;
        if (self.count == 32) return error.InvalidQuery;
        self.count += 1;
        const start = self.offset;
        var quoted = false;
        while (self.offset < self.query.len) : (self.offset += 1) {
            const ch = self.query[self.offset];
            if (ch == '"') quoted = !quoted;
            if (!quoted and std.ascii.isWhitespace(ch)) break;
        }
        if (quoted) return error.InvalidQuery;
        return self.query[start..self.offset];
    }
};
fn unquote(value: []const u8) []const u8 {
    return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
}
pub fn find(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    return std.ascii.findIgnoreCase(haystack, needle);
}
fn has(message: t.Message, label: []const u8) bool {
    for (message.labels) |value| if (std.ascii.eqlIgnoreCase(value, label)) return true;
    return false;
}
fn addressMatches(addresses: []const t.Address, term: []const u8) bool {
    for (addresses) |address| if (find(address.address, term) != null or find(address.name, term) != null) return true;
    return false;
}
fn termMatches(message: t.Message, token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, ':')) |split| {
        const field = token[0..split];
        const value = unquote(token[split + 1 ..]);
        if (std.mem.eql(u8, field, "from")) return find(message.from.address, value) != null or find(message.from.name, value) != null;
        if (std.mem.eql(u8, field, "to")) return addressMatches(message.to, value);
        if (std.mem.eql(u8, field, "cc")) return addressMatches(message.cc, value);
        if (std.mem.eql(u8, field, "subject")) return find(message.subject, value) != null;
        if (std.mem.eql(u8, field, "body")) return find(message.bodyText, value) != null;
        if (std.mem.eql(u8, field, "label")) return has(message, value);
        if (std.mem.eql(u8, field, "is")) {
            if (std.mem.eql(u8, value, "unread")) return message.unread;
            if (std.mem.eql(u8, value, "read")) return !message.unread;
            if (std.mem.eql(u8, value, "starred")) return has(message, "STARRED");
            return false;
        }
        if (std.mem.eql(u8, field, "has")) return std.mem.eql(u8, value, "attachment") and message.attachments.len != 0;
        if (std.mem.eql(u8, field, "in")) {
            if (std.mem.eql(u8, value, "anywhere")) return true;
            if (std.mem.eql(u8, value, "all")) return !has(message, "TRASH") and !has(message, "SPAM");
            if (std.mem.eql(u8, value, "archive")) return !has(message, "INBOX") and !has(message, "TRASH") and !has(message, "SPAM");
            return has(message, value);
        }
    }
    const value = unquote(token);
    for (message.labels) |label| if (find(label, value) != null) return true;
    return find(message.subject, value) != null or find(message.snippet, value) != null or find(message.bodyText, value) != null or find(message.from.address, value) != null or find(message.from.name, value) != null;
}
pub fn matches(message: t.Message, query: []const u8) bool {
    var terms: Terms = .{ .query = query };
    while (terms.next() catch return false) |token| {
        const negative = token.len > 0 and token[0] == '-';
        const matched = termMatches(message, if (negative) token[1..] else token);
        if (matched == negative) return false;
    }
    return true;
}
pub fn validate(query: []const u8) !void {
    if (query.len > 4096 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
    var terms: Terms = .{ .query = query };
    while (try terms.next()) |_| {}
}
pub fn highlightTerm(query: []const u8) []const u8 {
    var terms: Terms = .{ .query = query };
    var metadata: []const u8 = "";
    while (terms.next() catch return "") |token| {
        if (token.len == 0 or token[0] == '-') continue;
        if (std.mem.indexOfScalar(u8, token, ':')) |split| {
            const field = token[0..split];
            if (!std.mem.eql(u8, field, "subject") and !std.mem.eql(u8, field, "body") and !std.mem.eql(u8, field, "from") and !std.mem.eql(u8, field, "to")) continue;
            if (std.mem.eql(u8, field, "body")) return unquote(token[split + 1 ..]);
            if (metadata.len == 0) metadata = unquote(token[split + 1 ..]);
            continue;
        }
        return unquote(token);
    }
    return metadata;
}
pub fn needsBody(query: []const u8) bool {
    var terms: Terms = .{ .query = query };
    while (terms.next() catch return false) |raw| {
        const token = if (raw.len > 0 and raw[0] == '-') raw[1..] else raw;
        const split = std.mem.indexOfScalar(u8, token, ':') orelse return true;
        const field = token[0..split];
        if (std.mem.eql(u8, field, "body")) return true;
        var metadata = false;
        for ([_][]const u8{ "from", "to", "cc", "subject", "label", "is", "in", "has" }) |name| metadata = metadata or std.mem.eql(u8, field, name);
        if (!metadata) return true;
    }
    return false;
}

test "wishlist: cache full text terms quoted phrases and exclusions" {
    const message: t.Message = .{ .id = "m", .threadId = "t", .from = .{ .address = "alice@example.test", .name = "Alice" }, .subject = "Weekly report", .bodyText = "The secret marmalade project", .labels = &.{ "INBOX", "UNREAD" }, .unread = true };
    try std.testing.expect(matches(message, "from:alice body:\"secret marmalade\" is:unread"));
    try std.testing.expect(!matches(message, "body:marmalade -in:inbox"));
    try std.testing.expect(matches(message, "subject:report -body:missing"));
    try std.testing.expect(!matches(message, "body:absent"));
    try std.testing.expectError(error.InvalidQuery, validate("body:\"unterminated"));
    try std.testing.expectEqualStrings("secret marmalade", highlightTerm("is:unread body:\"secret marmalade\""));
}
