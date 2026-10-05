const std = @import("std");
const limits = @import("limits.zig");
const platform = @import("platform.zig");
pub const service = "io.github.technologylab_ai.omagma";
pub const terminal_service = "io.github.technologylab_ai.omagma.terminal";
pub var last_child_peak_rss: usize = 0;

fn addressValid(address: []const u8) !void {
    if (address.len == 0 or address.len > limits.max_address or std.mem.indexOfScalar(u8, address, '@') == null) return error.InvalidAccount;
    for (address) |b| if (b <= 32 or b >= 127) return error.InvalidAccount;
}
fn validSecret(secret: []const u8) !void {
    if (secret.len == 0 or secret.len > limits.secret) return error.InvalidToken;
    for (secret) |b| if (b <= 32 or b >= 127) return error.InvalidToken;
}

/// Exact account identity is a Secret Service attribute, never a cross-account search.
pub fn lookup(io: std.Io, address: []const u8, out: []u8) !?[]const u8 {
    try addressValid(address);
    if (out.len == 0 or out.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out);
    const n = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "lookup", "service", service, "account", address }, @as(?[]const u8, null), out, true });
    if (n == 0) return null;
    const secret = std.mem.trimEnd(u8, out[0..n], "\r\n");
    try validSecret(secret);
    return secret;
}
pub fn store(io: std.Io, address: []const u8, secret: []const u8) !void {
    try addressValid(address);
    try validSecret(secret);
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "store", "--label=omagma read-only refresh token", "service", service, "account", address }, @as(?[]const u8, secret), out[0..], false });
}
pub fn clear(io: std.Io, address: []const u8) !void {
    try addressValid(address);
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "clear", "service", service, "account", address }, @as(?[]const u8, null), out[0..], false });
}

/// Scope/client identity forms part of the lookup, never a write-token fallback
/// for the bar. OAuth client/grant identifiers are public metadata, not secrets.
pub fn lookupTerminal(io: std.Io, address: []const u8, client_id: []const u8, grant_id: []const u8, out: []u8) !?[]const u8 {
    try terminalIdentity(address, client_id, grant_id);
    if (out.len == 0 or out.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out);
    const n = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "lookup", "service", terminal_service, "account", address, "client", client_id, "grant", grant_id }, @as(?[]const u8, null), out, true });
    if (n == 0) return null;
    const secret = std.mem.trimEnd(u8, out[0..n], "\r\n");
    try validSecret(secret);
    return secret;
}
pub fn storeTerminal(io: std.Io, address: []const u8, client_id: []const u8, grant_id: []const u8, secret: []const u8) !void {
    try terminalIdentity(address, client_id, grant_id);
    try validSecret(secret);
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "store", "--label=omagma terminal refresh token", "service", terminal_service, "account", address, "client", client_id, "grant", grant_id }, @as(?[]const u8, secret), out[0..], false });
}
pub fn clearTerminal(io: std.Io, address: []const u8) !void {
    try addressValid(address);
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "clear", "service", terminal_service, "account", address }, @as(?[]const u8, null), out[0..], false });
}
fn terminalIdentity(address: []const u8, client_id: []const u8, grant_id: []const u8) !void {
    try addressValid(address);
    if (client_id.len == 0 or client_id.len > 4096 or grant_id.len != 64) return error.InvalidGrantIdentity;
    for (client_id) |c| if (c <= 32 or c >= 127) return error.InvalidGrantIdentity;
    for (grant_id) |c| if (!std.ascii.isHex(c)) return error.InvalidGrantIdentity;
}
fn run(io: std.Io, argv: []const []const u8, input: ?[]const u8, out: []u8, allow_absent: bool) anyerror!usize {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = if (input != null) .pipe else .ignore, .stdout = .pipe, .stderr = .ignore, .request_resource_usage_statistics = true });
    defer {
        platform.closePipes(&child, io);
        if (child.id != null) child.kill(io);
    }
    if (input) |secret| {
        var writer = child.stdin.?.writerStreaming(io, &.{});
        try writer.interface.writeAll(secret);
        try writer.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var n: usize = 0;
    while (n < out.len) {
        const count = child.stdout.?.readStreaming(io, &.{out[n..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (count == 0) break;
        n += count;
    }
    if (n == out.len) {
        var extra: [1]u8 = undefined;
        const trailing = child.stdout.?.readStreaming(io, &.{&extra}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (trailing != 0) {
            if (!allow_absent or extra[0] != '\n') return error.SecretOutputTooLarge;
            const more = child.stdout.?.readStreaming(io, &.{&extra}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (more != 0) return error.SecretOutputTooLarge;
        }
    }
    platform.closePipes(&child, io);
    const term = try child.wait(io);
    @atomicStore(usize, &last_child_peak_rss, child.resource_usage_statistics.getMaxRss() orelse 0, .release);
    switch (term) {
        .exited => |code| if (code == 0) return n else if (code == 1 and n == 0 and allow_absent) return 0 else return error.KeyringUnavailable,
        else => return error.KeyringUnavailable,
    }
}

pub fn syntheticProbe(io: std.Io) !void {
    const account = "synthetic-probe-do-not-use@example.invalid";
    const secret = "synthetic-omagma-token-not-a-credential";
    if (try lookup(io, account, &probe_output) != null) return error.SyntheticItemAlreadyExists;
    try store(io, account, secret);
    defer clear(io, account) catch {};
    const value = (try lookup(io, account, &probe_output)) orelse return error.SyntheticItemMissing;
    try std.testing.expectEqualStrings(secret, value);
    std.crypto.secureZero(u8, &probe_output);
    try clear(io, account);
    if (try lookup(io, account, &probe_output) != null) return error.SyntheticItemStillExists;
}
var probe_output: [limits.secret]u8 = undefined;

test "keyring identity and token validation reject controls" {
    try addressValid("account@example.invalid");
    try std.testing.expectError(error.InvalidAccount, addressValid("account\n@example.invalid"));
    try std.testing.expectError(error.InvalidToken, validSecret("token\n"));
}

/// Failure-path subprocess probes use only installed utilities and synthetic data.
pub fn failureProbe(io: std.Io) !void {
    var bounded_output: [16]u8 = undefined;
    try std.testing.expectError(error.SecretOutputTooLarge, platform.deadline(io, platform.seconds(2), run, .{ io, &.{ "/usr/bin/head", "-c", "8192", "/dev/zero" }, @as(?[]const u8, null), bounded_output[0..], false }));
    const short: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) };
    try std.testing.expectError(error.Timeout, platform.deadline(io, short, run, .{ io, &.{ "/usr/bin/sleep", "20" }, @as(?[]const u8, null), bounded_output[0..], false }));
}

pub const reservation_bytes = @sizeOf(@TypeOf(probe_output)) + @sizeOf(@TypeOf(last_child_peak_rss)) + 64;
