//! Separate consent and continuation records. Legacy Calendar review layouts
//! and byte projections must not change to accommodate Meet settings.
const std = @import("std");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const calendar = @import("calendar_service.zig");
const provider = @import("meet_notes_provider.zig");

pub const Phase = enum { reviewed, authorized, waiting_calendar, waiting_link, ready, unknown, confirmed, refused, abandoned };
pub const CalendarState = enum { not_sent, unchanged, applied, rejected, unknown, archived };
pub const Parent = enum { none, insert, update };

pub const Consent = struct {
    target: t.Target,
    event_id: []const u8,
    operation_id: []const u8,
    enabled: bool,
    parent: Parent,
    calendar_hash: ?[32]u8 = null,
    summary: []const u8,
    calendar_name: []const u8 = "",
    time_zone: []const u8 = "UTC",
    all_day: bool = false,
    notify_guests: bool = false,
    guest_count: u16 = 0,
    start: ?t.time.Point = null,
    end: ?t.time.Point = null,
    // Existing official conferences are resolved before consent. A newly
    // generated link instead binds to its frozen Calendar createRequest ID.
    existing_etag: []const u8 = "",
    existing_code: []const u8 = "",
    existing_space: []const u8 = "",
    conference_request_id: []const u8 = "",
    before_notes: provider.Auto = .unspecified,
    before_transcription: provider.Auto = .unspecified,

    pub fn validate(self: Consent) !void {
        try self.target.validate();
        try t.text(self.event_id, 1024, false);
        try operationId(self.operation_id);
        try t.text(self.summary, 4096, true);
        try t.text(self.calendar_name, 4096, true);
        try t.time.validateZoneName(self.time_zone);
        if ((self.parent == .none) != (self.calendar_hash == null)) return error.InvalidMeetContinuation;
        if (self.existing_space.len != 0) {
            try provider.validateName(self.existing_space);
            try provider.validateCode(self.existing_code);
            try t.text(self.existing_etag, 1024, false);
            if (self.conference_request_id.len != 0) return error.InvalidMeetContinuation;
        } else {
            if (self.parent == .none or self.existing_code.len != 0 or self.existing_etag.len != 0) return error.InvalidMeetContinuation;
            try operationId(self.conference_request_id);
        }
    }
    pub fn hash(self: Consent, a: std.mem.Allocator) ![32]u8 {
        try self.validate();
        const bytes = try j.encodeAlloc(a, .{ .contract = "omagma-meet-consent-v1", .consent = self }, .{});
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        return result;
    }
};

pub const Entry = struct {
    consent: Consent,
    review_hash: [32]u8,
    /// Retain the exact legacy review until its Calendar leg settles. A plain
    /// unclaimed Calendar review may be evicted/replaced by another editor.
    calendar_review: ?calendar.Review = null,
    phase: Phase = .reviewed,
    calendar_state: CalendarState = .not_sent,
    calendar_reason: []const u8 = "",
    space_name: []const u8 = "",
    code: []const u8 = "",
    generation: u32 = 0,
    reserved_bytes: usize = 0,
    request_hash: ?[32]u8 = null,
    reason: []const u8 = "",
    provider_status: u16 = 0,
    provider_reason: []const u8 = "",
    provider_message: []const u8 = "",
    observed_notes: provider.Auto = .unspecified,
    observed_transcription: provider.Auto = .unspecified,
    observed_ms: i64 = 0,

    pub fn protected(self: Entry) bool {
        return self.calendar_state == .unknown or switch (self.phase) {
            .authorized, .waiting_calendar, .waiting_link, .ready, .unknown => true,
            else => false,
        };
    }
    pub fn validate(self: Entry, a: std.mem.Allocator, account: []const u8) !void {
        try self.consent.validate();
        const actual_hash = try self.consent.hash(a);
        if (!std.ascii.eqlIgnoreCase(self.consent.target.account, account) or !std.mem.eql(u8, &actual_hash, &self.review_hash)) return error.InvalidMeetContinuation;
        if (self.calendar_review) |review| {
            if (self.consent.parent == .none or self.consent.calendar_hash == null or
                !std.mem.eql(u8, &review.review_hash, &self.consent.calendar_hash.?) or
                !review.intent.identity.target.eql(self.consent.target) or
                !std.mem.eql(u8, review.intent.event_id, self.consent.event_id) or
                !std.mem.eql(u8, review.intent.operation_id, self.consent.operation_id) or review.ordinary_event == null) return error.InvalidMeetContinuation;
        } else if (self.consent.parent != .none and (self.calendar_state == .not_sent or self.calendar_state == .unknown)) return error.InvalidMeetContinuation;
        if (self.space_name.len != 0) {
            try provider.validateName(self.space_name);
            try provider.validateCode(self.code);
            if (self.consent.existing_space.len != 0 and (!std.mem.eql(u8, self.space_name, self.consent.existing_space) or !std.mem.eql(u8, self.code, self.consent.existing_code))) return error.InvalidMeetContinuation;
        } else if (self.code.len != 0 or self.request_hash != null or self.phase == .ready or self.phase == .unknown or self.phase == .confirmed) return error.InvalidMeetContinuation;
        if (self.phase == .unknown and (self.generation == 0 or self.request_hash == null)) return error.InvalidMeetContinuation;
        if ((self.phase == .ready or self.phase == .unknown or self.phase == .confirmed) and self.calendar_state != .applied and self.calendar_state != .unchanged) return error.InvalidMeetContinuation;
        if (self.reserved_bytes > 4 * 1024 * 1024 or (self.protected() and self.reserved_bytes == 0)) return error.InvalidMeetContinuation;
        if (self.request_hash) |expected| {
            const actual = try requestHash(a, self.consent.target.account, self.space_name, self.consent.enabled);
            if (!std.mem.eql(u8, &expected, &actual)) return error.InvalidMeetContinuation;
        }
        try t.text(self.calendar_reason, 128, true);
        try t.text(self.reason, 128, true);
        try t.text(self.provider_reason, 128, true);
        try t.text(self.provider_message, 512, true);
    }
};

pub fn operationId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidOperationId;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidOperationId;
}
pub fn requestHash(a: std.mem.Allocator, account: []const u8, name: []const u8, enabled: bool) ![32]u8 {
    const request = try provider.configure(a, account, name, enabled);
    const bytes = try j.encodeAlloc(a, request, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}
