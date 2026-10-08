//! Native semantic HTML-only mail view. No terminal hyperlinks, images,
//! external resources or mail-authored escape sequences are emitted.
const std = @import("std");
const vaxis = @import("vaxis");
const html = @import("html_document.zig");
const theme = @import("theme.zig");
const reader_tools = @import("reader_tools.zig");
const text_layout = @import("text_layout.zig");

const max_lines = 16384;
const max_runs = 65536;
const blanks: [240]u8 = @splat(' ');
pub const Role = enum { text, heading, quote, marker, border, link, code, table_header };
pub const Run = struct { text: []const u8, columns: u16, flags: html.Style = .{}, role: Role = .text };
pub const Line = struct { first: usize, count: usize, columns: u16 };
pub const Layout = struct { lines: []const Line, runs: []const Run };
pub const Stats = struct { htmlDocumentBuilds: u64 = 0, htmlLayoutBuilds: u64 = 0, htmlFallbacks: u64 = 0 };

pub fn style(palette: theme.Palette, mono: bool, flags: html.Style, role: Role) vaxis.Style {
    var result: vaxis.Style = .{ .bold = flags.bold, .italic = flags.italic, .strikethrough = flags.strike, .ul_style = if (flags.underline) .single else .off };
    if (!mono) {
        result.fg = .{ .rgb = switch (role) {
            .heading, .marker, .table_header => palette.accent,
            .quote, .border => palette.muted,
            .link => palette.cyan,
            .code, .text => palette.foreground,
        } };
        result.bg = .{ .rgb = if (flags.code or role == .code) palette.selection else palette.background };
        if ((flags.code or role == .code) and flags.code_token != .none) result.fg = .{ .rgb = switch (flags.code_token) {
            .none => palette.foreground,
            .keyword => palette.accent,
            .string => palette.green,
            .comment => palette.muted,
            .number => palette.cyan,
        } };
    }
    if (flags.code or role == .code) {
        if (flags.code_token == .keyword) result.bold = true;
        if (flags.code_token == .comment) result.italic = true;
    }
    if (role == .heading or role == .table_header) result.bold = true;
    if (role == .quote) result.italic = true;
    if (role == .link) result.ul_style = .single;
    if (!flags.code and role != .code and flags.footer != .none) {
        if (!mono) result.fg = .{ .rgb = if (flags.footer == .link) palette.accent else palette.muted };
        if (flags.footer == .link) result.ul_style = .single;
    }
    return result;
}

fn safeText(allocator: std.mem.Allocator, text: []const u8, pre: bool) ![]const u8 {
    const iterator = try std.unicode.Utf8View.init(text);
    var codepoints = iterator.iterator();
    var wanted: usize = 0;
    while (codepoints.nextCodepoint()) |cp| {
        const bytes: usize = if (cp == '\n') 1 else if (cp == '\t') (if (pre) @as(usize, 4) else 1) else if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) 0 else try std.unicode.utf8CodepointSequenceLength(cp);
        if (bytes > 2 * 1024 * 1024 -| wanted) return error.HtmlLayoutUnavailable;
        wanted += bytes;
    }
    const out = try allocator.alloc(u8, wanted);
    errdefer allocator.free(out);
    var offset: usize = 0;
    codepoints = iterator.iterator();
    while (codepoints.nextCodepoint()) |cp| {
        if (cp == '\n') {
            out[offset] = '\n';
            offset += 1;
        } else if (cp == '\t') {
            const value = if (pre) "    " else " ";
            @memcpy(out[offset..][0..value.len], value);
            offset += value.len;
        } else if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) {
            continue;
        } else {
            var encoded: [4]u8 = undefined;
            const count = try std.unicode.utf8Encode(cp, &encoded);
            @memcpy(out[offset..][0..count], encoded[0..count]);
            offset += count;
        }
    }
    var normalized_bytes: usize = 0;
    var changed = false;
    var graphemes = vaxis.unicode.graphemeIterator(out);
    while (graphemes.next()) |gr| {
        changed = changed or gr.len > 128;
        normalized_bytes += if (gr.len > 128) @as(usize, "�".len) else gr.len;
    }
    if (!changed) return out;
    const normalized = try allocator.alloc(u8, normalized_bytes);
    offset = 0;
    graphemes = vaxis.unicode.graphemeIterator(out);
    while (graphemes.next()) |gr| {
        const value = if (gr.len > 128) "�" else gr.bytes(out);
        @memcpy(normalized[offset..][0..value.len], value);
        offset += value.len;
    }
    allocator.free(out);
    return normalized;
}

fn preparedSpan(allocator: std.mem.Allocator, spans: *std.ArrayList(html.Span), span: html.Span, count: *usize) !void {
    if (span.text.len == 0) return;
    if (count.* >= html.Limits.spans) return error.HtmlLayoutUnavailable;
    count.* += 1;
    var result = span;
    // Semantic appearance only; never populate terminal OSC8 metadata.
    if (result.link != null) result.style.underline = true;
    try spans.append(allocator, result);
}
fn sanitizeSpans(allocator: std.mem.Allocator, source: []const html.Span, pre: bool, total: *usize, count: *usize) ![]const html.Span {
    var spans: std.ArrayList(html.Span) = .empty;
    for (source) |span| {
        const clean = try safeText(allocator, span.text, pre);
        const display = try reader_tools.displayLinks(allocator, clean);
        if (display.text.len > 2 * 1024 * 1024 -| total.*) return error.HtmlLayoutUnavailable;
        total.* += display.text.len;
        var offset: usize = 0;
        for (display.ranges) |range| {
            try preparedSpan(allocator, &spans, .{ .text = display.text[offset..range.start], .style = span.style, .link = span.link }, count);
            try preparedSpan(allocator, &spans, .{ .text = display.text[range.start..range.end], .style = span.style, .link = span.link orelse range.url }, count);
            offset = range.end;
        }
        try preparedSpan(allocator, &spans, .{ .text = display.text[offset..], .style = span.style, .link = span.link }, count);
    }
    return spans.toOwnedSlice(allocator);
}

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    document_arena: std.heap.ArenaAllocator,
    layout_arena: std.heap.ArenaAllocator,
    document: html.Document,
    cached: Layout = .{ .lines = &.{}, .runs = &.{} },
    width: u16 = 0,
    method: vaxis.gwidth.Method = .unicode,
    failed: bool = false,
    layout_builds: usize = 0,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) !Prepared {
        return initWithOptions(allocator, input, .{});
    }
    /// The caller must provide locally escaped Markdown HTML, never mail read
    /// from a provider. Only the four fixed code token classes gain appearance.
    pub fn initGeneratedMarkdown(allocator: std.mem.Allocator, input: []const u8) !Prepared {
        return initWithOptions(allocator, input, .{ .generated_markdown = true });
    }
    fn initWithOptions(allocator: std.mem.Allocator, input: []const u8, options: html.ParseOptions) !Prepared {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var document = try html.parseWithOptions(input, owned, options);
        var semantic_bytes: usize = 0;
        var semantic_spans: usize = 0;
        const blocks = try owned.alloc(html.Block, document.blocks.len);
        for (document.blocks, blocks) |source, *dest| {
            dest.* = source;
            dest.spans = try sanitizeSpans(owned, source.spans, source.kind == .pre, &semantic_bytes, &semantic_spans);
            if (source.table) |table| {
                const rows = try owned.alloc(html.Row, table.rows.len);
                for (table.rows, rows) |row, *result_row| {
                    const cells = try owned.alloc(html.Cell, row.cells.len);
                    for (row.cells, cells) |cell, *result_cell| result_cell.* = .{ .spans = try sanitizeSpans(owned, cell.spans, false, &semantic_bytes, &semantic_spans), .header = cell.header };
                    result_row.* = .{ .cells = cells };
                }
                dest.table = .{ .rows = rows };
            }
        }
        document.blocks = blocks;
        return .{ .allocator = allocator, .document_arena = arena, .layout_arena = .init(allocator), .document = document };
    }
    pub fn deinit(self: *Prepared) void {
        self.layout_arena.deinit();
        self.document_arena.deinit();
    }
    pub fn ensure(self: *Prepared, width: u16, method: vaxis.gwidth.Method) !void {
        if (width == 0 or width > 240) return error.HtmlLayoutUnavailable;
        if (self.width == width and self.method == method) return if (self.failed) error.HtmlLayoutUnavailable else {};
        self.width = width;
        self.method = method;
        self.layout_builds += 1;
        self.failed = true;
        self.cached = .{ .lines = &.{}, .runs = &.{} };
        _ = self.layout_arena.reset(.retain_capacity);
        self.cached = buildLayout(self.layout_arena.allocator(), self.allocator, self.document, width, method) catch |err| {
            _ = self.layout_arena.reset(.free_all);
            return err;
        };
        self.failed = false;
    }
    pub fn draw(self: *const Prepared, win: vaxis.Window, offset: usize, base_row: usize, palette: theme.Palette, mono: bool) usize {
        const first = offset -| base_row;
        const last = @min(self.cached.lines.len, first + @as(usize, win.height));
        var index = first;
        while (index < last) : (index += 1) {
            const absolute = base_row + index;
            if (absolute < offset or absolute - offset >= win.height) continue;
            var column: u16 = 0;
            const line = self.cached.lines[index];
            for (self.cached.runs[line.first .. line.first + line.count]) |run| {
                var iterator = vaxis.unicode.graphemeIterator(run.text);
                while (iterator.next()) |gr| {
                    const glyph = text_layout.cellGrapheme(gr.bytes(run.text), self.method);
                    const columns = @max(vaxis.gwidth.gwidth(glyph, self.method), 1);
                    if (column +| columns <= win.width) win.writeCell(column, @intCast(absolute - offset), .{ .char = .{ .grapheme = glyph, .width = @intCast(@min(columns, 255)) }, .style = style(palette, mono, run.flags, run.role) });
                    column +|= columns;
                }
            }
        }
        return base_row + self.cached.lines.len;
    }
    pub fn drawFolded(self: *const Prepared, win: vaxis.Window, offset: usize, base_row: usize, palette: theme.Palette, mono: bool, hide_quotes: bool, hide_signature: bool) usize {
        return self.drawHighlightedFolded(win, offset, base_row, palette, mono, hide_quotes, hide_signature, "");
    }
    pub fn drawHighlightedFolded(self: *const Prepared, win: vaxis.Window, offset: usize, base_row: usize, palette: theme.Palette, mono: bool, hide_quotes: bool, hide_signature: bool, highlight: []const u8) usize {
        if (!hide_quotes and !hide_signature and highlight.len == 0) return self.draw(win, offset, base_row, palette, mono);
        const first = if (!hide_quotes and !hide_signature) offset -| base_row else 0;
        const last = if (!hide_quotes and !hide_signature) @min(self.cached.lines.len, first +| @as(usize, win.height)) else self.cached.lines.len;
        var row = base_row + first;
        var in_quote = false;
        var in_signature = false;
        // At most240 sanitized graphemes of at most128 bytes occupy a line.
        // Match across adjacent style runs without allocating another view.
        var text_buffer: [32 * 1024]u8 = undefined;
        for (self.cached.lines[@min(first, self.cached.lines.len)..last]) |line| {
            const runs = self.cached.runs[line.first .. line.first + line.count];
            var quoted = false;
            var signature = false;
            for (runs) |run| {
                quoted = quoted or run.role == .quote;
                const marker = std.mem.trim(u8, run.text, "\r\n");
                // HTML collapses a signature delimiter's trailing space.
                signature = signature or std.mem.eql(u8, marker, "-- ") or (runs.len == 1 and run.role == .text and std.mem.eql(u8, marker, "--"));
            }
            if ((hide_quotes and quoted) or (hide_signature and (signature or in_signature))) {
                const label = if (hide_signature and (signature or in_signature)) "[Signature folded · S shows it]" else "[Quoted history folded · Q shows it]";
                const first_hidden = if (hide_signature and (signature or in_signature)) !in_signature else !in_quote;
                if (first_hidden) {
                    if (row >= offset and row - offset < win.height) _ = win.printSegment(.{ .text = label, .style = style(palette, mono, .{}, .quote) }, .{ .row_offset = @intCast(row - offset), .wrap = .none });
                    row += 1;
                }
                if (hide_signature and (signature or in_signature)) in_signature = true else in_quote = true;
                continue;
            }
            in_quote = false;
            const absolute = row;
            row += 1;
            if (absolute < offset or absolute - offset >= win.height) continue;
            var column: u16 = 0;
            var text_length: usize = 0;
            for (runs) |run| {
                if (run.text.len > text_buffer.len - text_length) break;
                @memcpy(text_buffer[text_length..][0..run.text.len], run.text);
                text_length += run.text.len;
            }
            const line_text = text_buffer[0..text_length];
            var match = if (highlight.len > 0) std.ascii.findIgnoreCase(line_text, highlight) else null;
            var run_offset: usize = 0;
            for (runs) |run| {
                var iterator = vaxis.unicode.graphemeIterator(run.text);
                while (iterator.next()) |gr| {
                    const glyph = text_layout.cellGrapheme(gr.bytes(run.text), self.method);
                    const columns = @max(vaxis.gwidth.gwidth(glyph, self.method), 1);
                    const byte_offset = run_offset + gr.start;
                    while (match) |start| {
                        if (byte_offset < start + highlight.len) break;
                        const next = start + highlight.len;
                        match = if (std.ascii.findIgnoreCase(line_text[next..], highlight)) |relative| next + relative else null;
                    }
                    var appearance = style(palette, mono, run.flags, run.role);
                    if (match) |start| if (byte_offset >= start and byte_offset < start + highlight.len) {
                        appearance.bold = true;
                        if (mono) appearance.reverse = true else {
                            appearance.fg = .{ .rgb = palette.background };
                            appearance.bg = .{ .rgb = palette.yellow };
                        }
                    };
                    if (column +| columns <= win.width) win.writeCell(column, @intCast(absolute - offset), .{ .char = .{ .grapheme = glyph, .width = @intCast(@min(columns, 255)) }, .style = appearance });
                    column +|= columns;
                }
                run_offset += run.text.len;
            }
        }
        return if (!hide_quotes and !hide_signature) base_row + self.cached.lines.len else row;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    width: u16,
    method: vaxis.gwidth.Method,
    lines: std.ArrayList(Line) = .empty,
    runs: std.ArrayList(Run) = .empty,
    first: usize = 0,
    column: u16 = 0,
    indent: u16 = 0,
    marker: []const u8 = "",
    prefix_width: u16 = 0,
    role: Role = .text,
    open: bool = false,
    pending_space: bool = false,
    pending_flags: html.Style = .{},
    pending_role: Role = .text,

    fn add(self: *Builder, text: []const u8, columns: u16, flags: html.Style, role: Role) !void {
        if (text.len == 0) return;
        if (columns > self.width -| self.column) return error.HtmlLayoutUnavailable;
        if (self.runs.items.len == max_runs) return error.HtmlLayoutUnavailable;
        try self.runs.append(self.allocator, .{ .text = text, .columns = columns, .flags = flags, .role = role });
        self.column += columns;
    }
    fn begin(self: *Builder, indent: u16, marker: []const u8, role: Role) !void {
        self.indent = @min(indent, self.width -| 1);
        self.marker = marker;
        self.role = role;
        self.pending_space = false;
        self.pending_flags = .{};
        self.pending_role = .text;
        try self.newLine(true);
    }
    fn newLine(self: *Builder, first: bool) !void {
        if (self.open) try self.finishLine();
        self.first = self.runs.items.len;
        self.column = 0;
        self.open = true;
        if (self.indent > 0) try self.add(blanks[0..self.indent], self.indent, .{}, .text);
        const marker_width = textWidth(self.marker, self.method, self.width);
        const used = @min(marker_width, self.width -| self.column -| 1);
        if (used != marker_width) return error.HtmlLayoutUnavailable;
        if (used > 0) try self.add(if (first) self.marker else blanks[0..used], used, .{}, if (self.role == .quote) .quote else .marker);
        self.prefix_width = self.column;
    }
    fn finishLine(self: *Builder) !void {
        if (!self.open) return;
        if (self.lines.items.len == max_lines) return error.HtmlLayoutUnavailable;
        try self.lines.append(self.allocator, .{ .first = self.first, .count = self.runs.items.len - self.first, .columns = self.column });
        self.open = false;
    }
    fn blank(self: *Builder) !void {
        try self.finishLine();
        if (self.lines.items.len == max_lines) return error.HtmlLayoutUnavailable;
        try self.lines.append(self.allocator, .{ .first = self.runs.items.len, .count = 0, .columns = 0 });
    }
    fn chunk(self: *Builder, bytes: []const u8, flags: html.Style, role: Role) !void {
        var start: usize = 0;
        var width: u16 = 0;
        var iterator = vaxis.unicode.graphemeIterator(bytes);
        while (iterator.next()) |gr| {
            const columns = @max(vaxis.gwidth.gwidth(gr.bytes(bytes), self.method), 1);
            if (columns > self.width -| self.prefix_width) return error.HtmlLayoutUnavailable;
            if (self.column +| width +| columns > self.width) {
                try self.add(bytes[start..gr.start], width, flags, role);
                try self.newLine(false);
                start = gr.start;
                width = 0;
            }
            width += columns;
        }
        try self.add(bytes[start..], width, flags, role);
    }
    fn spans(self: *Builder, source: []const html.Span, pre: bool, header: bool) !void {
        for (source) |span| {
            var flags = span.style;
            flags.bold = flags.bold or header;
            const role: Role = if (span.link != null) .link else if (flags.code or pre) .code else if (header) .table_header else self.role;
            var offset: usize = 0;
            while (offset < span.text.len) {
                if (span.text[offset] == '\n') {
                    try self.newLine(false);
                    self.pending_space = false;
                    self.pending_flags = .{};
                    self.pending_role = .text;
                    offset += 1;
                    continue;
                }
                if (span.text[offset] == ' ' or span.text[offset] == '\t') {
                    if (pre) try self.chunk(" ", flags, role) else {
                        self.pending_space = self.column > self.prefix_width;
                        self.pending_flags = flags;
                        self.pending_role = role;
                    }
                    offset += 1;
                    continue;
                }
                var end = offset;
                while (end < span.text.len and span.text[end] != ' ' and span.text[end] != '\t' and span.text[end] != '\n') end += 1;
                const word = span.text[offset..end];
                const wanted = textWidth(word, self.method, self.width +| 1);
                const gap: u16 = @intFromBool(self.pending_space and self.column > self.prefix_width);
                if (!pre and self.column > self.prefix_width and self.column +| gap +| wanted > self.width) try self.newLine(false) else if (gap > 0) {
                    // A separating space belongs to the span that supplied it.
                    // Borrowing the next word's style underlines the gap before
                    // a link, which looks like a stray leading underscore.
                    try self.add(" ", 1, self.pending_flags, self.pending_role);
                }
                self.pending_space = false;
                self.pending_flags = .{};
                self.pending_role = .text;
                try self.chunk(word, flags, role);
                offset = end;
            }
        }
    }
    fn result(self: *Builder) !Layout {
        try self.finishLine();
        return .{ .lines = try self.lines.toOwnedSlice(self.allocator), .runs = try self.runs.toOwnedSlice(self.allocator) };
    }
};

fn textWidth(text: []const u8, method: vaxis.gwidth.Method, cap: u16) u16 {
    var width: u16 = 0;
    var iterator = vaxis.unicode.graphemeIterator(text);
    while (iterator.next()) |gr| {
        width +|= @max(vaxis.gwidth.gwidth(gr.bytes(text), method), 1);
        if (width >= cap) return cap;
    }
    return width;
}

fn cellWidth(cell: html.Cell, method: vaxis.gwidth.Method) u16 {
    var width: u16 = 0;
    var maximum: u16 = 0;
    for (cell.spans) |span| {
        var lines = std.mem.splitScalar(u8, span.text, '\n');
        while (lines.next()) |line| {
            width +|= textWidth(line, method, 240);
            maximum = @max(maximum, width);
            if (lines.index != null) width = 0;
        }
    }
    return @min(@max(maximum, 3), 240);
}

pub fn tableWidths(table: html.Table, available: u16, method: vaxis.gwidth.Method, widths: *[32]u16) ?usize {
    var count: usize = 0;
    var natural: [32]u16 = @splat(3);
    for (table.rows) |row| {
        count = @max(count, row.cells.len);
        if (count > widths.len or count > 8) return null;
        for (row.cells, 0..) |cell, index| natural[index] = @max(natural[index], cellWidth(cell, method));
    }
    if (count == 0 or available < count * 8 + 1) return null;
    const budget = available - @as(u16, @intCast(count * 3 + 1));
    @memset(widths[0..count], 3);
    var remaining = budget - @as(u16, @intCast(count * 3));
    while (remaining > 0) {
        var changed = false;
        for (0..count) |index| {
            if (remaining == 0) break;
            if (widths[index] < natural[index]) {
                widths[index] += 1;
                remaining -= 1;
                changed = true;
            }
        }
        if (!changed) break;
    }
    return count;
}

fn tableRule(builder: *Builder, widths: []const u16, left: []const u8, middle: []const u8, right: []const u8) !void {
    try builder.begin(0, "", .border);
    try builder.add(left, 1, .{}, .border);
    for (widths, 0..) |width, index| {
        for (0..width + 2) |_| try builder.add("─", 1, .{}, .border);
        try builder.add(if (index + 1 == widths.len) right else middle, 1, .{}, .border);
    }
    try builder.finishLine();
}

fn renderTable(builder: *Builder, table: html.Table) !void {
    var widths: [32]u16 = @splat(0);
    const count = tableWidths(table, builder.width, builder.method, &widths) orelse {
        for (table.rows, 0..) |row, index| {
            if (index > 0) try builder.blank();
            for (row.cells, 0..) |cell, column| {
                const header: ?html.Cell = if (table.rows.len > 0 and column < table.rows[0].cells.len) table.rows[0].cells[column] else null;
                const marker = if (header != null and header.?.header and index > 0) "" else try std.fmt.allocPrint(builder.allocator, "{d}: ", .{column + 1});
                try builder.begin(0, marker, .text);
                if (header != null and header.?.header and index > 0) {
                    try builder.spans(header.?.spans, false, true);
                    try builder.chunk(": ", .{}, .table_header);
                }
                try builder.spans(cell.spans, false, cell.header);
                try builder.finishLine();
            }
        }
        return;
    };
    try tableRule(builder, widths[0..count], "┌", "┬", "┐");
    for (table.rows, 0..) |row, row_index| {
        var scratch: std.heap.ArenaAllocator = .init(builder.scratch_allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        const layouts = try allocator.alloc(Layout, count);
        var height: usize = 1;
        for (0..count) |column| {
            var cell: Builder = .{ .allocator = allocator, .scratch_allocator = builder.scratch_allocator, .width = widths[column], .method = builder.method };
            try cell.begin(0, "", .text);
            if (column < row.cells.len) try cell.spans(row.cells[column].spans, false, row.cells[column].header);
            layouts[column] = try cell.result();
            height = @max(height, layouts[column].lines.len);
        }
        for (0..height) |line_index| {
            try builder.begin(0, "", .text);
            try builder.add("│", 1, .{}, .border);
            for (layouts, 0..) |cell, column| {
                try builder.add(" ", 1, .{}, .text);
                var used: u16 = 0;
                if (line_index < cell.lines.len) {
                    const line = cell.lines[line_index];
                    for (cell.runs[line.first .. line.first + line.count]) |run| try builder.add(run.text, run.columns, run.flags, run.role);
                    used = line.columns;
                }
                const padding = widths[column] - used;
                try builder.add(blanks[0..padding], padding, .{}, .text);
                try builder.add(" │", 2, .{}, .border);
            }
            try builder.finishLine();
        }
        if (row_index + 1 < table.rows.len) try tableRule(builder, widths[0..count], "├", "┼", "┤");
    }
    try tableRule(builder, widths[0..count], "└", "┴", "┘");
}

pub fn layout(allocator: std.mem.Allocator, document: html.Document, width: u16, method: vaxis.gwidth.Method) !Layout {
    return buildLayout(allocator, allocator, document, width, method);
}

fn buildLayout(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, document: html.Document, width: u16, method: vaxis.gwidth.Method) !Layout {
    if (width == 0 or width > 240) return error.HtmlLayoutUnavailable;
    // Explicit breaks in independent blocks are an unavoidable lower bound.
    // Table columns run side by side, so their cell counts are not summed.
    // Reject before allocating vectors rather than approaching the heap cap
    // for a document that can never fit the semantic row budget.
    var minimum_lines: usize = 0;
    for (document.blocks) |block| {
        if (block.kind == .table) continue;
        minimum_lines += 1;
        for (block.spans) |span| minimum_lines += std.mem.count(u8, span.text, "\n");
        if (minimum_lines > max_lines) return error.HtmlLayoutUnavailable;
    }
    var builder: Builder = .{ .allocator = allocator, .scratch_allocator = scratch_allocator, .width = width, .method = method };
    for (document.blocks, 0..) |block, index| {
        if (index > 0) {
            const previous = document.blocks[index - 1];
            const list_gap = block.kind == .list_item and
                ((block.list_continuation and block.list_paragraph) or
                    previous.kind != .list_item or
                    (block.list_start and block.level == 0 and !block.list_continuation) or
                    (block.list_loose and !block.list_continuation and previous.level >= block.level));
            if (block.kind != .list_item or list_gap) try builder.blank();
        }
        switch (block.kind) {
            .table => if (block.table) |table| try renderTable(&builder, table),
            .rule => {
                try builder.begin(0, "", .border);
                for (0..width) |_| try builder.add("─", 1, .{}, .border);
                try builder.finishLine();
            },
            else => {
                const quoted_list = block.kind == .list_item and block.quote_depth > 0;
                const role: Role = if (block.kind == .heading) .heading else if (block.kind == .quote or quoted_list) .quote else if (block.kind == .pre) .code else .text;
                const list_indent: u16 = @min(@as(u16, block.level) * 2, @min(@as(u16, 12), width / 4));
                const indent: u16 = if (quoted_list) @min(@as(u16, block.quote_depth) * 2, @min(@as(u16, 12), width / 4)) else if (block.kind == .list_item or block.kind == .quote) list_indent else if (block.kind == .pre) @min(@as(u16, 2), width / 4) else 0;
                const item_marker = if (block.kind == .quote) "│ " else if (block.kind == .list_item) (if (block.ordered) try std.fmt.allocPrint(allocator, "{d}. ", .{block.ordinal}) else "• ") else "";
                const list_marker = if (block.kind == .list_item and block.list_continuation) blanks[0..textWidth(item_marker, method, width)] else item_marker;
                const marker = if (quoted_list) try std.fmt.allocPrint(allocator, "│ {s}{s}", .{ blanks[0..list_indent], list_marker }) else list_marker;
                try builder.begin(indent, marker, role);
                try builder.spans(block.spans, block.kind == .pre, false);
                try builder.finishLine();
            },
        }
    }
    return builder.result();
}

test "semantic style maps flags and roles without hyperlink metadata" {
    const palette: theme.Palette = .{};
    const emphasis = style(palette, false, .{ .bold = true, .italic = true, .underline = true, .strike = true }, .text);
    try std.testing.expect(emphasis.bold and emphasis.italic and emphasis.strikethrough);
    try std.testing.expectEqual(vaxis.Style.Underline.single, emphasis.ul_style);
    const link = style(palette, false, .{}, .link);
    try std.testing.expectEqualSlices(u8, &palette.cyan, &link.fg.rgb);
    try std.testing.expectEqual(vaxis.Style.Underline.single, link.ul_style);
    const mono = style(palette, true, .{ .bold = true }, .heading);
    try std.testing.expect(mono.fg == .default and mono.bg == .default and mono.bold);
}

fn expectWindowLines(win: vaxis.Window, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(allocator);
    for (0..win.height) |row| {
        value.clearRetainingCapacity();
        for (0..win.width) |column| try value.appendSlice(allocator, win.screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
        try std.testing.expectEqualStrings(if (row < expected.len) expected[row] else "", std.mem.trimEnd(u8, value.items, " "));
    }
}

test "reader polish: HTML zero width clusters render actual blank cells in normal and highlighted paths" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 40, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 4, .screen = &screen };
    var prepared = try Prepared.init(allocator, "<p>\u{034f} <b>A\u{301}</b> 👩‍💻</p>");
    defer prepared.deinit();
    try prepared.ensure(40, .unicode);
    for ([_]bool{ false, true }) |highlight| {
        win.fill(.{});
        _ = if (highlight) prepared.drawHighlightedFolded(win, 0, 0, .{}, false, false, false, "A") else prepared.draw(win, 0, 0, .{}, false);
        const first = screen.readCell(0, 0).?.char;
        try std.testing.expectEqualStrings(" ", first.grapheme);
        try std.testing.expectEqual(@as(u8, 1), first.width);
        // The complete, meaningful Unicode clusters survive in their own
        // cells, rather than replacing attached accents or ZWJ sequences.
        try std.testing.expectEqualStrings("A\u{301}", screen.readCell(2, 0).?.char.grapheme);
        try std.testing.expectEqualStrings("👩‍💻", screen.readCell(4, 0).?.char.grapheme);
    }
}

test "markdown preview: tight nested and loose lists keep before after gaps without duplicate markers" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 40, .rows = 14, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 14, .screen = &screen };
    var tight = try Prepared.init(allocator, "<p>Before</p><ul><li>Alpha<ul><li>Child</li></ul>tail</li><li>Beta</li></ul><p>After</p>");
    defer tight.deinit();
    try tight.ensure(40, .unicode);
    _ = tight.draw(win, 0, 0, .{}, false);
    try expectWindowLines(win, &.{ "Before", "", "• Alpha", "  • Child", "  tail", "• Beta", "", "After" });
    win.fill(.{});
    var loose = try Prepared.init(allocator, "<p>Before</p><ol start='3'><li><p>Alpha</p><p>detail</p><ul><li>Child</li></ul></li><li><p>Beta</p></li></ol><p>After</p>");
    defer loose.deinit();
    try loose.ensure(40, .unicode);
    _ = loose.draw(win, 0, 0, .{}, false);
    try expectWindowLines(win, &.{ "Before", "", "3. Alpha", "", "   detail", "  • Child", "", "4. Beta", "", "After" });
    try loose.ensure(20, .unicode);
    for (loose.cached.lines) |line| try std.testing.expect(line.columns <= 20);
}

test "markdown preview: generated code colours render fixed tokens while received classes stay inert" {
    const allocator = std.testing.allocator;
    const input = "<pre><code><span class='omagma-syntax-keyword' style='color:#000'>const</span> <span class='omagma-syntax-string'>&quot;&lt;tag&gt;&quot;</span>\n<span class='omagma-syntax-comment'>// note</span> <span class='omagma-syntax-number'>42</span></code></pre>";
    const palette: theme.Palette = .{};
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 40, .rows = 6, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 6, .screen = &screen };
    var generated = try Prepared.initGeneratedMarkdown(allocator, input);
    defer generated.deinit();
    try generated.ensure(40, .unicode);
    _ = generated.draw(win, 0, 0, palette, false);
    try expectWindowLines(win, &.{ "  const \"<tag>\"", "  // note 42" });
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.accent }, screen.readCell(2, 0).?.style.fg));
    try std.testing.expect(screen.readCell(2, 0).?.style.bold);
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.green }, screen.readCell(8, 0).?.style.fg));
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.muted }, screen.readCell(2, 1).?.style.fg));
    try std.testing.expect(screen.readCell(2, 1).?.style.italic);
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.cyan }, screen.readCell(10, 1).?.style.fg));
    win.fill(.{});
    _ = generated.draw(win, 0, 0, palette, true);
    try std.testing.expect(screen.readCell(2, 0).?.style.fg == .default and screen.readCell(2, 0).?.style.bold);
    try std.testing.expect(screen.readCell(2, 1).?.style.fg == .default and screen.readCell(2, 1).?.style.italic);
    var received = try Prepared.init(allocator, input);
    defer received.deinit();
    try received.ensure(40, .unicode);
    win.fill(.{});
    _ = received.draw(win, 0, 0, palette, false);
    try expectWindowLines(win, &.{ "  const \"<tag>\"", "  // note 42" });
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.foreground }, screen.readCell(2, 0).?.style.fg));
    try std.testing.expect(!screen.readCell(2, 0).?.style.bold and !screen.readCell(2, 1).?.style.italic);
}

test "markdown preview: quoted reply lists retain quote bars and folding ownership" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 40, .rows = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 10, .screen = &screen };
    var prepared = try Prepared.init(allocator, "<blockquote><p>Context</p><ol start='3'><li>First<ul><li>Child</li></ul></li><li>Second</li></ol></blockquote><p>After</p>");
    defer prepared.deinit();
    try prepared.ensure(40, .unicode);
    _ = prepared.draw(win, 0, 0, .{}, false);
    try expectWindowLines(win, &.{ "  │ Context", "", "  │ 3. First", "  │   • Child", "  │ 4. Second", "", "After" });
    win.fill(.{});
    _ = prepared.drawFolded(win, 0, 0, .{}, false, true, false);
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(allocator);
    for (0..win.height) |row| for (0..win.width) |column| try visible.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "After") != null);
    for ([_][]const u8{ "Context", "First", "Child", "Second" }) |hidden| try std.testing.expect(std.mem.indexOf(u8, visible.items, hidden) == null);
}

test "markdown footer: native generated footer has grey text and only orange underlined brand" {
    const allocator = std.testing.allocator;
    const input = "<div class='omagma-footer' style='color:#ff0000'><img src='cid:omagma-logo@omagma.invalid' alt=''>Sent with <a class='omagma-footer-link' href='https://technologylab-ai.github.io/omagma/' style='color:#00ff00;text-decoration:none'>omagma</a> 🌋</div>";
    const palette: theme.Palette = .{};
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 40, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 4, .screen = &screen };
    var generated = try Prepared.initGeneratedMarkdown(allocator, input);
    defer generated.deinit();
    try generated.ensure(40, .unicode);
    _ = generated.draw(win, 0, 0, palette, false);
    try expectWindowLines(win, &.{"Sent with omagma 🌋"});
    for (0..10) |column| {
        const appearance = screen.readCell(@intCast(column), 0).?.style;
        if (!vaxis.Color.eql(.{ .rgb = palette.muted }, appearance.fg) or appearance.ul_style != .off)
            std.debug.print("native footer prefix cell {d}: fg={any}, underline={any}\n", .{ column, appearance.fg, appearance.ul_style });
        try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.muted }, appearance.fg));
        try std.testing.expectEqual(vaxis.Style.Underline.off, appearance.ul_style);
    }
    for (10..16) |column| {
        const appearance = screen.readCell(@intCast(column), 0).?.style;
        try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.accent }, appearance.fg));
        try std.testing.expectEqual(vaxis.Style.Underline.single, appearance.ul_style);
    }
    for ([_]u16{ 16, 17 }) |column| {
        const appearance = screen.readCell(column, 0).?.style;
        try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.muted }, appearance.fg));
        try std.testing.expectEqual(vaxis.Style.Underline.off, appearance.ul_style);
    }
    win.fill(.{});
    _ = generated.draw(win, 0, 0, palette, true);
    try std.testing.expect(screen.readCell(0, 0).?.style.fg == .default);
    try std.testing.expect(screen.readCell(10, 0).?.style.fg == .default);
    try std.testing.expectEqual(vaxis.Style.Underline.single, screen.readCell(10, 0).?.style.ul_style);
    var received = try Prepared.init(allocator, input);
    defer received.deinit();
    try received.ensure(40, .unicode);
    win.fill(.{});
    _ = received.draw(win, 0, 0, palette, false);
    try expectWindowLines(win, &.{"Sent with omagma 🌋"});
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.foreground }, screen.readCell(0, 0).?.style.fg));
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.cyan }, screen.readCell(10, 0).?.style.fg));
    for (received.document.blocks) |block| for (block.spans) |span| try std.testing.expectEqual(html.FooterStyle.none, span.style.footer);
}

test "HTML reader display compacts bare URLs and retains human labels and original hrefs" {
    var prepared = try Prepared.init(std.testing.allocator, "<p><a href='https://example.test/guide?tracking=abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz'>Guide</a> then https://example.test/guide?tracking=abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz</p>");
    defer prepared.deinit();
    try prepared.ensure(100, .unicode);
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(std.testing.allocator);
    var saw_label = false;
    var saw_compact = false;
    for (prepared.cached.runs) |run| {
        try visible.appendSlice(std.testing.allocator, run.text);
        if (std.mem.eql(u8, run.text, "Guide")) {
            saw_label = true;
            try std.testing.expectEqual(Role.link, run.role);
        }
        if (std.mem.eql(u8, run.text, "https://example.test/guide…")) {
            saw_compact = true;
            try std.testing.expectEqual(Role.link, run.role);
        }
    }
    try std.testing.expect(saw_label and saw_compact);
    try std.testing.expectEqualStrings("Guide then https://example.test/guide…", visible.items);
    try std.testing.expectEqualStrings("https://example.test/guide?tracking=abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz", prepared.document.blocks[0].spans[0].link.?);
}

test "semantic layouts wrap unicode words and table cells within responsive bounds" {
    const allocator = std.testing.allocator;
    var prepared = try Prepared.init(allocator, "<h2>Report</h2><p>Alpha <b>bravo</b> café 👋 next.</p><table><tr><th>Name</th><th>Value</th></tr><tr><td>Unicode 👩‍💻</td><td>Long words wrap across the cell safely</td></tr></table>");
    defer prepared.deinit();
    for ([_]u16{ 12, 24, 40, 80, 160 }) |width| {
        try prepared.ensure(width, .unicode);
        try std.testing.expect(prepared.cached.lines.len > 0);
        for (prepared.cached.lines) |line| try std.testing.expect(line.columns <= width);
        for (prepared.cached.runs) |run| try std.testing.expect(std.unicode.utf8ValidateSlice(run.text));
        const builds = prepared.layout_builds;
        try prepared.ensure(width, .unicode);
        try std.testing.expectEqual(builds, prepared.layout_builds);
    }
}

test "semantic view removes controls and oversized clusters without evaluating mail" {
    const allocator = std.testing.allocator;
    const cleaned = try safeText(allocator, "safe\x1b]52;c;payload\x07\u{061c}\u{200e}\u{200f}\u{202e}text\n\tcode", true);
    defer allocator.free(cleaned);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "\u{202e}") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "\u{061c}") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "\u{200e}") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "\u{200f}") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "\n    code") != null);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var cluster: std.ArrayList(u8) = .empty;
    try cluster.append(arena.allocator(), 'a');
    for (0..100) |_| try cluster.appendSlice(arena.allocator(), "\u{0300}");
    try std.testing.expectEqualStrings("�", try safeText(arena.allocator(), cluster.items, false));
}

test "semantic marker and layout row caps degrade without inconsistent widths" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var prepared = try Prepared.init(allocator, "<p>Visible text</p>");
    defer prepared.deinit();
    try std.testing.expectError(error.HtmlLayoutUnavailable, prepared.ensure(0, .unicode));
    try std.testing.expectError(error.HtmlLayoutUnavailable, prepared.ensure(241, .unicode));
    try prepared.ensure(40, .unicode);
    try std.testing.expect(prepared.cached.lines.len > 0);
    const document: html.Document = .{ .blocks = &.{.{ .kind = .list_item, .ordered = true, .ordinal = 4294967295, .spans = &.{.{ .text = "Value" }} }} };
    try std.testing.expectError(error.HtmlLayoutUnavailable, layout(arena.allocator(), document, 2, .unicode));
    const text = try allocator.alloc(u8, 32770);
    defer allocator.free(text);
    for (0..16385) |index| @memcpy(text[index * 2 ..][0..2], "x\n");
    const tall: html.Document = .{ .blocks = &.{.{ .kind = .pre, .spans = &.{.{ .text = text }} }} };
    try std.testing.expectError(error.HtmlLayoutUnavailable, layout(arena.allocator(), tall, 40, .unicode));
    var no_vectors: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.HtmlLayoutUnavailable, layout(no_vectors.allocator(), tall, 40, .unicode));
}

test "semantic sanitizer reserves one exact buffer and rejects tab expansion before allocation" {
    const allocator = std.testing.allocator;
    var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const clean = try safeText(failing.allocator(), "Plain café 👋 text", false);
    defer failing.allocator().free(clean);
    try std.testing.expectEqualStrings("Plain café 👋 text", clean);
    const tabs = try allocator.alloc(u8, 524289);
    defer allocator.free(tabs);
    @memset(tabs, '\t');
    var no_allocations: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.HtmlLayoutUnavailable, safeText(no_allocations.allocator(), tabs, true));
}

test "local reader: folding native quoted HTML keeps authored styles and text" {
    const allocator = std.testing.allocator;
    var prepared = try Prepared.init(allocator, "<p><b>AUTHORED-TEXT</b></p><blockquote><p>QUOTED-SECRET</p></blockquote><p>FRESH-TAIL</p>");
    defer prepared.deinit();
    try prepared.ensure(60, .unicode);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 60, .rows = 15, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 15, .screen = &screen };
    const rows = prepared.drawFolded(win, 0, 0, .{}, false, true, false);
    try std.testing.expect(rows <= prepared.cached.lines.len);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    for (0..win.height) |row| for (0..win.width) |column| try rendered.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "AUTHORED-TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "FRESH-TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "QUOTED-SECRET") == null);
    try std.testing.expect(screen.readCell(0, 0).?.style.bold);
}

test "local reader: native search highlighting spans style runs without altering literal text" {
    const allocator = std.testing.allocator;
    var prepared = try Prepared.init(allocator, "<p>A <b>cross</b><i>run</i> match.</p>");
    defer prepared.deinit();
    try prepared.ensure(60, .unicode);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 60, .rows = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 10, .screen = &screen };
    const palette: theme.Palette = .{};
    _ = prepared.drawHighlightedFolded(win, 0, 0, palette, false, false, false, "CROSSRUN");
    for (2..10) |column| try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.yellow }, screen.readCell(@intCast(column), 0).?.style.bg));
    try std.testing.expect(!vaxis.Color.eql(.{ .rgb = palette.yellow }, screen.readCell(0, 0).?.style.bg));
    try std.testing.expectEqualStrings("A", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("c", screen.readCell(2, 0).?.char.grapheme);
}

test "reader polish: inline link underline excludes surrounding prose spaces and punctuation" {
    const a = std.testing.allocator;
    const palette: theme.Palette = .{};
    var screen = try vaxis.Screen.init(a, .{ .cols = 40, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 4, .screen = &screen };
    for ([_]bool{ false, true }) |generated| {
        const input = "<p>Mail von <a href='https://example.test/'>Omagma</a>.</p>";
        var prepared = if (generated) try Prepared.initGeneratedMarkdown(a, input) else try Prepared.init(a, input);
        defer prepared.deinit();
        try prepared.ensure(40, .unicode);
        screen.clear();
        _ = prepared.draw(win, 0, 0, palette, false);
        try expectWindowLines(win, &.{"Mail von Omagma."});
        try std.testing.expectEqual(vaxis.Style.Underline.off, screen.readCell(8, 0).?.style.ul_style);
        try std.testing.expect(vaxis.Color.eql(.{ .rgb = palette.foreground }, screen.readCell(8, 0).?.style.fg));
        for (9..15) |col| try std.testing.expectEqual(vaxis.Style.Underline.single, screen.readCell(@intCast(col), 0).?.style.ul_style);
        try std.testing.expectEqual(vaxis.Style.Underline.off, screen.readCell(15, 0).?.style.ul_style);
    }
    var spaced = try Prepared.init(a, "<p>Before <a href='https://example.test/'>two words</a> after</p>");
    defer spaced.deinit();
    try spaced.ensure(40, .unicode);
    screen.clear();
    _ = spaced.draw(win, 0, 0, palette, false);
    try expectWindowLines(win, &.{"Before two words after"});
    try std.testing.expectEqual(vaxis.Style.Underline.off, screen.readCell(6, 0).?.style.ul_style);
    try std.testing.expectEqual(vaxis.Style.Underline.single, screen.readCell(10, 0).?.style.ul_style);
    try std.testing.expectEqual(vaxis.Style.Underline.off, screen.readCell(16, 0).?.style.ul_style);
}
