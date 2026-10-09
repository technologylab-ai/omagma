//! Local, account-scoped recipient suggestions. No provider lookup or field
//! mutation happens while collecting the bounded candidates.
const std = @import("std");
const recipients = @import("recipients.zig");
const Value = std.json.Value;
pub const max_matches = 8;
pub const Candidate = struct { address: []const u8, name: []const u8 };
pub const Range = struct { start: usize, end: usize, query: []const u8 };
pub const Matches = struct {
    values: [max_matches]Candidate = undefined,
    len: usize = 0,
    range: Range,
    pub fn slice(self: *const Matches) []const Candidate {
        return self.values[0..self.len];
    }
};

pub fn token(raw: []const u8, cursor_in: usize) Range {
    const cursor = @min(cursor_in, raw.len);
    var quote = false;
    var escape = false;
    var angle = false;
    var comments: usize = 0;
    var start: usize = 0;
    var end = raw.len;
    for (raw, 0..) |byte, index| {
        if (escape) {
            escape = false;
            continue;
        }
        if ((quote or comments > 0) and byte == '\\') {
            escape = true;
            continue;
        }
        if (comments > 0) {
            if (byte == '(') comments += 1 else if (byte == ')') comments -= 1;
            continue;
        }
        if (byte == '"') quote = !quote;
        if (quote) continue;
        if (byte == '(') comments = 1 else if (byte == '<') angle = true else if (byte == '>') angle = false else if (!angle and (byte == ',' or byte == ';')) {
            if (index < cursor) start = index + 1 else {
                end = index;
                break;
            }
        }
    }
    while (start < end and std.ascii.isWhitespace(raw[start])) start += 1;
    const query_end = @max(start, @min(cursor, end));
    return .{ .start = start, .end = end, .query = std.mem.trim(u8, raw[start..query_end], " \t") };
}
fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn text(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn safeName(raw: []const u8) []const u8 {
    if (raw.len > 256) return "";
    recipients.validateHeader(raw) catch return "";
    return raw;
}
fn includes(raw: []const u8, query: []const u8) bool {
    if (query.len > raw.len) return false;
    for (0..raw.len - query.len + 1) |index| if (std.ascii.eqlIgnoreCase(raw[index..][0..query.len], query)) return true;
    return false;
}
pub fn collect(contacts: []const Value, raw: []const u8, cursor: usize) Matches {
    var out: Matches = .{ .range = token(raw, cursor) };
    if (out.range.query.len == 0 or out.range.query.len > 254) return out;
    for (contacts) |contact| {
        const name = safeName(text(field(contact, "name")));
        const emails = field(contact, "emails");
        if (emails != .array) continue;
        for (emails.array.items) |mailbox| {
            const address = text(field(mailbox, "address"));
            recipients.validateAddress(address) catch continue;
            if ((!includes(address, out.range.query) and !includes(name, out.range.query)) or std.ascii.eqlIgnoreCase(address, out.range.query)) continue;
            var duplicate = false;
            for (out.slice()) |previous| duplicate = duplicate or std.ascii.eqlIgnoreCase(previous.address, address);
            if (duplicate) continue;
            out.values[out.len] = .{ .address = address, .name = name };
            out.len += 1;
            if (out.len == max_matches) return out;
        }
    }
    return out;
}
pub fn collectKnown(known: []const Value, contacts: []const Value, self_address: []const u8, raw: []const u8, cursor: usize) Matches {
    var out: Matches = .{ .range = token(raw, cursor) };
    if (out.range.query.len == 0 or out.range.query.len > 254) return out;
    // The cached projection is already ranked by recent interaction. Saved
    // contacts remain a compatibility fallback while that projection loads.
    for ([_]u8{ 3, 2, 1 }) |wanted_quality| {
        for (known) |value| {
            const address = text(field(value, "address"));
            const name = safeName(text(field(value, "name")));
            recipients.validateAddress(address) catch continue;
            if (std.ascii.eqlIgnoreCase(address, self_address) or std.ascii.eqlIgnoreCase(address, out.range.query) or matchQuality(name, address, out.range.query) != wanted_quality) continue;
            var duplicate = false;
            for (out.slice()) |previous| duplicate = duplicate or std.ascii.eqlIgnoreCase(previous.address, address);
            if (duplicate) continue;
            out.values[out.len] = .{ .address = address, .name = name };
            out.len += 1;
            if (out.len == max_matches) return out;
        }
        const saved = collect(contacts, raw, cursor);
        for (saved.slice()) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.address, self_address) or matchQuality(candidate.name, candidate.address, out.range.query) != wanted_quality) continue;
            var duplicate = false;
            for (out.slice()) |previous| duplicate = duplicate or std.ascii.eqlIgnoreCase(previous.address, candidate.address);
            if (duplicate) continue;
            out.values[out.len] = candidate;
            out.len += 1;
            if (out.len == max_matches) return out;
        }
    }
    return out;
}
fn matchQuality(name: []const u8, address: []const u8, query: []const u8) u8 {
    const at = std.mem.indexOfScalar(u8, address, '@') orelse address.len;
    const local = address[0..at];
    if (std.ascii.startsWithIgnoreCase(local, query)) return 3;
    for (name, 0..) |_, index| if (index == 0 or !std.ascii.isAlphanumeric(name[index - 1])) {
        if (std.ascii.startsWithIgnoreCase(name[index..], query)) return 3;
    };
    if (includes(local, query) or includes(name, query)) return 2;
    return if (includes(address, query)) 1 else 0;
}
pub fn replace(allocator: std.mem.Allocator, raw: []const u8, range: Range, address: []const u8) ![]u8 {
    return replaceCandidate(allocator, raw, range, .{ .address = address, .name = "" });
}
/// Replace only the current mailbox token. Existing comma/semicolon separators
/// and recipients after the cursor are retained exactly, without appending a
/// second separator. Cursor after insertion = result.len - (raw.len-range.end).
pub fn replaceCandidate(allocator: std.mem.Allocator, raw: []const u8, range: Range, candidate: Candidate) ![]u8 {
    if (range.start > range.end or range.end > raw.len) return error.InvalidCompletionRange;
    const mailbox = try recipients.formatDisplay(allocator, candidate.address, candidate.name);
    defer allocator.free(mailbox);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ raw[0..range.start], mailbox, raw[range.end..] });
}

test "composer completion: full mailbox preserves Unicode commas quotes and later separators" {
    const allocator = std.testing.allocator;
    const raw = "first@example.test, Jö, last@example.test";
    const range = token(raw, "first@example.test, Jö".len);
    const result = try replaceCandidate(allocator, raw, range, .{ .address = "jo@example.test", .name = "Jörg, \"Jo\" \\ Example" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("first@example.test, \"Jörg, \\\"Jo\\\" \\\\ Example\" <jo@example.test>, last@example.test", result);
    var parsed: recipients.List = .{};
    try recipients.parse(result, &parsed);
    try std.testing.expectEqual(@as(u8, 3), parsed.count);
    try std.testing.expectEqualStrings("Jörg, \"Jo\" \\ Example", parsed.items[1].name.slice());
    try std.testing.expectError(error.HeaderInjection, replaceCandidate(allocator, "Jo", token("Jo", 2), .{ .address = "jo@example.test", .name = "Jo\nBcc: bad@example.test" }));
}

test "composer completion: quoted commas and later recipients survive replacement" {
    const raw = "\"Doe, Jane\" <jane@example.test>, al, last@example.test";
    const range = token(raw, 35);
    try std.testing.expectEqualStrings("al", range.query);
    const replaced = try replace(std.testing.allocator, raw, range, "alex@example.test");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("\"Doe, Jane\" <jane@example.test>, alex@example.test, last@example.test", replaced);
}
test "composer completion: suggestions validate deduplicate and never exceed eight" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const contacts = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "[{\"name\":\"Alex Example\",\"emails\":[{\"address\":\"alex@example.test\"},{\"address\":\"alex@example.test\"},{\"address\":\"bad\\n@example.test\"}]},{\"name\":\"Another\",\"emails\":[{\"address\":\"other@example.test\"}]}]", .{});
    const matches = collect(contacts.array.items, "AL", 2);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("alex@example.test", matches.values[0].address);
    try std.testing.expectEqual(@as(usize, 0), collect(contacts.array.items, "alex@example.test", 17).len);
    try std.testing.expectEqual(@as(usize, 0), collect(contacts.array.items, "", 0).len);
}
