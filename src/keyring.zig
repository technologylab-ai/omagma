const std = @import("std");
const builtin = @import("builtin");
const native = @import("keyring_darwin.zig");
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
    if (builtin.os.tag == .macos) return nativeLookup(io, "lookup", false, address, "", "", out);
    const n = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "lookup", "service", service, "account", address }, @as(?[]const u8, null), out, true });
    if (n == 0) return null;
    const secret = std.mem.trimEnd(u8, out[0..n], "\r\n");
    try validSecret(secret);
    return secret;
}
/// Background search deliberately omits --unlock. GNOME secret-tool only
/// requests SECRET_SEARCH_UNLOCK when that option is explicitly supplied.
/// Manual lookup retains its original interactive behavior.
pub fn lookupAutomatic(io: std.Io, address: []const u8, out: []u8) !?[]const u8 {
    try addressValid(address);
    if (out.len == 0 or out.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out);
    if (builtin.os.tag == .macos) return nativeLookup(io, "lookup-auto", false, address, "", "", out);
    var capture: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &capture);
    const n = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "search", "service", service, "account", address }, @as(?[]const u8, null), &capture, true });
    return try automaticSecret(capture[0..n], out);
}
fn automaticSecret(capture: []const u8, out: []u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, capture, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "secret = ")) continue;
        if (found != null) return error.KeyringUnavailable;
        const value = std.mem.trimEnd(u8, line["secret = ".len..], "\r");
        try validSecret(value);
        found = value;
    }
    const value = found orelse return null;
    if (value.len > out.len) return error.SecretOutputTooLarge;
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}
pub fn store(io: std.Io, address: []const u8, secret: []const u8) !void {
    try addressValid(address);
    try validSecret(secret);
    if (builtin.os.tag == .macos) {
        var output: [1]u8 = undefined;
        _ = try nativeCall(io, "store", false, address, "", "", secret, &output);
        return;
    }
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "store", "--label=omagma read-only refresh token", "service", service, "account", address }, @as(?[]const u8, secret), out[0..], false });
}
pub fn clear(io: std.Io, address: []const u8) !void {
    try addressValid(address);
    if (builtin.os.tag == .macos) {
        var output: [1]u8 = undefined;
        _ = try nativeCall(io, "clear", false, address, "", "", null, &output);
        return;
    }
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "clear", "service", service, "account", address }, @as(?[]const u8, null), out[0..], false });
}

/// Scope/client identity forms part of the lookup, never a write-token fallback
/// for the bar. OAuth client/grant identifiers are public metadata, not secrets.
pub fn lookupTerminal(io: std.Io, address: []const u8, client_id: []const u8, grant_id: []const u8, out: []u8) !?[]const u8 {
    try terminalIdentity(address, client_id, grant_id);
    if (out.len == 0 or out.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out);
    if (builtin.os.tag == .macos) return nativeLookup(io, "lookup", true, address, client_id, grant_id, out);
    const n = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "lookup", "service", terminal_service, "account", address, "client", client_id, "grant", grant_id }, @as(?[]const u8, null), out, true });
    if (n == 0) return null;
    const secret = std.mem.trimEnd(u8, out[0..n], "\r\n");
    try validSecret(secret);
    return secret;
}
pub fn storeTerminal(io: std.Io, address: []const u8, client_id: []const u8, grant_id: []const u8, secret: []const u8) !void {
    try terminalIdentity(address, client_id, grant_id);
    try validSecret(secret);
    if (builtin.os.tag == .macos) {
        var output: [1]u8 = undefined;
        _ = try nativeCall(io, "store", true, address, client_id, grant_id, secret, &output);
        return;
    }
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "store", "--label=omagma terminal refresh token", "service", terminal_service, "account", address, "client", client_id, "grant", grant_id }, @as(?[]const u8, secret), out[0..], false });
}
pub fn clearTerminal(io: std.Io, address: []const u8) !void {
    try addressValid(address);
    if (builtin.os.tag == .macos) {
        var output: [1]u8 = undefined;
        _ = try nativeCall(io, "clear", true, address, "", "", null, &output);
        return;
    }
    var out: [1]u8 = undefined;
    _ = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &.{ "/usr/bin/secret-tool", "clear", "service", terminal_service, "account", address }, @as(?[]const u8, null), out[0..], false });
}
fn terminalIdentity(address: []const u8, client_id: []const u8, grant_id: []const u8) !void {
    try addressValid(address);
    if (client_id.len == 0 or client_id.len > 4096 or grant_id.len != 64) return error.InvalidGrantIdentity;
    for (client_id) |c| if (c <= 32 or c >= 127) return error.InvalidGrantIdentity;
    for (grant_id) |c| if (!std.ascii.isHex(c)) return error.InvalidGrantIdentity;
}
fn nativeLookup(io: std.Io, operation: []const u8, terminal: bool, address: []const u8, client: []const u8, grant: []const u8, out: []u8) !?[]const u8 {
    const n = try nativeCall(io, operation, terminal, address, client, grant, null, out);
    if (n == 0) return null;
    try validSecret(out[0..n]);
    return out[0..n];
}
fn nativeCall(io: std.Io, operation: []const u8, terminal: bool, address: []const u8, client: []const u8, grant: []const u8, secret: ?[]const u8, out: []u8) !usize {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var executable: [4096]u8 = undefined;
    const length = try std.process.executablePath(io, &executable);
    var input: [native.marker.len + limits.secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &input);
    @memcpy(input[0..native.marker.len], native.marker);
    const payload = secret orelse "";
    if (payload.len > limits.secret) return error.InvalidToken;
    @memcpy(input[native.marker.len..][0..payload.len], payload);
    const argv = [_][]const u8{ executable[0..length], "keychain-worker", operation, if (terminal) "terminal" else "bar", address, client, grant };
    if (std.mem.eql(u8, operation, "lookup") or std.mem.eql(u8, operation, "lookup-auto")) {
        // Native absence is successful empty output; worker exit1 is failure.
        return platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &argv, @as(?[]const u8, input[0 .. native.marker.len + payload.len]), out, false });
    }
    var acknowledgement: [3]u8 = undefined;
    const n = try platform.deadline(io, platform.seconds(limits.keyring_seconds), run, .{ io, &argv, @as(?[]const u8, input[0 .. native.marker.len + payload.len]), &acknowledgement, false });
    if (n != acknowledgement.len or !std.mem.eql(u8, &acknowledgement, "OK\n")) return error.KeyringUnavailable;
    return 0;
}
/// Hidden exec-worker entry, with pipe-only output; never a JSON/UI token API.
pub fn runNativeWorker(io: std.Io, args: []const []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    return native.worker(io, args);
}
pub fn upgradeProbe(io: std.Io, phase: []const u8, directory: []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const operation = if (std.mem.eql(u8, phase, "create")) "upgrade-create" else if (std.mem.eql(u8, phase, "check")) "upgrade-check" else if (std.mem.eql(u8, phase, "verify")) "upgrade-verify" else if (std.mem.eql(u8, phase, "clear")) "upgrade-clear" else if (std.mem.eql(u8, phase, "absent")) "upgrade-absent" else if (std.mem.eql(u8, phase, "write")) "upgrade-write" else if (std.mem.eql(u8, phase, "delete")) "upgrade-delete" else return error.InvalidKeychainWorker;
    var output: [1]u8 = undefined;
    _ = try nativeCall(io, operation, false, "synthetic-probe-do-not-use@example.invalid", "", "", directory, &output);
}
fn run(io: std.Io, argv: []const []const u8, input: ?[]const u8, out: []u8, allow_absent: bool) anyerror!usize {
    var child = try std.process.spawn(io, .{ .argv = argv, .pgid = if (builtin.os.tag == .macos) 0 else null, .stdin = if (input != null) .pipe else .ignore, .stdout = .pipe, .stderr = .ignore, .request_resource_usage_statistics = true });
    defer {
        platform.closePipes(&child, io);
        if (child.id) |pid| {
            if (builtin.os.tag == .macos) std.posix.kill(-pid, .KILL) catch {};
            platform.killOwned(io, &child);
        }
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
    const term = try platform.waitOwned(io, &child);
    @atomicStore(usize, &last_child_peak_rss, child.resource_usage_statistics.getMaxRss() orelse 0, .release);
    switch (term) {
        .exited => |code| if (code == 0) return n else if (code == 1 and n == 0 and allow_absent) return 0 else return error.KeyringUnavailable,
        else => return error.KeyringUnavailable,
    }
}

pub fn syntheticProbe(io: std.Io) !void {
    const account = "synthetic-probe-do-not-use@example.invalid";
    if (builtin.os.tag == .macos) {
        var random: [16]u8 = undefined;
        io.random(&random);
        var path_buffer: [192]u8 = undefined;
        const directory = try std.fmt.bufPrint(&path_buffer, "/tmp/omagma-keychain-probe-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try std.Io.Dir.createDirAbsolute(io, directory, .fromMode(0o700));
        // Parent owns cleanup even if a synchronous native worker is killed.
        defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
        _ = try nativeCall(io, "probe", false, account, "", "", directory, &probe_output);
        return;
    }
    const secret = "synthetic-omagma-token-not-a-credential";
    if (try lookup(io, account, &probe_output) != null) return error.SyntheticItemAlreadyExists;
    try store(io, account, secret);
    defer clear(io, account) catch {};
    const value = (try lookup(io, account, &probe_output)) orelse return error.SyntheticItemMissing;
    try std.testing.expectEqualStrings(secret, value);
    std.crypto.secureZero(u8, &probe_output);
    const automatic = (try lookupAutomatic(io, account, &probe_output)) orelse return error.SyntheticItemMissing;
    try std.testing.expectEqualStrings(secret, automatic);
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

test "automatic keyring capture accepts one secret without exposing attributes" {
    var out: [limits.secret]u8 = undefined;
    const value = (try automaticSecret("[/synthetic/item]\nattribute.account = personal@example.com\nsecret = synthetic-refresh-only\n", &out)).?;
    try std.testing.expectEqualStrings("synthetic-refresh-only", value);
    try std.testing.expect(try automaticSecret("[/synthetic/locked-item]\nlabel = synthetic\n", &out) == null);
    try std.testing.expectError(error.KeyringUnavailable, automaticSecret("secret = synthetic-one\nsecret = synthetic-two\n", &out));
    try std.testing.expectError(error.InvalidToken, automaticSecret("secret = \n", &out));
    try std.testing.expectError(error.SecretOutputTooLarge, automaticSecret("secret = synthetic-token\n", out[0..4]));
}

/// Failure-path subprocess probes use only installed utilities and synthetic data.
pub fn failureProbe(io: std.Io) !void {
    try platform.waitCancellationProbe(io);
    var bounded_output: [16]u8 = undefined;
    try std.testing.expectError(error.SecretOutputTooLarge, platform.deadline(io, platform.seconds(2), run, .{ io, &.{ "/usr/bin/head", "-c", "8192", "/dev/zero" }, @as(?[]const u8, null), bounded_output[0..], false }));
    const short: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) };
    try std.testing.expectError(error.Timeout, platform.deadline(io, short, run, .{ io, &.{ if (builtin.os.tag == .macos) "/bin/sleep" else "/usr/bin/sleep", "20" }, @as(?[]const u8, null), bounded_output[0..], false }));
}

pub const reservation_bytes = @sizeOf(@TypeOf(probe_output)) + @sizeOf(@TypeOf(last_child_peak_rss)) + 64;
