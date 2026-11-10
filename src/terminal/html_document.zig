const std = @import("std");
pub const entities = @import("html_entities.zig");

/// Work and structure caps. Memory stays bounded by the 2 MiB input/text caps:
/// tokens are only a work counter, and 8192 blocks/spans cost well under 1 MiB
/// of fixed-size records in the caller's arena.
pub const Limits = struct {
    pub const input_bytes = 2 * 1024 * 1024;
    pub const text_bytes = 2 * 1024 * 1024;
    pub const blocks = 8192;
    pub const spans = 8192;
    pub const cells = 4096;
    pub const columns = 32;
    pub const rows = 256;
    pub const depth = 128;
    pub const tokens = 262144;
    pub const tag_bytes = 8192;
    pub const link_bytes = 4096;
    pub const all_link_bytes = 256 * 1024;
};
pub const CodeToken = enum(u3) { none, keyword, string, comment, number };
pub const FooterStyle = enum(u2) { none, text, link };
pub const Style = packed struct { bold: bool = false, italic: bool = false, underline: bool = false, code: bool = false, strike: bool = false, code_token: CodeToken = .none, footer: FooterStyle = .none };
pub const Span = struct { text: []const u8, style: Style = .{}, link: ?[]const u8 = null };
pub const Kind = enum { paragraph, heading, pre, list_item, quote, rule, table };
pub const Cell = struct { spans: []const Span, header: bool = false };
pub const Row = struct { cells: []const Cell };
pub const Table = struct { rows: []const Row };
pub const Block = struct {
    kind: Kind,
    spans: []const Span = &.{},
    level: u8 = 0,
    ordered: bool = false,
    ordinal: u32 = 1,
    table: ?Table = null,
    list_group: u32 = 0,
    list_start: bool = false,
    list_continuation: bool = false,
    list_loose: bool = false,
    list_paragraph: bool = false,
    quote_depth: u8 = 0,
    /// Follows the previous block without a separating blank row: adjacent
    /// div/section/center/tr/td/th content of one kind with no authored gap.
    tight: bool = false,
};
/// `truncated` is set only by lenient parsing: a viewer limit ended the
/// document early and `blocks` holds everything built up to that point.
pub const Document = struct { blocks: []const Block, truncated: bool = false };
pub const ParseOptions = struct {
    /// Only for HTML produced locally by the escaped Markdown renderer. Mail
    /// received from providers must keep the default and cannot supply colours.
    generated_markdown: bool = false,
    /// Received-mail display: a viewer limit stops with Document.truncated and
    /// keeps the content built so far, rather than failing. Callers that turn
    /// the document into outgoing text keep the strict default, so a limit can
    /// never silently shorten a quotation.
    lenient: bool = false,
};

/// Caller owns every result and scratch allocation: use an arena and keep it
/// alive while displaying Document. Output text/URLs never borrow input. Errors
/// mean the viewer should use its existing plain fallback, not refuse the mail.
/// This is a semantic mail filter, with no CSS engine, resource loads or actions.
pub fn parse(input: []const u8, allocator: std.mem.Allocator) !Document {
    return parseWithOptions(input, allocator, .{});
}
pub fn parseGeneratedMarkdown(input: []const u8, allocator: std.mem.Allocator) !Document {
    return parseWithOptions(input, allocator, .{ .generated_markdown = true });
}
/// For showing received mail: limits truncate, see ParseOptions.lenient.
pub fn parseLenient(input: []const u8, allocator: std.mem.Allocator) !Document {
    return parseWithOptions(input, allocator, .{ .lenient = true });
}
pub fn parseWithOptions(input: []const u8, allocator: std.mem.Allocator, options: ParseOptions) !Document {
    if (input.len > Limits.input_bytes) return error.HtmlTooLarge;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var context: Context = .{ .a = allocator, .input = input, .options = options };
    var offset: usize = 0;
    while (offset < input.len) {
        try context.tick();
        if (context.truncated) break;
        if (context.rawHidden()) |name| {
            // Script/style bodies are raw text, not nested HTML. A quoted
            // "<script>" must not consume the real closer and hide the mail tail.
            offset = try context.rawHiddenEnd(offset, name);
            try context.close(name);
        } else if (std.mem.startsWith(u8, input[offset..], "<!--")) {
            offset = try context.commentEnd(offset + 4);
        } else if (input[offset] == '<') {
            if (try tagAt(input, offset, options.lenient)) |tag| {
                const begin = offset;
                offset = tag.end;
                if (tag.name.len == 0) continue;
                // Unescaped generic/type names occur in real technical code.
                // Only bare unknown tags in code/pre get this literal treatment;
                // real HTML formatting and escaped markup keep their semantics.
                if (!context.state.skip and context.state.style.code and !knownTag(tag.name) and tag.attributes.len == 0) {
                    try context.text(input[begin..offset]);
                    continue;
                }
                if (tag.closing) try context.close(tag.name) else {
                    if (tag.is("body") or blockTag(tag.name)) try context.closeMetadata();
                    try context.open(tag);
                }
            } else {
                if (!context.state.skip) try context.text("<");
                offset += 1;
            }
        } else {
            const end = std.mem.indexOfScalarPos(u8, input, offset, '<') orelse input.len;
            if (!context.state.skip) try context.text(input[offset..end]);
            offset = end;
        }
    }
    while (context.depth != 0) try context.pop();
    try context.finishTable();
    try context.flushBlock();
    return .{ .blocks = try context.blocks.toOwnedSlice(allocator), .truncated = context.truncated };
}

const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    end: usize,
    closing: bool = false,
    self_closing: bool = false,
    fn is(self: Tag, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }
    fn attribute(self: Tag, wanted: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.attributes.len) {
            while (i < self.attributes.len and (white(self.attributes[i]) or self.attributes[i] == '/')) : (i += 1) {}
            const start = i;
            while (i < self.attributes.len and !white(self.attributes[i]) and self.attributes[i] != '=' and self.attributes[i] != '/') : (i += 1) {}
            if (i == start) {
                i += 1;
                continue;
            }
            const name = self.attributes[start..i];
            while (i < self.attributes.len and white(self.attributes[i])) : (i += 1) {}
            var value: []const u8 = "";
            if (i < self.attributes.len and self.attributes[i] == '=') {
                i += 1;
                while (i < self.attributes.len and white(self.attributes[i])) : (i += 1) {}
                if (i < self.attributes.len and (self.attributes[i] == '\'' or self.attributes[i] == '"')) {
                    const quote = self.attributes[i];
                    i += 1;
                    const begin = i;
                    while (i < self.attributes.len and self.attributes[i] != quote) : (i += 1) {}
                    value = self.attributes[begin..i];
                    if (i < self.attributes.len) i += 1;
                } else {
                    const begin = i;
                    while (i < self.attributes.len and !white(self.attributes[i])) : (i += 1) {}
                    value = self.attributes[begin..i];
                }
            }
            if (std.ascii.eqlIgnoreCase(name, wanted)) return value;
        }
        return null;
    }
};
fn white(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 12;
}
fn commentEndScan(input: []const u8, start: usize) ?usize {
    // "<!-->" and "<!--->" are complete empty comments.
    if (std.mem.startsWith(u8, input[start..], ">")) return start + 1;
    if (std.mem.startsWith(u8, input[start..], "->")) return start + 2;
    var i = start;
    while (std.mem.indexOfPos(u8, input, i, "--")) |dashes| : (i = dashes + 1) {
        if (std.mem.startsWith(u8, input[dashes + 2 ..], ">")) return dashes + 3;
        if (std.mem.startsWith(u8, input[dashes + 2 ..], "!>")) return dashes + 4;
    }
    return null;
}
/// Where visible content plausibly resumes after an unterminated comment or
/// style: the next block-level tag. One forward scan; every tag is bounded.
fn nextBlockTag(input: []const u8, start: usize) usize {
    var offset = start;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |next| {
        const tag = (tagAt(input, next, true) catch unreachable) orelse {
            offset = next + 1;
            continue;
        };
        if (tag.is("body") or blockTag(tag.name)) return next;
        offset = @max(tag.end, next + 1);
    }
    return input.len;
}
fn knownTag(name: []const u8) bool {
    for ([_][]const u8{ "html", "head", "title", "body", "style", "script", "template", "noscript", "svg", "math", "iframe", "object", "canvas", "xml", "p", "div", "span", "section", "article", "main", "header", "footer", "address", "figure", "figcaption", "caption", "pre", "li", "ol", "ul", "blockquote", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "b", "strong", "i", "em", "u", "s", "strike", "del", "code", "kbd", "samp", "a", "font", "center", "sup", "sub", "small", "big", "form", "button", "select", "option", "textarea", "label", "video", "audio" }) |v| if (std.ascii.eqlIgnoreCase(name, v)) return true;
    if (voidTag(name)) return true;
    if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') return true;
    return std.ascii.startsWithIgnoreCase(name, "o:") or std.ascii.startsWithIgnoreCase(name, "w:") or std.ascii.startsWithIgnoreCase(name, "v:");
}
/// Strict parsing refuses a tag longer than Limits.tag_bytes. Lenient parsing
/// keeps its name and intact leading attributes and resumes after its end.
fn tagAt(input: []const u8, start: usize, lenient: bool) !?Tag {
    if (start + 1 >= input.len) return null;
    var i = start + 1;
    var closing = false;
    if (input[i] == '/') {
        closing = true;
        i += 1;
    }
    if (i >= input.len) return null;
    if (input[i] == '!' or input[i] == '?') {
        var quote: u8 = 0;
        var brackets: usize = 0;
        while (i < input.len) : (i += 1) {
            if (i - start > Limits.tag_bytes) {
                if (!lenient) return error.HtmlTooComplex;
                return .{ .name = "", .attributes = "", .end = if (std.mem.indexOfScalarPos(u8, input, i, '>')) |end| end + 1 else input.len };
            }
            const c = input[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '[') {
                brackets += 1;
            } else if (c == ']') {
                brackets -|= 1;
            } else if (c == '>' and brackets == 0) {
                return .{ .name = "", .attributes = "", .end = i + 1 };
            }
        }
        return .{ .name = "", .attributes = "", .end = input.len };
    }
    if (!std.ascii.isAlphabetic(input[i])) return null;
    const name_start = i;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == ':' or input[i] == '-')) : (i += 1) {}
    const name = input[name_start..i];
    // A raw mailbox or a comparison is not an attribute-bearing HTML tag.
    if (i < input.len and !white(input[i]) and input[i] != '/' and input[i] != '>') return null;
    const attributes_start = i;
    var quote: u8 = 0;
    var quote_start: usize = 0;
    var intact = i;
    var nested: ?usize = null;
    while (i < input.len) : (i += 1) {
        if (i - start > Limits.tag_bytes) {
            if (!lenient) return error.HtmlTooComplex;
            // One over-long tag, such as an inline data: image, ends at the
            // first '>' at/after the limit. An open quote that already
            // swallowed a '>' is unbalanced: rescan from it ignoring quotes.
            // Only attributes that ended before the excess remain readable.
            var from = i;
            if (quote != 0) if (std.mem.indexOfScalarPos(u8, input[0..i], quote_start, '>')) |inner| {
                from = inner;
            };
            const end = std.mem.indexOfScalarPos(u8, input, from, '>') orelse input.len;
            const attrs = std.mem.trimEnd(u8, input[attributes_start..intact], " \t\r\n");
            return .{ .name = name, .attributes = attrs, .end = @min(end + 1, input.len), .closing = closing, .self_closing = end < input.len and input[end - 1] == '/' };
        }
        if (input[i] == '<' and nested == null) nested = i;
        if (quote != 0) {
            if (input[i] == quote) {
                quote = 0;
                intact = i + 1;
            }
            continue;
        }
        if (input[i] == '"' or input[i] == '\'') {
            quote = input[i];
            quote_start = i;
            continue;
        }
        if (white(input[i])) intact = i;
        if (input[i] == '<') {
            // Recover at the next markup boundary without swallowing its tag.
            return if (knownTag(name)) .{ .name = "", .attributes = "", .end = i } else null;
        }
        if (input[i] == '>') {
            const attrs = std.mem.trimEnd(u8, input[attributes_start..i], " \t\r\n");
            return .{ .name = name, .attributes = attrs, .end = i + 1, .closing = closing, .self_closing = std.mem.endsWith(u8, attrs, "/") };
        }
    }
    // Truncated known markup must not become visible attribute fragments.
    // Unknown '<T' or '<limit' text remains literal instead of being guessed.
    if (knownTag(name)) return .{ .name = "", .attributes = "", .end = nested orelse input.len };
    return null;
}
fn rawHiddenScan(input: []const u8, start: usize, name: []const u8, lenient: bool) !?usize {
    var offset = start;
    while (std.mem.indexOfScalarPos(u8, input, offset, '<')) |next| {
        offset = next + 1;
        if (offset >= input.len or input[offset] != '/') continue;
        const begin = offset + 1;
        if (begin + name.len > input.len or !std.ascii.eqlIgnoreCase(input[begin..][0..name.len], name)) continue;
        const boundary = begin + name.len;
        if (boundary < input.len and input[boundary] != '>' and input[boundary] != '/' and !white(input[boundary])) continue;
        if (try tagAt(input, next, lenient)) |tag| return tag.end;
    }
    return null;
}
fn voidTag(name: []const u8) bool {
    for ([_][]const u8{ "br", "hr", "img", "meta", "link", "input", "area", "base", "col", "embed", "source", "track", "wbr" }) |v| if (std.ascii.eqlIgnoreCase(name, v)) return true;
    return false;
}
fn blockTag(name: []const u8) bool {
    for ([_][]const u8{ "p", "div", "section", "article", "main", "header", "footer", "address", "figure", "figcaption", "caption", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "li", "blockquote", "tr", "td", "th", "table", "center" }) |v| if (std.ascii.eqlIgnoreCase(name, v)) return true;
    return false;
}
/// A unitless or unit-suffixed CSS zero: "0", "0px", "0.0em", "0%".
fn cssZero(value: []const u8) bool {
    var digits: usize = 0;
    var i: usize = 0;
    while (i < value.len and (value[i] == '0' or value[i] == '.')) : (i += 1) digits += @intFromBool(value[i] == '0');
    if (digits == 0) return false;
    for (value[i..]) |c| if (!std.ascii.isAlphabetic(c) and c != '%') return false;
    return true;
}
/// Tracking pixels and spacers declare a width or height of at most 2.
fn tinyImage(tag: Tag) bool {
    for ([_][]const u8{ "width", "height" }) |name| if (tag.attribute(name)) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        var end: usize = 0;
        while (end < value.len and std.ascii.isDigit(value[end])) end += 1;
        if (end == 0 or (end != value.len and !std.ascii.eqlIgnoreCase(value[end..], "px"))) continue;
        if ((std.fmt.parseInt(u32, value[0..end], 10) catch continue) <= 2) return true;
    };
    return false;
}
/// Whitespace and default-ignorable code points draw nothing by themselves.
fn invisible(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0xa0 or cp == 0xad or cp == 0x34f or cp == 0x180e or
        (cp >= 0x2000 and cp <= 0x200d) or cp == 0x202f or cp == 0x205f or cp == 0x2060 or cp == 0x3000 or cp == 0xfeff;
}
fn visible(spans: []const Span) bool {
    for (spans) |span| {
        var i: usize = 0;
        while (i < span.text.len) {
            const n = std.unicode.utf8ByteSequenceLength(span.text[i]) catch return true;
            if (i + n > span.text.len) return true;
            if (!invisible(std.unicode.utf8Decode(span.text[i..][0..n]) catch return true)) return true;
            i += n;
        }
    }
    return false;
}
fn hidden(tag: Tag, a: std.mem.Allocator) !bool {
    for ([_][]const u8{ "head", "title", "style", "script", "template", "svg", "noscript", "iframe", "object", "canvas", "math", "xml", "o:officedocumentsettings", "o:documentproperties", "o:customdocumentproperties", "w:worddocument" }) |v| if (tag.is(v)) return true;
    if (tag.attribute("hidden") != null) return true;
    if (tag.attribute("aria-hidden")) |v| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t\r\n"), "true")) return true;
    if (tag.attribute("style")) |style| {
        const decoded = try decodeAttribute(a, style);
        var css: std.ArrayList(u8) = .empty;
        try css.ensureTotalCapacityPrecise(a, decoded.len);
        var i: usize = 0;
        while (i < decoded.len) {
            if (std.mem.startsWith(u8, decoded[i..], "/*")) {
                const end = std.mem.indexOfPos(u8, decoded, i + 2, "*/") orelse break;
                try css.append(a, ' ');
                i = end + 2;
            } else {
                try css.append(a, decoded[i]);
                i += 1;
            }
        }
        // Preheader idioms that keep text in the markup but draw nothing:
        // a clipped zero max-height, a zero box, zero font size or opacity.
        var clipped = false;
        var flat = false;
        var zero_width = false;
        var zero_height = false;
        var properties = std.mem.splitScalar(u8, css.items, ';');
        while (properties.next()) |property| {
            const colon = std.mem.indexOfScalar(u8, property, ':') orelse continue;
            const key = std.mem.trim(u8, property[0..colon], " \t\r\n");
            const value = std.mem.trim(u8, property[colon + 1 ..], " \t\r\n");
            const end = std.mem.indexOfAny(u8, value, " !\t\r\n") orelse value.len;
            if ((std.ascii.eqlIgnoreCase(key, "display") and std.ascii.eqlIgnoreCase(value[0..end], "none")) or
                (std.ascii.eqlIgnoreCase(key, "visibility") and std.ascii.eqlIgnoreCase(value[0..end], "hidden")) or
                (std.ascii.eqlIgnoreCase(key, "mso-hide") and std.ascii.eqlIgnoreCase(value[0..end], "all")) or
                ((std.ascii.eqlIgnoreCase(key, "font-size") or std.ascii.eqlIgnoreCase(key, "opacity")) and cssZero(value[0..end]))) return true;
            if (std.ascii.eqlIgnoreCase(key, "overflow") and std.ascii.eqlIgnoreCase(value[0..end], "hidden")) clipped = true;
            if (std.ascii.eqlIgnoreCase(key, "max-height") and cssZero(value[0..end])) flat = true;
            if (std.ascii.eqlIgnoreCase(key, "width") and cssZero(value[0..end])) zero_width = true;
            if (std.ascii.eqlIgnoreCase(key, "height") and cssZero(value[0..end])) zero_height = true;
        }
        if ((clipped and flat) or (zero_width and zero_height)) return true;
    }
    return false;
}

/// How the innermost block element spaces its content: wrappers and layout
/// rows/cells stack without blank rows; a cell is additionally a common spacer.
const Spacing = enum(u2) { loose, tight, cell };
const State = struct { style: Style = .{}, link: ?[]const u8 = null, skip: bool = false, pre: bool = false, spacing: Spacing = .tight, kind: Kind = .paragraph, level: u8 = 0, ordered: bool = false, ordinal: u32 = 1, list_depth: u8 = 0, quote_depth: u8 = 0, list_group: u32 = 0, list_loose: bool = false, list_paragraph: bool = false };
const Frame = struct { name: []const u8, before: State, next_ordinal: u32 = 1, data_table: bool = false, list_loose: bool = false, item_started: bool = false, list_group: u32 = 0, list_started: bool = false };
const TableBuilder = struct { rows: std.ArrayList(Row) = .empty, cells: std.ArrayList(Cell) = .empty, cell_active: bool = false, cell_header: bool = false };
const Context = struct {
    a: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions = .{},
    blocks: std.ArrayList(Block) = .empty,
    spans: std.ArrayList(Span) = .empty,
    text_buffer: std.ArrayList(u8) = .empty,
    buffer_style: Style = .{},
    buffer_link: ?[]const u8 = null,
    state: State = .{},
    block_state: State = .{},
    stack: [Limits.depth]Frame = undefined,
    depth: usize = 0,
    work: usize = 0,
    text_count: usize = 0,
    span_count: usize = 0,
    cell_count: usize = 0,
    link_count: usize = 0,
    pending_space: bool = false,
    pending_style: Style = .{},
    pending_link: ?[]const u8 = null,
    table_depth: usize = 0,
    table: ?TableBuilder = null,
    next_list_group: u32 = 1,
    truncated: bool = false,
    /// Elements opened beyond Limits.depth; they have no frame and no effect.
    overflow: usize = 0,
    /// Failed closer searches cover the whole remaining input, so they are
    /// never repeated: many unterminated comments stay linear.
    no_comment_end: bool = false,
    no_style_end: bool = false,
    no_script_end: bool = false,
    /// Last code point appended to the current block; 0 when it is empty.
    last: u21 = 0,
    /// Explicit breaks ending the current block's text so far.
    newlines: u8 = 0,
    lead_break: bool = false,
    blank_hint: bool = false,
    /// An authored empty line precedes the next block.
    gap: bool = false,
    previous_tightable: bool = false,
    anchor_text: bool = false,
    /// A viewer limit was reached. Strict parsing refuses the document;
    /// lenient parsing keeps what exists and stops consuming input.
    fn limit(self: *Context) !void {
        if (!self.options.lenient) return error.HtmlTooComplex;
        self.truncated = true;
    }
    fn tick(self: *Context) !void {
        self.work += 1;
        if (self.work > Limits.tokens) try self.limit();
    }
    fn pushBlock(self: *Context, block: Block) !void {
        self.previous_tightable = false;
        if (self.blocks.items.len == Limits.blocks) return self.limit();
        try self.blocks.append(self.a, block);
    }
    fn commentEnd(self: *Context, start: usize) !usize {
        if (!self.no_comment_end) if (commentEndScan(self.input, start)) |end| return end;
        self.no_comment_end = true;
        // An unterminated comment must not swallow the rest of the mail.
        return nextBlockTag(self.input, start);
    }
    fn rawHiddenEnd(self: *Context, start: usize, name: []const u8) !usize {
        const style = std.ascii.eqlIgnoreCase(name, "style");
        const exhausted = if (style) &self.no_style_end else &self.no_script_end;
        if (!exhausted.*) if (try rawHiddenScan(self.input, start, name, self.options.lenient)) |end| return end;
        exhausted.* = true;
        // Unterminated CSS resumes at the next block. Script source could
        // read as prose, so an unterminated script keeps hiding the tail.
        return if (style) nextBlockTag(self.input, start) else self.input.len;
    }
    /// A missing </head> or </title> must not hide the body: the element
    /// that started the current hidden region ends where body content begins.
    fn closeMetadata(self: *Context) !void {
        if (!self.state.skip) return;
        var index = self.depth;
        while (index != 0) {
            index -= 1;
            if (self.stack[index].before.skip) continue;
            const name = self.stack[index].name;
            if (std.ascii.eqlIgnoreCase(name, "head") or std.ascii.eqlIgnoreCase(name, "title")) while (self.depth > index) try self.pop();
            return;
        }
    }
    fn sameLink(a: ?[]const u8, b: ?[]const u8) bool {
        // One decoded href allocation identifies one anchor. Equal destinations
        // on adjacent anchors must retain their individual visible labels.
        return if (a) |v| if (b) |w| v.ptr == w.ptr and v.len == w.len else false else b == null;
    }
    fn flushSpan(self: *Context) !void {
        if (self.text_buffer.items.len == 0) return;
        if (self.span_count == Limits.spans) {
            self.text_buffer.clearRetainingCapacity();
            return self.limit();
        }
        self.span_count += 1;
        try self.spans.append(self.a, .{ .text = try self.text_buffer.toOwnedSlice(self.a), .style = self.buffer_style, .link = self.buffer_link });
    }
    fn flushBlock(self: *Context) !void {
        if (self.table != null and self.table.?.cell_active) {
            try self.lineBreak();
            return;
        }
        try self.flushSpan();
        // Trailing breaks and whitespace never render; two or more breaks are
        // an authored empty line before whatever follows.
        var trailing: usize = 0;
        if (self.spans.items.len != 0 and !self.block_state.pre) {
            while (self.spans.items.len != 0) {
                const last = &self.spans.items[self.spans.items.len - 1];
                const kept = std.mem.trimEnd(u8, last.text, " \t\n");
                trailing += std.mem.count(u8, last.text[kept.len..], "\n");
                last.text = kept;
                if (kept.len != 0) break;
                _ = self.spans.pop();
            }
            if (self.spans.items.len != 0) self.spans.items[0].text = std.mem.trimStart(u8, self.spans.items[0].text, " \t\n");
        }
        // A block of only breaks, spaces or invisible characters draws nothing.
        // Outside spacer cells it still records the author's empty line.
        if (!visible(self.spans.items)) {
            self.spans.clearRetainingCapacity();
            if (self.blank_hint) self.gap = true;
        }
        defer {
            self.last = 0;
            self.newlines = 0;
            self.lead_break = false;
            self.blank_hint = false;
        }
        if (self.spans.items.len != 0) {
            const tightable = self.block_state.spacing != .loose and (self.block_state.kind == .paragraph or self.block_state.kind == .quote);
            var tight = tightable and self.previous_tightable and !self.gap and !self.lead_break;
            if (tight) {
                const previous = self.blocks.items[self.blocks.items.len - 1];
                tight = previous.kind == self.block_state.kind and previous.quote_depth == self.block_state.quote_depth and previous.level == self.block_state.level;
            }
            self.gap = trailing >= 2;
            var continuation = false;
            var list_start = false;
            if (self.block_state.kind == .list_item) {
                var index = self.depth;
                while (index != 0) {
                    index -= 1;
                    if (!std.ascii.eqlIgnoreCase(self.stack[index].name, "li")) continue;
                    continuation = self.stack[index].item_started;
                    self.stack[index].item_started = true;
                    break;
                }
                index = self.depth;
                while (index != 0) {
                    index -= 1;
                    if (self.stack[index].list_group == 0 or self.stack[index].list_group != self.block_state.list_group) continue;
                    list_start = !self.stack[index].list_started;
                    self.stack[index].list_started = true;
                    break;
                }
            }
            try self.pushBlock(.{ .kind = self.block_state.kind, .spans = try self.spans.toOwnedSlice(self.a), .level = self.block_state.level, .ordered = self.block_state.ordered, .ordinal = self.block_state.ordinal, .list_group = self.block_state.list_group, .list_start = list_start, .list_continuation = continuation, .list_loose = self.block_state.list_loose, .list_paragraph = self.block_state.list_paragraph, .quote_depth = self.block_state.quote_depth, .tight = tight });
            self.previous_tightable = tightable and !self.truncated;
        }
        self.pending_space = false;
    }
    fn append(self: *Context, bytes: []const u8) !void {
        if (bytes.len > Limits.text_bytes - self.text_count) {
            if (!self.options.lenient) return error.HtmlTooLarge;
            self.truncated = true;
            return;
        }
        self.newlines = 0;
        self.text_count += bytes.len;
        if (self.text_buffer.items.len == 0 and self.spans.items.len == 0) self.block_state = self.state;
        if (!std.meta.eql(self.buffer_style, self.state.style) or !sameLink(self.buffer_link, self.state.link)) try self.flushSpan();
        self.buffer_style = self.state.style;
        self.buffer_link = self.state.link;
        try self.text_buffer.appendSlice(self.a, bytes);
    }
    fn flushPendingSpace(self: *Context) !void {
        if (!self.pending_space) return;
        self.pending_space = false;
        if (self.text_buffer.items.len == 0 and self.spans.items.len == 0) return;
        // Collapsed whitespace belongs to the text that supplied it, even if
        // an opening or closing inline tag changed state before the next rune.
        const current_style = self.state.style;
        const current_link = self.state.link;
        defer {
            self.state.style = current_style;
            self.state.link = current_link;
        }
        self.state.style = self.pending_style;
        self.state.link = self.pending_link;
        try self.append(" ");
    }
    fn rune(self: *Context, raw: u21) !void {
        var cp = raw;
        if (cp == 13) cp = 10;
        if ((cp < 32 and cp != 10 and cp != 9) or (cp >= 127 and cp <= 159) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xad) return;
        // Default-ignorable fillers would each occupy a blank terminal cell.
        if (cp == 0x34f or cp == 0x180e or cp == 0x200b or cp == 0x2060 or cp == 0xfeff) return;
        // A joiner shapes its neighbours; after whitespace or nothing it is
        // only padding. Emoji and script sequences keep theirs.
        if ((cp == 0x200c or cp == 0x200d) and (self.pending_space or self.last == 0 or self.last == ' ' or self.last == '\n' or self.last == '\t')) return;
        if (!self.state.pre and (cp == 10 or cp == 9 or cp == 32 or cp == 160 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x202f or cp == 0x205f or cp == 0x3000)) {
            if (cp == 160 and self.state.spacing != .cell and self.text_buffer.items.len == 0 and self.spans.items.len == 0) self.blank_hint = true;
            if (!self.pending_space) {
                self.pending_style = self.state.style;
                self.pending_link = self.state.link;
            }
            self.pending_space = true;
            return;
        }
        try self.flushPendingSpace();
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidUtf8;
        try self.append(encoded[0..n]);
        self.last = cp;
        if (self.state.link != null) self.anchor_text = true;
    }
    fn text(self: *Context, bytes: []const u8) !void {
        if (bytes.len >= 4096) {
            // A large plain/pre text token otherwise retains every geometric
            // growth buffer in the caller arena. Finish the old style first so
            // this reservation belongs only to the new span; actual sanitized
            // bytes still pass append's unchanged global text limit.
            if (!std.meta.eql(self.buffer_style, self.state.style) or !sameLink(self.buffer_link, self.state.link)) try self.flushSpan();
            self.buffer_style = self.state.style;
            self.buffer_link = self.state.link;
            const wanted = @min(Limits.text_bytes, self.text_buffer.items.len + bytes.len);
            try self.text_buffer.ensureTotalCapacityPrecise(self.a, wanted);
        }
        var i: usize = 0;
        while (i < bytes.len) {
            if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
                try self.rune(10);
                i += 2;
                continue;
            }
            if (bytes[i] == '&') if (entity(bytes[i..])) |v| {
                try self.rune(v.codepoint);
                i += v.consumed;
                continue;
            };
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return error.InvalidUtf8;
            try self.rune(std.unicode.utf8Decode(bytes[i..][0..n]) catch return error.InvalidUtf8);
            i += n;
        }
    }
    fn lineBreak(self: *Context) !void {
        self.pending_space = false;
        if (!self.state.pre) {
            // A leading break is spacing before the block, not a text row,
            // and any run of breaks leaves at most one empty row.
            if (self.text_buffer.items.len == 0 and self.spans.items.len == 0) {
                self.lead_break = true;
                if (self.state.spacing != .cell) self.blank_hint = true;
                return;
            }
            if (self.newlines >= 2) return;
        }
        const count = self.newlines;
        try self.append("\n");
        self.newlines = count +| 1;
        self.last = '\n';
    }
    fn begin(self: *Context) !void {
        try self.flushBlock();
        self.block_state = self.state;
    }
    fn safeLink(self: *Context, raw: []const u8) !?[]const u8 {
        if (raw.len > Limits.link_bytes or raw.len > Limits.all_link_bytes - self.link_count) return null;
        self.link_count += raw.len;
        const buffer = try decodeAttribute(self.a, raw);
        // As browsers do before resolving: tab/CR/LF vanish anywhere (wrapped
        // attributes) and surrounding ASCII whitespace is not part of the URL.
        var length: usize = 0;
        for (buffer) |c| if (c != '\t' and c != '\n' and c != '\r') {
            buffer[length] = c;
            length += 1;
        };
        const decoded = std.mem.trim(u8, buffer[0..length], " \x0c");
        if (!(std.ascii.startsWithIgnoreCase(decoded, "https://") or std.ascii.startsWithIgnoreCase(decoded, "http://") or std.ascii.startsWithIgnoreCase(decoded, "mailto:"))) return null;
        for (decoded) |c| if (c <= 32 or c == 127) return null;
        return decoded;
    }
    fn rawHidden(self: *const Context) ?[]const u8 {
        if (!self.state.skip) return null;
        for (self.stack[0..self.depth]) |frame| {
            if (!frame.before.skip and (std.ascii.eqlIgnoreCase(frame.name, "script") or std.ascii.eqlIgnoreCase(frame.name, "style"))) return frame.name;
        }
        return null;
    }
    fn open(self: *Context, tag: Tag) !void {
        if (!self.state.skip) {
            if (tag.is("p")) {
                // An unclosed paragraph ends at the next one only within its
                // own container, never across an enclosing cell, item or div.
                var i = self.depth;
                while (i != 0) {
                    i -= 1;
                    const name = self.stack[i].name;
                    if (std.ascii.eqlIgnoreCase(name, "p")) {
                        while (self.depth > i) try self.pop();
                        break;
                    }
                    var boundary = false;
                    for ([_][]const u8{ "table", "td", "th", "li", "blockquote", "div" }) |v| boundary = boundary or std.ascii.eqlIgnoreCase(name, v);
                    if (boundary) break;
                }
            }
            if (tag.is("li") or tag.is("tr") or tag.is("td") or tag.is("th")) {
                // Implicit sibling closure must never consume an ancestor list
                // item/row when entering a nested list or layout table.
                var i = self.depth;
                while (i != 0) {
                    i -= 1;
                    const name = self.stack[i].name;
                    if ((tag.is("li") and (std.ascii.eqlIgnoreCase(name, "ol") or std.ascii.eqlIgnoreCase(name, "ul"))) or
                        (!tag.is("li") and std.ascii.eqlIgnoreCase(name, "table"))) break;
                    if (std.ascii.eqlIgnoreCase(name, tag.name)) {
                        try self.close(tag.name);
                        break;
                    }
                }
            }
        }
        // HTML non-void tags ignore a trailing solidus. In particular a
        // <script/> must keep skipping its contents, and an unquoted href's
        // final slash remains URL data. Foreign svg/math roots and unknown or
        // Office-namespaced (o:/v:/w:) elements may self-close.
        const leaf = voidTag(tag.name) or (tag.self_closing and (tag.is("svg") or tag.is("math") or !knownTag(tag.name) or std.mem.indexOfScalar(u8, tag.name, ':') != null));
        if (!leaf and self.depth == Limits.depth) {
            if (!self.options.lenient) return error.HtmlTooComplex;
            // No frame can record this element: it stays transparent, with
            // no style or structure of its own. A hidden element cannot be
            // bounded without a frame, so the view ends instead of leaking it.
            if (!self.state.skip) {
                if (try hidden(tag, self.a)) {
                    self.truncated = true;
                    return;
                }
                if (blockTag(tag.name)) try self.begin();
            }
            self.overflow += 1;
            return;
        }
        const before = self.state;
        self.state.skip = self.state.skip or try hidden(tag, self.a);
        var is_data = false;
        var next_ordinal: u32 = 1;
        if (!self.state.skip) {
            // Finish any outer separator before entering the anchor. Then a
            // pending space at its closing edge was supplied inside this link.
            if (tag.is("a")) try self.flushPendingSpace();
            if (tag.is("b") or tag.is("strong")) self.state.style.bold = true;
            if (tag.is("i") or tag.is("em")) self.state.style.italic = true;
            if (tag.is("u")) self.state.style.underline = true;
            if (tag.is("s") or tag.is("strike") or tag.is("del")) self.state.style.strike = true;
            if (tag.is("code") or tag.is("kbd") or tag.is("samp")) self.state.style.code = true;
            if (self.options.generated_markdown and self.state.pre and self.state.style.code and tag.is("span")) {
                if (tag.attribute("class")) |class| self.state.style.code_token = generatedCodeToken(class);
            }
            if (self.options.generated_markdown and !self.state.pre and !self.state.style.code) {
                if (tag.attribute("class")) |class| {
                    if (tag.is("div") and std.mem.eql(u8, class, "omagma-footer")) self.state.style.footer = .text;
                    if (tag.is("a") and self.state.style.footer != .none and std.mem.eql(u8, class, "omagma-footer-link")) {
                        // The pending separator retains its grey prefix
                        // ownership when the next label becomes the brand.
                        self.state.style.footer = .link;
                    }
                }
            }
            if (tag.is("a")) {
                self.state.link = if (tag.attribute("href")) |href| try self.safeLink(href) else null;
                // A missing or rejected destination leaves ordinary text.
                if (self.state.link != null) {
                    self.state.style.underline = true;
                    self.anchor_text = false;
                }
            }
            if (blockTag(tag.name)) self.state.spacing = if (tag.is("td") or tag.is("th")) .cell else if (tag.is("div") or tag.is("section") or tag.is("center") or tag.is("tr")) .tight else .loose;
            if (tag.is("blockquote")) {
                self.state.quote_depth +|= 1;
                self.state.kind = .quote;
                self.state.level = @min(self.state.quote_depth, 8);
            }
            if (tag.is("pre")) {
                self.state.pre = true;
                self.state.kind = .pre;
                self.state.style.code = true;
            }
            if (tag.name.len == 2 and (tag.name[0] == 'h' or tag.name[0] == 'H') and tag.name[1] >= '1' and tag.name[1] <= '6') {
                self.state.kind = .heading;
                self.state.level = tag.name[1] - '0';
                self.state.style.bold = true;
            }
            if (tag.is("ol") or tag.is("ul")) {
                self.state.list_depth +|= 1;
                self.state.ordered = tag.is("ol");
                self.state.list_group = self.next_list_group;
                self.next_list_group += 1; // At most Limits.tokens tag opens.
                self.state.list_loose = false;
                self.state.list_paragraph = false;
                if (tag.attribute("start")) |v| next_ordinal = std.fmt.parseInt(u32, v, 10) catch 1;
            }
            if (tag.is("li")) {
                self.state.kind = .list_item;
                self.state.level = @min(self.state.list_depth -| 1, 8);
                self.state.list_paragraph = false;
                var i = self.depth;
                while (i != 0) {
                    i -= 1;
                    if (std.ascii.eqlIgnoreCase(self.stack[i].name, "ol") or std.ascii.eqlIgnoreCase(self.stack[i].name, "ul")) {
                        self.state.ordinal = self.stack[i].next_ordinal;
                        self.state.list_loose = self.stack[i].list_loose;
                        self.stack[i].next_ordinal +|= 1;
                        break;
                    }
                }
                if (tag.attribute("value")) |v| self.state.ordinal = std.fmt.parseInt(u32, v, 10) catch self.state.ordinal;
            }
            if (tag.is("p") and self.state.kind == .list_item) {
                // Explicit paragraphs distinguish loose HTML lists from tight
                // direct li text. Their later blocks retain the item identity.
                self.state.list_loose = true;
                self.state.list_paragraph = true;
                var index = self.depth;
                while (index != 0) {
                    index -= 1;
                    if (std.ascii.eqlIgnoreCase(self.stack[index].name, "ul") or std.ascii.eqlIgnoreCase(self.stack[index].name, "ol")) {
                        self.stack[index].list_loose = true;
                        break;
                    }
                }
            }
            if (tag.is("table")) {
                try self.begin();
                is_data = self.table_depth == 0 and try self.dataTable(tag);
                self.table_depth += 1;
                if (is_data) self.table = .{};
            } else if (self.table != null and tag.is("tr")) {
                try self.finishRow();
            } else if (self.table != null and (tag.is("td") or tag.is("th"))) {
                try self.finishCell();
                try self.flushBlock();
                self.table.?.cell_active = true;
                self.table.?.cell_header = tag.is("th");
                if (tag.is("th")) self.state.style.bold = true;
            } else if (blockTag(tag.name)) try self.begin();
            if (tag.is("br")) try self.lineBreak();
            if (tag.is("hr")) {
                try self.flushBlock();
                if (self.table != null and self.table.?.cell_active) try self.lineBreak() else try self.pushBlock(.{ .kind = .rule });
            }
            if (tag.is("img") and !tinyImage(tag)) {
                // An intentionally empty alt marks decorative/tracking noise,
                // and an image without any description is noise as well. Only
                // an otherwise empty link keeps a generic label to activate.
                const alt = tag.attribute("alt");
                var raw: []const u8 = alt orelse tag.attribute("title") orelse "";
                const long = raw.len > 1024;
                if (long) {
                    var cut: usize = 1024;
                    while (cut > 0 and raw[cut] & 0xc0 == 0x80) cut -= 1;
                    raw = raw[0..cut];
                }
                const caption = std.mem.trim(u8, try decodeAttribute(self.a, raw), " \t\r\n");
                if (caption.len != 0) {
                    try self.rune(' ');
                    try self.text("[Image: ");
                    // Attribute entities have already been decoded once.
                    var cursor: usize = 0;
                    while (cursor < caption.len) {
                        const n = try std.unicode.utf8ByteSequenceLength(caption[cursor]);
                        try self.rune(try std.unicode.utf8Decode(caption[cursor..][0..n]));
                        cursor += n;
                    }
                    if (long) try self.rune(0x2026);
                    try self.text("]");
                    try self.rune(' ');
                } else if (self.state.link != null and !self.anchor_text) {
                    try self.rune(' ');
                    try self.text("[Image]");
                    try self.rune(' ');
                }
            }
        }
        if (leaf) {
            self.state = before;
            return;
        }
        self.stack[self.depth] = .{ .name = tag.name, .before = before, .next_ordinal = next_ordinal, .data_table = is_data, .list_group = if (tag.is("ul") or tag.is("ol")) self.state.list_group else 0 };
        self.depth += 1;
    }
    fn close(self: *Context, name: []const u8) !void {
        if (self.overflow != 0 and !voidTag(name)) {
            // Closers pair with the frameless elements beyond the depth limit.
            self.overflow -= 1;
            if (!self.state.skip and blockTag(name)) try self.flushBlock();
            return;
        }
        var i = self.depth;
        while (i != 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.stack[i].name, name)) {
                while (self.depth > i) try self.pop();
                return;
            }
            // Malicious tag-shaped script/hidden text cannot close an outer
            // visible ancestor and thereby escape its skipped subtree.
            if (self.state.skip and !self.stack[i].before.skip) return;
        }
    }
    fn pop(self: *Context) !void {
        // Keep the closing item's frame available until its final block has
        // captured continuation metadata, including malformed implicit closes.
        const frame = self.stack[self.depth - 1];
        if (!self.state.skip) {
            if (std.ascii.eqlIgnoreCase(frame.name, "table")) {
                if (frame.data_table) try self.finishTable() else try self.flushBlock();
                self.table_depth -|= 1;
            } else if (self.table != null and (std.ascii.eqlIgnoreCase(frame.name, "td") or std.ascii.eqlIgnoreCase(frame.name, "th"))) try self.finishCell() else if (self.table != null and std.ascii.eqlIgnoreCase(frame.name, "tr")) try self.finishRow() else if (blockTag(frame.name)) try self.flushBlock();
        }
        if (!self.state.skip and std.ascii.eqlIgnoreCase(frame.name, "a") and self.pending_space) {
            // Formatting whitespace and image-placeholder spacing at a link's
            // closing edge separate labels, rather than extending its underline.
            // Keep originating code/emphasis.
            self.pending_style.underline = frame.before.style.underline;
            self.pending_link = frame.before.link;
            if (self.pending_style.footer == self.state.style.footer and self.state.style.footer != frame.before.style.footer)
                self.pending_style.footer = frame.before.style.footer;
        }
        self.depth -= 1;
        self.state = frame.before;
    }
    fn finishCell(self: *Context) !void {
        if (self.table == null or !self.table.?.cell_active) return;
        try self.flushSpan();
        if (self.spans.items.len != 0) {
            const first = &self.spans.items[0];
            const last = &self.spans.items[self.spans.items.len - 1];
            first.text = std.mem.trimStart(u8, first.text, " \t\n");
            last.text = std.mem.trimEnd(u8, last.text, " \t\n");
        }
        self.table.?.cell_active = false;
        self.pending_space = false;
        self.last = 0;
        self.newlines = 0;
        self.lead_break = false;
        self.blank_hint = false;
        if (self.cell_count == Limits.cells or self.table.?.cells.items.len == Limits.columns) {
            self.spans.clearRetainingCapacity();
            return self.limit();
        }
        self.cell_count += 1;
        try self.table.?.cells.append(self.a, .{ .spans = try self.spans.toOwnedSlice(self.a), .header = self.table.?.cell_header });
    }
    fn finishRow(self: *Context) !void {
        if (self.table == null) return;
        try self.finishCell();
        if (self.table.?.cells.items.len == 0) return;
        if (self.table.?.rows.items.len == Limits.rows) {
            self.table.?.cells.clearRetainingCapacity();
            return self.limit();
        }
        try self.table.?.rows.append(self.a, .{ .cells = try self.table.?.cells.toOwnedSlice(self.a) });
    }
    fn finishTable(self: *Context) !void {
        if (self.table == null) return;
        try self.finishRow();
        const rows = try self.table.?.rows.toOwnedSlice(self.a);
        self.table = null;
        if (rows.len != 0) try self.pushBlock(.{ .kind = .table, .table = .{ .rows = rows } });
    }
    fn dataTable(self: *Context, opening: Tag) !bool {
        if (opening.attribute("role")) |role| if (std.ascii.eqlIgnoreCase(role, "presentation") or std.ascii.eqlIgnoreCase(role, "none")) return false;
        var offset = opening.end;
        var rows: usize = 0;
        var columns: usize = 0;
        var previous_columns: usize = 0;
        var headers: usize = 0;
        var consistent = true;
        var compact = true;
        var cell_start: ?usize = null;
        while (offset < self.input.len) {
            const next = std.mem.indexOfScalarPos(u8, self.input, offset, '<') orelse break;
            if (std.mem.startsWith(u8, self.input[next..], "<!--")) {
                offset = try self.commentEnd(next + 4);
                continue;
            }
            try self.tick();
            if (self.truncated) return false;
            const tag = (try tagAt(self.input, next, self.options.lenient)) orelse {
                offset = next + 1;
                continue;
            };
            offset = tag.end;
            if (tag.is("table")) {
                if (tag.closing) break else return false;
            }
            if (!tag.closing and tag.is("tr")) {
                if (columns != 0) {
                    consistent = consistent and (previous_columns == 0 or previous_columns == columns);
                    previous_columns = columns;
                }
                rows += 1;
                columns = 0;
                if (rows > Limits.rows) return false;
            }
            if (tag.is("td") or tag.is("th")) {
                if (!tag.closing) {
                    columns += 1;
                    if (columns > Limits.columns) return false;
                    if (tag.is("th")) headers += 1;
                    cell_start = tag.end;
                } else if (cell_start) |start| {
                    compact = compact and next - start <= 160;
                    cell_start = null;
                }
            }
        }
        consistent = consistent and (previous_columns == 0 or previous_columns == columns);
        return headers != 0 or (compact and consistent and rows >= 2 and columns >= 2 and columns <= 6);
    }
};

fn generatedCodeToken(class: []const u8) CodeToken {
    if (std.mem.eql(u8, class, "omagma-syntax-keyword")) return .keyword;
    if (std.mem.eql(u8, class, "omagma-syntax-string")) return .string;
    if (std.mem.eql(u8, class, "omagma-syntax-comment")) return .comment;
    if (std.mem.eql(u8, class, "omagma-syntax-number")) return .number;
    return .none;
}

test "markdown preview: list paragraphs retain item identity through nested children" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p>Before</p><ol start='3'><li><p>Alpha</p><p>detail</p><ul><li>Child</li></ul>tail</li><li><p>Beta</p></li></ol><p>After</p>", a);
    try std.testing.expectEqual(@as(usize, 7), doc.blocks.len);
    const first = doc.blocks[1];
    const detail = doc.blocks[2];
    const child = doc.blocks[3];
    const tail = doc.blocks[4];
    const next = doc.blocks[5];
    try std.testing.expect(first.list_loose and first.list_paragraph and !first.list_continuation);
    try std.testing.expect(detail.list_continuation and detail.list_paragraph and detail.ordinal == 3);
    try std.testing.expectEqual(first.list_group, detail.list_group);
    try std.testing.expect(child.level == 1 and !child.ordered and !child.list_continuation and !child.list_loose);
    try std.testing.expect(child.list_group != first.list_group);
    try std.testing.expect(tail.list_continuation and !tail.list_paragraph and tail.level == 0);
    try std.testing.expectEqual(first.list_group, tail.list_group);
    try std.testing.expect(next.ordinal == 4 and next.list_loose and !next.list_continuation);
    try std.testing.expectEqual(Kind.paragraph, doc.blocks[6].kind);
    try std.testing.expectEqualStrings("Before\nAlpha\ndetail\nChild\ntail\nBeta\nAfter", try Oracle.document(a, doc));
    const malformed = try parse("<ul><li><p>One</p><p>More</p><li>Two</ul><p>Tail", a);
    try std.testing.expectEqual(@as(usize, 4), malformed.blocks.len);
    try std.testing.expect(malformed.blocks[1].list_continuation and !malformed.blocks[2].list_continuation);
    try std.testing.expectEqualStrings("One\nMore\nTwo\nTail", try Oracle.document(a, malformed));
}

test "markdown preview: only explicit generated provenance accepts exact fenced token classes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<p><span class='omagma-syntax-keyword'>Outside</span></p><pre><code><span class='omagma-syntax-keyword' style='color:#000;background:url(https://tracker.example.test)' onclick='run()'>const</span> <span class='omagma-syntax-string'>&quot;&lt;script&gt;&quot;</span> <span class='omagma-syntax-comment'>// note</span> <span class='omagma-syntax-number'>42</span> <span class='omagma-syntax-keyword extra'>unknown</span></code></pre>";
    const received = try parse(source, a);
    for (received.blocks) |block| for (block.spans) |span| try std.testing.expectEqual(CodeToken.none, span.style.code_token);
    const generated = try parseGeneratedMarkdown(source, a);
    try std.testing.expectEqual(CodeToken.none, generated.blocks[0].spans[0].style.code_token);
    var seen: [5]bool = @splat(false);
    for (generated.blocks[1].spans) |span| {
        seen[@backingInt(span.style.code_token)] = true;
        if (std.mem.eql(u8, span.text, "unknown")) try std.testing.expectEqual(CodeToken.none, span.style.code_token);
        try std.testing.expect(span.link == null);
    }
    for (seen) |present| try std.testing.expect(present);
    try std.testing.expectEqualStrings(try Oracle.document(a, received), try Oracle.document(a, generated));
    try std.testing.expectEqualStrings("Outside\nconst \"<script>\" // note 42 unknown", try Oracle.document(a, generated));
}

test "markdown footer: generated provenance accepts only contextual exact footer classes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<p><a class='omagma-footer-link' href='https://example.test'>Ordinary</a></p><div class='omagma-footer' style='color:#ff0000'><img src='cid:omagma-logo@omagma.invalid' alt=''>Sent with <a class='omagma-footer-link' href='https://technologylab-ai.github.io/omagma/' style='text-decoration:none;color:#00ff00'>omagma</a> 🌋</div><p>After</p><div class='omagma-footer extra'>Not branded</div><pre><code><div class='omagma-footer'>Code</div></code></pre>";
    const received = try parse(source, a);
    for (received.blocks) |block| for (block.spans) |span| try std.testing.expectEqual(FooterStyle.none, span.style.footer);
    const generated = try parseGeneratedMarkdown(source, a);
    try std.testing.expectEqualStrings(try Oracle.document(a, received), try Oracle.document(a, generated));
    try std.testing.expectEqual(FooterStyle.none, generated.blocks[0].spans[0].style.footer);
    const footer = generated.blocks[1].spans;
    try std.testing.expectEqual(@as(usize, 3), footer.len);
    try std.testing.expectEqualStrings("Sent with ", footer[0].text);
    try std.testing.expectEqual(FooterStyle.text, footer[0].style.footer);
    try std.testing.expect(!footer[0].style.underline and footer[0].link == null);
    try std.testing.expectEqualStrings("omagma", footer[1].text);
    try std.testing.expectEqual(FooterStyle.link, footer[1].style.footer);
    try std.testing.expect(footer[1].style.underline);
    try std.testing.expectEqualStrings("https://technologylab-ai.github.io/omagma/", footer[1].link.?);
    try std.testing.expectEqualStrings(" 🌋", footer[2].text);
    try std.testing.expectEqual(FooterStyle.text, footer[2].style.footer);
    try std.testing.expect(!footer[2].style.underline and footer[2].link == null);
    for (generated.blocks[2..]) |block| for (block.spans) |span| try std.testing.expectEqual(FooterStyle.none, span.style.footer);
}

const Entity = struct { consumed: usize, codepoint: u21 };
fn entity(input: []const u8) ?Entity {
    if (input.len > 2 and input[1] == '#') {
        const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 32)], ';') orelse return null;
        const name = input[1..end];
        const hex = name.len > 2 and (name[1] == 'x' or name[1] == 'X');
        const value = std.fmt.parseInt(u32, name[if (hex) 2 else 1..], if (hex) 16 else 10) catch return null;
        const cp: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        // Browsers read references to 0x80..0x9f as Windows-1252 punctuation.
        return .{ .consumed = end + 1, .codepoint = entities.numericCodepoint(cp) };
    }
    const match = entities.named(input, true) orelse return null;
    return .{ .consumed = match.consumed, .codepoint = match.codepoint };
}
fn decodeAttribute(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var context: Context = .{ .a = a, .input = input, .state = .{ .pre = true } };
    try context.text(input);
    return context.text_buffer.toOwnedSlice(a);
}

const Oracle = struct {
    fn spans(a: std.mem.Allocator, values: []const Span) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (values) |span| try out.appendSlice(a, span.text);
        return out.toOwnedSlice(a);
    }
    fn document(a: std.mem.Allocator, doc: Document) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (doc.blocks) |block| {
            if (out.items.len != 0) try out.append(a, '\n');
            if (block.table) |table| {
                for (table.rows) |row| for (row.cells) |cell| {
                    for (cell.spans) |span| try out.appendSlice(a, span.text);
                    try out.append(a, '\n');
                };
            } else for (block.spans) |span| try out.appendSlice(a, span.text);
        }
        return out.toOwnedSlice(a);
    }
};

test "semantic HTML preserves headings inline emphasis entities and hard breaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<h2>A &amp; B</h2><p>Normal <strong>bold <em>both</em></strong> <u>under</u> <code>x &lt; y</code> <del>obsolete</del><br>End</p>", a);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expectEqual(Kind.heading, doc.blocks[0].kind);
    try std.testing.expectEqual(@as(u8, 2), doc.blocks[0].level);
    try std.testing.expectEqualStrings("A & B", try Oracle.spans(a, doc.blocks[0].spans));
    try std.testing.expectEqualStrings("Normal bold both under x < y obsolete\nEnd", try Oracle.spans(a, doc.blocks[1].spans));
    var saw_both = false;
    var saw_code = false;
    var saw_strike = false;
    var saw_under = false;
    for (doc.blocks[1].spans) |span| {
        if (std.mem.indexOf(u8, span.text, "both") != null) {
            saw_both = true;
            try std.testing.expect(span.style.bold and span.style.italic);
        }
        if (std.mem.indexOf(u8, span.text, "x < y") != null) {
            saw_code = true;
            try std.testing.expect(span.style.code);
        }
        if (std.mem.indexOf(u8, span.text, "obsolete") != null) {
            saw_strike = true;
            try std.testing.expect(span.style.strike);
        }
        if (std.mem.indexOf(u8, span.text, "under") != null) {
            saw_under = true;
            try std.testing.expect(span.style.underline);
        }
    }
    try std.testing.expect(saw_both and saw_code and saw_strike and saw_under);
}

test "hidden HTML scripts hostile outer closers comments and controls cannot escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<head><title>Hidden title</title></head><p>Shown<script>bad </p> LEAK </script> Tail<span hidden>secret</span><span style='DISPLAY: none !important'>secret2</span><template>secret3</template><svg>secret4</svg><!--secret5-->&#27;[31m &#x202E;&#x061c;&#x200e;&#x200f;safe &lt;script&gt; &#0;&#x110000;&#xD800;</p>", a);
    const text = try Oracle.document(a, doc);
    try std.testing.expectEqualStrings("Shown Tail[31m safe <script> ���", text);
    try std.testing.expect(std.mem.indexOf(u8, text, "secret") == null and std.mem.indexOf(u8, text, "LEAK") == null);
    for (text) |c| try std.testing.expect(c != 27);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "HTML lists quotes preformatted CRLF and owned safe link destinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<ol start='3'><li>One<ul><li>Nested</li></ul></li><li>Two</li></ol><blockquote><p>Quote</p></blockquote><pre>  a\t b\r\n c</pre><p><a href='https://example.test/?a=1&amp;b=2'>Visit</a> <a href='javascript:evil()'>Unsafe label</a><img src='https://tracking.example.test/pixel' alt='Caption &amp; text'></p>", a);
    try std.testing.expectEqual(Kind.list_item, doc.blocks[0].kind);
    try std.testing.expect(doc.blocks[0].ordered and doc.blocks[0].ordinal == 3);
    try std.testing.expectEqual(Kind.list_item, doc.blocks[1].kind);
    try std.testing.expect(!doc.blocks[1].ordered and doc.blocks[1].level == 1);
    try std.testing.expectEqual(@as(u32, 4), doc.blocks[2].ordinal);
    try std.testing.expectEqual(Kind.quote, doc.blocks[3].kind);
    try std.testing.expectEqual(Kind.pre, doc.blocks[4].kind);
    try std.testing.expectEqualStrings("  a\t b\n c", try Oracle.spans(a, doc.blocks[4].spans));
    var found = false;
    for (doc.blocks[5].spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Visit") != null) {
            found = true;
            try std.testing.expectEqualStrings("https://example.test/?a=1&b=2", span.link.?);
        }
        if (std.mem.indexOf(u8, span.text, "Unsafe label") != null) try std.testing.expect(span.link == null);
    }
    try std.testing.expect(found);
    try std.testing.expect(std.mem.indexOf(u8, try Oracle.document(a, doc), "Caption & text") != null);
    const original = try a.dupe(u8, "<p><a href='https://example.test'>Owned</a></p>");
    const owned = try parse(original, a);
    @memset(original, 'x');
    try std.testing.expectEqualStrings("Owned", try Oracle.spans(a, owned.blocks[0].spans));
    try std.testing.expectEqualStrings("https://example.test", owned.blocks[0].spans[0].link.?);
    const slash = try parse("<script/>secret</script><style/>secret2</style><p><a href=https://example.test/>Visit</a><br/>Tail<svg/> End</p>", a);
    try std.testing.expectEqualStrings("Visit\nTail End", try Oracle.document(a, slash));
    try std.testing.expectEqualStrings("https://example.test/", slash.blocks[0].spans[0].link.?);
}

test "HTML data tables retain caption headers cells while newsletter layout tables flatten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<table><caption>Quarter totals</caption><tr><th>Item</th><th>Amount</th></tr><tr><td><b>One</b></td><td>€ 12</td></tr></table>", a);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expectEqualStrings("Quarter totals", try Oracle.spans(a, doc.blocks[0].spans));
    try std.testing.expectEqual(Kind.table, doc.blocks[1].kind);
    const table = doc.blocks[1].table.?;
    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expect(table.rows[0].cells[0].header);
    try std.testing.expectEqualStrings("Item", try Oracle.spans(a, table.rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("€ 12", try Oracle.spans(a, table.rows[1].cells[1].spans));
    try std.testing.expect(table.rows[1].cells[0].spans[0].style.bold);
    const short = try parse("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>", a);
    try std.testing.expectEqual(Kind.table, short.blocks[0].kind);
    const layout = try parse("<table role='presentation'><tr><td>Outer<table><tr><th>Nested</th></tr></table>Tail</td></tr></table>", a);
    for (layout.blocks) |block| try std.testing.expect(block.kind != .table);
    try std.testing.expectEqualStrings("Outer\nNested\nTail", try Oracle.document(a, layout));
}

test "HTML complexity bounds and allocation failures leave arena-owned output cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidUtf8, parse(&.{0xff}, a));
    const oversized = try a.alloc(u8, 2097153);
    @memset(oversized, 'x');
    try std.testing.expectError(error.HtmlTooLarge, parse(oversized, a));
    var deep: std.ArrayList(u8) = .empty;
    for (0..129) |_| try deep.appendSlice(a, "<div>");
    try std.testing.expectError(error.HtmlTooComplex, parse(deep.items, a));
    var blocks: std.ArrayList(u8) = .empty;
    for (0..Limits.blocks + 1) |_| try blocks.appendSlice(a, "<p>x</p>");
    try std.testing.expectError(error.HtmlTooComplex, parse(blocks.items, a));
    // Showing received mail keeps everything built before the same limits.
    const kept = try parseLenient(blocks.items, a);
    try std.testing.expect(kept.truncated);
    try std.testing.expectEqual(@as(usize, Limits.blocks), kept.blocks.len);
    try deep.appendSlice(a, "<b>Deep</b> text</div><p>Tail</p>");
    const transparent = try parseLenient(deep.items, a);
    try std.testing.expect(!transparent.truncated);
    try std.testing.expectEqualStrings("Deep text\nTail", try Oracle.document(a, transparent));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(backing: std.mem.Allocator) !void {
            var scratch = std.heap.ArenaAllocator.init(backing);
            defer scratch.deinit();
            const doc = try parse("<h1>Title</h1><p><a href='https://example.test'>Link</a> <b>bold</b></p><table><tr><th>Name</th></tr><tr><td>Value</td></tr></table>", scratch.allocator());
            try std.testing.expectEqual(@as(usize, 3), doc.blocks.len);
        }
    }.run, .{});
}

test "large token capacity reservation preserves preceding style and complete bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try a.alloc(u8, "<p><b>prefix</b>".len + 4096 + "</p>".len);
    @memcpy(input[0.."<p><b>prefix</b>".len], "<p><b>prefix</b>");
    @memset(input["<p><b>prefix</b>".len..][0..4096], 'x');
    @memcpy(input[input.len - "</p>".len ..], "</p>");
    const doc = try parse(input, a);
    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[0].spans.len);
    try std.testing.expectEqualStrings("prefix", doc.blocks[0].spans[0].text);
    try std.testing.expect(doc.blocks[0].spans[0].style.bold);
    try std.testing.expect(!doc.blocks[0].spans[1].style.bold);
    try std.testing.expectEqual(@as(usize, 4096), doc.blocks[0].spans[1].text.len);
    for (doc.blocks[0].spans[1].text) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}

test "HTML reader repairs malformed tag boundaries without leaking attributes or losing code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const broken_quote = try parse("<p>Before <span class='broken<p>Visible</p>", a);
    try std.testing.expectEqualStrings("Before\nVisible", try Oracle.document(a, broken_quote));
    const interrupted = try parse("<p>Before <span class=x <b>Visible</b> after</p>", a);
    try std.testing.expectEqualStrings("Before Visible after", try Oracle.document(a, interrupted));
    const truncated = try parse("<p>Before<span class=unfinished", a);
    try std.testing.expectEqualStrings("Before", try Oracle.document(a, truncated));
    const literal = try parse("<pre>std::vector<T>\nx < y &amp;&amp; y > z\n<custom>literal</custom></pre><p>&lt;span class=&quot;x&quot;&gt; &amp;lt;script&amp;gt; &LT;tag&GT; &AMP;</p>", a);
    try std.testing.expectEqualStrings("std::vector<T>\nx < y && y > z\n<custom>literal</custom>\n<span class=\"x\"> &lt;script&gt; <tag> &", try Oracle.document(a, literal));
    const address = try parse("<p>Contact <person@example.test> or compare x < y.</p>", a);
    try std.testing.expectEqualStrings("Contact <person@example.test> or compare x < y.", try Oracle.document(a, address));
}

test "HTML reader ignores raw script strings Office metadata and decoded hidden CSS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try parse("<p>Before<script>const x = '<script>'; bad </p></script> after<style>p:before{content:'<style>'}</style> tail</p>", a);
    try std.testing.expectEqualStrings("Before after tail", try Oracle.document(a, raw));
    const office = try parse("<!DOCTYPE html [<!ENTITY marker 'hidden > metadata'>]><xml><o:DocumentProperties><o:Author>Metadata author</o:Author></o:DocumentProperties></xml><o:OfficeDocumentSettings>Hidden settings</o:OfficeDocumentSettings><p>Visible<o:p>&nbsp;</o:p> text<!--hidden --!> tail</p>", a);
    try std.testing.expectEqualStrings("Visible text tail", try Oracle.document(a, office));
    const styles = try parse("<p>Shown<span style='d&#105;splay:/**/n&#111;ne !important'>Hidden</span><span style='visibility&#58; hidden'>Hidden2</span><span style='mso-hide:all'>Hidden3</span> End</p>", a);
    try std.testing.expectEqualStrings("Shown End", try Oracle.document(a, styles));
}

test "HTML reader image placeholders use alt title or generic label without tracking resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p>Start<img src='https://example.test/pixel?private=unused' alt='Map &amp; route'><img title='Diagram &lt;T&gt;'><img><img alt='' title='Decorative'><img alt='   '><img hidden alt='Hidden'><img alt='&amp;lt;literal&amp;gt;'>End</p>", a);
    try std.testing.expectEqualStrings("Start [Image: Map & route] [Image: Diagram <T>] [Image: &lt;literal&gt;] End", try Oracle.document(a, doc));
    for (doc.blocks) |block| for (block.spans) |span| {
        try std.testing.expect(span.link == null);
        try std.testing.expect(std.mem.indexOf(u8, span.text, "private") == null);
    };
}

test "HTML reader leaves orphan CSS and escaped tutorials literal without guessing markup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p>Technical note: .sample { color: red; } &lt;div&gt;</p><pre>&lt;style&gt;body { display: none; }&lt;/style&gt;</pre>", a);
    try std.testing.expectEqualStrings("Technical note: .sample { color: red; } <div>\n<style>body { display: none; }</style>", try Oracle.document(a, doc));
}

test "reader polish: deferred whitespace retains its inline source style across tag boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p>Before <strong><code>DEMO </code></strong>after.</p>", a);
    var text: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    for (doc.blocks[0].spans) |span| {
        try text.appendSlice(a, span.text);
        for (span.text, 0..) |_, i| {
            const at = offset + i;
            if (at == 6) try std.testing.expect(!span.style.code and !span.style.bold);
            if (at >= 7 and at <= 11) try std.testing.expect(span.style.code and span.style.bold);
            if (at >= 12) try std.testing.expect(!span.style.code and !span.style.bold);
        }
        offset += span.text.len;
    }
    try std.testing.expectEqualStrings("Before DEMO after.", text.items);
}

fn repeatedForTest(comptime value: []const u8, comptime count: usize) [value.len * count]u8 {
    @setEvalBranchQuota(200_000);
    var output: [value.len * count]u8 = undefined;
    for (0..count) |index| @memcpy(output[index * value.len ..][0..value.len], value);
    return output;
}

test "HTML reader drops empty blocks, caps break runs and marks tight wrapper blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<div>A</div><div><br></div><div><br></div><div>B</div><div>C<br><br></div><div>D<br></div><div>\u{200b}&nbsp;</div><p>&#8203;&zwnj;\u{feff}</p>" ++
        "<table role='presentation'><tr><td>&nbsp;</td></tr><tr><td>E</td></tr><tr><td><br>F<br><br><br><br>G<br></td></tr></table><section>H</section><p>I</p><center>J</center><pre>  \n </pre>", a);
    const expected = [_]struct { []const u8, bool }{ .{ "A", false }, .{ "B", false }, .{ "C", true }, .{ "D", false }, .{ "E", false }, .{ "F\n\nG", false }, .{ "H", true }, .{ "I", false }, .{ "J", false } };
    try std.testing.expectEqual(expected.len, doc.blocks.len);
    for (expected, doc.blocks) |want, block| {
        try std.testing.expectEqualStrings(want[0], try Oracle.spans(a, block.spans));
        try std.testing.expectEqual(want[1], block.tight);
    }
    // Different kinds or quote depths never join, and pre keeps its breaks.
    const mixed = try parse("<div>Reply</div><blockquote><div>Q1</div><div>Q2</div></blockquote><div>Tail</div><pre>a\n\n\n\nb</pre>", a);
    try std.testing.expectEqualStrings("Reply\nQ1\nQ2\nTail\na\n\n\n\nb", try Oracle.document(a, mixed));
    for (mixed.blocks, [_]bool{ false, false, true, false, false }) |block, tight| try std.testing.expectEqual(tight, block.tight);
}

test "HTML reader omits tracking pixels and undescribed images but labels image-only links" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = comptime repeatedForTest("é", 600);
    const doc = try parse("<p>A<img src='https://tracker.example.test/open'><img alt='Pixel' width='1' height='1'><img alt='Spacer' height=' 2px '><img alt='Wide' width='100%'>B" ++
        "<a href='https://example.test/shop'><img src='cid:logo'></a> <a href='https://example.test/b'><img alt=''></a> <a href='https://example.test/c'>Text<img></a>" ++
        "<a href='javascript:run()'><img></a><img alt='" ++ long ++ "'></p>", a);
    const text = try Oracle.document(a, doc);
    try std.testing.expect(std.mem.startsWith(u8, text, "A [Image: Wide] B [Image] "));
    // An over-long description is cut on a character boundary, not refused.
    try std.testing.expect(std.mem.endsWith(u8, text, "Text [Image: " ++ (comptime repeatedForTest("é", 512)) ++ "…]"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "[Image]"));
    try std.testing.expect(std.mem.indexOf(u8, text, "tracker") == null and std.mem.indexOf(u8, text, "Pixel") == null and std.mem.indexOf(u8, text, "Spacer") == null);
    var labelled: usize = 0;
    for (doc.blocks[0].spans) |span| if (std.mem.indexOf(u8, span.text, "[Image]") != null) {
        labelled += 1;
        try std.testing.expect(span.link != null);
    };
    try std.testing.expectEqual(@as(usize, 2), labelled);
}

test "HTML reader lenient limits truncate work spans and hidden overflow without refusing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tokens: std.ArrayList(u8) = .empty;
    try tokens.appendSlice(a, "<p>Start</p><p>Open ");
    for (0..Limits.tokens / 2 + 8) |_| try tokens.appendSlice(a, "<b></b>");
    try tokens.appendSlice(a, "</p><p>Never</p>");
    try std.testing.expectError(error.HtmlTooComplex, parse(tokens.items, a));
    const worked = try parseLenient(tokens.items, a);
    try std.testing.expect(worked.truncated);
    try std.testing.expectEqualStrings("Start\nOpen", try Oracle.document(a, worked));
    var spans: std.ArrayList(u8) = .empty;
    try spans.appendSlice(a, "<p>");
    for (0..Limits.spans / 2 + 8) |_| try spans.appendSlice(a, "<b>x</b>y");
    try std.testing.expectError(error.HtmlTooComplex, parse(spans.items, a));
    const styled = try parseLenient(spans.items, a);
    try std.testing.expect(styled.truncated);
    try std.testing.expectEqual(@as(usize, 1), styled.blocks.len);
    try std.testing.expectEqual(@as(usize, Limits.spans), styled.blocks[0].spans.len);
    // A hidden element beyond the depth limit has no frame to bound it.
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(a, "<p>Shown</p>");
    for (0..Limits.depth) |_| try deep.appendSlice(a, "<div>");
    try deep.appendSlice(a, "Deep<span style='display:none'>secret</span>after");
    const hiding = try parseLenient(deep.items, a);
    try std.testing.expect(hiding.truncated);
    try std.testing.expectEqualStrings("Shown\nDeep", try Oracle.document(a, hiding));
    // Unknown and Office-namespaced elements honour a trailing solidus.
    const closed = try parse("<o:OfficeDocumentSettings/><p>A<custom/>B<o:p/>C<v:shape id='x' />D</p><w:WordDocument/><p>E</p>", a);
    try std.testing.expectEqualStrings("ABCD\nE", try Oracle.document(a, closed));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(backing: std.mem.Allocator) !void {
            var scratch = std.heap.ArenaAllocator.init(backing);
            defer scratch.deinit();
            const doc = try parseLenient("<head><title>T<body><div>A</div><div><br></div><a href=' https://example.test '><img></a><!-- open <p>&copy 2026</p>", scratch.allocator());
            try std.testing.expectEqual(@as(usize, 3), doc.blocks.len);
        }
    }.run, .{});
}

test "HTML reader survives one over-long or unbalanced tag only when lenient" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filler = comptime repeatedForTest("A", Limits.tag_bytes + 512);
    const inline_image = "<p>Before<img alt='Chart' src=\"data:image/png;base64," ++ filler ++ "\" width='300'>After <a title=\"" ++ filler ++ "\" href='https://example.test/late'>Late</a></p>";
    try std.testing.expectError(error.HtmlTooComplex, parse(inline_image, a));
    const image = try parseLenient(inline_image, a);
    try std.testing.expect(!image.truncated);
    try std.testing.expectEqualStrings("Before [Image: Chart] After Late", try Oracle.document(a, image));
    // The cut attribute and everything after it are unreadable, never guessed.
    for (image.blocks[0].spans) |span| try std.testing.expect(span.link == null);
    const unbalanced = try parseLenient("<p>One <a class='x' href=\"https://example.test/x>Label</a> two</p><p>" ++ filler ++ "</p><p>Tail</p>", a);
    const text = try Oracle.document(a, unbalanced);
    try std.testing.expect(std.mem.startsWith(u8, text, "One Label two\nAAAA") and std.mem.endsWith(u8, text, "AAAA\nTail"));
    for (unbalanced.blocks[0].spans) |span| try std.testing.expect(span.link == null and !span.style.underline);
    const declaration = try parseLenient("<!DOCTYPE html " ++ filler ++ "><p>Body</p><script>x</script " ++ filler ++ "><p>Tail</p>", a);
    try std.testing.expectEqualStrings("Body\nTail", try Oracle.document(a, declaration));
}

test "HTML reader recovers the body after unclosed head title comment or style" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, []const u8 }{
        .{ "<html><head><meta charset='utf-8'><title>Subject</title><style>p{margin:0}</style><body><p>Body</p></body></html>", "Body" },
        .{ "<head><title>Subject<div>Body</div>", "Body" },
        .{ "<title>Hidden</title><p>Shown</p>", "Shown" },
        .{ "<p>A</p><!-- note without end <span>hidden</span><p>B</p><!-- again <p>C</p>", "A\nB\nC" },
        .{ "<p>A</p><!--><p>B</p><!---><p>C</p>", "A\nB\nC" },
        .{ "<p>A</p><style>p{color:red} .x{}<table><tr><td>B</td></tr></table><style>q{}</div><p>C", "A\nB\nC" },
        .{ "<p>A</p><script>var a = '<p>code</p>';<p>hidden", "A" },
        .{ "<div hidden><title>T<p>still hidden</p></div><p>B</p>", "B" },
    }) |case| try std.testing.expectEqualStrings(case[1], try Oracle.document(a, try parse(case[0], a)));
    // Repeated unterminated constructs stay linear: one failed search each.
    var many: std.ArrayList(u8) = .empty;
    for (0..20000) |_| try many.appendSlice(a, "<!-- x <style>y<p>z</p>");
    const doc = try parseLenient(many.items, a);
    try std.testing.expect(doc.truncated and doc.blocks.len == Limits.blocks);
}

test "HTML reader decodes the shared entity table, bare legacy names and Windows-1252 references" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p>&#146;&#x93;quoted&#148; &#128;5 &hellip; &bdquo;x&ldquo; &Omega;&omega; &check; caf&eacute &copy 2026 &notanentity; AT&T &amp;copy; a&zwnj;b &lrm;&shy;c&hairsp;d&#129;</p><p><a href='https://example.test/?a=1&copy=2&amp;reg=3&region=4'>Link</a></p>", a);
    try std.testing.expectEqualStrings("’“quoted” €5 … „x“ Ωω ✓ café © 2026 &notanentity; AT&T &copy; a\u{200c}b c d", try Oracle.spans(a, doc.blocks[0].spans));
    try std.testing.expectEqualStrings("https://example.test/?a=1&copy=2&reg=3&region=4", doc.blocks[1].spans[0].link.?);
}

test "HTML reader removes invisible fillers, collapses Unicode spaces and hides zero-size preheaders" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p>A\u{200b}\u{2060}\u{feff}\u{034f}\u{180e}B\u{2003}\u{2009}C\u{3000}D\u{202f}\u{205f}E \u{200d}\u{200c}F\u{200c}G 👩‍💻</p><p>\u{200d}\u{200c}</p><pre>x\u{2003}y\u{200b}z</pre>", a);
    try std.testing.expectEqualStrings("AB C D E F\u{200c}G 👩‍💻\nx\u{2003}yz", try Oracle.document(a, doc));
    const hidden_css = try parse("<div style='max-height:0px; overflow:hidden'>h1</div><span style='font-size:0'>h2</span><span style='OPACITY: 0 !important'>h3</span><div style='width:0;height:0px'>h4</div><div style='font-size:0.0em'>h5</div>" ++
        "<span style='opacity:0.5'>Shown</span><div style='max-height:0'>Kept</div><div style='overflow:hidden;max-height:40px;width:0'>Also</div><div style='font-size:10px'>Sized</div>", a);
    try std.testing.expectEqualStrings("Shown\nKept\nAlso\nSized", try Oracle.document(a, hidden_css));
}

test "HTML reader links trim wrapped destinations and underline only accepted ones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "https://example.test/" ++ (comptime repeatedForTest("p", 3900));
    const doc = try parse("<p><a href=' \n https://example.test/a\r\n\tb?c=d  '>Wrapped</a> <a href='javascript:run()'>Script</a> <a name='anchor'>Named</a> <a href='https://example.test/a b'>Spaced</a> <a href='" ++ long ++ "'>Long</a> <a href='" ++ long ++ (comptime repeatedForTest("q", 200)) ++ "'>Longer</a></p>", a);
    var seen: usize = 0;
    for (doc.blocks[0].spans) |span| {
        const label = std.mem.trim(u8, span.text, " ");
        if (label.len == 0) continue;
        seen += 1;
        if (std.mem.eql(u8, label, "Wrapped")) try std.testing.expectEqualStrings("https://example.test/ab?c=d", span.link.?);
        if (std.mem.eql(u8, label, "Long")) try std.testing.expectEqualStrings(long, span.link.?);
        const accepted = std.mem.eql(u8, label, "Wrapped") or std.mem.eql(u8, label, "Long");
        try std.testing.expectEqual(accepted, span.link != null);
        try std.testing.expectEqual(accepted, span.style.underline);
    }
    // Rejected anchors are plain prose and merge with their neighbours:
    // Wrapped, "Script Named Spaced", Long, Longer.
    try std.testing.expectEqual(@as(usize, 4), seen);
}

test "HTML reader implicit paragraph closing stays inside the nearest container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse("<p><b>Outer<div><p>Inner</p>after</div></b></p><p>One<p>Two<blockquote><p>Three<p>Four</blockquote>", a);
    try std.testing.expectEqualStrings("Outer\nInner\nafter\nOne\nTwo\nThree\nFour", try Oracle.document(a, doc));
    // The inner paragraph must not close the outer one through the div and
    // thereby drop the enclosing emphasis.
    try std.testing.expect(doc.blocks[1].spans[0].style.bold and doc.blocks[2].spans[0].style.bold);
    try std.testing.expect(!doc.blocks[3].spans[0].style.bold);
    try std.testing.expectEqual(Kind.quote, doc.blocks[5].kind);
    try std.testing.expectEqual(Kind.quote, doc.blocks[6].kind);
}
