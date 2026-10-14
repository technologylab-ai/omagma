//! Explicit local-to-Gmail handoff. The Store lock is never held over a
//! provider request, and the durable unknown fence is written before upload.
const std = @import("std");
const j = @import("json.zig");
const t = @import("types.zig");
const links = @import("draft_link.zig");
const remote = @import("draft_gmail.zig");
const storage = @import("store.zig");
const auth = @import("auth.zig");
const fixtures_document = "fixture-gmail-drafts.json";
const FixtureRecord = struct { id: []const u8, messageId: []const u8, attempt: []const u8, draft: ?t.Draft = null };
const FixtureState = struct { account: []const u8, drafts: []FixtureRecord = &.{}, uploads: u64 = 0 };

fn scenario(s: anytype, value: []const u8) bool {
    return std.mem.eql(u8, s.options.fixture_scenario, value);
}
fn gate(s: anytype, a: std.mem.Allocator, account: []const u8, req: j.Value) !void {
    if (try j.boolean(req, "cacheOnly", false) or try j.boolean(req, "barGrantOnly", false) or try j.boolean(req, "auto", false)) return error.PermissionDenied;
    if (s.options.fixtures) {
        if (scenario(s, "readonly")) return error.PermissionDenied;
        if (scenario(s, "offline-refresh")) return error.TransientFailure;
        return;
    }
    const registry = try auth.loadConfigured(s.io, a, &s.config, if (s.config.credential_store == .vault) "" else try j.required(req, "grantFile"));
    const grant = auth.find(&registry, account) orelse return error.PermissionDenied;
    if (!grant.permits("mail-drafts") and !grant.permits("mail-modify")) return error.PermissionDenied;
}
fn expectedVersion(req: j.Value) !u64 {
    const value = try j.integer(req, "expectedVersion", -1);
    if (value < 0) return error.GmailDraftVersionRequired;
    return @intCast(value);
}
fn find(store: *storage.Store, id: []const u8) !*links.Link {
    return &store.state.draftLinks[links.find(store.state.draftLinks, id) orelse return error.GmailDraftNotLinked];
}
fn ensureDraftIdle(store: *storage.Store, id: []const u8) !void {
    for (store.state.sendQueue) |entry| if (std.mem.eql(u8, entry.draftId, id)) switch (entry.state) {
        .queued => return error.DraftQueued,
        .submitting, .unknown => return error.UnknownOutcome,
        else => {},
    };
    for (store.state.operations) |entry| if (std.mem.eql(u8, entry.draftId, id) and std.mem.eql(u8, entry.outcome, "unknown")) return error.UnknownOutcome;
}
fn reopen(s: anytype, a: std.mem.Allocator, store: *storage.Store, account: []const u8) !void {
    store.close();
    store.* = try s.openStore(a, account, false);
}
fn fixtureRead(store: *storage.Store, a: std.mem.Allocator) !FixtureState {
    const bytes = try store.readDocument(a, fixtures_document, 512 * 1024) orelse return .{ .account = store.state.account };
    const state = try std.json.parseFromSliceLeaky(FixtureState, a, bytes, .{});
    if (!std.mem.eql(u8, state.account, store.state.account) or state.drafts.len > links.limit) return error.InvalidFixture;
    for (state.drafts) |item| {
        try @import("../bounded.zig").identifier(item.id);
        try @import("../bounded.zig").identifier(item.messageId);
        if (!@import("mime.zig").validMessageId(item.attempt)) return error.InvalidFixture;
    }
    return state;
}
fn fixtureCreate(s: anytype, a: std.mem.Allocator, account: []const u8, attempt: []const u8, draft: t.Draft, source: *const @import("send_spool.zig").Spool) !remote.Remote {
    // Consume the complete verified stream just as the HTTP adapter does.
    {
        var reader = try source.reader();
        defer reader.close();
        var buffer: [16 * 1024]u8 = undefined;
        while (try @import("send_spool.zig").Spool.Reader.read(&reader, &buffer) != 0) try s.io.checkCancel();
    }
    if (scenario(s, "gmail-draft-rejected")) return error.ProviderRejected;
    if (scenario(s, "gmail-draft-unknown-missing")) return error.UnknownOutcome;
    var store = try s.openStore(a, account, false);
    defer store.close();
    var state = try fixtureRead(&store, a);
    if (state.drafts.len == links.limit) return error.DraftLinkLimitReached;
    const hash = storage.Store.hash(attempt);
    const id = try std.fmt.allocPrint(a, "gmail-draft-{s}", .{hash[0..32]});
    const message_id = try std.fmt.allocPrint(a, "gmail-message-{s}", .{hash[0..32]});
    const records = try a.alloc(FixtureRecord, state.drafts.len + 1);
    @memcpy(records[0..state.drafts.len], state.drafts);
    var snapshot = draft;
    const prepared = try @import("markdown_mail.zig").prepare(a, draft);
    snapshot.bodyText = prepared.plain;
    snapshot.bodyFormat = .plain;
    var files: std.ArrayList(t.Attachment) = .empty;
    try files.appendSlice(a, draft.attachments);
    if (draft.original) |original| try files.appendSlice(a, original.resources);
    snapshot.attachments = files.items;
    snapshot.original = null;
    snapshot.recoveryFields = null;
    records[state.drafts.len] = .{ .id = id, .messageId = message_id, .attempt = try a.dupe(u8, attempt), .draft = snapshot };
    state.drafts = records;
    state.uploads += 1;
    try store.writeDocument(fixtures_document, try j.encodeAlloc(a, state, .{}));
    if (scenario(s, "gmail-draft-unknown")) return error.UnknownOutcome;
    return .{ .draftId = id, .messageId = message_id, .rfcMessageId = attempt };
}
fn fixtureStatus(s: anytype, a: std.mem.Allocator, account: []const u8, link: links.Link) !?remote.Remote {
    if (scenario(s, "gmail-draft-missing")) return null;
    var store = try s.openStore(a, account, true);
    defer store.close();
    const state = try fixtureRead(&store, a);
    for (state.drafts) |item| if (std.mem.eql(u8, item.id, link.remoteDraftId) or (link.phase == .unknown and std.mem.eql(u8, item.attempt, link.attemptMessageId))) {
        return .{ .draftId = item.id, .messageId = if (scenario(s, "gmail-draft-conflict")) try std.fmt.allocPrint(a, "{s}-edited", .{item.messageId}) else item.messageId, .rfcMessageId = item.attempt };
    };
    return null;
}
fn fixtureLoad(s: anytype, a: std.mem.Allocator, account: []const u8, link: links.Link, expected_message: []const u8) !@import("draft_gmail_import.zig").Loaded {
    const current = try fixtureStatus(s, a, account, link) orelse return error.GmailDraftChanged;
    if (!std.mem.eql(u8, current.messageId, expected_message)) return error.GmailDraftChanged;
    var store = try s.openStore(a, account, true);
    defer store.close();
    const state = try fixtureRead(&store, a);
    for (state.drafts) |item| if (std.mem.eql(u8, item.id, current.draftId)) {
        var draft = item.draft orelse return error.GmailDraftImportUnsupported;
        if (scenario(s, "gmail-draft-conflict")) draft.bodyText = try std.fmt.allocPrint(a, "Edited in Gmail\n\n{s}", .{draft.bodyText});
        return .{ .remote = current, .draft = draft };
    };
    return error.GmailDraftChanged;
}
fn response(a: std.mem.Allocator, draft: t.Draft, account: []const u8, link: ?links.Link, outcome: []const u8, got: ?remote.Remote) !j.Value {
    const digest = try links.contentDigest(a, draft, account);
    return j.value(a, .{ .draftId = draft.id, .contentDigest = digest[0..], .link = link, .outcome = outcome, .remote = got, .remoteChanged = if (link) |selected| if (got) |value| !std.mem.eql(u8, selected.remoteMessageId, value.messageId) else false else false, .remoteMissing = got == null and !std.mem.eql(u8, outcome, "local") });
}
/// Called while the account is locked, both when staging and immediately before
/// sending. The acknowledgement belongs to exactly the reviewed content.
pub fn permitSend(store: *storage.Store, a: std.mem.Allocator, req: j.Value, draft: t.Draft, digest: []const u8) !void {
    const index = links.find(store.state.draftLinks, draft.id) orelse return;
    const link = &store.state.draftLinks[index];
    if (try j.boolean(req, "acknowledgeGmailCopy", false)) {
        if (!std.mem.eql(u8, j.text(req, "gmailCopyDigest"), digest)) return error.DraftChanged;
        try link.acknowledgeSend(a, digest);
        try store.save();
    }
    try link.permitSend(digest);
}
pub fn readResponse(a: std.mem.Allocator, store: *storage.Store, draft: t.Draft) !j.Value {
    var value = try j.value(a, draft);
    const digest = try links.contentDigest(a, draft, store.state.account);
    try value.object.put(a, "contentDigest", .{ .string = try a.dupe(u8, &digest) });
    if (links.find(store.state.draftLinks, draft.id)) |index| try value.object.put(a, "gmailLink", try j.value(a, store.state.draftLinks[index]));
    return value;
}
pub fn run(s: anytype, a: std.mem.Allocator, account: []const u8, req: j.Value) !j.Value {
    const cmd = j.text(req, "cmd");
    const id = try j.required(req, "draftId");
    try @import("../bounded.zig").identifier(id);
    if (std.mem.eql(u8, cmd, "draft.gmail-info")) {
        var store = try s.openStore(a, account, true);
        defer store.close();
        const draft = try store.draft(id);
        return response(a, draft, account, if (links.find(store.state.draftLinks, id)) |index| store.state.draftLinks[index] else null, "local", null);
    }
    const creating = std.mem.eql(u8, cmd, "draft.gmail-save");
    const taking_back = std.mem.eql(u8, cmd, "draft.gmail-take-back");
    const importing = std.mem.eql(u8, cmd, "draft.gmail-import");
    if (!creating and !taking_back and !importing and !std.mem.eql(u8, cmd, "draft.gmail-status")) return error.UnsupportedCommand;
    const expected = try expectedVersion(req);
    try gate(s, a, account, req);
    var network: remote.Session = undefined;
    if (!s.options.fixtures) try network.init(s.io, a, s.allocator, &s.config, account, req);
    defer if (!s.options.fixtures) network.close();
    var store = try s.openStore(a, account, false);
    defer store.close();
    var draft = try store.draft(id);
    if (creating) {
        try ensureDraftIdle(&store, id);
        const previous = if (links.find(store.state.draftLinks, id)) |index| store.state.draftLinks[index] else null;
        if (expected != (if (previous) |link| link.version else @as(u64, 0))) return error.GmailDraftChanged;
        if (previous) |link| {
            if (link.phase == .unknown) return error.GmailDraftOutcomeUnknown;
            if (link.phase != .rejected) return error.GmailDraftAlreadyLinked;
        } else if (store.state.draftLinks.len == links.limit) return error.DraftLinkLimitReached;
        const digest = try links.contentDigest(a, draft, account);
        if (!std.mem.eql(u8, try j.required(req, "expectedDigest"), &digest)) return error.DraftChanged;
        if (!s.options.fixtures) {
            store.release();
            try network.validateSender(a, draft);
            try reopen(s, a, &store, account);
            draft = try store.draft(id);
            if (!std.mem.eql(u8, &digest, &(try links.contentDigest(a, draft, account)))) return error.DraftChanged;
            const current = if (links.find(store.state.draftLinks, id)) |index| store.state.draftLinks[index].version else 0;
            if (current != expected) return error.GmailDraftChanged;
            try ensureDraftIdle(&store, id);
        } else if (draft.from) |from| if (!std.ascii.eqlIgnoreCase(from.address, account)) return error.UnverifiedSender;
        const attempt_id = try store.nextId("gmail-upload");
        const identity = storage.Store.hash(try std.fmt.allocPrint(a, "{s}\x00{s}", .{ account, attempt_id }));
        const attempt = try std.fmt.allocPrint(a, "<omagma-draft-{s}@mail.invalid>", .{identity});
        var source: ?@import("send_spool.zig").Spool = try @import("draft_gmail_spool.zig").create(&store, draft, attempt);
        defer if (source) |*spooled| spooled.close();
        var link: links.Link = .{ .draftId = try a.dupe(u8, id), .attemptMessageId = attempt, .uploadedDigest = try a.dupe(u8, &digest), .version = std.math.add(u64, expected, 1) catch return error.DraftLinkLimitReached };
        if (links.find(store.state.draftLinks, id)) |index| store.state.draftLinks[index] = link else {
            const new_links = try a.alloc(links.Link, store.state.draftLinks.len + 1);
            @memcpy(new_links[0..store.state.draftLinks.len], store.state.draftLinks);
            new_links[store.state.draftLinks.len] = link;
            store.state.draftLinks = new_links;
        }
        try store.save(); // durable fence: after this, a crash leaves edits paused
        store.release();
        var failure: ?anyerror = null;
        const receipt: ?remote.Remote = (if (s.options.fixtures) fixtureCreate(s, a, account, attempt, draft, &source.?) else network.create(a, draft, &source.?)) catch |err| blk: {
            failure = err;
            break :blk null;
        };
        source.?.close();
        source = null;
        reopen(s, a, &store, account) catch return error.UnknownOutcome;
        const retained = find(&store, id) catch return error.UnknownOutcome;
        if (retained.version != link.version or !std.mem.eql(u8, retained.attemptMessageId, attempt)) return error.UnknownOutcome;
        if (receipt) |got| {
            link.applied(a, got.draftId, got.messageId, std.Io.Timestamp.now(s.io, .real).toMilliseconds()) catch return error.UnknownOutcome;
        } else if (@import("send_outcome.zig").rejected(failure.?)) {
            try link.rejected(a, @errorName(failure.?));
        } else link.errorCode = try a.dupe(u8, @errorName(failure.?));
        retained.* = link;
        store.save() catch return error.UnknownOutcome;
        return response(a, draft, account, link, @tagName(link.phase), receipt);
    }
    const original = (try find(&store, id)).*;
    try original.expectVersion(expected);
    if (original.phase == .rejected) return error.GmailDraftNotLinked;
    store.release();
    if (importing) {
        if (original.phase == .unknown) return error.GmailDraftOutcomeUnknown;
        const expected_message = try j.required(req, "expectedRemoteMessageId");
        const loaded = if (s.options.fixtures) try fixtureLoad(s, a, account, original, expected_message) else try @import("draft_gmail_import.zig").load(a, account, network.transport(), original.remoteDraftId, expected_message);
        const imported_draft = try @import("draft_gmail_download.zig").run(s, a, account, req, if (s.options.fixtures) null else &network, original, loaded, s.options.fixtures);
        try reopen(s, a, &store, account);
        const retained = (try find(&store, id)).*;
        var value = try response(a, draft, account, retained, "imported", loaded.remote);
        try value.object.put(a, "importedDraftId", .{ .string = imported_draft.id });
        return value;
    }
    var result: remote.Reconciled = undefined;
    if (s.options.fixtures) {
        const got = try fixtureStatus(s, a, account, original);
        result = if (got) |value| .{ .state = .found, .remote = value } else .{ .state = .not_found };
    } else if (original.phase == .unknown) {
        result = try remote.reconcile(a, network.transport(), original.attemptMessageId);
    } else {
        const got = try remote.status(a, network.transport(), original.remoteDraftId);
        result = if (got) |value| .{ .state = .found, .remote = value } else .{ .state = .not_found };
    }
    try reopen(s, a, &store, account);
    const link = try find(&store, id);
    try link.expectVersion(expected);
    draft = try store.draft(id);
    if (original.phase == .unknown) {
        if (result.state == .found) {
            try link.applied(a, result.remote.?.draftId, result.remote.?.messageId, std.Io.Timestamp.now(s.io, .real).toMilliseconds());
            try store.save();
        }
        // Search absence is never proof that the create failed. Even a
        // takeback request can only reconcile here; repeat an explicit choice.
        return response(a, draft, account, link.*, if (result.state == .found) "linked" else if (result.state == .ambiguous) "ambiguous" else "unknown", result.remote);
    }
    if (taking_back) {
        try ensureDraftIdle(&store, id);
        const keep_changed = try j.boolean(req, "keepLocalAfterChange", false);
        if (result.remote) |got| {
            if (keep_changed and !std.mem.eql(u8, j.text(req, "expectedRemoteMessageId"), got.messageId)) return error.GmailDraftChanged;
        } else if (!try j.boolean(req, "acknowledgeMissingCopy", false)) return error.GmailDraftMissing;
        try link.takeBack(expected, if (result.remote) |got| got.messageId else null, keep_changed);
        try store.save();
        return response(a, draft, account, link.*, "local", result.remote);
    }
    return response(a, draft, account, link.*, if (result.remote == null) "missing" else if (!std.mem.eql(u8, result.remote.?.messageId, original.remoteMessageId)) "changed" else "linked", result.remote);
}
