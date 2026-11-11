//! --fixtures scenario "sign-in-expired": the second configured account's
//! stored Google sign-in is refused, exactly as Google refuses an expired or
//! policy-revoked refresh token, until a fixture reconnect completes for this
//! cache. Fixture consent runs the real loopback listener, PKCE, state, browser
//! launch and callback (oauth.authorizeFixture) against a synthetic consent
//! page; nothing reaches Google and nothing is written to a credential store.
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

pub fn active(options: t.Options) bool {
    return options.fixtures and std.mem.eql(u8, options.fixture_scenario, scenario);
}

fn marker(a: std.mem.Allocator, cache_root: []const u8, account: []const u8) ![]const u8 {
    var lowered: [254]u8 = undefined;
    if (account.len == 0 or account.len > lowered.len) return error.InvalidAddress;
    for (account, 0..) |byte, index| lowered[index] = std.ascii.toLower(byte);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lowered[0..account.len], &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(a, "{s}/fixture-sign-in-{s}", .{ cache_root, hex[0..16] });
}

/// Whether this account's synthetic sign-in is refused right now.
pub fn expired(io: std.Io, a: std.mem.Allocator, options: t.Options, config: *const Config, cache_root: []const u8, account: []const u8) !bool {
    if (!active(options)) return false;
    if ((config.index(account) orelse return false) != 1) return false;
    std.Io.Dir.cwd().access(io, try marker(a, cache_root, account), .{}) catch |err| {
        if (err == error.FileNotFound) return true;
        return err;
    };
    return false;
}

/// Record the refusal through the same diagnostic path as a real refresh.
pub fn refuse(io: std.Io, a: std.mem.Allocator, account: []const u8) anyerror {
    const parsed = std.json.parseFromSliceLeaky(j.Value, a, refusal, .{}) catch return error.InvalidGrant;
    auth_diagnostic.recordFailure(account, oauth.TokenError.fromJson(400, parsed), std.Io.Timestamp.now(io, .real).toMilliseconds());
    return error.InvalidGrant;
}

pub fn markReconnected(io: std.Io, a: std.mem.Allocator, cache_root: []const u8, account: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, cache_root, .fromMode(0o700));
    const file = try std.Io.Dir.cwd().createFile(io, try marker(a, cache_root, account), .{ .permissions = .fromMode(0o600), .truncate = true });
    file.close(io);
}

test "fixture sign-in: only the second account expires, until a reconnect marker exists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/cache", .{temporary.sub_path});
    var config: Config = undefined;
    try config.defaults("/nonexistent/synthetic-home");
    const options: t.Options = .{ .fixtures = true, .fixture_scenario = scenario };
    try std.testing.expect(!try expired(io, a, options, &config, root, "personal@example.com"));
    try std.testing.expect(try expired(io, a, options, &config, root, "work@example.com"));
    try std.testing.expect(!try expired(io, a, .{ .fixtures = true }, &config, root, "work@example.com"));
    try std.testing.expectEqual(error.InvalidGrant, refuse(io, a, "work@example.com"));
    try std.testing.expectEqualStrings("invalid_rapt", auth_diagnostic.observed("work@example.com").value.subtype.slice());
    try markReconnected(io, a, root, "WORK@example.com");
    try std.testing.expect(!try expired(io, a, options, &config, root, "work@example.com"));
    auth_diagnostic.reset();
}
