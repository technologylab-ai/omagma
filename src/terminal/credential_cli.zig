//! Installation-wide credential selection, independent of mail/cache startup.
const std = @import("std");
const b = @import("../bounded.zig");
const Config = @import("../config.zig").Config;
const keyring = @import("../keyring.zig");
const file = @import("../keyring_file.zig");
const oauth = @import("../oauth.zig");
const auth = @import("auth.zig");
const j = @import("json.zig");
const Record = struct {
    account: []const u8,
    terminal: bool,
    client: b.Text(4096) = .{},
    grant: b.Text(64) = .{},
    secret: b.Text(4096) = .{},
    present: bool = false,
};
pub const Result = struct {
    ok: bool = true,
    credentialStore: []const u8,
    credentialDirectory: []const u8,
    copiedCredentials: usize = 0,
    sourceCopiesRetained: bool = false,
    restartRequired: bool = false,
};
fn loadConfig(io: std.Io, a: std.mem.Allocator, home: []const u8, path: []const u8, config: *Config) ![]u8 {
    const existing = try @import("files.zig").openRegular(io, a, std.Io.Dir.cwd(), path);
    defer existing.close(io);
    try file.privateFile(io, existing);
    var buffer: [4096]u8 = undefined;
    var reader = existing.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .limited(16 * 1024 - 1));
    try config.defaults(home);
    try config.parse(a, bytes);
    return bytes;
}
fn lookup(io: std.Io, settings: keyring.Settings, record: *const Record, out: []u8) !?[]const u8 {
    if (record.client.len == 0) return null;
    return if (record.terminal) keyring.lookupTerminal(io, settings, record.account, record.client.slice(), record.grant.slice(), out) else keyring.lookup(io, settings, record.account, record.client.slice(), out);
}
fn clear(io: std.Io, settings: keyring.Settings, record: *const Record) !void {
    if (record.terminal) try keyring.clearTerminal(io, settings, record.account) else try keyring.clear(io, settings, record.account);
}
fn save(io: std.Io, settings: keyring.Settings, record: *const Record) !void {
    if (record.terminal) try keyring.storeTerminal(io, settings, record.account, record.client.slice(), record.grant.slice(), record.secret.slice()) else try keyring.store(io, settings, record.account, record.client.slice(), record.secret.slice());
}

pub fn migrate(io: std.Io, a: std.mem.Allocator, home: []const u8, config_path: []const u8, grant_path: []const u8, target: keyring.Settings) !Result {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, config_path, a);
    const parent_path = std.fs.path.dirname(absolute) orelse return error.InvalidConfigPath;
    var parent = try file.directory(io, parent_path, false);
    defer parent.close(io);
    const lock = try @import("../native_file.zig").openAt(io, parent, "credential-migration.lock", .{ .read_write = true, .create = true, .mode = 0o600 });
    defer lock.close(io);
    try file.privateFile(io, lock);
    if (!try lock.tryLock(io, .exclusive)) return error.CredentialMigrationBusy;
    defer lock.unlock(io);
    const config = try a.create(Config);
    const original = try loadConfig(io, a, home, config_path, config);
    const source = config.credentials();
    var same = source.kind == .keyring and target.kind == .keyring;
    if (target.kind == .file) {
        var destination = try file.directory(io, target.directory, true);
        defer destination.close(io);
        if (source.kind == .file) {
            const active: ?std.Io.Dir = file.directory(io, source.directory, false) catch |err| if (err == error.FileNotFound) null else return err;
            if (active) |opened| {
                defer opened.close(io);
                same = try file.sameDirectory(io, opened, destination);
            }
        }
    }
    if (same) return .{ .credentialStore = @tagName(source.kind), .credentialDirectory = source.directory };
    const registry = try auth.load(io, a, grant_path);
    const records = try a.alloc(Record, config.count * 2);
    for (records) |*record| record.* = .{ .account = "", .terminal = false };
    defer for (records) |*record| record.secret.wipe();
    var bar_client: oauth.DesktopClient = .{};
    defer bar_client.wipe();
    if (config.client_file.len > 0) try oauth.loadDesktop(io, config.client_file.slice(), &bar_client);
    var secret: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    for (config.accounts[0..config.count], 0..) |*account, index| {
        records[index * 2].account = account.address.slice();
        try records[index * 2].client.set(bar_client.client_id.slice());
        const terminal = &records[index * 2 + 1];
        terminal.account = account.address.slice();
        terminal.terminal = true;
        if (auth.find(&registry, account.address.slice())) |grant| {
            var client: oauth.DesktopClient = .{};
            defer client.wipe();
            try oauth.loadDesktop(io, grant.clientFile, &client);
            if (!std.mem.eql(u8, client.client_id.slice(), grant.clientId)) return error.GrantClientMismatch;
            try terminal.client.set(grant.clientId);
            try terminal.grant.set(grant.grantId);
        }
    }
    // Read every authoritative source first; absence and failure are distinct.
    for (records) |*record| {
        if (try lookup(io, source, record, &secret)) |value| {
            try record.secret.set(value);
            record.present = true;
        }
        std.crypto.secureZero(u8, &secret);
    }
    var copied: usize = 0;
    for (records) |*record| {
        // Also clear variants missing from the active grant registry, so a
        // previous local revoke cannot be resurrected by retained backups.
        try clear(io, target, record);
        if (record.present) {
            try save(io, target, record);
            copied += 1;
        }
        const value = try lookup(io, target, record, &secret);
        if (record.present) {
            if (value == null or !std.mem.eql(u8, value.?, record.secret.slice())) return error.CredentialMigrationVerificationFailed;
        } else if (value != null) return error.CredentialMigrationVerificationFailed;
        std.crypto.secureZero(u8, &secret);
    }
    // Do not overwrite a simultaneous user edit to configuration.
    const current = try @import("files.zig").openRegular(io, a, parent, std.fs.path.basename(absolute));
    defer current.close(io);
    try file.privateFile(io, current);
    var buffer: [4096]u8 = undefined;
    var reader = current.reader(io, &buffer);
    const latest = try reader.interface.allocRemaining(a, .limited(16 * 1024 - 1));
    if (!std.mem.eql(u8, original, latest)) return error.CredentialConfigChanged;
    var document = try std.json.parseFromSliceLeaky(j.Value, a, original, .{ .duplicate_field_behavior = .@"error" });
    try document.object.put(a, "credentialStore", .{ .string = @tagName(target.kind) });
    if (target.kind == .file) try document.object.put(a, "credentialDirectory", .{ .string = target.directory });
    const bytes = try std.json.Stringify.valueAlloc(a, document, .{});
    if (bytes.len >= 16 * 1024) return error.ConfigTooLarge;
    var atomic = try parent.createFileAtomic(io, std.fs.path.basename(absolute), .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try file.privateFile(io, atomic.file);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    return .{ .credentialStore = @tagName(target.kind), .credentialDirectory = target.directory, .copiedCredentials = copied, .sourceCopiesRetained = true, .restartRequired = true };
}
pub fn run(init: std.process.Init, io: std.Io, args: *std.process.Args.Iterator) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const verb = args.next() orelse "status";
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h")) return help(io);
    if (!std.mem.eql(u8, verb, "status") and !std.mem.eql(u8, verb, "migrate")) return error.UnknownCommand;
    var path: ?[]const u8 = null;
    var grants: ?[]const u8 = null;
    var destination: ?keyring.Kind = null;
    var directory_path: ?[]const u8 = null;
    var json = false;
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--help") or std.mem.eql(u8, option, "-h")) return help(io);
        if (std.mem.eql(u8, option, "--json")) {
            json = true;
            continue;
        }
        const value = args.next() orelse return error.ValueRequired;
        if (std.mem.eql(u8, option, "--config")) path = value else if (std.mem.eql(u8, option, "--grant-file")) grants = value else if (std.mem.eql(u8, option, "--directory")) directory_path = value else if (std.mem.eql(u8, option, "--to")) destination = std.meta.stringToEnum(keyring.Kind, value) orelse return error.InvalidCredentialStore else return error.UnknownOption;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    const config_path = path orelse try std.fmt.allocPrint(a, "{s}/omagma/config.json", .{init.environ_map.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{home})});
    var result: Result = undefined;
    if (std.mem.eql(u8, verb, "status")) {
        if (destination != null or directory_path != null) return error.InvalidCredentialOption;
        const config = try a.create(Config);
        _ = try loadConfig(io, a, home, config_path, config);
        result = .{ .credentialStore = @tagName(config.credential_store), .credentialDirectory = config.credential_directory.slice() };
    } else {
        const kind = destination orelse return error.CredentialStoreRequired;
        if (kind == .keyring and directory_path != null) return error.InvalidCredentialOption;
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, config_path, a);
        const selected = if (kind == .file) directory_path orelse try std.fmt.allocPrint(a, "{s}/credentials", .{std.fs.path.dirname(absolute) orelse return error.InvalidConfigPath}) else "";
        result = try migrate(io, a, home, config_path, grants orelse try auth.defaultFile(a, init.environ_map), .{ .kind = kind, .directory = selected });
    }
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    if (json) try std.json.Stringify.value(result, .{}, &writer.interface) else {
        try writer.interface.print("Credential store: {s}\n", .{result.credentialStore});
        if (std.mem.eql(u8, result.credentialStore, "file")) try writer.interface.print("Private directory: {s}\n", .{result.credentialDirectory});
        if (result.restartRequired) try writer.interface.print("Copied {d} credentials; source copies retained. Restart running Omagma sessions.\n", .{result.copiedCredentials});
    }
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
pub fn help(io: std.Io) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll("Credentials (no mail/network operation)\n  omagma credentials status [--config FILE] [--json]\n  omagma credentials migrate --to file|keyring [--directory ABS] [--config FILE] [--grant-file FILE] [--json]\nFile mode uses unencrypted owner-only credentials. Migration copies and verifies existing credentials without Google consent, then changes configuration; source copies remain. Restart running sessions afterward.\n");
    try writer.interface.flush();
}

fn testJson(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    const target = try dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
    defer target.close(io);
    try target.writeStreamingAll(io, bytes);
}
test "file credentials: migration reconciles revoked grants and does not resurrect retained copies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDir(io, "private", .fromMode(0o700));
    var dir = try tmp.dir.openDir(io, "private", .{});
    defer dir.close(io);
    const base = try dir.realPathFileAlloc(io, ".", a);
    const config_path = try std.fmt.allocPrint(a, "{s}/config.json", .{base});
    const grants_path = try std.fmt.allocPrint(a, "{s}/grants.json", .{base});
    const client_path = try std.fmt.allocPrint(a, "{s}/client.json", .{base});
    const first: keyring.Settings = .{ .kind = .file, .directory = try std.fmt.allocPrint(a, "{s}/first", .{base}) };
    const second: keyring.Settings = .{ .kind = .file, .directory = try std.fmt.allocPrint(a, "{s}/second", .{base}) };
    const account = "a@example.test";
    const client_id = "fixture-client.apps.googleusercontent.com";
    const capabilities: []const []const u8 = &.{ "mail-read", "mail-send" };
    const scopes = try auth.scopesFor(a, capabilities);
    const grant_id = auth.grantIdentity(scopes);
    try testJson(io, a, dir, "client.json", .{ .installed = .{ .client_id = client_id, .client_secret = "fixture-client-secret" } });
    try testJson(io, a, dir, "config.json", .{ .credentialStore = "file", .credentialDirectory = first.directory, .accounts = .{.{ .address = account, .profile = "Profile 1" }} });
    var grants = [_]auth.Grant{.{ .account = account, .clientFile = client_path, .clientId = client_id, .grantId = &grant_id, .capabilities = capabilities, .scopes = scopes }};
    try testJson(io, a, dir, "grants.json", auth.Registry{ .accounts = &grants });
    try keyring.storeTerminal(io, first, account, client_id, &grant_id, "synthetic-original");
    // A previously retained destination bar slot has no authoritative source.
    try keyring.store(io, second, account, client_id, "stale-readonly");
    const copied = try migrate(io, a, base, config_path, grants_path, second);
    try std.testing.expectEqual(@as(usize, 1), copied.copiedCredentials);
    try std.testing.expect(copied.restartRequired and copied.sourceCopiesRetained);
    var out: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &out);
    try std.testing.expectEqualStrings("synthetic-original", (try keyring.lookupTerminal(io, second, account, client_id, &grant_id, &out)).?);
    try std.testing.expectEqualStrings("synthetic-original", (try keyring.lookupTerminal(io, first, account, client_id, &grant_id, &out)).?);
    try std.testing.expect(try keyring.lookup(io, second, account, client_id, &out) == null);
    const config = try a.create(Config);
    _ = try loadConfig(io, a, base, config_path, config);
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", base);
    const revoke = try auth.run(io, a, config, &env, try j.value(a, .{ .cmd = "auth.revoke", .account = account, .grantFile = grants_path }));
    try std.testing.expect(try j.boolean(revoke, "cleared", false));
    try std.testing.expect(try keyring.lookupTerminal(io, second, account, client_id, &grant_id, &out) == null);
    // Switching back reconciles the empty active registry, rather than exposing
    // the retained first store's obsolete terminal token again.
    const back = try migrate(io, a, base, config_path, grants_path, first);
    try std.testing.expectEqual(@as(usize, 0), back.copiedCredentials);
    try std.testing.expect(try keyring.lookupTerminal(io, first, account, client_id, &grant_id, &out) == null);
    // Lexically different spellings of one directory never clear active data.
    try keyring.store(io, first, account, client_id, "active-alias-check");
    const alias = try std.fmt.allocPrint(a, "{s}//", .{first.directory});
    const unchanged = try migrate(io, a, base, config_path, grants_path, .{ .kind = .file, .directory = alias });
    try std.testing.expect(!unchanged.restartRequired);
    try std.testing.expectEqualStrings("active-alias-check", (try keyring.lookup(io, first, account, client_id, &out)).?);
    const case_alias = try std.fmt.allocPrint(a, "{s}/First", .{base});
    if (file.directory(io, case_alias, false)) |alias_dir| {
        defer alias_dir.close(io);
        var active_dir = try file.directory(io, first.directory, false);
        defer active_dir.close(io);
        if (try file.sameDirectory(io, active_dir, alias_dir)) {
            const alias_result = try migrate(io, a, base, config_path, grants_path, .{ .kind = .file, .directory = case_alias });
            try std.testing.expect(!alias_result.restartRequired);
            try std.testing.expectEqualStrings("active-alias-check", (try keyring.lookup(io, first, account, client_id, &out)).?);
        }
    } else |err| if (err != error.FileNotFound) return err;
}

test "file credentials: failed migration retains selected store and exact configuration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDir(io, "private", .fromMode(0o700));
    var dir = try tmp.dir.openDir(io, "private", .{});
    defer dir.close(io);
    const base = try dir.realPathFileAlloc(io, ".", a);
    const config_path = try std.fmt.allocPrint(a, "{s}/config.json", .{base});
    const grants_path = try std.fmt.allocPrint(a, "{s}/grants.json", .{base});
    const source: keyring.Settings = .{ .kind = .file, .directory = try std.fmt.allocPrint(a, "{s}/source", .{base}) };
    const account = "a@example.test";
    try testJson(io, a, dir, "config.json", .{ .credentialStore = "file", .credentialDirectory = source.directory, .accounts = .{.{ .address = account, .profile = "Profile 1" }} });
    try testJson(io, a, dir, "grants.json", auth.Registry{});
    try keyring.store(io, source, account, "fixture-client", "active-source-value");
    const before = try dir.readFileAlloc(io, "config.json", a, .limited(16384));
    try dir.createDir(io, "unsafe", .fromMode(0o755));
    const unsafe_dir = try dir.openDir(io, "unsafe", .{ .iterate = true });
    defer unsafe_dir.close(io);
    try (std.Io.File{ .handle = unsafe_dir.handle, .flags = .{ .nonblocking = true } }).setPermissions(io, .fromMode(0o755));
    const target = try std.fmt.allocPrint(a, "{s}/unsafe", .{base});
    try std.testing.expectError(error.UnsafeCredentialPermissions, migrate(io, a, base, config_path, grants_path, .{ .kind = .file, .directory = target }));
    const after = try dir.readFileAlloc(io, "config.json", a, .limited(16384));
    try std.testing.expectEqualStrings(before, after);
    var out: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &out);
    try std.testing.expectEqualStrings("active-source-value", (try keyring.lookup(io, source, account, "fixture-client", &out)).?);
    const held = try @import("../native_file.zig").openAt(io, dir, "credential-migration.lock", .{ .read_write = true, .create = true, .mode = 0o600 });
    defer held.close(io);
    try held.lock(io, .exclusive);
    defer held.unlock(io);
    try std.testing.expectError(error.CredentialMigrationBusy, migrate(io, a, base, config_path, grants_path, source));
}

test "file credentials: three account migration keeps distinct literal values and unrelated grants" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDir(io, "private", .fromMode(0o700));
    var dir = try tmp.dir.openDir(io, "private", .{});
    defer dir.close(io);
    const base = try dir.realPathFileAlloc(io, ".", a);
    const cfg = try std.fmt.allocPrint(a, "{s}/config.json", .{base});
    const registry_path = try std.fmt.allocPrint(a, "{s}/grants.json", .{base});
    const client_path = try std.fmt.allocPrint(a, "{s}/client.json", .{base});
    const first: keyring.Settings = .{ .kind = .file, .directory = try std.fmt.allocPrint(a, "{s}/before", .{base}) };
    const next: keyring.Settings = .{ .kind = .file, .directory = try std.fmt.allocPrint(a, "{s}/after", .{base}) };
    const accounts = [_][]const u8{ "one@example.test", "two@example.test", "three@example.test" };
    const tokens = [_][]const u8{ "literal-first-credential", "different-second-value", "third-account-only" };
    const client_id = "fixture-client.apps.googleusercontent.com";
    const capabilities: []const []const u8 = &.{ "mail-read", "mail-send" };
    const scopes = try auth.scopesFor(a, capabilities);
    const grant_id = auth.grantIdentity(scopes);
    var grants: [3]auth.Grant = undefined;
    for (accounts, tokens, &grants) |account, token, *grant| {
        grant.* = .{ .account = account, .clientFile = client_path, .clientId = client_id, .grantId = &grant_id, .capabilities = capabilities, .scopes = scopes };
        try keyring.storeTerminal(io, first, account, client_id, &grant_id, token);
    }
    try testJson(io, a, dir, "client.json", .{ .installed = .{ .client_id = client_id, .client_secret = "fixture-client-secret" } });
    try testJson(io, a, dir, "config.json", .{ .credentialStore = "file", .credentialDirectory = first.directory, .accounts = .{
        .{ .address = accounts[0], .profile = "Profile 1" }, .{ .address = accounts[1], .profile = "Profile 2" }, .{ .address = accounts[2], .profile = "Profile 3" },
    } });
    try testJson(io, a, dir, "grants.json", auth.Registry{ .accounts = &grants });
    const copied = try migrate(io, a, base, cfg, registry_path, next);
    try std.testing.expectEqual(@as(usize, 3), copied.copiedCredentials);
    var output: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    for (accounts, tokens) |account, token| {
        try std.testing.expectEqualStrings(token, (try keyring.lookupTerminal(io, next, account, client_id, &grant_id, &output)).?);
        try std.testing.expectEqualStrings(token, (try keyring.lookupTerminal(io, first, account, client_id, &grant_id, &output)).?);
    }
}
