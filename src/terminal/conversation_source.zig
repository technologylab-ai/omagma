//! Capture a received message for a draft without changing its MIME content.
//! Platform adapters supply attachment bytes; selection, quotas, original
//! snapshots and forward partitioning are shared by native and browser.
const std = @import("std");
const t = @import("types.zig");
const original_mail = @import("original_mail.zig");
const conversation = @import("conversation_draft.zig");
const codec = @import("draft_codec.zig");

pub const Attachments = struct {
    context: *anyopaque,
    fetchFn: *const fn (*anyopaque, std.mem.Allocator, t.Message, t.Attachment) anyerror!t.Attachment,
    /// An in-memory adapter can impose its smaller portable storage tier.
    /// The native adapter leaves this unset and may return a bounded blob.
    max_bytes: ?usize = null,

    fn hydrate(self: Attachments, a: std.mem.Allocator, message: t.Message, attachment: t.Attachment) !t.Attachment {
        if (attachment.data.len > 0 or (attachment.size == 0 and attachment.blobId == null)) return attachment;
        return self.fetchFn(self.context, a, message, attachment);
    }
};

pub fn captureOriginal(a: std.mem.Allocator, message: t.Message, source: Attachments) !t.Original {
    try conversation.requireBody(message);
    const html = message.bodyHtml orelse return error.OriginalHtmlUnavailable;
    if (html.len == 0) return error.OriginalHtmlUnavailable;
    if (message.bodyHtmlAmbiguous) return error.AmbiguousOriginalHtml;
    const plan = try original_mail.resourcePlanWithLimit(html, message.attachments, source.max_bytes orelse t.Limits.attachment_bytes);
    if (source.max_bytes) |limit| if (plan.bytes > limit) return error.AttachmentsTooLarge;
    const resources = try a.alloc(t.Attachment, plan.count);
    for (plan.indices[0..plan.count], resources) |index, *resource| resource.* = try source.hydrate(a, message, message.attachments[index]);
    const snapshot: t.Original = .{
        .sourceMessageId = message.id,
        .from = message.from,
        .to = message.to,
        .cc = message.cc,
        .subject = message.subject,
        .date = message.sentDate orelse "",
        .bodyText = message.bodyText,
        .bodyHtml = html,
        .resources = resources,
    };
    try original_mail.validate(snapshot);
    return snapshot;
}

pub const ForwardOptions = struct {
    format: t.BodyFormat = .plain,
    preserve_formatting: bool = false,
    body_text: ?[]const u8 = null,
    omit_attachments: bool = false,
    /// Optional backing allocator for discarded formatting validation output.
    temporary_allocator: ?std.mem.Allocator = null,
};

pub fn forward(a: std.mem.Allocator, message: t.Message, options: ForwardOptions, source: Attachments) !t.Draft {
    try conversation.requireBody(message);
    const preserve = options.preserve_formatting;
    if (options.omit_attachments) {
        if (preserve) return error.InvalidForwardOptions;
        const draft = try conversation.forward(a, message, .{ .format = options.format, .body_text = options.body_text, .omitted_attachments = message.attachments.len });
        try codec.validateDraft(draft, false);
        return draft;
    }
    if (message.attachments.len > (if (preserve) t.Limits.attachments + t.Limits.related_resources else t.Limits.attachments)) return error.TooManyAttachments;
    var total: usize = 0;
    for (message.attachments) |attachment| total = std.math.add(usize, total, attachment.size) catch return error.AttachmentsTooLarge;
    if (total > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
    if (source.max_bytes) |limit| if (total > limit) return error.AttachmentsTooLarge;
    if (preserve) {
        if (message.bodyHtmlAmbiguous) return error.AmbiguousOriginalHtml;
        // Refuse an unsupported resource plan before downloading any file.
        _ = try original_mail.resourcePlanWithLimit(message.bodyHtml orelse return error.OriginalHtmlUnavailable, message.attachments, source.max_bytes orelse t.Limits.attachment_bytes);
    }
    const attachments = try a.dupe(t.Attachment, message.attachments);
    for (attachments) |*attachment| attachment.* = try source.hydrate(a, message, attachment.*);
    var draft: t.Draft = undefined;
    if (preserve) {
        var hydrated = message;
        hydrated.attachments = attachments;
        const snapshot = try captureOriginal(a, hydrated, source);
        var files: std.ArrayList(t.Attachment) = .empty;
        for (attachments) |attachment| {
            var related = false;
            for (snapshot.resources) |resource| related = related or std.mem.eql(u8, attachment.id, resource.id);
            if (!related) try files.append(a, attachment);
        }
        draft = try conversation.forward(a, message, .{ .format = options.format, .attachments = files.items, .original = snapshot });
    } else {
        for (attachments) |*attachment| {
            attachment.contentId = null;
            attachment.disposition = null;
            attachment.contentLocation = null;
        }
        draft = try conversation.forward(a, message, .{ .format = options.format, .attachments = attachments, .body_text = options.body_text });
    }
    try codec.validateDraft(draft, false);
    if (preserve) try validateFormatting(options.temporary_allocator orelse a, draft);
    return draft;
}

pub fn validateFormatting(temporary_allocator: std.mem.Allocator, draft: t.Draft) !void {
    var scratch: std.heap.ArenaAllocator = .init(temporary_allocator);
    defer scratch.deinit();
    _ = try @import("markdown_mail.zig").prepare(scratch.allocator(), draft);
}

pub fn forwardRaw(a: std.mem.Allocator, raw: []const u8, format: t.BodyFormat) !t.Draft {
    const source = try @import("mime.zig").originalSource(a, raw);
    const attachments = try a.alloc(t.Attachment, 1);
    attachments[0] = source.attachment;
    const draft: t.Draft = .{
        .subject = if (std.ascii.startsWithIgnoreCase(source.subject, "Fwd:")) source.subject else try std.fmt.allocPrint(a, "Fwd: {s}", .{source.subject}),
        .bodyFormat = format,
        .attachments = attachments,
    };
    try codec.validateDraft(draft, false);
    return draft;
}

test "conversation source: formatted and text forwards retain the same source bytes" {
    const Fixture = struct {
        calls: usize = 0,
        fn fetch(ctx: *anyopaque, _: std.mem.Allocator, _: t.Message, expected: t.Attachment) !t.Attachment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            var result = expected;
            result.data = "YWJj";
            return result;
        }
        fn source(self: *@This()) Attachments {
            return .{ .context = self, .fetchFn = fetch, .max_bytes = t.Limits.body_bytes };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{};
    const html = "<!DOCTYPE html><html><body><img src=\"cid:logo\"><img src=\"https://example.test/art/chart.png\"><p>Exact source</p></body></html>";
    const message: t.Message = .{
        .id = "source-id",
        .threadId = "source-thread",
        .from = .{ .address = "peer@example.test" },
        .to = &.{.{ .address = "self@example.test" }},
        .subject = "Source",
        .bodyText = "Exact source",
        .bodyHtml = html,
        .attachments = &.{
            .{ .id = "cid-resource", .filename = "logo.png", .mimeType = "image/png", .size = 3, .contentId = "logo", .disposition = "inline" },
            .{ .id = "location-resource", .filename = "chart.png", .mimeType = "image/png", .size = 3, .contentLocation = "https://example.test/art/chart.png", .disposition = "inline" },
            .{ .id = "ordinary", .filename = "source.txt", .mimeType = "text/plain", .size = 3, .disposition = "attachment" },
        },
    };
    const formatted = try forward(a, message, .{ .preserve_formatting = true }, fixture.source());
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqualStrings(html, formatted.original.?.bodyHtml);
    try std.testing.expectEqual(@as(usize, 2), formatted.original.?.resources.len);
    try std.testing.expectEqualStrings("https://example.test/art/chart.png", formatted.original.?.resources[1].contentLocation.?);
    try std.testing.expectEqual(@as(usize, 1), formatted.attachments.len);
    try std.testing.expectEqualStrings("ordinary", formatted.attachments[0].id);
    try std.testing.expectEqualStrings("YWJj", formatted.attachments[0].data);
    try std.testing.expectEqual(@as(usize, 0), formatted.omittedAttachments);
    try std.testing.expectEqualStrings("", formatted.threadId);
    const plain = try forward(a, message, .{}, fixture.source());
    try std.testing.expectEqual(@as(usize, 3), plain.attachments.len);
    for (plain.attachments) |attachment| {
        try std.testing.expectEqualStrings("YWJj", attachment.data);
        try std.testing.expect(attachment.contentId == null and attachment.contentLocation == null and attachment.disposition == null);
    }
    fixture.calls = 0;
    const snapshot = try captureOriginal(a, message, fixture.source());
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), snapshot.resources.len);
}

test "conversation source: preflight rejects oversized and ambiguous captures before hydration" {
    const Fixture = struct {
        calls: usize = 0,
        fn fetch(ctx: *anyopaque, _: std.mem.Allocator, _: t.Message, _: t.Attachment) !t.Attachment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return error.AttachmentNotFound;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{};
    const source: Attachments = .{ .context = &fixture, .fetchFn = Fixture.fetch, .max_bytes = t.Limits.body_bytes };
    const message: t.Message = .{ .id = "source", .threadId = "source-thread", .bodyText = "Keep this source quote", .attachments = &.{.{ .id = "large", .filename = "large.bin", .size = t.Limits.body_bytes + 1 }} };
    try std.testing.expectError(error.AttachmentsTooLarge, forward(a, message, .{}, source));
    const omitted = try forward(a, message, .{ .omit_attachments = true }, source);
    try std.testing.expectEqual(@as(usize, 0), omitted.attachments.len);
    try std.testing.expectEqual(@as(usize, 1), omitted.omittedAttachments);
    try std.testing.expect(std.mem.indexOf(u8, omitted.bodyText, message.bodyText) != null);
    try std.testing.expectError(error.InvalidForwardOptions, forward(a, message, .{ .preserve_formatting = true, .omit_attachments = true }, source));
    var ambiguous = message;
    ambiguous.attachments = &.{};
    ambiguous.bodyHtml = "<p>ambiguous</p>";
    ambiguous.bodyHtmlAmbiguous = true;
    try std.testing.expectError(error.AmbiguousOriginalHtml, forward(a, ambiguous, .{ .preserve_formatting = true }, source));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "conversation source: raw forwarding preserves every original byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "Subject: Exact source\r\nFrom: peer@example.test\r\nContent-Type: application/octet-stream\r\n\r\n\x00\xff\r\n";
    const draft = try forwardRaw(a, raw, .markdown);
    try std.testing.expectEqualStrings("Fwd: Exact source", draft.subject);
    try std.testing.expectEqual(t.BodyFormat.markdown, draft.bodyFormat);
    try std.testing.expectEqualStrings("original.eml", draft.attachments[0].filename);
    try std.testing.expectEqualSlices(u8, raw, try @import("mime.zig").decodeBase64Url(draft.attachments[0].data, a));
    try std.testing.expectEqual(@as(usize, 0), draft.to.len);
    try std.testing.expectEqualStrings("", draft.threadId);
}

test "conversation source: prefixed raw subject and file outlive raw fetch storage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = "Subject: Fwd: Exact source\r\nFrom: peer@example.test\r\nContent-Type: text/plain\r\n\r\nKeep every byte\r\n";
    var source = expected.*;
    const draft = try forwardRaw(a, &source, .plain);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("Fwd: Exact source", draft.subject);
    try std.testing.expectEqualSlices(u8, expected, try @import("mime.zig").decodeBase64Url(draft.attachments[0].data, a));
    try codec.validateDraft(draft, false);
}

test "message isolation: body refusals stop source capture and all forward modes before hydration" {
    const Source = struct {
        calls: usize = 0,
        fn fetch(context: *anyopaque, _: std.mem.Allocator, _: t.Message, _: t.Attachment) !t.Attachment {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.UnexpectedFetch;
        }
    };
    var source: Source = .{};
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    const message: t.Message = .{ .id = "refused", .threadId = "thread", .from = .{ .address = "sender@example.test" }, .bodyHtml = "<p><img src=\"cid:image\"></p>", .bodyCacheError = "BodyTooLarge", .attachments = &.{.{ .id = "image", .filename = "image.png", .mimeType = "image/png", .size = 8, .contentId = "image" }} };
    const adapter: Attachments = .{ .context = &source, .fetchFn = Source.fetch };
    try std.testing.expectError(error.MessageBodyUnavailable, captureOriginal(a, message, adapter));
    for ([_]bool{ false, true }) |preserve| for ([_]bool{ false, true }) |omit| {
        try std.testing.expectError(error.MessageBodyUnavailable, forward(a, message, .{ .preserve_formatting = preserve, .omit_attachments = omit }, adapter));
    };
    try std.testing.expectEqual(@as(usize, 0), source.calls);
}

test "message isolation: raw forwarding preserves unsupported charset bytes and enforces its own size bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "From: sender@example.test\r\nSubject: Opaque original\r\nContent-Type: text/plain; charset=Shift_JIS\r\n\r\n\x82\xa0\x82\xa2\r\n";
    const draft = try forwardRaw(a, raw, .plain);
    try std.testing.expectEqual(@as(usize, 1), draft.attachments.len);
    try std.testing.expectEqualStrings("original.eml", draft.attachments[0].filename);
    try std.testing.expectEqualSlices(u8, raw, try @import("mime.zig").decodeBase64Url(draft.attachments[0].data, a));
    const oversized = try a.alloc(u8, t.Limits.body_bytes + 1);
    @memset(oversized, 'x');
    try std.testing.expectError(error.BodyTooLarge, forwardRaw(a, oversized, .plain));
}
