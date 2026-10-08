//! Native, bounded Markdown for outgoing mail. The editable source stays in
//! Draft.bodyText. HTML and semantic plain text are regenerated together for
//! both review and sending; raw HTML is escaped and images never fetch resources.
const std = @import("std");
const t = @import("types.zig");
const highlight = @import("markdown_highlight.zig");
const original_mail = @import("original_mail.zig");
pub const max_lines = 32768;
pub const max_depth = 12;
pub const max_table_columns = 32;
pub const logo_content_id = "omagma-logo@omagma.invalid";
pub const Rendered = struct { plain: []const u8, html: []const u8, logoOffset: usize };
pub const Prepared = struct { plain: []const u8, html: ?[]const u8 = null, logoOffset: ?usize = null, resources: []const t.Attachment = &.{} };
pub fn prepare(a: std.mem.Allocator, draft: t.Draft) !Prepared {
    const source = if (draft.recoveryFields) |fields| fields[4] else draft.bodyText;
    if (draft.original) |original| {
        const note = try renderNote(a, source, draft.bodyFormat);
        defer a.free(note.plain);
        defer a.free(note.html);
        const assembled = try original_mail.prepare(a, .{ .html = note.html, .plain = note.plain, .logoOffset = note.logoOffset }, original);
        return .{ .plain = assembled.plain, .html = assembled.html, .logoOffset = assembled.logoOffset, .resources = assembled.resources };
    }
    if (draft.bodyFormat == .plain) return .{ .plain = source };
    const rendered = try render(a, source);
    return .{ .plain = rendered.plain, .html = rendered.html, .logoOffset = rendered.logoOffset };
}

const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn append(self: *Buffer, bytes: []const u8) !void {
        if (bytes.len > t.Limits.body_bytes - self.bytes.items.len) return error.RenderedBodyTooLarge;
        try self.bytes.appendSlice(self.allocator, bytes);
    }
    fn escaped(self: *Buffer, bytes: []const u8) !void {
        var start: usize = 0;
        for (bytes, 0..) |c, i| {
            const replacement: ?[]const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => null,
            };
            if (replacement) |text| {
                try self.append(bytes[start..i]);
                try self.append(text);
                start = i + 1;
            }
        }
        try self.append(bytes[start..]);
    }
    fn newline(self: *Buffer, count: usize) !void {
        var existing: usize = 0;
        var i = self.bytes.items.len;
        while (i > 0 and self.bytes.items[i - 1] == '\n') : (i -= 1) existing += 1;
        while (existing < count) : (existing += 1) try self.append("\n");
    }
};
const Line = struct { text: []const u8 };
const Marker = struct { indent: usize, content: usize, content_width: usize, ordered: bool, number: usize = 1 };
const Item = struct { lines: std.ArrayList(Line) = .empty, content_indent: usize };
const Context = struct {
    a: std.mem.Allocator,
    html: Buffer,
    plain: Buffer,
    search_budget: usize,
    blocks_left: usize = max_lines * 4,
    suppress_plain: bool = false,

    fn literalText(self: *Context, bytes: []const u8) !void {
        try self.html.escaped(bytes);
        if (!self.suppress_plain) try self.plain.append(bytes);
    }
    fn plainAppend(self: *Context, bytes: []const u8) !void {
        if (!self.suppress_plain) try self.plain.append(bytes);
    }
    fn plainBreak(self: *Context, count: usize) !void {
        if (!self.suppress_plain) try self.plain.newline(count);
    }
    fn search(self: *Context, text: []const u8, needle: []const u8) !?usize {
        if (text.len > self.search_budget) return error.MarkdownTooComplex;
        self.search_budget -= text.len;
        return std.mem.indexOf(u8, text, needle);
    }
    fn inlineText(self: *Context, text: []const u8, depth: usize, links: bool) anyerror!void {
        if (depth > max_depth) return error.MarkdownTooDeep;
        var i: usize = 0;
        var literal: usize = 0;
        while (i < text.len) {
            const rest = text[i..];
            if (rest[0] == '\\' and rest.len > 1 and std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!~|<>", rest[1]) != null) {
                try self.literalText(text[literal..i]);
                try self.literalText(rest[1..2]);
                i += 2;
                literal = i;
                continue;
            }
            if (rest[0] == '`') code: {
                var n: usize = 1;
                while (n < rest.len and rest[n] == '`') n += 1;
                const end = (try self.search(rest[n..], rest[0..n])) orelse break :code;
                try self.literalText(text[literal..i]);
                try self.html.append("<code style=\"font-family:Consolas,Menlo,monospace;font-size:0.9em;background:#f4f4f5;color:#a3410d;padding:2px 5px;border-radius:3px\">");
                var body = rest[n .. n + end];
                if (body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ' and std.mem.trim(u8, body, " ").len != 0) body = body[1 .. body.len - 1];
                try self.literalText(body);
                try self.html.append("</code>");
                i += n + end + n;
                literal = i;
                continue;
            }
            if (links and (rest[0] == '[' or std.mem.startsWith(u8, rest, "!["))) link: {
                const image = rest[0] == '!';
                const label_start: usize = if (image) 2 else 1;
                const close_off = (try self.search(rest[label_start..], "]")) orelse break :link;
                const close = label_start + close_off;
                if (close + 1 >= rest.len or rest[close + 1] != '(') break :link;
                const target = (try linkTarget(self, rest, close + 2)) orelse break :link;
                try self.literalText(text[literal..i]);
                const safe = safeUrl(target.url);
                if (safe) {
                    try self.html.append("<a style=\"color:#b84a10;text-decoration:underline\" href=\"");
                    try self.html.escaped(target.url);
                    try self.html.append("\">");
                }
                if (image) try self.literalText("[image: ");
                try self.inlineText(rest[label_start..close], depth + 1, false);
                if (image) try self.literalText("]");
                if (safe) {
                    try self.html.append("</a>");
                    if (!std.mem.eql(u8, rest[label_start..close], target.url)) {
                        try self.plainAppend(" (");
                        try self.plainAppend(target.url);
                        try self.plainAppend(")");
                    }
                }
                i += target.end;
                literal = i;
                continue;
            }
            if (links and rest[0] == '<') autolink: {
                const end = (try self.search(rest[1..], ">")) orelse break :autolink;
                const url = rest[1 .. 1 + end];
                if (!safeUrl(url)) break :autolink;
                try self.literalText(text[literal..i]);
                try self.html.append("<a style=\"color:#b84a10;text-decoration:underline\" href=\"");
                try self.html.escaped(url);
                try self.html.append("\">");
                try self.literalText(url);
                try self.html.append("</a>");
                i += end + 2;
                literal = i;
                continue;
            }
            if (links and (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://")) and (i == 0 or std.ascii.isWhitespace(text[i - 1]) or text[i - 1] == '(')) bare_url: {
                var end: usize = 0;
                while (end < rest.len and !std.ascii.isWhitespace(rest[end]) and rest[end] != '<' and rest[end] != '>') end += 1;
                while (end > 0 and std.mem.indexOfScalar(u8, ".,;:!?'\"", rest[end - 1]) != null) end -= 1;
                if (end > 0 and rest[end - 1] == ')' and std.mem.indexOfScalar(u8, rest[0 .. end - 1], '(') == null) end -= 1;
                const url = rest[0..end];
                if (!safeUrl(url)) break :bare_url;
                try self.literalText(text[literal..i]);
                try self.html.append("<a style=\"color:#b84a10;text-decoration:underline\" href=\"");
                try self.html.escaped(url);
                try self.html.append("\">");
                try self.literalText(url);
                try self.html.append("</a>");
                i += end;
                literal = i;
                continue;
            }
            if (rest[0] == '*' or rest[0] == '_' or std.mem.startsWith(u8, rest, "~~")) emphasis: {
                if (rest[0] == '_' and i > 0 and wordByte(text[i - 1])) break :emphasis;
                const n: usize = if (rest[0] != '~' and rest.len > 2 and rest[0] == rest[1] and rest[1] == rest[2]) 3 else if (rest.len > 1 and rest[0] == rest[1]) 2 else 1;
                if (rest[0] == '~' and n != 2) break :emphasis;
                if (n >= rest.len or std.ascii.isWhitespace(rest[n])) break :emphasis;
                const end = (try self.search(rest[n..], rest[0..n])) orelse break :emphasis;
                if (end == 0 or std.ascii.isWhitespace(rest[n + end - 1])) break :emphasis;
                const tag: []const u8 = if (rest[0] == '~') "del" else if (n >= 2) "strong" else "em";
                try self.literalText(text[literal..i]);
                try self.html.append("<");
                try self.html.append(tag);
                try self.html.append(">");
                if (n == 3) try self.html.append("<em>");
                try self.inlineText(rest[n .. n + end], depth + 1, links);
                if (n == 3) try self.html.append("</em>");
                try self.html.append("</");
                try self.html.append(tag);
                try self.html.append(">");
                i += n + end + n;
                literal = i;
                continue;
            }
            i += 1;
        }
        try self.literalText(text[literal..]);
    }

    fn blocks(self: *Context, lines: []const Line, depth: usize, tight: bool, in_list: bool) anyerror!void {
        if (depth > max_depth) return error.MarkdownTooDeep;
        var i: usize = 0;
        while (i < lines.len) {
            if (self.blocks_left == 0) return error.MarkdownTooComplex;
            self.blocks_left -= 1;
            const text = trim(lines[i].text);
            if (text.len == 0) {
                i += 1;
                continue;
            }
            if (fence(text)) |opening| {
                var end = i + 1;
                while (end < lines.len and !closingFence(trim(lines[end].text), opening)) end += 1;
                const language = std.mem.trim(u8, text[opening.len..], " \t");
                try self.html.append("<div style=\"margin:0 0 16px;background:#f4f4f5;border:1px solid #e4e4e7;border-radius:6px;padding:12px 14px\">");
                if (language.len > 0) {
                    try self.html.append("<div style=\"font-family:Arial,sans-serif;font-size:11px;line-height:1.4;color:#71717a;margin:0 0 8px\">");
                    try self.html.escaped(language);
                    try self.html.append("</div>");
                }
                try self.html.append("<pre style=\"margin:0;white-space:pre-wrap;overflow-wrap:anywhere;font-family:Consolas,Menlo,monospace;font-size:13px;line-height:1.6;color:#262626\"><code>");
                var code: Buffer = .{ .allocator = self.a };
                defer code.bytes.deinit(self.a);
                for (lines[i + 1 .. end], 0..) |line, index| {
                    if (index != 0) try code.append("\n");
                    try code.append(line.text);
                }
                var lexer: highlight.Lexer = .{ .source = code.bytes.items, .language = language };
                var span_count: usize = 0;
                while (lexer.next()) |token| {
                    const colour: ?[]const u8 = if (span_count >= 4096 or code.bytes.items.len > 128 * 1024) null else switch (token.kind) {
                        .keyword => "#b84a10",
                        .string => "#316a40",
                        .comment => "#71717a",
                        .number => "#7953a2",
                        .literal => null,
                    };
                    if (colour) |value| {
                        try self.html.append("<span class=\"omagma-syntax-");
                        try self.html.append(@tagName(token.kind));
                        try self.html.append("\" style=\"color:");
                        try self.html.append(value);
                        try self.html.append("\">");
                        span_count += 1;
                    }
                    try self.html.escaped(token.text);
                    if (colour != null) try self.html.append("</span>");
                }
                try self.plainAppend(code.bytes.items);
                try self.plainBreak(if (in_list) 1 else 2);
                try self.html.append("</code></pre></div>\n");
                i = if (end < lines.len) end + 1 else end;
                continue;
            }
            if (heading(text)) |level| {
                try self.headingText(text[level + 1 ..], level);
                i += 1;
                continue;
            }
            if (rule(text)) {
                try self.html.append("<hr style=\"border:0;border-top:1px solid #e4e4e7;margin:20px 0\">\n");
                try self.plainAppend("---");
                try self.plainBreak(2);
                i += 1;
                continue;
            }
            if (text[0] == '>') {
                var quoted: std.ArrayList(Line) = .empty;
                defer quoted.deinit(self.a);
                while (i < lines.len) : (i += 1) {
                    const q = trim(lines[i].text);
                    if (q.len == 0 or q[0] != '>') break;
                    const body = if (q.len > 1 and q[1] == ' ') q[2..] else q[1..];
                    try quoted.append(self.a, .{ .text = body });
                }
                try self.html.append("<blockquote style=\"margin:0 0 16px;padding:2px 0 2px 16px;border-left:3px solid #b84a10;color:#71717a\">");
                const quoted_plain = try self.quoteBlocks(quoted.items, depth);
                defer self.a.free(quoted_plain);
                var plain_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, quoted_plain, "\n"), '\n');
                while (plain_lines.next()) |line| {
                    try self.plainAppend("> ");
                    try self.plainAppend(line);
                    try self.plainBreak(1);
                }
                try self.plainBreak(if (in_list) 1 else 2);
                try self.html.append("</blockquote>\n");
                continue;
            }
            if (marker(lines[i].text) != null) {
                i = try self.list(lines, i, depth, in_list);
                continue;
            }
            if (i + 1 < lines.len and hasPipe(text) and tableSeparator(trim(lines[i + 1].text))) {
                i = try self.table(lines, i);
                continue;
            }
            var end = i + 1;
            var setext: usize = 0;
            while (end < lines.len and trim(lines[end].text).len != 0) : (end += 1) {
                if (setextLevel(trim(lines[end].text))) |level| {
                    setext = level;
                    break;
                }
                if (startsBlock(lines, end)) break;
            }
            if (setext != 0) {
                try self.headingText(text, setext);
                // Multiline setext text is uncommon; preserve every line.
                for (lines[i + 1 .. end]) |line| try self.headingText(trim(line.text), setext);
                i = end + 1;
                continue;
            }
            var last_paragraph = true;
            for (lines[end..]) |line| if (trim(line.text).len != 0) {
                last_paragraph = false;
                break;
            };
            if (!tight) try self.html.append(if (in_list) if (last_paragraph) "<p style=\"margin:0\">" else "<p style=\"margin:0 0 10px\">" else "<p style=\"margin:0 0 16px\">");
            for (lines[i..end], 0..) |line, index| {
                if (index != 0) {
                    try self.html.append("<br>\n");
                    try self.plainBreak(1);
                }
                var body = trim(line.text);
                if (index + 1 < end - i and body.len > 0 and body[body.len - 1] == '\\' and (body.len < 2 or body[body.len - 2] != '\\')) body = body[0 .. body.len - 1];
                try self.inlineText(body, 0, true);
            }
            if (!tight) try self.html.append("</p>\n");
            try self.plainBreak(if (in_list) 1 else 2);
            i = end;
        }
    }
    fn quoteBlocks(self: *Context, lines: []const Line, depth: usize) ![]u8 {
        const original_plain = self.plain;
        const original_suppression = self.suppress_plain;
        self.plain = .{ .allocator = self.a };
        self.suppress_plain = false;
        defer {
            self.plain.bytes.deinit(self.a);
            self.plain = original_plain;
            self.suppress_plain = original_suppression;
        }
        try self.blocks(lines, depth + 1, false, false);
        return self.a.dupe(u8, self.plain.bytes.items);
    }
    fn headingText(self: *Context, body: []const u8, level: usize) !void {
        const tag: [1]u8 = .{@as(u8, @intCast(level)) + '0'};
        try self.html.append("<h");
        try self.html.append(&tag);
        try self.html.append(" style=\"margin:24px 0 12px;color:#b84a10;font-weight:650;line-height:1.3;font-size:");
        try self.html.append(switch (level) {
            1 => "28",
            2 => "23",
            3 => "20",
            else => "17",
        });
        try self.html.append("px\">");
        var heading_body = std.mem.trimEnd(u8, body, " ");
        var hashes = heading_body.len;
        while (hashes > 0 and heading_body[hashes - 1] == '#') hashes -= 1;
        if (hashes > 0 and hashes < heading_body.len and heading_body[hashes - 1] == ' ') heading_body = std.mem.trimEnd(u8, heading_body[0..hashes], " ");
        try self.inlineText(heading_body, 0, true);
        try self.html.append("</h");
        try self.html.append(&tag);
        try self.html.append(">\n");
        try self.plainBreak(2);
    }
    fn list(self: *Context, lines: []const Line, start: usize, depth: usize, nested: bool) anyerror!usize {
        const first = marker(lines[start].text).?;
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |*item| item.lines.deinit(self.a);
            items.deinit(self.a);
        }
        var loose = false;
        var saw_blank = false;
        var i = start;
        while (i < lines.len) {
            const raw = lines[i].text;
            if (trim(raw).len == 0) {
                saw_blank = true;
                i += 1;
                continue;
            }
            const m = marker(raw);
            if (m != null and m.?.indent == first.indent and m.?.ordered == first.ordered) {
                if (saw_blank and items.items.len > 0) loose = true;
                saw_blank = false;
                var item: Item = .{ .content_indent = m.?.content_width };
                try item.lines.append(self.a, .{ .text = raw[m.?.content..] });
                try items.append(self.a, item);
                i += 1;
                continue;
            }
            if (items.items.len == 0) break;
            const item = &items.items[items.items.len - 1];
            const indentation = indent(raw);
            if (indentation >= @min(item.content_indent, first.indent + 2)) {
                if (saw_blank) {
                    try item.lines.append(self.a, .{ .text = "" });
                    loose = true;
                }
                saw_blank = false;
                try item.lines.append(self.a, .{ .text = raw[cutIndent(raw, item.content_indent)..] });
                i += 1;
                continue;
            }
            if (!saw_blank and !startsBlock(lines, i)) {
                try item.lines.append(self.a, lines[i]);
                i += 1;
                continue;
            }
            break;
        }
        while (i > start and trim(lines[i - 1].text).len == 0) i -= 1;
        const tag: []const u8 = if (first.ordered) "ol" else "ul";
        try self.html.append("<");
        try self.html.append(tag);
        if (first.ordered and first.number != 1) {
            var number: [24]u8 = undefined;
            try self.html.append(" start=\"");
            try self.html.append(try std.fmt.bufPrint(&number, "{d}", .{first.number}));
            try self.html.append("\"");
        }
        var number_buffer: [24]u8 = undefined;
        const digits = (try std.fmt.bufPrint(&number_buffer, "{d}", .{first.number})).len;
        const padding = (if (nested) @as(usize, 24) else @as(usize, 26)) + if (first.ordered and digits > 2) (digits - 2) * 9 else @as(usize, 0);
        try self.html.append(if (nested) " style=\"margin:4px 0 0;padding-left:" else " style=\"margin:0 0 16px;padding-left:");
        try self.html.append(try std.fmt.bufPrint(&number_buffer, "{d}", .{padding}));
        try self.html.append("px\">");
        for (items.items, 0..) |*item, index| {
            const last = index + 1 == items.items.len;
            try self.html.append(if (last) "<li style=\"margin:0;padding:0\">" else if (loose) "<li style=\"margin:0;padding:0 0 10px\">" else "<li style=\"margin:0;padding:0 0 4px\">");
            if (first.ordered) {
                var number: [24]u8 = undefined;
                try self.plainAppend(try std.fmt.bufPrint(&number, "{d}. ", .{first.number + index}));
            } else try self.plainAppend("- ");
            const body = item.lines.items[0].text;
            if (body.len >= 3 and body[0] == '[' and body[2] == ']' and (body[1] == ' ' or body[1] == 'x' or body[1] == 'X') and (body.len == 3 or std.ascii.isWhitespace(body[3]))) {
                try self.literalText(if (body[1] == ' ') "☐ " else "☑ ");
                item.lines.items[0].text = std.mem.trimStart(u8, body[3..], " \t");
            }
            try self.blocks(item.lines.items, depth + 1, !loose, true);
            try self.html.append("</li>");
        }
        try self.html.append("</");
        try self.html.append(tag);
        try self.html.append(">\n");
        try self.plainBreak(if (nested) 1 else 2);
        return i;
    }
    fn table(self: *Context, lines: []const Line, start: usize) !usize {
        var head: [max_table_columns][]const u8 = undefined;
        const columns = try cells(trim(lines[start].text), &head);
        var separators: [max_table_columns][]const u8 = undefined;
        if (try cells(trim(lines[start + 1].text), &separators) != columns) return error.InvalidMarkdownTable;
        try self.html.append("<table style=\"border-collapse:collapse;width:100%;margin:0 0 16px;font-size:14px\"><thead>");
        try self.tableRow(head[0..columns], separators[0..columns], true);
        try self.html.append("</thead><tbody>");
        var i = start + 2;
        while (i < lines.len and trim(lines[i].text).len != 0 and hasPipe(lines[i].text)) : (i += 1) {
            var row: [max_table_columns][]const u8 = @splat("");
            _ = try cells(trim(lines[i].text), &row);
            try self.tableRow(row[0..columns], separators[0..columns], false);
        }
        try self.html.append("</tbody></table>\n");
        try self.plainBreak(2);
        return i;
    }
    fn tableRow(self: *Context, values: []const []const u8, separators: []const []const u8, head: bool) !void {
        try self.html.append("<tr>");
        for (values, separators, 0..) |value, separator, index| {
            const tag: []const u8 = if (head) "th" else "td";
            try self.html.append("<");
            try self.html.append(tag);
            try self.html.append(if (head) " style=\"border:1px solid #e4e4e7;padding:9px 12px;background:#fff5eb;color:#a3410d;text-align:" else " style=\"border:1px solid #e4e4e7;padding:9px 12px;vertical-align:top;text-align:");
            try self.html.append(if (std.mem.endsWith(u8, separator, ":")) if (std.mem.startsWith(u8, separator, ":")) "center" else "right" else "left");
            try self.html.append("\">");
            if (index != 0) try self.plainAppend(" | ");
            try self.inlineText(value, 0, true);
            try self.html.append("</");
            try self.html.append(tag);
            try self.html.append(">");
        }
        try self.html.append("</tr>");
        try self.plainBreak(1);
    }
};

const document_prefix = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0;padding:0;background:#ffffff;color:#262626\">";
const note_prefix = "<div style=\"max-width:680px;margin:0 auto;padding:24px;font-family:-apple-system,BlinkMacSystemFont,&#39;Segoe UI&#39;,Arial,sans-serif;font-size:16px;line-height:1.65;overflow-wrap:anywhere\">";
const footer_prefix = "<div class=\"omagma-footer\" style=\"margin-top:24px;padding-top:14px;border-top:1px solid #e4e4e7;font-size:12px;line-height:1.5;color:#71717a\"><img src=\"cid:";
const footer_suffix = "\" width=\"16\" height=\"16\" alt=\"\" style=\"width:16px;height:16px;vertical-align:-3px;border:0;margin-right:5px\">Sent with <a class=\"omagma-footer-link\" href=\"https://technologylab-ai.github.io/omagma/\" style=\"color:#b84a10;text-decoration:underline\">omagma</a> 🌋</div></div>";

pub fn render(a: std.mem.Allocator, source: []const u8) !Rendered {
    return renderSource(a, source, .markdown, true);
}

/// Owns both returned strings. This is a trusted, generated fragment; received
/// HTML must never pass through protectNote or acquire generated-Markdown trust.
pub fn renderNote(a: std.mem.Allocator, source: []const u8, format: t.BodyFormat) !Rendered {
    const rendered = try renderSource(a, source, format, false);
    defer a.free(rendered.html);
    errdefer a.free(rendered.plain);
    const html = try protectNote(a, rendered.html);
    errdefer a.free(html);
    const logo_marker = "src=\"cid:" ++ logo_content_id ++ "\"";
    // Only our escaped renderer's output is searched. Original mail, including
    // older Omagma footers, is appended later and cannot influence this offset.
    const logo = std.mem.indexOf(u8, html, logo_marker) orelse return error.MissingLogoReference;
    return .{ .html = html, .plain = rendered.plain, .logoOffset = logo + "src=\"cid:".len };
}

fn renderSource(a: std.mem.Allocator, source: []const u8, format: t.BodyFormat, standalone: bool) !Rendered {
    if (source.len > t.Limits.body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    for (source) |c| if ((c < 0x20 and c != '\n' and c != '\r' and c != '\t') or c == 0x7f) return error.InvalidBody;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(a);
    if (format == .markdown) {
        var iterator = std.mem.splitScalar(u8, source, '\n');
        while (iterator.next()) |raw| {
            if (lines.items.len == max_lines) return error.MarkdownTooComplex;
            try lines.append(a, .{ .text = std.mem.trimEnd(u8, raw, "\r") });
        }
    }
    var context: Context = .{ .a = a, .html = .{ .allocator = a }, .plain = .{ .allocator = a }, .search_budget = @max(4096, source.len * 32) };
    errdefer context.html.bytes.deinit(a);
    errdefer context.plain.bytes.deinit(a);
    if (standalone) try context.html.append(document_prefix);
    try context.html.append(note_prefix);
    if (format == .markdown) {
        try context.blocks(lines.items, 0, false, false);
    } else {
        try context.html.append("<div style=\"white-space:pre-wrap;overflow-wrap:anywhere\">");
        try context.literalText(source);
        try context.html.append("</div>");
    }
    try context.html.append(footer_prefix);
    const logo_offset = context.html.bytes.items.len;
    try context.html.append(logo_content_id);
    try context.html.append(footer_suffix);
    if (standalone) try context.html.append("</body></html>");
    try context.plain.newline(2);
    try context.plain.append("Sent with omagma — https://technologylab-ai.github.io/omagma/ 🌋");
    const plain = try context.plain.bytes.toOwnedSlice(a);
    errdefer a.free(plain);
    return .{ .plain = plain, .html = try context.html.bytes.toOwnedSlice(a), .logoOffset = logo_offset };
}

/// Add local resets and important declarations only to generated tags. CSS in
/// the original document remains opaque. Email clients can still impose their
/// own styles; this prevents ordinary original selectors from restyling a note.
fn protectNote(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: Buffer = .{ .allocator = a };
    errdefer out.bytes.deinit(a);
    var offset: usize = 0;
    var first = true;
    var first_content = true;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |start| {
        try out.append(input[offset..start]);
        var end = start + 1;
        var quote: u8 = 0;
        while (end < input.len) : (end += 1) {
            const c = input[end];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') break;
        }
        if (end == input.len) return error.InvalidGeneratedHtml;
        end += 1;
        const tag = input[start..end];
        offset = end;
        if (tag.len < 3 or !std.ascii.isAlphabetic(tag[1])) {
            try out.append(tag);
            continue;
        }
        var name_end: usize = 1;
        while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
        const name = tag[1..name_end];
        // The generated root supplies the card's padding. Only a heading that
        // is its first content block needs its additional top margin removed.
        const leading_heading = !first and first_content and name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6';
        const style_at = std.mem.indexOf(u8, tag, " style=\"");
        try out.append(tag[0 .. style_at orelse name_end]);
        try out.append(" style=\"box-sizing:border-box!important;position:static!important;float:none!important;visibility:visible!important;opacity:1!important;max-width:100%!important;margin:0!important;padding:0!important;border:0!important;font-family:inherit!important;font-size:inherit!important;font-weight:inherit!important;font-style:inherit!important;line-height:inherit!important;color:inherit!important;letter-spacing:normal!important;text-transform:none!important;text-indent:0!important;");
        try out.append(if (first) "background:#ffffff!important;color:#262626!important;" else "background:transparent!important;");
        try out.append("display:");
        try out.append(displayFor(name));
        try out.append("!important;");
        if (std.mem.eql(u8, name, "strong")) try out.append("font-weight:bold!important;");
        if (std.mem.eql(u8, name, "em")) try out.append("font-style:italic!important;");
        if (std.mem.eql(u8, name, "del")) try out.append("text-decoration:line-through!important;");
        if (std.mem.eql(u8, name, "ul")) try out.append("list-style-type:disc!important;");
        if (std.mem.eql(u8, name, "ol")) try out.append("list-style-type:decimal!important;");
        if (style_at) |at| {
            const value_at = at + " style=\"".len;
            const close = std.mem.indexOfScalarPos(u8, tag, value_at, '"') orelse return error.InvalidGeneratedHtml;
            try importantStyles(&out, tag[value_at..close]);
            if (leading_heading) try out.append("margin-top:0!important;");
            try out.append(tag[close..]);
        } else {
            if (leading_heading) try out.append("margin-top:0!important;");
            try out.append("\"");
            try out.append(tag[name_end..]);
        }
        if (!first) first_content = false;
        first = false;
    }
    try out.append(input[offset..]);
    return out.bytes.toOwnedSlice(a);
}
fn displayFor(name: []const u8) []const u8 {
    for ([_][]const u8{ "a", "strong", "em", "del", "code", "span", "br" }) |inline_tag| if (std.mem.eql(u8, name, inline_tag)) return "inline";
    if (std.mem.eql(u8, name, "img")) return "inline-block";
    if (std.mem.eql(u8, name, "table")) return "table";
    if (std.mem.eql(u8, name, "thead")) return "table-header-group";
    if (std.mem.eql(u8, name, "tbody")) return "table-row-group";
    if (std.mem.eql(u8, name, "tr")) return "table-row";
    if (std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th")) return "table-cell";
    if (std.mem.eql(u8, name, "li")) return "list-item";
    return "block";
}
fn importantStyles(out: *Buffer, value: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= value.len) : (i += 1) {
        // Renderer-authored font names contain &#39;; its semicolon belongs to
        // an HTML entity, not to the surrounding CSS declaration.
        if (i < value.len and value[i] == '&') {
            i = std.mem.indexOfScalarPos(u8, value, i, ';') orelse return error.InvalidGeneratedHtml;
            continue;
        }
        if (i == value.len or value[i] == ';') {
            if (i > start) {
                try out.append(value[start..i]);
                try out.append("!important;");
            }
            start = i + 1;
        }
    }
}
/// Original mail is literal evidence, even when its lines happen to contain
/// Markdown metacharacters. Replies/forwards quote this escaped source.
pub fn escapeSource(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: Buffer = .{ .allocator = a };
    errdefer out.bytes.deinit(a);
    var start: usize = 0;
    for (source, 0..) |c, i| if (std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!~|<>", c) != null) {
        try out.append(source[start..i]);
        try out.append("\\");
        try out.append(source[i .. i + 1]);
        start = i + 1;
    };
    try out.append(source[start..]);
    return out.bytes.toOwnedSlice(a);
}
fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}
fn indent(text: []const u8) usize {
    var n: usize = 0;
    var width: usize = 0;
    while (n < text.len and (text[n] == ' ' or text[n] == '\t')) : (n += 1) width += if (text[n] == '\t') @as(usize, 4) else 1;
    return width;
}
fn cutIndent(text: []const u8, desired_width: usize) usize {
    var n: usize = 0;
    var width: usize = 0;
    while (n < text.len and width < desired_width and (text[n] == ' ' or text[n] == '\t')) : (n += 1) width += if (text[n] == '\t') @as(usize, 4) else 1;
    return n;
}
fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}
fn heading(text: []const u8) ?usize {
    var n: usize = 0;
    while (n < text.len and text[n] == '#') n += 1;
    return if (n >= 1 and n <= 6 and n < text.len and text[n] == ' ') n else null;
}
fn rule(text: []const u8) bool {
    if (text.len == 0 or std.mem.indexOfScalar(u8, "-*_", text[0]) == null) return false;
    var count: usize = 0;
    for (text) |c| {
        if (c == text[0]) count += 1 else if (c != ' ' and c != '\t') return false;
    }
    return count >= 3;
}
fn setextLevel(text: []const u8) ?usize {
    if (text.len == 0 or (text[0] != '=' and text[0] != '-')) return null;
    for (text) |c| if (c != text[0] and c != ' ') return null;
    return if (text[0] == '=') 1 else 2;
}
fn fence(text: []const u8) ?[]const u8 {
    if (text.len < 3 or (text[0] != '`' and text[0] != '~')) return null;
    var n: usize = 0;
    while (n < text.len and text[n] == text[0]) n += 1;
    return if (n >= 3) text[0..n] else null;
}
fn closingFence(text: []const u8, opening: []const u8) bool {
    const found = fence(text) orelse return false;
    return found[0] == opening[0] and found.len >= opening.len and trim(text[found.len..]).len == 0;
}
fn marker(raw: []const u8) ?Marker {
    const width = indent(raw);
    const n = cutIndent(raw, width);
    const text = raw[n..];
    if (text.len < 2) return null;
    if (std.mem.indexOfScalar(u8, "-*+", text[0]) != null and text[1] == ' ') return .{ .indent = width, .content = n + 2, .content_width = width + 2, .ordered = false };
    var digits: usize = 0;
    while (digits < text.len and std.ascii.isDigit(text[digits])) digits += 1;
    if (digits == 0 or digits > 9 or digits + 1 >= text.len or (text[digits] != '.' and text[digits] != ')') or text[digits + 1] != ' ') return null;
    return .{ .indent = width, .content = n + digits + 2, .content_width = width + digits + 2, .ordered = true, .number = std.fmt.parseInt(usize, text[0..digits], 10) catch 1 };
}
fn startsBlock(lines: []const Line, i: usize) bool {
    const text = trim(lines[i].text);
    return text.len == 0 or heading(text) != null or rule(text) or fence(text) != null or text[0] == '>' or marker(lines[i].text) != null or (i + 1 < lines.len and hasPipe(text) and tableSeparator(trim(lines[i + 1].text)));
}
fn hasPipe(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '|') != null;
}
fn cells(input: []const u8, output: *[max_table_columns][]const u8) !usize {
    var text = trim(input);
    if (std.mem.startsWith(u8, text, "|")) text = text[1..];
    if (std.mem.endsWith(u8, text, "|") and (text.len < 2 or text[text.len - 2] != '\\')) text = text[0 .. text.len - 1];
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var code = false;
    while (i <= text.len) : (i += 1) {
        if (i < text.len and text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (i < text.len and text[i] == '`') code = !code;
        if (i == text.len or (text[i] == '|' and !code)) {
            if (count == output.len) return error.MarkdownTableTooWide;
            output[count] = trim(text[start..i]);
            count += 1;
            start = i + 1;
        }
    }
    return count;
}
fn tableSeparator(text: []const u8) bool {
    if (!hasPipe(text)) return false;
    var values: [max_table_columns][]const u8 = undefined;
    const n = cells(text, &values) catch return false;
    for (values[0..n]) |value| {
        const core = std.mem.trim(u8, value, ":");
        if (core.len < 3) return false;
        for (core) |c| if (c != '-') return false;
    }
    return n > 0;
}
pub fn safeUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 8192) return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f or c == '\\' or c == '<' or c == '>') return false;
    return (std.ascii.startsWithIgnoreCase(url, "https://") and url.len > 8) or (std.ascii.startsWithIgnoreCase(url, "http://") and url.len > 7) or (std.ascii.startsWithIgnoreCase(url, "mailto:") and url.len > 7);
}
const Target = struct { url: []const u8, end: usize };
fn linkTarget(context: *Context, text: []const u8, start: usize) !?Target {
    var i = start;
    var parentheses: usize = 0;
    var quoted = false;
    while (i < text.len) : (i += 1) {
        if (context.search_budget == 0) return error.MarkdownTooComplex;
        context.search_budget -= 1;
        if (text[i] == '"' and parentheses == 0) quoted = !quoted;
        if (quoted) continue;
        if (text[i] == '(') {
            parentheses += 1;
            if (parentheses > 4) return null;
        }
        if (text[i] == ')') {
            if (parentheses == 0) {
                var url = trim(text[start..i]);
                if (std.mem.indexOfScalar(u8, url, ' ')) |space| url = url[0..space];
                if (url.len >= 2 and url[0] == '<' and url[url.len - 1] == '>') url = url[1 .. url.len - 1];
                return .{ .url = url, .end = i + 1 };
            }
            parentheses -= 1;
        }
    }
    return null;
}

test "markdown mail: semantic blocks inline styles escaping and deterministic alternatives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "# Hello 🌋\n\nA **bold** and *kind* note with `code` and [link](https://example.test/a?x=1&y=2).\n\n> Quote\n\n| Name | Value |\n| :--- | ---: |\n| α | 42 |\n\n```zig\nconst n = 42; // <tag>\n```\n\n<script>alert(1)</script>\n![remote](https://example.test/pixel.png)\n[bad](javascript:alert(1))";
    const first = try render(arena.allocator(), source);
    const second = try render(arena.allocator(), source);
    try std.testing.expectEqualStrings(first.html, second.html);
    try std.testing.expectEqualStrings(first.plain, second.plain);
    for ([_][]const u8{ "<h1", "<strong>bold</strong>", "<em>kind</em>", "<blockquote", "<table", "<thead>", "text-align:right", "color:#b84a10", "&lt;script&gt;", "href=\"https://example.test/a?x=1&amp;y=2\"", "cid:omagma-logo@omagma.invalid" }) |part| try std.testing.expect(std.mem.indexOf(u8, first.html, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, first.html, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.html, "href=\"javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.html, "src=\"https:") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.plain, "A bold and kind note") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.plain, "const n = 42; // <tag>") != null);
}
test "markdown mail: tight loose nested list spacing and paragraph boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tight = try render(a, "Before\n\n- one\n  - nested\n- two\n\nAfter");
    try std.testing.expect(std.mem.indexOf(u8, tight.html, "padding:0 0 4px\">one<ul") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight.html, ">nested</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight.html, "</ul>\n<p style=\"margin:0 0 16px\">After") != null);
    const loose = try render(a, "- one\n\n- two");
    try std.testing.expect(std.mem.indexOf(u8, loose.html, "padding:0 0 10px\"><p") != null);
    const boundary = try render(a, "- a\n---\n\nParagraph\nmore");
    try std.testing.expect(std.mem.indexOf(u8, boundary.html, "</ul>\n<hr") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary.html, "Paragraph<br>\nmore") != null);
    const ordered = try render(a, "3. c\n4. d");
    try std.testing.expect(std.mem.indexOf(u8, ordered.html, "<ol start=\"3\"") != null);
}
test "markdown mail: output complexity depth controls and URL boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidUtf8, render(a, "\xff"));
    try std.testing.expectError(error.InvalidBody, render(a, "hello\x1b[31m"));
    const expanding = try a.alloc(u8, t.Limits.body_bytes / 2);
    @memset(expanding, '&');
    try std.testing.expectError(error.RenderedBodyTooLarge, render(a, expanding));
    const many_lines = try a.alloc(u8, max_lines + 1);
    @memset(many_lines, '\n');
    try std.testing.expectError(error.MarkdownTooComplex, render(a, many_lines));
    for ([_][]const u8{ "javascript:alert(1)", "data:image/png;base64,aaa", "file:///tmp/private", "//example.test", "https://example.test/\n" }) |url| try std.testing.expect(!safeUrl(url));
    try std.testing.expect(safeUrl("https://example.test/path"));
    try std.testing.expect(safeUrl("mailto:peer@example.test"));
}

test "markdown mail: allocated results have exact ownership and capped failures clean scratch" {
    const rendered = try render(std.testing.allocator, "**Hello** fixture");
    defer std.testing.allocator.free(rendered.plain);
    defer std.testing.allocator.free(rendered.html);
    const escaped = try escapeSource(std.testing.allocator, "# Literal *text*");
    defer std.testing.allocator.free(escaped);
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = std.testing.allocator, .limit = 256 };
    try std.testing.expectError(error.OutOfMemory, render(cap.allocator(), "Hello"));
    try std.testing.expectEqual(@as(usize, 0), cap.used);
}

test "markdown mail: footer has approved image first gray prose orange omagma link and trailing volcano" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try render(arena.allocator(), "A synthetic message.");
    const start = std.mem.indexOf(u8, rendered.html, "<div class=\"omagma-footer\"").?;
    const footer = rendered.html[start..];
    const image_at = std.mem.indexOf(u8, footer, "<img src=\"cid:omagma-logo@omagma.invalid\"").?;
    const prose_at = std.mem.indexOf(u8, footer, ">Sent with ").?;
    const link_at = std.mem.indexOf(u8, footer, "<a class=\"omagma-footer-link\"").?;
    try std.testing.expect(image_at < prose_at and prose_at < link_at);
    try std.testing.expect(std.mem.indexOf(u8, footer, "color:#71717a\"><img") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "href=\"https://technologylab-ai.github.io/omagma/\" style=\"color:#b84a10;text-decoration:underline\">omagma</a> 🌋</div>") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, footer, "<a "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, footer, "<img "));
    try std.testing.expect(std.mem.endsWith(u8, rendered.plain, "Sent with omagma — https://technologylab-ai.github.io/omagma/ 🌋"));
}

test "original mail: Markdown preparation retains original HTML and limits trusted styling to note" {
    const original_html = "<!doctype html><html><head><style>p,div{color:blue!important}</style></head><body class=\"original\"><p style=\"color:red\">Original <b>formatting</b></p><img src=\"cid:omagma-logo@omagma.invalid\"></body></html>";
    const resources = [_]t.Attachment{.{ .id = "old-logo", .filename = "old-logo.png", .mimeType = "image/png", .contentId = logo_content_id, .data = "YWJj", .size = 3 }};
    const draft: t.Draft = .{ .bodyText = "# Note\n\n**New** [link](https://example.test/note). Literal cid:omagma-logo@omagma.invalid.\n\n`<img src=\"cid:omagma-logo@omagma.invalid\">`\n\n## Later heading\n\n- Later list item", .bodyFormat = .markdown, .original = .{ .sourceMessageId = "original", .from = .{ .address = "sender@example.test" }, .subject = "Original subject", .bodyText = "Original formatting", .bodyHtml = original_html, .resources = &resources } };
    const result = try prepare(std.testing.allocator, draft);
    defer std.testing.allocator.free(result.html.?);
    defer std.testing.allocator.free(result.plain);
    const html = result.html.?;
    const original_at = std.mem.indexOf(u8, html, "<p style=\"color:red\">Original <b>formatting</b></p>").?;
    try std.testing.expect(result.logoOffset.? < original_at);
    try std.testing.expectEqualStrings(logo_content_id, html[result.logoOffset.?..][0..logo_content_id.len]);
    try std.testing.expectEqualStrings("src=\"cid:", html[result.logoOffset.? - "src=\"cid:".len .. result.logoOffset.?]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "<html>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "<body class=\"original\">"));
    try std.testing.expect(std.mem.indexOf(u8, html, "<style>p,div{color:blue!important}</style>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html[0..original_at], "color:#b84a10!important;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html[0..original_at], "font-weight:bold!important;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html[0..original_at], "font-family:-apple-system,BlinkMacSystemFont,&#39;Segoe UI&#39;,Arial,sans-serif!important;") != null);
    const first_heading = std.mem.indexOf(u8, html, "<h1 ").?;
    const first_heading_end = std.mem.indexOfScalarPos(u8, html, first_heading, '>').?;
    try std.testing.expect(std.mem.indexOf(u8, html[first_heading..first_heading_end], "margin-top:0!important;") != null);
    const later_heading = std.mem.indexOf(u8, html, "<h2 ").?;
    const later_heading_end = std.mem.indexOfScalarPos(u8, html, later_heading, '>').?;
    try std.testing.expect(std.mem.indexOf(u8, html[later_heading..later_heading_end], "margin-top:0!important;") == null);
    try std.testing.expect(std.mem.indexOf(u8, html[later_heading..later_heading_end], "margin:24px 0 12px!important;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "margin:0 0 16px!important;padding-left:") != null);
    try std.testing.expect(result.resources.ptr == resources[0..].ptr);
    try std.testing.expect(std.mem.startsWith(u8, result.plain, "Note\n\nNew link"));
    try std.testing.expect(std.mem.endsWith(u8, result.plain, "Original formatting"));
}

test "original mail: plain and recovery notes stay literal inside branded HTML" {
    const draft: t.Draft = .{ .bodyText = "**Literal** <script>alert(1)</script>\nSecond line.", .original = .{ .from = .{ .address = "sender@example.test" }, .subject = "Subject", .bodyText = "Original <literal> & plain", .bodyHtml = "" } };
    const result = try prepare(std.testing.allocator, draft);
    defer std.testing.allocator.free(result.html.?);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.indexOf(u8, result.html.?, "**Literal** &lt;script&gt;alert(1)&lt;/script&gt;\nSecond line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html.?, "white-space:pre-wrap!important;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html.?, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.html.?, "Original &lt;literal&gt; &amp; plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html.?, "Sent with ") != null);
    try std.testing.expect(std.mem.startsWith(u8, result.plain, draft.bodyText));
    var recovery = draft;
    recovery.recoveryFields = &.{ "unfinished address", "", "", "Subject", "Recovery **literal**" };
    const recovered = try prepare(std.testing.allocator, recovery);
    defer std.testing.allocator.free(recovered.html.?);
    defer std.testing.allocator.free(recovered.plain);
    try std.testing.expect(std.mem.startsWith(u8, recovered.plain, "Recovery **literal**"));
    const legacy = try prepare(std.testing.allocator, .{ .bodyText = "**Literal**" });
    try std.testing.expect(legacy.html == null and legacy.logoOffset == null and legacy.resources.len == 0);
    try std.testing.expectEqualStrings("**Literal**", legacy.plain);
}
