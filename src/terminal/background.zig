const std = @import("std");
const core = @import("core.zig");
const t = @import("types.zig");
const j = @import("json.zig");
const CappedAllocator = @import("capped_allocator.zig").CappedAllocator;
const Io = std.Io;

var wake_fd: std.atomic.Value(i32) = .init(-1);
var stopped: std.atomic.Value(bool) = .init(false);
pub const reservation_bytes = @sizeOf(@TypeOf(wake_fd)) + @sizeOf(@TypeOf(stopped));

const Outcome = enum { refreshed, fresh, in_progress, auth_needed, offline, local_failure };
const Slot = struct { slot: usize, outcome: Outcome };
const Settings = struct { options: t.Options = .{}, interval: u32 = 300, force: bool = false, quiet: bool = false };

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stopped.store(true, .release);
    const fd = wake_fd.load(.acquire);
    if (fd >= 0) {
        const one: u64 = 1;
        _ = std.os.linux.write(fd, std.mem.asBytes(&one).ptr, 8);
    }
}
fn signalTask(io: Io, file: Io.File, cancel: *Io.Event) void {
    var bytes: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    reader.interface.readSliceAll(&bytes) catch return;
    cancel.set(io);
}
fn waitStop(io: Io, cancel: *Io.Event) Io.Cancelable!void {
    try cancel.wait(io);
}

fn classify(code: []const u8) Outcome {
    for ([_][]const u8{ "NotConnected", "OAuthClientRequired", "InvalidGrant", "PermissionDenied", "KeyringUnavailable", "KeyringLocked", "WrongAccount" }) |name| if (std.mem.eql(u8, code, name)) return .auth_needed;
    for ([_][]const u8{ "Timeout", "Canceled", "RateLimited", "TransientFailure", "ConnectionRefused", "NetworkUnreachable", "HostUnreachable", "ProviderRejected" }) |name| if (std.mem.eql(u8, code, name)) return .offline;
    return .local_failure;
}
fn refresh(session: *core.Session, slot: usize, address: []const u8, settings: Settings) Slot {
    var arena: std.heap.ArenaAllocator = .init(session.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = std.json.Stringify.valueAlloc(a, .{
        .cmd = "mail.refresh", .account = address, .label = "INBOX", .limit = @as(usize, 32),
        .auto = !settings.force, .intervalSeconds = settings.interval, .barGrantOnly = true,
    }, .{}) catch return .{ .slot = slot, .outcome = .local_failure };
    const raw = session.execute(a, request) catch |err| return .{ .slot = slot, .outcome = classify(@errorName(err)) };
    const response = std.json.parseFromSliceLeaky(j.Value, a, raw, .{ .allocate = .alloc_always }) catch return .{ .slot = slot, .outcome = .local_failure };
    if (!(j.boolean(response, "ok", false) catch false)) return .{ .slot = slot, .outcome = classify(j.text(j.get(response, "error") orelse .null, "code")) };
    const data = j.get(response, "data") orelse return .{ .slot = slot, .outcome = .local_failure };
    return .{ .slot = slot, .outcome = if (j.boolean(data, "refreshInProgress", false) catch false) .in_progress else if (j.boolean(data, "coalesced", false) catch false) .fresh else .refreshed };
}

pub fn run(init: std.process.Init, io: Io, args: *std.process.Args.Iterator) !void {
    var cap: CappedAllocator = .{ .backing = init.gpa, .limit = t.Limits.runtime_bytes };
    const a = cap.allocator();
    var settings: Settings = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            var buf: [1024]u8 = undefined;
            var out = Io.File.stdout().writer(io, &buf);
            try out.interface.writeAll("Experimental cache refresh: read-only enabled accounts, sequentially.\n  omagma cache-refresh [--config FILE] [--cache-dir DIR] [--interval SECONDS] [--quiet] [--force]\nAutomatic runs coalesce through account refresh leases; --force bypasses age, not the lease.\nNo mail or account identifiers are printed.\n");
            try out.interface.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "--quiet")) { settings.quiet = true; continue; }
        if (std.mem.eql(u8, arg, "--force")) { settings.force = true; continue; }
        if (std.mem.eql(u8, arg, "--fixtures")) { settings.options.fixtures = true; continue; }
        const value = args.next() orelse return error.ValueRequired;
        if (std.mem.eql(u8, arg, "--config")) settings.options.config_file = value
        else if (std.mem.eql(u8, arg, "--cache-dir")) settings.options.cache_dir = value
        else if (std.mem.eql(u8, arg, "--fixture-root")) settings.options.fixture_root = value
        else if (std.mem.eql(u8, arg, "--fixture-scenario")) settings.options.fixture_scenario = value
        else if (std.mem.eql(u8, arg, "--interval")) settings.interval = try std.fmt.parseInt(u32, value, 10)
        else if (std.mem.eql(u8, arg, "--metadata-limit")) { settings.options.metadata_limit = try std.fmt.parseInt(usize, value, 10); settings.options.metadata_limit_set = true; }
        else if (std.mem.eql(u8, arg, "--disk-limit-bytes")) { settings.options.disk_limit = try std.fmt.parseInt(usize, value, 10); settings.options.disk_limit_set = true; }
        else return error.UnknownOption;
    }
    if (settings.interval < 60 or settings.interval > 86400) return error.InvalidRefreshInterval;
    var session = try core.Session.init(io, a, init.environ_map, settings.options);
    defer session.deinit();
    session.meter = &cap;
    const raw_fd = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
    if (std.os.linux.errno(raw_fd) != .SUCCESS) return error.EventFdFailed;
    const file: Io.File = .{ .handle = @intCast(raw_fd), .flags = .{ .nonblocking = false } };
    defer file.close(io);
    var cancel: Io.Event = .unset;
    stopped.store(false, .release);
    wake_fd.store(file.handle, .release);
    const signals = [_]std.posix.SIG{ .TERM, .INT, .HUP, .QUIT };
    var old: [signals.len]std.posix.Sigaction = undefined;
    for (signals, 0..) |signal, i| {
        var action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(signal, &action, &old[i]);
    }
    defer {
        wake_fd.store(-1, .release);
        for (signals, 0..) |signal, i| std.posix.sigaction(signal, &old[i], null);
    }
    var signal_future = try io.concurrent(signalTask, .{ io, file, &cancel });
    defer signal_future.cancel(io);
    var slots: [3]Slot = undefined;
    var count: usize = 0;
    var failed = false;
    for (session.config.accounts[0..session.config.count], 0..) |account, i| {
        if (stopped.load(.acquire)) break;
        if (!account.enabled) continue;
        const Event = union(enum) { result: Slot, stop: Io.Cancelable!void };
        var events: [2]Event = undefined;
        var selection: Io.Select(Event) = .init(io, &events);
        defer selection.cancelDiscard();
        try selection.concurrent(.result, refresh, .{ &session, i + 1, account.address.slice(), settings });
        try selection.concurrent(.stop, waitStop, .{ io, &cancel });
        switch (try selection.await()) {
            .result => |result| {
                slots[count] = result; count += 1;
                failed = failed or result.outcome == .local_failure;
            },
            .stop => |result| { try result; break; },
        }
    }
    if (!settings.quiet) {
        const result = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .ok = !failed, .interrupted = stopped.load(.acquire), .slots = slots[0..count] }, .{});
        defer a.free(result);
        var buffer: [4096]u8 = undefined;
        var out = Io.File.stdout().writer(io, &buffer);
        try out.interface.writeAll(result); try out.interface.writeByte('\n'); try out.interface.flush();
    }
    if (failed) return error.BackgroundCacheFailed;
}

test "background reports classify static errors without revealing mailbox data" {
    try std.testing.expectEqual(Outcome.auth_needed, classify("PermissionDenied"));
    try std.testing.expectEqual(Outcome.auth_needed, classify("KeyringLocked"));
    try std.testing.expectEqual(Outcome.offline, classify("Timeout"));
    try std.testing.expectEqual(Outcome.local_failure, classify("InsecureCacheFile"));
}
