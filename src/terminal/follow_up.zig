//! Account-local follow-ups survive mail eviction. Dates are civil days, never
//! ambiguous wall-clock times. Completion removes the local reminder only.
const std = @import("std");
const bounded = @import("../bounded.zig");
const timezone = @import("timezone.zig");
const storage = @import("store.zig");
const j = @import("json.zig");
const t = @import("types.zig");

pub const limit = 100;
pub const max_bytes = 512 * 1024;
pub const document = "follow-ups.json";
pub const Entry = struct {
    messageId: []const u8,
    threadId: []const u8,
    dueDate: []const u8,
    subject: []const u8 = "",
    counterpart: []const u8 = "",
    version: i64,
};
pub const State = struct {
    schema: u8 = 1,
    account: []const u8,
    revision: i64 = 0,
    entries: []Entry = &.{},

    pub fn find(self: *const State, message_id: []const u8) ?Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.messageId, message_id)) return entry;
        return null;
    }
    pub fn validate(self: *const State, account: []const u8) !void {
        if (self.schema != 1 or !std.mem.eql(u8, self.account, account) or self.revision < 0 or self.entries.len > limit) return error.FollowUpStoreCorrupt;
        for (self.entries, 0..) |entry, index| {
            try bounded.identifier(entry.messageId);
            try bounded.identifier(entry.threadId);
            try date(entry.dueDate);
            try literal(entry.subject, 512);
            try literal(entry.counterpart, 256);
            if (entry.version <= 0 or entry.version > self.revision) return error.FollowUpStoreCorrupt;
            for (self.entries[0..index]) |prior| if (std.mem.eql(u8, entry.messageId, prior.messageId)) return error.FollowUpStoreCorrupt;
        }
    }
    /// expectedVersion=0 creates only when absent. A retained document revision
    /// prevents a stale edit from matching a reminder removed then recreated.
    pub fn set(self: *State, a: std.mem.Allocator, message_id: []const u8, due: []const u8, expected: i64, snapshot: ?t.Message) !Entry {
        try bounded.identifier(message_id);
        try date(due);
        const prior = self.find(message_id);
        if (expected < 0 or expected != (if (prior) |entry| entry.version else @as(i64, 0))) return error.FollowUpChanged;
        if (prior == null and self.entries.len == limit) return error.FollowUpLimitReached;
        const version = std.math.add(i64, self.revision, 1) catch return error.FollowUpLimitReached;
        var entry: Entry = if (prior) |old| old else blk: {
            const source = snapshot orelse return error.FollowUpMessageUnavailable;
            if (!std.mem.eql(u8, source.id, message_id)) return error.FollowUpMessageUnavailable;
            for (source.labels) |label| if (std.mem.eql(u8, label, "DRAFT")) return error.DraftNotMail;
            try bounded.identifier(source.threadId);
            break :blk .{ .messageId = try a.dupe(u8, message_id), .threadId = try a.dupe(u8, source.threadId), .dueDate = "", .version = 0, .subject = try snapshotText(a, source.subject, 512), .counterpart = try snapshotText(a, if (source.from.name.len > 0) source.from.name else source.from.address, 256) };
        };
        entry.dueDate = try a.dupe(u8, due);
        entry.version = version;
        if (prior != null) {
            for (self.entries) |*item| if (std.mem.eql(u8, item.messageId, message_id)) {
                item.* = entry;
                break;
            };
        } else {
            const entries = try a.alloc(Entry, self.entries.len + 1);
            @memcpy(entries[0..self.entries.len], self.entries);
            entries[self.entries.len] = entry;
            self.entries = entries;
        }
        self.revision = version;
        return entry;
    }
    pub fn done(self: *State, message_id: []const u8, expected: i64) !void {
        const prior = self.find(message_id) orelse return error.FollowUpChanged;
        if (expected != prior.version) return error.FollowUpChanged;
        const version = std.math.add(i64, self.revision, 1) catch return error.FollowUpLimitReached;
        for (self.entries, 0..) |entry, index| if (std.mem.eql(u8, entry.messageId, message_id)) {
            std.mem.copyForwards(Entry, self.entries[index .. self.entries.len - 1], self.entries[index + 1 ..]);
            self.entries = self.entries[0 .. self.entries.len - 1];
            break;
        };
        self.revision = version;
    }
};
fn literal(text: []const u8, max: usize) !void {
    if (text.len > max or !std.unicode.utf8ValidateSlice(text)) return error.FollowUpStoreCorrupt;
    for (text) |byte| if (byte < 32 or byte == 127) return error.FollowUpStoreCorrupt;
}
fn snapshotText(a: std.mem.Allocator, input: []const u8, max: usize) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var end = @min(input.len, max);
    while (end > 0 and !std.unicode.utf8ValidateSlice(input[0..end])) end -= 1;
    const output = try a.dupe(u8, input[0..end]);
    for (output) |*byte| if (byte.* < 32 or byte.* == 127) {
        byte.* = ' ';
    };
    return output;
}
pub fn date(value: []const u8) !void {
    _ = timezone.parseDate(value) catch return error.InvalidFollowUpDate;
    if (value[4] != '-') return error.InvalidFollowUpDate;
}
pub fn dateForDay(a: std.mem.Allocator, day: i64) ![]const u8 {
    const utc = try timezone.Zone.fromPosix("UTC0");
    const formatted = try utc.format(a, std.math.mul(i64, day, 86400000) catch return error.InvalidFollowUpDate);
    try date(formatted[0..10]);
    return formatted[0..10];
}
pub fn read(store: *storage.Store, a: std.mem.Allocator, account: []const u8) !State {
    const raw = try store.readDocument(a, document, max_bytes) orelse return .{ .account = account };
    return parse(a, raw, account);
}
pub fn parse(a: std.mem.Allocator, raw: []const u8, account: []const u8) !State {
    if (raw.len > max_bytes) return error.FollowUpStoreCorrupt;
    const state = try std.json.parseFromSliceLeaky(State, a, raw, .{ .allocate = .alloc_if_needed, .max_value_len = max_bytes });
    try state.validate(account);
    return state;
}
pub fn write(store: *storage.Store, a: std.mem.Allocator, state: State) !void {
    try state.validate(state.account);
    try store.writeDocument(document, try j.encodeAlloc(a, state, .{}));
}
pub fn sorted(a: std.mem.Allocator, state: State) ![]Entry {
    const entries = try a.dupe(Entry, state.entries);
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            const order = std.mem.order(u8, left.dueDate, right.dueDate);
            return if (order == .eq) std.mem.lessThan(u8, left.messageId, right.messageId) else order == .lt;
        }
    }.less);
    return entries;
}

test "follow-ups: civil dates validate and completion cannot accept stale edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{ .account = "fictional@example.test" };
    const message: t.Message = .{ .id = "m1", .threadId = "t1", .subject = "Café\nPlan", .from = .{ .address = "other@example.test", .name = "Example" } };
    const first = try state.set(a, "m1", "2028-02-29", 0, message);
    try std.testing.expectEqualStrings("Café Plan", first.subject);
    try std.testing.expectError(error.InvalidFollowUpDate, state.set(a, "m1", "2027-02-29", first.version, null));
    try std.testing.expectError(error.FollowUpChanged, state.set(a, "m1", "2028-03-01", 0, message));
    const edited = try state.set(a, "m1", "2028-03-01", first.version, null);
    try std.testing.expectError(error.FollowUpChanged, state.done("m1", first.version));
    try state.done("m1", edited.version);
    const recreated = try state.set(a, "m1", "2028-03-02", 0, message);
    try std.testing.expect(recreated.version > edited.version);
    try std.testing.expectError(error.FollowUpChanged, state.done("m1", edited.version));
    const copy = try parse(a, try j.encodeAlloc(a, state, .{}), state.account);
    try std.testing.expectEqualStrings("2028-03-02", copy.find("m1").?.dueDate);
    try std.testing.expectError(error.FollowUpStoreCorrupt, parse(a, try j.encodeAlloc(a, state, .{}), "other@example.test"));
    try std.testing.expectEqualStrings("2028-03-01", try dateForDay(a, try timezone.dateDay("2028-02-29") + 1));
}

test "follow-ups: active cap refuses new messages and permits edits and completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{ .account = "fictional@example.test" };
    for (0..limit) |i| {
        const id = try std.fmt.allocPrint(a, "m{d}", .{i});
        _ = try state.set(a, id, "2026-10-13", 0, .{ .id = id, .threadId = "t1" });
    }
    try std.testing.expectError(error.FollowUpLimitReached, state.set(a, "extra", "2026-10-13", 0, .{ .id = "extra", .threadId = "t1" }));
    _ = try state.set(a, "m0", "2026-10-14", state.find("m0").?.version, null);
    try state.done("m1", state.find("m1").?.version);
    _ = try state.set(a, "extra", "2026-10-13", 0, .{ .id = "extra", .threadId = "t1" });
    try std.testing.expectEqual(@as(usize, limit), state.entries.len);
    try state.done("extra", state.find("extra").?.version);
    try std.testing.expectError(error.FollowUpMessageUnavailable, state.set(a, "unavailable", "2026-10-13", 0, null));
}
