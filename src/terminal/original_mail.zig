//! Outbound assembly of an immutable original and a separately authored note.
//! Original HTML is opaque mail data: no CSS evaluation, resource loading or
//! semantic-reader sanitization occurs here. Only its document envelope and
//! encoding declarations are inspected. Every output allocation is caller-owned.
const std = @import("std");
const t = @import("types.zig");
const mail_limits = @import("mail_limits.zig");

pub const Note = struct { html: []const u8, plain: []const u8, logoOffset: usize };
pub const Prepared = struct { html: []const u8, plain: []const u8, logoOffset: usize, resources: []const t.Attachment };
const logo_content_id = "omagma-logo@omagma.invalid";
const max_tag_bytes = 16384;
const max_root_attributes = 256;
const max_scope_depth = 64;
const utf8_meta = "<meta charset=\"utf-8\">";
const Span = struct { start: usize, end: usize };

const Buffer = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn append(self: *Buffer, value: []const u8) !void {
        if (value.len > t.Limits.compose_body_bytes - self.bytes.items.len) return error.RenderedBodyTooLarge;
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

/// Checks bounded source text and a safe insertion point, not HTML validity. Resource bytes,
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
pub const ResourceUsage = std.StaticBitSet(t.Limits.message_attachments);

pub fn resourceUsage(html: []const u8, resources: []const t.Attachment) !ResourceUsage {
    if (resources.len > t.Limits.message_attachments) return error.TooManyAttachments;
    try bodyText(html);
    var used: ResourceUsage = .empty;
    try scanReferences(html, resources, &used);
    return used;
}

pub const ResourcePlan = struct {
    indices: [t.Limits.related_resources]usize = undefined,
    count: usize = 0,
    bytes: usize = 0,
};

/// Metadata-only preflight shared by the format chooser and fresh capture.
/// No allocation, file access or resource download occurs here. Explicit files
/// are retained as related resources only when HTML actually references them;
/// other identified resources are retained for opaque conditional markup too.
/// Portable adapters keep the 2 MiB decoded aggregate limit. Inline resources
/// have their own count budget, independent of ordinary outgoing file slots.
pub fn resourcePlan(html: []const u8, attachments: []const t.Attachment) !ResourcePlan {
    return resourcePlanWithLimit(html, attachments, t.Limits.body_bytes);
}

/// Native adapters can retain larger resources in verified private blobs;
/// portable adapters explicitly keep the smaller embedded-byte allowance.
pub fn resourcePlanWithLimit(html: []const u8, attachments: []const t.Attachment, byte_limit: usize) !ResourcePlan {
    if (html.len == 0) return error.OriginalHtmlUnavailable;
    const usage = try resourceUsage(html, attachments);
    _ = try scan(html, null);
    var plan: ResourcePlan = .{};
    for (attachments, 0..) |attachment, index| {
        const is_file = if (attachment.disposition) |value| std.ascii.eqlIgnoreCase(value, "attachment") else false;
        const referenced = usage.isSet(index);
        const has_identity = attachment.contentId != null or attachment.contentLocation != null;
        if (!has_identity or (is_file and !referenced)) continue;
        if (plan.count == plan.indices.len) return error.TooManyAttachments;
        plan.bytes = std.math.add(usize, plan.bytes, attachment.size) catch return error.AttachmentsTooLarge;
        if (plan.bytes > @min(byte_limit, t.Limits.attachment_bytes)) return error.AttachmentsTooLarge;
        if (attachment.contentId) |id| {
            _ = try @import("mime.zig").contentId(id);
            for (plan.indices[0..plan.count]) |previous| if (attachments[previous].contentId) |other| if (std.mem.eql(u8, id, other)) return error.AmbiguousContentId;
        }
        if (attachment.contentLocation) |location| {
            for (plan.indices[0..plan.count]) |previous| if (attachments[previous].contentLocation) |other| if (std.mem.eql(u8, location, other)) return error.AmbiguousContentId;
        }
        plan.indices[plan.count] = index;
        plan.count += 1;
    }
    return plan;
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
    // Splice into the received bytes, without appending a doctype or closing
    // tags. The recipient retains the same quirks mode and recovery of tails,
    // repeated envelopes and incomplete body markup that it already had.
    try envelope.copy(&html, input, 0, envelope.meta_at);
    try html.append(utf8_meta);
    const body_start = envelope.note_at;
    try envelope.copy(&html, input, envelope.meta_at, body_start);
    const logo_offset = html.bytes.items.len + note.logoOffset;
    try html.append(note.html);
    try htmlHeaders(&html, original);
    if (input.len == 0) {
        try html.append("<div style=\"white-space:pre-wrap;overflow-wrap:anywhere\">");
        try html.escaped(original.bodyText);
        try html.append("</div>");
    } else try envelope.copy(&html, input, body_start, input.len);
    const plain_result = try plain.bytes.toOwnedSlice(a);
    errdefer a.free(plain_result);
    return .{ .html = try html.bytes.toOwnedSlice(a), .plain = plain_result, .logoOffset = logo_offset, .resources = original.resources };
}

fn bodyText(value: []const u8) !void {
    if (value.len > t.Limits.compose_body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidOriginalHtml;
}
fn summaryText(value: []const u8, limit: usize) !void {
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return error.InvalidOriginalHtml;
    for (value) |c| if ((c < 32 and c != '\t') or c == 127) return error.InvalidOriginalHtml;
}
fn mailbox(value: t.Address) !void {
    try summaryText(value.address, mail_limits.incoming_address_bytes);
    try summaryText(value.name, mail_limits.display_name_bytes);
}
fn inspect(original: t.Original) !Envelope {
    if (original.version != 1) return error.OriginalHtmlUnavailable;
    try bodyText(original.bodyText);
    try bodyText(original.bodyHtml);
    try summaryText(original.sourceMessageId, 1024);
    try summaryText(original.subject, mail_limits.subject_bytes);
    try summaryText(original.date, 1024);
    try mailbox(original.from);
    if (original.to.len > mail_limits.incoming_recipients or original.cc.len > mail_limits.incoming_recipients) return error.InvalidOriginalHtml;
    for (original.to) |address| try mailbox(address);
    for (original.cc) |address| try mailbox(address);
    const envelope = try scan(original.bodyHtml, null);
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
    meta_at: usize = 0,
    note_at: usize = 0,

    fn copy(self: *const Envelope, out: *Buffer, input: []const u8, start: usize, end: usize) !void {
        _ = self;
        if (start > end or end > input.len) return error.InvalidOriginalHtml;
        if (start == end) return;
        // Scan the same context again and stream removals, so repeated quoted
        // documents cannot overflow a tiny fixed charset-tag table. Each pass
        // advances through byte-bounded input; no source bytes are modified.
        var range: CopyRange = .{ .out = out, .input = input, .start = start, .end = end, .offset = start };
        _ = try scan(input, &range);
        try out.append(input[range.offset..end]);
    }
};
const CopyRange = struct {
    out: *Buffer,
    input: []const u8,
    start: usize,
    end: usize,
    offset: usize,
    fn omitEncoding(self: *CopyRange, tag: Span) !void {
        if (tag.end <= self.start or tag.start >= self.end) return;
        if (tag.start < self.offset or tag.end > self.end) return error.InvalidOriginalHtml;
        try self.out.append(self.input[self.offset..tag.start]);
        self.offset = tag.end;
    }
};

const Attribute = struct { name: []const u8, value: []const u8, raw: []const u8 };
/// The same attribute states delimit tags, read URLs and recognize charset
/// metadata. A quote starts a quoted value only immediately after '=' and
/// optional whitespace; quotes/'<' in names or unquoted values stay literal.
/// https://html.spec.whatwg.org/multipage/parsing.html#before-attribute-name-state
/// https://html.spec.whatwg.org/multipage/parsing.html#attribute-value-(unquoted)-state
const AttributeIterator = struct {
    input: []const u8,
    offset: usize = 0,
    end: ?usize = null,
    self_closing: bool = false,

    fn next(self: *AttributeIterator) ?Attribute {
        const input = self.input;
        while (self.offset < input.len) {
            while (self.offset < input.len and white(input[self.offset])) self.offset += 1;
            if (self.offset == input.len) return null;
            if (input[self.offset] == '>') {
                self.offset += 1;
                self.end = self.offset;
                return null;
            }
            if (input[self.offset] == '/') {
                self.offset += 1;
                self.self_closing = self.offset < input.len and input[self.offset] == '>';
                continue;
            }
            const start = self.offset;
            // An initial '=' is itself part of an erroneous attribute name.
            if (input[self.offset] == '=') self.offset += 1;
            while (self.offset < input.len and !white(input[self.offset]) and input[self.offset] != '=' and input[self.offset] != '/' and input[self.offset] != '>') self.offset += 1;
            const name = input[start..self.offset];
            const name_end = self.offset;
            while (self.offset < input.len and white(input[self.offset])) self.offset += 1;
            if (self.offset == input.len or input[self.offset] != '=') return .{ .name = name, .value = "", .raw = input[start..name_end] };
            self.offset += 1;
            while (self.offset < input.len and white(input[self.offset])) self.offset += 1;
            var value: []const u8 = "";
            if (self.offset < input.len and (input[self.offset] == '\'' or input[self.offset] == '"')) {
                const quote = input[self.offset];
                self.offset += 1;
                const value_start = self.offset;
                while (self.offset < input.len and input[self.offset] != quote) self.offset += 1;
                value = input[value_start..self.offset];
                if (self.offset < input.len) self.offset += 1;
            } else {
                const value_start = self.offset;
                while (self.offset < input.len and !white(input[self.offset]) and input[self.offset] != '>') self.offset += 1;
                value = input[value_start..self.offset];
            }
            return .{ .name = name, .value = value, .raw = input[start..self.offset] };
        }
        return null;
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
        var attributes: AttributeIterator = .{ .input = self.attributes };
        while (attributes.next()) |attr| {
            if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
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
    // These abrupt comment starts terminate in HTML's comment-start states.
    if (std.mem.startsWith(u8, input[start..], "<!-->")) return start + 5;
    if (std.mem.startsWith(u8, input[start..], "<!--->")) return start + 6;
    var i = start + 4;
    while (i < input.len) : (i += 1) {
        if (std.mem.startsWith(u8, input[i..], "-->")) return i + 3;
        if (std.mem.startsWith(u8, input[i..], "--!>")) return i + 4;
    }
    return error.InvalidOriginalHtml;
}
fn declarationAt(input: []const u8, start: usize, doctype: bool) !Tag {
    // Bogus comments and HTML doctypes terminate at '>', including a '>'
    // encountered in an abruptly closed doctype identifier. XML DTD bracket
    // nesting and ordinary attribute quoting do not apply to these tokens.
    const limit = @min(input.len, start + max_tag_bytes);
    const end = std.mem.indexOfScalarPos(u8, input[0..limit], start + 2, '>') orelse {
        if (limit - start == max_tag_bytes) return error.OriginalHtmlUnavailable;
        return error.InvalidOriginalHtml;
    };
    return .{ .span = .{ .start = start, .end = end + 1 }, .name = if (doctype) "doctype" else "", .declaration = true };
}
fn tagAt(input: []const u8, start: usize) !?Tag {
    var i = start + 1;
    if (i == input.len) return null;
    if (input[i] == '!' or input[i] == '?') {
        return try declarationAt(input, start, std.ascii.startsWithIgnoreCase(input[start..], "<!doctype"));
    }
    var closing = false;
    if (input[i] == '/') {
        closing = true;
        i += 1;
    }
    if (i == input.len) return null;
    if (!std.ascii.isAlphabetic(input[i])) {
        if (closing) return try declarationAt(input, start, false);
        return null;
    }
    const limit = @min(input.len, start + max_tag_bytes);
    const name_start = i;
    // Punctuation and non-ASCII bytes after an ASCII initial letter are tag
    // name characters, not a new envelope or quote state (e.g. <body=broken>).
    while (i < limit and !white(input[i]) and input[i] != '/' and input[i] != '>') i += 1;
    const name = input[name_start..i];
    var attributes: AttributeIterator = .{ .input = input[i..limit] };
    var count: usize = 0;
    while (attributes.next() != null) {
        if (count == max_root_attributes) return error.OriginalHtmlUnavailable;
        count += 1;
    }
    const end = attributes.end orelse {
        if (limit - start == max_tag_bytes) return error.OriginalHtmlUnavailable;
        return error.InvalidOriginalHtml;
    };
    return .{ .span = .{ .start = start, .end = i + end }, .name = name, .attributes = input[i .. i + end - 1], .closing = closing, .self_closing = attributes.self_closing };
}
fn headTag(tag: Tag) bool {
    if (tag.closing) return false;
    for ([_][]const u8{ "meta", "base", "basefont", "bgsound", "link", "style", "script", "title", "noscript", "noframes", "template" }) |name| if (tag.is(name)) return true;
    return false;
}
fn rawTag(tag: Tag) bool {
    if (tag.closing) return false;
    for ([_][]const u8{ "style", "script", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "noscript" }) |name| if (tag.is(name)) return true;
    return false;
}
fn rawCloserAt(input: []const u8, start: usize, name: []const u8) !?Tag {
    if (!std.mem.startsWith(u8, input[start..], "</")) return null;
    const name_start = start + 2;
    if (name.len > input.len - name_start or !std.ascii.eqlIgnoreCase(input[name_start..][0..name.len], name)) return null;
    const end = name_start + name.len;
    if (end < input.len and !white(input[end]) and input[end] != '/' and input[end] != '>') return null;
    return try tagAt(input, start);
}
fn scriptClose(input: []const u8, tag: Tag) !Tag {
    // Only HTML script-data escape states matter; JS strings/comments never
    // decide HTML boundaries. No script is interpreted or executed here.
    const State = enum { data, escaped, double_escaped };
    var state: State = .data;
    var i = tag.span.end;
    while (i < input.len) {
        if (state == .data and std.mem.startsWith(u8, input[i..], "<!--")) {
            state = .escaped;
            i += 4;
        } else if (state != .data and std.mem.startsWith(u8, input[i..], "-->")) {
            state = .data;
            i += 3;
        } else if (input[i] == '<') {
            const closing_name = std.ascii.startsWithIgnoreCase(input[i..], "</script") and
                (i + 8 == input.len or (i + 8 < input.len and (white(input[i + 8]) or input[i + 8] == '/' or input[i + 8] == '>')));
            if (state == .double_escaped and closing_name) {
                state = .escaped;
                i += 8; // '</script' switches state; it is still source text.
            } else if (try rawCloserAt(input, i, "script")) |closer| {
                return closer;
            } else if (state == .escaped and std.ascii.startsWithIgnoreCase(input[i..], "<script") and
                i + 7 < input.len and (white(input[i + 7]) or input[i + 7] == '/' or input[i + 7] == '>'))
            {
                state = .double_escaped;
                i += 7;
            } else i += 1;
        } else i += 1;
    }
    return error.InvalidOriginalHtml;
}
fn rawClose(input: []const u8, tag: Tag) !Tag {
    if (tag.is("script")) return scriptClose(input, tag);
    var offset = tag.span.end;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |start| {
        offset = start + 1;
        if (try rawCloserAt(input, start, tag.name)) |closer| return closer;
    }
    return error.InvalidOriginalHtml;
}
fn rawEnd(input: []const u8, tag: Tag) !usize {
    return (try rawClose(input, tag)).span.end;
}
fn cdataEnd(input: []const u8, start: usize) !usize {
    const end = std.mem.indexOfPos(u8, input, start + 9, "]]>") orelse return error.InvalidOriginalHtml;
    return end + 3;
}
fn templateEnd(input: []const u8, opener: Tag) !usize {
    var depth: usize = 1;
    var foreign_depth: usize = 0;
    var offset = opener.span.end;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |start| {
        if (std.mem.startsWith(u8, input[start..], "<!--")) {
            offset = try commentEnd(input, start);
            continue;
        }
        if (foreign_depth != 0 and std.mem.startsWith(u8, input[start..], "<![CDATA[")) {
            offset = try cdataEnd(input, start);
            continue;
        }
        const tag = try tagAt(input, start) orelse {
            offset = start + 1;
            continue;
        };
        offset = tag.span.end;
        if (tag.declaration) continue;
        if (tag.is("template")) {
            if (tag.closing) {
                depth -= 1;
                if (depth == 0) return offset;
            } else {
                if (depth == max_scope_depth) return error.OriginalHtmlUnavailable;
                depth += 1;
            }
        }
        if (tag.is("svg") or tag.is("math")) {
            if (tag.closing) foreign_depth -|= 1 else if (!tag.self_closing) {
                if (foreign_depth == max_scope_depth) return error.OriginalHtmlUnavailable;
                foreign_depth += 1;
            }
        }
        if (tag.is("plaintext") and !tag.closing) return error.OriginalHtmlUnavailable;
        if (foreign_depth == 0 and rawTag(tag)) offset = try rawEnd(input, tag);
    }
    return error.InvalidOriginalHtml;
}

/// Find a safe note insertion boundary, not a conforming HTML document.
/// Received envelopes and body bytes pass through; browser recovery still
/// handles duplicate roots/bodies, omitted tags and content after their ends.
fn scan(input: []const u8, copy: ?*CopyRange) !Envelope {
    var result: Envelope = .{};
    const Phase = enum { before_head, in_head, after_head, body };
    var phase: Phase = .before_head;
    var meta_at: ?usize = null;
    var note_at: ?usize = null;
    var offset: usize = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) 3 else 0;
    var foreign_depth: usize = 0;
    while (offset < input.len) {
        if (std.mem.startsWith(u8, input[offset..], "<!--")) {
            offset = commentEnd(input, offset) catch |err| {
                if (note_at != null and err == error.InvalidOriginalHtml) break;
                return if (err == error.InvalidOriginalHtml) error.OriginalHtmlUnavailable else err;
            };
            continue;
        }
        if (foreign_depth != 0 and std.mem.startsWith(u8, input[offset..], "<![CDATA[")) {
            offset = cdataEnd(input, offset) catch |err| {
                if (note_at != null and err == error.InvalidOriginalHtml) break;
                return if (err == error.InvalidOriginalHtml) error.OriginalHtmlUnavailable else err;
            };
            continue;
        }
        if (input[offset] != '<') {
            const end = std.mem.indexOfScalarPos(u8, input, offset, '<') orelse input.len;
            if (note_at == null and !blank(input[offset..end])) {
                note_at = offset;
                if (meta_at == null) meta_at = offset;
                phase = .body;
            }
            offset = end;
            continue;
        }
        const tag = (tagAt(input, offset) catch |err| {
            if (note_at != null and err == error.InvalidOriginalHtml) break;
            return if (err == error.InvalidOriginalHtml) error.OriginalHtmlUnavailable else err;
        }) orelse {
            if (note_at == null) {
                note_at = offset;
                if (meta_at == null) meta_at = offset;
                phase = .body;
            }
            offset += 1;
            continue;
        };
        offset = tag.span.end;
        if (tag.declaration) continue;
        if (tag.is("html")) {
            if (tag.closing and note_at == null) {
                note_at = tag.span.start;
                if (meta_at == null) meta_at = tag.span.start;
                phase = .body;
            }
            continue;
        }
        if (tag.is("head")) {
            if (note_at == null) {
                if (tag.closing) {
                    if (meta_at == null) meta_at = tag.span.start;
                    phase = .after_head;
                } else if (phase == .before_head) {
                    meta_at = tag.span.end;
                    phase = .in_head;
                }
            }
            continue;
        }
        if (tag.is("body")) {
            if (note_at == null) {
                if (meta_at == null) meta_at = tag.span.start;
                note_at = if (tag.closing) tag.span.start else tag.span.end;
                phase = .body;
            }
            continue;
        }
        if (tag.is("plaintext") or tag.is("frameset") or tag.is("frame")) return error.OriginalHtmlUnavailable;
        if (note_at == null and !tag.closing) {
            if (headTag(tag)) {
                if (meta_at == null) meta_at = tag.span.start;
                if (phase == .before_head) phase = .in_head;
            } else {
                if (meta_at == null) meta_at = tag.span.start;
                note_at = tag.span.start;
                phase = .body;
            }
        } else if (note_at == null and tag.is("br")) {
            if (meta_at == null) meta_at = tag.span.start;
            note_at = tag.span.start;
            phase = .body;
        }
        if (tag.is("template") and !tag.closing) {
            offset = templateEnd(input, tag) catch |err| {
                if (note_at != null and err == error.InvalidOriginalHtml) break;
                return if (err == error.InvalidOriginalHtml) error.OriginalHtmlUnavailable else err;
            };
            continue;
        }
        if (tag.is("svg") or tag.is("math")) {
            if (tag.closing) foreign_depth -|= 1 else if (!tag.self_closing) {
                if (foreign_depth == max_scope_depth) return error.OriginalHtmlUnavailable;
                foreign_depth += 1;
            }
        }
        if (foreign_depth != 0) continue;
        if (tag.is("meta") and !tag.closing) {
            const http_equiv = tag.attribute("http-equiv") orelse "";
            if (tag.attribute("charset") != null or std.ascii.eqlIgnoreCase(std.mem.trim(u8, http_equiv, " \t\r\n"), "content-type")) {
                if (copy) |range| try range.omitEncoding(tag.span);
            }
        }
        if (rawTag(tag)) {
            offset = rawEnd(input, tag) catch |err| {
                if (note_at != null and err == error.InvalidOriginalHtml) break;
                return if (err == error.InvalidOriginalHtml) error.OriginalHtmlUnavailable else err;
            };
        }
    }
    result.meta_at = meta_at orelse input.len;
    result.note_at = note_at orelse input.len;
    return result;
}

/// Scan URL-bearing markup only: prose/code containing "cid:" is not a
/// reference. Comments remain opaque, including Outlook conditional markup;
/// all captured related resources are still retained for those clients.
fn validateReferences(input: []const u8, resources: []const t.Attachment) !void {
    try scanReferences(input, resources, null);
}

/// Borrowed sorted metadata keeps reference lookup logarithmic even when an
/// accumulated chain repeats every old screenshot many times. No HTML or
/// identity is rewritten; duplicate identities remain visible to validation.
const ResourceLookup = struct {
    const Identity = enum { contentId, contentLocation };
    resources: []const t.Attachment,
    ids: [t.Limits.message_attachments]usize = undefined,
    id_count: usize = 0,
    locations: [t.Limits.message_attachments]usize = undefined,
    location_count: usize = 0,
    seen_ids: ResourceUsage = .empty,
    seen_locations: ResourceUsage = .empty,

    fn init(resources: []const t.Attachment) !ResourceLookup {
        if (resources.len > t.Limits.message_attachments) return error.TooManyAttachments;
        var result: ResourceLookup = .{ .resources = resources };
        for (resources, 0..) |resource, index| {
            if (resource.contentId != null) {
                result.ids[result.id_count] = index;
                result.id_count += 1;
            }
            if (resource.contentLocation != null) {
                result.locations[result.location_count] = index;
                result.location_count += 1;
            }
        }
        result.sort(.contentId, result.ids[0..result.id_count]);
        result.sort(.contentLocation, result.locations[0..result.location_count]);
        return result;
    }

    fn sort(self: *const ResourceLookup, comptime kind: Identity, indices: []usize) void {
        const Order = struct {
            fn less(resources: []const t.Attachment, first: usize, second: usize) bool {
                return std.mem.lessThan(u8, @field(resources[first], @tagName(kind)).?, @field(resources[second], @tagName(kind)).?);
            }
        };
        std.mem.sort(usize, indices, self.resources, Order.less);
    }

    fn mark(self: *ResourceLookup, comptime kind: Identity, value: []const u8, used: ?*ResourceUsage) bool {
        const indices = switch (kind) {
            .contentId => self.ids[0..self.id_count],
            .contentLocation => self.locations[0..self.location_count],
        };
        var low: usize = 0;
        var high = indices.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (std.mem.lessThan(u8, @field(self.resources[indices[mid]], @tagName(kind)).?, value)) low = mid + 1 else high = mid;
        }
        if (low == indices.len or !std.mem.eql(u8, @field(self.resources[indices[low]], @tagName(kind)).?, value)) return false;
        if (used) |bits| {
            // Mark every duplicate on the first occurrence. A repeated URL
            // must not repeatedly walk a malicious duplicate-identity group.
            const seen = switch (kind) {
                .contentId => &self.seen_ids,
                .contentLocation => &self.seen_locations,
            };
            if (!seen.isSet(indices[low])) {
                seen.set(indices[low]);
                while (low < indices.len and std.mem.eql(u8, @field(self.resources[indices[low]], @tagName(kind)).?, value)) : (low += 1) bits.set(indices[low]);
            }
        }
        return true;
    }
};

fn scanReferences(input: []const u8, resources: []const t.Attachment, used: ?*ResourceUsage) !void {
    var lookup = try ResourceLookup.init(resources);
    var offset: usize = 0;
    var foreign_depth: usize = 0;
    var decoded: [max_tag_bytes]u8 = undefined;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |start| {
        if (std.mem.startsWith(u8, input[start..], "<!--")) {
            offset = commentEnd(input, start) catch |err| {
                if (err == error.InvalidOriginalHtml) break; // The remaining source is comment text.
                return err;
            };
            continue;
        }
        if (foreign_depth != 0 and std.mem.startsWith(u8, input[start..], "<![CDATA[")) {
            offset = cdataEnd(input, start) catch |err| {
                if (err == error.InvalidOriginalHtml) break;
                return err;
            };
            continue;
        }
        const tag = (tagAt(input, start) catch |err| {
            if (err == error.InvalidOriginalHtml) break; // An unfinished tag is not emitted by HTML.
            return err;
        }) orelse {
            offset = start + 1;
            continue;
        };
        offset = tag.span.end;
        if (tag.declaration) continue;
        if (tag.is("svg") or tag.is("math")) {
            if (tag.closing) foreign_depth -|= 1 else if (!tag.self_closing) {
                if (foreign_depth == max_scope_depth) return error.OriginalHtmlUnavailable;
                foreign_depth += 1;
            }
        }
        if (tag.closing) continue;
        for ([_][]const u8{ "src", "href", "background", "poster", "data", "xlink:href", "lowsrc" }) |name| {
            if (tag.attribute(name)) |raw| try checkUrl(try htmlAttribute(raw, &decoded), &lookup, used);
        }
        if (tag.attribute("srcset")) |raw| {
            var candidates = std.mem.splitScalar(u8, try htmlAttribute(raw, &decoded), ',');
            while (candidates.next()) |candidate| {
                const value = std.mem.trim(u8, candidate, " \t\r\n");
                const end = std.mem.indexOfAny(u8, value, " \t\r\n") orelse value.len;
                try checkUrl(value[0..end], &lookup, used);
            }
        }
        if (tag.attribute("style")) |raw| try cssReferences(try htmlAttribute(raw, &decoded), &lookup, used);
        if (foreign_depth == 0 and rawTag(tag)) {
            const closer = rawClose(input, tag) catch |err| {
                if (err != error.InvalidOriginalHtml) return err;
                if (tag.is("style")) try cssReferences(input[tag.span.end..], &lookup, used);
                break;
            };
            if (tag.is("style")) try cssReferences(input[tag.span.end..closer.span.start], &lookup, used);
            offset = closer.span.end;
        }
    }
}
fn hex(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}
fn checkUrl(raw: []const u8, lookup: *ResourceLookup, used: ?*ResourceUsage) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(value, "cid:")) {
        if (value.len != 0) _ = lookup.mark(.contentLocation, value, used);
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
    if (lookup.mark(.contentId, buffer[0..n], used)) return;
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
const CssString = struct { end: usize, closed: bool };
fn cssEscapeEnd(input: []const u8, start: usize) usize {
    var i = start + 1;
    if (i == input.len) return i;
    if (hex(input[i]) != null) {
        var count: usize = 0;
        while (i < input.len and count < 6 and hex(input[i]) != null) : (count += 1) i += 1;
        if (i < input.len and white(input[i])) {
            if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') i += 1;
            i += 1;
        }
        return i;
    }
    if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') i += 1;
    return i + 1;
}
fn cssStringEnd(input: []const u8, start: usize) CssString {
    const quote = input[start];
    var i = start + 1;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\') {
            i = cssEscapeEnd(input, i) - 1;
        } else if (input[i] == quote) return .{ .end = i + 1, .closed = true } else if (input[i] == '\n' or input[i] == '\r' or input[i] == 12) return .{ .end = i + 1, .closed = false };
    }
    return .{ .end = input.len, .closed = false };
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
        // CSS replaces invalid escaped code points rather than invalidating HTML.
        if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) cp = 0xfffd;
        const count = std.unicode.utf8Encode(@intCast(cp), &encoded) catch unreachable;
        if (count > out.len - n) return error.OriginalHtmlUnavailable;
        @memcpy(out[n..][0..count], encoded[0..count]);
        n += count;
    }
    return out[0..n];
}
fn badCssUrlEnd(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == ')') return i + 1;
        if (input[i] == '\\' and i + 1 < input.len) i += 1;
    }
    return input.len;
}
fn cssReferences(input: []const u8, lookup: *ResourceLookup, used: ?*ResourceUsage) !void {
    // CSS syntax errors are not HTML splice errors. Ignore discarded/unfinished
    // CSS tokens, but require resources for recognized URLs. In particular, do
    // not mark unrelated CID attachments as used merely because CSS is broken.
    var i: usize = 0;
    var decoded: [max_tag_bytes]u8 = undefined;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, input, i + 2, "*/") orelse return;
            i = end + 2;
            continue;
        }
        if (input[i] == '\'' or input[i] == '"') {
            i = cssStringEnd(input, i).end;
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
        if (next == input.len) return;
        var value: []const u8 = undefined;
        if (input[next] == '\'' or input[next] == '"') {
            const string = cssStringEnd(input, next);
            if (!string.closed) {
                i = string.end;
                continue;
            }
            value = input[next + 1 .. string.end - 1];
            next = string.end;
            while (next < input.len and white(input[next])) next += 1;
            if (next < input.len and input[next] != ')') {
                i = badCssUrlEnd(input, next);
                continue;
            }
        } else {
            const start = next;
            var had_space = false;
            var bad = false;
            while (next < input.len and input[next] != ')') : (next += 1) {
                const c = input[next];
                if (white(c)) {
                    had_space = true;
                    continue;
                }
                if (had_space or c == '\'' or c == '"' or c == '(' or c < 32 or c == 127) bad = true;
                if (c == '\\') {
                    if (next + 1 == input.len or input[next + 1] == '\n' or input[next + 1] == '\r' or input[next + 1] == 12) {
                        bad = true;
                    } else next = cssEscapeEnd(input, next) - 1;
                }
            }
            if (bad) {
                i = if (next < input.len) next + 1 else input.len;
                continue;
            }
            value = std.mem.trimEnd(u8, input[start..next], " \t\r\n");
        }
        try checkUrl(try cssUrl(value, &decoded), lookup, used);
        i = if (next < input.len) next + 1 else input.len;
    }
}

fn fixtureOriginal(html: []const u8) t.Original {
    return .{ .sourceMessageId = "synthetic-source", .from = .{ .address = "sender@example.test", .name = "Sender & <friend>" }, .to = &.{.{ .address = "recipient@example.test" }}, .subject = "A <table> & a picture", .date = "Mon, 05 Oct 2026 12:00:00 +0000", .bodyText = "Original plain text.", .bodyHtml = html };
}

fn expectUsage(expected: []const usize, actual: ResourceUsage) !void {
    try std.testing.expectEqual(expected.len, actual.count());
    for (expected) |index| try std.testing.expect(actual.isSet(index));
}
const fixture_note = "<div>New note<img src=\"cid:omagma-logo@omagma.invalid\"></div>";
fn fixtureNote() Note {
    return .{ .html = fixture_note, .plain = "New note", .logoOffset = std.mem.indexOf(u8, fixture_note, logo_content_id).? };
}

test "mail metadata: original snapshots preserve received participant and display limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const participants = try a.alloc(t.Address, mail_limits.incoming_recipients + 1);
    for (participants, 0..) |*address, index| address.* = .{ .address = try std.fmt.allocPrint(a, "member{d}@example.test", .{index}) };
    const name: [mail_limits.display_name_bytes]u8 = @splat('n');
    const subject: [mail_limits.subject_bytes]u8 = @splat('s');
    var original = fixtureOriginal("<p>Preserved source</p>");
    original.from.name = &name;
    original.subject = &subject;
    original.to = participants[0..mail_limits.incoming_recipients];
    original.cc = participants[0..65];
    try validate(original);
    const rendered = try prepare(a, fixtureNote(), original);
    try std.testing.expect(std.mem.indexOf(u8, rendered.plain, "member1023@example.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.plain, &subject) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, &name) != null);
    original.to = participants;
    try std.testing.expectError(error.InvalidOriginalHtml, validate(original));
}

test "original mail: resource plan separates unloaded file metadata from bounded preserved resources" {
    const html = "<p>Original</p><img src='cid:photo@example.test'>";
    const resources = [_]t.Attachment{
        .{ .id = "file", .filename = "report.pptx", .size = 30 * 1024 * 1024, .contentId = "unused@example.test", .contentLocation = "report.pptx", .disposition = "attachment" },
        .{ .id = "photo", .filename = "photo.png", .size = 14 * 1024, .contentId = "photo@example.test", .disposition = "inline" },
    };
    const eligible = try resourcePlan(html, &resources);
    try std.testing.expectEqual(@as(usize, 1), eligible.count);
    try std.testing.expectEqual(@as(usize, 1), eligible.indices[0]);
    try std.testing.expectEqual(@as(usize, 14 * 1024), eligible.bytes);
    var photo = resources[1];
    photo.size = 2 * 1024 * 1024;
    try std.testing.expectEqual(photo.size, (try resourcePlan(html, &.{photo})).bytes);
    photo.size = 5 * 1024 * 1024;
    try std.testing.expectError(error.AttachmentsTooLarge, resourcePlan(html, &.{photo}));
    try std.testing.expectEqual(photo.size, (try resourcePlanWithLimit(html, &.{photo}, t.Limits.attachment_bytes)).bytes);
    photo.size = t.Limits.attachment_bytes + 1;
    try std.testing.expectError(error.AttachmentsTooLarge, resourcePlanWithLimit(html, &.{photo}, t.Limits.attachment_bytes));
    // A large explicit file becomes a resource when referenced, so it cannot
    // evade the preservation limit merely by using attachment disposition.
    try std.testing.expectError(error.AttachmentsTooLarge, resourcePlan("<img src='report.pptx'>", &resources));
    var many: [t.Limits.related_resources + 1]t.Attachment = @splat(.{ .id = "conditional", .filename = "conditional.png", .size = 8, .disposition = "inline" });
    var locations: [t.Limits.related_resources + 1][24]u8 = undefined;
    for (&many, 0..) |*item, index| {
        item.contentLocation = try std.fmt.bufPrint(&locations[index], "part-{d}.png", .{index});
    }
    try std.testing.expectEqual(t.Limits.related_resources, (try resourcePlan("<p>Conditional resources</p>", many[0..t.Limits.related_resources])).count);
    try std.testing.expectError(error.TooManyAttachments, resourcePlan("<p>Conditional resources</p>", &many));
    try std.testing.expectError(error.OriginalResourceUnavailable, resourcePlan("<img src='cid:missing@example.test'>", &resources));
    try std.testing.expectError(error.AmbiguousContentId, resourcePlan(html, &.{ resources[1], resources[1] }));
    try std.testing.expectError(error.AmbiguousContentId, resourcePlan("<p>Original</p>", &.{ many[0], many[0] }));
    photo.size = 1;
    photo.contentId = "invalid cid";
    try std.testing.expectError(error.InvalidContentId, resourcePlan("<p>Original</p>", &.{photo}));
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

test "original mail: fragments optional envelopes and raw text retain their receiver parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = .{
        .{ "<p>Fragment <img src='https://example.test/picture.png'></p>", "<p>Fragment" },
        .{ "<style>p{color:blue}</style><p>Fragment</p>", "<p>Fragment" },
        .{ "<html><head><title>A &lt;body&gt; title</title></head><p>Implicit body</p></html>", "<p>Implicit body" },
        .{ "<html><head><style>p{color:blue}</style><body>Implicit head closer", "Implicit head closer" },
        .{ "<body class='original'><p>Body fragment</p></body>", "<p>Body fragment" },
        .{ "<head><style>p{color:blue}</style></head><p>Head fragment</p>", "<p>Head fragment" },
        .{ "<script>const fake = '<html><body>'; const other = '</body>';</script><p>After script</p>", "<p>After script" },
        .{ "<textarea>literal <html><body> text</textarea><p>After textarea</p>", "<textarea>literal" },
        .{ "<meta charset=ascii><style>p{color:blue}</style></head><p>Omitted starts</body></html>", "<p>Omitted starts" },
        .{ "Fictional prefix<head><style>p{color:blue}</style></head><body>Later body</body></html>", "Fictional prefix" },
        .{ "</head></body></body></html></html>", "</body>" },
    };
    inline for (cases) |case| {
        const result = try prepare(a, fixtureNote(), fixtureOriginal(case[0]));
        const note_at = std.mem.indexOf(u8, result.html, fixture_note).?;
        try std.testing.expect(note_at < std.mem.indexOf(u8, result.html, case[1]).?);
        try std.testing.expectEqualStrings(logo_content_id, result.html[result.logoOffset..][0..logo_content_id.len]);
        try std.testing.expect(std.mem.indexOf(u8, result.html, "<!doctype") == null);
    }
    const no_html = try prepare(a, fixtureNote(), fixtureOriginal(""));
    try std.testing.expect(std.mem.indexOf(u8, no_html.html, ">Original plain text.</div>") != null);
}

test "original mail: repeated envelopes retain literal namespace language and attribute order" {
    const original_body = "<table class='booking'><tr><td>Fictional booking summary</td></tr></table><img src='https://example.test/booking.png'><!--[if mso]><v:rect fill='true'></v:rect><![endif]-->";
    const roots = "\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\">\n<!-- between opening roots -->" ++
        "<html lang=\"de\">";
    const source = roots ++ "<head><meta name='viewport' content='width=device-width'><style>html:lang(de) .booking{color:#123456}body{background:#abcdef}</style></head>" ++
        "<body id=\"body\" style=\"margin:0;padding:0\">" ++ original_body ++ "</body></html>";
    const result = try prepare(std.testing.allocator, fixtureNote(), fixtureOriginal(source));
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.startsWith(u8, result.html, roots ++ "<head>" ++ utf8_meta));
    for ([_][]const u8{
        "<meta name='viewport' content='width=device-width'>",
        "<style>html:lang(de) .booking{color:#123456}body{background:#abcdef}</style>",
        "<body id=\"body\" style=\"margin:0;padding:0\">" ++ fixture_note,
    }) |preserved| try std.testing.expect(std.mem.indexOf(u8, result.html, preserved) != null);
    try std.testing.expect(std.mem.endsWith(u8, result.html, original_body ++ "</body></html>"));
    try validate(fixtureOriginal(source));
}

test "original mail: late roots bodies tails and concatenated leaves stay in source order" {
    const prefix = "\xef\xbb\xbf<!doctype html><HTML LANG = 'en' xmlns:o = 'urn:first'><head>";
    const head = "<style>p{color:#123456}</style></head><body class='first'>";
    const original_body = "<p>First content</p><html lang=de dir=rtl><body class=second data-late=yes>" ++
        "<p>Second content</p></body><img src='https://example.test/pixel.png'></html>" ++
        "<!doctype html><html lang=fr><head><style>.tail{color:blue}</style></head><body><p class=tail>Third content</p></body></html>Tail";
    const result = try prepare(std.testing.allocator, fixtureNote(), fixtureOriginal(prefix ++ head ++ original_body));
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.startsWith(u8, result.html, prefix ++ utf8_meta ++ head ++ fixture_note));
    try std.testing.expect(std.mem.endsWith(u8, result.html, original_body));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.html, "<!doctype html>"));
    try std.testing.expectEqualStrings(logo_content_id, result.html[result.logoOffset..][0..logo_content_id.len]);
}

test "original mail: recoverable less-than attributes preserve body bytes and later CID resources" {
    const original_body = "<p style=\"color:#123456\" <span>Fictional itinerary</span></p>" ++
        "<p style=\"color:#654321\" <span>Fictional connection</span></p>" ++
        "<p data-raw=left<right>Literal attribute value</p>" ++
        "<img src='cid:picture@example.test'><p>After the image</p>";
    const source = "<!DOCTYPE html><html><head><style>p{margin:0}</style></head><body class='booking'>" ++ original_body ++ "</body></html>";
    const resources = [_]t.Attachment{
        .{ .id = "ordinary", .filename = "document.pdf", .mimeType = "application/pdf", .contentId = "ordinary@example.test" },
        .{ .id = "picture", .filename = "", .mimeType = "image/png", .contentId = "picture@example.test" },
    };
    var original = fixtureOriginal(source);
    original.resources = &resources;
    try validate(original);
    try expectUsage(&.{1}, try resourceUsage(source, &resources));
    const result = try prepare(std.testing.allocator, fixtureNote(), original);
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.endsWith(u8, result.html, original_body ++ "</body></html>"));
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<body class='booking'>" ++ fixture_note) != null);
    try std.testing.expectEqualStrings(logo_content_id, result.html[result.logoOffset..][0..logo_content_id.len]);
    original.resources = resources[0..1];
    try std.testing.expectError(error.OriginalResourceUnavailable, validate(original));
}

test "original mail: unsafe head boundaries and quotas fail without partial results" {
    for ([_][]const u8{
        "<html><head data-bad='unterminated>Head",
        "<html><head><style>p{color:red}</head><body>Missing style closer</body></html>",
        "<!-- unclosed <html><body>",
        "<head><template><body>Unclosed head template",
    }) |source| try std.testing.expectError(error.OriginalHtmlUnavailable, prepare(std.testing.allocator, fixtureNote(), fixtureOriginal(source)));
    try std.testing.expectError(error.OriginalHtmlUnavailable, validate(fixtureOriginal("<plaintext>Body")));
    var invalid = fixtureOriginal("<p>Fine</p>");
    invalid.subject = "Subject\r\nFrom: forged@example.test";
    try std.testing.expectError(error.InvalidOriginalHtml, validate(invalid));
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = std.testing.allocator, .limit = 64 };
    try std.testing.expectError(error.OutOfMemory, prepare(cap.allocator(), fixtureNote(), fixtureOriginal("<p>Original</p>")));
    try std.testing.expectEqual(@as(usize, 0), cap.used);
}

test "original mail: incomplete body tails are preserved without appended closing bytes" {
    const tails = .{
        "<p data-value=\"unfinished>Discarded tag <img src='cid:fake@example.test'>",
        "<!-- unfinished comment <body><img src='cid:fake@example.test'>",
        "<style>p{color:red}/* unfinished CSS <img src='cid:fake@example.test'>",
        "<script>const fake = '<body><img src=cid:fake@example.test>';",
        "<template><body><p>Unclosed body template",
    };
    inline for (tails) |tail| {
        const source = "<!doctype html><html><body><p>Visible original</p>" ++ tail;
        const result = try prepare(std.testing.allocator, fixtureNote(), fixtureOriginal(source));
        defer std.testing.allocator.free(result.html);
        defer std.testing.allocator.free(result.plain);
        try std.testing.expect(std.mem.endsWith(u8, result.html, "<p>Visible original</p>" ++ tail));
        try std.testing.expect(std.mem.indexOf(u8, result.html, "<body>" ++ fixture_note) != null);
        try expectUsage(&.{}, try resourceUsage(source, &.{}));
    }
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
    if (t.Limits.compose_body_bytes > t.Limits.body_bytes) {
        try std.testing.expect((try prepare(a, fixtureNote(), original)).plain.len > t.Limits.body_bytes);
    } else try std.testing.expectError(error.RenderedBodyTooLarge, prepare(a, fixtureNote(), original));
    var repeated: Buffer = .{ .a = a };
    for (0..80) |_| try repeated.append("<meta charset='ascii'>");
    try repeated.append("<p>Source after many quoted encodings</p>");
    const normalized = try prepare(a, fixtureNote(), fixtureOriginal(repeated.bytes.items));
    try std.testing.expect(std.mem.indexOf(u8, normalized.html, "charset='ascii'") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, normalized.html, utf8_meta));
    try std.testing.expect(std.mem.endsWith(u8, normalized.html, "<p>Source after many quoted encodings</p>"));
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
    try expectUsage(&.{ 1, 2, 3 }, try resourceUsage(html, &resources));
    try expectUsage(&.{}, try resourceUsage("<p>cid:picture@example.test</p>", &resources));
    try std.testing.expectError(error.OriginalResourceUnavailable, resourceUsage("<img src='cid:missing@example.test'>", &resources));
    // The classification helper keeps duplicates visible for backend rejection.
    const duplicates = [_]t.Attachment{ resources[1], resources[1] };
    try expectUsage(&.{ 0, 1 }, try resourceUsage("<img src='cid:picture@example.test'>", &duplicates));
}

test "original mail: usage bitset is bounded and includes the final resource slot" {
    var resources: [t.Limits.message_attachments + 1]t.Attachment = @splat(.{ .id = "part", .filename = "part.bin" });
    resources[t.Limits.message_attachments - 1].contentId = "last@example.test";
    try expectUsage(&.{t.Limits.message_attachments - 1}, try resourceUsage("<img src='cid:last@example.test'>", resources[0..t.Limits.message_attachments]));
    try std.testing.expectError(error.TooManyAttachments, resourceUsage("", &resources));
    try expectUsage(&.{}, try resourceUsage("<html><body>A</body></html><html><body>B</body></html>", &.{}));
}

test "original mail: growing resource counts preserve high CID CSS location and conditional identities" {
    var resources: [t.Limits.message_attachments]t.Attachment = @splat(.{ .id = "ordinary", .filename = "document.pdf", .disposition = "attachment" });
    resources[64] = .{ .id = "picture", .filename = "picture.png", .contentId = "picture@example.test", .disposition = "attachment", .size = 4 };
    resources[129] = .{ .id = "background", .filename = "", .contentId = "background@example.test", .disposition = "attachment", .size = 5 };
    resources[1023] = .{ .id = "located", .filename = "located.png", .contentLocation = "photo.png?a=1&b=2", .disposition = "attachment", .size = 6 };
    resources[t.Limits.message_attachments - 1] = .{ .id = "conditional", .filename = "conditional.png", .contentId = "conditional@example.test", .disposition = "inline", .size = 7 };
    const html = "<img src='CID:picture%40example.test'><style>.back{background:url(c\\69 d:background%40example.test)}</style>" ++
        "<img src='photo.png?a=1&amp;b=2'><!--[if mso]><img src='cid:conditional@example.test'><![endif]-->";
    try expectUsage(&.{ 64, 129, 1023 }, try resourceUsage(html, &resources));
    const plan = try resourcePlan(html, &resources);
    try std.testing.expectEqualSlices(usize, &.{ 64, 129, 1023, t.Limits.message_attachments - 1 }, plan.indices[0..plan.count]);
    try std.testing.expectEqual(@as(usize, 22), plan.bytes);
    // An exact location match cannot hide a subsequent duplicated CID group.
    resources[64].contentLocation = "first.png";
    resources[700] = resources[64];
    resources[700].contentLocation = "second.png";
    try expectUsage(&.{ 64, 700 }, try resourceUsage("<img src='first.png'><img src='cid:picture@example.test'>", &resources));
    try std.testing.expectError(error.AmbiguousContentId, resourcePlan(html, &resources));
    resources[700] = resources[1023];
    try std.testing.expectError(error.AmbiguousContentId, resourcePlan(html, &resources));
    resources[700] = .{ .id = "conditional-duplicate", .filename = "", .contentId = "conditional@example.test" };
    try std.testing.expectError(error.AmbiguousContentId, resourcePlan(html, &resources));
}

test "original mail: twenty more replies retain every earlier screenshot and exact opaque body" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial_count = 65;
    const added_per_reply = 6;
    const resources = try a.alloc(t.Attachment, initial_count + 20 * added_per_reply);
    resources[0] = .{ .id = "previous-signature", .filename = "logo.png", .contentId = logo_content_id, .size = 3, .data = "AAEC" };
    var source: std.ArrayList(u8) = .empty;
    const source_markup = "<table data-opaque='  unchanged &amp; exact  '><tr><td>Original screenshot discussion</td></tr></table><!--[if mso]><v:shape data-note='preserve'/><![endif]-->";
    try source.appendSlice(a, source_markup);
    for (resources[1..], 1..) |*resource, index| {
        const id = try std.fmt.allocPrint(a, "screen-{d}@example.test", .{index});
        resource.* = .{ .id = id, .filename = "screenshot.png", .mimeType = "image/png", .contentId = id, .size = 3, .data = "AAEC", .disposition = "attachment" };
        if (index < initial_count) try source.appendSlice(a, try std.fmt.allocPrint(a, "<img src='cid:{s}'>", .{id}));
    }
    for (0..21) |reply| {
        const count = initial_count + reply * added_per_reply;
        if (reply != 0) for (resources[count - added_per_reply .. count]) |resource| {
            try source.appendSlice(a, try std.fmt.allocPrint(a, "<img src='cid:{s}'>", .{resource.contentId.?}));
        };
        var original = fixtureOriginal(source.items);
        original.resources = resources[0..count];
        const plan = try resourcePlan(original.bodyHtml, original.resources);
        try std.testing.expectEqual(count, plan.count);
        const prepared = try prepare(a, fixtureNote(), original);
        try std.testing.expectEqual(count, prepared.resources.len);
        try std.testing.expect(std.mem.indexOf(u8, prepared.html, source_markup) != null);
        const usage = try resourceUsage(prepared.html, prepared.resources);
        try std.testing.expectEqual(count, usage.count());
        for (prepared.resources, 0..) |resource, index| {
            try std.testing.expect(usage.isSet(index));
            try std.testing.expectEqualStrings("AAEC", resource.data);
        }
        source = .empty;
        try source.appendSlice(a, prepared.html);
    }
}

test "original mail: byte bounded scanner preserves a long repeated quote beyond old token quota" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.alloc(u8, 40000 * "<p>x</p>".len);
    for (0..40000) |index| @memcpy(source[index * 8 ..][0..8], "<p>x</p>");
    const prepared = try prepare(a, fixtureNote(), fixtureOriginal(source));
    try std.testing.expect(std.mem.endsWith(u8, prepared.html, source));
}

test "original mail: shared attribute states retain punctuation adjacent values and first URL" {
    const body = "<p data-label=can't data-quote=left\"right data-odd'key=value data-mark=a<b=1>Literal attributes</p>" ++
        "<body=broken>Not a body token</body=broken><a<b>Not an a token</a<b>" ++
        "<img/alt='Fictional badge'src='cid:picture@example.test' src='cid:ignored@example.test'>";
    const source = "<html/><head/><style>p{color:#123456}</style></head/><body/>" ++ body ++ "</body/></html/>";
    const resources = [_]t.Attachment{.{ .id = "picture", .filename = "", .contentId = "picture@example.test" }};
    var original = fixtureOriginal(source);
    original.resources = &resources;
    const result = try prepare(std.testing.allocator, fixtureNote(), original);
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.endsWith(u8, result.html, body ++ "</body/></html/>"));
    try expectUsage(&.{0}, try resourceUsage(source, &resources));
    try std.testing.expectError(error.OriginalResourceUnavailable, resourceUsage(source, &.{}));
}

test "original mail: head templates foreign CDATA and bogus declarations cannot supply fake boundaries" {
    const template = "<template id='fixture'><html lang=de><head><body class=fake><p>Inert text</p>" ++
        "<meta charset=ascii><template><body>Nested template</body></template></body></html></template>";
    const source = "<?xml version='1.0'?><!doctype html><html lang=en><head><!--><!--->" ++ template ++
        "<style>p{color:#123456}</style></head><body class=actual>" ++
        "<svg><g><![CDATA[<body><img src='cid:fake@example.test'>]]></g></svg>" ++
        "<!bogus ' > <p>Visible original</p><img src='cid:picture@example.test'></body></html>";
    const resources = [_]t.Attachment{.{ .id = "picture", .filename = "", .contentId = "picture@example.test" }};
    var original = fixtureOriginal(source);
    original.resources = &resources;
    const result = try prepare(std.testing.allocator, fixtureNote(), original);
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.indexOf(u8, result.html, template) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<body class=actual>" ++ fixture_note) != null);
    try expectUsage(&.{0}, try resourceUsage(source, &resources));
}

test "original mail: double escaped script text keeps fake envelopes and CIDs opaque" {
    const script = "<script><!--<script> const fake = '</script><body><img src=\"cid:fake@example.test\">'; --></script>";
    const source = "<!doctype html><html><head>" ++ script ++ "</head><body><p>After script</p><img src='cid:picture@example.test'></body></html>";
    const resources = [_]t.Attachment{.{ .id = "picture", .filename = "", .contentId = "picture@example.test" }};
    var original = fixtureOriginal(source);
    original.resources = &resources;
    const result = try prepare(std.testing.allocator, fixtureNote(), original);
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.indexOf(u8, result.html, script) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "</head><body>" ++ fixture_note) != null);
    try expectUsage(&.{0}, try resourceUsage(source, &resources));
}

test "original mail: malformed CSS preserves actual CID usage without absorbing ordinary attachments" {
    const resources = [_]t.Attachment{
        .{ .id = "ordinary", .filename = "document.pdf", .contentId = "ordinary@example.test", .disposition = "attachment" },
        .{ .id = "picture", .filename = "", .contentId = "picture@example.test" },
        .{ .id = "calendar", .filename = "event.ics", .contentId = "calendar@example.test", .disposition = "attachment" },
    };
    const source = "<style>.a{background:url(c\\69 d:picture%40example.test)}.b{color:red}/* unfinished cid:ordinary@example.test</style>" ++
        "<p style='background:url(bad value);color:red;content:&quot;unfinished'>Original</p>" ++
        "<div style='background:url(\\FFFFFF)'>Invalid escaped code point</div><img src='cid:picture@example.test'>";
    var original = fixtureOriginal(source);
    original.resources = &resources;
    const result = try prepare(std.testing.allocator, fixtureNote(), original);
    defer std.testing.allocator.free(result.html);
    defer std.testing.allocator.free(result.plain);
    try std.testing.expect(std.mem.indexOf(u8, result.html, ".b{color:red}/* unfinished cid:ordinary@example.test</style>") != null);
    try expectUsage(&.{1}, try resourceUsage(source, &resources));
    try expectUsage(&.{}, try resourceUsage("<style>/* url(cid:ordinary@example.test)</style><p>Original</p>", &resources));
    try std.testing.expectError(error.OriginalResourceUnavailable, resourceUsage("<style>.a{color:broken;background:url(cid:missing@example.test)}</style><p>Original</p>", &resources));
}
