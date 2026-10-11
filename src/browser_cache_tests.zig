const std = @import("std");
const cache = @import("browser_cache.zig");
const types = @import("terminal/types.zig");
const j = @import("terminal/json.zig");

const actor: cache.Binding = .{
    .account = "ada@example.test",
    .clientId = "synthetic.apps.googleusercontent.com",
    .grantId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
};
const header =
    \\{"version":1,"account":"ada@example.test","clientId":"synthetic.apps.googleusercontent.com","grantId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","updatedAt":1791730000000,
;
// These are independently authored wire fixtures, not Store.snapshot output.
const fixture_messages =
    \\[
    \\{"id":"mail-inbox","threadId":"thread-inbox","receivedAt":6000,"from":{"address":"morgan@example.test","name":"Morgan Chen"},"to":[{"address":"ada@example.test"}],"replyTo":[{"address":"reply@example.test"}],"subject":"Violet lantern report","snippet":"Inbox preview","bodyText":"The violet lantern arrives.\nSecond literal line.","bodyHtml":"<p>Violet <b>lantern</b><img src=\"https://remote.invalid/passive\"></p>","bodySource":"html","bodyCached":true,"messageId":"<inbox@example.test>","references":"<prior@example.test>","inReplyTo":"<prior@example.test>","labels":["INBOX","UNREAD"],"unread":true,"attachments":[{"id":"attachment-1","filename":"report.pdf","mimeType":"application/pdf","size":12,"contentId":"cid-report","disposition":"attachment"}]},
    \\{"id":"mail-archive","threadId":"thread-archive","receivedAt":5000,"from":{"address":"bea@example.test","name":"Bea"},"subject":"Archived decision","bodyText":"An archived violet memo.","bodyCached":true,"labels":["STARRED"],"unread":true},
    \\{"id":"mail-sent","threadId":"thread-sent","receivedAt":4000,"subject":"Sent copy","labels":["SENT"]},
    \\{"id":"mail-trash","threadId":"thread-trash","receivedAt":3000,"subject":"Discarded copy","labels":["TRASH"],"unread":true},
    \\{"id":"mail-spam","threadId":"thread-spam","receivedAt":2000,"subject":"Spam copy","labels":["SPAM"]},
    \\{"id":"mail-metadata","threadId":"thread-metadata","receivedAt":1000,"subject":"Uncached inbox row","labels":["INBOX"]}
    \\]
;
const fixture_contacts =
    \\[{"resourceName":"people/morgan","etag":"synthetic-etag","name":"Morgan Chen","emails":[{"address":"morgan@example.test","name":"Morgan"}]}]
;
const fixture = header ++ "\"messages\":" ++ fixture_messages ++ ",\"contacts\":" ++ fixture_contacts ++ ",\"contactsLoaded\":true}";

fn parse(a: std.mem.Allocator, bytes: []const u8) !j.Value {
    return std.json.parseFromSliceLeaky(j.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}
fn array(a: std.mem.Allocator, bytes: []const u8) ![]const j.Value {
    return (try parse(a, bytes)).array.items;
}
fn document(a: std.mem.Allocator, messages: []const u8, contacts: []const u8, loaded: bool) ![]const u8 {
    return std.mem.concat(a, u8, &.{ header, "\"messages\":", messages, ",\"contacts\":", contacts, if (loaded) ",\"contactsLoaded\":true}" else ",\"contactsLoaded\":false}" });
}
fn snapshot(a: std.mem.Allocator, store: *cache.Store, index: usize) ![]u8 {
    const output = try a.alloc(u8, cache.snapshot_limit);
    defer a.free(output);
    return a.dupe(u8, try store.snapshot(index, output));
}
fn expectRejected(result: anyerror!void) !void {
    if (result) |_| return error.ExpectedInvalidCacheRejection else |err| try std.testing.expect(err != error.OutOfMemory);
}
fn expectIds(values: []const j.Value, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, values.len);
    for (values, expected) |value, id| try std.testing.expectEqualStrings(id, j.text(value, "id"));
}
fn repeatedRows(a: std.mem.Allocator, count: usize, contacts: bool) ![]const u8 {
    const rows = try a.alloc([]const u8, count);
    for (rows, 0..) |*row, index| row.* = if (contacts)
        try std.fmt.allocPrint(a, "{{\"resourceName\":\"people/contact-{d}\",\"name\":\"Synthetic\",\"emails\":[]}}", .{index})
    else
        try std.fmt.allocPrint(a, "{{\"id\":\"mail-{d}\",\"threadId\":\"thread-{d}\",\"subject\":\"Synthetic retained metadata\",\"labels\":[\"INBOX\"],\"receivedAt\":{d}}}", .{ index, index, 1000 + index });
    return std.mem.concat(a, u8, &.{ "[", try std.mem.join(a, ",", rows), "]" });
}

test "browser cache: independent literal snapshot restores passive bodies and caller-owned contacts" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    const before = store.revision(0);
    try store.restore(0, fixture, true);
    try std.testing.expect(store.valid(0));
    try std.testing.expect(store.contactsLoaded(0));
    try std.testing.expectEqual(before +% 1, store.revision(0));
    const message = (try store.read(0, "mail-inbox")).?;
    try std.testing.expectEqualStrings("The violet lantern arrives.\nSecond literal line.", message.bodyText);
    try std.testing.expectEqualStrings("<p>Violet <b>lantern</b><img src=\"https://remote.invalid/passive\"></p>", message.bodyHtml.?);
    try std.testing.expectEqual(types.BodySource.html, message.bodySource);
    try std.testing.expectEqualStrings("reply@example.test", message.replyTo[0].address);
    try std.testing.expectEqualStrings("report.pdf", message.attachments[0].filename);
    try std.testing.expect(message.attachments[0].blobId == null);
    try std.testing.expectEqual(@as(usize, 0), message.attachments[0].data.len);
    try std.testing.expect(try store.read(0, "mail-metadata") == null);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const contacts = try store.contacts(0, arena.allocator());
    const listed = try store.list(0, arena.allocator(), "INBOX", "");
    store.clear(0);
    // Returned JSON values must survive Store arena replacement.
    try std.testing.expectEqualStrings("Morgan Chen", j.text(contacts[0], "name"));
    try std.testing.expectEqualStrings("morgan@example.test", j.text(j.get(contacts[0], "emails").?.array.items[0], "address"));
    try expectIds(listed, &.{ "mail-inbox", "mail-metadata" });
    try std.testing.expectEqualStrings("Violet lantern report", j.text(listed[0], "subject"));
    try std.testing.expectEqualStrings("The violet lantern arrives.\nSecond literal line.", j.text(listed[0], "bodyText"));
}

test "browser cache: every exact actor component is required for restore" {
    for ([_]cache.Binding{
        .{ .account = "bea@example.test", .clientId = actor.clientId, .grantId = actor.grantId },
        .{ .account = actor.account, .clientId = "other.apps.googleusercontent.com", .grantId = actor.grantId },
        .{ .account = actor.account, .clientId = actor.clientId, .grantId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .{ .account = "Ada@example.test", .clientId = actor.clientId, .grantId = actor.grantId },
    }) |binding| {
        var store = cache.Store.init(std.testing.allocator);
        defer store.deinit();
        try store.bind(0, binding);
        const revision = store.revision(0);
        try std.testing.expectError(error.InvalidBrowserCache, store.restore(0, fixture, true));
        try std.testing.expect(!store.valid(0));
        try std.testing.expectEqual(revision, store.revision(0));
    }
}

test "browser cache: replacing metadata retains bodies only for the same message and thread" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, true);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replacement = try array(a,
        \\[{"id":"mail-inbox","threadId":"thread-inbox","receivedAt":6000,"subject":"Fresh inbox metadata","labels":["STARRED"],"unread":false},{"id":"mail-archive","threadId":"replacement-thread","receivedAt":5000,"subject":"Different thread"}]
    );
    try store.replaceList(0, replacement, 1791730000001);
    const retained = (try store.read(0, "mail-inbox")).?;
    try std.testing.expectEqualStrings("Fresh inbox metadata", retained.subject);
    try std.testing.expect(!retained.unread);
    try std.testing.expectEqualStrings("STARRED", retained.labels[0]);
    try std.testing.expectEqualStrings("The violet lantern arrives.\nSecond literal line.", retained.bodyText);
    try std.testing.expectEqualStrings("<inbox@example.test>", retained.messageId);
    try std.testing.expectEqualStrings("<prior@example.test>", retained.references);
    try std.testing.expectEqualStrings("report.pdf", retained.attachments[0].filename);
    try std.testing.expect(retained.bodyHtml != null);
    try std.testing.expect(try store.read(0, "mail-archive") == null);
    try expectIds(try store.list(0, a, "", ""), &.{ "mail-inbox", "mail-archive", "mail-sent", "mail-trash", "mail-spam", "mail-metadata" });
    try std.testing.expectEqual(@as(i64, 1791730000001), try j.integer(try parse(a, try snapshot(a, &store, 0)), "updatedAt", 0));
    try store.replaceList(0, try array(a, "[{\"id\":\"mail-new\",\"threadId\":\"thread-new\",\"receivedAt\":7000}]"), 1791730000002);
    try std.testing.expect(try store.read(0, "mail-inbox") != null);
    try expectIds(try store.list(0, a, "", ""), &.{ "mail-new", "mail-inbox", "mail-archive", "mail-sent", "mail-trash", "mail-spam", "mail-metadata" });
}

test "browser cache: Inbox survives Sent and server search across a persisted reload" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inbox = try array(a,
        \\[{"id":"inbox-1","threadId":"thread-inbox-1","receivedAt":3000,"labels":["INBOX"],"subject":"Original Inbox subject"},{"id":"inbox-2","threadId":"thread-inbox-2","receivedAt":2000,"labels":["INBOX"],"subject":"Second Inbox message"}]
    );
    const sent = try array(a,
        \\[{"id":"sent-1","threadId":"thread-sent-1","receivedAt":5000,"labels":["SENT"],"subject":"Sent first"},{"id":"sent-2","threadId":"thread-sent-2","receivedAt":4000,"labels":["SENT"],"subject":"Sent second"}]
    );
    const server_search = try array(a,
        \\[{"id":"inbox-1","threadId":"thread-inbox-1","receivedAt":3000,"labels":["INBOX","STARRED"],"subject":"Updated Inbox subject"},{"id":"archive-search","threadId":"thread-archive-search","receivedAt":1000,"labels":["STARRED"],"subject":"Older search result"}]
    );
    try store.replaceList(0, inbox, 1);
    try store.saveRead(0, .{ .id = "inbox-1", .threadId = "thread-inbox-1", .receivedAt = 3000, .labels = &.{"INBOX"}, .subject = "Original Inbox subject", .bodyText = "Previously opened Inbox body." });
    try store.replaceList(0, sent, 2);
    try expectIds(try store.list(0, a, "INBOX", ""), &.{ "inbox-1", "inbox-2" });
    try store.replaceList(0, server_search, 3);
    try store.replaceList(0, &.{}, 4); // An empty subsequent search must not erase other views.
    try expectIds(try store.list(0, a, "INBOX", ""), &.{ "inbox-1", "inbox-2" });
    try expectIds(try store.list(0, a, "SENT", ""), &.{ "sent-1", "sent-2" });
    try expectIds(try store.list(0, a, "", "subject:\"older search\""), &.{"archive-search"});
    try std.testing.expectEqualStrings("Updated Inbox subject", (try store.read(0, "inbox-1")).?.subject);
    try std.testing.expectEqualStrings("Previously opened Inbox body.", (try store.read(0, "inbox-1")).?.bodyText);

    const raw = try snapshot(a, &store, 0);
    try std.testing.expectEqual(@as(usize, 5), j.get(try parse(a, raw), "messages").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Original Inbox subject") == null);
    var reopened = cache.Store.init(std.testing.allocator);
    defer reopened.deinit();
    try reopened.bind(0, actor);
    try reopened.restore(0, raw, false);
    try expectIds(try reopened.list(0, a, "INBOX", ""), &.{ "inbox-1", "inbox-2" });
    try expectIds(try reopened.list(0, a, "SENT", ""), &.{ "sent-1", "sent-2" });
    try std.testing.expectEqualStrings("Previously opened Inbox body.", (try reopened.read(0, "inbox-1")).?.bodyText);
}

test "browser cache: fetched bodies insert unknown IDs and replace changed threads without duplicate IDs" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, true);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try store.saveRead(0, .{ .id = "older-searched-mail", .threadId = "older-thread", .receivedAt = 500, .bodyText = "Fetched older search body." });
    try std.testing.expectEqualStrings("Fetched older search body.", (try store.read(0, "older-searched-mail")).?.bodyText);
    try expectIds(try store.list(0, a, "", "body:\"older search\""), &.{"older-searched-mail"});
    try store.saveRead(0, .{ .id = "mail-inbox", .threadId = "changed-thread", .receivedAt = 6000, .labels = &.{"INBOX"}, .bodyText = "Fresh body for the changed thread." });
    const changed = (try store.read(0, "mail-inbox")).?;
    try std.testing.expectEqualStrings("changed-thread", changed.threadId);
    try std.testing.expectEqualStrings("Fresh body for the changed thread.", changed.bodyText);
    const raw = try snapshot(a, &store, 0);
    const messages = j.get(try parse(a, raw), "messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 7), messages.len);
    var inbox_count: usize = 0;
    for (messages) |message| if (std.mem.eql(u8, j.text(message, "id"), "mail-inbox")) {
        inbox_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), inbox_count);
    try std.testing.expect(std.mem.indexOf(u8, raw, "The violet lantern arrives.") == null);
    // The emitted snapshot must pass the same strict uniqueness check on reload.
    var reopened = cache.Store.init(std.testing.allocator);
    defer reopened.deinit();
    try reopened.bind(0, actor);
    try reopened.restore(0, raw, true);
    try std.testing.expectEqualStrings("changed-thread", (try reopened.read(0, "mail-inbox")).?.threadId);
}

test "browser cache: a 300-message inventory exposes only the latest 30 matching rows" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try store.restore(0, try document(a, try repeatedRows(a, 300, false), "[]", false), false);
    const visible = try store.list(0, a, "INBOX", "subject:retained");
    try std.testing.expectEqual(@as(usize, 30), visible.len);
    for (visible, 0..) |message, index| try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mail-{d}", .{299 - index}), j.text(message, "id"));
    try store.saveRead(0, .{ .id = "older-searched-mail", .threadId = "older-thread", .receivedAt = 500, .bodyText = "Distinct imported search body." });
    try std.testing.expectEqual(@as(usize, 300), j.get(try parse(a, try snapshot(a, &store, 0)), "messages").?.array.items.len);
    try std.testing.expectEqualStrings("Distinct imported search body.", (try store.read(0, "older-searched-mail")).?.bodyText);
    try expectIds(try store.list(0, a, "", "body:\"distinct imported\""), &.{"older-searched-mail"});
    try std.testing.expectEqual(@as(usize, 30), (try store.list(0, a, "INBOX", "")).len);
}

test "browser cache: 49 attachment descriptors survive while a fiftieth is rejected atomically" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, false);
    var files: [50]types.Attachment = undefined;
    for (&files) |*file| file.* = .{ .id = "synthetic-attachment", .filename = "report.pdf" };
    try store.saveRead(0, .{ .id = "mail-inbox", .threadId = "thread-inbox", .bodyText = "Attachment inventory.", .attachments = files[0..49] });
    try std.testing.expectEqual(@as(usize, 49), (try store.read(0, "mail-inbox")).?.attachments.len);
    const revision = store.revision(0);
    try std.testing.expectError(error.InvalidBrowserCache, store.saveRead(0, .{ .id = "mail-inbox", .threadId = "thread-inbox", .bodyText = "Must not replace the prior read.", .attachments = &files }));
    try std.testing.expectEqual(revision, store.revision(0));
    try std.testing.expectEqualStrings("Attachment inventory.", (try store.read(0, "mail-inbox")).?.bodyText);
}

test "browser cache: contact scope removal strips contacts without changing retained mail" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, false);
    try std.testing.expect(store.valid(0));
    try std.testing.expect(!store.contactsLoaded(0));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try store.contacts(0, a)).len);
    try std.testing.expect(try store.read(0, "mail-inbox") != null);
    const raw = try snapshot(a, &store, 0);
    try std.testing.expect(std.mem.indexOf(u8, raw, "people/morgan") == null);
    const restored = try parse(a, raw);
    try std.testing.expect(!(try j.boolean(restored, "contactsLoaded", true)));
    try std.testing.expectEqual(@as(usize, 0), j.get(restored, "contacts").?.array.items.len);
    try store.restore(0, fixture, true);
    const revision = store.revision(0);
    try store.dropContacts(0);
    try std.testing.expectEqual(revision +% 1, store.revision(0));
    try std.testing.expectEqualStrings(raw, try snapshot(a, &store, 0));
    try store.dropContacts(0);
    try std.testing.expectEqual(revision +% 1, store.revision(0));
    try std.testing.expectError(error.InvalidBrowserCache, store.dropContacts(3));
}

test "browser cache: local folders and native query syntax search only the retained snapshot" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, true);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIds(try store.list(0, a, "ARCHIVE", ""), &.{"mail-archive"});
    try expectIds(try store.list(0, a, "UNREAD", ""), &.{ "mail-inbox", "mail-archive", "mail-trash" });
    try expectIds(try store.list(0, a, "INBOX", "VIOLET"), &.{"mail-inbox"});
    try expectIds(try store.list(0, a, "", "from:morgan body:\"violet lantern\" is:unread"), &.{"mail-inbox"});
    try expectIds(try store.list(0, a, "ARCHIVE", "body:violet -from:morgan"), &.{"mail-archive"});
    try expectIds(try store.list(0, a, "", "filename:report.pdf has:attachment"), &.{"mail-inbox"});
    try expectIds(try store.list(0, a, "", "body:absent"), &.{});
    try std.testing.expectError(error.UnknownQueryOperator, store.list(0, a, "", "subjet:violet"));
    try std.testing.expectError(error.InvalidQuery, store.list(0, a, "", "body:\"unterminated"));
}

test "browser cache: malformed duplicate and over-limit snapshots preserve the current entry" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, true);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try snapshot(a, &store, 0);
    const revision = store.revision(0);
    const duplicate_contacts = "[{\"resourceName\":\"people/same\"},{\"resourceName\":\"people/same\"}]";
    const malformed = [_][]const u8{
        "",                                              "{",                                                                                                                   "[]",                                                               "null",
        "{\"version\":1,\"version\":1}",                 try document(a, "[{\"id\":\"duplicate\",\"threadId\":\"t\"},{\"id\":\"duplicate\",\"threadId\":\"u\"}]", "[]", false), try document(a, "[{\"id\":\"\",\"threadId\":\"t\"}]", "[]", false), try document(a, "[{\"id\":\"m\",\"threadId\":\"t\",\"bodyText\":\"\xff\"}]", "[]", false),
        try document(a, "[]", duplicate_contacts, true), try document(a, "[]", fixture_contacts, false),                                                                        try document(a, try repeatedRows(a, 301, false), "[]", false),      try document(a, "[]", try repeatedRows(a, 101, true), true),
    };
    for (malformed) |bytes| {
        try expectRejected(store.restore(0, bytes, true));
        try std.testing.expectEqual(revision, store.revision(0));
        try std.testing.expectEqualStrings(before, try snapshot(a, &store, 0));
    }
    for ([_][]const u8{ "version", "updatedAt", "messages", "contacts", "contactsLoaded" }) |field| {
        var missing = try parse(a, fixture);
        _ = missing.object.swapRemove(field);
        try expectRejected(store.restore(0, try std.json.Stringify.valueAlloc(a, missing, .{}), true));
        try std.testing.expectEqual(revision, store.revision(0));
        try std.testing.expectEqualStrings(before, try snapshot(a, &store, 0));
    }
    const oversized = try a.alloc(u8, cache.snapshot_limit + 1);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InvalidBrowserCache, store.restore(0, oversized, true));
    try std.testing.expectEqualStrings(before, try snapshot(a, &store, 0));
}

test "browser cache: persistence rejects credentials provider JSON drafts and native handles" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "refreshToken", "access_token", "clientSecret", "session", "nonce", "path", "drafts", "operationId" }) |key| {
        const raw = try std.mem.concat(a, u8, &.{ header, "\"messages\":[],\"contacts\":[],\"contactsLoaded\":false,\"", key, "\":\"SYNTHETIC_PRIVATE_VALUE\"}" });
        try expectRejected(store.restore(0, raw, true));
    }
    for ([_][]const u8{ "provider", "fixtureRaw", "invitation", "path" }) |key| {
        const messages = try std.mem.concat(a, u8, &.{ "[{\"id\":\"m\",\"threadId\":\"t\",\"", key, "\":null}]" });
        try expectRejected(store.restore(0, try document(a, messages, "[]", false), true));
    }
    try expectRejected(store.restore(0, try document(a, "[]", "[{\"resourceName\":\"people/p\",\"provider\":{}}]", true), true));
    for ([_][]const u8{ "data", "blobId", "contentLocation", "path" }) |key| {
        const messages = try std.mem.concat(a, u8, &.{ "[{\"id\":\"m\",\"threadId\":\"t\",\"attachments\":[{\"id\":\"a\",\"filename\":\"report.pdf\",\"", key, "\":\"SYNTHETIC_PRIVATE_VALUE\"}]}]" });
        try expectRejected(store.restore(0, try document(a, messages, "[]", false), true));
    }
    try std.testing.expect(!store.valid(0));
}

test "browser cache: live typed reads strip transient provider and native attachment fields" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, true);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try store.saveRead(0, .{
        .id = "mail-inbox",
        .threadId = "thread-inbox",
        .bodyText = "A new independently fetched body.",
        .fixtureRaw = "SYNTHETIC_RAW_MIME",
        .invitation = "SYNTHETIC_INVITATION",
        .attachments = &.{.{ .id = "attachment-live", .filename = "live.pdf", .data = "SYNTHETIC_ENCODED_DATA", .blobId = "SYNTHETIC_NATIVE_HANDLE", .contentLocation = "/synthetic/native/location" }},
    });
    try store.replaceContacts(0, try array(a, "[{\"resourceName\":\"people/live\",\"name\":\"Live contact\",\"provider\":{\"metadata\":\"SYNTHETIC_PROVIDER_JSON\"}}]"));
    const raw = try snapshot(a, &store, 0);
    for ([_][]const u8{ "SYNTHETIC_RAW_MIME", "SYNTHETIC_INVITATION", "SYNTHETIC_ENCODED_DATA", "SYNTHETIC_NATIVE_HANDLE", "/synthetic/native/location", "SYNTHETIC_PROVIDER_JSON", "fixtureRaw", "blobId", "contentLocation", "provider" }) |excluded| try std.testing.expect(std.mem.indexOf(u8, raw, excluded) == null);
    try std.testing.expectEqualStrings("A new independently fetched body.", (try store.read(0, "mail-inbox")).?.bodyText);
    try std.testing.expectEqualStrings("Live contact", j.text((try store.contacts(0, a))[0], "name"));
}

test "browser cache: boundary-sized row sets are accepted and oversized live replacements are atomic" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try store.restore(0, try document(a, try repeatedRows(a, 300, false), try repeatedRows(a, 100, true), true), true);
    try std.testing.expectEqual(@as(usize, 30), (try store.list(0, a, "", "")).len);
    try std.testing.expectEqual(@as(usize, 100), (try store.contacts(0, a)).len);
    try std.testing.expectEqual(@as(usize, 300), j.get(try parse(a, try snapshot(a, &store, 0)), "messages").?.array.items.len);
    const before = try snapshot(a, &store, 0);
    const revision = store.revision(0);
    try std.testing.expectError(error.InvalidBrowserCache, store.replaceList(0, try array(a, try repeatedRows(a, 31, false)), 1));
    try std.testing.expectError(error.InvalidBrowserCache, store.replaceContacts(0, try array(a, try repeatedRows(a, 101, true))));
    try std.testing.expectError(error.InvalidBrowserCache, store.replaceList(0, try array(a, "[{\"id\":\"same\",\"threadId\":\"t\"},{\"id\":\"same\",\"threadId\":\"u\"}]"), 1));
    try std.testing.expectError(error.InvalidBrowserCache, store.replaceContacts(0, try array(a, "[{\"resourceName\":\"people/same\"},{\"resourceName\":\"people/same\"}]")));
    try std.testing.expectError(error.InvalidBrowserCache, store.replaceList(0, &.{}, -1));
    try std.testing.expectError(error.InvalidBrowserCache, store.replaceList(0, &.{}, 253402300800001));
    try std.testing.expectEqual(revision, store.revision(0));
    try std.testing.expectEqualStrings(before, try snapshot(a, &store, 0));
}

test "browser cache: quota eviction preserves the selected body and failed writes preserve old bytes" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.restore(0, fixture, true);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try a.alloc(u8, 1800 * 1024);
    @memset(body, 'v');
    try store.saveRead(0, .{ .id = "mail-inbox", .threadId = "thread-inbox", .bodyText = body });
    try store.saveRead(0, .{ .id = "mail-archive", .threadId = "thread-archive", .bodyText = body });
    try std.testing.expect(try store.read(0, "mail-inbox") == null);
    try std.testing.expectEqual(body.len, (try store.read(0, "mail-archive")).?.bodyText.len);
    const before = try snapshot(a, &store, 0);
    try std.testing.expect(before.len <= cache.snapshot_limit);
    const revision = store.revision(0);
    const too_large = try a.alloc(u8, 2 * 1024 * 1024);
    @memset(too_large, 'x');
    try std.testing.expectError(error.BrowserCacheQuotaExceeded, store.saveRead(0, .{ .id = "mail-archive", .threadId = "thread-archive", .bodyText = too_large, .bodyHtml = too_large }));
    try std.testing.expectEqual(revision, store.revision(0));
    try std.testing.expectEqualStrings(before, try snapshot(a, &store, 0));
}

test "browser cache: quota prunes older bodies before newer bodies while preserving the active read" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try store.replaceList(0, try array(a,
        \\[{"id":"newer","threadId":"thread-newer","receivedAt":3000},{"id":"older","threadId":"thread-older","receivedAt":2000},{"id":"active","threadId":"thread-active","receivedAt":1000}]
    ), 1);
    const body = try a.alloc(u8, 1024 * 1024);
    const active_body = try a.alloc(u8, 1400 * 1024);
    @memset(body, 'b');
    @memset(active_body, 'a');
    try store.saveRead(0, .{ .id = "newer", .threadId = "thread-newer", .receivedAt = 3000, .bodyText = body });
    try store.saveRead(0, .{ .id = "older", .threadId = "thread-older", .receivedAt = 2000, .bodyText = body });
    try store.saveRead(0, .{ .id = "active", .threadId = "thread-active", .receivedAt = 1000, .bodyText = active_body });
    try std.testing.expect(try store.read(0, "newer") != null);
    try std.testing.expect(try store.read(0, "older") == null);
    try std.testing.expectEqual(active_body.len, (try store.read(0, "active")).?.bodyText.len);
    try std.testing.expect((try snapshot(a, &store, 0)).len <= cache.snapshot_limit);
}

test "browser cache: metadata quota removes older retained rows while keeping the incoming page" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subject = try a.alloc(u8, 14 * 1024);
    @memset(subject, 'x');
    var retained: [200][]const u8 = undefined;
    for (&retained, 0..) |*row, index| row.* = try std.fmt.allocPrint(a, "{{\"id\":\"old-{d}\",\"threadId\":\"old-thread-{d}\",\"subject\":\"{s}\",\"receivedAt\":{d}}}", .{ index, index, subject, 2000 - index });
    const old_rows = try std.mem.concat(a, u8, &.{ "[", try std.mem.join(a, ",", &retained), "]" });
    try store.restore(0, try document(a, old_rows, "[]", false), false);
    try std.testing.expectEqual(@as(usize, 200), j.get(try parse(a, try snapshot(a, &store, 0)), "messages").?.array.items.len);
    var fresh: [30][]const u8 = undefined;
    for (&fresh, 0..) |*row, index| row.* = try std.fmt.allocPrint(a, "{{\"id\":\"new-{d}\",\"threadId\":\"new-thread-{d}\",\"subject\":\"{s}\",\"receivedAt\":{d}}}", .{ index, index, subject, 3000 + index });
    try store.replaceList(0, try array(a, try std.mem.concat(a, u8, &.{ "[", try std.mem.join(a, ",", &fresh), "]" })), 2);
    const raw = try snapshot(a, &store, 0);
    try std.testing.expect(raw.len <= cache.snapshot_limit);
    const retained_count = j.get(try parse(a, raw), "messages").?.array.items.len;
    try std.testing.expect(retained_count >= 30 and retained_count < 230);
    const visible = try store.list(0, a, "", "");
    try std.testing.expectEqual(@as(usize, 30), visible.len);
    for (visible, 0..) |message, index| try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "new-{d}", .{29 - index}), j.text(message, "id"));
}

test "browser cache: the combined three-slot quota cannot discard another account" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try array(a, "[{\"id\":\"large\",\"threadId\":\"large-thread\"}]");
    const body = try a.alloc(u8, 1800 * 1024);
    const html = try a.alloc(u8, 1000 * 1024);
    @memset(body, 'b');
    @memset(html, 'h');
    for ([_][]const u8{ "ada@example.test", "bea@example.test", "cam@example.test" }, 0..) |account, index| {
        try store.bind(index, .{ .account = account, .clientId = actor.clientId, .grantId = actor.grantId });
        try store.replaceList(index, rows, 1791730000000);
    }
    const large: types.Message = .{ .id = "large", .threadId = "large-thread", .bodyText = body, .bodyHtml = html };
    try store.saveRead(0, large);
    try store.saveRead(1, large);
    const before = try snapshot(a, &store, 2);
    const revision = store.revision(2);
    try std.testing.expectError(error.BrowserCacheQuotaExceeded, store.saveRead(2, large));
    try std.testing.expectEqualStrings(before, try snapshot(a, &store, 2));
    try std.testing.expectEqual(revision, store.revision(2));
    try std.testing.expectEqual(body.len, (try store.read(0, "large")).?.bodyText.len);
    try std.testing.expectEqual(body.len, (try store.read(1, "large")).?.bodyText.len);
    var total: usize = 0;
    for (0..3) |index| total += (try snapshot(a, &store, index)).len;
    try std.testing.expect(total <= cache.total_limit);
    try std.testing.expectError(error.InvalidBrowserCache, store.bind(3, actor));
}

test "browser cache: clear and actor replacement advance only the affected revision" {
    var store = cache.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.bind(0, actor);
    try store.bind(1, actor);
    try store.restore(0, fixture, true);
    try store.restore(1, fixture, true);
    const first = store.revision(0);
    const second = store.revision(1);
    try store.bind(0, actor);
    try std.testing.expectEqual(first, store.revision(0));
    store.clear(0);
    try std.testing.expect(!store.valid(0));
    try std.testing.expect(!store.contactsLoaded(0));
    try std.testing.expectEqual(first +% 1, store.revision(0));
    try std.testing.expectEqual(second, store.revision(1));
    try std.testing.expect(try store.read(1, "mail-inbox") != null);
    var output: [32]u8 = undefined;
    try std.testing.expectError(error.BrowserCacheEmpty, store.snapshot(0, &output));
    try store.restore(0, fixture, true);
    const restored = store.revision(0);
    try store.bind(0, .{ .account = actor.account, .clientId = actor.clientId, .grantId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" });
    try std.testing.expect(!store.valid(0));
    try std.testing.expectEqual(restored +% 1, store.revision(0));
    try std.testing.expectError(error.InvalidBrowserCache, store.restore(0, fixture, true));
    store.clear(3);
    try std.testing.expect(!store.valid(3));
    try std.testing.expectEqual(@as(u32, 0), store.revision(3));
    try std.testing.expectError(error.InvalidBrowserCache, store.read(3, "mail-inbox"));
}

test "browser cache: failed actor allocation retains the old binding and snapshot without leaks" {
    for (0..3) |offset| {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
        var store = cache.Store.init(failing.allocator());
        defer store.deinit();
        try store.bind(0, actor);
        try store.restore(0, fixture, true);
        const before = try snapshot(std.testing.allocator, &store, 0);
        defer std.testing.allocator.free(before);
        const revision = store.revision(0);
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, store.bind(0, .{ .account = "replacement@example.test", .clientId = actor.clientId, .grantId = actor.grantId }));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(revision, store.revision(0));
        const after = try snapshot(std.testing.allocator, &store, 0);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
        // A failed rebind must not change the actor accepted by restore.
        try store.restore(0, fixture, true);
    }
}

test "browser cache: allocation failures in restore and replacements leave prior bytes intact" {
    var input: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer input.deinit();
    const rows = try array(input.allocator(), "[{\"id\":\"mail-inbox\",\"threadId\":\"thread-inbox\",\"subject\":\"Replacement\"}]");
    const contacts = try array(input.allocator(), "[{\"resourceName\":\"people/new\",\"name\":\"Replacement\"}]");
    const Operation = enum { restore, list, read, read_insert, read_changed_thread, contacts, drop_contacts };
    for (std.meta.tags(Operation)) |operation| {
        var reached_success = false;
        for (0..64) |offset| {
            var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
            var store = cache.Store.init(failing.allocator());
            defer store.deinit();
            try store.bind(0, actor);
            try store.restore(0, fixture, true);
            const before = try snapshot(std.testing.allocator, &store, 0);
            defer std.testing.allocator.free(before);
            const revision = store.revision(0);
            failing.fail_index = failing.alloc_index + offset;
            const result = switch (operation) {
                .restore => store.restore(0, fixture, false),
                .list => store.replaceList(0, rows, 1791730000001),
                .read => store.saveRead(0, .{ .id = "mail-inbox", .threadId = "thread-inbox", .bodyText = "Replacement body" }),
                .read_insert => store.saveRead(0, .{ .id = "newly-read-mail", .threadId = "newly-read-thread", .bodyText = "Fetched search body" }),
                .read_changed_thread => store.saveRead(0, .{ .id = "mail-inbox", .threadId = "changed-thread", .bodyText = "Fresh changed-thread body" }),
                .contacts => store.replaceContacts(0, contacts),
                .drop_contacts => store.dropContacts(0),
            };
            failing.fail_index = std.math.maxInt(usize);
            if (result) |_| {
                reached_success = true;
                try std.testing.expectEqual(revision +% 1, store.revision(0));
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(revision, store.revision(0));
                const after = try snapshot(std.testing.allocator, &store, 0);
                defer std.testing.allocator.free(after);
                try std.testing.expectEqualStrings(before, after);
            }
        }
        try std.testing.expect(reached_success);
    }
}
