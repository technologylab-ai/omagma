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
const action = @import("calendar_event_action.zig");
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

    if (std.mem.eql(u8, command, "calendar.event-pending")) return pendingValue(service, request, host, target);
    if (executionCommand(command)) return executeReview(service, request, host, target, command);
    const calendar = try selectedCalendar(service, target);
    if (std.mem.eql(u8, command, "calendar.event")) {
        // A view, never a write target: calendar.event-review re-reads the
        // event strictly, and a repaired event arrives here locked.
        const document = try service.documentForRead(calendar, try j.required(request, "eventId"));
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
        const review = try prepareOrdinaryReview(service, request, host, calendar);
        const store = service.persistence orelse return error.CalendarPersistenceRequired;
        try store.preserveFn(store.context, review);
        return eventReviewValue(service.a, review);
    }
    if (actionCommand(command)) {
        const dry_run = try j.boolean(request, "dryRun", false);
        const prepared = try service.prepareEventActionReview(calendar, try actionRequest(request, command), try j.required(request, "operationId"));
        // A dry run reads only: nothing is saved, so its plan has no hash to apply.
        if (!dry_run) {
            const review = prepared.review orelse return error.CalendarResponseRequired;
            const store = service.persistence orelse return error.CalendarPersistenceRequired;
            try store.preserveFn(store.context, review);
        }
        return actionReviewValue(service.a, prepared, j.text(request, "operationId"), dry_run);
    }
    if (std.mem.eql(u8, command, "calendar.agenda") or std.mem.eql(u8, command, "calendar.freebusy")) {
        const dated = try requestDatedWindow(service.a, request, host, calendar);
        var value = if (std.mem.eql(u8, command, "calendar.freebusy")) try j.value(service.a, try service.freeBusy(calendar, dated.window)) else agenda: {
            const result = try service.agenda(calendar, dated.window);
            break :agenda try j.value(service.a, .{ .calendar = calendar, .snapshot = result.snapshot, .refreshError = result.refresh_error, .cacheError = result.cache_error });
        };
        // The civil date a relative form used, in the window's own zone.
        if (dated.resolved_date) |date| if (value == .object) try value.object.put(service.a, "resolvedDate", .{ .string = date });
        return value;
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

/// An unconfirmed Calendar write to resume. `operationId` names it exactly
/// (as a CalendarOperationPending refusal reports it). Otherwise `eventId`
/// finds a write to that event, its whole series, or (for a series) one of
/// its occurrences; then, for a series action chosen on it, a write to
/// another occurrence. Series membership is the provider's: the caller's
/// `seriesEventId` (the event's recurring_event_id, "" when it does not
/// repeat), else one read of the event. Without `eventId` it finds an
/// unconfirmed creation. Nothing is written or sent.
fn pendingValue(service: svc.Service, request: j.Value, host: HostInputs, target: t.Target) !j.Value {
    const operation_id = j.text(request, "operationId");
    if (operation_id.len != 0) return foundValue(service, target, try exactPending(service, host, target, operation_id), "operation", true);
    const wanted = j.text(request, "eventId");
    if (wanted.len == 0) {
        const load = host.loadPendingFn orelse return error.CalendarPersistenceRequired;
        return foundValue(service, target, try load(host.context, service.a, target, ""), "creation", true);
    }
    const store = service.persistence orelse return error.CalendarPersistenceRequired;
    const find = store.pendingFn orelse return error.CalendarPersistenceRequired;
    var series: ?[]const u8 = if (j.get(request, "seriesEventId")) |value| try j.string(value) else null;
    if (try find(store.context, service.a, target, action.Reach.lookup(wanted, series orelse ""), "")) |found| return foundValue(service, target, found, "event", true);
    var read_error: []const u8 = "";
    if (series == null) {
        // The provider says which series the event belongs to. Without
        // that read the series stays unchecked, and the reply says so.
        series = learned: {
            const calendar = selectedCalendar(service, target) catch |err| {
                read_error = @errorName(err);
                break :learned null;
            };
            const document = service.documentForRead(calendar, wanted) catch |err| {
                read_error = @errorName(err);
                break :learned null;
            };
            break :learned document.event.recurring_event_id;
        };
        if (series) |known| if (known.len != 0) if (try find(store.context, service.a, target, action.Reach.lookup(wanted, known), "")) |found| return foundValue(service, target, found, "event", true);
    }
    if (series) |known| if (try find(store.context, service.a, target, action.Reach.seriesWide(wanted, known), "")) |found| return foundValue(service, target, found, "series", true);
    var empty = try foundValue(service, target, null, "", series != null);
    if (read_error.len != 0) try empty.object.put(service.a, "readError", .{ .string = read_error });
    return empty;
}
/// The one unknown write saved under `operation_id`, if any.
fn exactPending(service: svc.Service, host: HostInputs, target: t.Target, operation_id: []const u8) !?svc.Pending {
    const load = host.loadReviewFn orelse return error.CalendarPersistenceRequired;
    const store = service.persistence orelse return error.CalendarPersistenceRequired;
    const review = load(host.context, service.a, target, operation_id) catch |err| {
        if (err == error.CalendarReviewNotFound) return null;
        return err;
    };
    const state = try store.load(service.a, review.intent.identity);
    const operation = state.operation orelse return null;
    if (operation.state != .unknown or !std.mem.eql(u8, operation.intent.operation_id, operation_id)) return null;
    return .{ .review = review, .operation = operation };
}
fn foundValue(service: svc.Service, target: t.Target, found: ?svc.Pending, relation: []const u8, series_checked: bool) !j.Value {
    const a = service.a;
    var result = j.object(a);
    try result.object.put(a, "pending", .null);
    try result.object.put(a, "seriesChecked", .{ .bool = series_checked });
    const value = found orelse return result;
    if (value.operation.state != .unknown or !value.operation.intent.eql(value.review.intent) or !value.review.intent.identity.target.eql(target)) return error.CalendarReviewMismatch;
    if (!value.review.journaledEvent()) {
        // An invitation's own update: resolved from that invitation, not here.
        try result.object.put(a, "blockedBy", try j.value(a, .{ .kind = "invitation", .operationId = value.operation.intent.operation_id, .uid = value.operation.intent.identity.uid, .eventId = value.operation.intent.event_id, .recovery = "calendar.reconcile" }));
        return result;
    }
    try result.object.put(a, "pending", try j.value(a, .{ .review = try eventReviewValue(a, value.review), .relation = relation, .state = "unknown", .attempt = value.operation.attempt, .nextAttempt = value.operation.attempt +| 1, .retryPossible = false, .recoveryReason = "Check Calendar before retrying" }));
    return result;
}

/// Shared preparation keeps the legacy byte contract exact. Compound Meet
/// consent retains this returned value directly rather than racing a later
/// lookup of an unclaimed Calendar review that another editor could replace.
pub fn prepareOrdinaryReview(service: svc.Service, request: j.Value, host: HostInputs, selected: t.Calendar) !svc.Review {
    const event = j.get(request, "event") orelse return error.InvalidCalendarEvent;
    const zone_name = try j.required(event, "timeZone");
    var zone = try loadZone(service.a, host, zone_name);
    defer zone.deinit(service.a);
    const prepared = try ordinary.parse(service.a, request, &zone);
    return service.prepareEventReviewFields(selected, prepared, try j.required(request, "operationId"), j.text(request, "eventId"), j.text(request, "expectedEtag"), .{ .description_present = present(event, "description"), .location_present = present(event, "location") });
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
    for ([_][]const u8{ "calendar.list", "calendar.agenda", "calendar.event", "calendar.freebusy", "calendar.invitation-plan", "calendar.review", "calendar.apply", "calendar.import", "calendar.update", "calendar.cancel", "calendar.reconcile", "calendar.event-review", "calendar.event-apply", "calendar.event-reconcile", "calendar.event-retry", "calendar.event-abandon", "calendar.event-pending", "calendar.event-delete-review", "calendar.event-respond-review" }) |value| if (std.mem.eql(u8, command, value)) return true;
    return false;
}
/// Reviews of a delete or an attendee response on an existing event. Their
/// saved reviews are applied, checked, retried and archived by the shared
/// calendar.event-apply/-reconcile/-retry/-abandon commands.
pub fn actionCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "calendar.event-delete-review") or std.mem.eql(u8, command, "calendar.event-respond-review");
}
fn actionRequest(request: j.Value, command: []const u8) !svc.ActionRequest {
    const kind: action.Action = if (std.mem.eql(u8, command, "calendar.event-delete-review")) .delete else .respond;
    return .{
        .action = kind,
        .scope = std.meta.stringToEnum(action.Scope, try j.required(request, "scope")) orelse return error.InvalidCalendarScope,
        .send_updates = std.meta.stringToEnum(ordinary.UpdatePolicy, try j.required(request, "sendUpdates")) orelse return error.InvalidCalendarNotificationPolicy,
        .response = if (j.get(request, "response")) |value| std.meta.stringToEnum(action.Response, try j.string(value)) orelse return error.InvalidCalendarResponseStatus else null,
        .event_id = try j.required(request, "eventId"),
        .expected_etag = j.text(request, "expectedEtag"),
        .dry_run = try j.boolean(request, "dryRun", false),
    };
}
pub fn localCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "calendar.event-pending") or std.mem.eql(u8, command, "calendar.event-abandon");
}
/// Served from the local journal alone. An event-pending lookup by event ID
/// without its seriesEventId first reads the event to learn its series.
pub fn localRequest(request: j.Value) bool {
    const command = j.text(request, "cmd");
    if (!localCommand(command)) return false;
    if (!std.mem.eql(u8, command, "calendar.event-pending")) return true;
    return j.text(request, "eventId").len == 0 or j.text(request, "operationId").len != 0 or j.get(request, "seriesEventId") != null;
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
    if (std.mem.eql(u8, command, "calendar.event-pending")) {
        if (j.get(request, "eventId")) |value| if (value != .null) try t.text(try j.string(value), 1024, false);
        // "" says the event does not repeat; any other value is its series.
        if (j.get(request, "seriesEventId")) |value| try t.text(try j.string(value), 1024, true);
        if (j.get(request, "operationId")) |value| {
            const id = try j.string(value);
            try t.text(id, 128, false);
            for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidOperationId;
        }
    }
    if (std.mem.eql(u8, command, "calendar.event-retry")) {
        const attempt = try j.integer(request, "nextAttempt", 0);
        if (attempt <= 0 or attempt > 1000000) return error.InvalidCalendarRetry;
    } else if (j.get(request, "nextAttempt") != null) return error.InvalidCalendarConfirmation;
    if (std.mem.eql(u8, command, "calendar.agenda") or std.mem.eql(u8, command, "calendar.freebusy")) {
        // Relative forms resolve later, in the zone that builds the window.
        const date = try j.required(request, "date");
        if (!@import("cli_dates.zig").relative(date)) _ = try timezone.parseDate(date);
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
    if (actionCommand(command)) {
        for ([_][]const u8{ "messageId", "review", "request", "event", "reviewHash", "source" }) |field| if (j.get(request, field) != null) return error.InvalidCalendarRequest;
        try t.text(try j.required(request, "eventId"), 1024, false);
        // An empty version is no version: the same guidance as a missing one.
        if (j.get(request, "expectedEtag")) |value| {
            const etag = try j.string(value);
            if (etag.len == 0) return error.CalendarExpectedEtagRequired;
            try t.text(etag, 1024, false);
        }
        _ = std.meta.stringToEnum(action.Scope, try j.required(request, "scope")) orelse return error.InvalidCalendarScope;
        _ = std.meta.stringToEnum(ordinary.UpdatePolicy, try j.required(request, "sendUpdates")) orelse return error.InvalidCalendarNotificationPolicy;
        _ = try j.boolean(request, "dryRun", false);
        if (std.mem.eql(u8, command, "calendar.event-respond-review")) {
            if (j.get(request, "response")) |value| _ = std.meta.stringToEnum(action.Response, try j.string(value)) orelse return error.InvalidCalendarResponseStatus;
        } else if (j.get(request, "response") != null) return error.InvalidCalendarRequest;
    } else if (j.get(request, "dryRun")) |value| {
        // Only the action reviews and event-apply have a dry run.
        if (!std.mem.eql(u8, command, "calendar.event-apply")) return error.DryRunUnsupported;
        if (value != .bool) return error.InvalidRequest;
    }
    if (std.mem.eql(u8, command, "calendar.review") or std.mem.eql(u8, command, "calendar.event-review") or actionCommand(command) or executionCommand(command)) {
        const id = try j.required(request, "operationId");
        try t.text(id, 128, false);
        for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidOperationId;
    }
}

fn selectedCalendar(service: svc.Service, target: t.Target) !t.Calendar {
    return service.loadCalendar(target);
}

fn executeReview(service: svc.Service, request: j.Value, host: HostInputs, target: t.Target, command: []const u8) !j.Value {
    for ([_][]const u8{ "review", "source", "body", "request", "expectedEtag", "etag", "verifiedAliases", "event", "eventId", "sendUpdates" }) |field| if (j.get(request, field) != null) return error.InvalidCalendarConfirmation;
    const operation_id = try j.required(request, "operationId");
    const hash = try parseReviewHash(try j.required(request, "reviewHash"));
    const dry_run = try j.boolean(request, "dryRun", false);
    if (dry_run and !std.mem.eql(u8, command, "calendar.event-apply")) return error.DryRunUnsupported;
    if (host.loadReceiptFn) |load_receipt| if (try load_receipt(host.context, service.a, target, operation_id)) |receipt| {
        if (!receipt.operation.intent.identity.target.eql(target) or !std.mem.eql(u8, receipt.operation.intent.operation_id, operation_id) or !std.mem.eql(u8, &receipt.review_hash, &hash) or receipt.operation.state == .unknown) return error.CalendarReviewMismatch;
        const ordinary_command = std.mem.eql(u8, command, "calendar.event-apply") or std.mem.eql(u8, command, "calendar.event-reconcile") or std.mem.eql(u8, command, "calendar.event-retry") or std.mem.eql(u8, command, "calendar.event-abandon");
        if (ordinary_command != receipt.ordinary) return error.CalendarReviewMismatch;
        const required_kind: ?@TypeOf(receipt.operation.intent.kind) = if (std.mem.eql(u8, command, "calendar.import")) .import_event else if (std.mem.eql(u8, command, "calendar.update")) .update_event else if (std.mem.eql(u8, command, "calendar.cancel")) .cancel_event else null;
        if (required_kind) |kind| if (receipt.operation.intent.kind != kind) return error.CalendarReviewMismatch;
        // Replaying a recorded receipt never writes, dry run or not.
        var replay = try appliedValue(service.a, target, .{ .operation = receipt.operation });
        if (dry_run) try replay.object.put(service.a, "dryRun", .{ .bool = true });
        return replay;
    };
    const load = host.loadReviewFn orelse return error.CalendarPersistenceRequired;
    var review = try load(host.context, service.a, target, operation_id);
    if (!review.intent.identity.target.eql(target) or !std.mem.eql(u8, review.intent.operation_id, operation_id) or !std.mem.eql(u8, &hash, &review.review_hash)) return error.CalendarReviewMismatch;
    const expected_kind: ?@TypeOf(review.intent.kind) = if (std.mem.eql(u8, command, "calendar.import")) .import_event else if (std.mem.eql(u8, command, "calendar.update")) .update_event else if (std.mem.eql(u8, command, "calendar.cancel")) .cancel_event else null;
    if (expected_kind) |kind| if (review.intent.kind != kind) return error.CalendarReviewMismatch;
    const ordinary_command = std.mem.eql(u8, command, "calendar.event-apply") or std.mem.eql(u8, command, "calendar.event-reconcile") or std.mem.eql(u8, command, "calendar.event-retry") or std.mem.eql(u8, command, "calendar.event-abandon");
    if (ordinary_command != review.journaledEvent()) return error.CalendarReviewMismatch;
    const confirmation: svc.Confirmation = .{ .target = target, .operation_id = operation_id, .review_hash = hash };
    if (std.mem.eql(u8, command, "calendar.event-abandon")) return appliedValue(service.a, target, try service.archive(review, confirmation));
    review.calendar = try selectedCalendar(service, target);
    if (dry_run) return dryRunValue(service.a, target, review, try service.check(review, confirmation));
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
    return (try requestDatedWindow(a, request, host, calendar)).window;
}
pub const DatedWindow = struct { window: t.Window, resolved_date: ?[]const u8 };
/// The request window plus the civil date a relative form (today, +3d,
/// friday) resolved to, in the same zone: request timeZone, else the
/// selected calendar's zone, else the local zone.
pub fn requestDatedWindow(a: std.mem.Allocator, request: j.Value, host: HostInputs, calendar: t.Calendar) !DatedWindow {
    const zone_name = if (j.get(request, "timeZone")) |value| try j.string(value) else calendar.time_zone;
    var zone = try loadZone(a, host, zone_name);
    defer zone.deinit(a);
    const view = if (j.get(request, "view")) |value| try j.string(value) else "day";
    if (!std.mem.eql(u8, view, "day") and !std.mem.eql(u8, view, "week")) return error.InvalidCalendarView;
    const raw = try j.required(request, "date");
    const dates = @import("cli_dates.zig");
    var resolved: ?[]const u8 = null;
    if (dates.relative(raw)) {
        const now_ms = std.Io.Timestamp.now(host.io, .real).toMilliseconds();
        const today = zone.localDay(now_ms) catch @divFloor(now_ms, 86400000);
        resolved = (try dates.resolveWith(a, raw, today, dates.weekdayRule(j.text(request, "cmd")))) orelse return error.InvalidCalendarDate;
    }
    return .{ .window = try svc.windowForDays(a, resolved orelse raw, if (std.mem.eql(u8, view, "day")) .day else .week, .{ .id = zone_name, .zone = &zone }), .resolved_date = resolved };
}

pub fn requestPlan(service: svc.Service, request: j.Value, host: HostInputs, calendar: t.Calendar) !svc.InvitationPlan {
    if (!service.grants.canRead(calendar)) return error.CalendarReadPermissionRequired;
    const load = host.loadInvitationFn orelse return error.CalendarInvitationSourceRequired;
    const input = try load(host.context, service.a, service.grants.account, request);
    const source = try invitation.parseForCalendar(service.a, input.source, service.grants.account, input.verified_aliases);
    var start_name = try sourceZone(request, "startTimeZone", source.start);
    var end_name = try sourceZone(request, "endTimeZone", source.end);
    var time_error: []const u8 = "";
    var suggestion: []const u8 = "";
    var start_zone: ?timezone.Zone = if (start_name) |name| loadZone(service.a, host, name) catch |err| blk: {
        time_error = @errorName(err);
        break :blk if (j.get(request, "startTimeZone") == null) candidateZone(service.a, host, calendar, source, source.start, &start_name, &suggestion) else null;
    } else null;
    defer if (start_zone) |*zone| zone.deinit(service.a);
    var end_zone: ?timezone.Zone = if (end_name) |name| loadZone(service.a, host, name) catch |err| blk: {
        time_error = @errorName(err);
        break :blk if (j.get(request, "endTimeZone") == null) candidateZone(service.a, host, calendar, source, source.end, &end_name, &suggestion) else null;
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
    if (planned.span == null) planned.zone_suggestion = suggestion;
    return planned;
}

/// The source TZID did not load. Outlook names Windows zones and some
/// producers prefix a vendor path; timezone.canonicalId turns both into a
/// zoneinfo candidate. A candidate is used only when the source's own
/// VTIMEZONE agrees at the event (verifyEmbedded then proves the whole
/// span). Without embedded rules the mapping is our assumption about the
/// sender's meaning: it is reported as a suggestion and nothing is resolved.
/// The calendar zone remains the last candidate for embedded rules.
fn candidateZone(a: std.mem.Allocator, host: HostInputs, calendar: t.Calendar, source: t.Invitation, stamp: ?t.time.Stamp, name: *?[]const u8, suggestion: *[]const u8) ?timezone.Zone {
    const value = stamp orelse return null;
    if (value.kind == .zoned) {
        const mapped = timezone.canonicalId(value.zone);
        if (!std.mem.eql(u8, mapped, value.zone)) if (loadZone(a, host, mapped)) |loaded| {
            var zone = loaded;
            if (source.has_timezones) {
                const instant: ?i64 = zone.fromLocal(value.civil) catch null;
                if (instant) |at| if (embedded_zone.matches(source.unfolded, value.zone, &zone, at, at)) {
                    name.* = mapped;
                    return zone;
                };
            } else suggestion.* = mapped;
            zone.deinit(a);
        } else |_| {};
    }
    if (!source.has_timezones) return null;
    name.* = calendar.time_zone;
    return loadZone(a, host, calendar.time_zone) catch null;
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

const Recovery = struct { account: []const u8, calendarId: []const u8, operationId: []const u8, reviewHash: []const u8, action: []const u8, calendarOrganizer: []const u8 };
fn recovery(a: std.mem.Allocator, planned: svc.InvitationPlan, host: HostInputs) !?Recovery {
    const operation = planned.state.operation orelse return null;
    if (operation.state != .unknown) return null;
    const load = host.loadReviewFn orelse return error.CalendarPersistenceRequired;
    const review = try load(host.context, a, planned.calendar.target, operation.intent.operation_id);
    if (!review.intent.eql(operation.intent) or !review.calendar.target.eql(planned.calendar.target)) return error.CalendarReviewMismatch;
    const hash = std.fmt.bytesToHex(review.review_hash, .lower);
    return .{ .account = planned.calendar.target.account, .calendarId = planned.calendar.target.calendar_id, .operationId = operation.intent.operation_id, .reviewHash = try a.dupe(u8, &hash), .action = @tagName(review.intent.kind), .calendarOrganizer = if (review.intent.kind == .import_event) try @import("calendar_provider.zig").importedOrganizer(a, review.request) else review.source.organizer };
}
fn planValue(a: std.mem.Allocator, planned: svc.InvitationPlan, pending: ?Recovery) !j.Value {
    const existing: ?t.Event = switch (planned.decision) {
        .existing, .review_update, .review_cancel, .previously_cancelled, .reconciled => |event| event,
        else => null,
    };
    return j.value(a, .{ .calendar = planned.calendar, .invitation = planned.source, .resolved = planned.span, .decision = @tagName(std.meta.activeTag(planned.decision)), .writable = planned.writable, .lookupComplete = planned.lookup.complete, .timeError = planned.time_error, .timeZoneSuggestion = planned.zone_suggestion, .event = existing, .operation = planned.state.operation, .recovery = pending });
}
fn reviewValue(a: std.mem.Allocator, review: svc.Review) !j.Value {
    const hash = std.fmt.bytesToHex(review.review_hash, .lower);
    return j.value(a, .{ .account = review.intent.identity.target.account, .calendarId = review.intent.identity.target.calendar_id, .calendarName = review.calendar.summary, .operationId = review.intent.operation_id, .reviewHash = hash[0..], .action = @tagName(review.intent.kind), .calendarOrganizer = if (review.intent.kind == .import_event) try @import("calendar_provider.zig").importedOrganizer(a, review.request) else review.source.organizer, .uid = review.intent.identity.uid, .version = review.intent.version, .eventId = review.intent.event_id, .expectedEtag = review.intent.expected_etag, .invitation = review.source, .resolved = review.span, .previous = review.previous });
}

pub fn eventReviewValue(a: std.mem.Allocator, review: svc.Review) !j.Value {
    const hash = std.fmt.bytesToHex(review.review_hash, .lower);
    if (review.event_action) |prepared| return actionReviewValue(a, .{ .prepared = prepared, .options = null, .calendar = review.calendar, .target_etag = review.intent.expected_etag, .review = review }, review.intent.operation_id, false);
    const prepared = review.ordinary_event orelse return error.CalendarReviewMismatch;
    return j.value(a, .{ .account = review.intent.identity.target.account, .calendarId = review.intent.identity.target.calendar_id, .calendarName = review.calendar.summary, .operationId = review.intent.operation_id, .reviewHash = hash[0..], .action = if (review.intent.kind == .insert_event) @as([]const u8, "create_event") else "update_event", .eventId = review.intent.event_id, .expectedEtag = review.intent.expected_etag, .event = prepared.draft, .resolved = prepared.span, .sendUpdates = @tagName(prepared.send_updates), .previous = review.previous, .conference = @tagName(prepared.draft.conference) });
}

/// The action review returned to the CLI and TUI. `consequence` is the one
/// sentence a confirmation dialog shows; `options` lists the other choices.
pub fn actionReviewValue(a: std.mem.Allocator, value: svc.ActionReview, operation_id: []const u8, dry_run: bool) !j.Value {
    const prepared = value.prepared;
    var hex: [64]u8 = undefined;
    var hash: ?[]const u8 = null;
    if (value.review) |review| if (!dry_run) {
        hex = std.fmt.bytesToHex(review.review_hash, .lower);
        hash = &hex;
    };
    return j.value(a, .{
        .account = value.calendar.target.account,
        .calendarId = value.calendar.target.calendar_id,
        .calendarName = value.calendar.summary,
        .operationId = operation_id,
        .reviewHash = hash,
        .action = if (prepared.action == .delete) @as([]const u8, "delete_event") else "respond_event",
        .scope = @tagName(prepared.scope),
        .sendUpdates = @tagName(prepared.send_updates),
        .response = if (prepared.response) |response| @as(?[]const u8, action.wire(response)) else null,
        .previousResponse = prepared.previous_response,
        .role = @tagName(prepared.role),
        .eventId = prepared.selected_event_id,
        .expectedEtag = prepared.selected_etag,
        .targetEventId = prepared.target_event_id,
        .targetEtag = value.target_etag,
        .summary = prepared.summary,
        .start = prepared.start,
        .end = prepared.end,
        .recurring = prepared.recurring,
        .guestCount = prepared.guest_count,
        .guestsOmitted = prepared.guests_omitted,
        .organizer = prepared.organizer,
        .attendee = prepared.attendee,
        .seriesEventId = prepared.series_event_id,
        .recurrence = prepared.recurrence,
        .ownCalendar = prepared.own_calendar,
        .consequence = try action.consequence(a, prepared, value.calendar.summary),
        .options = value.options,
        .dryRun = dry_run,
        .saved = !dry_run and value.review != null,
    });
}

/// event-apply with dryRun: the same fresh checks as apply, nothing saved,
/// claimed or sent. An operation already recorded under this ID is reported.
fn dryRunValue(a: std.mem.Allocator, target: t.Target, review: svc.Review, existing: ?@import("calendar_plan.zig").Operation) !j.Value {
    const request = review.request;
    const query = std.mem.indexOfScalar(u8, request.url, '?');
    const send_updates = if (query) |at| if (std.mem.indexOf(u8, request.url[at..], "sendUpdates=")) |found| blk: {
        const rest = request.url[at + found + "sendUpdates=".len ..];
        break :blk rest[0 .. std.mem.indexOfScalar(u8, rest, '&') orelse rest.len];
    } else "" else "";
    const action_name: []const u8 = if (review.event_action) |prepared| (if (prepared.action == .delete) "delete_event" else "respond_event") else if (review.intent.kind == .insert_event) "create_event" else "update_event";
    return j.value(a, .{
        .account = target.account,
        .calendarId = target.calendar_id,
        .operationId = review.intent.operation_id,
        .dryRun = true,
        .state = if (existing) |operation| @tagName(operation.state) else "not_sent",
        .wouldSend = .{ .action = action_name, .method = @tagName(request.method), .eventId = review.intent.event_id, .ifMatch = request.if_match, .sendUpdates = send_updates },
        .consequence = if (review.event_action) |prepared| try action.consequence(a, prepared, review.calendar.summary) else "",
    });
}

fn appliedValue(a: std.mem.Allocator, target: t.Target, result: svc.Applied) !j.Value {
    // The operation may already be applied or durably uncertain. Losing its
    // command DTO must retain that ambiguity before Core encodes the envelope.
    return j.value(a, .{ .account = target.account, .calendarId = target.calendar_id, .operationId = result.operation.intent.operation_id, .uid = result.operation.intent.identity.uid, .state = @tagName(result.operation.state), .providerId = result.operation.provider_id, .reconciled = result.reconciled, .errorCode = if (result.failure) |failure| @errorName(svc.failureError(failure)) else result.operation.error_code, .event = result.event, .attempt = result.operation.attempt, .nextAttempt = result.operation.attempt +| 1, .retryPossible = result.retry_possible, .recoveryReason = result.recovery_reason, .providerError = result.provider_error }) catch return error.UnknownOutcome;
}

fn present(value: j.Value, field: []const u8) bool {
    return if (j.get(value, field)) |raw| raw != .null else false;
}
