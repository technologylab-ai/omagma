//! Real private Unix sockets and synthetic account data; no production paths.
const std = @import("std");
const test_allocator = @import("cancel_neutral_test_allocator.zig");
const owner_module = @import("terminal/vault_owner.zig");
const daemon = @import("terminal/vault_daemon.zig");
const transport = @import("terminal/vault_transport.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;
const a = test_allocator.allocator;

test {
    test_allocator.install();
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(transport);
    std.testing.refAllDecls(@import("terminal/vault_allocator.zig"));
    std.testing.refAllDecls(@import("terminal/vault_recovery.zig"));
    std.testing.refAllDecls(@import("terminal/vault_initialization.zig"));
}

fn command(client: *transport.Client, allocator: std.mem.Allocator, request: anytype) !std.json.Value {
    const raw = try j.encodeAlloc(allocator, request, .{});
    const response = client.request(allocator, .execute, raw) catch |err| {
        std.debug.print("synthetic vault command {s} transport failure: {s}\n", .{ request.cmd, @errorName(err) });
        return err;
    };
    const value = try std.json.parseFromSliceLeaky(j.Value, allocator, response, .{});
    if (!(value.object.get("ok") orelse return error.MissingResponse).bool)
        std.debug.print("synthetic vault command {s} rejected: {s}\n", .{ request.cmd, j.text(j.get(value, "error") orelse .null, "code") });
    try std.testing.expect((value.object.get("ok") orelse return error.MissingResponse).bool);
    return value.object.get("data") orelse error.MissingResponse;
}

test "vault protocol: old clients cannot mutate current daemon and current clients retain normal dispatch" {
    test_allocator.install();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.parent_dir.setFilePermissions(io, &tmp.sub_path, .fromMode(0o700), .{ .follow_symlinks = false });
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const vault = try std.fmt.allocPrint(allocator, "{s}/vault", .{root});
    const socket = try std.fmt.allocPrint(allocator, "{s}/socket", .{root});
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", root);
    const owner = try a.create(owner_module.Owner);
    defer a.destroy(owner);
    owner.* = try owner_module.Owner.init(io, a, &env, vault, .{ .fixtures = true });
    defer owner.deinit();
    var recovery: @import("terminal/vault_types.zig").RecoveryKey = .{ .bytes = @splat(0x53) };
    defer recovery.wipe();
    const password = "Synthetic protocol upgrade password";
    try owner.create(password, &recovery);
    var service = try io.concurrent(daemon.serve, .{ io, a, owner, socket });
    defer service.cancel(io) catch {};
    var client: transport.Client = .{ .io = io, .socket_path = socket };
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
    const Legacy = struct {
        fn request(path: []const u8, kind: transport.Kind, body: []const u8, memory: std.mem.Allocator) !j.Value {
            const address = try std.Io.net.UnixAddress.init(path);
            const stream = try address.connect(io);
            defer stream.close(io);
            var header = try transport.encodeHeader(kind, body.len, transport.request_limit);
            @memcpy(header[0..8], "OMAVIPC1");
            var writer = stream.writer(io, &.{});
            try writer.interface.writeAll(&header);
            try writer.interface.writeAll(body);
            try writer.interface.flush();
            var response = try transport.readFrame(io, memory, stream, transport.ordinary_response_limit);
            defer response.deinit(memory);
            return std.json.parseFromSliceLeaky(j.Value, memory, response.body, .{ .allocate = .alloc_always });
        }
    };
    for ([_][]const u8{
        "{\"id\":\"legacy-create\",\"account\":\"personal@example.com\",\"cmd\":\"draft.create\",\"draft\":{\"bodyText\":\"Must never be saved\"}}",
        "{\"id\":42,\"account\":\"personal@example.com\",\"cmd\":\"draft.send\",\"operationId\":\"never-dispatched\"}",
    }) |body| {
        const response = try Legacy.request(socket, .execute, body, allocator);
        const request = try std.json.parseFromSliceLeaky(j.Value, allocator, body, .{});
        try std.testing.expectEqualDeep(j.get(request, "id").?, j.get(response, "id").?);
        try std.testing.expectEqualStrings("personal@example.com", j.text(response, "account"));
        try std.testing.expectEqualStrings("BackendProtocolMismatch", j.text(j.get(response, "error").?, "code"));
        try std.testing.expect(std.mem.indexOf(u8, j.text(j.get(response, "error").?, "message"), "omagma vault stop") != null);
    }
    const empty = try command(&client, allocator, .{ .cmd = "draft.list", .account = "personal@example.com" });
    try std.testing.expectEqual(@as(usize, 0), j.get(empty, "drafts").?.array.items.len);
    const stats = try command(&client, allocator, .{ .cmd = "cache.stats", .account = "personal@example.com" });
    try std.testing.expectEqual(@as(i64, 0), try j.integer(stats, "fixtureSends", 0));
    try std.testing.expectEqual(@as(i64, 0), try j.integer(stats, "fixtureCalls", 0));
    const current = try command(&client, allocator, .{ .cmd = "draft.create", .account = "personal@example.com", .draft = .{ .subject = "Current protocol", .bodyText = "Exact new content" } });
    const saved = try command(&client, allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = j.text(current, "id") });
    try std.testing.expectEqualStrings("Exact new content", j.text(saved, "bodyText"));
    _ = try Legacy.request(socket, .lock, "", allocator);
    try std.testing.expect(!owner.unlocked());
    const refused_unlock = try Legacy.request(socket, .unlock, password, allocator);
    try std.testing.expectEqualStrings("BackendProtocolMismatch", j.text(j.get(refused_unlock, "error").?, "code"));
    try std.testing.expect(!owner.unlocked());
    var wrong_owner = client;
    wrong_owner.expected_vault_id = @splat(0xff);
    try std.testing.expectError(error.VaultIdentityMismatch, wrong_owner.request(allocator, .unlock, password));
    try std.testing.expect(!owner.unlocked());
    _ = try client.request(allocator, .unlock, password);
    try std.testing.expect(owner.unlocked());
    const old_status = try Legacy.request(socket, .status, "", allocator);
    try std.testing.expect(j.get(j.get(old_status, "data").?, "unlocked").?.bool);
    _ = try Legacy.request(socket, .stop, "", allocator);
    try service.await(io);
    try std.testing.expect(!owner.unlocked());
}

test "vault daemon: create unlock account mail draft lock and restart through private socket" {
    test_allocator.install();
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
    try env.put("XDG_RUNTIME_DIR", root);
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
    // Native compose frames and encrypted draft records grow by actual bytes.
    // Escaping makes this ordinary4MiB text exceed both old3MiB IPC and8MiB
    // stored-draft ceilings; the original command remains bounded by policy.
    const large_note = try allocator.alloc(u8, 4 * 1024 * 1024);
    for (large_note, 0..) |*byte, index| byte.* = "\n\t\\\""[index % 4];
    const preview_tail = "Synthetic encrypted preview reaches the final body bytes.";
    @memcpy(large_note[large_note.len - preview_tail.len ..], preview_tail);
    const large_draft = try command(&client, allocator, .{ .cmd = "draft.create", .account = "personal@example.com", .acknowledgementOnly = true, .draft = .{ .subject = "Large sealed source", .bodyText = large_note } });
    const large_id = try allocator.dupe(u8, j.text(large_draft, "id"));
    const large_saved = try command(&client, allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = large_id });
    try std.testing.expectEqualStrings(large_note, j.text(large_saved, "bodyText"));
    // Exercise the encrypted daemon worker's complete export path over IPC,
    // including its native stack and private plaintext-export destination.
    // Fixtures never launch a browser or contact a provider.
    const draft_before_preview = try j.encodeAlloc(allocator, large_saved, .{});
    const preview = try command(&client, allocator, .{ .cmd = "draft.open-preview", .account = "personal@example.com", .draftId = large_id });
    try std.testing.expect(j.get(preview, "fixture").?.bool);
    try std.testing.expect(!j.get(preview, "opened").?.bool);
    const preview_path = j.text(preview, "path");
    const preview_directory = std.fs.path.dirname(preview_path) orelse return error.MissingPreviewDirectory;
    const preview_prefix = try std.fmt.allocPrint(allocator, "{s}/omagma-preview-", .{root});
    try std.testing.expect(std.mem.startsWith(u8, preview_directory, preview_prefix));
    defer std.Io.Dir.cwd().deleteTree(io, preview_directory) catch {};
    try std.testing.expectEqualStrings(@import("terminal/preview_file.zig").filename, std.fs.path.basename(preview_path));
    const preview_stat = try std.Io.Dir.cwd().statFile(io, preview_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(.file, preview_stat.kind);
    try std.testing.expectEqual(@as(u32, 0o600), preview_stat.permissions.toMode() & 0o777);
    const directory_stat = try std.Io.Dir.cwd().statFile(io, preview_directory, .{ .follow_symlinks = false });
    try std.testing.expectEqual(.directory, directory_stat.kind);
    try std.testing.expectEqual(@as(u32, 0o700), directory_stat.permissions.toMode() & 0o777);
    const rendered = try std.Io.Dir.cwd().readFileAlloc(io, preview_path, allocator, .limited(@import("terminal/preview_file.zig").max_file_bytes));
    try std.testing.expect(rendered.len > large_note.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered, preview_tail) != null);
    const draft_after_preview = try command(&client, allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = large_id });
    try std.testing.expectEqualStrings(draft_before_preview, try j.encodeAlloc(allocator, draft_after_preview, .{}));
    try std.Io.Dir.cwd().deleteTree(io, preview_directory);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, preview_directory, .{ .follow_symlinks = false }));
    _ = try client.request(allocator, .lock, "");
    try std.testing.expect(!owner.unlocked());
    for (owner.key.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    _ = try client.request(allocator, .unlock, password);
    const reopened = try command(&client, allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = draft_id });
    try std.testing.expectEqualStrings("Sealed draft body", j.text(reopened, "bodyText"));
    const large_reopened = try command(&client, allocator, .{ .cmd = "draft.read", .account = "personal@example.com", .draftId = large_id });
    try std.testing.expectEqualStrings(large_note, j.text(large_reopened, "bodyText"));
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
    test_allocator.install();
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
    test_allocator.install();
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
    test_allocator.install();
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
