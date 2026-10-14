//! Runtime-only identity injection. Providers never come from JSON and never
//! expose secrets through the application protocol. Reads borrow until apply.
const std = @import("std");
pub const Kind = enum { configuration, grants, desktop_client, bar_token, terminal_token, preferences };
pub const max_preferences_bytes = 256 * 1024;
pub const Key = struct {
    name: []const u8 = "",
    account: []const u8 = "",
    client: []const u8 = "",
    grant: []const u8 = "",
    pub fn eql(left: Key, right: Key) bool {
        return std.mem.eql(u8, left.name, right.name) and std.mem.eql(u8, left.account, right.account) and std.mem.eql(u8, left.client, right.client) and std.mem.eql(u8, left.grant, right.grant);
    }
};
/// Null token value with account only removes every token in that namespace
/// for that account. All changes in one apply are published atomically.
pub const Change = struct { kind: Kind, key: Key = .{}, value: ?[]const u8 };
pub const Provider = struct {
    context: *anyopaque,
    readFn: *const fn (*anyopaque, Kind, Key) anyerror!?[]const u8,
    applyFn: *const fn (*anyopaque, []const Change) anyerror!void,
    pub fn read(self: Provider, kind: Kind, key: Key) !?[]const u8 {
        return self.readFn(self.context, kind, key);
    }
    pub fn apply(self: Provider, changes: []const Change) !void {
        return self.applyFn(self.context, changes);
    }
};
