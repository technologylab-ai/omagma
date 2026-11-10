//! Display-only mail corrections. Stored text, MIME decoding and literal URL
//! targets remain authoritative. null means use the original input; otherwise
//! the caller owns the returned slice. Both helpers have a fixed input bound.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const max_bytes = 2 * 1024 * 1024;

const html_entities = @import("html_entities.zig");

/// A null code point decodes to nothing: invisible fillers such as &zwnj;.
const Entity = struct { consumed: usize, codepoint: ?u21 };

fn printable(cp: u21) bool {
    return cp >= 32 and !(cp >= 0x7f and cp <= 0x9f) and
        !(cp >= 0xd800 and cp <= 0xdfff) and cp <= 0x10ffff and
        !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069);
}
/// Default-ignorable format characters: no glyph, at most a blank cell.
fn ignorable(cp: u21) bool {
    return cp == 0xad or cp == 0x34f or cp == 0x180e or (cp >= 0x200b and cp <= 0x200d) or cp == 0x2060 or cp == 0xfeff;
}

fn entity(input: []const u8) ?Entity {
    if (input.len < 3 or input[0] != '&') return null;
    var found: Entity = undefined;
    if (input[1] == '#') {
        const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 32)], ';') orelse return null;
        const name = input[1..end];
        const hex = name.len > 2 and (name[1] == 'x' or name[1] == 'X');
        const digits = name[if (hex) 2 else 1..];
        if (digits.len == 0) return null;
        // Require literal digits; parseInt also accepts signs and separators.
        for (digits) |digit| if (!(digit >= '0' and digit <= '9') and
            !(hex and ((digit >= 'a' and digit <= 'f') or (digit >= 'A' and digit <= 'F')))) return null;
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
        if (value > 0x10ffff) return null;
        // As in browsers, 0x80..0x9f references mean Windows-1252 characters.
        found = .{ .consumed = end + 1, .codepoint = html_entities.numericCodepoint(@intCast(value)) };
    } else {
        // Shared table; previews require the terminating semicolon.
        const match = html_entities.named(input, false) orelse return null;
        found = .{ .consumed = match.consumed, .codepoint = match.codepoint };
    }
    const cp = found.codepoint.?;
    if (ignorable(cp) or cp == 0x200e or cp == 0x200f) found.codepoint = null else if (!printable(cp)) return null;
    return found;
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
            const count = if (found.codepoint) |cp| std.unicode.utf8Encode(cp, &encoded) catch unreachable else 0;
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
            const count = if (found.codepoint) |cp| std.unicode.utf8Encode(cp, &encoded) catch unreachable else 0;
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
    for (html_entities.cp1252_upper, 0..) |value, index| if (value != 0 and cp == value) return @intCast(index + 0x80);
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
/// Characters newsletters repeat to push later body text out of the inbox
/// preview: blank or zero-width, never part of prose in such quantity.
fn paddingMember(cp: u21) bool {
    return switch (cp) {
        ' ', 0xa0, 0xad, 0x34f, 0x2007, 0x200b, 0x200c, 0x200d, 0x2800, 0x3164, 0xfeff => true,
        else => false,
    };
}
fn newsletterPadding(raw: []const u8, start: usize) ?PaddingRun {
    const first = rune(raw[start..]) orelse return null;
    if (!paddingMember(first.cp)) return null;
    var members: usize = 0;
    var exotic: usize = 0;
    var newlines: usize = 0;
    var line_start: ?usize = null;
    var pos = start;
    while (pos < raw.len) {
        const value = rune(raw[pos..]) orelse break;
        switch (value.cp) {
            '\n' => {
                // Do not consume padding used as a literal indented-code
                // example on the following line.
                const following = raw[pos + 1 ..];
                if (std.mem.startsWith(u8, following, "    ") or std.mem.startsWith(u8, following, "\t")) break;
                newlines += 1;
                line_start = pos + 1;
            },
            '\t', '\r' => {},
            else => {
                if (!paddingMember(value.cp)) break;
                members += 1;
                exotic += @intFromBool(value.cp > 0x7f);
            },
        }
        pos += value.consumed;
    }
    // A long run dominated by non-ASCII blanks is strong evidence. Ordinary
    // spacing and indentation (ASCII only), Unicode prose, emoji joiners and
    // short intentional examples remain unchanged.
    return .{ .end = pos, .newlines = @min(newlines, 2), .line_start = line_start, .remove = members >= 16 and exotic >= 8 };
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

fn blankRune(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\r' or cp == 0xa0 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x202f or cp == 0x205f or
        cp == 0x2800 or cp == 0x3000 or cp == 0x3164 or ignorable(cp);
}
fn blankLine(line: []const u8) bool {
    var pos: usize = 0;
    while (pos < line.len) {
        const value = rune(line[pos..]) orelse return false;
        if (!blankRune(value.cp)) return false;
        pos += value.consumed;
    }
    return true;
}
fn indentedCode(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t");
}

/// Display copy without invisible clutter: a line of only whitespace and
/// default-ignorable characters becomes empty, more than two consecutive
/// empty lines become one, and zero-width fillers that would each occupy a
/// blank terminal cell disappear (joiners only where nothing precedes them to
/// join). Fenced blocks, code lines and blank runs inside indented code stay
/// byte-exact. Never applied to stored mail or reply sources.
pub fn tidyBlankLinesDisplay(allocator: Allocator, raw: []const u8) !?[]u8 {
    if (raw.len > max_bytes or !std.unicode.utf8ValidateSlice(raw)) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    // Every step copies or removes input bytes, so the input length suffices.
    try output.ensureTotalCapacityPrecise(allocator, raw.len);
    var start: usize = 0;
    var fence: ?u8 = null;
    var blank_start: usize = 0;
    var blank_lines: usize = 0;
    var previous_code = false;
    while (start < raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, start, '\n') orelse raw.len;
        const line = raw[start..end];
        const next = @min(end + 1, raw.len);
        const clean = std.mem.trimStart(u8, line, " \t\r");
        const boundary: ?u8 = if (std.mem.startsWith(u8, clean, "```")) '`' else if (std.mem.startsWith(u8, clean, "~~~")) '~' else null;
        const literal = fence != null or boundary != null;
        if (boundary) |kind| {
            if (fence == null) fence = kind else if (fence.? == kind) fence = null;
        }
        // An indented line of exotic padding is a code example, not a blank.
        if (!literal and (std.mem.trim(u8, line, " \t\r").len == 0 or (!indentedCode(line) and blankLine(line)))) {
            if (blank_lines == 0) blank_start = start;
            // An unterminated final blank segment is not a line of its own.
            blank_lines += @intFromBool(end < raw.len);
            start = next;
            continue;
        }
        if (blank_lines > 0) {
            if (previous_code and indentedCode(line)) output.appendSliceAssumeCapacity(raw[blank_start..start]) else output.appendNTimesAssumeCapacity('\n', if (blank_lines > 2) 1 else blank_lines);
            blank_lines = 0;
        }
        if (literal or codeLine(line)) output.appendSliceAssumeCapacity(line) else {
            var pos: usize = 0;
            var previous: u21 = ' ';
            while (pos < line.len) {
                const value = rune(line[pos..]).?;
                const joiner = value.cp == 0x34f or value.cp == 0x200c or value.cp == 0x200d;
                if (!(ignorable(value.cp) and (!joiner or blankRune(previous)))) {
                    output.appendSliceAssumeCapacity(line[pos..][0..value.consumed]);
                    previous = value.cp;
                }
                pos += value.consumed;
            }
        }
        if (end < raw.len) output.appendAssumeCapacity('\n');
        previous_code = !literal and indentedCode(line);
        start = next;
    }
    if (blank_lines > 0) output.appendNTimesAssumeCapacity('\n', if (blank_lines > 2) 1 else blank_lines);
    if (std.mem.eql(u8, output.items, raw)) {
        output.deinit(allocator);
        return null;
    }
    return try output.toOwnedSlice(allocator);
}

/// The reader owns a display-only snapshot; no correction affects the body
/// returned by the CLI or used for quoting/composing a reply.
pub fn preparePlainBodyDisplay(allocator: Allocator, raw: []const u8) !?[]u8 {
    var current: ?[]u8 = null;
    errdefer if (current) |owned| allocator.free(owned);
    inline for (.{ removeNewsletterPaddingDisplay, tidyBlankLinesDisplay, repairMojibakeDisplay }) |pass| {
        if (try pass(allocator, current orelse raw)) |next| {
            if (current) |owned| allocator.free(owned);
            current = next;
        }
    }
    return current;
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
    const expected = "Fictional release preview.\n\nHello from the team.\nRead: https://example.test/release\n";
    const display = (try preparePlainBodyDisplay(allocator, raw)).?;
    defer allocator.free(display);
    try std.testing.expectEqualStrings(expected, display);
    try std.testing.expect(std.mem.indexOf(u8, raw, padding) != null);
    // Apply the same two independent corrections once while retaining body
    // bytes as the caller's authoritative source.
    const mojibake = "F\u{c3}\u{a4}rben und gr\u{c3}\u{bc}nen. " ++ padding ++ "\n\nNext.";
    const combined = (try preparePlainBodyDisplay(allocator, mojibake)).?;
    defer allocator.free(combined);
    try std.testing.expectEqualStrings("Färben und grünen.\n\nNext.", combined);
    const inline_padding = (try preparePlainBodyDisplay(allocator, "Before" ++ padding ++ "after.")).?;
    defer allocator.free(inline_padding);
    try std.testing.expectEqualStrings("Before after.", inline_padding);
}

test "mail display: newsletter heuristic preserves short runs code combining scripts and literal markup" {
    const allocator = std.testing.allocator;
    const padding = &(comptime repeatedForTest("\u{2007} \u{034f} ", 8));
    for ([_][]const u8{
        "a\u{034f}\u{301} café 👩‍💻 text.",
        &(comptime repeatedForTest("\u{2007} \u{034f} ", 3)),
        "Seven\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007} figure spaces align digits.",
        "Plain indentation:" ++ (comptime repeatedForTest(" ", 40)) ++ "value\n" ++ (comptime repeatedForTest(" ", 20)) ++ "next",
        "```text\n" ++ padding ++ "\n```\nLiteral example.",
        "~~~\n" ++ padding ++ "\n~~~\nLiteral example.",
        "    " ++ padding ++ "\nIndented code.",
        "<p>literal markup</p> &amp; <team@example.test>",
    }) |raw| try std.testing.expect((try removeNewsletterPaddingDisplay(allocator, raw)) == null);
    const invalid = [_]u8{0xff};
    try std.testing.expect((try preparePlainBodyDisplay(allocator, &invalid)) == null);
    // Any long run dominated by non-ASCII blanks is padding, whatever its mix.
    for ([_][]const u8{
        &(comptime repeatedForTest("\u{2007} \u{034f} ", 7)),
        &(comptime repeatedForTest("\u{2007}", 100)),
        &(comptime repeatedForTest("\u{034f}", 100)),
        &(comptime repeatedForTest("\u{200c}\u{a0}", 8)),
        &(comptime repeatedForTest("\u{2800}\u{3164}\u{ad}\u{feff}\u{200b}\u{200d} ", 3)),
    }) |filler| {
        const raw = try std.mem.concat(allocator, u8, &.{ "Preview", filler, "body." });
        defer allocator.free(raw);
        const display = (try removeNewsletterPaddingDisplay(allocator, raw)).?;
        defer allocator.free(display);
        try std.testing.expectEqualStrings("Preview body.", display);
    }
}

test "mail display: blank-looking lines empty, long empty runs collapse and standalone fillers vanish" {
    const allocator = std.testing.allocator;
    const raw = "A\n\n\n\n\nB\n \t \r\nC\n\u{200b}\u{a0}\u{3000}\nD\n\n\nE\u{200b} \u{200d}F\u{ad}G a\u{034f}\u{301} 👩‍💻 x\u{200c}y\n\u{feff}\n \n\n\u{2060}";
    const display = (try preparePlainBodyDisplay(allocator, raw)).?;
    defer allocator.free(display);
    try std.testing.expectEqualStrings("A\n\nB\n\nC\n\nD\n\n\nE FG a\u{034f}\u{301} 👩‍💻 x\u{200c}y\n\n", display);
    // Stored bytes are untouched; code keeps its exact blank runs and fillers.
    try std.testing.expect(std.mem.indexOf(u8, raw, "\u{200b}") != null);
    for ([_][]const u8{
        "Already tidy.\n\nTwo empty lines follow.\n\n\nEnd.\n",
        "```text\n\n\n\n\nx\u{200b}\n \n```\n",
        "~~~\n\u{200b}\n\n\n\n~~~",
        "    first\n\n\n\n    second\u{200b}\n\tthird\n",
        "const padded = \"\u{200b}\";\n",
    }) |unchanged| try std.testing.expect((try tidyBlankLinesDisplay(allocator, unchanged)) == null);
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(backing: Allocator) !void {
            const value = (try preparePlainBodyDisplay(backing, "F\u{c3}\u{a4}rben und gr\u{c3}\u{bc}nen.\n\n\n\n" ++ (comptime repeatedForTest("\u{200c}\u{a0}", 8)) ++ "\nNext.\u{200b}")).?;
            defer backing.free(value);
            try std.testing.expectEqualStrings("Färben und grünen.\n\nNext.", value);
        }
    }.run, .{});
}

test "mail display: previews share the entity table, drop invisible fillers and map Windows-1252 references" {
    const a = std.testing.allocator;
    const value = (try decodePreview(a, "&zwnj;&#847;&shy;Caf&eacute; &hellip; it&#146;s &bdquo;x&ldquo; &#x80;5 &Omega; &check; &copy 2026 &#129; &lrm;end")).?;
    defer a.free(value);
    try std.testing.expectEqualStrings("Café … it’s „x“ €5 Ω ✓ &copy 2026 &#129; end", value);
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
