const std = @import("std");
const builtin = @import("builtin");

test "vault launch: diagnostic allocator unwind cancellation control" {
    if (builtin.os.tag != .macos or std.debug.SelfInfo == void) return error.SkipZigTest;
    const io = std.testing.io;
    const State = struct {
        gate: std.atomic.Value(bool) = .init(false),
        stage: std.atomic.Value(u8) = .init(0),
        id: std.atomic.Value(std.Thread.Id) = .init(0),
        observed: std.atomic.Value(bool) = .init(false),
        allocation_failed: std.atomic.Value(bool) = .init(false),
        bytes: ?[]u8 = null,
        protected: bool,
        fn work(state: *@This()) void {
            const task_io = std.testing.io;
            state.id.store(std.Thread.getCurrentId(), .release);
            while (!state.gate.load(.acquire)) std.Thread.yield() catch {};
            const old = if (state.protected) task_io.swapCancelProtection(.blocked) else null;
            state.stage.store(1, .release);
            state.bytes = std.testing.allocator.alloc(u8, 113) catch {
                state.allocation_failed.store(true, .release);
                if (old) |value| _ = task_io.swapCancelProtection(value);
                state.stage.store(2, .release);
                return;
            };
            if (old) |value| _ = task_io.swapCancelProtection(value);
            const canceled = if (task_io.checkCancel()) |_| false else |_| true;
            state.observed.store(canceled, .release);
            state.stage.store(2, .release);
        }
    };
    const Cancel = struct {
        fn run(future: *std.Io.Future(void)) void {
            future.cancel(std.testing.io);
        }
    };
    const Wait = struct {
        fn before(deadline: std.Io.Clock.Timestamp) bool {
            return deadline.durationFromNow(std.testing.io).raw.toNanoseconds() > 0;
        }
        fn blocked(id: std.Thread.Id) bool {
            var next = std.testing.io_instance.worker_threads.load(.acquire);
            while (next) |thread| : (next = thread.next) {
                if (thread.id == id) return thread.status.load(.acquire).cancelation == .blocked;
            }
            return false;
        }
        fn pending(id: std.Thread.Id) bool {
            var next = std.testing.io_instance.worker_threads.load(.acquire);
            while (next) |thread| : (next = thread.next) {
                if (thread.id != id) continue;
                return switch (thread.status.load(.acquire).cancelation) {
                    .canceling, .blocked_canceling, .blocked_alertable_canceling => true,
                    else => false,
                };
            }
            return false;
        }
    };
    for ([_]bool{ false, true }) |protected| {
        var state: State = .{ .protected = protected };
        var future = try io.concurrent(State.work, .{&state});
        defer {
            future.cancel(io);
            if (state.bytes) |bytes| std.testing.allocator.free(bytes);
        }
        const info = try std.debug.getSelfDebugInfo();
        info.mutex.lockUncancelable(std.Options.debug_io);
        var locked = true;
        defer if (locked) info.mutex.unlock(std.Options.debug_io);
        state.gate.store(true, .release);
        const started = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
        while (state.stage.load(.acquire) < 1 and Wait.before(started)) std.Thread.yield() catch {};
        if (state.stage.load(.acquire) < 1) return error.DiagnosticWorkerDidNotStart;
        while (info.mutex.state.load(.acquire) != .contended and Wait.before(started)) std.Thread.yield() catch {};
        if (info.mutex.state.load(.acquire) != .contended) return error.DiagnosticUnwindMutexNotContended;
        if (!protected) {
            while (!Wait.blocked(state.id.load(.acquire)) and Wait.before(started)) std.Thread.yield() catch {};
            if (!Wait.blocked(state.id.load(.acquire))) return error.DiagnosticUnwindDidNotBlock;
        }
        // A raw helper avoids allocating another Io task while the allocator's
        // MachO unwind mutex is intentionally held by this test.
        const canceler = try std.Thread.spawn(.{}, Cancel.run, .{&future});
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
        if (protected) {
            while (!Wait.pending(state.id.load(.acquire)) and Wait.before(deadline)) std.Thread.yield() catch {};
        } else {
            while (state.stage.load(.acquire) < 2 and Wait.before(deadline)) std.Thread.yield() catch {};
        }
        const reached = if (protected) Wait.pending(state.id.load(.acquire)) else state.stage.load(.acquire) == 2;
        info.mutex.unlock(std.Options.debug_io);
        locked = false;
        canceler.join();
        std.debug.print("ALLOCATOR-CANCEL protected={} reached={} cancellationVisible={} allocationFailed={}\n", .{ protected, reached, state.observed.load(.acquire), state.allocation_failed.load(.acquire) });
        try std.testing.expect(reached);
        try std.testing.expect(!state.allocation_failed.load(.acquire));
        try std.testing.expectEqual(protected, state.observed.load(.acquire));
    }
}
