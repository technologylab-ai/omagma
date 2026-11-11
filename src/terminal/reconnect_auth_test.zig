//! Reconnect through the real terminal authorization: loopback listener,
//! PKCE, state, a test-only consent page and a loopback token/profile oracle
//! behind the unit-test HTTP route. No browser, Google traffic or credentials.
const std = @import("std");
const auth = @import("auth.zig");
const auth_diagnostic = @import("auth_diagnostic.zig");
const oauth = @import("../oauth.zig");
const http = @import("../http_client.zig");
const native = @import("../native_identity.zig");
const platform = @import("../platform.zig");
const Config = @import("../config.zig").Config;
const j = @import("json.zig");
const io = std.testing.io;
const account = "self@example.test";
const client_id = "synthetic-reconnect.apps.googleusercontent.com";
const client_json = "{\"installed\":{\"client_id\":\"synthetic-reconnect.apps.googleusercontent.com\",\"client_secret\":\"synthetic-reconnect-secret\"}}";
const recorded = [_][]const u8{ "mail-read", "mail-send", "contacts-read", "calendar-read" };
const fresh_refresh = "synthetic-renewed-refresh";

/// Decoded query parameter of the consent URL (bounded test helper).
fn param(url: []const u8, name: []const u8, out: []u8) ![]const u8 {
    const query = url[(std.mem.indexOfScalar(u8, url, '?') orelse return error.MissingQuery) + 1 ..];
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eql = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eql], name)) continue;
        const raw = pair[eql + 1 ..];
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '%') {
                out[n] = try std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16);
                i += 2;
            } else out[n] = raw[i];
            n += 1;
        }
        return out[0..n];
    }
    return error.MissingParameter;
}

const Behaviour = enum { approve, deny, ignore, fixture_self, fixture_other, fixture_bad_pkce };
/// The synthetic consent page. It records what Google would see and answers
/// on a concurrent task, as a browser's later redirect would.
const Consent = struct {
    var behaviour: Behaviour = .approve;
    var opened: usize = 0;
    var challenge: [43]u8 = @splat(0);
    var scope: [512]u8 = undefined;
    var scope_len: usize = 0;
    var client: [128]u8 = undefined;
    var client_len: usize = 0;
    var pending: ?std.Io.Future(anyerror!void) = null;
    fn reset(choice: Behaviour) void {
        behaviour = choice;
        opened = 0;
        pending = null;
        oauth.TestBrowser.open = open;
    }
    fn finish() !void {
        oauth.TestBrowser.open = null;
        if (pending) |owned| {
            var future = owned;
            pending = null;
            try future.await(io);
        }
    }
    fn open(_: std.Io, url: []const u8) anyerror!void {
        opened += 1;
        var storage: [6][512]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, url, "https://accounts.google.com/o/oauth2/v2/auth?client_id="));
        try std.testing.expectEqualStrings("consent", try param(url, "prompt", &storage[0]));
        try std.testing.expectEqualStrings("offline", try param(url, "access_type", &storage[0]));
        try std.testing.expectEqualStrings("S256", try param(url, "code_challenge_method", &storage[0]));
        try std.testing.expectEqualStrings(account, try param(url, "login_hint", &storage[0]));
        // The verifier never reaches the consent URL; only its challenge does.
        try std.testing.expect(std.mem.indexOf(u8, url, "code_verifier") == null);
        const found_scope = try param(url, "scope", &storage[1]);
        @memcpy(scope[0..found_scope.len], found_scope);
        scope_len = found_scope.len;
        const found_client = try param(url, "client_id", &storage[2]);
        @memcpy(client[0..found_client.len], found_client);
        client_len = found_client.len;
        const found_challenge = try param(url, "code_challenge", &storage[3]);
        try std.testing.expectEqual(@as(usize, 43), found_challenge.len);
        @memcpy(&challenge, found_challenge);
        const redirect = try param(url, "redirect_uri", &storage[4]);
        const state = try param(url, "state", &storage[5]);
        const prefix = "http://127.0.0.1:";
        try std.testing.expect(std.mem.startsWith(u8, redirect, prefix));
        const port = try std.fmt.parseInt(u16, redirect[prefix.len..std.mem.indexOfScalarPos(u8, redirect, prefix.len, '/').?], 10);
        if (behaviour == .ignore) return;
        var head: [1024]u8 = undefined;
        var identity: [128]u8 = undefined;
        const code = switch (behaviour) {
            .approve => "synthetic-code",
            .fixture_self, .fixture_other, .fixture_bad_pkce => blk: {
                const who = if (behaviour == .fixture_other) "other@example.test" else account;
                const encoded = std.base64.url_safe_no_pad.Encoder.encode(&identity, who);
                if (behaviour == .fixture_bad_pkce) challenge[0] ^= 1;
                break :blk try std.fmt.bufPrint(&storage[0], "fixture.{s}.{s}", .{ &challenge, encoded });
            },
            else => "",
        };
        const request = if (behaviour == .deny)
            try std.fmt.bufPrint(&head, "GET /oauth2/callback?error=access_denied&state={s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{state})
        else
            try std.fmt.bufPrint(&head, "GET /oauth2/callback?code={s}&state={s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{ code, state });
        const owned = try std.testing.allocator.dupe(u8, request);
        pending = try io.concurrent(redirectBack, .{ port, owned });
    }
    fn redirectBack(port: u16, request: []const u8) anyerror!void {
        defer std.testing.allocator.free(request);
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var writer = std.Io.net.Stream.Writer.init(stream, io, &.{});
        try writer.interface.writeAll(request);
        try writer.interface.flush();
        var buffer: [1024]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, io, &buffer);
        var rest: [1024]u8 = undefined;
        _ = try reader.interface.readSliceShort(&rest);
    }
};

/// Google's token endpoint and Gmail profile, on loopback.
const Oracle = struct {
    listener: std.Io.net.Server,
    profile: []const u8 = account,
    scope: []const u8 = "",
    exchanges: std.atomic.Value(usize) = .init(0),
    verified_pkce: std.atomic.Value(bool) = .init(false),
    fn run(self: *Oracle) anyerror!void {
        while (true) {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            try self.respond(stream);
        }
    }
    fn respond(self: *Oracle, stream: std.Io.net.Stream) !void {
        var input: [8192]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, io, &input);
        var writer = std.Io.net.Stream.Writer.init(stream, io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        var path_buffer: [512]u8 = undefined;
        const path = path_buffer[0..request.head.target.len];
        @memcpy(path, request.head.target);
        const method = request.head.method;
        var body: [8192]u8 = undefined;
        const size = if (method.requestHasBody()) try request.readerExpectNone(&.{}).readSliceShort(&body) else 0;
        var reply: [1024]u8 = undefined;
        var response: []const u8 = "{}";
        if (std.mem.eql(u8, path, "/oauth2.googleapis.com/token")) {
            _ = self.exchanges.fetchAdd(1, .acq_rel);
            const form = body[0..size];
            try std.testing.expect(std.mem.indexOf(u8, form, "grant_type=authorization_code") != null);
            try std.testing.expect(std.mem.indexOf(u8, form, "code=synthetic-code") != null);
            const at = (std.mem.indexOf(u8, form, "code_verifier=") orelse return error.MissingVerifier) + "code_verifier=".len;
            var expected: [43]u8 = undefined;
            oauth.pkceChallenge(form[at..][0..43], &expected);
            self.verified_pkce.store(std.mem.eql(u8, &expected, &Consent.challenge), .release);
            response = try std.fmt.bufPrint(&reply, "{{\"access_token\":\"synthetic-renewed-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"{s}\",\"scope\":\"{s}\"}}", .{ fresh_refresh, self.scope });
        } else if (std.mem.startsWith(u8, path, "/gmail.googleapis.com/gmail/v1/users/me/profile?")) {
            response = try std.fmt.bufPrint(&reply, "{{\"emailAddress\":\"{s}\"}}", .{self.profile});
        } else return error.UnexpectedOracleRequest;
        try request.respond(response, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    }
};

/// A vault-backed credential store that records what authorization writes.
const Vault = struct {
    registry: []const u8,
    applies: usize = 0,
    saved_registry: [4096]u8 = undefined,
    saved_registry_len: usize = 0,
    token: [128]u8 = undefined,
    token_len: usize = 0,
    fn read(context: *anyopaque, kind: native.Kind, key: native.Key) !?[]const u8 {
        const self: *Vault = @ptrCast(@alignCast(context));
        return switch (kind) {
            .grants => self.registry,
            .desktop_client => if (std.mem.eql(u8, key.name, "synthetic-terminal-client")) client_json else null,
            else => null,
        };
    }
    fn apply(context: *anyopaque, changes: []const native.Change) !void {
        const self: *Vault = @ptrCast(@alignCast(context));
        self.applies += 1;
        for (changes) |change| {
            if (change.kind == .grants) {
                const value = change.value.?;
                @memcpy(self.saved_registry[0..value.len], value);
                self.saved_registry_len = value.len;
            } else if (change.kind == .terminal_token) if (change.value) |value| {
                @memcpy(self.token[0..value.len], value);
                self.token_len = value.len;
            };
        }
    }
};

const Setup = struct {
    arena: std.heap.ArenaAllocator,
    vault: Vault,
    config: *Config,
    env: std.process.Environ.Map,
    grant_id: [64]u8,
    oracle: Oracle,
    task: ?std.Io.Future(anyerror!void) = null,
    fn init(self: *Setup, grant: bool) !void {
        self.arena = .init(std.testing.allocator);
        const a = self.arena.allocator();
        const scopes = try auth.scopesFor(a, &recorded);
        self.grant_id = auth.grantIdentity(scopes);
        var rows = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-terminal-client", .clientId = client_id, .grantId = &self.grant_id, .capabilities = &recorded, .scopes = scopes }};
        self.vault = .{ .registry = try j.encodeAlloc(a, auth.Registry{ .accounts = if (grant) &rows else &.{} }, .{}) };
        self.config = try a.create(Config);
        try self.config.defaults("/nonexistent/synthetic-home");
        self.config.count = 1;
        try self.config.accounts[0].address.set(account);
        try self.config.accounts[0].profile.set("Synthetic Profile");
        self.config.accounts[0].enabled = true;
        self.config.credential_store = .vault;
        self.config.runtime_provider = .{ .context = &self.vault, .readFn = Vault.read, .applyFn = Vault.apply };
        self.env = .init(std.testing.allocator);
        var joined: std.ArrayList(u8) = .empty;
        for (scopes, 0..) |scope, index| {
            if (index != 0) try joined.append(a, ' ');
            try joined.appendSlice(a, scope);
        }
        self.oracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .scope = joined.items };
        http.TestRoute.origin = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.oracle.listener.socket.address.getPort()});
        self.task = try io.concurrent(Oracle.run, .{&self.oracle});
        auth_diagnostic.reset();
    }
    fn deinit(self: *Setup) void {
        if (self.task) |*task| task.cancel(io) catch {};
        http.TestRoute.origin = null;
        oauth.TestBrowser.open = null;
        self.oracle.listener.deinit(io);
        self.env.deinit();
        self.arena.deinit();
        auth_diagnostic.reset();
    }
    fn authorize(self: *Setup, capabilities: []const []const u8, expected_grant: ?[]const u8) !j.Value {
        const a = self.arena.allocator();
        var request = try j.value(a, .{ .cmd = "auth.authorize", .account = account, .capabilities = capabilities, .reconnect = true });
        if (expected_grant) |id| try request.object.put(a, "expectedGrantId", .{ .string = id });
        return auth.run(io, a, self.config, &self.env, request);
    }
};

test "reconnect auth: consent renews exactly the recorded grant and its credential" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    const a = setup.arena.allocator();
    auth_diagnostic.recordFailure(account, oauth.TokenError.fromJson(400, try std.json.parseFromSliceLeaky(j.Value, a, "{\"error\":\"invalid_grant\",\"error_subtype\":\"invalid_rapt\"}", .{})), 7);
    const before = try auth.run(io, a, setup.config, &setup.env, try j.value(a, .{ .cmd = "auth.status", .account = account }));
    try std.testing.expectEqualStrings("reauthenticationRequired", j.text(j.get(before, "lastRefreshError").?, "kind"));
    Consent.reset(.approve);
    // A different order of the same set is the same grant.
    const result = try setup.authorize(&.{ "calendar-read", "mail-read", "contacts-read", "mail-send" }, &setup.grant_id);
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 1), Consent.opened);
    try std.testing.expect(try j.boolean(result, "reconnected", false));
    try std.testing.expect(setup.oracle.verified_pkce.load(.acquire));
    try std.testing.expectEqualStrings(client_id, Consent.client[0..Consent.client_len]);
    try std.testing.expectEqualStrings(setup.oracle.scope, Consent.scope[0..Consent.scope_len]);
    // The stored registry keeps the recorded capabilities, scopes and identity.
    try std.testing.expectEqual(@as(usize, 1), setup.vault.applies);
    const saved = try auth.parse(a, setup.vault.saved_registry[0..setup.vault.saved_registry_len]);
    const grant = auth.find(&saved, account) orelse {
        std.debug.print("saved registry: {s}\n", .{setup.vault.saved_registry[0..setup.vault.saved_registry_len]});
        return error.GrantNotSaved;
    };
    try std.testing.expectEqual(recorded.len, grant.capabilities.len);
    for (recorded, grant.capabilities) |left, right| try std.testing.expectEqualStrings(left, right);
    try std.testing.expectEqualStrings(&setup.grant_id, grant.grantId);
    try std.testing.expectEqualStrings(fresh_refresh, setup.vault.token[0..setup.vault.token_len]);
    // The obsolete reason is gone and the reply carries no token material.
    const after = try auth.run(io, a, setup.config, &setup.env, try j.value(a, .{ .cmd = "auth.status", .account = account }));
    try std.testing.expect(j.get(after, "lastRefreshError").? == .null);
    const encoded = try j.encodeAlloc(a, result, .{});
    for ([_][]const u8{ fresh_refresh, "synthetic-code", "synthetic-renewed-access", "synthetic-reconnect-secret" }) |secret| try std.testing.expect(std.mem.indexOf(u8, encoded, secret) == null);
}

test "reconnect auth: a narrower, broader or changed grant is refused before consent" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    Consent.reset(.approve);
    try std.testing.expectError(error.ReconnectCapabilitiesChanged, setup.authorize(&.{ "mail-read", "mail-send", "contacts-read" }, null));
    try std.testing.expectError(error.ReconnectCapabilitiesChanged, setup.authorize(&.{ "mail-read", "mail-send", "contacts-read", "calendar-read", "drive-upload" }, null));
    try std.testing.expectError(error.ReconnectCapabilitiesChanged, setup.authorize(&.{ "mail-read", "mail-send", "contacts-read", "calendar-freebusy" }, null));
    const other_grant: [64]u8 = @splat('0');
    try std.testing.expectError(error.GrantChanged, setup.authorize(&recorded, &other_grant));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 0), Consent.opened);
    try std.testing.expectEqual(@as(usize, 0), setup.vault.applies);
    try std.testing.expectEqual(@as(usize, 0), setup.oracle.exchanges.load(.acquire));
    var missing: Setup = undefined;
    try missing.init(false);
    defer missing.deinit();
    Consent.reset(.approve);
    try std.testing.expectError(error.ReconnectRequiresGrant, missing.authorize(&recorded, null));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 0), Consent.opened);
}

test "reconnect auth: denied consent and a different Google account store nothing" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    Consent.reset(.deny);
    try std.testing.expectError(error.AuthorizationDenied, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 0), setup.oracle.exchanges.load(.acquire));
    setup.oracle.profile = "other@example.test";
    Consent.reset(.approve);
    try std.testing.expectError(error.WrongAccount, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 1), setup.oracle.exchanges.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), setup.vault.applies);
}

test "reconnect auth: fixture consent checks PKCE and identity, times out and cancels with its listener closed" {
    const scopes = [_][]const u8{oauth.readonly_scope};
    Consent.reset(.fixture_self);
    try oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/browser", &scopes, platform.seconds(5));
    try Consent.finish();
    Consent.reset(.fixture_other);
    try std.testing.expectError(error.WrongAccount, oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/browser", &scopes, platform.seconds(5)));
    try Consent.finish();
    Consent.reset(.fixture_bad_pkce);
    try std.testing.expectError(error.InvalidGrant, oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/browser", &scopes, platform.seconds(5)));
    try Consent.finish();
    // A closed browser never calls back: the bounded wait ends cleanly.
    Consent.reset(.ignore);
    try std.testing.expectError(error.Timeout, oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/browser", &scopes, .{ .clock = .awake, .raw = .fromMilliseconds(200) }));
    try Consent.finish();
    // Cancelling while consent waits closes the loopback listener.
    Consent.reset(.ignore);
    var future = try io.concurrent(oauth.authorizeFixture, .{ io, account, "Synthetic Profile", "/nonexistent/browser", @as([]const []const u8, &scopes), platform.seconds(30) });
    while (Consent.opened == 0) try io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try Consent.finish();
}

test "reconnect auth: Google's refresh refusal reason reaches the diagnostic" {
    var access: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidGrant, oauth.parseTokens(400, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}", &access, null));
    const refusal = oauth.takeTokenError();
    try std.testing.expectEqualStrings("expiredOrRevoked", refusal.kind());
    try std.testing.expect(!oauth.takeTokenError().present());
}

test {
    _ = @import("auth_diagnostic.zig");
    _ = @import("fixture_auth.zig");
}
