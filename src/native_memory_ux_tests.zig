const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/calendar_ui.zig"));
    std.testing.refAllDecls(@import("terminal/calendar_notifications.zig"));
    std.testing.refAllDecls(@import("terminal/batch.zig"));
    std.testing.refAllDecls(@import("terminal/draft_measure_commands.zig"));
    std.testing.refAllDecls(@import("terminal/gmail.zig"));
}

const WorkerConversation = struct {
    const Core = @import("terminal/core.zig").Session;
    const t = @import("terminal/types.zig");
    const j = @import("terminal/json.zig");
    const account = "personal@example.com";
    const plain = "Keep the complete original and all three screenshots.";
    const html = "<html><body><p>Keep the complete original.</p><img src='cid:shot-0@fixture'><img src='cid:shot-1@fixture'><img src='cid:shot-2@fixture'></body></html>";
    const image_count = 3;
    const operation_id = "one-mib-formatted-reply-send";

    session: *Core,
    saved: [3]@import("bounded.zig").Text(256) = @splat(.{}),
    progress_calls: usize = 0,
    failure: ?anyerror = null,

    fn image(index: usize) [9]u8 {
        var bytes: [9]u8 = undefined;
        @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
        bytes[8] = @intCast(index);
        return bytes;
    }
    fn encode(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        return encoder.encode(try a.alloc(u8, encoder.calcSize(bytes.len)), bytes);
    }
    fn fixture(a: std.mem.Allocator) ![]const u8 {
        const parts = try a.alloc(j.Value, 2 + image_count);
        parts[0] = try j.value(a, .{ .partId = "plain", .mimeType = "text/plain", .body = .{ .size = plain.len, .data = try encode(a, plain) } });
        parts[1] = try j.value(a, .{ .partId = "html", .mimeType = "text/html", .body = .{ .size = html.len, .data = try encode(a, html) } });
        for (parts[2..], 0..) |*part, index| {
            const bytes = image(index);
            part.* = try j.value(a, .{
                .partId = try std.fmt.allocPrint(a, "shot-{d}", .{index}),
                .mimeType = "image/png",
                .filename = try std.fmt.allocPrint(a, "shot-{d}.png", .{index}),
                .headers = .{
                    .{ .name = "Content-ID", .value = try std.fmt.allocPrint(a, "<shot-{d}@fixture>", .{index}) },
                    .{ .name = "Content-Disposition", .value = "inline" },
                },
                .body = .{ .size = bytes.len, .data = try encode(a, &bytes) },
            });
        }
        return j.encodeAlloc(a, .{
            .account = account,
            .generation = 1000,
            .pages = .{.{ .pageToken = "", .response = .{ .messages = .{.{ .id = "worker-source", .threadId = "worker-thread" }}, .resultSizeEstimate = 1 } }},
            .messages = .{.{
                .id = "worker-source",
                .threadId = "worker-thread",
                .historyId = "1000",
                .labelIds = .{"INBOX"},
                .internalDate = "1",
                .payload = .{
                    .mimeType = "multipart/related",
                    .headers = .{
                        .{ .name = "From", .value = "River Fixture <river@example.test>" },
                        .{ .name = "To", .value = account },
                        .{ .name = "Cc", .value = "Peer Fixture <peer@example.test>" },
                        .{ .name = "Subject", .value = "Worker original" },
                        .{ .name = "Message-ID", .value = "<worker-source@example.test>" },
                        .{ .name = "Date", .value = "Fri, 23 Oct 2026 12:00:00 +0000" },
                    },
                    .parts = parts,
                },
            }},
        }, .{});
    }
    fn progress(context: *anyopaque, _: t.FetchProgress) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.progress_calls += 1;
    }
    fn call(self: *@This(), a: std.mem.Allocator, request: anytype) !j.Value {
        const raw = try j.encodeAlloc(a, request, .{});
        // This is the production TUI path, including its progress Session
        // wrapper. Calling dispatch directly misses the failing parent frame.
        const response = try self.session.client().callWithProgress(a, raw, .{ .ctx = self, .reportFn = progress });
        const envelope = try std.json.parseFromSliceLeaky(j.Value, a, response, .{});
        if (!try j.boolean(envelope, "ok", false)) {
            std.debug.print("worker conversation rejected: {s}\n", .{j.text(j.get(envelope, "error") orelse .null, "code")});
            return error.WorkerConversationRejected;
        }
        return j.get(envelope, "data") orelse error.MissingWorkerResponse;
    }
    fn expectOriginal(self: *@This(), a: std.mem.Allocator, draft: t.Draft) !void {
        const original = draft.original orelse return error.MissingOriginal;
        try std.testing.expectEqualStrings(html, original.bodyHtml);
        try std.testing.expectEqualStrings(plain, original.bodyText);
        try std.testing.expectEqual(@as(usize, image_count), original.resources.len);
        try std.testing.expectEqual(@as(usize, 0), draft.attachments.len);
        var store = try self.session.openStore(a, account, true);
        defer store.close();
        // Actual history exists before every capture, including the second
        // Incoming reservation after its first image has been published.
        try std.testing.expect(store.state.history.operations >= 1);
        for (original.resources, 0..) |resource, index| {
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "shot-{d}@fixture", .{index}), resource.contentId.?);
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "shot-{d}.png", .{index}), resource.filename);
            try std.testing.expectEqualStrings("image/png", resource.mimeType);
            try std.testing.expectEqualStrings("", resource.data);
            const expected = image(index);
            try std.testing.expectEqual(expected.len, resource.size);
            const file = try @import("terminal/attachment_blob.zig").open(&store, resource.blobId.?, resource.size);
            defer file.close(std.testing.io);
            var actual: [10]u8 = undefined;
            const count = try file.readPositional(std.testing.io, &.{&actual}, 0);
            try std.testing.expectEqualSlices(u8, &expected, actual[0..count]);
        }
    }
    fn start(self: *@This()) void {
        self.run() catch |err| {
            self.failure = err;
        };
    }
    fn run(self: *@This()) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for (0..3) |index| {
            const result = try self.call(a, .{
                .cmd = if (index == 2) @as([]const u8, "mail.forward") else "mail.reply",
                .account = account,
                .messageId = "worker-source",
                .all = index == 1,
                .bodyFormat = "markdown",
                .preserveFormatting = true,
            });
            const draft = try @import("terminal/core.zig").decodeDraft(a, result);
            try self.saved[index].set(draft.id);
            try self.expectOriginal(a, draft);
            try std.testing.expectEqual(@as(usize, if (index == 2) 0 else 1), draft.to.len);
            if (index != 2) try std.testing.expectEqualStrings("river@example.test", draft.to[0].address);
            try std.testing.expectEqual(@as(usize, if (index == 1) 1 else 0), draft.cc.len);
            if (index == 1) try std.testing.expectEqualStrings("peer@example.test", draft.cc[0].address);
            try std.testing.expectEqualStrings(if (index == 2) "" else "worker-thread", draft.threadId);
        }
        // Refresh has a second progress Session wrapper. Exercise its real
        // nested copy with retained history on the same bounded worker too.
        const refreshed = try self.call(a, .{ .cmd = "mail.refresh", .account = account, .limit = 32 });
        try std.testing.expect(try j.boolean(refreshed, "refreshed", false));
        const messages = (j.get(refreshed, "messages") orelse return error.MissingRefreshedMessages).array.items;
        try std.testing.expectEqual(@as(usize, 1), messages.len);
        try std.testing.expectEqualStrings("worker-source", j.text(messages[0], "id"));
        const request = .{ .cmd = "draft.send", .account = account, .draftId = self.saved[0].slice(), .operationId = operation_id };
        const first = try self.call(a, request);
        try std.testing.expectEqualStrings("applied", j.text(first, "outcome"));
        const replay = try self.call(a, request);
        try std.testing.expectEqualStrings(try j.encodeAlloc(a, first, .{}), try j.encodeAlloc(a, replay, .{}));
        const stats = try self.call(a, .{ .cmd = "cache.stats", .account = account });
        try std.testing.expectEqual(@as(i64, 2), try j.integer(stats, "fixtureSends", -1));
    }
};

test "native worker stack: formatted reply reply-all and forward retain exact sources and replay on one MiB" {
    if (!@import("terminal/types.zig").Limits.native) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "fixtures/accounts");
    try tmp.dir.writeFile(io, .{ .sub_path = "fixtures/accounts/personal.json", .data = try WorkerConversation.fixture(a) });
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", base);
    const options: WorkerConversation.t.Options = .{
        .fixtures = true,
        .fixture_root = try std.fmt.allocPrint(a, "{s}/fixtures", .{base}),
        .cache_dir = try std.fmt.allocPrint(a, "{s}/cache", .{base}),
    };
    // Session/config setup belongs to the test's main stack, exactly as in
    // native startup; the worker only receives a pointer to the stable owner.
    const session = try a.create(WorkerConversation.Core);
    try session.initInto(io, a, &env, options, null);
    defer session.deinit();
    var work: WorkerConversation = .{ .session = session };
    _ = try work.call(a, .{
        .cmd = "mail.send",
        .account = WorkerConversation.account,
        .operationId = "prior-worker-history",
        .draft = WorkerConversation.t.Draft{ .to = &.{.{ .address = "prior@example.test" }}, .subject = "Retained history", .bodyText = "Earlier source remains durable." },
    });
    work.progress_calls = 0;
    const thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, WorkerConversation.start, .{&work});
    thread.join();
    if (work.failure) |err| return err;
    try std.testing.expect(work.progress_calls > 0);

    // A separate Session must reopen both active captures and the sent source;
    // operation replay after restart must still produce exactly one new send.
    const restarted = try a.create(WorkerConversation.Core);
    try restarted.initInto(io, a, &env, options, null);
    defer restarted.deinit();
    work.session = restarted;
    for (work.saved) |saved| {
        const result = try work.call(a, .{ .cmd = "draft.read", .account = WorkerConversation.account, .draftId = saved.slice() });
        try work.expectOriginal(a, try @import("terminal/core.zig").decodeDraft(a, result));
    }
    const replay = try work.call(a, .{ .cmd = "draft.send", .account = WorkerConversation.account, .draftId = work.saved[0].slice(), .operationId = WorkerConversation.operation_id });
    try std.testing.expectEqualStrings("applied", WorkerConversation.j.text(replay, "outcome"));
    const stats = try work.call(a, .{ .cmd = "cache.stats", .account = WorkerConversation.account });
    try std.testing.expectEqual(@as(i64, 2), try WorkerConversation.j.integer(stats, "fixtureSends", -1));
}
