const std = @import("std");
/// Accounting and synchronization around one allocator. Native production
/// normally uses a fixed reservation; outgoing transient storage has a separate
/// meter and explicitly uses OS pages instead.
pub const CappedAllocator = struct {
    backing: std.mem.Allocator,
    limit: usize,
    reservation_bytes: usize = 0,
    used: usize = 0,
    peak: usize = 0,
    rejected: usize = 0,
    backing_rejected: usize = 0,
    last_rejected_bytes: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,
    pub fn allocator(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn lock(s: *CappedAllocator) void {
        while (!s.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub const Snapshot = struct { allocatorUsedBytes: usize, allocatorPeakBytes: usize, rejectedAllocations: usize, allocatorLimitBytes: usize, allocatorReservationBytes: usize, backingRejectedAllocations: usize, lastRejectedAllocationBytes: usize };
    pub fn snapshot(s: *CappedAllocator) Snapshot {
        s.lock();
        defer s.mutex.unlock();
        return .{ .allocatorUsedBytes = s.used, .allocatorPeakBytes = s.peak, .rejectedAllocations = s.rejected, .allocatorLimitBytes = s.limit, .allocatorReservationBytes = s.reservation_bytes, .backingRejectedAllocations = s.backing_rejected, .lastRejectedAllocationBytes = s.last_rejected_bytes };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *CappedAllocator = @ptrCast(@alignCast(ctx));
        s.lock();
        defer s.mutex.unlock();
        if (n > s.limit - s.used) {
            s.rejected += 1;
            s.last_rejected_bytes = n;
            return null;
        }
        const p = s.backing.rawAlloc(n, alignment, ra) orelse {
            s.rejected += 1;
            s.backing_rejected += 1;
            s.last_rejected_bytes = n;
            return null;
        };
        s.used += n;
        s.peak = @max(s.peak, s.used);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const s: *CappedAllocator = @ptrCast(@alignCast(ctx));
        s.lock();
        defer s.mutex.unlock();
        if (n > m.len and n - m.len > s.limit - s.used) {
            s.rejected += 1;
            s.last_rejected_bytes = n;
            return false;
        }
        if (!s.backing.rawResize(m, alignment, n, ra)) return false;
        s.used = s.used - m.len + n;
        s.peak = @max(s.peak, s.used);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const s: *CappedAllocator = @ptrCast(@alignCast(ctx));
        s.lock();
        defer s.mutex.unlock();
        if (n > m.len and n - m.len > s.limit - s.used) {
            s.rejected += 1;
            s.last_rejected_bytes = n;
            return null;
        }
        const p = s.backing.rawRemap(m, alignment, n, ra) orelse return null;
        s.used = s.used - m.len + n;
        s.peak = @max(s.peak, s.used);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const s: *CappedAllocator = @ptrCast(@alignCast(ctx));
        s.lock();
        defer s.mutex.unlock();
        s.backing.rawFree(m, alignment, ra);
        s.used -= m.len;
    }
};
test "allocation ceiling counts simultaneous ownership" {
    var cap: CappedAllocator = .{ .backing = std.testing.allocator, .limit = 128 };
    const a = cap.allocator();
    const x = try a.alloc(u8, 100);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 29));
    a.free(x);
    const y = try a.alloc(u8, 128);
    a.free(y);
    try std.testing.expectEqual(@as(usize, 0), cap.used);
}
