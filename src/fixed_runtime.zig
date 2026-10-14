//! Native memory ownership. Static reservations are mapped with the executable;
//! allocations only split/reuse those bytes. There is no upstream allocator.
//! Threaded's task/process buffers share a separate reservation and its complete
//! worker pool is created before seal(), never on an application operation.
const std = @import("std");
const Heap = @import("fixed_heap.zig").Heap;
const Meter = @import("terminal/capped_allocator.zig").CappedAllocator;
const MiB = 1024 * 1024;

pub const application_limit = @import("terminal/types.zig").Limits.runtime_bytes;
/// Preserve the payload ceiling; block headers, alignment and fragmentation
/// consume separate fixed capacity. This is a reservation, not measured RSS.
pub const application_reservation = application_limit + 8 * MiB;
pub const io_reservation = 4 * MiB;
pub const startup_reservation = 2 * MiB;
pub const message_scratch_reservation = @import("mail_scratch.zig").reservation_bytes;
pub const worker_count = 16;
pub const worker_stack_bytes = MiB;

/// Native entrypoints opt out of the standard panic symbol reader's implicit
/// page allocator and file mappings. Panic text and raw addresses remain.
pub const debug = struct {
    pub const SelfInfo = void;
};

pub const Buffers = struct { application: []u8, io: []u8, startup: []u8 };

/// Declare one instance at static scope; do not put the reservations on a stack.
pub fn Storage(comptime application_bytes: usize) type {
    return struct {
        application: [application_bytes]u8 align(16),
        io: [io_reservation]u8 align(16),
        startup: [startup_reservation]u8 align(16),

        pub fn buffers(self: *@This()) Buffers {
            return .{ .application = &self.application, .io = &self.io, .startup = &self.startup };
        }
    };
}

/// Explicit replacement for std.process.Init; accepting Init.Minimal avoids
/// constructing a hidden GPA-backed environment and an unused default runtime.
pub const Context = struct {
    minimal: std.process.Init.Minimal,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    meter: *Meter,
    memory: *Runtime,
};

pub const Runtime = struct {
    phase: enum { cold, startup, sealed, stopped } = .cold,
    application_heap: Heap = undefined,
    application_meter: Meter = undefined,
    io_heap: Heap = undefined,
    io_meter: Meter = undefined,
    startup: std.heap.FixedBufferAllocator = undefined,
    environ: std.process.Environ.Map = undefined,
    threaded: std.Io.Threaded = undefined,
    minimal: std.process.Init.Minimal = undefined,

    pub fn init(self: *Runtime, minimal: std.process.Init.Minimal, buffers: Buffers, payload_limit: usize) !void {
        if (self.phase != .cold) return error.RuntimeAlreadyInitialized;
        self.minimal = minimal;
        @import("platform.zig").configureLaunchEnvironment(minimal.environ);
        self.application_heap = Heap.init(buffers.application);
        self.application_meter = .{ .backing = self.application_heap.allocator(), .limit = payload_limit, .reservation_bytes = buffers.application.len };
        self.io_heap = Heap.init(buffers.io);
        self.io_meter = .{ .backing = self.io_heap.allocator(), .limit = buffers.io.len, .reservation_bytes = buffers.io.len };
        self.startup = std.heap.FixedBufferAllocator.init(buffers.startup);
        self.environ = std.process.Environ.createMap(minimal.environ, self.startup.allocator()) catch return error.StartupEnvironmentTooLarge;
        self.threaded = .init(self.io_meter.allocator(), .{
            .stack_size = worker_stack_bytes,
            .concurrent_limit = .limited(worker_count),
            .async_limit = .limited(worker_count),
            .environ = minimal.environ,
            .argv0 = .init(minimal.args),
            .disable_memory_mapping = true,
        });
        self.phase = .startup;
    }

    /// This is the only phase that may acquire worker stacks/TLS from the OS.
    /// Once sealed, both limits equal the permanent prestarted pool size.
    pub fn seal(self: *Runtime) !void {
        if (self.phase != .startup) return error.RuntimeNotInStartup;
        try prestartWorkers(&self.threaded, worker_count);
        std.debug.assert(self.workerCount() == worker_count);
        self.phase = .sealed;
    }

    /// Relays/control clients do no provider work. Keep their worker pool and
    /// untouched static reservation small while preserving deadline support.
    pub fn sealClient(self: *Runtime) !void {
        return self.sealRelay(4);
    }

    /// The interactive relay also owns terminal/signal waits and one UI job.
    /// IPC deadline tasks must fit alongside them without adding provider work.
    pub fn sealFrontend(self: *Runtime) !void {
        return self.sealRelay(8);
    }

    fn sealRelay(self: *Runtime, count: usize) !void {
        if (self.phase != .startup) return error.RuntimeNotInStartup;
        self.threaded.concurrent_limit = .limited(count);
        self.threaded.async_limit = .limited(count);
        try prestartWorkers(&self.threaded, count);
        std.debug.assert(self.workerCount() == count);
        self.phase = .sealed;
    }

    pub fn context(self: *Runtime) Context {
        std.debug.assert(self.phase == .sealed);
        return .{ .minimal = self.minimal, .allocator = self.application_meter.allocator(), .environ_map = &self.environ, .meter = &self.application_meter, .memory = self };
    }

    pub fn io(self: *Runtime) std.Io {
        std.debug.assert(self.phase == .sealed);
        return self.threaded.io();
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.phase == .startup or self.phase == .sealed);
        self.threaded.deinit();
        self.environ.deinit();
        self.phase = .stopped;
    }

    pub fn workerCount(self: *Runtime) usize {
        var count: usize = 0;
        var thread = self.threaded.worker_threads.load(.acquire);
        while (thread) |item| : (thread = item.next) count += 1;
        return count;
    }

    pub const Snapshot = struct {
        phase: []const u8,
        application: Meter.Snapshot,
        io: Meter.Snapshot,
        startupReservationBytes: usize,
        startupUsedBytes: usize,
        mailScratch: @import("mail_scratch.zig").Snapshot,
        workerThreads: usize,
        workerStackBytes: usize,
        upstreamAllocatorPresent: bool,
    };

    pub fn snapshot(self: *Runtime) Snapshot {
        std.debug.assert(self.phase == .sealed);
        return .{
            .phase = @tagName(self.phase),
            .application = self.application_meter.snapshot(),
            .io = self.io_meter.snapshot(),
            .startupReservationBytes = self.startup.buffer.len,
            .startupUsedBytes = self.startup.end_index,
            .mailScratch = @import("mail_scratch.zig").snapshot(),
            .workerThreads = self.workerCount(),
            .workerStackBytes = worker_stack_bytes,
            .upstreamAllocatorPresent = false,
        };
    }
};

const StartupBarrier = struct {
    target: usize = worker_count,
    started: std.atomic.Value(usize) = .init(0),
    all_started: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    fn waitForRelease(io: std.Io, barrier: *StartupBarrier) void {
        if (barrier.started.fetchAdd(1, .acq_rel) + 1 == barrier.target) barrier.all_started.set(io);
        barrier.released.wait(io) catch {};
    }
};

fn prestartWorkers(threaded: *std.Io.Threaded, target: usize) !void {
    std.debug.assert(target > 0 and target <= worker_count);
    const io = threaded.io();
    var barrier: StartupBarrier = .{ .target = target };
    var futures: [worker_count]std.Io.Future(void) = undefined;
    var count: usize = 0;
    errdefer for (futures[0..count]) |*future| future.cancel(io);
    // Threaded counts a spawned worker before that worker has entered its
    // callback. Keep every callback blocked until all workers have actually
    // entered; otherwise an early worker can consume a late worker's task.
    for (futures[0..target]) |*future| {
        future.* = try io.concurrent(StartupBarrier.waitForRelease, .{ io, &barrier });
        count += 1;
    }
    try barrier.all_started.wait(io);
    std.debug.assert(barrier.started.load(.acquire) == target);
    barrier.released.set(io);
    for (futures[0..target]) |*future| future.await(io);
    // A future publishes completion just before Threaded returns that worker
    // to its idle pool. Finish that handoff before the first application job.
    while (true) {
        threaded.mutex.lockUncancelable(io);
        const idle = threaded.busy_count == 0;
        threaded.mutex.unlock(io);
        if (idle) return;
        std.Thread.yield() catch {};
    }
}

test "fixed runtime: startup barrier waits for a delayed callback on every prestarted worker" {
    var application: [8192]u8 align(16) = undefined;
    var io_storage: [192 * 1024]u8 align(16) = undefined;
    var startup: [4096]u8 align(16) = undefined;
    var runtime: Runtime = .{};
    try runtime.init(.{ .args = .{ .vector = &.{"startup-barrier-test"} }, .environ = .empty }, .{
        .application = &application,
        .io = &io_storage,
        .startup = &startup,
    }, application.len);
    defer runtime.deinit();
    try runtime.seal();
    const io = runtime.io();
    const pool = runtime.threaded.worker_threads.load(.acquire);
    var barrier: StartupBarrier = .{};
    var delay_last: std.Io.Event = .unset;
    var completed: std.atomic.Value(usize) = .init(0);
    var identities: [worker_count]std.Thread.Id = undefined;
    const Callback = struct {
        fn run(task_io: std.Io, gate: ?*std.Io.Event, shared: *StartupBarrier, identity: *std.Thread.Id, finished: *std.atomic.Value(usize)) void {
            if (gate) |event| event.wait(task_io) catch return;
            identity.* = std.Thread.getCurrentId();
            StartupBarrier.waitForRelease(task_io, shared);
            _ = finished.fetchAdd(1, .release);
        }
    };
    var futures: [worker_count]std.Io.Future(void) = undefined;
    var count: usize = 0;
    defer for (futures[0..count]) |*future| future.cancel(io);
    for (&futures, &identities, 0..) |*future, *identity, index| {
        future.* = try io.concurrent(Callback.run, .{ io, if (index + 1 == barrier.target) &delay_last else null, &barrier, identity, &completed });
        count += 1;
    }
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    while (barrier.started.load(.acquire) != worker_count - 1) {
        if (deadline.durationFromNow(io).raw.toNanoseconds() <= 0) return error.StartupBarrierTimeout;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!barrier.all_started.isSet());
    try std.testing.expect(!barrier.released.isSet());
    try std.testing.expectEqual(@as(usize, 0), completed.load(.acquire));
    delay_last.set(io);
    try barrier.all_started.wait(io);
    try std.testing.expectEqual(@as(usize, worker_count), barrier.started.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), completed.load(.acquire));
    for (identities, 0..) |identity, index| {
        for (identities[0..index]) |previous| try std.testing.expect(identity != previous);
        var found = false;
        var thread = pool;
        while (thread) |item| : (thread = item.next) found = found or item.id == identity;
        try std.testing.expect(found);
    }
    barrier.released.set(io);
    for (&futures) |*future| future.await(io);
    try std.testing.expectEqual(@as(usize, worker_count), completed.load(.acquire));
    try std.testing.expectEqual(pool, runtime.threaded.worker_threads.load(.acquire));
    try std.testing.expectEqual(@as(usize, worker_count), runtime.workerCount());
}
