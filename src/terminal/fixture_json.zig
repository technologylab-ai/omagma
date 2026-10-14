//! Fixture envelopes may contain large base64 API responses. Zig 0.17's
//! dynamic Value parser always copies strings, even with alloc_if_needed.
//! Use the standard validating Scanner while borrowing unescaped scalars from
//! the caller-owned file buffer. Both that buffer and allocator must outlive
//! every returned value; this is not a public request parser.
const std = @import("std");
const Value = std.json.Value;

pub fn parse(a: std.mem.Allocator, raw: []const u8) !Value {
    if (raw.len > 16 * 1024 * 1024) return error.StreamTooLong;
    var scanner = std.json.Scanner.initCompleteInput(a, raw);
    defer scanner.deinit();
    const result = try value(a, &scanner, try next(a, &scanner), 0);
    if (try next(a, &scanner) != .end_of_document) return error.InvalidJson;
    return result;
}
fn next(a: std.mem.Allocator, scanner: *std.json.Scanner) !std.json.Token {
    return scanner.nextAllocMax(a, .alloc_if_needed, 16 * 1024 * 1024);
}
fn value(a: std.mem.Allocator, scanner: *std.json.Scanner, token: std.json.Token, depth: usize) anyerror!Value {
    if (depth > 64) return error.JsonTooDeep;
    return switch (token) {
        .string, .allocated_string => |text| .{ .string = text },
        .number, .allocated_number => |text| Value.parseFromNumberSlice(text),
        .null => .null,
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .array_begin => blk: {
            var result: Value = .{ .array = .init(a) };
            while (true) {
                const item = try next(a, scanner);
                if (item == .array_end) break;
                try result.array.append(try value(a, scanner, item, depth + 1));
            }
            break :blk result;
        },
        .object_begin => blk: {
            var result: Value = .{ .object = .empty };
            while (true) {
                const key_token = try next(a, scanner);
                if (key_token == .object_end) break;
                const key = switch (key_token) {
                    .string, .allocated_string => |text| text,
                    else => return error.InvalidJson,
                };
                if (result.object.contains(key)) return error.DuplicateField;
                const item = try value(a, scanner, try next(a, scanner), depth + 1);
                try result.object.put(a, key, item);
            }
            break :blk result;
        },
        else => error.InvalidJson,
    };
}

test "forward memory: fixture parser borrows plain scalars and validates escaped JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "{\"plain\":\"borrowed bytes\",\"escaped\":\"quote \\\" \\u00e9\\n\",\"numbers\":[1,-2,1.5,1e999],\"flags\":[true,false,null]}";
    const parsed = try parse(a, raw);
    const plain = parsed.object.get("plain").?.string;
    try std.testing.expect(@intFromPtr(plain.ptr) >= @intFromPtr(raw.ptr) and @intFromPtr(plain.ptr) + plain.len <= @intFromPtr(raw.ptr) + raw.len);
    try std.testing.expectEqualStrings("quote \" é\n", parsed.object.get("escaped").?.string);
    try std.testing.expectEqual(@as(i64, -2), parsed.object.get("numbers").?.array.items[1].integer);
    try std.testing.expectEqualStrings("1e999", parsed.object.get("numbers").?.array.items[3].number_string);
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"x\":1,\"x\":2}"));
    for ([_][]const u8{ "{\"x\":}", "[1,]", "true false", "\"\\ud800\"" }) |invalid| {
        if (parse(a, invalid)) |_| return error.TestUnexpectedResult else |_| {}
    }
}
