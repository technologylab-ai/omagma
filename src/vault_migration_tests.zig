const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/vault_migration_journal.zig"));
    std.testing.refAllDecls(@import("terminal/vault_migration_identity.zig"));
    std.testing.refAllDecls(@import("terminal/vault_paths.zig"));
}

const j = @import("terminal/json.zig");
fn request(session: *@import("terminal/core.zig").Session, a: std.mem.Allocator, value: anytype) !j.Value {
    const raw = try j.encodeAlloc(a, value, .{});
    const response = try session.execute(a, raw);
    const parsed = try std.json.parseFromSliceLeaky(j.Value, a, response, .{});
    try std.testing.expect((parsed.object.get("ok") orelse return error.MissingResponse).bool);
    return parsed.object.get("data") orelse error.MissingResponse;
}

test "vault migration: imported queued sends require explicit resume or send-now" {
    const io = std.testing.io;
    std.debug.print("vault migration compiler={s} mode={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch) });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const path = try std.fmt.allocPrint(a, "{s}/omagma-migration-queue-{s}", .{ @import("terminal/vault_paths.zig").temporary_root, std.fmt.bytesToHex(nonce, .lower) });
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", path);
    const options: @import("terminal/types.zig").Options = .{ .fixtures = true, .cache_dir = path };
    const session = try a.create(@import("terminal/core.zig").Session);
    try session.initInto(io, a, &env, options, null);
    defer session.deinit();
    const account = "personal@example.com";
    const draft = try request(session, a, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Synthetic imported intent" } });
    const queued = try request(session, a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(draft, "id"), .operationId = "imported-queued-send", .delaySeconds = 0 });
    const queue_id = j.text(queued, "queueId");
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        (try @import("terminal/send_queue.zig").find(&store, queue_id)).resumeRequired = true;
        try store.save();
    }
    const paused = try request(session, a, .{ .cmd = "queue.process", .account = account, .queueId = queue_id, .wait = true });
    try std.testing.expectEqualStrings("queued", j.text(paused, "state"));
    try std.testing.expect(try j.boolean(paused, "resumeRequired", false));
    try std.testing.expectEqual(@as(i64, 0), try j.integer(try request(session, a, .{ .cmd = "cache.stats", .account = account }), "fixtureSends", -1));
    const resumed = try request(session, a, .{ .cmd = "queue.resume", .account = account, .queueId = queue_id, .delaySeconds = 0 });
    try std.testing.expect(!try j.boolean(resumed, "resumeRequired", true));
    const sent = try request(session, a, .{ .cmd = "queue.process", .account = account, .queueId = queue_id });
    try std.testing.expectEqualStrings("applied", j.text(sent, "state"));
    const copied = try request(session, a, .{ .cmd = "draft.clone", .account = account, .draftId = j.text(draft, "id") });
    const next = try request(session, a, .{ .cmd = "draft.queue", .account = account, .draftId = j.text(copied, "id"), .operationId = "imported-explicit-now", .delaySeconds = 30 });
    const next_id = j.text(next, "queueId");
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        (try @import("terminal/send_queue.zig").find(&store, next_id)).resumeRequired = true;
        try store.save();
    }
    const sent_now = try request(session, a, .{ .cmd = "queue.send-now", .account = account, .queueId = next_id });
    try std.testing.expectEqualStrings("applied", j.text(sent_now, "state"));
    try std.testing.expect(!try j.boolean(sent_now, "resumeRequired", true));
    try std.testing.expectEqual(@as(i64, 2), try j.integer(try request(session, a, .{ .cmd = "cache.stats", .account = account }), "fixtureSends", -1));
}

test "vault migration: three full metadata accounts copy and resume under the application heap limit" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture: std.heap.ArenaAllocator = .init(a);
    defer fixture.deinit();
    const fa = fixture.allocator();
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const path = try std.fmt.allocPrint(fa, "{s}/omagma-migration-capacity-{s}", .{ @import("terminal/vault_paths.zig").temporary_root, std.fmt.bytesToHex(nonce, .lower) });
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const types = @import("terminal/types.zig");
    const storage = @import("terminal/store.zig");
    const options: types.Options = .{ .fixtures = true, .metadata_limit = types.Limits.metadata_hard, .disk_limit = 96 * 1024 * 1024 };
    const config = try fa.create(@import("config.zig").Config);
    try config.defaults(path);
    config.count = 3;
    for (config.accounts[0..config.count], 0..) |*account, account_index| {
        try account.address.set(try std.fmt.allocPrint(fa, "capacity-{d}@example.test", .{account_index}));
        var source_arena: std.heap.ArenaAllocator = .init(a);
        defer source_arena.deinit();
        const sa = source_arena.allocator();
        var source = try storage.Store.open(io, sa, path, account.address.slice(), options);
        defer source.close();
        const rows = try sa.alloc(storage.Entry, types.Limits.metadata_hard);
        for (rows, 0..) |*entry, index| {
            const id = try std.fmt.allocPrint(sa, "synthetic-metadata-{d}", .{index});
            entry.* = .{ .message = .{ .id = id, .threadId = id, .from = .{ .address = "sender@example.test" } }, .bodyBlobIds = &.{} };
        }
        source.state.entries = rows;
        try source.save();
        try std.testing.expectEqual(types.Limits.metadata_hard, source.state.entries.len);
    }
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = a, .limit = 64 * 1024 * 1024 };
    var request_arena: std.heap.ArenaAllocator = .init(cap.allocator());
    defer request_arena.deinit();
    const private_directory = try @import("keyring_file.zig").directory(io, path, false);
    defer private_directory.close(io);
    const config_bytes = try config.snapshot(fa);
    const grants_bytes = "{\"version\":1,\"accounts\":[]}";
    for ([_][]const u8{ "config.json", "grants.json" }, [_][]const u8{ config_bytes, grants_bytes }) |name, contents| {
        const file = try private_directory.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, contents);
    }
    const metadata: @import("terminal/vault_migration_identity.zig").Metadata = .{ .config = config, .registry = .{}, .registry_bytes = grants_bytes, .source = .{ .config = try std.fmt.allocPrint(fa, "{s}/config.json", .{path}), .grants = try std.fmt.allocPrint(fa, "{s}/grants.json", .{path}), .cache = path } };
    const inventory = try @import("terminal/vault_migration.zig").inventory(io, request_arena.allocator(), cap.allocator(), metadata, options, false, null);
    try std.testing.expectEqual(@as(usize, 3), inventory.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), inventory.object_count);
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
    std.debug.print("migration inventory accounts=3 rows={d} heap_peak={d} heap_limit={d}\n", .{ types.Limits.metadata_hard * 3, cap.peak, cap.limit });
    var env: std.process.Environ.Map = .init(fa);
    defer env.deinit();
    try env.put("HOME", path);
    const owner_module = @import("terminal/vault_owner.zig");
    const owner = try cap.allocator().create(owner_module.Owner);
    defer cap.allocator().destroy(owner);
    owner.* = try owner_module.Owner.initForMigration(io, cap.allocator(), &env, try std.fmt.allocPrint(fa, "{s}/encrypted", .{path}), options);
    defer owner.deinit();
    const captured = try @import("terminal/vault_migration_identity.zig").capture(io, request_arena.allocator(), metadata);
    var recovery: @import("terminal/vault_types.zig").RecoveryKey = .{ .bytes = @splat(0x46) };
    defer recovery.wipe();
    try owner.createConfigured("Synthetic three-account migration password", &recovery, captured.config);
    try @import("terminal/vault_migration.zig").copy(owner, request_arena.allocator(), metadata, captured, .{});
    {
        // Simulate a crash after all account publications but before the final
        // completion checkpoint: resume must not parse source+target together.
        const journal = @import("terminal/vault_migration_journal.zig");
        var log = try journal.Journal.open(io, request_arena.allocator(), owner.path, &owner.key, &owner.workspace, owner.catalog_owner.?.root.handle, false);
        defer log.close();
        const manifest = try log.readManifest(request_arena.allocator());
        var progress = try log.readProgress(request_arena.allocator(), manifest);
        progress.verified = false;
        try log.saveProgress(progress, manifest);
    }
    try owner.lock();
    try owner.unlock("Synthetic three-account migration password");
    try @import("terminal/vault_migration.zig").copy(owner, request_arena.allocator(), metadata, captured, .{});
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
    std.debug.print("migration copy+unlock+verified-resume accounts=3 rows={d} heap_peak={d} heap_limit={d}\n", .{ types.Limits.metadata_hard * 3, cap.peak, cap.limit });
}

test "vault migration: explicit file capture preserves exact bound tokens without changing source" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var wiping: @import("terminal/vault_allocator.zig").WipingAllocator = .{ .backing = a };
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer arena.deinit();
    const scratch = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", scratch);
    const root = try std.fmt.allocPrint(scratch, "{s}/private", .{base});
    const private_directory = try @import("keyring_file.zig").directory(io, root, true);
    defer private_directory.close(io);
    const account = "capture@example.test";
    const client = "synthetic-capture.apps.googleusercontent.com";
    const config = try scratch.create(@import("config.zig").Config);
    try config.defaults(root);
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .file;
    try config.credential_directory.set(try std.fmt.allocPrint(scratch, "{s}/credentials", .{root}));
    try config.client_file.set(try std.fmt.allocPrint(scratch, "{s}/client.json", .{root}));
    const config_json = try j.encodeAlloc(scratch, .{ .credentialStore = "file", .credentialDirectory = config.credential_directory.slice(), .oauthClientFile = config.client_file.slice(), .accounts = &.{.{ .address = account, .profile = "Profile 3" }} }, .{});
    const auth = @import("terminal/auth.zig");
    const scopes = try auth.scopesFor(scratch, &.{"mail-read"});
    const grant_id = auth.grantIdentity(scopes);
    var grants = [_]auth.Grant{.{ .account = account, .clientFile = config.client_file.slice(), .clientId = client, .grantId = &grant_id, .capabilities = &.{"mail-read"}, .scopes = scopes }};
    const grant_json = try j.encodeAlloc(scratch, auth.Registry{ .accounts = &grants }, .{});
    const desktop = "{\"installed\":{\"client_id\":\"synthetic-capture.apps.googleusercontent.com\",\"client_secret\":\"SYNTHETIC-CAPTURE-CLIENT-SECRET\"}}";
    const paths = [_][]const u8{ "config.json", "grants.json", "client.json" };
    const contents = [_][]const u8{ config_json, grant_json, desktop };
    for (paths, contents) |path, bytes| {
        const file = try private_directory.createFile(io, path, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }
    const keyring = @import("keyring.zig");
    try keyring.store(io, config.credentials(), account, client, "SYNTHETIC-CAPTURE-BAR-TOKEN");
    try keyring.storeTerminal(io, config.credentials(), account, client, &grant_id, "SYNTHETIC-CAPTURE-TERMINAL-TOKEN");
    try keyring.store(io, config.credentials(), account, "other-synthetic.apps.googleusercontent.com", "SYNTHETIC-UNRELATED-TOKEN");
    var env: std.process.Environ.Map = .init(scratch);
    defer env.deinit();
    try env.put("HOME", root);
    const source: @import("terminal/vault_migration_journal.zig").Source = .{ .config = try std.fmt.allocPrint(scratch, "{s}/config.json", .{root}), .grants = try std.fmt.allocPrint(scratch, "{s}/grants.json", .{root}), .cache = try std.fmt.allocPrint(scratch, "{s}/cache", .{root}) };
    const migration_identity = @import("terminal/vault_migration_identity.zig");
    const captured = try migration_identity.capture(io, scratch, try migration_identity.Metadata.load(io, scratch, &env, source));
    try std.testing.expectEqual(@as(usize, 2), captured.token_count);
    try std.testing.expectEqual(keyring.Kind.vault, captured.config.credential_store);
    try std.testing.expectEqual(@as(usize, 0), captured.config.credential_directory.len);
    var found: usize = 0;
    for (captured.changes) |change| switch (change.kind) {
        .bar_token, .terminal_token => {
            try std.testing.expectEqualStrings(account, change.key.account);
            try std.testing.expectEqualStrings(client, change.key.client);
            try std.testing.expectEqualStrings(if (change.kind == .bar_token) "SYNTHETIC-CAPTURE-BAR-TOKEN" else "SYNTHETIC-CAPTURE-TERMINAL-TOKEN", change.value.?);
            try std.testing.expectEqualStrings(if (change.kind == .bar_token) "" else &grant_id, change.key.grant);
            found += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    var token: [@import("limits.zig").secret]u8 = undefined;
    defer std.crypto.secureZero(u8, &token);
    try std.testing.expectEqualStrings("SYNTHETIC-CAPTURE-TERMINAL-TOKEN", (try keyring.lookupTerminal(io, config.credentials(), account, client, &grant_id, &token)).?);
    for (paths, contents) |path, bytes| {
        var file_buffer: [128 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &file_buffer);
        try std.testing.expectEqualStrings(bytes, try private_directory.readFile(io, path, &file_buffer));
    }
}

test "retained migration: paged copy resumes across an authenticated page boundary before publication" {
    const io = std.testing.io;
    const storage = @import("terminal/store.zig");
    const migration = @import("terminal/vault_migration.zig");
    const journal = @import("terminal/vault_migration_journal.zig");
    const identity = @import("terminal/vault_migration_identity.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    const cache = try std.fmt.allocPrint(a, "{s}/cache", .{path});
    const options: @import("terminal/types.zig").Options = .{ .fixtures = true };
    const config = try a.create(@import("config.zig").Config);
    try config.defaults(path);
    config.count = 1;
    try config.accounts[0].address.set("paged@example.test");
    {
        var source = try storage.Store.open(io, a, cache, config.accounts[0].address.slice(), options);
        defer source.close();
        try source.save();
        for (0..129) |index| {
            const name = try std.fmt.allocPrint(a, "history-page-{s}.json", .{storage.Store.hash(try std.fmt.allocPrint(a, "owned-{d}", .{index}))});
            const file = try source.dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
            try file.writeStreamingAll(io, "{}");
            file.close(io);
        }
    }
    const identity_path = try std.fmt.allocPrint(a, "{s}/identity", .{path});
    const identity_dir = try @import("keyring_file.zig").directory(io, identity_path, true);
    defer identity_dir.close(io);
    const config_bytes = try config.snapshot(a);
    const grants_bytes = "{\"version\":1,\"accounts\":[]}";
    for ([_][]const u8{ "config.json", "grants.json" }, [_][]const u8{ config_bytes, grants_bytes }) |name, contents| {
        const file = try identity_dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, contents);
        file.close(io);
    }
    const metadata: identity.Metadata = .{ .config = config, .registry = .{}, .registry_bytes = grants_bytes, .source = .{ .config = try std.fmt.allocPrint(a, "{s}/config.json", .{identity_path}), .grants = try std.fmt.allocPrint(a, "{s}/grants.json", .{identity_path}), .cache = cache } };
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", path);
    const Owner = @import("terminal/vault_owner.zig").Owner;
    const owner = try std.testing.allocator.create(Owner);
    defer std.testing.allocator.destroy(owner);
    owner.* = try Owner.initForMigration(io, std.testing.allocator, &env, try std.fmt.allocPrint(a, "{s}/sealed", .{path}), options);
    defer owner.deinit();
    const captured = try identity.capture(io, a, metadata);
    var recovery: @import("terminal/vault_types.zig").RecoveryKey = .{ .bytes = @splat(0x46) };
    defer recovery.wipe();
    try owner.createConfigured("Synthetic paged migration password", &recovery, captured.config);
    try std.testing.expectError(error.VaultMigrationInterrupted, migration.copy(owner, a, metadata, captured, .{ .fixture_stop_after = 128 }));
    try owner.lock();
    try owner.unlock("Synthetic paged migration password");
    try migration.copy(owner, a, metadata, captured, .{});
    var log = try journal.Journal.open(io, a, owner.path, &owner.key, &owner.workspace, owner.catalog_owner.?.root.handle, false);
    defer log.close();
    const manifest = try log.readManifest(a);
    try std.testing.expectEqual(@as(u8, 2), manifest.schema);
    try std.testing.expectEqual(@as(usize, 129), manifest.objectCount());
    try std.testing.expect((try log.readProgress(a, manifest)).verified);
    var destination = try storage.Store.openMigrationDestination(io, a, &owner.catalog_owner.?, "paged@example.test", options);
    defer destination.close();
    try std.testing.expectEqual(@as(usize, 0), destination.vaultObjects.len);
}
