//! Realistic synthetic encrypted mail streaming; no live accounts or network.
const std = @import("std");
const Store = @import("terminal/store.zig").Store;
const blob = @import("terminal/attachment_blob.zig");
const spool = @import("terminal/send_spool.zig");
const catalog = @import("terminal/vault_catalog.zig");
const storage = @import("terminal/vault_storage.zig");
const crypto = @import("terminal/vault_crypto.zig");
const header = @import("terminal/vault_header.zig");
const vault = @import("terminal/vault_types.zig");
const t = @import("terminal/types.zig");
const mime = @import("terminal/mime.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const options: t.Options = .{ .fixtures = true };
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    key: vault.DataKey,
    workspace: vault.StreamWorkspace,
    owner: catalog.Owner,
    first: catalog.Account,
    second: catalog.Account,
    fn init(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.arena = .init(a);
        const allocator = self.arena.allocator();
        self.base = try self.tmp.dir.realPathFileAlloc(io, ".", allocator);
        self.key = try crypto.createDataKey(io);
        const descriptor: header.Header = .{ .vault_id = self.key.vault_id, .key_id = self.key.key_id, .root_record = try storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
        self.owner = try catalog.Owner.create(io, try std.fmt.allocPrint(allocator, "{s}/sealed", .{self.base}), descriptor, &self.key, &self.workspace);
        try Store.createVaultAccount(&self.owner, allocator, "synthetic@example.test", options);
        try Store.createVaultAccount(&self.owner, allocator, "neighbor@example.test", options);
        self.first = try self.owner.openAccount("synthetic@example.test");
        self.second = try self.owner.openAccount("neighbor@example.test");
    }
    fn close(self: *Fixture) void {
        self.second.close();
        self.first.close();
        self.owner.close();
        self.key.wipe();
        self.arena.deinit();
        self.tmp.cleanup();
    }
    fn input(self: *Fixture, name: []const u8, size: usize, marker: []const u8) ![]const u8 {
        const file = try self.tmp.dir.createFile(io, name, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        var block: [64 * 1024]u8 = undefined;
        for (&block, 0..) |*byte, index| byte.* = @intCast(index % 251);
        @memcpy(block[0..marker.len], marker);
        var written: usize = 0;
        while (written < size) {
            const count = @min(block.len, size - written);
            try file.writeStreamingAll(io, block[0..count]);
            written += count;
        }
        return self.tmp.dir.realPathFileAlloc(io, name, self.arena.allocator());
    }
    fn assertCiphertext(self: *Fixture) !void {
        var iterator = self.first.directory.dir.iterate();
        while (try iterator.next(io)) |entry| {
            try std.testing.expect(std.mem.eql(u8, entry.name, ".vault-lock") or (std.mem.startsWith(u8, entry.name, "vrec-") and std.mem.endsWith(u8, entry.name, ".bin")));
            const file = try storage.openPrivate(io, self.first.directory.dir, try self.arena.allocator().dupeSentinel(u8, entry.name, 0));
            defer file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (true) {
                const count = try file.readPositional(io, &.{&buffer}, offset);
                if (count == 0) break;
                try std.testing.expect(std.mem.indexOf(u8, buffer[0..count], "SYNTHETIC PRIVATE") == null);
                try std.testing.expect(std.mem.indexOf(u8, buffer[0..count], "synthetic@example.test") == null);
                offset += count;
            }
        }
    }
};

test "vault mail: 25 MiB attachment and related image produce exact private MIME within bounded heap" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.close();
    const path = try fixture.input("large.pdf", 25 * 1024 * 1024, "SYNTHETIC PRIVATE PDF");
    const picture = try fixture.input("related.png", 64 * 1024 + 17, "SYNTHETIC PRIVATE IMAGE");
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = a, .limit = 4 * 1024 * 1024 };
    var arena: std.heap.ArenaAllocator = .init(cap.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer store.close();
    const attachment = try blob.importFile(&store, path, "application/pdf");
    var related = try blob.importFile(&store, picture, "image/png");
    related.contentId = "<synthetic-image@example.test>";
    related.disposition = "inline";
    const draft = try store.putDraft(.{ .subject = "SYNTHETIC PRIVATE draft", .bodyText = "A bounded streamed message", .attachments = &.{attachment}, .original = .{ .bodyHtml = "<img src=\"cid:synthetic-image@example.test\">", .resources = &.{related} } }, null);
    try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, related.blobId.?));
    const recipients = @import("terminal/recipients.zig");
    var envelope: recipients.Envelope = .{};
    try recipients.parse("recipient@example.test", &envelope.to);
    var sender: recipients.Mailbox = .{};
    try sender.address.set("synthetic@example.test");
    const compose: mime.Compose = .{ .from = sender, .envelope = &envelope, .subject = draft.subject, .body = draft.bodyText, .html = draft.original.?.bodyHtml, .message_id = "<synthetic-vault@example.test>", .date = "Tue, 13 Oct 2026 12:00:00 +0000" };
    try std.testing.expectError(error.AttachmentsTooLarge, spool.create(&store, compose, &.{attachment}, &.{related}));
    var boundary_compose = compose;
    boundary_compose.html = null;
    var encrypted = try spool.create(&store, boundary_compose, &.{attachment}, &.{});
    defer encrypted.close();
    try std.testing.expect(encrypted.file == null);
    // Independent existing plaintext adapter is the byte-for-byte oracle, in
    // this synthetic fixture's separate directory outside the vault.
    var plain = try Store.open(io, allocator, try std.fmt.allocPrint(allocator, "{s}/reference", .{fixture.base}), "reference@example.test", options);
    defer plain.close();
    const plain_attachment = try blob.importFile(&plain, path, "application/pdf");
    var plain_related = try blob.importFile(&plain, picture, "image/png");
    plain_related.contentId = related.contentId;
    plain_related.disposition = related.disposition;
    var reference = try spool.create(&plain, boundary_compose, &.{plain_attachment}, &.{});
    defer reference.close();
    try std.testing.expectEqual(reference.size, encrypted.size);
    try std.testing.expectEqualSlices(u8, &reference.hash, &encrypted.hash);
    {
        var left = try encrypted.reader();
        defer left.close();
        var right = try reference.reader();
        defer right.close();
        var first: [64 * 1024]u8 = undefined;
        var second: [64 * 1024]u8 = undefined;
        while (true) {
            const count = try spool.Spool.Reader.read(&left, &first);
            var received: usize = 0;
            while (received < count) {
                const n = try spool.Spool.Reader.read(&right, second[received..count]);
                try std.testing.expect(n != 0);
                received += n;
            }
            try std.testing.expectEqualSlices(u8, first[0..count], second[0..count]);
            if (count == 0) break;
        }
        try std.testing.expectEqual(@as(usize, 0), try spool.Spool.Reader.read(&right, &second));
        try left.reset();
        try std.testing.expect(try spool.Spool.Reader.read(&left, &first) != 0);
    }
    {
        const note: t.Attachment = .{ .id = "small-inline", .filename = "note.bin", .mimeType = "application/octet-stream", .size = 3, .data = "AAAA" };
        var with_image = try spool.create(&store, compose, &.{note}, &.{related});
        defer with_image.close();
        var image_reference = try spool.create(&plain, compose, &.{note}, &.{plain_related});
        defer image_reference.close();
        try std.testing.expectEqual(image_reference.size, with_image.size);
        try std.testing.expectEqualSlices(u8, &image_reference.hash, &with_image.hash);
    }
    try fixture.assertCiphertext();
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
    try std.testing.expect(cap.snapshot().allocatorPeakBytes < 4 * 1024 * 1024);
    store.release();
    var neighbor = try Store.openVault(io, allocator, &fixture.second, options, false);
    defer neighbor.close();
    try std.testing.expectError(error.AttachmentHandleNotFound, blob.Stream.init(&neighbor, attachment));
}

test "vault mail: raw upper bound download releases transaction preserves exact bytes and cleans interruptions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.close();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer store.close();
    const raw = "Subject: SYNTHETIC PRIVATE original\r\nFrom: sender@example.test\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nExactly retained raw bytes.\r\n";
    var incoming = try blob.Incoming.create(&store, 25 * 1024 * 1024);
    defer incoming.close();
    try std.testing.expect(incoming.file == null);
    store.release();
    try std.testing.expectError(error.VaultBusy, Store.openVault(io, allocator, &fixture.first, options, false));
    var chunk: [13]u8 = undefined;
    var writer = incoming.writer(&chunk);
    var expected_hash = std.crypto.hash.sha2.Sha256.init(.{});
    expected_hash.update(raw);
    try writer.interface.writeAll(raw);
    var raw_block: [64 * 1024]u8 = @splat('x');
    for (0..raw_block.len / 128) |line| {
        raw_block[line * 128 + 126] = '\r';
        raw_block[line * 128 + 127] = '\n';
    }
    for (0..48) |_| {
        try writer.interface.writeAll(&raw_block);
        expected_hash.update(&raw_block);
    }
    const exact_size = raw.len + 48 * raw_block.len;
    try writer.flush();
    try incoming.finish(exact_size);
    var latest = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer latest.close();
    const classified = blk: {
        var reader = try incoming.reader();
        defer reader.close();
        break :blk try mime.originalSourceStream(allocator, .{ .ctx = &reader, .readFn = blob.Incoming.Reader.read }, exact_size);
    };
    try std.testing.expectEqualStrings("SYNTHETIC PRIVATE original", classified.subject);
    const attachment = try incoming.commit(&latest, classified.attachment);
    incoming.close();
    {
        var stream = try blob.Stream.init(&latest, attachment);
        defer stream.close();
        var actual_hash = std.crypto.hash.sha2.Sha256.init(.{});
        var total: usize = 0;
        while (true) {
            const count = try blob.Stream.read(&stream, &raw_block);
            if (count == 0) break;
            actual_hash.update(raw_block[0..count]);
            total += count;
        }
        var actual_digest: [32]u8 = undefined;
        var expected_digest: [32]u8 = undefined;
        actual_hash.final(&actual_digest);
        expected_hash.final(&expected_digest);
        try std.testing.expectEqual(exact_size, total);
        try std.testing.expectEqualSlices(u8, &expected_digest, &actual_digest);
    }
    const before = try latest.diskBytes();
    {
        var interrupted = try blob.Incoming.create(&latest, 3 * 1024 * 1024);
        try interrupted.write(raw);
        latest.release();
        interrupted.close();
    }
    var reopened = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer reopened.close();
    try std.testing.expectEqual(before, try reopened.diskBytes());
    try fixture.assertCiphertext();
}

test "vault mail: tampered final ciphertext refuses stream before returning plaintext" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.close();
    const path = try fixture.input("tamper.bin", 128 * 1024 + 3, "SYNTHETIC PRIVATE tamper");
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var store = try Store.openVault(io, arena.allocator(), &fixture.first, options, false);
    defer store.close();
    const attachment = try blob.importFile(&store, path, "application/octet-stream");
    var record = try store.openVaultStream(try blob.filename(arena.allocator(), attachment.blobId.?));
    const target = record.record.handle.filename();
    record.close();
    const corrupt = try fixture.first.directory.dir.openFile(io, &target, .{ .mode = .read_write });
    defer corrupt.close(io);
    const offset = (try corrupt.stat(io)).size - 1;
    var last: [1]u8 = undefined;
    _ = try corrupt.readPositionalAll(io, &last, offset);
    last[0] ^= 0x80;
    try corrupt.writePositionalAll(io, &last, offset);
    try std.testing.expectError(error.VaultAuthenticationFailed, blob.Stream.init(&store, attachment));
    for (fixture.workspace.ciphertext) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectError(error.VaultAuthenticationFailed, blob.verify(&store, attachment));
}

test "vault mail: blob cap permits deduped downloads and small raw inspection but refuses new blobs" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.close();
    for ([_]bool{ false, true }) |sealed| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        var store = if (sealed) try Store.openVault(io, allocator, &fixture.first, options, false) else try Store.open(io, allocator, try std.fmt.allocPrint(allocator, "{s}/cap-reference", .{fixture.base}), "reference@example.test", options);
        defer store.close();
        var first: t.Attachment = undefined;
        for (0..128) |index| {
            const value: [1]u8 = .{@intCast(index)};
            const input = try fixture.input("one-byte.bin", 1, &value);
            const imported = try blob.importFile(&store, input, "application/octet-stream");
            if (index == 0) first = imported;
        }
        try std.testing.expectEqual(@as(usize, 128), (try store.blobStats()).count);
        {
            var duplicate = try blob.Incoming.create(&store, 1);
            defer duplicate.close();
            try duplicate.write("\x00");
            try duplicate.finish(1);
            const reused = try duplicate.commit(&store, first);
            try std.testing.expectEqualStrings(first.blobId.?, reused.blobId.?);
        }
        const raw = "Subject: Small raw at blob cap\r\nFrom: synthetic@example.test\r\n\r\nSmall body\r\n";
        {
            var small = try blob.Incoming.create(&store, 25 * 1024 * 1024);
            defer small.close();
            try small.write(raw);
            try small.finish(raw.len);
            var reader = try small.reader();
            defer reader.close();
            const inspected = try mime.originalSourceStream(allocator, .{ .ctx = &reader, .readFn = blob.Incoming.Reader.read }, raw.len);
            try std.testing.expectEqualStrings("Small raw at blob cap", inspected.subject);
        }
        {
            var fresh = try blob.Incoming.create(&store, 1);
            defer fresh.close();
            try fresh.write("\x80");
            try fresh.finish(1);
            try std.testing.expectError(error.AttachmentLimitExceeded, fresh.commit(&store, .{ .id = "new", .filename = "new.bin", .size = 1 }));
        }
        const stats = try store.blobStats();
        try std.testing.expectEqual(@as(usize, 128), stats.count);
        try std.testing.expectEqual(if (sealed) 128 * try vault.sealedSize(1) else @as(usize, 128), stats.bytes);
    }
}
