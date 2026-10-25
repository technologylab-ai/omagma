const std = @import("std");
const storage = @import("terminal/store.zig");
const history = @import("terminal/operation_history.zig");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;

fn accepted(s: *storage.Store, index: usize) !void {
    const a = s.allocator;
    const draft = try s.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .subject = "Retained source", .bodyText = try std.fmt.allocPrint(a, "Complete authored source {d}", .{index}), .original = .{ .bodyText = "Exact original", .bodyHtml = "<p>Exact original</p>" } }, null);
    try markApplied(s, draft, index);
}
fn markApplied(s: *storage.Store, draft: t.Draft, index: usize) !void {
    const a = s.allocator;
    const digest = storage.Store.hash(try @import("terminal/send_outcome.zig").payload(a, draft, s.state.account, null));
    const ops = try a.alloc(storage.Operation, s.state.operations.len + 1);
    @memcpy(ops[0..s.state.operations.len], s.state.operations);
    ops[s.state.operations.len] = .{ .id = try std.fmt.allocPrint(a, "operation-{d}", .{index}), .hash = try a.dupe(u8, &digest), .draftId = draft.id, .outcome = "applied", .messageId = try std.fmt.allocPrint(a, "provider-{d}", .{index}) };
    s.state.operations = ops;
    try s.save();
}

test "retained history: excluded originals keep blob pins and unknown Gmail Calendar work stays active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const file = try tmp.dir.createFile(io, "source.bin", .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "retained image bytes");
    file.close(io);
    var store = try storage.Store.open(io, a, try std.fmt.allocPrint(a, "{s}/cache", .{base}), "self@example.test", .{ .fixtures = true });
    defer store.close();
    const blob = try @import("terminal/attachment_blob.zig").importFile(&store, try std.fmt.allocPrint(a, "{s}/source.bin", .{base}), "application/octet-stream");
    const saved = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Authored", .includeOriginal = false, .original = .{ .bodyText = "Full retained original", .resources = &.{blob} } }, null);
    try markApplied(&store, saved, 0);
    const unknown = try store.putDraft(.{ .bodyText = "Unknown source" }, null);
    const paused = try store.putDraft(.{ .bodyText = "Paused Gmail source" }, null);
    const calendar = try store.putDraft(.{ .bodyText = "Unfinished Calendar source" }, null);
    const op_list = try a.alloc(storage.Operation, 4);
    op_list[0] = store.state.operations[0];
    op_list[1] = .{ .id = "unknown", .hash = "unknown-hash", .draftId = unknown.id };
    op_list[2] = .{ .id = "gmail", .hash = "gmail-hash", .draftId = paused.id, .outcome = "applied" };
    op_list[3] = .{ .id = "calendar", .hash = "calendar-hash", .draftId = calendar.id, .outcome = "applied", .icalendar = "pending", .calendarSync = .{ .state = .unknown, .canRetry = true } };
    store.state.operations = op_list;
    store.state.draftLinks = try a.dupe(@import("terminal/draft_link.zig").Link, &.{.{ .draftId = paused.id, .attemptMessageId = "<upload@example.test>", .uploadedDigest = &storage.Store.hash("paused") }});
    try store.save();
    try history.compact(&store, true);
    try std.testing.expectEqual(@as(usize, 3), store.state.operations.len);
    try std.testing.expectEqual(@as(usize, 3), store.state.drafts.len);
    try std.testing.expect(try store.blobReferencedVerified(blob.blobId.?));
    const restored = try store.draft(saved.id);
    try std.testing.expect(!restored.includeOriginal);
    try std.testing.expectEqualStrings("Full retained original", restored.original.?.bodyText);
    try std.testing.expectEqualStrings(blob.blobId.?, restored.original.?.resources[0].blobId.?);
    try store.clearMail();
    try std.testing.expect(try store.blobReferencedVerified(blob.blobId.?));
    _ = try history.deleteSource(&store, saved.id);
    try std.testing.expect(!try store.blobReferencedVerified(blob.blobId.?));
    try std.testing.expectEqual(@as(usize, 1), try history.pruneSourceFiles(&store, saved.id));
    try std.testing.expectEqual(@as(usize, 0), try history.pruneSourceFiles(&store, saved.id));
}

test "retained history: migration preserves direct history handles outside the encrypted active map" {
    const catalog = @import("terminal/vault_catalog.zig");
    const vt = @import("terminal/vault_types.zig");
    const handles = @import("terminal/vault_storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const root = try std.fmt.allocPrint(a, "{s}/cache", .{base});
    const account = "self@example.test";
    const options: t.Options = .{ .fixtures = true };
    var source_store = try storage.Store.open(io, a, root, account, options);
    const blob_module = @import("terminal/attachment_blob.zig");
    var incoming = try blob_module.Incoming.create(&source_store, 3);
    defer incoming.close();
    try incoming.write("new");
    try incoming.finish(3);
    const indexed_blob = try incoming.commit(&source_store, .{ .id = "new", .filename = "new.bin", .size = 3 });
    const legacy_id = try a.dupe(u8, &storage.Store.hash("legacy"));
    const legacy_name = try blob_module.filename(a, legacy_id);
    const old_file = try source_store.dir.createFile(io, legacy_name, .{ .permissions = .fromMode(0o600) });
    try old_file.writeStreamingAll(io, "legacy");
    old_file.close(io);
    const legacy_blob: t.Attachment = .{ .id = "old", .blobId = legacy_id, .filename = "old.bin", .size = 6 };
    const sent = try source_store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Complete authored source 0", .original = .{ .bodyHtml = "<p>Exact original</p>" }, .attachments = &.{ indexed_blob, legacy_blob } }, null);
    try markApplied(&source_store, sent, 0);
    const draft_id = sent.id;
    try history.compact(&source_store, true);
    source_store.close();
    var key = try @import("terminal/vault_crypto.zig").createDataKey(io);
    defer key.wipe();
    const descriptor: @import("terminal/vault_header.zig").Header = .{ .vault_id = key.vault_id, .key_id = key.key_id, .root_record = try handles.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
    var workspace: vt.StreamWorkspace = undefined;
    var owner = try catalog.Owner.create(io, try std.fmt.allocPrint(a, "{s}/sealed", .{base}), descriptor, &key, &workspace);
    defer owner.close();
    const config = try a.create(@import("config.zig").Config);
    try config.defaults("/nonexistent/synthetic-history-home");
    config.credential_store = .vault;
    config.count = 1;
    try config.accounts[0].address.set(account);
    var identity = try @import("terminal/vault_identity.zig").State.createWithAccounts(&owner, std.testing.allocator, config, &.{.{ .account = account, .initial_index = try storage.Store.initialVaultIndex(a, account, options), .disk_limit = options.disk_limit }});
    defer identity.deinit();
    var source = (try storage.Store.openMigration(io, a, root, account, options, true)).?;
    defer source.close();
    const objects = try source.migrationObjects(a);
    var destination = try storage.Store.openMigrationDestination(io, a, &owner, account, options);
    defer destination.close();
    for (objects) |*object| try destination.copyMigrationObject(&source, object);
    try destination.publishMigrationSnapshot(&source, objects);
    try std.testing.expectEqual(@as(usize, 1), destination.vaultObjects.len);
    try std.testing.expectEqualStrings("Complete authored source 0", (try destination.draft(draft_id)).bodyText);
    try blob_module.verify(&destination, indexed_blob);
    try blob_module.verify(&destination, legacy_blob);
    try std.testing.expectError(error.AttachmentInUse, blob_module.discard(&destination, indexed_blob.blobId.?));
    try std.testing.expectEqualStrings("applied", (try destination.findOperation(a, "operation-0")).?.outcome);
    // Read the encrypted snapshot from a new account lease, then append a new
    // history publication using the same direct-addressed record contract.
    destination.close();
    var selected = try owner.openAccount(account);
    defer selected.close();
    var reopened = try storage.Store.openVault(io, a, &selected, options, false);
    defer reopened.close();
    try accepted(&reopened, 1);
    try history.compact(&reopened, true);
    try std.testing.expectEqual(@as(usize, 1), reopened.vaultObjects.len);
    try blob_module.verify(&reopened, indexed_blob);
    _ = try history.deleteSource(&reopened, draft_id);
    try std.testing.expectEqual(@as(usize, 2), try history.pruneSourceFiles(&reopened, draft_id));
    try std.testing.expectEqual(@as(usize, 0), (try reopened.blobStats()).count);
    try std.testing.expectError(error.ArchivedSourceDeleted, reopened.draft(draft_id));
    try std.testing.expectEqualStrings("applied", (try reopened.findOperation(a, "operation-0")).?.outcome);
}

test "retained history: plaintext accepted sources leave active index and replay fences survive deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer setup.deinit();
    const a = setup.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/history", .{tmp.sub_path});
    const options: t.Options = .{ .fixtures = true };
    var first_id: []const u8 = "";
    for (0..129) |index| {
        var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer phase.deinit();
        var store = try storage.Store.open(io, phase.allocator(), root, "self@example.test", options);
        defer store.close();
        try accepted(&store, index);
        if (index == 0) first_id = try a.dupe(u8, store.state.drafts[0].id);
        try std.testing.expect(store.state.drafts.len <= 64);
        try std.testing.expect(store.state.operations.len <= 64);
    }
    var store = try storage.Store.open(io, a, root, "self@example.test", options);
    defer store.close();
    const receipt = (try store.findOperation(a, "operation-0")).?;
    try std.testing.expectEqualStrings(first_id, receipt.draftId);
    try std.testing.expectEqualStrings("Complete authored source 0", (try store.draft(first_id)).bodyText);
    try std.testing.expectEqualStrings("<p>Exact original</p>", (try store.draft(first_id)).original.?.bodyHtml);
    try std.testing.expectError(error.ArchivedDraftReadOnly, store.putDraft(.{ .bodyText = "Changed" }, first_id));
    try store.clearMail();
    try std.testing.expectEqualStrings(receipt.hash, (try store.findOperation(a, "operation-0")).?.hash);
    var cursor: []const u8 = "";
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    while (true) {
        const page = try history.list(&store, a, .operation, cursor, 7);
        const items = j.get(page, "items").?.array.items;
        try std.testing.expect(items.len <= 7);
        for (items) |item| try std.testing.expect(!(try seen.getOrPut(j.text(item, "id"))).found_existing);
        cursor = j.text(page, "nextCursor");
        if (cursor.len == 0) break;
    }
    try std.testing.expectEqual(store.state.history.operations, seen.count());
    try std.testing.expect(seen.contains("operation-0"));
    try std.testing.expect(try history.deleteSource(&store, first_id));
    try std.testing.expectError(error.ArchivedSourceDeleted, store.draft(first_id));
    try std.testing.expectEqualStrings(receipt.hash, (try store.findOperation(a, "operation-0")).?.hash);
    try std.testing.expect(!try history.deleteSource(&store, first_id));
}

test "retained history: publication faults retain either complete active or complete archived state" {
    for ([_]bool{ false, true }) |after| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/history-fault", .{tmp.sub_path});
        var store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
        defer store.close();
        try accepted(&store, 0);
        const draft_id = store.state.drafts[0].id;
        const before_bytes = try store.diskBytes();
        store.history_fault = if (after) .after_publication else .before_publication;
        try std.testing.expectError(error.InjectedHistoryPublication, history.compact(&store, true));
        store.close();
        store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
        try std.testing.expectEqual(@as(usize, if (after) 0 else 1), store.state.drafts.len);
        try std.testing.expectEqualStrings("Complete authored source 0", (try store.draft(draft_id)).bodyText);
        try std.testing.expectEqualStrings("applied", (try store.findOperation(a, "operation-0")).?.outcome);
        try std.testing.expectEqual(@as(usize, 0), store.state.history.cleanup.len);
        if (!after) try std.testing.expectEqual(before_bytes, try store.diskBytes());
    }
}

test "retained history: canceled queue receipts retain their original operation identity after paging" {
    const queue = @import("terminal/send_queue.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/history-queue", .{tmp.sub_path});
    var store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const draft = try store.putDraft(.{ .bodyText = "Still editable" }, null);
    const digest = storage.Store.hash("same reviewed draft");
    var oldest: []const u8 = "";
    for (0..129) |index| {
        const operation_id = try std.fmt.allocPrint(a, "canceled-{d}", .{index});
        const entry = try queue.stage(&store, draft.id, operation_id, &digest, 0, 0);
        if (index == 0) oldest = entry.queueId;
        _ = try queue.cancel(&store, entry.queueId);
    }
    store.close();
    store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
    try std.testing.expect(store.state.sendQueue.len < 64);
    try std.testing.expectEqual(storage.SendState.canceled, (try queue.find(&store, oldest)).state);
    const replayed = try queue.stage(&store, draft.id, "canceled-0", &digest, 0, 0);
    try std.testing.expectEqualStrings(oldest, replayed.queueId);
    try std.testing.expectEqual(storage.SendState.canceled, replayed.state);
    try std.testing.expectError(error.OperationConflict, queue.stage(&store, draft.id, "canceled-0", &storage.Store.hash("changed"), 0, 0));
    try std.testing.expectError(error.SendAlreadySubmitted, queue.resumeEntry(&store, oldest, 0, 0));
}

test "retained migration: inventory and authenticated plan pages exceed the former lifetime object ceiling" {
    const journal = @import("terminal/vault_migration_journal.zig");
    const handles = @import("terminal/vault_storage.zig");
    const vt = @import("terminal/vault_types.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const root = try std.fmt.allocPrint(a, "{s}/cache", .{base});
    const account = "history@example.test";
    const options: t.Options = .{ .fixtures = true };
    var store = try storage.Store.open(io, a, root, account, options);
    try store.save();
    const count = journal.max_objects + 1;
    for (0..count) |index| {
        var key: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&key, "synthetic-owned-history-{d}", .{index});
        var name_buffer: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "history-page-{s}.json", .{storage.Store.hash(label)});
        const file = try store.dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, "{}");
        file.close(io);
    }
    store.close();
    var source = (try storage.Store.openMigration(io, a, root, account, options, true)).?;
    defer source.close();
    const objects = try source.migrationObjects(a);
    try std.testing.expectEqual(count, objects.len);
    try std.testing.expectEqual(@as(usize, 0), storage.Store.migrationMappedCount(objects));
    const planned = try a.alloc(journal.Object, objects.len);
    for (objects, planned) |object, *target| target.* = .{ .name = object.name, .kind = object.kind, .size = object.size, .sha256 = object.sha256, .handle = object.handle };
    var key = try @import("terminal/vault_crypto.zig").createDataKey(io);
    defer key.wipe();
    const workspace = try std.testing.allocator.create(vt.StreamWorkspace);
    defer {
        workspace.wipe();
        std.testing.allocator.destroy(workspace);
    }
    const path = try std.fmt.allocPrint(a, "{s}/plan", .{base});
    const parent = try @import("keyring_file.zig").directory(io, path, true);
    parent.close(io);
    const log_id = try handles.Handle.create(io);
    var log = try journal.Journal.open(io, std.testing.allocator, path, &key, workspace, log_id, true);
    defer log.close();
    const manifest: journal.Manifest = .{ .vault_id = key.vault_id, .source = .{ .config = "/synthetic/config", .grants = "/synthetic/grants", .cache = root }, .identity_sha256 = @splat(0x11), .accounts = &.{.{ .account = account, .present = true, .state_sha256 = try journal.digest(source.state), .target_state_sha256 = try journal.digest(try source.migrationTargetState(a)), .objects = planned }} };
    // A crash before the root exists cannot authorize even the first copy.
    log.fixture_stop_after_page = 1;
    try std.testing.expectError(error.VaultMigrationInterrupted, log.createManifest(manifest));
    try std.testing.expectError(error.FileNotFound, log.readManifest(a));
    log.close();
    log = try journal.Journal.open(io, std.testing.allocator, path, &key, workspace, log_id, false);
    try log.discardIncompletePlan();
    try log.createManifest(manifest);
    const recovered = try log.readManifest(a);
    try std.testing.expectEqual(@as(u8, 2), recovered.schema);
    try std.testing.expectEqual(count, recovered.objectCount());
    try std.testing.expectEqual(@as(usize, 0), recovered.accounts[0].objects.len);
    try std.testing.expect(@import("terminal/gmail_decode.zig").serializedBytes(recovered) < 64 * 1024);
    for ([_]usize{ 0, count / journal.objects_per_page / 2, (count - 1) / journal.objects_per_page }) |page_index| {
        var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer phase.deinit();
        const page = try log.objectPage(phase.allocator(), recovered.accounts[0], page_index);
        try std.testing.expect(page.len <= journal.objects_per_page);
        const expected = objects[page_index * journal.objects_per_page];
        try std.testing.expectEqualStrings(expected.name, page[0].name);
        try std.testing.expectEqualSlices(u8, &expected.handle.bytes, &page[0].handle.bytes);
    }
    try std.testing.expectError(error.PathAlreadyExists, log.discardIncompletePlan());
    try log.saveProgress(.{ .next_object = count - 1 }, recovered);
    log.close();
    log = try journal.Journal.open(io, std.testing.allocator, path, &key, workspace, log_id, false);
    try std.testing.expectEqual(count - 1, (try log.readProgress(a, try log.readManifest(a))).next_object);
    try std.testing.expectError(error.InvalidVaultMigration, log.saveProgress(.{ .next_object = count - 1, .published_accounts = 1, .verified = true }, recovered));
}

test "retained history: a missing or truncated lookup bucket cannot forget a replay fence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/closed-fence", .{tmp.sub_path});
    var store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    try accepted(&store, 0);
    try history.compact(&store, true);
    const location = (try history.locate(&store, a, .operation, "operation-0")).?;
    var selected: usize = 0;
    for (store.state.history.buckets, 0..) |head, index| {
        if (head.len == 0) continue;
        const path = try history.fileName(a, "index", head);
        const raw = try store.readHistory(a, path, history.page_bytes);
        const bucket = try std.json.parseFromSliceLeaky(history.Bucket, a, raw, .{});
        for (bucket.entries) |entry| if (entry.kind == .operation and std.mem.eql(u8, entry.id, "operation-0")) {
            selected = index;
        };
    }
    const head = store.state.history.buckets[selected];
    store.state.history.buckets[selected] = "";
    try std.testing.expectError(error.InvalidHistory, store.findOperation(a, "operation-0"));
    store.state.history.buckets[selected] = head;
    try store.dir.deleteFile(io, try history.fileName(a, "index", head));
    try std.testing.expectError(error.HistoryRecordMissing, store.findOperation(a, "operation-0"));
    // A valid global receipt page still exists; lookup must fail closed rather
    // than returning not-found and authorizing a new provider submission.
    try std.testing.expectEqualStrings("operation-0", (try history.readPage(&store, a, location.page)).records[location.slot].operation.id);
}

test "retained history: deduplicating a legacy archived file cannot erase its unknown pin count" {
    const blob = @import("terminal/attachment_blob.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-pins", .{tmp.sub_path});
    var store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const id = try a.dupe(u8, &storage.Store.hash("legacy bytes"));
    const name = try blob.filename(a, id);
    const file = try store.dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "legacy bytes");
    file.close(io);
    const attachment: t.Attachment = .{ .id = "old", .filename = "old.bin", .size = 12, .blobId = id };
    const draft = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Old accepted source", .attachments = &.{attachment} }, null);
    try markApplied(&store, draft, 0);
    try history.compact(&store, true);
    try std.testing.expect(store.state.history.unindexedBlobPins);
    const path = try store.dir.realPathFileAlloc(io, name, a);
    const reused = try blob.importFile(&store, path, "application/octet-stream");
    try std.testing.expectEqualStrings(id, reused.blobId.?);
    try std.testing.expect((try history.findBlob(&store, a, id)).?.references == null);
    try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, id));
    try blob.verify(&store, attachment);
    _ = try history.deleteSource(&store, draft.id);
    try std.testing.expectEqual(@as(usize, 1), try history.pruneSourceFiles(&store, draft.id));
}

const PinFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    key: @import("terminal/vault_types.zig").DataKey,
    workspace: @import("terminal/vault_types.zig").StreamWorkspace,
    owner: ?@import("terminal/vault_catalog.zig").Owner = null,
    account: ?@import("terminal/vault_catalog.zig").Account = null,
    fn init(self: *PinFixture, encrypted: bool) !void {
        self.owner = null;
        self.account = null;
        self.tmp = std.testing.tmpDir(.{});
        self.arena = .init(std.testing.allocator);
        const a = self.arena.allocator();
        const base = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        self.root = try std.fmt.allocPrint(a, "{s}/cache", .{base});
        self.key = try @import("terminal/vault_crypto.zig").createDataKey(io);
        if (encrypted) {
            const descriptor: @import("terminal/vault_header.zig").Header = .{ .vault_id = self.key.vault_id, .key_id = self.key.key_id, .root_record = try @import("terminal/vault_storage.zig").Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
            self.owner = try @import("terminal/vault_catalog.zig").Owner.create(io, try std.fmt.allocPrint(a, "{s}/vault", .{base}), descriptor, &self.key, &self.workspace);
            try storage.Store.createVaultAccount(&self.owner.?, a, "self@example.test", .{ .fixtures = true });
            self.account = try self.owner.?.openAccount("self@example.test");
        }
    }
    fn close(self: *PinFixture) void {
        if (self.account) |*account| account.close();
        if (self.owner) |*owner| owner.close();
        self.key.wipe();
        self.workspace.wipe();
        self.arena.deinit();
        self.tmp.cleanup();
    }
    fn open(self: *PinFixture, a: std.mem.Allocator) !storage.Store {
        return if (self.account) |*account| storage.Store.openVault(io, a, account, .{ .fixtures = true }, false) else storage.Store.open(io, a, self.root, "self@example.test", .{ .fixtures = true });
    }
};
fn tinyFile(store: *storage.Store, bytes: []const u8) !t.Attachment {
    var incoming = try @import("terminal/attachment_blob.zig").Incoming.create(store, bytes.len);
    defer incoming.close();
    try incoming.write(bytes);
    try incoming.finish(bytes.len);
    return incoming.commit(store, .{ .id = bytes, .filename = "source.bin", .mimeType = "application/octet-stream", .size = bytes.len });
}

test "active draft pins: immutable source and pins publish together across faults in both stores" {
    const blobs = @import("terminal/attachment_blob.zig");
    for ([_]bool{ false, true }) |encrypted| for ([_]bool{ false, true }) |after| {
        var fixture: PinFixture = undefined;
        try fixture.init(encrypted);
        defer fixture.close();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try fixture.open(a);
        defer store.close();
        const old = try tinyFile(&store, "old");
        const new = try tinyFile(&store, "new");
        const retained = try tinyFile(&store, "retained");
        const first = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Before", .attachments = &.{old}, .includeOriginal = false, .original = .{ .bodyText = "Immutable original", .resources = &.{retained} } }, null);
        const original_owned = try store.activeDraftOwnedRecords(a, first.id);
        var changed = first;
        changed.bodyText = "After";
        changed.attachments = &.{new};
        store.history_fault = if (after) .after_publication else .before_publication;
        try std.testing.expectError(error.InjectedHistoryPublication, store.putDraft(changed, first.id));
        store.close();
        store = try fixture.open(a);
        const recovered = try store.draft(first.id);
        try std.testing.expectEqualStrings(if (after) "After" else "Before", recovered.bodyText);
        try std.testing.expectEqualStrings(if (after) new.blobId.? else old.blobId.?, recovered.attachments[0].blobId.?);
        try std.testing.expect(recovered.summaryCounts == null);
        try std.testing.expectEqualStrings("Immutable original", recovered.original.?.bodyText);
        try std.testing.expect(!recovered.includeOriginal);
        try std.testing.expectError(error.AttachmentInUse, blobs.discard(&store, recovered.attachments[0].blobId.?));
        try std.testing.expectError(error.AttachmentInUse, blobs.discard(&store, retained.blobId.?));
        try std.testing.expect(!try store.blobReferencedVerified(if (after) old.blobId.? else new.blobId.?));
        try std.testing.expectEqual(@as(usize, 0), store.state.history.cleanup.len);
        if (after) for (original_owned) |name| try std.testing.expectError(error.HistoryRecordMissing, store.readHistory(a, name, storage.mail_record_bytes));
        try store.discardDraft(first.id);
        try blobs.discard(&store, retained.blobId.?);
    };
}

test "active draft pins: 128 metadata-heavy unsent drafts keep exact sources outside the hot index" {
    for ([_]bool{ false, true }) |encrypted| {
        var fixture: PinFixture = undefined;
        try fixture.init(encrypted);
        defer fixture.close();
        const a = fixture.arena.allocator();
        const long_name = try a.alloc(u8, 512);
        @memset(long_name, 'a');
        const recipients = try a.alloc(t.Address, t.Limits.recipients);
        for (recipients, 0..) |*entry, index| entry.* = .{ .address = try std.fmt.allocPrint(a, "peer-{d}@example.test", .{index}), .name = long_name };
        const files = try a.alloc(t.Attachment, t.Limits.attachments);
        for (files, 0..) |*entry, index| entry.* = .{ .id = try std.fmt.allocPrint(a, "file-{d}", .{index}), .filename = long_name, .mimeType = "application/octet-stream", .size = 0 };
        var first: []const u8 = "";
        var last: []const u8 = "";
        for (0..128) |index| {
            var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer phase.deinit();
            var store = try fixture.open(phase.allocator());
            defer store.close();
            const input: t.Draft = .{ .to = recipients, .attachments = files, .subject = "Complete metadata retained", .bodyText = "Authored source" };
            try @import("terminal/draft_codec.zig").validateDraft(input, false);
            const saved = try store.putDraft(input, null);
            if (index == 0) first = try a.dupe(u8, saved.id);
            if (index == 127) last = try a.dupe(u8, saved.id);
            try std.testing.expect(@import("terminal/gmail_decode.zig").serializedBytes(store.state) < 128 * 1024);
            try std.testing.expectEqual(@as(usize, 0), store.state.drafts[index].attachments.len);
            try std.testing.expectEqual(files.len, store.state.drafts[index].summaryCounts.?.attachments);
            try std.testing.expectEqual(@as(usize, 0), store.state.relatedDraftBlobs[index].blobs.len);
            if (encrypted) try std.testing.expectEqual(@as(usize, 0), store.vaultObjects.len);
        }
        var phase: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer phase.deinit();
        var reopened = try fixture.open(phase.allocator());
        defer reopened.close();
        try std.testing.expectEqual(@as(usize, 128), reopened.state.drafts.len);
        for ([_][]const u8{ first, last }) |id| {
            const exact = try reopened.draft(id);
            try std.testing.expectEqual(recipients.len, exact.to.len);
            try std.testing.expectEqual(files.len, exact.attachments.len);
            try std.testing.expectEqualStrings(long_name, exact.to[exact.to.len - 1].name);
            try std.testing.expectEqualStrings(long_name, exact.attachments[exact.attachments.len - 1].filename);
            try std.testing.expectEqualStrings("Authored source", exact.bodyText);
        }
        try std.testing.expectError(error.DraftLimitExceeded, reopened.putDraft(.{ .bodyText = "Actual active capacity" }, null));
    }
}

test "active draft pins: legacy named sources convert without changing an unknown operation digest" {
    const blob = @import("terminal/attachment_blob.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/legacy-active", .{tmp.sub_path});
    var store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const id = try a.dupe(u8, &storage.Store.hash("legacy source file"));
    const file = try store.dir.createFile(io, try blob.filename(a, id), .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, "legacy source file");
    file.close(io);
    const file_value: t.Attachment = .{ .id = "old-file", .blobId = id, .size = 18, .filename = "old.bin" };
    const saved = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Exact old draft", .attachments = &.{file_value}, .original = .{ .bodyText = "Original", .resources = &.{file_value} } }, null);
    const raw = try store.activeDraftBytes(a, saved.id);
    try store.write(try store.fileName("draft", saved.id), raw);
    var preview = saved;
    preview.bodyText = "";
    preview.original = null;
    preview.summaryCounts = null;
    store.state.schema = 1;
    store.state.drafts = try a.dupe(t.Draft, &.{preview});
    store.state.relatedDraftBlobs = &.{.{ .draftId = saved.id, .blobs = &.{id} }};
    const digest = try @import("terminal/send_outcome.zig").digest(a, saved, store.state.account, null);
    store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "unknown-old", .hash = &digest, .draftId = saved.id, .outcome = "unknown" }});
    var value = try std.json.parseFromSliceLeaky(j.Value, a, try j.encodeAlloc(a, store.state, .{}), .{ .allocate = .alloc_if_needed });
    _ = value.object.orderedRemove("history");
    for (value.object.getPtr("drafts").?.array.items) |*draft| {
        _ = draft.object.orderedRemove("summaryCounts");
        _ = draft.object.orderedRemove("includeOriginal");
    }
    for (value.object.getPtr("relatedDraftBlobs").?.array.items) |*reference| _ = reference.object.orderedRemove("handle");
    try store.write("index.json", try j.encodeAlloc(a, value, .{}));
    store.close();
    store = try storage.Store.openCached(io, a, root, "self@example.test", .{ .fixtures = true });
    try std.testing.expectEqual(@as(u8, 1), store.state.schema);
    try std.testing.expect(store.state.drafts[0].summaryCounts == null);
    store.close();
    store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
    try std.testing.expectEqual(@as(u8, 2), store.state.schema);
    try std.testing.expectEqual(@as(usize, 1), store.state.drafts[0].summaryCounts.?.attachments);
    try std.testing.expectEqual(@as(usize, 64), store.state.relatedDraftBlobs[0].handle.len);
    try std.testing.expectEqualStrings(raw, try store.activeDraftBytes(a, saved.id));
    const same = try store.putDraft(try store.draft(saved.id), saved.id);
    try std.testing.expectEqualSlices(u8, &digest, &(try @import("terminal/send_outcome.zig").digest(a, same, store.state.account, null)));
    try std.testing.expectEqualStrings("unknown", (try store.findOperation(a, "unknown-old")).?.outcome);
    try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, id));
    try std.testing.expectError(error.UnknownOutcome, store.discardDraft(saved.id));
}

test "retained history: applied sources stay immutable through archive publication failure and protected compaction" {
    for ([_]bool{ false, true }) |encrypted| {
        var fixture: PinFixture = undefined;
        try fixture.init(encrypted);
        defer fixture.close();
        const a = fixture.arena.allocator();
        var store = try fixture.open(a);
        defer store.close();
        const original = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Exact accepted source" }, null);
        try markApplied(&store, original, 0);
        store.history_fault = .before_publication;
        try std.testing.expectError(error.InjectedHistoryPublication, history.compact(&store, true));
        store.history_fault = .none;
        var changed = original;
        changed.bodyText = "Must use a new draft ID";
        try std.testing.expectError(error.ArchivedDraftReadOnly, store.putDraft(changed, original.id));
        store.close();
        store = try fixture.open(a);
        try std.testing.expectError(error.ArchivedDraftReadOnly, store.discardDraft(original.id));
        store.close();
        store = try fixture.open(a);
        // Identical saves preserve the exact protected source and old receipt.
        _ = try store.putDraft(original, original.id);
        try markApplied(&store, original, 1);
        store.history_protected_draft = original.id;
        try history.compact(&store, true);
        try std.testing.expectEqual(@as(usize, 1), store.state.operations.len);
        try std.testing.expectEqualStrings("operation-1", store.state.operations[0].id);
        try std.testing.expectEqualStrings("applied", (try store.findOperation(a, "operation-0")).?.outcome);
        store.close();
        store = try fixture.open(a);
        try std.testing.expectError(error.ArchivedDraftReadOnly, store.putDraft(changed, original.id));
        store.close();
        store = try fixture.open(a);
        const clone = try store.putDraft(try store.draft(original.id), null);
        try std.testing.expect(!std.mem.eql(u8, original.id, clone.id));
        try history.compact(&store, true);
        try std.testing.expectEqualStrings("Exact accepted source", (try store.draft(original.id)).bodyText);
        try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
        _ = try history.deleteSource(&store, original.id);
        try std.testing.expectEqualStrings("applied", (try store.findOperation(a, "operation-1")).?.outcome);
    }
}

test "retained history: cleanup checkpoint failure cannot roll back a committed root and uncertain publication fences writes" {
    for ([_]bool{ false, true }) |encrypted| for ([_]bool{ false, true }) |uncertain| {
        var fixture: PinFixture = undefined;
        try fixture.init(encrypted);
        defer fixture.close();
        const a = fixture.arena.allocator();
        var store = try fixture.open(a);
        defer store.close();
        const original = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Retained despite cleanup checkpoint failure" }, null);
        try markApplied(&store, original, 0);
        const owned = try store.activeDraftOwnedRecords(a, original.id);
        const queued = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Outer queued continuation" }, null);
        const queue_digest = try @import("terminal/send_outcome.zig").digest(a, queued, store.state.account, null);
        const entry = try @import("terminal/send_queue.zig").stage(&store, queued.id, "outer-queue", &queue_digest, 0, 0);
        const queue_id = entry.queueId;
        entry.state = .submitting;
        try store.save();
        store.history_fault = if (uncertain) .uncertain_publication else .after_cleanup;
        try std.testing.expectError(error.InjectedHistoryPublication, history.compact(&store, true));
        try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
        try std.testing.expectEqualStrings(queued.id, store.state.drafts[0].id);
        try std.testing.expectEqual(@as(u64, 1), store.state.history.operations);
        (try @import("terminal/send_queue.zig").find(&store, queue_id)).state = .applied;
        if (uncertain) {
            try std.testing.expectError(error.HistoryTransactionUncertain, store.save());
            try std.testing.expectError(error.HistoryTransactionUncertain, store.finishHistoryCleanup());
            // Both copies remain; a fresh read chooses the durable root.
            for (owned) |name| _ = try store.readHistory(a, name, storage.mail_record_bytes);
        } else {
            for (owned) |name| try std.testing.expectError(error.HistoryRecordMissing, store.readHistory(a, name, storage.mail_record_bytes));
            // A nested continuation may save only the new root, never the
            // previous root whose owned source and pin were already deleted.
            try store.save();
        }
        store.close();
        store = try fixture.open(a);
        try std.testing.expectEqualStrings(original.bodyText, (try store.draft(original.id)).bodyText);
        try std.testing.expectEqualStrings("applied", (try store.findOperation(a, "operation-0")).?.outcome);
        try std.testing.expectEqual(if (uncertain) storage.SendState.submitting else storage.SendState.applied, (try @import("terminal/send_queue.zig").find(&store, queue_id)).state);
        try std.testing.expectEqual(@as(usize, 0), store.state.history.cleanup.len);
    };
}

test "retained recovery: warning links and source pins publish atomically across vault restart" {
    const Fault = enum { before, uncertain, after };
    for ([_]bool{ false, true }) |encrypted| for ([_]Fault{ .before, .uncertain, .after }) |fault| {
        const fixture = try std.testing.allocator.create(PinFixture);
        defer std.testing.allocator.destroy(fixture);
        try fixture.init(encrypted);
        defer fixture.close();
        const a = fixture.arena.allocator();
        var store = try fixture.open(a);
        defer store.close();
        const blob = try tinyFile(&store, "Recovery keeps every original byte");
        const source = try store.putDraft(.{ .bodyText = "Remote source", .attachments = &.{blob}, .includeOriginal = false, .original = .{ .bodyText = "Protected original", .resources = &.{blob} } }, null);
        const Link = @import("terminal/draft_link.zig").Link;
        const old: Link = .{ .draftId = source.id, .phase = .linked, .paused = false, .remoteDraftId = "remote-copy", .remoteMessageId = "remote-version", .attemptMessageId = "<source-upload@example.test>", .uploadedDigest = try a.dupe(u8, &storage.Store.hash("actual uploaded content")), .sendAcknowledgedDigest = try a.dupe(u8, &storage.Store.hash("old acknowledgement")), .version = 7, .lastImportedMessageId = "prior-import-version", .lastImportedDraftId = "prior-import-copy" };
        store.state.draftLinks = try a.dupe(Link, &.{old});
        try store.save();
        var local = source;
        local.bodyText = "Exact new unsaved local note";
        store.history_fault = switch (fault) {
            .before => .before_publication,
            .uncertain => .uncertain_publication,
            .after => .after_publication,
        };
        try std.testing.expectError(error.InjectedHistoryPublication, store.putRecoveryCopy(local, source.id));
        store.close();
        store = try fixture.open(a);
        try std.testing.expectEqual(@as(usize, if (fault == .before) 1 else 2), store.state.drafts.len);
        try std.testing.expectEqual(@as(usize, if (fault == .before) 1 else 2), store.state.draftLinks.len);
        try std.testing.expectEqualDeep(source, try store.draft(source.id));
        try std.testing.expectEqualDeep(old, (try history.gmailLink(&store, a, source.id)).?);
        for (store.state.drafts) |summary| if (!std.mem.eql(u8, summary.id, source.id)) {
            const copy = try store.draft(summary.id);
            local.id = copy.id;
            try std.testing.expectEqualDeep(local, copy);
            const kept = (try history.gmailLink(&store, a, copy.id)).?;
            var expected = old;
            expected.draftId = copy.id;
            expected.version = 1;
            expected.sendAcknowledgedDigest = "";
            expected.lastImportedMessageId = "";
            expected.lastImportedDraftId = "";
            try std.testing.expectEqualDeep(expected, kept);
            try std.testing.expectError(error.GmailCopyUnchecked, kept.permitSend(&storage.Store.hash("new content")));
        };
        try @import("terminal/attachment_blob.zig").verify(&store, blob);
        try std.testing.expectError(error.AttachmentInUse, @import("terminal/attachment_blob.zig").discard(&store, blob.blobId.?));
        try std.testing.expectEqual(@as(u64, 0), store.state.fixtureCalls);
        try std.testing.expectEqual(@as(u64, 0), store.state.fixtureSends);
    };
}
