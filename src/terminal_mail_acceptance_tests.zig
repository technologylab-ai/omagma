const std = @import("std");
const gmail = @import("terminal/gmail.zig");
const core = @import("terminal/core.zig");
const storage = @import("terminal/store.zig");
const batch = @import("terminal/batch.zig");
const triage = @import("terminal/triage.zig");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");

// Hand-written provider responses: neither the MIME encoder nor the ordinary
// fixture generator produces these inputs or the expected readable strings.
// The attachment has fictional bytes and a realistic descriptor, not a real
// Office document. Its opaque token must survive the provider/cache/UI handoff.
const delivered =
    \\{"id":"same-message","threadId":"same-thread","internalDate":"42","labelIds":["INBOX","UNREAD"],"snippet":"Fictional attachment handoff","payload":{"mimeType":"multipart/mixed","filename":"","headers":[{"name":"From","value":"Sender <sender@example.test>"},{"name":"To","value":"personal@example.com"},{"name":"Subject","value":"Attachment handoff café"}],"body":{"size":0},"parts":[{"mimeType":"multipart/alternative","filename":"","headers":[],"body":{"size":0},"parts":[{"mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=utf-8"},{"name":"Content-Transfer-Encoding","value":"base64"}],"body":{"size":16,"data":"UGxhaW4gY2Fmw6kuCg"}},{"mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=utf-8"},{"name":"Content-Transfer-Encoding","value":"base64"}],"body":{"size":21,"data":"PHA-SFRNTCBjYWbDqS48L3A-"}}]},{"partId":"1","mimeType":"application/vnd.openxmlformats-officedocument.presentationml.presentation","filename":"Quarterly café.pptx","headers":[{"name":"Content-Disposition","value":"attachment"}],"body":{"size":17,"attachmentId":"pptx-token/+=="}}]}}
;
const other_delivered =
    \\{"id":"same-message","threadId":"same-thread","internalDate":"43","labelIds":["INBOX"],"payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Other <other@example.test>"},{"name":"To","value":"work@example.com"},{"name":"Subject","value":"Other account"}],"body":{"size":20,"data":"T3RoZXIgYWNjb3VudCBvbmx5Lgo"}}}
;
const refreshed_metadata =
    \\{"id":"same-message","threadId":"same-thread","internalDate":"42","labelIds":["INBOX","STARRED"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"Sender <sender@example.test>"},{"name":"To","value":"personal@example.com"},{"name":"Subject","value":"Attachment handoff café"}]}}
;
const full_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/same-message?format=full";
const membership_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/same-message?format=minimal&fields=id,labelIds";
const modify_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/same-message/modify?fields=id,labelIds";
const attachment_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/same-message/attachments/pptx-token%2F%2B%3D%3D";

const Step = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    body: ?[]const u8 = null,
    response: []const u8,
};
const Peer = struct {
    steps: []const Step,
    calls: usize = 0,
    writes: usize = 0,

    fn transport(self: *Peer) gmail.Transport {
        return .{ .context = self, .requestFn = request };
    }
    fn request(context: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *Peer = @ptrCast(@alignCast(context));
        if (method != .GET) self.writes += 1;
        if (self.calls == self.steps.len) return error.UnexpectedAcceptanceRequest;
        const step = self.steps[self.calls];
        self.calls += 1;
        try std.testing.expectEqual(step.method, method);
        try std.testing.expectEqualStrings(step.url, url);
        if (step.body) |expected| {
            try std.testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(a, body orelse return error.MissingRequestBody, .{}));
        } else try std.testing.expect(body == null);
        return std.json.parseFromSliceLeaky(j.Value, a, step.response, .{});
    }
    fn complete(self: Peer, writes: usize) !void {
        try std.testing.expectEqual(self.steps.len, self.calls);
        try std.testing.expectEqual(writes, self.writes);
    }
};

fn readProvider(a: std.mem.Allocator, account: []const u8, peer: *Peer) !t.Message {
    return j.decode(t.Message, a, try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-read"}, peer.transport(), "mail.read", try j.value(a, .{ .messageId = "same-message" })));
}
fn expectDelivered(message: t.Message) !void {
    try std.testing.expectEqualStrings("same-message", message.id);
    try std.testing.expectEqualStrings("same-thread", message.threadId);
    try std.testing.expectEqualStrings("Plain café.\n", message.bodyText);
    try std.testing.expectEqualStrings("<p>HTML café.</p>", message.bodyHtml orelse return error.MissingHtml);
    try std.testing.expectEqual(t.BodySource.plain, message.bodySource);
    try std.testing.expect(!message.bodyHtmlAmbiguous);
    try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
    const attachment = message.attachments[0];
    try std.testing.expectEqualStrings("pptx-token/+==", attachment.id);
    try std.testing.expectEqualStrings("Quarterly café.pptx", attachment.filename);
    try std.testing.expectEqualStrings("application/vnd.openxmlformats-officedocument.presentationml.presentation", attachment.mimeType);
    try std.testing.expectEqual(@as(usize, 17), attachment.size);
    try std.testing.expectEqualStrings("", attachment.data);
}
fn has(labels: []const []const u8, wanted: []const u8) bool {
    for (labels) |label| if (std.mem.eql(u8, label, wanted)) return true;
    return false;
}

fn seed(root: []const u8, account: []const u8, wire: []const u8) ![64]u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = wire }} };
    const message = try readProvider(a, account, &peer);
    try peer.complete(0); // Reading does not fetch the unopened binary attachment.
    var store = try storage.Store.open(std.testing.io, a, root, account, .{});
    defer store.close();
    try store.put(message, false);
    try std.testing.expect(try store.putBody(message));
    try store.save();
    var hash: [64]u8 = undefined;
    @memcpy(&hash, store.find("same-message").?.bodyHash);
    return hash;
}

// Use the actual cache-only client consumed by the TUI. It has production cache
// namespacing and two configured fictional accounts, without a network session,
// desktop environment, credentials, or a fixture-mode branch.
fn newCachedSession(a: std.mem.Allocator, root: []const u8, env: *const std.process.Environ.Map) !*core.Session {
    const session = try a.create(core.Session);
    errdefer a.destroy(session);
    session.* = .{ .io = std.testing.io, .allocator = a, .options = .{ .grant_file = "unused-acceptance-grants.json" }, .config = .{}, .cache_root = try a.dupe(u8, root), .env = env };
    errdefer session.deinit();
    try session.config.defaults("/unused-acceptance-home");
    return session;
}
fn cached(a: std.mem.Allocator, session: *core.Session, account: []const u8, command: []const u8) !j.Value {
    const request = try std.json.Stringify.valueAlloc(a, .{ .id = "acceptance", .cmd = command, .account = account, .messageId = "same-message", .threadId = "same-thread" }, .{});
    const response = try std.json.parseFromSliceLeaky(j.Value, a, try session.client().callCached(a, request), .{});
    try std.testing.expect(try j.boolean(response, "ok", false));
    try std.testing.expectEqualStrings(account, j.text(response, "account"));
    try std.testing.expectEqualStrings("acceptance", j.text(response, "id"));
    return j.get(response, "data") orelse error.MissingResponseData;
}

test "mail acceptance: provider body and attachment survive metadata refresh into two account cached readers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mail-acceptance", .{tmp.sub_path});
    const first_hash = try seed(root, "personal@example.com", delivered);
    _ = try seed(root, "work@example.com", other_delivered);
    {
        var refresh_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer refresh_arena.deinit();
        const ra = refresh_arena.allocator();
        var peer: Peer = .{ .steps = &.{
            .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=1&includeSpamTrash=false&fields=messages(id,threadId),nextPageToken", .response = "{\"messages\":[{\"id\":\"same-message\",\"threadId\":\"same-thread\"}]}" },
            .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/same-message?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To&fields=id,threadId,labelIds,internalDate,snippet,payload(mimeType,headers)", .response = refreshed_metadata },
        } };
        const page = try gmail.dispatchAuthorized(std.testing.io, ra, "personal@example.com", &.{"mail-read"}, peer.transport(), "mail.list", try j.value(ra, .{ .limit = @as(u8, 1) }));
        const metadata = try j.decode(t.Message, ra, j.get(page, "messages").?.array.items[0]);
        try std.testing.expectEqual(@as(usize, 0), metadata.attachments.len);
        var store = try storage.Store.open(std.testing.io, ra, root, "personal@example.com", .{});
        defer store.close();
        try store.put(metadata, false);
        try store.save();
        try peer.complete(0);
    }
    // All provider/decode/initial-store arenas are gone before these reads.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const session = try newCachedSession(std.testing.allocator, root, &env);
    defer std.testing.allocator.destroy(session);
    defer session.deinit();
    const message = try j.decode(t.Message, a, try cached(a, session, "personal@example.com", "mail.read"));
    try expectDelivered(message);
    try std.testing.expect(message.bodyCached and !message.unread and has(message.labels, "STARRED"));
    const listed = try cached(a, session, "personal@example.com", "mail.list");
    const row = try j.decode(t.Message, a, j.get(listed, "messages").?.array.items[0]);
    try std.testing.expect(row.bodyCached and row.bodyCacheError.len == 0);
    try std.testing.expectEqual(@as(usize, 1), row.attachments.len);
    try std.testing.expectEqualStrings("Quarterly café.pptx", row.attachments[0].filename);
    const thread = try cached(a, session, "personal@example.com", "mail.thread");
    try expectDelivered(try j.decode(t.Message, a, j.get(thread, "messages").?.array.items[0]));
    const other = try j.decode(t.Message, a, try cached(a, session, "work@example.com", "mail.read"));
    try std.testing.expectEqualStrings("Other account only.\n", other.bodyText);
    try std.testing.expectEqual(@as(usize, 0), other.attachments.len);
    try std.testing.expect(!has(other.labels, "STARRED"));
    {
        var store = try storage.Store.openCached(std.testing.io, a, root, "personal@example.com", .{});
        defer store.close();
        try std.testing.expectEqualStrings(&first_hash, store.find("same-message").?.bodyHash);
        try std.testing.expectEqualStrings("", store.find("same-message").?.bodyError);
    }
    // A user's saved attachment uses the selected persisted token directly.
    var peer: Peer = .{ .steps = &.{.{ .url = attachment_url, .response = "{\"size\":17,\"data\":\"RmljdGlvbmFsIHNsaWRlcwo\"}" }} };
    const attachment = try gmail.attachmentAuthorized(a, "personal@example.com", &.{"mail-read"}, peer.transport(), message.id, message.attachments[0]);
    var bytes: [17]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&bytes, attachment.data);
    try std.testing.expectEqualStrings("Fictional slides\n", &bytes);
    try peer.complete(0);
}

const BatchPeer = struct {
    peer: *Peer,
    fn provider(self: *BatchPeer) batch.Provider {
        return .{ .context = self, .labelsFn = labels, .modifyFn = modify };
    }
    fn labels(context: *anyopaque, a: std.mem.Allocator, store: *storage.Store, id: []const u8) ![]const []const u8 {
        const self: *BatchPeer = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("personal@example.com", store.state.account);
        const response = try gmail.dispatchAuthorized(std.testing.io, a, store.state.account, &.{"mail-read"}, self.peer.transport(), "mail.labels", try j.value(a, .{ .messageId = id }));
        return j.decode([]const []const u8, a, j.get(response, "labels").?);
    }
    fn modify(context: *anyopaque, a: std.mem.Allocator, id: []const u8, _: []const []const u8, delta: triage.Delta) ![]const []const u8 {
        const self: *BatchPeer = @ptrCast(@alignCast(context));
        const response = try gmail.dispatchAuthorized(std.testing.io, a, "personal@example.com", &.{"mail-modify"}, self.peer.transport(), "mail.modify-labels", try j.value(a, .{ .messageId = id, .addLabels = delta.add, .removeLabels = delta.remove }));
        return j.decode([]const []const u8, a, j.get(response, "labels").?);
    }
};

test "mail acceptance: star and read persist confirmed state and unknown receipt never replays" {
    const Case = struct { request: []const u8, body: []const u8, response: []const u8, unknown: bool = false, starred: bool = false, unread: bool = true };
    for ([_]Case{
        .{ .request = "{\"messageIds\":[\"same-message\"],\"action\":\"mark\",\"starred\":true}", .body = "{\"addLabelIds\":[\"STARRED\"],\"removeLabelIds\":[]}", .response = "{\"id\":\"same-message\",\"labelIds\":[\"INBOX\",\"UNREAD\",\"STARRED\"]}", .starred = true },
        .{ .request = "{\"messageIds\":[\"same-message\"],\"action\":\"mark\",\"unread\":false}", .body = "{\"addLabelIds\":[],\"removeLabelIds\":[\"UNREAD\"]}", .response = "{\"id\":\"same-message\",\"labelIds\":[\"INBOX\"]}", .unread = false },
        .{ .request = "{\"messageIds\":[\"same-message\"],\"action\":\"mark\",\"starred\":true}", .body = "{\"addLabelIds\":[\"STARRED\"],\"removeLabelIds\":[]}", .response = "{\"id\":\"wrong-message\",\"labelIds\":[\"INBOX\",\"STARRED\"]}", .unknown = true },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mail-acceptance", .{tmp.sub_path});
        const first_hash = try seed(root, "personal@example.com", delivered);
        var peer: Peer = .{ .steps = &.{
            .{ .url = membership_url, .response = "{\"id\":\"same-message\",\"labelIds\":[\"INBOX\",\"UNREAD\"]}" },
            .{ .method = .POST, .url = modify_url, .body = case.body, .response = case.response },
        } };
        var adapter: BatchPeer = .{ .peer = &peer };
        const context: batch.Context = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = "personal@example.com", .options = .{}, .provider = adapter.provider() };
        const request = try std.json.parseFromSliceLeaky(j.Value, a, case.request, .{});
        const delta = try gmail.resolveBatchLabels(a, peer.transport(), try triage.plan(a, request));
        try std.testing.expectEqual(@as(usize, 0), peer.calls);
        const result = try batch.run(context, a, request, delta);
        const outcomes = j.get(result, "outcomes").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), outcomes.len);
        try std.testing.expectEqualStrings("same-message", j.text(outcomes[0], "messageId"));
        try std.testing.expectEqualStrings(if (case.unknown) "unknown" else "applied", j.text(outcomes[0], "outcome"));
        try peer.complete(1);
        if (case.unknown) {
            try std.testing.expectEqualStrings("UnknownOutcome", j.text(outcomes[0], "errorCode"));
            _ = try batch.undo(context, a, try j.value(a, .{ .undoToken = try j.required(result, "undoToken") }));
            try peer.complete(1); // Reopening the durable receipt cannot issue another write.
        }
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        const session = try newCachedSession(std.testing.allocator, root, &env);
        defer std.testing.allocator.destroy(session);
        defer session.deinit();
        const shown = try j.decode(t.Message, a, try cached(a, session, "personal@example.com", "mail.read"));
        try expectDelivered(shown);
        try std.testing.expectEqual(case.unread, shown.unread);
        try std.testing.expectEqual(case.starred, has(shown.labels, "STARRED"));
        var store = try storage.Store.openCached(std.testing.io, a, root, "personal@example.com", .{});
        defer store.close();
        try std.testing.expectEqualStrings(&first_hash, store.find("same-message").?.bodyHash);
        try std.testing.expectEqual(@as(usize, 1), store.state.undo.len);
        try std.testing.expectEqualStrings(if (case.unknown) "unknown" else "applied", store.state.undo[0].items[0].outcome);
    }
}

fn structuredVariant(a: std.mem.Allocator, variant: usize) ![]const u8 {
    var wire = try std.json.parseFromSliceLeaky(j.Value, a, delivered, .{});
    const payload = wire.object.getPtr("payload").?;
    const parts = payload.object.getPtr("parts").?;
    const alternative = &parts.array.items[0];
    const leaves = alternative.object.getPtr("parts").?;
    for (leaves.array.items, 0..) |*leaf, index| {
        // Exact sizes and Gmail's retained three-byte BOM count are both valid
        // representations of the same independent complete UTF-8 oracle.
        try leaf.object.getPtr("body").?.object.put(a, "size", .{ .integer = @as(i64, if (index == 0) 13 else 18) + @as(i64, if (variant & 1 == 0) 0 else 3) });
        if (variant & 4 != 0) {
            const headers = leaf.object.getPtr("headers").?;
            try headers.array.items[0].object.put(a, "name", .{ .string = "content-type" });
            try headers.array.items[1].object.put(a, "name", .{ .string = "CONTENT-TRANSFER-ENCODING" });
        }
        if (variant & 8 != 0) try leaf.object.put(a, "parts", .{ .array = .init(a) });
        if (variant & 32 != 0) _ = leaf.object.swapRemove("filename");
    }
    if (variant & 2 != 0) std.mem.swap(j.Value, &leaves.array.items[0], &leaves.array.items[1]);
    if (variant & 16 != 0) {
        var wrapper = j.object(a);
        try wrapper.object.put(a, "mimeType", .{ .string = "multipart/mixed" });
        try wrapper.object.put(a, "body", try j.value(a, .{ .size = @as(u8, 0) }));
        try wrapper.object.put(a, "parts", parts.*);
        var wrapped = std.json.Array.init(a);
        try wrapped.append(wrapper);
        parts.* = .{ .array = wrapped };
    }
    return std.json.Stringify.valueAlloc(a, wire, .{});
}

test "mail acceptance: fixed seed structured provider fuzz keeps readable mail and selected attachment" {
    const seed_value: usize = 0x4f4d4147;
    // A seeded permutation visits every combination exactly once: 64 cases,
    // at most three multipart levels, two text leaves and one attachment.
    for (0..64) |iteration| {
        const variant = (iteration * 37 + seed_value) & 63;
        errdefer std.debug.print("mail acceptance structured fuzz seed=0x{x} iteration={d} variant=0x{x}\n", .{ seed_value, iteration, variant });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = try structuredVariant(a, variant) }} };
        try expectDelivered(try readProvider(a, "personal@example.com", &peer));
        try peer.complete(0);
    }
}

test "mail acceptance: binary attachment corruption remains explicit and never refetches a different message" {
    for ([_][]const u8{
        "{\"size\":17,\"data\":\"RmljdGlvbmFsIHNsaWRlcw\"}", // One actual byte short.
        "{\"size\":17,\"data\":\"RmljdGlvbmFsIHNsaWRlcwoK\"}", // One actual byte long.
    }) |response| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: Peer = .{ .steps = &.{
            .{ .url = full_url, .response = delivered },
            .{ .url = attachment_url, .response = response },
        } };
        const message = try readProvider(a, "personal@example.com", &peer);
        try std.testing.expectError(error.BodySizeMismatch, gmail.attachmentAuthorized(a, "personal@example.com", &.{"mail-read"}, peer.transport(), message.id, message.attachments[0]));
        try peer.complete(0);
    }
}

test "mail acceptance: broken display encodings retain readable mail and a healthy second metadata row" {
    const Case = struct { word: []const u8, display: []const u8 };
    const metadata_suffix = "?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To&fields=id,threadId,labelIds,internalDate,snippet,payload(mimeType,headers)";
    const healthy_metadata =
        \\{"id":"healthy-message","threadId":"healthy-thread","internalDate":"43","labelIds":["INBOX"],"payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Healthy <healthy@example.test>"},{"name":"Subject","value":"Healthy second row"}]}}
    ;
    // RFC 2047 sections 6.2/6.3 permit literal unsupported display text and
    // require malformed encoded words not to prevent handling the message.
    // None of these changes an address, identity, body or attachment byte.
    for ([_]Case{
        .{ .word = "=?UTF-8?B?%%%?=", .display = "=?UTF-8?B?%%%?=" },
        .{ .word = "=?UTF-8?Q?bad=ZZ?=", .display = "=?UTF-8?Q?bad=ZZ?=" },
        .{ .word = "=?Shift_JIS?Q?Example?=", .display = "=?Shift_JIS?Q?Example?=" },
        .{ .word = "=?UTF-8?X?Example?=", .display = "=?UTF-8?X?Example?=" },
        .{ .word = "=?UTF-8?B?8A==?=", .display = "=?UTF-8?B?8A==?=" },
        .{ .word = "=?UTF-8?Q?Caf=C3=A9?=", .display = "Café" },
    }, 0..) |case, index| {
        errdefer std.debug.print("mail acceptance display encoding variant={d}\n", .{index});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var wire = try std.json.parseFromSliceLeaky(j.Value, a, delivered, .{});
        const payload = wire.object.getPtr("payload").?;
        const headers = payload.object.getPtr("headers").?;
        try headers.array.items[0].object.put(a, "value", .{ .string = try std.fmt.allocPrint(a, "{s} <sender@example.test>", .{case.word}) });
        try headers.array.items[2].object.put(a, "value", .{ .string = case.word });
        try payload.object.getPtr("parts").?.array.items[1].object.put(a, "filename", .{ .string = try std.fmt.allocPrint(a, "{s}.pptx", .{case.word}) });
        var metadata = try j.copyObject(a, wire);
        var metadata_payload = try j.copyObject(a, payload.*);
        _ = metadata_payload.object.orderedRemove("body");
        _ = metadata_payload.object.orderedRemove("parts");
        try metadata.object.put(a, "payload", metadata_payload);
        var peer: Peer = .{ .steps = &.{
            .{ .url = full_url, .response = try std.json.Stringify.valueAlloc(a, wire, .{}) },
            .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=2&includeSpamTrash=false&fields=messages(id,threadId),nextPageToken", .response = "{\"messages\":[{\"id\":\"same-message\"},{\"id\":\"healthy-message\"}]}" },
            .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/same-message" ++ metadata_suffix, .response = try std.json.Stringify.valueAlloc(a, metadata, .{}) },
            .{ .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/healthy-message" ++ metadata_suffix, .response = healthy_metadata },
        } };
        const message = try readProvider(a, "personal@example.com", &peer);
        try std.testing.expectEqualStrings(case.display, message.subject);
        try std.testing.expectEqualStrings(case.display, message.from.name);
        try std.testing.expectEqualStrings("sender@example.test", message.from.address);
        try std.testing.expectEqualStrings("Plain café.\n", message.bodyText);
        try std.testing.expectEqualStrings("<p>HTML café.</p>", message.bodyHtml.?);
        try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}.pptx", .{case.display}), message.attachments[0].filename);
        try std.testing.expectEqualStrings("pptx-token/+==", message.attachments[0].id);
        try std.testing.expectEqual(@as(usize, 17), message.attachments[0].size);
        const page = try gmail.dispatchAuthorized(std.testing.io, a, "personal@example.com", &.{"mail-read"}, peer.transport(), "mail.list", try j.value(a, .{ .limit = @as(u8, 2) }));
        const rows = j.get(page, "messages").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), rows.len);
        const first = try j.decode(t.Message, a, rows[0]);
        try std.testing.expectEqualStrings(case.display, first.subject);
        try std.testing.expectEqualStrings(case.display, first.from.name);
        try std.testing.expectEqualStrings("sender@example.test", first.from.address);
        try std.testing.expectEqualStrings("healthy-message", j.text(rows[1], "id"));
        try std.testing.expectEqualStrings("Healthy second row", j.text(rows[1], "subject"));
        try peer.complete(0);
        // Forward-as-original inspects the Subject too; it must preserve the
        // raw message even when only that display text cannot be decoded.
        const raw = try std.fmt.allocPrint(a, "From: sender@example.test\r\nSubject: {s}\r\nContent-Type: text/plain\r\n\r\nLiteral original bytes\r\n", .{case.word});
        const original = try @import("terminal/mime.zig").originalSource(a, raw);
        try std.testing.expectEqualStrings(case.display, original.subject);
        try std.testing.expectEqualStrings(raw, try @import("terminal/mime.zig").decodeBase64Url(original.attachment.data, a));
    }
    // Fallback for display encoding does not accept injected physical headers.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire = try std.json.parseFromSliceLeaky(j.Value, a, delivered, .{});
    try wire.object.getPtr("payload").?.object.getPtr("headers").?.array.items[2].object.put(a, "value", .{ .string = "Subject\r\nBcc: injected@example.test" });
    var peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = try std.json.Stringify.valueAlloc(a, wire, .{}) }} };
    try std.testing.expectError(error.InvalidHeaders, readProvider(a, "personal@example.com", &peer));
    try peer.complete(0);
}

fn sessionCommand(a: std.mem.Allocator, session: *core.Session, request: anytype) !j.Value {
    const raw = try std.json.Stringify.valueAlloc(a, request, .{});
    const response = try std.json.parseFromSliceLeaky(j.Value, a, try session.client().call(a, raw), .{});
    if (!try j.boolean(response, "ok", false)) {
        std.debug.print("mail acceptance next action failed: {s}\n", .{j.text(j.get(response, "error").?, "code")});
        return error.NextActionFailed;
    }
    return j.get(response, "data") orelse error.MissingResponseData;
}

test "mail acceptance: read save preserve reply reply-all and forward retain original resources and envelope through draft reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cache_root = try std.fmt.allocPrint(a, "{s}/draft-cache", .{root});
    const html = "<p>HTML café.</p><img src=\"cid:chart@example.test\">";
    const png_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI_ScLbtAAAAABJRU5ErkJggg";
    var wire = try std.json.parseFromSliceLeaky(j.Value, a, delivered, .{});
    const headers = wire.object.getPtr("payload").?.object.getPtr("headers").?;
    try headers.array.items[1].object.put(a, "value", .{ .string = "personal@example.com, teammate@example.test" });
    for ([_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "Reply-To", .value = "Replies <replies@example.test>" },
        .{ .name = "Cc", .value = "copied@example.test" },
        .{ .name = "Message-ID", .value = "<literal-source@example.test>" },
        .{ .name = "References", .value = "<parent@example.test>" },
    }) |header| try headers.array.append(try j.value(a, header));
    const parts = wire.object.getPtr("payload").?.object.getPtr("parts").?;
    const html_body = parts.array.items[0].object.getPtr("parts").?.array.items[1].object.getPtr("body").?;
    try html_body.object.put(a, "size", .{ .integer = 55 });
    try html_body.object.put(a, "data", .{ .string = "PHA-SFRNTCBjYWbDqS48L3A-PGltZyBzcmM9ImNpZDpjaGFydEBleGFtcGxlLnRlc3QiPg" });
    try parts.array.append(try std.json.parseFromSliceLeaky(j.Value, a,
        \\{"partId":"2","mimeType":"image/png","filename":"chart.png","headers":[{"name":"Content-ID","value":"<chart@example.test>"},{"name":"Content-Disposition","value":"inline"}],"body":{"size":70,"attachmentId":"chart-token"}}
    , .{}));
    const wire_text = try std.json.Stringify.valueAlloc(a, wire, .{});
    var provider_peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = wire_text }} };
    const provider_message = try readProvider(a, "personal@example.com", &provider_peer);
    try std.testing.expectEqualStrings(html, provider_message.bodyHtml.?);
    try std.testing.expectEqual(@as(usize, 2), provider_message.attachments.len);
    try provider_peer.complete(0);

    var external = j.object(a);
    try external.object.put(a, "pptx-token/+==", try std.json.parseFromSliceLeaky(j.Value, a, "{\"size\":17,\"data\":\"RmljdGlvbmFsIHNsaWRlcwo\"}", .{}));
    try external.object.put(a, "chart-token", try j.value(a, .{ .size = @as(u8, 70), .data = png_data }));
    const source = try j.value(a, .{ .account = "personal@example.com", .messages = [_]j.Value{wire}, .externalBodies = external });
    try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = try std.json.Stringify.valueAlloc(a, source, .{}) });
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const session = try newCachedSession(std.testing.allocator, cache_root, &env);
    defer std.testing.allocator.destroy(session);
    defer session.deinit();
    // Session currently exposes transport injection only below this boundary.
    // The draft/UI handoff uses the same independent wire input in its offline
    // provider mode; the real dispatcher and token GET are checked above/below.
    session.options.fixtures = true;
    session.options.fixture_root = root;
    const account = "personal@example.com";
    // Refresh/prefetch stores descriptors for unopened binary attachments. Start
    // from those production-decoded bytes, so the first save cannot rely on a
    // previous fixture read or reply having hydrated the attachment for us.
    {
        var store = try storage.Store.open(std.testing.io, a, cache_root, account, session.options);
        defer store.close();
        try store.put(provider_message, false);
        try std.testing.expect(try store.putBody(provider_message));
        try store.save();
    }
    _ = try sessionCommand(a, session, .{ .cmd = "mail.read", .account = account, .messageId = "same-message" });
    const destination = try std.fmt.allocPrint(a, "{s}/saved-slides.pptx", .{root});
    _ = try sessionCommand(a, session, .{ .cmd = "mail.attachment-save", .account = account, .messageId = "same-message", .attachmentId = "pptx-token/+==", .path = destination });
    var saved_bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Fictional slides\n", try tmp.dir.readFile(std.testing.io, "saved-slides.pptx", &saved_bytes));
    for ([_]struct { command: []const u8, all: bool = false }{
        .{ .command = "mail.reply" },
        .{ .command = "mail.reply", .all = true },
        .{ .command = "mail.forward" },
    }) |action| {
        errdefer std.debug.print("mail acceptance next action: {s} all={any}\n", .{ action.command, action.all });
        const created = try sessionCommand(a, session, .{ .cmd = action.command, .account = account, .messageId = "same-message", .preserveFormatting = true, .bodyFormat = "markdown", .all = action.all });
        var draft = try core.decodeDraft(a, created);
        try std.testing.expectEqualStrings(html, draft.original.?.bodyHtml);
        try std.testing.expectEqualStrings("Plain café.\n", draft.original.?.bodyText);
        try std.testing.expectEqual(@as(usize, 1), draft.original.?.resources.len);
        const resource = draft.original.?.resources[0];
        try std.testing.expectEqualStrings("chart@example.test", resource.contentId.?);
        try std.testing.expectEqualStrings(png_data, resource.data);
        try std.testing.expectEqual(@as(usize, 70), resource.size);
        const forwarding = std.mem.eql(u8, action.command, "mail.forward");
        try std.testing.expectEqual(@as(usize, if (forwarding) 1 else 0), draft.attachments.len);
        if (forwarding) {
            try std.testing.expectEqual(@as(usize, 0), draft.to.len + draft.cc.len + draft.bcc.len);
            try std.testing.expectEqualStrings("", draft.threadId);
            try std.testing.expectEqualStrings("", draft.inReplyTo);
            try std.testing.expectEqualStrings("Quarterly café.pptx", draft.attachments[0].filename);
            try std.testing.expectEqualStrings("RmljdGlvbmFsIHNsaWRlcwo", draft.attachments[0].data);
        } else {
            try std.testing.expectEqual(@as(usize, 1), draft.to.len);
            try std.testing.expectEqualStrings("replies@example.test", draft.to[0].address);
            try std.testing.expectEqual(@as(usize, if (action.all) 2 else 0), draft.cc.len);
            if (action.all) {
                try std.testing.expectEqualStrings("teammate@example.test", draft.cc[0].address);
                try std.testing.expectEqualStrings("copied@example.test", draft.cc[1].address);
            }
            try std.testing.expectEqual(@as(usize, 0), draft.bcc.len);
            try std.testing.expectEqualStrings("same-thread", draft.threadId);
            try std.testing.expectEqualStrings("<literal-source@example.test>", draft.inReplyTo);
        }
        draft.bodyText = "**Reviewed note**";
        _ = try sessionCommand(a, session, .{ .cmd = "draft.update", .account = account, .draftId = draft.id, .draft = draft });
        const preview = try sessionCommand(a, session, .{ .cmd = "draft.preview", .account = account, .draftId = draft.id });
        try std.testing.expect(std.mem.indexOf(u8, j.text(preview, "bodyHtml"), html) != null);
        try std.testing.expect(std.mem.indexOf(u8, j.text(preview, "plainText"), "Reviewed note") != null);
        const reopened = try core.decodeDraft(a, try sessionCommand(a, session, .{ .cmd = "draft.read", .account = account, .draftId = draft.id }));
        try std.testing.expectEqualStrings(html, reopened.original.?.bodyHtml);
        const prepared = try @import("terminal/markdown_mail.zig").prepare(a, reopened);
        const outgoing = try @import("terminal/mime.zig").composeAttachments(prepared.resources, a);
        try std.testing.expectEqual(@as(usize, 1), outgoing.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(outgoing[0].data, &digest, .{});
        try std.testing.expectEqualStrings("2640059609118b695c139804676372eca75c30d30e5906775902d13e44f5356c", &std.fmt.bytesToHex(digest, .lower));
    }
    const stats = try sessionCommand(a, session, .{ .cmd = "cache.stats", .account = account });
    try std.testing.expectEqual(@as(i64, 0), try j.integer(stats, "fixtureSends", -1));
}

test "mail acceptance: ordinary reply ignores unselected incoming SMTP limits while reply-all retains outgoing checks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var wire = try std.json.parseFromSliceLeaky(j.Value, a, other_delivered, .{});
    try wire.object.getPtr("payload").?.object.getPtr("headers").?.array.append(try std.json.parseFromSliceLeaky(j.Value, a, "{\"name\":\"Message-ID\",\"value\":\"<recipient-selection@example.test>\"}", .{}));
    // Incoming RFC address syntax permits this local part. SMTP does not; it
    // should matter only if an action selects it as an outgoing recipient.
    const long_local: [65]u8 = @splat('a');
    try wire.object.getPtr("payload").?.object.getPtr("headers").?.array.items[1].object.put(a, "value", .{ .string = try std.fmt.allocPrint(a, "Unselected original recipient <{s}@example.test>, personal@example.com", .{&long_local}) });
    const source = try j.value(a, .{ .account = "personal@example.com", .messages = [_]j.Value{wire} });
    try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = try std.json.Stringify.valueAlloc(a, source, .{}) });
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const session = try newCachedSession(std.testing.allocator, try std.fmt.allocPrint(a, "{s}/reply-cache", .{root}), &env);
    defer std.testing.allocator.destroy(session);
    defer session.deinit();
    session.options.fixtures = true;
    session.options.fixture_root = root;
    const draft = try core.decodeDraft(a, try sessionCommand(a, session, .{ .cmd = "mail.reply", .account = "personal@example.com", .messageId = "same-message" }));
    try std.testing.expectEqual(@as(usize, 1), draft.to.len);
    try std.testing.expectEqualStrings("other@example.test", draft.to[0].address);
    try std.testing.expectEqualStrings("Other", draft.to[0].name);
    try std.testing.expectEqual(@as(usize, 0), draft.cc.len + draft.bcc.len);
    const request = "{\"cmd\":\"mail.reply\",\"account\":\"personal@example.com\",\"messageId\":\"same-message\",\"all\":true}";
    const response = try std.json.parseFromSliceLeaky(j.Value, a, try session.client().call(a, request), .{});
    try std.testing.expect(!try j.boolean(response, "ok", true));
    try std.testing.expectEqualStrings("InvalidAddress", j.text(j.get(response, "error").?, "code"));
}

test "mail acceptance: unused identities on ordinary large files retain reading and reply without widening forward limits" {
    const prefix =
        \\{"id":"same-message","threadId":"same-thread","internalDate":"44","labelIds":["INBOX"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"Sender <sender@example.test>"},{"name":"To","value":"personal@example.com, teammate@example.test"},{"name":"Subject","value":"Large ordinary file"},{"name":"Message-ID","value":"<large-file@example.test>"}],"body":{"size":0},"parts":[{"mimeType":"multipart/alternative","headers":[],"parts":[{"mimeType":"text/plain","headers":[],"body":{"size":2,"data":"SGk"}},{"mimeType":"text/html","headers":[],"body":{"size":9,"data":"PHA-SGk8L3A-"}}]},{"mimeType":"application/vnd.openxmlformats-officedocument.presentationml.presentation","filename":"report.pptx","headers":[{"name":"Content-Disposition","value":"attachment; filename=report.pptx"}
    ;
    const suffix =
        \\],"body":{"size":31457280,"attachmentId":"large-document"}}]}}
    ;
    const id_header = ",{\"name\":\"Content-ID\",\"value\":\"<report@example.test>\"}";
    const location_header = ",{\"name\":\"Content-Location\",\"value\":\"report.pptx\"}";
    for ([_][]const u8{ id_header, location_header, id_header ++ location_header }, 0..) |identity_headers, variant| {
        errdefer std.debug.print("mail acceptance unused large-file identity variant={d}\n", .{variant});
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const wire_text = try std.mem.concat(a, u8, &.{ prefix, identity_headers, suffix });
        var peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = wire_text }} };
        const message = try readProvider(a, "personal@example.com", &peer);
        try std.testing.expectEqualStrings("Hi", message.bodyText);
        try std.testing.expectEqualStrings("<p>Hi</p>", message.bodyHtml.?);
        try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
        const file = message.attachments[0];
        try std.testing.expectEqual(@as(usize, 30 * 1024 * 1024), file.size);
        try std.testing.expectEqualStrings("large-document", file.id);
        try std.testing.expectEqualStrings("report.pptx", file.filename);
        try std.testing.expectEqualStrings("attachment", file.disposition.?);
        try std.testing.expectEqualStrings("", file.data);
        try std.testing.expect(file.blobId == null);
        if (variant != 1) try std.testing.expectEqualStrings("report@example.test", file.contentId.?) else try std.testing.expect(file.contentId == null);
        if (variant != 0) try std.testing.expectEqualStrings("report.pptx", file.contentLocation.?) else try std.testing.expect(file.contentLocation == null);
        // There is deliberately no attachment step: viewing metadata never
        // downloads a 30 MiB ordinary file, regardless of its unused identity.
        try peer.complete(0);

        var wire = try std.json.parseFromSliceLeaky(j.Value, a, wire_text, .{});
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const account = "personal@example.com";
        var source = try j.value(a, .{ .account = account, .messages = [_]j.Value{wire} });
        try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = try std.json.Stringify.valueAlloc(a, source, .{}) });
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        const session = try newCachedSession(std.testing.allocator, try std.fmt.allocPrint(a, "{s}/large-file-cache", .{root}), &env);
        defer std.testing.allocator.destroy(session);
        defer session.deinit();
        session.options.fixtures = true;
        session.options.fixture_root = root;
        // No externalBodies map exists. Reply must not try to hydrate this
        // unreferenced ordinary file as an HTML resource.
        for ([_]bool{ false, true }) |all| {
            const draft = try core.decodeDraft(a, try sessionCommand(a, session, .{ .cmd = "mail.reply", .account = account, .messageId = "same-message", .preserveFormatting = true, .bodyFormat = "markdown", .all = all }));
            try std.testing.expectEqualStrings("<p>Hi</p>", draft.original.?.bodyHtml);
            try std.testing.expectEqual(@as(usize, 0), draft.original.?.resources.len + draft.attachments.len);
            try std.testing.expectEqual(@as(usize, 1), draft.to.len);
            try std.testing.expectEqualStrings("sender@example.test", draft.to[0].address);
            try std.testing.expectEqual(@as(usize, @intFromBool(all)), draft.cc.len);
            const preview = try sessionCommand(a, session, .{ .cmd = "draft.preview", .account = account, .draftId = draft.id });
            try std.testing.expect(std.mem.indexOf(u8, j.text(preview, "bodyHtml"), "<p>Hi</p>") != null);
        }
        const forward_request = "{\"cmd\":\"mail.forward\",\"account\":\"personal@example.com\",\"messageId\":\"same-message\",\"preserveFormatting\":true,\"bodyFormat\":\"markdown\"}";
        const refused = try std.json.parseFromSliceLeaky(j.Value, a, try session.client().call(a, forward_request), .{});
        try std.testing.expect(!try j.boolean(refused, "ok", true));
        try std.testing.expectEqualStrings("AttachmentsTooLarge", j.text(j.get(refused, "error").?, "code"));

        // The same unused identities on a small file must still forward that
        // file as an ordinary attachment rather than drop it or quote it inline.
        const leaf = &wire.object.getPtr("payload").?.object.getPtr("parts").?.array.items[1];
        try leaf.object.getPtr("body").?.object.put(a, "size", .{ .integer = 17 });
        try wire.object.put(a, "id", .{ .string = "small-file" });
        source = try j.value(a, .{ .account = account, .messages = [_]j.Value{wire} });
        var external = j.object(a);
        try external.object.put(a, "large-document", try std.json.parseFromSliceLeaky(j.Value, a, "{\"size\":17,\"data\":\"RmljdGlvbmFsIHNsaWRlcwo\"}", .{}));
        try source.object.put(a, "externalBodies", external);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = try std.json.Stringify.valueAlloc(a, source, .{}) });
        const forwarded = try core.decodeDraft(a, try sessionCommand(a, session, .{ .cmd = "mail.forward", .account = account, .messageId = "small-file", .preserveFormatting = true, .bodyFormat = "markdown" }));
        try std.testing.expectEqual(@as(usize, 0), forwarded.original.?.resources.len);
        try std.testing.expectEqual(@as(usize, 1), forwarded.attachments.len);
        try std.testing.expectEqualStrings("report.pptx", forwarded.attachments[0].filename);
        try std.testing.expectEqualStrings("RmljdGlvbmFsIHNsaWRlcwo", forwarded.attachments[0].data);
        try std.testing.expectEqual(@as(usize, 17), forwarded.attachments[0].size);

        // Explicit inline resources remain subject to the small body budget.
        try wire.object.put(a, "id", .{ .string = "same-message" });
        try leaf.object.getPtr("body").?.object.put(a, "size", .{ .integer = 30 * 1024 * 1024 });
        try leaf.object.getPtr("headers").?.array.items[0].object.put(a, "value", .{ .string = "inline; filename=report.pptx" });
        var inline_peer: Peer = .{ .steps = &.{.{ .url = full_url, .response = try std.json.Stringify.valueAlloc(a, wire, .{}) }} };
        try std.testing.expectError(error.BodyTooLarge, readProvider(a, account, &inline_peer));
        try inline_peer.complete(0);
        const stats = try sessionCommand(a, session, .{ .cmd = "cache.stats", .account = account });
        try std.testing.expectEqual(@as(i64, 0), try j.integer(stats, "fixtureSends", -1));
    }
}
