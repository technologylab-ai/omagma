//! Real private Unix sockets and synthetic account data; no production paths.
const std = @import("std");
const owner_module = @import("terminal/vault_owner.zig");
const daemon = @import("terminal/vault_daemon.zig");
const transport = @import("terminal/vault_transport.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;
const a = std.testing.allocator;

test {
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(transport);
    std.testing.refAllDecls(@import("terminal/vault_allocator.zig"));
    std.testing.refAllDecls(@import("terminal/vault_recovery.zig"));
    std.testing.refAllDecls(@import("terminal/vault_initialization.zig"));
}

fn command(client: *transport.Client, allocator: std.mem.Allocator, request: anytype) !std.json.Value {
    const raw = try j.encodeAlloc(allocator, request, .{});
    const response = try client.request(allocator, .execute, raw);
    const value = try std.json.parseFromSliceLeaky(j.Value, allocator, response, .{});
    try std.testing.expect((value.object.get("ok") orelse return error.MissingResponse).bool);
    return value.object.get("data") orelse error.MissingResponse;
}

test "vault daemon: create unlock account mail draft lock and restart through private socket" {
    std.debug.print("vault daemon compiler={s} mode={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch) });
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    const root = try std.fmt.allocPrint(a, "{s}/omagma-vault-test-{s}", .{ @import("terminal/vault_paths.zig").temporary_root, std.fmt.bytesToHex(random, .lower) });
    defer a.free(root);
    const dir = try @import("keyring_file.zig").directory(io, root, true);
    dir.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/vault", .{root});
    defer a.free(path);
    const socket = try std.fmt.allocPrint(a, "{s}/ipc/sock", .{root});
    defer a.free(socket);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    const owner = try a.create(owner_module.Owner);
    defer a.destroy(owner);
    owner.* = try owner_module.Owner.init(io, a, &env, path, .{ .fixtures = true });
    defer owner.deinit();
    var recovery: @import("terminal/vault_types.zig").RecoveryKey = .{ .bytes = @splat(0x47) };
    defer recovery.wipe();
    const password = "Synthetic vault daemon password";
    try owner.create(password, &recovery);
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        var store = try owner.openStore(arena.allocator(), "personal@example.com", false);
        defer store.close();
        try store.put(.{ .id = "synthetic-message", .threadId = "synthetic-thread", .subject = "Secret fixture subject", .bodyText = "Secret fixture body", .labels = &.{"INBOX"} }, true);
        const large = try arena.allocator().alloc(u8, 2 * 1024 * 1024);
        @memset(large, 'x');
        try store.put(.{ .id = "large-synthetic-message", .threadId = "large-thread", .subject = "Large synthetic subject", .bodyHtml = large, .bodySource = .html, .labels = &.{"INBOX"} }, true);
        try store.save();
    }
    try owner.lock();
    try std.testing.expect(!owner.unlocked());
    try std.testing.expectError(error.VaultAuthenticationFailed, owner.unlock("Wrong synthetic password"));
    try std.testing.expect(!@import("terminal/vault_kdf_memory.zig").busy());
    var service = try io.concurrent(daemon.serve, .{ io, a, owner, socket });
    defer service.cancel(io) catch {};
    var client: transport.Client = .{ .io = io, .socket_path = socket };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var connected = false;
    for (0..200) |_| {
        _ = client.request(allocator, .status, "") catch {
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(10) }).sleep(io);
            continue;
        };
        connected = true;
        break;
    }
    try std.testing.expect(connected);
    const locked = try client.request(allocator, .execute, "{\"id\":\"locked-correlation\",\"cmd\":\"accounts.list\",\"account\":\"personal@example.com\"}");
    try std.testing.expect(std.mem.indexOf(u8, locked, "VaultLocked") != null);
    const locked_value = try std.json.parseFromSliceLeaky(j.Value, allocator, locked, .{});
    try std.testing.expectEqualStrings("locked-correlation", j.text(locked_value, "id"));
    try std.testing.expectEqualStrings("personal@example.com", j.text(locked_value, "account"));
    const unlocked = try client.request(allocator, .unlock, password);
    try std.testing.expect(std.mem.indexOf(u8, unlocked, "\"unlocked\":true") != null);
    const direct = try owner.execute(allocator, "{\"cmd\":\"accounts.list\"}");
    const relayed = try client.request(allocator, .execute, "{\"cmd\":\"accounts.list\"}");
    try std.testing.expectEqualStrings(direct, relayed);
    client.expected_vault_id = owner.key.vault_id;
    try std.testing.expectEqualStrings(direct, try client.client().call(allocator, "{\"cmd\":\"accounts.list\"}"));
    client.expected_vault_id.?[0] ^= 1;
    const wrong_vault = try client.client().call(allocator, "{\"id\":\"wrong-vault\",\"cmd\":\"accounts.list\"}");
    try std.testing.expect(std.mem.indexOf(u8, wrong_vault, "VaultIdentityMismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrong_vault, "wrong-vault") != null);
    client.expected_vault_id = null;
    // Runtime policy changes come from the authenticated identity on every
    // request; an unlocked Session cannot retain an older enabled account.
    const provider = owner.identity.?.provider();
    const original_config = try allocator.dupe(u8, (try provider.read(.configuration, .{})).?);
    owner.session.?.config.accounts[0].enabled = false;
    const disabled_config = try owner.session.?.config.snapshot(allocator);
    try provider.apply(&.{.{ .kind = .configuration, .value = disabled_config }});
    const disabled = try client.request(allocator, .execute, "{\"id\":\"disabled-policy\",\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"synthetic-message\"}");
    try std.testing.expect(std.mem.indexOf(u8, disabled, "AccountDisabled") != null);
    try provider.apply(&.{.{ .kind = .configuration, .value = original_config }});
    const large_request = "{\"id\":\"large-body\",\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"large-synthetic-message\",\"cacheOnly\":true}";
    const large_direct = try owner.execute(allocator, large_request);
    const large_relay = try client.request(allocator, .execute, large_request);
    try std.testing.expect(large_direct.len > 2 * 1024 * 1024);
    try std.testing.expectEqualStrings(large_direct, large_relay);
    const mail = try command(&client, allocator, .{ .cmd = "mail.read", .account = "personal@example.com", .messageId = "synthetic-message", .cacheOnly = true });
    try std.testing.expect(std.mem.indexOf(u8, try j.encodeAlloc(allocator, mail, .{}), "Secret fixture body") != null);
    const draft = try command(&client, allocator, .{ .cmd = "draft.create", .account = "personal@example.com", .draft = .{ .subject = "Sealed draft", .bodyText = "Sealed draft body" } });
    const draft_id = try allocator.dupe(u8, j.text(draft, "id"));
    try std.testing.expect(draft_id.len != 0);
    _ = try client.request(allocator, .lock, "");
    try std.testing.expect(!owner.unlocked());
    for (owner.key.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    _ = try client.request(allocator, .unlock, password);
    const reopened = try command(&client, allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = draft_id });
    try std.testing.expectEqualStrings("Sealed draft body", j.text(reopened, "bodyText"));
    _ = try client.request(allocator, .stop, "");
    try service.await(io);
    try std.testing.expect(!owner.unlocked());
    // Reconstruct every owner descriptor, proving restart uses only ciphertext.
    owner.deinit();
    owner.* = try owner_module.Owner.init(io, a, &env, path, .{ .fixtures = true });
    try owner.unlock(password);
    const after_restart = try owner.execute(allocator, try j.encodeAlloc(allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = draft_id }, .{}));
    try std.testing.expect(std.mem.indexOf(u8, after_restart, "Sealed draft body") != null);
    try owner.changePassword("Replacement synthetic password");
    try owner.lock();
    try std.testing.expectError(error.VaultAuthenticationFailed, owner.unlock(password));
    try owner.unlock("Replacement synthetic password");
    var replacement_recovery: @import("terminal/vault_types.zig").RecoveryKey = .{ .bytes = @splat(0x68) };
    defer replacement_recovery.wipe();
    try owner.changeRecovery(&replacement_recovery);
    try owner.lock();
    try std.testing.expectError(error.VaultAuthenticationFailed, owner.recover(&recovery, "Recovery replacement password"));
    try owner.recover(&replacement_recovery, "Recovery replacement password");
    try owner.lock();
    try std.testing.expectError(error.VaultAuthenticationFailed, owner.unlock("Replacement synthetic password"));
    try owner.unlock("Recovery replacement password");
    try owner.lock();
    const plaintext_cache = try std.fmt.allocPrint(allocator, "{s}/.cache", .{root});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, plaintext_cache, .{}));
}

test "vault daemon: private listener refuses unsafe paths and competing servers" {
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const root = try std.fmt.allocPrint(a, "{s}/omagma-peer-test-{s}", .{ @import("terminal/vault_paths.zig").temporary_root, std.fmt.bytesToHex(random, .lower) });
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/s", .{root});
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var listener = try transport.Listener.init(io, path);
    defer listener.deinit();
    try std.testing.expectError(error.BackendAlreadyRunning, transport.Listener.init(io, path));
    const stat = try listener.directory.statFile(io, "s", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var expected: [108]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try transport.defaultPath(&expected), if (@import("builtin").os.tag == .macos) "/private/tmp/omagma-" else "/tmp/omagma-"));
}

test "vault daemon: caller retains and wipes a completed allocation during deadline cancellation" {
    const Race = struct {
        allocated: std.Io.Event = .unset,
        output: ?[]u8 = null,
        fn operation(self: *@This()) !void {
            self.output = try a.dupe(u8, "synthetic-secret-completed-at-timeout");
            self.allocated.set(io);
            // Return success while cancellation is joining this task. The
            // Select discards void; allocation remains in the caller's slot.
            @import("platform.zig").seconds(30).sleep(io) catch |err| if (err != error.Canceled) return err;
        }
        fn timeout(self: *@This()) !void {
            try self.allocated.wait(io);
        }
    };
    var race: Race = .{};
    defer if (race.output) |bytes| {
        std.crypto.secureZero(u8, bytes);
        for (bytes) |byte| std.debug.assert(byte == 0);
        a.free(bytes);
    };
    const Event = union(enum) { operation: anyerror!void, timeout: anyerror!void };
    var events: [2]Event = undefined;
    {
        var select: std.Io.Select(Event) = .init(io, &events);
        defer select.cancelDiscard();
        try select.concurrent(.operation, Race.operation, .{&race});
        try select.concurrent(.timeout, Race.timeout, .{&race});
        switch (try select.await()) {
            .operation => return error.UnexpectedEarlyCompletion,
            .timeout => |result| try result,
        }
    }
    try std.testing.expectEqualStrings("synthetic-secret-completed-at-timeout", race.output.?);
}

test "vault daemon: repeated stop signal and cancellation join workers before listener reuse" {
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const root = try std.fmt.allocPrint(a, "{s}/omagma-stop-test-{s}", .{ @import("terminal/vault_paths.zig").temporary_root, std.fmt.bytesToHex(random, .lower) });
    defer a.free(root);
    const directory = try @import("keyring_file.zig").directory(io, root, true);
    directory.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/vault", .{root});
    defer a.free(path);
    const socket = try std.fmt.allocPrint(a, "{s}/ipc/sock", .{root});
    defer a.free(socket);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    const owner = try a.create(owner_module.Owner);
    defer a.destroy(owner);
    owner.* = try owner_module.Owner.init(io, a, &env, path, .{ .fixtures = true });
    defer owner.deinit();
    var client: transport.Client = .{ .io = io, .socket_path = socket };
    // The stop response can reach its caller before the worker has unwound
    // its deadline tasks. Reuse the exact socket to check joined teardown.
    for (0..96) |iteration| {
        var service = try io.concurrent(daemon.serve, .{ io, a, owner, socket });
        defer service.cancel(io) catch {};
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var connected = false;
        for (0..200) |_| {
            _ = client.request(arena.allocator(), .status, "") catch {
                try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(10) }).sleep(io);
                continue;
            };
            connected = true;
            break;
        }
        try std.testing.expect(connected);
        switch (iteration % 3) {
            0 => {
                const stopped = try client.request(arena.allocator(), .stop, "");
                try std.testing.expect(std.mem.indexOf(u8, stopped, "\"unlocked\":false") != null);
                try service.await(io);
            },
            1 => {
                const pid: i32 = if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else std.c.getpid();
                try std.posix.kill(pid, .TERM);
                try service.await(io);
            },
            2 => try std.testing.expectError(error.Canceled, service.cancel(io)),
            else => unreachable,
        }
        try std.testing.expect(!owner.unlocked());
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, socket, .{ .follow_symlinks = false }));
    }
}
