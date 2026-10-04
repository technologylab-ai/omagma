const std = @import("std");
const b = @import("bounded.zig");
const limits = @import("limits.zig");
const http = @import("http_client.zig");
const keyring = @import("keyring.zig");
const platform = @import("platform.zig");
pub const readonly_scope = "https://www.googleapis.com/auth/gmail.readonly";
pub const DesktopClient = struct {
    client_id: b.Text(4096) = .{},
    client_secret: b.Text(4096) = .{},
    pub fn wipe(self: *DesktopClient) void {
        self.client_id.wipe();
        self.client_secret.wipe();
    }
};
pub const TokenResult = struct { access_token: []const u8, expires_in: u32 };
var json_workspace: [64 * 1024]u8 align(16) = undefined;
var token_body: [limits.token_response]u8 = undefined;
var form_buffer: [32 * 1024]u8 = undefined;
var desktop_body: [16 * 1024]u8 = undefined;

pub fn loadDesktop(io: std.Io, path: []const u8, desktop: *DesktopClient) !void {
    defer std.crypto.secureZero(u8, &desktop_body);
    const data = try std.Io.Dir.cwd().readFile(io, path, &desktop_body);
    if (data.len == desktop_body.len) return error.DesktopClientTooLarge;
    try parseDesktop(data, desktop);
}
pub fn parseDesktop(data: []const u8, desktop: *DesktopClient) !void {
    if (data.len > desktop_body.len) return error.DesktopClientTooLarge;
    desktop.wipe();
    errdefer desktop.wipe();
    var fixed = std.heap.FixedBufferAllocator.init(&json_workspace);
    defer std.crypto.secureZero(u8, json_workspace[0..fixed.end_index]);
    const parsed = try b.parse(fixed.allocator(), data);
    defer parsed.deinit();
    const installed = try b.field(parsed.value, "installed");
    const id = try b.string(try b.field(installed, "client_id"));
    if (!std.mem.endsWith(u8, id, ".apps.googleusercontent.com")) return error.InvalidDesktopClient;
    try tokenValid(id);
    try desktop.client_id.set(id);
    const secret = try b.string(try b.field(installed, "client_secret"));
    try tokenValid(secret);
    try desktop.client_secret.set(secret);
    if (b.optional(installed, "auth_uri")) |v| if (!std.mem.eql(u8, try b.string(v), "https://accounts.google.com/o/oauth2/auth")) return error.InvalidDesktopClient;
    if (b.optional(installed, "token_uri")) |v| if (!std.mem.eql(u8, try b.string(v), "https://oauth2.googleapis.com/token")) return error.InvalidDesktopClient;
}
fn tokenValid(t: []const u8) !void {
    if (t.len == 0 or t.len > limits.secret) return error.InvalidToken;
    for (t) |c| if (c <= 32 or c >= 127) return error.InvalidToken;
}
pub fn pkceChallenge(verifier: []const u8, output: *[43]u8) void {
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(output, &digest);
}
pub fn percent(w: *std.Io.Writer, text: []const u8) !void {
    const digits = "0123456789ABCDEF";
    for (text) |c| if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try w.writeByte(c) else {
        const enc = [_]u8{ '%', digits[c >> 4], digits[c & 15] };
        try w.writeAll(&enc);
    };
}
fn formField(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    if (w.buffered().len != 0) try w.writeByte('&');
    try w.writeAll(name);
    try w.writeByte('=');
    try percent(w, value);
}
pub fn refresh(io: std.Io, client: *http.Client, desktop: *const DesktopClient, refresh_token: []const u8, out_access: []u8) !TokenResult {
    _ = io;
    try tokenValid(refresh_token);
    var form = std.Io.Writer.fixed(&form_buffer);
    defer std.crypto.secureZero(u8, &form_buffer);
    defer std.crypto.secureZero(u8, &token_body);
    try formField(&form, "client_id", desktop.client_id.slice());
    try formField(&form, "client_secret", desktop.client_secret.slice());
    try formField(&form, "refresh_token", refresh_token);
    try formField(&form, "grant_type", "refresh_token");
    const response = try client.request("https://oauth2.googleapis.com/token", .POST, null, form.buffered(), &token_body);
    return try parseTokens(response.status, response.body, out_access, null);
}
pub fn parseTokens(status: u16, data: []const u8, out_access: []u8, out_refresh: ?[]u8) !TokenResult {
    if (data.len > limits.token_response) return error.TokenResponseTooLarge;
    if (out_access.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out_access);
    if (out_refresh) |out| {
        std.crypto.secureZero(u8, out);
    }
    errdefer if (out_refresh) |out| {
        std.crypto.secureZero(u8, out);
    };
    var fixed = std.heap.FixedBufferAllocator.init(&json_workspace);
    defer std.crypto.secureZero(u8, json_workspace[0..fixed.end_index]);
    const parsed = try b.parse(fixed.allocator(), data);
    defer parsed.deinit();
    if (status != 200) {
        if (b.optional(parsed.value, "error")) |v| if (v == .string and std.mem.eql(u8, v.string, "invalid_grant")) return error.InvalidGrant;
        return error.TokenExchangeFailed;
    }
    if (!std.ascii.eqlIgnoreCase(try b.string(try b.field(parsed.value, "token_type")), "Bearer")) return error.InvalidTokenType;
    const access = try b.string(try b.field(parsed.value, "access_token"));
    try tokenValid(access);
    if (access.len > out_access.len) return error.TokenTooLarge;
    const expires = try b.integer(try b.field(parsed.value, "expires_in"));
    if (expires <= 0 or expires > 86400) return error.InvalidTokenExpiry;
    if (b.optional(parsed.value, "scope")) |scope| {
        var parts = std.mem.tokenizeScalar(u8, try b.string(scope), ' ');
        var count: usize = 0;
        while (parts.next()) |part| {
            if (!std.mem.eql(u8, part, readonly_scope)) return error.UnexpectedScope;
            count += 1;
        }
        if (count != 1) return error.UnexpectedScope;
    }
    if (out_refresh) |out| {
        const refresh_token = try b.string(b.optional(parsed.value, "refresh_token") orelse return error.MissingRefreshToken);
        try tokenValid(refresh_token);
        if (refresh_token.len > out.len) return error.TokenTooLarge;
        @memcpy(out[0..refresh_token.len], refresh_token);
        if (out.len > refresh_token.len) @memset(out[refresh_token.len..], 0);
    }
    std.crypto.secureZero(u8, out_access);
    @memcpy(out_access[0..access.len], access);
    return .{ .access_token = out_access[0..access.len], .expires_in = @intCast(expires) };
}
pub fn verifyIdentity(data: []const u8, expected: []const u8) !void {
    try b.address(expected);
    if (data.len > limits.token_response) return error.ProfileResponseTooLarge;
    var fixed = std.heap.FixedBufferAllocator.init(&json_workspace);
    defer std.crypto.secureZero(u8, json_workspace[0..fixed.end_index]);
    const parsed = try b.parse(fixed.allocator(), data);
    defer parsed.deinit();
    const address = try b.string(try b.field(parsed.value, "emailAddress"));
    try b.address(address);
    if (!std.ascii.eqlIgnoreCase(expected, address)) return error.WrongAccount;
}

pub fn verifyProfile(status: u16, data: []const u8, expected: []const u8) !void {
    switch (status) {
        200 => try verifyIdentity(data, expected),
        401 => return error.ProfileUnauthenticated,
        403 => return error.ProfileAccessDenied,
        429 => return error.ProfileRateLimited,
        500...599 => return error.ProfileTransientFailure,
        else => return error.ProfileVerificationFailed,
    }
}

pub const Callback = struct {
    expected_state: []const u8,
    completed: bool = false,
    pub fn parse(self: *Callback, head: []const u8, code: []u8) ![]const u8 {
        if (self.completed) return error.DuplicateCallback;
        if (head.len > 8192) return error.CallbackHeadersTooLarge;
        if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return error.InvalidCallback;
        const first_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.InvalidCallback;
        var parts = std.mem.splitScalar(u8, head[0..first_end], ' ');
        if (!std.mem.eql(u8, parts.next() orelse "", "GET")) return error.InvalidCallbackMethod;
        const target = parts.next() orelse return error.InvalidCallback;
        const version = parts.next() orelse return error.InvalidCallback;
        if (parts.next() != null or (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0"))) return error.InvalidCallback;
        if (target.len > 4096) return error.CallbackTargetTooLarge;
        if (std.mem.indexOfScalar(u8, target, '#') != null) return error.InvalidCallback;
        const query_at = std.mem.indexOfScalar(u8, target, '?') orelse return error.InvalidCallback;
        if (!std.mem.eql(u8, target[0..query_at], "/oauth2/callback")) return error.InvalidCallbackPath;
        var headers = std.mem.splitSequence(u8, head[first_end + 2 ..], "\r\n");
        while (headers.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidCallback;
            if (colon == 0) return error.InvalidCallback;
            for (line[0..colon]) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidCallback;
            for (line[colon + 1 ..]) |c| if ((c < 32 and c != '\t') or c == 127) return error.InvalidCallback;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) return error.InvalidCallback;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length") and !std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), "0")) return error.InvalidCallback;
        }
        var seen_keys: [16][128]u8 = undefined;
        var seen_len: [16]usize = undefined;
        var count: usize = 0;
        var pairs = std.mem.splitScalar(u8, target[query_at + 1 ..], '&');
        var state: [128]u8 = @splat(0);
        var state_len: ?usize = null;
        var code_len: ?usize = null;
        var callback_error: [128]u8 = undefined;
        var error_len: ?usize = null;
        while (pairs.next()) |pair| {
            if (count == 16 or pair.len == 0) return error.InvalidCallback;
            const eql = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidCallback;
            const key_len = try decode(pair[0..eql], &seen_keys[count]);
            const key = seen_keys[count][0..key_len];
            for (0..count) |i| if (std.mem.eql(u8, key, seen_keys[i][0..seen_len[i]])) return error.AmbiguousCallback;
            seen_len[count] = key_len;
            count += 1;
            const value = pair[eql + 1 ..];
            if (std.mem.eql(u8, key, "state")) state_len = try decode(value, &state) else if (std.mem.eql(u8, key, "code")) code_len = try decode(value, code) else if (std.mem.eql(u8, key, "error")) error_len = try decode(value, &callback_error) else {
                var ignored: [4096]u8 = undefined;
                _ = try decode(value, &ignored);
            }
        }
        const slen = state_len orelse return error.MissingState;
        if (slen != self.expected_state.len or self.expected_state.len > 128) return error.StateMismatch;
        var expected: [128]u8 = @splat(0);
        @memcpy(expected[0..self.expected_state.len], self.expected_state);
        if (!std.crypto.timing_safe.eql([128]u8, state, expected)) return error.StateMismatch;
        if (error_len != null) {
            if (code_len != null) return error.AmbiguousCallback;
            self.completed = true;
            if (std.mem.eql(u8, callback_error[0..error_len.?], "access_denied")) return error.AuthorizationDenied;
            return error.AuthorizationFailed;
        }
        const n = code_len orelse return error.MissingCode;
        if (n == 0) return error.MissingCode;
        self.completed = true;
        return code[0..n];
    }
};
fn decode(raw: []const u8, out: []u8) !usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (n == out.len) return error.CallbackValueTooLarge;
        const c = if (raw[i] == '%') blk: {
            if (i + 2 >= raw.len) return error.InvalidEscape;
            const decoded = std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16) catch return error.InvalidEscape;
            i += 2;
            break :blk decoded;
        } else if (raw[i] == '+') ' ' else raw[i];
        if (c < 32 or c == 127) return error.InvalidCallback;
        out[n] = c;
        n += 1;
    }
    return n;
}

var auth_access: [limits.secret]u8 = undefined;
var auth_refresh: [limits.secret]u8 = undefined;
var auth_code: [4096]u8 = undefined;
var auth_url: [8192]u8 = undefined;
var auth_header: [8192]u8 = undefined;
var auth_desktop: DesktopClient = .{};

pub fn authorize(io: std.Io, client_file: []const u8, address: []const u8, profile: []const u8, chrome: []const u8) !void {
    try b.address(address);
    try b.profile(profile);
    defer {
        auth_desktop.wipe();
        std.crypto.secureZero(u8, &auth_access);
        std.crypto.secureZero(u8, &auth_refresh);
        std.crypto.secureZero(u8, &auth_code);
        std.crypto.secureZero(u8, &auth_url);
        std.crypto.secureZero(u8, &auth_header);
        std.crypto.secureZero(u8, &form_buffer);
        std.crypto.secureZero(u8, &token_body);
    }
    try loadDesktop(io, client_file, &auth_desktop);
    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
    var listener_closed = false;
    defer if (!listener_closed) listener.deinit(io);
    var redirect_storage: [128]u8 = undefined;
    const redirect = try std.fmt.bufPrint(&redirect_storage, "http://127.0.0.1:{d}/oauth2/callback", .{listener.socket.address.getPort()});
    var random: [32]u8 = undefined;
    var verifier: [43]u8 = undefined;
    var state: [43]u8 = undefined;
    var challenge: [43]u8 = undefined;
    defer {
        std.crypto.secureZero(u8, &random);
        std.crypto.secureZero(u8, &verifier);
        std.crypto.secureZero(u8, &state);
    }
    try io.randomSecure(&random);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &random);
    pkceChallenge(&verifier, &challenge);
    try io.randomSecure(&random);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&state, &random);
    var url = std.Io.Writer.fixed(&auth_url);
    try url.writeAll("https://accounts.google.com/o/oauth2/v2/auth?");
    // formField counts the URL prefix, so write the first field explicitly.
    try url.writeAll("client_id=");
    try percent(&url, auth_desktop.client_id.slice());
    try formField(&url, "redirect_uri", redirect);
    try formField(&url, "response_type", "code");
    try formField(&url, "scope", readonly_scope);
    try formField(&url, "code_challenge", &challenge);
    try formField(&url, "code_challenge_method", "S256");
    try formField(&url, "state", &state);
    try formField(&url, "access_type", "offline");
    try formField(&url, "prompt", "consent");
    try formField(&url, "login_hint", address);
    var profile_arg: [160]u8 = undefined;
    const arg = try std.fmt.bufPrint(&profile_arg, "--profile-directory={s}", .{profile});
    try platform.launchDetached(io, &.{ chrome, arg, url.buffered() });
    var callback: Callback = .{ .expected_state = &state };
    const code = try platform.deadline(io, platform.seconds(limits.auth_seconds), acceptCallback, .{ io, &listener, &callback });
    listener.deinit(io);
    listener_closed = true;
    var client = try http.Client.init(io);
    defer client.deinit();
    var form = std.Io.Writer.fixed(&form_buffer);
    try formField(&form, "client_id", auth_desktop.client_id.slice());
    try formField(&form, "client_secret", auth_desktop.client_secret.slice());
    try formField(&form, "code", code);
    try formField(&form, "code_verifier", &verifier);
    try formField(&form, "redirect_uri", redirect);
    try formField(&form, "grant_type", "authorization_code");
    const token_response = try client.request("https://oauth2.googleapis.com/token", .POST, null, form.buffered(), &token_body);
    const tokens = try parseTokens(token_response.status, token_response.body, &auth_access, &auth_refresh);
    const identity = try client.request("https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress", .GET, tokens.access_token, null, &token_body);
    try verifyProfile(identity.status, identity.body, address);
    const refresh_token = std.mem.sliceTo(&auth_refresh, 0);
    try keyring.store(io, address, refresh_token);
}
fn acceptCallback(io: std.Io, listener: *std.Io.net.Server, callback: *Callback) anyerror![]const u8 {
    for (0..2) |_| {
        const stream = try listener.accept(io);
        defer stream.close(io);
        const code = platform.deadline(io, platform.seconds(10), connectionCallback, .{ io, stream, callback }) catch |err| {
            if (err == error.AuthorizationDenied or err == error.AuthorizationFailed or err == error.Canceled) return err;
            continue;
        };
        return code;
    }
    return error.CallbackConnectionsExhausted;
}
fn connectionCallback(io: std.Io, stream: std.Io.net.Stream, callback: *Callback) anyerror![]const u8 {
    var read_buffer: [1024]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);
    var size: usize = 0;
    while (size < auth_header.len) {
        auth_header[size] = try reader.interface.takeByte();
        size += 1;
        if (size >= 4 and std.mem.eql(u8, auth_header[size - 4 .. size], "\r\n\r\n")) break;
    }
    const parsed = callback.parse(auth_header[0..size], &auth_code);
    var writer = std.Io.net.Stream.Writer.init(stream, io, &.{});
    const page = if (parsed) |_| "Authorization received. You can close this tab." else |_| "Authorization callback rejected. Return to the terminal.";
    try writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ if (parsed) |_| "200 OK" else |_| "400 Bad Request", page.len, page });
    try writer.interface.flush();
    return parsed;
}

test "PKCE S256 published vector" {
    var result: [43]u8 = undefined;
    pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", &result);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &result);
}
test "profile verification requires HTTP success and matching identity" {
    const body = "{\"emailAddress\":\"expected@example.invalid\"}";
    try verifyProfile(200, body, "expected@example.invalid");
    try std.testing.expectError(error.WrongAccount, verifyProfile(200, body, "other@example.invalid"));
    try std.testing.expectError(error.ProfileUnauthenticated, verifyProfile(401, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileAccessDenied, verifyProfile(403, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileRateLimited, verifyProfile(429, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileTransientFailure, verifyProfile(503, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileVerificationFailed, verifyProfile(404, body, "expected@example.invalid"));
}
test "callback state, method, ambiguity and one-time completion" {
    var callback: Callback = .{ .expected_state = "expected" };
    var code: [128]u8 = undefined;
    try std.testing.expectError(error.StateMismatch, callback.parse("GET /oauth2/callback?code=secret&state=wrong HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallbackMethod, callback.parse("POST /oauth2/callback?code=secret&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.AmbiguousCallback, callback.parse("GET /oauth2/callback?code=secret&state=expected&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectEqualStrings("example/code", try callback.parse("GET /oauth2/callback?code=example%2Fcode&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.DuplicateCallback, callback.parse("GET /oauth2/callback?code=secret&state=expected HTTP/1.1\r\n\r\n", &code));
}
test "cancelled callback and unsafe queries" {
    var callback: Callback = .{ .expected_state = "expected" };
    var code: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidEscape, callback.parse("GET /oauth2/callback?code=%GG&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.AuthorizationDenied, callback.parse("GET /oauth2/callback?error=access_denied&state=expected HTTP/1.1\r\n\r\n", &code));
}
test "token parsing absent refresh revoked grant and account identity" {
    var access: [limits.secret]u8 = undefined;
    var refresh_token: [limits.secret]u8 = undefined;
    try std.testing.expectError(error.MissingRefreshToken, parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600}", &access, &refresh_token));
    try std.testing.expectError(error.InvalidGrant, parseTokens(400, "{\"error\":\"invalid_grant\"}", &access, null));
    try std.testing.expectError(error.WrongAccount, verifyIdentity("{\"emailAddress\":\"other@example.invalid\"}", "expected@example.invalid"));
    const result = try parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"synthetic-refresh\"}", &access, &refresh_token);
    try std.testing.expectEqualStrings("synthetic", result.access_token);
}

/// Synthetic listener lifecycle verification. No browser or Google requests.
pub fn callbackProbe(io: std.Io) !void {
    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const short: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) };
    {
        var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
        const address = listener.socket.address;
        var callback: Callback = .{ .expected_state = "synthetic-state" };
        try std.testing.expectError(error.Timeout, platform.deadline(io, short, acceptCallback, .{ io, &listener, &callback }));
        listener.deinit(io);
        try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    }
    {
        var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
        defer listener.deinit(io);
        var callback: Callback = .{ .expected_state = "synthetic-state" };
        var future = try io.concurrent(callbackWithTimeout, .{ io, short, &listener, &callback });
        defer _ = future.cancel(io) catch "";
        const stalled = try listener.socket.address.connect(io, .{ .mode = .stream });
        defer stalled.close(io);
        try std.testing.expectError(error.Timeout, future.await(io));
    }
    {
        var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
        const address = listener.socket.address;
        var callback: Callback = .{ .expected_state = "synthetic-state" };
        var future = try io.concurrent(callbackWithTimeout, .{ io, platform.seconds(2), &listener, &callback });
        defer _ = future.cancel(io) catch "";
        try syntheticCallback(io, address, "GET /oauth2/callback?code=synthetic-code&state=wrong HTTP/1.1\r\nHost: localhost\r\n\r\n", 400);
        try syntheticCallback(io, address, "GET /oauth2/callback?code=synthetic-code&state=synthetic-state HTTP/1.1\r\nHost: localhost\r\n\r\n", 200);
        const result = try future.await(io);
        try std.testing.expectEqualStrings("synthetic-code", result);
        listener.deinit(io);
        try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    }
    std.crypto.secureZero(u8, &auth_header);
    std.crypto.secureZero(u8, &auth_code);
}
fn callbackWithTimeout(io: std.Io, duration: std.Io.Clock.Duration, listener: *std.Io.net.Server, callback: *Callback) anyerror![]const u8 {
    return try platform.deadline(io, duration, acceptCallback, .{ io, listener, callback });
}
fn syntheticCallback(io: std.Io, address: std.Io.net.IpAddress, head: []const u8, expected_status: u16) !void {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer = std.Io.net.Stream.Writer.init(stream, io, &.{});
    try writer.interface.writeAll(head);
    try writer.interface.flush();
    var buffer: [1024]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &buffer);
    const first = (try reader.interface.takeDelimiter('\n')) orelse return error.EmptyCallbackResponse;
    var expected: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&expected, "HTTP/1.1 {d} ", .{expected_status});
    if (!std.mem.startsWith(u8, first, prefix)) return error.UnexpectedCallbackStatus;
    // Read the bounded reply through EOF before closing the client. Closing
    // after only the status line can reset a still-writing server connection,
    // turning a valid callback into a harness-induced response-write failure.
    var remainder: [1024]u8 = undefined;
    const remaining = try reader.interface.readSliceShort(&remainder);
    if (remaining == remainder.len) return error.CallbackResponseTooLarge;
}

// Static reservations exclude caller-provided tokens and response storage.
pub const reservation_bytes = @sizeOf(@TypeOf(json_workspace)) + @sizeOf(@TypeOf(token_body)) + @sizeOf(@TypeOf(form_buffer)) + @sizeOf(@TypeOf(desktop_body)) + @sizeOf(@TypeOf(auth_access)) + @sizeOf(@TypeOf(auth_refresh)) + @sizeOf(@TypeOf(auth_code)) + @sizeOf(@TypeOf(auth_url)) + @sizeOf(@TypeOf(auth_header)) + @sizeOf(DesktopClient) + 64;

test "desktop client and token scope/capacity failures are explicit" {
    var desktop: DesktopClient = .{};
    defer desktop.wipe();
    try parseDesktop("{\"installed\":{\"client_id\":\"synthetic.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret\",\"token_uri\":\"https://oauth2.googleapis.com/token\"}}", &desktop);
    try std.testing.expectError(error.MissingField, parseDesktop("{\"web\":{\"client_id\":\"synthetic.apps.googleusercontent.com\"}}", &desktop));
    try std.testing.expectError(error.InvalidDesktopClient, parseDesktop("{\"installed\":{\"client_id\":\"synthetic.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret\",\"token_uri\":\"https://attacker.invalid/token\"}}", &desktop));
    var access: [32]u8 = @splat('x');
    try std.testing.expectError(error.UnexpectedScope, parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.modify\"}", &access, null));
    try std.testing.expectEqual(@as(u8, 0), access[0]);
    _ = try parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600}", &access, null);
    try std.testing.expectEqual(@as(u8, 0), access[31]);
    try std.testing.expectError(error.DuplicateField, parseTokens(200, "{\"access_token\":\"a\",\"access_token\":\"b\"}", &access, null));
    var oversized: [limits.token_response + 1]u8 = @splat(' ');
    try std.testing.expectError(error.TokenResponseTooLarge, parseTokens(200, &oversized, &access, null));
}
test "callback rejects encoded duplicate keys controls and wrong path" {
    var callback: Callback = .{ .expected_state = "expected" };
    var code: [128]u8 = undefined;
    try std.testing.expectError(error.AmbiguousCallback, callback.parse("GET /oauth2/callback?code=synthetic&state=expected&%73tate=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallback, callback.parse("GET /oauth2/callback?code=%00&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallbackPath, callback.parse("GET /other?code=synthetic&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallback, callback.parse("GET /oauth2/callback?code=synthetic&state=expected HTTP/1.1\r\nContent-Length: 1\r\n\r\n", &code));
}
