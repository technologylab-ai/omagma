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
const conversation_draft = @import("conversation_draft.zig");
const conversation_source = @import("conversation_source.zig");
const draft_codec = @import("draft_codec.zig");
const draft_summary = @import("draft_summary.zig");
const gmail_decode = @import("gmail_decode.zig");
const mail_limits = @import("mail_limits.zig");
const mail_value = @import("mail_response_value.zig");
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
    return @import("send_outcome.zig").payload(a, draft, account, if (calendar) |ics| try calendarIdentity(a, ics) else null);
}
fn operationDigest(a: std.mem.Allocator, draft: t.Draft, account: []const u8, calendar: ?[]const u8) ![64]u8 {
    return @import("send_outcome.zig").digest(a, draft, account, if (calendar) |ics| try calendarIdentity(a, ics) else null);
}
fn requireReviewedDigest(request: Value, digest: []const u8) !void {
    if (j.get(request, "expectedContentDigest")) |value| {
        const expected = try j.string(value);
        if (expected.len != 64) return error.InvalidContentDigest;
        for (expected) |byte| if (!std.ascii.isHex(byte)) return error.InvalidContentDigest;
        if (!std.mem.eql(u8, expected, digest)) return error.ReviewedDraftChanged;
    }
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
    access_cache: @import("session_cache.zig").Cache = .{},
    cache_root: []const u8,
    env: *const std.process.Environ.Map,
    meter: ?*@import("capped_allocator.zig").CappedAllocator = null,
    progress_sink: ?t.ProgressSink = null,
    vault_owner: ?*@import("vault_owner.zig").Owner = null,
    fn storeAccessOpen(context: *anyopaque, a: std.mem.Allocator, account: []const u8, readonly: bool) anyerror!storage.Store {
        const self: *Session = @ptrCast(@alignCast(context));
        return self.openStore(a, account, readonly);
    }
    pub fn openStore(s: *Session, a: std.mem.Allocator, account: []const u8, readonly: bool) !storage.Store {
        if (s.vault_owner) |owner| return storage.Store.openVault(s.io, a, try owner.borrowAccount(account), s.options, readonly);
        return if (readonly) storage.Store.openCached(s.io, a, s.cache_root, account, s.options) else storage.Store.open(s.io, a, s.cache_root, account, s.options);
    }
    fn refreshActive(s: *Session, account: []const u8) !bool {
        // The daemon serializes all jobs; no plaintext refresh lease exists.
        if (s.vault_owner != null) return false;
        return storage.refreshActive(s.io, s.cache_root, account, s.options);
    }
    pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, options: t.Options) !Session {
        var s: Session = undefined;
        try s.initInto(io, a, env, options, null);
        return s;
    }
    /// Initialize a heap-owned Session directly. Debug's return-by-value copies
    /// of the large inline Config exceed a bounded daemon worker's 1 MiB stack.
    /// A provided authenticated config bypasses every plaintext config read.
    pub fn initInto(s: *Session, io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, options: t.Options, provided: ?*const Config) !void {
        s.io = io;
        s.allocator = a;
        s.options = options;
        s.env = env;
        s.meter = null;
        s.progress_sink = null;
        s.vault_owner = null;
        s.access_cache = .{};
        const home = env.get("HOME") orelse return error.HomeRequired;
        var parse_arena = std.heap.ArenaAllocator.init(a);
        defer parse_arena.deinit();
        const pa = parse_arena.allocator();
        // All native entry points must honor activation, including internal
        // callers which bypass the CLI. Only an authenticated daemon-owned
        // config or isolated fixtures may bypass this routing guard.
        if (provided == null and !options.fixtures and try @import("vault_activation.zig").load(io, pa, env) != null) return error.BackendRequired;
        if (provided) |config| {
            s.config = config.*;
        } else {
            try s.config.defaults(home);
            if (options.fixtures) for (s.config.accounts[0..s.config.count]) |*account| {
                account.enabled = true;
            };
            const cfg = options.config_file orelse if (!options.fixtures) try std.fmt.allocPrint(pa, "{s}/omagma/config.json", .{env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(pa, "{s}/.config", .{home})}) else null;
            if (cfg) |path| {
                const buf = try pa.alloc(u8, 16 * 1024);
                try s.config.load(io, path, pa, buf);
            }
        }
        s.cache_root = try a.dupe(u8, options.cache_dir orelse try std.fmt.allocPrint(pa, "{s}/omagma/terminal", .{env.get("XDG_CACHE_HOME") orelse try std.fmt.allocPrint(pa, "{s}/.cache", .{home})}));
        errdefer a.free(s.cache_root);
        if (options.metadata_limit == 0 or options.metadata_limit > t.Limits.metadata_hard or options.disk_limit < 64 * 1024 or options.disk_limit > t.Limits.disk_hard) return error.InvalidCacheLimit;
        if (options.body_prefetch_limit > 64) return error.InvalidPrefetchLimit;
        if (!std.mem.eql(u8, options.fixture_scenario, "normal") and !options.fixtures) return error.FixtureOptionRequiresFixtures;
        if (options.fixture_root != null and !options.fixtures) return error.FixtureOptionRequiresFixtures;
        if (options.fixtures and std.mem.indexOfScalar(u8, options.fixture_scenario, '/') != null) return error.InvalidFixtureScenario;
    }
    pub fn deinit(s: *Session) void {
        s.access_cache.clear();
        s.config.runtime_access_cache = null;
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
        if (s.vault_owner) |owner| return owner.cacheStamp(account);
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
        // Only the parent retains access tokens between jobs. The progress
        // wrapper borrows that cache and wipes its incidental struct copy.
        worker.access_cache.clear();
        worker.config.runtime_access_cache = &s.access_cache;
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
        // Attach only at the caller-stable address, after any Config reload.
        s.config.runtime_access_cache = &s.access_cache;
        return s.executeMode(out_allocator, raw, false);
    }
    fn executeMode(s: *Session, out_allocator: std.mem.Allocator, raw: []const u8, cached_only: bool) ![]const u8 {
        // Keep the Session and token cache on their original lifetime. Only
        // this operation borrows expandable, wiped storage, and response bytes
        // are copied to the caller before its arena is released on every exit.
        var arena = std.heap.ArenaAllocator.init(@import("send_memory.zig").operationBacking(s.allocator, raw, cached_only));
        defer arena.deinit();
        const a = arena.allocator();
        const request_limit = @import("send_memory.zig").requestLimit(raw);
        const request = if (raw.len > request_limit or !boundedJson(raw)) null else std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_if_needed, .max_value_len = request_limit, .duplicate_field_behavior = .@"error" }) catch null;
        if (request == null or request.? != .object) return failure(out_allocator, .null, "", "InvalidRequest", "Expected a bounded JSON object");
        var req = request.?;
        if (cached_only) {
            if (!@import("client_contract.zig").cachedRequest(req)) return error.CacheUnsupported;
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
        // A plaintext CLI/TUI may predate explicit vault activation. Check
        // its next operation too, before any source/cache/provider access.
        // Malformed or unsafe markers fail closed with correlated errors.
        if (!s.options.fixtures and s.vault_owner == null) {
            const active = @import("vault_activation.zig").load(s.io, a, s.env) catch |err| return failureForError(out_allocator, id, account, err);
            if (active != null) return failureForError(out_allocator, id, account, error.BackendRequired);
        }
        const data = s.dispatch(a, req) catch |err| {
            // Internal cached callers own a cancelable lifetime. Keep the
            // cancellation signal out of protocol normalization for that path.
            if (cached_only and err == error.Canceled) return err;
            return failureForError(out_allocator, id, account, reconciliationFailure(req, err));
        };
        return successResponse(out_allocator, id, account, j.text(req, "cmd"), !@import("client_contract.zig").readOnlyRequest(req), s.options.fixtures, data);
    }
    fn reconciliationFailure(req: Value, err: anyerror) anyerror {
        if (!std.mem.eql(u8, j.text(req, "cmd"), "invitation.inspect") or @import("client_contract.zig").readOnlyRequest(req)) return err;
        return switch (err) {
            error.Canceled, error.Timeout, error.DeadlineExceeded, error.OutOfMemory, error.VaultOperationCanceled => error.UnknownOutcome,
            else => err,
        };
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
    fn successResponse(a: std.mem.Allocator, id: Value, account: []const u8, cmd: []const u8, may_write: bool, fixtures: bool, data: Value) ![]const u8 {
        return j.encodeAlloc(a, .{ .version = @as(u8, 1), .id = id, .ok = true, .account = account, .data = data }, .{}) catch |err| {
            if (!fixtures and may_write and std.mem.eql(u8, cmd, "invitation.inspect")) return failureForError(a, id, account, error.UnknownOutcome);
            if (!fixtures) for ([_][]const u8{ "mail.batch", "mail.undo", "contacts.upsert", "mail.mark", "mail.archive", "mail.trash", "mail.restore", "mail.send", "draft.send", "queue.process", "queue.send-now", "invitation.reply", "labels.create", "labels.rename", "labels.delete", "labels.color", "calendar.apply", "calendar.import", "calendar.update", "calendar.cancel", "calendar.event-apply", "calendar.event-retry", "draft.gmail-save" }) |mutation| {
                if (std.mem.eql(u8, cmd, mutation)) return failureForError(a, id, account, error.UnknownOutcome);
            };
            return err;
        };
    }
    fn errorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.PermissionDenied => "Permission denied: check the account capability and the agent's access to Omagma files and network",
            error.CredentialStorageAccessDenied => "The OS or sandbox denied access to the configured private credential files",
            error.KeyringUnavailable => "The selected system credential store is unavailable in this process session; use an unlocked session or explicitly migrate to file storage",
            error.UnknownAccount => "Choose an explicitly configured account",
            error.FollowUpMetadataUnavailableOffline => "Message metadata is no longer cached; reconnect to create this follow-up. Existing reminders remain available offline.",
            error.UnknownOutcome => "Outcome is unknown; do not automatically retry",
            error.OperationConflict => "This operation identity was already used for different content",
            error.ReviewedDraftChanged => "The draft changed after review; review its current recipients, content and size before sending",
            error.ArchivedDraftReadOnly => "This retained sent source is read-only; use draft.clone to create a new editable draft",
            error.CloneRequiresSettledSource => "Only a settled sent source can be cloned; finish or resolve the source draft's pending work first",
            error.ArchivedSourceDeleted => "The retained source was explicitly deleted; its operation receipt and replay protection remain available",
            error.DiskQuotaExceeded => "The account disk quota is full; review history.drafts and explicitly delete retained sources, discard unused files, or increase the disk quota. Operation receipts and unknown outcomes remain protected.",
            error.CacheBusy => "Another client is using this account cache; retry later",
            error.UnknownQueryOperator, error.InvalidQueryDate, error.InvalidQueryValue, error.InvalidQuery, error.TimezoneUnavailable, error.TimezoneRangeUnavailable => cache_query.diagnostic(err),
            else => @errorName(err),
        };
    }
    fn preferences(s: *Session, a: std.mem.Allocator, req: Value, write: bool) !Value {
        if (s.config.credential_store != .vault) return error.VaultRequired;
        const provider = s.config.runtime_provider orelse return error.VaultLocked;
        if (!write) {
            var result = j.object(a);
            const bytes = try provider.read(.preferences, .{}) orelse {
                try result.object.put(a, "preferences", .null);
                return result;
            };
            try result.object.put(a, "preferences", try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_if_needed, .max_value_len = @import("../native_identity.zig").max_preferences_bytes }));
            return result;
        }
        const input = j.get(req, "preferences") orelse return error.MissingField;
        if (input != .object) return error.InvalidField;
        const bytes = try j.encodeAlloc(a, input, .{});
        if (bytes.len > @import("../native_identity.zig").max_preferences_bytes) return error.UiPreferencesTooLarge;
        // The provider validates the complete typed preferences schema before
        // publication. Avoid a second large Preferences value on this worker.
        try provider.apply(&.{.{ .kind = .preferences, .value = bytes }});
        return j.value(a, .{ .saved = true });
    }
    fn gmailDraftJob(s: *Session, a: std.mem.Allocator, account: []const u8, req: Value) anyerror!Value {
        return @import("draft_gmail_commands.zig").run(s, a, account, req);
    }
    fn followUpSnapshot(s: *Session, a: std.mem.Allocator, account: []const u8, req: Value) !t.Message {
        const gmail = @import("gmail.zig");
        try s.capability(a, account, req, "mail-read");
        const id = try j.required(req, "messageId");
        if (s.options.fixtures) {
            const source = try s.fixture(a, account);
            try s.fixtureGate(a, source, req);
            var peer: FixtureRemote = .{ .session = s, .source = source };
            return gmail.readAuthorizedMetadata(a, account, &.{"mail-read"}, peer.transport(), id);
        }
        var network: gmail.NetworkSession = undefined;
        try network.initWithAllocator(s.io, a, s.allocator, &s.config, account, "mail.read", req);
        defer network.close();
        return gmail.readAuthorizedMetadata(a, account, &.{"mail-read"}, network.transport(), id);
    }
    fn followUps(s: *Session, a: std.mem.Allocator, account: []const u8, req: Value) !Value {
        const follow_up = @import("follow_up.zig");
        const cmd = j.text(req, "cmd");
        const reading = std.mem.eql(u8, cmd, "reminder.list");
        if (!reading and !std.mem.eql(u8, cmd, "reminder.set") and !std.mem.eql(u8, cmd, "reminder.done")) return error.UnknownCommand;
        if (!reading and try j.boolean(req, "cacheOnly", false)) return error.CachedMutationDenied;
        var store = try s.openStore(a, account, reading);
        defer store.close();
        var state = try follow_up.read(&store, a, account);
        if (reading) {
            const entries = try follow_up.sorted(a, state);
            const messages = try a.alloc(Value, entries.len);
            for (entries, 0..) |entry, i| {
                const snapshot: t.Message = if (store.find(entry.messageId)) |cached| cached.message else .{ .id = entry.messageId, .threadId = entry.threadId, .subject = entry.subject, .from = .{ .address = "", .name = entry.counterpart } };
                messages[i] = try j.value(a, snapshot);
                try messages[i].object.put(a, "followUpDate", .{ .string = entry.dueDate });
                try messages[i].object.put(a, "followUpVersion", .{ .integer = entry.version });
            }
            return j.value(a, .{ .entries = entries, .messages = messages, .revision = state.revision, .local = true, .cached = true });
        }
        const message_id = try j.required(req, "messageId");
        try @import("../bounded.zig").identifier(message_id);
        const expected = try j.integer(req, "expectedVersion", -1);
        if (expected < 0) return error.FollowUpVersionRequired;
        if (std.mem.eql(u8, cmd, "reminder.done")) {
            try state.done(message_id, expected);
            try follow_up.write(&store, a, state);
            return j.value(a, .{ .done = true, .revision = state.revision, .messageId = message_id });
        }
        const due = try j.required(req, "dueDate");
        try follow_up.date(due);
        const prior = state.find(message_id);
        if (expected != (if (prior) |entry| entry.version else @as(i64, 0))) return error.FollowUpChanged;
        if (prior == null and state.entries.len == follow_up.limit) return error.FollowUpLimitReached;
        var snapshot: ?t.Message = if (store.find(message_id)) |entry| entry.message else for (store.state.outbox) |message| {
            if (std.mem.eql(u8, message.id, message_id)) break message;
        } else null;
        if (prior == null and snapshot == null) {
            // A provider search/thread can display an older message which a
            // full metadata quota immediately evicts. Verify its exact account
            // and ID without requiring it to be retained in the mail cache.
            // Never accept a client-supplied subject/sender snapshot as proof.
            store.release();
            snapshot = @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), followUpSnapshot, .{ s, a, account, req }) catch |err| switch (err) {
                error.TransientFailure, error.NetworkUnreachable, error.ConnectionRefused, error.ConnectionTimedOut, error.Timeout => return error.FollowUpMetadataUnavailableOffline,
                else => return err,
            };
            try s.reopenBody(a, &store);
            state = try follow_up.read(&store, a, account);
            // set rechecks the version/cap after the unlocked provider phase.
        }
        const entry = try state.set(a, message_id, due, expected, snapshot);
        try follow_up.write(&store, a, state);
        return j.value(a, .{ .entry = entry, .revision = state.revision, .local = true });
    }
    fn dispatch(s: *Session, a: std.mem.Allocator, req: Value) !Value {
        const cmd = try j.required(req, "cmd");
        if (std.mem.eql(u8, cmd, "preferences.get") or std.mem.eql(u8, cmd, "preferences.set")) return s.preferences(a, req, std.mem.eql(u8, cmd, "preferences.set"));
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
            const registry = if (!s.options.fixtures) try @import("auth.zig").loadConfigured(s.io, a, &s.config, if (s.config.credential_store == .vault) "" else try j.required(req, "grantFile")) else @import("auth.zig").Registry{};
            for (s.config.accounts[0..s.config.count]) |*account| {
                const grant = @import("auth.zig").find(&registry, account.address.slice());
                try list.append(a, .{ .address = account.address.slice(), .enabled = account.enabled, .senderName = account.sender_name.slice(), .signature = account.signature.slice(), .capabilities = if (s.options.fixtures and !s.scenario("readonly")) (if (s.scenario("calendar-readonly")) &.{ "mail-read", "mail-modify", "mail-send", "contacts-read", "contacts-write", "calendar-rsvp", "calendar-read", "calendar-freebusy" } else &.{ "mail-read", "mail-modify", "mail-send", "contacts-read", "contacts-write", "calendar-rsvp", "calendar-read", "calendar-write-shared", "calendar-freebusy" }) else if (grant) |g| if (g.enabled) g.capabilities else &.{} else &.{"mail-read"} });
            }
            return j.value(a, .{ .accounts = list.items });
        }
        const address = try j.required(req, "account");
        const index = s.config.index(address) orelse return error.UnknownAccount;
        if (!s.config.accounts[index].enabled) return error.AccountDisabled;
        try recipients.validateAddress(address);
        if ((j.text(req, "beforeMessageId").len != 0 or j.text(req, "afterMessageId").len != 0) and !try j.boolean(req, "cacheOnly", false) and !(std.mem.eql(u8, cmd, "mail.thread") and try j.boolean(req, "progressive", false))) return error.CacheWindowRequiresCached;
        if (std.mem.startsWith(u8, cmd, "auth.")) {
            if (s.options.fixtures) {
                if (!std.mem.eql(u8, cmd, "auth.status")) return error.FixtureOnly;
                return j.value(a, .{ .configured = true, .fixture = true });
            }
            const result = try @import("auth.zig").run(s.io, a, &s.config, s.env, req);
            if (!std.mem.eql(u8, cmd, "auth.status")) if (s.config.runtime_access_cache) |cache| cache.invalidateAccount(index);
            return result;
        }
        if (std.mem.eql(u8, cmd, "cache.refresh-status")) return j.value(a, .{ .refreshInProgress = try s.refreshActive(address) });
        if (std.mem.eql(u8, cmd, "browser.open")) {
            const target = try @import("../open_target.zig").makeUrl(&s.config.accounts[index], try j.required(req, "url"));
            if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, &s.config.accounts[index], &target);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .url = target.url.slice(), .profile = target.profile_arg.slice() });
        }
        if (std.mem.eql(u8, cmd, "calendar.open") or std.mem.eql(u8, cmd, "calendar.event-open")) {
            return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), calendarBrowserJob, .{ s, a, req, index });
        }
        if (std.mem.eql(u8, cmd, "attachment.open")) {
            const path = try j.required(req, "path");
            if (path.len == 0 or path.len > 4096) return error.InvalidAttachmentPath;
            try recipients.validateHeader(path);
            if (!s.options.fixtures) try @import("../open_target.zig").openSavedAttachment(s.io, a, path);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures });
        }
        if (std.mem.startsWith(u8, cmd, "calendar.")) {
            return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), calendarJob, .{ s, a, req });
        }
        if (std.mem.startsWith(u8, cmd, "reminder.")) return s.followUps(a, address, req);
        if (std.mem.startsWith(u8, cmd, "draft.gmail-")) return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(@import("send_memory.zig").seconds(cmd)), gmailDraftJob, .{ s, a, address, req });
        if (std.mem.eql(u8, cmd, "cache.activity") or (try j.boolean(req, "cacheOnly", false) and !std.mem.eql(u8, cmd, "invitation.inspect"))) return s.cachedDispatch(a, address, req);
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
        var store = try s.openStore(a, address, std.mem.eql(u8, cmd, "draft.measure") or (std.mem.eql(u8, cmd, "invitation.inspect") and try j.boolean(req, "cacheOnly", false)));
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
            return j.value(a, .{ .cleared = true, .draftsPreserved = true, .operationsPreserved = true, .followUpsPreserved = true });
        }
        if (std.mem.eql(u8, cmd, "operation.list")) return j.value(a, .{ .operations = store.state.operations });
        if (std.mem.eql(u8, cmd, "history.operations") or std.mem.eql(u8, cmd, "history.drafts") or std.mem.eql(u8, cmd, "history.queues")) {
            const limit = try j.integer(req, "limit", 50);
            if (limit < 1 or limit > 100) return error.InvalidPageLimit;
            return @import("operation_history.zig").list(&store, a, if (std.mem.eql(u8, cmd, "history.operations")) .operation else if (std.mem.eql(u8, cmd, "history.drafts")) .draft else .queue, j.text(req, "cursor"), @intCast(limit));
        }
        if (std.mem.eql(u8, cmd, "history.delete-source")) {
            if (!try j.boolean(req, "confirm", false)) return error.HistoryDeletionRequiresConfirmation;
            const draft_id = try j.required(req, "draftId");
            const discard_files = try j.boolean(req, "discardFiles", false);
            const history = @import("operation_history.zig");
            if (try history.source(&store, a, draft_id) == null and try history.immutableSource(&store, draft_id)) try history.compact(&store, true);
            const deleted = try history.deleteSource(&store, draft_id);
            return j.value(a, .{ .deleted = deleted, .filesDeleted = if (discard_files) try @import("operation_history.zig").pruneSourceFiles(&store, draft_id) else @as(usize, 0), .receiptPreserved = true });
        }
        if (std.mem.eql(u8, cmd, "operation.read")) {
            const operation_id = try j.required(req, "operationId");
            if (try store.findOperation(a, operation_id)) |operation| return j.value(a, operation);
            return error.OperationNotFound;
        }
        if (std.mem.eql(u8, cmd, "draft.list")) {
            const limit = try j.integer(req, "limit", 100);
            if (limit < 1 or limit > 100) return error.InvalidPageLimit;
            return draft_summary.list(a, store.state.drafts, store.state.draftLinks, j.text(req, "cursor"), @intCast(limit));
        }
        if (std.mem.eql(u8, cmd, "draft.queue") or std.mem.startsWith(u8, cmd, "queue.")) return s.queuedSend(a, &store, req);
        if (std.mem.eql(u8, cmd, "draft.read")) return @import("draft_gmail_commands.zig").readResponse(a, &store, try store.draft(try j.required(req, "draftId")));
        if (std.mem.eql(u8, cmd, "draft.clone")) {
            const draft_id = try j.required(req, "draftId");
            try guardRecoveryCopy(&store, draft_id);
            if (!try @import("operation_history.zig").cloneableSource(&store, draft_id)) return error.CloneRequiresSettledSource;
            const source = try store.draft(draft_id);
            return draft_summary.savedResponse(a, try store.putDraft(source, null), false);
        }
        if (std.mem.eql(u8, cmd, "draft.open-preview")) {
            try s.capability(a, address, req, "mail-read");
            const draft = try store.draft(try j.required(req, "draftId"));
            try validateDraft(draft, false);
            const prepared = try markdown_mail.prepare(a, draft);
            var header_draft = draft;
            if (header_draft.from == null) header_draft.from = .{ .address = address };
            const preview = @import("preview_file.zig");
            const written = if (store.vault != null) try preview.writePrivateExport(&store, a, s.env, prepared, header_draft) else plain: {
                try store.reserveBytes(try preview.byteSizeWithStore(&store, prepared, header_draft));
                try store.save();
                break :plain try preview.writePreviewWithStore(&store, a, prepared, header_draft);
            };
            const target = if (store.vault) |vault|
                try @import("../open_target.zig").makeVaultPreview(&s.config.accounts[index], written.path, vault.owner.key.vault_id, vault.entry.index.bytes)
            else
                try @import("../open_target.zig").makePreview(&s.config.accounts[index], written.path);
            if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, &s.config.accounts[index], &target);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .path = written.path, .url = target.url.slice(), .profile = target.profile_arg.slice() });
        }
        if (std.mem.eql(u8, cmd, "draft.preview")) {
            const draft = if (j.get(req, "draft")) |input| try decodeDraft(a, input) else try store.draft(try j.required(req, "draftId"));
            try validateDraft(draft, false);
            const prepared = try markdown_mail.prepare(a, draft);
            return j.value(a, .{ .bodyFormat = draft.bodyFormat, .bodyText = if (draft.recoveryFields) |fields| fields[4] else draft.bodyText, .plainText = prepared.plain, .bodyHtml = prepared.html });
        }
        if (std.mem.eql(u8, cmd, "draft.measure")) return @import("draft_measure_commands.zig").run(a, &store, req);
        if (std.mem.eql(u8, cmd, "draft.recovery-save")) {
            const acknowledgement_only = try j.boolean(req, "acknowledgementOnly", false);
            const previous_id = j.text(req, "draftId");
            const copy_source = if (j.get(req, "copyFromDraftId")) |value| (if (value == .null) "" else try j.required(req, "copyFromDraftId")) else "";
            const fork_if_settled = try j.boolean(req, "forkIfSettled", false);
            if (copy_source.len != 0) {
                if (previous_id.len != 0 or fork_if_settled) return error.InvalidRequest;
                try guardRecoveryCopy(&store, copy_source);
            }
            const source_id = if (copy_source.len != 0) copy_source else previous_id;
            const input = j.get(req, "draft") orelse return error.MissingField;
            const fields = try j.decode([]const []const u8, a, j.get(input, "recoveryFields") orelse return error.MissingField);
            if (fields.len != 5) return error.InvalidRecovery;
            for (fields, 0..) |field, i| if (field.len > (switch (i) {
                4 => t.Limits.compose_body_bytes,
                3 => mail_limits.subject_bytes,
                else => mail_limits.header_value_bytes,
            }) or !std.unicode.utf8ValidateSlice(field)) return error.InvalidRecovery;
            var clean = try j.copyObject(a, input);
            _ = clean.object.swapRemove("to");
            _ = clean.object.swapRemove("cc");
            _ = clean.object.swapRemove("bcc");
            _ = clean.object.swapRemove("recoveryFields");
            try clean.object.put(a, "subject", .{ .string = fields[3] });
            try clean.object.put(a, "bodyText", .{ .string = fields[4] });
            var draft = try decodeDraft(a, clean);
            if (j.get(input, "bodyFormat") == null and source_id.len != 0) draft.bodyFormat = (try store.draft(source_id)).bodyFormat;
            if (j.get(input, "includeOriginal") == null and source_id.len != 0) draft.includeOriginal = (try store.draft(source_id)).includeOriginal;
            if (j.get(input, "original") == null and source_id.len != 0) draft.original = (try store.draft(source_id)).original;
            try validateDraft(draft, false);
            draft.recoveryFields = fields;
            // The recovery body lives in the raw fields once, while the index
            // retains only its subject. Normal drafts keep bodyText as before.
            draft.bodyText = "";
            const forked = previous_id.len != 0 and fork_if_settled and try recoveryForkAllowed(&store, previous_id);
            const saved = if (copy_source.len != 0 or forked) try store.putRecoveryCopy(draft, source_id) else try store.putDraft(draft, if (previous_id.len != 0) previous_id else null);
            var response = try draft_summary.savedResponse(a, saved, acknowledgement_only);
            if (forked) try response.object.put(a, "forkedFrom", .{ .string = previous_id });
            if (copy_source.len != 0) try response.object.put(a, "copiedFrom", .{ .string = copy_source });
            if (copy_source.len != 0 or forked) if (try @import("operation_history.zig").gmailLink(&store, a, saved.id)) |link| {
                try response.object.put(a, "gmailLink", try j.value(a, link));
                try response.object.put(a, "contentDigest", .{ .string = try a.dupe(u8, &(try @import("draft_link.zig").contentDigest(a, saved, address))) });
            };
            return response;
        }
        if (std.mem.eql(u8, cmd, "draft.discard")) {
            try store.discardDraft(try j.required(req, "draftId"));
            return j.value(a, .{ .discarded = true });
        }
        if (std.mem.eql(u8, cmd, "draft.create") or std.mem.eql(u8, cmd, "draft.update")) {
            const acknowledgement_only = try j.boolean(req, "acknowledgementOnly", false);
            const input = j.get(req, "draft") orelse return error.MissingField;
            var draft = try decodeDraft(a, input);
            if (std.mem.eql(u8, cmd, "draft.update") and j.get(input, "bodyFormat") == null) draft.bodyFormat = (try store.draft(try j.required(req, "draftId"))).bodyFormat;
            if (std.mem.eql(u8, cmd, "draft.update") and j.get(input, "includeOriginal") == null) draft.includeOriginal = (try store.draft(try j.required(req, "draftId"))).includeOriginal;
            if (std.mem.eql(u8, cmd, "draft.update") and j.get(input, "original") == null) draft.original = (try store.draft(try j.required(req, "draftId"))).original;
            try validateDraft(draft, false);
            return draft_summary.savedResponse(a, try store.putDraft(draft, if (std.mem.eql(u8, cmd, "draft.update")) try j.required(req, "draftId") else null), acknowledgement_only);
        }
        if (std.mem.eql(u8, cmd, "mail.send") or std.mem.eql(u8, cmd, "draft.send")) {
            if (std.mem.eql(u8, cmd, "draft.send")) {
                const draft_id = try j.required(req, "draftId");
                if (try @import("operation_history.zig").source(&store, a, draft_id) != null) {
                    try s.capability(a, address, req, "mail-send");
                    const old = (try store.findOperation(a, try j.required(req, "operationId"))) orelse return error.ArchivedDraftReadOnly;
                    if (!std.mem.eql(u8, old.draftId, draft_id) or old.icalendar.len != 0 or old.kind.len != 0) return error.OperationConflict;
                    try requireReviewedDigest(req, old.hash);
                    return mutationReceipt(a, old);
                }
            }
            const draft = if (std.mem.eql(u8, cmd, "draft.send")) try store.draft(try j.required(req, "draftId")) else try decodeDraft(a, j.get(req, "draft") orelse return error.MissingField);
            return s.send(a, &store, req, draft, null, false);
        }
        if (std.mem.eql(u8, cmd, "mail.reply")) {
            const format = try requestBodyFormat(req);
            const preserve = try j.boolean(req, "preserveFormatting", false);
            // Legacy immutable caches predate CID metadata. A formatted draft
            // always captures the provider's current FULL source read-only.
            const message = try s.readMessage(a, &store, try j.required(req, "messageId"), req, !preserve);
            try conversation_draft.requireBody(message);
            const original: ?t.Original = if (preserve) try s.captureOriginal(a, &store, req, message) else null;
            const aliases = if (!s.options.fixtures) try j.decode([]const []const u8, a, j.get(try s.remote(a, address, "accounts.aliases", req), "aliases") orelse return error.InvalidProviderResponse) else &.{};
            const d = try conversation_draft.reply(a, message, .{ .account = address, .aliases = aliases, .all = try j.boolean(req, "all", false), .format = format, .original = original });
            try validateDraft(d, false);
            if (preserve) try conversation_source.validateFormatting(@import("send_memory.zig").commandBacking(s.allocator, cmd), d);
            if (!store.lockHeld) try s.reopenBody(a, &store);
            return mail_value.borrowed(a, try store.putDraft(d, null));
        }
        if (std.mem.eql(u8, cmd, "mail.forward")) {
            const format = try requestBodyFormat(req);
            const omit = try j.boolean(req, "omitAttachments", false);
            if (try j.boolean(req, "original", false)) {
                if (omit) return error.InvalidForwardOptions;
                return s.forwardRaw(a, &store, req, format);
            }
            const preserve = try j.boolean(req, "preserveFormatting", false);
            if (omit and preserve) return error.InvalidForwardOptions;
            const source_id = try j.required(req, "messageId");
            // Older successful bodies could omit empty files. Refresh them
            // once before claiming that a forward preserves every attachment.
            const allow_cached = !preserve and (omit or !store.bodyNeedsUpgrade(source_id));
            const message = s.readMessage(a, &store, source_id, req, allow_cached) catch |err| {
                if (!allow_cached and !preserve and store.bodyNeedsUpgrade(source_id) and (err == error.NetworkFailure or err == error.LiveProviderNotReady)) return error.CachedAttachmentsNeedRefresh;
                return err;
            };
            try conversation_draft.requireBody(message);
            const prepared = if (omit) message else try s.prepareForwardAttachments(a, &store, req, message, preserve);
            var source: ConversationAttachments = .{ .session = s, .store = &store, .request = req };
            const draft = try conversation_source.forward(a, prepared, .{ .format = format, .preserve_formatting = preserve, .omit_attachments = omit, .temporary_allocator = @import("send_memory.zig").commandBacking(s.allocator, cmd) }, source.adapter());
            if (!store.lockHeld) try s.reopenBody(a, &store);
            return mail_value.borrowed(a, try store.putDraft(draft, null));
        }
        if (std.mem.eql(u8, cmd, "mail.list") or std.mem.eql(u8, cmd, "mail.search") or std.mem.eql(u8, cmd, "mail.sync")) return s.listMail(a, &store, req);
        if (std.mem.eql(u8, cmd, "mail.compose-source")) {
            var message = try s.readMessage(a, &store, try j.required(req, "messageId"), req, false);
            // The chooser needs identity metadata, not embedded file bytes.
            // Preserve all options even if an ordinary source file is too
            // large to forward; only the chosen reply/forward enforces that
            // outgoing policy and captures its selected immutable resources.
            message.attachments = try draft_summary.attachmentMetadata(a, message.attachments);
            return mail_value.borrowed(a, message);
        }
        if (std.mem.eql(u8, cmd, "mail.read")) return mail_value.borrowed(a, try s.read(a, &store, try j.required(req, "messageId"), req));
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
                if (try j.boolean(result, "progressive", false)) return s.retainProgressiveThread(a, &store, result, expected);
                for (try array(result, "messages")) |v| {
                    const message = try j.decode(t.Message, a, v);
                    try store.rememberAttachments(message);
                    if (store.state.generation == expected) try store.put(message, true) else try retainReadBody(&store, message);
                }
                try store.save();
                return result;
            }
            const thread = try j.required(req, "threadId");
            const source = try s.fixtureProviderSource(a, &store);
            if (try j.boolean(req, "progressive", false)) if (try s.fixtureProgressiveThread(a, &store, source, req)) |result| return result;
            var messages: std.ArrayList(t.Message) = .empty;
            var thread_total: usize = 0;
            for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "threadId"), thread)) {
                thread_total += 1;
            };
            for (store.state.outbox) |entry| if (std.mem.eql(u8, entry.threadId, thread)) {
                thread_total += 1;
            };
            if (thread_total > 100) return error.ThreadTooLarge;
            var remaining: usize = t.Limits.thread_bytes;
            var partial = false;
            if (thread_total != 0) s.reportProgress(.bodies, 0, thread_total);
            for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "threadId"), thread)) {
                var scope = std.heap.ArenaAllocator.init(s.allocator);
                defer scope.deinit();
                var m = try s.normalize(scope.allocator(), source, v);
                if (store.find(m.id)) |existing| {
                    copyMembership(&m, existing.message);
                }
                const retained = try gmail_decode.retainThreadMessage(m, a, &remaining);
                partial = partial or retained.metadataPartial or retained.decodeWarning.len != 0;
                try store.rememberAttachments(retained);
                try store.put(retained, true);
                try messages.append(a, retained);
                s.reportProgress(.bodies, messages.items.len, thread_total);
            };
            for (store.state.outbox) |entry| if (std.mem.eql(u8, entry.threadId, thread)) {
                var scope = std.heap.ArenaAllocator.init(s.allocator);
                defer scope.deinit();
                if (try store.readOutboxWithAllocator(scope.allocator(), entry.id)) |sent| {
                    const retained = try gmail_decode.retainThreadMessage(sent, a, &remaining);
                    partial = partial or retained.metadataPartial or retained.decodeWarning.len != 0;
                    try messages.append(a, retained);
                }
                s.reportProgress(.bodies, messages.items.len, thread_total);
            };
            if (messages.items.len == 0) return error.MessageNotFound;
            std.mem.sort(t.Message, messages.items, {}, olderFirst);
            try store.save();
            return mail_value.borrowed(a, .{ .messages = messages.items, .partial = partial });
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
            for ([_][]const u8{ "attendee", "sourceHash" }) |field| if (j.get(req, field)) |value| if (value != .string) return error.InvalidRequest;
            if (j.get(req, "calendarId")) |value| try @import("calendar_types.zig").text(try j.string(value), 1024, false);
            const cache_only = try j.boolean(req, "cacheOnly", false);
            const reconcile = try j.boolean(req, "reconcile", false);
            if (reconcile and (cache_only or !std.mem.eql(u8, cmd, "invitation.inspect"))) return error.InvalidRequest;
            var m = if (cache_only) (try store.read(message_id)) orelse return error.CacheMiss else try s.read(a, &store, message_id, req);
            // Repair old metadata-only calendar attachments only when the
            // user explicitly inspects this mail. Cache browsing stays local.
            if (!cache_only and m.invitation == null) for (m.attachments) |part| {
                if (!@import("mime.zig").isCalendarPart(part.mimeType, part.filename)) continue;
                m = try s.readMessage(a, &store, message_id, req, false);
                break;
            };
            const ics = m.invitation orelse return error.NotInvitation;
            var invite: invitation.Invitation = .{};
            const inspecting = std.mem.eql(u8, cmd, "invitation.inspect");
            // Same reviewed operation returns its durable receipt before refreshing
            // identities or generating a new DTSTAMP. Never repeat an unknown send.
            if (!inspecting) if (try invitationReceipt(a, &store, ics, req)) |receipt| return s.syncInvitationCalendar(a, &store, ics, req, receipt);
            var aliases = try cachedAliases(a, &store);
            if (inspecting) {
                try invitation.parseDisplay(ics, address, aliases, &invite);
                if (!cache_only and invite.method == .request and invite.attendee.len == 0 and !invite.response_blocked and invite.additional_events == 0) {
                    // An explicit inspection may discover verified send-as aliases.
                    // A network failure still leaves this cached notice readable.
                    if (s.identities(a, &store, req, false)) |_| {
                        aliases = try cachedAliases(a, &store);
                        try invitation.parseDisplay(ics, address, aliases, &invite);
                    } else |_| {}
                }
            } else {
                _ = try s.identities(a, &store, req, false);
                aliases = try cachedAliases(a, &store);
                try invitation.parse(ics, address, aliases, &invite);
                const expected_attendee = j.text(req, "attendee");
                if (expected_attendee.len > 0 and !std.ascii.eqlIgnoreCase(expected_attendee, invite.attendee.slice())) return error.InvitationChanged;
                const expected_source = j.text(req, "sourceHash");
                if (expected_source.len > 0 and !std.mem.eql(u8, expected_source, &storage.Store.hash(ics))) return error.InvitationChanged;
            }
            if (std.mem.eql(u8, cmd, "invitation.inspect")) {
                const timezone = @import("timezone.zig");
                const local_zone = timezone.load(s.io, a, s.env) catch timezone.Zone{ .unavailable = true };
                const friendly = try invitation.friendlyNative(s.io, a, s.env, &invite, &local_zone);
                if (reconcile) try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), reconcileInvitation, .{ s, a, &store, ics, req });
                if (reconcile) try s.resumeInvitationCalendar(a, &store, ics, req);
                const response_status = try confirmedInvitationResponse(a, &store, ics, address, aliases);
                return j.value(a, .{ .method = @tagName(invite.method), .cancelled = invite.cancelled, .canReply = invite.canRespond(), .additionalEvents = invite.additional_events, .sourceHash = @as([]const u8, &storage.Store.hash(ics)), .confirmedResponse = response_status.status, .responseOutcome = response_status.outcome, .calendarSync = response_status.calendarSync, .calendarSyncAvailable = s.calendarHost(a).canSyncRsvp(req, address), .calendarSyncTarget = "primary", .dtstamp = invite.stamp.slice(), .recurrenceParameters = invite.recurrence_parameters.slice(), .uid = invite.uid.slice(), .organizer = invite.organizer.slice(), .attendee = invite.attendee.slice(), .attendeeStatus = invite.attendee_status.slice(), .sequence = invite.sequence, .recurrenceId = invite.recurrence_id.slice(), .summary = invite.summary.slice(), .start = invite.start.slice(), .startDisplay = friendly.start, .originalStartDisplay = friendly.original_start, .endDisplay = friendly.end, .durationDisplay = friendly.duration, .location = friendly.location, .joinUrl = friendly.join_url, .recurrenceDisplay = friendly.recurrence, .allDay = friendly.all_day, .timezoneUnavailable = friendly.timezone_unavailable });
            }
            if (std.mem.eql(u8, (try confirmedInvitationResponse(a, &store, ics, address, aliases)).outcome, "unknown")) return error.UnknownOutcome;
            const status = std.meta.stringToEnum(invitation.Status, try j.required(req, "status")) orelse return error.InvalidInvitationStatus;
            const buf = try a.alloc(u8, invitation.max_calendar_bytes);
            const reply = try invitation.reply(&invite, status, try utcStamp(s.io, a), buf);
            const d: t.Draft = .{ .to = &.{.{ .address = invite.organizer.slice() }}, .subject = try std.fmt.allocPrint(a, "{s}: {s}", .{ @tagName(status), m.subject }), .bodyText = try std.fmt.allocPrint(a, "Invitation response: {s}", .{@tagName(status)}) };
            var responding = try j.copyObject(a, req);
            const source_hash = storage.Store.hash(ics);
            try responding.object.put(a, "_sourceInvitationHash", .{ .string = try a.dupe(u8, &source_hash) });
            const sent = try s.send(a, &store, responding, d, reply, false);
            return s.syncInvitationCalendar(a, &store, ics, req, sent);
        }
        return error.UnsupportedCommand;
    }
    // A positive Sent match can resolve a lost RSVP receipt. Absence is never
    // evidence of rejection: indexing may lag, so this path never resubmits.
    fn reconcileInvitation(s: *Session, a: std.mem.Allocator, store: *storage.Store, ics: []const u8, req: Value) !void {
        const source_hash = storage.Store.hash(ics);
        const selected = (try @import("operation_history.zig").latestInvitation(store, a, &source_hash)) orelse return;
        if (!std.mem.eql(u8, selected.outcome, "unknown")) return;
        if (selected.rfcMessageId.len == 0) return;
        try @import("invitation_receipt.zig").validateMessageId(selected.rfcMessageId);
        var matched: ?[]const u8 = null;
        if (s.options.fixtures) {
            store.state.fixtureCalls += 1;
            for (store.state.outbox) |entry| {
                if (!std.mem.eql(u8, entry.messageId, selected.rfcMessageId)) continue;
                const message = (try store.readOutbox(entry.id)) orelse continue;
                if (@import("invitation_receipt.zig").matches(store.state.account, selected.rfcMessageId, selected.icalendar, message)) {
                    matched = try a.dupe(u8, message.id);
                    break;
                }
            }
        } else {
            store.release();
            var lookup_scope = std.heap.ArenaAllocator.init(s.allocator);
            defer lookup_scope.deinit();
            const temporary = lookup_scope.allocator();
            var search = try j.copyObject(temporary, req);
            try search.object.put(temporary, "query", .{ .string = try std.fmt.allocPrint(temporary, "in:sent rfc822msgid:{s}", .{selected.rfcMessageId}) });
            try search.object.put(temporary, "limit", .{ .integer = 8 });
            try search.object.put(temporary, "cursor", .{ .string = "" });
            const result = try s.remote(temporary, store.state.account, "mail.search", search);
            const candidates = try array(result, "messages");
            if (candidates.len > 8) return error.InvalidProviderResponse;
            for (candidates) |candidate| {
                try s.io.checkCancel();
                var message_scope = std.heap.ArenaAllocator.init(s.allocator);
                defer message_scope.deinit();
                const scratch = message_scope.allocator();
                var read_request = try j.copyObject(scratch, req);
                try read_request.object.put(scratch, "messageId", .{ .string = try j.required(candidate, "id") });
                const value = s.remote(scratch, store.state.account, "mail.read", read_request) catch |err| {
                    if (err == error.MessageNotFound) continue;
                    return err;
                };
                const message = try j.decode(t.Message, scratch, value);
                if (@import("invitation_receipt.zig").matches(store.state.account, selected.rfcMessageId, selected.icalendar, message)) {
                    matched = try a.dupe(u8, message.id);
                    break;
                }
            }
            try s.reopenBody(a, store);
        }
        if (matched) |message_id| {
            for (store.state.operations) |*operation| {
                if (!std.mem.eql(u8, operation.id, selected.id)) continue;
                if (!std.mem.eql(u8, operation.hash, selected.hash) or !std.mem.eql(u8, operation.sourceInvitationHash, &source_hash) or !std.mem.eql(u8, operation.rfcMessageId, selected.rfcMessageId) or !std.mem.eql(u8, operation.icalendar, selected.icalendar)) return error.OperationConflict;
                if (!std.mem.eql(u8, operation.outcome, "unknown")) return;
                operation.outcome = "applied";
                operation.messageId = message_id;
                operation.errorCode = "";
                try store.save();
                return;
            }
            return error.OperationNotFound;
        }
    }
    fn cachedAliases(a: std.mem.Allocator, store: *const storage.Store) ![]const []const u8 {
        const result = try a.alloc([]const u8, store.state.identities.len);
        for (store.state.identities, result) |identity, *address| address.* = identity.address;
        return result;
    }
    fn invitationReceipt(a: std.mem.Allocator, store: *storage.Store, ics: []const u8, req: Value) !?Value {
        const id = try j.required(req, "operationId");
        const status = std.meta.stringToEnum(invitation.Status, try j.required(req, "status")) orelse return error.InvalidInvitationStatus;
        const hash = storage.Store.hash(ics);
        if (try store.findOperation(a, id)) |operation| {
            if (!std.mem.eql(u8, operation.sourceInvitationHash, &hash)) return error.OperationConflict;
            if (!std.mem.eql(u8, operation.invitationCalendarId, j.text(req, "calendarId"))) return error.OperationConflict;
            var previous: invitation.Invitation = .{};
            invitation.parseDisplay(operation.icalendar, store.state.account, &.{}, &previous) catch return error.OperationConflict;
            if (previous.method != .reply or !std.ascii.eqlIgnoreCase(previous.attendee_status.slice(), @tagName(status))) return error.OperationConflict;
            const expected_attendee = j.text(req, "attendee");
            if (expected_attendee.len > 0 and !std.ascii.eqlIgnoreCase(expected_attendee, previous.attendee.slice())) return error.OperationConflict;
            const expected_source = j.text(req, "sourceHash");
            if (expected_source.len > 0 and !std.mem.eql(u8, expected_source, &hash)) return error.OperationConflict;
            return try j.value(a, operation);
        }
        return null;
    }
    const ConfirmedInvitationResponse = struct { status: []const u8 = "", outcome: []const u8 = "", calendarSync: ?@import("calendar_rsvp.zig").Result = null };
    fn confirmedInvitationResponse(a: std.mem.Allocator, store: *storage.Store, ics: []const u8, account: []const u8, aliases: []const []const u8) !ConfirmedInvitationResponse {
        const source_hash = storage.Store.hash(ics);
        const operation = (try @import("operation_history.zig").latestInvitation(store, a, &source_hash)) orelse return .{};
        if (!std.mem.eql(u8, operation.outcome, "applied")) return .{ .outcome = "unknown" };
        var sent: invitation.Invitation = .{};
        invitation.parseDisplay(operation.icalendar, account, &.{}, &sent) catch return .{};
        var original: invitation.Invitation = .{};
        invitation.parseDisplay(ics, account, aliases, &original) catch return .{};
        if (sent.method != .reply or !std.mem.eql(u8, sent.uid.slice(), original.uid.slice()) or !std.mem.eql(u8, sent.recurrence_id.slice(), original.recurrence_id.slice()) or !std.mem.eql(u8, sent.recurrence_parameters.slice(), original.recurrence_parameters.slice())) return .{};
        return .{ .outcome = "applied", .status = try a.dupe(u8, sent.attendee_status.slice()), .calendarSync = operation.calendarSync };
    }
    fn calendarJob(s: *Session, a: std.mem.Allocator, req: Value) !Value {
        return s.calendarHost(a).run(req);
    }
    fn calendarBrowserJob(s: *Session, a: std.mem.Allocator, req: Value, account_index: usize) !Value {
        const calendar_browser = @import("calendar_browser.zig");
        const calendar_types = @import("calendar_types.zig");
        const account = &s.config.accounts[account_index];
        const is_event = std.mem.eql(u8, j.text(req, "cmd"), "calendar.event-open");
        var request = try j.copyObject(a, req);
        try request.object.put(a, "cmd", .{ .string = if (is_event) "calendar.event" else "calendar.list" });
        const data = try s.calendarJob(a, request);
        const target = if (is_event) blk: {
            const source: calendar_types.Target = .{ .account = account.address.slice(), .calendar_id = try j.required(req, "calendarId") };
            const event = try j.decode(calendar_types.Event, a, j.get(data, "event") orelse return error.InvalidCalendarResponse);
            break :blk try calendar_browser.event(account, source, try j.required(req, "eventId"), event);
        } else blk: {
            if (!std.ascii.eqlIgnoreCase(j.text(data, "account"), account.address.slice())) return error.CalendarAccountMismatch;
            const wanted = j.text(req, "calendarId");
            if (wanted.len > 0) {
                try calendar_types.text(wanted, 1024, false);
                var found = false;
                for (try array(data, "calendars")) |entry| {
                    const source = try @import("calendar_sources.zig").jsonTarget(j.get(entry, "calendar") orelse return error.InvalidCalendarResponse);
                    if (!std.ascii.eqlIgnoreCase(source.account, account.address.slice())) return error.CalendarAccountMismatch;
                    if (std.mem.eql(u8, source.calendar_id, wanted)) found = true;
                }
                if (!found) return error.CalendarNotFound;
            }
            break :blk try calendar_browser.calendar(account);
        };
        if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, account, &target);
        return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .url = target.url.slice(), .profile = target.profile_arg.slice(), .cached = try j.boolean(data, "cached", false), .stale = try j.boolean(data, "stale", false), .refreshError = j.text(data, "refreshError") });
    }
    fn calendarHost(s: *Session, a: std.mem.Allocator) @import("calendar_host.zig").Host {
        return .{ .io = s.io, .allocator = a, .backing_allocator = s.allocator, .env = s.env, .config = &s.config, .options = s.options, .cache_root = s.cache_root, .source_context = s, .loadSourceFn = calendarSource, .access = .{ .context = s, .openFn = storeAccessOpen } };
    }
    fn syncInvitationCalendar(s: *Session, a: std.mem.Allocator, store: *storage.Store, ics: []const u8, req: Value, receipt: Value) !Value {
        const sync = @import("calendar_rsvp.zig");
        var result = try j.copyObject(a, receipt);
        if (!std.mem.eql(u8, j.text(receipt, "outcome"), "applied")) {
            try result.object.put(a, "calendarSync", try j.value(a, sync.Result{ .errorCode = "MailReplyNotConfirmed" }));
            return result;
        }
        const status = std.meta.stringToEnum(invitation.Status, j.text(req, "status")) orelse return error.InvalidInvitationStatus;
        if (j.get(receipt, "calendarSync")) |saved| if (saved != .null and !std.mem.eql(u8, j.text(saved, "state"), "unknown")) {
            if (!try j.boolean(req, "reconcile", false) or !std.mem.eql(u8, j.text(saved, "state"), "skipped")) return result;
        };
        var outcome: sync.Result = .{ .errorCode = "DeclinedReplyOnly" };
        if (status != .declined) {
            const aliases = try cachedAliases(a, store);
            // Persist the continuation before opening Calendar. A crash after
            // its write cannot leave a completed-mail receipt that looks final
            // or conceal Calendar's separately durable unknown journal claim.
            for (store.state.operations) |*operation| if (std.mem.eql(u8, operation.id, j.text(receipt, "id"))) {
                if (operation.calendarSync == null or operation.calendarSync.?.state != .unknown) operation.calendarSync = .{ .state = .unknown, .errorCode = "CalendarSyncPending", .canRetry = true };
                store.save() catch {
                    try result.object.put(a, "calendarSync", try j.value(a, sync.Result{ .errorCode = "CalendarReceiptPersistenceFailed" }));
                    return result;
                };
                break;
            };
            store.release();
            outcome = s.calendarHost(a).syncRsvp(req, .{ .source = ics, .verified_aliases = aliases }, if (status == .accepted) .accepted else .tentative) catch |err| sync.failed(err);
            if (j.get(receipt, "calendarSync")) |saved| if (saved != .null and std.mem.eql(u8, j.text(saved, "state"), "unknown") and outcome.state == .skipped) {
                outcome.state = .unknown;
                outcome.canRetry = true;
                outcome.calendarId = j.text(saved, "calendarId");
                outcome.operationId = j.text(saved, "operationId");
            };
            s.reopenBody(a, store) catch {
                try result.object.put(a, "calendarSync", try j.value(a, sync.Result{ .state = .unknown, .errorCode = "CalendarReceiptPersistenceFailed", .canRetry = true }));
                return result;
            };
        }
        const operation_id = j.text(receipt, "id");
        for (store.state.operations) |*operation| if (std.mem.eql(u8, operation.id, operation_id)) {
            operation.calendarSync = outcome;
            store.save() catch {
                outcome.state = .unknown;
                outcome.canRetry = true;
                outcome.errorCode = "CalendarReceiptPersistenceFailed";
            };
            break;
        };
        try result.object.put(a, "calendarSync", try j.value(a, outcome));
        if (outcome.state != .unknown) settleAcceptedSource(store);
        return result;
    }
    fn resumeInvitationCalendar(s: *Session, a: std.mem.Allocator, store: *storage.Store, ics: []const u8, req: Value) !void {
        const hash = storage.Store.hash(ics);
        const operation = (try @import("operation_history.zig").latestInvitation(store, a, &hash)) orelse return;
        if (!std.mem.eql(u8, operation.outcome, "applied")) return;
        var previous: invitation.Invitation = .{};
        invitation.parseDisplay(operation.icalendar, store.state.account, &.{}, &previous) catch return;
        var request = try j.copyObject(a, req);
        try request.object.put(a, "operationId", .{ .string = operation.id });
        try request.object.put(a, "status", .{ .string = if (std.ascii.eqlIgnoreCase(previous.attendee_status.slice(), "ACCEPTED")) "accepted" else if (std.ascii.eqlIgnoreCase(previous.attendee_status.slice(), "TENTATIVE")) "tentative" else "declined" });
        if (operation.invitationCalendarId.len != 0) try request.object.put(a, "calendarId", .{ .string = operation.invitationCalendarId });
        _ = try s.syncInvitationCalendar(a, store, ics, request, try j.value(a, operation));
    }
    fn calendarSource(context: *anyopaque, a: std.mem.Allocator, account: []const u8, request: Value) anyerror!@import("calendar_commands.zig").InvitationInput {
        const s: *Session = @ptrCast(@alignCast(context));
        try s.capability(a, account, request, "mail-read");
        const message_id = try j.required(request, "messageId");
        try @import("../bounded.zig").identifier(message_id);
        var aliases: []const []const u8 = &.{};
        const source = blk: {
            var store = try s.openStore(a, account, false);
            defer store.close();
            var message = try s.read(a, &store, message_id, request);
            if (message.invitation == null) for (message.attachments) |part| {
                if (!@import("mime.zig").isCalendarPart(part.mimeType, part.filename)) continue;
                message = try s.readMessage(a, &store, message_id, request, false);
                break;
            };
            aliases = try cachedAliases(a, &store);
            break :blk message.invitation orelse return error.NotInvitation;
        };
        // Verified aliases retained with this account make local inspection
        // available offline. Calendar writes independently enforce their grant.
        return .{ .source = source, .verified_aliases = aliases };
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
            if (store.state.labels.len > t.Limits.labels) return error.TooManyLabels;
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
                    try network.initWithAllocator(s.io, a, s.allocator, &s.config, store.state.account, "mail.labels", req);
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
        if (store.state.labels.len > t.Limits.labels) return error.TooManyLabels;
        for (store.state.labels) |label| {
            try @import("../bounded.zig").identifier(label.id);
            if (label.name.len > 512 or !std.unicode.utf8ValidateSlice(label.name)) return error.InvalidLabel;
            try recipients.validateHeader(label.name);
        }
    }

    fn mutationReceipt(a: std.mem.Allocator, value: anytype) !Value {
        // Receipt cloning runs after a durable operation exists. Preserve its
        // uncertainty even if Core never reaches successResponse's encoder.
        return j.value(a, value) catch |err| return if (err == error.OutOfMemory) error.UnknownOutcome else err;
    }
    fn labelReceipt(a: std.mem.Allocator, operation: storage.Operation) !Value {
        return mutationReceipt(a, .{ .outcome = operation.outcome, .operationId = operation.id, .labelId = operation.labelId, .label = if (operation.label) |label| try mutationReceipt(a, label) else @as(Value, .null), .deleted = operation.deleted, .errorCode = operation.errorCode });
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
        if (try store.findOperation(a, operation_id)) |operation| {
            if (!std.mem.eql(u8, operation.hash, &digest) or !std.mem.eql(u8, operation.kind, cmd)) return error.OperationConflict;
            return labelReceipt(a, operation);
        }
        // An uncertain collection mutation must be reconciled explicitly; a
        // fresh identity must not silently cause a second provider request.
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and std.mem.startsWith(u8, operation.kind, "labels.")) {
            if (std.mem.eql(u8, operation.hash, &digest) or (!create and std.mem.eql(u8, operation.labelId, id))) return labelReceipt(a, operation);
        };
        try store.compactHistory();
        if (store.state.operations.len >= 1000) return error.OperationJournalFull;
        _ = try s.loadLabels(a, store, req, false);
        // The live list temporarily releases the store; another client may
        // have journaled this identity while the GET was in progress.
        if (try store.findOperation(a, operation_id)) |operation| {
            if (!std.mem.eql(u8, operation.hash, &digest) or !std.mem.eql(u8, operation.kind, cmd)) return error.OperationConflict;
            return labelReceipt(a, operation);
        }
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and std.mem.startsWith(u8, operation.kind, "labels.")) {
            if (std.mem.eql(u8, operation.hash, &digest) or (!create and std.mem.eql(u8, operation.labelId, id))) return labelReceipt(a, operation);
        };
        try store.compactHistory();
        if (store.state.operations.len >= 1000) return error.OperationJournalFull;
        const old = if (!create) try label_collection.custom(store.state.labels, id) else storage.Label{ .id = "", .name = "" };
        const final_name = if (coloring) old.name else name;
        if (deleting) {
            if (!std.mem.eql(u8, confirmation, old.name)) return error.InvalidLabelConfirmation;
            if (s.options.fixtures and store.state.fixtureDeletedLabels.len >= t.Limits.labels) return error.TooManyDeletedLabels;
        } else {
            try label_collection.unique(store.state.labels, final_name, id);
            if (create and store.state.labels.len >= t.Limits.labels) return error.TooManyLabels;
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
        const configured = &s.config.accounts[s.config.index(store.state.account) orelse return error.UnknownAccount];
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
            if (store.state.identities.len > (if (@import("send_memory.zig").native) @as(usize, 1024) else 32)) return error.TooManyAliases;
            for (store.state.identities) |*identity| {
                try recipients.validateAddress(identity.address);
                try recipients.validateHeader(identity.name);
                if (identity.name.len > @import("mail_limits.zig").display_name_bytes or identity.signature.len > 8192) return error.IdentityTooLarge;
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
            var store = try s.openStore(a, address, false);
            defer store.close();
            batch_remote.source = try s.fixtureProviderSource(a, &store);
        }
        var network: @import("gmail.zig").NetworkSession = undefined;
        if (!s.options.fixtures) {
            try network.initWithAllocator(s.io, a, s.allocator, &s.config, address, "mail.modify-labels", req);
            batch_remote.transport = network.transport();
        }
        defer if (!s.options.fixtures) network.close();
        const context: batch.Context = .{ .io = s.io, .allocator = s.allocator, .root = s.cache_root, .account = address, .options = s.options, .access = .{ .context = s, .openFn = storeAccessOpen }, .provider = .{ .context = &batch_remote, .labelsFn = BatchRemote.labelsFn, .modifyFn = BatchRemote.modifyFn, .fixtureCheckpoint = if (s.options.fixtures) fixtureCheckpoint(batch_remote.source) else null } };
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
        store.* = try s.openStore(a, account, false);
        if (store.state.generation != expected) return error.CacheChanged;
    }
    fn reopenBody(s: *Session, a: std.mem.Allocator, store: *storage.Store) !void {
        const account = store.state.account;
        store.close();
        store.* = try s.openStore(a, account, false);
    }
    fn cacheStats(s: *Session, a: std.mem.Allocator, store: *storage.Store) !Value {
        const meter = if (s.meter) |m| m.snapshot() else null;
        const blobs = try store.blobStats();
        return j.value(a, .{ .blobCount = blobs.count, .blobBytes = blobs.bytes, .blobBytesAreCiphertext = store.vault != null, .metadataEntries = store.state.entries.len, .metadataLimit = store.options.metadata_limit, .diskBytes = try store.diskBytes(), .diskLimitBytes = store.options.disk_limit, .bodyLimitBytes = t.Limits.body_bytes, .runtimeReservationBytes = t.Limits.runtime_bytes, .terminalHeapLimitBytes = t.Limits.runtime_bytes, .outgoingTransient = @import("send_memory.zig").snapshot(), .fixedBackendReservationBytes = @import("../limits.zig").app_reservation, .allocatorUsedBytes = if (meter) |m| m.allocatorUsedBytes else null, .allocatorPeakBytes = if (meter) |m| m.allocatorPeakBytes else null, .rejectedAllocations = if (meter) |m| m.rejectedAllocations else null, .allocatorReservationBytes = if (meter) |m| m.allocatorReservationBytes else null, .backingRejectedAllocations = if (meter) |m| m.backingRejectedAllocations else null, .lastRejectedAllocationBytes = if (meter) |m| m.lastRejectedAllocationBytes else null, .fixtureCalls = store.state.fixtureCalls, .fixtureSends = store.state.fixtureSends, .fixtureProviderEntries = store.state.fixtureProvider.len, .fixtureProviderLimit = @as(usize, 1024), .refreshInProgress = try s.refreshActive(store.state.account), .historyId = store.state.historyId, .lastSyncAt = store.state.lastSyncAt, .syncCalls = store.state.syncCalls, .syncMetadataGets = store.state.syncMetadataGets, .syncListCalls = store.state.syncListCalls, .syncHistoryPages = store.state.syncHistoryPages, .syncBodyGets = store.state.syncBodyGets, .generation = store.state.generation });
    }
    fn cachedDispatch(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value) !Value {
        const cmd = j.text(req, "cmd");
        if (std.mem.eql(u8, cmd, "mail.recipients")) try s.capability(a, address, req, "mail-read");
        var store = try s.openStore(a, address, true);
        defer store.close();
        if (std.mem.eql(u8, cmd, "mail.recipients")) {
            var known = @import("recipient_cache.zig").Builder.init(a, address);
            defer known.deinit();
            const aliases = try a.alloc([]const u8, store.state.identities.len);
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
            return j.value(a, .{ .contacts = cached_contacts.items, .cached = true, .cacheReady = store.state.contactsReady or store.state.contacts.len != 0, .partial = store.state.contactWarnings.any(), .contactWarnings = store.state.contactWarnings });
        }
        if (std.mem.eql(u8, cmd, "mail.read")) {
            const id = try j.required(req, "messageId");
            var message = (try store.read(id)) orelse store.refusedMessage(id) orelse if (s.options.fixtures) (try store.readOutbox(id)) orelse return error.CacheMiss else return error.CacheMiss;
            if (store.find(id)) |entry| {
                copyMembership(&message, entry.message);
            }
            message.bodyCached = message.bodyCacheError.len == 0;
            return mail_value.borrowed(a, message);
        }
        if (std.mem.eql(u8, cmd, "mail.thread")) {
            const thread = try j.required(req, "threadId");
            if (try j.boolean(req, "progressive", false)) if (try s.cachedProgressiveThread(a, &store, req)) |result| return result;
            var messages: std.ArrayList(t.Message) = .empty;
            var remaining: usize = t.Limits.thread_bytes;
            for (store.state.entries) |entry| if (std.mem.eql(u8, entry.message.threadId, thread)) {
                if (messages.items.len == 100) return error.ThreadTooLarge;
                var scope = std.heap.ArenaAllocator.init(s.allocator);
                defer scope.deinit();
                if ((try store.readWithAllocator(scope.allocator(), entry.message.id)) orelse store.refusedMessage(entry.message.id)) |cached| {
                    var message = cached;
                    copyMembership(&message, entry.message);
                    message.bodyCached = message.bodyCacheError.len == 0;
                    try messages.append(a, try gmail_decode.retainThreadMessage(message, a, &remaining));
                } else try messages.append(a, try gmail_decode.unavailablePlaceholder(entry.message, a, "BodyNotCached"));
            };
            if (messages.items.len == 0) return error.CacheMiss;
            std.sort.heap(t.Message, messages.items, {}, olderFirst);
            return mail_value.borrowed(a, .{ .messages = messages.items, .cached = true, .partial = true });
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
        const plan = try (try cache_query.compile(query)).prepared(a);
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
            if (plan.findRange(full.bodyText, term) != null) {
                field = "body";
                source = full.bodyText;
            } else if (plan.findRange(message.subject, term) == null) {
                source = message.snippet;
                if (plan.findRange(source, term) == null) source = if (plan.findRange(message.from.name, term) != null) message.from.name else message.from.address;
            }
            const matched = plan.findRange(source, term);
            const offset = if (matched) |range| range.start else 0;
            // A bounded UTF-8 excerpt starts at a codepoint boundary and never
            // exposes raw HTML/base64 or a second copy of the complete body.
            var start = offset -| 48;
            while (start < source.len and !std.unicode.utf8ValidateSlice(source[start..])) start += 1;
            const excerpt = utf8Prefix(source[start..], 192);
            const matched_length = if (matched) |range| range.end - range.start else 0;
            try highlights.append(a, .{ .messageId = message.id, .field = field, .offset = offset - start, .length = @min(matched_length, excerpt.len -| (offset - start)), .excerpt = try a.dupe(u8, excerpt) });
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
            if (label_id.len > 0 and !hasLabel(entry.message, label_id)) {
                // The authoritative scoped list may certify membership when a
                // single metadata response could not verify labelIds.
                var listed = false;
                if (!entry.message.labelsVerified) if (view) |scoped| {
                    for (scoped.ids) |id| listed = listed or std.mem.eql(u8, id, entry.message.id);
                };
                if (!listed) continue;
            }
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
            return .{ .context = self, .requestFn = request, .temporary_allocator = self.session.allocator };
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
                const tail = url[pos + 13 ..];
                const end = std.mem.indexOfScalar(u8, tail, '?') orelse tail.len;
                const id = try decodeUrlValue(a, tail[0..end]);
                // Match Gmail's 404 mapping, including the shared one-time
                // metadata retry for a verified but expired opaque token.
                return j.get(j.get(self.source, "externalBodies") orelse return error.MessageNotFound, id) orelse error.MessageNotFound;
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
                return decodeUrlValue(a, field[equal + 1 ..]);
            }
            return "";
        }
        fn decodeUrlValue(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
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
        var lease: ?storage.RefreshLease = null;
        if (s.vault_owner == null) lease = (try storage.RefreshLease.acquire(s.io, s.cache_root, address, s.options)) orelse {
            var snapshot = try s.openStore(a, address, true);
            defer snapshot.close();
            var result = try cachedList(a, &snapshot, request);
            try result.object.put(a, "coalesced", .{ .bool = true });
            try result.object.put(a, "refreshInProgress", .{ .bool = true });
            try result.object.put(a, "refreshed", .{ .bool = false });
            return result;
        };
        defer if (lease) |*held| held.release();
        if (automatic) {
            var freshness_phase = std.heap.ArenaAllocator.init(s.allocator);
            defer freshness_phase.deinit();
            const fa = freshness_phase.allocator();
            var snapshot = try s.openStore(fa, address, true);
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
            if (entry.bytes != 0 and store.vault != null and !try store.bodyAvailable(entry.message.id)) return false;
            if (entry.bytes != 0 and store.vault == null) {
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
            var trim = try s.openStore(phase.allocator(), address, false);
            defer trim.close();
        }
        {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var snapshot = try s.openStore(phase.allocator(), address, true);
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
        // Keep the complete fixture tree separate from the request's plan and
        // result allocations. Its large arena must not determine their next
        // growth size; borrowed provider values stay alive through all fetches.
        var fixture_arena = std.heap.ArenaAllocator.init(s.allocator);
        defer fixture_arena.deinit();
        var fixture_remote: FixtureRemote = undefined;
        var live: @import("gmail.zig").NetworkSession = undefined;
        var transport = if (s.options.fixtures) fixture_transport: {
            const fixture_allocator = fixture_arena.allocator();
            const raw_source = try s.fixture(fixture_allocator, address);
            try s.fixtureGate(a, raw_source, req);
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            const pa = phase.allocator();
            var provider_store = try s.openStore(pa, address, false);
            defer provider_store.close();
            if (provider_store.state.generation != expected) return error.CacheChanged;
            if (try reconcileFixtureSource(pa, &provider_store, raw_source)) {
                provider_store.state.generation += 1;
                for (provider_store.state.views) |*view| view.stale = true;
                try provider_store.save();
                expected = provider_store.state.generation;
            }
            // Overlay maps borrow the long-lived source tree; allocating them
            // with the request avoids growing that tree's large arena again.
            const source = try overlayFixtureSource(a, &provider_store, raw_source);
            fixture_remote = .{ .session = s, .source = source };
            break :fixture_transport fixture_remote.transport();
        } else live_transport: {
            try live.initWithAllocator(s.io, a, s.allocator, &s.config, address, "mail.refresh", req);
            break :live_transport live.transport();
        };
        transport.progress_sink = s.progress_sink;
        transport.temporary_allocator = s.allocator;
        defer if (!s.options.fixtures) live.close();
        const plan_value = try @import("gmail.zig").dispatchAuthorized(s.io, a, address, &.{"mail-read"}, transport, "mail.refresh", request);
        const plan = try j.decode(@import("gmail.zig").RefreshPlan, a, plan_value);
        const key = try storage.Store.viewKey(a, address, j.text(req, "query"), j.text(req, "label"));
        {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            const ca = phase.allocator();
            var commit = try s.openStore(ca, address, false);
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
            for (plan.labels) |update| {
                if (update.verified) commit.applyLabels(update.id, update.labels) else if (commit.find(update.id)) |entry| {
                    entry.message.labelsVerified = false;
                    entry.message.metadataPartial = true;
                    entry.message.decodeWarning = update.warning;
                }
            }
            if (plan.messages.len != 0 or plan.labels.len != 0 or plan.deleted.len != 0) for (commit.state.views) |*view| {
                view.stale = true;
            };
            if (plan.viewFetched) {
                var messages: std.ArrayList(t.Message) = .empty;
                for (plan.viewIds) |id| if (commit.find(id)) |entry| try messages.append(ca, entry.message);
                try commit.recordView(j.text(req, "query"), j.text(req, "label"), plan.labelId, messages.items, plan.nextCursor, false);
                if (plan.partial) if (commit.findView(&key)) |view| {
                    view.incomplete = true;
                };
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
            var snapshot = try s.openStore(sa, address, true);
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
                var snapshot = try s.openStore(check_phase.allocator(), address, true);
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
            var commit = try s.openStore(ma, address, false);
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
            if (body_result) |message| s.reportRow(.{ .kind = .body, .failed = message.bodyCacheError.len != 0, .message = message }) else s.reportRow(.{ .kind = .body, .failed = true, .message = .{ .id = id, .threadId = "" } });
            s.reportProgress(.bodies, body_completed, body_total);
            if (s.options.fixtures) try s.fixtureProgressGate(ma, fixture_remote.source, .bodies, body_completed);
        }
        var final_phase = std.heap.ArenaAllocator.init(s.allocator);
        defer final_phase.deinit();
        const fa = final_phase.allocator();
        var commit = try s.openStore(fa, address, false);
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
        return @import("gmail_decode.zig").messageRefusal(err);
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
        const registry = try @import("auth.zig").loadConfigured(s.io, a, &s.config, if (s.config.credential_store == .vault) "" else try j.required(req, "grantFile"));
        if (@import("auth.zig").find(&registry, address)) |grant| {
            if (!grant.permits(name)) return error.PermissionDenied;
        } else if (!std.mem.eql(u8, name, "mail-read")) return error.PermissionDenied;
    }
    fn remote(s: *Session, a: std.mem.Allocator, address: []const u8, cmd: []const u8, req: Value) !Value {
        return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(@import("send_memory.zig").seconds(j.text(req, "cmd"))), @import("gmail.zig").executeProgressWithAllocator, .{ s.io, a, @import("send_memory.zig").commandBacking(s.allocator, j.text(req, "cmd")), &s.config, address, cmd, req, s.progress_sink });
    }
    fn fixture(s: *Session, a: std.mem.Allocator, address: []const u8) !Value {
        if (!s.options.fixtures) return error.LiveProviderNotReady;
        if (s.options.fixture_root) |root| {
            const key = if (std.mem.eql(u8, address, "personal@example.com")) "personal" else if (std.mem.eql(u8, address, "work@example.com")) "work" else if (std.mem.eql(u8, address, "optional@example.com")) "optional" else return error.FixtureAccountRequired;
            const directory = try std.Io.Dir.cwd().openDir(s.io, root, .{});
            defer directory.close(s.io);
            var path_bytes: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_bytes, "accounts/{s}.json", .{key});
            const file = try directory.openFile(s.io, path, .{ .allow_directory = false });
            defer file.close(s.io);
            const stat = try file.stat(s.io);
            if (stat.kind != .file or stat.size > 16 * 1024 * 1024) return error.StreamTooLong;
            // A regular fixture file has a known bound. Growing an EOF reader
            // inside an arena retains earlier buffers and can speculatively
            // request far more memory than the complete provider envelope.
            const raw = try a.alloc(u8, @intCast(stat.size));
            var offset: usize = 0;
            while (offset < raw.len) {
                const count = try file.readPositional(s.io, &.{raw[offset..]}, offset);
                if (count == 0) return error.UnexpectedEndOfInput;
                offset += count;
            }
            var extra: [1]u8 = undefined;
            if (try file.readPositional(s.io, &.{&extra}, offset) != 0) return error.StreamTooLong;
            // The immutable input and parsed tree share this allocator's
            // lifetime; only escaped strings need another owned allocation.
            const source = try @import("fixture_json.zig").parse(a, raw);
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
                try store.setFixtureRecord(record.id, &.{}, try store.allocator.dupe(u8, checkpoint), true);
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
        // Provider bytes may live in a per-download arena. Any reconciled
        // labels/checkpoints outlive that response with the open cache state.
        try s.ensureFixtureLabels(store.allocator, store, source);
        if (try reconcileFixtureSource(store.allocator, store, source)) {
            store.state.generation += 1;
            for (store.state.views) |*view| view.stale = true;
            try store.save();
        }
        return overlayFixtureSource(a, store, source);
    }

    fn cachedProgressiveThread(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !?Value {
        const windows = @import("thread_window.zig");
        const thread = try j.required(req, "threadId");
        var members: std.ArrayList(windows.Member) = .empty;
        for (store.state.entries, 0..) |entry, index| if (std.mem.eql(u8, entry.message.threadId, thread)) {
            if (members.items.len == windows.maximum) return error.ThreadTooLarge;
            try members.append(a, .{ .id = entry.message.id, .received_at = entry.message.receivedAt, .source_index = index });
        };
        if (members.items.len <= windows.limit and j.text(req, "beforeMessageId").len == 0 and j.text(req, "afterMessageId").len == 0 and j.text(req, "windowStartMessageId").len == 0 and j.text(req, "windowEndMessageId").len == 0) return null;
        std.sort.heap(windows.Member, members.items, {}, windows.older);
        const window = windows.choose(members.items, req) catch |err| return if (err == error.ThreadWindowChanged or err == error.MessageNotFound) error.CacheMiss else err;
        const messages = try a.alloc(t.Message, window.end - window.start);
        var remaining: usize = t.Limits.thread_bytes;
        const focused = window.focus - window.start;
        for (0..messages.len) |order| {
            // Reserve the selected body before retained neighbors. The wire
            // remains chronological regardless of this allocation order.
            const index = if (order == 0) focused else if (order <= focused) order - 1 else order;
            const member = members.items[window.start + index];
            var scope: std.heap.ArenaAllocator = .init(s.allocator);
            defer scope.deinit();
            const metadata = store.state.entries[member.source_index].message;
            var message = metadata;
            message.bodyCached = false;
            if (try store.readWithAllocator(scope.allocator(), member.id)) |cached| {
                message = cached;
                copyMembership(&message, metadata);
                message.bodyCached = message.bodyCacheError.len == 0;
            }
            messages[index] = try gmail_decode.retainThreadMessage(message, a, &remaining);
        }
        var response = windows.response(messages, members.items.len, window);
        response.cached = true;
        response.partial = true; // Cache metadata cannot certify provider completeness.
        return try mail_value.borrowed(a, response);
    }
    fn retainProgressiveThread(s: *Session, a: std.mem.Allocator, store: *storage.Store, result: Value, expected: u64) !Value {
        const windows = @import("thread_window.zig");
        var response = try j.decode(windows.Response, a, result);
        const messages = try a.dupe(t.Message, response.messages);
        var remaining: usize = t.Limits.thread_bytes;
        response.deferredMessages = 0;
        response.partial = response.olderMessages > 0 or response.newerMessages > 0;
        const focused = for (messages, 0..) |message, index| {
            if (std.mem.eql(u8, message.id, response.focusMessageId)) break index;
        } else return error.ThreadWindowChanged;
        for (0..messages.len) |order| {
            const index = if (order == 0) focused else if (order <= focused) order - 1 else order;
            const message = &messages[index];
            var scope: std.heap.ArenaAllocator = .init(s.allocator);
            defer scope.deinit();
            if (!message.bodyCached and message.bodyCacheError.len == 0) {
                if ((try store.readWithAllocator(scope.allocator(), message.id))) |cached| {
                    var retained = cached;
                    copyMembership(&retained, message.*);
                    retained.bodyCached = retained.bodyCacheError.len == 0;
                    message.* = retained;
                }
            }
            message.* = try gmail_decode.retainThreadMessage(message.*, a, &remaining);
            const full = message.bodyCached or message.bodyCacheError.len > 0;
            if (full) try store.rememberAttachments(message.*);
            if (store.state.generation == expected) try store.put(message.*, full) else if (full) try retainReadBody(store, message.*);
            response.deferredMessages += @intFromBool(!message.bodyCached and message.bodyCacheError.len == 0);
            response.partial = response.partial or message.metadataPartial or message.bodyCacheError.len > 0;
        }
        response.partial = response.partial or response.deferredMessages > 0;
        response.messages = messages;
        try store.save();
        return mail_value.borrowed(a, response);
    }
    fn fixtureProgressiveThread(s: *Session, a: std.mem.Allocator, store: *storage.Store, source: Value, req: Value) !?Value {
        const windows = @import("thread_window.zig");
        const thread = try j.required(req, "threadId");
        const raw = try array(source, "messages");
        var members: std.ArrayList(windows.Member) = .empty;
        for (raw, 0..) |value, index| if (std.mem.eql(u8, j.text(value, "threadId"), thread)) {
            if (members.items.len == windows.maximum) return error.ThreadTooLarge;
            const id = try j.required(value, "id");
            try @import("../bounded.zig").identifier(id);
            for (members.items) |previous| if (std.mem.eql(u8, previous.id, id)) return error.DuplicateMessage;
            const received = if (j.get(value, "internalDate")) |date| @import("../bounded.zig").integer(date) catch 0 else 0;
            try members.append(a, .{ .id = id, .received_at = received, .source_index = index });
        };
        for (store.state.outbox, 0..) |entry, index| if (std.mem.eql(u8, entry.threadId, thread)) {
            if (members.items.len == windows.maximum) return error.ThreadTooLarge;
            for (members.items) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateMessage;
            try members.append(a, .{ .id = entry.id, .received_at = entry.receivedAt, .source_index = raw.len + index });
        };
        if (members.items.len <= windows.limit and j.text(req, "beforeMessageId").len == 0 and j.text(req, "afterMessageId").len == 0 and j.text(req, "windowStartMessageId").len == 0 and j.text(req, "windowEndMessageId").len == 0) return null;
        std.sort.heap(windows.Member, members.items, {}, windows.older);
        const window = try windows.choose(members.items, req);
        var messages: std.ArrayList(t.Message) = .empty;
        var remaining: usize = t.Limits.thread_bytes;
        for (members.items[window.start..window.end], window.start..) |member, index| {
            try s.io.checkCancel();
            var scope: std.heap.ArenaAllocator = .init(s.allocator);
            defer scope.deinit();
            const temp = scope.allocator();
            var message = if (member.source_index < raw.len) (if (index == window.focus) try s.normalize(temp, source, raw[member.source_index]) else metadata: {
                // The fixture source contains full MIME. Match the provider's
                // metadata projection before decoding an unopened card.
                const original = raw[member.source_index];
                const payload = j.get(original, "payload") orelse return error.InvalidProviderResponse;
                const projected = try j.value(temp, .{ .id = member.id, .threadId = thread, .internalDate = j.text(original, "internalDate"), .labelIds = j.get(original, "labelIds") orelse .null, .snippet = j.text(original, "snippet"), .payload = .{ .mimeType = j.text(payload, "mimeType"), .headers = j.get(payload, "headers") orelse .null } });
                break :metadata try gmail_decode.normalizeMetadata(projected, temp);
            }) else store.state.outbox[member.source_index - raw.len];
            if (index == window.focus and member.source_index >= raw.len) message = (try store.readOutboxWithAllocator(temp, member.id)) orelse return error.MessageNotFound;
            message.bodyCached = index == window.focus and message.bodyCacheError.len == 0;
            try messages.append(a, try gmail_decode.retainThreadMessage(message, a, &remaining));
        }
        const result = try mail_value.borrowed(a, windows.response(messages.items, members.items.len, window));
        return try s.retainProgressiveThread(a, store, result, store.state.generation);
    }
    fn normalize(_: *Session, a: std.mem.Allocator, source: Value, v: Value) !t.Message {
        return @import("gmail_decode.zig").normalize(v, a, j.get(source, "externalBodies"));
    }
    fn read(s: *Session, a: std.mem.Allocator, store: *storage.Store, id: []const u8, req: Value) !t.Message {
        return s.readMessage(a, store, id, req, true);
    }
    const ConversationAttachments = struct {
        session: *Session,
        store: *storage.Store,
        request: Value,
        fn adapter(self: *@This()) conversation_source.Attachments {
            return .{ .context = self, .fetchFn = fetch };
        }
        fn fetch(ctx: *anyopaque, a: std.mem.Allocator, message: t.Message, attachment: t.Attachment) !t.Attachment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var request = try j.copyObject(a, self.request);
            try request.object.put(a, "attachmentId", .{ .string = attachment.id });
            return self.session.fetchKnownAttachment(a, self.store, request, message);
        }
    };
    fn captureOriginal(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, message: t.Message) !t.Original {
        const plan = try @import("original_mail.zig").resourcePlanWithLimit(message.bodyHtml orelse return error.OriginalHtmlUnavailable, message.attachments, t.Limits.attachment_bytes);
        var selected = message;
        const resources = try a.alloc(t.Attachment, plan.count);
        for (plan.indices[0..plan.count], resources) |index, *resource| resource.* = message.attachments[index];
        selected.attachments = resources;
        const prepared = try s.prepareForwardAttachments(a, store, req, selected, true);
        var source: ConversationAttachments = .{ .session = s, .store = store, .request = req };
        return conversation_source.captureOriginal(a, prepared, source.adapter());
    }
    fn prepareForwardAttachments(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, message: t.Message, preserve: bool) !t.Message {
        if (message.attachments.len > (if (preserve) t.Limits.attachments + t.Limits.related_resources else t.Limits.attachments)) return error.TooManyAttachments;
        var total: usize = 0;
        var embedded: usize = 0;
        for (message.attachments) |attachment| {
            total = std.math.add(usize, total, attachment.size) catch return error.AttachmentsTooLarge;
            if (attachment.blobId == null) embedded = std.math.add(usize, embedded, attachment.size) catch return error.AttachmentsTooLarge;
        }
        if (total > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
        if (preserve) {
            if (message.bodyHtmlAmbiguous) return error.AmbiguousOriginalHtml;
            _ = try @import("original_mail.zig").resourcePlanWithLimit(message.bodyHtml orelse return error.OriginalHtmlUnavailable, message.attachments, t.Limits.attachment_bytes);
        }
        if (!preserve and embedded <= t.Limits.body_bytes) return message;
        var prepared = message;
        const attachments = try a.dupe(t.Attachment, message.attachments);
        // Every formatted capture externalizes resources from its first image,
        // so an accumulating reply never grows JSON frames with image bytes.
        // Ordinary forwards retain their existing small portable tier.
        for (attachments) |*attachment| if (attachment.blobId == null and attachment.size != 0) {
            var request = try j.copyObject(a, req);
            try request.object.put(a, "attachmentId", .{ .string = attachment.id });
            attachment.* = try s.spillAttachment(a, store, request, message.id, attachment.*, false);
        };
        prepared.attachments = attachments;
        return prepared;
    }
    fn reserveIncoming(s: *Session, a: std.mem.Allocator, store: *storage.Store, size: usize) !@import("attachment_blob.zig").Incoming {
        const account = store.state.account;
        store.release();
        var name: [64]u8 = undefined;
        var incoming = blk: {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var latest = try s.openStore(phase.allocator(), account, false);
            defer latest.close();
            var pending = try @import("attachment_blob.zig").Incoming.create(&latest, size);
            errdefer pending.close();
            if (pending.name.len > name.len) return error.InvalidAttachmentHandle;
            @memcpy(name[0..pending.name.len], pending.name);
            pending.name = name[0..pending.name.len];
            break :blk pending;
        };
        errdefer incoming.close();
        // Handles belong to Incoming. Retain its generated name only after
        // releasing the temporary cache snapshot and its allocator chunks.
        incoming.name = try a.dupe(u8, incoming.name);
        return incoming;
    }
    fn commitIncoming(s: *Session, a: std.mem.Allocator, store: *storage.Store, incoming: *@import("attachment_blob.zig").Incoming, attachment: t.Attachment, reopen_after: bool) !t.Attachment {
        store.release();
        var blob_id: [64]u8 = undefined;
        const result = blk: {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var latest = try s.openStore(phase.allocator(), store.state.account, false);
            defer latest.close();
            var committed = try incoming.commit(&latest, attachment);
            const id = committed.blobId orelse return error.InvalidAttachmentHandle;
            try @import("draft_codec.zig").validateAttachmentHandle(id);
            @memcpy(&blob_id, id);
            committed.blobId = &blob_id;
            break :blk committed;
        };
        // Incoming.commit preserves caller-owned descriptor fields, replacing
        // only data and the verified blob ID. Reclaim the entire cache snapshot
        // before retaining that tiny result in the command arena; interleaving
        // the two arenas prevents in-place growth and retains oversized slabs.
        const retained = try @import("gmail.zig").retainAttachment(a, result);
        if (reopen_after) try s.reopenBody(a, store);
        return retained;
    }
    fn spillAttachment(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, message_id: []const u8, attachment: t.Attachment, reopen_after: bool) !t.Attachment {
        var incoming = try s.reserveIncoming(a, store, attachment.size);
        defer incoming.close();
        const downloaded = blk: {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var buffer: [64 * 1024]u8 = undefined;
            var writer = incoming.writer(&buffer);
            const value = if (attachment.data.len > 0 or attachment.size == 0) inline_data: {
                try @import("gmail.zig").writeAttachmentData(&writer.interface, attachment);
                break :inline_data attachment;
            } else if (s.options.fixtures) fixture: {
                var peer: FixtureRemote = .{ .session = s, .source = try s.fixture(phase.allocator(), store.state.account) };
                break :fixture try @import("gmail.zig").attachmentAuthorizedToWriter(phase.allocator(), store.state.account, &.{"mail-read"}, peer.transport(), message_id, attachment, &writer.interface);
            } else try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(@import("../attachment_limits.zig").download_seconds), @import("gmail.zig").executeAttachmentToWriterWithAllocator, .{ s.io, phase.allocator(), s.allocator, &s.config, store.state.account, req, attachment, &writer.interface });
            try writer.flush();
            var metadata = value;
            metadata.data = "";
            break :blk try @import("gmail.zig").retainAttachment(a, metadata);
        };
        try incoming.finish(downloaded.size);
        return s.commitIncoming(a, store, &incoming, downloaded, reopen_after);
    }
    fn forwardRaw(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, format: t.BodyFormat) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        const id = try j.required(req, "messageId");
        var incoming = try s.reserveIncoming(a, store, t.Limits.attachment_bytes);
        defer incoming.close();
        const size = blk: {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var buffer: [64 * 1024]u8 = undefined;
            var writer = incoming.writer(&buffer);
            const bytes = if (s.options.fixtures) fixture: {
                const source = try s.fixture(phase.allocator(), store.state.account);
                for (try array(source, "messages")) |message| if (std.mem.eql(u8, j.text(message, "id"), id)) {
                    var decoder = try @import("attachment_json.zig").Decoder.initRaw(&writer.interface, id);
                    std.json.Stringify.value(.{ .id = j.text(message, "id"), .raw = try j.required(message, "raw") }, .{}, &decoder.writer) catch |err| return decoder.failure orelse err;
                    try decoder.finish();
                    break :fixture decoder.bytes;
                };
                return error.MessageNotFound;
            } else try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(@import("../attachment_limits.zig").download_seconds), @import("gmail.zig").executeRawMessageToWriter, .{ s.io, s.allocator, &s.config, store.state.account, req, &writer.interface });
            try writer.flush();
            break :blk bytes;
        };
        try incoming.finish(size);
        if (incoming.sealed != null) try s.reopenBody(a, store);
        const draft = if (size <= t.Limits.body_bytes) small: {
            // Keep the portable representation for small originals; the
            // download/decode phase has already been reclaimed before this.
            const raw = try a.alloc(u8, size);
            var source = try incoming.reader();
            defer source.close();
            var offset: usize = 0;
            while (offset < raw.len) {
                const count = try @import("attachment_blob.zig").Incoming.Reader.read(&source, raw[offset..]);
                if (count == 0) return error.BodySizeMismatch;
                offset += count;
            }
            var extra: [1]u8 = undefined;
            if (try @import("attachment_blob.zig").Incoming.Reader.read(&source, &extra) != 0) return error.BodySizeMismatch;
            break :small try conversation_source.forwardRaw(a, raw, format);
        } else large: {
            const source = source: {
                var reader = try incoming.reader();
                defer reader.close();
                break :source try @import("mime.zig").originalSourceStream(a, .{ .ctx = &reader, .readFn = @import("attachment_blob.zig").Incoming.Reader.read }, size);
            };
            const attachments = try a.alloc(t.Attachment, 1);
            attachments[0] = try s.commitIncoming(a, store, &incoming, source.attachment, false);
            const large_draft: t.Draft = .{
                .subject = if (std.ascii.startsWithIgnoreCase(source.subject, "Fwd:")) source.subject else try std.fmt.allocPrint(a, "Fwd: {s}", .{source.subject}),
                .bodyFormat = format,
                .attachments = attachments,
            };
            try validateDraft(large_draft, false);
            break :large large_draft;
        };
        if (!store.lockHeld) try s.reopenBody(a, store);
        if (s.options.fixtures) store.state.fixtureCalls += 1;
        return mail_value.borrowed(a, try store.putDraft(draft, null));
    }
    fn exactAttachment(attachments: []const t.Attachment, id: []const u8) !?t.Attachment {
        var selected: ?t.Attachment = null;
        for (attachments) |attachment| if (std.mem.eql(u8, attachment.id, id)) {
            if (selected != null) return error.AmbiguousAttachment;
            selected = attachment;
        };
        return selected;
    }
    const AttachmentSnapshot = struct { thread_id: []const u8, attachment: t.Attachment };
    fn pinAttachment(store: *storage.Store, message_id: []const u8, attachment_id: []const u8) !?AttachmentSnapshot {
        const receipt = try @import("attachment_receipts.zig").find(store.state.attachmentReceipts, message_id, attachment_id);
        if (store.find(message_id)) |entry| if (try exactAttachment(entry.message.attachments, attachment_id)) |attachment| {
            if (receipt) |verified| if (!std.mem.eql(u8, verified.threadId, entry.message.threadId) or !sameAttachmentIdentity(verified.attachment, attachment)) return error.AmbiguousAttachment;
            return .{ .thread_id = entry.message.threadId, .attachment = attachment };
        };
        if (receipt) |verified| return .{ .thread_id = verified.threadId, .attachment = verified.attachment };
        return null;
    }
    fn knownAttachment(message: t.Message, attachment_id: []const u8, snapshot: ?AttachmentSnapshot) !t.Attachment {
        if (try exactAttachment(message.attachments, attachment_id)) |attachment| return attachment;
        // A FULL thread response can issue new opaque attachment tokens while
        // the immutable cached body retains its earlier descriptors. Its
        // verified metadata still records the exact token shown in the thread.
        // Pin it before reading: an evicted/refused body requires a fresh FULL
        // read, which may replace that metadata with yet another provider token.
        // Resolve only that same message's exact ID, never a filename or a
        // neighbor's attachment. The bounded receipt table retains previously
        // displayed versions across later reads; never-observed IDs still fail.
        const selected = snapshot orelse return error.AttachmentNotFound;
        if (!std.mem.eql(u8, selected.thread_id, message.threadId)) return error.MessageIdentityMismatch;
        return selected.attachment;
    }
    fn retainReadBody(store: *storage.Store, message: t.Message) !void {
        const retained = store.find(message.id) orelse return;
        if (!std.mem.eql(u8, retained.message.threadId, message.threadId)) return error.MessageIdentityMismatch;
        _ = try store.putBody(message);
        if (message.bodyCacheError.len != 0 or message.metadataPartial) return;
        // A concurrent refresh owns current labels and ordering. A FULL read
        // can still verify new opaque attachment tokens for the retained ID,
        // even when putBody keeps an older immutable body. Never resurrect an
        // evicted message or overwrite another message/thread's descriptors.
        const entry = store.find(message.id) orelse return;
        if (!std.mem.eql(u8, entry.message.threadId, message.threadId)) return error.MessageIdentityMismatch;
        const metadata = @constCast(try draft_summary.attachmentMetadata(store.allocator, message.attachments));
        for (metadata) |*attachment| {
            if (attachment.blobId != null) continue;
            const previous = (try exactAttachment(entry.message.attachments, attachment.id)) orelse continue;
            if (previous.blobId != null and sameAttachmentIdentity(previous, attachment.*)) attachment.blobId = previous.blobId;
        }
        entry.message.attachments = metadata;
    }
    fn sameAttachmentIdentity(left: t.Attachment, right: t.Attachment) bool {
        if (left.size != right.size) return false;
        inline for (.{ "id", "filename", "mimeType" }) |field| {
            if (!std.mem.eql(u8, @field(left, field), @field(right, field))) return false;
        }
        inline for (.{ "contentId", "disposition", "contentLocation" }) |field| {
            const old = @field(left, field);
            const current = @field(right, field);
            if ((old == null) != (current == null)) return false;
            if (old) |value| if (!std.mem.eql(u8, value, current.?)) return false;
        }
        return true;
    }
    fn fetchKnownAttachment(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, known_message: ?t.Message) !t.Attachment {
        try s.capability(a, store.state.account, req, "mail-read");
        const message_id = try j.required(req, "messageId");
        const attachment_id = try j.required(req, "attachmentId");
        const snapshot = try pinAttachment(store, message_id, attachment_id);
        const message = known_message orelse try s.read(a, store, message_id, req);
        if (!std.mem.eql(u8, message.id, message_id)) return error.MessageIdentityMismatch;
        const selected = try knownAttachment(message, attachment_id, snapshot);
        return s.fetchSelectedAttachment(a, store, req, message_id, selected, known_message == null);
    }
    fn verifyAttachmentBacking(s: *Session, store: *storage.Store, selected: t.Attachment) !void {
        // Downloading earlier parts releases the caller's transaction. Its
        // encrypted object map also predates any newly committed blob. Borrow
        // one current transaction for verification, then reclaim its index
        // before hydrating the next part or reopening the draft transaction.
        if (store.vault != null and !store.lockHeld) {
            var phase: std.heap.ArenaAllocator = .init(s.allocator);
            defer phase.deinit();
            var current = try s.openStore(phase.allocator(), store.state.account, true);
            defer current.close();
            var stream = try @import("attachment_blob.zig").Stream.init(&current, selected);
            stream.close();
            return;
        }
        var stream = try @import("attachment_blob.zig").Stream.init(store, selected);
        stream.close();
    }
    fn fetchSelectedAttachment(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, message_id: []const u8, selected: t.Attachment, reopen_after: bool) !t.Attachment {
        if (selected.blobId != null) {
            s.verifyAttachmentBacking(store, selected) catch |err| {
                if (err != error.AttachmentHandleNotFound) return err;
                // A local cache miss does not invalidate the same message's
                // verified provider descriptor. Corruption is never retried.
                var remote_attachment = selected;
                remote_attachment.blobId = null;
                return s.spillAttachment(a, store, req, message_id, remote_attachment, reopen_after);
            };
            return selected;
        }
        if (selected.data.len > 0 or selected.size == 0) return selected;
        if (selected.size > t.Limits.body_bytes) return s.spillAttachment(a, store, req, message_id, selected, reopen_after);
        if (s.options.fixtures) {
            var phase = std.heap.ArenaAllocator.init(s.allocator);
            defer phase.deinit();
            var fixture_peer: FixtureRemote = .{ .session = s, .source = try s.fixture(phase.allocator(), store.state.account) };
            const downloaded = try @import("gmail.zig").attachmentAuthorized(phase.allocator(), store.state.account, &.{"mail-read"}, fixture_peer.transport(), message_id, selected);
            return @import("gmail.zig").retainAttachment(a, downloaded);
        }
        const account = store.state.account;
        store.release();
        const downloaded = try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").executeAttachmentWithAllocator, .{ s.io, a, s.allocator, &s.config, account, req, selected, s.progress_sink });
        // Conversation capture needs current cache state only when saving the
        // completed draft; per-file snapshots belong to short arenas above.
        if (reopen_after) try s.reopenBody(a, store);
        return downloaded;
    }
    fn saveKnownAttachment(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        const message_id = try j.required(req, "messageId");
        const attachment_id = try j.required(req, "attachmentId");
        const path = try j.required(req, "path");
        if (path.len == 0 or path.len > 4096 or !@import("file_dialog.zig").validText(path)) return error.InvalidAttachmentPath;
        const leaf = std.fs.path.basename(path);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidAttachmentPath;
        const snapshot = try pinAttachment(store, message_id, attachment_id);
        const message = try s.read(a, store, message_id, req);
        if (!std.mem.eql(u8, message.id, message_id)) return error.MessageIdentityMismatch;
        const attachment = try knownAttachment(message, attachment_id, snapshot);
        if (attachment.size > t.Limits.incoming_attachment_bytes) return error.AttachmentsTooLarge;
        var directory = try @import("path_completion.zig").openDirectory(s.io, std.fs.path.dirname(path) orelse ".", false);
        defer directory.close(s.io);
        var destination = try directory.createFileAtomic(s.io, leaf, .{ .permissions = .fromMode(0o600), .replace = false });
        defer destination.deinit(s.io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = destination.file.writer(s.io, &buffer);
        var local: ?@import("attachment_blob.zig").Stream = if (attachment.blobId != null) @import("attachment_blob.zig").Stream.init(store, attachment) catch |err| if (err == error.AttachmentHandleNotFound) null else return err else null;
        if (local) |*source| {
            defer source.close();
            var chunk: [64 * 1024]u8 = undefined;
            while (true) {
                const count = try @import("attachment_blob.zig").Stream.read(source, &chunk);
                if (count == 0) break;
                try writer.interface.writeAll(chunk[0..count]);
            }
        } else if (attachment.data.len > 0 or attachment.size == 0) {
            try @import("gmail.zig").writeAttachmentData(&writer.interface, attachment);
        } else {
            if (s.options.fixtures) {
                var phase = std.heap.ArenaAllocator.init(s.allocator);
                defer phase.deinit();
                var peer: FixtureRemote = .{ .session = s, .source = try s.fixture(phase.allocator(), store.state.account) };
                _ = try @import("gmail.zig").attachmentAuthorizedToWriter(phase.allocator(), store.state.account, &.{"mail-read"}, peer.transport(), message_id, attachment, &writer.interface);
            } else {
                const account = store.state.account;
                store.release();
                _ = try @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(@import("../attachment_limits.zig").download_seconds), @import("gmail.zig").executeAttachmentToWriterWithAllocator, .{ s.io, a, s.allocator, &s.config, account, req, attachment, &writer.interface });
            }
        }
        try writer.flush();
        try destination.file.sync(s.io);
        try destination.link(s.io);
        return j.value(a, .{ .saved = true, .path = path, .filename = attachment.filename, .size = attachment.size });
    }
    fn retryComposeSizeRefusal(command: []const u8, body_error: []const u8) bool {
        if (!@import("send_memory.zig").native) return false;
        if (!std.mem.eql(u8, command, "mail.reply") and !std.mem.eql(u8, command, "mail.forward")) return false;
        for ([_][]const u8{ "BodyTooLarge", "DecodedMessageTooLarge", "MessageTooLarge", "ResponseTooLarge", "MessageBudgetExceeded", "ThreadBodyBudgetExceeded", "JsonTooManyTokens", "ComposeSourceRequired" }) |code| {
            if (std.mem.eql(u8, body_error, code)) return true;
        }
        return false;
    }
    fn readMessage(s: *Session, a: std.mem.Allocator, store: *storage.Store, id: []const u8, req: Value, allow_cached: bool) !t.Message {
        try s.capability(a, store.state.account, req, "mail-read");
        var fixture_source: ?Value = null;
        if (s.options.fixtures) {
            if (if (@import("send_memory.zig").command(j.text(req, "cmd"))) try store.readOutboxExpandedWithAllocator(a, id) else try store.readOutbox(id)) |sent| return sent;
            if (store.state.fixtureProvider.len != 0) fixture_source = try s.fixtureProviderSource(a, store);
        }
        if (if (allow_cached) (if (@import("send_memory.zig").command(j.text(req, "cmd"))) try store.readExpandedWithAllocator(a, id) else try store.read(id)) orelse store.refusedMessage(id) else null) |cached| retained: {
            // A normal reader's size/scratch refusal is not the native compose
            // tier's limit. Explicit reply/forward gets one fresh complete
            // source read; the normal decoder and integrity refusals stay strict.
            if (retryComposeSizeRefusal(j.text(req, "cmd"), cached.bodyCacheError)) break :retained;
            var m = cached;
            if (store.find(id)) |entry| {
                copyMembership(&m, entry.message);
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
            try store.rememberAttachments(m);
            if (!allow_cached) _ = try store.upgradeInvitation(m);
            if (store.state.generation == expected) try store.put(m, true) else {
                try retainReadBody(store, m);
                if (store.find(m.id)) |entry| {
                    copyMembership(&m, entry.message);
                }
            }
            try store.save();
            return m;
        }
        // Reconciliation already loaded the complete source when provider
        // overlays exist. Reuse it for an uncached body in this same request.
        const source = fixture_source orelse try s.fixtureProviderSource(a, store);
        for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "id"), id)) {
            s.reportProgress(.bodies, 0, 1);
            try s.fixtureProgressGate(a, source, .bodies, 0);
            var m = if (@import("send_memory.zig").command(j.text(req, "cmd"))) try gmail_decode.normalizeForCompose(v, a, j.get(source, "externalBodies")) else try s.normalize(a, source, v);
            if (store.find(id)) |existing| {
                copyMembership(&m, existing.message);
            }
            store.state.fixtureCalls += 1;
            try store.rememberAttachments(m);
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
                copyMembership(&m, e.message);
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
                store.state.contactWarnings = .{};
                try store.save();
            }
            const result = try s.remote(a, store.state.account, cmd, req);
            // Provider writes already validate the contact receipt. Return it
            // directly; refresh the invalidated cache on the next contacts read
            // rather than risking a cache failure after a successful create.
            // A provider search is a temporary filtered view. It must not erase
            // the cached head or its retained omission/warning receipt.
            if (write or std.mem.eql(u8, cmd, "contacts.search")) return result;
            store.state.contacts = try j.decode([]t.Contact, a, j.get(result, "contacts") orelse return error.InvalidProviderResponse);
            store.state.contactWarnings = if (j.get(result, "contactWarnings")) |warnings| try j.decode(t.ContactReadWarnings, a, warnings) else .{};
            store.state.contactsReady = true;
            try store.save();
            return result;
        }
        if (store.state.contacts.len == 0 and !store.state.contactsReady) {
            if (s.options.fixture_root) |root| {
                const key = if (std.mem.eql(u8, store.state.account, "personal@example.com")) "personal" else if (std.mem.eql(u8, store.state.account, "work@example.com")) "work" else "optional";
                var scope: std.heap.ArenaAllocator = .init(s.allocator);
                defer scope.deinit();
                const temporary = scope.allocator();
                const raw = try std.Io.Dir.cwd().readFileAlloc(s.io, try std.fmt.allocPrint(temporary, "{s}/contacts/{s}.json", .{ root, key }), temporary, .limited(4 * 1024 * 1024));
                const source = try std.json.parseFromSliceLeaky(Value, temporary, raw, .{});
                const page = try @import("contact_record.zig").readPage(a, s.allocator, source, .{});
                store.state.contacts = page.contacts;
                store.state.contactWarnings = page.contactWarnings;
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
            return j.value(a, .{ .contacts = contacts_list.items, .partial = store.state.contactWarnings.any(), .contactWarnings = store.state.contactWarnings });
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
    fn recoveryForkAllowed(store: *storage.Store, draft_id: []const u8) !bool {
        const history = @import("operation_history.zig");
        if (try history.source(store, store.allocator, draft_id) == null and !try history.immutableSource(store, draft_id)) return false;
        try guardRecoveryCopy(store, draft_id);
        return true;
    }
    fn guardRecoveryCopy(store: *storage.Store, draft_id: []const u8) !void {
        var found = false;
        for (store.state.drafts) |draft| found = found or std.mem.eql(u8, draft.id, draft_id);
        if (!found and try @import("operation_history.zig").source(store, store.allocator, draft_id) == null) return error.DraftNotFound;
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.draftId, draft_id) and std.mem.eql(u8, operation.outcome, "unknown")) return error.UnknownOutcome;
        for (store.state.sendQueue) |entry| if (std.mem.eql(u8, entry.draftId, draft_id)) switch (entry.state) {
            .queued => return error.DraftQueued,
            .submitting, .unknown => return error.UnknownOutcome,
            else => {},
        };
        for (store.state.draftLinks) |link| if (std.mem.eql(u8, link.draftId, draft_id)) {
            if (link.paused) return error.DraftPausedInGmail;
            if (link.phase == .unknown) return error.GmailDraftOutcomeUnknown;
        };
    }
    fn queuedMutationReceipt(a: std.mem.Allocator, store: *storage.Store, entry: storage.QueuedSend) !Value {
        const result = send_queue.receipt(a, store, entry) catch |err| {
            // A send may already exist for these durable states. Keep that
            // uncertainty through the second, queue-level receipt encoder.
            if (err == error.OutOfMemory) switch (entry.state) {
                .submitting, .unknown, .applied => return error.UnknownOutcome,
                else => {},
            };
            return err;
        };
        if (entry.state == .applied) settleAcceptedSource(store);
        return result;
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
            const draft_id = try j.required(req, "draftId");
            const operation_id = try j.required(req, "operationId");
            const retained_source = try @import("operation_history.zig").source(store, a, draft_id) != null;
            if (retained_source or try @import("operation_history.zig").immutableSource(store, draft_id)) {
                var previous: ?storage.QueuedSend = null;
                for (store.state.sendQueue) |entry| if (std.mem.eql(u8, entry.operationId, operation_id)) {
                    previous = entry;
                    break;
                };
                if (previous == null) previous = try @import("operation_history.zig").queueOperation(store, a, operation_id);
                const entry = previous orelse return error.ArchivedDraftReadOnly;
                if (!std.mem.eql(u8, entry.draftId, draft_id)) return error.OperationConflict;
                try requireReviewedDigest(req, entry.hash);
                return queuedMutationReceipt(a, store, entry);
            }
            try store.requireActiveDraft(draft_id);
            const draft = try store.draft(draft_id);
            try validateDraft(draft, true);
            _ = try markdown_mail.prepare(a, draft);
            const digest = try operationDigest(a, draft, store.state.account, null);
            try requireReviewedDigest(req, &digest);
            try @import("draft_gmail_commands.zig").permitSend(store, a, req, draft, &digest);
            const entry = try send_queue.stage(store, draft.id, try j.required(req, "operationId"), &digest, std.Io.Timestamp.now(s.io, .real).toMilliseconds(), try send_queue.delay(req));
            return send_queue.receipt(a, store, entry.*);
        }
        const id = try j.required(req, "queueId");
        if (std.mem.eql(u8, cmd, "queue.read")) return send_queue.receipt(a, store, (try send_queue.find(store, id)).*);
        if (std.mem.eql(u8, cmd, "queue.cancel")) return send_queue.receipt(a, store, (try send_queue.cancel(store, id)).*);
        if (std.mem.eql(u8, cmd, "queue.resume")) {
            try s.capability(a, store.state.account, req, "mail-send");
            try requireReviewedDigest(req, (try send_queue.find(store, id)).hash);
            return send_queue.receipt(a, store, (try send_queue.resumeEntry(store, id, std.Io.Timestamp.now(s.io, .real).toMilliseconds(), try send_queue.delay(req))).*);
        }
        const send_now = std.mem.eql(u8, cmd, "queue.send-now");
        if (!send_now and !std.mem.eql(u8, cmd, "queue.process")) return error.UnsupportedCommand;
        const wait_for_due = try j.boolean(req, "wait", false);
        if (send_now and wait_for_due) return error.WaitRequiresQueueProcess;
        try s.capability(a, store.state.account, req, "mail-send");
        var entry = try send_queue.find(store, id);
        try requireReviewedDigest(req, entry.hash);
        if (entry.state != .queued or (entry.resumeRequired and !send_now)) return queuedMutationReceipt(a, store, entry.*);
        const remaining = entry.dueAtMs - std.Io.Timestamp.now(s.io, .real).toMilliseconds();
        // Send now claims the same reviewed intent through the normal durable
        // submission path. It skips only the countdown, never the draft hash,
        // account capability, claim or uncertain-outcome protections.
        if (remaining > 0 and !send_now) {
            if (!wait_for_due) return error.QueueNotDue;
            if (remaining > 30000) return error.QueueClockChanged;
            store.release();
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(remaining) }).sleep(s.io);
            try s.reopenBody(a, store);
            entry = try send_queue.find(store, id);
            if (entry.state != .queued or entry.resumeRequired) return queuedMutationReceipt(a, store, entry.*);
            if (entry.dueAtMs > std.Io.Timestamp.now(s.io, .real).toMilliseconds()) return error.QueueNotDue;
        }
        const draft = try store.draft(entry.draftId);
        const digest = try operationDigest(a, draft, store.state.account, null);
        if (!std.mem.eql(u8, entry.hash, &digest)) {
            entry.state = .canceled;
            entry.errorCode = "DraftChanged";
            try store.save();
            return send_queue.receipt(a, store, entry.*);
        }
        // Prepare the derived request while the queue is still safely queued.
        // An allocation failure here cannot have submitted anything and must
        // not strand the entry behind a durable submitting fence.
        var request = try j.copyObject(a, req);
        try request.object.put(a, "cmd", .{ .string = "draft.send" });
        try request.object.put(a, "draftId", .{ .string = entry.draftId });
        try request.object.put(a, "operationId", .{ .string = entry.operationId });
        // The durable claim precedes any send code. After a crash, submitting
        // remains fenced even if the operation journal was not written yet.
        entry.resumeRequired = false;
        entry.state = .submitting;
        try store.save();
        const sent = s.send(a, store, request, draft, null, true) catch |err| {
            entry = try send_queue.find(store, id);
            entry.state = .rejected;
            entry.errorCode = @errorName(err);
            for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, entry.operationId)) {
                entry.state = .unknown;
                break;
            };
            store.save() catch return error.UnknownOutcome;
            return queuedMutationReceipt(a, store, entry.*);
        };
        entry = try send_queue.find(store, id);
        entry.state = if (std.mem.eql(u8, j.text(sent, "outcome"), "applied")) .applied else if (std.mem.eql(u8, j.text(sent, "outcome"), "rejected")) .rejected else .unknown;
        entry.errorCode = j.text(sent, "errorCode");
        store.save() catch return error.UnknownOutcome;
        return queuedMutationReceipt(a, store, entry.*);
    }
    fn settleAcceptedSource(store: *storage.Store) void {
        const previous_protected = store.history_protected_draft;
        store.history_protected_draft = "";
        defer store.history_protected_draft = previous_protected;
        // The applied receipt is already durable. A housekeeping failure must
        // not turn acceptance into a retryable failure; Store's immutable
        // source guard preserves it until a later successful archive.
        @import("operation_history.zig").compact(store, true) catch {};
    }
    fn settledMutationReceipt(a: std.mem.Allocator, store: *storage.Store, operation: storage.Operation, final: bool) !Value {
        const result = try mutationReceipt(a, operation);
        if (final and std.mem.eql(u8, operation.outcome, "applied")) settleAcceptedSource(store);
        return result;
    }
    fn reopenSendOperation(s: *Session, a: std.mem.Allocator, store: *storage.Store, previous: *storage.Operation) !*storage.Operation {
        if (store.vault == null or store.lockHeld) return previous;
        try s.reopenBody(a, store);
        for (store.state.operations) |*current| if (std.mem.eql(u8, current.id, previous.id)) {
            if (!std.mem.eql(u8, current.hash, previous.hash)) return error.UnknownOutcome;
            return current;
        };
        return error.UnknownOutcome;
    }
    fn send(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, draft: t.Draft, calendar: ?[]const u8, claimed_queue: bool) !Value {
        const previous_protected = store.history_protected_draft;
        store.history_protected_draft = if (std.mem.eql(u8, j.text(req, "cmd"), "draft.send")) draft.id else "";
        defer store.history_protected_draft = previous_protected;
        try s.capability(a, store.state.account, req, if (calendar != null) "calendar-rsvp" else "mail-send");
        try validateDraft(draft, true);
        const operation_id = try j.required(req, "operationId");
        if (operation_id.len > 256) return error.InvalidOperationId;
        try recipients.validateHeader(operation_id);
        const digest = try operationDigest(a, draft, store.state.account, calendar);
        try requireReviewedDigest(req, &digest);
        try @import("draft_gmail_commands.zig").permitSend(store, a, req, draft, &digest);
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
        if (try store.findOperation(a, operation_id)) |operation| {
            if (!std.mem.eql(u8, operation.hash, &digest)) return error.OperationConflict;
            return settledMutationReceipt(a, store, operation, !claimed_queue and calendar == null);
        }
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and (std.mem.eql(u8, operation.hash, &digest) or (draft.id.len > 0 and std.mem.eql(u8, operation.draftId, draft.id)))) return settledMutationReceipt(a, store, operation, !claimed_queue and calendar == null);
        if (draft.id.len != 0 and try @import("operation_history.zig").immutableSource(store, draft.id)) return error.ArchivedDraftReadOnly;
        try store.compactHistory();
        if (store.state.operations.len >= 1000) return error.OperationJournalFull;
        const prepared = try markdown_mail.prepare(a, draft);
        // The RSVP's verified attendee may be a send-as alias. Keep this wire
        // identity out of the canonical draft/fingerprint used by old receipts.
        var wire_draft = draft;
        if (calendar) |ics| {
            var reply: invitation.Invitation = .{};
            try invitation.parseReply(ics, store.state.account, try cachedAliases(a, store), &reply);
            if (draft.to.len != 1 or draft.cc.len != 0 or draft.bcc.len != 0 or !std.ascii.eqlIgnoreCase(draft.to[0].address, reply.organizer.slice())) return error.InvalidInvitationRecipient;
            wire_draft.from = .{ .address = try a.dupe(u8, reply.attendee.slice()) };
        }
        // Persist uncertainty before dispatch, including on process failure.
        var operations: std.ArrayList(storage.Operation) = .empty;
        const wire_identity = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ store.state.account, operation_id });
        const wire_hash = storage.Store.hash(wire_identity);
        var fixture_raw: ?[]const u8 = null;
        var spool: ?@import("send_spool.zig").Spool = null;
        defer if (spool) |*file| file.close();
        {
            var from: recipients.Mailbox = .{};
            const sender = wire_draft.from orelse t.Address{ .address = store.state.account };
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
            const mime = @import("mime.zig");
            var compose: mime.Compose = .{ .from = from, .destinations = .{ .to = draft.to, .cc = draft.cc, .bcc = draft.bcc }, .subject = draft.subject, .body = prepared.plain, .html = prepared.html, .inline_logo = prepared.html != null, .logo_offset = prepared.logoOffset, .calendar = calendar, .message_id = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{wire_hash}), .date = if (s.options.fixtures) "Mon, 05 Oct 2026 12:00:00 +0000" else try @import("gmail.zig").date(s.io, a, false), .in_reply_to = draft.inReplyTo, .references = draft.references };
            // Production sends always consume this one validated MIME spool.
            // Rebuilding the draft in the provider retained two renders plus
            // MIME/base64/JSON copies inside the same operation arena.
            if (!s.options.fixtures or @import("send_spool.zig").required(draft.attachments) or @import("send_spool.zig").required(prepared.resources)) {
                spool = try @import("send_spool.zig").create(store, compose, draft.attachments, prepared.resources);
            } else {
                compose.related = try mime.composeAttachments(prepared.resources, a);
                compose.attachments = try mime.composeAttachments(draft.attachments, a);
                // MIME base64 and the JSON transport's outer base64 both grow
                // inline files. Measure the actual wire before choosing the
                // transport, including preserved images and generated HTML.
                // A normal attachment must not hit the small JSON frame cap.
                var count_buffer: [16 * 1024]u8 = undefined;
                var counting = std.Io.Writer.Discarding.init(&count_buffer);
                try mime.encodeTo(compose, &counting.writer);
                const raw_size: usize = @intCast(counting.fullCount());
                if (raw_size > mime.max_raw_bytes or std.base64.url_safe_no_pad.Encoder.calcSize(raw_size) > t.Limits.request_bytes - 1024) {
                    spool = try @import("send_spool.zig").create(store, compose, draft.attachments, prepared.resources);
                } else {
                    const wire = try a.alloc(u8, raw_size);
                    const raw = mime.encode(compose, wire) catch |err| return if (err == error.WriteFailed) error.FormTooLarge else err;
                    if (s.options.fixtures) {
                        const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
                        fixture_raw = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
                    }
                }
            }
        }
        // Small synthetic sends retain their exact wire oracle even when
        // immutable blob handles selected the streaming implementation.
        if (s.options.fixtures) if (spool) |*file| if (file.size <= @import("mime.zig").max_raw_bytes) {
            var reader = try file.reader();
            defer reader.close();
            const raw = try a.alloc(u8, file.size);
            var offset: usize = 0;
            while (offset < raw.len) {
                const count = try @import("send_spool.zig").Spool.Reader.read(&reader, raw[offset..]);
                if (count == 0) return error.BodySizeMismatch;
                offset += count;
            }
            var end: [1]u8 = undefined;
            if (try @import("send_spool.zig").Spool.Reader.read(&reader, &end) != 0) return error.BodySizeMismatch;
            const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
            fixture_raw = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
        };
        // Keep direct-send content as a recoverable draft before uncertainty is recorded.
        const saved_draft = if (std.mem.eql(u8, j.text(req, "cmd"), "draft.send")) draft else try store.putDraft(draft, null);
        try operations.appendSlice(a, store.state.operations);
        try operations.append(a, .{ .id = operation_id, .hash = try a.dupe(u8, &digest), .draftId = saved_draft.id, .rfcMessageId = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{wire_hash}), .icalendar = calendar orelse "", .sourceInvitationHash = if (calendar != null) j.text(req, "_sourceInvitationHash") else "", .invitationCalendarId = if (calendar != null) j.text(req, "calendarId") else "" });
        store.state.operations = operations.items;
        try store.save();
        var operation = &store.state.operations[store.state.operations.len - 1];
        if (!s.options.fixtures) {
            if (store.vault != null) store.release();
            const result = @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(@import("send_memory.zig").seconds("mail.send")), @import("gmail.zig").executeSpool, .{ s.io, a, &s.config, store.state.account, req, wire_draft, &spool.?, operation.rfcMessageId }) catch |err| {
                operation = s.reopenSendOperation(a, store, operation) catch |reopen_error| {
                    operation.errorCode = @errorName(reopen_error);
                    operation.outcome = "unknown";
                    return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
                };
                if (!std.mem.eql(u8, operation.outcome, "unknown")) return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
                operation.errorCode = @errorName(err);
                operation.outcome = if (@import("send_outcome.zig").rejected(err)) "rejected" else "unknown";
                store.save() catch {
                    operation.outcome = "unknown";
                };
                return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
            };
            operation = s.reopenSendOperation(a, store, operation) catch |reopen_error| {
                operation.errorCode = @errorName(reopen_error);
                operation.outcome = "unknown";
                return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
            };
            if (!std.mem.eql(u8, operation.outcome, "unknown")) return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
            const outcome = j.text(result, "outcome");
            operation.outcome = if (std.mem.eql(u8, outcome, "applied")) "applied" else if (std.mem.eql(u8, outcome, "rejected")) "rejected" else "unknown";
            operation.messageId = j.text(result, "messageId");
            operation.errorCode = j.text(result, "errorCode");
            store.save() catch {
                operation.outcome = "unknown";
            };
            return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
        }
        store.state.fixtureCalls += 1;
        if (s.scenario("rejected-mutation")) operation.outcome = "rejected" else if (s.scenario("unknown-send")) operation.outcome = "unknown" else {
            store.state.fixtureSends += 1;
            operation.messageId = try store.nextId("sent");
            operation.outcome = if (s.scenario("applied-lost")) "unknown" else "applied";
            var sent_attachments: std.ArrayList(t.Attachment) = .empty;
            try sent_attachments.appendSlice(a, prepared.resources);
            try sent_attachments.appendSlice(a, draft.attachments);
            // Outgoing files may have no provider retrieval ID (RAW forwards
            // are one example). A synthetic Sent message, like a provider
            // response, owns a new message-scoped identity for every part.
            for (sent_attachments.items, 0..) |*attachment, index| attachment.id = try std.fmt.allocPrint(a, "{s}-part-{d}", .{ operation.messageId, index });
            const sent: t.Message = .{ .id = operation.messageId, .threadId = if (draft.threadId.len > 0) draft.threadId else operation.messageId, .from = wire_draft.from orelse t.Address{ .address = store.state.account }, .to = draft.to, .cc = draft.cc, .subject = draft.subject, .snippet = utf8Prefix(prepared.plain, 240), .bodyText = prepared.plain, .bodyHtml = prepared.html, .bodySource = .plain, .messageId = operation.rfcMessageId, .inReplyTo = draft.inReplyTo, .references = draft.references, .labels = &.{"SENT"}, .receivedAt = std.Io.Timestamp.now(s.io, .real).toMilliseconds(), .attachments = sent_attachments.items, .invitation = calendar, .fixtureRaw = fixture_raw };
            // Copy the receipt first: put() can grow the entries slice, never operations.
            store.putOutbox(sent) catch {
                operation.outcome = "unknown";
            };
            store.state.generation += 1;
        }
        store.save() catch {
            operation.outcome = "unknown";
        };
        return settledMutationReceipt(a, store, operation.*, !claimed_queue and calendar == null);
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
pub fn decodeAddresses(a: std.mem.Allocator, value: Value) ![]const t.Address {
    return draft_codec.decodeAddresses(a, value);
}
pub fn decodeDraft(a: std.mem.Allocator, value: Value) !t.Draft {
    return draft_codec.decodeDraft(a, value);
}
fn requestBodyFormat(value: Value) !t.BodyFormat {
    return draft_codec.requestBodyFormat(value);
}
pub fn validateDraft(draft: t.Draft, send: bool) !void {
    return draft_codec.validateDraft(draft, send);
}
fn copyMembership(message: *t.Message, metadata: t.Message) void {
    message.labels = metadata.labels;
    message.unread = metadata.unread;
    message.labelsVerified = metadata.labelsVerified;
    if (!metadata.labelsVerified) {
        message.metadataPartial = true;
        if (message.decodeWarning.len == 0) message.decodeWarning = metadata.decodeWarning;
    }
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
                if (separators > @max(65536, 128 * t.Limits.message_attachments)) return false;
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

test "mail response memory: borrowed DTO values preserve the owning JSON wire shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var message: t.Message = .{
        .id = "literal-message",
        .threadId = "literal-thread",
        .from = .{ .address = "Sender@EXAMPLE.test", .name = "Sender \"Café\"" },
        .to = &.{.{ .address = "self@example.test", .name = "Self" }},
        .cc = &.{.{ .address = "peer@example.test" }},
        .replyTo = &.{.{ .address = "reply@example.test" }},
        .subject = "Quoted \"subject\"",
        .bodyText = "Literal text\n\twith café and \\slashes.",
        .bodyHtml = "<p>Literal \"HTML\"</p>\n",
        .bodySource = .html,
        .messageId = "<literal@example.test>",
        .references = "<earlier@example.test>",
        .inReplyTo = "<earlier@example.test>",
        .labels = &.{ "INBOX", "Custom label" },
        .receivedAt = -1,
        .sentDate = "Fri, 09 Oct 2026 12:00:00 +0000",
        .unread = true,
        .bodyCached = true,
        .attachments = &.{.{ .id = "binary", .filename = "binary café.bin", .size = 4, .data = "AP-AfQ", .blobId = "owned-blob", .contentId = "<image@example.test>", .disposition = "inline", .contentLocation = "literal/image" }},
        .invitation = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
        .fixtureRaw = "Literal synthetic raw\r\n",
    };
    for ([_]?[]const u8{ message.bodyHtml, "", null }) |html| {
        message.bodyHtml = html;
        const expected = try std.json.Stringify.valueAlloc(a, try j.value(a, message), .{});
        const actual = try std.json.Stringify.valueAlloc(a, try mail_value.borrowed(a, message), .{});
        try std.testing.expectEqualStrings(expected, actual);
    }
    const thread = .{ .messages = @as([]const t.Message, &.{message}), .cached = true, .partial = true };
    try std.testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(a, try j.value(a, thread), .{}),
        try std.json.Stringify.valueAlloc(a, try mail_value.borrowed(a, thread), .{}),
    );
}

test "mail response memory: native and cached reads preserve two MiB HTML within the fixed runtime cap" {
    const testing_allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer fixture_arena.deinit();
    const fa = fixture_arena.allocator();
    const root = try std.fmt.allocPrint(fa, ".zig-cache/tmp/{s}/large-cached-html", .{tmp.sub_path});
    const account = "personal@example.com";
    const html = try fa.alloc(u8, t.Limits.body_bytes);
    const prefix = "<html><body><h1>Fictional large HTML</h1><pre>Fictional personal@example.com: café 👋.\n";
    const suffix = "\nFictional large tail marker.</pre></body></html>";
    const line = "Fictional bounded navigation line.\n";
    @memcpy(html[0..prefix.len], prefix);
    const end = html.len - suffix.len;
    var pos = prefix.len;
    while (pos < end) {
        const count = @min(line.len, end - pos);
        @memcpy(html[pos..][0..count], line[0..count]);
        pos += count;
    }
    @memcpy(html[end..], suffix);
    const plain = try @import("mime.zig").htmlToText(html, fa);
    {
        var store = try storage.Store.open(std.testing.io, fa, root, account, .{ .fixtures = true, .metadata_limit = 40 });
        defer store.close();
        for (0..39) |index| try store.put(.{
            .id = try std.fmt.allocPrint(fa, "neighbor-{d}", .{index}),
            .threadId = "neighbor-thread",
            .subject = "Retained fictional neighbor",
            .receivedAt = @intCast(index),
            .labels = &.{"INBOX"},
        }, false);
        try store.put(.{ .id = "large-html", .threadId = "html-thread", .from = .{ .address = "sender@example.test", .name = "Fictional Sender" }, .to = &.{.{ .address = account }}, .subject = "Fictional large HTML", .bodyText = plain, .bodyHtml = html, .bodySource = .html, .labels = &.{"INBOX"}, .receivedAt = 100 }, true);
        try store.save();
    }
    // Match the production reusable backing heap and unchanged payload cap.
    // Fixture construction and independent response assertions stay outside it.
    const reservation = try testing_allocator.alloc(u8, @import("../fixed_runtime.zig").application_reservation);
    defer testing_allocator.free(reservation);
    var heap = @import("../fixed_heap.zig").Heap.init(reservation);
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = heap.allocator(), .limit = t.Limits.runtime_bytes, .reservation_bytes = reservation.len };
    const a = cap.allocator();
    var env = std.process.Environ.Map.init(testing_allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try a.create(Session);
    defer a.destroy(session);
    session.* = try Session.init(std.testing.io, a, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    session.meter = &cap;
    const baseline = cap.snapshot().allocatorUsedBytes;
    for ([_]bool{ false, true, false }) |cached_only| {
        {
            var output = std.heap.ArenaAllocator.init(a);
            defer output.deinit();
            const response = try session.executeMode(output.allocator(), "{\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"large-html\"}", cached_only);
            const parsed = try std.json.parseFromSlice(Value, testing_allocator, response, .{});
            defer parsed.deinit();
            try std.testing.expect(try j.boolean(parsed.value, "ok", false));
            const message = j.get(parsed.value, "data") orelse return error.MissingReadResponse;
            try std.testing.expectEqualStrings("large-html", j.text(message, "id"));
            try std.testing.expectEqualStrings("html", j.text(message, "bodySource"));
            try std.testing.expectEqualStrings(html, j.text(message, "bodyHtml"));
            try std.testing.expectEqualStrings(plain, j.text(message, "bodyText"));
            try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
        }
        try std.testing.expectEqual(baseline, cap.snapshot().allocatorUsedBytes);
    }
    try std.testing.expect(cap.snapshot().allocatorPeakBytes <= t.Limits.runtime_bytes);
}

test "post-dispatch allocation failure preserves live mutation ambiguity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inspecting = try j.value(arena.allocator(), .{ .cmd = "invitation.inspect" });
    const reconciling = try j.value(arena.allocator(), .{ .cmd = "invitation.inspect", .reconcile = true });
    for ([_]anyerror{ error.Canceled, error.Timeout, error.OutOfMemory }) |err| {
        try std.testing.expectEqual(err, Session.reconciliationFailure(inspecting, err));
        try std.testing.expectEqual(error.UnknownOutcome, Session.reconciliationFailure(reconciling, err));
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    const receipt: Value = .{ .string = "applied-provider-receipt" };
    for ([_][]const u8{ "contacts.upsert", "mail.mark", "mail.archive", "mail.trash", "mail.restore", "mail.send", "draft.send", "queue.process", "queue.send-now", "invitation.reply" }) |cmd| {
        try std.testing.expectError(error.UnknownOutcome, Session.successResponse(a, .null, "self@example.test", cmd, true, false, receipt));
    }
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "mail.read", false, false, receipt));
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "invitation.inspect", false, false, receipt));
    try std.testing.expectError(error.UnknownOutcome, Session.successResponse(a, .null, "self@example.test", "invitation.inspect", true, false, receipt));
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "contacts.upsert", true, true, receipt));
    try std.testing.expectError(error.UnknownOutcome, Session.failureForError(a, .null, "self@example.test", error.UnknownOutcome));
    try std.testing.expect(failing.has_induced_failure);
}

fn testMutationReceipt(kind: enum { send, label, queue_applied, queue_unknown }) !void {
    const label = kind == .label;
    const queued = kind == .queue_applied or kind == .queue_unknown;
    const ReceiptFailure = struct {
        backing: std.mem.Allocator,
        store: *storage.Store,
        wait_for_queue: bool,
        failed: bool = false,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn afterDispatch(self: *@This()) bool {
            return self.store.state.operations.len != 0 and self.store.state.fixtureCalls != 0 and
                (!self.wait_for_queue or self.store.state.sendQueue[0].state == .applied);
        }
        fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.afterDispatch()) {
                self.failed = true;
                return null;
            }
            return self.backing.rawAlloc(length, alignment, address);
        }
        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (length > memory.len and self.afterDispatch()) return false;
            return self.backing.rawResize(memory, alignment, length, address);
        }
        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (length > memory.len and self.afterDispatch()) return null;
            return self.backing.rawRemap(memory, alignment, length, address);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.backing.rawFree(memory, alignment, address);
        }
    };
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mutation-receipt", .{tmp.sub_path});
        const account = "personal@example.com";
        const options: t.Options = .{ .fixtures = true, .cache_dir = root, .fixture_scenario = if (label) "unknown-send" else "normal" };
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", root);
        const session = try std.testing.allocator.create(Session);
        defer std.testing.allocator.destroy(session);
        session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
        defer session.deinit();
        var store = try storage.Store.open(std.testing.io, a, root, account, options);
        defer store.close();
        var draft: t.Draft = .{ .to = &.{.{ .address = "recipient@example.test" }}, .bodyText = "Small normal mail" };
        const queue_id = if (queued) staged: {
            draft = try store.putDraft(draft, null);
            const digest = storage.Store.hash(try operationPayload(a, draft, account, null));
            break :staged (try send_queue.stage(&store, draft.id, "stable-operation", &digest, 0, 0)).queueId;
        } else "";
        const request = try j.value(a, .{ .cmd = if (queued) @as([]const u8, "queue.send-now") else if (label) "labels.create" else "mail.send", .account = account, .operationId = "stable-operation", .name = "New fixture label", .queueId = queue_id });
        var failing: ReceiptFailure = .{ .backing = a, .store = &store, .wait_for_queue = kind == .queue_applied };
        const call = if (queued) session.queuedSend(failing.allocator(), &store, request) else if (label) session.manageLabels(failing.allocator(), &store, request) else session.send(failing.allocator(), &store, request, draft, null, false);
        try std.testing.expectError(error.UnknownOutcome, call);
        try std.testing.expect(failing.failed);
        store.close();
        store = try storage.Store.open(std.testing.io, a, root, account, options);
        try std.testing.expectEqual(@as(usize, 1), store.state.operations.len);
        const operation = store.state.operations[0];
        try std.testing.expectEqualStrings("stable-operation", operation.id);
        try std.testing.expectEqualStrings(if (label) "unknown" else "applied", operation.outcome);
        const writes = store.state.fixtureCalls;
        const recovered = if (queued) try session.queuedSend(a, &store, request) else if (label) try session.manageLabels(a, &store, request) else try session.send(a, &store, request, draft, null, false);
        const receipt = if (queued) j.get(recovered, "operation").? else recovered;
        try std.testing.expectEqualStrings(if (label) "unknown" else "applied", j.text(receipt, "outcome"));
        try std.testing.expectEqualStrings(operation.id, j.text(receipt, if (label) "operationId" else "id"));
        try std.testing.expectEqual(writes, store.state.fixtureCalls);
        if (queued) {
            const entry = try send_queue.find(&store, queue_id);
            try std.testing.expectEqualStrings(operation.id, entry.operationId);
            try std.testing.expectEqual(if (kind == .queue_applied) storage.SendState.applied else .unknown, entry.state);
            try std.testing.expectEqualStrings(@tagName(entry.state), j.text(recovered, "state"));
            var replay_failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            try std.testing.expectError(error.UnknownOutcome, session.queuedSend(replay_failure.allocator(), &store, request));
            var read_failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, session.queuedSend(read_failure.allocator(), &store, try j.value(a, .{ .cmd = "queue.read", .queueId = queue_id })));
            // A different queued intent that cannot even hash its draft has
            // not reached dispatch and must still report ordinary OOM.
            draft = try store.putDraft(.{ .to = draft.to, .bodyText = "Not dispatched" }, null);
            const digest = storage.Store.hash(try operationPayload(a, draft, account, null));
            const fresh = try send_queue.stage(&store, draft.id, "preflight-operation", &digest, 0, 0);
            var preflight_failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, session.queuedSend(preflight_failure.allocator(), &store, try j.value(a, .{ .cmd = "queue.send-now", .queueId = fresh.queueId })));
            try std.testing.expectEqual(storage.SendState.queued, fresh.state);
            try std.testing.expectEqual(writes, store.state.fixtureCalls);
            return;
        }
        var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        const preflight = if (label) session.manageLabels(unavailable.allocator(), &store, request) else session.send(unavailable.allocator(), &store, request, draft, null, false);
        try std.testing.expectError(error.OutOfMemory, preflight);
        try std.testing.expectEqual(writes, store.state.fixtureCalls);
    }
}
test "native mutation receipt: sent DTO failure preserves durable identity without replay" {
    try testMutationReceipt(.send);
}
test "native mutation receipt: uncertain label DTO failure preserves durable identity without replay" {
    try testMutationReceipt(.label);
}
test "native mutation receipt: queued send applied DTO failure keeps its durable identity" {
    try testMutationReceipt(.queue_applied);
}
test "native mutation receipt: queued send error DTO failure keeps its durable identity" {
    try testMutationReceipt(.queue_unknown);
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
    for ([_]anyerror{ error.BodySizeMismatch, error.TooManyHeaders, error.InvalidEncodedWord, error.MalformedMessage, error.BodyTooLarge, error.CalendarTooLarge, error.JsonTooManyTokens, error.JsonTooDeep }) |err| try std.testing.expect(Session.messageRefusal(err));
    for ([_]anyerror{ error.OutOfMemory, error.Canceled, error.Timeout, error.InvalidGrant, error.PermissionDenied, error.TokenRefreshFailed, error.RateLimited, error.CacheBusy, error.CacheIdentityMismatch }) |err| try std.testing.expect(!Session.messageRefusal(err));
}

test "reply boundaries: fresh native compose reads retry only cached reader size refusals" {
    const native = @import("send_memory.zig").native;
    for ([_][]const u8{ "mail.reply", "mail.forward" }) |command| {
        for ([_][]const u8{ "BodyTooLarge", "DecodedMessageTooLarge", "MessageTooLarge", "ResponseTooLarge", "MessageBudgetExceeded", "ThreadBodyBudgetExceeded", "JsonTooManyTokens", "ComposeSourceRequired" }) |code| {
            try std.testing.expectEqual(native, Session.retryComposeSizeRefusal(command, code));
        }
        for ([_][]const u8{ "", "UnsupportedCharset", "InvalidRecipients", "BodySizeMismatch", "InvalidBase64", "CacheIdentityMismatch", "TooManyReferences" }) |code| {
            try std.testing.expect(!Session.retryComposeSizeRefusal(command, code));
        }
    }
    for ([_][]const u8{ "mail.read", "mail.thread", "mail.list", "mail.sync", "draft.read", "draft.preview", "unknown" }) |command| {
        try std.testing.expect(!Session.retryComposeSizeRefusal(command, "BodyTooLarge"));
    }
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

test "contact isolation: native fixture and cached search retain omissions without permitting subset writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cache_root = try std.fmt.allocPrint(a, "{s}/cache", .{fixture_root});
    try tmp.dir.createDir(std.testing.io, "contacts", .fromMode(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "contacts/optional.json", .data =
        \\{"connections":[{"resourceName":"people/complete","names":[{"displayName":"Alex Fixture"}],"emailAddresses":[{"value":"alex@example.test"}]},{"resourceName":"people/partial","names":[{"displayName":"Partial Peer"}],"emailAddresses":[{"value":"not an address"},{"value":"peer@example.test"}]},{"emailAddresses":[{"value":"missing-identity@example.test"}]}]}
    });
    var session: Session = .{ .io = std.testing.io, .allocator = std.testing.allocator, .options = .{ .fixtures = true, .fixture_root = fixture_root }, .config = undefined, .cache_root = cache_root, .env = undefined };
    const req = try j.value(a, .{ .cmd = "contacts.list" });
    {
        var store = try storage.Store.open(std.testing.io, a, cache_root, "fictional@example.test", session.options);
        defer store.close();
        const live = try session.contacts(a, &store, req, "contacts.list");
        try std.testing.expectEqual(@as(usize, 2), (try array(live, "contacts")).len);
        try std.testing.expect(try j.boolean(live, "partial", false));
        try std.testing.expectEqual(@as(i64, 1), try j.integer(j.get(live, "contactWarnings").?, "omittedContacts", 0));
        try std.testing.expectEqual(@as(u32, 1), store.state.contacts[1].readWarnings.omittedEmails);
        const edit = try j.value(a, .{ .cmd = "contacts.upsert", .contact = .{ .resourceName = "people/partial", .name = "Changed" } });
        try std.testing.expectError(error.IncompleteContact, session.contacts(a, &store, edit, "contacts.upsert"));
        try std.testing.expectEqualStrings("Partial Peer", store.state.contacts[1].name);
        try std.testing.expectEqual(@as(u64, 1), store.state.fixtureCalls);
    }
    const cached = try session.cachedDispatch(a, "fictional@example.test", req);
    try std.testing.expect(try j.boolean(cached, "partial", false));
    try std.testing.expect(try j.boolean(cached, "cacheReady", false));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(j.get(cached, "contactWarnings").?, "omittedContacts", 0));
    const search = try session.cachedDispatch(a, "fictional@example.test", try j.value(a, .{ .cmd = "contacts.search", .query = "no-match" }));
    try std.testing.expectEqual(@as(usize, 0), (try array(search, "contacts")).len);
    try std.testing.expect(try j.boolean(search, "partial", false));
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
    draft.omittedAttachments = 2;
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
    try std.testing.expectError(error.ArchivedDraftReadOnly, session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = draft_id, .operationId = "grace-new-sent-source", .delaySeconds = 0 })));
    const unknown_copy = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = draft_id }));
    const unknown_draft_id = j.text(unknown_copy, "id");
    session.options.fixture_scenario = "unknown-send";
    const next = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = unknown_draft_id, .operationId = "grace-unknown", .delaySeconds = 0 }));
    const unknown_process = try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = j.text(next, "queueId") });
    try std.testing.expectEqualStrings("unknown", j.text(try session.dispatch(a, unknown_process), "state"));
    try std.testing.expectEqualStrings("unknown", j.text(try session.dispatch(a, unknown_process), "state"));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "draft.discard", .account = account, .draftId = unknown_draft_id })));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = unknown_draft_id, .queueId = j.text(next, "queueId"), .operationId = "grace-unknown" })));
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

test "send grace: send now preserves the reviewed intent and fences repeats cancellation and uncertainty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/send-now", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer session.deinit();
    const account = "personal@example.com";
    var draft = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Reviewed note" } }));
    const queued = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "send-now-reviewed", .delaySeconds = 30 }));
    const queue_id = j.text(queued, "queueId");
    const request = try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = queue_id });
    const due_request = try j.value(a, .{ .cmd = "queue.process", .account = account, .queueId = queue_id });
    try std.testing.expectError(error.QueueNotDue, session.dispatch(a, due_request));
    try std.testing.expectError(error.QueueNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = "work@example.com", .queueId = queue_id })));
    try std.testing.expectError(error.WaitRequiresQueueProcess, session.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = queue_id, .wait = true })));
    const sent = try session.dispatch(a, request);
    try std.testing.expectEqualStrings("applied", j.text(sent, "state"));
    try std.testing.expectEqualStrings(queue_id, j.text(sent, "queueId"));
    try std.testing.expectEqualStrings("send-now-reviewed", j.text(sent, "operationId"));
    try std.testing.expectEqual(try j.integer(queued, "dueAtMs", 0), try j.integer(sent, "dueAtMs", 0));
    for ([_]Value{ request, due_request, request }) |replay| try std.testing.expectEqualStrings("applied", j.text(try session.dispatch(a, replay), "state"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));

    try std.testing.expectError(error.ArchivedDraftReadOnly, session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "fresh-operation-sent-source" })));
    draft = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = j.text(draft, "id") }));
    const canceled = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "send-now-canceled", .delaySeconds = 30 }));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "queue.cancel", .account = account, .queueId = j.text(canceled, "queueId") }));
    try std.testing.expectEqualStrings("canceled", j.text(try session.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(canceled, "queueId") })), "state"));

    session.options.fixture_scenario = "unknown-send";
    const uncertain = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "send-now-unknown", .delaySeconds = 30 }));
    const unknown_request = try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(uncertain, "queueId") });
    try std.testing.expectEqualStrings("unknown", j.text(try session.dispatch(a, unknown_request), "state"));
    session.deinit();
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    try std.testing.expectEqualStrings("unknown", j.text(try session.dispatch(a, unknown_request), "state"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
    try std.testing.expectError(error.UnknownOutcome, session.dispatch(a, try j.value(a, .{ .cmd = "draft.discard", .account = account, .draftId = j.text(draft, "id") })));
}

test "send grace: send now checks content hash and a submitting claim before sending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/send-now-claim", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer session.deinit();
    const account = "personal@example.com";
    const draft = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Reviewed content" } }));
    const queued = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "send-now-hash", .delaySeconds = 30 }));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, options);
        defer store.close();
        // Simulate a stale persisted review without going through the editor,
        // which normally cancels its queue. Immutable source hashes remain
        // intact; this reaches the independent queue-to-content digest guard.
        const entry = try send_queue.find(&store, j.text(queued, "queueId"));
        entry.hash = try a.dupe(u8, &storage.Store.hash("stale reviewed content"));
        try store.save();
    }
    const rejected = try session.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(queued, "queueId") }));
    try std.testing.expectEqualStrings("canceled", j.text(rejected, "state"));
    try std.testing.expectEqualStrings("DraftChanged", j.text(rejected, "errorCode"));
    const claimed = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "send-now-claimed", .delaySeconds = 30 }));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, options);
        defer store.close();
        (try send_queue.find(&store, j.text(claimed, "queueId"))).state = .submitting;
        try store.save();
    }
    session.deinit();
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    try std.testing.expectEqualStrings("submitting", j.text(try session.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(claimed, "queueId") })), "state"));
    try std.testing.expectEqual(@as(i64, 0), try j.integer(try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
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
    const ordinary: [t.Limits.attachments + 1]t.Attachment = @splat(draft.attachments[0]);
    too_many.attachments = &ordinary;
    try std.testing.expectError(error.TooManyAttachments, validateDraft(too_many, false));
    too_many = draft;
    const related: [t.Limits.related_resources + 1]t.Attachment = @splat(draft.original.?.resources[0]);
    too_many.original.?.resources = &related;
    try std.testing.expectError(error.TooManyAttachments, validateDraft(too_many, false));
}

test "legacy bodies: plain forward refreshes an old empty-file omission once and retains it after restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = try std.fmt.allocPrint(a, "{s}/cache", .{fixture_root});
    try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
    const account = "personal@example.com";
    const raw =
        \\{"account":"personal@example.com","messages":[{"id":"legacy-source","threadId":"thread","internalDate":"9000000","labelIds":["SENT"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"personal@example.com"},{"name":"To","value":"peer@example.test"},{"name":"Subject","value":"Original empty file"}],"parts":[{"partId":"0","mimeType":"text/plain","body":{"size":2,"data":"SGk"}},{"partId":"1","mimeType":"application/octet-stream","filename":"empty.bin","body":{"size":0,"data":""}}]}}]}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = raw });
    const options: t.Options = .{ .fixtures = true, .fixture_root = fixture_root, .cache_dir = root };
    {
        var old = try storage.Store.open(std.testing.io, a, root, account, options);
        defer old.close();
        try old.put(.{ .id = "legacy-source", .threadId = "thread", .from = .{ .address = account }, .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Hi", .labels = &.{"SENT"} }, true);
        old.find("legacy-source").?.bodyDecoderRevision = 0;
        try old.save();
    }
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer session.deinit();
    const request = try j.value(a, .{ .cmd = "mail.forward", .account = account, .messageId = "legacy-source" });
    const first = try decodeDraft(a, try session.dispatch(a, request));
    try std.testing.expectEqual(@as(usize, 1), first.attachments.len);
    try std.testing.expectEqualStrings("empty.bin", first.attachments[0].filename);
    try std.testing.expectEqual(@as(usize, 0), first.attachments[0].size);
    session.deinit();
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    // A fresh provider read would now fail. The migrated immutable body is
    // sufficient, and another forward must neither refetch nor lose the file.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = "{\"account\":\"personal@example.com\",\"messages\":[]}" });
    const second = try decodeDraft(a, try session.dispatch(a, request));
    try std.testing.expectEqual(@as(usize, 1), second.attachments.len);
    try std.testing.expectEqualStrings("empty.bin", second.attachments[0].filename);
    var stored = try storage.Store.open(std.testing.io, a, root, account, options);
    defer stored.close();
    try std.testing.expect(!stored.bodyNeedsUpgrade("legacy-source"));
    try std.testing.expectEqual(@as(u64, 1), stored.state.fixtureCalls);
}

test "related originals: Gmail resource downloads spill aggregate and individual large images through cold drafts preview and MIME" {
    const Oracle = struct {
        const html = "<p>Unchanged source fragment.</p><img src=\"cid:photo-0\"><img src=\"https://example.test/photo-1.png\"><img src=\"cid:photo-2\">";
        fn write(a: std.mem.Allocator, dir: std.Io.Dir, sent: bool, files: []const t.Attachment, downloads: bool) !void {
            var parts: Value = .{ .array = .init(a) };
            const encoded_html = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(html.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(encoded_html, html);
            try parts.array.append(try j.value(a, .{ .partId = "plain", .mimeType = "text/plain", .body = .{ .size = 2, .data = "SGk" } }));
            try parts.array.append(try j.value(a, .{ .partId = "html", .mimeType = "text/html", .body = .{ .size = html.len, .data = encoded_html } }));
            var external = j.object(a);
            for (files) |attachment| {
                var headers: Value = .{ .array = .init(a) };
                if (attachment.contentId) |cid| try headers.array.append(try j.value(a, .{ .name = "Content-ID", .value = try std.fmt.allocPrint(a, "<{s}>", .{cid}) }));
                if (attachment.contentLocation) |location| try headers.array.append(try j.value(a, .{ .name = "Content-Location", .value = location }));
                try headers.array.append(try j.value(a, .{ .name = "Content-Disposition", .value = attachment.disposition orelse "attachment" }));
                try parts.array.append(try j.value(a, .{ .partId = attachment.id, .filename = attachment.filename, .mimeType = attachment.mimeType, .headers = headers, .body = .{ .size = attachment.size, .attachmentId = attachment.id } }));
                if (downloads) try external.object.put(a, attachment.id, try j.value(a, .{ .size = attachment.size, .data = attachment.data }));
            }
            const message = try j.value(a, .{ .id = "source", .threadId = "source-thread", .internalDate = "9000000", .labelIds = [_][]const u8{if (sent) "SENT" else "INBOX"}, .payload = .{ .mimeType = "multipart/mixed", .headers = .{ .{ .name = "From", .value = if (sent) "personal@example.com" else "peer@example.test" }, .{ .name = "To", .value = if (sent) "peer@example.test" else "personal@example.com" }, .{ .name = "Message-ID", .value = "<source@example.test>" }, .{ .name = "Subject", .value = "Large inline source" } }, .parts = parts } });
            var source = try j.value(a, .{ .account = "personal@example.com", .messages = [_]Value{message} });
            if (downloads) try source.object.put(a, "externalBodies", external);
            try dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = try std.json.Stringify.valueAlloc(a, source, .{}) });
        }
        fn mimePart(a: std.mem.Allocator, raw: []const u8, marker: []const u8) ![]const u8 {
            const at = std.mem.indexOf(u8, raw, marker) orelse return error.MissingExpectedPart;
            const start = at + (std.mem.indexOf(u8, raw[at..], "\r\n\r\n") orelse return error.MissingExpectedPart) + 4;
            const end = start + (std.mem.indexOf(u8, raw[start..], "\r\n--") orelse return error.MissingExpectedPart);
            var compact: std.ArrayList(u8) = .empty;
            for (raw[start..end]) |byte| if (byte != '\r' and byte != '\n') try compact.append(a, byte);
            const decoded = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(compact.items));
            try std.base64.standard.Decoder.decode(decoded, compact.items);
            return decoded;
        }
    };
    for ([_]bool{ false, true }) |sent| for ([_]usize{ 900_000, 2_200_000 }) |first_size| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer setup.deinit();
        const setup_a = setup.allocator();
        const fixture_root = try std.fmt.allocPrint(setup_a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const root = try std.fmt.allocPrint(setup_a, "{s}/cache", .{fixture_root});
        try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
        var files: [4]t.Attachment = undefined;
        var bytes: [4][]u8 = undefined;
        for (&files, &bytes, 0..) |*attachment, *content, index| {
            const size: usize = if (index == 0) first_size else if (index == 3) 128 else 900_000;
            content.* = try setup_a.alloc(u8, size);
            @memset(content.*, @as(u8, @intCast(index)) + 'A');
            if (index < 3) @memcpy(content.*[0..8], "\x89PNG\r\n\x1a\n") else @memcpy(content.*[0..9], "%PDF-1.7\n");
            const encoded = try setup_a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(size));
            _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, content.*);
            attachment.* = .{ .id = try std.fmt.allocPrint(setup_a, "part-{d}", .{index}), .filename = try std.fmt.allocPrint(setup_a, "source-{d}.{s}", .{ index, if (index < 3) @as([]const u8, "png") else "pdf" }), .mimeType = if (index < 3) "image/png" else "application/pdf", .size = size, .data = encoded, .contentId = if (index == 0 or index == 2) try std.fmt.allocPrint(setup_a, "photo-{d}", .{index}) else null, .contentLocation = if (index == 1) "https://example.test/photo-1.png" else null, .disposition = if (index == 2 or index == 3) "attachment" else "inline" };
        }
        const account = "personal@example.com";
        const options: t.Options = .{ .fixtures = true, .fixture_root = fixture_root, .cache_dir = root };
        {
            var seed = try storage.Store.open(std.testing.io, setup_a, root, account, options);
            defer seed.close();
            for (0..2000) |index| try seed.put(.{ .id = try std.fmt.allocPrint(setup_a, "retained-{d}", .{index}), .threadId = "retained-thread", .receivedAt = @intCast(index), .subject = "Ordinary cache entry", .snippet = "A retained synthetic preview" }, false);
            try seed.save();
        }
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", "/tmp/synthetic-omagma-home");
        const session = try std.testing.allocator.create(Session);
        defer std.testing.allocator.destroy(session);
        session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
        defer session.deinit();
        const reservation = try std.testing.allocator.alloc(u8, 72 * 1024 * 1024);
        defer std.testing.allocator.free(reservation);
        var heap = @import("../fixed_heap.zig").Heap.init(reservation);
        var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = heap.allocator(), .limit = 64 * 1024 * 1024, .reservation_bytes = reservation.len };
        session.allocator = cap.allocator();
        defer session.allocator = std.testing.allocator;
        var draft_id: []const u8 = undefined;
        {
            var command = std.heap.ArenaAllocator.init(cap.allocator());
            defer command.deinit();
            const a = command.allocator();
            try Oracle.write(setup_a, tmp.dir, sent, &files, false);
            const req = try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "source" });
            const message = try j.decode(t.Message, a, try session.dispatch(a, req));
            for (message.attachments) |attachment| try std.testing.expect(attachment.data.len == 0 and attachment.blobId == null);
            // FULL capture precedes the external download map, as it does on
            // Gmail; no eager fixture decoding can bypass the native fetch.
            try Oracle.write(setup_a, tmp.dir, sent, &files, true);
            var store = try storage.Store.open(std.testing.io, a, root, account, options);
            defer store.close();
            const prepared = try session.prepareForwardAttachments(a, &store, req, message, true);
            var adapter: Session.ConversationAttachments = .{ .session = session, .store = &store, .request = req };
            var draft = try conversation_source.forward(a, prepared, .{ .preserve_formatting = true, .temporary_allocator = cap.allocator() }, adapter.adapter());
            draft.to = &.{.{ .address = "recipient@example.test" }};
            if (!store.lockHeld) try session.reopenBody(a, &store);
            const saved = try store.putDraft(draft, null);
            draft_id = try setup_a.dupe(u8, saved.id);
            try std.testing.expectEqual(@as(usize, 2000), store.state.entries.len);
        }
        {
            var command = std.heap.ArenaAllocator.init(cap.allocator());
            defer command.deinit();
            const a = command.allocator();
            var store = try storage.Store.open(std.testing.io, a, root, account, options);
            defer store.close();
            const draft = try store.draft(draft_id);
            try std.testing.expectEqualStrings(Oracle.html, draft.original.?.bodyHtml);
            try std.testing.expectEqual(@as(usize, 3), draft.original.?.resources.len);
            try std.testing.expectEqual(@as(usize, 1), draft.attachments.len);
            for (draft.original.?.resources, 0..) |resource, index| {
                try std.testing.expect(resource.blobId != null and resource.data.len == 0);
                try std.testing.expectEqualStrings(&storage.Store.hash(bytes[index]), resource.blobId.?);
                try std.testing.expectEqualDeep(files[index].contentId, resource.contentId);
                try std.testing.expectEqualDeep(files[index].contentLocation, resource.contentLocation);
                try std.testing.expectError(error.AttachmentInUse, @import("attachment_blob.zig").discard(&store, resource.blobId.?));
            }
            const prepared = try markdown_mail.prepare(a, draft);
            const preview = @import("preview_file.zig");
            const preview_size = try preview.byteSizeWithStore(&store, prepared, draft);
            try store.reserveBytes(preview_size);
            const written = try preview.writePreviewWithStore(&store, a, prepared, draft);
            _ = written;
            const rendered = try store.dir.readFileAlloc(std.testing.io, preview.filename, setup_a, .limited(preview.max_file_bytes));
            try std.testing.expectEqual(preview_size, rendered.len);
            for (bytes[0..3]) |expected| {
                const encoded = try setup_a.alloc(u8, std.base64.standard.Encoder.calcSize(expected.len));
                _ = std.base64.standard.Encoder.encode(encoded, expected);
                try std.testing.expect(std.mem.indexOf(u8, rendered, encoded) != null);
            }
            try std.testing.expect(std.mem.indexOf(u8, rendered, "https://example.test/photo-1.png") == null);
            var sender: recipients.Mailbox = .{};
            try sender.address.set(account);
            var envelope: recipients.Envelope = .{};
            try recipients.parse("recipient@example.test", &envelope.to);
            const mime = @import("mime.zig");
            var spool = try @import("send_spool.zig").create(&store, mime.Compose{ .from = sender, .envelope = &envelope, .subject = draft.subject, .body = prepared.plain, .html = prepared.html, .inline_logo = true, .logo_offset = prepared.logoOffset, .message_id = "<large-related@example.test>", .date = "Tue, 13 Oct 2026 12:00:00 +0000" }, draft.attachments, prepared.resources);
            defer spool.close();
            const wire = try setup_a.alloc(u8, spool.size);
            var offset: usize = 0;
            while (offset < wire.len) {
                const count = try spool.file.?.readPositional(std.testing.io, &.{wire[offset..]}, offset);
                if (count == 0) return error.UnexpectedEndOfInput;
                offset += count;
            }
            for (bytes[0..3], 0..) |expected, index| {
                const marker = if (index == 1) "Content-Location: https://example.test/photo-1.png\r\n" else try std.fmt.allocPrint(setup_a, "Content-ID: <photo-{d}>\r\n", .{index});
                try std.testing.expectEqualSlices(u8, expected, try Oracle.mimePart(setup_a, wire, marker));
            }
            try std.testing.expectEqualSlices(u8, bytes[3], try Oracle.mimePart(setup_a, wire, "filename*0*=UTF-8''source-3.pdf\r\n"));
            try std.testing.expect(std.mem.indexOf(u8, try Oracle.mimePart(setup_a, wire, "Content-Type: text/html; charset=UTF-8\r\n"), Oracle.html) != null);
            if (sent and first_size == 2_200_000) {
                // Exercise the backend's spool decision with related blobs
                // alone; an ordinary file must not be needed to select it.
                var images_only = draft;
                images_only.attachments = &.{};
                images_only = try store.putDraft(images_only, null);
                const send_request = try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = images_only.id, .operationId = "synthetic-related-only-send" });
                const receipt = try session.send(a, &store, send_request, images_only, null, false);
                try std.testing.expectEqualStrings("applied", j.text(receipt, "outcome"));
                try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
                try std.testing.expectEqual(@as(usize, 3), (try store.readOutbox(j.text(receipt, "messageId"))).?.attachments.len);
            }
            // A foreign account cannot resolve this draft's local images.
            var foreign = try storage.Store.open(std.testing.io, a, root, "neighbor@example.test", options);
            defer foreign.close();
            try std.testing.expectError(error.AttachmentHandleNotFound, preview.writePreviewWithStore(&foreign, a, prepared, draft));
            try std.testing.expectError(error.FileNotFound, foreign.dir.access(std.testing.io, preview.filename, .{}));
            // Hash mismatch refuses both saving and preview publication, even
            // when size, MIME identity and private filesystem mode still match.
            const changed = try store.dir.createFile(std.testing.io, try @import("attachment_blob.zig").filename(a, draft.original.?.resources[0].blobId.?), .{ .read = true, .truncate = false });
            try changed.writeStreamingAll(std.testing.io, "X");
            changed.close(std.testing.io);
            try std.testing.expectError(error.AttachmentChanged, store.putDraft(draft, draft.id));
            try std.testing.expectError(error.AttachmentChanged, preview.writePreviewWithStore(&store, a, prepared, draft));
            try std.testing.expectEqualStrings(&storage.Store.hash(rendered), &storage.Store.hash(try store.dir.readFileAlloc(std.testing.io, preview.filename, setup_a, .limited(preview.max_file_bytes))));
        }
        try std.testing.expectEqual(@as(usize, 0), cap.snapshot().allocatorUsedBytes);
        try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
    };
}

test "forward memory: a large fixture RAW envelope uses one bounded file allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const root = try std.fmt.allocPrint(setup.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
    {
        const file = try tmp.dir.createFile(std.testing.io, "accounts/personal.json", .{ .permissions = .fromMode(0o600) });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"account\":\"personal@example.com\",\"messages\":[{\"id\":\"source\",\"raw\":\"");
        var block: [4096]u8 = undefined;
        @memset(&block, 'A');
        for (0..3072) |_| try file.writeStreamingAll(std.testing.io, &block);
        try file.writeStreamingAll(std.testing.io, "\"}]}");
    }
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .fixture_root = root, .cache_dir = root });
    defer session.deinit();
    const reservation = try std.testing.allocator.alloc(u8, 40 * 1024 * 1024);
    defer std.testing.allocator.free(reservation);
    var heap = @import("../fixed_heap.zig").Heap.init(reservation);
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = heap.allocator(), .limit = 32 * 1024 * 1024, .reservation_bytes = reservation.len };
    {
        var phase = std.heap.ArenaAllocator.init(cap.allocator());
        defer phase.deinit();
        const value = try session.fixture(phase.allocator(), "personal@example.com");
        const messages = try array(value, "messages");
        try std.testing.expectEqual(@as(usize, 12 * 1024 * 1024), j.text(messages[0], "raw").len);
    }
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().allocatorUsedBytes);
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
    try std.testing.expect(cap.snapshot().allocatorPeakBytes < 24 * 1024 * 1024);
}

test "forward memory: large blob reservations release each 2000-entry cache snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const root = try std.fmt.allocPrint(setup.allocator(), ".zig-cache/tmp/{s}/large-forward", .{tmp.sub_path});
    const account = "personal@example.com";
    {
        var seed = try storage.Store.open(std.testing.io, setup.allocator(), root, account, .{ .fixtures = true });
        defer seed.close();
        for (0..2000) |index| try seed.put(.{
            .id = try std.fmt.allocPrint(setup.allocator(), "cached-{d}", .{index}),
            .threadId = "ordinary-thread",
            .receivedAt = @intCast(index),
            .subject = "An ordinary cached conversation with enough metadata to represent a populated account",
            .snippet = "A retained message preview with synthetic participants and ordinary folder metadata.",
            .to = &.{.{ .address = "peer@example.test", .name = "Fictional Correspondent" }},
            .labels = &.{"INBOX"},
        }, false);
        try seed.save();
    }
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const reservation = try std.testing.allocator.alloc(u8, 72 * 1024 * 1024);
    defer std.testing.allocator.free(reservation);
    var heap = @import("../fixed_heap.zig").Heap.init(reservation);
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = heap.allocator(), .limit = 64 * 1024 * 1024, .reservation_bytes = reservation.len };
    session.allocator = cap.allocator();

    defer session.allocator = std.testing.allocator;
    {
        var command = std.heap.ArenaAllocator.init(cap.allocator());
        defer command.deinit();
        const a = command.allocator();
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        var attachments: [8]t.Attachment = undefined;
        var block: [64 * 1024]u8 = undefined;
        for (&attachments, 0..) |*attachment, index| {
            const size = 2_200_000;
            var incoming = try session.reserveIncoming(a, &store, size);
            defer incoming.close();
            @memset(&block, @intCast(index + 1));
            var written: usize = 0;
            while (written < size) {
                const count = @min(block.len, size - written);
                try incoming.file.?.writeStreamingAll(std.testing.io, block[0..count]);
                written += count;
            }
            attachment.* = try session.commitIncoming(a, &store, &incoming, .{ .id = try std.fmt.allocPrint(a, "large-{d}", .{index}), .filename = "large.pdf", .mimeType = "application/pdf", .size = size }, false);
            try std.testing.expect(attachment.blobId != null and attachment.data.len == 0);
            try std.testing.expect(!store.lockHeld);
        }
        try session.reopenBody(a, &store);
        const draft = try store.putDraft(.{ .subject = "Eight ordinary large files", .attachments = &attachments }, null);
        try validateDraft(draft, false);
        try std.testing.expectEqual(@as(usize, 2000), store.state.entries.len);
        store.close();
        var check = std.heap.ArenaAllocator.init(cap.allocator());
        defer check.deinit();
        var reopened = try storage.Store.open(std.testing.io, check.allocator(), root, account, session.options);
        defer reopened.close();
        const retained = try reopened.draft(draft.id);
        try std.testing.expectEqual(@as(usize, 8), retained.attachments.len);
        for (retained.attachments, attachments, 0..) |attachment, original, index| {
            try std.testing.expectEqualDeep(original, attachment);
            var stream = try @import("attachment_blob.zig").Stream.init(&reopened, attachment);
            defer stream.close();
            var size: usize = 0;
            while (true) {
                const count = try @import("attachment_blob.zig").Stream.read(&stream, &block);
                if (count == 0) break;
                for (block[0..count]) |byte| try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte);
                size += count;
            }
            try std.testing.expectEqual(@as(usize, 2_200_000), size);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().allocatorUsedBytes);
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
    try std.testing.expect(cap.snapshot().allocatorPeakBytes < 32 * 1024 * 1024);
}

test "attachment identity: fresh thread tokens resolve against the same message despite an older cached body" {
    const Oracle = struct {
        const pdf = "%PDF-1.7\nFinal report.\n%%EOF\n";
        fn write(a: std.mem.Allocator, dir: std.Io.Dir, token: []const u8, bodies: bool) !void {
            var messages: Value = .{ .array = .init(a) };
            var external = j.object(a);
            for (0..4) |i| {
                const attachment_id = if (i == 3) token else try std.fmt.allocPrint(a, "neighbor-token-{d}", .{i});
                const bytes = if (i == 3) pdf else "%PDF-1.7\nOther report.\n%%EOF\n";
                const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
                _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
                if (bodies) try external.object.put(a, attachment_id, try j.value(a, .{ .size = bytes.len, .data = encoded }));
                try messages.array.append(try j.value(a, .{
                    .id = try std.fmt.allocPrint(a, "thread-message-{d}", .{i + 1}),
                    .threadId = "attachment-thread",
                    .internalDate = try std.fmt.allocPrint(a, "{d}", .{(i + 1) * 1000}),
                    .labelIds = [_][]const u8{if (i == 3) "SENT" else "INBOX"},
                    .payload = .{
                        .mimeType = "multipart/mixed",
                        .headers = .{
                            .{ .name = "From", .value = if (i == 3) "personal@example.com" else "peer@example.test" },
                            .{ .name = "To", .value = if (i == 3) "peer@example.test" else "personal@example.com" },
                            .{ .name = "Subject", .value = "Fictional report" },
                        },
                        .parts = .{
                            .{ .partId = "0", .mimeType = "text/plain", .body = .{ .size = 2, .data = "SGk" } },
                            .{ .partId = "1", .mimeType = "application/pdf", .filename = "report.pdf", .body = .{ .size = bytes.len, .attachmentId = attachment_id } },
                        },
                    },
                }));
            }
            var source = try j.value(a, .{ .account = "personal@example.com" });
            try source.object.put(a, "messages", messages);
            if (bodies) try source.object.put(a, "externalBodies", external);
            try dir.writeFile(std.testing.io, .{ .sub_path = "accounts/personal.json", .data = try std.json.Stringify.valueAlloc(a, source, .{}) });
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = try std.fmt.allocPrint(a, "{s}/attachment-cache", .{fixture_root});
    try tmp.dir.createDir(std.testing.io, "accounts", .fromMode(0o700));
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .fixture_root = fixture_root, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const message_id = "thread-message-4";
    // No fixture bytes during reads: these are actual unloaded Gmail parts,
    // not eagerly decoded test data that bypasses the attachment provider.
    try Oracle.write(a, tmp.dir, "cached-token-A", false);
    const cached = try j.decode(t.Message, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = message_id })));
    try std.testing.expectEqualStrings("cached-token-A", cached.attachments[0].id);
    try std.testing.expectEqual(@as(usize, 0), cached.attachments[0].data.len);
    try Oracle.write(a, tmp.dir, "thread-token-B", false);
    const thread = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.thread", .account = account, .threadId = "attachment-thread" }));
    const messages = try array(thread, "messages");
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    const selected = try j.decode(t.Message, a, messages[3]);
    try std.testing.expectEqualStrings(message_id, selected.id);
    try std.testing.expectEqualStrings("SENT", selected.labels[0]);
    try std.testing.expectEqualStrings("thread-token-B", selected.attachments[0].id);
    try std.testing.expectEqual(@as(usize, 0), selected.attachments[0].data.len);
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        try std.testing.expectEqualStrings("cached-token-A", (try store.read(message_id)).?.attachments[0].id);
        try std.testing.expectEqualStrings("thread-token-B", store.find(message_id).?.message.attachments[0].id);
    }
    try Oracle.write(a, tmp.dir, "thread-token-B", true);
    const downloaded = try j.decode(t.Attachment, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment", .account = account, .messageId = selected.id, .attachmentId = selected.attachments[0].id })));
    try std.testing.expectEqualSlices(u8, Oracle.pdf, try @import("mime.zig").decodeBase64Url(downloaded.data, a));
    const output = try std.fmt.allocPrint(a, "{s}/saved.pdf", .{fixture_root});
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = selected.id, .attachmentId = selected.attachments[0].id, .path = output }));
    try std.testing.expectEqualSlices(u8, Oracle.pdf, try tmp.dir.readFileAlloc(std.testing.io, "saved.pdf", a, .limited(1024)));
    try std.testing.expectError(error.PathAlreadyExists, session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = selected.id, .attachmentId = selected.attachments[0].id, .path = output })));
    try std.testing.expectEqualSlices(u8, Oracle.pdf, try tmp.dir.readFileAlloc(std.testing.io, "saved.pdf", a, .limited(1024)));
    const refused = try std.fmt.allocPrint(a, "{s}/refused.pdf", .{fixture_root});
    // Same name, MIME type and size in a neighboring message do not authorize
    // its token for this message (or this message's token for that neighbor).
    for ([_][]const u8{ "neighbor-token-0", "unknown-token" }) |id| {
        try std.testing.expectError(error.AttachmentNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = message_id, .attachmentId = id, .path = refused })));
    }
    try std.testing.expectError(error.AttachmentNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment", .account = account, .messageId = "thread-message-1", .attachmentId = "thread-token-B" })));
    // Another reader publishes C while the picker still holds its verified B.
    // The bounded receipt retains that binding across operations/restarts.
    try Oracle.write(a, tmp.dir, "thread-token-C", false);
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.thread", .account = account, .threadId = "attachment-thread" }));
    try Oracle.write(a, tmp.dir, "thread-token-C", true);
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment-save", .account = account, .messageId = selected.id, .attachmentId = selected.attachments[0].id, .path = refused }));
    const recovered = try j.decode(t.Attachment, a, try session.dispatch(a, try j.value(a, .{ .cmd = "mail.attachment", .account = account, .messageId = selected.id, .attachmentId = selected.attachments[0].id })));
    try std.testing.expectEqualSlices(u8, Oracle.pdf, try @import("mime.zig").decodeBase64Url(recovered.data, a));
    try std.testing.expectEqualSlices(u8, Oracle.pdf, try tmp.dir.readFileAlloc(std.testing.io, "refused.pdf", a, .limited(1024)));
    // A quota-refused/evicted body forces save's own FULL read. Pin B before
    // that read replaces the index with C, then exercise Gmail's shared 404
    // retry from B to the unique verified C descriptor and exact PDF bytes.
    for ([_][]const u8{ "mail.attachment", "mail.attachment-save" }) |command| {
        try Oracle.write(a, tmp.dir, "thread-token-B", false);
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.thread", .account = account, .threadId = "attachment-thread" }));
        {
            var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
            defer store.close();
            const entry = store.find(message_id).?;
            entry.bytes = 0;
            entry.bodyHash = "";
            store.options.disk_limit = 1;
            try std.testing.expect(!try store.putBody(selected));
            try std.testing.expectEqualStrings("DiskQuotaExceeded", store.find(message_id).?.bodyError);
            try std.testing.expectEqualStrings("thread-token-B", store.find(message_id).?.message.attachments[0].id);
            // Restore room for the metadata transaction itself; the refused
            // body and its B descriptor remain the state the next read sees.
            store.options.disk_limit = session.options.disk_limit;
            store.state.quotaDiskLimit = session.options.disk_limit;
            try store.save();
        }
        try Oracle.write(a, tmp.dir, "thread-token-C", true);
        const quota_path = try std.fmt.allocPrint(a, "{s}/quota-saved.pdf", .{fixture_root});
        const result = try session.dispatch(a, try j.value(a, .{ .cmd = command, .account = account, .messageId = message_id, .attachmentId = "thread-token-B", .path = quota_path }));
        if (std.mem.eql(u8, command, "mail.attachment")) {
            try std.testing.expectEqualStrings("thread-token-C", j.text(result, "id"));
            try std.testing.expectEqualSlices(u8, Oracle.pdf, try @import("mime.zig").decodeBase64Url(j.text(result, "data"), a));
        } else try std.testing.expectEqualSlices(u8, Oracle.pdf, try tmp.dir.readFileAlloc(std.testing.io, "quota-saved.pdf", a, .limited(1024)));
    }
}

test "attachment identity: a concurrent refresh retains fresh tokens without changing membership or resurrecting mail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/attachment-generation", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const old: t.Message = .{ .id = "retained", .threadId = "retained-thread", .bodyText = "Immutable original", .receivedAt = 1000, .labels = &.{"INBOX"}, .unread = true, .attachments = &.{.{ .id = "token-A", .filename = "report.pdf", .size = 2 }} };
    try store.put(old, true);
    const current = store.find(old.id).?;
    current.message.labels = &.{"STARRED"};
    current.message.unread = false;
    current.message.receivedAt = 2000;
    store.state.generation += 1;
    const generation = store.state.generation;
    var fresh = old;
    fresh.attachments = &.{.{ .id = "token-B", .filename = "report.pdf", .size = 2, .data = "AP8" }};
    try Session.retainReadBody(&store, fresh);
    try std.testing.expectEqualStrings("token-A", (try store.read(old.id)).?.attachments[0].id);
    const metadata = store.find(old.id).?.message;
    try std.testing.expectEqualStrings("token-B", metadata.attachments[0].id);
    try std.testing.expectEqualStrings("", metadata.attachments[0].data);
    try std.testing.expectEqualStrings("STARRED", metadata.labels[0]);
    try std.testing.expect(!metadata.unread);
    try std.testing.expectEqual(@as(i64, 2000), metadata.receivedAt);
    try std.testing.expectEqual(generation, store.state.generation);
    fresh.id = "evicted";
    try Session.retainReadBody(&store, fresh);
    try std.testing.expect(store.find(fresh.id) == null);
    fresh.id = old.id;
    fresh.threadId = "wrong-thread";
    try std.testing.expectError(error.MessageIdentityMismatch, Session.retainReadBody(&store, fresh));
    try std.testing.expectEqualStrings("token-B", store.find(old.id).?.message.attachments[0].id);
}

test "attachment identity: duplicate exact descriptors are ambiguous" {
    const one: t.Attachment = .{ .id = "same-id", .filename = "one.pdf", .size = 2, .data = "AP8" };
    const another: t.Attachment = .{ .id = "same-id", .filename = "another.pdf", .size = 2, .data = "_wA" };
    try std.testing.expectEqualDeep(one, (try Session.exactAttachment(&.{one}, "same-id")).?);
    try std.testing.expect((try Session.exactAttachment(&.{one}, "unknown")) == null);
    try std.testing.expectError(error.AmbiguousAttachment, Session.exactAttachment(&.{ one, another }, "same-id"));
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
        const original: t.Message = .{ .id = "large-original", .threadId = "original-thread", .from = .{ .address = account }, .to = &.{.{ .address = "peer@example.test" }}, .labels = &.{"SENT"}, .subject = "Large report", .bodyText = "Report attached.", .attachments = &.{imported} };
        try store.put(original, true);
        try store.put(.{ .id = original.id, .threadId = original.threadId, .subject = original.subject, .labels = &.{"SENT"} }, false);
        try std.testing.expectEqualStrings(imported.blobId.?, store.find(original.id).?.message.attachments[0].blobId.?);
        // A concurrent FULL read omits local blob handles. Exact-ID metadata
        // refresh must preserve the existing backing file across saving and
        // reopening, so the following forward/save/send lifecycle still works.
        var provider_attachment = imported;
        provider_attachment.blobId = null;
        var refreshed = original;
        refreshed.attachments = &.{provider_attachment};
        try Session.retainReadBody(&store, refreshed);
        try std.testing.expectEqualStrings(imported.blobId.?, store.find(original.id).?.message.attachments[0].blobId.?);
        try std.testing.expect(store.blobReferenced(imported.blobId.?));
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
    try std.testing.expectError(error.ArchivedDraftReadOnly, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = draft.id, .operationId = "fresh-sent-source" })));
    const corruption_copy = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = draft.id }));
    {
        var store = try storage.Store.open(std.testing.io, a, root, account, session.options);
        defer store.close();
        const blob_name = try @import("attachment_blob.zig").filename(a, imported.blobId.?);
        const corrupt = try store.dir.openFile(std.testing.io, blob_name, .{ .mode = .read_write, .follow_symlinks = false });
        defer corrupt.close(std.testing.io);
        try corrupt.writeStreamingAll(std.testing.io, "changed");
    }
    try std.testing.expectError(error.AttachmentChanged, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = j.text(corruption_copy, "id"), .operationId = "corrupt-fixture-send" })));
    const stats = try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account }));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(stats, "fixtureSends", 0));
}

test "draft save: compact acknowledgements preserve originals files and default full responses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/compact-draft-save", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root });
    defer session.deinit();
    const account = "personal@example.com";
    const original: t.Original = .{ .sourceMessageId = "frozen-source", .bodyHtml = "<p>Frozen source</p><img src=\"cid:frozen\">", .resources = &.{.{ .id = "frozen", .filename = "frozen.png", .mimeType = "image/png", .size = 3, .data = "AAH_", .contentId = "frozen" }} };
    const files: []const t.Attachment = &.{.{ .id = "file", .filename = "file.bin", .size = 3, .data = "AP-A" }};
    const created = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .acknowledgementOnly = true, .draft = t.Draft{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "First note", .bodyFormat = .markdown, .attachments = files, .original = original } }));
    try std.testing.expectEqual(@as(usize, 1), created.object.count());
    const id = try j.required(created, "id");
    const updated = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .to = "peer@example.test", .bodyText = "Edited note", .attachments = files } }));
    try std.testing.expectEqual(@as(usize, 1), updated.object.count());
    try std.testing.expectEqualStrings(id, j.text(updated, "id"));
    var saved = try decodeDraft(a, try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = id })));
    try std.testing.expectEqualStrings("Edited note", saved.bodyText);
    try std.testing.expectEqual(t.BodyFormat.markdown, saved.bodyFormat);
    try std.testing.expectEqualDeep(original, saved.original.?);
    try std.testing.expectEqualDeep(files, saved.attachments);
    const fields = [_][]const u8{ "unfinished address", "", "", "Recovery", "Unfinished note" };
    const recovered = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.recovery-save", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .recoveryFields = fields, .attachments = files } }));
    try std.testing.expectEqual(@as(usize, 1), recovered.object.count());
    try std.testing.expectEqualStrings(id, j.text(recovered, "id"));
    saved = try decodeDraft(a, try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = id })));
    try std.testing.expectEqualDeep(original, saved.original.?);
    try std.testing.expectEqualDeep(files, saved.attachments);
    try std.testing.expectEqualStrings(fields[4], saved.recoveryFields.?[4]);
    const before = try std.json.Stringify.valueAlloc(a, saved, .{});
    for ([_][]const u8{ "draft.create", "draft.update", "draft.recovery-save" }) |cmd| {
        try std.testing.expectError(error.InvalidRequest, session.dispatch(a, try j.value(a, .{ .cmd = cmd, .account = account, .draftId = id, .acknowledgementOnly = "true", .draft = .{ .to = "peer@example.test", .bodyText = "Must not replace saved content", .recoveryFields = fields, .attachments = files } })));
    }
    try std.testing.expectError(error.HeaderInjection, session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .subject = "Invalid\r\nHeader", .attachments = files } })));
    saved = try decodeDraft(a, try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = id })));
    try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(a, saved, .{}));
    const listed = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.list", .account = account }));
    try std.testing.expectEqual(@as(usize, 1), (try array(listed, "drafts")).len);
    for ([_]bool{ false, true }) |explicit_false| {
        var request = try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .to = "peer@example.test", .bodyText = "Finished note", .attachments = files } });
        if (explicit_false) try request.object.put(a, "acknowledgementOnly", .{ .bool = false });
        const full = try decodeDraft(a, try session.dispatch(a, request));
        try std.testing.expectEqualStrings("Finished note", full.bodyText);
        try std.testing.expectEqualDeep(original, full.original.?);
        try std.testing.expectEqualDeep(files, full.attachments);
    }
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

test "follow-ups: evicted provider metadata creates exact account reminder without retention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/follow-up-quota", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    try Session.initInto(session, std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root, .metadata_limit = 1 }, null);
    defer session.deinit();
    const account = "personal@example.com";
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "demo-96" }));
    const displayed = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "demo-1" }));
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        try std.testing.expect(store.find("demo-1") == null);
        try std.testing.expect(store.find("demo-96") != null);
    }
    const saved = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-1", .dueDate = "2026-10-14", .expectedVersion = 0, .snapshot = .{ .subject = "Untrusted client text", .threadId = "wrong-thread" } }));
    const entry = j.get(saved, "entry").?;
    try std.testing.expectEqualStrings(j.text(displayed, "subject"), j.text(entry, "subject"));
    try std.testing.expectEqualStrings(j.text(displayed, "threadId"), j.text(entry, "threadId"));
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        try std.testing.expectEqual(@as(usize, 1), store.state.entries.len);
        try std.testing.expect(store.find("demo-1") == null);
        try std.testing.expect(store.find("demo-96") != null);
    }
    // The same provider ID in another account resolves its own trusted header.
    const other = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = "work@example.com", .messageId = "demo-1", .dueDate = "2026-10-15", .expectedVersion = 0 }));
    try std.testing.expect(std.mem.startsWith(u8, j.text(j.get(other, "entry").?, "subject"), "work@example.com:"));
    try std.testing.expectError(error.MessageNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "missing-provider-message", .dueDate = "2026-10-14", .expectedVersion = 0, .snapshot = .{ .subject = "Untrusted" } })));
    session.options.fixture_scenario = "offline-refresh";
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-1", .dueDate = "2026-10-15", .expectedVersion = try j.integer(entry, "version", 0) }));
    try std.testing.expectError(error.FollowUpMetadataUnavailableOffline, session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-2", .dueDate = "2026-10-14", .expectedVersion = 0 })));
    try std.testing.expectError(error.FollowUpChanged, session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-2", .dueDate = "2026-10-14", .expectedVersion = 1 })));
    try std.testing.expectEqual(@as(usize, 1), (try array(try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.list", .account = account })), "entries")).len);
}

test "follow-ups: local account reminders survive cache clear restart and stale edits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/follow-up-cache", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    try Session.initInto(session, std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root }, null);
    defer session.deinit();
    const account = "personal@example.com";
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "mail.read", .account = account, .messageId = "demo-1" }));
    const saved = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-1", .dueDate = "2026-10-14", .expectedVersion = 0 }));
    const first = try j.integer(j.get(saved, "entry").?, "version", 0);
    try std.testing.expect(first > 0);
    try std.testing.expectError(error.FollowUpChanged, session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-1", .dueDate = "2026-10-15", .expectedVersion = 0 })));
    _ = try session.dispatch(a, try j.value(a, .{ .cmd = "cache.clear", .account = account }));
    const listed = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.list", .account = account, .cacheOnly = true }));
    try std.testing.expectEqual(@as(usize, 1), (try array(listed, "entries")).len);
    try std.testing.expectEqualStrings("demo-1", j.text((try array(listed, "messages"))[0], "id"));
    try std.testing.expectEqual(@as(usize, 0), (try array(try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.list", .account = "work@example.com" })), "entries")).len);
    const edited = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-1", .dueDate = "2026-10-15", .expectedVersion = first }));
    const second = try j.integer(j.get(edited, "entry").?, "version", 0);
    // A second Session reads the private document without requiring mail data.
    const reopened = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(reopened);
    try Session.initInto(reopened, std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root }, null);
    defer reopened.deinit();
    const persisted = try reopened.dispatch(a, try j.value(a, .{ .cmd = "reminder.list", .account = account }));
    try std.testing.expectEqualStrings("2026-10-15", j.text((try array(persisted, "entries"))[0], "dueDate"));
    try std.testing.expectError(error.FollowUpChanged, reopened.dispatch(a, try j.value(a, .{ .cmd = "reminder.done", .account = account, .messageId = "demo-1", .expectedVersion = first })));
    _ = try reopened.dispatch(a, try j.value(a, .{ .cmd = "reminder.done", .account = account, .messageId = "demo-1", .expectedVersion = second }));
    const completed = try session.dispatch(a, try j.value(a, .{ .cmd = "reminder.list", .account = account }));
    try std.testing.expectEqual(@as(usize, 0), (try array(completed, "entries")).len);
    session.options.fixture_scenario = "offline-refresh";
    try std.testing.expectError(error.FollowUpMetadataUnavailableOffline, session.dispatch(a, try j.value(a, .{ .cmd = "reminder.set", .account = account, .messageId = "demo-1", .dueDate = "2026-10-15", .expectedVersion = 0 })));
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

test "invitation offline: cached identity and exact confirmed source survive inspection without provider calls" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("TZ", "UTC");
    const session = try a.create(Session);
    session.* = try Session.init(io, a, &env, .{ .fixtures = true, .cache_dir = try std.fmt.allocPrint(a, "{s}/cache", .{root}) });
    defer session.deinit();
    const account = "personal@example.com";
    const ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:offline@example.test\r\nDTSTAMP:20261013T100000Z\r\nSEQUENCE:3\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:alias@example.test\r\nDTSTART:20261014T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var invite: invitation.Invitation = .{};
    try invitation.parse(ics, account, &.{"alias@example.test"}, &invite);
    const wire = try a.alloc(u8, invitation.max_calendar_bytes);
    const response = try invitation.reply(&invite, .accepted, "20261013T110000Z", wire);
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        try store.put(.{ .id = "offline-invitation", .threadId = "offline-thread", .bodyText = "Planning", .invitation = ics }, true);
        // Confirmed receipts do not depend on a still-populated send-as cache.
        const hash = storage.Store.hash(ics);
        store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "accepted", .hash = "synthetic", .outcome = "applied", .icalendar = response, .sourceInvitationHash = try a.dupe(u8, &hash) }});
        try store.save();
    }
    const result = try session.dispatch(a, try j.value(a, .{ .cmd = "invitation.inspect", .account = account, .messageId = "offline-invitation", .cacheOnly = true }));
    try std.testing.expectEqualStrings("ACCEPTED", j.text(result, "confirmedResponse"));
    try std.testing.expectEqualStrings("", j.text(result, "attendee"));
    try std.testing.expect(!try j.boolean(result, "canReply", false));
    var store = try session.openStore(a, account, false);
    defer store.close();
    try std.testing.expectEqual(@as(u64, 0), store.state.fixtureCalls);
    try std.testing.expectEqualStrings("", (try Session.confirmedInvitationResponse(a, &store, "changed source", account, &.{"alias@example.test"})).status);
    const repeated = try j.value(a, .{ .operationId = "accepted", .status = "accepted" });
    try std.testing.expectEqualStrings("applied", j.text((try Session.invitationReceipt(a, &store, ics, repeated)).?, "outcome"));
    try std.testing.expectError(error.OperationConflict, Session.invitationReceipt(a, &store, "other source", repeated));
    try std.testing.expectError(error.OperationConflict, Session.invitationReceipt(a, &store, ics, try j.value(a, .{ .operationId = "accepted", .status = "declined" })));
    store.state.operations[0].outcome = "unknown";
    try std.testing.expectEqualStrings("unknown", (try Session.confirmedInvitationResponse(a, &store, ics, account, &.{"alias@example.test"})).outcome);
    try std.testing.expectEqualStrings("unknown", j.text((try Session.invitationReceipt(a, &store, ics, repeated)).?, "outcome"));
}

test "calendar RSVP: mail receipt survives calendar failures and reply replay never resends" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("TZ", "UTC");
    const account = "personal@example.com";
    const cases = [_]struct { scenario: []const u8, status: []const u8, mail: []const u8, sync: []const u8, writes: i64 }{
        .{ .scenario = "", .status = "accepted", .mail = "applied", .sync = "applied", .writes = 1 },
        .{ .scenario = "", .status = "tentative", .mail = "applied", .sync = "applied", .writes = 1 },
        .{ .scenario = "", .status = "declined", .mail = "applied", .sync = "skipped", .writes = 0 },
        .{ .scenario = "calendar-no-grant", .status = "accepted", .mail = "applied", .sync = "skipped", .writes = 0 },
        .{ .scenario = "calendar-readonly", .status = "accepted", .mail = "applied", .sync = "skipped", .writes = 0 },
        .{ .scenario = "calendar-offline", .status = "accepted", .mail = "applied", .sync = "skipped", .writes = 0 },
        .{ .scenario = "calendar-lost-response", .status = "accepted", .mail = "applied", .sync = "unknown", .writes = 1 },
        .{ .scenario = "unknown-send", .status = "accepted", .mail = "unknown", .sync = "skipped", .writes = 0 },
    };
    for (cases, 0..) |case, index| {
        const session = try a.create(Session);
        session.* = try Session.init(io, a, &env, .{ .fixtures = true, .fixture_scenario = case.scenario, .cache_dir = try std.fmt.allocPrint(a, "{s}/case-{d}", .{ root, index }) });
        defer session.deinit();
        const ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:auto-rsvp@example.test\r\nDTSTAMP:20261013T100000Z\r\nSEQUENCE:3\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:personal@example.com\r\nDTSTART:20261014T100000Z\r\nDTEND:20261014T110000Z\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        {
            var store = try session.openStore(a, account, false);
            defer store.close();
            try store.put(.{ .id = "auto-invitation", .threadId = "auto-thread", .bodyText = "Planning", .invitation = ics }, true);
            try store.save();
        }
        const request = try j.value(a, .{ .cmd = "invitation.reply", .account = account, .messageId = "auto-invitation", .status = case.status, .operationId = "mail-reply" });
        const receipt = try session.dispatch(a, request);
        if (!std.mem.eql(u8, case.sync, j.text(j.get(receipt, "calendarSync").?, "state"))) std.debug.print("Calendar RSVP fixture case {d}: {s}\n", .{ index, j.text(j.get(receipt, "calendarSync").?, "errorCode") });
        try std.testing.expectEqualStrings(case.mail, j.text(receipt, "outcome"));
        try std.testing.expectEqualStrings(case.sync, j.text(j.get(receipt, "calendarSync").?, "state"));
        if (std.mem.eql(u8, case.scenario, "calendar-lost-response")) {
            session.options.fixture_scenario = "calendar-offline";
            const unavailable = try session.dispatch(a, request);
            try std.testing.expectEqualStrings("unknown", j.text(j.get(unavailable, "calendarSync").?, "state"));
        }
        session.options.fixture_scenario = "";
        const again = try session.dispatch(a, request);
        try std.testing.expectEqualStrings(case.mail, j.text(again, "outcome"));
        if (std.mem.eql(u8, case.sync, "unknown")) try std.testing.expectEqualStrings("applied", j.text(j.get(again, "calendarSync").?, "state"));
        var changed_target = try j.copyObject(a, request);
        try changed_target.object.put(a, "calendarId", .{ .string = "fixture-shared-team" });
        try std.testing.expectError(error.OperationConflict, session.dispatch(a, changed_target));
        const inspected = try session.dispatch(a, try j.value(a, .{ .cmd = "invitation.inspect", .account = account, .messageId = "auto-invitation", .cacheOnly = true }));
        if (std.mem.eql(u8, case.mail, "applied")) {
            try std.testing.expectEqualStrings("applied", j.text(inspected, "responseOutcome"));
            try std.testing.expectEqualStrings(j.text(j.get(again, "calendarSync").?, "state"), j.text(j.get(inspected, "calendarSync").?, "state"));
        }
        var store = try session.openStore(a, account, false);
        defer store.close();
        try std.testing.expectEqual(@as(u64, if (std.mem.eql(u8, case.mail, "applied")) 1 else 0), store.state.fixtureSends);
        const calendar_state = try store.readDocument(a, @import("calendar_fixture.zig").document_name, @import("calendar_fixture.zig").document_bytes);
        const writes = if (calendar_state) |raw| try j.integer(try std.json.parseFromSliceLeaky(Value, a, raw, .{}), "writes", -1) else 0;
        try std.testing.expectEqual(case.writes, writes);
    }
}

test "calendar RSVP: Check Sent resumes calendar only after confirming the reply" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("TZ", "UTC");
    const session = try a.create(Session);
    session.* = try Session.init(io, a, &env, .{ .fixtures = true, .fixture_scenario = "applied-lost", .cache_dir = try std.fmt.allocPrint(a, "{s}/cache", .{root}) });
    defer session.deinit();
    const account = "personal@example.com";
    const ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:reconcile-rsvp@example.test\r\nDTSTAMP:20261013T100000Z\r\nSEQUENCE:3\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:personal@example.com\r\nDTSTART:20261014T100000Z\r\nDTEND:20261014T110000Z\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        try store.put(.{ .id = "reconcile-invitation", .threadId = "reconcile-thread", .bodyText = "Planning", .invitation = ics }, true);
        try store.save();
    }
    const request = try j.value(a, .{ .cmd = "invitation.reply", .account = account, .messageId = "reconcile-invitation", .status = "accepted", .operationId = "mail-reconcile" });
    const lost = try session.dispatch(a, request);
    try std.testing.expectEqualStrings("unknown", j.text(lost, "outcome"));
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        try std.testing.expect(try store.readDocument(a, @import("calendar_fixture.zig").document_name, @import("calendar_fixture.zig").document_bytes) == null);
    }
    session.options.fixture_scenario = "calendar-offline";
    const check = try j.value(a, .{ .cmd = "invitation.inspect", .account = account, .messageId = "reconcile-invitation", .reconcile = true });
    const offline = try session.dispatch(a, check);
    try std.testing.expectEqualStrings("applied", j.text(offline, "responseOutcome"));
    try std.testing.expectEqualStrings("skipped", j.text(j.get(offline, "calendarSync").?, "state"));
    session.options.fixture_scenario = "";
    const resolved = try session.dispatch(a, check);
    try std.testing.expectEqualStrings("applied", j.text(resolved, "responseOutcome"));
    try std.testing.expectEqualStrings("applied", j.text(j.get(resolved, "calendarSync").?, "state"));
    _ = try session.dispatch(a, check);
    var store = try session.openStore(a, account, false);
    defer store.close();
    try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
    const state = try store.readDocument(a, @import("calendar_fixture.zig").document_name, @import("calendar_fixture.zig").document_bytes) orelse return error.MissingCalendarFixture;
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try std.json.parseFromSliceLeaky(Value, a, state, .{}), "writes", -1));
}

test "calendar browser: native commands open exact account profile after source-bound reads without writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    try environment.put("HOME", "/tmp/synthetic-calendar-browser-home");
    const session = try a.create(Session);
    session.* = try Session.init(std.testing.io, a, &environment, .{ .fixtures = true, .cache_dir = try std.fs.path.join(a, &.{ root, "cache" }) });
    defer session.deinit();
    const account_names = [_][]const u8{ "personal@example.com", "work@example.com", "optional@example.com" };
    session.config.accounts[session.config.index("optional@example.com").?].enabled = true;
    for (account_names) |address| {
        const home = session.dispatch(a, try j.value(a, .{ .cmd = "calendar.open", .account = address })) catch |err| {
            std.debug.print("Calendar browser source read failed: {s}\n", .{@errorName(err)});
            return err;
        };
        const index = session.config.index(address).?;
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "--profile-directory={s}", .{session.config.accounts[index].profile.slice()}), j.text(home, "profile"));
        const calendar_url = j.text(home, "url");
        try std.testing.expect(std.mem.startsWith(u8, calendar_url, "https://calendar.google.com/calendar/r?authuser="));
        try std.testing.expect(std.mem.indexOf(u8, calendar_url, "%40example.com") != null);
        const opened = try session.dispatch(a, try j.value(a, .{ .cmd = "calendar.event-open", .account = address, .calendarId = address, .eventId = "fixture-planning" }));
        try std.testing.expectEqualStrings(j.text(home, "profile"), j.text(opened, "profile"));
        try std.testing.expect(std.mem.indexOf(u8, j.text(opened, "url"), "eid=fixture-planning") != null);
        try std.testing.expect(!try j.boolean(opened, "opened", true));
        try std.testing.expectError(error.CalendarNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "calendar.open", .account = address, .calendarId = "does-not-exist" })));
        var store = try session.openStore(a, address, false);
        defer store.close();
        const bytes = try store.readDocument(a, @import("calendar_fixture.zig").document_name, @import("calendar_fixture.zig").document_bytes) orelse return error.MissingCalendarFixture;
        const state = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
        try std.testing.expectEqual(@as(i64, 0), try j.integer(state, "writes", -1));
        try std.testing.expectEqual(@as(u64, 0), store.state.fixtureSends);
    }
}

test "send grace: request preparation OOM never strands an unsubmitted queue claim" {
    var completed = false;
    var observed_preflight = false;
    for (0..192) |failure_index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/queue-preclaim", .{tmp.sub_path});
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", root);
        const options: t.Options = .{ .fixtures = true, .cache_dir = root };
        const session = try std.testing.allocator.create(Session);
        defer std.testing.allocator.destroy(session);
        try session.initInto(std.testing.io, std.testing.allocator, &env, options, null);
        defer session.deinit();
        var store = try storage.Store.open(std.testing.io, a, root, "personal@example.com", options);
        defer store.close();
        const draft = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Queue request preparation" }, null);
        const digest = try operationDigest(a, draft, store.state.account, null);
        const entry = try send_queue.stage(&store, draft.id, "queue-preclaim-operation", &digest, 0, 0);
        const request = try j.value(a, .{ .cmd = "queue.send-now", .account = store.state.account, .queueId = entry.queueId });
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure_index });
        _ = session.queuedSend(failing.allocator(), &store, request) catch |err| {
            if (err == error.OutOfMemory and store.state.fixtureCalls == 0) {
                observed_preflight = true;
                try std.testing.expect(store.state.sendQueue[0].state != .submitting);
                // Restart sees the same queued/rejected safe preflight state.
                store.close();
                store = try storage.Store.openCached(std.testing.io, a, root, "personal@example.com", options);
                try std.testing.expect(store.state.sendQueue[0].state != .submitting);
            } else try std.testing.expect(err == error.UnknownOutcome);
        };
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(@as(u64, 1), store.state.fixtureCalls);
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed and observed_preflight);
}

test "reviewed draft: another session cannot replace measured content before send or queue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/reviewed-content", .{tmp.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const reviewer = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(reviewer);
    reviewer.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer reviewer.deinit();
    const editor = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(editor);
    editor.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer editor.deinit();
    const account = "personal@example.com";
    const original: t.Draft = .{ .to = &.{.{ .address = "peer@example.test" }}, .subject = "Reviewed", .bodyText = "Authored note", .original = .{ .bodyText = "Retained original", .bodyHtml = "<p>Retained original</p>" } };
    const created = try reviewer.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = original }));
    const id = j.text(created, "id");
    for (0..5) |change| {
        _ = try editor.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = original }));
        const operation = try std.fmt.allocPrint(a, "reviewed-{d}", .{change});
        const measured = try reviewer.dispatch(a, try j.value(a, .{ .cmd = "draft.measure", .account = account, .draftId = id, .operationId = operation }));
        const digest = j.text(measured, "contentDigest");
        try std.testing.expectEqual(@as(usize, 64), digest.len);
        var changed = original;
        switch (change) {
            0 => changed.bodyText = "Changed after review",
            1 => changed.subject = "Changed subject",
            2 => changed.from = .{ .address = account, .name = "Changed sender" },
            3 => changed.includeOriginal = false,
            4 => changed.attachments = &.{.{ .id = "new-file", .filename = "added.txt", .mimeType = "text/plain", .size = 3, .data = "YWJj" }},
            else => unreachable,
        }
        _ = try editor.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = changed }));
        for ([_][]const u8{ "draft.send", "draft.queue" }) |cmd| try std.testing.expectError(error.ReviewedDraftChanged, reviewer.dispatch(a, try j.value(a, .{ .cmd = cmd, .account = account, .draftId = id, .operationId = operation, .expectedContentDigest = digest, .delaySeconds = 0 })));
        const stats = try reviewer.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account }));
        try std.testing.expectEqual(@as(i64, 0), try j.integer(stats, "fixtureSends", 0));
        try std.testing.expectEqual(@as(usize, 0), j.get(try reviewer.dispatch(a, try j.value(a, .{ .cmd = "queue.list", .account = account })), "queue").?.array.items.len);
        try std.testing.expectError(error.OperationNotFound, reviewer.dispatch(a, try j.value(a, .{ .cmd = "operation.read", .account = account, .operationId = operation })));
    }
    const measured = try reviewer.dispatch(a, try j.value(a, .{ .cmd = "draft.measure", .account = account, .draftId = id, .operationId = "reviewed-approved" }));
    const digest = j.text(measured, "contentDigest");
    const queued = try reviewer.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = id, .operationId = "reviewed-approved", .expectedContentDigest = digest, .delaySeconds = 0 }));
    const wrong = storage.Store.hash("unreviewed-content");
    try std.testing.expectError(error.ReviewedDraftChanged, reviewer.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(queued, "queueId"), .expectedContentDigest = wrong[0..] })));
    const receipt = try reviewer.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(queued, "queueId"), .expectedContentDigest = digest }));
    try std.testing.expectEqualStrings("applied", j.text(receipt, "state"));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try reviewer.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
}

test "retained history: schema one draft lists stay compact while exact large sources remain readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-list", .{tmp.sub_path});
    const account = "personal@example.com";
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const large = try a.alloc(u8, 2 * 1024 * 1024);
    @memset(large, 'x');
    var store = try storage.Store.open(std.testing.io, a, root, account, options);
    const saved = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .subject = "Legacy source", .bodyText = large, .original = .{ .bodyText = large, .bodyHtml = "<p>Exact retained HTML</p>" } }, null);
    // Public 0.2.12 already kept payloads in separate draft files. Recreate
    // its schema-1 index and exact draft shape, without the new fields.
    var state = store.state;
    state.schema = 1;
    var old_preview = saved;
    old_preview.bodyText = "";
    old_preview.original = null;
    old_preview.summaryCounts = null;
    state.drafts = try a.dupe(t.Draft, &.{old_preview});
    state.relatedDraftBlobs = &.{};
    var index = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, state, .{}), .{ .allocate = .alloc_if_needed });
    _ = index.object.orderedRemove("history");
    for (index.object.getPtr("drafts").?.array.items) |*value| {
        _ = value.object.orderedRemove("includeOriginal");
        _ = value.object.orderedRemove("summaryCounts");
    }
    const encoded_index = try std.json.Stringify.valueAlloc(a, index, .{});
    try std.testing.expect(encoded_index.len < 16 * 1024);
    try store.write("index.json", encoded_index);
    var full = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, saved, .{}), .{ .allocate = .alloc_if_needed });
    _ = full.object.orderedRemove("includeOriginal");
    _ = full.object.orderedRemove("summaryCounts");
    try store.write(try store.fileName("draft", saved.id), try std.json.Stringify.valueAlloc(a, full, .{}));
    store.close();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/synthetic-omagma-home");
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = try Session.init(std.testing.io, std.testing.allocator, &env, options);
    defer session.deinit();
    const list = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.list", .account = account }));
    try std.testing.expect((try std.json.Stringify.valueAlloc(a, list, .{})).len < 16 * 1024);
    const loaded = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = saved.id }));
    try std.testing.expectEqualStrings(large, j.text(loaded, "bodyText"));
    try std.testing.expectEqualStrings(large, j.text(j.get(loaded, "original").?, "bodyText"));
    try std.testing.expectEqualStrings("<p>Exact retained HTML</p>", j.text(j.get(loaded, "original").?, "bodyHtml"));
}

test "retained history: accepted direct and queued drafts archive immediately and clone explicitly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/accepted-immutable", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    try session.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer session.deinit();
    const account = "personal@example.com";
    const input: t.Draft = .{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Exact accepted authored text", .includeOriginal = false, .original = .{ .bodyText = "Retained excluded original" } };
    for ([_]bool{ false, true }, 0..) |queued, index| {
        const saved = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = input }));
        const id = j.text(saved, "id");
        const operation = try std.fmt.allocPrint(a, "immediately-retained-{d}", .{index});
        const send_request = try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = id, .operationId = operation });
        if (queued) {
            const queue = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = id, .operationId = operation, .delaySeconds = 0 }));
            const result = try session.dispatch(a, try j.value(a, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(queue, "queueId") }));
            try std.testing.expectEqualStrings("applied", j.text(result, "state"));
            try std.testing.expectEqualStrings("applied", j.text(try session.dispatch(a, try j.value(a, .{ .cmd = "queue.read", .account = account, .queueId = j.text(queue, "queueId") })), "state"));
        } else try std.testing.expectEqualStrings("applied", j.text(try session.dispatch(a, send_request), "outcome"));
        const listed = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.list", .account = account }));
        try std.testing.expectEqual(@as(usize, 0), j.get(listed, "drafts").?.array.items.len);
        var changed = input;
        changed.bodyText = "Changed after acceptance";
        try std.testing.expectError(error.ArchivedDraftReadOnly, session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = changed })));
        try std.testing.expectError(error.ArchivedDraftReadOnly, session.dispatch(a, try j.value(a, .{ .cmd = "draft.discard", .account = account, .draftId = id })));
        session.deinit();
        try session.initInto(std.testing.io, std.testing.allocator, &env, options, null);
        const exact = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = id }));
        try std.testing.expectEqualStrings(input.bodyText, j.text(exact, "bodyText"));
        try std.testing.expectEqualStrings(input.original.?.bodyText, j.text(j.get(exact, "original").?, "bodyText"));
        try std.testing.expect(!try j.boolean(exact, "includeOriginal", true));
        const cloned = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = id }));
        try std.testing.expect(!std.mem.eql(u8, id, j.text(cloned, "id")));
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = j.text(cloned, "id"), .draft = changed }));
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.discard", .account = account, .draftId = j.text(cloned, "id") }));
        _ = try session.dispatch(a, send_request);
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), try j.integer(try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "history.delete-source", .account = account, .draftId = id, .confirm = true }));
        try std.testing.expectEqualStrings("applied", j.text(try session.dispatch(a, send_request), "outcome"));
        if (queued) {
            const repeated = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = id, .operationId = operation, .delaySeconds = 0 }));
            try std.testing.expectEqualStrings("applied", j.text(repeated, "state"));
            try std.testing.expectEqual(@as(i64, @intCast(index + 1)), try j.integer(try session.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
        }
    }
}

test "retained history: accepted receipt survives archive failure without allowing source reuse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/archive-after-accept", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    try session.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer session.deinit();
    var store = try session.openStore(a, "personal@example.com", false);
    defer store.close();
    const original = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Accepted before archive failure" }, null);
    const request = try j.value(a, .{ .cmd = "draft.send", .account = store.state.account, .draftId = original.id, .operationId = "accepted-archive-failure" });
    store.history_fault = .before_publication;
    const result = try session.send(a, &store, request, original, null, false);
    try std.testing.expectEqualStrings("applied", j.text(result, "outcome"));
    try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
    try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
    store.close();
    store = try session.openStore(a, "personal@example.com", false);
    var other = try j.copyObject(a, request);
    try other.object.put(a, "operationId", .{ .string = "fresh-id-must-not-resend" });
    try std.testing.expectError(error.ArchivedDraftReadOnly, session.send(a, &store, other, original, null, false));
    try std.testing.expectEqualStrings("applied", j.text(try session.send(a, &store, request, original, null, false), "outcome"));
    try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
    try std.testing.expectEqual(@as(usize, 0), store.state.drafts.len);
    try std.testing.expectEqualStrings(original.bodyText, (try store.draft(original.id)).bodyText);
}

test "retained history: explicit recovery fork preserves unsaved text after another session sends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/concurrent-recovery", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const editor = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(editor);
    try editor.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer editor.deinit();
    const sender = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(sender);
    try sender.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer sender.deinit();
    const account = "personal@example.com";
    const created = try editor.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Saved and sent source", .original = .{ .bodyText = "Exact retained original", .bodyHtml = "<p>Exact retained original</p>" } } }));
    const old_id = j.text(created, "id");
    _ = try sender.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = old_id, .operationId = "other-session-accepted" }));
    const fields: [5][]const u8 = .{ "unfinished recipient <", "", "hidden@example.test", "Unsaved subject", "Exact unsaved note\nwith unfinished **Markdown" };
    var recovery = try j.value(a, .{ .cmd = "draft.recovery-save", .account = account, .draftId = old_id, .acknowledgementOnly = true, .draft = .{ .bodyFormat = "markdown", .includeOriginal = false, .recoveryFields = fields, .attachments = .{.{ .id = "unsaved-file", .filename = "note.txt", .mimeType = "text/plain", .size = 3, .data = "YWJj" }} } });
    try recovery.object.put(a, "copyFromDraftId", .null);
    try std.testing.expectError(error.ArchivedDraftReadOnly, editor.dispatch(a, recovery));
    try recovery.object.put(a, "forkIfSettled", .{ .bool = true });
    const saved = try editor.dispatch(a, recovery);
    try std.testing.expectEqualStrings(old_id, j.text(saved, "forkedFrom"));
    const new_id = j.text(saved, "id");
    try std.testing.expect(!std.mem.eql(u8, old_id, new_id));
    editor.deinit();
    try editor.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    const restored = try editor.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = new_id }));
    for (fields, j.get(restored, "recoveryFields").?.array.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual.string);
    try std.testing.expect(!try j.boolean(restored, "includeOriginal", true));
    try std.testing.expectEqualStrings("Exact retained original", j.text(j.get(restored, "original").?, "bodyText"));
    try std.testing.expectEqualStrings("note.txt", j.text(j.get(restored, "attachments").?.array.items[0], "filename"));
    const original = try editor.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = old_id }));
    try std.testing.expectEqualStrings("Saved and sent source", j.text(original, "bodyText"));
    try std.testing.expect(try j.boolean(original, "includeOriginal", true));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(try editor.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
    // The explicit fork never bypasses unresolved external ownership, even
    // if a prior applied source also exists for the same historical identity.
    var store = try editor.openStore(a, account, false);
    defer store.close();
    store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "pending", .hash = "pending", .draftId = old_id }});
    try std.testing.expectError(error.UnknownOutcome, Session.recoveryForkAllowed(&store, old_id));
    store.state.operations = &.{};
    store.state.sendQueue = try a.dupe(storage.QueuedSend, &.{.{ .queueId = "queued", .draftId = old_id, .operationId = "queued", .hash = "queued", .createdAtMs = 0, .dueAtMs = 0 }});
    try std.testing.expectError(error.DraftQueued, Session.recoveryForkAllowed(&store, old_id));
    store.state.sendQueue[0].state = .submitting;
    try std.testing.expectError(error.UnknownOutcome, Session.recoveryForkAllowed(&store, old_id));
    store.state.sendQueue = &.{};
    store.state.draftLinks = try a.dupe(@import("draft_link.zig").Link, &.{.{ .draftId = old_id, .paused = true, .attemptMessageId = "<pending@example.test>", .uploadedDigest = &storage.Store.hash("pending") }});
    try std.testing.expectError(error.DraftPausedInGmail, Session.recoveryForkAllowed(&store, old_id));
}

test "retained history: queue finalization survives cleanup failure without restoring retired sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/queue-cleanup-boundary", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    try session.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer session.deinit();
    var store = try session.openStore(a, "personal@example.com", false);
    defer store.close();
    const older = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Prior applied source" }, null);
    const older_hash = try operationDigest(a, older, store.state.account, null);
    store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "prior-applied", .hash = &older_hash, .draftId = older.id, .outcome = "applied" }});
    const draft = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Queued accepted source" }, null);
    const digest = try operationDigest(a, draft, store.state.account, null);
    var entry = try send_queue.stage(&store, draft.id, "queue-cleanup", &digest, 0, 0);
    const queue_id = entry.queueId;
    entry.state = .submitting;
    try store.save();
    store.history_fault = .after_cleanup;
    const request = try j.value(a, .{ .cmd = "draft.send", .account = store.state.account, .draftId = draft.id, .operationId = entry.operationId, .queueId = queue_id });
    const sent = try session.send(a, &store, request, draft, null, true);
    try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
    // Intermediate mail acceptance cannot perform unrelated archival while
    // the outer queue still has to persist its final state.
    try std.testing.expectEqual(@as(u64, 0), store.state.history.pages);
    try std.testing.expectEqual(@as(usize, 2), store.state.drafts.len);
    entry = try send_queue.find(&store, queue_id);
    entry.state = .applied;
    try store.save();
    try std.testing.expectEqualStrings("applied", j.text(try Session.queuedMutationReceipt(a, &store, entry.*), "state"));
    try std.testing.expectEqual(@as(usize, 0), store.state.drafts.len);
    try std.testing.expect(store.state.history.cleanup.len != 0);
    try store.save();
    store.close();
    store = try session.openStore(a, "personal@example.com", false);
    try std.testing.expectEqualStrings(older.bodyText, (try store.draft(older.id)).bodyText);
    try std.testing.expectEqualStrings(draft.bodyText, (try store.draft(draft.id)).bodyText);
    try std.testing.expectEqual(storage.SendState.applied, (try send_queue.find(&store, queue_id)).state);
    try std.testing.expectEqualStrings("applied", (try store.findOperation(a, "queue-cleanup")).?.outcome);
    try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
}

test "retained history: explicit recovery copy preserves a conflicted local snapshot without changing saved source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/conflicted-copy", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const local = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(local);
    try local.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer local.deinit();
    const other = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(other);
    try other.initInto(std.testing.io, std.testing.allocator, &env, options, null);
    defer other.deinit();
    const account = "personal@example.com";
    const original: t.Original = .{ .bodyText = "Local retained quote", .bodyHtml = "<p>Local retained quote</p>" };
    const initial = try local.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Initial saved text", .original = original } }));
    const old_id = j.text(initial, "id");
    _ = try other.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = old_id, .draft = .{ .to = "peer@example.test", .bodyText = "Other session saved text", .original = .{ .bodyText = "Other session quote" } } }));
    const fields: [5][]const u8 = .{ "unfinished recipient <", "", "", "Local unsaved subject", "Exact local dirty text" };
    const request = try j.value(a, .{ .cmd = "draft.recovery-save", .account = account, .draftId = "", .copyFromDraftId = old_id, .acknowledgementOnly = true, .draft = .{ .recoveryFields = fields, .includeOriginal = false, .original = original } });
    const copied = try local.dispatch(a, request);
    try std.testing.expectEqualStrings(old_id, j.text(copied, "copiedFrom"));
    const new_id = j.text(copied, "id");
    try std.testing.expect(!std.mem.eql(u8, old_id, new_id));
    const exact = try local.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = new_id }));
    for (fields, j.get(exact, "recoveryFields").?.array.items) |wanted, got| try std.testing.expectEqualStrings(wanted, got.string);
    try std.testing.expectEqualStrings(original.bodyText, j.text(j.get(exact, "original").?, "bodyText"));
    try std.testing.expect(!try j.boolean(exact, "includeOriginal", true));
    const unchanged = try other.dispatch(a, try j.value(a, .{ .cmd = "draft.read", .account = account, .draftId = old_id }));
    try std.testing.expectEqualStrings("Other session saved text", j.text(unchanged, "bodyText"));
    try std.testing.expectEqualStrings("Other session quote", j.text(j.get(unchanged, "original").?, "bodyText"));
    var crossed = try j.copyObject(a, request);
    try crossed.object.put(a, "account", .{ .string = "work@example.com" });
    try std.testing.expectError(error.DraftNotFound, local.dispatch(a, crossed));
    const queued = try other.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = old_id, .operationId = "protected-conflict-copy", .delaySeconds = 30 }));
    try std.testing.expectError(error.DraftQueued, local.dispatch(a, request));
    _ = try other.dispatch(a, try j.value(a, .{ .cmd = "queue.cancel", .account = account, .queueId = j.text(queued, "queueId") }));
    other.options.fixture_scenario = "unknown-send";
    _ = try other.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = old_id, .operationId = "unknown-conflict-source" }));
    try std.testing.expectError(error.UnknownOutcome, local.dispatch(a, request));
    try std.testing.expectEqual(@as(i64, 0), try j.integer(try local.dispatch(a, try j.value(a, .{ .cmd = "cache.stats", .account = account })), "fixtureSends", 0));
}

test "retained clone: active ownership and unfinished work cannot become independent drafts" {
    const Scenario = enum { ordinary, queued, submitting, queue_unknown, send_unknown, gmail_paused, gmail_unknown, gmail_taken_back, gmail_missing, calendar_pending };
    for ([_]Scenario{ .ordinary, .queued, .submitting, .queue_unknown, .send_unknown, .gmail_paused, .gmail_unknown, .gmail_taken_back, .gmail_missing, .calendar_pending }) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/clone-ownership", .{tmp.sub_path});
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", root);
        const session = try std.testing.allocator.create(Session);
        defer std.testing.allocator.destroy(session);
        try session.initInto(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root }, null);
        defer session.deinit();
        const account = "personal@example.com";
        var store = try session.openStore(a, account, false);
        defer store.close();
        const source = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .subject = "Protected source", .bodyText = "Exact source remains owned", .includeOriginal = false, .original = .{ .bodyText = "Retained quote" } }, null);
        const calendar = "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n";
        const digest = try operationDigest(a, source, account, if (scenario == .calendar_pending) calendar else null);
        switch (scenario) {
            .ordinary => {},
            .queued, .submitting, .queue_unknown => store.state.sendQueue = try a.dupe(storage.QueuedSend, &.{.{ .queueId = "owned-queue", .draftId = source.id, .operationId = "owned-send", .hash = try a.dupe(u8, &digest), .state = switch (scenario) {
                .queued => .queued,
                .submitting => .submitting,
                else => .unknown,
            }, .createdAtMs = 0, .dueAtMs = 0 }}),
            .send_unknown => store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "owned-send", .draftId = source.id, .hash = try a.dupe(u8, &digest) }}),
            .calendar_pending => {
                store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "owned-rsvp", .draftId = source.id, .hash = try a.dupe(u8, &digest), .outcome = "applied", .icalendar = calendar, .calendarSync = .{ .state = .unknown, .errorCode = "CalendarSyncPending", .canRetry = true } }});
                try std.testing.expect(try @import("operation_history.zig").immutableSource(&store, source.id));
            },
            .gmail_paused, .gmail_unknown, .gmail_taken_back, .gmail_missing => store.state.draftLinks = try a.dupe(@import("draft_link.zig").Link, &.{.{ .draftId = source.id, .phase = switch (scenario) {
                .gmail_unknown => .unknown,
                .gmail_missing => .missing,
                else => .linked,
            }, .paused = scenario == .gmail_paused or scenario == .gmail_unknown, .remoteDraftId = "remote-draft", .remoteMessageId = "remote-message", .attemptMessageId = "<owned-upload@example.test>", .uploadedDigest = try a.dupe(u8, &digest), .possiblySentElsewhere = scenario == .gmail_missing }}),
        }
        try store.save();
        const before = try j.encodeAlloc(a, store.state, .{});
        store.close();
        const expected: anyerror = switch (scenario) {
            .queued => error.DraftQueued,
            .submitting, .queue_unknown, .send_unknown => error.UnknownOutcome,
            .gmail_paused, .gmail_unknown => error.DraftPausedInGmail,
            else => error.CloneRequiresSettledSource,
        };
        try std.testing.expectError(expected, session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = source.id })));
        store = try session.openStore(a, account, false);
        try std.testing.expectEqualStrings(before, try j.encodeAlloc(a, store.state, .{}));
        try std.testing.expectEqualDeep(source, try store.draft(source.id));
        try std.testing.expectEqual(@as(u64, 0), store.state.fixtureCalls);
        try std.testing.expectEqual(@as(u64, 0), store.state.fixtureSends);
    }
}

test "retained clone: settled archived and active fallback sources copy exactly while deletion stays final" {
    for ([_]bool{ false, true }) |fallback| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/clone-settled", .{tmp.sub_path});
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", root);
        const session = try std.testing.allocator.create(Session);
        defer std.testing.allocator.destroy(session);
        try session.initInto(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root }, null);
        defer session.deinit();
        const account = "personal@example.com";
        var store = try session.openStore(a, account, false);
        defer store.close();
        const source = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Known accepted source", .includeOriginal = false, .original = .{ .bodyText = "Complete retained quote" }, .attachments = &.{.{ .id = "file", .filename = "note.txt", .mimeType = "text/plain", .size = 3, .data = "YWJj" }} }, null);
        if (fallback) store.history_fault = .before_publication;
        const sent = try session.send(a, &store, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = source.id, .operationId = "clone-source-accepted" }), source, null, false);
        try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
        try std.testing.expectEqual(@as(usize, if (fallback) 1 else 0), store.state.drafts.len);
        store.close();
        const copy = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = source.id }));
        const copy_id = j.text(copy, "id");
        try std.testing.expect(!std.mem.eql(u8, source.id, copy_id));
        store = try session.openStore(a, account, false);
        const restored = try store.draft(copy_id);
        var expected = source;
        expected.id = restored.id;
        try std.testing.expectEqualDeep(expected, restored);
        try std.testing.expectEqualDeep(source, try store.draft(source.id));
        try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
        try std.testing.expect(@import("draft_link.zig").find(store.state.draftLinks, copy_id) == null);
        store.close();
        try std.testing.expectError(error.DraftNotFound, session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = "work@example.com", .draftId = source.id })));
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "history.delete-source", .account = account, .draftId = source.id, .confirm = true }));
        try std.testing.expectError(error.ArchivedSourceDeleted, session.dispatch(a, try j.value(a, .{ .cmd = "draft.clone", .account = account, .draftId = source.id })));
        store = try session.openStore(a, account, false);
        try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
        try std.testing.expectEqualStrings(copy_id, store.state.drafts[0].id);
        try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
        try std.testing.expectEqualStrings("applied", (try store.findOperation(a, "clone-source-accepted")).?.outcome);
    }
}

test "retained recovery: local copies inherit Gmail warnings and require a fresh send acknowledgement" {
    const Case = struct { missing: bool = false, forked: bool = false };
    for ([_]Case{ .{}, .{ .missing = true }, .{ .forked = true } }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/recovery-gmail-warning", .{tmp.sub_path});
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", root);
        const session = try std.testing.allocator.create(Session);
        defer std.testing.allocator.destroy(session);
        try session.initInto(std.testing.io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = root }, null);
        defer session.deinit();
        const account = "personal@example.com";
        const created = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Uploaded local source", .includeOriginal = false, .original = .{ .bodyText = "Complete protected original" } } }));
        const source_id = j.text(created, "id");
        const info = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.gmail-info", .account = account, .draftId = source_id }));
        const uploaded = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.gmail-save", .account = account, .draftId = source_id, .expectedVersion = 0, .expectedDigest = j.text(info, "contentDigest") }));
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.gmail-take-back", .account = account, .draftId = source_id, .expectedVersion = try j.integer(j.get(uploaded, "link").?, "version", 0) }));
        var store = try session.openStore(a, account, false);
        defer store.close();
        const source = try store.draft(source_id);
        const digest = try operationDigest(a, source, account, null);
        const links = @import("draft_link.zig");
        const original_link = &store.state.draftLinks[links.find(store.state.draftLinks, source_id).?];
        if (case.missing) {
            original_link.phase = .missing;
            original_link.possiblySentElsewhere = true;
        }
        try original_link.acknowledgeSend(a, &digest);
        try store.save();
        if (case.forked) {
            const sent = try session.send(a, &store, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = source_id, .operationId = "source-was-sent" }), source, null, false);
            try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
            try std.testing.expectEqual(@as(usize, 0), store.state.drafts.len);
        }
        const history = @import("operation_history.zig");
        const source_link = (try history.gmailLink(&store, a, source_id)).?;
        const provider_before = try a.dupe(u8, (try store.readDocument(a, "fixture-gmail-drafts.json", 4 * 1024 * 1024)).?);
        store.close();
        const fields: [5][]const u8 = .{ "peer@example.test", "", "", "Independent local subject", "Exact unsaved note after the remote copy" };
        var request = try j.value(a, .{ .cmd = "draft.recovery-save", .account = account, .draftId = if (case.forked) source_id else "", .acknowledgementOnly = true, .draft = .{ .recoveryFields = fields, .includeOriginal = false } });
        if (case.forked) try request.object.put(a, "forkIfSettled", .{ .bool = true }) else try request.object.put(a, "copyFromDraftId", .{ .string = source_id });
        const copied = try session.dispatch(a, request);
        const copy_id = j.text(copied, "id");
        try std.testing.expectEqualStrings(source_id, j.text(copied, if (case.forked) "forkedFrom" else "copiedFrom"));
        try std.testing.expect(!std.mem.eql(u8, source_id, copy_id));
        const response_link = try j.decode(links.Link, a, j.get(copied, "gmailLink").?);
        var expected_link = source_link;
        expected_link.draftId = copy_id;
        expected_link.version = 1;
        expected_link.paused = false;
        expected_link.sendAcknowledgedDigest = "";
        expected_link.lastImportedMessageId = "";
        expected_link.lastImportedDraftId = "";
        try std.testing.expectEqualDeep(expected_link, response_link);
        store = try session.openStore(a, account, false);
        var recovered = try store.draft(copy_id);
        try std.testing.expectEqualDeep(@as([]const []const u8, &fields), recovered.recoveryFields.?);
        try std.testing.expectEqualDeep(source.original, recovered.original);
        try std.testing.expect(!recovered.includeOriginal);
        try std.testing.expectEqualStrings(j.text(copied, "contentDigest"), &(try links.contentDigest(a, recovered, account)));
        try std.testing.expectEqualDeep(source_link, (try history.gmailLink(&store, a, source_id)).?);
        try std.testing.expectEqualDeep(source, try store.draft(source_id));
        try std.testing.expect(!try history.immutableSource(&store, copy_id));
        try std.testing.expectEqual(@as(u64, if (case.forked) 1 else 0), store.state.fixtureSends);
        store.close();
        // Normal editor save resolves valid raw fields. It keeps the remote
        // warning while changing the exact content to be acknowledged.
        recovered.recoveryFields = null;
        recovered.to = &.{.{ .address = "peer@example.test" }};
        recovered.subject = fields[3];
        recovered.bodyText = fields[4];
        _ = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.update", .account = account, .draftId = copy_id, .draft = recovered }));
        try std.testing.expectError(error.GmailCopyUnchecked, session.dispatch(a, try j.value(a, .{ .cmd = "draft.queue", .account = account, .draftId = copy_id, .operationId = "unacknowledged-copy-queue", .delaySeconds = 0 })));
        try std.testing.expectError(error.GmailCopyUnchecked, session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = copy_id, .operationId = "copy-explicit-send" })));
        const current = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.gmail-info", .account = account, .draftId = copy_id }));
        const sent = try session.dispatch(a, try j.value(a, .{ .cmd = "draft.send", .account = account, .draftId = copy_id, .operationId = "copy-explicit-send", .acknowledgeGmailCopy = true, .gmailCopyDigest = j.text(current, "contentDigest") }));
        try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
        store = try session.openStore(a, account, false);
        try std.testing.expectEqual(@as(u64, if (case.forked) 2 else 1), store.state.fixtureSends);
        try std.testing.expectEqualStrings(provider_before, (try store.readDocument(a, "fixture-gmail-drafts.json", 4 * 1024 * 1024)).?);
        try std.testing.expectEqualDeep(source_link, (try history.gmailLink(&store, a, source_id)).?);
        try std.testing.expectEqualDeep(source, try store.draft(source_id));
    }
}
