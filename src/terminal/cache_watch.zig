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
    future: ?std.Io.Future(void) = null,
    context: *anyopaque = undefined,
    postFn: *const fn (*anyopaque) anyerror!bool = undefined,

    fn read(self: *Watch, allocator: std.mem.Allocator, account: []const u8) !Activity {
        const request = try std.json.Stringify.valueAlloc(allocator, .{ .cmd = "cache.activity", .account = account }, .{});
        const response = try self.client.callCached(allocator, request);
        if (response.len > 4096) return error.ResponseTooLarge;
        const Envelope = struct { ok: bool, data: ?Activity = null };
        const value = try std.json.parseFromSliceLeaky(Envelope, allocator, response, .{ .allocate = .alloc_always, .max_value_len = 4096, .ignore_unknown_fields = true });
        if (!value.ok) return error.CacheActivityUnavailable;
        return value.data orelse error.InvalidCacheActivity;
    }

    pub fn prime(self: *Watch) void {
        if (self.client.cacheStampFn == null or self.client.cachedFn == null) return;
        for (self.accounts, 0..) |account, index| {
            if (account.len == 0) continue;
            const stamp = self.client.cacheStamp(account) catch continue;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const activity = self.read(arena.allocator(), account) catch continue;
            self.stamps[index] = stamp;
            self.latest[index] = activity;
        }
    }

    pub fn start(self: *Watch) !void {
        if (self.client.cacheStampFn == null or self.client.cachedFn == null) return;
        self.future = try self.io.concurrent(run, .{self});
    }

    pub fn stop(self: *Watch) void {
        if (self.future) |*future| future.cancel(self.io);
        self.future = null;
    }

    fn run(self: *Watch) void {
        while (true) {
            std.Io.sleep(self.io, .fromSeconds(1), .awake) catch return;
            for (self.accounts, 0..) |account, index| {
                if (account.len == 0) continue;
                const stamp = self.client.cacheStamp(account) catch continue;
                if (std.meta.eql(stamp, self.stamps[index]) and self.latest[index] != null) continue;
                var arena: std.heap.ArenaAllocator = .init(self.allocator);
                defer arena.deinit();
                const activity = self.read(arena.allocator(), account) catch continue;
                self.mutex.lock(self.io) catch return;
                self.latest[index] = activity;
                self.stamps[index] = stamp;
                _ = self.changed.fetchOr(@as(u8, 1) << @intCast(index), .release);
                self.mutex.unlock(self.io);
            }
            if (self.changed.load(.acquire) != 0 and !self.posted.swap(true, .acq_rel)) {
                const accepted = self.postFn(self.context) catch false;
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
