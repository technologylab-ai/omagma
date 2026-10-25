comptime {
    _ = @import("terminal/vault_activation.zig");
    _ = @import("terminal/backend_retry.zig");
}

const std = @import("std");
const runtime_module = @import("fixed_runtime.zig");
const platform = @import("platform.zig");
const launch = @import("terminal/vault_launch.zig");
const transport = @import("terminal/vault_transport.zig");
const test_io = std.testing.io;
const a = std.testing.allocator;

test "vault launch: nested identity deadlines tolerate joined control worker retirement" {
    const Gate = struct {
        backing: std.mem.Allocator,
        io: std.Io,
        remaining: std.atomic.Value(usize) = .init(0),
        entered: std.atomic.Value(usize) = .init(0),
        release: std.Io.Event = .unset,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawAlloc(bytes, alignment, ra);
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var remaining = self.remaining.load(.acquire);
            while (remaining > 0) {
                remaining = self.remaining.cmpxchgWeak(remaining, remaining - 1, .acq_rel, .acquire) orelse {
                    _ = self.entered.fetchAdd(1, .release);
                    self.release.waitUncancelable(self.io);
                    break;
                };
            }
            self.backing.rawFree(bytes, alignment, ra);
        }
    };
    const Work = struct {
        fn waitIdle(runtime: *runtime_module.Runtime, wanted: usize) !void {
            const io = runtime.io();
            const deadline = std.Io.Clock.Timestamp.fromNow(io, platform.seconds(5));
            while (true) {
                runtime.threaded.mutex.lockUncancelable(io);
                const busy = runtime.threaded.busy_count;
                runtime.threaded.mutex.unlock(io);
                if (busy == wanted) return;
                if (deadline.durationFromNow(io).raw.toNanoseconds() <= 0) return error.RetirementTimedOut;
                std.Thread.yield() catch {};
            }
        }
        fn respond(listener: *transport.Listener, id: [16]u8, count: usize, requests: *std.atomic.Value(usize)) !void {
            for (0..count) |_| {
                const stream = try listener.server.accept(test_io);
                defer stream.close(test_io);
                var frame = try transport.readFrame(test_io, a, stream, transport.request_limit);
                defer frame.deinit(a);
                try std.testing.expectEqual(transport.Kind.status, frame.kind);
                _ = requests.fetchAdd(1, .release);
                var bytes: [128]u8 = undefined;
                const raw = try std.fmt.bufPrint(&bytes, "{{\"ok\":true,\"data\":{{\"vaultId\":\"{s}\",\"executionProtocol\":2}}}}", .{std.fmt.bytesToHex(id, .lower)});
                try transport.writeFrame(test_io, stream, .response, raw, transport.response_limit);
            }
        }
    };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.parent_dir.setFilePermissions(test_io, &temp.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    var path_buffer: [4096]u8 = undefined;
    const root = path_buffer[0..try temp.dir.realPath(test_io, &path_buffer)];
    const socket = try std.fmt.allocPrint(a, "{s}/socket", .{root});
    defer a.free(socket);
    var listener = try transport.Listener.init(test_io, socket);
    defer listener.deinit();
    const id: [16]u8 = @splat(0x37);
    for ([_]bool{ true, false }) |small| {
        var requests: std.atomic.Value(usize) = .init(0);
        var server = try test_io.concurrent(Work.respond, .{ &listener, id, if (small) @as(usize, 1) else 2, &requests });
        defer server.cancel(test_io) catch {};
        var application: [8192]u8 align(16) = undefined;
        var io_storage: [192 * 1024]u8 align(16) = undefined;
        var startup: [4096]u8 = undefined;
        var runtime: runtime_module.Runtime = .{};
        try runtime.init(.{ .args = .{ .vector = &.{"launch-retirement-test"} }, .environ = .empty }, .{
            .application = &application,
            .io = &io_storage,
            .startup = &startup,
        }, application.len);
        defer runtime.deinit();
        if (small) try runtime.sealClient() else try runtime.sealControl();
        const io = runtime.io();
        const pool = runtime.threaded.worker_threads.load(.acquire);
        const baseline = runtime.io_meter.snapshot().allocatorUsedBytes;
        var gate: Gate = .{ .backing = runtime.threaded.allocator, .io = io };
        runtime.threaded.allocator = gate.allocator();
        // Hold all four actual identity/transport tasks after their joined
        // completion, before Threaded decrements its worker busy count.
        gate.remaining.store(4, .release);
        defer gate.release.set(io);
        try launch.verifyOwner(io, a, socket, id);
        const deadline = std.Io.Clock.Timestamp.fromNow(io, platform.seconds(5));
        while (gate.entered.load(.acquire) != 4) {
            if (deadline.durationFromNow(io).raw.toNanoseconds() <= 0) return error.RetirementTimedOut;
            std.Thread.yield() catch {};
        }
        try Work.waitIdle(&runtime, 4);
        try std.testing.expectEqual(@as(usize, 1), requests.load(.acquire));
        const response = launch.verifyOwner(io, a, socket, id);
        if (small) {
            try std.testing.expectError(error.ConcurrencyUnavailable, response);
        } else {
            try response;
        }
        try std.testing.expectEqual(@as(usize, if (small) 1 else 2), requests.load(.acquire));
        gate.release.set(io);
        try Work.waitIdle(&runtime, 0);
        try std.testing.expectEqual(baseline, runtime.io_meter.snapshot().allocatorUsedBytes);
        try std.testing.expectEqual(pool, runtime.threaded.worker_threads.load(.acquire));
        try std.testing.expectEqual(@as(usize, if (small) 4 else runtime_module.worker_count), runtime.workerCount());
        try server.await(test_io);
    }
}
