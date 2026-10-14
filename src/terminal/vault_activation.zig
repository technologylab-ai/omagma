//! Explicit native-vault routing. The public marker contains no account or
//! credential material and never authorizes fallback to an old plaintext store.
const std = @import("std");
const private = @import("../keyring_file.zig");
const files = @import("files.zig");
const vt = @import("vault_types.zig");
pub const filename = "native-vault.json";
pub const max_bytes = 12 * 1024;
pub const Marker = struct {
    schema: u8,
    vaultDirectory: []const u8,
    vaultId: []const u8,
    socketPath: []const u8,

    pub fn id(self: Marker) !vt.Id {
        var result: vt.Id = undefined;
        if (self.vaultId.len != result.len * 2) return error.InvalidVaultActivation;
        _ = std.fmt.hexToBytes(&result, self.vaultId) catch return error.InvalidVaultActivation;
        if (std.mem.allEqual(u8, &result, 0)) return error.InvalidVaultActivation;
        return result;
    }
};
fn absolute(value: []const u8, limit: usize) !void {
    if (value.len < 2 or value.len > limit or value[0] != '/' or !std.unicode.utf8ValidateSlice(value)) return error.InvalidVaultActivation;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidVaultActivation;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidVaultActivation;
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Marker {
    if (bytes.len == 0 or bytes.len > max_bytes) return error.InvalidVaultActivation;
    const marker = std.json.parseFromSliceLeaky(Marker, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch return error.InvalidVaultActivation;
    if (marker.schema != 1) return error.InvalidVaultActivation;
    try absolute(marker.vaultDirectory, 4096);
    try absolute(marker.socketPath, 103); // Fits both Linux and macOS sockaddr_un.
    _ = try marker.id();
    return marker;
}
pub fn path(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const base = env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{env.get("HOME") orelse return error.HomeRequired});
    try absolute(base, 4000);
    return std.fmt.allocPrint(a, "{s}/omagma/{s}", .{ base, filename });
}
pub fn loadPath(io: std.Io, a: std.mem.Allocator, selected_path: []const u8) !?Marker {
    try absolute(selected_path, 4096);
    // An absent marker must work with ordinary existing installation folders,
    // even when those folders predate the private vault's stricter permissions.
    const file = files.openRegular(io, a, .cwd(), selected_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    try private.privateFile(io, file);
    const parent_path = std.fs.path.dirname(selected_path) orelse return error.InvalidVaultActivation;
    const parent = try private.directory(io, parent_path, false);
    defer parent.close(io);
    if ((try file.stat(io)).size > max_bytes) return error.InvalidVaultActivation;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .limited(max_bytes));
    return try parse(a, bytes);
}
pub fn load(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map) !?Marker {
    return loadPath(io, a, try path(a, env));
}
/// Caller verifies the completed migration and authenticated vault identity
/// first. This operation only publishes that reviewed routing choice. Another
/// active vault is never silently replaced, even by an otherwise valid marker.
pub fn publish(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, marker: Marker) !void {
    return publishPath(io, a, try path(a, env), marker);
}
pub fn publishPath(io: std.Io, a: std.mem.Allocator, selected_path: []const u8, marker: Marker) !void {
    const bytes = try @import("json.zig").encodeAlloc(a, marker, .{});
    _ = try parse(a, bytes);
    if (try loadPath(io, a, selected_path)) |previous| {
        if (std.mem.eql(u8, previous.vaultDirectory, marker.vaultDirectory) and std.mem.eql(u8, previous.vaultId, marker.vaultId) and std.mem.eql(u8, previous.socketPath, marker.socketPath)) return;
        return error.VaultAlreadyActive;
    }
    const parent = try private.directory(io, std.fs.path.dirname(selected_path) orelse return error.InvalidVaultActivation, true);
    defer parent.close(io);
    var atomic = try parent.createFileAtomic(io, std.fs.path.basename(selected_path), .{ .permissions = .fromMode(0o600), .replace = false });
    defer atomic.deinit(io);
    try private.privateAtomicFile(io, atomic.file);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.VaultAlreadyActive,
        else => return err,
    };
    try @import("vault_storage.zig").syncDirectory(io, parent);
}

test "vault activation: strict version identity paths and unknown fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid = "{\"schema\":1,\"vaultDirectory\":\"/private/vault\",\"vaultId\":\"0102030405060708090a0b0c0d0e0f10\",\"socketPath\":\"/private/socket\"}";
    const parsed = try parse(a, valid);
    try std.testing.expectEqual(@as(u8, 1), (try parsed.id())[0]);
    for ([_][]const u8{
        "{\"schema\":2,\"vaultDirectory\":\"/vault\",\"vaultId\":\"0102030405060708090a0b0c0d0e0f10\",\"socketPath\":\"/socket\"}",
        "{\"schema\":1,\"vaultDirectory\":\"/vault\",\"vaultId\":\"00000000000000000000000000000000\",\"socketPath\":\"/socket\"}",
        "{\"schema\":1,\"vaultDirectory\":\"relative\",\"vaultId\":\"0102030405060708090a0b0c0d0e0f10\",\"socketPath\":\"/socket\"}",
        "{\"schema\":1,\"vaultDirectory\":\"/vault/../other\",\"vaultId\":\"0102030405060708090a0b0c0d0e0f10\",\"socketPath\":\"/socket\"}",
        "{\"schema\":1,\"vaultDirectory\":\"/vault\",\"vaultId\":\"0102030405060708090a0b0c0d0e0f10\",\"socketPath\":\"/socket\",\"plaintextFallback\":true}",
    }) |invalid| try std.testing.expectError(error.InvalidVaultActivation, parse(a, invalid));
}

test "vault activation: absent creates nothing publication is private and a different vault cannot replace it" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const target = try std.fmt.allocPrint(a, "{s}/private/{s}", .{ root, filename });
    try std.testing.expect((try loadPath(io, a, target)) == null);
    try std.testing.expectError(error.FileNotFound, temporary.dir.openDir(io, "private", .{}));
    const marker: Marker = .{ .schema = 1, .vaultDirectory = "/synthetic/vault", .vaultId = "0102030405060708090a0b0c0d0e0f10", .socketPath = "/synthetic/socket" };
    try publishPath(io, a, target, marker);
    const saved = (try loadPath(io, a, target)).?;
    try std.testing.expectEqualStrings(marker.vaultId, saved.vaultId);
    try publishPath(io, a, target, marker);
    var changed = marker;
    changed.socketPath = "/synthetic/different";
    try std.testing.expectError(error.VaultAlreadyActive, publishPath(io, a, target, changed));
    try std.testing.expectEqualStrings(marker.socketPath, (try loadPath(io, a, target)).?.socketPath);
}
