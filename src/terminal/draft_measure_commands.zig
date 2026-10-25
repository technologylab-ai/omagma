//! Count the canonical outgoing MIME without creating a spool or sending it.
//! The caller reserves this operation ID for the measured draft revision, so
//! transport CIDs and collision-safe MIME boundaries match the eventual send.
const std = @import("std");
const j = @import("json.zig");
const t = @import("types.zig");
const storage = @import("store.zig");
const mime = @import("mime.zig");
const recipients = @import("recipients.zig");
const codec = @import("draft_codec.zig");

fn count(a: std.mem.Allocator, store: *storage.Store, draft: t.Draft, message_id: []const u8) !usize {
    // Included and omitted alternatives are measured independently. Release
    // each render, including failed growth, before attempting the next one.
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const prepared = try @import("markdown_mail.zig").prepare(arena.allocator(), draft);
    const sender = draft.from orelse t.Address{ .address = store.state.account };
    var from: recipients.Mailbox = .{};
    try from.address.set(sender.address);
    try from.name.set(sender.name);
    return @import("send_spool.zig").measure(store, .{
        .from = from,
        .destinations = .{ .to = draft.to, .cc = draft.cc, .bcc = draft.bcc },
        .allow_empty_recipients = true,
        .subject = draft.subject,
        .body = prepared.plain,
        .html = prepared.html,
        .inline_logo = prepared.html != null,
        .logo_offset = prepared.logoOffset,
        .message_id = message_id,
        // Native send dates always have this fixed-width UTC representation.
        .date = "Mon, 05 Oct 2026 12:00:00 +0000",
        .in_reply_to = draft.inReplyTo,
        .references = draft.references,
    }, draft.attachments, prepared.resources);
}

fn provenBodyOverflow(err: anyerror) bool {
    // Native saved sources were validated before this path. These errors now
    // mean a rendered plain/HTML body exceeded 35MiB, which also exceeds the
    // complete MIME ceiling after transfer encoding. Complexity, charset and
    // immutable attachment failures do not prove size and must still fail.
    return t.Limits.native and switch (err) {
        error.RenderedBodyTooLarge, error.BodyTooLarge => true,
        else => false,
    };
}

pub fn run(a: std.mem.Allocator, store: *storage.Store, request: j.Value) !j.Value {
    if (!@import("send_memory.zig").native) return error.UnsupportedCommand;
    const operation_id = try j.required(request, "operationId");
    if (operation_id.len > 256) return error.InvalidOperationId;
    try recipients.validateHeader(operation_id);
    const revision = try j.integer(request, "revision", 0);
    if (revision < 0) return error.InvalidRevision;
    const draft = try store.draft(try j.required(request, "draftId"));
    return measureDraft(a, store, draft, operation_id, revision);
}

fn measureDraft(a: std.mem.Allocator, store: *storage.Store, draft: t.Draft, operation_id: []const u8, revision: i64) !j.Value {
    if (draft.recoveryFields != null) return error.UnfinishedDraft;
    try codec.validateDraft(draft, false);
    const content_digest = try @import("send_outcome.zig").digest(a, draft, store.state.account, null);
    var admission_error: ?[]const u8 = null;
    codec.validateDraft(draft, true) catch |err| {
        admission_error = @errorName(err);
    };
    const identity = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ store.state.account, operation_id });
    const hash = storage.Store.hash(identity);
    const message_id = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{hash});
    const bytes: ?usize = count(a, store, draft, message_id) catch |err| blk: {
        if (!provenBodyOverflow(err)) return err;
        admission_error = @errorName(err);
        break :blk null;
    };
    var without_original: ?usize = null;
    if (draft.original != null and draft.includeOriginal) {
        var omitted = draft;
        omitted.includeOriginal = false;
        without_original = count(a, store, omitted, message_id) catch |err| blk: {
            if (!provenBodyOverflow(err)) return err;
            break :blk null;
        };
    }
    const over_limit = if (bytes) |value| value > t.Limits.mime_upload_bytes else true;
    if (over_limit and admission_error == null) admission_error = "FormTooLarge";
    return j.value(a, .{
        .draftId = draft.id,
        .operationId = operation_id,
        .contentDigest = content_digest[0..],
        .revision = revision,
        .includeOriginal = draft.includeOriginal,
        .bytes = if (bytes) |value| j.Value{ .integer = @intCast(value) } else @as(j.Value, .null),
        .maxBytes = t.Limits.mime_upload_bytes,
        .withoutOriginalBytes = if (without_original) |value| j.Value{ .integer = @intCast(value) } else @as(j.Value, .null),
        .exact = bytes != null,
        .overLimit = over_limit,
        .admissionError = admission_error,
        .sendable = admission_error == null,
    });
}

test "memory UX: measured revision and original policy match actual immutable MIME spool bytes" {
    if (!t.Limits.native) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/measure", .{tmp.sub_path});
    const account = "self@example.test";
    var store = try storage.Store.open(std.testing.io, a, root, account, .{ .fixtures = true });
    defer store.close();
    var draft: t.Draft = .{
        .to = &.{.{ .address = "recipient@example.test" }},
        .subject = "Measured source",
        .bodyText = "New **note**",
        .bodyFormat = .markdown,
        .original = .{ .sourceMessageId = "source", .from = .{ .address = "sender@example.test" }, .bodyText = "Original words", .bodyHtml = "<p>Original words, with the complete source retained.</p>" },
        .attachments = &.{.{ .id = "tiny", .filename = "tiny.txt", .mimeType = "text/plain", .size = 5, .data = "aGVsbG8" }},
    };
    var included_size: usize = 0;
    for ([_]bool{ true, false }) |include| {
        draft.includeOriginal = include;
        draft = try store.putDraft(draft, if (draft.id.len == 0) null else draft.id);
        const request = try j.value(a, .{ .draftId = draft.id, .operationId = "reserved-review", .revision = 7 });
        const receipt = try run(a, &store, request);
        try std.testing.expectEqualStrings("reserved-review", j.text(receipt, "operationId"));
        try std.testing.expectEqualStrings(&try @import("send_outcome.zig").digest(a, draft, account, null), j.text(receipt, "contentDigest"));
        try std.testing.expectEqual(@as(i64, 7), try j.integer(receipt, "revision", -1));
        try std.testing.expect(try j.boolean(receipt, "exact", false));
        try std.testing.expect(try j.boolean(receipt, "sendable", false));
        try std.testing.expectEqual(include, try j.boolean(receipt, "includeOriginal", !include));
        const bytes: usize = @intCast(try j.integer(receipt, "bytes", -1));
        const prepared = try @import("markdown_mail.zig").prepare(a, draft);
        var from: recipients.Mailbox = .{};
        try from.address.set(account);
        const identity = try std.fmt.allocPrint(a, "{s}\x00reserved-review", .{account});
        const hash = storage.Store.hash(identity);
        var spool = try @import("send_spool.zig").create(&store, .{ .from = from, .destinations = .{ .to = draft.to }, .subject = draft.subject, .body = prepared.plain, .html = prepared.html, .inline_logo = prepared.html != null, .logo_offset = prepared.logoOffset, .message_id = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{hash}), .date = "Tue, 06 Oct 2026 12:00:00 +0000" }, draft.attachments, prepared.resources);
        defer spool.close();
        try std.testing.expectEqual(bytes, spool.size);
        if (include) included_size = bytes else {
            try std.testing.expect(bytes < included_size);
            try std.testing.expectEqualStrings("<p>Original words, with the complete source retained.</p>", draft.original.?.bodyHtml);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), store.state.fixtureCalls);
}

test "memory UX: rendered overflow retains digest and exact omission rescue in bounded workspace" {
    if (!t.Limits.native) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer setup.deinit();
    const a = setup.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/overflow", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    // A valid retained source fits its native bound. The extra authored note
    // and original headers make the included outgoing body exceed it. The
    // source is borrowed; no equally large rendered/canonical copy is needed.
    const original = try std.testing.allocator.alloc(u8, t.Limits.compose_body_bytes);
    defer std.testing.allocator.free(original);
    @memset(original, 'x');
    var draft: t.Draft = .{
        .id = "reviewed",
        .to = &.{.{ .address = "recipient@example.test" }},
        .bodyText = "New note",
        .original = .{ .sourceMessageId = "source", .from = .{ .address = "sender@example.test" }, .bodyText = original },
    };
    const workspace = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(workspace);
    var bounded = std.heap.FixedBufferAllocator.init(workspace);
    const receipt = try measureDraft(bounded.allocator(), &store, draft, "overflow-review", 4);
    try std.testing.expect(j.get(receipt, "bytes").? == .null);
    try std.testing.expect(!try j.boolean(receipt, "exact", true));
    try std.testing.expect(try j.boolean(receipt, "overLimit", false));
    try std.testing.expect(!try j.boolean(receipt, "sendable", true));
    try std.testing.expectEqualStrings("RenderedBodyTooLarge", j.text(receipt, "admissionError"));
    try std.testing.expectEqualStrings(&try @import("send_outcome.zig").digest(a, draft, store.state.account, null), j.text(receipt, "contentDigest"));
    const rescued = try j.integer(receipt, "withoutOriginalBytes", -1);
    try std.testing.expect(rescued > 0 and rescued < t.Limits.mime_upload_bytes);
    draft.includeOriginal = false;
    const omitted = try measureDraft(a, &store, draft, "overflow-review", 5);
    try std.testing.expectEqual(rescued, try j.integer(omitted, "bytes", -1));
    try std.testing.expect(try j.boolean(omitted, "exact", false));
    try std.testing.expect(try j.boolean(omitted, "sendable", false));
    try std.testing.expect(!std.mem.eql(u8, j.text(receipt, "contentDigest"), j.text(omitted, "contentDigest")));
    draft.bodyText = "\xff";
    try std.testing.expectError(error.InvalidUtf8, measureDraft(a, &store, draft, "invalid-source", 6));
    draft.original = null;
    draft.bodyText = "New note";
    const blob_id = storage.Store.hash("right");
    const blob_name = try @import("attachment_blob.zig").filename(a, &blob_id);
    const corrupted = try store.dir.createFile(store.io, blob_name, .{ .permissions = .fromMode(0o600) });
    defer corrupted.close(store.io);
    try corrupted.writeStreamingAll(store.io, "wrong");
    draft.attachments = &.{.{ .id = "corrupted", .filename = "source.txt", .mimeType = "text/plain", .size = 5, .blobId = &blob_id }};
    try std.testing.expectError(error.AttachmentChanged, measureDraft(a, &store, draft, "changed-attachment", 7));
    try std.testing.expectEqual(@as(usize, 0), store.state.fixtureCalls);
    for ([_]anyerror{ error.InvalidUtf8, error.InvalidOriginalHtml, error.AttachmentChanged, error.BodySizeMismatch, error.InvalidBase64, error.MarkdownTooComplex, error.OutOfMemory }) |err| try std.testing.expect(!provenBodyOverflow(err));
}
