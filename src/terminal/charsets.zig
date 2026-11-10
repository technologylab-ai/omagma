//! Lenient charset decoding for received mail. Display must never be refused
//! because a sender mislabelled or corrupted text: every input produces valid
//! UTF-8, with U+FFFD for bytes that cannot be mapped. Callers still sanitize
//! the result; this module only converts encodings. No I/O.
const std = @import("std");
const generated = @import("charset_tables.zig");

pub const Result = struct {
    text: []const u8,
    /// At least one byte had no mapping and became U+FFFD.
    lossy: bool = false,
    /// Output stopped at the caller's byte limit on a code-point boundary.
    truncated: bool = false,
};

const Family = enum { utf8, ascii, single, utf16le, utf16be, multibyte, unknown };
const Resolved = struct { family: Family, table: ?*const [128]u16 = null };

const aliases = [_]struct { alias: []const u8, name: []const u8 }{
    .{ .alias = "utf8", .name = "utf-8" },
    .{ .alias = "unicode-1-1-utf-8", .name = "utf-8" },
    .{ .alias = "utf-8-sig", .name = "utf-8" },
    .{ .alias = "ascii", .name = "us-ascii" },
    .{ .alias = "us", .name = "us-ascii" },
    .{ .alias = "ansi_x3.4-1968", .name = "us-ascii" },
    .{ .alias = "ansi_x3.4-1986", .name = "us-ascii" },
    .{ .alias = "iso646-us", .name = "us-ascii" },
    .{ .alias = "iso-646.irv:1991", .name = "us-ascii" },
    .{ .alias = "646", .name = "us-ascii" },
    .{ .alias = "latin1", .name = "iso-8859-1" },
    .{ .alias = "latin-1", .name = "iso-8859-1" },
    .{ .alias = "l1", .name = "iso-8859-1" },
    .{ .alias = "cp819", .name = "iso-8859-1" },
    .{ .alias = "ibm819", .name = "iso-8859-1" },
    .{ .alias = "iso-8859-1:1987", .name = "iso-8859-1" },
    .{ .alias = "latin2", .name = "iso-8859-2" },
    .{ .alias = "l2", .name = "iso-8859-2" },
    .{ .alias = "latin3", .name = "iso-8859-3" },
    .{ .alias = "latin4", .name = "iso-8859-4" },
    .{ .alias = "cyrillic", .name = "iso-8859-5" },
    .{ .alias = "arabic", .name = "iso-8859-6" },
    .{ .alias = "greek", .name = "iso-8859-7" },
    .{ .alias = "hebrew", .name = "iso-8859-8" },
    .{ .alias = "iso-8859-8-i", .name = "iso-8859-8" },
    .{ .alias = "latin5", .name = "iso-8859-9" },
    .{ .alias = "latin6", .name = "iso-8859-10" },
    .{ .alias = "tis-620", .name = "windows-874" },
    .{ .alias = "latin7", .name = "iso-8859-13" },
    .{ .alias = "latin8", .name = "iso-8859-14" },
    .{ .alias = "latin9", .name = "iso-8859-15" },
    .{ .alias = "latin0", .name = "iso-8859-15" },
    .{ .alias = "latin10", .name = "iso-8859-16" },
    .{ .alias = "koi8r", .name = "koi8-r" },
    .{ .alias = "koi8u", .name = "koi8-u" },
    .{ .alias = "cp850", .name = "ibm850" },
    .{ .alias = "850", .name = "ibm850" },
    .{ .alias = "cp437", .name = "ibm437" },
    .{ .alias = "437", .name = "ibm437" },
    .{ .alias = "cp852", .name = "ibm852" },
    .{ .alias = "cp866", .name = "ibm866" },
    .{ .alias = "mac", .name = "macintosh" },
    .{ .alias = "macroman", .name = "macintosh" },
    .{ .alias = "mac-roman", .name = "macintosh" },
    .{ .alias = "cp874", .name = "windows-874" },
    .{ .alias = "utf-16", .name = "utf-16le" },
    .{ .alias = "utf16", .name = "utf-16le" },
    .{ .alias = "ucs-2", .name = "utf-16le" },
    .{ .alias = "unicode", .name = "utf-16le" },
    .{ .alias = "utf16le", .name = "utf-16le" },
    .{ .alias = "utf16be", .name = "utf-16be" },
};
const multibyte = [_][]const u8{ "gb2312", "gbk", "gb18030", "hz-gb-2312", "big5", "big5-hkscs", "shift_jis", "shift-jis", "sjis", "ms932", "cp932", "windows-31j", "euc-jp", "iso-2022-jp", "iso-2022-kr", "euc-kr", "ks_c_5601-1987", "cp949", "windows-949", "utf-7", "utf-32", "utf-32le", "utf-32be" };

/// Lowercased, trimmed and stripped of quotes, a `*language` suffix and the
/// `x-`/`cs` vanity prefixes. Returns the slice of `buffer` that was written.
fn canonical(buffer: *[40]u8, raw: []const u8) []const u8 {
    var name = std.mem.trim(u8, raw, " \t\"'");
    if (std.mem.indexOfScalar(u8, name, '*')) |star| name = name[0..star];
    if (name.len > buffer.len) return "";
    var used: usize = 0;
    for (name) |c| {
        buffer[used] = if (c == '_' and !std.ascii.startsWithIgnoreCase(name, "shift") and !std.ascii.startsWithIgnoreCase(name, "ks_") and !std.ascii.startsWithIgnoreCase(name, "ansi_")) '-' else std.ascii.toLower(c);
        used += 1;
    }
    var out: []const u8 = buffer[0..used];
    if (std.mem.startsWith(u8, out, "x-")) out = out[2..];
    // `windows1252`, `cp-1252`, `cp1252`, `win-1252` and `iso8859-1` spellings.
    return out;
}

fn digitsSuffix(name: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) {
        const rest = std.mem.trimStart(u8, name[prefix.len..], "-");
        if (rest.len == 0) return null;
        for (rest) |c| if (!std.ascii.isDigit(c)) return null;
        return rest;
    };
    return null;
}

fn table(name: []const u8) ?*const [128]u16 {
    for (&generated.tables) |*entry| if (std.mem.eql(u8, entry.name, name)) return &entry.map;
    return null;
}

fn resolve(raw: []const u8) Resolved {
    var buffer: [40]u8 = undefined;
    var name = canonical(&buffer, raw);
    if (name.len == 0 or std.mem.eql(u8, name, "utf-8")) return .{ .family = .utf8 };
    for (aliases) |alias| if (std.mem.eql(u8, name, alias.alias)) {
        name = alias.name;
        break;
    };
    if (std.mem.eql(u8, name, "utf-8")) return .{ .family = .utf8 };
    if (std.mem.eql(u8, name, "us-ascii")) return .{ .family = .ascii };
    if (std.mem.eql(u8, name, "utf-16le")) return .{ .family = .utf16le };
    if (std.mem.eql(u8, name, "utf-16be")) return .{ .family = .utf16be };
    if (table(name)) |map| return .{ .family = .single, .table = map };
    var rebuilt: [40]u8 = undefined;
    if (digitsSuffix(name, &.{ "windows", "win", "cp" })) |digits| {
        const candidate = std.fmt.bufPrint(&rebuilt, "windows-{s}", .{digits}) catch "";
        if (table(candidate)) |map| return .{ .family = .single, .table = map };
        const ibm = std.fmt.bufPrint(&rebuilt, "ibm{s}", .{digits}) catch "";
        if (table(ibm)) |map| return .{ .family = .single, .table = map };
    }
    if (digitsSuffix(name, &.{ "iso-8859", "iso8859", "8859" })) |digits| {
        const candidate = std.fmt.bufPrint(&rebuilt, "iso-8859-{s}", .{digits}) catch "";
        if (table(candidate)) |map| return .{ .family = .single, .table = map };
    }
    for (multibyte) |known| if (std.mem.eql(u8, name, known)) return .{ .family = .multibyte };
    return .{ .family = .unknown };
}

/// True when `charset` names an encoding this module maps exactly.
pub fn supported(charset: []const u8) bool {
    return switch (resolve(charset).family) {
        .utf8, .ascii, .single, .utf16le, .utf16be => true,
        .multibyte, .unknown => false,
    };
}

const Writer = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    limit: usize,
    lossy: bool = false,
    truncated: bool = false,
    /// Returns false once the limit is reached; callers stop converting.
    fn put(self: *Writer, cp: u21) !bool {
        var encoded: [4]u8 = undefined;
        const valid: u21 = if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else cp;
        if (valid == 0xfffd) self.lossy = true;
        const count = std.unicode.utf8Encode(valid, &encoded) catch unreachable;
        if (count > self.limit - self.out.items.len) {
            self.truncated = true;
            return false;
        }
        try self.out.appendSlice(self.allocator, encoded[0..count]);
        return true;
    }
    fn slice(self: *Writer, bytes: []const u8) !bool {
        if (bytes.len > self.limit - self.out.items.len) {
            self.truncated = true;
            return false;
        }
        try self.out.appendSlice(self.allocator, bytes);
        return true;
    }
};

/// Decode `data` to valid UTF-8 without ever refusing the text. `limit` bounds
/// the output; reaching it truncates on a code-point boundary. Only
/// allocation failure is returned as an error.
pub fn decodeLossy(data: []const u8, charset: []const u8, allocator: std.mem.Allocator, limit: usize) error{OutOfMemory}!Result {
    const resolved = resolve(charset);
    var writer: Writer = .{ .allocator = allocator, .limit = limit };
    errdefer writer.out.deinit(allocator);
    try writer.out.ensureTotalCapacity(allocator, @min(data.len, limit));
    switch (resolved.family) {
        .single => {
            const map = resolved.table.?;
            for (data) |c| if (!try writer.put(if (c < 128) c else map[c - 128])) break;
        },
        .utf16le, .utf16be => {
            var big = resolved.family == .utf16be;
            var pos: usize = 0;
            if (data.len >= 2 and data[0] == 0xfe and data[1] == 0xff) {
                big = true;
                pos = 2;
            } else if (data.len >= 2 and data[0] == 0xff and data[1] == 0xfe) {
                big = false;
                pos = 2;
            }
            while (pos + 1 < data.len) {
                const unit: u21 = if (big) @as(u21, data[pos]) << 8 | data[pos + 1] else @as(u21, data[pos + 1]) << 8 | data[pos];
                pos += 2;
                var cp = unit;
                if (unit >= 0xd800 and unit <= 0xdbff and pos + 1 < data.len) {
                    const low: u21 = if (big) @as(u21, data[pos]) << 8 | data[pos + 1] else @as(u21, data[pos + 1]) << 8 | data[pos];
                    if (low >= 0xdc00 and low <= 0xdfff) {
                        cp = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
                        pos += 2;
                    }
                }
                if (!try writer.put(cp)) break;
            }
            if (pos < data.len and !writer.truncated) _ = try writer.put(0xfffd);
        },
        .utf8, .ascii, .multibyte, .unknown => {
            // Valid UTF-8 sequences are kept whatever the label says: senders
            // frequently declare us-ascii or nothing for UTF-8 text. A stray
            // high byte in ASCII/unknown text is almost always Windows-1252;
            // in UTF-8 or an unmapped multi-byte encoding it is unknowable.
            const guess = if (resolved.family == .ascii or resolved.family == .unknown) table("windows-1252") else null;
            var pos: usize = 0;
            var replaced = false;
            while (pos < data.len) {
                const c = data[pos];
                if (c < 128) {
                    // ISO-2022 escape sequences are noise once unmapped.
                    if (!try writer.slice(data[pos..][0..1])) break;
                    pos += 1;
                    replaced = false;
                    continue;
                }
                const count = std.unicode.utf8ByteSequenceLength(c) catch 0;
                if (count > 1 and pos + count <= data.len and std.unicode.utf8ValidateSlice(data[pos..][0..count])) {
                    if (!try writer.slice(data[pos..][0..count])) break;
                    pos += count;
                    replaced = false;
                    continue;
                }
                if (guess) |map| {
                    if (!try writer.put(map[c - 128])) break;
                } else if (!replaced) {
                    // One marker per undecodable run keeps the text readable.
                    if (!try writer.put(0xfffd)) break;
                    replaced = true;
                }
                pos += 1;
            }
        },
    }
    return .{ .text = try writer.out.toOwnedSlice(allocator), .lossy = writer.lossy, .truncated = writer.truncated };
}

/// Largest prefix of valid UTF-8 `text` that fits `limit` bytes.
pub fn clip(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

test "charsets: aliases and vanity spellings resolve to exact tables" {
    for ([_][]const u8{ "UTF8", "\"utf-8\"", "'UTF-8'", "utf-8*en", "us-ascii", "ANSI_X3.4-1968", "iso8859-1", "ISO_8859-1", "Latin1", "cp-1252", "windows1252", "x-cp1252", "WIN-1250", "ISO-8859-15", "koi8-r", "KOI8_U", "cp850", "IBM850", "x-mac-roman", "windows-1256", "utf-16", "tis-620" }) |name| try std.testing.expect(supported(name));
    for ([_][]const u8{ "gb2312", "Shift_JIS", "iso-2022-jp", "unknown-8bit", "x-unknown", "klingon", "big5" }) |name| try std.testing.expect(!supported(name));
}

test "charsets: lossy decoding never refuses and keeps readable text" {
    const a = std.testing.allocator;
    const cases = [_]struct { data: []const u8, charset: []const u8, text: []const u8, lossy: bool }{
        .{ .data = "Gr\xfc\xdfe", .charset = "iso-8859-1", .text = "Grüße", .lossy = false },
        .{ .data = "Gr\xfc\xdfe", .charset = "us-ascii", .text = "Grüße", .lossy = false },
        .{ .data = "Gr\xfc\xdfe", .charset = "unknown-8bit", .text = "Grüße", .lossy = false },
        .{ .data = "Grüße", .charset = "us-ascii", .text = "Grüße", .lossy = false },
        .{ .data = "ok \xff\xfe bad", .charset = "utf-8", .text = "ok \u{fffd} bad", .lossy = true },
        .{ .data = "\x93quoted\x94 \x80", .charset = "cp1252", .text = "\u{201c}quoted\u{201d} \u{20ac}", .lossy = false },
        .{ .data = "\xf0\xd2\xc9\xd7\xc5\xd4", .charset = "KOI8-R", .text = "Привет", .lossy = false },
        .{ .data = "\x9c\xb9", .charset = "windows-1250", .text = "śą", .lossy = false },
        .{ .data = "abc \xc4\xe3\xba\xc3 def", .charset = "gb2312", .text = "abc \u{fffd} def", .lossy = true },
        .{ .data = "\xff\xfeH\x00i\x00", .charset = "utf-16", .text = "Hi", .lossy = false },
        .{ .data = "\x00H\x00i", .charset = "utf-16be", .text = "Hi", .lossy = false },
        .{ .data = "\x81", .charset = "windows-1252", .text = "\u{fffd}", .lossy = true },
    };
    for (cases) |case| {
        const result = try decodeLossy(case.data, case.charset, a, 1024);
        defer a.free(result.text);
        try std.testing.expectEqualStrings(case.text, result.text);
        try std.testing.expectEqual(case.lossy, result.lossy);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
    }
}

test "charsets: output limit truncates on a code-point boundary" {
    const a = std.testing.allocator;
    const result = try decodeLossy("\xfc\xfc\xfc", "iso-8859-1", a, 5);
    defer a.free(result.text);
    try std.testing.expectEqualStrings("üü", result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("aü", clip("aüb", 3));
    try std.testing.expectEqualStrings("a", clip("aüb", 2));
}
