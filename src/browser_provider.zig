//! Browser implementation of the existing terminal Client protocol.
//! This module owns provider/cache/session storage, never keyboard or UI state.
const std = @import("std");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const live = @import("browser_live.zig");
const cache_module = @import("browser_cache.zig");
const mail_actions_module = @import("browser_mail_actions.zig");
const codec = @import("terminal/draft_codec.zig");
const draft_summary = @import("terminal/draft_summary.zig");
const draft_storage = @import("browser_drafts.zig");
const conversation = @import("terminal/conversation_draft.zig");
const conversation_source = @import("terminal/conversation_source.zig");
const gmail_decode = @import("terminal/gmail_decode.zig");
const mail_value = @import("terminal/mail_response_value.zig");
const bounded = @import("bounded.zig");
const Allocator = std.mem.Allocator;
const Value = j.Value;
pub const heap_bytes: usize = 64 * 1024 * 1024;
pub const linear_memory_bytes: usize = 96 * 1024 * 1024;
const draft_limit = draft_storage.per_actor;
const draft_bytes_limit = draft_storage.total_bytes;
const demo_accounts = [_][]const u8{ "alex@example.test", "studio@example.test", "team@example.test" };
const DraftSlot = struct { raw: ?[]const u8 = null, id: bounded.Text(128) = .{}, retired: bool = false };
const View = struct {
    label: bounded.Text(256) = .{},
    query: bounded.Text(4096) = .{},
    ids: [30]bounded.Text(128) = @splat(.{}),
    count: usize = 0,
    valid: bool = false,
    complete: bool = false,
};
const Operation = struct {
    account_index: usize,
    id: bounded.Text(256) = .{},
    draft_id: bounded.Text(128) = .{},
    hash: [32]u8,
    outcome: draft_storage.Outcome = .unknown,
    phase: draft_storage.Phase = .submitted,
    error_code: bounded.Text(64) = .{},
    acknowledged: bool = false,
    awaiting_receipt: bool = true,
    // Only set by the transport's exact send boundary result. This in-memory
    // proof keeps a refused POST editable if its receipt cannot be persisted.
    proven_no_post: bool = false,
};

pub const UnknownTarget = struct { account_index: usize, draft_id: []const u8, operation_id: []const u8 };

pub const Provider = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    cache: cache_module.Store,
    mail_actions: mail_actions_module.Store,
    live_count: usize = 0,
    live_sessions: [3]live.Session = undefined,
    fixtures_ready: bool = false,
    drafts: [3][draft_limit]DraftSlot = @splat(@splat(.{})),
    draft_bytes: usize = 0,
    draft_store: ?draft_storage.Storage = null,
    draft_revisions: [3]u32 = @splat(0),
    sequence: u64 = 0,
    operations: [64]Operation = undefined,
    operation_count: usize = 0,
    last_send_status: u32 = 0,
    local_send_rejection: bool = false,
    acknowledgement_operation: ?usize = null,
    views: [3][8]View = @splat(@splat(.{})),
    view_next: [3]usize = @splat(0),
    verified_aliases: [3]?[]const []const u8 = @splat(null),

    pub fn init(a: Allocator) Provider {
        return .{ .allocator = a, .arena = .init(a), .cache = cache_module.Store.init(a), .mail_actions = mail_actions_module.Store.init(a) };
    }
    pub fn deinit(self: *Provider) void {
        self.mail_actions.deinit();
        for (&self.drafts) |*draft_slots| for (draft_slots) |slot| if (slot.raw) |raw| self.allocator.free(raw);
        self.cache.deinit();
        self.arena.deinit();
    }
    pub fn client(self: *Provider) t.Client {
        return .{ .ctx = self, .callFn = call, .cachedFn = callCached, .sendReceiptFn = sendReceipt };
    }
    pub fn accountCount(self: *const Provider) usize {
        return self.live_count;
    }
    pub fn accountAddress(self: *const Provider, index: usize) []const u8 {
        return if (index < self.live_count) self.live_sessions[index].account else "";
    }
    pub fn draftCount(self: *const Provider) usize {
        var count: usize = 0;
        for (self.drafts) |draft_slots| for (draft_slots) |slot| if (slot.raw != null and !slot.retired) {
            count += 1;
        };
        return count;
    }
    pub fn canSend(self: *const Provider, index: usize) bool {
        return index < self.live_count and self.live_sessions[index].can_send;
    }
    pub fn canModify(self: *const Provider, index: usize) bool {
        return index < self.live_count and self.live_sessions[index].can_modify;
    }
    pub fn canContacts(self: *const Provider, index: usize) bool {
        return self.live_count == 0 or (index < self.live_count and self.live_sessions[index].can_contacts);
    }
    pub fn sessionNonce(self: *const Provider, index: usize) []const u8 {
        return if (index < self.live_count) self.live_sessions[index].nonce else "00000000-0000-4000-8000-000000000000";
    }
    pub fn sendStatus(self: *const Provider) u32 {
        return self.last_send_status;
    }
    pub fn pendingUnknown(self: *const Provider) ?UnknownTarget {
        var index = self.operation_count;
        while (index > 0) {
            index -= 1;
            const operation = &self.operations[index];
            if (operation.outcome == .unknown and !operation.acknowledged) return .{ .account_index = operation.account_index, .draft_id = operation.draft_id.slice(), .operation_id = operation.id.slice() };
        }
        return null;
    }
    pub fn pendingUnknownFor(self: *const Provider, account_index: usize, draft_id: ?[]const u8) ?UnknownTarget {
        if (account_index >= self.live_count) return null;
        var index = self.operation_count;
        while (index > 0) {
            index -= 1;
            const operation = &self.operations[index];
            if (operation.account_index != account_index or operation.outcome != .unknown or operation.acknowledged) continue;
            if (draft_id) |id| if (!std.mem.eql(u8, id, operation.draft_id.slice())) continue;
            return .{ .account_index = account_index, .draft_id = operation.draft_id.slice(), .operation_id = operation.id.slice() };
        }
        return null;
    }
    pub fn unknownCount(self: *const Provider) usize {
        var count: usize = 0;
        for (self.operations[0..self.operation_count]) |operation| if (operation.outcome == .unknown and !operation.acknowledged) {
            count += 1;
        };
        return count;
    }
    pub fn cacheSnapshot(self: *Provider, index: usize, out: []u8) ![]u8 {
        if (index >= self.live_count) return error.InvalidBrowserCache;
        return self.cache.snapshot(index, out);
    }
    pub fn cacheRevision(self: *const Provider, index: usize) u32 {
        return if (index < self.live_count) self.cache.revision(index) else 0;
    }
    pub fn cacheClear(self: *Provider, index: usize) !void {
        if (index >= self.live_count) return error.InvalidBrowserCache;
        self.cache.clear(index);
        self.views[index] = @splat(.{});
    }
    pub fn restrictContacts(self: *Provider, index: usize, allowed: bool) !void {
        if (index >= self.live_count) return error.InvalidBrowserCache;
        if (allowed or !self.live_sessions[index].can_contacts) return;
        self.live_sessions[index].can_contacts = false;
        // A narrowed grant cannot expose previously cached People records.
        self.cache.dropContacts(index) catch self.cache.clear(index);
    }
    pub fn acknowledgeUnknown(self: *Provider, index: usize, draft_id: []const u8) !void {
        if (index >= self.live_count or draft_id.len == 0) return error.DraftNotFound;
        var found = false;
        const previous_operations = self.operations;
        for (self.operations[0..self.operation_count]) |*operation| {
            if (operation.account_index == index and std.mem.eql(u8, operation.draft_id.slice(), draft_id) and operation.outcome == .unknown) {
                operation.acknowledged = true;
                operation.awaiting_receipt = false;
                found = true;
            }
        }
        if (!found) return error.OperationNotFound;
        self.persistDrafts(index) catch |err| {
            self.operations = previous_operations;
            return err;
        };
        self.last_send_status = if (self.pendingUnknown() != null) 2 else 0;
    }
    pub fn connect(self: *Provider, bytes: []const u8, pending_cache: []const u8) !usize {
        if (self.live_count == 3) return error.TooManyAccounts;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        // Profile validation happens before any uploaded snapshot is consumed.
        var session = try live.connect(scratch.allocator(), bytes);
        session.temporary_allocator = self.allocator;
        for (self.live_sessions[0..self.live_count]) |previous| if (std.ascii.eqlIgnoreCase(previous.account, session.account)) return error.DuplicateAccount;
        const a = self.arena.allocator();
        session.account = try a.dupe(u8, session.account);
        session.nonce = try a.dupe(u8, session.nonce);
        session.client_id = try a.dupe(u8, session.client_id);
        session.grant_id = try a.dupe(u8, session.grant_id);
        const index = self.live_count;
        if (index == 0) {
            for (0..3) |actor_index| self.cache.clear(actor_index);
            // The showcase cannot leave drafts attached to a real actor slot.
            for (&self.drafts) |*draft_slots| for (draft_slots) |*slot| if (slot.raw) |raw| {
                self.allocator.free(raw);
                slot.raw = null;
            };
            self.draft_bytes = 0;
        }
        try self.cache.bind(index, .{ .account = session.account, .clientId = session.client_id, .grantId = session.grant_id });
        if (pending_cache.len > 0) self.cache.restore(index, pending_cache, session.can_contacts) catch self.cache.clear(index);
        self.live_sessions[index] = session;
        self.live_count += 1;
        return index;
    }
    fn call(ctx: *anyopaque, a: Allocator, raw: []const u8) ![]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return self.execute(a, raw, false);
    }
    fn callCached(ctx: *anyopaque, a: Allocator, raw: []const u8) ![]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return self.execute(a, raw, true);
    }
    fn sendReceipt(ctx: *anyopaque, raw: []const u8, accepted: bool) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        // Receipt consumption must remain possible after a UI allocation
        // failure. Its identity envelope is small and needs no heap storage.
        var buffer: [16 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const request = if (raw.len <= 2048) std.json.parseFromSliceLeaky(Value, fixed.allocator(), raw, .{ .allocate = .alloc_always }) catch null else null;
        if (request) |value| {
            for (self.operations[0..self.operation_count], 0..) |*operation, record_index| {
                if (!operation.awaiting_receipt or !std.mem.eql(u8, j.text(value, "cmd"), "draft.send") or !std.mem.eql(u8, operation.id.slice(), j.text(value, "operationId")) or !std.mem.eql(u8, operation.draft_id.slice(), j.text(value, "draftId")) or !std.mem.eql(u8, self.address(operation.account_index), j.text(value, "account"))) continue;
                operation.awaiting_receipt = false;
                if (!accepted) self.markReceiptUnknown(record_index) else {
                    self.last_send_status = switch (operation.outcome) {
                        .applied => 1,
                        .rejected => 3,
                        .unknown => 2,
                    };
                    if (operation.outcome == .applied) for (&self.drafts[operation.account_index]) |*slot| {
                        if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), operation.draft_id.slice())) slot.retired = true;
                    };
                    self.persistDrafts(operation.account_index) catch {
                        // Google may already have applied the send. A failed
                        // deletion/receipt commit keeps the recovery protected.
                        self.markReceiptUnknown(record_index);
                    };
                }
                return;
            }
            // A well-formed acknowledgment for another operation cannot
            // change this actor's outstanding or already consumed receipt.
            return;
        }
        // No heap allocation is required even when a consumer cannot preserve
        // its request. Unidentifiable failure keeps outstanding sends fenced.
        if (!accepted) for (self.operations[0..self.operation_count], 0..) |operation, record_index| if (operation.awaiting_receipt) self.markReceiptUnknown(record_index);
    }
    fn markReceiptUnknown(self: *Provider, index: usize) void {
        const operation = &self.operations[index];
        if (operation.proven_no_post) {
            operation.awaiting_receipt = false;
            operation.outcome = .rejected;
            self.last_send_status = 3;
            // A stale tab can fail CAS here; preserve its editor and the newer
            // disk row while retaining the proof that this POST never began.
            self.persistDrafts(operation.account_index) catch {};
            return;
        }
        operation.outcome = .unknown;
        operation.phase = .submitted;
        operation.acknowledged = false;
        operation.error_code.set("AcknowledgementUnavailable") catch {};
        self.last_send_status = 2;
        // A failed replay must restore the protected recovery draft too.
        for (&self.drafts[operation.account_index]) |*slot| if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), operation.draft_id.slice())) {
            slot.retired = false;
        };
        self.persistDrafts(operation.account_index) catch {};
    }
    fn execute(self: *Provider, out: Allocator, raw: []const u8, cached: bool) ![]const u8 {
        self.local_send_rejection = false;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        if (raw.len > t.Limits.request_bytes) return error.RequestTooLarge;
        const request = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always, .max_value_len = t.Limits.request_bytes });
        if (request != .object) return error.InvalidRequest;
        const account = j.text(request, "account");
        const id = j.get(request, "id") orelse .null;
        const cache_only = cached or try j.boolean(request, "cacheOnly", false);
        self.acknowledgement_operation = null;
        const data = self.dispatch(a, request, cached) catch |err| {
            if (self.local_send_rejection) return error.SendNotStarted;
            const failure = if (!cache_only and std.mem.eql(u8, j.text(request, "cmd"), "draft.send") and self.failedAcknowledgement()) error.UnknownOutcome else err;
            return std.json.Stringify.valueAlloc(out, .{ .version = @as(u8, 1), .id = id, .ok = false, .account = account, .@"error" = .{ .code = @errorName(failure), .message = @errorName(failure) } }, .{}) catch |encoding_error| {
                if (failure == error.UnknownOutcome) return error.UnknownOutcome;
                return encoding_error;
            };
        };
        return std.json.Stringify.valueAlloc(out, .{ .version = @as(u8, 1), .id = id, .ok = true, .account = account, .data = data }, .{}) catch |err| {
            // Failure to encode a post-write acknowledgement cannot claim rejection.
            if (!cache_only and std.mem.eql(u8, j.text(request, "cmd"), "draft.send")) {
                if (self.local_send_rejection) return error.SendNotStarted;
                _ = self.failedAcknowledgement();
                return error.UnknownOutcome;
            }
            return err;
        };
    }
    fn failedAcknowledgement(self: *Provider) bool {
        const index = self.acknowledgement_operation orelse return false;
        self.markReceiptUnknown(index);
        return true;
    }
    fn actor(self: *const Provider, account: []const u8) !usize {
        const count = if (self.live_count == 0) @as(usize, 3) else self.live_count;
        for (0..count) |index| if (std.mem.eql(u8, account, self.address(index))) return index;
        return error.UnknownAccount;
    }
    fn address(self: *const Provider, index: usize) []const u8 {
        return if (self.live_count == 0) demo_accounts[index] else self.live_sessions[index].account;
    }
    fn capabilities(self: *const Provider, index: usize) []const []const u8 {
        if (self.live_count == 0) return &.{ "mail-read", "contacts-read" };
        return self.live_sessions[index].capabilities();
    }
    fn dispatch(self: *Provider, a: Allocator, request: Value, cached_call: bool) !Value {
        const cmd = try j.required(request, "cmd");
        if (self.live_count == 0) try self.ensureFixtures();
        if (std.mem.eql(u8, cmd, "accounts.list")) {
            var accounts: std.ArrayList(Value) = .empty;
            for (0..if (self.live_count == 0) @as(usize, 3) else self.live_count) |index| try accounts.append(a, try j.value(a, .{ .address = self.address(index), .enabled = true, .capabilities = self.capabilities(index) }));
            return j.value(a, .{ .accounts = accounts.items });
        }
        const index = try self.actor(try j.required(request, "account"));
        const explicitly_cached = cached_call or try j.boolean(request, "cacheOnly", false);
        if (explicitly_cached and !@import("terminal/client_contract.zig").cachedCommand(cmd)) return error.CacheUnsupported;
        const cached = explicitly_cached or self.live_count == 0;
        if (std.mem.eql(u8, cmd, "accounts.identities")) return j.value(a, .{ .identities = [_]struct { address: []const u8, name: []const u8 = "", signature: []const u8 = "" }{.{ .address = self.address(index) }}, .cached = true });
        if (std.mem.eql(u8, cmd, "labels.list")) {
            if (cached and self.live_count > 0 and !self.mail_actions.labelsReady(index)) return error.CacheMiss;
            return self.mail_actions.listLabels(a, index, if (cached) null else &self.live_sessions[index]);
        }
        if (std.mem.eql(u8, cmd, "mail.triage-scope") or std.mem.eql(u8, cmd, "mail.labels")) {
            if (cached) return error.CacheUnsupported;
            return self.live_sessions[index].dispatch(a, cmd, request);
        }
        if (std.mem.eql(u8, cmd, "mail.label-state")) {
            if (cached) return error.CacheUnsupported;
            return self.mail_actions.labelState(a, index, &self.live_sessions[index], request);
        }
        if (std.mem.eql(u8, cmd, "operation.read")) return self.mail_actions.operationRead(a, index, try j.required(request, "operationId"));
        if (std.mem.eql(u8, cmd, "mail.batch") or std.mem.eql(u8, cmd, "mail.undo") or std.mem.eql(u8, cmd, "mail.archive") or std.mem.eql(u8, cmd, "mail.trash") or std.mem.eql(u8, cmd, "mail.restore") or std.mem.eql(u8, cmd, "mail.mark") or std.mem.eql(u8, cmd, "mail.modify-labels")) {
            if (cached or !self.canModify(index)) return error.PermissionDenied;
            const previous = self.mail_actions.epoch(index);
            defer {
                if (previous != self.mail_actions.epoch(index)) self.views[index] = @splat(.{});
            }
            if (std.mem.eql(u8, cmd, "mail.undo")) return self.mail_actions.undo(a, index, &self.live_sessions[index], &self.cache, request);
            var batch = request;
            if (!std.mem.eql(u8, cmd, "mail.batch")) {
                batch = try j.copyObject(a, request);
                try batch.object.put(a, "messageIds", try j.value(a, [_][]const u8{try j.required(request, "messageId")}));
                try batch.object.put(a, "action", .{ .string = if (std.mem.eql(u8, cmd, "mail.modify-labels")) "mark" else cmd[5..] });
            }
            const batch_receipt = try self.mail_actions.batch(a, index, &self.live_sessions[index], &self.cache, batch);
            if (std.mem.eql(u8, cmd, "mail.batch")) return batch_receipt;
            const token = j.text(batch_receipt, "undoToken");
            try self.mail_actions.singleResult(index, token);
            return self.directMailResult(a, index, cmd, try j.required(request, "messageId")) catch {
                // The direct native protocol returns a message (or exact
                // memberships), not a batch envelope. Losing that projection
                // after a write must never make the target replayable.
                self.mail_actions.loseSingleResult(index, token);
                return error.UnknownOutcome;
            };
        }
        if (std.mem.eql(u8, cmd, "labels.create") or std.mem.eql(u8, cmd, "labels.rename") or std.mem.eql(u8, cmd, "labels.delete") or std.mem.eql(u8, cmd, "labels.color")) {
            if (cached or !self.canModify(index)) return error.PermissionDenied;
            const previous = self.mail_actions.epoch(index);
            defer {
                if (previous != self.mail_actions.epoch(index)) self.views[index] = @splat(.{});
            }
            return self.mail_actions.manageLabel(a, index, &self.live_sessions[index], &self.cache, request);
        }
        if (std.mem.eql(u8, cmd, "cache.refresh-status")) return j.value(a, .{ .refreshInProgress = false });
        if (std.mem.eql(u8, cmd, "cache.activity")) return j.value(a, .{ .inboxArrivalCount = @as(usize, 0), .generation = self.cache.revision(index), .lastSyncAt = self.cache.updatedAt(index) });
        if (std.mem.eql(u8, cmd, "cache.clear")) {
            self.cache.clear(index);
            self.views[index] = @splat(.{});
            return j.value(a, .{ .cleared = true, .draftsPreserved = true, .operationsPreserved = true });
        }
        if (std.mem.eql(u8, cmd, "cache.stats")) return j.value(a, .{ .metadataEntries = self.cache.retained(index).len, .metadataLimit = @as(usize, 300), .diskBytes = @as(usize, 0), .diskLimitBytes = cache_module.total_limit, .bodyLimitBytes = t.Limits.body_bytes, .runtimeReservationBytes = heap_bytes, .terminalHeapLimitBytes = heap_bytes, .browserLinearMemoryBytes = linear_memory_bytes, .mailScratch = @import("mail_scratch.zig").snapshot(), .lastSyncAt = self.cache.updatedAt(index), .generation = self.cache.revision(index), .refreshInProgress = false });
        if (std.mem.eql(u8, cmd, "mail.recipients")) {
            var known = @import("terminal/recipient_cache.zig").Builder.init(a, self.address(index));
            defer known.deinit();
            for (self.cache.retained(index)) |message| try known.mail(message);
            if (self.canContacts(index)) for (try self.cache.contacts(index, a)) |contact| try known.contact(try j.decode(t.Contact, a, contact));
            return j.value(a, .{ .recipients = try known.result(), .cached = true, .contactsIncluded = self.canContacts(index) });
        }
        if (std.mem.eql(u8, cmd, "mail.list") or std.mem.eql(u8, cmd, "mail.search") or std.mem.eql(u8, cmd, "mail.refresh")) {
            if (cached) return self.cachedList(a, index, request);
            if (j.text(request, "cursor").len > 0) return error.BrowserPaginationUnavailable;
            const result = try self.live_sessions[index].list(a, j.text(request, "label"), j.text(request, "query"));
            const messages = j.get(result, "messages") orelse return error.InvalidProviderResponse;
            if (messages != .array or messages.array.items.len > 30) return error.InvalidPage;
            var complete = j.text(result, "nextCursor").len == 0 and !try j.boolean(result, "partial", false);
            for (messages.array.items) |message| complete = complete and !try j.boolean(message, "metadataPartial", false) and try j.boolean(message, "labelsVerified", true);
            self.cache.replaceView(index, messages.array.items, std.Io.Timestamp.now(live.io, .real).toMilliseconds(), j.text(request, "label"), j.text(request, "query").len == 0 and complete) catch |err| {
                if (err != error.BrowserCacheQuotaExceeded) return err;
                for (messages.array.items) |*message| message.* = try cacheQuotaWarning(a, message.*);
                // The caller can display this response even though the atomic
                // cache operation kept the previous snapshot and timestamp.
                return j.value(a, .{ .messages = messages.array.items, .cached = false, .partial = true, .cacheWriteFailed = true, .decodeWarning = "BrowserCacheQuotaExceeded", .cacheReady = self.cache.valid(index), .lastSyncAt = self.cache.updatedAt(index), .refreshCompleted = true, .refreshInProgress = false });
            };
            try self.recordView(index, request, messages.array.items, complete);
            // A bounded head is honest about its scope; it never invents a cursor.
            if (std.mem.eql(u8, cmd, "mail.refresh")) return j.value(a, .{ .cacheReady = true, .lastSyncAt = self.cache.updatedAt(index), .refreshCompleted = true, .refreshInProgress = false });
            return j.value(a, .{ .messages = messages.array.items, .cached = false, .partial = true, .cacheReady = true, .lastSyncAt = self.cache.updatedAt(index) });
        }
        if (std.mem.eql(u8, cmd, "mail.read")) return mail_value.borrowed(a, try self.read(a, index, try j.required(request, "messageId"), cached));
        if (std.mem.eql(u8, cmd, "mail.thread")) {
            const thread_id = try j.required(request, "threadId");
            if (!cached) {
                const session = &self.live_sessions[index];
                const result = try @import("terminal/gmail.zig").dispatchAuthorized(live.io, a, session.account, session.capabilities(), session.transport(), cmd, request);
                const messages = j.get(result, "messages") orelse return error.InvalidProviderResponse;
                if (messages != .array or messages.array.items.len > 100) return error.ThreadTooLarge;
                std.mem.sort(Value, messages.array.items, {}, struct {
                    fn less(_: void, left: Value, right: Value) bool {
                        const l = j.integer(left, "receivedAt", 0) catch 0;
                        const r = j.integer(right, "receivedAt", 0) catch 0;
                        return l < r or (l == r and std.mem.lessThan(u8, j.text(left, "id"), j.text(right, "id")));
                    }
                }.less);
                const selected = messages.array.items[messages.array.items.len -| 30..];
                const omitted = messages.array.items.len - selected.len;
                var cache_partial = false;
                for (selected) |*value| {
                    const decoded = try j.decode(t.Message, a, value.*);
                    const admitted = try self.cacheRead(index, decoded);
                    if (!std.mem.eql(u8, admitted.decodeWarning, decoded.decodeWarning) or admitted.metadataPartial != decoded.metadataPartial or admitted.bodyCached != decoded.bodyCached) {
                        // Annotate only the small map. Re-encoding the complete
                        // body here would duplicate an already bounded result.
                        var annotated = try j.copyObject(a, value.*);
                        try annotated.object.put(a, "decodeWarning", .{ .string = admitted.decodeWarning });
                        try annotated.object.put(a, "metadataPartial", .{ .bool = admitted.metadataPartial });
                        try annotated.object.put(a, "bodyCached", .{ .bool = admitted.bodyCached });
                        value.* = annotated;
                        cache_partial = true;
                    }
                }
                if (cache_partial or omitted > 0) {
                    var annotated = try j.copyObject(a, result);
                    try annotated.object.put(a, "partial", .{ .bool = true });
                    if (omitted > 0) {
                        var window: Value = .{ .array = .init(a) };
                        try window.array.appendSlice(selected);
                        try annotated.object.put(a, "messages", window);
                        try annotated.object.put(a, "omittedMessages", .{ .integer = (try j.integer(result, "omittedMessages", 0)) + @as(i64, @intCast(omitted)) });
                    }
                    return annotated;
                }
                return result;
            }
            var newest: [30]t.Message = undefined;
            var count: usize = 0;
            var total: usize = 0;
            for (self.cache.retained(index)) |message| if (std.mem.eql(u8, message.threadId, thread_id)) {
                total += 1;
                if (count < newest.len) {
                    newest[count] = message;
                    count += 1;
                } else {
                    var oldest: usize = 0;
                    for (newest[1..], 1..) |candidate, row| if (olderMessage({}, candidate, newest[oldest])) {
                        oldest = row;
                    };
                    if (olderMessage({}, newest[oldest], message)) newest[oldest] = message;
                }
            };
            if (count == 0) return error.CacheMiss;
            std.mem.sort(t.Message, newest[0..count], {}, olderMessage);
            var remaining: usize = t.Limits.thread_bytes;
            const messages = try a.alloc(t.Message, count);
            for (newest[0..count], messages) |message, *out| {
                const candidate = if (message.bodyCached or message.bodyCacheError.len > 0) message else try gmail_decode.unavailablePlaceholder(message, a, "BodyNotCached");
                out.* = try gmail_decode.retainThreadMessage(candidate, a, &remaining);
            }
            return mail_value.borrowed(a, .{ .messages = messages, .cached = true, .partial = true, .omittedMessages = total - count });
        }
        if (std.mem.eql(u8, cmd, "contacts.list") or std.mem.eql(u8, cmd, "contacts.search")) {
            if (!self.canContacts(index)) return error.PermissionDenied;
            if (cached) {
                const contacts = try self.cache.contacts(index, a);
                var matches: std.ArrayList(Value) = .empty;
                const query = j.text(request, "query");
                for (contacts) |contact| {
                    var match = query.len == 0 or contains(j.text(contact, "name"), query);
                    if (j.get(contact, "emails")) |emails| if (emails == .array) for (emails.array.items) |email| {
                        match = match or contains(j.text(email, "address"), query);
                    };
                    if (match) try matches.append(a, contact);
                }
                const warnings = self.cache.contactWarnings(index);
                return j.value(a, .{ .contacts = matches.items, .cached = true, .cacheReady = self.cache.contactsLoaded(index), .partial = warnings.any(), .contactWarnings = warnings });
            }
            const result = try self.live_sessions[index].contacts(a, j.text(request, "query"));
            const contacts = j.get(result, "contacts") orelse return error.InvalidProviderResponse;
            if (contacts != .array) return error.InvalidProviderResponse;
            // Remote searches are temporary views; they cannot replace the full cached head.
            if (j.text(request, "query").len == 0) try self.cache.replaceContactPage(index, contacts.array.items, if (j.get(result, "contactWarnings")) |warnings| try j.decode(t.ContactReadWarnings, a, warnings) else .{});
            return result;
        }
        if (std.mem.eql(u8, cmd, "draft.list")) {
            var drafts: std.ArrayList(t.Draft) = .empty;
            for (self.drafts[index]) |slot| if (!slot.retired) {
                if (slot.raw) |raw| {
                    const stored = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_if_needed });
                    try drafts.append(a, try draft_summary.fromValue(a, stored));
                }
            };
            return j.value(a, .{ .drafts = drafts.items });
        }
        if (std.mem.eql(u8, cmd, "draft.read")) {
            const draft_id = try j.required(request, "draftId");
            if ((try self.draftSlot(a, index, draft_id)).retired) return error.DraftAlreadySent;
            return self.draftValue(a, index, draft_id);
        }
        if (std.mem.eql(u8, cmd, "draft.discard")) {
            const draft_id = try j.required(request, "draftId");
            try self.requireEditableDraft(index, draft_id);
            const slot = try self.draftSlot(a, index, draft_id);
            const previous = slot.*;
            slot.* = .{};
            self.persistDrafts(index) catch |err| {
                slot.* = previous;
                return err;
            };
            self.draft_bytes -= previous.raw.?.len;
            self.allocator.free(previous.raw.?);
            return j.value(a, .{ .discarded = true });
        }
        if (std.mem.eql(u8, cmd, "operation.list")) {
            var operations: std.ArrayList(Value) = .empty;
            for (self.operations[0..self.operation_count]) |operation| if (operation.account_index == index) try operations.append(a, try self.receipt(a, operation));
            return j.value(a, .{ .operations = operations.items });
        }
        if (std.mem.eql(u8, cmd, "queue.list")) return j.value(a, .{ .queue = [_]Value{} });
        if (std.mem.eql(u8, cmd, "draft.preview")) {
            const draft = try codec.decodeDraftWithScratch(a, self.allocator, j.get(request, "draft") orelse try self.draftValue(a, index, try j.required(request, "draftId")));
            try codec.validateDraft(draft, false);
            const prepared = try @import("terminal/markdown_mail.zig").prepare(a, draft);
            return j.value(a, .{ .bodyFormat = draft.bodyFormat, .bodyText = if (draft.recoveryFields) |fields| fields[4] else draft.bodyText, .plainText = prepared.plain, .bodyHtml = prepared.html });
        }
        if (std.mem.eql(u8, cmd, "draft.create") or std.mem.eql(u8, cmd, "draft.update") or std.mem.eql(u8, cmd, "draft.recovery-save")) {
            if (!self.canSend(index)) return error.PermissionDenied;
            const acknowledgement_only = try j.boolean(request, "acknowledgementOnly", false);
            const input = j.get(request, "draft") orelse return error.MissingField;
            var draft = if (std.mem.eql(u8, cmd, "draft.recovery-save"))
                try codec.decodeRecoveryDraftWithScratch(a, self.allocator, input)
            else
                try codec.decodeDraftWithScratch(a, self.allocator, input);
            const existing = j.text(request, "draftId");
            if (existing.len > 0) {
                const previous = try codec.decodeDraftWithScratch(a, self.allocator, try self.draftValue(a, index, existing));
                if (j.get(input, "bodyFormat") == null) draft.bodyFormat = previous.bodyFormat;
                if (j.get(input, "original") == null) draft.original = previous.original;
                if (j.get(input, "omittedAttachments") == null) draft.omittedAttachments = previous.omittedAttachments;
            }
            return draft_summary.savedResponse(a, try self.putDraft(a, index, draft, if (existing.len > 0) existing else null), acknowledgement_only);
        }
        if (std.mem.eql(u8, cmd, "mail.reply") or std.mem.eql(u8, cmd, "mail.forward")) {
            if (!self.canSend(index)) return error.PermissionDenied;
            const session = &self.live_sessions[index];
            const forward = std.mem.eql(u8, cmd, "mail.forward");
            const format = try codec.requestBodyFormat(request);
            const id = try j.required(request, "messageId");
            const omit = try j.boolean(request, "omitAttachments", false);
            if (forward and try j.boolean(request, "original", false)) {
                if (omit) return error.InvalidForwardOptions;
                const draft = capture: {
                    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
                    defer scratch.deinit();
                    break :capture try conversation_source.forwardRaw(a, try session.raw(scratch.allocator(), id), format);
                };
                return j.value(a, try self.putDraft(a, index, draft, null));
            }
            const preserve = try j.boolean(request, "preserveFormatting", false);
            if (forward and omit and preserve) return error.InvalidForwardOptions;
            // Persisted reader snapshots deliberately strip attachment bytes
            // and some MIME metadata. Capture every forward and formatted
            // reply from a fresh FULL response, without weakening that cache.
            const message = if (forward or preserve) try session.read(a, id) else try self.read(a, index, id, false);
            var attachments: ConversationAttachments = .{ .session = session, .allocator = self.allocator };
            const draft = if (forward)
                try conversation_source.forward(a, message, .{ .format = format, .preserve_formatting = preserve, .omit_attachments = omit, .body_text = if (preserve) null else try conversation.plainText(a, message), .temporary_allocator = self.allocator }, attachments.source())
            else
                try conversation.reply(a, message, .{ .account = self.address(index), .aliases = try self.replyAliases(a, index), .all = try j.boolean(request, "all", false), .format = format, .original = if (preserve) try conversation_source.captureOriginal(a, message, attachments.source()) else null });
            if (preserve and !forward) try conversation_source.validateFormatting(self.allocator, draft);
            return j.value(a, try self.putDraft(a, index, draft, null));
        }
        if (std.mem.eql(u8, cmd, "draft.send")) return self.send(a, index, request);
        return error.BrowserCapabilityUnavailable;
    }
    const ConversationAttachments = struct {
        session: *live.Session,
        allocator: Allocator,
        fn source(self: *@This()) conversation_source.Attachments {
            return .{ .context = self, .fetchFn = fetch, .max_bytes = t.Limits.body_bytes };
        }
        fn fetch(ctx: *anyopaque, a: Allocator, message: t.Message, expected: t.Attachment) !t.Attachment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var scratch: std.heap.ArenaAllocator = .init(self.allocator);
            defer scratch.deinit();
            const source_adapter = self.session.attachmentSource();
            const downloaded = try source_adapter.fetchFn(source_adapter.context, scratch.allocator(), message, expected);
            // Attachment decoding and token-refresh metadata are temporary.
            // Only the complete, validated DTO survives until response encoding.
            var result = downloaded;
            result.id = try a.dupe(u8, downloaded.id);
            result.filename = try a.dupe(u8, downloaded.filename);
            result.mimeType = try a.dupe(u8, downloaded.mimeType);
            result.data = try a.dupe(u8, downloaded.data);
            result.blobId = if (downloaded.blobId) |value| try a.dupe(u8, value) else null;
            result.contentId = if (downloaded.contentId) |value| try a.dupe(u8, value) else null;
            result.disposition = if (downloaded.disposition) |value| try a.dupe(u8, value) else null;
            result.contentLocation = if (downloaded.contentLocation) |value| try a.dupe(u8, value) else null;
            return result;
        }
    };
    fn replyAliases(self: *Provider, a: Allocator, index: usize) ![]const []const u8 {
        if (self.verified_aliases[index]) |aliases| return aliases;
        const aliases = try self.live_sessions[index].aliases(a);
        const stored = try self.arena.allocator().alloc([]const u8, aliases.len);
        for (aliases, stored) |alias, *copy| copy.* = try self.arena.allocator().dupe(u8, alias);
        self.verified_aliases[index] = stored;
        return stored;
    }
    fn cachedList(self: *Provider, a: Allocator, index: usize, request: Value) !Value {
        if (!self.cache.valid(index)) return error.CacheMiss;
        // A server search may use Gmail-only operators. Its optional local
        // preview cannot reject the provider search as invalid cache syntax.
        if (std.mem.eql(u8, j.text(request, "cmd"), "mail.list")) @import("terminal/cache_query.zig").validate(j.text(request, "query")) catch return error.CacheMiss;
        const values = try self.viewList(a, index, request);
        var start: usize = 0;
        var end: usize = @min(values.len, 30);
        const before = j.text(request, "beforeMessageId");
        const after = j.text(request, "afterMessageId");
        const anchor = j.text(request, "anchorMessageId");
        if (before.len > 0 and after.len > 0) return error.InvalidWindowBoundary;
        const target = if (before.len > 0) before else if (after.len > 0) after else anchor;
        if (target.len > 0) {
            var rank: ?usize = null;
            for (values, 0..) |value, row| if (std.mem.eql(u8, j.text(value, "id"), target)) {
                rank = row;
                break;
            };
            if (rank) |row| {
                if (before.len > 0) {
                    end = row;
                    start = end -| 30;
                } else {
                    start = if (after.len > 0) row + 1 else row / 30 * 30;
                    end = @min(values.len, start + 30);
                }
            } else if (before.len > 0 or after.len > 0) return error.CacheBoundaryGone;
        } else if (j.text(request, "cursor").len > 0) {
            const cursor = j.text(request, "cursor");
            const prefix = try self.cacheCursor(a, index, request, 0);
            const separator = std.mem.lastIndexOfScalar(u8, prefix, ':').?;
            if (!std.mem.startsWith(u8, cursor, prefix[0 .. separator + 1])) return error.InvalidCursor;
            start = std.fmt.parseInt(usize, cursor[separator + 1 ..], 10) catch return error.InvalidCursor;
            if (start > values.len) return error.InvalidCursor;
            end = @min(values.len, start + 30);
        }
        var incomplete = self.viewIncomplete(index, request);
        for (values) |message| incomplete = incomplete or try j.boolean(message, "metadataPartial", false) or !try j.boolean(message, "labelsVerified", true);
        return j.value(a, .{ .messages = values[start..end], .cached = true, .partial = true, .cacheReady = true, .lastSyncAt = self.cache.updatedAt(index), .hasMoreCachedBefore = start > 0, .hasMoreCachedAfter = end < values.len, .cursor = try self.cacheCursor(a, index, request, start), .previousCursor = if (start > 0) try self.cacheCursor(a, index, request, start -| 30) else "", .nextCursor = if (end < values.len) try self.cacheCursor(a, index, request, end) else "", .viewIncomplete = incomplete, .searchMode = "cache", .searchScope = "retained subset" });
    }
    fn cacheCursor(self: *Provider, a: Allocator, index: usize, request: Value, offset: usize) ![]const u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ self.address(index), j.text(request, "label"), j.text(request, "query") }) |field| {
            hasher.update(field);
            hasher.update("\x00");
        }
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        const hex = std.fmt.bytesToHex(hash[0..8].*, .lower);
        return std.fmt.allocPrint(a, "C:{d}:{s}:{d}", .{ self.cache.revision(index), hex, offset });
    }
    fn recordView(self: *Provider, index: usize, request: Value, messages: []const Value, complete: bool) !void {
        var replacement: View = .{};
        try replacement.label.set(j.text(request, "label"));
        try replacement.query.set(j.text(request, "query"));
        if (messages.len > replacement.ids.len) return error.InvalidPage;
        for (messages, 0..) |message, row| try replacement.ids[row].set(try j.required(message, "id"));
        replacement.count = messages.len;
        replacement.valid = true;
        replacement.complete = complete;
        const slot = self.view_next[index];
        self.views[index][slot] = replacement;
        self.view_next[index] = (slot + 1) % self.views[index].len;
        // A partial refresh proves no removals. Older matching IDs remain
        // certified scoped members, but their former exact view is no longer
        // authoritative. A complete unfiltered folder supersedes all its views.
        for (&self.views[index], 0..) |*view, row| if (row != slot and view.valid and std.mem.eql(u8, view.label.slice(), replacement.label.slice())) {
            if (replacement.complete and replacement.query.len == 0) {
                view.valid = false;
            } else if (std.mem.eql(u8, view.query.slice(), replacement.query.slice())) {
                if (replacement.complete) view.valid = false else view.complete = false;
            }
        };
    }
    fn viewList(self: *Provider, a: Allocator, index: usize, request: Value) ![]const Value {
        for (&self.views[index]) |*view| if (view.valid and view.complete and std.mem.eql(u8, view.label.slice(), j.text(request, "label")) and std.mem.eql(u8, view.query.slice(), j.text(request, "query"))) {
            var values: std.ArrayList(Value) = .empty;
            for (view.ids[0..view.count]) |id| for (self.cache.retained(index)) |message| if (std.mem.eql(u8, message.id, id.slice())) {
                try values.append(a, try j.value(a, message));
                break;
            };
            if (values.items.len == view.count) return try values.toOwnedSlice(a);
            // Eviction makes the former exact result incomplete. Fall back to
            // the retained subset, including its certified unknown-label IDs.
            view.complete = false;
            break;
        };
        // A partial list certifies its returned IDs without proving that any
        // older neighbor left the folder. Merge unknown-label IDs into the
        // retained subset, and apply this request's local query afterwards.
        var scoped_ids: [8 * 30][]const u8 = undefined;
        var count: usize = 0;
        for (&self.views[index]) |*view| if (view.valid and std.mem.eql(u8, view.label.slice(), j.text(request, "label"))) {
            for (view.ids[0..view.count]) |*id| {
                scoped_ids[count] = id.slice();
                count += 1;
            }
        };
        return self.cache.listAllScoped(index, a, j.text(request, "label"), j.text(request, "query"), scoped_ids[0..count]);
    }
    fn viewIncomplete(self: *const Provider, index: usize, request: Value) bool {
        for (self.views[index]) |view| if (view.valid and !view.complete and std.mem.eql(u8, view.label.slice(), j.text(request, "label")) and (view.query.len == 0 or std.mem.eql(u8, view.query.slice(), j.text(request, "query")))) return true;
        return false;
    }
    fn cacheRead(self: *Provider, index: usize, message: t.Message) !t.Message {
        self.cache.saveRead(index, message) catch |err| {
            // Serialization expansion or the retained snapshot quota can deny
            // persistence of a valid body. The atomic cache write preserved its
            // previous entry; the caller still owns the actual decoded body.
            if (err != error.BrowserCacheQuotaExceeded) return err;
            var readable = message;
            readable.bodyCached = false;
            readable.metadataPartial = true;
            if (readable.decodeWarning.len == 0) readable.decodeWarning = "BrowserCacheQuotaExceeded";
            return readable;
        };
        return message;
    }
    fn cacheQuotaWarning(a: Allocator, value: Value) !Value {
        var annotated = try j.copyObject(a, value);
        if (j.text(value, "decodeWarning").len == 0) try annotated.object.put(a, "decodeWarning", .{ .string = "BrowserCacheQuotaExceeded" });
        try annotated.object.put(a, "metadataPartial", .{ .bool = true });
        try annotated.object.put(a, "bodyCached", .{ .bool = false });
        return annotated;
    }
    fn olderMessage(_: void, left: t.Message, right: t.Message) bool {
        return left.receivedAt < right.receivedAt or (left.receivedAt == right.receivedAt and std.mem.lessThan(u8, left.id, right.id));
    }
    fn read(self: *Provider, a: Allocator, index: usize, id: []const u8, cached: bool) !t.Message {
        if (try self.cache.read(index, id)) |message| return message;
        if (cached or self.live_count == 0) return error.CacheMiss;
        const message = try self.live_sessions[index].read(a, id);
        return self.cacheRead(index, message);
    }
    fn directMailResult(self: *Provider, a: Allocator, index: usize, cmd: []const u8, id: []const u8) !Value {
        if (std.mem.eql(u8, cmd, "mail.modify-labels")) {
            for (self.cache.retained(index)) |message| if (std.mem.eql(u8, message.id, id) and message.labelsVerified) return j.value(a, .{ .messageId = id, .labels = message.labels });
            return self.live_sessions[index].dispatch(a, "mail.labels", try j.value(a, .{ .messageId = id }));
        }
        if (try self.cache.read(index, id)) |message| if (!message.metadataPartial and message.labelsVerified) return j.value(a, message);
        const message = try self.live_sessions[index].read(a, id);
        return j.value(a, try self.cacheRead(index, message));
    }
    fn writeDraftSnapshot(self: *const Provider, index: usize, revision: u32, writer: *std.Io.Writer) !void {
        if (index >= self.live_count) return error.UnknownAccount;
        const session = &self.live_sessions[index];
        try writer.writeAll("{\"version\":1,\"revision\":");
        try std.json.Stringify.value(revision, .{}, writer);
        try writer.writeAll(",\"account\":");
        try std.json.Stringify.value(session.account, .{}, writer);
        try writer.writeAll(",\"clientId\":");
        try std.json.Stringify.value(session.client_id, .{}, writer);
        try writer.writeAll(",\"grantId\":");
        try std.json.Stringify.value(session.grant_id, .{}, writer);
        try writer.writeAll(",\"drafts\":[");
        var first = true;
        for (self.drafts[index]) |slot| if (!slot.retired) {
            if (slot.raw) |raw| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeAll(raw);
            }
        };
        try writer.writeAll("],\"operations\":[");
        first = true;
        for (self.operations[0..self.operation_count]) |operation| if (operation.account_index == index) {
            if (!first) try writer.writeByte(',');
            first = false;
            const hash = std.fmt.bytesToHex(operation.hash, .lower);
            try std.json.Stringify.value(draft_storage.Receipt{
                .id = operation.id.slice(),
                .draftId = operation.draft_id.slice(),
                .hash = &hash,
                .phase = operation.phase,
                .outcome = operation.outcome,
                .errorCode = operation.error_code.slice(),
                .acknowledged = operation.acknowledged,
            }, .{}, writer);
        };
        try writer.writeAll("]}");
    }
    pub fn draftSnapshot(self: *const Provider, index: usize, out: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(out);
        try self.writeDraftSnapshot(index, self.draft_revisions[index], &writer);
        return out[0..writer.end];
    }
    fn writeDraftChanges(self: *const Provider, index: usize, revision: u32, other: ?usize, writer: *std.Io.Writer) !void {
        if (other) |actor_index| {
            try writer.writeAll("{\"version\":1,\"updates\":[");
            try self.writeDraftSnapshot(index, revision, writer);
            try writer.writeByte(',');
            try self.writeDraftSnapshot(actor_index, self.draft_revisions[actor_index] + 1, writer);
            try writer.writeAll("]}");
        } else try self.writeDraftSnapshot(index, revision, writer);
    }
    fn persistDrafts(self: *Provider, index: usize) !void {
        try self.persistDraftChanges(index, null);
    }
    fn persistDraftChanges(self: *Provider, index: usize, other: ?usize) !void {
        const storage = self.draft_store orelse return;
        if (index >= self.live_count) return error.UnknownAccount;
        const revision = std.math.add(u32, self.draft_revisions[index], 1) catch return error.BrowserDraftStorageConflict;
        if (other) |actor_index| {
            if (actor_index >= self.live_count or actor_index == index or self.draft_revisions[actor_index] == std.math.maxInt(u32)) return error.BrowserDraftStorageConflict;
        }
        var count_buffer: [256]u8 = undefined;
        var counter: std.Io.Writer.Discarding = .init(&count_buffer);
        try self.writeDraftChanges(index, revision, other, &counter.writer);
        const size: usize = @intCast(counter.fullCount());
        if (size > draft_storage.snapshot_bytes) return error.BrowserDraftQuota;
        const buffer = try self.allocator.alloc(u8, size);
        defer {
            std.crypto.secureZero(u8, buffer);
            self.allocator.free(buffer);
        }
        var writer: std.Io.Writer = .fixed(buffer);
        try self.writeDraftChanges(index, revision, other, &writer);
        try storage.saveFn(storage.context, self.live_sessions[index].id, buffer);
        self.draft_revisions[index] = revision;
        if (other) |actor_index| self.draft_revisions[actor_index] += 1;
    }
    pub fn restoreDrafts(self: *Provider, index: usize, raw: []const u8) !void {
        if (raw.len == 0) return;
        if (index >= self.live_count) return error.UnknownAccount;
        const session = &self.live_sessions[index];
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const document = try draft_storage.decode(scratch.allocator(), self.allocator, .{ .account = session.account, .clientId = session.client_id, .grantId = session.grant_id }, raw);
        var next: [draft_limit]DraftSlot = @splat(.{});
        errdefer for (next) |slot| if (slot.raw) |bytes| self.allocator.free(bytes);
        var next_bytes: usize = 0;
        for (document.drafts, 0..) |draft, cursor| {
            try next[cursor].id.set(draft.id);
            next[cursor].raw = try std.json.Stringify.valueAlloc(self.allocator, draft, .{ .emit_null_optional_fields = false });
            next_bytes += next[cursor].raw.?.len;
        }
        var previous_bytes: usize = 0;
        for (self.drafts[index]) |slot| if (slot.raw) |bytes| {
            previous_bytes += bytes.len;
        };
        if (self.draft_bytes - previous_bytes + next_bytes > draft_bytes_limit) return error.BrowserDraftQuota;
        var operations: [64]Operation = undefined;
        var operation_count: usize = 0;
        for (self.operations[0..self.operation_count]) |operation| if (operation.account_index != index) {
            operations[operation_count] = operation;
            operation_count += 1;
        };
        if (document.operations.len > operations.len - operation_count) return error.OperationJournalFull;
        for (document.operations) |receipt_value| {
            var operation: Operation = .{ .account_index = index, .hash = undefined, .outcome = receipt_value.outcome, .phase = receipt_value.phase, .acknowledged = receipt_value.acknowledged, .awaiting_receipt = false };
            try operation.id.set(receipt_value.id);
            try operation.draft_id.set(receipt_value.draftId);
            try operation.error_code.set(receipt_value.errorCode);
            _ = try std.fmt.hexToBytes(&operation.hash, receipt_value.hash);
            if (operation.phase == .paused and operation.outcome == .unknown and !operation.acknowledged) {
                operation.outcome = .rejected;
                try operation.error_code.set("SendPausedForReview");
            }
            if (operation.outcome == .applied) for (&next) |*slot| {
                if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), operation.draft_id.slice())) slot.retired = true;
            };
            operations[operation_count] = operation;
            operation_count += 1;
        }
        // Admission is whole-snapshot and failure leaves existing work intact.
        for (self.drafts[index]) |slot| if (slot.raw) |bytes| self.allocator.free(bytes);
        self.drafts[index] = next;
        self.draft_bytes = self.draft_bytes - previous_bytes + next_bytes;
        self.operations = operations;
        self.operation_count = operation_count;
        self.draft_revisions[index] = document.revision;
        if (self.pendingUnknown() != null) self.last_send_status = 2;
    }
    fn draftSlot(self: *Provider, a: Allocator, index: usize, id: []const u8) !*DraftSlot {
        _ = a;
        for (&self.drafts[index]) |*slot| if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), id)) return slot;
        return error.DraftNotFound;
    }
    fn draftValue(self: *Provider, a: Allocator, index: usize, id: []const u8) !Value {
        // Read responses serialize before this immutable slot can change.
        // Mutating callers decode an owning Draft before replacing its bytes.
        return std.json.parseFromSliceLeaky(Value, a, (try self.draftSlot(a, index, id)).raw.?, .{ .allocate = .alloc_if_needed });
    }
    fn putDraft(self: *Provider, a: Allocator, index: usize, input: t.Draft, id: ?[]const u8) !t.Draft {
        if (id) |draft_id| try self.requireEditableDraft(index, draft_id);
        var draft = input;
        try codec.validateDraft(draft, false);
        // Session drafts retain inline bytes; native filesystem blob handles
        // cannot be interpreted by this portable storage adapter.
        for (draft.attachments) |attachment| if (attachment.blobId != null) return error.BrowserAttachmentsUnavailable;
        const slot = if (id) |value| try self.draftSlot(a, index, value) else find: {
            for (&self.drafts[index]) |*candidate| if (candidate.raw == null or self.reclaimableDraft(index, candidate)) break :find candidate;
            return error.BrowserDraftLimit;
        };
        if (id != null and slot.retired) return error.DraftAlreadySent;
        if (id) |value| draft.id = value else {
            self.sequence += 1;
            draft.id = try std.fmt.allocPrint(a, "browser-draft-{s}-{d}", .{ self.sessionNonce(index), self.sequence });
        }
        var identity: bounded.Text(128) = .{};
        try identity.set(draft.id);
        const raw = try std.json.Stringify.valueAlloc(self.allocator, draft, .{ .emit_null_optional_fields = false });
        errdefer self.allocator.free(raw);
        const previous_bytes = if (slot.raw) |previous| previous.len else 0;
        // Leave room for the shared request/response identity envelope.
        if (raw.len > t.Limits.request_bytes - 16 * 1024) return error.BrowserDraftQuota;
        var admitted_bytes = self.draft_bytes - previous_bytes + raw.len;
        var victims: [3 * draft_limit]*DraftSlot = undefined;
        var victim_count: usize = 0;
        // Confirmed sent drafts are only a bounded replay convenience. Their
        // hidden bytes must not consume another account's active-draft quota.
        // Plan first, so an insufficient quota never partially evicts data.
        for (&self.drafts, 0..) |*actor_slots, actor_index| for (actor_slots) |*candidate| {
            if (admitted_bytes <= draft_bytes_limit) break;
            if (candidate == slot or !self.reclaimableDraft(actor_index, candidate)) continue;
            victims[victim_count] = candidate;
            victim_count += 1;
            admitted_bytes -= candidate.raw.?.len;
        };
        if (admitted_bytes > draft_bytes_limit) return error.BrowserDraftQuota;
        // Await the atomic host transaction before releasing any prior bytes.
        const previous_slot = slot.*;
        slot.* = .{ .raw = raw, .id = identity };
        self.persistDrafts(index) catch |err| {
            slot.* = previous_slot;
            return err;
        };
        // All validation, allocation and durable storage precede this commit.
        for (victims[0..victim_count]) |victim| {
            self.allocator.free(victim.raw.?);
            victim.* = .{};
        }
        self.draft_bytes = admitted_bytes;
        if (previous_slot.raw) |previous| self.allocator.free(previous);
        return draft;
    }
    fn reclaimableDraft(self: *const Provider, index: usize, slot: *const DraftSlot) bool {
        if (slot.raw == null or !slot.retired) return false;
        var confirmed = false;
        for (self.operations[0..self.operation_count]) |operation| {
            if (operation.account_index != index or !std.mem.eql(u8, operation.draft_id.slice(), slot.id.slice())) continue;
            if (operation.awaiting_receipt or (operation.outcome == .unknown and !operation.acknowledged)) return false;
            confirmed = confirmed or operation.outcome == .applied;
        }
        return confirmed;
    }
    fn reclaimOrphanedSentDrafts(self: *Provider) void {
        for (&self.drafts, 0..) |*slots, actor_index| for (slots) |*slot| {
            if (!slot.retired or slot.raw == null) continue;
            var retained = false;
            for (self.operations[0..self.operation_count]) |operation| {
                if (operation.account_index == actor_index and std.mem.eql(u8, operation.draft_id.slice(), slot.id.slice())) retained = true;
            }
            if (!retained) {
                self.draft_bytes -= slot.raw.?.len;
                self.allocator.free(slot.raw.?);
                slot.* = .{};
            }
        };
    }
    fn requireEditableDraft(self: *const Provider, index: usize, draft_id: []const u8) !void {
        for (self.operations[0..self.operation_count]) |operation| if (operation.account_index == index and (operation.awaiting_receipt or (operation.outcome == .unknown and !operation.acknowledged)) and std.mem.eql(u8, operation.draft_id.slice(), draft_id)) return error.UnknownOutcome;
    }
    fn receipt(_: *Provider, a: Allocator, operation: Operation) !Value {
        return j.value(a, .{ .id = operation.id.slice(), .draftId = operation.draft_id.slice(), .outcome = if (operation.acknowledged) "acknowledged" else @tagName(operation.outcome), .errorCode = operation.error_code.slice(), .reconciled = operation.acknowledged });
    }
    fn settledOperation(self: *const Provider, account_index: usize, same_actor: bool) ?usize {
        for (self.operations[0..self.operation_count], 0..) |candidate, cursor| {
            if ((candidate.account_index == account_index) != same_actor or candidate.awaiting_receipt or (candidate.outcome == .unknown and !candidate.acknowledged)) continue;
            return cursor;
        }
        return null;
    }
    fn removeOperation(self: *Provider, cursor: usize) void {
        std.mem.copyForwards(Operation, self.operations[cursor .. self.operation_count - 1], self.operations[cursor + 1 .. self.operation_count]);
        self.operation_count -= 1;
    }
    fn rejectedBeforeSend(self: *Provider, a: Allocator, operation_id: []const u8, draft_id: []const u8, err: anyerror) !Value {
        self.last_send_status = 3;
        self.local_send_rejection = true;
        // Keep the concrete preflight/storage cause whenever a receipt can be
        // encoded. SendNotStarted remains the allocation-failure fallback.
        return j.value(a, .{ .id = operation_id, .draftId = draft_id, .outcome = "rejected", .errorCode = @errorName(err) });
    }
    fn send(self: *Provider, a: Allocator, index: usize, request: Value) !Value {
        if (!self.canSend(index)) return error.PermissionDenied;
        const draft = try codec.decodeDraftWithScratch(a, self.allocator, try self.draftValue(a, index, try j.required(request, "draftId")));
        try codec.validateDraft(draft, true);
        const operation_id = try j.required(request, "operationId");
        if (operation_id.len > 256) return error.InvalidOperationId;
        try @import("terminal/recipients.zig").validateHeader(operation_id);
        const content = try @import("terminal/send_outcome.zig").payload(a, draft, self.address(index), null);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        for (self.operations[0..self.operation_count], 0..) |operation, record_index| if (operation.account_index == index) {
            if (std.mem.eql(u8, operation.id.slice(), operation_id)) {
                if (!std.mem.eql(u8, &operation.hash, &digest)) return error.OperationConflict;
                self.last_send_status = 2;
                self.operations[record_index].awaiting_receipt = true;
                for (&self.drafts[index]) |*slot| if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), operation.draft_id.slice())) {
                    slot.retired = false;
                };
                self.acknowledgement_operation = record_index;
                return self.receipt(a, operation);
            }
            if ((operation.awaiting_receipt or (operation.outcome == .unknown and !operation.acknowledged)) and (std.mem.eql(u8, operation.draft_id.slice(), draft.id) or std.mem.eql(u8, &operation.hash, &digest))) {
                self.last_send_status = 2;
                self.acknowledgement_operation = record_index;
                return self.receipt(a, operation);
            }
        };
        // A retained successful receipt may be replayed above, but a new
        // operation must never re-submit the bytes of an already-sent draft.
        if ((try self.draftSlot(a, index, draft.id)).retired) return error.DraftAlreadySent;
        const evict: ?usize = if (self.operation_count == self.operations.len)
            self.settledOperation(index, true) orelse self.settledOperation(index, false) orelse return self.rejectedBeforeSend(a, operation_id, draft.id, error.OperationJournalFull)
        else
            null;
        var operation: Operation = .{ .account_index = index, .hash = digest, .phase = if (self.draft_store != null) .paused else .submitted };
        try operation.id.set(operation_id);
        try operation.draft_id.set(draft.id);
        const prepared = self.live_sessions[index].prepareSend(a, draft, operation_id) catch |err| {
            // Preparation has not submitted a provider write. A recognized
            // rejected receipt keeps local MIME/size failures editable without
            // weakening the existing replay/conflict and unknown-outcome gates.
            return self.rejectedBeforeSend(a, operation_id, draft.id, err);
        };
        // Reclaim settled receipt history atomically with the new pending
        // record. Unknown/unconsumed outcomes are never quota victims.
        const previous_operations = self.operations;
        const previous_count = self.operation_count;
        var other_actor: ?usize = null;
        var reclaimed = false;
        if (evict) |cursor| {
            const actor_index = self.operations[cursor].account_index;
            if (actor_index != index) other_actor = actor_index;
            self.removeOperation(cursor);
            reclaimed = true;
        }
        // Record uncertainty before crossing the provider boundary.
        self.operations[self.operation_count] = operation;
        self.acknowledgement_operation = self.operation_count;
        self.operation_count += 1;
        const persistence_error: ?anyerror = commit: {
            self.persistDraftChanges(index, other_actor) catch |first_error| {
                // The durable table also contains unconnected actors. Their
                // receipts can fill its global quota while this in-memory
                // journal is smaller. Retire one settled receipt, preferring
                // this actor, and retry once. Another live actor joins the
                // same transaction so both in-memory revisions stay current.
                if (first_error == error.BrowserDraftOperationQuota) {
                    const retire = self.settledOperation(index, true) orelse if (other_actor) |actor_index| self.settledOperation(actor_index, true) else self.settledOperation(index, false);
                    if (retire) |cursor| {
                        const actor_index = self.operations[cursor].account_index;
                        if (actor_index != index) other_actor = actor_index;
                        self.removeOperation(cursor);
                        self.acknowledgement_operation = self.operation_count - 1;
                        reclaimed = true;
                        self.persistDraftChanges(index, other_actor) catch |retry_error| break :commit retry_error;
                        break :commit null;
                    }
                }
                break :commit first_error;
            };
            break :commit null;
        };
        if (persistence_error) |err| {
            self.operation_count = previous_count;
            self.operations = previous_operations;
            self.acknowledgement_operation = null;
            return self.rejectedBeforeSend(a, operation_id, draft.id, err);
        }
        if (reclaimed) self.reclaimOrphanedSentDrafts();
        const record = &self.operations[self.operation_count - 1];
        self.last_send_status = 2;
        const result = self.live_sessions[index].submitPrepared(a, prepared) catch |err| {
            // The host may have durably crossed the submission boundary even
            // when its final preflight proves no POST started. Preserve that
            // phase monotonically; the rejected outcome remains editable.
            const session = &self.live_sessions[index];
            record.phase = if (session.send_boundary == .none and self.draft_store != null) .paused else .submitted;
            record.proven_no_post = !session.send_possible_submission;
            record.outcome = if (record.proven_no_post or @import("terminal/send_outcome.zig").rejected(err)) .rejected else .unknown;
            record.error_code.set(@errorName(err)) catch {};
            self.local_send_rejection = record.proven_no_post;
            self.last_send_status = if (record.proven_no_post) 3 else 2;
            return self.receipt(a, record.*);
        };
        record.phase = .submitted;
        record.outcome = if (std.mem.eql(u8, j.text(result, "outcome"), "applied")) .applied else .unknown;
        self.last_send_status = 2;
        return self.receipt(a, record.*);
    }
    fn ensureFixtures(self: *Provider) !void {
        if (self.fixtures_ready) return;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const subjects = [_][]const u8{ "Omagma, now in your browser", "Design review — autumn palette", "Friday demo checklist", "A small note from Montréal", "Release planning", "Weekend reading list", "The café experiment", "Project update: native and browser", "Invitation to the showcase", "Three accounts, one bounded screen", "A Unicode postcard: こんにちは", "Final rehearsal notes" };
        const bodies = [_][]const u8{
            "Hello Alex,\n\nThis is the actual Zig TUI renderer, compiled to WebAssembly.\nThe browser supplies a terminal and forwards key presses to the shared application.\n\nTry j/k to choose mail, Enter to focus the reader, v to switch layouts, and ? for help.\n\nAll accounts and messages are fictional. This demo has no network or credentials.\n\nCheers,\nMorgan",
            "A warm orange accent, calm blue secondary text, and a compact list.\n\nThe UI comes from the native terminal application.\n\nReview points:\n• Can we read the sender at narrow widths?\n• Does the reader preserve literal message text?\n• Do keyboard controls feel natural in a browser?\n\nResize the window to explore the responsive layouts.\n\nMorgan",
            "For Friday:\n\n1. Open the inbox.\n2. Switch account with 1, 2, or 3.\n3. Search locally using /.\n4. Toggle the reader layout with v.\n5. Show searchable help.\n\nThis fictional showcase is read-only. Connect an account to use its granted workflows.\n\nThanks,\nSam",
            "Bonjour!\n\nA Unicode check: café, naïve, Montréal, 日本語, and a friendly 🚀.\n\nTerminal cell width and wrapping happen inside WebAssembly.\n\nOne\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight\nNine\nTen\n\nÀ bientôt,\nCamille",
        };
        for (0..3) |index| {
            try self.cache.bind(index, .{ .account = demo_accounts[index], .clientId = "synthetic-demo", .grantId = "synthetic-readonly" });
            var messages: std.ArrayList(Value) = .empty;
            for (subjects, 0..) |subject, row| try messages.append(a, try j.value(a, t.Message{
                .id = try std.fmt.allocPrint(a, "demo-{d}-{d}", .{ index, row }),
                .threadId = try std.fmt.allocPrint(a, "thread-{d}-{d}", .{ index, row }),
                .from = .{ .address = if (row % 2 == 0) "morgan@example.test" else "sam@example.test", .name = if (row % 2 == 0) "Morgan Chen" else "Sam Rivera" },
                .to = &.{.{ .address = demo_accounts[index] }},
                .subject = subject,
                .snippet = "Synthetic mail · rendered by the native TUI in WebAssembly",
                .bodyText = bodies[row % bodies.len],
                .bodyCached = true,
                .bodySource = .plain,
                .unread = row % 3 == 0,
                .labels = if (row % 4 == 0) &.{ "INBOX", "STARRED" } else &.{"INBOX"},
                .receivedAt = 1791712800000 - @as(i64, @intCast(row)) * 3600000,
            }));
            try self.cache.replaceList(index, messages.items, 1791712800000);
            const contacts = try j.value(a, [_]t.Contact{ .{ .resourceName = "people/morgan", .name = "Morgan Chen", .emails = &.{.{ .address = "morgan@example.test" }} }, .{ .resourceName = "people/sam", .name = "Sam Rivera", .emails = &.{.{ .address = "sam@example.test" }} } });
            try self.cache.replaceContacts(index, contacts.array.items);
        }
        self.fixtures_ready = true;
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    return false;
}
