const std = @import("std");
const limits = @import("limits.zig");
const platform = @import("platform.zig");
pub const Source = @import("byte_stream.zig").Source;
pub const terminal_stream_bytes = 36 * limits.MiB;
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

pub const Response = struct { status: u16, body: []const u8, retry_after: u32 = 0, bytes: usize = 0 };
/// Fixed, public destinations. This policy never accepts OAuth credentials or
/// caller-controlled URLs and never follows redirects.
pub const MetadataEndpoint = enum {
    latest_release,
    homebrew_formula,
    pub fn url(self: MetadataEndpoint) []const u8 {
        return switch (self) {
            .latest_release => "https://api.github.com/repos/technologylab-ai/omagma/releases/latest",
            .homebrew_formula => "https://raw.githubusercontent.com/renerocksai/homebrew-tap/main/Formula/omagma.rb",
        };
    }
};
pub const metadata_bytes = 64 * 1024;
const Upload = struct { source: Source, size: usize, content_type: []const u8 };
const Download = struct { writer: *std.Io.Writer, limit: usize };
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
    pub fn requestPublicMetadata(self: *Client, endpoint: MetadataEndpoint, out: []u8) !Response {
        return platform.deadline(self.io, platform.seconds(5), requestPublicMetadataInner, .{ self, endpoint, out });
    }
    fn requestPublicMetadataInner(self: *Client, endpoint: MetadataEndpoint, out: []u8) anyerror!Response {
        if (out.len > metadata_bytes) return error.ResponseBufferTooLarge;
        const uri = try std.Uri.parse(endpoint.url());
        if (self.inner == null) self.inner = .{ .allocator = self.workspace.allocator(), .io = self.io, .read_buffer_size = limits.headers, .connection_pool = .{ .free_size = 0 } };
        var req = try self.inner.?.request(.GET, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .authorization = .omit, .user_agent = .{ .override = "omagma-update-check" }, .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) return error.RedirectRejected;
        if (response.head.content_encoding != .identity) return error.CompressionRejected;
        if (response.head.content_length) |length| if (length > out.len) return error.ResponseTooLarge;
        var retry_after: u32 = 0;
        var iter = response.head.iterateHeaders();
        while (iter.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after = @min(std.fmt.parseInt(u32, std.mem.trim(u8, header.value, " \t"), 10) catch 86400, 604800);
        };
        const reader = response.reader(&.{});
        const count = reader.readSliceShort(out) catch |err| {
            if (err == error.ReadFailed) {
                if (req.connection.?.getReadError()) |network_error| return network_error;
                if (response.bodyErr()) |body_error| return body_error;
            }
            return err;
        };
        if (count == out.len) {
            var extra: [1]u8 = undefined;
            if (try reader.readSliceShort(&extra) != 0) return error.ResponseTooLarge;
        }
        return .{ .status = status, .body = out[0..count], .retry_after = retry_after };
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
    /// Terminal media only. Source is consumed once, with exact Content-Length
    /// and an EOF check. Any explicit authorized retry needs a fresh source.
    /// Response JSON retains the ordinary terminal response-buffer ceiling.
    pub fn requestTerminalFile(self: *Client, url: []const u8, method: std.http.Method, token: ?[]const u8, content_type: []const u8, source: Source, content_length: usize, out: []u8) !Response {
        if (method != .POST and method != .PUT and method != .PATCH) return error.InvalidStreamMethod;
        return platform.deadline(self.io, try self.streamDuration(), requestStreamingInner, .{ self, url, method, token, @as(?Upload, .{ .source = source, .size = content_length, .content_type = content_type }), @as(?Download, null), out, false });
    }
    /// Only 2xx bytes enter the destination writer. Errors remain in the small
    /// caller-provided buffer, so a 401 retry never appends provider error JSON
    /// to an attachment. Successful response.body is empty; bytes is its size.
    pub fn requestTerminalDownload(self: *Client, url: []const u8, token: ?[]const u8, writer: *std.Io.Writer, max_response_bytes: usize, error_out: []u8) !Response {
        return platform.deadline(self.io, try self.streamDuration(), requestStreamingInner, .{ self, url, .GET, token, @as(?Upload, null), @as(?Download, .{ .writer = writer, .limit = max_response_bytes }), error_out, false });
    }
    pub fn requestLoopbackFileProbe(self: *Client, url: []const u8, content_type: []const u8, source: Source, content_length: usize, out: []u8) !Response {
        return platform.deadline(self.io, try self.streamDuration(), requestStreamingInner, .{ self, url, .POST, @as(?[]const u8, "synthetic-omagma-bearer"), @as(?Upload, .{ .source = source, .size = content_length, .content_type = content_type }), @as(?Download, null), out, true });
    }
    pub fn requestLoopbackDownloadProbe(self: *Client, url: []const u8, writer: *std.Io.Writer, max_response_bytes: usize, error_out: []u8) !Response {
        return platform.deadline(self.io, try self.streamDuration(), requestStreamingInner, .{ self, url, .GET, @as(?[]const u8, "synthetic-omagma-bearer"), @as(?Upload, null), @as(?Download, .{ .writer = writer, .limit = max_response_bytes }), error_out, true });
    }
    fn streamDuration(self: *Client) !std.Io.Clock.Duration {
        const remaining = self.job_deadline.durationFromNow(self.io);
        if (remaining.raw.toNanoseconds() <= 0) return error.Timeout;
        // Large media can use the remaining bounded job budget. The bar and
        // ordinary terminal JSON requests keep their existing ten-second cap.
        return .{ .clock = .awake, .raw = .fromNanoseconds(remaining.raw.toNanoseconds()) };
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
    /// Label transport regression only: fixed synthetic content/credential,
    /// POST/PATCH/DELETE, and the same terminal policy restricted to loopback.
    pub fn requestLoopbackLabelProbe(self: *Client, url: []const u8, method: std.http.Method, out: []u8) !Response {
        if (method != .POST and method != .PATCH and method != .DELETE) return error.InvalidProbeMethod;
        const remaining = self.job_deadline.durationFromNow(self.io);
        if (remaining.raw.toNanoseconds() <= 0) return error.Timeout;
        const duration: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromNanoseconds(@min(remaining.raw.toNanoseconds(), @as(i96, limits.request_seconds) * std.time.ns_per_s)) };
        const body: ?[]const u8 = if (method == .DELETE) null else "{\"name\":\"Fixture 🌋\"}";
        return try platform.deadline(self.io, duration, requestInner, .{ self, url, method, @as(?[]const u8, "synthetic-omagma-bearer"), body, out, true, true });
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
    fn requestStreamingInner(self: *Client, url: []const u8, method: std.http.Method, token: ?[]const u8, upload: ?Upload, download: ?Download, out: []u8, loopback: bool) anyerror!Response {
        if (out.len > 3 * limits.MiB) return error.ResponseBufferTooLarge;
        if (url.len > 4096) return error.UrlTooLarge;
        const uri = try std.Uri.parse(url);
        try validateDestination(uri, loopback, true);
        if (!loopback and !std.mem.eql(u8, uri.host.?.percent_encoded, "gmail.googleapis.com")) return error.InvalidHost;
        if (upload) |body| {
            if (body.size > terminal_stream_bytes) return error.FormTooLarge;
            if (body.content_type.len == 0 or body.content_type.len > 512) return error.InvalidContentType;
            for (body.content_type) |byte| if (byte < 32 or byte >= 127) return error.InvalidContentType;
        }
        if (download) |body| if (body.limit > terminal_stream_bytes) return error.ResponseBufferTooLarge;
        if (self.inner == null) self.inner = .{ .allocator = self.workspace.allocator(), .io = self.io, .read_buffer_size = limits.headers, .connection_pool = .{ .free_size = 0 } };
        var authorization: [limits.secret + 7]u8 = undefined;
        defer std.crypto.secureZero(u8, &authorization);
        const bearer: ?[]const u8 = if (token) |secret| blk: {
            if (secret.len == 0 or secret.len > limits.secret) return error.InvalidToken;
            for (secret) |byte| if (byte <= 32 or byte >= 127) return error.InvalidToken;
            break :blk try std.fmt.bufPrint(&authorization, "Bearer {s}", .{secret});
        } else null;
        var request_value = try self.inner.?.request(method, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .authorization = if (bearer) |value| .{ .override = value } else .omit, .accept_encoding = .{ .override = "identity" }, .content_type = if (upload) |body| .{ .override = body.content_type } else .omit },
        });
        defer request_value.deinit();
        if (upload) |body| {
            request_value.transfer_encoding = .{ .content_length = body.size };
            var send_buffer: [16 * 1024]u8 = undefined;
            var output = try request_value.sendBodyUnflushed(&send_buffer);
            var buffer: [32 * 1024]u8 = undefined;
            var sent: usize = 0;
            while (true) {
                try self.io.checkCancel();
                const count = try body.source.read(&buffer);
                if (count == 0) break;
                if (count > body.size -| sent) return error.BodySizeMismatch;
                try output.writer.writeAll(buffer[0..count]);
                sent += count;
            }
            if (sent != body.size) return error.BodySizeMismatch;
            try output.end();
            try request_value.connection.?.flush();
        } else try request_value.sendBodiless();
        var response = try request_value.receiveHead(&.{});
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) return error.RedirectRejected;
        if (response.head.content_encoding != .identity) return error.CompressionRejected;
        const destination: ?Download = if (status >= 200 and status < 300) download else null;
        const limit = if (destination) |body| body.limit else out.len;
        if (response.head.content_length) |size| if (size > limit) return error.ResponseTooLarge;
        var retry_after: u32 = 0;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after = @min(std.fmt.parseInt(u32, std.mem.trim(u8, header.value, " \t"), 10) catch 300, 300);
        };
        const reader = response.reader(&.{});
        var buffer: [32 * 1024]u8 = undefined;
        var received: usize = 0;
        while (true) {
            try self.io.checkCancel();
            const count = reader.readSliceShort(&buffer) catch |err| {
                if (err == error.ReadFailed) {
                    if (request_value.connection.?.getReadError()) |network_error| return network_error;
                    if (response.bodyErr()) |body_error| return body_error;
                }
                return err;
            };
            if (count == 0) break;
            if (count > limit -| received) return error.ResponseTooLarge;
            if (destination) |body| try body.writer.writeAll(buffer[0..count]) else @memcpy(out[received..][0..count], buffer[0..count]);
            received += count;
        }
        return .{ .status = status, .body = if (destination != null) "" else out[0..received], .retry_after = retry_after, .bytes = received };
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

test "updates: public metadata endpoints remain outside Google credential policy" {
    // The public path has a separate, fixed endpoint enum; adding discovery
    // never makes an OAuth-bearing Google request able to reach these hosts.
    for ([_]MetadataEndpoint{ .latest_release, .homebrew_formula }) |endpoint| {
        const uri = try std.Uri.parse(endpoint.url());
        try std.testing.expectError(error.InvalidHost, validateDestination(uri, false, false));
        try std.testing.expectError(error.InvalidHost, validateDestination(uri, false, true));
        try std.testing.expectEqualStrings("https", uri.scheme);
        try std.testing.expect(uri.user == null and uri.password == null and uri.fragment == null);
    }
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
