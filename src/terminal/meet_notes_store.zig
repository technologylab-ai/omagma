//! Bounded account-private Meet continuations. Every transaction releases the
//! existing account lock before any Calendar or Meet network request occurs.
const std = @import("std");
const j = @import("json.zig");
const records = @import("meet_notes_types.zig");
const provider = @import("meet_notes_provider.zig");
const calendar_types = @import("calendar_types.zig");
const storage = @import("store.zig");
const mail = @import("types.zig");
const history = @import("meet_notes_history.zig");

pub const name = "meet-notes.json";
pub const max_bytes = 4 * 1024 * 1024;
pub const max_entries = 256;
pub const final_reserve = 16 * 1024;
pub const File = struct { schema: u8 = 1, account: []const u8, default_enabled: bool = false, entries: []records.Entry = &.{}, history: history.Root = .{} };
pub const Claim = struct { entry: records.Entry, dispatch: bool };

fn validateFile(a: std.mem.Allocator, file: File, account: []const u8) !void {
    if (file.schema != 1 or !std.ascii.eqlIgnoreCase(file.account, account) or file.entries.len > max_entries) return error.InvalidMeetContinuation;
    try history.validate(file.history);
    for (file.entries, 0..) |entry, index| {
        try entry.validate(a, account);
        for (file.entries[0..index]) |prior| if (std.mem.eql(u8, entry.consent.operation_id, prior.consent.operation_id)) return error.InvalidMeetContinuation;
    }
}
/// Migration must verify every page owned by this document before publishing
/// the destination credential/cache store, just like Calendar history does.
pub fn verifyHistory(store: *storage.Store, a: std.mem.Allocator) !void {
    const raw = try store.readDocument(a, name, max_bytes) orelse return;
    const file = try std.json.parseFromSliceLeaky(File, a, raw, .{ .allocate = .alloc_if_needed });
    try validateFile(a, file, store.state.account);
    try history.verify(store, file.history);
}

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    account: []const u8,
    options: mail.Options,
    access: @import("store_access.zig").Access = .{},

    fn open(self: Host, a: std.mem.Allocator) !storage.Store {
        return self.access.open(self.io, a, self.root, self.account, self.options, false);
    }
    fn checkTarget(self: Host, target: calendar_types.Target) !void {
        try target.validate();
        if (!std.ascii.eqlIgnoreCase(self.account, target.account)) return error.CalendarAccountMismatch;
    }
    fn load(self: Host, store: *storage.Store, a: std.mem.Allocator) !File {
        const raw = try store.readDocument(a, name, max_bytes) orelse return .{ .account = self.account };
        const file = try std.json.parseFromSliceLeaky(File, a, raw, .{ .allocate = .alloc_if_needed });
        try validateFile(a, file, self.account);
        return file;
    }
    fn write(store: *storage.Store, a: std.mem.Allocator, file: File) !void {
        if (charged(file) > max_bytes) return error.MeetContinuationFull;
        try store.publishDocumentRecords(name, try j.encodeAlloc(a, file, .{}));
    }
    fn charged(file: File) usize {
        var reserve: usize = 0;
        for (file.entries) |entry| if (entry.protected()) {
            // Filling the claim/final fields consumes existing headroom;
            // charging a fresh fixed reserve after every update would count
            // it twice and could strand an already-created Calendar event.
            reserve += entry.reserved_bytes -| @import("gmail_decode.zig").serializedBytes(entry);
        };
        const root_reserve = 8192 -| @import("gmail_decode.zig").serializedBytes(file.history);
        return @import("gmail_decode.zig").serializedBytes(file) + reserve + root_reserve;
    }
    fn find(file: File, operation_id: []const u8) ?usize {
        for (file.entries, 0..) |entry, index| if (std.mem.eql(u8, entry.consent.operation_id, operation_id)) return index;
        return null;
    }
    fn bound(file: File, target: calendar_types.Target, operation_id: []const u8, hash: ?[32]u8) !usize {
        const index = find(file, operation_id) orelse return error.MeetReviewExpired;
        const entry = file.entries[index];
        if (!entry.consent.target.eql(target)) return error.MeetReviewMismatch;
        if (hash) |expected| if (!std.mem.eql(u8, &expected, &entry.review_hash)) return error.MeetReviewMismatch;
        return index;
    }
    fn archived(store: *storage.Store, a: std.mem.Allocator, file: File, target: calendar_types.Target, operation_id: []const u8, hash: ?[32]u8) !records.Entry {
        const entry = try history.find(store, a, file.history, operation_id) orelse return error.MeetReviewExpired;
        if (!entry.consent.target.eql(target)) return error.MeetReviewMismatch;
        if (hash) |expected| if (!std.mem.eql(u8, &entry.review_hash, &expected)) return error.MeetReviewMismatch;
        return entry;
    }
    fn clone(comptime T: type, a: std.mem.Allocator, value: T) !T {
        return std.json.parseFromSliceLeaky(T, a, try j.encodeAlloc(a, value, .{}), .{ .allocate = .alloc_if_needed });
    }
    fn conflict(file: File, selected: records.Entry) !void {
        for (file.entries) |other| {
            if (std.mem.eql(u8, other.consent.operation_id, selected.consent.operation_id) or !other.protected()) continue;
            const same_event = other.consent.target.eql(selected.consent.target) and std.mem.eql(u8, other.consent.event_id, selected.consent.event_id);
            const same_space = selected.space_name.len != 0 and other.space_name.len != 0 and std.mem.eql(u8, selected.space_name, other.space_name);
            if (same_event or same_space) return error.MeetOperationPending;
        }
    }
    fn fit(store: *storage.Store, a: std.mem.Allocator, file: *File, protected_id: []const u8) !void {
        var settled: std.ArrayList(records.Entry) = .empty;
        while (file.entries.len > max_entries or charged(file.*) > max_bytes) {
            var remove: ?usize = null;
            for (file.entries, 0..) |entry, index| if (entry.phase == .reviewed and !std.mem.eql(u8, entry.consent.operation_id, protected_id)) {
                remove = index;
                break;
            };
            if (remove == null) {
                for (file.entries, 0..) |entry, index| if (history.settled(entry) and !std.mem.eql(u8, entry.consent.operation_id, protected_id)) {
                    try settled.append(a, entry);
                    remove = index;
                    break;
                };
            }
            const index = remove orelse return error.MeetContinuationFull;
            std.mem.copyForwards(records.Entry, file.entries[index .. file.entries.len - 1], file.entries[index + 1 ..]);
            file.entries = file.entries[0 .. file.entries.len - 1];
        }
        if (settled.items.len != 0) file.history = try history.append(store, file.history, settled.items);
    }

    pub fn preference(self: Host, out: std.mem.Allocator, update: ?bool) !bool {
        _ = out;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try self.load(&store, a);
        if (update) |enabled| {
            file.default_enabled = enabled;
            try write(&store, a, file);
        }
        return file.default_enabled;
    }
    pub fn read(self: Host, out: std.mem.Allocator, target: calendar_types.Target, operation_id: []const u8) !records.Entry {
        try self.checkTarget(target);
        try records.operationId(operation_id);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        const file = try self.load(&store, a);
        const entry = if (find(file, operation_id)) |_| file.entries[try bound(file, target, operation_id, null)] else try archived(&store, a, file, target, operation_id, null);
        return clone(records.Entry, out, entry);
    }
    pub fn pending(self: Host, out: std.mem.Allocator, target: calendar_types.Target, event_id: []const u8) !?records.Entry {
        try self.checkTarget(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        const file = try self.load(&store, a);
        for (file.entries) |entry| if (entry.consent.target.eql(target) and entry.protected() and (if (event_id.len == 0) entry.consent.parent == .insert and entry.calendar_state != .applied else std.mem.eql(u8, entry.consent.event_id, event_id))) return try clone(records.Entry, out, entry);
        return null;
    }
    pub fn review(self: Host, entry: records.Entry) !void {
        try self.checkTarget(entry.consent.target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try entry.validate(a, self.account);
        if (entry.phase != .reviewed or entry.generation != 0 or entry.request_hash != null or entry.reserved_bytes != 0) return error.InvalidMeetContinuation;
        if (entry.calendar_state != (if (entry.consent.parent == .none) records.CalendarState.unchanged else .not_sent)) return error.InvalidMeetContinuation;
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try self.load(&store, a);
        if (find(file, entry.consent.operation_id)) |index| {
            if (!std.mem.eql(u8, &file.entries[index].review_hash, &entry.review_hash)) return error.OperationConflict;
            // Repeating review must never reset an authorized or settled leg.
            return;
        }
        if (try history.find(&store, a, file.history, entry.consent.operation_id)) |old| {
            if (!old.consent.target.eql(entry.consent.target) or !std.mem.eql(u8, &old.review_hash, &entry.review_hash)) return error.OperationConflict;
            return;
        }
        const expanded = try a.alloc(records.Entry, file.entries.len + 1);
        @memcpy(expanded[0..file.entries.len], file.entries);
        expanded[file.entries.len] = entry;
        file.entries = expanded;
        try fit(&store, a, &file, entry.consent.operation_id);
        try write(&store, a, file);
    }
    pub fn authorize(self: Host, out: std.mem.Allocator, target: calendar_types.Target, operation_id: []const u8, hash: [32]u8) !records.Entry {
        try self.checkTarget(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try self.load(&store, a);
        const index = if (find(file, operation_id)) |_| try bound(file, target, operation_id, hash) else return clone(records.Entry, out, try archived(&store, a, file, target, operation_id, hash));
        var entry = file.entries[index];
        if (entry.phase == .reviewed) {
            entry.phase = .authorized;
            if (entry.consent.parent == .none) entry.calendar_state = .unchanged;
            entry.reserved_bytes = @import("gmail_decode.zig").serializedBytes(entry) + final_reserve;
            try conflict(file, entry);
            file.entries[index] = entry;
            try fit(&store, a, &file, operation_id);
            try write(&store, a, file);
        }
        return clone(records.Entry, out, entry);
    }
    pub fn progress(self: Host, out: std.mem.Allocator, update: records.Entry, expected_generation: u32) !records.Entry {
        try self.checkTarget(update.consent.target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try update.validate(a, self.account);
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try self.load(&store, a);
        const index = if (find(file, update.consent.operation_id)) |_| try bound(file, update.consent.target, update.consent.operation_id, update.review_hash) else return clone(records.Entry, out, try archived(&store, a, file, update.consent.target, update.consent.operation_id, update.review_hash));
        const old = file.entries[index];
        if (old.generation != expected_generation or update.generation != expected_generation) return clone(records.Entry, out, old);
        if (old.reserved_bytes != update.reserved_bytes) return error.InvalidMeetContinuation;
        if (old.phase == .confirmed or old.phase == .refused or old.phase == .abandoned) return clone(records.Entry, out, old);
        if (!legalProgress(old.phase, update.phase)) return error.InvalidMeetContinuation;
        if (old.generation != 0 and (update.phase == .reviewed or update.phase == .authorized or update.phase == .waiting_calendar or update.phase == .waiting_link or update.phase == .ready)) return error.InvalidMeetContinuation;
        if (old.request_hash) |frozen| if (update.request_hash == null or !std.mem.eql(u8, &frozen, &update.request_hash.?)) return error.InvalidMeetContinuation;
        if ((old.calendar_state == .applied or old.calendar_state == .unchanged) and update.calendar_state != old.calendar_state) return error.InvalidMeetContinuation;
        if (old.space_name.len != 0 and (!std.mem.eql(u8, old.space_name, update.space_name) or !std.mem.eql(u8, old.code, update.code))) return error.MeetSpaceChanged;
        try conflict(file, update);
        file.entries[index] = update;
        try fit(&store, a, &file, update.consent.operation_id);
        try write(&store, a, file);
        return clone(records.Entry, out, update);
    }
    /// A claim is the only transition into unknown and the only generation
    /// increment. Durable publication precedes the single possible PATCH.
    pub fn claim(self: Host, out: std.mem.Allocator, target: calendar_types.Target, operation_id: []const u8, hash: [32]u8, next_attempt: ?u32) !Claim {
        try self.checkTarget(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try self.load(&store, a);
        const index = if (find(file, operation_id)) |_| try bound(file, target, operation_id, hash) else return .{ .entry = try clone(records.Entry, out, try archived(&store, a, file, target, operation_id, hash)), .dispatch = false };
        var entry = file.entries[index];
        // A definite refusal is terminal, whether active or archived. A new
        // explicit notes-only review may request another change on this same
        // event, but an old refused confirmation must never become replayable.
        const retry = next_attempt != null and entry.phase == .unknown;
        if (entry.phase != .ready and !retry) return .{ .entry = try clone(records.Entry, out, entry), .dispatch = false };
        if (entry.calendar_state != .applied and entry.calendar_state != .unchanged) return error.InvalidMeetContinuation;
        if (next_attempt) |attempt| if (attempt != entry.generation +| 1) return .{ .entry = try clone(records.Entry, out, entry), .dispatch = false };
        if (entry.generation == std.math.maxInt(u32) or entry.space_name.len == 0) return error.InvalidMeetContinuation;
        try conflict(file, entry);
        entry.phase = .unknown;
        entry.generation += 1;
        entry.request_hash = try records.requestHash(a, entry.consent.target.account, entry.space_name, entry.consent.enabled);
        entry.reason = "";
        entry.provider_status = 0;
        entry.provider_reason = "";
        entry.provider_message = "";
        try entry.validate(a, self.account);
        file.entries[index] = entry;
        try fit(&store, a, &file, operation_id);
        try write(&store, a, file);
        return .{ .entry = try clone(records.Entry, out, entry), .dispatch = true };
    }
    /// A matching observation settles an authorized/uncertain operation without
    /// another write. Definite refusals stay historical; current settings can
    /// still be read independently without relabelling the refused request.
    pub fn observe(self: Host, out: std.mem.Allocator, target: calendar_types.Target, operation_id: []const u8, hash: [32]u8, expected_generation: u32, space: provider.Space, now_ms: i64) !records.Entry {
        try self.checkTarget(target);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try self.load(&store, a);
        const index = if (find(file, operation_id)) |_| try bound(file, target, operation_id, hash) else return clone(records.Entry, out, try archived(&store, a, file, target, operation_id, hash));
        var entry = file.entries[index];
        if (entry.generation != expected_generation or entry.phase == .confirmed or entry.phase == .refused or entry.phase == .abandoned) return clone(records.Entry, out, entry);
        if (entry.phase == .reviewed or (entry.calendar_state != .applied and entry.calendar_state != .unchanged)) return error.InvalidMeetContinuation;
        if (!std.mem.eql(u8, space.name, entry.space_name) or !std.mem.eql(u8, space.code, entry.code)) return error.MeetSpaceChanged;
        if (!space.matches(entry.consent.enabled)) return error.MeetSettingsUnconfirmed;
        entry.phase = .confirmed;
        entry.observed_notes = space.notes;
        entry.observed_transcription = space.transcription;
        entry.observed_ms = now_ms;
        entry.reason = "";
        entry.calendar_review = null;
        try entry.validate(a, self.account);
        file.entries[index] = entry;
        try write(&store, a, file);
        return clone(records.Entry, out, entry);
    }
    pub fn abandon(self: Host, out: std.mem.Allocator, target: calendar_types.Target, operation_id: []const u8, hash: [32]u8) !records.Entry {
        var entry = try self.read(out, target, operation_id);
        if (!std.mem.eql(u8, &entry.review_hash, &hash)) return error.MeetReviewMismatch;
        if (entry.calendar_state != .applied and entry.calendar_state != .unchanged) return error.CalendarOperationPending;
        if (entry.phase == .confirmed or entry.phase == .refused or entry.phase == .abandoned) return entry;
        entry.phase = .abandoned;
        return self.progress(out, entry, entry.generation);
    }
};

fn legalProgress(from: records.Phase, to: records.Phase) bool {
    if (to == .reviewed or to == .unknown or to == .confirmed) return from == to;
    if (from == to) return true;
    return switch (from) {
        .authorized => to == .waiting_calendar or to == .waiting_link or to == .ready or to == .refused or to == .abandoned,
        .waiting_calendar => to == .waiting_link or to == .ready or to == .refused or to == .abandoned,
        .waiting_link => to == .ready or to == .refused or to == .abandoned,
        .ready, .unknown => to == .refused or to == .abandoned,
        else => false,
    };
}

fn testReview(a: std.mem.Allocator, operation_id: []const u8, event_id: []const u8) !records.Entry {
    const consent: records.Consent = .{
        .target = .{ .account = "self@example.test", .calendar_id = "opaque-primary" },
        .event_id = event_id,
        .operation_id = operation_id,
        .enabled = true,
        .parent = .none,
        .summary = "Fictional planning meeting",
        .existing_etag = "\"event-v1\"",
        .existing_code = "abc-defg-hij",
        .existing_space = "spaces/canonical_A2",
    };
    return .{ .consent = consent, .review_hash = try consent.hash(a), .calendar_state = .unchanged, .space_name = consent.existing_space, .code = consent.existing_code };
}

test "meet notes: durable claim survives restart and settled or stale callers cannot replay it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/meet", .{tmp.sub_path});
    const host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = "self@example.test", .options = .{ .fixtures = true } };
    const reviewed = try testReview(a, "notes-one", "event-one");
    try host.review(reviewed);
    var entry = try host.authorize(a, reviewed.consent.target, reviewed.consent.operation_id, reviewed.review_hash);
    entry.phase = .ready;
    _ = try host.progress(a, entry, 0);
    const first = try host.claim(a, entry.consent.target, entry.consent.operation_id, entry.review_hash, null);
    try std.testing.expect(first.dispatch);
    try std.testing.expectEqual(records.Phase.unknown, first.entry.phase);
    try std.testing.expectEqual(@as(u32, 1), first.entry.generation);
    try std.testing.expect(!(try host.claim(a, entry.consent.target, entry.consent.operation_id, entry.review_hash, null)).dispatch);
    const reopened = try host.read(a, entry.consent.target, entry.consent.operation_id);
    try std.testing.expectEqualDeep(first.entry.request_hash, reopened.request_hash);
    try std.testing.expect((try host.pending(a, entry.consent.target, "event-one")) != null);
    var invalid_reopen = reopened;
    invalid_reopen.phase = .ready;
    try std.testing.expectError(error.InvalidMeetContinuation, host.progress(a, invalid_reopen, 1));
    try std.testing.expect(!(try host.claim(a, entry.consent.target, entry.consent.operation_id, entry.review_hash, null)).dispatch);
    _ = try host.observe(a, entry.consent.target, entry.consent.operation_id, entry.review_hash, 1, .{ .name = entry.space_name, .code = entry.code, .notes = .on, .transcription = .on }, 1000);
    var late = reopened;
    late.phase = .refused;
    late.reason = "LateResponse";
    try std.testing.expectEqual(records.Phase.confirmed, (try host.progress(a, late, 1)).phase);
    try host.review(reviewed);
    try std.testing.expectEqual(records.Phase.confirmed, (try host.read(a, entry.consent.target, entry.consent.operation_id)).phase);
    try std.testing.expect(!(try host.claim(a, entry.consent.target, entry.consent.operation_id, entry.review_hash, null)).dispatch);
    try std.testing.expect((try host.pending(a, entry.consent.target, "event-one")) == null);
}

test "meet notes: pending intents fence a reused canonical space across different events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/meet", .{tmp.sub_path});
    const host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = "self@example.test", .options = .{ .fixtures = true } };
    const first = try testReview(a, "notes-one", "event-one");
    const second = try testReview(a, "notes-two", "event-two");
    try host.review(first);
    try host.review(second);
    _ = try host.authorize(a, first.consent.target, first.consent.operation_id, first.review_hash);
    try std.testing.expectError(error.MeetOperationPending, host.authorize(a, second.consent.target, second.consent.operation_id, second.review_hash));
    try std.testing.expectEqual(records.Phase.reviewed, (try host.read(a, second.consent.target, second.consent.operation_id)).phase);
    try std.testing.expectError(error.MeetReviewMismatch, host.authorize(a, first.consent.target, first.consent.operation_id, @splat(0)));
    try std.testing.expectError(error.CalendarAccountMismatch, host.read(a, .{ .account = "other@example.test", .calendar_id = "opaque-primary" }, first.consent.operation_id));
}

test "meet notes: frozen claim fields consume existing reserved bytes without double charging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = try testReview(a, "notes-one", "event-one");
    entry.phase = .ready;
    entry.reserved_bytes = @import("gmail_decode.zig").serializedBytes(entry) + final_reserve;
    var entries = [_]records.Entry{entry};
    const before = Host.charged(.{ .account = "self@example.test", .entries = &entries });
    entries[0].phase = .unknown;
    entries[0].generation = 1;
    entries[0].request_hash = try records.requestHash(a, "self@example.test", entry.space_name, true);
    try entries[0].validate(a, "self@example.test");
    try std.testing.expectEqual(before, Host.charged(.{ .account = "self@example.test", .entries = &entries }));
    entries[0].phase = .confirmed;
    try std.testing.expect(Host.charged(.{ .account = "self@example.test", .entries = &entries }) < before);
}

test "meet notes: archived ON confirmation cannot replay after a newer OFF and active-book trimming" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/meet", .{tmp.sub_path});
    const host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .root = root, .account = "self@example.test", .options = .{ .fixtures = true } };
    const first = try testReview(a, "notes-on", "event-one");
    try host.review(first);
    var authorized = try host.authorize(a, first.consent.target, first.consent.operation_id, first.review_hash);
    authorized.phase = .ready;
    _ = try host.progress(a, authorized, 0);
    const on_claim = try host.claim(a, first.consent.target, first.consent.operation_id, first.review_hash, null);
    try std.testing.expect(on_claim.dispatch);
    _ = try host.observe(a, first.consent.target, first.consent.operation_id, first.review_hash, 1, .{ .name = first.space_name, .code = first.code, .notes = .on, .transcription = .on }, 1000);
    var second = try testReview(a, "notes-off", "event-one");
    second.consent.enabled = false;
    second.consent.before_notes = .on;
    second.review_hash = try second.consent.hash(a);
    try host.review(second);
    authorized = try host.authorize(a, second.consent.target, second.consent.operation_id, second.review_hash);
    authorized.phase = .ready;
    _ = try host.progress(a, authorized, 0);
    try std.testing.expect((try host.claim(a, second.consent.target, second.consent.operation_id, second.review_hash, null)).dispatch);
    _ = try host.observe(a, second.consent.target, second.consent.operation_id, second.review_hash, 1, .{ .name = second.space_name, .code = second.code, .notes = .off, .transcription = .on }, 2000);
    {
        var store = try host.open(a);
        defer store.close();
        store.beginHistory();
        errdefer store.abortHistory();
        var file = try host.load(&store, a);
        const entries = try a.alloc(records.Entry, max_entries);
        @memcpy(entries[0..file.entries.len], file.entries);
        for (file.entries.len..max_entries) |index| {
            var final = try testReview(a, try std.fmt.allocPrint(a, "settled-{d}", .{index}), try std.fmt.allocPrint(a, "event-{d}", .{index}));
            final.phase = .confirmed;
            final.observed_notes = .on;
            final.observed_transcription = .on;
            entries[index] = final;
        }
        file.entries = entries;
        try Host.write(&store, a, file);
    }
    try host.review(try testReview(a, "new-review", "event-new"));
    {
        var store = try host.open(a);
        defer store.close();
        const file = try host.load(&store, a);
        try std.testing.expect(Host.find(file, first.consent.operation_id) == null);
        try verifyHistory(&store, a);
    }
    // Replaying the old reviewed bytes and the old confirmation must read the
    // immutable historical receipt, never claim another PATCH over newer OFF.
    try host.review(first);
    try std.testing.expectEqual(records.Phase.confirmed, (try host.authorize(a, first.consent.target, first.consent.operation_id, first.review_hash)).phase);
    const replay = try host.claim(a, first.consent.target, first.consent.operation_id, first.review_hash, null);
    try std.testing.expect(!replay.dispatch);
    try std.testing.expectEqual(@as(u32, 1), replay.entry.generation);
    try std.testing.expectEqual(provider.Auto.off, (try host.read(a, second.consent.target, second.consent.operation_id)).observed_notes);
}
