const std = @import("std");
const l = @import("limits.zig");
const b = @import("bounded.zig");
pub const Framer = struct {
    storage: [l.input_frame]u8 = undefined,
    len: usize = 0,
    oversized: bool = false,
    pub const Result = union(enum) { pending, line: []const u8, overflow };
    pub fn byte(self: *Framer, c: u8) Result {
        if (c == '\n') {
            if (self.oversized) {
                self.oversized = false;
                self.len = 0;
                return .overflow;
            }
            const result = self.storage[0..self.len];
            self.len = 0;
            return .{ .line = result };
        }
        if (self.oversized) return .pending;
        if (self.len == self.storage.len) {
            self.oversized = true;
            self.len = 0;
            return .pending;
        }
        self.storage[self.len] = c;
        self.len += 1;
        return .pending;
    }
};
pub const Request = struct {
    id: ?u64 = null,
    cmd: []const u8,
    account: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    message: ?[]const u8 = null,
    open: ?bool = null,
    fallback: bool = false,
    pub fn from(v: std.json.Value) !Request {
        const idv = try b.field(v, "id");
        if (idv != .integer or idv.integer < 0 or idv.integer > 9007199254740991) return error.InvalidRequestId;
        var req: Request = .{ .id = @intCast(idv.integer), .cmd = try b.string(try b.field(v, "cmd")) };
        if (b.optional(v, "account")) |a| {
            req.account = try b.string(a);
            try b.address(req.account.?);
        }
        if (b.optional(v, "kind")) |a| req.kind = try b.string(a);
        if (b.optional(v, "message")) |a| req.message = try b.string(a);
        if (b.optional(v, "open")) |a| {
            if (a != .bool) return error.InvalidRequest;
            req.open = a.bool;
        }
        if (b.optional(v, "fallback")) |a| {
            if (a != .bool) return error.InvalidRequest;
            req.fallback = a.bool;
        }
        return req;
    }
};
test "oversized IPC frame recovers at delimiter" {
    var f: Framer = .{};
    for (0..l.input_frame + 1) |_| _ = f.byte('a');
    try std.testing.expect(f.byte('\n') == .overflow);
    _ = f.byte('{');
    _ = f.byte('}');
    try std.testing.expectEqualStrings("{}", f.byte('\n').line);
}
