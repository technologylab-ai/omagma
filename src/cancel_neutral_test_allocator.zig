//! Allocator calls are not cancellation points. Zig 0.17 SafeAllocator
//! stack tracing can consume cancellation in MachO's unwind mutex. Protect
//! only each backing call; keep its full diagnostics, checks and return address.
const std = @import("std");
const backing = std.testing.allocator;

pub const allocator: std.mem.Allocator = .{ .ptr = backing.ptr, .vtable = &.{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
} };

/// The stock runner recreates this instance per test. Install before starting
/// any testing-IO workers; the stateless wrapper remains valid through deinit.
pub fn install() void {
    std.debug.assert(std.testing.io_instance.worker_threads.load(.acquire) == null);
    std.testing.io_instance.allocator = allocator;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const previous = std.testing.io.swapCancelProtection(.blocked);
    defer _ = std.testing.io.swapCancelProtection(previous);
    return backing.vtable.alloc(ctx, len, alignment, ra);
}
fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
    const previous = std.testing.io.swapCancelProtection(.blocked);
    defer _ = std.testing.io.swapCancelProtection(previous);
    return backing.vtable.resize(ctx, bytes, alignment, len, ra);
}
fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
    const previous = std.testing.io.swapCancelProtection(.blocked);
    defer _ = std.testing.io.swapCancelProtection(previous);
    return backing.vtable.remap(ctx, bytes, alignment, len, ra);
}
fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const previous = std.testing.io.swapCancelProtection(.blocked);
    defer _ = std.testing.io.swapCancelProtection(previous);
    backing.vtable.free(ctx, bytes, alignment, ra);
}

// Force the native unwinder to contend while an owned task is canceled. Both
// allocation and release must leave that cancellation pending for checkCancel.
test "vault launch: allocator calls preserve cancellation during native stack tracing" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (std.debug.SelfInfo == void) return error.TestRequiresSymbolizedStackTraces;
    install();
    const io = std.testing.io;
    // Safe mode disables tracing in std.testing.allocator by default. Force
    // the same native unwinder and cancellation wrapper in both test modes.
    var traced: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 7 });
    defer std.debug.assert(traced.deinit() == 0);
    const traced_backing = traced.allocator();
    std.debug.assert(traced_backing.vtable == backing.vtable);
    const traced_allocator: std.mem.Allocator = .{ .ptr = traced_backing.ptr, .vtable = allocator.vtable };
    const State = struct {
        allocator: std.mem.Allocator,
        gate: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(bool) = .init(false),
        id: std.atomic.Value(std.Thread.Id) = .init(0),
        observed: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        bytes: ?[]u8 = null,
        release: bool,
        fn work(state: *@This()) void {
            state.id.store(std.Thread.getCurrentId(), .release);
            while (!state.gate.load(.acquire)) std.Thread.yield() catch {};
            state.started.store(true, .release);
            if (state.release) {
                state.allocator.free(state.bytes.?);
                state.bytes = null;
            } else {
                state.bytes = state.allocator.alloc(u8, 113) catch {
                    state.failed.store(true, .release);
                    return;
                };
            }
            const canceled = if (std.testing.io.checkCancel()) |_| false else |_| true;
            state.observed.store(canceled, .release);
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
    for ([_]bool{ false, true }) |release| {
        var state: State = .{ .allocator = traced_allocator, .release = release, .bytes = if (release) try traced_allocator.alloc(u8, 113) else null };
        defer if (state.bytes) |bytes| traced_allocator.free(bytes);
        var future = try io.concurrent(State.work, .{&state});
        defer future.cancel(io);
        const info = try std.debug.getSelfDebugInfo();
        info.mutex.lockUncancelable(std.Options.debug_io);
        var locked = true;
        defer if (locked) info.mutex.unlock(std.Options.debug_io);
        state.gate.store(true, .release);
        const started = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
        while (!state.started.load(.acquire) and Wait.before(started)) std.Thread.yield() catch {};
        if (!state.started.load(.acquire)) return error.TestWorkerDidNotStart;
        while (info.mutex.state.load(.acquire) != .contended and Wait.before(started)) std.Thread.yield() catch {};
        if (info.mutex.state.load(.acquire) != .contended) return error.TestUnwindMutexNotContended;
        // Do not allocate an Io task while its allocator's debug mutex is held.
        const canceler = try std.Thread.spawn(.{}, Cancel.run, .{&future});
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
        while (!Wait.pending(state.id.load(.acquire)) and Wait.before(deadline)) std.Thread.yield() catch {};
        const pending = Wait.pending(state.id.load(.acquire));
        info.mutex.unlock(std.Options.debug_io);
        locked = false;
        canceler.join();
        try std.testing.expect(pending);
        try std.testing.expect(!state.failed.load(.acquire));
        try std.testing.expect(state.observed.load(.acquire));
    }
}
