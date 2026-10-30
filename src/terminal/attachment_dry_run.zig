//! Local metadata-only attachment planning. No session, cache, credentials,
//! immutable imports or network are initialized. MIME is explicitly estimated.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const mime = @import("mime.zig");
const files = @import("files.zig");
const delivery = @import("attachment_delivery.zig");
const native = @import("native_delivery.zig");
const A = std.mem.Allocator;
const Zeros = struct {
    remaining: usize,
    fn read(ctx: *anyopaque, buffer: []u8) !usize {
        const self: *Zeros = @ptrCast(@alignCast(ctx));
        const n = @min(buffer.len, self.remaining);
        @memset(buffer[0..n], 0);
        self.remaining -= n;
        return n;
    }
};
const Counter = struct {
    account: []const u8,
    fn count(ctx: *anyopaque, a: A, draft: t.Draft, items: []const delivery.Item) !usize {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        var temporary: std.heap.ArenaAllocator = .init(a);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const placeholder: [256]u8 = @splat('x');
        var ids: [delivery.max_drive_files][]const u8 = undefined;
        var n: usize = 0;
        for (items) |item| if (item.delivery == .drive) {
            ids[n] = &placeholder;
            n += 1;
        };
        const wire = try native.materialize(scratch, draft, items, ids[0..n]);
        const ordinary = wire.draft.attachments;
        const resources = wire.prepared.resources;
        const parts = try scratch.alloc(mime.Attachment, ordinary.len + resources.len);
        const sources = try scratch.alloc(Zeros, parts.len);
        var cursor: usize = 0;
        for ([_][]const t.Attachment{ ordinary, resources }) |list| for (list) |file| {
            const part = &parts[cursor];
            const source = &sources[cursor];
            cursor += 1;
            if (file.blobId != null) {
                source.* = .{ .remaining = file.size };
                // A metadata-only estimate cannot inspect message/rfc822
                // identity streams. Base64 is a conservative size alternative.
                part.* = .{ .filename = file.filename, .mime_type = if (std.ascii.startsWithIgnoreCase(file.mimeType, "message/")) "application/octet-stream" else file.mimeType, .size = file.size, .content_id = if (file.contentId) |value| try mime.contentId(value) else "", .disposition = file.disposition orelse "", .content_location = file.contentLocation orelse "", .source = .{ .ctx = source, .readFn = Zeros.read } };
            } else part.* = (try mime.composeAttachments(&.{file}, scratch))[0];
        };
        var from: @import("recipients.zig").Mailbox = .{};
        const sender = wire.draft.from orelse t.Address{ .address = self.account };
        try from.address.set(sender.address);
        try from.name.set(sender.name);
        var buffer: [32 * 1024]u8 = undefined;
        var sink = std.Io.Writer.Discarding.init(&buffer);
        try mime.measureTo(.{ .from = from, .destinations = .{ .to = draft.to, .cc = draft.cc, .bcc = draft.bcc }, .allow_empty_recipients = true, .subject = draft.subject, .body = wire.prepared.plain, .html = wire.prepared.html, .inline_logo = wire.prepared.html != null, .logo_offset = wire.prepared.logoOffset, .message_id = "<omagma-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@mail.invalid>", .date = "Mon, 05 Oct 2026 12:00:00 +0000", .in_reply_to = draft.inReplyTo, .references = draft.references, .attachments = parts[0..ordinary.len], .related = parts[ordinary.len..] }, &sink.writer);
        return @intCast(sink.fullCount());
    }
};
const placeholder_handle = "0000000000000000000000000000000000000000000000000000000000000000";
pub fn appendLocalFiles(io: std.Io, a: A, draft: t.Draft, paths: []const []const u8, methods: []const ?t.AttachmentDelivery) !t.Draft {
    if (paths.len != methods.len or paths.len > t.Limits.attachments -| draft.attachments.len) return error.TooManyAttachments;
    const selected = try a.alloc(t.Attachment, draft.attachments.len + paths.len);
    @memcpy(selected[0..draft.attachments.len], draft.attachments);
    for (paths, methods, selected[draft.attachments.len..], 0..) |path, method, *file, index| {
        const input = try files.openRegular(io, a, .cwd(), path);
        defer input.close(io);
        const stat = try input.stat(io);
        if (stat.size > delivery.max_file_bytes) return error.AttachmentsTooLarge;
        const filename = std.fs.path.basename(path);
        try mime.validateAttachment(filename, "application/octet-stream");
        file.* = .{ .id = try std.fmt.allocPrint(a, "dry-run-file-{d}", .{index}), .filename = filename, .size = @intCast(stat.size), .blobId = placeholder_handle, .delivery = method };
    }
    var result = draft;
    result.attachments = selected;
    return result;
}
pub fn estimate(a: A, account: []const u8, draft: t.Draft) !delivery.Plan {
    var counter: Counter = .{ .account = account };
    var plan = try delivery.preview(a, draft, .{ .ctx = &counter, .countFn = Counter.count });
    plan.estimated = true;
    return plan;
}
pub fn selection(io: std.Io, a: A, account: []const u8, input: t.Draft, paths: []const []const u8, method: t.AttachmentDelivery) !j.Value {
    const start = input.attachments.len;
    const methods = try a.alloc(?t.AttachmentDelivery, paths.len);
    @memset(methods, method);
    const draft = try appendLocalFiles(io, a, input, paths, methods);
    const plan = try estimate(a, account, draft);
    var attached_draft = draft;
    const attached = try a.dupe(t.Attachment, draft.attachments);
    for (attached[start..]) |*file| file.delivery = .attach;
    attached_draft.attachments = attached;
    const attached_plan = if (method == .attach) plan else try estimate(a, account, attached_draft);
    var selected_attached: usize = 0;
    var selected_attached_bytes: usize = 0;
    var selected_drive: usize = 0;
    var selected_drive_bytes: usize = 0;
    for (plan.items[start..]) |item| {
        if (item.delivery == .drive) {
            selected_drive += 1;
            selected_drive_bytes += draft.attachments[item.index].size;
        } else {
            selected_attached += 1;
            selected_attached_bytes += draft.attachments[item.index].size;
        }
    }
    var result = try native.value(a, draft, plan);
    try result.object.put(a, "selectedStart", .{ .integer = @intCast(start) });
    try result.object.put(a, "selectedAttachedCount", .{ .integer = @intCast(selected_attached) });
    try result.object.put(a, "selectedAttachedBytes", .{ .integer = @intCast(selected_attached_bytes) });
    try result.object.put(a, "selectedDriveCount", .{ .integer = @intCast(selected_drive) });
    try result.object.put(a, "selectedDriveBytes", .{ .integer = @intCast(selected_drive_bytes) });
    try result.object.put(a, "selectionOverLimit", .{ .bool = attached_plan.attached_bytes > t.Limits.attachment_bytes or attached_plan.mime_bytes > t.Limits.mime_upload_bytes });
    return result;
}
pub fn run(io: std.Io, a: A, request: j.Value, paths: []const []const u8, deliveries: []const ?t.AttachmentDelivery) ![]const u8 {
    if (!t.Limits.native) return error.UnsupportedAttachmentDelivery;
    if (paths.len != deliveries.len or paths.len > t.Limits.attachments) return error.InvalidAttachmentDelivery;
    const account = try j.required(request, "account");
    try @import("recipients.zig").validateAddress(account);
    var draft = try @import("draft_codec.zig").decodeDraft(a, j.get(request, "draft") orelse return error.MissingField);
    if (paths.len != 0 and draft.attachments.len != 0) return error.ConflictingDraftOptions;
    for (draft.attachments) |file| if (file.blobId != null) return error.DryRunRequiresLocalFiles;
    if (draft.original) |original| for (original.resources) |file| if (file.blobId != null) return error.DryRunRequiresLocalFiles;
    if (paths.len != 0) draft = try appendLocalFiles(io, a, draft, paths, deliveries);
    try @import("draft_codec.zig").validateDraft(draft, false);
    const plan = try estimate(a, account, draft);
    var result = try native.value(a, draft, plan);
    try result.object.put(a, "dryRun", .{ .bool = true });
    try result.object.put(a, "mimeEstimate", .{ .bool = true });
    try result.object.put(a, "account", .{ .string = account });
    const blockers = j.get(result, "blockers").?;
    const blocked = blockers.array.items.len != 0;
    try result.object.put(a, "status", .{ .string = if (blocked) "blocked" else "planned" });
    return j.encodeAlloc(a, .{ .version = @as(u8, 1), .id = j.get(request, "id") orelse .null, .ok = !blocked, .account = account, .data = result }, .{});
}

test "attachment delivery: dry run plans multiple large local files without creating cache or blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const source = try tmp.dir.createFile(std.testing.io, "large.bin", .{});
    defer source.close(std.testing.io);
    try source.setLength(std.testing.io, 30 * 1024 * 1024);
    const small = try tmp.dir.createFile(std.testing.io, "small.txt", .{});
    defer small.close(std.testing.io);
    try small.writeStreamingAll(std.testing.io, "small");
    const paths = [_][]const u8{ try std.fmt.allocPrint(a, "{s}/large.bin", .{base}), try std.fmt.allocPrint(a, "{s}/small.txt", .{base}) };
    // Use the actual backend DTO with the frontend parser, including the raw
    // selection plan shape (not only hand-written wrapped fixture objects).
    for ([_]t.AttachmentDelivery{ .attach, .auto }) |method| {
        const raw_plan = try selection(std.testing.io, a, "self@example.test", .{ .to = &.{.{ .address = "peer@example.test" }} }, paths[0..1], method);
        var displayed: @import("delivery_view.zig").Plan = .{};
        try @import("delivery_view.zig").parseSelection(&displayed, raw_plan, 0, 1);
        try std.testing.expect(displayed.valid and displayed.selection_over_limit);
        try std.testing.expectEqual(@as(u64, if (method == .auto) 1 else 0), displayed.selected_drive_count);
    }
    const output = try run(std.testing.io, a, try j.value(a, .{ .cmd = "mail.send", .account = "self@example.test", .draft = .{ .to = "peer@example.test", .bodyText = "A local preview" } }), &paths, &.{ .auto, .attach });
    const value = try std.json.parseFromSliceLeaky(j.Value, a, output, .{});
    try std.testing.expect(try j.boolean(value, "ok", false));
    const data = j.get(value, "data").?;
    try std.testing.expect(try j.boolean(data, "dryRun", false));
    try std.testing.expectEqual(@as(i64, 1), try j.integer(data, "driveFileCount", 0));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "index.json", .{}));
    var directory = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}
