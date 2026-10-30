const std = @import("std");
const b = @import("../bounded.zig");
const oauth = @import("../oauth.zig");
const keyring = @import("../keyring.zig");
const platform = @import("../platform.zig");
const Config = @import("../config.zig").Config;
const j = @import("json.zig");
const calendar_permissions = @import("calendar_permissions.zig");

pub const allowed_capabilities = [_][]const u8{
    "mail-read",     "mail-drafts",          "mail-send",             "mail-modify",       "contacts-read", "contacts-write", "calendar-rsvp",
    "calendar-read", "calendar-write-owned", "calendar-write-shared", "calendar-freebusy", "drive-upload",
};

pub const Grant = struct {
    account: []const u8,
    clientFile: []const u8,
    clientId: []const u8,
    grantId: []const u8,
    capabilities: []const []const u8,
    scopes: []const []const u8,
    enabled: bool = true,
    pub fn permits(self: *const Grant, capability: []const u8) bool {
        if (!self.enabled) return false;
        for (self.capabilities) |item| if (std.mem.eql(u8, item, capability)) return true;
        return false;
    }
};
pub const Registry = struct { version: u8 = 1, accounts: []Grant = &.{} };
const max_registry_bytes = 64 * 1024;

pub fn scopesFor(a: std.mem.Allocator, capabilities: []const []const u8) ![]const []const u8 {
    if (capabilities.len == 0 or capabilities.len > allowed_capabilities.len) return error.InvalidCapabilities;
    var read = false;
    var send = false;
    var modify = false;
    var drafts = false;
    var contacts_read = false;
    var contacts_write = false;
    var drive_upload = false;
    var calendar: calendar_permissions.Selection = .{};
    for (capabilities, 0..) |capability, index| {
        var known = false;
        for (allowed_capabilities) |item| known = known or std.mem.eql(u8, item, capability);
        if (!known) return error.InvalidCapabilities;
        for (capabilities[0..index]) |previous| if (std.mem.eql(u8, previous, capability)) return error.InvalidCapabilities;
        read = read or std.mem.eql(u8, capability, "mail-read");
        send = send or std.mem.eql(u8, capability, "mail-send") or std.mem.eql(u8, capability, "calendar-rsvp");
        modify = modify or std.mem.eql(u8, capability, "mail-modify");
        drafts = drafts or std.mem.eql(u8, capability, "mail-drafts");
        contacts_read = contacts_read or std.mem.eql(u8, capability, "contacts-read");
        contacts_write = contacts_write or std.mem.eql(u8, capability, "contacts-write");
        drive_upload = drive_upload or std.mem.eql(u8, capability, "drive-upload");
        calendar.read = calendar.read or std.mem.eql(u8, capability, "calendar-read");
        calendar.write_owned = calendar.write_owned or std.mem.eql(u8, capability, "calendar-write-owned");
        calendar.write_shared = calendar.write_shared or std.mem.eql(u8, capability, "calendar-write-shared");
        calendar.availability = calendar.availability or std.mem.eql(u8, capability, "calendar-freebusy");
    }
    if (!read) return error.MailReadCapabilityRequired;
    var scopes: std.ArrayList([]const u8) = .empty;
    try scopes.append(a, if (modify) "https://www.googleapis.com/auth/gmail.modify" else oauth.readonly_scope);
    if (!modify) {
        if (drafts) try scopes.append(a, "https://www.googleapis.com/auth/gmail.compose") else if (send) try scopes.append(a, "https://www.googleapis.com/auth/gmail.send");
    }
    if (contacts_write) try scopes.append(a, "https://www.googleapis.com/auth/contacts") else if (contacts_read) try scopes.append(a, "https://www.googleapis.com/auth/contacts.readonly");
    const calendar_scopes = try calendar_permissions.scopes(a, calendar);
    defer a.free(calendar_scopes);
    try scopes.appendSlice(a, calendar_scopes);
    if (drive_upload) try scopes.append(a, "https://www.googleapis.com/auth/drive.file");
    return try scopes.toOwnedSlice(a);
}
pub fn grantIdentity(scopes: []const []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("omagma-terminal-grant-v1\x00");
    for (scopes) |scope| {
        hasher.update(scope);
        hasher.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn defaultFile(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const root = env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{env.get("HOME") orelse return error.HomeRequired});
    return try std.fmt.allocPrint(a, "{s}/omagma/terminal-grants.json", .{root});
}
pub fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) !Registry {
    return loadFrom(std.Io.Dir.cwd(), io, a, path);
}
pub fn loadConfigured(io: std.Io, a: std.mem.Allocator, config: *const Config, path: []const u8) !Registry {
    if (config.credential_store != .vault) return load(io, a, path);
    const provider = config.runtime_provider orelse return error.VaultLocked;
    const bytes = (try provider.read(.grants, .{})) orelse return error.VaultIdentityRequired;
    return parse(a, bytes);
}
fn validateRegistryFile(stat: std.Io.File.Stat) !void {
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureGrantRegistryFile;
    if (stat.size > max_registry_bytes) return error.GrantRegistryTooLarge;
}
fn loadFrom(dir: std.Io.Dir, io: std.Io, a: std.mem.Allocator, path: []const u8) !Registry {
    // Reject special files before opening so an ordinary named pipe cannot
    // block this metadata read. Recheck the descriptor to close replacement
    // races, and never follow the final registry symlink.
    const before = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return .{} else return err;
    try validateRegistryFile(before);
    const file = dir.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop, error.IsDir => return error.InsecureGrantRegistryFile,
        else => return err,
    };
    defer file.close(io);
    try validateRegistryFile(try file.stat(io));
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const bytes = reader.interface.allocRemaining(a, .limited(max_registry_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.GrantRegistryTooLarge,
        else => return err,
    };
    return parse(a, bytes);
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Registry {
    if (bytes.len > max_registry_bytes) return error.GrantRegistryTooLarge;
    try b.preflight(bytes);
    const registry = try std.json.parseFromSliceLeaky(Registry, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = 4096 });
    if (registry.version != 1 or registry.accounts.len > 3) return error.InvalidGrantRegistry;
    for (registry.accounts, 0..) |*grant, index| {
        try b.address(grant.account);
        if (grant.clientFile.len == 0 or grant.clientFile.len > 4096 or grant.clientId.len > 4096 or !std.mem.endsWith(u8, grant.clientId, ".apps.googleusercontent.com")) return error.InvalidGrantRegistry;
        try oauth.validateScopeSet(grant.scopes);
        const expected = try scopesFor(a, grant.capabilities);
        if (expected.len != grant.scopes.len) return error.InvalidGrantRegistry;
        for (expected, grant.scopes) |left, right| if (!std.mem.eql(u8, left, right)) return error.InvalidGrantRegistry;
        const id = grantIdentity(grant.scopes);
        if (!std.mem.eql(u8, grant.grantId, &id)) return error.InvalidGrantRegistry;
        for (registry.accounts[0..index]) |previous| if (std.ascii.eqlIgnoreCase(previous.account, grant.account)) return error.InvalidGrantRegistry;
    }
    return registry;
}
pub fn find(registry: *const Registry, account: []const u8) ?*const Grant {
    for (registry.accounts) |*grant| if (std.mem.eql(u8, grant.account, account)) return grant;
    return null;
}
fn save(io: std.Io, a: std.mem.Allocator, path: []const u8, registry: Registry) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return error.InvalidGrantPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    const bytes = try std.json.Stringify.valueAlloc(a, registry, .{});
    if (bytes.len >= max_registry_bytes) return error.GrantRegistryTooLarge;
    var atomic = try dir.createFileAtomic(io, basename, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
fn requestCapabilities(a: std.mem.Allocator, request: j.Value) ![]const []const u8 {
    const field = j.get(request, "capabilities") orelse return error.CapabilitiesRequired;
    if (field != .array or field.array.items.len > allowed_capabilities.len) return error.InvalidCapabilities;
    const result = try a.alloc([]const u8, field.array.items.len);
    for (field.array.items, result) |item, *dest| dest.* = try j.string(item);
    _ = try scopesFor(a, result);
    return result;
}

/// Reconsent keeps this account's terminal registration unless explicitly
/// replaced. Falling back to the bar registration would broaden its grant.
fn authorizationClient(request: j.Value, current: ?*const Grant, configured: []const u8) ![]const u8 {
    const selected = if (j.get(request, "clientFile")) |value| try j.string(value) else if (current) |grant| grant.clientFile else configured;
    if (selected.len == 0) return error.OAuthClientRequired;
    return selected;
}

pub fn run(io: std.Io, a: std.mem.Allocator, config: *const Config, env: *const std.process.Environ.Map, request: j.Value) !j.Value {
    const command = try j.required(request, "cmd");
    const account = try j.required(request, "account");
    const index = config.index(account) orelse return error.UnknownAccount;
    if (!config.accounts[index].enabled) return error.AccountDisabled;
    const path = if (config.credential_store == .vault) "" else if (j.get(request, "grantFile")) |v| try j.string(v) else try defaultFile(a, env);
    var registry = try loadConfigured(io, a, config, path);
    const current = find(&registry, account);
    if (std.mem.eql(u8, command, "auth.status")) return j.value(a, .{ .account = account, .namespace = keyring.terminal_service, .configured = current != null, .grant = current, .credentialStore = @tagName(config.credential_store), .credentialDirectory = config.credential_directory.slice() });
    if (std.mem.eql(u8, command, "auth.revoke")) {
        if (config.credential_store != .vault) try keyring.clearTerminal(io, config.credentials(), account);
        var accounts: std.ArrayList(Grant) = .empty;
        for (registry.accounts) |grant| if (!std.mem.eql(u8, grant.account, account)) try accounts.append(a, grant);
        registry.accounts = accounts.items;
        if (config.credential_store == .vault) {
            const bytes = try j.encodeAlloc(a, registry, .{});
            try (config.runtime_provider orelse return error.VaultLocked).apply(&.{ .{ .kind = .terminal_token, .key = .{ .account = account }, .value = null }, .{ .kind = .grants, .value = bytes } });
        } else try save(io, a, path, registry);
        return j.value(a, .{ .account = account, .cleared = true, .namespace = keyring.terminal_service });
    }
    if (!std.mem.eql(u8, command, "auth.authorize")) return error.UnsupportedCommand;
    const caps = try requestCapabilities(a, request);
    const scopes = try scopesFor(a, caps);
    const client_file = try authorizationClient(request, current, config.client_file.slice());
    var desktop: oauth.DesktopClient = .{};
    defer desktop.wipe();
    try oauth.loadDesktopWithSettings(io, client_file, &desktop, config.credentials());
    // A new scope grant on the bar's OAuth client can change its refresh-token
    // scope response. Require a distinct Desktop client for broader access.
    if (scopes.len != 1 or !std.mem.eql(u8, scopes[0], oauth.readonly_scope)) {
        if (config.client_file.len != 0) {
            var bar: oauth.DesktopClient = .{};
            defer bar.wipe();
            try oauth.loadDesktopWithSettings(io, config.client_file.slice(), &bar, config.credentials());
            if (std.mem.eql(u8, bar.client_id.slice(), desktop.client_id.slice())) return error.SeparateTerminalClientRequired;
        }
    }
    var captured: b.Text(@import("../limits.zig").secret) = .{};
    defer captured.wipe();
    const identity = grantIdentity(scopes);
    try platform.deadline(io, platform.seconds(180), oauth.authorizeScoped, .{ io, client_file, account, config.accounts[index].profile.slice(), config.chrome.slice(), scopes, @as(?oauth.TerminalCredential, .{ .grant_id = &identity, .capture = if (config.credential_store == .vault) &captured else null }), config.credentials() });
    const grant: Grant = .{ .account = try a.dupe(u8, account), .clientFile = try a.dupe(u8, client_file), .clientId = try a.dupe(u8, desktop.client_id.slice()), .grantId = try a.dupe(u8, &identity), .capabilities = caps, .scopes = scopes };
    var accounts: std.ArrayList(Grant) = .empty;
    for (registry.accounts) |old| if (!std.mem.eql(u8, old.account, account)) try accounts.append(a, old);
    try accounts.append(a, grant);
    if (accounts.items.len > 3) return error.InvalidGrantRegistry;
    registry.accounts = accounts.items;
    if (config.credential_store == .vault) {
        const bytes = try j.encodeAlloc(a, registry, .{});
        try (config.runtime_provider orelse return error.VaultLocked).apply(&.{ .{ .kind = .terminal_token, .key = .{ .account = account }, .value = null }, .{ .kind = .grants, .value = bytes }, .{ .kind = .terminal_token, .key = .{ .account = account, .client = desktop.client_id.slice(), .grant = &identity }, .value = captured.slice() } });
    } else try save(io, a, path, registry);
    return j.value(a, .{ .account = account, .authorized = true, .namespace = keyring.terminal_service, .capabilities = caps, .scopes = scopes });
}

test "terminal scopes are minimal canonical and identity-bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const send = try scopesFor(a, &.{ "mail-read", "mail-send", "calendar-rsvp", "contacts-read" });
    try std.testing.expectEqual(@as(usize, 3), send.len);
    try std.testing.expectEqualStrings(oauth.readonly_scope, send[0]);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/gmail.send", send[1]);
    const drafts = try scopesFor(a, &.{ "mail-read", "mail-send", "mail-drafts" });
    try std.testing.expectEqual(@as(usize, 2), drafts.len);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/gmail.compose", drafts[1]);
    try oauth.validateScopeSet(drafts);
    const modify = try scopesFor(a, &.{ "mail-read", "mail-modify", "mail-send", "mail-drafts", "contacts-write" });
    try std.testing.expectEqual(@as(usize, 2), modify.len);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/gmail.modify", modify[0]);
    try std.testing.expect(!std.mem.eql(u8, &grantIdentity(send), &grantIdentity(modify)));
    try std.testing.expectError(error.InvalidCapabilities, scopesFor(a, &.{ "mail-read", "mail-read" }));
}

test "calendar: terminal grants preserve mail and contacts while requesting exact optional scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shared = try scopesFor(a, allowed_capabilities[0 .. allowed_capabilities.len - 1]);
    try std.testing.expectEqual(@as(usize, 5), shared.len);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/gmail.modify", shared[0]);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/contacts", shared[1]);
    try std.testing.expectEqualStrings(calendar_permissions.calendar_list, shared[2]);
    try std.testing.expectEqualStrings(calendar_permissions.events_write, shared[3]);
    try std.testing.expectEqualStrings(calendar_permissions.free_busy, shared[4]);
    try oauth.validateScopeSet(shared);
    const reordered = try scopesFor(a, &.{ "calendar-freebusy", "contacts-write", "calendar-write-shared", "mail-modify", "mail-read" });
    try std.testing.expectEqualSlices(u8, &grantIdentity(shared), &grantIdentity(reordered));
    const owned = try scopesFor(a, &.{ "mail-read", "calendar-write-owned" });
    try std.testing.expectEqualStrings(calendar_permissions.events_owned, owned[2]);
    try std.testing.expect(!std.mem.eql(u8, &grantIdentity(owned), &grantIdentity(shared)));
    try std.testing.expectError(error.MailReadCapabilityRequired, scopesFor(a, &.{"calendar-read"}));
    try std.testing.expectError(error.InvalidCapabilities, scopesFor(a, &.{ "mail-read", "calendar-read", "calendar-read" }));
    try std.testing.expectError(error.InvalidCapabilities, scopesFor(a, &.{ "mail-read", "calendar-admin" }));
}

test "grant registry reads require private regular files and reject final symlinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "terminal-grants.json", .{ .read = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, "{\"version\":1,\"accounts\":[]}");
    const private = try loadFrom(temporary.dir, io, a, "terminal-grants.json");
    try std.testing.expectEqual(@as(usize, 0), private.accounts.len);
    try temporary.dir.symLink(io, "terminal-grants.json", "grant-link.json", .{});
    try std.testing.expectError(error.InsecureGrantRegistryFile, loadFrom(temporary.dir, io, a, "grant-link.json"));
    try file.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.InsecureGrantRegistryFile, loadFrom(temporary.dir, io, a, "terminal-grants.json"));
    try temporary.dir.createDir(io, "registry-directory", .fromMode(0o700));
    try std.testing.expectError(error.InsecureGrantRegistryFile, loadFrom(temporary.dir, io, a, "registry-directory"));
    const absent = try loadFrom(temporary.dir, io, a, "absent.json");
    try std.testing.expectEqual(@as(usize, 0), absent.accounts.len);
}

test "Drive authorization: upload capability adds only per-file scope" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const scopes = try scopesFor(arena.allocator(), &.{ "mail-read", "drive-upload" });
    try std.testing.expectEqual(@as(usize, 2), scopes.len);
    try std.testing.expectEqualStrings(oauth.readonly_scope, scopes[0]);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/drive.file", scopes[1]);
    try oauth.validateScopeSet(scopes);
}

test "attachment delivery: reconsent retains the existing terminal registration separately from the bar" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grant: Grant = .{ .account = "self@example.test", .clientFile = "existing-terminal-registration", .clientId = "synthetic.apps.googleusercontent.com", .grantId = "synthetic", .capabilities = &.{"mail-read"}, .scopes = &.{oauth.readonly_scope} };
    const request = j.object(a);
    try std.testing.expectEqualStrings("existing-terminal-registration", try authorizationClient(request, &grant, "bar-registration"));
    try std.testing.expectEqualStrings("existing-terminal-registration", try authorizationClient(request, &grant, ""));
    const explicit = try j.value(a, .{ .clientFile = "replacement-terminal-registration" });
    try std.testing.expectEqualStrings("replacement-terminal-registration", try authorizationClient(explicit, &grant, "bar-registration"));
    try std.testing.expectEqualStrings("bar-registration", try authorizationClient(request, null, "bar-registration"));
    try std.testing.expectError(error.OAuthClientRequired, authorizationClient(request, null, ""));
}

test "attachment delivery: reconsent via a persisted terminal registration cannot broaden the bar client" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Native = @import("../native_identity.zig");
    const Fixture = struct {
        registry: []const u8,
        client_reads: usize = 0,
        writes: usize = 0,
        fn read(ctx: *anyopaque, kind: Native.Kind, key: Native.Key) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (kind == .grants) return self.registry;
            if (kind == .desktop_client) {
                try std.testing.expectEqualStrings(if (self.client_reads == 0) "existing-terminal-registration" else "bar-registration", key.name);
                self.client_reads += 1;
                return "{\"installed\":{\"client_id\":\"synthetic.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret\"}}";
            }
            return error.UnexpectedIdentityRead;
        }
        fn apply(ctx: *anyopaque, _: []const Native.Change) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.writes += 1;
            return error.UnexpectedIdentityWrite;
        }
    };
    const scopes = try scopesFor(a, &.{"mail-read"});
    const grant_id = grantIdentity(scopes);
    const grant: Grant = .{ .account = "self@example.test", .clientFile = "existing-terminal-registration", .clientId = "synthetic.apps.googleusercontent.com", .grantId = &grant_id, .capabilities = &.{"mail-read"}, .scopes = scopes };
    var grants = [_]Grant{grant};
    var fixture: Fixture = .{ .registry = try j.encodeAlloc(a, Registry{ .accounts = &grants }, .{}) };
    const config = try a.create(Config);
    try config.defaults("/nonexistent/synthetic-home");
    config.count = 1;
    try config.accounts[0].address.set(grant.account);
    try config.client_file.set("bar-registration");
    config.credential_store = .vault;
    config.runtime_provider = .{ .context = &fixture, .readFn = Fixture.read, .applyFn = Fixture.apply };
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    const request = try j.value(a, .{ .cmd = "auth.authorize", .account = grant.account, .capabilities = [_][]const u8{ "mail-read", "mail-send", "drive-upload" } });
    try std.testing.expectError(error.SeparateTerminalClientRequired, run(std.testing.io, a, config, &env, request));
    try std.testing.expectEqual(@as(usize, 2), fixture.client_reads);
    try std.testing.expectEqual(@as(usize, 0), fixture.writes);
}
