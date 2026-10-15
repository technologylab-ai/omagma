//! Account-bound Calendar visibility and presentation. Provider snapshots keep
//! their own source identities; this module only builds a bounded display view.
const std = @import("std");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const t = @import("calendar_types.zig");
const tz = @import("timezone.zig");
const theme = @import("theme.zig");

pub const max_sources = 3 * t.Limits.calendars;
pub const max_events = 3 * t.Limits.snapshot_events;
pub const Scope = enum { account, all_accounts };
/// Theme roles, never provider-supplied or hardcoded terminal RGB values.
pub const Color = enum { cyan, green, magenta, yellow, blue, orange, foreground, red };
/// A preference identifies one exact account/source, independently of its
/// current visibility, read access, theme colour or provider display name.
pub const SourceKey = struct {
    account: b.Text(254) = .{},
    calendar_id: b.Text(1024) = .{},
    pub fn init(source: t.Target) !SourceKey {
        try source.validate();
        var result: SourceKey = .{};
        try result.account.set(source.account);
        try result.calendar_id.set(source.calendar_id);
        return result;
    }
    pub fn target(self: *const SourceKey) t.Target {
        return .{ .account = self.account.slice(), .calendar_id = self.calendar_id.slice() };
    }
};
pub const Choice = struct {
    account: b.Text(254) = .{},
    calendar_id: b.Text(1024) = .{},
    visible: bool = true,
    color: ?Color = null,
    pub fn target(self: *const Choice) t.Target {
        return .{ .account = self.account.slice(), .calendar_id = self.calendar_id.slice() };
    }
};
pub const ChoiceWire = struct { account: []const u8, calendarId: []const u8, visible: bool = true, color: ?Color = null };
pub const SourceKeyWire = struct { account: []const u8, calendarId: []const u8 };
pub const Wire = struct { scope: Scope = .account, sources: []const ChoiceWire = &.{}, preferred: ?SourceKeyWire = null };
pub const Selection = struct {
    scope: Scope = .account,
    choices: [max_sources]?Choice = @splat(null),
    preferred: ?SourceKey = null,
    pub fn isPreferred(self: *const Selection, source: t.Target) bool {
        return if (self.preferred) |key| key.target().eql(source) else false;
    }
    /// Only records presentation preference; never enables or grants access.
    /// Validation occurs before replacing an existing preference.
    pub fn setPreferred(self: *Selection, source: t.Target) !void {
        self.preferred = try SourceKey.init(source);
    }
    pub fn clearPreferred(self: *Selection) void {
        self.preferred = null;
    }
    pub fn find(self: *const Selection, target: t.Target) ?*const Choice {
        for (&self.choices) |*choice| if (choice.*) |*value| if (value.target().eql(target)) return value;
        return null;
    }
    pub fn selected(self: *const Selection, calendar: j.Value) bool {
        const target = jsonTarget(calendar) catch return false;
        if (self.find(target)) |choice| return choice.visible;
        return (j.boolean(calendar, "selected", false) catch false) or (j.boolean(calendar, "primary", false) catch false);
    }
    pub fn color(self: *const Selection, target: t.Target) Color {
        if (self.find(target)) |choice| if (choice.color) |value| return value;
        return defaultColor(target);
    }
    pub fn set(self: *Selection, target: t.Target, visible: bool, selected_color: ?Color) !void {
        try target.validate();
        var free: ?usize = null;
        for (&self.choices, 0..) |*choice, index| {
            if (choice.*) |*value| {
                if (value.target().eql(target)) {
                    value.visible = visible;
                    value.color = selected_color;
                    return;
                }
            } else if (free == null) free = index;
        }
        var choice: Choice = .{ .visible = visible, .color = selected_color };
        try choice.account.set(target.account);
        try choice.calendar_id.set(target.calendar_id);
        self.choices[free orelse return error.TooManyCalendarSources] = choice;
    }
    /// Only authoritative account discovery may remove saved overrides.
    /// A missing/offline/partial list must never erase the user's choices.
    pub fn pruneAccount(self: *Selection, account: []const u8, entries: []const j.Value) void {
        for (&self.choices) |*optional| if (optional.*) |choice| {
            if (!std.ascii.eqlIgnoreCase(choice.account.slice(), account)) continue;
            var found = false;
            for (entries) |entry| {
                const target = jsonTarget(j.get(entry, "calendar") orelse continue) catch continue;
                found = found or choice.target().eql(target);
            }
            if (!found) optional.* = null;
        };
        if (self.preferred) |key| {
            if (!std.ascii.eqlIgnoreCase(key.account.slice(), account)) return;
            for (entries) |entry| {
                const source = jsonTarget(j.get(entry, "calendar") orelse continue) catch continue;
                if (key.target().eql(source)) return;
            }
            self.clearPreferred();
        }
    }
    pub fn pruneDiscovered(self: *Selection, result: j.Value) void {
        const valid = validateCatalogueAccount(result, &.{}) catch return;
        if (!valid.complete or valid.stale) return;
        self.pruneAccount(j.text(result, "account"), valid.entries);
    }
    pub fn pruneConfiguredAccounts(self: *Selection, accounts: []const j.Value) void {
        if (accounts.len == 0) return;
        for (&self.choices) |*optional| if (optional.*) |choice| {
            var found = false;
            for (accounts) |account| found = found or std.ascii.eqlIgnoreCase(choice.account.slice(), j.text(account, "address"));
            if (!found) optional.* = null;
        };
        if (self.preferred) |key| {
            for (accounts) |account| if (std.ascii.eqlIgnoreCase(key.account.slice(), j.text(account, "address"))) return;
            self.clearPreferred();
        }
    }
};
pub fn fromWire(wire: Wire) !Selection {
    if (wire.sources.len > max_sources) return error.TooManyCalendarSources;
    var result: Selection = .{ .scope = wire.scope };
    for (wire.sources) |source| {
        const target: t.Target = .{ .account = source.account, .calendar_id = source.calendarId };
        if (result.find(target) != null) return error.DuplicateCalendarSource;
        try result.set(target, source.visible, source.color);
    }
    if (wire.preferred) |source| try result.setPreferred(.{ .account = source.account, .calendar_id = source.calendarId });
    return result;
}
pub fn toWire(selection: *const Selection, storage: *[max_sources]ChoiceWire) Wire {
    var count: usize = 0;
    for (&selection.choices) |*choice| if (choice.*) |*value| {
        storage[count] = .{ .account = value.account.slice(), .calendarId = value.calendar_id.slice(), .visible = value.visible, .color = value.color };
        count += 1;
    };
    return .{ .scope = selection.scope, .sources = storage[0..count], .preferred = if (selection.preferred) |*key| .{ .account = key.account.slice(), .calendarId = key.calendar_id.slice() } else null };
}
pub fn defaultColor(target: t.Target) Color {
    var hash = std.hash.Wyhash.init(0);
    for (target.account) |byte| hash.update(&.{std.ascii.toLower(byte)});
    hash.update(&.{0});
    hash.update(target.calendar_id);
    return @fromBackingInt(@as(u3, @intCast(hash.final() % 6)));
}
pub fn rgb(color: Color, palette: theme.Palette) theme.Color {
    return switch (color) {
        .cyan => palette.cyan,
        .green => palette.green,
        .yellow => palette.yellow,
        .magenta => palette.magenta,
        .blue => palette.blue,
        .orange => palette.orange,
        .red => palette.red,
        .foreground => palette.foreground,
    };
}
fn luminance(value: theme.Color) f64 {
    var result: f64 = 0;
    for (value, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
        const scaled = @as(f64, @floatFromInt(channel)) / 255;
        result += (if (scaled <= 0.04045) scaled / 12.92 else std.math.pow(f64, (scaled + 0.055) / 1.055, 2.4)) * weight;
    }
    return result;
}
fn contrast(left: theme.Color, right: theme.Color) f64 {
    const l = luminance(left);
    const r = luminance(right);
    return (@max(l, r) + 0.05) / (@min(l, r) + 0.05);
}
fn near(left: theme.Color, right: theme.Color) bool {
    var distance: i32 = 0;
    for (left, right) |l, r| {
        const difference: i32 = @as(i32, l) - r;
        distance += difference * difference;
    }
    return distance < 24 * 24;
}
/// A theme may alias magenta to its error red, or choose a very dark blue.
/// Keep automatic source badges legible without inventing colors outside the
/// current theme. Letter labels provide identity when theme colors coincide.
pub fn readableRgb(color: Color, palette: theme.Palette) theme.Color {
    const preferred = rgb(color, palette);
    if (contrast(preferred, palette.background) >= 3 and (color == .red or !near(preferred, palette.red))) return preferred;
    var fallback = palette.foreground;
    var score = contrast(fallback, palette.background);
    for ([_]Color{ .cyan, .green, .magenta, .yellow, .blue, .orange, .foreground }) |candidate| {
        const value = rgb(candidate, palette);
        if (near(value, palette.red)) continue;
        const candidate_score = contrast(value, palette.background);
        if (candidate_score > score) {
            fallback = value;
            score = candidate_score;
        }
    }
    return fallback;
}
pub fn jsonTarget(value: j.Value) !t.Target {
    const object = j.get(value, "target") orelse return error.InvalidCalendarResponse;
    const result: t.Target = .{ .account = try j.required(object, "account"), .calendar_id = try j.required(object, "calendar_id") };
    try result.validate();
    return result;
}

/// List results are already scoped to configured accounts by the caller. Every
/// contained calendar must match its envelope, including stale discovery.
pub fn catalogue(a: std.mem.Allocator, selection: *const Selection, results: []const j.Value, active_account: []const u8) !j.Value {
    if (results.len > 3) return error.TooManyCalendarAccounts;
    var entries: std.ArrayList(j.Value) = .empty;
    var complete = true;
    var stale = false;
    var unavailable: usize = 0;
    for (results, 0..) |result, account_index| {
        const account = j.required(result, "account") catch {
            complete = false;
            unavailable += 1;
            continue;
        };
        if (selection.scope == .account and !std.ascii.eqlIgnoreCase(account, active_account)) continue;
        const valid = validateCatalogueAccount(result, results[0..account_index]) catch {
            complete = false;
            unavailable += 1;
            continue;
        };
        complete = complete and valid.complete;
        const source_stale = valid.stale;
        stale = stale or source_stale;
        for (valid.entries) |entry| {
            const calendar = j.get(entry, "calendar").?;
            const target = try jsonTarget(calendar);
            var display = try j.copyObject(a, entry);
            try display.object.put(a, "visible", .{ .bool = try j.boolean(entry, "canRead", false) and selection.selected(calendar) });
            try display.object.put(a, "source_stale", .{ .bool = source_stale });
            try display.object.put(a, "color", .{ .string = @tagName(selection.color(target)) });
            try entries.append(a, display);
        }
    }
    return j.value(a, .{ .calendars = entries.items, .complete = complete, .stale = stale, .unavailableAccounts = unavailable });
}
fn validateCatalogueAccount(result: j.Value, previous_results: []const j.Value) !struct { entries: []const j.Value, complete: bool, stale: bool } {
    const account = try j.required(result, "account");
    try b.address(account);
    for (previous_results) |prior| if (std.ascii.eqlIgnoreCase(account, j.text(prior, "account"))) return error.DuplicateCalendarAccount;
    const calendars = j.get(result, "calendars") orelse return error.InvalidCalendarResponse;
    if (calendars != .array or calendars.array.items.len > t.Limits.calendars) return error.TooManyCalendars;
    for (calendars.array.items, 0..) |entry, index| {
        const calendar = j.get(entry, "calendar") orelse return error.InvalidCalendarResponse;
        const target = try jsonTarget(calendar);
        if (!std.ascii.eqlIgnoreCase(target.account, account)) return error.CalendarAccountMismatch;
        _ = try j.boolean(entry, "canRead", false);
        _ = try j.boolean(entry, "canWrite", false);
        _ = try j.boolean(calendar, "primary", false);
        _ = try j.boolean(calendar, "selected", false);
        for (calendars.array.items[0..index]) |previous| if ((try jsonTarget(j.get(previous, "calendar").?)).eql(target)) return error.DuplicateCalendarSource;
    }
    return .{ .entries = calendars.array.items, .complete = try j.boolean(result, "complete", false), .stale = try j.boolean(result, "stale", false) or try j.boolean(result, "cached", false) };
}

pub const Input = struct { calendar: j.Value, snapshot: ?j.Value = null, refresh_error: []const u8 = "", catalogue_stale: bool = false, color: Color = .cyan };
const SortEvent = struct { value: j.Value, day: i64, all_day: bool, instant: i64, target: t.Target, id: []const u8 };
fn less(_: void, left: SortEvent, right: SortEvent) bool {
    if (left.day != right.day) return left.day < right.day;
    if (left.all_day != right.all_day) return left.all_day;
    if (left.instant != right.instant) return left.instant < right.instant;
    const account = std.ascii.orderIgnoreCase(left.target.account, right.target.account);
    if (account != .eq) return account == .lt;
    const calendar = std.mem.order(u8, left.target.calendar_id, right.target.calendar_id);
    if (calendar != .eq) return calendar == .lt;
    return std.mem.lessThan(u8, left.id, right.id);
}
pub fn validateSnapshot(a: std.mem.Allocator, input: Input, window: t.Window) !void {
    const snapshot = input.snapshot orelse return;
    const target = try jsonTarget(input.calendar);
    if (!(try jsonTarget(snapshot)).eql(target)) return error.CalendarAccountMismatch;
    const bound = try j.decode(t.Window, a, j.get(snapshot, "window") orelse return error.InvalidCalendarResponse);
    if (bound.start_ms != window.start_ms or bound.end_ms != window.end_ms or !std.mem.eql(u8, bound.time_zone, window.time_zone)) return error.CalendarWindowMismatch;
    _ = try j.boolean(snapshot, "complete", false);
    _ = try j.boolean(snapshot, "stale", false);
    if (try j.integer(snapshot, "fetched_at_ms", 0) < 0) return error.InvalidCalendarResponse;
    const events = j.get(snapshot, "events") orelse return error.InvalidCalendarResponse;
    if (events != .array or events.array.items.len > t.Limits.snapshot_events) return error.TooManyCalendarEvents;
    for (events.array.items, 0..) |event, index| {
        if (!(try jsonTarget(event)).eql(target)) return error.CalendarAccountMismatch;
        const id = try j.required(event, "id");
        try t.text(id, 1024, false);
        for (events.array.items[0..index]) |previous| if (std.mem.eql(u8, id, j.text(previous, "id"))) return error.CalendarPageOverlap;
        if (try j.boolean(event, "cancelled", false)) continue;
        const start = try j.decode(t.time.Point, a, j.get(event, "start") orelse return error.InvalidCalendarTime);
        const end = try j.decode(t.time.Point, a, j.get(event, "end") orelse return error.InvalidCalendarTime);
        if (start.kind != end.kind or end.value < start.value) return error.InvalidCalendarTime;
    }
}
/// Merge only an identical requested instant window, projected in one display
/// zone. All-day dates remain dates, and are never shifted by another account's
/// zone. Failure/partial/stale state is retained per source and in the summary.
pub fn merge(a: std.mem.Allocator, inputs: []const Input, window: t.Window, zone: *const tz.Zone) !j.Value {
    try window.validate();
    if (inputs.len > max_sources) return error.TooManyCalendarSources;
    var events: std.ArrayList(SortEvent) = .empty;
    var statuses: std.ArrayList(j.Value) = .empty;
    var complete = inputs.len != 0;
    var stale = false;
    var truncated = false;
    var failed: usize = 0;
    var stale_count: usize = 0;
    var fetched_at: i64 = 0;
    var bytes: usize = 0;
    const first_day = try zone.localDay(window.start_ms);
    const last_day = try zone.localDay(window.end_ms - 1);
    for (inputs, 0..) |input, source_index| {
        const target = try jsonTarget(input.calendar);
        for (inputs[0..source_index]) |prior| if ((try jsonTarget(prior.calendar)).eql(target)) return error.DuplicateCalendarSource;
        validateSnapshot(a, input, window) catch |err| {
            failed += 1;
            stale_count += 1;
            stale = true;
            complete = false;
            try statuses.append(a, try j.value(a, .{ .target = target, .name = j.text(input.calendar, "summary"), .complete = false, .stale = true, .missing = true, .refreshError = @errorName(err), .events = @as(usize, 0), .color = @tagName(input.color) }));
            continue;
        };
        var source_complete = false;
        var source_stale = input.catalogue_stale or input.refresh_error.len != 0;
        var retained: usize = 0;
        if (input.snapshot) |snapshot| {
            if (!(try jsonTarget(snapshot)).eql(target)) return error.CalendarAccountMismatch;
            const bound = try j.decode(t.Window, a, j.get(snapshot, "window") orelse return error.InvalidCalendarResponse);
            if (bound.start_ms != window.start_ms or bound.end_ms != window.end_ms or !std.mem.eql(u8, bound.time_zone, window.time_zone)) return error.CalendarWindowMismatch;
            source_complete = try j.boolean(snapshot, "complete", false);
            source_stale = source_stale or try j.boolean(snapshot, "stale", false);
            const fetched = try j.integer(snapshot, "fetched_at_ms", 0);
            if (fetched < 0) return error.InvalidCalendarResponse;
            if (fetched_at == 0 or (fetched > 0 and fetched < fetched_at)) fetched_at = fetched;
            const values = j.get(snapshot, "events") orelse return error.InvalidCalendarResponse;
            if (values != .array or values.array.items.len > t.Limits.snapshot_events) return error.TooManyCalendarEvents;
            for (values.array.items, 0..) |event, index| {
                if (!(try jsonTarget(event)).eql(target)) return error.CalendarAccountMismatch;
                const id = try j.required(event, "id");
                try t.text(id, 1024, false);
                for (values.array.items[0..index]) |previous| if (std.mem.eql(u8, id, j.text(previous, "id"))) return error.CalendarPageOverlap;
                if (try j.boolean(event, "cancelled", false)) continue;
                const start_value = j.get(event, "start") orelse return error.InvalidCalendarTime;
                const end_value = j.get(event, "end") orelse return error.InvalidCalendarTime;
                const start = try j.decode(t.time.Point, a, start_value);
                const end = try j.decode(t.time.Point, a, end_value);
                if (start.kind != end.kind or end.value < start.value) return error.InvalidCalendarTime;
                const overlaps = if (start.kind == .instant) start.value < window.end_ms and @max(end.value, start.value +| 1) > window.start_ms else start.value <= last_day and @max(end.value, start.value +| 1) > first_day;
                if (!overlaps) continue;
                // Retain bounded header data for the grid. Full description is
                // fetched account-bound when details are opened, avoiding 72
                // sources duplicating entire large event descriptions.
                var display = try j.copyObject(a, event);
                try display.object.put(a, "description", .{ .string = "" });
                try display.object.put(a, "source_name", .{ .string = j.text(input.calendar, "summary") });
                try display.object.put(a, "source_color", .{ .string = @tagName(input.color) });
                try display.object.put(a, "source_stale", .{ .bool = source_stale });
                const raw = try std.json.Stringify.valueAlloc(a, display, .{});
                if (events.items.len == max_events or raw.len + bytes > t.Limits.snapshot_bytes - 65536) {
                    truncated = true;
                    source_complete = false;
                    continue;
                }
                bytes += raw.len;
                try events.append(a, .{ .value = display, .day = if (start.kind == .date) start.value else try zone.localDay(start.value), .all_day = start.kind == .date, .instant = start.value, .target = target, .id = id });
                retained += 1;
            }
        } else failed += 1;
        if (source_stale) stale_count += 1;
        stale = stale or source_stale;
        complete = complete and source_complete;
        try statuses.append(a, try j.value(a, .{ .target = target, .name = j.text(input.calendar, "summary"), .complete = source_complete, .stale = source_stale, .missing = input.snapshot == null, .refreshError = input.refresh_error, .events = retained, .color = @tagName(input.color) }));
    }
    std.mem.sort(SortEvent, events.items, {}, less);
    const values = try a.alloc(j.Value, events.items.len);
    for (events.items, values) |event, *value| value.* = event.value;
    return j.value(a, .{ .snapshot = .{ .window = window, .events = values, .complete = complete and !truncated, .stale = stale, .fetched_at_ms = fetched_at }, .sources = statuses.items, .failedSources = failed, .staleSources = stale_count, .truncated = truncated });
}

test "calendar sources: visibility and themed colors stay account and calendar bound" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const work = try j.value(temp, .{ .target = .{ .account = "work@example.test", .calendar_id = "holidays" }, .selected = true });
    const personal = try j.value(temp, .{ .target = .{ .account = "personal@example.test", .calendar_id = "holidays" }, .selected = true });
    var selection: Selection = .{};
    try selection.set(try jsonTarget(work), false, .yellow);
    try std.testing.expect(!selection.selected(work));
    try std.testing.expect(selection.selected(personal));
    try std.testing.expectEqual(Color.yellow, selection.color(try jsonTarget(work)));
    var storage: [max_sources]ChoiceWire = undefined;
    const restored = try fromWire(toWire(&selection, &storage));
    try std.testing.expect(!restored.selected(work));
    try std.testing.expectEqual(defaultColor(.{ .account = "WORK@example.test", .calendar_id = "primary" }), defaultColor(.{ .account = "work@example.test", .calendar_id = "primary" }));
    var palette: theme.Palette = .{};
    palette.yellow = .{ 1, 2, 3 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &rgb(.yellow, palette));
    try std.testing.expectError(error.DuplicateCalendarSource, fromWire(.{ .sources = &.{ .{ .account = "work@example.test", .calendarId = "same" }, .{ .account = "WORK@example.test", .calendarId = "same" } } }));
}

test "calendar sources: one preferred exact source owns its identity without changing visibility colour or scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var account = "work@example.test".*;
    var calendar_id = "team/会議".*;
    const work = try j.value(a, .{ .target = t.Target{ .account = &account, .calendar_id = &calendar_id }, .selected = true });
    const personal = try j.value(a, .{ .target = t.Target{ .account = "personal@example.test", .calendar_id = &calendar_id }, .selected = true });
    const expected: t.Target = .{ .account = "work@example.test", .calendar_id = "team/会議" };
    var selection: Selection = .{ .scope = .all_accounts };
    try selection.set(expected, false, .orange);
    try selection.set(try jsonTarget(personal), true, .green);
    try selection.setPreferred(.{ .account = &account, .calendar_id = &calendar_id });
    @memset(&account, 'x');
    @memset(&calendar_id, 'x');
    try std.testing.expect(selection.isPreferred(expected));
    try std.testing.expect(selection.isPreferred(.{ .account = "WORK@example.test", .calendar_id = expected.calendar_id }));
    try std.testing.expect(!selection.isPreferred(try jsonTarget(personal)));
    try std.testing.expect(!selection.isPreferred(.{ .account = expected.account, .calendar_id = "team/会議-other" }));
    try std.testing.expect(!selection.selected(work));
    try std.testing.expect(selection.selected(personal));
    try std.testing.expectEqual(Color.orange, selection.color(expected));
    try std.testing.expectEqual(Scope.all_accounts, selection.scope);
    var storage: [max_sources]ChoiceWire = undefined;
    const restored = try fromWire(toWire(&selection, &storage));
    try std.testing.expect(restored.isPreferred(expected));
    try std.testing.expect(!restored.selected(work));
    try std.testing.expect(restored.selected(personal));
    try std.testing.expectEqual(Color.orange, restored.color(expected));
    try selection.setPreferred(try jsonTarget(personal));
    try std.testing.expect(!selection.isPreferred(expected));
    selection.clearPreferred();
    try std.testing.expect(selection.preferred == null);
    try std.testing.expect(!selection.selected(work));
    try std.testing.expectEqual(Color.orange, selection.color(expected));
    try std.testing.expectEqual(Scope.all_accounts, selection.scope);
}

test "calendar sources: preferred identity validates bounds atomically and never truncates Unicode" {
    var account: [254]u8 = @splat('a');
    account[1] = '@';
    const calendar_id: [1024]u8 = @splat('c');
    var selection: Selection = .{};
    try selection.setPreferred(.{ .account = &account, .calendar_id = &calendar_id });
    const long_account: [255]u8 = @splat('a');
    const long_calendar: [1025]u8 = @splat('c');
    try std.testing.expectError(error.InvalidAddress, selection.setPreferred(.{ .account = &long_account, .calendar_id = "primary" }));
    try std.testing.expectError(error.InvalidCalendarField, selection.setPreferred(.{ .account = "work@example.test", .calendar_id = &long_calendar }));
    try std.testing.expectError(error.InvalidCalendarField, selection.setPreferred(.{ .account = "work@example.test", .calendar_id = "" }));
    try std.testing.expectError(error.InvalidCalendarField, selection.setPreferred(.{ .account = "work@example.test", .calendar_id = "calendar\ncontrol" }));
    try std.testing.expectError(error.InvalidUtf8, selection.setPreferred(.{ .account = "work@example.test", .calendar_id = &.{ 0xc0, 0x80 } }));
    try std.testing.expect(selection.isPreferred(.{ .account = &account, .calendar_id = &calendar_id }));
    try std.testing.expectEqual(@as(usize, 254), selection.preferred.?.account.len);
    try std.testing.expectEqual(@as(usize, 1024), selection.preferred.?.calendar_id.len);
    try std.testing.expectError(error.InvalidAddress, fromWire(.{ .preferred = .{ .account = "missing-at", .calendarId = "primary" } }));
    try std.testing.expectError(error.InvalidCalendarField, fromWire(.{ .preferred = .{ .account = "work@example.test", .calendarId = "" } }));
}

test "calendar sources: preferred sources survive unavailable partial stale and hidden discovery but prune proven removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target: t.Target = .{ .account = "work@example.test", .calendar_id = "shared" };
    var selection: Selection = .{};
    try selection.set(target, false, .blue);
    try selection.setPreferred(target);
    var response = try j.value(a, .{ .account = target.account, .complete = false, .calendars = @as([]const j.Value, &.{}) });
    selection.pruneDiscovered(response);
    try std.testing.expect(selection.isPreferred(target));
    try response.object.put(a, "complete", .{ .bool = true });
    try response.object.put(a, "stale", .{ .bool = true });
    selection.pruneDiscovered(response);
    try std.testing.expect(selection.isPreferred(target));
    try response.object.put(a, "stale", .{ .bool = false });
    try response.object.put(a, "cached", .{ .bool = true });
    selection.pruneDiscovered(response);
    try std.testing.expect(selection.isPreferred(target));
    try response.object.put(a, "cached", .{ .bool = false });
    try response.object.put(a, "calendars", .{ .string = "malformed" });
    selection.pruneDiscovered(response);
    try std.testing.expect(selection.isPreferred(target));
    const unreadable = try j.value(a, .{ .account = target.account, .complete = true, .calendars = .{.{ .calendar = .{ .target = target, .selected = false }, .canRead = false }} });
    selection.pruneDiscovered(unreadable);
    try std.testing.expect(selection.isPreferred(target));
    try std.testing.expect(!selection.find(target).?.visible);
    try std.testing.expectEqual(Color.blue, selection.find(target).?.color.?);
    const another_account = try j.value(a, .{ .account = "personal@example.test", .complete = true, .calendars = @as([]const j.Value, &.{}) });
    selection.pruneDiscovered(another_account);
    try std.testing.expect(selection.isPreferred(target));
    try response.object.put(a, "calendars", .{ .array = .init(a) });
    selection.pruneDiscovered(response);
    try std.testing.expect(selection.preferred == null);
    try selection.setPreferred(target);
    selection.pruneConfiguredAccounts(&.{}); // No authoritative account list yet.
    try std.testing.expect(selection.isPreferred(target));
    const configured = try j.value(a, .{ .{ .address = "WORK@example.test" }, .{ .address = "personal@example.test" } });
    selection.pruneConfiguredAccounts(configured.array.items);
    try std.testing.expect(selection.isPreferred(target));
    const removed = try j.value(a, .{.{ .address = "personal@example.test" }});
    selection.pruneConfiguredAccounts(removed.array.items);
    try std.testing.expect(selection.preferred == null);
}

fn testCalendar(a: std.mem.Allocator, account: []const u8, id: []const u8, name: []const u8) !j.Value {
    return j.value(a, .{ .target = t.Target{ .account = account, .calendar_id = id }, .summary = name, .selected = true, .time_zone = "UTC", .access = "reader" });
}
fn testEvent(a: std.mem.Allocator, target: t.Target, id: []const u8, start: t.time.Point, end: t.time.Point) !j.Value {
    return j.value(a, t.Event{ .target = target, .id = id, .uid = "same-invitation@example.test", .summary = id, .description = "Full details are fetched only on opening.", .start = start, .end = end });
}
fn testSnapshot(a: std.mem.Allocator, target: t.Target, window: t.Window, events: []const j.Value, stale: bool) !j.Value {
    return j.value(a, .{ .target = target, .window = window, .events = events, .complete = true, .stale = stale, .fetched_at_ms = @as(i64, 100) });
}
test "calendar sources: same IDs and invitation UID across accounts remain distinct while all-day dates survive DST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var zone = try tz.Zone.fromPosix("CET-1CEST,M3.5.0/2,M10.5.0/3");
    defer zone.deinit(a);
    const day = try tz.dateDay("2026-10-25");
    const window: t.Window = .{ .start_ms = try zone.fromLocal(try tz.parseDate("2026-10-25")), .end_ms = try zone.fromLocal(try tz.parseDate("2026-10-26")), .time_zone = "Europe/Vienna" };
    try std.testing.expectEqual(@as(i64, 25 * 3600000), window.end_ms - window.start_ms);
    const work = try testCalendar(a, "work@example.test", "primary", "Work");
    const holidays = try testCalendar(a, "work@example.test", "holidays", "Holidays");
    const personal = try testCalendar(a, "personal@example.test", "primary", "Personal");
    const instant = try t.time.rfc3339("2026-10-24T23:30:00Z");
    const work_event = try testEvent(a, try jsonTarget(work), "same-id", .{ .kind = .instant, .value = instant, .zone = "America/New_York" }, .{ .kind = .instant, .value = instant + 3600000 });
    const personal_event = try testEvent(a, try jsonTarget(personal), "same-id", .{ .kind = .instant, .value = instant }, .{ .kind = .instant, .value = instant + 3600000 });
    const holiday = try testEvent(a, try jsonTarget(holidays), "same-id", .{ .kind = .date, .value = day }, .{ .kind = .date, .value = day + 1 });
    const result = try merge(a, &.{
        .{ .calendar = personal, .snapshot = try testSnapshot(a, try jsonTarget(personal), window, &.{personal_event}, false), .color = .green },
        .{ .calendar = work, .snapshot = try testSnapshot(a, try jsonTarget(work), window, &.{work_event}, false), .color = .cyan },
        .{ .calendar = holidays, .snapshot = try testSnapshot(a, try jsonTarget(holidays), window, &.{holiday}, false), .color = .yellow },
    }, window, &zone);
    const events = j.get(j.get(result, "snapshot").?, "events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("holidays", (try jsonTarget(events[0])).calendar_id);
    try std.testing.expectEqual(day, try j.integer(j.get(events[0], "start").?, "value", -1));
    try std.testing.expectEqualStrings("personal@example.test", (try jsonTarget(events[1])).account);
    try std.testing.expectEqualStrings("work@example.test", (try jsonTarget(events[2])).account);
    try std.testing.expectEqualStrings("", j.text(events[2], "description"));
    try std.testing.expect(try j.boolean(j.get(result, "snapshot").?, "complete", false));
}
test "calendar sources: malformed stale missing and partial sources do not hide healthy neighbors or assert availability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone: tz.Zone = .{};
    const window: t.Window = .{ .start_ms = 0, .end_ms = 86400000, .time_zone = "UTC" };
    const good = try testCalendar(a, "work@example.test", "good", "Healthy");
    const wrong = try testCalendar(a, "work@example.test", "wrong", "Malformed");
    const stale = try testCalendar(a, "personal@example.test", "stale", "Saved");
    const missing = try testCalendar(a, "personal@example.test", "missing", "Unavailable");
    const event = try testEvent(a, try jsonTarget(good), "healthy", .{ .kind = .instant, .value = 1000 }, .{ .kind = .instant, .value = 2000 });
    const wrong_event = try testEvent(a, .{ .account = "injected@example.test", .calendar_id = "wrong" }, "injected", .{ .kind = .instant, .value = 1000 }, .{ .kind = .instant, .value = 2000 });
    const stale_event = try testEvent(a, try jsonTarget(stale), "saved", .{ .kind = .instant, .value = 3000 }, .{ .kind = .instant, .value = 4000 });
    const result = try merge(a, &.{
        .{ .calendar = wrong, .snapshot = try testSnapshot(a, try jsonTarget(wrong), window, &.{wrong_event}, false) },
        .{ .calendar = good, .snapshot = try testSnapshot(a, try jsonTarget(good), window, &.{event}, false) },
        .{ .calendar = stale, .snapshot = try testSnapshot(a, try jsonTarget(stale), window, &.{stale_event}, true), .refresh_error = "ConnectionRefused" },
        .{ .calendar = missing, .refresh_error = "CalendarPermissionRequired" },
    }, window, &zone);
    const snapshot = j.get(result, "snapshot").?;
    const events = j.get(snapshot, "events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("healthy", j.text(events[0], "id"));
    try std.testing.expect(!try j.boolean(events[0], "source_stale", true));
    try std.testing.expect(try j.boolean(events[1], "source_stale", false));
    try std.testing.expect(!try j.boolean(snapshot, "complete", true));
    try std.testing.expect(try j.boolean(snapshot, "stale", false));
    try std.testing.expectEqual(@as(i64, 2), try j.integer(result, "failedSources", -1));
    const statuses = j.get(result, "sources").?.array.items;
    try std.testing.expectEqualStrings("CalendarAccountMismatch", j.text(statuses[0], "refreshError"));
}
test "calendar sources: catalogue scope includes read-only holidays with independent visibility and detects crossed accounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try testCalendar(a, "work@example.test", "primary", "Work");
    const holidays = try testCalendar(a, "work@example.test", "holidays", "Holidays");
    const personal = try testCalendar(a, "personal@example.test", "primary", "Personal");
    const list_work = try j.value(a, .{ .account = "work@example.test", .complete = true, .calendars = .{ .{ .calendar = work, .canRead = true }, .{ .calendar = holidays, .canRead = true, .canWrite = false } } });
    const list_personal = try j.value(a, .{ .account = "personal@example.test", .complete = false, .calendars = .{.{ .calendar = personal, .canRead = true }} });
    var selection: Selection = .{};
    const one = try catalogue(a, &selection, &.{ list_work, list_personal }, "work@example.test");
    try std.testing.expectEqual(@as(usize, 2), j.get(one, "calendars").?.array.items.len);
    try std.testing.expect(try j.boolean(one, "complete", false));
    selection.scope = .all_accounts;
    try selection.set(try jsonTarget(holidays), false, null);
    const all = try catalogue(a, &selection, &.{ list_work, list_personal }, "work@example.test");
    const entries = j.get(all, "calendars").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(!try j.boolean(entries[1], "visible", true));
    try std.testing.expect(!try j.boolean(all, "complete", true));
    const crossed = try j.value(a, .{ .account = "work@example.test", .calendars = .{.{ .calendar = personal, .canRead = true }} });
    const isolated = try catalogue(a, &selection, &.{ crossed, list_personal }, "work@example.test");
    try std.testing.expect(!try j.boolean(isolated, "complete", true));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(isolated, "unavailableAccounts", 0));
    try std.testing.expectEqual(@as(usize, 1), j.get(isolated, "calendars").?.array.items.len);
    for (0..100) |index| try std.testing.expect(defaultColor(.{ .account = "work@example.test", .calendar_id = try std.fmt.allocPrint(a, "calendar-{d}", .{index}) }) != .red);
}

test "calendar sources: only complete valid fresh account discovery prunes retired overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var selected: Selection = .{};
    const current: t.Target = .{ .account = "work@example.test", .calendar_id = "current" };
    const retired: t.Target = .{ .account = current.account, .calendar_id = "retired" };
    const offline: t.Target = .{ .account = "offline@example.test", .calendar_id = "keep" };
    try selected.set(current, true, .green);
    try selected.set(retired, false, .cyan);
    try selected.set(offline, false, .magenta);
    var response = try j.value(a, .{ .account = current.account, .complete = false, .calendars = .{.{ .calendar = .{ .target = current }, .canRead = true }} });
    selected.pruneDiscovered(response);
    try std.testing.expect(selected.find(retired) != null);
    try response.object.put(a, "complete", .{ .bool = true });
    try response.object.put(a, "stale", .{ .bool = true });
    selected.pruneDiscovered(response);
    try std.testing.expect(selected.find(retired) != null);
    try response.object.put(a, "stale", .{ .bool = false });
    selected.pruneDiscovered(response);
    try std.testing.expect(selected.find(retired) == null);
    try std.testing.expect(selected.find(offline) != null);
    try std.testing.expectEqual(Color.green, selected.find(current).?.color.?);
}
