//! Explicit local migration reads. Inventory parses public config/grant
//! metadata; only capture() reads the selected credential backend and clients.
//! The caller supplies a wiping arena, and never serializes Capture to IPC.
const std = @import("std");
const native = @import("../native_identity.zig");
const Config = @import("../config.zig").Config;
const auth = @import("auth.zig");
const oauth = @import("../oauth.zig");
const keyring = @import("../keyring.zig");
const private = @import("../keyring_file.zig");
const storage = @import("vault_storage.zig");
const journal = @import("vault_migration_journal.zig");
const j = @import("json.zig");
pub const Metadata = struct {
    config: *Config,
    registry: auth.Registry,
    registry_bytes: []const u8,
    source: journal.Source,
    pub fn load(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, source: journal.Source) !Metadata {
        const config = try a.create(Config);
        try config.defaults(env.get("HOME") orelse return error.HomeRequired);
        const config_bytes = try readPrivate(io, a, source.config, 128 * 1024, false);
        try config.parse(a, config_bytes.?);
        if (config.credential_store == .vault) return error.VaultMigrationSourceAlreadySealed;
        const registry_bytes = (try readPrivate(io, a, source.grants, 64 * 1024, true)) orelse if (source.allow_missing_grants) "{\"version\":1,\"accounts\":[]}" else return error.VaultMigrationGrantsRequired;
        const registry = try auth.parse(a, registry_bytes);
        for (registry.accounts) |entry| if (config.index(entry.account) == null) return error.VaultIdentityMismatch;
        if (config.client_file.len != 0) try checkClientPrivacy(io, config.client_file.slice());
        for (registry.accounts) |entry| try checkClientPrivacy(io, entry.clientFile);
        return .{ .config = config, .registry = registry, .registry_bytes = registry_bytes, .source = source };
    }
};
pub const Capture = struct {
    config: *Config,
    changes: []const native.Change,
    digest: [32]u8,
    token_count: usize,
};

pub fn capture(io: std.Io, a: std.mem.Allocator, metadata: Metadata) !Capture {
    const config = try a.create(Config);
    config.* = metadata.config.*;
    const selected = metadata.config.credentials();
    var changes: std.ArrayList(native.Change) = .empty;
    config.credential_store = .vault;
    config.runtime_provider = null;
    config.runtime_access_cache = null;
    config.credential_directory.wipe();
    try changes.append(a, .{ .kind = .configuration, .value = try config.snapshot(a) });
    try changes.append(a, .{ .kind = .grants, .value = metadata.registry_bytes });
    if (config.client_file.len != 0) try addClient(io, a, &changes, config.client_file.slice());
    for (metadata.registry.accounts) |entry| try addClient(io, a, &changes, entry.clientFile);
    var token_count: usize = 0;
    var token: [@import("../limits.zig").secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &token);
    for (config.accounts[0..config.count]) |*configured| {
        if (config.client_file.len != 0) {
            var desktop: oauth.DesktopClient = .{};
            defer desktop.wipe();
            try oauth.parseDesktop(clientBytes(changes.items, config.client_file.slice()).?, &desktop);
            if (try keyring.lookup(io, selected, configured.address.slice(), desktop.client_id.slice(), &token)) |value| {
                try changes.append(a, .{ .kind = .bar_token, .key = .{ .account = configured.address.slice(), .client = try a.dupe(u8, desktop.client_id.slice()) }, .value = try a.dupe(u8, value) });
                token_count += 1;
            }
            std.crypto.secureZero(u8, &token);
        }
        if (auth.find(&metadata.registry, configured.address.slice())) |grant| {
            var desktop: oauth.DesktopClient = .{};
            defer desktop.wipe();
            try oauth.parseDesktop(clientBytes(changes.items, grant.clientFile).?, &desktop);
            if (!std.mem.eql(u8, desktop.client_id.slice(), grant.clientId)) return error.VaultIdentityMismatch;
            if (try keyring.lookupTerminal(io, selected, grant.account, grant.clientId, grant.grantId, &token)) |value| {
                try changes.append(a, .{ .kind = .terminal_token, .key = .{ .account = grant.account, .client = grant.clientId, .grant = grant.grantId }, .value = try a.dupe(u8, value) });
                token_count += 1;
            } else if (configured.enabled and grant.enabled and !metadata.source.allow_missing_tokens) return error.VaultMigrationTokenRequired;
            std.crypto.secureZero(u8, &token);
        }
    }
    if (metadata.source.preferences) |path| if (try readPrivate(io, a, path, native.max_preferences_bytes, true)) |bytes| {
        // State.apply performs complete typed validation atomically with the
        // supplied config, clients, exact grants and bound tokens.
        try changes.append(a, .{ .kind = .preferences, .value = bytes });
    };
    return .{ .config = config, .changes = changes.items, .digest = try journal.digest(changes.items), .token_count = token_count };
}
fn clientBytes(changes: []const native.Change, path: []const u8) ?[]const u8 {
    for (changes) |entry| if (entry.kind == .desktop_client and std.mem.eql(u8, entry.key.name, path)) return entry.value;
    return null;
}
fn addClient(io: std.Io, a: std.mem.Allocator, changes: *std.ArrayList(native.Change), path: []const u8) !void {
    if (clientBytes(changes.items, path) != null) return;
    const bytes = (try readPrivate(io, a, path, 128 * 1024, false)).?;
    var desktop: oauth.DesktopClient = .{};
    defer desktop.wipe();
    try oauth.parseDesktop(bytes, &desktop);
    try changes.append(a, .{ .kind = .desktop_client, .key = .{ .name = path }, .value = bytes });
}
/// Inventory checks privacy and size without reading Desktop-client secrets.
fn checkClientPrivacy(io: std.Io, path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidVaultMigrationSource;
    const basename = std.fs.path.basename(path);
    if (path.len < 2 or path[0] != '/' or basename.len == 0 or basename.len > 255) return error.InvalidVaultMigrationSource;
    const parent = try private.directory(io, parent_path, false);
    defer parent.close(io);
    var name: [255:0]u8 = @splat(0);
    @memcpy(name[0..basename.len], basename);
    const file = try storage.openPrivate(io, parent, &name);
    defer file.close(io);
    if ((try file.stat(io)).size > 128 * 1024) return error.VaultMigrationSourceTooLarge;
}
fn readPrivate(io: std.Io, a: std.mem.Allocator, path: []const u8, limit: usize, optional: bool) !?[]u8 {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidVaultMigrationSource;
    const basename = std.fs.path.basename(path);
    if (path.len < 2 or path[0] != '/' or basename.len == 0 or basename.len > 255) return error.InvalidVaultMigrationSource;
    const parent = private.directory(io, parent_path, false) catch |err| if (optional and err == error.FileNotFound) return null else return err;
    defer parent.close(io);
    var name: [255:0]u8 = @splat(0);
    @memcpy(name[0..basename.len], basename);
    const file = storage.openPrivate(io, parent, &name) catch |err| if (optional and err == error.FileNotFound) return null else return err;
    defer file.close(io);
    if (!try file.tryLock(io, .shared)) return error.VaultMigrationSourceBusy;
    defer file.unlock(io);
    const before = try file.stat(io);
    if (before.size > limit) return error.VaultMigrationSourceTooLarge;
    const bytes = try a.alloc(u8, @intCast(before.size));
    errdefer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.VaultMigrationSourceChanged;
    const after = try file.stat(io);
    const current = try parent.statFile(io, basename, .{ .follow_symlinks = false });
    if (before.inode != after.inode or after.inode != current.inode or before.size != after.size or before.mtime.toNanoseconds() != after.mtime.toNanoseconds() or before.ctime.toNanoseconds() != after.ctime.toNanoseconds()) return error.VaultMigrationSourceChanged;
    try private.privateFile(io, file);
    return bytes;
}
