const std = @import("std");
const exporter = @import("browser_export.zig");
const keyring = @import("keyring.zig");
const auth = @import("terminal/auth.zig");
const io = std.testing.io;
const account = "synthetic@example.test";
const client_id = "synthetic-client.apps.googleusercontent.com";
const caps: []const []const u8 = &.{ "mail-read", "mail-send" };

const Fixture = struct {
    a: std.mem.Allocator,
    path: []const u8,
    dir: std.Io.Dir,
    config: []const u8,
    grants: []const u8,
    client: []const u8,
    output: []const u8,
    settings: keyring.Settings,
    scopes: []const []const u8,
    grant: [64]u8,
    fn init(a: std.mem.Allocator, token: bool) !Fixture {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const path = try std.fmt.allocPrint(a, "/tmp/omagma-browser-export-test-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try std.Io.Dir.createDirAbsolute(io, path, .fromMode(0o700));
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        const scopes = try auth.scopesFor(a, caps);
        var f: Fixture = .{ .a = a, .path = path, .dir = dir, .config = try std.fmt.allocPrint(a, "{s}/config.json", .{path}), .grants = try std.fmt.allocPrint(a, "{s}/grants.json", .{path}), .client = try std.fmt.allocPrint(a, "{s}/client.json", .{path}), .output = try std.fmt.allocPrint(a, "{s}/browser/connection.json", .{path}), .settings = .{ .kind = .file, .directory = try std.fmt.allocPrint(a, "{s}/tokens", .{path}) }, .scopes = scopes, .grant = auth.grantIdentity(scopes) };
        try f.write("client.json", .{ .installed = .{ .client_id = client_id, .client_secret = "SYNTHETIC_CLIENT_SECRET_ONLY" } });
        try f.write("config.json", .{ .credentialStore = "file", .credentialDirectory = f.settings.directory, .accounts = .{ .{ .address = account, .profile = "Profile 1" }, .{ .address = "disabled@example.test", .profile = "Profile 2", .enabled = false } } });
        var grants = [_]auth.Grant{.{ .account = account, .clientFile = f.client, .clientId = client_id, .grantId = &f.grant, .capabilities = caps, .scopes = scopes }};
        try f.write("grants.json", auth.Registry{ .accounts = &grants });
        if (token) try keyring.storeTerminal(io, f.settings, account, client_id, &f.grant, "SYNTHETIC_REFRESH_TOKEN_ONLY");
        return f;
    }
    fn write(f: *Fixture, name: []const u8, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(f.a, value, .{});
        const target = try f.dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        defer target.close(io);
        try target.writeStreamingAll(io, bytes);
    }
    fn deinit(f: *Fixture) void {
        f.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, f.path) catch {};
    }
};

test "browser export: one validated private bundle preserves selected store and source credentials" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(a, true);
    defer fixture.deinit();
    const config_before = try fixture.dir.readFileAlloc(io, "config.json", a, .limited(16 * 1024));
    const result = try exporter.run(io, a, "/tmp", fixture.config, fixture.grants, fixture.output);
    try std.testing.expectEqual(@as(usize, 1), result.exportedAccounts);
    try std.testing.expectEqualStrings("file", result.credentialStore);
    try std.testing.expectEqualStrings(config_before, try fixture.dir.readFileAlloc(io, "config.json", a, .limited(16 * 1024)));
    var tokens: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("SYNTHETIC_REFRESH_TOKEN_ONLY", (try keyring.lookupTerminal(io, fixture.settings, account, client_id, &fixture.grant, &tokens)).?);
    const output = try fixture.dir.readFileAlloc(io, "browser/connection.json", a, .limited(64 * 1024));
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, output, .{ .duplicate_field_behavior = .@"error" });
    try std.testing.expectEqualStrings("omagma-browser-connection", value.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("version").?.integer);
    const accounts = value.object.get("accounts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), accounts.len);
    try std.testing.expectEqualStrings("SYNTHETIC_CLIENT_SECRET_ONLY", accounts[0].object.get("clientSecret").?.string);
    try std.testing.expectEqualStrings("SYNTHETIC_REFRESH_TOKEN_ONLY", accounts[0].object.get("refreshToken").?.string);
    const parent_stat = try fixture.dir.statFile(io, "browser", .{ .follow_symlinks = false });
    const file_stat = try fixture.dir.statFile(io, "browser/connection.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o700), parent_stat.permissions.toMode() & 0o7777);
    try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o7777);
    try std.testing.expectError(error.OutputAlreadyExists, exporter.run(io, a, "/tmp", fixture.config, fixture.grants, fixture.output));
    try std.testing.expectEqualStrings(output, try fixture.dir.readFileAlloc(io, "browser/connection.json", a, .limited(64 * 1024)));
}

test "browser export: missing token and mismatched OAuth client leave no output or partial file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(a, false);
    defer fixture.deinit();
    try std.testing.expectError(error.RefreshTokenMissing, exporter.run(io, a, "/tmp", fixture.config, fixture.grants, fixture.output));
    try std.testing.expectError(error.FileNotFound, fixture.dir.statFile(io, "browser/connection.json", .{}));
    var parent = try fixture.dir.openDir(io, "browser", .{ .iterate = true });
    defer parent.close(io);
    var iterator = parent.iterate();
    try std.testing.expect(try iterator.next(io) == null);
    try fixture.write("client.json", .{ .installed = .{ .client_id = "different.apps.googleusercontent.com", .client_secret = "SYNTHETIC_DIFFERENT" } });
    try std.testing.expectError(error.GrantClientMismatch, exporter.run(io, a, "/tmp", fixture.config, fixture.grants, fixture.output));
    try std.testing.expect(try iterator.next(io) == null);
}

test "browser export: rejects unsafe directories noncanonical paths symlinks and repository destinations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(a, true);
    defer fixture.deinit();
    try fixture.dir.createDir(io, "unsafe", .fromMode(0o755));
    const unsafe = try std.fmt.allocPrint(a, "{s}/unsafe/connection.json", .{fixture.path});
    try std.testing.expectError(error.UnsafeCredentialPermissions, exporter.run(io, a, "/tmp", fixture.config, fixture.grants, unsafe));
    try fixture.dir.symLink(io, "/tmp", "link", .{});
    const symlink = try std.fmt.allocPrint(a, "{s}/link/connection.json", .{fixture.path});
    if (exporter.run(io, a, "/tmp", fixture.config, fixture.grants, symlink)) |_| return error.SymlinkAccepted else |_| {}
    const noncanonical = try std.fmt.allocPrint(a, "{s}//browser/connection.json", .{fixture.path});
    try std.testing.expectError(error.NonCanonicalOutputDirectory, exporter.run(io, a, "/tmp", fixture.config, fixture.grants, noncanonical));
    try fixture.dir.createDir(io, ".git", .fromMode(0o700));
    try std.testing.expectError(error.OutputInsideRepository, exporter.run(io, a, "/tmp", fixture.config, fixture.grants, fixture.output));
    try std.testing.expectError(error.FileNotFound, fixture.dir.statFile(io, "browser/connection.json", .{}));
}
