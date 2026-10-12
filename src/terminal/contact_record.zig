const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const recipients = @import("recipients.zig");
const bounded = @import("../bounded.zig");
const policy = @import("mail_limits.zig");

pub const ReadOptions = struct { search: bool = false, limit: usize = 100, retain_provider: bool = true };
pub const ReadPage = struct {
    contacts: []t.Contact,
    nextCursor: ?[]const u8 = null,
    partial: bool = false,
    contactWarnings: t.ContactReadWarnings = .{},
};

fn count(value: usize) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}
fn readArray(value: j.Value, key: []const u8, warnings: *t.ContactReadWarnings) []const j.Value {
    const field = j.get(value, key) orelse return &.{};
    if (field == .array) return field.array.items;
    warnings.invalidFields +|= 1;
    return &.{};
}
fn identity(value: j.Value) ?[]const u8 {
    const resource_name = j.text(value, "resourceName");
    if (!std.mem.startsWith(u8, resource_name, "people/")) return null;
    bounded.identifier(resource_name[7..]) catch return null;
    return resource_name;
}
fn readRecord(a: std.mem.Allocator, value: j.Value, resource_name: []const u8, retain_provider: bool) !?t.Contact {
    var warnings: t.ContactReadWarnings = .{};
    const raw_emails = readArray(value, "emailAddresses", &warnings);
    // Inspect at most 32 source addresses, preserving the established contact
    // bound even when a provider returns an unexpectedly large array.
    const email_count = @min(raw_emails.len, 32);
    warnings.omittedEmails = count(raw_emails.len - email_count);
    var emails: std.ArrayList(t.Address) = .empty;
    for (raw_emails[0..email_count]) |entry| {
        const address = j.text(entry, "value");
        recipients.validateAddress(address) catch {
            warnings.omittedEmails +|= 1;
            continue;
        };
        var duplicate = false;
        for (emails.items) |previous| duplicate = duplicate or recipients.sameAddress(address, previous.address);
        if (duplicate) {
            warnings.omittedEmails +|= 1;
            continue;
        }
        try emails.append(a, .{ .address = address });
    }
    const names = readArray(value, "names", &warnings);
    const name_count = @min(names.len, 32);
    warnings.omittedNames = count(names.len - name_count);
    var name: []const u8 = "";
    var primary = false;
    for (names[0..name_count]) |entry| {
        const candidate = j.get(entry, "displayName") orelse {
            warnings.omittedNames +|= 1;
            continue;
        };
        if (candidate != .string or !std.unicode.utf8ValidateSlice(candidate.string)) {
            warnings.omittedNames +|= 1;
            continue;
        }
        var len = @min(candidate.string.len, policy.display_name_bytes);
        if (len < candidate.string.len) while (len > 0 and candidate.string[len] & 0xc0 == 0x80) : (len -= 1) {};
        const cleaned = try @import("mime.zig").sanitizeHeaderText(candidate.string[0..len], a);
        if (!std.mem.eql(u8, cleaned, candidate.string)) warnings.sanitizedNames +|= 1;
        if (std.mem.trim(u8, cleaned, " ").len == 0) continue;
        const preferred = if (j.get(entry, "metadata")) |metadata| j.boolean(metadata, "primary", false) catch false else false;
        if (name.len == 0 or (preferred and !primary)) {
            name = cleaned;
            primary = preferred;
        }
    }
    if (name.len == 0 and emails.items.len == 0) return null;
    var etag: []const u8 = "";
    if (j.get(value, "metadata")) |metadata| {
        if (metadata != .object) warnings.omittedMetadata = 1 else {
            const sources = readArray(metadata, "sources", &warnings);
            if (sources.len > 32) warnings.omittedMetadata = 1;
            for (sources[0..@min(sources.len, 32)]) |source| {
                if (source != .object) {
                    warnings.omittedMetadata = 1;
                    continue;
                }
                if (!std.mem.eql(u8, j.text(source, "type"), "CONTACT")) continue;
                const raw_etag = j.get(source, "etag") orelse continue;
                if (raw_etag != .string or raw_etag.string.len > 4096) {
                    warnings.omittedMetadata = 1;
                    continue;
                }
                recipients.validateHeader(raw_etag.string) catch {
                    warnings.omittedMetadata = 1;
                    continue;
                };
                etag = raw_etag.string;
            }
        }
    }
    var provider: ?j.Value = null;
    if (!warnings.any()) {
        var fields = j.object(a);
        for ([_][]const u8{ "names", "emailAddresses", "metadata" }) |key| if (j.get(value, key)) |field| try fields.object.put(a, key, field);
        // Count without allocating the over-limit serialization. Only a bounded
        // provider object can survive the temporary record/page arenas.
        if (@import("gmail_decode.zig").serializedBytes(fields) > 64 * 1024) warnings.omittedMetadata = 1 else if (retain_provider) provider = fields;
    }
    if (warnings.any()) warnings.partialContacts = 1;
    return .{ .resourceName = resource_name, .etag = etag, .name = name, .emails = emails.items, .provider = provider, .readWarnings = warnings };
}
fn copyRead(a: std.mem.Allocator, value: t.Contact) !t.Contact {
    var result = value;
    result.resourceName = try a.dupe(u8, value.resourceName);
    result.etag = try a.dupe(u8, value.etag);
    result.name = try a.dupe(u8, value.name);
    const emails = try a.alloc(t.Address, value.emails.len);
    for (value.emails, emails) |email, *dest| dest.* = .{ .address = try a.dupe(u8, email.address) };
    result.emails = emails;
    result.provider = if (value.provider) |provider| try j.value(a, provider) else null;
    return result;
}
/// Strict page boundaries and bounded record-local loss are shared by every
/// People read. Global allocator/provider failures are never swallowed here.
pub fn readPage(a: std.mem.Allocator, scratch: std.mem.Allocator, value: j.Value, options: ReadOptions) !ReadPage {
    if (value != .object or options.limit == 0 or options.limit > 100) return error.InvalidProviderResponse;
    const field = j.get(value, if (options.search) "results" else "connections");
    if (field != null and field.? != .array) return error.InvalidProviderResponse;
    const entries: []const j.Value = if (field) |present| present.array.items else &.{};
    if (entries.len > @min(options.limit, if (options.search) @as(usize, 30) else 100)) return error.InvalidPage;
    const cursor = if (j.get(value, "nextPageToken")) |v| if (v == .string) v.string else return error.InvalidProviderResponse else "";
    if (cursor.len > 4096) return error.InvalidProviderResponse;
    recipients.validateHeader(cursor) catch return error.InvalidProviderResponse;
    var result: ReadPage = .{ .contacts = try a.alloc(t.Contact, entries.len) };
    var used: usize = 0;
    for (entries) |entry| {
        const person = if (options.search) j.get(entry, "person") orelse .null else entry;
        const resource_name = identity(person) orelse {
            result.contactWarnings.omittedContacts +|= 1;
            continue;
        };
        var duplicate = false;
        for (result.contacts[0..used]) |previous| duplicate = duplicate or std.mem.eql(u8, resource_name, previous.resourceName);
        if (duplicate) {
            result.contactWarnings.omittedContacts +|= 1;
            continue;
        }
        var record_scope: std.heap.ArenaAllocator = .init(scratch);
        defer record_scope.deinit();
        const normalized = (try readRecord(record_scope.allocator(), person, resource_name, options.retain_provider)) orelse {
            result.contactWarnings.omittedContacts +|= 1;
            continue;
        };
        result.contacts[used] = try copyRead(a, normalized);
        result.contactWarnings.add(normalized.readWarnings);
        used += 1;
    }
    result.contacts = result.contacts[0..used];
    result.nextCursor = if (cursor.len > 0) try a.dupe(u8, cursor) else null;
    result.partial = result.contactWarnings.any();
    return result;
}

fn array(value: j.Value, key: []const u8) ![]j.Value {
    const entries = j.get(value, key) orelse return &.{};
    if (entries != .array) return error.InvalidContact;
    return entries.array.items;
}
pub fn validate(value: t.Contact) !void {
    try recipients.validateHeader(value.name);
    if (value.name.len > policy.display_name_bytes or value.emails.len == 0 or value.emails.len > 32) return error.InvalidContact;
    for (value.emails, 0..) |email, index| {
        try recipients.validateAddress(email.address);
        try recipients.validateHeader(email.name);
        if (email.name.len > policy.display_name_bytes) return error.InvalidContact;
        for (value.emails[0..index]) |previous| if (recipients.sameAddress(email.address, previous.address)) return error.DuplicateAddress;
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
    if (name.len > policy.display_name_bytes or etag.len > 4096) return error.ContactTooLarge;
    var provider = j.object(a);
    for ([_][]const u8{ "names", "emailAddresses", "metadata" }) |key| if (j.get(value, key)) |field| try provider.object.put(a, key, field);
    if ((try std.json.Stringify.valueAlloc(a, provider, .{})).len > 64 * 1024) return error.ContactTooLarge;
    return .{ .resourceName = resource_name, .etag = etag, .name = try @import("mime.zig").sanitizeHeaderText(name, a), .emails = emails, .provider = provider };
}
pub fn mergeInput(a: std.mem.Allocator, value: j.Value, current: ?t.Contact) !t.Contact {
    var result = try j.decode(t.Contact, a, value);
    if (current) |old| {
        // Read isolation must never silently become a destructive write of the
        // retained subset. Live updates first fetch a strictly decoded record.
        if (old.readWarnings.any()) return error.IncompleteContact;
        if (j.get(value, "name") == null) result.name = old.name;
        if (j.get(value, "emails") == null) result.emails = old.emails;
        result.provider = old.provider;
    } else result.provider = null;
    result.readWarnings = .{};
    try validate(result);
    return result;
}
pub fn emailsEqual(left: []const t.Address, right: []const t.Address) bool {
    if (left.len != right.len) return false;
    for (left, right) |l, r| if (!recipients.sameAddress(l.address, r.address)) return false;
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
        for (old_emails) |old| if (recipients.sameAddress(email.address, j.text(old, "value"))) {
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

test "mailbox compatibility: contacts allow Unicode names and preserve distinct local parts" {
    var name_bytes: [1023]u8 = undefined;
    for (0..341) |index| @memcpy(name_bytes[index * 3 ..][0..3], "界");
    const long = &name_bytes;
    try validate(.{ .name = long, .emails = &.{ .{ .address = "Smith@例子.test" }, .{ .address = "smith@例子.test" }, .{ .address = "用户@例子.test" } } });
    try std.testing.expectError(error.DuplicateAddress, validate(.{ .emails = &.{ .{ .address = "Smith@example.test" }, .{ .address = "\"Smith\"@EXAMPLE.test" } } }));
    const too_long = try std.mem.concat(std.testing.allocator, u8, &.{ long, "界" });
    defer std.testing.allocator.free(too_long);
    try std.testing.expectError(error.InvalidContact, validate(.{ .name = too_long, .emails = &.{.{ .address = "peer@example.test" }} }));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const normalized = try normalize(a, try j.value(a, .{ .resourceName = "people/unicode", .names = .{.{ .displayName = long }}, .emailAddresses = .{.{ .value = "用户@例子.test" }} }));
    try std.testing.expectEqualStrings(long, normalized.name);
    try std.testing.expectEqualStrings("用户@例子.test", normalized.emails[0].address);
}
