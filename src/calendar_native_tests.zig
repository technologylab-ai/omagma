const std = @import("std");
const native = @import("terminal/calendar_native.zig");
const provider = @import("terminal/calendar_provider.zig");
const permissions = @import("terminal/calendar_permissions.zig");
const t = @import("terminal/calendar_types.zig");
const j = @import("terminal/json.zig");

test {
    std.testing.refAllDecls(native);
    std.testing.refAllDecls(native.Native);
}

test "calendar native: capability and exact returned scope are both required" {
    const scopes = &.{ permissions.calendar_list, permissions.events_write, permissions.free_busy };
    const shared = try native.grantsFor("self@example.test", &.{ "calendar-write-shared", "calendar-freebusy" }, scopes);
    try std.testing.expect(shared.write_shared and shared.free_busy and shared.calendar_list);
    try std.testing.expect(!shared.read_events and !shared.write_owned);
    const read = try native.grantsFor("self@example.test", &.{"calendar-read"}, scopes);
    try std.testing.expect(read.read_events and !read.write_shared and !read.free_busy);
    try std.testing.expectError(error.CalendarPermissionRequired, native.grantsFor("self@example.test", &.{"mail-read"}, scopes));
    try std.testing.expectError(error.CalendarPermissionRequired, native.grantsFor("self@example.test", &.{"calendar-write-shared"}, &.{ permissions.calendar_list, permissions.events_owned }));
    try std.testing.expectError(error.CalendarPermissionRequired, native.grantsFor("self@example.test", &.{"calendar-read"}, &.{permissions.events_read}));
    try std.testing.expectEqual(@as(usize, 1), (try native.capabilitiesForCommand("calendar.freebusy")).len);
    try std.testing.expectEqual(@as(usize, 2), (try native.capabilitiesForCommand("calendar.apply")).len);
    try std.testing.expectError(error.UnsupportedCalendarCommand, native.capabilitiesForCommand("mail.send"));
}

test "calendar native: absent Calendar grant fails before client token or profile access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config: @import("config.zig").Config = undefined;
    try config.defaults("/tmp");
    try config.client_file.set("/nonexistent/fictional-calendar-client.json");
    const request = try j.value(a, .{ .barGrantOnly = true, .grantFile = "/nonexistent/fictional-calendar-grants.json" });
    var session: native.Native = .{};
    try std.testing.expectError(error.CalendarPermissionRequired, session.init(std.testing.io, a, a, &config, "personal@example.com", "calendar.list", request));
    try std.testing.expect(!session.opened);
    session.close();
    try std.testing.expectError(error.UnknownAccount, session.init(std.testing.io, a, a, &config, "unknown@example.test", "calendar.list", request));
}

test "calendar native: authentication retry policy excludes every Calendar mutation" {
    const Session = @import("terminal/gmail.zig").NetworkSession;
    const import_url = provider.base_url ++ "/calendars/primary/events/import";
    const event_url = provider.base_url ++ "/calendars/primary/events/event";
    try std.testing.expect(Session.calendarReadRetryAllowed(.GET, event_url));
    try std.testing.expect(Session.calendarReadRetryAllowed(.POST, provider.base_url ++ "/freeBusy"));
    try std.testing.expect(!Session.calendarReadRetryAllowed(.POST, import_url));
    try std.testing.expect(!Session.calendarReadRetryAllowed(.PATCH, event_url));
    try std.testing.expect(!Session.calendarReadRetryAllowed(.DELETE, event_url));
    try std.testing.expect(!Session.calendarReadRetryAllowed(.POST, provider.base_url ++ "/freeBusy?unexpected=path"));
}

test "calendar native: method destination account and ETag cannot bypass the service operation kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "shared+team@example.test" };
    const grants = try native.grantsFor(target.account, &.{"calendar-write-shared"}, &.{ permissions.calendar_list, permissions.events_write });
    const request = try provider.lookup(a, target, "uid", "");
    try native.validateRequest(a, grants, request);
    var changed = request;
    changed.method = .DELETE;
    try std.testing.expectError(error.InvalidCalendarRequest, native.validateRequest(a, grants, changed));
    changed = request;
    changed.target.account = "other@example.test";
    try std.testing.expectError(error.CalendarAccountMismatch, native.validateRequest(a, grants, changed));
    changed = request;
    changed.target.calendar_id = "different-calendar";
    try std.testing.expectError(error.CalendarIdentityMismatch, native.validateRequest(a, grants, changed));
    changed = request;
    changed.kind = .update_event;
    changed.method = .PATCH;
    changed.body = "{}";
    try std.testing.expectError(error.InvalidCalendarRequest, native.validateRequest(a, grants, changed));
    changed = request;
    changed.url = "https://attacker.invalid/calendar/v3/calendars/shared/events?x=y";
    try std.testing.expectError(error.CalendarIdentityMismatch, native.validateRequest(a, grants, changed));
    const list = try provider.listCalendars(a, target.account, "");
    try native.validateRequest(a, grants, list);
    const read_grants = try native.grantsFor(target.account, &.{"calendar-read"}, &.{ permissions.calendar_list, permissions.events_read });
    const cancel: provider.Request = .{ .target = target, .kind = .cancel_event, .method = .DELETE, .url = (try provider.get(a, target, "event")).url, .if_match = "\"v4\"" };
    try std.testing.expectError(error.CalendarWritePermissionRequired, native.validateRequest(a, read_grants, cancel));
    try native.validateRequest(a, grants, cancel);
}
