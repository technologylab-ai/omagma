//! Active Omagma callback parser/storage probe; no historical HTTP engine.
const std = @import("std");
const builtin = @import("builtin");
const oauth = @import("oauth");

pub fn main(init: std.process.Init) !void {
    var code: [128]u8 = undefined;
    defer std.crypto.secureZero(u8, &code);
    var callback: oauth.Callback = .{ .expected_state = "fixture-state" };
    const head = "GET /oauth2/callback?code=fixture%2Fcode&state=fixture-state HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqualStrings("fixture/code", try callback.parse(head, &code));
    try std.testing.expectError(error.DuplicateCallback, callback.parse(head, &code));

    callback = .{ .expected_state = "fixture-state" };
    var short: [1]u8 = undefined;
    defer std.crypto.secureZero(u8, &short);
    try std.testing.expectError(error.CallbackValueTooLarge, callback.parse(head, &short));
    try std.testing.expect(!callback.completed);
    var oversized: [8193]u8 = @splat(' ');
    try std.testing.expectError(error.CallbackHeadersTooLarge, callback.parse(&oversized, &code));

    // The listener probe uses only loopback sockets and finite deadlines.
    try oauth.callbackProbe(init.io);
    var output: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output);
    try writer.interface.print("{{\"ok\":true,\"zigVersion\":\"{s}\",\"buildMode\":\"{s}\",\"authReservationBytes\":{d},\"parserStateBytes\":{d},\"callerCodeBytes\":{d},\"loopbackLifecycleChecked\":true,\"externalServicesUsed\":false}}\n", .{
        builtin.zig_version_string, @tagName(builtin.mode), oauth.reservation_bytes,
        @sizeOf(oauth.Callback),    code.len,
    });
    try writer.interface.flush();
}
