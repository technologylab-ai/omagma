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
const other_client_json = "{\"installed\":{\"client_id\":\"synthetic-other.apps.googleusercontent.com\",\"client_secret\":\"synthetic-other-secret\"}}";
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
    var port: u16 = 0;
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
        port = try std.fmt.parseInt(u16, redirect[prefix.len..std.mem.indexOfScalarPos(u8, redirect, prefix.len, '/').?], 10);
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
    fn redirectBack(target: u16, request: []const u8) anyerror!void {
        defer std.testing.allocator.free(request);
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", target);
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

/// Google's token endpoint, Gmail profile and labels, on loopback.
const Oracle = struct {
    listener: std.Io.net.Server,
    profile: []const u8 = account,
    scope: []const u8 = "",
    /// Scope string returned for the authorization code; empty: `scope`.
    granted_scope: []const u8 = "",
    exchanges: std.atomic.Value(usize) = .init(0),
    refreshes: std.atomic.Value(usize) = .init(0),
    verified_pkce: std.atomic.Value(bool) = .init(false),
    /// The code exchange waits here until released (a slow token endpoint).
    hold_exchange: std.atomic.Value(bool) = .init(false),
    exchange_entered: std.atomic.Value(bool) = .init(false),
    /// A refresh of the stored token is refused like Google's invalid_rapt.
    refuse_refresh: std.atomic.Value(bool) = .init(false),
    /// The code exchange fails (a token endpoint outage after consent).
    fail_exchange: std.atomic.Value(bool) = .init(false),
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
        var status: std.http.Status = .ok;
        if (std.mem.eql(u8, path, "/oauth2.googleapis.com/token")) {
            const form = body[0..size];
            if (std.mem.indexOf(u8, form, "grant_type=refresh_token") != null) {
                _ = self.refreshes.fetchAdd(1, .acq_rel);
                if (self.refuse_refresh.load(.acquire)) {
                    status = .bad_request;
                    response = "{\"error\":\"invalid_grant\",\"error_description\":\"reauth related error (invalid_rapt)\",\"error_uri\":\"https://support.google.com/a/answer/9368756\",\"error_subtype\":\"invalid_rapt\"}";
                } else response = try std.fmt.bufPrint(&reply, "{{\"access_token\":\"synthetic-refreshed-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"{s}\"}}", .{self.scope});
            } else {
                _ = self.exchanges.fetchAdd(1, .acq_rel);
                self.exchange_entered.store(true, .release);
                while (self.hold_exchange.load(.acquire)) try io.sleep(.fromMilliseconds(5), .awake);
                if (self.fail_exchange.load(.acquire)) {
                    try request.respond("{\"error\":\"internal_failure\"}", .{ .status = .internal_server_error, .keep_alive = false });
                    return;
                }
                try std.testing.expect(std.mem.indexOf(u8, form, "grant_type=authorization_code") != null);
                try std.testing.expect(std.mem.indexOf(u8, form, "code=synthetic-code") != null);
                const at = (std.mem.indexOf(u8, form, "code_verifier=") orelse return error.MissingVerifier) + "code_verifier=".len;
                var expected: [43]u8 = undefined;
                oauth.pkceChallenge(form[at..][0..43], &expected);
                self.verified_pkce.store(std.mem.eql(u8, &expected, &Consent.challenge), .release);
                response = try std.fmt.bufPrint(&reply, "{{\"access_token\":\"synthetic-renewed-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"{s}\",\"scope\":\"{s}\"}}", .{ fresh_refresh, if (self.granted_scope.len > 0) self.granted_scope else self.scope });
            }
        } else if (std.mem.startsWith(u8, path, "/gmail.googleapis.com/gmail/v1/users/me/profile?")) {
            response = try std.fmt.bufPrint(&reply, "{{\"emailAddress\":\"{s}\"}}", .{self.profile});
        } else if (std.mem.startsWith(u8, path, "/gmail.googleapis.com/gmail/v1/users/me/labels")) {
            response = "{\"labels\":[]}";
        } else return error.UnexpectedOracleRequest;
        try request.respond(response, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    }
};
/// A vault-backed credential store that records what authorization writes.
const Vault = struct {
    registry: []const u8,
    applies: usize = 0,
    /// The recorded registration name now holds another registration.
    replaced: bool = false,
    fail_apply: ?anyerror = null,
    /// The durable write hangs (until the commit bound cancels it).
    block_apply: bool = false,
    saved_registry: [4096]u8 = undefined,
    saved_registry_len: usize = 0,
    token: [128]u8 = undefined,
    token_len: usize = 0,
    fn read(context: *anyopaque, kind: native.Kind, key: native.Key) !?[]const u8 {
        const self: *Vault = @ptrCast(@alignCast(context));
        return switch (kind) {
            .grants => self.registry,
            .desktop_client => if (std.mem.eql(u8, key.name, "synthetic-terminal-client")) (if (self.replaced) other_client_json else client_json) else if (std.mem.eql(u8, key.name, "same-registration-copy")) client_json else if (std.mem.eql(u8, key.name, "another-registration")) other_client_json else null,
            else => null,
        };
    }
    fn apply(context: *anyopaque, changes: []const native.Change) !void {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (self.block_apply) while (true) try io.sleep(.fromMilliseconds(5), .awake);
        if (self.fail_apply) |err| return err;
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
    auth_diagnostic.recordFailure(account, &setup.grant_id, oauth.TokenError.fromJson(400, try std.json.parseFromSliceLeaky(j.Value, a, "{\"error\":\"invalid_grant\",\"error_subtype\":\"invalid_rapt\"}", .{})), 7);
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
    const grant = auth.find(&saved, account) orelse return error.GrantNotSaved;
    try std.testing.expectEqual(recorded.len, grant.capabilities.len);
    for (recorded, grant.capabilities) |left, right| try std.testing.expectEqualStrings(left, right);
    try std.testing.expectEqualStrings(&setup.grant_id, grant.grantId);
    try std.testing.expectEqualStrings(fresh_refresh, setup.vault.token[0..setup.vault.token_len]);
    // The obsolete reason is gone, the commit has ended and the reply carries
    // no token material.
    try std.testing.expect(!oauth.committing());
    const after = try auth.run(io, a, setup.config, &setup.env, try j.value(a, .{ .cmd = "auth.status", .account = account }));
    try std.testing.expect(j.get(after, "lastRefreshError").? == .null);
    const encoded = try j.encodeAlloc(a, result, .{});
    for ([_][]const u8{ fresh_refresh, "synthetic-code", "synthetic-renewed-access", "synthetic-reconnect-secret" }) |secret| try std.testing.expect(std.mem.indexOf(u8, encoded, secret) == null);
}

test "reconnect auth: a narrower, broader, changed or re-registered grant is refused before consent" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    const a = setup.arena.allocator();
    Consent.reset(.approve);
    try std.testing.expectError(error.ReconnectCapabilitiesChanged, setup.authorize(&.{ "mail-read", "mail-send", "contacts-read" }, null));
    try std.testing.expectError(error.ReconnectCapabilitiesChanged, setup.authorize(&.{ "mail-read", "mail-send", "contacts-read", "calendar-read", "drive-upload" }, null));
    try std.testing.expectError(error.ReconnectCapabilitiesChanged, setup.authorize(&.{ "mail-read", "mail-send", "contacts-read", "calendar-freebusy" }, null));
    const other_grant: [64]u8 = @splat('0');
    try std.testing.expectError(error.GrantChanged, setup.authorize(&recorded, &other_grant));
    // A malformed identity is a malformed request, not a changed grant.
    try std.testing.expectError(error.InvalidRequest, setup.authorize(&recorded, "x"));
    try std.testing.expectError(error.InvalidRequest, setup.authorize(&recorded, "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));
    // Reconnect never switches the OAuth registration: neither an explicit
    // other one, nor another registration put at the recorded path.
    var moved = try j.value(a, .{ .cmd = "auth.authorize", .account = account, .capabilities = &recorded, .reconnect = true, .clientFile = "another-registration" });
    try std.testing.expectError(error.ReconnectRegistrationChanged, auth.run(io, a, setup.config, &setup.env, moved));
    setup.vault.replaced = true;
    try std.testing.expectError(error.ReconnectRegistrationChanged, setup.authorize(&recorded, &setup.grant_id));
    setup.vault.replaced = false;
    moved = try j.value(a, .{ .cmd = "auth.authorize", .account = account, .capabilities = &recorded, .expectedGrantId = &setup.grant_id });
    try std.testing.expectError(error.ExpectedGrantRequiresReconnect, auth.run(io, a, setup.config, &setup.env, moved));
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

test "reconnect auth: denial, a different Google account and a narrowed grant store nothing" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    Consent.reset(.deny);
    try std.testing.expectError(error.AuthorizationDenied, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 0), setup.oracle.exchanges.load(.acquire));
    try std.testing.expect(!oauth.committing());
    setup.oracle.profile = "other@example.test";
    Consent.reset(.approve);
    try std.testing.expectError(error.WrongAccount, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 1), setup.oracle.exchanges.load(.acquire));
    // A permission unchecked on Google's consent page returns fewer scopes.
    setup.oracle.profile = account;
    setup.oracle.granted_scope = "https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.readonly";
    Consent.reset(.approve);
    try std.testing.expectError(error.UnexpectedScope, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 2), setup.oracle.exchanges.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), setup.vault.applies);
    try std.testing.expect(!oauth.committing());
}

test "reconnect auth: the same registration under another spelling is accepted" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    const a = setup.arena.allocator();
    for ([_][]const u8{ "same-registration-copy", "synthetic-terminal-client/", "synthetic-terminal-client//" }) |spelling| {
        Consent.reset(.deny);
        const request = try j.value(a, .{ .cmd = "auth.authorize", .account = account, .capabilities = &recorded, .reconnect = true, .clientFile = spelling, .expectedGrantId = &setup.grant_id });
        // Consent opened with the recorded registration, then was declined.
        try std.testing.expectError(error.AuthorizationDenied, auth.run(io, a, setup.config, &setup.env, request));
        try Consent.finish();
        try std.testing.expectEqual(@as(usize, 1), Consent.opened);
        try std.testing.expectEqualStrings(client_id, Consent.client[0..Consent.client_len]);
    }
}

test "reconnect auth: a failure after Google's callback says whether anything may have been stored" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    var cause: [64]u8 = undefined;
    // The token endpoint fails after consent: nothing was stored.
    setup.oracle.fail_exchange.store(true, .release);
    Consent.reset(.approve);
    try std.testing.expectError(error.TokenExchangeFailed, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expect(oauth.takeCommitCause(&cause).len > 0);
    try std.testing.expectEqual(@as(usize, 0), setup.vault.applies);
    setup.oracle.fail_exchange.store(false, .release);
    // The durable write fails: whether it landed is unknown.
    setup.vault.fail_apply = error.AccessDenied;
    Consent.reset(.approve);
    try std.testing.expectError(error.SignInStoreUnconfirmed, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expectEqualStrings("AccessDenied", oauth.takeCommitCause(&cause));
    setup.vault.fail_apply = null;
    // A hung durable write is ended by the commit bound, not waited on.
    oauth.TestBound.ms = 300;
    defer oauth.TestBound.ms = null;
    setup.vault.block_apply = true;
    Consent.reset(.approve);
    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try std.testing.expectError(error.SignInStoreUnconfirmed, setup.authorize(&recorded, &setup.grant_id));
    try Consent.finish();
    try std.testing.expect(std.Io.Timestamp.now(io, .awake).toMilliseconds() - started < 5000);
    try std.testing.expectEqualStrings("Timeout", oauth.takeCommitCause(&cause));
    try std.testing.expect(!oauth.committing());
}

test "reconnect auth: an in-process canceller and Google's callback cannot both win" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    const a = setup.arena.allocator();
    const types = @import("types.zig");
    const Quiet = struct {
        fn report(_: *anyopaque, _: types.FetchProgress) void {}
    };
    var context: u8 = 0;
    const request = try j.value(a, .{ .cmd = "auth.authorize", .account = account, .capabilities = &recorded, .reconnect = true, .expectedGrantId = &setup.grant_id });
    // The canceller won before the callback: the commit never starts.
    var gate: std.atomic.Value(u8) = .init(oauth.gate_canceled);
    Consent.reset(.approve);
    try std.testing.expectError(error.Canceled, auth.runWithProgress(io, a, setup.config, &setup.env, request, .{ .ctx = &context, .reportFn = Quiet.report, .commit_gate = &gate }));
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 0), setup.oracle.exchanges.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), setup.vault.applies);
    try std.testing.expect(!oauth.committing());
    // The callback won: the commit completes and a later cancel cannot claim the gate.
    gate.store(oauth.gate_open, .release);
    Consent.reset(.approve);
    _ = try auth.runWithProgress(io, a, setup.config, &setup.env, request, .{ .ctx = &context, .reportFn = Quiet.report, .commit_gate = &gate });
    try Consent.finish();
    try std.testing.expect(gate.cmpxchgStrong(oauth.gate_open, oauth.gate_canceled, .acq_rel, .acquire) != null);
    try std.testing.expectEqual(@as(usize, 1), setup.vault.applies);
}

const Authorization = struct {
    fn run(setup: *Setup) anyerror!j.Value {
        return setup.authorize(&recorded, &setup.grant_id);
    }
};

test "reconnect auth: cancelling after Google's callback still stores and reports the renewed credential" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    setup.oracle.hold_exchange.store(true, .release);
    Consent.reset(.approve);
    var future = try io.concurrent(Authorization.run, .{&setup});
    while (!setup.oracle.exchange_entered.load(.acquire)) try io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(oauth.committing());
    // Release the slow exchange shortly after the cancel request arrives.
    const Release = struct {
        fn later(oracle: *Oracle) anyerror!void {
            try io.sleep(.fromMilliseconds(150), .awake);
            oracle.hold_exchange.store(false, .release);
        }
    };
    var release = try io.concurrent(Release.later, .{&setup.oracle});
    const result = try future.cancel(io);
    try release.await(io);
    try Consent.finish();
    try std.testing.expect(try j.boolean(result, "reconnected", false));
    try std.testing.expectEqual(@as(usize, 1), setup.vault.applies);
    try std.testing.expectEqualStrings(fresh_refresh, setup.vault.token[0..setup.vault.token_len]);
    try std.testing.expect(!oauth.committing());
}

test "reconnect auth: cancelling while consent waits closes the loopback listener and stores nothing" {
    var setup: Setup = undefined;
    try setup.init(true);
    defer setup.deinit();
    Consent.reset(.ignore);
    var future = try io.concurrent(Authorization.run, .{&setup});
    while (Consent.opened == 0) try io.sleep(.fromMilliseconds(5), .awake);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", Consent.port);
    // The listener is open while waiting...
    (try address.connect(io, .{ .mode = .stream })).close(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try Consent.finish();
    // ...and closed once the cancel returns.
    try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(usize, 0), setup.vault.applies);
    try std.testing.expect(!oauth.committing());
}

test "reconnect auth: fixture consent checks PKCE and identity, times out and cancels with its listener closed" {
    const scopes = [_][]const u8{oauth.readonly_scope};
    Consent.reset(.fixture_self);
    try oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/consent-page", &scopes, platform.seconds(5), null);
    try Consent.finish();
    Consent.reset(.fixture_other);
    try std.testing.expectError(error.WrongAccount, oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/consent-page", &scopes, platform.seconds(5), null));
    try Consent.finish();
    // A code the token exchange refuses arrives after Google's callback:
    // nothing was stored, and the underlying refusal is named.
    Consent.reset(.fixture_bad_pkce);
    try std.testing.expectError(error.TokenExchangeFailed, oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/consent-page", &scopes, platform.seconds(5), null));
    try Consent.finish();
    var cause: [64]u8 = undefined;
    try std.testing.expectEqualStrings("InvalidGrant", oauth.takeCommitCause(&cause));
    // A closed browser never calls back: the bounded wait ends cleanly.
    Consent.reset(.ignore);
    try std.testing.expectError(error.Timeout, oauth.authorizeFixture(io, account, "Synthetic Profile", "/nonexistent/consent-page", &scopes, .{ .clock = .awake, .raw = .fromMilliseconds(200) }, null));
    try Consent.finish();
    // Cancelling while consent waits closes the loopback listener.
    Consent.reset(.ignore);
    var future = try io.concurrent(oauth.authorizeFixture, .{ io, account, "Synthetic Profile", "/nonexistent/consent-page", @as([]const []const u8, &scopes), platform.seconds(30), @as(?*oauth.Commit, null) });
    while (Consent.opened == 0) try io.sleep(.fromMilliseconds(5), .awake);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", Consent.port);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    try Consent.finish();
    try std.testing.expect(!oauth.committing());
}

test "reconnect auth: fixture consent never launches a configured browser" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const config = try a.create(Config);
    try config.defaults("/nonexistent/synthetic-home");
    const options: @import("types.zig").Options = .{ .fixtures = true, .fixture_scenario = "sign-in-expired", .cache_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temporary.sub_path}) };
    const request = try j.value(a, .{ .cmd = "auth.authorize", .account = "work@example.com", .capabilities = &@import("fixture_auth.zig").capabilities, .reconnect = true });
    Consent.reset(.fixture_self);
    for ([_][]const u8{ Config.default_chrome, "/usr/bin/chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium", "/opt/any/browser" }) |browser| {
        try config.chrome.set(browser);
        try std.testing.expectError(error.FixtureConsentPageRequired, auth.runFixture(io, a, config, options, options.cache_dir.?, request, null));
    }
    try Consent.finish();
    try std.testing.expectEqual(@as(usize, 0), Consent.opened);
    // The explicit synthetic page is the only way in.
    var parsed: Config = undefined;
    try parsed.defaults("/nonexistent/synthetic-home");
    try parsed.parse(a, "{\"fixtureConsentPage\":\"/synthetic/consent-page\"}");
    try std.testing.expectEqualStrings("/synthetic/consent-page", parsed.fixture_consent_page.slice());
    try std.testing.expectError(error.InvalidFixtureConsentPage, parsed.parse(a, "{\"fixtureConsentPage\":\"relative/page\"}"));
}

test "reconnect auth: revoking a grant forgets its refusal in memory and in the sidecar" {
    auth_diagnostic.reset();
    defer auth_diagnostic.reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temporary.sub_path}), a);
    const credentials = try std.fmt.allocPrint(a, "{s}/credentials", .{root});
    try std.Io.Dir.cwd().createDir(io, credentials, .fromMode(0o700));
    const grants = try std.fmt.allocPrint(a, "{s}/terminal-grants.json", .{root});
    const scopes = try auth.scopesFor(a, &recorded);
    const grant_id = auth.grantIdentity(scopes);
    var rows = [_]auth.Grant{.{ .account = account, .clientFile = "/synthetic/client.json", .clientId = client_id, .grantId = &grant_id, .capabilities = &recorded, .scopes = scopes }};
    const file = try std.Io.Dir.cwd().createFile(io, grants, .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, try j.encodeAlloc(a, auth.Registry{ .accounts = &rows }, .{}));
    file.close(io);
    const config = try a.create(Config);
    try config.defaults("/nonexistent/synthetic-home");
    config.count = 1;
    try config.accounts[0].address.set(account);
    try config.accounts[0].profile.set("Synthetic Profile");
    config.accounts[0].enabled = true;
    config.credential_store = .file;
    try config.credential_directory.set(credentials);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    auth_diagnostic.recordFailure(account, &grant_id, .{}, 3);
    const sidecar = try auth_diagnostic.sidecarPath(a, grants);
    try auth_diagnostic.persist(io, a, sidecar, account);
    const status = try j.value(a, .{ .cmd = "auth.status", .account = account, .grantFile = grants });
    try std.testing.expect(j.get(try auth.run(io, a, config, &env, status), "lastRefreshError").? != .null);
    _ = try auth.run(io, a, config, &env, try j.value(a, .{ .cmd = "auth.revoke", .account = account, .grantFile = grants }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, sidecar, .{}));
    try std.testing.expectEqual(auth_diagnostic.Observed.unknown, auth_diagnostic.observed(account).observed);
    try std.testing.expect(j.get(try auth.run(io, a, config, &env, status), "lastRefreshError").? == .null);
}

test "reconnect auth: Google's refresh refusal reason reaches the diagnostic" {
    var access: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidGrant, oauth.parseTokens(400, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}", &access, null));
    const refusal = oauth.takeTokenError();
    try std.testing.expectEqualStrings("expiredOrRevoked", refusal.kind());
    try std.testing.expect(!oauth.takeTokenError().present());
}

test "reconnect auth: production sessions persist only the terminal grant's refusal and clear it after a verified refresh" {
    const core = @import("core.zig");
    const keyring = @import("../keyring.zig");
    auth_diagnostic.reset();
    defer auth_diagnostic.reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temporary.sub_path}), a);
    const credentials = try std.fmt.allocPrint(a, "{s}/credentials", .{root});
    try std.Io.Dir.cwd().createDir(io, credentials, .fromMode(0o700));
    const client_path = try std.fmt.allocPrint(a, "{s}/terminal-client.json", .{root});
    const client_file = try std.Io.Dir.cwd().createFile(io, client_path, .{ .permissions = .fromMode(0o600) });
    try client_file.writeStreamingAll(io, client_json);
    client_file.close(io);
    const grants = try std.fmt.allocPrint(a, "{s}/terminal-grants.json", .{root});
    const capabilities = [_][]const u8{"mail-read"};
    const scopes = try auth.scopesFor(a, &capabilities);
    const grant_id = auth.grantIdentity(scopes);
    var rows = [_]auth.Grant{.{ .account = account, .clientFile = client_path, .clientId = client_id, .grantId = &grant_id, .capabilities = &capabilities, .scopes = scopes }};
    const registry_file = try std.Io.Dir.cwd().createFile(io, grants, .{ .permissions = .fromMode(0o600) });
    try registry_file.writeStreamingAll(io, try j.encodeAlloc(a, auth.Registry{ .accounts = &rows }, .{}));
    registry_file.close(io);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", try std.fmt.allocPrint(a, "{s}/home", .{root}));
    try env.put("XDG_CONFIG_HOME", try std.fmt.allocPrint(a, "{s}/config", .{root}));
    try env.put("XDG_RUNTIME_DIR", try std.fmt.allocPrint(a, "{s}/runtime", .{root}));
    const session = try std.testing.allocator.create(core.Session);
    defer std.testing.allocator.destroy(session);
    session.* = try core.Session.init(io, std.testing.allocator, &env, .{ .fixtures = true, .cache_dir = try std.fmt.allocPrint(a, "{s}/cache", .{root}) });
    defer session.deinit();
    session.options.fixtures = false;
    session.options.grant_file = grants;
    session.config.count = 1;
    try session.config.accounts[0].address.set(account);
    try session.config.accounts[0].profile.set("Synthetic Profile");
    session.config.accounts[0].enabled = true;
    session.config.credential_store = .file;
    try session.config.credential_directory.set(credentials);
    // The bar's read-only registration and credential live beside it.
    try session.config.client_file.set(client_path);
    try keyring.storeTerminal(io, session.config.credentials(), account, client_id, &grant_id, "synthetic-stored-refresh");
    try keyring.store(io, session.config.credentials(), account, client_id, "synthetic-bar-refresh");
    var oracle: Oracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .scope = oauth.readonly_scope };
    defer oracle.listener.deinit(io);
    http.TestRoute.origin = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(Oracle.run, .{&oracle});
    defer task.cancel(io) catch {};
    const sidecar = try auth_diagnostic.sidecarPath(a, grants);
    const labels = "{\"cmd\":\"labels.list\",\"account\":\"self@example.test\"}";
    const status = "{\"cmd\":\"auth.status\",\"account\":\"self@example.test\"}";
    // Google refuses the stored terminal token: the reason is persisted.
    oracle.refuse_refresh.store(true, .release);
    const refused = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, labels), .{});
    try std.testing.expectEqualStrings("InvalidGrant", j.text(j.get(refused, "error").?, "code"));
    const persisted = (try auth_diagnostic.status(io, a, sidecar, account, &grant_id)).?;
    try std.testing.expectEqualStrings("invalid_rapt", persisted.subtype);
    // A later one-shot process (nothing observed) still explains it.
    auth_diagnostic.reset();
    const later = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, status), .{});
    try std.testing.expectEqualStrings("reauthenticationRequired", j.text(j.get(j.get(later, "data").?, "lastRefreshError").?, "kind"));
    // The bar's read-only credential is never described as the terminal grant's.
    auth_diagnostic.reset();
    try std.Io.Dir.cwd().deleteFile(io, sidecar);
    // Exactly the background cache-refresh request, which uses the bar's credential.
    const bar = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, "{\"cmd\":\"mail.refresh\",\"account\":\"self@example.test\",\"label\":\"INBOX\",\"limit\":32,\"auto\":true,\"intervalSeconds\":300,\"barGrantOnly\":true}"), .{});
    try std.testing.expectEqualStrings("InvalidGrant", j.text(j.get(bar, "error").?, "code"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, sidecar, .{}));
    try std.testing.expectEqual(auth_diagnostic.Observed.unknown, auth_diagnostic.observed(account).observed);
    // Refused again, then the grant works again (re-authorized elsewhere):
    // the first verified refresh outdates the persisted reason for every process.
    _ = try session.execute(a, labels);
    _ = try std.Io.Dir.cwd().statFile(io, sidecar, .{});
    oracle.refuse_refresh.store(false, .release);
    const recovered = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, labels), .{});
    try std.testing.expect(try j.boolean(recovered, "ok", false));
    var kept: [2048]u8 = undefined;
    const row = try std.Io.Dir.cwd().readFile(io, sidecar, &kept);
    try std.testing.expect(std.mem.indexOf(u8, row, "invalid_grant") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"okAt\":") != null);
    auth_diagnostic.reset();
    const clean = try std.json.parseFromSliceLeaky(j.Value, a, try session.execute(a, status), .{});
    try std.testing.expect(j.get(j.get(clean, "data").?, "lastRefreshError").? == .null);
}

test {
    _ = @import("auth_diagnostic.zig");
    _ = @import("fixture_auth.zig");
}
