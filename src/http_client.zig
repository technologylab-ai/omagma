const std = @import("std");
const limits = @import("limits.zig");
const platform = @import("platform.zig");
var slab: [limits.http_workspace]u8 align(16) = undefined;
var reserved = std.atomic.Value(bool).init(false);

const Workspace = struct {
    fixed: std.heap.FixedBufferAllocator,
    peak: usize = 0,
    rejected: usize = 0,
    fn allocator(self: *Workspace) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const s: *Workspace = @ptrCast(@alignCast(ctx));
        const p = s.fixed.allocator().rawAlloc(len, alignment, ret) orelse {
            s.rejected += 1;
            return null;
        };
        s.peak = @max(s.peak, s.fixed.end_index);
        return p;
    }
    fn resize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const s: *Workspace = @ptrCast(@alignCast(ctx));
        if (!s.fixed.allocator().rawResize(mem, alignment, len, ret)) {
            s.rejected += 1;
            return false;
        }
        s.peak = @max(s.peak, s.fixed.end_index);
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const s: *Workspace = @ptrCast(@alignCast(ctx));
        const p = s.fixed.allocator().rawRemap(mem, alignment, len, ret) orelse {
            s.rejected += 1;
            return null;
        };
        s.peak = @max(s.peak, s.fixed.end_index);
        return p;
    }
    fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const s: *Workspace = @ptrCast(@alignCast(ctx));
        s.fixed.allocator().rawFree(mem, alignment, ret);
    }
};

pub const Response = struct { status: u16, body: []const u8, retry_after: u32 = 0 };
pub const terminal_probe_body_bytes = 128 * 1024;
/// Credential-free wire oracle input. Only the caller's bounded storage is used.
pub fn terminalProbeBody(out: []u8) ![]const u8 {
    if (out.len < terminal_probe_body_bytes) return error.ProbeBufferTooSmall;
    const body = out[0..terminal_probe_body_bytes];
    const prefix = "{\"payload\":\"";
    @memcpy(body[0..prefix.len], prefix);
    @memset(body[prefix.len .. body.len - 2], 'x');
    @memcpy(body[body.len - 2 ..], "\"}");
    return body;
}
pub const Client = struct {
    io: std.Io,
    workspace: Workspace,
    inner: ?std.http.Client = null,
    job_deadline: std.Io.Clock.Timestamp,
    pub fn init(io: std.Io) !Client {
        if (reserved.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.ClientAlreadyActive;
        return .{ .io = io, .workspace = .{ .fixed = .init(&slab) }, .job_deadline = .fromNow(io, platform.seconds(limits.job_seconds)) };
    }
    pub fn deinit(self: *Client) void {
        if (self.inner) |*inner| inner.deinit();
        self.inner = null;
        std.crypto.secureZero(u8, slab[0..self.workspace.peak]);
        reserved.store(false, .release);
    }
    pub fn peakBytes(self: *const Client) usize {
        return self.workspace.peak;
    }
    pub fn rejectedAllocations(self: *const Client) usize {
        return self.workspace.rejected;
    }
    pub fn request(self: *Client, url: []const u8, method: std.http.Method, token: ?[]const u8, form: ?[]const u8, out: []u8) !Response {
        const remaining = self.job_deadline.durationFromNow(self.io);
        if (remaining.raw.toNanoseconds() <= 0) return error.Timeout;
        const duration: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromNanoseconds(@min(remaining.raw.toNanoseconds(), @as(i96, limits.request_seconds) * std.time.ns_per_s)) };
        return try platform.deadline(self.io, duration, requestInner, .{ self, url, method, token, form, out, false, false });
    }
    /// Terminal-only JSON policy. The bar wrapper retains its original hosts,
    /// form cap and response cap. Caller-owned storage remains bounded.
    pub fn requestTerminal(self: *Client, url: []const u8, method: std.http.Method, token: ?[]const u8, json_body: ?[]const u8, out: []u8) !Response {
        const remaining = self.job_deadline.durationFromNow(self.io);
        if (remaining.raw.toNanoseconds() <= 0) return error.Timeout;
        const duration: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromNanoseconds(@min(remaining.raw.toNanoseconds(), @as(i96, limits.request_seconds) * std.time.ns_per_s)) };
        return try platform.deadline(self.io, duration, requestInner, .{ self, url, method, token, json_body, out, false, true });
    }
    /// Credential-free loopback only, for synthetic transport verification.
    pub fn requestLoopback(self: *Client, url: []const u8, out: []u8) !Response {
        return try platform.deadline(self.io, platform.seconds(limits.request_seconds), requestInner, .{ self, url, .GET, null, null, out, true, false });
    }
    /// Wire regression probe: a fixed fake bearer, never user credentials,
    /// and requestInner restricts the destination to plain HTTP 127.0.0.1.
    pub fn requestLoopbackBearerProbe(self: *Client, url: []const u8, out: []u8) !Response {
        return try platform.deadline(self.io, platform.seconds(limits.request_seconds), requestInner, .{ self, url, .GET, @as(?[]const u8, "synthetic-omagma-bearer"), null, out, true, false });
    }
    /// Test-only POST policy: fixed synthetic bearer, JSON terminal limits, and
    /// plain HTTP 127.0.0.1 only. This cannot transmit real credentials or reach
    /// production hosts, and it exercises the same requestInner wire path.
    pub fn requestLoopbackTerminalProbe(self: *Client, url: []const u8, json_body: []const u8, out: []u8) !Response {
        const remaining = self.job_deadline.durationFromNow(self.io);
        if (remaining.raw.toNanoseconds() <= 0) return error.Timeout;
        const duration: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromNanoseconds(@min(remaining.raw.toNanoseconds(), @as(i96, limits.request_seconds) * std.time.ns_per_s)) };
        return try platform.deadline(self.io, duration, requestInner, .{ self, url, .POST, @as(?[]const u8, "synthetic-omagma-bearer"), @as(?[]const u8, json_body), out, true, true });
    }
    fn requestInner(self: *Client, url: []const u8, method: std.http.Method, token: ?[]const u8, form: ?[]const u8, out: []u8, loopback: bool, terminal: bool) anyerror!Response {
        if (out.len > (if (terminal) @as(usize, 3 * limits.MiB) else limits.response)) return error.ResponseBufferTooLarge;
        if (url.len > 4096) return error.UrlTooLarge;
        const uri = try std.Uri.parse(url);
        try validateDestination(uri, loopback, terminal);
        // Refuse oversized payloads before client.request can acquire a TCP
        // connection. This applies equally to the existing bar form wrapper.
        if (form) |f| if (f.len > (if (terminal) @as(usize, 3 * limits.MiB) else 32 * 1024)) return error.FormTooLarge;
        if (self.inner == null) self.inner = .{ .allocator = self.workspace.allocator(), .io = self.io, .read_buffer_size = limits.headers, .connection_pool = .{ .free_size = 0 } };
        var authorization: [limits.secret + 7]u8 = undefined;
        defer std.crypto.secureZero(u8, &authorization);
        const bearer: ?[]const u8 = if (token) |t| blk: {
            if (t.len == 0 or t.len > limits.secret) return error.InvalidToken;
            for (t) |b| if (b <= 32 or b >= 127) return error.InvalidToken;
            break :blk try std.fmt.bufPrint(&authorization, "Bearer {s}", .{t});
        } else null;
        var req = try self.inner.?.request(method, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            // Exact Zig 0.17.0 sendHead still omits privileged_headers while
            // emitting the standard authorization override. Keep this override;
            // redirects remain unhandled and destination hosts restricted.
            .headers = .{ .authorization = if (bearer) |value| .{ .override = value } else .omit, .accept_encoding = .{ .override = "identity" }, .content_type = if (form != null) .{ .override = if (terminal) "application/json" else "application/x-www-form-urlencoded" } else .omit },
        });
        defer req.deinit();
        if (form) |f| {
            req.transfer_encoding = .{ .content_length = f.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(f);
            try body.end();
            try req.connection.?.flush();
        } else try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) return error.RedirectRejected;
        if (response.head.content_encoding != .identity) return error.CompressionRejected;
        if (response.head.content_length) |len| if (len > out.len) return error.ResponseTooLarge;
        var retry_after: u32 = 0;
        var iter = response.head.iterateHeaders();
        while (iter.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after = @min(std.fmt.parseInt(u32, std.mem.trim(u8, header.value, " \t"), 10) catch 300, 300);
        };
        const reader = response.reader(&.{});
        const n = reader.readSliceShort(out) catch |err| {
            if (err == error.ReadFailed) {
                if (req.connection.?.getReadError()) |network_error| return network_error;
                if (response.bodyErr()) |body_err| return body_err;
            }
            return err;
        };
        if (n == out.len) {
            var extra: [1]u8 = undefined;
            if (try reader.readSliceShort(&extra) != 0) return error.ResponseTooLarge;
        }
        return .{ .status = status, .body = out[0..n], .retry_after = retry_after };
    }
};
fn validateDestination(uri: std.Uri, loopback: bool, terminal: bool) !void {
    if (loopback) {
        if (!std.mem.eql(u8, uri.scheme, "http")) return error.InsecureUrl;
        const host = uri.host orelse return error.InvalidHost;
        if (!std.mem.eql(u8, host.percent_encoded, "127.0.0.1")) return error.InvalidHost;
    } else {
        if (!std.mem.eql(u8, uri.scheme, "https")) return error.InsecureUrl;
        const host = uri.host orelse return error.InvalidHost;
        if (!std.mem.eql(u8, host.percent_encoded, "gmail.googleapis.com") and !std.mem.eql(u8, host.percent_encoded, "oauth2.googleapis.com") and !(terminal and std.mem.eql(u8, host.percent_encoded, "people.googleapis.com"))) return error.InvalidHost;
    }
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidUrl;
}

test "HTTP slab rejects excess requests and captures high-water" {
    var bytes: [128]u8 = undefined;
    var work: Workspace = .{ .fixed = .init(&bytes) };
    const a = work.allocator();
    const mem = try a.alloc(u8, 120);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 20));
    a.free(mem);
    try std.testing.expectEqual(@as(usize, 120), work.peak);
    try std.testing.expectEqual(@as(usize, 1), work.rejected);
}
test "terminal HTTPS policy adds only People and preserves bar and loopback hosts" {
    for ([_][]const u8{ "https://gmail.googleapis.com/gmail/v1/users/me/profile", "https://oauth2.googleapis.com/token" }) |url| {
        const uri = try std.Uri.parse(url);
        try validateDestination(uri, false, false);
        try validateDestination(uri, false, true);
    }
    const people = try std.Uri.parse("https://people.googleapis.com/v1/people/me/connections");
    try std.testing.expectError(error.InvalidHost, validateDestination(people, false, false));
    try validateDestination(people, false, true);
    for ([_][]const u8{ "https://gmail.googleapis.com.attacker.invalid/", "https://people.googleapis.com.attacker.invalid/", "https://www.googleapis.com/", "https://accounts.google.com/" }) |url| {
        const uri = try std.Uri.parse(url);
        try std.testing.expectError(error.InvalidHost, validateDestination(uri, false, false));
        try std.testing.expectError(error.InvalidHost, validateDestination(uri, false, true));
    }
    try std.testing.expectError(error.InsecureUrl, validateDestination(try std.Uri.parse("http://people.googleapis.com/"), false, true));
    var credentialed = people;
    credentialed.user = .{ .percent_encoded = "synthetic" };
    try std.testing.expectError(error.InvalidUrl, validateDestination(credentialed, false, true));
    try std.testing.expectError(error.InvalidUrl, validateDestination(try std.Uri.parse("https://@people.googleapis.com/"), false, true));
    try std.testing.expectError(error.InvalidUrl, validateDestination(try std.Uri.parse("https://people.googleapis.com/#fragment"), false, true));
    try validateDestination(try std.Uri.parse("http://127.0.0.1:1234/"), true, false);
    try std.testing.expectError(error.InvalidHost, validateDestination(try std.Uri.parse("http://localhost:1234/"), true, false));
}

pub const reservation_bytes = @sizeOf(@TypeOf(slab)) + @sizeOf(@TypeOf(reserved)) + 64;
