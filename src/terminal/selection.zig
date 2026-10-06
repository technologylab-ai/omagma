//! Bounded multi-message selection, owned by one account and mailbox/search scope.
const std = @import("std");
const bounded = @import("../bounded.zig");
pub const Selection = struct {
    account: bounded.Text(254) = .{},
    scope: [32]u8 = @splat(0),
    ids: [100]bounded.Text(512) = @splat(.{}),
    count: usize = 0,
    pub fn clear(self: *Selection) void {
        self.count = 0;
    }
    pub fn ensureScope(self: *Selection, account: []const u8, mailbox: []const u8, query: []const u8) !void {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(account);
        hash.update("\x00");
        hash.update(mailbox);
        hash.update("\x00");
        hash.update(query);
        var scope: [32]u8 = undefined;
        hash.final(&scope);
        if (!std.mem.eql(u8, self.account.slice(), account) or !std.mem.eql(u8, &self.scope, &scope)) {
            self.clear();
            try self.account.set(account);
            self.scope = scope;
        }
    }
    pub fn contains(self: *const Selection, id: []const u8) bool {
        for (self.ids[0..self.count]) |*value| if (std.mem.eql(u8, value.slice(), id)) return true;
        return false;
    }
    pub fn toggle(self: *Selection, id: []const u8) !void {
        if (id.len == 0 or id.len > 512) return error.InvalidMessageId;
        for (self.ids[0..self.count], 0..) |*value, index| if (std.mem.eql(u8, value.slice(), id)) {
            for (index..self.count - 1) |i| self.ids[i] = self.ids[i + 1];
            self.count -= 1;
            return;
        };
        if (self.count == self.ids.len) return error.SelectionLimitExceeded;
        try self.ids[self.count].set(id);
        self.count += 1;
    }
};
test "triage UI: selection survives paging but is cleared across accounts or search scopes" {
    var selection: Selection = .{};
    try selection.ensureScope("work@example.com", "INBOX", "");
    try selection.toggle("shared-id");
    try selection.toggle("another-id");
    try selection.ensureScope("work@example.com", "INBOX", "");
    try std.testing.expect(selection.contains("shared-id") and selection.count == 2);
    try selection.toggle("shared-id");
    try std.testing.expect(!selection.contains("shared-id") and selection.count == 1);
    try selection.ensureScope("personal@example.com", "INBOX", "");
    try std.testing.expectEqual(@as(usize, 0), selection.count);
    try selection.toggle("shared-id");
    try selection.ensureScope("personal@example.com", "INBOX", "body:meeting");
    try std.testing.expectEqual(@as(usize, 0), selection.count);
}
test "triage UI: selection refuses overflow without dropping existing identities" {
    var selection: Selection = .{};
    try selection.ensureScope("work@example.com", "INBOX", "");
    for (0..100) |index| {
        var buffer: [32]u8 = undefined;
        try selection.toggle(try std.fmt.bufPrint(&buffer, "message-{d}", .{index}));
    }
    try std.testing.expectError(error.SelectionLimitExceeded, selection.toggle("overflow"));
    try std.testing.expectEqual(@as(usize, 100), selection.count);
    try std.testing.expect(selection.contains("message-0") and selection.contains("message-99"));
}
