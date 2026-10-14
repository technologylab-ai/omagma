//! Retry only explicit daemon admission refusals. A disconnect, timeout, or
//! unknown outcome may have executed a write and must never be replayed here.
const std = @import("std");
const t = @import("types.zig");
const Envelope = struct {
    ok: bool = true,
    @"error": ?struct { code: []const u8 } = null,
};
pub fn admissionRefused(a: std.mem.Allocator, response: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(Envelope, a, response, .{ .ignore_unknown_fields = true }) catch return false;
    if (value.ok) return false;
    const code = if (value.@"error") |failure| failure.code else return false;
    return std.mem.eql(u8, code, "VaultBusy") or std.mem.eql(u8, code, "VaultLocked");
}
pub fn snapshotCommand(a: std.mem.Allocator, raw: []const u8) bool {
    const Request = struct { cmd: []const u8 = "", draftId: []const u8 = "" };
    const request = std.json.parseFromSliceLeaky(Request, a, raw, .{ .ignore_unknown_fields = true }) catch return false;
    if (std.mem.eql(u8, request.cmd, "preferences.get") or std.mem.eql(u8, request.cmd, "preferences.set")) return true;
    return request.draftId.len > 0 and (std.mem.eql(u8, request.cmd, "draft.update") or std.mem.eql(u8, request.cmd, "draft.recovery-save"));
}
pub fn call(io: std.Io, backing: std.mem.Allocator, output: std.mem.Allocator, client: t.Client, raw: []const u8, wait_ms: i64) ![]const u8 {
    var validation: std.heap.ArenaAllocator = .init(backing);
    defer validation.deinit();
    if (!snapshotCommand(validation.allocator(), raw)) return error.InvalidRetryCommand;
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + wait_ms;
    while (true) {
        try io.checkCancel();
        var attempt: std.heap.ArenaAllocator = .init(backing);
        defer attempt.deinit();
        const a = attempt.allocator();
        const response = try client.call(a, raw);
        if (!admissionRefused(a, response)) return output.dupe(u8, response);
        const remaining = deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining <= 0) return output.dupe(u8, response);
        try io.sleep(.fromMilliseconds(@min(remaining, 100)), .awake);
    }
}

test "daemon snapshot retry: admission failures retry but unknown outcomes and sends never do" {
    const Fixture = struct {
        calls: usize = 0,
        failure: []const u8 = "VaultBusy",
        fn request(ctx: *anyopaque, a: std.mem.Allocator, _: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return if (self.calls <= 2)
                @import("json.zig").encodeAlloc(a, .{ .ok = false, .@"error" = .{ .code = self.failure } }, .{})
            else
                a.dupe(u8, "{\"ok\":true,\"data\":{\"saved\":true}}");
        }
    };
    const a = std.testing.allocator;
    var fixture: Fixture = .{};
    const client: t.Client = .{ .ctx = &fixture, .callFn = Fixture.request };
    const result = try call(std.testing.io, a, a, client, "{\"cmd\":\"preferences.set\"}", 2000);
    defer a.free(result);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    fixture = .{ .failure = "UnknownOutcome" };
    const unknown = try call(std.testing.io, a, a, client, "{\"cmd\":\"draft.update\",\"draftId\":\"saved-id\"}", 2000);
    defer a.free(unknown);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "UnknownOutcome") != null);
    try std.testing.expectError(error.InvalidRetryCommand, call(std.testing.io, a, a, client, "{\"cmd\":\"draft.send\",\"draftId\":\"saved-id\"}", 0));
    try std.testing.expectError(error.InvalidRetryCommand, call(std.testing.io, a, a, client, "{\"cmd\":\"draft.recovery-save\"}", 0));
}
