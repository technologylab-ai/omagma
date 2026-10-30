//! Pure, bounded native Calendar editor. The TUI owns focus and text editing;
//! this module owns civil-date semantics and the exact reviewed request.
//! No credentials, network, timezone file loading, or provider writes live here.
const std = @import("std");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const tz = @import("timezone.zig");
const reader = @import("reader_tools.zig");
const recipients = @import("recipients.zig");

pub const max_guests = 200;
pub const guest_bytes = max_guests * 256;
pub const Field = enum {
    summary,
    start_date,
    start_time,
    end_date,
    end_time,
    time_zone,
    location,
    description,
    attendees,
    join_url,
    start_offset,
    end_offset,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .summary => "Title",
            .start_date => "Start date",
            .start_time => "Start time",
            .end_date => "End date",
            .end_time => "End time",
            .time_zone => "Time zone",
            .location => "Location",
            .description => "Notes",
            .attendees => "Guests",
            .join_url => "Meeting link",
            .start_offset => "Start UTC offset",
            .end_offset => "End UTC offset",
        };
    }

    pub fn limit(self: Field) usize {
        return switch (self) {
            .summary => 4096,
            .start_date, .end_date => 10,
            .start_time, .end_time => 12,
            .time_zone => 512,
            .location => 4096,
            .description => 65536,
            .attendees => guest_bytes,
            .join_url => 4096,
            .start_offset, .end_offset => 6,
        };
    }
};
pub const field_count = @typeInfo(Field).@"enum".field_names.len;
pub const Conference = enum {
    none,
    google_meet,
    link,

    pub fn label(self: Conference) []const u8 {
        return switch (self) {
            .none => "No new video link",
            .google_meet => "Create Google Meet",
            .link => "Use a meeting link",
        };
    }
};
pub const SendUpdates = enum { none, all };
const Notes = struct {
    bytes: [65536]u8 = @splat(0),
    len: u32 = 0,
    pub fn slice(self: *const Notes) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn set(self: *Notes, raw: []const u8) !void {
        if (raw.len > self.bytes.len) return error.CapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        @memcpy(self.bytes[0..raw.len], raw);
        self.len = @intCast(raw.len);
    }
};
pub const Init = struct {
    target: t.Target,
    /// Selected civil day, in days since epoch. This is not UTC midnight.
    day: i64,
    now_ms: i64,
    zone_name: []const u8,
    zone: *const tz.Zone,
    writable: bool = true,
    supports_meet: bool = false,
};

pub const Model = struct {
    summary: b.Text(4096) = .{},
    start_date: b.Text(10) = .{},
    start_time: b.Text(12) = .{},
    end_date: b.Text(10) = .{},
    end_time: b.Text(12) = .{},
    time_zone: b.Text(512) = .{},
    location: b.Text(4096) = .{},
    description: Notes = .{},
    attendees: b.Text(guest_bytes) = .{},
    join_url: b.Text(4096) = .{},
    start_offset: b.Text(6) = .{},
    end_offset: b.Text(6) = .{},
    account: b.Text(254) = .{},
    calendar_id: b.Text(1024) = .{},
    event_id: b.Text(1024) = .{},
    expected_etag: b.Text(1024) = .{},
    protected_join_url: b.Text(4096) = .{},
    /// Used only to decide whether the attendee field was actually changed.
    /// Provider attendee properties/RSVPs are preserved by omitting unchanged
    /// attendees; the backend merges additions without replacing old objects.
    original_attendees: b.Text(guest_bytes) = .{},
    all_day: bool = false,
    conference: Conference = .none,
    send_updates: SendUpdates = .none,
    editing: bool = false,
    writable: bool = true,
    supports_meet: bool = false,
    existing_join: bool = false,
    attendees_complete: bool = true,
    notes_read_only: bool = false,
    original_guest_count: usize = 0,

    pub fn init(a: std.mem.Allocator, options: Init) !Model {
        try options.target.validate();
        try t.time.validateZoneName(options.zone_name);
        var out: Model = .{ .writable = options.writable, .supports_meet = options.supports_meet };
        try out.account.set(options.target.account);
        try out.calendar_id.set(options.target.calendar_id);
        try out.time_zone.set(options.zone_name);
        // New events on another day start at 09:00. On today, use the next
        // half-hour, allowing a genuine overnight interval near midnight.
        const today = try options.zone.localDay(options.now_ms);
        var start_day = options.day;
        var minute: i64 = 9 * 60;
        if (start_day == today) {
            const seconds = @divFloor(options.now_ms, 1000);
            const wall = seconds + try options.zone.offsetSeconds(seconds);
            minute = (@divFloor(@mod(wall, 86400), 1800) + 1) * 30;
            start_day += @divFloor(minute, 1440);
            minute = @mod(minute, 1440);
        }
        try out.start_date.set(try t.time.format(a, .{ .kind = .date, .value = start_day }));
        try out.end_date.set(try t.time.format(a, .{ .kind = .date, .value = start_day + @divFloor(minute + 60, 1440) }));
        try out.start_time.set(try minuteText(a, minute));
        try out.end_time.set(try minuteText(a, @mod(minute + 60, 1440)));
        return out;
    }

    /// `response` is the complete calendar.event read result. Its eventDraft
    /// is provider-normalized local time, including seconds and fold offsets;
    /// never reconstruct an editable meeting from a partial agenda snapshot.
    pub fn initEdit(a: std.mem.Allocator, options: Init, response: j.Value) !Model {
        if (!options.writable or !try j.boolean(response, "canEdit", false)) return error.CalendarReadOnly;
        const event = j.get(response, "event") orelse return error.CalendarEventNeedsRefresh;
        const draft = j.get(response, "eventDraft") orelse return error.CalendarEventNeedsRefresh;
        try options.target.validate();
        var out: Model = .{ .editing = true, .writable = options.writable, .supports_meet = options.supports_meet };
        try out.account.set(options.target.account);
        try out.calendar_id.set(options.target.calendar_id);
        try out.start_time.set("09:00");
        try out.end_time.set("10:00");
        try out.event_id.set(try j.required(event, "id"));
        try out.expected_etag.set(try j.required(event, "etag"));
        if (j.get(event, "target")) |target| {
            if (!std.ascii.eqlIgnoreCase(j.text(target, "account"), options.target.account) or !std.mem.eql(u8, j.text(target, "calendar_id"), options.target.calendar_id)) return error.CalendarAccountMismatch;
        }
        out.all_day = try j.boolean(draft, "allDay", false);
        try out.set(.summary, j.text(draft, "summary"));
        try out.set(.time_zone, try j.required(draft, "timeZone"));
        try out.set(.location, j.text(draft, "location"));
        try out.set(.description, j.text(draft, "description"));
        try out.prefillEndpoint(a, true, try j.required(draft, "start"));
        try out.prefillEndpoint(a, false, try j.required(draft, "end"));
        try out.set(.start_offset, j.text(draft, "startOffset"));
        try out.set(.end_offset, j.text(draft, "endOffset"));
        out.existing_join = j.text(event, "join_url").len > 0 or
            ((try j.boolean(event, "conference_present", false) or std.mem.eql(u8, j.text(event, "conference_status"), "pending")) and !std.mem.eql(u8, j.text(event, "conference_status"), "failure"));
        out.notes_read_only = @import("calendar_event.zig").htmlDescription(out.description.slice());
        const join = j.text(event, "join_url");
        if (join.len > 0 and std.mem.indexOf(u8, out.description.slice(), join) != null) try out.protected_join_url.set(join);
        out.attendees_complete = !try j.boolean(event, "attendees_omitted", false);
        var guests: std.ArrayList(u8) = .empty;
        defer guests.deinit(a);
        const draft_guests = j.get(draft, "attendees") orelse @as(j.Value, .null);
        const displayed_guests = if (draft_guests == .null and !out.attendees_complete) j.get(event, "attendees") orelse @as(j.Value, .null) else draft_guests;
        if (displayed_guests != .null) {
            const values = displayed_guests;
            if (values != .array or values.array.items.len > max_guests) return error.CalendarTooManyGuests;
            for (values.array.items) |value| {
                const email = try j.string(value);
                if (guests.items.len > 0) try guests.appendSlice(a, ", ");
                if (guests.items.len + email.len > guest_bytes) return error.CalendarTooManyGuests;
                try guests.appendSlice(a, email);
            }
        }
        try out.set(.attendees, guests.items);
        try out.original_attendees.set(guests.items);
        const provider_count = try j.integer(event, "attendee_count", @intCast(if (displayed_guests == .array) displayed_guests.array.items.len else 0));
        if (provider_count < 0 or provider_count > std.math.maxInt(u32)) return error.InvalidCalendarResponse;
        out.original_guest_count = @intCast(provider_count);
        if (displayed_guests == .array and out.original_guest_count < displayed_guests.array.items.len) return error.InvalidCalendarResponse;
        return out;
    }

    /// Restore the exact locally saved review for read-only unknown-outcome
    /// recovery. This does not refresh an event, acquire permission, dispatch a
    /// request, or turn an uncertain operation into a new write. The TUI keeps
    /// the saved operation/hash and its recovery-only controls separately.
    pub fn initReview(a: std.mem.Allocator, options: Init, review: j.Value) !Model {
        try options.target.validate();
        const target: t.Target = .{ .account = try j.required(review, "account"), .calendar_id = try j.required(review, "calendarId") };
        if (!target.eql(options.target)) return error.CalendarAccountMismatch;
        try operationId(try j.required(review, "operationId"));
        const draft = j.get(review, "event") orelse return error.CalendarReviewMismatch;
        if (draft != .object) return error.CalendarReviewMismatch;
        const previous = j.get(review, "previous") orelse @as(j.Value, .null);
        const action = try j.required(review, "action");
        const editing = std.mem.eql(u8, action, "update_event");
        if ((!editing and !std.mem.eql(u8, action, "create_event")) or editing != (previous != .null)) return error.CalendarReviewMismatch;
        var out: Model = if (editing) edit: {
            if (!std.mem.eql(u8, j.text(previous, "id"), try j.required(review, "eventId")) or
                !std.mem.eql(u8, j.text(previous, "etag"), try j.required(review, "expectedEtag"))) return error.CalendarReviewMismatch;
            // The review can contain additions; original attendees must come
            // from the previous provider snapshot, never the desired draft.
            var bootstrap = try j.copyObject(a, draft);
            try bootstrap.object.put(a, "attendees", if (try j.boolean(previous, "attendees_omitted", false)) @as(j.Value, .null) else j.get(previous, "attendees") orelse @as(j.Value, .null));
            var readable = options;
            readable.writable = true;
            break :edit try initEdit(a, readable, try j.value(a, .{ .canEdit = true, .event = previous, .eventDraft = bootstrap }));
        } else .{ .supports_meet = options.supports_meet };
        out.writable = options.writable;
        try out.account.set(target.account);
        try out.calendar_id.set(target.calendar_id);
        try out.event_id.set(try j.required(review, "eventId"));
        if (editing) try out.expected_etag.set(try j.required(review, "expectedEtag"));
        out.all_day = try j.boolean(draft, "allDay", false);
        if (!editing) {
            try out.start_time.set("09:00");
            try out.end_time.set("10:00");
        }
        try out.set(.summary, try j.required(draft, "summary"));
        try out.set(.time_zone, try j.required(draft, "timeZone"));
        try out.prefillEndpoint(a, true, try j.required(draft, "start"));
        try out.prefillEndpoint(a, false, try j.required(draft, "end"));
        try out.set(.start_offset, j.text(draft, "startOffset"));
        try out.set(.end_offset, j.text(draft, "endOffset"));
        try out.set(.location, j.text(draft, "location"));
        try out.set(.description, j.text(draft, "description"));
        out.conference = std.meta.stringToEnum(Conference, j.text(draft, "conference")) orelse return error.CalendarReviewMismatch;
        out.send_updates = std.meta.stringToEnum(SendUpdates, try j.required(review, "sendUpdates")) orelse return error.CalendarReviewMismatch;
        try out.set(.join_url, j.text(draft, "joinUrl"));
        if (j.get(draft, "attendees")) |values| if (values != .null) {
            if (values != .array or values.array.items.len > max_guests) return error.CalendarTooManyGuests;
            var guests: std.ArrayList(u8) = .empty;
            defer guests.deinit(a);
            for (values.array.items) |value| {
                const email = try j.string(value);
                if (guests.items.len > 0) try guests.appendSlice(a, ", ");
                if (guests.items.len + email.len > guest_bytes) return error.CalendarTooManyGuests;
                try guests.appendSlice(a, email);
            }
            try out.set(.attendees, guests.items);
        };
        return out;
    }

    fn prefillEndpoint(self: *Model, a: std.mem.Allocator, start: bool, raw: []const u8) !void {
        const date_field: Field = if (start) .start_date else .end_date;
        const time_field: Field = if (start) .start_time else .end_time;
        if (self.all_day) {
            const day = try dateDay(raw);
            // The editor explicitly includes the last day; Calendar end dates
            // are exclusive. Reverse exactly once when opening an event.
            try self.set(date_field, try t.time.format(a, .{ .kind = .date, .value = day - @as(i64, if (start) 0 else 1) }));
        } else {
            if (raw.len < 16 or raw[10] != 'T') return error.CalendarInvalidTime;
            _ = try dateDay(raw[0..10]);
            _ = try clockMilliseconds(raw[11..]);
            try self.set(date_field, raw[0..10]);
            try self.set(time_field, raw[11..]);
        }
    }

    pub fn get(self: *const Model, field: Field) []const u8 {
        return switch (field) {
            inline else => |tag| @field(self, @tagName(tag)).slice(),
        };
    }

    pub fn set(self: *Model, field: Field, raw: []const u8) !void {
        if (raw.len > field.limit()) return error.CalendarFieldTooLong;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        for (raw) |byte| {
            if ((byte < 32 or byte == 127) and !((field == .description or field == .attendees) and (byte == '\n' or byte == '\r' or byte == '\t'))) return error.InvalidCalendarField;
        }
        const changed = !std.mem.eql(u8, self.get(field), raw);
        if (!changed) return;
        if (field == .description and self.notes_read_only) return error.CalendarFormattedNotesReadOnly;
        switch (field) {
            inline else => |tag| try @field(self, @tagName(tag)).set(raw),
        }
        if (changed) switch (field) {
            .start_date, .start_time => self.start_offset.len = 0,
            .end_date, .end_time => self.end_offset.len = 0,
            .time_zone => {
                self.start_offset.len = 0;
                self.end_offset.len = 0;
            },
            else => {},
        };
    }

    pub fn visible(self: *const Model, field: Field) bool {
        return switch (field) {
            .start_time, .end_time, .time_zone, .start_offset, .end_offset => !self.all_day,
            .join_url => self.conference == .link,
            else => true,
        };
    }

    pub fn label(self: *const Model, field: Field) []const u8 {
        return if (field == .end_date and self.all_day) "Last date (included)" else field.label();
    }

    pub fn editable(self: *const Model, field: Field) bool {
        return self.writable and self.visible(field) and (field != .attendees or self.attendees_complete) and (field != .description or !self.notes_read_only);
    }

    pub fn setTarget(self: *Model, target: t.Target, writable: bool, supports_meet: bool) !void {
        try target.validate();
        if (self.editing and (!std.ascii.eqlIgnoreCase(self.account.slice(), target.account) or !std.mem.eql(u8, self.calendar_id.slice(), target.calendar_id))) return error.CalendarEditTargetFixed;
        try self.account.set(target.account);
        try self.calendar_id.set(target.calendar_id);
        self.writable = writable;
        self.supports_meet = supports_meet;
    }

    /// Invite policy follows actual new mailboxes, never formatting changes
    /// such as reordering, whitespace, case or display names in the editor.
    /// Parsed lists are scratch in a local arena over `a`; only the count
    /// leaves this call, so `a` may be any allocator.
    pub fn addedGuestCount(self: *const Model, a: std.mem.Allocator) !usize {
        var scratch: std.heap.ArenaAllocator = .init(a);
        defer scratch.deinit();
        const guests = try parseGuests(scratch.allocator(), self.attendees.slice());
        const originals = try parseGuests(scratch.allocator(), self.original_attendees.slice());
        return newGuestCount(guests, originals);
    }

    /// Actual provider count includes guests omitted from a bounded read.
    /// The TUI uses this to require an explicit email/no-email edit choice.
    pub fn existingGuestCount(self: *const Model) usize {
        return self.original_guest_count;
    }

    /// This allocates an owned JSON value. Editing can continue without
    /// changing a submitted review; the backend separately binds its hash.
    pub fn reviewRequest(self: *const Model, a: std.mem.Allocator, operation_id: []const u8) !j.Value {
        if (!self.writable) return error.CalendarReadOnly;
        try (t.Target{ .account = self.account.slice(), .calendar_id = self.calendar_id.slice() }).validate();
        try operationId(operation_id);
        const title = std.mem.trim(u8, self.summary.slice(), " \t\n");
        if (title.len == 0) return error.CalendarTitleRequired;
        // DATE endpoints do not depend on timezone rules. Retain the user's
        // timed zone in the editor, but never let an irrelevant hidden field
        // block an all-day event or reinterpret its civil dates.
        const request_zone = if (self.all_day) @as([]const u8, "UTC") else self.time_zone.slice();
        if (!self.all_day) try t.time.validateZoneName(request_zone);
        const first_day = dateDay(self.start_date.slice()) catch return error.CalendarInvalidStartDate;
        const last_day = dateDay(self.end_date.slice()) catch return error.CalendarInvalidEndDate;
        var start: []const u8 = undefined;
        var end: []const u8 = undefined;
        var start_offset: ?[]const u8 = null;
        var end_offset: ?[]const u8 = null;
        if (self.all_day) {
            if (last_day < first_day) return error.CalendarEndBeforeStart;
            start = self.start_date.slice();
            end = t.time.format(a, .{ .kind = .date, .value = last_day + 1 }) catch return error.CalendarInvalidEndDate;
        } else {
            const first_ms = clockMilliseconds(self.start_time.slice()) catch return error.CalendarInvalidStartTime;
            const last_ms = clockMilliseconds(self.end_time.slice()) catch return error.CalendarInvalidEndTime;
            start_offset = optional(self.start_offset.slice());
            end_offset = optional(self.end_offset.slice());
            const first_shift = if (start_offset) |raw| try offsetSeconds(raw) else 0;
            const last_shift = if (end_offset) |raw| try offsetSeconds(raw) else 0;
            const first_wall = first_day * 86400000 + first_ms;
            const last_wall = last_day * 86400000 + last_ms;
            // An explicit fold choice may make 02:15 follow 02:45. Compare
            // real instants only when both offsets are known; the backend
            // verifies those offsets against the chosen IANA rules.
            if (start_offset != null and end_offset != null) {
                if (last_wall - @as(i64, last_shift) * 1000 <= first_wall - @as(i64, first_shift) * 1000) return error.CalendarEndBeforeStart;
            } else if (last_wall <= first_wall) return error.CalendarEndBeforeStart;
            start = try std.fmt.allocPrint(a, "{s}T{s}", .{ self.start_date.slice(), self.start_time.slice() });
            end = try std.fmt.allocPrint(a, "{s}T{s}", .{ self.end_date.slice(), self.end_time.slice() });
        }
        // Parsed lists are scratch: j.value below copies the addresses it keeps.
        var scratch: std.heap.ArenaAllocator = .init(a);
        defer scratch.deinit();
        const guests = try parseGuests(scratch.allocator(), self.attendees.slice());
        const originals = try parseGuests(scratch.allocator(), self.original_attendees.slice());
        const changed = !sameGuests(guests, originals);
        if (self.editing and changed) {
            if (!self.attendees_complete) return error.CalendarGuestsNeedRefresh;
            for (originals) |email| if (!containsGuest(guests, email)) return error.CalendarExistingGuestsMustBePreserved;
        }
        if (newGuestCount(guests, originals) > 0 and self.send_updates != .all) return error.CalendarGuestsRequireUpdates;
        if (self.conference != .none and self.existing_join) return error.CalendarExistingConference;
        if (self.conference == .google_meet and !self.supports_meet) return error.CalendarMeetUnavailable;
        if (self.conference == .link and (!std.mem.startsWith(u8, self.join_url.slice(), "https://") or !reader.safeUrl(self.join_url.slice()))) return error.CalendarUnsafeJoinLink;
        if (self.protected_join_url.len > 0 and std.mem.indexOf(u8, self.description.slice(), self.protected_join_url.slice()) == null) return error.CalendarExistingMeetingLinkRequired;
        if (self.editing and (self.event_id.len == 0 or self.expected_etag.len == 0)) return error.CalendarEventNeedsRefresh;
        return j.value(a, .{
            .cmd = "calendar.event-review",
            .account = self.account.slice(),
            .calendarId = self.calendar_id.slice(),
            .operationId = operation_id,
            .eventId = if (self.editing) optional(self.event_id.slice()) else null,
            .expectedEtag = if (self.editing) optional(self.expected_etag.slice()) else null,
            .sendUpdates = @tagName(self.send_updates),
            .event = .{
                .summary = title,
                .start = start,
                .end = end,
                .timeZone = request_zone,
                .allDay = self.all_day,
                .description = self.description.slice(),
                .location = self.location.slice(),
                .attendees = if (!self.editing or changed) @as(?[]const []const u8, guests) else null,
                .conference = @tagName(self.conference),
                .joinUrl = if (self.conference == .link) optional(self.join_url.slice()) else null,
                .startOffset = start_offset,
                .endOffset = end_offset,
            },
        });
    }
};

fn optional(raw: []const u8) ?[]const u8 {
    return if (raw.len == 0) null else raw;
}

fn minuteText(a: std.mem.Allocator, minute: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ @as(u8, @intCast(@divFloor(minute, 60))), @as(u8, @intCast(@mod(minute, 60))) });
}

fn dateDay(raw: []const u8) !i64 {
    // The CLI and the editor deliberately use one unambiguous ISO spelling.
    if (raw.len != 10 or raw[4] != '-' or raw[7] != '-') return error.CalendarInvalidDate;
    return tz.dateDay(raw);
}

fn clockMilliseconds(raw: []const u8) !i64 {
    if (raw.len != 5 and raw.len != 8 and (raw.len < 10 or raw.len > 12)) return error.CalendarInvalidTime;
    if (raw[2] != ':' or (raw.len >= 8 and raw[5] != ':') or (raw.len >= 10 and raw[8] != '.')) return error.CalendarInvalidTime;
    for (raw, 0..) |byte, index| if (index != 2 and index != 5 and index != 8 and !std.ascii.isDigit(byte)) return error.CalendarInvalidTime;
    const hour = std.fmt.parseInt(u8, raw[0..2], 10) catch return error.CalendarInvalidTime;
    const minute = std.fmt.parseInt(u8, raw[3..5], 10) catch return error.CalendarInvalidTime;
    const second = if (raw.len >= 8) std.fmt.parseInt(u8, raw[6..8], 10) catch return error.CalendarInvalidTime else 0;
    const fraction = if (raw.len >= 10) std.fmt.parseInt(u16, raw[9..], 10) catch return error.CalendarInvalidTime else 0;
    const millis = fraction * @as(u16, if (raw.len == 10) 100 else if (raw.len == 11) 10 else 1);
    if (hour > 23 or minute > 59 or second > 59) return error.CalendarInvalidTime;
    return (@as(i64, hour) * 3600 + @as(i64, minute) * 60 + second) * 1000 + millis;
}

fn offsetSeconds(raw: []const u8) !i32 {
    if (raw.len != 6 or (raw[0] != '+' and raw[0] != '-') or raw[3] != ':') return error.CalendarInvalidOffset;
    for ([_]usize{ 1, 2, 4, 5 }) |index| if (!std.ascii.isDigit(raw[index])) return error.CalendarInvalidOffset;
    const hours = std.fmt.parseInt(i32, raw[1..3], 10) catch return error.CalendarInvalidOffset;
    const minutes = std.fmt.parseInt(i32, raw[4..6], 10) catch return error.CalendarInvalidOffset;
    if (hours > 23 or minutes > 59) return error.CalendarInvalidOffset;
    return (hours * 3600 + minutes * 60) * @as(i32, if (raw[0] == '-') -1 else 1);
}

fn operationId(raw: []const u8) !void {
    if (raw.len == 0 or raw.len > 128) return error.InvalidOperationId;
    for (raw) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidOperationId;
}

/// Guests accept the ordinary Mail address-list grammar (display names,
/// quoted commas, comments) and become bare addresses. Calendar keeps its own
/// policy: at most 200 guests, a repeated mailbox is refused rather than
/// merged, and nothing invalid is dropped. Storage is two allocations bounded
/// by the field (200 slices and `raw.len` bytes), freed on every error; on
/// success the result belongs to `a`, which callers make a local arena.
fn parseGuests(a: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    // Mail's header-injection boundary: a line break is never list
    // whitespace, even in an otherwise blank field.
    if (std.mem.indexOfAny(u8, raw, "\r\n") != null) return error.CalendarInvalidGuest;
    if (std.mem.trim(u8, raw, " \t").len == 0) return &.{};
    const list = try a.alloc([]const u8, max_guests);
    errdefer a.free(list);
    const bytes = try a.alloc(u8, raw.len);
    errdefer a.free(bytes);
    var sink: GuestSink = .{ .list = list, .bytes = bytes };
    recipients.scanAddresses(raw, &sink) catch |err| return switch (err) {
        error.CalendarTooManyGuests, error.CalendarDuplicateGuest => err,
        else => error.CalendarInvalidGuest,
    };
    return list[0..sink.count];
}
const GuestSink = struct {
    list: [][]const u8,
    bytes: []u8,
    count: usize = 0,
    used: usize = 0,
    /// Public: recipients.scanAddresses calls it from another file.
    pub fn visit(self: *GuestSink, email: []const u8) !void {
        // `bounded.address` intentionally serves older mail APIs as well. A
        // normalized guest is one bare mailbox, never list/display syntax.
        b.address(email) catch return error.CalendarInvalidGuest;
        if (std.mem.indexOfAny(u8, email, "<>(),;:") != null) return error.CalendarInvalidGuest;
        if (self.count == self.list.len) return error.CalendarTooManyGuests;
        if (containsGuest(self.list[0..self.count], email)) return error.CalendarDuplicateGuest;
        // An address never exceeds its own token, so `raw.len` bytes suffice.
        if (email.len > self.bytes.len - self.used) return error.CalendarInvalidGuest;
        const copy = self.bytes[self.used..][0..email.len];
        @memcpy(copy, email);
        self.used += email.len;
        self.list[self.count] = copy;
        self.count += 1;
    }
};

/// Ordinary end-following policy for the editor. Until the user edits End
/// date, End time or the end's DST occurrence, a valid Start edit moves the
/// end by the interval shown just before that edit: wall-clock length for
/// timed events (so 09:00–10:00 stays one hour on any date, including across
/// a DST change) and the number of extra included days for all-day events.
/// A partial or invalid start leaves the end untouched. After an end edit
/// the end is never moved again in that editor session. Offsets are never
/// chosen here: a moved end loses its inherited offset (Model.set), and the
/// review still asks when a wall time is skipped or occurs twice.
pub const EndFollow = struct {
    /// Set by an explicit end edit; only a newly opened editor clears it.
    pinned: bool = false,
    /// Last valid interval: milliseconds (timed) or days (all-day).
    span: ?i64 = null,
    span_all_day: bool = false,

    pub const Fields = struct { start_date: []const u8, start_time: []const u8, end_date: []const u8, end_time: []const u8 };
    pub const End = struct { date: []const u8, time: []const u8 };

    /// Call before applying a user edit to Start date or Start time.
    pub fn observe(self: *EndFollow, all_day: bool, fields: Fields) void {
        if (self.pinned) return;
        if (shownInterval(all_day, fields)) |value| {
            self.span = value;
            self.span_all_day = all_day;
        } else if (self.span_all_day != all_day) self.span = null;
    }

    /// The end after a start edit, or null to keep the current end. Both
    /// strings are allocated in `a` and owned by the caller; an allocation
    /// failure frees whatever this call already allocated.
    pub fn follow(self: *const EndFollow, a: std.mem.Allocator, all_day: bool, fields: Fields) !?End {
        if (self.pinned or self.span_all_day != all_day) return null;
        const span = self.span orelse return null;
        const day = dateDay(fields.start_date) catch return null;
        if (all_day) {
            const date = (try followedDate(a, day + span)) orelse return null;
            errdefer a.free(date);
            return .{ .date = date, .time = try a.dupe(u8, fields.end_time) };
        }
        const clock = clockMilliseconds(fields.start_time) catch return null;
        const end = day * 86400000 + clock + span;
        const date = (try followedDate(a, @divFloor(end, 86400000))) orelse return null;
        errdefer a.free(date);
        return .{ .date = date, .time = try clockText(a, @mod(end, 86400000)) };
    }
};

fn shownInterval(all_day: bool, fields: EndFollow.Fields) ?i64 {
    const first = dateDay(fields.start_date) catch return null;
    const last = dateDay(fields.end_date) catch return null;
    if (all_day) return if (last >= first) last - first else null;
    const first_ms = clockMilliseconds(fields.start_time) catch return null;
    const last_ms = clockMilliseconds(fields.end_time) catch return null;
    const value = (last - first) * 86400000 + last_ms - first_ms;
    return if (value > 0) value else null;
}

/// Null only for a date outside the editor's range; allocation failure is
/// an error, never a silent "keep the old end".
fn followedDate(a: std.mem.Allocator, day: i64) !?[]const u8 {
    const raw = t.time.format(a, .{ .kind = .date, .value = day }) catch |err| {
        const failure: anyerror = err;
        if (failure == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    _ = dateDay(raw) catch {
        a.free(raw);
        return null;
    };
    return raw;
}

/// Formats the end as HH:MM, HH:MM:SS or HH:MM:SS.mmm without losing its value.
fn clockText(a: std.mem.Allocator, ms: i64) ![]const u8 {
    const value: u64 = @intCast(ms);
    const hour = value / 3600000;
    const minute = value / 60000 % 60;
    const second = value / 1000 % 60;
    const fraction = value % 1000;
    if (fraction != 0) return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hour, minute, second, fraction });
    if (second != 0) return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second });
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ hour, minute });
}

fn containsGuest(values: []const []const u8, wanted: []const u8) bool {
    for (values) |email| if (std.ascii.eqlIgnoreCase(email, wanted)) return true;
    return false;
}

fn newGuestCount(values: []const []const u8, previous: []const []const u8) usize {
    var count: usize = 0;
    for (values) |email| if (!containsGuest(previous, email)) {
        count += 1;
    };
    return count;
}

fn sameGuests(first: []const []const u8, second: []const []const u8) bool {
    if (first.len != second.len) return false;
    for (first) |email| if (!containsGuest(second, email)) return false;
    return true;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.CalendarReadOnly => "Choose a calendar you can edit.",
        error.CalendarTitleRequired => "Enter a title for this event.",
        error.CalendarInvalidStartDate => "Start date must be a valid YYYY-MM-DD date.",
        error.CalendarInvalidEndDate => "End date must be a valid YYYY-MM-DD date.",
        error.CalendarInvalidStartTime => "Start time must be HH:MM (optional seconds).",
        error.CalendarInvalidEndTime => "End time must be HH:MM (optional seconds).",
        error.CalendarEndBeforeStart => "End must be after start. For overnight events, use the next date.",
        error.InvalidTimezoneName => "Enter an IANA time zone, such as Europe/Vienna.",
        error.CalendarInvalidOffset => "UTC offsets must be +HH:MM or -HH:MM.",
        error.CalendarInvalidGuest => "Check guests: emails or Name <email>, separated by commas.",
        error.CalendarDuplicateGuest => "A guest email address appears more than once.",
        error.CalendarTooManyGuests => "This event has more than 200 guests.",
        error.CalendarGuestsRequireUpdates => "Choose Notify guests to send invitations to new guests.",
        error.CalendarExistingGuestsMustBePreserved => "Existing guests must be kept; this editor supports adding guests.",
        error.CalendarGuestsNeedRefresh => "Refresh the complete event before changing its guest list.",
        error.CalendarExistingConference => "This event already has a meeting link; it will be preserved.",
        error.CalendarExistingMeetingLinkRequired => "Keep the existing meeting link in Notes; other participants still use it.",
        error.CalendarFormattedNotesReadOnly => "Formatted notes are kept unchanged. Edit them in Google Calendar.",
        error.CalendarMeetUnavailable => "Google Meet is unavailable for this calendar. Paste another meeting link instead.",
        error.CalendarUnsafeJoinLink => "Paste a complete HTTPS meeting link without credentials or spaces.",
        error.CalendarEventNeedsRefresh => "Refresh the event before editing it.",
        error.CalendarEditTargetFixed => "An existing event stays in its original account and calendar.",
        error.CalendarFieldTooLong => "The field is too long. Shorten it before reviewing.",
        else => "Check the event fields before reviewing.",
    };
}

fn fixture(a: std.mem.Allocator) !Model {
    const zone: tz.Zone = .{};
    var model = try Model.init(a, .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = try tz.dateDay("2026-10-24"), .now_ms = try t.time.rfc3339("2026-10-15T10:00:00Z"), .zone_name = "UTC", .zone = &zone, .supports_meet = true });
    try model.set(.summary, "Planning");
    return model;
}

test "calendar composer: all-day UI dates include the last date across DST leap and year boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    model.all_day = true;
    try model.set(.time_zone, "Europe/Vienna");
    for ([_][3][]const u8{
        .{ "2026-10-24", "2026-10-26", "2026-10-27" },
        .{ "2028-02-29", "2028-02-29", "2028-03-01" },
        .{ "2026-12-31", "2027-01-01", "2027-01-02" },
    }) |dates| {
        try model.set(.start_date, dates[0]);
        try model.set(.end_date, dates[1]);
        const request = try model.reviewRequest(a, "operation-1");
        const event = j.get(request, "event").?;
        try std.testing.expectEqualStrings(dates[0], j.text(event, "start"));
        try std.testing.expectEqualStrings(dates[2], j.text(event, "end"));
        try std.testing.expect(j.get(event, "startOffset") == null);
    }
    try model.set(.end_date, "2026-12-30");
    try std.testing.expectError(error.CalendarEndBeforeStart, model.reviewRequest(a, "operation-1"));
    try model.set(.end_date, "9999-12-31");
    try std.testing.expectError(error.CalendarInvalidEndDate, model.reviewRequest(a, "operation-1"));
}

test "calendar composer: overnight intervals require a later date and fold offsets compare actual time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.set(.start_time, "23:30");
    try model.set(.end_time, "00:30");
    try std.testing.expectError(error.CalendarEndBeforeStart, model.reviewRequest(a, "operation-2"));
    try model.set(.end_date, "2026-10-25");
    const overnight = try model.reviewRequest(a, "operation-2");
    try std.testing.expectEqualStrings("2026-10-25T00:30", j.text(j.get(overnight, "event").?, "end"));
    try model.set(.start_date, "2026-10-25");
    try model.set(.start_time, "02:45");
    try model.set(.end_time, "02:15");
    try model.set(.start_offset, "+02:00");
    try model.set(.end_offset, "+01:00");
    _ = try model.reviewRequest(a, "operation-2");
    try model.set(.end_offset, "+02:00");
    try std.testing.expectError(error.CalendarEndBeforeStart, model.reviewRequest(a, "operation-2"));
    try model.set(.end_offset, "+24:00");
    try std.testing.expectError(error.CalendarInvalidOffset, model.reviewRequest(a, "operation-2"));
}

test "calendar composer: guest validation duplicate detection and invitations are explicit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    // Mail list grammar is accepted (see the paste test below); broken lists,
    // semicolon-joined recipients and invalid entries are still refused.
    for ([_][]const u8{ "peer@example.test,", "Jane <peer@example.test", "peer@example.test;second@example.test", "not an email", "bad\n@example.test", "peer@example.test\r\nBcc: hidden@example.test", "Name\r\nBcc: hidden@example.test;", "peer@example.test,\nsecond@example.test", "\r\n", " \n ", "" }) |raw| {
        try model.set(.attendees, raw);
        if (raw.len == 0) {
            _ = try model.reviewRequest(a, "operation-3");
        } else try std.testing.expectError(error.CalendarInvalidGuest, model.reviewRequest(a, "operation-3"));
    }
    try model.set(.attendees, "peer@example.test, PEER@example.test");
    try std.testing.expectError(error.CalendarDuplicateGuest, model.reviewRequest(a, "operation-3"));
    try model.set(.attendees, "peer@example.test, second@example.test");
    try std.testing.expectError(error.CalendarGuestsRequireUpdates, model.reviewRequest(a, "operation-3"));
    model.send_updates = .all;
    const request = try model.reviewRequest(a, "operation-3");
    try std.testing.expectEqual(@as(usize, 2), j.get(j.get(request, "event").?, "attendees").?.array.items.len);
    try std.testing.expectEqualStrings("all", j.text(request, "sendUpdates"));
}

test "calendar composer: guests accept Mail address-list paste and review only bare emails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    model.send_updates = .all;
    try model.set(.attendees, "\"Doe, Jane\" <jane@example.test>, Alex Example <alex@example.test>,\t robin@example.test (Robin)");
    const request = try model.reviewRequest(a, "operation-15");
    const guests = j.get(j.get(request, "event").?, "attendees").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), guests.len);
    for (guests, [_][]const u8{ "jane@example.test", "alex@example.test", "robin@example.test" }) |guest, expected| try std.testing.expectEqualStrings(expected, try j.string(guest));
    try std.testing.expectEqual(@as(usize, 3), try model.addedGuestCount(a));
    // A display name never hides a duplicate, and nothing invalid is dropped.
    try model.set(.attendees, "Jane <jane@example.test>, \"Doe, Jane\" <JANE@example.test>");
    try std.testing.expectError(error.CalendarDuplicateGuest, model.reviewRequest(a, "operation-15"));
    try model.set(.attendees, "Jane <jane@example.test>, not an email");
    try std.testing.expectError(error.CalendarInvalidGuest, model.reviewRequest(a, "operation-15"));
    // Exactly 200 named guests fit; the 201st is refused without truncation.
    var list: std.ArrayList(u8) = .empty;
    for (0..max_guests) |index| try list.print(a, "{s}\"Guest, {d}\" <guest{d}@example.test>", .{ if (index == 0) "" else ", ", index, index });
    try model.set(.attendees, list.items);
    const full = j.get(j.get(try model.reviewRequest(a, "operation-15"), "event").?, "attendees").?.array.items;
    try std.testing.expectEqual(@as(usize, max_guests), full.len);
    try std.testing.expectEqualStrings("guest199@example.test", try j.string(full[max_guests - 1]));
    try list.appendSlice(a, ", \"Guest, 200\" <guest200@example.test>");
    try model.set(.attendees, list.items);
    try std.testing.expectError(error.CalendarTooManyGuests, model.reviewRequest(a, "operation-15"));
    try std.testing.expectEqualStrings(list.items, model.get(.attendees));
    // Existing guests compare by mailbox, whatever name is pasted around them.
    try model.original_attendees.set("jane@example.test");
    model.editing = true;
    try model.event_id.set("existing");
    try model.expected_etag.set("v1");
    try model.set(.attendees, "Jane Doe <JANE@example.test>, New <new@example.test>");
    try std.testing.expectEqual(@as(usize, 1), try model.addedGuestCount(a));
    try model.set(.attendees, "New <new@example.test>");
    try std.testing.expectError(error.CalendarExistingGuestsMustBePreserved, model.reviewRequest(a, "operation-15"));
}

test "calendar composer: an untouched end follows start edits and keeps the shown interval" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var follow: EndFollow = .{};
    var fields: EndFollow.Fields = .{ .start_date = "2026-10-24", .start_time = "09:00", .end_date = "2026-10-24", .end_time = "10:00" };
    // Only the start date moves; the one-hour end moves with it.
    follow.observe(false, fields);
    fields.start_date = "2026-10-28";
    var end = (try follow.follow(a, false, fields)).?;
    try std.testing.expectEqualStrings("2026-10-28", end.date);
    try std.testing.expectEqualStrings("10:00", end.time);
    fields.end_date = end.date;
    fields.end_time = end.time;
    // A late start carries the end over midnight and the year boundary.
    for ([_][4][]const u8{
        .{ "2026-10-28", "23:30", "2026-10-29", "00:30" },
        .{ "2026-12-31", "23:15", "2027-01-01", "00:15" },
        .{ "2026-12-31", "00:00", "2026-12-31", "01:00" },
        .{ "2026-10-28", "09:15:30.250", "2026-10-28", "10:15:30.250" },
    }) |case| {
        follow.observe(false, fields);
        fields.start_date = case[0];
        fields.start_time = case[1];
        end = (try follow.follow(a, false, fields)).?;
        try std.testing.expectEqualStrings(case[2], end.date);
        try std.testing.expectEqualStrings(case[3], end.time);
        fields.end_date = end.date;
        fields.end_time = end.time;
    }
    // Wall-clock length is kept on the Vienna fold date; offsets stay unchosen.
    fields = .{ .start_date = "2026-10-24", .start_time = "02:30", .end_date = "2026-10-24", .end_time = "03:30" };
    follow.observe(false, fields);
    fields.start_date = "2026-10-25";
    end = (try follow.follow(a, false, fields)).?;
    try std.testing.expectEqualStrings("2026-10-25", end.date);
    try std.testing.expectEqualStrings("03:30", end.time);
    // Partial or invalid start text leaves the end as it is.
    for ([_][]const u8{ "2026-10-2", "2026-02-30", "2026/10/25", "" }) |partial| {
        fields.start_date = partial;
        try std.testing.expect((try follow.follow(a, false, fields)) == null);
    }
    fields.start_date = "2026-10-25";
    for ([_][]const u8{ "2", "24:00", "09:6" }) |partial| {
        fields.start_time = partial;
        try std.testing.expect((try follow.follow(a, false, fields)) == null);
    }
    // An overnight multi-day interval keeps its length; out of range stays put.
    fields = .{ .start_date = "2026-10-24", .start_time = "22:00", .end_date = "2026-10-26", .end_time = "02:00" };
    follow.observe(false, fields);
    fields.start_date = "2026-11-01";
    end = (try follow.follow(a, false, fields)).?;
    try std.testing.expectEqualStrings("2026-11-03", end.date);
    try std.testing.expectEqualStrings("02:00", end.time);
    fields.start_date = "9999-12-31";
    try std.testing.expect((try follow.follow(a, false, fields)) == null);
    // All-day keeps its included days across month, leap and year ends.
    var days: EndFollow = .{};
    fields = .{ .start_date = "2026-10-24", .start_time = "09:00", .end_date = "2026-10-26", .end_time = "10:00" };
    days.observe(true, fields);
    for ([_][2][]const u8{ .{ "2026-12-30", "2027-01-01" }, .{ "2028-02-28", "2028-03-01" } }) |case| {
        fields.start_date = case[0];
        try std.testing.expectEqualStrings(case[1], (try days.follow(a, true, fields)).?.date);
    }
    // The learned interval is mode-specific and a reversed pair teaches nothing.
    try std.testing.expect((try days.follow(a, false, fields)) == null);
    var reversed: EndFollow = .{};
    reversed.observe(false, .{ .start_date = "2026-10-24", .start_time = "10:00", .end_date = "2026-10-24", .end_time = "09:00" });
    try std.testing.expect((try reversed.follow(a, false, fields)) == null);
    // An explicitly edited end is never moved.
    follow.pinned = true;
    fields = .{ .start_date = "2026-10-24", .start_time = "09:00", .end_date = "2026-10-24", .end_time = "10:00" };
    follow.observe(false, fields);
    fields.start_date = "2026-10-30";
    try std.testing.expect((try follow.follow(a, false, fields)) == null);
}

test "calendar composer: guest counting keeps no parsed lists and allocation failure is never a silent fallback" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.original_attendees.set("first@example.test");
    var many: std.ArrayList(u8) = .empty;
    for (0..max_guests + 1) |index| try many.print(a, "{s}g{d}@example.test", .{ if (index == 0) "" else ", ", index });
    // The leak-checking allocator proves nothing parsed is left behind, on
    // success or on any refusal; line breaks are refused before allocating.
    for ([_][]const u8{ "First <first@example.test>, second@example.test", "a@example.test, A@example.test", "a@example.test, not an email", "Name\r\nBcc: hidden@example.test;", many.items }, [_]?anyerror{ null, error.CalendarDuplicateGuest, error.CalendarInvalidGuest, error.CalendarInvalidGuest, error.CalendarTooManyGuests }) |raw, expected| {
        try model.set(.attendees, raw);
        if (expected) |err| try std.testing.expectError(err, model.addedGuestCount(std.testing.allocator)) else try std.testing.expectEqual(@as(usize, 1), try model.addedGuestCount(std.testing.allocator));
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(if (std.mem.indexOfAny(u8, raw, "\r\n") != null) error.CalendarInvalidGuest else error.OutOfMemory, model.addedGuestCount(failing.allocator()));
    }
    // End following: every allocation may fail. The error propagates (never
    // "keep the end"), the leak-checking allocator proves nothing partial is
    // left, and once allocations succeed the caller owns both strings.
    var follow: EndFollow = .{};
    var fields: EndFollow.Fields = .{ .start_date = "2026-10-24", .start_time = "09:00", .end_date = "2026-10-24", .end_time = "10:00" };
    follow.observe(false, fields);
    fields.start_date = "2026-10-28";
    var days: EndFollow = .{};
    days.observe(true, .{ .start_date = "2026-10-24", .start_time = "09:00", .end_date = "2026-10-25", .end_time = "10:00" });
    for ([_]bool{ false, true }) |all_day| {
        const source: *const EndFollow = if (all_day) &days else &follow;
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            try std.testing.expect(fail_index < 16);
            var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
            const end = (source.follow(failing.allocator(), all_day, fields) catch |err| {
                try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), err);
                continue;
            }).?;
            defer failing.allocator().free(end.date);
            defer failing.allocator().free(end.time);
            try std.testing.expect(fail_index >= 2);
            try std.testing.expectEqualStrings(if (all_day) "2026-10-29" else "2026-10-28", end.date);
            try std.testing.expectEqualStrings("10:00", end.time);
            break;
        }
    }
}

test "calendar composer: Model.set used by hydration and review never moves the other endpoint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.set(.start_date, "2026-10-30");
    try model.set(.start_time, "11:00");
    try std.testing.expectEqualStrings("2026-10-24", model.get(.end_date));
    try std.testing.expectEqualStrings("10:00", model.get(.end_time));
    try std.testing.expectError(error.CalendarEndBeforeStart, model.reviewRequest(a, "operation-16"));
}

test "calendar composer: review owns escaped text and pasted meeting links are inert safe HTTPS" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.set(.summary, "Planning \"café\"");
    try model.set(.description, "First line\nA backslash \\ and quote \"");
    model.conference = .link;
    for ([_][]const u8{ "javascript:alert(1)", "http://meet.example.test/room", "https://user:pass@meet.example.test/room", "https://meet.example.test/room bad" }) |url| {
        try model.set(.join_url, url);
        try std.testing.expectError(error.CalendarUnsafeJoinLink, model.reviewRequest(a, "operation-4"));
    }
    try model.set(.join_url, "https://meet.example.test/room?one=1&two=2");
    const request = try model.reviewRequest(a, "operation-4");
    try model.set(.summary, "Changed after review");
    try std.testing.expectEqualStrings("Planning \"café\"", j.text(j.get(request, "event").?, "summary"));
    try std.testing.expectEqualStrings("First line\nA backslash \\ and quote \"", j.text(j.get(request, "event").?, "description"));
    try std.testing.expectEqualStrings("https://meet.example.test/room?one=1&two=2", j.text(j.get(request, "event").?, "joinUrl"));
    model.writable = false;
    try std.testing.expectError(error.CalendarReadOnly, model.reviewRequest(a, "operation-4"));
}

test "calendar composer: edit preserves exact provider seconds guests and conference by default" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = try tz.dateDay("2026-10-25"), .now_ms = try t.time.rfc3339("2026-10-15T10:00:00Z"), .zone_name = "UTC", .zone = &zone, .supports_meet = true };
    const response = try j.value(a, .{ .canEdit = true, .event = .{ .id = "provider-event", .etag = "\"version-7\"", .join_url = "https://meet.example.test/existing", .attendees_omitted = false }, .eventDraft = .{ .summary = "Existing", .start = "2026-10-25T02:30:04.125", .end = "2026-10-25T03:30:09", .timeZone = "Europe/Vienna", .allDay = false, .attendees = [_][]const u8{"peer@example.test"}, .startOffset = "+02:00", .endOffset = "+01:00" } });
    var model = try Model.initEdit(a, options, response);
    try std.testing.expectEqualStrings("02:30:04.125", model.get(.start_time));
    try model.set(.summary, "Edited title");
    const request = try model.reviewRequest(a, "operation-5");
    try std.testing.expectEqualStrings("provider-event", j.text(request, "eventId"));
    try std.testing.expectEqualStrings("\"version-7\"", j.text(request, "expectedEtag"));
    const event = j.get(request, "event").?;
    try std.testing.expect(j.get(event, "attendees") == null);
    try std.testing.expectEqualStrings("none", j.text(event, "conference"));
    try std.testing.expect(j.get(event, "joinUrl") == null);
    try std.testing.expectEqualStrings("2026-10-25T02:30:04.125", j.text(event, "start"));
    try model.set(.attendees, " PEER@example.test ");
    try std.testing.expectEqual(@as(usize, 0), try model.addedGuestCount(a));
    try std.testing.expect(j.get(j.get(try model.reviewRequest(a, "operation-5"), "event").?, "attendees") == null);
    try model.set(.attendees, "new@example.test");
    try std.testing.expectError(error.CalendarExistingGuestsMustBePreserved, model.reviewRequest(a, "operation-5"));
    try model.set(.attendees, "peer@example.test, new@example.test");
    try std.testing.expectEqual(@as(usize, 1), try model.addedGuestCount(a));
    model.send_updates = .all;
    _ = try model.reviewRequest(a, "operation-5");
    model.conference = .google_meet;
    try std.testing.expectError(error.CalendarExistingConference, model.reviewRequest(a, "operation-5"));
    try std.testing.expectError(error.CalendarEditTargetFixed, model.setTarget(.{ .account = options.target.account, .calendar_id = "another" }, true, true));
}

test "calendar composer: edit all-day exclusive end round-trips and incomplete metadata fails closed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone };
    const response = try j.value(a, .{ .canEdit = true, .event = .{ .id = "all-day", .etag = "v1", .attendees_omitted = true }, .eventDraft = .{ .summary = "Away", .start = "2026-10-24", .end = "2026-10-27", .timeZone = "Europe/Vienna", .allDay = true, .attendees = [_][]const u8{"peer@example.test"} } });
    var model = try Model.initEdit(a, options, response);
    try std.testing.expectEqualStrings("2026-10-26", model.get(.end_date));
    const request = try model.reviewRequest(a, "operation-6");
    try std.testing.expectEqualStrings("2026-10-27", j.text(j.get(request, "event").?, "end"));
    try std.testing.expect(!model.editable(.attendees));
    try model.set(.attendees, "peer@example.test, new@example.test");
    try std.testing.expectError(error.CalendarGuestsNeedRefresh, model.reviewRequest(a, "operation-6"));
    try std.testing.expectError(error.CalendarReadOnly, Model.initEdit(a, options, try j.value(a, .{ .canEdit = false })));
    try std.testing.expectError(error.CalendarEventNeedsRefresh, Model.initEdit(a, options, try j.value(a, .{ .canEdit = true })));
}

test "calendar composer: defaults use selected civil day and safely cross local midnight" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone = try tz.Zone.fromPosix("CET-1");
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = try tz.dateDay("2026-10-24"), .now_ms = try t.time.rfc3339("2026-10-24T22:45:00Z"), .zone_name = "Europe/Vienna", .zone = &zone };
    const model = try Model.init(a, options);
    try std.testing.expectEqualStrings("2026-10-25", model.get(.start_date));
    try std.testing.expectEqualStrings("00:00", model.get(.start_time));
    try std.testing.expectEqualStrings("01:00", model.get(.end_time));
    var next = options;
    next.day += 3;
    const selected = try Model.init(a, next);
    try std.testing.expectEqualStrings("2026-10-27", selected.get(.start_date));
    try std.testing.expectEqualStrings("09:00", selected.get(.start_time));
}

test "calendar composer: invalid civil values empty title readonly and missing Meet support refuse review" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.set(.summary, "   ");
    try std.testing.expectError(error.CalendarTitleRequired, model.reviewRequest(a, "operation-7"));
    try model.set(.summary, "Planning");
    try model.set(.start_date, "2026-02-29");
    try std.testing.expectError(error.CalendarInvalidStartDate, model.reviewRequest(a, "operation-7"));
    try model.set(.start_date, "2026-10-24");
    try model.set(.end_date, "2026/10/24");
    try std.testing.expectError(error.CalendarInvalidEndDate, model.reviewRequest(a, "operation-7"));
    try model.set(.end_date, "2026-10-24");
    try model.set(.start_time, "24:00");
    try std.testing.expectError(error.CalendarInvalidStartTime, model.reviewRequest(a, "operation-7"));
    try model.set(.start_time, "09:00:00.1");
    try model.set(.end_time, "09:00:00.12");
    _ = try model.reviewRequest(a, "operation-7");
    model.conference = .google_meet;
    model.supports_meet = false;
    try std.testing.expectError(error.CalendarMeetUnavailable, model.reviewRequest(a, "operation-7"));
    model.writable = false;
    try std.testing.expectError(error.CalendarReadOnly, model.reviewRequest(a, "operation-7"));
    try std.testing.expect(!model.editable(.summary));
    try std.testing.expectError(error.InvalidCalendarField, model.set(.summary, "Title\x1b[2J"));
}

test "calendar composer: changing wall time clears inherited fold offsets while notes preserve CRLF" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.set(.start_offset, "+02:00");
    try model.set(.end_offset, "+02:00");
    try model.set(.start_date, model.get(.start_date));
    try std.testing.expectEqualStrings("+02:00", model.get(.start_offset));
    try model.set(.start_date, "2026-10-25");
    try std.testing.expectEqualStrings("", model.get(.start_offset));
    try std.testing.expectEqualStrings("+02:00", model.get(.end_offset));
    try model.set(.time_zone, "Europe/Vienna");
    try std.testing.expectEqualStrings("", model.get(.end_offset));
    try model.set(.end_date, "2026-10-25");
    try model.set(.description, "First\r\nSecond\r\n");
    const request = try model.reviewRequest(a, "operation-8");
    try std.testing.expectEqualStrings("First\r\nSecond\r\n", j.text(j.get(request, "event").?, "description"));
}

test "calendar composer: maximum guest list is bounded and never truncated" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    model.send_updates = .all;
    var guests: std.ArrayList(u8) = .empty;
    defer guests.deinit(a);
    for (0..max_guests) |index| {
        if (index > 0) try guests.appendSlice(a, ", ");
        try guests.appendSlice(a, try std.fmt.allocPrint(a, "guest{d}@example.test", .{index}));
    }
    try model.set(.attendees, guests.items);
    const request = try model.reviewRequest(a, "operation-9");
    try std.testing.expectEqual(@as(usize, max_guests), j.get(j.get(request, "event").?, "attendees").?.array.items.len);
    try guests.appendSlice(a, ", another@example.test");
    try model.set(.attendees, guests.items);
    try std.testing.expectError(error.CalendarTooManyGuests, model.reviewRequest(a, "operation-9"));
    try std.testing.expectEqualStrings(guests.items, model.get(.attendees));
}

test "calendar composer: formatted notes are unchanged and existing meeting URLs cannot be removed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone };
    const html = try j.value(a, .{ .canEdit = true, .event = .{ .id = "formatted", .etag = "v1", .join_url = "https://meet.example.test/room" }, .eventDraft = .{ .summary = "Formatted meeting", .start = "2026-10-24T10:00:00.000", .end = "2026-10-24T11:00:00.000", .timeZone = "UTC", .allDay = false, .description = "<p>Bring <b>notes</b></p><a href=\"https://meet.example.test/room\">Join</a>" } });
    var formatted = try Model.initEdit(a, options, html);
    try std.testing.expect(formatted.notes_read_only and !formatted.editable(.description));
    try formatted.set(.description, formatted.get(.description));
    try std.testing.expectError(error.CalendarFormattedNotesReadOnly, formatted.set(.description, "Flattened notes"));
    _ = try formatted.reviewRequest(a, "operation-10");
    const plain = try j.value(a, .{ .canEdit = true, .event = .{ .id = "plain", .etag = "v2", .join_url = "https://meet.example.test/room" }, .eventDraft = .{ .summary = "Plain meeting", .start = "2026-10-24T10:00", .end = "2026-10-24T11:00", .timeZone = "UTC", .allDay = false, .description = "Bring notes.\n\nJoin: https://meet.example.test/room" } });
    var editable = try Model.initEdit(a, options, plain);
    try std.testing.expect(!editable.notes_read_only and editable.editable(.description));
    try editable.set(.description, "Accidentally removed the meeting link.");
    try std.testing.expectError(error.CalendarExistingMeetingLinkRequired, editable.reviewRequest(a, "operation-11"));
    try editable.set(.description, "Updated notes.\n\nJoin: https://meet.example.test/room");
    _ = try editable.reviewRequest(a, "operation-11");
}

test "calendar composer: omitted large guest lists display a prefix and remain unchanged on edit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone };
    var response = try j.value(a, .{ .canEdit = true, .event = .{ .id = "company-meeting", .etag = "v1", .attendees = [_][]const u8{"first@example.test"}, .attendees_omitted = true, .attendee_count = 500 }, .eventDraft = .{ .summary = "Company update", .start = "2026-10-24T10:00", .end = "2026-10-24T11:00", .timeZone = "UTC", .allDay = false } });
    var draft = try j.copyObject(a, j.get(response, "eventDraft").?);
    try draft.object.put(a, "attendees", .null);
    try response.object.put(a, "eventDraft", draft);
    var model = try Model.initEdit(a, options, response);
    try std.testing.expectEqualStrings("first@example.test", model.get(.attendees));
    try std.testing.expectEqual(@as(usize, 500), model.existingGuestCount());
    try std.testing.expect(!model.editable(.attendees));
    try model.set(.summary, "Updated company update");
    const request = try model.reviewRequest(a, "operation-12");
    try std.testing.expect(j.get(j.get(request, "event").?, "attendees") == null);
}

test "calendar composer: actual guest count survives an entirely omitted provider guest list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone };
    var response = try j.value(a, .{ .canEdit = true, .event = .{ .id = "company-meeting", .etag = "v1", .attendees = [_][]const u8{}, .attendees_omitted = true, .attendee_count = 201 }, .eventDraft = .{ .summary = "Company update", .start = "2026-10-24T10:00", .end = "2026-10-24T11:00", .timeZone = "UTC", .allDay = false } });
    var draft = try j.copyObject(a, j.get(response, "eventDraft").?);
    try draft.object.put(a, "attendees", .null);
    try response.object.put(a, "eventDraft", draft);
    var model = try Model.initEdit(a, options, response);
    try std.testing.expectEqualStrings("", model.get(.attendees));
    try std.testing.expectEqual(@as(usize, 201), model.existingGuestCount());
    try std.testing.expect(model.editing and model.existingGuestCount() > 0);
    try std.testing.expect(!model.attendees_complete and !model.editable(.attendees));
    const request = try model.reviewRequest(a, "operation-14");
    try std.testing.expect(j.get(j.get(request, "event").?, "attendees") == null);
}

test "calendar composer: all-day review ignores the hidden timed zone and retains it for later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.set(.time_zone, "../../not-a-time-zone");
    model.all_day = true;
    const request = try model.reviewRequest(a, "operation-13");
    const event = j.get(request, "event").?;
    try std.testing.expectEqualStrings("UTC", j.text(event, "timeZone"));
    try std.testing.expectEqualStrings("2026-10-24", j.text(event, "start"));
    try std.testing.expectEqualStrings("2026-10-25", j.text(event, "end"));
    try std.testing.expectEqualStrings("../../not-a-time-zone", model.get(.time_zone));
    model.all_day = false;
    try std.testing.expectError(error.InvalidTimezoneName, model.reviewRequest(a, "operation-13"));
}

test "calendar composer: invitations count added guests rather than list presentation changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try fixture(a);
    try model.original_attendees.set("first@example.test, second@example.test");
    for ([_][]const u8{ "second@example.test, first@example.test", " FIRST@example.test , SECOND@example.test ", "first@example.test,\tsecond@example.test", "First <first@example.test>, \"Second, S\" <second@example.test>" }) |raw| {
        try model.set(.attendees, raw);
        try std.testing.expectEqual(@as(usize, 0), try model.addedGuestCount(a));
    }
    // The shared grammar never treats a line break as list whitespace.
    try model.set(.attendees, "first@example.test,\r\nsecond@example.test");
    try std.testing.expectError(error.CalendarInvalidGuest, model.addedGuestCount(a));
    try model.set(.attendees, "second@example.test, first@example.test, third@example.test");
    try std.testing.expectEqual(@as(usize, 1), try model.addedGuestCount(a));
}

test "calendar composer: pending create restores the saved draft without current write access or zone rules" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{ .unavailable = true };
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone, .writable = false, .supports_meet = true };
    const review = try j.value(a, .{ .account = options.target.account, .calendarId = options.target.calendar_id, .operationId = "saved-create", .action = "create_event", .eventId = "stable-generated-id", .expectedEtag = "", .sendUpdates = "all", .event = .{ .summary = "Saved pending meeting", .start = "2026-10-25T02:30:04.125", .end = "2026-10-25T03:30:07.250", .startOffset = "+01:00", .endOffset = "+01:00", .timeZone = "Europe/Vienna", .allDay = false, .description = "Reviewed original notes", .location = "Studio", .attendees = [_][]const u8{"guest@example.test"}, .conference = "google_meet" } });
    const restored = try Model.initReview(a, options, review);
    try std.testing.expect(!restored.editing and !restored.writable);
    try std.testing.expectEqualStrings("stable-generated-id", restored.event_id.slice());
    try std.testing.expectEqualStrings("Saved pending meeting", restored.get(.summary));
    try std.testing.expectEqualStrings("02:30:04.125", restored.get(.start_time));
    try std.testing.expectEqualStrings("+01:00", restored.get(.start_offset));
    try std.testing.expectEqual(Conference.google_meet, restored.conference);
    try std.testing.expectEqual(SendUpdates.all, restored.send_updates);
    try std.testing.expectEqual(@as(usize, 1), try restored.addedGuestCount(a));
    try std.testing.expectEqual(@as(usize, 0), restored.existingGuestCount());
    try std.testing.expectError(error.CalendarReadOnly, restored.reviewRequest(a, "new-write-refused"));
}

test "calendar composer: pending edit restores original metadata separately from reviewed additions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{ .unavailable = true };
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "team-calendar" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone };
    const notes = "<p>Original notes</p><a href=\"https://meet.example.test/existing\">Join</a>";
    const review = try j.value(a, .{ .account = options.target.account, .calendarId = options.target.calendar_id, .operationId = "saved-edit", .action = "update_event", .eventId = "existing-id", .expectedEtag = "\"reviewed-version\"", .sendUpdates = "all", .previous = .{ .target = options.target, .id = "existing-id", .etag = "\"reviewed-version\"", .attendees = [_][]const u8{"original@example.test"}, .attendee_count = 1, .attendees_omitted = false, .conference_present = true, .conference_status = "success", .join_url = "https://meet.example.test/existing" }, .event = .{ .summary = "Reviewed moved meeting", .start = "2026-10-25T02:30:12.125", .end = "2026-10-25T03:30:00.000", .startOffset = "+01:00", .endOffset = "+01:00", .timeZone = "Europe/Vienna", .allDay = false, .description = notes, .attendees = [_][]const u8{ "original@example.test", "added@example.test" }, .conference = "none" } });
    const restored = try Model.initReview(a, options, review);
    try std.testing.expect(restored.editing and restored.existing_join and restored.notes_read_only);
    try std.testing.expectEqualStrings("\"reviewed-version\"", restored.expected_etag.slice());
    try std.testing.expectEqualStrings("original@example.test", restored.original_attendees.slice());
    try std.testing.expectEqualStrings("original@example.test, added@example.test", restored.get(.attendees));
    try std.testing.expectEqual(@as(usize, 1), restored.existingGuestCount());
    try std.testing.expectEqual(@as(usize, 1), try restored.addedGuestCount(a));
    try std.testing.expectEqualStrings(notes, restored.get(.description));
    try std.testing.expectEqualStrings("https://meet.example.test/existing", restored.protected_join_url.slice());
    var other = options;
    other.target.calendar_id = "different-calendar";
    try std.testing.expectError(error.CalendarAccountMismatch, Model.initReview(a, other, review));
}

test "calendar composer: pending all-day create restores inclusive UI dates exactly once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const options: Init = .{ .target = .{ .account = "self@example.test", .calendar_id = "primary" }, .day = 0, .now_ms = 1000, .zone_name = "UTC", .zone = &zone };
    const review = try j.value(a, .{ .account = options.target.account, .calendarId = options.target.calendar_id, .operationId = "saved-all-day", .action = "create_event", .eventId = "stable-all-day", .expectedEtag = "", .sendUpdates = "none", .event = .{ .summary = "Saved leave", .start = "2028-02-28", .end = "2028-03-02", .timeZone = "UTC", .allDay = true, .conference = "none" } });
    const restored = try Model.initReview(a, options, review);
    try std.testing.expect(restored.all_day and !restored.editing);
    try std.testing.expectEqualStrings("2028-02-28", restored.get(.start_date));
    try std.testing.expectEqualStrings("2028-03-01", restored.get(.end_date));
    const request = try restored.reviewRequest(a, "separate-explicit-review");
    try std.testing.expectEqualStrings("2028-03-02", j.text(j.get(request, "event").?, "end"));
    try std.testing.expectEqualStrings("UTC", j.text(j.get(request, "event").?, "timeZone"));
}
