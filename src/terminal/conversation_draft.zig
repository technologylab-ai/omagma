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
pub const forward_header = "---------- Forwarded message ----------";
/// Where the quoted original starts in a draft body: before its attribution
/// line, or before the first "> " line of an older draft without one. Only
/// text above a plain forward's own header counts: the forwarded message may
/// itself contain an "On … wrote:" line and quote, which belong to it.
pub fn quoteStart(body: []const u8) ?usize {
    const own = body[0 .. std.mem.indexOf(u8, body, "\n\n" ++ forward_header) orelse body.len];
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, own, search, "\n\nOn ")) |at| : (search = at + 2) {
        const line_end = std.mem.indexOfScalarPos(u8, own, at + 2, '\n') orelse break;
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, own[at + 2 .. line_end], "\r"), "wrote:") and std.mem.startsWith(u8, own[line_end + 1 ..], "> ")) return at;
    }
    return std.mem.indexOf(u8, own, "\n\n> ");
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
        .bodyText = if (options.original != null) "" else try attributedQuote(a, try attribution(a, message, options.format), if (options.format == .markdown) try markdown.escapeQuoted(a, message.bodyText) else message.bodyText),
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
        const original = try std.fmt.allocPrint(a, forward_header ++ "\nFrom: {s} <{s}>\nSubject: {s}\n\n{s}", .{ message.from.name, message.from.address, message.subject, options.body_text orelse message.bodyText });
        draft.bodyText = if (options.format == .markdown) try quote(a, try markdown.escapeQuoted(a, original)) else try std.fmt.allocPrint(a, "\n\n{s}", .{original});
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
    // Nothing a sender wrote can become markup in the outgoing reply. The
    // attribution (with its display name) is escaped in full; the quote only
    // where the renderer would otherwise give a character meaning.
    try std.testing.expectEqualStrings("\n\nOn Sat, 7 Nov 2026 09:00:00 \\+0000, Alex \\*Fixture\\* \\<alex@example\\.test\\> wrote:\n> See you at 5. Bring (fictional) snacks!\n> \\# not a heading\n> \\- not a list\n", markdown_draft.bodyText);
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
    // A plain forward of a reply: the forwarded body's own attribution and
    // quote belong to the forwarded message, so a signature goes above the
    // forward header instead.
    const replied: t.Message = .{ .id = "source", .threadId = "thread", .from = .{ .address = "sam@example.test", .name = "Sam" }, .subject = "Re: Plans", .bodyText = "Sounds good.\n\nOn Fri, 6 Nov 2026, Alex <alex@example.test> wrote:\n> See you at 5.\n", .messageId = "<reply@example.test>" };
    for ([_]t.BodyFormat{ .plain, .markdown }) |format| {
        const forwarded = try forward(a, replied, .{ .format = format });
        const note = try std.fmt.allocPrint(a, "FYI below{s}", .{forwarded.bodyText});
        const at = quoteStart(note) orelse std.mem.indexOf(u8, note, "\n\n" ++ forward_header).?;
        try std.testing.expectEqual(@as(usize, "FYI below".len), at);
    }
    // A reply's own attribution still wins over a quote in the author's note.
    try std.testing.expectEqual(@as(?usize, 12), quoteStart("Note\n\n> mine\n\nOn Mon, A <author@example.test> wrote:\n> theirs\n"));
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

/// Minimal quote escaping must render byte-for-byte like full escaping.
fn expectQuoteEquivalent(a: std.mem.Allocator, source: []const u8) !void {
    const expected = markdown.render(a, try quote(a, try markdown.escapeSource(a, source)));
    const minimal = try markdown.escapeQuoted(a, source);
    const actual = markdown.render(a, try quote(a, minimal));
    if (expected) |full| {
        const got = actual catch |err| {
            std.debug.print("minimal quote escaping failed with {t} for {f}\n", .{ err, std.zig.fmtString(source) });
            return err;
        };
        if (!std.mem.eql(u8, full.html, got.html) or !std.mem.eql(u8, full.plain, got.plain)) {
            std.debug.print("quote escaping mismatch for {f}\nminimal: {f}\nfull plain: {f}\nminimal plain: {f}\n", .{ std.zig.fmtString(source), std.zig.fmtString(minimal), std.zig.fmtString(full.plain), std.zig.fmtString(got.plain) });
            return error.TestExpectedEqual;
        }
    } else |err| try std.testing.expectError(err, actual);
}

test "quote escaping: minimal escaping renders exactly like full escaping for random and exhaustive hostile text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const symbols = [_][]const u8{ "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "~", "|", "<", ">", "=", " ", " ", " ", "\t", "\r", "\n", "\n", "\r\n", "&", "http://", "https://", "www.", "@", ":", "/", "'", "\"", "a", "b", "Z", "word", "5", "1", "12", "é", "€", "😀", "mailto:", "(http://", "x.y", "cid:", "![", "](", "==", "---", "***", "```", "~~~", "~~", "__", "**", "1.", "2)", "\\\\", "| ", "|---|", ":---", " | x |" };
    var prng = std.Random.DefaultPrng.init(0x6f6d61676d61);
    const random = prng.random();
    var buffer: [80]u8 = undefined;
    var cases: usize = 0;
    while (cases < 200_000) : (cases += 1) {
        _ = arena.reset(.retain_capacity);
        const target = random.intRangeAtMost(usize, 1, buffer.len);
        var len: usize = 0;
        while (true) {
            const symbol = symbols[random.uintLessThan(usize, symbols.len)];
            if (len + symbol.len > target) break;
            @memcpy(buffer[len..][0..symbol.len], symbol);
            len += symbol.len;
        }
        if (len == 0) {
            buffer[0] = '_';
            len = 1;
        }
        try expectQuoteEquivalent(arena.allocator(), buffer[0..len]);
    }
    // Every string of up to four symbols over three 12-symbol hostile alphabets.
    const alphabets = [_][12][]const u8{
        .{ "_", "*", "\\", "#", "-", "1", ".", " ", "\n", "a", "~", "=" },
        .{ "<", ">", "[", "]", "(", ")", "!", "|", "`", "+", "\t", "\r" },
        .{ "http://", "x", "(", ")", ".", "\\", "_", " ", "<", ">", "!", "\n" },
    };
    for (alphabets) |alphabet| {
        for (1..5) |length| {
            var digits: [4]usize = @splat(0);
            while (true) {
                _ = arena.reset(.retain_capacity);
                var text: std.ArrayList(u8) = .empty;
                for (digits[0..length]) |digit| try text.appendSlice(arena.allocator(), alphabet[digit]);
                try expectQuoteEquivalent(arena.allocator(), text.items);
                cases += 1;
                var position: usize = 0;
                while (position < length) : (position += 1) {
                    digits[position] += 1;
                    if (digits[position] < alphabet.len) break;
                    digits[position] = 0;
                }
                if (position == length) break;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 200_000 + 3 * (12 + 144 + 1728 + 20736)), cases);
}

test "quote escaping: review cases stay literal, readable and linear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "Set APP__DB_HOST and FOO__BAR_BAZ before deploy",
        "a___b___c",
        "a__b _foo",
        "snake__case_x",
        "Receipt\n\n==========\nTotal 5",
        "Title\n=====",
        "x\n=",
        "Saved to C:\\Users\\Alex\\\nnext line",
        "Saved to C:\\Users\\Alex\\   \nnext line",
        "Saved to C:\\Users\\Alex\\\r\nnext line\r\n",
        "path C:\\dir\\ \nnext",
        "\rLine after a bare CR\r\n# heading?\r\n- list?\r\n1. ordered?\r\n> nested?",
        "Ticket #\n===",
        "Ticket ##  \n===",
        "C#\n===",
        "1) one\n2. two\n10.5 percent\n3.\n(http://example.test/a_b) and http://localhost:8080/x",
        "See https://example.test/path_(x)! or <https://example.test> and [label](https://example.test)",
        "~approx~ and ~~struck~~ and ~~~ fence",
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "*emph* _emph_ **strong** `code` ```",
    };
    for (cases) |source| try expectQuoteEquivalent(a, source);
    try std.testing.expectEqualStrings("Set APP_\\_DB_HOST and FOO_\\_BAR_BAZ before deploy", try markdown.escapeQuoted(a, cases[0]));
    try std.testing.expectEqualStrings("Saved to C:\\Users\\Alex\\\\\nnext line", try markdown.escapeQuoted(a, cases[7]));
    try std.testing.expectEqualStrings("See you at 5. Bring (fictional) snacks!", try markdown.escapeQuoted(a, "See you at 5. Bring (fictional) snacks!"));
    // `=` underlines are left exactly as full escaping leaves them, so they
    // never gain a visible backslash.
    try std.testing.expectEqualStrings("Receipt\n\n==========\nTotal 5", try markdown.escapeQuoted(a, cases[4]));

    // Large lines: `<` is always escaped, so rendering never searches for an
    // autolink end (the renderer's search budget is linear in the source and
    // would fail otherwise), and the escaper examines a bounded number of
    // bytes per input byte.
    var spaced: std.ArrayList(u8) = .empty;
    while (spaced.items.len < 100 * 1024) try spaced.appendSlice(a, "<aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const only_angles = try a.alloc(u8, 1024 * 1024);
    @memset(only_angles, '<');
    var mixed: std.ArrayList(u8) = .empty;
    while (mixed.items.len < 512 * 1024) try mixed.appendSlice(a, "a_b __ # \\ http://x.test/_ ~ 1. > |\r\n");
    for ([_][]const u8{ spaced.items, only_angles, mixed.items }) |source| {
        var work: usize = 0;
        const minimal = try markdown.escapeQuotedCounted(a, source, &work);
        try std.testing.expect(work <= 6 * source.len + 16);
        const rendered = try markdown.render(a, try quote(a, minimal));
        const full = try markdown.render(a, try quote(a, try markdown.escapeSource(a, source)));
        try std.testing.expectEqualStrings(full.html, rendered.html);
        try std.testing.expectEqualStrings(full.plain, rendered.plain);
    }
}
