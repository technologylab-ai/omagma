//! A local-only delivery plan. Remote identities and progress never enter the
//! reviewed source fingerprint. The caller measures canonical MIME, including
//! conservative placeholder links, before it performs any Drive operation.
const std = @import("std");
const t = @import("types.zig");
const A = std.mem.Allocator;
pub const max_drive_files = 16;
pub const max_file_bytes = t.Limits.disk_hard;
pub const Item = struct { index: usize, delivery: t.AttachmentDelivery };
pub const Plan = struct {
    items: []Item,
    drive_count: usize,
    attached_bytes: usize,
    mime_bytes: usize,
    problem: ?anyerror = null,
    estimated: bool = false,
};
pub const Measure = struct {
    ctx: *anyopaque,
    countFn: *const fn (*anyopaque, A, t.Draft, []const Item) anyerror!usize,
};
/// Explicit attach is immutable policy; auto removes the largest eligible
/// file first, with source order resolving equal sizes deterministically.
pub fn resolve(a: A, draft: t.Draft, measure: Measure) !Plan {
    return resolveMode(a, draft, measure, true);
}
pub fn preview(a: A, draft: t.Draft, measure: Measure) !Plan {
    return resolveMode(a, draft, measure, false);
}
fn resolveMode(a: A, draft: t.Draft, measure: Measure, strict: bool) !Plan {
    if (!t.Limits.native) return error.UnsupportedAttachmentDelivery;
    if (draft.attachments.len > t.Limits.attachments) return error.TooManyAttachments;
    const items = try a.alloc(Item, draft.attachments.len);
    var plan: Plan = .{ .items = items, .drive_count = 0, .attached_bytes = 0, .mime_bytes = 0 };
    var original_bytes: usize = 0;
    if (draft.includeOriginal) if (draft.original) |original| for (original.resources) |file| {
        original_bytes = std.math.add(usize, original_bytes, file.size) catch return error.AttachmentsTooLarge;
    };
    if (original_bytes > t.Limits.attachment_bytes) return error.AttachmentsTooLarge;
    plan.attached_bytes = original_bytes;
    for (draft.attachments, items, 0..) |file, *item, index| {
        if (file.size > max_file_bytes) return error.AttachmentsTooLarge;
        item.* = .{ .index = index, .delivery = if (file.delivery == .drive) .drive else .attach };
        if (item.delivery == .drive) plan.drive_count += 1 else plan.attached_bytes = std.math.add(usize, plan.attached_bytes, file.size) catch return error.AttachmentsTooLarge;
    }
    while (true) {
        if (plan.drive_count > max_drive_files) {
            if (strict) return error.TooManyDriveFiles;
            plan.problem = error.TooManyDriveFiles;
            plan.mime_bytes = overflowEstimate(draft, items);
            plan.estimated = true;
            return plan;
        }
        if (plan.drive_count != 0 and draft.bcc.len != 0) {
            if (strict) return error.DriveBccUnsupported;
            plan.problem = error.DriveBccUnsupported;
        }
        if (plan.attached_bytes <= t.Limits.attachment_bytes) {
            plan.mime_bytes = try measure.countFn(measure.ctx, a, draft, items);
            if (plan.mime_bytes <= t.Limits.mime_upload_bytes) return plan;
        }
        var largest: ?usize = null;
        for (draft.attachments, items, 0..) |file, item, index| {
            if (file.delivery != .auto or item.delivery != .attach) continue;
            if (largest == null or file.size > draft.attachments[largest.?].size or (file.size == draft.attachments[largest.?].size and std.mem.lessThan(u8, file.filename, draft.attachments[largest.?].filename))) largest = index;
        }
        const selected = largest orelse {
            if (strict) return error.AttachmentsTooLarge;
            if (plan.attached_bytes > t.Limits.attachment_bytes) {
                plan.mime_bytes = overflowEstimate(draft, items);
                plan.estimated = true;
            }
            if (plan.problem == null) plan.problem = error.AttachmentsTooLarge;
            return plan;
        };
        items[selected].delivery = .drive;
        plan.drive_count += 1;
        plan.attached_bytes -= draft.attachments[selected].size;
    }
}
/// A refused oversized bundle does not warrant reading or encoding its
/// content. This conservative metadata estimate is explicitly labelled; it
/// cannot authorize a send or replace the final exact MIME admission check.
fn overflowEstimate(draft: t.Draft, items: []const Item) usize {
    const source = if (draft.recoveryFields) |fields| fields[4] else draft.bodyText;
    var bytes: usize = 128 * 1024 + source.len * 6;
    for (items) |item| {
        const file = draft.attachments[item.index];
        if (item.delivery == .drive) {
            bytes += 2048;
            continue;
        }
        const encoded = ((file.size + 2) / 3) * 4;
        bytes += encoded + ((encoded + 75) / 76) * 2 + 2048;
    }
    if (draft.includeOriginal) if (draft.original) |original| {
        bytes += (original.bodyText.len + original.bodyHtml.len) * 6;
        for (original.resources) |file| {
            const encoded = ((file.size + 2) / 3) * 4;
            bytes += encoded + ((encoded + 75) / 76) * 2 + 2048;
        }
    };
    return bytes;
}

/// Remote IDs come exclusively from the private preparation ledger. A preview
/// supplies bounded placeholders instead; it must label that size as an estimate.
pub fn wireDraft(a: A, draft: t.Draft, items: []const Item, ids: []const []const u8) !t.Draft {
    if (items.len != draft.attachments.len) return error.InvalidAttachmentDelivery;
    var files: std.ArrayList(t.Attachment) = .empty;
    var body: std.Io.Writer.Allocating = .init(a);
    defer body.deinit();
    try body.writer.writeAll(draft.bodyText);
    var cursor: usize = 0;
    for (items, 0..) |item, index| {
        if (item.index != index) return error.InvalidAttachmentDelivery;
        const file = draft.attachments[index];
        if (item.delivery == .attach) {
            var attached = file;
            attached.delivery = null;
            try files.append(a, attached);
            continue;
        }
        if (item.delivery != .drive or cursor >= ids.len or cursor >= max_drive_files) return error.InvalidAttachmentDelivery;
        const id = ids[cursor];
        if (id.len == 0 or id.len > 256) return error.InvalidDriveFileId;
        for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidDriveFileId;
        if (cursor == 0) try body.writer.writeAll("\n\nFiles shared via Google Drive:\n");
        try body.writer.writeAll("\n- ");
        var filename = (std.unicode.Utf8View.init(file.filename) catch return error.InvalidAttachmentFilename).iterator();
        while (filename.nextCodepointSlice()) |bytes| {
            const codepoint = try std.unicode.utf8Decode(bytes);
            if (codepoint < 32 or (codepoint >= 127 and codepoint <= 159) or codepoint == 0x061c or codepoint == 0x200e or codepoint == 0x200f or (codepoint >= 0x2028 and codepoint <= 0x202e) or (codepoint >= 0x2066 and codepoint <= 0x2069)) {
                try body.writer.writeByte('?');
                continue;
            }
            if (draft.bodyFormat == .markdown and bytes.len == 1 and std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!<>", bytes[0]) != null) try body.writer.writeByte('\\');
            try body.writer.writeAll(bytes);
        }
        const unit: usize = if (file.size < 1024 * 1024) 1024 else 1024 * 1024;
        const tenths = (file.size * 10 + unit / 2) / unit;
        try body.writer.print(" ({d}.{d} {s}): ", .{ tenths / 10, tenths % 10, if (unit == 1024) @as([]const u8, "KiB") else "MiB" });
        if (draft.bodyFormat == .markdown) try body.writer.writeByte('<');
        try body.writer.writeAll("https://drive.google.com/file/d/");
        try body.writer.writeAll(id);
        try body.writer.writeAll(if (draft.bodyFormat == .markdown) "/view>\n" else "/view\n");
        cursor += 1;
    }
    if (cursor != ids.len) return error.InvalidAttachmentDelivery;
    if (cursor != 0 and draft.bcc.len != 0) return error.DriveBccUnsupported;
    var result = draft;
    result.attachments = try files.toOwnedSlice(a);
    result.bodyText = try a.dupe(u8, body.written());
    return result;
}

test "attachment delivery: aggregate and encoded limits choose largest auto and preserve explicit files" {
    const Oracle = struct {
        fn count(_: *anyopaque, _: A, draft: t.Draft, items: []const Item) !usize {
            var bytes: usize = 1024;
            for (items) |item| if (item.delivery == .attach) {
                bytes += draft.attachments[item.index].size * 2;
            };
            return bytes;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context: u8 = 0;
    const measure: Measure = .{ .ctx = &context, .countFn = Oracle.count };
    const files = [_]t.Attachment{
        .{ .id = "small", .filename = "small.pdf", .size = 2 * 1024 * 1024 },
        .{ .id = "first", .filename = "first.zip", .size = 16 * 1024 * 1024, .delivery = .auto },
        .{ .id = "second", .filename = "second.zip", .size = 16 * 1024 * 1024, .delivery = .auto },
    };
    const draft: t.Draft = .{ .attachments = &files };
    const plan = try resolve(a, draft, measure);
    try std.testing.expectEqual(@as(usize, 2), plan.drive_count);
    try std.testing.expectEqual(t.AttachmentDelivery.attach, plan.items[0].delivery);
    var hidden = draft;
    hidden.bcc = &.{.{ .address = "hidden@example.test" }};
    try std.testing.expectError(error.DriveBccUnsupported, resolve(a, hidden, measure));
    const forced: t.Draft = .{ .attachments = &.{.{ .id = "forced", .filename = "large.zip", .size = 26 * 1024 * 1024 }} };
    try std.testing.expectError(error.AttachmentsTooLarge, resolve(a, forced, measure));
}

test "attachment delivery: links escape filenames and leave reviewed draft unchanged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const draft: t.Draft = .{ .bodyText = "New note", .bodyFormat = .markdown, .attachments = &.{.{ .id = "file", .filename = "evil](url).zip", .delivery = .drive }} };
    const wire = try wireDraft(a, draft, &.{.{ .index = 0, .delivery = .drive }}, &.{"synthetic_id"});
    try std.testing.expectEqualStrings("New note", draft.bodyText);
    try std.testing.expectEqual(@as(usize, 0), wire.attachments.len);
    try std.testing.expect(std.mem.indexOf(u8, wire.bodyText, "evil\\]\\(url\\)\\.zip") != null);
    try std.testing.expectError(error.InvalidDriveFileId, wireDraft(a, draft, &.{.{ .index = 0, .delivery = .drive }}, &.{"bad/id"}));
}

test "attachment delivery: oversized preview refuses with bounded arithmetic instead of serializing bytes" {
    const Oracle = struct {
        fn count(_: *anyopaque, _: A, _: t.Draft, _: []const Item) !usize {
            return error.MustNotReadOrEncodeContent;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attachments = try a.alloc(t.Attachment, t.Limits.attachments);
    for (attachments) |*file| file.* = .{ .id = "synthetic", .filename = "large.bin", .size = max_file_bytes };
    var context: u8 = 0;
    const plan = try preview(a, .{ .attachments = attachments }, .{ .ctx = &context, .countFn = Oracle.count });
    try std.testing.expect(plan.estimated);
    try std.testing.expectEqual(error.AttachmentsTooLarge, plan.problem.?);
    try std.testing.expect(plan.mime_bytes > t.Limits.mime_upload_bytes);
}
