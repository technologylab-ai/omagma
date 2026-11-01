//! Credential-free acceptance for the actual Calendar HTTP request path.
const std = @import("std");
const builtin = @import("builtin");
const http = @import("http_client.zig");
const service = @import("terminal/calendar_service.zig");
const provider = @import("terminal/calendar_provider.zig");
const ordinary = @import("terminal/calendar_event.zig");
const calendar_types = @import("terminal/calendar_types.zig");
const fixture_body = "{\"summary\":\"Fixture reviewed update\",\"sequence\":5,\"extendedProperties\":{\"private\":{\"omagmaOperation\":\"wire-fixture\"}}}";

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const url = args.next() orelse return error.UrlRequired;
    const mode = args.next() orelse return error.ModeRequired;
    const method: std.http.Method = if (std.mem.eql(u8, mode, "get")) .GET else if (std.mem.eql(u8, mode, "booking-import") or std.mem.eql(u8, mode, "import") or std.mem.eql(u8, mode, "freebusy") or std.mem.eql(u8, mode, "create-meet")) .POST else if (std.mem.eql(u8, mode, "delete")) .DELETE else if (std.mem.eql(u8, mode, "patch") or std.mem.eql(u8, mode, "bad-etag")) .PATCH else return error.InvalidProbeMode;
    const kind: provider.OperationKind = if (method == .GET) .event_get else if (method == .DELETE) .cancel_event else if (method == .PATCH) .update_event else if (std.mem.eql(u8, mode, "freebusy")) .free_busy else if (std.mem.eql(u8, mode, "create-meet")) .insert_event else .import_event;
    const creation = if (kind == .insert_event) try ordinary.prepare(init.gpa, .{ .target = .{ .account = "self@example.test", .calendar_id = "self@example.test" }, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true, .supports_meet = true }, .{ .draft = .{ .summary = "Planning", .start = "2026-10-22T10:00", .end = "2026-10-22T11:00", .timeZone = "UTC", .attendees = &.{"guest@example.test"}, .conference = .google_meet }, .span = .{ .start = .{ .kind = .instant, .value = try calendar_types.time.rfc3339("2026-10-22T10:00:00Z"), .zone = "UTC" }, .end = .{ .kind = .instant, .value = try calendar_types.time.rfc3339("2026-10-22T11:00:00Z"), .zone = "UTC" } }, .send_updates = .all }, .{ .operation_id = "wire-event-create", .identity = .{ .target = .{ .account = "self@example.test", .calendar_id = "self@example.test" }, .uid = "event:omagma012345" }, .version = .{ .sequence = 0, .dtstamp_ms = 0 }, .kind = .insert_event, .source_hash = @splat(0), .payload_hash = @splat(0), .event_id = "omagma012345" }, null) else null;
    const booking: ?provider.Request = if (std.mem.eql(u8, mode, "booking-import")) blk: {
        const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, "tests/fixtures/terminal/calendar/booking-no-attendees.ics", init.gpa, .limited(calendar_types.Limits.source_bytes));
        const parsed = try @import("terminal/calendar_invitation.zig").parseForCalendar(init.gpa, raw, "self@example.test", &.{});
        const zone = try @import("terminal/timezone.zig").Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
        const first = try calendar_types.time.rfc3339("2026-11-10T09:15:00Z");
        const last = try calendar_types.time.rfc3339("2026-11-10T10:05:00Z");
        if (!@import("terminal/calendar_embedded.zig").matches(parsed.unfolded, "Europe/Vienna", &zone, first, last)) return error.EmbeddedTimezoneMismatch;
        const binding: calendar_types.time.Binding = .{ .id = "Europe/Vienna", .zone = &zone, .embedded_rules_verified = true };
        const span = try @import("terminal/calendar_invitation.zig").resolveSpan(parsed, binding, binding);
        break :blk try provider.prepareResolvedImport(init.gpa, parsed, .{ .operation_id = "wire-booking", .identity = .{ .target = .{ .account = "self@example.test", .calendar_id = "opaque-booking-calendar" }, .uid = parsed.uid }, .version = parsed.version, .kind = .import_event, .source_hash = parsed.source_hash, .payload_hash = @splat(0) }, span);
    } else null;
    const body: ?[]const u8 = if (booking) |request| request.body else if (creation) |request| request.body else if (method == .POST or method == .PATCH) fixture_body else null;
    const destination = if (booking) |request| blk: {
        const path_start = std.mem.indexOfScalarPos(u8, url, "http://".len, '/') orelse url.len;
        break :blk try std.fmt.allocPrint(init.gpa, "{s}{s}", .{ url[0..path_start], request.url["https://www.googleapis.com".len..] });
    } else if (creation) |request| try std.fmt.allocPrint(init.gpa, "{s}{s}", .{ url, request.url[std.mem.indexOfScalar(u8, request.url, '?').?..] }) else url;
    const etag: ?[]const u8 = if (method == .PATCH or method == .DELETE) (if (std.mem.eql(u8, mode, "bad-etag")) "\"bad\r\nInjected: true\"" else "\"wire-etag-4\"") else null;
    var client = try http.Client.init(init.io);
    defer client.deinit();
    var output: [4096]u8 = undefined;
    var failure: []const u8 = "";
    const response: ?http.Response = client.requestLoopbackCalendarProbe(destination, if (booking) |request| request.method else method, body, if (booking) |request| request.if_match else etag, &output) catch |err| blk: {
        failure = @errorName(err);
        break :blk null;
    };
    if (response) |value| if (value.status < 200 or value.status >= 300) {
        failure = @errorName(service.failureError(provider.classifyFailure(kind, value.status, "")));
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const detail: ?provider.ErrorDetail = if (response) |value| if (value.status >= 300) try provider.errorDetail(init.gpa, value.status, value.body) else null else null;
    try std.json.Stringify.value(.{ .status = if (response) |value| value.status else @as(u16, 0), .bodyBytes = if (response) |value| value.body.len else @as(usize, 0), .errorCode = failure, .providerError = detail, .zigVersion = builtin.zig_version_string, .optimizeMode = @tagName(builtin.mode) }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
