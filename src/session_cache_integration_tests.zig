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
    draft_flow: bool = false,
    draft_status_reads: std.atomic.Value(usize) = .init(0),
    draft_race: std.atomic.Value(bool) = .init(false),
    fn run(self: *Oracle) anyerror!void {
        while (true) {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            self.respond(stream) catch |err| {
                std.debug.print("HTTP fixture error: {s}\n", .{@errorName(err)});
                return err;
            };
        }
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
        var body: [64 * 1024]u8 = undefined;
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
                try std.testing.expect(std.mem.indexOf(u8, body[0..body_size], "Synthetic exact spool body") != null);
            }
            if (self.drop_write.load(.acquire)) return;
            status = @fromBackingInt(@intCast(self.write_status.load(.acquire)));
            response = "{\"id\":\"synthetic-sent\",\"threadId\":\"synthetic-thread\"}";
        }
        try request.respond(response, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    }
};
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
