//! Native send classification shared by providers. Only definite rejections
//! are safe to label rejected; an unclassified failure remains unconfirmed.
const std = @import("std");
const t = @import("types.zig");
/// Calendar identity is normalized by the caller, exactly as in the native
/// queue. Draft IDs and display-only metadata never change outbound identity.
fn canonicalValue(a: std.mem.Allocator, draft: t.Draft, account: []const u8) !std.json.Value {
    var canonical = draft;
    canonical.id = "";
    if (canonical.from) |sender| if (sender.name.len == 0 and std.ascii.eqlIgnoreCase(sender.address, account)) {
        canonical.from = null;
    };
    // Preserve the legacy outer calendar:null, but omit newly optional draft
    // fields so unchanged older uncertain operations keep their fingerprint.
    // The source lives through this synchronous encoding. Borrow its strings
    // instead of retaining a second JSON copy of every inline resource.
    var value = try @import("mail_response_value.zig").borrowed(a, canonical);
    _ = value.object.orderedRemove("summaryCounts");
    if (canonical.includeOriginal) _ = value.object.orderedRemove("includeOriginal");
    if (canonical.bodyFormat == .plain) _ = value.object.orderedRemove("bodyFormat");
    _ = value.object.orderedRemove("omittedAttachments");
    return value;
}
pub fn payload(a: std.mem.Allocator, draft: t.Draft, account: []const u8, calendar_identity: ?[]const u8) ![]const u8 {
    return @import("json.zig").encodeAlloc(a, .{ .draft = try canonicalValue(a, draft, account), .calendar = calendar_identity }, .{});
}
/// Hash exactly the existing operation payload without retaining its encoded
/// source or inline-resource bytes. Temporary JSON containers borrow the draft
/// only through this synchronous call and are released before returning.
pub fn digest(a: std.mem.Allocator, draft: t.Draft, account: []const u8, calendar_identity: ?[]const u8) ![64]u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const value = try canonicalValue(arena.allocator(), draft, account);
    var buffer: [4096]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buffer);
    try std.json.Stringify.value(.{ .draft = value, .calendar = calendar_identity }, .{}, &hashing.writer);
    try hashing.writer.flush();
    var hash: [32]u8 = undefined;
    hashing.hasher.final(&hash);
    return std.fmt.bytesToHex(hash, .lower);
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
    draft.summaryCounts = .{ .to = 500, .cc = 0, .bcc = 0, .attachments = 1040 };
    try std.testing.expectEqualStrings(literal, try payload(a, draft, "self@example.test", null));
    draft.bodyText = "Changed content";
    try std.testing.expect(!std.mem.eql(u8, literal, try payload(a, draft, "self@example.test", null)));
}

test "send outcome: optimized fingerprints retain exact legacy bytes for illustrated and recovered drafts" {
    const Legacy = struct {
        fn payload(a: std.mem.Allocator, input: t.Draft, account: []const u8, calendar: ?[]const u8) ![]const u8 {
            var canonical = input;
            canonical.id = "";
            if (canonical.from) |sender| if (sender.name.len == 0 and std.ascii.eqlIgnoreCase(sender.address, account)) {
                canonical.from = null;
            };
            const bytes = try std.json.Stringify.valueAlloc(a, canonical, .{ .emit_null_optional_fields = false });
            var value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_if_needed });
            if (canonical.includeOriginal) _ = value.object.orderedRemove("includeOriginal");
            if (canonical.bodyFormat == .plain) _ = value.object.orderedRemove("bodyFormat");
            _ = value.object.orderedRemove("omittedAttachments");
            return std.json.Stringify.valueAlloc(a, .{ .draft = value, .calendar = calendar }, .{});
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var draft: t.Draft = .{ .id = "saved-draft", .to = &.{.{ .address = "peer@example.test", .name = "Quoted \"Café\"" }}, .cc = &.{.{ .address = "copy@example.test", .name = "Copy\n\t" }}, .bcc = &.{.{ .address = "hidden@example.test" }}, .subject = "A\\B\tC", .bodyText = "**Authored**\n\nUnicode 👋\u{1f}", .attachments = &.{.{ .id = "blob", .filename = "stored.bin", .size = 4, .blobId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .contentLocation = "https://example.test/files/quoted?x=\"é\"" }}, .threadId = "thread", .inReplyTo = "<parent@example.test>", .references = "<parent@example.test>", .original = .{ .from = .{ .address = "sender@example.test" }, .bodyText = "Original\n", .bodyHtml = "<div title=\"café\">\n<img src=\"cid:image@example.test\"></div>", .resources = &.{.{ .id = "image", .filename = "quoted \"image\".png", .mimeType = "image/png", .size = 4, .data = "AP-AfQ", .contentId = "image@example.test", .disposition = "inline", .contentLocation = "images/source.png" }} } };
    for ([_]t.BodyFormat{ .plain, .markdown }) |format| {
        draft.bodyFormat = format;
        for ([_]?t.Address{ null, .{ .address = "SELF@example.test" }, .{ .address = "self@example.test", .name = "Named sender" }, .{ .address = "alias@example.test" } }) |from| {
            draft.from = from;
            for ([_]?[]const u8{ null, "calendar-identity\n\"quoted\"" }) |calendar| {
                const expected = try Legacy.payload(a, draft, "self@example.test", calendar);
                try std.testing.expectEqualStrings(expected, try payload(a, draft, "self@example.test", calendar));
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(expected, &hash, .{});
                try std.testing.expectEqualStrings(&std.fmt.bytesToHex(hash, .lower), &try digest(a, draft, "self@example.test", calendar));
                draft.recoveryFields = &.{ "partial", "", "", "Recovered", "**Source**\n" };
                draft.omittedAttachments = 3;
                try std.testing.expectEqualStrings(try Legacy.payload(a, draft, "self@example.test", calendar), try payload(a, draft, "self@example.test", calendar));
            }
        }
    }
}

test "send outcome: streaming digest preserves inclusion and multi-buffer escaped source bytes" {
    const a = std.testing.allocator;
    const source = try a.alloc(u8, 256 * 1024);
    defer a.free(source);
    for (source, 0..) |*byte, i| byte.* = "A\n\"\\"[i % 4];
    var draft: t.Draft = .{ .bodyText = source, .bodyFormat = .markdown, .original = .{ .from = .{ .address = "sender@example.test" }, .bodyText = "Original text" } };
    var included: [64]u8 = undefined;
    for ([_]bool{ true, false }) |include| {
        draft.includeOriginal = include;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const bytes = try payload(arena.allocator(), draft, "self@example.test", null);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        // A tiny workspace must hash the complete source: no body-sized JSON.
        var workspace: [16 * 1024]u8 = undefined;
        var bounded = std.heap.FixedBufferAllocator.init(&workspace);
        const actual = try digest(bounded.allocator(), draft, "self@example.test", null);
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(hash, .lower), &actual);
        if (include) included = actual else try std.testing.expect(!std.mem.eql(u8, &included, &actual));
    }
}

test "send outcome: streaming digest allocation failures release metadata and preserve source" {
    const Test = struct {
        const draft: t.Draft = .{ .id = "saved", .bodyText = "Retained source", .includeOriginal = false, .original = .{ .from = .{ .address = "sender@example.test" }, .bodyText = "Original" } };
        fn run(a: std.mem.Allocator, expected: [64]u8) !void {
            const actual = try digest(a, draft, "self@example.test", null);
            try std.testing.expectEqualStrings(&expected, &actual);
            try std.testing.expectEqualStrings("Retained source", draft.bodyText);
            try std.testing.expectEqualStrings("Original", draft.original.?.bodyText);
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try payload(arena.allocator(), Test.draft, "self@example.test", null);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Test.run, .{std.fmt.bytesToHex(hash, .lower)});
}
