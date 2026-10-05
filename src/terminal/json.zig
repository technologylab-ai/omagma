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
    _=a;return .{ .object = .empty };
}
