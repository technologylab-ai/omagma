//! Ephemeral-CI-only harness for the unchanged production Keychain dispatch.
const std = @import("std");
const keyring = @import("keyring");
extern fn SecKeychainCopyDefault(*?*const anyopaque) i32;
extern fn SecKeychainGetPath(*const anyopaque, *u32, [*]u8) i32;
extern fn CFRelease(*const anyopaque) void;
pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .macos or !std.mem.eql(u8, init.environ_map.get("CI") orelse "", "true") or !std.mem.eql(u8, init.environ_map.get("GITHUB_ACTIONS") orelse "", "true")) return error.EphemeralCIRequired;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const command = args.next() orelse return error.Args;
    if (std.mem.eql(u8, command, "keychain-worker")) {
        var fields: [5][]const u8 = undefined;
        for (&fields) |*field| field.* = args.next() orelse return error.Args;
        if (args.next() != null) return error.Args;
        return keyring.runNativeWorker(init.io, &fields);
    }
    if (!std.mem.eql(u8, command, "run")) return error.Args;
    const expected = args.next() orelse return error.Args;
    if (args.next() != null) return error.Args;
    var current: ?*const anyopaque = null;
    if (SecKeychainCopyDefault(&current) != 0 or current == null) return error.DefaultKeychainMismatch;
    defer CFRelease(current.?);
    var path: [4096]u8 = undefined;
    var length: u32 = path.len;
    if (SecKeychainGetPath(current.?, &length, &path) != 0 or length >= path.len) return error.DefaultKeychainMismatch;
    var canonical_actual: [4096]u8 = undefined;
    var canonical_expected: [4096]u8 = undefined;
    const actual_len = try std.Io.Dir.realPathFileAbsolute(init.io, std.fs.path.dirname(path[0..length]) orelse return error.DefaultKeychainMismatch, &canonical_actual);
    const expected_len = try std.Io.Dir.realPathFileAbsolute(init.io, std.fs.path.dirname(expected) orelse return error.DefaultKeychainMismatch, &canonical_expected);
    if (!std.mem.eql(u8, canonical_actual[0..actual_len], canonical_expected[0..expected_len])) return error.DefaultKeychainMismatch;
    // Legacy SecKeychain may expose its logical name or the backing -db file.
    const actual_leaf = std.fs.path.basename(path[0..length]);
    const expected_leaf = std.fs.path.basename(expected);
    if (!std.mem.eql(u8, actual_leaf, expected_leaf) and !(actual_leaf.len == expected_leaf.len + 3 and std.mem.startsWith(u8, actual_leaf, expected_leaf) and std.mem.endsWith(u8, actual_leaf, "-db"))) return error.DefaultKeychainMismatch;
    const account = "synthetic-default@example.invalid";
    const other = "synthetic-default-other@example.invalid";
    const client = "synthetic-default-client";
    const second_client = "synthetic-default-client-other";
    const grant = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var output: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    if (try keyring.lookup(init.io, account, &output) != null or try keyring.lookupTerminal(init.io, account, client, grant, &output) != null) return error.SyntheticItemAlreadyExists;
    defer keyring.clear(init.io, account) catch {};
    defer keyring.clear(init.io, other) catch {};
    defer keyring.clearTerminal(init.io, account) catch {};
    try keyring.store(init.io, account, "synthetic-default-bar");
    try keyring.store(init.io, other, "synthetic-default-other");
    try keyring.storeTerminal(init.io, account, client, grant, "synthetic-default-terminal");
    try keyring.storeTerminal(init.io, account, second_client, grant, "synthetic-default-client-other");
    try std.testing.expectEqualStrings("synthetic-default-bar", (try keyring.lookup(init.io, account, &output)).?);
    try std.testing.expectEqualStrings("synthetic-default-bar", (try keyring.lookupAutomatic(init.io, account, &output)).?);
    try std.testing.expectEqualStrings("synthetic-default-terminal", (try keyring.lookupTerminal(init.io, account, client, grant, &output)).?);
    var maximum: [4096]u8 = @splat('x');
    defer std.crypto.secureZero(u8, &maximum);
    try keyring.store(init.io, account, &maximum);
    try std.testing.expectEqualStrings(&maximum, (try keyring.lookup(init.io, account, &output)).?);
    try keyring.storeTerminal(init.io, account, client, grant, "synthetic-default-updated");
    try std.testing.expectEqualStrings("synthetic-default-updated", (try keyring.lookupTerminal(init.io, account, client, grant, &output)).?);
    try keyring.clearTerminal(init.io, account);
    if (try keyring.lookupTerminal(init.io, account, client, grant, &output) != null or try keyring.lookupTerminal(init.io, account, second_client, grant, &output) != null) return error.SyntheticItemStillExists;
    try std.testing.expectEqualStrings(&maximum, (try keyring.lookup(init.io, account, &output)).?);
    try std.testing.expectEqualStrings("synthetic-default-other", (try keyring.lookup(init.io, other, &output)).?);
    try keyring.clear(init.io, account);
    if (try keyring.lookup(init.io, account, &output) != null or try keyring.lookupAutomatic(init.io, account, &output) != null) return error.SyntheticItemStillExists;
    try keyring.clear(init.io, other);
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS production default dispatch:scoped native store/read/auto/update/clear/4096/isolation\n");
}
