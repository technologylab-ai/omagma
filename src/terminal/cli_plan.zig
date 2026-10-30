//! One-shot convenience commands compose the shared executor's account-scoped
//! requests. Every mutation still reaches the same journal and pinned targets.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const files = @import("files.zig");
pub const Options = struct {
    attachments: []const []const u8 = &.{},
    /// Parallel to attachments when supplied. Null keeps legacy Attach.
    deliveries: []const ?t.AttachmentDelivery = &.{},
    /// Parallel: chosen by --attach-file (always attached).
    forced: []const bool = &.{},
    /// CLI routing repeated in authorization hints (never in requests).
    backend_socket: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    grant_file: ?[]const u8 = null,
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
const delivery_view = @import("delivery_view.zig");
const FileReport = struct { path: []const u8, filename: []const u8, size: u64, delivery: []const u8 = "attach", source: []const u8 };
/// Too large, all Attach (DESIGN §2.3 with AMENDMENT command names).
fn oversizedReply(a: std.mem.Allocator, request: j.Value, options: Options, sizes: []const u64, total: u64) ![]const u8 {
    const limit = t.Limits.attachment_bytes;
    var forced_total: u64 = 0;
    var largest: ?usize = null;
    var largest_forced: ?usize = null;
    var reports: std.ArrayList(FileReport) = .empty;
    for (options.attachments, sizes, 0..) |path, size, index| {
        const forced = index < options.forced.len and options.forced[index];
        if (forced) {
            forced_total += size;
            if (largest_forced == null or size > sizes[largest_forced.?]) largest_forced = index;
        } else if (largest == null or size > sizes[largest.?]) largest = index;
        try reports.append(a, .{ .path = path, .filename = std.fs.path.basename(path), .size = size, .source = if (forced) "attach-file" else "file" });
    }
    var hints: std.ArrayList([]const u8) = .empty;
    const message = if (forced_total > limit) forced_text: {
        // Hints are copyable flags: paths are shell-quoted; files[].path stays raw.
        const path = try shellWord(a, options.attachments[largest_forced.?]);
        try hints.append(a, try std.fmt.allocPrint(a, "change --attach-file {s} to --upload-file {s}", .{ path, path }));
        break :forced_text try std.fmt.allocPrint(a, "files forced with --attach-file total {s}; the limit is {s} per message.", .{ try delivery_view.size(a, forced_total), try delivery_view.limit(a, limit) });
    } else total_text: {
        if (largest) |index| {
            try hints.append(a, "--attachment-mode auto (with --file): attach what fits, share the rest from Drive");
            try hints.append(a, try std.fmt.allocPrint(a, "--upload-file {s}: share this file from Drive", .{try shellWord(a, options.attachments[index])}));
        }
        if (largest_forced != null) try hints.append(a, "files given with --attach-file always stay attached");
        break :total_text try std.fmt.allocPrint(a, "attachments are too large: {s} would be attached; the limit is {s} per message.", .{ try delivery_view.size(a, total), try delivery_view.limit(a, limit) });
    };
    try hints.append(a, "Drive files are shared viewer-only with To and Cc recipients.");
    return std.json.Stringify.valueAlloc(a, .{ .version = 1, .id = null, .ok = false, .account = j.text(request, "account"), .@"error" = .{ .code = "AttachmentsTooLarge", .message = message, .limitBytes = limit, .attachedBytes = total, .files = reports.items, .hints = hints.items } }, .{});
}
/// A send stopped for a missing Drive grant before any Gmail attempt names
/// the authorization: the account's current capabilities plus drive-upload.
/// Only definitive pre-Gmail refusals for a missing or expired grant are
/// enriched: a DriveNotConnected or DriveAccessExpired error, a named-draft
/// preparationStopped receipt, or a paused queued preparation. Gmail
/// receipts (applied, rejected, unknown) are untouched, and receipt
/// identity/outcome fields are copied unchanged.
fn withDriveHint(a: std.mem.Allocator, client: t.Client, options: Options, account: []const u8, raw: []const u8) ![]const u8 {
    const frame = std.json.parseFromSliceLeaky(j.Value, a, raw, .{}) catch return raw;
    const owner = j.text(frame, "account");
    if (account.len == 0 or (owner.len != 0 and !eq(owner, account))) return raw;
    const ok = j.boolean(frame, "ok", false) catch return raw;
    const key: []const u8 = if (ok) "data" else "error";
    const target = j.get(frame, key) orelse return raw;
    if (target != .object) return raw;
    if (ok) {
        if (!stoppedForDrive(target)) return raw;
    } else if (!grantCode(j.text(target, "code"))) return raw;
    var enriched = try j.copyObject(a, target);
    if (!ok) try enriched.object.put(a, "message", .{ .string = if (eq(j.text(target, "code"), "DriveAccessExpired")) try std.fmt.allocPrint(a, "Drive access expired for {s}.", .{account}) else try std.fmt.allocPrint(a, "Drive isn't connected for {s}.", .{account}) });
    var hints: j.Value = .{ .array = .init(a) };
    try hints.array.append(.{ .string = try authorizationHint(a, client, options, account) });
    try enriched.object.put(a, "hints", hints);
    var result = try j.copyObject(a, frame);
    try result.object.put(a, key, enriched);
    return std.json.Stringify.valueAlloc(a, result, .{});
}
fn stoppedForDrive(data: j.Value) bool {
    const status = j.text(data, "status");
    if (eq(j.text(data, "outcome"), "preparationStopped")) return (status.len == 0 or eq(status, "stopped")) and grantCode(j.text(data, "errorCode"));
    if (!eq(j.text(data, "state"), "queued") or !(j.boolean(data, "resumeRequired", false) catch false)) return false;
    const preparation = j.get(data, "preparation") orelse return false;
    if (preparation != .object) return false;
    const stopped = eq(j.text(preparation, "outcome"), "preparationStopped") or eq(j.text(preparation, "status"), "stopped");
    const code = if (j.text(preparation, "errorCode").len != 0) j.text(preparation, "errorCode") else j.text(data, "errorCode");
    return stopped and grantCode(code);
}
/// A missing or expired Drive grant: the only refusals a new authorization
/// with every current capability can fix.
fn grantCode(code: []const u8) bool {
    return eq(code, "DriveNotConnected") or eq(code, "DriveAccessExpired");
}

test "UX backend: CLI expired Drive access names the same full authorization, in stopped contexts only" {
    const Oracle = struct {
        calls: usize = 0,
        fn call(ctx: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const request = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
            try std.testing.expectEqualStrings("accounts.list", j.text(request, "cmd"));
            self.calls += 1;
            return a.dupe(u8, "{\"ok\":true,\"data\":{\"accounts\":[{\"address\":\"self@example.test\",\"capabilities\":[\"mail-read\",\"mail-send\",\"drive-upload\"]}]}}");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: Oracle = .{};
    const routing: Options = .{ .config_file = "/private/omagma config.json" };
    const command = "run omagma terminal-auth authorize --account self@example.test --config '/private/omagma config.json' --capabilities mail-read,mail-send,drive-upload (access only to files Omagma uploads), or attach instead.";
    // Direct send: the top error says access expired; routing and the full
    // capability set are unchanged.
    const direct = j.get(try std.json.parseFromSliceLeaky(j.Value, a, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, routing, "self@example.test", "{\"version\":1,\"ok\":false,\"account\":\"self@example.test\",\"error\":{\"code\":\"DriveAccessExpired\",\"message\":\"\"}}"), .{}), "error").?;
    try std.testing.expectEqualStrings("Drive access expired for self@example.test.", j.text(direct, "message"));
    try std.testing.expectEqualStrings(command, try j.string(j.get(direct, "hints").?.array.items[0]));
    // Named draft and paused queue stopped before Gmail: same command, identity kept.
    const named = "{\"version\":1,\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"outcome\":\"preparationStopped\",\"status\":\"stopped\",\"operationId\":\"op-9\",\"errorCode\":\"DriveAccessExpired\",\"canRetryPreparation\":true,\"driveFiles\":[]}}";
    const named_data = j.get(try std.json.parseFromSliceLeaky(j.Value, a, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, routing, "self@example.test", named), .{}), "data").?;
    try std.testing.expectEqualStrings("op-9", j.text(named_data, "operationId"));
    try std.testing.expectEqualStrings(command, try j.string(j.get(named_data, "hints").?.array.items[0]));
    const queued = "{\"version\":1,\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"queueId\":\"q-2\",\"state\":\"queued\",\"resumeRequired\":true,\"preparation\":{\"outcome\":\"preparationStopped\",\"status\":\"stopped\",\"operationId\":\"op-10\",\"errorCode\":\"DriveAccessExpired\",\"driveFiles\":[]}}}";
    const queued_data = j.get(try std.json.parseFromSliceLeaky(j.Value, a, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, routing, "self@example.test", queued), .{}), "data").?;
    try std.testing.expectEqualStrings("q-2", j.text(queued_data, "queueId"));
    try std.testing.expectEqualStrings(command, try j.string(j.get(queued_data, "hints").?.array.items[0]));
    // Gmail-unknown and retired receipts are never enriched or looked up.
    oracle.calls = 0;
    for ([_][]const u8{
        "{\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"outcome\":\"unknown\",\"errorCode\":\"DriveAccessExpired\"}}",
        "{\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"state\":\"unknown\",\"resumeRequired\":true,\"errorCode\":\"DriveAccessExpired\",\"preparation\":{\"status\":\"stopped\"}}}",
        "{\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"outcome\":\"rejected\",\"kind\":\"drivePreparationRetired\",\"errorCode\":\"DriveSubmissionBudgetExpired\",\"messageId\":\"\"}}",
    }) |receipt| try std.testing.expectEqualStrings(receipt, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, routing, "self@example.test", receipt));
    try std.testing.expectEqual(@as(usize, 0), oracle.calls);
}
/// The exact command only after reading exactly one matching account with a
/// valid capability set; otherwise how to check it, never a guessed list.
fn authorizationHint(a: std.mem.Allocator, client: t.Client, options: Options, account: []const u8) ![]const u8 {
    const backend_arg = if (options.backend_socket) |path| try std.fmt.allocPrint(a, " --backend {s}", .{try shellWord(a, path)}) else "";
    const config_arg = if (options.config_file) |path| try std.fmt.allocPrint(a, " --config {s}", .{try shellWord(a, path)}) else "";
    const grant_arg = if (options.grant_file) |path| try std.fmt.allocPrint(a, " --grant-file {s}", .{try shellWord(a, path)}) else "";
    const routing = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ backend_arg, config_arg, grant_arg });
    const quoted = try shellWord(a, account);
    if (try currentCapabilities(a, client, account)) |list| return std.fmt.allocPrint(a, "run omagma terminal-auth authorize --account {s}{s} --capabilities {s} (access only to files Omagma uploads), or attach instead.", .{ quoted, routing, list });
    return delivery_view.unknownCapabilitiesHint(a, quoted, routing);
}
fn currentCapabilities(a: std.mem.Allocator, client: t.Client, account: []const u8) !?[]const u8 {
    const listed = issue(a, client, try j.value(a, .{ .cmd = "accounts.list" })) catch return null;
    if (!(succeeded(listed) catch false)) return null;
    const accounts = j.get(listed.data, "accounts") orelse return null;
    if (accounts != .array) return null;
    var match: ?j.Value = null;
    for (accounts.array.items) |entry| if (eq(j.text(entry, "address"), account)) {
        if (match != null) return null;
        match = entry;
    };
    const capabilities = j.get(match orelse return null, "capabilities") orelse return null;
    if (capabilities != .array) return null;
    var existing: std.ArrayList([]const u8) = .empty;
    for (capabilities.array.items) |capability| {
        if (capability != .string) return null;
        try existing.append(a, capability.string);
    }
    return delivery_view.capabilityList(a, existing.items);
}
/// Plain words stay readable; anything else is single-quoted for a POSIX shell.
fn shellWord(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var plain = raw.len != 0 and raw[0] != '-';
    for (raw) |byte| plain = plain and (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "@._+,:=/-", byte) != null);
    if (plain) return raw;
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(a, '\'');
    for (raw) |byte| if (byte == '\'') try quoted.appendSlice(a, "'\\''") else try quoted.append(a, byte);
    try quoted.append(a, '\'');
    return quoted.items;
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
        if (options.attachments.len > @import("types.zig").Limits.attachments) return error.TooManyAttachments;
        if (options.deliveries.len != 0 and options.deliveries.len != options.attachments.len) return error.InvalidRequest;
        // Drive/Auto files and saved drafts are planned by the backend; only
        // an all-Attach direct send keeps the early refusal before any import.
        var shared = false;
        for (options.deliveries) |delivery| shared = shared or (delivery != null and delivery.? != .attach);
        const refuse_oversized = !shared and eq(command, "mail.send");
        var total: u64 = 0;
        const sizes = try a.alloc(u64, options.attachments.len);
        for (options.attachments, sizes) |path, *size| {
            const file = try files.openRegular(io, a, .cwd(), path);
            defer file.close(io);
            const stat = try file.stat(io);
            size.* = stat.size;
            total = std.math.add(u64, total, stat.size) catch return error.AttachmentsTooLarge;
        }
        // Refuse before any import or provider write, naming the flags that
        // would change the plan. The reply keeps the JSON error contract.
        if (refuse_oversized and total > t.Limits.attachment_bytes) return oversizedReply(a, request, options, sizes, total);
        var draft = try j.copyObject(a, j.get(request, "draft") orelse j.object(a));
        if (j.get(draft, "attachments") != null) return error.ConflictingDraftOptions;
        var attachments: j.Value = .{ .array = .init(a) };
        var embedded: usize = 0;
        for (options.attachments, 0..) |path, index| {
            const delivery: ?t.AttachmentDelivery = if (index < options.deliveries.len) options.deliveries[index] else null;
            const attached = delivery == null or delivery.? == .attach;
            if (attached and total <= t.Limits.body_bytes) {
                const raw = try files.readBounded(io, a, .cwd(), path, t.Limits.body_bytes - embedded);
                embedded += raw.len;
                const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
                _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
                try attachments.array.append(try j.value(a, t.Attachment{ .id = "", .filename = std.fs.path.basename(path), .size = raw.len, .data = encoded, .delivery = delivery }));
            } else {
                const account = try j.required(request, "account");
                // Import pins local bytes only. Drive upload waits for the
                // reviewed send; the descriptor must echo the chosen delivery.
                const imported = if (delivery) |chosen| try issue(a, client, try j.value(a, .{ .cmd = "attachment.import", .account = account, .path = path, .delivery = @tagName(chosen) })) else try issue(a, client, try j.value(a, .{ .cmd = "attachment.import", .account = account, .path = path }));
                if (!try succeeded(imported)) return imported.raw;
                if (delivery) |chosen| if (!eq(j.text(imported.data, "delivery"), @tagName(chosen))) return error.InvalidAttachmentDelivery;
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
        if (!try succeeded(staged)) return withDriveHint(a, client, options, account, staged.raw);
        const process = try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = try j.required(staged.data, "queueId"), .wait = true });
        return withDriveHint(a, client, options, account, (try issue(a, client, process)).raw);
    }
    const reply = (try issue(a, client, request)).raw;
    // Every command that can prepare Drive files before Gmail, including an
    // explicit queue retry, may return a stopped missing-grant receipt.
    for ([_][]const u8{ "mail.send", "draft.send", "draft.queue", "queue.process", "queue.send-now" }) |sending| {
        if (eq(command, sending)) return withDriveHint(a, client, options, j.text(request, "account"), reply);
    }
    return reply;
}

test "UX backend: CLI Drive files import with their delivery while small Attach files stay inline" {
    const Oracle = struct {
        echo: bool,
        imports: usize = 0,
        fn call(ctx: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const request = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
            const command = j.text(request, "cmd");
            if (eq(command, "attachment.import")) {
                self.imports += 1;
                try std.testing.expectEqualStrings("drive", j.text(request, "delivery"));
                return std.json.Stringify.valueAlloc(a, .{ .ok = true, .data = .{ .id = "", .filename = "raw.zip", .size = 4, .blobId = "blob-raw", .delivery = if (self.echo) "drive" else "attach" } }, .{});
            }
            try std.testing.expectEqualStrings("draft.create", command);
            const attachments = j.get(j.get(request, "draft").?, "attachments").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), attachments.len);
            try std.testing.expect(j.text(attachments[0], "data").len != 0);
            try std.testing.expectEqualStrings("blob-raw", j.text(attachments[1], "blobId"));
            return a.dupe(u8, "{\"ok\":true,\"data\":{\"id\":\"draft-1\"}}");
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "note", .flags = .{ .permissions = .fromMode(0o600) } });
    try tmp.dir.writeFile(io, .{ .sub_path = "raw.zip", .data = "PK\x03\x04", .flags = .{ .permissions = .fromMode(0o600) } });
    const paths = [_][]const u8{ try tmp.dir.realPathFileAlloc(io, "notes.txt", a), try tmp.dir.realPathFileAlloc(io, "raw.zip", a) };
    const deliveries = [_]?t.AttachmentDelivery{ null, .drive };
    const request = try j.value(a, .{ .cmd = "draft.create", .account = "self@example.test", .draft = .{ .to = "peer@example.test", .bodyText = "Files" } });
    var echoed: Oracle = .{ .echo = true };
    _ = try execute(io, a, .{ .ctx = &echoed, .callFn = Oracle.call }, request, .{ .attachments = &paths, .deliveries = &deliveries });
    try std.testing.expectEqual(@as(usize, 1), echoed.imports);
    // A descriptor that silently changed delivery is never saved into a draft.
    var changed: Oracle = .{ .echo = false };
    try std.testing.expectError(error.InvalidAttachmentDelivery, execute(io, a, .{ .ctx = &changed, .callFn = Oracle.call }, request, .{ .attachments = &paths, .deliveries = &deliveries }));
    try std.testing.expectError(error.InvalidRequest, execute(io, a, .{ .ctx = &changed, .callFn = Oracle.call }, request, .{ .attachments = &paths, .deliveries = deliveries[0..1] }));
}

test "UX backend: CLI oversized all-Attach send names the flags that change the plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try j.value(a, .{ .cmd = "mail.send", .account = "self@example.test" });
    const mib: u64 = 1024 * 1024;
    const paths = [_][]const u8{ "report.pdf", "photo.jpg" };
    const deliveries = [_]?t.AttachmentDelivery{ null, null };
    const sizes = [_]u64{ 31 * mib, 8 * mib };
    const by_mode = try std.json.parseFromSliceLeaky(j.Value, a, try oversizedReply(a, request, .{ .attachments = &paths, .deliveries = &deliveries, .forced = &.{ false, false } }, &sizes, 39 * mib), .{});
    try std.testing.expect(!try j.boolean(by_mode, "ok", true));
    const failure = j.get(by_mode, "error").?;
    try std.testing.expectEqualStrings("AttachmentsTooLarge", j.text(failure, "code"));
    try std.testing.expectEqualStrings("attachments are too large: 39.0 MiB would be attached; the limit is 25 MiB per message.", j.text(failure, "message"));
    const hints = j.get(failure, "hints").?.array.items;
    try std.testing.expectEqualStrings("--upload-file report.pdf: share this file from Drive", try j.string(hints[1]));
    try std.testing.expectEqual(@as(usize, 2), j.get(failure, "files").?.array.items.len);
    const forced = try std.json.parseFromSliceLeaky(j.Value, a, try oversizedReply(a, request, .{ .attachments = &paths, .deliveries = &deliveries, .forced = &.{ true, false } }, &sizes, 39 * mib), .{});
    const forced_failure = j.get(forced, "error").?;
    try std.testing.expectEqualStrings("files forced with --attach-file total 31.0 MiB; the limit is 25 MiB per message.", j.text(forced_failure, "message"));
    try std.testing.expectEqualStrings("change --attach-file report.pdf to --upload-file report.pdf", try j.string(j.get(forced_failure, "hints").?.array.items[0]));
    // Spaces, quotes and shell metacharacters stay one safe, copyable word;
    // the machine-readable files[].path keeps the exact path.
    const odd = [_][]const u8{ "Q3 report (final) $1.pdf", "dir/it's;rm.zip" };
    const odd_reply = try std.json.parseFromSliceLeaky(j.Value, a, try oversizedReply(a, request, .{ .attachments = &odd, .deliveries = &deliveries, .forced = &.{ false, false } }, &sizes, 39 * mib), .{});
    const odd_failure = j.get(odd_reply, "error").?;
    try std.testing.expectEqualStrings("--upload-file 'Q3 report (final) $1.pdf': share this file from Drive", try j.string(j.get(odd_failure, "hints").?.array.items[1]));
    try std.testing.expectEqualStrings("Q3 report (final) $1.pdf", j.text(j.get(odd_failure, "files").?.array.items[0], "path"));
    const odd_forced = try std.json.parseFromSliceLeaky(j.Value, a, try oversizedReply(a, request, .{ .attachments = &.{ "dir/it's;rm.zip", "photo.jpg" }, .deliveries = &deliveries, .forced = &.{ true, false } }, &sizes, 39 * mib), .{});
    try std.testing.expectEqualStrings("change --attach-file 'dir/it'\\''s;rm.zip' to --upload-file 'dir/it'\\''s;rm.zip'", try j.string(j.get(j.get(odd_forced, "error").?, "hints").?.array.items[0]));
}

test "UX backend: CLI Drive-not-connected reply names the full safe authorization" {
    const Oracle = struct {
        fn call(_: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
            const request = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
            try std.testing.expectEqualStrings("accounts.list", j.text(request, "cmd"));
            return a.dupe(u8, "{\"ok\":true,\"data\":{\"accounts\":[{\"address\":\"self@example.test\",\"capabilities\":[\"mail-read\",\"mail-send\"]}]}}");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context: u8 = 0;
    const reply = try withDriveHint(a, .{ .ctx = &context, .callFn = Oracle.call }, .{}, "self@example.test", "{\"version\":1,\"id\":null,\"ok\":false,\"account\":\"self@example.test\",\"error\":{\"code\":\"DriveNotConnected\",\"message\":\"\"}}");
    const frame = try std.json.parseFromSliceLeaky(j.Value, a, reply, .{});
    const failure = j.get(frame, "error").?;
    try std.testing.expectEqualStrings("Drive isn't connected for self@example.test.", j.text(failure, "message"));
    try std.testing.expectEqualStrings("run omagma terminal-auth authorize --account self@example.test --capabilities mail-read,mail-send,drive-upload (access only to files Omagma uploads), or attach instead.", try j.string(j.get(failure, "hints").?.array.items[0]));
    const unrelated = "{\"ok\":false,\"error\":{\"code\":\"InvalidRecipients\"}}";
    try std.testing.expectEqualStrings(unrelated, try withDriveHint(a, .{ .ctx = &context, .callFn = Oracle.call }, .{}, "self@example.test", unrelated));
}

test "UX backend: CLI missing-grant hint covers pre-Gmail receipts only and never guesses capabilities" {
    const Oracle = struct {
        accounts: []const u8,
        calls: usize = 0,
        fn call(ctx: *anyopaque, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const request = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
            try std.testing.expectEqualStrings("accounts.list", j.text(request, "cmd"));
            self.calls += 1;
            if (self.accounts.len == 0) return error.ConnectionResetByPeer;
            return a.dupe(u8, self.accounts);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = "{\"ok\":true,\"data\":{\"accounts\":[{\"address\":\"self@example.test\",\"capabilities\":[\"mail-read\",\"mail-send\",\"contacts-read\"]}]}}";
    const routing: Options = .{ .backend_socket = "/run/user/1000/omagma vault.sock", .config_file = "/private/omagma config.json", .grant_file = "/private/grants.json" };
    // Named draft: preparation stopped before Gmail; identity fields are kept.
    const named = "{\"version\":1,\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"outcome\":\"preparationStopped\",\"status\":\"stopped\",\"operationId\":\"op-7\",\"draftId\":\"draft-7\",\"errorCode\":\"DriveNotConnected\",\"canRetryPreparation\":true,\"driveFiles\":[]}}";
    var oracle: Oracle = .{ .accounts = listed };
    const named_frame = try std.json.parseFromSliceLeaky(j.Value, a, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, routing, "self@example.test", named), .{});
    const named_data = j.get(named_frame, "data").?;
    try std.testing.expectEqualStrings("preparationStopped", j.text(named_data, "outcome"));
    try std.testing.expectEqualStrings("op-7", j.text(named_data, "operationId"));
    try std.testing.expectEqualStrings("draft-7", j.text(named_data, "draftId"));
    try std.testing.expectEqualStrings("run omagma terminal-auth authorize --account self@example.test --backend '/run/user/1000/omagma vault.sock' --config '/private/omagma config.json' --grant-file /private/grants.json --capabilities mail-read,mail-send,contacts-read,drive-upload (access only to files Omagma uploads), or attach instead.", try j.string(j.get(named_data, "hints").?.array.items[0]));
    // Queued: paused with its stopped preparation receipt.
    const queued = "{\"version\":1,\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"queueId\":\"q-1\",\"state\":\"queued\",\"resumeRequired\":true,\"errorCode\":\"DriveNotConnected\",\"preparation\":{\"outcome\":\"preparationStopped\",\"status\":\"stopped\",\"operationId\":\"op-8\",\"driveFiles\":[]}}}";
    const queued_data = j.get(try std.json.parseFromSliceLeaky(j.Value, a, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, .{}, "self@example.test", queued), .{}), "data").?;
    try std.testing.expectEqualStrings("q-1", j.text(queued_data, "queueId"));
    try std.testing.expect(std.mem.indexOf(u8, try j.string(j.get(queued_data, "hints").?.array.items[0]), "--capabilities mail-read,mail-send,contacts-read,drive-upload") != null);
    // Gmail receipts are never enriched, whatever their error code.
    oracle.calls = 0;
    for ([_][]const u8{
        "{\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"outcome\":\"applied\",\"errorCode\":\"DriveNotConnected\"}}",
        "{\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"outcome\":\"unknown\",\"errorCode\":\"DriveNotConnected\"}}",
        "{\"ok\":true,\"account\":\"self@example.test\",\"data\":{\"state\":\"unknown\",\"resumeRequired\":true,\"errorCode\":\"DriveNotConnected\",\"preparation\":{\"status\":\"stopped\"}}}",
    }) |receipt| try std.testing.expectEqualStrings(receipt, try withDriveHint(a, .{ .ctx = &oracle, .callFn = Oracle.call }, .{}, "self@example.test", receipt));
    try std.testing.expectEqual(@as(usize, 0), oracle.calls);
    // A failed lookup or no matching account never becomes a narrower command.
    for ([_][]const u8{ "", "{\"ok\":true,\"data\":{\"accounts\":[{\"address\":\"other@example.test\",\"capabilities\":[\"mail-read\"]}]}}", "{\"ok\":true,\"data\":{\"accounts\":[{\"address\":\"self@example.test\",\"capabilities\":[]}]}}", "{\"ok\":false,\"error\":{\"code\":\"OutOfMemory\"}}" }) |accounts| {
        var failing: Oracle = .{ .accounts = accounts };
        const hint = try j.string(j.get(j.get(try std.json.parseFromSliceLeaky(j.Value, a, try withDriveHint(a, .{ .ctx = &failing, .callFn = Oracle.call }, routing, "self@example.test", named), .{}), "data").?, "hints").?.array.items[0]);
        try std.testing.expect(std.mem.indexOf(u8, hint, "--capabilities") == null);
        // The check names the account and the same routing, shell-quoted.
        try std.testing.expect(std.mem.indexOf(u8, hint, "omagma terminal-auth status --account self@example.test --backend '/run/user/1000/omagma vault.sock' --config '/private/omagma config.json' --grant-file /private/grants.json,") != null);
    }
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
