//! Read-only local Client commands. Neither adapter may promote a cache call
//! into provider traffic or a local/remote mutation.
const std = @import("std");
pub fn cachedCommand(command: []const u8) bool {
    for ([_][]const u8{ "labels.list", "accounts.identities", "mail.list", "mail.recipients", "mail.search", "mail.read", "mail.thread", "cache.stats", "cache.activity", "cache.refresh-status", "contacts.list", "contacts.search" }) |allowed| if (std.mem.eql(u8, command, allowed)) return true;
    return false;
}
test "client contract: cached reads exclude draft and provider mutations" {
    for ([_][]const u8{ "mail.read", "mail.search", "mail.list", "contacts.search", "mail.recipients" }) |command| try std.testing.expect(cachedCommand(command));
    for ([_][]const u8{ "draft.send", "draft.update", "draft.discard", "mail.reply", "mail.forward", "contacts.upsert", "mail.refresh" }) |command| try std.testing.expect(!cachedCommand(command));
}
