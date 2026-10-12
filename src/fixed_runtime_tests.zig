//! Tests use a watched upstream only to obtain the initial reservation. The
//! application/runtime never receive that allocator and must work after it is
//! sealed, including cleanup, worker reuse, subprocess setup and exhaustion.
const std = @import("std");
const memory = @import("fixed_runtime.zig");
const Heap = @import("fixed_heap.zig").Heap;
const Meter = @import("terminal/capped_allocator.zig").CappedAllocator;
const Alignment = std.mem.Alignment;

const StartupBacking = struct {
    sealed: bool = false,
    acquire_calls: usize = 0,
    late_calls: usize = 0,

    fn allocator(self: *StartupBacking) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn permitted(self: *StartupBacking) bool {
        if (self.sealed) {
            self.late_calls += 1;
            return false;
        }
        self.acquire_calls += 1;
        return true;
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *StartupBacking = @ptrCast(@alignCast(ctx));
        if (!self.permitted()) return null;
        return std.testing.allocator.rawAlloc(n, alignment, ra);
    }
    fn resize(ctx: *anyopaque, old: []u8, alignment: Alignment, n: usize, ra: usize) bool {
        const self: *StartupBacking = @ptrCast(@alignCast(ctx));
        if (!self.permitted()) return false;
        return std.testing.allocator.rawResize(old, alignment, n, ra);
    }
    fn remap(ctx: *anyopaque, old: []u8, alignment: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *StartupBacking = @ptrCast(@alignCast(ctx));
        if (!self.permitted()) return null;
        return std.testing.allocator.rawRemap(old, alignment, n, ra);
    }
    fn free(_: *anyopaque, old: []u8, alignment: Alignment, ra: usize) void {
        std.testing.allocator.rawFree(old, alignment, ra);
    }
};

const minimal: std.process.Init.Minimal = .{
    .args = .{ .vector = &.{"synthetic-fixed-runtime"} },
    .environ = .empty,
};

fn allocationJob(io: std.Io, release: *std.Io.Event, a: std.mem.Allocator, index: usize) anyerror!usize {
    const first = try a.alloc(u8, 1024 + index * 17);
    defer a.free(first);
    @memset(first, @intCast(index));
    try release.wait(io);
    for (first) |byte| if (byte != @as(u8, @intCast(index))) return error.CorruptedPayload;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const second = try arena.allocator().alloc(u8, 8192 + index * 31);
    @memset(second, @intCast(index));
    return first.len + second.len;
}

test "fixed runtime: sealed application and Threaded work never reacquire backing memory" {
    var backing: StartupBacking = .{};
    const upstream = backing.allocator();
    const storage = try upstream.alloc(u8, 1024 * 1024);
    defer upstream.free(storage);
    var runtime: memory.Runtime = .{};
    try runtime.init(minimal, .{
        .application = storage[0 .. 768 * 1024],
        .io = storage[768 * 1024 .. 960 * 1024],
        .startup = storage[960 * 1024 ..],
    }, 640 * 1024);
    defer runtime.deinit();
    try runtime.seal();
    backing.sealed = true;
    try std.testing.expectError(error.RuntimeNotInStartup, runtime.seal());
    try std.testing.expectError(error.RuntimeAlreadyInitialized, runtime.init(minimal, .{ .application = &.{}, .io = &.{}, .startup = &.{} }, 0));
    const a = runtime.context().allocator;
    const io = runtime.io();
    const pool = runtime.threaded.worker_threads.load(.acquire);
    try std.testing.expectEqual(@as(usize, memory.worker_count), runtime.workerCount());
    for (0..24) |_| {
        var release: std.Io.Event = .unset;
        var jobs: [8]std.Io.Future(anyerror!usize) = undefined;
        var count: usize = 0;
        errdefer for (jobs[0..count]) |*job| {
            _ = job.cancel(io) catch {};
        };
        for (&jobs, 0..) |*job, index| {
            job.* = try io.concurrent(allocationJob, .{ io, &release, a, index });
            count += 1;
        }
        release.set(io);
        for (&jobs, 0..) |*job, index| try std.testing.expectEqual(9216 + index * 48, try job.await(io));
    }
    // Actual child argument/environment serialization goes through Threaded's
    // fixed allocator. Child and libc-owned memory is a separate boundary.
    var child = try std.process.spawn(io, .{ .argv = &.{"/usr/bin/true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .environ_map = &runtime.environ });
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "fixed-map", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "synthetic fixed IO map");
    var mapping = try std.Io.File.MemoryMap.create(io, file, .{ .len = 4096 });
    defer mapping.destroy(io);
    try std.testing.expectEqualStrings("synthetic fixed IO map", mapping.memory[0..22]);
    try std.testing.expect(mapping.section == null);
    try std.testing.expect(@intFromPtr(mapping.memory.ptr) >= @intFromPtr(runtime.io_heap.buffer.ptr));
    try std.testing.expect(@intFromPtr(mapping.memory.ptr) + mapping.memory.len <= @intFromPtr(runtime.io_heap.buffer.ptr) + runtime.io_heap.buffer.len);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 640 * 1024 + 1));
    const large = try a.alloc(u8, 600 * 1024);
    @memset(large, 0xa5);
    a.free(large);
    try std.testing.expectEqual(pool, runtime.threaded.worker_threads.load(.acquire));
    try std.testing.expectEqual(@as(usize, memory.worker_count), runtime.workerCount());
    const stats = runtime.snapshot();
    try std.testing.expectEqualStrings("sealed", stats.phase);
    try std.testing.expect(!stats.upstreamAllocatorPresent);
    try std.testing.expectEqual(@as(usize, 0), stats.application.allocatorUsedBytes);
    try std.testing.expectEqual(@as(usize, 1), stats.application.rejectedAllocations);
    try std.testing.expectEqual(@as(usize, 0), stats.io.rejectedAllocations);
    try std.testing.expectEqual(@as(usize, 1), backing.acquire_calls);
    try std.testing.expectEqual(@as(usize, 0), backing.late_calls);
}

test "fixed runtime: physical exhaustion records scarcity and freed blocks recover without fallback" {
    var backing: StartupBacking = .{};
    const upstream = backing.allocator();
    const bytes = try upstream.alloc(u8, 4096);
    defer upstream.free(bytes);
    var heap = Heap.init(bytes);
    var cap: Meter = .{ .backing = heap.allocator(), .limit = 8192, .reservation_bytes = bytes.len };
    const a = cap.allocator();
    backing.sealed = true;
    var held: [64][]u8 = undefined;
    var count: usize = 0;
    while (count < held.len) : (count += 1) held[count] = a.alloc(u8, 128) catch break;
    try std.testing.expect(count > 0 and count < held.len);
    const exhausted = cap.snapshot();
    try std.testing.expectEqual(@as(usize, 1), exhausted.backingRejectedAllocations);
    try std.testing.expectEqual(@as(usize, 128), exhausted.lastRejectedAllocationBytes);
    try std.testing.expect(exhausted.allocatorUsedBytes < exhausted.allocatorLimitBytes);
    // Fragmentation alone cannot trigger a grow operation; coalescing later
    // makes the whole reservation reusable for differently sized objects.
    for (held[0..count]) |allocation| a.free(allocation);
    const recovered = try a.alloc(u8, 4000);
    @memset(recovered, 0x6b);
    a.free(recovered);
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().allocatorUsedBytes);
    try std.testing.expectEqual(@as(usize, 0), backing.late_calls);
}

test "fixed runtime: a scarce startup fails before sealing and cleans owned workers" {
    var application: [8192]u8 align(16) = undefined;
    var io: [512]u8 align(16) = undefined;
    var startup: [4096]u8 align(16) = undefined;
    var runtime: memory.Runtime = .{};
    try runtime.init(minimal, .{ .application = &application, .io = &io, .startup = &startup }, application.len);
    defer runtime.deinit();
    try std.testing.expectError(error.ConcurrencyUnavailable, runtime.seal());
    try std.testing.expect(runtime.phase == .startup);
    try std.testing.expectEqual(@as(usize, 0), runtime.io_meter.snapshot().allocatorUsedBytes);
    try std.testing.expect(runtime.io_meter.snapshot().rejectedAllocations > 0);
}
