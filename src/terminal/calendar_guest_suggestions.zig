//! Bounded local guest suggestions; accepting replaces only the current token.
const std = @import("std");
const completion = @import("completion.zig");
const picker = @import("calendar_guest_picker.zig");
const recipients = @import("recipients.zig");
const composer = @import("calendar_composer.zig");
const Value = std.json.Value;
pub const max_matches = 8;
pub const Matches = struct {
    values: [max_matches]picker.Candidate = undefined,
    len: usize = 0,
    range: completion.Range,
    pub fn slice(self: *const Matches) []const picker.Candidate {
        return self.values[0..self.len];
    }
};
pub fn partial(raw: []const u8, cursor: usize) ?completion.Range {
    const range = completion.token(raw, cursor);
    if (range.query.len == 0 or !std.unicode.utf8ValidateSlice(range.query)) return null;
    if (std.mem.indexOfAny(u8, range.query, "\"<>;") != null) return null;
    if (recipients.validateAddress(range.query)) |_| return null else |_| {}
    return range;
}
pub fn eligible(raw: []const u8, cursor: usize) ?completion.Range {
    const range = partial(raw, cursor) orelse return null;
    if ((std.unicode.utf8CountCodepoints(range.query) catch return null) < 2) return null;
    return range;
}
fn includes(raw: []const u8, query: []const u8) bool {
    if (query.len > raw.len) return false;
    for (0..raw.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(raw[i..][0..query.len], query)) return true;
    return false;
}
fn quality(candidate: picker.Candidate, query: []const u8) u8 {
    const at = std.mem.indexOfScalar(u8, candidate.address, '@') orelse candidate.address.len;
    const local = candidate.address[0..at];
    if (std.ascii.startsWithIgnoreCase(local, query)) return 3;
    for (candidate.name, 0..) |_, i| if (i == 0 or !std.ascii.isAlphanumeric(candidate.name[i - 1])) {
        if (std.ascii.startsWithIgnoreCase(candidate.name[i..], query)) return 3;
    };
    if (includes(local, query) or includes(candidate.name, query)) return 2;
    return if (includes(candidate.address, query)) 1 else 0;
}
pub fn collect(a: std.mem.Allocator, contacts: Value, recent: Value, self_address: []const u8, raw: []const u8, cursor: usize) !Matches {
    var out: Matches = .{ .range = completion.token(raw, cursor) };
    const range = eligible(raw, cursor) orelse return out;
    const candidates = try picker.combine(a, contacts, recent, .null, range.query);
    defer a.free(candidates);
    for ([_]u8{ 3, 2, 1 }) |rank| for (candidates) |candidate| {
        if (quality(candidate, range.query) != rank or recipients.sameGmailIdentity(candidate.address, self_address) or picker.contains(raw, candidate.address)) continue;
        out.values[out.len] = candidate;
        out.len += 1;
        if (out.len == max_matches) return out;
    };
    return out;
}
pub const Replacement = struct { text: []const u8, cursor: usize };
pub fn replace(a: std.mem.Allocator, raw: []const u8, range: completion.Range, address: []const u8) !Replacement {
    recipients.validateAddress(address) catch return error.CalendarInvalidGuest;
    if (picker.contains(raw, address)) return error.CalendarInvalidGuest;
    const value = try completion.replace(a, raw, range, address);
    defer a.free(value);
    const tail = raw.len - range.end;
    const at_end = tail == 0;
    const result = if (at_end) try std.fmt.allocPrint(a, "{s}, ", .{value}) else try a.dupe(u8, value);
    errdefer a.free(result);
    if (result.len > composer.guest_bytes) return error.CalendarFieldTooLong;
    const Count = struct {
        total: usize = 0,
        pub fn visit(self: *@This(), _: []const u8) !void {
            self.total += 1;
        }
    };
    var count: Count = .{};
    if (recipients.scanAddresses(result, &count)) |_| {
        if (count.total > composer.max_guests) return error.CalendarTooManyGuests;
    } else |_| {
        var pieces = std.mem.splitScalar(u8, result, ',');
        var total: usize = 0;
        while (pieces.next()) |piece| if (std.mem.trim(u8, piece, " \t").len != 0) {
            total += 1;
        };
        if (total > composer.max_guests) return error.CalendarTooManyGuests;
    }
    return .{ .text = result, .cursor = value.len - tail + (if (at_end) @as(usize, 2) else 0) };
}

test "calendar guest suggestions: threshold complete address and quoted tokens stay text" {
    for ([_][]const u8{ "", "a", "é", "person@example.test", "\"Ameni", "Ameni <am" }) |raw| try std.testing.expect(eligible(raw, raw.len) == null);
    try std.testing.expectEqualStrings("am", eligible("one@example.test, am", 20).?.query);
    try std.testing.expectEqualStrings("am", eligible("one@example.test; am", 20).?.query);
    try std.testing.expectEqualStrings("a", partial("a", 1).?.query);
}
test "calendar guest suggestions: current token replacement keeps later recipients and cursor" {
    const a = std.testing.allocator;
    const raw = "first@example.test, am, last@example.test";
    const range = completion.token(raw, "first@example.test, am".len);
    const updated = try replace(a, raw, range, "ameni@example.test");
    defer a.free(updated.text);
    try std.testing.expectEqualStrings("first@example.test, ameni@example.test, last@example.test", updated.text);
    try std.testing.expectEqual("first@example.test, ameni@example.test".len, updated.cursor);
    const final = try replace(a, "am", completion.token("am", 2), "ameni@example.test");
    defer a.free(final.text);
    try std.testing.expectEqualStrings("ameni@example.test, ", final.text);
    try std.testing.expectEqual(final.text.len, final.cursor);
}
test "calendar guest suggestions: local sources rank deduplicate and exclude self and existing guests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const contacts = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Ameni Example","emails":[{"address":"ameni@example.test"}]},{"name":"Already Am","emails":[{"address":"old@example.test"}]}]}
    , .{});
    const recent = try std.json.parseFromSliceLeaky(Value, a,
        \\{"recipients":[{"name":"Ameni Recent","address":"ameni@example.test"},{"name":"Self Am","address":"self@example.test"}]}
    , .{});
    const raw = "old@example.test, am";
    const matches = try collect(a, contacts, recent, "self@example.test", raw, raw.len);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("ameni@example.test", matches.values[0].address);
}
