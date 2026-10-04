const std = @import("std");
const http = @import("http_client.zig");
var output: [512 * 1024]u8 = undefined;
pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const url = args.next() orelse "https://gmail.googleapis.com/gmail/v1/users/me/profile";
    const repeats = if (args.next()) |n| try std.fmt.parseInt(usize, n, 10) else 1;
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
