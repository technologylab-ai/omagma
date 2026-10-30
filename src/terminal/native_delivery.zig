//! Store-backed, local-only delivery preview and canonical MIME materialization.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const delivery = @import("attachment_delivery.zig");
const markdown = @import("markdown_mail.zig");
const Store = @import("store.zig").Store;
const A = std.mem.Allocator;
pub const Materialized = struct { draft: t.Draft, prepared: markdown.Prepared };
pub fn materialize(a: A, draft: t.Draft, items: []const delivery.Item, ids: []const []const u8) !Materialized {
    var suffix = draft;
    suffix.bodyText = "";
    suffix.original = null;
    suffix.recoveryFields = null;
    suffix.bcc = &.{};
    const source = try delivery.wireDraft(a, suffix, items, ids);
    var wire = draft;
    wire.attachments = source.attachments;
    return .{ .draft = wire, .prepared = try markdown.prepareWithSuffix(a, wire, source.bodyText) };
}
const Counter = struct {
    store: *Store,
    message_id: []const u8 = "<omagma-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@mail.invalid>",
    fn count(ctx: *anyopaque, a: A, draft: t.Draft, items: []const delivery.Item) !usize {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        var temporary: std.heap.ArenaAllocator = .init(a);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        var ids: [delivery.max_drive_files][]const u8 = undefined;
        const placeholder: [256]u8 = @splat('x');
        var n: usize = 0;
        for (items) |item| if (item.delivery == .drive) {
            if (n == ids.len) return error.TooManyDriveFiles;
            ids[n] = &placeholder;
            n += 1;
        };
        const wire = try materialize(scratch, draft, items, ids[0..n]);
        return measure(scratch, self.store, wire, self.message_id);
    }
};
pub fn measure(a: A, store: *Store, wire: Materialized, message_id: []const u8) !usize {
    _ = a;
    const sender = wire.draft.from orelse t.Address{ .address = store.state.account };
    var from: @import("recipients.zig").Mailbox = .{};
    try from.address.set(sender.address);
    try from.name.set(sender.name);
    return @import("send_spool.zig").measure(store, .{
        .from = from,
        .destinations = .{ .to = wire.draft.to, .cc = wire.draft.cc, .bcc = wire.draft.bcc },
        .allow_empty_recipients = true,
        .subject = wire.draft.subject,
        .body = wire.prepared.plain,
        .html = wire.prepared.html,
        .inline_logo = wire.prepared.html != null,
        .logo_offset = wire.prepared.logoOffset,
        .message_id = message_id,
        .date = "Mon, 05 Oct 2026 12:00:00 +0000",
        .in_reply_to = wire.draft.inReplyTo,
        .references = wire.draft.references,
    }, wire.draft.attachments, wire.prepared.resources);
}
pub fn resolve(a: A, store: *Store, draft: t.Draft) !delivery.Plan {
    var counter: Counter = .{ .store = store };
    return delivery.resolve(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
}
pub fn preview(a: A, store: *Store, draft: t.Draft) !delivery.Plan {
    var counter: Counter = .{ .store = store };
    return delivery.preview(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
}
pub fn previewWithIdentity(a: A, store: *Store, draft: t.Draft, message_id: []const u8) !delivery.Plan {
    var counter: Counter = .{ .store = store, .message_id = message_id };
    return delivery.preview(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
}
pub fn requested(draft: t.Draft) bool {
    for (draft.attachments) |file| if (file.delivery != null and file.delivery.? != .attach) return true;
    return false;
}
pub fn value(a: A, draft: t.Draft, plan: delivery.Plan) !j.Value {
    var files: std.ArrayList(j.Value) = .empty;
    for (draft.attachments, plan.items) |file, item| try files.append(a, try j.value(a, .{
        .index = item.index,
        .filename = file.filename,
        .size = file.size,
        .mimeType = file.mimeType,
        .requestedDelivery = file.delivery orelse .attach,
        .delivery = item.delivery,
        .state = "planned",
        .reuse = "none",
        .newCopy = false,
        .sharedWith = [_][]const u8{},
    }));
    var blockers: std.ArrayList(j.Value) = .empty;
    if (plan.drive_count != 0 and draft.bcc.len != 0) try blockers.append(a, try j.value(a, .{ .code = "DriveWithBcc", .message = "Drive delivery can't be used with Bcc recipients." }));
    if (plan.drive_count != 0 and draft.to.len + draft.cc.len == 0) try blockers.append(a, try j.value(a, .{ .code = "DriveNoRecipients", .message = "Drive files need at least one To or Cc recipient." }));
    if (plan.attached_bytes > t.Limits.attachment_bytes) try blockers.append(a, try j.value(a, .{ .code = "AttachmentsTooLarge", .message = "Set large files to Auto or Drive." }));
    if (plan.mime_bytes > t.Limits.mime_upload_bytes) try blockers.append(a, try j.value(a, .{ .code = "MessageTooLarge", .message = "Set large files to Auto or Drive." }));
    if (plan.drive_count > delivery.max_drive_files) try blockers.append(a, try j.value(a, .{ .code = "TooManyDriveFiles", .message = "At most 16 Drive files per message." }));
    return j.value(a, .{
        .files = files.items,
        .attachedBytes = plan.attached_bytes,
        .mimeBytes = plan.mime_bytes,
        .mimeEstimate = plan.drive_count != 0 or plan.estimated,
        .driveFileCount = plan.drive_count,
        .driveFileLimit = delivery.max_drive_files,
        .decodedLimitBytes = t.Limits.attachment_bytes,
        .mimeLimitBytes = t.Limits.mime_upload_bytes,
        .blockers = blockers.items,
    });
}

pub fn valueWithStore(a: A, store: *Store, draft: t.Draft, plan: delivery.Plan, operation_id: []const u8) !j.Value {
    var result = try value(a, draft, plan);
    if (plan.drive_count == 0) return result;
    const prepare = @import("drive_prepare.zig");
    const book = try prepare.Book.load(a, store);
    var recipients_draft = draft;
    recipients_draft.bcc = &.{};
    const recipients = prepare.recipientSet(a, recipients_draft) catch &.{};
    var recipient_hash: ?[64]u8 = null;
    if (recipients.len != 0) recipient_hash = Store.hash(try j.encodeAlloc(a, recipients, .{}));
    const entries = result.object.getPtr("files").?;
    for (plan.items) |item| {
        if (item.delivery != .drive) continue;
        const info = try book.reuse(a, draft.attachments[item.index], if (recipient_hash) |*hash| hash else null, operation_id, item.index);
        var entry = &entries.array.items[item.index];
        try entry.object.put(a, "reuse", .{ .string = info.kind });
        try entry.object.put(a, "newCopy", .{ .bool = info.newCopy });
        try entry.object.put(a, "sharedWith", try j.value(a, info.sharedWith));
    }
    return result;
}
