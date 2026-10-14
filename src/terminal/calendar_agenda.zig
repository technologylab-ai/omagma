//! A bounded staging snapshot. Only a fully fetched snapshot replaces the last
//! known complete cache; partial results cannot erase events or claim free time.
const std = @import("std");
const t = @import("calendar_types.zig");

pub const Builder = struct {
    target: t.Target,
    window: t.Window,
    events: std.ArrayList(t.Event) = .empty,
    next_page_token: []const u8 = "",
    pages: usize = 0,
    bytes: usize = 0,
    fetched_at_ms: i64 = 0,
    complete: bool = false,

    pub fn init(target: t.Target, window: t.Window) !Builder {
        try target.validate();
        try window.validate();
        return .{ .target = target, .window = window };
    }
    pub fn deinit(self: *Builder, a: std.mem.Allocator) void {
        self.events.deinit(a);
    }
    pub fn append(self: *Builder, a: std.mem.Allocator, page: t.Page, requested_page_token: []const u8) !void {
        if (self.complete or !std.mem.eql(u8, self.next_page_token, requested_page_token)) return error.CalendarPageMismatch;
        if (!page.target.eql(self.target)) return error.CalendarAccountMismatch;
        if (self.pages == t.Limits.pages or page.events.len > t.Limits.page_events or self.events.items.len + page.events.len > t.Limits.snapshot_events) return error.TooManyCalendarEvents;
        if (page.next_page_token.len != 0 and std.mem.eql(u8, page.next_page_token, requested_page_token)) return error.CalendarPageMismatch;
        var added_bytes: usize = 0;
        for (page.events, 0..) |event, index| {
            if (!event.target.eql(self.target)) return error.CalendarAccountMismatch;
            for (self.events.items) |previous| if (std.mem.eql(u8, event.id, previous.id)) return error.CalendarPageOverlap;
            for (page.events[0..index]) |previous| if (std.mem.eql(u8, event.id, previous.id)) return error.CalendarPageOverlap;
            added_bytes += retainedBytes(event);
        }
        if (self.bytes + added_bytes > t.Limits.snapshot_bytes) return error.CalendarSnapshotTooLarge;
        try self.events.appendSlice(a, page.events);
        self.bytes += added_bytes;
        self.pages += 1;
        self.next_page_token = page.next_page_token;
        self.fetched_at_ms = @max(self.fetched_at_ms, page.fetched_at_ms);
        self.complete = page.complete();
    }
    pub fn snapshot(self: *const Builder) !t.Snapshot {
        if (!self.complete) return error.CalendarSnapshotIncomplete;
        return .{ .target = self.target, .window = self.window, .events = self.events.items, .fetched_at_ms = self.fetched_at_ms, .complete = true };
    }
};

fn retainedBytes(event: t.Event) usize {
    var bytes: usize = @sizeOf(t.Event);
    for ([_][]const u8{ event.target.account, event.target.calendar_id, event.id, event.uid, event.etag, event.organizer, event.summary, event.description, event.location, event.join_url, event.html_url, event.recurring_event_id, event.operation_marker, event.source_marker }) |value| bytes += value.len;
    if (event.start) |point| bytes += point.zone.len;
    if (event.end) |point| bytes += point.zone.len;
    if (event.original_start) |point| bytes += point.zone.len;
    return bytes;
}

pub const Availability = struct {
    overlaps: usize = 0,
    /// False means not checked completely, not available/free.
    complete: bool = true,
};

/// Check selected cached calendars only. Busy-only calendars and unavailable
/// calendars must be represented by the caller as incomplete snapshots.
/// Comparing all-day dates with timed instants requires a calendar-zone
/// resolver, so this first slice reports incomplete rather than guessing.
pub fn availability(snapshots: []const t.Snapshot, start: t.time.Point, end: t.time.Point, exclude_uid: []const u8) !Availability {
    if (start.kind != end.kind or end.value <= start.value) return error.InvalidCalendarTime;
    var result: Availability = .{ .complete = snapshots.len != 0 };
    var retained_events: usize = 0;
    for (snapshots) |snapshot| {
        try snapshot.validate();
        retained_events += snapshot.events.len;
        if (retained_events > t.Limits.snapshot_events) return error.TooManyCalendarEvents;
        if (!snapshot.complete or snapshot.stale) result.complete = false;
        if (start.kind != .instant or snapshot.window.start_ms > start.value or snapshot.window.end_ms < end.value) result.complete = false;
        for (snapshot.events) |event| {
            if (event.cancelled or event.transparent or event.response == .declined) continue;
            if (exclude_uid.len > 0 and std.mem.eql(u8, exclude_uid, event.uid)) continue;
            const event_start = event.start orelse {
                result.complete = false;
                continue;
            };
            const event_end = event.end orelse {
                result.complete = false;
                continue;
            };
            if (event_start.kind != start.kind or event_end.kind != end.kind) {
                result.complete = false;
                continue;
            }
            if (event_start.value < end.value and event_end.value > start.value) result.overlaps += 1;
        }
    }
    return result;
}

test "calendar: incomplete and stale snapshots never assert availability" {
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };
    const window: t.Window = .{ .start_ms = 0, .end_ms = 86400000, .time_zone = "UTC" };
    var builder = try Builder.init(target, window);
    defer builder.deinit(std.testing.allocator);
    try builder.append(std.testing.allocator, .{ .target = target, .events = &.{}, .next_page_token = "more", .fetched_at_ms = 100 }, "");
    try std.testing.expectError(error.CalendarSnapshotIncomplete, builder.snapshot());
    try builder.append(std.testing.allocator, .{ .target = target, .events = &.{}, .fetched_at_ms = 200 }, "more");
    var snapshot = try builder.snapshot();
    const start: t.time.Point = .{ .kind = .instant, .value = 1000 };
    const end: t.time.Point = .{ .kind = .instant, .value = 2000 };
    try std.testing.expect((try availability(&.{snapshot}, start, end, "")).complete);
    snapshot.stale = true;
    try std.testing.expect(!(try availability(&.{snapshot}, start, end, "")).complete);
}
