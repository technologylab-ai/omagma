const std = @import("std");
/// All terminal allocations share one accounting ceiling; runtime stacks are
/// measured separately. Accounting is protected for the single UI worker.
pub const CappedAllocator = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    rejected: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,
    pub fn allocator(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn lock(s: *CappedAllocator) void {
        while (!s.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn snapshot(s: *CappedAllocator) struct { allocatorUsedBytes: usize, allocatorPeakBytes: usize, rejectedAllocations: usize, allocatorLimitBytes: usize } {
        s.lock();
        defer s.mutex.unlock();
        return .{ .allocatorUsedBytes = s.used, .allocatorPeakBytes = s.peak, .rejectedAllocations = s.rejected, .allocatorLimitBytes = s.limit };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *CappedAllocator = @ptrCast(@alignCast(ctx));
        s.lock();
        defer s.mutex.unlock();
        if (n > s.limit - s.used) {
            s.rejected += 1;
            return null;
        }
        const p = s.backing.rawAlloc(n, alignment, ra) orelse return null;
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
