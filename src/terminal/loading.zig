//! One bounded, request-owned preview window. Published headers and body
//! excerpts are immutable until the worker has joined and the mailbox resets.
const std = @import("std");
const types = @import("types.zig");
pub const window = 32;
pub fn Bytes(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8 = @splat(0),
        len: usize = 0,
        fn set(self: *@This(), input: []const u8) void {
            var length = @min(input.len, capacity);
            while (length > 0 and !std.unicode.utf8ValidateSlice(input[0..length])) : (length -= 1) {}
            @memcpy(self.buffer[0..length], input[0..length]);
            self.len = length;
        }
        pub fn value(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}
pub const Row = struct {
    id: Bytes(128) = .{},
    from_name: Bytes(256) = .{},
    from_address: Bytes(254) = .{},
    subject: Bytes(1024) = .{},
    snippet: Bytes(1024) = .{},
    received_at: i64 = 0,
    unread: bool = false,
};
pub const Slot = struct {
    row: Row = .{},
    available: std.atomic.Value(bool) = .init(false),
    body_excerpt: Bytes(512) = .{},
    body_state: std.atomic.Value(u8) = .init(0), //0pending,1ready,2refused
    pub fn metadata(self: *const Slot) ?*const Row {
        return if (self.available.load(.acquire)) &self.row else null;
    }
    pub fn bodyState(self: *const Slot) u8 {
        return self.body_state.load(.acquire);
    }
};
pub const Mailbox = struct {
    slots: [window]Slot = @splat(.{}),
    total: std.atomic.Value(usize) = .init(0),
    pub fn count(self: *const Mailbox) usize {
        return self.total.load(.acquire);
    }
    pub fn publish(self: *Mailbox, update: types.FetchRow) void {
        if (update.message.id.len == 0 or update.message.id.len > 128) return;
        if (update.kind == .body) {
            for (&self.slots) |*slot| {
                const row = slot.metadata() orelse continue;
                if (!std.mem.eql(u8, row.id.value(), update.message.id) or slot.bodyState() != 0) continue;
                slot.body_excerpt.set(update.message.bodyText);
                slot.body_state.store(if (update.failed) 2 else 1, .release);
                return;
            }
            return;
        }
        self.total.store(@min(update.total, window), .release);
        if (update.index >= window) return;
        const slot = &self.slots[update.index];
        if (slot.available.load(.acquire)) return;
        slot.row.id.set(update.message.id);
        slot.row.from_name.set(update.message.from.name);
        slot.row.from_address.set(update.message.from.address);
        slot.row.subject.set(update.message.subject);
        slot.row.snippet.set(update.message.snippet);
        slot.row.received_at = update.message.receivedAt;
        slot.row.unread = update.message.unread;
        slot.available.store(true, .release);
        if (update.message.bodyCached) {
            slot.body_excerpt.set(update.message.bodyText);
            slot.body_state.store(1, .release);
        }
    }
};
pub const frames = [_][]const u8{ "▱▱▱", "▰▱▱", "▱▰▱", "▱▱▰" };
pub fn frame(index: usize) []const u8 {
    return frames[index % frames.len];
}
test "loading rows: bounded immutable metadata becomes a ready body without borrowing provider memory" {
    var mailbox: Mailbox = .{};
    var subject: [1200]u8 = @splat('A');
    mailbox.publish(.{ .kind = .page, .index = 0, .total = 100, .message = .{ .id = "mail-a", .threadId = "thread-a", .subject = &subject } });
    @memset(&subject, 'B');
    try std.testing.expectEqual(@as(usize,32), mailbox.count());
    const row = mailbox.slots[0].metadata().?;
    try std.testing.expectEqual(@as(usize,1024), row.subject.value().len);
    try std.testing.expectEqual(@as(u8,'A'), row.subject.value()[0]);
    mailbox.publish(.{ .kind = .page, .index = 0, .total = 100, .message = .{ .id = "wrong-mail", .threadId = "wrong-thread", .subject = "must not overwrite" } });
    try std.testing.expectEqualStrings("mail-a", row.id.value());
    mailbox.publish(.{ .kind = .body, .message = .{ .id = "mail-a", .threadId = "thread-a", .bodyText = "Actual downloaded body" } });
    try std.testing.expectEqual(@as(u8,1), mailbox.slots[0].bodyState());
    try std.testing.expectEqualStrings("Actual downloaded body", mailbox.slots[0].body_excerpt.value());
    mailbox.publish(.{ .kind = .body, .message = .{ .id = "mail-a", .threadId = "thread-a", .bodyText = "second publication ignored" } });
    try std.testing.expectEqualStrings("Actual downloaded body", mailbox.slots[0].body_excerpt.value());
    try std.testing.expect(mailbox.slots[1].metadata() == null);
}
test "loading rows: UTF8 truncation stays valid and unknown bodies never replace another row" {
    var bytes: Bytes(5) = .{};
    bytes.set("ab🌋cd");
    try std.testing.expectEqualStrings("ab",bytes.value());
    var mailbox: Mailbox = .{};
    mailbox.publish(.{ .kind = .view, .total = 1, .message = .{ .id="one", .threadId="thread" } });
    mailbox.publish(.{ .kind = .body, .message = .{ .id="other", .threadId="thread", .bodyText="other private body" } });
    try std.testing.expectEqual(@as(u8,0),mailbox.slots[0].bodyState());
    mailbox.publish(.{ .kind=.body, .failed=true, .message=.{ .id="one", .threadId="thread" } });
    try std.testing.expectEqual(@as(u8,2),mailbox.slots[0].bodyState());
}
