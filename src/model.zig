const std = @import("std");
const b = @import("bounded.zig");
const l = @import("limits.zig");
pub const State = enum { never, loading, current, stale, disconnected, unavailable };
pub const Message = struct {
    id: b.Text(l.max_id) = .{},
    thread_id: b.Text(l.max_id) = .{},
    sender: b.Text(l.sender) = .{},
    subject: b.Text(l.subject) = .{},
    snippet: b.Text(l.snippet) = .{},
    message_id: b.Text(l.message_id) = .{},
    received_at: i64 = 0,
    unread: bool = false,
};
pub const Snapshot = struct {
    messages: [l.max_rows]Message = @splat(.{}),
    count: usize = 0,
    unread: ?u32 = null,
    checked_at: i64 = 0,
    partial: bool = false,
    pub fn sort(self: *Snapshot) void {
        // At most30records: insertion sort uses one Message on the stack.
        // std.mem.sort's block-sort scratch can exceed1MiB for this record size.
        if (self.count < 2) return;
        for (1..self.count) |i| {
            const item = self.messages[i];
            var j = i;
            while (j > 0 and self.messages[j - 1].received_at < item.received_at) : (j -= 1) self.messages[j] = self.messages[j - 1];
            self.messages[j] = item;
        }
    }
};
pub const Account = struct {
    address: b.Text(l.max_address) = .{},
    profile: b.Text(128) = .{},
    enabled: bool = true,
    required: bool = true,
    state: State = .never,
    generation: u64 = 0,
    snapshot: Snapshot = .{},
    error_code: b.Text(64) = .{},
    retry_at: i64 = 0,
    pending: bool = false,
    fixture_jobs: u64 = 0,
    pub fn bump(self: *Account) void {
        self.generation +%= 1;
    }
    pub fn fail(self: *Account, code: []const u8, disconnected: bool) void {
        self.state = if (disconnected) .disconnected else if (self.snapshot.checked_at > 0) .stale else .never;
        self.error_code.set(code) catch unreachable;
        self.bump();
    }
    pub fn publish(self: *Account, snapshot: *const Snapshot) void {
        self.snapshot = snapshot.*;
        self.state = .current;
        self.error_code = .{};
        self.retry_at = 0;
        self.bump();
    }
};

pub fn writeSnapshot(w: *std.Io.Writer, a: *const Account, event: bool) !void {
    try w.writeAll(if (event) "{\"ev\":\"snapshot\",\"account\":" else "{\"account\":");
    try b.jsonString(w, a.address.slice());
    try w.print(",\"enabled\":{s},\"required\":{s},\"generation\":{d},\"state\":\"{s}\",\"checkedAt\":{d},\"unread\":", .{ if (a.enabled) "true" else "false", if (a.required) "true" else "false", a.generation, @tagName(a.state), a.snapshot.checked_at });
    if (a.snapshot.unread) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.print(",\"partial\":{s},\"error\":", .{if (a.snapshot.partial) "true" else "false"});
    try b.jsonString(w, a.error_code.slice());
    try w.print(",\"retryAt\":{d},\"messages\":[", .{a.retry_at});
    for (a.snapshot.messages[0..a.snapshot.count], 0..) |*m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try b.jsonString(w, m.id.slice());
        try w.writeAll(",\"threadId\":");
        try b.jsonString(w, m.thread_id.slice());
        try w.writeAll(",\"sender\":");
        try b.jsonString(w, m.sender.slice());
        try w.writeAll(",\"subject\":");
        try b.jsonString(w, m.subject.slice());
        try w.writeAll(",\"snippet\":");
        try b.jsonString(w, m.snippet.slice());
        try w.print(",\"receivedAt\":{d},\"unread\":{s}}}", .{ m.received_at, if (m.unread) "true" else "false" });
    }
    try w.writeAll("]}");
}
test "snapshot JSON worst-case escape fits declared IPC frame" {
    const a = try std.testing.allocator.create(Account);
    defer std.testing.allocator.destroy(a);
    a.* = .{};
    try a.address.set("a@example.com");
    a.snapshot.count = l.max_rows;
    for (&a.snapshot.messages) |*m| {
        m.* = .{};
        @memset(&m.sender.bytes, '"');
        m.sender.len = l.sender;
        @memset(&m.subject.bytes, '\\');
        m.subject.len = l.subject;
        @memset(&m.snippet.bytes, '\t');
        m.snippet.len = l.snippet;
    }
    const buf = try std.testing.allocator.alloc(u8, l.output_frame);
    defer std.testing.allocator.free(buf);
    var w = std.Io.Writer.fixed(buf);
    try writeSnapshot(&w, a, true);
    try std.testing.expect(w.buffered().len < l.output_frame);
}

test "bounded timestamp sorting is descending and stable for equal dates" {
    var snapshot: Snapshot = .{};
    snapshot.count = 4;
    snapshot.messages[0].received_at = 10;
    try snapshot.messages[0].id.set("first");
    snapshot.messages[1].received_at = 20;
    try snapshot.messages[1].id.set("newer");
    snapshot.messages[2].received_at = 10;
    try snapshot.messages[2].id.set("second");
    snapshot.messages[3].received_at = 1;
    try snapshot.messages[3].id.set("oldest");
    snapshot.sort();
    try std.testing.expectEqualStrings("newer", snapshot.messages[0].id.slice());
    try std.testing.expectEqualStrings("first", snapshot.messages[1].id.slice());
    try std.testing.expectEqualStrings("second", snapshot.messages[2].id.slice());
    snapshot.count = 0;
    snapshot.sort();
}
