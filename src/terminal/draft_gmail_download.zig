//! Download a verified Gmail draft version into one atomic new local draft.
const std = @import("std");
const j = @import("json.zig");
const t = @import("types.zig");
const storage = @import("store.zig");
const remote = @import("draft_gmail.zig");
const links = @import("draft_link.zig");
const importer = @import("draft_gmail_import.zig");
const blob = @import("attachment_blob.zig");
const gmail = @import("gmail.zig");

pub fn run(s: anytype, a: std.mem.Allocator, account: []const u8, req: j.Value, network: ?*remote.Session, original: links.Link, loaded: importer.Loaded, fixture_source: bool) !t.Draft {
    const expected_message = try j.required(req, "expectedRemoteMessageId");
    if (!std.mem.eql(u8, expected_message, loaded.remote.messageId) or !std.mem.eql(u8, original.remoteDraftId, loaded.remote.draftId)) return error.GmailDraftChanged;
    try importer.attachmentBudget(loaded.draft.attachments);
    var store = try s.openStore(a, account, false);
    defer store.close();
    const source_index = links.find(store.state.draftLinks, original.draftId) orelse return error.GmailDraftNotLinked;
    try store.state.draftLinks[source_index].expectVersion(original.version);
    if (store.state.draftLinks.len == links.limit or store.state.drafts.len == 128) return error.DraftLimitExceeded;
    var incoming: [t.Limits.attachments + 1]blob.Incoming = undefined;
    var slots: [t.Limits.attachments + 1]?usize = @splat(null);
    var incoming_count: usize = 0;
    defer for (incoming[0..incoming_count]) |*item| item.close();
    var reservation: usize = 0;
    for (loaded.draft.attachments) |file| {
        if (fixture_source and file.blobId != null) continue;
        reservation += if (store.vault != null) try @import("vault_download.zig").Download.reservation(file.size) + try @import("vault_types.zig").sealedSize(file.size) else file.size;
    }
    if (store.vault != null) try store.reserveVaultCiphertext(reservation + try store.vaultIndexStagingBytes()) else try store.reserveBytes(reservation);
    for (loaded.draft.attachments, 0..) |file, index| {
        if (fixture_source and file.blobId != null) {
            // The synthetic remote snapshot borrows an immutable owned blob.
            // Verify it without opening a simultaneous encrypted writer.
            try blob.verify(&store, file);
            continue;
        }
        const target = &incoming[incoming_count];
        target.* = try blob.Incoming.create(&store, file.size);
        slots[index] = incoming_count;
        incoming_count += 1;
        store.release();
        var buffer: [16 * 1024]u8 = undefined;
        var writer = target.writer(&buffer);
        if (file.data.len != 0 or file.size == 0) {
            try gmail.writeAttachmentData(&writer.interface, file);
        } else {
            const session = network orelse return error.InvalidFixture;
            _ = try session.native.attachmentToWriter(a, expected_message, file, &writer.interface);
        }
        try writer.flush();
        // Finish releases the encrypted workspace pin. Keep the sealed spool
        // itself until the final remote check and atomic local publication.
        try target.finish(file.size);
        store.close();
        store = try s.openStore(a, account, false);
    }
    store.release();
    if (network) |session| {
        const current = try remote.status(a, session.transport(), original.remoteDraftId) orelse return error.GmailDraftChanged;
        if (!std.mem.eql(u8, current.messageId, expected_message)) return error.GmailDraftChanged;
    } else if (std.mem.eql(u8, s.options.fixture_scenario, "gmail-draft-import-race")) return error.GmailDraftChanged;
    store.close();
    store = try s.openStore(a, account, false);
    const fresh_index = links.find(store.state.draftLinks, original.draftId) orelse return error.GmailDraftNotLinked;
    try store.state.draftLinks[fresh_index].expectVersion(original.version);
    var files: std.ArrayList(t.Attachment) = .empty;
    var total: usize = 0;
    for (loaded.draft.attachments, 0..) |file, index| {
        var kept = if (slots[index]) |slot| try incoming[slot].commit(&store, file) else file;
        if (importer.isBranding(file, kept.blobId.?)) continue;
        total = std.math.add(usize, total, kept.size) catch return error.AttachmentsTooLarge;
        if (files.items.len == t.Limits.attachments or total > t.Limits.attachment_bytes) return error.GmailDraftImportUnsupported;
        kept.disposition = "attachment";
        kept.contentId = null;
        kept.contentLocation = null;
        try files.append(a, kept);
    }
    var draft = loaded.draft;
    draft.attachments = files.items;
    try @import("draft_codec.zig").validateDraft(draft, false);
    return store.putImportedDraft(draft, original.draftId, original.version, loaded.remote.messageId);
}
