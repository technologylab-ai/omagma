//! Bounded loopback server for immutable embedded browser assets. No disk
//! serving or Google proxy; the optional connection source is native and
//! protected by a per-launch capability supplied only in the URL fragment.
const std = @import("std");
const Io = std.Io;
const platform = @import("platform.zig");
const signal_wake = @import("signal_wake.zig");

pub const Asset = struct { path: []const u8, mime: []const u8, bytes: []const u8 };
pub const ConnectionSource = struct {
    context: *anyopaque,
    nonce: []const u8,
    load: *const fn (context: *anyopaque, io: Io, out: []u8) anyerror![]const u8,
};
pub const Options = struct { port: u16 = 8766, connection: ?ConnectionSource = null };
pub const worker_count = 4;
pub const header_limit = 8192;
pub const connection_limit = 64 * 1024;
pub const reservation_bytes = @sizeOf(@TypeOf(signal_fd)) + @sizeOf(@TypeOf(active));
var signal_fd: std.atomic.Value(i32) = .init(-1);
var active: std.atomic.Value(bool) = .init(false);

pub const Reply = struct {
    status: u16 = 200,
    bytes: []const u8,
    mime: []const u8 = "text/plain; charset=utf-8",
    head_only: bool = false,
    private: bool = false,
    allow: []const u8 = "GET, HEAD",
};

pub fn parsePort(value: []const u8) !u16 {
    if (value.len == 0) return error.InvalidPort;
    for (value) |char| if (!std.ascii.isDigit(char)) return error.InvalidPort;
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

pub fn run(io: Io, args: *std.process.Args.Iterator, assets: []const Asset) !void {
    var options: Options = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buffer: [1024]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &buffer);
            try stdout.interface.writeAll("omagma server [--port PORT]\nServe the bundled browser UI on 127.0.0.1.\nDefault port8766; occupied ports advance to the next free port.\nCtrl+C stops the server.\n");
            return stdout.interface.flush();
        }
        if (!std.mem.eql(u8, arg, "--port")) return error.UnknownOption;
        options.port = try parsePort(args.next() orelse return error.ValueRequired);
    }
    try serve(io, assets, options);
}

pub fn listen(io: Io, first_port: u16) !Io.net.Server {
    if (first_port == 0) return error.InvalidPort;
    var port = first_port;
    while (true) {
        const address = try Io.net.IpAddress.parse("127.0.0.1", port);
        return address.listen(io, .{ .kernel_backlog = 16 }) catch |err| {
            if (err != error.AddressInUse) return err;
            if (port == std.math.maxInt(u16)) return error.NoAvailablePort;
            port += 1;
            continue;
        };
    }
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const fd = signal_fd.load(.acquire);
    if (fd >= 0) signal_wake.notify(fd);
}

fn waitSignal(io: Io, file: Io.File, stopped: *Io.Event) void {
    var bytes: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    reader.interface.readSliceAll(&bytes) catch return;
    stopped.set(io);
}

fn validateAssets(assets: []const Asset) !void {
    if (assets.len == 0) return error.BrowserAssetsNotIncluded;
    if (assets.len > 32) return error.InvalidBrowserAssets;
    var total: usize = 0;
    var has_index = false;
    for (assets, 0..) |asset, index| {
        if (!safePath(asset.path) or asset.mime.len == 0 or asset.mime.len > 128 or asset.bytes.len > 16 * 1024 * 1024) return error.InvalidBrowserAssets;
        for (asset.mime) |char| if (char < 32 or char >= 127) return error.InvalidBrowserAssets;
        for (assets[0..index]) |previous| if (std.mem.eql(u8, asset.path, previous.path)) return error.InvalidBrowserAssets;
        total += asset.bytes.len;
        has_index = has_index or std.mem.eql(u8, asset.path, "/") or std.mem.eql(u8, asset.path, "/index.html");
    }
    if (!has_index or total > 32 * 1024 * 1024) return error.InvalidBrowserAssets;
}

fn validNonce(nonce: []const u8) bool {
    if (nonce.len != 64) return false;
    for (nonce) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

pub fn serve(io: Io, assets: []const Asset, options: Options) !void {
    try validateAssets(assets);
    if (options.connection) |connection| if (!validNonce(connection.nonce)) return error.InvalidServerSession;
    if (active.swap(true, .acq_rel)) return error.BrowserServerAlreadyActive;
    defer active.store(false, .release);
    var listener = try listen(io, options.port);
    defer listener.deinit(io);
    const wake = try signal_wake.Wake.init(io);
    defer wake.close(io);
    const signals = [_]std.posix.SIG{ .INT, .TERM };
    var previous: [signals.len]std.posix.Sigaction = undefined;
    signal_fd.store(wake.write_fd, .release);
    for (signals, 0..) |signal, index| {
        var action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(signal, &action, &previous[index]);
    }
    defer {
        signal_fd.store(-1, .release);
        for (signals, 0..) |signal, index| std.posix.sigaction(signal, &previous[index], null);
    }
    var stopped: Io.Event = .unset;
    var signal_task = try io.concurrent(waitSignal, .{ io, wake.read, &stopped });
    defer signal_task.cancel(io);
    var context: Context = .{ .io = io, .listener = &listener, .assets = assets, .options = options, .stopped = &stopped };
    var workers: Io.Group = .init;
    defer workers.cancel(io);
    for (0..worker_count) |_| try workers.concurrent(io, worker, .{&context});
    var output: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &output);
    try stdout.interface.print("http://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
    if (options.connection) |connection| try stdout.interface.print("#omagma-session={s}", .{connection.nonce});
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    try stopped.wait(io);
    if (context.failed.load(.acquire)) return error.BrowserServerUnavailable;
}

const Context = struct {
    io: Io,
    listener: *Io.net.Server,
    assets: []const Asset,
    options: Options,
    stopped: *Io.Event,
    failed: std.atomic.Value(bool) = .init(false),
};

fn worker(context: *Context) Io.Cancelable!void {
    while (true) {
        const stream = context.listener.accept(context.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted => continue,
            else => {
                context.failed.store(true, .release);
                context.stopped.set(context.io);
                return;
            },
        };
        defer stream.close(context.io);
        // Header arrival gets its own short deadline; a speculative idle
        // browser connection cannot reserve a worker for the private timeout.
        var header: [header_limit]u8 = undefined;
        defer std.crypto.secureZero(u8, &header);
        const count = platform.deadline(context.io, platform.seconds(5), readHead, .{ context.io, stream, &header }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        const reply = classify(header[0..count], context.assets, context.listener.socket.address.getPort(), context.options.connection);
        platform.deadline(context.io, platform.seconds(if (reply.private) 30 else 5), respond, .{ context.io, stream, reply, context.options.connection }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
        };
    }
}

fn readHead(io: Io, stream: Io.net.Stream, out: *[header_limit]u8) !usize {
    var buffer: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = Io.net.Stream.Reader.init(stream, io, &buffer);
    for (out, 0..) |*byte, index| {
        byte.* = try reader.interface.takeByte();
        if (index >= 3 and std.mem.eql(u8, out[index - 3 .. index + 1], "\r\n\r\n")) return index + 1;
    }
    return error.RequestHeaderTooLarge;
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 1024 or path[0] != '/') return false;
    for (path) |char| if (char <= 32 or char >= 127 or char == '%' or char == '\\' or char == '#' or char == '?') return false;
    if (std.mem.indexOf(u8, path, "//") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn failure(status: u16, head_only: bool) Reply {
    return .{ .status = status, .head_only = head_only, .bytes = switch (status) {
        400 => "Bad request.\n",
        403 => "This local request is not authorized.\n",
        404 => "Not found.\n",
        405 => "This method is not supported.\n",
        else => "Omagma could not load the connection.\n",
    } };
}

fn publicHost(host: []const u8, expected: []const u8) bool {
    if (std.mem.eql(u8, host, expected) or std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (!std.ascii.startsWithIgnoreCase(host, "localhost:")) return false;
    return std.mem.eql(u8, host["localhost:".len..], expected["127.0.0.1:".len..]);
}

pub fn classify(head: []const u8, assets: []const Asset, port: u16, connection: ?ConnectionSource) Reply {
    if (head.len > header_limit or !std.mem.endsWith(u8, head, "\r\n\r\n")) return failure(400, false);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    var first = std.mem.splitScalar(u8, lines.next() orelse return failure(400, false), ' ');
    const method = first.next() orelse return failure(400, false);
    const target = first.next() orelse return failure(400, false);
    const version = first.next() orelse return failure(400, false);
    const is_head = std.mem.eql(u8, method, "HEAD");
    if (first.next() != null or (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0"))) return failure(400, is_head);
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..query];
    if (!safePath(path) or target.len > 1024) return failure(404, is_head);
    const is_private = std.mem.eql(u8, path, "/connection.json");
    if (!std.mem.eql(u8, method, "GET") and !is_head) {
        var reply = failure(405, false);
        if (is_private) reply.allow = "GET";
        return reply;
    }
    var host: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var authorization: ?[]const u8 = null;
    var length_seen = false;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        for (line) |char| if ((char < 32 and char != '\t') or char >= 127) return failure(400, is_head);
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return failure(400, is_head);
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Host")) {
            if (host != null) return failure(400, is_head);
            host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "Origin")) {
            if (origin != null) return failure(400, is_head);
            origin = value;
        } else if (std.ascii.eqlIgnoreCase(name, "Authorization")) {
            if (authorization != null) return failure(400, is_head);
            authorization = value;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) return failure(400, is_head) else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length_seen or !std.mem.eql(u8, value, "0")) return failure(400, is_head);
            length_seen = true;
        }
    }
    var expected_host_buffer: [32]u8 = undefined;
    const expected_host = std.fmt.bufPrint(&expected_host_buffer, "127.0.0.1:{d}", .{port}) catch unreachable;
    if (host) |value| {
        if (!publicHost(value, expected_host)) return failure(403, is_head);
    } else if (std.mem.eql(u8, version, "HTTP/1.1")) return failure(400, is_head);
    if (is_private) {
        const source = connection orelse return failure(404, is_head);
        if (is_head) {
            var reply = failure(405, true);
            reply.allow = "GET";
            return reply;
        }
        if (query != target.len or host == null or !std.mem.eql(u8, host.?, expected_host)) return failure(403, false);
        if (origin) |value| {
            var expected_origin_buffer: [64]u8 = undefined;
            const expected_origin = std.fmt.bufPrint(&expected_origin_buffer, "http://{s}", .{expected_host}) catch unreachable;
            if (!std.mem.eql(u8, value, expected_origin)) return failure(403, false);
        }
        const supplied = authorization orelse return failure(403, false);
        const prefix = "Omagma-Session ";
        if (!std.mem.startsWith(u8, supplied, prefix) or supplied.len != prefix.len + source.nonce.len) return failure(403, false);
        var difference: u8 = 0;
        for (supplied[prefix.len..], source.nonce) |left, right| difference |= left ^ right;
        if (difference != 0) return failure(403, false);
        return .{ .bytes = "", .mime = "application/json; charset=utf-8", .private = true };
    }
    for (assets) |asset| if (std.mem.eql(u8, asset.path, path) or (std.mem.eql(u8, path, "/") and std.mem.eql(u8, asset.path, "/index.html"))) return .{ .bytes = asset.bytes, .mime = asset.mime, .head_only = is_head };
    return failure(404, is_head);
}

fn respond(io: Io, stream: Io.net.Stream, initial: Reply, connection: ?ConnectionSource) !void {
    var reply = initial;
    var private_buffer: [connection_limit]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_buffer);
    if (reply.private) {
        const source = connection orelse return error.InvalidServerSession;
        const body = source.load(source.context, io, &private_buffer) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            try writeReply(io, stream, failure(503, false));
            return;
        };
        if (body.len == 0 or body.len > private_buffer.len or @intFromPtr(body.ptr) < @intFromPtr(&private_buffer) or @intFromPtr(body.ptr) - @intFromPtr(&private_buffer) > private_buffer.len - body.len) return writeReply(io, stream, failure(503, false));
        reply.bytes = body;
    }
    try writeReply(io, stream, reply);
}

fn writeReply(io: Io, stream: Io.net.Stream, reply: Reply) !void {
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var writer = Io.net.Stream.Writer.init(stream, io, &buffer);
    const reason = switch (reply.status) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        else => "Service Unavailable",
    };
    try writer.interface.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\nX-Frame-Options: DENY\r\n", .{ reply.status, reason, reply.mime, reply.bytes.len });
    if (reply.status == 405) try writer.interface.print("Allow: {s}\r\n", .{reply.allow});
    try writer.interface.writeAll("\r\n");
    if (!reply.head_only) try writer.interface.writeAll(reply.bytes);
    try writer.interface.flush();
}
