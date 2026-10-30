//! Same-binary detached launch using the project's existing raw-only child
//! path. No allocation, locks or std.Io execute after fork in that primitive.
const std = @import("std");
const test_allocator = @import("../cancel_neutral_test_allocator.zig");
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

/// Safe controls must remain available to stop an incompatible old backend.
/// Identity checks remain mandatory for an activated vault.
pub fn verifyControlOwner(io: std.Io, a: std.mem.Allocator, socket_path: []const u8, expected: vt.Id) !void {
    var check: Check = .{ .io = io, .a = a, .client = .{ .io = io, .socket_path = socket_path }, .expected = expected, .require_protocol = false };
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
    require_protocol: bool = true,
    pid: ?i32 = null,
    fn probe(self: *Check) !bool {
        const bytes = self.client.request(self.a, .status, "") catch |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused => return false,
            // Our child binds before chmod publishes the private socket mode.
            // Keep transport checks intact and wait only during our own launch;
            // an unsafe pre-existing path must still fail before spawning.
            error.UnsafeBackendSocket => if (self.pid != null) return false else return err,
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
        if (self.require_protocol) try transport.requireExecutionProtocol(data);
        return true;
    }
    fn wait(self: *Check) !void {
        while (!try self.probe()) {
            if (self.pid) |pid| if (!try platform.detachedRunning(self.io, pid)) return error.BackendStartFailed;
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(25) }).sleep(self.io);
        }
    }
};

test "vault launch: owned socket permissions become ready before the first status exchange" {
    test_allocator.install();
    if (!@import("send_memory.zig").native) return error.SkipZigTest;
    const io = std.testing.io;
    const a = test_allocator.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.parent_dir.setFilePermissions(io, &temporary.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/socket", .{root});
    defer a.free(path);
    const expected: vt.Id = @splat(0x37);
    var check: Check = .{ .io = io, .a = a, .client = .{ .io = io, .socket_path = path }, .expected = expected };
    try std.testing.expect(!try check.probe()); // The child's socket is not bound yet.

    var listener = try transport.Listener.init(io, path);
    defer listener.deinit();
    // Recreate the bind-before-chmod interval under the same private parent.
    try temporary.dir.setFilePermissions(io, "socket", .fromMode(0o644), .{ .follow_symlinks = false });
    try std.testing.expectError(error.UnsafeBackendSocket, check.probe());
    // The test's own live PID supplies only the existing read-only liveness
    // check. No detached child, credential, or process signal is needed.
    check.pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else std.c.getpid();
    try std.testing.expect(!try check.probe());
    try std.testing.expectError(error.UnsafeBackendSocket, check.client.request(a, .status, ""));
    try std.testing.expectError(error.Timeout, platform.deadline(io, .{ .clock = .awake, .raw = .fromMilliseconds(75) }, Check.wait, .{&check}));

    const Peer = struct {
        fn respond(server: *transport.Listener, id: vt.Id, requests: *std.atomic.Value(usize)) !void {
            const peer_io = std.testing.io;
            const peer_a = test_allocator.allocator;
            const stream = try server.server.accept(peer_io);
            defer stream.close(peer_io);
            var frame = try transport.readFrame(peer_io, peer_a, stream, transport.request_limit);
            defer frame.deinit(peer_a);
            try std.testing.expectEqual(transport.Kind.status, frame.kind);
            try std.testing.expectEqual(@as(usize, 0), frame.body.len);
            _ = requests.fetchAdd(1, .release);
            var bytes: [128]u8 = undefined;
            const response = try std.fmt.bufPrint(&bytes, "{{\"ok\":true,\"data\":{{\"vaultId\":\"{s}\",\"executionProtocol\":3}}}}", .{std.fmt.bytesToHex(id, .lower)});
            try transport.writeFrame(peer_io, stream, .response, response, transport.response_limit);
        }
    };
    var requests: std.atomic.Value(usize) = .init(0);
    var peer = try io.concurrent(Peer.respond, .{ &listener, expected, &requests });
    defer peer.cancel(io) catch {};
    try temporary.dir.setFilePermissions(io, "socket", .fromMode(0o600), .{ .follow_symlinks = false });
    try platform.deadline(io, platform.seconds(5), Check.wait, .{&check});
    try peer.await(io);
    // An earlier unsafe connect would have queued an extra/empty connection
    // and failed the peer's framed-status check instead of reaching this count.
    try std.testing.expectEqual(@as(usize, 1), requests.load(.acquire));
}

test "vault launch: unsafe path kinds never become trusted during owned readiness" {
    test_allocator.install();
    if (!@import("send_memory.zig").native) return error.SkipZigTest;
    const io = std.testing.io;
    const a = test_allocator.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.parent_dir.setFilePermissions(io, &temporary.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/socket", .{root});
    defer a.free(path);
    const target = try temporary.dir.createFile(io, "target", .{ .permissions = .fromMode(0o600) });
    target.close(io);
    for ([_]bool{ false, true }) |symlink| {
        if (symlink) {
            try temporary.dir.symLink(io, "target", "socket", .{});
        } else {
            const file = try temporary.dir.createFile(io, "socket", .{ .permissions = .fromMode(0o600) });
            file.close(io);
        }
        defer temporary.dir.deleteFile(io, "socket") catch {};
        var check: Check = .{ .io = io, .a = a, .client = .{ .io = io, .socket_path = path }, .expected = @splat(0x37) };
        try std.testing.expectError(error.UnsafeBackendSocket, check.probe());
        check.pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else std.c.getpid();
        try std.testing.expect(!try check.probe());
        try std.testing.expectError(error.UnsafeBackendSocket, check.client.request(a, .status, ""));
    }
}

test "vault protocol: startup requires compatible generation while control ownership keeps identity checks" {
    test_allocator.install();
    const io = std.testing.io;
    const a = test_allocator.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.parent_dir.setFilePermissions(io, &tmp.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/socket", .{root});
    defer a.free(path);
    const expected: vt.Id = @splat(0x37);
    var listener = try transport.Listener.init(io, path);
    defer listener.deinit();
    const Peer = struct {
        fn run(server: *transport.Listener, id: vt.Id) !void {
            for (0..5) |index| {
                const stream = try server.server.accept(std.testing.io);
                defer stream.close(std.testing.io);
                var frame = try transport.readFrame(std.testing.io, test_allocator.allocator, stream, transport.request_limit);
                defer frame.deinit(test_allocator.allocator);
                try std.testing.expectEqual(transport.Kind.status, frame.kind);
                var bytes: [160]u8 = undefined;
                const response = try std.fmt.bufPrint(&bytes, "{{\"ok\":true,\"data\":{{\"vaultId\":\"{s}\"{s}}}}}", .{ std.fmt.bytesToHex(id, .lower), if (index == 4) ",\"executionProtocol\":3" else "" });
                try transport.writeFrame(std.testing.io, stream, .response, response, transport.response_limit);
            }
        }
    };
    var peer = try io.concurrent(Peer.run, .{ &listener, expected });
    defer peer.cancel(io) catch {};
    var check: Check = .{ .io = io, .a = a, .client = .{ .io = io, .socket_path = path }, .expected = expected };
    try std.testing.expectError(error.BackendProtocolMismatch, check.probe());
    try std.testing.expectError(error.BackendProtocolMismatch, verifyOwner(io, a, path, expected));
    try verifyControlOwner(io, a, path, expected);
    try std.testing.expectError(error.VaultIdentityMismatch, verifyControlOwner(io, a, path, @splat(0x38)));
    try verifyOwner(io, a, path, expected);
    try peer.await(io);
}
