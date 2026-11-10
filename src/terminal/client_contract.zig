//! Read-only local Client commands. Neither adapter may promote a cache call
//! into provider traffic or a local/remote mutation. This is the single source
//! of truth for "mutates": disconnect classification, the JSONL fields
//! projection and the published manifest/help cards all derive from it.
const std = @import("std");
const j = @import("json.zig");
/// Disconnects after a request was submitted are safe to classify as reads
/// only for this positive allowlist. New/unknown commands default to mutation.
/// Reconciliation commands are not reads: they settle a recorded outcome in
/// the local journal, so they are classified with the writes they check.
pub fn readOnlyCommand(command: []const u8) bool {
    for ([_][]const u8{ "history.operations", "history.drafts", "history.queues", "operation.read", "operation.list", "queue.read", "draft.measure", "draft.preview", "draft.delivery-plan", "draft.selection-plan", "draft.gmail-info", "calendar.freebusy", "calendar.invitation-plan", "mail.sync", "mail.attachment" }) |allowed| if (std.mem.eql(u8, command, allowed)) return true;
    // The command name alone cannot prove whether inspection will continue a
    // previously authorized Calendar write. Callers with flags use the helper.
    if (std.mem.eql(u8, command, "invitation.inspect")) return false;
    if (std.mem.eql(u8, command, "calendar.event-pending") or std.mem.eql(u8, command, "calendar.meet-event-pending")) return true;
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
/// Whether some request of this command can change state (remote, local
/// journal, drafts, cache policy or an opened browser). Conditional commands
/// (invitation.inspect with reconcile:true) count as mutating.
pub fn mayMutate(command: []const u8) bool {
    return !readOnlyEnvelope(command, true);
}
/// Read-only unless an explicit flag asks it to continue a recorded write.
pub fn conditionalMutation(command: []const u8) ?[]const u8 {
    if (readOnlyEnvelope(command, false) and !readOnlyEnvelope(command, true)) return "reconcile:true";
    return null;
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

test "meet notes: pending is a local read, reconcile settles the journal, neither enters cache adapters" {
    try std.testing.expect(readOnlyCommand("calendar.meet-event-pending"));
    // Reconciliation uses provider reads only but records the settled outcome
    // in the local journal, like calendar.reconcile and event-reconcile.
    for ([_][]const u8{ "calendar.meet-event-reconcile", "calendar.event-reconcile", "calendar.reconcile", "calendar.meet-event-apply" }) |command| try std.testing.expect(!readOnlyCommand(command));
    for ([_][]const u8{ "calendar.meet-event-pending", "calendar.meet-event-reconcile" }) |command| try std.testing.expect(!cachedCommand(command));
}
test "client contract: reads that never write are classified read-only, conditional inspection mutates only with reconcile" {
    for ([_][]const u8{ "draft.gmail-info", "calendar.freebusy", "calendar.invitation-plan", "mail.sync", "mail.attachment", "mail.read", "calendar.agenda" }) |command| {
        try std.testing.expect(readOnlyCommand(command));
        try std.testing.expect(!mayMutate(command));
    }
    for ([_][]const u8{ "draft.gmail-save", "draft.gmail-status", "mail.attachment-save", "mail.send", "draft.patch", "contacts.upsert", "reminder.set" }) |command| try std.testing.expect(mayMutate(command));
    try std.testing.expect(mayMutate("invitation.inspect"));
    try std.testing.expectEqualStrings("reconcile:true", conditionalMutation("invitation.inspect").?);
    try std.testing.expect(conditionalMutation("mail.read") == null and conditionalMutation("mail.send") == null);
}
