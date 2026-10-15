//! Pure reviewed calendar decisions. A missing/partial response is never proof
//! that an import did not happen. No request is dispatched by this module.
const std = @import("std");
const t = @import("calendar_types.zig");

pub const Identity = struct {
    target: t.Target,
    uid: []const u8,
    /// Single-event imports use empty. Future recurring writes bind the
    /// normalized original occurrence, never its rescheduled start time.
    recurrence_key: []const u8 = "",
    pub fn eql(self: Identity, other: Identity) bool {
        return self.target.eql(other.target) and std.mem.eql(u8, self.uid, other.uid) and std.mem.eql(u8, self.recurrence_key, other.recurrence_key);
    }
};

pub const Intent = struct {
    operation_id: []const u8,
    identity: Identity,
    version: t.Version,
    kind: enum { import_event, insert_event, update_event, cancel_event },
    source_hash: [32]u8,
    payload_hash: [32]u8,
    event_id: []const u8 = "",
    expected_etag: []const u8 = "",

    pub fn validate(self: Intent) !void {
        try self.identity.target.validate();
        try t.text(self.identity.uid, 1024, false);
        try t.text(self.identity.recurrence_key, 1024, true);
        try t.text(self.operation_id, 128, false);
        for (self.operation_id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidOperationId;
        if (self.kind == .insert_event) try t.text(self.event_id, 1024, false);
        if (self.kind != .import_event and self.kind != .insert_event) {
            try t.text(self.event_id, 1024, false);
            try t.text(self.expected_etag, 1024, false);
        }
    }

    pub fn eql(self: Intent, other: Intent) bool {
        return self.identity.eql(other.identity) and self.kind == other.kind and
            self.version.order(other.version) == .eq and
            std.mem.eql(u8, self.operation_id, other.operation_id) and
            std.mem.eql(u8, &self.source_hash, &other.source_hash) and
            std.mem.eql(u8, &self.payload_hash, &other.payload_hash) and
            std.mem.eql(u8, self.event_id, other.event_id) and
            std.mem.eql(u8, self.expected_etag, other.expected_etag);
    }
};

pub const Operation = struct {
    intent: Intent,
    state: enum { unknown, applied, rejected, archived } = .unknown,
    provider_id: []const u8 = "",
    error_code: []const u8 = "",
    attempt: u32 = 0,
};
pub const Claim = struct {
    operation: Operation,
    /// Exactly one claimant can receive true, after durable unknown is saved.
    /// A pre-existing unknown receipt must return false and be reconciled.
    fresh: bool,
};

/// Implemented by the host's account-scoped encrypted store, not by a
/// calendar-specific plaintext cache. claimFn must atomically persist unknown
/// before returning and serialize competing intents for the same identity.
/// Claiming an identical operation returns its existing durable receipt.
pub const Journal = struct {
    context: *anyopaque,
    claimFn: *const fn (*anyopaque, Intent) anyerror!Claim,
    recordFn: *const fn (*anyopaque, Operation) anyerror!void,
    retryFn: ?*const fn (*anyopaque, Intent, u32) anyerror!Claim = null,

    pub fn claim(self: Journal, intent: Intent) !Claim {
        try intent.validate();
        const result = try self.claimFn(self.context, intent);
        const operation = result.operation;
        if (!operation.intent.eql(intent)) return error.OperationConflict;
        if (result.fresh and operation.state != .unknown) return error.OperationConflict;
        return result;
    }
    pub fn retry(self: Journal, intent: Intent, next_attempt: u32) !Claim {
        try intent.validate();
        if (next_attempt == 0 or next_attempt > 1000000) return error.InvalidCalendarRetry;
        const callback = self.retryFn orelse return error.CalendarRetryUnavailable;
        const result = try callback(self.context, intent, next_attempt);
        if (!result.operation.intent.eql(intent) or (result.fresh and (result.operation.state != .unknown or result.operation.attempt != next_attempt))) return error.OperationConflict;
        return result;
    }
    pub fn record(self: Journal, operation: Operation) !void {
        try operation.intent.validate();
        self.recordFn(self.context, operation) catch return error.UnknownOutcome;
    }
};

pub const Tracked = struct {
    identity: Identity,
    event_id: []const u8,
    version: t.Version,
    source_hash: [32]u8,
};

pub const Lookup = struct {
    target: t.Target,
    uid: []const u8,
    events: []const t.Event,
    complete: bool,
};

pub const Decision = union(enum) {
    import_missing,
    existing: t.Event,
    review_update: t.Event,
    review_cancel: t.Event,
    previously_cancelled: t.Event,
    no_event_to_cancel,
    reconcile_unknown,
    reconciled: t.Event,
    ambiguous,
    lookup_incomplete,
    identity_conflict,
    stale_source,
    unsupported_recurrence,
    time_review_required,
};

pub const Input = struct {
    invitation: t.Invitation,
    target: t.Target,
    lookup: Lookup,
    tracked: ?Tracked = null,
    operation: ?Operation = null,
    /// True only after the start/end resolver succeeds and the review uses
    /// those same resolved values. An existing event can still be inspected.
    times_resolved: bool = false,
};

pub fn plan(input: Input) !Decision {
    try input.target.validate();
    const invitation = input.invitation;
    if (!std.ascii.eqlIgnoreCase(invitation.account, input.target.account) or !input.lookup.target.eql(input.target)) return error.CalendarAccountMismatch;
    if (!std.mem.eql(u8, input.lookup.uid, invitation.uid)) return error.CalendarIdentityMismatch;
    if (input.lookup.events.len > t.Limits.snapshot_events) return error.TooManyCalendarEvents;
    var match: ?t.Event = null;
    for (input.lookup.events) |event| {
        if (!event.target.eql(input.target)) return error.CalendarAccountMismatch;
        // Deleted events may have only an ID. They cannot establish absence
        // or be imported over unless the host can bind their stored identity.
        if (!std.mem.eql(u8, event.uid, invitation.uid)) return .identity_conflict;
        if (event.organizer.len != 0 and !std.ascii.eqlIgnoreCase(event.organizer, invitation.organizer)) return .identity_conflict;
        if (match != null) return .ambiguous;
        match = event;
    }
    if (input.operation) |operation| {
        try operation.intent.validate();
        if (!operation.intent.identity.target.eql(input.target) or !std.mem.eql(u8, operation.intent.identity.uid, invitation.uid)) return error.OperationConflict;
        if (operation.state == .unknown) {
            if (match) |event| {
                // This is only an advisory; the service commits reconciliation.
                // Never tell the host that a partial lookup or a marker alone
                // proves the exact reviewed source reached the provider.
                const intent = operation.intent;
                const source_hash = std.fmt.bytesToHex(intent.source_hash, .lower);
                if (input.lookup.complete and intent.kind != .cancel_event and !event.cancelled and
                    invitation.version.order(intent.version) == .eq and std.mem.eql(u8, &invitation.source_hash, &intent.source_hash) and
                    event.sequence == intent.version.sequence and std.ascii.eqlIgnoreCase(event.organizer, invitation.organizer) and
                    std.mem.eql(u8, event.operation_marker, intent.operation_id) and std.mem.eql(u8, event.source_marker, &source_hash) and
                    (intent.kind == .import_event or std.mem.eql(u8, event.id, intent.event_id))) return .{ .reconciled = event };
            }
            return .reconcile_unknown;
        }
        if (operation.state == .applied and match == null) return .identity_conflict;
    }
    if (!input.lookup.complete) return .lookup_incomplete;
    // Reading/linking a provider recurrence is possible without implementing
    // an ICS expansion engine. Writing one must wait for its dedicated flow.
    if (invitation.isRecurring()) return if (match) |event| .{ .existing = event } else .unsupported_recurrence;
    const cancelling = invitation.method == .cancel or invitation.cancelled;
    if (input.tracked) |tracked| {
        const identity: Identity = .{ .target = input.target, .uid = invitation.uid };
        if (!tracked.identity.eql(identity)) return error.CalendarIdentityMismatch;
        if (invitation.version.order(tracked.version) == .lt) return .stale_source;
        if (match) |event| {
            if (!std.mem.eql(u8, event.id, tracked.event_id)) return .identity_conflict;
            if (event.sequence > invitation.version.sequence) return .stale_source;
            if (event.cancelled) return .{ .previously_cancelled = event };
            if (invitation.version.order(tracked.version) == .eq) return .{ .existing = event };
            if (event.locked or event.etag.len == 0) return .{ .existing = event };
            if (cancelling) return .{ .review_cancel = event };
            if (!input.times_resolved) return .time_review_required;
            return .{ .review_update = event };
        }
        // A previously tracked event disappearing must never be silently
        // resurrected from an older email, including after a manual deletion.
        return if (cancelling) .no_event_to_cancel else .identity_conflict;
    }
    if (match) |event| return if (event.cancelled) .{ .previously_cancelled = event } else .{ .existing = event };
    if (cancelling) return .no_event_to_cancel;
    if (!input.times_resolved) return .time_review_required;
    return .import_missing;
}

test "calendar: uncertain imports require complete source and version proof before advisory reconciliation" {
    const target: t.Target = .{ .account = "self@example.test", .calendar_id = "primary" };
    const invitation: t.Invitation = .{ .account = target.account, .source = "", .unfolded = "", .source_hash = @splat(0), .method = .request, .uid = "meeting@example.test", .organizer = "host@example.test", .attendee = target.account, .version = .{ .sequence = 1, .dtstamp_ms = 1000 } };
    const operation: Operation = .{ .intent = .{ .operation_id = "calendar-operation-1", .identity = .{ .target = target, .uid = invitation.uid }, .version = invitation.version, .kind = .import_event, .source_hash = @splat(0), .payload_hash = @splat(0) } };
    var input: Input = .{ .invitation = invitation, .target = target, .lookup = .{ .target = target, .uid = invitation.uid, .events = &.{}, .complete = true }, .operation = operation, .times_resolved = true };
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    input.lookup.events = &.{.{ .target = target, .id = "existing", .uid = invitation.uid, .organizer = invitation.organizer, .operation_marker = operation.intent.operation_id }};
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    const hash = std.fmt.bytesToHex(operation.intent.source_hash, .lower);
    var event = input.lookup.events[0];
    event.source_marker = &hash;
    event.sequence = operation.intent.version.sequence;
    input.lookup.events = &.{event};
    try std.testing.expectEqual(std.meta.Tag(Decision).reconciled, std.meta.activeTag(try plan(input)));
    input.lookup.complete = false;
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    input.lookup.complete = true;
    event.sequence += 1;
    input.lookup.events = &.{event};
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    event.sequence -= 1;
    input.lookup.events = &.{event};
    input.invitation.version.dtstamp_ms += 1;
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    input.invitation = invitation;
    input.invitation.source_hash[0] = 1;
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    input.invitation = invitation;
    var update = operation;
    update.intent.kind = .update_event;
    update.intent.event_id = "different-event";
    update.intent.expected_etag = "\"v1\"";
    input.operation = update;
    try std.testing.expectEqual(std.meta.Tag(Decision).reconcile_unknown, std.meta.activeTag(try plan(input)));
    input.operation = null;
    try std.testing.expectEqual(std.meta.Tag(Decision).existing, std.meta.activeTag(try plan(input)));
    input.lookup.events = &.{};
    input.lookup.complete = false;
    try std.testing.expectEqual(std.meta.Tag(Decision).lookup_incomplete, std.meta.activeTag(try plan(input)));
}
