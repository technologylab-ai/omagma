//! Optional terminal calendar permissions. The bar never consumes this module.
const std = @import("std");
pub const calendar_list = "https://www.googleapis.com/auth/calendar.calendarlist.readonly";
pub const events_read = "https://www.googleapis.com/auth/calendar.events.readonly";
pub const events_owned = "https://www.googleapis.com/auth/calendar.events.owned";
pub const events_write = "https://www.googleapis.com/auth/calendar.events";
pub const free_busy = "https://www.googleapis.com/auth/calendar.events.freebusy";

pub const Selection = struct {
    read: bool = false,
    write_owned: bool = false,
    write_shared: bool = false,
    availability: bool = false,
};

/// Append these to the complete existing terminal scope set for explicit
/// installed-app reconsent. This does not request Google incremental consent.
pub fn scopes(a: std.mem.Allocator, selected: Selection) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    if (!selected.read and !selected.write_owned and !selected.write_shared and !selected.availability) return &.{};
    try result.append(a, calendar_list);
    if (selected.write_shared) {
        try result.append(a, events_write);
    } else {
        if (selected.read) try result.append(a, events_read);
        if (selected.write_owned) try result.append(a, events_owned);
    }
    // FreeBusy's documented authorization set does not include events.readonly
    // or events.owned. Availability-only grants remain a separate choice.
    if (selected.availability) try result.append(a, free_busy);
    return result.toOwnedSlice(a);
}

test "calendar: optional scopes remain narrow and distinguish shared writes" {
    const a = std.testing.allocator;
    const none = try scopes(a, .{});
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const own = try scopes(a, .{ .write_owned = true });
    defer a.free(own);
    try std.testing.expectEqual(@as(usize, 2), own.len);
    try std.testing.expectEqualStrings(events_owned, own[1]);
    const shared = try scopes(a, .{ .read = true, .write_owned = true, .write_shared = true, .availability = true });
    defer a.free(shared);
    try std.testing.expectEqual(@as(usize, 3), shared.len);
    try std.testing.expectEqualStrings(events_write, shared[1]);
    try std.testing.expectEqualStrings(free_busy, shared[2]);
}
