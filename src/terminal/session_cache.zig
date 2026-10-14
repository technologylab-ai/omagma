//! Fixed, process-local access-token policy for the sole native network worker.
//! No I/O, allocator, refresh tokens, HTTP clients or serialized state live here.
//! Before every begin(), the caller must validate current config/grant/client
//! and obtain the current credential revision through its selected provider.
//! Paths or timestamps alone do not prove an unchanged credential. A failed or
//! locked credential lookup must invalidate that account instead of using a hit.
const std = @import("std");
const limits = @import("../limits.zig");

pub const Digest = [32]u8;
pub const Namespace = enum(u8) { terminal, readonly_interactive, readonly_automatic };
pub const CredentialBackend = enum(u8) { keyring, file, vault };
pub const expiry_margin_ms: i64 = 60 * 1000;

/// These values come from locally validated authorization inputs, never an
/// untrusted request's proposed scopes or capabilities. Revisions are digests
/// of the current validated contents or equally strong provider revisions.
pub const Context = struct {
    account: []const u8,
    namespace: Namespace,
    client_id: []const u8,
    client_revision: Digest,
    grant_id: []const u8,
    grant_revision: Digest,
    scopes: []const []const u8,
    capabilities: []const []const u8,
    credential_backend: CredentialBackend,
    credential_location: []const u8,
    credential_revision: Digest,
};

pub fn revision(bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    hash.update("omagma-session-revision-v1\x00");
    hash.update(bytes);
    return hash.finalResult();
}

fn field(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, @intCast(bytes.len), .little);
    hash.update(&size);
    hash.update(bytes);
}

fn accountDigest(account: []const u8) !Digest {
    if (account.len == 0 or account.len > limits.max_address or std.mem.indexOfScalar(u8, account, '@') == null) return error.InvalidAccount;
    var lowered: [limits.max_address]u8 = undefined;
    for (account, 0..) |byte, index| {
        if (byte <= 32 or byte >= 127) return error.InvalidAccount;
        lowered[index] = std.ascii.toLower(byte);
    }
    return revision(lowered[0..account.len]);
}

pub const Binding = struct {
    account: Digest,
    context: Digest,

    pub fn init(input: Context) !Binding {
        const account = try accountDigest(input.account);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("omagma-session-binding-v1\x00");
        field(&hash, &account);
        field(&hash, &.{@backingInt(input.namespace)});
        field(&hash, input.client_id);
        field(&hash, &input.client_revision);
        field(&hash, input.grant_id);
        field(&hash, &input.grant_revision);
        // Counts separate the two lists; fields are length-delimited, so a
        // changed boundary or order can never accidentally produce a hit.
        var count: [8]u8 = undefined;
        std.mem.writeInt(u64, &count, @intCast(input.scopes.len), .little);
        field(&hash, &count);
        for (input.scopes) |scope| field(&hash, scope);
        std.mem.writeInt(u64, &count, @intCast(input.capabilities.len), .little);
        field(&hash, &count);
        for (input.capabilities) |capability| field(&hash, capability);
        field(&hash, &.{@backingInt(input.credential_backend)});
        field(&hash, input.credential_location);
        field(&hash, &input.credential_revision);
        return .{ .account = account, .context = hash.finalResult() };
    }
};

/// Valid only until the slot is begun again, invalidated or cleared. This
/// prevents a canceled/old refresh from publishing into a newer account job.
pub const Lease = struct { index: u8, generation: u64 };

const Slot = struct {
    binding: ?Binding = null,
    generation: u64 = 0,
    access: [limits.secret]u8 = @splat(0),
    access_len: u16 = 0,
    usable_until_ms: i64 = 0,

    fn wipe(self: *Slot) void {
        std.crypto.secureZero(u8, &self.access);
        self.access_len = 0;
        self.usable_until_ms = 0;
        self.generation +%= 1;
    }
};

pub const Cache = struct {
    slots: [limits.max_accounts]Slot = @splat(.{}),
    last_now_ms: ?i64 = null,

    /// Use one suspend-inclusive monotonic clock (std.Io.Clock.boot) for every
    /// timestamp. A backwards clock invalidates all tokens and outstanding
    /// leases; wall-clock corrections must never extend an access lifetime.
    fn observe(self: *Cache, now_ms: i64) !void {
        if (now_ms < 0) {
            self.clear();
            return error.InvalidSessionClock;
        }
        if (self.last_now_ms) |previous| if (now_ms < previous) self.clear();
        self.last_now_ms = now_ms;
    }

    /// index is the already-validated config account slot, not a caller key.
    /// A new context securely replaces that slot; no cross-context fallback.
    pub fn begin(self: *Cache, index: usize, binding: Binding, now_ms: i64) !Lease {
        if (index >= self.slots.len) return error.InvalidAccountSlot;
        try self.observe(now_ms);
        const slot = &self.slots[index];
        if (slot.binding == null or !std.mem.eql(u8, &slot.binding.?.context, &binding.context)) {
            slot.wipe();
            slot.binding = binding;
        } else slot.generation +%= 1;
        if (slot.access_len != 0 and now_ms >= slot.usable_until_ms) slot.wipe();
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    fn current(self: *Cache, lease: Lease) ?*Slot {
        if (lease.index >= self.slots.len) return null;
        const slot = &self.slots[lease.index];
        return if (slot.binding != null and slot.generation == lease.generation) slot else null;
    }

    /// The borrowed token never outlives its lease. Do not copy it to logs,
    /// argv, JSON/IPC, persisted state or a per-request arena.
    pub fn token(self: *Cache, lease: Lease, now_ms: i64) !?[]const u8 {
        try self.observe(now_ms);
        const slot = self.current(lease) orelse return null;
        if (slot.access_len == 0) return null;
        if (now_ms >= slot.usable_until_ms) {
            slot.wipe();
            return null;
        }
        return slot.access[0..slot.access_len];
    }

    /// Call only after a successful profile HTTP response has verified the new
    /// token's actual account. refresh_started_ms precedes the token exchange;
    /// profile/network latency must not add time to Google's expires_in.
    /// false means the freshly verified token is too near expiry to retain.
    pub fn publishVerified(self: *Cache, lease: Lease, verified_account: []const u8, access: []const u8, refresh_started_ms: i64, expires_in: u32, now_ms: i64) !bool {
        try self.observe(now_ms);
        const slot = self.current(lease) orelse return error.StaleSessionLease;
        errdefer slot.wipe();
        if (!std.mem.eql(u8, &slot.binding.?.account, &(try accountDigest(verified_account)))) return error.WrongAccount;
        if (access.len == 0 or access.len > limits.secret) return error.InvalidToken;
        for (access) |byte| if (byte <= 32 or byte >= 127) return error.InvalidToken;
        if (expires_in == 0 or expires_in > 86400 or refresh_started_ms < 0 or refresh_started_ms > now_ms) return error.InvalidTokenExpiry;
        const duration_ms = @as(i64, expires_in) * 1000;
        const expires_ms = std.math.add(i64, refresh_started_ms, duration_ms) catch return error.InvalidTokenExpiry;
        const usable_until_ms = expires_ms - expiry_margin_ms;
        if (usable_until_ms <= now_ms) {
            slot.wipe();
            return false;
        }
        std.mem.copyForwards(u8, slot.access[0..access.len], access);
        std.crypto.secureZero(u8, slot.access[access.len..]);
        slot.access_len = @intCast(access.len);
        slot.usable_until_ms = usable_until_ms;
        return true;
    }

    /// 401/revocation/profile failure invalidates before any refresh. The
    /// caller still owns the one-refresh-per-job guard and mutation policy.
    pub fn invalidate(self: *Cache, lease: Lease) void {
        if (self.current(lease)) |slot| slot.wipe();
    }

    pub fn invalidateAccount(self: *Cache, index: usize) void {
        if (index >= self.slots.len) return;
        self.slots[index].wipe();
        self.slots[index].binding = null;
    }

    pub fn clear(self: *Cache) void {
        for (&self.slots) |*slot| {
            slot.wipe();
            slot.binding = null;
        }
        self.last_now_ms = null;
    }
};

pub const reservation_bytes = @sizeOf(Cache);

fn testContext() Context {
    return .{
        .account = "self@example.test",
        .namespace = .terminal,
        .client_id = "synthetic.apps.googleusercontent.com",
        .client_revision = revision("synthetic-client-v1"),
        .grant_id = "synthetic-grant",
        .grant_revision = revision("synthetic-grant-v1"),
        .scopes = &.{"https://www.googleapis.com/auth/gmail.readonly"},
        .capabilities = &.{"mail-read"},
        .credential_backend = .file,
        .credential_location = "/synthetic/private/credentials",
        .credential_revision = revision("synthetic-refresh-v1"),
    };
}

test "session cache: reuse ends before token expiry and includes profile latency" {
    var cache: Cache = .{};
    defer cache.clear();
    const binding = try Binding.init(testContext());
    const first = try cache.begin(0, binding, 1000);
    try std.testing.expect((try cache.token(first, 1000)) == null);
    try std.testing.expect(try cache.publishVerified(first, "SELF@example.test", "synthetic-access", 1000, 3600, 8000));
    const next = try cache.begin(0, binding, 9000);
    try std.testing.expectEqualStrings("synthetic-access", (try cache.token(next, 9000)).?);
    try std.testing.expect((try cache.token(first, 9000)) == null);
    try std.testing.expectEqualStrings("synthetic-access", (try cache.token(next, 3540999)).?);
    try std.testing.expect((try cache.token(next, 3541000)) == null);
    try std.testing.expectEqualSlices(u8, &@as([limits.secret]u8, @splat(0)), &cache.slots[0].access);
}

test "session cache: every authorization identity or revision change misses" {
    const original = testContext();
    const initial = try Binding.init(original);
    var changed: [10]Context = @splat(original);
    changed[0].account = "another@example.test";
    changed[1].namespace = .readonly_automatic;
    changed[2].client_id = "different.apps.googleusercontent.com";
    changed[3].client_revision = revision("synthetic-client-v2");
    changed[4].grant_id = "another-grant";
    changed[5].grant_revision = revision("synthetic-grant-v2");
    changed[6].scopes = &.{"https://www.googleapis.com/auth/gmail.modify"};
    changed[7].capabilities = &.{ "mail-read", "mail-modify" };
    changed[8].credential_location = "/synthetic/different/credentials";
    changed[9].credential_revision = revision("synthetic-refresh-v2");
    for (changed) |context| {
        var cache: Cache = .{};
        defer cache.clear();
        const first = try cache.begin(0, initial, 1000);
        try std.testing.expect(try cache.publishVerified(first, original.account, "synthetic-access", 1000, 3600, 1001));
        const second = try cache.begin(0, try Binding.init(context), 1002);
        try std.testing.expect((try cache.token(second, 1002)) == null);
        try std.testing.expectError(error.StaleSessionLease, cache.publishVerified(first, original.account, "stale-access", 1000, 3600, 1003));
        try std.testing.expectEqualSlices(u8, &@as([limits.secret]u8, @splat(0)), &cache.slots[0].access);
    }
    var keyring = original;
    keyring.credential_backend = .keyring;
    try std.testing.expect(!std.mem.eql(u8, &initial.context, &(try Binding.init(keyring)).context));
    var automatic = original;
    automatic.namespace = .readonly_automatic;
    var manual = original;
    manual.namespace = .readonly_interactive;
    try std.testing.expect(!std.mem.eql(u8, &(try Binding.init(automatic)).context, &(try Binding.init(manual)).context));
}

test "session cache: three accounts stay isolated and explicit invalidation wipes" {
    var cache: Cache = .{};
    defer cache.clear();
    const accounts = [_][]const u8{ "one@example.test", "two@example.test", "three@example.test" };
    var leases: [3]Lease = undefined;
    for (accounts, 0..) |account, index| {
        var context = testContext();
        context.account = account;
        leases[index] = try cache.begin(index, try Binding.init(context), 1000);
        try std.testing.expect(try cache.publishVerified(leases[index], account, account, 1000, 3600, 1000));
    }
    cache.invalidate(leases[1]);
    try std.testing.expect((try cache.token(leases[1], 2000)) == null);
    try std.testing.expectEqualStrings(accounts[0], (try cache.token(leases[0], 2000)).?);
    try std.testing.expectEqualStrings(accounts[2], (try cache.token(leases[2], 2000)).?);
    try std.testing.expectError(error.StaleSessionLease, cache.publishVerified(leases[1], accounts[1], "late-access", 1000, 3600, 2000));
    cache.invalidateAccount(0);
    try std.testing.expect((try cache.token(leases[0], 2000)) == null);
    cache.clear();
    for (cache.slots) |slot| try std.testing.expectEqualSlices(u8, &@as([limits.secret]u8, @splat(0)), &slot.access);
    try std.testing.expect(reservation_bytes < 16 * 1024);
    try std.testing.expectError(error.InvalidAccountSlot, cache.begin(3, try Binding.init(testContext()), 2000));
}

test "session cache: profile mismatch clock regression and short expiry cannot publish a reusable token" {
    var cache: Cache = .{};
    defer cache.clear();
    const binding = try Binding.init(testContext());
    var lease = try cache.begin(0, binding, 1000);
    try std.testing.expectError(error.WrongAccount, cache.publishVerified(lease, "wrong@example.test", "synthetic-access", 1000, 3600, 1000));
    try std.testing.expect((try cache.token(lease, 1000)) == null);
    lease = try cache.begin(0, binding, 1000);
    try std.testing.expect(!try cache.publishVerified(lease, "self@example.test", "short-access", 1000, 60, 1000));
    lease = try cache.begin(0, binding, 1000);
    try std.testing.expect(try cache.publishVerified(lease, "self@example.test", "synthetic-access", 1000, 3600, 1000));
    try std.testing.expect((try cache.token(lease, 999)) == null);
    try std.testing.expectError(error.StaleSessionLease, cache.publishVerified(lease, "self@example.test", "late-access", 999, 3600, 999));
    lease = try cache.begin(0, binding, 2000);
    try std.testing.expectError(error.InvalidTokenExpiry, cache.publishVerified(lease, "self@example.test", "synthetic-access", 2001, 3600, 2000));
    lease = try cache.begin(0, binding, 2000);
    try std.testing.expectError(error.InvalidToken, cache.publishVerified(lease, "self@example.test", "invalid\ntoken", 2000, 3600, 2000));
    try std.testing.expectEqualSlices(u8, &@as([limits.secret]u8, @splat(0)), &cache.slots[0].access);
}
