//! Literal synthetic provider fixtures exercise the browser ABI and the same
//! mailbox domain used by the native TUI. No real Google requests are made.
const std = @import("std");
const Provider = @import("browser_provider.zig").Provider;
const live = @import("browser_live.zig");
const auth = @import("terminal/auth.zig");
const j = @import("terminal/json.zig");
const A = std.mem.Allocator;
const V = j.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const account = "ada@example.test";
const client_id = "synthetic.apps.googleusercontent.com";
const nonce = "12345678-1234-4234-8234-123456789abc";
const root = "https://gmail.googleapis.com/gmail/v1/users/me/";
const definitions = "{\"labels\":[{\"id\":\"INBOX\",\"name\":\"INBOX\",\"type\":\"system\"},{\"id\":\"Label_old\",\"name\":\"Project\",\"type\":\"user\"}]}";
const Step = struct { method: []const u8 = "GET", url: []const u8, body: []const u8 = "{}", expected: ?[]const u8 = null, status: u32 = 200, result: u32 = 0 };
var steps: []const Step = &.{};
var cursor: usize = 0;
var violations: bool = false;
var writes: usize = 0;
export fn now_ms() f64 {
    return 1791730000000;
}
export fn http_request(session: u32, method_ptr: usize, method_len: usize, url_ptr: usize, url_len: usize, body_ptr: usize, body_len: usize, response_ptr: usize, capacity: usize, metadata_ptr: usize) u32 {
    const method = @as([*]const u8, @ptrFromInt(method_ptr))[0..method_len];
    const url = @as([*]const u8, @ptrFromInt(url_ptr))[0..url_len];
    const body = @as([*]const u8, @ptrFromInt(body_ptr))[0..body_len];
    if (!std.mem.eql(u8, method, "GET")) writes += 1;
    if (cursor == steps.len) {
        violations = true;
        return 1;
    }
    const step = steps[cursor];
    cursor += 1;
    if (session != 11 or !std.mem.eql(u8, step.method, method) or !std.mem.eql(u8, step.url, url) or step.body.len > capacity) violations = true;
    if (step.expected) |expected| {
        if (!std.mem.eql(u8, body, expected)) violations = true;
    }
    if (step.body.len > capacity) return 2;
    @memcpy(@as([*]u8, @ptrFromInt(response_ptr))[0..step.body.len], step.body);
    @as(*[2]u32, @ptrFromInt(metadata_ptr)).* = .{ step.status, @intCast(step.body.len) };
    return step.result;
}
fn reset(input: []const Step) void {
    steps = input;
    cursor = 0;
    violations = false;
    writes = 0;
}
fn checked() !void {
    try expect(!violations);
    try equal(steps.len, cursor);
}
fn actor(provider: *Provider, can_modify: bool) !void {
    provider.live_sessions[0] = .{ .id = 11, .nonce = nonce, .account = account, .client_id = client_id, .grant_id = "", .can_send = false, .can_modify = can_modify };
    provider.live_count = 1;
    try provider.cache.bind(0, .{ .account = account, .clientId = client_id, .grantId = "" });
}
fn invoke(provider: *Provider, a: A, request: anytype, cached: bool) !V {
    const encoded = try std.json.Stringify.valueAlloc(a, request, .{});
    const response = if (cached) try provider.client().callCached(a, encoded) else try provider.client().call(a, encoded);
    return std.json.parseFromSliceLeaky(V, a, response, .{});
}
fn data(value: V) !V {
    try expect(try j.boolean(value, "ok", false));
    return j.get(value, "data") orelse error.MissingData;
}
fn failure(value: V, code: []const u8) !void {
    try expect(!try j.boolean(value, "ok", true));
    try strings(code, j.text(j.get(value, "error").?, "code"));
}
fn cachedRows(provider: *Provider, a: A) !void {
    const values = try j.value(a, .{
        .{ .id = "m1", .threadId = "thread", .subject = "First synthetic", .bodyText = "Retained first body", .bodyCached = true, .labels = &.{ "INBOX", "UNREAD", "Label_old" } },
        .{ .id = "m2", .threadId = "thread", .subject = "Second synthetic", .bodyText = "Retained second body", .bodyCached = true, .labels = &.{"INBOX"} },
    });
    try provider.cache.replaceList(0, values.array.items, 1);
}
fn cachedHas(provider: *Provider, id: []const u8, label: []const u8) bool {
    for (provider.cache.retained(0)) |message| if (std.mem.eql(u8, id, message.id)) {
        for (message.labels) |value| if (std.mem.eql(u8, value, label)) return true;
    };
    return false;
}

test "browser mailbox: actual grant scope controls modify and read-only calls reject writes before HTTP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |actual_modify| {
        const scopes = [_][]const u8{"https://www.googleapis.com/auth/gmail.modify"};
        const metadata = try std.json.Stringify.valueAlloc(a, .{ .session = 11, .nonce = nonce, .account = account, .clientId = client_id, .grantId = &auth.grantIdentity(&scopes), .capabilities = &.{ "mail-read", "mail-modify" }, .scopes = scopes, .actualScopes = if (actual_modify) &scopes else &[_][]const u8{"https://www.googleapis.com/auth/gmail.readonly"} }, .{});
        reset(&.{.{ .url = root ++ "profile?fields=emailAddress", .body = "{\"emailAddress\":\"ada@example.test\"}" }});
        const connected = try live.connect(a, metadata);
        try equal(actual_modify, connected.can_modify);
        try expect(!connected.can_send);
        try checked();
    }
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, false);
    reset(&.{});
    try failure(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "trash", .messageIds = &.{"m1"} }, false), "PermissionDenied");
    try failure(try invoke(&provider, a, .{ .cmd = "labels.create", .account = account, .name = "New", .operationId = "label-1" }, false), "PermissionDenied");
    provider.live_sessions[0].can_modify = true;
    try failure(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "trash", .messageIds = &.{"m1"} }, true), "CacheUnsupported");
    try failure(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "trash", .messageIds = &.{ "m1", "m1" } }, false), "DuplicateMessage");
    try checked();
}

test "browser mailbox: batch receipts isolate read preflight failure and undo preserves concurrent membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"UNREAD\",\"Label_old\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .expected = "{\"addLabelIds\":[],\"removeLabelIds\":[\"INBOX\"]}", .body = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\",\"Label_old\"]}" },
        .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .result = 1 },
    });
    const receipt = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "archive", .messageIds = &.{ "m1", "m2" } }, false));
    try equal(@as(i64, 1), try j.integer(receipt, "appliedCount", 0));
    const outcomes = j.get(receipt, "outcomes").?.array.items;
    try strings("applied", j.text(outcomes[0], "outcome"));
    try strings("rejected", j.text(outcomes[1], "outcome"));
    try strings("NetworkFailure", j.text(outcomes[1], "errorCode"));
    try expect(!cachedHas(&provider, "m1", "INBOX") and cachedHas(&provider, "m2", "INBOX"));
    try expect(provider.pendingUnknown() == null);
    try equal(@as(u32, 0), provider.sendStatus());
    try checked();
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\",\"Label_old\",\"Label_concurrent\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .expected = "{\"addLabelIds\":[\"INBOX\"],\"removeLabelIds\":[]}", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"UNREAD\",\"Label_old\",\"Label_concurrent\"]}" },
    });
    const undone = try data(try invoke(&provider, a, .{ .cmd = "mail.undo", .account = account, .undoToken = j.text(receipt, "undoToken") }, false));
    try equal(@as(i64, 1), try j.integer(undone, "restoredCount", 0));
    try expect(cachedHas(&provider, "m1", "INBOX") and cachedHas(&provider, "m1", "Label_concurrent"));
    try strings("Retained first body", (try provider.cache.read(0, "m1")).?.bodyText);
    try checked();
}

test "browser mailbox: unknown modification and unknown undo never replay and preserve cached membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .result = 1 },
    });
    const request = .{ .cmd = "mail.batch", .account = account, .action = "spam", .messageIds = &.{"m1"} };
    const receipt = try data(try invoke(&provider, a, request, false));
    try strings("unknown", j.text(j.get(receipt, "outcomes").?.array.items[0], "outcome"));
    try expect(cachedHas(&provider, "m1", "INBOX") and !cachedHas(&provider, "m1", "SPAM"));
    try checked();
    reset(&.{});
    const replay = try data(try invoke(&provider, a, request, false));
    try strings(j.text(receipt, "undoToken"), j.text(replay, "undoToken"));
    try failure(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "restore", .messageIds = &.{"m1"} }, false), "UnknownOutcome");
    _ = try data(try invoke(&provider, a, .{ .cmd = "mail.undo", .account = account, .undoToken = j.text(receipt, "undoToken") }, false));
    try checked();
    reset(&.{
        .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m2/modify?fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\",\"STARRED\"]}" },
    });
    const starred = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "mark", .starred = true, .messageIds = &.{"m2"} }, false));
    try checked();
    reset(&.{
        .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\",\"STARRED\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m2/modify?fields=id,labelIds", .result = 1 },
    });
    const undo_request = .{ .cmd = "mail.undo", .account = account, .undoToken = j.text(starred, "undoToken") };
    const failed_undo = try data(try invoke(&provider, a, undo_request, false));
    try strings("UnknownOutcome", j.text(j.get(failed_undo, "outcomes").?.array.items[0], "errorCode"));
    try equal(@as(i64, 1), try j.integer(failed_undo, "appliedCount", 0));
    try equal(@as(i64, 0), try j.integer(failed_undo, "restoredCount", 0));
    try expect(try j.boolean(failed_undo, "partial", false));
    try expect(cachedHas(&provider, "m2", "STARRED"));
    try checked();
    reset(&.{});
    const replayed_undo = try data(try invoke(&provider, a, undo_request, false));
    try expect(try j.boolean(replayed_undo, "partial", false));
    try checked();
}

test "browser mailbox: canceled preflight and definite provider rejection remain retryable per item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    for ([_]Step{
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .result = 4 },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .result = 3 },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .status = 403 },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"TRASH\"]}" },
    }, 0..) |step, n| {
        const calls = [_]Step{ .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\"]}" }, step };
        reset(&calls);
        const receipt = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "trash", .messageIds = &.{"m1"} }, false));
        try strings(if (n == 3) "applied" else "rejected", j.text(j.get(receipt, "outcomes").?.array.items[0], "outcome"));
        if (n < 2) try expect(!provider.live_sessions[0].mailbox_submitted);
        if (n == 1) try strings("NotConnected", j.text(j.get(receipt, "outcomes").?.array.items[0], "errorCode"));
        try checked();
    }
}

test "browser mailbox: label management uses native validation receipts and keeps messages after delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    reset(&.{.{ .url = root ++ "labels?fields=labels(id,name,type,color)", .body = definitions }});
    _ = try data(try invoke(&provider, a, .{ .cmd = "labels.list", .account = account }, false));
    try checked();
    reset(&.{
        .{ .url = root ++ "labels?fields=labels(id,name,type,color)", .body = definitions },
        .{ .method = "PATCH", .url = root ++ "labels/Label_old", .expected = "{\"name\":\"Renamed\"}", .body = "{\"id\":\"Label_old\",\"name\":\"Renamed\",\"type\":\"user\"}" },
    });
    const request = .{ .cmd = "labels.rename", .account = account, .labelId = "Label_old", .name = "Renamed", .operationId = "rename-1" };
    const renamed = try data(try invoke(&provider, a, request, false));
    try strings("applied", j.text(renamed, "outcome"));
    try checked();
    reset(&.{});
    _ = try data(try invoke(&provider, a, request, false));
    const list = try data(try invoke(&provider, a, .{ .cmd = "labels.list", .account = account }, true));
    try strings("Renamed", j.text(j.get(list, "labels").?.array.items[1], "name"));
    try failure(try invoke(&provider, a, .{ .cmd = "labels.rename", .account = account, .labelId = "Label_old", .name = "Other", .operationId = "rename-1" }, false), "OperationConflict");
    try checked();
    reset(&.{
        .{ .url = root ++ "labels?fields=labels(id,name,type,color)", .body = "{\"labels\":[{\"id\":\"Label_old\",\"name\":\"Renamed\",\"type\":\"user\"}]}" },
        .{ .method = "DELETE", .url = root ++ "labels/Label_old", .expected = "", .status = 204, .body = "" },
    });
    const deleted = try data(try invoke(&provider, a, .{ .cmd = "labels.delete", .account = account, .labelId = "Label_old", .confirmName = "Renamed", .operationId = "delete-1" }, false));
    try strings("applied", j.text(deleted, "outcome"));
    try expect(try j.boolean(deleted, "deleted", false));
    try expect(!cachedHas(&provider, "m1", "Label_old") and cachedHas(&provider, "m1", "INBOX"));
    try strings("Retained first body", (try provider.cache.read(0, "m1")).?.bodyText);
    try checked();
}

test "browser mailbox: unknown collection writes retain exact operation receipts and cannot resubmit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    reset(&.{
        .{ .url = root ++ "labels?fields=labels(id,name,type,color)", .body = definitions },
        .{ .method = "POST", .url = root ++ "labels", .result = 1 },
    });
    const created = try data(try invoke(&provider, a, .{ .cmd = "labels.create", .account = account, .name = "New Project", .operationId = "create-1" }, false));
    try strings("unknown", j.text(created, "outcome"));
    try checked();
    reset(&.{});
    const replay = try data(try invoke(&provider, a, .{ .cmd = "labels.create", .account = account, .name = "New Project", .operationId = "create-2" }, false));
    try strings("create-1", j.text(replay, "operationId"));
    const inspected = try data(try invoke(&provider, a, .{ .cmd = "operation.read", .account = account, .operationId = "create-1" }, false));
    try strings("unknown", j.text(inspected, "outcome"));
    try equal(@as(u32, 0), provider.sendStatus());
    try checked();
}

test "browser mailbox: exact conversation review targets and membership counts share the native protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,threadId", .body = "{\"id\":\"m1\",\"threadId\":\"thread\"}" },
        .{ .url = root ++ "threads/thread?format=minimal&fields=id,messages(id,threadId)", .body = "{\"id\":\"thread\",\"messages\":[{\"id\":\"m1\",\"threadId\":\"thread\"},{\"id\":\"m2\",\"threadId\":\"thread\"}]}" },
    });
    const resolved = try data(try invoke(&provider, a, .{ .cmd = "mail.triage-scope", .account = account, .messageId = "m1", .scope = "conversation" }, false));
    const ids = try j.decode([]const []const u8, a, j.get(resolved, "messageIds").?);
    try equal(@as(usize, 2), ids.len);
    try strings("m2", ids[1]);
    try expect(try j.boolean(resolved, "complete", false));
    try checked();
    reset(&.{
        .{ .url = root ++ "labels?fields=labels(id,name,type,color)", .body = definitions },
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"Label_old\"]}" },
        .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\"]}" },
    });
    const state = try data(try invoke(&provider, a, .{ .cmd = "mail.label-state", .account = account, .messageIds = ids }, false));
    const labels = j.get(state, "labels").?.array.items;
    try equal(@as(i64, 2), try j.integer(labels[0], "appliedCount", 0));
    try equal(@as(i64, 1), try j.integer(labels[1], "appliedCount", 0));
    try checked();
    // A newly arrived conversation member cannot enter this explicit review.
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"SPAM\"]}" },
        .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m2/modify?fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"SPAM\"]}" },
    });
    const receipt = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .messageIds = ids, .action = "spam" }, false));
    try equal(@as(i64, 2), try j.integer(receipt, "appliedCount", 0));
    try checked();
}

test "browser mailbox: restore not-spam read unread and star removal submit the shared native deltas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    const Case = struct { request: []const u8, before: []const u8, expected: []const u8, after: []const u8 };
    for ([_]Case{
        .{ .request = "{\"action\":\"restore\"}", .before = "[\"TRASH\"]", .expected = "{\"addLabelIds\":[\"INBOX\"],\"removeLabelIds\":[\"TRASH\"]}", .after = "[\"INBOX\"]" },
        .{ .request = "{\"action\":\"unspam\"}", .before = "[\"SPAM\"]", .expected = "{\"addLabelIds\":[\"INBOX\"],\"removeLabelIds\":[\"SPAM\"]}", .after = "[\"INBOX\"]" },
        .{ .request = "{\"action\":\"mark\",\"unread\":false}", .before = "[\"INBOX\",\"UNREAD\"]", .expected = "{\"addLabelIds\":[],\"removeLabelIds\":[\"UNREAD\"]}", .after = "[\"INBOX\"]" },
        .{ .request = "{\"action\":\"mark\",\"unread\":true}", .before = "[\"INBOX\"]", .expected = "{\"addLabelIds\":[\"UNREAD\"],\"removeLabelIds\":[]}", .after = "[\"INBOX\",\"UNREAD\"]" },
        .{ .request = "{\"action\":\"mark\",\"starred\":false}", .before = "[\"INBOX\",\"STARRED\"]", .expected = "{\"addLabelIds\":[],\"removeLabelIds\":[\"STARRED\"]}", .after = "[\"INBOX\"]" },
    }) |case| {
        var request = try std.json.parseFromSliceLeaky(V, a, case.request, .{});
        try request.object.put(a, "cmd", .{ .string = "mail.batch" });
        try request.object.put(a, "account", .{ .string = account });
        try request.object.put(a, "messageIds", try j.value(a, [_][]const u8{"m1"}));
        const calls = [_]Step{
            .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = try std.fmt.allocPrint(a, "{{\"id\":\"m1\",\"labelIds\":{s}}}", .{case.before}) },
            .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .expected = case.expected, .body = try std.fmt.allocPrint(a, "{{\"id\":\"m1\",\"labelIds\":{s}}}", .{case.after}) },
        };
        reset(&calls);
        const receipt = try data(try invoke(&provider, a, request, false));
        try equal(@as(i64, 1), try j.integer(receipt, "appliedCount", 0));
        try checked();
    }
}

test "browser mailbox: custom label assignment resolves provider IDs before saving the native inverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    const collection = "{\"labels\":[{\"id\":\"Label_old\",\"name\":\"Project\",\"type\":\"user\"},{\"id\":\"Label_next\",\"name\":\"Next\",\"type\":\"user\"}]}";
    reset(&.{
        .{ .url = root ++ "labels?fields=labels(id,name,type)", .body = collection },
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"Label_old\"]}" },
        .{ .url = root ++ "labels?fields=labels(id,name,type)", .body = collection },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .expected = "{\"addLabelIds\":[\"Label_next\"],\"removeLabelIds\":[\"Label_old\"]}", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"Label_next\"]}" },
    });
    const receipt = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "mark", .messageIds = &.{"m1"}, .addLabels = &.{"Next"}, .removeLabels = &.{"Project"} }, false));
    const item = j.get(receipt, "outcomes").?.array.items[0];
    try strings("applied", j.text(item, "outcome"));
    try strings("Label_old", try j.string(j.get(item, "addLabels").?.array.items[0]));
    try strings("Label_next", try j.string(j.get(item, "removeLabels").?.array.items[0]));
    try expect(cachedHas(&provider, "m1", "Label_next") and !cachedHas(&provider, "m1", "Label_old"));
    try checked();
}

test "browser mailbox: a malformed successful mutation receipt is unknown and cannot change the cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .body = "{\"id\":\"other-message\",\"labelIds\":[\"TRASH\"]}" },
    });
    const receipt = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "trash", .messageIds = &.{"m1"} }, false));
    try strings("unknown", j.text(j.get(receipt, "outcomes").?.array.items[0], "outcome"));
    try expect(cachedHas(&provider, "m1", "INBOX") and !cachedHas(&provider, "m1", "TRASH"));
    try checked();
}

test "browser mailbox: settled actions rotate within sixty-four receipts while unknown and latest undo stay pinned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    reset(&.{
        .{ .url = root ++ "labels?fields=labels(id,name,type,color)", .body = definitions },
        .{ .method = "POST", .url = root ++ "labels", .result = 1 },
    });
    _ = try data(try invoke(&provider, a, .{ .cmd = "labels.create", .account = account, .name = "Unresolved", .operationId = "uncertain" }, false));
    try checked();
    var latest: []const u8 = "";
    for (0..70) |_| {
        reset(&.{
            .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\"]}" },
            .{ .method = "POST", .url = root ++ "messages/m2/modify?fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\",\"UNREAD\"]}" },
        });
        const result = try data(try invoke(&provider, a, .{ .cmd = "mail.batch", .account = account, .action = "mark", .unread = true, .messageIds = &.{"m2"} }, false));
        try equal(@as(i64, 1), try j.integer(result, "appliedCount", 0));
        latest = j.text(result, "undoToken");
        try checked();
    }
    try equal(@as(usize, 64), provider.mail_actions.count);
    try expect(provider.mail_actions.bytes <= 2 * 1024 * 1024);
    reset(&.{});
    const original = try data(try invoke(&provider, a, .{ .cmd = "labels.create", .account = account, .name = "Unresolved", .operationId = "try-new-identity" }, false));
    try strings("uncertain", j.text(original, "operationId"));
    try strings("unknown", j.text(original, "outcome"));
    try checked();
    reset(&.{
        .{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\",\"UNREAD\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m2/modify?fields=id,labelIds", .expected = "{\"addLabelIds\":[],\"removeLabelIds\":[\"UNREAD\"]}", .body = "{\"id\":\"m2\",\"labelIds\":[\"INBOX\"]}" },
    });
    const undone = try data(try invoke(&provider, a, .{ .cmd = "mail.undo", .account = account, .undoToken = latest }, false));
    try equal(@as(i64, 1), try j.integer(undone, "restoredCount", 0));
    try checked();
}

test "browser mailbox: direct native commands project message and membership replies without another workflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try actor(&provider, true);
    try cachedRows(&provider, a);
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"UNREAD\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\"]}" },
    });
    const archived = try data(try invoke(&provider, a, .{ .cmd = "mail.archive", .account = account, .messageId = "m1" }, false));
    try strings("m1", j.text(archived, "id"));
    try strings("Retained first body", j.text(archived, "bodyText"));
    try expect(j.get(archived, "outcomes") == null);
    try checked();
    reset(&.{
        .{ .url = root ++ "messages/m1?format=minimal&fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\"]}" },
        .{ .method = "POST", .url = root ++ "messages/m1/modify?fields=id,labelIds", .body = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\",\"STARRED\"]}" },
    });
    const modified = try data(try invoke(&provider, a, .{ .cmd = "mail.modify-labels", .account = account, .messageId = "m1", .addLabels = &.{"STARRED"} }, false));
    try strings("m1", j.text(modified, "messageId"));
    try equal(@as(usize, 2), j.get(modified, "labels").?.array.items.len);
    try expect(j.get(modified, "outcomes") == null);
    try checked();
    reset(&.{.{ .url = root ++ "messages/m2?format=minimal&fields=id,labelIds", .result = 1 }});
    try failure(try invoke(&provider, a, .{ .cmd = "mail.mark", .account = account, .messageId = "m2", .starred = true }, false), "NetworkFailure");
    try checked();
    reset(&.{
        .{ .url = root ++ "messages/uncached?format=minimal&fields=id,labelIds", .body = "{\"id\":\"uncached\",\"labelIds\":[\"INBOX\"]}" },
        .{ .method = "POST", .url = root ++ "messages/uncached/modify?fields=id,labelIds", .body = "{\"id\":\"uncached\",\"labelIds\":[]}" },
        .{ .url = root ++ "messages/uncached?format=full", .result = 1 },
    });
    const missing = .{ .cmd = "mail.archive", .account = account, .messageId = "uncached" };
    try failure(try invoke(&provider, a, missing, false), "UnknownOutcome");
    try checked();
    reset(&.{});
    try failure(try invoke(&provider, a, missing, false), "UnknownOutcome");
    try checked();
}
