//! Synthetic source-retaining import; no installed cache or credentials.
const std = @import("std");
const storage = @import("terminal/store.zig");
const Store = storage.Store;
const catalog = @import("terminal/vault_catalog.zig");
const identity = @import("terminal/vault_identity.zig");
const sealed = @import("terminal/vault_storage.zig");
const vt = @import("terminal/vault_types.zig");
const crypto = @import("terminal/vault_crypto.zig");
const header = @import("terminal/vault_header.zig");
const Config = @import("config.zig").Config;
const t = @import("terminal/types.zig");
const blob = @import("terminal/attachment_blob.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;
const a = std.testing.allocator;
const account = "migration@example.test";
const other = "other-migration@example.test";
const options: t.Options = .{ .fixtures = true, .disk_limit = 96 * 1024 * 1024 };
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    source_path: []const u8,
    destination_path: []const u8,
    key: vt.DataKey,
    descriptor: header.Header,
    workspace: vt.StreamWorkspace = undefined,
    owner: catalog.Owner,
    identity: identity.State,
    draft_id: []const u8,
    attachment: t.Attachment,
    fn create(size: usize) !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = .init(a);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const path = try self.tmp.dir.realPathFileAlloc(io, ".", arena);
        self.source_path = try std.fmt.allocPrint(arena, "{s}/source", .{path});
        self.destination_path = try std.fmt.allocPrint(arena, "{s}/sealed", .{path});
        const incoming = try self.tmp.dir.createFile(io, "large-synthetic.bin", .{ .read = true, .permissions = .fromMode(0o600) });
        var buffer: [64 * 1024]u8 = @splat('s');
        var written: usize = 0;
        while (written < size) {
            const n = @min(buffer.len, size - written);
            try incoming.writeStreamingAll(io, buffer[0..n]);
            written += n;
        }
        incoming.close(io);
        var source = try Store.open(io, arena, self.source_path, account, options);
        defer source.close();
        self.attachment = try blob.importFile(&source, try std.fmt.allocPrint(arena, "{s}/large-synthetic.bin", .{path}), "application/octet-stream");
        try source.put(.{ .id = "source-message", .threadId = "thread", .bodyText = "MIGRATION PRIVATE BODY SENTENCE", .attachments = &.{self.attachment} }, true);
        const draft = try source.putDraft(.{ .subject = "MIGRATION PRIVATE DRAFT", .bodyText = "Draft kept exactly", .attachments = &.{self.attachment}, .original = .{ .sourceMessageId = "source-message", .bodyText = "Preserved original", .resources = &.{self.attachment} } }, null);
        self.draft_id = draft.id;
        try source.putOutbox(.{ .id = "sent-before-migration", .threadId = "thread", .bodyText = "Exact retained outbox" });
        try source.writeDocument("calendar-state.json", "{\"schema\":1,\"account\":\"migration@example.test\",\"receipts\":[{\"outcome\":\"unknown\",\"source\":\"exact synthetic ICS\"}]}");
        try source.writeDocument("follow-ups.json", "{\"schema\":1,\"entries\":[]}");
        source.state.serial = 77;
        source.state.generation = 19;
        source.state.operations = try arena.dupe(storage.Operation, &.{.{ .id = "uncertain-send", .hash = try arena.dupe(u8, &Store.hash("wire")), .draftId = self.draft_id, .outcome = "unknown" }});
        const queue_hash = try arena.dupe(u8, &Store.hash("queue-wire"));
        source.state.sendQueue = try arena.dupe(storage.QueuedSend, &.{
            .{ .queueId = "queued", .draftId = self.draft_id, .operationId = "queue-operation", .hash = queue_hash, .createdAtMs = 1000, .dueAtMs = 2000 },
            .{ .queueId = "uncertain", .draftId = self.draft_id, .operationId = "uncertain-send", .hash = queue_hash, .state = .unknown, .createdAtMs = 1000, .dueAtMs = 2000 },
        });
        try source.save();
        self.key = try crypto.createDataKey(io);
        errdefer self.key.wipe();
        self.descriptor = .{ .vault_id = self.key.vault_id, .key_id = self.key.key_id, .root_record = try sealed.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
        self.owner = try catalog.Owner.create(io, self.destination_path, self.descriptor, &self.key, &self.workspace);
        errdefer self.owner.close();
        const config = try arena.create(Config);
        try config.defaults("/nonexistent/synthetic-home");
        config.credential_store = .vault;
        config.count = 2;
        try config.accounts[0].address.set(account);
        try config.accounts[1].address.set(other);
        self.identity = try identity.State.createWithAccounts(&self.owner, a, config, &.{
            .{ .account = account, .initial_index = try Store.initialVaultIndex(arena, account, options), .disk_limit = options.disk_limit },
            .{ .account = other, .initial_index = try Store.initialVaultIndex(arena, other, options), .disk_limit = options.disk_limit },
        });
        return self;
    }
    fn destroy(self: *Fixture) void {
        self.identity.deinit();
        self.owner.close();
        self.workspace.wipe();
        self.key.wipe();
        self.arena.deinit();
        self.tmp.cleanup();
        a.destroy(self);
    }
};

test "vault Store migration: 25 MiB copy resumes planned handles and preserves exact records under a four MiB request heap" {
    std.debug.print("migration Store compiler={s} optimize={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    const fixture = try Fixture.create(25 * 1024 * 1024);
    defer fixture.destroy();
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = a, .limit = 4 * 1024 * 1024 };
    var memory = std.heap.ArenaAllocator.init(cap.allocator());
    defer memory.deinit();
    const scratch = memory.allocator();
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, false)).?;
    defer source.close();
    try std.testing.expectError(error.FileNotFound, source.dir.statFile(io, "refresh.lock", .{}));
    const source_json = try j.encodeAlloc(scratch, source.state, .{});
    const plan = try source.migrationObjects(scratch);
    try std.testing.expectEqual(@as(usize, 6), plan.len);
    const target_json = try j.encodeAlloc(scratch, try source.migrationTargetState(scratch), .{});
    try std.testing.expect(!source.state.sendQueue[0].resumeRequired);
    var destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, options);
    defer destination.close();
    try destination.copyMigrationObject(&source, &plan[0]);
    const copied_size = try destination.diskBytes();
    try destination.copyMigrationObject(&source, &plan[0]);
    try std.testing.expectEqual(copied_size, try destination.diskBytes());
    destination.close();
    source.close();
    source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    _ = try source.migrationObjects(scratch);
    destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, options);
    for (plan) |*object| try destination.copyMigrationObject(&source, object);
    // An incomplete map cannot make a source snapshot visible.
    try std.testing.expectError(error.MigrationSourceChanged, destination.publishMigrationSnapshot(&source, plan[0 .. plan.len - 1]));
    destination.options.disk_limit = try destination.diskBytes();
    try std.testing.expectError(error.DiskQuotaExceeded, destination.publishMigrationSnapshot(&source, plan));
    destination.options.disk_limit = options.disk_limit;
    try destination.publishMigrationSnapshot(&source, plan);
    try std.testing.expectEqualStrings(target_json, try j.encodeAlloc(scratch, destination.state, .{}));
    destination.close();
    destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, options);
    try std.testing.expectEqualStrings("MIGRATION PRIVATE BODY SENTENCE", (try destination.read("source-message")).?.bodyText);
    try std.testing.expectEqualStrings("Draft kept exactly", (try destination.draft(fixture.draft_id)).bodyText);
    try std.testing.expectEqualStrings("Exact retained outbox", (try destination.readOutbox("sent-before-migration")).?.bodyText);
    for ([_][]const u8{ "calendar-state.json", "follow-ups.json" }) |name| {
        try std.testing.expectEqualStrings((try source.readDocument(scratch, name, 1024)).?, (try destination.readDocument(scratch, name, 1024)).?);
    }
    // Scan persisted bytes with one fixed buffer. No logical source filename
    // or synthetic body/draft plaintext appears in the encrypted account.
    var files = destination.dir.iterate();
    var file_buffer: [64 * 1024 + 64]u8 = undefined;
    while (try files.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".vault-lock")) continue;
        try std.testing.expectEqual(@as(usize, 73), entry.name.len);
        try std.testing.expect(std.mem.startsWith(u8, entry.name, "vrec-") and std.mem.endsWith(u8, entry.name, ".bin"));
        const file = try destination.dir.openFile(io, entry.name, .{});
        defer file.close(io);
        var position: u64 = 0;
        var retained: usize = 0;
        while (true) {
            const n = try file.readPositional(io, &.{file_buffer[retained..]}, position);
            if (n == 0) break;
            position += n;
            for ([_][]const u8{ "MIGRATION PRIVATE", "migration@example.test", "exact synthetic ICS", "calendar-state.json", "source-message" }) |secret| try std.testing.expect(std.mem.indexOf(u8, file_buffer[0 .. retained + n], secret) == null);
            const end = retained + n;
            retained = @min(64, end);
            std.mem.copyForwards(u8, file_buffer[0..retained], file_buffer[end - retained .. end]);
        }
    }
    try std.testing.expect(destination.state.sendQueue[0].resumeRequired);
    try std.testing.expect(!destination.state.sendQueue[1].resumeRequired);
    try std.testing.expectEqual(storage.SendState.unknown, destination.state.sendQueue[1].state);
    try std.testing.expectEqualStrings("unknown", destination.state.operations[0].outcome);
    try std.testing.expectEqual(@as(u64, 77), destination.state.serial);
    try std.testing.expectEqualStrings(source_json, try j.encodeAlloc(scratch, source.state, .{}));
    try std.testing.expectEqual(@as(usize, 25 * 1024 * 1024), (try source.dir.statFile(io, plan[0].name, .{})).size);
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
    std.debug.print("migration request allocator peak={d} limit={d}\n", .{ cap.peak, cap.limit });
}

test "vault Store migration: missing inventory creates nothing and scratch or foreign data is never silently imported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var memory = std.heap.ArenaAllocator.init(a);
    defer memory.deinit();
    const scratch = memory.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", scratch);
    const missing = try std.fmt.allocPrint(scratch, "{s}/missing", .{base});
    try std.testing.expect((try Store.openMigration(io, scratch, missing, account, options, false)) == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing", .{}));
    const fixture = try Fixture.create(8);
    defer fixture.destroy();
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    defer source.close();
    const plan = try source.migrationObjects(scratch);
    var foreign = try Store.openMigrationDestination(io, scratch, &fixture.owner, other, options);
    defer foreign.close();
    try std.testing.expectError(error.MigrationSourceRequired, foreign.copyMigrationObject(&source, &plan[0]));
    foreign.close();
    const name = "send-spool-0123456789abcdef0123456789abcdef.mime";
    const file = try source.dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "synthetic interrupted send");
    file.close(io);
    try std.testing.expectError(error.MigrationSourceInvalid, source.migrationObjects(scratch));
    try std.testing.expect(source.migration_inventory == null);
    _ = try source.dir.statFile(io, name, .{});
}

test "vault Store migration: foreign source body remains refused even when its local index hash is replaced" {
    const fixture = try Fixture.create(8);
    defer fixture.destroy();
    var memory = std.heap.ArenaAllocator.init(a);
    defer memory.deinit();
    const scratch = memory.allocator();
    {
        var source = try Store.open(io, scratch, fixture.source_path, account, options);
        defer source.close();
        const forged = try j.encodeAlloc(scratch, .{ .schema = @as(u8, 1), .account = other, .message = t.Message{ .id = "source-message", .threadId = "thread", .bodyText = "Synthetic foreign payload" } }, .{});
        try source.write(try std.fmt.allocPrint(scratch, "mail-{s}.json", .{Store.hash("source-message")}), forged);
        const entry = source.find("source-message").?;
        entry.bytes = forged.len;
        entry.bodyHash = try scratch.dupe(u8, &Store.hash(forged));
        try source.save();
    }
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    defer source.close();
    try std.testing.expectError(error.CacheIdentityMismatch, source.migrationObjects(scratch));
    try std.testing.expect(source.migration_inventory == null);
}

test "vault Store migration: legacy index order and persisted quotas survive copy and reopen exactly" {
    const fixture = try Fixture.create(8);
    defer fixture.destroy();
    var memory = std.heap.ArenaAllocator.init(a);
    defer memory.deinit();
    const scratch = memory.allocator();
    {
        var source = try Store.open(io, scratch, fixture.source_path, account, options);
        defer source.close();
        try source.put(.{ .id = "newer-metadata", .threadId = "thread", .receivedAt = 12345 }, false);
        std.mem.swap(storage.Entry, &source.state.entries[0], &source.state.entries[1]);
        source.state.metadataPolicy = options.metadata_limit + 100;
        source.state.diskPolicy = options.disk_limit * 2;
        source.options.metadata_limit = source.state.metadataPolicy;
        source.options.disk_limit = source.state.diskPolicy;
        try source.save();
    }
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    defer source.close();
    try std.testing.expectEqualStrings("source-message", source.state.entries[0].message.id);
    const plan = try source.migrationObjects(scratch);
    const target = try j.encodeAlloc(scratch, try source.migrationTargetState(scratch), .{});
    var destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, source.options);
    defer destination.close();
    try std.testing.expectEqual(source.options.disk_limit, destination.options.disk_limit);
    try std.testing.expectEqual(source.options.metadata_limit, destination.options.metadata_limit);
    for (plan) |*object| try destination.copyMigrationObject(&source, object);
    try destination.publishMigrationSnapshot(&source, plan);
    destination.close();
    destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, source.options);
    try std.testing.expectEqualStrings(target, try j.encodeAlloc(scratch, destination.state, .{}));
}

test "vault Store migration: changed source or corrupt planned ciphertext refuses publication" {
    const fixture = try Fixture.create(1024);
    defer fixture.destroy();
    var memory = std.heap.ArenaAllocator.init(a);
    defer memory.deinit();
    const scratch = memory.allocator();
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    defer source.close();
    const plan = try source.migrationObjects(scratch);
    var destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, options);
    defer destination.close();
    try destination.copyMigrationObject(&source, &plan[0]);
    const selected = try destination.vaultContext();
    const corrupt = try selected.directory.dir.openFile(io, &plan[0].handle.filename(), .{ .mode = .read_write });
    const last = (try corrupt.stat(io)).size - 1;
    var byte: [1]u8 = undefined;
    _ = try corrupt.readPositionalAll(io, &byte, last);
    byte[0] ^= 1;
    try corrupt.writePositionalAll(io, &byte, last);
    corrupt.close(io);
    try std.testing.expectError(error.VaultAuthenticationFailed, destination.copyMigrationObject(&source, &plan[0]));
    const changed = try source.dir.openFile(io, plan[1].name, .{ .mode = .read_write });
    try changed.writePositionalAll(io, "x", 0);
    changed.close(io);
    try std.testing.expectError(error.MigrationSourceChanged, destination.copyMigrationObject(&source, &plan[1]));
    try std.testing.expectEqual(@as(usize, 0), destination.vaultObjects.len);
}

test "vault Store migration: full plaintext quota plans sealed overlap and scans once per destination lease" {
    const fixture = try Fixture.create(80 * 1024);
    defer fixture.destroy();
    {
        var setup = std.heap.ArenaAllocator.init(a);
        defer setup.deinit();
        var source = try Store.open(io, setup.allocator(), fixture.source_path, account, options);
        defer source.close();
        // Model a real source already filled to its persisted policy. A raw
        // synthetic index replacement avoids asking normal eviction to free
        // space for an unrelated setup transaction.
        source.state.diskPolicy = try source.diskBytes() + 128;
        try source.write("index.json", try j.encodeAlloc(setup.allocator(), source.state, .{}));
        try std.testing.expect(try source.diskBytes() <= source.state.diskPolicy);
    }
    var memory = std.heap.ArenaAllocator.init(a);
    defer memory.deinit();
    const scratch = memory.allocator();
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    defer source.close();
    const original = try j.encodeAlloc(scratch, source.state, .{});
    const objects = try source.migrationObjects(scratch);
    const capacity = try source.migrationCapacity(objects);
    try std.testing.expect(capacity.disk_limit > source.options.disk_limit);
    try std.testing.expectEqual(capacity.required_disk_bytes, capacity.disk_limit);
    var target_options = source.options;
    target_options.disk_limit = capacity.disk_limit;
    var destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, target_options);
    defer destination.close();
    try std.testing.expectEqual(@as(usize, 1), destination.disk_scan_count);
    for (objects) |*object| try destination.copyMigrationObject(&source, object);
    // Reused ciphertext and repeated publication consume no extra disk quota.
    const copied_bytes = destination.migration_disk_bytes.?;
    for (objects) |*object| try destination.copyMigrationObject(&source, object);
    try std.testing.expectEqual(copied_bytes, destination.migration_disk_bytes.?);
    try destination.publishMigrationSnapshot(&source, objects);
    try std.testing.expectEqual(capacity.sealed_bytes, destination.migration_disk_bytes.?);
    try destination.publishMigrationSnapshot(&source, objects);
    try std.testing.expectEqual(@as(usize, 1), destination.disk_scan_count);
    try std.testing.expectEqual(destination.migration_disk_bytes.?, try destination.diskBytes());
    try std.testing.expectEqual(capacity.disk_limit, destination.state.diskPolicy);
    try std.testing.expectEqual(capacity.index_bytes, @import("terminal/gmail_decode.zig").serializedBytes(.{ .schema = @as(u8, 1), .state = destination.state, .objects = destination.vaultObjects }));
    try std.testing.expectEqualStrings(original, try j.encodeAlloc(scratch, source.state, .{}));
    destination.close();
    destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, target_options);
    try std.testing.expectEqual(@as(usize, 1), destination.disk_scan_count);
    for (objects) |*object| try destination.copyMigrationObject(&source, object);
    try destination.publishMigrationSnapshot(&source, objects);
    try std.testing.expectEqual(@as(usize, 1), destination.disk_scan_count);
}

test "vault Store migration: source leases survive parsed account lifetimes and block writers and refresh" {
    const fixture = try Fixture.create(8);
    defer fixture.destroy();
    var lease = (try storage.MigrationLease.acquire(io, fixture.source_path, account, options, true)).?;
    defer lease.close();
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = a, .limit = 1024 * 1024 };
    for (0..3) |_| {
        var memory = std.heap.ArenaAllocator.init(cap.allocator());
        defer memory.deinit();
        var source = try Store.openMigrationLeased(io, memory.allocator(), &lease, account, options);
        defer source.close();
        _ = try source.migrationObjects(memory.allocator());
        _ = try source.migrationTargetState(memory.allocator());
        source.close();
        try std.testing.expect(!lease.closed);
        try std.testing.expect((try storage.RefreshLease.acquire(io, fixture.source_path, account, options)) == null);
        // This is the between-account gap that used to release source locks.
        try std.testing.expectError(error.CacheBusy, Store.open(io, memory.allocator(), fixture.source_path, account, options));
        var reader = try Store.openCached(io, memory.allocator(), fixture.source_path, account, options);
        reader.close();
    }
    try std.testing.expectEqual(@as(usize, 0), cap.used);
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
    lease.close();
    var memory = std.heap.ArenaAllocator.init(a);
    defer memory.deinit();
    try std.testing.expectError(error.MigrationSourceRequired, Store.openMigrationLeased(io, memory.allocator(), &lease, account, options));
    var writer = try Store.open(io, memory.allocator(), fixture.source_path, account, options);
    writer.close();
    var refresh = (try storage.RefreshLease.acquire(io, fixture.source_path, account, options)).?;
    refresh.release();
}

test "vault Store migration: wide source index admits object map above plaintext ceiling and refuses hard bounds early" {
    const fixture = try Fixture.create(8);
    defer fixture.destroy();
    {
        var setup = std.heap.ArenaAllocator.init(a);
        defer setup.deinit();
        const arena = setup.allocator();
        var source = try Store.open(io, arena, fixture.source_path, account, options);
        defer source.close();
        const entries = try arena.alloc(storage.Entry, 4000);
        entries[0] = source.state.entries[0];
        const subject = try arena.alloc(u8, 2048);
        @memset(subject, 'w');
        for (entries[1..], 1..) |*entry, index| entry.* = .{ .message = .{ .id = try std.fmt.allocPrint(arena, "wide-{d}", .{index}), .threadId = "wide-thread", .subject = subject } };
        source.state.entries = entries;
        source.options.metadata_limit = t.Limits.metadata_hard;
        source.state.metadataPolicy = t.Limits.metadata_hard;
        const count = @import("terminal/gmail_decode.zig").serializedBytes;
        const target_bytes = storage.index_write_bytes - 128;
        var state_bytes = count(source.state);
        while (state_bytes > target_bytes) {
            state_bytes -= count(source.state.entries[source.state.entries.len - 1]) + 1;
            source.state.entries = source.state.entries[0 .. source.state.entries.len - 1];
        }
        const tail = &source.state.entries[source.state.entries.len - 1].message;
        const padded = try arena.alloc(u8, tail.subject.len + target_bytes - count(source.state));
        @memset(padded, 'w');
        tail.subject = padded;
        try std.testing.expectEqual(target_bytes, count(source.state));
        try source.save();
    }
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = a, .limit = 64 * 1024 * 1024 };
    var memory = std.heap.ArenaAllocator.init(cap.allocator());
    defer memory.deinit();
    const scratch = memory.allocator();
    var source = (try Store.openMigration(io, scratch, fixture.source_path, account, options, true)).?;
    defer source.close();
    const objects = try source.migrationObjects(scratch);
    const capacity = try source.migrationCapacity(objects);
    try std.testing.expect(capacity.index_bytes > storage.index_write_bytes);
    try std.testing.expect(capacity.index_bytes < storage.vault_index_write_bytes);
    var target_options = source.options;
    target_options.disk_limit = capacity.disk_limit;
    var destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, target_options);
    defer destination.close();
    for (objects) |*object| try destination.copyMigrationObject(&source, object);
    try destination.publishMigrationSnapshot(&source, objects);
    destination.close();
    destination = try Store.openMigrationDestination(io, scratch, &fixture.owner, account, target_options);
    try std.testing.expectEqual(source.state.entries.len, destination.state.entries.len);
    try std.testing.expectEqualStrings(source.state.entries[source.state.entries.len - 1].message.subject, destination.state.entries[destination.state.entries.len - 1].message.subject);
    var impossible: [17]storage.MigrationObject = @splat(objects[0]);
    for (&impossible) |*object| object.size = vt.max_record_bytes;
    try std.testing.expectError(error.MigrationDiskQuotaExceeded, source.migrationCapacity(&impossible));
    // Admission rejects an oversized state before copy can publish anything.
    const saved_subject = source.state.entries[0].message.subject;
    const excess = try scratch.alloc(u8, storage.vault_index_write_bytes);
    @memset(excess, 'e');
    source.state.entries[0].message.subject = excess;
    try std.testing.expectError(error.MigrationIndexTooLarge, source.migrationObjects(scratch));
    try std.testing.expect(source.migration_inventory == null);
    source.state.entries[0].message.subject = saved_subject;
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
    std.debug.print("migration wide index request allocator peak={d} limit={d}\n", .{ cap.peak, cap.limit });
}
