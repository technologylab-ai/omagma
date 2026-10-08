//! Display-only mail corrections. Stored text, MIME decoding and literal URL
//! targets remain authoritative. null means use the original input; otherwise
//! the caller owns the returned slice. Both helpers have a fixed input bound.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const max_bytes = 2 * 1024 * 1024;

const Entity = struct { consumed: usize, codepoint: u21 };

fn printable(cp: u21) bool {
    return cp >= 32 and !(cp >= 0x7f and cp <= 0x9f) and
        !(cp >= 0xd800 and cp <= 0xdfff) and cp <= 0x10ffff and
        !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069);
}

fn entity(input: []const u8) ?Entity {
    if (input.len < 3 or input[0] != '&') return null;
    const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 32)], ';') orelse return null;
    if (end < 2) return null;
    const name = input[1..end];
    if (name[0] == '#') {
        const hex = name.len > 2 and (name[1] == 'x' or name[1] == 'X');
        const digits = name[if (hex) 2 else 1..];
        if (digits.len == 0) return null;
        // Require literal digits; parseInt also accepts signs and separators.
        for (digits) |digit| if (!(digit >= '0' and digit <= '9') and
            !(hex and ((digit >= 'a' and digit <= 'f') or (digit >= 'A' and digit <= 'F')))) return null;
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
        if (value > 0x10ffff) return null;
        const cp: u21 = @intCast(value);
        if (!printable(cp)) return null;
        return .{ .consumed = end + 1, .codepoint = cp };
    }
    const names = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },      .{ "AMP", '&' },       .{ "lt", '<' },       .{ "LT", '<' },
        .{ "gt", '>' },       .{ "GT", '>' },        .{ "quot", '"' },     .{ "QUOT", '"' },
        .{ "apos", '\'' },    .{ "nbsp", 0xa0 },     .{ "copy", 0xa9 },    .{ "reg", 0xae },
        .{ "trade", 0x2122 }, .{ "euro", 0x20ac },   .{ "pound", 0xa3 },   .{ "yen", 0xa5 },
        .{ "cent", 0xa2 },    .{ "hellip", 0x2026 }, .{ "ndash", 0x2013 }, .{ "mdash", 0x2014 },
        .{ "lsquo", 0x2018 }, .{ "rsquo", 0x2019 },  .{ "ldquo", 0x201c }, .{ "rdquo", 0x201d },
        .{ "laquo", 0xab },   .{ "raquo", 0xbb },    .{ "bull", 0x2022 },  .{ "middot", 0xb7 },
        .{ "auml", 0xe4 },    .{ "Auml", 0xc4 },     .{ "ouml", 0xf6 },    .{ "Ouml", 0xd6 },
        .{ "uuml", 0xfc },    .{ "Uuml", 0xdc },     .{ "szlig", 0xdf },
    };
    for (names) |pair| if (std.mem.eql(u8, name, pair[0]))
        return .{ .consumed = end + 1, .codepoint = pair[1] };
    return null;
}

/// Decode metadata preview entities once. No tag removal, recursive decoding,
/// entity normalization in headers, or modification of stored/plaintext mail.
pub fn decodePreview(allocator: Allocator, raw: []const u8) !?[]u8 {
    if (raw.len > max_bytes or !std.unicode.utf8ValidateSlice(raw)) return null;
    var changed = false;
    var size = raw.len;
    var index: usize = 0;
    while (index < raw.len) {
        if (entity(raw[index..])) |found| {
            var encoded: [4]u8 = undefined;
            const count = std.unicode.utf8Encode(found.codepoint, &encoded) catch unreachable;
            size -= found.consumed - count;
            changed = true;
            index += found.consumed;
        } else index += 1;
    }
    if (!changed) return null;
    const result = try allocator.alloc(u8, size);
    var written: usize = 0;
    index = 0;
    while (index < raw.len) {
        if (entity(raw[index..])) |found| {
            var encoded: [4]u8 = undefined;
            const count = std.unicode.utf8Encode(found.codepoint, &encoded) catch unreachable;
            @memcpy(result[written..][0..count], encoded[0..count]);
            written += count;
            index += found.consumed;
        } else {
            result[written] = raw[index];
            written += 1;
            index += 1;
        }
    }
    std.debug.assert(written == result.len);
    return result;
}

const Rune = struct { cp: u21, consumed: usize };
fn rune(raw: []const u8) ?Rune {
    if (raw.len == 0) return null;
    const count = std.unicode.utf8ByteSequenceLength(raw[0]) catch return null;
    if (count > raw.len) return null;
    return .{ .cp = std.unicode.utf8Decode(raw[0..count]) catch return null, .consumed = count };
}

/// The defined Windows-1252 characters at 80..9f. Undefined slots have no
/// inverse mapping, and existing C1 controls never become repair evidence.
fn cp1252Byte(cp: u21) ?u8 {
    if (cp <= 0x7f or (cp >= 0xa0 and cp <= 0xff)) return @intCast(cp);
    const upper = [_]u21{
        0x20ac, 0,      0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
        0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017d, 0,
        0,      0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
        0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0,      0x017e, 0x0178,
    };
    for (upper, 0..) |value, index| if (value != 0 and cp == value) return @intCast(index + 0x80);
    return null;
}

fn latinLetter(cp: u21) bool {
    return (cp >= 0xc0 and cp <= 0x2af) and cp != 0xd7 and cp != 0xf7;
}
fn asciiLetter(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

const Repair = struct { consumed: usize, count: usize, bytes: [4]u8, classic: bool };
fn repairedRune(raw: []const u8) ?Repair {
    const first = rune(raw) orelse return null;
    const lead = cp1252Byte(first.cp) orelse return null;
    if (lead < 0xc2 or lead > 0xf4) return null;
    const count = std.unicode.utf8ByteSequenceLength(lead) catch return null;
    var result: Repair = .{ .consumed = first.consumed, .count = count, .bytes = undefined, .classic = lead == 0xc3 };
    result.bytes[0] = lead;
    for (1..count) |index| {
        const next = rune(raw[result.consumed..]) orelse return null;
        const byte = cp1252Byte(next.cp) orelse return null;
        if (byte < 0x80 or byte > 0xbf) return null;
        result.bytes[index] = byte;
        result.consumed += next.consumed;
    }
    const decoded = std.unicode.utf8Decode(result.bytes[0..count]) catch return null;
    // Deliberately restrict automatic repair to embedded Latin prose. Emoji,
    // punctuation and ambiguous standalone encoding examples are untouched.
    if (!latinLetter(decoded)) return null;
    return result;
}

fn codeLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t")) return true;
    const clean = std.mem.trimStart(u8, line, " \t\r");
    for ([_][]const u8{ "const ", "var ", "let ", "fn ", "pub ", "def ", "import ", "return ", "function ", "class ", "type ", "//", "#include", "{", "}", "[" }) |prefix|
        if (std.mem.startsWith(u8, clean, prefix)) return true;
    // An encoding discussion can intentionally show the very strings that a
    // repair heuristic would otherwise change. Preserve that complete line.
    for ([_][]const u8{ "UTF-8", "UTF8", "utf-8", "utf8", "CP1252", "cp1252", "ISO-8859", "mojibake", "charset", "\\u00", "\\x" }) |token|
        if (std.mem.indexOf(u8, line, token) != null) return true;
    return false;
}

const Pass = struct { size: usize = 0, strong: usize = 0, changed: bool = false };
fn urlStart(raw: []const u8) bool {
    return (raw.len >= 8 and std.ascii.eqlIgnoreCase(raw[0..8], "https://")) or
        (raw.len >= 7 and std.ascii.eqlIgnoreCase(raw[0..7], "http://"));
}
fn emit(pass: *Pass, destination: ?[]u8, bytes: []const u8) void {
    if (destination) |out| @memcpy(out[pass.size..][0..bytes.len], bytes);
    pass.size += bytes.len;
}
fn repairPass(raw: []const u8, destination: ?[]u8) Pass {
    var pass: Pass = .{};
    var start: usize = 0;
    var fence: ?u8 = null;
    while (start < raw.len) {
        const end = if (std.mem.indexOfScalar(u8, raw[start..], '\n')) |offset| start + offset else raw.len;
        const line = raw[start..end];
        const clean = std.mem.trimStart(u8, line, " \t\r");
        const boundary: ?u8 = if (std.mem.startsWith(u8, clean, "```")) '`' else if (std.mem.startsWith(u8, clean, "~~~")) '~' else null;
        if (boundary) |kind| {
            if (fence == null) fence = kind else if (fence.? == kind) fence = null;
            emit(&pass, destination, line);
        } else if (fence != null or codeLine(line)) {
            emit(&pass, destination, line);
        } else {
            var index: usize = 0;
            while (index < line.len) {
                if (urlStart(line[index..])) {
                    var stop = index;
                    while (stop < line.len and std.mem.indexOfScalar(u8, " \t\r<>\"`", line[stop]) == null) : (stop += 1) {}
                    emit(&pass, destination, line[index..stop]);
                    index = stop;
                    continue;
                }
                if (line[index] == '`') {
                    // Preserve inline code, including unmatched code delimiters.
                    var ticks: usize = 1;
                    while (index + ticks < line.len and line[index + ticks] == '`') : (ticks += 1) {}
                    const stop = if (std.mem.indexOf(u8, line[index + ticks ..], line[index .. index + ticks])) |offset| index + ticks + offset + ticks else line.len;
                    emit(&pass, destination, line[index..stop]);
                    index = stop;
                    continue;
                }
                if (repairedRune(line[index..])) |found| {
                    const before = index > 0 and asciiLetter(line[index - 1]);
                    const after = index + found.consumed < line.len and asciiLetter(line[index + found.consumed]);
                    if (before or after) {
                        emit(&pass, destination, found.bytes[0..found.count]);
                        pass.strong += @intFromBool(found.classic and before and after);
                        pass.changed = true;
                        index += found.consumed;
                        continue;
                    }
                }
                emit(&pass, destination, line[index..][0..1]);
                index += 1;
            }
        }
        if (end < raw.len) emit(&pass, destination, "\n");
        start = end + 1;
    }
    return pass;
}

/// Repair high-confidence CP1252-as-UTF8 Latin prose only. At least two C3
/// markers embedded between ASCII letters must be present outside code/URLs.
/// This is a conservative display heuristic, never a general encoding decoder.
pub fn repairMojibakeDisplay(allocator: Allocator, raw: []const u8) !?[]u8 {
    if (raw.len > max_bytes or !std.unicode.utf8ValidateSlice(raw)) return null;
    const measured = repairPass(raw, null);
    if (!measured.changed or measured.strong < 2) return null;
    const result = try allocator.alloc(u8, measured.size);
    const written = repairPass(raw, result);
    std.debug.assert(written.size == result.len);
    return result;
}

const PaddingRun = struct { end: usize, newlines: usize, line_start: ?usize, remove: bool };
fn newsletterPadding(raw: []const u8, start: usize) ?PaddingRun {
    const first = rune(raw[start..]) orelse return null;
    if (first.cp != 0x2007 and first.cp != 0x034f) return null;
    var figures: usize = 0;
    var joiners: usize = 0;
    var newlines: usize = 0;
    var line_start: ?usize = null;
    var pos = start;
    while (pos < raw.len) {
        const value = rune(raw[pos..]) orelse break;
        switch (value.cp) {
            0x2007 => figures += 1,
            0x034f => joiners += 1,
            '\n' => {
                // Do not consume padding used as a literal indented-code
                // example on the following line.
                const following = raw[pos + 1 ..];
                if (std.mem.startsWith(u8, following, "    ") or std.mem.startsWith(u8, following, "\t")) break;
                newlines += 1;
                line_start = pos + 1;
            },
            ' ', '\t', '\r', 0xa0 => {},
            else => break,
        }
        pos += value.consumed;
    }
    // Newsletter preview extenders alternate figure spaces and invisible
    // grapheme joiners. A long whitespace-only run is strong evidence; ordinary
    // spacing, Unicode prose and short intentional examples remain unchanged.
    return .{ .end = pos, .newlines = @min(newlines, 2), .line_start = line_start, .remove = figures >= 8 and joiners >= 8 };
}

/// Strip only long invisible newsletter preview padding in a display copy.
/// Preserve the provider's plaintext provenance, stored bytes and reply source.
pub fn removeNewsletterPaddingDisplay(allocator: Allocator, raw: []const u8) !?[]u8 {
    if (raw.len > max_bytes or !std.unicode.utf8ValidateSlice(raw)) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var copied: usize = 0;
    var pos: usize = 0;
    var line_start: usize = 0;
    var recheck_line = true;
    var code_line = false;
    var fence: ?u8 = null;
    while (pos < raw.len) {
        if (recheck_line) {
            recheck_line = false;
            const end = std.mem.indexOfScalarPos(u8, raw, pos, '\n') orelse raw.len;
            const line = raw[line_start..end];
            const clean = std.mem.trimStart(u8, line, " \t\r");
            const boundary: ?u8 = if (std.mem.startsWith(u8, clean, "```")) '`' else if (std.mem.startsWith(u8, clean, "~~~")) '~' else null;
            code_line = fence != null or boundary != null or codeLine(line);
            if (boundary) |kind| {
                if (fence == null) fence = kind else if (fence.? == kind) fence = null;
            }
        }
        if (!code_line) if (newsletterPadding(raw, pos)) |padding| {
            if (padding.remove) {
                try output.appendSlice(allocator, raw[copied..pos]);
                for (0..padding.newlines) |_| try output.append(allocator, '\n');
                if (padding.newlines == 0 and output.items.len > 0 and padding.end < raw.len and
                    std.mem.indexOfScalar(u8, " \t\r\n", output.items[output.items.len - 1]) == null)
                    try output.append(allocator, ' ');
                copied = padding.end;
            }
            pos = padding.end;
            // A removed run may span physical lines. Recheck the actual line
            // containing the next visible character without losing fence state.
            // Even a short/nonqualifying run is scanned once, preventing a
            // quadratic lookahead for a large body made solely of padding.
            if (padding.line_start) |start| {
                line_start = start;
                recheck_line = true;
            }
            continue;
        };
        const value = rune(raw[pos..]).?;
        pos += value.consumed;
        if (value.cp == '\n') {
            line_start = pos;
            recheck_line = true;
        }
    }
    if (copied == 0) return null;
    try output.appendSlice(allocator, raw[copied..]);
    return try output.toOwnedSlice(allocator);
}

/// The reader owns a display-only snapshot; neither correction affects the
/// body returned by the CLI or used for quoting/composing a reply.
pub fn preparePlainBodyDisplay(allocator: Allocator, raw: []const u8) !?[]u8 {
    const unpadded = try removeNewsletterPaddingDisplay(allocator, raw);
    errdefer if (unpadded) |owned| allocator.free(owned);
    if (try repairMojibakeDisplay(allocator, unpadded orelse raw)) |repaired| {
        if (unpadded) |owned| allocator.free(owned);
        return repaired;
    }
    return unpadded;
}

fn repeatedForTest(comptime value: []const u8, comptime count: usize) [value.len * count]u8 {
    var output: [value.len * count]u8 = undefined;
    for (0..count) |index| @memcpy(output[index * value.len ..][0..value.len], value);
    return output;
}

test "mail display: repeated invisible newsletter padding disappears without rewriting visible prose" {
    const allocator = std.testing.allocator;
    const padding = &(comptime repeatedForTest("\u{2007} \u{034f} ", 20));
    const raw = "Fictional release preview. " ++ padding ++ "\n" ++ padding ++
        "\n\n\nHello from the team.\nRead: https://example.test/release\n";
    const expected = "Fictional release preview. \n\nHello from the team.\nRead: https://example.test/release\n";
    const display = (try preparePlainBodyDisplay(allocator, raw)).?;
    defer allocator.free(display);
    try std.testing.expectEqualStrings(expected, display);
    try std.testing.expect(std.mem.indexOf(u8, raw, padding) != null);
    // Apply the same two independent corrections once while retaining body
    // bytes as the caller's authoritative source.
    const mojibake = "F\u{c3}\u{a4}rben und gr\u{c3}\u{bc}nen. " ++ padding ++ "\n\nNext.";
    const combined = (try preparePlainBodyDisplay(allocator, mojibake)).?;
    defer allocator.free(combined);
    try std.testing.expectEqualStrings("Färben und grünen. \n\nNext.", combined);
    const inline_padding = (try preparePlainBodyDisplay(allocator, "Before" ++ padding ++ "after.")).?;
    defer allocator.free(inline_padding);
    try std.testing.expectEqualStrings("Before after.", inline_padding);
}

test "mail display: newsletter heuristic preserves short runs code combining scripts and literal markup" {
    const allocator = std.testing.allocator;
    const padding = &(comptime repeatedForTest("\u{2007} \u{034f} ", 8));
    for ([_][]const u8{
        "a\u{034f}\u{301} café 👩‍💻 text.",
        &(comptime repeatedForTest("\u{2007} \u{034f} ", 7)),
        &(comptime repeatedForTest("\u{2007}", 100)),
        &(comptime repeatedForTest("\u{034f}", 100)),
        "```text\n" ++ padding ++ "\n```\nLiteral example.",
        "~~~\n" ++ padding ++ "\n~~~\nLiteral example.",
        "    " ++ padding ++ "\nIndented code.",
        "<p>literal markup</p> &amp; <team@example.test>",
    }) |raw| try std.testing.expect((try removeNewsletterPaddingDisplay(allocator, raw)) == null);
    const invalid = [_]u8{0xff};
    try std.testing.expect((try preparePlainBodyDisplay(allocator, &invalid)) == null);
}

test "mail display: metadata apostrophe and numeric entities decode once without stripping tags" {
    const a = std.testing.allocator;
    const value = (try decodePreview(a, "We&#39;re &quot;ready&quot; &amp; &#x1f642; <b>ok</b> &amp;#39;")).?;
    defer a.free(value);
    try std.testing.expectEqualStrings("We're \"ready\" & 🙂 <b>ok</b> &#39;", value);
    try std.testing.expect((try decodePreview(a, "Für Grüße 🙂")) == null);
    try std.testing.expect((try decodePreview(a, "&#0; &#27; &#x202e; &#xD800; &#1114112; &unknown; &#-39;")) == null);
}

test "mail display: multiple embedded German CP1252 markers repair only display prose" {
    const a = std.testing.allocator;
    const value = (try repairMojibakeDisplay(a, "BenÃ¶tigen Sie EinwÃ¤hlen? FÃ¼r die Ãœbersicht: ZurÃ¼cksetzen. 🙂 Grüße")).?;
    defer a.free(value);
    try std.testing.expectEqualStrings("Benötigen Sie Einwählen? Für die Übersicht: Zurücksetzen. 🙂 Grüße", value);
}

test "mail display: genuine Unicode and ambiguous single markers remain unchanged" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "Benötigen Sie Einwählen? Für Grüße 🙂 日本語", "FÃ¼r", "Ã¶ Ã¼", "Ãngela and São Tomé", "UTF-8 examples: FÃ¼r ZurÃ¼cksetzen" }) |raw|
        try std.testing.expect((try repairMojibakeDisplay(a, raw)) == null);
}

test "mail display: preserve URL destinations and fenced inline or indented code" {
    const a = std.testing.allocator;
    const raw = "BenÃ¶tigen Sie EinwÃ¤hlen? https://example.org/FÃ¼r/ZurÃ¼cksetzen?q=Ã¶\n" ++
        "`FÃ¼r ZurÃ¼cksetzen` and ``FÃ¼r ZurÃ¼cksetzen``\n```text\nFÃ¼r ZurÃ¼cksetzen\n```\n" ++
        "    FÃ¼r ZurÃ¼cksetzen\nconst text = \"FÃ¼r ZurÃ¼cksetzen\";\n";
    const value = (try repairMojibakeDisplay(a, raw)).?;
    defer a.free(value);
    try std.testing.expectEqualStrings("Benötigen Sie Einwählen? https://example.org/FÃ¼r/ZurÃ¼cksetzen?q=Ã¶\n" ++
        "`FÃ¼r ZurÃ¼cksetzen` and ``FÃ¼r ZurÃ¼cksetzen``\n```text\nFÃ¼r ZurÃ¼cksetzen\n```\n" ++
        "    FÃ¼r ZurÃ¼cksetzen\nconst text = \"FÃ¼r ZurÃ¼cksetzen\";\n", value);
    try std.testing.expect((try repairMojibakeDisplay(a, "https://example.org/FÃ¼r/ZurÃ¼cksetzen")) == null);
    try std.testing.expect((try repairMojibakeDisplay(a, "HTTP://example.org/FÃ¼r/ZurÃ¼cksetzen")) == null);
}

test "mail display: invalid UTF8 and oversized input preserve original fallback" {
    const a = std.testing.allocator;
    try std.testing.expect((try decodePreview(a, &.{0xff})) == null);
    try std.testing.expect((try repairMojibakeDisplay(a, &.{0xff})) == null);
    const too_large = try a.alloc(u8, max_bytes + 1);
    defer a.free(too_large);
    @memset(too_large, 'x');
    try std.testing.expect((try decodePreview(a, too_large)) == null);
    try std.testing.expect((try repairMojibakeDisplay(a, too_large)) == null);
}
