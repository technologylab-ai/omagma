//! Calendar contracts shared by the native TUI and its future CLI adapter.
//! Strings belong to the caller's bounded request/snapshot arena. No credentials,
//! files, network worker, or recurrence expansion live in these contracts.
const std = @import("std");
const b = @import("../bounded.zig");
pub const time = @import("calendar_time.zig");

pub const Limits = struct {
    pub const source_bytes = 128 * 1024;
    pub const source_properties = 1024;
    pub const source_line_bytes = 4096;
    pub const recurrence_lines = 64;
    pub const calendars = 24;
    pub const page_events = 100;
    pub const snapshot_events = 500;
    pub const response_bytes = 1024 * 1024;
    pub const snapshot_bytes = 4 * 1024 * 1024;
    pub const window_days = 31;
    pub const pages = 16;
};

pub const Target = struct {
    account: []const u8,
    calendar_id: []const u8,

    pub fn validate(self: Target) !void {
        try b.address(self.account);
        try text(self.calendar_id, 1024, false);
    }
    pub fn eql(self: Target, other: Target) bool {
        return std.ascii.eqlIgnoreCase(self.account, other.account) and std.mem.eql(u8, self.calendar_id, other.calendar_id);
    }
};

pub const Version = struct {
    sequence: u32,
    dtstamp_ms: i64,

    pub fn order(self: Version, previous: Version) std.math.Order {
        const sequence = std.math.order(self.sequence, previous.sequence);
        return if (sequence != .eq) sequence else std.math.order(self.dtstamp_ms, previous.dtstamp_ms);
    }
};

pub const Invitation = struct {
    account: []const u8,
    /// Exact received bytes, retained independently of presentation fields.
    source: []const u8,
    /// Complete unfolded source, including unknown properties and VTIMEZONE.
    unfolded: []const u8,
    source_hash: [32]u8,
    method: enum { request, cancel },
    uid: []const u8,
    organizer: []const u8,
    attendee: []const u8,
    version: Version,
    summary: []const u8 = "",
    description: []const u8 = "",
    location: []const u8 = "",
    url: []const u8 = "",
    join_url: []const u8 = "",
    start: ?time.Stamp = null,
    end: ?time.Stamp = null,
    duration: ?time.Duration = null,
    recurrence_id: ?time.Stamp = null,
    recurrence_range: []const u8 = "",
    recurrence: []const []const u8 = &.{},
    has_timezones: bool = false,
    cancelled: bool = false,
    transparent: bool = false,
    private: bool = false,

    pub fn isRecurring(self: Invitation) bool {
        return self.recurrence.len != 0 or self.recurrence_id != null;
    }
};

pub const Access = enum { none, free_busy, reader, writer_without_private, writer, owner };
pub const Calendar = struct {
    target: Target,
    summary: []const u8,
    time_zone: []const u8,
    access: Access,
    data_owner: []const u8 = "",
    primary: bool = false,
    selected: bool = false,
    /// ACL owner is not proof that calendar.events.owned covers this calendar.
    owned_scope_verified: bool = false,

    pub fn writable(self: Calendar) bool {
        return self.access == .writer_without_private or self.access == .writer or self.access == .owner;
    }
};

pub const Event = struct {
    target: Target,
    id: []const u8,
    uid: []const u8 = "",
    etag: []const u8 = "",
    organizer: []const u8 = "",
    summary: []const u8 = "",
    description: []const u8 = "",
    location: []const u8 = "",
    join_url: []const u8 = "",
    html_url: []const u8 = "",
    start: ?time.Point = null,
    end: ?time.Point = null,
    original_start: ?time.Point = null,
    recurring_event_id: []const u8 = "",
    sequence: u32 = 0,
    cancelled: bool = false,
    transparent: bool = false,
    locked: bool = false,
    private_copy: bool = false,
    response: enum { unknown, needs_action, accepted, tentative, declined } = .unknown,
    /// An opaque operation ID; never place account names or message bodies here.
    operation_marker: []const u8 = "",
    source_marker: []const u8 = "",
};

pub const Window = struct {
    start_ms: i64,
    end_ms: i64,
    time_zone: []const u8,

    pub fn validate(self: Window) !void {
        // A 31-civil-day window can span a daylight-saving offset change.
        if (self.start_ms < 0 or self.end_ms <= self.start_ms or self.end_ms - self.start_ms > (Limits.window_days * 86400 + 86400) * 1000) return error.CalendarWindowTooLarge;
        try time.validateZoneName(self.time_zone);
    }
};

pub const Page = struct {
    target: Target,
    events: []const Event,
    next_page_token: []const u8 = "",
    fetched_at_ms: i64,
    pub fn complete(self: Page) bool {
        return self.next_page_token.len == 0;
    }
};

pub const Snapshot = struct {
    target: Target,
    window: Window,
    events: []const Event,
    fetched_at_ms: i64,
    complete: bool,
    /// A failed refresh leaves the last snapshot intact and visibly stale.
    stale: bool = false,

    pub fn validate(self: Snapshot) !void {
        try self.target.validate();
        try self.window.validate();
        if (self.events.len > Limits.snapshot_events) return error.TooManyCalendarEvents;
        for (self.events) |event| if (!event.target.eql(self.target)) return error.CalendarAccountMismatch;
    }
};

pub fn text(value: []const u8, maximum: usize, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or value.len > maximum) return error.InvalidCalendarField;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidCalendarField;
}

test "calendar: source versions use sequence before DTSTAMP" {
    const previous: Version = .{ .sequence = 4, .dtstamp_ms = 2000 };
    try std.testing.expectEqual(std.math.Order.lt, (Version{ .sequence = 3, .dtstamp_ms = 3000 }).order(previous));
    try std.testing.expectEqual(std.math.Order.gt, (Version{ .sequence = 4, .dtstamp_ms = 3000 }).order(previous));
    try std.testing.expectEqual(std.math.Order.eq, previous.order(previous));
}
