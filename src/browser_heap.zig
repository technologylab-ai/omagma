//! Single-worker heap for the browser's fixed memory budget. Free blocks are
//! address ordered, split on allocation and coalesced on release; a temporary
//! large arena can therefore serve later allocations of different sizes.
const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

pub const Heap = struct {
    const Block = struct {
        span: usize,
        next: ?*Block = null,
        requested: usize = 0,
        alignment: Alignment = .@"1",
    };
    const block_alignment = @alignOf(Block);
    const backpointer_size = @sizeOf(*Block);
    const minimum_span = @sizeOf(Block) + backpointer_size + block_alignment;

    buffer: []u8,
    free_list: ?*Block = null,

    /// The buffer must outlive this heap and every allocation. No allocation
    /// or operating-system call is needed to initialize it. Not thread safe.
    pub fn init(buffer: []u8) Heap {
        const base = @intFromPtr(buffer.ptr);
        const aligned = alignForward(base, block_alignment) orelse return .{ .buffer = buffer[0..0] };
        const skipped = aligned - base;
        if (skipped > buffer.len) return .{ .buffer = buffer[0..0] };
        const length = (buffer.len - skipped) & ~(@as(usize, block_alignment) - 1);
        var heap: Heap = .{ .buffer = buffer[skipped..][0..length] };
        if (length >= minimum_span) {
            const first: *Block = @ptrCast(@alignCast(heap.buffer.ptr));
            first.* = .{ .span = length };
            heap.free_list = first;
        }
        return heap;
    }

    pub fn allocator(self: *Heap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alignForward(value: usize, alignment: usize) ?usize {
        return (std.math.add(usize, value, alignment - 1) catch return null) & ~(alignment - 1);
    }
    fn payloadAddress(block: *const Block, alignment: Alignment) ?usize {
        const prefix = std.math.add(usize, @intFromPtr(block), @sizeOf(Block) + backpointer_size) catch return null;
        return alignForward(prefix, @max(alignment.toByteUnits(), @alignOf(*Block)));
    }
    fn requiredSpan(block: *const Block, payload: usize, length: usize) ?usize {
        const total = std.math.add(usize, payload - @intFromPtr(block), length) catch return null;
        return alignForward(total, block_alignment);
    }
    fn checkBlock(self: *const Heap, block: *const Block) void {
        const address = @intFromPtr(block);
        const base = @intFromPtr(self.buffer.ptr);
        assert(address >= base and address - base <= self.buffer.len);
        assert(self.buffer.len - (address - base) >= @sizeOf(Block));
        assert(Alignment.of(Block).check(address));
        assert(block.span >= minimum_span and block.span % block_alignment == 0);
        assert(block.span <= self.buffer.len - (address - base));
    }
    fn checkFree(self: *const Heap, block: *const Block) void {
        self.checkBlock(block);
        assert(block.requested == 0);
        if (block.next) |next| assert(@intFromPtr(block) + block.span < @intFromPtr(next));
    }
    fn owner(self: *const Heap, memory: []u8, alignment: Alignment) *Block {
        const address = @intFromPtr(memory.ptr);
        const base = @intFromPtr(self.buffer.ptr);
        assert(memory.len > 0 and address >= base);
        assert(address - base >= @sizeOf(Block) + backpointer_size);
        assert(address - base <= self.buffer.len);
        assert(memory.len <= self.buffer.len - (address - base));
        assert(Alignment.of(*Block).check(address) and alignment.check(address));
        const backpointer: *const *Block = @ptrFromInt(address - backpointer_size);
        const block = backpointer.*;
        self.checkBlock(block);
        assert(block.requested == memory.len and block.alignment == alignment);
        assert(payloadAddress(block, alignment).? == address);
        assert(address - @intFromPtr(block) + memory.len <= block.span);
        return block;
    }
    fn alloc(ctx: *anyopaque, length: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        assert(length > 0);
        var link = &self.free_list;
        while (link.*) |block| : (link = &block.next) {
            self.checkFree(block);
            const payload = payloadAddress(block, alignment) orelse return null;
            const needed = requiredSpan(block, payload, length) orelse return null;
            if (needed > block.span) continue;
            const remainder = block.span - needed;
            if (remainder >= minimum_span) {
                const tail: *Block = @ptrFromInt(@intFromPtr(block) + needed);
                tail.* = .{ .span = remainder, .next = block.next };
                link.* = tail;
                block.span = needed;
            } else link.* = block.next;
            block.next = null;
            block.requested = length;
            block.alignment = alignment;
            const backpointer: **Block = @ptrFromInt(payload - backpointer_size);
            backpointer.* = block;
            return @ptrFromInt(payload);
        }
        return null;
    }
    fn insertFree(self: *Heap, block: *Block) void {
        self.checkBlock(block);
        assert(block.requested == 0);
        const address = @intFromPtr(block);
        var previous: ?*Block = null;
        var link = &self.free_list;
        while (link.*) |candidate| {
            self.checkFree(candidate);
            if (@intFromPtr(candidate) >= address) break;
            previous = candidate;
            link = &candidate.next;
        }
        if (previous) |before| assert(@intFromPtr(before) + before.span <= address);
        block.next = link.*;
        if (block.next) |after| {
            assert(address + block.span <= @intFromPtr(after));
            if (address + block.span == @intFromPtr(after)) {
                block.span += after.span;
                block.next = after.next;
            }
        }
        if (previous) |before| {
            if (@intFromPtr(before) + before.span == address) {
                before.span += block.span;
                before.next = block.next;
                return;
            }
        }
        link.* = block;
    }
    fn splitTail(self: *Heap, block: *Block, needed: usize) void {
        const remainder = block.span - needed;
        if (remainder < minimum_span) return;
        block.span = needed;
        const tail: *Block = @ptrFromInt(@intFromPtr(block) + needed);
        tail.* = .{ .span = remainder };
        self.insertFree(tail);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, _: usize) bool {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        assert(length > 0);
        const block = self.owner(memory, alignment);
        const needed = requiredSpan(block, @intFromPtr(memory.ptr), length) orelse return false;
        if (needed > block.span) {
            const end = @intFromPtr(block) + block.span;
            var link = &self.free_list;
            while (link.*) |candidate| {
                self.checkFree(candidate);
                if (@intFromPtr(candidate) >= end) break;
                link = &candidate.next;
            }
            const after = link.* orelse return false;
            if (@intFromPtr(after) != end or needed - block.span > after.span) return false;
            link.* = after.next;
            block.span += after.span;
        }
        block.requested = length;
        self.splitTail(block, needed);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, length: usize, ra: usize) ?[*]u8 {
        // Let std Allocator perform allocate/copy/free when movement is needed.
        // A failed attempt must leave the old allocation and its bytes intact.
        return if (resize(ctx, memory, alignment, length, ra)) memory.ptr else null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const block = self.owner(memory, alignment);
        block.requested = 0;
        self.insertFree(block);
    }
};

test "browser heap: arbitrary alignment produces distinct live regions and complete reuse" {
    var buffer: [32 * 1024 + 1]u8 align(16) = undefined;
    var heap = Heap.init(buffer[1..]);
    const a = heap.allocator();
    var allocations: [13][]u8 = undefined;
    for (&allocations, 0..) |*allocation, index| {
        const alignment: Alignment = .fromByteUnits(@as(usize, 1) << @intCast(index));
        const ptr = a.rawAlloc(17 + index, alignment, 0) orelse return error.OutOfMemory;
        allocation.* = ptr[0 .. 17 + index];
        try std.testing.expect(alignment.check(@intFromPtr(ptr)));
        for (allocations[0..index]) |other| try std.testing.expect(@intFromPtr(ptr) >= @intFromPtr(other.ptr) + other.len or @intFromPtr(other.ptr) >= @intFromPtr(ptr) + allocation.len);
        @memset(allocation.*, @intCast(index));
    }
    for (allocations, 0..) |allocation, index| {
        for (allocation) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
        a.rawFree(allocation, .fromByteUnits(@as(usize, 1) << @intCast(index)), 0);
    }
    try std.testing.expectEqual(heap.buffer.len, heap.free_list.?.span);
    try std.testing.expect(heap.free_list.?.next == null);
    const large = try a.alloc(u8, 30 * 1024);
    a.free(large);
}

test "browser heap: freed different-sized neighbors coalesce for a larger allocation" {
    var buffer: [64 * 1024]u8 align(16) = undefined;
    var heap = Heap.init(&buffer);
    const a = heap.allocator();
    const first = try a.alloc(u8, 8 * 1024);
    const second = try a.alloc(u8, 16 * 1024);
    const third = try a.alloc(u8, 4 * 1024);
    const barrier = try a.alloc(u8, 30 * 1024);
    a.free(first);
    a.free(third);
    a.free(second); // Joins both sides, independent of their former sizes.
    const joined = try a.alloc(u8, 27 * 1024);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(joined.ptr));
    a.free(joined);
    a.free(barrier);
    try std.testing.expectEqual(heap.buffer.len, heap.free_list.?.span);
    try std.testing.expect(heap.free_list.?.next == null);
}

test "browser heap: adjacent resize shrink reuse and failed remap preserve bytes" {
    var buffer: [8192]u8 align(16) = undefined;
    var heap = Heap.init(&buffer);
    const a = heap.allocator();
    var first = try a.alloc(u8, 512);
    const neighbor = try a.alloc(u8, 1024);
    const barrier = try a.alloc(u8, 512);
    @memset(first, 0x5a);
    try std.testing.expect(!a.resize(first, 1400));
    try std.testing.expect(a.remap(first, 1400) == null);
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    a.free(neighbor);
    try std.testing.expect(a.resize(first, 1400));
    first = first.ptr[0..1400];
    for (first[0..512]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    @memset(first, 0x5a);
    try std.testing.expect(a.resize(first, 128));
    first = first[0..128];
    const reused = try a.alloc(u8, 1024);
    try std.testing.expect(@intFromPtr(reused.ptr) < @intFromPtr(barrier.ptr));
    const old_ptr = first.ptr;
    first = try a.realloc(first, 2000); // Falls back to a different free block.
    try std.testing.expect(first.ptr != old_ptr);
    for (first[0..128]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    @memset(first, 0x6b);
    try std.testing.expectError(error.OutOfMemory, a.realloc(first, buffer.len));
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0x6b), byte);
    try std.testing.expect(a.rawAlloc(std.math.maxInt(usize), .@"1", 0) == null);
    try std.testing.expect(a.rawAlloc(1, .fromByteUnits(std.math.maxInt(usize) / 2 + 1), 0) == null);
    try std.testing.expect(!a.rawResize(first, .@"1", std.math.maxInt(usize), 0));
    a.free(first);
    a.free(reused);
    a.free(barrier);
    try std.testing.expectEqual(heap.buffer.len, heap.free_list.?.span);
}

test "browser heap: bounded mixed allocation trace preserves every live payload" {
    var buffer: [32 * 1024]u8 align(16) = undefined;
    var heap = Heap.init(&buffer);
    const a = heap.allocator();
    const Slot = struct { bytes: ?[]u8 = null, alignment: Alignment = .@"1", marker: u8 = 0 };
    var slots: [24]Slot = @splat(.{});
    var random: u32 = 0x7c83a9d1;
    for (0..600) |step| {
        random = random *% 1664525 +% 1013904223;
        const index = (random >> 8) % slots.len;
        const slot = &slots[index];
        if (slot.bytes) |old| {
            if (random & 3 == 0) {
                a.rawFree(old, slot.alignment, 0);
                slot.bytes = null;
            } else {
                const length = 1 + (random >> 16) % 2048;
                if (a.rawRemap(old, slot.alignment, length, 0)) |ptr| {
                    for (ptr[0..@min(length, old.len)]) |byte| try std.testing.expectEqual(slot.marker, byte);
                    slot.bytes = ptr[0..length];
                }
                @memset(slot.bytes.?, slot.marker);
            }
        } else {
            const alignment: Alignment = .fromByteUnits(@as(usize, 1) << @intCast((random >> 5) % 9));
            const length = 1 + (random >> 16) % 1024;
            if (a.rawAlloc(length, alignment, 0)) |ptr| {
                slot.* = .{ .bytes = ptr[0..length], .alignment = alignment, .marker = @truncate(step) };
                @memset(slot.bytes.?, slot.marker);
            }
        }
        for (slots, 0..) |live, live_index| if (live.bytes) |bytes| {
            try std.testing.expect(live.alignment.check(@intFromPtr(bytes.ptr)));
            for (bytes) |byte| try std.testing.expectEqual(live.marker, byte);
            for (slots[0..live_index]) |other| if (other.bytes) |earlier| try std.testing.expect(@intFromPtr(bytes.ptr) >= @intFromPtr(earlier.ptr) + earlier.len or @intFromPtr(earlier.ptr) >= @intFromPtr(bytes.ptr) + bytes.len);
        };
    }
    for (slots) |slot| if (slot.bytes) |bytes| a.rawFree(bytes, slot.alignment, 0);
    try std.testing.expectEqual(heap.buffer.len, heap.free_list.?.span);
    try std.testing.expect(heap.free_list.?.next == null);
    var tiny: [8]u8 = undefined;
    var empty = Heap.init(tiny[1..]);
    try std.testing.expectError(error.OutOfMemory, empty.allocator().alloc(u8, 1));
}
