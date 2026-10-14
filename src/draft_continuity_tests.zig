const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/draft_link.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail_spool.zig"));
    std.testing.refAllDecls(@import("terminal/draft_gmail_import.zig"));
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
