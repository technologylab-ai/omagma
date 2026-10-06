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
extern var kSecAttrAccess: CF;
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
extern fn SecKeychainOpen([*:0]const u8, *?CF) i32;
extern fn SecKeychainCopyDefault(*?CF) i32;
extern fn SecKeychainGetStatus(CF, *u32) i32;
extern fn SecKeychainGetPath(CF, *u32, [*]u8) i32;
extern fn SecKeychainLock(CF) i32;
extern fn SecKeychainUnlock(CF, u32, [*]const u8, u8) i32;
extern fn SecTrustedApplicationCreateFromPath(?[*:0]const u8, *?CF) i32;
extern fn SecAccessCreate(CF, ?CF, *?CF) i32;
extern "c" fn proc_pidpath(c_int, [*]u8, u32) c_int;
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
    if (adding) try result.string(kSecAttrLabel, identity.namespace());
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
    const access = try trustedAccess();
    defer CFRelease(access);
    adding.set(kSecAttrAccess, access);
    try adding.data(kSecValueData, secret);
    const created = SecItemAdd(adding.value, null);
    if (created == duplicate) {
        if (SecItemUpdate(request.value, changed.value) != 0) return error.KeyringUnavailable;
    } else if (created != 0) return error.KeyringUnavailable;
}

fn trustedAccess() !CF {
    var own: ?CF = null;
    var system: ?CF = null;
    if (SecTrustedApplicationCreateFromPath(null, &own) != 0 or SecTrustedApplicationCreateFromPath("/usr/bin/security", &system) != 0 or own == null or system == null) return error.KeyringUnavailable;
    defer CFRelease(own.?);
    defer CFRelease(system.?);
    const apps = [_]CF{ own.?, system.? };
    const list = CFArrayCreate(null, &apps, 2, &kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(list);
    const text = "Omagma account credential";
    const descriptor = CFStringCreateWithBytes(null, text.ptr, text.len, 0x08000100, 0) orelse return error.OutOfMemory;
    defer CFRelease(descriptor);
    var access: ?CF = null;
    if (SecAccessCreate(descriptor, list, &access) != 0 or access == null) return error.KeyringUnavailable;
    return access.?;
}

fn unlocked(keychain: CF) !void {
    var status: u32 = 0;
    if (SecKeychainGetStatus(keychain, &status) != 0 or status & 1 == 0) return error.KeyringUnavailable;
}

/// Only this exact default/probe keychain and primary key reach the signed
/// system tool. Native metadata and unlocked-state checks run with UI disabled.
fn lookupStable(io: std.Io, identity: Identity, keychain: CF, out: []u8) !usize {
    try unlocked(keychain);
    const request = try query(identity, keychain, false, false);
    defer request.deinit();
    request.set(kSecReturnAttributes, kCFBooleanTrue);
    request.set(kSecMatchLimit, kSecMatchLimitOne);
    var attributes: ?CF = null;
    const result = SecItemCopyMatching(request.value, &attributes);
    defer if (attributes) |value| CFRelease(value);
    if (result == not_found) return 0;
    if (result != 0 or attributes == null) return error.KeyringUnavailable;
    var path: [4096]u8 = undefined;
    var path_length: u32 = path.len;
    if (SecKeychainGetPath(keychain, &path_length, &path) != 0 or path_length == 0 or path_length >= path.len) return error.KeyringUnavailable;
    var service_buffer: [192]u8 = undefined;
    const service = try identity.service(&service_buffer);
    var child = try std.process.spawn(io, .{ .argv = &.{ "/usr/bin/security", "find-generic-password", "-s", service, "-a", identity.account, "-w", std.mem.sliceTo(&path, 0) }, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    defer {
        @import("platform.zig").closePipes(&child, io);
        if (child.id != null) child.kill(io);
    }
    var captured: [limits.secret + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &captured);
    var length: usize = 0;
    while (length < captured.len) {
        const n = child.stdout.?.readStreaming(io, &.{captured[length..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) break;
        length += n;
    }
    if (length == captured.len) return error.SecretOutputTooLarge;
    @import("platform.zig").closePipes(&child, io);
    try @import("platform.zig").checkedExit(try child.wait(io));
    try unlocked(keychain);
    const value = std.mem.trimEnd(u8, captured[0..length], "\r\n");
    try validSecret(value);
    if (value.len > out.len) return error.SecretOutputTooLarge;
    @memcpy(out[0..value.len], value);
    return value.len;
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
            if (CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
            const value = CFDictionaryGetValue(item, kSecAttrService) orelse continue;
            if (CFGetTypeID(value) != CFStringGetTypeID() or CFStringGetCString(value, &services[index], services[index].len, 0x08000100) == 0) continue;
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
    try checkParent(io);
    var alarm_action: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.ALRM, &alarm_action, null);
    _ = std.c.alarm(@intCast(limits.keyring_seconds + 2));
    if ((try std.Io.File.stdin().stat(io)).kind != .named_pipe or (try std.Io.File.stdout().stat(io)).kind != .named_pipe) return error.PrivateKeychainPipesRequired;
    const terminal = if (std.mem.eql(u8, args[1], "bar")) false else if (std.mem.eql(u8, args[1], "terminal")) true else return error.InvalidKeychainNamespace;
    const identity: Identity = .{ .terminal = terminal, .account = args[2], .client = args[3], .grant = args[4] };
    const probing = std.mem.eql(u8, args[0], "probe");
    const clearing = std.mem.eql(u8, args[0], "clear");
    try identity.validate(clearing);
    var input: [marker.len + limits.secret + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &input);
    var scratch: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
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
    if (std.mem.startsWith(u8, args[0], "upgrade-")) {
        if (terminal or !std.mem.eql(u8, identity.account, "synthetic-probe-do-not-use@example.invalid")) return error.InvalidKeychainWorker;
        try upgradeProbe(io, args[0], secret);
        return acknowledgement(io);
    }
    if (probing) {
        if (terminal or !std.mem.eql(u8, identity.account, "synthetic-probe-do-not-use@example.invalid") or secret.len == 0) return error.InvalidKeychainWorker;
        try synthetic(io, secret);
        return acknowledgement(io);
    }
    var default_ref: ?CF = null;
    if (SecKeychainCopyDefault(&default_ref) != 0 or default_ref == null) return error.KeyringUnavailable;
    defer CFRelease(default_ref.?);
    try unlocked(default_ref.?);
    if (std.mem.eql(u8, args[0], "store")) {
        try store(identity, default_ref, secret);
        return acknowledgement(io);
    }
    if (secret.len != 0) return error.InvalidKeychainWorker;
    if (clearing) {
        try clear(identity, default_ref);
        return acknowledgement(io);
    }
    if (!std.mem.eql(u8, args[0], "lookup") and !std.mem.eql(u8, args[0], "lookup-auto")) return error.InvalidKeychainWorker;
    var output: [limits.secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    const n = try lookupStable(io, identity, default_ref.?, &output);
    var writer = std.Io.File.stdout().writerStreaming(io, &.{});
    try writer.interface.writeAll(output[0..n]);
    try writer.interface.flush();
}

fn checkParent(io: std.Io) !void {
    const pid = std.c.getppid();
    if (pid <= 1) return error.PrivateKeychainParentRequired;
    var parent_path: [4096]u8 = undefined;
    const found = proc_pidpath(pid, &parent_path, parent_path.len);
    if (found <= 0 or found >= parent_path.len) return error.PrivateKeychainParentRequired;
    var own_path: [4096]u8 = undefined;
    const own_length = try std.process.executablePath(io, &own_path);
    var canonical_parent: [4096]u8 = undefined;
    var canonical_self: [4096]u8 = undefined;
    const parent_length = std.Io.Dir.realPathFileAbsolute(io, std.mem.sliceTo(&parent_path, 0), &canonical_parent) catch return error.PrivateKeychainParentRequired;
    const self_length = try std.Io.Dir.realPathFileAbsolute(io, own_path[0..own_length], &canonical_self);
    if (!std.mem.eql(u8, canonical_parent[0..parent_length], canonical_self[0..self_length])) return error.PrivateKeychainParentRequired;
}

fn acknowledgement(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "OK\n");
}

fn upgradeProbe(io: std.Io, operation: []const u8, directory: []const u8) !void {
    if (!std.mem.startsWith(u8, directory, "/tmp/omagma-keychain-upgrade-") or directory.len > 192 or std.mem.indexOfScalar(u8, directory, 0) != null or std.mem.indexOf(u8, directory, "..") != null) return error.InvalidKeychainWorker;
    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{ .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.InvalidKeychainWorker;
    var storage: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&storage, "{s}/fixture.keychain", .{directory}, 0);
    const password = "synthetic-keychain-pass-not-a-user-password";
    var ref: ?CF = null;
    const creating = std.mem.eql(u8, operation, "upgrade-create");
    const status = if (creating) SecKeychainCreate(path, password.len, password.ptr, 0, null, &ref) else SecKeychainOpen(path, &ref);
    if (status != 0 or ref == null) return error.SyntheticKeychainUnavailable;
    defer CFRelease(ref.?);
    const identity: Identity = .{ .terminal = false, .account = "synthetic-upgrade@example.invalid" };
    if (creating) {
        try store(identity, ref, "synthetic-cross-build-token");
    } else if (std.mem.eql(u8, operation, "upgrade-check")) {
        if (SecKeychainUnlock(ref.?, password.len, password.ptr, 1) != 0) return error.SyntheticKeychainUnavailable;
        var output: [limits.secret]u8 = undefined;
        defer std.crypto.secureZero(u8, &output);
        const count = try lookupStable(io, identity, ref.?, &output);
        if (!std.mem.eql(u8, output[0..count], "synthetic-cross-build-token")) return error.SyntheticIdentityMismatch;
        try store(identity, ref, "synthetic-cross-build-updated");
        const updated = try lookupStable(io, identity, ref.?, &output);
        if (!std.mem.eql(u8, output[0..updated], "synthetic-cross-build-updated")) return error.SyntheticIdentityMismatch;
    } else if (std.mem.eql(u8, operation, "upgrade-verify")) {
        if (SecKeychainUnlock(ref.?, password.len, password.ptr, 1) != 0) return error.SyntheticKeychainUnavailable;
        var output: [limits.secret]u8 = undefined;
        defer std.crypto.secureZero(u8, &output);
        const count = try lookupStable(io, identity, ref.?, &output);
        if (!std.mem.eql(u8, output[0..count], "synthetic-cross-build-updated")) return error.SyntheticIdentityMismatch;
        if (SecKeychainLock(ref.?) != 0) return error.SyntheticKeychainUnavailable;
        try std.testing.expectError(error.KeyringUnavailable, lookupStable(io, identity, ref.?, &output));
        if (SecKeychainUnlock(ref.?, password.len, password.ptr, 1) != 0) return error.SyntheticKeychainUnavailable;
    } else if (std.mem.eql(u8, operation, "upgrade-write")) {
        if (SecKeychainUnlock(ref.?, password.len, password.ptr, 1) != 0) return error.SyntheticKeychainUnavailable;
        try store(identity, ref, "synthetic-cross-build-updated");
    } else if (std.mem.eql(u8, operation, "upgrade-delete")) {
        if (SecKeychainDelete(ref.?) != 0) return error.SyntheticKeychainCleanupFailed;
    } else return error.InvalidKeychainWorker;
}

fn synthetic(io: std.Io, directory: []const u8) !void {
    if (!std.mem.startsWith(u8, directory, "/tmp/omagma-keychain-probe-") or directory.len > 192 or std.mem.indexOfScalar(u8, directory, 0) != null or std.mem.indexOf(u8, directory, "..") != null) return error.InvalidKeychainWorker;
    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{ .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.InvalidKeychainWorker;
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
    if (try lookupStable(io, bar_a, keychain, &output) != 0) return error.SyntheticItemAlreadyExists;
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
    const n = try lookupStable(io, bar_a, keychain, &output);
    if (!std.mem.eql(u8, output[0..n], "synthetic-bar-a")) return error.SyntheticIdentityMismatch;
    const m = try lookupStable(io, term_a, keychain, &output);
    if (!std.mem.eql(u8, output[0..m], "synthetic-terminal-a")) return error.SyntheticIdentityMismatch;
    // A display-name edit must not change the service/account primary key.
    const relabel_query = try query(term_a, keychain, false, false);
    defer relabel_query.deinit();
    const relabel = try Dictionary.init();
    defer relabel.deinit();
    try relabel.string(kSecAttrLabel, "Renamed fictional credential");
    if (SecItemUpdate(relabel_query.value, relabel.value) != 0) return error.SyntheticKeychainUnavailable;
    if (try lookupStable(io, term_a, keychain, &output) == 0) return error.SyntheticIdentityMismatch;
    if (SecKeychainLock(keychain) != 0) return error.SyntheticKeychainUnavailable;
    try std.testing.expectError(error.KeyringUnavailable, lookupStable(io, term_a, keychain, &output));
    try std.testing.expectError(error.KeyringUnavailable, store(term_a, keychain, "synthetic-locked-write"));
    try std.testing.expectError(error.KeyringUnavailable, unlocked(keychain));
    if (SecKeychainUnlock(keychain, password.len, password.ptr, 1) != 0) return error.SyntheticKeychainUnavailable;
    // Boundaries use the actual signed-tool read path, not cast/inverse mocks.
    var maximum: [limits.secret]u8 = @splat('x');
    defer std.crypto.secureZero(u8, &maximum);
    try store(term_a, keychain, &maximum);
    const maximum_count = try lookupStable(io, term_a, keychain, &output);
    if (maximum_count != limits.secret or !std.mem.eql(u8, output[0..maximum_count], &maximum)) return error.SyntheticIdentityMismatch;
    try store(term_a, keychain, "synthetic-terminal-updated");
    const k = try lookupStable(io, term_a, keychain, &output);
    if (!std.mem.eql(u8, output[0..k], "synthetic-terminal-updated")) return error.SyntheticIdentityMismatch;
    const removed: Identity = .{ .terminal = true, .account = account_a };
    try clear(removed, keychain);
    if (try lookupStable(io, term_a, keychain, &output) != 0 or try lookupStable(io, term_other, keychain, &output) != 0) return error.SyntheticItemStillExists;
    if (try lookupStable(io, bar_a, keychain, &output) == 0 or try lookupStable(io, bar_b, keychain, &output) == 0) return error.SyntheticIdentityMismatch;
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
