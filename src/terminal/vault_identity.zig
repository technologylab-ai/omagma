//! One authenticated, bounded identity snapshot per vault. This API accepts
//! already supplied synthetic/import data; it never discovers plaintext files.
const std = @import("std");
const native = @import("../native_identity.zig");
const Config = @import("../config.zig").Config;
const catalog = @import("vault_catalog.zig");
const auth = @import("auth.zig");
const oauth = @import("../oauth.zig");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const WipingAllocator = @import("vault_allocator.zig").WipingAllocator;
const max_entries = 16;
const Entry = struct { kind: native.Kind, key: native.Key = .{}, value: []const u8 };
const Wire = struct { schema: u8 = 1, entries: []const Entry };

/// Keep State stable after provider() is borrowed. Owner serializes requests;
/// callers must finish a borrowed read before apply or deinit.
pub const State = struct {
    owner: *catalog.Owner,
    backing: std.mem.Allocator,
    wiping: *WipingAllocator,
    arena: std.heap.ArenaAllocator,
    entries: []const Entry = &.{},
    active: bool = true,
    fn empty(owner: *catalog.Owner, a: std.mem.Allocator) !State {
        const wiping = try a.create(WipingAllocator);
        wiping.* = .{ .backing = a };
        return .{ .owner = owner, .backing = a, .wiping = wiping, .arena = .init(wiping.allocator()) };
    }
    pub fn create(owner: *catalog.Owner, a: std.mem.Allocator, config: *const Config) !State {
        return createWithAccounts(owner, a, config, &.{});
    }
    pub fn createWithAccounts(owner: *catalog.Owner, a: std.mem.Allocator, config: *const Config, additions: []const catalog.InitialAccount) !State {
        if (owner.identity != null) return error.PathAlreadyExists;
        if (config.credential_store != .vault) return error.InvalidCredentialStore;
        var self = try empty(owner, a);
        errdefer self.deinit();
        const bytes = try config.snapshot(self.arena.allocator());
        try self.applyWithAccounts(&.{ .{ .kind = .configuration, .value = bytes }, .{ .kind = .grants, .value = "{\"version\":1,\"accounts\":[]}" } }, additions);
        return self;
    }
    pub fn open(owner: *catalog.Owner, a: std.mem.Allocator) !State {
        var self = try empty(owner, a);
        errdefer self.deinit();
        const bytes = try owner.readIdentity(self.arena.allocator());
        try b.preflight(bytes);
        const wire = try std.json.parseFromSliceLeaky(Wire, self.arena.allocator(), bytes, .{ .allocate = .alloc_if_needed, .duplicate_field_behavior = .@"error", .max_value_len = catalog.Owner.max_identity_bytes });
        if (wire.schema != 1) return error.InvalidVaultIdentity;
        var validation: std.heap.ArenaAllocator = .init(self.wiping.allocator());
        defer validation.deinit();
        try validate(owner, validation.allocator(), wire.entries, &.{});
        self.entries = wire.entries;
        return self;
    }
    pub fn deinit(self: *State) void {
        if (!self.active) return;
        self.active = false;
        self.arena.deinit();
        self.entries = &.{};
        self.backing.destroy(self.wiping);
    }
    pub fn provider(self: *State) native.Provider {
        return .{ .context = self, .readFn = readCallback, .applyFn = applyCallback };
    }
    fn ready(self: *State) !void {
        if (!self.active or self.owner.closed) return error.VaultLocked;
        if (self.owner.uncertain) return error.VaultDurabilityUncertain;
    }
    pub fn loadConfig(self: *State, output: *Config) !void {
        try self.ready();
        var scratch: std.heap.ArenaAllocator = .init(self.wiping.allocator());
        defer scratch.deinit();
        output.* = .{};
        errdefer std.crypto.secureZero(u8, std.mem.asBytes(output));
        try output.parse(scratch.allocator(), find(self.entries, .configuration, .{}) orelse return error.InvalidVaultIdentity);
        output.runtime_provider = self.provider();
    }
    fn readCallback(context: *anyopaque, kind: native.Kind, key: native.Key) !?[]const u8 {
        const self: *State = @ptrCast(@alignCast(context));
        try self.ready();
        return find(self.entries, kind, key);
    }
    fn applyCallback(context: *anyopaque, changes: []const native.Change) !void {
        const self: *State = @ptrCast(@alignCast(context));
        return self.apply(changes);
    }
    pub fn apply(self: *State, changes: []const native.Change) !void {
        return self.applyWithAccounts(changes, &.{});
    }
    pub fn applyWithAccounts(self: *State, changes: []const native.Change, additions: []const catalog.InitialAccount) !void {
        try self.ready();
        if (changes.len == 0 or changes.len > max_entries) return error.InvalidVaultIdentity;
        var next: std.heap.ArenaAllocator = .init(self.wiping.allocator());
        errdefer next.deinit();
        const a = next.allocator();
        var rows: std.ArrayList(Entry) = .empty;
        for (self.entries) |entry| try rows.append(a, entry);
        for (changes) |change| {
            const wildcard = change.value == null and (change.kind == .bar_token or change.kind == .terminal_token) and change.key.account.len != 0 and change.key.client.len == 0 and change.key.grant.len == 0 and change.key.name.len == 0;
            var index: usize = 0;
            while (index < rows.items.len) {
                const entry = rows.items[index];
                if (entry.kind == change.kind and (entry.key.eql(change.key) or (wildcard and std.mem.eql(u8, entry.key.account, change.key.account)))) {
                    _ = rows.orderedRemove(index);
                } else index += 1;
            }
            if (change.value) |value| try rows.append(a, .{ .kind = change.kind, .key = change.key, .value = value });
            if (rows.items.len > max_entries) return error.VaultIdentityTooLarge;
        }
        var validation: std.heap.ArenaAllocator = .init(self.wiping.allocator());
        defer validation.deinit();
        try validate(self.owner, validation.allocator(), rows.items, additions);
        const encoded = try j.encodeAlloc(a, Wire{ .entries = rows.items }, .{});
        if (encoded.len > catalog.Owner.max_identity_bytes) return error.VaultIdentityTooLarge;
        // Parse owned copies before publication. No allocation may fail after
        // the catalog pointer commits; old borrowed bytes survive until then.
        const wire = try std.json.parseFromSliceLeaky(Wire, a, encoded, .{ .allocate = .alloc_if_needed, .max_value_len = catalog.Owner.max_identity_bytes });
        try self.owner.writeIdentityWithAccounts(encoded, additions);
        self.arena.deinit();
        self.arena = next;
        self.entries = wire.entries;
    }
};
fn find(entries: []const Entry, kind: native.Kind, key: native.Key) ?[]const u8 {
    for (entries) |entry| if (entry.kind == kind and entry.key.eql(key)) return entry.value;
    return null;
}
fn validate(owner: *catalog.Owner, a: std.mem.Allocator, entries: []const Entry, additions: []const catalog.InitialAccount) !void {
    if (entries.len < 2 or entries.len > max_entries) return error.InvalidVaultIdentity;
    for (entries, 0..) |entry, index| {
        for (entries[0..index]) |previous| if (entry.kind == previous.kind and entry.key.eql(previous.key)) return error.InvalidVaultIdentity;
        if (entry.kind == .preferences and entry.value.len > native.max_preferences_bytes) return error.UiPreferencesTooLarge;
        const value_limit: usize = if (entry.kind == .preferences) native.max_preferences_bytes else 128 * 1024;
        if (entry.value.len > value_limit or entry.key.name.len > 4096 or entry.key.account.len > 254 or entry.key.client.len > 4096 or entry.key.grant.len > 64) return error.VaultIdentityTooLarge;
        switch (entry.kind) {
            .configuration, .grants => if (!entry.key.eql(.{})) return error.InvalidVaultIdentity,
            .preferences => {
                if (!entry.key.eql(.{})) return error.InvalidVaultIdentity;
                if (entry.value.len > native.max_preferences_bytes) return error.UiPreferencesTooLarge;
                const prefs = try a.create(@import("preferences.zig").Preferences);
                try @import("preferences.zig").parseInto(prefs, a, entry.value);
            },
            .desktop_client => {
                if (entry.key.name.len == 0 or entry.key.account.len != 0 or entry.key.client.len != 0 or entry.key.grant.len != 0) return error.InvalidVaultIdentity;
                var desktop: oauth.DesktopClient = .{};
                defer desktop.wipe();
                try oauth.parseDesktop(entry.value, &desktop);
            },
            .bar_token, .terminal_token => {
                if (entry.key.name.len != 0 or entry.key.client.len == 0) return error.InvalidVaultIdentity;
                try b.address(entry.key.account);
                if (entry.value.len == 0 or entry.value.len > @import("../limits.zig").secret) return error.InvalidToken;
                for (entry.value) |byte| if (byte <= 32 or byte >= 127) return error.InvalidToken;
                if (entry.kind == .bar_token and entry.key.grant.len != 0) return error.InvalidVaultIdentity;
                if (entry.kind == .terminal_token and entry.key.grant.len != 64) return error.InvalidVaultIdentity;
            },
        }
    }
    const config = try a.create(Config);
    config.* = .{};
    try config.parse(a, find(entries, .configuration, .{}) orelse return error.InvalidVaultIdentity);
    if (additions.len > catalog.max_accounts - owner.count) return error.VaultAccountLimit;
    if (config.credential_store != .vault or config.count == 0 or config.count != owner.count + additions.len) return error.InvalidVaultIdentity;
    for (owner.entries[0..owner.count]) |*account| if (config.index(account.address()) == null) return error.VaultIdentityMismatch;
    for (additions) |account| if (config.index(account.account) == null) return error.VaultIdentityMismatch;
    const registry = try auth.parse(a, find(entries, .grants, .{}) orelse return error.InvalidVaultIdentity);
    for (registry.accounts) |grant| {
        if (config.index(grant.account) == null) return error.VaultIdentityMismatch;
        const bytes = find(entries, .desktop_client, .{ .name = grant.clientFile }) orelse return error.OAuthClientRequired;
        var desktop: oauth.DesktopClient = .{};
        defer desktop.wipe();
        try oauth.parseDesktop(bytes, &desktop);
        if (!std.mem.eql(u8, desktop.client_id.slice(), grant.clientId)) return error.VaultIdentityMismatch;
    }
    for (entries) |entry| {
        if (entry.kind != .bar_token and entry.kind != .terminal_token) continue;
        if (config.index(entry.key.account) == null) return error.VaultIdentityMismatch;
        if (entry.kind == .terminal_token) {
            const grant = auth.find(&registry, entry.key.account) orelse return error.InvalidGrantIdentity;
            if (!std.mem.eql(u8, grant.clientId, entry.key.client) or !std.mem.eql(u8, grant.grantId, entry.key.grant)) return error.InvalidGrantIdentity;
        } else {
            const bytes = find(entries, .desktop_client, .{ .name = config.client_file.slice() }) orelse return error.OAuthClientRequired;
            var desktop: oauth.DesktopClient = .{};
            defer desktop.wipe();
            try oauth.parseDesktop(bytes, &desktop);
            if (!std.mem.eql(u8, desktop.client_id.slice(), entry.key.client)) return error.InvalidGrantIdentity;
        }
    }
}
