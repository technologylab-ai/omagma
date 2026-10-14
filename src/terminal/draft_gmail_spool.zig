//! Gmail drafts use exactly the native send renderer and bounded MIME spool.
//! Preparation finishes before the durable uncertain-create record is written.
const t = @import("types.zig");
const storage = @import("store.zig");
const mime = @import("mime.zig");
const recipients = @import("recipients.zig");
const spool = @import("send_spool.zig");

pub fn create(store: *storage.Store, draft: t.Draft, attempt: []const u8) !spool.Spool {
    try @import("draft_codec.zig").validateDraft(draft, false);
    if (draft.recoveryFields != null) return error.UnfinishedDraft;
    if (!mime.validMessageId(attempt)) return error.InvalidDraftLink;
    const a = store.allocator;
    const prepared = try @import("markdown_mail.zig").prepare(a, draft);
    var from: recipients.Mailbox = .{};
    const sender = draft.from orelse t.Address{ .address = store.state.account };
    try from.address.set(sender.address);
    try from.name.set(sender.name);
    var envelope: recipients.Envelope = .{};
    for ([_][]const t.Address{ draft.to, draft.cc, draft.bcc }, [_]*recipients.List{ &envelope.to, &envelope.cc, &envelope.bcc }) |addresses, target| for (addresses) |address| {
        var mailbox: recipients.Mailbox = .{};
        try mailbox.address.set(address.address);
        try mailbox.name.set(address.name);
        try target.append(mailbox);
    };
    return spool.create(store, .{
        .from = from,
        .envelope = &envelope,
        .allow_empty_recipients = true,
        .subject = draft.subject,
        .body = prepared.plain,
        .html = prepared.html,
        .inline_logo = prepared.html != null,
        .logo_offset = prepared.logoOffset,
        .message_id = attempt,
        .date = if (store.options.fixtures) "Mon, 05 Oct 2026 12:00:00 +0000" else try @import("gmail.zig").date(store.io, a, false),
        .in_reply_to = draft.inReplyTo,
        .references = draft.references,
    }, draft.attachments, prepared.resources);
}
