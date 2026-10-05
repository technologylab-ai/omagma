const std = @import("std");

pub const ReaderLayout = enum { right, below };
pub const Focus = enum { navigation, list, reader };
pub const Rect = struct { x: u16 = 0, y: u16 = 0, width: u16, height: u16 };
pub const Panes = struct { navigation: ?Rect = null, list: ?Rect = null, reader: ?Rect = null };

pub fn compute(width: u16, height: u16, focus: Focus, reader_layout: ReaderLayout, expanded: bool) Panes {
    return computeWithNavigation(width, height, focus, reader_layout, expanded, 26);
}

pub fn computeWithNavigation(width: u16, height: u16, focus: Focus, reader_layout: ReaderLayout, expanded: bool, requested_navigation_width: u16) Panes {
    if (width == 0 or height == 0) return .{};
    if (expanded) return .{ .reader = .{ .width = width, .height = height } };
    if (focus == .navigation and width < 120) return .{ .navigation = .{ .width = width, .height = height } };
    var panes: Panes = .{};
    const nav_width: u16 = if (width >= 120) @min(@max(requested_navigation_width, 26), @min(@as(u16, 36), width - 80)) else 0;
    if (nav_width > 0) panes.navigation = .{ .width = nav_width, .height = height };
    const available = width - nav_width;
    if (reader_layout == .below and available >= 48 and height >= 16) {
        const list_height: u16 = @max(@as(u16, 7), @as(u16, @intCast(@as(u32, height) * 2 / 5)));
        panes.list = .{ .x = nav_width, .width = available, .height = list_height };
        panes.reader = .{ .x = nav_width, .y = list_height, .width = available, .height = height - list_height };
    } else if (reader_layout == .right and available >= 80) {
        const list_width = @min(@as(u16, @intCast(@as(u32, available) * 55 / 100)), available - 34);
        panes.list = .{ .x = nav_width, .width = list_width, .height = height };
        panes.reader = .{ .x = nav_width + list_width, .width = available - list_width, .height = height };
    } else if (focus == .reader) panes.reader = .{ .x = nav_width, .width = available, .height = height } else panes.list = .{ .x = nav_width, .width = available, .height = height };
    return panes;
}

pub fn stepMessage(count: usize, selected: usize, next: bool) usize {
    if (count == 0) return 0;
    const current = @min(selected, count - 1);
    return if (next) @min(current +| 1, count - 1) else current -| 1;
}

test "reader layouts use balanced width and bounded stacked panes" {
    const right = compute(200, 40, .list, .right, false);
    try std.testing.expectEqual(@as(u16, 26), right.navigation.?.width);
    try std.testing.expectEqual(@as(u16, 95), right.list.?.width);
    try std.testing.expectEqual(@as(u16, 79), right.reader.?.width);
    const below = compute(100, 20, .reader, .below, false);
    try std.testing.expectEqual(@as(u16, 100), below.list.?.width);
    try std.testing.expectEqual(@as(u16, 8), below.list.?.height);
    try std.testing.expectEqual(@as(u16, 8), below.reader.?.y);
    try std.testing.expectEqual(@as(u16, 12), below.reader.?.height);
    for ([_]u16{ 30, 60, 80, 100, 120, 200, 240 }) |width| for ([_]u16{ 6, 12, 16, 20, 40, 76 }) |height| {
        for ([_]Focus{ .navigation, .list, .reader }) |focus| for ([_]ReaderLayout{ .right, .below }) |reader_layout| {
            const panes = compute(width, height, focus, reader_layout, false);
            for ([_]?Rect{ panes.navigation, panes.list, panes.reader }) |maybe| if (maybe) |rect| {
                try std.testing.expect(rect.width > 0 and rect.height > 0);
                try std.testing.expect(rect.x + rect.width <= width);
                try std.testing.expect(rect.y + rect.height <= height);
            };
        };
    };
    const expanded = compute(100, 20, .reader, .below, true);
    try std.testing.expect(expanded.list == null and expanded.navigation == null);
    try std.testing.expectEqual(@as(u16, 100), expanded.reader.?.width);
}

test "reader mail navigation clamps empty first and last selections" {
    try std.testing.expectEqual(@as(usize, 0), stepMessage(0, 99, true));
    try std.testing.expectEqual(@as(usize, 0), stepMessage(3, 0, false));
    try std.testing.expectEqual(@as(usize, 1), stepMessage(3, 0, true));
    try std.testing.expectEqual(@as(usize, 1), stepMessage(3, 2, false));
    try std.testing.expectEqual(@as(usize, 2), stepMessage(3, 2, true));
    try std.testing.expectEqual(@as(usize, 2), stepMessage(3, std.math.maxInt(usize), true));
}

test "account width grows only when needed and preserves bounded mail panes" {
    const wider = computeWithNavigation(160, 36, .list, .right, false, 27);
    try std.testing.expectEqual(@as(u16, 27), wider.navigation.?.width);
    try std.testing.expectEqual(@as(u16, 27), wider.list.?.x);
    try std.testing.expect(wider.reader.?.width >= 34);
    const longest = computeWithNavigation(120, 36, .list, .right, false, 260);
    try std.testing.expectEqual(@as(u16, 36), longest.navigation.?.width);
    try std.testing.expect(longest.reader.?.x + longest.reader.?.width <= 120);
    const narrow = computeWithNavigation(70, 20, .navigation, .right, false, 260);
    try std.testing.expectEqual(@as(u16, 70), narrow.navigation.?.width);
    try std.testing.expect(narrow.list == null and narrow.reader == null);
}
