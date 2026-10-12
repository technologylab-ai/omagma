//! Bounded browser storage adapter for the native mailbox transaction domain.
//! No UI state or credentials live here. Unknown receipts are never replayed.
const std = @import("std");
const j = @import("terminal/json.zig");
const live = @import("browser_live.zig");
const cache_module = @import("browser_cache.zig");
const triage = @import("terminal/triage.zig");
const item_engine = @import("terminal/batch_item.zig");
const storage = @import("terminal/store.zig");
const gmail = @import("terminal/gmail.zig");
const bounded = @import("bounded.zig");
const A = std.mem.Allocator;
const Value = j.Value;
const journal_limit = 2 * 1024 * 1024;
const labels_limit = 512 * 1024;

const Record = struct {
    arena: std.heap.ArenaAllocator,
    account_index: usize,
    id: bounded.Text(256) = .{},
    command: bounded.Text(32) = .{},
    hash: [32]u8,
    items: []storage.UndoItem = &.{},
    failures: [100]?anyerror = @splat(null),
    outcome: []const u8 = "rejected",
    error_code: []const u8 = "NotStarted",
    label_id: bounded.Text(128) = .{},
    label: ?storage.Label = null,
    deleted: bool = false,
    bytes: usize = 0,
};

pub const Store = struct {
    allocator: A,
    records: [64]Record = undefined,
    count: usize = 0,
    bytes: usize = 0,
    sequence: u64 = 0,
    busy: bool = false,
    labels: [3]?[]const u8 = @splat(null),
    epochs: [3]u32 = @splat(0),

    pub fn init(a: A) Store {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Store) void {
        for (self.records[0..self.count]) |*record| record.arena.deinit();
        for (self.labels) |raw| if (raw) |value| self.allocator.free(value);
    }
    pub fn epoch(self: *const Store, index: usize) u32 {
        return self.epochs[index];
    }
    pub fn labelsReady(self: *const Store, index: usize) bool {
        return self.labels[index] != null;
    }
    fn changed(self: *Store, index: usize) void {
        self.epochs[index] +%= 1;
    }
    fn reserve(self: *Store, record: *Record, size: usize) !void {
        if (size > journal_limit -| self.bytes) return error.OperationJournalFull;
        self.bytes += size;
        record.bytes += size;
    }
    fn copyLabels(self: *Store, record: *Record, values: []const []const u8) ![]const []const u8 {
        var size: usize = values.len * (@sizeOf([]const u8) + 16) + 64;
        for (values) |value| size += value.len + 16;
        try self.reserve(record, size);
        const a = record.arena.allocator();
        const result = try a.alloc([]const u8, values.len);
        for (values, result) |value, *copy| copy.* = try a.dupe(u8, value);
        return result;
    }
    fn reclaim(self: *Store) bool {
        var recent: [3]?usize = @splat(null);
        for (self.records[0..self.count], 0..) |record, position| for (record.items) |item| if (item_engine.canUndo(item)) {
            recent[record.account_index] = position;
            break;
        };
        for (self.records[0..self.count], 0..) |record, position| {
            if (recent[record.account_index] == position) continue;
            var protected = record.items.len == 0 and std.mem.eql(u8, record.outcome, "unknown");
            for (record.items) |item| protected = protected or uncertain(item) or std.mem.eql(u8, item.outcome, "pending");
            if (protected) continue;
            self.records[position].arena.deinit();
            self.bytes -= record.bytes;
            std.mem.copyForwards(Record, self.records[position .. self.count - 1], self.records[position + 1 .. self.count]);
            self.count -= 1;
            return true;
        }
        return false;
    }
    fn append(self: *Store, index: usize, id: []const u8, command: []const u8, hash: [32]u8, additional_bytes: usize) !*Record {
        const required = @sizeOf(Record) + 64 + additional_bytes;
        if (index >= 3 or required > journal_limit) return error.OperationJournalFull;
        // Reclaim only before obtaining the new record pointer. The one-job
        // guard prevents a reentrant request from moving an active adapter.
        while (self.count == self.records.len or required > journal_limit -| self.bytes) {
            if (!self.reclaim()) return error.OperationJournalFull;
        }
        var record: Record = .{ .arena = .init(self.allocator), .account_index = index, .hash = hash };
        try record.id.set(id);
        try record.command.set(command);
        try self.reserve(&record, @sizeOf(Record) + 64);
        self.records[self.count] = record;
        self.count += 1;
        return &self.records[self.count - 1];
    }
    fn discardUnstarted(self: *Store, record: *Record) void {
        std.debug.assert(self.count > 0 and record == &self.records[self.count - 1]);
        self.bytes -= record.bytes;
        record.arena.deinit();
        self.count -= 1;
    }
    fn prepareTargets(self: *Store, record: *Record, ids: []const []const u8) !void {
        try self.reserve(record, ids.len * (@sizeOf(storage.UndoItem) + 192));
        record.items = try record.arena.allocator().alloc(storage.UndoItem, ids.len);
        for (record.items) |*item| item.* = .{ .messageId = "", .outcome = "rejected", .errorCode = "NotStarted" };
        for (ids, record.items) |id, *item| item.messageId = try record.arena.allocator().dupe(u8, id);
    }
    fn digest(a: A, request: Value) ![32]u8 {
        const raw = try std.json.Stringify.valueAlloc(a, request, .{});
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &result, .{});
        return result;
    }
    fn uncertain(item: storage.UndoItem) bool {
        return std.mem.eql(u8, item.outcome, "unknown") or std.mem.eql(u8, item.errorCode, "UnknownOutcome");
    }
    pub fn unknownMessage(self: *const Store, index: usize, id: []const u8) bool {
        for (self.records[0..self.count]) |record| if (record.account_index == index) {
            for (record.items) |item| if (std.mem.eql(u8, item.messageId, id) and uncertain(item)) return true;
        };
        return false;
    }
    pub fn listLabels(self: *Store, a: A, index: usize, session: ?*live.Session) !Value {
        if (session) |active| {
            const response = try active.dispatch(a, "labels.list", j.object(a));
            try self.saveLabels(index, j.get(response, "labels") orelse return error.InvalidProviderResponse);
        }
        const values: Value = if (self.labels[index]) |raw| try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always }) else .{ .array = .init(a) };
        return j.value(a, .{ .labels = values, .cached = session == null });
    }
    fn saveLabels(self: *Store, index: usize, values: Value) !void {
        if (values != .array or values.array.items.len > 512) return error.TooManyLabels;
        const raw = try std.json.Stringify.valueAlloc(self.allocator, values, .{});
        errdefer self.allocator.free(raw);
        if (raw.len > labels_limit) return error.TooManyLabels;
        if (self.labels[index]) |previous| self.allocator.free(previous);
        self.labels[index] = raw;
    }
    pub fn labelState(self: *Store, a: A, index: usize, session: *live.Session, request: Value) !Value {
        const ids = try triage.pinned(a, request);
        const listed = try self.listLabels(a, index, session);
        const definitions = try j.decode([]storage.Label, a, j.get(listed, "labels").?);
        const LabelState = struct { id: []const u8, name: []const u8, type: []const u8, color: ?@import("terminal/types.zig").LabelColor, appliedCount: usize = 0 };
        const labels = try a.alloc(LabelState, definitions.len);
        for (definitions, labels) |definition, *label| label.* = .{ .id = definition.id, .name = definition.name, .type = definition.type, .color = definition.color };
        for (ids) |id| {
            const response = try session.dispatch(a, "mail.labels", try j.value(a, .{ .messageId = id }));
            const memberships = try j.decode([]const []const u8, a, j.get(response, "labels").?);
            for (labels) |*label| for (memberships) |membership| if (std.mem.eql(u8, label.id, membership)) {
                label.appliedCount += 1;
                break;
            };
        }
        return j.value(a, .{ .messageIds = ids, .count = ids.len, .labels = labels, .complete = true });
    }
    fn batchReceipt(a: A, record: *const Record) !Value {
        const summary = item_engine.summarize(record.items);
        return j.value(a, .{ .undoToken = record.id.slice(), .outcomes = record.items, .appliedCount = summary.appliedCount, .restoredCount = summary.restoredCount, .partial = summary.partial });
    }
    pub fn batch(self: *Store, a: A, index: usize, session: *live.Session, cache: *cache_module.Store, request: Value) !Value {
        if (self.busy) return error.OperationPending;
        self.busy = true;
        defer self.busy = false;
        if (!session.can_modify) return error.PermissionDenied;
        _ = try triage.scope(request);
        const ids = try triage.pinned(a, request);
        var delta = try triage.plan(a, request);
        const hash = try digest(a, try j.value(a, .{ .messageIds = ids, .add = delta.add, .remove = delta.remove }));
        const explicit_id = j.text(request, "operationId");
        if (explicit_id.len > 256) return error.InvalidOperationId;
        try @import("terminal/recipients.zig").validateHeader(explicit_id);
        for (self.records[0..self.count]) |*record| if (record.account_index == index) {
            if (explicit_id.len > 0 and std.mem.eql(u8, record.id.slice(), explicit_id)) {
                if (record.items.len == 0 or !std.mem.eql(u8, &record.hash, &hash)) return error.OperationConflict;
                return batchReceipt(a, record);
            }
            for (record.items) |item| if (uncertain(item)) for (ids) |id| if (std.mem.eql(u8, item.messageId, id)) {
                if (std.mem.eql(u8, &record.hash, &hash)) return batchReceipt(a, record);
                return error.UnknownOutcome;
            };
        };
        delta = try gmail.resolveBatchLabels(a, session.transport(), delta);
        for (delta.add) |added| for (delta.remove) |removed| if (std.mem.eql(u8, added, removed)) return error.ConflictingLabels;
        self.sequence += 1;
        const token = if (explicit_id.len > 0) explicit_id else try std.fmt.allocPrint(a, "browser-undo-{s}-{d}", .{ session.nonce, self.sequence });
        var inverse_bytes: usize = 128;
        for ([_][]const []const u8{ delta.add, delta.remove }) |labels| for (labels) |label| {
            inverse_bytes += @sizeOf([]const u8) + label.len + 32;
        };
        const record = try self.append(index, token, "mail.batch", hash, ids.len * (@sizeOf(storage.UndoItem) + 192 + inverse_bytes));
        self.prepareTargets(record, ids) catch |err| {
            self.discardUnstarted(record);
            return err;
        };
        for (ids, 0..) |id, position| {
            var scope: std.heap.ArenaAllocator = .init(self.allocator);
            defer scope.deinit();
            var adapter: ItemAdapter = .{ .store = self, .record = record, .position = position, .session = session, .cache = cache };
            try item_engine.run(adapter.hooks(), scope.allocator(), id, delta, false);
        }
        return batchReceipt(a, record);
    }
    pub fn undo(self: *Store, a: A, index: usize, session: *live.Session, cache: *cache_module.Store, request: Value) !Value {
        if (self.busy) return error.OperationPending;
        self.busy = true;
        defer self.busy = false;
        if (!session.can_modify) return error.PermissionDenied;
        const token = try j.required(request, "undoToken");
        if (token.len > 256) return error.InvalidUndoToken;
        var found: ?*Record = null;
        for (self.records[0..self.count]) |*record| if (record.account_index == index and record.items.len > 0 and std.mem.eql(u8, record.id.slice(), token)) {
            found = record;
            break;
        };
        const record = found orelse return error.UndoNotFound;
        const selected = if (j.get(request, "messageIds") != null) try triage.pinned(a, request) else null;
        if (selected) |ids| for (ids) |id| {
            var matches = false;
            for (record.items) |item| matches = matches or std.mem.eql(u8, item.messageId, id);
            if (!matches) return error.UndoMessageNotFound;
        };
        for (record.items, 0..) |item, position| {
            if (selected) |ids| {
                var matches = false;
                for (ids) |id| matches = matches or std.mem.eql(u8, item.messageId, id);
                if (!matches) continue;
            }
            if (!item_engine.canUndo(item)) continue;
            // An older inverse cannot bypass a later uncertain mutation.
            if (self.unknownMessage(index, item.messageId)) continue;
            var scope: std.heap.ArenaAllocator = .init(self.allocator);
            defer scope.deinit();
            var adapter: ItemAdapter = .{ .store = self, .record = record, .position = position, .session = session, .cache = cache };
            try item_engine.run(adapter.hooks(), scope.allocator(), item.messageId, .{ .add = item.addLabels, .remove = item.removeLabels }, true);
        }
        return batchReceipt(a, record);
    }
    fn labelReceipt(a: A, record: *const Record) !Value {
        return j.value(a, .{ .operationId = record.id.slice(), .outcome = record.outcome, .errorCode = record.error_code, .labelId = record.label_id.slice(), .label = record.label, .deleted = record.deleted });
    }
    pub fn operationRead(self: *Store, a: A, index: usize, id: []const u8) !Value {
        for (self.records[0..self.count]) |*record| if (record.account_index == index and std.mem.eql(u8, record.id.slice(), id)) return if (record.items.len > 0) batchReceipt(a, record) else labelReceipt(a, record);
        return error.OperationNotFound;
    }
    pub fn singleResult(self: *Store, index: usize, token: []const u8) !void {
        for (self.records[0..self.count]) |record| if (record.account_index == index and std.mem.eql(u8, record.id.slice(), token) and record.items.len == 1) {
            const item = record.items[0];
            if (uncertain(item)) return error.UnknownOutcome;
            if (std.mem.eql(u8, item.outcome, "applied")) return;
            return record.failures[0] orelse error.ProviderRejected;
        };
        return error.OperationNotFound;
    }
    pub fn loseSingleResult(self: *Store, index: usize, token: []const u8) void {
        for (self.records[0..self.count]) |*record| if (record.account_index == index and std.mem.eql(u8, record.id.slice(), token) and record.items.len == 1) {
            record.items[0].outcome = "unknown";
            record.items[0].errorCode = "UnknownOutcome";
            record.failures[0] = error.UnknownOutcome;
            self.changed(index);
            return;
        };
    }
    pub fn manageLabel(self: *Store, a: A, index: usize, session: *live.Session, cache: *cache_module.Store, request: Value) !Value {
        if (self.busy) return error.OperationPending;
        self.busy = true;
        defer self.busy = false;
        if (!session.can_modify) return error.PermissionDenied;
        const cmd = try j.required(request, "cmd");
        const operation_id = try j.required(request, "operationId");
        if (operation_id.len > 256) return error.InvalidOperationId;
        try @import("terminal/recipients.zig").validateHeader(operation_id);
        const label_id = j.text(request, "labelId");
        const hash = try digest(a, try j.value(a, .{ .cmd = cmd, .labelId = label_id, .name = j.text(request, "name"), .confirmName = j.text(request, "confirmName"), .color = j.get(request, "color") orelse .null }));
        for (self.records[0..self.count]) |*record| if (record.account_index == index) {
            if (std.mem.eql(u8, record.id.slice(), operation_id)) {
                if (!std.mem.eql(u8, &record.hash, &hash) or !std.mem.eql(u8, record.command.slice(), cmd)) return error.OperationConflict;
                return labelReceipt(a, record);
            }
            if (record.items.len == 0 and std.mem.eql(u8, record.outcome, "unknown") and (std.mem.eql(u8, &record.hash, &hash) or (label_id.len > 0 and std.mem.eql(u8, record.label_id.slice(), label_id)))) return labelReceipt(a, record);
        };
        const record = try self.append(index, operation_id, cmd, hash, 4096);
        record.label_id.set(label_id) catch |err| {
            self.discardUnstarted(record);
            return err;
        };
        // Reserve receipt storage before provider entry. The native label
        // dispatcher performs exact name/color/deletion confirmation checks.
        self.reserve(record, 4096) catch |err| {
            self.discardUnstarted(record);
            return err;
        };
        const receipt_buffer = record.arena.allocator().alloc(u8, 2048) catch |err| {
            self.discardUnstarted(record);
            return err;
        };
        var receipt_allocator = std.heap.FixedBufferAllocator.init(receipt_buffer);
        errdefer if (session.mailbox_submitted) self.changed(index);
        record.outcome = "unknown";
        record.error_code = "UnknownOutcome";
        const result = session.dispatch(a, cmd, request) catch |err| {
            const rejected = !session.mailbox_submitted or item_engine.knownRejection(err);
            record.outcome = if (rejected) "rejected" else "unknown";
            record.error_code = @errorName(err);
            if (!rejected) self.changed(index);
            return labelReceipt(a, record);
        };
        return self.finishLabel(a, index, record, &receipt_allocator, cache, cmd, label_id, result) catch return error.UnknownOutcome;
    }
    fn finishLabel(self: *Store, a: A, index: usize, record: *Record, receipt_allocator: *std.heap.FixedBufferAllocator, cache: *cache_module.Store, cmd: []const u8, label_id: []const u8, result: Value) !Value {
        errdefer if (self.labels[index]) |raw| {
            self.allocator.free(raw);
            self.labels[index] = null;
        };
        if (std.mem.eql(u8, cmd, "labels.delete")) {
            record.deleted = true;
            cache.dropLabel(index, label_id) catch cache.clear(index);
        } else {
            const parsed = try j.decode(storage.Label, a, j.get(result, "label") orelse return error.UnknownOutcome);
            const owner = receipt_allocator.allocator();
            record.label = .{ .id = try owner.dupe(u8, parsed.id), .name = try owner.dupe(u8, parsed.name), .type = try owner.dupe(u8, parsed.type), .color = if (parsed.color) |color| .{ .backgroundColor = try owner.dupe(u8, color.backgroundColor), .textColor = try owner.dupe(u8, color.textColor) } else null };
            record.label_id.set(record.label.?.id) catch return error.UnknownOutcome;
        }
        record.outcome = "applied";
        record.error_code = "";
        self.changed(index);
        // Apply the confirmed definition to the retained list; no second
        // provider request is needed to decide whether this write succeeded.
        if (self.labels[index]) |raw| {
            const previous = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
            var labels: std.ArrayList(Value) = .empty;
            var replaced = false;
            for (previous.array.items) |label| {
                if (std.mem.eql(u8, j.text(label, "id"), record.label_id.slice())) {
                    if (record.label) |updated| try labels.append(a, try j.value(a, updated));
                    replaced = true;
                } else try labels.append(a, label);
            }
            if (!replaced) if (record.label) |updated| try labels.append(a, try j.value(a, updated));
            self.saveLabels(index, try j.value(a, labels.items)) catch {
                self.allocator.free(self.labels[index].?);
                self.labels[index] = null;
            };
        }
        return labelReceipt(a, record);
    }
};

const ItemAdapter = struct {
    store: *Store,
    record: *Record,
    position: usize,
    session: *live.Session,
    cache: *cache_module.Store,
    fn hooks(self: *@This()) item_engine.Hooks {
        return .{ .context = self, .labelsFn = labelsFn, .prepareFn = prepareFn, .modifyFn = modifyFn, .commitFn = commitFn, .submittedFn = submittedFn };
    }
    fn labelsFn(raw: *anyopaque, a: A, id: []const u8) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const response = try self.session.dispatch(a, "mail.labels", try j.value(a, .{ .messageId = id }));
        return j.decode([]const []const u8, a, j.get(response, "labels") orelse return error.InvalidProviderResponse);
    }
    fn prepareFn(raw: *anyopaque, id: []const u8, before: []const []const u8, delta: triage.Delta, undoing: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const item = &self.record.items[self.position];
        if (undoing) item.errorCode = "UnknownOutcome" else {
            var arena: std.heap.ArenaAllocator = .init(self.store.allocator);
            defer arena.deinit();
            const inverse = try triage.inverse(arena.allocator(), id, before, delta);
            const add = try self.store.copyLabels(self.record, inverse.addLabels);
            const remove = try self.store.copyLabels(self.record, inverse.removeLabels);
            item.addLabels = add;
            item.removeLabels = remove;
            item.outcome = "unknown";
            item.errorCode = "UnknownOutcome";
        }
    }
    fn modifyFn(raw: *anyopaque, a: A, id: []const u8, _: []const []const u8, delta: triage.Delta) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const response = try self.session.dispatch(a, "mail.modify-labels", try j.value(a, .{ .messageId = id, .addLabels = delta.add, .removeLabels = delta.remove }));
        return j.decode([]const []const u8, a, j.get(response, "labels") orelse return error.UnknownOutcome);
    }
    fn submittedFn(raw: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.session.mailbox_submitted;
    }
    fn commitFn(raw: *anyopaque, undoing: bool, labels: ?[]const []const u8, failure: ?anyerror, preflight: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const item = &self.record.items[self.position];
        if (failure) |err| {
            self.record.failures[self.position] = err;
            const rejected = preflight or item_engine.knownRejection(err);
            item.errorCode = if (undoing and !rejected) "UnknownOutcome" else @errorName(err);
            if (!undoing) item.outcome = if (rejected) "rejected" else "unknown";
            if (!rejected) self.store.changed(self.record.account_index);
            return;
        }
        item.errorCode = "";
        self.record.failures[self.position] = null;
        if (undoing) item.restored = true else item.outcome = "applied";
        if (labels) |memberships| self.cache.applyLabels(self.record.account_index, item.messageId, memberships) catch {
            // The provider success remains known even if local cache admission
            // fails; stale memberships must not masquerade as the receipt.
            self.cache.clear(self.record.account_index);
            item.errorCode = "BrowserCacheUnavailable";
        };
        self.store.changed(self.record.account_index);
    }
};
