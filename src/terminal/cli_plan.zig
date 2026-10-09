//! One-shot convenience commands compose the shared executor's account-scoped
//! requests. Every mutation still reaches the same journal and pinned targets.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const files = @import("files.zig");
pub const Options = struct {
    attachments: []const []const u8 = &.{},
    send_delay: ?i64 = null,
    browser: bool = false,
};
const Reply = struct { raw: []const u8, frame: j.Value, data: j.Value };
fn issue(a: std.mem.Allocator, client: t.Client, request: j.Value) !Reply {
    const raw = try client.call(a, try std.json.Stringify.valueAlloc(a, request, .{}));
    const frame = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
    return .{ .raw = raw, .frame = frame, .data = j.get(frame, "data") orelse .null };
}
fn succeeded(reply: Reply) !bool {
    return j.boolean(reply.frame, "ok", false);
}
fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn action(command: []const u8) ?[]const u8 {
    for ([_][]const u8{ "archive", "trash", "restore", "spam", "unspam", "mark" }) |verb| {
        if (std.mem.startsWith(u8, command, "mail.") and eq(command[5..], verb)) return verb;
    }
    return null;
}
fn oneId(a: std.mem.Allocator, request: j.Value) !j.Value {
    if (j.get(request, "messageIds")) |ids| return ids;
    return j.value(a, .{try j.required(request, "messageId")});
}
pub fn execute(io: std.Io, a: std.mem.Allocator, client: t.Client, input: j.Value, options: Options) ![]const u8 {
    var request = try j.copyObject(a, input);
    var command = try j.required(request, "cmd");
    if (try j.boolean(request, "cacheOnly", false) and (options.attachments.len != 0 or options.send_delay != null or options.browser or j.get(request, "scope") != null)) return error.CacheUnsupported;
    if (options.browser) {
        if (!eq(command, "draft.preview") and !eq(command, "draft.open-preview")) return error.BrowserRequiresPreview;
        _ = try j.required(request, "draftId");
        if (j.get(request, "draft") != null) return error.BrowserPreviewRequiresSavedDraft;
        command = "draft.open-preview";
        try request.object.put(a, "cmd", .{ .string = command });
    }
    if (options.send_delay) |delay| {
        if (delay < 0 or delay > 30) return error.InvalidSendDelay;
        if (!eq(command, "mail.send") and !eq(command, "draft.send")) return error.SendDelayRequiresSend;
        _ = try j.required(request, "account");
        _ = try j.required(request, "operationId");
        if (eq(command, "draft.send")) _ = try j.required(request, "draftId");
    }
    if (options.attachments.len != 0) {
        if (!eq(command, "draft.create") and !eq(command, "draft.update") and !eq(command, "draft.preview") and !eq(command, "mail.send")) return error.AttachmentsRequireDraftSource;
        if (options.attachments.len > 16) return error.TooManyAttachments;
        var total: u64 = 0;
        for (options.attachments) |path| {
            const file = try files.openRegular(io, a, .cwd(), path);
            defer file.close(io);
            const stat = try file.stat(io);
            total = std.math.add(u64, total, stat.size) catch return error.AttachmentsTooLarge;
            if (total > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
        }
        var draft = try j.copyObject(a, j.get(request, "draft") orelse j.object(a));
        if (j.get(draft, "attachments") != null) return error.ConflictingDraftOptions;
        var attachments: j.Value = .{ .array = .init(a) };
        var embedded: usize = 0;
        for (options.attachments) |path| {
            if (total <= t.Limits.body_bytes) {
                const raw = try files.readBounded(io, a, .cwd(), path, t.Limits.body_bytes - embedded);
                embedded += raw.len;
                const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
                _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
                try attachments.array.append(try j.value(a, t.Attachment{ .id = "", .filename = std.fs.path.basename(path), .size = raw.len, .data = encoded }));
            } else {
                const imported = try issue(a, client, try j.value(a, .{ .cmd = "attachment.import", .account = try j.required(request, "account"), .path = path }));
                if (!try succeeded(imported)) return imported.raw;
                try attachments.array.append(imported.data);
            }
        }
        try draft.object.put(a, "attachments", attachments);
        try request.object.put(a, "draft", draft);
    }
    const label_state = eq(command, "mail.label-state") or (eq(command, "labels.list") and (j.get(request, "messageIds") != null or j.get(request, "messageId") != null or j.get(request, "scope") != null));
    const scoped = j.get(request, "scope") != null and !eq(command, "mail.triage-scope");
    if (scoped) {
        if (!label_state and !eq(command, "mail.batch") and action(command) == null) return error.ScopeRequiresTriageCommand;
        const scope = try @import("triage.zig").scope(request);
        const ids = try oneId(a, request);
        if (ids != .array or ids.array.items.len != 1) return error.ScopeRequiresSingleMessage;
        const resolved = try issue(a, client, try j.value(a, .{ .cmd = "mail.triage-scope", .account = try j.required(request, "account"), .messageId = try j.string(ids.array.items[0]), .scope = scope }));
        if (!try succeeded(resolved)) return resolved.raw;
        const pinned = j.get(resolved.data, "messageIds") orelse return error.IncompleteTriageScope;
        if (!try j.boolean(resolved.data, "complete", false) or pinned != .array or pinned.array.items.len == 0 or pinned.array.items.len > 100 or try j.integer(resolved.data, "count", -1) != @as(i64, @intCast(pinned.array.items.len))) return error.IncompleteTriageScope;
        try request.object.put(a, "messageIds", pinned);
    }
    if (label_state) {
        try request.object.put(a, "messageIds", try oneId(a, request));
        command = "mail.label-state";
        try request.object.put(a, "cmd", .{ .string = command });
    } else if (action(command)) |verb| {
        if (scoped or j.get(request, "messageIds") != null or eq(verb, "spam") or eq(verb, "unspam")) {
            try request.object.put(a, "messageIds", try oneId(a, request));
            try request.object.put(a, "action", .{ .string = verb });
            command = "mail.batch";
            try request.object.put(a, "cmd", .{ .string = command });
        }
    }
    if (options.send_delay) |delay| {
        const account = try j.required(request, "account");
        const operation = try j.required(request, "operationId");
        const draft_id = if (eq(command, "draft.send")) try j.required(request, "draftId") else created: {
            const created = try issue(a, client, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = j.get(request, "draft") orelse return error.MissingField }));
            if (!try succeeded(created)) return created.raw;
            break :created try j.required(created.data, "id");
        };
        const staged = try issue(a, client, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = draft_id, .operationId = operation, .delaySeconds = delay }));
        if (!try succeeded(staged)) return staged.raw;
        const process = try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = try j.required(staged.data, "queueId"), .wait = true });
        return (try issue(a, client, process)).raw;
    }
    return (try issue(a, client, request)).raw;
}

test "UX backend: CLI conversation scope pins complete IDs and refuses incomplete results before mutation" {
    const Oracle = struct {
        complete: bool,
        calls: usize = 0,
        fn call(ctx: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const request = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
            try std.testing.expectEqualStrings("self@example.test", j.text(request, "account"));
            self.calls += 1;
            if (self.calls == 1) {
                try std.testing.expectEqualStrings("mail.triage-scope", j.text(request, "cmd"));
                try std.testing.expectEqualStrings("anchor", j.text(request, "messageId"));
                return std.json.Stringify.valueAlloc(a, .{ .ok = true, .data = .{ .complete = self.complete, .count = 2, .messageIds = .{ "anchor", "sibling" } } }, .{});
            }
            try std.testing.expectEqualStrings("mail.batch", j.text(request, "cmd"));
            try std.testing.expectEqualStrings("archive", j.text(request, "action"));
            const ids = j.get(request, "messageIds").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), ids.len);
            try std.testing.expectEqualStrings("sibling", try j.string(ids[1]));
            return a.dupe(u8, "{\"ok\":true,\"data\":{\"appliedCount\":2}}");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try j.value(a, .{ .cmd = "mail.archive", .account = "self@example.test", .messageId = "anchor", .scope = "conversation" });
    var incomplete: Oracle = .{ .complete = false };
    try std.testing.expectError(error.IncompleteTriageScope, execute(std.testing.io, a, .{ .ctx = &incomplete, .callFn = Oracle.call }, request, .{}));
    try std.testing.expectEqual(@as(usize, 1), incomplete.calls);
    var complete: Oracle = .{ .complete = true };
    _ = try execute(std.testing.io, a, .{ .ctx = &complete, .callFn = Oracle.call }, request, .{});
    try std.testing.expectEqual(@as(usize, 2), complete.calls);
}
