//! Outbound assembly of an immutable original and a separately authored note.
//! Original HTML is opaque mail data: no CSS evaluation, resource loading or
//! semantic-reader sanitization occurs here. Only its document envelope and
//! encoding declarations are inspected. Every output allocation is caller-owned.
const std = @import("std");
const t = @import("types.zig");

pub const Note = struct { html: []const u8, plain: []const u8, logoOffset: usize };
pub const Prepared = struct { html: []const u8, plain: []const u8, logoOffset: usize, resources: []const t.Attachment };
const logo_content_id = "omagma-logo@omagma.invalid";
const max_tokens = 32768;
const max_tag_bytes = 16384;
const max_encoding_tags = 32;
const utf8_meta = "<meta charset=\"utf-8\">";
const Span = struct { start: usize, end: usize };

const Buffer = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn append(self: *Buffer, value: []const u8) !void {
        if (value.len > t.Limits.body_bytes - self.bytes.items.len) return error.RenderedBodyTooLarge;
        try self.bytes.appendSlice(self.a, value);
    }
    fn escaped(self: *Buffer, value: []const u8) !void {
        var start: usize = 0;
        for (value, 0..) |c, i| {
            const replacement: ?[]const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => null,
            };
            if (replacement) |encoded| {
                try self.append(value[start..i]);
                try self.append(encoded);
                start = i + 1;
            }
        }
        try self.append(value[start..]);
    }
};

/// Validates retained source text and its structural envelope. Resource bytes,
/// CID/header syntax and aggregate attachment quotas remain the MIME/backend's
/// responsibility. This routine neither allocates nor changes the original.
pub fn validate(original: t.Original) !void {
    _ = try inspect(original);
}

/// Bit i identifies a resource referenced by actual URL-bearing HTML/CSS.
/// Disposition and filename do not affect this result: even an image declared
/// as an attachment may be embedded, while a PDF's unused CID proves nothing.
/// Exact Content-Location URLs are recognized after HTML/CSS decoding; relative
/// resolution, network access and URI-equivalence guesses are intentionally absent.
pub fn resourceUsage(html: []const u8, resources: []const t.Attachment) !u64 {
    if (resources.len > 64) return error.TooManyAttachments;
    try bodyText(html);
    _ = try scan(html);
    var used: u64 = 0;
    try scanReferences(html, resources, &used);
    return used;
}

pub fn prepare(a: std.mem.Allocator, note: Note, original: t.Original) !Prepared {
    const envelope = try inspect(original);
    try bodyText(note.html);
    try bodyText(note.plain);
    if (note.logoOffset > note.html.len or logo_content_id.len > note.html.len - note.logoOffset or
        !std.mem.eql(u8, note.html[note.logoOffset..][0..logo_content_id.len], logo_content_id)) return error.MissingLogoReference;

    var plain: Buffer = .{ .a = a };
    errdefer plain.bytes.deinit(a);
    try plain.append(note.plain);
    if (plain.bytes.items.len != 0) try plain.append("\n\n");
    try plain.append("---------- Original message ----------\n");
    try plainHeaders(&plain, original);
    try plain.append("\n");
    try plain.append(original.bodyText);

    var html: Buffer = .{ .a = a };
    errdefer html.bytes.deinit(a);
    const input = original.bodyHtml;
    const content_start = if (envelope.html_open) |root| root.end else if (envelope.doctype) |doctype| doctype.end else 0;
    if (envelope.html_open) |root| {
        try envelope.copy(&html, input, 0, root.end);
    } else {
        if (envelope.doctype) |doctype| try envelope.copy(&html, input, 0, doctype.end) else try html.append("<!doctype html>");
        try html.append("<html>");
    }

    var after_head: usize = undefined;
    if (envelope.head_open) |head| {
        try envelope.copy(&html, input, content_start, head.end);
        try html.append(utf8_meta);
        const end = if (envelope.head_close) |close| close.start else envelope.implicit_head_end orelse return error.InvalidOriginalHtml;
        try envelope.copy(&html, input, head.end, end);
        if (envelope.head_close) |close| {
            try envelope.copy(&html, input, close.start, close.end);
            after_head = close.end;
        } else {
            try html.append("</head>");
            after_head = end;
        }
    } else {
        const end = if (envelope.body_open) |body| body.start else envelope.first_body orelse if (envelope.html_close) |root| root.start else input.len;
        try html.append("<head>");
        try html.append(utf8_meta);
        try envelope.copy(&html, input, content_start, end);
        try html.append("</head>");
        after_head = end;
    }

    const body_start = if (envelope.body_open) |body| body.end else after_head;
    if (envelope.body_open) |body| try envelope.copy(&html, input, after_head, body.end) else try html.append("<body>");
    const logo_offset = html.bytes.items.len + note.logoOffset;
    try html.append(note.html);
    try htmlHeaders(&html, original);
    const body_end = if (envelope.body_close) |body| body.start else if (envelope.html_close) |root| root.start else input.len;
    if (input.len == 0) {
        try html.append("<div style=\"white-space:pre-wrap;overflow-wrap:anywhere\">");
        try html.escaped(original.bodyText);
        try html.append("</div>");
    } else try envelope.copy(&html, input, body_start, body_end);
    const after_body = if (envelope.body_close) |body| blk: {
        try envelope.copy(&html, input, body.start, body.end);
        break :blk body.end;
    } else blk: {
        try html.append("</body>");
        break :blk body_end;
    };
    if (envelope.html_close != null) {
        try envelope.copy(&html, input, after_body, input.len);
    } else {
        try envelope.copy(&html, input, after_body, input.len);
        try html.append("</html>");
    }
    const plain_result = try plain.bytes.toOwnedSlice(a);
    errdefer a.free(plain_result);
    return .{ .html = try html.bytes.toOwnedSlice(a), .plain = plain_result, .logoOffset = logo_offset, .resources = original.resources };
}

fn bodyText(value: []const u8) !void {
    if (value.len > t.Limits.body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidOriginalHtml;
}
fn summaryText(value: []const u8, limit: usize) !void {
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return error.InvalidOriginalHtml;
    for (value) |c| if ((c < 32 and c != '\t') or c == 127) return error.InvalidOriginalHtml;
}
fn mailbox(value: t.Address) !void {
    try summaryText(value.address, 254);
    try summaryText(value.name, 256);
}
fn inspect(original: t.Original) !Envelope {
    if (original.version != 1) return error.OriginalHtmlUnavailable;
    try bodyText(original.bodyText);
    try bodyText(original.bodyHtml);
    try summaryText(original.sourceMessageId, 1024);
    try summaryText(original.subject, 4096);
    try summaryText(original.date, 1024);
    try mailbox(original.from);
    if (original.to.len + original.cc.len > 2 * t.Limits.recipients) return error.InvalidOriginalHtml;
    for (original.to) |address| try mailbox(address);
    for (original.cc) |address| try mailbox(address);
    const envelope = try scan(original.bodyHtml);
    try validateReferences(original.bodyHtml, original.resources);
    return envelope;
}

fn addressText(out: *Buffer, address: t.Address, html: bool) !void {
    if (address.name.len != 0) {
        if (html) try out.escaped(address.name) else try out.append(address.name);
        try out.append(if (html) " &lt;" else " <");
    }
    if (html) try out.escaped(address.address) else try out.append(address.address);
    if (address.name.len != 0) try out.append(if (html) "&gt;" else ">");
}
fn addressesText(out: *Buffer, addresses: []const t.Address, html: bool) !void {
    for (addresses, 0..) |address, i| {
        if (i != 0) try out.append(", ");
        try addressText(out, address, html);
    }
}
fn plainHeaders(out: *Buffer, original: t.Original) !void {
    try out.append("From: ");
    try addressText(out, original.from, false);
    try out.append("\n");
    if (original.date.len != 0) {
        try out.append("Date: ");
        try out.append(original.date);
        try out.append("\n");
    }
    if (original.to.len != 0) {
        try out.append("To: ");
        try addressesText(out, original.to, false);
        try out.append("\n");
    }
    if (original.cc.len != 0) {
        try out.append("Cc: ");
        try addressesText(out, original.cc, false);
        try out.append("\n");
    }
    try out.append("Subject: ");
    try out.append(original.subject);
    try out.append("\n");
}
fn htmlHeaders(out: *Buffer, original: t.Original) !void {
    try out.append("<div class=\"omagma-original-header\" style=\"display:block!important;position:static!important;visibility:visible!important;opacity:1!important;float:none!important;box-sizing:border-box!important;width:680px!important;max-width:100%!important;margin:10px auto 16px!important;padding:12px 16px!important;border:0!important;border-left:3px solid #b84a10!important;background:#f3f4f6!important;color:#52525b!important;font-family:Arial,sans-serif!important;font-size:13px!important;font-weight:normal!important;line-height:1.5!important;text-align:left!important;white-space:pre-wrap!important;overflow-wrap:anywhere!important\">Original message\n");
    try htmlLabel(out, "From:");
    try addressText(out, original.from, true);
    if (original.date.len != 0) {
        try out.append("\n");
        try htmlLabel(out, "Date:");
        try out.escaped(original.date);
    }
    if (original.to.len != 0) {
        try out.append("\n");
        try htmlLabel(out, "To:");
        try addressesText(out, original.to, true);
    }
    if (original.cc.len != 0) {
        try out.append("\n");
        try htmlLabel(out, "Cc:");
        try addressesText(out, original.cc, true);
    }
    try out.append("\n");
    try htmlLabel(out, "Subject:");
    try out.escaped(original.subject);
    try out.append("</div>");
}
fn htmlLabel(out: *Buffer, label: []const u8) !void {
    try out.append("<strong style=\"color:inherit!important;font-weight:bold!important\">");
    try out.escaped(label);
    try out.append("</strong> ");
}

const Envelope = struct {
    html_open: ?Span = null,
    html_close: ?Span = null,
    head_open: ?Span = null,
    head_close: ?Span = null,
    body_open: ?Span = null,
    body_close: ?Span = null,
    doctype: ?Span = null,
    first_body: ?usize = null,
    implicit_head_end: ?usize = null,
    encoding_tags: [max_encoding_tags]Span = undefined,
    encoding_count: usize = 0,
    fn copy(self: *const Envelope, out: *Buffer, input: []const u8, start: usize, end: usize) !void {
        if (start > end or end > input.len) return error.InvalidOriginalHtml;
        var offset = start;
        for (self.encoding_tags[0..self.encoding_count]) |tag| {
            if (tag.end <= start or tag.start >= end) continue;
            if (tag.start < offset or tag.end > end) return error.InvalidOriginalHtml;
            try out.append(input[offset..tag.start]);
            offset = tag.end;
        }
        try out.append(input[offset..end]);
    }
};
const Tag = struct {
    span: Span,
    name: []const u8,
    attributes: []const u8 = "",
    closing: bool = false,
    declaration: bool = false,
    self_closing: bool = false,
    fn is(self: Tag, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }
    fn attribute(self: Tag, name: []const u8) ?[]const u8 {
        const attrs = self.attributes;
        var i: usize = 0;
        while (i < attrs.len) {
            while (i < attrs.len and (white(attrs[i]) or attrs[i] == '/')) : (i += 1) {}
            const start = i;
            while (i < attrs.len and !white(attrs[i]) and attrs[i] != '=' and attrs[i] != '/') : (i += 1) {}
            if (i == start) {
                i += 1;
                continue;
            }
            const key = attrs[start..i];
            while (i < attrs.len and white(attrs[i])) : (i += 1) {}
            var value: []const u8 = "";
            if (i < attrs.len and attrs[i] == '=') {
                i += 1;
                while (i < attrs.len and white(attrs[i])) : (i += 1) {}
                if (i < attrs.len and (attrs[i] == '\'' or attrs[i] == '"')) {
                    const quote = attrs[i];
                    i += 1;
                    const value_start = i;
                    while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
                    value = attrs[value_start..i];
                    if (i < attrs.len) i += 1;
                } else {
                    const value_start = i;
                    while (i < attrs.len and !white(attrs[i])) : (i += 1) {}
                    value = attrs[value_start..i];
                }
            }
            if (std.ascii.eqlIgnoreCase(key, name)) return value;
        }
        return null;
    }
};
fn white(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 12;
}
fn blank(value: []const u8) bool {
    for (value) |c| if (!white(c)) return false;
    return true;
}
fn commentEnd(input: []const u8, start: usize) !usize {
    var i = start + 4;
    while (i < input.len) : (i += 1) {
        if (std.mem.startsWith(u8, input[i..], "-->")) return i + 3;
        if (std.mem.startsWith(u8, input[i..], "--!>")) return i + 4;
    }
    return error.InvalidOriginalHtml;
}
fn tagAt(input: []const u8, start: usize) !?Tag {
    var i = start + 1;
    if (i == input.len) return null;
    var closing = false;
    if (input[i] == '/') {
        closing = true;
        i += 1;
    }
    if (i == input.len) return null;
    const declaration = input[i] == '!' or input[i] == '?';
    if (declaration) i += 1;
    if (i == input.len) return error.InvalidOriginalHtml;
    if (!declaration and !std.ascii.isAlphabetic(input[i])) return null;
    const name_start = i;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == ':' or input[i] == '-' or input[i] == '_')) : (i += 1) {}
    const name = input[name_start..i];
    if (!declaration and i < input.len and !white(input[i]) and input[i] != '/' and input[i] != '>') return error.InvalidOriginalHtml;
    const attrs = i;
    var quote: u8 = 0;
    var brackets: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i - start >= max_tag_bytes) return error.OriginalHtmlUnavailable;
        const c = input[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (declaration and c == '[') {
            brackets += 1;
        } else if (declaration and c == ']') {
            brackets -|= 1;
        } else if (c == '<' and !declaration) {
            return error.InvalidOriginalHtml;
        } else if (c == '>' and brackets == 0) {
            const attributes = std.mem.trimEnd(u8, input[attrs..i], " \t\r\n");
            return .{ .span = .{ .start = start, .end = i + 1 }, .name = name, .attributes = attributes, .closing = closing, .declaration = declaration, .self_closing = std.mem.endsWith(u8, attributes, "/") };
        }
    }
    return error.InvalidOriginalHtml;
}
fn headTag(tag: Tag) bool {
    if (tag.closing) return false;
    for ([_][]const u8{ "meta", "base", "link", "style", "script", "title", "noscript" }) |name| if (tag.is(name)) return true;
    return false;
}
fn rawTag(tag: Tag) bool {
    if (tag.closing) return false;
    for ([_][]const u8{ "style", "script", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "noscript" }) |name| if (tag.is(name)) return true;
    return false;
}
fn rawEnd(input: []const u8, tag: Tag) !usize {
    var offset = tag.span.end;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |start| {
        offset = start + 1;
        if (offset == input.len or input[offset] != '/') continue;
        const name_start = offset + 1;
        if (tag.name.len > input.len - name_start or !std.ascii.eqlIgnoreCase(input[name_start..][0..tag.name.len], tag.name)) continue;
        const end = name_start + tag.name.len;
        if (end < input.len and !white(input[end]) and input[end] != '/' and input[end] != '>') continue;
        const closer = try tagAt(input, start) orelse return error.InvalidOriginalHtml;
        return closer.span.end;
    }
    return error.InvalidOriginalHtml;
}

/// Linear bounded envelope scan, not an HTML/CSS sanitizer or a browser DOM.
/// Optional body/head/html end tags are repaired at known envelope boundaries;
/// duplicate roots, trailing documents and ambiguous envelopes are refused.
fn scan(input: []const u8) !Envelope {
    var result: Envelope = .{};
    var offset: usize = 0;
    var tokens: usize = 0;
    var in_head = false;
    var implicit_head_content = false;
    while (offset < input.len) {
        if (tokens == max_tokens) return error.OriginalHtmlUnavailable;
        tokens += 1;
        if (std.mem.startsWith(u8, input[offset..], "<!--")) {
            offset = try commentEnd(input, offset);
            continue;
        }
        if (input[offset] != '<') {
            const end = std.mem.indexOfScalarPos(u8, input, offset, '<') orelse input.len;
            if (!blank(input[offset..end])) {
                if (result.body_close != null or result.html_close != null) return error.InvalidOriginalHtml;
                if (in_head) {
                    result.implicit_head_end = offset;
                    in_head = false;
                }
                if (result.body_open == null and result.first_body == null) result.first_body = offset;
            }
            offset = end;
            continue;
        }
        const tag = (try tagAt(input, offset)) orelse {
            if (result.body_close != null or result.html_close != null) return error.InvalidOriginalHtml;
            if (in_head) {
                result.implicit_head_end = offset;
                in_head = false;
            }
            if (result.body_open == null and result.first_body == null) result.first_body = offset;
            offset += 1;
            continue;
        };
        offset = tag.span.end;
        if (tag.declaration) {
            if (tag.is("doctype")) {
                if (result.doctype != null or result.html_open != null or result.head_open != null or result.body_open != null or result.first_body != null) return error.InvalidOriginalHtml;
                result.doctype = tag.span;
            } else if (result.body_close != null or result.html_close != null) return error.InvalidOriginalHtml;
            continue;
        }
        if (tag.is("html")) {
            if (tag.self_closing) return error.InvalidOriginalHtml;
            if (tag.closing) {
                if (result.html_open == null or result.html_close != null) return error.InvalidOriginalHtml;
                if (in_head) {
                    result.implicit_head_end = tag.span.start;
                    in_head = false;
                }
                result.html_close = tag.span;
            } else {
                if (result.html_open != null or result.head_open != null or result.body_open != null or result.first_body != null or implicit_head_content) return error.InvalidOriginalHtml;
                result.html_open = tag.span;
            }
            continue;
        }
        if (result.html_close != null) return error.InvalidOriginalHtml;
        if (tag.is("head")) {
            if (tag.self_closing or result.body_open != null or result.first_body != null) return error.InvalidOriginalHtml;
            if (tag.closing) {
                if (result.head_open == null or !in_head or result.head_close != null) return error.InvalidOriginalHtml;
                result.head_close = tag.span;
                in_head = false;
            } else {
                if (result.head_open != null or implicit_head_content) return error.InvalidOriginalHtml;
                result.head_open = tag.span;
                in_head = true;
            }
            continue;
        }
        if (tag.is("body")) {
            if (tag.self_closing) return error.InvalidOriginalHtml;
            if (tag.closing) {
                if (result.body_open == null or result.body_close != null or in_head) return error.InvalidOriginalHtml;
                result.body_close = tag.span;
            } else {
                if (result.body_open != null or result.first_body != null) return error.InvalidOriginalHtml;
                if (in_head) {
                    result.implicit_head_end = tag.span.start;
                    in_head = false;
                }
                result.body_open = tag.span;
            }
            continue;
        }
        if (result.body_close != null) return error.InvalidOriginalHtml;
        if (tag.is("plaintext") or tag.is("frameset") or tag.is("frame")) return error.OriginalHtmlUnavailable;
        if (result.head_open == null and result.body_open == null and result.first_body == null and headTag(tag)) implicit_head_content = true;
        if (tag.is("meta") and !tag.closing) {
            const http_equiv = tag.attribute("http-equiv") orelse "";
            if (tag.attribute("charset") != null or std.ascii.eqlIgnoreCase(std.mem.trim(u8, http_equiv, " \t\r\n"), "content-type")) {
                if (result.encoding_count == result.encoding_tags.len) return error.OriginalHtmlUnavailable;
                result.encoding_tags[result.encoding_count] = tag.span;
                result.encoding_count += 1;
            }
        }
        if (in_head and !headTag(tag)) {
            result.implicit_head_end = tag.span.start;
            in_head = false;
            if (result.first_body == null) result.first_body = tag.span.start;
        } else if (result.body_open == null and !in_head and result.first_body == null and
            (result.head_close != null or !headTag(tag))) result.first_body = tag.span.start;
        if (rawTag(tag)) offset = try rawEnd(input, tag);
    }
    if (in_head) result.implicit_head_end = input.len;
    return result;
}

/// Scan URL-bearing markup only: prose/code containing "cid:" is not a
/// reference. Comments remain opaque, including Outlook conditional markup;
/// all captured related resources are still retained for those clients.
fn validateReferences(input: []const u8, resources: []const t.Attachment) !void {
    try scanReferences(input, resources, null);
}
fn scanReferences(input: []const u8, resources: []const t.Attachment, used: ?*u64) !void {
    var offset: usize = 0;
    var decoded: [max_tag_bytes]u8 = undefined;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |start| {
        if (std.mem.startsWith(u8, input[start..], "<!--")) {
            offset = try commentEnd(input, start);
            continue;
        }
        const tag = try tagAt(input, start) orelse {
            offset = start + 1;
            continue;
        };
        offset = tag.span.end;
        if (tag.closing or tag.declaration) continue;
        for ([_][]const u8{ "src", "href", "background", "poster", "data", "xlink:href", "lowsrc" }) |name| {
            if (tag.attribute(name)) |raw| try checkUrl(try htmlAttribute(raw, &decoded), resources, used);
        }
        if (tag.attribute("srcset")) |raw| {
            var candidates = std.mem.splitScalar(u8, try htmlAttribute(raw, &decoded), ',');
            while (candidates.next()) |candidate| {
                const value = std.mem.trim(u8, candidate, " \t\r\n");
                const end = std.mem.indexOfAny(u8, value, " \t\r\n") orelse value.len;
                try checkUrl(value[0..end], resources, used);
            }
        }
        if (tag.attribute("style")) |raw| try cssReferences(try htmlAttribute(raw, &decoded), resources, used);
        if (rawTag(tag)) {
            const end = try rawEnd(input, tag);
            if (tag.is("style")) {
                const closer = std.mem.lastIndexOfScalar(u8, input[tag.span.end..end], '<') orelse return error.InvalidOriginalHtml;
                try cssReferences(input[tag.span.end..][0..closer], resources, used);
            }
            offset = end;
        }
    }
}
fn hex(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}
fn checkUrl(raw: []const u8, resources: []const t.Attachment, used: ?*u64) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(value, "cid:")) {
        if (value.len != 0) if (used) |bits| for (resources, 0..) |resource, index| {
            if (resource.contentLocation) |location| if (std.mem.eql(u8, value, location)) {
                bits.* |= @as(u64, 1) << @as(u6, @intCast(index));
            };
        };
        return;
    }
    var buffer: [1024]u8 = undefined;
    var n: usize = 0;
    var i: usize = 4;
    while (i < value.len) : (i += 1) {
        if (n == buffer.len) return error.OriginalResourceUnavailable;
        var c = value[i];
        if (c == '%') {
            if (value.len - i < 3) return error.OriginalResourceUnavailable;
            c = ((hex(value[i + 1]) orelse return error.OriginalResourceUnavailable) << 4) | (hex(value[i + 2]) orelse return error.OriginalResourceUnavailable);
            i += 2;
        }
        if (c < 33 or c == 127) return error.OriginalResourceUnavailable;
        buffer[n] = c;
        n += 1;
    }
    if (n == 0) return error.OriginalResourceUnavailable;
    var matched = false;
    for (resources, 0..) |resource, index| if (resource.contentId) |id| {
        if (std.mem.eql(u8, buffer[0..n], id)) {
            matched = true;
            // Keep every match visible to the backend's existing duplicate-CID
            // validation, rather than accidentally selecting the first part.
            if (used) |bits| bits.* |= @as(u64, 1) << @as(u6, @intCast(index));
        }
    };
    if (matched) return;
    return error.OriginalResourceUnavailable;
}
fn entity(value: []const u8) ?u21 {
    const names = .{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' }, .{ "colon", ':' }, .{ "commat", '@' }, .{ "sol", '/' }, .{ "percnt", '%' }, .{ "num", '#' } };
    inline for (names) |pair| if (std.mem.eql(u8, value, pair[0])) return pair[1];
    if (value.len > 1 and value[0] == '#') {
        const is_hex = value.len > 2 and (value[1] == 'x' or value[1] == 'X');
        const cp = std.fmt.parseInt(u21, value[if (is_hex) @as(usize, 2) else 1..], if (is_hex) 16 else 10) catch return null;
        if (cp == 0 or !std.unicode.utf8ValidCodepoint(cp)) return null;
        return cp;
    }
    return null;
}
fn htmlAttribute(input: []const u8, out: []u8) ![]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '&') {
            const tail = input[i + 1 .. @min(input.len, i + 17)];
            if (std.mem.indexOfScalar(u8, tail, ';')) |relative| {
                const at = i + 1 + relative;
                if (entity(input[i + 1 .. at])) |cp| {
                    var encoded: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidOriginalHtml;
                    if (count > out.len - n) return error.OriginalHtmlUnavailable;
                    @memcpy(out[n..][0..count], encoded[0..count]);
                    n += count;
                    i = at;
                    continue;
                }
            }
        }
        if (n == out.len) return error.OriginalHtmlUnavailable;
        out[n] = input[i];
        n += 1;
    }
    return out[0..n];
}
fn cssStringEnd(input: []const u8, start: usize) !usize {
    const quote = input[start];
    var i = start + 1;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\') {
            if (i + 1 < input.len) i += 1;
        } else if (input[i] == quote) return i + 1;
    }
    return error.OriginalHtmlUnavailable;
}
fn cssUrl(input: []const u8, out: []u8) ![]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len) : (i += 1) {
        var cp: u32 = input[i];
        if (input[i] == '\\') {
            i += 1;
            if (i == input.len) return error.OriginalResourceUnavailable;
            if (input[i] == '\n' or input[i] == '\r' or input[i] == 12) {
                if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') i += 1;
                continue;
            }
            cp = input[i];
            if (hex(input[i])) |first| {
                cp = first;
                var count: usize = 1;
                while (count < 6 and i + 1 < input.len) : (count += 1) {
                    const next = hex(input[i + 1]) orelse break;
                    cp = cp * 16 + next;
                    i += 1;
                }
                if (i + 1 < input.len and white(input[i + 1])) {
                    i += 1;
                    if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') i += 1;
                }
            }
        } else {
            if (n == out.len) return error.OriginalHtmlUnavailable;
            out[n] = input[i];
            n += 1;
            continue;
        }
        var encoded: [4]u8 = undefined;
        if (cp > 0x10ffff) return error.OriginalResourceUnavailable;
        const count = std.unicode.utf8Encode(@intCast(cp), &encoded) catch return error.OriginalResourceUnavailable;
        if (count > out.len - n) return error.OriginalHtmlUnavailable;
        @memcpy(out[n..][0..count], encoded[0..count]);
        n += count;
    }
    return out[0..n];
}
fn cssReferences(input: []const u8, resources: []const t.Attachment, used: ?*u64) !void {
    var i: usize = 0;
    var decoded: [max_tag_bytes]u8 = undefined;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, input, i + 2, "*/") orelse return error.OriginalHtmlUnavailable;
            i = end + 2;
            continue;
        }
        if (input[i] == '\'' or input[i] == '"') {
            i = try cssStringEnd(input, i);
            continue;
        }
        const before = i == 0 or (!std.ascii.isAlphanumeric(input[i - 1]) and input[i - 1] != '-' and input[i - 1] != '_');
        if (!before or !std.ascii.startsWithIgnoreCase(input[i..], "url")) {
            i += 1;
            continue;
        }
        var next = i + 3;
        while (next < input.len and white(input[next])) next += 1;
        if (next == input.len or input[next] != '(') {
            i += 3;
            continue;
        }
        next += 1;
        while (next < input.len and white(input[next])) next += 1;
        if (next == input.len) return error.OriginalHtmlUnavailable;
        var value: []const u8 = undefined;
        if (input[next] == '\'' or input[next] == '"') {
            const end = try cssStringEnd(input, next);
            value = input[next + 1 .. end - 1];
            next = end;
            while (next < input.len and white(input[next])) next += 1;
            if (next == input.len or input[next] != ')') return error.OriginalHtmlUnavailable;
        } else {
            const start = next;
            while (next < input.len and input[next] != ')') : (next += 1) if (input[next] == '\\' and next + 1 < input.len) {
                next += 1;
            };
            if (next == input.len) return error.OriginalHtmlUnavailable;
            value = std.mem.trimEnd(u8, input[start..next], " \t\r\n");
        }
        try checkUrl(try cssUrl(value, &decoded), resources, used);
        i = next + 1;
    }
}

fn fixtureOriginal(html: []const u8) t.Original {
    return .{ .sourceMessageId = "synthetic-source", .from = .{ .address = "sender@example.test", .name = "Sender & <friend>" }, .to = &.{.{ .address = "recipient@example.test" }}, .subject = "A <table> & a picture", .date = "Mon, 05 Oct 2026 12:00:00 +0000", .bodyText = "Original plain text.", .bodyHtml = html };
}
const fixture_note = "<div>New note<img src=\"cid:omagma-logo@omagma.invalid\"></div>";
fn fixtureNote() Note {
    return .{ .html = fixture_note, .plain = "New note", .logoOffset = std.mem.indexOf(u8, fixture_note, logo_content_id).? };
}

test "original mail: body prefix keeps attributes styles comments images and trusted logo offset" {
    const original_html = "<!DOCTYPE html><HTML xmlns:v='urn:schemas-microsoft-com:vml'><HEAD><META CHARSET='windows-1252'><style>body{color:red}p{margin:9px!important}div:before{content:'<body>'}</style><!-- <body>not a body</body> --></HEAD><BODY class='original' data-label='a > b' style='background:#123456'><table><tr><td>Received <img src='cid:picture@example.test'></td></tr></table><img src=\"cid:omagma-logo@omagma.invalid\"><!--[if mso]><v:rect fill='true'></v:rect><![endif]--></BODY></HTML>";
    var original = fixtureOriginal(original_html);
    original.cc = &.{.{ .address = "copied@example.test" }};
    original.resources = &.{
        .{ .id = "picture", .filename = "picture.png", .mimeType = "image/png", .contentId = "picture@example.test" },
        .{ .id = "old-logo", .filename = "omagma-logo.png", .mimeType = "image/png", .contentId = logo_content_id },
    };
    const result = try prepare(std.testing.allocator, fixtureNote(), original);
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expectEqualStrings(logo_content_id, result.html[result.logoOffset..][0..logo_content_id.len]);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.html, "cid:omagma-logo@omagma.invalid"));
    for ([_][]const u8{ "<HTML xmlns:v='urn:schemas-microsoft-com:vml'>", "<style>body{color:red}p{margin:9px!important}div:before{content:'<body>'}</style>", "<!-- <body>not a body</body> -->", "<BODY class='original' data-label='a > b' style='background:#123456'>" ++ fixture_note, "<table><tr><td>Received <img src='cid:picture@example.test'></td></tr></table>", "<!--[if mso]><v:rect fill='true'></v:rect><![endif]-->", "Sender &amp; &lt;friend&gt;", ">Subject:</strong> A &lt;table&gt; &amp; a picture", "width:680px!important;max-width:100%!important;margin:10px auto 16px!important;", "border-left:3px solid #b84a10!important;background:#f3f4f6!important;" }) |piece| try std.testing.expect(std.mem.indexOf(u8, result.html, piece) != null);
    inline for (.{ "From:", "Date:", "To:", "Cc:", "Subject:" }) |label| try std.testing.expect(std.mem.indexOf(u8, result.html, "<strong style=\"color:inherit!important;font-weight:bold!important\">" ++ label ++ "</strong> ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "windows-1252") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.html, utf8_meta));
    try std.testing.expect(std.mem.indexOf(u8, result.plain, "From: Sender & <friend> <sender@example.test>\nDate: Mon, 05 Oct 2026 12:00:00 +0000") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.plain, "Original plain text."));
}

test "original mail: fragments optional envelope tags and raw text get one document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "<p>Fragment <img src='https://example.test/picture.png'></p>",
        "<style>p{color:blue}</style><p>Fragment</p>",
        "<html><head><title>A &lt;body&gt; title</title></head><p>Implicit body</p></html>",
        "<html><head><style>p{color:blue}</style><body>Implicit head closer",
        "<body class='original'><p>Body fragment</p></body>",
        "<head><style>p{color:blue}</style></head><p>Head fragment</p>",
        "<script>const fake = '<html><body>'; const other = '</body>';</script><p>After script</p>",
        "<textarea>literal <html><body> text</textarea><p>After textarea</p>",
    }) |source| {
        const result = try prepare(a, fixtureNote(), fixtureOriginal(source));
        const envelope = try scan(result.html);
        try std.testing.expect(envelope.html_open != null and envelope.html_close != null);
        try std.testing.expect(envelope.head_open != null and envelope.head_close != null);
        try std.testing.expect(envelope.body_open != null and envelope.body_close != null);
        try std.testing.expectEqualStrings(logo_content_id, result.html[result.logoOffset..][0..logo_content_id.len]);
    }
    const no_html = try prepare(a, fixtureNote(), fixtureOriginal(""));
    try std.testing.expect(std.mem.indexOf(u8, no_html.html, ">Original plain text.</div>") != null);
}

test "original mail: ambiguous malformed and excessive envelopes fail without partial results" {
    for ([_][]const u8{
        "<html><body>One</body></html><html><body>Two</body></html>",
        "<html><body>One<body>Two</body></html>",
        "<p>Fragment</p><html><body>Another document</body></html>",
        "<style>p{color:red}</style><html><body>Another document</body></html>",
        "<html><body data-bad='unterminated>Body</body></html>",
        "<html><head><style>p{color:red}</head><body>Missing style closer</body></html>",
        "<html><body>Body</body><p>Unexpected trailing content</p></html>",
        "<!-- unclosed <html><body>",
        "</body></html>",
    }) |source| try std.testing.expectError(error.InvalidOriginalHtml, prepare(std.testing.allocator, fixtureNote(), fixtureOriginal(source)));
    try std.testing.expectError(error.OriginalHtmlUnavailable, validate(fixtureOriginal("<plaintext>Body")));
    var invalid = fixtureOriginal("<p>Fine</p>");
    invalid.subject = "Subject\r\nFrom: forged@example.test";
    try std.testing.expectError(error.InvalidOriginalHtml, validate(invalid));
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = std.testing.allocator, .limit = 64 };
    try std.testing.expectError(error.OutOfMemory, prepare(cap.allocator(), fixtureNote(), fixtureOriginal("<p>Original</p>")));
    try std.testing.expectEqual(@as(usize, 0), cap.used);
}

test "original mail: related resources stay borrowed and aggregate output remains bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resources = [_]t.Attachment{.{ .id = "part-2", .filename = "", .mimeType = "image/png", .size = 3, .data = "YWJj", .contentId = "picture@example.test", .disposition = "inline" }};
    var original = fixtureOriginal("<p><img src='cid:picture@example.test'></p>");
    original.resources = &resources;
    const result = try prepare(a, fixtureNote(), original);
    try std.testing.expect(result.resources.ptr == resources[0..].ptr);
    try std.testing.expectEqualStrings("YWJj", result.resources[0].data);
    const large = try a.alloc(u8, t.Limits.body_bytes);
    @memset(large, 'x');
    original.bodyText = large;
    try std.testing.expectError(error.RenderedBodyTooLarge, prepare(a, fixtureNote(), original));
    var too_many: Buffer = .{ .a = a };
    for (0..max_encoding_tags + 1) |_| try too_many.append("<meta charset='ascii'>");
    try std.testing.expectError(error.OriginalHtmlUnavailable, validate(fixtureOriginal(too_many.bytes.items)));
}

test "original mail: real CID references resolve attributes percent entities CSS and missing parts" {
    var original = fixtureOriginal("<style>/* url(cid:comment) */ p:before{content:'url(cid:literal)'} div{background:url('cid:p%40example.test')}</style><div style='background: url(&quot;c\\69 d:p&#64;example.test&quot;)'><img src='CID:p%40example.test'><img srcset='cid:p@example.test 1x, cid:p%40example.test 2x'><p>Literal cid:unattached is prose.</p></div>");
    original.resources = &.{.{ .id = "external-no-name", .filename = "", .mimeType = "image/png", .contentId = "p@example.test", .size = 3, .data = "YWJj" }};
    try validate(original);
    original.resources = &.{};
    try std.testing.expectError(error.OriginalResourceUnavailable, validate(original));
    for ([_][]const u8{
        "<img src='cid:missing@example.test'>",
        "<table background='cid:missing@example.test'><tr><td>Content</td></tr></table>",
        "<div style='background:url(cid:missing@example.test)'>Content</div>",
        "<style>div { background: url(cid:missing@example.test) }</style><div>Content</div>",
        "<img src='cid:bad%xx@example.test'>",
        "<div style='background:url(\\FFFFFF)'>Content</div>",
    }) |source| try std.testing.expectError(error.OriginalResourceUnavailable, validate(fixtureOriginal(source)));
    try validate(fixtureOriginal("<!-- <img src='cid:unattached'> --><script>const image = '<img src=cid:missing>';</script><p>cid:unattached</p><img src='https://example.test/cid:unattached'>"));
}

test "original mail: usage separates referenced images from ordinary CID attachments" {
    const resources = [_]t.Attachment{
        .{ .id = "pdf", .filename = "document.pdf", .mimeType = "application/pdf", .contentId = "ordinary@example.test", .disposition = "attachment" },
        .{ .id = "picture", .filename = "picture.png", .mimeType = "image/png", .contentId = "picture@example.test", .disposition = "attachment" },
        .{ .id = "background", .filename = "", .mimeType = "image/png", .contentId = "background@example.test", .disposition = "inline" },
        .{ .id = "located", .filename = "located.png", .mimeType = "image/png", .contentLocation = "https://example.test/image?a=1&b=2" },
        .{ .id = "ics", .filename = "event.ics", .mimeType = "text/calendar", .contentId = "event@example.test", .disposition = "attachment" },
        .{ .id = "comment", .filename = "comment.pdf", .mimeType = "application/pdf", .contentId = "comment@example.test", .disposition = "attachment" },
        .{ .id = "script", .filename = "script.png", .mimeType = "image/png", .contentId = "script@example.test" },
    };
    const html = "<style>/* url(cid:ordinary@example.test) */ .literal:before{content:'url(cid:event@example.test)'} .back{background:url('c\\69 d:background%40example.test')}</style>" ++
        "<img src='CID:picture&#64;example.test'><img srcset='cid:picture%40example.test 1x, cid:picture@example.test 2x'>" ++
        "<div style='background:url(&quot;cid:background%40example.test&quot;)'>Body</div>" ++
        "<img src='https://example.test/image?a=1&amp;b=2'>" ++
        "<p>cid:ordinary@example.test and cid:event@example.test are prose. &lt;img src='cid:ordinary@example.test'&gt;</p>" ++
        "<!-- <img src='cid:comment@example.test'> --><script>const image = '<img src=cid:script@example.test>';</script>";
    try std.testing.expectEqual(@as(u64, 0b0001110), try resourceUsage(html, &resources));
    try std.testing.expectEqual(@as(u64, 0), try resourceUsage("<p>cid:picture@example.test</p>", &resources));
    try std.testing.expectError(error.OriginalResourceUnavailable, resourceUsage("<img src='cid:missing@example.test'>", &resources));
    // The classification helper keeps duplicates visible for backend rejection.
    const duplicates = [_]t.Attachment{ resources[1], resources[1] };
    try std.testing.expectEqual(@as(u64, 3), try resourceUsage("<img src='cid:picture@example.test'>", &duplicates));
}

test "original mail: usage bitset is bounded and includes the final resource slot" {
    var resources: [65]t.Attachment = @splat(.{ .id = "part", .filename = "part.bin" });
    resources[63].contentId = "last@example.test";
    try std.testing.expectEqual(@as(u64, 1) << 63, try resourceUsage("<img src='cid:last@example.test'>", resources[0..64]));
    try std.testing.expectError(error.TooManyAttachments, resourceUsage("", &resources));
    try std.testing.expectError(error.InvalidOriginalHtml, resourceUsage("<html><body>A</body></html><html><body>B</body></html>", &.{}));
}
