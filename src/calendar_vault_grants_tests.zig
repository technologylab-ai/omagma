//! Calendar's non-fixture host must authorize offline reads from the active
//! encrypted identity. All records and clients here are synthetic; no tokens
//! are provisioned and no provider operation is requested.
const std = @import("std");
const Config = @import("config.zig").Config;
const auth = @import("terminal/auth.zig");
const calendar_host = @import("terminal/calendar_host.zig");
const commands = @import("terminal/calendar_commands.zig");
const persistence = @import("terminal/calendar_store.zig");
const calendar_types = @import("terminal/calendar_types.zig");
const calendar_service = @import("terminal/calendar_service.zig");
const Store = @import("terminal/store.zig").Store;
const catalog = @import("terminal/vault_catalog.zig");
const identity = @import("terminal/vault_identity.zig");
const storage = @import("terminal/vault_storage.zig");
const crypto = @import("terminal/vault_crypto.zig");
const header = @import("terminal/vault_header.zig");
const vault = @import("terminal/vault_types.zig");
const j = @import("terminal/json.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const account = "calendar-vault@example.test";
const client_id = "synthetic-calendar.apps.googleusercontent.com";
const client_json = "{\"installed\":{\"client_id\":\"synthetic-calendar.apps.googleusercontent.com\",\"client_secret\":\"SYNTHETIC-NEVER-REAL\"}}";
const target: calendar_types.Target = .{ .account = account, .calendar_id = "synthetic-calendar" };

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    path: []const u8,
    grant_path: []const u8,
    key: vault.DataKey,
    workspace: vault.StreamWorkspace = undefined,
    descriptor: header.Header,
    owner: catalog.Owner,
    state: identity.State,
    selected: catalog.Account,
    config: *Config,
    reads: usize = 0,
    writes: usize = 0,

    fn create() !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = .init(a);
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        self.base = try self.tmp.dir.realPathFileAlloc(io, ".", alloc);
        self.path = try std.fmt.allocPrint(alloc, "{s}/sealed", .{self.base});
        self.grant_path = try std.fmt.allocPrint(alloc, "{s}/missing-grants.json", .{self.base});
        self.key = try crypto.createDataKey(io);
        errdefer self.key.wipe();
        self.descriptor = .{ .vault_id = self.key.vault_id, .key_id = self.key.key_id, .root_record = try storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
        self.owner = try catalog.Owner.create(io, self.path, self.descriptor, &self.key, &self.workspace);
        errdefer self.owner.close();
        try Store.createVaultAccount(&self.owner, alloc, account, .{ .fixtures = true });
        self.config = try alloc.create(Config);
        try self.config.defaults(self.base);
        self.config.credential_store = .vault;
        self.config.count = 1;
        try self.config.accounts[0].address.set(account);
        self.config.accounts[0].enabled = true;
        self.state = try identity.State.create(&self.owner, a, self.config);
        errdefer self.state.deinit();
        try self.state.loadConfig(self.config);
        self.owner.live_enabled = true;
        self.selected = try self.owner.openAccount(account);
        self.reads = 0;
        self.writes = 0;
        return self;
    }
    fn close(self: *Fixture) void {
        self.selected.close();
        self.state.deinit();
        self.owner.close();
        self.key.wipe();
        self.workspace.wipe();
        self.arena.deinit();
        self.tmp.cleanup();
        a.destroy(self);
    }
    fn reopen(self: *Fixture) !void {
        self.selected.close();
        self.state.deinit();
        self.owner.close();
        self.owner = try catalog.Owner.open(io, self.path, self.descriptor, &self.key, &self.workspace);
        self.state = try identity.State.open(&self.owner, a);
        try self.state.loadConfig(self.config);
        self.owner.live_enabled = true;
        self.selected = try self.owner.openAccount(account);
    }
    fn grant(self: *Fixture, enabled: bool) ![]const u8 {
        const alloc = self.arena.allocator();
        const scopes = try auth.scopesFor(alloc, &.{ "mail-read", "calendar-read" });
        const id = auth.grantIdentity(scopes);
        var rows = [_]auth.Grant{.{ .account = account, .clientFile = "calendar-client", .clientId = client_id, .grantId = &id, .capabilities = &.{ "mail-read", "calendar-read" }, .scopes = scopes, .enabled = enabled }};
        const bytes = try j.encodeAlloc(alloc, auth.Registry{ .accounts = &rows }, .{});
        try self.state.apply(&.{ .{ .kind = .desktop_client, .key = .{ .name = "calendar-client" }, .value = client_json }, .{ .kind = .grants, .value = bytes } });
        return bytes;
    }
    fn openStore(context: *anyopaque, alloc: std.mem.Allocator, requested: []const u8, readonly: bool) anyerror!Store {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings(account, requested);
        if (readonly) self.reads += 1 else self.writes += 1;
        return Store.openVault(io, alloc, &self.selected, .{}, readonly);
    }
    fn noSource(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: j.Value) anyerror!commands.InvitationInput {
        return error.UnexpectedMailSourceRead;
    }
    fn host(self: *Fixture, alloc: std.mem.Allocator, env: *const std.process.Environ.Map) calendar_host.Host {
        return .{ .io = io, .allocator = alloc, .backing_allocator = a, .env = env, .config = self.config, .options = .{}, .cache_root = self.base, .source_context = self, .loadSourceFn = noSource, .access = .{ .context = self, .openFn = openStore } };
    }
};

test "calendar vault grants: offline list agenda and details use encrypted grants after restart and revocation" {
    std.debug.print("calendar vault grants compiler={s} optimize={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    const fixture = try Fixture.create();
    defer fixture.close();
    const alloc = fixture.arena.allocator();
    const valid_grant = try fixture.grant(true);
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("HOME", fixture.base);
    const zone: @import("terminal/timezone.zig").Zone = .{};
    const window = try calendar_service.windowForDays(alloc, "2026-10-13", .day, .{ .id = "UTC", .zone = &zone });
    const calendar: calendar_types.Calendar = .{ .target = target, .summary = "Synthetic private calendar", .time_zone = "UTC", .access = .owner, .primary = true };
    const event: calendar_types.Event = .{ .target = target, .id = "synthetic-event", .summary = "Encrypted fixture event", .start = .{ .kind = .instant, .value = window.start_ms + 3600000 }, .end = .{ .kind = .instant, .value = window.start_ms + 7200000 } };
    var saved: persistence.Host = .{ .io = io, .allocator = a, .result_allocator = alloc, .root = fixture.base, .account = account, .options = .{}, .access = .{ .context = fixture, .openFn = Fixture.openStore } };
    const cache = saved.cache();
    try cache.saveCalendarsFn.?(cache.context, .{ .calendars = &.{calendar}, .complete = true });
    try cache.saveFn(cache.context, .{ .target = target, .window = window, .events = &.{event}, .fetched_at_ms = window.start_ms, .complete = true });
    const writes_before = fixture.writes;
    const requests = [_]j.Value{
        try j.value(alloc, .{ .cmd = "calendar.list", .account = account, .cacheOnly = true, .grantFile = fixture.grant_path }),
        try j.value(alloc, .{ .cmd = "calendar.agenda", .account = account, .calendarId = target.calendar_id, .date = "2026-10-13", .view = "day", .cacheOnly = true, .grantFile = fixture.grant_path }),
        try j.value(alloc, .{ .cmd = "calendar.event", .account = account, .calendarId = target.calendar_id, .eventId = event.id, .cacheOnly = true, .grantFile = fixture.grant_path }),
    };
    for (0..2) |pass| {
        if (pass == 1) try fixture.reopen();
        const host = fixture.host(alloc, &env);
        for (requests, 0..) |request, index| {
            const result = try host.run(request);
            try std.testing.expect(try j.boolean(result, "cached", false));
            if (index == 0) {
                try std.testing.expect(try j.boolean(result, "stale", false));
                const calendars = j.get(result, "calendars").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), calendars.len);
                try std.testing.expect(try j.boolean(calendars[0], "canRead", false));
                try std.testing.expect(!try j.boolean(calendars[0], "canWrite", true));
            } else if (index == 1) {
                const snapshot = j.get(result, "snapshot").?;
                try std.testing.expect(try j.boolean(snapshot, "stale", false));
                const events = j.get(snapshot, "events").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), events.len);
                try std.testing.expectEqualStrings(event.summary, j.text(events[0], "summary"));
            } else try std.testing.expectEqualStrings(event.summary, j.text(j.get(result, "event").?, "summary"));
        }
    }
    try std.testing.expectEqual(writes_before, fixture.writes);
    try std.testing.expect(fixture.reads > 0);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, "missing-grants.json", .{}));

    // A stale, valid legacy registry must not override the revoked encrypted
    // grant. Revocation is reloaded for every cached command, including after
    // reopening the encrypted catalog and identity.
    const legacy = try fixture.tmp.dir.createFile(io, "missing-grants.json", .{ .permissions = .fromMode(0o600) });
    try legacy.writeStreamingAll(io, valid_grant);
    legacy.close(io);
    _ = try fixture.grant(false);
    try fixture.reopen();
    const reads_before = fixture.reads;
    const host = fixture.host(alloc, &env);
    for (requests) |request| try std.testing.expectError(error.CalendarPermissionRequired, host.run(request));
    try std.testing.expectEqual(reads_before, fixture.reads);
    try std.testing.expectEqual(writes_before, fixture.writes);
    fixture.config.runtime_provider = null;
    try std.testing.expectError(error.VaultLocked, host.run(requests[0]));
}
