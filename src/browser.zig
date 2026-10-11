//! No WASI, network or filesystem imports: the host only exchanges terminal bytes.
const std = @import("std");
const tui = @import("terminal/tui.zig");
pub const panic = std.debug.FullPanic(trap);
fn trap(_: []const u8, _: ?usize) noreturn {
    @trap();
}
pub const std_options: std.Options = .{ .log_level = .err, .logFn = quietLog };
fn quietLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}
const allocator = std.heap.wasm_allocator;
var demo: tui.BrowserDemo = undefined;
var initialized = false;
var input_buffer: [1024]u8 = undefined;
var output_buffer: [1024 * 1024]u8 = undefined;
var output_length: usize = 0;
var writer: std.Io.Writer = undefined;
var decoder: @import("terminal/input.zig").Decoder = .{};

export fn init(cols: u32, rows: u32) u32 {
    if (initialized) return resize(cols, rows);
    writer = .fixed(&output_buffer);
    demo.init(allocator, &writer, dimension(cols, 240), dimension(rows, 80)) catch return 1;
    initialized = true;
    return redraw();
}
fn dimension(value: u32, maximum: u16) u16 {
    return @intCast(@min(@max(value, 1), maximum));
}
export fn resize(cols: u32, rows: u32) u32 {
    if (!initialized) return 2;
    writer = .fixed(&output_buffer);
    demo.resize(dimension(cols, 240), dimension(rows, 80)) catch return 1;
    return redraw();
}
export fn input_ptr() usize {
    return @intFromPtr(&input_buffer);
}
export fn input_capacity() usize {
    return input_buffer.len;
}
export fn output_ptr() usize {
    return @intFromPtr(&output_buffer);
}
export fn output_len() usize {
    return output_length;
}
export fn input(length: usize) u32 {
    if (!initialized or length > input_buffer.len) return 2;
    const writable = decoder.writable() catch return 3;
    if (length > writable.len) return 3;
    @memcpy(writable[0..length], input_buffer[0..length]);
    decoder.added(length);
    while (decoder.next() catch return 3) |event| {
        switch (event) {
            .key_press => |key| demo.key(key) catch return 1,
            .mouse => |mouse| demo.mouse(mouse) catch return 1,
            else => {},
        }
    }
    return redraw();
}
fn redraw() u32 {
    writer = .fixed(&output_buffer);
    demo.draw() catch {
        output_length = 0;
        return 1;
    };
    output_length = writer.end;
    return 0;
}
