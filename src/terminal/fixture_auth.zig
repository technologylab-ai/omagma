//! --fixtures scenario "sign-in-expired": the second configured account's
//! stored Google sign-in is refused, exactly as Google refuses an expired or
//! policy-revoked refresh token, until a fixture reconnect completes. Fixture
//! consent runs the real loopback listener, PKCE, state, consent-page launch
//! and callback (oauth.authorizeFixture) against the config's explicit
//! synthetic `fixtureConsentPage`; nothing reaches Google, no configured
//! browser is launched and nothing is written to a credential store.
//!
//! A completed reconnect is remembered in this process and, only with an
//! explicit --cache-dir, as a marker there for later fixture processes; the
//! default (real) cache root is never written.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const Config = @import("../config.zig").Config;
const oauth = @import("../oauth.zig");
const auth_diagnostic = @import("auth_diagnostic.zig");

pub const scenario = "sign-in-expired";
/// Google's token-endpoint answer for a Workspace re-authentication policy.
pub const refusal = "{\"error\":\"invalid_grant\",\"error_description\":\"reauth related error (invalid_rapt)\",\"error_uri\":\"https://support.google.com/a/answer/9368756\",\"error_subtype\":\"invalid_rapt\"}";
/// The fixture grant: the ordinary synthetic capability set.
pub const capabilities = [_][]const u8{ "mail-read", "mail-modify", "mail-send", "contacts-read", "contacts-write", "calendar-rsvp", "calendar-read", "calendar-write-shared", "calendar-freebusy" };

var lock: std.atomic.Mutex = .unlocked;
var reconnected: [@import("../limits.zig").max_accounts]?[16]u8 = @splat(null);
pub const reservation_bytes = @sizeOf(@TypeOf(reconnected)) + 1;

pub fn active(options: t.Options) bool {
    return options.fixtures and std.mem.eql(u8, options.fixture_scenario, scenario);
}

/// The fixture grant's identity, as auth.status reports it.
pub fn grantId(a: std.mem.Allocator) ![64]u8 {
    const auth = @import("auth.zig");
    return auth.grantIdentity(try auth.scopesFor(a, &capabilities));
}

fn key(account: []const u8) ![16]u8 {
    var lowered: [254]u8 = undefined;
    if (account.len == 0 or account.len > lowered.len) return error.InvalidAddress;
    for (account, 0..) |byte, index| lowered[index] = std.ascii.toLower(byte);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lowered[0..account.len], &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..16].*;
}

fn remembered(account: []const u8) bool {
    const wanted = key(account) catch return false;
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    for (reconnected) |entry| if (entry) |value| if (std.mem.eql(u8, &value, &wanted)) return true;
    return false;
}

fn marker(a: std.mem.Allocator, cache_root: []const u8, account: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/fixture-sign-in-{s}", .{ cache_root, &(try key(account)) });
}

/// Whether this account's synthetic sign-in is refused right now.
pub fn expired(io: std.Io, a: std.mem.Allocator, options: t.Options, config: *const Config, cache_root: []const u8, account: []const u8) !bool {
    if (!active(options)) return false;
    if ((config.index(account) orelse return false) != 1) return false;
    if (remembered(account)) return false;
    if (options.cache_dir == null) return true;
    std.Io.Dir.cwd().access(io, try marker(a, cache_root, account), .{}) catch |err| {
        if (err == error.FileNotFound) return true;
        return err;
    };
    return false;
}

/// Record the refusal through the same diagnostic path as a real refresh.
pub fn refuse(io: std.Io, a: std.mem.Allocator, account: []const u8) anyerror {
    const parsed = std.json.parseFromSliceLeaky(j.Value, a, refusal, .{}) catch return error.InvalidGrant;
    const grant = grantId(a) catch return error.InvalidGrant;
    auth_diagnostic.recordFailure(account, &grant, oauth.TokenError.fromJson(400, parsed), std.Io.Timestamp.now(io, .real).toMilliseconds());
    return error.InvalidGrant;
}

/// Every synthetic provider read: refused while expired, otherwise a
/// verified success of the synthetic grant, recorded exactly as a real
/// refresh records one, so fixtures and production report alike.
pub fn check(io: std.Io, a: std.mem.Allocator, options: t.Options, config: *const Config, cache_root: []const u8, account: []const u8) !void {
    if (try expired(io, a, options, config, cache_root, account)) return refuse(io, a, account);
    if (!active(options)) return;
    const grant = grantId(a) catch return;
    auth_diagnostic.recordSuccess(account, &grant, std.Io.Timestamp.now(io, .real).toMilliseconds());
}

pub fn markReconnected(io: std.Io, a: std.mem.Allocator, options: t.Options, cache_root: []const u8, account: []const u8) !void {
    const wanted = try key(account);
    if (!remembered(account)) {
        while (!lock.tryLock()) std.atomic.spinLoopHint();
        defer lock.unlock();
        for (&reconnected) |*entry| if (entry.* == null) {
            entry.* = wanted;
            break;
        };
    }
    // Only an explicit fixture cache directory is ever written.
    if (options.cache_dir == null) return;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, cache_root, .fromMode(0o700));
    const file = try std.Io.Dir.cwd().createFile(io, try marker(a, cache_root, account), .{ .permissions = .fromMode(0o600), .truncate = true });
    file.close(io);
}

/// Test isolation only.
pub fn reset() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    reconnected = @splat(null);
}

test "reconnect fixture sign-in: only the second account expires, until a reconnect is recorded" {
    reset();
    defer reset();
    defer auth_diagnostic.reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/cache", .{temporary.sub_path});
    var config: Config = undefined;
    try config.defaults("/nonexistent/synthetic-home");
    const options: t.Options = .{ .fixtures = true, .fixture_scenario = scenario, .cache_dir = root };
    try std.testing.expect(!try expired(io, a, options, &config, root, "personal@example.com"));
    try std.testing.expect(try expired(io, a, options, &config, root, "work@example.com"));
    try std.testing.expect(!try expired(io, a, .{ .fixtures = true }, &config, root, "work@example.com"));
    try std.testing.expectEqual(error.InvalidGrant, refuse(io, a, "work@example.com"));
    try std.testing.expectEqualStrings("invalid_rapt", auth_diagnostic.observed("work@example.com").value.subtype.slice());
    try markReconnected(io, a, options, root, "WORK@example.com");
    try std.testing.expect(!try expired(io, a, options, &config, root, "work@example.com"));
    // A later process with the same explicit cache sees the marker.
    reset();
    try std.testing.expect(!try expired(io, a, options, &config, root, "work@example.com"));
}

test "reconnect fixture sign-in: without --cache-dir the reconnect stays in memory and writes nothing" {
    reset();
    defer reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // Stands in for the default cache root, which must stay untouched.
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/default-cache", .{temporary.sub_path});
    var config: Config = undefined;
    try config.defaults("/nonexistent/synthetic-home");
    const options: t.Options = .{ .fixtures = true, .fixture_scenario = scenario };
    try std.testing.expect(try expired(io, a, options, &config, root, "work@example.com"));
    try markReconnected(io, a, options, root, "work@example.com");
    try std.testing.expect(!try expired(io, a, options, &config, root, "work@example.com"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, root, .{}));
}

test "reconnect fixture sign-in: provider reads record a refusal while expired and a verified success after another process reconnected" {
    reset();
    defer reset();
    defer auth_diagnostic.reset();
    auth_diagnostic.reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/cache", .{temporary.sub_path});
    var config: Config = undefined;
    try config.defaults("/nonexistent/synthetic-home");
    const options: t.Options = .{ .fixtures = true, .fixture_scenario = scenario, .cache_dir = root };
    try std.testing.expectError(error.InvalidGrant, check(io, a, options, &config, root, "work@example.com"));
    try std.testing.expectEqual(auth_diagnostic.Observed.failed, auth_diagnostic.observed("work@example.com").observed);
    // Another fixture process records the reconnect; this one only sees the marker.
    try markReconnected(io, a, options, root, "work@example.com");
    reset();
    try check(io, a, options, &config, root, "work@example.com");
    try std.testing.expectEqual(auth_diagnostic.Observed.ok, auth_diagnostic.observed("work@example.com").observed);
}
