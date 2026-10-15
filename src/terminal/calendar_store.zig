//! Calendar receipts and snapshots use the account Store's private documents.
//! Each callback holds the existing account lock only for its local transaction.
//! The Store selects legacy private files or sealed vault objects; no provider
//! requests execute while these transactions hold an account lock.
const std = @import("std");
const storage = @import("store.zig");
const mail = @import("types.zig");
const t = @import("calendar_types.zig");
const plan = @import("calendar_plan.zig");
const svc = @import("calendar_service.zig");

pub const max_identities = 256;
pub const state_bytes = 4 * 1024 * 1024;
pub const max_snapshots = 4;
pub const cache_bytes = 8 * 1024 * 1024;
const state_name = "calendar-state.json";
const cache_name = "calendar-agenda.json";
const Entry = struct {
    identity: plan.Identity,
    state: svc.State = .{},
    review: ?svc.Review = null,
    /// Ordinary event IDs and ETags prevent duplicate writes independently of
    /// invitation UID tracking. Their settled receipts may be pruned, whereas
    /// invitation identities survive a provider-side deletion.
    ordinary: bool = false,
    receipt_hash: ?[32]u8 = null,
    /// Older journals had no reservation. Do not retroactively charge their
    /// unknown entries and block the very finalization that frees that space.
    receipt_reserved: bool = false,
};
const StateFile = struct { schema: u8 = 1, account: []const u8, entries: []Entry = &.{} };
const CacheFile = struct { schema: u8 = 1, account: []const u8, snapshots: []const t.Snapshot = &.{}, calendars: ?svc.CalendarList = null };

// A final invitation receipt may add the bounded tracked identity plus a
// provider ID (each at most 1024 bytes), including worst-case JSON escaping.
// Ordinary receipts shrink after completion. Every unknown claim reserves this
// headroom before dispatch; subsequent reviews cannot consume it.
pub const final_receipt_reserve = 16 * 1024;

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    root: []const u8,
    account: []const u8,
    options: mail.Options,
    access: @import("store_access.zig").Access = .{},

    pub fn persistence(self: *Host) svc.Persistence {
        return .{ .context = self, .journal = .{ .context = self, .claimFn = claim, .recordFn = record, .retryFn = retry }, .loadFn = load, .preserveFn = preserve };
    }
    pub fn cache(self: *Host) svc.Cache {
        return .{ .context = self, .loadFn = cacheLoad, .saveFn = cacheSave, .loadCalendarsFn = calendarsLoad, .saveCalendarsFn = calendarsSave };
    }
    fn cast(context: *anyopaque) *Host {
        return @ptrCast(@alignCast(context));
    }
    fn check(self: *Host, target: t.Target) !void {
        try target.validate();
        if (!std.ascii.eqlIgnoreCase(target.account, self.account)) return error.CalendarAccountMismatch;
    }
    fn open(self: *Host, a: std.mem.Allocator) !storage.Store {
        return self.access.open(self.io, a, self.root, self.account, self.options, false);
    }
    fn readState(self: *Host, store: *storage.Store, a: std.mem.Allocator) !StateFile {
        const raw = try store.readDocument(a, state_name, state_bytes) orelse return .{ .account = self.account };
        var state = try std.json.parseFromSliceLeaky(StateFile, a, raw, .{ .allocate = .alloc_if_needed });
        if (state.schema != 1 or !std.mem.eql(u8, state.account, self.account) or state.entries.len > max_identities) return error.CalendarStoreCorrupt;
        for (state.entries, 0..) |entry, index| {
            try self.check(entry.identity.target);
            try t.text(entry.identity.uid, 1024, false);
            for (state.entries[0..index]) |prior| if (entry.identity.eql(prior.identity)) return error.CalendarStoreCorrupt;
            if (entry.state.tracked) |tracked| if (!tracked.identity.eql(entry.identity)) return error.CalendarStoreCorrupt;
            if (entry.state.operation) |operation| {
                try operation.intent.validate();
                if (!operation.intent.identity.eql(entry.identity)) return error.CalendarStoreCorrupt;
            }
            if (entry.review) |review| {
                try review.intent.validate();
                if (!review.intent.identity.eql(entry.identity) or !review.calendar.target.eql(entry.identity.target) or
                    !std.mem.eql(u8, review.source.account, self.account) or !std.mem.eql(u8, review.source.uid, entry.identity.uid) or
                    review.source.source.len > t.Limits.source_bytes) return error.CalendarStoreCorrupt;
                const bound = try review.request.bindIntent(review.intent);
                if (!bound.eql(review.intent)) return error.CalendarStoreCorrupt;
            }
            if (entry.receipt_hash != null and (entry.state.operation == null or entry.state.operation.?.state == .unknown)) return error.CalendarStoreCorrupt;
        }
        compact(&state);
        return state;
    }
    fn writeState(store: *storage.Store, a: std.mem.Allocator, state: StateFile) !void {
        if (@import("gmail_decode.zig").serializedBytes(state) > state_bytes) return error.CalendarStoreFull;
        try store.writeDocument(state_name, try std.json.Stringify.valueAlloc(a, state, .{}));
    }
    fn findEntry(state: *StateFile, identity: plan.Identity) ?*Entry {
        for (state.entries) |*value| if (value.identity.eql(identity)) return value;
        return null;
    }
    fn compact(state: *StateFile) void {
        for (state.entries) |*entry| {
            if (entry.review) |review| {
                if (review.ordinary_event != null) entry.ordinary = true;
                if (entry.state.operation) |operation| if (operation.state != .unknown and operation.intent.eql(review.intent)) {
                    entry.receipt_hash = review.review_hash;
                    entry.review = null;
                };
            }
            if (entry.state.operation != null and entry.state.operation.?.state != .unknown) entry.receipt_reserved = false;
            if (entry.ordinary and entry.state.operation != null and entry.state.operation.?.state != .unknown) entry.state.tracked = null;
        }
    }
    fn evictable(entry: Entry) bool {
        return entry.state.tracked == null and (entry.state.operation == null or entry.state.operation.?.state != .unknown);
    }
    fn reservedBytes(state: StateFile) usize {
        var count: usize = 0;
        for (state.entries) |entry| if (entry.state.operation) |operation| {
            if (operation.state == .unknown and entry.receipt_reserved) count += 1;
        };
        return count * final_receipt_reserve;
    }
    fn removeAt(state: *StateFile, index: usize) void {
        std.mem.copyForwards(Entry, state.entries[index .. state.entries.len - 1], state.entries[index + 1 ..]);
        state.entries = state.entries[0 .. state.entries.len - 1];
    }
    /// Admission accounts for every in-flight final receipt. A new draft may
    /// evict old unclaimed reviews and settled ordinary receipts by bytes as
    /// well as count, but never its own review or another pending operation.
    fn fit(state: *StateFile, protected: plan.Identity) !void {
        compact(state);
        while (state.entries.len > max_identities or @import("gmail_decode.zig").serializedBytes(state.*) + reservedBytes(state.*) > state_bytes) {
            var index = state.entries.len;
            var removed = false;
            while (index > 0) {
                index -= 1;
                const candidate = state.entries[index];
                if (candidate.identity.eql(protected) or !evictable(candidate)) continue;
                removeAt(state, index);
                removed = true;
                break;
            }
            if (!removed) return error.CalendarStoreFull;
        }
    }
    /// Recent reviews lead the table. Unknown outcomes and tracked invitation
    /// identities are never pruned: provider deletion must not resurrect mail.
    fn ensure(state: *StateFile, a: std.mem.Allocator, identity: plan.Identity) !*Entry {
        for (state.entries, 0..) |existing, index| if (existing.identity.eql(identity)) {
            std.mem.copyBackwards(Entry, state.entries[1 .. index + 1], state.entries[0..index]);
            state.entries[0] = existing;
            return &state.entries[0];
        };
        var remove: ?usize = null;
        if (state.entries.len == max_identities) {
            var index = state.entries.len;
            while (index > 0) {
                index -= 1;
                const candidate = state.entries[index];
                if (evictable(candidate)) {
                    remove = index;
                    break;
                }
            }
            if (remove == null) return error.CalendarStoreFull;
        }
        var values: std.ArrayList(Entry) = .empty;
        try values.append(a, .{ .identity = identity });
        for (state.entries, 0..) |value, index| {
            if (remove != null and remove.? == index) continue;
            try values.append(a, value);
        }
        if (values.items.len > max_identities) return error.CalendarStoreFull;
        state.entries = values.items;
        return &state.entries[0];
    }
    fn load(context: *anyopaque, out: std.mem.Allocator, identity: plan.Identity) anyerror!svc.State {
        const self = cast(context);
        try self.check(identity.target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        var state = try self.readState(&store, a);
        const current = findEntry(&state, identity) orelse return .{};
        return clone(svc.State, out, current.state);
    }
    pub fn loadReview(self: *Host, out: std.mem.Allocator, target: t.Target, operation_id: []const u8) !svc.Review {
        try self.check(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        const state = try self.readState(&store, a);
        for (state.entries) |value| if (value.review) |review| {
            if (review.intent.identity.target.eql(target) and std.mem.eql(u8, review.intent.operation_id, operation_id)) return clone(svc.Review, out, review);
        };
        return error.CalendarReviewNotFound;
    }
    pub fn loadReceipt(self: *Host, out: std.mem.Allocator, target: t.Target, operation_id: []const u8) !?svc.Receipt {
        try self.check(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        const state = try self.readState(&store, a);
        for (state.entries) |entry| if (entry.receipt_hash) |hash| {
            const operation = entry.state.operation orelse return error.CalendarStoreCorrupt;
            if (operation.intent.identity.target.eql(target) and std.mem.eql(u8, operation.intent.operation_id, operation_id))
                return try clone(svc.Receipt, out, .{ .operation = operation, .review_hash = hash, .ordinary = entry.ordinary });
        };
        return null;
    }
    pub fn loadPending(self: *Host, out: std.mem.Allocator, target: t.Target, event_id: []const u8) !?svc.Pending {
        try self.check(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        const state = try self.readState(&store, a);
        for (state.entries) |entry| {
            const operation = entry.state.operation orelse continue;
            if (operation.state != .unknown or !operation.intent.identity.target.eql(target)) continue;
            const review = entry.review orelse continue;
            if (review.ordinary_event == null) continue;
            if (if (event_id.len == 0) operation.intent.kind != .insert_event else !std.mem.eql(u8, event_id, operation.intent.event_id)) continue;
            return try clone(svc.Pending, out, .{ .review = review, .operation = operation });
        }
        return null;
    }
    fn preserve(context: *anyopaque, review: svc.Review) anyerror!void {
        const self = cast(context);
        try self.check(review.intent.identity.target);
        try review.intent.validate();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        var state = try self.readState(&store, a);
        for (state.entries) |prior| {
            if (prior.review) |saved| if (std.mem.eql(u8, saved.intent.operation_id, review.intent.operation_id)) {
                if (!saved.intent.eql(review.intent) or !std.mem.eql(u8, &saved.review_hash, &review.review_hash)) return error.OperationConflict;
            };
            if (prior.state.operation) |operation| {
                if (std.mem.eql(u8, operation.intent.operation_id, review.intent.operation_id) and !operation.intent.eql(review.intent)) return error.OperationConflict;
                if (prior.identity.eql(review.intent.identity) and operation.state == .unknown and !operation.intent.eql(review.intent)) return error.CalendarOperationPending;
                if (operation.state == .unknown and operation.intent.kind == .insert_event and review.intent.kind == .insert_event and prior.identity.target.eql(review.intent.identity.target) and !operation.intent.eql(review.intent)) return error.CalendarOperationPending;
            }
        }
        const current = try ensure(&state, a, review.intent.identity);
        current.review = review;
        current.ordinary = review.ordinary_event != null;
        try fit(&state, review.intent.identity);
        try writeState(&store, a, state);
    }
    fn claim(context: *anyopaque, intent: plan.Intent) anyerror!plan.Claim {
        const self = cast(context);
        try self.check(intent.identity.target);
        try intent.validate();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        var state = try self.readState(&store, a);
        if (intent.kind == .insert_event) for (state.entries) |prior| if (prior.state.operation) |operation| {
            if (operation.state == .unknown and operation.intent.kind == .insert_event and prior.identity.target.eql(intent.identity.target) and !operation.intent.eql(intent)) return error.CalendarOperationPending;
        };
        const current = findEntry(&state, intent.identity) orelse return error.CalendarReviewNotFound;
        const review = current.review orelse return error.CalendarReviewNotFound;
        if (!review.intent.eql(intent)) return error.OperationConflict;
        if (current.state.operation) |operation| {
            if (std.mem.eql(u8, operation.intent.operation_id, intent.operation_id)) {
                if (!operation.intent.eql(intent)) return error.OperationConflict;
                return .{ .operation = try clone(plan.Operation, self.result_allocator, operation), .fresh = false };
            }
            if (operation.state == .unknown) return error.CalendarOperationPending;
        }
        // Another process may have completed an action after Service.apply's
        // read/lookup but before this locked claim. Recheck the durable target
        // and version here; only this transaction can grant fresh dispatch.
        if (review.ordinary_event != null) {
            if (current.state.tracked) |tracked| if (intent.kind == .insert_event or !std.mem.eql(u8, intent.event_id, tracked.event_id)) return error.CalendarReviewStale;
        } else if (current.state.tracked) |tracked| {
            if (intent.kind == .import_event or (if (review.response_only) intent.version.order(tracked.version) == .lt else intent.version.order(tracked.version) != .gt) or !std.mem.eql(u8, intent.event_id, tracked.event_id)) return error.CalendarReviewStale;
        } else if (intent.kind != .import_event and !review.response_only) return error.CalendarReviewStale;
        const operation: plan.Operation = .{ .intent = intent };
        current.state.operation = operation;
        current.receipt_hash = null;
        current.receipt_reserved = true;
        try fit(&state, intent.identity);
        try writeState(&store, a, state);
        return .{ .operation = try clone(plan.Operation, self.result_allocator, operation), .fresh = true };
    }
    fn record(context: *anyopaque, operation: plan.Operation) anyerror!void {
        const self = cast(context);
        try self.check(operation.intent.identity.target);
        try operation.intent.validate();
        try t.text(operation.provider_id, 1024, operation.state != .applied);
        try t.text(operation.error_code, 128, true);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        var state = try self.readState(&store, a);
        const current = findEntry(&state, operation.intent.identity) orelse return error.CalendarOperationNotFound;
        const previous = current.state.operation orelse return error.CalendarOperationNotFound;
        if (!previous.intent.eql(operation.intent) or operation.attempt > previous.attempt) return error.OperationConflict;
        // A late refusal from an earlier attempt cannot settle a newer send.
        // Positive provider proof, however, resolves the same immutable write.
        if (operation.attempt < previous.attempt and operation.state != .applied) return error.OperationConflict;
        if (previous.state != .unknown and (previous.state != operation.state or !std.mem.eql(u8, previous.provider_id, operation.provider_id))) return error.OperationConflict;
        if (operation.state == .applied) {
            try t.text(operation.provider_id, 1024, false);
            current.state.tracked = .{ .identity = operation.intent.identity, .event_id = operation.provider_id, .version = operation.intent.version, .source_hash = operation.intent.source_hash };
        }
        var final_operation = operation;
        final_operation.attempt = previous.attempt;
        current.state.operation = final_operation;
        try fit(&state, operation.intent.identity);
        try writeState(&store, a, state);
    }
    fn retry(context: *anyopaque, intent: plan.Intent, next_attempt: u32) anyerror!plan.Claim {
        const self = cast(context);
        try self.check(intent.identity.target);
        try intent.validate();
        if (next_attempt == 0 or next_attempt > 1_000_000) return error.InvalidCalendarRetry;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        var state = try self.readState(&store, a);
        const entry = findEntry(&state, intent.identity) orelse return error.CalendarOperationNotFound;
        var operation = entry.state.operation orelse return error.CalendarOperationNotFound;
        if (!operation.intent.eql(intent)) return error.OperationConflict;
        if (operation.state != .unknown or next_attempt <= operation.attempt)
            return .{ .operation = try clone(plan.Operation, self.result_allocator, operation), .fresh = false };
        if (next_attempt != operation.attempt + 1) return error.InvalidCalendarRetry;
        const review = entry.review orelse return error.CalendarReviewNotFound;
        if (review.ordinary_event == null or !review.intent.eql(intent)) return error.OperationConflict;
        operation.attempt = next_attempt;
        entry.state.operation = operation;
        entry.receipt_reserved = true;
        try fit(&state, intent.identity);
        try writeState(&store, a, state);
        return .{ .operation = try clone(plan.Operation, self.result_allocator, operation), .fresh = true };
    }
    fn readCache(self: *Host, store: *storage.Store, a: std.mem.Allocator) !CacheFile {
        const raw = try store.readDocument(a, cache_name, cache_bytes) orelse return .{ .account = self.account };
        const file = try std.json.parseFromSliceLeaky(CacheFile, a, raw, .{ .allocate = .alloc_if_needed });
        if (file.schema != 1 or !std.mem.eql(u8, file.account, self.account) or file.snapshots.len > max_snapshots) return error.CalendarStoreCorrupt;
        for (file.snapshots) |snapshot| {
            try self.check(snapshot.target);
            try snapshot.validate();
            if (!snapshot.complete or snapshot.stale) return error.CalendarStoreCorrupt;
        }
        return file;
    }
    fn cacheLoad(context: *anyopaque, out: std.mem.Allocator, target: t.Target, window: t.Window) anyerror!?t.Snapshot {
        const self = cast(context);
        try self.check(target);
        try window.validate();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = self.access.open(self.io, a, self.root, self.account, self.options, true) catch |err| if (err == error.FileNotFound) return null else return err;
        defer store.close();
        const cached = try self.readCache(&store, a);
        for (cached.snapshots) |snapshot| if (snapshot.target.eql(target) and sameWindow(snapshot.window, window)) return try clone(t.Snapshot, out, snapshot);
        return null;
    }
    fn cacheSave(context: *anyopaque, snapshot: t.Snapshot) anyerror!void {
        const self = cast(context);
        try self.check(snapshot.target);
        try snapshot.validate();
        if (!snapshot.complete or snapshot.stale) return error.CalendarCacheMismatch;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        const previous = try self.readCache(&store, a);
        var values: [max_snapshots]t.Snapshot = undefined;
        values[0] = snapshot;
        var count: usize = 1;
        for (previous.snapshots) |old| {
            if (old.target.eql(snapshot.target) and sameWindow(old.window, snapshot.window)) continue;
            if (count == max_snapshots) break;
            values[count] = old;
            count += 1;
        }
        var file: CacheFile = .{ .account = self.account, .snapshots = values[0..count], .calendars = previous.calendars };
        while (@import("gmail_decode.zig").serializedBytes(file) > cache_bytes) {
            if (count == 1) return error.CalendarSnapshotTooLarge;
            count -= 1;
            file.snapshots = values[0..count];
        }
        try store.writeDocument(cache_name, try std.json.Stringify.valueAlloc(a, file, .{}));
    }

    fn validateCalendars(self: *Host, values: svc.CalendarList) !void {
        if (!values.complete or values.calendars.len > t.Limits.calendars) return error.CalendarCacheMismatch;
        for (values.calendars, 0..) |calendar, index| {
            try self.check(calendar.target);
            try t.text(calendar.summary, 4096, true);
            try t.time.validateZoneName(calendar.time_zone);
            for (values.calendars[0..index]) |previous| if (previous.target.eql(calendar.target)) return error.CalendarCacheMismatch;
        }
    }
    fn calendarsLoad(context: *anyopaque, out: std.mem.Allocator) anyerror!?svc.CalendarList {
        const self = cast(context);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = self.access.open(self.io, a, self.root, self.account, self.options, true) catch |err| if (err == error.FileNotFound) return null else return err;
        defer store.close();
        const saved = (try self.readCache(&store, a)).calendars orelse return null;
        try self.validateCalendars(saved);
        return try clone(svc.CalendarList, out, saved);
    }
    fn calendarsSave(context: *anyopaque, values: svc.CalendarList) anyerror!void {
        const self = cast(context);
        try self.validateCalendars(values);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        var file = try self.readCache(&store, a);
        file.calendars = .{ .calendars = values.calendars, .complete = true };
        while (@import("gmail_decode.zig").serializedBytes(file) > cache_bytes) {
            if (file.snapshots.len == 0) return error.CalendarSnapshotTooLarge;
            file.snapshots = file.snapshots[0 .. file.snapshots.len - 1];
        }
        try store.writeDocument(cache_name, try std.json.Stringify.valueAlloc(a, file, .{}));
    }
    /// Only already-downloaded detail is available offline. Do not synthesize
    /// an event GET or claim that an absent event was deleted by its provider.
    pub fn cachedEvent(self: *Host, out: std.mem.Allocator, target: t.Target, event_id: []const u8) !?t.Event {
        try self.check(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = self.access.open(self.io, a, self.root, self.account, self.options, true) catch |err| if (err == error.FileNotFound) return null else return err;
        defer store.close();
        const file = try self.readCache(&store, a);
        var newest: ?t.Event = null;
        var fetched_at: i64 = -1;
        for (file.snapshots) |snapshot| {
            if (!snapshot.target.eql(target) or snapshot.fetched_at_ms < fetched_at) continue;
            for (snapshot.events) |event| if (std.mem.eql(u8, event.id, event_id)) {
                newest = event;
                fetched_at = snapshot.fetched_at_ms;
                break;
            };
        }
        return if (newest) |event| try clone(t.Event, out, event) else null;
    }
};

fn sameWindow(a: t.Window, b: t.Window) bool {
    return a.start_ms == b.start_ms and a.end_ms == b.end_ms and std.mem.eql(u8, a.time_zone, b.time_zone);
}
fn clone(comptime T: type, a: std.mem.Allocator, value: T) !T {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .allocate = .alloc_if_needed });
}

test "calendar store: bounded identity retention never discards an unknown outcome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };
    var state: StateFile = .{ .account = target.account };
    for (0..max_identities) |index| {
        const identity: plan.Identity = .{ .target = target, .uid = try std.fmt.allocPrint(a, "event-{d}", .{index}) };
        const value = try Host.ensure(&state, a, identity);
        value.state.operation = .{ .intent = .{ .operation_id = identity.uid, .identity = identity, .version = .{ .sequence = 1, .dtstamp_ms = 1 }, .kind = .import_event, .source_hash = @splat(1), .payload_hash = @splat(2) } };
    }
    const newcomer: plan.Identity = .{ .target = target, .uid = "new-event" };
    try std.testing.expectError(error.CalendarStoreFull, Host.ensure(&state, a, newcomer));
    try std.testing.expectEqual(max_identities, state.entries.len);
    state.entries[max_identities - 2].state.operation.?.state = .rejected;
    const removed = state.entries[max_identities - 2].identity;
    const oldest_unknown = state.entries[max_identities - 1].identity;
    _ = try Host.ensure(&state, a, newcomer);
    try std.testing.expect(Host.findEntry(&state, removed) == null);
    try std.testing.expect(Host.findEntry(&state, oldest_unknown) != null);
    _ = try Host.ensure(&state, a, oldest_unknown);
    try std.testing.expect(state.entries[0].identity.eql(oldest_unknown));
    try std.testing.expectEqual(max_identities, state.entries.len);
    // Settled imports still carry a durable identity even if the remote event
    // has since been removed. They must survive pressure just like unknowns.
    for (state.entries) |*value| {
        value.state.tracked = .{ .identity = value.identity, .event_id = "tracked-event", .version = .{ .sequence = 1, .dtstamp_ms = 1 }, .source_hash = @splat(1) };
        value.state.operation = null;
    }
    try std.testing.expectError(error.CalendarStoreFull, Host.ensure(&state, a, .{ .target = target, .uid = "cannot-evict-tracked" }));
    try std.testing.expect(Host.findEntry(&state, oldest_unknown).?.state.tracked != null);
}

test "calendar store: final reservation exceeds maximum escaped receipt growth and legacy unknowns are not retroactively charged" {
    const quoted: [1024]u8 = @splat('"');
    const account_text: [254]u8 = @splat('a');
    const operation_text: [128]u8 = @splat('a');
    const error_text: [128]u8 = @splat('"');
    const identity: plan.Identity = .{ .target = .{ .account = &account_text, .calendar_id = &quoted }, .uid = &quoted, .recurrence_key = &quoted };
    const intent: plan.Intent = .{ .operation_id = &operation_text, .identity = identity, .version = .{ .sequence = std.math.maxInt(u32), .dtstamp_ms = std.math.minInt(i64) }, .kind = .update_event, .source_hash = @splat(255), .payload_hash = @splat(255), .event_id = &quoted, .expected_etag = &quoted };
    var entries = [_]Entry{.{ .identity = identity, .state = .{ .operation = .{ .intent = intent } } }};
    const state: StateFile = .{ .account = identity.target.account, .entries = &entries };
    try std.testing.expectEqual(@as(usize, 0), Host.reservedBytes(state));
    entries[0].receipt_reserved = true;
    try std.testing.expectEqual(@as(usize, final_receipt_reserve), Host.reservedBytes(state));
    const initial_bytes = @import("gmail_decode.zig").serializedBytes(entries[0]);
    entries[0].state.operation.?.state = .applied;
    entries[0].state.operation.?.provider_id = &quoted;
    entries[0].state.operation.?.error_code = &error_text;
    entries[0].state.operation.?.attempt = 1_000_000;
    entries[0].state.tracked = .{ .identity = identity, .event_id = &quoted, .version = intent.version, .source_hash = intent.source_hash };
    entries[0].receipt_hash = @splat(255);
    try std.testing.expect(@import("gmail_decode.zig").serializedBytes(entries[0]) - initial_bytes < final_receipt_reserve);
}
