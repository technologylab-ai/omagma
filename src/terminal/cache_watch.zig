const std = @import("std");
const types = @import("types.zig");

pub const Activity = struct { inboxArrivalCount: u64, generation: u64, lastSyncAt: i64 };
pub const Updates = struct { mask: u8, values: [3]?Activity };

/// Watch only index identity while idle. Read local activity after an atomic
/// replacement, on a separate task from both terminal input and provider work.
pub const Watch = struct {
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    client: types.Client = undefined,
    accounts: [3][]const u8 = @splat(""),
    stamps: [3]?types.CacheStamp = @splat(null),
    latest: [3]?Activity = @splat(null),
    mutex: std.Io.Mutex = .init,
    changed: std.atomic.Value(u8) = .init(0),
    posted: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    context: *anyopaque = undefined,
    postFn: *const fn (*anyopaque) anyerror!bool = undefined,
    // Optional lightweight UI wakeup piggybacks this existing finite wait;
    // it does not add a polling task or hold the cache mutex.
    idleFn: ?*const fn (*anyopaque) anyerror!void = null,

    fn read(self: *Watch, allocator: std.mem.Allocator, account: []const u8) !Activity {
        const request = try std.json.Stringify.valueAlloc(allocator, .{ .cmd = "cache.activity", .account = account }, .{});
        const response = try self.client.callCached(allocator, request);
        if (response.len > 4096) return error.ResponseTooLarge;
        const Envelope = struct { ok: bool, data: ?Activity = null, @"error": ?struct { code: []const u8 } = null };
        const value = try std.json.parseFromSliceLeaky(Envelope, allocator, response, .{ .allocate = .alloc_always, .max_value_len = 4096, .ignore_unknown_fields = true });
        if (!value.ok) {
            if (value.@"error") |failure| if (std.mem.eql(u8, failure.code, "Canceled")) return error.Canceled;
            return error.CacheActivityUnavailable;
        }
        return value.data orelse error.InvalidCacheActivity;
    }

    pub fn prime(self: *Watch) !void {
        if (self.client.cacheStampFn == null or self.client.cachedFn == null) return;
        for (self.accounts, 0..) |account, index| {
            if (account.len == 0) continue;
            const stamp = self.client.cacheStamp(account) catch |err| if (err == error.Canceled) return err else continue;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const activity = self.read(arena.allocator(), account) catch |err| if (err == error.Canceled) return err else continue;
            self.stamps[index] = stamp;
            self.latest[index] = activity;
        }
    }

    pub fn start(self: *Watch) !void {
        if (self.client.cacheStampFn == null or self.client.cachedFn == null) return;
        self.stopping.store(false, .release);
        self.future = try self.io.concurrent(run, .{self});
    }

    pub fn stop(self: *Watch) void {
        // Cancellation is acknowledged once. A cache callback may encode it
        // into a response; owner shutdown must remain visible independently.
        self.stopping.store(true, .release);
        if (self.future) |*future| future.cancel(self.io);
        self.future = null;
    }

    fn run(self: *Watch) void {
        while (!self.stopping.load(.acquire)) {
            std.Io.sleep(self.io, .fromSeconds(1), .awake) catch return;
            if (self.stopping.load(.acquire)) return;
            if (self.idleFn) |idle| idle(self.context) catch |err| {
                if (err == error.Canceled) return;
            };
            for (self.accounts, 0..) |account, index| {
                if (self.stopping.load(.acquire)) return;
                if (account.len == 0) continue;
                const stamp = self.client.cacheStamp(account) catch |err| if (err == error.Canceled) return else continue;
                if (std.meta.eql(stamp, self.stamps[index]) and self.latest[index] != null) continue;
                var arena: std.heap.ArenaAllocator = .init(self.allocator);
                defer arena.deinit();
                const activity = self.read(arena.allocator(), account) catch |err| if (err == error.Canceled) return else continue;
                if (self.stopping.load(.acquire)) return;
                self.mutex.lock(self.io) catch return;
                self.latest[index] = activity;
                self.stamps[index] = stamp;
                _ = self.changed.fetchOr(@as(u8, 1) << @intCast(index), .release);
                self.mutex.unlock(self.io);
            }
            if (self.changed.load(.acquire) != 0 and !self.posted.swap(true, .acq_rel)) {
                const accepted = self.postFn(self.context) catch |err| if (err == error.Canceled) return else false;
                if (!accepted) self.posted.store(false, .release);
            }
        }
    }

    pub fn take(self: *Watch) !Updates {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const mask = self.changed.swap(0, .acq_rel);
        self.posted.store(false, .release);
        return .{ .mask = mask, .values = self.latest };
    }
};

test "cache watcher cancellation terminates after a cache call acknowledges it" {
    const Probe = struct {
        const Mode = enum { stamp, raw_activity, encoded_activity };
        io: std.Io,
        mode: Mode,
        entered: std.Io.Event = .unset,
        hold: std.Io.Event = .unset,
        acknowledged: std.atomic.Value(bool) = .init(false),
        fn awaitCancellation(self: *@This()) !void {
            self.entered.set(self.io);
            self.hold.wait(self.io) catch |err| {
                if (err == error.Canceled) self.acknowledged.store(true, .release);
                return err;
            };
            return error.UnexpectedRelease;
        }
        fn stamp(ctx: *anyopaque, _: []const u8) !?types.CacheStamp {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.mode == .stamp) try self.awaitCancellation();
            return .{ .inode = 1, .size = 1, .mtime_ns = 1 };
        }
        fn activity(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.awaitCancellation() catch |err| {
                if (err == error.Canceled and self.mode == .encoded_activity)
                    return allocator.dupe(u8, "{\"ok\":false,\"error\":{\"code\":\"Canceled\"}}");
                return err;
            };
            return error.UnexpectedRelease;
        }
        fn post(_: *anyopaque) !bool {
            return error.UnexpectedCacheEvent;
        }
    };
    for ([_]Probe.Mode{ .stamp, .raw_activity, .encoded_activity }) |mode| {
        var probe: Probe = .{ .io = std.testing.io, .mode = mode };
        var watch: Watch = .{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .client = .{ .ctx = &probe, .callFn = Probe.activity, .cachedFn = Probe.activity, .cacheStampFn = Probe.stamp },
            .accounts = .{ "personal@example.com", "", "" },
            .context = &probe,
            .postFn = Probe.post,
        };
        try watch.start();
        defer watch.stop();
        try probe.entered.waitTimeout(probe.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        const before = std.Io.Timestamp.now(probe.io, .awake);
        watch.stop();
        const elapsed = before.durationTo(std.Io.Timestamp.now(probe.io, .awake));
        try std.testing.expect(elapsed.toMilliseconds() < 1000);
        try std.testing.expect(probe.acknowledged.load(.acquire));
        try std.testing.expect(watch.future == null);
    }
}
