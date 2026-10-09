const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const recipients = @import("recipients.zig");
const bounded = @import("../bounded.zig");

fn array(value: j.Value, key: []const u8) ![]j.Value {
    const entries = j.get(value, key) orelse return &.{};
    if (entries != .array) return error.InvalidContact;
    return entries.array.items;
}
pub fn validate(value: t.Contact) !void {
    try recipients.validateHeader(value.name);
    if (value.name.len > 256 or value.emails.len == 0 or value.emails.len > 32) return error.InvalidContact;
    for (value.emails, 0..) |email, index| {
        try recipients.validateAddress(email.address);
        try recipients.validateHeader(email.name);
        for (value.emails[0..index]) |previous| if (std.ascii.eqlIgnoreCase(email.address, previous.address)) return error.DuplicateAddress;
    }
}
pub fn normalize(a: std.mem.Allocator, value: j.Value) !t.Contact {
    const names = try array(value, "names");
    const raw_emails = try array(value, "emailAddresses");
    if (names.len > 32 or raw_emails.len > 32) return error.ContactTooLarge;
    const emails = try a.alloc(t.Address, raw_emails.len);
    for (raw_emails, emails) |entry, *dest| {
        const address = try j.required(entry, "value");
        try recipients.validateAddress(address);
        dest.* = .{ .address = address };
    }
    var etag: []const u8 = "";
    if (j.get(value, "metadata")) |metadata| for (try array(metadata, "sources")) |source| if (std.mem.eql(u8, j.text(source, "type"), "CONTACT")) {
        etag = j.text(source, "etag");
    };
    const resource_name = try j.required(value, "resourceName");
    if (!std.mem.startsWith(u8, resource_name, "people/")) return error.InvalidContactIdentity;
    try bounded.identifier(resource_name[7..]);
    var name: []const u8 = "";
    for (names) |entry| {
        if (name.len == 0) name = j.text(entry, "displayName");
        if (j.get(entry, "metadata")) |metadata| if (j.boolean(metadata, "primary", false) catch false) {
            name = j.text(entry, "displayName");
            break;
        };
    }
    if (name.len > 512 or etag.len > 4096) return error.ContactTooLarge;
    var provider = j.object(a);
    for ([_][]const u8{ "names", "emailAddresses", "metadata" }) |key| if (j.get(value, key)) |field| try provider.object.put(a, key, field);
    if ((try std.json.Stringify.valueAlloc(a, provider, .{})).len > 64 * 1024) return error.ContactTooLarge;
    return .{ .resourceName = resource_name, .etag = etag, .name = try @import("mime.zig").sanitizeText(name, a), .emails = emails, .provider = provider };
}
pub fn mergeInput(a: std.mem.Allocator, value: j.Value, current: ?t.Contact) !t.Contact {
    var result = try j.decode(t.Contact, a, value);
    if (current) |old| {
        if (j.get(value, "name") == null) result.name = old.name;
        if (j.get(value, "emails") == null) result.emails = old.emails;
        result.provider = old.provider;
    } else result.provider = null;
    try validate(result);
    return result;
}
pub fn emailsEqual(left: []const t.Address, right: []const t.Address) bool {
    if (left.len != right.len) return false;
    for (left, right) |l, r| if (!std.mem.eql(u8, l.address, r.address)) return false;
    return true;
}
pub fn providerBody(a: std.mem.Allocator, value: t.Contact, current: ?t.Contact) !j.Value {
    var body = j.object(a);
    const previous = if (current) |old| old.provider orelse @as(j.Value, .null) else @as(j.Value, .null);
    const same_name = if (current) |old| std.mem.eql(u8, value.name, old.name) else false;
    const names = if (same_name) j.get(previous, "names") else null;
    try body.object.put(a, "names", names orelse try j.value(a, .{.{ .unstructuredName = value.name }}));
    var emails: std.ArrayList(j.Value) = .empty;
    const old_emails = try array(previous, "emailAddresses");
    for (value.emails) |email| {
        var preserved: ?j.Value = null;
        for (old_emails) |old| if (std.ascii.eqlIgnoreCase(email.address, j.text(old, "value"))) {
            preserved = old;
            break;
        };
        var entry = if (preserved) |old| try j.copyObject(a, old) else j.object(a);
        try entry.object.put(a, "value", .{ .string = email.address });
        try emails.append(a, entry);
    }
    try body.object.put(a, "emailAddresses", try j.value(a, emails.items));
    if (j.get(previous, "metadata")) |metadata| try body.object.put(a, "metadata", metadata);
    return body;
}

test "contacts: changing one address preserves other addresses and People metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try std.json.parseFromSliceLeaky(j.Value, a,
        \\{"resourceName":"people/fixture","names":[{"displayName":"Alex Fixture","givenName":"Alex","familyName":"Fixture"}],"emailAddresses":[{"value":"alex@example.test","type":"work","metadata":{"primary":true}},{"value":"home@example.test","type":"home","displayName":"Personal"}],"metadata":{"sources":[{"type":"CONTACT","etag":"source-v1"}]}}
    , .{});
    const current = try normalize(a, original);
    const edited = try mergeInput(a, try j.value(a, .{ .name = "Alex Changed" }), current);
    try std.testing.expectEqual(@as(usize, 2), edited.emails.len);
    const name_body = try providerBody(a, edited, current);
    const name_emails = try array(name_body, "emailAddresses");
    try std.testing.expectEqualStrings("home", j.text(name_emails[1], "type"));
    try std.testing.expectEqualStrings("Personal", j.text(name_emails[1], "displayName"));
    const addresses = try mergeInput(a, try j.value(a, .{ .emails = .{ .{ .address = "alex@example.test" }, .{ .address = "new@example.test" } } }), current);
    const address_body = try providerBody(a, addresses, current);
    const names = try array(address_body, "names");
    try std.testing.expectEqualStrings("Fixture", j.text(names[0], "familyName"));
    const after_emails = try array(address_body, "emailAddresses");
    try std.testing.expect(try j.boolean(j.get(after_emails[0], "metadata").?, "primary", false));
    try std.testing.expectEqualStrings("new@example.test", j.text(after_emails[1], "value"));
}
