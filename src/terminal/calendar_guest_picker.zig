//! Account-bound Calendar address-book projection. Choosing an address appends
//! a bare email; it never replaces existing guests or alters notification policy.
const std = @import("std");
const composer = @import("calendar_composer.zig");
const recipients = @import("recipients.zig");
const Value = std.json.Value;
pub const max_candidates = 1024;
pub const Candidate = struct { name: []const u8, address: []const u8 };

fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn text(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn includes(value: []const u8, query: []const u8) bool {
    if (query.len > value.len) return false;
    for (0..value.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(value[i..][0..query.len], query)) return true;
    return false;
}
pub fn collect(a: std.mem.Allocator, response: Value, query: []const u8) ![]const Candidate {
    const contacts = field(response, "contacts");
    if (contacts != .array or contacts.array.items.len > 1024) return error.InvalidContactsResponse;
    var out: std.ArrayList(Candidate) = .empty;
    defer out.deinit(a);
    for (contacts.array.items) |contact| {
        var name = text(field(contact, "name"));
        if (name.len > 512) name = "";
        recipients.validateHeader(name) catch {
            name = "";
        };
        const emails = field(contact, "emails");
        if (emails != .array) continue;
        for (emails.array.items) |email| {
            const address = text(field(email, "address"));
            if (!validAddress(address)) continue;
            if (!includes(name, query) and !includes(address, query)) continue;
            var duplicate = false;
            for (out.items) |entry| duplicate = duplicate or std.ascii.eqlIgnoreCase(entry.address, address);
            if (duplicate) continue;
            try out.append(a, .{ .name = name, .address = address });
            if (out.items.len == max_candidates) return out.toOwnedSlice(a);
        }
    }
    return out.toOwnedSlice(a);
}
fn validAddress(address: []const u8) bool {
    @import("../bounded.zig").address(address) catch return false;
    return std.mem.indexOfAny(u8, address, "<>(),;:") == null;
}
pub fn contains(raw: []const u8, address: []const u8) bool {
    var entries = std.mem.splitScalar(u8, raw, ',');
    while (entries.next()) |entry| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, entry, " \t\r\n"), address)) return true;
    return false;
}
pub fn append(a: std.mem.Allocator, raw: []const u8, address: []const u8) !?[]const u8 {
    if (!validAddress(address)) return error.CalendarInvalidGuest;
    if (contains(raw, address)) return null;
    const trimmed = std.mem.trimEnd(u8, raw, " \t\r\n");
    const separator: []const u8 = if (trimmed.len == 0) "" else if (std.mem.endsWith(u8, trimmed, ",")) (if (raw.len == trimmed.len) " " else "") else ", ";
    if (raw.len + separator.len + address.len > composer.guest_bytes) return error.CalendarFieldTooLong;
    var entries = std.mem.splitScalar(u8, raw, ',');
    var count: usize = 0;
    while (entries.next()) |entry| if (std.mem.trim(u8, entry, " \t\r\n").len > 0) {
        count += 1;
    };
    if (count >= composer.max_guests) return error.CalendarTooManyGuests;
    // Preserve even unfinished manually typed text. The exact Review validates
    // every token before it can save or send invitations.
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ raw, separator, address });
}

test "calendar composer: address book exposes distinct safe addresses and appends without replacing existing guests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const contacts = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Alex Example","emails":[{"address":"alex@example.test"},{"address":"alex.work@example.test"},{"address":"ALEX@example.test"},{"address":"bad\n@example.test"}]},{"name":"Other","emails":[{"address":"other@example.test"}]}]}
    , .{});
    const all = try collect(a, contacts, "");
    try std.testing.expectEqual(@as(usize, 3), all.len);
    const alex = try collect(a, contacts, "ALEX");
    try std.testing.expectEqual(@as(usize, 2), alex.len);
    try std.testing.expectEqualStrings("alex.work@example.test", alex[1].address);
    const before = "host@example.test, guest@example.test, ";
    const after = (try append(a, before, alex[1].address)).?;
    try std.testing.expectEqualStrings("host@example.test, guest@example.test, alex.work@example.test", after);
    try std.testing.expect((try append(a, after, "ALEX.WORK@example.test")) == null);
    try std.testing.expectEqualStrings("unfinished, alex@example.test", (try append(a, "unfinished", alex[0].address)).?);
    try std.testing.expectError(error.CalendarInvalidGuest, append(a, "", "Alex <alex@example.test>"));
}
