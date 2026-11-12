//! One bounded, asynchronous width measurement for terminals without a
//! negotiated grapheme-width or explicit-width capability.
const std = @import("std");
const vaxis = @import("vaxis");

pub const witness = "⏱️ 👋🏿 👩‍💻";
pub const row: u16 = 2;
pub const Probe = struct {
    deadline_ms: ?i64 = null,

    pub fn begin(self: *Probe, now_ms: i64) void {
        self.deadline_ms = now_ms + 500;
    }
    pub fn accept(self: *Probe, position: vaxis.Screen.Cursor, now_ms: i64) ?vaxis.gwidth.Method {
        const deadline = self.deadline_ms orelse return null;
        if (now_ms > deadline) {
            self.deadline_ms = null;
            return null;
        }
        // Capability probes use the home row. An unrelated or late report
        // must never be mistaken for this measurement.
        if (position.row != row) return null;
        self.deadline_ms = null;
        return switch (position.col) {
            11 => .wcwidth,
            10 => .no_zwj,
            8 => .unicode,
            else => null,
        };
    }
};

test "terminal width: measured VS16 modifiers and joining select one consistent method" {
    for ([_]struct { columns: u16, method: vaxis.gwidth.Method }{
        .{ .columns = 11, .method = .wcwidth },
        .{ .columns = 10, .method = .no_zwj },
        .{ .columns = 8, .method = .unicode },
    }) |case| {
        try std.testing.expectEqual(case.columns, vaxis.gwidth.gwidth(witness, case.method));
        var probe: Probe = .{};
        probe.begin(1000);
        try std.testing.expectEqual(case.method, probe.accept(.{ .row = row, .col = case.columns }, 1100).?);
        try std.testing.expect(probe.accept(.{ .row = row, .col = case.columns }, 1101) == null);
    }
}

test "terminal width: missing unexpected expired and home-row reports cannot change policy" {
    var probe: Probe = .{};
    try std.testing.expect(probe.accept(.{ .row = row, .col = 8 }, 1000) == null);
    probe.begin(1000);
    try std.testing.expect(probe.accept(.{ .row = 0, .col = 8 }, 1100) == null);
    try std.testing.expect(probe.accept(.{ .row = row, .col = 8 }, 1501) == null);
    probe.begin(2000);
    try std.testing.expect(probe.accept(.{ .row = row, .col = 9 }, 2001) == null);
    try std.testing.expect(probe.accept(.{ .row = row, .col = 8 }, 2002) == null);
}
