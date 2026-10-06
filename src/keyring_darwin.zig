//! Native Keychain code runs only in an exec-self worker with private pipes.
//! Security.framework is synchronous; the parent owns its finite deadline.
const std = @import("std");
const limits = @import("limits.zig");
pub const marker = "OMAGMA-KEYCHAIN1\n";
pub const bar_service = "io.github.technologylab_ai.omagma";
pub const terminal_service = "io.github.technologylab_ai.omagma.terminal";
const CF = *const anyopaque;
const MutableCF = *anyopaque;
const Callbacks = extern struct { version: isize, retain: ?*const anyopaque, release: ?*const anyopaque, description: ?*const anyopaque, equal: ?*const anyopaque };
const KeyCallbacks = extern struct { version: isize, retain: ?*const anyopaque, release: ?*const anyopaque, description: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
extern var kCFTypeDictionaryKeyCallBacks: KeyCallbacks;
extern var kCFTypeDictionaryValueCallBacks: Callbacks;
extern var kCFTypeArrayCallBacks: Callbacks;
extern var kCFBooleanTrue: CF;
extern var kCFBooleanFalse: CF;
extern var kSecClass: CF;
extern var kSecClassGenericPassword: CF;
extern var kSecAttrService: CF;
extern var kSecAttrAccount: CF;
extern var kSecAttrLabel: CF;
extern var kSecAttrGeneric: CF;
extern var kSecAttrSynchronizable: CF;
extern var kSecValueData: CF;
extern var kSecReturnData: CF;
extern var kSecReturnAttributes: CF;
extern var kSecMatchLimit: CF;
extern var kSecMatchLimitOne: CF;
extern var kSecMatchLimitAll: CF;
extern var kSecUseAuthenticationUI: CF;
extern var kSecUseAuthenticationUIFail: CF;
extern var kSecUseKeychain: CF;
extern var kSecMatchSearchList: CF;
extern fn CFStringCreateWithBytes(?CF, [*]const u8, isize, u32, u8) ?CF;
extern fn CFDataCreate(?CF, [*]const u8, isize) ?CF;
extern fn CFDataGetLength(CF) isize;
extern fn CFDataGetBytePtr(CF) ?[*]const u8;
extern fn CFGetTypeID(CF) usize;
extern fn CFDataGetTypeID() usize;
extern fn CFStringGetTypeID() usize;
extern fn CFStringGetCString(CF, [*]u8, isize, u32) u8;
extern fn CFDictionaryGetTypeID() usize;
extern fn CFDictionaryGetValue(CF, CF) ?CF;
extern fn CFArrayGetTypeID() usize;
extern fn CFArrayGetCount(CF) isize;
extern fn CFArrayGetValueAtIndex(CF, isize) CF;
extern fn CFDictionaryCreateMutable(?CF, isize, *const KeyCallbacks, *const Callbacks) ?MutableCF;
extern fn CFDictionarySetValue(MutableCF, CF, CF) void;
extern fn CFArrayCreate(?CF, [*]const CF, isize, *const Callbacks) ?CF;
extern fn CFRelease(CF) void;
extern fn SecItemCopyMatching(CF, *?CF) i32;
extern fn SecItemAdd(CF, ?*?CF) i32;
extern fn SecItemUpdate(CF, CF) i32;
extern fn SecItemDelete(CF) i32;
extern fn SecKeychainSetUserInteractionAllowed(u8) i32;
extern fn SecKeychainCreate([*:0]const u8, u32, [*]const u8, u8, ?CF, *?CF) i32;
extern fn SecKeychainDelete(CF) i32;
const not_found = -25300;
const duplicate = -25299;

const Identity = struct {
    terminal: bool,
    account: []const u8,
    client: []const u8 = "",
    grant: []const u8 = "",
    fn validate(self: Identity, clearing: bool) !void {
        if (self.account.len == 0 or self.account.len > limits.max_address or std.mem.indexOfScalar(u8, self.account, '@') == null) return error.InvalidAccount;
        for (self.account) |c| if (c <= 32 or c >= 127) return error.InvalidAccount;
        if (!self.terminal or clearing) {
            if (self.client.len != 0 or self.grant.len != 0) return error.InvalidGrantIdentity;
        } else {
            if (self.client.len == 0 or self.client.len > 4096 or self.grant.len != 64) return error.InvalidGrantIdentity;
            for (self.client) |c| if (c <= 32 or c >= 127) return error.InvalidGrantIdentity;
            for (self.grant) |c| if (!std.ascii.isHex(c)) return error.InvalidGrantIdentity;
        }
    }
    fn namespace(self: Identity) []const u8 {
        return if (self.terminal) terminal_service else bar_service;
    }
    fn service(self: Identity, buffer: []u8) ![]const u8 {
        if (!self.terminal) return bar_service;
        var digest: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(self.client);
        hash.update(&.{0});
        hash.update(self.grant);
        hash.final(&digest);
        return std.fmt.bufPrint(buffer, "{s}.{s}", .{ terminal_service, std.fmt.bytesToHex(digest, .lower) });
    }
};
const Dictionary = struct {
    value: MutableCF,
    fn init() !Dictionary {
        return .{ .value = CFDictionaryCreateMutable(null, 10, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory };
    }
    fn deinit(self: Dictionary) void {
        CFRelease(self.value);
    }
    fn set(self: Dictionary, key: CF, value: CF) void {
        CFDictionarySetValue(self.value, key, value);
    }
    fn string(self: Dictionary, key: CF, raw: []const u8) !void {
        const value = CFStringCreateWithBytes(null, raw.ptr, @intCast(raw.len), 0x08000100, 0) orelse return error.OutOfMemory;
        defer CFRelease(value);
        self.set(key, value);
    }
    fn data(self: Dictionary, key: CF, raw: []const u8) !void {
        const value = CFDataCreate(null, raw.ptr, @intCast(raw.len)) orelse return error.OutOfMemory;
        defer CFRelease(value);
        self.set(key, value);
    }
};
fn query(identity: Identity, keychain: ?CF, adding: bool, clearing: bool) !Dictionary {
    var result = try Dictionary.init();
    errdefer result.deinit();
    result.set(kSecClass, kSecClassGenericPassword);
    try result.string(kSecAttrLabel, identity.namespace());
    try result.string(kSecAttrAccount, identity.account);
    result.set(kSecAttrSynchronizable, kCFBooleanFalse);
    result.set(kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    if (!identity.terminal or !clearing) {
        var service_buffer: [192]u8 = undefined;
        try result.string(kSecAttrService, try identity.service(&service_buffer));
        if (identity.terminal) {
            var generic: [4096 + 1 + 64]u8 = undefined;
            @memcpy(generic[0..identity.client.len], identity.client);
            generic[identity.client.len] = 0;
            @memcpy(generic[identity.client.len + 1 ..][0..identity.grant.len], identity.grant);
            try result.data(kSecAttrGeneric, generic[0 .. identity.client.len + 1 + identity.grant.len]);
        }
    }
    if (keychain) |ref| {
        if (adding) result.set(kSecUseKeychain, ref) else {
            const refs = [_]CF{ref};
            const list = CFArrayCreate(null, &refs, 1, &kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
            defer CFRelease(list);
            result.set(kSecMatchSearchList, list);
        }
    }
    return result;
}
fn validSecret(raw: []const u8) !void {
    if (raw.len == 0 or raw.len > limits.secret) return error.InvalidToken;
    for (raw) |c| if (c <= 32 or c >= 127) return error.InvalidToken;
}
fn lookup(identity: Identity, keychain: ?CF, out: []u8) !usize {
    const request = try query(identity, keychain, false, false);
    defer request.deinit();
    request.set(kSecReturnData, kCFBooleanTrue);
    request.set(kSecMatchLimit, kSecMatchLimitOne);
    var result: ?CF = null;
    const status = SecItemCopyMatching(request.value, &result);
    defer if (result) |value| CFRelease(value);
    if (status == not_found) return 0;
    if (status != 0 or result == null) return error.KeyringUnavailable;
    const value = result.?;
    if (CFGetTypeID(value) != CFDataGetTypeID()) return error.KeyringUnavailable;
    const length = CFDataGetLength(value);
    if (length <= 0 or length > limits.secret or length > out.len) return error.SecretOutputTooLarge;
    const bytes = CFDataGetBytePtr(value) orelse return error.KeyringUnavailable;
    const raw = bytes[0..@intCast(length)];
    try validSecret(raw);
    @memcpy(out[0..raw.len], raw);
    return raw.len;
}
fn store(identity: Identity, keychain: ?CF, secret: []const u8) !void {
    try validSecret(secret);
    const request = try query(identity, keychain, false, false);
    defer request.deinit();
    const changed = try Dictionary.init();
    defer changed.deinit();
    try changed.data(kSecValueData, secret);
    const updated = SecItemUpdate(request.value, changed.value);
    if (updated == 0) return;
    if (updated != not_found) return error.KeyringUnavailable;
    const adding = try query(identity, keychain, true, false);
    defer adding.deinit();
    try adding.data(kSecValueData, secret);
    const created = SecItemAdd(adding.value, null);
    if (created == duplicate) {
        if (SecItemUpdate(request.value, changed.value) != 0) return error.KeyringUnavailable;
    } else if (created != 0) return error.KeyringUnavailable;
}
fn clear(identity: Identity, keychain: ?CF) !void {
    const request = try query(identity, keychain, false, true);
    defer request.deinit();
    if (identity.terminal) {
        // Labels are mutable display data. Validate the actual primary-key
        // service namespace before deleting each matching account/grant item.
        request.set(kSecReturnAttributes, kCFBooleanTrue);
        request.set(kSecMatchLimit, kSecMatchLimitAll);
        var returned: ?CF = null;
        const status = SecItemCopyMatching(request.value, &returned);
        defer if (returned) |value| CFRelease(value);
        if (status == not_found) return;
        if (status != 0 or returned == null or CFGetTypeID(returned.?) != CFArrayGetTypeID()) return error.KeyringUnavailable;
        const count = CFArrayGetCount(returned.?);
        if (count < 0 or count > 128) return error.KeyringUnavailable;
        var services: [128][192]u8 = undefined;
        var lengths: [128]usize = @splat(0);
        // Finish validating the bounded response before making any changes.
        for (0..@intCast(count)) |index| {
            const item = CFArrayGetValueAtIndex(returned.?, @intCast(index));
            if (CFGetTypeID(item) != CFDictionaryGetTypeID()) return error.KeyringUnavailable;
            const value = CFDictionaryGetValue(item, kSecAttrService) orelse return error.KeyringUnavailable;
            if (CFGetTypeID(value) != CFStringGetTypeID() or CFStringGetCString(value, &services[index], services[index].len, 0x08000100) == 0) return error.KeyringUnavailable;
            const text = std.mem.sliceTo(&services[index], 0);
            if (terminalService(text)) lengths[index] = text.len;
        }
        for (lengths[0..@intCast(count)], 0..) |length, index| {
            if (length == 0) continue;
            const deleting = try query(identity, keychain, false, true);
            defer deleting.deinit();
            try deleting.string(kSecAttrService, services[index][0..length]);
            const deleted = SecItemDelete(deleting.value);
            if (deleted != 0 and deleted != not_found) return error.KeyringUnavailable;
        }
        return;
    }
    const status = SecItemDelete(request.value);
    if (status != 0 and status != not_found) return error.KeyringUnavailable;
}

fn terminalService(raw: []const u8) bool {
    if (std.mem.eql(u8, raw, terminal_service)) return true;
    if (raw.len != terminal_service.len + 1 + 64 or !std.mem.startsWith(u8, raw, terminal_service) or raw[terminal_service.len] != '.') return false;
    for (raw[terminal_service.len + 1 ..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn worker(io: std.Io, args: []const []const u8) !void {
    if (args.len != 5) return error.InvalidKeychainWorker;
    if ((try std.Io.File.stdin().stat(io)).kind != .named_pipe or (try std.Io.File.stdout().stat(io)).kind != .named_pipe) return error.PrivateKeychainPipesRequired;
    const terminal = if (std.mem.eql(u8, args[1], "bar")) false else if (std.mem.eql(u8, args[1], "terminal")) true else return error.InvalidKeychainNamespace;
    const identity: Identity = .{ .terminal = terminal, .account = args[2], .client = args[3], .grant = args[4] };
    const probing = std.mem.eql(u8, args[0], "probe");
    const clearing = std.mem.eql(u8, args[0], "clear");
    try identity.validate(clearing);
    var input: [marker.len + limits.secret + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &input);
    var scratch: [256]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &scratch);
    var length: usize = 0;
    while (length < input.len) {
        const count = try reader.interface.readSliceShort(input[length..]);
        if (count == 0) break;
        length += count;
    }
    if (length < marker.len or length == input.len or !std.mem.eql(u8, input[0..marker.len], marker)) return error.InvalidKeychainWorker;
    const secret = input[marker.len..length];
    // This affects only the short-lived worker, including legacy keychains.
    if (SecKeychainSetUserInteractionAllowed(0) != 0) return error.KeyringUnavailable;
    if (probing) {
        if (terminal or !std.mem.eql(u8, identity.account, "synthetic-probe-do-not-use@example.invalid") or secret.len != 0) return error.InvalidKeychainWorker;
        return synthetic(io);
    }
    if (std.mem.eql(u8, args[0], "store")) return store(identity, null, secret);
    if (secret.len != 0) return error.InvalidKeychainWorker;
    if (clearing) return clear(identity, null);
    if (!std.mem.eql(u8, args[0], "lookup") and !std.mem.eql(u8, args[0], "lookup-auto")) return error.InvalidKeychainWorker;
    var output: [limits.secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    const n = try lookup(identity, null, &output);
    var writer = std.Io.File.stdout().writerStreaming(io, &.{});
    try writer.interface.writeAll(output[0..n]);
    try writer.interface.flush();
}

fn synthetic(io: std.Io) !void {
    var random: [16]u8 = undefined;
    io.random(&random);
    var path_buffer: [192]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, "/tmp/omagma-keychain-probe-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.createDirAbsolute(io, directory, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var keychain_path: [256]u8 = undefined;
    const filename = try std.fmt.bufPrintSentinel(&keychain_path, "{s}/fixture.keychain", .{directory}, 0);
    const password = "synthetic-keychain-pass-not-a-user-password";
    var reference: ?CF = null;
    if (SecKeychainCreate(filename, password.len, password.ptr, 0, null, &reference) != 0 or reference == null) return error.SyntheticKeychainUnavailable;
    const keychain = reference.?;
    defer CFRelease(keychain);
    defer _ = SecKeychainDelete(keychain);
    const account_a = "synthetic-a@example.invalid";
    const account_b = "synthetic-b@example.invalid";
    const bar_a: Identity = .{ .terminal = false, .account = account_a };
    const bar_b: Identity = .{ .terminal = false, .account = account_b };
    const term_a: Identity = .{ .terminal = true, .account = account_a, .client = "synthetic-client-a", .grant = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" };
    var term_other = term_a;
    term_other.client = "synthetic-client-b";
    var output: [limits.secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    if (try lookup(bar_a, keychain, &output) != 0) return error.SyntheticItemAlreadyExists;
    try store(bar_a, keychain, "synthetic-bar-a");
    try store(bar_b, keychain, "synthetic-bar-b");
    try store(term_a, keychain, "synthetic-terminal-a");
    try store(term_other, keychain, "synthetic-other-client");
    const foreign = try query(bar_a, keychain, true, false);
    defer foreign.deinit();
    try foreign.string(kSecAttrService, "io.example.unrelated-password");
    try foreign.string(kSecAttrLabel, terminal_service);
    try foreign.data(kSecValueData, "synthetic-unrelated-kept");
    if (SecItemAdd(foreign.value, null) != 0) return error.SyntheticKeychainUnavailable;
    const n = try lookup(bar_a, keychain, &output);
    if (!std.mem.eql(u8, output[0..n], "synthetic-bar-a")) return error.SyntheticIdentityMismatch;
    const m = try lookup(term_a, keychain, &output);
    if (!std.mem.eql(u8, output[0..m], "synthetic-terminal-a")) return error.SyntheticIdentityMismatch;
    try store(term_a, keychain, "synthetic-terminal-updated");
    const k = try lookup(term_a, keychain, &output);
    if (!std.mem.eql(u8, output[0..k], "synthetic-terminal-updated")) return error.SyntheticIdentityMismatch;
    const removed: Identity = .{ .terminal = true, .account = account_a };
    try clear(removed, keychain);
    if (try lookup(term_a, keychain, &output) != 0 or try lookup(term_other, keychain, &output) != 0) return error.SyntheticItemStillExists;
    if (try lookup(bar_a, keychain, &output) == 0 or try lookup(bar_b, keychain, &output) == 0) return error.SyntheticIdentityMismatch;
    const retained = try query(bar_a, keychain, false, false);
    defer retained.deinit();
    try retained.string(kSecAttrService, "io.example.unrelated-password");
    try retained.string(kSecAttrLabel, terminal_service);
    retained.set(kSecReturnData, kCFBooleanTrue);
    var unrelated: ?CF = null;
    const retained_status = SecItemCopyMatching(retained.value, &unrelated);
    defer if (unrelated) |value| CFRelease(value);
    if (retained_status != 0 or unrelated == null) return error.SyntheticNamespaceCrossed;
    try clear(bar_a, keychain);
    try clear(bar_b, keychain);
    if (SecKeychainDelete(keychain) != 0) return error.SyntheticKeychainCleanupFailed;
}

test "native keychain identity keeps account service client and grant distinct" {
    const a: Identity = .{ .terminal = true, .account = "account@example.invalid", .client = "client-a", .grant = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" };
    try a.validate(false);
    var b = a;
    b.client = "client-b";
    var left: [192]u8 = undefined;
    var right: [192]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, try a.service(&left), try b.service(&right)));
    try std.testing.expect(std.mem.startsWith(u8, try a.service(&left), terminal_service));
    try std.testing.expectError(error.InvalidToken, validSecret("invalid\n"));
    const other: Identity = .{ .terminal = false, .account = "other@example.invalid", .client = "client-a" };
    try std.testing.expectError(error.InvalidGrantIdentity, other.validate(false));
    try std.testing.expect(terminalService(terminal_service));
    try std.testing.expect(terminalService(try a.service(&left)));
    try std.testing.expect(!terminalService("io.example.unrelated-password"));
    try std.testing.expect(!terminalService(terminal_service ++ ".not-a-grant-digest"));
}
