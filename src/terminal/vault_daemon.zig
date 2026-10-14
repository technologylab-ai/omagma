//! Same-binary vault service. Two bounded connections share one network lane.
//! Control/unlock jobs do not consume that lane; a lock drains the active job.
const std = @import("std");
const builtin = @import("builtin");
const transport = @import("vault_transport.zig");
const Owner = @import("vault_owner.zig").Owner;
const vt = @import("vault_types.zig");
const recovery_text = @import("vault_recovery.zig");
const platform = @import("../platform.zig");
const wakeup = @import("../signal_wake.zig");
var signal_fd: std.atomic.Value(i32) = .init(-1);
pub const reservation_bytes = @sizeOf(@TypeOf(signal_fd));

const LaneTestGate = if (builtin.is_test) struct {
    once: std.atomic.Value(bool) = .init(true),
    entered: std.Io.Event = .unset,
    acquired: std.Io.Event = .unset,
    release_wait: std.Io.Event = .unset,
} else void;

pub fn disableCoreDumps() !void {
    try std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 });
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_DUMPABLE), 0, 0, 0, 0)) != .SUCCESS) return error.VaultHardeningFailed;
    }
}

const Server = struct {
    io: std.Io,
    a: std.mem.Allocator,
    listener: *transport.Listener,
    owner: *Owner,
    stopped: std.Io.Event = .unset,
    failed: std.atomic.Value(bool) = .init(false),
    network_lane: std.atomic.Value(bool) = .init(false),
    control_locking: std.atomic.Value(bool) = .init(false),
    cancel_execution: std.Io.Event = .unset,
    lane_test_gate: if (builtin.is_test) ?*LaneTestGate else void = if (builtin.is_test) null else {},

    fn worker(self: *Server) std.Io.Cancelable!void {
        while (!self.stopped.isSet()) {
            const stream = self.listener.server.accept(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.ConnectionAborted => continue,
                else => {
                    self.failed.store(true, .release);
                    self.stopped.set(self.io);
                    return;
                },
            };
            defer stream.close(self.io);
            transport.validatePeer(stream) catch continue;
            var received: ?transport.Frame = null;
            defer if (received) |*owned| owned.deinit(self.a);
            platform.deadline(self.io, platform.seconds(5), readFrameInto, .{ self.io, self.a, stream, &received }) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                continue;
            };
            var frame = received.?;
            const lane = frame.kind == .execute;
            // deadline joins its operation even when timeout/cancel wins.
            // Retain acquisition ownership outside its discarded result.
            var acquired_lane = false;
            defer if (acquired_lane) self.network_lane.store(false, .release);
            if (lane and self.control_locking.load(.acquire)) {
                self.sendError(stream, &frame, error.VaultLocked) catch |err| if (err == error.Canceled) return error.Canceled;
                continue;
            }
            if (lane) platform.deadline(self.io, platform.seconds(5), acquireLane, .{ self, &acquired_lane }) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.sendError(stream, &frame, if (err == error.Timeout) error.VaultBusy else err) catch |send_err| if (send_err == error.Canceled) return error.Canceled;
                continue;
            };
            if (lane) self.cancel_execution.reset();
            if (lane and self.control_locking.load(.acquire)) {
                self.sendError(stream, &frame, error.VaultLocked) catch |err| if (err == error.Canceled) return error.Canceled;
                continue;
            }
            var response: ?[]const u8 = null;
            defer if (response) |bytes| {
                std.crypto.secureZero(u8, @constCast(bytes));
                self.a.free(bytes);
            };
            self.dispatch(&frame, &response, stream) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                const report = if (frame.kind == .execute and (err == error.Timeout or err == error.OutOfMemory or err == error.VaultOperationCanceled)) mutationFailure(frame.body, err) else err;
                self.sendError(stream, &frame, report) catch |send_err| if (send_err == error.Canceled) return error.Canceled;
                continue;
            };
            platform.deadline(self.io, platform.seconds(5), transport.writeFrame, .{ self.io, stream, .response, response.?, transport.response_limit }) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
            if (frame.kind == .stop) {
                self.stopped.set(self.io);
                return;
            }
        }
    }
    fn dispatch(self: *Server, frame: *transport.Frame, response: *?[]const u8, stream: std.Io.net.Stream) !void {
        switch (frame.kind) {
            .execute => return self.executeFrame(frame, response, stream),
            .unlock => {
                // This dedicated connection worker owns the KDF. The 64 MiB
                // lease is serialized and always reclaimed before returning.
                defer std.crypto.secureZero(u8, frame.body);
                try self.owner.unlock(frame.body);
            },
            .password_change => {
                defer std.crypto.secureZero(u8, frame.body);
                try self.owner.changePassword(frame.body);
            },
            .recovery_change, .recover => {
                defer std.crypto.secureZero(u8, frame.body);
                var recovery: vt.RecoveryKey = .{ .bytes = frame.body[0..32].* };
                defer recovery.wipe();
                if (frame.kind == .recover) try self.owner.recover(&recovery, frame.body[32..]) else try self.owner.changeRecovery(&recovery);
            },
            .lock, .stop => {
                if (self.control_locking.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.VaultBusy;
                defer self.control_locking.store(false, .release);
                self.cancel_execution.set(self.io);
                try platform.deadline(self.io, platform.seconds(35), drainAndLock, .{self});
            },
            .status => {},
            .response => return error.InvalidBackendFrame,
        }
        var id_text: [32]u8 = undefined;
        const vault_id: ?[]const u8 = if (self.owner.known_vault_id) |id| blk: {
            id_text = std.fmt.bytesToHex(id, .lower);
            break :blk &id_text;
        } else null;
        response.* = try std.json.Stringify.valueAlloc(self.a, .{ .version = @as(u8, 1), .ok = true, .data = .{ .unlocked = self.owner.unlocked(), .vaultId = vault_id } }, .{});
    }
    fn readFrameInto(io: std.Io, a: std.mem.Allocator, stream: std.Io.net.Stream, output: *?transport.Frame) !void {
        output.* = try transport.readFrame(io, a, stream, transport.request_limit);
    }
    fn executeInto(self: *Server, raw: []const u8, output: *?[]const u8) !void {
        output.* = try self.owner.execute(self.a, raw);
    }
    fn executeTimer(io: std.Io, seconds: i64) !void {
        try platform.seconds(seconds).sleep(io);
    }
    fn waitReadPeer(io: std.Io, stream: std.Io.net.Stream) !void {
        // One frame owns this connection. The caller keeps its sending half
        // open while awaiting the response; EOF abandons this background read.
        // No other peer, provider mutation or control operation is observed.
        var buffer: [1]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        var reader = stream.reader(io, &buffer);
        _ = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        return error.InvalidBackendFrame;
    }
    fn executeFrame(self: *Server, frame: *transport.Frame, response: *?[]const u8, stream: std.Io.net.Stream) !void {
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = try transport.requestMetadata(fixed.allocator(), frame.body);
        const Event = union(enum) { operation: anyerror!void, timeout: anyerror!void, lock: std.Io.Cancelable!void, read_peer: anyerror!void };
        var events: [4]Event = undefined;
        var select: std.Io.Select(Event) = .init(self.io, &events);
        // Zig0.17 Select explicitly discards return values here. Resources go
        // into caller-owned slots, which are wiped after cancellation joins.
        defer select.cancelDiscard();
        try select.concurrent(.operation, executeInto, .{ self, frame.body, response });
        try select.concurrent(.timeout, executeTimer, .{ self.io, transport.executionSeconds(meta.command) });
        try select.concurrent(.lock, std.Io.Event.wait, .{ &self.cancel_execution, self.io });
        // Only these background reads yield to their caller's disconnect.
        // Admitted draft/provider mutations keep their independent completion
        // and unknown-outcome behavior even if the requesting client goes away.
        if (std.mem.eql(u8, meta.command, "mail.refresh") or std.mem.eql(u8, meta.command, "calendar.list") or std.mem.eql(u8, meta.command, "calendar.agenda"))
            try select.concurrent(.read_peer, waitReadPeer, .{ self.io, stream });
        switch (try select.await()) {
            .operation => |result| try result,
            .timeout => |result| {
                try result;
                return error.Timeout;
            },
            .lock => |result| {
                try result;
                return error.VaultOperationCanceled;
            },
            .read_peer => |result| {
                // Both EOF and malformed additional bytes abandon this exact
                // read. The Select defer joins execution before lane/key
                // reuse; an admitted cache mutation remains UnknownOutcome.
                result catch |err| if (err == error.Canceled) return err;
                return error.VaultOperationCanceled;
            },
        }
    }
    fn drainAndLock(self: *Server) !void {
        while (self.network_lane.load(.acquire)) try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(10) }).sleep(self.io);
        try self.owner.lock();
    }
    fn acquireLane(self: *Server, acquired: *bool) !void {
        const gate = if (builtin.is_test) (if (self.lane_test_gate) |g| (if (g.once.swap(false, .acq_rel)) g else null) else null) else {};
        if (builtin.is_test) if (gate) |g| g.entered.set(self.io);
        while (true) {
            if (self.control_locking.load(.acquire)) return error.VaultLocked;
            if (self.network_lane.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                acquired.* = true; // No cancellation point between CAS and ownership publication.
                if (builtin.is_test) if (gate) |g| {
                    // Model descheduling after the swap but before Select can
                    // publish success. A timeout/cancel then discards success.
                    g.acquired.set(self.io);
                    g.release_wait.wait(self.io) catch |err| if (err != error.Canceled) return err;
                };
                return;
            }
            // A preceding client's response may be received before its secure
            // cleanup completes. Bound this admission wait instead of leaking
            // a spurious Busy into ordinary sequential CLI/TUI calls.
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(1) }).sleep(self.io);
        }
    }
    fn sendError(self: *Server, stream: std.Io.net.Stream, frame: *const transport.Frame, err: anyerror) !void {
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
        const meta = if (frame.kind == .execute) transport.requestMetadata(fixed.allocator(), frame.body) catch transport.Metadata{} else transport.Metadata{};
        var bytes: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        var out: std.Io.Writer = .fixed(&bytes);
        try std.json.Stringify.value(.{ .version = @as(u8, 1), .id = meta.id, .ok = false, .account = meta.account, .@"error" = .{ .code = @errorName(err), .message = @errorName(err) } }, .{}, &out);
        try platform.deadline(self.io, platform.seconds(5), transport.writeFrame, .{ self.io, stream, .response, out.buffered(), transport.response_limit });
    }
};

fn mutationFailure(raw: []const u8, err: anyerror) anyerror {
    // No allocation during low-memory outcome classification. This bounded
    // prefix can only prove a known command; failure remains conservative.
    var scratch: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const meta = transport.requestMetadata(fixed.allocator(), raw) catch return error.UnknownOutcome;
    return if (@import("client_contract.zig").readOnlyEnvelope(meta.command, meta.reconcile)) err else error.UnknownOutcome;
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const fd = signal_fd.load(.acquire);
    if (fd >= 0) wakeup.notify(fd);
}
fn waitSignal(io: std.Io, file: std.Io.File, stopped: *std.Io.Event) void {
    var bytes: [8]u8 = undefined;
    _ = file.readStreaming(io, &.{&bytes}) catch return;
    stopped.set(io);
}

pub fn serve(io: std.Io, a: std.mem.Allocator, owner: *Owner, socket_path: []const u8) !void {
    if (!builtin.is_test) try disableCoreDumps();
    var listener = try transport.Listener.init(io, socket_path);
    defer listener.deinit();
    var server: Server = .{ .io = io, .a = a, .listener = &listener, .owner = owner };
    const wake = try wakeup.Wake.init(io);
    defer wake.close(io);
    const signals = [_]std.posix.SIG{ .INT, .TERM };
    var previous: [signals.len]std.posix.Sigaction = undefined;
    signal_fd.store(wake.write_fd, .release);
    for (signals, 0..) |signal, index| {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(signal, &action, &previous[index]);
    }
    defer {
        signal_fd.store(-1, .release);
        for (signals, 0..) |signal, index| std.posix.sigaction(signal, &previous[index], null);
    }
    var signal_task = try io.concurrent(waitSignal, .{ io, wake.read, &server.stopped });
    defer {
        wakeup.notify(wake.write_fd);
        signal_task.cancel(io);
    }
    var workers: std.Io.Group = .init;
    defer {
        // Every exit stops admission before joining workers. Cancellation is
        // one-shot: an acknowledged request must never enter another accept.
        server.stopped.set(io);
        workers.cancel(io);
    }
    // Leave room in the fixed 16-worker runtime for Core/HTTP's bounded
    // deadline tasks even when the other connection stalls while writing.
    for (0..2) |_| try workers.concurrent(io, Server.worker, .{&server});
    try server.stopped.wait(io);
    if (server.failed.load(.acquire)) return error.BackendStopped;
}

/// Local interactive input only. No stdin/argv/environment password option.
/// The caller wipes output even when this function fails midway through input.
pub fn passwordPrompt(io: std.Io, label: []const u8, output: []u8) ![]const u8 {
    const tty = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write, .allow_directory = false });
    defer tty.close(io);
    const previous = try std.posix.tcgetattr(tty.handle);
    var settings = previous;
    settings.lflag.ECHO = false;
    settings.lflag.ECHONL = false;
    settings.lflag.ICANON = false;
    settings.lflag.ISIG = false;
    settings.cc[@backingInt(std.posix.V.MIN)] = 1;
    settings.cc[@backingInt(std.posix.V.TIME)] = 0;
    const wake = try wakeup.Wake.init(io);
    defer wake.close(io);
    if (signal_fd.cmpxchgStrong(-1, wake.write_fd, .acq_rel, .acquire) != null) return error.VaultPromptBusy;
    const signals = [_]std.posix.SIG{ .INT, .TERM, .HUP };
    var handlers: [signals.len]std.posix.Sigaction = undefined;
    for (signals, 0..) |sig, index| {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(sig, &action, &handlers[index]);
    }
    defer {
        signal_fd.store(-1, .release);
        for (signals, 0..) |sig, index| std.posix.sigaction(sig, &handlers[index], null);
    }
    try std.posix.tcsetattr(tty.handle, .FLUSH, settings);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, previous) catch {};
    try tty.writeStreamingAll(io, label);
    defer tty.writeStreamingAll(io, "\n") catch {};
    const Event = union(enum) { input: anyerror!usize, signal: anyerror!void };
    var events: [2]Event = undefined;
    var choice: std.Io.Select(Event) = .init(io, &events);
    defer choice.cancelDiscard();
    try choice.concurrent(.input, readPassword, .{ io, tty, output });
    try choice.concurrent(.signal, promptSignal, .{ io, wake.read });
    const count = switch (try choice.await()) {
        .input => |result| try result,
        .signal => |result| {
            try result;
            return error.VaultPasswordCanceled;
        },
    };
    return output[0..count];
}
fn promptSignal(io: std.Io, file: std.Io.File) !void {
    var bytes: [8]u8 = undefined;
    _ = try file.readStreaming(io, &.{&bytes});
    return error.VaultPasswordCanceled;
}
fn readPassword(io: std.Io, tty: std.Io.File, output: []u8) !usize {
    var count: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        defer std.crypto.secureZero(u8, &byte);
        if (try tty.readStreaming(io, &.{&byte}) == 0) return error.VaultPasswordCanceled;
        switch (byte[0]) {
            3, 4 => return error.VaultPasswordCanceled,
            '\r', '\n' => return if (count == 0) error.InvalidVaultPassword else count,
            8, 127 => count -|= 1,
            0...2, 5...7, 9, 11...12, 14...31 => return error.InvalidVaultPassword,
            else => {
                if (count == output.len) return error.InvalidVaultPassword;
                output[count] = byte[0];
                count += 1;
            },
        }
    }
}

fn newPassword(io: std.Io, password: []u8) ![]const u8 {
    var confirmation: [vt.max_password_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &confirmation);
    const secret = try passwordPrompt(io, "New vault password: ", password);
    const again = try passwordPrompt(io, "Confirm password: ", &confirmation);
    if (!std.mem.eql(u8, secret, again)) return error.VaultPasswordMismatch;
    return secret;
}

/// Display and verify possession before any recovery slot becomes durable.
/// A failed/canceled terminal interaction cannot create an unrecoverable vault.
fn confirmRecovery(io: std.Io, recovery: *const vt.RecoveryKey) !void {
    const tty = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only, .allow_directory = false });
    defer tty.close(io);
    var encoded = recovery_text.format(recovery);
    defer std.crypto.secureZero(u8, &encoded);
    try tty.writeStreamingAll(io, "Recovery key (store privately): ");
    try tty.writeStreamingAll(io, &encoded);
    try tty.writeStreamingAll(io, "\nSave this key separately. It can unlock every account in this vault.\n");
    var confirmation: [recovery_text.input_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &confirmation);
    var parsed = try recovery_text.parse(try passwordPrompt(io, "Confirm recovery key: ", &confirmation));
    defer parsed.wipe();
    if (!std.mem.eql(u8, &parsed.bytes, &recovery.bytes)) return error.RecoveryKeyMismatch;
}

pub fn run(init: @import("../fixed_runtime.zig").Context, io: std.Io, args: *std.process.Args.Iterator) !void {
    const verb = args.next() orelse return error.CommandRequired;
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "help")) {
        return std.Io.File.stdout().writeStreamingAll(io,
            \\omagma vault inventory --source-config PATH --source-grants PATH --source-cache PATH [--source-ui PATH]
            \\omagma vault migrate --vault-dir NEW_PATH --source-config PATH --source-grants PATH --source-cache PATH [--source-ui PATH] [--resume]
            \\omagma vault activate --vault-dir PATH [--socket PATH] [--allow-unavailable-source]
            \\omagma vault start|serve [--vault-dir PATH] [--socket PATH]
            \\omagma vault unlock|lock|status|stop|password|recovery-key|recover [--socket PATH]
            \\omagma vault discard-init --vault-dir PATH
            \\omagma vault init --fixtures --vault-dir PATH
            \\Intentional empty sources: --allow-empty-cache --allow-missing-grants --allow-missing-tokens
            \\Source checks and per-account counts precede password/recovery prompts.
            \\Passwords and recovery keys use a private local terminal; no password hash is stored.
            \\Migration retains original plaintext. Activation is explicit after full verification.
            \\Imported queued sends require a fresh review and explicit resume/send-now.
            \\The daemon starts locked; same-user SSH clients share its private socket.
            \\Slot changes replace managed headers; copied old backups retain old slots.
            \\See docs/ENCRYPTION.md for lifecycle, backups and plaintext export boundaries.
            \\
        );
    }
    var socket_buffer: [108]u8 = undefined;
    var socket_path: []const u8 = try transport.defaultPath(&socket_buffer);
    var vault_path: ?[]const u8 = null;
    var socket_explicit = false;
    var allow_empty_cache = false;
    var allow_missing_grants = false;
    var allow_missing_tokens = false;
    var allow_unavailable_source = false;
    var options: @import("types.zig").Options = .{};
    var source_config: ?[]const u8 = null;
    var source_grants: ?[]const u8 = null;
    var source_cache: ?[]const u8 = null;
    var source_ui: ?[]const u8 = null;
    var resume_copy = false;
    var fixture_stop_after: ?usize = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fixtures")) {
            options.fixtures = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            socket_explicit = true;
            socket_path = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--vault-dir")) {
            vault_path = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--fixture-root")) {
            options.fixture_root = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--fixture-scenario")) {
            options.fixture_scenario = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--source-config")) {
            source_config = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--source-grants")) {
            source_grants = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--source-cache")) {
            source_cache = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--source-ui")) {
            source_ui = args.next() orelse return error.ValueRequired;
        } else if (std.mem.eql(u8, arg, "--allow-empty-cache")) {
            allow_empty_cache = true;
        } else if (std.mem.eql(u8, arg, "--allow-missing-grants")) {
            allow_missing_grants = true;
        } else if (std.mem.eql(u8, arg, "--allow-missing-tokens")) {
            allow_missing_tokens = true;
        } else if (std.mem.eql(u8, arg, "--allow-unavailable-source")) {
            allow_unavailable_source = true;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            resume_copy = true;
        } else if (std.mem.eql(u8, arg, "--fixture-stop-after")) {
            fixture_stop_after = try std.fmt.parseInt(usize, args.next() orelse return error.ValueRequired, 10);
        } else return error.UnknownOption;
    }
    try disableCoreDumps();
    const a = init.allocator;
    var paths: std.heap.ArenaAllocator = .init(a);
    defer paths.deinit();
    const pa = paths.allocator();
    var expected_id: ?vt.Id = null;
    const service_verb = std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "serve");
    const control_verb = std.mem.eql(u8, verb, "unlock") or std.mem.eql(u8, verb, "lock") or std.mem.eql(u8, verb, "status") or std.mem.eql(u8, verb, "stop") or std.mem.eql(u8, verb, "password") or std.mem.eql(u8, verb, "recovery-key") or std.mem.eql(u8, verb, "recover");
    if (!options.fixtures and (service_verb or control_verb) and (!socket_explicit or (service_verb and vault_path == null))) {
        if (try @import("vault_activation.zig").load(io, pa, init.environ_map)) |active| {
            if (!socket_explicit) {
                socket_path = active.socketPath;
                expected_id = try active.id();
            }
            if (service_verb and vault_path == null) vault_path = active.vaultDirectory;
        }
    }
    socket_path = try @import("vault_paths.zig").normalize(io, pa, socket_path, 103);
    if (vault_path) |path| vault_path = try @import("vault_paths.zig").normalize(io, pa, path, 4096);
    if (source_config) |path| source_config = try @import("vault_paths.zig").normalize(io, pa, path, 4096);
    if (source_grants) |path| source_grants = try @import("vault_paths.zig").normalize(io, pa, path, 4096);
    if (source_cache) |path| source_cache = try @import("vault_paths.zig").normalize(io, pa, path, 4096);
    if (source_ui) |path| source_ui = try @import("vault_paths.zig").normalize(io, pa, path, 4096);
    if (service_verb and expected_id != null and vault_path != null) {
        var saved = try @import("vault_header.zig").Store.open(io, vault_path.?, false);
        defer saved.close();
        const requested = (try saved.load()).header.vault_id;
        if (!std.mem.eql(u8, &requested, &expected_id.?)) return error.VaultIdentityMismatch;
    }
    const migration_command = std.mem.eql(u8, verb, "inventory") or std.mem.eql(u8, verb, "migrate") or std.mem.eql(u8, verb, "activate");
    if (migration_command) {
        if (allow_unavailable_source and !std.mem.eql(u8, verb, "activate")) return error.UnknownOption;
        if ((allow_empty_cache or allow_missing_grants or allow_missing_tokens) and std.mem.eql(u8, verb, "activate")) return error.UnknownOption;
        const source: ?@import("vault_migration_journal.zig").Source = if (source_config != null or source_grants != null or source_cache != null or source_ui != null) .{ .config = source_config orelse return error.VaultMigrationSourceRequired, .grants = source_grants orelse return error.VaultMigrationSourceRequired, .cache = source_cache orelse return error.VaultMigrationSourceRequired, .preferences = source_ui, .allow_empty_cache = allow_empty_cache, .allow_missing_grants = allow_missing_grants, .allow_missing_tokens = allow_missing_tokens } else null;
        return @import("vault_migration_cli.zig").run(io, a, init.environ_map, verb, vault_path, socket_path, options, .{ .source = source, .resume_copy = resume_copy, .fixture_stop_after = fixture_stop_after, .allow_unavailable_source = allow_unavailable_source }, .{ .password = passwordPrompt, .new_password = newPassword, .recovery = confirmRecovery });
    }
    if (source_config != null or source_grants != null or source_cache != null or source_ui != null or resume_copy or fixture_stop_after != null or allow_empty_cache or allow_missing_grants or allow_missing_tokens or allow_unavailable_source) return error.UnknownOption;
    if (std.mem.eql(u8, verb, "start")) {
        try @import("vault_launch.zig").start(io, a, vault_path orelse return error.VaultDirectoryRequired, socket_path, options);
        return std.Io.File.stdout().writeStreamingAll(io, "{\"ok\":true,\"data\":{\"started\":true}}\n");
    }
    if (std.mem.eql(u8, verb, "discard-init")) {
        const path = vault_path orelse return error.VaultDirectoryRequired;
        var confirmation: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &confirmation);
        const answer = try passwordPrompt(io, "Retain abandoned ciphertext separately and reset headerless initialization? Type DISCARD: ", &confirmation);
        if (!std.mem.eql(u8, answer, "DISCARD")) return error.VaultPasswordCanceled;
        const retained = try @import("vault_initialization.zig").discard(io, a, path);
        defer if (retained) |bytes| a.free(bytes);
        const response = try @import("json.zig").encodeAlloc(a, .{ .ok = true, .data = .{ .reset = true, .retainedRecords = retained } }, .{});
        defer a.free(response);
        try std.Io.File.stdout().writeStreamingAll(io, response);
        return std.Io.File.stdout().writeStreamingAll(io, "\n");
    }
    if (std.mem.eql(u8, verb, "init") or std.mem.eql(u8, verb, "serve")) {
        const owner = try a.create(Owner);
        defer a.destroy(owner);
        owner.* = try Owner.init(io, a, init.environ_map, vault_path orelse return error.VaultDirectoryRequired, options);
        defer owner.deinit();
        if (std.mem.eql(u8, verb, "serve")) return serve(io, a, owner, socket_path);
        var password: [vt.max_password_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &password);
        const secret = try newPassword(io, &password);
        var recovery = try @import("vault_crypto.zig").createRecoveryKey(io);
        defer recovery.wipe();
        try confirmRecovery(io, &recovery);
        try owner.create(secret, &recovery);
        try owner.lock();
        return std.Io.File.stdout().writeStreamingAll(io, "{\"ok\":true,\"data\":{\"unlocked\":false}}\n");
    }
    if (vault_path != null or options.fixtures or options.fixture_root != null or !std.mem.eql(u8, options.fixture_scenario, "normal")) return error.UnknownOption;
    const kind: transport.Kind = if (std.mem.eql(u8, verb, "unlock")) .unlock else if (std.mem.eql(u8, verb, "lock")) .lock else if (std.mem.eql(u8, verb, "status")) .status else if (std.mem.eql(u8, verb, "stop")) .stop else if (std.mem.eql(u8, verb, "password")) .password_change else if (std.mem.eql(u8, verb, "recovery-key")) .recovery_change else if (std.mem.eql(u8, verb, "recover")) .recover else return error.UnknownCommand;
    if (expected_id) |id| try @import("vault_launch.zig").verifyOwner(io, a, socket_path, id);
    var secret: [32 + vt.max_password_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    const body: []const u8 = switch (kind) {
        .unlock => try passwordPrompt(io, "Vault password: ", secret[0..vt.max_password_bytes]),
        .password_change => try newPassword(io, secret[0..vt.max_password_bytes]),
        .recovery_change => blk: {
            var recovery = try @import("vault_crypto.zig").createRecoveryKey(io);
            defer recovery.wipe();
            try confirmRecovery(io, &recovery);
            @memcpy(secret[0..32], &recovery.bytes);
            break :blk secret[0..32];
        },
        .recover => blk: {
            var input: [recovery_text.input_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &input);
            var recovery = try recovery_text.parse(try passwordPrompt(io, "Recovery key: ", &input));
            defer recovery.wipe();
            @memcpy(secret[0..32], &recovery.bytes);
            const password = try newPassword(io, secret[32..]);
            break :blk secret[0 .. 32 + password.len];
        },
        else => "",
    };
    var client: transport.Client = .{ .io = io, .socket_path = socket_path };
    const response = try client.request(a, kind, body);
    defer {
        std.crypto.secureZero(u8, @constCast(response));
        a.free(response);
    }
    try std.Io.File.stdout().writeStreamingAll(io, response);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

test "vault daemon: interrupted invitation reconciliation keeps unknown outcome" {
    try std.testing.expectEqual(error.Timeout, mutationFailure("{\"cmd\":\"invitation.inspect\"}", error.Timeout));
    try std.testing.expectEqual(error.Timeout, mutationFailure("{\"cmd\":\"invitation.inspect\",\"reconcile\":false}", error.Timeout));
    for ([_]anyerror{ error.Timeout, error.OutOfMemory, error.VaultOperationCanceled }) |err| try std.testing.expectEqual(error.UnknownOutcome, mutationFailure("{\"cmd\":\"invitation.inspect\",\"reconcile\":true}", err));
}

test "vault daemon: timed out and canceled lane acquisition retain exact ownership" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const PendingRequest = struct {
        client: *transport.Client,
        response: ?[]const u8 = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.response = self.client.request(std.testing.allocator, .execute, "{\"cmd\":\"accounts.list\"}") catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const root = try std.fmt.allocPrint(a, "{s}/omagma-lane-test-{s}", .{ @import("vault_paths.zig").temporary_root, std.fmt.bytesToHex(random, .lower) });
    defer a.free(root);
    const directory = try @import("../keyring_file.zig").directory(io, root, true);
    directory.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/vault", .{root});
    defer a.free(path);
    const socket = try std.fmt.allocPrint(a, "{s}/ipc/sock", .{root});
    defer a.free(socket);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    const owner = try a.create(Owner);
    defer a.destroy(owner);
    owner.* = try Owner.init(io, a, &env, path, .{ .fixtures = true });
    defer owner.deinit();
    var recovery: vt.RecoveryKey = .{ .bytes = @splat(0x39) };
    defer recovery.wipe();
    const password = "Synthetic lane ownership password";
    try owner.create(password, &recovery);
    const Scenario = enum { timeout, cancel_acquired, cancel_waiter };
    for ([_]Scenario{ .timeout, .cancel_acquired, .cancel_waiter }, 0..) |scenario, index| {
        if (index != 0) try owner.unlock(password);
        var listener = try transport.Listener.init(io, socket);
        defer listener.deinit();
        var gate: LaneTestGate = .{};
        var server: Server = .{ .io = io, .a = a, .listener = &listener, .owner = owner, .lane_test_gate = &gate };
        // This lane belongs to a different request. Canceling a waiter must
        // leave it alone, unlike canceling an acquisition that actually won.
        if (scenario == .cancel_waiter) server.network_lane.store(true, .release);
        var worker = try io.concurrent(Server.worker, .{&server});
        defer {
            server.stopped.set(io);
            worker.cancel(io) catch {};
        }
        var client: transport.Client = .{ .io = io, .socket_path = socket };
        var pending: PendingRequest = .{ .client = &client };
        defer if (pending.response) |bytes| {
            std.crypto.secureZero(u8, @constCast(bytes));
            a.free(bytes);
        };
        var request = try io.concurrent(PendingRequest.run, .{&pending});
        defer request.cancel(io);
        try platform.deadline(io, platform.seconds(3), std.Io.Event.wait, .{ &gate.entered, io });
        if (scenario != .cancel_waiter) try platform.deadline(io, platform.seconds(3), std.Io.Event.wait, .{ &gate.acquired, io });
        if (scenario != .timeout) {
            // Match serve teardown: stop admission before joining workers.
            server.stopped.set(io);
            worker.cancel(io) catch {};
        }
        request.await(io);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        if (scenario == .timeout) {
            try std.testing.expect(pending.failure == null);
            try std.testing.expect(std.mem.indexOf(u8, pending.response.?, "VaultBusy") != null);
            // A second round trip through this sole worker proves the failed
            // request's cleanup finished before inspecting lane ownership.
            _ = try client.request(arena.allocator(), .status, "");
        } else if (scenario == .cancel_waiter and pending.failure == null) {
            // Cancellation may race the bounded Busy response; neither may
            // release the other request's lane or execute this request.
            const denied = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), pending.response.?, .{});
            try std.testing.expect(!denied.object.get("ok").?.bool);
            try std.testing.expectEqualStrings("VaultBusy", denied.object.get("error").?.object.get("code").?.string);
        } else {
            try std.testing.expect(pending.failure != null);
        }
        try std.testing.expectEqual(scenario == .cancel_waiter, server.network_lane.load(.acquire));
        if (scenario == .cancel_waiter) server.network_lane.store(false, .release);
        if (scenario != .timeout) {
            server.stopped.reset();
            worker = try io.concurrent(Server.worker, .{&server});
        }
        const response = try client.request(arena.allocator(), .execute, "{\"cmd\":\"accounts.list\"}");
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});
        try std.testing.expect(parsed.object.get("ok").?.bool);
        _ = try client.request(arena.allocator(), .lock, "");
        try std.testing.expect(!owner.unlocked());
        _ = try client.request(arena.allocator(), .stop, "");
        try worker.await(io);
        try std.testing.expect(!server.network_lane.load(.acquire));
    }
}
