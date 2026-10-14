//! Stable identity based windows for received conversations. Provider order is
//! never a cursor; a missing boundary is an explicit stale-window result.
const std = @import("std");
const j = @import("json.zig");
const b = @import("../bounded.zig");
pub const limit: usize = 20;
pub const maximum: usize = 1000;
pub const Member = struct { id: []const u8, received_at: i64, source_index: usize };
pub const Window = struct { start: usize, end: usize, focus: usize };
pub const Response = struct {
    messages: []const @import("types.zig").Message,
    progressive: bool = true,
    cached: bool = false,
    partial: bool,
    totalMessages: usize,
    olderMessages: usize,
    newerMessages: usize,
    deferredMessages: usize,
    omittedMessages: usize,
    focusMessageId: []const u8,
};
pub fn response(messages: []const @import("types.zig").Message, total: usize, window: Window) Response {
    var deferred: usize = 0;
    var partial = window.start > 0 or window.end < total;
    for (messages) |message| {
        deferred += @intFromBool(!message.bodyCached and message.bodyCacheError.len == 0);
        partial = partial or message.metadataPartial or message.bodyCacheError.len > 0;
    }
    return .{ .messages = messages, .partial = partial or deferred > 0, .totalMessages = total, .olderMessages = window.start, .newerMessages = total - window.end, .deferredMessages = deferred, .omittedMessages = total - messages.len, .focusMessageId = messages[window.focus - window.start].id };
}
pub fn older(_: void, left: Member, right: Member) bool {
    return left.received_at < right.received_at or (left.received_at == right.received_at and std.mem.lessThan(u8, left.id, right.id));
}
fn find(members: []const Member, id: []const u8) !usize {
    try b.identifier(id);
    for (members, 0..) |member, index| if (std.mem.eql(u8, member.id, id)) return index;
    return error.ThreadWindowChanged;
}
pub fn choose(members: []const Member, request: j.Value) !Window {
    if (members.len == 0) return error.MessageNotFound;
    if (members.len > maximum) return error.ThreadTooLarge;
    for ([_][]const u8{ "beforeMessageId", "afterMessageId", "windowStartMessageId", "windowEndMessageId", "focusMessageId" }) |field| if (j.get(request, field)) |value| if (value != .string) return error.InvalidThreadWindow;
    const before = j.text(request, "beforeMessageId");
    const after = j.text(request, "afterMessageId");
    const first = j.text(request, "windowStartMessageId");
    const last = j.text(request, "windowEndMessageId");
    const focused = j.text(request, "focusMessageId");
    if (@as(u8, @intFromBool(before.len > 0)) + @as(u8, @intFromBool(after.len > 0)) + @as(u8, @intFromBool(first.len > 0 or last.len > 0)) > 1) return error.InvalidThreadWindow;
    var start = members.len -| limit;
    var end = members.len;
    if (before.len > 0) {
        end = try find(members, before);
        start = end -| limit;
    } else if (after.len > 0) {
        start = (try find(members, after)) + 1;
        end = @min(start + limit, members.len);
    } else if (first.len > 0 or last.len > 0) {
        if (first.len == 0 or last.len == 0) return error.InvalidThreadWindow;
        start = try find(members, first);
        end = (try find(members, last)) + 1;
        if (end <= start or end - start > limit) return error.ThreadWindowChanged;
    } else if (focused.len > 0) {
        const index = try find(members, focused);
        if (index < start) {
            start = index -| (limit - 1);
            end = @min(start + limit, members.len);
        }
    }
    if (start == end) return error.ThreadWindowBoundary;
    const focus = if (focused.len > 0) try find(members, focused) else if (after.len > 0) start else end - 1;
    if (focus < start or focus >= end) return error.ThreadWindowChanged;
    return .{ .start = start, .end = end, .focus = focus };
}

test "progressive thread: identity windows retain selected old mail and reject stale boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var members: [63]Member = undefined;
    for (&members, 0..) |*member, index| member.* = .{ .id = try std.fmt.allocPrint(a, "mail-{d}", .{index}), .received_at = @intCast(index), .source_index = index };
    const latest = try choose(&members, try j.value(a, .{}));
    try std.testing.expectEqual(Window{ .start = 43, .end = 63, .focus = 62 }, latest);
    const old = try choose(&members, try j.value(a, .{ .focusMessageId = "mail-5" }));
    try std.testing.expectEqual(@as(usize, 5), old.focus);
    const preceding = try choose(&members, try j.value(a, .{ .beforeMessageId = "mail-43" }));
    try std.testing.expectEqual(Window{ .start = 23, .end = 43, .focus = 42 }, preceding);
    const retained = try choose(&members, try j.value(a, .{ .windowStartMessageId = "mail-43", .windowEndMessageId = "mail-62", .focusMessageId = "mail-45" }));
    try std.testing.expectEqual(Window{ .start = 43, .end = 63, .focus = 45 }, retained);
    try std.testing.expectError(error.ThreadWindowChanged, choose(&members, try j.value(a, .{ .beforeMessageId = "deleted-mail" })));
    try std.testing.expectError(error.InvalidThreadWindow, choose(&members, try j.value(a, .{ .beforeMessageId = "mail-43", .afterMessageId = "mail-42" })));
    try std.testing.expectError(error.InvalidThreadWindow, choose(&members, try j.value(a, .{ .focusMessageId = 42 })));
}
