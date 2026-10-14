//! Bounded account-scoped evidence for descriptors already shown by a FULL
//! read. Opaque provider tokens may rotate independently of an open picker.
const std = @import("std");
const t = @import("types.zig");
const mime = @import("mime.zig");
const b = @import("../bounded.zig");

pub const max_count = 256;
pub const max_bytes = 256 * 1024;
pub const Receipt = struct { messageId: []const u8, threadId: []const u8, attachment: t.Attachment };

pub fn same(left: t.Attachment, right: t.Attachment) bool {
    if (left.size != right.size) return false;
    inline for (.{ "id", "filename", "mimeType" }) |field| if (!std.mem.eql(u8, @field(left, field), @field(right, field))) return false;
    inline for (.{ "contentId", "disposition", "contentLocation" }) |field| {
        const x = @field(left, field);
        const y = @field(right, field);
        if ((x == null) != (y == null)) return false;
        if (x) |value| if (!std.mem.eql(u8, value, y.?)) return false;
    }
    return true;
}
pub fn validate(receipts: []const Receipt) !void {
    if (receipts.len > max_count or @import("gmail_decode.zig").serializedBytes(receipts) > max_bytes) return error.CacheLimitExceeded;
    for (receipts) |receipt| {
        try b.identifier(receipt.messageId);
        try b.identifier(receipt.threadId);
        const attachment = receipt.attachment;
        if (attachment.id.len == 0 or attachment.id.len > 1024 or attachment.size > t.Limits.incoming_attachment_bytes or attachment.data.len != 0 or attachment.blobId != null) return error.CacheLimitExceeded;
        try mime.validateAttachment(attachment.filename, attachment.mimeType);
        inline for (.{ "contentId", "disposition", "contentLocation" }) |field| if (@field(attachment, field)) |value| if (value.len > 4096) return error.CacheLimitExceeded;
    }
}
pub fn find(receipts: []const Receipt, message_id: []const u8, attachment_id: []const u8) !?Receipt {
    var result: ?Receipt = null;
    for (receipts) |receipt| if (std.mem.eql(u8, receipt.messageId, message_id) and std.mem.eql(u8, receipt.attachment.id, attachment_id)) {
        if (result) |previous| if (!std.mem.eql(u8, previous.threadId, receipt.threadId) or !same(previous.attachment, receipt.attachment)) return error.AmbiguousAttachment;
        result = receipt;
    };
    return result;
}
/// New descriptors lead the bounded table. A huge/refused/partial result does
/// not make reading mail fail and never lends authority to a caller's token.
pub fn remember(a: std.mem.Allocator, previous: []const Receipt, message: t.Message) ![]const Receipt {
    if (message.metadataPartial or message.bodyCacheError.len != 0 or message.attachments.len == 0) return previous;
    var selected: [max_count]Receipt = undefined;
    var count: usize = 0;
    var bytes: usize = 2;
    for (message.attachments) |attachment| {
        var metadata = attachment;
        metadata.data = "";
        metadata.blobId = null;
        const receipt: Receipt = .{ .messageId = message.id, .threadId = message.threadId, .attachment = metadata };
        validate(&.{receipt}) catch continue;
        const size = @import("gmail_decode.zig").serializedBytes(receipt) + 1;
        if (count == max_count or bytes + size > max_bytes) break;
        selected[count] = receipt;
        count += 1;
        bytes += size;
    }
    const added = count;
    if (added == 0) return previous;
    for (previous) |receipt| {
        var duplicate = false;
        for (selected[0..count]) |newer| if (std.mem.eql(u8, newer.messageId, receipt.messageId) and std.mem.eql(u8, newer.threadId, receipt.threadId) and same(newer.attachment, receipt.attachment)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        const size = @import("gmail_decode.zig").serializedBytes(receipt) + 1;
        if (count == max_count or bytes + size > max_bytes) break;
        selected[count] = receipt;
        count += 1;
        bytes += size;
    }
    const out = try a.dupe(Receipt, selected[0..count]);
    // FULL response arenas may be released before the next index checkpoint.
    for (out[0..added]) |*receipt| {
        receipt.messageId = try a.dupe(u8, receipt.messageId);
        receipt.threadId = try a.dupe(u8, receipt.threadId);
        inline for (.{ "id", "filename", "mimeType" }) |field| @field(receipt.attachment, field) = try a.dupe(u8, @field(receipt.attachment, field));
        inline for (.{ "contentId", "disposition", "contentLocation" }) |field| if (@field(receipt.attachment, field)) |value| {
            @field(receipt.attachment, field) = try a.dupe(u8, value);
        };
    }
    return out;
}

test "attachment identity: receipts retain observed token versions and refuse contradictory or foreign bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var message: t.Message = .{ .id = "source", .threadId = "thread", .attachments = &.{.{ .id = "B", .filename = "report.pdf", .mimeType = "application/pdf", .size = 3, .data = "YWJj" }} };
    const first = try remember(a, &.{}, message);
    message.attachments = &.{.{ .id = "C", .filename = "report.pdf", .mimeType = "application/pdf", .size = 3 }};
    const next = try remember(a, first, message);
    try validate(next);
    try std.testing.expectEqualStrings("B", (try find(next, "source", "B")).?.attachment.id);
    try std.testing.expect((try find(next, "neighbor", "B")) == null);
    try std.testing.expect((try find(next, "source", "never-observed")) == null);
    for (next) |receipt| try std.testing.expect(receipt.attachment.data.len == 0 and receipt.attachment.blobId == null);
    message.attachments = &.{.{ .id = "B", .filename = "different.pdf", .mimeType = "application/pdf", .size = 3 }};
    try std.testing.expectError(error.AmbiguousAttachment, find(try remember(a, next, message), "source", "B"));
}

test "attachment identity: receipt count and byte limits evict oldest evidence without refusing mail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var receipts: []const Receipt = &.{};
    for (0..max_count + 1) |index| {
        const id = try std.fmt.allocPrint(a, "observed-{d}", .{index});
        receipts = try remember(a, receipts, .{ .id = "source", .threadId = "thread", .attachments = &.{.{ .id = id, .filename = "report.pdf", .size = 4 }} });
    }
    try validate(receipts);
    try std.testing.expectEqual(@as(usize, max_count), receipts.len);
    try std.testing.expect((try find(receipts, "source", "observed-0")) == null);
    try std.testing.expect((try find(receipts, "source", "observed-1")) != null);
    const enormous = try a.alloc(u8, max_bytes);
    @memset(enormous, 'x');
    const unchanged = try remember(a, receipts, .{ .id = "source", .threadId = "thread", .attachments = &.{.{ .id = enormous, .filename = "report.pdf", .size = 4 }} });
    try std.testing.expectEqual(receipts.ptr, unchanged.ptr);
}
