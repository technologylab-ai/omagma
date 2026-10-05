const std = @import("std");

pub const Limits = struct {
    pub const input_bytes = 2 * 1024 * 1024;
    pub const text_bytes = 2 * 1024 * 1024;
    pub const blocks = 1024;
    pub const spans = 8192;
    pub const cells = 4096;
    pub const columns = 32;
    pub const rows = 256;
    pub const depth = 128;
    pub const tokens = 32768;
    pub const tag_bytes = 8192;
    pub const link_bytes = 2048;
    pub const all_link_bytes = 256 * 1024;
};
pub const Style = packed struct { bold: bool = false, italic: bool = false, underline: bool = false, code: bool = false, strike: bool = false };
pub const Span = struct { text: []const u8, style: Style = .{}, link: ?[]const u8 = null };
pub const Kind = enum { paragraph, heading, pre, list_item, quote, rule, table };
pub const Cell = struct { spans: []const Span, header: bool = false };
pub const Row = struct { cells: []const Cell };
pub const Table = struct { rows: []const Row };
pub const Block = struct { kind: Kind, spans: []const Span = &.{}, level: u8 = 0, ordered: bool = false, ordinal: u32 = 1, table: ?Table = null };
pub const Document = struct { blocks: []const Block };

/// Caller owns every result and scratch allocation: use an arena and keep it
/// alive while displaying Document. Output text/URLs never borrow input. Errors
/// mean the viewer should use its existing plain fallback, not refuse the mail.
/// This is a semantic mail filter, with no CSS engine, resource loads or actions.
pub fn parse(input: []const u8, allocator: std.mem.Allocator) !Document {
    if (input.len > Limits.input_bytes) return error.HtmlTooLarge;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var context: Context = .{ .a = allocator, .input = input };
    var offset: usize = 0;
    while (offset < input.len) {
        try context.tick();
        if (std.mem.startsWith(u8, input[offset..], "<!--")) {
            offset = if (std.mem.indexOf(u8, input[offset + 4 ..], "-->")) |end| offset + 4 + end + 3 else input.len;
        } else if (input[offset] == '<') {
            if (try tagAt(input, offset)) |tag| {
                offset = tag.end;
                if (tag.name.len == 0) continue;
                if (tag.closing) try context.close(tag.name) else try context.open(tag);
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
    return .{ .blocks = try context.blocks.toOwnedSlice(allocator) };
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
fn tagAt(input: []const u8, start: usize) !?Tag {
    if (start + 1 >= input.len) return null;
    var i = start + 1;
    var closing = false;
    if (input[i] == '/') {
        closing = true;
        i += 1;
    }
    if (i >= input.len) return null;
    if (input[i] == '!' or input[i] == '?') {
        const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse return .{ .name = "", .attributes = "", .end = input.len };
        if (end - start > Limits.tag_bytes) return error.HtmlTooComplex;
        return .{ .name = "", .attributes = "", .end = end + 1 };
    }
    if (!std.ascii.isAlphabetic(input[i])) return null;
    const name_start = i;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == ':' or input[i] == '-')) : (i += 1) {}
    const name = input[name_start..i];
    const attributes_start = i;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        if (i - start > Limits.tag_bytes) return error.HtmlTooComplex;
        if (quote != 0) {
            if (input[i] == quote) quote = 0;
            continue;
        }
        if (input[i] == '"' or input[i] == '\'') {
            quote = input[i];
            continue;
        }
        if (input[i] == '>') {
            const attrs = std.mem.trimEnd(u8, input[attributes_start..i], " \t\r\n");
            return .{ .name = name, .attributes = attrs, .end = i + 1, .closing = closing, .self_closing = std.mem.endsWith(u8, attrs, "/") };
        }
    }
    return null;
}
fn voidTag(name: []const u8) bool {
    for ([_][]const u8{ "br", "hr", "img", "meta", "link", "input", "area", "base", "col", "embed", "source", "track", "wbr" }) |v| if (std.ascii.eqlIgnoreCase(name, v)) return true;
    return false;
}
fn blockTag(name: []const u8) bool {
    for ([_][]const u8{ "p", "div", "section", "article", "main", "header", "footer", "address", "figure", "figcaption", "caption", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "li", "blockquote", "tr", "td", "th", "table" }) |v| if (std.ascii.eqlIgnoreCase(name, v)) return true;
    return false;
}
fn hidden(tag: Tag) bool {
    for ([_][]const u8{ "head", "style", "script", "template", "svg", "noscript", "iframe", "object", "canvas", "math" }) |v| if (tag.is(v)) return true;
    if (tag.attribute("hidden") != null) return true;
    if (tag.attribute("aria-hidden")) |v| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t\r\n"), "true")) return true;
    if (tag.attribute("style")) |style| {
        var properties = std.mem.splitScalar(u8, style, ';');
        while (properties.next()) |property| {
            const colon = std.mem.indexOfScalar(u8, property, ':') orelse continue;
            const key = std.mem.trim(u8, property[0..colon], " \t\r\n");
            const value = std.mem.trim(u8, property[colon + 1 ..], " \t\r\n");
            const end = std.mem.indexOfAny(u8, value, " !\t\r\n") orelse value.len;
            if ((std.ascii.eqlIgnoreCase(key, "display") and std.ascii.eqlIgnoreCase(value[0..end], "none")) or
                (std.ascii.eqlIgnoreCase(key, "visibility") and std.ascii.eqlIgnoreCase(value[0..end], "hidden")) or
                (std.ascii.eqlIgnoreCase(key, "mso-hide") and std.ascii.eqlIgnoreCase(value[0..end], "all"))) return true;
        }
    }
    return false;
}

const State = struct { style: Style = .{}, link: ?[]const u8 = null, skip: bool = false, pre: bool = false, kind: Kind = .paragraph, level: u8 = 0, ordered: bool = false, ordinal: u32 = 1, list_depth: u8 = 0, quote_depth: u8 = 0 };
const Frame = struct { name: []const u8, before: State, next_ordinal: u32 = 1, data_table: bool = false };
const TableBuilder = struct { rows: std.ArrayList(Row) = .empty, cells: std.ArrayList(Cell) = .empty, cell_active: bool = false, cell_header: bool = false };
const Context = struct {
    a: std.mem.Allocator,
    input: []const u8,
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
    table_depth: usize = 0,
    table: ?TableBuilder = null,
    fn tick(self: *Context) !void {
        self.work += 1;
        if (self.work > Limits.tokens) return error.HtmlTooComplex;
    }
    fn pushBlock(self: *Context, block: Block) !void {
        if (self.blocks.items.len == Limits.blocks) return error.HtmlTooComplex;
        try self.blocks.append(self.a, block);
    }
    fn sameLink(a: ?[]const u8, b: ?[]const u8) bool {
        return if (a) |v| if (b) |w| std.mem.eql(u8, v, w) else false else b == null;
    }
    fn flushSpan(self: *Context) !void {
        if (self.text_buffer.items.len == 0) return;
        if (self.span_count == Limits.spans) return error.HtmlTooComplex;
        self.span_count += 1;
        try self.spans.append(self.a, .{ .text = try self.text_buffer.toOwnedSlice(self.a), .style = self.buffer_style, .link = self.buffer_link });
    }
    fn flushBlock(self: *Context) !void {
        if (self.table != null and self.table.?.cell_active) {
            try self.lineBreak();
            return;
        }
        try self.flushSpan();
        if (self.spans.items.len != 0) {
            const last = &self.spans.items[self.spans.items.len - 1];
            if (!self.block_state.pre) last.text = std.mem.trimEnd(u8, last.text, " \t\n");
            try self.pushBlock(.{ .kind = self.block_state.kind, .spans = try self.spans.toOwnedSlice(self.a), .level = self.block_state.level, .ordered = self.block_state.ordered, .ordinal = self.block_state.ordinal });
        }
        self.pending_space = false;
    }
    fn append(self: *Context, bytes: []const u8) !void {
        if (bytes.len > Limits.text_bytes - self.text_count) return error.HtmlTooLarge;
        self.text_count += bytes.len;
        if (self.text_buffer.items.len == 0 and self.spans.items.len == 0) self.block_state = self.state;
        if (!std.meta.eql(self.buffer_style, self.state.style) or !sameLink(self.buffer_link, self.state.link)) try self.flushSpan();
        self.buffer_style = self.state.style;
        self.buffer_link = self.state.link;
        try self.text_buffer.appendSlice(self.a, bytes);
    }
    fn rune(self: *Context, raw: u21) !void {
        var cp = raw;
        if (cp == 13) cp = 10;
        if ((cp < 32 and cp != 10 and cp != 9) or (cp >= 127 and cp <= 159) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xad) return;
        if (!self.state.pre and (cp == 10 or cp == 9 or cp == 32 or cp == 160)) {
            self.pending_space = true;
            return;
        }
        if (self.pending_space and (self.text_buffer.items.len != 0 or self.spans.items.len != 0)) try self.append(" ");
        self.pending_space = false;
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidUtf8;
        try self.append(encoded[0..n]);
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
                if (v.codepoint) |cp| try self.rune(cp) else for (v.text) |c| try self.rune(c);
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
        try self.append("\n");
    }
    fn begin(self: *Context) !void {
        try self.flushBlock();
        self.block_state = self.state;
    }
    fn safeLink(self: *Context, raw: []const u8) !?[]const u8 {
        if (raw.len > Limits.link_bytes or raw.len > Limits.all_link_bytes - self.link_count) return null;
        self.link_count += raw.len;
        const decoded = try decodeAttribute(self.a, raw);
        if (!(std.ascii.startsWithIgnoreCase(decoded, "https://") or std.ascii.startsWithIgnoreCase(decoded, "http://") or std.ascii.startsWithIgnoreCase(decoded, "mailto:"))) return null;
        for (decoded) |c| if (c <= 32 or c == 127) return null;
        return decoded;
    }
    fn open(self: *Context, tag: Tag) !void {
        if (!self.state.skip) {
            if (tag.is("p")) try self.close(tag.name);
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
        const before = self.state;
        self.state.skip = self.state.skip or hidden(tag);
        var is_data = false;
        var next_ordinal: u32 = 1;
        if (!self.state.skip) {
            if (tag.is("b") or tag.is("strong")) self.state.style.bold = true;
            if (tag.is("i") or tag.is("em")) self.state.style.italic = true;
            if (tag.is("u")) self.state.style.underline = true;
            if (tag.is("s") or tag.is("strike") or tag.is("del")) self.state.style.strike = true;
            if (tag.is("code") or tag.is("kbd") or tag.is("samp")) self.state.style.code = true;
            if (tag.is("a")) {
                self.state.style.underline = true;
                self.state.link = if (tag.attribute("href")) |href| try self.safeLink(href) else null;
            }
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
                if (tag.attribute("start")) |v| next_ordinal = std.fmt.parseInt(u32, v, 10) catch 1;
            }
            if (tag.is("li")) {
                self.state.kind = .list_item;
                self.state.level = @min(self.state.list_depth -| 1, 8);
                var i = self.depth;
                while (i != 0) {
                    i -= 1;
                    if (std.ascii.eqlIgnoreCase(self.stack[i].name, "ol") or std.ascii.eqlIgnoreCase(self.stack[i].name, "ul")) {
                        self.state.ordinal = self.stack[i].next_ordinal;
                        self.stack[i].next_ordinal +|= 1;
                        break;
                    }
                }
                if (tag.attribute("value")) |v| self.state.ordinal = std.fmt.parseInt(u32, v, 10) catch self.state.ordinal;
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
            if (tag.is("img")) {
                const alt = tag.attribute("alt") orelse "[image]";
                if (alt.len > 1024) return error.HtmlTooComplex;
                if (alt.len != 0) {
                    try self.rune(' ');
                    try self.text(alt);
                    try self.rune(' ');
                }
            }
        }
        // HTML non-void tags ignore a trailing solidus. In particular a
        // <script/> must keep skipping its contents, and an unquoted href's
        // final slash remains URL data. Foreign svg/math roots may self-close.
        if (voidTag(tag.name) or (tag.self_closing and (tag.is("svg") or tag.is("math")))) {
            self.state = before;
            return;
        }
        if (self.depth == Limits.depth) return error.HtmlTooComplex;
        self.stack[self.depth] = .{ .name = tag.name, .before = before, .next_ordinal = next_ordinal, .data_table = is_data };
        self.depth += 1;
    }
    fn close(self: *Context, name: []const u8) !void {
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
        self.depth -= 1;
        const frame = self.stack[self.depth];
        if (!self.state.skip) {
            if (std.ascii.eqlIgnoreCase(frame.name, "table")) {
                if (frame.data_table) try self.finishTable() else try self.flushBlock();
                self.table_depth -|= 1;
            } else if (self.table != null and (std.ascii.eqlIgnoreCase(frame.name, "td") or std.ascii.eqlIgnoreCase(frame.name, "th"))) try self.finishCell() else if (self.table != null and std.ascii.eqlIgnoreCase(frame.name, "tr")) try self.finishRow() else if (blockTag(frame.name)) try self.flushBlock();
        }
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
        if (self.cell_count == Limits.cells or self.table.?.cells.items.len == Limits.columns) return error.HtmlTooComplex;
        self.cell_count += 1;
        try self.table.?.cells.append(self.a, .{ .spans = try self.spans.toOwnedSlice(self.a), .header = self.table.?.cell_header });
        self.table.?.cell_active = false;
        self.pending_space = false;
    }
    fn finishRow(self: *Context) !void {
        if (self.table == null) return;
        try self.finishCell();
        if (self.table.?.cells.items.len == 0) return;
        if (self.table.?.rows.items.len == Limits.rows) return error.HtmlTooComplex;
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
                offset = if (std.mem.indexOf(u8, self.input[next + 4 ..], "-->")) |end| next + 4 + end + 3 else self.input.len;
                continue;
            }
            try self.tick();
            const tag = (try tagAt(self.input, next)) orelse {
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

const Entity = struct { consumed: usize, codepoint: ?u21 = null, text: []const u8 = "" };
fn entity(input: []const u8) ?Entity {
    const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 32)], ';') orelse return null;
    if (end < 2) return null;
    const name = input[1..end];
    if (name[0] == '#') {
        const hex = name.len > 2 and (name[1] == 'x' or name[1] == 'X');
        const value = std.fmt.parseInt(u32, name[if (hex) 2 else 1..], if (hex) 16 else 10) catch return null;
        const cp: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        return .{ .consumed = end + 1, .codepoint = cp };
    }
    const names = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },      .{ "lt", '<' },      .{ "gt", '>' },       .{ "quot", '"' },    .{ "apos", '\'' },     .{ "nbsp", 160 },     .{ "ensp", 32 },      .{ "emsp", 32 },      .{ "thinsp", 32 },    .{ "shy", 0xad },
        .{ "copy", 0xa9 },    .{ "reg", 0xae },    .{ "trade", 0x2122 }, .{ "euro", 0x20ac }, .{ "pound", 0xa3 },    .{ "yen", 0xa5 },     .{ "cent", 0xa2 },    .{ "sect", 0xa7 },    .{ "deg", 0xb0 },     .{ "plusmn", 0xb1 },
        .{ "times", 0xd7 },   .{ "divide", 0xf7 }, .{ "middot", 0xb7 },  .{ "bull", 0x2022 }, .{ "hellip", 0x2026 }, .{ "ndash", 0x2013 }, .{ "mdash", 0x2014 }, .{ "lsquo", 0x2018 }, .{ "rsquo", 0x2019 }, .{ "ldquo", 0x201c },
        .{ "rdquo", 0x201d }, .{ "laquo", 0xab },  .{ "raquo", 0xbb },   .{ "larr", 0x2190 }, .{ "rarr", 0x2192 },   .{ "uarr", 0x2191 },  .{ "darr", 0x2193 },  .{ "ne", 0x2260 },    .{ "le", 0x2264 },    .{ "ge", 0x2265 },
        .{ "aacute", 0xe1 },  .{ "Aacute", 0xc1 }, .{ "agrave", 0xe0 },  .{ "Agrave", 0xc0 }, .{ "acirc", 0xe2 },    .{ "auml", 0xe4 },    .{ "Auml", 0xc4 },    .{ "aring", 0xe5 },   .{ "atilde", 0xe3 },  .{ "ccedil", 0xe7 },
        .{ "Ccedil", 0xc7 },  .{ "eacute", 0xe9 }, .{ "Eacute", 0xc9 },  .{ "egrave", 0xe8 }, .{ "ecirc", 0xea },    .{ "euml", 0xeb },    .{ "iacute", 0xed },  .{ "igrave", 0xec },  .{ "icirc", 0xee },   .{ "iuml", 0xef },
        .{ "ntilde", 0xf1 },  .{ "Ntilde", 0xd1 }, .{ "oacute", 0xf3 },  .{ "ograve", 0xf2 }, .{ "ocirc", 0xf4 },    .{ "ouml", 0xf6 },    .{ "Ouml", 0xd6 },    .{ "otilde", 0xf5 },  .{ "oslash", 0xf8 },  .{ "uacute", 0xfa },
        .{ "ugrave", 0xf9 },  .{ "ucirc", 0xfb },  .{ "uuml", 0xfc },    .{ "Uuml", 0xdc },   .{ "szlig", 0xdf },
    };
    for (names) |pair| if (std.mem.eql(u8, name, pair[0])) return .{ .consumed = end + 1, .codepoint = pair[1] };
    return null;
}
fn decodeAttribute(a: std.mem.Allocator, input: []const u8) ![]const u8 {
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
    for (0..1025) |_| try blocks.appendSlice(a, "<p>x</p>");
    try std.testing.expectError(error.HtmlTooComplex, parse(blocks.items, a));
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
