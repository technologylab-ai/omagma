//! Pure conversation-to-draft construction shared by native and browser
//! providers. Hydration, capabilities, validation and storage belong to callers.
const std = @import("std");
const t = @import("types.zig");
const recipients = @import("recipients.zig");
const mime = @import("mime.zig");
const markdown = @import("markdown_mail.zig");
const mail_limits = @import("mail_limits.zig");

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
pub fn requireBody(message: t.Message) !void {
    if (message.bodyCacheError.len != 0) return error.MessageBodyUnavailable;
    // Reading degrades gracefully; writing does not. A source known to be
    // incomplete is shown with its warning but is never quoted or forwarded
    // as though it were the whole message.
    for ([_][]const u8{ "BodySizeMismatch", "ContentTruncated" }) |incomplete| {
        if (std.mem.eql(u8, message.decodeWarning, incomplete)) return error.MessageBodyUnavailable;
    }
}
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
        if (line.len + 3 > t.Limits.compose_body_bytes - bytes.items.len) return error.BodyTooLarge;
        try bytes.appendSlice(a, "> ");
        try bytes.appendSlice(a, line);
        try bytes.append(a, '\n');
    }
    return bytes.items;
}
/// "On <date>, <name> <address> wrote:" above a text quote. The sender's own
/// Date header is used as written; otherwise the received instant in UTC.
/// Header text is flattened to one bounded line before it enters the body.
pub fn attribution(a: std.mem.Allocator, message: t.Message, format: t.BodyFormat) ![]const u8 {
    var date_buffer: [40]u8 = undefined;
    // Cached records are not re-validated: keep the conversion inside the
    // range the shared decoder accepts, and never print an empty date.
    const sent_text = std.mem.trim(u8, message.sentDate orelse "", " \t\r\n");
    const date: []const u8 = if (sent_text.len != 0) sent_text else if (message.receivedAt > 0 and message.receivedAt <= mime.max_received_at_ms) blk: {
        const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(message.receivedAt, 1000)) };
        const day = seconds.getEpochDay().calculateYearDay();
        const month = day.calculateMonthDay();
        const clock = seconds.getDaySeconds();
        break :blk try std.fmt.bufPrint(&date_buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ day.year, month.month.numeric(), month.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour() });
    } else "an earlier date";
    const name = oneLine(message.from.name, 256);
    const address = oneLine(message.from.address, 320);
    const who = if (name.len > 0 and address.len > 0)
        try std.fmt.allocPrint(a, "{s} <{s}>", .{ name, address })
    else if (name.len > 0) name else address;
    const raw = try std.fmt.allocPrint(a, "On {s}, {s} wrote:", .{ oneLine(date, 64), who });
    const line = try a.dupe(u8, raw);
    for (line) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
        byte.* = ' ';
    };
    return if (format == .markdown) markdown.escapeSource(a, line) else line;
}
fn oneLine(text: []const u8, limit: usize) []const u8 {
    var end = @min(std.mem.indexOfAny(u8, text, "\r\n") orelse text.len, limit);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return std.mem.trim(u8, text[0..end], " \t");
}
/// Where the quoted original starts in a draft body: before its attribution
/// line, or before the first "> " line of an older draft without one.
pub fn quoteStart(body: []const u8) ?usize {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, body, search, "\n\nOn ")) |at| : (search = at + 2) {
        const line_end = std.mem.indexOfScalarPos(u8, body, at + 2, '\n') orelse break;
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, body[at + 2 .. line_end], "\r"), "wrote:") and std.mem.startsWith(u8, body[line_end + 1 ..], "> ")) return at;
    }
    return std.mem.indexOf(u8, body, "\n\n> ");
}
fn attributedQuote(a: std.mem.Allocator, line: []const u8, body: []const u8) ![]const u8 {
    const quoted = try quote(a, body);
    if (line.len + 1 > t.Limits.compose_body_bytes - quoted.len) return error.BodyTooLarge;
    return std.fmt.allocPrint(a, "\n\n{s}\n{s}", .{ line, quoted[2..] });
}
pub fn reply(a: std.mem.Allocator, message: t.Message, options: ReplyOptions) !t.Draft {
    try requireBody(message);
    // A display-only fallback never supplies an implicit outgoing recipient.
    if (message.decodeWarning.len > 0 and message.from.address.len == 0) return error.UnsafeReplyMetadata;
    const threading = try mime.threading(message.messageId, message.references, message.inReplyTo, a);
    const envelope = try recipients.replyAddresses(a, options.account, options.aliases, message.from, message.replyTo, message.to, message.cc, options.all);
    errdefer envelope.deinit(a);
    return .{
        .to = envelope.to,
        .cc = envelope.cc,
        .subject = try prefixedSubject(a, message.subject, "Re:"),
        .bodyText = if (options.original != null) "" else try attributedQuote(a, try attribution(a, message, options.format), if (options.format == .markdown) try markdown.escapeSource(a, message.bodyText) else message.bodyText),
        .bodyFormat = options.format,
        .threadId = message.threadId,
        .inReplyTo = threading.in_reply_to,
        .references = threading.references,
        .original = options.original,
    };
}
pub fn forward(a: std.mem.Allocator, message: t.Message, options: ForwardOptions) !t.Draft {
    try requireBody(message);
    var draft: t.Draft = .{
        .subject = try prefixedSubject(a, message.subject, "Fwd:"),
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
fn prefixedSubject(a: std.mem.Allocator, subject: []const u8, prefix: []const u8) ![]const u8 {
    if (subject.len > mail_limits.subject_bytes) return error.HeaderTooLarge;
    if (std.ascii.startsWithIgnoreCase(subject, prefix)) return subject;
    if (prefix.len + 1 > mail_limits.subject_bytes - subject.len) return error.HeaderTooLarge;
    return std.fmt.allocPrint(a, "{s} {s}", .{ prefix, subject });
}
fn appendSpan(a: std.mem.Allocator, out: *std.ArrayList(u8), span: @import("html_document.zig").Span) !void {
    try out.appendSlice(a, span.text);
    if (span.link) |target| if (@import("reader_tools.zig").safeUrl(target) and !std.mem.eql(u8, target, span.text)) {
        try out.appendSlice(a, " (");
        try out.appendSlice(a, target);
        try out.append(a, ')');
    };
    if (out.items.len > t.Limits.compose_body_bytes) return error.BodyTooLarge;
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
        if (out.items.len > t.Limits.compose_body_bytes) return error.BodyTooLarge;
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
    try std.testing.expectEqualStrings("\n\nOn an earlier date, Sender <sender@example.test> wrote:\n> Line one\n> Line two\n", draft.bodyText);
    try std.testing.expectEqualStrings("thread", draft.threadId);
    try std.testing.expectEqualStrings("<source@example.test>", draft.inReplyTo);
    try std.testing.expectEqualStrings("<prior@example.test> <source@example.test>", draft.references);
}
test "conversation draft: reply quote names its sender and date above readable quoted text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const message: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "alex@example.test", .name = "Alex *Fixture*" }, .subject = "Plans", .bodyText = "See you at 5. Bring (fictional) snacks!\n# not a heading\n- not a list", .messageId = "<source@example.test>", .sentDate = "Sat, 7 Nov 2026 09:00:00 +0000" };
    const plain = try reply(a, message, .{ .account = "self@example.test" });
    try std.testing.expectEqualStrings("\n\nOn Sat, 7 Nov 2026 09:00:00 +0000, Alex *Fixture* <alex@example.test> wrote:\n> See you at 5. Bring (fictional) snacks!\n> # not a heading\n> - not a list\n", plain.bodyText);
    const markdown_draft = try reply(a, message, .{ .account = "self@example.test", .format = .markdown });
    // Quoted source is escaped in full: nothing a sender wrote, including a
    // display name, can become markup in the outgoing reply.
    try std.testing.expectEqualStrings("\n\nOn Sat, 7 Nov 2026 09:00:00 \\+0000, Alex \\*Fixture\\* \\<alex@example\\.test\\> wrote:\n> See you at 5\\. Bring \\(fictional\\) snacks\\!\n> \\# not a heading\n> \\- not a list\n", markdown_draft.bodyText);
    const rendered = try markdown.render(a, markdown_draft.bodyText);
    try std.testing.expect(std.mem.indexOf(u8, rendered.plain, "On Sat, 7 Nov 2026 09:00:00 +0000, Alex *Fixture* <alex@example.test> wrote:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.plain, "> # not a heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "<em>") == null and std.mem.indexOf(u8, rendered.html, "<h1") == null and std.mem.indexOf(u8, rendered.html, "<li") == null);
    // The reader folds the attribution with its quote; signatures insert above it.
    const folded = try @import("reader_tools.zig").fold(a, plain.bodyText, true, false);
    try std.testing.expect(std.mem.indexOf(u8, folded.text, "wrote:") == null and std.mem.indexOf(u8, folded.text, "Bring") == null);
    try std.testing.expectEqual(@as(?usize, 0), quoteStart(plain.bodyText));
    try std.testing.expectEqual(@as(?usize, 4), quoteStart("Note\n\n> Older draft quote\n"));
    try std.testing.expectEqual(@as(?usize, null), quoteStart("On Monday we met.\nNo quote here"));
    // Without a Date header the received instant is shown in UTC; header
    // text never adds lines to the body.
    const received: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "line@example.test", .name = "Two\nLines" }, .bodyText = "Body", .receivedAt = 1794047760000 };
    try std.testing.expectEqualStrings("On 2026-11-07 10:36 UTC, Two <line@example.test> wrote:", try attribution(a, received, .plain));
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

test "mail metadata: reply and forward retain full subjects with prefix headroom" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subject: [mail_limits.subject_text_bytes]u8 = @splat('s');
    const message: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "sender@example.test" }, .to = &.{.{ .address = "self@example.test" }}, .subject = &subject, .bodyText = "Body", .messageId = "<source@example.test>" };
    const reply_draft = try reply(a, message, .{ .account = "self@example.test" });
    try std.testing.expectEqualStrings(&subject, reply_draft.subject["Re: ".len..]);
    try @import("draft_codec.zig").validateDraft(reply_draft, true);
    const forward_draft = try forward(a, message, .{});
    try std.testing.expectEqualStrings(&subject, forward_draft.subject["Fwd: ".len..]);
    try @import("draft_codec.zig").validateDraft(forward_draft, false);
    const limit: [mail_limits.subject_bytes]u8 = @splat('s');
    try std.testing.expectError(error.HeaderTooLarge, prefixedSubject(a, &limit, "Re:"));
}

test "conversation draft: display-only metadata never supplies reply destinations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const message: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "", .name = "Display-only sender" }, .replyTo = &.{.{ .address = "untrusted@example.test" }}, .subject = "Readable source", .bodyText = "Body", .messageId = "<source@example.test>", .decodeWarning = "InvalidRecipients" };
    try std.testing.expectError(error.UnsafeReplyMetadata, reply(arena.allocator(), message, .{ .account = "self@example.test" }));
    const draft = try forward(arena.allocator(), message, .{});
    try std.testing.expectEqual(@as(usize, 0), draft.to.len);
    try std.testing.expectEqual(@as(usize, 0), draft.cc.len);
    try std.testing.expectEqual(@as(usize, 0), draft.bcc.len);
    try std.testing.expect(std.mem.indexOf(u8, draft.bodyText, "Body") != null);
}

test "message isolation: body refusals block reply all and forwards before destination derivation" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    const message: t.Message = .{ .id = "refused", .threadId = "thread", .from = .{ .address = "sender@example.test" }, .replyTo = &.{.{ .address = "actual-reply@example.test" }}, .to = &.{.{ .address = "self@example.test" }}, .cc = &.{.{ .address = "peer@example.test" }}, .subject = "Unavailable source", .bodyCacheError = "UnsupportedCharset", .decodeWarning = "UnsupportedCharset" };
    for ([_]bool{ false, true }) |all| {
        try std.testing.expectError(error.MessageBodyUnavailable, reply(a, message, .{ .account = "self@example.test", .all = all }));
        try std.testing.expectError(error.MessageBodyUnavailable, reply(a, message, .{ .account = "self@example.test", .all = all, .original = .{ .sourceMessageId = message.id, .bodyHtml = "<p>Stale source</p>" } }));
    }
    try std.testing.expectError(error.MessageBodyUnavailable, forward(a, message, .{}));
    try std.testing.expectError(error.MessageBodyUnavailable, forward(a, message, .{ .body_text = "Stale source", .omitted_attachments = 3 }));
    try std.testing.expectError(error.MessageBodyUnavailable, forward(a, message, .{ .original = .{ .sourceMessageId = message.id, .bodyHtml = "<p>Stale source</p>" } }));
}

test "parser leniency: an incomplete readable source is never quoted or forwarded as complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var message: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "sender@example.test" }, .to = &.{.{ .address = "self@example.test" }}, .subject = "Readable", .bodyText = "Shown part", .messageId = "<source@example.test>" };
    _ = try reply(a, message, .{ .account = "self@example.test" });
    for ([_][]const u8{ "BodySizeMismatch", "ContentTruncated" }) |warning| {
        message.decodeWarning = warning;
        try std.testing.expectError(error.MessageBodyUnavailable, reply(a, message, .{ .account = "self@example.test" }));
    }
    // Replacement characters are visible in the quote the author reviews.
    message.decodeWarning = "UnsupportedCharset";
    _ = try reply(a, message, .{ .account = "self@example.test" });
}
