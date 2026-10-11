//! The host exchanges terminal bytes and injects an explicit session HTTP
//! transport. OAuth tokens stay in the host, outside WASM and diagnostics.
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
var busy = false;
var input_buffer: [1024]u8 = undefined;
var connect_buffer: [16 * 1024]u8 = undefined;
var output_buffer: [1024 * 1024]u8 = undefined;
var output_length: usize = 0;
var writer: std.Io.Writer = undefined;
var decoder: @import("terminal/input.zig").Decoder = .{};

export fn init(cols: u32, rows: u32) u32 {
    if (busy) return 4;
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
    if (busy) return 4;
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
    if (busy) return 4;
    if (!initialized or length > input_buffer.len) return 2;
    busy = true;
    defer busy = false;
    var offset: usize = 0;
    while (offset < length) {
        // A UTF-8 or ANSI prefix may remain from the preceding host chunk.
        // Fill only the decoder's remaining room, consume complete events,
        // then append the rest without dropping that bounded prefix.
        const writable = decoder.writable() catch return 3;
        const count = @min(length - offset, writable.len);
        @memcpy(writable[0..count], input_buffer[offset..][0..count]);
        decoder.added(count);
        offset += count;
        while (decoder.next() catch return 3) |event| {
            switch (event) {
                .key_press => |key| demo.key(key) catch |err| demo.failure(err),
                .mouse => |mouse| demo.mouse(mouse) catch |err| demo.failure(err),
                .paste_start => demo.pasteStart(),
                .paste_end => demo.pasteEnd(),
                else => {},
            }
        }
    }
    return redraw();
}
export fn connect_ptr() usize {
    return @intFromPtr(&connect_buffer);
}
export fn connect_capacity() usize {
    return connect_buffer.len;
}
export fn connect(length: usize) u32 {
    if (busy) return 4;
    if (!initialized or length > connect_buffer.len) return 2;
    busy = true;
    defer busy = false;
    demo.connect(connect_buffer[0..length]) catch |err| {
        demo.failure(err);
        _ = redraw();
        return 1;
    };
    return redraw();
}
export fn live_accounts() u32 {
    return if (initialized) @intCast(demo.live_count) else 0;
}
export fn can_send() u32 {
    return @intFromBool(initialized and demo.canSend());
}
export fn send_status() u32 {
    return if (initialized) demo.last_send_status else 0;
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
