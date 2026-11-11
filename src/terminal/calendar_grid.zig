//! Block layout for the Calendar Day and Week grids. Civil-minute spans become
//! row blocks with bounded side-by-side lanes; all-day and day-long events
//! share a spanning band. Pure: no clock, no provider, no terminal state.
//! Every result is bounded by the caps below and allocated by the caller's
//! frame arena; the layout never depends on which event is focused, except
//! that an explicitly selected block is always drawn, on top (see `place`).
//! Invariant: no event is ever undrawn without being counted. A block is
//! drawn, or `hidden` (counted by "+N" at its first visible hour), or loses
//! rows to the floating selection (`cover_*`, counted where it loses them).
const std = @import("std");
const t = @import("calendar_types.zig");

/// Side-by-side lanes drawn in one overlapping cluster. More are "+N".
pub const max_lanes = 6;
/// Lanes tracked while assigning; a cluster deeper than this is hidden.
const tracked_lanes = 64;
/// Timed segments laid out per day column; later ones are counted as hidden.
pub const max_segments = 256;
/// Narrowest readable lane: one bar cell and seven text cells.
pub const min_lane_cells = 8;
/// All-day band rows tracked; the renderer shows at most a few.
pub const max_band_rows = 16;
pub const minutes_per_day = 24 * 60;

/// Timed events lasting a whole day or more read better as spanning bars
/// (as in common calendar applications) than as full-height blocks that
/// squeeze every other appointment of the week into a narrow lane.
pub fn inBand(start: t.time.Point, end: t.time.Point) bool {
    return start.kind == .date or end.value -| start.value >= 86_400_000;
}

/// Rows per hour for a timed grid of `rows` rows: 30-minute rows once ten
/// hours fit (the working day), finer rows only when the whole day still fits.
/// Below that one row per hour keeps a small terminal useful.
pub fn rowsPerHour(rows: usize) u8 {
    if (rows >= 24 * 4) return 4;
    if (rows >= 24 * 3) return 3;
    if (rows >= 20) return 2;
    return 1;
}
pub fn dayRows(rph: u8) usize {
    return 24 * @as(usize, rph);
}
/// Row containing `minute` (floor).
pub fn rowOf(minute: u16, rph: u8) usize {
    return @as(usize, @min(minute, minutes_per_day)) * rph / 60;
}
/// First row after a span ending at `minute` (ceiling).
pub fn rowEnd(minute: u16, rph: u8) usize {
    return (@as(usize, @min(minute, minutes_per_day)) * rph + 59) / 60;
}
/// Civil minute where `row` starts.
pub fn minuteOf(row: usize, rph: u8) u16 {
    return @intCast(@min(row * 60 / rph, minutes_per_day));
}

/// Lanes a column of `cells` can show readably.
pub fn laneCap(cells: usize) u8 {
    return @intCast(std.math.clamp(cells / min_lane_cells, 1, max_lanes));
}
/// First cell of `lane` among `lanes` equal lanes of a `cells`-wide column.
pub fn laneX(cells: usize, lane: usize, lanes: usize) usize {
    return cells * lane / @max(lanes, 1);
}

pub const Item = struct {
    /// Civil minutes within the day, `first < end <= 1440`.
    first: u16,
    end: u16,
    declined: bool = false,
    preferred: bool = false,
};
pub const Placement = struct {
    /// Rows of the full day, `top < bottom <= dayRows`.
    top: usize = 0,
    bottom: usize = 0,
    lane: u8 = 0,
    /// Consecutive lanes (from `lane`) the block may use without covering
    /// another drawn block of its cluster.
    span: u8 = 1,
    /// Lanes drawn for its overlapping cluster; widths are `cells / lanes`.
    lanes: u8 = 1,
    hidden: bool = false,
    /// A selection that had no free lane: drawn last, over its cluster's
    /// last lane (full width beyond `max_segments`), so lane geometry never
    /// shifts. Blocks beneath it lose those rows, as `cover_*` records.
    floating: bool = false,
    /// Rows `[cover_top, cover_bottom)` drawn over by the floating selection;
    /// empty when equal. A block covered entirely is `hidden` instead.
    cover_top: usize = 0,
    cover_bottom: usize = 0,

    pub fn covered(self: Placement) bool {
        return self.cover_bottom > self.cover_top;
    }
};

fn rowSpan(item: Item, rph: u8) struct { usize, usize } {
    const top = @min(rowOf(item.first, rph), dayRows(rph) - 1);
    // A zero-length or sub-row event still gets one readable row.
    return .{ top, @max(top + 1, @min(rowEnd(item.end, rph), dayRows(rph))) };
}

const Order = struct {
    items: []const Item,
    /// The real start minute first (rows follow it, so greedy lanes stay
    /// optimal); at the same minute non-declined, then Priority, then the
    /// longer event, then the caller's chronological order. Stable.
    fn less(self: Order, left: usize, right: usize) bool {
        const x = self.items[left];
        const y = self.items[right];
        if (x.first != y.first) return x.first < y.first;
        if (x.declined != y.declined) return !x.declined;
        if (x.preferred != y.preferred) return x.preferred;
        if (x.end - x.first != y.end - y.first) return x.end - x.first > y.end - y.first;
        return left < right;
    }
};

fn overlaps(a: Placement, b: Placement) bool {
    return a.top < b.bottom and b.top < a.bottom;
}

/// Lay out one day column `cells` wide. Items are in the caller's
/// chronological order; results use the same indices. Only `max_segments`
/// items are placed; any further item is returned hidden. `selected`, when
/// given, is always drawn: without a lane of its own (or beyond
/// `max_segments`) it floats over its cluster's last lane (full width), and
/// every block beneath it records the rows it loses.
pub fn place(a: std.mem.Allocator, items: []const Item, rph: u8, cells: usize, selected: ?usize) ![]Placement {
    std.debug.assert(rph >= 1 and rph <= 4);
    const lane_cap = laneCap(cells);
    const result = try a.alloc(Placement, items.len);
    errdefer a.free(result);
    const laid = @min(items.len, max_segments);
    for (items, result, 0..) |item, *placement, index| {
        const span = rowSpan(item, rph);
        placement.* = .{ .top = span[0], .bottom = span[1], .hidden = index >= laid };
    }
    const order = try a.alloc(usize, laid);
    defer a.free(order);
    for (order, 0..) |*value, index| value.* = index;
    std.mem.sort(usize, order, Order{ .items = items }, Order.less);
    var lane_end: [tracked_lanes]usize = undefined;
    var cluster_start: usize = 0;
    var cluster_bottom: usize = 0;
    for (order, 0..) |index, position| {
        const placement = &result[index];
        if (position > 0 and placement.top >= cluster_bottom) {
            finish(result, order[cluster_start..position], lane_cap, selected);
            cluster_start = position;
        }
        if (position == cluster_start) {
            @memset(&lane_end, 0);
            cluster_bottom = 0;
        }
        var lane: usize = 0;
        while (lane < tracked_lanes and lane_end[lane] > placement.top) lane += 1;
        if (lane < tracked_lanes) lane_end[lane] = placement.bottom;
        placement.lane = @intCast(lane);
        cluster_bottom = @max(cluster_bottom, placement.bottom);
    }
    if (laid > 0) finish(result, order[cluster_start..laid], lane_cap, selected);
    if (selected) |chosen| if (chosen < items.len and chosen >= laid) {
        // Never laid out: drawn full width over whatever shares its rows.
        result[chosen] = .{ .top = result[chosen].top, .bottom = result[chosen].bottom, .floating = true };
    };
    cover(result, cells);
    return result;
}

fn finish(result: []Placement, members: []const usize, lane_cap: u8, selected: ?usize) void {
    var needed: usize = 0;
    for (members) |index| needed = @max(needed, @as(usize, result[index].lane) + 1);
    const lanes: u8 = @intCast(@min(needed, lane_cap));
    for (members) |index| {
        result[index].lanes = lanes;
        result[index].hidden = result[index].lane >= lanes;
    }
    if (selected) |chosen| if (std.mem.indexOfScalar(usize, members, chosen) != null and result[chosen].hidden) {
        result[chosen] = .{ .top = result[chosen].top, .bottom = result[chosen].bottom, .lane = lanes - 1, .lanes = lanes, .floating = true };
    };
    // Widen a block into following lanes that stay free for its whole
    // height; a floating selection occupies its lane like any other block.
    for (members) |index| {
        const block = &result[index];
        if (block.hidden or block.floating) continue;
        var span: u8 = 1;
        widen: while (block.lane + span < lanes) : (span += 1) {
            for (members) |other| {
                const neighbour = result[other];
                if (other == index or neighbour.hidden or neighbour.lane != block.lane + span) continue;
                if (overlaps(neighbour, block.*)) break :widen;
            }
        }
        block.span = span;
    }
}

/// Every drawn block the floating selection overlaps loses those rows; one
/// that loses all of them is hidden, so "+N" still counts it.
fn cover(result: []Placement, cells: usize) void {
    const floating = for (result) |block| {
        if (block.floating) break block;
    } else return;
    const left = laneX(cells, floating.lane, floating.lanes);
    const right = laneX(cells, @as(usize, floating.lane) + floating.span, floating.lanes);
    for (result) |*block| {
        if (block.floating or block.hidden or !overlaps(block.*, floating)) continue;
        const x0 = laneX(cells, block.lane, block.lanes);
        const x1 = laneX(cells, @as(usize, block.lane) + block.span, block.lanes);
        if (x1 <= left or right <= x0) continue;
        block.cover_top = @max(block.top, floating.top);
        block.cover_bottom = @min(block.bottom, floating.bottom);
        if (block.cover_top == block.top and block.cover_bottom == block.bottom) {
            block.hidden = true;
            block.cover_top = 0;
            block.cover_bottom = 0;
        }
    }
}

pub const BandItem = struct {
    /// Visible day columns occupied, inclusive.
    first: u8,
    last: u8,
    declined: bool = false,
    preferred: bool = false,
};
pub const BandPlacement = struct { row: u8 = 0, hidden: bool = false };

/// Rows needed to show every band item without overlap (unbounded layout).
pub fn bandRows(a: std.mem.Allocator, items: []const BandItem) !usize {
    var needed: usize = 0;
    const placements = try placeBand(a, items, max_band_rows, null);
    defer a.free(placements);
    for (placements) |placement| {
        if (!placement.hidden) needed = @max(needed, @as(usize, placement.row) + 1);
    }
    return needed;
}

/// Spanning all-day bars: the earliest and longest take the top rows. As in
/// `place`, a `selected` bar hidden by `row_cap` takes the last row.
pub fn placeBand(a: std.mem.Allocator, items: []const BandItem, row_cap: u8, selected: ?usize) ![]BandPlacement {
    const result = try a.alloc(BandPlacement, items.len);
    errdefer a.free(result);
    const order = try a.alloc(usize, items.len);
    defer a.free(order);
    for (order, 0..) |*value, index| value.* = index;
    std.mem.sort(usize, order, items, struct {
        fn less(values: []const BandItem, left: usize, right: usize) bool {
            const x = values[left];
            const y = values[right];
            if (x.first != y.first) return x.first < y.first;
            if (x.declined != y.declined) return !x.declined;
            if (x.preferred != y.preferred) return x.preferred;
            if (x.last != y.last) return x.last > y.last;
            return left < right;
        }
    }.less);
    var row_end: [max_band_rows]u16 = @splat(0);
    for (order) |index| {
        const item = items[index];
        var row: usize = 0;
        while (row < max_band_rows and row_end[row] > item.first) row += 1;
        if (row < max_band_rows) row_end[row] = @as(u16, item.last) + 1;
        result[index] = .{ .row = @intCast(@min(row, max_band_rows)), .hidden = row >= row_cap };
    }
    if (row_cap > 0) if (selected) |chosen| if (chosen < items.len and result[chosen].hidden) {
        const last = row_cap - 1;
        result[chosen] = .{ .row = last };
        for (items, result, 0..) |item, *placement, index| {
            if (index != chosen and !placement.hidden and placement.row == last and item.first <= items[chosen].last and items[chosen].first <= item.last) placement.hidden = true;
        }
    };
    return result;
}

/// The first row shown by default: the working day (08:00–18:00) centred
/// when it fits, otherwise starting at 08:00.
pub fn defaultTop(visible: usize, rph: u8) usize {
    const total = dayRows(rph);
    if (visible >= total) return 0;
    const work_first = 8 * @as(usize, rph);
    const work_rows = 10 * @as(usize, rph);
    const margin = if (visible > work_rows) (visible - work_rows) / 2 else 0;
    return @min(work_first -| margin, total - visible);
}
/// Scroll as little as possible so rows `[first, last)` are shown; a block
/// taller than the window shows its start.
pub fn follow(top: usize, visible: usize, total: usize, first: usize, last: usize) usize {
    if (visible == 0 or visible >= total) return 0;
    var result = top;
    if (last -| first >= visible or first < result) {
        result = first;
    } else if (last > result + visible) result = last - visible;
    return @min(result, total - visible);
}
pub fn clampTop(top: usize, visible: usize, total: usize) usize {
    return if (visible >= total) 0 else @min(top, total - visible);
}

// Colours ------------------------------------------------------------------

pub const Rgb = [3]u8;
/// `over` at `percent` opacity on `base`.
pub fn mix(base: Rgb, over: Rgb, percent: u8) Rgb {
    var result: Rgb = undefined;
    for (&result, base, over) |*channel, low, high| {
        channel.* = @intCast((@as(u32, low) * (100 - @as(u32, percent)) + @as(u32, high) * percent + 50) / 100);
    }
    return result;
}
fn luminance(value: Rgb) f64 {
    var result: f64 = 0;
    for (value, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
        const scaled = @as(f64, @floatFromInt(channel)) / 255;
        result += (if (scaled <= 0.04045) scaled / 12.92 else std.math.pow(f64, (scaled + 0.055) / 1.055, 2.4)) * weight;
    }
    return result;
}
/// WCAG contrast ratio, 1 to 21.
pub fn contrast(left: Rgb, right: Rgb) f64 {
    const l = luminance(left);
    const r = luminance(right);
    return (@max(l, r) + 0.05) / (@min(l, r) + 0.05);
}
/// Titles, times and places keep at least WCAG AA contrast on their fill,
/// including the selected block's solid fill.
pub const text_floor = 4.5;
/// Deliberately dimmed text (past, declined, busy-only, stale) and the
/// source-coloured title of an unanswered event keep at least 3:1; below
/// that they fall back to the theme foreground.
pub const quiet_floor = 3.0;
/// `preferred` when it keeps `floor` on `fill`, otherwise `fallback`.
pub fn inkOn(preferred: Rgb, fill: Rgb, fallback: Rgb, floor: f64) Rgb {
    return if (contrast(preferred, fill) >= floor) preferred else fallback;
}
/// A tint of `color` on `background` at up to `percent`, reduced until `text`
/// keeps `floor` contrast on it (never below the plain background).
pub fn readableFill(color: Rgb, background: Rgb, text: Rgb, percent: u8, floor: f64) Rgb {
    var alpha = percent;
    while (alpha > 0) : (alpha -|= 4) {
        const fill = mix(background, color, alpha);
        if (contrast(text, fill) >= floor) return fill;
    }
    return background;
}
/// Text colour for a solid `color` fill: whichever theme end reads better.
pub fn onColor(color: Rgb, background: Rgb, foreground: Rgb) Rgb {
    return if (contrast(background, color) >= contrast(foreground, color)) background else foreground;
}
pub const Solid = struct { fill: Rgb, ink: Rgb };
/// The selected block's solid fill and text: the calendar colour, moved
/// toward the theme end opposite its text until the text reaches
/// `text_floor` (or as far as the theme's own contrast allows).
pub fn selectedColors(color: Rgb, background: Rgb, foreground: Rgb) Solid {
    const ink = onColor(color, background, foreground);
    const away = if (std.mem.eql(u8, &ink, &background)) foreground else background;
    var percent: u8 = 0;
    while (percent <= 100) : (percent += 5) {
        const fill = mix(color, away, percent);
        if (contrast(ink, fill) >= text_floor) return .{ .fill = fill, .ink = ink };
    }
    return .{ .fill = away, .ink = ink };
}

// Tests --------------------------------------------------------------------

fn testPlace(items: []const Item, rph: u8, cap: u8, selected: ?usize) ![]Placement {
    return place(std.testing.allocator, items, rph, @as(usize, cap) * min_lane_cells, selected);
}
/// The grid's promise: each item is drawn on at least one row, or hidden
/// (and so counted), and every row lost to the selection is recorded.
fn expectAccounted(placements: []const Placement) !void {
    for (placements) |block| {
        if (block.hidden) continue;
        try std.testing.expect(block.top < block.bottom);
        if (block.covered()) {
            try std.testing.expect(!block.floating);
            try std.testing.expect(block.cover_top >= block.top and block.cover_bottom <= block.bottom);
            try std.testing.expect(block.cover_top > block.top or block.cover_bottom < block.bottom);
        }
    }
}

test "calendar grid: row mapping keeps short and zero-length events readable" {
    try std.testing.expectEqual(@as(u8, 1), rowsPerHour(12));
    try std.testing.expectEqual(@as(u8, 2), rowsPerHour(20));
    try std.testing.expectEqual(@as(u8, 2), rowsPerHour(71));
    try std.testing.expectEqual(@as(u8, 3), rowsPerHour(72));
    try std.testing.expectEqual(@as(u8, 4), rowsPerHour(200));
    try std.testing.expectEqual(@as(usize, 19), rowOf(9 * 60 + 30, 2));
    try std.testing.expectEqual(@as(usize, 23), rowEnd(11 * 60 + 15, 2));
    try std.testing.expectEqual(@as(u16, 570), minuteOf(19, 2));
    const placements = try testPlace(&.{
        .{ .first = 9 * 60, .end = 9 * 60 + 5 }, // shorter than a row
        .{ .first = 15 * 60 + 30, .end = 15 * 60 + 31 }, // zero-length (coverage widens to a minute)
        .{ .first = 23 * 60 + 50, .end = minutes_per_day },
    }, 2, 3, null);
    defer std.testing.allocator.free(placements);
    for (placements) |placement| try std.testing.expectEqual(@as(usize, 1), placement.bottom - placement.top);
    try std.testing.expectEqual(@as(usize, 47), placements[2].top);
    try std.testing.expectEqual(@as(usize, 48), placements[2].bottom);
}

test "calendar grid: overlaps share lanes, back-to-back events do not, and free lanes widen" {
    // 09:30–11:15, 10:00–11:00, 10:30–11:30, then 12:00 alone.
    const placements = try testPlace(&.{
        .{ .first = 570, .end = 675 },
        .{ .first = 600, .end = 660 },
        .{ .first = 630, .end = 690 },
        .{ .first = 720, .end = 780 },
        .{ .first = 780, .end = 840 },
    }, 2, 4, null);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(u8, 0), placements[0].lane);
    try std.testing.expectEqual(@as(u8, 1), placements[1].lane);
    try std.testing.expectEqual(@as(u8, 2), placements[2].lane);
    for (placements[0..3]) |placement| try std.testing.expectEqual(@as(u8, 3), placement.lanes);
    // Lunch and the next meeting touch but do not overlap: full width.
    try std.testing.expectEqual(@as(u8, 1), placements[3].lanes);
    try std.testing.expectEqual(@as(u8, 0), placements[4].lane);
    try std.testing.expectEqual(@as(u8, 1), placements[4].lanes);
    for (placements) |placement| try std.testing.expect(!placement.hidden);
    // 09:00–12:00 beside two consecutive short events: the second short one
    // reuses lane 1, and nothing can widen into an occupied lane.
    const chain = try testPlace(&.{
        .{ .first = 540, .end = 720 },
        .{ .first = 540, .end = 600 },
        .{ .first = 600, .end = 660 },
    }, 2, 4, null);
    defer std.testing.allocator.free(chain);
    try std.testing.expectEqual(@as(u8, 1), chain[2].lane);
    try std.testing.expectEqual(@as(u8, 2), chain[0].lanes);
    try std.testing.expectEqual(@as(u8, 1), chain[0].span);
    // A third lane exists only from 10:30; the 09:00 block may widen into it.
    const wide = try testPlace(&.{
        .{ .first = 540, .end = 600 },
        .{ .first = 540, .end = 720 },
        .{ .first = 630, .end = 690 },
        .{ .first = 630, .end = 660 },
    }, 2, 4, null);
    defer std.testing.allocator.free(wide);
    try std.testing.expectEqual(@as(u8, 3), wide[0].lanes);
    try std.testing.expectEqual(@as(u8, 1), wide[0].lane);
    try std.testing.expectEqual(@as(u8, 2), wide[0].span);
    try std.testing.expectEqual(@as(u8, 1), wide[1].span);
}

test "calendar grid: crowded clusters keep bounded lanes and an explicit selection visible" {
    var items: [12]Item = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .first = 600, .end = 660, .declined = index == 0 };
    const placements = try testPlace(&items, 2, 3, null);
    defer std.testing.allocator.free(placements);
    var shown: usize = 0;
    for (placements) |placement| {
        try std.testing.expect(placement.lanes == 3 and (placement.hidden or placement.lane < 3));
        shown += @intFromBool(!placement.hidden);
    }
    try std.testing.expectEqual(@as(usize, 3), shown);
    // A declined event yields its lane at the same start.
    try std.testing.expect(placements[0].hidden);
    const promoted = try testPlace(&items, 2, 3, 11);
    defer std.testing.allocator.free(promoted);
    try std.testing.expect(!promoted[11].hidden and promoted[11].floating and promoted[11].lane == 2 and promoted[11].span == 1);
    // Lanes never move. The block it covers in the last lane is hidden, so
    // "+N" counts it; everything else is exactly as before.
    for (placements, promoted, 0..) |before, after, index| {
        if (index == 11) continue;
        if (before.lane == 2 and !before.hidden) {
            try std.testing.expect(after.hidden and after.lane == 2);
            continue;
        }
        try std.testing.expectEqualDeep(before, after);
    }
    try expectAccounted(promoted);
    // A selection that already has a lane is not moved.
    const visible = try testPlace(&items, 2, 3, 2);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualDeep(placements[2], visible[2]);
}

test "calendar grid: a revealed selection never leaves a covered event uncounted" {
    // One lane: 08:30–09:30, a 09:00–17:00 routine, 13:00 and 15:00 starts.
    const items = [_]Item{
        .{ .first = 510, .end = 570 },
        .{ .first = 540, .end = 1020 },
        .{ .first = 780, .end = 840 },
        .{ .first = 900, .end = 930 },
    };
    const passive = try testPlace(&items, 2, 1, null);
    defer std.testing.allocator.free(passive);
    try std.testing.expect(passive[1].hidden and !passive[2].hidden and !passive[3].hidden);
    const revealed = try testPlace(&items, 2, 1, 1);
    defer std.testing.allocator.free(revealed);
    try expectAccounted(revealed);
    try std.testing.expect(revealed[1].floating and !revealed[1].hidden);
    // 08:30 keeps its first row and records losing 09:00–09:30; the later
    // starts lie wholly beneath the routine and are hidden, hence counted.
    try std.testing.expect(!revealed[0].hidden and revealed[0].cover_top == 18 and revealed[0].cover_bottom == 19);
    try std.testing.expect(revealed[2].hidden and revealed[3].hidden);
    // Two identical meetings in one lane: revealing the second hides the first.
    const twins = [_]Item{ .{ .first = 600, .end = 660 }, .{ .first = 600, .end = 660 } };
    const pair = try testPlace(&twins, 2, 1, 1);
    defer std.testing.allocator.free(pair);
    try std.testing.expect(pair[1].floating and pair[0].hidden);
    // With room in another lane nothing floats and nothing is covered.
    const roomy = try testPlace(&items, 2, 3, 1);
    defer std.testing.allocator.free(roomy);
    for (roomy) |block| try std.testing.expect(!block.hidden and !block.floating and !block.covered());
}

test "calendar grid: lanes follow real start minutes, then duration, within a rounded row" {
    // One row per hour: 09:30–11:15 and 09:00–09:15 share the 09:00 row; the
    // earlier start keeps the first lane even though the other is longer.
    const placements = try testPlace(&.{
        .{ .first = 570, .end = 675 },
        .{ .first = 540, .end = 555 },
    }, 1, 2, null);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(u8, 1), placements[0].lane);
    try std.testing.expectEqual(@as(u8, 0), placements[1].lane);
    // Equal starts: the longer event first.
    const equal = try testPlace(&.{ .{ .first = 600, .end = 630 }, .{ .first = 600, .end = 720 } }, 2, 2, null);
    defer std.testing.allocator.free(equal);
    try std.testing.expectEqual(@as(u8, 0), equal[1].lane);
}

test "calendar grid: an unbounded day is laid out in bounded memory and order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const items = try arena.allocator().alloc(Item, max_segments + 40);
    for (items, 0..) |*item, index| item.* = .{ .first = @intCast(index % 1440), .end = @intCast(@min(index % 1440 + 90, 1440)) };
    const placements = try place(arena.allocator(), items, 4, max_lanes * min_lane_cells, null);
    for (placements[max_segments..]) |placement| try std.testing.expect(placement.hidden);
    try expectAccounted(placements);
    // A selection beyond the laid-out segments is still drawn, full width,
    // and whatever it covers is accounted for.
    const chosen = max_segments + 20;
    const selected = try place(arena.allocator(), items, 4, max_lanes * min_lane_cells, chosen);
    try std.testing.expect(selected[chosen].floating and !selected[chosen].hidden and selected[chosen].lanes == 1);
    try expectAccounted(selected);
    for (selected, 0..) |block, index| {
        if (index == chosen or block.hidden or block.floating) continue;
        if (overlaps(block, selected[chosen])) try std.testing.expect(block.covered());
    }
    for (placements) |placement| {
        try std.testing.expect(placement.top < placement.bottom and placement.bottom <= dayRows(4));
        try std.testing.expect(placement.lanes >= 1 and placement.lanes <= max_lanes);
        if (!placement.hidden) try std.testing.expect(placement.lane + placement.span <= placement.lanes);
    }
    // Visible blocks in the same lane never overlap.
    for (placements, 0..) |first, i| for (placements[i + 1 ..]) |second| {
        if (first.hidden or second.hidden) continue;
        const lanes_overlap = first.lane < second.lane + second.span and second.lane < first.lane + first.span;
        if (lanes_overlap and first.lanes == second.lanes) try std.testing.expect(!overlaps(first, second));
    };
}

test "calendar grid: all-day bars span columns, cap rows and promote a hidden selection" {
    const a = std.testing.allocator;
    const items = [_]BandItem{
        .{ .first = 0, .last = 0 },
        .{ .first = 1, .last = 3 }, // multi-day trip
        .{ .first = 0, .last = 6 }, // spans the whole week: first row
        .{ .first = 2, .last = 2 },
    };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    // Week-long bar, then the single day and the trip share row 1; the
    // Wednesday item overlaps the trip and needs a third row.
    try std.testing.expectEqual(@as(usize, 3), try bandRows(arena.allocator(), &items));
    const full = try placeBand(arena.allocator(), &items, 3, null);
    try std.testing.expectEqual(@as(u8, 0), full[2].row);
    try std.testing.expectEqual(@as(u8, 1), full[0].row);
    try std.testing.expectEqual(@as(u8, 1), full[1].row);
    try std.testing.expectEqual(@as(u8, 2), full[3].row);
    const placements = try placeBand(a, &items, 1, null);
    defer a.free(placements);
    try std.testing.expect(!placements[2].hidden and placements[2].row == 0);
    try std.testing.expect(placements[0].hidden and placements[1].hidden and placements[3].hidden);
    const promoted = try placeBand(a, &items, 1, 3);
    defer a.free(promoted);
    try std.testing.expect(!promoted[3].hidden and promoted[3].row == 0);
    try std.testing.expect(promoted[2].hidden);
    const none = try placeBand(a, &items, 0, 1);
    defer a.free(none);
    for (none) |placement| try std.testing.expect(placement.hidden);
}

test "calendar grid: working hours are shown by default and selection scrolls minimally" {
    try std.testing.expectEqual(@as(usize, 13), defaultTop(26, 2)); // 06:30–19:30
    try std.testing.expectEqual(@as(usize, 16), defaultTop(12, 2)); // 08:00–14:00
    try std.testing.expectEqual(@as(usize, 0), defaultTop(48, 2));
    try std.testing.expectEqual(@as(usize, 6), defaultTop(40, 2)); // 03:00–23:00
    try std.testing.expectEqual(@as(usize, 2), defaultTop(46, 2)); // never past 24:00
    try std.testing.expectEqual(@as(usize, 5), defaultTop(16, 1)); // 05:00–21:00
    // Visible: keep. Above: show its start. Below: bring its end in. Taller
    // than the window: show the start.
    try std.testing.expectEqual(@as(usize, 16), follow(16, 12, 48, 18, 20));
    try std.testing.expectEqual(@as(usize, 2), follow(16, 12, 48, 2, 4));
    try std.testing.expectEqual(@as(usize, 34), follow(16, 12, 48, 44, 46));
    try std.testing.expectEqual(@as(usize, 30), follow(16, 12, 48, 30, 47));
    try std.testing.expectEqual(@as(usize, 36), follow(0, 12, 48, 46, 48));
    try std.testing.expectEqual(@as(usize, 0), follow(10, 60, 48, 46, 48));
    try std.testing.expectEqual(@as(usize, 36), clampTop(99, 12, 48));
}

test "calendar grid: day-long timed events join the all-day band" {
    const day: t.time.Point = .{ .kind = .date, .value = 20000 };
    try std.testing.expect(inBand(day, .{ .kind = .date, .value = 20001 }));
    const start: t.time.Point = .{ .kind = .instant, .value = 1_000_000 };
    try std.testing.expect(!inBand(start, .{ .kind = .instant, .value = 1_000_000 + 86_399_999 }));
    try std.testing.expect(inBand(start, .{ .kind = .instant, .value = 1_000_000 + 86_400_000 }));
    try std.testing.expect(!inBand(start, start));
}

test "calendar grid: tinted blocks keep text contrast in dark and light themes" {
    const dark_bg: Rgb = .{ 17, 22, 32 };
    const dark_fg: Rgb = .{ 232, 235, 241 };
    const light_bg: Rgb = .{ 250, 250, 248 };
    const light_fg: Rgb = .{ 30, 30, 36 };
    for ([_]Rgb{ .{ 92, 177, 255 }, .{ 255, 198, 98 }, .{ 255, 112, 112 }, .{ 255, 255, 255 }, .{ 0, 0, 0 }, .{ 128, 128, 128 }, .{ 119, 119, 119 } }) |color| {
        for ([_][2]Rgb{ .{ dark_bg, dark_fg }, .{ light_bg, light_fg } }) |theme| {
            const fill = readableFill(color, theme[0], theme[1], 40, text_floor);
            try std.testing.expect(contrast(theme[1], fill) >= text_floor);
            const on = onColor(color, theme[0], theme[1]);
            try std.testing.expectEqual(@max(contrast(theme[0], color), contrast(theme[1], color)), contrast(on, color));
            // The selected block's text reaches text_floor on its fill.
            const solid = selectedColors(color, theme[0], theme[1]);
            try std.testing.expect(contrast(solid.ink, solid.fill) >= text_floor);
            // Dimmed text falls back below its own floor.
            const quiet = inkOn(mix(theme[0], theme[1], 30), fill, theme[1], quiet_floor);
            try std.testing.expect(contrast(quiet, fill) >= quiet_floor or std.mem.eql(u8, &quiet, &theme[1]));
        }
    }
    try std.testing.expectEqualSlices(u8, &.{ 17, 22, 32 }, &mix(dark_bg, dark_fg, 0));
    try std.testing.expectEqualSlices(u8, &dark_fg, &mix(dark_bg, dark_fg, 100));
    try std.testing.expect(laneCap(18) == 2 and laneCap(3) == 1 and laneCap(400) == max_lanes);
    try std.testing.expectEqual(@as(usize, 9), laneX(18, 1, 2));
}
