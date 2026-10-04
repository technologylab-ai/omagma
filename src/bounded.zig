const std = @import("std");
const limits = @import("limits.zig");

pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = @splat(0),
        len: u16 = 0,
        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn set(self: *Self, input: []const u8) !void {
            if (input.len > capacity) return error.CapacityExceeded;
            if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
            @memcpy(self.bytes[0..input.len], input);
            self.len = @intCast(input.len);
        }
        pub fn display(self: *Self, input: []const u8) void {
            self.len = 0;
            var pos: usize = 0;
            while (pos < input.len) {
                const n = std.unicode.utf8ByteSequenceLength(input[pos]) catch {
                    pos += 1;
                    continue;
                };
                if (pos + n > input.len) break;
                const cp = std.unicode.utf8Decode(input[pos..][0..n]) catch {
                    pos += 1;
                    continue;
                };
                if (cp < 32 or (cp >= 127 and cp <= 159) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) {
                    if (self.len < capacity and self.len > 0 and self.bytes[self.len - 1] != ' ') {
                        self.bytes[self.len] = ' ';
                        self.len += 1;
                    }
                } else {
                    if (@as(usize, self.len) + n > capacity) break;
                    @memcpy(self.bytes[self.len..][0..n], input[pos..][0..n]);
                    self.len += n;
                }
                pos += n;
            }
        }
        pub fn wipe(self: *Self) void {
            std.crypto.secureZero(u8, &self.bytes);
            self.len = 0;
        }
    };
}

pub fn identifier(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.max_id) return error.InvalidIdentifier;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidIdentifier;
}
pub fn address(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.max_address) return error.InvalidAddress;
    var ats: usize = 0;
    for (text) |c| {
        if (c <= 32 or c >= 127 or c == '/' or c == '\\' or c == '?' or c == '#' or c == '"') return error.InvalidAddress;
        if (c == '@') ats += 1;
    }
    if (ats != 1 or text[0] == '@' or text[text.len - 1] == '@') return error.InvalidAddress;
}
pub fn profile(text: []const u8) !void {
    if (text.len == 0 or text.len > 128 or std.mem.eql(u8, text, "Default")) return error.InvalidProfile;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != ' ' and c != '-' and c != '_') return error.InvalidProfile;
}

// A lexical preflight bounds nesting and token count before the allocating parser.
// The parser below verifies grammar and rejects duplicate object fields.
pub fn preflight(text: []const u8) !void {
    var depth: usize = 0;
    var tokens: usize = 0;
    var in_string = false;
    var escaped = false;
    var atom = false;
    for (text) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') escaped = true else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => {
                in_string = true;
                atom = false;
                tokens += 1;
            },
            '{', '[' => {
                depth += 1;
                tokens += 1;
                atom = false;
                if (depth > limits.max_depth) return error.JsonTooDeep;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
                atom = false;
            },
            ' ', '\t', '\n', '\r', ':', ',' => {
                atom = false;
            },
            else => {
                if (!atom) {
                    tokens += 1;
                    atom = true;
                }
            },
        }
        if (tokens > limits.max_tokens) return error.JsonTooManyTokens;
    }
    if (in_string or depth != 0) return error.InvalidJson;
}
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    try preflight(text);
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always, .max_value_len = limits.response, .duplicate_field_behavior = .@"error" });
}
pub fn field(v: std.json.Value, key: []const u8) !std.json.Value {
    if (v != .object) return error.InvalidJson;
    return v.object.get(key) orelse error.MissingField;
}
pub fn optional(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}
pub fn string(v: std.json.Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidJson;
}
pub fn integer(v: std.json.Value) !i64 {
    return switch (v) {
        .integer => v.integer,
        .string => std.fmt.parseInt(i64, v.string, 10) catch return error.InvalidJson,
        else => error.InvalidJson,
    };
}

pub fn jsonString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}

// RFC 2047 B/Q words for UTF-8, ASCII and Latin-1. Unsupported/malformed
// encodings remain readable literal text; decoded control characters sanitize.
pub fn header(comptime n: usize, output: *Text(n), raw: []const u8) void {
    var buffer: [n * 2]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "=?")) {
            const cs_end = std.mem.indexOfScalarPos(u8, raw, i + 2, '?') orelse raw.len;
            if (cs_end + 3 <= raw.len and raw[cs_end + 2] == '?') {
                const end = std.mem.indexOfPos(u8, raw, cs_end + 3, "?=") orelse raw.len;
                if (end < raw.len) {
                    const charset = raw[i + 2 .. cs_end];
                    const data = raw[cs_end + 3 .. end];
                    var decoded: [n * 2]u8 = undefined;
                    const count = decodeWord(raw[cs_end + 1], data, &decoded) catch 0;
                    const utf = std.ascii.eqlIgnoreCase(charset, "utf-8") or std.ascii.eqlIgnoreCase(charset, "us-ascii");
                    const latin = std.ascii.eqlIgnoreCase(charset, "iso-8859-1");
                    if (count > 0 and (utf or latin)) {
                        if (utf) w.writeAll(decoded[0..count]) catch break else for (decoded[0..count]) |c| {
                            if (c < 128) w.writeByte(c) catch break else {
                                const bytes = [_]u8{ 0xc0 | (c >> 6), 0x80 | (c & 63) };
                                w.writeAll(&bytes) catch break;
                            }
                        }
                        i = end + 2;
                        var j = i;
                        while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) : (j += 1) {}
                        if (std.mem.startsWith(u8, raw[j..], "=?")) i = j;
                        continue;
                    }
                }
            }
        }
        w.writeByte(raw[i]) catch break;
        i += 1;
    }
    output.display(w.buffered());
}
fn decodeWord(kind: u8, data: []const u8, out: []u8) !usize {
    if (kind == 'B' or kind == 'b') {
        const size = try std.base64.standard.Decoder.calcSizeForSlice(data);
        if (size > out.len) return error.CapacityExceeded;
        try std.base64.standard.Decoder.decode(out[0..size], data);
        return size;
    }
    if (kind != 'Q' and kind != 'q') return error.UnsupportedEncoding;
    var i: usize = 0;
    var size: usize = 0;
    while (i < data.len) : (i += 1) {
        if (size == out.len) return error.CapacityExceeded;
        if (data[i] == '=') {
            if (i + 2 >= data.len) return error.InvalidEncoding;
            out[size] = try std.fmt.parseInt(u8, data[i + 1 ..][0..2], 16);
            i += 2;
        } else out[size] = if (data[i] == '_') ' ' else data[i];
        size += 1;
    }
    return size;
}

test "display controls and UTF-8 boundary; identifiers refuse overflow" {
    var t: Text(5) = .{};
    t.display("a\x00éé");
    try std.testing.expectEqualStrings("a é", t.slice());
    try std.testing.expectError(error.InvalidIdentifier, identifier("a/b"));
    try std.testing.expectError(error.CapacityExceeded, t.set("123456"));
}
test "encoded and non-ASCII mail headers" {
    var t: Text(512) = .{};
    header(512, &t, "=?UTF-8?B?Sm9zw6k=?= =?UTF-8?Q?_hello?=");
    try std.testing.expectEqualStrings("José hello", t.slice());
    header(512, &t, "=?iso-8859-1?Q?Jos=E9?=");
    try std.testing.expectEqualStrings("José", t.slice());
}
test "nested JSON refused before allocation; duplicate keys refused" {
    var buf: [16 * 1024]u8 = undefined;
    var f = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectError(error.DuplicateField, parse(f.allocator(), "{\"id\":1,\"id\":2}"));
    var deep: [130]u8 = undefined;
    @memset(deep[0..65], '[');
    @memset(deep[65..], ']');
    try std.testing.expectError(error.JsonTooDeep, preflight(&deep));
}
