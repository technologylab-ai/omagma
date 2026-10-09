const std = @import("std");
const j = @import("json.zig");
const recipients = @import("recipients.zig");
const storage = @import("store.zig");
pub const Delta = struct { add: []const []const u8, remove: []const []const u8 };
pub const Scope = enum { message, conversation };
pub fn scope(request: j.Value) !Scope {
    const text = j.text(request, "scope");
    if (text.len == 0) return .message;
    return std.meta.stringToEnum(Scope, text) orelse error.InvalidTriageScope;
}
/// Scope resolution happens before review. Mutations always accept only this
/// explicit snapshot, never the thread ID or a query that could grow later.
pub fn pinned(a: std.mem.Allocator, request: j.Value) ![]const []const u8 {
    const values = j.get(request, "messageIds") orelse return error.MissingField;
    if (values != .array or values.array.items.len == 0 or values.array.items.len > 100) return error.InvalidBatchSize;
    const ids = try a.alloc([]const u8, values.array.items.len);
    for (values.array.items, ids, 0..) |value, *id, index| {
        id.* = try j.string(value);
        try @import("../bounded.zig").identifier(id.*);
        for (ids[0..index]) |previous| if (std.mem.eql(u8, previous, id.*)) return error.DuplicateMessage;
    }
    return ids;
}
fn has(labels: []const []const u8, wanted: []const u8) bool {
    for (labels) |label| if (std.mem.eql(u8, label, wanted)) return true;
    return false;
}
fn append(a: std.mem.Allocator, list: *std.ArrayList([]const u8), label: []const u8) !void {
    if (label.len == 0 or label.len > 256) return error.InvalidLabel;
    try recipients.validateHeader(label);
    if (!has(list.items, label)) try list.append(a, label);
}
pub fn plan(a: std.mem.Allocator, request: j.Value) !Delta {
    const action = try j.required(request, "action");
    var add: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, action, "archive")) {
        try append(a, &remove, "INBOX");
    } else if (std.mem.eql(u8, action, "trash") or std.mem.eql(u8, action, "spam")) {
        try append(a, &remove, "INBOX");
        try append(a, &add, if (std.mem.eql(u8, action, "trash")) "TRASH" else "SPAM");
    } else if (std.mem.eql(u8, action, "restore") or std.mem.eql(u8, action, "unspam")) {
        try append(a, &remove, if (std.mem.eql(u8, action, "restore")) "TRASH" else "SPAM");
        try append(a, &add, "INBOX");
    } else if (!std.mem.eql(u8, action, "mark")) return error.InvalidBatchAction;
    for ([_][]const u8{ "unread", "starred" }, [_][]const u8{ "UNREAD", "STARRED" }) |key, label| if (j.get(request, key) != null) {
        try append(a, if (try j.boolean(request, key, false)) &add else &remove, label);
    };
    for ([_][]const u8{ "addLabels", "removeLabels" }, [_]*std.ArrayList([]const u8){ &add, &remove }) |key, list| {
        if (j.get(request, key)) |values| {
            if (values != .array or values.array.items.len > 64) return error.TooManyLabels;
            for (values.array.items) |value| try append(a, list, try j.string(value));
        }
    }
    if (add.items.len + remove.items.len > 64) return error.TooManyLabels;
    for (add.items) |label| if (has(remove.items, label)) return error.ConflictingLabels;
    if (add.items.len + remove.items.len == 0) return error.EmptyMutation;
    return .{ .add = add.items, .remove = remove.items };
}
pub fn inverse(a: std.mem.Allocator, id: []const u8, before: []const []const u8, delta: Delta) !storage.UndoItem {
    var add: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    for (delta.remove) |label| if (has(before, label)) try add.append(a, label);
    for (delta.add) |label| if (!has(before, label)) try remove.append(a, label);
    return .{ .messageId = id, .addLabels = add.items, .removeLabels = remove.items };
}
pub fn apply(a: std.mem.Allocator, before: []const []const u8, delta: Delta) ![]const []const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    for (before) |label| if (!has(delta.remove, label)) try append(a, &labels, label);
    for (delta.add) |label| try append(a, &labels, label);
    if (labels.items.len > 64) return error.TooManyLabels;
    return labels.items;
}

test "wishlist: undo preserves concurrent unrelated labels and no-op membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const delta = try plan(a, try j.value(a, .{ .action = "trash", .unread = false }));
    const undo = try inverse(a, "m", &.{ "INBOX", "UNREAD", "Label_old" }, delta);
    const restored = try apply(a, &.{ "TRASH", "Label_old", "Label_concurrent" }, .{ .add = undo.addLabels, .remove = undo.removeLabels });
    try std.testing.expect(has(restored, "INBOX") and has(restored, "UNREAD") and has(restored, "Label_concurrent"));
    try std.testing.expect(!has(restored, "TRASH"));
    const already = try inverse(a, "m", &.{"STARRED"}, .{ .add = &.{"STARRED"}, .remove = &.{"INBOX"} });
    try std.testing.expect(already.addLabels.len == 0 and already.removeLabels.len == 0);
}
