//! Bounded Week-grid row allocation. Every day shares the same hour offsets.
//! Only viewport space and event counts affect layout; focus and the clock do not.
const std = @import("std");

pub const hours = 24;
pub const max_lines = 4;
pub const Bands = struct {
    overflow_row: ?usize,
    offscreen_row: ?usize,
    grid_start: usize,
    hour_budget: usize,

    /// Keep two all-day titles and the related-events footer. Overflow and
    /// offscreen-hour hints consume a row only when they can contain content.
    pub fn init(height: usize, max_all_day: usize) Bands {
        const overflow = max_all_day > 2;
        const after_dates: usize = 3 + @as(usize, @intFromBool(overflow));
        const offscreen = height -| (after_dates + 1) < hours;
        const grid_start = after_dates + @intFromBool(offscreen);
        return .{
            .overflow_row = if (overflow) 3 else null,
            .offscreen_row = if (offscreen) after_dates else null,
            .grid_start = grid_start,
            .hour_budget = height -| (grid_start + 1),
        };
    }
};
pub const Plan = struct {
    count: usize = 0,
    lines: [hours]u8 = @splat(0),
    offsets: [hours]usize = @splat(0),
    used_rows: usize = 0,
};

test "calendar week rows: optional bands preserve all-day capacity and exactly fitting full-day grids" {
    for (0..4) |all_day| {
        const full_height: usize = if (all_day > 2) 29 else 28;
        for (0..108) |height| {
            const bands = Bands.init(height, all_day);
            try std.testing.expectEqual(all_day > 2, bands.overflow_row != null);
            try std.testing.expectEqual(height < full_height, bands.offscreen_row != null);
            const plan = allocate(bands.hour_budget, @splat(0));
            try std.testing.expectEqual(height >= full_height, plan.count == hours);
            if (plan.count > 0) try std.testing.expect(bands.grid_start + plan.used_rows < height);
            if (bands.overflow_row) |row| try std.testing.expect(row < bands.grid_start);
            if (bands.offscreen_row) |row| {
                try std.testing.expect(row < bands.grid_start);
                if (bands.overflow_row) |overflow| try std.testing.expect(overflow < row);
            }
            if (height == full_height) {
                try std.testing.expectEqual(@as(usize, hours), bands.hour_budget);
                try std.testing.expectEqual(height - 2, bands.grid_start + plan.offsets[23]);
            }
        }
    }
}

/// `needs[h]` is the largest candidate count in hour h across the visible days.
/// Compact grids retain one row per visible hour. Once all 24 hours fit, spend
/// spare rows on event titles before adding cosmetic spacing to quiet hours.
/// Each crowded hour receives a second line before any receives a third.
/// A larger viewport cannot hide an alternative that already fit at less height.
pub fn allocate(budget: usize, needs: [hours]usize) Plan {
    var result: Plan = .{ .count = @min(hours, budget) };
    if (result.count == 0) return result;
    @memset(result.lines[0..result.count], 1);
    var remaining = budget - result.count;
    while (result.count == hours and remaining > 0) {
        var advanced = false;
        for (0..hours) |hour| {
            const wanted = @max(1, @min(max_lines, needs[hour]));
            if (result.lines[hour] >= wanted) continue;
            result.lines[hour] += 1;
            remaining -= 1;
            advanced = true;
            if (remaining == 0) break;
        }
        if (!advanced) break;
    }
    // Fill remaining room only after every candidate that can fit is visible.
    // This fixed sequence is also monotonic when the viewport grows.
    for (2..max_lines + 1) |spacing| {
        if (result.count != hours or remaining == 0) break;
        for (0..hours) |hour| {
            if (result.lines[hour] >= spacing) continue;
            result.lines[hour] += 1;
            remaining -= 1;
            if (remaining == 0) break;
        }
    }
    for (0..result.count) |hour| {
        result.offsets[hour] = result.used_rows;
        result.used_rows += result.lines[hour];
    }
    return result;
}

test "calendar week rows: spare rows reveal several crowded hours without hiding midnight or the last hour" {
    var needs: [hours]usize = @splat(0);
    needs[9] = 5;
    needs[10] = 3;
    needs[11] = 2;
    const plan = allocate(27, needs);
    try std.testing.expectEqual(@as(usize, hours), plan.count);
    try std.testing.expectEqual(@as(usize, 27), plan.used_rows);
    for (0..hours) |hour| try std.testing.expectEqual(@as(u8, if (hour >= 9 and hour <= 11) 2 else 1), plan.lines[hour]);
    try std.testing.expectEqual(@as(usize, 0), plan.offsets[0]);
    try std.testing.expectEqual(@as(usize, 9), plan.offsets[9]);
    try std.testing.expectEqual(@as(usize, 11), plan.offsets[10]);
    try std.testing.expectEqual(@as(usize, 13), plan.offsets[11]);
    try std.testing.expectEqual(@as(usize, 26), plan.offsets[23]);
    const another = allocate(28, needs);
    try std.testing.expectEqual(@as(u8, 3), another.lines[9]);
    try std.testing.expectEqual(@as(u8, 2), another.lines[10]);
    try std.testing.expectEqual(@as(u8, 2), another.lines[11]);
}

test "calendar week rows: event titles take spare space before cosmetic spacing" {
    var needs: [hours]usize = @splat(1);
    needs[9] = 3;
    needs[10] = 3;
    needs[11] = 3;
    const plan = allocate(50, needs);
    try std.testing.expectEqual(@as(u8, 2), plan.lines[0]);
    try std.testing.expectEqual(@as(u8, 3), plan.lines[9]);
    try std.testing.expectEqual(@as(u8, 3), plan.lines[10]);
    try std.testing.expectEqual(@as(u8, 3), plan.lines[11]);
    try std.testing.expectEqual(@as(usize, 50), plan.used_rows);
}

test "calendar week rows: increasing height never hides previously visible alternatives" {
    var needs: [hours]usize = @splat(0);
    needs[9] = 4;
    needs[15] = 3;
    needs[23] = 2;
    var previous = allocate(hours, needs);
    for (hours + 1..130) |budget| {
        const next = allocate(budget, needs);
        for (0..hours) |hour| try std.testing.expect(next.lines[hour] >= previous.lines[hour]);
        previous = next;
    }
    try std.testing.expectEqual(@as(u8, 4), allocate(47, needs).lines[9]);
    try std.testing.expectEqual(@as(u8, 4), allocate(48, needs).lines[9]);
}

test "calendar week rows: compact and huge viewports keep bounded disjoint hour geometry" {
    const needs: [hours]usize = @splat(std.math.maxInt(usize));
    for (0..257) |budget| {
        const plan = allocate(budget, needs);
        try std.testing.expectEqual(@min(hours, budget), plan.count);
        try std.testing.expect(plan.used_rows <= budget);
        var end: usize = 0;
        for (0..plan.count) |hour| {
            try std.testing.expectEqual(end, plan.offsets[hour]);
            try std.testing.expect(plan.lines[hour] >= 1 and plan.lines[hour] <= max_lines);
            if (budget < hours) try std.testing.expectEqual(@as(u8, 1), plan.lines[hour]);
            end += plan.lines[hour];
        }
        try std.testing.expectEqual(end, plan.used_rows);
    }
    const huge = allocate(std.math.maxInt(usize), needs);
    try std.testing.expectEqual(@as(usize, hours * max_lines), huge.used_rows);
}
