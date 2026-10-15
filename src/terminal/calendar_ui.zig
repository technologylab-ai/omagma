//! Bounded presentation state and civil-date projection for the native Calendar.
//! Provider dates stay civil days; instants use the selected calendar's zone.
const std = @import("std");
const j = @import("json.zig");
const b = @import("../bounded.zig");
const tz = @import("timezone.zig");
const t = @import("calendar_types.zig");
pub const View = enum { agenda, day, week };
pub const Page = enum { compose, event_review, main, calendars, detail, review, permissions, help, actions, overlaps };
pub const Document = struct {
    arena: ?std.heap.ArenaAllocator = null,
    value: j.Value = .null,
    bytes: usize = 0,
    pub fn deinit(self: *Document) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn replace(self: *Document, a: std.mem.Allocator, value: j.Value) !void {
        var next: Document = .{ .arena = .init(a) };
        errdefer next.deinit();
        const owned = next.arena.?.allocator();
        const raw = try std.json.Stringify.valueAlloc(owned, value, .{});
        if (raw.len > t.Limits.snapshot_bytes) return error.CalendarTooLarge;
        next.bytes = raw.len;
        next.value = try std.json.parseFromSliceLeaky(j.Value, owned, raw, .{ .allocate = .alloc_always });
        self.deinit();
        self.* = next;
    }
};
pub const State = struct {
    open: bool = false,
    view: View = .agenda,
    page: Page = .main,
    help_return: Page = .main,
    help_focus_back: bool = false,
    help_return_scroll: usize = 0,
    help_return_focus: ?usize = null,
    day: i64 = 0,
    selected: usize = 0,
    /// Only explicit navigation/reveal promotes a hidden selection in Week.
    week_reveal_selected: bool = false,
    picker: usize = 0,
    top: usize = 0,
    scroll: usize = 0,
    focus: ?usize = null,
    searching: bool = false,
    entering_date: bool = false,
    ready: bool = false,
    stale: bool = false,
    card_stale: bool = false,
    complete: bool = false,
    review_ready: bool = false,
    confirmed_review: bool = false,
    unknown: bool = false,
    outcome: b.Text(32) = .{},
    account: b.Text(254) = .{},
    calendar_id: b.Text(1024) = .{},
    calendar_name: b.Text(1024) = .{},
    zone_name: b.Text(512) = .{},
    source_message: b.Text(1024) = .{},
    operation: b.Text(128) = .{},
    hash: b.Text(64) = .{},
    error_code: b.Text(128) = .{},
    notice: b.Text(256) = .{},
    calendars: Document = .{},
    source_lists: [3]Document = @splat(.{}),
    source_snapshots: [72]Document = @splat(.{}),
    source_errors: [72]b.Text(128) = @splat(.{}),
    list_errors: [3]b.Text(128) = @splat(.{}),
    list_cursor: usize = 0,
    source_cursor: usize = 0,
    source_loading: bool = false,
    resume_sources: bool = false,
    resume_lists: bool = false,
    pending_card: bool = false,
    listing_all: bool = false,
    single_source: bool = false,
    selection_dirty: bool = false,
    pending_selection: ?@import("calendar_sources.zig").Selection = null,
    list_for_picker: bool = false,
    selection_initialized: bool = false,
    sources_cache_only: bool = false,
    picker_return: Page = .main,
    actions_return: Page = .main,
    request_window: ?t.Window = null,
    agenda: Document = .{},
    card: Document = .{},
    review: Document = .{},
    zone: tz.Zone = .{},
    card_zone: tz.Zone = .{},
    card_zone_name: b.Text(512) = .{},
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.calendars.deinit();
        for (&self.source_lists) |*document| document.deinit();
        for (&self.source_snapshots) |*document| document.deinit();
        self.agenda.deinit();
        self.card.deinit();
        self.review.deinit();
        self.zone.deinit(a);
        self.card_zone.deinit(a);
        self.* = .{};
    }
};
pub fn dayText(a: std.mem.Allocator, day: i64) ![]const u8 {
    const utc: tz.Zone = .{};
    const value = try utc.format(a, day * 86400000);
    return value[0..@min(value.len, 10)];
}
pub fn viewName(view: View) []const u8 {
    return switch (view) {
        .agenda => "Agenda",
        .day => "Day",
        .week => "Week",
    };
}
pub fn period(view: View) i64 {
    return if (view == .day) 1 else 7;
}
pub fn visiblePeriod(view: View, width: u16) i64 {
    return if (view == .week and gridDays(width) == 3) 3 else period(view);
}
/// Civil minute coverage for a single column. Endpoints remain instants; this
/// projection only determines the occupied rows, including a repeated DST hour.
pub const Coverage = struct { first: u16, end: u16 };
pub fn coverage(start: t.time.Point, end: t.time.Point, day: i64, zone: *const tz.Zone) !?Coverage {
    if (start.kind != .instant or end.kind != .instant or end.value < start.value or !try touchesDay(start, end, day, zone)) return null;
    const first_seconds = @divFloor(start.value, 1000);
    const last_value = @max(end.value - 1, start.value);
    const last_seconds = @divFloor(last_value, 1000);
    const first: u16 = if (try pointDay(start, zone) < day) 0 else @intCast(@divFloor(@mod(first_seconds + try zone.offsetSeconds(first_seconds), 86400), 60));
    const last: u16 = if (try zone.localDay(last_value) > day) 1439 else @intCast(@divFloor(@mod(last_seconds + try zone.offsetSeconds(last_seconds), 86400), 60));
    return .{ .first = @min(first, last), .end = @max(first, last) + 1 };
}

test "calendar UI: minute coverage retains duration midnight and hour overlaps" {
    const zone: tz.Zone = .{};
    const start: t.time.Point = .{ .kind = .instant, .value = (10 * 60 + 30) * 60000 };
    const end: t.time.Point = .{ .kind = .instant, .value = 12 * 3600000 };
    const span = (try coverage(start, end, 0, &zone)).?;
    try std.testing.expectEqual(@as(u16, 630), span.first);
    try std.testing.expectEqual(@as(u16, 720), span.end);
    const overnight: t.time.Point = .{ .kind = .instant, .value = 25 * 3600000 };
    try std.testing.expectEqual(@as(u16, 1440), (try coverage(start, overnight, 0, &zone)).?.end);
    try std.testing.expectEqual(@as(u16, 0), (try coverage(start, overnight, 1, &zone)).?.first);
    try std.testing.expectEqual(@as(u16, 60), (try coverage(start, overnight, 1, &zone)).?.end);
    try std.testing.expect((try coverage(start, end, 1, &zone)) == null);
    try std.testing.expectEqual(@as(i64, 3), visiblePeriod(.week, 82));
    try std.testing.expectEqual(@as(u16, 630), (try coverage(start, start, 0, &zone)).?.first);
}
pub fn responseMark(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "needs_action")) return "?";
    if (std.mem.eql(u8, raw, "tentative")) return "~";
    if (std.mem.eql(u8, raw, "declined")) return "×";
    return " ";
}
/// Every camera badge and Join control uses the same launchable-link policy.
pub fn canJoin(event: j.Value) bool {
    if (j.get(event, "cancelled")) |value| if (value == .bool and value.bool) return false;
    const url = j.text(event, "join_url");
    return std.mem.startsWith(u8, url, "https://") and @import("reader_tools.zig").safeUrl(url);
}
pub fn responseLabel(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "needs_action")) return "Not answered";
    if (std.mem.eql(u8, raw, "accepted")) return "Accepted";
    if (std.mem.eql(u8, raw, "tentative")) return "Tentative";
    if (std.mem.eql(u8, raw, "declined")) return "Declined";
    return "";
}
pub fn cardWidth(width: u16) u16 {
    return @min(width, 88);
}
/// Display only: reuse the bounded inert mail parser for Calendar's HTML prose.
pub fn descriptionText(a: std.mem.Allocator, raw: []const u8, join_url: []const u8) ![]const u8 {
    var markup = false;
    for ([_][]const u8{ "<p", "<div", "<br", "<a ", "<b>", "<strong", "<table", "<ul", "<ol", "<script", "<style" }) |tag| {
        if (std.ascii.findIgnoreCase(raw, tag) != null) markup = true;
    }
    var output: std.ArrayList(u8) = .empty;
    if (markup) {
        const document = @import("html_document.zig").parse(raw, a) catch return raw;
        for (document.blocks) |block| {
            if (output.items.len > 0) try output.append(a, '\n');
            for (block.spans) |span| try output.appendSlice(a, span.text);
            if (block.table) |table| for (table.rows) |row| {
                if (output.items.len > 0) try output.append(a, '\n');
                for (row.cells, 0..) |cell, i| {
                    if (i > 0) try output.appendSlice(a, " · ");
                    for (cell.spans) |span| try output.appendSlice(a, span.text);
                }
            };
        }
    } else try output.appendSlice(a, raw);
    const value = std.mem.trim(u8, output.items, " \t\r\n");
    // Import appends this exact trailer; the card already has a dedicated link.
    if (join_url.len > 0) {
        const trailer = try std.fmt.allocPrint(a, "Join: {s}", .{join_url});
        if (std.mem.endsWith(u8, value, trailer) and (value.len == trailer.len or value[value.len - trailer.len - 1] == '\n')) return std.mem.trimEnd(u8, value[0 .. value.len - trailer.len], " \t\r\n");
    }
    return value;
}

test "calendar UI: description displays inert HTML and omits the repeated Join trailer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rendered = try descriptionText(a, "<p>Planning &amp; notes</p><p><b>Discuss</b><br>Next steps</p><script>hidden()</script>", "");
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Planning & notes") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Discuss") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<") == null);
    try std.testing.expectEqualStrings("Bring notes", try descriptionText(a, "Bring notes\n\nJoin: https://meet.example.test/room", "https://meet.example.test/room"));
}

test "calendar UI: camera and Join require one safe HTTPS noncancelled event" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "http://meet.example.test/room", "javascript:alert(1)", "https://user:pass@meet.example.test/room", "https://meet.example.test/room\n" }) |url| {
        try std.testing.expect(!canJoin(try j.value(a, .{ .join_url = url, .cancelled = false })));
    }
    try std.testing.expect(canJoin(try j.value(a, .{ .join_url = "https://meet.example.test/room", .cancelled = false })));
    try std.testing.expect(!canJoin(try j.value(a, .{ .join_url = "https://meet.example.test/room", .cancelled = true })));
    try std.testing.expectEqual(@as(u16, 88), cardWidth(140));
    try std.testing.expectEqual(@as(u16, 82), cardWidth(82));
    try std.testing.expectEqual(@as(u16, 48), cardWidth(48));
}
pub fn gridDays(width: u16) usize {
    return if (width >= 104) 7 else if (width >= 60) 3 else 0;
}
pub fn pointDay(point: t.time.Point, zone: *const tz.Zone) !i64 {
    return if (point.kind == .date) point.value else zone.localDay(point.value);
}
pub fn touchesDay(start: t.time.Point, end: t.time.Point, day: i64, zone: *const tz.Zone) !bool {
    if (start.kind != end.kind) return error.InvalidCalendarTime;
    const first = try pointDay(start, zone);
    // End is exclusive for DATE and timed intervals, including local midnight.
    var last = end;
    last.value = @max(start.value, last.value - 1);
    return day >= first and day <= try pointDay(last, zone);
}
pub fn clock(a: std.mem.Allocator, point: t.time.Point, zone: *const tz.Zone) ![]const u8 {
    if (point.kind == .date) return "all-day";
    const value = try zone.format(a, point.value);
    return if (value.len >= 16) value[11..16] else "--:--";
}
pub fn matches(event: j.Value, query: []const u8) bool {
    if (j.get(event, "cancelled")) |value| if (value == .bool and value.bool) return false;
    if (query.len == 0) return true;
    for ([_][]const u8{ "summary", "description", "location", "organizer" }) |field| {
        const value = j.get(event, field) orelse continue;
        if (value == .string and @import("unicode_search.zig").find(value.string, query) != null) return true;
    }
    return false;
}
test "calendar UI: width breakpoints preserve readable week columns" {
    try std.testing.expectEqual(@as(usize, 0), gridDays(59));
    try std.testing.expectEqual(@as(usize, 3), gridDays(60));
    try std.testing.expectEqual(@as(usize, 7), gridDays(104));
}
test "calendar UI: all-day civil spans use exclusive end and ignore display zone" {
    const zone: tz.Zone = .{ .unavailable = true };
    const start: t.time.Point = .{ .kind = .date, .value = 20000 };
    const end: t.time.Point = .{ .kind = .date, .value = 20003 };
    try std.testing.expect(try touchesDay(start, end, 20002, &zone));
    try std.testing.expect(!try touchesDay(start, end, 20003, &zone));
    try std.testing.expectEqualStrings("?", responseMark("needs_action"));
    try std.testing.expectEqual(@as(i64, 1), period(.day));
    try std.testing.expectEqual(@as(i64, 7), period(.week));
}

test "calendar UI: replaced view owns its source and never appends event history" {
    const a = std.testing.allocator;
    var view: Document = .{};
    defer view.deinit();
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const source = try j.value(arena.allocator(), .{ .summary = "Synthetic meeting", .cancelled = false });
        try view.replace(a, source);
    }
    try std.testing.expect(matches(view.value, "MEETING"));
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try view.replace(a, try j.value(arena.allocator(), .{ .summary = "Removed", .cancelled = true }));
    try std.testing.expect(!matches(view.value, ""));
}

/// User-facing wording stays independent of persistence/command enum names.
pub fn actionLabel(raw: []const u8) []const u8 {
    const labels = [_]struct { []const u8, []const u8 }{
        .{ "import_missing", "Add to Calendar" },                                 .{ "import_event", "Add to Calendar" },
        .{ "review_update", "Apply organizer's update" },                         .{ "update_event", "Apply organizer's update" },
        .{ "review_cancel", "Apply organizer's cancellation" },                   .{ "cancel_event", "Apply organizer's cancellation" },
        .{ "existing", "Already in this calendar" },                              .{ "previously_cancelled", "Already cancelled" },
        .{ "no_event_to_cancel", "No matching event to cancel" },                 .{ "reconcile_unknown", "Reconcile unknown outcome" },
        .{ "reconciled", "Previous action verified" },                            .{ "ambiguous", "Multiple matches need review" },
        .{ "lookup_incomplete", "Lookup incomplete; no action allowed" },         .{ "identity_conflict", "Invitation identity conflict" },
        .{ "stale_source", "A newer invitation was already processed" },          .{ "unsupported_recurrence", "Recurring invitation requires manual review" },
        .{ "time_review_required", "Resolve invitation timezone before adding" },
    };
    for (labels) |label| if (std.mem.eql(u8, raw, label[0])) return label[1];
    return if (raw.len > 0) raw else "Checking invitation…";
}

/// Copyable grant guides are shell text. Treat even a valid email atom as data.
pub fn shellQuoted(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    try result.append(a, '\'');
    for (raw) |byte| {
        if (byte == '\'') try result.appendSlice(a, "'\\''") else try result.append(a, byte);
    }
    try result.append(a, '\'');
    return result.toOwnedSlice(a);
}

test "calendar UI: grant command quotes preserve literal apostrophes and substitutions" {
    const a = std.testing.allocator;
    const quoted = try shellQuoted(a, "o'neil$(literal)@example.test");
    defer a.free(quoted);
    try std.testing.expectEqualStrings("'o'\\''neil$(literal)@example.test'", quoted);
}
