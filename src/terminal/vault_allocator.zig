//! Clears the whole allocation before returning private arena chunks to the
//! existing bounded heap. No extra reservation or fallback allocator exists.
const std = @import("std");
pub const WipingAllocator = struct {
    backing: std.mem.Allocator,
    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(length, alignment, ra);
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, ra: usize) bool {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        // A shrinking/moving upstream remap could release secret tail bytes
        // before we can wipe them. Force the caller's copy+secure-free path.
        if (length < bytes.len) return false;
        return self.backing.rawResize(bytes, alignment, length, ra);
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, ra: usize) ?[*]u8 {
        return if (resize(context, bytes, alignment, length, ra)) bytes.ptr else null;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, bytes);
        self.backing.rawFree(bytes, alignment, ra);
    }
};

test "vault allocator: shrinking and freeing erase complete private allocations" {
    var bytes: [256]u8 = @splat(0xa5);
    var backing: std.heap.FixedBufferAllocator = .init(&bytes);
    var secure: WipingAllocator = .{ .backing = backing.allocator() };
    const allocator = secure.allocator();
    const first = try allocator.alloc(u8, 128);
    @memset(first, 0x47);
    const smaller = try allocator.realloc(first, 32);
    for (bytes[0..128]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (smaller) |byte| try std.testing.expectEqual(@as(u8, 0x47), byte);
    allocator.free(smaller);
    for (bytes[128..160]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
