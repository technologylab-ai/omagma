const std = @import("std");
const storage = @import("terminal/store.zig");
const persistence = @import("terminal/calendar_store.zig");
const service = @import("terminal/calendar_service.zig");
const provider = @import("terminal/calendar_provider.zig");
const plan = @import("terminal/calendar_plan.zig");
const history = @import("terminal/calendar_identity_history.zig");
const t = @import("terminal/calendar_types.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;
const account = "self@example.test";
const target: t.Target = .{ .account = account, .calendar_id = "self@example.test" };
const calendar: t.Calendar = .{ .target = target, .summary = "Calendar capacity", .time_zone = "UTC", .access = .owner, .primary = true, .owned_scope_verified = true };
const Fault = @TypeOf(@as(storage.Store, undefined).history_fault);

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    key: @import("terminal/vault_types.zig").DataKey,
    workspace: @import("terminal/vault_types.zig").StreamWorkspace,
    owner: ?@import("terminal/vault_catalog.zig").Owner = null,
    selected: ?@import("terminal/vault_catalog.zig").Account = null,
    fault: Fault = .none,
    fn init(self: *Fixture, encrypted: bool) !void {
        self.owner = null;
        self.selected = null;
        self.fault = .none;
        self.tmp = std.testing.tmpDir(.{});
        self.arena = .init(std.testing.allocator);
        const a = self.arena.allocator();
        const base = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        self.root = try std.fmt.allocPrint(a, "{s}/cache", .{base});
        self.key = try @import("terminal/vault_crypto.zig").createDataKey(io);
        if (encrypted) {
            const descriptor: @import("terminal/vault_header.zig").Header = .{ .vault_id = self.key.vault_id, .key_id = self.key.key_id, .root_record = try @import("terminal/vault_storage.zig").Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
            self.owner = try @import("terminal/vault_catalog.zig").Owner.create(io, try std.fmt.allocPrint(a, "{s}/vault", .{base}), descriptor, &self.key, &self.workspace);
            try self.owner.?.addAccount(account, try storage.Store.initialVaultIndex(a, account, .{ .fixtures = true }), (@import("terminal/types.zig").Options{}).disk_limit);
            self.selected = try self.owner.?.openAccount(account);
        }
    }
    fn close(self: *Fixture) void {
        if (self.selected) |*selected| selected.close();
        if (self.owner) |*owner| owner.close();
        self.key.wipe();
        self.workspace.wipe();
        self.arena.deinit();
        self.tmp.cleanup();
    }
    fn open(context: *anyopaque, a: std.mem.Allocator, address: []const u8, readonly: bool) !storage.Store {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, address, account)) return error.CalendarAccountMismatch;
        var store = if (self.selected) |*selected| try storage.Store.openVault(io, a, selected, .{ .fixtures = true }, readonly) else if (readonly) try storage.Store.openCached(io, a, self.root, account, .{ .fixtures = true }) else try storage.Store.open(io, a, self.root, account, .{ .fixtures = true });
        store.history_fault = self.fault;
        return store;
    }
    fn host(self: *Fixture, a: std.mem.Allocator) persistence.Host {
        return .{ .io = io, .allocator = std.testing.allocator, .result_allocator = a, .root = self.root, .account = account, .options = .{ .fixtures = true }, .access = .{ .context = self, .openFn = open } };
    }
};
const Oracle = struct {
    fixture: *Fixture,
    writes: usize = 0,
    first_event: []const u8 = "",
    visible: bool = false,
    lost_next: bool = false,
    fault_on_write: Fault = .none,
    last_id: []const u8 = "",
    fn send(context: *anyopaque, a: std.mem.Allocator, request: provider.Request) !service.Response {
        const self: *Oracle = @ptrCast(@alignCast(context));
        if (request.kind == .event_lookup) return .{ .account = account, .status = 200, .body = if (self.visible) try std.fmt.allocPrint(a, "{{\"items\":[{s}]}}", .{self.first_event}) else "{\"items\":[]}" };
        if (request.kind == .event_get) return .{ .account = account, .status = if (self.visible) 200 else 404, .body = if (self.visible) self.first_event else "{}" };
        if (!request.kind.mutating()) return error.UnexpectedCalendarRequest;
        self.writes += 1;
        if (self.lost_next) {
            self.lost_next = false;
            return error.NetworkFailure;
        }
        self.fixture.fault = self.fault_on_write;
        self.fault_on_write = .none;
        if (request.kind == .cancel_event) {
            self.visible = false;
            return .{ .account = account, .status = 204, .body = "" };
        }
        var event = try std.json.parseFromSliceLeaky(j.Value, a, request.body orelse return error.MissingRequestBody, .{ .allocate = .alloc_if_needed });
        if (request.kind == .update_event) {
            const patch = event;
            event = try std.json.parseFromSliceLeaky(j.Value, a, self.first_event, .{ .allocate = .alloc_if_needed });
            var fields = patch.object.iterator();
            while (fields.next()) |field| try event.object.put(a, field.key_ptr.*, field.value_ptr.*);
        }
        const id = if (request.kind == .update_event) j.text(try std.json.parseFromSliceLeaky(j.Value, a, self.first_event, .{}), "id") else try std.fmt.allocPrint(a, "provider-{d}", .{self.writes});
        self.last_id = try self.fixture.arena.allocator().dupe(u8, id);
        try event.object.put(a, "id", .{ .string = id });
        try event.object.put(a, "etag", .{ .string = try std.fmt.allocPrint(a, "\"revision-{d}\"", .{self.writes}) });
        try event.object.put(a, "status", .{ .string = "confirmed" });
        try event.object.put(a, "privateCopy", .{ .bool = true });
        const raw = try j.encodeAlloc(a, event, .{});
        if (std.mem.eql(u8, j.text(event, "iCalUID"), "capacity-0@example.test")) self.first_event = try self.fixture.arena.allocator().dupe(u8, raw);
        return .{ .account = account, .status = 200, .body = raw };
    }
    fn instance(self: *Oracle, a: std.mem.Allocator, host: *persistence.Host) service.Service {
        return .{ .a = a, .grants = .{ .account = account, .calendar_list = true, .read_events = true, .write_owned = true }, .transport = .{ .context = self, .sendFn = send }, .persistence = host.persistence(), .now_ms = 0 };
    }
};
fn source(a: std.mem.Allocator, id: usize, sequence: usize, cancel: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Omagma synthetic capacity//EN\r\nMETHOD:{s}\r\nBEGIN:VEVENT\r\nUID:capacity-{d}@example.test\r\nDTSTAMP:20261001T120000Z\r\nSEQUENCE:{d}\r\nDTSTART:20261013T140000Z\r\nDTEND:20261013T150000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nSUMMARY:Calendar capacity {d}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", .{ if (cancel) "CANCEL" else "REQUEST", id, sequence, id });
}
fn prepare(a: std.mem.Allocator, oracle: *Oracle, host: *persistence.Host, id: usize, sequence: usize, cancel: bool) !service.Review {
    const instance = oracle.instance(a, host);
    const planned = try instance.invitationPlan(calendar, try source(a, id, sequence, cancel), &.{}, .{});
    return instance.prepareReview(planned, try std.fmt.allocPrint(a, "calendar-{d}-{d}", .{ id, sequence }));
}
fn copy(comptime T: type, a: std.mem.Allocator, input: T) !T {
    return std.json.parseFromSliceLeaky(T, a, try j.encodeAlloc(a, input, .{}), .{ .allocate = .alloc_if_needed });
}

// Long lifecycle qualification runs only through test-native-history-stress.
pub fn thousandCalendarIdentityScenario() !void {
    for ([_]bool{ false, true }) |encrypted| {
        const fixture = try std.testing.allocator.create(Fixture);
        defer std.testing.allocator.destroy(fixture);
        try fixture.init(encrypted);
        defer fixture.close();
        const a = fixture.arena.allocator();
        var oracle: Oracle = .{ .fixture = fixture };
        var reopened = fixture.host(a);
        const pending = try prepare(a, &oracle, &reopened, 9000, 1, false);
        oracle.lost_next = true;
        try std.testing.expectEqual(.unknown, (try oracle.instance(a, &reopened).apply(pending, pending.confirmation())).operation.state);
        var first: service.Review = undefined;
        var legacy_entries: std.ArrayList(history.Entry) = .empty;
        for (0..1001) |id| {
            var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer phase.deinit();
            const temporary = phase.allocator();
            var current = fixture.host(temporary);
            const review = try prepare(temporary, &oracle, &current, id, 1, false);
            const applied = try oracle.instance(temporary, &current).apply(review, review.confirmation());
            try std.testing.expectEqual(.applied, applied.operation.state);
            if (id == 0) first = try copy(service.Review, a, review);
            if (id < 255) try legacy_entries.append(a, try copy(history.Entry, a, .{ .identity = review.intent.identity, .state = try current.persistence().load(temporary, review.intent.identity), .receipt_hash = review.review_hash }));
            if (id == 254) {
                // Recreate the exact old-format full 256-identity document
                // from genuine imports, including its protected unknown.
                try legacy_entries.append(a, .{ .identity = pending.intent.identity, .state = try reopened.persistence().load(a, pending.intent.identity), .review = pending, .receipt_reserved = true });
                try std.testing.expectEqual(@as(usize, 256), legacy_entries.items.len);
                var old = try Fixture.open(fixture, temporary, account, false);
                defer old.close();
                try old.writeDocument("calendar-state.json", try j.encodeAlloc(temporary, .{ .schema = @as(u8, 1), .account = account, .entries = legacy_entries.items }, .{}));
            }
        }
        const after_import = oracle.writes;
        try std.testing.expectEqual(@as(usize, 1002), after_import);
        const backend = reopened.persistence();
        try std.testing.expectEqual(.unknown, (try backend.load(a, pending.intent.identity)).operation.?.state);
        try std.testing.expectEqualStrings(pending.source.source, (try reopened.loadReview(a, target, pending.intent.operation_id)).source.source);
        try std.testing.expectEqual(.applied, (try oracle.instance(a, &reopened).apply(first, first.confirmation())).operation.state);
        try std.testing.expectEqual(after_import, oracle.writes);
        try std.testing.expectEqualStrings(first.intent.operation_id, (try reopened.loadReceipt(a, target, first.intent.operation_id)).?.operation.intent.operation_id);
        var same_account = first.intent.identity;
        same_account.target.account = "SELF@example.test";
        try std.testing.expect((try backend.load(a, same_account)).tracked != null);
        const absent = try oracle.instance(a, &reopened).invitationPlan(calendar, first.source.source, &.{}, .{});
        try std.testing.expect(absent.decision == .identity_conflict);
        var foreign = first.intent.identity;
        foreign.target.calendar_id = "other-calendar";
        try std.testing.expect((try backend.load(a, foreign)).tracked == null);
        try std.testing.expect(try reopened.loadReceipt(a, foreign.target, first.intent.operation_id) == null);
        foreign.target.account = "other@example.test";
        try std.testing.expectError(error.CalendarAccountMismatch, backend.load(a, foreign));
        var recurrence = first.intent.identity;
        recurrence.recurrence_key = "20261014T140000Z";
        try std.testing.expect((try backend.load(a, recurrence)).tracked == null);

        // A new version reactivates the exact old identity and its provider
        // ETag. The original operation receipt survives the replacement claim.
        oracle.visible = true;
        const updated = try prepare(a, &oracle, &reopened, 0, 2, false);
        try std.testing.expectEqual(.applied, (try oracle.instance(a, &reopened).apply(updated, updated.confirmation())).operation.state);
        const canceled = try prepare(a, &oracle, &reopened, 0, 3, true);
        try std.testing.expectEqual(.applied, (try oracle.instance(a, &reopened).apply(canceled, canceled.confirmation())).operation.state);
        for (1001..1065) |id| {
            var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer phase.deinit();
            var current = fixture.host(phase.allocator());
            const review = try prepare(phase.allocator(), &oracle, &current, id, 1, false);
            try std.testing.expectEqual(.applied, (try oracle.instance(phase.allocator(), &current).apply(review, review.confirmation())).operation.state);
        }
        var restarted = fixture.host(a);
        const retained = try restarted.persistence().load(a, first.intent.identity);
        try std.testing.expectEqual(@as(u32, 3), retained.tracked.?.version.sequence);
        try std.testing.expectEqual(.cancel_event, retained.operation.?.intent.kind);
        try std.testing.expect((try oracle.instance(a, &restarted).invitationPlan(calendar, first.source.source, &.{}, .{})).decision == .identity_conflict);
        oracle.visible = true;
        try std.testing.expect((try oracle.instance(a, &restarted).invitationPlan(calendar, first.source.source, &.{}, .{})).decision == .stale_source);
        oracle.visible = false;
        try std.testing.expect((try oracle.instance(a, &restarted).invitationPlan(calendar, try source(a, 0, 4, false), &.{}, .{})).decision == .identity_conflict);
        try std.testing.expect(try restarted.loadReceipt(a, target, first.intent.operation_id) != null);
        try std.testing.expect(try restarted.loadReceipt(a, target, updated.intent.operation_id) != null);
        try std.testing.expect(try restarted.loadReceipt(a, target, canceled.intent.operation_id) != null);
        var store = try Fixture.open(fixture, a, account, false);
        defer store.close();
        try persistence.verifyHistory(&store, a);
        const raw = (try store.readDocument(a, "calendar-state.json", persistence.state_bytes)).?;
        try std.testing.expect(raw.len < persistence.state_bytes);
        const document = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
        try std.testing.expect(j.get(document, "entries").?.array.items.len < 64);
    }
}

test "calendar identity history: document publication faults keep unknown or applied roots in both stores" {
    for ([_]bool{ false, true }) |encrypted| for ([_]Fault{ .before_publication, .uncertain_publication, .after_publication }) |fault| {
        const fixture = try std.testing.allocator.create(Fixture);
        defer std.testing.allocator.destroy(fixture);
        try fixture.init(encrypted);
        defer fixture.close();
        const a = fixture.arena.allocator();
        var oracle: Oracle = .{ .fixture = fixture };
        var host = fixture.host(a);
        for (1..64) |id| {
            const prepared = try prepare(a, &oracle, &host, id, 1, false);
            try host.persistence().preserveFn(host.persistence().context, prepared);
        }
        const review = try prepare(a, &oracle, &host, 0, 1, false);
        oracle.fault_on_write = fault;
        try std.testing.expectError(error.UnknownOutcome, oracle.instance(a, &host).apply(review, review.confirmation()));
        fixture.fault = .none;
        var restarted = fixture.host(a);
        var operation = (try restarted.persistence().load(a, review.intent.identity)).operation.?;
        if (fault == .before_publication) try std.testing.expectEqual(.unknown, operation.state) else try std.testing.expectEqual(.applied, operation.state);
        if (operation.state == .unknown) {
            try std.testing.expect(!(try restarted.persistence().journal.claim(review.intent)).fresh);
            // The synthetic provider returned this exact positive receipt;
            // recording it is reconciliation, never a second provider write.
            operation.state = .applied;
            operation.provider_id = oracle.last_id;
            try restarted.persistence().journal.record(operation);
        }
        try std.testing.expectEqual(.applied, (try oracle.instance(a, &restarted).apply(review, review.confirmation())).operation.state);
        try std.testing.expectEqual(@as(usize, 1), oracle.writes);
        try std.testing.expectEqualStrings("calendar-1-1", (try restarted.loadReview(a, target, "calendar-1-1")).intent.operation_id);
        var store = try Fixture.open(fixture, a, account, true);
        defer store.close();
        try persistence.verifyHistory(&store, a);
    };
}

test "calendar identity history: migration keeps direct fences and missing pages fail closed" {
    const plain = try std.testing.allocator.create(Fixture);
    defer std.testing.allocator.destroy(plain);
    try plain.init(false);
    defer plain.close();
    const a = plain.arena.allocator();
    var oracle: Oracle = .{ .fixture = plain };
    var host = plain.host(a);
    var first: service.Review = undefined;
    for (0..64) |id| {
        var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer phase.deinit();
        var current = plain.host(phase.allocator());
        const review = try prepare(phase.allocator(), &oracle, &current, id, 1, false);
        try std.testing.expectEqual(.applied, (try oracle.instance(phase.allocator(), &current).apply(review, review.confirmation())).operation.state);
        if (id == 0) first = try copy(service.Review, a, review);
    }
    const sealed = try std.testing.allocator.create(Fixture);
    defer std.testing.allocator.destroy(sealed);
    try sealed.init(true);
    defer sealed.close();
    sealed.selected.?.close();
    sealed.selected = null;
    const config = try a.create(@import("config.zig").Config);
    try config.defaults("/nonexistent/synthetic-calendar-history");
    config.credential_store = .vault;
    config.count = 1;
    try config.accounts[0].address.set(account);
    var identity = try @import("terminal/vault_identity.zig").State.create(&sealed.owner.?, std.testing.allocator, config);
    defer identity.deinit();
    {
        var from = (try storage.Store.openMigration(io, a, plain.root, account, .{ .fixtures = true }, true)).?;
        defer from.close();
        const objects = try from.migrationObjects(a);
        var to = try storage.Store.openMigrationDestination(io, a, &sealed.owner.?, account, .{ .fixtures = true });
        defer to.close();
        for (objects) |*object| try to.copyMigrationObject(&from, object);
        try to.publishMigrationSnapshot(&from, objects);
        // Only the Calendar document uses the active map; pages keep their
        // immutable authenticated handles across the copy and restart.
        try std.testing.expectEqual(@as(usize, 1), to.vaultObjects.len);
        try persistence.verifyHistory(&to, a);
    }
    sealed.selected = try sealed.owner.?.openAccount(account);
    var migrated = sealed.host(a);
    try std.testing.expectEqualStrings(first.intent.operation_id, (try migrated.loadReceipt(a, target, first.intent.operation_id)).?.operation.intent.operation_id);
    try std.testing.expectEqual(.applied, (try oracle.instance(a, &migrated).apply(first, first.confirmation())).operation.state);
    try std.testing.expectEqual(@as(usize, 64), oracle.writes);
    try std.testing.expect((try oracle.instance(a, &migrated).invitationPlan(calendar, first.source.source, &.{}, .{})).decision == .identity_conflict);

    for ([_]*Fixture{ plain, sealed }) |fixture| {
        {
            var store = try Fixture.open(fixture, a, account, false);
            defer store.close();
            const raw = (try store.readDocument(a, "calendar-state.json", persistence.state_bytes)).?;
            const value = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
            const roots = try j.decode(history.Root, a, j.get(value, "history").?);
            for ([_][history.bucket_count][]const u8{ roots.identities.heads, roots.receipts.heads }) |heads| for (heads) |handle| {
                if (handle.len == 0) continue;
                const name = try @import("terminal/operation_history.zig").fileName(a, "calendar", handle);
                if (store.vault) |vault| try vault.remove(try @import("terminal/vault_storage.zig").Handle.parse(handle)) else try store.dir.deleteFile(io, name);
            };
            try std.testing.expectError(error.HistoryRecordMissing, persistence.verifyHistory(&store, a));
        }
        host = fixture.host(a);
        try std.testing.expectError(error.HistoryRecordMissing, host.persistence().load(a, first.intent.identity));
        try std.testing.expectError(error.HistoryRecordMissing, host.persistence().journal.claim(first.intent));
        try std.testing.expectError(error.HistoryRecordMissing, oracle.instance(a, &host).apply(first, first.confirmation()));
        try std.testing.expectEqual(@as(usize, 64), oracle.writes);
    }
}
