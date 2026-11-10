//! End-to-end JSONL contract checks through the shared executor with the
//! synthetic fixture mailbox: strict fields, dry runs, lean views and safe
//! draft edits. No credentials, network or real mail are involved.
const std = @import("std");
const core = @import("terminal/core.zig");
const j = @import("terminal/json.zig");
const account = "personal@example.com";

const Harness = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    session: *core.Session,
    arena: std.heap.ArenaAllocator,
    fn init(self: *Harness, name: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.arena = .init(std.testing.allocator);
        self.env = .init(std.testing.allocator);
        try self.env.put("HOME", "/tmp/synthetic-omagma-home");
        const root = try std.fmt.allocPrint(self.arena.allocator(), ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
        self.session = try std.testing.allocator.create(core.Session);
        self.session.* = try core.Session.init(std.testing.io, std.testing.allocator, &self.env, .{ .fixtures = true, .fixture_root = "tests/fixtures/terminal", .cache_dir = root });
    }
    fn deinit(self: *Harness) void {
        self.session.deinit();
        std.testing.allocator.destroy(self.session);
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }
    /// One JSONL frame; returns the complete parsed reply.
    fn frame(self: *Harness, raw: []const u8) !j.Value {
        const a = self.arena.allocator();
        const response = try self.session.execute(a, raw);
        return std.json.parseFromSliceLeaky(j.Value, a, response, .{});
    }
    fn data(self: *Harness, raw: []const u8) !j.Value {
        const reply = try self.frame(raw);
        if (!try j.boolean(reply, "ok", false)) {
            std.debug.print("unexpected failure: {s}\n", .{j.text(j.get(reply, "error") orelse .null, "message")});
            return error.UnexpectedFailure;
        }
        return j.get(reply, "data").?;
    }
    fn failure(self: *Harness, raw: []const u8) !j.Value {
        const reply = try self.frame(raw);
        try std.testing.expect(!try j.boolean(reply, "ok", true));
        return j.get(reply, "error").?;
    }
    fn sends(self: *Harness) !i64 {
        return j.integer(try self.data("{\"cmd\":\"cache.stats\",\"account\":\"personal@example.com\"}"), "fixtureSends", -1);
    }
    fn drafts(self: *Harness) !usize {
        return (j.get(try self.data("{\"cmd\":\"draft.list\",\"account\":\"personal@example.com\"}"), "drafts") orelse return error.MissingDrafts).array.items.len;
    }
};

test "CLI contract: undeclared fields fail closed before any draft, label or send changes" {
    var h: Harness = undefined;
    try h.init("strict");
    defer h.deinit();
    // A misspelled body field used to save an empty draft that could be sent.
    const body = try h.failure("{\"id\":\"dc\",\"cmd\":\"draft.create\",\"account\":\"personal@example.com\",\"draft\":{\"to\":[\"alex@example.org\"],\"subject\":\"Hello\",\"body\":\"Hi Alex\"}}");
    try std.testing.expectEqualStrings("UnknownField", j.text(body, "code"));
    try std.testing.expectEqualStrings("draft.bodyText", j.text(body, "didYouMean"));
    try std.testing.expect(!j.get(body, "retryable").?.bool);
    try std.testing.expectEqual(@as(usize, 0), try h.drafts());
    // A misspelled safety flag never turns into a real send.
    const flag = try h.failure("{\"cmd\":\"mail.send\",\"account\":\"personal@example.com\",\"operationId\":\"op-typo\",\"dry_run\":true,\"draft\":{\"to\":[\"alex@example.org\"],\"subject\":\"Q\",\"bodyText\":\"hello\"}}");
    try std.testing.expectEqualStrings("dryRun", j.text(flag, "didYouMean"));
    try std.testing.expectEqual(@as(i64, 0), try h.sends());
    // Mutations reject fields they never honored, including operationId.
    const before = try h.data("{\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-010\"}");
    try std.testing.expectEqualStrings("UnknownField", j.text(try h.failure("{\"cmd\":\"mail.archive\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-010\",\"operationId\":\"op\"}"), "code"));
    const after = try h.data("{\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-010\"}");
    try std.testing.expectEqual(j.get(before, "labels").?.array.items.len, j.get(after, "labels").?.array.items.len);
    // replyAll is a documented alias of all instead of silently replying to one.
    const reply = try h.data("{\"cmd\":\"mail.reply\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-005\",\"replyAll\":true}");
    try std.testing.expect(j.get(reply, "cc").?.array.items.len + j.get(reply, "to").?.array.items.len > 1);
    try std.testing.expectEqualStrings("ConflictingReplyAll", j.text(try h.failure("{\"cmd\":\"mail.reply\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-005\",\"replyAll\":true,\"all\":false}"), "code"));
    // Explained executor failures keep their stable codes.
    const missing = try h.failure("{\"cmd\":\"mail.read\",\"account\":\"personal@example.com\"}");
    try std.testing.expectEqualStrings("MissingField", j.text(missing, "code"));
    try std.testing.expectEqualStrings("messageId", j.text(missing, "field"));
    const limit = try h.failure("{\"cmd\":\"mail.list\",\"account\":\"personal@example.com\",\"limit\":500}");
    try std.testing.expectEqualStrings("InvalidPageLimit", j.text(limit, "code"));
    try std.testing.expectEqual(@as(i64, 100), j.get(limit, "maximum").?.integer);
    const unknown_account = try h.failure("{\"cmd\":\"mail.read\",\"account\":\"nobody@example.com\",\"messageId\":\"shared-msg-003\"}");
    try std.testing.expectEqualStrings("UnknownAccount", j.text(unknown_account, "code"));
    try std.testing.expect(j.get(unknown_account, "configured").?.array.items.len >= 1);
    const command = try h.failure("{\"cmd\":\"mail.reed\",\"account\":\"personal@example.com\"}");
    try std.testing.expectEqualStrings("UnsupportedCommand", j.text(command, "code"));
    try std.testing.expectEqualStrings("mail.read", j.text(command, "didYouMean"));
}

test "CLI contract: no dry-run spelling on a send ever submits, queues or journals mail" {
    var h: Harness = undefined;
    try h.init("dry-run-spellings");
    defer h.deinit();
    const a = h.arena.allocator();
    const draft = try h.data("{\"cmd\":\"draft.create\",\"account\":\"personal@example.com\",\"draft\":{\"to\":\"alex@example.org\",\"subject\":\"Never sent\",\"bodyText\":\"Plan only\"}}");
    const id = j.text(draft, "id");
    const message = "\"draft\":{\"to\":[\"alex@example.org\"],\"subject\":\"Never sent\",\"bodyText\":\"Plan only\"";
    for ([_][]const u8{ "dryRun", "dry_run", "dry-run", "dryrun", "simulate", "validateOnly", "noSend" }, 0..) |key, index| {
        for ([_][]const u8{
            try std.fmt.allocPrint(a, "{{\"cmd\":\"mail.send\",\"account\":\"personal@example.com\",\"operationId\":\"op-top-{d}\",\"{s}\":true,{s}}}}}", .{ index, key, message }),
            try std.fmt.allocPrint(a, "{{\"cmd\":\"mail.send\",\"account\":\"personal@example.com\",\"operationId\":\"op-nested-{d}\",{s},\"{s}\":true}}}}", .{ index, message, key }),
            try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.send\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"operationId\":\"op-saved-{d}\",\"{s}\":true}}", .{ id, index, key }),
            try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.queue\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"operationId\":\"op-queue-{d}\",\"delaySeconds\":0,\"{s}\":true}}", .{ id, index, key }),
        }) |raw| {
            const reply = try h.frame(raw);
            // Only the declared top-level dryRun runs (as a plan); every other
            // spelling or placement is refused as an unknown field.
            if (try j.boolean(reply, "ok", false)) {
                try std.testing.expectEqualStrings("dryRun", key);
                try std.testing.expect(j.get(j.get(reply, "data").?, "dryRun").?.bool);
            } else try std.testing.expectEqualStrings("UnknownField", j.text(j.get(reply, "error").?, "code"));
        }
    }
    try std.testing.expectEqual(@as(i64, 0), try h.sends());
    try std.testing.expectEqual(@as(usize, 0), (j.get(try h.data("{\"cmd\":\"queue.list\",\"account\":\"personal@example.com\"}"), "queue") orelse return error.MissingQueue).array.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try h.data("{\"cmd\":\"operation.list\",\"account\":\"personal@example.com\"}")).object.get("operations").?.array.items.len);
}

test "CLI contract: dryRun plans sends and label changes without writing anything" {
    var h: Harness = undefined;
    try h.init("dry-run");
    defer h.deinit();
    const planned = try h.data("{\"cmd\":\"mail.send\",\"account\":\"personal@example.com\",\"operationId\":\"op-dry\",\"dryRun\":true,\"draft\":{\"to\":[\"alex@example.org\"],\"subject\":\"Direct\",\"bodyText\":\"hello\",\"bodyFormat\":\"markdown\"}}");
    try std.testing.expect(j.get(planned, "dryRun").?.bool and j.get(planned, "sendable").?.bool);
    try std.testing.expectEqualStrings("planned", j.text(planned, "status"));
    try std.testing.expectEqual(@as(usize, 64), j.text(planned, "contentDigest").len);
    try std.testing.expectEqualStrings("alex@example.org", j.text(j.get(planned, "to").?.array.items[0], "address"));
    try std.testing.expectEqual(@as(i64, 0), try h.sends());
    try std.testing.expectEqual(@as(usize, 0), (try h.data("{\"cmd\":\"operation.list\",\"account\":\"personal@example.com\"}")).object.get("operations").?.array.items.len);
    // The returned digest binds the real send to exactly the reviewed content.
    const draft = try h.data("{\"cmd\":\"draft.create\",\"account\":\"personal@example.com\",\"draft\":{\"to\":\"alex@example.org\",\"subject\":\"Saved\",\"bodyText\":\"Reviewed\"}}");
    const id = j.text(draft, "id");
    const a = h.arena.allocator();
    for ([_][]const u8{ "draft.send", "draft.queue" }) |name| {
        const plan = try h.data(try std.fmt.allocPrint(a, "{{\"cmd\":\"{s}\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"operationId\":\"op-saved\",\"dryRun\":true}}", .{ name, id }));
        try std.testing.expectEqualStrings(id, j.text(plan, "draftId"));
    }
    try std.testing.expectEqual(@as(usize, 0), (j.get(try h.data("{\"cmd\":\"queue.list\",\"account\":\"personal@example.com\"}"), "queue") orelse return error.MissingQueue).array.items.len);
    const plan = try h.data(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.send\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"operationId\":\"op-saved\",\"dryRun\":true}}", .{id}));
    const sent = try h.data(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.send\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"operationId\":\"op-saved\",\"expectedContentDigest\":\"{s}\"}}", .{ id, j.text(plan, "contentDigest") }));
    try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
    try std.testing.expectEqual(@as(i64, 1), try h.sends());
    // Label dry runs resolve the change and report it per message.
    const archive = try h.data("{\"cmd\":\"mail.archive\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-010\",\"dryRun\":true}");
    try std.testing.expectEqualStrings("INBOX", try j.string(j.get(archive, "removeLabels").?.array.items[0]));
    try std.testing.expectEqualStrings("INBOX", try j.string(j.get(archive, "removedLabels").?.array.items[0]));
    const batch = try h.data("{\"cmd\":\"mail.batch\",\"account\":\"personal@example.com\",\"messageIds\":[\"shared-msg-010\",\"shared-msg-011\"],\"action\":\"mark\",\"addLabels\":[\"Projects\"],\"dryRun\":true}");
    try std.testing.expectEqual(@as(usize, 2), j.get(batch, "messages").?.array.items.len);
    const read = try h.data("{\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-010\"}");
    var inbox = false;
    for (j.get(read, "labels").?.array.items) |label| inbox = inbox or std.mem.eql(u8, label.string, "INBOX");
    try std.testing.expect(inbox);
    try std.testing.expectEqualStrings("UnknownField", j.text(try h.failure("{\"cmd\":\"mail.reply\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-005\",\"dryRun\":true}"), "code"));
}

test "CLI contract: one-call reply, patching and guarded replacement keep threading" {
    var h: Harness = undefined;
    try h.init("drafts");
    defer h.deinit();
    const a = h.arena.allocator();
    const reply = try h.data("{\"cmd\":\"mail.reply\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-005\",\"all\":true,\"bodyText\":\"Thursday works.\"}");
    // The note sits above the attribution line and the quoted original.
    try std.testing.expect(std.mem.startsWith(u8, j.text(reply, "bodyText"), "Thursday works.\n\nOn "));
    try std.testing.expect(std.mem.indexOf(u8, j.text(reply, "bodyText"), " wrote:\n> ") != null);
    const id = j.text(reply, "id");
    const thread = j.text(reply, "threadId");
    try std.testing.expect(thread.len != 0);
    // A partial replacement that would drop recipients and threading is refused.
    const refused = try h.failure(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.update\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"draft\":{{\"bodyText\":\"Only text\"}}}}", .{id}));
    try std.testing.expectEqualStrings("DraftReplaceWouldDropThreading", j.text(refused, "code"));
    try std.testing.expect(j.text(refused, "hint").len != 0);
    // draft.patch changes only the supplied field.
    const patched = try h.data(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.patch\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"set\":{{\"bodyText\":\"Patched note\"}}}}", .{id}));
    try std.testing.expectEqualStrings("Patched note", j.text(patched, "bodyText"));
    try std.testing.expectEqualStrings(thread, j.text(patched, "threadId"));
    try std.testing.expectEqualStrings(j.text(reply, "inReplyTo"), j.text(patched, "inReplyTo"));
    try std.testing.expectEqual(j.get(reply, "cc").?.array.items.len, j.get(patched, "cc").?.array.items.len);
    const stale: [64]u8 = @splat('0');
    try std.testing.expectEqualStrings("ReviewedDraftChanged", j.text(try h.failure(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.patch\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"expectedContentDigest\":\"{s}\",\"set\":{{\"subject\":\"x\"}}}}", .{ id, &stale })), "code"));
    try std.testing.expectEqualStrings("UnknownField", j.text(try h.failure(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.patch\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"set\":{{\"body\":\"x\"}}}}", .{id})), "code"));
    // An explicit replacement remains available.
    const replaced = try h.data(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.update\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\",\"replace\":true,\"draft\":{{\"bodyText\":\"Only text\"}}}}", .{id}));
    try std.testing.expectEqualStrings("", j.text(replaced, "threadId"));
    // A complete returned draft passed back unchanged, digest included, is accepted.
    const read = try h.data(try std.fmt.allocPrint(a, "{{\"cmd\":\"draft.read\",\"account\":\"personal@example.com\",\"draftId\":\"{s}\"}}", .{id}));
    var request = try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id });
    try request.object.put(a, "draft", read);
    _ = try h.data(try std.json.Stringify.valueAlloc(a, request, .{}));
}

test "CLI contract: lean views, receipts and relative dates reshape replies only" {
    var h: Harness = undefined;
    try h.init("views");
    defer h.deinit();
    const listed = try h.data("{\"cmd\":\"mail.list\",\"account\":\"personal@example.com\",\"label\":\"INBOX\",\"limit\":30,\"view\":\"summary\"}");
    for (j.get(listed, "messages").?.array.items) |row| {
        try std.testing.expect(j.get(row, "bodyText") == null and j.text(row, "id").len != 0);
        try std.testing.expect(j.text(row, "receivedAtIso").len == 20);
    }
    const read = try h.data("{\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-003\",\"body\":\"text\",\"attachmentData\":false,\"fields\":[\"id\",\"bodyText\",\"attachments\",\"rfcMessageId\"]}");
    try std.testing.expectEqual(@as(usize, 4), read.object.count());
    try std.testing.expect(j.get(j.get(read, "attachments").?.array.items[0], "data") == null);
    try std.testing.expectEqualStrings("<fixture-003-personal@example.org>", j.text(read, "rfcMessageId"));
    const receipt = try h.data("{\"cmd\":\"mail.mark\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-011\",\"starred\":true}");
    try std.testing.expectEqualStrings("shared-msg-011", j.text(receipt, "messageId"));
    try std.testing.expectEqualStrings("STARRED", try j.string(j.get(receipt, "addedLabels").?.array.items[0]));
    try std.testing.expect(j.get(receipt, "bodyText") == null);
    const full = try h.data("{\"cmd\":\"mail.mark\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-011\",\"starred\":false,\"view\":\"message\"}");
    try std.testing.expectEqualStrings("shared-msg-011", j.text(full, "id"));
    try std.testing.expectEqualStrings("InvalidView", j.text(try h.failure("{\"cmd\":\"mail.list\",\"account\":\"personal@example.com\",\"view\":\"tiny\"}"), "code"));
    const reminder = try h.data("{\"cmd\":\"reminder.set\",\"account\":\"personal@example.com\",\"messageId\":\"shared-msg-010\",\"expectedVersion\":0,\"dueDate\":\"tomorrow\"}");
    try std.testing.expectEqual(@as(usize, 10), j.text(reminder, "resolvedDate").len);
    try std.testing.expectEqualStrings(j.text(reminder, "resolvedDate"), j.text(j.get(reminder, "entry").?, "dueDate"));
}
