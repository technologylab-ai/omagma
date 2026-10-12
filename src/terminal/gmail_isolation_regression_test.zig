//! Fictional provider batches exercise the same normalization and history
//! boundaries as live Gmail, without credentials, storage or mailbox writes.
const std = @import("std");
const gmail = @import("gmail.zig");
const j = @import("json.zig");
const decode = @import("gmail_decode.zig");

const Peer = struct {
    kind: enum { multi_from, bcc, bad_body, bad_labels, oversized_json } = .multi_from,
    fatal: ?anyerror = null,
    calls: usize = 0,
    writes: usize = 0,
    labels_only: bool = false,

    fn transport(self: *Peer) gmail.Transport {
        return .{ .context = self, .requestFn = request, .temporary_allocator = std.testing.allocator };
    }
    fn message(self: *Peer, a: std.mem.Allocator, id: []const u8, full: bool) !j.Value {
        const odd = std.mem.eql(u8, id, "odd");
        var value = try j.value(a, .{
            .id = id,
            .threadId = "thread",
            .internalDate = "1791651960000",
            .labelIds = [_][]const u8{ "INBOX", "UNREAD" },
            .snippet = "Synthetic visible snippet",
            .payload = .{ .mimeType = "text/plain", .headers = [_]struct { name: []const u8, value: []const u8 }{
                .{ .name = "From", .value = if (odd and self.kind == .multi_from) "One <one@example.test>, Two <two@example.test>" else "One <one@example.test>" },
                .{ .name = "Sender", .value = "agent@example.test" },
                .{ .name = "To", .value = "self@example.test" },
                .{ .name = "Bcc", .value = if (odd and self.kind == .bcc) "Person <@route.example:person@example.test>" else "" },
                .{ .name = "Subject", .value = if (odd) "Unusual but identifiable" else "Ordinary neighbor" },
                .{ .name = "Message-ID", .value = "<synthetic@example.test>" },
            }, .body = .{ .size = @as(usize, if (odd and self.kind == .bad_body) 20 else 4), .data = "Qm9keQ" } },
        });
        if (!full) {
            var payload = j.get(value, "payload").?;
            _ = payload.object.swapRemove("body");
            try value.object.put(a, "payload", payload);
        }
        if (odd and self.kind == .bad_labels) try value.object.put(a, "labelIds", .{ .integer = 7 });
        return value;
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *Peer = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (method != .GET or body != null) {
            self.writes += 1;
            return error.UnexpectedWrite;
        }
        if (std.mem.indexOf(u8, url, "/profile?") != null) return j.value(a, .{ .historyId = "20" });
        if (std.mem.indexOf(u8, url, "/history?") != null and self.labels_only) return j.value(a, .{ .historyId = "21", .history = .{.{ .id = "21", .labelsRemoved = .{.{ .message = .{ .id = "odd" } }} }} });
        if (std.mem.indexOf(u8, url, "/history?") != null) return j.value(a, .{ .historyId = "21", .history = .{.{
            .id = "21",
            .messagesAdded = .{ .{ .message = .{ .id = "good1" } }, .{ .message = .{ .id = "odd" } }, .{ .message = .{ .id = "good2" } } },
        }} });
        if (std.mem.indexOf(u8, url, "/threads/") != null) {
            if (self.kind == .oversized_json) {
                if (std.mem.indexOf(u8, url, "format=full") != null) return error.JsonTooManyTokens;
                return j.value(a, .{ .id = "thread", .messages = .{ .{ .id = "good1", .threadId = "thread" }, .{ .id = "odd", .threadId = "thread" }, .{ .id = "good2", .threadId = "thread" } } });
            }
            return j.value(a, .{ .messages = [_]j.Value{ try self.message(a, "good1", true), try self.message(a, "odd", true), try self.message(a, "good2", true) } });
        }
        if (std.mem.indexOf(u8, url, "/messages?") != null) return j.value(a, .{ .messages = .{ .{ .id = "good1", .threadId = "thread" }, .{ .id = "odd", .threadId = "thread" }, .{ .id = "good2", .threadId = "thread" } } });
        for ([_][]const u8{ "good1", "odd", "good2" }) |id| {
            const needle = try std.fmt.allocPrint(a, "/messages/{s}?", .{id});
            if (std.mem.indexOf(u8, url, needle) == null) continue;
            if (std.mem.eql(u8, id, "odd")) {
                if (self.fatal) |err| return err;
                if (self.kind == .oversized_json and std.mem.indexOf(u8, url, "format=minimal") == null) return error.JsonTooManyTokens;
            }
            if (std.mem.indexOf(u8, url, "format=minimal") != null) return j.value(a, .{ .id = id, .threadId = "thread" });
            return self.message(a, id, std.mem.indexOf(u8, url, "format=full") != null);
        }
        return error.UnexpectedProviderRequest;
    }
};

fn assertNeighbors(value: j.Value) !void {
    const messages = j.get(value, "messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    for ([_][]const u8{ "good1", "odd", "good2" }) |id| {
        var found = false;
        for (messages) |message| found = found or std.mem.eql(u8, j.text(message, "id"), id);
        try std.testing.expect(found);
    }
}

test "message isolation: legal multiple From plus Sender and unsupported Bcc retain body without reply targets" {
    for ([_]@FieldType(Peer, "kind"){ .multi_from, .bcc }) |kind| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: Peer = .{ .kind = kind };
        const message = try gmail.readAuthorizedMessage(a, "self@example.test", &.{"mail-read"}, peer.transport(), "odd");
        try std.testing.expectEqualStrings("Body", message.bodyText);
        try std.testing.expect(message.decodeWarning.len != 0);
        try std.testing.expectEqualStrings("", message.from.address);
        try std.testing.expectEqual(@as(usize, 0), message.replyTo.len + message.to.len + message.cc.len);
        try std.testing.expectEqualStrings("", message.messageId);
        try std.testing.expectError(error.UnsafeReplyMetadata, @import("conversation_draft.zig").reply(a, message, .{ .account = "self@example.test" }));
        try std.testing.expectEqual(@as(usize, 0), peer.writes);
    }
}

test "message isolation: good unusual good survives list bootstrap history and thread" {
    for ([_]@FieldType(Peer, "kind"){ .multi_from, .bad_body, .bad_labels, .oversized_json }) |kind| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: Peer = .{ .kind = kind };
        const request = try j.value(a, .{ .limit = @as(u8, 3) });
        try assertNeighbors(try gmail.listAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), request));
        const bootstrap = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), "mail.refresh", request);
        try assertNeighbors(bootstrap);
        try std.testing.expectEqualStrings("20", j.text(bootstrap, "historyId"));
        var history_request = try j.copyObject(a, request);
        try history_request.object.put(a, "historyId", .{ .string = "20" });
        const history = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), "mail.refresh", history_request);
        try assertNeighbors(history);
        try std.testing.expectEqualStrings("21", j.text(history, "historyId"));
        const thread = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), "mail.thread", try j.value(a, .{ .threadId = "thread" }));
        try assertNeighbors(thread);
        if (kind == .bad_body) {
            for (j.get(thread, "messages").?.array.items) |message| {
                if (std.mem.eql(u8, j.text(message, "id"), "odd")) try std.testing.expectEqualStrings("BodySizeMismatch", j.text(message, "bodyCacheError")) else try std.testing.expectEqualStrings("Body", j.text(message, "bodyText"));
            }
        }
        try std.testing.expectEqual(@as(usize, 0), peer.writes);
    }
}

test "message isolation: fatal failures and mismatched identities never become placeholders" {
    for ([_]anyerror{ error.OutOfMemory, error.Canceled, error.Timeout, error.InvalidGrant, error.PermissionDenied, error.MessageIdentityMismatch }) |err| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: Peer = .{ .fatal = err };
        try std.testing.expectError(err, gmail.listAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), try j.value(a, .{ .limit = @as(u8, 3) })));
        try std.testing.expect(!decode.messageRefusal(err));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.MessageIdentityMismatch, decode.normalize(try j.value(a, .{ .id = "odd", .threadId = "invalid/thread" }), a, null));
}

test "message isolation: unverifiable history labels advance checkpoint without inventing removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var peer: Peer = .{ .kind = .bad_labels, .labels_only = true };
    const value = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), "mail.refresh", try j.value(a, .{ .historyId = "20", .knownIds = [_][]const u8{"odd"} }));
    const plan = try j.decode(gmail.RefreshPlan, a, value);
    try std.testing.expectEqualStrings("21", plan.historyId);
    try std.testing.expect(plan.partial);
    try std.testing.expectEqual(@as(usize, 1), plan.labels.len);
    try std.testing.expect(!plan.labels[0].verified);
    try std.testing.expectEqualStrings("InvalidLabels", plan.labels[0].warning);
    try std.testing.expectEqual(@as(usize, 0), plan.deleted.len);
}

const LargeThreadPeer = struct {
    reads: usize = 0,
    const body_bytes = 512 * 1024;
    fn transport(self: *LargeThreadPeer) gmail.Transport {
        return .{ .context = self, .requestFn = request, .temporary_allocator = std.testing.allocator };
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *LargeThreadPeer = @ptrCast(@alignCast(ctx));
        if (method != .GET or body != null) return error.UnexpectedWrite;
        if (std.mem.indexOf(u8, url, "/threads/") != null) {
            if (std.mem.indexOf(u8, url, "format=full") != null) return error.ResponseTooLarge;
            const entries = try a.alloc(struct { id: []const u8, threadId: []const u8, internalDate: i64 }, 12);
            for (entries, 0..) |*entry, i| entry.* = .{ .id = try std.fmt.allocPrint(a, "large-{d}", .{i}), .threadId = "large-thread", .internalDate = @intCast(i) };
            return j.value(a, .{ .id = "large-thread", .messages = entries });
        }
        const prefix = "/messages/";
        const begin = (std.mem.indexOf(u8, url, prefix) orelse return error.UnexpectedProviderRequest) + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, url, begin, '?') orelse return error.UnexpectedProviderRequest;
        self.reads += 1;
        const text = try a.alloc(u8, body_bytes);
        @memset(text, 'x');
        const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(text.len));
        const order = try std.fmt.parseInt(i64, url[begin + "large-".len .. end], 10);
        return j.value(a, .{ .id = url[begin..end], .threadId = "large-thread", .internalDate = order, .labelIds = [_][]const u8{"INBOX"}, .payload = .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "sender@example.test" }, .{ .name = "Subject", .value = "Large synthetic member" } }, .body = .{ .size = text.len, .data = std.base64.url_safe_no_pad.Encoder.encode(encoded, text) } } });
    }
};

test "message isolation: aggregate thread budget retains every ID and leaves individual reads available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var peer: LargeThreadPeer = .{};
    const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), "mail.thread", try j.value(a, .{ .threadId = "large-thread" }));
    const messages = j.get(result, "messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 12), messages.len);
    try std.testing.expect(try j.boolean(result, "partial", false));
    var full: usize = 0;
    var refused: usize = 0;
    var retained_bytes: usize = 0;
    var refused_id: []const u8 = "";
    for (messages) |message| {
        if (j.text(message, "bodyCacheError").len == 0) {
            full += 1;
            retained_bytes += decode.serializedBytes(try j.decode(@import("types.zig").Message, a, message));
            try std.testing.expectEqual(@as(usize, LargeThreadPeer.body_bytes), j.text(message, "bodyText").len);
        } else {
            refused += 1;
            refused_id = j.text(message, "id");
            try std.testing.expectEqualStrings("ThreadBodyBudgetExceeded", j.text(message, "bodyCacheError"));
            try std.testing.expectEqualStrings("", j.text(j.get(message, "from").?, "address"));
            try std.testing.expectEqual(@as(usize, 0), j.text(message, "bodyText").len);
        }
    }
    try std.testing.expect(full != 0 and refused != 0);
    try std.testing.expect(retained_bytes <= @import("types.zig").Limits.thread_bytes);
    try std.testing.expectEqual(@as(usize, 12), peer.reads);
    try std.testing.expectEqualStrings("large-0", j.text(messages[0], "id"));
    try std.testing.expectEqualStrings("ThreadBodyBudgetExceeded", j.text(messages[0], "bodyCacheError"));
    try std.testing.expectEqualStrings("large-11", j.text(messages[messages.len - 1], "id"));
    try std.testing.expectEqualStrings("", j.text(messages[messages.len - 1], "bodyCacheError"));
    const independent = try gmail.readAuthorizedMessage(a, "self@example.test", &.{"mail-read"}, peer.transport(), refused_id);
    try std.testing.expectEqual(@as(usize, LargeThreadPeer.body_bytes), independent.bodyText.len);
    try std.testing.expectEqualStrings("", independent.bodyCacheError);
}

const WideMetadataPeer = struct {
    subject: []const u8,
    references: []const u8,
    const count = 68;
    fn transport(self: *WideMetadataPeer) gmail.Transport {
        return .{ .context = self, .requestFn = request, .temporary_allocator = std.testing.allocator };
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *WideMetadataPeer = @ptrCast(@alignCast(ctx));
        if (method != .GET or body != null) return error.UnexpectedWrite;
        if (std.mem.indexOf(u8, url, "/profile?") != null) return j.value(a, .{ .historyId = "20" });
        if (std.mem.indexOf(u8, url, "/history?") != null) {
            const entries = try a.alloc(struct { message: struct { id: []const u8 } }, count);
            for (entries, 0..) |*entry, i| entry.* = .{ .message = .{ .id = try std.fmt.allocPrint(a, "wide-{d}", .{i}) } };
            return j.value(a, .{ .historyId = "21", .history = .{.{ .id = "21", .messagesAdded = entries }} });
        }
        if (std.mem.indexOf(u8, url, "/messages?") != null) {
            const entries = try a.alloc(struct { id: []const u8, threadId: []const u8 }, count);
            for (entries, 0..) |*entry, i| entry.* = .{ .id = try std.fmt.allocPrint(a, "wide-{d}", .{i}), .threadId = "wide-thread" };
            return j.value(a, .{ .messages = entries });
        }
        const prefix = "/messages/";
        const begin = (std.mem.indexOf(u8, url, prefix) orelse return error.UnexpectedProviderRequest) + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, url, begin, '?') orelse return error.UnexpectedProviderRequest;
        const id = url[begin..end];
        const ordinary = std.mem.eql(u8, id, "wide-0") or std.mem.eql(u8, id, "wide-67");
        var value = try j.value(a, .{ .id = id, .threadId = "wide-thread", .internalDate = "42", .labelIds = [_][]const u8{ "INBOX", "UNREAD", "Label_project" }, .payload = .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "sender@example.test" }, .{ .name = "Subject", .value = if (ordinary) "Ordinary neighbor" else self.subject }, .{ .name = "References", .value = if (ordinary) "" else self.references } }, .body = .{ .size = @as(usize, 4), .data = "Qm9keQ" } } });
        if (std.mem.indexOf(u8, url, "format=full") == null) _ = value.object.getPtr("payload").?.object.swapRemove("body");
        return value;
    }
};

test "message isolation: metadata quota keeps large-header batches and both good neighbors through list bootstrap history" {
    for (0..3) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const subject = try a.alloc(u8, @import("mail_limits.zig").subject_bytes);
        @memset(subject, 's');
        const local: [870]u8 = @splat('r');
        const reference = try std.fmt.allocPrint(a, "<{s}@example.test>", .{local});
        var references: std.ArrayList(u8) = .empty;
        for (0..64) |i| {
            if (i != 0) try references.append(a, ' ');
            try references.appendSlice(a, reference);
        }
        try @import("mime.zig").validateReferences(references.items);
        var peer: WideMetadataPeer = .{ .subject = subject, .references = references.items };
        var request = try j.value(a, .{ .limit = @as(u8, 100) });
        if (mode == 2) try request.object.put(a, "historyId", .{ .string = "20" });
        const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(), if (mode == 0) "mail.list" else "mail.refresh", request);
        const messages = j.get(result, "messages").?.array.items;
        try std.testing.expectEqual(@as(usize, WideMetadataPeer.count), messages.len);
        try std.testing.expect(try j.boolean(result, "partial", false));
        if (mode != 0) try std.testing.expectEqualStrings(if (mode == 1) "20" else "21", j.text(result, "historyId"));
        var full_bytes: usize = 0;
        var refused_id: []const u8 = "";
        for (messages) |message| {
            if (std.mem.eql(u8, j.text(message, "decodeWarning"), "MetadataBudgetExceeded")) {
                refused_id = j.text(message, "id");
                try std.testing.expectEqualStrings("", j.text(message, "bodyCacheError"));
                try std.testing.expectEqualStrings("", j.text(j.get(message, "from").?, "address"));
                try std.testing.expect(try j.boolean(message, "labelsVerified", false));
                try std.testing.expect(try j.boolean(message, "unread", false));
                const labels = j.get(message, "labels").?.array.items;
                try std.testing.expectEqual(@as(usize, 3), labels.len);
                try std.testing.expectEqualStrings("INBOX", labels[0].string);
                try std.testing.expectEqualStrings("UNREAD", labels[1].string);
                try std.testing.expectEqualStrings("Label_project", labels[2].string);
            } else full_bytes += decode.serializedBytes(try j.decode(@import("types.zig").Message, a, message));
        }
        try std.testing.expect(refused_id.len != 0);
        try std.testing.expect(full_bytes <= @import("types.zig").Limits.metadata_batch_bytes);
        try std.testing.expectEqualStrings("wide-0", j.text(messages[0], "id"));
        try std.testing.expectEqualStrings("wide-67", j.text(messages[messages.len - 1], "id"));
        try std.testing.expectEqualStrings("", j.text(messages[0], "decodeWarning"));
        try std.testing.expectEqualStrings("", j.text(messages[messages.len - 1], "decodeWarning"));
        const independent = try gmail.readAuthorizedMessage(a, "self@example.test", &.{"mail-read"}, peer.transport(), refused_id);
        try std.testing.expectEqualStrings("Body", independent.bodyText);
        try std.testing.expectEqualStrings(subject, independent.subject);
        try std.testing.expectEqualStrings(references.items, independent.references);
        try std.testing.expectEqualStrings("", independent.decodeWarning);
    }
}

const WindowThreadPeer = struct {
    fallback: bool,
    bad_omitted_identity: bool = false,
    reads: usize = 0,
    read_ids: [40]bool = @splat(false),
    fn transport(self: *@This(), limit: usize) gmail.Transport {
        return .{ .context = self, .requestFn = request, .temporary_allocator = std.testing.allocator, .thread_limit = limit };
    }
    fn message(self: *@This(), a: std.mem.Allocator, order: usize, full: bool) !j.Value {
        var value = try j.value(a, .{ .id = try std.fmt.allocPrint(a, "window-{d:0>2}", .{order}), .threadId = if (order == 0 and self.bad_omitted_identity) "other-thread" else "window-thread", .internalDate = order, .labelIds = [_][]const u8{ "INBOX", "UNREAD" }, .payload = .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "sender@example.test" }, .{ .name = "Subject", .value = "Windowed thread" } }, .body = .{ .size = @as(usize, 4), .data = "Qm9keQ" } } });
        if (!full) _ = value.object.swapRemove("payload");
        return value;
    }
    fn request(context: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (method != .GET or body != null) return error.UnexpectedWrite;
        if (std.mem.indexOf(u8, url, "/threads/") != null) {
            const full = std.mem.indexOf(u8, url, "format=full") != null;
            if (self.fallback and full) return error.ResponseTooLarge;
            if (!full and std.mem.indexOf(u8, url, "format=metadata&fields=id,messages(id,threadId,internalDate)") == null) return error.UnexpectedProviderRequest;
            const entries = try a.alloc(j.Value, 40);
            // Date order differs from both response position and lexical ID.
            for (entries, 0..) |*entry, i| entry.* = try self.message(a, (i * 17) % entries.len, full);
            return j.value(a, .{ .id = "window-thread", .messages = entries });
        }
        const prefix = "/messages/window-";
        const start = (std.mem.indexOf(u8, url, prefix) orelse return error.UnexpectedProviderRequest) + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, url, start, '?') orelse return error.UnexpectedProviderRequest;
        const order = try std.fmt.parseInt(usize, url[start..end], 10);
        if (order >= self.read_ids.len or self.read_ids[order]) return error.UnexpectedProviderRequest;
        self.read_ids[order] = true;
        self.reads += 1;
        return self.message(a, order, true);
    }
};

test "message isolation: bounded threads select newest dates before decoding or individual full fetches" {
    for ([_]bool{ false, true }) |fallback| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: WindowThreadPeer = .{ .fallback = fallback };
        const result = try gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(30), "mail.thread", try j.value(a, .{ .threadId = "window-thread" }));
        const messages = j.get(result, "messages").?.array.items;
        try std.testing.expectEqual(@as(usize, 30), messages.len);
        try std.testing.expectEqual(@as(i64, 10), j.get(result, "omittedMessages").?.integer);
        try std.testing.expect(try j.boolean(result, "partial", false));
        for (messages, 10..) |message, order| {
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "window-{d:0>2}", .{order}), j.text(message, "id"));
            try std.testing.expectEqualStrings("Body", j.text(message, "bodyText"));
            try std.testing.expect(try j.boolean(message, "unread", false));
        }
        try std.testing.expectEqual(@as(usize, if (fallback) 30 else 0), peer.reads);
        for (peer.read_ids, 0..) |was_read, order| try std.testing.expectEqual(fallback and order >= 10, was_read);
        peer.bad_omitted_identity = true;
        peer.reads = 0;
        try std.testing.expectError(error.MessageIdentityMismatch, gmail.dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, peer.transport(30), "mail.thread", try j.value(a, .{ .threadId = "window-thread" })));
        try std.testing.expectEqual(@as(usize, 0), peer.reads);
    }
}
