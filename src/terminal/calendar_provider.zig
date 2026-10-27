//! Google Calendar request/response shaping. No network calls or token access.
//! The host verifies the selected grant/account and durably claims each write.
const std = @import("std");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const invitation = @import("calendar_invitation.zig");
const plan = @import("calendar_plan.zig");
const time = t.time;
const tools = @import("reader_tools.zig");
const meeting_link = @import("meeting_link.zig");
pub const base_url = "https://www.googleapis.com/calendar/v3";
pub const event_fields = "id,iCalUID,etag,organizer(email),summary,description,location,hangoutLink,htmlLink,eventType,start,end,originalStartTime,recurringEventId,sequence,status,transparency,locked,privateCopy,attendees(self,email,responseStatus),attendeesOmitted,extendedProperties(private),conferenceData(createRequest(status(statusCode)),entryPoints(entryPointType,uri))";
pub const OperationKind = enum {
    calendar_list,
    event_lookup,
    agenda,
    event_get,
    free_busy,
    import_event,
    insert_event,
    update_event,
    cancel_event,
    pub fn mutating(self: OperationKind) bool {
        return self == .insert_event or self == .import_event or self == .update_event or self == .cancel_event;
    }
};
pub const Request = struct {
    target: t.Target,
    kind: OperationKind,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
    if_match: ?[]const u8 = null,

    /// Finalize the exact request fingerprint before the encrypted journal
    /// claims it. Only a fresh durable claim authorizes host dispatch.
    pub fn bindIntent(self: Request, intent: plan.Intent) !plan.Intent {
        try intent.validate();
        if (!self.kind.mutating() or !self.target.eql(intent.identity.target)) return error.CalendarIdentityMismatch;
        const expected: OperationKind = switch (intent.kind) {
            .import_event => .import_event,
            .insert_event => .insert_event,
            .update_event => .update_event,
            .cancel_event => .cancel_event,
        };
        if (self.kind != expected) return error.CalendarIdentityMismatch;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ self.target.account, self.target.calendar_id, @tagName(self.kind), @tagName(self.method), self.url, self.if_match orelse "", self.body orelse "" }) |part| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(part.len), .big);
            hasher.update(&length);
            hasher.update(part);
        }
        var result = intent;
        hasher.final(&result.payload_hash);
        return result;
    }
};

pub fn listCalendars(a: std.mem.Allocator, account: []const u8, page_token: []const u8) !Request {
    const target: t.Target = .{ .account = account, .calendar_id = "primary" };
    try target.validate();
    const suffix = try tokenSuffix(a, page_token);
    return .{ .target = target, .kind = .calendar_list, .method = .GET, .url = try std.fmt.allocPrint(a, base_url ++ "/users/me/calendarList?maxResults={d}&showHidden=true&fields=items(id,summary,timeZone,accessRole,dataOwner,primary,selected,conferenceProperties),nextPageToken{s}", .{ t.Limits.calendar_page, suffix }) };
}

pub fn lookup(a: std.mem.Allocator, target: t.Target, uid: []const u8, page_token: []const u8) !Request {
    try target.validate();
    try t.text(uid, 1024, false);
    const url = try std.fmt.allocPrint(a, "{s}/events?iCalUID={s}&showHiddenInvitations=true&showDeleted=true&singleEvents=false&maxResults=100&maxAttendees=1&fields=items({s}),nextPageToken{s}", .{ try calendarPath(a, target), try encode(a, uid), event_fields, try tokenSuffix(a, page_token) });
    return .{ .target = target, .kind = .event_lookup, .method = .GET, .url = url };
}

pub fn agenda(a: std.mem.Allocator, target: t.Target, window: t.Window, page_token: []const u8) !Request {
    try target.validate();
    try window.validate();
    const start = try time.format(a, .{ .kind = .instant, .value = window.start_ms });
    const end = try time.format(a, .{ .kind = .instant, .value = window.end_ms });
    const url = try std.fmt.allocPrint(a, "{s}/events?timeMin={s}&timeMax={s}&timeZone={s}&singleEvents=true&orderBy=startTime&showHiddenInvitations=true&maxResults=100&maxAttendees=1&fields=items({s}),nextPageToken{s}", .{ try calendarPath(a, target), try encode(a, start), try encode(a, end), try encode(a, window.time_zone), event_fields, try tokenSuffix(a, page_token) });
    // Bounded window refreshes intentionally do not mix syncToken with
    // timeMin/timeMax, which Google forbids.
    return .{ .target = target, .kind = .agenda, .method = .GET, .url = url };
}

pub fn get(a: std.mem.Allocator, target: t.Target, event_id: []const u8) !Request {
    return .{ .target = target, .kind = .event_get, .method = .GET, .url = try eventPath(a, target, event_id) };
}

pub fn prepareImport(a: std.mem.Allocator, source: t.Invitation, intent: plan.Intent, start_binding: ?time.Binding, end_binding: ?time.Binding) !Request {
    if (source.method == .cancel or source.cancelled) return error.CalendarCancelled;
    if (source.isRecurring()) return error.UnsupportedCalendarRecurrence;
    return prepareResolvedImport(a, source, intent, try invitation.resolveSpan(source, start_binding, end_binding));
}

/// The service resolves and reviews these exact values before binding a write.
pub fn prepareResolvedImport(a: std.mem.Allocator, source: t.Invitation, intent: plan.Intent, span: invitation.Span) !Request {
    try intent.validate();
    if (intent.kind != .import_event or !std.ascii.eqlIgnoreCase(source.account, intent.identity.target.account) or !std.mem.eql(u8, source.uid, intent.identity.uid) or intent.identity.recurrence_key.len != 0 or !std.mem.eql(u8, &source.source_hash, &intent.source_hash) or source.version.order(intent.version) != .eq) return error.CalendarIdentityMismatch;
    if (source.method == .cancel or source.cancelled) return error.CalendarCancelled;
    if (source.isRecurring()) return error.UnsupportedCalendarRecurrence;
    try validSpan(span);
    const description = if (source.join_url.len != 0 and std.mem.indexOf(u8, source.description, source.join_url) == null) try std.fmt.allocPrint(a, "{s}\n\nJoin: {s}", .{ source.description, source.join_url }) else source.description;
    try validateInvitationText(source, description);
    const source_hex = std.fmt.bytesToHex(source.source_hash, .lower);
    const body = try std.json.Stringify.valueAlloc(a, .{
        .iCalUID = source.uid,
        .organizer = .{ .email = source.organizer },
        .summary = source.summary,
        .description = description,
        .location = source.location,
        .start = try googleTime(a, span.start),
        .end = try googleTime(a, span.end),
        .sequence = source.version.sequence,
        .attendees = [_]struct { email: []const u8, responseStatus: []const u8 }{.{ .email = source.attendee, .responseStatus = "needsAction" }},
        .transparency = if (source.transparent) @as([]const u8, "transparent") else "opaque",
        .visibility = if (source.private) @as([]const u8, "private") else "default",
        .extendedProperties = .{ .private = .{ .omagmaOperation = intent.operation_id, .omagmaSource = source_hex[0..] } },
    }, .{ .emit_null_optional_fields = false });
    if (body.len > t.Limits.source_bytes * 2) return error.CalendarTooLarge;
    // No event ID, sendUpdates, conference creation, or organizer replacement.
    // import is the documented attendee-copy path that sends no invitation.
    return .{ .target = intent.identity.target, .kind = .import_event, .method = .POST, .url = try std.fmt.allocPrint(a, "{s}/events/import", .{try calendarPath(a, intent.identity.target)}), .body = body };
}

pub fn prepareCancel(a: std.mem.Allocator, intent: plan.Intent) !Request {
    try intent.validate();
    if (intent.kind != .cancel_event) return error.InvalidCalendarMutation;
    return .{ .target = intent.identity.target, .kind = .cancel_event, .method = .DELETE, .url = try std.fmt.allocPrint(a, "{s}?sendUpdates=none", .{try eventPath(a, intent.identity.target, intent.event_id)}), .if_match = intent.expected_etag };
}

/// Preserve unrelated private and shared extended properties from a fresh GET.
/// Never replace attendee, recurrence, attachment, or conference arrays.
pub fn prepareInvitationPatch(a: std.mem.Allocator, source: t.Invitation, intent: plan.Intent, span: invitation.Span, document: EventDocument) !Request {
    try intent.validate();
    if (intent.kind != .update_event or source.isRecurring() or source.method != .request or source.cancelled) return error.InvalidCalendarMutation;
    if (!sourceMatches(source, intent) or !document.event.target.eql(intent.identity.target) or !std.mem.eql(u8, document.event.id, intent.event_id) or !std.mem.eql(u8, document.event.uid, source.uid) or !std.ascii.eqlIgnoreCase(document.event.organizer, source.organizer) or !std.mem.eql(u8, document.event.etag, intent.expected_etag)) return error.CalendarIdentityMismatch;
    try validSpan(span);
    var properties = if (j.get(document.value, "extendedProperties")) |value| try j.copyObject(a, value) else j.object(a);
    var private = if (j.get(properties, "private")) |value| try j.copyObject(a, value) else j.object(a);
    try private.object.put(a, "omagmaOperation", .{ .string = intent.operation_id });
    const source_hex = std.fmt.bytesToHex(source.source_hash, .lower);
    try private.object.put(a, "omagmaSource", .{ .string = try a.dupe(u8, &source_hex) });
    try properties.object.put(a, "private", private);
    const description = if (source.join_url.len != 0 and std.mem.indexOf(u8, source.description, source.join_url) == null) try std.fmt.allocPrint(a, "{s}\n\nJoin: {s}", .{ source.description, source.join_url }) else source.description;
    try validateInvitationText(source, description);
    return preparePatch(a, intent, try j.value(a, .{ .summary = source.summary, .description = description, .location = source.location, .start = try googleTime(a, span.start), .end = try googleTime(a, span.end), .sequence = source.version.sequence, .extendedProperties = properties }));
}

fn validateInvitationText(source: t.Invitation, description: []const u8) !void {
    // A prepared event must also fit our provider read/reconciliation model.
    // Reject before RSVP submission rather than write an unreadable event.
    if (source.summary.len > 4096) return error.CalendarSummaryTooLarge;
    if (source.location.len > 4096) return error.CalendarLocationTooLarge;
    if (description.len > 64 * 1024) return error.CalendarDescriptionTooLarge;
}

fn validSpan(span: invitation.Span) !void {
    if (span.start.kind != span.end.kind or span.end.value <= span.start.value) return error.InvalidCalendarTime;
}

fn sourceMatches(source: t.Invitation, intent: plan.Intent) bool {
    return std.ascii.eqlIgnoreCase(source.account, intent.identity.target.account) and std.mem.eql(u8, source.uid, intent.identity.uid) and intent.identity.recurrence_key.len == 0 and std.mem.eql(u8, &source.source_hash, &intent.source_hash) and source.version.order(intent.version) == .eq;
}

/// Changed fields are a reviewed patch against the GET version, not an
/// entire truncated list item. Array replacement is explicitly refused here.
/// The adapter must preserve conferencing and unrelated provider properties.
pub fn preparePatch(a: std.mem.Allocator, intent: plan.Intent, changes: j.Value) !Request {
    try intent.validate();
    if (intent.kind != .update_event or changes != .object) return error.InvalidCalendarMutation;
    var iterator = changes.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.eql(u8, name, "summary") and !std.mem.eql(u8, name, "description") and !std.mem.eql(u8, name, "location") and !std.mem.eql(u8, name, "start") and !std.mem.eql(u8, name, "end") and !std.mem.eql(u8, name, "sequence") and !std.mem.eql(u8, name, "extendedProperties")) return error.InvalidCalendarMutation;
    }
    const body = try std.json.Stringify.valueAlloc(a, changes, .{});
    if (body.len > t.Limits.source_bytes * 2) return error.CalendarTooLarge;
    return .{ .target = intent.identity.target, .kind = .update_event, .method = .PATCH, .url = try std.fmt.allocPrint(a, "{s}?sendUpdates=none", .{try eventPath(a, intent.identity.target, intent.event_id)}), .body = body, .if_match = intent.expected_etag };
}

pub const Failure = enum { unauthorized, forbidden, not_found, duplicate, version_conflict, full_refresh_required, rate_limited, rejected, transient, unknown };
pub fn classifyFailure(kind: OperationKind, status: u16, reason: []const u8) Failure {
    return switch (status) {
        401 => .unauthorized,
        403 => if (std.mem.eql(u8, reason, "rateLimitExceeded") or std.mem.eql(u8, reason, "userRateLimitExceeded")) .rate_limited else .forbidden,
        404 => .not_found,
        409 => .duplicate,
        410 => .full_refresh_required,
        412 => .version_conflict,
        429 => .rate_limited,
        500...599 => if (kind.mutating()) .unknown else .transient,
        400 => .rejected,
        else => if (kind.mutating()) .unknown else .transient,
    };
}

pub fn decodePage(a: std.mem.Allocator, target: t.Target, bytes: []const u8, fetched_at_ms: i64) !t.Page {
    try target.validate();
    const value = try parseJson(a, bytes);
    const items = j.get(value, "items") orelse return error.InvalidCalendarResponse;
    if (items != .array or items.array.items.len > t.Limits.page_events) return error.TooManyCalendarEvents;
    const events = try a.alloc(t.Event, items.array.items.len);
    // Own the binding as well as all event fields; provider buffers can reset.
    const owned_target: t.Target = .{ .account = try a.dupe(u8, target.account), .calendar_id = try a.dupe(u8, target.calendar_id) };
    for (items.array.items, events) |item, *event| event.* = try decodeEvent(a, owned_target, item);
    return .{ .target = owned_target, .events = events, .next_page_token = try field(a, value, "nextPageToken", 4096, true), .fetched_at_ms = fetched_at_ms };
}

pub const CalendarPage = struct { calendars: []const t.Calendar, next_page_token: []const u8 };
pub fn decodeCalendars(a: std.mem.Allocator, account: []const u8, bytes: []const u8) !CalendarPage {
    try b.address(account);
    const value = try parseJson(a, bytes);
    const items = j.get(value, "items") orelse return error.InvalidCalendarResponse;
    if (items != .array or items.array.items.len > t.Limits.calendar_page) return error.TooManyCalendars;
    const calendars = try a.alloc(t.Calendar, items.array.items.len);
    const owned_account = try a.dupe(u8, account);
    for (items.array.items, calendars) |item, *calendar| calendar.* = try decodeCalendarValue(a, owned_account, item);
    return .{ .calendars = calendars, .next_page_token = try field(a, value, "nextPageToken", 4096, true) };
}

pub fn getCalendar(a: std.mem.Allocator, target: t.Target) !Request {
    try target.validate();
    return .{ .target = target, .kind = .calendar_list, .method = .GET, .url = try std.fmt.allocPrint(a, base_url ++ "/users/me/calendarList/{s}", .{try encode(a, target.calendar_id)}) };
}
pub fn decodeCalendar(a: std.mem.Allocator, target: t.Target, bytes: []const u8) !t.Calendar {
    const calendar = try decodeCalendarValue(a, target.account, try parseJson(a, bytes));
    if (!calendar.target.eql(target) and !(std.mem.eql(u8, target.calendar_id, "primary") and calendar.primary)) return error.CalendarIdentityMismatch;
    return calendar;
}
fn decodeCalendarValue(a: std.mem.Allocator, account: []const u8, item: j.Value) !t.Calendar {
    try b.address(account);
    const role = try field(a, item, "accessRole", 32, false);
    const access: t.Access = if (std.mem.eql(u8, role, "owner")) .owner else if (std.mem.eql(u8, role, "writer")) .writer else if (std.mem.eql(u8, role, "writerWithoutPrivateAccess")) .writer_without_private else if (std.mem.eql(u8, role, "reader")) .reader else if (std.mem.eql(u8, role, "freeBusyReader")) .free_busy else if (std.mem.eql(u8, role, "none")) .none else return error.InvalidCalendarResponse;
    var calendar: t.Calendar = .{ .target = .{ .account = try a.dupe(u8, account), .calendar_id = try field(a, item, "id", 1024, false) }, .summary = try field(a, item, "summary", 1024, true), .time_zone = try field(a, item, "timeZone", 512, false), .access = access, .primary = try j.boolean(item, "primary", false), .selected = try j.boolean(item, "selected", false) };
    if (j.get(item, "conferenceProperties")) |properties| if (j.get(properties, "allowedConferenceSolutionTypes")) |allowed| {
        if (allowed != .array or allowed.array.items.len > 16) return error.InvalidCalendarResponse;
        for (allowed.array.items) |solution| if (std.mem.eql(u8, try j.string(solution), "hangoutsMeet")) {
            calendar.supports_meet = true;
        };
    };
    calendar.data_owner = try field(a, item, "dataOwner", 512, true);
    if (calendar.data_owner.len != 0) try b.address(calendar.data_owner);
    calendar.owned_scope_verified = calendar.primary or std.ascii.eqlIgnoreCase(calendar.data_owner, account);
    try time.validateZoneName(calendar.time_zone);
    return calendar;
}

pub const EventDocument = struct { event: t.Event, value: j.Value };
pub const RsvpResponse = enum { accepted, tentative };

/// Google explicitly supports attendeesOmitted when updating only a
/// participant's response. Never replace the complete attendee list.
pub fn withRsvpResponse(a: std.mem.Allocator, request: Request, attendee: []const u8, response: RsvpResponse, document: ?EventDocument) !Request {
    if (request.kind != .import_event and request.kind != .update_event) return error.InvalidCalendarMutation;
    if (document) |current| if (!hasAttendee(current, attendee)) return error.CalendarAttendeeMismatch;
    var body = try parseJson(a, request.body orelse return error.InvalidCalendarMutation);
    try body.object.put(a, "attendees", try j.value(a, [_]struct { email: []const u8, responseStatus: []const u8 }{.{ .email = attendee, .responseStatus = @tagName(response) }}));
    if (request.kind == .update_event) try body.object.put(a, "attendeesOmitted", .{ .bool = true });
    var result = request;
    result.body = try std.json.Stringify.valueAlloc(a, body, .{});
    return result;
}

pub fn prepareRsvpPatch(a: std.mem.Allocator, source: t.Invitation, intent: plan.Intent, document: EventDocument, response: RsvpResponse) !Request {
    if (!sourceMatches(source, intent) or !document.event.target.eql(intent.identity.target) or !std.mem.eql(u8, document.event.uid, source.uid) or !std.mem.eql(u8, document.event.id, intent.event_id) or !std.mem.eql(u8, document.event.etag, intent.expected_etag) or !std.ascii.eqlIgnoreCase(document.event.organizer, source.organizer)) return error.CalendarIdentityMismatch;
    var properties = if (j.get(document.value, "extendedProperties")) |value| try j.copyObject(a, value) else j.object(a);
    var private = if (j.get(properties, "private")) |value| try j.copyObject(a, value) else j.object(a);
    try private.object.put(a, "omagmaOperation", .{ .string = intent.operation_id });
    const source_hex = std.fmt.bytesToHex(source.source_hash, .lower);
    try private.object.put(a, "omagmaSource", .{ .string = try a.dupe(u8, &source_hex) });
    try properties.object.put(a, "private", private);
    return withRsvpResponse(a, try preparePatch(a, intent, try j.value(a, .{ .extendedProperties = properties })), source.attendee, response, document);
}

fn hasAttendee(document: EventDocument, attendee: []const u8) bool {
    const attendees = j.get(document.value, "attendees") orelse return false;
    if (attendees != .array) return false;
    var matches: usize = 0;
    for (attendees.array.items) |entry| if (std.ascii.eqlIgnoreCase(j.text(entry, "email"), attendee)) {
        matches += 1;
    };
    return matches == 1;
}

pub fn responseMatches(document: EventDocument, attendee: []const u8, response: RsvpResponse) bool {
    if (!hasAttendee(document, attendee)) return false;
    for (j.get(document.value, "attendees").?.array.items) |entry| if (std.ascii.eqlIgnoreCase(j.text(entry, "email"), attendee)) return std.mem.eql(u8, j.text(entry, "responseStatus"), @tagName(response));
    return false;
}
pub fn decodeDocument(a: std.mem.Allocator, target: t.Target, bytes: []const u8) !EventDocument {
    try target.validate();
    const value = try parseJson(a, bytes);
    const owned_target: t.Target = .{ .account = try a.dupe(u8, target.account), .calendar_id = try a.dupe(u8, target.calendar_id) };
    return .{ .event = try decodeEvent(a, owned_target, value), .value = value };
}

fn decodeEvent(a: std.mem.Allocator, target: t.Target, item: j.Value) !t.Event {
    const status = try field(a, item, "status", 32, false);
    if (!std.mem.eql(u8, status, "confirmed") and !std.mem.eql(u8, status, "tentative") and !std.mem.eql(u8, status, "cancelled")) return error.InvalidCalendarResponse;
    var event: t.Event = .{
        .target = target,
        .id = try field(a, item, "id", 1024, false),
        .uid = try field(a, item, "iCalUID", 1024, true),
        .etag = try field(a, item, "etag", 1024, true),
        .summary = try field(a, item, "summary", 4096, true),
        .event_type = try field(a, item, "eventType", 64, true),
        .location = try field(a, item, "location", 4096, true),
        .recurring_event_id = try field(a, item, "recurringEventId", 1024, true),
        .cancelled = std.mem.eql(u8, status, "cancelled"),
        .locked = try j.boolean(item, "locked", false),
        .private_copy = try j.boolean(item, "privateCopy", false),
        .transparent = std.mem.eql(u8, j.text(item, "transparency"), "transparent"),
    };
    const sequence = try j.integer(item, "sequence", 0);
    if (sequence < 0 or sequence > std.math.maxInt(i32)) return error.InvalidCalendarResponse;
    event.sequence = @intCast(sequence);
    if (j.get(item, "description")) |description| {
        const value = try j.string(description);
        if (value.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidCalendarResponse;
        for (value) |byte| if ((byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') or byte == 127) return error.InvalidCalendarResponse;
        event.description = try a.dupe(u8, value);
    }
    if (j.get(item, "organizer")) |organizer| event.organizer = try field(a, organizer, "email", 512, true);
    if (j.get(item, "start")) |start| event.start = try point(a, start);
    if (j.get(item, "end")) |end| event.end = try point(a, end);
    if (j.get(item, "originalStartTime")) |original| event.original_start = try point(a, original);
    if (!event.cancelled and (event.start == null or event.end == null)) return error.InvalidCalendarResponse;
    if (event.start != null and event.end != null and (event.start.?.kind != event.end.?.kind or event.end.?.value < event.start.?.value)) return error.InvalidCalendarResponse;
    const hangout = try field(a, item, "hangoutLink", 4096, true);
    if (tools.safeUrl(hangout)) event.join_url = hangout;
    const html = try field(a, item, "htmlLink", 4096, true);
    if (tools.safeUrl(html)) event.html_url = html;
    if (j.get(item, "conferenceData")) |conference| {
        event.conference_present = true;
        if (j.get(conference, "createRequest")) |create| if (j.get(create, "status")) |status_value| {
            event.conference_status = try field(a, status_value, "statusCode", 32, true);
        };
    }
    if (j.get(item, "conferenceData")) |conference| if (j.get(conference, "entryPoints")) |points| {
        if (points != .array or points.array.items.len > 32) return error.InvalidCalendarResponse;
        for (points.array.items) |entry| {
            const uri = j.text(entry, "uri");
            if (event.join_url.len == 0 and std.mem.eql(u8, j.text(entry, "entryPointType"), "video") and tools.safeUrl(uri)) event.join_url = try a.dupe(u8, uri);
        }
    };
    // Imported invitations retain their original meeting URL in LOCATION or
    // DESCRIPTION without manufacturing Google conference data. Keep the same
    // Join affordance after refresh, including in bounded agenda snapshots.
    if (event.join_url.len == 0) {
        const location = std.mem.trim(u8, event.location, " \t\r\n");
        if (tools.safeUrl(location)) event.join_url = location else event.join_url = try descriptionJoin(a, event.description);
    }
    if (event.cancelled) event.join_url = "";
    if (j.get(item, "extendedProperties")) |properties| {
        if (j.get(properties, "private")) |private| {
            event.operation_marker = try field(a, private, "omagmaOperation", 128, true);
            event.source_marker = try field(a, private, "omagmaSource", 64, true);
        }
    }
    event.attendees_omitted = try j.boolean(item, "attendeesOmitted", false);
    if (j.get(item, "attendees")) |attendees| {
        if (attendees != .array) return error.InvalidCalendarResponse;
        event.attendee_count = attendees.array.items.len;
        const retained = @min(attendees.array.items.len, 200);
        const emails = try a.alloc([]const u8, retained);
        for (attendees.array.items[0..retained], emails) |attendee, *email| email.* = try field(a, attendee, "email", 512, false);
        event.attendees = emails;
        event.attendees_omitted = event.attendees_omitted or attendees.array.items.len > retained;
        var self_seen = false;
        for (attendees.array.items) |attendee| if (try j.boolean(attendee, "self", false)) {
            if (self_seen) return error.InvalidCalendarResponse;
            self_seen = true;
            const response = j.text(attendee, "responseStatus");
            event.response = if (std.mem.eql(u8, response, "accepted")) .accepted else if (std.mem.eql(u8, response, "tentative")) .tentative else if (std.mem.eql(u8, response, "declined")) .declined else if (std.mem.eql(u8, response, "needsAction")) .needs_action else .unknown;
        };
    }
    return event;
}

fn descriptionJoin(a: std.mem.Allocator, description: []const u8) ![]const u8 {
    if (!meeting_link.htmlDescription(description)) return meeting_link.plain(description);
    // Reuse the reader's inert semantic parser so HTML entities inside hrefs
    // preserve the exact meeting URL. A malformed description has no fallback
    // through raw markup, which could turn &amp; into a different join token.
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const document = @import("html_document.zig").parse(description, scratch.allocator()) catch return "";
    // A notes/support link beside a Join label must not hide a recognized
    // meeting in a later paragraph or table cell.
    for ([_]bool{ true, false }) |known_only| for (document.blocks) |block| {
        const link = spansJoin(block.spans, known_only);
        if (link.len != 0) return a.dupe(u8, link);
        if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| {
            const cell_link = spansJoin(cell.spans, known_only);
            if (cell_link.len != 0) return a.dupe(u8, cell_link);
        };
    };
    return "";
}

fn spansJoin(spans: []const @import("html_document.zig").Span, known_only: bool) []const u8 {
    var join_label = false;
    for (spans) |span| join_label = join_label or std.ascii.findIgnoreCase(span.text, "join") != null;
    for (spans) |span| {
        if (span.link) |link| if (tools.safeUrl(link) and (meeting_link.knownUrl(link) or (!known_only and std.ascii.findIgnoreCase(span.text, "join") != null))) return link;
        const link = if (known_only) meeting_link.plainKnown(span.text) else meeting_link.plain(span.text);
        if (link.len != 0) return link;
    }
    if (!known_only and join_label) for (spans) |span| if (span.link) |link| if (tools.safeUrl(link)) return link;
    return "";
}

fn point(a: std.mem.Allocator, value: j.Value) !time.Point {
    const date = j.get(value, "date");
    const instant = j.get(value, "dateTime");
    if ((date == null) == (instant == null)) return error.InvalidCalendarResponse;
    if (date) |raw| return .{ .kind = .date, .value = @import("timezone.zig").dateDay(try j.string(raw)) catch return error.InvalidCalendarResponse };
    const zone = try field(a, value, "timeZone", 512, true);
    if (zone.len > 0) try time.validateZoneName(zone);
    return .{ .kind = .instant, .value = time.rfc3339(try j.string(instant.?)) catch return error.InvalidCalendarResponse, .zone = zone };
}
const GoogleTime = struct { date: ?[]const u8 = null, dateTime: ?[]const u8 = null, timeZone: ?[]const u8 = null };
fn googleTime(a: std.mem.Allocator, value: time.Point) !GoogleTime {
    const rendered = try time.format(a, value);
    if (value.kind == .date) return .{ .date = rendered };
    return .{ .dateTime = rendered, .timeZone = if (value.zone.len > 0) value.zone else null };
}
fn parseJson(a: std.mem.Allocator, bytes: []const u8) !j.Value {
    if (bytes.len == 0 or bytes.len > t.Limits.response_bytes) return error.CalendarResponseTooLarge;
    try b.preflight(bytes);
    const result = try std.json.parseFromSliceLeaky(j.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = t.Limits.response_bytes });
    if (result != .object) return error.InvalidCalendarResponse;
    return result;
}
fn field(a: std.mem.Allocator, value: j.Value, key: []const u8, maximum: usize, optional: bool) ![]const u8 {
    const raw = j.get(value, key) orelse return if (optional) "" else error.InvalidCalendarResponse;
    const string = try j.string(raw);
    try t.text(string, maximum, optional);
    return a.dupe(u8, string);
}
fn calendarPath(a: std.mem.Allocator, target: t.Target) ![]const u8 {
    try target.validate();
    return std.fmt.allocPrint(a, base_url ++ "/calendars/{s}", .{try encode(a, target.calendar_id)});
}
fn eventPath(a: std.mem.Allocator, target: t.Target, event_id: []const u8) ![]const u8 {
    try t.text(event_id, 1024, false);
    return std.fmt.allocPrint(a, "{s}/events/{s}", .{ try calendarPath(a, target), try encode(a, event_id) });
}
fn tokenSuffix(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    try t.text(value, 4096, true);
    if (value.len == 0) return "";
    return std.fmt.allocPrint(a, "&pageToken={s}", .{try encode(a, value)});
}
fn encode(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    const output = try a.alloc(u8, value.len * 3);
    const hex = "0123456789ABCDEF";
    var len: usize = 0;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            output[len] = byte;
            len += 1;
        } else {
            output[len] = '%';
            output[len + 1] = hex[byte >> 4];
            output[len + 2] = hex[byte & 15];
            len += 3;
        }
    }
    return output[0..len];
}

test "calendar: provider failures distinguish conflicts quotas and read-only POST" {
    try std.testing.expectEqual(Failure.version_conflict, classifyFailure(.update_event, 412, "conditionNotMet"));
    try std.testing.expectEqual(Failure.duplicate, classifyFailure(.import_event, 409, "duplicate"));
    try std.testing.expectEqual(Failure.rate_limited, classifyFailure(.agenda, 403, "userRateLimitExceeded"));
    try std.testing.expectEqual(Failure.unknown, classifyFailure(.import_event, 503, "backendError"));
    try std.testing.expectEqual(Failure.transient, classifyFailure(.free_busy, 503, "backendError"));
}

test "calendar Join: imported conference link survives Calendar document and agenda shaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const account = "self@example.test";
    const target: t.Target = .{ .account = account, .calendar_id = account };
    const raw = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:join-roundtrip@example.test\r\nDTSTAMP:20261013T120000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nDTSTART:20261014T130000Z\r\nDTEND:20261014T140000Z\r\nDESCRIPTION:Planning notes\r\nCONFERENCE:https://meet.example.test/room?token=synthetic!\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const source = try invitation.parse(a, raw, account, &.{});
    const intent: plan.Intent = .{ .operation_id = "import-with-join", .identity = .{ .target = target, .uid = source.uid }, .version = source.version, .kind = .import_event, .source_hash = source.source_hash, .payload_hash = @splat(0) };
    const request = try prepareImport(a, source, intent, null, null);
    var item = try parseJson(a, request.body.?);
    try item.object.put(a, "id", .{ .string = "imported-join" });
    try item.object.put(a, "status", .{ .string = "confirmed" });
    const document = try decodeDocument(a, target, try std.json.Stringify.valueAlloc(a, item, .{}));
    try std.testing.expectEqualStrings(source.join_url, document.event.join_url);
    const page = try decodePage(a, target, try std.json.Stringify.valueAlloc(a, .{ .items = [_]j.Value{item} }, .{}), 0);
    try std.testing.expectEqualStrings(source.join_url, page.events[0].join_url);
    const listed = try agenda(a, target, .{ .start_ms = 1, .end_ms = 86400001, .time_zone = "UTC" }, "");
    try std.testing.expect(std.mem.indexOf(u8, listed.url, "summary,description,location") != null);
}

test "calendar Join: bounded description fallback retains URLs and refuses unrelated or unsafe links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { description: []const u8, expected: []const u8 }{
        .{ .description = "Join: https://meeting.example.test/room?token=fixture!", .expected = "https://meeting.example.test/room?token=fixture!" },
        .{ .description = "Video: https://company.zoom.us/j/12345?pwd=synthetic", .expected = "https://company.zoom.us/j/12345?pwd=synthetic" },
        .{ .description = "https://teams.microsoft.com/l/meetup-join/fixture", .expected = "https://teams.microsoft.com/l/meetup-join/fixture" },
        .{ .description = "<p><a href=\"https://docs.example.test/notes\">Notes</a> <a href=\"https://meeting.example.test/room?a=1&amp;b=2\">Join meeting</a></p>", .expected = "https://meeting.example.test/room?a=1&b=2" },
        .{ .description = "<table><tr><td><a href=\"https://meeting.example.test/room\">Join</a></td></tr></table>", .expected = "https://meeting.example.test/room" },
        .{ .description = "<p><a href=\"https://docs.example.test/notes\">Join notes</a></p><table><tr><td><a href=\"https://teams.microsoft.com/meet/123?p=Ab%2Bcd&amp;context=%7Bfixture%7D\">Jetzt teilnehmen</a></td></tr></table>", .expected = "https://teams.microsoft.com/meet/123?p=Ab%2Bcd&context=%7Bfixture%7D" },
        .{ .description = "Meeting notes: https://docs.example.test/notes", .expected = "" },
        .{ .description = "https://notzoom.us/j/123", .expected = "" },
        .{ .description = "Join: javascript:alert(1)", .expected = "" },
        .{ .description = "Join: https://user:password@meet.example.test/private", .expected = "" },
        .{ .description = "<a href=\"javascript:alert(1)\">Join meeting</a>", .expected = "" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, try descriptionJoin(a, case.description));
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };
    const base = "{\"id\":\"meeting\",\"status\":\"confirmed\",\"start\":{\"date\":\"2026-10-14\"},\"end\":{\"date\":\"2026-10-15\"},\"location\":\"https://meeting.example.test/location\",\"description\":\"Join: https://meeting.example.test/description\"}";
    var item = try parseJson(a, base);
    try std.testing.expectEqualStrings("https://meeting.example.test/location", (try decodeEvent(a, target, item)).join_url);
    try item.object.put(a, "hangoutLink", .{ .string = "https://meet.google.com/provider" });
    try std.testing.expectEqualStrings("https://meet.google.com/provider", (try decodeEvent(a, target, item)).join_url);
    try item.object.put(a, "status", .{ .string = "cancelled" });
    try std.testing.expectEqualStrings("", (try decodeEvent(a, target, item)).join_url);
}

test "meeting Join: Mail and Calendar import retain the same description meeting URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mail = @import("invitation.zig");
    const account = "self@example.test";
    const target: t.Target = .{ .account = account, .calendar_id = account };
    const header = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:description-join@example.test\r\nDTSTAMP:20261014T120000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nDTSTART:20261014T130000Z\r\nDTEND:20261014T140000Z\r\nDESCRIPTION:";
    const footer = "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const cases = [_]struct { description: []const u8, expected: []const u8 }{
        .{ .description = "Jetzt teilnehmen: https://teams.microsoft.com/meet/123?p=Ab%2Bcd&context=%7Bfixture%7D", .expected = "https://teams.microsoft.com/meet/123?p=Ab%2Bcd&context=%7Bfixture%7D" },
        .{ .description = "Besprechung\\nhttps://company.zoom.us/j/123?pwd=fixture", .expected = "https://company.zoom.us/j/123?pwd=fixture" },
        .{ .description = "https://meet.google.com/abc-defg-hij", .expected = "https://meet.google.com/abc-defg-hij" },
        .{ .description = "Join notes https://docs.example.test/notes\\nhttps://teams.cloud.microsoft/meet/123", .expected = "https://teams.cloud.microsoft/meet/123" },
        .{ .description = "Join: https://meeting.example.test/room?token=fixture!", .expected = "https://meeting.example.test/room?token=fixture!" },
        .{ .description = "Meeting notes: https://docs.example.test/notes", .expected = "" },
        .{ .description = "https://teams.microsoft.com/meet/123?p=Ab%2B\r\n cd&context=%7Bfixture%7D", .expected = "https://teams.microsoft.com/meet/123?p=Ab%2Bcd&context=%7Bfixture%7D" },
    };
    for (cases) |case| {
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ header, case.description, footer });
        var preview: mail.Invitation = .{};
        try mail.parseDisplay(raw, account, &.{}, &preview);
        try std.testing.expectEqualStrings(case.expected, preview.join_url.slice());
        const source = try invitation.parse(a, raw, account, &.{});
        try std.testing.expectEqualStrings(case.expected, source.join_url);
        const intent: plan.Intent = .{ .operation_id = "description-join", .identity = .{ .target = target, .uid = source.uid }, .version = source.version, .kind = .import_event, .source_hash = source.source_hash, .payload_hash = @splat(0) };
        const request = try prepareImport(a, source, intent, null, null);
        var item = try parseJson(a, request.body.?);
        try item.object.put(a, "id", .{ .string = "imported-description-join" });
        try item.object.put(a, "status", .{ .string = "confirmed" });
        try std.testing.expectEqualStrings(case.expected, (try decodeEvent(a, target, item)).join_url);
        try item.object.put(a, "status", .{ .string = "cancelled" });
        try std.testing.expectEqualStrings("", (try decodeEvent(a, target, item)).join_url);
        const cancelled_raw = try std.fmt.allocPrint(a, "{s}{s}\r\nSTATUS:CANCELLED{s}", .{ header, case.description, footer });
        try mail.parseDisplay(cancelled_raw, account, &.{}, &preview);
        const zone = try @import("timezone.zig").Zone.fromPosix("UTC0");
        try std.testing.expectEqualStrings("", (try mail.friendly(a, &preview, &zone)).join_url);
    }
    // Explicit ICS meeting properties retain their precedence in both parsers.
    const properties = "\r\nLOCATION:https://location.example.test/room\r\nURL:https://event.example.test/room\r\nCONFERENCE:https://conference.example.test/room?token=fixture!";
    const raw = try std.fmt.allocPrint(a, "{s}https://meet.google.com/abc-defg-hij{s}{s}", .{ header, properties, footer });
    var preview: mail.Invitation = .{};
    try mail.parseDisplay(raw, account, &.{}, &preview);
    try std.testing.expectEqualStrings("https://conference.example.test/room?token=fixture!", preview.join_url.slice());
    try std.testing.expectEqualStrings(preview.join_url.slice(), (try invitation.parse(a, raw, account, &.{})).join_url);
}

test "calendar ordinary: large incoming guest lists remain readable and preserve self response beyond editor limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };
    var item = try j.value(a, .{ .id = "company-meeting", .status = "confirmed", .eventType = "default", .start = .{ .date = "2026-10-22" }, .end = .{ .date = "2026-10-23" } });
    const Guest = struct { email: []const u8, self: bool, responseStatus: []const u8 };
    const guests = try a.alloc(Guest, 250);
    for (guests, 0..) |*guest, index| guest.* = .{ .email = try std.fmt.allocPrint(a, "guest{d}@example.test", .{index}), .self = index == 249, .responseStatus = if (index == 249) "accepted" else "needsAction" };
    try item.object.put(a, "attendees", try j.value(a, guests));
    const event = (try decodeDocument(a, target, try std.json.Stringify.valueAlloc(a, item, .{}))).event;
    try std.testing.expectEqual(@as(usize, 250), event.attendee_count);
    try std.testing.expectEqual(@as(usize, 200), event.attendees.len);
    try std.testing.expect(event.attendees_omitted);
    try std.testing.expectEqual(.accepted, event.response);
    try std.testing.expectEqualStrings("default", event.event_type);
}
