const std = @import("std");
const builtin = @import("builtin");
const http = @import("http_client.zig");
var output: [512 * 1024]u8 = undefined;
pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const url = args.next() orelse "https://gmail.googleapis.com/gmail/v1/users/me/profile";
    if (std.mem.eql(u8, url, "build-info")) {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        try writer.interface.print("{{\"zigVersion\":\"{s}\",\"optimizeMode\":\"{s}\"}}\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });
        try writer.interface.flush();
        return;
    }
    const mode = args.next() orelse "1";
    if (std.mem.eql(u8, mode, "terminal-post") or std.mem.eql(u8, mode, "terminal-post-oversize")) {
        try terminalProbe(init, url, std.mem.eql(u8, mode, "terminal-post-oversize"));
        return;
    }
    const repeats = try std.fmt.parseInt(usize, mode, 10);
    if (repeats == 0 or repeats > 1000) return error.InvalidRepeatCount;
    const loopback = std.mem.startsWith(u8, url, "http://");
    const token_post = std.mem.eql(u8, url, "https://oauth2.googleapis.com/token");
    if (!loopback and repeats > 3) return error.LiveProbeRepeatLimit;
    var client = try http.Client.init(init.io);
    defer client.deinit();
    var first_peak: usize = 0;
    var response: http.Response = undefined;
    for (0..repeats) |i| {
        const result = if (loopback) client.requestLoopback(url, &output) else client.request(url, if (token_post) .POST else .GET, null, if (token_post) "grant_type=unsupported_feasibility_probe" else null, &output);
        response = result catch |err| {
            std.debug.print("error={s} peak={d} requests={d}\n", .{ @errorName(err), client.peakBytes(), i + 1 });
            return err;
        };
        if (i == 0) first_peak = client.peakBytes();
    }
    std.debug.print("status={d} bytes={d} retry_after={d} peak={d} first_peak={d} requests={d} rejected={d}\n", .{ response.status, response.body.len, response.retry_after, client.peakBytes(), first_peak, repeats, client.rejectedAllocations() });
    if (repeats > 1 and client.peakBytes() != first_peak) return error.WorkspaceDidNotPlateau;
}

fn terminalProbe(init: std.process.Init, url: []const u8, oversized: bool) !void {
    const storage = try init.gpa.alloc(u8, if (oversized) 3 * 1024 * 1024 + 1 else http.terminal_probe_body_bytes);
    defer init.gpa.free(storage);
    const body = if (oversized) bytes: {
        @memset(storage, 'x');
        break :bytes storage;
    } else try http.terminalProbeBody(storage);
    const response_storage = try init.gpa.alloc(u8, 3 * 1024 * 1024);
    defer init.gpa.free(response_storage);
    var client = try http.Client.init(init.io);
    defer client.deinit();
    const start = std.Io.Timestamp.now(init.io, .awake);
    var failure: ?anyerror = null;
    const response: ?http.Response = client.requestLoopbackTerminalProbe(url, body, response_storage) catch |err| failed: {
        failure = err;
        break :failed @as(?http.Response, null);
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{{\"ok\":{s},\"status\":{d},\"bodyBytes\":{d},\"httpPeakBytes\":{d},\"error\":\"{s}\",\"elapsedMs\":{d},\"zigVersion\":\"{s}\",\"optimizeMode\":\"{s}\"}}\n", .{ if (failure == null) "true" else "false", if (response) |r| r.status else @as(u16, 0), if (response) |r| r.body.len else @as(usize, 0), client.peakBytes(), if (failure) |err| @errorName(err) else "", start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toMilliseconds(), builtin.zig_version_string, @tagName(builtin.mode) });
    try writer.interface.flush();
}
