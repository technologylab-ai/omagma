//! Stable native Day/Week disclosure. A bucket groups events occupying the
//! same displayed hour (or the all-day band), not necessarily events with
//! intersecting actual intervals. Timed events lasting a day or more belong to
//! the band, exactly as the grid draws them (calendar_grid.inBand).
//! No provider mutations, background rotation or inferred importance live here.
const std = @import("std");
const t = @import("calendar_types.zig");
const j = @import("json.zig");
const ui = @import("calendar_ui.zig");
const sources = @import("calendar_sources.zig");
const tz = @import("timezone.zig");
const grid = @import("calendar_grid.zig");
const Value = j.Value;

pub const Viewport = struct {
    first_day: i64,
    days: usize,
    first_hour: u8,
    hours: usize,
    pub fn validate(self: Viewport) !void {
        if (self.days == 0 or self.days > 7 or self.hours == 0 or self.hours > 24 or @as(usize, self.first_hour) + self.hours > 24) return error.InvalidCalendarViewport;
    }
};
pub const Bucket = struct {
    day: i64,
    hour: ?u8 = null,
    pub fn eql(self: Bucket, other: Bucket) bool {
        return self.day == other.day and self.hour == other.hour;
    }
};
pub const Identity = struct {
    target: t.Target,
    id: []const u8,
    start: t.time.Point,
    original_start: ?t.time.Point = null,
    recurring_id: []const u8 = "",
    pub fn init(event: Value) !Identity {
        const target = try sources.jsonTarget(event);
        const id = try j.required(event, "id");
        try t.text(id, 1024, false);
        const start = try point(j.get(event, "start") orelse return error.InvalidCalendarTime);
        // Points contain only borrowed strings here. The snapshot below takes
        // ownership of all strings before the underlying agenda can change.
        const original = j.get(event, "original_start") orelse @as(Value, .null);
        return .{ .target = target, .id = id, .start = start, .original_start = if (original == .null) null else try point(original), .recurring_id = j.text(event, "recurring_event_id") };
    }
    pub fn eql(self: Identity, other: Identity) bool {
        return self.target.eql(other.target) and std.mem.eql(u8, self.id, other.id) and self.start.eql(other.start) and std.mem.eql(u8, self.recurring_id, other.recurring_id) and optionalPointEql(self.original_start, other.original_start);
    }
    pub fn copy(self: Identity, a: std.mem.Allocator) !Identity {
        var result = self;
        result.target = .{ .account = try a.dupe(u8, self.target.account), .calendar_id = try a.dupe(u8, self.target.calendar_id) };
        result.id = try a.dupe(u8, self.id);
        result.recurring_id = try a.dupe(u8, self.recurring_id);
        result.start.zone = try a.dupe(u8, self.start.zone);
        if (self.original_start) |original| {
            result.original_start = original;
            result.original_start.?.zone = try a.dupe(u8, original.zone);
        }
        return result;
    }
};
fn optionalPointEql(first: ?t.time.Point, second: ?t.time.Point) bool {
    if (first) |value| return if (second) |other| value.eql(other) else false;
    return second == null;
}
fn point(value: Value) !t.time.Point {
    const kind = j.text(value, "kind");
    if (!std.mem.eql(u8, kind, "date") and !std.mem.eql(u8, kind, "instant")) return error.InvalidCalendarTime;
    const raw = j.get(value, "value") orelse return error.InvalidCalendarTime;
    if (raw != .integer) return error.InvalidCalendarTime;
    return .{ .kind = if (std.mem.eql(u8, kind, "date")) .date else .instant, .value = raw.integer, .zone = j.text(value, "zone") };
}
pub const Projection = struct { event: Value, identity: Identity, end: t.time.Point, visible_index: usize };
/// Decode each event once per frame, before walking day/hour cells. The returned
/// DTO slices borrow the unchanged agenda and are never retained by a chooser.
pub fn project(a: std.mem.Allocator, events: []const Value, filter: []const u8) ![]const Projection {
    if (events.len > sources.max_events) return error.CalendarTooLarge;
    var out: std.ArrayList(Projection) = .empty;
    errdefer out.deinit(a);
    for (events) |event| {
        if (!ui.matches(event, filter)) continue;
        try out.append(a, .{ .event = event, .identity = try Identity.init(event), .end = try point(j.get(event, "end") orelse return error.InvalidCalendarTime), .visible_index = out.items.len });
    }
    return out.toOwnedSlice(a);
}

pub const Query = union(enum) {
    bucket: Bucket,
    selected: struct { identity: Identity, viewport: Viewport },
};
const Mask = struct {
    first_day: i64,
    days: usize,
    all_day: bool,
    hours: [7]u32 = @splat(0),
    dates: u8 = 0,
    fn init(events: []const Value, query: Query, filter: []const u8, zone: *const tz.Zone) !Mask {
        return switch (query) {
            .bucket => |bucket| blk: {
                if (bucket.hour) |hour| {
                    if (hour >= 24) return error.InvalidCalendarViewport;
                    var mask: Mask = .{ .first_day = bucket.day, .days = 1, .all_day = false };
                    mask.hours[0] = @as(u32, 1) << @intCast(hour);
                    break :blk mask;
                }
                break :blk .{ .first_day = bucket.day, .days = 1, .all_day = true, .dates = 1 };
            },
            .selected => |selected| blk: {
                try selected.viewport.validate();
                const anchor = for (events) |event| {
                    if (ui.matches(event, filter) and (try Identity.init(event)).eql(selected.identity)) break event;
                } else return error.CalendarSelectionUnavailable;
                const start = try point(j.get(anchor, "start") orelse return error.InvalidCalendarTime);
                const end = try point(j.get(anchor, "end") orelse return error.InvalidCalendarTime);
                var mask: Mask = .{ .first_day = selected.viewport.first_day, .days = selected.viewport.days, .all_day = grid.inBand(start, end) };
                for (0..mask.days) |index| {
                    const day = mask.first_day + @as(i64, @intCast(index));
                    if (mask.all_day) {
                        if (try ui.touchesDay(start, end, day, zone)) mask.dates |= @as(u8, 1) << @intCast(index);
                    } else if (try ui.coverage(start, end, day, zone)) |coverage| {
                        for (0..selected.viewport.hours) |offset| {
                            const hour = selected.viewport.first_hour + offset;
                            if (coverage.first < (hour + 1) * 60 and coverage.end > hour * 60) mask.hours[index] |= @as(u32, 1) << @intCast(hour);
                        }
                    }
                }
                break :blk mask;
            },
        };
    }
    fn includes(self: *const Mask, event: Value, zone: *const tz.Zone) !bool {
        const start = try point(j.get(event, "start") orelse return error.InvalidCalendarTime);
        const end = try point(j.get(event, "end") orelse return error.InvalidCalendarTime);
        if (self.all_day != grid.inBand(start, end)) return false;
        for (0..self.days) |index| {
            const day = self.first_day + @as(i64, @intCast(index));
            if (self.all_day) {
                if (self.dates & (@as(u8, 1) << @intCast(index)) != 0 and try ui.touchesDay(start, end, day, zone)) return true;
            } else if (self.hours[index] != 0) {
                const coverage = (try ui.coverage(start, end, day, zone)) orelse continue;
                for (0..24) |hour| if (self.hours[index] & (@as(u32, 1) << @intCast(hour)) != 0 and coverage.first < (hour + 1) * 60 and coverage.end > hour * 60) return true;
            }
        }
        return false;
    }
};

/// Build the selected event's displayed-hour union from already decoded points.
/// No JSON reparse or candidate allocation happens inside the hour loops.
pub fn related(a: std.mem.Allocator, events: []const Projection, selection: usize, viewport: Viewport, zone: *const tz.Zone) ![]const usize {
    try viewport.validate();
    if (selection >= events.len) return &.{};
    const anchor = events[selection];
    const anchor_band = grid.inBand(anchor.identity.start, anchor.end);
    var hours: [7]u32 = @splat(0);
    var dates: u8 = 0;
    for (0..viewport.days) |column| {
        const day = viewport.first_day + @as(i64, @intCast(column));
        if (anchor_band) {
            if (try ui.touchesDay(anchor.identity.start, anchor.end, day, zone)) dates |= @as(u8, 1) << @intCast(column);
        } else if (try ui.coverage(anchor.identity.start, anchor.end, day, zone)) |coverage| {
            for (0..viewport.hours) |slot| {
                const hour = @as(usize, viewport.first_hour) + slot;
                if (coverage.first < (hour + 1) * 60 and coverage.end > hour * 60) hours[column] |= @as(u32, 1) << @intCast(hour);
            }
        }
    }
    var output: std.ArrayList(usize) = .empty;
    errdefer output.deinit(a);
    for (events, 0..) |event, index| {
        if (grid.inBand(event.identity.start, event.end) != anchor_band) continue;
        for (0..viewport.days) |column| {
            const day = viewport.first_day + @as(i64, @intCast(column));
            var matches = false;
            if (anchor_band) {
                matches = dates & (@as(u8, 1) << @intCast(column)) != 0 and try ui.touchesDay(event.identity.start, event.end, day, zone);
            } else if (hours[column] != 0) {
                const coverage = (try ui.coverage(event.identity.start, event.end, day, zone)) orelse continue;
                for (0..24) |hour| if (hours[column] & (@as(u32, 1) << @intCast(hour)) != 0 and coverage.first < (hour + 1) * 60 and coverage.end > hour * 60) {
                    matches = true;
                    break;
                };
            }
            if (matches) {
                try output.append(a, index);
                break;
            }
        }
    }
    return output.toOwnedSlice(a);
}

pub const Snapshot = struct {
    arena: ?std.heap.ArenaAllocator = null,
    events: []const Value = &.{},
    origin: ?Identity = null,
    pub fn deinit(self: *Snapshot) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn init(a: std.mem.Allocator, events: []const Value, query: Query, filter: []const u8, zone: *const tz.Zone, origin: ?Identity) !Snapshot {
        if (events.len > sources.max_events) return error.CalendarTooLarge;
        var result: Snapshot = .{ .arena = .init(a) };
        errdefer result.deinit();
        const owned = result.arena.?.allocator();
        const mask = try Mask.init(events, query, filter, zone);
        var values: std.ArrayList(Value) = .empty;
        for (events) |event| {
            if (!ui.matches(event, filter) or !try mask.includes(event, zone)) continue;
            _ = try Identity.init(event);
            // Each merged event is considered once even when it occupies many
            // selected hours. Calendar source merging already deduplicates IDs.
            try values.append(owned, event);
        }
        const raw = try std.json.Stringify.valueAlloc(owned, values.items, .{});
        // calendar_sources.merge bounds the aggregate displayed events from
        // all accounts below snapshot_bytes - 64KiB, not one cap per account.
        if (raw.len > t.Limits.snapshot_bytes) return error.CalendarTooLarge;
        const copied = try std.json.parseFromSliceLeaky(Value, owned, raw, .{ .allocate = .alloc_always });
        if (copied != .array) return error.InvalidCalendarResponse;
        std.mem.sort(Value, copied.array.items, {}, chronological);
        result.events = copied.array.items;
        if (origin) |value| result.origin = try value.copy(owned);
        return result;
    }
};

/// Resolve immediately before changing the selected row. A moved/cancelled or
/// missing occurrence is unavailable, never substituted by its array index.
pub fn findVisible(events: []const Value, identity: Identity, filter: []const u8) !?usize {
    var visible: usize = 0;
    for (events) |event| {
        if (!ui.matches(event, filter)) continue;
        if ((try Identity.init(event)).eql(identity)) return visible;
        visible += 1;
    }
    return null;
}

pub const Rank = struct { identity: Identity, declined: bool = false, starts_here: bool = false, preferred: bool = false };
/// Non-declined events, a start in this cell, then a saved preferred source.
/// Last tie-breaks are stable identities, with no clock/title/recurrence guess.
pub fn outranks(candidate: Rank, current: Rank) bool {
    if (candidate.declined != current.declined) return !candidate.declined;
    if (candidate.starts_here != current.starts_here) return candidate.starts_here;
    if (candidate.preferred != current.preferred) return candidate.preferred;
    return identityOrder(candidate.identity, current.identity) == .lt;
}
pub fn startHour(start: t.time.Point, zone: *const tz.Zone) !u8 {
    if (start.kind != .instant) return error.InvalidCalendarTime;
    const seconds = @divFloor(start.value, 1000);
    return @intCast(@divFloor(@mod(seconds + try zone.offsetSeconds(seconds), 86400), 3600));
}
fn inViewport(bucket: Bucket, viewport: Viewport) bool {
    return bucket.day >= viewport.first_day and bucket.day < viewport.first_day + @as(i64, @intCast(viewport.days)) and (if (bucket.hour) |hour| hour >= viewport.first_hour and hour < @as(usize, viewport.first_hour) + viewport.hours else true);
}
fn touchesBucket(event: Projection, bucket: Bucket, zone: *const tz.Zone) !bool {
    const band = grid.inBand(event.identity.start, event.end);
    if (bucket.hour) |hour| {
        if (band or event.identity.start.kind != .instant) return false;
        const coverage = (try ui.coverage(event.identity.start, event.end, bucket.day, zone)) orelse return false;
        return coverage.first < (@as(usize, hour) + 1) * 60 and coverage.end > @as(usize, hour) * 60;
    }
    return band and try ui.touchesDay(event.identity.start, event.end, bucket.day, zone);
}
/// A reveal belongs to one civil bucket, never every hour of a long routine.
/// Clicked buckets survive refresh/resize; if clipped, use the real start or
/// first currently visible occupied bucket without changing selected identity.
pub fn revealBucket(event: Projection, viewport: Viewport, zone: *const tz.Zone, requested: ?Bucket) !?Bucket {
    if (requested) |bucket| if (inViewport(bucket, viewport) and try touchesBucket(event, bucket, zone)) return bucket;
    const band = grid.inBand(event.identity.start, event.end);
    const actual: Bucket = .{ .day = try ui.pointDay(event.identity.start, zone), .hour = if (band) null else try startHour(event.identity.start, zone) };
    if (inViewport(actual, viewport) and try touchesBucket(event, actual, zone)) return actual;
    for (0..viewport.days) |column| {
        const day = viewport.first_day + @as(i64, @intCast(column));
        if (band) {
            const bucket: Bucket = .{ .day = day };
            if (try touchesBucket(event, bucket, zone)) return bucket;
        } else for (0..viewport.hours) |slot| {
            const bucket: Bucket = .{ .day = day, .hour = @intCast(@as(usize, viewport.first_hour) + slot) };
            if (try touchesBucket(event, bucket, zone)) return bucket;
        }
    }
    return null;
}
/// Chronological chooser ordering never follows preferred-source/grid ranking.
fn chronological(_: void, first: Value, second: Value) bool {
    const a = Identity.init(first) catch return false;
    const b = Identity.init(second) catch return true;
    return identityOrder(a, b) == .lt;
}

pub const Secondary = struct { index: ?usize = null, hidden: usize = 0 };
/// `related_indices` is the distinct visible-row union. Preview a genuinely
/// hidden alternative first; counts never include titles already on the grid.
pub fn secondary(events: []const Projection, related_indices: []const usize, visible: []const bool, selection: usize, preferences: *const sources.Selection) Secondary {
    var result: Secondary = .{};
    for (related_indices) |index| {
        if (index >= events.len or index >= visible.len or index == selection) continue;
        if (!visible[index]) result.hidden += 1;
    }
    var chosen: ?Rank = null;
    for (related_indices) |index| {
        if (index >= events.len or index >= visible.len or index == selection or (result.hidden > 0 and visible[index])) continue;
        const event = events[index];
        const rank: Rank = .{ .identity = event.identity, .declined = std.mem.eql(u8, j.text(event.event, "response"), "declined"), .preferred = preferences.isPreferred(event.identity.target) };
        if (chosen == null or outranks(rank, chosen.?)) {
            chosen = rank;
            result.index = index;
        }
    }
    return result;
}
fn identityOrder(first: Identity, second: Identity) std.math.Order {
    if (first.start.kind != second.start.kind) return std.math.order(@backingInt(first.start.kind), @backingInt(second.start.kind));
    if (first.start.value != second.start.value) return std.math.order(first.start.value, second.start.value);
    const account = std.ascii.orderIgnoreCase(first.target.account, second.target.account);
    if (account != .eq) return account;
    const calendar = std.mem.order(u8, first.target.calendar_id, second.target.calendar_id);
    if (calendar != .eq) return calendar;
    const id = std.mem.order(u8, first.id, second.id);
    if (id != .eq) return id;
    const recurring = std.mem.order(u8, first.recurring_id, second.recurring_id);
    if (recurring != .eq) return recurring;
    if (first.original_start) |value| {
        const other = second.original_start orelse return .gt;
        if (value.kind != other.kind) return std.math.order(@backingInt(value.kind), @backingInt(other.kind));
        return std.math.order(value.value, other.value);
    }
    return if (second.original_start != null) .lt else .eq;
}

fn fixture(a: std.mem.Allocator) !Value {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/terminal/calendar/week-overlaps.json", a, .limited(t.Limits.snapshot_bytes));
    return std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
}
fn expectIds(events: []const Value, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, events.len);
    for (events, expected) |event, id| try std.testing.expectEqualStrings(id, j.text(event, "id"));
}

test "calendar slots: exact hour includes all co-displayed events without claiming interval conflicts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try fixture(a);
    const events = j.get(data, "events").?.array.items;
    const day = try tz.dateDay(j.text(data, "day"));
    const zone: tz.Zone = .{};
    var snapshot = try Snapshot.init(std.testing.allocator, events, .{ .bucket = .{ .day = day, .hour = 10 } }, "", &zone, null);
    defer snapshot.deinit();
    try expectIds(snapshot.events, &.{ "weekly-routine", "early-check-in", "special-visit" });
    // The two short events do not overlap each other, but share an hourly row.
    const visit = try Identity.init(snapshot.events[2]);
    const early_end = try point(j.get(snapshot.events[1], "end").?);
    try std.testing.expect(early_end.value <= visit.start.value);
    var next = try Snapshot.init(std.testing.allocator, events, .{ .bucket = .{ .day = day, .hour = 11 } }, "", &zone, null);
    defer next.deinit();
    try expectIds(next.events, &.{ "weekly-routine", "next-hour" });
    var filtered = try Snapshot.init(std.testing.allocator, events, .{ .bucket = .{ .day = day, .hour = 10 } }, "visit", &zone, null);
    defer filtered.deinit();
    try expectIds(filtered.events, &.{"special-visit"});
}

test "calendar slots: selected event unions visible occupied hours once and all-day dates stay separate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try fixture(a);
    const events = j.get(data, "events").?.array.items;
    const day = try tz.dateDay(j.text(data, "day"));
    const zone: tz.Zone = .{};
    const origin = try Identity.init(events[0]);
    const viewport: Viewport = .{ .first_day = day, .days = 7, .first_hour = 10, .hours = 2 };
    var timed = try Snapshot.init(std.testing.allocator, events, .{ .selected = .{ .identity = origin, .viewport = viewport } }, "", &zone, origin);
    defer timed.deinit();
    try expectIds(timed.events, &.{ "weekly-routine", "early-check-in", "special-visit", "next-hour" });
    try std.testing.expect(timed.origin.?.eql(origin));
    var dates = try Snapshot.init(std.testing.allocator, events, .{ .bucket = .{ .day = day } }, "", &zone, null);
    defer dates.deinit();
    try expectIds(dates.events, &.{ "travel", "home", "holiday" });
    var tomorrow = try Snapshot.init(std.testing.allocator, events, .{ .bucket = .{ .day = day + 1 } }, "", &zone, null);
    defer tomorrow.deinit();
    try expectIds(tomorrow.events, &.{"home"});
    var midnight = try Snapshot.init(std.testing.allocator, events, .{ .bucket = .{ .day = day + 1, .hour = 0 } }, "", &zone, null);
    defer midnight.deinit();
    try expectIds(midnight.events, &.{"overnight"});
    var clipped = try Snapshot.init(std.testing.allocator, events, .{ .selected = .{ .identity = try Identity.init(events[4]), .viewport = viewport } }, "", &zone, null);
    defer clipped.deinit();
    try std.testing.expectEqual(@as(usize, 0), clipped.events.len);
}

test "calendar slots: snapshots own candidates and exact identity survives reorder without retargeting" {
    const a = std.testing.allocator;
    var snapshot: Snapshot = .{};
    defer snapshot.deinit();
    {
        var source_arena: std.heap.ArenaAllocator = .init(a);
        defer source_arena.deinit();
        const data = try fixture(source_arena.allocator());
        const events = j.get(data, "events").?.array.items;
        const day = try tz.dateDay(j.text(data, "day"));
        const zone: tz.Zone = .{};
        snapshot = try Snapshot.init(a, events, .{ .bucket = .{ .day = day, .hour = 10 } }, "", &zone, try Identity.init(events[1]));
    }
    try std.testing.expectEqualStrings("Special visit", j.text(snapshot.events[2], "summary"));
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var moved = try j.copyObject(scratch, snapshot.events[2]);
    const start = (try Identity.init(moved)).start;
    try moved.object.put(scratch, "start", try j.value(scratch, .{ .kind = "instant", .value = start.value + 3600000 }));
    const reordered = [_]Value{ snapshot.events[1], moved, snapshot.events[0], snapshot.events[2] };
    try std.testing.expectEqual(@as(?usize, 3), try findVisible(&reordered, snapshot.origin.?, ""));
    try std.testing.expect((try findVisible(reordered[0..3], snapshot.origin.?, "")) == null);
    var cancelled = try j.copyObject(scratch, snapshot.events[2]);
    try cancelled.object.put(scratch, "cancelled", .{ .bool = true });
    try std.testing.expect((try findVisible(&.{cancelled}, snapshot.origin.?, "")) == null);
    var foreign = try j.copyObject(scratch, snapshot.events[2]);
    try foreign.object.put(scratch, "target", try j.value(scratch, .{ .account = "personal@example.com", .calendar_id = "work@example.com" }));
    try std.testing.expect((try findVisible(&.{foreign}, snapshot.origin.?, "")) == null);
}

test "calendar slots: stable ranking uses nondeclined starts preferred source then complete identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const data = try fixture(arena.allocator());
    const events = j.get(data, "events").?.array.items;
    const routine: Rank = .{ .identity = try Identity.init(events[0]), .preferred = true };
    const visit: Rank = .{ .identity = try Identity.init(events[1]), .starts_here = true };
    try std.testing.expect(outranks(visit, routine));
    var declined = visit;
    declined.declined = true;
    try std.testing.expect(outranks(routine, declined));
    var preferred = visit;
    preferred.preferred = true;
    try std.testing.expect(outranks(preferred, visit));
    try std.testing.expect(!outranks(visit, preferred));
    var next = visit;
    next.identity.target = .{ .account = "work@example.com", .calendar_id = "z-calendar" };
    try std.testing.expect(outranks(visit, next));
    next = visit;
    next.identity.original_start = .{ .kind = .instant, .value = visit.identity.start.value + 1 };
    try std.testing.expect(!next.identity.eql(visit.identity));
    try std.testing.expect(outranks(visit, next));
}

test "calendar slots: repeated DST hour keeps both exact instants and civil all-day dates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone = try tz.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    const first = try t.time.rfc3339("2026-10-25T00:15:00Z");
    const second = try t.time.rfc3339("2026-10-25T01:15:00Z");
    const raw = try j.value(a, .{ .{
        .target = .{ .account = "personal@example.com", .calendar_id = "primary" },
        .id = "fold-first",
        .summary = "First occurrence",
        .start = .{ .kind = "instant", .value = first },
        .end = .{ .kind = "instant", .value = first + 600000 },
    }, .{
        .target = .{ .account = "personal@example.com", .calendar_id = "primary" },
        .id = "fold-second",
        .summary = "Second occurrence",
        .start = .{ .kind = "instant", .value = second },
        .end = .{ .kind = "instant", .value = second + 600000 },
    } });
    var snapshot = try Snapshot.init(std.testing.allocator, raw.array.items, .{ .bucket = .{ .day = try tz.dateDay("2026-10-25"), .hour = 2 } }, "", &zone, null);
    defer snapshot.deinit();
    try expectIds(snapshot.events, &.{ "fold-first", "fold-second" });
    try std.testing.expect(!(try Identity.init(snapshot.events[0])).eql(try Identity.init(snapshot.events[1])));
    try std.testing.expectError(error.InvalidCalendarViewport, (Viewport{ .first_day = 0, .days = 8, .first_hour = 0, .hours = 24 }).validate());
    try std.testing.expectError(error.InvalidCalendarViewport, (Viewport{ .first_day = 0, .days = 7, .first_hour = 23, .hours = 2 }).validate());
}

fn gridItems(a: std.mem.Allocator, values: []const Projection, day: i64, zone: *const tz.Zone) ![]const grid.Item {
    var result: std.ArrayList(grid.Item) = .empty;
    for (values) |value| {
        if (grid.inBand(value.identity.start, value.end)) continue;
        const span = (try ui.coverage(value.identity.start, value.end, day, zone)) orelse continue;
        try result.append(a, .{ .first = span.first, .end = span.end });
    }
    return result.items;
}

test "calendar slots: fixture day lays every overlapping event out side by side and keeps the visible-row union" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try fixture(a);
    const events = j.get(data, "events").?.array.items;
    const values = try project(a, events, "");
    const zone: tz.Zone = .{};
    const day = try tz.dateDay(j.text(data, "day"));
    // Routine 09:00–12:00, check-in 10:05–10:20, visit 10:30–11:00,
    // next-hour call 11:00–11:30 and the 23:30 overnight start.
    const placements = try grid.place(a, try gridItems(a, values, day, &zone), 2, 3 * grid.min_lane_cells, null);
    try std.testing.expectEqual(@as(usize, 5), placements.len);
    for (placements) |placement| try std.testing.expect(!placement.hidden);
    try std.testing.expectEqual(@as(u8, 0), placements[0].lane);
    for (placements[1..4]) |placement| try std.testing.expectEqual(@as(u8, 1), placement.lane);
    try std.testing.expectEqual(@as(u8, 2), placements[0].lanes);
    try std.testing.expectEqual(@as(u8, 1), placements[4].lanes);
    const viewport: Viewport = .{ .first_day = day, .days = 7, .first_hour = 10, .hours = 3 };
    const related_indices = try related(a, values, 0, viewport, &zone);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, related_indices);
}

test "calendar slots: two-hour rollback keeps the actual start bucket and its whole civil coverage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone = try tz.Zone.fromPosix("STD0DST-2,M3.5.0/2,M10.5.0/3");
    const start = try t.time.rfc3339("2026-10-25T00:45:00Z");
    const end = try t.time.rfc3339("2026-10-25T01:15:00Z");
    const values = try j.value(a, .{.{ .target = .{ .account = "personal@example.com", .calendar_id = "primary" }, .id = "rollback", .start = .{ .kind = "instant", .value = start }, .end = .{ .kind = "instant", .value = end } }});
    const projected = try project(a, values.array.items, "");
    const day = try tz.dateDay("2026-10-25");
    try std.testing.expectEqual(@as(u8, 2), try startHour(projected[0].identity.start, &zone));
    // 02:45 DST until 01:15 standard time: civil rows 01:14 to 02:46.
    const placement = (try grid.place(a, try gridItems(a, projected, day, &zone), 1, grid.min_lane_cells, null))[0];
    try std.testing.expectEqual(@as(usize, 1), placement.top);
    try std.testing.expectEqual(@as(usize, 3), placement.bottom);
    const viewport: Viewport = .{ .first_day = day, .days = 1, .first_hour = 0, .hours = 24 };
    try std.testing.expect((try revealBucket(projected[0], viewport, &zone, null)).?.eql(.{ .day = day, .hour = 2 }));
    try std.testing.expect((try revealBucket(projected[0], viewport, &zone, .{ .day = day, .hour = 1 })).?.eql(.{ .day = day, .hour = 1 }));
}

test "calendar slots: zero-duration event exactly on the hour has a block, a bucket and a selected union" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = try j.value(a, .{.{ .target = .{ .account = "personal@example.com", .calendar_id = "primary" }, .id = "point-event", .start = .{ .kind = "instant", .value = 36000000 }, .end = .{ .kind = "instant", .value = 36000000 } }});
    const projected = try project(a, values.array.items, "");
    const zone: tz.Zone = .{};
    const viewport: Viewport = .{ .first_day = 0, .days = 1, .first_hour = 10, .hours = 1 };
    const placement = (try grid.place(a, try gridItems(a, projected, 0, &zone), 2, 2 * grid.min_lane_cells, null))[0];
    try std.testing.expect(!placement.hidden and placement.top == 20 and placement.bottom == 21);
    var snapshot = try Snapshot.init(std.testing.allocator, values.array.items, .{ .bucket = .{ .day = 0, .hour = 10 } }, "", &zone, null);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.events.len);
    const union_indices = try related(a, projected, 0, viewport, &zone);
    try std.testing.expectEqualSlices(usize, &.{0}, union_indices);
}

test "calendar slots: day-long timed events are band entries for buckets, reveal and unions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day: i64 = 20000;
    const base = day * 86400000;
    const target = .{ .account = "personal@example.com", .calendar_id = "primary" };
    const values = try j.value(a, .{
        .{ .target = target, .id = "on-call", .start = .{ .kind = "instant", .value = base - 6 * 3600000 }, .end = .{ .kind = "instant", .value = base + 3 * 86400000 } },
        .{ .target = target, .id = "holiday", .start = .{ .kind = "date", .value = day + 1 }, .end = .{ .kind = "date", .value = day + 2 } },
        .{ .target = target, .id = "meeting", .start = .{ .kind = "instant", .value = base + 10 * 3600000 }, .end = .{ .kind = "instant", .value = base + 11 * 3600000 } },
    });
    const projected = try project(a, values.array.items, "");
    const zone: tz.Zone = .{};
    var all_day = try Snapshot.init(std.testing.allocator, values.array.items, .{ .bucket = .{ .day = day + 1 } }, "", &zone, null);
    defer all_day.deinit();
    // The chooser lists civil dates before timed starts.
    try expectIds(all_day.events, &.{ "holiday", "on-call" });
    var hour = try Snapshot.init(std.testing.allocator, values.array.items, .{ .bucket = .{ .day = day, .hour = 10 } }, "", &zone, null);
    defer hour.deinit();
    try expectIds(hour.events, &.{"meeting"});
    const viewport: Viewport = .{ .first_day = day, .days = 7, .first_hour = 8, .hours = 10 };
    try std.testing.expect((try revealBucket(projected[0], viewport, &zone, null)).?.eql(.{ .day = day }));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, try related(a, projected, 0, viewport, &zone));
    try std.testing.expectEqualSlices(usize, &.{2}, try related(a, projected, 2, viewport, &zone));
}

test "calendar slots: hidden preview favors nondeclined then preferred and counts distinct undisplayed alternatives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try fixture(a);
    const events = j.get(data, "events").?.array.items;
    const values = try project(a, events, "");
    var preferences: sources.Selection = .{};
    try preferences.setPreferred(values[1].identity.target);
    const visible = [_]bool{ true, true, false, false, true, true, true, true };
    const first = secondary(values, &.{ 0, 1, 2, 3 }, &visible, 0, &preferences);
    try std.testing.expectEqual(@as(?usize, 2), first.index);
    try std.testing.expectEqual(@as(usize, 2), first.hidden);
    var declined = try j.copyObject(a, values[2].event);
    try declined.object.put(a, "response", .{ .string = "declined" });
    const changed = try a.dupe(Projection, values);
    changed[2].event = declined;
    const after = secondary(changed, &.{ 0, 1, 2, 3 }, &visible, 0, &preferences);
    try std.testing.expectEqual(@as(?usize, 3), after.index);
    try std.testing.expectEqual(@as(usize, 2), after.hidden);
    const all_visible: [8]bool = @splat(true);
    const fallback = secondary(values, &.{ 0, 1, 2, 3 }, &all_visible, 0, &preferences);
    try std.testing.expectEqual(@as(?usize, 1), fallback.index);
    try std.testing.expectEqual(@as(usize, 0), fallback.hidden);
}
