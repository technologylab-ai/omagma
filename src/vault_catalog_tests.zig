//! Only synthetic accounts and private temporary ciphertext directories.
const std = @import("std");
const crypto = @import("terminal/vault_crypto.zig");
const storage = @import("terminal/vault_storage.zig");
const catalog = @import("terminal/vault_catalog.zig");
const header = @import("terminal/vault_header.zig");
const t = @import("terminal/vault_types.zig");
const io = std.testing.io;
const a = std.testing.allocator;
fn descriptor(key: *const t.DataKey) !header.Header {
    // This catalog fixture does not exercise header persistence or unwrap.
    return .{ .vault_id = key.vault_id, .key_id = key.key_id, .root_record = try storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
}
test "vault catalog: reopened accounts have opaque paths and serialize one borrowed workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const path = try std.fmt.allocPrint(a, "{s}/durable-records", .{base});
    defer a.free(path);
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const saved_header = try descriptor(&key);
    var workspace: t.StreamWorkspace = undefined;
    var owner = try catalog.Owner.create(io, path, saved_header, &key, &workspace);
    defer owner.close();
    const one = "{\"schema\":1,\"state\":{\"account\":\"one@example.test\"}}";
    const two = "{\"schema\":1,\"state\":{\"account\":\"two@example.test\"}}";
    try std.testing.expectError(error.DiskQuotaExceeded, owner.addAccount("one@example.test", one, one.len));
    try owner.addAccount("one@example.test", one, 64 * 1024);
    try owner.addAccount("two@example.test", two, 64 * 1024);
    try std.testing.expectError(error.VaultAccountExists, owner.addAccount("ONE@example.test", one, 64 * 1024));
    owner.close();
    owner = try catalog.Owner.open(io, path, saved_header, &key, &workspace);
    var first = try owner.openAccount("one@example.test");
    defer first.close();
    var second = try owner.openAccount("two@example.test");
    defer second.close();
    try first.claim();
    try std.testing.expectError(error.VaultBusy, second.claim());
    const index = try first.read(a, .cache_index, first.entry.index, 4096);
    defer a.free(index);
    try std.testing.expectEqualStrings(one, index);
    const object = try storage.Handle.create(io);
    try first.write(.operation_ledger, object, "synthetic unknown receipt and exact calendar request", false);
    try std.testing.expectError(error.CacheLimitExceeded, first.read(a, .operation_ledger, object, 4));
    const record = try first.read(a, .operation_ledger, object, 4096);
    defer a.free(record);
    try std.testing.expectEqualStrings("synthetic unknown receipt and exact calendar request", record);
    try std.testing.expectError(error.VaultAuthenticationFailed, first.read(a, .cache_index, object, 4096));
    // Copy valid ciphertext to the other account under the same random handle.
    // Even a correct data key cannot turn it into an account-two record.
    const name = object.filename();
    const input = try storage.openPrivate(io, first.directory.dir, &name);
    defer input.close(io);
    const ciphertext = try a.alloc(u8, @intCast((try input.stat(io)).size));
    defer a.free(ciphertext);
    try std.testing.expectEqual(ciphertext.len, try input.readPositionalAll(io, ciphertext, 0));
    const output = try second.directory.dir.createFile(io, &name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    try output.writeStreamingAll(io, ciphertext);
    output.close(io);
    first.release();
    try second.claim();
    defer second.release();
    try std.testing.expectError(error.VaultAuthenticationFailed, second.read(a, .operation_ledger, object, 4096));
    var iterator = owner.directory.dir.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, "example") == null);
        if (entry.kind == .directory) _ = try storage.Handle.parse(entry.name);
    }
}
test "vault catalog: wrong key and corrupt catalog fail before any account is discovered" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const path = try std.fmt.allocPrint(a, "{s}/records", .{base});
    defer a.free(path);
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const saved_header = try descriptor(&key);
    var workspace: t.StreamWorkspace = undefined;
    var owner = try catalog.Owner.create(io, path, saved_header, &key, &workspace);
    const name = saved_header.root_record.filename();
    owner.close();
    var wrong = key;
    defer wrong.wipe();
    wrong.bytes[0] ^= 1;
    try std.testing.expectError(error.VaultAuthenticationFailed, catalog.Owner.open(io, path, saved_header, &wrong, &workspace));
    owner = try catalog.Owner.open(io, path, saved_header, &key, &workspace);
    const file = try owner.directory.dir.openFile(io, &name, .{ .mode = .read_write });
    var last: [1]u8 = undefined;
    const position = (try file.stat(io)).size - 1;
    _ = try file.readPositionalAll(io, &last, position);
    last[0] ^= 1;
    try file.writePositionalAll(io, &last, position);
    file.close(io);
    owner.close();
    if (catalog.Owner.open(io, path, saved_header, &key, &workspace)) |unexpected| {
        var opened = unexpected;
        opened.close();
        return error.AcceptedTamperedCatalog;
    } else |_| {}
}

test "vault catalog: failed publication cleans owned records and unknown directories still require recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const path = try std.fmt.allocPrint(a, "{s}/records", .{base});
    defer a.free(path);
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    const saved_header = try descriptor(&key);
    var workspace: t.StreamWorkspace = undefined;
    var owner = try catalog.Owner.create(io, path, saved_header, &key, &workspace);
    defer owner.close();
    try owner.addAccount("known@example.test", "known index", 65536);
    // The account ciphertext is complete when publication of the root fails.
    // This is also the restart state of a crash between those durable writes.
    var pinned = try owner.directory.reader(saved_header.root_record);
    try std.testing.expectError(error.VaultBusy, owner.addAccount("stranded@example.test", "stranded index", 65536));
    pinned.close();
    // The failed attempt's own index/directory were removed. A separate
    // unknown directory is never inferred safe from its opaque name.
    var before = owner.directory.dir.iterate();
    var known_directories: usize = 0;
    while (try before.next(io)) |entry| if (entry.kind == .directory) {
        known_directories += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), known_directories);
    const unknown = try storage.Handle.create(io);
    try owner.directory.dir.createDir(io, &unknown.text(), .fromMode(0o700));
    owner.close();
    try std.testing.expectError(error.VaultRecoveryRequired, catalog.Owner.create(io, path, saved_header, &key, &workspace));
    owner = try catalog.Owner.open(io, path, saved_header, &key, &workspace);
    try std.testing.expectEqual(@as(usize, 1), owner.count);
    try std.testing.expectError(error.VaultRecoveryRequired, owner.addAccount("third@example.test", "more allocation", 65536));
    var account = try owner.openAccount("known@example.test");
    defer account.close();
    try account.claim();
    defer account.release();
    const index = try account.read(a, .cache_index, account.entry.index, 4096);
    defer a.free(index);
    try std.testing.expectEqualStrings("known index", index);
    const document = try storage.Handle.create(io);
    try account.write(.operation_ledger, document, "known account still works", false);
    var directories: usize = 0;
    var entries = owner.directory.dir.iterate();
    while (try entries.next(io)) |entry| if (entry.kind == .directory) {
        directories += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), directories);
}
