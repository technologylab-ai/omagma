const std = @import("std");
const b = @import("../bounded.zig");
const l = @import("../limits.zig");
const model = @import("../model.zig");
const http = @import("../http_client.zig");
const oauth = @import("../oauth.zig");
const keyring = @import("../keyring.zig");
const Config = @import("../config.zig").Config;
const open = @import("../open_target.zig");
const message_refusal = @import("../terminal/gmail_decode.zig").messageRefusal;
var response_storage: [l.response]u8 = undefined;
var json_storage: [l.json_workspace / 2]u8 align(16) = undefined;
var refresh_secret: [l.secret]u8 = undefined;
var access_secret: [l.secret]u8 = undefined;
var desktop: oauth.DesktopClient = undefined;

pub const Metrics = struct { http_peak: usize = 0, json_peak: usize = 0, rejected: usize = 0, retry_after: u32 = 0 };
const Session = struct {
    io: std.Io,
    client: *http.Client,
    access: []const u8,
    refresh_token: []const u8,
    retried: bool = false,
    fn get(self: *Session, url: []const u8, metrics: *Metrics) !http.Response {
        var response = try self.client.request(url, .GET, self.access, null, &response_storage);
        if (response.status == 401 and !self.retried) {
            self.retried = true;
            const token = try oauth.refresh(self.io, self.client, &desktop, self.refresh_token, &access_secret);
            self.access = token.access_token;
            response = try self.client.request(url, .GET, self.access, null, &response_storage);
        }
        metrics.retry_after = @max(metrics.retry_after, response.retry_after);
        return response;
    }
};
pub fn refresh(io: std.Io, config: *const Config, account: *const model.Account, snapshot: *model.Snapshot, metrics: *Metrics) !void {
    var client = try http.Client.init(io);
    defer client.deinit();
    defer {
        metrics.http_peak = client.peakBytes();
        metrics.rejected = client.rejectedAllocations();
    }
    defer std.crypto.secureZero(u8, &response_storage);
    defer std.crypto.secureZero(u8, &refresh_secret);
    defer std.crypto.secureZero(u8, &access_secret);
    if (config.client_file.len == 0) return error.OAuthClientRequired;
    try oauth.loadDesktop(io, config.client_file.slice(), &desktop);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&desktop));
    const refresh_token = try keyring.lookup(io, config.credentials(), account.address.slice(), desktop.client_id.slice(), &refresh_secret) orelse return error.NotConnected;
    const token = try oauth.refresh(io, &client, &desktop, refresh_token, &access_secret);
    var session: Session = .{ .io = io, .client = &client, .access = token.access_token, .refresh_token = refresh_token };
    var parse_alloc = std.heap.FixedBufferAllocator.init(&json_storage);
    // Verify identity on every job; credentials are never trusted solely by keyring label.
    const profile = try session.get("https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress", metrics);
    try status(profile.status);
    var parsed = try b.parse(parse_alloc.allocator(), profile.body);
    metrics.json_peak = @max(metrics.json_peak, parse_alloc.end_index);
    const address = try b.string(try b.field(parsed.value, "emailAddress"));
    if (!std.ascii.eqlIgnoreCase(address, account.address.slice())) return error.WrongAccount;
    parsed.deinit();
    parse_alloc.reset();
    const listed = try session.get("https://gmail.googleapis.com/gmail/v1/users/me/messages?labelIds=INBOX&maxResults=30&includeSpamTrash=false&fields=messages(id,threadId)", metrics);
    try status(listed.status);
    var ids: [l.max_rows]b.Text(l.max_id) = @splat(.{});
    var threads: [l.max_rows]b.Text(l.max_id) = @splat(.{});
    const count = try listIdentities(listed.body, &ids, &threads, &parse_alloc, metrics);
    snapshot.* = .{};
    for (ids[0..count], threads[0..count]) |*id, *thread| {
        var url: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&url);
        try w.writeAll("https://gmail.googleapis.com/gmail/v1/users/me/messages/");
        try open.encode(&w, id.slice());
        try w.writeAll("?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&fields=id,threadId,labelIds,internalDate,snippet,payload(headers)");
        const got = session.get(w.buffered(), metrics) catch |err| {
            if (!message_refusal(err)) return err;
            try partialMessage(.null, id.slice(), thread.slice(), &snapshot.messages[snapshot.count], err);
            snapshot.count += 1;
            snapshot.partial = true;
            continue;
        };
        if (got.status == 404) {
            snapshot.partial = true;
            continue;
        }
        try status(got.status);
        if (!try messageTolerant(got.body, id.slice(), thread.slice(), &snapshot.messages[snapshot.count], &parse_alloc, metrics)) {
            snapshot.partial = true;
            continue;
        }
        snapshot.partial = snapshot.partial or snapshot.messages[snapshot.count].partial;
        snapshot.count += 1;
    }
    const unread: ?http.Response = session.get("https://gmail.googleapis.com/gmail/v1/users/me/labels/INBOX?fields=messagesUnread", metrics) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Canceled or err == error.InvalidGrant or err == error.NotConnected or err == error.WrongAccount) return err;
        break :blk null;
    };
    // A count-only failure leaves the verified page usable with unknown count.
    if (unread) |count_response| {
        if (count_response.status == 401) return error.NotConnected;
        if (count_response.status == 403) return error.AccessDenied;
        if (count_response.status == 200) snapshot.unread = unreadCount(count_response.body, &parse_alloc, metrics) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            break :blk null;
        } else if (count_response.status == 429 or count_response.status >= 500) metrics.retry_after = @max(metrics.retry_after, 5);
    }
    snapshot.sort();
    snapshot.checked_at = std.Io.Timestamp.now(io, .real).toSeconds();
}
pub fn unreadCount(raw: []const u8, allocator: *std.heap.FixedBufferAllocator, metrics: *Metrics) !u32 {
    defer allocator.reset();
    const parsed = try parse(raw, allocator, metrics);
    defer parsed.deinit();
    const n = try b.integer(try b.field(parsed.value, "messagesUnread"));
    if (n < 0 or n > std.math.maxInt(u32)) return error.InvalidUnreadCount;
    return @intCast(n);
}
fn parse(raw: []const u8, allocator: *std.heap.FixedBufferAllocator, metrics: *Metrics) !std.json.Parsed(std.json.Value) {
    const parsed = b.parse(allocator.allocator(), raw) catch |err| {
        metrics.json_peak = @max(metrics.json_peak, allocator.end_index);
        if (err == error.OutOfMemory) metrics.rejected += 1;
        return err;
    };
    metrics.json_peak = @max(metrics.json_peak, allocator.end_index);
    return parsed;
}
fn status(s: u16) !void {
    return switch (s) {
        200 => {},
        401 => error.NotConnected,
        403 => error.AccessDenied,
        429 => error.RateLimited,
        500...599 => error.TransientFailure,
        else => error.ApiFailure,
    };
}
pub fn list(raw: []const u8, ids: *[l.max_rows]b.Text(l.max_id), allocator: *std.heap.FixedBufferAllocator, metrics: *Metrics) !usize {
    return listIdentities(raw, ids, null, allocator, metrics);
}
fn listIdentities(raw: []const u8, ids: *[l.max_rows]b.Text(l.max_id), threads: ?*[l.max_rows]b.Text(l.max_id), allocator: *std.heap.FixedBufferAllocator, metrics: *Metrics) !usize {
    defer allocator.reset();
    const parsed = try parse(raw, allocator, metrics);
    defer parsed.deinit();
    metrics.json_peak = @max(metrics.json_peak, allocator.end_index);
    const v = b.optional(parsed.value, "messages") orelse return 0;
    if (v != .array or v.array.items.len > l.max_rows) return error.InvalidPage;
    for (v.array.items, 0..) |entry, i| {
        const id = try b.string(try b.field(entry, "id"));
        try b.identifier(id);
        try ids[i].set(id);
        if (threads) |out| {
            const thread = try b.string(try b.field(entry, "threadId"));
            try b.identifier(thread);
            try out[i].set(thread);
        }
        for (ids[0..i]) |*previous| if (std.mem.eql(u8, previous.slice(), id)) return error.DuplicateMessage;
    }
    return v.array.items.len;
}
pub fn message(raw: []const u8, out: *model.Message, allocator: *std.heap.FixedBufferAllocator, metrics: *Metrics) !void {
    defer allocator.reset();
    const parsed = try parse(raw, allocator, metrics);
    defer parsed.deinit();
    metrics.json_peak = @max(metrics.json_peak, allocator.end_index);
    const root = parsed.value;
    try messageValue(root, out);
}
fn messageValue(root: std.json.Value, out: *model.Message) !void {
    out.* = .{};
    const id = try b.string(try b.field(root, "id"));
    try b.identifier(id);
    try out.id.set(id);
    const thread = try b.string(try b.field(root, "threadId"));
    try b.identifier(thread);
    try out.thread_id.set(thread);
    out.received_at = try b.integer(try b.field(root, "internalDate"));
    if (out.received_at < 0 or out.received_at > @import("../terminal/mime.zig").max_received_at_ms) return error.InvalidDate;
    // Missing snippet means projection feasibility has not been satisfied; don't silently hide it.
    out.snippet.display(try b.string(try b.field(root, "snippet")));
    const labels = try b.field(root, "labelIds");
    if (labels != .array or labels.array.items.len > 64) return error.InvalidLabels;
    var inbox = false;
    for (labels.array.items) |label| {
        const s = try b.string(label);
        if (s.len == 0 or s.len > 256) return error.InvalidLabels;
        if (std.mem.eql(u8, s, "UNREAD")) out.unread = true;
        if (std.mem.eql(u8, s, "INBOX")) inbox = true;
    }
    if (!inbox) return error.MessageLeftInbox;
    const payload = try b.field(root, "payload");
    if (b.optional(payload, "headers")) |headers| {
        if (headers != .array or headers.array.items.len > 64) return error.InvalidHeaders;
        for (headers.array.items) |h| {
            const name = try b.string(try b.field(h, "name"));
            const value = try b.string(try b.field(h, "value"));
            if (std.ascii.eqlIgnoreCase(name, "From")) b.header(l.sender, &out.sender, value) else if (std.ascii.eqlIgnoreCase(name, "Subject")) b.header(l.subject, &out.subject, value) else if (std.ascii.eqlIgnoreCase(name, "Message-ID")) {
                if (value.len > l.message_id) return error.InvalidMessageId;
                if (open.validMessageId(value)) try out.message_id.set(value);
            }
        }
    }
}

fn partialMessage(root: std.json.Value, id: []const u8, thread: []const u8, out: *model.Message, err: anyerror) !void {
    try b.identifier(id);
    try b.identifier(thread);
    out.* = .{};
    try out.id.set(id);
    try out.thread_id.set(thread);
    out.partial = true;
    try out.warning_code.set(@errorName(err));
    out.subject.display("Message unavailable");
    if (b.optional(root, "internalDate")) |field| {
        const received = b.integer(field) catch -1;
        if (received >= 0 and received <= @import("../terminal/mime.zig").max_received_at_ms) out.received_at = received;
    }
    if (b.optional(root, "snippet")) |field| if (field == .string) out.snippet.display(field.string);
    if (b.optional(root, "labelIds")) |labels| if (labels == .array and labels.array.items.len <= 64) {
        var unread = false;
        var verified = true;
        for (labels.array.items) |label| {
            if (label != .string or label.string.len > 256) {
                verified = false;
                break;
            }
            unread = unread or std.mem.eql(u8, label.string, "UNREAD");
        }
        if (verified) out.unread = unread;
    };
    if (b.optional(b.optional(root, "payload") orelse .null, "headers")) |headers| if (headers == .array) {
        for (headers.array.items[0..@min(headers.array.items.len, 64)]) |header| {
            const name = b.string(b.optional(header, "name") orelse .null) catch continue;
            const value = b.string(b.optional(header, "value") orelse .null) catch continue;
            if (std.ascii.eqlIgnoreCase(name, "From") and out.sender.len == 0) b.header(l.sender, &out.sender, value[0..@min(value.len, 8192)]);
            if (std.ascii.eqlIgnoreCase(name, "Subject")) b.header(l.subject, &out.subject, value[0..@min(value.len, 8192)]);
        }
    };
}

/// Isolate unsupported metadata while keeping the IDs independently verified
/// by the bounded list response. An explicit mismatched response stays fatal.
pub fn messageTolerant(raw: []const u8, id: []const u8, thread: []const u8, out: *model.Message, allocator: *std.heap.FixedBufferAllocator, metrics: *Metrics) !bool {
    defer allocator.reset();
    const parsed = parse(raw, allocator, metrics) catch |err| {
        // This allocator is the reset-per-message fixed JSON workspace, not
        // the application's retained heap or the HTTP transport allocator.
        const local = if (err == error.OutOfMemory) error.MessageBudgetExceeded else err;
        if (!message_refusal(local)) return local;
        try partialMessage(.null, id, thread, out, local);
        return true;
    };
    defer parsed.deinit();
    const got_id = b.string(b.optional(parsed.value, "id") orelse .null) catch return error.MessageIdentityMismatch;
    const got_thread = b.string(b.optional(parsed.value, "threadId") orelse .null) catch return error.MessageIdentityMismatch;
    if (!std.mem.eql(u8, got_id, id) or !std.mem.eql(u8, got_thread, thread)) return error.MessageIdentityMismatch;
    messageValue(parsed.value, out) catch |err| {
        if (err == error.MessageLeftInbox) return false;
        if (!message_refusal(err)) return err;
        try partialMessage(parsed.value, id, thread, out, err);
    };
    return true;
}
const DemoRow = struct { sender: []const u8, subject: []const u8, snippet: []const u8 };
// Read-only synthetic artwork/data lives in executable mappings; fixed
// normalization buffers and the per-account storage limits are unchanged.
const demo_rows: [3][8]DemoRow = .{
    .{
        .{ .sender = "Alex Morgan", .subject = "Coffee next Thursday?", .snippet = "How about the café near the station at ten?" },
        .{ .sender = "NATS Community", .subject = "This week in NATS", .snippet = "Release notes, community talks and a few useful links." },
        .{ .sender = "Google Workspace", .subject = "Your monthly account summary", .snippet = "A quick overview of recent activity and storage." },
        .{ .sender = "=?UTF-8?Q?Mira_Nov=C3=A1k?=", .subject = "A few photos from the weekend", .snippet = "I finally sorted the photos. This one made me laugh." },
        .{ .sender = "GitHub", .subject = "Review requested: simplify the parser", .snippet = "The new patch is ready for another look." },
        .{ .sender = "Rail Support", .subject = "Your train booking is confirmed", .snippet = "Departure at 09:42. Your reserved seat is included." },
        .{ .sender = "Lena Weiss", .subject = "Dinner plans for Friday", .snippet = "Let me know whether seven works for you." },
        .{ .sender = "Design Weekly", .subject = "Small interfaces, useful details", .snippet = "Notes on typography, density and getting out of the way." },
    },
    .{
        .{ .sender = "Sam Patel", .subject = "Project review: proposed next steps", .snippet = "Here are the decisions from our last call." },
        .{ .sender = "Acme Studio", .subject = "Draft proposal for the new website", .snippet = "The updated estimate includes both design and implementation." },
        .{ .sender = "Cloud Billing", .subject = "Your September usage report", .snippet = "The monthly breakdown is ready to review." },
        .{ .sender = "Priya Shah", .subject = "Can we move the planning call?", .snippet = "Tuesday afternoon would work better for the team." },
        .{ .sender = "Dev Tools", .subject = "Build completed successfully", .snippet = "All checks passed on the latest commit." },
        .{ .sender = "Project Atlas", .subject = "Milestone two: delivery notes", .snippet = "The documents and final changes are ready." },
        .{ .sender = "Jordan Lee", .subject = "Feedback on the prototype", .snippet = "The smaller layout feels much easier to use." },
        .{ .sender = "Team Updates", .subject = "Agenda for next week", .snippet = "Three topics to discuss at the team meeting." },
    },
    .{
        .{ .sender = "NATS Engineering", .subject = "Transport design review", .snippet = "A few comments on cancellation and connection limits." },
        .{ .sender = "Release Bot", .subject = "New release candidate available", .snippet = "The artifacts and changelog are ready for testing." },
        .{ .sender = "Customer Success", .subject = "Customer call summary", .snippet = "Two follow-up items from today's discussion." },
        .{ .sender = "Optional account Events", .subject = "Developer session next week", .snippet = "Join the technical session and bring your questions." },
        .{ .sender = "Incident Review", .subject = "Postmortem draft for review", .snippet = "The timeline and action items have been updated." },
        .{ .sender = "Taylor Chen", .subject = "A question about the API", .snippet = "Could you check the example when you have a moment?" },
        .{ .sender = "Community Digest", .subject = "Notes from the maintainers", .snippet = "Recent updates and upcoming community events." },
        .{ .sender = "Support Team", .subject = "Support ticket update", .snippet = "The requested details have arrived from the customer." },
    },
};

pub fn fixture(io: std.Io, account: *const model.Account, snapshot: *model.Snapshot, metrics: *Metrics, empty: bool, fixture_rows: usize) !void {
    snapshot.* = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&json_storage);
    var ids: [l.max_rows]b.Text(l.max_id) = @splat(.{});
    const group: usize = if (std.mem.eql(u8, account.profile.slice(), "Profile 3")) 0 else if (std.mem.eql(u8, account.profile.slice(), "Profile 1")) 1 else 2;
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const count = if (empty) 0 else fixture_rows;
    if (count > l.max_rows) return error.InvalidPage;
    for (ids[0..count], 0..) |*id, i| {
        var text: [128]u8 = undefined;
        try id.set(try std.fmt.bufPrint(&text, "shared{d}", .{i + 1}));
    }
    for (ids[0..count], 0..) |*id, i| {
        const row = demo_rows[group][i % demo_rows[group].len];
        var buffer: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try w.writeAll("{\"id\":");
        try b.jsonString(&w, id.slice());
        try w.writeAll(",\"threadId\":\"sharedthread\",\"internalDate\":");
        try w.print("\"{d}\",\"snippet\":", .{now_ms - @as(i64, @intCast(i)) * 600000});
        try b.jsonString(&w, row.snippet);
        try w.writeAll(if (i % 2 == 0) ",\"labelIds\":[\"INBOX\",\"UNREAD\"]," else ",\"labelIds\":[\"INBOX\"],");
        try w.writeAll("\"payload\":{\"headers\":[{\"name\":\"fRoM\",\"value\":");
        try b.jsonString(&w, row.sender);
        try w.writeAll("},{\"name\":\"Subject\",\"value\":");
        try b.jsonString(&w, row.subject);
        try w.writeAll("},{\"name\":\"Message-ID\",\"value\":\"<fixture+message@example.test>\"}]}}");
        try message(w.buffered(), &snapshot.messages[i], &allocator, metrics);
    }
    snapshot.count = count;
    snapshot.unread = if (empty) 0 else if (std.mem.eql(u8, account.profile.slice(), "Profile 3")) 7 else 11;
    snapshot.checked_at = std.Io.Timestamp.now(io, .real).toSeconds();
    snapshot.sort();
}

test "partial provider input and oversized identities never become valid snapshots" {
    var storage: [64 * 1024]u8 = undefined;
    var f = std.heap.FixedBufferAllocator.init(&storage);
    var metrics: Metrics = .{};
    var m: model.Message = .{};
    try std.testing.expectError(error.MissingField, message("{\"id\":\"a\",\"threadId\":\"b\",\"internalDate\":\"1\",\"labelIds\":[\"INBOX\"]}", &m, &f, &metrics));
    var ids: [l.max_rows]b.Text(l.max_id) = @splat(.{});
    try std.testing.expectError(error.DuplicateMessage, list("{\"messages\":[{\"id\":\"a\"},{\"id\":\"a\"}]}", &ids, &f, &metrics));
}

test "bar message isolation keeps good partial good rows and rejects wrong identity" {
    var scratch: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    var metrics: Metrics = .{};
    var snapshot: model.Snapshot = .{};
    const raws = [_][]const u8{
        "{\"id\":\"good1\",\"threadId\":\"thread\",\"internalDate\":\"3\",\"labelIds\":[\"INBOX\"],\"snippet\":\"first\",\"payload\":{\"headers\":[]}}",
        "{\"id\":\"odd\",\"threadId\":\"thread\",\"internalDate\":\"2\",\"labelIds\":7,\"snippet\":\"retained\",\"payload\":{\"headers\":[{\"name\":\"Subject\",\"value\":\"Unusual message\"}]}}",
        "{\"id\":\"good2\",\"threadId\":\"thread\",\"internalDate\":\"1\",\"labelIds\":[\"INBOX\"],\"snippet\":\"last\",\"payload\":{\"headers\":[]}}",
    };
    for (raws, [_][]const u8{ "good1", "odd", "good2" }) |raw, id| {
        try std.testing.expect(try messageTolerant(raw, id, "thread", &snapshot.messages[snapshot.count], &allocator, &metrics));
        snapshot.partial = snapshot.partial or snapshot.messages[snapshot.count].partial;
        snapshot.count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), snapshot.count);
    try std.testing.expect(snapshot.partial);
    try std.testing.expectEqualStrings("InvalidLabels", snapshot.messages[1].warning_code.slice());
    try std.testing.expectEqualStrings("Unusual message", snapshot.messages[1].subject.slice());
    try std.testing.expectError(error.MessageIdentityMismatch, messageTolerant(raws[0], "odd", "thread", &snapshot.messages[0], &allocator, &metrics));
    try std.testing.expect(try messageTolerant("{broken", "odd", "thread", &snapshot.messages[1], &allocator, &metrics));
    try std.testing.expectEqualStrings("odd", snapshot.messages[1].id.slice());
    try std.testing.expect(snapshot.messages[1].partial);
    var tiny: [1]u8 = undefined;
    var exhausted = std.heap.FixedBufferAllocator.init(&tiny);
    try std.testing.expect(try messageTolerant(raws[0], "good1", "thread", &snapshot.messages[0], &exhausted, &metrics));
    try std.testing.expectEqualStrings("good1", snapshot.messages[0].id.slice());
    try std.testing.expectEqualStrings("MessageBudgetExceeded", snapshot.messages[0].warning_code.slice());
    try std.testing.expect(snapshot.messages[0].partial);
    try std.testing.expectEqual(@as(usize, 0), exhausted.end_index);
    // Transport/global allocation errors still fail refresh before parsing.
    try std.testing.expect(!message_refusal(error.OutOfMemory));
    try std.testing.expect(try messageTolerant(raws[2], "good2", "thread", &snapshot.messages[2], &allocator, &metrics));
    try std.testing.expect(!snapshot.messages[2].partial);
}

test "bar message isolation keeps invalid dates inside the shared reader and UI bound" {
    var scratch: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    var metrics: Metrics = .{};
    var snapshot: model.Snapshot = .{};
    const raws = [_][]const u8{
        "{\"id\":\"good1\",\"threadId\":\"thread\",\"internalDate\":\"253402300799999\",\"labelIds\":[\"INBOX\"],\"snippet\":\"boundary\",\"payload\":{\"headers\":[]}}",
        "{\"id\":\"odd\",\"threadId\":\"thread\",\"internalDate\":\"8900000000000000\",\"labelIds\":[\"INBOX\"],\"snippet\":\"bad date\",\"payload\":{\"headers\":[]}}",
        "{\"id\":\"good2\",\"threadId\":\"thread\",\"internalDate\":\"1\",\"labelIds\":[\"INBOX\"],\"snippet\":\"last\",\"payload\":{\"headers\":[]}}",
    };
    for (raws, [_][]const u8{ "good1", "odd", "good2" }) |raw, id| {
        try std.testing.expect(try messageTolerant(raw, id, "thread", &snapshot.messages[snapshot.count], &allocator, &metrics));
        snapshot.partial = snapshot.partial or snapshot.messages[snapshot.count].partial;
        snapshot.count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), snapshot.count);
    try std.testing.expect(snapshot.partial);
    try std.testing.expectEqual(@import("../terminal/mime.zig").max_received_at_ms, snapshot.messages[0].received_at);
    try std.testing.expectEqual(@as(i64, 0), snapshot.messages[1].received_at);
    try std.testing.expectEqualStrings("InvalidDate", snapshot.messages[1].warning_code.slice());
    try std.testing.expect(!snapshot.messages[2].partial);
}

pub const reservation_bytes = @sizeOf(@TypeOf(response_storage)) + @sizeOf(@TypeOf(json_storage)) + @sizeOf(@TypeOf(refresh_secret)) + @sizeOf(@TypeOf(access_secret)) + @sizeOf(oauth.DesktopClient) + 128;

test "whole-Inbox unread counts validate independently of page normalization" {
    var storage: [16 * 1024]u8 = undefined;
    var f = std.heap.FixedBufferAllocator.init(&storage);
    var metrics: Metrics = .{};
    try std.testing.expectEqual(@as(u32, 900), try unreadCount("{\"messagesUnread\":900}", &f, &metrics));
    try std.testing.expectError(error.InvalidUnreadCount, unreadCount("{\"messagesUnread\":-1}", &f, &metrics));
    try std.testing.expectError(error.MissingField, unreadCount("{}", &f, &metrics));
}
