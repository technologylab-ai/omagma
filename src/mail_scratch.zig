//! One reusable message-decoding workspace, separate from retained application
//! data. The buffer is reserved in native/WASM static storage from startup.
//! A lease is synchronous and non-reentrant: copy every retained result into
//! its destination allocator before releasing it, and never suspend while held.
const std = @import("std");
const builtin = @import("builtin");
const Alignment = std.mem.Alignment;

pub const reservation_bytes = 16 * 1024 * 1024;
var storage: [reservation_bytes]u8 align(16) = undefined;
var mutex: std.atomic.Mutex = .unlocked;
var fixed: std.heap.FixedBufferAllocator = undefined;
var generation: usize = 0;
// Includes freed tails so release also wipes bytes no longer counted as used.
var touched: usize = 0;
var current_used: std.atomic.Value(usize) = .init(0);
var peak: std.atomic.Value(usize) = .init(0);
var rejected: std.atomic.Value(usize) = .init(0);
var last_rejected: std.atomic.Value(usize) = .init(0);
var leases: std.atomic.Value(usize) = .init(0);
var active: std.atomic.Value(bool) = .init(false);
const Owner = if (builtin.single_threaded) struct {
    var held: bool = false;
} else struct {
    threadlocal var held: bool = false;
};

pub const Snapshot = struct {
    reservationBytes: usize,
    usedBytes: usize,
    peakBytes: usize,
    rejectedAllocations: usize,
    lastRejectedAllocationBytes: usize,
    leases: usize,
    active: bool,
};

/// Does not wait on the lease, allocate, or expose decoded content. Fields are
/// individually atomic; a concurrent decode may progress between field reads.
pub fn snapshot() Snapshot {
    return .{
        .reservationBytes = reservation_bytes,
        .usedBytes = current_used.load(.monotonic),
        .peakBytes = peak.load(.monotonic),
        .rejectedAllocations = rejected.load(.monotonic),
        .lastRejectedAllocationBytes = last_rejected.load(.monotonic),
        .leases = leases.load(.monotonic),
        .active = active.load(.acquire),
    };
}

pub fn tryAcquire() ?Lease {
    if (!mutex.tryLock()) return null;
    Owner.held = true;
    fixed = .init(&storage);
    touched = 0;
    generation +%= 1;
    _ = leases.fetchAdd(1, .monotonic);
    active.store(true, .release);
    return .{ .generation = generation };
}

pub fn acquire() Lease {
    if (Owner.held) @panic("Nested message scratch lease");
    while (true) {
        if (tryAcquire()) |lease| return lease;
        // A browser decode is synchronous; contention here can only be a
        // programming error and cannot resolve by spinning its sole worker.
        if (builtin.single_threaded) @panic("Nested message scratch lease");
        std.atomic.spinLoopHint();
    }
}

pub const Lease = struct {
    generation: usize,
    live: bool = true,

    fn check(self: *const Lease) void {
        std.debug.assert(self.live and Owner.held and self.generation == generation and active.load(.acquire));
    }

    pub fn allocator(self: *Lease) std.mem.Allocator {
        self.check();
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Discard a completed/failed attempt before a bounded retry. All previous
    /// scratch slices become invalid, including allocations already freed.
    pub fn reset(self: *Lease) void {
        self.check();
        std.crypto.secureZero(u8, storage[0..touched]);
        fixed.reset();
        touched = 0;
        current_used.store(0, .monotonic);
    }

    pub fn release(self: *Lease) void {
        self.reset();
        self.live = false;
        Owner.held = false;
        active.store(false, .release);
        mutex.unlock();
    }

    fn recordUse() void {
        touched = @max(touched, fixed.end_index);
        current_used.store(fixed.end_index, .monotonic);
        // Only the lease owner writes peak, so no compare/exchange is needed.
        peak.store(@max(peak.load(.monotonic), fixed.end_index), .monotonic);
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Lease = @ptrCast(@alignCast(ctx));
        self.check();
        const result = fixed.allocator().rawAlloc(n, alignment, ra) orelse {
            _ = rejected.fetchAdd(1, .monotonic);
            last_rejected.store(n, .monotonic);
            return null;
        };
        recordUse();
        return result;
    }

    fn resize(ctx: *anyopaque, old: []u8, alignment: Alignment, n: usize, ra: usize) bool {
        const self: *Lease = @ptrCast(@alignCast(ctx));
        self.check();
        if (!fixed.allocator().rawResize(old, alignment, n, ra)) return false;
        recordUse();
        return true;
    }

    fn remap(ctx: *anyopaque, old: []u8, alignment: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Lease = @ptrCast(@alignCast(ctx));
        self.check();
        const result = fixed.allocator().rawRemap(old, alignment, n, ra) orelse return null;
        recordUse();
        return result;
    }

    fn free(ctx: *anyopaque, old: []u8, alignment: Alignment, ra: usize) void {
        const self: *Lease = @ptrCast(@alignCast(ctx));
        self.check();
        fixed.allocator().rawFree(old, alignment, ra);
        current_used.store(fixed.end_index, .monotonic);
    }
};

test "mail scratch: exclusive leases wipe freed tails and reuse fixed addresses" {
    const before = snapshot();
    var first = acquire();
    errdefer if (first.live) first.release();
    try std.testing.expect(tryAcquire() == null);
    const a = first.allocator();
    const bytes = try a.alloc(u8, 1024);
    const address = @intFromPtr(bytes.ptr);
    @memset(bytes, 0x5a);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), snapshot().usedBytes);
    first.release();
    try std.testing.expect(!snapshot().active);
    for (storage[0..1024]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    var second = acquire();
    defer second.release();
    const recovered = try second.allocator().alloc(u8, 1024);
    try std.testing.expectEqual(address, @intFromPtr(recovered.ptr));
    try std.testing.expectEqual(before.leases + 2, snapshot().leases);
}

test "mail scratch: exhaustion and retry reset stay inside the same reservation" {
    const before = snapshot();
    var lease = acquire();
    defer lease.release();
    const a = lease.allocator();
    const full = try a.alloc(u8, reservation_bytes);
    @memset(full, 0x4b);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try std.testing.expectEqual(before.rejectedAllocations + 1, snapshot().rejectedAllocations);
    try std.testing.expectEqual(@as(usize, 1), snapshot().lastRejectedAllocationBytes);
    try std.testing.expectEqual(@as(usize, reservation_bytes), snapshot().peakBytes);
    lease.reset();
    try std.testing.expectEqual(@as(u8, 0), storage[0]);
    try std.testing.expectEqual(@as(u8, 0), storage[storage.len - 1]);
    const recovered = try a.alloc(u8, reservation_bytes);
    try std.testing.expectEqual(@intFromPtr(full.ptr), @intFromPtr(recovered.ptr));
}

fn concurrentDecodePattern(pattern: u8) anyerror!void {
    for (0..32) |_| {
        var lease = acquire();
        defer lease.release();
        const bytes = try lease.allocator().alloc(u8, 1024);
        @memset(bytes, pattern);
        std.Thread.yield() catch {};
        for (bytes) |byte| if (byte != pattern) return error.MixedScratchOwners;
    }
}

test "mail scratch: concurrent native callers retain exclusive scratch ownership" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var tasks: [4]std.Io.Future(anyerror!void) = undefined;
    var count: usize = 0;
    errdefer for (tasks[0..count]) |*task| task.cancel(io) catch {};
    for (&tasks, 0..) |*task, index| {
        task.* = try io.concurrent(concurrentDecodePattern, .{@as(u8, @intCast(index + 1))});
        count += 1;
    }
    for (&tasks) |*task| try task.await(io);
    try std.testing.expect(!snapshot().active);
    try std.testing.expectEqual(@as(usize, 0), snapshot().usedBytes);
}
