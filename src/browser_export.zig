//! Offline collection of existing terminal grants for browser connections.
//! Explicit file export shares the same bounded collector; storage stays selected.
const std = @import("std");
const Config = @import("config.zig").Config;
const credentials = @import("keyring.zig");
const private = @import("keyring_file.zig");
const oauth = @import("oauth.zig");
const auth = @import("terminal/auth.zig");
const files = @import("terminal/files.zig");
const max_bundle_bytes = 64 * 1024;

const Account = struct {
    account: []const u8,
    clientId: []const u8,
    clientSecret: []const u8,
    grantId: []const u8,
    capabilities: []const []const u8,
    scopes: []const []const u8,
    refreshToken: []const u8,
};
pub const Result = struct {
    ok: bool = true,
    format: []const u8 = "browser",
    exportedAccounts: usize,
    credentialStore: []const u8,
    outputFile: []const u8,
};
fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidOutputPath;
    for (name) |byte| if (byte < 32 or byte == 127 or byte == '/' or byte == '\\') return error.InvalidOutputPath;
}
fn rejectRepositoryAncestors(io: std.Io, absolute: []const u8) !void {
    var path = absolute;
    while (true) {
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false });
        defer dir.close(io);
        if (dir.statFile(io, ".git", .{ .follow_symlinks = false })) |_| return error.OutputInsideRepository else |err| if (err != error.FileNotFound) return err;
        if (std.mem.eql(u8, path, "/")) break;
        path = std.fs.path.dirname(path) orelse return error.InvalidOutputPath;
    }
}
fn openOutputParent(io: std.Io, a: std.mem.Allocator, output_path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(output_path) or output_path.len > 4096 or std.mem.indexOfScalar(u8, output_path, 0) != null) return error.InvalidOutputPath;
    const parent = std.fs.path.dirname(output_path) orelse return error.InvalidOutputPath;
    try validateName(std.fs.path.basename(output_path));
    var dir = try private.directory(io, parent, true);
    errdefer dir.close(io);
    const canonical = try dir.realPathFileAlloc(io, ".", a);
    if (!std.mem.eql(u8, parent, canonical)) return error.NonCanonicalOutputDirectory;
    try rejectRepositoryAncestors(io, canonical);
    if (dir.statFile(io, std.fs.path.basename(output_path), .{ .follow_symlinks = false })) |_| return error.OutputAlreadyExists else |err| if (err != error.FileNotFound) return err;
    return dir;
}
fn loadConfig(io: std.Io, a: std.mem.Allocator, home: []const u8, config_path: []const u8, config: *Config) !void {
    const source = try files.openRegular(io, a, .cwd(), config_path);
    defer source.close(io);
    try private.privateFile(io, source);
    var bytes: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    var buffer: [4096]u8 = undefined;
    var reader = source.reader(io, &buffer);
    const length = try reader.interface.readSliceShort(&bytes);
    if (length == bytes.len) return error.ConfigTooLarge;
    try config.defaults(home);
    try config.parse(a, bytes[0..length]);
}

pub const Collection = struct {
    bytes: []const u8,
    exportedAccounts: usize,
    credentialStore: []const u8,
};
/// Reads only existing enabled grants, client files and the selected credential
/// store. No directories/files are created, no configuration is changed, and
/// no Google request is made. The returned bytes borrow `out`; callers wipe the
/// output and their allocator workspace after use. A valid output buffer is
/// cleared on failure; an invalid-sized buffer is rejected before any lookup.
pub fn collect(io: std.Io, a: std.mem.Allocator, home: []const u8, config_path: []const u8, grant_path: []const u8, out: []u8) !Collection {
    if (out.len == 0 or out.len > max_bundle_bytes) return error.InvalidBrowserConnectionBuffer;
    errdefer std.crypto.secureZero(u8, out);
    var config: Config = undefined;
    try loadConfig(io, a, home, config_path, &config);
    if (config.credential_store == .vault) return error.VaultExportRequiresOwner;
    const registry = try auth.load(io, a, grant_path);
    var clients: [3]oauth.DesktopClient = @splat(.{});
    defer for (&clients) |*client| client.wipe();
    var tokens: [3][4096]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&tokens));
    var accounts: [3]Account = undefined;
    var count: usize = 0;
    for (config.accounts[0..config.count]) |*account| {
        if (!account.enabled) continue;
        const grant = auth.find(&registry, account.address.slice()) orelse continue;
        if (!grant.enabled) continue;
        if (count == accounts.len) return error.TooManyAccounts;
        const client = &clients[count];
        try oauth.loadDesktop(io, grant.clientFile, client);
        if (!std.mem.eql(u8, client.client_id.slice(), grant.clientId)) return error.GrantClientMismatch;
        const token = (try credentials.lookupTerminal(io, config.credentials(), account.address.slice(), grant.clientId, grant.grantId, &tokens[count])) orelse return error.RefreshTokenMissing;
        accounts[count] = .{ .account = account.address.slice(), .clientId = client.client_id.slice(), .clientSecret = client.client_secret.slice(), .grantId = grant.grantId, .capabilities = grant.capabilities, .scopes = grant.scopes, .refreshToken = token };
        count += 1;
    }
    if (count == 0) return error.NoEnabledTerminalGrants;
    var writer: std.Io.Writer = .fixed(out);
    std.json.Stringify.value(.{ .format = "omagma-browser-connection", .version = @as(u8, 1), .accounts = accounts[0..count] }, .{}, &writer) catch return error.BrowserConnectionTooLarge;
    writer.writeByte('\n') catch return error.BrowserConnectionTooLarge;
    return .{ .bytes = writer.buffered(), .exportedAccounts = count, .credentialStore = @tagName(config.credential_store) };
}

pub fn run(io: std.Io, a: std.mem.Allocator, home: []const u8, config_path: []const u8, grant_path: []const u8, output_path: []const u8) !Result {
    var output_parent = try openOutputParent(io, a, output_path);
    defer output_parent.close(io);
    var output: [max_bundle_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    const collected = try collect(io, a, home, config_path, grant_path, &output);
    // Re-pin the canonical path after potentially interactive keyring lookup.
    var current_parent = try private.directory(io, std.fs.path.dirname(output_path).?, false);
    defer current_parent.close(io);
    if (!try private.sameDirectory(io, output_parent, current_parent)) return error.OutputDirectoryChanged;
    var atomic = try output_parent.createFileAtomic(io, std.fs.path.basename(output_path), .{ .permissions = .fromMode(0o600), .replace = false });
    defer atomic.deinit(io);
    try private.privateAtomicFile(io, atomic.file);
    try atomic.file.writeStreamingAll(io, collected.bytes);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| return if (err == error.PathAlreadyExists) error.OutputAlreadyExists else err;
    const published = try files.openRegular(io, a, output_parent, std.fs.path.basename(output_path));
    defer published.close(io);
    try private.privateFile(io, published);
    if ((try published.stat(io)).size != collected.bytes.len) return error.OutputVerificationFailed;
    return .{ .exportedAccounts = collected.exportedAccounts, .credentialStore = collected.credentialStore, .outputFile = output_path };
}
