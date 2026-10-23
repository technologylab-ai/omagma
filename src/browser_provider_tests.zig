//! Independent native acceptance tests for the browser provider's Client contract.
//! The real browser_live ABI is linked to synthetic HTTP below; no credential,
//! filesystem, GUI, or network access is involved.
const std = @import("std");
const Provider = @import("browser_provider.zig").Provider;
const cache = @import("browser_cache.zig");
const live = @import("browser_live.zig");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const decoder_policy = @import("terminal/decoder_policy.zig");
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
const aliases_url = "https://gmail.googleapis.com/gmail/v1/users/me/settings/sendAs?fields=sendAs(sendAsEmail,displayName,signature,isPrimary,isDefault,verificationStatus)";
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
    capture_body: ?[]u8 = null,
    captured_bytes: usize = 0,
    draft_receipt_failure: ?*?anyerror = null,
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
        if (host.draft_receipt_failure) |failure_ptr| failure_ptr.* = error.BrowserDraftStorageConflict;
        host.posts += 1;
        if (body_len == 0 or body_ptr == 0) host.violation = true;
        if (host.capture_body) |buffer| {
            if (body_len > buffer.len) host.violation = true else {
                @memcpy(buffer[0..body_len], @as([*]const u8, @ptrFromInt(body_ptr))[0..body_len]);
                host.captured_bytes = body_len;
            }
        }
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

test "browser provider: native Calendar grants connect without advertising unsupported operations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = @import("terminal/auth.zig");
    const scopes = try auth.scopesFor(a, &auth.allowed_capabilities);
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .session = @as(u32, 11), .nonce = nonce, .account = account, .clientId = client_id,
        .grantId = &auth.grantIdentity(scopes), .capabilities = auth.allowed_capabilities,
        .scopes = scopes, .actualScopes = scopes,
    }, .{});
    resetHost(&.{.{ .url = profile_url, .body = "{\"emailAddress\":\"ada@example.test\"}" }});
    var session = try live.connect(a, metadata);
    try expect(session.can_send and session.can_modify and session.can_contacts);
    const supported = [_][]const u8{ "mail-read", "mail-send", "mail-modify", "contacts-read" };
    try equal(supported.len, session.capabilities().len);
    for (supported, session.capabilities()) |expected, actual| try strings(expected, actual);
    const transport = session.transport();
    try std.testing.expectError(error.InvalidHost, transport.requestFn(transport.context, a, .GET, "https://www.googleapis.com/calendar/v3/users/me/calendarList", null));
    try std.testing.expectError(error.PermissionDenied, transport.requestFn(transport.context, a, .POST, "https://gmail.googleapis.com/gmail/v1/users/me/drafts", null));
    try verifyHost();
    try equal(@as(usize, 1), host.requests);
}

test "browser provider: native compose scope preserves explicitly granted mail sending" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = @import("terminal/auth.zig");
    const caps = [_][]const u8{ "mail-read", "mail-drafts", "mail-send", "calendar-read" };
    const scopes = try auth.scopesFor(a, &caps);
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .session = @as(u32, 11), .nonce = nonce, .account = account, .clientId = client_id,
        .grantId = &auth.grantIdentity(scopes), .capabilities = caps,
        .scopes = scopes, .actualScopes = scopes,
    }, .{});
    resetHost(&.{.{ .url = profile_url, .body = "{\"emailAddress\":\"ada@example.test\"}" }});
    const session = try live.connect(a, metadata);
    try expect(session.can_send and !session.can_modify and !session.can_contacts);
    try equal(@as(usize, 2), session.capabilities().len);
    try strings("mail-send", session.capabilities()[1]);
    try verifyHost();
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
    try equal(@as(u32, 3), provider.sendStatus());
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

const source_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/source?format=full";
const source_raw_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/source?format=raw&fields=id,raw";
const source_image_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/source/attachments/image";
const source_style_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/source/attachments/style";
const source_file_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/source/attachments/file";
const source_body = "<!-- exact source --><div class=\"source\"><img src=\"cid:source-image\"><img src=\"https://example.test/source.css\"><p>Received source</p></div>";
const source_html = "<!DOCTYPE html><html><head><style>.source{color:#123456}</style></head><body>" ++ source_body ++ "</body></html>";
const source_aliases = "{\"sendAs\":[{\"sendAsEmail\":\"ada@example.test\",\"isPrimary\":true},{\"sendAsEmail\":\"alias@example.test\",\"verificationStatus\":\"accepted\"},{\"sendAsEmail\":\"unverified@example.test\",\"verificationStatus\":\"pending\"}]}";
const image_response = "{\"size\":3,\"data\":\"AAH_\"}";
const style_response = "{\"size\":3,\"data\":\"YWJj\"}";
const file_response = "{\"size\":3,\"data\":\"AP8N\"}";

fn base64(a: A, bytes: []const u8) ![]const u8 {
    const buffer = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    return std.base64.url_safe_no_pad.Encoder.encode(buffer, bytes);
}
fn sourceMessage(a: A, id: []const u8, image_id: []const u8) ![]const u8 {
    // Provider-shaped input is authored independently of the Gmail decoder.
    return std.json.Stringify.valueAlloc(a, .{
        .id = id,
        .threadId = "source-thread",
        .internalDate = "1791799200000",
        .labelIds = [_][]const u8{"INBOX"},
        .payload = .{
            .mimeType = "multipart/mixed",
            .headers = [_]struct { name: []const u8, value: []const u8 }{
                .{ .name = "From", .value = "Sender <sender@example.test>" },
                .{ .name = "Reply-To", .value = "Reply <reply@example.test>" },
                .{ .name = "To", .value = "Ada <ada@example.test>, Alias <alias@example.test>, Peer <peer@example.test>" },
                .{ .name = "Cc", .value = "ADA@EXAMPLE.TEST, PEER@example.test, Copy <copy@example.test>" },
                .{ .name = "Subject", .value = "Source conversation" },
                .{ .name = "Date", .value = "Mon, 12 Oct 2026 10:00:00 +0000" },
                .{ .name = "Message-ID", .value = "<source@example.test>" },
                .{ .name = "References", .value = "<earlier@example.test>" },
            },
            .parts = .{
                .{ .mimeType = "text/html", .body = .{ .size = source_html.len, .data = try base64(a, source_html) } },
                .{ .mimeType = "image/png", .filename = "source.png", .headers = .{ .{ .name = "Content-ID", .value = "<source-image>" }, .{ .name = "Content-Disposition", .value = "inline" } }, .body = .{ .size = 3, .attachmentId = image_id } },
                .{ .mimeType = "text/css", .filename = "source.css", .headers = .{ .{ .name = "Content-Location", .value = "https://example.test/source.css" }, .{ .name = "Content-Disposition", .value = "inline" } }, .body = .{ .size = 3, .attachmentId = "style" } },
                .{ .mimeType = "application/octet-stream", .filename = "source.bin", .headers = .{.{ .name = "Content-Disposition", .value = "attachment" }}, .body = .{ .size = 3, .attachmentId = "file" } },
            },
        },
    }, .{});
}
fn original(value: Value) !Value {
    const captured = j.get(value, "original") orelse return error.MissingOriginal;
    try strings(source_html, j.text(captured, "bodyHtml"));
    const resources = j.get(captured, "resources") orelse return error.MissingResources;
    try equal(@as(usize, 2), resources.array.items.len);
    try strings("AAH_", j.text(resources.array.items[0], "data"));
    try strings("YWJj", j.text(resources.array.items[1], "data"));
    try strings("https://example.test/source.css", j.text(resources.array.items[1], "contentLocation"));
    return captured;
}
fn decodeWirePart(a: A, wire: []const u8, header: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, wire, header) orelse return error.MissingWirePart;
    const header_end = std.mem.indexOfPos(u8, wire, start, "\r\n\r\n") orelse return error.InvalidWirePart;
    const end = std.mem.indexOfPos(u8, wire, header_end + 4, "\r\n--") orelse return error.InvalidWirePart;
    const encoded = wire[header_end + 4 .. end];
    if (std.mem.indexOf(u8, wire[start..header_end], "quoted-printable") != null) {
        var decoded: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < encoded.len) {
            if (encoded[index] == '=') {
                if (index + 2 >= encoded.len) return error.InvalidQuotedPrintable;
                if (!(encoded[index + 1] == '\r' and encoded[index + 2] == '\n')) try decoded.append(a, try std.fmt.parseInt(u8, encoded[index + 1 ..][0..2], 16));
                index += 3;
            } else {
                try decoded.append(a, encoded[index]);
                index += 1;
            }
        }
        return decoded.toOwnedSlice(a);
    }
    if (std.mem.indexOf(u8, wire[start..header_end], "base64") != null) {
        var compact: std.ArrayList(u8) = .empty;
        for (encoded) |byte| if (!std.ascii.isWhitespace(byte)) try compact.append(a, byte);
        const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(compact.items));
        try std.base64.standard.Decoder.decode(bytes, compact.items);
        return bytes;
    }
    return a.dupe(u8, encoded);
}

test "browser provider: formatted reply all uses fresh source verified aliases and frozen recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    try actor(&provider, 1, "second@example.test", true, false);
    try provider.cache.saveRead(0, .{ .id = "source", .threadId = "stale-thread", .bodyText = "Stale cached source", .bodyCached = true });
    const full = try sourceMessage(a, "source", "image");
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .body = full },
        .{ .url = aliases_url, .body = source_aliases },
        .{ .url = source_image_url, .body = image_response },
        .{ .url = source_style_url, .body = style_response },
    });
    const draft = try data(try invoke(&provider, a, .{ .cmd = "mail.reply", .account = account, .messageId = "source", .preserveFormatting = true, .all = true }, false));
    const id = try j.required(draft, "id");
    const frozen = try std.json.Stringify.valueAlloc(a, try original(draft), .{});
    const to = j.get(draft, "to").?.array.items;
    const cc = j.get(draft, "cc").?.array.items;
    try equal(@as(usize, 1), to.len);
    try strings("reply@example.test", j.text(to[0], "address"));
    try equal(@as(usize, 3), cc.len);
    try strings("peer@example.test", j.text(cc[0], "address"));
    try strings("PEER@example.test", j.text(cc[1], "address"));
    try strings("copy@example.test", j.text(cc[2], "address"));
    try strings("source-thread", j.text(draft, "threadId"));
    try strings("<source@example.test>", j.text(draft, "inReplyTo"));
    try strings("<earlier@example.test> <source@example.test>", j.text(draft, "references"));
    try verifyHost();
    resetHost(&.{});
    const changed = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .to = "reply@example.test", .subject = "My note", .bodyText = "Edited note" } }, false));
    try strings(frozen, try std.json.Stringify.valueAlloc(a, try original(changed), .{}));
    const recovered = try data(try invoke(&provider, a, .{ .cmd = "draft.recovery-save", .account = account, .draftId = id, .draft = .{ .recoveryFields = [_][]const u8{ "unfinished@", "", "", "Unfinished subject", "Unfinished note" } } }, false));
    try strings(frozen, try std.json.Stringify.valueAlloc(a, try original(recovered), .{}));
    try strings("Unfinished note", j.get(recovered, "recoveryFields").?.array.items[4].string);
    _ = try data(try invoke(&provider, a, .{ .cmd = "accounts.list" }, true));
    _ = try data(try invoke(&provider, a, .{ .cmd = "accounts.identities", .account = "second@example.test" }, true));
    _ = try data(try invoke(&provider, a, .{ .cmd = "accounts.identities", .account = account }, true));
    try verifyHost();
    // A second reply reuses only this actor's already verified aliases.
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .body = full },
        .{ .url = source_image_url, .body = image_response },
        .{ .url = source_style_url, .body = style_response },
    });
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.reply", .account = account, .messageId = "source", .preserveFormatting = true }, false));
    try verifyHost();
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .session = 12, .body = full },
        .{ .url = aliases_url, .session = 12, .body = "{\"sendAs\":[{\"sendAsEmail\":\"second@example.test\",\"isPrimary\":true}]}" },
        .{ .url = source_image_url, .session = 12, .body = image_response },
        .{ .url = source_style_url, .session = 12, .body = style_response },
    });
    const other = try data(try invoke(&provider, a, .{ .cmd = "mail.reply", .account = "second@example.test", .messageId = "source", .preserveFormatting = true, .all = true }, false));
    try equal(@as(usize, 6), j.get(other, "cc").?.array.items.len);
    try verifyHost();
}

test "browser provider: formatted forward preserves complete MIME and all source files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const full = try sourceMessage(a, "source", "image");
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .body = full },
        .{ .url = source_image_url, .body = image_response },
        .{ .url = source_style_url, .body = style_response },
        .{ .url = source_file_url, .body = file_response },
    });
    const forward = try data(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .preserveFormatting = true }, false));
    _ = try original(forward);
    const files = j.get(forward, "attachments").?;
    try equal(@as(usize, 1), files.array.items.len);
    try strings("AP8N", j.text(files.array.items[0], "data"));
    try strings("", j.text(forward, "threadId"));
    try equal(@as(usize, 0), j.get(forward, "to").?.array.items.len);
    try equal(@as(i64, 0), try j.integer(forward, "omittedAttachments", 0));
    const id = try j.required(forward, "id");
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .to = "peer@example.test", .subject = "Forwarded source", .bodyText = "My new note", .attachments = files } }, false));
    try verifyHost();
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent-source\"}" }});
    host.provider = &provider;
    host.expected_draft = id;
    host.capture_body = try a.alloc(u8, t.Limits.request_bytes);
    try outcome(try send(&provider, a, id, "send-original-source"), "applied");
    const sent = try parse(a, host.capture_body.?[0..host.captured_bytes]);
    const encoded = try j.required(sent, "raw");
    const wire = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded));
    try std.base64.url_safe_no_pad.Decoder.decode(wire, encoded);
    const html = try decodeWirePart(a, wire, "Content-Type: text/html");
    try expect(std.mem.indexOf(u8, html, "<style>.source{color:#123456}</style>") != null);
    try expect(std.mem.indexOf(u8, html, source_body) != null);
    try expect(std.mem.indexOf(u8, html, "My new note") != null);
    try strings("\x00\x01\xff", try decodeWirePart(a, wire, "Content-ID: <source-image>"));
    try strings("abc", try decodeWirePart(a, wire, "Content-Location: https://example.test/source.css"));
    try strings("\x00\xff\r", try decodeWirePart(a, wire, "Content-Type: application/octet-stream"));
    try acknowledgeReceipt(&provider, a, id, "send-original-source", true);
    try equal(@as(usize, 0), provider.draftCount());
    try verifyHost();
}

test "browser provider: raw forward is byte exact and failed hydration never creates a partial draft" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const raw = "From: Sender <sender@example.test>\r\nSubject: Opaque original\r\nContent-Type: application/octet-stream\r\n\r\n\x00\xff\r\n";
    resetHost(&.{.{ .url = source_raw_url, .body = try std.json.Stringify.valueAlloc(a, .{ .id = "source", .raw = try base64(a, raw) }, .{}) }});
    const draft = try data(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .original = true }, false));
    const file = j.get(draft, "attachments").?.array.items[0];
    try strings("original.eml", j.text(file, "filename"));
    const encoded = try j.required(file, "data");
    const decoded = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded));
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded);
    try strings(raw, decoded);
    try verifyHost();
    const id = try j.required(draft, "id");
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.discard", .account = account, .draftId = id }, false));
    const full = try sourceMessage(a, "source", "image");
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .body = full },
        .{ .url = source_image_url, .status = 404 },
        .{ .url = source_url, .prefix = true, .body = try sourceMessage(a, "different-source", "rotated") },
    });
    try failure(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .preserveFormatting = true }, false), "MessageIdentityMismatch");
    try equal(@as(usize, 0), provider.draftCount());
    try verifyHost();
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .body = full },
        .{ .url = source_image_url, .body = "{\"size\":3,\"data\":\"AA\"}" },
    });
    try failure(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .preserveFormatting = true }, false), "BodySizeMismatch");
    try equal(@as(usize, 0), provider.draftCount());
    try verifyHost();
    resetHost(&.{
        .{ .url = source_url, .prefix = true, .body = full },
        .{ .url = source_image_url, .status = 404 },
        .{ .url = source_url, .prefix = true, .body = try sourceMessage(a, "source", "rotated") },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/source/attachments/rotated", .body = image_response },
        .{ .url = source_style_url, .body = style_response },
        .{ .url = source_file_url, .body = file_response },
    });
    const retried = try data(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source" }, false));
    const files = j.get(retried, "attachments").?.array.items;
    try equal(@as(usize, 3), files.len);
    try strings("rotated", j.text(files[0], "id"));
    try strings("AAH_", j.text(files[0], "data"));
    for (files) |attachment| {
        try expect(j.get(attachment, "contentId") == null);
        try expect(j.get(attachment, "contentLocation") == null);
        try expect(j.get(attachment, "disposition") == null);
    }
    try verifyHost();
}

test "browser provider: local MIME expansion rejection has no POST or uncertain record and permits reviewed retry" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const resource = try a.alloc(u8, 1850 * 1024);
    @memset(resource, 0xa5);
    const captured: t.Original = .{ .sourceMessageId = "large-source", .bodyHtml = "<p>Large resource</p><img src=\"cid:large\">", .resources = &.{.{ .id = "large", .filename = "large.png", .mimeType = "image/png", .size = resource.len, .data = try base64(a, resource), .contentId = "large", .disposition = "inline" }} };
    resetHost(&.{});
    const value = try data(try invoke(&provider, a, .{ .cmd = "draft.create", .account = account, .draft = t.Draft{ .to = &.{.{ .address = "peer@example.test" }}, .subject = "Oversized portable MIME", .bodyText = "Retain my note", .original = captured } }, false));
    const id = try j.required(value, "id");
    const receipt = try send(&provider, a, id, "local-size-rejection");
    try outcome(receipt, "rejected");
    const result = try data(receipt);
    try strings("local-size-rejection", j.text(result, "id"));
    try strings(id, j.text(result, "draftId"));
    try strings("FormTooLarge", j.text(result, "errorCode"));
    try equal(@as(u32, 3), provider.sendStatus());
    try equal(@as(usize, 0), (try operations(&provider, a)).len);
    try expect(provider.pendingUnknown() == null);
    try acknowledgeReceipt(&provider, a, id, "local-size-rejection", true);
    const request = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.send", .account = account, .draftId = id, .operationId = "local-rejection-output-failure" }, .{});
    var failing_output: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.SendNotStarted, provider.client().call(failing_output.allocator(), request));
    try expect(failing_output.has_induced_failure);
    try equal(@as(usize, 0), (try operations(&provider, a)).len);
    try expect(provider.pendingUnknown() == null);
    try equal(@as(usize, 0), host.posts);
    // Replacing a source is an explicit edit. Failed preparation must not
    // leave a storage fence which blocks that correction or a new review.
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .to = "peer@example.test", .subject = "Reviewed correction", .bodyText = "Edited after local refusal", .original = @as(?t.Original, null) } }, false));
    try equal(@as(usize, 0), host.posts);
    try verifyHost();
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"reviewed-retry\"}" }});
    host.provider = &provider;
    host.expected_draft = id;
    try outcome(try send(&provider, a, id, "explicit-reviewed-retry"), "applied");
    try acknowledgeReceipt(&provider, a, id, "explicit-reviewed-retry", true);
    try equal(@as(usize, 1), host.posts);
    try verifyHost();
}

test "browser provider: omitting oversized source files is explicit retains the quote and never downloads files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const input = try parse(a, try sourceMessage(a, "source", "image"));
    var large_file = j.get(j.get(input, "payload").?, "parts").?.array.items[3];
    var body = j.get(large_file, "body").?;
    try body.object.put(a, "size", .{ .integer = t.Limits.body_bytes + 1 });
    try large_file.object.put(a, "body", body);
    const full = try std.json.Stringify.valueAlloc(a, input, .{});
    resetHost(&.{.{ .url = source_url, .prefix = true, .body = full }});
    try failure(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source" }, false), "AttachmentsTooLarge");
    try equal(@as(usize, 0), provider.draftCount());
    try verifyHost();
    resetHost(&.{.{ .url = source_url, .prefix = true, .body = full }});
    const draft = try data(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .omitAttachments = true }, false));
    try equal(@as(i64, 3), try j.integer(draft, "omittedAttachments", 0));
    try equal(@as(usize, 0), j.get(draft, "attachments").?.array.items.len);
    try expect(std.mem.indexOf(u8, j.text(draft, "bodyText"), "Received source") != null);
    try expect(std.mem.indexOf(u8, j.text(draft, "bodyText"), "<div") == null);
    const id = try j.required(draft, "id");
    const retained = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .to = "peer@example.test", .bodyText = "Edited note" } }, false));
    try equal(@as(i64, 3), try j.integer(retained, "omittedAttachments", 0));
    try verifyHost();
    resetHost(&.{});
    try failure(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .omitAttachments = true, .preserveFormatting = true }, false), "InvalidForwardOptions");
    try failure(try invoke(&provider, a, .{ .cmd = "mail.forward", .account = account, .messageId = "source", .omitAttachments = true, .original = true }, false), "InvalidForwardOptions");
    try verifyHost();
}

fn frozenDraft(provider: *Provider, a: A, address: []const u8, tag: []const u8, bytes: []const u8) ![]const u8 {
    const captured: t.Original = .{ .sourceMessageId = tag, .bodyHtml = "<p>Retained source</p><img src=\"cid:retained\">", .resources = &.{.{ .id = "retained", .filename = "retained.png", .mimeType = "image/png", .size = bytes.len, .data = try base64(a, bytes), .contentId = "retained", .disposition = "inline" }} };
    return j.required(try data(try invoke(provider, a, .{ .cmd = "draft.create", .account = address, .draft = t.Draft{ .to = &.{.{ .address = "peer@example.test" }}, .subject = tag, .bodyText = "An active note must survive quota pressure", .original = captured } }, false)), "id");
}
fn storedDraftHash(provider: *const Provider, index: usize, id: []const u8) ![32]u8 {
    for (provider.drafts[index]) |slot| if (slot.raw) |raw| if (std.mem.eql(u8, slot.id.slice(), id)) {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        return hash;
    };
    return error.DraftNotFound;
}
fn storedDraftBytes(provider: *const Provider) usize {
    var bytes: usize = 0;
    for (provider.drafts) |slots| for (slots) |slot| if (slot.raw) |raw| {
        bytes += raw.len;
    };
    return bytes;
}

test "browser provider: compact save acknowledgements retain original bytes and reject invalid flags before mutation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const resource = try a.alloc(u8, 256 * 1024);
    @memset(resource, 0xa5);
    const resource_data = try base64(a, resource);
    const received_original: t.Original = .{ .sourceMessageId = "frozen-source", .bodyHtml = "<p>Frozen source</p><img src=\"cid:frozen\">", .resources = &.{.{ .id = "frozen", .filename = "frozen.png", .mimeType = "image/png", .size = resource.len, .data = resource_data, .contentId = "frozen" }} };
    const files: []const t.Attachment = &.{.{ .id = "file", .filename = "file.bin", .size = 3, .data = "AP-A" }};
    resetHost(&.{});
    const created = try data(try invoke(&provider, a, .{ .cmd = "draft.create", .account = account, .acknowledgementOnly = true, .draft = t.Draft{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "First note", .bodyFormat = .markdown, .attachments = files, .original = received_original } }, false));
    try equal(@as(usize, 1), created.object.count());
    const id = try j.required(created, "id");
    const updated = try data(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .to = "peer@example.test", .bodyText = "Edited note", .attachments = files } }, false));
    try equal(@as(usize, 1), updated.object.count());
    try strings(id, j.text(updated, "id"));
    var saved = try data(try invoke(&provider, a, .{ .cmd = "draft.read", .account = account, .draftId = id }, false));
    try strings("Edited note", j.text(saved, "bodyText"));
    try strings("markdown", j.text(saved, "bodyFormat"));
    try strings(resource_data, j.text(j.get(j.get(saved, "original").?, "resources").?.array.items[0], "data"));
    try strings(files[0].data, j.text(j.get(saved, "attachments").?.array.items[0], "data"));
    const recovery_fields = [_][]const u8{ "unfinished address", "", "", "Recovery", "Unfinished note" };
    const recovered = try data(try invoke(&provider, a, .{ .cmd = "draft.recovery-save", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .recoveryFields = recovery_fields, .attachments = files } }, false));
    try equal(@as(usize, 1), recovered.object.count());
    try strings(id, j.text(recovered, "id"));
    saved = try data(try invoke(&provider, a, .{ .cmd = "draft.read", .account = account, .draftId = id }, false));
    try strings(recovery_fields[4], j.get(saved, "recoveryFields").?.array.items[4].string);
    try strings(resource_data, j.text(j.get(j.get(saved, "original").?, "resources").?.array.items[0], "data"));
    try strings(files[0].data, j.text(j.get(saved, "attachments").?.array.items[0], "data"));
    const before_hash = try storedDraftHash(&provider, 0, id);
    const before_bytes = provider.draft_bytes;
    const before_sequence = provider.sequence;
    for ([_][]const u8{ "draft.create", "draft.update", "draft.recovery-save" }) |cmd| {
        try failure(try invoke(&provider, a, .{ .cmd = cmd, .account = account, .draftId = id, .acknowledgementOnly = "true", .draft = .{ .to = "peer@example.test", .bodyText = "Must not replace saved content", .recoveryFields = recovery_fields, .attachments = files } }, false), "InvalidRequest");
        try equal(before_hash, try storedDraftHash(&provider, 0, id));
        try equal(before_bytes, provider.draft_bytes);
        try equal(before_sequence, provider.sequence);
    }
    try failure(try invoke(&provider, a, .{ .cmd = "draft.update", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .subject = "Invalid\r\nHeader", .attachments = files } }, false), "HeaderInjection");
    try equal(before_hash, try storedDraftHash(&provider, 0, id));
    // Omitted and explicit false preserve the full CLI response contract.
    for ([_]bool{ false, true }) |explicit_false| {
        var request = try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .to = "peer@example.test", .bodyText = "Finished note", .attachments = files } });
        if (explicit_false) try request.object.put(a, "acknowledgementOnly", .{ .bool = false });
        const response = try data(try invoke(&provider, a, request, false));
        try strings("Finished note", j.text(response, "bodyText"));
        try strings(resource_data, j.text(j.get(j.get(response, "original").?, "resources").?.array.items[0], "data"));
        try strings(files[0].data, j.text(j.get(response, "attachments").?.array.items[0], "data"));
    }
    try equal(@as(usize, 1), provider.draftCount());
    try equal(@as(usize, 0), provider.operation_count);
    try equal(@as(usize, 0), host.requests);
    try verifyHost();
}

test "browser provider: large original draft lists are compact read-only summaries and full reads retain exact files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const bytes = try a.alloc(u8, 2000 * 1024);
    @memset(bytes, 0xa5);
    const resource_data = try base64(a, bytes);
    const file_data = try base64(a, "Ordinary source bytes");
    const received_original: t.Original = .{
        .sourceMessageId = "large-original",
        .subject = "Frozen source subject",
        .bodyText = "Frozen source text",
        .bodyHtml = "<p>Frozen source text</p><img src=\"cid:retained\">",
        .resources = &.{.{ .id = "retained", .filename = "retained.png", .mimeType = "image/png", .size = bytes.len, .data = resource_data, .contentId = "retained", .disposition = "inline" }},
    };
    const file: t.Attachment = .{ .id = "ordinary", .filename = "source.txt", .mimeType = "text/plain", .size = "Ordinary source bytes".len, .data = file_data, .disposition = "attachment" };
    var ids: [3][]const u8 = undefined;
    var hashes: [3][32]u8 = undefined;
    resetHost(&.{});
    for (&ids, &hashes, 0..) |*id, *hash, index| {
        var command: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer command.deinit();
        const ca = command.allocator();
        const created = try data(try invoke(&provider, ca, .{
            .cmd = "draft.create",
            .account = account,
            .draft = t.Draft{
                .to = &.{.{ .address = "peer@example.test" }},
                .subject = try std.fmt.allocPrint(ca, "Large draft {d}", .{index}),
                .bodyText = "Editable note remains in the full draft",
                .bodyFormat = .markdown,
                .omittedAttachments = 1,
                .attachments = &.{file},
                .original = received_original,
            },
        }, false));
        id.* = try a.dupe(u8, try j.required(created, "id"));
        hash.* = try storedDraftHash(&provider, 0, id.*);
    }
    try expect(provider.draft_bytes > 7 * 1024 * 1024);
    try expect(provider.draft_bytes < 8 * 1024 * 1024);
    const stored_bytes = provider.draft_bytes;
    // Removing send permission must not remove access to local recovery data.
    provider.live_sessions[0].can_send = false;
    const request = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.list", .account = account }, .{});
    const listed_raw = try provider.client().call(a, request);
    try expect(listed_raw.len < 16 * 1024);
    try expect(listed_raw.len < t.Limits.request_bytes);
    try expect(std.mem.indexOf(u8, listed_raw, resource_data[0..64]) == null);
    const listed = j.get(try data(try parse(a, listed_raw)), "drafts").?.array.items;
    try equal(@as(usize, 3), listed.len);
    for (listed, ids, hashes) |summary, id, hash| {
        try strings(id, j.text(summary, "id"));
        try strings("", j.text(summary, "bodyText"));
        try strings("markdown", j.text(summary, "bodyFormat"));
        try equal(@as(i64, 1), try j.integer(summary, "omittedAttachments", 0));
        if (j.get(summary, "original")) |value| try expect(value == .null);
        if (j.get(summary, "recoveryFields")) |value| try expect(value == .null);
        const files = j.get(summary, "attachments").?.array.items;
        try equal(@as(usize, 1), files.len);
        try strings(file.filename, j.text(files[0], "filename"));
        try equal(@as(i64, @intCast(file.size)), try j.integer(files[0], "size", -1));
        try strings("", j.text(files[0], "data"));
        var read_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer read_arena.deinit();
        const read = try data(try invoke(&provider, read_arena.allocator(), .{ .cmd = "draft.read", .account = account, .draftId = id }, false));
        try strings("Editable note remains in the full draft", j.text(read, "bodyText"));
        const retained = j.get(read, "original").?;
        try strings(received_original.bodyHtml, j.text(retained, "bodyHtml"));
        try strings(resource_data, j.text(j.get(retained, "resources").?.array.items[0], "data"));
        try strings(file_data, j.text(j.get(read, "attachments").?.array.items[0], "data"));
        try equal(hash, try storedDraftHash(&provider, 0, id));
    }
    try equal(stored_bytes, provider.draft_bytes);
    try equal(stored_bytes, storedDraftBytes(&provider));
    try equal(@as(usize, 0), provider.operation_count);
    try equal(@as(usize, 0), host.requests);
    try verifyHost();
}

test "browser provider: shared quota reclaims confirmed retired originals across actors without touching active or unknown drafts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const other = "bea@example.test";
    try actor(&provider, 1, other, true, false);
    const large = try a.alloc(u8, 1536 * 1024);
    @memset(large, 0xa5);
    // Create both originals before sending, so both confirmed drafts retain
    // their roughly 2 MiB JSON snapshots in separate slots.
    const first = try frozenDraft(&provider, a, account, "First confirmed original", large);
    const second = try frozenDraft(&provider, a, account, "Second confirmed original", large);
    const active = try frozenDraft(&provider, a, account, "Ada active original", large);
    const unknown = try frozenDraft(&provider, a, other, "Bea unresolved original", large[0 .. 100 * 1024]);
    resetHost(&.{
        .{ .method = "POST", .url = send_url, .body = "{\"id\":\"confirmed-one\"}" },
        .{ .method = "POST", .url = send_url, .body = "{\"id\":\"confirmed-two\"}" },
        .{ .method = "POST", .url = send_url, .session = 12, .result = 1 },
    });
    host.provider = &provider;
    host.expected_draft = first;
    try outcome(try send(&provider, a, first, "quota-confirmed-one"), "applied");
    try acknowledgeReceipt(&provider, a, first, "quota-confirmed-one", true);
    host.expected_draft = second;
    try outcome(try send(&provider, a, second, "quota-confirmed-two"), "applied");
    try acknowledgeReceipt(&provider, a, second, "quota-confirmed-two", true);
    host.expected_draft = unknown;
    try outcome(try invoke(&provider, a, .{ .cmd = "draft.send", .account = other, .draftId = unknown, .operationId = "quota-unknown" }, false), "unknown");
    const unknown_request = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.send", .account = other, .draftId = unknown, .operationId = "quota-unknown" }, .{});
    provider.client().sendReceipt(unknown_request, true);
    const active_hash = try storedDraftHash(&provider, 0, active);
    const unknown_hash = try storedDraftHash(&provider, 1, unknown);
    try verifyHost();

    resetHost(&.{});
    const admitted = try frozenDraft(&provider, a, other, "Bea new original", large);
    try expect(provider.draft_bytes <= 8 * 1024 * 1024);
    try equal(provider.draft_bytes, storedDraftBytes(&provider));
    try equal(@as(usize, 3), provider.draftCount());
    try std.testing.expectError(error.DraftNotFound, storedDraftHash(&provider, 0, first));
    _ = try storedDraftHash(&provider, 0, second);
    _ = try storedDraftHash(&provider, 1, admitted);
    try equal(active_hash, try storedDraftHash(&provider, 0, active));
    try equal(unknown_hash, try storedDraftHash(&provider, 1, unknown));
    const pending = provider.pendingUnknown() orelse return error.MissingUncertainFence;
    try equal(@as(usize, 1), pending.account_index);
    try strings(unknown, pending.draft_id);
    const receipts = try operations(&provider, a);
    try equal(@as(usize, 2), receipts.len);
    for (receipts) |receipt| try strings("applied", j.text(receipt, "outcome"));
    // Eviction has the same replay lifetime as reuse of a sent slot: the
    // ledger remains, and a stale draft ID cannot submit another message.
    try failure(try send(&provider, a, first, "quota-confirmed-one"), "DraftNotFound");
    try equal(@as(usize, 2), (try operations(&provider, a)).len);
    try failure(try invoke(&provider, a, .{ .cmd = "draft.discard", .account = other, .draftId = unknown }, false), "UnknownOutcome");
    try verifyHost();
}

test "browser provider: unsuccessful quota admission preserves retired active and unconsumed originals atomically" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var provider = Provider.init(failing.allocator());
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    const other = "bea@example.test";
    try actor(&provider, 1, other, true, false);
    const bytes = try a.alloc(u8, t.Limits.body_bytes);
    @memset(bytes, 0xa5);
    const retired = try frozenDraft(&provider, a, account, "Small confirmed original", bytes[0 .. 64 * 1024]);
    const active = try frozenDraft(&provider, a, account, "Ada still editing", bytes[0 .. 1536 * 1024]);
    const other_active = try frozenDraft(&provider, a, other, "Bea still editing", bytes[0 .. 1536 * 1024]);
    const unconsumed = try frozenDraft(&provider, a, other, "Bea awaiting consumer", bytes[0 .. 1536 * 1024]);
    resetHost(&.{
        .{ .method = "POST", .url = send_url, .body = "{\"id\":\"confirmed-small\"}" },
        .{ .method = "POST", .url = send_url, .session = 12, .body = "{\"id\":\"unconsumed-large\"}" },
    });
    host.provider = &provider;
    host.expected_draft = retired;
    try outcome(try send(&provider, a, retired, "small-confirmed"), "applied");
    try acknowledgeReceipt(&provider, a, retired, "small-confirmed", true);
    host.expected_draft = unconsumed;
    try outcome(try invoke(&provider, a, .{ .cmd = "draft.send", .account = other, .draftId = unconsumed, .operationId = "awaiting-consumer" }, false), "applied");
    try verifyHost();
    const before_bytes = provider.draft_bytes;
    const hashes = [_][32]u8{ try storedDraftHash(&provider, 0, retired), try storedDraftHash(&provider, 0, active), try storedDraftHash(&provider, 1, other_active), try storedDraftHash(&provider, 1, unconsumed) };

    resetHost(&.{});
    const captured: t.Original = .{ .sourceMessageId = "too-large-for-remaining-quota", .bodyHtml = "<img src=\"cid:retained\">", .resources = &.{.{ .id = "retained", .filename = "retained.png", .mimeType = "image/png", .size = bytes.len, .data = try base64(a, bytes), .contentId = "retained" }} };
    try failure(try invoke(&provider, a, .{ .cmd = "draft.create", .account = other, .draft = t.Draft{ .subject = "Cannot fit", .original = captured } }, false), "BrowserDraftQuota");
    try equal(before_bytes, provider.draft_bytes);
    try equal(hashes[0], try storedDraftHash(&provider, 0, retired));
    try equal(hashes[1], try storedDraftHash(&provider, 0, active));
    try equal(hashes[2], try storedDraftHash(&provider, 1, other_active));
    try equal(hashes[3], try storedDraftHash(&provider, 1, unconsumed));
    try equal(provider.draft_bytes, storedDraftBytes(&provider));
    try equal(@as(usize, 2), provider.operation_count);
    try expect(provider.operations[1].awaiting_receipt);
    // Allocation failure before admission is equally non-destructive.
    const request = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.create", .account = other, .draft = .{ .subject = "Allocation failure", .bodyText = "New note" } }, .{});
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, provider.client().call(a, request));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try equal(before_bytes, provider.draft_bytes);
    try equal(hashes[0], try storedDraftHash(&provider, 0, retired));
    try equal(hashes[3], try storedDraftHash(&provider, 1, unconsumed));
    try failure(try invoke(&provider, a, .{ .cmd = "draft.discard", .account = other, .draftId = unconsumed }, false), "UnknownOutcome");
    try verifyHost();
}

test "browser provider: partial metadata cannot remove retained folder membership or hide warning rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    try provider.cache.restore(0, fixture_snapshot, false);
    resetHost(&.{
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[{\"id\":\"warning-mail\"}]}" },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/warning-mail?", .prefix = true, .body = "{\"id\":\"warning-mail\",\"threadId\":\"warning-thread\",\"labelIds\":[\"INBOX\"],\"internalDate\":\"2000\",\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Subject\",\"value\":\"Warning remains visible\"},{\"name\":\"From\",\"value\":\"unsupported syntax\"}]}}" },
    });
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    const cached = try data(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true));
    const rows = j.get(cached, "messages").?.array.items;
    try equal(@as(usize, 2), rows.len);
    try expect(try j.boolean(cached, "viewIncomplete", false));
    try strings("warning-mail", j.text(rows[0], "id"));
    try strings("", j.text(j.get(rows[0], "from").?, "address"));
    try expect(try j.boolean(rows[0], "metadataPartial", false));
    try expect(j.text(rows[0], "decodeWarning").len != 0);
    try strings("old-inbox", j.text(rows[1], "id"));
    try strings("An independently authored cached body", j.text(try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "old-inbox" }, true)), "bodyText"));
    try verifyHost();
}

test "browser provider: stats report the actual fixed heap separately from linear memory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    resetHost(&.{});
    const stats = try data(try invoke(&provider, a, .{ .cmd = "cache.stats", .account = account }, true));
    try equal(@as(i64, 64 * 1024 * 1024), try j.integer(stats, "runtimeReservationBytes", 0));
    try equal(@as(i64, 64 * 1024 * 1024), try j.integer(stats, "terminalHeapLimitBytes", 0));
    try equal(@as(i64, 96 * 1024 * 1024), try j.integer(stats, "browserLinearMemoryBytes", 0));
    const scratch = j.get(stats, "mailScratch").?;
    try equal(@as(i64, 16 * 1024 * 1024), try j.integer(scratch, "reservationBytes", 0));
    try equal(@as(i64, 0), try j.integer(scratch, "usedBytes", -1));
    try expect(!try j.boolean(scratch, "active", true));
    try equal(@as(i64, 8 * 1024 * 1024), try j.integer(stats, "diskLimitBytes", 0));
    try verifyHost();
}

test "mail response memory: browser live and cached reads and threads preserve two MiB HTML in the fixed heap" {
    const Meter = @import("terminal/capped_allocator.zig").CappedAllocator;
    const Oracle = struct {
        html: []const u8,
        plain: []const u8,
        message_wire: []const u8,
        thread_wire: []const u8,
        snapshot_buffer: []u8,
        fn response(self: *const @This(), provider: *Provider, a: A, command: []const u8, cached: bool, body_cached: bool) !void {
            var output: std.heap.ArenaAllocator = .init(a);
            defer output.deinit();
            const request = if (std.mem.eql(u8, command, "mail.read"))
                "{\"id\":\"browser-large\",\"cmd\":\"mail.read\",\"account\":\"ada@example.test\",\"messageId\":\"large-html\"}"
            else
                "{\"id\":\"browser-large\",\"cmd\":\"mail.thread\",\"account\":\"ada@example.test\",\"threadId\":\"large-thread\"}";
            const raw = if (cached) try provider.client().callCached(output.allocator(), request) else try provider.client().call(output.allocator(), request);
            // The transport, response encoding and retained cache share the
            // production heap. Independent assertion parsing stays outside it.
            var assertions: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer assertions.deinit();
            const envelope = try parse(assertions.allocator(), raw);
            try strings("browser-large", j.text(envelope, "id"));
            try strings(account, j.text(envelope, "account"));
            const result = try data(envelope);
            const message = if (std.mem.eql(u8, command, "mail.read")) result else blk: {
                const rows = (j.get(result, "messages") orelse return error.MissingMessages).array.items;
                try equal(@as(usize, 1), rows.len);
                try equal(cached, try j.boolean(result, "partial", !cached));
                try equal(@as(i64, 0), try j.integer(result, "omittedMessages", -1));
                if (cached) try expect(try j.boolean(result, "cached", false));
                break :blk rows[0];
            };
            try strings("large-html", j.text(message, "id"));
            try strings("large-thread", j.text(message, "threadId"));
            try strings("Fictional large HTML", j.text(message, "subject"));
            try strings("sender@example.test", j.text(j.get(message, "from").?, "address"));
            try strings("html", j.text(message, "bodySource"));
            try strings(self.html, j.text(message, "bodyHtml"));
            try strings(self.plain, j.text(message, "bodyText"));
            try equal(body_cached, try j.boolean(message, "bodyCached", !body_cached));
            try strings("", try j.string(j.get(message, "bodyCacheError").?));
            try strings("", try j.string(j.get(message, "decodeWarning").?));
            try expect(!try j.boolean(message, "metadataPartial", true));
            try expect(!try j.boolean(message, "bodyHtmlAmbiguous", true));
            try equal(@as(usize, 0), j.get(message, "attachments").?.array.items.len);
            try expect(j.get(message, "invitation") == null);
        }
        fn run(self: *const @This(), cap: *Meter, command: []const u8) !void {
            const a = cap.allocator();
            var provider = Provider.init(a);
            defer provider.deinit();
            try actor(&provider, 0, account, false, false);
            // actor() skips OAuth setup; match Provider.connect's allocator
            // so completed provider fetch arenas release their heap storage.
            provider.live_sessions[0].temporary_allocator = a;
            resetHost(&.{.{
                .url = if (std.mem.eql(u8, command, "mail.read")) "https://gmail.googleapis.com/gmail/v1/users/me/messages/large-html?format=full" else "https://gmail.googleapis.com/gmail/v1/users/me/threads/large-thread?format=full",
                .body = if (std.mem.eql(u8, command, "mail.read")) self.message_wire else self.thread_wire,
            }});
            defer resetHost(&.{});
            // Each case starts empty, so both live routes must cross the real
            // browser_live ABI and decodeResponse before final JSON encoding.
            try self.response(&provider, a, command, false, false);
            const retained = cap.snapshot().allocatorUsedBytes;
            const revision = provider.cacheRevision(0);
            const stored = try provider.cacheSnapshot(0, self.snapshot_buffer);
            try expect(stored.len > self.html.len and stored.len < cache.snapshot_limit);
            try equal(retained, cap.snapshot().allocatorUsedBytes);
            for ([_][]const u8{ "mail.read", "mail.thread", "mail.read", "mail.thread" }) |cached_command| {
                try self.response(&provider, a, cached_command, true, true);
                try equal(retained, cap.snapshot().allocatorUsedBytes);
                try equal(revision, provider.cacheRevision(0));
            }
            // Ordinary read also borrows the retained entry once it is warm.
            try self.response(&provider, a, "mail.read", false, true);
            try equal(retained, cap.snapshot().allocatorUsedBytes);
            try equal(revision, provider.cacheRevision(0));
            try equal(@as(usize, 1), host.requests);
            try equal(@as(usize, 0), host.posts);
            try verifyHost();
        }
    };
    var fixtures: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer fixtures.deinit();
    const fa = fixtures.allocator();
    const html = try fa.alloc(u8, t.Limits.body_bytes);
    const prefix = "<html><body>\n<p>Fictional browser header.</p>\n";
    const line = "<p><strong>Fictional line.</strong></p>\n";
    const suffix = "\n<p>Fictional browser tail.</p></body></html>";
    @memcpy(html[0..prefix.len], prefix);
    const end = html.len - suffix.len;
    var plain: std.ArrayList(u8) = .empty;
    try plain.appendSlice(fa, "Fictional browser header.\n");
    var pos = prefix.len;
    while (line.len <= end - pos) : (pos += line.len) {
        @memcpy(html[pos..][0..line.len], line);
        try plain.appendSlice(fa, "Fictional line.\n");
    }
    @memset(html[pos..end], ' ');
    @memcpy(html[end..], suffix);
    try plain.appendSlice(fa, "Fictional browser tail.");
    // Literal markup and a separately authored plaintext oracle keep the
    // exact two-MiB HTML body within the existing three-MiB snapshot quota.
    const encoded = try base64(fa, html);
    const message_wire = try std.fmt.allocPrint(fa, "{{\"id\":\"large-html\",\"threadId\":\"large-thread\",\"internalDate\":\"1791633600000\",\"labelIds\":[\"INBOX\"],\"payload\":{{\"mimeType\":\"text/html\",\"headers\":[{{\"name\":\"From\",\"value\":\"Fictional Sender <sender@example.test>\"}},{{\"name\":\"To\",\"value\":\"ada@example.test\"}},{{\"name\":\"Subject\",\"value\":\"Fictional large HTML\"}},{{\"name\":\"Message-ID\",\"value\":\"<large-html@example.test>\"}}],\"body\":{{\"size\":{d},\"data\":\"{s}\"}}}}}}", .{ html.len, encoded });
    const oracle: Oracle = .{ .html = html, .plain = plain.items, .message_wire = message_wire, .thread_wire = try std.fmt.allocPrint(fa, "{{\"id\":\"large-thread\",\"messages\":[{s}]}}", .{message_wire}), .snapshot_buffer = try fa.alloc(u8, cache.snapshot_limit) };
    // Browser production uses this exact fixed reservation, without the
    // native heap's additional allocator-overhead allowance.
    const reservation = try std.testing.allocator.alloc(u8, @import("browser_provider.zig").heap_bytes);
    defer std.testing.allocator.free(reservation);
    var first_error: ?anyerror = null;
    for ([_][]const u8{ "mail.read", "mail.thread" }) |command| {
        var heap = @import("browser_heap.zig").Heap.init(reservation);
        var cap: Meter = .{ .backing = heap.allocator(), .limit = reservation.len, .reservation_bytes = reservation.len };
        var failed = false;
        oracle.run(&cap, command) catch |err| {
            std.debug.print("\nbrowser {s}: {s}; allocation snapshot {any}\n", .{ command, @errorName(err), cap.snapshot() });
            failed = true;
            if (first_error == null) first_error = err;
        };
        try equal(@as(usize, 0), cap.snapshot().allocatorUsedBytes);
        if (!failed) try equal(@as(usize, 0), cap.snapshot().rejectedAllocations);
        try expect(cap.snapshot().allocatorPeakBytes <= reservation.len);
    }
    if (first_error) |err| return err;
}

fn browserMailFixture(a: A, id: []const u8, thread: []const u8, body: []const u8) !Value {
    return j.value(a, .{
        .id = id,
        .threadId = thread,
        .labelIds = [_][]const u8{"INBOX"},
        .internalDate = "2000",
        .payload = .{ .mimeType = "text/plain", .headers = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = "From", .value = "Peer <peer@example.test>" },
            .{ .name = "To", .value = account },
            .{ .name = "Subject", .value = "Independent browser body fixture" },
        }, .body = .{ .size = body.len, .data = try base64(a, body) } },
    });
}
fn escapedBrowserBody(a: A, bytes: usize) ![]u8 {
    const body = try a.alloc(u8, bytes);
    for (body, 0..) |*byte, index| byte.* = if (index % 2 == 0) '"' else '\\';
    return body;
}
fn findBrowserMessage(values: []const Value, id: []const u8) !Value {
    for (values) |value| if (std.mem.eql(u8, j.text(value, "id"), id)) return value;
    return error.MissingFixtureMessage;
}

test "browser provider: aggregate thread omission remains eligible for a later individual live read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    const body = try escapedBrowserBody(a, 1_100_000);
    var first = try browserMailFixture(a, "first", "aggregate", body);
    try first.object.put(a, "internalDate", .{ .string = "1000" });
    const second = try browserMailFixture(a, "second", "aggregate", body);
    const thread = try std.json.Stringify.valueAlloc(a, .{ .id = "aggregate", .messages = [_]Value{ first, second } }, .{});
    const standalone = try std.json.Stringify.valueAlloc(a, first, .{});
    resetHost(&.{
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/threads/aggregate?format=full", .body = thread },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/first?format=full", .body = standalone },
    });
    const conversation = try messages(try invoke(&provider, a, .{ .cmd = "mail.thread", .account = account, .threadId = "aggregate" }, false));
    try equal(@as(usize, 2), conversation.len);
    try strings(body, j.text(try findBrowserMessage(conversation, "second"), "bodyText"));
    try strings("ThreadBodyBudgetExceeded", j.text(try findBrowserMessage(conversation, "first"), "bodyCacheError"));
    try expect(try provider.cache.read(0, "first") == null);
    try failure(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "first" }, true), "CacheMiss");
    const opened = try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "first" }, false));
    try strings(body, j.text(opened, "bodyText"));
    try strings("", j.text(opened, "bodyCacheError"));
    try strings(body, (try provider.cache.read(0, "first")).?.bodyText);
    try verifyHost();
}

test "browser provider: standalone escaped body remains readable when its serialized snapshot exceeds quota" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    const body = try escapedBrowserBody(a, 1_600_000);
    const response = try std.json.Stringify.valueAlloc(a, try browserMailFixture(a, "quota", "thread", body), .{});
    const step: HttpStep = .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/quota?format=full", .body = response };
    resetHost(&.{ step, step });
    for (0..2) |_| {
        const opened = try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "quota" }, false));
        try strings(body, j.text(opened, "bodyText"));
        try strings("BrowserCacheQuotaExceeded", j.text(opened, "decodeWarning"));
        try strings("", j.text(opened, "bodyCacheError"));
        try expect(try j.boolean(opened, "metadataPartial", false));
        try expect(!try j.boolean(opened, "bodyCached", true));
        try expect(try provider.cache.read(0, "quota") == null);
    }
    try verifyHost();
}

test "browser provider: thread cache quota warning preserves actual bodies neighboring messages and prior full cache" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    try provider.cache.saveRead(0, .{ .id = "large", .threadId = "quota-thread", .bodyText = "Earlier full cached body", .labels = &.{"INBOX"} });
    const body = try escapedBrowserBody(a, 1_600_000);
    const large = try browserMailFixture(a, "large", "quota-thread", body);
    const neighbor = try browserMailFixture(a, "neighbor", "quota-thread", "A healthy neighboring body");
    const response = try std.json.Stringify.valueAlloc(a, .{ .id = "quota-thread", .messages = [_]Value{ large, neighbor } }, .{});
    resetHost(&.{.{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/threads/quota-thread?format=full", .body = response }});
    const result = try data(try invoke(&provider, a, .{ .cmd = "mail.thread", .account = account, .threadId = "quota-thread" }, false));
    const returned = j.get(result, "messages").?.array.items;
    try equal(@as(usize, 2), returned.len);
    const readable = try findBrowserMessage(returned, "large");
    try strings(body, j.text(readable, "bodyText"));
    try strings("BrowserCacheQuotaExceeded", j.text(readable, "decodeWarning"));
    try strings("", j.text(readable, "bodyCacheError"));
    try expect(try j.boolean(result, "partial", false));
    try strings("A healthy neighboring body", j.text(try findBrowserMessage(returned, "neighbor"), "bodyText"));
    try strings("Earlier full cached body", (try provider.cache.read(0, "large")).?.bodyText);
    try strings("A healthy neighboring body", (try provider.cache.read(0, "neighbor")).?.bodyText);
    try verifyHost();
}

test "browser provider: cache admission does not hide allocator authentication or identity failures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    const response = try std.json.Stringify.valueAlloc(a, try browserMailFixture(a, "requested", "thread", "Small readable body"), .{});
    resetHost(&.{
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/requested?format=full", .status = 401 },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/other?format=full", .body = response },
    });
    try failure(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "requested" }, false), "NotConnected");
    try failure(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "other" }, false), "MessageIdentityMismatch");
    try verifyHost();
    provider.cache.deinit();
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    provider.cache = cache.Store.init(failing.allocator());
    try provider.cache.bind(0, .{ .account = account, .clientId = client_id, .grantId = "" });
    failing.fail_index = failing.alloc_index;
    resetHost(&.{.{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/requested?format=full", .body = response }});
    try failure(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "requested" }, false), "OutOfMemory");
    try expect(!provider.cache.valid(0));
    try verifyHost();
}

test "browser provider: ID-only scoped rows survive account switches and partial queries without losing neighbors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    try actor(&provider, 1, "second@example.test", false, false);
    try provider.cache.restore(0, fixture_snapshot, false);
    try provider.cache.saveRead(1, .{ .id = "other-actor", .threadId = "other-thread", .bodyText = "Second actor only", .labels = &.{"INBOX"} });
    resetHost(&.{
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[{\"id\":\"id-only\"}]}" },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/id-only?format=metadata", .prefix = true, .result = 2 },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/id-only?format=minimal&fields=id,threadId", .body = "{\"id\":\"id-only\",\"threadId\":\"unknown-thread\"}" },
    });
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    try equal(@as(usize, 1), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = "second@example.test", .label = "INBOX" }, true))).len);
    const restored = try data(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true));
    const rows = j.get(restored, "messages").?.array.items;
    try equal(@as(usize, 2), rows.len);
    _ = try findBrowserMessage(rows, "old-inbox");
    const unknown = try findBrowserMessage(rows, "id-only");
    try expect(!try j.boolean(unknown, "labelsVerified", true));
    try equal(@as(usize, 0), j.get(unknown, "labels").?.array.items.len);
    try expect(try j.boolean(restored, "viewIncomplete", false));
    for ([_][]const u8{ "mail.list", "mail.search" }) |cmd| {
        const partial = try messages(try invoke(&provider, a, .{ .cmd = cmd, .account = account, .label = "INBOX", .query = "status:partial" }, true));
        try equal(@as(usize, 1), partial.len);
        try strings("id-only", j.text(partial[0], "id"));
    }
    try equal(@as(usize, 0), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "SENT", .query = "status:partial" }, true))).len);
    try equal(@as(usize, 0), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .query = "label:SENT status:partial" }, true))).len);
    try strings("An independently authored cached body", (try provider.cache.read(0, "old-inbox")).?.bodyText);
    try verifyHost();
    // A subsequent partial head proves no removals, including for unknown
    // labels whose membership came solely from an earlier scoped list.
    resetHost(&.{.{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[],\"nextPageToken\":\"more\"}" }});
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    const repeated = try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .query = "status:partial" }, true));
    try equal(@as(usize, 1), repeated.len);
    try strings("id-only", j.text(repeated[0], "id"));
    try verifyHost();
    // Only a later complete provider view can certify that these IDs left.
    resetHost(&.{.{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[]}" }});
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    const empty = try data(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true));
    try equal(@as(usize, 0), j.get(empty, "messages").?.array.items.len);
    try expect(!try j.boolean(empty, "viewIncomplete", true));
    try equal(@as(usize, 0), (try messages(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX", .query = "status:partial" }, true))).len);
    try verifyHost();
}

test "browser provider: decoder migration stays offline and a newly refused charset is fetched only once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    const old = snapshot_head ++ "\"decoderRevision\":3,\"messages\":[{\"id\":\"charset\",\"threadId\":\"thread\",\"subject\":\"Retained subject\",\"bodyCacheError\":\"UnsupportedCharset\",\"decodeWarning\":\"UnsupportedCharset\",\"metadataPartial\":true,\"labels\":[\"INBOX\"]}],\"contacts\":[],\"contactsLoaded\":false}";
    var source = try browserMailFixture(a, "charset", "thread", "\x82\xa0");
    const payload = source.object.getPtr("payload").?;
    try payload.object.getPtr("headers").?.array.append(try j.value(a, .{ .name = "Content-Type", .value = "text/plain; charset=Shift_JIS" }));
    const response = try std.json.Stringify.valueAlloc(a, source, .{});
    resetHost(&.{.{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/charset?format=full", .body = response }});
    try provider.cache.restore(0, old, false);
    try equal(@as(usize, 0), host.requests);
    try failure(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "charset" }, true), "CacheMiss");
    try equal(@as(usize, 0), host.requests);
    const first = try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "charset" }, false));
    try strings("UnsupportedCharset", j.text(first, "bodyCacheError"));
    try equal(@as(usize, 1), host.requests);
    const snapshot_buffer = try a.alloc(u8, cache.snapshot_limit);
    const persisted = try a.dupe(u8, try provider.cache.snapshot(0, snapshot_buffer));
    // Charset retry eligibility changed at revision 4; the saved receipt
    // records the current shared policy, including later unrelated changes.
    try equal(@as(i64, decoder_policy.decoder_revision), try j.integer(try parse(a, persisted), "decoderRevision", 0));
    try provider.cache.restore(0, persisted, false);
    const second = try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "charset" }, false));
    try strings("UnsupportedCharset", j.text(second, "bodyCacheError"));
    try equal(@as(usize, 1), host.requests);
    try verifyHost();
}

test "browser provider: cached thread includes metadata-only members in the newest thirty message window" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    var rows: [35]Value = undefined;
    for (&rows, 0..) |*row, index| row.* = try j.value(a, .{ .id = try std.fmt.allocPrint(a, "member-{d}", .{index}), .threadId = "large-thread", .subject = "Retained member", .receivedAt = @as(i64, @intCast(index + 1)), .bodyText = if (index % 2 == 0) @as([]const u8, "") else "Retained full body", .bodyCached = index % 2 != 0, .labels = [_][]const u8{"INBOX"} });
    const old = try std.mem.concat(a, u8, &.{ snapshot_head, "\"decoderRevision\":4,\"messages\":", try std.json.Stringify.valueAlloc(a, &rows, .{}), ",\"contacts\":[],\"contactsLoaded\":false}" });
    try provider.cache.restore(0, old, false);
    resetHost(&.{});
    const result = try data(try invoke(&provider, a, .{ .cmd = "mail.thread", .account = account, .threadId = "large-thread" }, true));
    const returned = j.get(result, "messages").?.array.items;
    try equal(@as(usize, 30), returned.len);
    try equal(@as(i64, 5), try j.integer(result, "omittedMessages", 0));
    try expect(try j.boolean(result, "partial", false));
    try strings("member-5", j.text(returned[0], "id"));
    try strings("member-34", j.text(returned[29], "id"));
    const missing = try findBrowserMessage(returned, "member-6");
    try strings("BodyNotCached", j.text(missing, "bodyCacheError"));
    try expect(try j.boolean(missing, "labelsVerified", false));
    try strings("INBOX", j.get(missing, "labels").?.array.items[0].string);
    try strings("Retained full body", j.text(try findBrowserMessage(returned, "member-7"), "bodyText"));
    try expect(try provider.cache.read(0, "member-6") == null);
    try verifyHost();
}

test "browser provider: live threads keep healthy newest thirty members and report older omissions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    var rows: [35]Value = undefined;
    for (&rows, 0..) |*row, index| {
        row.* = try browserMailFixture(a, try std.fmt.allocPrint(a, "member-{d}", .{index}), "large-thread", "Healthy live body");
        try row.object.put(a, "internalDate", .{ .string = try std.fmt.allocPrint(a, "{d}", .{index + 1}) });
    }
    resetHost(&.{.{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/threads/large-thread?format=full", .body = try std.json.Stringify.valueAlloc(a, .{ .id = "large-thread", .messages = &rows }, .{}) }});
    const result = try data(try invoke(&provider, a, .{ .cmd = "mail.thread", .account = account, .threadId = "large-thread" }, false));
    const returned = j.get(result, "messages").?.array.items;
    try equal(@as(usize, 30), returned.len);
    try equal(@as(i64, 5), try j.integer(result, "omittedMessages", 0));
    try expect(try j.boolean(result, "partial", false));
    try strings("member-5", j.text(returned[0], "id"));
    try strings("member-34", j.text(returned[29], "id"));
    for (returned) |row| try strings("Healthy live body", j.text(row, "bodyText"));
    try expect(try provider.cache.read(0, "member-0") == null);
    try equal(@as(usize, 30), provider.cache.retained(0).len);
    try verifyHost();
}

test "browser provider: eviction invalidates a complete cached view and returns the retained subset honestly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    resetHost(&.{
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[{\"id\":\"original\"}]}" },
        .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/original?format=metadata", .prefix = true, .body = try std.json.Stringify.valueAlloc(a, try browserMailFixture(a, "original", "original-thread", ""), .{}) },
    });
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.refresh", .account = account, .label = "INBOX" }, false));
    for (0..10) |page| {
        var rows: [30]Value = undefined;
        for (&rows, 0..) |*row, offset| row.* = try j.value(a, t.Message{ .id = try std.fmt.allocPrint(a, "retained-{d}", .{page * 30 + offset}), .threadId = "retained-thread", .receivedAt = @intCast(page * 30 + offset + 1), .labels = &.{"INBOX"} });
        try provider.cache.replaceList(0, &rows, 100);
    }
    try equal(@as(usize, 300), provider.cache.retained(0).len);
    const result = try data(try invoke(&provider, a, .{ .cmd = "mail.list", .account = account, .label = "INBOX" }, true));
    const returned = j.get(result, "messages").?.array.items;
    try equal(@as(usize, 30), returned.len);
    try expect(try j.boolean(result, "viewIncomplete", false));
    try expect(try j.boolean(result, "hasMoreCachedAfter", false));
    try strings("retained-299", j.text(returned[0], "id"));
    try verifyHost();
}

test "browser provider: list snapshot quota preserves the current decoded view and previous committed cache" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    const mime_type = try a.alloc(u8, 64 * 1024);
    @memset(mime_type, 'a');
    @memcpy(mime_type[0..12], "application/");
    const content_id = try a.alloc(u8, 1024);
    @memset(content_id, 'i');
    var files: [47]t.Attachment = undefined;
    for (&files, 0..) |*file, index| file.* = .{ .id = try std.fmt.allocPrint(a, "part-{d}", .{index}), .filename = "retained.bin", .mimeType = mime_type, .contentId = content_id };
    try provider.cache.saveRead(0, .{ .id = "quota-meta", .threadId = "quota-thread", .subject = "Before", .bodyText = "Prior body", .attachments = &files, .labels = &.{"INBOX"} });
    const before = try snapshot(&provider, a, 0);
    try expect(before.len > cache.snapshot_limit - 16 * 1024 and before.len <= cache.snapshot_limit);
    const revision = provider.cache.revision(0);
    const timestamp = provider.cache.updatedAt(0);
    const subject = try a.alloc(u8, 16 * 1024);
    @memset(subject, 's');
    var large = try browserMailFixture(a, "quota-meta", "quota-thread", "");
    try large.object.getPtr("payload").?.object.getPtr("headers").?.array.items[2].object.put(a, "value", .{ .string = subject });
    const large_response = try std.json.Stringify.valueAlloc(a, large, .{});
    const neighbor_response = try std.json.Stringify.valueAlloc(a, try browserMailFixture(a, "neighbor", "neighbor-thread", ""), .{});
    const listing: HttpStep = .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?", .prefix = true, .body = "{\"messages\":[{\"id\":\"quota-meta\"},{\"id\":\"neighbor\"}]}" };
    const large_step: HttpStep = .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/quota-meta?format=metadata", .prefix = true, .body = large_response };
    const neighbor_step: HttpStep = .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/neighbor?format=metadata", .prefix = true, .body = neighbor_response };
    resetHost(&.{ listing, large_step, neighbor_step, listing, large_step, neighbor_step });
    for ([_][]const u8{ "mail.refresh", "mail.list" }) |cmd| {
        const result = try data(try invoke(&provider, a, .{ .cmd = cmd, .account = account, .label = "INBOX" }, false));
        try expect(try j.boolean(result, "cacheWriteFailed", false));
        try expect(try j.boolean(result, "cacheReady", false));
        try expect(try j.boolean(result, "refreshCompleted", false));
        const returned = j.get(result, "messages").?.array.items;
        try equal(@as(usize, 2), returned.len);
        const current = try findBrowserMessage(returned, "quota-meta");
        try strings(subject, j.text(current, "subject"));
        try strings("BrowserCacheQuotaExceeded", j.text(current, "decodeWarning"));
        _ = try findBrowserMessage(returned, "neighbor");
        try equal(timestamp, try j.integer(result, "lastSyncAt", -1));
        try equal(revision, provider.cache.revision(0));
        try strings(before, try snapshot(&provider, a, 0));
        try strings("Prior body", (try provider.cache.read(0, "quota-meta")).?.bodyText);
    }
    try verifyHost();
}

test "browser provider: warm legacy header display is corrected without refetching a successful body" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, false, false);
    const old = snapshot_head ++ "\"messages\":[{\"id\":\"warm\",\"threadId\":\"thread\",\"from\":{\"address\":\"peer@example.test\",\"name\":\"Decoded\\tname\"},\"subject\":\"Warm\\nsubject\",\"bodyText\":\"Retained\\n\\tbody\",\"bodyCached\":true,\"labels\":[\"INBOX\"]}],\"contacts\":[],\"contactsLoaded\":false}";
    resetHost(&.{});
    try provider.cache.restore(0, old, false);
    for ([_]bool{ true, false }) |cached| {
        const opened = try data(try invoke(&provider, a, .{ .cmd = "mail.read", .account = account, .messageId = "warm" }, cached));
        try strings("Warm subject", j.text(opened, "subject"));
        try strings("Decoded name", j.text(j.get(opened, "from").?, "name"));
        try strings("Retained\n\tbody", j.text(opened, "bodyText"));
        try expect(try j.boolean(opened, "bodyCached", false));
        try strings("", j.text(opened, "bodyCacheError"));
    }
    try equal(@as(usize, 0), host.requests);
    try equal(@as(usize, 0), host.posts);
    try verifyHost();
}

test {
    _ = @import("browser_drafts_tests.zig");
}

const DraftRotationHost = struct {
    rows: [3]?[]u8 = @splat(null),
    revisions: [3]u32 = @splat(0),
    batch_commits: usize = 0,
    fail: bool = false,
    failure: ?anyerror = null,
    attempts: usize = 0,
    quota_failures: usize = 0,
    fn deinit(self: *@This()) void {
        for (self.rows) |row| if (row) |raw| std.testing.allocator.free(raw);
    }
    fn save(ctx: ?*anyopaque, _: u32, raw: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.attempts += 1;
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        const out = scratch.allocator();
        const value = try parse(out, raw);
        const batch = j.get(value, "updates");
        const single = [_]Value{value};
        const updates = if (batch) |items| items.array.items else &single;
        var next: [3]?[]u8 = @splat(null);
        defer for (next) |item| if (item) |bytes| std.testing.allocator.free(bytes);
        var revision = self.revisions;
        const actors = [_][]const u8{ account, "second@example.test", "third@example.test" };
        for (updates) |doc| {
            const index = find: {
                for (actors, 0..) |address, cursor| if (std.mem.eql(u8, address, j.text(doc, "account"))) break :find cursor;
                return error.UnknownAccount;
            };
            try equal(@as(i64, self.revisions[index]) + 1, try j.integer(doc, "revision", 0));
            if (next[index] != null) return error.DuplicateAccount;
            next[index] = try std.json.Stringify.valueAlloc(std.testing.allocator, doc, .{});
            revision[index] += 1;
        }
        var records: usize = 0;
        for (self.rows, 0..) |previous, index| {
            if (next[index] orelse previous) |bytes| {
                const doc = try parse(out, bytes);
                records += j.get(doc, "operations").?.array.items.len;
            }
        }
        if (records > 64) {
            self.quota_failures += 1;
            return error.BrowserDraftOperationQuota;
        }
        if (self.fail) return error.BrowserDraftStorageUnavailable;
        if (self.failure) |err| return err;
        for (&next, 0..) |*item, index| if (item.*) |bytes| {
            if (self.rows[index]) |previous| std.testing.allocator.free(previous);
            self.rows[index] = bytes;
            item.* = null;
        };
        self.revisions = revision;
        if (batch != null) self.batch_commits += 1;
    }
};

test "browser durable drafts: settled receipts rotate after reload and across actors without evicting unknown sends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var durable: DraftRotationHost = .{};
    defer durable.deinit();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    for ([_][]const u8{ account, "second@example.test", "third@example.test" }, 0..) |address, index| try actor(&provider, index, address, true, false);
    provider.draft_store = .{ .context = &durable, .saveFn = DraftRotationHost.save };
    const replies: [70]HttpStep = @splat(.{ .method = "POST", .url = send_url, .body = "{\"id\":\"sent123\"}" });
    resetHost(&replies);
    host.provider = &provider;
    for (0..70) |index| {
        const draft_id = try create(&provider, a, try std.fmt.allocPrint(a, "Settled durable body {d}", .{index}));
        const operation_id = try std.fmt.allocPrint(a, "durable-operation-{d}", .{index});
        host.expected_draft = draft_id;
        try outcome(try send(&provider, a, draft_id, operation_id), "applied");
        try acknowledgeReceipt(&provider, a, draft_id, operation_id, true);
        try equal(@as(usize, @min(64, index + 1)), provider.operation_count);
    }
    try verifyHost();
    const unknown = j.text(try data(try invoke(&provider, a, .{ .cmd = "draft.create", .account = "second@example.test", .draft = .{ .to = "peer@example.test", .bodyText = "Independent protected recovery" } }, false)), "id");
    resetHost(&.{.{ .method = "POST", .session = 12, .url = send_url, .result = 1 }});
    host.provider = &provider;
    host.expected_draft = unknown;
    const unknown_request = .{ .cmd = "draft.send", .account = "second@example.test", .draftId = unknown, .operationId = "retained-unknown" };
    try outcome(try invoke(&provider, a, unknown_request, false), "unknown");
    provider.client().sendReceipt(try std.json.Stringify.valueAlloc(a, unknown_request, .{}), false);
    try verifyHost();
    try equal(@as(usize, 64), provider.operation_count);
    var restored = Provider.init(std.testing.allocator);
    defer restored.deinit();
    for ([_][]const u8{ account, "second@example.test", "third@example.test" }, 0..) |address, index| {
        try actor(&restored, index, address, true, false);
        if (durable.rows[index]) |raw| try restored.restoreDrafts(index, raw);
    }
    restored.draft_store = .{ .context = &durable, .saveFn = DraftRotationHost.save };
    try equal(@as(usize, 64), restored.operation_count);
    try expect(restored.pendingUnknown() != null);
    const third_draft = j.text(try data(try invoke(&restored, a, .{ .cmd = "draft.create", .account = "third@example.test", .draft = .{ .to = "peer@example.test", .bodyText = "New third actor" } }, false)), "id");
    const third_request = .{ .cmd = "draft.send", .account = "third@example.test", .draftId = third_draft, .operationId = "third-actor-send" };
    const previous_first = try a.dupe(u8, durable.rows[0].?);
    const previous_third = try a.dupe(u8, durable.rows[2].?);
    durable.fail = true;
    resetHost(&.{});
    const rejected_send = try invoke(&restored, a, third_request, false);
    try outcome(rejected_send, "rejected");
    try strings("BrowserDraftStorageUnavailable", j.text(try data(rejected_send), "errorCode"));
    try equal(@as(usize, 64), restored.operation_count);
    try strings(previous_first, durable.rows[0].?);
    try strings(previous_third, durable.rows[2].?);
    try verifyHost();
    durable.fail = false;
    resetHost(&.{.{ .method = "POST", .session = 13, .url = send_url, .body = "{\"id\":\"third123\"}" }});
    host.provider = &restored;
    host.expected_draft = third_draft;
    try outcome(try invoke(&restored, a, third_request, false), "applied");
    restored.client().sendReceipt(try std.json.Stringify.valueAlloc(a, third_request, .{}), true);
    try verifyHost();
    try expect(durable.batch_commits >= 2);
    try equal(@as(usize, 64), restored.operation_count);
    try strings(unknown, restored.pendingUnknown().?.draft_id);
    try failure(try invoke(&restored, a, .{ .cmd = "draft.discard", .account = "second@example.test", .draftId = unknown }, false), "UnknownOutcome");
    var records: usize = 0;
    for (durable.rows) |row| if (row) |bytes| {
        records += j.get(try parse(a, bytes), "operations").?.array.items.len;
    };
    try equal(@as(usize, 64), records);
}

fn seedDraftHistory(a: A, durable: *DraftRotationHost, index: usize, count: usize, uncertain: bool) !void {
    const draft_storage = @import("browser_drafts.zig");
    const actors = [_][]const u8{ account, "second@example.test", "third@example.test" };
    const draft_id = try std.fmt.allocPrint(a, "protected-{d}", .{index});
    const receipts = try a.alloc(draft_storage.Receipt, count);
    for (receipts, 0..) |*receipt, cursor| receipt.* = .{
        .id = try std.fmt.allocPrint(a, "old-{d}-{d}", .{ index, cursor }),
        .draftId = if (uncertain and cursor == count - 1) draft_id else try std.fmt.allocPrint(a, "settled-draft-{d}", .{cursor}),
        .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .phase = .submitted,
        .outcome = if (uncertain and cursor == count - 1) .unknown else .applied,
    };
    const drafts = [_]t.Draft{.{ .id = draft_id, .subject = "Protected older recovery", .bodyText = "Kept unchanged" }};
    const document: draft_storage.Document = .{ .version = 1, .revision = 1, .account = actors[index], .clientId = client_id, .grantId = "", .drafts = if (uncertain) &drafts else &.{}, .operations = receipts };
    durable.rows[index] = try std.json.Stringify.valueAlloc(std.testing.allocator, document, .{ .emit_null_optional_fields = false });
    durable.revisions[index] = 1;
}

test "browser durable drafts: disconnected actor receipts trigger one bounded local retirement retry before POST" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var durable: DraftRotationHost = .{};
    defer durable.deinit();
    try seedDraftHistory(a, &durable, 0, 40, true);
    try seedDraftHistory(a, &durable, 1, 24, true);
    const disconnected = try a.dupe(u8, durable.rows[1].?);
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    try provider.restoreDrafts(0, durable.rows[0].?);
    provider.draft_store = .{ .context = &durable, .saveFn = DraftRotationHost.save };
    const draft_id = try create(&provider, a, "New send with one connected actor");
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"accepted123\"}" }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    const attempts = durable.attempts;
    try outcome(try send(&provider, a, draft_id, "only-connected-actor"), "applied");
    try equal(attempts + 2, durable.attempts);
    try equal(@as(usize, 1), durable.quota_failures);
    try acknowledgeReceipt(&provider, a, draft_id, "only-connected-actor", true);
    try verifyHost();
    try equal(@as(usize, 40), provider.operation_count);
    try strings("protected-0", provider.pendingUnknown().?.draft_id);
    try strings(disconnected, durable.rows[1].?);
    var count: usize = 0;
    for (durable.rows) |row| if (row) |raw| {
        count += j.get(try parse(a, raw), "operations").?.array.items.len;
    };
    try equal(@as(usize, 64), count);
    // A failed second transaction restores the full local journal and both
    // durable rows. Its error remains visible, with no provider request.
    const retry_id = try create(&provider, a, "Refused storage retry");
    const previous = try a.dupe(u8, durable.rows[0].?);
    const old_revision = provider.draft_revisions[0];
    durable.fail = true;
    resetHost(&.{});
    const rejected_send = try send(&provider, a, retry_id, "storage-retry-failed");
    try outcome(rejected_send, "rejected");
    try strings("BrowserDraftStorageUnavailable", j.text(try data(rejected_send), "errorCode"));
    try equal(@as(usize, 2), durable.quota_failures);
    try equal(@as(usize, 40), provider.operation_count);
    try equal(old_revision, provider.draft_revisions[0]);
    try strings(previous, durable.rows[0].?);
    try strings(disconnected, durable.rows[1].?);
    try strings("protected-0", provider.pendingUnknown().?.draft_id);
    try equal(@as(usize, 0), host.posts);
    try verifyHost();
}

test "browser durable drafts: transport no-POST proof survives stale receipt writes and consumer failure" {
    for ([_]u32{ 3, 4, 5, 1 }) |transport_result| for ([_]bool{ true, false }) |accepted| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var durable: DraftRotationHost = .{};
        defer durable.deinit();
        var provider = Provider.init(std.testing.allocator);
        defer provider.deinit();
        try actor(&provider, 0, account, true, false);
        provider.draft_store = .{ .context = &durable, .saveFn = DraftRotationHost.save };
        const draft_id = try create(&provider, a, "Cancelled or unconfirmed exact send");
        resetHost(&.{.{ .method = "POST", .url = send_url, .result = transport_result }});
        host.provider = &provider;
        host.expected_draft = draft_id;
        host.draft_receipt_failure = &durable.failure;
        const possibly_submitted = transport_result == 1;
        try outcome(try send(&provider, a, draft_id, "transport-proof"), if (possibly_submitted) "unknown" else "rejected");
        try equal(possibly_submitted, provider.live_sessions[0].send_possible_submission);
        const boundary: live.SendBoundary = if (transport_result == 5) .marked else if (possibly_submitted) .submitted else .none;
        const phase: @import("browser_drafts.zig").Phase = if (transport_result == 3 or transport_result == 4) .paused else .submitted;
        try equal(boundary, provider.live_sessions[0].send_boundary);
        try equal(phase, provider.operations[0].phase);
        try acknowledgeReceipt(&provider, a, draft_id, "transport-proof", accepted);
        try equal(possibly_submitted, provider.pendingUnknown() != null);
        try equal(@as(u32, if (possibly_submitted) 2 else 3), provider.sendStatus());
        try verifyHost();
        // The failed receipt transaction leaves the durable pending copy;
        // the live editor still distinguishes a proven refusal from a POST.
        const persisted = try parse(a, durable.rows[0].?);
        try strings("unknown", j.text(j.get(persisted, "operations").?.array.items[0], "outcome"));
        durable.failure = null;
        const edit = .{ .cmd = "draft.update", .account = account, .draftId = draft_id, .draft = .{ .subject = "Retained editable work" } };
        if (possibly_submitted) try failure(try invoke(&provider, a, edit, false), "UnknownOutcome") else _ = try data(try invoke(&provider, a, edit, false));
    };
}

test "browser durable drafts: pre-POST cause survives receipt encoding and allocation failure stays definitely rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var durable: DraftRotationHost = .{};
    defer durable.deinit();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    provider.draft_store = .{ .context = &durable, .saveFn = DraftRotationHost.save };
    const draft_id = try create(&provider, a, "Typed storage rejection");
    resetHost(&.{});
    for ([_]anyerror{ error.BrowserDraftQuota, error.BrowserDraftStorageUnavailable, error.BrowserDraftStorageConflict, error.BrowserDraftOperationQuota }) |cause| {
        durable.failure = cause;
        const result = try send(&provider, a, draft_id, "preflight-storage-cause");
        try outcome(result, "rejected");
        try strings(@errorName(cause), j.text(try data(result), "errorCode"));
        try equal(@as(usize, 0), provider.operation_count);
        try expect(provider.pendingUnknown() == null);
    }
    try verifyHost();
    durable.failure = null;
    resetHost(&.{.{ .method = "POST", .url = send_url, .result = 3 }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    host.draft_receipt_failure = &durable.failure;
    var failing_output: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const request = try std.json.Stringify.valueAlloc(a, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "failed-local-receipt-allocation" }, .{});
    try std.testing.expectError(error.SendNotStarted, provider.client().call(failing_output.allocator(), request));
    provider.client().sendReceipt(request, false);
    try expect(provider.pendingUnknown() == null);
    try equal(@as(u32, 3), provider.sendStatus());
    try expect(!provider.operations[0].awaiting_receipt);
    try verifyHost();
}

test "browser durable drafts: a quota retry can retire another connected actor atomically without revision drift" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var durable: DraftRotationHost = .{};
    defer durable.deinit();
    try seedDraftHistory(a, &durable, 1, 24, false);
    try seedDraftHistory(a, &durable, 2, 40, true);
    const unconnected = try a.dupe(u8, durable.rows[2].?);
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, 0, account, true, false);
    try actor(&provider, 1, "second@example.test", true, false);
    try provider.restoreDrafts(1, durable.rows[1].?);
    provider.draft_store = .{ .context = &durable, .saveFn = DraftRotationHost.save };
    const draft_id = try create(&provider, a, "First send by new actor");
    resetHost(&.{.{ .method = "POST", .url = send_url, .body = "{\"id\":\"newactor123\"}" }});
    host.provider = &provider;
    host.expected_draft = draft_id;
    try outcome(try send(&provider, a, draft_id, "new-actor-with-loaded-history"), "applied");
    try acknowledgeReceipt(&provider, a, draft_id, "new-actor-with-loaded-history", true);
    try verifyHost();
    try equal(@as(usize, 1), durable.quota_failures);
    try equal(@as(usize, 1), durable.batch_commits);
    try equal(@as(usize, 24), provider.operation_count);
    try equal(@as(u32, 2), provider.draft_revisions[1]);
    try equal(provider.draft_revisions[1], durable.revisions[1]);
    try strings(unconnected, durable.rows[2].?);
    _ = try data(try invoke(&provider, a, .{ .cmd = "draft.create", .account = "second@example.test", .draft = .{ .subject = "Loaded actor stays writable" } }, false));
    try equal(@as(u32, 3), provider.draft_revisions[1]);
    try equal(provider.draft_revisions[1], durable.revisions[1]);
}
