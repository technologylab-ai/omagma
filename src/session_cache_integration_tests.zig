//! Real loopback HTTP with synthetic identity provider only. Production URL
//! validation runs before the test-only HTTP redirect; no Google traffic.
const std = @import("std");
const gmail = @import("terminal/gmail.zig");
const http = @import("http_client.zig");
const cache_module = @import("terminal/session_cache.zig");
const native = @import("native_identity.zig");
const Config = @import("config.zig").Config;
const auth = @import("terminal/auth.zig");
const oauth = @import("oauth.zig");
const j = @import("terminal/json.zig");
const io = std.testing.io;
const a = std.testing.allocator;
const account = "self@example.test";
const client_id = "synthetic-session.apps.googleusercontent.com";
const client_one = "{\"installed\":{\"client_id\":\"synthetic-session.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret-one\"}}";
const client_two = "{\"installed\":{\"client_id\":\"synthetic-session.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret-two\"}}";
const labels_url = "https://gmail.googleapis.com/gmail/v1/users/me/labels";
const send_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send";
const Identity = struct {
    registry: []const u8,
    disabled_registry: []const u8,
    grant: [64]u8,
    desktop: []const u8 = client_one,
    refresh: ?[]const u8 = "synthetic-refresh-one",
    locked: bool = false,
    disabled: bool = false,
    fn init(allocator: std.mem.Allocator) !Identity {
        const scopes = try auth.scopesFor(allocator, &.{ "mail-read", "mail-send" });
        const grant = auth.grantIdentity(scopes);
        var rows = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-client", .clientId = client_id, .grantId = &grant, .capabilities = &.{ "mail-read", "mail-send" }, .scopes = scopes }};
        const registry = try j.encodeAlloc(allocator, auth.Registry{ .accounts = &rows }, .{});
        rows[0].enabled = false;
        return .{ .registry = registry, .disabled_registry = try j.encodeAlloc(allocator, auth.Registry{ .accounts = &rows }, .{}), .grant = grant };
    }
    fn read(context: *anyopaque, kind: native.Kind, key: native.Key) !?[]const u8 {
        const self: *Identity = @ptrCast(@alignCast(context));
        if (self.locked) return error.VaultLocked;
        return switch (kind) {
            .grants => if (self.disabled) self.disabled_registry else self.registry,
            .desktop_client => if (std.mem.eql(u8, key.name, "synthetic-client")) self.desktop else null,
            .terminal_token => if (std.mem.eql(u8, key.account, account) and std.mem.eql(u8, key.client, client_id) and std.mem.eql(u8, key.grant, &self.grant)) self.refresh else null,
            else => null,
        };
    }
    fn apply(_: *anyopaque, _: []const native.Change) !void {
        return error.ReadOnlyFixture;
    }
    fn provider(self: *Identity) native.Provider {
        return .{ .context = self, .readFn = read, .applyFn = apply };
    }
};
const draft_full =
    \\{"id":"remote-message","threadId":"remote-thread","labelIds":["DRAFT"],"internalDate":"1","payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"self@example.test"},{"name":"To","value":"reader@example.test"},{"name":"Bcc","value":"hidden@example.test"},{"name":"Subject","value":"Remote draft text"}],"parts":[{"mimeType":"text/plain","body":{"size":12,"data":"UmVtb3RlIHRleHQu"}},{"mimeType":"application/octet-stream","filename":"first.bin","body":{"size":5,"attachmentId":"file-a"}},{"mimeType":"application/octet-stream","filename":"second.bin","body":{"size":6,"attachmentId":"file-b"}}]}}
;
const Oracle = struct {
    listener: std.Io.net.Server,
    refreshes: std.atomic.Value(usize) = .init(0),
    profiles: std.atomic.Value(usize) = .init(0),
    reads: std.atomic.Value(usize) = .init(0),
    writes: std.atomic.Value(usize) = .init(0),
    spools: std.atomic.Value(usize) = .init(0),
    read_401: std.atomic.Value(usize) = .init(0),
    write_status: std.atomic.Value(u16) = .init(401),
    ttl: std.atomic.Value(u32) = .init(3600),
    wrong_profile: std.atomic.Value(bool) = .init(false),
    drop_write: std.atomic.Value(bool) = .init(false),
    invalid_refresh: std.atomic.Value(bool) = .init(false),
    draft_flow: bool = false,
    history_flow: bool = false,
    history_blob_flow: bool = false,
    verified_history_files: std.atomic.Value(usize) = .init(0),
    history_failure: std.atomic.Value(bool) = .init(false),
    draft_status_reads: std.atomic.Value(usize) = .init(0),
    draft_race: std.atomic.Value(bool) = .init(false),
    fn run(self: *Oracle) anyerror!void {
        while (true) {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            self.respond(stream) catch |err| {
                if (self.history_flow and err != error.Canceled) self.history_failure.store(true, .release);
                std.debug.print("HTTP fixture error: {s}\n", .{@errorName(err)});
                return err;
            };
        }
    }
    fn verifyHistoryMedia(self: *Oracle, media: []const u8) !void {
        errdefer self.history_failure.store(true, .release);
        if (std.mem.indexOf(u8, media, "Message-ID: <omagma-") == null) return error.MissingSyntheticMessageId;
        if (std.mem.indexOf(u8, media, "U3ludGhldGljIGV4YWN0IHNwb29sIGJvZHkg") == null) return error.MissingSyntheticAuthoredNote;
        if (self.writes.load(.acquire) == 1) {
            try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, media, "<peer-"));
            try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, media, "Content-Disposition: attachment;"));
        }
        if (self.history_blob_flow) {
            var phase: std.heap.ArenaAllocator = .init(a);
            defer phase.deinit();
            const alloc = phase.allocator();
            const first_line_end = std.mem.indexOf(u8, media, "\r\n") orelse return error.MissingSyntheticBoundary;
            const suffix = try std.fmt.allocPrint(alloc, "\r\n{s}--\r\n", .{media[0..first_line_end]});
            try std.testing.expect(std.mem.endsWith(u8, media, suffix));
            const header = "Content-Type: message/rfc822\r\n\r\n";
            const start = (std.mem.indexOf(u8, media, header) orelse return error.MissingSyntheticMime) + header.len;
            const parsed = try @import("terminal/mime.zig").parse(media[start .. media.len - suffix.len], alloc);
            const index = self.writes.load(.acquire) - 1;
            const expected_note = if (index == 6) "Synthetic exact spool body uncertain" else try std.fmt.allocPrint(alloc, "Synthetic exact spool body {d}", .{index});
            try std.testing.expectEqualStrings(expected_note, std.mem.trimEnd(u8, parsed.body_text, "\r\n"));
            try std.testing.expectEqual(@as(usize, if (index == 0) 40 else if (index <= 4) 1000 else if (index == 5) 57 else 0), parsed.attachments.len);
            const first = self.verified_history_files.load(.acquire);
            for (parsed.attachments, first..) |file, number| {
                try std.testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "tiny-{d}.bin", .{number}), file.filename);
                var expected: [4]u8 = undefined;
                std.mem.writeInt(u32, &expected, @intCast(number), .little);
                try std.testing.expectEqualSlices(u8, &expected, file.data);
            }
            _ = self.verified_history_files.fetchAdd(parsed.attachments.len, .acq_rel);
        }
    }
    fn requireHistorySuccess(self: *const Oracle) !void {
        if (self.history_failure.load(.acquire)) return error.SyntheticHttpOracleFailed;
    }
    fn respond(self: *Oracle, stream: std.Io.net.Stream) !void {
        var input: [8192]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, io, &input);
        var writer = std.Io.net.Stream.Writer.init(stream, io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        const method = request.head.method;
        var path_buffer: [2048]u8 = undefined;
        if (request.head.target.len > path_buffer.len) return error.InvalidFixtureRequest;
        @memcpy(path_buffer[0..request.head.target.len], request.head.target);
        const path = path_buffer[0..request.head.target.len];
        const content_type = request.head.content_type orelse "";
        const multipart = std.mem.startsWith(u8, content_type, "multipart/related;");
        var body: [512 * 1024]u8 = undefined;
        const body_size = if (method.requestHasBody()) try request.readerExpectNone(&.{}).readSliceShort(&body) else 0;
        if (body_size == body.len) return error.InvalidFixtureRequest;
        var status: std.http.Status = .ok;
        var response: []const u8 = "{}";
        var token_buffer: [1024]u8 = undefined;
        if (std.mem.eql(u8, path, "/oauth2.googleapis.com/token")) {
            try std.testing.expectEqual(std.http.Method.POST, method);
            try std.testing.expect(std.mem.indexOf(u8, body[0..body_size], "refresh_token=synthetic-refresh-") != null);
            _ = self.refreshes.fetchAdd(1, .acq_rel);
            response = if (self.draft_flow) "{\"access_token\":\"synthetic-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose\"}" else try std.fmt.bufPrint(&token_buffer, "{{\"access_token\":\"synthetic-access\",\"token_type\":\"Bearer\",\"expires_in\":{d},\"scope\":\"https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send\"}}", .{self.ttl.load(.acquire)});
            if (self.invalid_refresh.load(.acquire)) {
                status = .bad_request;
                response = "{\"error\":\"invalid_grant\"}";
            }
        } else if (std.mem.startsWith(u8, path, "/gmail.googleapis.com/gmail/v1/users/me/profile?")) {
            try std.testing.expectEqual(std.http.Method.GET, method);
            _ = self.profiles.fetchAdd(1, .acq_rel);
            response = if (self.wrong_profile.load(.acquire)) "{\"emailAddress\":\"foreign@example.test\"}" else "{\"emailAddress\":\"self@example.test\"}";
        } else if (self.draft_flow and method == .POST) {
            try std.testing.expect(std.mem.indexOf(u8, path, "/upload/gmail/v1/users/me/drafts?") != null);
            try std.testing.expect(multipart);
            try std.testing.expect(std.mem.indexOf(u8, body[0..body_size], "Bcc: <hidden@example.test>") != null);
            try std.testing.expect(std.mem.indexOf(u8, body[0..body_size], "Message-ID: <owned-upload@mail.invalid>") != null);
            _ = self.writes.fetchAdd(1, .acq_rel);
            _ = self.spools.fetchAdd(1, .acq_rel);
            response = "{\"id\":\"remote-draft\",\"message\":{\"id\":\"remote-message\",\"threadId\":\"remote-thread\"}}";
        } else if (self.draft_flow and method == .GET) {
            _ = self.reads.fetchAdd(1, .acq_rel);
            if (std.mem.indexOf(u8, path, "/drafts/") != null) {
                const count = self.draft_status_reads.fetchAdd(1, .acq_rel);
                response = if (self.draft_race.load(.acquire) and count > 0) "{\"id\":\"remote-draft\",\"message\":{\"id\":\"remote-newer\",\"threadId\":\"remote-thread\"}}" else "{\"id\":\"remote-draft\",\"message\":" ++ draft_full ++ "}";
            } else if (std.mem.indexOf(u8, path, "/attachments/file-a") != null) {
                response = "{\"size\":5,\"data\":\"Zmlyc3Q\"}";
            } else if (std.mem.indexOf(u8, path, "/attachments/file-b") != null) {
                response = "{\"size\":6,\"data\":\"c2Vjb25k\"}";
            } else response = draft_full;
        } else if (method == .GET) {
            _ = self.reads.fetchAdd(1, .acq_rel);
            if (self.read_401.load(.acquire) != 0) {
                _ = self.read_401.fetchSub(1, .acq_rel);
                status = .unauthorized;
            }
            response = "{\"labels\":[]}";
        } else {
            _ = self.writes.fetchAdd(1, .acq_rel);
            if (multipart) {
                _ = self.spools.fetchAdd(1, .acq_rel);
                if (self.history_flow) {
                    try self.verifyHistoryMedia(body[0..body_size]);
                } else try std.testing.expect(std.mem.indexOf(u8, body[0..body_size], "Synthetic exact spool body") != null);
            }
            if (self.drop_write.load(.acquire)) return;
            status = @fromBackingInt(@intCast(self.write_status.load(.acquire)));
            response = "{\"id\":\"synthetic-sent\",\"threadId\":\"synthetic-thread\"}";
        }
        try request.respond(response, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    }
};
test "retained history HTTP oracle: unknown request is exact and receiver failures reach foreground" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var oracle: Oracle = .{ .listener = undefined, .history_flow = true, .history_blob_flow = true, .writes = .init(7), .verified_history_files = .init(4097) };
    const mime = @import("terminal/mime.zig");
    var sender: @import("terminal/recipients.zig").Mailbox = .{};
    try sender.address.set(account);
    var buffer: [4096]u8 = undefined;
    const raw = try mime.encode(.{ .from = sender, .destinations = .{ .to = &.{.{ .address = "peer@example.test" }} }, .subject = "", .body = "Synthetic exact spool body uncertain", .message_id = "<omagma-oracle@example.test>", .date = "Thu, 08 Oct 2026 12:00:00 +0000" }, &buffer);
    const media = try std.fmt.allocPrint(allocator, "--probe\r\nContent-Type: application/json\r\n\r\n{{}}\r\n--probe\r\nContent-Type: message/rfc822\r\n\r\n{s}\r\n--probe--\r\n", .{raw});
    try oracle.verifyHistoryMedia(media);
    try oracle.requireHistorySuccess();
    try std.testing.expectEqual(@as(usize, 4097), oracle.verified_history_files.load(.acquire));
    media[std.mem.indexOf(u8, media, "Message-ID:").?] = 'X';
    try std.testing.expectError(error.MissingSyntheticMessageId, oracle.verifyHistoryMedia(media));
    try std.testing.expectError(error.SyntheticHttpOracleFailed, oracle.requireHistorySuccess());
}

fn invoke(config: *const Config, method: std.http.Method) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var session: gmail.NetworkSession = undefined;
    try session.initWithAllocator(io, arena.allocator(), a, config, account, if (method == .GET) "labels.list" else "mail.send", j.object(arena.allocator()));
    defer session.close();
    const transport = session.transport();
    _ = try transport.requestFn(transport.context, arena.allocator(), method, if (method == .GET) labels_url else send_url, if (method == .GET or method == .DELETE) null else try j.value(arena.allocator(), .{ .raw = "synthetic" }));
}
fn expectCounts(oracle: *Oracle, refreshes: usize, profiles: usize) !void {
    try std.testing.expectEqual(refreshes, oracle.refreshes.load(.acquire));
    try std.testing.expectEqual(profiles, oracle.profiles.load(.acquire));
}

fn submitSpool(config: *const Config, draft_upload: bool, source: *const @import("terminal/send_spool.zig").Spool) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const draft: @import("terminal/types.zig").Draft = .{ .id = "synthetic-draft" };
    if (draft_upload) {
        var session: @import("terminal/draft_gmail.zig").Session = undefined;
        try session.init(io, alloc, a, config, account, j.object(alloc));
        defer session.close();
        _ = try session.create(alloc, draft, source);
    } else _ = try gmail.executeSpool(io, alloc, config, account, j.object(alloc), draft, source, "<owned-upload@mail.invalid>");
}

test "session cache HTTP: expired Google sign-in blocks send and Gmail upload before provider writes and reconnect restores both" {
    for ([_]bool{ false, true }) |draft_upload| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var identity = try Identity.init(alloc);
        if (draft_upload) {
            const scopes = try auth.scopesFor(alloc, &.{ "mail-read", "mail-drafts" });
            identity.grant = auth.grantIdentity(scopes);
            var grants = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-client", .clientId = client_id, .grantId = &identity.grant, .capabilities = &.{ "mail-read", "mail-drafts" }, .scopes = scopes }};
            identity.registry = try j.encodeAlloc(alloc, auth.Registry{ .accounts = &grants }, .{});
        }
        var cache: cache_module.Cache = .{};
        defer cache.clear();
        const config = try alloc.create(Config);
        try config.defaults("/nonexistent/synthetic-home");
        config.count = 1;
        try config.accounts[0].address.set(account);
        config.credential_store = .vault;
        config.runtime_provider = identity.provider();
        config.runtime_access_cache = &cache;
        var oracle: Oracle = .{
            .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }),
            .draft_flow = draft_upload,
            .invalid_refresh = .init(true),
            .write_status = .init(200),
        };
        defer oracle.listener.deinit(io);
        http.TestRoute.origin = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
        defer http.TestRoute.origin = null;
        var task = try io.concurrent(Oracle.run, .{&oracle});
        defer task.cancel(io) catch {};
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const raw = "From: self@example.test\r\nBcc: <hidden@example.test>\r\nMessage-ID: <owned-upload@mail.invalid>\r\n\r\nSynthetic exact spool body\r\n";
        const file = try tmp.dir.createFile(io, "synthetic.mime", .{ .read = true, .permissions = .fromMode(0o600) });
        try file.writeStreamingAll(io, raw);
        var source: @import("terminal/send_spool.zig").Spool = .{ .io = io, .dir = tmp.dir, .file = file, .name = "synthetic.mime", .size = raw.len, .hash = @import("terminal/store.zig").Store.hash(raw) };
        defer source.close();

        try std.testing.expectError(error.InvalidGrant, submitSpool(config, draft_upload, &source));
        try expectCounts(&oracle, 1, 0);
        try std.testing.expectEqual(@as(usize, 0), oracle.writes.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), oracle.spools.load(.acquire));
        // Replacement consent supplies a new refresh credential. Renewal
        // itself must not submit anything; the user explicitly tries again.
        identity.refresh = "synthetic-refresh-two";
        oracle.invalid_refresh.store(false, .release);
        try std.testing.expectEqual(@as(usize, 0), oracle.writes.load(.acquire));
        try submitSpool(config, draft_upload, &source);
        try expectCounts(&oracle, 2, 1);
        try std.testing.expectEqual(@as(usize, 1), oracle.writes.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), oracle.spools.load(.acquire));
    }
}

test "session cache HTTP: current vault identity reuse invalidation expiry and no duplicate mutations" {
    std.debug.print("session HTTP compiler={s} optimize={s} target={s}-{s}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var identity = try Identity.init(arena.allocator());
    var cache: cache_module.Cache = .{};
    defer cache.clear();
    const config = try arena.allocator().create(Config);
    try config.defaults("/nonexistent/synthetic-home");
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .vault;
    config.runtime_provider = identity.provider();
    config.runtime_access_cache = &cache;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var oracle: Oracle = .{ .listener = try address.listen(io, .{ .kernel_backlog = 4 }) };
    defer oracle.listener.deinit(io);
    const origin = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    http.TestRoute.origin = origin;
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(Oracle.run, .{&oracle});
    defer task.cancel(io) catch {};

    try invoke(config, .GET);
    try invoke(config, .GET);
    try expectCounts(&oracle, 1, 1);
    identity.refresh = "synthetic-refresh-two";
    try invoke(config, .GET);
    try expectCounts(&oracle, 2, 2);
    identity.desktop = client_two;
    try invoke(config, .GET);
    try expectCounts(&oracle, 3, 3);
    identity.disabled = true;
    try std.testing.expectError(error.PermissionDenied, invoke(config, .GET));
    try expectCounts(&oracle, 3, 3);
    identity.disabled = false;
    try invoke(config, .GET);
    try expectCounts(&oracle, 4, 4);
    identity.locked = true;
    try std.testing.expectError(error.VaultLocked, invoke(config, .GET));
    identity.locked = false;
    try invoke(config, .GET);
    try expectCounts(&oracle, 5, 5);
    identity.refresh = null;
    try std.testing.expectError(error.NotConnected, invoke(config, .GET));
    identity.refresh = "synthetic-refresh-two";
    try invoke(config, .GET);
    try expectCounts(&oracle, 6, 6);

    // Near-expiry responses are valid for the current read but never retained.
    oracle.ttl.store(60, .release);
    cache.clear();
    try invoke(config, .GET);
    try invoke(config, .GET);
    try expectCounts(&oracle, 8, 8);
    oracle.ttl.store(3600, .release);
    try invoke(config, .GET);
    try expectCounts(&oracle, 9, 9);
    oracle.read_401.store(1, .release);
    const before_reads = oracle.reads.load(.acquire);
    try invoke(config, .GET);
    try expectCounts(&oracle, 10, 10);
    try std.testing.expectEqual(before_reads + 2, oracle.reads.load(.acquire));
    oracle.read_401.store(2, .release);
    try std.testing.expectError(error.NotConnected, invoke(config, .GET));
    try expectCounts(&oracle, 11, 11);
    try invoke(config, .GET);
    try expectCounts(&oracle, 12, 12);

    for ([_]std.http.Method{ .POST, .PATCH, .DELETE }) |method| {
        try invoke(config, .GET); // ensures a current verified cached token
        const refreshes = oracle.refreshes.load(.acquire);
        const writes = oracle.writes.load(.acquire);
        try std.testing.expectError(error.NotConnected, invoke(config, method));
        try std.testing.expectEqual(writes + 1, oracle.writes.load(.acquire));
        try std.testing.expectEqual(refreshes, oracle.refreshes.load(.acquire));
    }
    try invoke(config, .GET);
    oracle.drop_write.store(true, .release);
    const writes_before_drop = oracle.writes.load(.acquire);
    try std.testing.expectError(error.UnknownOutcome, invoke(config, .POST));
    try std.testing.expectEqual(writes_before_drop + 1, oracle.writes.load(.acquire));
    oracle.drop_write.store(false, .release);

    // The exact production spool upload path also dispatches once on 401.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = "From: self@example.test\r\n\r\nSynthetic exact spool body\r\n";
    const file = try tmp.dir.createFile(io, "synthetic.mime", .{ .read = true, .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io, raw);
    var spool: @import("terminal/send_spool.zig").Spool = .{ .io = io, .dir = tmp.dir, .file = file, .name = "synthetic.mime", .size = raw.len, .hash = @import("terminal/store.zig").Store.hash(raw) };
    defer spool.close();
    const writes_before_spool = oracle.writes.load(.acquire);
    try std.testing.expectError(error.NotConnected, gmail.executeSpool(io, arena.allocator(), config, account, j.object(arena.allocator()), .{ .id = "synthetic-draft" }, &spool, "<synthetic@example.test>"));
    try std.testing.expectEqual(writes_before_spool + 1, oracle.writes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), oracle.spools.load(.acquire));

    oracle.wrong_profile.store(true, .release);
    cache.clear();
    try std.testing.expectError(error.WrongAccount, invoke(config, .GET));
    const rejected_profiles = oracle.profiles.load(.acquire);
    oracle.wrong_profile.store(false, .release);
    try invoke(config, .GET);
    try std.testing.expectEqual(rejected_profiles + 1, oracle.profiles.load(.acquire));
}

test "Gmail draft HTTP: one verified session streams two encrypted files and rechecks before publishing" {
    const storage = @import("terminal/store.zig");
    const types = @import("terminal/types.zig");
    const catalog = @import("terminal/vault_catalog.zig");
    const vault_storage = @import("terminal/vault_storage.zig");
    const vault = @import("terminal/vault_types.zig");
    const links = @import("terminal/draft_link.zig");
    const Session = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        options: types.Options = .{ .fixtures = true },
        sealed: *catalog.Account,
        pub fn openStore(self: *@This(), allocator: std.mem.Allocator, address: []const u8, readonly: bool) !storage.Store {
            try std.testing.expectEqualStrings(account, address);
            return storage.Store.openVault(self.io, allocator, self.sealed, self.options, readonly);
        }
    };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var identity = try Identity.init(alloc);
    const scopes = try auth.scopesFor(alloc, &.{ "mail-read", "mail-drafts" });
    identity.grant = auth.grantIdentity(scopes);
    var draft_grants = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-client", .clientId = client_id, .grantId = &identity.grant, .capabilities = &.{ "mail-read", "mail-drafts" }, .scopes = scopes }};
    identity.registry = try j.encodeAlloc(alloc, auth.Registry{ .accounts = &draft_grants }, .{});
    const config = try alloc.create(Config);
    try config.defaults("/nonexistent/synthetic-home");
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .vault;
    config.runtime_provider = identity.provider();
    var oracle: Oracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .draft_flow = true };
    defer oracle.listener.deinit(io);
    http.TestRoute.origin = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(Oracle.run, .{&oracle});
    defer task.cancel(io) catch {};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    var key = try @import("terminal/vault_crypto.zig").createDataKey(io);
    defer key.wipe();
    const workspace = try alloc.create(vault.StreamWorkspace);
    const descriptor: @import("terminal/vault_header.zig").Header = .{ .vault_id = key.vault_id, .key_id = key.key_id, .root_record = try vault_storage.Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
    var owner = try catalog.Owner.create(io, try std.fmt.allocPrint(alloc, "{s}/sealed", .{base}), descriptor, &key, workspace);
    defer owner.close();
    try storage.Store.createVaultAccount(&owner, alloc, account, .{ .fixtures = true });
    var sealed = try owner.openAccount(account);
    defer sealed.close();
    var session: Session = .{ .io = io, .allocator = a, .sealed = &sealed };
    var store = try session.openStore(alloc, account, false);
    defer store.close();
    const source = try store.putDraft(.{ .subject = "Original", .bodyText = "# Local source", .bodyFormat = .markdown, .bcc = &.{.{ .address = "hidden@example.test" }} }, null);
    const digest = try links.contentDigest(alloc, source, account);
    store.state.draftLinks = try alloc.dupe(links.Link, &.{.{ .draftId = source.id, .phase = .linked, .remoteDraftId = "remote-draft", .remoteMessageId = "remote-message", .attemptMessageId = "<owned-upload@mail.invalid>", .uploadedDigest = &digest }});
    try store.save();
    var original_link = store.state.draftLinks[0];
    store.close();
    var network: @import("terminal/draft_gmail.zig").Session = undefined;
    try network.init(io, alloc, a, config, account, j.object(alloc));
    defer network.close();
    store = try session.openStore(alloc, account, false);
    var upload = try @import("terminal/draft_gmail_spool.zig").create(&store, source, "<owned-upload@mail.invalid>");
    store.release();
    const receipt = network.create(alloc, source, &upload) catch |err| {
        upload.close();
        return err;
    };
    upload.close();
    store.close();
    try std.testing.expectEqualStrings("remote-draft", receipt.draftId);
    try std.testing.expectEqual(@as(usize, 1), oracle.spools.load(.acquire));
    const request = try j.value(alloc, .{ .expectedRemoteMessageId = "remote-message" });
    var loaded = try @import("terminal/draft_gmail_import.zig").load(alloc, account, network.transport(), "remote-draft", "remote-message");
    const imported = try @import("terminal/draft_gmail_download.zig").run(&session, alloc, account, request, &network, original_link, loaded, false);
    try std.testing.expectEqual(@as(usize, 2), imported.attachments.len);
    try std.testing.expectEqualStrings("hidden@example.test", imported.bcc[0].address);
    try std.testing.expectEqual(@as(usize, 1), oracle.refreshes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), oracle.profiles.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), oracle.draft_status_reads.load(.acquire));
    store = try session.openStore(alloc, account, false);
    const kept = try store.draft(imported.id);
    for (kept.attachments, [_][]const u8{ "first", "second" }) |file, expected| {
        var stream = try @import("terminal/attachment_blob.zig").Stream.init(&store, file);
        defer stream.close();
        var buffer: [16]u8 = undefined;
        const count = try @import("terminal/attachment_blob.zig").Stream.read(&stream, &buffer);
        try std.testing.expectEqualStrings(expected, buffer[0..count]);
        try std.testing.expectEqual(@as(usize, 0), try @import("terminal/attachment_blob.zig").Stream.read(&stream, &buffer));
    }
    try std.testing.expectEqualStrings("# Local source", (try store.draft(source.id)).bodyText);
    original_link = store.state.draftLinks[links.find(store.state.draftLinks, source.id).?];
    const copy_link = store.state.draftLinks[links.find(store.state.draftLinks, imported.id).?];
    try std.testing.expect(original_link.paused and !copy_link.paused);
    store.close();
    oracle.draft_race.store(true, .release);
    oracle.draft_status_reads.store(0, .release);
    loaded = try @import("terminal/draft_gmail_import.zig").load(alloc, account, network.transport(), "remote-draft", "remote-message");
    try std.testing.expectError(error.GmailDraftChanged, @import("terminal/draft_gmail_download.zig").run(&session, alloc, account, request, &network, original_link, loaded, false));
    store = try session.openStore(alloc, account, false);
    try std.testing.expectEqual(@as(usize, 2), store.state.drafts.len);
    try std.testing.expectEqual(@as(usize, 2), store.state.draftLinks.len);
    try std.testing.expectEqual(@as(usize, 1), oracle.writes.load(.acquire));
}

// Full native dispatch through the production reusable heap and a loopback
// provider. All content and identities here are synthetic.
const SendMemoryOracle = struct {
    listener: std.Io.net.Server,
    original: []const u8,
    images: []const []const u8,
    writes: std.atomic.Value(usize) = .init(0),
    uploads: std.atomic.Value(usize) = .init(0),
    last_media_bytes: std.atomic.Value(usize) = .init(0),
    last_mime_bytes: std.atomic.Value(usize) = .init(0),
    refreshes: std.atomic.Value(usize) = .init(0),
    drop: std.atomic.Value(bool) = .init(false),
    rsvp: bool = false,
    source: ?[]const u8 = null,
    attachment_responses: ?[]const []const u8 = null,
    source_reads: std.atomic.Value(usize) = .init(0),
    attachment_reads: std.atomic.Value(usize) = .init(0),
    fn run(self: *SendMemoryOracle) !void {
        while (true) {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            self.respond(stream) catch |err| {
                std.debug.print("Synthetic send oracle failed: {s}\n", .{@errorName(err)});
                return err;
            };
        }
    }
    // Decode a MIME part independently of the application's MIME parser.
    fn part(allocator: std.mem.Allocator, raw: []const u8, header: []const u8) ![]const u8 {
        var cursor: usize = 0;
        return partAfter(allocator, raw, header, &cursor);
    }
    fn partAfter(allocator: std.mem.Allocator, raw: []const u8, header: []const u8, cursor: *usize) ![]const u8 {
        const offset = cursor.* + (std.mem.indexOf(u8, raw[cursor.*..], header) orelse return error.MissingSyntheticPart);
        const start = offset + (std.mem.indexOf(u8, raw[offset..], "\r\n\r\n") orelse return error.MissingSyntheticBody) + 4;
        const end = start + (std.mem.indexOf(u8, raw[start..], "\r\n--") orelse return error.MissingSyntheticBoundary);
        // One exact upper-bound buffer and one copy per RFC base64 line. The
        // oracle must not append every byte through a growing vector or scan
        // the preceding 35 MiB anew for each of the 146 independent images.
        const encoded = try allocator.alloc(u8, end - start);
        var length: usize = 0;
        var lines = std.mem.splitSequence(u8, raw[start..end], "\r\n");
        while (lines.next()) |line| {
            @memcpy(encoded[length..][0..line.len], line);
            length += line.len;
        }
        const decoded = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded[0..length]));
        try std.base64.standard.Decoder.decode(decoded, encoded[0..length]);
        cursor.* = end;
        return decoded;
    }
    fn attachmentResponse(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var prefix_bytes: [64]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_bytes, "{{\"size\":{d},\"data\":\"", .{data.len});
        const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(data.len);
        const response = try allocator.alloc(u8, prefix.len + encoded_len + 2);
        @memcpy(response[0..prefix.len], prefix);
        _ = std.base64.url_safe_no_pad.Encoder.encode(response[prefix.len..][0..encoded_len], data);
        @memcpy(response[response.len - 2 ..], "\"}");
        return response;
    }
    fn validateMime(self: *SendMemoryOracle, allocator: std.mem.Allocator, body: []const u8, multipart: bool) !void {
        var raw = body;
        if (multipart) {
            if (!self.rsvp) try std.testing.expect(std.mem.indexOf(u8, body, "\"threadId\":\"synthetic-thread\"") != null);
            // Isolate RFC822 bytes independently of the application's upload
            // builder. HTTP multipart metadata/delimiters are not MIME size.
            const first_line_end = std.mem.indexOf(u8, body, "\r\n") orelse return error.MissingSyntheticBoundary;
            const opening = body[0..first_line_end];
            try std.testing.expect(std.mem.startsWith(u8, opening, "--"));
            const suffix = try std.fmt.allocPrint(allocator, "\r\n{s}--\r\n", .{opening});
            try std.testing.expect(std.mem.endsWith(u8, body, suffix));
            const header = "Content-Type: message/rfc822\r\n\r\n";
            const start = (std.mem.indexOf(u8, body, header) orelse return error.MissingSyntheticMime) + header.len;
            const end = body.len - suffix.len;
            try std.testing.expect(start < end);
            raw = body[start..end];
        } else {
            const value = try std.json.parseFromSliceLeaky(j.Value, allocator, body, .{});
            const encoded = try j.required(value, "raw");
            const decoded = try allocator.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded));
            try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded);
            raw = decoded;
        }
        self.last_mime_bytes.store(raw.len, .release);
        if (self.rsvp) {
            try std.testing.expect(std.mem.indexOf(u8, raw, "From: <alias@example.test>\r\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, raw, "To: <host@example.test>\r\n") != null);
            const calendar = try part(allocator, raw, "Content-Type: text/calendar;");
            try std.testing.expect(std.mem.indexOf(u8, calendar, "METHOD:REPLY\r\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, calendar, ":mailto:alias@example.test\r\n") != null);
            return;
        }
        if (!(std.mem.indexOf(u8, raw, "In-Reply-To: <parent@example.test>\r\n") != null)) return error.MissingReplyHeader;
        if (!(std.mem.indexOf(u8, raw, "References: <ancestor@example.test>\r\n <parent@example.test>\r\n") != null)) return error.MissingReferencesHeader;
        if (!(std.mem.indexOf(u8, raw, "Bcc: <hidden@example.test>\r\n") != null)) return error.MissingBccHeader;
        const html = try part(allocator, raw, "Content-Type: text/html;");
        if (!(std.mem.indexOf(u8, html, self.original) != null)) return error.OriginalHtmlChanged;
        if (!(std.mem.indexOf(u8, html, "Authored synthetic opening") != null)) return error.MissingNoteOpening;
        if (!(std.mem.indexOf(u8, html, "Authored synthetic tail") != null)) return error.MissingNoteTail;
        const plain = try part(allocator, raw, "Content-Type: text/plain;");
        try std.testing.expect(std.mem.indexOf(u8, plain, "Authored synthetic opening") != null);
        if (!(std.mem.indexOf(u8, plain, "Original synthetic tail") != null)) return error.MissingOriginalPlainTail;
        try std.testing.expectEqual(self.images.len, std.mem.count(u8, raw, "Content-ID: <image-"));
        var cursor: usize = 0;
        for (self.images, 0..) |expected, index| {
            const header = try std.fmt.allocPrint(allocator, "Content-ID: <image-{d}@example.test>\r\n", .{index});
            try std.testing.expectEqualSlices(u8, expected, try partAfter(allocator, raw, header, &cursor));
        }
    }
    fn respond(self: *SendMemoryOracle, stream: std.Io.net.Stream) !void {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        var input: [8192]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, io, &input);
        var writer = std.Io.net.Stream.Writer.init(stream, io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        const path = try allocator.dupe(u8, request.head.target);
        const multipart = std.mem.startsWith(u8, request.head.content_type orelse "", "multipart/related;");
        const body = if (request.head.method.requestHasBody()) try request.readerExpectNone(&.{}).allocRemaining(allocator, .limited(36 * 1024 * 1024)) else "";
        var response: []const u8 = "{}";
        if (std.mem.eql(u8, path, "/oauth2.googleapis.com/token")) {
            _ = self.refreshes.fetchAdd(1, .acq_rel);
            response = if (self.rsvp) "{\"access_token\":\"synthetic-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send\"}" else "{\"access_token\":\"synthetic-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose\"}";
        } else if (std.mem.startsWith(u8, path, "/gmail.googleapis.com/gmail/v1/users/me/profile?")) {
            response = "{\"emailAddress\":\"self@example.test\"}";
        } else if (std.mem.indexOf(u8, path, "/settings/sendAs?") != null) {
            response = "{\"sendAs\":[{\"sendAsEmail\":\"self@example.test\",\"isPrimary\":true},{\"sendAsEmail\":\"alias@example.test\",\"verificationStatus\":\"accepted\"}]}";
        } else if (self.source != null and request.head.method == .GET) {
            _ = self.source_reads.fetchAdd(1, .acq_rel);
            if (std.mem.indexOf(u8, path, "/attachments/file-")) |at| {
                const tail = path[at + "/attachments/file-".len ..];
                const index = try std.fmt.parseInt(usize, tail[0 .. std.mem.indexOfScalar(u8, tail, '?') orelse tail.len], 10);
                try std.testing.expect(index < self.images.len);
                _ = self.attachment_reads.fetchAdd(1, .acq_rel);
                response = if (self.attachment_responses) |responses| responses[index] else try attachmentResponse(allocator, self.images[index]);
            } else response = self.source.?;
        } else {
            try std.testing.expectEqual(std.http.Method.POST, request.head.method);
            _ = self.writes.fetchAdd(1, .acq_rel);
            self.last_media_bytes.store(body.len, .release);
            try self.validateMime(allocator, body, multipart);
            if (std.mem.indexOf(u8, path, "/drafts?") != null) {
                _ = self.uploads.fetchAdd(1, .acq_rel);
                response = "{\"id\":\"remote-draft\",\"message\":{\"id\":\"remote-message\",\"threadId\":\"synthetic-thread\"}}";
            } else response = "{\"id\":\"synthetic-sent\",\"threadId\":\"synthetic-thread\"}";
            if (self.drop.load(.acquire)) return;
        }
        try request.respond(response, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    }
};
fn sendMemoryText(allocator: std.mem.Allocator, size: usize, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const bytes = try allocator.alloc(u8, size);
    @memset(bytes, 'x');
    @memcpy(bytes[0..prefix.len], prefix);
    @memcpy(bytes[size - suffix.len ..], suffix);
    return bytes;
}
fn sendMemoryCall(session: *@import("terminal/core.zig").Session, allocator: std.mem.Allocator, request: anytype) !j.Value {
    const bytes = try j.encodeAlloc(allocator, request, .{});
    const response = try session.execute(allocator, bytes);
    const value = try std.json.parseFromSliceLeaky(j.Value, allocator, response, .{});
    if (!try j.boolean(value, "ok", false)) {
        std.debug.print("Synthetic native request failed: {s}\n", .{response});
        return error.SyntheticNativeRequestFailed;
    }
    return j.get(value, "data") orelse error.MissingSyntheticReceipt;
}

fn sendMemoryScenario(html_bytes: usize, plain_bytes: usize, note_bytes: usize, encrypted: bool) !void {
    const types = @import("terminal/types.zig");
    const storage = @import("terminal/store.zig");
    const Core = @import("terminal/core.zig").Session;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var identity = try Identity.init(allocator);
    const scopes = try auth.scopesFor(allocator, &.{ "mail-read", "mail-send", "mail-drafts" });
    identity.grant = auth.grantIdentity(scopes);
    var grants = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-client", .clientId = client_id, .grantId = &identity.grant, .capabilities = &.{ "mail-read", "mail-send", "mail-drafts" }, .scopes = scopes }};
    identity.registry = try j.encodeAlloc(allocator, auth.Registry{ .accounts = &grants }, .{});
    const config = try allocator.create(Config);
    try config.defaults("/nonexistent/synthetic-send-home");
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .vault;
    config.runtime_provider = identity.provider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const root = try std.fmt.allocPrint(allocator, "{s}/cache", .{base});
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", base);
    const VaultOwner = @import("terminal/vault_owner.zig").Owner;
    const sealed_owner: ?*VaultOwner = if (encrypted) try a.create(VaultOwner) else null;
    defer if (sealed_owner) |owner| {
        owner.deinit();
        a.destroy(owner);
    };
    if (sealed_owner) |owner| {
        owner.* = try VaultOwner.init(io, a, &env, try std.fmt.allocPrint(allocator, "{s}/sealed", .{base}), .{});
        var directory = try @import("keyring_file.zig").directory(io, owner.path, true);
        directory.close(io);
        owner.key = try @import("terminal/vault_crypto.zig").createDataKey(io);
        const descriptor: @import("terminal/vault_header.zig").Header = .{ .vault_id = owner.key.vault_id, .key_id = owner.key.key_id, .root_record = try @import("terminal/vault_storage.zig").Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
        owner.catalog_owner = try @import("terminal/vault_catalog.zig").Owner.create(io, owner.data_path, descriptor, &owner.key, &owner.workspace);
        try storage.Store.createVaultAccount(&owner.catalog_owner.?, allocator, account, .{ .fixtures = true });
        owner.catalog_owner.?.live_enabled = true;
    }
    const original = try sendMemoryText(allocator, html_bytes, "<div><p>Original synthetic opening</p><p>", "</p><img src=\"cid:image-0@example.test\"><img src=\"cid:image-1@example.test\"><img src=\"cid:image-2@example.test\"><img src=\"cid:image-3@example.test\"><img src=\"cid:image-4@example.test\"><img src=\"cid:image-5@example.test\"><p>Original synthetic tail</p></div>");
    var images: [6][]const u8 = undefined;
    var resources: [6]types.Attachment = undefined;
    for (&images, &resources, 0..) |*image_bytes, *resource, index| {
        const data = try allocator.alloc(u8, 102480 + @as(usize, @intFromBool(index < 3)));
        for (data, 0..) |*byte, offset| byte.* = @truncate(offset *% 37 + index * 19);
        image_bytes.* = data;
        const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(data.len));
        resource.* = .{ .id = "", .filename = try std.fmt.allocPrint(allocator, "image-{d}.png", .{index}), .mimeType = "image/png", .size = data.len, .data = std.base64.url_safe_no_pad.Encoder.encode(encoded, data), .contentId = try std.fmt.allocPrint(allocator, "image-{d}@example.test", .{index}), .disposition = "inline" };
    }
    const draft: types.Draft = .{ .to = &.{.{ .address = "reader@example.test" }}, .bcc = &.{.{ .address = "hidden@example.test" }}, .subject = "Synthetic illustrated thread", .threadId = "synthetic-thread", .inReplyTo = "<parent@example.test>", .references = "<ancestor@example.test> <parent@example.test>", .bodyText = try sendMemoryText(allocator, note_bytes, "Authored synthetic opening\n\n", "\n\nAuthored synthetic tail"), .bodyFormat = .markdown, .original = .{ .sourceMessageId = "synthetic-source", .from = .{ .address = "peer@example.test" }, .subject = "Original synthetic thread", .bodyText = try sendMemoryText(allocator, plain_bytes, "Original synthetic opening\n", "\nOriginal synthetic tail"), .bodyHtml = original, .resources = &resources } };
    var draft_id: []const u8 = undefined;
    {
        var store = if (sealed_owner) |owner| try owner.openStore(allocator, account, false) else try storage.Store.open(io, allocator, root, account, .{});
        defer store.close();
        const entries = try allocator.alloc(storage.Entry, 620);
        const subject = try sendMemoryText(allocator, 1050, "Synthetic retained metadata ", " tail");
        for (entries, 0..) |*entry, index| entry.* = .{ .message = .{ .id = try std.fmt.allocPrint(allocator, "neighbor-{d}", .{index}), .threadId = "synthetic-neighbor-thread", .subject = subject, .receivedAt = @intCast(1000 - index), .labels = &.{"INBOX"} } };
        store.state.entries = entries;
        for (0..73) |_| _ = try store.putDraft(.{ .subject = "Other synthetic saved draft", .bodyText = "Retained local content" }, null);
        draft_id = (try store.putDraft(draft, null)).id;
        try store.save();
    }
    var oracle: SendMemoryOracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .original = original, .images = &images };
    defer oracle.listener.deinit(io);
    http.TestRoute.origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(SendMemoryOracle.run, .{&oracle});
    defer task.cancel(io) catch {};
    const reservation = try a.alloc(u8, @import("fixed_runtime.zig").application_reservation);
    defer a.free(reservation);
    var heap = @import("fixed_heap.zig").Heap.init(reservation);
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = heap.allocator(), .limit = types.Limits.runtime_bytes, .reservation_bytes = reservation.len };
    const session = try cap.allocator().create(Core);
    defer cap.allocator().destroy(session);
    try session.initInto(io, cap.allocator(), &env, .{ .cache_dir = root }, config);
    defer session.deinit();
    session.vault_owner = sealed_owner;
    // Model the concurrently retained TUI/view allocations sharing this heap.
    const retained_ui = try cap.allocator().alloc(u8, 8 * 1024 * 1024);
    defer cap.allocator().free(retained_ui);
    @memset(retained_ui, 0x5a);
    const baseline = cap.snapshot().allocatorUsedBytes;
    const result = try sendMemoryCall(session, allocator, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "synthetic-send" });
    if (!std.mem.eql(u8, "applied", j.text(result, "outcome"))) std.debug.print("Synthetic send failed: outcome={s} code={s} posts={d} fixedPeak={d} refusals={d}\n", .{ j.text(result, "outcome"), j.text(result, "errorCode"), oracle.writes.load(.acquire), cap.snapshot().allocatorPeakBytes, cap.snapshot().rejectedAllocations });
    try std.testing.expectEqualStrings("applied", j.text(result, "outcome"));
    try std.testing.expectEqual(@as(usize, 1), oracle.writes.load(.acquire));
    try std.testing.expectEqualStrings("synthetic-sent", j.text(result, "messageId"));
    const again = try sendMemoryCall(session, allocator, .{ .cmd = "draft.send", .account = account, .draftId = draft_id, .operationId = "synthetic-send" });
    try std.testing.expectEqualStrings("applied", j.text(again, "outcome"));
    try std.testing.expectEqual(@as(usize, 1), oracle.writes.load(.acquire));
    const preview = try sendMemoryCall(session, allocator, .{ .cmd = "draft.preview", .account = account, .draftId = draft_id });
    try std.testing.expect(std.mem.indexOf(u8, j.text(preview, "bodyHtml"), original) != null);
    // A completed source is immutable. Explicitly clone it for a new Gmail
    // draft; even oversized complete JSON never needs a request-frame copy.
    const copied = try sendMemoryCall(session, allocator, .{ .cmd = "draft.clone", .account = account, .draftId = draft_id });
    const copied_id = j.text(copied, "id");
    const info = try sendMemoryCall(session, allocator, .{ .cmd = "draft.gmail-info", .account = account, .draftId = copied_id });
    const saved = try sendMemoryCall(session, allocator, .{ .cmd = "draft.gmail-save", .account = account, .draftId = copied_id, .expectedVersion = 0, .expectedDigest = j.text(info, "contentDigest") });
    try std.testing.expectEqualStrings("linked", j.text(saved, "outcome"));
    try std.testing.expectEqual(@as(usize, 2), oracle.writes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), oracle.uploads.load(.acquire));
    // Reusing the verified access cache after two destroyed operation arenas
    // checks that no transient token/config borrow escaped into the Session.
    try std.testing.expectEqual(@as(usize, 1), oracle.refreshes.load(.acquire));
    var queued_id: []const u8 = undefined;
    var uncertain_id: []const u8 = undefined;
    var output_failure_id: []const u8 = undefined;
    var uncertain_upload_id: []const u8 = undefined;
    var invalid_id: []const u8 = undefined;
    {
        var store = if (sealed_owner) |owner| try owner.openStore(allocator, account, false) else try storage.Store.open(io, allocator, root, account, .{});
        defer store.close();
        queued_id = (try store.putDraft(draft, null)).id;
        uncertain_id = (try store.putDraft(draft, null)).id;
        output_failure_id = (try store.putDraft(draft, null)).id;
        uncertain_upload_id = (try store.putDraft(draft, null)).id;
        var invalid = draft;
        invalid.inReplyTo = "not-a-message-id";
        invalid_id = (try store.putDraft(invalid, null)).id;
    }
    const queued = try sendMemoryCall(session, allocator, .{ .cmd = "draft.queue", .account = account, .draftId = queued_id, .operationId = "synthetic-queued-send", .delaySeconds = 0 });
    const queued_result = try sendMemoryCall(session, allocator, .{ .cmd = "queue.send-now", .account = account, .queueId = j.text(queued, "queueId") });
    try std.testing.expectEqualStrings("applied", j.text(queued_result, "state"));
    try std.testing.expectEqual(@as(usize, 3), oracle.writes.load(.acquire));
    // The provider accepts, but the caller cannot allocate a response frame.
    // It must receive uncertainty, and the durable applied receipt prevents a
    // repeated operation from issuing another POST.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const output_request = try j.encodeAlloc(allocator, .{ .cmd = "draft.send", .account = account, .draftId = output_failure_id, .operationId = "synthetic-output-oom" }, .{});
    try std.testing.expectError(error.UnknownOutcome, session.execute(failing.allocator(), output_request));
    try std.testing.expectEqual(@as(usize, 4), oracle.writes.load(.acquire));
    const output_replay = try sendMemoryCall(session, allocator, .{ .cmd = "draft.send", .account = account, .draftId = output_failure_id, .operationId = "synthetic-output-oom" });
    try std.testing.expectEqualStrings("applied", j.text(output_replay, "outcome"));
    try std.testing.expectEqual(@as(usize, 4), oracle.writes.load(.acquire));
    // A verified MIME request reaches the server, which drops the receipt.
    // Both the same operation and a fresh operation ID stay fenced afterwards.
    oracle.drop.store(true, .release);
    const uncertain = try sendMemoryCall(session, allocator, .{ .cmd = "draft.send", .account = account, .draftId = uncertain_id, .operationId = "synthetic-lost-receipt" });
    try std.testing.expectEqualStrings("unknown", j.text(uncertain, "outcome"));
    try std.testing.expectEqualStrings("UnknownOutcome", j.text(uncertain, "errorCode"));
    try std.testing.expectEqual(@as(usize, 5), oracle.writes.load(.acquire));
    for ([_][]const u8{ "synthetic-lost-receipt", "synthetic-new-id" }) |operation| {
        const replay = try sendMemoryCall(session, allocator, .{ .cmd = "draft.send", .account = account, .draftId = uncertain_id, .operationId = operation });
        try std.testing.expectEqualStrings("unknown", j.text(replay, "outcome"));
    }
    try std.testing.expectEqual(@as(usize, 5), oracle.writes.load(.acquire));
    const upload_info = try sendMemoryCall(session, allocator, .{ .cmd = "draft.gmail-info", .account = account, .draftId = uncertain_upload_id });
    const upload_unknown = try sendMemoryCall(session, allocator, .{ .cmd = "draft.gmail-save", .account = account, .draftId = uncertain_upload_id, .expectedVersion = 0, .expectedDigest = j.text(upload_info, "contentDigest") });
    try std.testing.expectEqualStrings("unknown", j.text(upload_unknown, "outcome"));
    try std.testing.expectEqual(@as(usize, 6), oracle.writes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), oracle.uploads.load(.acquire));
    const upload_replay = try session.execute(allocator, try j.encodeAlloc(allocator, .{ .cmd = "draft.gmail-save", .account = account, .draftId = uncertain_upload_id, .expectedVersion = 1, .expectedDigest = j.text(upload_info, "contentDigest") }, .{}));
    const upload_replay_value = try std.json.parseFromSliceLeaky(j.Value, allocator, upload_replay, .{});
    try std.testing.expect(!try j.boolean(upload_replay_value, "ok", true));
    try std.testing.expectEqualStrings("GmailDraftOutcomeUnknown", j.text(j.get(upload_replay_value, "error").?, "code"));
    try std.testing.expectEqual(@as(usize, 6), oracle.writes.load(.acquire));
    const invalid_response = try session.execute(allocator, try j.encodeAlloc(allocator, .{ .cmd = "draft.send", .account = account, .draftId = invalid_id, .operationId = "synthetic-invalid" }, .{}));
    const invalid_value = try std.json.parseFromSliceLeaky(j.Value, allocator, invalid_response, .{});
    try std.testing.expect(!try j.boolean(invalid_value, "ok", true));
    try std.testing.expectEqual(@as(usize, 6), oracle.writes.load(.acquire));
    {
        var store = if (sealed_owner) |owner| try owner.openStore(allocator, account, false) else try storage.Store.open(io, allocator, root, account, .{});
        defer store.close();
        try std.testing.expectEqual(@as(usize, 620), store.state.entries.len);
        try std.testing.expectEqualStrings(draft.bodyText, (try store.draft(uncertain_id)).bodyText);
        for (store.state.operations) |operation| try std.testing.expect(!std.mem.eql(u8, operation.id, "synthetic-invalid"));
        var entries = store.dir.iterate();
        while (try entries.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, "send-spool-"));
    }
    try std.testing.expectEqual(@as(usize, 0), @import("terminal/send_memory.zig").snapshot().allocatorUsedBytes);
    try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
    try std.testing.expectEqual(baseline, cap.snapshot().allocatorUsedBytes);
    std.debug.print("native send memory compiler={s} optimize={s} originalHtml={d} fixedPeak={d} outgoingPeak={d} outgoingRetained={d} posts={d}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), html_bytes, cap.snapshot().allocatorPeakBytes, @import("terminal/send_memory.zig").snapshot().allocatorPeakBytes, @import("terminal/send_memory.zig").snapshot().allocatorUsedBytes, oracle.writes.load(.acquire) });
}

test "native send memory HTTP: realistic illustrated thread survives preparation and provider dispatch" {
    try sendMemoryScenario(32288, 6773, 6642, false);
}

test "native send memory HTTP: long illustrated thread exceeds JSON wire frames and preserves saved source" {
    try sendMemoryScenario(1200 * 1024, 1200 * 1024, 100 * 1024, false);
}

test "native send memory HTTP: encrypted store preserves uncertain receipts and releases sealed spools" {
    try sendMemoryScenario(32288, 6773, 6642, true);
}

test "native send memory HTTP: RSVP spool preserves the verified alias and calendar-only send capability" {
    const storage = @import("terminal/store.zig");
    const Core = @import("terminal/core.zig").Session;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var identity = try Identity.init(allocator);
    const scopes = try auth.scopesFor(allocator, &.{ "mail-read", "calendar-rsvp" });
    identity.grant = auth.grantIdentity(scopes);
    var grants = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-client", .clientId = client_id, .grantId = &identity.grant, .capabilities = &.{ "mail-read", "calendar-rsvp" }, .scopes = scopes }};
    identity.registry = try j.encodeAlloc(allocator, auth.Registry{ .accounts = &grants }, .{});
    const config = try allocator.create(Config);
    try config.defaults("/nonexistent/synthetic-rsvp-home");
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .vault;
    config.runtime_provider = identity.provider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const root = try std.fmt.allocPrint(allocator, "{s}/cache", .{base});
    {
        var store = try storage.Store.open(io, allocator, root, account, .{});
        defer store.close();
        try store.put(.{ .id = "synthetic-invitation", .threadId = "synthetic-invitation-thread", .subject = "Synthetic invitation", .bodyText = "Synthetic invitation body", .invitation = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:synthetic-alias-rsvp\r\nDTSTAMP:20261023T100000Z\r\nDTSTART:20261101T120000Z\r\nDTEND:20261101T130000Z\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:alias@example.test\r\nSUMMARY:Synthetic meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" }, true);
        try store.save();
    }
    var oracle: SendMemoryOracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .original = "", .images = &.{}, .rsvp = true };
    defer oracle.listener.deinit(io);
    http.TestRoute.origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(SendMemoryOracle.run, .{&oracle});
    defer task.cancel(io) catch {};
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", base);
    const session = try allocator.create(Core);
    try session.initInto(io, allocator, &env, .{ .cache_dir = root }, config);
    defer session.deinit();
    for (0..2) |_| {
        const result = try sendMemoryCall(session, allocator, .{ .cmd = "invitation.reply", .account = account, .messageId = "synthetic-invitation", .status = "accepted", .operationId = "synthetic-rsvp", .attendee = "alias@example.test" });
        try std.testing.expectEqualStrings("applied", j.text(result, "outcome"));
        try std.testing.expectEqual(@as(usize, 1), oracle.writes.load(.acquire));
    }
    try std.testing.expectEqual(@as(usize, 0), @import("terminal/send_memory.zig").snapshot().allocatorUsedBytes);
}

// The source is fetched through the real native provider adapter at every
// stage. Repeated replies add seven screenshots, crossing 32,64 and128 files;
// final wire approaches Gmail's35MiB ceiling while JSON carries only handles.
/// One persistent conversation, including every production capture and all
/// accumulated local drafts/blobs. The mandatory native-send stress target
/// gives this 21-stage sequence its own bounded deadline; ordinary correctness
/// tests keep their existing per-test limit and do not depend on test order.
pub fn growingNativeThreadScenario() !void {
    const started = std.Io.Timestamp.now(io, .awake);
    const types = @import("terminal/types.zig");
    const Core = @import("terminal/core.zig").Session;
    var outer: std.heap.ArenaAllocator = .init(a);
    defer outer.deinit();
    const alloc = outer.allocator();
    var identity = try Identity.init(alloc);
    const scopes = try auth.scopesFor(alloc, &.{ "mail-read", "mail-send", "mail-drafts" });
    identity.grant = auth.grantIdentity(scopes);
    var grants = [_]auth.Grant{.{ .account = account, .clientFile = "synthetic-client", .clientId = client_id, .grantId = &identity.grant, .capabilities = &.{ "mail-read", "mail-send", "mail-drafts" }, .scopes = scopes }};
    identity.registry = try j.encodeAlloc(alloc, auth.Registry{ .accounts = &grants }, .{});
    const config = try alloc.create(Config);
    try config.defaults("/nonexistent/synthetic-growing-thread");
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .vault;
    config.runtime_provider = identity.provider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", base);
    var images: [146][]const u8 = undefined;
    var image_digests: [146][32]u8 = undefined;
    var image_identities: std.AutoHashMap([32]u8, void) = .init(alloc);
    defer image_identities.deinit();
    var attachment_responses: [146][]const u8 = undefined;
    for (&images, 0..) |*image_bytes, index| {
        const bytes = try alloc.alloc(u8, 160000);
        // A valid synthetic PNG with a large ancillary text chunk. Every
        // image remains displayable, and its byte identity is independent.
        const png = @import("terminal/markdown_logo.zig").png;
        const prefix = png.len - 12; // retain original IEND after the new chunk
        @memcpy(bytes[0..prefix], png[0..prefix]);
        const payload_size = bytes.len - png.len - 12;
        std.mem.writeInt(u32, bytes[prefix..][0..4], @intCast(payload_size), .big);
        @memcpy(bytes[prefix + 4 ..][0..4], "tEXt");
        const payload = bytes[prefix + 8 ..][0..payload_size];
        for (payload, 0..) |*byte, offset| byte.* = @intCast('A' + (offset + index) % 26);
        @memcpy(payload[0..10], "Synthetic\x00");
        // The repeating alphabet alone aliases every26 images. Give every
        // screenshot its own valid Latin-1 text identity before computingCRC.
        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, @intCast(index), .big);
        @memcpy(payload[10..][0..8], &std.fmt.bytesToHex(index_bytes, .lower));
        const crc = std.hash.Crc32.hash(bytes[prefix + 4 ..][0 .. 4 + payload_size]);
        std.mem.writeInt(u32, bytes[prefix + 8 + payload_size ..][0..4], crc, .big);
        @memcpy(bytes[bytes.len - 12 ..], png[prefix..]);
        image_bytes.* = bytes;
        std.crypto.hash.sha2.Sha256.hash(bytes, &image_digests[index], .{});
        try std.testing.expect(!(try image_identities.getOrPut(image_digests[index])).found_existing);
        // Every round still downloads every selected image through the real
        // HTTP adapter. Only the immutable provider fixture representation is
        // reused, instead of re-encoding it for all 1,596 attachment GETs.
        attachment_responses[index] = try SendMemoryOracle.attachmentResponse(alloc, bytes);
    }
    try std.testing.expectEqual(@as(usize, 146), image_identities.count());
    var oracle: SendMemoryOracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .original = "", .images = &images, .attachment_responses = &attachment_responses };
    defer oracle.listener.deinit(io);
    http.TestRoute.origin = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(SendMemoryOracle.run, .{&oracle});
    defer task.cancel(io) catch {};
    const reservation = try a.alloc(u8, @import("fixed_runtime.zig").application_reservation);
    defer a.free(reservation);
    var heap = @import("fixed_heap.zig").Heap.init(reservation);
    var cap: @import("terminal/capped_allocator.zig").CappedAllocator = .{ .backing = heap.allocator(), .limit = types.Limits.runtime_bytes, .reservation_bytes = reservation.len };
    const session = try cap.allocator().create(Core);
    defer cap.allocator().destroy(session);
    try session.initInto(io, cap.allocator(), &env, .{ .cache_dir = try std.fmt.allocPrint(alloc, "{s}/cache", .{base}) }, config);
    defer session.deinit();
    const held_ui = try cap.allocator().alloc(u8, 8 * 1024 * 1024);
    defer cap.allocator().free(held_ui);
    @memset(held_ui, 0xa5);
    const fixed_baseline = cap.snapshot().allocatorUsedBytes;
    var expected_attachment_reads: usize = 0;
    for (0..21) |round| {
        var phase: std.heap.ArenaAllocator = .init(a);
        defer phase.deinit();
        const temp = phase.allocator();
        const count = 6 + 7 * round;
        expected_attachment_reads += count;
        var suffix: std.Io.Writer.Allocating = .init(temp);
        for (0..count) |index| try suffix.writer.print("<img src=\"cid:image-{d}@example.test\">", .{index});
        try suffix.writer.writeAll("<p>Original synthetic tail</p></div>");
        const html = try sendMemoryText(temp, if (round == 20) 3 * 1024 * 1024 else 32288 + round * 16384, "<div><p>Original synthetic opening</p>", suffix.written());
        const plain = try sendMemoryText(temp, 6773 + round * 1500, "Original synthetic opening\n", "\nOriginal synthetic tail");
        const html64 = try temp.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(html.len));
        const plain64 = try temp.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(plain.len));
        var parts: j.Value = .{ .array = .init(temp) };
        try parts.array.append(try j.value(temp, .{ .mimeType = "text/plain", .body = .{ .size = plain.len, .data = std.base64.url_safe_no_pad.Encoder.encode(plain64, plain) } }));
        try parts.array.append(try j.value(temp, .{ .mimeType = "text/html", .body = .{ .size = html.len, .data = std.base64.url_safe_no_pad.Encoder.encode(html64, html) } }));
        for (0..count) |index| try parts.array.append(try j.value(temp, .{ .partId = try std.fmt.allocPrint(temp, "part-{d}", .{index}), .mimeType = "image/png", .filename = try std.fmt.allocPrint(temp, "image-{d}.png", .{index}), .headers = .{ .{ .name = "Content-ID", .value = try std.fmt.allocPrint(temp, "<image-{d}@example.test>", .{index}) }, .{ .name = "Content-Disposition", .value = "inline" } }, .body = .{ .size = images[index].len, .attachmentId = try std.fmt.allocPrint(temp, "file-{d}", .{index}) } }));
        oracle.source = try j.encodeAlloc(temp, .{ .id = "synthetic-source", .threadId = "synthetic-thread", .internalDate = "1", .labelIds = .{"INBOX"}, .payload = .{ .mimeType = "multipart/related", .headers = .{ .{ .name = "From", .value = "reader@example.test" }, .{ .name = "To", .value = account }, .{ .name = "Subject", .value = "Accumulating screenshot conversation" }, .{ .name = "Message-ID", .value = "<parent@example.test>" }, .{ .name = "References", .value = "<ancestor@example.test>" } }, .parts = parts } }, .{});
        oracle.original = html;
        oracle.images = images[0..count];
        // This is the TUI's source chooser, before the reply exists locally.
        const source = try sendMemoryCall(session, temp, .{ .cmd = "mail.compose-source", .account = account, .messageId = "synthetic-source" });
        try std.testing.expectEqualStrings(html, j.text(source, "bodyHtml"));
        const descriptors = j.get(source, "attachments").?.array.items;
        try std.testing.expectEqual(count, descriptors.len);
        for (descriptors) |descriptor| try std.testing.expectEqual(@as(usize, 0), j.text(descriptor, "data").len);
        const created = try sendMemoryCall(session, temp, .{ .cmd = "mail.reply", .account = account, .messageId = "synthetic-source", .preserveFormatting = true, .bodyFormat = "markdown" });
        const id = j.text(created, "id");
        const original = j.get(created, "original").?;
        try std.testing.expectEqualStrings(html, j.text(original, "bodyHtml"));
        const resources = j.get(original, "resources").?.array.items;
        try std.testing.expectEqual(count, resources.len);
        for (resources, 0..) |resource, index| {
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(image_digests[index], .lower), j.text(resource, "blobId"));
            try std.testing.expectEqual(@as(usize, 0), j.text(resource, "data").len);
        }
        const note = "Authored synthetic opening\n\nAnother reply retains every screenshot.\n\nAuthored synthetic tail";
        const update = try j.encodeAlloc(temp, .{ .cmd = "draft.update", .account = account, .draftId = id, .acknowledgementOnly = true, .draft = .{ .to = .{.{ .address = "reader@example.test" }}, .bcc = .{.{ .address = "hidden@example.test" }}, .subject = "Growing source", .bodyText = note, .threadId = "synthetic-thread", .inReplyTo = "<parent@example.test>", .references = "<ancestor@example.test> <parent@example.test>" } }, .{});
        try std.testing.expect(update.len < 1024);
        const updated = try session.execute(temp, update);
        try std.testing.expect(try j.boolean(try std.json.parseFromSliceLeaky(j.Value, temp, updated, .{}), "ok", false));
        const reopened = try sendMemoryCall(session, temp, .{ .cmd = "draft.read", .account = account, .draftId = id });
        const reopened_original = j.get(reopened, "original").?;
        try std.testing.expectEqualStrings(html, j.text(reopened_original, "bodyHtml"));
        const reopened_resources = j.get(reopened_original, "resources").?.array.items;
        try std.testing.expectEqual(count, reopened_resources.len);
        for (reopened_resources, 0..) |resource, index| try std.testing.expectEqualStrings(&std.fmt.bytesToHex(image_digests[index], .lower), j.text(resource, "blobId"));
        const preview = try sendMemoryCall(session, temp, .{ .cmd = "draft.preview", .account = account, .draftId = id });
        try std.testing.expect(std.mem.indexOf(u8, j.text(preview, "bodyHtml"), html) != null);
        if (round % 5 == 0) std.debug.print("growing native progress round={d} resources={d} elapsedMs={d}\n", .{ round + 1, count, started.untilNow(io, .awake).toMilliseconds() });
        if (round == 20) {
            // Exercise the private standalone preview renderer without ever
            // launching a browser. Every retained image must be embedded.
            {
                var store = try session.openStore(temp, account, false);
                defer store.close();
                var iterator = store.dir.iterate();
                var persisted_blobs: usize = 0;
                while (try iterator.next(io)) |entry| if (std.mem.startsWith(u8, entry.name, "blob-") and std.mem.endsWith(u8, entry.name, ".bin")) {
                    persisted_blobs += 1;
                };
                try std.testing.expectEqual(count, persisted_blobs);
                const loaded = try store.draft(id);
                const prepared = try @import("terminal/markdown_mail.zig").prepare(temp, loaded);
                const preview_file = @import("terminal/preview_file.zig");
                try store.reserveBytes(try preview_file.byteSizeWithStore(&store, prepared, loaded));
                const file = try preview_file.writePreviewWithStore(&store, temp, prepared, loaded);
                const exported = try @import("terminal/files.zig").readBounded(io, temp, std.Io.Dir.cwd(), file.path, preview_file.max_file_bytes);
                try std.testing.expectEqual(count + @intFromBool(prepared.logoOffset != null), std.mem.count(u8, exported, "data:image/png;base64,"));
                try std.testing.expect(std.mem.indexOf(u8, exported, "Original synthetic tail") != null);
            }
            const sent = try sendMemoryCall(session, temp, .{ .cmd = "draft.send", .account = account, .draftId = id, .operationId = "growing-thread-final-send" });
            try std.testing.expectEqualStrings("applied", j.text(sent, "outcome"));
            try std.testing.expect(oracle.last_mime_bytes.load(.acquire) > 34 * 1024 * 1024);
            try std.testing.expect(oracle.last_mime_bytes.load(.acquire) <= types.Limits.mime_upload_bytes);
            const repeated = try sendMemoryCall(session, temp, .{ .cmd = "draft.send", .account = account, .draftId = id, .operationId = "growing-thread-final-send" });
            try std.testing.expectEqualStrings("applied", j.text(repeated, "outcome"));
            const refused_raw = try session.execute(temp, try j.encodeAlloc(temp, .{ .cmd = "draft.gmail-save", .account = account, .draftId = id, .expectedVersion = 0 }, .{}));
            const refused = try std.json.parseFromSliceLeaky(j.Value, temp, refused_raw, .{});
            try std.testing.expectEqualStrings("ArchivedDraftReadOnly", j.text(j.get(refused, "error").?, "code"));
            try std.testing.expectEqual(@as(usize, 0), oracle.uploads.load(.acquire));
            const copied = try sendMemoryCall(session, temp, .{ .cmd = "draft.clone", .account = account, .draftId = id });
            const copied_id = j.text(copied, "id");
            const info = try sendMemoryCall(session, temp, .{ .cmd = "draft.gmail-info", .account = account, .draftId = copied_id });
            const uploaded = try sendMemoryCall(session, temp, .{ .cmd = "draft.gmail-save", .account = account, .draftId = copied_id, .expectedVersion = 0, .expectedDigest = j.text(info, "contentDigest") });
            try std.testing.expectEqualStrings("linked", j.text(uploaded, "outcome"));
            try std.testing.expect(oracle.last_mime_bytes.load(.acquire) > 34 * 1024 * 1024);
            try std.testing.expect(oracle.last_mime_bytes.load(.acquire) <= types.Limits.mime_upload_bytes);
            try std.testing.expect(oracle.last_media_bytes.load(.acquire) > oracle.last_mime_bytes.load(.acquire));
            try std.testing.expect(oracle.last_media_bytes.load(.acquire) < types.Limits.mime_upload_bytes + 4096);
            try std.testing.expectEqual(@as(usize, 2), oracle.writes.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), oracle.uploads.load(.acquire));
            // The provider ceiling is a real refusal before submission. The
            // full create request also exceeds the old3MiB frame limit.
            var over_limit: types.Draft = undefined;
            {
                var store = try session.openStore(temp, account, false);
                defer store.close();
                over_limit = try store.draft(id);
            }
            over_limit.id = "";
            over_limit.bodyText = try sendMemoryText(temp, 1024 * 1024, "Authored synthetic opening\n", "\nAuthored synthetic tail");
            const over = try sendMemoryCall(session, temp, .{ .cmd = "draft.create", .account = account, .draft = over_limit, .acknowledgementOnly = true });
            const rejected_raw = try session.execute(temp, try j.encodeAlloc(temp, .{ .cmd = "draft.send", .account = account, .draftId = j.text(over, "id"), .operationId = "over-provider-ceiling" }, .{}));
            const rejected = try std.json.parseFromSliceLeaky(j.Value, temp, rejected_raw, .{});
            try std.testing.expect(!try j.boolean(rejected, "ok", true));
            try std.testing.expectEqualStrings("MessageTooLarge", j.text(j.get(rejected, "error").?, "code"));
            try std.testing.expectEqual(@as(usize, 2), oracle.writes.load(.acquire));
            var store = try session.openStore(temp, account, false);
            defer store.close();
            for (store.state.operations) |operation| try std.testing.expect(!std.mem.eql(u8, operation.id, "over-provider-ceiling"));
        }
        try std.testing.expectEqual(@as(usize, 0), @import("terminal/send_memory.zig").snapshot().allocatorUsedBytes);
        try std.testing.expectEqual(fixed_baseline, cap.snapshot().allocatorUsedBytes);
        try std.testing.expectEqual(@as(usize, 0), cap.snapshot().rejectedAllocations);
        try std.testing.expectEqual(expected_attachment_reads, oracle.attachment_reads.load(.acquire));
        oracle.source = null;
    }
    std.debug.print("growing native thread compiler={s} optimize={s} rounds=21 resources=146 uniqueBlobs={d} decodedImages={d} mimeBytes={d} httpMediaBytes={d} fixedPeak={d} transientPeak={d} posts={d} attachmentGets={d} elapsedMs={d}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), image_identities.count(), 146 * 160000, oracle.last_mime_bytes.load(.acquire), oracle.last_media_bytes.load(.acquire), cap.snapshot().allocatorPeakBytes, @import("terminal/send_memory.zig").snapshot().allocatorPeakBytes, oracle.writes.load(.acquire), oracle.attachment_reads.load(.acquire), started.untilNow(io, .awake).toMilliseconds() });
}

pub fn retainedSendLifecycle(encrypted: bool, many_blobs: bool) !void {
    const operation_count: usize = if (many_blobs) 6 else 1001;
    const storage = @import("terminal/store.zig");
    const Core = @import("terminal/core.zig").Session;
    const VaultOwner = @import("terminal/vault_owner.zig").Owner;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var identity = try Identity.init(allocator);
    const config = try allocator.create(Config);
    try config.defaults("/nonexistent/synthetic-history-home");
    config.count = 1;
    try config.accounts[0].address.set(account);
    config.credential_store = .vault;
    config.runtime_provider = identity.provider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const root = try std.fmt.allocPrint(allocator, "{s}/cache", .{base});
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", base);
    const sealed_owner: ?*VaultOwner = if (encrypted) try a.create(VaultOwner) else null;
    defer if (sealed_owner) |owner| {
        owner.deinit();
        a.destroy(owner);
    };
    if (sealed_owner) |owner| {
        owner.* = try VaultOwner.init(io, a, &env, try std.fmt.allocPrint(allocator, "{s}/sealed", .{base}), .{});
        var directory = try @import("keyring_file.zig").directory(io, owner.path, true);
        directory.close(io);
        owner.key = try @import("terminal/vault_crypto.zig").createDataKey(io);
        const descriptor: @import("terminal/vault_header.zig").Header = .{ .vault_id = owner.key.vault_id, .key_id = owner.key.key_id, .root_record = try @import("terminal/vault_storage.zig").Handle.create(io), .password = @splat(0), .recovery = @splat(0) };
        owner.catalog_owner = try @import("terminal/vault_catalog.zig").Owner.create(io, owner.data_path, descriptor, &owner.key, &owner.workspace);
        try storage.Store.createVaultAccount(&owner.catalog_owner.?, allocator, account, .{ .fixtures = true });
        owner.catalog_owner.?.live_enabled = true;
    }
    var oracle: Oracle = .{ .listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .kernel_backlog = 4 }), .write_status = .init(200), .history_flow = true, .history_blob_flow = many_blobs };
    defer oracle.listener.deinit(io);
    http.TestRoute.origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{oracle.listener.socket.address.getPort()});
    defer http.TestRoute.origin = null;
    var task = try io.concurrent(Oracle.run, .{&oracle});
    var oracle_joined = false;
    defer if (!oracle_joined) task.cancel(io) catch {};
    const session = try a.create(Core);
    defer a.destroy(session);
    try session.initInto(io, a, &env, .{ .cache_dir = root }, config);
    defer session.deinit();
    session.vault_owner = sealed_owner;
    const types = @import("terminal/types.zig");
    var broad: [40]types.Address = undefined;
    var files: [40]types.Attachment = undefined;
    for (&broad, &files, 0..) |*destination, *attachment, index| {
        destination.* = .{ .address = try std.fmt.allocPrint(allocator, "peer-{d}@example.test", .{index}) };
        attachment.* = .{ .id = try std.fmt.allocPrint(allocator, "file-{d}", .{index}), .filename = try std.fmt.allocPrint(allocator, "tiny-{d}.txt", .{index}), .mimeType = "text/plain", .size = 1, .data = "eA" };
    }
    var first_draft: []const u8 = "";
    var first_hash: []const u8 = "";
    var imported_files: usize = 0;
    for (0..operation_count) |index| {
        var phase: std.heap.ArenaAllocator = .init(a);
        defer phase.deinit();
        const alloc = phase.allocator();
        const file_count: usize = if (!many_blobs) 0 else if (index == 0) 40 else if (index <= 4) 1000 else if (index == 5) 57 else 0;
        const selected_files = if (index == 0) @as([]types.Attachment, &files) else try alloc.alloc(types.Attachment, file_count);
        const descriptor_allocator = if (index == 0) allocator else alloc;
        if (many_blobs) for (selected_files) |*file| {
            var file_arena: std.heap.ArenaAllocator = .init(a);
            defer file_arena.deinit();
            var store = try session.openStore(file_arena.allocator(), account, false);
            defer store.close();
            var content: [4]u8 = undefined;
            std.mem.writeInt(u32, &content, @intCast(imported_files), .little);
            var incoming = try @import("terminal/attachment_blob.zig").Incoming.create(&store, content.len);
            defer incoming.close();
            try incoming.write(&content);
            try incoming.finish(content.len);
            file.* = try incoming.commit(&store, .{ .id = try std.fmt.allocPrint(descriptor_allocator, "file-{d}", .{imported_files}), .filename = try std.fmt.allocPrint(descriptor_allocator, "tiny-{d}.bin", .{imported_files}), .mimeType = "application/octet-stream", .size = content.len });
            file.blobId = try descriptor_allocator.dupe(u8, file.blobId.?);
            imported_files += 1;
            if (imported_files % 512 == 0) std.debug.print("retained blob progress encrypted={} imported={d}\n", .{ encrypted, imported_files });
            if (encrypted) try std.testing.expectEqual(@as(usize, 0), store.vaultBlobCount());
        };
        const result = try sendMemoryCall(session, alloc, .{ .cmd = "mail.send", .account = account, .operationId = try std.fmt.allocPrint(alloc, "history-operation-{d}", .{index}), .draft = .{ .to = if (index == 0) @as([]const types.Address, &broad) else @as([]const types.Address, &.{.{ .address = "peer@example.test" }}), .attachments = selected_files, .bodyText = try std.fmt.allocPrint(alloc, "Synthetic exact spool body {d}", .{index}) } });
        try std.testing.expectEqualStrings("applied", j.text(result, "outcome"));
        if ((index + 1) % 250 == 0 or many_blobs) std.debug.print("retained send progress encrypted={} accepted={d}/{d}\n", .{ encrypted, index + 1, operation_count });
        if (index == 0) {
            first_draft = try allocator.dupe(u8, j.text(result, "draftId"));
            first_hash = try allocator.dupe(u8, j.text(result, "hash"));
        }
    }
    try std.testing.expectEqual(@as(usize, if (many_blobs) 4097 else 0), imported_files);
    try std.testing.expectEqual(imported_files, oracle.verified_history_files.load(.acquire));
    if (many_blobs) {
        var store = try session.openStore(allocator, account, false);
        defer store.close();
        try @import("terminal/operation_history.zig").compact(&store, true);
    }
    try std.testing.expectEqual(operation_count, oracle.writes.load(.acquire));
    try std.testing.expectEqual(operation_count, oracle.spools.load(.acquire));
    session.deinit();
    try session.initInto(io, a, &env, .{ .cache_dir = root }, config);
    session.vault_owner = sealed_owner;
    const original = try sendMemoryCall(session, allocator, .{ .cmd = "operation.read", .account = account, .operationId = "history-operation-0" });
    try std.testing.expectEqualStrings(first_hash, j.text(original, "hash"));
    _ = try sendMemoryCall(session, allocator, .{ .cmd = "mail.send", .account = account, .operationId = "history-operation-0", .draft = .{ .to = &broad, .attachments = &files, .bodyText = "Synthetic exact spool body 0" } });
    try std.testing.expectEqual(operation_count, oracle.writes.load(.acquire));
    const conflict = try session.execute(allocator, try j.encodeAlloc(allocator, .{ .cmd = "mail.send", .account = account, .operationId = "history-operation-0", .draft = .{ .to = "peer@example.test", .bodyText = "Changed content" } }, .{}));
    const conflict_value = try std.json.parseFromSliceLeaky(j.Value, allocator, conflict, .{});
    try std.testing.expectEqualStrings("OperationConflict", j.text(j.get(conflict_value, "error").?, "code"));
    try std.testing.expectEqual(operation_count, oracle.writes.load(.acquire));
    const recovered = try sendMemoryCall(session, allocator, .{ .cmd = "draft.read", .account = account, .draftId = first_draft });
    try std.testing.expectEqualStrings("Synthetic exact spool body 0", j.text(recovered, "bodyText"));
    try std.testing.expectEqual(@as(usize, 40), j.get(recovered, "to").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 40), j.get(recovered, "attachments").?.array.items.len);
    _ = try sendMemoryCall(session, allocator, .{ .cmd = "cache.clear", .account = account });
    if (many_blobs) {
        const shared = try sendMemoryCall(session, allocator, .{ .cmd = "draft.create", .account = account, .draft = .{ .to = "peer@example.test", .bodyText = "Unsent shared file pin", .attachments = files[0..1] } });
        {
            var store = try session.openStore(allocator, account, false);
            defer store.close();
            try std.testing.expectEqual(@as(usize, 4097), (try store.blobStats()).count);
            try @import("terminal/attachment_blob.zig").verify(&store, files[0]);
            try std.testing.expectError(error.AttachmentInUse, @import("terminal/attachment_blob.zig").discard(&store, files[0].blobId.?));
        }
        const deleted = try sendMemoryCall(session, allocator, .{ .cmd = "history.delete-source", .account = account, .draftId = first_draft, .confirm = true, .discardFiles = true });
        try std.testing.expectEqual(@as(i64, 39), try j.integer(deleted, "filesDeleted", 0));
        {
            var store = try session.openStore(allocator, account, false);
            defer store.close();
            try @import("terminal/attachment_blob.zig").verify(&store, files[0]);
            try std.testing.expectEqual(@as(usize, 4097 - 39), (try store.blobStats()).count);
        }
        _ = try sendMemoryCall(session, allocator, .{ .cmd = "draft.discard", .account = account, .draftId = j.text(shared, "id") });
        const pruned = try sendMemoryCall(session, allocator, .{ .cmd = "history.delete-source", .account = account, .draftId = first_draft, .confirm = true, .discardFiles = true });
        try std.testing.expectEqual(@as(i64, 1), try j.integer(pruned, "filesDeleted", 0));
    } else _ = try sendMemoryCall(session, allocator, .{ .cmd = "history.delete-source", .account = account, .draftId = first_draft, .confirm = true });
    _ = try sendMemoryCall(session, allocator, .{ .cmd = "draft.send", .account = account, .draftId = first_draft, .operationId = "history-operation-0" });
    try std.testing.expectEqual(operation_count, oracle.writes.load(.acquire));
    // A genuine ambiguous provider completion remains active through explicit
    // compaction/restart and cannot be retried under a fresh operation ID.
    oracle.drop_write.store(true, .release);
    const uncertain = try sendMemoryCall(session, allocator, .{ .cmd = "mail.send", .account = account, .operationId = "history-unknown", .draft = .{ .to = "peer@example.test", .bodyText = "Synthetic exact spool body uncertain" } });
    try std.testing.expectEqualStrings("unknown", j.text(uncertain, "outcome"));
    oracle.drop_write.store(false, .release);
    {
        var store = try session.openStore(allocator, account, false);
        defer store.close();
        try @import("terminal/operation_history.zig").compact(&store, true);
        try std.testing.expectEqual(@as(usize, 1), store.state.operations.len);
        try std.testing.expectEqualStrings("history-unknown", store.state.operations[0].id);
        try std.testing.expectEqual(@as(usize, 1), store.state.drafts.len);
        try std.testing.expectEqual(@as(u64, operation_count), store.state.history.operations);
        try std.testing.expectEqual(@as(usize, 0), store.state.outbox.len);
        if (encrypted) try std.testing.expect(store.vaultObjects.len < 8);
    }
    _ = try sendMemoryCall(session, allocator, .{ .cmd = "mail.send", .account = account, .operationId = "fresh-id-same-uncertain-body", .draft = .{ .to = "peer@example.test", .bodyText = "Synthetic exact spool body uncertain" } });
    try std.testing.expectEqual(operation_count + 1, oracle.writes.load(.acquire));
    oracle_joined = true;
    task.cancel(io) catch |err| if (err != error.Canceled) return err;
    try oracle.requireHistorySuccess();
}
