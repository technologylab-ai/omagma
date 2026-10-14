//! Bounded local ownership for explicit Gmail draft handoff. An uncertain
//! create is never retried, and taking back never deletes a remote draft.
const std = @import("std");
const bounded = @import("../bounded.zig");
const mime = @import("mime.zig");

pub const limit = 128;
pub const Phase = enum { unknown, linked, missing, rejected };
pub const Link = struct {
    draftId: []const u8,
    phase: Phase = .unknown,
    remoteDraftId: []const u8 = "",
    remoteMessageId: []const u8 = "",
    attemptMessageId: []const u8,
    uploadedDigest: []const u8,
    uploadedAtMs: i64 = 0,
    version: u64 = 1,
    paused: bool = true,
    possiblySentElsewhere: bool = false,
    // Explicit acknowledgement in the send review is invalidated by any edit.
    sendAcknowledgedDigest: []const u8 = "",
    errorCode: []const u8 = "",
    lastImportedMessageId: []const u8 = "",
    lastImportedDraftId: []const u8 = "",

    pub fn validate(self: Link) !void {
        try bounded.identifier(self.draftId);
        if (self.version == 0 or self.uploadedAtMs < 0) return error.InvalidDraftLink;
        if (!mime.validMessageId(self.attemptMessageId) or self.attemptMessageId.len > 128) return error.InvalidDraftLink;
        try digest(self.uploadedDigest);
        if (self.sendAcknowledgedDigest.len > 0) try digest(self.sendAcknowledgedDigest);
        if (self.errorCode.len > 128) return error.InvalidDraftLink;
        for (self.errorCode) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidDraftLink;
        if (self.lastImportedMessageId.len > 0) try bounded.identifier(self.lastImportedMessageId);
        if (self.lastImportedDraftId.len > 0) try bounded.identifier(self.lastImportedDraftId);
        if (self.remoteDraftId.len > 0) try bounded.identifier(self.remoteDraftId);
        if (self.remoteMessageId.len > 0) try bounded.identifier(self.remoteMessageId);
        if (self.phase == .linked and (self.remoteDraftId.len == 0 or self.remoteMessageId.len == 0)) return error.InvalidDraftLink;
        if (self.phase == .unknown and !self.paused) return error.InvalidDraftLink;
    }
    pub fn expectVersion(self: Link, expected: u64) !void {
        if (expected != self.version) return error.GmailDraftChanged;
    }
    pub fn bump(self: *Link) !void {
        self.version = std.math.add(u64, self.version, 1) catch return error.DraftLinkLimitReached;
    }
    pub fn applied(self: *Link, a: std.mem.Allocator, remote_draft: []const u8, remote_message: []const u8, now: i64) !void {
        try bounded.identifier(remote_draft);
        try bounded.identifier(remote_message);
        self.remoteDraftId = try a.dupe(u8, remote_draft);
        self.remoteMessageId = try a.dupe(u8, remote_message);
        self.phase = .linked;
        self.paused = true;
        self.uploadedAtMs = now;
        self.errorCode = "";
        self.sendAcknowledgedDigest = "";
        try self.bump();
    }
    pub fn rejected(self: *Link, a: std.mem.Allocator, code: []const u8) !void {
        self.phase = .rejected;
        self.paused = false;
        self.errorCode = try a.dupe(u8, code);
        self.sendAcknowledgedDigest = "";
        try self.bump();
    }
    /// The current remote version is checked by the caller immediately before
    /// this local-only ownership change. Missing copies are never assumed sent.
    pub fn takeBack(self: *Link, expected: u64, current_remote: ?[]const u8, keep_local_after_change: bool) !void {
        try self.expectVersion(expected);
        if (self.phase == .unknown) return error.GmailDraftOutcomeUnknown;
        if (current_remote) |id| {
            try bounded.identifier(id);
            if (!std.mem.eql(u8, id, self.remoteMessageId) and !keep_local_after_change) return error.GmailDraftConflict;
        } else {
            self.phase = .missing;
            self.possiblySentElsewhere = true;
        }
        self.paused = false;
        self.sendAcknowledgedDigest = "";
        self.errorCode = "";
        try self.bump();
    }
    pub fn acknowledgeSend(self: *Link, a: std.mem.Allocator, payload_digest: []const u8) !void {
        if (self.paused) return error.DraftPausedInGmail;
        try digest(payload_digest);
        self.sendAcknowledgedDigest = try a.dupe(u8, payload_digest);
        try self.bump();
    }
    pub fn permitSend(self: Link, payload_digest: []const u8) !void {
        if (self.paused) return error.DraftPausedInGmail;
        if (self.phase == .rejected) return;
        if (!std.mem.eql(u8, payload_digest, self.sendAcknowledgedDigest)) return error.GmailCopyUnchecked;
    }
};
fn digest(value: []const u8) !void {
    if (value.len != 64) return error.InvalidDraftLink;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidDraftLink;
}
pub fn validate(links: []const Link) !void {
    if (links.len > limit) return error.DraftLinkLimitReached;
    for (links, 0..) |link, i| {
        try link.validate();
        for (links[0..i]) |previous| if (std.mem.eql(u8, previous.draftId, link.draftId)) return error.InvalidDraftLink;
    }
}
pub fn find(links: []const Link, draft_id: []const u8) ?usize {
    for (links, 0..) |link, i| if (std.mem.eql(u8, link.draftId, draft_id)) return i;
    return null;
}

test "Gmail draft link: uncertain upload stays paused and remote changes require an explicit choice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: [64]u8 = @splat('a');
    const edited: [64]u8 = @splat('b');
    var link: Link = .{ .draftId = "local", .attemptMessageId = "<owned-attempt@mail.invalid>", .uploadedDigest = &original };
    try link.validate();
    try std.testing.expectError(error.GmailDraftOutcomeUnknown, link.takeBack(1, null, false));
    try std.testing.expectError(error.DraftPausedInGmail, link.permitSend(&original));
    try link.applied(a, "remote-container", "remote-version-1", 10);
    try std.testing.expectError(error.GmailDraftChanged, link.takeBack(1, "remote-version-1", false));
    try std.testing.expectError(error.GmailDraftConflict, link.takeBack(2, "remote-version-2", false));
    try std.testing.expect(link.paused);
    try link.takeBack(2, "remote-version-2", true);
    try std.testing.expect(!link.paused);
    try std.testing.expectEqualStrings("remote-container", link.remoteDraftId);
    try std.testing.expectError(error.GmailCopyUnchecked, link.permitSend(&original));
    try link.acknowledgeSend(a, &original);
    try link.permitSend(&original);
    try std.testing.expectError(error.GmailCopyUnchecked, link.permitSend(&edited));
    try link.takeBack(link.version, null, false);
    try std.testing.expect(link.possiblySentElsewhere and link.phase == .missing);
    try std.testing.expectError(error.GmailCopyUnchecked, link.permitSend(&original));
}

pub fn contentDigest(a: std.mem.Allocator, draft: @import("types.zig").Draft, account: []const u8) ![64]u8 {
    const bytes = try @import("send_outcome.zig").payload(a, draft, account, null);
    defer a.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
