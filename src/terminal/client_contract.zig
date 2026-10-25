//! Read-only local Client commands. Neither adapter may promote a cache call
//! into provider traffic or a local/remote mutation.
const std = @import("std");
const j = @import("json.zig");
/// Disconnects after a request was submitted are safe to classify as reads
/// only for this positive allowlist. New/unknown commands default to mutation.
pub fn readOnlyCommand(command: []const u8) bool {
    for ([_][]const u8{ "history.operations", "history.drafts", "history.queues", "operation.read", "operation.list", "queue.read" }) |allowed| if (std.mem.eql(u8, command, allowed)) return true;
    // The command name alone cannot prove whether inspection will continue a
    // previously authorized Calendar write. Callers with flags use the helper.
    if (std.mem.eql(u8, command, "invitation.inspect")) return false;
    if (std.mem.eql(u8, command, "calendar.event-pending")) return true;
    if (cachedCommand(command)) return true;
    for ([_][]const u8{ "accounts.list", "auth.status", "preferences.get", "labels.palette", "mail.label-state", "mail.triage-scope", "mail.compose-source", "draft.list", "draft.read", "queue.list", "queue.status", "updates.check" }) |allowed| if (std.mem.eql(u8, command, allowed)) return true;
    return false;
}
pub fn readOnlyEnvelope(command: []const u8, reconcile: bool) bool {
    if (std.mem.eql(u8, command, "invitation.inspect")) return !reconcile;
    return readOnlyCommand(command);
}
pub fn readOnlyRequest(request: j.Value) bool {
    return readOnlyEnvelope(j.text(request, "cmd"), j.boolean(request, "reconcile", false) catch return false);
}
pub fn cachedRequest(request: j.Value) bool {
    const command = j.text(request, "cmd");
    if (!cachedCommand(command)) return false;
    return !std.mem.eql(u8, command, "invitation.inspect") or !(j.boolean(request, "reconcile", false) catch return false);
}
pub fn cachedCommand(command: []const u8) bool {
    if (std.mem.eql(u8, command, "reminder.list") or std.mem.eql(u8, command, "invitation.inspect")) return true;
    for ([_][]const u8{ "labels.list", "accounts.identities", "mail.list", "mail.recipients", "mail.search", "mail.read", "mail.thread", "cache.stats", "cache.activity", "cache.refresh-status", "contacts.list", "contacts.search", "calendar.list", "calendar.agenda", "calendar.event" }) |allowed| if (std.mem.eql(u8, command, allowed)) return true;
    return false;
}
test "client contract: cached reads exclude draft and provider mutations" {
    try std.testing.expect(readOnlyCommand("calendar.event-pending"));
    try std.testing.expect(!cachedCommand("calendar.event-pending"));
    for ([_][]const u8{ "mail.read", "mail.search", "mail.list", "contacts.search", "mail.recipients" }) |command| try std.testing.expect(cachedCommand(command));
    for ([_][]const u8{ "draft.send", "draft.update", "draft.discard", "mail.reply", "mail.forward", "contacts.upsert", "mail.refresh", "calendar.review", "calendar.apply", "calendar.freebusy", "calendar.reconcile" }) |command| try std.testing.expect(!cachedCommand(command));
}
test "client contract: invitation reconciliation is a mutation and cannot enter cached adapters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |reconcile| {
        const request = try j.value(a, .{ .cmd = "invitation.inspect", .reconcile = reconcile });
        try std.testing.expectEqual(!reconcile, readOnlyRequest(request));
        try std.testing.expectEqual(!reconcile, cachedRequest(request));
    }
    try std.testing.expect(!readOnlyCommand("invitation.inspect"));
    try std.testing.expect(cachedCommand("invitation.inspect"));
    try std.testing.expect(readOnlyRequest(try j.value(a, .{ .cmd = "invitation.inspect" })));
    try std.testing.expect(!cachedRequest(try j.value(a, .{ .cmd = "invitation.inspect", .reconcile = "true" })));
}
