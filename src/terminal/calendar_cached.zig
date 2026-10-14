//! Offline Calendar reads. Local validated grants remain mandatory; provider
//! access and membership are explicitly stale. No mutation or availability
//! assertion can route through this module.
const std = @import("std");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const service = @import("calendar_service.zig");
const commands = @import("calendar_commands.zig");
const persistence = @import("calendar_store.zig");

pub fn supported(command: []const u8) bool {
    return std.mem.eql(u8, command, "calendar.list") or std.mem.eql(u8, command, "calendar.agenda") or std.mem.eql(u8, command, "calendar.event");
}

pub fn connectionFailure(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.TemporaryNameServerFailure,
        error.UnknownHostName,
        error.Timeout,
        error.DeadlineExceeded,
        error.CalendarUnavailable,
        error.CalendarRateLimited,
        error.TransientFailure,
        error.RateLimited,
        => true,
        else => false,
    };
}

pub fn dispatch(a: std.mem.Allocator, grants: service.Grants, store: *persistence.Host, request: j.Value, inputs: commands.HostInputs, reason: []const u8) !j.Value {
    try commands.preflight(request);
    const command = try j.required(request, "cmd");
    if (!supported(command)) return error.CacheUnsupported;
    const account = try j.required(request, "account");
    if (!std.mem.eql(u8, account, grants.account) or !std.mem.eql(u8, account, store.account)) return error.CalendarAccountMismatch;
    if (!grants.calendar_list) return error.CalendarPermissionRequired;
    const cache = store.cache();
    const load = cache.loadCalendarsFn orelse return error.CalendarNotCached;
    const list = try load(cache.context, a) orelse return error.CalendarNotCached;
    if (std.mem.eql(u8, command, "calendar.list")) {
        const View = struct { calendar: t.Calendar, canRead: bool, canWrite: bool = false, canFreeBusy: bool = false };
        const values = try a.alloc(View, list.calendars.len);
        for (list.calendars, values) |calendar, *value| value.* = .{ .calendar = calendar, .canRead = grants.canRead(calendar) };
        return j.value(a, .{ .account = account, .calendars = values, .complete = list.complete, .cached = true, .stale = true, .refreshError = reason });
    }
    const target: t.Target = .{ .account = account, .calendar_id = try j.required(request, "calendarId") };
    var chosen: ?t.Calendar = null;
    for (list.calendars) |calendar| if (calendar.target.eql(target)) {
        chosen = calendar;
        break;
    };
    const calendar = chosen orelse return error.CalendarNotCached;
    if (!grants.canRead(calendar)) return error.CalendarReadPermissionRequired;
    if (std.mem.eql(u8, command, "calendar.event")) {
        const event = try store.cachedEvent(a, target, try j.required(request, "eventId")) orelse return error.CalendarEventNotCached;
        return j.value(a, .{ .calendar = calendar, .event = event, .cached = true, .stale = true, .refreshError = reason });
    }
    const window = try commands.requestWindow(a, request, inputs, calendar);
    var snapshot = try cache.loadFn(cache.context, a, target, window) orelse return error.CalendarNotCached;
    snapshot.stale = true;
    return j.value(a, .{ .calendar = calendar, .snapshot = snapshot, .cached = true, .refreshError = reason });
}
