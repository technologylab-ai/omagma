const std = @import("std");
const b = @import("../bounded.zig");
const oauth = @import("../oauth.zig");
const keyring = @import("../keyring.zig");
const platform = @import("../platform.zig");
const Config = @import("../config.zig").Config;
const j = @import("json.zig");

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
    if (capabilities.len == 0 or capabilities.len > 6) return error.InvalidCapabilities;
    const allowed = [_][]const u8{ "mail-read", "mail-send", "mail-modify", "contacts-read", "contacts-write", "calendar-rsvp" };
    var read = false;
    var send = false;
    var modify = false;
    var contacts_read = false;
    var contacts_write = false;
    for (capabilities, 0..) |capability, index| {
        var known = false;
        for (allowed) |item| known = known or std.mem.eql(u8, item, capability);
        if (!known) return error.InvalidCapabilities;
        for (capabilities[0..index]) |previous| if (std.mem.eql(u8, previous, capability)) return error.InvalidCapabilities;
        read = read or std.mem.eql(u8, capability, "mail-read");
        send = send or std.mem.eql(u8, capability, "mail-send") or std.mem.eql(u8, capability, "calendar-rsvp");
        modify = modify or std.mem.eql(u8, capability, "mail-modify");
        contacts_read = contacts_read or std.mem.eql(u8, capability, "contacts-read");
        contacts_write = contacts_write or std.mem.eql(u8, capability, "contacts-write");
    }
    if (!read) return error.MailReadCapabilityRequired;
    var scopes: std.ArrayList([]const u8) = .empty;
    try scopes.append(a, if (modify) "https://www.googleapis.com/auth/gmail.modify" else oauth.readonly_scope);
    if (send and !modify) try scopes.append(a, "https://www.googleapis.com/auth/gmail.send");
    if (contacts_write) try scopes.append(a, "https://www.googleapis.com/auth/contacts") else if (contacts_read) try scopes.append(a, "https://www.googleapis.com/auth/contacts.readonly");
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
    if (field != .array or field.array.items.len > 6) return error.InvalidCapabilities;
    const result = try a.alloc([]const u8, field.array.items.len);
    for (field.array.items, result) |item, *dest| dest.* = try j.string(item);
    _ = try scopesFor(a, result);
    return result;
}

pub fn run(io: std.Io, a: std.mem.Allocator, config: *const Config, env: *const std.process.Environ.Map, request: j.Value) !j.Value {
    const command = try j.required(request, "cmd");
    const account = try j.required(request, "account");
    const index = config.index(account) orelse return error.UnknownAccount;
    if (!config.accounts[index].enabled) return error.AccountDisabled;
    const path = if (j.get(request, "grantFile")) |v| try j.string(v) else try defaultFile(a, env);
    var registry = try load(io, a, path);
    const current = find(&registry, account);
    if (std.mem.eql(u8, command, "auth.status")) return j.value(a, .{ .account = account, .namespace = keyring.terminal_service, .configured = current != null, .grant = current });
    if (std.mem.eql(u8, command, "auth.revoke")) {
        try keyring.clearTerminal(io, account);
        var accounts: std.ArrayList(Grant) = .empty;
        for (registry.accounts) |grant| if (!std.mem.eql(u8, grant.account, account)) try accounts.append(a, grant);
        registry.accounts = accounts.items;
        try save(io, a, path, registry);
        return j.value(a, .{ .account = account, .cleared = true, .namespace = keyring.terminal_service });
    }
    if (!std.mem.eql(u8, command, "auth.authorize")) return error.UnsupportedCommand;
    const caps = try requestCapabilities(a, request);
    const scopes = try scopesFor(a, caps);
    const client_file = if (j.get(request, "clientFile")) |v| try j.string(v) else config.client_file.slice();
    if (client_file.len == 0) return error.OAuthClientRequired;
    var desktop: oauth.DesktopClient = .{};
    defer desktop.wipe();
    try oauth.loadDesktop(io, client_file, &desktop);
    // A new scope grant on the bar's OAuth client can change its refresh-token
    // scope response. Require a distinct Desktop client for broader access.
    if (scopes.len != 1 or !std.mem.eql(u8, scopes[0], oauth.readonly_scope)) {
        if (config.client_file.len != 0) {
            var bar: oauth.DesktopClient = .{};
            defer bar.wipe();
            try oauth.loadDesktop(io, config.client_file.slice(), &bar);
            if (std.mem.eql(u8, bar.client_id.slice(), desktop.client_id.slice())) return error.SeparateTerminalClientRequired;
        }
    }
    const identity = grantIdentity(scopes);
    try platform.deadline(io, platform.seconds(180), oauth.authorizeScoped, .{ io, client_file, account, config.accounts[index].profile.slice(), config.chrome.slice(), scopes, @as(?oauth.TerminalCredential, .{ .grant_id = &identity }) });
    const grant: Grant = .{ .account = try a.dupe(u8, account), .clientFile = try a.dupe(u8, client_file), .clientId = try a.dupe(u8, desktop.client_id.slice()), .grantId = try a.dupe(u8, &identity), .capabilities = caps, .scopes = scopes };
    var accounts: std.ArrayList(Grant) = .empty;
    for (registry.accounts) |old| if (!std.mem.eql(u8, old.account, account)) try accounts.append(a, old);
    try accounts.append(a, grant);
    if (accounts.items.len > 3) return error.InvalidGrantRegistry;
    registry.accounts = accounts.items;
    try save(io, a, path, registry);
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
    const modify = try scopesFor(a, &.{ "mail-read", "mail-modify", "mail-send", "contacts-write" });
    try std.testing.expectEqual(@as(usize, 2), modify.len);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/gmail.modify", modify[0]);
    try std.testing.expect(!std.mem.eql(u8, &grantIdentity(send), &grantIdentity(modify)));
    try std.testing.expectError(error.InvalidCapabilities, scopesFor(a, &.{ "mail-read", "mail-read" }));
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
