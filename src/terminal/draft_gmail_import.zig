//! Import into a NEW local draft. Small copies retain editable plain text with
//! no added footer. Native illustrated copies that exceed ordinary file slots
//! retain a protected formatted original beneath a separately editable note.
//! The source local draft and Gmail copy are never overwritten.
const std = @import("std");
const j = @import("json.zig");
const t = @import("types.zig");
const gmail = @import("gmail.zig");
const remote = @import("draft_gmail.zig");
const mime = @import("mime.zig");
const b = @import("../bounded.zig");
pub const Loaded = struct { remote: remote.Remote, draft: t.Draft };

fn addresses(a: std.mem.Allocator, input: []const @import("recipients.zig").IncomingMailbox) ![]const t.Address {
    if (input.len > t.Limits.recipients) return error.GmailDraftImportUnsupported;
    const out = try a.alloc(t.Address, input.len);
    for (input, out) |item, *target| target.* = .{ .address = try a.dupe(u8, item.address), .name = try a.dupe(u8, item.name) };
    return out;
}
/// Read all envelope fields through the real MIME decoder, including Bcc which
/// the received-mail Message DTO intentionally omits.
pub fn envelope(a: std.mem.Allocator, headers: j.Value, message: t.Message, account: []const u8) !t.Draft {
    const projected = try j.value(a, .{ .payload = .{ .mimeType = "text/plain", .headers = headers, .body = .{ .size = 0, .data = "" } } });
    const parsed = mime.parseGmail(projected, a) catch return error.GmailDraftImportUnsupported;
    if (parsed.from.len > 1 or parsed.to.len + parsed.cc.len + parsed.bcc.len > t.Limits.recipients) return error.GmailDraftImportUnsupported;
    if (message.metadataPartial or message.decodeWarning.len != 0 or message.bodyCacheError.len != 0 or message.bodyHtmlAmbiguous) return error.GmailDraftImportUnsupported;
    // Rendered plain text is a complete editable snapshot, not reconstructed
    // Markdown. Any existing footer stays once; the plain sender adds none.
    const draft: t.Draft = .{
        .to = try addresses(a, parsed.to),
        .cc = try addresses(a, parsed.cc),
        .bcc = try addresses(a, parsed.bcc),
        .from = if (parsed.from.len == 1) .{ .address = try a.dupe(u8, parsed.from[0].address), .name = try a.dupe(u8, parsed.from[0].name) } else .{ .address = try a.dupe(u8, account) },
        .subject = try a.dupe(u8, parsed.subject),
        .bodyText = try a.dupe(u8, message.bodyText),
        .bodyFormat = .plain,
        .threadId = if (parsed.in_reply_to.len > 0) try a.dupe(u8, message.threadId) else "",
        .inReplyTo = try a.dupe(u8, parsed.in_reply_to),
        .references = try a.dupe(u8, parsed.references),
        .attachments = message.attachments,
    };
    if (draft.inReplyTo.len > 0 and !mime.validMessageId(draft.inReplyTo)) return error.GmailDraftImportUnsupported;
    mime.validateReferences(draft.references) catch return error.GmailDraftImportUnsupported;
    // Attachment descriptors are validated after their bytes are downloaded.
    var without_files = draft;
    without_files.attachments = &.{};
    @import("draft_codec.zig").validateDraft(without_files, false) catch return error.GmailDraftImportUnsupported;
    return draft;
}
pub fn load(a: std.mem.Allocator, account: []const u8, transport: gmail.Transport, draft_id: []const u8, expected_message_id: []const u8) !Loaded {
    try b.identifier(draft_id);
    try b.identifier(expected_message_id);
    const url = try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/drafts/{s}?format=metadata&fields=id,message(id,threadId,labelIds,payload(headers))", .{draft_id});
    const value = try transport.requestFn(transport.context, a, .GET, url, null);
    const identified = try remote.parse(value);
    if (!std.mem.eql(u8, identified.draftId, draft_id) or !std.mem.eql(u8, identified.messageId, expected_message_id)) return error.GmailDraftChanged;
    const provider_message = j.get(value, "message") orelse return error.InvalidProviderResponse;
    const labels = j.get(provider_message, "labelIds") orelse return error.GmailDraftImportUnsupported;
    if (labels != .array) return error.InvalidProviderResponse;
    var is_draft = false;
    for (labels.array.items) |label| if (label == .string and std.mem.eql(u8, label.string, "DRAFT")) {
        is_draft = true;
    };
    if (!is_draft) return error.GmailDraftImportUnsupported;
    const headers = j.get(j.get(provider_message, "payload") orelse return error.InvalidProviderResponse, "headers") orelse return error.InvalidProviderResponse;
    const message = try gmail.readAuthorizedMessage(a, account, &.{"mail-read"}, transport, expected_message_id);
    return .{ .remote = identified, .draft = try fromMessage(a, headers, message, account) };
}

/// Keep the existing editable-plain import whenever its ordinary attachment
/// slots suffice. A larger illustrated native copy needs an immutable HTML
/// snapshot so inline resources keep their identities and do not consume file
/// slots. This is a new note above the remote original, not editable remote HTML.
pub fn fromMessage(a: std.mem.Allocator, headers: j.Value, message: t.Message, account: []const u8) !t.Draft {
    return preserveIfNeeded(a, try envelope(a, headers, message, account), message);
}
pub fn preserveIfNeeded(a: std.mem.Allocator, input: t.Draft, message: t.Message) !t.Draft {
    var draft = input;
    if (!@import("send_memory.zig").native or draft.attachments.len <= t.Limits.attachments) return draft;
    // The small import's one extra slot is reserved for a generated logo whose
    // identity AND bytes are checked after download. Preserve that contract.
    if (draft.attachments.len == t.Limits.attachments + 1) {
        for (draft.attachments) |file| if (brandingCandidate(file)) return draft;
    }
    const html = message.bodyHtml orelse return error.GmailDraftImportUnsupported;
    const original_mail = @import("original_mail.zig");
    const plan = try original_mail.resourcePlanWithLimit(html, message.attachments, t.Limits.attachment_bytes);
    if (message.attachments.len - plan.count > t.Limits.attachments) return error.GmailDraftImportUnsupported;
    const resources = try a.alloc(t.Attachment, plan.count);
    var selected: original_mail.ResourceUsage = .empty;
    for (plan.indices[0..plan.count], resources) |index, *resource| {
        resource.* = message.attachments[index];
        selected.set(index);
    }
    const files = try a.alloc(t.Attachment, message.attachments.len - plan.count);
    var next: usize = 0;
    for (message.attachments, 0..) |file, index| if (!selected.isSet(index)) {
        files[next] = file;
        next += 1;
    };
    draft.bodyText = "";
    draft.bodyFormat = .markdown;
    draft.attachments = files;
    draft.original = .{
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
    try original_mail.validate(draft.original.?);
    try draftBudget(draft);
    return draft;
}

pub fn draftBudget(draft: t.Draft) !void {
    const original = draft.original orelse return attachmentBudget(draft.attachments);
    if (draft.attachments.len > t.Limits.attachments or original.resources.len > t.Limits.related_resources) return error.GmailDraftImportUnsupported;
    var bytes: usize = 0;
    for ([_][]const t.Attachment{ draft.attachments, original.resources }) |files| for (files) |file| {
        mime.validateAttachment(file.filename, file.mimeType) catch return error.GmailDraftImportUnsupported;
        bytes = std.math.add(usize, bytes, file.size) catch return error.GmailDraftImportUnsupported;
        if (bytes > t.Limits.attachment_bytes) return error.GmailDraftImportUnsupported;
    };
}
pub fn attachmentBudget(files: []const t.Attachment) !void {
    // One trusted generated branding image can be recognized after downloading
    // its exact bytes. Every other inline image remains an ordinary file.
    if (files.len > t.Limits.attachments + 1) return error.GmailDraftImportUnsupported;
    var bytes: usize = 0;
    for (files) |file| {
        mime.validateAttachment(file.filename, file.mimeType) catch return error.GmailDraftImportUnsupported;
        bytes = std.math.add(usize, bytes, file.size) catch return error.GmailDraftImportUnsupported;
        if (bytes > t.Limits.attachment_bytes + @import("markdown_logo.zig").png.len) return error.GmailDraftImportUnsupported;
    }
}
pub fn isBranding(file: t.Attachment, digest: []const u8) bool {
    if (!brandingCandidate(file)) return false;
    return std.mem.eql(u8, digest, "e2e844a35476454f11b513404041135327fec6354f7b6e7e0269a32fdf56d3c4");
}
fn brandingCandidate(file: t.Attachment) bool {
    return file.contentId != null and std.mem.eql(u8, file.contentId.?, @import("markdown_logo.zig").content_id) and file.size == @import("markdown_logo.zig").png.len;
}

test "Gmail draft import: complete envelope and full plaintext do not append quote or footer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const headers = try j.value(a, .{
        .{ .name = "From", .value = "Alias <alias@example.test>" },
        .{ .name = "To", .value = "First <first@example.test>" },
        .{ .name = "Cc", .value = "Second <second@example.test>" },
        .{ .name = "Bcc", .value = "=?UTF-8?B?SMOkbnNlbA==?= <hidden@example.test>" },
        .{ .name = "Subject", .value = "Edited in Gmail" },
        .{ .name = "In-Reply-To", .value = "<original@example.test>" },
        .{ .name = "References", .value = "<original@example.test>" },
    });
    const text = "Phone edits\n\nExisting quote\nSent with omagma\n";
    const draft = try envelope(a, headers, .{ .id = "m1", .threadId = "t1", .bodyText = text }, "self@example.test");
    try std.testing.expectEqualStrings("hidden@example.test", draft.bcc[0].address);
    try std.testing.expectEqualStrings("Hänsel", draft.bcc[0].name);
    try std.testing.expectEqualStrings("alias@example.test", draft.from.?.address);
    try std.testing.expectEqualStrings("t1", draft.threadId);
    try std.testing.expectEqualStrings(text, draft.bodyText);
    try std.testing.expectEqual(.plain, draft.bodyFormat);
    try std.testing.expect(draft.original == null);
    try std.testing.expectEqualStrings(text, (try @import("markdown_mail.zig").prepare(a, draft)).plain);
    try std.testing.expectError(error.GmailDraftImportUnsupported, envelope(a, headers, .{ .id = "m1", .threadId = "t1", .bodyCacheError = "BodyTooLarge" }, "self@example.test"));
}

test "Gmail draft import: provider version and envelope are checked before reading full content" {
    const Oracle = struct {
        reads: usize = 0,
        fn request(context: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) anyerror!j.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(.GET, method);
            try std.testing.expect(body == null);
            const message = try std.json.parseFromSliceLeaky(j.Value, a,
                \\{"id":"version-2","threadId":"thread-1","labelIds":["DRAFT"],"internalDate":"1","payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"self@example.test"},{"name":"Bcc","value":"hidden@example.test"},{"name":"Subject","value":"Remote edit"}],"body":{"size":12,"data":"UmVtb3RlIHRleHQu"}}}
            , .{});
            if (std.mem.indexOf(u8, url, "/drafts/") != null) return j.value(a, .{ .id = "remote-1", .message = message });
            self.reads += 1;
            return message;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: Oracle = .{};
    const transport: gmail.Transport = .{ .context = &oracle, .requestFn = Oracle.request };
    try std.testing.expectError(error.GmailDraftChanged, load(a, "self@example.test", transport, "remote-1", "version-1"));
    try std.testing.expectEqual(@as(usize, 0), oracle.reads);
    const loaded = try load(a, "self@example.test", transport, "remote-1", "version-2");
    try std.testing.expectEqualStrings("Remote text.", loaded.draft.bodyText);
    try std.testing.expectEqualStrings("hidden@example.test", loaded.draft.bcc[0].address);
    try std.testing.expectEqualStrings("", loaded.draft.threadId);
    try std.testing.expectEqual(@as(usize, 1), oracle.reads);
}

test "Gmail draft import: illustrated native copies preserve complete source and separate ordinary files" {
    if (!@import("send_memory.zig").native) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const headers = try j.value(a, .{
        .{ .name = "From", .value = "Alias <alias@example.test>" },
        .{ .name = "To", .value = "Recipient <recipient@example.test>" },
        .{ .name = "Bcc", .value = "hidden@example.test" },
        .{ .name = "Subject", .value = "Remote illustrated copy" },
    });
    var html: std.ArrayList(u8) = .empty;
    try html.appendSlice(a, "<html><body><p>");
    try html.appendNTimes(a, 'x', 3 * 1024 * 1024);
    try html.appendSlice(a, "</p>");
    const files = try a.alloc(t.Attachment, 130);
    for (files[0..129], 0..) |*file, index| {
        const id = try std.fmt.allocPrint(a, "image-{d}", .{index});
        const cid = try std.fmt.allocPrint(a, "{s}@example.test", .{id});
        file.* = .{ .id = id, .filename = try std.fmt.allocPrint(a, "{s}.png", .{id}), .mimeType = "image/png", .size = 3, .contentId = cid, .disposition = "inline" };
        try html.appendSlice(a, try std.fmt.allocPrint(a, "<img src='cid:{s}'>", .{cid}));
    }
    try html.appendSlice(a, "</body></html>");
    files[129] = .{ .id = "ordinary", .filename = "report.pdf", .mimeType = "application/pdf", .size = 4, .disposition = "attachment" };
    const message: t.Message = .{ .id = "remote-version", .threadId = "remote-thread", .from = .{ .address = "alias@example.test" }, .to = &.{.{ .address = "recipient@example.test" }}, .subject = "Remote illustrated copy", .bodyText = "Complete remote plaintext, including its old footer.", .bodyHtml = html.items, .attachments = files };
    const draft = try fromMessage(a, headers, message, "self@example.test");
    try std.testing.expectEqualStrings("", draft.bodyText);
    try std.testing.expectEqual(.markdown, draft.bodyFormat);
    try std.testing.expectEqualStrings("hidden@example.test", draft.bcc[0].address);
    try std.testing.expectEqualStrings("alias@example.test", draft.from.?.address);
    try std.testing.expectEqualStrings(message.bodyText, draft.original.?.bodyText);
    try std.testing.expectEqualStrings(html.items, draft.original.?.bodyHtml);
    try std.testing.expectEqual(@as(usize, 129), draft.original.?.resources.len);
    try std.testing.expectEqualStrings("image-128@example.test", draft.original.?.resources[128].contentId.?);
    try std.testing.expectEqual(@as(usize, 1), draft.attachments.len);
    try std.testing.expectEqualStrings("ordinary", draft.attachments[0].id);
    var small = message;
    small.attachments = files[0..t.Limits.attachments];
    const plain = try fromMessage(a, headers, small, "self@example.test");
    try std.testing.expect(plain.original == null);
    try std.testing.expectEqual(.plain, plain.bodyFormat);
    try std.testing.expectEqualStrings(message.bodyText, plain.bodyText);
    var refused = message;
    refused.bodyHtml = null;
    try std.testing.expectError(error.GmailDraftImportUnsupported, fromMessage(a, headers, refused, "self@example.test"));
    files[128].contentId = files[0].contentId;
    try std.testing.expectError(error.OriginalResourceUnavailable, fromMessage(a, headers, message, "self@example.test"));
    files[128].contentId = "image-128@example.test";
    files[128].contentLocation = "same.png";
    files[0].contentLocation = "same.png";
    try std.testing.expectError(error.AmbiguousContentId, fromMessage(a, headers, message, "self@example.test"));
}
