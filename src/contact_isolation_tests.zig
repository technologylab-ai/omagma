//! Synthetic contact pages exercise the shared native/browser read policy.
//! No credentials, production account, network or provider mutation is used.
const std = @import("std");
const records = @import("terminal/contact_record.zig");
const gmail = @import("terminal/gmail.zig");
const live = @import("browser_live.zig");
const cache = @import("browser_cache.zig");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");

const mixed =
    \\{"connections":[
    \\{"resourceName":"people/good1","names":[{"displayName":"Alex Fixture"}],"emailAddresses":[{"value":"alex@example.test"}]},
    \\{"resourceName":"people/partial","names":[{"displayName":"Readable peer"}],"emailAddresses":[{"value":"broken"},{"value":"用户@例子.test"},{"value":"用户@例子.TEST"}]},
    \\{"names":[{"displayName":"No identity"}],"emailAddresses":[{"value":"lost@example.test"}]},
    \\{"resourceName":"people/useless","emailAddresses":[{"value":"invalid"}]},
    \\{"resourceName":"people/nameonly","names":[{"displayName":"Phone contact"}],"emailAddresses":7},
    \\{"resourceName":"people/good2","names":[{"displayName":"最後"}],"emailAddresses":[{"value":"last@example.test"}]},
    \\{"resourceName":"people/good1","emailAddresses":[{"value":"duplicate@example.test"}]}
    \\],"nextPageToken":"next/+="}
;
fn parse(a: std.mem.Allocator, bytes: []const u8) !j.Value {
    return std.json.parseFromSliceLeaky(j.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}
fn warnings(a: std.mem.Allocator, value: j.Value) !t.ContactReadWarnings {
    return j.decode(t.ContactReadWarnings, a, j.get(value, "contactWarnings") orelse return error.MissingWarnings);
}
fn ids(page: records.ReadPage, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, page.contacts.len);
    for (page.contacts, expected) |contact, id| try std.testing.expectEqualStrings(id, contact.resourceName);
}
test "contact isolation: malformed records retain neighbors safe addresses and name-only contacts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try records.readPage(a, std.testing.allocator, try parse(a, mixed), .{});
    try ids(page, &.{ "people/good1", "people/partial", "people/nameonly", "people/good2" });
    try std.testing.expect(page.partial);
    try std.testing.expectEqualStrings("next/+=", page.nextCursor.?);
    try std.testing.expectEqual(@as(u32, 3), page.contactWarnings.omittedContacts);
    try std.testing.expectEqual(@as(u32, 2), page.contactWarnings.partialContacts);
    try std.testing.expectEqual(@as(u32, 2), page.contactWarnings.omittedEmails);
    try std.testing.expectEqual(@as(u32, 1), page.contactWarnings.invalidFields);
    try std.testing.expectEqualStrings("用户@例子.test", page.contacts[1].emails[0].address);
    try std.testing.expectEqual(@as(usize, 1), page.contacts[1].emails.len);
    try std.testing.expectEqual(@as(usize, 0), page.contacts[2].emails.len);
    try std.testing.expectEqualStrings("Phone contact", page.contacts[2].name);
    try std.testing.expect(page.contacts[0].provider != null);
    try std.testing.expect(page.contacts[1].provider == null);
    try std.testing.expectError(error.IncompleteContact, records.mergeInput(a, try j.value(a, .{ .name = "Changed" }), page.contacts[1]));
    try std.testing.expectError(error.InvalidAddress, records.normalize(a, j.get(try parse(a, mixed), "connections").?.array.items[1]));
}

test "contact isolation: per-field bounds preserve UTF-8 and never retain oversized metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var long_name: [1026]u8 = undefined;
    for (0..342) |index| @memcpy(long_name[index * 3 ..][0..3], "界");
    const source_emails = try a.alloc(j.Value, 34);
    for (source_emails, 0..) |*email, index| email.* = try j.value(a, .{ .value = try std.fmt.allocPrint(a, "peer-{d}@example.test", .{index}) });
    const source_names = try a.alloc(j.Value, 33);
    for (source_names, 0..) |*name, index| name.* = try j.value(a, .{ .displayName = if (index == 0) @as([]const u8, &long_name) else "Alternate" });
    const raw = try j.value(a, .{ .connections = .{.{ .resourceName = "people/wide", .names = source_names, .emailAddresses = source_emails }} });
    const page = try records.readPage(a, std.testing.allocator, raw, .{});
    try std.testing.expectEqual(@as(usize, 1), page.contacts.len);
    try std.testing.expectEqual(@as(usize, 1023), page.contacts[0].name.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(page.contacts[0].name));
    try std.testing.expectEqual(@as(usize, 32), page.contacts[0].emails.len);
    try std.testing.expectEqual(@as(u32, 1), page.contactWarnings.sanitizedNames);
    try std.testing.expectEqual(@as(u32, 1), page.contactWarnings.omittedNames);
    try std.testing.expectEqual(@as(u32, 2), page.contactWarnings.omittedEmails);
    try std.testing.expectError(error.ContactTooLarge, records.normalize(a, j.get(raw, "connections").?.array.items[0]));
    const oversized = try a.alloc(u8, 70 * 1024);
    @memset(oversized, 'x');
    const metadata = try j.value(a, .{ .connections = .{.{ .resourceName = "people/metadata", .names = .{.{ .displayName = "Kept", .extra = oversized }}, .emailAddresses = .{.{ .value = "kept@example.test" }} }} });
    for ([_]bool{ false, true }) |retain| {
        // The decoded provider page already exists. Refusing its oversized
        // metadata must not require a second oversized output allocation.
        var output: [8192]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&output);
        const result = try records.readPage(fixed.allocator(), std.testing.allocator, metadata, .{ .retain_provider = retain });
        try std.testing.expectEqualStrings("Kept", result.contacts[0].name);
        try std.testing.expect(result.contacts[0].provider == null);
        try std.testing.expectEqual(@as(u32, 1), result.contactWarnings.omittedMetadata);
    }
    const etag_page = try records.readPage(a, std.testing.allocator, try j.value(a, .{ .connections = .{.{ .resourceName = "people/etag", .names = .{.{ .displayName = "Version omitted" }}, .metadata = .{ .sources = .{.{ .type = "CONTACT", .etag = oversized }} } }} }), .{});
    try std.testing.expectEqualStrings("", etag_page.contacts[0].etag);
    try std.testing.expectEqual(@as(u32, 1), etag_page.contactWarnings.omittedMetadata);
    const address = try a.alloc(u8, 513);
    @memset(address, 'a');
    @memcpy(address[500..], "@example.test");
    const email_page = try records.readPage(a, std.testing.allocator, try j.value(a, .{ .connections = .{.{ .resourceName = "people/addresses", .emailAddresses = .{ .{ .value = address }, .{ .value = address[1..] } } }} }), .{});
    try std.testing.expectEqual(@as(usize, 1), email_page.contacts[0].emails.len);
    try std.testing.expectEqual(@as(usize, 512), email_page.contacts[0].emails[0].address.len);
    try std.testing.expectEqual(@as(u32, 1), email_page.contactWarnings.omittedEmails);
}

test "contact isolation: malformed names metadata and wrapped search people are row-local" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a,
        \\{"results":[{"person":{"resourceName":"people/controls","names":[{"displayName":"Ada\u001b[31m\nFixture"}],"emailAddresses":[{"value":"ada@example.test"}],"metadata":{"sources":7}}},{"bad":"wrapper"},{"person":false},{"person":{"resourceName":"people/fallback","names":[7,{"displayName":8},{"displayName":"Fallback"}],"metadata":7}}]}
    );
    const page = try records.readPage(a, std.testing.allocator, source, .{ .search = true });
    try ids(page, &.{ "people/controls", "people/fallback" });
    try std.testing.expectEqual(@as(u32, 2), page.contactWarnings.omittedContacts);
    try std.testing.expectEqual(@as(u32, 2), page.contactWarnings.partialContacts);
    try std.testing.expectEqual(@as(u32, 2), page.contactWarnings.omittedNames);
    try std.testing.expectEqual(@as(u32, 1), page.contactWarnings.sanitizedNames);
    try std.testing.expectEqualStrings("Ada[31m Fixture", page.contacts[0].name);
    try std.testing.expectEqualStrings("Fallback", page.contacts[1].name);
    const invalid_utf8 = try j.value(a, .{ .resourceName = "people/utf8", .emailAddresses = .{.{ .value = "safe@example.test" }} });
    var invalid = invalid_utf8;
    try invalid.object.put(a, "names", try j.value(a, .{.{ .displayName = "valid" }}));
    var names = j.get(invalid, "names").?;
    try names.array.items[0].object.put(a, "displayName", .{ .string = "\xff" });
    const invalid_page = try records.readPage(a, std.testing.allocator, try pageValue(a, &.{invalid}, false), .{});
    try std.testing.expectEqualStrings("", invalid_page.contacts[0].name);
    try std.testing.expectEqual(@as(u32, 1), invalid_page.contactWarnings.omittedNames);
}
fn pageValue(a: std.mem.Allocator, entries: []const j.Value, search: bool) !j.Value {
    var result = j.object(a);
    var copies = std.json.Array.init(a);
    try copies.appendSlice(entries);
    try result.object.put(a, if (search) "results" else "connections", .{ .array = copies });
    return result;
}

test "contact isolation: corrupt page envelopes and allocator exhaustion remain fatal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "null", "[]", "{\"connections\":null}", "{\"connections\":7}", "{\"nextPageToken\":7}" }) |bytes| try std.testing.expectError(error.InvalidProviderResponse, records.readPage(a, std.testing.allocator, try parse(a, bytes), .{}));
    const many = try a.alloc(j.Value, 101);
    @memset(many, .null);
    try std.testing.expectError(error.InvalidPage, records.readPage(a, std.testing.allocator, try pageValue(a, many, false), .{}));
    try std.testing.expectError(error.InvalidPage, records.readPage(a, std.testing.allocator, try pageValue(a, many[0..31], true), .{ .search = true }));
    const source = try parse(a, mixed);
    var output_failure: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, records.readPage(output_failure.allocator(), std.testing.allocator, source, .{}));
    var scratch_failure: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, records.readPage(a, scratch_failure.allocator(), source, .{}));
}

test "contact isolation: read DTOs own only bounded data after provider scratch is destroyed" {
    var output: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer output.deinit();
    var source: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const raw = try parse(source.allocator(), mixed);
    const page = try records.readPage(output.allocator(), std.testing.allocator, raw, .{});
    source.deinit();
    try std.testing.expectEqualStrings("Alex Fixture", page.contacts[0].name);
    try std.testing.expectEqualStrings("alex@example.test", page.contacts[0].emails[0].address);
    try std.testing.expectEqualStrings("Alex Fixture", j.text(j.get(page.contacts[0].provider.?, "names").?.array.items[0], "displayName"));
}

const Peer = struct {
    body: []const u8 = mixed,
    fatal: ?anyerror = null,
    calls: usize = 0,
    writes: usize = 0,
    fn transport(self: *@This()) gmail.Transport {
        return .{ .context = self, .requestFn = request, .temporary_allocator = std.testing.allocator };
    }
    fn request(context: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (method != .GET or body != null) {
            self.writes += 1;
            return error.UnexpectedWrite;
        }
        if (self.fatal) |err| return err;
        if (std.mem.endsWith(u8, url, "query=")) return parse(a, "{}");
        return parse(a, self.body);
    }
};

test "contact isolation: bounded provider search reaches beyond the list head and retains omission warnings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "{\"connections\":[");
    for (0..100) |index| try body.print(a, "{s}{{\"resourceName\":\"people/head{d}\",\"names\":[{{\"displayName\":\"Head {d}\"}}],\"emailAddresses\":[{{\"value\":\"head{d}@example.test\"}}]}}", .{ if (index == 0) "" else ",", index, index, index });
    try body.appendSlice(a, "],\"nextPageToken\":\"another/contact/page+=\"}");
    const Oracle = struct {
        list_body: []const u8,
        lists: usize = 0,
        warmups: usize = 0,
        searches: usize = 0,
        writes: usize = 0,
        fn request(context: *anyopaque, allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, request_body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (method != .GET or request_body != null) {
                self.writes += 1;
                return error.UnexpectedWrite;
            }
            if (std.mem.eql(u8, url, "https://people.googleapis.com/v1/people/me/connections?personFields=names,emailAddresses,metadata&sources=READ_SOURCE_TYPE_CONTACT&pageSize=100&pageToken=")) {
                self.lists += 1;
                return parse(allocator, self.list_body);
            }
            if (std.mem.eql(u8, url, "https://people.googleapis.com/v1/people:searchContacts?readMask=names,emailAddresses,metadata&pageSize=30&query=")) {
                self.warmups += 1;
                return parse(allocator, "{}");
            }
            if (std.mem.eql(u8, url, "https://people.googleapis.com/v1/people:searchContacts?readMask=names,emailAddresses,metadata&pageSize=30&query=Beyond%20first%20page")) {
                self.searches += 1;
                return parse(allocator,
                    \\{"results":[{"person":{"resourceName":"people/beyond","names":[{"displayName":"Beyond first page"}],"emailAddresses":[{"value":"beyond@example.test"}]}},{"person":{"names":[{"displayName":"Missing identity"}],"emailAddresses":[{"value":"omitted@example.test"}]}}]}
                );
            }
            return error.UnexpectedContactUrl;
        }
    };
    var oracle: Oracle = .{ .list_body = body.items };
    const transport: gmail.Transport = .{ .context = &oracle, .requestFn = Oracle.request, .temporary_allocator = std.testing.allocator };
    const listed = try gmail.dispatchAuthorized(std.testing.io, a, "calendar-owner@example.test", &.{"contacts-read"}, transport, "contacts.list", try j.value(a, .{}));
    const head = j.get(listed, "contacts").?.array.items;
    try std.testing.expectEqual(@as(usize, 100), head.len);
    try std.testing.expectEqualStrings("another/contact/page+=", j.text(listed, "nextCursor"));
    for (head) |contact| for (j.get(contact, "emails").?.array.items) |email| try std.testing.expect(!std.mem.eql(u8, j.text(email, "address"), "beyond@example.test"));
    const searched = try gmail.dispatchAuthorized(std.testing.io, a, "calendar-owner@example.test", &.{"contacts-read"}, transport, "contacts.search", try j.value(a, .{ .query = "Beyond first page" }));
    const found = j.get(searched, "contacts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("beyond@example.test", j.text(j.get(found[0], "emails").?.array.items[0], "address"));
    try std.testing.expect(try j.boolean(searched, "partial", false));
    try std.testing.expectEqual(@as(u32, 1), (try warnings(a, searched)).omittedContacts);
    try std.testing.expectEqual(@as(usize, 1), oracle.lists);
    try std.testing.expectEqual(@as(usize, 1), oracle.warmups);
    try std.testing.expectEqual(@as(usize, 1), oracle.searches);
    try std.testing.expectEqual(@as(usize, 0), oracle.writes);
}
var host_body: []const u8 = mixed;
var host_result: u32 = 0;
var host_status: u32 = 200;
var host_calls: usize = 0;
var host_violation = false;
export fn now_ms() f64 {
    return 1791730000000;
}
export fn http_request(_: u32, method_ptr: usize, method_len: usize, url_ptr: usize, url_len: usize, _: usize, body_len: usize, response_ptr: usize, response_capacity: usize, metadata_ptr: usize) u32 {
    host_calls += 1;
    const method = @as([*]const u8, @ptrFromInt(method_ptr))[0..method_len];
    const url = @as([*]const u8, @ptrFromInt(url_ptr))[0..url_len];
    if (!std.mem.eql(u8, method, "GET") or body_len != 0 or !std.mem.startsWith(u8, url, "https://people.googleapis.com/v1/people")) host_violation = true;
    const bytes = if (std.mem.endsWith(u8, url, "query=")) "{}" else host_body;
    if (bytes.len > response_capacity) return 2;
    @memcpy(@as([*]u8, @ptrFromInt(response_ptr))[0..bytes.len], bytes);
    @as(*[2]u32, @ptrFromInt(metadata_ptr)).* = .{ host_status, @intCast(bytes.len) };
    return host_result;
}
fn browserSession() live.Session {
    return .{ .id = 1, .nonce = "12345678-1234-4234-8234-123456789abc", .account = "self@example.test", .client_id = "synthetic.apps.googleusercontent.com", .grant_id = "", .can_send = false, .can_contacts = true, .temporary_allocator = std.testing.allocator };
}
test "contact isolation: native and browser list/search share warnings and preserve fatal provider failures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |search| {
        const raw = try parse(a, mixed);
        var wrapped: std.ArrayList(j.Value) = .empty;
        for (j.get(raw, "connections").?.array.items) |person| try wrapped.append(a, try j.value(a, .{ .person = person }));
        const body = if (search) try std.json.Stringify.valueAlloc(a, try pageValue(a, wrapped.items, true), .{}) else mixed;
        var peer: Peer = .{ .body = body };
        host_body = body;
        host_result = 0;
        host_status = 200;
        host_calls = 0;
        host_violation = false;
        var browser = browserSession();
        const native = try gmail.dispatchAuthorized(std.testing.io, a, browser.account, &.{"contacts-read"}, peer.transport(), if (search) "contacts.search" else "contacts.list", try j.value(a, .{ .query = if (search) "peer" else "" }));
        const web = try browser.contacts(a, if (search) "peer" else "");
        try std.testing.expectEqualDeep(try warnings(a, native), try warnings(a, web));
        const native_contacts = j.get(native, "contacts").?.array.items;
        const web_contacts = j.get(web, "contacts").?.array.items;
        try std.testing.expectEqual(@as(usize, 4), native_contacts.len);
        try std.testing.expectEqual(native_contacts.len, web_contacts.len);
        for (native_contacts, web_contacts) |left, right| {
            try std.testing.expectEqualStrings(j.text(left, "resourceName"), j.text(right, "resourceName"));
            try std.testing.expectEqualStrings(j.text(left, "name"), j.text(right, "name"));
            try std.testing.expect(j.get(right, "provider") == null);
        }
        try std.testing.expectEqual(@as(usize, if (search) 2 else 1), peer.calls);
        try std.testing.expectEqual(peer.calls, host_calls);
        try std.testing.expectEqual(@as(usize, 0), peer.writes);
        try std.testing.expect(!host_violation);
    }
    for ([_]anyerror{ error.OutOfMemory, error.Canceled, error.PermissionDenied, error.InvalidGrant, error.NetworkFailure, error.ResponseTooLarge, error.InvalidProviderResponse }) |fatal| {
        var peer: Peer = .{ .fatal = fatal };
        try std.testing.expectError(fatal, gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"contacts-read"}, peer.transport(), "contacts.list", j.object(a)));
    }
    var browser = browserSession();
    for ([_]struct { result: u32, expected: anyerror }{ .{ .result = 1, .expected = error.NetworkFailure }, .{ .result = 2, .expected = error.ResponseTooLarge }, .{ .result = 3, .expected = error.NotConnected }, .{ .result = 4, .expected = error.Canceled } }) |failure| {
        host_result = failure.result;
        try std.testing.expectError(failure.expected, browser.contacts(a, ""));
    }
    host_result = 0;
    host_status = 403;
    host_body = "{}";
    try std.testing.expectError(error.PermissionDenied, browser.contacts(a, ""));
    host_status = 200;
}

test "contact isolation: browser snapshots retain row warnings and empty-page omission counts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const binding: cache.Binding = .{ .account = "self@example.test", .clientId = "synthetic.apps.googleusercontent.com", .grantId = "" };
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, binding);
    const page = try records.readPage(a, std.testing.allocator, try parse(a, mixed), .{ .retain_provider = false });
    try store.replaceContactPage(0, (try j.value(a, page.contacts)).array.items, page.contactWarnings);
    const buffer = try a.alloc(u8, cache.snapshot_limit);
    var restored = cache.Store.init(std.testing.allocator);
    defer restored.deinit();
    try restored.bind(0, binding);
    try restored.restore(0, try store.snapshot(0, buffer), true);
    try std.testing.expectEqualDeep(page.contactWarnings, restored.contactWarnings(0));
    const entries = try restored.contacts(0, a);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqual(@as(i64, 2), try j.integer(j.get(entries[1], "readWarnings").?, "omittedEmails", 0));
    try restored.replaceContactPage(0, &.{}, .{ .omittedContacts = 3 });
    try store.restore(0, try restored.snapshot(0, buffer), true);
    try std.testing.expect(store.contactsLoaded(0));
    try std.testing.expectEqual(@as(u32, 3), store.contactWarnings(0).omittedContacts);
    try std.testing.expectEqual(@as(usize, 0), (try store.contacts(0, a)).len);
    try store.dropContacts(0);
    try std.testing.expect(!store.contactWarnings(0).any());
}
