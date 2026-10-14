//! Same-binary detached launch using the project's existing raw-only child
//! path. No allocation, locks or std.Io execute after fork in that primitive.
const std = @import("std");
const transport = @import("vault_transport.zig");
const header = @import("vault_header.zig");
const vt = @import("vault_types.zig");
const t = @import("types.zig");
const platform = @import("../platform.zig");
const j = @import("json.zig");

pub fn verifyOwner(io: std.Io, a: std.mem.Allocator, socket_path: []const u8, expected: vt.Id) !void {
    var check: Check = .{ .io = io, .a = a, .client = .{ .io = io, .socket_path = socket_path }, .expected = expected };
    if (!try platform.deadline(io, platform.seconds(5), Check.probe, .{&check})) return error.BackendStopped;
}

pub fn start(io: std.Io, a: std.mem.Allocator, vault_path: []const u8, socket_path: []const u8, options: t.Options) !void {
    const expected = blk: {
        var saved = try header.Store.open(io, vault_path, false);
        defer saved.close();
        break :blk (try saved.load()).header.vault_id;
    };
    var check: Check = .{ .io = io, .a = a, .client = .{ .io = io, .socket_path = socket_path }, .expected = expected };
    if (try platform.deadline(io, platform.seconds(5), Check.probe, .{&check})) return;
    var executable: [4096]u8 = undefined;
    const length = try std.process.executablePath(io, &executable);
    var argv: [16][]const u8 = undefined;
    const base = [_][]const u8{ executable[0..length], "vault", "serve", "--vault-dir", vault_path, "--socket", socket_path };
    @memcpy(argv[0..base.len], &base);
    var count: usize = base.len;
    if (options.fixtures) {
        argv[count] = "--fixtures";
        count += 1;
    }
    if (options.fixture_root) |root| {
        argv[count] = "--fixture-root";
        argv[count + 1] = root;
        count += 2;
    }
    if (!std.mem.eql(u8, options.fixture_scenario, "normal")) {
        argv[count] = "--fixture-scenario";
        argv[count + 1] = options.fixture_scenario;
        count += 2;
    }
    check.pid = try platform.launchDetachedPid(io, argv[0..count]);
    try platform.deadline(io, platform.seconds(10), Check.wait, .{&check});
}
const Check = struct {
    io: std.Io,
    a: std.mem.Allocator,
    client: transport.Client,
    expected: vt.Id,
    pid: ?i32 = null,
    fn probe(self: *Check) !bool {
        const bytes = self.client.request(self.a, .status, "") catch |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused => return false,
            else => return err,
        };
        defer self.a.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(j.Value, arena.allocator(), bytes, .{ .allocate = .alloc_if_needed });
        const ok = j.get(value, "ok") orelse return error.InvalidBackendFrame;
        if (ok != .bool) return error.InvalidBackendFrame;
        if (!ok.bool) return error.BackendStartFailed;
        const data = j.get(value, "data") orelse return error.InvalidBackendFrame;
        if (!std.mem.eql(u8, j.text(data, "vaultId"), &std.fmt.bytesToHex(self.expected, .lower))) return error.VaultIdentityMismatch;
        return true;
    }
    fn wait(self: *Check) !void {
        while (!try self.probe()) {
            if (self.pid) |pid| if (!try platform.detachedRunning(self.io, pid)) return error.BackendStartFailed;
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(25) }).sleep(self.io);
        }
    }
};
