//! Sequential Calendar/Meet coordination. Legacy Calendar claims remain the
//! authority for the event leg; Meet has a separately frozen companion claim.
const std = @import("std");
const j = @import("json.zig");
const types = @import("meet_notes_types.zig");
const provider = @import("meet_notes_provider.zig");
const book = @import("meet_notes_store.zig");
const calendar = @import("calendar_service.zig");
const cp = @import("calendar_provider.zig");
const ct = @import("calendar_types.zig");

pub const Transport = struct { context: *anyopaque, sendFn: *const fn (*anyopaque, std.mem.Allocator, provider.Request) anyerror!calendar.Response };
pub const Result = struct {
    entry: types.Entry,
    calendar_result: ?calendar.Applied = null,
    observed: ?provider.Space = null,
    observed_ms: i64 = 0,
    read_error: []const u8 = "",
};
pub const Mode = enum { apply, reconcile };
pub const Receipts = struct { context: *anyopaque, loadFn: *const fn (*anyopaque, std.mem.Allocator, ct.Target, []const u8) anyerror!?calendar.Receipt };
const Bound = struct { entry: types.Entry, space: provider.Space };

pub const Service = struct {
    a: std.mem.Allocator,
    calendar: calendar.Service,
    book: book.Host,
    transport: Transport,
    settings_access: bool,
    capabilities: []const []const u8 = &.{},
    now_ms: i64,
    receipts: ?Receipts = null,

    fn requireSettings(self: Service) !void {
        if (!self.settings_access) return error.MeetSettingsPermissionRequired;
    }
    fn send(self: Service, request: provider.Request) !calendar.Response {
        try self.requireSettings();
        if (!std.ascii.eqlIgnoreCase(request.account, self.calendar.grants.account)) return error.CalendarAccountMismatch;
        const response = try self.transport.sendFn(self.transport.context, self.a, request);
        if (!std.ascii.eqlIgnoreCase(response.account, request.account)) return error.CalendarAccountMismatch;
        if (response.body.len > provider.max_response_bytes) return error.MeetResponseTooLarge;
        return response;
    }
    fn readSpace(self: Service, account: []const u8, code: []const u8, name: ?[]const u8) !provider.Space {
        const response = try self.send(if (name) |canonical| try provider.read(self.a, account, canonical) else try provider.resolve(self.a, account, code));
        if (response.status < 200 or response.status >= 300) return statusError(self.a, response.status, response.body);
        return provider.decode(self.a, response.body, code, name) catch |err| {
            if (err == error.MeetSpaceMismatch) return error.MeetSpaceChanged;
            return err;
        };
    }
    fn documentLink(self: Service, selected: ct.Calendar, event_id: []const u8) !struct { document: cp.EventDocument, link: provider.Link } {
        const document = try self.calendar.document(selected, event_id);
        const link = provider.calendarLink(self.a, self.calendar.grants.account, event_id, document.value) catch |err| return bindingError(err);
        return .{ .document = document, .link = link };
    }

    /// The caller has preserved this exact unchanged Calendar review already.
    /// This second publication is inert until the compound hash is confirmed.
    pub fn reviewEvent(self: Service, inner: calendar.Review, enabled: bool) !types.Entry {
        try self.requireSettings();
        if (inner.intent.kind != .insert_event or !enabled) return error.MeetNewEventsOnly;
        if (!inner.calendar.primary) return error.MeetNotOrganizer;
        const prepared = inner.ordinary_event orelse return error.CalendarReviewMismatch;
        if (!std.ascii.eqlIgnoreCase(inner.intent.identity.target.account, self.calendar.grants.account)) return error.CalendarAccountMismatch;
        const parent: types.Parent = switch (inner.intent.kind) {
            .insert_event => .insert,
            .update_event => .update,
            else => return error.CalendarReviewMismatch,
        };
        var consent: types.Consent = .{
            .target = inner.intent.identity.target,
            .event_id = inner.intent.event_id,
            .operation_id = inner.intent.operation_id,
            .enabled = enabled,
            .parent = parent,
            .calendar_hash = inner.review_hash,
            .summary = prepared.draft.summary,
            .calendar_name = inner.calendar.summary,
            .time_zone = prepared.draft.timeZone,
            .all_day = prepared.draft.allDay,
            .notify_guests = prepared.send_updates == .all,
            .guest_count = @intCast(if (prepared.draft.attendees) |guests| guests.len else 0),
            .start = prepared.span.start,
            .end = prepared.span.end,
        };
        if (prepared.draft.conference == .google_meet) {
            consent.conference_request_id = inner.intent.operation_id;
        } else if (parent == .update and prepared.draft.conference == .none) {
            const current = try self.documentLink(inner.calendar, inner.intent.event_id);
            if (!std.mem.eql(u8, current.link.etag, inner.intent.expected_etag)) return error.CalendarReviewStale;
            const space = try self.readSpace(consent.target.account, current.link.code, null);
            consent.existing_etag = current.link.etag;
            consent.existing_code = current.link.code;
            consent.existing_space = space.name;
            consent.before_notes = space.notes;
            consent.before_transcription = space.transcription;
        } else return error.MeetLinkNotProvider;
        const entry: types.Entry = .{ .consent = consent, .review_hash = try consent.hash(self.a), .calendar_review = inner, .space_name = consent.existing_space, .code = consent.existing_code };
        try self.book.review(entry);
        // A repeated review can refer to a settled (even archived) operation.
        // Return its actual immutable state, not a new apparent ready review.
        return self.book.read(self.a, consent.target, consent.operation_id);
    }

    /// Both provider legs share one compound consent. Read-only reconciliation
    /// can advance durable observations but can never dispatch either mutation.
    pub fn execute(self: Service, target: ct.Target, operation_id: []const u8, hash: [32]u8, mode: Mode) !Result {
        var entry = try self.book.read(self.a, target, operation_id);
        if (!std.mem.eql(u8, &entry.review_hash, &hash)) return error.MeetReviewMismatch;
        if (entry.consent.parent != .insert or !entry.consent.enabled) return error.MeetNewEventsOnly;
        if (entry.phase == .confirmed) {
            if (mode == .reconcile) {
                const checked = self.bind(entry) catch |err| return .{ .entry = entry, .read_error = @errorName(err) };
                return .{ .entry = entry, .observed = checked.space, .observed_ms = self.now_ms };
            }
            return .{ .entry = entry };
        }
        if (entry.phase == .abandoned) return .{ .entry = entry };
        if (entry.phase == .refused) return if (mode == .reconcile) self.advanceMeet(entry, true, null) else .{ .entry = entry };
        if (entry.phase == .reviewed) {
            if (mode == .reconcile) return .{ .entry = entry };
            if (mode != .apply) return error.InvalidMeetContinuation;
            try self.requireSettings();
            // Known missing grants must not create an event without its
            // requested notes. The ordinary Service rechecks before claim.
            if (entry.calendar_review) |inner| if (!self.calendar.grants.canWrite(inner.calendar)) return error.CalendarWritePermissionRequired;
            entry = try self.book.authorize(self.a, target, operation_id, hash);
        }
        var parent_result: ?calendar.Applied = null;
        const parent_needed = entry.consent.parent != .none and entry.calendar_state != .applied and entry.calendar_state != .rejected and entry.calendar_state != .archived;
        if (parent_needed) {
            const inner = entry.calendar_review orelse return error.InvalidMeetContinuation;
            if (self.receipts) |receipts| if (try receipts.loadFn(receipts.context, self.a, target, operation_id)) |receipt| {
                if (!receipt.ordinary or !std.mem.eql(u8, &receipt.review_hash, &entry.consent.calendar_hash.?) or !receipt.operation.intent.eql(inner.intent)) return error.MeetReviewMismatch;
                parent_result = .{ .operation = receipt.operation };
            };
            var parent_error: []const u8 = "";
            const persistence = self.calendar.persistence orelse return error.CalendarPersistenceRequired;
            const before = try persistence.load(self.a, inner.intent.identity);
            const own_before = if (before.operation) |operation| operation.intent.eql(inner.intent) else false;
            if (parent_result == null and own_before) {
                parent_result = self.calendar.reconcile(inner) catch |err| blk: {
                    parent_error = @errorName(err);
                    break :blk null;
                };
            }
            if (parent_result == null and parent_error.len == 0 and mode == .apply) {
                try self.requireSettings();
                parent_result = self.calendar.apply(inner, inner.confirmation()) catch |err| blk: {
                    parent_error = @errorName(err);
                    break :blk null;
                };
            }
            if (parent_result) |applied| {
                entry.calendar_state = switch (applied.operation.state) {
                    .applied => .applied,
                    .rejected => .rejected,
                    .unknown => .unknown,
                    .archived => .archived,
                };
                entry.calendar_reason = applied.operation.error_code;
                entry.phase = switch (entry.calendar_state) {
                    .applied => .waiting_link,
                    .rejected => .refused,
                    .archived => .abandoned,
                    else => .waiting_calendar,
                };
                if (entry.calendar_state == .applied or entry.calendar_state == .rejected or entry.calendar_state == .archived) entry.calendar_review = null;
            } else {
                entry.phase = .waiting_calendar;
                if (parent_error.len != 0) {
                    const after = persistence.load(self.a, inner.intent.identity) catch return error.UnknownOutcome;
                    const own_after = if (after.operation) |operation| operation.intent.eql(inner.intent) else false;
                    if (own_after) {
                        entry.calendar_state = .unknown;
                    } else {
                        // No exact durable claim exists, so this failed before
                        // dispatch. Keep the source hash but report a definite refusal.
                        entry.calendar_state = .rejected;
                        entry.phase = .refused;
                        entry.calendar_review = null;
                    }
                }
                entry.calendar_reason = if (parent_error.len != 0) parent_error else "CalendarOperationNotFound";
            }
            entry = try self.book.progress(self.a, entry, entry.generation);
            if (entry.calendar_state != .applied) return .{ .entry = entry, .calendar_result = parent_result, .read_error = parent_error };
        }
        var result = try self.advanceMeet(entry, mode == .reconcile, null);
        result.calendar_result = parent_result;
        return result;
    }

    fn bind(self: Service, original: types.Entry) !Bound {
        const selected = try self.calendar.loadCalendar(original.consent.target);
        const current = try self.documentLink(selected, original.consent.event_id);
        if (original.consent.existing_code.len != 0 and !std.mem.eql(u8, current.link.code, original.consent.existing_code)) return error.MeetSpaceChanged;
        if (original.consent.conference_request_id.len != 0) {
            const conference = j.get(current.document.value, "conferenceData") orelse return error.MeetSpaceChanged;
            const creation = j.get(conference, "createRequest") orelse return error.MeetSpaceChanged;
            if (!std.mem.eql(u8, j.text(creation, "requestId"), original.consent.conference_request_id)) return error.MeetSpaceChanged;
        }
        if (original.code.len != 0 and !std.mem.eql(u8, current.link.code, original.code)) return error.MeetSpaceChanged;
        const space = try self.readSpace(original.consent.target.account, current.link.code, if (original.space_name.len != 0) original.space_name else null);
        var entry = original;
        if (entry.space_name.len == 0) {
            entry.space_name = space.name;
            entry.code = current.link.code;
            entry.phase = .ready;
            entry.reason = "";
            entry = try self.book.progress(self.a, entry, entry.generation);
        } else if (entry.reason.len != 0 and entry.phase != .unknown and entry.phase != .refused and entry.phase != .confirmed) {
            entry.reason = "";
            entry.phase = .ready;
            entry = try self.book.progress(self.a, entry, entry.generation);
        }
        return .{ .entry = entry, .space = space };
    }

    /// The parent leg is settled before this method. read_only means strictly
    /// GET on both providers, even when a waiting link becomes ready meanwhile.
    pub fn advanceMeet(self: Service, original: types.Entry, read_only: bool, next_attempt: ?u32) !Result {
        if (original.calendar_state != .applied and original.calendar_state != .unchanged) return .{ .entry = original };
        if (original.phase == .reviewed or original.phase == .confirmed or original.phase == .abandoned) return .{ .entry = original };
        const bound = self.bind(original) catch |err| {
            var entry = original;
            // A write may already have arrived. A failed GET must retain its
            // unknown claim, never reinterpret it as a known refusal or OFF.
            if (entry.phase != .unknown and entry.phase != .refused) {
                const definite = switch (err) {
                    error.MeetNotOrganizer, error.MeetSpaceChanged, error.MeetRecurringUnsupported, error.MeetLinkNotProvider, error.MeetLinkFailed => true,
                    else => false,
                };
                if (definite) entry.phase = .refused;
                entry.reason = @errorName(err);
                entry = try self.book.progress(self.a, entry, entry.generation);
            }
            return .{ .entry = entry, .read_error = @errorName(err) };
        };
        var entry = bound.entry;
        if (entry.phase == .refused) return .{ .entry = entry, .observed = bound.space, .observed_ms = self.now_ms };
        if (bound.space.matches(entry.consent.enabled)) {
            entry = try self.book.observe(self.a, entry.consent.target, entry.consent.operation_id, entry.review_hash, entry.generation, bound.space, self.now_ms);
            return .{ .entry = entry, .observed = bound.space, .observed_ms = self.now_ms };
        }
        if (read_only or (entry.phase == .unknown and next_attempt == null)) return .{ .entry = entry, .observed = bound.space, .observed_ms = self.now_ms };
        if (entry.phase == .authorized or entry.phase == .waiting_link or entry.phase == .waiting_calendar) {
            entry.phase = .ready;
            entry = try self.book.progress(self.a, entry, entry.generation);
        }
        const claim = try self.book.claim(self.a, entry.consent.target, entry.consent.operation_id, entry.review_hash, next_attempt);
        if (!claim.dispatch) return .{ .entry = claim.entry };
        entry = claim.entry;
        const request = try provider.configure(self.a, entry.consent.target.account, entry.space_name, entry.consent.enabled);
        const response = self.send(request) catch |err| {
            entry.reason = @errorName(err);
            entry = try self.book.progress(self.a, entry, entry.generation);
            return .{ .entry = entry, .read_error = @errorName(err) };
        };
        if (response.status < 200 or response.status >= 300) {
            const detail = cp.errorDetail(self.a, response.status, response.body) catch cp.ErrorDetail{ .status = response.status };
            const failure = cp.classifyFailure(.update_event, response.status, detail.reason);
            entry.phase = if (failure == .unknown) .unknown else .refused;
            entry.reason = @errorName(statusError(self.a, response.status, response.body));
            entry.provider_status = response.status;
            entry.provider_reason = detail.reason;
            entry.provider_message = detail.message;
            entry = try self.book.progress(self.a, entry, entry.generation);
            return .{ .entry = entry };
        }
        const space = provider.decode(self.a, response.body, entry.code, entry.space_name) catch |err| {
            entry.reason = @errorName(err);
            return .{ .entry = try self.book.progress(self.a, entry, entry.generation), .read_error = @errorName(err) };
        };
        if (space.matches(entry.consent.enabled)) {
            entry = try self.book.observe(self.a, entry.consent.target, entry.consent.operation_id, entry.review_hash, entry.generation, space, self.now_ms);
            return .{ .entry = entry, .observed = space, .observed_ms = self.now_ms };
        }
        entry.reason = "MeetSettingsUnconfirmed";
        return .{ .entry = try self.book.progress(self.a, entry, entry.generation), .observed = space, .observed_ms = self.now_ms };
    }
};

fn bindingError(err: anyerror) anyerror {
    return switch (err) {
        error.MeetOrganizerRequired => error.MeetNotOrganizer,
        error.MeetConferenceFailed => error.MeetLinkFailed,
        error.MeetEventUnsupported => error.MeetLinkNotProvider,
        error.MeetRecurringSpace => error.MeetRecurringUnsupported,
        error.MeetConferenceUnsupported, error.InvalidMeetLink, error.InvalidMeetCode => error.MeetLinkNotProvider,
        error.MeetEventMismatch, error.MeetEventCancelled => error.MeetSpaceChanged,
        else => err,
    };
}
fn statusError(a: std.mem.Allocator, status: u16, body: []const u8) anyerror {
    const detail = cp.errorDetail(a, status, body) catch cp.ErrorDetail{ .status = status };
    if (std.mem.eql(u8, detail.reason, "accessNotConfigured") or std.mem.eql(u8, detail.reason, "SERVICE_DISABLED")) return error.MeetApiDisabled;
    if (status == 429 or status >= 500) return error.MeetSettingsUnavailable;
    if (status == 401) return error.MeetSettingsPermissionRequired;
    if (status == 404) return error.MeetSpaceChanged;
    return error.MeetSettingsRequestRejected;
}
