//! Native send classification shared by providers. Only definite rejections
//! are safe to label rejected; an unclassified failure remains unconfirmed.
const std = @import("std");
const t = @import("types.zig");
/// Calendar identity is normalized by the caller, exactly as in the native
/// queue. Draft IDs and display-only metadata never change outbound identity.
pub fn payload(a: std.mem.Allocator, draft: t.Draft, account: []const u8, calendar_identity: ?[]const u8) ![]const u8 {
    var canonical = draft;
    canonical.id = "";
    if (canonical.from) |sender| if (sender.name.len == 0 and std.ascii.eqlIgnoreCase(sender.address, account)) {
        canonical.from = null;
    };
    // Preserve the legacy outer calendar:null, but omit newly optional draft
    // fields so unchanged older uncertain operations keep their fingerprint.
    const bytes = try std.json.Stringify.valueAlloc(a, canonical, .{ .emit_null_optional_fields = false });
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_if_needed });
    if (canonical.bodyFormat == .plain) _ = value.object.orderedRemove("bodyFormat");
    _ = value.object.orderedRemove("omittedAttachments");
    return std.json.Stringify.valueAlloc(a, .{ .draft = value, .calendar = calendar_identity }, .{});
}
pub fn rejected(err: anyerror) bool {
    return switch (err) {
        error.UnverifiedSender, error.FormTooLarge, error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.OAuthClientRequired, error.WrongAccount, error.InvalidGrant, error.UnexpectedScope, error.GrantClientMismatch, error.MessageNotFound, error.ContactConflict, error.RateLimited, error.SendCanceledBeforeSubmission => true,
        else => false,
    };
}
test "send outcome: only definite native rejections permit a reviewed retry" {
    for ([_]anyerror{ error.UnverifiedSender, error.FormTooLarge, error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.OAuthClientRequired, error.WrongAccount, error.InvalidGrant, error.UnexpectedScope, error.GrantClientMismatch, error.MessageNotFound, error.ContactConflict, error.RateLimited, error.SendCanceledBeforeSubmission }) |err| try std.testing.expect(rejected(err));
    for ([_]anyerror{ error.OutOfMemory, error.Timeout, error.Canceled, error.NetworkFailure, error.UnknownOutcome, error.InvalidProviderResponse }) |err| try std.testing.expect(!rejected(err));
}
test "send outcome: content identity excludes draft IDs no-op sender and omission warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var draft: t.Draft = .{ .id = "first", .to = &.{.{ .address = "peer@example.test" }}, .subject = "Hi", .bodyText = "Body" };
    const literal = "{\"draft\":{\"id\":\"\",\"to\":[{\"address\":\"peer@example.test\",\"name\":\"\"}],\"cc\":[],\"bcc\":[],\"subject\":\"Hi\",\"bodyText\":\"Body\",\"threadId\":\"\",\"inReplyTo\":\"\",\"references\":\"\",\"attachments\":[]},\"calendar\":null}";
    try std.testing.expectEqualStrings(literal, try payload(a, draft, "self@example.test", null));
    draft.id = "another-draft";
    draft.from = .{ .address = "SELF@example.test" };
    draft.omittedAttachments = 2;
    try std.testing.expectEqualStrings(literal, try payload(a, draft, "self@example.test", null));
    draft.bodyText = "Changed content";
    try std.testing.expect(!std.mem.eql(u8, literal, try payload(a, draft, "self@example.test", null)));
}
