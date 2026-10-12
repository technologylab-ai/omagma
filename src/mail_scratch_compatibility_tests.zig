//! Synthetic Gmail response admission at the combined reader/metadata bounds.
//! The input oracle and retained DTO buffers are separate from decode scratch.
const std = @import("std");
const gmail = @import("terminal/gmail.zig");
const decode = @import("terminal/gmail_decode.zig");
const policy = @import("terminal/mail_limits.zig");
const types = @import("terminal/types.zig");
const scratch = @import("mail_scratch.zig");

const Header = struct { name: []const u8, value: []const u8 };
const Part = struct {
    mimeType: []const u8,
    headers: [1]Header,
    body: struct { size: usize, data: []const u8 },
};

fn repeated(a: std.mem.Allocator, len: usize, byte: u8) ![]u8 {
    const bytes = try a.alloc(u8, len);
    @memset(bytes, byte);
    return bytes;
}

fn part(a: std.mem.Allocator, kind: []const u8, bytes: []const u8) !Part {
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    return .{
        .mimeType = kind,
        .headers = .{.{ .name = "Content-Type", .value = try std.fmt.allocPrint(a, "{s}; charset=utf-8", .{kind}) }},
        .body = .{ .size = bytes.len, .data = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes) },
    };
}

test "near-limit Gmail scratch: two 1 MiB alternatives and maximum metadata fit both MIME orders" {
    var source = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source.deinit();
    const a = source.allocator();
    const plain = try repeated(a, 1024 * 1024, 'P');
    const html = try repeated(a, 1024 * 1024, 'H');
    @memcpy(html[0..3], "<p>");
    @memcpy(html[html.len - 4 ..], "</p>");
    const subject = try repeated(a, policy.subject_bytes, 'S');
    const name = try a.alloc(u8, policy.display_name_bytes);
    for (0..name.len / 2) |index| @memcpy(name[index * 2 ..][0..2], "é");
    var headers: std.ArrayList(Header) = .empty;
    for ([_]Header{
        .{ .name = "Subject", .value = subject },
        .{ .name = "From", .value = try std.fmt.allocPrint(a, "{s} <sender@example.test>", .{name}) },
        .{ .name = "To", .value = try std.fmt.allocPrint(a, "{s} <self@example.test>", .{name}) },
        .{ .name = "Cc", .value = try std.fmt.allocPrint(a, "{s} <copy@example.test>", .{name}) },
        .{ .name = "Reply-To", .value = try std.fmt.allocPrint(a, "{s} <reply@example.test>", .{name}) },
        .{ .name = "Message-ID", .value = "<scratch-boundary@example.test>" },
    }) |header| try headers.append(a, header);
    const padding_start = headers.items.len;
    while (headers.items.len < policy.header_count) try headers.append(a, .{
        .name = try std.fmt.allocPrint(a, "X-Scratch-{d}", .{headers.items.len}),
        .value = "",
    });
    var header_bytes: usize = 0;
    for (headers.items) |header| header_bytes += header.name.len + header.value.len;
    var remaining = policy.headers_bytes - header_bytes;
    for (headers.items[padding_start..], padding_start..) |*header, index| {
        const len = remaining / (headers.items.len - index);
        header.value = try repeated(a, len, 'X');
        remaining -= len;
        header_bytes += len;
    }
    try std.testing.expectEqual(policy.headers_bytes, header_bytes);
    try std.testing.expectEqual(policy.header_count, headers.items.len);
    const plain_part = try part(a, "text/plain", plain);
    const html_part = try part(a, "text/html", html);
    const retained_storage = try a.alloc(u8, 8 * 1024 * 1024);
    var retained = std.heap.FixedBufferAllocator.init(retained_storage);
    var messages: [2]types.Message = undefined;
    for (&messages, 0..) |*message, order| {
        const wire = try std.json.Stringify.valueAlloc(a, .{
            .id = "scratch-boundary",
            .threadId = "scratch-thread",
            .internalDate = "1791651960000",
            .labelIds = [_][]const u8{ "INBOX", "UNREAD" },
            .snippet = "Synthetic maximum metadata and alternative bodies",
            .payload = .{
                .mimeType = "multipart/alternative",
                .headers = headers.items,
                .parts = if (order == 0) [_]Part{ plain_part, html_part } else [_]Part{ html_part, plain_part },
            },
        }, .{});
        try std.testing.expect(wire.len > 2_900_000 and wire.len <= types.Limits.request_bytes);
        var transport_scope = std.heap.ArenaAllocator.init(a);
        defer transport_scope.deinit();
        const response = try gmail.decodeResponse(transport_scope.allocator(), .GET, "https://gmail.googleapis.com/gmail/v1/users/me/messages/scratch-boundary", 200, wire);
        const before = scratch.snapshot();
        message.* = try decode.normalize(response, retained.allocator(), null);
        const after = scratch.snapshot();
        try std.testing.expectEqual(before.rejectedAllocations, after.rejectedAllocations);
        try std.testing.expectEqual(before.leases + 1, after.leases);
        try std.testing.expectEqual(@as(usize, 0), after.usedBytes);
        try std.testing.expect(!after.active);
        try std.testing.expectEqualStrings("", message.decodeWarning);
        try std.testing.expectEqualStrings("", message.bodyCacheError);
        try std.testing.expect(!message.metadataPartial and message.labelsVerified);
    }
    // A later decode has wiped and reused scratch; both retained copies must
    // still have every body byte and all reply/display metadata intact.
    for (messages) |message| {
        try std.testing.expectEqualSlices(u8, plain, message.bodyText);
        try std.testing.expectEqualSlices(u8, html, message.bodyHtml.?);
        try std.testing.expectEqualStrings(subject, message.subject);
        try std.testing.expectEqualStrings(name, message.from.name);
        try std.testing.expectEqualStrings(name, message.to[0].name);
        try std.testing.expectEqualStrings(name, message.cc[0].name);
        try std.testing.expectEqualStrings(name, message.replyTo[0].name);
        try std.testing.expectEqualStrings("sender@example.test", message.from.address);
        try std.testing.expectEqualStrings("reply@example.test", message.replyTo[0].address);
    }
}
