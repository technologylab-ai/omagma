const std = @import("std");
const server = @import("browser_server.zig");
const assets = [_]server.Asset{
    .{ .path = "/index.html", .mime = "text/html; charset=utf-8", .bytes = "<p>synthetic</p>" },
    .{ .path = "/omagma.wasm", .mime = "application/wasm", .bytes = "\x00asm\x01\x00\x00\x00" },
    .{ .path = "/app.mjs", .mime = "text/javascript; charset=utf-8", .bytes = "export const synthetic=true;" },
};
const nonce_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const nonce_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

test "browser server: port parsing excludes zero, overflow and non-digits" {
    try std.testing.expectEqual(@as(u16, 8766), try server.parsePort("8766"));
    try std.testing.expectEqual(@as(u16, 65535), try server.parsePort("65535"));
    for ([_][]const u8{ "", "0", "65536", "-1", "+1", "4x", " 80" }) |value| try std.testing.expectError(error.InvalidPort, server.parsePort(value));
}

test "browser server: exact asset GET and HEAD routes with MIME and no disk paths" {
    const get = server.classify("GET / HTTP/1.1\r\nHost: 127.0.0.1:8766\r\n\r\n", &assets, 8766, null);
    try std.testing.expectEqual(@as(u16, 200), get.status);
    try std.testing.expectEqualStrings(assets[0].bytes, get.bytes);
    const head = server.classify("HEAD /omagma.wasm HTTP/1.1\r\nHost: localhost:8766\r\n\r\n", &assets, 8766, null);
    try std.testing.expect(head.head_only);
    try std.testing.expectEqualStrings("application/wasm", head.mime);
    try std.testing.expectEqual(@as(usize, 8), head.bytes.len);
    for ([_][]const u8{ "/../config.json", "/%2e%2e/config.json", "/foo/../index.html", "//index.html", "/config.json", "/connection.json" }) |path| {
        var buffer: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(&buffer, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{path});
        try std.testing.expectEqual(@as(u16, 404), server.classify(request, &assets, 8766, null).status);
    }
}

test "browser server: method, host, request body and ambiguous headers are rejected" {
    const post = server.classify("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 30\r\n\r\n", &assets, 8766, null);
    try std.testing.expectEqual(@as(u16, 405), post.status);
    try std.testing.expectEqualStrings("GET, HEAD", post.allow);
    try std.testing.expectEqual(@as(u16, 403), server.classify("GET / HTTP/1.1\r\nHost: attacker.invalid\r\n\r\n", &assets, 8766, null).status);
    for ([_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: localhost\r\nHost: localhost\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",
    }) |request| try std.testing.expectEqual(@as(u16, 400), server.classify(request, &assets, 8766, null).status);
}

fn syntheticLoad(_: *anyopaque, _: std.Io, out: []u8) ![]const u8 {
    const body = "{\"format\":\"omagma-browser-connection\",\"version\":1,\"accounts\":[]}";
    @memcpy(out[0..body.len], body);
    return out[0..body.len];
}

test "browser server: private bundle requires nonce, exact local host and same origin" {
    var context: u8 = 0;
    const source: server.ConnectionSource = .{ .context = &context, .nonce = nonce_a, .load = syntheticLoad };
    const valid = "GET /connection.json HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nAuthorization: Omagma-Session " ++ nonce_a ++ "\r\nOrigin: http://127.0.0.1:8766\r\n\r\n";
    try std.testing.expect(server.classify(valid, &assets, 8766, source).private);
    for ([_][]const u8{
        "GET /connection.json HTTP/1.1\r\nHost: 127.0.0.1:8766\r\n\r\n",
        "GET /connection.json HTTP/1.1\r\nHost: localhost:8766\r\nAuthorization: Omagma-Session " ++ nonce_a ++ "\r\n\r\n",
        "GET /connection.json HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nAuthorization: Omagma-Session " ++ nonce_b ++ "\r\n\r\n",
        "GET /connection.json HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nAuthorization: Omagma-Session " ++ nonce_a ++ "\r\nOrigin: https://attacker.invalid\r\n\r\n",
        "GET /connection.json?token=ignored HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nAuthorization: Omagma-Session " ++ nonce_a ++ "\r\n\r\n",
    }) |request| {
        const reply = server.classify(request, &assets, 8766, source);
        try std.testing.expectEqual(@as(u16, 403), reply.status);
        try std.testing.expect(!reply.private);
    }
    const head = server.classify("HEAD /connection.json HTTP/1.1\r\nHost: 127.0.0.1:8766\r\n\r\n", &assets, 8766, source);
    try std.testing.expectEqual(@as(u16, 405), head.status);
    try std.testing.expectEqualStrings("GET", head.allow);
}

test "browser server: occupied port advances through actual loopback binds" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var occupied = try address.listen(io, .{ .kernel_backlog = 1 });
    defer occupied.deinit(io);
    const port = occupied.socket.address.getPort();
    if (port == 65535) return;
    var chosen = try server.listen(io, port);
    defer chosen.deinit(io);
    try std.testing.expect(chosen.socket.address.getPort() > port);
}

test "browser server: upper port exhaustion does not wrap to zero" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 65535);
    var occupied = address.listen(io, .{ .kernel_backlog = 1 }) catch |err| {
        if (err == error.AddressInUse) return std.testing.expectError(error.NoAvailablePort, server.listen(io, 65535));
        return err;
    };
    defer occupied.deinit(io);
    try std.testing.expectError(error.NoAvailablePort, server.listen(io, 65535));
}
