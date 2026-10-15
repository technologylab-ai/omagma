//! Shared JSON command boundary for the native Calendar CLI and TUI.
//! Credentials stay in Native; hosts supply account-bound source and saved
//! review callbacks. Caller JSON never supplies an executable provider request.
const std = @import("std");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const svc = @import("calendar_service.zig");
const invitation = @import("calendar_invitation.zig");
const timezone = @import("timezone.zig");
const ordinary = @import("calendar_event.zig");
const embedded_zone = @import("calendar_embedded.zig");

pub const InvitationInput = struct {
    source: []const u8,
    /// Resolved from the selected account's verified identities by the host.
    verified_aliases: []const []const u8 = &.{},
};
pub const HostInputs = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,
    context: *anyopaque,
    /// The host resolves messageId/attachmentId within this exact account.
    loadInvitationFn: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, j.Value) anyerror!InvitationInput = null,
    /// Return owned strings from a saved review, never decode request JSON as
    /// Review. Bind account/calendar/operation ID before returning anything.
    loadReviewFn: ?*const fn (*anyopaque, std.mem.Allocator, t.Target, []const u8) anyerror!svc.Review = null,
    loadReceiptFn: ?*const fn (*anyopaque, std.mem.Allocator, t.Target, []const u8) anyerror!?svc.Receipt = null,
    loadPendingFn: ?*const fn (*anyopaque, std.mem.Allocator, t.Target, []const u8) anyerror!?svc.Pending = null,
};

pub fn dispatch(instance: svc.Service, request: j.Value, host: HostInputs) !j.Value {
    try preflight(request);
    var service = instance;
    service.persist_cache = instance.persist_cache and try j.boolean(request, "persistCache", true);
    const command = try j.required(request, "cmd");
    const account = try j.required(request, "account");
    if (!std.ascii.eqlIgnoreCase(account, service.grants.account)) return error.CalendarAccountMismatch;
    if (std.mem.eql(u8, command, "calendar.list")) {
        const result = try service.list();
        const View = struct { calendar: t.Calendar, canRead: bool, canWrite: bool, canFreeBusy: bool };
        const values = try service.a.alloc(View, result.calendars.len);
        for (result.calendars, values) |calendar, *view| view.* = .{ .calendar = calendar, .canRead = service.grants.canRead(calendar), .canWrite = service.grants.canWrite(calendar), .canFreeBusy = service.grants.free_busy and calendar.access != .none };
        return j.value(service.a, .{ .account = account, .calendars = values, .complete = result.complete, .cacheError = result.cache_error });
    }
    const target: t.Target = .{ .account = account, .calendar_id = try j.required(request, "calendarId") };
    try target.validate();

    if (std.mem.eql(u8, command, "calendar.event-pending")) {
        const load = host.loadPendingFn orelse return error.CalendarPersistenceRequired;
        const pending = try load(host.context, service.a, target, j.text(request, "eventId"));
        if (pending) |value| {
            if (value.review.ordinary_event == null or value.operation.state != .unknown or !value.operation.intent.eql(value.review.intent) or !value.review.intent.identity.target.eql(target) or (j.text(request, "eventId").len != 0 and !std.mem.eql(u8, j.text(request, "eventId"), value.review.intent.event_id))) return error.CalendarReviewMismatch;
            return j.value(service.a, .{ .pending = .{ .review = try eventReviewValue(service.a, value.review), .state = "unknown", .attempt = value.operation.attempt, .nextAttempt = value.operation.attempt +| 1, .retryPossible = false, .recoveryReason = "Check Calendar before retrying" } });
        }
        var empty = j.object(service.a);
        try empty.object.put(service.a, "pending", .null);
        return empty;
    }
    if (executionCommand(command)) return executeReview(service, request, host, target, command);
    const calendar = try selectedCalendar(service, target);
    if (std.mem.eql(u8, command, "calendar.event")) {
        const document = try service.document(calendar, try j.required(request, "eventId"));
        const zone_name = if (document.event.start) |point| if (point.zone.len > 0) point.zone else calendar.time_zone else calendar.time_zone;
        var draft: ?ordinary.Draft = null;
        var draft_error: []const u8 = "";
        if (!document.event.cancelled) {
            var zone_value: ?timezone.Zone = loadZone(service.a, host, zone_name) catch |err| blk: {
                draft_error = @errorName(err);
                break :blk null;
            };
            defer if (zone_value) |*zone| zone.deinit(service.a);
            if (zone_value) |*zone| draft = ordinary.prefill(service.a, document.event, zone_name, zone) catch |err| blk: {
                draft_error = @errorName(err);
                break :blk null;
            };
        }
        const reason = if (ordinary.editReason(calendar, document).len != 0) ordinary.editReason(calendar, document) else if (!service.grants.canWrite(calendar)) @as([]const u8, "calendar_write_permission") else if (draft_error.len != 0) "event_time_not_editable" else "";
        return j.value(service.a, .{ .calendar = calendar, .event = document.event, .canEdit = reason.len == 0 and draft != null, .canEditReason = reason, .draftError = draft_error, .htmlNotesReadOnly = ordinary.htmlDescription(document.event.description), .eventDraft = draft });
    }
    if (std.mem.eql(u8, command, "calendar.event-review")) {
        const event = j.get(request, "event") orelse return error.InvalidCalendarEvent;
        const zone_name = try j.required(event, "timeZone");
        var zone = try loadZone(service.a, host, zone_name);
        defer zone.deinit(service.a);
        const prepared = try ordinary.parse(service.a, request, &zone);
        const review = try service.prepareEventReviewFields(calendar, prepared, try j.required(request, "operationId"), j.text(request, "eventId"), j.text(request, "expectedEtag"), .{ .description_present = present(event, "description"), .location_present = present(event, "location") });
        const store = service.persistence orelse return error.CalendarPersistenceRequired;
        try store.preserveFn(store.context, review);
        return eventReviewValue(service.a, review);
    }
    if (std.mem.eql(u8, command, "calendar.agenda") or std.mem.eql(u8, command, "calendar.freebusy")) {
        const window = try requestWindow(service.a, request, host, calendar);
        if (std.mem.eql(u8, command, "calendar.freebusy")) return j.value(service.a, try service.freeBusy(calendar, window));
        const result = try service.agenda(calendar, window);
        return j.value(service.a, .{ .calendar = calendar, .snapshot = result.snapshot, .refreshError = result.refresh_error, .cacheError = result.cache_error });
    }

    const planned = try requestPlan(service, request, host, calendar);
    if (std.mem.eql(u8, command, "calendar.invitation-plan")) return planValue(service.a, planned, try recovery(service.a, planned, host));
    const review = try service.prepareReview(planned, try j.required(request, "operationId"));
    // A separate CLI invocation can now load this same review. Saving it does
    // not claim a mutation; apply must still durably claim unknown afterwards.
    const store = service.persistence orelse return error.CalendarPersistenceRequired;
    try store.preserveFn(store.context, review);
    return reviewValue(service.a, review);
}

/// Core can run this without a session, allocator, credentials, files or
/// network. Check the recorded local Calendar capability next, then fetch the
/// account's source mail, then open Native; HTTP clients must not overlap.
pub fn preflight(request: j.Value) !void {
    const command = try j.required(request, "cmd");
    if (!supported(command)) return error.UnsupportedCalendarCommand;
    try @import("../bounded.zig").address(try j.required(request, "account"));
    try validateFields(request, command);
    if (!std.mem.eql(u8, command, "calendar.list")) {
        const target: t.Target = .{ .account = try j.required(request, "account"), .calendar_id = try j.required(request, "calendarId") };
        try target.validate();
    }
    if (executionCommand(command)) {
        for ([_][]const u8{ "review", "source", "body", "request", "expectedEtag", "etag", "verifiedAliases", "event", "eventId", "sendUpdates" }) |field| if (j.get(request, field) != null) return error.InvalidCalendarConfirmation;
        _ = try parseReviewHash(try j.required(request, "reviewHash"));
    }
}

pub fn supported(command: []const u8) bool {
    for ([_][]const u8{ "calendar.list", "calendar.agenda", "calendar.event", "calendar.freebusy", "calendar.invitation-plan", "calendar.review", "calendar.apply", "calendar.import", "calendar.update", "calendar.cancel", "calendar.reconcile", "calendar.event-review", "calendar.event-apply", "calendar.event-reconcile", "calendar.event-retry", "calendar.event-abandon", "calendar.event-pending" }) |value| if (std.mem.eql(u8, command, value)) return true;
    return false;
}
pub fn localCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "calendar.event-pending") or std.mem.eql(u8, command, "calendar.event-abandon");
}

fn executionCommand(command: []const u8) bool {
    for ([_][]const u8{ "calendar.apply", "calendar.import", "calendar.update", "calendar.cancel", "calendar.reconcile", "calendar.event-apply", "calendar.event-reconcile", "calendar.event-retry", "calendar.event-abandon" }) |value| if (std.mem.eql(u8, command, value)) return true;
    return false;
}
fn validateFields(request: j.Value, command: []const u8) !void {
    if (j.get(request, "persistCache") != null) {
        if (!std.mem.eql(u8, command, "calendar.list") and !std.mem.eql(u8, command, "calendar.agenda")) return error.InvalidCalendarRequest;
        _ = try j.boolean(request, "persistCache", true);
    }
    if (std.mem.eql(u8, command, "calendar.event")) try t.text(try j.required(request, "eventId"), 1024, false);
    if (std.mem.eql(u8, command, "calendar.event-pending")) if (j.get(request, "eventId")) |value| if (value != .null) {
        try t.text(try j.string(value), 1024, false);
    };
    if (std.mem.eql(u8, command, "calendar.event-retry")) {
        const attempt = try j.integer(request, "nextAttempt", 0);
        if (attempt <= 0 or attempt > 1000000) return error.InvalidCalendarRetry;
    } else if (j.get(request, "nextAttempt") != null) return error.InvalidCalendarConfirmation;
    if (std.mem.eql(u8, command, "calendar.agenda") or std.mem.eql(u8, command, "calendar.freebusy")) {
        _ = try timezone.parseDate(try j.required(request, "date"));
        if (j.get(request, "view")) |value| {
            const view = try j.string(value);
            if (!std.mem.eql(u8, view, "day") and !std.mem.eql(u8, view, "week")) return error.InvalidCalendarView;
        }
        if (j.get(request, "timeZone")) |value| try t.time.validateZoneName(try j.string(value));
    }
    if (std.mem.eql(u8, command, "calendar.invitation-plan") or std.mem.eql(u8, command, "calendar.review")) {
        try t.text(try j.required(request, "messageId"), 1024, false);
        if (j.get(request, "verifiedAliases") != null) return error.InvalidCalendarRequest;
        for ([_][]const u8{ "startTimeZone", "endTimeZone" }) |field| if (j.get(request, field)) |value| try t.time.validateZoneName(try j.string(value));
        _ = try j.boolean(request, "acceptFloatingTime", false);
        _ = try j.boolean(request, "reinterpretEmbeddedTimezones", false);
    }
    if (std.mem.eql(u8, command, "calendar.event-review")) {
        if (j.get(request, "messageId") != null or j.get(request, "review") != null or j.get(request, "request") != null) return error.InvalidCalendarRequest;
        const event = j.get(request, "event") orelse return error.InvalidCalendarEvent;
        if (event != .object) return error.InvalidCalendarEvent;
        try t.time.validateZoneName(try j.required(event, "timeZone"));
        try t.text(try j.required(event, "summary"), 4096, false);
        try t.text(try j.required(event, "start"), 40, false);
        try t.text(try j.required(event, "end"), 40, false);
        _ = try j.boolean(event, "allDay", false);
        const updates = try j.required(request, "sendUpdates");
        if (!std.mem.eql(u8, updates, "none") and !std.mem.eql(u8, updates, "all")) return error.InvalidCalendarNotificationPolicy;
        const event_id = j.text(request, "eventId");
        if (event_id.len != 0) {
            try t.text(event_id, 1024, false);
            try t.text(try j.required(request, "expectedEtag"), 1024, false);
        } else if (j.get(request, "expectedEtag")) |value| if (value != .null) return error.InvalidCalendarConfirmation;
    }
    if (std.mem.eql(u8, command, "calendar.review") or std.mem.eql(u8, command, "calendar.event-review") or executionCommand(command)) {
        const id = try j.required(request, "operationId");
        try t.text(id, 128, false);
        for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidOperationId;
    }
}

fn selectedCalendar(service: svc.Service, target: t.Target) !t.Calendar {
    const result = try service.list();
    for (result.calendars) |calendar| if (calendar.target.eql(target)) return calendar;
    return if (result.complete) error.CalendarNotFound else error.CalendarListIncomplete;
}

fn executeReview(service: svc.Service, request: j.Value, host: HostInputs, target: t.Target, command: []const u8) !j.Value {
    for ([_][]const u8{ "review", "source", "body", "request", "expectedEtag", "etag", "verifiedAliases", "event", "eventId", "sendUpdates" }) |field| if (j.get(request, field) != null) return error.InvalidCalendarConfirmation;
    const operation_id = try j.required(request, "operationId");
    const hash = try parseReviewHash(try j.required(request, "reviewHash"));
    if (host.loadReceiptFn) |load_receipt| if (try load_receipt(host.context, service.a, target, operation_id)) |receipt| {
        if (!receipt.operation.intent.identity.target.eql(target) or !std.mem.eql(u8, receipt.operation.intent.operation_id, operation_id) or !std.mem.eql(u8, &receipt.review_hash, &hash) or receipt.operation.state == .unknown) return error.CalendarReviewMismatch;
        const ordinary_command = std.mem.eql(u8, command, "calendar.event-apply") or std.mem.eql(u8, command, "calendar.event-reconcile") or std.mem.eql(u8, command, "calendar.event-retry") or std.mem.eql(u8, command, "calendar.event-abandon");
        if (ordinary_command != receipt.ordinary) return error.CalendarReviewMismatch;
        const required_kind: ?@TypeOf(receipt.operation.intent.kind) = if (std.mem.eql(u8, command, "calendar.import")) .import_event else if (std.mem.eql(u8, command, "calendar.update")) .update_event else if (std.mem.eql(u8, command, "calendar.cancel")) .cancel_event else null;
        if (required_kind) |kind| if (receipt.operation.intent.kind != kind) return error.CalendarReviewMismatch;
        return appliedValue(service.a, target, .{ .operation = receipt.operation });
    };
    const load = host.loadReviewFn orelse return error.CalendarPersistenceRequired;
    var review = try load(host.context, service.a, target, operation_id);
    if (!review.intent.identity.target.eql(target) or !std.mem.eql(u8, review.intent.operation_id, operation_id) or !std.mem.eql(u8, &hash, &review.review_hash)) return error.CalendarReviewMismatch;
    const expected_kind: ?@TypeOf(review.intent.kind) = if (std.mem.eql(u8, command, "calendar.import")) .import_event else if (std.mem.eql(u8, command, "calendar.update")) .update_event else if (std.mem.eql(u8, command, "calendar.cancel")) .cancel_event else null;
    if (expected_kind) |kind| if (review.intent.kind != kind) return error.CalendarReviewMismatch;
    const ordinary_command = std.mem.eql(u8, command, "calendar.event-apply") or std.mem.eql(u8, command, "calendar.event-reconcile") or std.mem.eql(u8, command, "calendar.event-retry") or std.mem.eql(u8, command, "calendar.event-abandon");
    if (ordinary_command != (review.ordinary_event != null)) return error.CalendarReviewMismatch;
    const confirmation: svc.Confirmation = .{ .target = target, .operation_id = operation_id, .review_hash = hash };
    if (std.mem.eql(u8, command, "calendar.event-abandon")) return appliedValue(service.a, target, try service.archive(review, confirmation));
    review.calendar = try selectedCalendar(service, target);
    const result = if (std.mem.eql(u8, command, "calendar.reconcile") or std.mem.eql(u8, command, "calendar.event-reconcile")) try service.reconcile(review) else if (std.mem.eql(u8, command, "calendar.event-retry")) try service.retry(review, confirmation, @intCast(try j.integer(request, "nextAttempt", 0))) else try service.apply(review, confirmation);
    return appliedValue(service.a, target, result);
}

pub fn parseReviewHash(raw: []const u8) ![32]u8 {
    if (raw.len != 64) return error.InvalidCalendarConfirmation;
    for (raw) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidCalendarConfirmation;
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, raw) catch return error.InvalidCalendarConfirmation;
    return hash;
}

pub fn requestWindow(a: std.mem.Allocator, request: j.Value, host: HostInputs, calendar: t.Calendar) !t.Window {
    const zone_name = if (j.get(request, "timeZone")) |value| try j.string(value) else calendar.time_zone;
    var zone = try loadZone(a, host, zone_name);
    defer zone.deinit(a);
    const view = if (j.get(request, "view")) |value| try j.string(value) else "day";
    if (!std.mem.eql(u8, view, "day") and !std.mem.eql(u8, view, "week")) return error.InvalidCalendarView;
    return svc.windowForDays(a, try j.required(request, "date"), if (std.mem.eql(u8, view, "day")) .day else .week, .{ .id = zone_name, .zone = &zone });
}

pub fn requestPlan(service: svc.Service, request: j.Value, host: HostInputs, calendar: t.Calendar) !svc.InvitationPlan {
    if (!service.grants.canRead(calendar)) return error.CalendarReadPermissionRequired;
    const load = host.loadInvitationFn orelse return error.CalendarInvitationSourceRequired;
    const input = try load(host.context, service.a, service.grants.account, request);
    const source = try invitation.parse(service.a, input.source, service.grants.account, input.verified_aliases);
    var start_name = try sourceZone(request, "startTimeZone", source.start);
    var end_name = try sourceZone(request, "endTimeZone", source.end);
    var time_error: []const u8 = "";
    var start_zone: ?timezone.Zone = if (start_name) |name| loadZone(service.a, host, name) catch |err| blk: {
        time_error = @errorName(err);
        // Outlook can name a Windows timezone. The calendar zone is only a
        // candidate here; it becomes usable after embedded-rule equivalence
        // is proved over the whole event. No name-only fallback is accepted.
        if (source.has_timezones and j.get(request, "startTimeZone") == null) {
            start_name = calendar.time_zone;
            break :blk loadZone(service.a, host, calendar.time_zone) catch null;
        }
        break :blk null;
    } else null;
    defer if (start_zone) |*zone| zone.deinit(service.a);
    var end_zone: ?timezone.Zone = if (end_name) |name| loadZone(service.a, host, name) catch |err| blk: {
        time_error = @errorName(err);
        if (source.has_timezones and j.get(request, "endTimeZone") == null) {
            end_name = calendar.time_zone;
            break :blk loadZone(service.a, host, calendar.time_zone) catch null;
        }
        break :blk null;
    } else null;
    defer if (end_zone) |*zone| zone.deinit(service.a);
    const floating = try j.boolean(request, "acceptFloatingTime", false);
    const embedded = try j.boolean(request, "reinterpretEmbeddedTimezones", false);
    // Reinterpreting embedded rules requires both explicit consent and an
    // explicit target zone. Merely recognizing an IANA-looking TZID is not
    // evidence that its embedded rules match the machine's timezone database.
    var start: ?t.time.Binding = if (start_zone) |*zone| .{ .id = start_name.?, .zone = zone, .accept_floating = floating, .embedded_rules_verified = embedded and j.get(request, "startTimeZone") != null } else null;
    var end: ?t.time.Binding = if (end_zone) |*zone| .{ .id = end_name.?, .zone = zone, .accept_floating = floating, .embedded_rules_verified = embedded and j.get(request, "endTimeZone") != null } else null;
    verifyEmbedded(source, &start, &end);
    var planned = try service.invitationPlan(calendar, input.source, input.verified_aliases, .{ .start = start, .end = end });
    if (planned.span == null and time_error.len != 0) planned.time_error = time_error;
    return planned;
}

fn verifyEmbedded(source: t.Invitation, start: *?t.time.Binding, end: *?t.time.Binding) void {
    if (!source.has_timezones) return;
    var candidate_start = start.*;
    var candidate_end = end.*;
    // Temporary candidates only determine the interval to prove. They never
    // leave this function and never authorize a plan or prepared mutation.
    if (candidate_start) |*binding| binding.embedded_rules_verified = true;
    if (candidate_end) |*binding| binding.embedded_rules_verified = true;
    const span = invitation.resolveSpan(source, candidate_start, candidate_end) catch return;
    if (span.start.kind != .instant) return; // DATE remains a civil day.
    if (source.start) |stamp| if (stamp.kind == .zoned) if (start.*) |*binding| {
        if (!binding.embedded_rules_verified) binding.embedded_rules_verified = embedded_zone.matches(source.unfolded, stamp.zone, binding.zone, span.start.value, span.end.value);
    };
    if (source.end) |stamp| if (stamp.kind == .zoned) {
        if (end.*) |*binding| {
            if (!binding.embedded_rules_verified) binding.embedded_rules_verified = embedded_zone.matches(source.unfolded, stamp.zone, binding.zone, span.start.value, span.end.value);
        } else if (start.*) |*binding| {
            // A borrowed start binding must prove the end's actual TZID too.
            binding.embedded_rules_verified = binding.embedded_rules_verified and embedded_zone.matches(source.unfolded, stamp.zone, binding.zone, span.start.value, span.end.value);
        }
    };
}

fn sourceZone(request: j.Value, field: []const u8, stamp: ?t.time.Stamp) !?[]const u8 {
    if (j.get(request, field)) |value| {
        const name = try j.string(value);
        try t.time.validateZoneName(name);
        return name;
    }
    if (stamp) |value| if (value.kind == .zoned) return value.zone;
    return null;
}
fn loadZone(a: std.mem.Allocator, host: HostInputs, name: []const u8) !timezone.Zone {
    try t.time.validateZoneName(name);
    if (std.mem.eql(u8, name, "UTC")) return .{};
    return timezone.loadNamed(host.io, a, host.env, name);
}

const Recovery = struct { account: []const u8, calendarId: []const u8, operationId: []const u8, reviewHash: []const u8, action: []const u8 };
fn recovery(a: std.mem.Allocator, planned: svc.InvitationPlan, host: HostInputs) !?Recovery {
    const operation = planned.state.operation orelse return null;
    if (operation.state != .unknown) return null;
    const load = host.loadReviewFn orelse return error.CalendarPersistenceRequired;
    const review = try load(host.context, a, planned.calendar.target, operation.intent.operation_id);
    if (!review.intent.eql(operation.intent) or !review.calendar.target.eql(planned.calendar.target)) return error.CalendarReviewMismatch;
    const hash = std.fmt.bytesToHex(review.review_hash, .lower);
    return .{ .account = planned.calendar.target.account, .calendarId = planned.calendar.target.calendar_id, .operationId = operation.intent.operation_id, .reviewHash = try a.dupe(u8, &hash), .action = @tagName(review.intent.kind) };
}
fn planValue(a: std.mem.Allocator, planned: svc.InvitationPlan, pending: ?Recovery) !j.Value {
    const existing: ?t.Event = switch (planned.decision) {
        .existing, .review_update, .review_cancel, .previously_cancelled, .reconciled => |event| event,
        else => null,
    };
    return j.value(a, .{ .calendar = planned.calendar, .invitation = planned.source, .resolved = planned.span, .decision = @tagName(std.meta.activeTag(planned.decision)), .writable = planned.writable, .lookupComplete = planned.lookup.complete, .timeError = planned.time_error, .event = existing, .operation = planned.state.operation, .recovery = pending });
}
fn reviewValue(a: std.mem.Allocator, review: svc.Review) !j.Value {
    const hash = std.fmt.bytesToHex(review.review_hash, .lower);
    return j.value(a, .{ .account = review.intent.identity.target.account, .calendarId = review.intent.identity.target.calendar_id, .calendarName = review.calendar.summary, .operationId = review.intent.operation_id, .reviewHash = hash[0..], .action = @tagName(review.intent.kind), .uid = review.intent.identity.uid, .version = review.intent.version, .eventId = review.intent.event_id, .expectedEtag = review.intent.expected_etag, .invitation = review.source, .resolved = review.span, .previous = review.previous });
}

fn eventReviewValue(a: std.mem.Allocator, review: svc.Review) !j.Value {
    const hash = std.fmt.bytesToHex(review.review_hash, .lower);
    const prepared = review.ordinary_event orelse return error.CalendarReviewMismatch;
    return j.value(a, .{ .account = review.intent.identity.target.account, .calendarId = review.intent.identity.target.calendar_id, .calendarName = review.calendar.summary, .operationId = review.intent.operation_id, .reviewHash = hash[0..], .action = if (review.intent.kind == .insert_event) @as([]const u8, "create_event") else "update_event", .eventId = review.intent.event_id, .expectedEtag = review.intent.expected_etag, .event = prepared.draft, .resolved = prepared.span, .sendUpdates = @tagName(prepared.send_updates), .previous = review.previous, .conference = @tagName(prepared.draft.conference) });
}

fn appliedValue(a: std.mem.Allocator, target: t.Target, result: svc.Applied) !j.Value {
    return j.value(a, .{ .account = target.account, .calendarId = target.calendar_id, .operationId = result.operation.intent.operation_id, .uid = result.operation.intent.identity.uid, .state = @tagName(result.operation.state), .providerId = result.operation.provider_id, .reconciled = result.reconciled, .errorCode = if (result.failure) |failure| @errorName(svc.failureError(failure)) else result.operation.error_code, .event = result.event, .attempt = result.operation.attempt, .nextAttempt = result.operation.attempt +| 1, .retryPossible = result.retry_possible, .recoveryReason = result.recovery_reason });
}

fn present(value: j.Value, field: []const u8) bool {
    return if (j.get(value, field)) |raw| raw != .null else false;
}
