//! Pure conversation-to-draft construction shared by native and browser
//! providers. Hydration, capabilities, validation and storage belong to callers.
const std = @import("std");
const t = @import("types.zig");
const recipients = @import("recipients.zig");
const mime = @import("mime.zig");
const markdown = @import("markdown_mail.zig");

pub const ReplyOptions = struct {
    account: []const u8,
    aliases: []const []const u8 = &.{},
    all: bool = false,
    format: t.BodyFormat = .plain,
    original: ?t.Original = null,
};
pub const ForwardOptions = struct {
    format: t.BodyFormat = .plain,
    attachments: []const t.Attachment = &.{},
    original: ?t.Original = null,
    /// Optional literal source projection, e.g. semantic HTML-to-text in a
    /// browser. The native default remains the cached message's bodyText.
    body_text: ?[]const u8 = null,
    omitted_attachments: usize = 0,
};
pub fn listAddresses(a: std.mem.Allocator, list: *const recipients.List) ![]const t.Address {
    const result = try a.alloc(t.Address, list.count);
    for (list.slice(), result) |*source, *dest| dest.* = .{ .address = try a.dupe(u8, source.address.slice()), .name = try a.dupe(u8, source.name.slice()) };
    return result;
}
pub fn addressHeader(a: std.mem.Allocator, list: []const t.Address) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    for (list, 0..) |address, index| {
        if (index > 0) try bytes.appendSlice(a, ", ");
        if (address.name.len == 0) {
            try bytes.appendSlice(a, address.address);
        } else {
            const display = try recipients.formatIncomingDisplay(a, address.address, address.name);
            defer a.free(display);
            try bytes.appendSlice(a, display);
        }
    }
    return bytes.items;
}
pub fn quote(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, "\n\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len + 3 > t.Limits.body_bytes - bytes.items.len) return error.BodyTooLarge;
        try bytes.appendSlice(a, "> ");
        try bytes.appendSlice(a, line);
        try bytes.append(a, '\n');
    }
    return bytes.items;
}
pub fn reply(a: std.mem.Allocator, message: t.Message, options: ReplyOptions) !t.Draft {
    const threading = try mime.threading(message.messageId, message.references, message.inReplyTo, a);
    var envelope: recipients.Envelope = .{};
    try recipients.replyIncoming(a, options.account, options.aliases, try addressHeader(a, &.{message.from}), try addressHeader(a, message.replyTo), try addressHeader(a, message.to), try addressHeader(a, message.cc), options.all, &envelope);
    return .{
        .to = try listAddresses(a, &envelope.to),
        .cc = try listAddresses(a, &envelope.cc),
        .subject = if (std.ascii.startsWithIgnoreCase(message.subject, "Re:")) message.subject else try std.fmt.allocPrint(a, "Re: {s}", .{message.subject}),
        .bodyText = if (options.original != null) "" else try quote(a, if (options.format == .markdown) try markdown.escapeSource(a, message.bodyText) else message.bodyText),
        .bodyFormat = options.format,
        .threadId = message.threadId,
        .inReplyTo = threading.in_reply_to,
        .references = threading.references,
        .original = options.original,
    };
}
pub fn forward(a: std.mem.Allocator, message: t.Message, options: ForwardOptions) !t.Draft {
    var draft: t.Draft = .{
        .subject = if (std.ascii.startsWithIgnoreCase(message.subject, "Fwd:")) message.subject else try std.fmt.allocPrint(a, "Fwd: {s}", .{message.subject}),
        .bodyFormat = options.format,
        .attachments = options.attachments,
        .original = options.original,
        .omittedAttachments = options.omitted_attachments,
    };
    if (options.original == null) {
        const original = try std.fmt.allocPrint(a, "---------- Forwarded message ----------\nFrom: {s} <{s}>\nSubject: {s}\n\n{s}", .{ message.from.name, message.from.address, message.subject, options.body_text orelse message.bodyText });
        draft.bodyText = if (options.format == .markdown) try quote(a, try markdown.escapeSource(a, original)) else try std.fmt.allocPrint(a, "\n\n{s}", .{original});
    }
    // A forward deliberately has no original recipients or reply threading.
    return draft;
}
fn appendSpan(a: std.mem.Allocator, out: *std.ArrayList(u8), span: @import("html_document.zig").Span) !void {
    try out.appendSlice(a, span.text);
    if (span.link) |target| if (@import("reader_tools.zig").safeUrl(target) and !std.mem.eql(u8, target, span.text)) {
        try out.appendSlice(a, " (");
        try out.appendSlice(a, target);
        try out.append(a, ')');
    };
    if (out.items.len > t.Limits.body_bytes) return error.BodyTooLarge;
}
/// Literal semantic projection: never execute HTML or fetch remote resources.
/// Preserve safe link targets when their labels would otherwise lose them.
pub fn plainText(a: std.mem.Allocator, message: t.Message) ![]const u8 {
    const html = message.bodyHtml orelse return message.bodyText;
    if (html.len == 0 or (message.bodySource != .html and message.bodyText.len > 0)) return message.bodyText;
    const document = try @import("html_document.zig").parse(html, a);
    var out: std.ArrayList(u8) = .empty;
    for (document.blocks, 0..) |block, index| {
        if (index > 0) try out.appendSlice(a, "\n\n");
        if (block.kind == .table) {
            if (block.table) |table| for (table.rows, 0..) |row, row_index| {
                if (row_index > 0) try out.append(a, '\n');
                for (row.cells, 0..) |cell, cell_index| {
                    if (cell_index > 0) try out.append(a, '\t');
                    for (cell.spans) |span| try appendSpan(a, &out, span);
                }
            };
        } else {
            if (block.kind == .list_item) try out.appendSlice(a, if (block.ordered) try std.fmt.allocPrint(a, "{d}. ", .{block.ordinal}) else "- ");
            if (block.kind == .quote) try out.appendSlice(a, "> ");
            if (block.kind == .rule) try out.appendSlice(a, "---");
            for (block.spans) |span| try appendSpan(a, &out, span);
        }
        if (out.items.len > t.Limits.body_bytes) return error.BodyTooLarge;
    }
    return out.items;
}

test "conversation draft: reply-all excludes self aliases and retains native threading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "sender@example.test", .name = "Sender" }, .replyTo = &.{.{ .address = "reply@example.test" }}, .to = &.{ .{ .address = "self@example.test" }, .{ .address = "alias@example.test" }, .{ .address = "peer@example.test" } }, .cc = &.{.{ .address = "other@example.test" }}, .subject = "Subject", .bodyText = "Line one\nLine two", .messageId = "<source@example.test>", .references = "<prior@example.test>" };
    const draft = try reply(arena.allocator(), message, .{ .account = "self@example.test", .aliases = &.{"alias@example.test"}, .all = true });
    try std.testing.expectEqual(@as(usize, 1), draft.to.len);
    try std.testing.expectEqualStrings("reply@example.test", draft.to[0].address);
    try std.testing.expectEqual(@as(usize, 2), draft.cc.len);
    try std.testing.expectEqualStrings("peer@example.test", draft.cc[0].address);
    try std.testing.expectEqualStrings("other@example.test", draft.cc[1].address);
    try std.testing.expectEqualStrings("Re: Subject", draft.subject);
    try std.testing.expectEqualStrings("\n\n> Line one\n> Line two\n", draft.bodyText);
    try std.testing.expectEqualStrings("thread", draft.threadId);
    try std.testing.expectEqualStrings("<source@example.test>", draft.inReplyTo);
    try std.testing.expectEqualStrings("<prior@example.test> <source@example.test>", draft.references);
}
test "conversation draft: forward preserves semantic links and omission warning without reply identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const message: t.Message = .{ .id = "source", .threadId = "old-thread", .from = .{ .address = "sender@example.test", .name = "Sender" }, .subject = "re: Example", .bodyHtml = "<p><a href=\"https://example.test/rsvp\">Respond here</a></p><script>hidden()</script>", .bodySource = .html, .messageId = "<source@example.test>", .references = "<prior@example.test>" };
    const draft = try forward(a, message, .{ .body_text = try plainText(a, message), .omitted_attachments = 2 });
    try std.testing.expectEqualStrings("Fwd: re: Example", draft.subject);
    try std.testing.expect(std.mem.indexOf(u8, draft.bodyText, "Respond here (https://example.test/rsvp)") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.bodyText, "hidden()") == null);
    try std.testing.expectEqual(@as(usize, 2), draft.omittedAttachments);
    try std.testing.expectEqual(@as(usize, 0), draft.to.len);
    try std.testing.expectEqualStrings("", draft.threadId);
    try std.testing.expectEqualStrings("", draft.inReplyTo);
    try std.testing.expectEqualStrings("", draft.references);
}
