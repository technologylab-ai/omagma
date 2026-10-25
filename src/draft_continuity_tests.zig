const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/draft_link.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail_spool.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail_import.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail_download.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail_commands.zig"));
    std.testing.refAllDecls(@import("terminal/auth.zig"));
}

test "Gmail draft spool: unfinished recipients preserve MIME envelope and Markdown source" {
    const storage = @import("terminal/store.zig");
    const spool = @import("terminal/draft_gmail_spool.zig");
    const mime = @import("terminal/mime.zig");
    const t = @import("terminal/types.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try storage.Store.open(std.testing.io, a, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/draft-spool", .{tmp.sub_path}), "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    var draft: t.Draft = .{ .subject = "Draft café", .bodyText = "# Still editing\n\n**Source** stays local.", .bodyFormat = .markdown };
    for (0..2) |pass| {
        if (pass == 1) draft.bcc = &.{.{ .address = "hidden@example.test", .name = "Hidden Recipient" }};
        var body = try spool.create(&store, draft, "<synthetic-upload@mail.invalid>");
        defer body.close();
        var reader = try body.reader();
        defer reader.close();
        const bytes = try a.alloc(u8, body.size);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const got = try @import("terminal/send_spool.zig").Spool.Reader.read(&reader, bytes[offset..]);
            try std.testing.expect(got > 0);
            offset += got;
        }
        var end: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try @import("terminal/send_spool.zig").Spool.Reader.read(&reader, &end));
        try std.testing.expect(reader.verified);
        const parsed = try mime.parse(bytes, a);
        try std.testing.expectEqualStrings("Draft café", parsed.subject);
        try std.testing.expectEqualStrings("<synthetic-upload@mail.invalid>", parsed.message_id);
        try std.testing.expectEqual(@as(usize, 0), parsed.to.len);
        try std.testing.expectEqual(pass, parsed.bcc.len);
        if (pass == 1) try std.testing.expectEqualStrings("hidden@example.test", parsed.bcc[0].address);
        try std.testing.expect(std.mem.indexOf(u8, parsed.body_html, "<strong>Source</strong>") != null);
        try std.testing.expectEqualStrings("# Still editing\n\n**Source** stays local.", draft.bodyText);
    }
    // Draft upload's exception does not relax the ordinary send serializer.
    var from: @import("terminal/recipients.zig").Mailbox = .{};
    try from.address.set("fictional@example.test");
    var envelope: @import("terminal/recipients.zig").Envelope = .{};
    var bytes: [4096]u8 = undefined;
    try std.testing.expectError(error.MissingRecipient, mime.encode(.{ .from = from, .envelope = &envelope, .subject = "", .body = "", .message_id = "<send@mail.invalid>", .date = "Mon, 05 Oct 2026 12:00:00 +0000" }, &bytes));
}

test "Gmail draft import: new copy and duplicate-send guard publish together and survive restart" {
    const storage = @import("terminal/store.zig");
    const links = @import("terminal/draft_link.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/draft-import", .{tmp.sub_path});
    const account = "fictional@example.test";
    var store = try storage.Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
    defer store.close();
    const source = try store.putDraft(.{ .subject = "Source", .bodyText = "# Local Markdown", .bodyFormat = .markdown }, null);
    const digest = try links.contentDigest(a, source, account);
    store.state.draftLinks = try a.dupe(links.Link, &.{.{ .draftId = source.id, .phase = .linked, .remoteDraftId = "gmail-draft", .remoteMessageId = "version-1", .attemptMessageId = "<owned-upload@mail.invalid>", .uploadedDigest = &digest }});
    try store.save();
    const copy = try store.putImportedDraft(.{ .subject = "Edited remotely", .bodyText = "Full remote text" }, source.id, 1, "version-2");
    try std.testing.expect(!std.mem.eql(u8, source.id, copy.id));
    try std.testing.expectEqual(@as(usize, 2), store.state.drafts.len);
    try std.testing.expectEqual(@as(usize, 2), store.state.draftLinks.len);
    try std.testing.expectError(error.GmailDraftChanged, store.putImportedDraft(.{}, source.id, 1, "version-2"));
    store.close();
    store = try storage.Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
    const original = try store.draft(source.id);
    const imported = try store.draft(copy.id);
    try std.testing.expectEqualStrings("# Local Markdown", original.bodyText);
    try std.testing.expectEqualStrings("Full remote text", imported.bodyText);
    const source_link = store.state.draftLinks[links.find(store.state.draftLinks, source.id).?];
    const copy_link = store.state.draftLinks[links.find(store.state.draftLinks, copy.id).?];
    try std.testing.expect(source_link.paused and !copy_link.paused);
    try std.testing.expectEqualStrings(copy.id, source_link.lastImportedDraftId);
    try std.testing.expectEqualStrings("version-2", copy_link.remoteMessageId);
    try std.testing.expectError(error.GmailCopyUnchecked, copy_link.permitSend(&(try links.contentDigest(a, imported, account))));
}

test "Gmail draft continuity: omitted original stays local across upload takeback and import as new" {
    if (!@import("terminal/types.zig").Limits.native) return error.SkipZigTest;
    const core = @import("terminal/core.zig");
    const j = @import("terminal/json.zig");
    const t = @import("terminal/types.zig");
    const commands = @import("terminal/draft_gmail_commands.zig");
    const links = @import("terminal/draft_link.zig");
    const blob = @import("terminal/attachment_blob.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/omitted-handoff", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", root);
    const options: t.Options = .{ .fixtures = true, .cache_dir = root };
    const session = try a.create(core.Session);
    try session.initInto(std.testing.io, a, &env, options, null);
    defer session.deinit();
    const account = "personal@example.com";
    const original_text = "Exact retained original with its image.";
    const original_html = "<div>Exact retained original<img src='cid:retained@example.test'></div>";
    var source: t.Draft = undefined;
    var resource: t.Attachment = undefined;
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        const png = @import("terminal/markdown_logo.zig").png;
        var incoming = try blob.Incoming.create(&store, png.len);
        defer incoming.close();
        try incoming.write(png);
        try incoming.finish(png.len);
        resource = try incoming.commit(&store, .{ .id = "retained-image", .filename = "retained.png", .mimeType = "image/png", .size = png.len, .contentId = "retained@example.test", .disposition = "inline" });
        source = try store.putDraft(.{
            .to = &.{.{ .address = "peer@example.test" }},
            .subject = "Omitted original handoff",
            .bodyText = "New **note** only.",
            .bodyFormat = .markdown,
            .includeOriginal = false,
            .threadId = "retained-thread",
            .inReplyTo = "<parent@example.test>",
            .references = "<parent@example.test>",
            .attachments = &.{.{ .id = "ordinary", .filename = "note.txt", .mimeType = "text/plain", .size = 5, .data = "aGVsbG8" }},
            .original = .{ .sourceMessageId = "retained-source", .from = .{ .address = "sender@example.test" }, .bodyText = original_text, .bodyHtml = original_html, .resources = &.{resource} },
        }, null);
    }
    const digest = try links.contentDigest(a, source, account);
    const uploaded = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-save", .draftId = source.id, .expectedVersion = 0, .expectedDigest = digest[0..] }));
    const linked = j.get(uploaded, "link").?;
    const version = try j.integer(linked, "version", -1);
    const remote_message = j.text(linked, "remoteMessageId");
    try std.testing.expectEqualStrings("linked", j.text(uploaded, "outcome"));
    {
        var store = try session.openStore(a, account, true);
        defer store.close();
        const fixture = try std.json.parseFromSliceLeaky(j.Value, a, (try store.readDocument(a, "fixture-gmail-drafts.json", 512 * 1024)).?, .{});
        const record = j.get(fixture, "drafts").?.array.items[0];
        const remote_draft = j.get(record, "draft").?;
        const files = j.get(remote_draft, "attachments").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), files.len);
        try std.testing.expectEqualStrings("note.txt", j.text(files[0], "filename"));
        try std.testing.expect(std.mem.indexOf(u8, j.text(remote_draft, "bodyText"), original_text) == null);
        try std.testing.expect(std.mem.indexOf(u8, j.text(record, "html"), "retained@example.test") == null);
        try std.testing.expectEqual(@as(i64, 1), try j.integer(fixture, "uploads", -1));
    }
    // A fresh process takes back the existing local source; no download or
    // remote replacement participates in this command.
    session.deinit();
    try session.initInto(std.testing.io, a, &env, options, null);
    const taken = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-take-back", .draftId = source.id, .expectedVersion = version }));
    try std.testing.expect(!try j.boolean(j.get(taken, "link").?, "paused", true));
    try std.testing.expectEqualStrings(&digest, j.text(taken, "contentDigest"));
    const imported = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-import", .draftId = source.id, .expectedVersion = try j.integer(j.get(taken, "link").?, "version", -1), .expectedRemoteMessageId = remote_message }));
    const copied_id = j.text(imported, "importedDraftId");
    try std.testing.expect(copied_id.len > 0 and !std.mem.eql(u8, source.id, copied_id));
    try std.testing.expect(!try j.boolean(imported, "importedOriginal", true));
    session.deinit();
    try session.initInto(std.testing.io, a, &env, options, null);
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        const retained = try store.draft(source.id);
        const copied = try store.draft(copied_id);
        try std.testing.expect(!retained.includeOriginal);
        try std.testing.expectEqualStrings(source.bodyText, retained.bodyText);
        try std.testing.expectEqualStrings(original_text, retained.original.?.bodyText);
        try std.testing.expectEqualStrings(original_html, retained.original.?.bodyHtml);
        try std.testing.expectEqualStrings(resource.blobId.?, retained.original.?.resources[0].blobId.?);
        try std.testing.expectEqualStrings(&digest, &try links.contentDigest(a, retained, account));
        try blob.verify(&store, retained.original.?.resources[0]);
        try std.testing.expectError(error.AttachmentInUse, blob.discard(&store, resource.blobId.?));
        try std.testing.expect(copied.original == null);
        try std.testing.expectEqual(@as(usize, 1), copied.attachments.len);
        try std.testing.expectEqualStrings("note.txt", copied.attachments[0].filename);
        try std.testing.expect(std.mem.indexOf(u8, copied.bodyText, original_text) == null);
        // Explicitly including the retained local original restores its exact
        // source and resource, independently of the separate imported copy.
        var restored = retained;
        restored.includeOriginal = true;
        restored = try store.putDraft(restored, retained.id);
        const rendered = try @import("terminal/markdown_mail.zig").prepare(a, restored);
        try std.testing.expect(std.mem.indexOf(u8, rendered.html.?, original_html) != null);
        try std.testing.expectEqual(@as(usize, 1), rendered.resources.len);
        try blob.verify(&store, rendered.resources[0]);
        const fixture = try std.json.parseFromSliceLeaky(j.Value, a, (try store.readDocument(a, "fixture-gmail-drafts.json", 512 * 1024)).?, .{});
        try std.testing.expectEqual(@as(i64, 1), try j.integer(fixture, "uploads", -1));
        try std.testing.expectEqual(@as(usize, 1), j.get(fixture, "drafts").?.array.items.len);
    }
    // Inclusion remains a positive control: a separate explicit upload keeps
    // both the ordinary file and the original resource in its remote fixture.
    var included = source;
    included.includeOriginal = true;
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        included = try store.putDraft(included, null);
    }
    const included_digest = try links.contentDigest(a, included, account);
    _ = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-save", .draftId = included.id, .expectedVersion = 0, .expectedDigest = included_digest[0..] }));
    {
        var store = try session.openStore(a, account, true);
        defer store.close();
        const fixture = try std.json.parseFromSliceLeaky(j.Value, a, (try store.readDocument(a, "fixture-gmail-drafts.json", 512 * 1024)).?, .{});
        try std.testing.expectEqual(@as(i64, 2), try j.integer(fixture, "uploads", -1));
        const record = j.get(fixture, "drafts").?.array.items[1];
        try std.testing.expectEqual(@as(usize, 2), j.get(j.get(record, "draft").?, "attachments").?.array.items.len);
        try std.testing.expect(std.mem.indexOf(u8, j.text(record, "html"), "retained@example.test") != null);
    }
    // A completed native send after Take back may retire its workspace row,
    // while preserving the Gmail duplicate-copy warning with the source.
    const ready = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-info", .draftId = source.id }));
    const send_request = try j.encodeAlloc(a, .{ .cmd = "draft.send", .account = account, .draftId = source.id, .operationId = "takeback-native-send", .acknowledgeGmailCopy = true, .gmailCopyDigest = j.text(ready, "contentDigest"), .expectedContentDigest = j.text(ready, "contentDigest") }, .{});
    const sent = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, send_request), .{});
    try std.testing.expect(try j.boolean(sent, "ok", false));
    try std.testing.expectEqualStrings("applied", j.text(j.get(sent, "data").?, "outcome"));
    var retained_link: links.Link = undefined;
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        retained_link = (try @import("terminal/operation_history.zig").gmailLink(&store, a, source.id)).?;
        try std.testing.expectError(error.ArchivedDraftReadOnly, store.requireActiveDraft(source.id));
        // A prior applied send does not make an uncertain subsequent Gmail
        // handoff archivable. Its exact source and active fence must stay put.
        const uncertain = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Uncertain Gmail handoff" }, null);
        const uncertain_digest = try links.contentDigest(a, uncertain, account);
        const operations = try a.alloc(@import("terminal/store.zig").Operation, store.state.operations.len + 1);
        @memcpy(operations[0..store.state.operations.len], store.state.operations);
        operations[store.state.operations.len] = .{ .id = "prior-uncertain-send", .hash = try a.dupe(u8, &uncertain_digest), .draftId = uncertain.id, .outcome = "applied" };
        store.state.operations = operations;
        const handoffs = try a.alloc(links.Link, store.state.draftLinks.len + 1);
        @memcpy(handoffs[0..store.state.draftLinks.len], store.state.draftLinks);
        handoffs[store.state.draftLinks.len] = .{ .draftId = uncertain.id, .attemptMessageId = "<uncertain-handoff@mail.invalid>", .uploadedDigest = try a.dupe(u8, &uncertain_digest) };
        store.state.draftLinks = handoffs;
        try store.save();
        try @import("terminal/operation_history.zig").compact(&store, true);
        try std.testing.expectError(error.ArchivedDraftReadOnly, store.requireActiveDraft(source.id));
        try store.requireActiveDraft(uncertain.id);
        try store.requireActiveDraft(included.id);
        try std.testing.expect(links.find(store.state.draftLinks, source.id) == null);
        try std.testing.expect(links.find(store.state.draftLinks, uncertain.id) != null);
        try std.testing.expect(links.find(store.state.draftLinks, included.id) != null);
        const archived = try store.draft(source.id);
        const readable = try commands.readResponse(a, &store, archived);
        try std.testing.expectEqualStrings(try j.encodeAlloc(a, retained_link, .{}), try j.encodeAlloc(a, j.get(readable, "gmailLink").?, .{}));
    }
    session.deinit();
    try session.initInto(std.testing.io, a, &env, options, null);
    const archived_info = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-info", .draftId = source.id }));
    try std.testing.expectEqualStrings(try j.encodeAlloc(a, retained_link, .{}), try j.encodeAlloc(a, j.get(archived_info, "link").?, .{}));
    try std.testing.expectError(error.ArchivedDraftReadOnly, commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-status", .draftId = source.id, .expectedVersion = retained_link.version })));
    const replayed = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, send_request), .{});
    try std.testing.expect(try j.boolean(replayed, "ok", false));
    try std.testing.expectEqualStrings("applied", j.text(j.get(replayed, "data").?, "outcome"));
    var store = try session.openStore(a, account, true);
    defer store.close();
    try std.testing.expectEqual(@as(u64, 1), store.state.fixtureSends);
}

test "Gmail draft continuity: applied active sources reject new uploads but finish existing handoffs" {
    const core = @import("terminal/core.zig");
    const storage = @import("terminal/store.zig");
    const j = @import("terminal/json.zig");
    const t = @import("terminal/types.zig");
    const commands = @import("terminal/draft_gmail_commands.zig");
    const links = @import("terminal/draft_link.zig");
    const history = @import("terminal/operation_history.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/accepted-handoff", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", root);
    const session = try a.create(core.Session);
    try session.initInto(std.testing.io, a, &env, .{ .fixtures = true, .cache_dir = root }, null);
    defer session.deinit();
    const account = "personal@example.com";
    var accepted: t.Draft = undefined;
    var pending: t.Draft = undefined;
    {
        var store = try session.openStore(a, account, false);
        defer store.close();
        accepted = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Previously accepted source" }, null);
        pending = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .bodyText = "Existing Gmail handoff" }, null);
    }
    const accepted_digest = try links.contentDigest(a, accepted, account);
    const pending_digest = try links.contentDigest(a, pending, account);
    const uploaded = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-save", .draftId = pending.id, .expectedVersion = 0, .expectedDigest = pending_digest[0..] }));
    const version = try j.integer(j.get(uploaded, "link").?, "version", -1);
    const remote_message = j.text(j.get(uploaded, "link").?, "remoteMessageId");
    {
        // Recreate a legacy accepted source whose archival has not completed.
        // The existing paused handoff remains eligible for explicit recovery.
        var store = try session.openStore(a, account, false);
        defer store.close();
        const operations = try a.alloc(storage.Operation, 64);
        for (operations, 0..) |*operation, index| operation.* = .{ .id = try std.fmt.allocPrint(a, "old-receipt-{d}", .{index}), .hash = "rejected-content", .outcome = "rejected" };
        operations[0] = .{ .id = "accepted-before-archive", .hash = accepted_digest[0..], .draftId = accepted.id, .outcome = "applied" };
        operations[1] = .{ .id = "accepted-before-handoff-recovery", .hash = pending_digest[0..], .draftId = pending.id, .outcome = "applied" };
        store.state.operations = operations;
        try store.save();
    }
    try std.testing.expectError(error.ArchivedDraftReadOnly, commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-save", .draftId = accepted.id, .expectedVersion = 0, .expectedDigest = accepted_digest[0..] })));
    const checked = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-status", .draftId = pending.id, .expectedVersion = version }));
    try std.testing.expectEqualStrings("linked", j.text(checked, "outcome"));
    const taken = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-take-back", .draftId = pending.id, .expectedVersion = version }));
    try std.testing.expectEqualStrings("local", j.text(taken, "outcome"));
    const copied = try commands.run(session, a, account, try j.value(a, .{ .cmd = "draft.gmail-import", .draftId = pending.id, .expectedVersion = try j.integer(j.get(taken, "link").?, "version", -1), .expectedRemoteMessageId = remote_message }));
    try std.testing.expect(j.text(copied, "importedDraftId").len != 0);
    try std.testing.expect(!std.mem.eql(u8, pending.id, j.text(copied, "importedDraftId")));
    var store = try session.openStore(a, account, true);
    defer store.close();
    try store.requireActiveDraft(pending.id);
    try std.testing.expect(try history.immutableSource(&store, pending.id));
    try std.testing.expectEqualStrings(pending.bodyText, (try store.draft(pending.id)).bodyText);
    const fixture = try std.json.parseFromSliceLeaky(j.Value, a, (try store.readDocument(a, "fixture-gmail-drafts.json", 512 * 1024)).?, .{});
    try std.testing.expectEqual(@as(i64, 1), try j.integer(fixture, "uploads", -1));
    try std.testing.expectEqual(@as(u64, 0), store.state.fixtureSends);
}
