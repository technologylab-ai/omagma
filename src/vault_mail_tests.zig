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

test "vault mail: rich Gmail import retains related resources and rolls back newly published encrypted blobs" {
    if (!@import("terminal/send_memory.zig").native) return error.SkipZigTest;
    const j = @import("terminal/json.zig");
    const links = @import("terminal/draft_link.zig");
    const importer = @import("terminal/draft_gmail_import.zig");
    const Session = struct {
        account: *catalog.Account,
        options: t.Options = .{ .fixtures = true },
        pub fn openStore(self: *@This(), allocator: std.mem.Allocator, account: []const u8, readonly: bool) !Store {
            if (!std.mem.eql(u8, account, self.account.entry.address())) return error.VaultIdentityMismatch;
            return Store.openVault(io, allocator, self.account, self.options, readonly);
        }
    };
    const account = "synthetic@example.test";
    const png = @import("terminal/markdown_logo.zig").png;
    const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    for ([_]bool{ false, true }) |race| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.close();
        const allocator = fixture.arena.allocator();
        var session: Session = .{ .account = &fixture.first };
        if (race) session.options.fixture_scenario = "gmail-draft-import-race";
        var seed = try session.openStore(allocator, account, false);
        defer seed.close();
        const source = try seed.putDraft(.{ .subject = "SYNTHETIC PRIVATE local", .bodyText = "SYNTHETIC PRIVATE local source retained" }, null);
        const digest = try links.contentDigest(allocator, source, account);
        const link: links.Link = .{ .draftId = source.id, .phase = .linked, .remoteDraftId = "remote-draft", .remoteMessageId = "version-1", .attemptMessageId = "<upload@mail.invalid>", .uploadedDigest = &digest };
        seed.state.draftLinks = try allocator.dupe(links.Link, &.{link});
        try seed.save();
        var incoming = try blob.Incoming.create(&seed, png.len);
        try incoming.write(png);
        try incoming.finish(png.len);
        const existing = try incoming.commit(&seed, .{ .id = "existing", .filename = "existing.png", .mimeType = "image/png", .size = png.len });
        incoming.close();
        seed.close();
        const png_data = std.base64.url_safe_no_pad.Encoder.encode(try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(png.len)), png);
        const gif_data = std.base64.url_safe_no_pad.Encoder.encode(try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(gif.len)), gif);
        const files = try allocator.alloc(t.Attachment, 66);
        var html: std.ArrayList(u8) = .empty;
        try html.appendSlice(allocator, "<html><body><p>SYNTHETIC PRIVATE remote original</p>");
        for (files[0..65], 0..) |*file, index| {
            const cid = try std.fmt.allocPrint(allocator, "image-{d}@example.test", .{index});
            file.* = .{ .id = try std.fmt.allocPrint(allocator, "part-{d}", .{index}), .filename = try std.fmt.allocPrint(allocator, "image-{d}.{s}", .{ index, if (index == 0) @as([]const u8, "png") else "gif" }), .mimeType = if (index == 0) "image/png" else "image/gif", .size = if (index == 0) png.len else gif.len, .data = if (index == 0) png_data else gif_data, .contentId = cid, .disposition = "inline" };
            try html.appendSlice(allocator, try std.fmt.allocPrint(allocator, "<img src='cid:{s}'>", .{cid}));
        }
        try html.appendSlice(allocator, "</body></html>");
        files[65] = .{ .id = "ordinary", .filename = "report.pdf", .mimeType = "application/pdf", .size = 3, .data = "UERG", .disposition = "attachment" };
        const headers = try j.value(allocator, .{ .{ .name = "From", .value = account }, .{ .name = "To", .value = "recipient@example.test" }, .{ .name = "Subject", .value = "SYNTHETIC PRIVATE remote" } });
        const loaded: importer.Loaded = .{ .remote = .{ .draftId = "remote-draft", .messageId = "version-2" }, .draft = try importer.fromMessage(allocator, headers, .{ .id = "version-2", .threadId = "remote-thread", .from = .{ .address = account }, .to = &.{.{ .address = "recipient@example.test" }}, .subject = "SYNTHETIC PRIVATE remote", .bodyText = "SYNTHETIC PRIVATE full remote text", .bodyHtml = html.items, .attachments = files }, account) };
        const baseline = @import("terminal/send_memory.zig").snapshot().allocatorUsedBytes;
        const result = @import("terminal/draft_gmail_download.zig").run(&session, allocator, account, try j.value(allocator, .{ .expectedRemoteMessageId = "version-2" }), null, link, loaded, false);
        try std.testing.expectEqual(baseline, @import("terminal/send_memory.zig").snapshot().allocatorUsedBytes);
        try std.testing.expect(!fixture.first.workspace_pinned and fixture.first.reader_owner == null);
        var store = try session.openStore(allocator, account, false);
        defer store.close();
        try std.testing.expectEqualStrings(source.bodyText, (try store.draft(source.id)).bodyText);
        if (race) {
            try std.testing.expectError(error.GmailDraftChanged, result);
            try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
            try std.testing.expectEqual(@as(u64, 1), store.state.draftLinks[0].version);
            try std.testing.expectEqual(@as(usize, 1), (try store.blobStats()).count);
        } else {
            const imported = try result;
            const retained = try store.draft(imported.id);
            try std.testing.expectEqualStrings("", retained.bodyText);
            try std.testing.expectEqualStrings(html.items, retained.original.?.bodyHtml);
            try std.testing.expectEqualStrings("SYNTHETIC PRIVATE full remote text", retained.original.?.bodyText);
            try std.testing.expectEqual(@as(usize, 65), retained.original.?.resources.len);
            try std.testing.expectEqual(@as(usize, 1), retained.attachments.len);
            for (retained.original.?.resources, 0..) |file, index| {
                try std.testing.expectEqualStrings(files[index].contentId.?, file.contentId.?);
                try std.testing.expectEqual(@as(usize, 0), file.data.len);
                try blob.verify(&store, file);
            }
            try std.testing.expectEqual(@as(usize, 2), store.state.draftLinks.len);
            try std.testing.expectError(error.GmailCopyUnchecked, @import("terminal/draft_gmail_commands.zig").permitSend(&store, allocator, .null, retained, &(try links.contentDigest(allocator, retained, account))));
        }
        try blob.verify(&store, existing);
        store.close();
        try fixture.assertCiphertext();
    }
}

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

test "vault mail: history metadata reads preserve buffered encrypted output" {
    const fixture = try a.create(Fixture);
    defer a.destroy(fixture);
    try fixture.init();
    defer fixture.close();
    const allocator = fixture.arena.allocator();
    const path = try fixture.input("tiny.bin", 41, "SYNTHETIC PRIVATE FILE");
    var store = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer store.close();
    const attachment = try blob.importFile(&store, path, "application/octet-stream");
    const raw = "Buffered MIME header\r\n\r\nExact authored note.";
    const handle = block: {
        var writer: @import("terminal/vault_stream.zig").Writer = undefined;
        const handle = try store.beginVaultStream(&writer, .send_spool, raw.len);
        defer writer.deinit();
        try writer.interface.writeAll(raw[0..20]);
        try std.testing.expectError(error.VaultBusy, fixture.first.read(allocator, .cache_index, fixture.first.entry.index, 8 * 1024 * 1024));
        try std.testing.expectError(error.VaultBusy, fixture.first.write(.cache_index, fixture.first.entry.index, "must never publish", true));
        try std.testing.expectError(error.VaultBusy, store.save());
        var overlapping: @import("terminal/vault_stream.zig").Writer = undefined;
        try std.testing.expectError(error.VaultBusy, store.beginVaultStream(&overlapping, .send_spool, 1));
        try std.testing.expect(try @import("terminal/operation_history.zig").findBlob(&store, allocator, attachment.blobId.?) != null);
        try writer.interface.writeAll(raw[20..]);
        try writer.finish();
        try std.testing.expect(fixture.first.writer_owner == null);
        break :block handle;
    };
    var source: spool.Spool = .{ .io = io, .dir = fixture.first.directory.dir, .account = &fixture.first, .handle = handle, .size = raw.len, .hash = Store.hash(raw) };
    defer source.close();
    var reader = try source.reader();
    defer reader.close();
    // Shared scratch remains unavailable while a consumer pins the stream.
    try std.testing.expectError(error.VaultBusy, fixture.first.read(allocator, .send_spool, handle, raw.len));
    try std.testing.expectError(error.VaultBusy, fixture.first.write(.send_spool, handle, raw, true));
    var output: [raw.len]u8 = undefined;
    try std.testing.expectEqual(raw.len, try spool.Spool.Reader.read(&reader, &output));
    try std.testing.expectEqualStrings(raw, &output);
    var end: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try spool.Spool.Reader.read(&reader, &end));
}

test "vault mail: encrypted writer leases release on aborted and failed streams" {
    const fixture = try a.create(Fixture);
    defer a.destroy(fixture);
    try fixture.init();
    defer fixture.close();
    var store = try Store.openVault(io, fixture.arena.allocator(), &fixture.first, options, false);
    defer store.close();
    for ([_]bool{ false, true }) |finish_early| {
        var writer: @import("terminal/vault_stream.zig").Writer = undefined;
        _ = try store.beginVaultStream(&writer, .send_spool, 4);
        try writer.interface.writeAll("abc");
        try std.testing.expect(fixture.first.writer_owner != null);
        if (finish_early) {
            try std.testing.expectError(error.VaultLengthMismatch, writer.finish());
            try std.testing.expect(fixture.first.writer_owner == null);
        }
        writer.deinit();
        try std.testing.expect(fixture.first.writer_owner == null);
        try store.save();
    }
}

test "vault mail: encrypted writer lease blocks other accounts after releasing its Store" {
    const fixture = try a.create(Fixture);
    defer a.destroy(fixture);
    try fixture.init();
    defer fixture.close();
    var store = try Store.openVault(io, fixture.arena.allocator(), &fixture.first, options, false);
    defer store.close();
    var writer: @import("terminal/vault_stream.zig").Writer = undefined;
    const handle = try store.beginVaultStream(&writer, .send_spool, 6);
    defer writer.deinit();
    try writer.interface.writeAll("before");
    store.release();
    try std.testing.expectError(error.VaultBusy, fixture.second.claim());
    try writer.finish();
    try fixture.second.claim();
    fixture.second.release();
    var source: spool.Spool = .{ .io = io, .dir = fixture.first.directory.dir, .account = &fixture.first, .handle = handle, .size = 6, .hash = Store.hash("before") };
    defer source.close();
    var reader = try source.reader();
    defer reader.close();
    var output: [6]u8 = undefined;
    try std.testing.expectEqual(output.len, try spool.Spool.Reader.read(&reader, &output));
    try std.testing.expectEqualStrings("before", &output);
    var end: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try spool.Spool.Reader.read(&reader, &end));
}

test "vault mail: paged blob lookup preserves buffered encrypted MIME across many small files" {
    const fixture = try a.create(Fixture);
    defer a.destroy(fixture);
    try fixture.init();
    defer fixture.close();
    const allocator = fixture.arena.allocator();
    const path = try fixture.input("tiny.bin", 41, "SYNTHETIC PRIVATE FILE");
    var sealed_store = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer sealed_store.close();
    const sealed_file = try blob.importFile(&sealed_store, path, "application/octet-stream");
    try std.testing.expectEqual(@as(usize, 0), sealed_store.vaultBlobCount());
    var plain_store = try Store.open(io, allocator, try std.fmt.allocPrint(allocator, "{s}/reference", .{fixture.base}), "reference@example.test", options);
    defer plain_store.close();
    const plain_file = try blob.importFile(&plain_store, path, "application/octet-stream");
    const sealed_parts = try allocator.alloc(t.Attachment, 256);
    const plain_parts = try allocator.alloc(t.Attachment, sealed_parts.len);
    for (sealed_parts, plain_parts, 0..) |*sealed, *plain, index| {
        sealed.* = sealed_file;
        plain.* = plain_file;
        const name = try std.fmt.allocPrint(allocator, "file-{d}.bin", .{index});
        sealed.filename = name;
        plain.filename = name;
    }
    var sender: @import("terminal/recipients.zig").Mailbox = .{};
    try sender.address.set("synthetic@example.test");
    const compose: mime.Compose = .{ .from = sender, .destinations = .{ .to = &.{.{ .address = "recipient@example.test" }} }, .subject = "SYNTHETIC PRIVATE files", .body = "Exact authored note before every file.", .message_id = "<buffered-vault@example.test>", .date = "Thu, 08 Oct 2026 12:00:00 +0000" };
    var encrypted = try spool.create(&sealed_store, compose, sealed_parts, &.{});
    defer encrypted.close();
    // More than one Sink flush, with history reads between writes to the
    // partially buffered encryption chunk. The independent plain adapter is
    // the exact wire oracle; comparing the pre-encryption hashes alone is not.
    try std.testing.expect(encrypted.size > vault.chunk_bytes);
    var reference = try spool.create(&plain_store, compose, plain_parts, &.{});
    defer reference.close();
    try std.testing.expectEqual(reference.size, encrypted.size);
    const actual = try allocator.alloc(u8, encrypted.size);
    const expected = try allocator.alloc(u8, reference.size);
    for ([_]*spool.Spool{ &encrypted, &reference }, [_][]u8{ actual, expected }) |source, output| {
        var reader = try source.reader();
        defer reader.close();
        var offset: usize = 0;
        while (offset < output.len) {
            const count = try spool.Spool.Reader.read(&reader, output[offset..]);
            try std.testing.expect(count != 0);
            offset += count;
        }
        var end: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try spool.Spool.Reader.read(&reader, &end));
        try std.testing.expect(reader.verified);
    }
    try std.testing.expectEqualSlices(u8, expected, actual);
    const parsed = try mime.parse(actual, allocator);
    try std.testing.expectEqualStrings(compose.message_id, parsed.message_id);
    try std.testing.expectEqualStrings(compose.body, std.mem.trimEnd(u8, parsed.body_text, "\r\n"));
    try std.testing.expectEqual(sealed_parts.len, parsed.attachments.len);
    for (parsed.attachments, sealed_parts) |part, metadata| {
        try std.testing.expectEqualStrings(metadata.filename, part.filename);
        try std.testing.expectEqualStrings(sealed_file.blobId.?, &Store.hash(part.data));
    }
}

test "growing chain spool: encrypted thousand image chain matches plaintext MIME with sequential readers" {
    const fixture = try a.create(Fixture);
    defer a.destroy(fixture);
    try fixture.init();
    defer fixture.close();
    const allocator = fixture.arena.allocator();
    const path = try fixture.input("screenshot.png", 41, "SYNTHETIC PRIVATE IMAGE");
    var sealed_store = try Store.openVault(io, allocator, &fixture.first, options, false);
    defer sealed_store.close();
    const sealed_picture = try blob.importFile(&sealed_store, path, "image/png");
    var plain_store = try Store.open(io, allocator, try std.fmt.allocPrint(allocator, "{s}/reference", .{fixture.base}), "reference@example.test", options);
    defer plain_store.close();
    const plain_picture = try blob.importFile(&plain_store, path, "image/png");
    const sealed_parts = try allocator.alloc(t.Attachment, t.Limits.related_resources);
    const plain_parts = try allocator.alloc(t.Attachment, t.Limits.related_resources);
    var html: std.ArrayList(u8) = .empty;
    for (sealed_parts, plain_parts, 0..) |*sealed, *plain, index| {
        const cid = try std.fmt.allocPrint(allocator, "screenshot-{d}@example.test", .{index});
        sealed.* = sealed_picture;
        sealed.contentId = cid;
        plain.* = plain_picture;
        plain.contentId = cid;
        try html.appendSlice(allocator, try std.fmt.allocPrint(allocator, "<img src='cid:{s}'>", .{cid}));
    }
    const recipients = @import("terminal/recipients.zig");
    var envelope: recipients.Envelope = .{};
    try recipients.parse("recipient@example.test", &envelope.to);
    var sender: recipients.Mailbox = .{};
    try sender.address.set("synthetic@example.test");
    const compose: mime.Compose = .{ .from = sender, .envelope = &envelope, .subject = "SYNTHETIC PRIVATE chain", .body = "Every screenshot retained", .html = html.items, .message_id = "<growing-vault@example.test>", .date = "Thu, 08 Oct 2026 12:00:00 +0000" };
    var encrypted = try spool.create(&sealed_store, compose, &.{}, sealed_parts);
    defer encrypted.close();
    try std.testing.expect(fixture.first.reader_owner == null);
    var reference = try spool.create(&plain_store, compose, &.{}, plain_parts);
    defer reference.close();
    try std.testing.expectEqual(reference.size, encrypted.size);
    try std.testing.expectEqualSlices(u8, &reference.hash, &encrypted.hash);
    var reader = try encrypted.reader();
    defer reader.close();
    const raw = try allocator.alloc(u8, encrypted.size);
    var offset: usize = 0;
    while (offset < raw.len) {
        const count = try spool.Spool.Reader.read(&reader, raw[offset..]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    var end: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try spool.Spool.Reader.read(&reader, &end));
    try std.testing.expect(reader.verified);
    const parsed = try mime.parse(raw, allocator);
    try std.testing.expectEqual(t.Limits.related_resources, parsed.attachments.len);
    for (parsed.attachments, sealed_parts) |actual, expected| {
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "<{s}>", .{expected.contentId.?}), actual.content_id);
        try std.testing.expectEqualStrings("SYNTHETIC PRIVATE IMAGE", actual.data[0.."SYNTHETIC PRIVATE IMAGE".len]);
        try std.testing.expectEqual(@as(usize, 41), actual.data.len);
    }
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

test "vault mail: legacy full blob maps permit deduplication and new paged blob identities" {
    const blob_limit = @import("terminal/store.zig").blob_limit;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.close();
    for ([_]bool{ false, true }) |sealed| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        const reference_root = try std.fmt.allocPrint(allocator, "{s}/cap-reference", .{fixture.base});
        var store = if (sealed) try Store.openVault(io, allocator, &fixture.first, options, false) else try Store.open(io, allocator, reference_root, "reference@example.test", options);
        defer store.close();
        const zero: [@sizeOf(u32)]u8 = @splat(0);
        const input = try fixture.input("four-byte.bin", zero.len, &zero);
        const first = try blob.importFile(&store, input, "application/octet-stream");
        // Seed real, distinct content-addressed records in one batch. Reusing
        // importFile for every slot would repeatedly copy and sync the entire
        // growing encrypted index. Quota admission below still uses Incoming.
        const previous = store.vaultObjects;
        const objects = if (sealed) try allocator.alloc(@TypeOf(previous[0]), previous.len + blob_limit - 1) else previous;
        if (sealed) @memcpy(objects[0..previous.len], previous);
        const wire = try allocator.alloc(u8, try vault.sealedSize(zero.len));
        var last = first;
        for (1..blob_limit) |index| {
            var value: [@sizeOf(u32)]u8 = undefined;
            std.mem.writeInt(u32, &value, @intCast(index), .little);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&value, &digest, .{});
            const id = try allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
            const name = try blob.filename(allocator, id);
            if (sealed) {
                const handle = try storage.Handle.create(io);
                const handle_text = handle.text();
                const bytes = try crypto.sealRecord(io, &fixture.key, storage.binding(fixture.first.record(.attachment, handle), &handle_text), &value, wire, &fixture.workspace);
                const file = try store.dir.createFile(io, &handle.filename(), .{ .exclusive = true, .permissions = .fromMode(0o600) });
                defer file.close(io);
                try file.writeStreamingAll(io, bytes);
                objects[previous.len + index - 1] = .{ .name = name, .kind = .attachment, .handle = try allocator.dupe(u8, &handle_text) };
            } else {
                const file = try store.dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
                defer file.close(io);
                try file.writeStreamingAll(io, &value);
            }
            last = .{ .id = id, .filename = "seed.bin", .mimeType = "application/octet-stream", .size = value.len, .blobId = id };
        }
        if (sealed) store.vaultObjects = objects;
        try store.save();
        store.close();
        store = if (sealed) try Store.openVault(io, allocator, &fixture.first, options, false) else try Store.open(io, allocator, reference_root, "reference@example.test", options);
        try blob.verify(&store, first);
        try blob.verify(&store, last);
        try std.testing.expectEqual(@as(usize, blob_limit), (try store.blobStats()).count);
        {
            var duplicate = try blob.Incoming.create(&store, zero.len);
            defer duplicate.close();
            try duplicate.write(&zero);
            try duplicate.finish(zero.len);
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
            var value: [@sizeOf(u32)]u8 = undefined;
            std.mem.writeInt(u32, &value, blob_limit, .little);
            var fresh = try blob.Incoming.create(&store, value.len);
            defer fresh.close();
            try fresh.write(&value);
            try fresh.finish(value.len);
            const added = try fresh.commit(&store, .{ .id = "new", .filename = "new.bin", .size = value.len });
            try blob.verify(&store, added);
            if (sealed) try std.testing.expectEqual(previous.len + blob_limit - 1, store.vaultObjects.len);
        }
        const stats = try store.blobStats();
        try std.testing.expectEqual(@as(usize, blob_limit + 1), stats.count);
        try std.testing.expectEqual((blob_limit + 1) * (if (sealed) try vault.sealedSize(zero.len) else zero.len), stats.bytes);
    }
}
