//! Native outgoing preparation gets a short-lived OS-backed arena, separate
//! from the normal fixed UI/read heap. Message, MIME and disk quotas still
//! apply; a long illustrated thread is not subject to an incidental heap cap.
//! No allocator or borrowed result may escape the synchronous operation.
const std = @import("std");
const Meter = @import("capped_allocator.zig").CappedAllocator;
pub const native = @import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos;

const State = if (native) struct {
    var pages: Meter = .{ .backing = std.heap.page_allocator, .limit = std.math.maxInt(usize) };
    var secure: @import("vault_allocator.zig").WipingAllocator = .{ .backing = pages.allocator() };
} else struct {};

pub fn allocator() std.mem.Allocator {
    // The wrapper itself is immutable; construct it at comptime so concurrent
    // operations never race to initialize a global allocator vtable.
    if (!native) @compileError("Outgoing OS-backed allocation is native-only");
    return State.secure.allocator();
}

pub fn operationBacking(normal: std.mem.Allocator, raw: []const u8, cached_only: bool) std.mem.Allocator {
    if (!native) return normal;
    return if (!cached_only and request(raw)) allocator() else normal;
}

pub const Snapshot = struct {
    allocatorUsedBytes: usize,
    allocatorPeakBytes: usize,
    rejectedAllocations: usize,
    allocatorLimitBytes: ?usize = null,
    osBacked: bool = true,
};
pub fn snapshot() Snapshot {
    if (!native) return .{ .allocatorUsedBytes = 0, .allocatorPeakBytes = 0, .rejectedAllocations = 0, .osBacked = false };
    const value = State.pages.snapshot();
    return .{ .allocatorUsedBytes = value.allocatorUsedBytes, .allocatorPeakBytes = value.allocatorPeakBytes, .rejectedAllocations = value.rejectedAllocations };
}

// JSON escaping can expand text sixfold. A retained original has both HTML
// and plain alternatives; recovery may additionally retain the authored text.
// This is a serialization ceiling, never a reservation or allocation size.
pub const record_bytes = if (native) 12 * @import("types.zig").Limits.compose_body_bytes else 4 * @import("types.zig").Limits.body_bytes;
pub const source_response_bytes = if (native) ((@import("types.zig").Limits.mime_upload_bytes + 2) / 3) * 4 + 2 * 1024 * 1024 else @import("types.zig").Limits.request_bytes;
pub fn seconds(name: []const u8) i64 {
    return if (native and command(name)) @import("../attachment_limits.zig").download_seconds else 30;
}
pub fn requestLimit(raw: []const u8) usize {
    return if (request(raw)) record_bytes else @import("types.zig").Limits.request_bytes;
}
pub fn commandBacking(normal: std.mem.Allocator, name: []const u8) std.mem.Allocator {
    if (!native) return normal;
    return if (command(name)) allocator() else normal;
}
pub fn command(name: []const u8) bool {
    for ([_][]const u8{ "mail.compose-source", "mail.reply", "mail.forward", "draft.create", "draft.update", "draft.read", "draft.clone", "draft.recovery-save", "draft.gmail-info", "draft.gmail-status", "draft.gmail-take-back", "draft.gmail-import", "draft.gmail-open", "draft.preview", "draft.measure", "draft.open-preview", "draft.queue", "queue.process", "queue.send-now", "mail.send", "draft.send", "invitation.reply", "draft.gmail-save", "operation.read" }) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

/// Inspect only the top-level command before the full request (and inline
/// images) are decoded. Unknown values are skipped without allocating them.
/// The ordinary parser still validates the whole bounded request afterwards.
pub fn request(raw: []const u8) bool {
    if (!native) return false;
    if (raw.len > record_bytes) return false;
    var bytes: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&bytes);
    const selector = std.json.parseFromSliceLeaky(struct { cmd: []const u8 }, fixed.allocator(), raw, .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = true, .max_value_len = 256 }) catch return false;
    return command(selector.cmd);
}

test "native send memory: target policy and ordinary calls retain the caller allocator" {
    var bytes: [32]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&bytes);
    const normal = fixed.allocator();
    try std.testing.expectEqual(normal, operationBacking(normal, "{\"cmd\":\"mail.read\"}", false));
    try std.testing.expectEqual(normal, operationBacking(normal, "{\"cmd\":\"draft.send\"}", true));
    if (!native) {
        try std.testing.expect(!request("{\"cmd\":\"draft.send\"}"));
        try std.testing.expectEqual(normal, operationBacking(normal, "{\"cmd\":\"draft.send\"}", false));
        try std.testing.expect(!snapshot().osBacked);
    }
}

test "native send memory: command selection precedes large values without broadening normal reads" {
    if (!native) return error.SkipZigTest;
    try std.testing.expect(request("{\"cmd\":\"draft.send\"}"));
    try std.testing.expect(request("{\"draft\":{\"cmd\":\"mail.read\"},\"c\\u006dd\":\"\\u0064raft.send\"}"));
    for ([_][]const u8{ "{\"cmd\":\"mail.read\",\"draft\":{\"cmd\":\"draft.send\"}}", "{\"draft\":{\"cmd\":\"draft.send\"}}", "{\"cmd\":\"draft.send\",\"cmd\":\"mail.read\"}", "{\"cmd\":\"mail.read\",\"cmd\":\"draft.send\"}", "{\"cmd\":\"draft.send\",", "{\"cmd\":null}" }) |raw| try std.testing.expect(!request(raw));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, "{\"draft\":{\"bodyText\":\"");
    try bytes.appendNTimes(std.testing.allocator, 'x', 1024 * 1024);
    try bytes.appendSlice(std.testing.allocator, "\"},\"cmd\":\"draft.preview\"}");
    try std.testing.expect(request(bytes.items));
    for ([_][]const u8{ "draft.queue", "queue.process", "queue.send-now", "draft.open-preview", "draft.gmail-save", "invitation.reply" }) |name| try std.testing.expect(command(name));
    for ([_][]const u8{ "mail.read", "mail.thread", "cache.stats", "draft.list", "accounts.list", "unknown" }) |name| try std.testing.expect(!command(name));
}

test "native send memory: transient arenas exceed 256 MiB and release on failure and joined cancellation" {
    if (!native) return error.SkipZigTest;
    const baseline = snapshot().allocatorUsedBytes;
    {
        var arena: std.heap.ArenaAllocator = .init(allocator());
        defer arena.deinit();
        const memory = try arena.allocator().alloc(u8, 257 * 1024 * 1024);
        memory[0] = 0x5a;
        memory[memory.len - 1] = 0xa5;
        try std.testing.expect(snapshot().allocatorUsedBytes > 256 * 1024 * 1024);
    }
    try std.testing.expectEqual(baseline, snapshot().allocatorUsedBytes);
    const Job = struct {
        fn run(io: std.Io, entered: *std.Io.Event, release: *std.Io.Event, index: usize) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(allocator());
            defer arena.deinit();
            const memory = try arena.allocator().alloc(u8, (index + 1) * 1024 * 1024);
            @memset(memory, @intCast(index));
            entered.set(io);
            try release.wait(io);
            for (memory) |byte| if (byte != index) return error.CorruptedTransientArena;
            if (index == 1) return error.SyntheticPreparationFailure;
        }
    };
    const io = std.testing.io;
    var entered: [3]std.Io.Event = @splat(.unset);
    var release: std.Io.Event = .unset;
    var futures: [3]std.Io.Future(anyerror!void) = undefined;
    var count: usize = 0;
    errdefer for (futures[0..count]) |*future| future.cancel(io) catch {};
    for (&futures, &entered, 0..) |*future, *started, index| {
        future.* = try io.concurrent(Job.run, .{ io, started, &release, index });
        count += 1;
    }
    for (&entered) |*event| try event.wait(io);
    try std.testing.expect(snapshot().allocatorUsedBytes >= baseline + 6 * 1024 * 1024);
    try std.testing.expectError(error.Canceled, futures[0].cancel(io));
    release.set(io);
    try std.testing.expectError(error.SyntheticPreparationFailure, futures[1].await(io));
    try futures[2].await(io);
    try std.testing.expectEqual(baseline, snapshot().allocatorUsedBytes);
}
