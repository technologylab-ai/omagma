//! Invocation-owned deadlines. Only authoritative send phases can advance
//! them; progress and individual chunks never extend preparation.
const std = @import("std");
const builtin = @import("builtin");
pub const preparation_seconds: i64 = 30 * 60;
pub const gmail_seconds: i64 = 180;
pub const commit_margin_seconds: i64 = 30;
pub const transport_seconds: i64 = 180 + preparation_seconds + gmail_seconds + commit_margin_seconds + 15;
pub const Phase = enum { ordinary, preparation, gmail };
pub const Budget = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Event = .unset,
    phase: Phase = .ordinary,
    deadline_ms: i64,
    expired: bool = false,
    test_before_lock: if (builtin.is_test) ?*std.Io.Event else void = if (builtin.is_test) null else {},

    pub fn now(io: std.Io) i64 {
        return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
    }
    pub fn init(io: std.Io, seconds: i64) Budget {
        return .{ .deadline_ms = now(io) + seconds * 1000 };
    }
    pub fn timestamp(milliseconds: i64) std.Io.Clock.Timestamp {
        return .{ .clock = .awake, .raw = .{ .nanoseconds = @as(i96, milliseconds) * std.time.ns_per_ms } };
    }
    pub fn advance(self: *Budget, io: std.Io, phase: Phase) !std.Io.Clock.Timestamp {
        if (builtin.is_test) if (self.test_before_lock) |gate| gate.set(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.advanceLocked(io, phase, now(io));
    }
    fn advanceAt(self: *Budget, io: std.Io, phase: Phase, current: i64) !std.Io.Clock.Timestamp {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.advanceLocked(io, phase, current);
    }
    fn advanceLocked(self: *Budget, io: std.Io, phase: Phase, current: i64) !std.Io.Clock.Timestamp {
        if (self.expired or current >= self.deadline_ms) {
            self.expired = true;
            return error.Timeout;
        }
        if ((phase == .preparation and self.phase != .ordinary) or
            (phase == .gmail and self.phase != .preparation) or phase == .ordinary) return error.InvalidSendPhase;
        self.phase = phase;
        self.deadline_ms = current + 1000 * (if (phase == .preparation) preparation_seconds else gmail_seconds + commit_margin_seconds);
        self.changed.set(io);
        return timestamp(self.deadline_ms);
    }
    fn deadlineAt(self: *Budget, io: std.Io, current: i64) !std.Io.Clock.Timestamp {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.expired or current >= self.deadline_ms) {
            self.expired = true;
            return error.Timeout;
        }
        return timestamp(self.deadline_ms);
    }
    pub fn wait(self: *Budget, io: std.Io) !void {
        while (true) {
            // Reset before reading: a transition either precedes the locked
            // snapshot or wakes the subsequent wait. Expiry and transition
            // claim the same mutex, so a stale timer cannot cancel Gmail.
            self.changed.reset();
            self.mutex.lockUncancelable(io);
            const current = now(io);
            if (self.expired or current >= self.deadline_ms) {
                self.expired = true;
                self.mutex.unlock(io);
                return;
            }
            const deadline = timestamp(self.deadline_ms);
            self.mutex.unlock(io);
            self.changed.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {}, // includes spurious wakeups; re-read
                else => return err,
            };
        }
    }
    pub fn submissionAvailable(self: *Budget, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return !self.expired and self.phase == .gmail and timestamp(self.deadline_ms).durationFromNow(io).raw.toNanoseconds() >= gmail_seconds * std.time.ns_per_s;
    }
};
pub fn eligible(command: []const u8) bool {
    for ([_][]const u8{ "mail.send", "draft.send", "queue.process", "queue.send-now" }) |name| if (std.mem.eql(u8, name, command)) return true;
    return false;
}

test "attachment delivery: send budget: preparation has one absolute expiry and Gmail gets a fresh complete budget" {
    const io = std.testing.io;
    var budget: Budget = .{ .deadline_ms = 180000 };
    const preparation = try budget.advanceAt(io, .preparation, 179000);
    try std.testing.expectEqual(@as(i64, 1979000), @as(i64, @intCast(preparation.raw.toMilliseconds())));
    // Cumulative chunks can cross the former ordinary expiry without renewal.
    _ = try budget.deadlineAt(io, 180001);
    _ = try budget.deadlineAt(io, 1000000);
    try std.testing.expectError(error.InvalidSendPhase, budget.advanceAt(io, .preparation, 1000000));
    const gmail = try budget.advanceAt(io, .gmail, 1978999);
    try std.testing.expectEqual(@as(i64, 210000), @as(i64, @intCast(gmail.raw.toMilliseconds())) - 1978999);
    // A timer waking at the old deadline observes the admitted Gmail phase.
    _ = try budget.deadlineAt(io, 1979000);
    try std.testing.expectError(error.InvalidSendPhase, budget.advanceAt(io, .gmail, 1979000));
    var expired: Budget = .{ .deadline_ms = 1000, .phase = .preparation };
    try std.testing.expectError(error.Timeout, expired.deadlineAt(io, 1000));
    try std.testing.expectError(error.Timeout, expired.advanceAt(io, .gmail, 999));
    try std.testing.expectEqual(Phase.preparation, expired.phase);
}

test "attachment delivery: send budget: a transition blocked on its mutex cannot revive an expired phase" {
    const io = std.testing.io;
    const Task = struct {
        fn advance(budget: *Budget) anyerror!std.Io.Clock.Timestamp {
            return budget.advance(std.testing.io, .preparation);
        }
    };
    var entered: std.Io.Event = .unset;
    var budget: Budget = .{ .deadline_ms = Budget.now(io) + 200, .test_before_lock = &entered };
    budget.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) budget.mutex.unlock(io);
    var task = try io.concurrent(Task.advance, .{&budget});
    defer {
        if (locked) {
            budget.mutex.unlock(io);
            locked = false;
        }
        if (task.cancel(io)) |_| {} else |_| {}
    }
    try entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    try Budget.timestamp(budget.deadline_ms + 1).wait(io);
    budget.mutex.unlock(io);
    locked = false;
    try std.testing.expectError(error.Timeout, task.await(io));
    try std.testing.expectEqual(Phase.ordinary, budget.phase);
    try std.testing.expect(budget.expired);
}
