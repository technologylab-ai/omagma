const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const recipients = @import("recipients.zig");
const invitation = @import("invitation.zig");
const storage = @import("store.zig");
const cache_query = @import("cache_query.zig");
const triage = @import("triage.zig");
const batch = @import("batch.zig");
const markdown_mail = @import("markdown_mail.zig");
const label_collection = @import("labels.zig");
const send_queue = @import("send_queue.zig");
const Config = @import("../config.zig").Config;
const Value = std.json.Value;
const system_labels = [_][]const u8{ "INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED", "IMPORTANT", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS" };
fn canonicalLabel(text: []const u8, definitions: []const storage.Label) []const u8 {
    for (system_labels) |system| if (std.ascii.eqlIgnoreCase(text, system)) return system;
    for (definitions) |definition| if (std.mem.eql(u8, text, definition.id) or std.mem.eql(u8, text, definition.name)) return definition.id;
    return text;
}
fn fixtureLabel(source: Value, text: []const u8) ![]const u8 {
    try recipients.validateHeader(text);
    if (text.len == 0) return "";
    for (system_labels) |system| if (std.ascii.eqlIgnoreCase(text, system)) return system;
    if (j.get(source, "labels")) |value| {
        for (try valueArray(value)) |item| if (std.mem.eql(u8, text, j.text(item, "id")) or std.mem.eql(u8, text, j.text(item, "name"))) return j.required(item, "id");
    } else if (std.mem.eql(u8, text, "Projects") or std.mem.eql(u8, text, "Label_demo")) return "Label_demo";
    return error.LabelNotFound;
}
fn fixtureLabelDefinitions(a: std.mem.Allocator, source: Value) !Value {
    if (j.get(source, "labels")) |value| return value;
    var list: std.ArrayList(storage.Label) = .empty;
    for (system_labels) |name| try list.append(a, .{ .id = name, .name = name, .type = "system" });
    try list.append(a, .{ .id = "Label_demo", .name = "Projects", .type = "user" });
    return j.value(a, list.items);
}
fn cachedLabel(store: *storage.Store, text: []const u8) []const u8 {
    const resolved = canonicalLabel(text, store.state.labels);
    if (!std.mem.eql(u8, resolved, text)) return resolved;
    for (store.state.views) |view| if (std.mem.eql(u8, text, view.label) and view.labelId.len != 0) return view.labelId;
    if (store.options.fixtures and !store.state.fixtureLabelsReady and std.mem.eql(u8, text, "Projects")) return "Label_demo";
    return resolved;
}

fn requestedPrefetch(options: t.Options, request: Value) !i64 {
    const page = try j.integer(request, "limit", 32);
    if (page < 1 or page > 100) return error.InvalidPageLimit;
    const fallback: i64 = if (options.body_prefetch_limit_set or options.body_prefetch_limit != 32) @intCast(options.body_prefetch_limit) else @min(page, 32);
    const limit = try j.integer(request, "prefetchLimit", fallback);
    if (limit < 0 or limit > 64) return error.InvalidPrefetchLimit;
    return limit;
}
fn operationPayload(a: std.mem.Allocator, draft: t.Draft, account: []const u8, calendar: ?[]const u8) ![]const u8 {
    var canonical = draft;
    canonical.id = "";
    if (canonical.from) |sender| if (sender.name.len == 0 and std.ascii.eqlIgnoreCase(sender.address, account)) {
        canonical.from = null;
    };
    // Preserve legacy outer calendar:null; omit only the newly optional draft
    // fields so an unchanged old uncertain operation keeps its fingerprint.
    const bytes = try std.json.Stringify.valueAlloc(a, canonical, .{ .emit_null_optional_fields = false });
    var value = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_if_needed });
    // Plain is the legacy wire/source interpretation. Keep historical uncertain
    // fingerprints identical when an older draft gains the default field.
    if (canonical.bodyFormat == .plain) _ = value.object.orderedRemove("bodyFormat");
    return std.json.Stringify.valueAlloc(a, .{ .draft = value, .calendar = if (calendar) |ics| try calendarIdentity(a, ics) else null }, .{});
}
const CacheWindow = struct { start: usize, end: usize, direction: []const u8 = "head", fallback: bool = false };
fn adjacentCacheWindow(store: *storage.Store, candidates: []const t.Message, request: Value, limit: usize, offset: usize) !CacheWindow {
    const before = j.text(request, "beforeMessageId");
    const after = j.text(request, "afterMessageId");
    if (before.len == 0 and after.len == 0) return .{ .start = offset, .end = @min(candidates.len, offset + limit), .direction = if (offset != 0) "cursor" else "head" };
    if ((before.len != 0 and after.len != 0) or j.text(request, "cursor").len != 0 or j.text(request, "anchorMessageId").len != 0) return error.ConflictingWindowSelectors;
    const id = if (before.len != 0) before else after;
    try @import("../bounded.zig").identifier(id);
    var rank: usize = 0;
    var exact = false;
    for (candidates, 0..) |candidate, index| if (std.mem.eql(u8, candidate.id, id)) {
        rank = index;
        exact = true;
        break;
    };
    if (!exact) {
        const stamp = if (store.find(id)) |entry| entry.message.receivedAt else fallback: {
            const field = j.get(request, "boundaryReceivedAt") orelse return error.CacheBoundaryGone;
            if (field != .integer or field.integer < 0) return error.InvalidWindowBoundary;
            break :fallback field.integer;
        };
        // The supplied visible timestamp is used only to rank this account's
        // current retained candidates, never to fetch or import another ID.
        for (candidates) |candidate| {
            if (candidate.receivedAt > stamp or (candidate.receivedAt == stamp and std.mem.lessThan(u8, candidate.id, id))) rank += 1 else break;
        }
    }
    if (before.len != 0) return .{ .start = rank -| limit, .end = rank, .direction = "before", .fallback = !exact };
    const start = rank + @intFromBool(exact);
    return .{ .start = start, .end = @min(candidates.len, start + limit), .direction = "after", .fallback = !exact };
}

pub const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: t.Options,
    config: Config,
    cache_root: []const u8,
    env: *const std.process.Environ.Map,
    meter: ?*@import("capped_allocator.zig").CappedAllocator = null,
    progress_sink: ?t.ProgressSink = null,
    pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, options: t.Options) !Session {
        var s: Session = .{ .io = io, .allocator = a, .options = options, .config = undefined, .cache_root = undefined, .env = env };
        const home = env.get("HOME") orelse return error.HomeRequired;
        try s.config.defaults(home);
        if (options.fixtures) for (s.config.accounts[0..s.config.count]) |*account| {
            account.enabled = true;
        };
        var parse_arena = std.heap.ArenaAllocator.init(a);
        defer parse_arena.deinit();
        const pa = parse_arena.allocator();
        const cfg = options.config_file orelse if (!options.fixtures) try std.fmt.allocPrint(pa, "{s}/omagma/config.json", .{env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(pa, "{s}/.config", .{home})}) else null;
        if (cfg) |path| {
            const buf = try pa.alloc(u8, 16 * 1024);
            try s.config.load(io, path, pa, buf);
        }
        s.cache_root = try a.dupe(u8, options.cache_dir orelse try std.fmt.allocPrint(pa, "{s}/omagma/terminal", .{env.get("XDG_CACHE_HOME") orelse try std.fmt.allocPrint(pa, "{s}/.cache", .{home})}));
        if (options.metadata_limit == 0 or options.metadata_limit > t.Limits.metadata_hard or options.disk_limit < 64 * 1024 or options.disk_limit > t.Limits.disk_hard) return error.InvalidCacheLimit;
        if (options.body_prefetch_limit > 64) return error.InvalidPrefetchLimit;
        if (!std.mem.eql(u8, options.fixture_scenario, "normal") and !options.fixtures) return error.FixtureOptionRequiresFixtures;
        if (options.fixture_root != null and !options.fixtures) return error.FixtureOptionRequiresFixtures;
        if (options.fixtures and std.mem.indexOfScalar(u8, options.fixture_scenario, '/') != null) return error.InvalidFixtureScenario;
        return s;
    }
    pub fn deinit(s: *Session) void {
        s.allocator.free(s.cache_root);
    }
    pub fn client(s: *Session) t.Client {
        return .{ .ctx = s, .callFn = call, .cachedFn = callCached, .cacheStampFn = callCacheStamp, .callProgressFn = callProgress };
    }
    fn call(ctx: *anyopaque, out_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const s: *Session = @ptrCast(@alignCast(ctx));
        return s.execute(out_allocator, raw);
    }
    fn callCacheStamp(ctx: *anyopaque, account: []const u8) !?t.CacheStamp {
        const s: *Session = @ptrCast(@alignCast(ctx));
        try recipients.validateAddress(account);
        const index = s.config.index(account) orelse return error.UnknownAccount;
        if (!s.config.accounts[index].enabled) return error.AccountDisabled;
        return storage.cacheStamp(s.io, s.cache_root, account, s.options);
    }
    fn callCached(ctx: *anyopaque, out_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const s: *Session = @ptrCast(@alignCast(ctx));
        return s.executeMode(out_allocator, raw, true);
    }
    fn callProgress(ctx: *anyopaque, out_allocator: std.mem.Allocator, raw: []const u8, sink: t.ProgressSink) ![]const u8 {
        const s: *Session = @ptrCast(@alignCast(ctx));
        return s.executeWithProgress(out_allocator, raw, sink);
    }
    pub fn executeWithProgress(s: *Session, out_allocator: std.mem.Allocator, raw: []const u8, sink: t.ProgressSink) ![]const u8 {
        // The Session includes its large inline Config. Copy directly to a
        // tracked heap wrapper, never through a temporary stack Session.
        const worker = try s.allocator.create(Session);
        defer s.allocator.destroy(worker);
        worker.* = s.*;
        worker.progress_sink = sink;
        // cache_root/env are borrowed; deinit would free the original root.
        return worker.executeMode(out_allocator, raw, false);
    }
    fn reportProgress(s: *const Session, phase: t.FetchPhase, completed: usize, total: usize) void {
        if (s.progress_sink) |sink| sink.report(.{ .phase = phase, .completed = completed, .total = total });
    }
    fn reportRow(s: *const Session, update: t.FetchRow) void {
        if (s.progress_sink) |sink| sink.row(update);
    }
    pub fn execute(s: *Session, out_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        return s.executeMode(out_allocator, raw, false);
    }
    fn executeMode(s: *Session, out_allocator: std.mem.Allocator, raw: []const u8, cached_only: bool) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(s.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const request = if (raw.len > t.Limits.request_bytes or !boundedJson(raw)) null else std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always, .max_value_len = t.Limits.request_bytes }) catch null;
        if (request == null or request.? != .object) return failure(out_allocator, .null, "", "InvalidRequest", "Expected a bounded JSON object");
        var req = request.?;
        if (cached_only) {
            const command = j.text(req, "cmd");
            if (!std.mem.eql(u8, command, "labels.list") and !std.mem.eql(u8, command, "accounts.identities") and !std.mem.eql(u8, command, "mail.list") and !std.mem.eql(u8, command, "mail.recipients") and !std.mem.eql(u8, command, "mail.search") and !std.mem.eql(u8, command, "mail.read") and !std.mem.eql(u8, command, "mail.thread") and !std.mem.eql(u8, command, "cache.stats") and !std.mem.eql(u8, command, "cache.activity") and !std.mem.eql(u8, command, "cache.refresh-status") and !std.mem.eql(u8, command, "contacts.list") and !std.mem.eql(u8, command, "contacts.search")) return error.CacheUnsupported;
            try req.object.put(a, "cacheOnly", .{ .bool = true });
        }
        const account = j.text(req, "account");
        const id = j.get(req, "id") orelse .null;
        for ([_][]const u8{ "cmd", "account", "cursor", "query", "label", "messageId", "threadId", "draftId", "operationId", "status", "expectedEtag", "grantFile", "clientFile", "preparedCalendar", "anchorMessageId", "beforeMessageId", "afterMessageId", "action", "undoToken", "url", "path", "labelId", "name", "confirmName", "queueId", "scope", "attachmentId", "blobId", "mimeType" }) |key| if (j.get(req, key)) |field| {
            if (field != .string) return failure(out_allocator, id, account, "InvalidRequest", "Expected string command fields");
        };
        if (j.get(req, "boundaryReceivedAt")) |field| if (field != .integer or field.integer < 0) return failure(out_allocator, id, account, "InvalidWindowBoundary", "Expected a nonnegative integer window timestamp");
        if (!s.options.fixtures and j.get(req, "grantFile") == null) try req.object.put(a, "grantFile", .{ .string = s.options.grant_file orelse try std.fmt.allocPrint(a, "{s}/omagma/terminal-grants.json", .{s.env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{s.env.get("HOME") orelse return error.HomeRequired})}) });
        if ((id != .null and id != .string and id != .integer) or (id == .string and id.string.len > 256)) return failure(out_allocator, .null, account, "InvalidRequest", "id must be a bounded string or integer");
        const data = s.dispatch(a, req) catch |err| {
            // Internal cached callers own a cancelable lifetime. Keep the
            // cancellation signal out of protocol normalization for that path.
            if (cached_only and err == error.Canceled) return err;
            return failureForError(out_allocator, id, account, err);
        };
        return successResponse(out_allocator, id, account, j.text(req, "cmd"), s.options.fixtures, data);
    }
    fn failure(a: std.mem.Allocator, id: Value, account: []const u8, code: []const u8, message: []const u8) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .id = id, .ok = false, .account = account, .@"error" = .{ .code = code, .message = message } }, .{});
    }
    fn failureForError(a: std.mem.Allocator, id: Value, account: []const u8, err: anyerror) ![]const u8 {
        return failure(a, id, account, @errorName(err), errorMessage(err)) catch |encoding_error| {
            // A failed error frame must not replace the warning that a remote
            // mutation may already have happened, including at CLI exit.
            if (err == error.UnknownOutcome) return error.UnknownOutcome;
            return encoding_error;
        };
    }
    fn successResponse(a: std.mem.Allocator, id: Value, account: []const u8, cmd: []const u8, fixtures: bool, data: Value) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .id = id, .ok = true, .account = account, .data = data }, .{}) catch |err| {
            if (!fixtures) for ([_][]const u8{ "mail.batch", "mail.undo", "contacts.upsert", "mail.mark", "mail.archive", "mail.trash", "mail.restore", "mail.send", "draft.send", "queue.process", "invitation.reply", "labels.create", "labels.rename", "labels.delete", "labels.color" }) |mutation| {
                if (std.mem.eql(u8, cmd, mutation)) return failureForError(a, id, account, error.UnknownOutcome);
            };
            return err;
        };
    }
    fn errorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.PermissionDenied => "This account lacks the required capability; authorize terminal access separately",
            error.UnknownAccount => "Choose an explicitly configured account",
            error.UnknownOutcome => "Outcome is unknown; do not automatically retry",
            error.OperationConflict => "This operation identity was already used for different content",
            error.CacheBusy => "Another client is using this account cache; retry later",
            error.UnknownQueryOperator, error.InvalidQueryDate, error.InvalidQueryValue, error.InvalidQuery, error.TimezoneUnavailable, error.TimezoneRangeUnavailable => cache_query.diagnostic(err),
            else => @errorName(err),
        };
    }
    fn dispatch(s: *Session, a: std.mem.Allocator, req: Value) !Value {
        const cmd = try j.required(req, "cmd");
        if (j.get(req, "original") != null) {
            _ = try j.boolean(req, "original", false);
            if (!std.mem.eql(u8, cmd, "mail.forward")) return error.OriginalRequiresForward;
        }
        if (j.get(req, "preserveFormatting") != null) {
            _ = try j.boolean(req, "preserveFormatting", false);
            if (!std.mem.eql(u8, cmd, "mail.forward") and !std.mem.eql(u8, cmd, "mail.reply")) return error.PreserveFormattingRequiresReplyOrForward;
        }
        if (try j.boolean(req, "original", false) and try j.boolean(req, "preserveFormatting", false)) return error.ConflictingForwardModes;
        if (std.mem.eql(u8, cmd, "accounts.list")) {
            const Account = struct { address: []const u8, enabled: bool, capabilities: []const []const u8, senderName: []const u8 = "", signature: []const u8 = "" };
            var list: std.ArrayList(Account) = .empty;
            const registry = if (!s.options.fixtures) try @import("auth.zig").load(s.io, a, try j.required(req, "grantFile")) else @import("auth.zig").Registry{};
            for (s.config.accounts[0..s.config.count]) |*account| {
                const grant = @import("auth.zig").find(&registry, account.address.slice());
                try list.append(a, .{ .address = account.address.slice(), .enabled = account.enabled, .senderName = account.sender_name.slice(), .signature = account.signature.slice(), .capabilities = if (s.options.fixtures and !s.scenario("readonly")) &.{ "mail-read", "mail-modify", "mail-send", "contacts-read", "contacts-write", "calendar-rsvp" } else if (grant) |g| if (g.enabled) g.capabilities else &.{} else &.{"mail-read"} });
            }
            return j.value(a, .{ .accounts = list.items });
        }
        const address = try j.required(req, "account");
        const index = s.config.index(address) orelse return error.UnknownAccount;
        if (!s.config.accounts[index].enabled) return error.AccountDisabled;
        try recipients.validateAddress(address);
        if ((j.text(req, "beforeMessageId").len != 0 or j.text(req, "afterMessageId").len != 0) and !try j.boolean(req, "cacheOnly", false)) return error.CacheWindowRequiresCached;
        if (std.mem.startsWith(u8, cmd, "auth.")) {
            if (s.options.fixtures) {
                if (!std.mem.eql(u8, cmd, "auth.status")) return error.FixtureOnly;
                return j.value(a, .{ .configured = true, .fixture = true });
            }
            return @import("auth.zig").run(s.io, a, &s.config, s.env, req);
        }
        if (std.mem.eql(u8, cmd, "cache.refresh-status")) return j.value(a, .{ .refreshInProgress = try storage.refreshActive(s.io, s.cache_root, address, s.options) });
        if (std.mem.eql(u8, cmd, "browser.open")) {
            const target = try @import("../open_target.zig").makeUrl(&s.config.accounts[index], try j.required(req, "url"));
            if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, &s.config.accounts[index], &target);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .url = target.url.slice(), .profile = target.profile_arg.slice() });
        }
        if (std.mem.eql(u8, cmd, "attachment.open")) {
            const path = try j.required(req, "path");
            if (path.len == 0 or path.len > 4096) return error.InvalidAttachmentPath;
            try recipients.validateHeader(path);
            if (!s.options.fixtures) try @import("../open_target.zig").openSavedAttachment(s.io, a, path);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures });
        }
        if (std.mem.eql(u8, cmd, "cache.activity") or try j.boolean(req, "cacheOnly", false)) return s.cachedDispatch(a, address, req);
        if (std.mem.eql(u8, cmd, "mail.batch") or std.mem.eql(u8, cmd, "mail.undo")) return s.batchMail(a, address, req);
        if (std.mem.eql(u8, cmd, "mail.prefetch")) {
            var request = try j.copyObject(a, req);
            const limit = try j.integer(req, "limit", @intCast(s.options.body_prefetch_limit));
            if (limit < 0 or limit > 64) return error.InvalidPrefetchLimit;
            try request.object.put(a, "cmd", .{ .string = "mail.refresh" });
            try request.object.put(a, "prefetchLimit", .{ .integer = limit });
            try request.object.put(a, "limit", .{ .integer = @max(1, limit) });
            return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), refreshJob, .{ s, a, address, request });
        }
        if (std.mem.eql(u8, cmd, "mail.refresh")) return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), refreshJob, .{ s, a, address, req });
        var store = try storage.Store.open(s.io, a, s.cache_root, address, s.options);
        defer store.close();
        if (std.mem.eql(u8, cmd, "attachment.import")) return j.value(a, try @import("attachment_blob.zig").importFile(&store, try j.required(req, "path"), j.text(req, "mimeType")));
        if (std.mem.eql(u8, cmd, "attachment.discard")) {
            try @import("attachment_blob.zig").discard(&store, try j.required(req, "blobId"));
            return j.value(a, .{ .discarded = true });
        }
        if (std.mem.eql(u8, cmd, "labels.palette")) return j.value(a, .{ .colors = label_collection.palette });
        if (std.mem.eql(u8, cmd, "mail.label-state")) return s.labelState(a, &store, req);
        if (std.mem.eql(u8, cmd, "mail.triage-scope")) {
            try s.capability(a, address, req, "mail-read");
            const scope = try triage.scope(req);
            const message_id = try j.required(req, "messageId");
            try @import("../bounded.zig").identifier(message_id);
            if (!s.options.fixtures) {
                store.release();
                return s.remote(a, address, cmd, req);
            }
            const source = try s.fixtureProviderSource(a, &store);
            const messages = try array(source, "messages");
            var thread_id: []const u8 = "";
            for (messages) |message| if (std.mem.eql(u8, j.text(message, "id"), message_id)) {
                thread_id = j.text(message, "threadId");
                break;
            };
            for (store.state.outbox) |message| if (std.mem.eql(u8, message.id, message_id)) {
                thread_id = message.threadId;
                break;
            };
            if (thread_id.len == 0) return error.MessageNotFound;
            var ids: std.ArrayList([]const u8) = .empty;
            if (scope == .message) try ids.append(a, message_id) else {
                for (messages) |message| if (std.mem.eql(u8, j.text(message, "threadId"), thread_id)) {
                    if (ids.items.len == 100) return error.ThreadTooLarge;
                    try ids.append(a, try j.required(message, "id"));
                };
                for (store.state.outbox) |message| if (std.mem.eql(u8, message.threadId, thread_id)) {
                    var duplicate = false;
                    for (ids.items) |id| duplicate = duplicate or std.mem.eql(u8, id, message.id);
                    if (!duplicate) {
                        if (ids.items.len == 100) return error.ThreadTooLarge;
                        try ids.append(a, message.id);
                    }
                };
            }
            return j.value(a, .{ .scope = scope, .threadId = thread_id, .messageIds = ids.items, .count = ids.items.len, .complete = true });
        }
        if (std.mem.eql(u8, cmd, "labels.list")) return s.loadLabels(a, &store, req, false);
        if (std.mem.eql(u8, cmd, "labels.create") or std.mem.eql(u8, cmd, "labels.rename") or std.mem.eql(u8, cmd, "labels.delete") or std.mem.eql(u8, cmd, "labels.color")) return s.manageLabels(a, &store, req);
        if (std.mem.eql(u8, cmd, "accounts.identities")) return s.identities(a, &store, req, false);
        if (std.mem.eql(u8, cmd, "cache.stats")) return s.cacheStats(a, &store);
        if (std.mem.eql(u8, cmd, "cache.clear")) {
            try store.clearMail();
            return j.value(a, .{ .cleared = true, .draftsPreserved = true, .operationsPreserved = true });
        }
        if (std.mem.eql(u8, cmd, "operation.list")) return j.value(a, .{ .operations = store.state.operations });
        if (std.mem.eql(u8, cmd, "operation.read")) {
            const operation_id = try j.required(req, "operationId");
            for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, operation_id)) return j.value(a, operation);
            return error.OperationNotFound;
        }
        if (std.mem.eql(u8, cmd, "draft.list")) return j.value(a, .{ .drafts = store.state.drafts });
        if (std.mem.eql(u8, cmd, "draft.queue") or std.mem.startsWith(u8, cmd, "queue.")) return s.queuedSend(a, &store, req);
        if (std.mem.eql(u8, cmd, "draft.read")) return j.value(a, try store.draft(try j.required(req, "draftId")));
        if (std.mem.eql(u8, cmd, "draft.open-preview")) {
            try s.capability(a, address, req, "mail-read");
            const draft = try store.draft(try j.required(req, "draftId"));
            try validateDraft(draft, false);
            const prepared = try markdown_mail.prepare(a, draft);
            var header_draft = draft;
            if (header_draft.from == null) header_draft.from = .{ .address = address };
            const preview = @import("preview_file.zig");
            try store.reserveBytes(try preview.byteSize(prepared, header_draft));
            try store.save();
            const written = try preview.writePreview(s.io, a, store.dir, prepared, header_draft);
            const target = try @import("../open_target.zig").makePreview(&s.config.accounts[index], written.path);
            if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, &s.config.accounts[index], &target);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .path = written.path, .url = target.url.slice(), .profile = target.profile_arg.slice() });
        }
        if (std.mem.eql(u8, cmd, "draft.preview")) {
            const draft = if (j.get(req, "draft")) |input| try decodeDraft(a, input) else try store.draft(try j.required(req, "draftId"));
            try validateDraft(draft, false);
            const prepared = try markdown_mail.prepare(a, draft);
            return j.value(a, .{ .bodyFormat = draft.bodyFormat, .bodyText = if (draft.recoveryFields) |fields| fields[4] else draft.bodyText, .plainText = prepared.plain, .bodyHtml = prepared.html });
        }
        if (std.mem.eql(u8, cmd, "draft.recovery-save")) {
            const input = j.get(req, "draft") orelse return error.MissingField;
            const fields = try j.decode([]const []const u8, a, j.get(input, "recoveryFields") orelse return error.MissingField);
            if (fields.len != 5) return error.InvalidRecovery;
            for (fields, 0..) |field, i| if (field.len > (if (i == 4) t.Limits.body_bytes else @as(usize, 16 * 1024)) or !std.unicode.utf8ValidateSlice(field)) return error.InvalidRecovery;
            var clean = try j.copyObject(a, input);
            _ = clean.object.swapRemove("to");
            _ = clean.object.swapRemove("cc");
            _ = clean.object.swapRemove("bcc");
            _ = clean.object.swapRemove("recoveryFields");
            try clean.object.put(a, "subject", .{ .string = fields[3] });
            try clean.object.put(a, "bodyText", .{ .string = fields[4] });
            var draft = try decodeDraft(a, clean);
            if (j.get(input, "bodyFormat") == null and j.text(req, "draftId").len != 0) draft.bodyFormat = (try store.draft(j.text(req, "draftId"))).bodyFormat;
            if (j.get(input, "original") == null and j.text(req, "draftId").len != 0) draft.original = (try store.draft(j.text(req, "draftId"))).original;
            try validateDraft(draft, false);
            draft.recoveryFields = fields;
            // The recovery body lives in the raw fields once, while the index
            // retains only its subject. Normal drafts keep bodyText as before.
            draft.bodyText = "";
            return j.value(a, try store.putDraft(draft, if (j.text(req, "draftId").len != 0) j.text(req, "draftId") else null));
        }
        if (std.mem.eql(u8, cmd, "draft.discard")) {
            try store.discardDraft(try j.required(req, "draftId"));
            return j.value(a, .{ .discarded = true });
        }
        if (std.mem.eql(u8, cmd, "draft.create") or std.mem.eql(u8, cmd, "draft.update")) {
            const input = j.get(req, "draft") orelse return error.MissingField;
            var draft = try decodeDraft(a, input);
            if (std.mem.eql(u8, cmd, "draft.update") and j.get(input, "bodyFormat") == null) draft.bodyFormat = (try store.draft(try j.required(req, "draftId"))).bodyFormat;
            if (std.mem.eql(u8, cmd, "draft.update") and j.get(input, "original") == null) draft.original = (try store.draft(try j.required(req, "draftId"))).original;
            try validateDraft(draft, false);
            return j.value(a, try store.putDraft(draft, if (std.mem.eql(u8, cmd, "draft.update")) try j.required(req, "draftId") else null));
        }
        if (std.mem.eql(u8, cmd, "mail.send") or std.mem.eql(u8, cmd, "draft.send")) {
            const draft = if (std.mem.eql(u8, cmd, "draft.send")) try store.draft(try j.required(req, "draftId")) else try decodeDraft(a, j.get(req, "draft") orelse return error.MissingField);
            return s.send(a, &store, req, draft, null, false);
        }
        if (std.mem.eql(u8, cmd, "mail.reply")) {
            const format = try requestBodyFormat(req);
            const preserve = try j.boolean(req, "preserveFormatting", false);
            // Legacy immutable caches predate CID metadata. A formatted draft
            // always captures the provider's current FULL source read-only.
            const message = try s.readMessage(a, &store, try j.required(req, "messageId"), req, !preserve);
            const original: ?t.Original = if (preserve) try s.captureOriginal(a, &store, req, message) else null;
            const threading = try @import("mime.zig").threading(message.messageId, message.references, message.inReplyTo, a);
            var envelope: recipients.Envelope = .{};
            const aliases = if (!s.options.fixtures) try j.decode([]const []const u8, a, j.get(try s.remote(a, address, "accounts.aliases", req), "aliases") orelse return error.InvalidProviderResponse) else &.{};
            try recipients.replyIncoming(a, address, aliases, try addressHeader(a, &.{message.from}), try addressHeader(a, message.replyTo), try addressHeader(a, message.to), try addressHeader(a, message.cc), try j.boolean(req, "all", false), &envelope);
            const d: t.Draft = .{ .to = try listAddresses(a, &envelope.to), .cc = try listAddresses(a, &envelope.cc), .subject = if (std.ascii.startsWithIgnoreCase(message.subject, "Re:")) message.subject else try std.fmt.allocPrint(a, "Re: {s}", .{message.subject}), .bodyText = if (preserve) "" else try quote(a, if (format == .markdown) try markdown_mail.escapeSource(a, message.bodyText) else message.bodyText), .bodyFormat = format, .threadId = message.threadId, .inReplyTo = threading.in_reply_to, .references = threading.references, .original = original };
            try validateDraft(d, false);
            if (preserve) _ = try markdown_mail.prepare(a, d);
            return j.value(a, try store.putDraft(d, null));
        }
        if (std.mem.eql(u8, cmd, "mail.forward")) {
            const format = try requestBodyFormat(req);
            if (try j.boolean(req, "original", false)) return s.forwardRaw(a, &store, req, format);
            const preserve = try j.boolean(req, "preserveFormatting", false);
            const message = try s.readMessage(a, &store, try j.required(req, "messageId"), req, !preserve);
            if (message.attachments.len > (if (preserve) t.Limits.attachments + t.Limits.related_resources else t.Limits.attachments)) return error.TooManyAttachments;
            var total: usize = 0;
            for (message.attachments) |attachment| total = std.math.add(usize, total, attachment.size) catch return error.AttachmentsTooLarge;
            if (total > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
            const attachments = try a.dupe(t.Attachment, message.attachments);
            for (attachments) |*attachment| if (attachment.data.len == 0 and attachment.size != 0) {
                var request = try j.copyObject(a, req);
                try request.object.put(a, "attachmentId", .{ .string = attachment.id });
                attachment.* = try s.fetchKnownAttachment(a, &store, request, message);
            };
            if (preserve) {
                var hydrated = message;
                hydrated.attachments = attachments;
                const snapshot = try s.captureOriginal(a, &store, req, hydrated);
                var files: std.ArrayList(t.Attachment) = .empty;
                for (attachments) |attachment| {
                    var related = false;
                    for (snapshot.resources) |resource| related = related or std.mem.eql(u8, attachment.id, resource.id);
                    if (!related) try files.append(a, attachment);
                }
                const draft: t.Draft = .{ .subject = if (std.ascii.startsWithIgnoreCase(message.subject, "Fwd:")) message.subject else try std.fmt.allocPrint(a, "Fwd: {s}", .{message.subject}), .bodyFormat = format, .attachments = files.items, .original = snapshot };
                try validateDraft(draft, false);
                _ = try markdown_mail.prepare(a, draft);
                return j.value(a, try store.putDraft(draft, null));
            }
            for (attachments) |*attachment| {
                attachment.contentId = null;
                attachment.disposition = null;
                attachment.contentLocation = null;
            }
            // A forward is a new conversation, not a reply to the old thread.
            const original = try std.fmt.allocPrint(a, "---------- Forwarded message ----------\nFrom: {s} <{s}>\nSubject: {s}\n\n{s}", .{ message.from.name, message.from.address, message.subject, message.bodyText });
            const body = if (format == .markdown) try quote(a, try markdown_mail.escapeSource(a, original)) else try std.fmt.allocPrint(a, "\n\n{s}", .{original});
            const draft: t.Draft = .{ .subject = if (std.ascii.startsWithIgnoreCase(message.subject, "Fwd:")) message.subject else try std.fmt.allocPrint(a, "Fwd: {s}", .{message.subject}), .bodyText = body, .bodyFormat = format, .attachments = attachments };
            try validateDraft(draft, false);
            return j.value(a, try store.putDraft(draft, null));
        }
        if (std.mem.eql(u8, cmd, "mail.list") or std.mem.eql(u8, cmd, "mail.search") or std.mem.eql(u8, cmd, "mail.sync")) return s.listMail(a, &store, req);
        if (std.mem.eql(u8, cmd, "mail.read")) return j.value(a, try s.read(a, &store, try j.required(req, "messageId"), req));
        if (std.mem.eql(u8, cmd, "mail.open")) {
            const id = j.text(req, "messageId");
            var message: @import("../model.zig").Message = .{};
            if (id.len > 0) {
                try s.capability(a, address, req, "mail-read");
                const m = if (store.find(id)) |cached| cached.message else try s.read(a, &store, id, req);
                try message.thread_id.set(m.threadId);
                try message.message_id.set(m.messageId);
            }
            const target = try @import("../open_target.zig").make(&s.config.accounts[index], if (id.len > 0) &message else null, false);
            if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, &s.config.accounts[index], &target);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .url = target.url.slice(), .profile = target.profile_arg.slice() });
        }
        if (std.mem.eql(u8, cmd, "mail.thread")) {
            try s.capability(a, address, req, "mail-read");
            if (!s.options.fixtures) {
                const expected = store.state.generation;
                store.release();
                const result = try s.remote(a, address, cmd, req);
                try s.reopenBody(a, &store);
                for (try array(result, "messages")) |v| {
                    const message = try j.decode(t.Message, a, v);
                    if (store.state.generation == expected) try store.put(message, true) else _ = try store.putBody(message);
                }
                try store.save();
                return result;
            }
            const thread = try j.required(req, "threadId");
            const source = try s.fixtureProviderSource(a, &store);
            var messages: std.ArrayList(t.Message) = .empty;
            var thread_total: usize = 0;
            for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "threadId"), thread)) {
                thread_total += 1;
            };
            for (store.state.outbox) |entry| if (std.mem.eql(u8, entry.threadId, thread)) {
                thread_total += 1;
            };
            if (thread_total != 0) s.reportProgress(.bodies, 0, thread_total);
            for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "threadId"), thread)) {
                var m = try s.normalize(a, source, v);
                if (store.find(m.id)) |existing| {
                    m.labels = existing.message.labels;
                    m.unread = existing.message.unread;
                }
                try store.put(m, true);
                try messages.append(a, m);
                s.reportProgress(.bodies, messages.items.len, thread_total);
            };
            for (store.state.outbox) |entry| if (std.mem.eql(u8, entry.threadId, thread)) {
                if (try store.readOutbox(entry.id)) |sent| try messages.append(a, sent);
                s.reportProgress(.bodies, messages.items.len, thread_total);
            };
            if (messages.items.len == 0) return error.MessageNotFound;
            std.mem.sort(t.Message, messages.items, {}, olderFirst);
            try store.save();
            return j.value(a, .{ .messages = messages.items });
        }
        if (std.mem.eql(u8, cmd, "mail.attachment")) {
            return j.value(a, try s.fetchKnownAttachment(a, &store, req, null));
        }
        if (std.mem.eql(u8, cmd, "mail.attachment-save")) return s.saveKnownAttachment(a, &store, req);
        if (std.mem.eql(u8, cmd, "mail.archive") or std.mem.eql(u8, cmd, "mail.trash") or std.mem.eql(u8, cmd, "mail.restore") or std.mem.eql(u8, cmd, "mail.mark")) {
            try s.capability(a, address, req, "mail-modify");
            if (!s.options.fixtures) {
                const id = try j.required(req, "messageId");
                // Discard cached state before dispatch, including uncertain outcomes.
                try store.invalidate(id);
                store.state.generation += 1;
                try store.save();
                return s.remote(a, address, cmd, req);
            }
            if (s.scenario("rejected-mutation")) return error.ProviderRejected;
            var m = try s.read(a, &store, try j.required(req, "messageId"), req);
            const provider_source = try s.fixtureProviderSource(a, &store);
            var canonical = false;
            for (try array(provider_source, "messages")) |raw| if (std.mem.eql(u8, j.text(raw, "id"), m.id)) {
                m.labels = try fixtureLabels(a, raw);
                canonical = true;
                break;
            };
            for (store.state.outbox) |sent| canonical = canonical or std.mem.eql(u8, sent.id, m.id);
            if (!canonical) return error.MessageNotFound;
            var labels: std.ArrayList([]const u8) = .empty;
            try labels.appendSlice(a, m.labels);
            if (std.mem.eql(u8, cmd, "mail.archive")) removeLabel(&labels, "INBOX");
            if (std.mem.eql(u8, cmd, "mail.trash")) {
                removeLabel(&labels, "INBOX");
                try addLabel(a, &labels, "TRASH");
            }
            if (std.mem.eql(u8, cmd, "mail.restore")) {
                removeLabel(&labels, "TRASH");
                try addLabel(a, &labels, "INBOX");
            }
            if (j.get(req, "unread")) |_| {
                if (try j.boolean(req, "unread", false)) try addLabel(a, &labels, "UNREAD") else removeLabel(&labels, "UNREAD");
            }
            if (j.get(req, "starred")) |_| {
                if (try j.boolean(req, "starred", false)) try addLabel(a, &labels, "STARRED") else removeLabel(&labels, "STARRED");
            }
            if (j.get(req, "addLabels")) |v| for (try valueArray(v)) |label| {
                const text = try j.string(label);
                try recipients.validateHeader(text);
                try addLabel(a, &labels, try fixtureLabel(provider_source, text));
            };
            if (j.get(req, "removeLabels")) |v| for (try valueArray(v)) |label| removeLabel(&labels, try fixtureLabel(provider_source, try j.string(label)));
            m.labels = labels.items;
            m.unread = hasLabel(m, "UNREAD");
            store.state.fixtureCalls += 1;
            store.state.generation += 1;
            for (store.state.views) |*view| view.stale = true;
            // Labels do not change the immutable body. Retain its existing
            // residency/hash without allocating an atomic second body copy.
            if (!store.updateOutboxMetadata(m)) {
                try store.setFixtureRecord(m.id, m.labels, fixtureCheckpoint(provider_source), false);
                try store.put(m, false);
            }
            try store.save();
            return j.value(a, m);
        }
        if (std.mem.eql(u8, cmd, "contacts.list") or std.mem.eql(u8, cmd, "contacts.search") or std.mem.eql(u8, cmd, "contacts.upsert")) return s.contacts(a, &store, req, cmd);
        if (std.mem.eql(u8, cmd, "invitation.reply") or std.mem.eql(u8, cmd, "invitation.inspect")) {
            try s.capability(a, address, req, if (std.mem.eql(u8, cmd, "invitation.inspect")) "mail-read" else "calendar-rsvp");
            const message_id = try j.required(req, "messageId");
            var m = try s.read(a, &store, message_id, req);
            // Repair old metadata-only calendar attachments only when the
            // user explicitly inspects this mail. Cache browsing stays local.
            if (m.invitation == null) for (m.attachments) |part| {
                if (!@import("mime.zig").isCalendarPart(part.mimeType, part.filename)) continue;
                m = try s.readMessage(a, &store, message_id, req, false);
                break;
            };
            const ics = m.invitation orelse return error.NotInvitation;
            var invite: invitation.Invitation = .{};
            const aliases = if (!s.options.fixtures) try j.decode([]const []const u8, a, j.get(try s.remote(a, address, "accounts.aliases", req), "aliases") orelse return error.InvalidProviderResponse) else &.{};
            try invitation.parse(ics, address, aliases, &invite);
            if (std.mem.eql(u8, cmd, "invitation.inspect")) {
                const timezone = @import("timezone.zig");
                const local_zone = timezone.load(s.io, a, s.env) catch timezone.Zone{ .unavailable = true };
                const event_name = invitation.eventTimezone(&invite);
                const event_zone: ?timezone.Zone = if (event_name.len != 0 and invite.timezones.len == 0) timezone.loadNamed(s.io, a, s.env, event_name) catch null else null;
                const friendly = try invitation.friendlyWithZone(a, &invite, &local_zone, if (event_zone) |*zone| zone else null);
                return j.value(a, .{ .uid = invite.uid.slice(), .organizer = invite.organizer.slice(), .attendee = invite.attendee.slice(), .attendeeStatus = invite.attendee_status.slice(), .sequence = invite.sequence, .recurrenceId = invite.recurrence_id.slice(), .summary = invite.summary.slice(), .start = invite.start.slice(), .startDisplay = friendly.start, .endDisplay = friendly.end, .durationDisplay = friendly.duration, .location = friendly.location, .joinUrl = friendly.join_url, .recurrenceDisplay = friendly.recurrence, .allDay = friendly.all_day, .timezoneUnavailable = friendly.timezone_unavailable });
            }
            const status = std.meta.stringToEnum(invitation.Status, try j.required(req, "status")) orelse return error.InvalidInvitationStatus;
            const buf = try a.alloc(u8, invitation.max_calendar_bytes);
            const reply = try invitation.reply(&invite, status, try utcStamp(s.io, a), buf);
            const d: t.Draft = .{ .to = &.{.{ .address = invite.organizer.slice() }}, .subject = try std.fmt.allocPrint(a, "{s}: {s}", .{ @tagName(status), m.subject }), .bodyText = try std.fmt.allocPrint(a, "Invitation response: {s}", .{@tagName(status)}) };
            return s.send(a, &store, req, d, reply, false);
        }
        return error.UnsupportedCommand;
    }
    fn loadLabels(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, cached: bool) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        if (!cached) {
            if (!s.options.fixtures) {
                store.release();
                const response = try s.remote(a, store.state.account, "labels.list", req);
                try s.reopenBody(a, store);
                store.state.labels = try j.decode([]storage.Label, a, j.get(response, "labels") orelse return error.InvalidProviderResponse);
            } else {
                try s.ensureFixtureLabels(a, store, try s.fixture(a, store.state.account));
            }
            if (store.state.labels.len > 512) return error.TooManyLabels;
            for (store.state.labels) |label| {
                try @import("../bounded.zig").identifier(label.id);
                if (label.name.len > 512) return error.InvalidLabel;
                try recipients.validateHeader(label.name);
            }
            try store.save();
        }
        return j.value(a, .{ .labels = store.state.labels, .cached = cached });
    }
    fn labelState(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        const ids = try triage.pinned(a, req);
        _ = try s.loadLabels(a, store, req, false);
        const LabelState = struct { id: []const u8, name: []const u8, type: []const u8, color: ?t.LabelColor = null, appliedCount: usize = 0 };
        const labels = try a.alloc(LabelState, store.state.labels.len);
        for (store.state.labels, labels) |definition, *label| label.* = .{ .id = definition.id, .name = definition.name, .type = definition.type, .color = definition.color };
        var remote_state: BatchRemote = .{ .session = s };
        if (s.options.fixtures) remote_state.source = try s.fixtureProviderSource(a, store);
        var network: @import("gmail.zig").NetworkSession = undefined;
        var opened = false;
        defer if (opened) network.close();
        store.release();
        for (ids) |id| {
            var uncertain = false;
            for (store.state.undo) |receipt| for (receipt.items) |item| {
                if (std.mem.eql(u8, item.messageId, id) and (std.mem.eql(u8, item.outcome, "unknown") or std.mem.eql(u8, item.errorCode, "UnknownOutcome"))) uncertain = true;
            };
            const cached = if (uncertain) null else store.find(id);
            const memberships: []const []const u8 = if (cached) |entry| entry.message.labels else missing: {
                if (!s.options.fixtures and !opened) {
                    try network.init(s.io, a, &s.config, store.state.account, "mail.labels", req);
                    remote_state.transport = network.transport();
                    opened = true;
                }
                break :missing try BatchRemote.labelsFn(&remote_state, a, store, id);
            };
            for (labels) |*label| {
                for (memberships) |membership| if (std.mem.eql(u8, membership, label.id)) {
                    label.appliedCount += 1;
                    break;
                };
            }
        }
        return j.value(a, .{ .messageIds = ids, .count = ids.len, .labels = labels, .complete = true });
    }

    fn ensureFixtureLabels(_: *Session, a: std.mem.Allocator, store: *storage.Store, source: Value) !void {
        if (store.state.fixtureLabelsReady) return;
        store.state.labels = try j.decode([]storage.Label, a, try fixtureLabelDefinitions(a, source));
        if (store.state.labels.len > 512) return error.TooManyLabels;
        for (store.state.labels) |label| {
            try @import("../bounded.zig").identifier(label.id);
            if (label.name.len > 512 or !std.unicode.utf8ValidateSlice(label.name)) return error.InvalidLabel;
            try recipients.validateHeader(label.name);
        }
    }

    fn labelReceipt(a: std.mem.Allocator, operation: storage.Operation) !Value {
        return j.value(a, .{ .outcome = operation.outcome, .operationId = operation.id, .labelId = operation.labelId, .label = if (operation.label) |label| try j.value(a, label) else @as(Value, .null), .deleted = operation.deleted, .errorCode = operation.errorCode });
    }

    fn manageLabels(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        try s.capability(a, store.state.account, req, "mail-modify");
        const cmd = j.text(req, "cmd");
        const create = std.mem.eql(u8, cmd, "labels.create");
        const deleting = std.mem.eql(u8, cmd, "labels.delete");
        const coloring = std.mem.eql(u8, cmd, "labels.color");
        const color = try label_collection.requestColor(a, req);
        if (coloring and color == null) return error.InvalidLabelColor;
        if (deleting and color != null) return error.InvalidLabelColor;
        const operation_id = try j.required(req, "operationId");
        if (operation_id.len > 256) return error.InvalidOperationId;
        try recipients.validateHeader(operation_id);
        const id = if (create) "" else try j.required(req, "labelId");
        const name = if (deleting or coloring) "" else try j.required(req, "name");
        const confirmation = if (deleting) try j.required(req, "confirmName") else "";
        if (!create) try label_collection.validateId(id);
        if (!deleting and !coloring) try label_collection.validateName(name);
        if (confirmation.len > 512) return error.InvalidLabelConfirmation;
        try recipients.validateHeader(confirmation);
        var intent = try j.value(a, .{ .cmd = cmd, .account = store.state.account, .labelId = id, .name = name, .confirmName = confirmation });
        if (color) |value| try intent.object.put(a, "color", try j.value(a, value));
        const payload = try std.json.Stringify.valueAlloc(a, intent, .{});
        const digest = storage.Store.hash(payload);
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, operation_id)) {
            if (!std.mem.eql(u8, operation.hash, &digest) or !std.mem.eql(u8, operation.kind, cmd)) return error.OperationConflict;
            return labelReceipt(a, operation);
        };
        // An uncertain collection mutation must be reconciled explicitly; a
        // fresh identity must not silently cause a second provider request.
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and std.mem.startsWith(u8, operation.kind, "labels.")) {
            if (std.mem.eql(u8, operation.hash, &digest) or (!create and std.mem.eql(u8, operation.labelId, id))) return labelReceipt(a, operation);
        };
        if (store.state.operations.len == 1000) return error.OperationJournalFull;
        _ = try s.loadLabels(a, store, req, false);
        // The live list temporarily releases the store; another client may
        // have journaled this identity while the GET was in progress.
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, operation_id)) {
            if (!std.mem.eql(u8, operation.hash, &digest) or !std.mem.eql(u8, operation.kind, cmd)) return error.OperationConflict;
            return labelReceipt(a, operation);
        };
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and std.mem.startsWith(u8, operation.kind, "labels.")) {
            if (std.mem.eql(u8, operation.hash, &digest) or (!create and std.mem.eql(u8, operation.labelId, id))) return labelReceipt(a, operation);
        };
        if (store.state.operations.len == 1000) return error.OperationJournalFull;
        const old = if (!create) try label_collection.custom(store.state.labels, id) else storage.Label{ .id = "", .name = "" };
        const final_name = if (coloring) old.name else name;
        if (deleting) {
            if (!std.mem.eql(u8, confirmation, old.name)) return error.InvalidLabelConfirmation;
            if (s.options.fixtures and store.state.fixtureDeletedLabels.len == 512) return error.TooManyDeletedLabels;
        } else {
            try label_collection.unique(store.state.labels, final_name, id);
            if (create and store.state.labels.len == 512) return error.TooManyLabels;
        }
        var operations: std.ArrayList(storage.Operation) = .empty;
        try operations.appendSlice(a, store.state.operations);
        try operations.append(a, .{ .id = operation_id, .hash = try a.dupe(u8, &digest), .kind = cmd, .labelId = id });
        store.state.operations = operations.items;
        if (s.options.fixtures) store.state.fixtureLabelsReady = true;
        // Commit intent before entering the transport. Crashes leave an unknown
        // receipt, rather than a replayable operation with no journal entry.
        try store.save();
        const result: Value = if (!s.options.fixtures) remote: {
            const account = store.state.account;
            store.release();
            const remote_result = s.remote(a, account, cmd, req) catch |err| {
                s.reopenBody(a, store) catch return error.UnknownOutcome;
                for (store.state.operations) |*operation| if (std.mem.eql(u8, operation.id, operation_id)) {
                    operation.errorCode = @errorName(err);
                    operation.outcome = switch (err) {
                        error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.LabelNotFound, error.MessageNotFound, error.SystemLabelImmutable, error.InvalidLabelName, error.InvalidLabelColor, error.InvalidLabelConfirmation, error.DuplicateLabelName, error.TooManyLabels, error.InvalidIdentifier => "rejected",
                        else => "unknown",
                    };
                    store.save() catch return error.UnknownOutcome;
                    return labelReceipt(a, operation.*);
                };
                return error.UnknownOutcome;
            };
            s.reopenBody(a, store) catch return error.UnknownOutcome;
            break :remote remote_result;
        } else fixture_result: {
            store.state.fixtureCalls += 1;
            if (s.scenario("rejected-mutation") or s.scenario("unknown-send")) {
                const operation = &store.state.operations[store.state.operations.len - 1];
                operation.outcome = if (s.scenario("rejected-mutation")) "rejected" else "unknown";
                operation.errorCode = if (s.scenario("rejected-mutation")) "ProviderRejected" else "UnknownOutcome";
                try store.save();
                return labelReceipt(a, operation.*);
            }
            if (deleting) {
                // Overlay all raw provider messages too, including messages
                // beyond the retained cache tail, so refresh cannot resurrect
                // deleted label memberships.
                const source = try s.fixtureProviderSource(a, store);
                for (try array(source, "messages")) |raw| {
                    var ids: std.ArrayList([]const u8) = .empty;
                    var changed = false;
                    for (try fixtureLabels(a, raw)) |label_id| {
                        if (std.mem.eql(u8, label_id, id)) changed = true else try ids.append(a, label_id);
                    }
                    if (changed) try store.setFixtureRecord(j.text(raw, "id"), ids.items, fixtureCheckpoint(source), false);
                }
                break :fixture_result try j.value(a, .{ .deleted = true, .labelId = id });
            }
            break :fixture_result try j.value(a, .{ .label = storage.Label{ .id = if (create) try store.nextId("Label") else id, .name = final_name, .type = "user", .color = color orelse old.color } });
        };
        if (!deleting and color != null) {
            const received = j.decode(storage.Label, a, j.get(result, "label") orelse return error.UnknownOutcome) catch return error.UnknownOutcome;
            if (!label_collection.sameColor(color, received.color)) return error.UnknownOutcome;
        }
        return s.commitLabelResult(a, store, operation_id, create, deleting, id, final_name, old.name, result) catch return error.UnknownOutcome;
    }

    fn commitLabelResult(s: *Session, a: std.mem.Allocator, store: *storage.Store, operation_id: []const u8, create: bool, deleting: bool, id: []const u8, name: []const u8, old_name: []const u8, result: Value) !Value {
        var operation_ptr: ?*storage.Operation = null;
        for (store.state.operations) |*operation| if (std.mem.eql(u8, operation.id, operation_id)) {
            operation_ptr = operation;
            break;
        };
        const operation = operation_ptr orelse return error.UnknownOutcome;
        if (deleting) {
            if (!try j.boolean(result, "deleted", false) or !std.mem.eql(u8, j.text(result, "labelId"), id)) return error.UnknownOutcome;
            var kept: usize = 0;
            for (store.state.labels) |label| if (!std.mem.eql(u8, label.id, id)) {
                store.state.labels[kept] = label;
                kept += 1;
            };
            store.state.labels = store.state.labels[0..kept];
            try store.labelCollectionChanged(id, old_name, null);
            operation.deleted = true;
        } else {
            const label = try j.decode(storage.Label, a, j.get(result, "label") orelse return error.UnknownOutcome);
            label_collection.validateId(label.id) catch return error.UnknownOutcome;
            if (!std.mem.eql(u8, label.name, name) or !std.ascii.eqlIgnoreCase(label.type, "user") or (!create and !std.mem.eql(u8, label.id, id))) return error.UnknownOutcome;
            if (create) {
                var definitions: std.ArrayList(storage.Label) = .empty;
                try definitions.appendSlice(a, store.state.labels);
                for (definitions.items) |known| if (std.mem.eql(u8, known.id, label.id)) return error.UnknownOutcome;
                try definitions.append(a, label);
                store.state.labels = definitions.items;
            } else for (store.state.labels) |*definition| if (std.mem.eql(u8, definition.id, id)) {
                definition.* = label;
                break;
            };
            try store.labelCollectionChanged(label.id, old_name, name);
            operation.label = label;
            operation.labelId = label.id;
        }
        operation.outcome = if (s.options.fixtures and s.scenario("applied-lost")) "unknown" else "applied";
        store.save() catch {
            operation.outcome = "unknown";
            return error.UnknownOutcome;
        };
        return labelReceipt(a, operation.*);
    }
    fn identities(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, cached: bool) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        const configured = s.config.accounts[s.config.index(store.state.account) orelse return error.UnknownAccount];
        const primary: storage.Identity = .{ .address = configured.address.slice(), .name = configured.sender_name.slice(), .signature = configured.signature.slice(), .isDefault = true };
        if (!cached) {
            if (!s.options.fixtures) {
                store.release();
                const response = try s.remote(a, store.state.account, "accounts.identities", req);
                try s.reopenBody(a, store);
                store.state.identities = try j.decode([]storage.Identity, a, j.get(response, "identities") orelse return error.InvalidProviderResponse);
            } else {
                const source = try s.fixture(a, store.state.account);
                store.state.identities = if (j.get(source, "identities")) |value| try j.decode([]storage.Identity, a, value) else try a.dupe(storage.Identity, &.{primary});
            }
            if (store.state.identities.len > 32) return error.TooManyAliases;
            for (store.state.identities) |*identity| {
                try recipients.validateAddress(identity.address);
                try recipients.validateHeader(identity.name);
                if (identity.name.len > 256 or identity.signature.len > 8192) return error.IdentityTooLarge;
                identity.signature = try @import("mime.zig").sanitizeText(identity.signature, a);
                if (std.ascii.eqlIgnoreCase(identity.address, primary.address)) {
                    if (primary.name.len != 0) identity.name = primary.name;
                    if (primary.signature.len != 0) identity.signature = primary.signature;
                }
            }
            try store.save();
        }
        var output: std.ArrayList(storage.Identity) = .empty;
        try output.appendSlice(a, store.state.identities);
        var present = false;
        for (output.items) |identity| present = present or std.ascii.eqlIgnoreCase(identity.address, primary.address);
        if (!present) try output.append(a, primary);
        return j.value(a, .{ .identities = output.items, .cached = cached });
    }
    const BatchRemote = struct {
        session: *Session,
        source: Value = .null,
        transport: ?@import("gmail.zig").Transport = null,
        fn labelsFn(ctx: *anyopaque, a: std.mem.Allocator, store: *storage.Store, id: []const u8) ![]const []const u8 {
            const self: *BatchRemote = @ptrCast(@alignCast(ctx));
            if (self.transport) |transport| {
                const value = try @import("gmail.zig").dispatchAuthorized(self.session.io, a, store.state.account, &.{"mail-read"}, transport, "mail.labels", try j.value(a, .{ .messageId = id }));
                return j.decode([]const []const u8, a, j.get(value, "labels") orelse return error.InvalidProviderResponse);
            }
            if (store.fixtureRecord(id)) |record| {
                if (record.deleted) return error.MessageNotFound;
                return record.labels;
            }
            for (store.state.outbox) |message| if (std.mem.eql(u8, id, message.id)) return message.labels;
            for (try array(self.source, "messages")) |raw| if (std.mem.eql(u8, id, j.text(raw, "id"))) return fixtureLabels(a, raw);
            return error.MessageNotFound;
        }
        fn modifyFn(ctx: *anyopaque, a: std.mem.Allocator, id: []const u8, before: []const []const u8, delta: triage.Delta) ![]const []const u8 {
            const self: *BatchRemote = @ptrCast(@alignCast(ctx));
            if (self.transport) |transport| {
                const value = try @import("gmail.zig").dispatchAuthorized(self.session.io, a, j.text(self.source, "account"), &.{"mail-modify"}, transport, "mail.modify-labels", try j.value(a, .{ .messageId = id, .addLabels = delta.add, .removeLabels = delta.remove }));
                return j.decode([]const []const u8, a, j.get(value, "labels") orelse return error.InvalidProviderResponse);
            }
            if (self.session.scenario("rejected-mutation")) return error.ProviderRejected;
            if (self.session.scenario("unknown-batch")) return error.UnknownOutcome;
            return triage.apply(a, before, delta);
        }
    };
    fn batchMail(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value) !Value {
        try s.capability(a, address, req, "mail-modify");
        _ = try triage.scope(req);
        const undoing = std.mem.eql(u8, j.text(req, "cmd"), "mail.undo");
        var delta: triage.Delta = .{ .add = &.{}, .remove = &.{} };
        if (undoing) {
            const token = try j.required(req, "undoToken");
            if (token.len > 256) return error.InvalidUndoToken;
        } else {
            const ids = j.get(req, "messageIds") orelse return error.MissingField;
            if (ids != .array or ids.array.items.len == 0 or ids.array.items.len > 100) return error.InvalidBatchSize;
            for (ids.array.items, 0..) |value, i| {
                const id = try j.string(value);
                try @import("../bounded.zig").identifier(id);
                for (ids.array.items[0..i]) |previous| if (std.mem.eql(u8, id, try j.string(previous))) return error.DuplicateMessage;
            }
            delta = try triage.plan(a, req);
        }
        var batch_remote: BatchRemote = .{ .session = s, .source = try j.value(a, .{ .account = address }) };
        if (s.options.fixtures) {
            var store = try storage.Store.open(s.io, a, s.cache_root, address, s.options);
            defer store.close();
            batch_remote.source = try s.fixtureProviderSource(a, &store);
        }
        var network: @import("gmail.zig").NetworkSession = undefined;
        if (!s.options.fixtures) {
            try network.init(s.io, a, &s.config, address, "mail.modify-labels", req);
            batch_remote.transport = network.transport();
        }
        defer if (!s.options.fixtures) network.close();
        const context: batch.Context = .{ .io = s.io, .allocator = s.allocator, .root = s.cache_root, .account = address, .options = s.options, .provider = .{ .context = &batch_remote, .labelsFn = BatchRemote.labelsFn, .modifyFn = BatchRemote.modifyFn, .fixtureCheckpoint = if (s.options.fixtures) fixtureCheckpoint(batch_remote.source) else null } };
        if (undoing) return batch.undo(context, a, req);
        // Resolve names before recording the inverse: receipts must contain
        // provider IDs, so renamed labels do not change what undo restores.
        if (s.options.fixtures) {
            for ([_][]const []const u8{ delta.add, delta.remove }, 0..) |values, list_index| {
                const resolved = try a.alloc([]const u8, values.len);
                for (values, resolved) |label, *id| id.* = try fixtureLabel(batch_remote.source, label);
                if (list_index == 0) delta.add = resolved else delta.remove = resolved;
            }
        } else delta = try @import("gmail.zig").resolveBatchLabels(a, batch_remote.transport.?, delta);
        for (delta.add) |added| for (delta.remove) |removed| if (std.mem.eql(u8, added, removed)) return error.ConflictingLabels;
        return batch.run(context, a, req, delta);
    }
    fn reopen(s: *Session, a: std.mem.Allocator, store: *storage.Store, expected: u64) !void {
        const account = store.state.account;
        store.close();
        // Keep defer close safe even if reopening fails after releasing the lock.
        store.lockHeld = false;
        store.* = try storage.Store.open(s.io, a, s.cache_root, account, s.options);
        if (store.state.generation != expected) return error.CacheChanged;
    }
    fn reopenBody(s: *Session, a: std.mem.Allocator, store: *storage.Store) !void {
        const account = store.state.account;
        store.close();
        store.* = try storage.Store.open(s.io, a, s.cache_root, account, s.options);
    }
    fn cacheStats(s: *Session, a: std.mem.Allocator, store: *storage.Store) !Value {
        const meter = if (s.meter) |m| m.snapshot() else null;
        return j.value(a, .{ .metadataEntries = store.state.entries.len, .metadataLimit = store.options.metadata_limit, .diskBytes = try store.diskBytes(), .diskLimitBytes = store.options.disk_limit, .bodyLimitBytes = t.Limits.body_bytes, .runtimeReservationBytes = t.Limits.runtime_bytes, .terminalHeapLimitBytes = t.Limits.runtime_bytes, .fixedBackendReservationBytes = @import("../limits.zig").app_reservation, .allocatorUsedBytes = if (meter) |m| m.allocatorUsedBytes else null, .allocatorPeakBytes = if (meter) |m| m.allocatorPeakBytes else null, .rejectedAllocations = if (meter) |m| m.rejectedAllocations else null, .fixtureCalls = store.state.fixtureCalls, .fixtureSends = store.state.fixtureSends, .fixtureProviderEntries = store.state.fixtureProvider.len, .fixtureProviderLimit = @as(usize, 1024), .refreshInProgress = try storage.refreshActive(s.io, s.cache_root, store.state.account, s.options), .historyId = store.state.historyId, .lastSyncAt = store.state.lastSyncAt, .syncCalls = store.state.syncCalls, .syncMetadataGets = store.state.syncMetadataGets, .syncListCalls = store.state.syncListCalls, .syncHistoryPages = store.state.syncHistoryPages, .syncBodyGets = store.state.syncBodyGets, .generation = store.state.generation });
    }
    fn cachedDispatch(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value) !Value {
        const cmd = j.text(req, "cmd");
        if (std.mem.eql(u8, cmd, "mail.recipients")) try s.capability(a, address, req, "mail-read");
        var store = try storage.Store.openCached(s.io, a, s.cache_root, address, s.options);
        defer store.close();
        if (std.mem.eql(u8, cmd, "mail.recipients")) {
            var known = @import("recipient_cache.zig").Builder.init(a, address);
            defer known.deinit();
            var aliases: [32][]const u8 = undefined;
            for (store.state.identities, 0..) |identity, index| aliases[index] = identity.address;
            known.self_aliases = aliases[0..store.state.identities.len];
            for (store.state.entries) |entry| {
                try s.io.checkCancel();
                try known.mail(entry.message);
            }
            for (store.state.outbox) |message| {
                try s.io.checkCancel();
                try known.mail(message);
            }
            const contacts_allowed = allowed: {
                s.capability(a, address, req, "contacts-read") catch break :allowed false;
                break :allowed true;
            };
            if (contacts_allowed) for (store.state.contacts) |contact| {
                try s.io.checkCancel();
                try known.contact(contact);
            };
            return j.value(a, .{ .recipients = try known.result(), .cached = true, .contactsIncluded = contacts_allowed });
        }
        if (std.mem.eql(u8, cmd, "cache.activity")) return j.value(a, .{ .inboxArrivalCount = store.state.inboxArrivalCount, .generation = store.state.generation, .lastSyncAt = store.state.lastSyncAt });
        if (std.mem.eql(u8, cmd, "mail.list")) return cachedList(a, &store, req);
        if (std.mem.eql(u8, cmd, "mail.search")) return cacheSearchEnv(a, &store, req, s.allocator, s.env);
        if (std.mem.eql(u8, cmd, "labels.list")) return s.loadLabels(a, &store, req, true);
        if (std.mem.eql(u8, cmd, "accounts.identities")) return s.identities(a, &store, req, true);
        if (std.mem.eql(u8, cmd, "cache.stats")) return s.cacheStats(a, &store);
        if (std.mem.eql(u8, cmd, "contacts.list") or std.mem.eql(u8, cmd, "contacts.search")) {
            try s.capability(a, address, req, "contacts-read");
            const query = j.text(req, "query");
            if (query.len > 4096) return error.InvalidQuery;
            var cached_contacts: std.ArrayList(t.Contact) = .empty;
            for (store.state.contacts) |contact| {
                var match = query.len == 0 or containsIgnoreCase(contact.name, query);
                for (contact.emails) |email| match = match or containsIgnoreCase(email.address, query);
                if (match) try cached_contacts.append(a, contact);
            }
            return j.value(a, .{ .contacts = cached_contacts.items, .cached = true, .cacheReady = store.state.contactsReady or store.state.contacts.len != 0 });
        }
        if (std.mem.eql(u8, cmd, "mail.read")) {
            const id = try j.required(req, "messageId");
            var message = (try store.read(id)) orelse if (s.options.fixtures) (try store.readOutbox(id)) orelse return error.CacheMiss else return error.CacheMiss;
            if (store.find(id)) |entry| {
                message.labels = entry.message.labels;
                message.unread = entry.message.unread;
            }
            message.bodyCached = true;
            return j.value(a, message);
        }
        if (std.mem.eql(u8, cmd, "mail.thread")) {
            const thread = try j.required(req, "threadId");
            var messages: std.ArrayList(t.Message) = .empty;
            for (store.state.entries) |entry| if (std.mem.eql(u8, entry.message.threadId, thread)) {
                if (try store.read(entry.message.id)) |cached| {
                    var message = cached;
                    message.labels = entry.message.labels;
                    message.unread = entry.message.unread;
                    message.bodyCached = true;
                    try messages.append(a, message);
                }
            };
            if (messages.items.len == 0) return error.CacheMiss;
            std.sort.heap(t.Message, messages.items, {}, olderFirst);
            return j.value(a, .{ .messages = messages.items, .cached = true, .partial = true });
        }
        return error.CacheUnsupported;
    }
    fn cacheSearch(a: std.mem.Allocator, store: *storage.Store, req: Value, body_allocator: std.mem.Allocator) !Value {
        return cacheSearchEnv(a, store, req, body_allocator, null);
    }
    fn cacheSearchEnv(a: std.mem.Allocator, store: *storage.Store, req: Value, body_allocator: std.mem.Allocator, env: ?*const std.process.Environ.Map) !Value {
        const limit = try j.integer(req, "limit", 32);
        if (limit < 1 or limit > 100) return error.InvalidPageLimit;
        const query = j.text(req, "query");
        const label = j.text(req, "label");
        if (query.len > 4096 or label.len > 256) return error.InvalidQuery;
        const plan = try cache_query.compile(query);
        const timezone = @import("timezone.zig");
        var empty_env = std.process.Environ.Map.init(a);
        defer empty_env.deinit();
        const zone: timezone.Zone = if (plan.needs_timezone) try timezone.load(store.io, a, env orelse &empty_env) else .{};
        const label_id = cachedLabel(store, label);
        var key = storage.Store.hash(try std.fmt.allocPrint(a, "cache-search\x00{s}\x00{s}\x00{s}", .{ store.state.account, query, label }));
        if (plan.needs_body) {
            // Body residency changes hit sets independently of metadata
            // generation. Bind pagination to that exact retained snapshot.
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&key);
            for (store.state.entries) |entry| {
                hasher.update(entry.message.id);
                hasher.update("\x00");
                hasher.update(entry.bodyHash);
                hasher.update("\x00");
                hasher.update(entry.bodyError);
                hasher.update("\x00");
            }
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            key = std.fmt.bytesToHex(digest, .lower);
        }
        var candidates: std.ArrayList(t.Message) = .empty;
        const SearchMatch = struct { messageId: []const u8, field: []const u8, offset: usize, length: usize, excerpt: []const u8 };
        var highlights: std.ArrayList(SearchMatch) = .empty;
        const term = cache_query.highlightTerm(query);
        for (store.state.entries) |entry| {
            try store.io.checkCancel();
            if (label_id.len != 0 and !hasLabel(entry.message, label_id)) continue;
            var body_arena = std.heap.ArenaAllocator.init(body_allocator);
            defer body_arena.deinit();
            // Each complete body is reclaimed before the next row. The result
            // holds metadata and a small literal excerpt, never whole bodies.
            var full = if (plan.needs_body) (try store.readWithAllocator(body_arena.allocator(), entry.message.id)) orelse entry.message else entry.message;
            if (entry.message.labels.len > 64) return error.InvalidLabels;
            var names: [128][]const u8 = undefined;
            var names_count: usize = 0;
            for (entry.message.labels) |id| {
                names[names_count] = id;
                names_count += 1;
                for (store.state.labels) |definition| if (std.mem.eql(u8, definition.id, id)) {
                    if (!std.mem.eql(u8, definition.name, id)) {
                        names[names_count] = definition.name;
                        names_count += 1;
                    }
                    break;
                };
            }
            full.labels = names[0..names_count];
            full.unread = entry.message.unread;
            if (!try plan.matches(full, &zone)) continue;
            var message = entry.message;
            message.bodyCacheError = entry.bodyError;
            try candidates.append(a, message);
            var field: []const u8 = "metadata";
            var source: []const u8 = message.subject;
            if (cache_query.find(full.bodyText, term) != null) {
                field = "body";
                source = full.bodyText;
            } else if (cache_query.find(message.subject, term) == null) {
                source = message.snippet;
                if (cache_query.find(source, term) == null) source = if (cache_query.find(message.from.name, term) != null) message.from.name else message.from.address;
            }
            const offset = cache_query.find(source, term) orelse 0;
            // A bounded UTF-8 excerpt starts at a codepoint boundary and never
            // exposes raw HTML/base64 or a second copy of the complete body.
            var start = offset -| 48;
            while (start < source.len and !std.unicode.utf8ValidateSlice(source[start..])) start += 1;
            const excerpt = utf8Prefix(source[start..], 192);
            try highlights.append(a, .{ .messageId = message.id, .field = field, .offset = offset - start, .length = if (cache_query.find(source, term) != null) @min(term.len, excerpt.len -| (offset - start)) else 0, .excerpt = try a.dupe(u8, excerpt) });
        }
        var offset: usize = 0;
        const cursor = j.text(req, "cursor");
        if (cursor.len != 0) {
            var parts = std.mem.splitScalar(u8, cursor, ':');
            if (!std.mem.eql(u8, parts.next() orelse "", "K")) return error.InvalidCursor;
            const generation = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch return error.InvalidCursor;
            offset = std.fmt.parseInt(usize, parts.next() orelse "", 10) catch return error.InvalidCursor;
            if (generation != store.state.generation or !std.mem.eql(u8, parts.next() orelse "", &key) or parts.next() != null) return error.InvalidCursor;
        }
        const anchor = j.text(req, "anchorMessageId");
        if (anchor.len != 0) for (candidates.items, 0..) |message, i| if (std.mem.eql(u8, message.id, anchor)) {
            offset = i / @as(usize, @intCast(limit)) * @as(usize, @intCast(limit));
            break;
        };
        if (offset > candidates.items.len) return error.InvalidCursor;
        const window = try adjacentCacheWindow(store, candidates.items, req, @intCast(limit), offset);
        offset = window.start;
        const end = window.end;
        for (candidates.items[offset..end]) |*message| message.bodyCached = try store.bodyAvailable(message.id);
        return j.value(a, .{ .cacheWindow = window.direction, .boundaryFallback = window.fallback, .hasMoreCachedBefore = offset != 0, .hasMoreCachedAfter = end < candidates.items.len, .messages = candidates.items[offset..end], .searchMatches = highlights.items[offset..end], .highlightTerm = term, .cursor = if (offset != 0) try std.fmt.allocPrint(a, "K:{d}:{d}:{s}", .{ store.state.generation, offset, key }) else @as(?[]const u8, null), .previousCursor = if (offset != 0) try std.fmt.allocPrint(a, "K:{d}:{d}:{s}", .{ store.state.generation, offset - @min(offset, @as(usize, @intCast(limit))), key }) else @as(?[]const u8, null), .nextCursor = if (end < candidates.items.len) try std.fmt.allocPrint(a, "K:{d}:{d}:{s}", .{ store.state.generation, end, key }) else @as(?[]const u8, null), .matchedCachedCount = candidates.items.len, .cached = true, .cacheReady = store.state.entries.len != 0 or store.state.historyId.len != 0, .partial = true, .searchMode = "cache", .searchScope = "metadata-and-cached-bodies", .generation = store.state.generation });
    }

    fn cachedList(a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        const limit = try j.integer(req, "limit", 32);
        if (limit < 1 or limit > 100) return error.InvalidPageLimit;
        const query = j.text(req, "query");
        const label = j.text(req, "label");
        if (query.len > 4096 or label.len > 256) return error.InvalidQuery;
        const key = try storage.Store.viewKey(a, store.state.account, query, label);
        const view = store.findView(&key);
        const label_id = if (view) |v| v.labelId else cachedLabel(store, label);
        var candidates: std.ArrayList(t.Message) = .empty;
        // Gmail search semantics are never guessed locally. Only an exact saved
        // query view contributes members, and stale membership is advertised.
        const ready = if (query.len != 0) view != null else store.state.entries.len != 0 or view != null or store.state.lastSyncAt != 0;
        if (ready) for (store.state.entries[0..@min(store.state.entries.len, store.options.metadata_limit)]) |entry| {
            if (query.len != 0) {
                var member = false;
                for (view.?.ids) |id| member = member or std.mem.eql(u8, id, entry.message.id);
                if (!member) continue;
            }
            if (label_id.len > 0 and !hasLabel(entry.message, label_id)) continue;
            if (label_id.len == 0 and query.len == 0 and (hasLabel(entry.message, "TRASH") or hasLabel(entry.message, "SPAM"))) continue;
            var message = entry.message;
            message.bodyCached = entry.bytes != 0;
            message.bodyCacheError = entry.bodyError;
            try candidates.append(a, message);
        };
        var offset: usize = 0;
        const cursor = j.text(req, "cursor");
        if (cursor.len > 0) {
            var parts = std.mem.splitScalar(u8, cursor, ':');
            if (!std.mem.eql(u8, parts.next() orelse "", "C")) return error.InvalidCursor;
            const generation = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch return error.InvalidCursor;
            offset = std.fmt.parseInt(usize, parts.next() orelse "", 10) catch return error.InvalidCursor;
            if (generation != store.state.generation or !std.mem.eql(u8, parts.next() orelse "", &key) or parts.next() != null) return error.InvalidCursor;
        }
        const anchor = j.text(req, "anchorMessageId");
        if (anchor.len != 0) for (candidates.items, 0..) |message, i| if (std.mem.eql(u8, message.id, anchor)) {
            offset = i / @as(usize, @intCast(limit)) * @as(usize, @intCast(limit));
            break;
        };
        if (offset > candidates.items.len) return error.InvalidCursor;
        const window = try adjacentCacheWindow(store, candidates.items, req, @intCast(limit), offset);
        offset = window.start;
        const end = window.end;
        for (candidates.items[offset..end]) |*message| message.bodyCached = try store.bodyAvailable(message.id);
        const remote_cursor = if (view) |v| if (!v.stale) v.remoteCursor else "" else "";
        const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(remote_cursor.len));
        _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, remote_cursor);
        return j.value(a, .{ .cacheWindow = window.direction, .boundaryFallback = window.fallback, .hasMoreCachedBefore = offset != 0, .hasMoreCachedAfter = end < candidates.items.len, .messages = candidates.items[offset..end], .cursor = if (offset > 0) try std.fmt.allocPrint(a, "C:{d}:{d}:{s}", .{ store.state.generation, offset, key }) else @as(?[]const u8, null), .nextCursor = if (end < candidates.items.len) try std.fmt.allocPrint(a, "C:{d}:{d}:{s}", .{ store.state.generation, end, key }) else @as(?[]const u8, null), .remoteCursor = if (remote_cursor.len != 0) try std.fmt.allocPrint(a, "L:{d}:{s}:{s}", .{ store.state.generation, key, encoded }) else @as(?[]const u8, null), .hasMoreRemote = remote_cursor.len != 0, .cached = true, .cacheReady = ready, .partial = true, .stale = if (view) |v| v.stale else false, .viewIncomplete = if (view) |v| v.incomplete else false, .lastSyncAt = if (view) |v| v.lastSyncAt else @as(i64, 0), .generation = store.state.generation, .inboxArrivalCount = store.state.inboxArrivalCount, .previousCursor = if (offset > 0) try std.fmt.allocPrint(a, "C:{d}:{d}:{s}", .{ store.state.generation, offset - @min(offset, @as(usize, @intCast(limit))), key }) else @as(?[]const u8, null) });
    }

    const FixtureRemote = struct {
        session: *Session,
        source: Value,
        metadata_requests: usize = 0,
        fn transport(self: *FixtureRemote) @import("gmail.zig").Transport {
            return .{ .context = self, .requestFn = request };
        }
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?Value) !Value {
            _ = body;
            if (method != .GET) return error.FixtureOnly;
            const self: *FixtureRemote = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, url, "?format=metadata") != null or std.mem.indexOf(u8, url, "?format=minimal") != null) {
                // The preceding request has completed and its progress was
                // reported before this next provider step can be held.
                try self.session.fixtureProgressGate(a, self.source, .metadata, self.metadata_requests);
                self.metadata_requests += 1;
            }
            const sync = j.get(self.source, "sync") orelse j.object(a);
            const checkpoint = if (j.text(sync, "historyId").len != 0) j.text(sync, "historyId") else "1";
            if (std.mem.indexOf(u8, url, "/labels?") != null) return j.value(a, .{ .labels = try fixtureLabelDefinitions(a, self.source) });
            if (std.mem.indexOf(u8, url, "/profile?") != null) return j.value(a, .{ .historyId = checkpoint, .emailAddress = j.text(self.source, "account") });
            if (std.mem.indexOf(u8, url, "/history?") != null) {
                const start = try parameter(a, url, "startHistoryId");
                if (std.mem.eql(u8, start, checkpoint)) return j.value(a, .{ .historyId = checkpoint, .history = @as([]const Value, &.{}) });
                if (try j.boolean(sync, "expired", false)) return error.MessageNotFound;
                if (j.get(sync, "historyPages")) |pages| {
                    const entries = try valueArray(pages);
                    const cursor = try parameter(a, url, "pageToken");
                    for (entries, 0..) |entry, i| {
                        if ((i == 0 and cursor.len == 0) or (i > 0 and std.mem.eql(u8, j.text(entries[i - 1], "nextPageToken"), cursor))) return entry;
                    }
                    return error.InvalidCursor;
                }
                return sync;
            }
            if (std.mem.indexOf(u8, url, "/messages?") != null) {
                const limit = std.fmt.parseInt(usize, try parameter(a, url, "maxResults"), 10) catch return error.InvalidPageLimit;
                const query = try parameter(a, url, "q");
                const label = try parameter(a, url, "labelIds");
                const cursor = try parameter(a, url, "pageToken");
                const offset = if (cursor.len != 0) std.fmt.parseInt(usize, cursor, 10) catch return error.InvalidCursor else 0;
                const Candidate = struct { raw: Value, received: i64 };
                var candidates: std.ArrayList(Candidate) = .empty;
                for (try array(self.source, "messages")) |raw| {
                    var wanted = label.len == 0;
                    var hidden = false;
                    for (try array(raw, "labelIds")) |v| {
                        const name = try j.string(v);
                        wanted = wanted or std.mem.eql(u8, name, label);
                        hidden = hidden or std.mem.eql(u8, name, "TRASH") or std.mem.eql(u8, name, "SPAM");
                    }
                    if (!wanted) continue;
                    if (label.len == 0 and query.len == 0 and hidden and !std.mem.eql(u8, try parameter(a, url, "includeSpamTrash"), "true")) continue;
                    if (query.len != 0 and !matches(try self.session.normalize(a, self.source, raw), query)) continue;
                    try candidates.append(a, .{ .raw = raw, .received = std.fmt.parseInt(i64, j.text(raw, "internalDate"), 10) catch return error.InvalidDate });
                }
                std.sort.heap(Candidate, candidates.items, {}, struct {
                    fn less(_: void, left: Candidate, right: Candidate) bool {
                        return left.received > right.received or (left.received == right.received and std.mem.lessThan(u8, j.text(left.raw, "id"), j.text(right.raw, "id")));
                    }
                }.less);
                if (offset > candidates.items.len) return error.InvalidCursor;
                const end = @min(candidates.items.len, offset + limit);
                var ids: std.ArrayList(Value) = .empty;
                for (candidates.items[offset..end]) |candidate| try ids.append(a, try j.value(a, .{ .id = j.text(candidate.raw, "id"), .threadId = j.text(candidate.raw, "threadId") }));
                return j.value(a, .{ .messages = ids.items, .nextPageToken = if (end < candidates.items.len) try std.fmt.allocPrint(a, "{d}", .{end}) else @as(?[]const u8, null) });
            }
            if (std.mem.indexOf(u8, url, "/attachments/")) |pos| {
                const id = url[pos + 13 ..];
                return j.get(j.get(self.source, "externalBodies") orelse return error.AttachmentNotFound, id) orelse error.AttachmentNotFound;
            }
            if (std.mem.indexOf(u8, url, "/messages/")) |pos| {
                const tail = url[pos + 10 ..];
                const end = std.mem.indexOfScalar(u8, tail, '?') orelse tail.len;
                const id = tail[0..end];
                for (try array(self.source, "messages")) |raw| if (std.mem.eql(u8, j.text(raw, "id"), id)) {
                    const format = try parameter(a, url, "format");
                    if (std.mem.eql(u8, format, "minimal")) return j.value(a, .{ .id = id, .labelIds = j.get(raw, "labelIds").? });
                    if (std.mem.eql(u8, format, "metadata")) {
                        const payload = j.get(raw, "payload") orelse return error.InvalidProviderResponse;
                        return j.value(a, .{ .id = id, .threadId = j.text(raw, "threadId"), .internalDate = j.text(raw, "internalDate"), .labelIds = j.get(raw, "labelIds").?, .snippet = j.text(raw, "snippet"), .payload = .{ .mimeType = j.text(payload, "mimeType"), .headers = j.get(payload, "headers") orelse return error.InvalidProviderResponse } });
                    }
                    return raw;
                };
                return error.MessageNotFound;
            }
            return error.UnsupportedCommand;
        }
        fn parameter(a: std.mem.Allocator, url: []const u8, name: []const u8) ![]const u8 {
            const pos = std.mem.indexOfScalar(u8, url, '?') orelse return "";
            var fields = std.mem.splitScalar(u8, url[pos + 1 ..], '&');
            while (fields.next()) |field| {
                const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
                if (!std.mem.eql(u8, field[0..equal], name)) continue;
                const raw = field[equal + 1 ..];
                const out = try a.alloc(u8, raw.len);
                var used: usize = 0;
                var i: usize = 0;
                while (i < raw.len) : (i += 1) {
                    if (raw[i] == '%') {
                        if (i + 2 >= raw.len) return error.InvalidUrl;
                        out[used] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidUrl;
                        i += 2;
                    } else out[used] = raw[i];
                    used += 1;
                }
                return out[0..used];
            }
            return "";
        }
    };
    fn fixtureGate(s: *Session, a: std.mem.Allocator, source: Value, req: Value) !void {
        const sync = j.get(source, "sync") orelse j.object(a);
        if (s.options.fixture_root) |root| {
            const hold = j.text(sync, "fixtureHold");
            const entered = j.text(sync, "fixtureEntered");
            if (hold.len != 0 or entered.len != 0) {
                for ([_][]const u8{ hold, entered }) |name| {
                    if (name.len == 0 or name.len > 64 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidFixtureControl;
                    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return error.InvalidFixtureControl;
                }
                const entered_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, entered });
                const file = try std.Io.Dir.cwd().createFile(s.io, entered_path, .{ .permissions = .fromMode(0o600), .truncate = true });
                file.close(s.io);
                const hold_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, hold });
                while (true) {
                    std.Io.Dir.cwd().access(s.io, hold_path, .{}) catch |err| {
                        if (err == error.FileNotFound) break;
                        return err;
                    };
                    try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(20) }).sleep(s.io);
                }
            }
        }
        const delay = try j.integer(req, "fixtureDelayMs", if (s.scenario("slow-refresh")) 2000 else 0);
        if (delay < 0 or delay > 30000) return error.InvalidFixtureDelay;
        if (delay != 0) try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(delay) }).sleep(s.io);
        if (s.scenario("offline-refresh")) return error.TransientFailure;
    }
    fn fixtureProgressGate(s: *Session, a: std.mem.Allocator, source: Value, phase: t.FetchPhase, completed: usize) !void {
        if (!s.options.fixtures) return;
        const sync = j.get(source, "sync") orelse return;
        const control = j.get(sync, "fixtureProgress") orelse return;
        const selected = std.meta.stringToEnum(t.FetchPhase, j.text(control, "phase")) orelse return error.InvalidFixtureControl;
        const count = try j.integer(control, "completed", 1);
        if (count < 0 or count > 100) return error.InvalidFixtureControl;
        if (phase != selected or completed != @as(usize, @intCast(count))) return;
        const root = s.options.fixture_root orelse return error.InvalidFixtureControl;
        const hold = j.text(control, "fixtureHold");
        const entered = j.text(control, "fixtureEntered");
        for ([_][]const u8{ hold, entered }) |name| {
            if (name.len == 0 or name.len > 64 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidFixtureControl;
            for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return error.InvalidFixtureControl;
        }
        const entered_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, entered });
        // Never truncate an existing fixture/reference file.
        const marker = std.Io.Dir.cwd().createFile(s.io, entered_path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| if (err == error.PathAlreadyExists) null else return err;
        if (marker) |file| file.close(s.io);
        const hold_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, hold });
        const deadline: std.Io.Clock.Timestamp = .fromNow(s.io, .{ .clock = .awake, .raw = .fromSeconds(15) });
        while (true) {
            try s.io.checkCancel();
            std.Io.Dir.cwd().access(s.io, hold_path, .{}) catch |err| {
                if (err == error.FileNotFound) break;
                return err;
            };
            if (deadline.durationFromNow(s.io).raw.toNanoseconds() <= 0) return error.Timeout;
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(20) }).sleep(s.io);
        }
    }
    fn refreshJob(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value) !Value {
        var request = try j.copyObject(a, req);
        const prefetch = try requestedPrefetch(s.options, request);
        try request.object.put(a, "prefetchLimit", .{ .integer = prefetch });
        const automatic = try j.boolean(request, "auto", false);
        const interval = try j.integer(request, "intervalSeconds", 300);
        if (interval < 60 or interval > 86400) return error.InvalidRefreshInterval;
        if (automatic) {
            const label = j.text(request, "label");
            if (j.text(request, "query").len != 0 or j.text(request, "cursor").len != 0 or (label.len != 0 and !std.ascii.eqlIgnoreCase(label, "INBOX"))) return error.InvalidAutomaticRefresh;
            const limit = try j.integer(request, "limit", 32);
            if (limit < 1 or limit > 100) return error.InvalidPageLimit;
            try request.object.put(a, "label", .{ .string = "INBOX" });
            try request.object.put(a, "limit", .{ .integer = limit });
            try request.object.put(a, "barGrantOnly", .{ .bool = true });
        }
        try s.capability(a, address, request, "mail-read");
        var lease = (try storage.RefreshLease.acquire(s.io, s.cache_root, address, s.options)) orelse {
            var snapshot = try storage.Store.openCached(s.io, a, s.cache_root, address, s.options);
            defer snapshot.close();
            var result = try cachedList(a, &snapshot, request);
            try result.object.put(a, "coalesced", .{ .bool = true });
            try result.object.put(a, "refreshInProgress", .{ .bool = true });
            try result.object.put(a, "refreshed", .{ .bool = false });
            return result;
        };
        defer lease.release();
        if (automatic) {
            var freshness_phase = std.heap.ArenaAllocator.init(s.allocator);
            defer freshness_phase.deinit();
            const fa = freshness_phase.allocator();
            var snapshot = try storage.Store.openCached(s.io, fa, s.cache_root, address, s.options);
            defer snapshot.close();
            if (try automaticFresh(fa, &snapshot, request, std.Io.Timestamp.now(s.io, .real).toMilliseconds(), interval)) {
                var result = try j.value(a, try cachedList(fa, &snapshot, request));
                try result.object.put(a, "coalesced", .{ .bool = true });
                try result.object.put(a, "refreshInProgress", .{ .bool = false });
                try result.object.put(a, "refreshed", .{ .bool = false });
                return result;
            }
        }
        const worker = try s.allocator.create(Session);
        defer s.allocator.destroy(worker);
        worker.* = s.*;
        if (automatic) worker.options.use_persisted_policy = true;
        var result = try worker.refreshOwned(a, address, request);
        try result.object.put(a, "coalesced", .{ .bool = false });
        try result.object.put(a, "refreshInProgress", .{ .bool = false });
        try result.object.put(a, "refreshed", .{ .bool = true });
        return result;
    }
    fn automaticFresh(a: std.mem.Allocator, store: *storage.Store, request: Value, now_ms: i64, interval: i64) !bool {
        if (store.state.historyId.len == 0) return false;
        const key = try storage.Store.viewKey(a, store.state.account, "", "INBOX");
        const view = store.findView(&key) orelse return false;
        if (view.stale or view.lastSyncStartedAt <= 0 or now_ms < view.lastSyncStartedAt or now_ms - view.lastSyncStartedAt >= @divTrunc(interval, 2) * 1000 or !std.mem.eql(u8, view.labelId, "INBOX")) return false;
        const page = try j.integer(request, "limit", 32);
        if (page < 1 or page > 100) return false;
        const limit = try j.integer(request, "prefetchLimit", @min(page, 32));
        if (limit < 0 or limit > 64) return false;
        if (limit == 0) return true;
        var found: usize = 0;
        for (store.state.entries) |entry| {
            if (!hasLabel(entry.message, "INBOX")) continue;
            if (entry.bytes == 0 and entry.bodyError.len == 0) return false;
            if (entry.bytes != 0) {
                const stat = store.dir.statFile(store.io, try store.fileName("mail", entry.message.id), .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return false else return err;
                if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0 or stat.size != entry.bytes) return false;
            }
            found += 1;
            if (found == limit) break;
        }
        return found == limit or view.remoteCursor.len == 0 or view.incomplete;
    }

    fn refreshOwned(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value) !Value {
        const started_at = std.Io.Timestamp.now(s.io, .real).toMilliseconds();
        try s.capability(a, address, req, "mail-read");
        var request = try j.copyObject(a, req);
        const prefetch = try requestedPrefetch(s.options, req);
        try request.object.put(a, "limit", .{ .integer = @max(try j.integer(req, "limit", 32), @max(1, prefetch)) });
        var expected: u64 = undefined;
        {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var trim = try storage.Store.open(s.io, phase.allocator(), s.cache_root, address, s.options);
            defer trim.close();
        }
        {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var snapshot = try storage.Store.openCached(s.io, phase.allocator(), s.cache_root, address, s.options);
            defer snapshot.close();
            expected = snapshot.state.generation;
            const key = try storage.Store.viewKey(a, address, j.text(req, "query"), j.text(req, "label"));
            const view = snapshot.findView(&key);
            const known = try a.alloc([]const u8, snapshot.state.entries.len);
            for (snapshot.state.entries, known) |entry, *id| id.* = try a.dupe(u8, entry.message.id);
            try request.object.put(a, "historyId", .{ .string = try a.dupe(u8, snapshot.state.historyId) });
            try request.object.put(a, "knownIds", try j.value(a, known));
            try request.object.put(a, "forceView", .{ .bool = (j.text(req, "query").len != 0 or j.text(req, "label").len != 0) and (view == null or view.?.stale) });
        }
        var fixture_remote: FixtureRemote = undefined;
        var live: @import("gmail.zig").NetworkSession = undefined;
        var transport = if (s.options.fixtures) fixture_transport: {
            const raw_source = try s.fixture(a, address);
            try s.fixtureGate(a, raw_source, req);
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            const pa = phase.allocator();
            var provider_store = try storage.Store.open(s.io, pa, s.cache_root, address, s.options);
            defer provider_store.close();
            if (provider_store.state.generation != expected) return error.CacheChanged;
            if (try reconcileFixtureSource(pa, &provider_store, raw_source)) {
                provider_store.state.generation += 1;
                for (provider_store.state.views) |*view| view.stale = true;
                try provider_store.save();
                expected = provider_store.state.generation;
            }
            const source = try overlayFixtureSource(a, &provider_store, raw_source);
            fixture_remote = .{ .session = s, .source = source };
            break :fixture_transport fixture_remote.transport();
        } else live_transport: {
            try live.init(s.io, a, &s.config, address, "mail.refresh", req);
            break :live_transport live.transport();
        };
        transport.progress_sink = s.progress_sink;
        defer if (!s.options.fixtures) live.close();
        const plan_value = try @import("gmail.zig").dispatchAuthorized(s.io, a, address, &.{"mail-read"}, transport, "mail.refresh", request);
        const plan = try j.decode(@import("gmail.zig").RefreshPlan, a, plan_value);
        const key = try storage.Store.viewKey(a, address, j.text(req, "query"), j.text(req, "label"));
        {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            const ca = phase.allocator();
            var commit = try storage.Store.open(s.io, ca, s.cache_root, address, s.options);
            defer commit.close();
            if (commit.state.generation != expected) return error.CacheChanged;
            if (plan.resync) {
                // Expired history cannot certify retained old rows. Replace only
                // cached mail, preserving drafts, receipts, contacts and outbox.
                var i = commit.state.entries.len;
                while (i > 0) {
                    i -= 1;
                    const id = commit.state.entries[i].message.id;
                    var retained = false;
                    for (plan.retentionIds) |wanted| retained = retained or std.mem.eql(u8, id, wanted);
                    if (!retained) try commit.invalidate(id);
                }
                // Retained IDs have immutable content: keep their full bytes and
                // hashes while metadata/labels update, even during resync.
                commit.state.views = &.{};
            }
            for (plan.deleted) |id| {
                if (s.options.fixtures) try commit.setFixtureRecord(id, &.{}, plan.historyId, true);
                try commit.invalidate(id);
            }
            for (plan.messages) |message| try commit.put(message, false);
            for (plan.labels) |update| commit.applyLabels(update.id, update.labels);
            if (plan.messages.len != 0 or plan.labels.len != 0 or plan.deleted.len != 0) for (commit.state.views) |*view| {
                view.stale = true;
            };
            if (plan.viewFetched) {
                var messages: std.ArrayList(t.Message) = .empty;
                for (plan.viewIds) |id| if (commit.find(id)) |entry| try messages.append(ca, entry.message);
                try commit.recordView(j.text(req, "query"), j.text(req, "label"), plan.labelId, messages.items, plan.nextCursor, false);
                for (plan.viewIds) |id| if (commit.find(id) == null) {
                    if (commit.findView(&key)) |view| view.incomplete = true;
                };
            }
            commit.state.syncCalls += 1;
            commit.state.syncMetadataGets += plan.metadataGets;
            commit.state.syncListCalls += plan.listCalls;
            commit.state.syncHistoryPages += plan.historyPages;
            if (plan.messages.len != 0 or plan.labels.len != 0 or plan.deleted.len != 0 or plan.viewFetched) commit.state.generation += 1;
            try commit.save();
            expected = commit.state.generation;
        }
        // Borrow only IDs across iterations. Full bodies and parse scratch are
        // reclaimed after every short atomic body/index commit, bounding memory.
        var ids: std.ArrayList([]const u8) = .empty;
        {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            const sa = phase.allocator();
            var snapshot = try storage.Store.openCached(s.io, sa, s.cache_root, address, s.options);
            defer snapshot.close();
            // The authoritative scoped metadata is committed before body
            // prefetch. Publish only this view, never the global retention
            // enumeration used to establish the account checkpoint.
            if (s.progress_sink) |sink| if (sink.rowFn != null) {
                var view_request = try j.copyObject(sa, req);
                try view_request.object.put(sa, "limit", .{ .integer = 32 });
                const view = try cachedList(sa, &snapshot, view_request);
                const rows = try array(view, "messages");
                for (rows, 0..) |row, index| sink.row(.{ .kind = .view, .index = index, .total = rows.len, .message = try j.decode(t.Message, sa, row) });
            };
            if (prefetch != 0) {
                var body_request = try j.copyObject(sa, req);
                try body_request.object.put(sa, "limit", .{ .integer = prefetch });
                const head = try cachedList(sa, &snapshot, body_request);
                for (try array(head, "messages")) |message| if (j.text(message, "bodyCacheError").len == 0) {
                    try s.io.checkCancel();
                    const id = try j.required(message, "id");
                    var verify = std.heap.ArenaAllocator.init(s.allocator);
                    defer verify.deinit();
                    if (try snapshot.readWithAllocator(verify.allocator(), id)) |_| continue;
                    try ids.append(a, try a.dupe(u8, id));
                };
            }
        }
        var body_total = ids.items.len;
        var body_completed: usize = 0;
        if (body_total != 0) s.reportProgress(.bodies, 0, body_total);
        for (ids.items) |id| {
            try s.io.checkCancel();
            var message_arena = std.heap.ArenaAllocator.init(s.allocator);
            defer message_arena.deinit();
            const ma = message_arena.allocator();
            {
                var check_phase = std.heap.ArenaAllocator.init(s.allocator);
                defer check_phase.deinit();
                var snapshot = try storage.Store.openCached(s.io, check_phase.allocator(), s.cache_root, address, s.options);
                defer snapshot.close();
                if (snapshot.state.generation != expected) return error.CacheChanged;
                const entry = snapshot.find(id) orelse {
                    body_total -= 1;
                    s.reportProgress(.bodies, body_completed, body_total);
                    continue;
                };
                // Byte pressure may have removed queued old-tail IDs; another
                // reader may already have cached a body. Never refetch either.
                if (entry.bodyError.len != 0 or (try snapshot.read(id)) != null) {
                    body_total -= 1;
                    s.reportProgress(.bodies, body_completed, body_total);
                    continue;
                }
            }
            var body_error: []const u8 = "";
            // Keep the validated typed message through its atomic cache commit.
            // A body with both HTML and plain fallback can be 4 MiB: serializing
            // and reparsing an intermediate DTO retains unnecessary arena copies.
            const body_result: ?t.Message = @import("gmail.zig").readAuthorizedMessage(ma, address, &.{"mail-read"}, transport, id) catch |err| refused: {
                if (err == error.MessageNotFound) {
                    body_error = "MessageNotFound";
                    break :refused null;
                }
                if (messageRefusal(err)) {
                    body_error = @errorName(err);
                    break :refused null;
                }
                return err;
            };
            var commit = try storage.Store.open(s.io, ma, s.cache_root, address, s.options);
            defer commit.close();
            if (commit.state.generation != expected) return error.CacheChanged;
            if (body_result) |message| {
                _ = commit.putBody(message) catch |err| refused_body: {
                    if (!messageRefusal(err)) return err;
                    if (commit.find(id)) |entry| entry.bodyError = @errorName(err);
                    break :refused_body false;
                };
            } else if (std.mem.eql(u8, body_error, "MessageNotFound")) {
                try commit.invalidate(id);
                commit.state.generation += 1;
            } else if (commit.find(id)) |entry| entry.bodyError = body_error;
            commit.state.syncBodyGets += 1;
            try commit.save();
            expected = commit.state.generation;
            commit.release();
            body_completed += 1;
            if (body_result) |message| s.reportRow(.{ .kind = .body, .message = message }) else s.reportRow(.{ .kind = .body, .failed = true, .message = .{ .id = id, .threadId = "" } });
            s.reportProgress(.bodies, body_completed, body_total);
            if (s.options.fixtures) try s.fixtureProgressGate(ma, fixture_remote.source, .bodies, body_completed);
        }
        var final_phase = std.heap.ArenaAllocator.init(s.allocator);
        defer final_phase.deinit();
        const fa = final_phase.allocator();
        var commit = try storage.Store.open(s.io, fa, s.cache_root, address, s.options);
        defer commit.close();
        if (commit.state.generation != expected) return error.CacheChanged;
        // This final synced index is the only checkpoint advancement. Failed or
        // cancelled partial jobs leave old history for replay, skipping full IDs.
        // Metadata and bodies may have committed before a canceled attempt.
        // Advance the arrival counter only with the successful history checkpoint;
        // replay still retains typed added IDs even when their metadata is known.
        if (!std.mem.eql(u8, commit.state.historyId, plan.historyId)) commit.state.inboxArrivalCount +|= @as(u64, @intCast(plan.inboxArrivals()));
        commit.state.historyId = plan.historyId;
        commit.state.lastSyncAt = std.Io.Timestamp.now(s.io, .real).toMilliseconds();
        if (commit.findView(&key)) |view| {
            view.lastSyncAt = commit.state.lastSyncAt;
            view.lastSyncStartedAt = started_at;
            view.stale = false;
        }
        try commit.save();
        var result = try j.value(a, try cachedList(fa, &commit, req));
        try result.object.put(a, "changed", .{ .integer = @intCast(plan.messages.len + plan.labels.len) });
        try result.object.put(a, "deleted", .{ .integer = @intCast(plan.deleted.len) });
        try result.object.put(a, "resync", .{ .bool = plan.resync });
        return result;
    }

    fn messageRefusal(err: anyerror) bool {
        return switch (err) {
            error.BodyTooLarge, error.DecodedMessageTooLarge, error.MessageTooLarge, error.ResponseTooLarge, error.UnsupportedCharset, error.TooManyMimeParts, error.MimeTooDeep, error.BodySizeMismatch, error.AmbiguousCalendarPart, error.AmbiguousHeader, error.AmbiguousSender, error.AttachmentsTooLarge, error.CapacityExceeded, error.ExternalBodyRequired, error.FilenameTooLarge, error.HeaderInjection, error.HeaderTooLarge, error.HeadersTooLarge, error.IncompleteMultipart, error.InvalidAttachmentFilename, error.InvalidAttachmentId, error.InvalidBase64, error.InvalidBody, error.InvalidCharsetData, error.InvalidDate, error.InvalidEncodedWord, error.InvalidHeaders, error.InvalidLabels, error.InvalidMessageId, error.InvalidMimeBoundary, error.InvalidMimeType, error.InvalidQuotedPrintable, error.InvalidUtf8, error.MissingHeaderBoundary, error.MissingMimeBoundary, error.MissingMimeType, error.ReferencesTooLarge, error.TooManyAttachments, error.TooManyHeaders, error.TooManyReferences, error.UnsupportedTransferEncoding, error.InvalidAddress, error.InvalidRecipients, error.RecipientHeaderTooLarge, error.RecipientTooLarge, error.TooManyIncomingRecipients, error.MalformedMessage => true,
            else => false,
        };
    }
    fn scenario(s: *Session, name: []const u8) bool {
        return std.mem.eql(u8, s.options.fixture_scenario, name);
    }
    fn capability(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value, name: []const u8) !void {
        if (try j.boolean(req, "barGrantOnly", false) or try j.boolean(req, "auto", false)) {
            if (!std.mem.eql(u8, name, "mail-read")) return error.PermissionDenied;
            return;
        }
        if (s.options.fixtures) {
            if (s.scenario("readonly") and !std.mem.eql(u8, name, "mail-read")) return error.PermissionDenied;
            return;
        }
        const registry = try @import("auth.zig").load(s.io, a, try j.required(req, "grantFile"));
        if (@import("auth.zig").find(&registry, address)) |grant| {
            if (!grant.permits(name)) return error.PermissionDenied;
        } else if (!std.mem.eql(u8, name, "mail-read")) return error.PermissionDenied;
    }
    fn remote(s: *Session, a: std.mem.Allocator, address: []const u8, cmd: []const u8, req: Value) !Value {
        return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeProgress, .{ s.io, a, &s.config, address, cmd, req, s.progress_sink });
    }
    fn fixture(s: *Session, a: std.mem.Allocator, address: []const u8) !Value {
        if (!s.options.fixtures) return error.LiveProviderNotReady;
        if (s.options.fixture_root) |root| {
            const key = if (std.mem.eql(u8, address, "personal@example.com")) "personal" else if (std.mem.eql(u8, address, "work@example.com")) "work" else if (std.mem.eql(u8, address, "optional@example.com")) "optional" else return error.FixtureAccountRequired;
            const path = try std.fmt.allocPrint(a, "{s}/accounts/{s}.json", .{ root, key });
            const raw = try std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(16 * 1024 * 1024));
            const source = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always, .max_value_len = t.Limits.request_bytes });
            if (!std.mem.eql(u8, j.text(source, "account"), address)) return error.FixtureIdentityMismatch;
            return source;
        }
        // Complete fictional fixtures are shipped in development. Built-in
        // fixtures keep installed bundles useful without a tests directory.
        var messages: std.ArrayList(Value) = .empty;
        var i: usize = 96;
        while (i > 0) : (i -= 1) {
            const id = try std.fmt.allocPrint(a, "demo-{d}", .{i});
            const body = try std.fmt.allocPrint(a, "Hello from {s}!\n\nA complete synthetic message, with café and emoji 🌋.\n", .{address});
            const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(body.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, body);
            const account_key = storage.Store.hash(address);
            var payload = try j.value(a, .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "Alex Fixture <alex@example.org>" }, .{ .name = "To", .value = address }, .{ .name = "Subject", .value = try std.fmt.allocPrint(a, "{s}: synthetic thread {d} 🌋", .{ address, (i - 1) / 3 }) }, .{ .name = "Message-ID", .value = try std.fmt.allocPrint(a, "<demo-{d}-{s}@example.org>", .{ i, account_key[0..12] }) } }, .body = .{ .size = body.len, .data = encoded } });
            if (i == 3 or i == 8) {
                var parts: j.Value = .{ .array = .init(a) };
                try parts.array.append(payload);
                const content = if (i == 3) "Synthetic attachment: flowing magma 🌋\n" else try std.fmt.allocPrint(a, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//omagma//Synthetic//EN\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:demo-magma-meeting@example.org\r\nSEQUENCE:2\r\nDTSTAMP:20261004T120000Z\r\nDTSTART:20261107T100000Z\r\nSUMMARY:Demo magma meeting 🌋\r\nORGANIZER:mailto:organizer@example.org\r\nATTENDEE;RSVP=TRUE:mailto:{s}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", .{address});
                const data = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(content.len));
                _ = std.base64.url_safe_no_pad.Encoder.encode(data, content);
                try parts.array.append(try j.value(a, .{ .partId = "demo-part-1", .mimeType = if (i == 3) "text/plain" else "text/calendar", .filename = if (i == 3) "demo-magma.txt" else "", .body = .{ .size = content.len, .data = data } }));
                const headers = j.get(payload, "headers").?;
                payload = try j.value(a, .{ .mimeType = "multipart/mixed", .headers = headers, .parts = parts });
            }
            try messages.append(a, try j.value(a, .{ .id = id, .threadId = try std.fmt.allocPrint(a, "demo-thread-{d}", .{(i - 1) / 3}), .internalDate = try std.fmt.allocPrint(a, "{d}", .{1791100800000 + i * 60000}), .labelIds = [_][]const u8{ "INBOX", "UNREAD" }, .snippet = body, .payload = payload }));
        }
        return j.value(a, .{ .account = address, .messages = messages.items });
    }
    fn fixtureCheckpoint(source: Value) []const u8 {
        const sync = j.get(source, "sync") orelse return "1";
        const checkpoint = j.text(sync, "historyId");
        return if (checkpoint.len != 0) checkpoint else "1";
    }
    fn newerCheckpoint(left: []const u8, right: []const u8) bool {
        const l = std.mem.trimStart(u8, left, "0");
        const r = std.mem.trimStart(u8, right, "0");
        return l.len > r.len or (l.len == r.len and std.mem.order(u8, l, r) == .gt);
    }
    fn rawFixtureMessage(source: Value, id: []const u8) !?Value {
        for (try array(source, "messages")) |raw| if (std.mem.eql(u8, j.text(raw, "id"), id)) return raw;
        return null;
    }
    fn fixtureLabels(a: std.mem.Allocator, raw: Value) ![]const []const u8 {
        const labels = if (j.get(raw, "labelIds")) |value| try j.decode([]const []const u8, a, value) else &.{};
        if (labels.len > 64) return error.InvalidLabels;
        for (labels) |label| {
            if (label.len > 256) return error.InvalidLabels;
            try recipients.validateHeader(label);
        }
        return labels;
    }
    fn fixtureRevision(revision: []const u8) !void {
        if (revision.len == 0 or revision.len > 32) return error.InvalidFixtureProviderState;
        for (revision) |c| if (!std.ascii.isDigit(c)) return error.InvalidFixtureProviderState;
    }
    fn reconcileFixtureSource(a: std.mem.Allocator, store: *storage.Store, source: Value) !bool {
        if (store.state.fixtureProvider.len == 0) return false;
        const sync = j.get(source, "sync") orelse return false;
        const current = fixtureCheckpoint(source);
        try fixtureRevision(current);
        var pages: std.ArrayList(Value) = .empty;
        if (j.get(sync, "historyPages")) |items| try pages.appendSlice(a, try valueArray(items)) else try pages.append(a, sync);
        var changed = false;
        var i: usize = 0;
        while (i < store.state.fixtureProvider.len) {
            const record = store.state.fixtureProvider[i];
            var checkpoint = record.sourceHistoryId;
            var touched = false;
            var deleted = record.deleted;
            var events: usize = 0;
            var incomplete = pages.items.len > 8;
            for (pages.items[0..@min(pages.items.len, 8)]) |page| {
                const histories = try optionalArray(page, "history");
                if (histories.len > 100) incomplete = true;
                for (histories[0..@min(histories.len, 100)]) |history| {
                    const revision = j.text(history, "id");
                    try fixtureRevision(revision);
                    if (!newerCheckpoint(revision, record.sourceHistoryId) or newerCheckpoint(checkpoint, revision)) continue;
                    for ([_][]const u8{ "messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved" }) |kind| for (try optionalArray(history, kind)) |event| {
                        events += 1;
                        if (events > 256) {
                            incomplete = true;
                            break;
                        }
                        const message = j.get(event, "message") orelse return error.InvalidProviderResponse;
                        if (!std.mem.eql(u8, j.text(message, "id"), record.id)) continue;
                        touched = true;
                        if (std.mem.eql(u8, kind, "messagesDeleted")) deleted = true else if (std.mem.eql(u8, kind, "messagesAdded")) deleted = false;
                        checkpoint = revision;
                    };
                }
            }
            // An explicit newer expired/full-snapshot fixture is authoritative
            // when typed history is unavailable or exceeds its bounded budget.
            if ((incomplete or try j.boolean(sync, "expired", false)) and newerCheckpoint(current, record.sourceHistoryId)) {
                touched = true;
                checkpoint = current;
                deleted = (try rawFixtureMessage(source, record.id)) == null;
            }
            if (!touched) {
                i += 1;
                continue;
            }
            changed = true;
            if (deleted) {
                try store.setFixtureRecord(record.id, &.{}, checkpoint, true);
                try store.invalidate(record.id);
                i += 1;
            } else {
                if (try rawFixtureMessage(source, record.id)) |raw| {
                    const labels = try fixtureLabels(a, raw);
                    store.applyLabels(record.id, labels);
                }
                store.clearFixtureRecord(record.id);
            }
        }
        return changed;
    }
    fn overlayFixtureSource(a: std.mem.Allocator, store: *storage.Store, source: Value) !Value {
        if (store.state.fixtureProvider.len == 0 and !store.state.fixtureLabelsReady) return source;
        var out = try j.copyObject(a, source);
        if (store.state.fixtureLabelsReady) try out.object.put(a, "labels", try j.value(a, store.state.labels));
        var messages: Value = .{ .array = .init(a) };
        for (try array(source, "messages")) |raw| {
            var message = raw;
            if (store.fixtureRecord(j.text(raw, "id"))) |record| {
                if (record.deleted) continue;
                message = try j.copyObject(a, raw);
                try message.object.put(a, "labelIds", try j.value(a, record.labels));
            }
            if (store.state.fixtureDeletedLabels.len != 0) {
                var retained: std.ArrayList([]const u8) = .empty;
                var changed = false;
                for (try fixtureLabels(a, message)) |id| {
                    var deleted = false;
                    for (store.state.fixtureDeletedLabels) |removed| deleted = deleted or std.mem.eql(u8, id, removed);
                    if (deleted) changed = true else try retained.append(a, id);
                }
                if (changed) {
                    message = try j.copyObject(a, message);
                    try message.object.put(a, "labelIds", try j.value(a, retained.items));
                }
            }
            try messages.array.append(message);
        }
        try out.object.put(a, "messages", messages);
        return out;
    }
    fn fixtureProviderSource(s: *Session, a: std.mem.Allocator, store: *storage.Store) !Value {
        const source = try s.fixture(a, store.state.account);
        try s.ensureFixtureLabels(a, store, source);
        if (try reconcileFixtureSource(a, store, source)) {
            store.state.generation += 1;
            for (store.state.views) |*view| view.stale = true;
            try store.save();
        }
        return overlayFixtureSource(a, store, source);
    }

    fn normalize(_: *Session, a: std.mem.Allocator, source: Value, v: Value) !t.Message {
        return @import("gmail_decode.zig").normalize(v, a, j.get(source, "externalBodies"));
    }
    fn read(s: *Session, a: std.mem.Allocator, store: *storage.Store, id: []const u8, req: Value) !t.Message {
        return s.readMessage(a, store, id, req, true);
    }
    fn captureOriginal(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, message: t.Message) !t.Original {
        const html = message.bodyHtml orelse return error.OriginalHtmlUnavailable;
        if (html.len == 0) return error.OriginalHtmlUnavailable;
        if (message.bodyHtmlAmbiguous) return error.AmbiguousOriginalHtml;
        const usage = try @import("original_mail.zig").resourceUsage(html, message.attachments);
        var resources: std.ArrayList(t.Attachment) = .empty;
        var bytes: usize = 0;
        for (message.attachments, 0..) |attachment, index| {
            const is_file = if (attachment.disposition) |value| std.ascii.eqlIgnoreCase(value, "attachment") else false;
            const referenced = usage & (@as(u64, 1) << @as(u6, @intCast(index))) != 0;
            const has_identity = attachment.contentId != null or attachment.contentLocation != null;
            if (!has_identity or (is_file and !referenced and attachment.contentLocation == null)) continue;
            if (resources.items.len == t.Limits.related_resources) return error.TooManyAttachments;
            bytes = std.math.add(usize, bytes, attachment.size) catch return error.AttachmentsTooLarge;
            if (bytes > t.Limits.body_bytes) return error.AttachmentsTooLarge;
            if (attachment.contentId) |id| {
                _ = try @import("mime.zig").contentId(id);
                for (resources.items) |previous| if (previous.contentId) |other| if (std.mem.eql(u8, id, other)) return error.AmbiguousContentId;
            }
            try resources.append(a, attachment);
        }
        for (resources.items) |*attachment| if (attachment.data.len == 0 and attachment.size != 0) {
            var request = try j.copyObject(a, req);
            try request.object.put(a, "attachmentId", .{ .string = attachment.id });
            attachment.* = try s.fetchKnownAttachment(a, store, request, message);
        };
        const snapshot: t.Original = .{ .sourceMessageId = message.id, .from = message.from, .to = message.to, .cc = message.cc, .subject = message.subject, .date = message.sentDate orelse "", .bodyText = message.bodyText, .bodyHtml = html, .resources = resources.items };
        try @import("original_mail.zig").validate(snapshot);
        return snapshot;
    }
    fn forwardRaw(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, format: t.BodyFormat) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        const id = try j.required(req, "messageId");
        const raw = if (s.options.fixtures) blk: {
            const source = try s.fixtureProviderSource(a, store);
            for (try array(source, "messages")) |message| if (std.mem.eql(u8, j.text(message, "id"), id)) {
                const bytes = try @import("gmail.zig").decodeRawMessage(a, message, id);
                store.state.fixtureCalls += 1;
                break :blk bytes;
            };
            return error.MessageNotFound;
        } else blk: {
            const account = store.state.account;
            store.release();
            const bytes = try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeRawMessage, .{ s.io, a, &s.config, account, req, s.progress_sink });
            try s.reopenBody(a, store);
            break :blk bytes;
        };
        const source = try @import("mime.zig").originalSource(a, raw);
        const draft: t.Draft = .{ .subject = if (std.ascii.startsWithIgnoreCase(source.subject, "Fwd:")) source.subject else try std.fmt.allocPrint(a, "Fwd: {s}", .{source.subject}), .bodyFormat = format, .attachments = &.{source.attachment} };
        try validateDraft(draft, false);
        return j.value(a, try store.putDraft(draft, null));
    }
    fn fetchKnownAttachment(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, known_message: ?t.Message) !t.Attachment {
        try s.capability(a, store.state.account, req, "mail-read");
        const message_id = try j.required(req, "messageId");
        const attachment_id = try j.required(req, "attachmentId");
        const message = known_message orelse try s.read(a, store, message_id, req);
        if (!std.mem.eql(u8, message.id, message_id)) return error.MessageIdentityMismatch;
        for (message.attachments) |selected| if (std.mem.eql(u8, selected.id, attachment_id)) {
            if (selected.blobId != null) return selected;
            if (selected.data.len > 0 or selected.size == 0) return selected;
            if (s.options.fixtures) return error.AttachmentNotFound;
            const account = store.state.account;
            if (selected.size > t.Limits.body_bytes) {
                var incoming = try @import("attachment_blob.zig").Incoming.create(store, selected.size);
                defer incoming.close();
                var buffer: [64 * 1024]u8 = undefined;
                var writer = incoming.file.writer(s.io, &buffer);
                store.release();
                const downloaded = try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeAttachmentToWriter, .{ s.io, a, &s.config, account, req, selected, &writer.interface });
                try writer.flush();
                try s.reopenBody(a, store);
                return incoming.commit(store, downloaded);
            }
            store.release();
            const downloaded = try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeAttachment, .{ s.io, a, &s.config, account, req, selected, s.progress_sink });
            try s.reopenBody(a, store);
            return downloaded;
        };
        return error.AttachmentNotFound;
    }
    fn saveKnownAttachment(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        const message_id = try j.required(req, "messageId");
        const attachment_id = try j.required(req, "attachmentId");
        const path = try j.required(req, "path");
        if (path.len == 0 or path.len > 4096 or !@import("file_dialog.zig").validText(path)) return error.InvalidAttachmentPath;
        const leaf = std.fs.path.basename(path);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidAttachmentPath;
        const message = try s.read(a, store, message_id, req);
        var selected: ?t.Attachment = null;
        for (message.attachments) |attachment| if (std.mem.eql(u8, attachment.id, attachment_id)) {
            selected = attachment;
            break;
        };
        const attachment = selected orelse return error.AttachmentNotFound;
        if (attachment.size > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
        var directory = try @import("path_completion.zig").openDirectory(s.io, std.fs.path.dirname(path) orelse ".", false);
        defer directory.close(s.io);
        var destination = try directory.createFileAtomic(s.io, leaf, .{ .permissions = .fromMode(0o600), .replace = false });
        defer destination.deinit(s.io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = destination.file.writer(s.io, &buffer);
        if (attachment.blobId != null) {
            var source = try @import("attachment_blob.zig").Stream.init(store, attachment);
            defer source.close();
            var chunk: [64 * 1024]u8 = undefined;
            while (true) {
                const count = try @import("attachment_blob.zig").Stream.read(&source, &chunk);
                if (count == 0) break;
                try writer.interface.writeAll(chunk[0..count]);
            }
        } else if (attachment.data.len > 0 or attachment.size == 0) {
            const decoded = try @import("mime.zig").decodeBase64Url(attachment.data, a);
            if (decoded.len != attachment.size) return error.BodySizeMismatch;
            try writer.interface.writeAll(decoded);
        } else {
            if (s.options.fixtures) return error.AttachmentNotFound;
            const account = store.state.account;
            store.release();
            _ = try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeAttachmentToWriter, .{ s.io, a, &s.config, account, req, attachment, &writer.interface });
        }
        try writer.flush();
        try destination.file.sync(s.io);
        try destination.link(s.io);
        return j.value(a, .{ .saved = true, .path = path, .filename = attachment.filename, .size = attachment.size });
    }
    fn readMessage(s: *Session, a: std.mem.Allocator, store: *storage.Store, id: []const u8, req: Value, allow_cached: bool) !t.Message {
        try s.capability(a, store.state.account, req, "mail-read");
        if (s.options.fixtures) {
            if (try store.readOutbox(id)) |sent| return sent;
            if (store.state.fixtureProvider.len != 0) _ = try s.fixtureProviderSource(a, store);
        }
        if (if (allow_cached) try store.read(id) else null) |cached| {
            var m = cached;
            if (store.find(id)) |entry| {
                m.labels = entry.message.labels;
                m.unread = entry.message.unread;
            }
            if (s.options.fixtures) try store.applyFixtureRecord(&m);
            return m;
        }
        if (!s.options.fixtures) {
            const expected = store.state.generation;
            const account = store.state.account;
            store.release();
            var m = try j.decode(t.Message, a, try s.remote(a, account, "mail.read", req));
            try s.reopenBody(a, store);
            if (!allow_cached) _ = try store.upgradeInvitation(m);
            if (store.state.generation == expected) try store.put(m, true) else {
                _ = try store.putBody(m);
                if (store.find(m.id)) |entry| {
                    m.labels = entry.message.labels;
                    m.unread = entry.message.unread;
                }
            }
            try store.save();
            return m;
        }
        const source = try s.fixtureProviderSource(a, store);
        for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "id"), id)) {
            s.reportProgress(.bodies, 0, 1);
            try s.fixtureProgressGate(a, source, .bodies, 0);
            var m = try s.normalize(a, source, v);
            if (store.find(id)) |existing| {
                m.labels = existing.message.labels;
                m.unread = existing.message.unread;
            }
            store.state.fixtureCalls += 1;
            if (!allow_cached) _ = try store.upgradeInvitation(m);
            try store.put(m, true);
            try store.save();
            s.reportRow(.{ .kind = .body, .message = m });
            s.reportProgress(.bodies, 1, 1);
            return m;
        };
        return error.MessageNotFound;
    }
    fn listMail(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        if (!s.options.fixtures) return s.liveList(a, store, req);
        const limit = try j.integer(req, "limit", 30);
        if (limit < 1 or limit > t.Limits.page) return error.InvalidPageLimit;
        const query = j.text(req, "query");
        const label = j.text(req, "label");
        if (query.len > 4096 or label.len > 256) return error.InvalidQuery;
        const filter = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ store.state.account, query, label });
        const key = storage.Store.hash(filter);
        const cursor = j.text(req, "cursor");
        var offset: usize = 0;
        if (cursor.len > 0) {
            var parts = std.mem.splitScalar(u8, cursor, ':');
            const version = parts.next() orelse return error.InvalidCursor;
            const generation = parts.next() orelse return error.InvalidCursor;
            const third = parts.next() orelse return error.InvalidCursor;
            const fourth = parts.next() orelse return error.InvalidCursor;
            if (parts.next() != null or (std.fmt.parseInt(u64, generation, 10) catch return error.InvalidCursor) != store.state.generation) return error.InvalidCursor;
            if (std.mem.eql(u8, version, "1")) {
                if (!std.mem.eql(u8, fourth, &key)) return error.InvalidCursor;
                offset = std.fmt.parseInt(usize, third, 10) catch return error.InvalidCursor;
            } else if (std.mem.eql(u8, version, "L")) {
                if (!std.mem.eql(u8, third, &key)) return error.InvalidCursor;
                const n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(fourth) catch return error.InvalidCursor;
                if (n > 4096) return error.InvalidCursor;
                const decoded = try a.alloc(u8, n);
                std.base64.url_safe_no_pad.Decoder.decode(decoded, fourth) catch return error.InvalidCursor;
                offset = std.fmt.parseInt(usize, decoded, 10) catch return error.InvalidCursor;
            } else return error.InvalidCursor;
        }
        const source = try s.fixtureProviderSource(a, store);
        const label_id = try fixtureLabel(source, label);
        var messages: std.ArrayList(t.Message) = .empty;
        var matched: usize = 0;
        var next: bool = false;
        var candidates: std.ArrayList(t.Message) = .empty;
        for (try array(source, "messages")) |v| {
            var m = try s.normalize(a, source, v);
            if (store.find(m.id)) |e| {
                m.labels = e.message.labels;
                m.unread = e.message.unread;
            }
            try candidates.append(a, m);
        }
        try candidates.appendSlice(a, store.state.outbox);
        std.mem.sort(t.Message, candidates.items, {}, newerFirst);
        var eligible: usize = 0;
        for (candidates.items) |message| {
            if (label_id.len > 0 and !hasLabel(message, label_id)) continue;
            if (label.len == 0 and query.len == 0 and hasLabel(message, "TRASH")) continue;
            if (query.len > 0 and !matches(message, query)) continue;
            eligible += 1;
        }
        const page_total = @min(eligible -| offset, @as(usize, @intCast(limit)));
        if (page_total != 0) s.reportProgress(.metadata, 0, page_total);
        for (candidates.items) |message| {
            var m = message;
            if (label_id.len > 0 and !hasLabel(m, label_id)) continue;
            if (label.len == 0 and query.len == 0 and hasLabel(m, "TRASH")) continue;
            if (query.len > 0 and !matches(m, query)) continue;
            matched += 1;
            if (matched <= offset) continue;
            if (messages.items.len == limit) {
                next = true;
                break;
            }
            try store.put(m, false);
            m.bodyText = "";
            m.bodyHtml = null;
            m.bodySource = .unknown;
            m.invitation = null;
            m.attachments = &.{};
            try messages.append(a, m);
            s.reportRow(.{ .kind = .page, .index = messages.items.len - 1, .total = page_total, .message = m });
            s.reportProgress(.metadata, messages.items.len, page_total);
            try s.fixtureProgressGate(a, source, .metadata, messages.items.len);
        }
        if (offset > matched) return error.InvalidCursor;
        store.state.fixtureCalls += 1;
        const saved_cursor = if (next) try std.fmt.allocPrint(a, "{d}", .{offset + messages.items.len}) else "";
        try store.recordView(query, label, label_id, messages.items, saved_cursor, cursor.len != 0);
        try store.save();
        return j.value(a, .{ .messages = messages.items, .nextCursor = if (next) try std.fmt.allocPrint(a, "1:{d}:{d}:{s}", .{ store.state.generation, offset + messages.items.len, key }) else @as(?[]const u8, null) });
    }
    fn liveList(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        const query = j.text(req, "query");
        const label = j.text(req, "label");
        const filter = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ store.state.account, query, label });
        const key = storage.Store.hash(filter);
        var request = try j.copyObject(a, req);
        const cursor = j.text(req, "cursor");
        if (cursor.len > 0) {
            var parts = std.mem.splitScalar(u8, cursor, ':');
            const version = parts.next() orelse return error.InvalidCursor;
            const generation = parts.next() orelse return error.InvalidCursor;
            const digest = parts.next() orelse return error.InvalidCursor;
            const payload = parts.next() orelse return error.InvalidCursor;
            if (!std.mem.eql(u8, version, "L") or parts.next() != null or !std.mem.eql(u8, digest, &key) or (std.fmt.parseInt(u64, generation, 10) catch return error.InvalidCursor) != store.state.generation) return error.InvalidCursor;
            const n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return error.InvalidCursor;
            if (n > 4096) return error.InvalidCursor;
            const decoded = try a.alloc(u8, n);
            std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return error.InvalidCursor;
            try request.object.put(a, "cursor", .{ .string = decoded });
        }
        const expected = store.state.generation;
        const account = store.state.account;
        store.release();
        var result = try s.remote(a, account, try j.required(req, "cmd"), request);
        try s.reopen(a, store, expected);
        const messages = try j.decode([]const t.Message, a, j.get(result, "messages") orelse return error.InvalidProviderResponse);
        for (messages) |message| try store.put(message, false);
        try store.recordView(query, label, j.text(result, "labelId"), messages, j.text(result, "nextCursor"), cursor.len != 0);
        const remote_cursor = j.text(result, "nextCursor");
        if (remote_cursor.len > 0) {
            if (remote_cursor.len > 4096) return error.InvalidCursor;
            const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(remote_cursor.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, remote_cursor);
            try result.object.put(a, "nextCursor", .{ .string = try std.fmt.allocPrint(a, "L:{d}:{s}:{s}", .{ store.state.generation, key, encoded }) });
        }
        try store.save();
        return result;
    }
    fn contacts(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, cmd: []const u8) !Value {
        const write = std.mem.eql(u8, cmd, "contacts.upsert");
        try s.capability(a, store.state.account, req, if (write) "contacts-write" else "contacts-read");
        if (!s.options.fixtures) {
            if (write) {
                store.state.contacts = &.{};
                store.state.contactsReady = false;
                try store.save();
            }
            const result = try s.remote(a, store.state.account, cmd, req);
            // Provider writes already validate the contact receipt. Return it
            // directly; refresh the invalidated cache on the next contacts read
            // rather than risking a cache failure after a successful create.
            if (write) return result;
            store.state.contacts = try j.decode([]t.Contact, a, j.get(result, "contacts") orelse return error.InvalidProviderResponse);
            store.state.contactsReady = true;
            try store.save();
            return result;
        }
        if (store.state.contacts.len == 0 and !store.state.contactsReady) {
            if (s.options.fixture_root) |root| {
                const key = if (std.mem.eql(u8, store.state.account, "personal@example.com")) "personal" else if (std.mem.eql(u8, store.state.account, "work@example.com")) "work" else "optional";
                const raw = try std.Io.Dir.cwd().readFileAlloc(s.io, try std.fmt.allocPrint(a, "{s}/contacts/{s}.json", .{ root, key }), a, .limited(4 * 1024 * 1024));
                const source = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
                var list: std.ArrayList(t.Contact) = .empty;
                for (try array(source, "connections")) |v| try list.append(a, try @import("contact_record.zig").normalize(a, v));
                store.state.contacts = list.items;
            } else store.state.contacts = try a.dupe(t.Contact, &.{.{ .resourceName = "people/demo-alex", .etag = "demo-1", .name = "Alex Fixture", .emails = &.{.{ .address = "alex@example.org" }} }});
            store.state.contactsReady = true;
            store.state.fixtureCalls += 1;
            try store.save();
        }
        if (!write) {
            const query = j.text(req, "query");
            var contacts_list: std.ArrayList(t.Contact) = .empty;
            for (store.state.contacts) |contact| {
                var match = query.len == 0 or containsIgnoreCase(contact.name, query);
                for (contact.emails) |email| match = match or containsIgnoreCase(email.address, query);
                if (match) try contacts_list.append(a, contact);
            }
            return j.value(a, .{ .contacts = contacts_list.items });
        }
        if (s.scenario("rejected-mutation")) return error.ProviderRejected;
        const v = j.get(req, "contact") orelse return error.MissingField;
        for ([_][]const u8{ "resourceName", "etag", "name" }) |key| if (j.get(v, key)) |field| {
            if (field != .string) return error.InvalidRequest;
        };
        var pos: ?usize = null;
        for (store.state.contacts, 0..) |old, i| if (std.mem.eql(u8, old.resourceName, j.text(v, "resourceName"))) {
            pos = i;
            break;
        };
        var clean = try j.copyObject(a, v);
        if (j.get(v, "emails")) |emails| try clean.object.put(a, "emails", try j.value(a, try decodeAddresses(a, emails)));
        const previous: ?t.Contact = if (pos) |i| store.state.contacts[i] else null;
        var c = try @import("contact_record.zig").mergeInput(a, clean, previous);
        if (pos) |i| {
            const expected = j.text(req, "expectedEtag");
            if (!std.mem.eql(u8, if (expected.len > 0) expected else c.etag, store.state.contacts[i].etag)) return error.ContactConflict;
        } else {
            if (c.resourceName.len > 0) return error.ContactNotFound;
            if (store.state.contacts.len == 1024) return error.ContactLimitExceeded;
            c.resourceName = try store.nextId("people/contact");
        }
        c.etag = try store.nextId("contact-version");
        c.provider = try @import("contact_record.zig").providerBody(a, c, previous);
        if (pos) |i| store.state.contacts[i] = c else {
            var list: std.ArrayList(t.Contact) = .empty;
            try list.appendSlice(a, store.state.contacts);
            try list.append(a, c);
            store.state.contacts = list.items;
        }
        store.state.fixtureCalls += 1;
        try store.save();
        return j.value(a, c);
    }
    fn queuedSend(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        const cmd = j.text(req, "cmd");
        if (std.mem.eql(u8, cmd, "queue.list")) {
            var entries: std.ArrayList(Value) = .empty;
            for (store.state.sendQueue) |entry| try entries.append(a, try send_queue.receipt(a, store, entry));
            return j.value(a, .{ .queue = entries.items });
        }
        if (std.mem.eql(u8, cmd, "draft.queue")) {
            try s.capability(a, store.state.account, req, "mail-send");
            const draft = try store.draft(try j.required(req, "draftId"));
            try validateDraft(draft, true);
            _ = try markdown_mail.prepare(a, draft);
            const digest = storage.Store.hash(try operationPayload(a, draft, store.state.account, null));
            const entry = try send_queue.stage(store, draft.id, try j.required(req, "operationId"), &digest, std.Io.Timestamp.now(s.io, .real).toMilliseconds(), try send_queue.delay(req));
            return send_queue.receipt(a, store, entry.*);
        }
        const id = try j.required(req, "queueId");
        if (std.mem.eql(u8, cmd, "queue.read")) return send_queue.receipt(a, store, (try send_queue.find(store, id)).*);
        if (std.mem.eql(u8, cmd, "queue.cancel")) return send_queue.receipt(a, store, (try send_queue.cancel(store, id)).*);
        if (std.mem.eql(u8, cmd, "queue.resume")) {
            try s.capability(a, store.state.account, req, "mail-send");
            return send_queue.receipt(a, store, (try send_queue.resumeEntry(store, id, std.Io.Timestamp.now(s.io, .real).toMilliseconds(), try send_queue.delay(req))).*);
        }
        if (!std.mem.eql(u8, cmd, "queue.process")) return error.UnsupportedCommand;
        const wait_for_due = try j.boolean(req, "wait", false);
        try s.capability(a, store.state.account, req, "mail-send");
        var entry = try send_queue.find(store, id);
        if (entry.state != .queued) return send_queue.receipt(a, store, entry.*);
        const remaining = entry.dueAtMs - std.Io.Timestamp.now(s.io, .real).toMilliseconds();
        if (remaining > 0) {
            if (!wait_for_due) return error.QueueNotDue;
            if (remaining > 30000) return error.QueueClockChanged;
            store.release();
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(remaining) }).sleep(s.io);
            try s.reopenBody(a, store);
            entry = try send_queue.find(store, id);
            if (entry.state != .queued) return send_queue.receipt(a, store, entry.*);
            if (entry.dueAtMs > std.Io.Timestamp.now(s.io, .real).toMilliseconds()) return error.QueueNotDue;
        }
        const draft = try store.draft(entry.draftId);
        const digest = storage.Store.hash(try operationPayload(a, draft, store.state.account, null));
        if (!std.mem.eql(u8, entry.hash, &digest)) {
            entry.state = .canceled;
            entry.errorCode = "DraftChanged";
            try store.save();
            return send_queue.receipt(a, store, entry.*);
        }
        // The durable claim precedes any send code. After a crash, submitting
        // remains fenced even if the operation journal was not written yet.
        entry.state = .submitting;
        try store.save();
        var request = try j.copyObject(a, req);
        try request.object.put(a, "cmd", .{ .string = "draft.send" });
        try request.object.put(a, "draftId", .{ .string = entry.draftId });
        try request.object.put(a, "operationId", .{ .string = entry.operationId });
        const sent = s.send(a, store, request, draft, null, true) catch |err| {
            entry = try send_queue.find(store, id);
            entry.state = .rejected;
            entry.errorCode = @errorName(err);
            for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, entry.operationId)) {
                entry.state = .unknown;
                break;
            };
            store.save() catch return error.UnknownOutcome;
            return send_queue.receipt(a, store, entry.*);
        };
        entry = try send_queue.find(store, id);
        entry.state = if (std.mem.eql(u8, j.text(sent, "outcome"), "applied")) .applied else if (std.mem.eql(u8, j.text(sent, "outcome"), "rejected")) .rejected else .unknown;
        entry.errorCode = j.text(sent, "errorCode");
        store.save() catch return error.UnknownOutcome;
        return send_queue.receipt(a, store, entry.*);
    }
    fn send(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, draft: t.Draft, calendar: ?[]const u8, claimed_queue: bool) !Value {
        try s.capability(a, store.state.account, req, if (calendar != null) "calendar-rsvp" else "mail-send");
        try validateDraft(draft, true);
        const operation_id = try j.required(req, "operationId");
        if (operation_id.len > 256) return error.InvalidOperationId;
        try recipients.validateHeader(operation_id);
        const payload = try operationPayload(a, draft, store.state.account, calendar);
        const digest = storage.Store.hash(payload);
        for (store.state.sendQueue) |entry| {
            const same_operation = std.mem.eql(u8, entry.operationId, operation_id);
            const same_content = std.mem.eql(u8, entry.hash, &digest);
            const same_draft = draft.id.len != 0 and std.mem.eql(u8, entry.draftId, draft.id);
            if (same_operation and !same_content) return error.OperationConflict;
            if (!same_operation and !same_content and !same_draft) continue;
            if (entry.state == .queued) return error.DraftQueued;
            const claimed = claimed_queue and same_operation and same_content and same_draft and std.mem.eql(u8, entry.queueId, j.text(req, "queueId"));
            if (entry.state == .unknown or (entry.state == .submitting and !claimed)) return error.UnknownOutcome;
        }
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, operation_id)) {
            if (!std.mem.eql(u8, operation.hash, &digest)) return error.OperationConflict;
            return j.value(a, operation);
        };
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and (std.mem.eql(u8, operation.hash, &digest) or (draft.id.len > 0 and std.mem.eql(u8, operation.draftId, draft.id)))) return j.value(a, operation);
        if (store.state.operations.len == 1000) return error.OperationJournalFull;
        const prepared = try markdown_mail.prepare(a, draft);
        // Persist uncertainty before dispatch, including on process failure.
        var operations: std.ArrayList(storage.Operation) = .empty;
        try operations.appendSlice(a, store.state.operations);
        const wire_identity = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ store.state.account, operation_id });
        const wire_hash = storage.Store.hash(wire_identity);
        var fixture_raw: ?[]const u8 = null;
        var spool: ?@import("send_spool.zig").Spool = null;
        defer if (spool) |*file| file.close();
        {
            var from: recipients.Mailbox = .{};
            const sender = draft.from orelse t.Address{ .address = store.state.account };
            if (s.options.fixtures and !std.ascii.eqlIgnoreCase(sender.address, store.state.account)) {
                const source = try s.fixture(a, store.state.account);
                var verified = false;
                if (j.get(source, "identities")) |identities_value| for (try valueArray(identities_value)) |identity| {
                    verified = verified or std.ascii.eqlIgnoreCase(j.text(identity, "address"), sender.address);
                };
                if (!verified) return error.UnverifiedSender;
            }
            try from.address.set(sender.address);
            try from.name.set(sender.name);
            var envelope: recipients.Envelope = .{};
            const lists = [_][]const t.Address{ draft.to, draft.cc, draft.bcc };
            const targets = [_]*recipients.List{ &envelope.to, &envelope.cc, &envelope.bcc };
            for (lists, targets) |addresses, target| for (addresses) |address| {
                var mailbox: recipients.Mailbox = .{};
                try mailbox.address.set(address.address);
                try mailbox.name.set(address.name);
                try target.append(mailbox);
            };
            const mime = @import("mime.zig");
            var compose: mime.Compose = .{ .from = from, .envelope = &envelope, .subject = draft.subject, .body = prepared.plain, .html = prepared.html, .inline_logo = prepared.html != null, .logo_offset = prepared.logoOffset, .related = try mime.composeAttachments(prepared.resources, a), .calendar = calendar, .message_id = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{wire_hash}), .date = if (s.options.fixtures) "Mon, 05 Oct 2026 12:00:00 +0000" else try @import("gmail.zig").date(s.io, a, false), .in_reply_to = draft.inReplyTo, .references = draft.references };
            if (@import("send_spool.zig").required(draft.attachments)) {
                spool = try @import("send_spool.zig").create(store, compose, draft.attachments);
            } else {
                compose.attachments = try mime.composeAttachments(draft.attachments, a);
                const wire = try a.alloc(u8, mime.max_raw_bytes);
                const raw = mime.encode(compose, wire) catch |err| return if (err == error.WriteFailed) error.FormTooLarge else err;
                // Legacy small drafts retain the bounded JSON send wire.
                if (std.base64.url_safe_no_pad.Encoder.calcSize(raw.len) > t.Limits.request_bytes - 1024) return error.FormTooLarge;
                if (s.options.fixtures) {
                    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
                    fixture_raw = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
                }
            }
        }
        // Keep direct-send content as a recoverable draft before uncertainty is recorded.
        const saved_draft = if (std.mem.eql(u8, j.text(req, "cmd"), "draft.send")) draft else try store.putDraft(draft, null);
        try operations.append(a, .{ .id = operation_id, .hash = try a.dupe(u8, &digest), .draftId = saved_draft.id, .rfcMessageId = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{wire_hash}), .icalendar = calendar orelse "" });
        store.state.operations = operations.items;
        try store.save();
        const operation = &store.state.operations[store.state.operations.len - 1];
        if (!s.options.fixtures) {
            var request = try j.copyObject(a, req);
            try request.object.put(a, "draft", try j.value(a, draft));
            if (calendar) |ics| try request.object.put(a, "preparedCalendar", .{ .string = ics });
            const result = (if (spool) |*file| @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeSpool, .{ s.io, a, &s.config, store.state.account, request, draft, file, operation.rfcMessageId }) else s.remote(a, store.state.account, if (calendar != null) "invitation.reply" else "mail.send", request)) catch |err| {
                operation.errorCode = @errorName(err);
                operation.outcome = switch (err) {
                    error.UnverifiedSender, error.FormTooLarge, error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.OAuthClientRequired, error.WrongAccount, error.InvalidGrant, error.UnexpectedScope, error.GrantClientMismatch, error.MessageNotFound, error.ContactConflict, error.RateLimited => "rejected",
                    else => "unknown",
                };
                store.save() catch {
                    operation.outcome = "unknown";
                };
                return j.value(a, operation.*);
            };
            const outcome = j.text(result, "outcome");
            operation.outcome = if (std.mem.eql(u8, outcome, "applied")) "applied" else if (std.mem.eql(u8, outcome, "rejected")) "rejected" else "unknown";
            operation.messageId = j.text(result, "messageId");
            operation.errorCode = j.text(result, "errorCode");
            store.save() catch {
                operation.outcome = "unknown";
            };
            return j.value(a, operation.*);
        }
        store.state.fixtureCalls += 1;
        if (s.scenario("rejected-mutation")) operation.outcome = "rejected" else if (s.scenario("unknown-send")) operation.outcome = "unknown" else {
            store.state.fixtureSends += 1;
            operation.messageId = try store.nextId("sent");
            operation.outcome = if (s.scenario("applied-lost")) "unknown" else "applied";
            var sent_attachments: std.ArrayList(t.Attachment) = .empty;
            try sent_attachments.appendSlice(a, prepared.resources);
            try sent_attachments.appendSlice(a, draft.attachments);
            const sent: t.Message = .{ .id = operation.messageId, .threadId = if (draft.threadId.len > 0) draft.threadId else operation.messageId, .from = draft.from orelse t.Address{ .address = store.state.account }, .to = draft.to, .cc = draft.cc, .subject = draft.subject, .snippet = utf8Prefix(prepared.plain, 240), .bodyText = prepared.plain, .bodyHtml = prepared.html, .bodySource = .plain, .messageId = operation.rfcMessageId, .inReplyTo = draft.inReplyTo, .references = draft.references, .labels = &.{"SENT"}, .receivedAt = std.Io.Timestamp.now(s.io, .real).toMilliseconds(), .attachments = sent_attachments.items, .invitation = calendar, .fixtureRaw = fixture_raw };
            // Copy the receipt first: put() can grow the entries slice, never operations.
            store.putOutbox(sent) catch {
                operation.outcome = "unknown";
            };
            store.state.generation += 1;
        }
        store.save() catch {
            operation.outcome = "unknown";
        };
        return j.value(a, operation.*);
    }
};

fn optionalArray(v: Value, key: []const u8) ![]Value {
    return if (j.get(v, key)) |value| valueArray(value) else &.{};
}
fn array(v: Value, key: []const u8) ![]Value {
    return valueArray(j.get(v, key) orelse return error.InvalidProviderResponse);
}
fn valueArray(v: Value) ![]Value {
    return if (v == .array) v.array.items else error.InvalidRequest;
}
pub fn decodeAddresses(a: std.mem.Allocator, v: Value) ![]const t.Address {
    var list: std.ArrayList(t.Address) = .empty;
    if (v == .string) {
        var parsed: recipients.List = .{};
        try recipients.parse(v.string, &parsed);
        return listAddresses(a, &parsed);
    }
    const values = try valueArray(v);
    if (values.len > t.Limits.recipients) return error.TooManyRecipients;
    for (values) |item| {
        const address = if (item == .string) item.string else try j.required(item, "address");
        if (item == .object) if (j.get(item, "name")) |field| {
            if (field != .string) return error.InvalidRequest;
        };
        const name = if (item == .string) "" else j.text(item, "name");
        try recipients.validateAddress(address);
        try recipients.validateHeader(name);
        if (name.len > 256) return error.InvalidAddress;
        try list.append(a, .{ .address = address, .name = name });
    }
    return list.items;
}
pub fn decodeDraft(a: std.mem.Allocator, v: Value) !t.Draft {
    if (v != .object) return error.InvalidRequest;
    for ([_][]const u8{ "id", "subject", "bodyText", "threadId", "inReplyTo", "references" }) |key| if (j.get(v, key)) |field| {
        if (field != .string) return error.InvalidRequest;
    };
    var draft = try j.decode(t.Draft, a, try j.value(a, .{ .id = j.text(v, "id"), .subject = j.text(v, "subject"), .bodyText = j.text(v, "bodyText"), .threadId = j.text(v, "threadId"), .inReplyTo = j.text(v, "inReplyTo"), .references = j.text(v, "references") }));
    draft.bodyFormat = try requestBodyFormat(v);
    draft.to = if (j.get(v, "to")) |x| try decodeAddresses(a, x) else &.{};
    draft.cc = if (j.get(v, "cc")) |x| try decodeAddresses(a, x) else &.{};
    draft.bcc = if (j.get(v, "bcc")) |x| try decodeAddresses(a, x) else &.{};
    if (j.get(v, "from")) |sender| if (sender != .null) {
        if (sender == .string) {
            const addresses = try decodeAddresses(a, sender);
            if (addresses.len != 1) return error.InvalidSender;
            draft.from = addresses[0];
        } else draft.from = try j.decode(t.Address, a, sender);
    };
    if (j.get(v, "recoveryFields")) |fields| if (fields != .null) {
        draft.recoveryFields = try j.decode([]const []const u8, a, fields);
        if (draft.recoveryFields.?.len != 5) return error.InvalidRecovery;
    };
    draft.attachments = if (j.get(v, "attachments")) |x| try j.decode([]const t.Attachment, a, x) else &.{};
    if (j.get(v, "original")) |original| {
        if (original != .null) draft.original = try j.decode(t.Original, a, original);
    }
    for (draft.attachments) |attachment| if (attachment.blobId == null) {
        _ = try @import("mime.zig").composeAttachments(&.{attachment}, a);
    };
    if (draft.original) |original| _ = try @import("mime.zig").composeAttachments(original.resources, a);
    return draft;
}
fn requestBodyFormat(v: Value) !t.BodyFormat {
    const field = j.get(v, "bodyFormat") orelse return .plain;
    const text = try j.string(field);
    return std.meta.stringToEnum(t.BodyFormat, text) orelse error.InvalidBodyFormat;
}
pub fn validateDraft(d: t.Draft, send: bool) !void {
    if (send and d.recoveryFields != null) return error.UnfinishedDraft;
    if (d.from) |sender| {
        try recipients.validateAddress(sender.address);
        try recipients.validateHeader(sender.name);
        if (sender.name.len > 256) return error.InvalidSender;
    }
    if (d.to.len + d.cc.len + d.bcc.len > t.Limits.recipients) return error.TooManyRecipients;
    if (send and d.to.len + d.cc.len + d.bcc.len == 0) return error.MissingRecipient;
    if (d.bodyText.len > t.Limits.body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(d.bodyText)) return error.InvalidUtf8;
    const related = if (d.original) |original| original.resources else &.{};
    if (d.attachments.len > t.Limits.attachments or related.len > t.Limits.related_resources) return error.TooManyAttachments;
    if (d.original) |original| try @import("original_mail.zig").validate(original);
    var attachment_bytes: usize = 0;
    var embedded_bytes: usize = 0;
    for ([_][]const t.Attachment{ d.attachments, related }) |list| for (list) |attachment| {
        if (attachment.filename.len == 0 or attachment.filename.len > 256 or std.mem.indexOfAny(u8, attachment.filename, "/\\") != null) return error.InvalidAttachment;
        try recipients.validateHeader(attachment.filename);
        try recipients.validateHeader(attachment.mimeType);
        if (attachment.mimeType.len == 0 or attachment.mimeType.len > 128 or std.mem.indexOfScalar(u8, attachment.mimeType, '/') == null) return error.InvalidAttachment;
        const n = if (attachment.blobId) |id| blk: {
            try @import("attachment_blob.zig").validateId(id);
            if (attachment.data.len != 0) return error.InvalidAttachmentHandle;
            break :blk attachment.size;
        } else std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(attachment.data) catch return error.InvalidAttachment;
        attachment_bytes = std.math.add(usize, attachment_bytes, n) catch return error.BodyTooLarge;
        if (attachment_bytes > t.Limits.attachment_bytes or n != attachment.size) return error.InvalidAttachment;
        if (attachment.blobId == null) {
            embedded_bytes = std.math.add(usize, embedded_bytes, n) catch return error.BodyTooLarge;
            if (embedded_bytes > t.Limits.body_bytes) return error.InvalidAttachment;
        }
        // Validate every encoded byte without allocating a second binary copy.
        for (attachment.data) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidAttachment;
        try @import("mime.zig").validateAttachment(attachment.filename, attachment.mimeType);
        if (attachment.contentId) |id| _ = try @import("mime.zig").contentId(id);
        if (attachment.disposition) |value| if (!std.mem.eql(u8, value, "inline") and !std.mem.eql(u8, value, "attachment")) return error.InvalidDisposition;
        if (attachment.contentLocation) |value| {
            try recipients.validateHeader(value);
            if (value.len == 0 or value.len > 2048) return error.InvalidContentLocation;
        }
    };
    for (related, 0..) |resource, index| {
        if (resource.blobId != null) return error.InvalidOriginalResource;
        if (std.ascii.startsWithIgnoreCase(resource.mimeType, "message/")) return error.UnsupportedRelatedType;
        if (resource.contentId == null and resource.contentLocation == null) return error.MissingRelatedIdentity;
        for (related[0..index]) |previous| {
            if (resource.contentId) |id| if (previous.contentId) |other| if (std.mem.eql(u8, id, other)) return error.AmbiguousContentId;
            if (resource.contentLocation) |location| if (previous.contentLocation) |other| if (std.mem.eql(u8, location, other)) return error.AmbiguousContentId;
        }
    }
    try recipients.validateHeader(d.subject);
    try recipients.validateHeader(d.inReplyTo);
    try recipients.validateHeader(d.references);
    try recipients.validateHeader(d.threadId);
    if (d.subject.len > 4096 or d.references.len > 8192) return error.HeaderTooLarge;
    for ([_][]const t.Address{ d.to, d.cc, d.bcc }) |list| for (list) |address| {
        try recipients.validateAddress(address.address);
        try recipients.validateHeader(address.name);
    };
}
fn listAddresses(a: std.mem.Allocator, list: *const recipients.List) ![]const t.Address {
    const result = try a.alloc(t.Address, list.count);
    for (list.slice(), result) |*src, *dst| dst.* = .{ .address = try a.dupe(u8, src.address.slice()), .name = try a.dupe(u8, src.name.slice()) };
    return result;
}
fn addressHeader(a: std.mem.Allocator, list: []const t.Address) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    for (list, 0..) |address, i| {
        if (i > 0) try bytes.appendSlice(a, ", ");
        try bytes.appendSlice(a, address.address);
    }
    return bytes.items;
}
fn quote(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, "\n\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len + 3 > t.Limits.body_bytes - bytes.items.len) return error.BodyTooLarge;
        try bytes.appendSlice(a, "> ");
        try bytes.appendSlice(a, line);
        try bytes.append(a, '\n');
    }
    return bytes.items;
}
fn hasLabel(m: t.Message, label: []const u8) bool {
    for (m.labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}
fn removeLabel(list: *std.ArrayList([]const u8), label: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], label)) _ = list.orderedRemove(i) else i += 1;
    }
}
fn addLabel(a: std.mem.Allocator, list: *std.ArrayList([]const u8), label: []const u8) !void {
    for (list.items) |l| if (std.mem.eql(u8, l, label)) return;
    if (list.items.len == 64) return error.TooManyLabels;
    try list.append(a, label);
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}
fn cacheMatches(m: t.Message, q: []const u8) bool {
    return cache_query.matches(m, q);
}

fn matches(m: t.Message, q: []const u8) bool {
    if (std.mem.eql(u8, q, "-in:inbox -in:trash")) return !hasLabel(m, "INBOX") and !hasLabel(m, "TRASH");
    if (std.mem.startsWith(u8, q, "from:")) return containsIgnoreCase(m.from.address, q[5..]);
    if (std.mem.startsWith(u8, q, "subject:")) return containsIgnoreCase(m.subject, q[8..]);
    if (std.mem.eql(u8, q, "is:unread")) return m.unread;
    if (std.mem.eql(u8, q, "in:trash")) return hasLabel(m, "TRASH");
    return containsIgnoreCase(m.subject, q) or containsIgnoreCase(m.snippet, q) or containsIgnoreCase(m.bodyText, q) or containsIgnoreCase(m.from.address, q);
}
pub fn boundedJson(raw: []const u8) bool {
    var quote_open = false;
    var escaped = false;
    var depth: usize = 0;
    var separators: usize = 0;
    for (raw) |c| {
        if (quote_open) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quote_open = false;
            continue;
        }
        switch (c) {
            '"' => quote_open = true,
            '[', '{' => {
                depth += 1;
                if (depth > 64) return false;
            },
            ']', '}' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            ',', ':' => {
                separators += 1;
                if (separators > 65536) return false;
            },
            else => {},
        }
    }
    return !quote_open and depth == 0;
}
fn utcStamp(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    if (seconds < 0 or seconds > 253402300799) return error.InvalidClock;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}
fn calendarIdentity(a: std.mem.Allocator, ics: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitSequence(u8, ics, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "DTSTAMP:")) continue;
        try out.appendSlice(a, line);
        try out.appendSlice(a, "\r\n");
    }
    return out.items;
}

fn olderFirst(_: void, a: t.Message, b: t.Message) bool {
    return a.receivedAt < b.receivedAt;
}
fn newerFirst(_: void, a: t.Message, b: t.Message) bool {
    return a.receivedAt > b.receivedAt;
}
fn utf8Prefix(bytes: []const u8, limit: usize) []const u8 {
    var n = @min(bytes.len, limit);
    while (n > 0 and !std.unicode.utf8ValidateSlice(bytes[0..n])) : (n -= 1) {}
    return bytes[0..n];
}

test "post-dispatch allocation failure preserves live mutation ambiguity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    const receipt: Value = .{ .string = "applied-provider-receipt" };
    for ([_][]const u8{ "contacts.upsert", "mail.mark", "mail.archive", "mail.trash", "mail.restore", "mail.send", "draft.send", "invitation.reply" }) |cmd| {
        try std.testing.expectError(error.UnknownOutcome, Session.successResponse(a, .null, "self@example.test", cmd, false, receipt));
    }
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "mail.read", false, receipt));
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "contacts.upsert", true, receipt));
    try std.testing.expectError(error.UnknownOutcome, Session.failureForError(a, .null, "self@example.test", error.UnknownOutcome));
    try std.testing.expect(failing.has_induced_failure);
}

test "mock provider label state survives eviction clear restart and newer typed history wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/provider-state", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 1 });
    defer store.close();
    try store.put(.{ .id = "older", .threadId = "thread", .receivedAt = 10, .labels = &.{"TRASH"}, .bodyText = "Immutable fictional body" }, true);
    try store.setFixtureRecord("older", &.{"TRASH"}, "41", false);
    try store.setFixtureRecord("untouched", &.{"TRASH"}, "41", false);
    const original_hash = (store.find("older").?).bodyHash;
    const newer = try std.json.parseFromSliceLeaky(Value, a, "{\"messages\":[{\"id\":\"older\",\"labelIds\":[\"INBOX\",\"STARRED\"]},{\"id\":\"untouched\",\"labelIds\":[\"INBOX\"]}],\"sync\":{\"historyId\":\"70\",\"history\":[{\"id\":\"57\",\"labelsAdded\":[{\"message\":{\"id\":\"older\"},\"labelIds\":[\"STARRED\"]}]}]}}", .{});
    try std.testing.expect(try Session.reconcileFixtureSource(a, &store, newer));
    try std.testing.expect(store.fixtureRecord("older") == null);
    try std.testing.expect(store.fixtureRecord("untouched") != null);
    try std.testing.expectEqualStrings("STARRED", store.find("older").?.message.labels[1]);
    try std.testing.expectEqualStrings(original_hash, store.find("older").?.bodyHash);
    const overlaid = try Session.overlayFixtureSource(a, &store, newer);
    const untouched = (try Session.rawFixtureMessage(overlaid, "untouched")).?;
    try std.testing.expectEqualStrings("TRASH", (try fixtureLabelLiteral(untouched))[0].string);
    try store.clearMail();
    try std.testing.expectEqual(@as(usize, 1), store.state.fixtureProvider.len);
    store.close();
    var restarted = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true, .metadata_limit = 1 });
    defer restarted.close();
    var message: t.Message = .{ .id = "untouched", .threadId = "thread", .labels = &.{ "INBOX", "UNREAD" }, .unread = true };
    try restarted.applyFixtureRecord(&message);
    try std.testing.expectEqualStrings("TRASH", message.labels[0]);
    try std.testing.expect(!message.unread);
    const deleted = try std.json.parseFromSliceLeaky(Value, a, "{\"messages\":[{\"id\":\"untouched\",\"labelIds\":[\"INBOX\"]}],\"sync\":{\"historyId\":\"91\",\"history\":[{\"id\":\"90\",\"messagesDeleted\":[{\"message\":{\"id\":\"untouched\"}}]}]}}", .{});
    try std.testing.expect(try Session.reconcileFixtureSource(a, &restarted, deleted));
    try std.testing.expectError(error.MessageNotFound, restarted.applyFixtureRecord(&message));
    const tombstone = try Session.overlayFixtureSource(a, &restarted, deleted);
    try std.testing.expectEqual(@as(usize, 0), (try array(tombstone, "messages")).len);
    try restarted.save();
    restarted.close();
    var live = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = false });
    defer live.close();
    try std.testing.expectEqual(@as(usize, 0), live.state.fixtureProvider.len);
    try std.testing.expectError(error.FixtureOnly, live.setFixtureRecord("untouched", &.{"TRASH"}, "41", false));
}
fn fixtureLabelLiteral(raw: Value) ![]Value {
    return array(raw, "labelIds");
}

test "automatic freshness uses completed matching Inbox start and exact half-interval boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/fresh", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    const m: t.Message = .{ .id = "m", .threadId = "t", .labels = &.{"INBOX"}, .bodyText = "Body" };
    try store.put(m, true);
    store.state.historyId = "41";
    try store.recordView("", "INBOX", "INBOX", &.{m}, "remote-more", false);
    const key = try storage.Store.viewKey(a, store.state.account, "", "INBOX");
    const view = store.findView(&key).?;
    view.lastSyncStartedAt = 1000000;
    view.lastSyncAt = 1020000;
    const request = try j.value(a, .{ .limit = @as(u8, 1) });
    try std.testing.expect(try Session.automaticFresh(a, &store, request, 1149999, 300));
    try std.testing.expect(!try Session.automaticFresh(a, &store, request, 1150000, 300));
    try std.testing.expect(!try Session.automaticFresh(a, &store, request, 999999, 300));
    view.stale = true;
    try std.testing.expect(!try Session.automaticFresh(a, &store, request, 1100000, 300));
    view.stale = false;
    view.incomplete = true;
    const larger = try j.value(a, .{ .limit = @as(u8, 32) });
    try std.testing.expect(try Session.automaticFresh(a, &store, larger, 1100000, 300));
    try store.dir.deleteFile(std.testing.io, try store.fileName("mail", "m"));
    try std.testing.expect(!try Session.automaticFresh(a, &store, request, 1100000, 300));
}
test "cache search has K account query mode cursors and metadata-only predicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/search", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    for (0..3) |i| try store.put(.{ .id = try std.fmt.allocPrint(a, "m{d}", .{i}), .threadId = "t", .subject = "Café synthetic", .from = .{ .address = "sender@example.test", .name = "Alex Fixture" }, .labels = &.{"INBOX"}, .receivedAt = @intCast(i) }, false);
    var request = try j.value(a, .{ .query = "Café", .limit = @as(u8, 1) });
    const result = try Session.cacheSearch(a, &store, request, std.testing.allocator);
    try std.testing.expectEqualStrings("cache", j.text(result, "searchMode"));
    try std.testing.expectEqual(@as(i64, 3), try j.integer(result, "matchedCachedCount", 0));
    const cursor = try j.required(result, "nextCursor");
    try std.testing.expect(std.mem.startsWith(u8, cursor, "K:"));
    try request.object.put(a, "cursor", .{ .string = cursor });
    _ = try Session.cacheSearch(a, &store, request, std.testing.allocator);
    try std.testing.expectError(error.InvalidCursor, Session.cachedList(a, &store, request));
    try request.object.put(a, "query", .{ .string = "from:Alex" });
    try std.testing.expectError(error.InvalidCursor, Session.cacheSearch(a, &store, request, std.testing.allocator));
    try std.testing.expect(cacheMatches(store.state.entries[0].message, "from:Alex"));
    try std.testing.expect(cacheMatches(store.state.entries[0].message, "in:inbox"));
    try std.testing.expect(!cacheMatches(store.state.entries[0].message, "-in:inbox -in:trash"));
}
test "message refusal classification keeps integrity bounds and excludes systemic failures" {
    for ([_]anyerror{ error.BodySizeMismatch, error.TooManyHeaders, error.InvalidEncodedWord, error.MalformedMessage, error.BodyTooLarge }) |err| try std.testing.expect(Session.messageRefusal(err));
    for ([_]anyerror{ error.OutOfMemory, error.Canceled, error.Timeout, error.InvalidGrant, error.PermissionDenied, error.TokenRefreshFailed, error.RateLimited, error.CacheBusy, error.CacheIdentityMismatch }) |err| try std.testing.expect(!Session.messageRefusal(err));
}

test "cached contacts distinguish absent empty and loaded data without granting readonly contacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/contacts", .{tmp.sub_path});
    var session: Session = .{ .io = std.testing.io, .allocator = a, .options = .{ .fixtures = true }, .config = undefined, .cache_root = root, .env = undefined };
    const req = try j.value(a, .{ .cmd = "contacts.list" });
    const cold = try session.cachedDispatch(a, "fictional@example.test", req);
    try std.testing.expect(!try j.boolean(cold, "cacheReady", true));
    {
        var store = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
        defer store.close();
        store.state.contactsReady = true;
        try store.save();
    }
    const empty = try session.cachedDispatch(a, "fictional@example.test", req);
    try std.testing.expect(try j.boolean(empty, "cacheReady", false));
    try std.testing.expectEqual(@as(usize, 0), (try array(empty, "contacts")).len);
    {
        var store = try storage.Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
        defer store.close();
        store.state.contacts = try a.dupe(t.Contact, &.{.{ .resourceName = "people/synthetic", .etag = "1", .name = "Alex Fixture", .emails = &.{.{ .address = "alex@example.test" }} }});
        try store.save();
    }
    const search = try j.value(a, .{ .cmd = "contacts.search", .query = "ALEX" });
    try std.testing.expectEqual(@as(usize, 1), (try array(try session.cachedDispatch(a, "fictional@example.test", search), "contacts")).len);
    session.options.fixture_scenario = "readonly";
    try std.testing.expectError(error.PermissionDenied, session.cachedDispatch(a, "fictional@example.test", req));
}

test "recipient cache: actual cached client sees body-free Sent To Cc and fences grants and accounts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/recipients", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .fixture_scenario = "readonly", .cache_dir = root });
    defer session.deinit();
    {
        var store = try storage.Store.open(std.testing.io, a, root, "personal@example.com", session.options);
        defer store.close();
        try store.put(.{ .id = "unread-sent-body", .threadId = "sent", .from = .{ .address = "personal@example.com" }, .to = &.{.{ .address = "caroline@example.test", .name = "Caroline Composer" }}, .cc = &.{.{ .address = "copied@example.test" }}, .labels = &.{"SENT"}, .receivedAt = 42 }, false);
        try store.save();
        try std.testing.expectEqual(@as(usize, 0), store.find("unread-sent-body").?.bytes);
    }
    const raw = try session.client().callCached(a, "{\"cmd\":\"mail.recipients\",\"account\":\"personal@example.com\"}");
    const response = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
    try std.testing.expect(try j.boolean(response, "ok", false));
    const data = j.get(response, "data").?;
    try std.testing.expect(!try j.boolean(data, "contactsIncluded", true));
    const values = try array(data, "recipients");
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("caroline@example.test", j.text(values[0], "address"));
    try std.testing.expectEqualStrings("copied@example.test", j.text(values[1], "address"));
    const unknown = try std.json.parseFromSliceLeaky(Value, a, try session.client().callCached(a, "{\"cmd\":\"mail.recipients\",\"account\":\"unknown@example.test\"}"), .{});
    try std.testing.expectEqualStrings("UnknownAccount", j.text(j.get(unknown, "error").?, "code"));
    session.config.accounts[0].enabled = false;
    const disabled = try std.json.parseFromSliceLeaky(Value, a, try session.client().callCached(a, "{\"cmd\":\"mail.recipients\",\"account\":\"personal@example.com\"}"), .{});
    try std.testing.expectEqualStrings("AccountDisabled", j.text(j.get(disabled, "error").?, "code"));
    session.config.accounts[0].enabled = true;
    const auth = @import("auth.zig");
    const scopes = try auth.scopesFor(a, &.{"mail-read"});
    const grant_id = auth.grantIdentity(scopes);
    const registry: auth.Registry = .{ .accounts = try a.dupe(auth.Grant, &.{.{ .account = "personal@example.com", .clientFile = "/tmp/fictional-client.json", .clientId = "fictional.apps.googleusercontent.com", .grantId = &grant_id, .capabilities = &.{"mail-read"}, .scopes = scopes, .enabled = false }}) };
    const file = try tmp.dir.createFile(std.testing.io, "disabled-grants.json", .{ .permissions = .fromMode(0o600) });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, try std.json.Stringify.valueAlloc(a, registry, .{}));
    session.options.fixtures = false;
    session.options.grant_file = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/disabled-grants.json", .{tmp.sub_path});
    const denied = try std.json.parseFromSliceLeaky(Value, a, try session.client().callCached(a, "{\"cmd\":\"mail.recipients\",\"account\":\"personal@example.com\"}"), .{});
    try std.testing.expectEqualStrings("PermissionDenied", j.text(j.get(denied, "error").?, "code"));
}

test "wishlist: old primary draft operation wire keeps optional nulls absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const literal = "{\"draft\":{\"id\":\"\",\"to\":[{\"address\":\"peer@example.test\",\"name\":\"\"}],\"cc\":[],\"bcc\":[],\"subject\":\"Hi\",\"bodyText\":\"Body\",\"threadId\":\"\",\"inReplyTo\":\"\",\"references\":\"\",\"attachments\":[]},\"calendar\":null}";
    var draft: t.Draft = .{ .id = "local-id", .to = &.{.{ .address = "peer@example.test" }}, .subject = "Hi", .bodyText = "Body" };
    try std.testing.expectEqualStrings(literal, try operationPayload(a, draft, "self@example.test", null));
    draft.from = .{ .address = "SELF@example.test" };
    try std.testing.expectEqualStrings(literal, try operationPayload(a, draft, "self@example.test", null));
}

test "UX backend: complete triage scopes pin IDs and selective undo preserves each message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/triage-scope", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const message = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.triage-scope", .account = account, .messageId = "demo-1", .scope = "message" }));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(message, "count", 0));
    const conversation = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.triage-scope", .account = account, .messageId = "demo-1", .scope = "conversation" }));
    try std.testing.expect(try j.boolean(conversation, "complete", false));
    try std.testing.expectEqual(@as(i64, 3), try j.integer(conversation, "count", 0));
    var request = try j.value(a, .{ .cmd = "mail.batch", .account = account, .scope = "conversation", .action = "archive" });
    try request.object.put(a, "messageIds", j.get(conversation, "messageIds").?);
    const applied = try session.dispatch(a, request);
    try std.testing.expectEqual(@as(i64, 3), try j.integer(applied, "appliedCount", 0));
    const token = j.text(applied, "undoToken");
    try std.testing.expectError(error.UndoMessageNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "mail.undo", .account = account, .undoToken = token, .messageIds = .{"demo-4"} })));
    const undone = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.undo", .account = account, .undoToken = token, .messageIds = .{"demo-1"} }));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(undone, "restoredCount", 0));
    var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
    defer store.close();
    try std.testing.expect(hasLabel(.{ .id = "", .threadId = "", .labels = store.fixtureRecord("demo-1").?.labels }, "INBOX"));
    try std.testing.expect(!hasLabel(.{ .id = "", .threadId = "", .labels = store.fixtureRecord("demo-2").?.labels }, "INBOX"));
}

test "UX backend: advertised default fixture label IDs apply and remove without changing mail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/default-label-ids", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const listed = try session.dispatch(a, try j.value(a, .{ .cmd = "labels.list", .account = account }));
    var definition: ?Value = null;
    for (try array(listed, "labels")) |label| if (std.mem.eql(u8, j.text(label, "type"), "user")) {
        definition = label;
        break;
    };
    const id = try j.required(definition orelse return error.MissingFixtureLabel, "id");
    const name = try j.required(definition.?, "name");
    const before = try j.decode(t.Message, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "demo-1" })));
    for ([_][]const u8{ id, name }) |input| {
        const applied = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.batch", .account = account, .messageIds = .{"demo-1"}, .action = "mark", .addLabels = .{input} }));
        try std.testing.expectEqual(@as(i64, 1), try j.integer(applied, "appliedCount", 0));
        const marked = try j.decode(t.Message, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "demo-1" })));
        try std.testing.expect(hasLabel(marked, id));
        try std.testing.expectEqualStrings(before.bodyText, marked.bodyText);
        const removed = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.batch", .account = account, .messageIds = .{"demo-1"}, .action = "mark", .removeLabels = .{id} }));
        try std.testing.expectEqual(@as(i64, 1), try j.integer(removed, "appliedCount", 0));
        const restored = try j.decode(t.Message, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "demo-1" })));
        try std.testing.expect(!hasLabel(restored, id));
        try std.testing.expectEqualDeep(before.labels, restored.labels);
        try std.testing.expectEqualStrings(before.bodyText, restored.bodyText);
    }
    try std.testing.expectError(error.LabelNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "mail.batch", .account = account, .messageIds = .{"demo-1"}, .action = "mark", .addLabels = .{"Label_not_advertised"} })));
    const stats = try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account }));
    try std.testing.expectEqual(@as(i64, 0), try j.integer(stats, "fixtureSends", -1));
}

test "UX backend: label colors round trip rename and reject invalid colors before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/label-colors", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const colored = try session.dispatch(a, try j.value(a, .{ .cmd = "labels.color", .account = account, .labelId = "Label_demo", .operationId = "color-fixture", .color = .{ .backgroundColor = "#FB4C2F", .textColor = "#ffffff" } }));
    try std.testing.expectEqualStrings("#fb4c2f", j.text(j.get(j.get(colored, "label").?, "color").?, "backgroundColor"));
    const renamed = try session.dispatch(a, try j.value(a, .{ .cmd = "labels.rename", .account = account, .labelId = "Label_demo", .operationId = "color-rename", .name = "Renamed project" }));
    try std.testing.expectEqualStrings("#fb4c2f", j.text(j.get(j.get(renamed, "label").?, "color").?, "backgroundColor"));
    try std.testing.expectError(error.InvalidLabelColor, session.dispatch(a, try j.value(a, .{ .cmd = "labels.color", .account = account, .labelId = "Label_demo", .operationId = "bad-color", .color = .{ .backgroundColor = "#123456", .textColor = "#ffffff" } })));
    try std.testing.expectError(error.SystemLabelImmutable, session.dispatch(a, try j.value(a, .{ .cmd = "labels.color", .account = account, .labelId = "INBOX", .operationId = "system-color", .color = .{ .backgroundColor = "#fb4c2f", .textColor = "#ffffff" } })));
}

test "UX backend: label state preserves exact mixed targets and resolves uncertain memberships" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/label-state", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const clear = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.batch", .account = account, .messageIds = .{ "demo-1", "demo-2" }, .action = "mark", .starred = false }));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.batch", .account = account, .messageIds = .{"demo-1"}, .action = "mark", .starred = true }));
    const state_request = try j.value(a, .{ .cmd = "mail.label-state", .account = account, .messageIds = .{ "demo-1", "demo-2" } });
    const mixed = try session.dispatch(a, state_request);
    try std.testing.expect(try j.boolean(mixed, "complete", false));
    try std.testing.expectEqual(@as(i64, 2), try j.integer(mixed, "count", 0));
    var starred_count: i64 = -1;
    for (try array(mixed, "labels")) |label| if (std.mem.eql(u8, j.text(label, "id"), "STARRED")) {
        starred_count = try j.integer(label, "appliedCount", -1);
    };
    try std.testing.expectEqual(@as(i64, 1), starred_count);
    try std.testing.expectError(error.MessageNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "mail.label-state", .account = account, .messageIds = .{ "demo-1", "missing-target" } })));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        // Cache was not updated after an uncertain receipt, while fixture
        // provider labels have a known one-starred result.
        try store.put(.{ .id = "demo-1", .threadId = "thread", .labels = &.{} }, false);
        for (store.state.undo) |*receipt| if (std.mem.eql(u8, receipt.token, j.text(clear, "undoToken"))) {
            receipt.items[0].outcome = "unknown";
        };
        try store.save();
    }
    const resolved = try session.dispatch(a, state_request);
    starred_count = -1;
    for (try array(resolved, "labels")) |label| if (std.mem.eql(u8, j.text(label, "id"), "STARRED")) {
        starred_count = try j.integer(label, "appliedCount", -1);
    };
    try std.testing.expectEqual(@as(i64, 1), starred_count);
}

test "UX backend: send grace cancel edit restart and uncertainty never duplicate submission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/send-grace", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer session.deinit();
    const account = "personal@example.com";
    const created = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .subject = "Reviewed fixture", .bodyText = "First version" } }));
    const draft_id = j.text(created, "id");
    const queued = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = draft_id, .operationId = "grace-cancel", .delaySeconds = 30 }));
    const queue_id = j.text(queued, "queueId");
    try std.testing.expectEqual(@as(i64, 30000), try j.integer(queued, "dueAtMs", 0) - try j.integer(queued, "createdAtMs", 0));
    try std.testing.expectError(error.QueueNotDue, session.dispatch(a, try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = queue_id })));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "queue.cancel", .account = account, .queueId = queue_id }));
    try std.testing.expectEqualStrings("canceled", j.text(try session.dispatch(a, try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = queue_id })), "state"));
    const edited_queue = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = draft_id, .operationId = "grace-edit", .delaySeconds = 30 }));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = draft_id, .draft = .{ .to = "peer@example.test", .subject = "Edited fixture", .bodyText = "Second version" } }));
    try std.testing.expectEqualStrings("canceled", j.text(try session.dispatch(a, try j.value(a, .{ .cmd = "queue.read", .account = account, .queueId = j.text(edited_queue, "queueId") })), "state"));
    const ready = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = draft_id, .operationId = "grace-send", .delaySeconds = 0 }));
    session.deinit();
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    try std.testing.expectEqualStrings("queued", j.text(try session.dispatch(a, try j.value(a, .{ .cmd = "queue.read", .account = account, .queueId = j.text(ready, "queueId") })), "state"));
    const process = try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = j.text(ready, "queueId") });
    var invalid_wait = try j.copyObject(a, process);
    try invalid_wait.object.put(a, "wait", .{ .string = "invalid" });
    try std.testing.expectError(error.InvalidRequest, session.dispatch(a, invalid_wait));
    try std.testing.expectEqualStrings("applied", j.text(try session.dispatch(a, process), "state"));
    _ = try session.dispatch(a, process);
    const stats = try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account }));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(stats, "fixtureSends", 0));
    session.options.fixture_scenario = "unknown-send";
    const next = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = draft_id, .operationId = "grace-unknown", .delaySeconds = 0 }));
    const unknown_process = try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = j.text(next, "queueId") });
    try std.testing.expectEqualStrings("unknown", j.text(try session.dispatch(a, unknown_process), "state"));
    try std.testing.expectEqualStrings("unknown", j.text(try session.dispatch(a, unknown_process), "state"));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "draft.discard", .account = account, .draftId = draft_id })));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .queueId = j.text(next, "queueId"), .operationId = "grace-unknown" })));
    const interrupted_draft = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "other@example.test", .bodyText = "A distinct approved draft" } }));
    const interrupted = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(interrupted_draft, "id"), .operationId = "grace-interrupted", .delaySeconds = 0 }));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, options);
        defer store.close();
        const claimed = try send_queue.find(&store, j.text(interrupted, "queueId"));
        claimed.state = .submitting;
        // Simulate termination immediately after the durable claim, before
        // the ordinary send operation receipt can be written.
        try store.save();
    }
    session.deinit();
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    try std.testing.expectError(error.QueueNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "queue.process", .account = "work@example.com", .queueId = j.text(interrupted, "queueId") })));
    const fenced = try session.dispatch(a, try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = j.text(interrupted, "queueId") }));
    try std.testing.expectEqualStrings("submitting", j.text(fenced, "state"));
    const inline_draft = try j.value(a, .{ .to = "other@example.test", .bodyText = "A distinct approved draft" });
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "mail.send", .account = account, .draft = inline_draft, .operationId = "grace-interrupted" })));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "mail.send", .account = account, .draft = inline_draft, .operationId = "different-operation-same-content" })));
    try std.testing.expectError(error.OperationConflict, session.dispatch(a, try j.value(a, .{ .cmd = "mail.send", .account = account, .draft = .{ .to = "other@example.test", .bodyText = "Changed content" }, .operationId = "grace-interrupted" })));
    try std.testing.expectError(error.SendAlreadySubmitted, session.dispatch(a, try j.value(a, .{ .cmd = "queue.cancel", .account = account, .queueId = j.text(interrupted, "queueId") })));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "draft.discard", .account = account, .draftId = j.text(interrupted_draft, "id") })));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
}

test "UX backend: formatted forward preserves 32 CID resources and an ordinary PDF through MIME" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/cid-forward", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const mime = @import("mime.zig");
    const png = @import("markdown_logo.zig").png;
    const png_encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(png.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(png_encoded, png);
    const pdf = "%PDF-1.7\nFictional ordinary report.\n%%EOF\n";
    const pdf_encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(pdf.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(pdf_encoded, pdf);
    var parts: [33]t.Attachment = undefined;
    var html: std.ArrayList(u8) = .empty;
    try html.appendSlice(a, "<html><body><p>Fictional inline report</p>");
    for (parts[0..32], 0..) |*part, index| {
        const cid = try std.fmt.allocPrint(a, "figure-{d}@example.test", .{index});
        part.* = .{ .id = cid, .filename = try std.fmt.allocPrint(a, "figure-{d}.png", .{index}), .mimeType = "image/png", .size = png.len, .data = png_encoded, .contentId = cid, .disposition = "inline" };
        try html.appendSlice(a, try std.fmt.allocPrint(a, "<img src=\"cid:{s}\" alt=\"Figure {d}\">", .{ cid, index }));
    }
    try html.appendSlice(a, "</body></html>");
    parts[32] = .{ .id = "report-file", .filename = "report.pdf", .mimeType = "application/pdf", .size = pdf.len, .data = pdf_encoded, .disposition = "attachment" };
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        try store.putOutbox(.{ .id = "source-report", .threadId = "source-thread", .from = .{ .address = "peer@example.test" }, .to = &.{.{ .address = account }}, .subject = "Fictional inline report", .bodyText = "Fictional inline report", .bodyHtml = html.items, .attachments = &parts, .labels = &.{"INBOX"} });
        try store.save();
    }
    const forwarded = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.forward", .account = account, .messageId = "source-report", .preserveFormatting = true, .bodyFormat = "markdown" }));
    var draft = try decodeDraft(a, forwarded);
    try std.testing.expectEqual(@as(usize, 32), draft.original.?.resources.len);
    try std.testing.expectEqual(@as(usize, 1), draft.attachments.len);
    try std.testing.expectEqualStrings("report.pdf", draft.attachments[0].filename);
    draft.to = &.{.{ .address = "recipient@example.test" }};
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = draft.id, .draft = draft }));
    const receipt = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = draft.id, .operationId = "cid-forward-send" }));
    try std.testing.expectEqualStrings("applied", j.text(receipt, "outcome"));
    const sent = try j.decode(t.Message, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = j.text(receipt, "messageId") })));
    const parsed = try mime.parse(try mime.decodeBase64Url(sent.fixtureRaw.?, a), a);
    try std.testing.expectEqual(@as(usize, 34), parsed.attachments.len); // 32 original images, one logo, one PDF.
    for (parts[0..32]) |expected| {
        var found = false;
        for (parsed.attachments) |part| if (part.content_id.len > 0 and std.mem.eql(u8, try mime.contentId(part.content_id), expected.contentId.?)) {
            found = true;
            try std.testing.expectEqualSlices(u8, png, part.data);
        };
        try std.testing.expect(found);
        try std.testing.expect(std.mem.indexOf(u8, parsed.body_html, expected.contentId.?) != null);
    }
    var pdf_found = false;
    for (parsed.attachments) |part| if (std.mem.eql(u8, part.filename, "report.pdf")) {
        pdf_found = true;
        try std.testing.expectEqualSlices(u8, pdf, part.data);
    };
    try std.testing.expect(pdf_found);
    var too_many = draft;
    const ordinary: [17]t.Attachment = @splat(draft.attachments[0]);
    too_many.attachments = &ordinary;
    try std.testing.expectError(error.TooManyAttachments, validateDraft(too_many, false));
    too_many = draft;
    const related: [33]t.Attachment = @splat(draft.original.?.resources[0]);
    too_many.original.?.resources = &related;
    try std.testing.expectError(error.TooManyAttachments, validateDraft(too_many, false));
}

test "UX backend: large immutable attachments forward save send and reject wrong accounts or corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/large-attachments", .{tmp.sub_path});
    const input_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/report.bin", .{tmp.sub_path});
    const output_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/saved.bin", .{tmp.sub_path});
    const input = try tmp.dir.createFile(std.testing.io, "report.bin", .{ .read = true, .permissions = .fromMode(0o600) });
    defer input.close(std.testing.io);
    var chunk: [64 * 1024]u8 = undefined;
    for (&chunk, 0..) |*byte, i| byte.* = @truncate(i);
    for (0..64) |_| try input.writeStreamingAll(std.testing.io, &chunk);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const imported = try j.decode(t.Attachment, a, try session.dispatch(a, try j.value(a, .{ .cmd = "attachment.import", .account = account, .path = input_path })));
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), imported.size);
    try std.testing.expect(imported.blobId != null and imported.data.len == 0);
    // Changing the user's source after import cannot change the approved bytes.
    try input.setLength(std.testing.io, 0);
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        const original: t.Message = .{ .id = "large-original", .threadId = "original-thread", .from = .{ .address = "peer@example.test" }, .subject = "Large report", .bodyText = "Report attached.", .attachments = &.{imported} };
        try store.put(original, true);
        try store.put(.{ .id = original.id, .threadId = original.threadId, .subject = original.subject, .labels = &.{"INBOX"} }, false);
        try std.testing.expectEqualStrings(imported.blobId.?, store.find(original.id).?.message.attachments[0].blobId.?);
        try store.save();
    }
    const forwarded = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.forward", .account = account, .messageId = "large-original" }));
    var draft = try decodeDraft(a, forwarded);
    try std.testing.expectEqualStrings(imported.blobId.?, draft.attachments[0].blobId.?);
    try std.testing.expectEqualStrings("", draft.threadId);
    draft.to = &.{.{ .address = "recipient@example.test" }};
    try std.testing.expectError(error.AttachmentHandleNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = "work@example.com", .draft = draft })));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = draft.id, .draft = draft }));
    try std.testing.expectError(error.AttachmentInUse, session.dispatch(a, try j.value(a, .{ .cmd = "attachment.discard", .account = account, .blobId = imported.blobId.? })));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = "large-original", .attachmentId = imported.id, .path = output_path }));
    try std.testing.expectError(error.PathAlreadyExists, session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = "large-original", .attachmentId = imported.id, .path = output_path })));
    const output = try tmp.dir.openFile(std.testing.io, "saved.bin", .{});
    defer output.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, imported.size), (try output.stat(std.testing.io)).size);
    try std.testing.expectEqual(@as(u32, 0o600), (try output.stat(std.testing.io)).permissions.toMode() & 0o777);
    try tmp.dir.createDir(std.testing.io, "save-target", .fromMode(0o700));
    try tmp.dir.symLink(std.testing.io, "save-target", "save-link", .{ .is_directory = true });
    const linked_parent = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/save-link/refused.bin", .{tmp.sub_path});
    if (session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = "large-original", .attachmentId = imported.id, .path = linked_parent }))) |_| {
        return error.ExpectedSymlinkRefusal;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "save-target/refused.bin", .{ .follow_symlinks = false }));
    try tmp.dir.symLink(std.testing.io, "saved.bin", "saved-link.bin", .{});
    const linked_leaf = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/saved-link.bin", .{tmp.sub_path});
    try std.testing.expectError(error.PathAlreadyExists, session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = "large-original", .attachmentId = imported.id, .path = linked_leaf })));
    var saved_chunk: [64 * 1024]u8 = undefined;
    for (0..64) |index| {
        try std.testing.expectEqual(saved_chunk.len, try output.readPositional(std.testing.io, &.{&saved_chunk}, index * saved_chunk.len));
        try std.testing.expectEqualSlices(u8, &chunk, &saved_chunk);
    }
    const sent = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = draft.id, .operationId = "large-fixture-send" }));
    try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        const blob_name = try @import("attachment_blob.zig").filename(a, imported.blobId.?);
        const corrupt = try store.dir.openFile(std.testing.io, blob_name, .{ .mode = .read_write, .follow_symlinks = false });
        defer corrupt.close(std.testing.io);
        try corrupt.writeStreamingAll(std.testing.io, "changed");
    }
    try std.testing.expectError(error.AttachmentChanged, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = draft.id, .operationId = "corrupt-fixture-send" })));
    const stats = try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account }));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(stats, "fixtureSends", 0));
}

test "markdown mail: persisted sources recovery preview compose reply forward send and uncertainty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/markdown", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const source = "# Markdown\n\n**Hello** fixture.\n\n- first\n- second";
    const created = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = source, .bodyFormat = "markdown" } }));
    const id = j.text(created, "id");
    const read_draft = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = id }));
    try std.testing.expectEqualStrings(source, j.text(read_draft, "bodyText"));
    try std.testing.expectEqualStrings("markdown", j.text(read_draft, "bodyFormat"));
    const preview = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.preview", .account = account, .draftId = id }));
    try std.testing.expect(std.mem.indexOf(u8, j.text(preview, "bodyHtml"), "<strong>Hello</strong>") != null);
    const receipt = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = id, .operationId = "markdown-send" }));
    try std.testing.expectEqualStrings("applied", j.text(receipt, "outcome"));
    const sent = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = j.text(receipt, "messageId") }));
    try std.testing.expectEqualStrings(j.text(preview, "bodyHtml"), j.text(sent, "bodyHtml"));
    try std.testing.expectEqualStrings(j.text(preview, "plainText"), j.text(sent, "bodyText"));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        const persisted = try store.draft(id);
        try std.testing.expectEqual(t.BodyFormat.markdown, persisted.bodyFormat);
        try std.testing.expectEqualStrings(source, persisted.bodyText);
        try store.put(.{ .id = "original", .threadId = "original-thread", .from = .{ .address = "peer@example.test" }, .to = &.{.{ .address = account }}, .subject = "Original", .bodyText = "# Original *literal* [link](javascript:bad)\n<tag>", .messageId = "<original@example.test>", .attachments = &.{.{ .id = "fixture-file", .filename = "fixture.bin", .size = 3, .data = "AP-A" }} }, true);
        try store.save();
    }
    const replied = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.reply", .account = account, .messageId = "original", .bodyFormat = "markdown", .all = true }));
    try std.testing.expectEqualStrings("markdown", j.text(replied, "bodyFormat"));
    try std.testing.expectEqualStrings("original-thread", j.text(replied, "threadId"));
    const reply_preview = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.preview", .account = account, .draftId = j.text(replied, "id") }));
    try std.testing.expect(std.mem.indexOf(u8, j.text(reply_preview, "plainText"), "> # Original *literal* [link](javascript:bad)") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.text(reply_preview, "bodyHtml"), "href=\"javascript:") == null);
    const forwarded = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.forward", .account = account, .messageId = "original", .bodyFormat = "markdown" }));
    try std.testing.expectEqualStrings("", j.text(forwarded, "threadId"));
    try std.testing.expectEqual(@as(usize, 1), (try array(forwarded, "attachments")).len);
    var forward_draft = try decodeDraft(a, forwarded);
    forward_draft.to = &.{.{ .address = "forward-peer@example.test" }};
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = forward_draft.id, .draft = forward_draft }));
    const forwarded_receipt = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = forward_draft.id, .operationId = "markdown-forward" }));
    try std.testing.expectEqualStrings("applied", j.text(forwarded_receipt, "outcome"));
    const replied_receipt = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = j.text(replied, "id"), .operationId = "markdown-reply" }));
    try std.testing.expectEqualStrings("applied", j.text(replied_receipt, "outcome"));
    const legacy_reply = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.reply", .account = account, .messageId = "original" }));
    try std.testing.expectEqualStrings("plain", j.text(legacy_reply, "bodyFormat"));
    const legacy = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .bodyText = "**literal**" } }));
    const legacy_preview = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.preview", .account = account, .draftId = j.text(legacy, "id") }));
    try std.testing.expectEqualStrings("**literal**", j.text(legacy_preview, "plainText"));
    try std.testing.expect(j.get(legacy_preview, "bodyHtml") == null);
    try std.testing.expectError(error.DraftNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "draft.preview", .account = "work@example.com", .draftId = id })));
    const recovery = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.recovery-save", .account = account, .draft = .{ .bodyFormat = "markdown", .recoveryFields = [_][]const u8{ "unfinished", "", "", "Recovery", "**Retained** source" } } }));
    const recovery_read = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = j.text(recovery, "id") }));
    try std.testing.expectEqualStrings("markdown", j.text(recovery_read, "bodyFormat"));
    const recovery_preview = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.preview", .account = account, .draftId = j.text(recovery, "id") }));
    try std.testing.expect(std.mem.indexOf(u8, j.text(recovery_preview, "bodyHtml"), "<strong>Retained</strong>") != null);
    try std.testing.expectError(error.UnfinishedDraft, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = j.text(recovery, "id"), .operationId = "recovery-send" })));
    session.options.fixture_scenario = "unknown-send";
    const unknown_source: t.Draft = .{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "**Unknown**", .bodyFormat = .markdown };
    const unknown = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.send", .account = account, .draft = unknown_source, .operationId = "markdown-unknown" }));
    const replay = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.send", .account = account, .draft = unknown_source, .operationId = "markdown-replay" }));
    try std.testing.expectEqualStrings("unknown", j.text(unknown, "outcome"));
    try std.testing.expectEqualStrings(j.text(unknown, "id"), j.text(replay, "id"));
    var different_format = unknown_source;
    different_format.bodyFormat = .plain;
    try std.testing.expectError(error.OperationConflict, session.dispatch(a, try j.value(a, .{ .cmd = "mail.send", .account = account, .draft = different_format, .operationId = "markdown-unknown" })));
    try std.testing.expectError(error.InvalidBodyFormat, decodeDraft(a, try j.value(a, .{ .bodyFormat = "html" })));
}

test "wishlist: body search pagination binds changing body residency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/body-search", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    for (0..3) |i| try store.put(.{ .id = try std.fmt.allocPrint(a, "m{d}", .{i}), .threadId = "t", .subject = "needle", .bodyText = if (i < 2) "A unique needle" else "", .receivedAt = @intCast(i) }, i < 2);
    var body_request = try j.value(a, .{ .query = "body:needle", .limit = @as(u8, 1) });
    var metadata_request = try j.value(a, .{ .query = "subject:needle", .limit = @as(u8, 1) });
    const body = try Session.cacheSearch(a, &store, body_request, std.testing.allocator);
    const metadata = try Session.cacheSearch(a, &store, metadata_request, std.testing.allocator);
    try body_request.object.put(a, "cursor", .{ .string = try j.required(body, "nextCursor") });
    try metadata_request.object.put(a, "cursor", .{ .string = try j.required(metadata, "nextCursor") });
    const generation = store.state.generation;
    try store.put(.{ .id = "m2", .threadId = "t", .subject = "needle", .bodyText = "Newly cached needle", .receivedAt = 2 }, true);
    try std.testing.expectEqual(generation, store.state.generation);
    try std.testing.expectError(error.InvalidCursor, Session.cacheSearch(a, &store, body_request, std.testing.allocator));
    _ = try Session.cacheSearch(a, &store, metadata_request, std.testing.allocator);
}

test "fetch progress: fixture metadata bodies then cache hits and wrapper ownership" {
    const Recorder = struct {
        values: [16]t.FetchProgress = undefined,
        count: usize = 0,
        fn report(ctx: *anyopaque, value: t.FetchProgress) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.count < self.values.len) {
                self.values[self.count] = value;
                self.count += 1;
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/progress", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    var recorder: Recorder = .{};
    const sink: t.ProgressSink = .{ .ctx = &recorder, .reportFn = Recorder.report };
    const request = "{\"cmd\":\"mail.refresh\",\"account\":\"personal@example.com\",\"label\":\"INBOX\",\"limit\":2}";
    const raw = try session.client().callWithProgress(a, request, sink);
    const reply = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
    try std.testing.expect(try j.boolean(reply, "ok", false));
    try std.testing.expectEqual(@as(usize, 6), recorder.count);
    for (recorder.values[0..6], [_]usize{ 0, 1, 2, 0, 1, 2 }, 0..) |value, completed, index| {
        try std.testing.expectEqual(if (index < 3) t.FetchPhase.metadata else t.FetchPhase.bodies, value.phase);
        try std.testing.expectEqual(completed, value.completed);
        try std.testing.expectEqual(@as(usize, 2), value.total);
    }
    try std.testing.expect(session.progress_sink == null);
    const original_root = session.cache_root;
    recorder.count = 0;
    _ = try session.client().callWithProgress(a, request, sink);
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    try std.testing.expectEqualStrings(root, session.cache_root);
    try std.testing.expectEqual(original_root.ptr, session.cache_root.ptr);
    _ = try session.client().callCached(a, "{\"cmd\":\"mail.list\",\"account\":\"personal@example.com\",\"label\":\"INBOX\",\"limit\":2}");
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
}

test "cache windows: adjacent IDs survive generation changes and bounded eviction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/windows", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true, .metadata_limit = 5 });
    defer store.close();
    for (0..5) |i| try store.put(.{ .id = try std.fmt.allocPrint(a, "m{d}", .{i}), .threadId = "t", .subject = "needle", .receivedAt = @intCast(i) }, false);
    const before = try j.value(a, .{ .beforeMessageId = "m2", .limit = @as(u8, 2) });
    var result = try Session.cachedList(a, &store, before);
    try std.testing.expectEqualStrings("m4", j.text((try array(result, "messages"))[0], "id"));
    try std.testing.expectEqualStrings("m3", j.text((try array(result, "messages"))[1], "id"));
    try store.put(.{ .id = "m5", .threadId = "t", .subject = "needle", .receivedAt = 5 }, false);
    store.state.generation += 1;
    result = try Session.cachedList(a, &store, before);
    try std.testing.expectEqualStrings("m3", j.text((try array(result, "messages"))[1], "id"));
    const evicted = try j.value(a, .{ .beforeMessageId = "m0", .boundaryReceivedAt = @as(i64, 0), .limit = @as(u8, 2) });
    result = try Session.cachedList(a, &store, evicted);
    try std.testing.expect(try j.boolean(result, "boundaryFallback", false));
    try std.testing.expectEqualStrings("m1", j.text((try array(result, "messages"))[1], "id"));
    try std.testing.expectError(error.CacheBoundaryGone, Session.cachedList(a, &store, try j.value(a, .{ .beforeMessageId = "m0" })));
    const after = try j.value(a, .{ .afterMessageId = "m3", .limit = @as(u8, 2) });
    result = try Session.cacheSearch(a, &store, after, std.testing.allocator);
    try std.testing.expectEqualStrings("m2", j.text((try array(result, "messages"))[0], "id"));
    try std.testing.expectEqualStrings("m1", j.text((try array(result, "messages"))[1], "id"));
}
