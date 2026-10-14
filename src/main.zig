const std = @import("std");
const builtin = @import("builtin");
const l = @import("limits.zig");
const Config = @import("config.zig").Config;
const daemon = @import("daemon.zig");
const oauth = @import("oauth.zig");
const http = @import("http_client.zig");
const memory = @import("fixed_runtime.zig");
pub const debug = memory.debug;
var runtime_storage: memory.Storage(memory.application_reservation) = undefined;
// The upstream parser's Debug paste log contains input text. Never log private
// compose/paste content or interleave library diagnostics with terminal paint.
pub const std_options: std.Options = .{ .log_scope_levels = &.{ .{ .scope = .vaxis, .level = .err }, .{ .scope = .vaxis_parser, .level = .err } } };
pub const panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, address: ?usize) noreturn {
        if (@import("build_options").tui) @import("terminal/tui.zig").recover();
        // Keep one symbolizable code address without opening debug mappings
        // or acquiring a panic-time heap. Mail/config values never enter it.
        if (address) |origin| std.debug.print("panic origin: 0x{x}\n", .{origin});
        std.debug.defaultPanic(message, address);
    }
}.call);
var config: Config = undefined;
var startup_storage: [64 * 1024]u8 = undefined;
var config_storage: [16 * 1024]u8 = undefined;
var probe_storage: [l.response]u8 = undefined;
// All module-owned static storage is accounted at compile time; unassigned
// capacity is physically reserved and touched once, with no allocator fallback.
const assigned_bytes = @sizeOf(Config) + @sizeOf(@TypeOf(startup_storage)) + @sizeOf(@TypeOf(config_storage)) + @sizeOf(@TypeOf(probe_storage)) + 256 + @import("terminal/background.zig").reservation_bytes + daemon.reservation_bytes + @import("terminal/vault_daemon.zig").reservation_bytes + @import("providers/gmail.zig").reservation_bytes + http.reservation_bytes + oauth.reservation_bytes + @import("platform.zig").reservation_bytes + @import("keyring.zig").reservation_bytes + (if (@import("build_options").tui) @import("terminal/tui.zig").reservation_bytes else 0) + (if (@import("build_options").browser) @import("browser_server.zig").reservation_bytes else 0);
comptime {
    if (assigned_bytes > l.app_reservation) @compileError("Application reservation exceeds16MiB");
}
var unassigned_reserve: [l.app_reservation - assigned_bytes]u8 = undefined;
pub fn main(init: std.process.Init.Minimal) void {
    app(init) catch |err| {
        std.debug.print("omagma: {s}\n", .{@errorName(err)});
        if (usageError(err)) {
            std.debug.print("Try omagma --help for available commands and options.\n", .{});
            contextHelpHint(init.args);
        }
        std.process.exit(1);
    };
}
fn contextHelpHint(arguments: std.process.Args) void {
    var args = arguments.iterate();
    _ = args.skip();
    const mode = args.next() orelse return;
    const info = @import("terminal/cli_help.zig");
    const verb = args.next();
    if (info.knownFamily(mode)) {
        if (verb != null and info.knownVerb(mode, verb.?)) std.debug.print("Details: omagma {s} {s} --help.\n", .{ mode, verb.? }) else std.debug.print("Details: omagma {s} --help.\n", .{mode});
    } else if (std.mem.eql(u8, mode, "credentials") and verb != null and (std.mem.eql(u8, verb.?, "status") or std.mem.eql(u8, verb.?, "migrate") or std.mem.eql(u8, verb.?, "export"))) {
        std.debug.print("Details: omagma credentials {s} --help.\n", .{verb.?});
    } else if (@import("terminal/standalone_help.zig").known(mode) or std.mem.eql(u8, mode, "cli") or std.mem.eql(u8, mode, "agent") or std.mem.eql(u8, mode, "tui")) std.debug.print("Details: omagma {s} --help.\n", .{mode});
}
fn usageError(err: anyerror) bool {
    return switch (err) {
        error.UnknownMode,
        error.UnknownOption,
        error.UnknownCommand,
        error.CommandRequired,
        error.ValueRequired,
        error.BrowserRequiresPreview,
        error.BrowserPreviewRequiresSavedDraft,
        error.WaitRequiresQueueProcess,
        error.SendDelayRequiresSend,
        error.InvalidSendDelay,
        error.InvalidTriageScope,
        error.ScopeRequiresTriageCommand,
        error.ScopeRequiresSingleMessage,
        error.AttachmentsRequireDraftSource,
        error.InvalidArgv,
        error.Args,
        error.AccountRequired,
        error.ConfigRequired,
        error.CredentialStoreRequired,
        error.InvalidCredentialStore,
        error.CredentialDirectoryRequired,
        error.OutputRequired,
        error.InvalidPort,
        error.ExportFormatRequired,
        error.UnsupportedExportFormat,
        error.InvalidCredentialDirectory,
        error.InvalidCredentialOption,
        error.UrlRequired,
        error.ValueOutOfRange,
        error.InvalidBodyFormat,
        error.ConflictingDraftOptions,
        error.ConflictingSearchMode,
        error.FormatRequiresComposeCommand,
        error.FormatRequiresDraftSource,
        error.OriginalRequiresForward,
        error.PreserveFormattingRequiresReplyOrForward,
        error.ConflictingForwardModes,
        error.CachedFlagRequiresOneShotCommand,
        error.ServerFlagRequiresSearch,
        error.InvalidUpdatePreference,
        => true,
        else => false,
    };
}
fn printHelp(io: std.Io) !void {
    return @import("terminal/cli_help.zig").overview(io);
}
fn printFullHelp(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("omagma {s} (Zig {s})\n  version | --version\n  server [--port PORT]\n  daemon [--config FILE] [--fixtures] [--dry-run-open]\n  auth --account ADDRESS --config FILE\n  status [--config FILE]\n  probe-http http://127.0.0.1:PORT/PATH\n  probe-https\n  cache-refresh --help\n  build-info | budget (use --help for scoped diagnostics)\n", .{ @import("build_options").version, builtin.zig_version_string });
    try writer.interface.flush();
    try @import("terminal/cli.zig").help(io);
    try @import("terminal/credential_cli.zig").help(io);
}
fn standaloneHelpRequested(mode: []const u8, args: *std.process.Args.Iterator) ?[]const u8 {
    var scan = args.*;
    var verb: ?[]const u8 = null;
    if (std.mem.eql(u8, mode, "credentials")) {
        const first = scan.next() orelse return null;
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help-all")) return "";
        if (!std.mem.eql(u8, first, "status") and !std.mem.eql(u8, first, "migrate") and !std.mem.eql(u8, first, "export")) return null;
        verb = first;
    }
    while (scan.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help-all")) return verb orelse "";
        if (std.mem.eql(u8, arg, "--fixtures") or std.mem.eql(u8, arg, "--dry-run-open") or std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "--quiet")) continue;
        // Standalone value flags (including probe positional arguments) are
        // data. Recognized value options consume their value before help scan.
        var value_flag = false;
        for ([_][]const u8{ "--config", "--account", "--grant-file", "--to", "--directory", "--format", "--output", "--port", "--cache-dir", "--interval", "--prefetch-bodies", "--metadata-limit", "--disk-limit-bytes", "--fixture-root", "--fixture-scenario", "--fixture-delay-ms", "--fixture-fail-account", "--fixture-empty-account", "--fixture-rows", "--fixture-fail-after", "--fixture-auto-refresh-ms" }) |flag| if (std.mem.eql(u8, arg, flag)) {
            value_flag = true;
            break;
        };
        if (value_flag and !scan.skip()) return null;
    }
    return null;
}
fn app(minimal: std.process.Init.Minimal) !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    // Inspect mode before allocating provider workers or touching the unused
    // native reserve. Relay requests are served by the unlocked owner process.
    var early = minimal.args.iterate();
    _ = early.skip();
    const early_mode = early.next() orelse "help";
    var lean_client = false;
    if (std.mem.eql(u8, early_mode, "vault")) {
        const verb = early.next() orelse "help";
        lean_client = !std.mem.eql(u8, verb, "serve") and !std.mem.eql(u8, verb, "init") and !std.mem.eql(u8, verb, "migrate");
    } else if (std.mem.eql(u8, early_mode, "cli") or std.mem.eql(u8, early_mode, "agent") or std.mem.eql(u8, early_mode, "tui") or @import("terminal/cli_help.zig").knownFamily(early_mode)) {
        while (early.next()) |arg| if (std.mem.eql(u8, arg, "--backend")) {
            lean_client = true;
            break;
        };
    }
    var runtime: memory.Runtime = .{};
    try runtime.init(minimal, runtime_storage.buffers(), memory.application_limit);
    defer runtime.deinit();
    if (!lean_client and (std.mem.eql(u8, early_mode, "cli") or std.mem.eql(u8, early_mode, "agent") or std.mem.eql(u8, early_mode, "tui") or @import("terminal/cli_help.zig").knownFamily(early_mode))) {
        var fixture_scan = minimal.args.iterate();
        var fixtures = false;
        while (fixture_scan.next()) |arg| if (std.mem.eql(u8, arg, "--fixtures")) {
            fixtures = true;
            break;
        };
        if (!fixtures) {
            // Resolve the strictly private activation before reserving provider
            // workers/touching the native reserve. Startup permits local I/O;
            // no provider or client can run until the chosen pool is sealed.
            var routing_arena: std.heap.ArenaAllocator = .init(runtime.application_meter.allocator());
            defer routing_arena.deinit();
            lean_client = try @import("terminal/vault_activation.zig").load(runtime.threaded.io(), routing_arena.allocator(), &runtime.environ) != null;
        }
    }
    if (lean_client) {
        if (std.mem.eql(u8, early_mode, "tui")) try runtime.sealFrontend() else try runtime.sealClient();
    } else try runtime.seal();
    const init = runtime.context();
    const io = runtime.io();
    if (!lean_client) {
        @memset(&unassigned_reserve, 0);
        std.mem.doNotOptimizeAway(&unassigned_reserve);
    }
    var f = std.heap.FixedBufferAllocator.init(&startup_storage);
    var args = try init.minimal.args.iterateAllocator(f.allocator());
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse "help";
    if (@import("terminal/standalone_help.zig").known(mode)) {
        if (standaloneHelpRequested(mode, &args)) |verb| return @import("terminal/standalone_help.zig").render(io, mode, if (verb.len == 0) null else verb);
    }
    if (std.mem.eql(u8, mode, "server")) {
        if (!@import("build_options").browser) return error.BrowserAssetsNotIncluded;
        const server = @import("browser_server.zig");
        const assets = @import("browser_assets").assets(server.Asset);
        return @import("browser_connection.zig").run(init, io, &args, &assets);
    }
    if (std.mem.eql(u8, mode, "vault")) return @import("terminal/vault_daemon.zig").run(init, io, &args);
    if (std.mem.eql(u8, mode, "credentials")) return @import("terminal/credential_cli.zig").run(init, io, &args);
    if (std.mem.eql(u8, mode, "__wait-probe-child")) return @import("platform.zig").waitCancellationChild(io);
    if (std.mem.eql(u8, mode, "probe-keyring-upgrade")) {
        const phase = args.next() orelse return error.Args;
        const directory = args.next() orelse return error.Args;
        if (args.next() != null) return error.Args;
        try @import("keyring.zig").upgradeProbe(io, phase, directory);
        return;
    }
    if (std.mem.eql(u8, mode, "keychain-worker")) {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        var command: [5][]const u8 = undefined;
        var count: usize = 0;
        while (args.next()) |arg| {
            if (count == command.len) return error.InvalidArgv;
            command[count] = arg;
            count += 1;
        }
        if (count != command.len) return error.InvalidArgv;
        try @import("keyring.zig").runNativeWorker(io, &command);
        return;
    }
    if (std.mem.eql(u8, mode, "__launch-worker")) {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        var command: [16][]const u8 = undefined;
        var count: usize = 0;
        while (args.next()) |arg| {
            if (count == command.len) return error.InvalidArgv;
            command[count] = arg;
            count += 1;
        }
        try @import("platform.zig").launchDarwinWorker(io, command[0..count]);
        return;
    }
    if (std.mem.eql(u8, mode, "cache-refresh")) {
        try @import("terminal/background.zig").run(init, io, &args);
        return;
    }
    if (std.mem.eql(u8, mode, "--version") or std.mem.eql(u8, mode, "version")) {
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
    if (std.mem.eql(u8, mode, "tui") or std.mem.eql(u8, mode, "cli") or std.mem.eql(u8, mode, "agent") or @import("terminal/cli_help.zig").knownFamily(mode)) {
        try @import("terminal/cli.zig").run(init, io, mode, &args);
        return;
    }
    if (std.mem.eql(u8, mode, "budget")) {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try std.json.Stringify.value(.{
            .reservationBytes = l.app_reservation,
            .assignedBytes = assigned_bytes,
            .unassignedBytes = unassigned_reserve.len,
            .httpBytes = http.reservation_bytes,
            .daemonBytes = daemon.reservation_bytes,
            .gmailBytes = @import("providers/gmail.zig").reservation_bytes,
            .oauthBytes = oauth.reservation_bytes,
            .platformBytes = @import("platform.zig").reservation_bytes,
            .fixedMemory = runtime.snapshot(),
        }, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "help") or std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) return printHelp(io);
    if (std.mem.eql(u8, mode, "--help-all")) return printFullHelp(io);
    if (std.mem.eql(u8, mode, "probe-label-http")) {
        const method = std.meta.stringToEnum(std.http.Method, args.next() orelse return error.InvalidProbeMethod) orelse return error.InvalidProbeMethod;
        const url = args.next() orelse return error.UrlRequired;
        if (args.next() != null) return error.Args;
        var arena = std.heap.ArenaAllocator.init(init.allocator);
        defer arena.deinit();
        const value = try @import("terminal/gmail.zig").probeLabelHttp(io, arena.allocator(), method, url);
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try std.json.Stringify.value(value, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
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
    if (std.mem.eql(u8, mode, "probe-http") or std.mem.eql(u8, mode, "probe-http-bearer") or std.mem.eql(u8, mode, "probe-https") or std.mem.eql(u8, mode, "probe-terminal-http") or std.mem.eql(u8, mode, "probe-terminal-http-oversize")) {
        const bearer_probe = std.mem.eql(u8, mode, "probe-http-bearer");
        const oversized_terminal = std.mem.eql(u8, mode, "probe-terminal-http-oversize");
        const terminal_probe = oversized_terminal or std.mem.eql(u8, mode, "probe-terminal-http");
        const url = if (!std.mem.eql(u8, mode, "probe-https")) args.next() orelse return error.UrlRequired else "https://gmail.googleapis.com/gmail/v1/users/me/profile";
        const terminal_output: []u8 = if (terminal_probe) try init.allocator.alloc(u8, 3 * l.MiB) else &.{};
        defer if (terminal_probe) init.allocator.free(terminal_output);
        const terminal_body: []u8 = if (terminal_probe) try init.allocator.alloc(u8, if (oversized_terminal) 3 * l.MiB + 1 else 131072) else &.{};
        defer if (terminal_probe) init.allocator.free(terminal_body);
        if (oversized_terminal) @memset(terminal_body, 'x');
        if (terminal_probe and !oversized_terminal) _ = try http.terminalProbeBody(terminal_body);
        var client = try http.Client.init(io);
        defer client.deinit();
        const start = std.Io.Timestamp.now(io, .awake);
        var response: ?http.Response = null;
        var failure: ?anyerror = null;
        if (terminal_probe) response = client.requestLoopbackTerminalProbe(url, terminal_body, terminal_output) catch |err| result: {
            failure = err;
            break :result null;
        } else if (bearer_probe) response = client.requestLoopbackBearerProbe(url, &probe_storage) catch |err| result: {
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
    if (!std.mem.eql(u8, mode, "daemon") and !std.mem.eql(u8, mode, "auth") and !std.mem.eql(u8, mode, "status")) return error.UnknownMode;
    var options: daemon.Options = .{};
    var config_path: ?[]const u8 = null;
    var account: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return printHelp(io);
        if (std.mem.eql(u8, arg, "--config")) config_path = args.next() orelse return error.ConfigRequired else if (std.mem.eql(u8, arg, "--account")) account = args.next() orelse return error.AccountRequired else if (std.mem.eql(u8, arg, "--fixtures")) options.fixtures = true else if (std.mem.eql(u8, arg, "--dry-run-open")) options.dry_open = true else if (std.mem.eql(u8, arg, "--fixture-delay-ms")) options.fixture_delay_ms = try std.fmt.parseInt(u32, args.next() orelse return error.ValueRequired, 10) else if (std.mem.eql(u8, arg, "--fixture-fail-account")) options.fixture_fail = args.next() orelse return error.ValueRequired else if (std.mem.eql(u8, arg, "--fixture-empty-account")) options.fixture_empty = args.next() orelse return error.ValueRequired else if (std.mem.eql(u8, arg, "--fixture-rows")) {
            options.fixture_rows = try std.fmt.parseInt(usize, args.next() orelse return error.ValueRequired, 10);
            if (options.fixture_rows > l.max_rows) return error.InvalidRowCount;
        } else if (std.mem.eql(u8, arg, "--fixture-fail-after")) options.fixture_fail_after = try std.fmt.parseInt(u64, args.next() orelse return error.ValueRequired, 10) else if (std.mem.eql(u8, arg, "--fixture-auto-refresh-ms")) {
            options.fixture_auto_refresh_ms = try std.fmt.parseInt(u32, args.next() orelse return error.ValueRequired, 10);
            if (options.fixture_auto_refresh_ms == 0 or options.fixture_auto_refresh_ms > 60000) return error.InvalidRefreshInterval;
        } else return error.UnknownOption;
    }
    if (options.fixture_auto_refresh_ms > 0 and !options.fixtures) return error.FixtureOptionRequiresFixtures;
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    try config.defaults(home);
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
    if (std.mem.eql(u8, mode, "daemon")) {
        if (builtin.os.tag != .linux) return error.LinuxRequired;
        try daemon.run(io, &config, options);
    } else if (std.mem.eql(u8, mode, "auth")) {
        const a = &config.accounts[config.index(account orelse return error.AccountRequired) orelse return error.UnknownAccount];
        if (!a.enabled) return error.AccountDisabled;
        try @import("open_target.zig").checkProfile(io, &config, a);
        if (config.client_file.len == 0) return error.OAuthClientRequired;
        try @import("platform.zig").deadline(io, @import("platform.zig").seconds(l.auth_seconds), oauth.authorize, .{ io, config.client_file.slice(), a.address.slice(), a.profile.slice(), config.chrome.slice(), config.credentials() });
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
    std.testing.refAllDecls(@import("fixed_runtime_tests.zig"));
    std.testing.refAllDecls(@import("fixed_heap.zig"));
    std.testing.refAllDecls(@import("daemon.zig"));
    std.testing.refAllDecls(@import("terminal/layout.zig"));
    std.testing.refAllDecls(@import("terminal/theme.zig"));
    std.testing.refAllDecls(@import("terminal/timezone.zig"));
    std.testing.refAllDecls(@import("terminal/preferences.zig"));
    std.testing.refAllDecls(@import("terminal/updates.zig"));
    std.testing.refAllDecls(@import("terminal/background.zig"));
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
    std.testing.refAllDecls(@import("keyring_file.zig"));
    std.testing.refAllDecls(@import("terminal/credential_cli.zig"));
    std.testing.refAllDecls(@import("terminal/capped_allocator.zig"));
    std.testing.refAllDecls(@import("terminal/core.zig"));
    std.testing.refAllDecls(@import("terminal/cli_plan.zig"));
    std.testing.refAllDecls(@import("terminal/mime.zig"));
    std.testing.refAllDecls(@import("terminal/recipients.zig"));
    std.testing.refAllDecls(@import("terminal/invitation.zig"));
    std.testing.refAllDecls(@import("terminal/editor.zig"));
    // Import its pure tests without instantiating run() against libvaxis's
    // deliberately different TestTty. Real terminal paths use isolated PTYs.
    if (@import("build_options").tui) {
        _ = @import("terminal/tui.zig");
        std.testing.refAllDecls(@import("terminal/html_view.zig"));
        std.testing.refAllDecls(@import("terminal/reader_selection.zig"));
        std.testing.refAllDecls(@import("terminal/input.zig"));
    }
}
