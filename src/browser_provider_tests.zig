//! Independent native acceptance tests for the browser provider's Client contract.
//! The real browser_live ABI is linked to synthetic HTTP below; no credential,
//! filesystem, GUI, or network access is involved.
const std = @import("std");
const Provider = @import("browser_provider.zig").Provider;
const cache = @import("browser_cache.zig");
const live = @import("browser_live.zig");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const A = std.mem.Allocator;
const Value = j.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const account = "ada@example.test";
const client_id = "synthetic.apps.googleusercontent.com";
const nonce = "12345678-1234-4234-8234-123456789abc";
const send_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send";
const profile_url = "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress";
const snapshot_head = "{\"version\":1,\"account\":\"ada@example.test\",\"clientId\":\"synthetic.apps.googleusercontent.com\",\"grantId\":\"\",\"updatedAt\":1791730000000,";
const snapshot_row = "{\"id\":\"old-inbox\",\"threadId\":\"thread-old\",\"subject\":\"Synthetic retained mail\",\"bodyText\":\"An independently authored cached body\",\"bodyCached\":true,\"receivedAt\":1000,\"labels\":[\"INBOX\"]}";
const fixture_snapshot = snapshot_head ++ "\"messages\":[" ++ snapshot_row ++ "],\"contacts\":[{\"resourceName\":\"people/peer\",\"name\":\"Peer\",\"emails\":[{\"address\":\"peer@example.test\"}]}],\"contactsLoaded\":true}";

const HttpStep = struct {
    method: []const u8 = "GET",
    url: []const u8,
    prefix: bool = false,
    session: u32 = 11,
    status: u32 = 200,
    result: u32 = 0,
    body: []const u8 = "{}",
};
const Host = struct {
    steps: []const HttpStep = &.{},
    cursor: usize = 0,
    requests: usize = 0,
    posts: usize = 0,
    active: usize = 0,
    peak: usize = 0,
    violation: bool = false,
    provider: ?*Provider = null,
    expected_draft: []const u8 = "",
    armed_allocator: ?*std.testing.FailingAllocator = null,
    fail_after_post: ?usize = null,
};
var host: Host = .{};

export fn now_ms() f64 {
    return 1791730000000;
}
export fn http_request(session: u32, method_ptr: usize, method_len: usize, url_ptr: usize, url_len: usize, body_ptr: usize, body_len: usize, response_ptr: usize, response_capacity: usize, metadata_ptr: usize) u32 {
    host.active += 1;
    defer host.active -= 1;
    host.peak = @max(host.peak, host.active);
    host.requests += 1;
    const method = @as([*]const u8, @ptrFromInt(method_ptr))[0..method_len];
    const url = @as([*]const u8, @ptrFromInt(url_ptr))[0..url_len];
    const is_post = std.mem.eql(u8, method, "POST");
    if (is_post) {
        host.posts += 1;
        if (body_len == 0 or body_ptr == 0) host.violation = true;
        if (host.provider) |provider| {
            const pending = provider.pendingUnknown();
            if (provider.sendStatus() != 2 or pending == null) host.violation = true else if (!std.mem.eql(u8, pending.?.draft_id, host.expected_draft)) host.violation = true;
        } else host.violation = true;
        if (host.armed_allocator) |allocator| if (host.fail_after_post) |offset| {
            allocator.fail_index = allocator.alloc_index + offset;
            allocator.resize_fail_index = allocator.resize_index;
        };
    }
    if (host.cursor >= host.steps.len) {
        host.violation = true;
        return 1;
    }
    const step = host.steps[host.cursor];
    host.cursor += 1;
    const url_matches = if (step.prefix) std.mem.startsWith(u8, url, step.url) else std.mem.eql(u8, url, step.url);
    if (session != step.session or !std.mem.eql(u8, method, step.method) or !url_matches or host.active != 1) host.violation = true;
    if (step.body.len > response_capacity) {
        host.violation = true;
        return 2;
    }
    const output = @as([*]u8, @ptrFromInt(response_ptr))[0..response_capacity];
    @memcpy(output[0..step.body.len], step.body);
    const metadata: *[2]u32 = @ptrFromInt(metadata_ptr);
    metadata.* = .{ step.status, @intCast(step.body.len) };
    return step.result;
}
fn resetHost(steps: []const HttpStep) void {
    host = .{ .steps = steps };
}
fn verifyHost() !void {
    try expect(!host.violation);
    try equal(host.steps.len, host.cursor);
    try expect(host.peak <= 1);
    try equal(@as(usize, 0), host.active);
}
fn actor(provider: *Provider, index: usize, address: []const u8, can_send: bool, contacts: bool) !void {
    provider.live_sessions[index] = live.Session{ .id = @intCast(11 + index), .nonce = nonce, .account = address, .client_id = client_id, .grant_id = "", .can_send = can_send, .can_contacts = contacts };
    provider.live_count = @max(provider.live_count, index + 1);
    try provider.cache.bind(index, .{ .account = address, .clientId = client_id, .grantId = "" });
}
fn parse(a: A, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}
fn invoke(provider: *Provider, a: A, request: anytype, cached: bool) !Value {
    const raw = try std.json.Stringify.valueAlloc(a, request, .{});
    const result = if (cached) try provider.client().callCached(a, raw) else try provider.client().call(a, raw);
    return parse(a, result);
}
fn data(value: Value) !Value {
    try expect(try j.boolean(value, "ok", false));
    try equal(@as(i64, 1), try j.integer(value, "version", 0));
    return j.get(value, "data") orelse error.MissingData;
}
fn failure(value: Value, code: []const u8) !void {
    try expect(!try j.boolean(value, "ok", true));
    try strings(code, j.text(j.get(value, "error") orelse return error.MissingError, "code"));
}
fn messages(value: Value) ![]const Value {
    const result = j.get(try data(value), "messages") orelse return error.MissingMessages;
    return if (result == .array) result.array.items else error.InvalidMessages;
}
fn create(provider: *Provider, a: A, body: []const u8) ![]const u8 {
    return j.required(try data(try invoke(provider, a, .{ .id = "create", .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .subject = "Synthetic acceptance", .bodyText = body } }, false)), "id");
}
fn send(provider: *Provider, a: A, draft_id: []const u8, operation_id: []const u8) !Value {
    return invoke(provider, a, .{ .id = "send", .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = operation_id }, false);
}
fn acknowledgeReceipt(provider: *Provider, a: A, draft_id: []const u8, operation_id: []const u8, accepted: bool) !void {
    const request = try std.json.Stringify.valueAlloc(a, .{ .id = "send", .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = operation_id }, .{});
    const client = provider.client();
    const callback = client.sendReceiptFn orelse return error.MissingSendReceiptConsumer;
    callback(client.ctx, request, accepted);
}
fn draftList(provider: *Provider, a: A) ![]const Value {
    const result = try data(try invoke(provider, a, .{ .cmd = "draft.list", .account = account }, false));
    return j.get(result, "drafts").?.array.items;
}
fn operations(provider: *Provider, a: A) ![]const Value {
    const value = try data(try invoke(provider, a, .{ .cmd = "operation.list", .account = account }, false));
    return j.get(value, "operations").?.array.items;
}
fn outcome(value: Value, expected: []const u8) !void {
    try strings(expected, j.text(try data(value), "outcome"));
}
fn snapshot(provider: *Provider, a: A, index: usize) ![]const u8 {
    const buffer = try a.alloc(u8, cache.snapshot_limit);
    defer a.free(buffer);
    return a.dupe(u8, try provider.cacheSnapshot(index, buffer));
}
fn connection(a: A, address: []const u8) ![]const u8 {
    const readonly = "https://www.googleapis.com/auth/gmail.readonly";
    return std.json.Stringify.valueAlloc(a, .{ .session = @as(u32, 11), .nonce = nonce, .account = address, .clientId = client_id, .capabilities = [_][]const u8{"mail-read"}, .scopes = [_][]const u8{readonly}, .actualScopes = [_][]const u8{readonly} }, .{});
}
fn expectPage(values: []const Value, start: usize, count: usize) !void {
    try equal(count, values.len);
    for (values, 0..) |value, offset| {
        var buffer: [32]u8 = undefined;
        try strings(try std.fmt.bufPrint(&buffer, "mail-{d}", .{start + offset}), j.text(value, "id"));
    }
}
fn seedInventory(provider: *Provider, a: A, index: usize, count: usize) !void {
    const rows = try a.alloc(Value, count);
    for (rows, 0..) |*row, rank| row.* = try j.value(a, .{ .id = try std.fmt.allocPrint(a, "mail-{d}", .{rank}), .threadId = try std.fmt.allocPrint(a, "thread-{d}", .{rank}), .subject = "Synthetic retained row", .receivedAt = @as(i64, @intCast(100000 - rank)), .labels = [_][]const u8{"INBOX"} });
    const raw = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .account = provider.live_sessions[index].account, .clientId = client_id, .grantId = "", .updatedAt = @as(i64, 1791730000000), .messages = rows, .contacts = [_]Value{}, .contactsLoaded = false }, .{});
    try provider.cache.restore(index, raw, false);
}

test "browser provider: cached mutations cannot change drafts cache or a successful send receipt" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, true);
    try provider.cache.restore(0, fixture_snapshot, true);
    const draft_id = try create(&provider, a, "Literal body");
    const active_draft_id = try create(&provider, a, "Unsent literal body");
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\",\"threadId\":\"thread123\"}" }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    try outcome(try send(&provider, a, draft_id, "cached-guard"), "applied");
    try equal(@as(u32, 2), provider.sendStatus());
    try acknowledgeReceipt(&provider, a, draft_id, "cached-guard", true);
    try verifyHost();
    const before = try snapshot(&provider, a, 0);
    const old_operations = try std.json.Stringify.valueAlloc(a, try operations(&provider, a), .{});
    const before_revision = provider.cacheRevision(0);
    resetHost(&.{});
    for ([_][]const u8{ "draft.create", "draft.update", "draft.recovery-save", "draft.discard", "draft.send", "mail.reply", "mail.forward", "mail.refresh", "cache.clear", "contacts.upsert" }) |cmd| {
        const request = .{ .cmd = cmd, .account = account, .draftId = if (std.mem.eql(u8, cmd, "draft.send")) draft_id else active_draft_id, .operationId = "cached-guard", .messageId = "old-inbox", .draft = .{ .to = "peer@example.test", .subject = "Replacement", .bodyText = "Mutation must not occur" } };
        try failure(try invoke(&provider, a, request, true), "CacheUnsupported");
    }
    try failure(try invoke(&provider, a, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "cached-guard", .cacheOnly = true }, false), "CacheUnsupported");
    try equal(@as(u32, 1), provider.sendStatus());
    try equal(before_revision, provider.cacheRevision(0));
    try strings(before, try snapshot(&provider, a, 0));
    try strings(old_operations, try std.json.Stringify.valueAlloc(a, try operations(&provider, a), .{}));
    try strings("Unsent literal body", j.text(try data(try invoke(&provider, a, .{ .cmd = "draft.read", .account = account, .draftId = active_draft_id }, false)), "bodyText"));
    try failure(try invoke(&provider, a, .{ .cmd = "draft.read", .account = account, .draftId = draft_id }, false), "DraftAlreadySent");
    try equal(@as(usize, 1), (try draftList(&provider, a)).len);
    try verifyHost();
}

test "browser provider: verified profile precedes snapshot restore and actor bindings cannot be crossed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const metadata = try connection(a, account);
    {
        var provider = Provider.init(std.testing.allocator);
        defer provider.deinit();
        resetHost(&.{.{ .url = profile_url, .body = "{\"emailAddress\":\"different@example.test\"}" }});
        try std.testing.expectError(error.WrongAccount, provider.connect(metadata, fixture_snapshot));
        try equal(@as(usize, 0), provider.accountCount());
        try expect(!provider.cache.valid(0));
        try verifyHost();
    }
    for ([_][]const u8{ "account", "clientId", "grantId", "matching" }) |changed| {
        var provider = Provider.init(std.testing.allocator);
        defer provider.deinit();
        var fixture = try parse(a, fixture_snapshot);
        if (!std.mem.eql(u8, changed, "matching")) try fixture.object.put(a, changed, .{ .string = "different-binding" });
        const uploaded = try std.json.Stringify.valueAlloc(a, fixture, .{});
        resetHost(&.{.{ .url = profile_url, .body = "{\"emailAddress\":\"ada@example.test\"}" }});
        try equal(@as(usize, 0), try provider.connect(metadata, uploaded));
        try verifyHost();
        resetHost(&.{});
        const result = try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true);
        if (std.mem.eql(u8, changed, "matching")) {
            const rows = try messages(result);
            try equal(@as(usize, 1), rows.len);
            try strings("old-inbox", j.text(rows[0], "id"));
            try failure(try invoke(&provider, a, .{ .cmd = "contacts.list", .account = account }, true), "PermissionDenied");
            try expect(!provider.cache.contactsLoaded(0));
        } else try failure(result, "CacheMiss");
        try failure(try invoke(&provider, a, .{ .cmd = "mail.list", .account = "different@example.test" }, true), "UnknownAccount");
        try verifyHost();
    }
}

test "browser provider: narrowing contacts drops old People rows and keeps mail account isolated" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, true);
    try actor(&provider, 1, "second@example.test", false, false);
    try provider.cache.restore(0, fixture_snapshot, true);
    resetHost(&.{});
    try equal(@as(usize, 1), j.get(try data(try invoke(&provider, a, .{ .cmd = "contacts.list", .account = account }, true)), "contacts").?.array.items.len);
    try provider.restrictContacts(0, false);
    try failure(try invoke(&provider, a, .{ .cmd = "contacts.list", .account = account }, true), "PermissionDenied");
    try expect(!provider.cache.contactsLoaded(0));
    const exported = try parse(a, try snapshot(&provider, a, 0));
    try equal(@as(usize, 0), j.get(exported, "contacts").?.array.items.len);
    try equal(@as(usize, 1), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true))).len);
    try failure(try invoke(&provider, a, .{ .cmd = "mail.read", .account = "second@example.test", .messageId = "old-inbox" }, true), "CacheMiss");
    try verifyHost();
}

test "browser provider: refreshed empty Inbox stays empty after navigation while historical read survives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    try provider.cache.restore(0, fixture_snapshot, false);
    const list_prefix = "https://gmail.googleapis.com/gmail/v1/users/me/messages?";
    const empty: HttpStep = .{ .url = list_prefix, .prefix = true, .body = "{\"messages\":[]}" };
    const steps: [10]HttpStep = @splat(empty);
    resetHost(&steps);
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    try equal(@as(usize, 0), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true))).len);
    for (0..9) |index| _ = try data(try invoke(&provider, a, .{ .cmd = "mail.search", .account = account, .query = try std.fmt.allocPrint(a, "subject:absent{d}", .{index}) }, false));
    try equal(@as(usize, 0), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true))).len);
    try strings("An independently authored cached body", j.text(try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "old-inbox" }, true)), "bodyText"));
    const persisted = try snapshot(&provider, a, 0);
    var reopened = Provider.init(std.testing.allocator);
    defer reopened.deinit();
    try actor(&reopened, 0, account, false, false);
    try reopened.cache.restore(0, persisted, false);
    try equal(@as(usize, 0), (try messages(try invoke(&reopened, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true))).len);
    try strings("An independently authored cached body", j.text(try data(try invoke(&reopened, a, .{ .cmd = "mail.read", .account = account, .messageId = "old-inbox" }, true)), "bodyText"));
    try verifyHost();
}

test "browser provider: an incomplete live head preserves navigation through older retained pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    try seedInventory(&provider, a, 0, 300);
    resetHost(&.{
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[{\"id\":\"mail-0\"}],\"nextPageToken\":\"server-has-more\"}" },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/mail-0?", .prefix = true, .body = "{\"id\":\"mail-0\",\"threadId\":\"thread-0\",\"labelIds\":[\"INBOX\"],\"internalDate\":\"100000\",\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Subject\",\"value\":\"Fresh partial head\"}]}}" },
    });
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    const head = try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true);
    try expectPage(try messages(head), 0, 30);
    try expect(try j.boolean(try data(head), "hasMoreCachedAfter", false));
    try expectPage(try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .afterMessageId = "mail-29" }, true)), 30, 30);
    try verifyHost();
}

test "browser provider: retained inventory is navigated in 30-row pages with scoped cursors and exact boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    try actor(&provider, 1, "second@example.test", false, false);
    try seedInventory(&provider, a, 0, 300);
    try seedInventory(&provider, a, 1, 300);
    resetHost(&.{});
    var cursor: []const u8 = "";
    var first_next: []const u8 = "";
    for (0..10) |page| {
        const response = try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .cursor = cursor }, true);
        try expectPage(try messages(response), page * 30, 30);
        const page_data = try data(response);
        try equal(page > 0, try j.boolean(page_data, "hasMoreCachedBefore", false));
        try equal(page < 9, try j.boolean(page_data, "hasMoreCachedAfter", false));
        cursor = j.text(page_data, "nextCursor");
        if (page == 0) first_next = cursor;
    }
    try strings("", cursor);
    try expectPage(try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .anchorMessageId = "mail-143" }, true)), 120, 30);
    try expectPage(try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .beforeMessageId = "mail-30" }, true)), 0, 30);
    try expectPage(try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .afterMessageId = "mail-269" }, true)), 270, 30);
    try expectPage(try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .afterMessageId = "mail-299" }, true)), 300, 0);
    try expectPage(try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .beforeMessageId = "mail-0" }, true)), 0, 0);
    try failure(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .beforeMessageId = "gone" }, true), "CacheBoundaryGone");
    try failure(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .beforeMessageId = "mail-1", .afterMessageId = "mail-2" }, true), "InvalidWindowBoundary");
    try failure(try invoke(&provider, a, .{ .cmd = "mail.list", .account = "second@example.test", .label = "INBOX", .cursor = first_next }, true), "InvalidCursor");
    try failure(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .query = "subject:Synthetic", .cursor = first_next }, true), "InvalidCursor");
    try provider.cache.saveRead(0, .{ .id = "mail-143", .threadId = "thread-143", .subject = "Changed", .bodyText = "Fetched body", .labels = &.{"INBOX"} });
    try failure(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .cursor = first_next }, true), "InvalidCursor");
    try equal(@as(i64, 300), try j.integer(try data(try invoke(&provider, a, .{ .cmd = "cache.stats", .account = account }, true)), "metadataEntries", 0));
    try verifyHost();
}

test "browser provider: unknown send pre-records its fence and blocks replay copied drafts updates and discard" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    try actor(&provider, 1, "second@example.test", true, false);
    const draft_id = try create(&provider, a, "Unique original body");
    const copied_id = try create(&provider, a, "Unique original body");
    resetHost(&.{.{ .method = "POST", .url = send_url, .result = 1 }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    const receipt = try send(&provider, a, draft_id, "uncertain-first");
    try outcome(receipt, "unknown");
    try acknowledgeReceipt(&provider, a, draft_id, "uncertain-first", true);
    try equal(@as(u32, 2), provider.sendStatus());
    try equal(@as(usize, 2), (try draftList(&provider, a)).len);
    try equal(@as(usize, 1), host.posts);
    try outcome(try send(&provider, a, draft_id, "uncertain-first"), "unknown");
    try outcome(try send(&provider, a, draft_id, "new-attempt"), "unknown");
    const copied = try send(&provider, a, copied_id, "copied-attempt");
    try outcome(copied, "unknown");
    try strings(draft_id, j.text(try data(copied), "draftId"));
    for ([_][]const u8{ "draft.update", "draft.recovery-save", "draft.discard" }) |cmd| try failure(try invoke(&provider, a, .{ .cmd = cmd, .account = account, .draftId = draft_id, .draft = .{ .to = "peer@example.test", .subject = "Changed", .bodyText = "Changed", .recoveryFields = [_][]const u8{ "peer@example.test", "", "", "Changed", "Changed" } } }, false), "UnknownOutcome");
    try equal(@as(usize, 1), (try operations(&provider, a)).len);
    try std.testing.expectError(error.OperationNotFound, provider.acknowledgeUnknown(1, draft_id));
    try std.testing.expectError(error.OperationNotFound, provider.acknowledgeUnknown(0, copied_id));
    try expect(provider.pendingUnknown() != null);
    try outcome(try send(&provider, a, copied_id, "still-blocked"), "unknown");
    try equal(@as(usize, 1), host.posts);
    try verifyHost();
    try provider.acknowledgeUnknown(0, draft_id);
    try expect(provider.pendingUnknown() == null);
    try equal(@as(u32, 0), provider.sendStatus());
    try strings("acknowledged", j.text((try operations(&provider, a))[0], "outcome"));
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = draft_id, .draft = .{ .to = "peer@example.test", .subject = "Reviewed retry", .bodyText = "Explicitly revised" } }, false));
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"accepted123\"}" }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    try outcome(try send(&provider, a, draft_id, "reviewed-new-attempt"), "applied");
    try equal(@as(u32, 2), provider.sendStatus());
    try acknowledgeReceipt(&provider, a, draft_id, "reviewed-new-attempt", true);
    try equal(@as(u32, 1), provider.sendStatus());
    try verifyHost();
}

test "browser provider: an operation ID conflict leaves its applied receipt intact without another POST" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const draft_id = try create(&provider, a, "Original");
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\"}" }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    try outcome(try send(&provider, a, draft_id, "operation-collision"), "applied");
    try acknowledgeReceipt(&provider, a, draft_id, "operation-collision", true);
    try outcome(try send(&provider, a, draft_id, "operation-collision"), "applied");
    try acknowledgeReceipt(&provider, a, draft_id, "operation-collision", true);
    const changed_draft = try create(&provider, a, "Different content");
    try failure(try send(&provider, a, changed_draft, "operation-collision"), "OperationConflict");
    try acknowledgeReceipt(&provider, a, changed_draft, "operation-collision", false);
    try equal(@as(usize, 1), host.posts);
    try strings("applied", j.text((try operations(&provider, a))[0], "outcome"));
    try expect(provider.pendingUnknown() == null);
    try verifyHost();
}

test "browser provider: cancellation proven before submission leaves the draft editable without reconciliation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const draft_id = try create(&provider, a, "Canceled during the browser grace interval");
    // Host result 4 is reserved for LocalCanceled before provider submission;
    // unlike a failed in-flight request, there is no delivery to reconcile.
    resetHost(&.{.{ .method = "POST", .url = send_url, .result = 4 }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    try outcome(try send(&provider, a, draft_id, "canceled-before-submit"), "rejected");
    try equal(@as(u32, 2), provider.sendStatus());
    try acknowledgeReceipt(&provider, a, draft_id, "canceled-before-submit", true);
    try equal(@as(u32, 3), provider.sendStatus());
    try expect(provider.pendingUnknown() == null);
    try equal(@as(usize, 1), (try draftList(&provider, a)).len);
    try outcome(try send(&provider, a, draft_id, "canceled-before-submit"), "rejected");
    try acknowledgeReceipt(&provider, a, draft_id, "canceled-before-submit", true);
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = draft_id, .draft = .{ .to = "peer@example.test", .subject = "Edited after cancel", .bodyText = "Local revision" } }, false));
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.discard", .account = account, .draftId = draft_id }, false));
    try verifyHost();
}

test "browser provider: receipt consumer failure keeps applied rejected and unknown drafts active and fenced" {
    const replies = [_]HttpStep{
        .{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\"}" },
        .{ .method = "POST", .url = send_url, .status = 403, .body = "{\"error\":{\"message\":\"Synthetic denial\"}}" },
        .{ .method = "POST", .url = send_url, .result = 1 },
    };
    for (replies) |reply| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var provider_alloc: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
        var provider = Provider.init(provider_alloc.allocator());
        defer provider.deinit();
        try actor(&provider, 0, account, true, false);
        const draft_id = try create(&provider, a, "Consumer could not retain its receipt");
        resetHost(&.{reply});
        host.provider = &provider;
        host.expected_draft = draft_id;
        const request = try std.json.Stringify.valueAlloc(a, .{ .id = "send", .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "consumer-failed" }, .{});
        const response = try provider.client().call(a, request);
        try equal(@as(u32, 2), provider.sendStatus());

        var consumer_alloc: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, std.json.parseFromSlice(Value, consumer_alloc.allocator(), response, .{ .allocate = .alloc_always }));
        try expect(consumer_alloc.has_induced_failure);
        // Reporting the consumer's failure must itself work without allocation.
        // The provider may not clear its browser fence just because its own
        // earlier serialization succeeded.
        provider_alloc.fail_index = provider_alloc.alloc_index;
        provider_alloc.resize_fail_index = provider_alloc.resize_index;
        const client = provider.client();
        const callback = client.sendReceiptFn orelse return error.MissingSendReceiptConsumer;
        callback(client.ctx, request, false);
        provider_alloc.fail_index = std.math.maxInt(usize);
        provider_alloc.resize_fail_index = std.math.maxInt(usize);

        try equal(@as(usize, 1), (try draftList(&provider, a)).len);
        try strings("unknown", j.text((try operations(&provider, a))[0], "outcome"));
        try verifyFenced(&provider, a, draft_id, "consumer-failed");
        try verifyHost();
    }
}

test "browser provider: only the matching consumer acknowledgement retires an applied draft" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    try actor(&provider, 1, "second@example.test", true, false);
    const draft_id = try create(&provider, a, "Pin consumer acknowledgement to its receipt");
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\"}" }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    try outcome(try send(&provider, a, draft_id, "receipt-identity"), "applied");
    try equal(@as(u32, 2), provider.sendStatus());
    const unconsumed_retry = try send(&provider, a, draft_id, "retry-before-consumption");
    try strings("receipt-identity", j.text(try data(unconsumed_retry), "id"));
    try equal(@as(usize, 1), host.posts);
    try failure(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = draft_id, .draft = .{ .to = "peer@example.test", .bodyText = "Changed before confirmation" } }, false), "UnknownOutcome");
    try failure(try invoke(&provider, a, .{ .cmd = "draft.discard", .account = account, .draftId = draft_id }, false), "UnknownOutcome");
    const client = provider.client();
    const callback = client.sendReceiptFn orelse return error.MissingSendReceiptConsumer;
    for ([_][]const u8{ "account", "draftId", "operationId" }) |changed| {
        var wrong = try j.value(a, .{ .id = "send", .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "receipt-identity" });
        try wrong.object.put(a, changed, .{ .string = if (std.mem.eql(u8, changed, "account")) "second@example.test" else "unrelated-identity" });
        callback(client.ctx, try std.json.Stringify.valueAlloc(a, wrong, .{}), true);
        try equal(@as(u32, 2), provider.sendStatus());
        try equal(@as(usize, 1), (try draftList(&provider, a)).len);
    }
    try acknowledgeReceipt(&provider, a, draft_id, "receipt-identity", true);
    try equal(@as(u32, 1), provider.sendStatus());
    try equal(@as(usize, 0), (try draftList(&provider, a)).len);
    try expect(provider.pendingUnknown() == null);
    try outcome(try send(&provider, a, draft_id, "receipt-identity"), "applied");
    try acknowledgeReceipt(&provider, a, draft_id, "receipt-identity", true);
    try equal(@as(usize, 0), (try draftList(&provider, a)).len);
    try equal(@as(usize, 1), host.posts);
    // A failed receipt replay must restore any draft that is now uncertain;
    // its retired slot must not become available for an unrelated new draft.
    try outcome(try send(&provider, a, draft_id, "receipt-identity"), "applied");
    try acknowledgeReceipt(&provider, a, draft_id, "receipt-identity", false);
    const preserved = try draftList(&provider, a);
    try equal(@as(usize, 1), preserved.len);
    try strings(draft_id, j.text(preserved[0], "id"));
    try verifyFenced(&provider, a, draft_id, "receipt-identity");
    try verifyHost();
}

test "browser provider: twelve confirmed sends release the eight active draft slots" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const replies: [12]HttpStep = @splat(.{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\"}" });
    resetHost(&replies);
    host.provider = &provider;
    for (0..12) |index| {
        try equal(@as(usize, 0), (try draftList(&provider, a)).len);
        const draft_id = try create(&provider, a, try std.fmt.allocPrint(a, "Independently confirmed message {d}", .{index}));
        const operation_id = try std.fmt.allocPrint(a, "confirmed-operation-{d}", .{index});
        host.expected_draft = draft_id;
        try outcome(try send(&provider, a, draft_id, operation_id), "applied");
        try equal(@as(u32, 2), provider.sendStatus());
        try equal(@as(usize, 1), (try draftList(&provider, a)).len);
        try acknowledgeReceipt(&provider, a, draft_id, operation_id, true);
        try equal(@as(u32, 1), provider.sendStatus());
        try equal(@as(usize, 0), (try draftList(&provider, a)).len);
        try expect(provider.pendingUnknown() == null);
    }
    try equal(@as(usize, 12), host.posts);
    const receipts = try operations(&provider, a);
    try equal(@as(usize, 12), receipts.len);
    for (receipts) |receipt| try strings("applied", j.text(receipt, "outcome"));
    try verifyHost();
}

fn verifyFenced(provider: *Provider, a: A, draft_id: []const u8, operation_id: []const u8) !void {
    try equal(@as(u32, 2), provider.sendStatus());
    const pending = provider.pendingUnknown() orelse return error.MissingUncertainFence;
    try strings(draft_id, pending.draft_id);
    const count = host.posts;
    try outcome(try send(provider, a, draft_id, operation_id), "unknown");
    try outcome(try send(provider, a, draft_id, "automatic-new-attempt"), "unknown");
    try equal(count, host.posts);
    try failure(try invoke(provider, a, .{ .cmd = "draft.discard", .account = account, .draftId = draft_id }, false), "UnknownOutcome");
}

test "browser provider: lost outer success rejected or unknown envelopes remain uncertain and cannot resend" {
    const replies = [_]HttpStep{
        .{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\"}" },
        .{ .method = "POST", .url = send_url, .status = 403, .body = "{\"error\":{\"message\":\"Synthetic denial\"}}" },
        .{ .method = "POST", .url = send_url, .result = 1 },
    };
    for (replies) |reply| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var provider = Provider.init(std.testing.allocator);
        defer provider.deinit();
        try actor(&provider, 0, account, true, false);
        const draft_id = try create(&provider, a, "Synthetic outcome serialization");
        resetHost(&.{reply});
        host.provider = &provider;
        host.expected_draft = draft_id;
        const raw = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "output-failure" }, .{});
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.UnknownOutcome, provider.client().call(failing.allocator(), raw));
        try expect(failing.has_induced_failure);
        try equal(@as(usize, 1), host.posts);
        try verifyFenced(&provider, a, draft_id, "output-failure");
        try verifyHost();
    }
}

test "browser provider: allocator failure after synthetic POST retains the uncertain fence" {
    var input: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer input.deinit();
    const a = input.allocator();
    // A legal large provider extension exercises post-write JSON allocation,
    // independently of how the provider currently packs its scratch arena.
    const padding = try a.alloc(u8, 2 * 1024 * 1024);
    @memset(padding, 'p');
    const reply = try std.json.Stringify.valueAlloc(a, .{ .id = "sent123", .providerExtension = padding }, .{});
    var observed_post_failure = false;
    var completed = false;
    for (0..64) |offset| {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
        var provider = Provider.init(failing.allocator());
        defer provider.deinit();
        try actor(&provider, 0, account, true, false);
        const draft_id = try create(&provider, a, "Post-write allocation failure");
        resetHost(&.{.{ .method = "POST", .url = send_url, .body = reply }});
        host.provider = &provider;
        host.expected_draft = draft_id;
        host.armed_allocator = &failing;
        host.fail_after_post = offset;
        const raw = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "after-post" }, .{});
        const response = provider.client().call(a, raw);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        host.armed_allocator = null;
        try equal(@as(usize, 1), host.posts);
        if (induced) {
            observed_post_failure = true;
            if (response) |bytes| {
                const value = try parse(a, bytes);
                if (try j.boolean(value, "ok", false)) try outcome(value, "unknown") else try failure(value, "UnknownOutcome");
            } else |err| try equal(error.UnknownOutcome, err);
            try verifyFenced(&provider, a, draft_id, "after-post");
        } else {
            try outcome(try parse(a, try response), "applied");
            completed = true;
        }
        try verifyHost();
        if (completed) break;
    }
    try expect(observed_post_failure);
    try expect(completed);
}
