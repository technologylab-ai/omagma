//! Credential-free wire acceptance through the production Meet HTTP policy.
const std = @import("std");
const builtin = @import("builtin");
const http = @import("http_client.zig");
const p = @import("terminal/meet_notes_provider.zig");
pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const origin = args.next() orelse return error.UrlRequired;
    const mode = args.next() orelse return error.ModeRequired;
    const request = if (std.mem.eql(u8, mode, "get")) try p.read(init.gpa, "self@example.test", "spaces/FictionalSpace") else try p.configure(init.gpa, "self@example.test", "spaces/FictionalSpace", true);
    const destination = try std.fmt.allocPrint(init.gpa, "{s}{s}", .{ origin, request.url["https://meet.googleapis.com".len..] });
    var client = try http.Client.init(init.io);
    defer client.deinit();
    var out: [p.max_response_bytes]u8 = undefined;
    var failure: []const u8 = "";
    const response = client.requestLoopbackMeetProbe(destination, request.method, request.body, &out) catch |err| blk: {
        failure = @errorName(err);
        break :blk @as(?http.Response, null);
    };
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .status = if (response) |r| r.status else @as(u16, 0), .errorCode = failure, .zigVersion = builtin.zig_version_string, .optimizeMode = @tagName(builtin.mode) }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
