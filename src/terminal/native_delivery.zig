//! Store-backed, local-only delivery preview and canonical MIME materialization.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const delivery = @import("attachment_delivery.zig");
const markdown = @import("markdown_mail.zig");
const Store = @import("store.zig").Store;
const A = std.mem.Allocator;
pub const Materialized = struct { draft: t.Draft, prepared: markdown.Prepared };
/// Dormant generated descriptors stay owned by the source even though they do
/// not enter MIME. Never let their reserved CID namespace bypass blob checks.
pub fn verifySource(store: *Store, draft: t.Draft) !void {
    for (draft.attachments) |file| if (markdown.isClipboardInline(file) and file.blobId != null) try @import("attachment_blob.zig").verify(store, file);
}
pub fn materialize(a: A, draft: t.Draft, items: []const delivery.Item, ids: []const []const u8) !Materialized {
    var suffix = draft;
    suffix.bodyText = "";
    suffix.original = null;
    suffix.recoveryFields = null;
    suffix.bcc = &.{};
    const source = try delivery.wireDraft(a, suffix, items, ids);
    var wire = draft;
    wire.attachments = source.attachments;
    const prepared = try markdown.prepareWithSuffix(a, wire, source.bodyText);
    wire.attachments = prepared.files(wire);
    return .{ .draft = wire, .prepared = prepared };
}
const Counter = struct {
    store: *Store,
    message_id: []const u8 = "<omagma-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@mail.invalid>",
    fn count(ctx: *anyopaque, a: A, draft: t.Draft, items: []const delivery.Item) !usize {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        var temporary: std.heap.ArenaAllocator = .init(a);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        var ids: [delivery.max_drive_files][]const u8 = undefined;
        const placeholder: [256]u8 = @splat('x');
        var n: usize = 0;
        for (items) |item| if (item.delivery == .drive) {
            if (n == ids.len) return error.TooManyDriveFiles;
            ids[n] = &placeholder;
            n += 1;
        };
        const wire = try materialize(scratch, draft, items, ids[0..n]);
        return measure(scratch, self.store, wire, self.message_id);
    }
};
pub fn measure(a: A, store: *Store, wire: Materialized, message_id: []const u8) !usize {
    _ = a;
    const sender = wire.draft.from orelse t.Address{ .address = store.state.account };
    var from: @import("recipients.zig").Mailbox = .{};
    try from.address.set(sender.address);
    try from.name.set(sender.name);
    return @import("send_spool.zig").measure(store, .{
        .from = from,
        .destinations = .{ .to = wire.draft.to, .cc = wire.draft.cc, .bcc = wire.draft.bcc },
        .allow_empty_recipients = true,
        .subject = wire.draft.subject,
        .body = wire.prepared.plain,
        .html = wire.prepared.html,
        .inline_logo = wire.prepared.html != null,
        .logo_offset = wire.prepared.logoOffset,
        .message_id = message_id,
        .date = "Mon, 05 Oct 2026 12:00:00 +0000",
        .in_reply_to = wire.draft.inReplyTo,
        .references = wire.draft.references,
    }, wire.prepared.files(wire.draft), wire.prepared.resources);
}
pub fn resolve(a: A, store: *Store, draft: t.Draft) !delivery.Plan {
    try verifySource(store, draft);
    var counter: Counter = .{ .store = store };
    return delivery.resolve(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
}
pub fn preview(a: A, store: *Store, draft: t.Draft) !delivery.Plan {
    try verifySource(store, draft);
    var counter: Counter = .{ .store = store };
    return delivery.preview(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
}
pub fn previewWithIdentity(a: A, store: *Store, draft: t.Draft, message_id: []const u8) !delivery.Plan {
    try verifySource(store, draft);
    var counter: Counter = .{ .store = store, .message_id = message_id };
    return delivery.preview(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
}
pub fn requested(draft: t.Draft) bool {
    for (draft.attachments) |file| if (file.delivery != null and file.delivery.? != .attach) return true;
    return false;
}
pub fn value(a: A, draft: t.Draft, plan: delivery.Plan) !j.Value {
    var files: std.ArrayList(j.Value) = .empty;
    for (draft.attachments, plan.items) |file, item| try files.append(a, try j.value(a, .{
        .index = item.index,
        .filename = file.filename,
        .size = file.size,
        .mimeType = file.mimeType,
        .requestedDelivery = file.delivery orelse .attach,
        .delivery = item.delivery,
        .state = if (item.omitted) @as([]const u8, "not_in_body") else "planned",
        .reuse = "none",
        .newCopy = false,
        .sharedWith = [_][]const u8{},
    }));
    var blockers: std.ArrayList(j.Value) = .empty;
    if (plan.drive_count != 0 and draft.bcc.len != 0) try blockers.append(a, try j.value(a, .{ .code = "DriveWithBcc", .message = "Drive delivery can't be used with Bcc recipients." }));
    if (plan.drive_count != 0 and draft.to.len + draft.cc.len == 0) try blockers.append(a, try j.value(a, .{ .code = "DriveNoRecipients", .message = "Drive files need at least one To or Cc recipient." }));
    var inline_over_limit = false;
    if (plan.attached_bytes > t.Limits.attachment_bytes or plan.mime_bytes > t.Limits.mime_upload_bytes) {
        var candidate = false;
        for (draft.attachments) |file| candidate = candidate or (file.contentId != null and std.mem.eql(u8, file.disposition orelse "", "inline"));
        if (candidate) {
            const used = try markdown.inlineUsage(a, draft);
            defer a.free(used);
            var inline_bytes: usize = 0;
            for (draft.attachments, used) |file, active| if (active) {
                inline_bytes = std.math.add(usize, inline_bytes, file.size) catch return error.AttachmentsTooLarge;
            };
            inline_over_limit = inline_bytes > t.Limits.attachment_bytes;
        }
    }
    const message = if (inline_over_limit) @as([]const u8, "Inline images are over the limit — remove a marker, or save the image and attach with A.") else "Set large files to Auto or Drive.";
    if (plan.attached_bytes > t.Limits.attachment_bytes) try blockers.append(a, try j.value(a, .{ .code = "AttachmentsTooLarge", .message = message }));
    if (plan.mime_bytes > t.Limits.mime_upload_bytes) try blockers.append(a, try j.value(a, .{ .code = "MessageTooLarge", .message = message }));
    if (plan.drive_count > delivery.max_drive_files) try blockers.append(a, try j.value(a, .{ .code = "TooManyDriveFiles", .message = "At most 16 Drive files per message." }));
    return j.value(a, .{
        .files = files.items,
        .attachedBytes = plan.attached_bytes,
        .mimeBytes = plan.mime_bytes,
        .mimeEstimate = plan.drive_count != 0 or plan.estimated,
        .driveFileCount = plan.drive_count,
        .driveFileLimit = delivery.max_drive_files,
        .decodedLimitBytes = t.Limits.attachment_bytes,
        .mimeLimitBytes = t.Limits.mime_upload_bytes,
        .blockers = blockers.items,
    });
}

pub fn valueWithStore(a: A, store: *Store, draft: t.Draft, plan: delivery.Plan, operation_id: []const u8) !j.Value {
    var result = try value(a, draft, plan);
    if (plan.drive_count == 0) return result;
    const prepare = @import("drive_prepare.zig");
    const book = try prepare.Book.load(a, store);
    var recipients_draft = draft;
    recipients_draft.bcc = &.{};
    const recipients = prepare.recipientSet(a, recipients_draft) catch &.{};
    var recipient_hash: ?[64]u8 = null;
    if (recipients.len != 0) recipient_hash = Store.hash(try j.encodeAlloc(a, recipients, .{}));
    const entries = result.object.getPtr("files").?;
    for (plan.items) |item| {
        if (item.delivery != .drive) continue;
        const info = try book.reuse(a, draft.attachments[item.index], if (recipient_hash) |*hash| hash else null, operation_id, item.index);
        var entry = &entries.array.items[item.index];
        try entry.object.put(a, "reuse", .{ .string = info.kind });
        try entry.object.put(a, "newCopy", .{ .bool = info.newCopy });
        try entry.object.put(a, "sharedWith", try j.value(a, info.sharedWith));
    }
    return result;
}

test "authored inline images: immutable local source survives restart previews in place and authenticates dormant blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const blob = @import("attachment_blob.zig");
    const png = @import("markdown_logo.zig").png;
    try tmp.dir.writeFile(io, .{ .sub_path = "screenshot.png", .data = png, .flags = .{ .permissions = .fromMode(0o600) } });
    const path = try tmp.dir.realPathFileAlloc(io, "screenshot.png", a);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/inline", .{tmp.sub_path});
    var store = try Store.open(io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    var image = try blob.importFile(&store, path, "image/png");
    image.contentId = "clipboard-0123456789abcdef0123456789abcdef@omagma.invalid";
    image.disposition = "inline";
    image.delivery = .attach;
    const source: t.Draft = .{ .to = &.{.{ .address = "recipient@example.test" }}, .bodyText = "Before screenshot.\n\n![Screenshot](cid:clipboard-0123456789abcdef0123456789abcdef@omagma.invalid)\n\nAfter screenshot.", .bodyFormat = .markdown, .attachments = &.{image} };
    const saved = try store.putDraft(source, null);
    const id = try a.dupe(u8, saved.id);
    store.close();
    store = try Store.open(io, a, root, "fictional@example.test", .{ .fixtures = true });
    const reopened = try store.draft(id);
    try std.testing.expectEqualStrings(source.bodyText, reopened.bodyText);
    try std.testing.expectEqualStrings(image.contentId.?, reopened.attachments[0].contentId.?);
    try std.testing.expectEqualStrings(image.blobId.?, reopened.attachments[0].blobId.?);
    try verifySource(&store, reopened);
    const plan = try resolve(a, &store, reopened);
    const wire = try materialize(a, reopened, plan.items, &.{});
    try std.testing.expectEqual(@as(usize, 0), wire.draft.attachments.len);
    try std.testing.expectEqual(@as(usize, 1), wire.prepared.resources.len);
    const preview_file = @import("preview_file.zig");
    const preview_size = try preview_file.byteSizeWithStore(&store, wire.prepared, wire.draft);
    _ = try preview_file.writePreviewWithStore(&store, a, wire.prepared, wire.draft);
    const preview_html = try store.dir.readFileAlloc(io, preview_file.filename, a, .limited(preview_file.max_file_bytes));
    try std.testing.expectEqual(preview_size, preview_html.len);
    const before = std.mem.indexOf(u8, preview_html, "Before screenshot.").?;
    const picture = std.mem.indexOf(u8, preview_html[before..], "data:image/png;base64,").? + before;
    const after = std.mem.indexOf(u8, preview_html[picture..], "After screenshot.").? + picture;
    try std.testing.expect(before < picture and picture < after);
    const mime = @import("mime.zig");
    var from: @import("recipients.zig").Mailbox = .{};
    try from.address.set("fictional@example.test");
    const compose: mime.Compose = .{ .from = from, .destinations = .{ .to = reopened.to }, .subject = "", .body = wire.prepared.plain, .html = wire.prepared.html, .inline_logo = true, .logo_offset = wire.prepared.logoOffset, .message_id = "<restart-fixture@example.test>", .date = "Tue, 03 Nov 2026 12:00:00 +0000" };
    const spool_module = @import("send_spool.zig");
    var spool = try spool_module.create(&store, compose, wire.draft.attachments, wire.prepared.resources);
    defer spool.close();
    const measured = try spool_module.measure(&store, compose, wire.draft.attachments, wire.prepared.resources);
    try std.testing.expectEqual(spool.size, measured);
    const raw = try a.alloc(u8, spool.size);
    var reader = try spool.reader();
    defer reader.close();
    var cursor: usize = 0;
    while (cursor < raw.len) {
        const n = try spool_module.Spool.Reader.read(&reader, raw[cursor..]);
        try std.testing.expect(n != 0);
        cursor += n;
    }
    var tail: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try spool_module.Spool.Reader.read(&reader, &tail));
    const parsed = try mime.parse(raw, a);
    var authored: usize = 0;
    for (parsed.attachments) |part| if (std.mem.eql(u8, mime.contentId(part.content_id) catch "", image.contentId.?)) {
        authored += 1;
        try std.testing.expectEqualSlices(u8, png, part.data);
    };
    try std.testing.expectEqual(@as(usize, 1), authored);
    var dormant = reopened;
    dormant.bodyText = "Image removed from body.";
    var forged = image;
    const missing: [64]u8 = @splat('0');
    forged.blobId = &missing;
    dormant.attachments = &.{forged};
    try std.testing.expectError(error.AttachmentHandleNotFound, verifySource(&store, dormant));
    dormant.attachments = reopened.attachments;
    const blob_name = try blob.filename(a, image.blobId.?);
    const damaged = try a.dupe(u8, png);
    damaged[damaged.len - 1] ^= 1;
    try store.dir.writeFile(io, .{ .sub_path = blob_name, .data = damaged, .flags = .{ .permissions = .fromMode(0o600) } });
    try std.testing.expectError(error.AttachmentChanged, verifySource(&store, dormant));
}

test "authored inline images: real local delivery plans distinguish inline-only overflow from movable ordinary files" {
    const Fixture = struct {
        fn file(store: *Store, directory: std.Io.Dir, name: []const u8, size: usize, mime_type: []const u8) !t.Attachment {
            const output = try directory.createFile(store.io, name, .{ .permissions = .fromMode(0o600) });
            defer output.close(store.io);
            try output.setLength(store.io, size);
            const path = try directory.realPathFileAlloc(store.io, name, store.allocator);
            return @import("attachment_blob.zig").importFile(store, path, mime_type);
        }
        fn advice(a: A, draft: t.Draft, plan: delivery.Plan, expected: []const u8) !void {
            const result = try value(a, draft, plan);
            const blockers = j.get(result, "blockers").?.array.items;
            try std.testing.expect(blockers.len > 0);
            for (blockers) |blocker| {
                try std.testing.expect(std.mem.eql(u8, j.text(blocker, "code"), "AttachmentsTooLarge") or std.mem.eql(u8, j.text(blocker, "code"), "MessageTooLarge"));
                try std.testing.expectEqualStrings(expected, j.text(blocker, "message"));
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/inline-limits", .{tmp.sub_path});
    var store = try Store.open(std.testing.io, a, root, "fictional@example.test", .{ .fixtures = true });
    defer store.close();
    const cid_a = "clipboard-0123456789abcdef0123456789abcdea@omagma.invalid";
    const cid_b = "clipboard-0123456789abcdef0123456789abcdeb@omagma.invalid";
    var thirteen = try Fixture.file(&store, tmp.dir, "thirteen.png", 13 * 1024 * 1024, "image/png");
    thirteen.contentId = cid_a;
    thirteen.disposition = "inline";
    thirteen.delivery = .attach;
    var second = thirteen;
    second.contentId = cid_b;
    const inline_draft: t.Draft = .{ .to = &.{.{ .address = "recipient@example.test" }}, .bodyFormat = .markdown, .bodyText = "![a](cid:" ++ cid_a ++ ")\n\n![b](cid:" ++ cid_b ++ ")", .attachments = &.{ thirteen, second } };
    const inline_plan = try preview(a, &store, inline_draft);
    try std.testing.expectEqual(@as(usize, 26 * 1024 * 1024), inline_plan.attached_bytes);
    try Fixture.advice(a, inline_draft, inline_plan, "Inline images are over the limit — remove a marker, or save the image and attach with A.");
    var ordinary = try Fixture.file(&store, tmp.dir, "ordinary.pdf", 20 * 1024 * 1024, "application/pdf");
    ordinary.delivery = .attach;
    var ten = try Fixture.file(&store, tmp.dir, "ten.png", 10 * 1024 * 1024, "image/png");
    ten.contentId = cid_a;
    ten.disposition = "inline";
    ten.delivery = .attach;
    // The dormant 13 MiB descriptor must not change either the subtotal or
    // the advice. All three handles are real, authenticated account blobs.
    var mixed: t.Draft = .{ .to = inline_draft.to, .bodyFormat = .markdown, .bodyText = "![a](cid:" ++ cid_a ++ ")", .attachments = &.{ ordinary, ten, second } };
    const mixed_plan = try preview(a, &store, mixed);
    try std.testing.expectEqual(@as(usize, 30 * 1024 * 1024), mixed_plan.attached_bytes);
    try std.testing.expect(mixed_plan.items[2].omitted);
    try Fixture.advice(a, mixed, mixed_plan, "Set large files to Auto or Drive.");
    // Following that advice can move the ordinary PDF, retaining the inline
    // image as an actual related MIME part under the unchanged exact limits.
    ordinary.delivery = .auto;
    mixed.attachments = &.{ ordinary, ten, second };
    const movable = try resolve(a, &store, mixed);
    try std.testing.expectEqual(@as(usize, 1), movable.drive_count);
    try std.testing.expectEqual(t.AttachmentDelivery.drive, movable.items[0].delivery);
    try std.testing.expectEqual(t.AttachmentDelivery.attach, movable.items[1].delivery);
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), movable.attached_bytes);
    try std.testing.expect(movable.mime_bytes <= t.Limits.mime_upload_bytes);
    const resolved = try value(a, mixed, movable);
    try std.testing.expectEqual(@as(usize, 0), j.get(resolved, "blockers").?.array.items.len);
}
