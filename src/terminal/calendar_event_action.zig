//! Reviewed delete and attendee-response (RSVP) actions on existing Calendar
//! events. Eligibility is judged from a fresh strict GET; the exact
//! conditional request (If-Match plus an explicit sendUpdates choice) is bound
//! into a durable review before anything is dispatched. No credentials,
//! network access or writes happen in this module.
//!
//! No undo is offered: Google exposes no restore that Omagma could prove, and
//! a cancellation email that was sent cannot be recalled.
const std = @import("std");
const t = @import("calendar_types.zig");
const p = @import("calendar_provider.zig");
const plan = @import("calendar_plan.zig");
const j = @import("json.zig");
const ordinary = @import("calendar_event.zig");

pub const Action = enum { delete, respond };
/// `event`: the selected event or one occurrence. `series`: every event of the
/// recurring series. "This and following" is deliberately not offered.
pub const Scope = enum { event, series };
pub const Response = enum { accepted, tentative, declined };
/// organizer: this calendar organizes the event. attendee: this calendar is a
/// listed guest. copy: neither (someone else's event shown in this calendar).
pub const Role = enum { organizer, attendee, copy };

/// The reviewed action. Its JSON is the review's hash-bound source bytes.
pub const Prepared = struct {
    action: Action,
    scope: Scope,
    send_updates: ordinary.UpdatePolicy,
    response: ?Response = null,
    role: Role,
    /// This calendar's own attendee entry; the address a response is sent as.
    attendee: []const u8 = "",
    /// The provider's responseStatus before the action (needsAction, …).
    previous_response: []const u8 = "",
    selected_event_id: []const u8,
    selected_etag: []const u8,
    /// The provider event the write addresses: the selection or its series.
    target_event_id: []const u8,
    summary: []const u8 = "",
    start: ?t.time.Point = null,
    end: ?t.time.Point = null,
    /// The selected event is one occurrence of a recurring series.
    recurring: bool = false,
    guest_count: usize = 0,
    guests_omitted: bool = false,
    organizer: []const u8 = "",
};

/// What the caller may choose besides the reviewed request. Never persisted.
pub const Options = struct {
    series: struct {
        available: bool = false,
        reason: []const u8 = "",
        eventId: []const u8 = "",
        etag: []const u8 = "",
        summary: []const u8 = "",
        guestCount: usize = 0,
        response: []const u8 = "",
    } = .{},
    /// delete: email guests a cancellation. respond: email the organizer.
    notify: struct { available: bool = false, reason: []const u8 = "", recipients: []const u8 = "" } = .{},
    thisAndFollowing: struct { available: bool = false, reason: []const u8 = "not_supported" } = .{},
};

pub const Facts = struct {
    role: Role,
    attendee: []const u8 = "",
    response: []const u8 = "",
    guest_count: usize = 0,
    guests_omitted: bool = false,
    organizer: []const u8 = "",
};

pub fn wire(response: Response) []const u8 {
    return @tagName(response);
}

/// A series master carries its recurrence rules; occurrences carry none.
pub fn isSeries(document: p.EventDocument) bool {
    const rules = j.get(document.value, "recurrence") orelse return false;
    return rules != .array or rules.array.items.len != 0;
}

/// Same organizer evidence as the editor: Google's organizer.self marker,
/// else the organizer address equals this calendar (or its primary owner).
pub fn organizes(calendar: t.Calendar, document: p.EventDocument) bool {
    if (j.get(document.value, "organizer")) |organizer| if (j.get(organizer, "self")) |marker| if (marker == .bool) return marker.bool;
    const email = document.event.organizer;
    return email.len != 0 and (std.ascii.eqlIgnoreCase(email, calendar.target.calendar_id) or (calendar.primary and std.ascii.eqlIgnoreCase(email, calendar.target.account)));
}

const SelfAttendee = struct { email: []const u8, response: []const u8 };
/// The single attendee entry Google marks as this calendar's own.
fn selfAttendee(document: p.EventDocument) !?SelfAttendee {
    const attendees = j.get(document.value, "attendees") orelse return null;
    if (attendees != .array) return error.CalendarAttendeeMismatch;
    var found: ?SelfAttendee = null;
    for (attendees.array.items) |entry| if (j.boolean(entry, "self", false) catch false) {
        if (found != null) return error.CalendarAttendeeMismatch;
        found = .{ .email = j.text(entry, "email"), .response = j.text(entry, "responseStatus") };
    };
    return found;
}

/// People other than this calendar and the organizer; rooms are not counted.
fn guestCount(document: p.EventDocument) usize {
    const attendees = j.get(document.value, "attendees") orelse return 0;
    if (attendees != .array) return 0;
    var count: usize = 0;
    for (attendees.array.items) |entry| {
        if (j.boolean(entry, "self", false) catch false) continue;
        if (j.boolean(entry, "organizer", false) catch false) continue;
        if (j.boolean(entry, "resource", false) catch false) continue;
        count += 1;
    }
    return count;
}

fn validEtag(etag: []const u8) bool {
    if (etag.len < 2 or etag[0] != '"' or etag[etag.len - 1] != '"') return false;
    for (etag[1 .. etag.len - 1]) |byte| if (byte < 33 or byte >= 127 or byte == '"') return false;
    return true;
}

/// Refusals shared by both actions. Each is a stable error code with a
/// sentence in error_text.zig and a TUI reason.
fn baseBlocker(document: p.EventDocument) ?anyerror {
    const event = document.event;
    if (event.cancelled) return error.CalendarEventCancelled;
    if (event.locked) return error.CalendarEventLocked;
    if (event.private_copy) return error.CalendarPrivateCopy;
    if (!validEtag(event.etag)) return error.CalendarEventVersionUnavailable;
    const event_type = j.text(document.value, "eventType");
    if (event_type.len != 0 and !std.mem.eql(u8, event_type, "default")) return error.CalendarSpecialEvent;
    return null;
}

/// Whether `action` is possible on this exact fresh document, and the facts
/// a review shows. Calendar ACL and grant checks belong to the service.
pub fn check(action: Action, calendar: t.Calendar, document: p.EventDocument, account: []const u8) !Facts {
    if (baseBlocker(document)) |err| return err;
    const own = organizes(calendar, document);
    const me = try selfAttendee(document);
    var facts: Facts = .{ .role = if (own) .organizer else if (me != null) .attendee else .copy, .organizer = document.event.organizer, .guest_count = guestCount(document), .guests_omitted = document.event.attendees_omitted };
    if (me) |value| {
        facts.attendee = value.email;
        facts.response = value.response;
    }
    if (action == .respond) {
        if (own) return error.CalendarOrganizerCannotRespond;
        const value = me orelse return if (document.event.attendees_omitted) error.CalendarAttendeesOmitted else error.NotAnAttendee;
        if (value.email.len == 0) return error.CalendarAttendeeMismatch;
        // Answering for another person's calendar would be a delegate's
        // decision; only the account itself (or its primary calendar) answers.
        if (!std.ascii.eqlIgnoreCase(value.email, account) and !calendar.primary) return error.CalendarRespondOtherAttendee;
    }
    return facts;
}

/// DELETE with the reviewed ETag. Google refuses it (412) when the event
/// changed after review, so a concurrent edit is never deleted blindly.
pub fn prepareDelete(a: std.mem.Allocator, intent: plan.Intent, send_updates: ordinary.UpdatePolicy) !p.Request {
    try intent.validate();
    if (intent.kind != .cancel_event) return error.InvalidCalendarMutation;
    const bound = try p.get(a, intent.identity.target, intent.event_id);
    return .{ .target = intent.identity.target, .kind = .cancel_event, .method = .DELETE, .url = try std.fmt.allocPrint(a, "{s}?sendUpdates={s}", .{ bound.url, @tagName(send_updates) }), .if_match = intent.expected_etag };
}

/// PATCH only this calendar's own response (Google's documented
/// attendeesOmitted form) plus private receipt markers on this copy. Other
/// guests, the organizer's fields and shared properties are not sent.
pub fn prepareRespond(a: std.mem.Allocator, intent: plan.Intent, document: p.EventDocument, attendee: []const u8, response: Response, send_updates: ordinary.UpdatePolicy) !p.Request {
    try intent.validate();
    if (intent.kind != .update_event) return error.InvalidCalendarMutation;
    if (!document.event.target.eql(intent.identity.target) or !std.mem.eql(u8, document.event.id, intent.event_id) or !std.mem.eql(u8, document.event.etag, intent.expected_etag)) return error.CalendarReviewStale;
    try @import("../bounded.zig").address(attendee);
    var private = if (j.get(document.value, "extendedProperties")) |properties| if (j.get(properties, "private")) |value| try j.copyObject(a, value) else j.object(a) else j.object(a);
    try private.object.put(a, "omagmaOperation", .{ .string = intent.operation_id });
    const hash = std.fmt.bytesToHex(intent.source_hash, .lower);
    try private.object.put(a, "omagmaSource", .{ .string = try a.dupe(u8, &hash) });
    var properties = j.object(a);
    try properties.object.put(a, "private", private);
    const Attendee = struct { email: []const u8, responseStatus: []const u8 };
    const body = try std.json.Stringify.valueAlloc(a, .{ .attendees = [_]Attendee{.{ .email = attendee, .responseStatus = wire(response) }}, .attendeesOmitted = true, .extendedProperties = properties }, .{});
    if (body.len > t.Limits.source_bytes * 2) return error.CalendarTooLarge;
    const bound = try p.get(a, intent.identity.target, intent.event_id);
    return .{ .target = intent.identity.target, .kind = .update_event, .method = .PATCH, .url = try std.fmt.allocPrint(a, "{s}?sendUpdates={s}", .{ bound.url, @tagName(send_updates) }), .body = body, .if_match = intent.expected_etag };
}

/// The provider's responseStatus for exactly one attendee address.
pub fn responseOf(document: p.EventDocument, attendee: []const u8) ?[]const u8 {
    const attendees = j.get(document.value, "attendees") orelse return null;
    if (attendees != .array) return null;
    var found: ?[]const u8 = null;
    for (attendees.array.items) |entry| if (std.ascii.eqlIgnoreCase(j.text(entry, "email"), attendee)) {
        if (found != null) return null;
        found = j.text(entry, "responseStatus");
    };
    return found;
}

/// A response is proven by this operation's private markers on the exact
/// event together with the reviewed response for the reviewed attendee.
pub fn respondProof(document: p.EventDocument, intent: plan.Intent, prepared: Prepared) bool {
    const response = prepared.response orelse return false;
    if (!ordinary.receiptProof(document.event, intent)) return false;
    const current = responseOf(document, prepared.attendee) orelse return false;
    return std.mem.eql(u8, current, wire(response));
}

/// Google reports a deleted event (or occurrence) as cancelled. That is the
/// state the user asked for; a missing (404) event is not treated as proof.
pub fn deleteProof(event: t.Event, intent: plan.Intent) bool {
    return event.target.eql(intent.identity.target) and std.mem.eql(u8, event.id, intent.event_id) and event.cancelled;
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

/// One plain sentence stating exactly what the reviewed action does,
/// including who is (and is not) emailed. Shared by the CLI and the TUI.
pub fn consequence(a: std.mem.Allocator, prepared: Prepared, calendar_name: []const u8) ![]const u8 {
    const what: []const u8 = if (prepared.scope == .series) "every event in this series" else if (prepared.recurring) "this occurrence only" else "this event";
    switch (prepared.action) {
        .delete => {
            const removed: []const u8 = if (prepared.scope == .series) "every event in this series" else if (prepared.recurring) "this occurrence" else "this event";
            if (prepared.role != .organizer) return std.fmt.allocPrint(a, "Removes {s} from {s} only. The organizer's event and other guests are not changed, and no email is sent.{s}", .{ removed, calendar_name, if (prepared.role == .attendee) @as([]const u8, " To tell the organizer you won't attend, decline it instead.") else "" });
            if (prepared.guest_count == 0 and !prepared.guests_omitted) return std.fmt.allocPrint(a, "Deletes {s} from {s}. It has no guests, so no email is sent.", .{ what, calendar_name });
            const guests = if (prepared.guests_omitted) try a.dupe(u8, "its guests") else try std.fmt.allocPrint(a, "{d} guest{s}", .{ prepared.guest_count, plural(prepared.guest_count) });
            if (prepared.send_updates == .all) return std.fmt.allocPrint(a, "Deletes {s} from {s} and emails {s} a cancellation.", .{ what, calendar_name, guests });
            return std.fmt.allocPrint(a, "Deletes {s} from {s} without emailing {s}. Guests outside Google Calendar keep their copy.", .{ what, calendar_name, guests });
        },
        .respond => {
            const answer: []const u8 = if (prepared.response) |response| switch (response) {
                .accepted => "Accepts",
                .tentative => "Answers Maybe to",
                .declined => "Declines",
            } else "Answers";
            const series_note: []const u8 = if (prepared.scope == .series) " Occurrences you answered separately may keep their own answer." else "";
            if (prepared.send_updates == .all) return std.fmt.allocPrint(a, "{s} {s} as {s}. Google emails your answer to the organizer{s}{s}.{s}", .{ answer, what, prepared.attendee, if (prepared.organizer.len > 0) @as([]const u8, " ") else "", prepared.organizer, series_note });
            return std.fmt.allocPrint(a, "{s} {s} as {s}. No email is sent; an organizer using Google Calendar sees your answer there.{s}", .{ answer, what, prepared.attendee, series_note });
        },
    }
}

test "calendar actions: eligibility separates organizer, attendee and copy and refuses unsafe events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "self@example.test" };
    const calendar: t.Calendar = .{ .target = target, .summary = "Personal", .time_zone = "UTC", .access = .owner, .primary = true };
    const base = "\"etag\":\"\\\"v1\\\"\",\"status\":\"confirmed\",\"start\":{\"dateTime\":\"2026-11-12T10:00:00Z\"},\"end\":{\"dateTime\":\"2026-11-12T11:00:00Z\"}";
    const hosted = try p.decodeDocument(a, target, "{\"id\":\"hosted\"," ++ base ++ ",\"organizer\":{\"email\":\"self@example.test\",\"self\":true},\"attendees\":[{\"email\":\"self@example.test\",\"self\":true,\"organizer\":true,\"responseStatus\":\"accepted\"},{\"email\":\"guest@example.test\",\"responseStatus\":\"needsAction\"},{\"email\":\"room@resource.example.test\",\"resource\":true}]}");
    const organizer = try check(.delete, calendar, hosted, target.account);
    try std.testing.expectEqual(Role.organizer, organizer.role);
    try std.testing.expectEqual(@as(usize, 1), organizer.guest_count);
    try std.testing.expectError(error.CalendarOrganizerCannotRespond, check(.respond, calendar, hosted, target.account));
    const invited = try p.decodeDocument(a, target, "{\"id\":\"invited\"," ++ base ++ ",\"organizer\":{\"email\":\"host@example.test\"},\"attendees\":[{\"email\":\"host@example.test\",\"organizer\":true},{\"email\":\"self@example.test\",\"self\":true,\"responseStatus\":\"needsAction\"}]}");
    const attendee = try check(.respond, calendar, invited, target.account);
    try std.testing.expectEqual(Role.attendee, attendee.role);
    try std.testing.expectEqualStrings("needsAction", attendee.response);
    const copy = try p.decodeDocument(a, target, "{\"id\":\"copy\"," ++ base ++ ",\"organizer\":{\"email\":\"host@example.test\"}}");
    try std.testing.expectEqual(Role.copy, (try check(.delete, calendar, copy, target.account)).role);
    try std.testing.expectError(error.NotAnAttendee, check(.respond, calendar, copy, target.account));
    const omitted = try p.decodeDocument(a, target, "{\"id\":\"omitted\"," ++ base ++ ",\"organizer\":{\"email\":\"host@example.test\"},\"attendeesOmitted\":true}");
    try std.testing.expectError(error.CalendarAttendeesOmitted, check(.respond, calendar, omitted, target.account));
    for ([_]struct { extra: []const u8, err: anyerror }{
        .{ .extra = ",\"locked\":true", .err = error.CalendarEventLocked },
        .{ .extra = ",\"privateCopy\":true", .err = error.CalendarPrivateCopy },
        .{ .extra = ",\"eventType\":\"outOfOffice\"", .err = error.CalendarSpecialEvent },
    }) |case| {
        const raw = try std.fmt.allocPrint(a, "{{\"id\":\"blocked\",{s},\"organizer\":{{\"email\":\"self@example.test\",\"self\":true}}{s}}}", .{ base, case.extra });
        const document = try p.decodeDocument(a, target, raw);
        try std.testing.expectError(case.err, check(.delete, calendar, document, target.account));
        try std.testing.expectError(case.err, check(.respond, calendar, document, target.account));
    }
    // Another attendee's calendar copy is not answered for them.
    const shared: t.Calendar = .{ .target = .{ .account = target.account, .calendar_id = "team@group.example.test" }, .summary = "Team", .time_zone = "UTC", .access = .writer };
    const delegate = try p.decodeDocument(a, shared.target, "{\"id\":\"delegate\"," ++ base ++ ",\"organizer\":{\"email\":\"host@example.test\"},\"attendees\":[{\"email\":\"team@group.example.test\",\"self\":true,\"responseStatus\":\"needsAction\"}]}");
    try std.testing.expectError(error.CalendarRespondOtherAttendee, check(.respond, shared, delegate, target.account));
}

test "calendar actions: delete and respond requests are conditional and explicit about notifications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "self@example.test" };
    var intent: plan.Intent = .{ .operation_id = "delete-1", .identity = .{ .target = target, .uid = "event:hosted" }, .version = .{ .sequence = 0, .dtstamp_ms = 0 }, .kind = .cancel_event, .source_hash = @splat(7), .payload_hash = @splat(0), .event_id = "hosted", .expected_etag = "\"v1\"" };
    const deleting = try prepareDelete(a, intent, .all);
    try std.testing.expectEqual(std.http.Method.DELETE, deleting.method);
    try std.testing.expectEqualStrings("\"v1\"", deleting.if_match.?);
    try std.testing.expect(std.mem.endsWith(u8, deleting.url, "/events/hosted?sendUpdates=all"));
    try std.testing.expect(deleting.body == null);
    intent.kind = .update_event;
    intent.event_id = "invited";
    const document = try p.decodeDocument(a, target, "{\"id\":\"invited\",\"etag\":\"\\\"v1\\\"\",\"status\":\"confirmed\",\"start\":{\"date\":\"2026-11-12\"},\"end\":{\"date\":\"2026-11-13\"},\"organizer\":{\"email\":\"host@example.test\"},\"attendees\":[{\"email\":\"self@example.test\",\"self\":true,\"responseStatus\":\"needsAction\"},{\"email\":\"other@example.test\",\"responseStatus\":\"accepted\"}],\"extendedProperties\":{\"private\":{\"kept\":\"yes\"},\"shared\":{\"organizerOwned\":\"yes\"}}}");
    const answering = try prepareRespond(a, intent, document, "self@example.test", .declined, .none);
    try std.testing.expectEqual(std.http.Method.PATCH, answering.method);
    try std.testing.expect(std.mem.endsWith(u8, answering.url, "/events/invited?sendUpdates=none"));
    const body = try std.json.parseFromSliceLeaky(j.Value, a, answering.body.?, .{});
    const attendees = j.get(body, "attendees").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), attendees.len);
    try std.testing.expectEqualStrings("declined", j.text(attendees[0], "responseStatus"));
    try std.testing.expect(try j.boolean(body, "attendeesOmitted", false));
    const properties = j.get(body, "extendedProperties").?;
    try std.testing.expect(j.get(properties, "shared") == null);
    try std.testing.expectEqualStrings("yes", j.text(j.get(properties, "private").?, "kept"));
    try std.testing.expectEqualStrings("delete-1", j.text(j.get(properties, "private").?, "omagmaOperation"));
    for ([_][]const u8{ "summary", "start", "end", "description", "location" }) |field| try std.testing.expect(j.get(body, field) == null);
    var stale = intent;
    stale.expected_etag = "\"v0\"";
    try std.testing.expectError(error.CalendarReviewStale, prepareRespond(a, stale, document, "self@example.test", .accepted, .all));
    try std.testing.expectError(error.InvalidCalendarMutation, prepareDelete(a, intent, .none));
}

test "calendar actions: consequences name who is and is not emailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prepared: Prepared = .{ .action = .delete, .scope = .event, .send_updates = .all, .role = .organizer, .selected_event_id = "e", .selected_etag = "\"1\"", .target_event_id = "e", .guest_count = 3 };
    try std.testing.expectEqualStrings("Deletes this event from Work and emails 3 guests a cancellation.", try consequence(a, prepared, "Work"));
    prepared.send_updates = .none;
    try std.testing.expect(std.mem.indexOf(u8, try consequence(a, prepared, "Work"), "without emailing 3 guests") != null);
    prepared.role = .attendee;
    try std.testing.expect(std.mem.indexOf(u8, try consequence(a, prepared, "Work"), "decline it instead") != null);
    prepared.role = .organizer;
    prepared.guest_count = 0;
    prepared.scope = .series;
    try std.testing.expectEqualStrings("Deletes every event in this series from Work. It has no guests, so no email is sent.", try consequence(a, prepared, "Work"));
    prepared = .{ .action = .respond, .scope = .event, .send_updates = .all, .response = .declined, .role = .attendee, .attendee = "self@example.test", .organizer = "host@example.test", .recurring = true, .selected_event_id = "e", .selected_etag = "\"1\"", .target_event_id = "e" };
    try std.testing.expectEqualStrings("Declines this occurrence only as self@example.test. Google emails your answer to the organizer host@example.test.", try consequence(a, prepared, "Work"));
}
