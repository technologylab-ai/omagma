//! Streaming decoder for Gmail attachments.get?fields=size,data. The large
//! base64 string never becomes a JSON allocation; only validated bytes reach
//! the private temporary destination, which the caller commits after finish.
const std = @import("std");
const t = @import("types.zig");
pub const Decoder = struct {
    writer: std.Io.Writer,
    sink: *std.Io.Writer,
    expected: usize,
    failure: ?anyerror = null,
    state: enum { start, key_start, key, colon, value, data, number, separator, done } = .start,
    key_bytes: [16]u8 = undefined,
    key_len: usize = 0,
    field: enum { data, size } = .data,
    seen_data: bool = false,
    seen_size: bool = false,
    size: usize = 0,
    number_digits: usize = 0,
    number_zero: bool = false,
    bytes: usize = 0,
    bits: u32 = 0,
    bit_count: u5 = 0,
    symbols: usize = 0,
    padding: usize = 0,
    pub fn init(sink: *std.Io.Writer, expected: usize) !Decoder {
        if (expected > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .sink = sink, .expected = expected };
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Decoder = @alignCast(@fieldParentPtr("writer", writer));
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.consume(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            count += bytes.len;
        }
        for (0..splat) |_| {
            const bytes = data[data.len - 1];
            self.consume(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            count += bytes.len;
        }
        return count;
    }
    fn consume(self: *Decoder, input: []const u8) !void {
        for (input) |c| try self.byte(c);
    }
    fn byte(self: *Decoder, c: u8) !void {
        switch (self.state) {
            .start => {
                if (std.ascii.isWhitespace(c)) return;
                if (c != '{') return error.InvalidProviderResponse;
                self.state = .key_start;
            },
            .key_start => {
                if (std.ascii.isWhitespace(c)) return;
                if (c != '"') return error.InvalidProviderResponse;
                self.key_len = 0;
                self.state = .key;
            },
            .key => {
                if (c == '"') {
                    const key = self.key_bytes[0..self.key_len];
                    if (std.mem.eql(u8, key, "data") and !self.seen_data) {
                        self.field = .data;
                        self.seen_data = true;
                    } else if (std.mem.eql(u8, key, "size") and !self.seen_size) {
                        self.field = .size;
                        self.seen_size = true;
                    } else return error.InvalidProviderResponse;
                    self.state = .colon;
                } else {
                    if (self.key_len == self.key_bytes.len or !std.ascii.isAlphabetic(c)) return error.InvalidProviderResponse;
                    self.key_bytes[self.key_len] = c;
                    self.key_len += 1;
                }
            },
            .colon => {
                if (std.ascii.isWhitespace(c)) return;
                if (c != ':') return error.InvalidProviderResponse;
                self.state = .value;
            },
            .value => {
                if (std.ascii.isWhitespace(c)) return;
                if (self.field == .data) {
                    if (c != '"') return error.InvalidProviderResponse;
                    self.state = .data;
                } else {
                    self.state = .number;
                    try self.byte(c);
                }
            },
            .data => {
                if (c == '"') {
                    const remainder = self.symbols % 4;
                    const needed: usize = if (remainder == 2) 2 else if (remainder == 3) 1 else 0;
                    if (remainder == 1 or self.bits != 0 or (self.padding != 0 and self.padding != needed)) return error.InvalidBase64;
                    self.state = .separator;
                    return;
                }
                if (c == '=') {
                    self.padding += 1;
                    if (self.padding > 2) return error.InvalidBase64;
                    return;
                }
                if (self.padding != 0) return error.InvalidBase64;
                const value: u32 = switch (c) {
                    'A'...'Z' => c - 'A',
                    'a'...'z' => c - 'a' + 26,
                    '0'...'9' => c - '0' + 52,
                    '-' => 62,
                    '_' => 63,
                    else => return error.InvalidBase64,
                };
                self.symbols += 1;
                self.bits = (self.bits << 6) | value;
                self.bit_count += 6;
                if (self.bit_count >= 8) {
                    self.bit_count -= 8;
                    if (self.bytes == self.expected) return error.BodySizeMismatch;
                    try self.sink.writeByte(@intCast(self.bits >> self.bit_count));
                    self.bytes += 1;
                    self.bits &= (@as(u32, 1) << self.bit_count) - 1;
                }
            },
            .number => {
                if (std.ascii.isDigit(c)) {
                    if (self.number_zero or self.number_digits == 10) return error.InvalidProviderResponse;
                    self.number_zero = self.number_digits == 0 and c == '0';
                    self.number_digits += 1;
                    self.size = std.math.mul(usize, self.size, 10) catch return error.BodySizeMismatch;
                    self.size = std.math.add(usize, self.size, c - '0') catch return error.BodySizeMismatch;
                    if (self.size > self.expected) return error.BodySizeMismatch;
                } else {
                    if (self.number_digits == 0 or self.size != self.expected) return error.BodySizeMismatch;
                    self.state = .separator;
                    try self.byte(c);
                }
            },
            .separator => {
                if (std.ascii.isWhitespace(c)) return;
                if (c == ',') self.state = .key_start else if (c == '}') self.state = .done else return error.InvalidProviderResponse;
            },
            .done => if (!std.ascii.isWhitespace(c)) return error.InvalidProviderResponse,
        }
    }
    pub fn finish(self: *Decoder) !void {
        if (self.failure) |err| return err;
        if (self.state != .done or !self.seen_data or !self.seen_size) return error.InvalidProviderResponse;
        if (self.bytes != self.expected or self.size != self.expected) return error.BodySizeMismatch;
    }
};

test "attachment streaming: arbitrary chunks decode padded binary and reject truncation or size drift" {
    for ([_][]const u8{ "{\"size\":3,\"data\":\"AP-A\"}", "{\"data\":\"AP-A\",\"size\":3}" }) |wire| {
        for (1..wire.len) |chunk| {
            var bytes: [3]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&bytes);
            var decoder = try Decoder.init(&sink, 3);
            var offset: usize = 0;
            while (offset < wire.len) {
                const end = @min(wire.len, offset + chunk);
                try decoder.writer.writeAll(wire[offset..end]);
                offset = end;
            }
            try decoder.finish();
            try std.testing.expectEqualSlices(u8, &.{ 0, 255, 128 }, sink.buffered());
        }
    }
    for ([_][]const u8{ "{\"size\":2,\"data\":\"AP8=\"}", "{\"size\":2,\"data\":\"AP8\"}" }) |wire| {
        var bytes: [2]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&bytes);
        var decoder = try Decoder.init(&sink, 2);
        try decoder.writer.writeAll(wire);
        try decoder.finish();
        try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, sink.buffered());
    }
    var bytes: [3]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&bytes);
    var truncated = try Decoder.init(&sink, 3);
    try truncated.writer.writeAll("{\"size\":3,\"data\":\"AP-A\"");
    try std.testing.expectError(error.InvalidProviderResponse, truncated.finish());
    var wrong_size = try Decoder.init(&sink, 2);
    try std.testing.expectError(error.WriteFailed, wrong_size.writer.writeAll("{\"size\":3,\"data\":\"AP-A\"}"));
    try std.testing.expectEqual(error.BodySizeMismatch, wrong_size.failure.?);
}
