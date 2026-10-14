//! Actual native Calendar transport over the existing verified terminal session.
//! Keep Native in stable storage from init through close; its HTTP allocator and
//! transport callbacks borrow it. Core remains responsible for command routing.
const std = @import("std");
const Config = @import("../config.zig").Config;
const gmail = @import("gmail.zig");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const p = @import("calendar_provider.zig");
const permissions = @import("calendar_permissions.zig");
const service = @import("calendar_service.zig");

pub const Native = struct {
    session: gmail.NetworkSession = undefined,
    grants: service.Grants = undefined,
    opened: bool = false,

    pub fn init(self: *Native, io: std.Io, a: std.mem.Allocator, buffer_allocator: std.mem.Allocator, config: *const Config, account: []const u8, command: []const u8, request: j.Value) !void {
        if (self.opened) return error.CalendarSessionAlreadyOpen;
        const required = try capabilitiesForCommand(command);
        // The shared initializer checks these capabilities in the validated
        // registry before opening credentials, refreshing or reading a profile.
        self.session.initRequiringAnyCapabilityWithAllocator(io, a, buffer_allocator, config, account, "mail.list", request, required) catch |err| return if (err == error.PermissionDenied) error.CalendarPermissionRequired else err;
        errdefer self.session.close();
        self.grants = try grantsFor(self.session.verified_account, self.session.capabilities, self.session.scopes);
        self.opened = true;
    }

    pub fn close(self: *Native) void {
        if (!self.opened) return;
        self.session.close();
        self.opened = false;
    }

    pub fn transport(self: *Native) service.Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, a: std.mem.Allocator, request: p.Request) anyerror!service.Response {
        const self: *Native = @ptrCast(@alignCast(context));
        if (!self.opened) return error.CalendarSessionClosed;
        try validateRequest(a, self.grants, request);
        // Writes receive no automatic retry, including after a definitive 401.
        // The service records their result and requires a fresh reviewed action.
        const response = try self.session.requestCalendarRaw(request.target.account, request.url, request.method, request.body, request.if_match, !request.kind.mutating());
        if (response.body.len > t.Limits.response_bytes) return error.CalendarResponseTooLarge;
        return .{ .account = self.session.verified_account, .status = response.status, .body = try a.dupe(u8, response.body) };
    }
};

pub fn capabilitiesForCommand(command: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, command, "calendar.list")) return &.{ "calendar-read", "calendar-write-owned", "calendar-write-shared", "calendar-freebusy" };
    if (std.mem.eql(u8, command, "calendar.freebusy")) return &.{"calendar-freebusy"};
    for ([_][]const u8{ "calendar.agenda", "calendar.event", "calendar.invitation-plan", "calendar.reconcile" }) |name| if (std.mem.eql(u8, command, name)) return &.{ "calendar-read", "calendar-write-owned", "calendar-write-shared" };
    for ([_][]const u8{ "calendar.review", "calendar.apply", "calendar.import", "calendar.update", "calendar.cancel" }) |name| if (std.mem.eql(u8, command, name)) return &.{ "calendar-write-owned", "calendar-write-shared" };
    return error.UnsupportedCalendarCommand;
}

/// A capability and its exact validated scope must both be present. These inputs
/// come from NetworkSession's registry validation, never request JSON.
pub fn grantsFor(account: []const u8, capabilities: []const []const u8, scopes: []const []const u8) !service.Grants {
    try @import("../bounded.zig").address(account);
    const result: service.Grants = .{
        .account = account,
        .calendar_list = contains(scopes, permissions.calendar_list),
        .read_events = contains(capabilities, "calendar-read") and (contains(scopes, permissions.events_read) or contains(scopes, permissions.events_write)),
        .write_owned = contains(capabilities, "calendar-write-owned") and (contains(scopes, permissions.events_owned) or contains(scopes, permissions.events_write)),
        .write_shared = contains(capabilities, "calendar-write-shared") and contains(scopes, permissions.events_write),
        .free_busy = contains(capabilities, "calendar-freebusy") and contains(scopes, permissions.free_busy),
    };
    if (!result.calendar_list or (!result.read_events and !result.write_owned and !result.write_shared and !result.free_busy)) return error.CalendarPermissionRequired;
    return result;
}

pub fn validateRequest(a: std.mem.Allocator, grants: service.Grants, request: p.Request) !void {
    try request.target.validate();
    if (!std.ascii.eqlIgnoreCase(grants.account, request.target.account)) return error.CalendarAccountMismatch;
    const expected_method: std.http.Method = switch (request.kind) {
        .calendar_list, .event_lookup, .agenda, .event_get => .GET,
        .free_busy, .import_event => .POST,
        .update_event => .PATCH,
        .cancel_event => .DELETE,
    };
    if (request.method != expected_method) return error.InvalidCalendarRequest;
    const has_body = request.kind == .free_busy or request.kind == .import_event or request.kind == .update_event;
    const conditional = request.kind == .update_event or request.kind == .cancel_event;
    if (has_body != (request.body != null) or conditional != (request.if_match != null)) return error.InvalidCalendarRequest;
    if (request.body) |body| if (body.len > t.Limits.source_bytes * 2) return error.CalendarTooLarge;
    switch (request.kind) {
        .calendar_list => {
            if (!grants.calendar_list) return error.CalendarPermissionRequired;
            if (!std.mem.startsWith(u8, request.url, p.base_url ++ "/users/me/calendarList?")) return error.InvalidCalendarPath;
        },
        .free_busy => {
            if (!grants.free_busy) return error.CalendarFreeBusyPermissionRequired;
            if (!std.mem.eql(u8, request.url, p.base_url ++ "/freeBusy")) return error.InvalidCalendarPath;
        },
        else => {
            if (request.kind.mutating()) {
                if (!grants.write_owned and !grants.write_shared) return error.CalendarWritePermissionRequired;
            } else if (!grants.read_events and !grants.write_owned and !grants.write_shared) return error.CalendarReadPermissionRequired;
            const marker = "calendar-native-path-binding";
            const bound = try p.get(a, request.target, marker);
            const prefix = bound.url[0 .. bound.url.len - marker.len];
            if (request.kind == .agenda or request.kind == .event_lookup) {
                const collection = try std.fmt.allocPrint(a, "{s}?", .{prefix[0 .. prefix.len - 1]});
                if (!std.mem.startsWith(u8, request.url, collection)) return error.CalendarIdentityMismatch;
            } else {
                if (!std.mem.startsWith(u8, request.url, prefix)) return error.CalendarIdentityMismatch;
                const tail = request.url[prefix.len..];
                const id = tail[0 .. std.mem.indexOfScalar(u8, tail, '?') orelse tail.len];
                if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.InvalidCalendarPath;
                if (request.kind == .import_event and !std.mem.eql(u8, tail, "import")) return error.InvalidCalendarPath;
            }
        },
    }
}

fn contains(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}
