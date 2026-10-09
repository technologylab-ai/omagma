//! Bounded byte sources and a counting writer shared by MIME and terminal HTTP.
const std = @import("std");
pub const Source = struct {
    ctx: *anyopaque,
    readFn: *const fn (*anyopaque, []u8) anyerror!usize,
    pub fn read(self: Source, buffer: []u8) !usize {
        const count = try self.readFn(self.ctx, buffer);
        if (count > buffer.len) return error.InvalidStreamRead;
        return count;
    }
};
pub const LimitedWriter = struct {
    interface: std.Io.Writer,
    sink: *std.Io.Writer,
    limit: usize,
    written: usize = 0,
    exceeded: bool = false,
    pub fn init(sink: *std.Io.Writer, limit: usize) LimitedWriter {
        return .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .sink = sink, .limit = limit };
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedWriter = @fieldParentPtr("interface", writer);
        var wanted: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            if (part.len > self.limit -| self.written -| wanted) return self.tooLarge();
            wanted += part.len;
        }
        const last = data[data.len - 1];
        if (last.len > 0 and splat > (self.limit -| self.written -| wanted) / last.len) return self.tooLarge();
        wanted += last.len * splat;
        for (data[0 .. data.len - 1]) |part| try self.sink.writeAll(part);
        if (last.len > 0) for (0..splat) |_| try self.sink.writeAll(last);
        self.written += wanted;
        return wanted;
    }
    fn tooLarge(self: *LimitedWriter) std.Io.Writer.Error {
        self.exceeded = true;
        return error.WriteFailed;
    }
};
test "byte stream: writer refuses oversized vectors before emitting their bytes" {
    var output: [16]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    var limited: LimitedWriter = .init(&sink, 8);
    try limited.interface.writeAll("1234");
    try std.testing.expectError(error.WriteFailed, limited.interface.writeAll("56789"));
    try std.testing.expect(limited.exceeded);
    try std.testing.expectEqual(@as(usize, 4), limited.written);
    try std.testing.expectEqualStrings("1234", sink.buffered());
}
