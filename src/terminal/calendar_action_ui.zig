//! Delete and RSVP dialogs for one Calendar event: bounded state, choices
//! and wording. The TUI starts the read-only plan, the exact review and the
//! apply jobs; nothing here performs I/O. A write needs an explicit choice
//! and a separate confirmation: no single key from the Calendar view sends.
const std = @import("std");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const ui = @import("calendar_ui.zig");
const action = @import("calendar_event_action.zig");

pub const Kind = enum { delete, respond };
pub const Phase = enum {
    /// The read-only plan (a dry-run review) is loading.
    loading,
    /// The action is unavailable here; `message` says why and what instead.
    blocked,
    /// Choose; `y` or the confirm button reviews and applies exactly that.
    choose,
    /// The exact review, then its single apply, are in flight.
    working,
    /// The outcome is unconfirmed: r checks Calendar with reads only.
    unknown,
    /// Separate confirmations for an identical retry or archiving.
    confirm_retry,
    confirm_archive,
    /// Calendar refused it: nothing changed.
    refused,
};
pub const Control = enum(u8) { scope_event, scope_series, notify_yes, notify_no, accept, maybe, decline, cancel, confirm, check, retry, archive, browser, permissions };
/// Mouse/hit indices of dialog controls start here (Calendar activate).
pub const hit_base: usize = 40;

pub const Dialog = struct {
    open: bool = false,
    kind: Kind = .delete,
    phase: Phase = .loading,
    account: b.Text(254) = .{},
    calendar_id: b.Text(1024) = .{},
    event_id: b.Text(1024) = .{},
    /// Shown while the plan loads; replaced by the plan's own summary.
    title: b.Text(512) = .{},
    when: b.Text(256) = .{},
    /// The focus whose row the content was last scrolled to; Ctrl+D/U
    /// scroll freely until the focus moves again.
    scrolled_focus: ?Control = null,
    /// The dry-run review: role, guests, current answer, series and options.
    plan: ui.Document = .{},
    series: bool = false,
    /// delete: email guests (null until chosen when there are guests).
    /// respond: email the organizer (on by default, shown on the button).
    notify: ?bool = null,
    response: ?action.Response = null,
    focus: ?Control = null,
    scroll: usize = 0,
    operation: b.Text(128) = .{},
    hash: b.Text(64) = .{},
    next_attempt: u32 = 0,
    retry_possible: bool = false,
    /// The blocked/refused reason or a working/unknown status sentence.
    message: b.Text(512) = .{},
    error_code: b.Text(128) = .{},
    /// Blocked by missing Calendar write permission: Enter shows the guide.
    permission: bool = false,
    /// `plan` is a saved review (an unconfirmed write being resumed), whose
    /// top-level facts are already those of its own scope.
    restored: bool = false,
    /// The TUI's frame counter (advanced before every frame) and the last
    /// frame that drew the event's identity, the consequence and the confirm
    /// button together. A confirm acts only on a dialog the user can see.
    frame: u64 = 0,
    visible_frame: u64 = 0,
    /// The step (phase and scope) shown, and when a confirm for it is
    /// accepted: a moment after it became visible, so a double click or a
    /// key typed ahead never confirms a new step.
    drawn: ?Shown = null,
    armed_at_ms: i64 = std.math.maxInt(i64),

    pub const Shown = struct { phase: Phase, series: bool };
    /// The settle interval after a step becomes visible.
    pub const settle_ms: i64 = 600;

    pub fn close(self: *Dialog) void {
        self.plan.deinit();
        const frame = self.frame;
        self.* = .{};
        self.frame = frame;
    }
    /// Called by every frame that drew the dialog with `visible` true when
    /// the identity, the consequence and the confirm button were all on
    /// screen. A step that was not visible in the previous frame (new
    /// phase or scope, or hidden, scrolled away or too small before) arms
    /// only after the settle time.
    pub fn markDrawn(self: *Dialog, now_ms: i64, visible: bool) void {
        if (!visible) return;
        const shown: Shown = .{ .phase = self.phase, .series = self.series };
        const continuous = self.drawn != null and std.meta.eql(self.drawn.?, shown) and self.visible_frame +% 1 == self.frame;
        if (!continuous) {
            self.drawn = shown;
            self.armed_at_ms = now_ms +| settle_ms;
        }
        self.visible_frame = self.frame;
    }
    pub const Readiness = enum { ready, hidden, settling };
    /// Whether a confirm (y, Enter or a click) may act now.
    pub fn readiness(self: *const Dialog, now_ms: i64) Readiness {
        const shown = self.drawn orelse return .hidden;
        if (self.visible_frame != self.frame or !std.meta.eql(shown, Shown{ .phase = self.phase, .series = self.series })) return .hidden;
        if (now_ms < self.armed_at_ms) return .settling;
        return .ready;
    }
    pub fn begin(self: *Dialog, kind: Kind, account: []const u8, calendar_id: []const u8, event_id: []const u8, title: []const u8, when: []const u8) !void {
        self.close();
        self.open = true;
        self.kind = kind;
        try self.account.set(account);
        try self.calendar_id.set(calendar_id);
        try self.event_id.set(event_id);
        self.title.display(title);
        self.when.display(when);
        self.focus = .cancel;
    }
    /// A fresh plan resets the choices: recurring defaults to this event
    /// only, a delete with guests waits for an explicit email choice and an
    /// answer starts unchosen.
    pub fn setPlan(self: *Dialog, a: std.mem.Allocator, value: j.Value) !void {
        try self.plan.replace(a, value);
        self.restored = false;
        self.series = false;
        self.response = null;
        self.notify = if (self.kind == .respond) true else if (self.needsNotifyChoice()) null else false;
        self.phase = .choose;
        self.scroll = 0;
        // As in Mail's Trash dialog, Enter on an untouched delete cancels.
        self.focus = if (self.kind == .respond) .accept else if (self.needsNotifyChoice()) .notify_yes else .cancel;
        self.message = .{};
    }
    /// A saved (pending) review restores exactly what was chosen then.
    pub fn restore(self: *Dialog, a: std.mem.Allocator, review: j.Value) !void {
        try self.plan.replace(a, review);
        self.restored = true;
        self.series = std.mem.eql(u8, j.text(review, "scope"), "series");
        self.notify = std.mem.eql(u8, j.text(review, "sendUpdates"), "all");
        self.response = std.meta.stringToEnum(action.Response, j.text(review, "response"));
        try self.operation.set(j.text(review, "operationId"));
        try self.hash.set(j.text(review, "reviewHash"));
    }

    /// The facts shown and confirmed are those of the event the chosen scope
    /// writes: the selected event, or the series read from the series itself
    /// (an occurrence can have its own guests, answer, title and time).
    /// A saved review (restore) already holds its own scope's facts.
    fn facts(self: *const Dialog) j.Value {
        if (self.series and !self.restored) return self.option("series");
        return self.plan.value;
    }
    pub fn role(self: *const Dialog) []const u8 {
        return j.text(self.facts(), "role");
    }
    pub fn guestCount(self: *const Dialog) usize {
        return @intCast(@max(0, j.integer(self.facts(), "guestCount", 0) catch 0));
    }
    pub fn guestsOmitted(self: *const Dialog) bool {
        return j.boolean(self.facts(), "guestsOmitted", false) catch false;
    }
    pub fn recurring(self: *const Dialog) bool {
        return j.boolean(self.plan.value, "recurring", false) catch false;
    }
    fn option(self: *const Dialog, name: []const u8) j.Value {
        return j.get(j.get(self.plan.value, "options") orelse .null, name) orelse .null;
    }
    pub fn seriesAvailable(self: *const Dialog) bool {
        return j.boolean(self.option("series"), "available", false) catch false;
    }
    pub fn seriesEtag(self: *const Dialog) []const u8 {
        return j.text(self.option("series"), "etag");
    }
    pub fn seriesReason(self: *const Dialog) []const u8 {
        return j.text(self.option("series"), "reason");
    }
    /// Only an organizer deleting an event with guests chooses whether
    /// Google emails them; nobody else can be notified by a delete.
    pub fn needsNotifyChoice(self: *const Dialog) bool {
        return self.kind == .delete and std.mem.eql(u8, self.role(), "organizer") and (self.guestCount() > 0 or self.guestsOmitted());
    }
    pub fn previousResponse(self: *const Dialog) []const u8 {
        return j.text(self.facts(), if (self.series and !self.restored) "response" else "previousResponse");
    }
    pub fn attendee(self: *const Dialog) []const u8 {
        return j.text(self.facts(), "attendee");
    }
    pub fn organizer(self: *const Dialog) []const u8 {
        return j.text(self.facts(), "organizer");
    }
    /// The start/end (and, for a series, how it repeats) of what is written.
    pub fn timing(self: *const Dialog) j.Value {
        return self.facts();
    }
    pub fn recurrence(self: *const Dialog) []const u8 {
        return if (self.series) j.text(self.facts(), "recurrence") else "";
    }
    pub fn ownCalendar(self: *const Dialog) bool {
        return j.boolean(self.plan.value, "ownCalendar", true) catch true;
    }
    pub fn calendarName(self: *const Dialog) []const u8 {
        return j.text(self.plan.value, "calendarName");
    }
    /// The event the chosen scope writes and the version it must still have.
    pub fn targetEventId(self: *const Dialog) []const u8 {
        if (self.series and !self.restored) return j.text(self.option("series"), "eventId");
        return j.text(self.plan.value, "targetEventId");
    }
    pub fn targetEtag(self: *const Dialog) []const u8 {
        if (self.restored) return j.text(self.plan.value, "targetEtag");
        return if (self.series) self.seriesEtag() else j.text(self.plan.value, "expectedEtag");
    }

    pub fn prepared(self: *const Dialog) action.Prepared {
        const value = self.plan.value;
        return .{
            .action = if (self.kind == .delete) .delete else .respond,
            .scope = if (self.series) .series else .event,
            .send_updates = if (self.notify orelse false) .all else .none,
            .response = self.response,
            .role = std.meta.stringToEnum(action.Role, self.role()) orelse .copy,
            .attendee = self.attendee(),
            .previous_response = self.previousResponse(),
            .selected_event_id = j.text(value, "eventId"),
            .selected_etag = j.text(value, "expectedEtag"),
            .target_event_id = self.targetEventId(),
            .summary = self.title_text(),
            .recurring = self.recurring(),
            .guest_count = self.guestCount(),
            .guests_omitted = self.guestsOmitted(),
            .organizer = self.organizer(),
            .own_calendar = self.ownCalendar(),
        };
    }
    pub fn consequence(self: *const Dialog, a: std.mem.Allocator) ![]const u8 {
        return action.consequence(a, self.prepared(), self.calendarName());
    }

    /// Why the confirm button is not available yet, or null.
    pub fn blocker(self: *const Dialog) ?[]const u8 {
        if (self.phase != .choose) return "";
        if (self.series and !self.seriesAvailable()) return "All events in the series is unavailable here";
        switch (self.kind) {
            .delete => if (self.notify == null) return "Choose whether Google emails the guests a cancellation",
            .respond => {
                const response = self.response orelse return "Choose Accept, Maybe or Decline";
                if (std.mem.eql(u8, self.previousResponse(), action.wire(response))) return if (self.series) "That is already the series' answer · choose another" else "That is already your answer · choose another";
            },
        }
        return null;
    }
    pub fn canConfirm(self: *const Dialog) bool {
        return self.blocker() == null;
    }
    /// The confirm button names exactly what y sends. Narrow dialogs use a
    /// shorter label; the consequence sentence above it gives the details.
    pub fn confirmLabel(self: *const Dialog, a: std.mem.Allocator, narrow: bool) ![]const u8 {
        const guests = self.guestCount();
        const series: []const u8 = if (self.series) " series" else "";
        return switch (self.kind) {
            .delete => if (!std.mem.eql(u8, self.role(), "organizer"))
                (if (narrow) try std.fmt.allocPrint(a, "[y Remove{s}]", .{series}) else try std.fmt.allocPrint(a, "[y Remove{s} from {s} calendar]", .{ series, if (self.ownCalendar()) @as([]const u8, "my") else "this" }))
            else if (!self.needsNotifyChoice())
                (if (self.series) @as([]const u8, "[y Delete series]") else if (narrow) "[y Delete]" else "[y Delete event]")
            else if (self.notify) |notify| (if (notify)
                (if (narrow or self.guestsOmitted()) try std.fmt.allocPrint(a, "[y Delete{s} & email{s}]", .{ series, if (narrow) @as([]const u8, "") else " guests" }) else try std.fmt.allocPrint(a, "[y Delete{s} & email {d} guest{s}]", .{ series, guests, if (guests == 1) @as([]const u8, "") else "s" }))
            else
                try std.fmt.allocPrint(a, "[y Delete{s}, no email]", .{series})) else "[y Delete…]",
            .respond => if (self.response) |response| try std.fmt.allocPrint(a, "[y {s}{s}{s}]", .{ responseVerb(response), series, if (self.notify orelse false) (if (narrow) @as([]const u8, " · email") else " · email organizer") else " · no email" }) else "[y Send answer]",
        };
    }

    /// Focusable controls in drawing order for the current phase.
    pub fn controls(self: *const Dialog, buffer: *[14]Control) []const Control {
        var count: usize = 0;
        const add = struct {
            fn one(list: *[14]Control, n: *usize, control: Control) void {
                list[n.*] = control;
                n.* += 1;
            }
        }.one;
        switch (self.phase) {
            .choose => {
                if (self.kind == .respond) for ([_]Control{ .accept, .maybe, .decline }) |control| add(buffer, &count, control);
                if (self.recurring()) {
                    add(buffer, &count, .scope_event);
                    if (self.seriesAvailable()) add(buffer, &count, .scope_series);
                }
                if (self.kind == .respond or self.needsNotifyChoice()) {
                    add(buffer, &count, .notify_yes);
                    if (self.kind == .delete) add(buffer, &count, .notify_no);
                }
                add(buffer, &count, .cancel);
                add(buffer, &count, .confirm);
            },
            .unknown => {
                add(buffer, &count, .cancel);
                add(buffer, &count, .check);
                if (self.retry_possible) add(buffer, &count, .retry);
                add(buffer, &count, .archive);
                add(buffer, &count, .browser);
            },
            .confirm_retry, .confirm_archive => {
                add(buffer, &count, .cancel);
                add(buffer, &count, .confirm);
            },
            .blocked, .refused => {
                add(buffer, &count, .cancel);
                if (self.permission) add(buffer, &count, .permissions) else add(buffer, &count, .browser);
            },
            .loading, .working => add(buffer, &count, .cancel),
        }
        return buffer[0..count];
    }
    pub fn moveFocus(self: *Dialog, back: bool) void {
        var buffer: [14]Control = undefined;
        const list = self.controls(&buffer);
        if (list.len == 0) return;
        var index: usize = 0;
        for (list, 0..) |control, i| if (self.focus == control) {
            index = i;
        };
        const present = for (list) |control| {
            if (self.focus == control) break true;
        } else false;
        self.focus = if (!present) (if (back) list[list.len - 1] else list[0]) else list[(index + if (back) list.len - 1 else 1) % list.len];
    }
    /// Select a radio choice. Selecting never sends; the confirm does.
    pub fn choose(self: *Dialog, control: Control) void {
        switch (control) {
            .scope_event, .scope_series => {
                const series = control == .scope_series;
                if (series != self.series and (!series or self.seriesAvailable())) {
                    self.series = series;
                    // The series and the occurrence can have different
                    // guests: ask again whom Google emails.
                    if (self.kind == .delete) self.notify = if (self.needsNotifyChoice()) null else false;
                }
            },
            .notify_yes => self.notify = if (self.kind == .respond) !(self.notify orelse false) else true,
            .notify_no => self.notify = false,
            .accept => self.response = .accepted,
            .maybe => self.response = .tentative,
            .decline => self.response = .declined,
            else => return,
        }
        self.focus = control;
    }
    pub fn selected(self: *const Dialog, control: Control) bool {
        return switch (control) {
            .scope_event => !self.series,
            .scope_series => self.series,
            .notify_yes => self.notify orelse false,
            .notify_no => if (self.notify) |value| !value else false,
            .accept => self.response == .accepted,
            .maybe => self.response == .tentative,
            .decline => self.response == .declined,
            else => false,
        };
    }

    pub fn planRequest(self: *const Dialog, a: std.mem.Allocator, operation_id: []const u8) !j.Value {
        return j.value(a, .{ .cmd = self.reviewCommand(), .account = self.account.slice(), .calendarId = self.calendar_id.slice(), .eventId = self.event_id.slice(), .scope = "event", .sendUpdates = "none", .operationId = operation_id, .dryRun = true });
    }
    /// The exact review: the plan's own ETag binds what the user saw.
    pub fn reviewRequest(self: *const Dialog, a: std.mem.Allocator, operation_id: []const u8) !j.Value {
        return j.value(a, .{
            .cmd = self.reviewCommand(),
            .account = self.account.slice(),
            .calendarId = self.calendar_id.slice(),
            .eventId = j.text(self.plan.value, "eventId"),
            .expectedEtag = j.text(self.plan.value, "expectedEtag"),
            .scope = if (self.series) @as([]const u8, "series") else "event",
            .sendUpdates = if (self.notify orelse false) @as([]const u8, "all") else "none",
            .response = if (self.response) |response| @as(?[]const u8, action.wire(response)) else null,
            .operationId = operation_id,
        });
    }
    pub fn executeRequest(self: *const Dialog, a: std.mem.Allocator, command: []const u8, next_attempt: ?u32) !j.Value {
        return j.value(a, .{ .cmd = command, .account = self.account.slice(), .calendarId = self.calendar_id.slice(), .operationId = self.operation.slice(), .reviewHash = self.hash.slice(), .nextAttempt = next_attempt });
    }
    pub fn reviewCommand(self: *const Dialog) []const u8 {
        return if (self.kind == .delete) "calendar.event-delete-review" else "calendar.event-respond-review";
    }
    /// What differs between the saved review and what the dialog showed, or
    /// null. Apply follows only a review that matches everything shown: the
    /// event and series version, role, guests, answer, scope and email.
    pub fn reviewMismatch(self: *const Dialog, a: std.mem.Allocator, review: j.Value) ?[]const u8 {
        const value = self.plan.value;
        const shown = self.prepared();
        if (!std.mem.eql(u8, j.text(review, "eventId"), j.text(value, "eventId"))) return "eventId";
        if (!std.mem.eql(u8, j.text(review, "scope"), @tagName(shown.scope))) return "scope";
        if (!std.mem.eql(u8, j.text(review, "sendUpdates"), @tagName(shown.send_updates))) return "sendUpdates";
        const answer: []const u8 = if (shown.response) |response| action.wire(response) else "";
        if (!std.mem.eql(u8, j.text(review, "response"), answer)) return "response";
        if (!std.mem.eql(u8, j.text(review, "targetEventId"), shown.target_event_id)) return "targetEventId";
        if (!std.mem.eql(u8, j.text(review, "targetEtag"), self.targetEtag())) return "targetEtag";
        if (!std.mem.eql(u8, j.text(review, "role"), self.role())) return "role";
        if ((j.integer(review, "guestCount", -1) catch -1) != @as(i64, @intCast(shown.guest_count))) return "guestCount";
        if ((j.boolean(review, "guestsOmitted", false) catch true) != shown.guests_omitted) return "guestsOmitted";
        if (!std.mem.eql(u8, j.text(review, "previousResponse"), shown.previous_response)) return "previousResponse";
        const said = self.consequence(a) catch return "consequence";
        if (!std.mem.eql(u8, j.text(review, "consequence"), said)) return "consequence";
        return null;
    }
    pub fn title_text(self: *const Dialog) []const u8 {
        const summary = j.text(self.facts(), "summary");
        return if (summary.len > 0) summary else if (self.title.len > 0) self.title.slice() else "Untitled event";
    }
    pub fn heading(self: *const Dialog) []const u8 {
        return switch (self.kind) {
            .delete => if (std.mem.eql(u8, self.role(), "organizer") or self.plan.value == .null) " Delete event? " else if (self.ownCalendar()) " Remove from your calendar? " else " Remove from this calendar? ",
            .respond => " Your answer ",
        };
    }
    pub fn roleText(self: *const Dialog, a: std.mem.Allocator) ![]const u8 {
        const organizer_email = self.organizer();
        const guests = self.guestCount();
        const role_name = self.role();
        if (std.mem.eql(u8, role_name, "organizer")) {
            // On a shared or delegated calendar, that calendar organizes it.
            const who = if (self.ownCalendar()) "You organize it" else try std.fmt.allocPrint(a, "{s} organizes it", .{if (self.calendarName().len > 0) self.calendarName() else "This calendar"});
            if (self.guestsOmitted()) return std.fmt.allocPrint(a, "{s} · guests not all listed", .{who});
            if (guests == 0) return std.fmt.allocPrint(a, "{s} · no guests", .{who});
            return std.fmt.allocPrint(a, "{s} · {d} guest{s}", .{ who, guests, if (guests == 1) @as([]const u8, "") else "s" });
        }
        if (std.mem.eql(u8, role_name, "attendee")) return std.fmt.allocPrint(a, "Invited by {s}", .{if (organizer_email.len > 0) organizer_email else "the organizer"});
        return std.fmt.allocPrint(a, "Organized by {s} · a copy in this calendar", .{if (organizer_email.len > 0) organizer_email else "someone else"});
    }
};

pub fn responseVerb(response: action.Response) []const u8 {
    return switch (response) {
        .accepted => "Accept",
        .tentative => "Maybe",
        .declined => "Decline",
    };
}
pub fn responseDone(response: action.Response) []const u8 {
    return switch (response) {
        .accepted => "Accepted",
        .tentative => "Answered Maybe",
        .declined => "Declined",
    };
}
/// The agenda's response tag for an answer (calendar_types.Event.response).
pub fn responseTag(response: action.Response) []const u8 {
    return switch (response) {
        .accepted => "accepted",
        .tentative => "tentative",
        .declined => "declined",
    };
}
/// Provider wording (needsAction, accepted, …) as the card shows it.
pub fn currentAnswer(raw: []const u8) []const u8 {
    if (raw.len == 0 or std.mem.eql(u8, raw, "needsAction")) return "Not answered";
    if (std.mem.eql(u8, raw, "accepted")) return "Accepted";
    if (std.mem.eql(u8, raw, "tentative")) return "Maybe";
    if (std.mem.eql(u8, raw, "declined")) return "Declined";
    return raw;
}

/// Refusals of a chosen combination: the dialog shows the reason, then the
/// event's current facts to choose again. Nothing was sent.
pub fn choosesAgain(code: []const u8) bool {
    for ([_][]const u8{ "CalendarNotificationUnavailable", "CalendarResponseUnchanged", "CalendarResponseRequired", "CalendarNotRecurring", "CalendarSeriesScopeRequired" }) |name| if (std.mem.eql(u8, code, name)) return true;
    return false;
}
/// Why a plan or review was refused, in words, with what to do instead;
/// null for a code without its own sentence (the caller words it).
pub fn reasonText(kind: Kind, code: []const u8) ?[]const u8 {
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "CalendarNotificationUnavailable", "Nobody can be emailed about this now (no guests to notify) · nothing was sent · choose again" },
        .{ "CalendarResponseRequired", "Choose Accept, Maybe or Decline · nothing was sent" },
        .{ "CalendarRetryUnavailable", "Calendar no longer shows the saved version unchanged, so the identical request is not sent again · r checks again" },
        .{ "CalendarReviewMismatch", "The saved review no longer matches this dialog · nothing was sent · open it again" },
        .{ "OperationConflict", "The saved review no longer matches this dialog · nothing was sent · open it again" },
        .{ "CalendarOperationNotFound", "No saved change was found for this dialog · nothing was sent" },
        .{ "CalendarReviewNotFound", "No saved change was found for this dialog · nothing was sent" },
        .{ "CalendarWritePermissionRequired", "This account has not allowed Omagma to change Calendar · Enter shows how to enable it" },
        .{ "CalendarPermissionRequired", "This account has not allowed Omagma to change Calendar · Enter shows how to enable it" },
        .{ "CalendarReadOnly", "This calendar is read-only for you · b opens the event in Google Calendar" },
        .{ "CalendarEventLocked", "Google has locked this event · b opens it in Google Calendar" },
        .{ "CalendarSpecialEvent", "Focus time, out of office, working location, birthdays and events from Gmail are changed in Google Calendar · b opens it" },
        .{ "CalendarEventCancelled", "This event is already cancelled · Ctrl+R refreshes Calendar" },
        .{ "CalendarOrganizerCannotRespond", "You organize this event, so there is no answer to send · D deletes it, e edits it" },
        .{ "NotAnAttendee", "This calendar is not on the event's guest list, so there is nothing to answer · D removes it from this calendar" },
        .{ "CalendarAttendeesOmitted", "Google left out this event's guest list, so your invitation cannot be checked · b answers in Google Calendar" },
        .{ "CalendarRespondOtherAttendee", "This invitation is for another person's calendar · answer from that account, or b opens Google Calendar" },
        .{ "CalendarAttendeeMismatch", "Your guest entry is ambiguous · b answers in Google Calendar" },
        .{ "CalendarEventVersionUnavailable", "Google did not give this event a version · Ctrl+R refreshes Calendar first" },
        .{ "CalendarNotFound", "This event is no longer in Calendar · Ctrl+R refreshes" },
        .{ "CalendarReviewStale", "The event changed in Calendar since you opened this · nothing was changed" },
        .{ "CalendarOperationPending", "An earlier change to this event is still unconfirmed" },
        .{ "CalendarSeriesScopeRequired", "This is a whole series · choose one of its events" },
        .{ "CalendarNotRecurring", "This event no longer repeats · nothing was sent · choose again" },
        .{ "CalendarResponseUnchanged", "That is already the answer in Calendar · nothing was sent · choose another" },
    };
    if (std.mem.eql(u8, code, "CalendarPrivateCopy")) return if (kind == .respond) "This is a private copy of an invitation · answer it from the invitation email in Mail (I)" else "This is a private copy of an invitation · b opens it in Google Calendar";
    for (pairs) |pair| if (std.mem.eql(u8, code, pair[0])) return pair[1];
    if (@import("calendar_text.zig").offline(code)) return "Calendar is unreachable · nothing was changed · try again when online";
    return null;
}
/// An unconfirmed outcome, from the read-only check's recovery reason.
pub fn recoveryText(kind: Kind, reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "SavedVersionStillCurrent")) return if (kind == .delete) "Calendar still shows the event unchanged · Ctrl+R sends the identical delete once more" else "Calendar still shows your previous answer · Ctrl+R sends the identical answer once more";
    if (std.mem.eql(u8, reason, "EventNotVisible")) return "Calendar no longer shows this event but cannot confirm the change · b checks Google Calendar";
    if (std.mem.eql(u8, reason, "EventChangedWithoutReceipt")) return "The event changed elsewhere; this change is unconfirmed · b checks Google Calendar";
    if (std.mem.eql(u8, reason, "EventDeletedWithoutReceipt")) return "The event was deleted; your answer is unconfirmed";
    return "Calendar did not confirm the outcome · r checks Calendar (reads only, sends nothing)";
}
/// A known refusal: Calendar changed nothing.
pub fn refusedText(kind: Kind, code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "CalendarVersionConflict")) return "Not changed · the event was changed in Calendar after you opened it · reopen it to see the current version";
    if (std.mem.eql(u8, code, "CalendarFullRefreshRequired")) return if (kind == .delete) "Already deleted in Calendar · nothing changed" else "The event was deleted in Calendar · nothing changed";
    if (std.mem.eql(u8, code, "CalendarNotFound")) return "The event no longer exists in Calendar · nothing changed";
    if (std.mem.eql(u8, code, "CalendarForbidden")) return "Calendar refused the change (no permission) · nothing changed";
    return "Calendar refused the change · nothing changed";
}

test "calendar action UI: a delete with guests needs an explicit email choice before confirming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dialog: Dialog = .{};
    defer dialog.close();
    try dialog.begin(.delete, "self@example.test", "self@example.test", "hosted", "Roadmap review", "Tue 13 Oct 11:00–12:00");
    try dialog.setPlan(std.testing.allocator, try j.value(a, .{ .role = "organizer", .guestCount = 2, .previousResponse = "accepted", .recurring = true, .summary = "Roadmap review", .calendarName = "Personal", .eventId = "hosted_1", .expectedEtag = "\"1\"", .targetEventId = "hosted_1", .options = .{ .series = .{ .available = true, .eventId = "hosted", .etag = "\"9\"", .summary = "Standup", .role = "organizer", .guestCount = 1, .response = "accepted" } } }));
    try std.testing.expectEqual(Control.notify_yes, dialog.focus.?);
    try std.testing.expect(!dialog.canConfirm());
    try std.testing.expectEqualStrings("[y Delete…]", try dialog.confirmLabel(a, false));
    var buffer: [14]Control = undefined;
    try std.testing.expectEqualSlices(Control, &.{ .scope_event, .scope_series, .notify_yes, .notify_no, .cancel, .confirm }, dialog.controls(&buffer));
    dialog.choose(.notify_yes);
    try std.testing.expect(dialog.canConfirm());
    try std.testing.expectEqualStrings("[y Delete & email 2 guests]", try dialog.confirmLabel(a, false));
    try std.testing.expectEqualStrings("[y Delete & email]", try dialog.confirmLabel(a, true));
    try std.testing.expectEqualStrings("Deletes this occurrence only from Personal and emails 2 guests a cancellation.", try dialog.consequence(a));
    // The series shows its own facts (one guest) and asks again about email.
    dialog.choose(.scope_series);
    try std.testing.expect(dialog.notify == null and !dialog.canConfirm());
    try std.testing.expectEqualStrings("Standup", dialog.title_text());
    try std.testing.expectEqual(@as(usize, 1), dialog.guestCount());
    dialog.choose(.notify_no);
    try std.testing.expectEqualStrings("[y Delete series, no email]", try dialog.confirmLabel(a, false));
    try std.testing.expectEqualStrings("Deletes every event in this series from Personal without emailing 1 guest. Guests outside Google Calendar keep their copy.", try dialog.consequence(a));
    const request = try dialog.reviewRequest(a, "op-1");
    try std.testing.expectEqualStrings("series", j.text(request, "scope"));
    try std.testing.expectEqualStrings("none", j.text(request, "sendUpdates"));
    try std.testing.expectEqualStrings("\"1\"", j.text(request, "expectedEtag"));
    try std.testing.expect(j.get(request, "response") == null);
    // Apply follows only a review of exactly what was shown.
    const Review = struct { eventId: []const u8 = "hosted_1", scope: []const u8 = "series", sendUpdates: []const u8 = "none", targetEventId: []const u8 = "hosted", targetEtag: []const u8 = "\"9\"", role: []const u8 = "organizer", guestCount: i64 = 1, guestsOmitted: bool = false, previousResponse: []const u8 = "accepted", consequence: []const u8 = "Deletes every event in this series from Personal without emailing 1 guest. Guests outside Google Calendar keep their copy." };
    try std.testing.expect(dialog.reviewMismatch(a, try j.value(a, Review{})) == null);
    try std.testing.expectEqualStrings("targetEtag", dialog.reviewMismatch(a, try j.value(a, Review{ .targetEtag = "\"10\"" })).?);
    try std.testing.expectEqualStrings("guestCount", dialog.reviewMismatch(a, try j.value(a, Review{ .guestCount = 2 })).?);
    try std.testing.expectEqualStrings("scope", dialog.reviewMismatch(a, try j.value(a, Review{ .scope = "event" })).?);
    // Back to this occurrence: its two guests, and the email choice again.
    dialog.choose(.scope_event);
    try std.testing.expect(dialog.notify == null and dialog.guestCount() == 2);
}

test "calendar action UI: an answer is chosen, never sent by a letter, and the current answer cannot be resent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dialog: Dialog = .{};
    defer dialog.close();
    try dialog.begin(.respond, "self@example.test", "self@example.test", "invite", "Partner sync", "");
    try dialog.setPlan(std.testing.allocator, try j.value(a, .{ .role = "attendee", .previousResponse = "accepted", .attendee = "self@example.test", .organizer = "host@example.test", .summary = "Partner sync", .calendarName = "Personal", .eventId = "invite", .expectedEtag = "\"1\"", .targetEventId = "invite" }));
    try std.testing.expect(!dialog.canConfirm());
    try std.testing.expectEqualStrings("Choose Accept, Maybe or Decline", dialog.blocker().?);
    dialog.choose(.accept);
    try std.testing.expect(!dialog.canConfirm());
    dialog.choose(.decline);
    try std.testing.expect(dialog.canConfirm());
    try std.testing.expectEqualStrings("[y Decline · email organizer]", try dialog.confirmLabel(a, false));
    dialog.choose(.notify_yes);
    try std.testing.expectEqualStrings("[y Decline · no email]", try dialog.confirmLabel(a, false));
    try std.testing.expectEqualStrings("declined", j.text(try dialog.reviewRequest(a, "op"), "response"));
    try std.testing.expectEqualStrings("Declines this event as self@example.test. No email is sent; an organizer using Google Calendar sees your answer there.", try dialog.consequence(a));
    try std.testing.expectEqualStrings("Not answered", currentAnswer("needsAction"));
    try std.testing.expect(std.mem.indexOf(u8, reasonText(.respond, "CalendarPrivateCopy").?, "invitation email") != null);
}
