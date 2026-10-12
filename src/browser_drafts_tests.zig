//! Browser persistence acceptance uses synthetic actors and an atomic memory
//! host. Imported by browser_provider_tests, whose HTTP ABI must stay unused.
const std = @import("std");
const Provider = @import("browser_provider.zig").Provider;
const storage = @import("browser_drafts.zig");
const codec = @import("terminal/draft_codec.zig");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const a = std.testing.allocator;
const account = "durable@example.test";
const client_id = "synthetic-drafts.apps.googleusercontent.com";
const grant_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const binding: storage.Binding = .{ .account = account, .clientId = client_id, .grantId = grant_id };
const Host = struct {
    raw: ?[]u8 = null,
    fail: bool = false,
    saves: usize = 0,
    fn deinit(self: *@This()) void {
        if (self.raw) |raw| a.free(raw);
    }
    fn save(ctx: ?*anyopaque, session: u32, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        try std.testing.expectEqual(@as(u32, 17), session);
        if (self.fail) return error.BrowserDraftStorageUnavailable;
        const next = try a.dupe(u8, bytes);
        if (self.raw) |raw| a.free(raw);
        self.raw = next;
        self.saves += 1;
    }
};
fn provider(host: ?*Host) Provider {
    var result = Provider.init(a);
    result.live_count = 1;
    result.live_sessions[0] = .{ .id = 17, .nonce = "12345678-1234-4234-8234-123456789abc", .account = account, .client_id = client_id, .grant_id = grant_id, .can_send = true, .can_contacts = false };
    if (host) |value| result.draft_store = .{ .context = value, .saveFn = Host.save };
    return result;
}
fn invoke(p: *Provider, out: std.mem.Allocator, request: anytype) !j.Value {
    return std.json.parseFromSliceLeaky(j.Value, out, try p.client().call(out, try std.json.Stringify.valueAlloc(out, request, .{})), .{ .allocate = .alloc_if_needed });
}
fn data(value: j.Value) !j.Value {
    try std.testing.expect(try j.boolean(value, "ok", false));
    return j.get(value, "data") orelse error.MissingData;
}
fn rejected(value: j.Value, name: []const u8) !void {
    try std.testing.expect(!try j.boolean(value, "ok", true));
    try std.testing.expectEqualStrings(name, j.text(j.get(value, "error").?, "code"));
}
fn create(p: *Provider, out: std.mem.Allocator, subject: []const u8) ![]const u8 {
    const result = try data(try invoke(p, out, .{ .cmd = "draft.create", .account = account, .draft = .{ .subject = subject, .bodyText = "Typed note", .bodyFormat = "markdown", .to = "peer@example.test" } }));
    return j.required(result, "id");
}
fn read(p: *Provider, out: std.mem.Allocator, id: []const u8) !j.Value {
    return data(try invoke(p, out, .{ .cmd = "draft.read", .account = account, .draftId = id }));
}
fn addOperation(out: std.mem.Allocator, raw: []const u8, phase: []const u8) ![]const u8 {
    var value = try std.json.parseFromSliceLeaky(j.Value, out, raw, .{ .allocate = .alloc_always });
    const id = j.text(j.get(value, "drafts").?.array.items[0], "id");
    try value.object.put(out, "operations", try j.value(out, .{.{ .id = "send-operation", .draftId = id, .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .phase = phase, .outcome = "unknown", .errorCode = "", .acknowledged = false }}));
    return std.json.Stringify.valueAlloc(out, value, .{});
}

test "browser durable drafts: raw recovery, format, original and file bytes survive a fresh provider" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const out = arena.allocator();
    var host: Host = .{};
    defer host.deinit();
    var first = provider(&host);
    defer first.deinit();
    const fields = [_][]const u8{ "Unfinished <recipient", "", "", "Frozen subject", "**My note**\n雪" };
    const original: t.Original = .{ .bodyHtml = "<p>Frozen original</p><img src=\"cid:logo\">", .resources = &.{.{ .id = "logo", .filename = "logo.png", .mimeType = "image/png", .size = 3, .data = "YWJj", .contentId = "logo" }} };
    const result = try data(try invoke(&first, out, .{ .cmd = "draft.recovery-save", .account = account, .draft = .{ .recoveryFields = fields, .bodyFormat = "markdown", .original = original, .attachments = [_]t.Attachment{.{ .id = "file", .filename = "file.txt", .mimeType = "text/plain", .size = 3, .data = "YWJj" }} } }));
    const id = j.text(result, "id");
    try std.testing.expectEqual(@as(usize, 1), host.saves);
    var restored = provider(null);
    defer restored.deinit();
    try restored.restoreDrafts(0, host.raw.?);
    const recovered = try codec.decodeDraftWithScratch(out, a, try read(&restored, out, id));
    try std.testing.expectEqualStrings(fields[0], recovered.recoveryFields.?[0]);
    try std.testing.expectEqualStrings(fields[4], recovered.recoveryFields.?[4]);
    try std.testing.expectEqual(t.BodyFormat.markdown, recovered.bodyFormat);
    try std.testing.expectEqualStrings(original.bodyHtml, recovered.original.?.bodyHtml);
    try std.testing.expectEqualStrings("YWJj", recovered.original.?.resources[0].data);
    try std.testing.expectEqualStrings("YWJj", recovered.attachments[0].data);
    try std.testing.expectError(error.UnfinishedDraft, codec.validateDraft(recovered, true));
    try std.testing.expectEqual(@as(usize, 1), restored.draftCount());
}

test "browser durable drafts: failed save and discard retain both prior memory and durable copy" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const out = arena.allocator();
    var host: Host = .{};
    defer host.deinit();
    var p = provider(&host);
    defer p.deinit();
    const id = try create(&p, out, "Saved subject");
    const previous = try out.dupe(u8, host.raw.?);
    const bytes = p.draft_bytes;
    host.fail = true;
    try rejected(try invoke(&p, out, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .subject = "New in-tab work", .bodyText = "Preserved by composer on failure" } }), "BrowserDraftStorageUnavailable");
    try std.testing.expectEqualStrings(previous, host.raw.?);
    try std.testing.expectEqualStrings("Saved subject", j.text(try read(&p, out, id), "subject"));
    try std.testing.expectEqual(bytes, p.draft_bytes);
    try rejected(try invoke(&p, out, .{ .cmd = "draft.discard", .account = account, .draftId = id }), "BrowserDraftStorageUnavailable");
    try std.testing.expectEqualStrings(previous, host.raw.?);
    try std.testing.expectEqual(@as(usize, 1), p.draftCount());
    host.fail = false;
    _ = try data(try invoke(&p, out, .{ .cmd = "draft.discard", .account = account, .draftId = id }));
    var restored = provider(null);
    defer restored.deinit();
    try restored.restoreDrafts(0, host.raw.?);
    try std.testing.expectEqual(@as(usize, 0), restored.draftCount());
}

test "browser durable drafts: fresh exact actor binding and whole-envelope validation precede replacement" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const out = arena.allocator();
    var host: Host = .{};
    defer host.deinit();
    var p = provider(&host);
    defer p.deinit();
    const id = try create(&p, out, "Keep me");
    for ([_]storage.Binding{
        .{ .account = "Durable@example.test", .clientId = client_id, .grantId = grant_id },
        .{ .account = account, .clientId = "other.apps.googleusercontent.com", .grantId = grant_id },
        .{ .account = account, .clientId = client_id, .grantId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    }) |other| try std.testing.expectError(error.InvalidBrowserDrafts, storage.decode(out, a, other, host.raw.?));
    var value = try std.json.parseFromSliceLeaky(j.Value, out, host.raw.?, .{ .allocate = .alloc_always });
    try value.object.put(out, "refreshToken", .{ .string = "synthetic-private" });
    try std.testing.expectError(error.UnknownField, p.restoreDrafts(0, try std.json.Stringify.valueAlloc(out, value, .{})));
    try std.testing.expectEqualStrings("Keep me", j.text(try read(&p, out, id), "subject"));
    var unverified = Provider.init(a);
    defer unverified.deinit();
    try std.testing.expectError(error.UnknownAccount, unverified.restoreDrafts(0, host.raw.?));
}

test "browser durable drafts: reload pauses countdowns and protects submitted unknown receipts without replay" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const out = arena.allocator();
    var host: Host = .{};
    defer host.deinit();
    var p = provider(&host);
    defer p.deinit();
    const id = try create(&p, out, "Awaiting send");
    const paused = try addOperation(out, host.raw.?, "paused");
    var paused_provider = provider(null);
    defer paused_provider.deinit();
    try paused_provider.restoreDrafts(0, paused);
    try std.testing.expect(paused_provider.pendingUnknown() == null);
    _ = try data(try invoke(&paused_provider, out, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = .{ .subject = "Needs fresh review" } }));
    var protected = provider(&host);
    defer protected.deinit();
    const submitted = try addOperation(out, host.raw.?, "submitted");
    try protected.restoreDrafts(0, submitted);
    try std.testing.expect(protected.pendingUnknown() != null);
    try std.testing.expectEqual(@as(u32, 2), protected.sendStatus());
    try rejected(try invoke(&protected, out, .{ .cmd = "draft.discard", .account = account, .draftId = id }), "UnknownOutcome");
    host.fail = true;
    try std.testing.expectError(error.BrowserDraftStorageUnavailable, protected.acknowledgeUnknown(0, id));
    try std.testing.expect(protected.pendingUnknown() != null);
    host.fail = false;
    try protected.acknowledgeUnknown(0, id);
    try std.testing.expect(protected.pendingUnknown() == null);
    var after_ack = provider(null);
    defer after_ack.deinit();
    try after_ack.restoreDrafts(0, host.raw.?);
    try std.testing.expect(after_ack.pendingUnknown() == null);
    try std.testing.expectEqual(@as(usize, 1), after_ack.draftCount());
}

test "browser durable drafts: eight-draft and whole-original quota refusal leave the saved record intact" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const out = arena.allocator();
    var host: Host = .{};
    defer host.deinit();
    var p = provider(&host);
    defer p.deinit();
    const id = try create(&p, out, "One");
    for (0..7) |_| _ = try create(&p, out, "Another bounded draft");
    const previous = try out.dupe(u8, host.raw.?);
    try rejected(try invoke(&p, out, .{ .cmd = "draft.create", .account = account, .draft = .{ .subject = "Ninth" } }), "BrowserDraftLimit");
    try std.testing.expectEqualStrings(previous, host.raw.?);
    const large = try out.alloc(u8, 1600000);
    @memset(large, 'x');
    const too_large: t.Draft = .{ .bodyText = large, .original = .{ .bodyText = large, .bodyHtml = "<p>Whole immutable source</p>" } };
    // request admission itself may be first to reject this combined envelope.
    const raw = try std.json.Stringify.valueAlloc(out, .{ .cmd = "draft.update", .account = account, .draftId = id, .draft = too_large }, .{});
    try std.testing.expectError(error.RequestTooLarge, p.client().call(out, raw));
    try std.testing.expectEqualStrings(previous, host.raw.?);
    try std.testing.expectEqual(@as(usize, 8), p.draftCount());
}

test "browser durable drafts: applied receipts retire a retained recovery on restore and cannot resend it" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const out = arena.allocator();
    var host: Host = .{};
    defer host.deinit();
    var first = provider(&host);
    defer first.deinit();
    const id = try create(&first, out, "Known sent recovery");
    const value = try std.json.parseFromSliceLeaky(j.Value, out, try addOperation(out, host.raw.?, "submitted"), .{ .allocate = .alloc_always });
    const operation = &j.get(value, "operations").?.array.items[0];
    try operation.object.put(out, "outcome", .{ .string = "applied" });
    var restored = provider(null);
    defer restored.deinit();
    try restored.restoreDrafts(0, try std.json.Stringify.valueAlloc(out, value, .{}));
    try std.testing.expectEqual(@as(usize, 0), restored.draftCount());
    try rejected(try invoke(&restored, out, .{ .cmd = "draft.read", .account = account, .draftId = id }), "DraftAlreadySent");
    try rejected(try invoke(&restored, out, .{ .cmd = "draft.send", .account = account, .draftId = id, .operationId = "must-not-resubmit" }), "DraftAlreadySent");
}
