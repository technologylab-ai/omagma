//! One progress snapshot plus a coalesced wake flag; no event history retained.
const std = @import("std");
const t = @import("types.zig");
pub const Mailbox = struct {
    sequence: std.atomic.Value(usize) = .init(0),
    phase: std.atomic.Value(u8) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    wake_pending: std.atomic.Value(bool) = .init(false),
    pub fn publish(self: *Mailbox, update: t.FetchProgress) bool {
        _ = self.sequence.fetchAdd(1, .acq_rel);
        self.total.store(update.total, .release);
        self.completed.store(@min(update.completed, update.total), .release);
        self.phase.store(@backingInt(update.phase), .release);
        _ = self.sequence.fetchAdd(1, .release);
        return !self.wake_pending.swap(true, .acq_rel);
    }
    pub fn snapshot(self: *const Mailbox) t.FetchProgress {
        while (true) {
            const before = self.sequence.load(.acquire);
            if (before % 2 != 0) continue;
            const phase = self.phase.load(.acquire);
            const total = self.total.load(.acquire);
            const completed = self.completed.load(.acquire);
            if (before == self.sequence.load(.acquire)) return .{ .phase = @fromBackingInt(@intCast(phase)), .completed = @min(completed, total), .total = total };
        }
    }
    pub fn acknowledged(self: *Mailbox) void {
        self.wake_pending.store(false, .release);
    }
};
test "fetch progress: coalescing keeps current fraction without retaining every notification" {
    var mailbox: Mailbox = .{};
    try std.testing.expect(mailbox.publish(.{ .phase = .metadata, .completed = 1, .total = 100 }));
    try std.testing.expect(!mailbox.publish(.{ .phase = .metadata, .completed = 3, .total = 100 }));
    var state = mailbox.snapshot();
    try std.testing.expectEqual(@as(usize, 3), state.completed);
    try std.testing.expectEqual(@as(usize, 100), state.total);
    mailbox.acknowledged();
    try std.testing.expect(mailbox.publish(.{ .phase = .bodies, .completed = 0, .total = 32 }));
    state = mailbox.snapshot();
    try std.testing.expectEqual(t.FetchPhase.bodies, state.phase);
    try std.testing.expectEqual(@as(usize, 0), state.completed);
    try std.testing.expectEqual(@as(usize, 32), state.total);
}
