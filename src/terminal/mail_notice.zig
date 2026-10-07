const std = @import("std");

/// Each account owns its own persisted arrival serial and pending UI count.
/// A first observation establishes a baseline, never an unread-mail alert.
pub const Notice = struct {
    seen: [3]?u64 = @splat(null),
    pending: [3]u64 = @splat(0),

    pub fn observe(self: *Notice, account: usize, serial: u64) void {
        if (account >= self.seen.len) return;
        if (self.seen[account]) |previous| {
            if (serial > previous) self.pending[account] +|= serial - previous;
        }
        self.seen[account] = serial;
    }

    pub fn clear(self: *Notice) void {
        self.pending = @splat(0);
    }

    pub fn visible(self: *const Notice) bool {
        for (self.pending) |count| if (count > 0) return true;
        return false;
    }
};

test "mail activity: baselines and accumulation stay separate for three accounts" {
    var notice: Notice = .{};
    notice.observe(0, 80);
    notice.observe(1, 7);
    notice.observe(2, 0);
    try std.testing.expect(!notice.visible());
    notice.observe(0, 82);
    notice.observe(1, 10);
    notice.observe(0, 85);
    notice.observe(1, 10);
    try std.testing.expectEqual([3]u64{ 5, 3, 0 }, notice.pending);
    notice.clear();
    notice.observe(0, 85);
    notice.observe(2, 1);
    try std.testing.expectEqual([3]u64{ 0, 0, 1 }, notice.pending);
    // A replaced/older cache resets its baseline rather than wrapping a count.
    notice.observe(0, 2);
    notice.observe(0, 4);
    try std.testing.expectEqual([3]u64{ 2, 0, 1 }, notice.pending);
}
