//! Credential-free loopback-only transport oracle for streamed attachments.
const std = @import("std");
const builtin = @import("builtin");
const http = @import("http_client.zig");
const Generator = struct {
    size: usize,
    offset: usize = 0,
    calls: usize = 0,
    fn read(ctx: *anyopaque, output: []u8) anyerror!usize {
        const self: *Generator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const count = @min(@min(output.len, 4093), self.size - self.offset);
        for (output[0..count], 0..) |*byte, index| byte.* = @truncate((self.offset + index) *% 31 +% 7);
        self.offset += count;
        return count;
    }
};
pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const url = args.next() orelse return error.MissingUrl;
    const mode = args.next() orelse return error.MissingMode;
    const size = try std.fmt.parseInt(usize, args.next() orelse "4194304", 10);
    if (size > http.terminal_stream_bytes + 1) return error.InvalidProbeSize;
    var client = try http.Client.init(init.io);
    defer client.deinit();
    var source: Generator = .{ .size = size };
    var hash_buffer: [4096]u8 = undefined;
    var hash: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&hash_buffer);
    var counter = @import("byte_stream.zig").LimitedWriter.init(&hash.writer, http.terminal_stream_bytes);
    var response_buffer: [16384]u8 = undefined;
    var failure: ?anyerror = null;
    const response = if (std.mem.eql(u8, mode, "upload") or std.mem.eql(u8, mode, "short-upload")) client.requestLoopbackFileProbe(url, "message/rfc822", .{ .ctx = &source, .readFn = Generator.read }, size + @intFromBool(std.mem.eql(u8, mode, "short-upload")), &response_buffer) else if (std.mem.eql(u8, mode, "download")) client.requestLoopbackDownloadProbe(url, &counter.interface, size, &response_buffer) else return error.InvalidProbeMode;
    const result: ?http.Response = response catch |err| failed: {
        failure = err;
        break :failed null;
    };
    try hash.writer.flush();
    var digest: [32]u8 = undefined;
    hash.hasher.final(&digest);
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.print("{{\"ok\":{s},\"status\":{d},\"responseBytes\":{d},\"sinkBytes\":{d},\"sourceBytes\":{d},\"sourceCalls\":{d},\"sinkSha256\":\"{s}\",\"error\":\"{s}\",\"zigVersion\":\"{s}\",\"optimizeMode\":\"{s}\"}}\n", .{ if (failure == null) "true" else "false", if (result) |r| r.status else @as(u16, 0), if (result) |r| r.bytes else @as(usize, 0), counter.written, source.offset, source.calls, std.fmt.bytesToHex(digest, .lower), if (failure) |err| @errorName(err) else "", builtin.zig_version_string, @tagName(builtin.mode) });
    try output.interface.flush();
}
