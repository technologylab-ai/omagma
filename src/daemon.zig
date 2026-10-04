const std = @import("std");
const linux = std.os.linux;
const l = @import("limits.zig");
const b = @import("bounded.zig");
const model = @import("model.zig");
const Config = @import("config.zig").Config;
const protocol = @import("protocol.zig");
const gmail = @import("providers/gmail.zig");
const open = @import("open_target.zig");
const keyring = @import("keyring.zig");
const platform = @import("platform.zig");

pub const Options = struct { fixtures: bool = false, dry_open: bool = false, fixture_delay_ms: u32 = 0, fixture_fail: []const u8 = "", fixture_empty: []const u8 = "", fixture_rows: usize = 8, fixture_fail_after: u64 = std.math.maxInt(u64), fixture_auto_refresh_ms: u32 = 0 };
var parse_storage: [l.json_workspace / 2]u8 align(16) = undefined;
var output_storage: [l.output_frame]u8 = undefined;
var state: Daemon = undefined;
var worker: Worker = undefined;
const Reply = struct { id: ?u64 = null, code: b.Text(64) = .{}, status: bool = false, target: ?open.Target = null };
const reply_count = 64;

const Worker = struct {
    io: std.Io,
    config: *const Config,
    options: Options,
    address: b.Text(l.max_address) = .{},
    profile: b.Text(128) = .{},
    fixture_jobs: u64 = 0,
    start_event: std.Io.Event = .unset,
    cancel_event: std.Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    event_fd: i32,
    snapshot: model.Snapshot = .{},
    metrics: gmail.Metrics = .{},
    result: ?anyerror = null,
    fn cancelWait(self: *Worker) std.Io.Cancelable!void {
        try self.cancel_event.wait(self.io);
    }
    fn job(self: *Worker) anyerror!void {
        var a: model.Account = .{};
        a.address = self.address;
        a.profile = self.profile;
        if (self.options.fixtures) {
            if (self.options.fixture_delay_ms > 0) try std.Io.sleep(self.io, .fromMilliseconds(self.options.fixture_delay_ms), .awake);
            if (std.mem.eql(u8, self.options.fixture_fail, a.address.slice()) or self.fixture_jobs > self.options.fixture_fail_after) return error.TransientFailure;
            try gmail.fixture(self.io, &a, &self.snapshot, &self.metrics, std.mem.eql(u8, self.options.fixture_empty, a.address.slice()), self.options.fixture_rows);
        } else try gmail.refresh(self.io, self.config, &a, &self.snapshot, &self.metrics);
    }
    fn runJob(self: *Worker) anyerror!void {
        const Event = union(enum) { job: anyerror!void, cancel: std.Io.Cancelable!void };
        var events: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(self.io, &events);
        defer select.cancelDiscard();
        try select.concurrent(.job, job, .{self});
        try select.concurrent(.cancel, cancelWait, .{self});
        switch (try select.await()) {
            .job => |r| try r,
            .cancel => |r| {
                try r;
                return error.Canceled;
            },
        }
    }
    fn run(self: *Worker) void {
        while (true) {
            self.start_event.waitUncancelable(self.io);
            self.start_event.reset();
            if (self.stop.load(.acquire)) break;
            self.metrics = .{};
            self.result = null;
            platform.deadline(self.io, platform.seconds(l.job_seconds), runJob, .{self}) catch |err| {
                self.result = err;
            };
            self.done.store(true, .release);
            var n: u64 = 1;
            _ = linux.write(self.event_fd, std.mem.asBytes(&n).ptr, 8);
        }
    }
};
const Daemon = struct {
    io: std.Io,
    config: *Config,
    options: Options,
    selected: usize,
    visible: bool = false,
    active: ?usize = null,
    active_previous_state: model.State = .never,
    auto_due: ?std.Io.Clock.Timestamp = null,
    cancelled: bool = false,
    framer: protocol.Framer = .{},
    replies: [reply_count]Reply = @splat(.{}),
    reply_head: usize = 0,
    reply_len: usize = 0,
    dirty: [l.max_accounts]bool = @splat(false),
    out_len: usize = 0,
    out_pos: usize = 0,
    metrics: gmail.Metrics = .{},
    refresh_jobs: u64 = 0,
    dropped_replies: u64 = 0,
    overflow_notice: bool = false,
    fn now(self: *Daemon) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }
    fn autoIntervalMs(self: *const Daemon) u32 {
        if (self.options.fixtures and self.options.fixture_auto_refresh_ms > 0) return self.options.fixture_auto_refresh_ms;
        return self.config.refresh_seconds * 1000;
    }
    fn autoEnabled(self: *const Daemon) bool {
        return self.autoIntervalMs() > 0;
    }
    fn scheduleAutomatic(self: *Daemon) void {
        const interval = self.autoIntervalMs();
        if (interval == 0) return;
        if (self.auto_due) |due| {
            if (due.durationFromNow(self.io).raw.toNanoseconds() > 0) return;
        }
        // One deadline, never a catch-up loop. Scheduling uses existing bounded
        // account flags and the one refresh worker, including while closed.
        self.auto_due = .fromNow(self.io, .{ .clock = .awake, .raw = .fromMilliseconds(interval) });
        for (self.config.accounts[0..self.config.count]) |*a| {
            if (!a.enabled or a.state == .disconnected or a.retry_at > self.now()) continue;
            a.pending = true;
        }
    }
    fn pollTimeout(self: *Daemon) i32 {
        const due = self.auto_due orelse return -1;
        const ns = due.durationFromNow(self.io).raw.toNanoseconds();
        if (ns <= 0) return 0;
        return @intCast(@min(@divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
    }
    fn queue(self: *Daemon, reply: Reply) !void {
        if (self.reply_len == reply_count) {
            // The caller has exceeded the documented64-request window. Keep
            // reading control messages so closing a popup still cancels work.
            // Replace the oldest receipt; one coalesced error tells the UI to
            // discard its ledger. Normal clients cannot enter this branch.
            self.reply_head = (self.reply_head + 1) % reply_count;
            self.reply_len -= 1;
            self.dropped_replies += 1;
            self.overflow_notice = true;
        }
        self.replies[(self.reply_head + self.reply_len) % reply_count] = reply;
        self.reply_len += 1;
    }
    fn ack(self: *Daemon, id: ?u64, code: ?[]const u8) !void {
        var r: Reply = .{ .id = id };
        if (code) |c| try r.code.set(c);
        try self.queue(r);
    }
    fn request(self: *Daemon, req: protocol.Request) !void {
        if (std.mem.eql(u8, req.cmd, "hello") or std.mem.eql(u8, req.cmd, "status")) {
            try self.queue(.{ .id = req.id, .status = true });
            return;
        }
        if (std.mem.eql(u8, req.cmd, "visibility")) {
            const visible = req.open orelse return error.InvalidRequest;
            if (req.account) |address| self.selected = self.config.index(address) orelse return error.UnknownAccount;
            self.visible = visible;
            if (!visible) {
                if (!self.autoEnabled()) {
                    for (self.config.accounts[0..self.config.count]) |*a| a.pending = false;
                    if (self.active != null) {
                        self.cancelled = true;
                        worker.cancel_event.set(self.io);
                    }
                }
            } else try self.schedule(self.selected, false);
            try self.ack(req.id, null);
            return;
        }
        const index = self.config.index(req.account orelse return error.AccountRequired) orelse return error.UnknownAccount;
        const a = &self.config.accounts[index];
        if (std.mem.eql(u8, req.cmd, "select")) {
            self.selected = index;
            if (self.visible) try self.schedule(index, false);
            try self.ack(req.id, null);
        } else if (std.mem.eql(u8, req.cmd, "refresh")) {
            if (!self.visible) return error.PopupClosed;
            try self.schedule(index, true);
            try self.ack(req.id, null);
        } else if (std.mem.eql(u8, req.cmd, "open")) {
            const kind = req.kind orelse return error.KindRequired;
            var message: ?*const model.Message = null;
            if (std.mem.eql(u8, kind, "message")) {
                const id = req.message orelse return error.MessageRequired;
                try b.identifier(id);
                for (a.snapshot.messages[0..a.snapshot.count]) |*m| if (std.mem.eql(u8, m.id.slice(), id)) {
                    message = m;
                    break;
                };
                if (message == null) return error.UnknownMessage;
            } else if (!std.mem.eql(u8, kind, "inbox")) return error.InvalidKind;
            const target = try open.make(a, message, req.fallback);
            if (self.options.dry_open) try self.queue(.{ .id = req.id, .target = target }) else {
                try open.launch(self.io, self.config, a, &target);
                try self.ack(req.id, null);
            }
        } else if (std.mem.eql(u8, req.cmd, "disconnect")) {
            if (self.active == index) {
                self.cancelled = true;
                worker.cancel_event.set(self.io);
            }
            a.pending = false;
            if (!self.options.fixtures) try keyring.clear(self.io, a.address.slice());
            a.snapshot = .{};
            a.state = .disconnected;
            a.error_code = .{};
            a.bump();
            self.dirty[index] = true;
            try self.ack(req.id, null);
        } else return error.UnknownCommand;
    }
    fn schedule(self: *Daemon, index: usize, force: bool) !void {
        const a = &self.config.accounts[index];
        if (!a.enabled) return; // optional account remains visible with browser action
        if (a.retry_at > self.now()) return error.RetryLater;
        if (!force and a.snapshot.checked_at > 0 and self.now() - a.snapshot.checked_at < l.freshness_seconds) return;
        a.pending = true;
    }
    fn startJob(self: *Daemon) void {
        if ((!self.visible and !self.autoEnabled()) or self.active != null) return;
        var index: ?usize = null;
        if (self.config.accounts[self.selected].pending) index = self.selected else for (self.config.accounts[0..self.config.count], 0..) |a, i| {
            if (a.pending) {
                index = i;
                break;
            }
        }
        const i = index orelse return;
        const a = &self.config.accounts[i];
        a.pending = false;
        self.active_previous_state = a.state;
        a.state = .loading;
        a.bump();
        self.dirty[i] = true;
        a.fixture_jobs += 1;
        worker.fixture_jobs = a.fixture_jobs;
        worker.address = a.address;
        worker.profile = a.profile;
        worker.cancel_event.reset();
        worker.done.store(false, .release);
        self.cancelled = false;
        self.active = i;
        self.refresh_jobs += 1;
        worker.start_event.set(self.io);
    }
    fn completeJob(self: *Daemon) void {
        if (!worker.done.load(.acquire)) return;
        worker.done.store(false, .release);
        const i = self.active orelse return;
        const a = &self.config.accounts[i];
        self.metrics.http_peak = @max(self.metrics.http_peak, worker.metrics.http_peak);
        self.metrics.json_peak = @max(self.metrics.json_peak, worker.metrics.json_peak);
        self.metrics.rejected += worker.metrics.rejected;
        if (self.cancelled or (!self.visible and !self.autoEnabled())) {
            // Closing is normal. Keep the last successful status and any
            // pre-existing error; cancellation did not invalidate that cache.
            if (a.state == .loading) {
                a.state = self.active_previous_state;
                a.bump();
            }
        } else if (worker.result) |err| {
            const disconnected = err == error.InvalidGrant or err == error.NotConnected or err == error.OAuthClientRequired or err == error.WrongAccount;
            a.fail(@errorName(err), disconnected);
            if (worker.metrics.retry_after > 0 or err == error.RateLimited or err == error.TransientFailure) a.retry_at = self.now() + @as(i64, @max(worker.metrics.retry_after, 5));
        } else {
            a.publish(&worker.snapshot);
            if (worker.metrics.retry_after > 0) a.retry_at = self.now() + @as(i64, worker.metrics.retry_after);
        }
        self.active = null;
        self.dirty[i] = true;
    }
    fn line(self: *Daemon, raw: []const u8) !void {
        var allocator = std.heap.FixedBufferAllocator.init(&parse_storage);
        const parsed = b.parse(allocator.allocator(), raw) catch |err| {
            if (err == error.OutOfMemory) self.metrics.rejected += 1;
            try self.ack(null, @errorName(err));
            return;
        };
        defer parsed.deinit();
        const req = protocol.Request.from(parsed.value) catch |err| {
            try self.ack(null, @errorName(err));
            return;
        };
        self.request(req) catch |err| {
            try self.ack(req.id, @errorName(err));
        };
    }
    fn formatOutput(self: *Daemon) !void {
        if (self.out_pos < self.out_len) return;
        self.out_len = 0;
        self.out_pos = 0;
        var w = std.Io.Writer.fixed(&output_storage);
        if (self.reply_len > 0) {
            const r = &self.replies[self.reply_head];
            try w.writeAll("{\"re\":");
            if (r.id) |id| try w.print("{d}", .{id}) else try w.writeAll("null");
            try w.print(",\"ok\":{s}", .{if (r.code.len == 0) "true" else "false"});
            if (r.code.len > 0) {
                try w.writeAll(",\"error\":");
                try b.jsonString(&w, r.code.slice());
            }
            if (r.status) {
                try w.writeAll(",\"version\":1,\"selected\":");
                try b.jsonString(&w, self.config.accounts[self.selected].address.slice());
                try w.writeAll(",\"accounts\":[");
                for (self.config.accounts[0..self.config.count], 0..) |*a, i| {
                    if (i > 0) try w.writeByte(',');
                    try model.writeSnapshot(&w, a, false);
                }
                try w.writeAll("]");
                var pending: usize = 0;
                var rows: usize = 0;
                for (self.config.accounts[0..self.config.count]) |a| {
                    if (a.pending) pending += 1;
                    rows += a.snapshot.count;
                }
                try w.print(",\"metrics\":{{\"reservationBytes\":{d},\"snapshotBytes\":{d},\"httpPeakBytes\":{d},\"jsonPeakBytes\":{d},\"rejectedAllocations\":{d},\"refreshJobs\":{d},\"retainedRows\":{d},\"activeJobs\":{d},\"pendingJobs\":{d}}}", .{ l.app_reservation, @sizeOf(model.Snapshot) * (l.max_accounts + 1), self.metrics.http_peak, self.metrics.json_peak, self.metrics.rejected, self.refresh_jobs, rows, @as(u8, if (self.active != null) 1 else 0), pending });
            }
            if (r.target) |*t| {
                try w.writeAll(",\"argv\":[");
                try b.jsonString(&w, self.config.chrome.slice());
                try w.writeByte(',');
                try b.jsonString(&w, t.profile_arg.slice());
                try w.writeByte(',');
                try b.jsonString(&w, t.url.slice());
                try w.writeByte(']');
            }
            try w.writeAll("}\n");
            self.reply_head = (self.reply_head + 1) % reply_count;
            self.reply_len -= 1;
        } else if (self.overflow_notice) {
            try w.writeAll("{\"ev\":\"error\",\"error\":\"ReplyWindowExceeded\"}\n");
            self.overflow_notice = false;
        } else if (self.visible) {
            for (self.dirty[0..self.config.count], 0..) |dirty, i| if (dirty) {
                try model.writeSnapshot(&w, &self.config.accounts[i], true);
                try w.writeByte('\n');
                self.dirty[i] = false;
                break;
            };
        }
        self.out_len = w.buffered().len;
    }
};
fn nonblocking(fd: i32) !void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.FcntlFailed;
    const extra: linux.O = .{ .NONBLOCK = true };
    // O has an explicit u32 backing integer on both supported architectures.
    // Preserve its scalar flag value without a memory or lane conversion.
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | flagBits(extra))) != .SUCCESS) return error.FcntlFailed;
}
fn flagBits(flags: linux.O) u32 {
    return @backingInt(flags);
}
test "fcntl flags preserve Linux x86_64 and arm64 scalar bits" {
    // Linux UAPI O_NONBLOCK=00004000 on both supported architectures.
    try std.testing.expectEqual(@as(u32, 0x800), flagBits(.{ .NONBLOCK = true }));
    try std.testing.expectEqual(@as(u32, 0x400), flagBits(.{ .APPEND = true }));
    try std.testing.expectEqual(@as(u32, 0xc00), flagBits(.{ .APPEND = true, .NONBLOCK = true }));
    try std.testing.expectEqual(@as(u32, 0), flagBits(.{}));
}
test "raw fcntl errors remain kernel errors when linked with musl" {
    // Linux UAPI EBADF=9. Raw syscalls return -9, whereas libc returns -1
    // and stores errno separately. Never decode a raw result via posix.errno.
    try std.testing.expectEqual(@as(u16, 9), @as(u16, @intCast(@backingInt(linux.errno(linux.fcntl(-1, linux.F.GETFL, 0))))));
    try std.testing.expectError(error.FcntlFailed, nonblocking(-1));
}
pub fn run(io: std.Io, config: *Config, options: Options) !void {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(result) != .SUCCESS) return error.EventFdFailed;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);
    try nonblocking(0);
    try nonblocking(1);
    worker = .{ .io = io, .config = config, .options = options, .event_fd = fd };
    const thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Worker.run, .{&worker});
    defer {
        worker.stop.store(true, .release);
        worker.cancel_event.set(io);
        worker.start_event.set(io);
        thread.join();
    }
    state = .{ .io = io, .config = config, .options = options, .selected = config.initial() };
    var eof = false;
    var chunk: [4096]u8 = undefined;
    while (true) {
        state.completeJob();
        if (!eof) state.scheduleAutomatic();
        state.startJob();
        try state.formatOutput();
        if (eof and state.active == null and state.out_pos == state.out_len and state.reply_len == 0) break;
        var fds = [_]linux.pollfd{
            .{ .fd = if (!eof) 0 else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (state.out_pos < state.out_len) 1 else -1, .events = linux.POLL.OUT, .revents = 0 },
        };
        const p = linux.poll(&fds, fds.len, if (eof) -1 else state.pollTimeout());
        if (linux.errno(p) == .INTR) continue;
        if (linux.errno(p) != .SUCCESS) return error.PollFailed;
        if (fds[1].revents & linux.POLL.IN != 0) {
            var n: u64 = 0;
            _ = linux.read(fd, std.mem.asBytes(&n).ptr, 8);
        }
        if (fds[2].revents & linux.POLL.OUT != 0) {
            const bytes = output_storage[state.out_pos..state.out_len];
            const written = linux.write(1, bytes.ptr, bytes.len);
            switch (linux.errno(written)) {
                .SUCCESS => state.out_pos += written,
                .AGAIN, .INTR => {},
                else => return error.OutputClosed,
            }
        }
        if (fds[2].revents & (linux.POLL.ERR | linux.POLL.HUP) != 0) return error.OutputClosed;
        if (fds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            // Input is consumed even with stalled output so close/cancel commands
            // stay effective; receipts have a fixed64-request window.
            const n = linux.read(0, &chunk, 1);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) {
                        eof = true;
                        state.visible = false;
                        for (config.accounts[0..config.count]) |*a| a.pending = false;
                        if (state.active != null) {
                            state.cancelled = true;
                            worker.cancel_event.set(io);
                        }
                    }
                    for (chunk[0..n]) |c| switch (state.framer.byte(c)) {
                        .pending => {},
                        .line => |raw| try state.line(raw),
                        .overflow => try state.ack(null, "FrameTooLarge"),
                    };
                },
                .AGAIN, .INTR => {},
                else => return error.InputFailed,
            }
        }
    }
}

pub const reservation_bytes = @sizeOf(@TypeOf(parse_storage)) + @sizeOf(@TypeOf(output_storage)) + @sizeOf(Daemon) + @sizeOf(Worker) + 128;
