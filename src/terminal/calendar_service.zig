//! Shared Calendar command service for native TUI and CLI hosts.
//! Host callbacks use the selected account's verified grant and encrypted store.
//! No credentials, filesystem policy, worker, or UI state live in this module.
const std = @import("std");
const t = @import("calendar_types.zig");
const p = @import("calendar_provider.zig");
const planner = @import("calendar_plan.zig");
const invitation = @import("calendar_invitation.zig");
const agenda_builder = @import("calendar_agenda.zig");
const timezone = @import("timezone.zig");
const j = @import("json.zig");
const ordinary = @import("calendar_event.zig");

pub const Grants = struct {
    account: []const u8,
    calendar_list: bool = false,
    read_events: bool = false,
    write_owned: bool = false,
    write_shared: bool = false,
    free_busy: bool = false,

    pub fn canRead(self: Grants, calendar: t.Calendar) bool {
        return self.sameAccount(calendar.target) and calendar.access != .none and calendar.access != .free_busy and
            (self.read_events or self.write_shared or (self.write_owned and calendar.owned_scope_verified));
    }
    pub fn canWrite(self: Grants, calendar: t.Calendar) bool {
        return self.sameAccount(calendar.target) and calendar.writable() and
            (self.write_shared or (self.write_owned and calendar.owned_scope_verified));
    }
    fn sameAccount(self: Grants, target: t.Target) bool {
        return std.ascii.eqlIgnoreCase(self.account, target.account);
    }
};

pub const Response = struct {
    /// The verified credential identity, not merely a copy of request.account.
    account: []const u8,
    status: u16,
    body: []const u8 = "",
};
pub const Transport = struct {
    context: *anyopaque,
    /// Return bounded response bytes owned by a. Do not retry mutating requests,
    /// follow redirects, or translate Calendar 404 into a Gmail/auth error.
    sendFn: *const fn (*anyopaque, std.mem.Allocator, p.Request) anyerror!Response,
};
pub const State = struct {
    tracked: ?planner.Tracked = null,
    /// The latest operation for this identity; pending unknown takes priority.
    operation: ?planner.Operation = null,
};
pub const Persistence = struct {
    context: *anyopaque,
    journal: planner.Journal,
    loadFn: *const fn (*anyopaque, std.mem.Allocator, planner.Identity) anyerror!State,
    /// Preserve the complete source and exact prepared request in encrypted
    /// account storage before claim. This callback does not authorize dispatch.
    preserveFn: *const fn (*anyopaque, Review) anyerror!void,

    /// Journal.claim must atomically serialize writes for the entire identity,
    /// including different operation IDs. Journal.record(applied) must retain
    /// tracked identity/version/hash and the operation in one durable commit.
    pub fn load(self: Persistence, a: std.mem.Allocator, identity: planner.Identity) !State {
        const state = try self.loadFn(self.context, a, identity);
        if (state.tracked) |tracked| if (!tracked.identity.eql(identity)) return error.CalendarIdentityMismatch;
        if (state.operation) |operation| {
            try operation.intent.validate();
            if (!operation.intent.identity.eql(identity)) return error.OperationConflict;
        }
        return state;
    }
};
pub const Cache = struct {
    context: *anyopaque,
    loadFn: *const fn (*anyopaque, std.mem.Allocator, t.Target, t.Window) anyerror!?t.Snapshot,
    /// Replace one exact account/calendar/window snapshot, never append history.
    saveFn: *const fn (*anyopaque, t.Snapshot) anyerror!void,
    loadCalendarsFn: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!?CalendarList = null,
    saveCalendarsFn: ?*const fn (*anyopaque, CalendarList) anyerror!void = null,
};
pub const CalendarList = struct { calendars: []const t.Calendar, complete: bool, cache_error: []const u8 = "" };
pub const Agenda = struct { snapshot: t.Snapshot, refresh_error: []const u8 = "", cache_error: []const u8 = "" };
pub const Bindings = struct { start: ?t.time.Binding = null, end: ?t.time.Binding = null };
pub const InvitationPlan = struct {
    calendar: t.Calendar,
    source: t.Invitation,
    span: ?invitation.Span,
    time_error: []const u8,
    lookup: planner.Lookup,
    state: State,
    decision: planner.Decision,
    writable: bool,
};
pub const Review = struct {
    calendar: t.Calendar,
    source: t.Invitation,
    span: ?invitation.Span,
    intent: planner.Intent,
    request: p.Request,
    review_hash: [32]u8,
    previous: ?t.Event = null,
    rsvp_response: ?p.RsvpResponse = null,
    response_only: bool = false,
    ordinary_event: ?ordinary.Prepared = null,

    pub fn confirmation(self: Review) Confirmation {
        return .{ .target = self.intent.identity.target, .operation_id = self.intent.operation_id, .review_hash = self.review_hash };
    }
};
pub const Receipt = struct { operation: planner.Operation, review_hash: [32]u8, ordinary: bool = true };
pub const Pending = struct { review: Review, operation: planner.Operation };
pub const Confirmation = struct { target: t.Target, operation_id: []const u8, review_hash: [32]u8 };
pub const Applied = struct {
    operation: planner.Operation,
    event: ?t.Event = null,
    reconciled: bool = false,
    failure: ?p.Failure = null,
    retry_possible: bool = false,
    recovery_reason: []const u8 = "",
};
pub const BusyRange = struct { start_ms: i64, end_ms: i64 };
pub const FreeBusy = struct {
    target: t.Target,
    window: t.Window,
    ranges: []const BusyRange,
    complete: bool,
    reason: []const u8 = "",
};

pub const Service = struct {
    a: std.mem.Allocator,
    grants: Grants,
    transport: Transport,
    persistence: ?Persistence = null,
    cache: ?Cache = null,
    /// Background reads retain cache fallback without replacing the user's
    /// saved calendars or agenda windows with polling snapshots.
    persist_cache: bool = true,
    now_ms: i64,

    pub fn list(self: Service) !CalendarList {
        if (!self.grants.calendar_list) return error.CalendarPermissionRequired;
        var calendars: std.ArrayList(t.Calendar) = .empty;
        var pages: Pages = .{};
        while (try pages.next()) |token| {
            const response = try self.read(try p.listCalendars(self.a, self.grants.account, token));
            const page = try p.decodeCalendars(self.a, self.grants.account, response.body);
            for (page.calendars) |calendar| {
                for (calendars.items) |previous| if (calendar.target.eql(previous.target)) return error.CalendarPageOverlap;
                if (calendars.items.len == t.Limits.calendars) return .{ .calendars = calendars.items, .complete = false };
                try calendars.append(self.a, calendar);
            }
            try pages.advance(page.next_page_token);
        }
        var result: CalendarList = .{ .calendars = calendars.items, .complete = pages.complete };
        if (result.complete and self.persist_cache) if (self.cache) |cache| if (cache.saveCalendarsFn) |save| {
            save(cache.context, result) catch |err| {
                result.cache_error = @errorName(err);
            };
        };
        return result;
    }

    /// UID lookup includes hidden invitations and deleted records. Reaching any
    /// bound returns complete=false; it can never authorize an absent import.
    pub fn lookup(self: Service, calendar: t.Calendar, uid: []const u8) !planner.Lookup {
        try self.requireRead(calendar);
        var events: std.ArrayList(t.Event) = .empty;
        var pages: Pages = .{};
        var bytes: usize = 0;
        while (try pages.next()) |token| {
            const response = try self.read(try p.lookup(self.a, calendar.target, uid, token));
            bytes += response.body.len;
            if (bytes > t.Limits.snapshot_bytes) return .{ .target = calendar.target, .uid = uid, .events = events.items, .complete = false };
            const page = try p.decodePage(self.a, calendar.target, response.body, self.now_ms);
            for (page.events) |item| {
                for (events.items) |previous| if (std.mem.eql(u8, item.id, previous.id)) return error.CalendarPageOverlap;
                if (events.items.len == t.Limits.snapshot_events) return .{ .target = calendar.target, .uid = uid, .events = events.items, .complete = false };
                try events.append(self.a, item);
            }
            try pages.advance(page.next_page_token);
        }
        return .{ .target = calendar.target, .uid = uid, .events = events.items, .complete = pages.complete };
    }

    pub fn agenda(self: Service, calendar: t.Calendar, window: t.Window) !Agenda {
        try self.requireRead(calendar);
        try window.validate();
        const snapshot = self.refreshAgenda(calendar, window) catch |err| {
            if (self.cache) |cache| if (try cache.loadFn(cache.context, self.a, calendar.target, window)) |previous| {
                try previous.validate();
                if (!previous.target.eql(calendar.target) or !sameWindow(previous.window, window) or !previous.complete) return error.CalendarCacheMismatch;
                var stale = previous;
                stale.stale = true;
                return .{ .snapshot = stale, .refresh_error = @errorName(err) };
            };
            return err;
        };
        var cache_error: []const u8 = "";
        if (self.persist_cache) if (self.cache) |cache| cache.saveFn(cache.context, snapshot) catch |err| {
            cache_error = @errorName(err);
        };
        return .{ .snapshot = snapshot, .cache_error = cache_error };
    }

    fn refreshAgenda(self: Service, calendar: t.Calendar, window: t.Window) !t.Snapshot {
        var builder = try agenda_builder.Builder.init(calendar.target, window);
        var pages: Pages = .{};
        var bytes: usize = 0;
        while (try pages.next()) |token| {
            const response = try self.read(try p.agenda(self.a, calendar.target, window, token));
            bytes += response.body.len;
            if (bytes > t.Limits.snapshot_bytes) return error.CalendarSnapshotTooLarge;
            const page = try p.decodePage(self.a, calendar.target, response.body, self.now_ms);
            try builder.append(self.a, page, token);
            try pages.advance(page.next_page_token);
        }
        return builder.snapshot();
    }

    pub fn event(self: Service, calendar: t.Calendar, event_id: []const u8) !t.Event {
        return (try self.document(calendar, event_id)).event;
    }

    pub fn document(self: Service, calendar: t.Calendar, event_id: []const u8) !p.EventDocument {
        try self.requireRead(calendar);
        const response = try self.read(try p.get(self.a, calendar.target, event_id));
        const result = try p.decodeDocument(self.a, calendar.target, response.body);
        if (!std.mem.eql(u8, result.event.id, event_id)) return error.CalendarIdentityMismatch;
        return result;
    }

    /// Ordinary organizer events share the same durable single-dispatch journal
    /// as invitation imports, while retaining a separate draft/review contract.
    pub const EventFields = struct { description_present: bool = true, location_present: bool = true };
    pub fn prepareEventReview(self: Service, calendar: t.Calendar, initial: ordinary.Prepared, operation_id: []const u8, event_id: []const u8, expected_etag: []const u8) !Review {
        return self.prepareEventReviewFields(calendar, initial, operation_id, event_id, expected_etag, .{});
    }
    pub fn prepareEventReviewFields(self: Service, calendar: t.Calendar, initial: ordinary.Prepared, operation_id: []const u8, event_id: []const u8, expected_etag: []const u8, fields: EventFields) !Review {
        try self.requireRead(calendar);
        try self.requireWrite(calendar);
        const current = if (event_id.len != 0) try self.document(calendar, event_id) else null;
        var prepared = initial;
        if (current) |document_value| {
            if (!fields.description_present) prepared.draft.description = document_value.event.description;
            if (!fields.location_present) prepared.draft.location = document_value.event.location;
            if (ordinary.htmlDescription(document_value.event.description) and prepared.draft.conference == .link) return error.CalendarHtmlNotesReadOnly;
            if (ordinary.htmlDescription(document_value.event.description) and !std.mem.eql(u8, prepared.draft.description, document_value.event.description)) return error.CalendarHtmlNotesReadOnly;
            const link = document_value.event.join_url;
            // Notes/location links are the conference identity when Google has
            // no conferenceData. Editing surrounding text must retain Join.
            if (prepared.draft.conference == .none and !ordinary.htmlDescription(document_value.event.description) and link.len != 0 and j.get(document_value.value, "conferenceData") == null and j.text(document_value.value, "hangoutLink").len == 0 and std.mem.indexOf(u8, prepared.draft.description, link) == null and std.mem.indexOf(u8, prepared.draft.location, link) == null) {
                prepared.draft.description = try std.fmt.allocPrint(self.a, "{s}\n\nJoin: {s}", .{ prepared.draft.description, link });
            }
        }
        if (current) |document_value| {
            if (!std.mem.eql(u8, document_value.event.etag, expected_etag)) return error.CalendarReviewStale;
        } else if (expected_etag.len != 0) return error.InvalidCalendarConfirmation;
        const id = if (current) |value| value.event.id else try ordinary.eventId(self.a, calendar.target, operation_id);
        const identity: planner.Identity = .{ .target = calendar.target, .uid = try std.fmt.allocPrint(self.a, "event:{s}", .{id}) };
        const source_bytes = try std.json.Stringify.valueAlloc(self.a, prepared, .{});
        if (source_bytes.len > t.Limits.source_bytes) return error.CalendarTooLarge;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source_bytes, &hash, .{});
        const version: t.Version = .{ .sequence = if (current) |value| value.event.sequence else 0, .dtstamp_ms = 0 };
        const source: t.Invitation = .{ .account = calendar.target.account, .source = source_bytes, .unfolded = source_bytes, .source_hash = hash, .method = .request, .uid = identity.uid, .organizer = calendar.target.account, .attendee = calendar.target.account, .version = version, .summary = prepared.draft.summary };
        var intent: planner.Intent = .{ .operation_id = operation_id, .identity = identity, .version = version, .kind = if (current != null) .update_event else .insert_event, .source_hash = hash, .payload_hash = @splat(0), .event_id = id, .expected_etag = expected_etag };
        const request = try ordinary.prepare(self.a, calendar, prepared, intent, current);
        intent = try request.bindIntent(intent);
        var review: Review = .{ .calendar = calendar, .source = source, .span = prepared.span, .intent = intent, .request = request, .review_hash = undefined, .previous = if (current) |value| value.event else null, .ordinary_event = prepared };
        review.review_hash = try reviewHash(self.a, review);
        return review;
    }

    pub fn eventEditable(self: Service, calendar: t.Calendar, document_value: p.EventDocument) bool {
        return self.grants.canWrite(calendar) and ordinary.canEdit(calendar, document_value);
    }

    pub fn invitationPlan(self: Service, calendar: t.Calendar, raw: []const u8, verified_aliases: []const []const u8, bindings: Bindings) !InvitationPlan {
        try self.requireRead(calendar);
        const source = try invitation.parse(self.a, raw, self.grants.account, verified_aliases);
        const identity: planner.Identity = .{ .target = calendar.target, .uid = source.uid };
        const state = if (self.persistence) |store| try store.load(self.a, identity) else State{};
        var time_error: []const u8 = "";
        const span: ?invitation.Span = invitation.resolveSpan(source, bindings.start, bindings.end) catch |err| blk: {
            time_error = @errorName(err);
            break :blk null;
        };
        const found = try self.lookup(calendar, source.uid);
        return .{ .calendar = calendar, .source = source, .span = span, .time_error = time_error, .lookup = found, .state = state, .decision = try planner.plan(.{ .invitation = source, .target = calendar.target, .lookup = found, .tracked = state.tracked, .operation = state.operation, .times_resolved = span != null }), .writable = self.grants.canWrite(calendar) };
    }

    /// Prepare exact bytes for review; no Calendar mutation or journal claim.
    /// Updates/cancellations use a fresh GET and bind its current ETag.
    pub fn prepareReview(self: Service, planned: InvitationPlan, operation_id: []const u8) !Review {
        if (self.persistence == null) return error.CalendarPersistenceRequired;
        try self.requireWrite(planned.calendar);
        const source = planned.source;
        var prior_event: ?t.Event = null;
        var intent: planner.Intent = .{ .operation_id = operation_id, .identity = .{ .target = planned.calendar.target, .uid = source.uid }, .version = source.version, .kind = .import_event, .source_hash = source.source_hash, .payload_hash = @splat(0) };
        const request = switch (planned.decision) {
            .import_missing => try p.prepareResolvedImport(self.a, source, intent, planned.span orelse return error.CalendarTimeReviewRequired),
            .review_update, .review_cancel => |previous| blk: {
                const current = try self.document(planned.calendar, previous.id);
                if (!sameEventIdentity(current.event, source) or current.event.cancelled or current.event.locked or !std.mem.eql(u8, current.event.etag, previous.etag) or current.event.sequence > source.version.sequence) return error.CalendarReviewStale;
                intent.kind = if (planned.decision == .review_cancel) .cancel_event else .update_event;
                intent.event_id = current.event.id;
                intent.expected_etag = current.event.etag;
                prior_event = current.event;
                break :blk if (intent.kind == .cancel_event) try p.prepareCancel(self.a, intent) else try p.prepareInvitationPatch(self.a, source, intent, planned.span orelse return error.CalendarTimeReviewRequired, current);
            },
            else => return error.CalendarActionUnavailable,
        };
        intent = try request.bindIntent(intent);
        var review: Review = .{ .calendar = planned.calendar, .source = source, .span = planned.span, .intent = intent, .request = request, .review_hash = undefined, .previous = prior_event };
        review.review_hash = try reviewHash(self.a, review);
        return review;
    }

    /// A successful mail RSVP authorizes the corresponding Calendar attendee
    /// response. Organizer updates keep the existing source/version guards.
    pub fn prepareRsvpReview(self: Service, planned: InvitationPlan, operation_id: []const u8, response: p.RsvpResponse) !Review {
        try self.requireWrite(planned.calendar);
        if (planned.source.isRecurring()) return error.UnsupportedCalendarRecurrence;
        if (!planned.lookup.complete) return error.CalendarLookupIncomplete;
        var review: Review = switch (planned.decision) {
            .import_missing, .review_update => try self.prepareReview(planned, operation_id),
            .existing => |previous| blk: {
                const current = try self.document(planned.calendar, previous.id);
                if (!sameEventIdentity(current.event, planned.source) or current.event.cancelled or current.event.locked or !std.mem.eql(u8, current.event.etag, previous.etag) or current.event.sequence != planned.source.version.sequence) return error.CalendarReviewStale;
                var intent: planner.Intent = .{ .operation_id = operation_id, .identity = .{ .target = planned.calendar.target, .uid = planned.source.uid }, .version = planned.source.version, .kind = .update_event, .source_hash = planned.source.source_hash, .payload_hash = @splat(0), .event_id = current.event.id, .expected_etag = current.event.etag };
                const request = try p.prepareRsvpPatch(self.a, planned.source, intent, current, response);
                intent = try request.bindIntent(intent);
                break :blk .{ .calendar = planned.calendar, .source = planned.source, .span = planned.span, .intent = intent, .request = request, .review_hash = undefined, .previous = current.event, .response_only = true };
            },
            else => return error.CalendarActionUnavailable,
        };
        if (!review.response_only) {
            const current = if (review.intent.kind == .update_event) try self.document(planned.calendar, review.intent.event_id) else null;
            if (current) |document_value| if (!std.mem.eql(u8, document_value.event.etag, review.intent.expected_etag)) return error.CalendarReviewStale;
            review.request = try p.withRsvpResponse(self.a, review.request, planned.source.attendee, response, current);
            review.intent = try review.request.bindIntent(review.intent);
        }
        review.rsvp_response = response;
        review.review_hash = try reviewHash(self.a, review);
        return review;
    }

    /// Only an exact confirmed review and a fresh durable unknown claim can
    /// reach sendFn. Repeated calls reconcile or return the existing receipt.
    pub fn apply(self: Service, review: Review, confirmation: Confirmation) !Applied {
        try self.validateReview(review, confirmation);
        try self.requireWrite(review.calendar);
        const store = self.persistence orelse return error.CalendarPersistenceRequired;
        const state = try store.load(self.a, review.intent.identity);
        if (state.operation) |operation| {
            if (std.mem.eql(u8, operation.intent.operation_id, review.intent.operation_id)) {
                if (!operation.intent.eql(review.intent)) return error.OperationConflict;
                return self.reconcileOperation(review, operation);
            }
            if (operation.state == .unknown) return error.CalendarOperationPending;
        }
        if (review.ordinary_event == null) {
            if (state.tracked) |tracked| {
                if (review.intent.kind == .import_event or (if (review.response_only) review.intent.version.order(tracked.version) == .lt else review.intent.version.order(tracked.version) != .gt) or !std.mem.eql(u8, review.intent.event_id, tracked.event_id)) return error.CalendarReviewStale;
            } else if (review.intent.kind != .import_event and !review.response_only) return error.CalendarReviewStale;

            if (review.intent.kind == .import_event) {
                const found = try self.lookup(review.calendar, review.intent.identity.uid);
                if (!found.complete) return error.CalendarLookupIncomplete;
                if (found.events.len != 0) return error.CalendarReviewStale;
            } else {
                const current = try self.event(review.calendar, review.intent.event_id);
                if (!sameEventIdentity(current, review.source) or current.cancelled or current.locked or !std.mem.eql(u8, current.etag, review.intent.expected_etag) or current.sequence > review.intent.version.sequence) return error.CalendarReviewStale;
            }
        } else if (review.intent.kind == .insert_event) {
            // The stable client-generated ID is the exact recovery address.
            // A pre-existing record never authorizes inserting over it.
            if (self.event(review.calendar, review.intent.event_id)) |_| return error.CalendarReviewStale else |err| {
                if (err != error.CalendarNotFound) return err;
            }
        } else {
            const current = try self.document(review.calendar, review.intent.event_id);
            if (!ordinary.canEdit(review.calendar, current) or !std.mem.eql(u8, current.event.etag, review.intent.expected_etag)) return error.CalendarReviewStale;
        }
        try store.preserveFn(store.context, review);
        const claim = try store.journal.claim(review.intent);
        if (!claim.fresh) return self.reconcileOperation(review, claim.operation);
        return self.dispatchClaimed(review, claim.operation, false);
    }

    /// A retry is an explicit fresh confirmation of the identical saved wire
    /// request. The fixed create ID / original If-Match / conference request ID
    /// remain unchanged; a monotonic durable attempt token fences double clicks.
    pub fn retry(self: Service, review: Review, confirmation: Confirmation, next_attempt: u32) !Applied {
        try self.validateReview(review, confirmation);
        try self.requireWrite(review.calendar);
        if (review.ordinary_event == null) return error.CalendarReviewMismatch;
        const store = self.persistence orelse return error.CalendarPersistenceRequired;
        const state = try store.load(self.a, review.intent.identity);
        const operation = state.operation orelse return error.CalendarOperationNotFound;
        if (!operation.intent.eql(review.intent)) return error.OperationConflict;
        if (operation.state != .unknown) return .{ .operation = operation };
        const checked = try self.reconcileOperation(review, operation);
        if (checked.operation.state != .unknown) return checked;
        if (!checked.retry_possible) return error.CalendarRetryUnavailable;
        const claim = try store.journal.retry(review.intent, next_attempt);
        if (!claim.fresh) return self.reconcileOperation(review, claim.operation);
        return self.dispatchClaimed(review, claim.operation, true);
    }

    /// Explicit local archiving releases the pending-operation guard. It never
    /// asserts the event was not saved and never issues a provider request.
    pub fn archive(self: Service, review: Review, confirmation: Confirmation) !Applied {
        try self.validateReview(review, confirmation);
        if (review.ordinary_event == null) return error.CalendarReviewMismatch;
        const store = self.persistence orelse return error.CalendarPersistenceRequired;
        const state = try store.load(self.a, review.intent.identity);
        var operation = state.operation orelse return error.CalendarOperationNotFound;
        if (!operation.intent.eql(review.intent)) return error.OperationConflict;
        if (operation.state != .unknown) return .{ .operation = operation };
        operation.state = .archived;
        operation.error_code = "UncertaintyArchived";
        try store.journal.record(operation);
        return .{ .operation = operation, .recovery_reason = "The event may still appear in Calendar" };
    }

    fn dispatchClaimed(self: Service, review: Review, claimed: planner.Operation, retrying: bool) !Applied {
        const store = self.persistence orelse return error.CalendarPersistenceRequired;
        var operation = claimed;
        const response = self.send(review.request) catch |err| return .{ .operation = operation, .recovery_reason = @errorName(err) };
        if (response.status < 200 or response.status >= 300) {
            const failure = p.classifyFailure(review.request.kind, response.status, reason(self.a, response.body));
            if (retrying and (failure == .duplicate or failure == .version_conflict)) return self.reconcileOperation(review, operation);
            if (failure == .unknown or retrying) return .{ .operation = operation, .failure = failure, .recovery_reason = "ProviderOutcomeUnknown" };
            operation.state = .rejected;
            operation.error_code = @tagName(failure);
            try store.journal.record(operation);
            return .{ .operation = operation, .failure = failure };
        }
        var result_event: ?t.Event = null;
        if (review.intent.kind == .cancel_event) {
            operation.provider_id = review.intent.event_id;
        } else {
            const document_value = p.decodeDocument(self.a, review.calendar.target, response.body) catch return .{ .operation = operation };
            if (!(if (review.ordinary_event != null) ordinary.receiptProof(document_value.event, review.intent) else provesWrite(document_value.event, review)) or (if (review.rsvp_response) |response_status| !p.responseMatches(document_value, review.source.attendee, response_status) else false)) return .{ .operation = operation };
            result_event = document_value.event;
            operation.provider_id = document_value.event.id;
        }
        operation.state = .applied;
        try store.journal.record(operation);
        return .{ .operation = operation, .event = result_event };
    }

    /// Reconciliation performs reads only. A Calendar 404 does not prove that
    /// cancellation succeeded: it can also mean lost calendar access.
    pub fn reconcile(self: Service, review: Review) !Applied {
        const store = self.persistence orelse return error.CalendarPersistenceRequired;
        const state = try store.load(self.a, review.intent.identity);
        return self.reconcileOperation(review, state.operation orelse return error.CalendarOperationNotFound);
    }

    fn reconcileOperation(self: Service, review: Review, pending: planner.Operation) !Applied {
        try self.validateReview(review, review.confirmation());
        if (!pending.intent.eql(review.intent)) return error.OperationConflict;
        if (pending.state != .unknown) return .{ .operation = pending };
        const store = self.persistence orelse return error.CalendarPersistenceRequired;
        var match: ?t.Event = null;
        if (review.ordinary_event != null) {
            const document_value = self.document(review.calendar, pending.intent.event_id) catch |err| return .{ .operation = pending, .retry_possible = pending.intent.kind == .insert_event and err == error.CalendarNotFound and pending.attempt < 1000000, .recovery_reason = @errorName(err) };
            const current = document_value.event;
            if (!ordinary.receiptProof(current, pending.intent)) {
                const possible = pending.intent.kind == .update_event and std.mem.eql(u8, current.etag, pending.intent.expected_etag) and ordinary.canEdit(review.calendar, document_value) and pending.attempt < 1000000;
                return .{ .operation = pending, .retry_possible = possible, .recovery_reason = if (possible) @as([]const u8, "SavedVersionStillCurrent") else if (current.cancelled) "EventDeletedWithoutReceipt" else "EventChangedWithoutReceipt" };
            }
            var resolved = pending;
            resolved.state = .applied;
            resolved.provider_id = current.id;
            try store.journal.record(resolved);
            return .{ .operation = resolved, .event = current, .reconciled = true };
        }
        if (pending.intent.kind == .cancel_event) {
            const current = self.event(review.calendar, pending.intent.event_id) catch return .{ .operation = pending };
            if (!current.cancelled or (current.uid.len != 0 and !std.mem.eql(u8, current.uid, pending.intent.identity.uid))) return .{ .operation = pending };
            match = current;
        } else {
            const found = self.lookup(review.calendar, pending.intent.identity.uid) catch return .{ .operation = pending };
            if (!found.complete) return .{ .operation = pending };
            for (found.events) |current| {
                if (!provesWrite(current, review)) continue;
                if (review.rsvp_response) |response_status| {
                    const full = self.document(review.calendar, current.id) catch return .{ .operation = pending };
                    if (!provesWrite(full.event, review) or !p.responseMatches(full, review.source.attendee, response_status)) continue;
                }
                if (match != null) return .{ .operation = pending };
                match = current;
            }
        }
        const current = match orelse return .{ .operation = pending };
        var resolved = pending;
        resolved.state = .applied;
        resolved.provider_id = current.id;
        try store.journal.record(resolved);
        return .{ .operation = resolved, .event = current, .reconciled = true };
    }

    pub fn freeBusy(self: Service, calendar: t.Calendar, window: t.Window) !FreeBusy {
        try self.requireAccount(calendar.target);
        if (!self.grants.free_busy or calendar.access == .none) return error.CalendarFreeBusyPermissionRequired;
        try window.validate();
        const body = try std.json.Stringify.valueAlloc(self.a, .{ .timeMin = try t.time.format(self.a, .{ .kind = .instant, .value = window.start_ms }), .timeMax = try t.time.format(self.a, .{ .kind = .instant, .value = window.end_ms }), .timeZone = window.time_zone, .calendarExpansionMax = 1, .items = [_]struct { id: []const u8 }{.{ .id = calendar.target.calendar_id }} }, .{});
        const response = try self.read(.{ .target = calendar.target, .kind = .free_busy, .method = .POST, .url = p.base_url ++ "/freeBusy", .body = body });
        return decodeFreeBusy(self.a, calendar.target, window, response.body);
    }

    fn requireAccount(self: Service, target: t.Target) !void {
        try target.validate();
        if (!self.grants.sameAccount(target)) return error.CalendarAccountMismatch;
    }
    fn requireRead(self: Service, calendar: t.Calendar) !void {
        try self.requireAccount(calendar.target);
        if (!self.grants.canRead(calendar)) return error.CalendarReadPermissionRequired;
    }
    fn requireWrite(self: Service, calendar: t.Calendar) !void {
        try self.requireAccount(calendar.target);
        if (!calendar.writable()) return error.CalendarReadOnly;
        if (!self.grants.canWrite(calendar)) return error.CalendarWritePermissionRequired;
    }
    fn send(self: Service, request: p.Request) !Response {
        try self.requireAccount(request.target);
        const response = try self.transport.sendFn(self.transport.context, self.a, request);
        if (!std.ascii.eqlIgnoreCase(response.account, self.grants.account)) return error.CalendarAccountMismatch;
        if (response.body.len > t.Limits.response_bytes) return error.CalendarResponseTooLarge;
        return response;
    }
    fn read(self: Service, request: p.Request) !Response {
        if (request.kind.mutating()) return error.InvalidCalendarMutation;
        const response = try self.send(request);
        if (response.status >= 200 and response.status < 300) return response;
        return failureError(p.classifyFailure(request.kind, response.status, reason(self.a, response.body)));
    }
    fn validateReview(self: Service, review: Review, confirmation: Confirmation) !void {
        if (review.response_only and (review.rsvp_response == null or review.intent.kind != .update_event)) return error.CalendarReviewMismatch;
        try review.intent.validate();
        try self.requireAccount(review.intent.identity.target);
        if (!review.calendar.target.eql(review.intent.identity.target) or !confirmation.target.eql(review.intent.identity.target) or !std.mem.eql(u8, confirmation.operation_id, review.intent.operation_id) or !std.mem.eql(u8, &confirmation.review_hash, &review.review_hash)) return error.CalendarReviewMismatch;
        var actual_source: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(review.source.source, &actual_source, .{});
        if (!std.mem.eql(u8, &actual_source, &review.intent.source_hash) or !std.mem.eql(u8, &review.source.source_hash, &actual_source) or review.source.version.order(review.intent.version) != .eq or !std.mem.eql(u8, review.source.uid, review.intent.identity.uid) or !std.ascii.eqlIgnoreCase(review.source.account, review.intent.identity.target.account)) return error.CalendarReviewMismatch;
        if (review.ordinary_event) |prepared| {
            const serialized = try std.json.Stringify.valueAlloc(self.a, prepared, .{});
            if (!std.mem.eql(u8, serialized, review.source.source) or (review.intent.kind != .insert_event and review.intent.kind != .update_event)) return error.CalendarReviewMismatch;
        } else if (review.intent.kind == .insert_event) return error.CalendarReviewMismatch;
        if (!(try review.request.bindIntent(review.intent)).eql(review.intent)) return error.CalendarReviewMismatch;
        const actual_review = try reviewHash(self.a, review);
        if (!std.mem.eql(u8, &actual_review, &review.review_hash)) {
            // v0.2.9 persisted the then-current Event shape in invitation
            // hashes. Added presentation fields must not strand a durable
            // unknown operation after an upgrade. Only the exact old shape,
            // with no newly populated metadata, can use its frozen projection.
            if (!legacyInvitationReview(review)) return error.CalendarReviewMismatch;
            const legacy_hash = try legacyReviewHash(self.a, review);
            if (!std.mem.eql(u8, &legacy_hash, &review.review_hash)) return error.CalendarReviewMismatch;
        }
    }
};

fn reviewHash(a: std.mem.Allocator, review: Review) ![32]u8 {
    const bytes = if (review.ordinary_event != null) try std.json.Stringify.valueAlloc(a, .{ .intent = review.intent, .ordinary_event = review.ordinary_event, .previous = review.previous }, .{}) else if (review.rsvp_response != null) try std.json.Stringify.valueAlloc(a, .{ .intent = review.intent, .organizer = review.source.organizer, .attendee = review.source.attendee, .summary = review.source.summary, .span = review.span, .previous = review.previous, .rsvp_response = review.rsvp_response, .response_only = review.response_only }, .{}) else try std.json.Stringify.valueAlloc(a, .{ .intent = review.intent, .organizer = review.source.organizer, .attendee = review.source.attendee, .summary = review.source.summary, .span = review.span, .previous = review.previous }, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}
fn legacyInvitationReview(review: Review) bool {
    if (review.ordinary_event != null) return false;
    const previous = review.previous orelse return false;
    return previous.event_type.len == 0 and previous.attendees.len == 0 and !previous.attendees_omitted and previous.attendee_count == 0 and previous.conference_status.len == 0 and !previous.conference_present;
}
fn legacyReviewHash(a: std.mem.Allocator, review: Review) ![32]u8 {
    const previous = review.previous orelse return error.CalendarReviewMismatch;
    // Keep this explicit order frozen to the released v0.2.9 Event contract.
    const fields = [_][]const u8{ "target", "id", "uid", "etag", "organizer", "summary", "description", "location", "join_url", "html_url", "start", "end", "original_start", "recurring_event_id", "sequence", "cancelled", "transparent", "locked", "private_copy", "response", "operation_marker", "source_marker" };
    const current = try std.json.parseFromSliceLeaky(j.Value, a, try std.json.Stringify.valueAlloc(a, previous, .{}), .{});
    var old = j.object(a);
    for (fields) |field| try old.object.put(a, field, j.get(current, field) orelse return error.CalendarReviewMismatch);
    const bytes = if (review.rsvp_response != null) try std.json.Stringify.valueAlloc(a, .{ .intent = review.intent, .organizer = review.source.organizer, .attendee = review.source.attendee, .summary = review.source.summary, .span = review.span, .previous = old, .rsvp_response = review.rsvp_response, .response_only = review.response_only }, .{}) else try std.json.Stringify.valueAlloc(a, .{ .intent = review.intent, .organizer = review.source.organizer, .attendee = review.source.attendee, .summary = review.source.summary, .span = review.span, .previous = old }, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

fn sameEventIdentity(event: t.Event, source: t.Invitation) bool {
    return std.mem.eql(u8, event.uid, source.uid) and std.ascii.eqlIgnoreCase(event.organizer, source.organizer);
}
fn provesWrite(event: t.Event, review: Review) bool {
    const hash = std.fmt.bytesToHex(review.intent.source_hash, .lower);
    return event.target.eql(review.intent.identity.target) and sameEventIdentity(event, review.source) and !event.cancelled and
        (review.intent.kind == .import_event or std.mem.eql(u8, event.id, review.intent.event_id)) and
        event.sequence == review.intent.version.sequence and std.mem.eql(u8, event.operation_marker, review.intent.operation_id) and std.mem.eql(u8, event.source_marker, &hash);
}
fn sameWindow(left: t.Window, right: t.Window) bool {
    return left.start_ms == right.start_ms and left.end_ms == right.end_ms and std.mem.eql(u8, left.time_zone, right.time_zone);
}

/// Civil-day boundaries are resolved independently, preserving 23/25-hour DST
/// days. A week is seven local days starting at the supplied date.
pub fn windowForDays(a: std.mem.Allocator, date: []const u8, days: enum { day, week }, binding: t.time.Binding) !t.Window {
    try t.time.validateZoneName(binding.id);
    const first = try timezone.parseDate(date);
    const last_day = try timezone.dateDay(date) + @as(i64, if (days == .day) 1 else 7);
    const last = try timezone.parseDate(try t.time.format(a, .{ .kind = .date, .value = last_day }));
    const result: t.Window = .{ .start_ms = try firstInstantOfDay(binding.zone, first), .end_ms = try firstInstantOfDay(binding.zone, last), .time_zone = binding.id };
    try result.validate();
    return result;
}

/// Day-window boundaries represent the first actual instant of a civil date.
/// Midnight transitions can skip 00:00 or repeat it; neither is a compose-time
/// ambiguity. All event/editor wall times keep their strict gap/fold policy.
pub fn firstInstantOfDay(zone: *const timezone.Zone, date: timezone.CivilTime) !i64 {
    var midnight = date;
    midnight.hour = 0;
    midnight.minute = 0;
    midnight.second = 0;
    const at_midnight = try zone.localCandidates(midnight);
    if (at_midnight.count != 0) return at_midnight.values[0].milliseconds;
    // Search this bounded civil day for the end of its midnight gap. A minute
    // probe locates the transition; second-level refinement also handles old
    // IANA transitions whose offsets included seconds.
    var minute: u32 = 1;
    while (minute < 1440) : (minute += 1) {
        var candidate = midnight;
        candidate.hour = @intCast(minute / 60);
        candidate.minute = @intCast(minute % 60);
        const found = try zone.localCandidates(candidate);
        if (found.count == 0) continue;
        var second = (minute - 1) * 60 + 1;
        while (second <= minute * 60) : (second += 1) {
            candidate.hour = @intCast(second / 3600);
            candidate.minute = @intCast((second % 3600) / 60);
            candidate.second = @intCast(second % 60);
            const exact = try zone.localCandidates(candidate);
            if (exact.count != 0) return exact.values[0].milliseconds;
        }
        unreachable;
    }
    return error.CalendarCivilDateSkipped;
}

test "calendar ordinary: midnight DST agenda windows use the first valid civil instant and earliest repeated midnight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Chile-style clock jump from 00:00 to 01:00 on September's first Sunday.
    const santiago = try timezone.Zone.fromPosix("CLT4CLST,M9.1.0/0,M4.1.0/0");
    const first = try windowForDays(arena.allocator(), "2026-09-06", .day, .{ .id = "America/Santiago", .zone = &santiago });
    try std.testing.expectEqual(try t.time.rfc3339("2026-09-06T04:00:00Z"), first.start_ms);
    try std.testing.expectEqual(@as(i64, 23 * 3600000), first.end_ms - first.start_ms);
    // Cuba-style autumn shift at 01:00 repeats midnight; choose its first side.
    const havana = try timezone.Zone.fromPosix("CST5CDT,M3.2.0/0,M11.1.0/1");
    const repeated = try windowForDays(arena.allocator(), "2026-11-01", .day, .{ .id = "America/Havana", .zone = &havana });
    try std.testing.expectEqual(try t.time.rfc3339("2026-11-01T04:00:00Z"), repeated.start_ms);
    try std.testing.expectEqual(@as(i64, 25 * 3600000), repeated.end_ms - repeated.start_ms);
}

const Pages = struct {
    tokens: [t.Limits.pages][]const u8 = undefined,
    count: usize = 0,
    token: []const u8 = "",
    complete: bool = false,
    fn next(self: *Pages) !?[]const u8 {
        if (self.complete or self.count == self.tokens.len) return null;
        for (self.tokens[0..self.count]) |previous| if (std.mem.eql(u8, self.token, previous)) return error.CalendarPageMismatch;
        self.tokens[self.count] = self.token;
        self.count += 1;
        return self.token;
    }
    fn advance(self: *Pages, token: []const u8) !void {
        try t.text(token, 4096, true);
        self.token = token;
        self.complete = token.len == 0;
    }
};

pub fn failureError(failure: p.Failure) anyerror {
    return switch (failure) {
        .unauthorized => error.CalendarUnauthorized,
        .forbidden => error.CalendarForbidden,
        .not_found => error.CalendarNotFound,
        .duplicate => error.CalendarDuplicate,
        .version_conflict => error.CalendarVersionConflict,
        .full_refresh_required => error.CalendarFullRefreshRequired,
        .rate_limited => error.CalendarRateLimited,
        .rejected => error.CalendarRequestRejected,
        .transient => error.CalendarUnavailable,
        .unknown => error.UnknownOutcome,
    };
}
fn reason(a: std.mem.Allocator, body: []const u8) []const u8 {
    @import("../bounded.zig").preflight(body) catch return "";
    const value = std.json.parseFromSliceLeaky(j.Value, a, body, .{ .duplicate_field_behavior = .@"error" }) catch return "";
    const error_value = j.get(value, "error") orelse return "";
    const errors = j.get(error_value, "errors") orelse return "";
    if (errors != .array or errors.array.items.len == 0) return "";
    return j.text(errors.array.items[0], "reason");
}

pub fn decodeFreeBusy(a: std.mem.Allocator, target: t.Target, window: t.Window, bytes: []const u8) !FreeBusy {
    try target.validate();
    try window.validate();
    if (bytes.len == 0 or bytes.len > t.Limits.response_bytes) return error.CalendarResponseTooLarge;
    try @import("../bounded.zig").preflight(bytes);
    const value = try std.json.parseFromSliceLeaky(j.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    if (try t.time.rfc3339(try j.required(value, "timeMin")) != window.start_ms or try t.time.rfc3339(try j.required(value, "timeMax")) != window.end_ms) return error.CalendarWindowMismatch;
    const calendars = j.get(value, "calendars") orelse return error.InvalidCalendarResponse;
    const calendar = j.get(calendars, target.calendar_id) orelse return .{ .target = target, .window = window, .ranges = &.{}, .complete = false, .reason = "missingCalendar" };
    if (j.get(calendar, "errors")) |errors| {
        if (errors != .array) return error.InvalidCalendarResponse;
        if (errors.array.items.len != 0) return .{ .target = target, .window = window, .ranges = &.{}, .complete = false, .reason = try a.dupe(u8, j.text(errors.array.items[0], "reason")) };
    }
    const busy = j.get(calendar, "busy") orelse return error.InvalidCalendarResponse;
    if (busy != .array or busy.array.items.len > t.Limits.snapshot_events) return error.TooManyCalendarEvents;
    const ranges = try a.alloc(BusyRange, busy.array.items.len);
    for (busy.array.items, ranges) |item, *range| {
        range.* = .{ .start_ms = try t.time.rfc3339(try j.required(item, "start")), .end_ms = try t.time.rfc3339(try j.required(item, "end")) };
        if (range.start_ms < window.start_ms or range.end_ms > window.end_ms or range.end_ms <= range.start_ms) return error.InvalidCalendarResponse;
    }
    return .{ .target = target, .window = window, .ranges = ranges, .complete = true };
}
