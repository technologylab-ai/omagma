//! Calendar continuation of an already confirmed mail RSVP. This module never
//! sends mail and never authorizes a second write for an uncertain operation.
const std = @import("std");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const service = @import("calendar_service.zig");
const provider = @import("calendar_provider.zig");
const commands = @import("calendar_commands.zig");

pub const Result = struct {
    state: enum { applied, existing, skipped, unknown, rejected } = .skipped,
    calendarId: []const u8 = "",
    eventId: []const u8 = "",
    operationId: []const u8 = "",
    errorCode: []const u8 = "",
    canRetry: bool = false,
};

pub fn failed(err: anyerror) Result {
    return .{ .state = if (err == error.UnknownOutcome or err == error.CalendarOperationPending) .unknown else .skipped, .errorCode = @errorName(err), .canRetry = switch (err) {
        error.UnknownOutcome, error.CalendarOperationPending, error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable, error.TemporaryNameServerFailure, error.UnknownHostName, error.Timeout, error.DeadlineExceeded, error.CalendarUnavailable, error.CalendarRateLimited => true,
        else => false,
    } };
}

pub fn sync(instance: service.Service, request: j.Value, host: commands.HostInputs, response: provider.RsvpResponse) !Result {
    const listed = try instance.list();
    if (!listed.complete) return error.CalendarListIncomplete;
    const calendar = try selectCalendar(listed.calendars, instance.grants.account, j.text(request, "calendarId"));
    if (!calendar.writable()) return error.CalendarReadOnly;
    if (!instance.grants.canWrite(calendar)) return error.CalendarWritePermissionRequired;
    const digest_input = try std.fmt.allocPrint(instance.a, "{s}\x00{s}\x00{s}\x00{s}", .{ instance.grants.account, calendar.target.calendar_id, try j.required(request, "operationId"), @tagName(response) });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(digest_input, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const operation_id = try std.fmt.allocPrint(instance.a, "rsvp-{s}", .{hex});
    if (host.loadReceiptFn) |load_receipt| if (try load_receipt(host.context, instance.a, calendar.target, operation_id)) |receipt| {
        const operation = receipt.operation;
        if (receipt.ordinary or !operation.intent.identity.target.eql(calendar.target) or !std.mem.eql(u8, operation.intent.operation_id, operation_id) or (operation.intent.kind != .import_event and operation.intent.kind != .update_event)) return error.CalendarReviewMismatch;
        return .{ .state = switch (operation.state) {
            .applied => .applied,
            .rejected => .rejected,
            .unknown, .archived => return error.CalendarReviewMismatch,
        }, .calendarId = calendar.target.calendar_id, .eventId = operation.provider_id, .operationId = operation_id, .errorCode = operation.error_code };
    };
    const load = host.loadReviewFn orelse return error.CalendarPersistenceRequired;
    const saved: ?service.Review = load(host.context, instance.a, calendar.target, operation_id) catch |err| switch (err) {
        error.CalendarReviewNotFound => null,
        else => return err,
    };
    var review: service.Review = if (saved) |value| value else blk: {
        const planned = try commands.requestPlan(instance, request, host, calendar);
        if (planned.state.operation) |operation| if (operation.state == .unknown) return .{ .state = .unknown, .calendarId = calendar.target.calendar_id, .operationId = operation.intent.operation_id, .errorCode = "CalendarOperationPending", .canRetry = true };
        if (planned.source.isRecurring()) return .{ .calendarId = calendar.target.calendar_id, .errorCode = "UnsupportedCalendarRecurrence" };
        switch (planned.decision) {
            .import_missing, .existing, .review_update => {},
            else => return .{ .calendarId = calendar.target.calendar_id, .errorCode = if (planned.time_error.len != 0) planned.time_error else @tagName(std.meta.activeTag(planned.decision)) },
        }
        break :blk try instance.prepareRsvpReview(planned, operation_id, response);
    };
    if (review.rsvp_response != response) return error.OperationConflict;
    review.calendar = calendar;
    const applied = instance.apply(review, review.confirmation()) catch |err| {
        var result = failed(err);
        result.calendarId = calendar.target.calendar_id;
        result.operationId = operation_id;
        return result;
    };
    return .{ .state = switch (applied.operation.state) {
        .applied => .applied,
        .rejected => .rejected,
        .unknown => .unknown,
        .archived => return error.CalendarReviewMismatch,
    }, .calendarId = calendar.target.calendar_id, .eventId = applied.operation.provider_id, .operationId = operation_id, .errorCode = if (applied.failure) |failure| @errorName(service.failureError(failure)) else applied.operation.error_code, .canRetry = applied.operation.state == .unknown };
}

pub fn selectCalendar(calendars: []const t.Calendar, account: []const u8, explicit_id: []const u8) !t.Calendar {
    var selected: ?t.Calendar = null;
    for (calendars) |calendar| {
        if (!std.ascii.eqlIgnoreCase(calendar.target.account, account)) return error.CalendarAccountMismatch;
        if (if (explicit_id.len != 0) !std.mem.eql(u8, calendar.target.calendar_id, explicit_id) else !calendar.primary) continue;
        if (selected != null) return error.CalendarTargetAmbiguous;
        selected = calendar;
    }
    return selected orelse error.CalendarNotFound;
}
