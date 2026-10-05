const std = @import("std");
pub const Value = std.json.Value;
pub fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
pub fn string(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidRequest;
}
pub fn text(v: Value, key: []const u8) []const u8 {
    return if (get(v, key)) |x| if (x == .string) x.string else "" else "";
}
pub fn required(v: Value, key: []const u8) ![]const u8 {
    const s = try string(get(v, key) orelse return error.MissingField);
    if (s.len == 0) return error.MissingField;
    return s;
}
pub fn boolean(v: Value, key: []const u8, default: bool) !bool {
    return if (get(v, key)) |x| if (x == .bool) x.bool else error.InvalidRequest else default;
}
pub fn integer(v: Value, key: []const u8, default: i64) !i64 {
    return if (get(v, key)) |x| if (x == .integer) x.integer else error.InvalidRequest else default;
}
pub fn value(a: std.mem.Allocator, v: anytype) !Value {
    const raw = try std.json.Stringify.valueAlloc(a, v, .{ .emit_null_optional_fields = false });
    return std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
}
pub fn decode(comptime T: type, a: std.mem.Allocator, v: Value) !T {
    return std.json.parseFromValueLeaky(T, a, v, .{ .ignore_unknown_fields = true });
}
pub fn object(a: std.mem.Allocator) Value {
    _ = a;
    return .{ .object = .empty };
}

/// Clone top-level object storage before adding/removing keys. Values borrow
/// immutable caller storage; the ordered-map capacity/layout must not be aliased.
pub fn copyObject(a: std.mem.Allocator, input: Value) !Value {
    if (input != .object) return error.InvalidRequest;
    var out = object(a);
    var it = input.object.iterator();
    while (it.next()) |field| try out.object.put(a, field.key_ptr.*, field.value_ptr.*);
    return out;
}

test "copied request map growth preserves original account query and label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try std.json.parseFromSliceLeaky(Value, a, "{\"cmd\":\"mail.refresh\",\"account\":\"fictional@example.test\",\"query\":\"subject:fictional\",\"label\":\"STARRED\"}", .{});
    var copied = try copyObject(a, original);
    for (0..24) |i| try copied.object.put(a, try std.fmt.allocPrint(a, "internal{d}", .{i}), .{ .integer = @intCast(i) });
    try copied.object.put(a, "label", .{ .string = "INBOX" });
    try std.testing.expectEqualStrings("fictional@example.test", text(original, "account"));
    try std.testing.expectEqualStrings("subject:fictional", text(original, "query"));
    try std.testing.expectEqualStrings("STARRED", text(original, "label"));
    try std.testing.expectEqual(@as(usize, 4), original.object.count());
    try std.testing.expectEqualStrings("INBOX", text(copied, "label"));
}
