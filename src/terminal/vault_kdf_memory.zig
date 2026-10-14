//! One bounded native mapping for password derivation. This is an explicit
//! transient workspace, separate from the normal mail heap. A lease is held
//! until Argon2 and its cancellation check finish; lock/stop must await it.
const std = @import("std");
const builtin = @import("builtin");
const t = @import("vault_types.zig");

var occupied: std.atomic.Value(bool) = .init(false);

pub const Lease = struct {
    bytes: []u8,
    active: bool = true,

    pub fn acquire(parameters: t.KdfParameters) !Lease {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
        if (parameters.memory_kib < 8 or parameters.passes == 0 or parameters.passes > t.KdfParameters.maximum_passes or parameters.lanes != 1) return error.InvalidVaultKdf;
        const size = try parameters.scratchBytes();
        if (occupied.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.VaultBusy;
        errdefer occupied.store(false, .release);
        // Page allocation is deliberate and limited to this one-off native
        // operation. It is not a fallback for arbitrary application allocations.
        return .{ .bytes = try std.heap.page_allocator.alloc(u8, size) };
    }

    pub fn release(self: *Lease) void {
        if (!self.active) return;
        std.crypto.secureZero(u8, self.bytes);
        std.heap.page_allocator.free(self.bytes);
        self.bytes = &.{};
        self.active = false;
        occupied.store(false, .release);
    }
};

pub fn busy() bool {
    return occupied.load(.acquire);
}

test "vault KDF memory: transient workspace is exclusive and returns its lease on every exit" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(!busy());
    {
        var lease = try Lease.acquire(.production);
        defer lease.release();
        try std.testing.expect(busy());
        try std.testing.expectEqual(try t.KdfParameters.production.scratchBytes(), lease.bytes.len);
        try std.testing.expectError(error.VaultBusy, Lease.acquire(.production));
        lease.bytes[0] = 0x7f;
        lease.bytes[lease.bytes.len - 1] = 0x7f;
    }
    try std.testing.expect(!busy());
    const Fail = struct {
        fn run() !void {
            var lease = try Lease.acquire(.production);
            defer lease.release();
            return error.SyntheticUnlockFailure;
        }
    };
    try std.testing.expectError(error.SyntheticUnlockFailure, Fail.run());
    try std.testing.expect(!busy());
    var recovered = try Lease.acquire(.production);
    recovered.release();
    recovered.release();
    try std.testing.expect(!busy());
    try std.testing.expectError(error.InvalidVaultKdf, Lease.acquire(.{ .memory_kib = t.KdfParameters.maximum_memory_kib + 1 }));
    try std.testing.expectError(error.InvalidVaultKdf, Lease.acquire(.{ .memory_kib = 0 }));
    try std.testing.expectError(error.InvalidVaultKdf, Lease.acquire(.{ .passes = 0 }));
    try std.testing.expectError(error.InvalidVaultKdf, Lease.acquire(.{ .lanes = 2 }));
    try std.testing.expect(!busy());
}
