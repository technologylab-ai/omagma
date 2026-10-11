//! Browser implementation of the existing terminal Client protocol.
//! This module owns provider/cache/session storage, never keyboard or UI state.
const std = @import("std");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const live = @import("browser_live.zig");
const cache_module = @import("browser_cache.zig");
const codec = @import("terminal/draft_codec.zig");
const conversation = @import("terminal/conversation_draft.zig");
const bounded = @import("bounded.zig");
const Allocator = std.mem.Allocator;
const Value = j.Value;
const draft_limit = 8;
const draft_bytes_limit = 8 * 1024 * 1024;
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
    outcome: enum { unknown, applied, rejected } = .unknown,
    error_code: bounded.Text(64) = .{},
    acknowledged: bool = false,
    awaiting_receipt: bool = true,
};

pub const Provider = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    cache: cache_module.Store,
    live_count: usize = 0,
    live_sessions: [3]live.Session = undefined,
    fixtures_ready: bool = false,
    drafts: [3][draft_limit]DraftSlot = @splat(@splat(.{})),
    draft_bytes: usize = 0,
    sequence: u64 = 0,
    operations: [64]Operation = undefined,
    operation_count: usize = 0,
    last_send_status: u32 = 0,
    acknowledgement_operation: ?usize = null,
    views: [3][8]View = @splat(@splat(.{})),
    view_next: [3]usize = @splat(0),

    pub fn init(a: Allocator) Provider {
        return .{ .allocator = a, .arena = .init(a), .cache = cache_module.Store.init(a) };
    }
    pub fn deinit(self: *Provider) void {
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
    pub fn canContacts(self: *const Provider, index: usize) bool {
        return self.live_count == 0 or (index < self.live_count and self.live_sessions[index].can_contacts);
    }
    pub fn sessionNonce(self: *const Provider, index: usize) []const u8 {
        return if (index < self.live_count) self.live_sessions[index].nonce else "00000000-0000-4000-8000-000000000000";
    }
    pub fn sendStatus(self: *const Provider) u32 {
        return self.last_send_status;
    }
    pub fn pendingUnknown(self: *const Provider) ?struct { account_index: usize, draft_id: []const u8 } {
        var index = self.operation_count;
        while (index > 0) {
            index -= 1;
            const operation = &self.operations[index];
            if (operation.outcome == .unknown and !operation.acknowledged) return .{ .account_index = operation.account_index, .draft_id = operation.draft_id.slice() };
        }
        return null;
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
        for (self.operations[0..self.operation_count]) |*operation| {
            if (operation.account_index == index and std.mem.eql(u8, operation.draft_id.slice(), draft_id) and operation.outcome == .unknown) {
                operation.acknowledged = true;
                operation.awaiting_receipt = false;
                found = true;
            }
        }
        if (!found) return error.OperationNotFound;
        self.last_send_status = 0;
    }
    pub fn connect(self: *Provider, bytes: []const u8, pending_cache: []const u8) !usize {
        if (self.live_count == 3) return error.TooManyAccounts;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        // Profile validation happens before any uploaded snapshot is consumed.
        var session = try live.connect(scratch.allocator(), bytes);
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
        operation.outcome = .unknown;
        operation.acknowledged = false;
        operation.error_code.set("AcknowledgementUnavailable") catch {};
        self.last_send_status = 2;
        // A failed replay must restore the protected recovery draft too.
        for (&self.drafts[operation.account_index]) |*slot| if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), operation.draft_id.slice())) {
            slot.retired = false;
        };
    }
    fn execute(self: *Provider, out: Allocator, raw: []const u8, cached: bool) ![]const u8 {
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
            const failure = if (!cache_only and std.mem.eql(u8, j.text(request, "cmd"), "draft.send") and self.failedAcknowledgement()) error.UnknownOutcome else err;
            return std.json.Stringify.valueAlloc(out, .{ .version = @as(u8, 1), .id = id, .ok = false, .account = account, .@"error" = .{ .code = @errorName(failure), .message = @errorName(failure) } }, .{}) catch |encoding_error| {
                if (failure == error.UnknownOutcome) return error.UnknownOutcome;
                return encoding_error;
            };
        };
        return std.json.Stringify.valueAlloc(out, .{ .version = @as(u8, 1), .id = id, .ok = true, .account = account, .data = data }, .{}) catch |err| {
            // Failure to encode a post-write acknowledgement cannot claim rejection.
            if (!cache_only and std.mem.eql(u8, j.text(request, "cmd"), "draft.send")) {
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
        return if (self.canSend(index)) (if (self.canContacts(index)) &.{ "mail-read", "mail-send", "contacts-read" } else &.{ "mail-read", "mail-send" }) else (if (self.canContacts(index)) &.{ "mail-read", "contacts-read" } else &.{"mail-read"});
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
        if (std.mem.eql(u8, cmd, "labels.list")) return j.value(a, .{ .labels = [_]Value{}, .cached = true });
        if (std.mem.eql(u8, cmd, "cache.refresh-status")) return j.value(a, .{ .refreshInProgress = false });
        if (std.mem.eql(u8, cmd, "cache.activity")) return j.value(a, .{ .inboxArrivalCount = @as(usize, 0), .generation = self.cache.revision(index), .lastSyncAt = self.cache.updatedAt(index) });
        if (std.mem.eql(u8, cmd, "cache.clear")) {
            self.cache.clear(index);
            self.views[index] = @splat(.{});
            return j.value(a, .{ .cleared = true, .draftsPreserved = true, .operationsPreserved = true });
        }
        if (std.mem.eql(u8, cmd, "cache.stats")) return j.value(a, .{ .metadataEntries = self.cache.retained(index).len, .metadataLimit = @as(usize, 300), .diskBytes = @as(usize, 0), .diskLimitBytes = cache_module.total_limit, .bodyLimitBytes = t.Limits.body_bytes, .runtimeReservationBytes = t.Limits.runtime_bytes, .terminalHeapLimitBytes = t.Limits.runtime_bytes, .lastSyncAt = self.cache.updatedAt(index), .generation = self.cache.revision(index), .refreshInProgress = false });
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
            try self.cache.replaceView(index, messages.array.items, std.Io.Timestamp.now(live.io, .real).toMilliseconds(), j.text(request, "label"), j.text(request, "query").len == 0 and j.text(result, "nextCursor").len == 0);
            try self.recordView(index, request, messages.array.items, j.text(result, "nextCursor").len == 0);
            // A bounded head is honest about its scope; it never invents a cursor.
            if (std.mem.eql(u8, cmd, "mail.refresh")) return j.value(a, .{ .cacheReady = true, .lastSyncAt = self.cache.updatedAt(index), .refreshCompleted = true, .refreshInProgress = false });
            return j.value(a, .{ .messages = messages.array.items, .cached = false, .partial = true, .cacheReady = true, .lastSyncAt = self.cache.updatedAt(index) });
        }
        if (std.mem.eql(u8, cmd, "mail.read")) return j.value(a, try self.read(a, index, try j.required(request, "messageId"), cached));
        if (std.mem.eql(u8, cmd, "mail.thread")) {
            const thread_id = try j.required(request, "threadId");
            if (!cached) {
                const session = &self.live_sessions[index];
                const result = try @import("terminal/gmail.zig").dispatchAuthorized(live.io, a, session.account, session.capabilities(), session.transport(), cmd, request);
                const messages = j.get(result, "messages") orelse return error.InvalidProviderResponse;
                if (messages != .array or messages.array.items.len > 30) return error.ThreadTooLarge;
                for (messages.array.items) |message| try self.cache.saveRead(index, try j.decode(t.Message, a, message));
                return result;
            }
            var messages: std.ArrayList(t.Message) = .empty;
            for (self.cache.retained(index)) |message| if (message.bodyCached and std.mem.eql(u8, message.threadId, thread_id)) {
                if (messages.items.len == 30) return error.ThreadTooLarge;
                try messages.append(a, message);
            };
            if (messages.items.len == 0) return error.CacheMiss;
            return j.value(a, .{ .messages = messages.items, .cached = true, .partial = true });
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
                return j.value(a, .{ .contacts = matches.items, .cached = true, .cacheReady = self.cache.contactsLoaded(index) });
            }
            const result = try self.live_sessions[index].contacts(a, j.text(request, "query"));
            const contacts = j.get(result, "contacts") orelse return error.InvalidProviderResponse;
            if (contacts != .array) return error.InvalidProviderResponse;
            // Remote searches are temporary views; they cannot replace the full cached head.
            if (j.text(request, "query").len == 0) try self.cache.replaceContacts(index, contacts.array.items);
            return result;
        }
        if (std.mem.eql(u8, cmd, "draft.list")) {
            var drafts: std.ArrayList(Value) = .empty;
            for (self.drafts[index]) |slot| if (!slot.retired) {
                if (slot.raw) |raw| try drafts.append(a, try std.json.parseFromSliceLeaky(Value, a, raw, .{}));
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
            const raw = slot.raw.?;
            self.draft_bytes -= raw.len;
            self.allocator.free(raw);
            slot.raw = null;
            return j.value(a, .{ .discarded = true });
        }
        if (std.mem.eql(u8, cmd, "operation.list")) {
            var operations: std.ArrayList(Value) = .empty;
            for (self.operations[0..self.operation_count]) |operation| if (operation.account_index == index) try operations.append(a, try self.receipt(a, operation));
            return j.value(a, .{ .operations = operations.items });
        }
        if (std.mem.eql(u8, cmd, "queue.list")) return j.value(a, .{ .queue = [_]Value{} });
        if (std.mem.eql(u8, cmd, "draft.preview")) {
            const draft = try codec.decodeDraft(a, j.get(request, "draft") orelse try self.draftValue(a, index, try j.required(request, "draftId")));
            try codec.validateDraft(draft, false);
            const prepared = try @import("terminal/markdown_mail.zig").prepare(a, draft);
            return j.value(a, .{ .bodyFormat = draft.bodyFormat, .bodyText = if (draft.recoveryFields) |fields| fields[4] else draft.bodyText, .plainText = prepared.plain, .bodyHtml = prepared.html });
        }
        if (std.mem.eql(u8, cmd, "draft.create") or std.mem.eql(u8, cmd, "draft.update") or std.mem.eql(u8, cmd, "draft.recovery-save")) {
            if (!self.canSend(index)) return error.PermissionDenied;
            const input = j.get(request, "draft") orelse return error.MissingField;
            var clean = input;
            var recovery: ?[]const []const u8 = null;
            if (std.mem.eql(u8, cmd, "draft.recovery-save")) {
                recovery = try j.decode([]const []const u8, a, j.get(input, "recoveryFields") orelse return error.MissingField);
                if (recovery.?.len != 5) return error.InvalidRecovery;
                for (recovery.?, 0..) |field, i| if (field.len > (if (i == 4) t.Limits.body_bytes else @as(usize, 16 * 1024)) or !std.unicode.utf8ValidateSlice(field)) return error.InvalidRecovery;
                clean = try j.copyObject(a, input);
                for ([_][]const u8{ "to", "cc", "bcc", "recoveryFields" }) |key| _ = clean.object.swapRemove(key);
                try clean.object.put(a, "subject", .{ .string = recovery.?[3] });
                try clean.object.put(a, "bodyText", .{ .string = "" });
            }
            var draft = try codec.decodeDraft(a, clean);
            draft.recoveryFields = recovery;
            const existing = j.text(request, "draftId");
            if (existing.len > 0) {
                const previous = try codec.decodeDraft(a, try self.draftValue(a, index, existing));
                if (j.get(input, "bodyFormat") == null) draft.bodyFormat = previous.bodyFormat;
                if (j.get(input, "omittedAttachments") == null) draft.omittedAttachments = previous.omittedAttachments;
            }
            return j.value(a, try self.putDraft(a, index, draft, if (existing.len > 0) existing else null));
        }
        if (std.mem.eql(u8, cmd, "mail.reply") or std.mem.eql(u8, cmd, "mail.forward")) {
            if (!self.canSend(index)) return error.PermissionDenied;
            if (try j.boolean(request, "original", false) or try j.boolean(request, "preserveFormatting", false)) return error.BrowserOriginalUnavailable;
            const message = try self.read(a, index, try j.required(request, "messageId"), false);
            const format = try codec.requestBodyFormat(request);
            var draft = if (std.mem.eql(u8, cmd, "mail.reply")) try conversation.reply(a, message, .{ .account = self.address(index), .all = try j.boolean(request, "all", false), .format = format }) else try conversation.forward(a, message, .{ .format = format, .body_text = try conversation.plainText(a, message) });
            if (std.mem.eql(u8, cmd, "mail.forward")) draft.omittedAttachments = message.attachments.len;
            return j.value(a, try self.putDraft(a, index, draft, null));
        }
        if (std.mem.eql(u8, cmd, "draft.send")) return self.send(a, index, request);
        return error.BrowserCapabilityUnavailable;
    }
    fn cachedList(self: *Provider, a: Allocator, index: usize, request: Value) !Value {
        if (!self.cache.valid(index)) return error.CacheMiss;
        // A server search may use Gmail-only operators. Its optional local
        // preview cannot reject the provider search as invalid cache syntax.
        if (std.mem.eql(u8, j.text(request, "cmd"), "mail.list")) @import("terminal/cache_query.zig").validate(j.text(request, "query")) catch return error.CacheMiss;
        const values = if (std.mem.eql(u8, j.text(request, "cmd"), "mail.list")) try self.viewList(a, index, request) orelse try self.cache.listAll(index, a, j.text(request, "label"), j.text(request, "query")) else try self.cache.listAll(index, a, j.text(request, "label"), j.text(request, "query"));
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
        return j.value(a, .{ .messages = values[start..end], .cached = true, .partial = true, .cacheReady = true, .lastSyncAt = self.cache.updatedAt(index), .hasMoreCachedBefore = start > 0, .hasMoreCachedAfter = end < values.len, .cursor = try self.cacheCursor(a, index, request, start), .previousCursor = if (start > 0) try self.cacheCursor(a, index, request, start -| 30) else "", .nextCursor = if (end < values.len) try self.cacheCursor(a, index, request, end) else "", .viewIncomplete = false, .searchMode = "cache", .searchScope = "retained subset" });
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
        // Only the latest current result for an exact view remains authoritative.
        for (&self.views[index], 0..) |*view, row| if (row != slot and view.valid and std.mem.eql(u8, view.label.slice(), replacement.label.slice()) and std.mem.eql(u8, view.query.slice(), replacement.query.slice())) {
            view.valid = false;
        };
    }
    fn viewList(self: *Provider, a: Allocator, index: usize, request: Value) !?[]const Value {
        for (self.views[index]) |view| if (view.valid and view.complete and std.mem.eql(u8, view.label.slice(), j.text(request, "label")) and std.mem.eql(u8, view.query.slice(), j.text(request, "query"))) {
            var values: std.ArrayList(Value) = .empty;
            for (view.ids[0..view.count]) |id| for (self.cache.retained(index)) |message| if (std.mem.eql(u8, message.id, id.slice())) {
                try values.append(a, try j.value(a, message));
                break;
            };
            return try values.toOwnedSlice(a);
        };
        return null;
    }
    fn read(self: *Provider, a: Allocator, index: usize, id: []const u8, cached: bool) !t.Message {
        if (try self.cache.read(index, id)) |message| return message;
        if (cached or self.live_count == 0) return error.CacheMiss;
        const message = try self.live_sessions[index].read(a, id);
        try self.cache.saveRead(index, message);
        return message;
    }
    fn draftSlot(self: *Provider, a: Allocator, index: usize, id: []const u8) !*DraftSlot {
        _ = a;
        for (&self.drafts[index]) |*slot| if (slot.raw != null and std.mem.eql(u8, slot.id.slice(), id)) return slot;
        return error.DraftNotFound;
    }
    fn draftValue(self: *Provider, a: Allocator, index: usize, id: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, a, (try self.draftSlot(a, index, id)).raw.?, .{ .allocate = .alloc_always });
    }
    fn putDraft(self: *Provider, a: Allocator, index: usize, input: t.Draft, id: ?[]const u8) !t.Draft {
        if (id) |draft_id| try self.requireEditableDraft(index, draft_id);
        var draft = input;
        try codec.validateDraft(draft, false);
        if (draft.attachments.len > 0 or draft.original != null) return error.BrowserAttachmentsUnavailable;
        const slot = if (id) |value| try self.draftSlot(a, index, value) else find: {
            for (&self.drafts[index]) |*candidate| if (candidate.raw == null or candidate.retired) break :find candidate;
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
        if (raw.len > 3 * 1024 * 1024 or self.draft_bytes - previous_bytes + raw.len > draft_bytes_limit) return error.BrowserDraftQuota;
        self.draft_bytes = self.draft_bytes - previous_bytes + raw.len;
        if (slot.raw) |previous| self.allocator.free(previous);
        slot.raw = raw;
        slot.id = identity;
        slot.retired = false;
        return draft;
    }
    fn requireEditableDraft(self: *const Provider, index: usize, draft_id: []const u8) !void {
        for (self.operations[0..self.operation_count]) |operation| if (operation.account_index == index and (operation.awaiting_receipt or (operation.outcome == .unknown and !operation.acknowledged)) and std.mem.eql(u8, operation.draft_id.slice(), draft_id)) return error.UnknownOutcome;
    }
    fn receipt(_: *Provider, a: Allocator, operation: Operation) !Value {
        return j.value(a, .{ .id = operation.id.slice(), .draftId = operation.draft_id.slice(), .outcome = if (operation.acknowledged) "acknowledged" else @tagName(operation.outcome), .errorCode = operation.error_code.slice(), .reconciled = operation.acknowledged });
    }
    fn send(self: *Provider, a: Allocator, index: usize, request: Value) !Value {
        if (!self.canSend(index)) return error.PermissionDenied;
        const draft = try codec.decodeDraft(a, try self.draftValue(a, index, try j.required(request, "draftId")));
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
        if (self.operation_count == self.operations.len) return error.OperationJournalFull;
        var operation: Operation = .{ .account_index = index, .hash = digest };
        try operation.id.set(operation_id);
        try operation.draft_id.set(draft.id);
        // Record uncertainty before crossing the provider boundary.
        self.operations[self.operation_count] = operation;
        const record = &self.operations[self.operation_count];
        self.acknowledgement_operation = self.operation_count;
        self.operation_count += 1;
        self.last_send_status = 2;
        const result = self.live_sessions[index].send(a, draft, operation_id) catch |err| {
            record.outcome = if (@import("terminal/send_outcome.zig").rejected(err)) .rejected else .unknown;
            record.error_code.set(@errorName(err)) catch {};
            self.last_send_status = 2;
            return self.receipt(a, record.*);
        };
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
