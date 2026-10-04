const std = @import("std");
const builtin = @import("builtin");
const l = @import("limits.zig");
const Config = @import("config.zig").Config;
const daemon = @import("daemon.zig");
const oauth = @import("oauth.zig");
const http = @import("http_client.zig");
var config: Config = undefined;
var startup_storage: [64 * 1024]u8 = undefined;
var config_storage: [16 * 1024]u8 = undefined;
var probe_storage: [l.response]u8 = undefined;
// All module-owned static storage is accounted at compile time; unassigned
// capacity is physically reserved and touched once, with no allocator fallback.
const assigned_bytes = @sizeOf(Config) + @sizeOf(@TypeOf(startup_storage)) + @sizeOf(@TypeOf(config_storage)) + @sizeOf(@TypeOf(probe_storage)) + 256 + daemon.reservation_bytes + @import("providers/gmail.zig").reservation_bytes + http.reservation_bytes + oauth.reservation_bytes + @import("platform.zig").reservation_bytes + @import("keyring.zig").reservation_bytes;
comptime {
    if (assigned_bytes > l.app_reservation) @compileError("Application reservation exceeds16MiB");
}
var unassigned_reserve: [l.app_reservation - assigned_bytes]u8 = undefined;
pub fn main(init: std.process.Init) void {
    app(init) catch |err| {
        std.debug.print("omagma: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn app(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.LinuxRequired;
    // Runtime bookkeeping is outside the application slab but its worker count
    // and virtual stack reservations are explicit rather than unlimited.
    var runtime = std.Io.Threaded.init(init.gpa, .{ .stack_size = 1024 * 1024, .concurrent_limit = .limited(16), .async_limit = .limited(16), .environ = init.minimal.environ });
    defer runtime.deinit();
    const io = runtime.io();
    @memset(&unassigned_reserve, 0);
    std.mem.doNotOptimizeAway(&unassigned_reserve);
    var f = std.heap.FixedBufferAllocator.init(&startup_storage);
    var args = try init.minimal.args.iterateAllocator(f.allocator());
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse "help";
    if (std.mem.eql(u8, mode, "--version")) {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("omagma {s}\n", .{@import("build_options").version});
        try writer.interface.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "build-info")) {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("{{\"version\":\"{s}\",\"zigVersion\":\"{s}\",\"optimizeMode\":\"{s}\"}}\n", .{ @import("build_options").version, builtin.zig_version_string, @tagName(builtin.mode) });
        try writer.interface.flush();
        return;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    try config.defaults(home);
    if (std.mem.eql(u8, mode, "budget")) {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("{{\"reservationBytes\":{d},\"assignedBytes\":{d},\"unassignedBytes\":{d},\"httpBytes\":{d},\"daemonBytes\":{d},\"gmailBytes\":{d},\"oauthBytes\":{d},\"platformBytes\":{d}}}\n", .{ l.app_reservation, assigned_bytes, unassigned_reserve.len, http.reservation_bytes, daemon.reservation_bytes, @import("providers/gmail.zig").reservation_bytes, oauth.reservation_bytes, @import("platform.zig").reservation_bytes });
        try writer.interface.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "help") or std.mem.eql(u8, mode, "--help")) {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("omagma {s} (Zig {s})\n  --version\n  daemon [--config FILE] [--fixtures] [--dry-run-open]\n  auth --account ADDRESS --config FILE\n  status [--config FILE]\n  probe-http http://127.0.0.1:PORT/PATH\n  probe-https\n", .{ @import("build_options").version, builtin.zig_version_string });
        try writer.interface.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "probe-keyring") or std.mem.eql(u8, mode, "probe-callback")) {
        if (std.mem.eql(u8, mode, "probe-keyring")) {
            try @import("keyring.zig").syntheticProbe(io);
            try @import("keyring.zig").failureProbe(io);
        } else try oauth.callbackProbe(io);
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("{{\"ok\":true,\"probe\":\"{s}\",\"childPeakRssBytes\":{d}}}\n", .{ mode, @import("keyring.zig").last_child_peak_rss });
        try writer.interface.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "probe-http") or std.mem.eql(u8, mode, "probe-http-bearer") or std.mem.eql(u8, mode, "probe-https")) {
        const bearer_probe = std.mem.eql(u8, mode, "probe-http-bearer");
        const url = if (!std.mem.eql(u8, mode, "probe-https")) args.next() orelse return error.UrlRequired else "https://gmail.googleapis.com/gmail/v1/users/me/profile";
        var client = try http.Client.init(io);
        defer client.deinit();
        const start = std.Io.Timestamp.now(io, .awake);
        var response: ?http.Response = null;
        var failure: ?anyerror = null;
        if (bearer_probe) response = client.requestLoopbackBearerProbe(url, &probe_storage) catch |err| result: {
            failure = err;
            break :result null;
        } else if (std.mem.eql(u8, mode, "probe-http")) response = client.requestLoopback(url, &probe_storage) catch |err| result: {
            failure = err;
            break :result null;
        } else response = client.request(url, .GET, null, null, &probe_storage) catch |err| result: {
            failure = err;
            break :result null;
        };
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("{{\"ok\":{s},\"status\":{d},\"bodyBytes\":{d},\"httpPeakBytes\":{d},\"error\":\"{s}\",\"elapsedMs\":{d}}}\n", .{ if (failure == null) "true" else "false", if (response) |r| r.status else @as(u16, 0), if (response) |r| r.body.len else @as(usize, 0), client.peakBytes(), if (failure) |e| @errorName(e) else "", start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() });
        try writer.interface.flush();
        return;
    }
    var options: daemon.Options = .{};
    var config_path: ?[]const u8 = null;
    var account: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) config_path = args.next() orelse return error.ConfigRequired else if (std.mem.eql(u8, arg, "--account")) account = args.next() orelse return error.AccountRequired else if (std.mem.eql(u8, arg, "--fixtures")) options.fixtures = true else if (std.mem.eql(u8, arg, "--dry-run-open")) options.dry_open = true else if (std.mem.eql(u8, arg, "--fixture-delay-ms")) options.fixture_delay_ms = try std.fmt.parseInt(u32, args.next() orelse return error.ValueRequired, 10) else if (std.mem.eql(u8, arg, "--fixture-fail-account")) options.fixture_fail = args.next() orelse return error.ValueRequired else if (std.mem.eql(u8, arg, "--fixture-empty-account")) options.fixture_empty = args.next() orelse return error.ValueRequired else if (std.mem.eql(u8, arg, "--fixture-rows")) {
            options.fixture_rows = try std.fmt.parseInt(usize, args.next() orelse return error.ValueRequired, 10);
            if (options.fixture_rows > l.max_rows) return error.InvalidRowCount;
        } else if (std.mem.eql(u8, arg, "--fixture-fail-after")) options.fixture_fail_after = try std.fmt.parseInt(u64, args.next() orelse return error.ValueRequired, 10) else if (std.mem.eql(u8, arg, "--fixture-auto-refresh-ms")) {
            options.fixture_auto_refresh_ms = try std.fmt.parseInt(u32, args.next() orelse return error.ValueRequired, 10);
            if (options.fixture_auto_refresh_ms == 0 or options.fixture_auto_refresh_ms > 60000) return error.InvalidRefreshInterval;
        } else return error.UnknownOption;
    }
    if (options.fixture_auto_refresh_ms > 0 and !options.fixtures) return error.FixtureOptionRequiresFixtures;
    var default_path: [4096]u8 = undefined;
    if (config_path == null and !options.fixtures) {
        const base = init.environ_map.get("XDG_CONFIG_HOME");
        const p = if (base) |path| try std.fmt.bufPrint(&default_path, "{s}/omagma/config.json", .{path}) else try std.fmt.bufPrint(&default_path, "{s}/.config/omagma/config.json", .{home});
        std.Io.Dir.cwd().access(io, p, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            if (std.mem.eql(u8, mode, "auth")) return error.ConfigRequired;
        };
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| config_path = p else |_| {}
    }
    if (config_path) |path| {
        var parse_buffer: [64 * 1024]u8 = undefined;
        var parse_alloc = std.heap.FixedBufferAllocator.init(&parse_buffer);
        try config.load(io, path, parse_alloc.allocator(), &config_storage);
    }
    if (std.mem.eql(u8, mode, "daemon")) try daemon.run(io, &config, options) else if (std.mem.eql(u8, mode, "auth")) {
        const a = &config.accounts[config.index(account orelse return error.AccountRequired) orelse return error.UnknownAccount];
        if (!a.enabled) return error.AccountDisabled;
        try @import("open_target.zig").checkProfile(io, &config, a);
        if (config.client_file.len == 0) return error.OAuthClientRequired;
        try @import("platform.zig").deadline(io, @import("platform.zig").seconds(l.auth_seconds), oauth.authorize, .{ io, config.client_file.slice(), a.address.slice(), a.profile.slice(), config.chrome.slice() });
    } else if (std.mem.eql(u8, mode, "status")) {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.writeAll("{\"version\":1,\"accounts\":[");
        for (config.accounts[0..config.count], 0..) |*a, i| {
            if (i > 0) try writer.interface.writeByte(',');
            try @import("model.zig").writeSnapshot(&writer.interface, a, false);
        }
        try writer.interface.writeAll("]}\n");
        try writer.interface.flush();
    } else return error.UnknownMode;
}
test {
    std.testing.refAllDecls(@import("daemon.zig"));
    std.testing.refAllDecls(@import("platform.zig"));
    std.testing.refAllDecls(@import("bounded.zig"));
    std.testing.refAllDecls(@import("model.zig"));
    std.testing.refAllDecls(@import("protocol.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("open_target.zig"));
    std.testing.refAllDecls(@import("providers/gmail.zig"));
    std.testing.refAllDecls(@import("http_client.zig"));
    std.testing.refAllDecls(@import("oauth.zig"));
    std.testing.refAllDecls(@import("keyring.zig"));
}
