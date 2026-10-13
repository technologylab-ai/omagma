//! JSON containers for immutable mail response DTOs whose strings already
//! outlive the response. This avoids a body-sized stringify/parse roundtrip.
const std = @import("std");
const j = @import("json.zig");
const Value = std.json.Value;

/// Allocates only JSON containers and borrows the DTO's immutable strings.
/// Callers must keep every source string alive through the last use of the
/// returned Value, including final response serialization. Unlike j.value,
/// this does not take ownership of caller strings.
pub fn borrowed(a: std.mem.Allocator, value: anytype) !Value {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| blk: {
            if (info.is_tuple) @compileError("Mail response tuples need an explicit representation");
            var out = j.object(a);
            inline for (info.field_names) |name| {
                const field = try borrowed(a, @field(value, name));
                // Match j.value's emit_null_optional_fields = false.
                if (field != .null) try out.object.put(a, name, field);
            }
            break :blk out;
        },
        .pointer => |pointer| blk: {
            if (pointer.size != .slice or pointer.sentinel_ptr != null) @compileError("Mail responses support ordinary slices only");
            if (pointer.child == u8) break :blk .{ .string = value };
            var out: Value = .{ .array = .init(a) };
            for (value) |item| try out.array.append(try borrowed(a, item));
            break :blk out;
        },
        .optional => if (value) |item| try borrowed(a, item) else .null,
        .@"enum" => .{ .string = @tagName(value) },
        .bool => .{ .bool = value },
        .int => if (std.math.cast(i64, value)) |integer| .{ .integer = integer } else .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{value}) },
        else => @compileError("Mail response requires an explicit representation for " ++ @typeName(@TypeOf(value))),
    };
}
