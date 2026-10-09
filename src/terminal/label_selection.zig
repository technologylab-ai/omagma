//! Staged custom-label membership over an explicitly frozen message scope.
const std = @import("std");
const bounded = @import("../bounded.zig");
pub const Desired = enum { unchanged, add, remove };
pub const Entry = struct {
    id: bounded.Text(256) = .{},
    applied: usize = 0,
    desired: Desired = .unchanged,
};
pub const State = struct {
    entries: [512]Entry = @splat(.{}),
    count: usize = 0,
    targets: usize = 0,
    ready: bool = false,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
    pub fn add(self: *State, id: []const u8, applied: usize) !void {
        if (self.count == self.entries.len or self.targets == 0 or applied > self.targets) return error.InvalidLabelState;
        if (self.get(id) != null) return error.DuplicateLabel;
        var entry: Entry = .{ .applied = applied };
        try entry.id.set(id);
        self.entries[self.count] = entry;
        self.count += 1;
    }
    pub fn get(self: *State, id: []const u8) ?*Entry {
        for (self.entries[0..self.count]) |*entry| if (std.mem.eql(u8, entry.id.slice(), id)) return entry;
        return null;
    }
    pub fn mark(self: *State, id: []const u8) []const u8 {
        const entry = self.get(id) orelse return "[?]";
        return switch (entry.desired) {
            .add => "[x]",
            .remove => "[ ]",
            .unchanged => if (entry.applied == self.targets) "[x]" else if (entry.applied == 0) "[ ]" else "[-]",
        };
    }
    pub fn toggle(self: *State, id: []const u8) !void {
        if (!self.ready) return error.LabelStatePending;
        const entry = self.get(id) orelse return error.LabelNotFound;
        const now_set = entry.desired == .add or (entry.desired == .unchanged and entry.applied == self.targets);
        try self.stage(id, if (now_set) .remove else .add);
    }
    pub fn stage(self: *State, id: []const u8, desired: Desired) !void {
        if (!self.ready) return error.LabelStatePending;
        const entry = self.get(id) orelse return error.LabelNotFound;
        entry.desired = if ((desired == .add and entry.applied == self.targets) or
            (desired == .remove and entry.applied == 0)) .unchanged else desired;
    }
    pub fn changed(self: *const State) usize {
        var count: usize = 0;
        for (self.entries[0..self.count]) |entry| if (entry.desired != .unchanged) {
            count += 1;
        };
        return count;
    }
};

test "label staging: mixed selection toggles explicitly and cancel does not produce changes" {
    var state: State = .{ .targets = 3 };
    try state.add("work", 3);
    try state.add("travel", 1);
    try state.add("receipts", 0);
    state.ready = true;
    try std.testing.expectEqualStrings("[-]", state.mark("travel"));
    try state.toggle("travel");
    try std.testing.expectEqualStrings("[x]", state.mark("travel"));
    try state.toggle("work");
    try std.testing.expectEqual(@as(usize, 2), state.changed());
    try state.stage("work", .add);
    try std.testing.expectEqual(@as(usize, 1), state.changed());
    state.reset();
    try std.testing.expectEqual(@as(usize, 0), state.changed());
}
