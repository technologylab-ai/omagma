//! Download a verified Gmail draft version into one atomic new local draft.
const std = @import("std");
const j = @import("json.zig");
const t = @import("types.zig");
const storage = @import("store.zig");
const remote = @import("draft_gmail.zig");
const links = @import("draft_link.zig");
const importer = @import("draft_gmail_import.zig");
const blob = @import("attachment_blob.zig");
const gmail = @import("gmail.zig");

pub fn run(s: anytype, a: std.mem.Allocator, account: []const u8, req: j.Value, network: ?*remote.Session, original: links.Link, loaded: importer.Loaded, fixture_source: bool) !t.Draft {
    if (loaded.draft.original != null) return runPreserved(s, a, account, req, network, original, loaded, fixture_source);
    const expected_message = try j.required(req, "expectedRemoteMessageId");
    if (!std.mem.eql(u8, expected_message, loaded.remote.messageId) or !std.mem.eql(u8, original.remoteDraftId, loaded.remote.draftId)) return error.GmailDraftChanged;
    try importer.attachmentBudget(loaded.draft.attachments);
    var store = try s.openStore(a, account, false);
    defer store.close();
    const source_index = links.find(store.state.draftLinks, original.draftId) orelse return error.GmailDraftNotLinked;
    try store.state.draftLinks[source_index].expectVersion(original.version);
    if (store.state.draftLinks.len == links.limit or store.state.drafts.len == 128) return error.DraftLimitExceeded;
    var incoming: [t.Limits.attachments + 1]blob.Incoming = undefined;
    var slots: [t.Limits.attachments + 1]?usize = @splat(null);
    var incoming_count: usize = 0;
    defer for (incoming[0..incoming_count]) |*item| item.close();
    var reservation: usize = 0;
    for (loaded.draft.attachments) |file| {
        if (fixture_source and file.blobId != null) continue;
        reservation += if (store.vault != null) try @import("vault_download.zig").Download.reservation(file.size) + try @import("vault_types.zig").sealedSize(file.size) else file.size;
    }
    if (store.vault != null) try store.reserveVaultCiphertext(reservation + try store.vaultIndexStagingBytes()) else try store.reserveBytes(reservation);
    for (loaded.draft.attachments, 0..) |file, index| {
        if (fixture_source and file.blobId != null) {
            // The synthetic remote snapshot borrows an immutable owned blob.
            // Verify it without opening a simultaneous encrypted writer.
            try blob.verify(&store, file);
            continue;
        }
        const target = &incoming[incoming_count];
        target.* = try blob.Incoming.create(&store, file.size);
        slots[index] = incoming_count;
        incoming_count += 1;
        store.release();
        var buffer: [16 * 1024]u8 = undefined;
        var writer = target.writer(&buffer);
        if (file.data.len != 0 or file.size == 0) {
            try gmail.writeAttachmentData(&writer.interface, file);
        } else {
            const session = network orelse return error.InvalidFixture;
            _ = try session.native.attachmentToWriter(a, expected_message, file, &writer.interface);
        }
        try writer.flush();
        // Finish releases the encrypted workspace pin. Keep the sealed spool
        // itself until the final remote check and atomic local publication.
        try target.finish(file.size);
        store.close();
        store = try s.openStore(a, account, false);
    }
    store.release();
    if (network) |session| {
        const current = try remote.status(a, session.transport(), original.remoteDraftId) orelse return error.GmailDraftChanged;
        if (!std.mem.eql(u8, current.messageId, expected_message)) return error.GmailDraftChanged;
    } else if (std.mem.eql(u8, s.options.fixture_scenario, "gmail-draft-import-race")) return error.GmailDraftChanged;
    store.close();
    store = try s.openStore(a, account, false);
    const fresh_index = links.find(store.state.draftLinks, original.draftId) orelse return error.GmailDraftNotLinked;
    try store.state.draftLinks[fresh_index].expectVersion(original.version);
    var files: std.ArrayList(t.Attachment) = .empty;
    var total: usize = 0;
    for (loaded.draft.attachments, 0..) |file, index| {
        var kept = if (slots[index]) |slot| try incoming[slot].commit(&store, file) else file;
        if (importer.isBranding(file, kept.blobId.?)) continue;
        total = std.math.add(usize, total, kept.size) catch return error.AttachmentsTooLarge;
        if (files.items.len == t.Limits.attachments or total > t.Limits.attachment_bytes) return error.GmailDraftImportUnsupported;
        kept.disposition = "attachment";
        kept.contentId = null;
        kept.contentLocation = null;
        try files.append(a, kept);
    }
    var draft = loaded.draft;
    draft.attachments = files.items;
    try @import("draft_codec.zig").validateDraft(draft, false);
    return store.putImportedDraft(draft, original.draftId, original.version, loaded.remote.messageId);
}

/// Large illustrated imports retain identity metadata while opening one
/// staging file at a time. Only immutable content-addressed blobs are committed
/// early; the new draft and its duplicate-send guard publish together after the
/// same final remote-version check used by the editable-plain import.
fn runPreserved(s: anytype, a: std.mem.Allocator, account: []const u8, req: j.Value, network: ?*remote.Session, original: links.Link, loaded: importer.Loaded, fixture_source: bool) !t.Draft {
    const expected_message = try j.required(req, "expectedRemoteMessageId");
    if (!std.mem.eql(u8, expected_message, loaded.remote.messageId) or !std.mem.eql(u8, original.remoteDraftId, loaded.remote.draftId)) return error.GmailDraftChanged;
    try importer.draftBudget(loaded.draft);
    const backing = @import("send_memory.zig").commandBacking(a, "draft.gmail-import");
    try @import("conversation_source.zig").validateFormatting(backing, loaded.draft);
    var created: std.ArrayList([]const u8) = .empty;
    defer created.deinit(a);
    errdefer discardCreated(s, backing, account, created.items);
    var draft = loaded.draft;
    const files = try a.alloc(t.Attachment, draft.attachments.len);
    for (draft.attachments, files) |file, *kept| {
        kept.* = try downloadOne(s, a, backing, account, network, original, expected_message, file, fixture_source, &created);
        kept.disposition = "attachment";
        kept.contentId = null;
        kept.contentLocation = null;
    }
    const related = try a.alloc(t.Attachment, draft.original.?.resources.len);
    for (draft.original.?.resources, related) |file, *kept| {
        // Even an old generated logo belongs to the preserved HTML. Removing
        // it here would leave an unresolved CID or alter the remote original.
        kept.* = try downloadOne(s, a, backing, account, network, original, expected_message, file, fixture_source, &created);
    }
    if (network) |session| {
        const current = try remote.status(a, session.transport(), original.remoteDraftId) orelse return error.GmailDraftChanged;
        if (!std.mem.eql(u8, current.messageId, expected_message)) return error.GmailDraftChanged;
    } else if (std.mem.eql(u8, s.options.fixture_scenario, "gmail-draft-import-race")) return error.GmailDraftChanged;
    var store = try s.openStore(a, account, false);
    defer store.close();
    const fresh_index = links.find(store.state.draftLinks, original.draftId) orelse return error.GmailDraftNotLinked;
    try store.state.draftLinks[fresh_index].expectVersion(original.version);
    draft.attachments = files;
    draft.original.?.resources = related;
    try @import("draft_codec.zig").validateDraft(draft, false);
    return store.putImportedDraft(draft, original.draftId, original.version, loaded.remote.messageId);
}

fn downloadOne(s: anytype, a: std.mem.Allocator, backing: std.mem.Allocator, account: []const u8, network: ?*remote.Session, original: links.Link, message_id: []const u8, file: t.Attachment, fixture_source: bool, created: *std.ArrayList([]const u8)) !t.Attachment {
    // Reopened indexes and transport metadata are temporary per part, not
    // retained once per screenshot in the encompassing operation arena.
    var phase: std.heap.ArenaAllocator = .init(backing);
    defer phase.deinit();
    const temporary = phase.allocator();
    var store = try s.openStore(temporary, account, false);
    defer store.close();
    const source_index = links.find(store.state.draftLinks, original.draftId) orelse return error.GmailDraftNotLinked;
    try store.state.draftLinks[source_index].expectVersion(original.version);
    if (store.state.draftLinks.len == links.limit or store.state.drafts.len == 128) return error.DraftLimitExceeded;
    if (fixture_source and file.blobId != null) {
        try blob.verify(&store, file);
        return file;
    }
    var incoming = try blob.Incoming.create(&store, file.size);
    defer incoming.close();
    store.release();
    var buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var writer = incoming.writer(&buffer);
    if (file.data.len != 0 or file.size == 0) {
        try gmail.writeAttachmentData(&writer.interface, file);
    } else {
        const session = network orelse return error.InvalidFixture;
        _ = try session.native.attachmentToWriter(temporary, message_id, file, &writer.interface);
    }
    try writer.flush();
    try incoming.finish(file.size);
    store.close();
    store = try s.openStore(temporary, account, false);
    const digest = try incomingDigest(&incoming);
    const id = try a.dupe(u8, &digest);
    const exists = if (store.vault != null)
        store.hasVaultBlob(try blob.filename(temporary, id))
    else exists: {
        const current = blob.open(&store, id, file.size) catch |err| {
            if (err == error.AttachmentHandleNotFound) break :exists false;
            return err;
        };
        current.close(store.io);
        break :exists true;
    };
    // Register before commit so even a failed index publication is eligible
    // for cleanup. Existing or concurrently referenced blobs are never removed.
    if (!exists) try created.append(a, id);
    const committed = try incoming.commit(&store, file);
    if (!std.mem.eql(u8, committed.blobId.?, id)) return error.AttachmentChanged;
    var kept = file;
    kept.data = "";
    kept.blobId = id;
    return kept;
}

fn incomingDigest(incoming: *blob.Incoming) ![64]u8 {
    var reader = try incoming.reader();
    defer reader.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    while (true) {
        const count = try blob.Incoming.Reader.read(&reader, &buffer);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return std.fmt.bytesToHex(hash, .lower);
}

fn discardCreated(s: anytype, backing: std.mem.Allocator, account: []const u8, created: []const []const u8) void {
    if (created.len == 0) return;
    var phase: std.heap.ArenaAllocator = .init(backing);
    defer phase.deinit();
    var store = s.openStore(phase.allocator(), account, false) catch return;
    defer store.close();
    for (created) |id| blob.discard(&store, id) catch {};
}

test "Gmail draft import: many images stream into a protected copy and a version race cleans new blobs" {
    if (!@import("send_memory.zig").native) return error.SkipZigTest;
    const Session = struct {
        root: []const u8,
        options: t.Options = .{ .fixtures = true },
        pub fn openStore(self: *@This(), a: std.mem.Allocator, account: []const u8, readonly: bool) !storage.Store {
            return if (readonly) storage.Store.openCached(std.testing.io, a, self.root, account, self.options) else storage.Store.open(std.testing.io, a, self.root, account, self.options);
        }
    };
    const account = "fictional@example.test";
    const png = @import("markdown_logo.zig").png;
    const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    for ([_]bool{ false, true }) |race| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var session: Session = .{ .root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/rich-import", .{tmp.sub_path}) };
        if (race) session.options.fixture_scenario = "gmail-draft-import-race";
        var seed = try session.openStore(a, account, false);
        defer seed.close();
        const source = try seed.putDraft(.{ .subject = "Local source", .bodyText = "Keep local source unchanged" }, null);
        const digest = try links.contentDigest(a, source, account);
        const link: links.Link = .{ .draftId = source.id, .phase = .linked, .remoteDraftId = "remote-draft", .remoteMessageId = "version-1", .attemptMessageId = "<upload@mail.invalid>", .uploadedDigest = &digest };
        seed.state.draftLinks = try a.dupe(links.Link, &.{link});
        try seed.save();
        // One existing, deliberately unreferenced blob must survive rollback.
        var incoming = try blob.Incoming.create(&seed, png.len);
        try incoming.write(png);
        try incoming.finish(png.len);
        const existing = try incoming.commit(&seed, .{ .id = "existing", .filename = "existing.png", .mimeType = "image/png", .size = png.len });
        incoming.close();
        seed.close();
        const png_data = std.base64.url_safe_no_pad.Encoder.encode(try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(png.len)), png);
        const gif_data = std.base64.url_safe_no_pad.Encoder.encode(try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(gif.len)), gif);
        const files = try a.alloc(t.Attachment, 131);
        var html: std.ArrayList(u8) = .empty;
        try html.appendSlice(a, "<html><body><p>Exact remote original</p>");
        for (files[0..130], 0..) |*file, index| {
            const cid = try std.fmt.allocPrint(a, "image-{d}@example.test", .{index});
            file.* = .{ .id = try std.fmt.allocPrint(a, "part-{d}", .{index}), .filename = try std.fmt.allocPrint(a, "image-{d}.{s}", .{ index, if (index == 0) @as([]const u8, "png") else "gif" }), .mimeType = if (index == 0) "image/png" else "image/gif", .size = if (index == 0) png.len else gif.len, .data = if (index == 0) png_data else gif_data, .contentId = cid, .disposition = "inline" };
            try html.appendSlice(a, try std.fmt.allocPrint(a, "<img src='cid:{s}'>", .{cid}));
        }
        try html.appendSlice(a, "</body></html>");
        files[130] = .{ .id = "ordinary", .filename = "report.pdf", .mimeType = "application/pdf", .size = 3, .data = "UERG", .disposition = "attachment" };
        const headers = try j.value(a, .{ .{ .name = "From", .value = account }, .{ .name = "To", .value = "recipient@example.test" }, .{ .name = "Bcc", .value = "hidden@example.test" }, .{ .name = "Subject", .value = "Remote source" } });
        const loaded: importer.Loaded = .{ .remote = .{ .draftId = "remote-draft", .messageId = "version-2" }, .draft = try importer.fromMessage(a, headers, .{ .id = "version-2", .threadId = "remote-thread", .from = .{ .address = account }, .to = &.{.{ .address = "recipient@example.test" }}, .subject = "Remote source", .bodyText = "Full remote text and old footer", .bodyHtml = html.items, .attachments = files }, account) };
        const request = try j.value(a, .{ .expectedRemoteMessageId = "version-2" });
        const baseline = @import("send_memory.zig").snapshot().allocatorUsedBytes;
        // Inline provider bytes still execute the real Incoming writer,
        // verification, immutable publication and Store reopen path.
        const result = run(&session, a, account, request, null, link, loaded, false);
        try std.testing.expectEqual(baseline, @import("send_memory.zig").snapshot().allocatorUsedBytes);
        if (race) {
            try std.testing.expectError(error.GmailDraftChanged, result);
            var store = try session.openStore(a, account, false);
            defer store.close();
            try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
            try std.testing.expectEqual(@as(u64, 1), store.state.draftLinks[0].version);
            try std.testing.expectEqual(@as(usize, 1), (try store.blobStats()).count);
            try blob.verify(&store, existing);
        } else {
            const imported = try result;
            var store = try session.openStore(a, account, false);
            defer store.close();
            const retained = try store.draft(imported.id);
            try std.testing.expectEqualStrings(source.bodyText, (try store.draft(source.id)).bodyText);
            try std.testing.expectEqualStrings("", retained.bodyText);
            try std.testing.expectEqualStrings(html.items, retained.original.?.bodyHtml);
            try std.testing.expectEqualStrings("Full remote text and old footer", retained.original.?.bodyText);
            try std.testing.expectEqual(@as(usize, 130), retained.original.?.resources.len);
            try std.testing.expectEqual(@as(usize, 1), retained.attachments.len);
            try std.testing.expectEqualStrings("hidden@example.test", retained.bcc[0].address);
            for (retained.original.?.resources, 0..) |file, index| {
                try std.testing.expectEqualStrings(files[index].contentId.?, file.contentId.?);
                try std.testing.expectEqual(@as(usize, 0), file.data.len);
                try blob.verify(&store, file);
            }
            try std.testing.expectEqual(@as(usize, 2), store.state.draftLinks.len);
            try std.testing.expectError(error.GmailCopyUnchecked, @import("draft_gmail_commands.zig").permitSend(&store, a, .null, retained, &(try links.contentDigest(a, retained, account))));
            var spool = try @import("draft_gmail_spool.zig").create(&store, retained, "<preserved-copy@mail.invalid>");
            defer spool.close();
            var reader = try spool.reader();
            defer reader.close();
            const raw = try a.alloc(u8, spool.size);
            var offset: usize = 0;
            while (offset < raw.len) {
                const count = try @import("send_spool.zig").Spool.Reader.read(&reader, raw[offset..]);
                try std.testing.expect(count != 0);
                offset += count;
            }
            var end: [1]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 0), try @import("send_spool.zig").Spool.Reader.read(&reader, &end));
            const parsed = try @import("mime.zig").parse(raw, a);
            try std.testing.expectEqual(@as(usize, 132), parsed.attachments.len);
            try std.testing.expect(std.mem.indexOf(u8, parsed.body_html, "cid:image-129@example.test") != null);
        }
        var store = try session.openStore(a, account, false);
        defer store.close();
        var entries = store.dir.iterate();
        while (try entries.next(std.testing.io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, "download-spool-"));
    }
}
