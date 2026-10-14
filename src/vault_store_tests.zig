//! Synthetic Store bridge acceptance; no live data or production migration.
const std = @import("std");
const Store = @import("terminal/store.zig").Store;
const catalog = @import("terminal/vault_catalog.zig");
const crypto = @import("terminal/vault_crypto.zig");
const storage = @import("terminal/vault_storage.zig");
const header = @import("terminal/vault_header.zig");
const vault = @import("terminal/vault_types.zig");
const t = @import("terminal/types.zig");
const io = std.testing.io;
const a = std.testing.allocator;

test "vault Store: body draft and exact calendar documents reopen with no plaintext paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const path = try std.fmt.allocPrint(a, "{s}/sealed", .{base});
    defer a.free(path);
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const descriptor: header.Header = .{ .vault_id = key.vault_id, .key_id = key.key_id, .root_record = try storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
    var workspace: vault.StreamWorkspace = undefined;
    var owner = try catalog.Owner.create(io, path, descriptor, &key, &workspace);
    defer owner.close();
    const options: t.Options = .{ .fixtures = true, .disk_limit = 8 * 1024 * 1024 };
    try Store.createVaultAccount(&owner, a, "synthetic@example.test", options);
    var account = try owner.openAccount("synthetic@example.test");
    defer account.close();
    var draft_id: [128]u8 = undefined;
    var draft_id_len: usize = 0;
    const calendar = "{\"receipt\":\"unknown\",\"exactRequest\":\"synthetic\\r\\nICS\"}";
    const follow_up = "{\"schema\":1,\"account\":\"synthetic@example.test\",\"revision\":1,\"entries\":[{\"messageId\":\"synthetic-mail-id\",\"threadId\":\"thread\",\"dueDate\":\"2026-10-14\",\"subject\":\"Synthetic secret follow-up\",\"version\":1}]}";
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        var store = try Store.openVault(io, arena.allocator(), &account, options, false);
        defer store.close();
        try std.testing.expectError(error.VaultBusy, Store.openVault(io, arena.allocator(), &account, options, true));
        try store.put(.{ .id = "synthetic-mail-id", .threadId = "thread", .subject = "Synthetic secret subject", .bodyText = "Synthetic secret body" }, true);
        try store.save();
        const draft = try store.putDraft(.{ .subject = "Synthetic draft", .bodyText = "Synthetic draft body" }, null);
        draft_id_len = draft.id.len;
        @memcpy(draft_id[0..draft_id_len], draft.id);
        try store.writeDocument("calendar-state.json", calendar);
        try store.writeDocument("calendar-agenda.json", "{\"snapshots\":[]}");
        try store.writeDocument("follow-ups.json", follow_up);
        try std.testing.expectError(error.InvalidStoreDocument, store.writeDocument("../escape", "bad"));
        try std.testing.expectError(error.VaultOperationUnsupported, store.write("preview.html", "plaintext forbidden"));
        try std.testing.expectError(error.VaultOperationUnsupported, store.reserveBytes(10));
        var entries = account.directory.dir.iterate();
        while (try entries.next(io)) |entry| {
            try std.testing.expect(std.mem.eql(u8, entry.name, ".vault-lock") or (std.mem.startsWith(u8, entry.name, "vrec-") and std.mem.endsWith(u8, entry.name, ".bin")));
            const file = try storage.openPrivate(io, account.directory.dir, try arena.allocator().dupeSentinel(u8, entry.name, 0));
            defer file.close(io);
            const bytes = try arena.allocator().alloc(u8, @intCast((try file.stat(io)).size));
            _ = try file.readPositionalAll(io, bytes, 0);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "Synthetic secret") == null);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "synthetic@example.test") == null);
        }
    }
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        var store = try Store.openVault(io, arena.allocator(), &account, options, true);
        defer store.close();
        try std.testing.expect(try store.bodyAvailable("synthetic-mail-id"));
        try std.testing.expectEqualStrings("Synthetic secret body", (try store.read("synthetic-mail-id")).?.bodyText);
        try std.testing.expectEqualStrings("Synthetic draft body", (try store.draft(draft_id[0..draft_id_len])).bodyText);
        try std.testing.expectEqualStrings(calendar, (try store.readDocument(arena.allocator(), "calendar-state.json", 4096)).?);
        try std.testing.expectEqualStrings(follow_up, (try store.readDocument(arena.allocator(), "follow-ups.json", 4096)).?);
        // A complete orphan from an interrupted write is charged, and failed
        // replacement admission preserves the previous calendar claim on disk.
        const orphan = try storage.Handle.create(io);
        try account.write(.mail_body, orphan, "charged orphan ciphertext", false);
        const used = try store.diskBytes();
        store.options.disk_limit = used + (try vault.sealedSize(100)) - 1;
        const too_large: [100]u8 = @splat('x');
        try std.testing.expectError(error.DiskQuotaExceeded, store.writeDocument("calendar-state.json", &too_large));
    }
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        var store = try Store.openVault(io, arena.allocator(), &account, options, true);
        defer store.close();
        try std.testing.expectEqualStrings(calendar, (try store.readDocument(arena.allocator(), "calendar-state.json", 4096)).?);
        try store.discardDraft(draft_id[0..draft_id_len]);
        try store.clearMail();
    }
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        var store = try Store.openVault(io, arena.allocator(), &account, options, true);
        defer store.close();
        try std.testing.expectError(error.DraftNotFound, store.draft(draft_id[0..draft_id_len]));
        try std.testing.expectEqualStrings(calendar, (try store.readDocument(arena.allocator(), "calendar-state.json", 4096)).?);
        try std.testing.expectEqualStrings(follow_up, (try store.readDocument(arena.allocator(), "follow-ups.json", 4096)).?);
        try std.testing.expect(!(try store.bodyAvailable("synthetic-mail-id")));
    }
}

test "vault Store: corrupt encrypted index never falls through to a valid plaintext index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const path = try std.fmt.allocPrint(a, "{s}/sealed", .{base});
    defer a.free(path);
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const descriptor: header.Header = .{ .vault_id = key.vault_id, .key_id = key.key_id, .root_record = try storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
    var workspace: vault.StreamWorkspace = undefined;
    var owner = try catalog.Owner.create(io, path, descriptor, &key, &workspace);
    defer owner.close();
    const options: t.Options = .{ .fixtures = true };
    try Store.createVaultAccount(&owner, a, "synthetic@example.test", options);
    var account = try owner.openAccount("synthetic@example.test");
    defer account.close();
    const name = account.entry.index.filename();
    const corrupted = try account.directory.dir.openFile(io, &name, .{ .mode = .read_write });
    var last: [1]u8 = undefined;
    const offset = (try corrupted.stat(io)).size - 1;
    _ = try corrupted.readPositionalAll(io, &last, offset);
    last[0] ^= 1;
    try corrupted.writePositionalAll(io, &last, offset);
    corrupted.close(io);
    // Deliberately planted legacy fixture: never a bridge output or staging.
    const fallback = try account.directory.dir.createFile(io, "index.json", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    try fallback.writeStreamingAll(io, "{\"schema\":1,\"account\":\"synthetic@example.test\"}");
    fallback.close(io);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try std.testing.expectError(error.VaultAuthenticationFailed, Store.openVault(io, arena.allocator(), &account, options, true));
    try std.testing.expect(!account.active);
    for (workspace.plaintext) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
