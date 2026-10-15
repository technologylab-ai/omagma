//! Session-only, bounded meeting reminders. Epoch instants drive eligibility;
//! local zones are presentation only. Dismissed identities stay until event end.
const std = @import("std");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const calendar = @import("calendar_types.zig");
const ui = @import("calendar_ui.zig");
pub const lead_ms: i64 = 10 * 60000;
pub const max_targets = 3 * calendar.Limits.calendars;
pub const max_records = 64;
pub const Key = [32]u8;
pub const Target = struct {
    active: bool = false,
    account: u8 = 0,
    id: b.Text(1024) = .{},
    name: b.Text(256) = .{},
    poll_after: i64 = 0,
};
pub const Record = struct {
    key: Key,
    target: u8,
    start: i64,
    end: i64,
    title: b.Text(512) = .{},
    location: b.Text(256) = .{},
    join: b.Text(2048) = .{},
    dismissed: bool = false,
    present: bool = true,
    stale: bool = false,
    announced: bool = false,
    observed_at: i64 = 0,
};
pub const CalendarListShape = struct { complete: bool, cached: bool, stale: bool, entries: j.Value };
/// Check the original provider shape before any preference adapter rewrites
/// primary/selected flags or maps an invalid collection to an empty array.
pub fn validateCalendars(address: []const u8, result: j.Value) !CalendarListShape {
    if (!std.mem.eql(u8, j.text(result, "account"), address)) return error.CalendarAccountMismatch;
    const complete = try j.boolean(result, "complete", false);
    const cached = try j.boolean(result, "cached", false);
    const stale = try j.boolean(result, "stale", false);
    const entries = j.get(result, "calendars") orelse return error.InvalidCalendarResponse;
    if (entries != .array or entries.array.items.len > calendar.Limits.calendars) return error.InvalidCalendarResponse;
    // Validate every identity before changing a previously usable target set.
    for (entries.array.items) |entry| {
        const value = j.get(entry, "calendar") orelse return error.InvalidCalendarResponse;
        const target = j.get(value, "target") orelse return error.InvalidCalendarResponse;
        if (!std.mem.eql(u8, j.text(target, "account"), address)) return error.CalendarAccountMismatch;
        try calendar.text(j.text(target, "calendar_id"), 1024, false);
        _ = try j.boolean(entry, "canRead", false);
        _ = try j.boolean(value, "primary", false);
        _ = try j.boolean(value, "selected", false);
    }
    return .{ .complete = complete, .cached = cached, .stale = stale, .entries = entries };
}
pub const State = struct {
    targets: [max_targets]Target = @splat(.{}),
    records: [max_records]?Record = @splat(null),
    list_after: [3]i64 = @splat(0),
    cursor: usize = 0,

    pub fn expire(self: *State, now: i64) void {
        for (&self.records) |*record| if (record.*) |*value| {
            if (value.end <= now) record.* = null else if (value.present and !value.stale and now - value.observed_at <= 120000 and value.start <= now +| lead_ms) value.announced = true;
        };
    }
    pub fn available(self: *const State, index: usize) bool {
        const record = self.records[index] orelse return false;
        return record.present and record.announced and !record.dismissed and self.targets[record.target].active;
    }
    pub fn count(self: *const State) usize {
        var result: usize = 0;
        for (0..self.records.len) |index| result += @intFromBool(self.available(index));
        return result;
    }
    pub fn find(self: *const State, key: Key) ?usize {
        for (self.records, 0..) |record, index| if (record) |value| {
            if (std.mem.eql(u8, &value.key, &key) and self.available(index)) return index;
        };
        return null;
    }
    pub fn first(self: *const State) ?usize {
        var chosen: ?usize = null;
        for (self.records, 0..) |record, index| if (record) |value| {
            if (!self.available(index)) continue;
            if (chosen == null or value.start < self.records[chosen.?].?.start) chosen = index;
        };
        return chosen;
    }
    pub fn next(self: *const State, index: usize) ?usize {
        for (1..self.records.len + 1) |step| {
            const candidate = (index + step) % self.records.len;
            if (self.available(candidate)) return candidate;
        }
        return null;
    }
    pub fn dismiss(self: *State, key: Key) void {
        if (self.find(key)) |index| self.records[index].?.dismissed = true;
    }
    pub fn fail(self: *State, target: usize) void {
        for (&self.records) |*record| if (record.*) |*value| {
            if (value.target == target) value.stale = true;
        };
    }
    /// Retire unavailable calendars immediately, while retaining identity-keyed
    /// dismissals in case this calendar is later selected or authorized again.
    pub fn deactivate(self: *State, target_index: usize) void {
        self.targets[target_index].active = false;
        for (&self.records) |*record| if (record.*) |*value| {
            if (value.target != target_index) continue;
            if (value.dismissed) value.present = false else record.* = null;
        };
    }
    pub fn calendars(self: *State, account: u8, address: []const u8, result: j.Value) !void {
        const validated = try validateCalendars(address, result);
        const complete = validated.complete;
        const cached = validated.cached;
        const stale = validated.stale;
        const entries = validated.entries;
        if (!complete or cached or stale) return;
        // Release obsolete owned slots first, including at full capacity. Other
        // accounts retain their slots; identity-keyed dismissal records survive.
        for (&self.targets, 0..) |*old, index| {
            if (!old.active or old.account != account) continue;
            var retained = false;
            for (entries.array.items) |entry| {
                const value = j.get(entry, "calendar").?;
                if (try j.boolean(entry, "canRead", false) and (try j.boolean(value, "primary", false) or try j.boolean(value, "selected", false)) and std.mem.eql(u8, old.id.slice(), j.text(j.get(value, "target").?, "calendar_id"))) {
                    retained = true;
                    break;
                }
            }
            if (!retained) self.deactivate(index);
        }
        var seen: [max_targets]bool = @splat(false);
        for (entries.array.items) |entry| {
            const value = j.get(entry, "calendar").?;
            if (!try j.boolean(entry, "canRead", false) or !(try j.boolean(value, "primary", false) or try j.boolean(value, "selected", false))) continue;
            const id = j.text(j.get(value, "target").?, "calendar_id");
            var selected: ?usize = null;
            for (self.targets, 0..) |target, index| if (target.active and target.account == account and std.mem.eql(u8, target.id.slice(), id)) {
                selected = index;
                break;
            };
            if (selected == null) for (self.targets, 0..) |target, index| if (!target.active and !seen[index]) {
                selected = index;
                // A reused slot cannot inherit another calendar's records.
                self.deactivate(index);
                self.targets[index] = .{ .active = true, .account = account };
                try self.targets[index].id.set(id);
                break;
            };
            const index = selected orelse continue;
            seen[index] = true;
            self.targets[index].name.display(j.text(value, "summary"));
        }
        for (&self.targets, 0..) |*target, index| if (target.account == account and target.active and !seen[index]) {
            self.deactivate(index);
        };
    }
    pub fn ingest(self: *State, target_index: usize, address: []const u8, result: j.Value, now: i64) !void {
        const target = &self.targets[target_index];
        const snapshot = j.get(result, "snapshot") orelse return error.InvalidCalendarResponse;
        const owner = j.get(snapshot, "target") orelse return error.InvalidCalendarResponse;
        if (!std.mem.eql(u8, j.text(owner, "account"), address) or !std.mem.eql(u8, j.text(owner, "calendar_id"), target.id.slice())) return error.CalendarAccountMismatch;
        if (!try j.boolean(snapshot, "complete", false) or try j.boolean(snapshot, "stale", false) or try j.boolean(result, "cached", false) or j.text(result, "refreshError").len > 0) {
            self.fail(target_index);
            return;
        }
        const events = j.get(snapshot, "events") orelse return error.InvalidCalendarResponse;
        if (events != .array or events.array.items.len > calendar.Limits.snapshot_events) return error.InvalidCalendarResponse;
        var retained: [max_records]bool = @splat(false);
        // Validate the whole response before expiring or replacing any records.
        for (events.array.items) |event| {
            const event_target = j.get(event, "target") orelse return error.InvalidCalendarResponse;
            if (!std.mem.eql(u8, j.text(event_target, "account"), address) or !std.mem.eql(u8, j.text(event_target, "calendar_id"), target.id.slice())) return error.CalendarAccountMismatch;
            _ = try j.boolean(event, "cancelled", false);
            const span = reminderSpan(event, now) orelse continue;
            const join = j.text(event, "join_url");
            if (ui.canJoin(event) and join.len <= 2048 and !std.unicode.utf8ValidateSlice(join)) return error.InvalidUtf8;
            const key = eventKey(address, target.id.slice(), event, span.start);
            for (self.records, 0..) |record, index| if (record) |value| {
                if (std.mem.eql(u8, &value.key, &key)) {
                    retained[index] = true;
                    break;
                }
            };
        }
        self.expire(now);
        // Free absent non-dismissed records before admitting replacements, even
        // when every slot was occupied at the start of this complete snapshot.
        for (&self.records, 0..) |*record, index| if (record.*) |*value| {
            if (value.target != target_index) continue;
            value.present = retained[index];
            if (!value.present and !value.dismissed) record.* = null;
        };
        for (events.array.items) |event| {
            const span = reminderSpan(event, now) orelse continue;
            const start = span.start;
            const end = span.end;
            const key = eventKey(address, target.id.slice(), event, start);
            var slot: ?usize = null;
            for (self.records, 0..) |record, index| if (record) |value| {
                if (std.mem.eql(u8, &value.key, &key)) {
                    slot = index;
                    break;
                }
            };
            if (slot == null) for (self.records, 0..) |record, index| if (record == null) {
                slot = index;
                break;
            };
            // Never evict a dismissal to make room: refresh must not resurrect it.
            const index = slot orelse continue;
            const dismissed = if (self.records[index]) |old| old.dismissed else false;
            const announced = (if (self.records[index]) |old| old.announced else false) or start <= now +| lead_ms;
            self.records[index] = .{ .key = key, .target = @intCast(target_index), .start = start, .end = end, .dismissed = dismissed, .announced = announced, .observed_at = now };
            const record = &self.records[index].?;
            record.title.display(if (j.text(event, "summary").len > 0) j.text(event, "summary") else "Untitled event");
            record.location.display(j.text(event, "location"));
            if (ui.canJoin(event) and j.text(event, "join_url").len <= record.join.bytes.len) try record.join.set(j.text(event, "join_url"));
        }
    }
};
fn reminderSpan(event: j.Value, now: i64) ?struct { start: i64, end: i64 } {
    const start = instant(j.get(event, "start") orelse .null) orelse return null;
    const end = instant(j.get(event, "end") orelse .null) orelse return null;
    const cancelled = j.boolean(event, "cancelled", false) catch return null;
    if (end <= now or end <= start or start > now +| lead_ms +| 60000 or cancelled or std.mem.eql(u8, j.text(event, "response"), "declined") or j.text(event, "id").len == 0) return null;
    return .{ .start = start, .end = end };
}
pub fn instant(value: j.Value) ?i64 {
    if (!std.mem.eql(u8, j.text(value, "kind"), "instant")) return null;
    const result = j.get(value, "value") orelse return null;
    return if (result == .integer and result.integer >= 0) result.integer else null;
}
pub fn eventKey(account: []const u8, calendar_id: []const u8, event: j.Value, start: i64) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ account, calendar_id }) |text| {
        hash.update(text);
        hash.update(&.{0});
    }
    const series = j.text(event, "recurring_event_id");
    const original = instant(j.get(event, "original_start") orelse .null);
    if (series.len > 0 and original != null) {
        hash.update(series);
        const occurrence = original.?;
        hash.update(std.mem.asBytes(&occurrence));
    } else hash.update(j.text(event, "id"));
    hash.update(&.{0});
    hash.update(std.mem.asBytes(&start)); // A moved occurrence deserves a new reminder.
    return hash.finalResult();
}
pub fn minutes(record: *const Record, now: i64) i64 {
    const remaining = (if (now < record.start) record.start else record.end) -| now;
    return @divFloor(remaining +| 59999, 60000);
}

fn testEvent(a: std.mem.Allocator, id: []const u8, start: i64, end: i64) !j.Value {
    return j.value(a, .{ .target = .{ .account = "work@example.test", .calendar_id = "primary" }, .id = id, .summary = "Design review", .start = .{ .kind = "instant", .value = start }, .end = .{ .kind = "instant", .value = end }, .join_url = "https://meet.example.test/design" });
}
fn testSnapshot(a: std.mem.Allocator, events: []const j.Value, cached: bool) !j.Value {
    return j.value(a, .{ .cached = cached, .snapshot = .{ .target = .{ .account = "work@example.test", .calendar_id = "primary" }, .complete = true, .events = events } });
}
fn testState() !State {
    var state: State = .{};
    state.targets[0].active = true;
    try state.targets[0].id.set("primary");
    return state;
}

test "meeting notifications: exact lead boundary and until versus remaining use epoch instants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    const start = 2000000;
    const end = start + 3600000;
    const event = try testEvent(a, "one", start, end);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, false), start - lead_ms - 1);
    try std.testing.expectEqual(@as(usize, 0), state.count());
    // No provider refresh is needed at the exact lead boundary.
    state.expire(start - lead_ms);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    const record = &state.records[state.first().?].?;
    try std.testing.expectEqual(@as(i64, 10), minutes(record, start - lead_ms));
    try std.testing.expectEqual(@as(i64, 1), minutes(record, start - 1));
    try std.testing.expectEqual(@as(i64, 60), minutes(record, start));
    try std.testing.expectEqual(@as(i64, 45), minutes(record, start + 15 * 60000));
    try std.testing.expectEqual(@as(i64, 1), minutes(record, end - 1));
    state.expire(end);
    try std.testing.expectEqual(@as(usize, 0), state.count());
}

test "meeting notifications: dismissal survives refresh while moved and recurring instances stay distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    const start = 2000000;
    var event = try testEvent(a, "one", start, start + 3600000);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, false), start - lead_ms);
    const original = state.records[state.first().?].?.key;
    state.dismiss(original);
    try event.object.put(a, "summary", .{ .string = "Changed title" });
    try event.object.put(a, "sequence", .{ .integer = 99 });
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, false), start - lead_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), state.count());
    const moved = try testEvent(a, "one", start + 60000, start + 3600000);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{moved}, false), start - lead_ms + 60000);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expect(!std.mem.eql(u8, &original, &state.records[state.first().?].?.key));
    try event.object.put(a, "recurring_event_id", .{ .string = "series" });
    try event.object.put(a, "original_start", try j.value(a, .{ .kind = "instant", .value = start }));
    const instance_one = eventKey("work@example.test", "primary", event, start);
    try event.object.put(a, "original_start", try j.value(a, .{ .kind = "instant", .value = start + 86400000 }));
    const instance_two = eventKey("work@example.test", "primary", event, start);
    try std.testing.expect(!std.mem.eql(u8, &instance_one, &instance_two));
    const other_account = eventKey("other@example.test", "primary", event, start);
    const other_calendar = eventKey("work@example.test", "team", event, start);
    try std.testing.expect(!std.mem.eql(u8, &instance_two, &other_account));
    try std.testing.expect(!std.mem.eql(u8, &instance_two, &other_calendar));
}

test "meeting notifications: cached snapshots cannot announce and failed refresh preserves an existing reminder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    const start = 2000000;
    var event = try testEvent(a, "one", start, start + 3600000);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, true), start - lead_ms);
    try std.testing.expectEqual(@as(usize, 0), state.count());
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, false), start - lead_ms - 1);
    state.fail(0);
    state.expire(start - lead_ms);
    try std.testing.expectEqual(@as(usize, 0), state.count());
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, false), start - lead_ms);
    state.fail(0);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expect(state.records[state.first().?].?.stale);
    try std.testing.expectError(error.CalendarAccountMismatch, state.ingest(0, "other@example.test", try testSnapshot(a, &.{event}, false), start));
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try event.object.put(a, "cancelled", .{ .bool = true });
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{event}, false), start);
    try std.testing.expectEqual(@as(usize, 0), state.count());
}

test "meeting notifications: declined and all-day events are skipped and unsafe Join is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    const start = 2000000;
    var declined = try testEvent(a, "declined", start, start + 60000);
    try declined.object.put(a, "response", .{ .string = "declined" });
    var all_day = try testEvent(a, "all-day", start, start + 86400000);
    try all_day.object.put(a, "start", try j.value(a, .{ .kind = "date", .value = "2026-10-14" }));
    var unsafe = try testEvent(a, "unsafe", start, start + 60000);
    try unsafe.object.put(a, "join_url", .{ .string = "http://meet.example.test/design" });
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{ declined, all_day, unsafe }, false), start - lead_ms);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expectEqual(@as(usize, 0), state.records[state.first().?].?.join.len);
}

test "meeting notifications: bounded dismissal records never evict and full calendar replacement is immediate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    var events: [max_records]j.Value = undefined;
    for (&events, 0..) |*event, index| event.* = try testEvent(a, try std.fmt.allocPrint(a, "event-{d}", .{index}), 2000000, 5600000);
    const snapshot = try testSnapshot(a, &events, false);
    try state.ingest(0, "work@example.test", snapshot, 2000000 - lead_ms);
    try std.testing.expectEqual(max_records, state.count());
    while (state.first()) |index| state.dismiss(state.records[index].?.key);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{try testEvent(a, "overflow", 2000000, 5600000)}, false), 2000000);
    try state.ingest(0, "work@example.test", snapshot, 2000000);
    try std.testing.expectEqual(@as(usize, 0), state.count());
    for (&state.targets, 0..) |*target, index| {
        target.active = true;
        target.account = @intCast(index / calendar.Limits.calendars);
        try target.id.set(try std.fmt.allocPrint(a, "old-{d}", .{index}));
    }
    const list = try j.value(a, .{ .account = "work@example.test", .complete = true, .calendars = .{.{ .canRead = true, .calendar = .{ .target = .{ .account = "work@example.test", .calendar_id = "replacement" }, .summary = "New", .selected = true } }} });
    try state.calendars(0, "work@example.test", list);
    var owned: usize = 0;
    var other: usize = 0;
    for (state.targets) |target| if (target.active) {
        if (target.account == 0) {
            owned += 1;
            try std.testing.expectEqualStrings("replacement", target.id.slice());
        } else other += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), owned);
    try std.testing.expectEqual(@as(usize, 2 * calendar.Limits.calendars), other);
    for (state.records) |record| try std.testing.expect(record != null and record.?.dismissed);
}

test "meeting notifications: discovery honors selected primary read access and atomic identity validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    const list = try std.json.parseFromSliceLeaky(j.Value, a,
        \\{"account":"work@example.test","complete":true,"calendars":[
        \\{"canRead":true,"calendar":{"target":{"account":"work@example.test","calendar_id":"primary"},"primary":true,"selected":false}},
        \\{"canRead":true,"calendar":{"target":{"account":"work@example.test","calendar_id":"selected"},"selected":true}},
        \\{"canRead":true,"calendar":{"target":{"account":"work@example.test","calendar_id":"hidden"},"selected":false}},
        \\{"canRead":false,"calendar":{"target":{"account":"work@example.test","calendar_id":"unreadable"},"selected":true}}]}
    , .{});
    try state.calendars(0, "work@example.test", list);
    var active_count: usize = 0;
    for (state.targets) |target| if (target.active) {
        active_count += 1;
        try std.testing.expect(std.mem.eql(u8, target.id.slice(), "primary") or std.mem.eql(u8, target.id.slice(), "selected"));
    };
    try std.testing.expectEqual(@as(usize, 2), active_count);
    const bad = try j.value(a, .{ .account = "work@example.test", .complete = true, .calendars = .{.{ .canRead = true, .calendar = .{ .target = .{ .account = "other@example.test", .calendar_id = "wrong" }, .primary = true } }} });
    try std.testing.expectError(error.CalendarAccountMismatch, state.calendars(0, "work@example.test", bad));
    try std.testing.expect(state.targets[0].active and state.targets[1].active);
}

test "meeting notifications: authoritative replacements reclaim absent records before admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |moved| {
        var state = try testState();
        var events: [max_records]j.Value = undefined;
        for (&events, 0..) |*event, index| event.* = try testEvent(a, try std.fmt.allocPrint(a, "event-{d}", .{index}), 2000000, 5600000);
        try state.ingest(0, "work@example.test", try testSnapshot(a, &events, false), 2000000);
        const dismissed_key = state.records[0].?.key;
        state.dismiss(dismissed_key);
        const replacement = try testEvent(a, if (moved) "event-1" else "replacement", 2060000, 5600000);
        const replacement_key = eventKey("work@example.test", "primary", replacement, 2060000);
        try state.ingest(0, "work@example.test", try testSnapshot(a, &.{replacement}, false), 2000000);
        try std.testing.expectEqual(@as(usize, 1), state.count());
        try std.testing.expect(state.find(replacement_key) != null);
        var retained_dismissals: usize = 0;
        for (state.records) |record| if (record) |value| {
            if (std.mem.eql(u8, &value.key, &dismissed_key)) {
                try std.testing.expect(value.dismissed);
                retained_dismissals += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), retained_dismissals);
        // A later snapshot cannot resurrect the original dismissed occurrence.
        try state.ingest(0, "work@example.test", try testSnapshot(a, &.{ events[0], replacement }, false), 2000000);
        try std.testing.expectEqual(@as(usize, 1), state.count());
    }
}

test "meeting notifications: removed calendars release capacity without losing dismissal identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    state.targets[1].active = true;
    try state.targets[1].id.set("retained");
    var events: [max_records]j.Value = undefined;
    for (&events, 0..) |*event, index| event.* = try testEvent(a, try std.fmt.allocPrint(a, "event-{d}", .{index}), 2000000, 5600000);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &events, false), 2000000);
    const dismissed_key = state.records[0].?.key;
    state.dismiss(dismissed_key);
    const retained_entry = .{ .canRead = true, .calendar = .{ .target = .{ .account = "work@example.test", .calendar_id = "retained" }, .selected = true } };
    try state.calendars(0, "work@example.test", try j.value(a, .{ .account = "work@example.test", .complete = true, .calendars = .{retained_entry} }));
    try std.testing.expect(!state.targets[0].active and state.targets[1].active);
    var remaining: usize = 0;
    for (state.records) |record| if (record) |value| {
        remaining += 1;
        try std.testing.expect(value.dismissed);
        try std.testing.expectEqualSlices(u8, &dismissed_key, &value.key);
    };
    try std.testing.expectEqual(@as(usize, 1), remaining);
    var next = try testEvent(a, "retained-event", 2000000, 5600000);
    try next.object.put(a, "target", try j.value(a, retained_entry.calendar.target));
    try state.ingest(1, "work@example.test", try j.value(a, .{ .snapshot = .{ .target = retained_entry.calendar.target, .complete = true, .events = .{next} } }), 2000000);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    // Re-select the original calendar without resurfacing the dismissed event.
    try state.calendars(0, "work@example.test", try j.value(a, .{ .account = "work@example.test", .complete = true, .calendars = .{ retained_entry, .{ .canRead = true, .calendar = .{ .target = .{ .account = "work@example.test", .calendar_id = "primary" }, .selected = true } } } }));
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{events[0]}, false), 2000000);
    try std.testing.expectEqual(@as(usize, 1), state.count());
}

test "meeting notifications: malformed later event leaves an existing stale reminder intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    const old = try testEvent(a, "retained", 2000000, 5600000);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{old}, false), 2000000);
    state.fail(0);
    const previous = state.records[state.first().?].?;
    const replacement = try testEvent(a, "replacement", 2000000, 5600000);
    var malformed = try testEvent(a, "malformed", 2000000, 5600000);
    try malformed.object.put(a, "cancelled", .{ .string = "false" });
    try std.testing.expectError(error.InvalidRequest, state.ingest(0, "work@example.test", try testSnapshot(a, &.{ replacement, malformed }, false), 2000001));
    try std.testing.expectEqual(@as(usize, 1), state.count());
    const retained = state.records[state.first().?].?;
    try std.testing.expectEqualSlices(u8, &previous.key, &retained.key);
    try std.testing.expect(retained.present and retained.stale);
    try std.testing.expectEqual(previous.observed_at, retained.observed_at);
    try std.testing.expectEqual(previous.start, retained.start);
    try std.testing.expectEqual(previous.end, retained.end);
}

test "meeting notifications: permission deactivation frees records and retains dismissal tombstones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try testState();
    const dismissed = try testEvent(a, "dismissed", 2000000, 5600000);
    const visible = try testEvent(a, "visible", 2000000, 5600000);
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{ dismissed, visible }, false), 2000000);
    const dismissed_key = eventKey("work@example.test", "primary", dismissed, 2000000);
    state.dismiss(dismissed_key);
    state.targets[1].active = true;
    try state.targets[1].id.set("retained");
    const other_target = .{ .account = "work@example.test", .calendar_id = "retained" };
    var other = try testEvent(a, "other-calendar", 2000000, 5600000);
    try other.object.put(a, "target", try j.value(a, other_target));
    try state.ingest(1, "work@example.test", try j.value(a, .{ .snapshot = .{ .target = other_target, .complete = true, .events = .{other} } }), 2000000);
    state.deactivate(0);
    try std.testing.expect(!state.targets[0].active and state.targets[1].active);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    var retired_records: usize = 0;
    for (state.records) |record| if (record) |value| {
        if (value.target == 0) {
            retired_records += 1;
            try std.testing.expect(value.dismissed and !value.present);
            try std.testing.expectEqualSlices(u8, &dismissed_key, &value.key);
        }
    };
    try std.testing.expectEqual(@as(usize, 1), retired_records);
    state.targets[0].active = true;
    try state.ingest(0, "work@example.test", try testSnapshot(a, &.{ dismissed, visible }, false), 2000000);
    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expect(state.find(dismissed_key) == null);
}

test "meeting notifications: preference adapters must validate original list and flag types" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address = "work@example.test";
    for ([_][]const u8{
        \\{"account":"work@example.test","complete":false,"calendars":{}}
        ,
        \\{"account":"work@example.test","complete":true,"cached":"true","calendars":[]}
        ,
        \\{"account":"work@example.test","complete":true,"calendars":[{"canRead":true,"calendar":{"target":{"account":"work@example.test","calendar_id":"primary"},"primary":"true"}}]}
        ,
        \\{"account":"work@example.test","complete":true,"calendars":[{"canRead":true,"calendar":{"target":{"account":"work@example.test","calendar_id":"primary"},"selected":"true"}}]}
        ,
    }) |raw| {
        const value = try std.json.parseFromSliceLeaky(j.Value, a, raw, .{});
        if (validateCalendars(address, value)) |_| return error.InvalidListAccepted else |_| {}
    }
    const partial = try validateCalendars(address, try std.json.parseFromSliceLeaky(j.Value, a, "{\"account\":\"work@example.test\",\"complete\":false,\"calendars\":[]}", .{}));
    try std.testing.expect(!partial.complete and !partial.cached and !partial.stale);
}
