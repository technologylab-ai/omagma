const std = @import("std");

pub const Context = enum { none, labels, links, attachments, send, trash, invitation, preview, theme };

/// Modal action focus is independent of the selected row and editor caret.
/// A new review starts on its supplied safe default, never on an old action.
pub const Focus = struct {
    context: Context = .none,
    index: usize = 0,

    pub fn reset(self: *Focus, context: Context, initial: usize) void {
        self.* = .{ .context = context, .index = initial };
    }

    pub fn ensure(self: *Focus, context: Context, initial: usize) void {
        if (self.context != context) self.reset(context, initial);
    }

    pub fn move(self: *Focus, backwards: bool, count: usize, enabled: u8) void {
        if (count == 0) return;
        self.index = @min(self.index, count - 1);
        for (0..count) |_| {
            self.index = (self.index + if (backwards) count - 1 else 1) % count;
            if (enabled & (@as(u8, 1) << @intCast(self.index)) != 0) return;
        }
    }
};

test "dialog controls: reverse traversal skips disabled actions and new reviews reset safely" {
    var focus: Focus = .{};
    focus.reset(.labels, 1);
    focus.move(false, 5, 0b10011);
    try std.testing.expectEqual(@as(usize, 4), focus.index);
    focus.move(true, 5, 0b10011);
    try std.testing.expectEqual(@as(usize, 1), focus.index);
    focus.move(true, 5, 0b10011);
    try std.testing.expectEqual(@as(usize, 0), focus.index);
    focus.ensure(.send, 0);
    try std.testing.expectEqual(@as(usize, 0), focus.index);
    focus.move(false, 2, 0b11);
    try std.testing.expectEqual(@as(usize, 1), focus.index);
    focus.reset(.send, 0);
    try std.testing.expectEqual(@as(usize, 0), focus.index);
}
