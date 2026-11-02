//! New command names fence older backends that would otherwise ignore a new
//! optional field and save an event without its requested Meet notes settings.
const std = @import("std");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const service = @import("meet_notes_service.zig");
const records = @import("meet_notes_types.zig");
const provider = @import("meet_notes_provider.zig");
const calendar_commands = @import("calendar_commands.zig");

pub fn supported(command: []const u8) bool {
    for ([_][]const u8{ "calendar.meet-event-review", "calendar.meet-event-apply", "calendar.meet-event-reconcile", "calendar.meet-event-pending" }) |name| if (std.mem.eql(u8, command, name)) return true;
    return false;
}
pub fn local(command: []const u8) bool {
    return std.mem.eql(u8, command, "calendar.meet-event-pending");
}
fn hash(raw: []const u8) ![32]u8 {
    if (raw.len != 64) return error.MeetReviewMismatch;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.MeetReviewMismatch;
    return result;
}
fn enabled(request: j.Value) !bool {
    const value = try j.required(request, "meetAiNotes");
    if (std.mem.eql(u8, value, "on")) return true;
    return error.InvalidMeetNotesIntent;
}
pub fn preflight(request: j.Value) !void {
    const command = try j.required(request, "cmd");
    if (!supported(command)) return error.UnsupportedCalendarCommand;
    if (try j.boolean(request, "cacheOnly", false) and !local(command)) return error.CacheUnsupported;
    try @import("../bounded.zig").address(try j.required(request, "account"));
    for ([_][]const u8{ "body", "request", "review", "source", "spaceName", "url", "verifiedAliases", "scopes", "capabilities" }) |key| if (j.get(request, key) != null) return error.InvalidMeetRequest;
    const target: t.Target = .{ .account = try j.required(request, "account"), .calendar_id = try j.required(request, "calendarId") };
    try target.validate();
    if (std.mem.eql(u8, command, "calendar.meet-event-pending")) {
        try t.text(j.text(request, "eventId"), 1024, true);
        return;
    }
    try records.operationId(try j.required(request, "operationId"));
    if (std.mem.eql(u8, command, "calendar.meet-event-review")) {
        _ = try enabled(request);
        if (j.get(request, "event") == null or j.get(request, "eventId") != null or j.get(request, "expectedEtag") != null) return error.MeetNewEventsOnly;
        const event = j.get(request, "event").?;
        for ([_][]const u8{ "recurrence", "recurringEventId", "originalStartTime", "rrule" }) |key| if (j.get(event, key) != null) return error.MeetRecurringUnsupported;
        if (!std.mem.eql(u8, j.text(event, "conference"), "google_meet")) return error.MeetLinkNotProvider;
    } else {
        _ = try hash(try j.required(request, "reviewHash"));
        for ([_][]const u8{ "event", "eventId", "expectedEtag", "sendUpdates", "meetAiNotes" }) |key| if (j.get(request, key) != null) return error.InvalidCalendarConfirmation;
    }
}

pub fn dispatch(instance: service.Service, request: j.Value, host: calendar_commands.HostInputs) !j.Value {
    try preflight(request);
    const a = instance.a;
    const command = try j.required(request, "cmd");
    const account = try j.required(request, "account");
    if (!std.ascii.eqlIgnoreCase(account, instance.book.account)) return error.CalendarAccountMismatch;
    const target: t.Target = .{ .account = account, .calendar_id = try j.required(request, "calendarId") };
    if (std.mem.eql(u8, command, "calendar.meet-event-pending")) {
        const pending = try instance.book.pending(a, target, j.text(request, "eventId"));
        return j.value(a, .{ .account = account, .calendarId = target.calendar_id, .pending = if (pending) |entry| try reviewValue(a, entry) else @as(?j.Value, null), .meetSettingsAccess = instance.settings_access, .capabilities = instance.capabilities });
    }
    if (std.mem.eql(u8, command, "calendar.meet-event-review")) {
        if (!instance.settings_access) return error.MeetSettingsPermissionRequired;
        const selected = try instance.calendar.loadCalendar(target);
        if (!selected.primary) return error.MeetNotOrganizer;
        const entry = blk: {
            var inner_request = try j.copyObject(a, request);
            try inner_request.object.put(a, "cmd", .{ .string = "calendar.event-review" });
            _ = inner_request.object.swapRemove("meetAiNotes");
            try calendar_commands.preflight(inner_request);
            const inner = try calendar_commands.prepareOrdinaryReview(instance.calendar, inner_request, host, selected);
            const store = instance.calendar.persistence orelse return error.CalendarPersistenceRequired;
            try store.preserveFn(store.context, inner);
            break :blk try instance.reviewEvent(inner, try enabled(request));
        };
        return reviewValue(a, entry);
    }
    const mode: service.Mode = if (std.mem.eql(u8, command, "calendar.meet-event-reconcile")) .reconcile else .apply;
    const operation_id = try j.required(request, "operationId");
    const review_hash = try hash(try j.required(request, "reviewHash"));
    const before = try instance.book.read(a, target, operation_id);
    if (!std.mem.eql(u8, &before.review_hash, &review_hash)) return error.MeetReviewMismatch;
    if (before.consent.parent != .insert or !before.consent.enabled) return error.MeetNewEventsOnly;
    const result = instance.execute(target, operation_id, review_hash, mode) catch |err| {
        if (mode == .apply) {
            const saved = instance.book.read(a, target, operation_id) catch return error.UnknownOutcome;
            if (saved.phase != .reviewed) return error.UnknownOutcome;
        }
        return err;
    };
    return resultValue(a, result) catch |err| {
        if (mode == .apply) return error.UnknownOutcome;
        return err;
    };
}

pub fn reviewValue(a: std.mem.Allocator, entry: records.Entry) !j.Value {
    const c = entry.consent;
    var value = if (entry.calendar_review) |inner| try calendar_commands.eventReviewValue(a, inner) else try j.value(a, .{
        .account = c.target.account,
        .calendarId = c.target.calendar_id,
        .calendarName = c.calendar_name,
        .operationId = c.operation_id,
        .eventId = c.event_id,
        .action = if (c.parent == .none) @as([]const u8, "meet_notes") else if (c.parent == .insert) "create_event" else "update_event",
        .event = .{ .summary = c.summary, .timeZone = c.time_zone, .allDay = c.all_day },
        .resolved = .{ .start = c.start, .end = c.end },
        .sendUpdates = if (c.notify_guests) @as([]const u8, "all") else "none",
        .guestCount = c.guest_count,
        .conference = "google_meet",
    });
    const digest = std.fmt.bytesToHex(entry.review_hash, .lower);
    try value.object.put(a, "reviewHash", .{ .string = try a.dupe(u8, &digest) });
    try value.object.put(a, "contract", .{ .string = "meet-event-v1" });
    try value.object.put(a, "notesOnly", .{ .bool = c.parent == .none });
    try value.object.put(a, "meetAiNotes", try j.value(a, .{ .enabled = c.enabled, .spaceWide = true, .phase = @tagName(entry.phase), .generation = entry.generation, .calendarState = @tagName(entry.calendar_state), .reason = entry.reason }));
    return value;
}
pub fn resultValue(a: std.mem.Allocator, result: service.Result) !j.Value {
    const ProviderError = struct { status: u16, reason: []const u8, message: []const u8 };
    const Current = struct { notes: []const u8, transcription: []const u8, observedAt: i64 };
    const e = result.entry;
    const uncertain = e.phase == .unknown or (e.phase == .abandoned and e.generation != 0);
    const state: []const u8 = if (e.calendar_state == .unknown or e.calendar_state == .archived or uncertain) "unknown" else if (e.calendar_state == .rejected) "rejected" else if (e.phase == .confirmed) "applied" else if (e.calendar_state == .not_sent) "not_sent" else "partial";
    const notes_state: []const u8 = switch (e.phase) {
        .confirmed => if (e.consent.enabled) "on" else "off",
        .unknown => "unknown",
        .waiting_link => if (e.reason.len == 0 or std.mem.eql(u8, e.reason, "MeetConferencePending")) @as([]const u8, "waiting_for_link") else "not_sent",
        .refused => "refused",
        .abandoned => if (e.generation != 0) "unknown" else "not_sent",
        else => "not_sent",
    };
    const next: []const u8 = if (e.phase == .confirmed or e.phase == .abandoned) "none" else if (e.calendar_state == .unknown or e.phase == .unknown) "reconcile" else if (e.phase == .refused) (if (std.mem.eql(u8, e.reason, "MeetSettingsPermissionRequired")) @as([]const u8, "connect") else "review") else "finish";
    const attempt = if (e.calendar_state == .unknown and result.calendar_result != null) result.calendar_result.?.operation.attempt else e.generation;
    return j.value(a, .{
        .account = e.consent.target.account,
        .calendarId = e.consent.target.calendar_id,
        .eventId = e.consent.event_id,
        .operationId = e.consent.operation_id,
        .state = state,
        .contract = "meet-event-v1",
        .calendar = .{ .state = @tagName(e.calendar_state), .reason = e.calendar_reason },
        .meetAiNotes = .{ .state = notes_state, .enabled = e.consent.enabled, .phase = @tagName(e.phase), .reason = e.reason, .next = next, .attempt = e.generation, .observedAt = e.observed_ms, .historical = result.observed == null, .providerError = if (e.provider_status != 0) @as(?ProviderError, .{ .status = e.provider_status, .reason = e.provider_reason, .message = e.provider_message }) else null },
        .current = if (result.observed) |space| @as(?Current, .{ .notes = @tagName(space.notes), .transcription = @tagName(space.transcription), .observedAt = result.observed_ms }) else null,
        .readError = result.read_error,
        .retryPossible = false,
        .attempt = attempt,
        .review = try reviewValue(a, e),
    });
}
