//! Synthetic identities only: no Google request, keychain or plaintext import.
const std = @import("std");
const catalog = @import("terminal/vault_catalog.zig");
const identity = @import("terminal/vault_identity.zig");
const storage = @import("terminal/vault_storage.zig");
const crypto = @import("terminal/vault_crypto.zig");
const vt = @import("terminal/vault_types.zig");
const header = @import("terminal/vault_header.zig");
const Config = @import("config.zig").Config;
const keyring = @import("keyring.zig");
const oauth = @import("oauth.zig");
const auth = @import("terminal/auth.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;
const a = std.testing.allocator;
const account = "identity-one@example.test";
const other = "identity-two@example.test";
const terminal_client = "fictional-terminal.apps.googleusercontent.com";
const bar_client = "fictional-bar.apps.googleusercontent.com";
const token = "SYNTHETIC-REFRESH-TOKEN-NEVER-REAL";
const bar_token = "SYNTHETIC-BAR-TOKEN-NEVER-REAL";
const terminal_json = "{\"installed\":{\"client_id\":\"fictional-terminal.apps.googleusercontent.com\",\"client_secret\":\"SYNTHETIC-TERMINAL-SECRET\"}}";
const bar_json = "{\"installed\":{\"client_id\":\"fictional-bar.apps.googleusercontent.com\",\"client_secret\":\"SYNTHETIC-BAR-SECRET\"}}";
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,
    key: vt.DataKey,
    workspace: vt.StreamWorkspace = undefined,
    saved: header.Header,
    owner: catalog.Owner,
    state: identity.State,
    config: *Config,
    fn create() !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const base = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(base);
        self.path = try std.fmt.allocPrint(a, "{s}/records", .{base});
        errdefer a.free(self.path);
        self.key = try crypto.createDataKey(io);
        errdefer self.key.wipe();
        self.saved = .{ .vault_id = self.key.vault_id, .key_id = self.key.key_id, .root_record = try storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
        self.owner = try catalog.Owner.create(io, self.path, self.saved, &self.key, &self.workspace);
        errdefer self.owner.close();
        try self.owner.addAccount(account, "synthetic-index-one", 4096);
        try self.owner.addAccount(other, "synthetic-index-two", 4096);
        self.config = try a.create(Config);
        errdefer a.destroy(self.config);
        try self.config.defaults("/nonexistent/synthetic-vault-home");
        self.config.credential_store = .vault;
        self.config.count = 2;
        try self.config.accounts[0].address.set(account);
        try self.config.accounts[1].address.set(other);
        try self.config.accounts[0].sender_name.set("Synthetic Sender");
        try self.config.accounts[0].signature.set("Synthetic signature\nSecond line");
        try self.config.client_file.set("bar-client");
        self.state = try identity.State.create(&self.owner, a, self.config);
        errdefer self.state.deinit();
        try self.state.loadConfig(self.config);
        return self;
    }
    fn destroy(self: *Fixture) void {
        self.state.deinit();
        self.owner.close();
        self.key.wipe();
        self.workspace.wipe();
        std.crypto.secureZero(u8, std.mem.asBytes(self.config));
        a.destroy(self.config);
        a.free(self.path);
        self.tmp.cleanup();
        a.destroy(self);
    }
    fn reopen(self: *Fixture) !void {
        self.state.deinit();
        self.owner.close();
        self.owner = try catalog.Owner.open(io, self.path, self.saved, &self.key, &self.workspace);
        self.state = try identity.State.open(&self.owner, a);
        try self.state.loadConfig(self.config);
    }
    fn provision(self: *Fixture, arena: std.mem.Allocator) ![64]u8 {
        const scopes = try auth.scopesFor(arena, &.{ "mail-read", "mail-send" });
        const grant = auth.grantIdentity(scopes);
        var rows = [_]auth.Grant{.{ .account = account, .clientFile = "terminal-client", .clientId = terminal_client, .grantId = &grant, .capabilities = &.{ "mail-read", "mail-send" }, .scopes = scopes }};
        const registry = try j.encodeAlloc(arena, auth.Registry{ .accounts = &rows }, .{});
        try self.state.apply(&.{
            .{ .kind = .desktop_client, .key = .{ .name = "bar-client" }, .value = bar_json },
            .{ .kind = .desktop_client, .key = .{ .name = "terminal-client" }, .value = terminal_json },
            .{ .kind = .grants, .value = registry },
            .{ .kind = .bar_token, .key = .{ .account = account, .client = bar_client }, .value = bar_token },
            .{ .kind = .terminal_token, .key = .{ .account = account, .client = terminal_client, .grant = &grant }, .value = token },
        });
        return grant;
    }
};

test "vault identity: reopen preserves full config and exact bar terminal account client grant boundaries" {
    std.debug.print("identity compiler={s} optimize={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    const f = try Fixture.create();
    defer f.destroy();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const grant = try f.provision(arena.allocator());
    const preferences = "{\"schema\":1,\"searchHistory\":[{\"account\":\"identity-one@example.test\",\"query\":\"SYNTHETIC-PRIVATE-SEARCH\",\"mode\":\"server\"}]}";
    try f.state.apply(&.{.{ .kind = .preferences, .value = preferences }});
    try f.reopen();
    try std.testing.expectEqualStrings(preferences, (try f.state.provider().read(.preferences, .{})).?);
    try std.testing.expectEqualStrings("Synthetic Sender", f.config.accounts[0].sender_name.slice());
    try std.testing.expectEqualStrings("Synthetic signature\nSecond line", f.config.accounts[0].signature.slice());
    try std.testing.expectEqualStrings("Profile 3", f.config.accounts[0].profile.slice());
    const snapshot = try f.config.snapshot(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "runtime_provider") == null);
    var output: [@import("limits.zig").secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    const settings = f.config.credentials();
    try std.testing.expectEqualStrings(token, (try keyring.lookupTerminal(io, settings, account, terminal_client, &grant, &output)).?);
    try std.testing.expectEqualStrings(bar_token, (try keyring.lookupAutomatic(io, settings, account, bar_client, &output)).?);
    try std.testing.expect((try keyring.lookup(io, settings, account, terminal_client, &output)) == null);
    try std.testing.expect((try keyring.lookupTerminal(io, settings, other, terminal_client, &grant, &output)) == null);
    var wrong = grant;
    wrong[0] = if (wrong[0] == 'a') 'b' else 'a';
    try std.testing.expect((try keyring.lookupTerminal(io, settings, account, terminal_client, &wrong, &output)) == null);
    var desktop: oauth.DesktopClient = .{};
    defer desktop.wipe();
    try oauth.loadDesktopWithSettings(io, "terminal-client", &desktop, settings);
    try std.testing.expectEqualStrings(terminal_client, desktop.client_id.slice());
    try std.testing.expectError(error.OAuthClientRequired, oauth.loadDesktopWithSettings(io, "/nonexistent/plaintext-client.json", &desktop, settings));
    const registry = try auth.loadConfigured(io, arena.allocator(), f.config, "/nonexistent/plaintext-grants.json");
    try std.testing.expect(auth.find(&registry, account).?.permits("mail-send"));
    var iterator = f.owner.directory.dir.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, "identity-one") == null);
        if (entry.kind != .file or std.mem.eql(u8, entry.name, ".vault-lock")) continue;
        const bytes = try f.owner.directory.dir.readFileAlloc(io, entry.name, arena.allocator(), .limited(512 * 1024));
        for ([_][]const u8{ account, token, bar_token, "SYNTHETIC-TERMINAL-SECRET", "Synthetic Sender", "SYNTHETIC-PRIVATE-SEARCH" }) |private| try std.testing.expect(std.mem.indexOf(u8, bytes, private) == null);
    }
}

test "vault identity: absent runtime provider never falls through to files or native keychain" {
    var output: [@import("limits.zig").secret]u8 = @splat(0xa5);
    const settings: keyring.Settings = .{ .kind = .vault, .directory = "/nonexistent" };
    try std.testing.expectError(error.VaultLocked, keyring.lookupAutomatic(io, settings, account, bar_client, &output));
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const grant = auth.grantIdentity(&.{oauth.readonly_scope});
    try std.testing.expectError(error.VaultLocked, keyring.storeTerminal(io, settings, account, terminal_client, &grant, token));
    try std.testing.expectError(error.VaultLocked, keyring.clear(io, settings, account));
    var desktop: oauth.DesktopClient = .{};
    try std.testing.expectError(error.VaultLocked, oauth.loadDesktopWithSettings(io, "/nonexistent/client.json", &desktop, settings));
}

test "vault identity: failed revoke keeps both grant and token across restart; successful revoke commits both" {
    const f = try Fixture.create();
    defer f.destroy();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const grant = try f.provision(arena.allocator());
    const orphan = try storage.Handle.create(io);
    const file = try f.owner.directory.dir.createFile(io, &orphan.filename(), .{ .permissions = .fromMode(0o600), .exclusive = true });
    try file.setLength(io, catalog.Owner.identity_disk_limit);
    file.close(io);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    const request = try j.value(arena.allocator(), .{ .cmd = "auth.revoke", .account = account });
    try std.testing.expectError(error.DiskQuotaExceeded, auth.run(io, arena.allocator(), f.config, &env, request));
    try f.reopen();
    var output: [@import("limits.zig").secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    try std.testing.expectEqualStrings(token, (try keyring.lookupTerminal(io, f.config.credentials(), account, terminal_client, &grant, &output)).?);
    var registry = try auth.loadConfigured(io, arena.allocator(), f.config, "");
    try std.testing.expect(auth.find(&registry, account) != null);
    try f.owner.directory.dir.deleteFile(io, &orphan.filename());
    _ = try auth.run(io, arena.allocator(), f.config, &env, request);
    try f.reopen();
    registry = try auth.loadConfigured(io, arena.allocator(), f.config, "");
    try std.testing.expect(auth.find(&registry, account) == null);
    try std.testing.expect((try keyring.lookupTerminal(io, f.config.credentials(), account, terminal_client, &grant, &output)) == null);
    try std.testing.expectEqualStrings(bar_token, (try keyring.lookup(io, f.config.credentials(), account, bar_client, &output)).?);
}

test "vault identity: corrupt current record refuses unlock rather than using retired credentials" {
    const f = try Fixture.create();
    defer f.destroy();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try f.provision(arena.allocator());
    f.state.deinit();
    const name = f.owner.identity.?.filename();
    const file = try f.owner.directory.dir.openFile(io, &name, .{ .mode = .read_write });
    const position = (try file.stat(io)).size - 1;
    var byte: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &byte, position);
    byte[0] ^= 1;
    try file.writePositionalAll(io, &byte, position);
    file.close(io);
    try std.testing.expectError(error.VaultAuthenticationFailed, identity.State.open(&f.owner, a));
}

test "vault identity: full existing search capacity survives encrypted preferences without truncation" {
    const f = try Fixture.create();
    defer f.destroy();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const prefs = @import("terminal/preferences.zig");
    const value = try arena.allocator().create(prefs.Preferences);
    value.* = .{};
    var query: [4096]u8 = undefined;
    for ([_][]const u8{ account, other }) |address| {
        for (0..8) |index| {
            @memset(&query, @as(u8, 'a') + @as(u8, @intCast(index)));
            try prefs.rememberSearch(value, address, &query, .server, null);
            var name_buffer: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "saved-{d}", .{index});
            try prefs.rememberSearch(value, address, &query, .cache, name);
        }
    }
    const encoded = try prefs.encode(arena.allocator(), value);
    try std.testing.expect(encoded.len > 128 * 1024);
    try std.testing.expect(encoded.len < @import("native_identity.zig").max_preferences_bytes);
    try f.state.apply(&.{.{ .kind = .preferences, .value = encoded }});
    try f.reopen();
    try std.testing.expectEqualStrings(encoded, (try f.state.provider().read(.preferences, .{})).?);
    const oversize = try arena.allocator().alloc(u8, @import("native_identity.zig").max_preferences_bytes + 1);
    @memset(oversize, 'x');
    try std.testing.expectError(error.UiPreferencesTooLarge, f.state.apply(&.{.{ .kind = .preferences, .value = oversize }}));
    try std.testing.expectEqualStrings(encoded, (try f.state.provider().read(.preferences, .{})).?);
}

fn rootEntries(owner: *catalog.Owner) !usize {
    var count: usize = 0;
    var iterator = owner.directory.dir.iterate();
    while (try iterator.next(io)) |_| count += 1;
    return count;
}
fn orphanRecord(f: *Fixture, kind: vt.RecordKind, account_binding: []const u8, bytes: []const u8) !storage.Handle {
    const handle = try storage.Handle.create(io);
    var writer: @import("terminal/vault_stream.zig").Writer = undefined;
    try writer.init(&f.owner.directory, &f.key, .{ .account = account_binding, .kind = kind, .handle = handle }, bytes.len, &f.workspace, false, .{});
    defer writer.deinit();
    try writer.interface.writeAll(bytes);
    try writer.finish();
    return handle;
}
test "vault identity: repeated catalog contention leaves no orphan and later save succeeds" {
    const f = try Fixture.create();
    defer f.destroy();
    const count = try rootEntries(&f.owner);
    const current = f.owner.identity.?;
    var pinned = try f.owner.directory.reader(f.owner.root.handle);
    defer pinned.close();
    const preferences = "{\"schema\":1,\"searchHistory\":[]}";
    for (0..4) |_| {
        try std.testing.expectError(error.VaultBusy, f.state.apply(&.{.{ .kind = .preferences, .value = preferences }}));
        try std.testing.expectEqual(count, try rootEntries(&f.owner));
        try std.testing.expectEqualSlices(u8, &current.bytes, &f.owner.identity.?.bytes);
        try std.testing.expect((try f.state.provider().read(.preferences, .{})) == null);
    }
    pinned.close();
    try f.state.apply(&.{.{ .kind = .preferences, .value = preferences }});
    try f.reopen();
    try std.testing.expectEqual(count, try rootEntries(&f.owner));
    try std.testing.expectEqualStrings(preferences, (try f.state.provider().read(.preferences, .{})).?);
}
test "vault identity: reopen sweeps authenticated identity leftovers but preserves unknown records" {
    const f = try Fixture.create();
    defer f.destroy();
    const bytes = try f.owner.readIdentity(a);
    defer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    const orphan = try orphanRecord(f, .identity, "omagma-vault-identity-v1", bytes);
    const unknown = try orphanRecord(f, .mail_body, account, "synthetic unknown record");
    try f.reopen();
    try std.testing.expectError(error.FileNotFound, f.owner.directory.dir.statFile(io, &orphan.filename(), .{}));
    _ = try f.owner.directory.dir.statFile(io, &unknown.filename(), .{});
    try std.testing.expectError(error.VaultRecoveryRequired, f.state.apply(&.{.{ .kind = .preferences, .value = "{}" }}));
    try std.testing.expect((try f.state.provider().read(.configuration, .{})) != null);
}
test "vault identity: orphan recovery authenticates every current account index before deleting" {
    const f = try Fixture.create();
    defer f.destroy();
    const bytes = try f.owner.readIdentity(a);
    defer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    const orphan = try orphanRecord(f, .identity, "omagma-vault-identity-v1", bytes);
    var selected = try f.owner.openAccount(account);
    const file = try selected.directory.dir.openFile(io, &selected.entry.index.filename(), .{ .mode = .read_write });
    const position = (try file.stat(io)).size - 1;
    var byte: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &byte, position);
    byte[0] ^= 1;
    try file.writePositionalAll(io, &byte, position);
    file.close(io);
    selected.close();
    f.state.deinit();
    f.owner.close();
    try std.testing.expectError(error.VaultAuthenticationFailed, catalog.Owner.open(io, f.path, f.saved, &f.key, &f.workspace));
    var dir = try std.Io.Dir.cwd().openDir(io, f.path, .{});
    defer dir.close(io);
    _ = try dir.statFile(io, &orphan.filename(), .{});
}
test "vault identity: onboarding publishes account index and matching identity together" {
    const f = try Fixture.create();
    defer f.destroy();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const next = try arena.allocator().create(Config);
    next.* = f.config.*;
    next.count = 3;
    const third = "identity-three@example.test";
    try next.accounts[2].address.set(third);
    try next.accounts[2].profile.set("Profile 9");
    const config_bytes = try next.snapshot(arena.allocator());
    const initial = try @import("terminal/store.zig").Store.initialVaultIndex(arena.allocator(), third, .{ .fixtures = true, .disk_limit = 65536 });
    const additions = [_]catalog.InitialAccount{.{ .account = third, .initial_index = initial, .disk_limit = 65536 }};
    try std.testing.expectError(error.InvalidVaultIdentity, f.state.apply(&.{.{ .kind = .configuration, .value = config_bytes }}));
    try std.testing.expectError(error.VaultAtomicIdentityRequired, f.owner.addAccount(third, initial, 65536));
    const count = try rootEntries(&f.owner);
    var pinned = try f.owner.directory.reader(f.owner.root.handle);
    defer pinned.close();
    try std.testing.expectError(error.VaultBusy, f.state.applyWithAccounts(&.{.{ .kind = .configuration, .value = config_bytes }}, &additions));
    try std.testing.expectEqual(@as(usize, 2), f.owner.count);
    try std.testing.expectEqual(count, try rootEntries(&f.owner));
    pinned.close();
    try f.reopen();
    try std.testing.expectEqual(@as(usize, 2), f.config.count);
    try f.state.applyWithAccounts(&.{.{ .kind = .configuration, .value = config_bytes }}, &additions);
    try f.reopen();
    try std.testing.expectEqual(@as(usize, 3), f.config.count);
    var selected = try f.owner.openAccount(third);
    defer selected.close();
    try selected.claim();
    defer selected.release();
    const actual = try selected.read(a, .cache_index, selected.entry.index, 4096);
    defer a.free(actual);
    try std.testing.expectEqualStrings(initial, actual);
}
