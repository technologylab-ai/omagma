//! Composer/review presentation of the backend attachment plan. Sizes,
//! resolutions and blockers come only from the backend; this file formats.
const std = @import("std");
const types = @import("types.zig");
const Value = std.json.Value;

pub const Delivery = types.AttachmentDelivery;
pub const Resolved = enum(u8) { unknown, attach, drive };
/// Declaration order is display priority: B2 > B3 > B4 > B1a > B1b > B6.
pub const Blocker = enum(u3) { bcc_with_drive, drive_not_connected, drive_unsupported, drive_no_recipients, attachments_too_large, message_too_large, too_many_drive_files, other };
pub const max_files = types.Limits.attachments;
/// Fixed delivery-button cells keep every row's [x] aligned.
pub const button_cells: u16 = 15;
pub const narrow_button_cells: u16 = 10;

const codes = [_]struct { code: []const u8, alias: []const u8, blocker: Blocker }{
    .{ .code = "DriveWithBcc", .alias = "bcc_with_drive", .blocker = .bcc_with_drive },
    .{ .code = "DriveNotConnected", .alias = "drive_not_connected", .blocker = .drive_not_connected },
    .{ .code = "DriveUnsupported", .alias = "drive_unsupported", .blocker = .drive_unsupported },
    .{ .code = "DriveNoRecipients", .alias = "drive_no_recipients", .blocker = .drive_no_recipients },
    .{ .code = "AttachmentsTooLarge", .alias = "too_large", .blocker = .attachments_too_large },
    .{ .code = "ForcedAttachmentsTooLarge", .alias = "forced_too_large", .blocker = .attachments_too_large },
    .{ .code = "MessageTooLarge", .alias = "mime_too_large", .blocker = .message_too_large },
    .{ .code = "TooManyDriveFiles", .alias = "too_many_drive_files", .blocker = .too_many_drive_files },
};

pub fn blockerFor(code: []const u8) Blocker {
    for (codes) |entry| if (std.mem.eql(u8, code, entry.code) or std.mem.eql(u8, code, entry.alias)) return entry.blocker;
    return .other;
}

pub const Plan = struct {
    valid: bool = false,
    file_count: usize = 0,
    resolved: [max_files]Resolved = @splat(.unknown),
    attached_bytes: u64 = 0,
    mime_bytes: u64 = 0,
    mime_estimate: bool = false,
    drive_count: u64 = 0,
    drive_limit: u64 = 0,
    decoded_limit: u64 = 0,
    mime_limit: u64 = 0,
    blockers: u8 = 0,
    other: [160]u8 = undefined,
    other_len: usize = 0,
    /// Earlier Drive copies (§1.5): reused private/same-recipient uploads,
    /// and files needing a new private copy with their review notes.
    reuse: [max_files]Reuse = @splat(.none),
    new_copy: [max_files]bool = @splat(false),
    notes: [2048]u8 = undefined,
    notes_len: usize = 0,
    /// draft.selection-plan only: the unimported selection starts here.
    selected_start: usize = 0,
    selected_attached_count: u64 = 0,
    selected_attached_bytes: u64 = 0,
    selected_drive_count: u64 = 0,
    selected_drive_bytes: u64 = 0,
    selection_over_limit: bool = false,

    pub fn has(self: *const Plan, blocker: Blocker) bool {
        return self.blockers & (@as(u8, 1) << @backingInt(blocker)) != 0;
    }
    pub fn blocked(self: *const Plan) bool {
        return self.blockers != 0;
    }
    pub fn first(self: *const Plan) ?Blocker {
        var bit: u4 = 0;
        while (bit < 8) : (bit += 1) {
            const blocker: Blocker = @fromBackingInt(@intCast(@as(u3, @intCast(bit))));
            if (self.has(blocker)) return blocker;
        }
        return null;
    }
    pub fn sizeBlocked(self: *const Plan) bool {
        return self.has(.attachments_too_large) or self.has(.message_too_large);
    }
    pub fn resolution(self: *const Plan, index: usize) Resolved {
        return if (index < self.file_count) self.resolved[index] else .unknown;
    }
    pub fn otherMessage(self: *const Plan) []const u8 {
        return self.other[0..self.other_len];
    }
    pub fn copyNotes(self: *const Plan) []const u8 {
        return self.notes[0..self.notes_len];
    }
    /// Row badge after the file name: a fresh copy wins over reuse.
    pub fn badge(self: *const Plan, index: usize) []const u8 {
        if (index >= self.file_count) return "";
        if (self.new_copy[index]) return " · new copy";
        return if (self.reuse[index] != .none) " · uploaded" else "";
    }
    fn note(self: *Plan, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.notes_len == self.notes.len) return;
            self.notes[self.notes_len] = if ((byte < 0x20 and byte != '\n') or byte == 0x7f) '?' else byte;
            self.notes_len += 1;
        }
    }
};
pub const Reuse = enum(u8) { none, private_upload, shared_same_recipients };

fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn count(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidAttachmentPlan;
    return @intCast(value.integer);
}

/// Replaces plan with the backend attachmentPlan for exactly attachment_count
/// composer files. Any malformed field leaves an invalid plan, never a guess.
pub fn parse(plan: *Plan, value: Value, attachment_count: usize) !void {
    plan.* = .{};
    errdefer plan.* = .{};
    if (value != .object or attachment_count > max_files) return error.InvalidAttachmentPlan;
    plan.attached_bytes = try count(field(value, "attachedBytes"));
    plan.mime_bytes = try count(field(value, "mimeBytes"));
    plan.drive_count = try count(field(value, "driveFileCount"));
    plan.drive_limit = try count(field(value, "driveFileLimit"));
    plan.decoded_limit = try count(field(value, "decodedLimitBytes"));
    plan.mime_limit = try count(field(value, "mimeLimitBytes"));
    const estimate = field(value, "mimeEstimate");
    plan.mime_estimate = estimate == .bool and estimate.bool;
    const files = field(value, "files");
    if (files != .array or files.array.items.len != attachment_count) return error.InvalidAttachmentPlan;
    for (files.array.items) |item| {
        const raw_index = try count(field(item, "index"));
        if (raw_index >= attachment_count) return error.InvalidAttachmentPlan;
        const index: usize = @intCast(raw_index);
        if (plan.resolved[index] != .unknown) return error.InvalidAttachmentPlan;
        const delivery = field(item, "delivery");
        if (delivery != .string) return error.InvalidAttachmentPlan;
        plan.resolved[index] = if (std.mem.eql(u8, delivery.string, "attach")) .attach else if (std.mem.eql(u8, delivery.string, "drive")) .drive else return error.InvalidAttachmentPlan;
        const reuse = field(item, "reuse");
        if (reuse == .string) plan.reuse[index] = std.meta.stringToEnum(Reuse, reuse.string) orelse return error.InvalidAttachmentPlan else if (reuse != .null) return error.InvalidAttachmentPlan;
        const fresh = field(item, "newCopy");
        plan.new_copy[index] = fresh == .bool and fresh.bool;
        if (plan.new_copy[index]) {
            // §1.3: name the earlier recipients; the old copy is never touched.
            const filename = field(item, "filename");
            plan.note(if (filename == .string) filename.string else "A Drive file");
            plan.note(" was shared earlier with ");
            const shared = field(item, "sharedWith");
            var first = true;
            if (shared == .array) for (shared.array.items) |address| if (address == .string) {
                if (!first) plan.note(", ");
                plan.note(address.string);
                first = false;
            };
            if (first) plan.note("other recipients");
            plan.note(". A new private copy will be shared with the recipients above; the earlier copy stays shared.\n");
        }
    }
    const blockers = field(value, "blockers");
    if (blockers != .array and blockers != .null) return error.InvalidAttachmentPlan;
    if (blockers == .array) for (blockers.array.items) |item| {
        const code = field(item, "code");
        if (code != .string) return error.InvalidAttachmentPlan;
        const blocker = blockerFor(code.string);
        plan.blockers |= @as(u8, 1) << @backingInt(blocker);
        if (blocker == .other and plan.other_len == 0) {
            const message = field(item, "message");
            const raw = if (message == .string and message.string.len > 0) message.string else code.string;
            // Backend text is display-only: keep a bounded printable copy.
            for (raw[0..@min(raw.len, plan.other.len)]) |byte| {
                plan.other[plan.other_len] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
                plan.other_len += 1;
            }
        }
    };
    plan.file_count = attachment_count;
    plan.valid = true;
}

/// draft.selection-plan: the plan covers existing files plus the selection
/// requested as Auto. Selection totals may sit in data or attachmentPlan.
pub fn parseSelection(plan: *Plan, data: Value, existing: usize, selected: usize) !void {
    const wrapped = field(data, "attachmentPlan");
    const source = if (wrapped == .null) data else wrapped;
    try parse(plan, source, existing + selected);
    errdefer plan.* = .{};
    const start = selectionField(data, source, "selectedStart");
    if ((try count(start)) != existing) return error.InvalidAttachmentPlan;
    plan.selected_start = existing;
    plan.selected_attached_count = try count(selectionField(data, source, "selectedAttachedCount"));
    plan.selected_attached_bytes = try count(selectionField(data, source, "selectedAttachedBytes"));
    plan.selected_drive_count = try count(selectionField(data, source, "selectedDriveCount"));
    plan.selected_drive_bytes = try count(selectionField(data, source, "selectedDriveBytes"));
    if (plan.selected_attached_count + plan.selected_drive_count != selected) return error.InvalidAttachmentPlan;
    const over = selectionField(data, source, "selectionOverLimit");
    if (over != .bool) return error.InvalidAttachmentPlan;
    plan.selection_over_limit = over.bool;
}
fn selectionField(data: Value, source: Value, name: []const u8) Value {
    const direct = field(data, name);
    return if (direct != .null) direct else field(source, name);
}

/// KiB below 1 MiB, otherwise MiB with one decimal.
pub fn size(a: std.mem.Allocator, bytes: u64) ![]const u8 {
    const mib: u64 = 1024 * 1024;
    if (bytes < mib) {
        const tenths = (bytes * 10 + 512) / 1024;
        return std.fmt.allocPrint(a, "{d}.{d} KiB", .{ tenths / 10, tenths % 10 });
    }
    const tenths = (bytes * 10 + mib / 2) / mib;
    return std.fmt.allocPrint(a, "{d}.{d} MiB", .{ tenths / 10, tenths % 10 });
}
/// Limits are whole MiB in every current policy; keep one decimal otherwise.
pub fn limit(a: std.mem.Allocator, bytes: u64) ![]const u8 {
    const mib: u64 = 1024 * 1024;
    if (bytes % mib == 0) return std.fmt.allocPrint(a, "{d} MiB", .{bytes / mib});
    return std.fmt.allocPrint(a, "{s} MiB", .{try decimal(a, bytes)});
}
fn decimal(a: std.mem.Allocator, bytes: u64) ![]const u8 {
    const mib: u64 = 1024 * 1024;
    if (bytes % mib == 0) return std.fmt.allocPrint(a, "{d}", .{bytes / mib});
    const tenths = (bytes * 10 + mib / 2) / mib;
    return std.fmt.allocPrint(a, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

/// Narrow rows truncate names in the middle so the extension stays visible.
pub fn middle(a: std.mem.Allocator, name: []const u8, cells: usize) ![]const u8 {
    const total = std.unicode.utf8CountCodepoints(name) catch return name[0..@min(name.len, cells)];
    if (total <= cells) return name;
    if (cells < 3) return "…";
    const keep = cells - 1;
    const head_cells = keep - keep / 2;
    const tail_cells = keep / 2;
    var head_end: usize = 0;
    var seen: usize = 0;
    while (seen < head_cells) : (seen += 1) head_end += std.unicode.utf8ByteSequenceLength(name[head_end]) catch 1;
    var tail_start: usize = name.len;
    seen = 0;
    while (seen < tail_cells) : (seen += 1) {
        tail_start -= 1;
        while (tail_start > 0 and (name[tail_start] & 0xc0) == 0x80) tail_start -= 1;
    }
    return std.fmt.allocPrint(a, "{s}…{s}", .{ name[0..head_end], name[tail_start..] });
}

pub fn header(a: std.mem.Allocator, plan: *const Plan, files: usize, narrow: bool) ![]const u8 {
    const approx: []const u8 = if (plan.mime_estimate) "≈" else "";
    if (narrow) return std.fmt.allocPrint(a, "Att {s}/{s} · MIME {s}{s}/{s} MiB · Drv {d}/{d}", .{ try decimal(a, plan.attached_bytes), try decimal(a, plan.decoded_limit), approx, try decimal(a, plan.mime_bytes), try decimal(a, plan.mime_limit), plan.drive_count, plan.drive_limit });
    return std.fmt.allocPrint(a, "Attachments {d} · {s} / {s} · message {s}{s} / {s} · Drive {d}/{d}", .{ files, try size(a, plan.attached_bytes), try limit(a, plan.decoded_limit), approx, try size(a, plan.mime_bytes), try limit(a, plan.mime_limit), plan.drive_count, plan.drive_limit });
}
/// The widest header that fits `cells`: full words, then shared MiB units,
/// then the narrow form, so buttons beside it never clip the Drive count.
pub fn headerFit(a: std.mem.Allocator, plan: *const Plan, files: usize, cells: usize) ![]const u8 {
    const full = try header(a, plan, files, false);
    if (try std.unicode.utf8CountCodepoints(full) <= cells) return full;
    const approx: []const u8 = if (plan.mime_estimate) "≈" else "";
    const medium = try std.fmt.allocPrint(a, "Attachments {d} · {s}/{s} MiB · message {s}{s}/{s} MiB · Drive {d}/{d}", .{ files, try decimal(a, plan.attached_bytes), try decimal(a, plan.decoded_limit), approx, try decimal(a, plan.mime_bytes), try decimal(a, plan.mime_limit), plan.drive_count, plan.drive_limit });
    if (try std.unicode.utf8CountCodepoints(medium) <= cells) return medium;
    return header(a, plan, files, true);
}

fn requestedOrAttach(requested: ?Delivery) Delivery {
    return requested orelse .attach;
}
pub fn isDrive(requested: ?Delivery) bool {
    return requestedOrAttach(requested) == .drive;
}
pub fn isAttach(requested: ?Delivery) bool {
    return requestedOrAttach(requested) == .attach;
}
/// Enter cycles Attach → Auto → Drive → Attach. Attach keeps the legacy null.
pub fn next(requested: ?Delivery) ?Delivery {
    return switch (requestedOrAttach(requested)) {
        .attach => .auto,
        .auto => .drive,
        .drive => null,
    };
}
pub fn button(requested: ?Delivery, resolved: Resolved, narrow: bool) []const u8 {
    return switch (requestedOrAttach(requested)) {
        .attach => if (narrow) "[Att     ]" else "[Attach       ]",
        .drive => if (narrow) "[Drv     ]" else "[Drive        ]",
        .auto => switch (resolved) {
            .attach => if (narrow) "[Auto›Att]" else "[Auto → attach]",
            .drive => if (narrow) "[Auto›Drv]" else "[Auto → Drive ]",
            .unknown => if (narrow) "[Auto    ]" else "[Auto         ]",
        },
    };
}
pub fn label(requested: ?Delivery, resolved: Resolved) []const u8 {
    return switch (requestedOrAttach(requested)) {
        .attach => "Attach",
        .drive => "Drive",
        .auto => switch (resolved) {
            .attach => "Auto → attach",
            .drive => "Auto → Drive",
            .unknown => "Auto",
        },
    };
}

pub fn warning(a: std.mem.Allocator, plan: *const Plan, blocker: Blocker, account: []const u8) ![]const u8 {
    return switch (blocker) {
        .bcc_with_drive => "⚠ Drive can't be used while Bcc has recipients. Remove Bcc or attach these files.",
        .drive_not_connected => std.fmt.allocPrint(a, "⚠ Drive isn't connected for {s}.", .{account}),
        .drive_unsupported => std.fmt.allocPrint(a, "⚠ {s} can't upload to Drive. Attach these files or change From.", .{account}),
        .drive_no_recipients => "⚠ Drive files need at least one To or Cc recipient.",
        .attachments_too_large => std.fmt.allocPrint(a, "⚠ Attachments total {s}; the limit is {s}. Set large files to Auto or Drive.", .{ try size(a, plan.attached_bytes), try limit(a, plan.decoded_limit) }),
        .message_too_large => std.fmt.allocPrint(a, "⚠ The complete message would be {s}; the limit is {s} (encoding adds about a third). Set large files to Auto or Drive.", .{ try size(a, plan.mime_bytes), try limit(a, plan.mime_limit) }),
        .too_many_drive_files => std.fmt.allocPrint(a, "⚠ {d} Drive files; at most {d} per message.", .{ plan.drive_count, plan.drive_limit }),
        .other => std.fmt.allocPrint(a, "⚠ {s}", .{plan.otherMessage()}),
    };
}

/// Connect Drive requests the current grant plus drive-upload, never
/// drive-upload alone. Null means the current set is unknown or not
/// canonical: no command is suggested, because a guess could drop access.
pub fn capabilityList(a: std.mem.Allocator, existing: []const []const u8) !?[]const u8 {
    if (existing.len == 0) return null;
    var list: std.ArrayList(u8) = .empty;
    var has_upload = false;
    for (existing, 0..) |capability, index| {
        if (!canonicalCapability(capability)) return null;
        for (existing[0..index]) |previous| if (std.mem.eql(u8, previous, capability)) return null;
        if (list.items.len > 0) try list.append(a, ',');
        try list.appendSlice(a, capability);
        has_upload = has_upload or std.mem.eql(u8, capability, "drive-upload");
    }
    if (!has_upload) try list.appendSlice(a, ",drive-upload");
    return list.items;
}
fn canonicalCapability(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-')) return false;
    return true;
}
/// Shown instead of a command when the current capabilities can't be read.
/// account and routing arrive shell-quoted; both commands name the account.
pub fn unknownCapabilitiesHint(a: std.mem.Allocator, account: []const u8, routing: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Omagma couldn't read the current capabilities for {s}, so it won't suggest a list that could remove access. Check them with omagma terminal-auth status --account {s}{s}, then run omagma terminal-auth authorize --account {s}{s} with every current capability plus drive-upload.", .{ account, account, routing, account, routing });
}

test "delivery view: backend plan parses resolutions and blockers in priority order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"files":[{"index":1,"filename":"photo.jpg","size":8493466,"requestedDelivery":"auto","delivery":"attach"},
        \\{"index":0,"filename":"report-final.pdf","size":32505856,"requestedDelivery":"drive","delivery":"drive"}],
        \\"attachedBytes":8493466,"mimeBytes":11953766,"mimeEstimate":true,"driveFileCount":1,"driveFileLimit":16,
        \\"decodedLimitBytes":26214400,"mimeLimitBytes":36700160,
        \\"blockers":[{"code":"DriveNoRecipients","message":"x"},{"code":"DriveWithBcc","message":"y"}]}
    ;
    const value = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
    var plan: Plan = .{};
    try parse(&plan, value, 2);
    try std.testing.expect(plan.valid);
    try std.testing.expectEqual(Resolved.drive, plan.resolution(0));
    try std.testing.expectEqual(Resolved.attach, plan.resolution(1));
    try std.testing.expectEqual(Blocker.bcc_with_drive, plan.first().?);
    try std.testing.expect(plan.has(.drive_no_recipients) and !plan.sizeBlocked());
    try std.testing.expectEqualStrings("Attachments 2 · 8.1 MiB / 25 MiB · message ≈11.4 MiB / 35 MiB · Drive 1/16", try header(a, &plan, 2, false));
    try std.testing.expectEqualStrings("Att 8.1/25 · MIME ≈11.4/35 MiB · Drv 1/16", try header(a, &plan, 2, true));
    // Beside [Upload all] the full header (74 cells) shortens its units first;
    // the Drive count survives at every width.
    try std.testing.expectEqualStrings(try header(a, &plan, 2, false), try headerFit(a, &plan, 2, 74));
    try std.testing.expectEqualStrings("Attachments 2 · 8.1/25 MiB · message ≈11.4/35 MiB · Drive 1/16", try headerFit(a, &plan, 2, 73));
    try std.testing.expectEqualStrings("Att 8.1/25 · MIME ≈11.4/35 MiB · Drv 1/16", try headerFit(a, &plan, 2, 61));
    try std.testing.expectEqualStrings("[Auto → attach]", button(.auto, plan.resolution(1), false));
    try std.testing.expectError(error.InvalidAttachmentPlan, parse(&plan, value, 3));
    try std.testing.expect(!plan.valid);
}

test "delivery view: labels keep fixed cells, cycle order and safe capability requests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]?Delivery{ null, .attach, .auto, .drive }) |requested| for ([_]Resolved{ .unknown, .attach, .drive }) |resolved| {
        try std.testing.expectEqual(@as(usize, button_cells), try std.unicode.utf8CountCodepoints(button(requested, resolved, false)));
        try std.testing.expectEqual(@as(usize, narrow_button_cells), try std.unicode.utf8CountCodepoints(button(requested, resolved, true)));
    };
    try std.testing.expectEqual(@as(?Delivery, .auto), next(null));
    try std.testing.expectEqual(@as(?Delivery, .drive), next(.auto));
    try std.testing.expectEqual(@as(?Delivery, null), next(.drive));
    try std.testing.expectEqualStrings("12.0 KiB", try size(a, 12 * 1024));
    try std.testing.expectEqualStrings("31.0 MiB", try size(a, 31 * 1024 * 1024));
    try std.testing.expectEqualStrings("mail-read,mail-send,drive-upload", (try capabilityList(a, &.{ "mail-read", "mail-send" })).?);
    try std.testing.expectEqualStrings("mail-read,drive-upload", (try capabilityList(a, &.{ "mail-read", "drive-upload" })).?);
    // Unknown or non-canonical sets never become a guessed, narrower command.
    try std.testing.expect((try capabilityList(a, &.{})) == null);
    try std.testing.expect((try capabilityList(a, &.{ "mail-read", "mail-read" })) == null);
    try std.testing.expect((try capabilityList(a, &.{ "mail-read", "mail-send --client-file x" })) == null);
    try std.testing.expect((try capabilityList(a, &.{ "mail-read", "" })) == null);
    var plan: Plan = .{ .valid = true, .attached_bytes = 27472691, .decoded_limit = 26214400 };
    plan.blockers = @as(u8, 1) << @backingInt(Blocker.attachments_too_large);
    try std.testing.expectEqualStrings("⚠ Attachments total 26.2 MiB; the limit is 25 MiB. Set large files to Auto or Drive.", try warning(a, &plan, plan.first().?, "self@example.test"));
    try std.testing.expectEqualStrings("⚠ Drive isn't connected for self@example.test.", try warning(a, &plan, .drive_not_connected, "self@example.test"));
    try std.testing.expectEqual(Blocker.other, blockerFor("SomethingNew"));
    try std.testing.expectEqual(Blocker.attachments_too_large, blockerFor("forced_too_large"));
}

test "delivery view: reuse badges, new-copy notes and selection totals come from the backend" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"selectedStart":1,"selectedAttachedCount":1,"selectedAttachedBytes":4,"selectedDriveCount":1,"selectedDriveBytes":32505856,"selectionOverLimit":true,
        \\"attachmentPlan":{"files":[{"index":0,"filename":"report-final.pdf","size":4,"requestedDelivery":"drive","delivery":"drive","reuse":"shared_same_recipients","newCopy":true,"sharedWith":["peer@example.test","old@example.test"]},
        \\{"index":1,"filename":"notes.txt","size":4,"requestedDelivery":"auto","delivery":"attach","reuse":"none","newCopy":false},
        \\{"index":2,"filename":"video.mp4","size":32505856,"requestedDelivery":"auto","delivery":"drive","reuse":"private_upload"}],
        \\"attachedBytes":4,"mimeBytes":900,"mimeEstimate":true,"driveFileCount":2,"driveFileLimit":16,
        \\"decodedLimitBytes":26214400,"mimeLimitBytes":36700160,"blockers":[]}}
    ;
    const value = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
    var plan: Plan = .{};
    try parseSelection(&plan, value, 1, 2);
    try std.testing.expect(plan.selection_over_limit and plan.selected_drive_count == 1);
    try std.testing.expectEqualStrings(" · new copy", plan.badge(0));
    try std.testing.expectEqualStrings("", plan.badge(1));
    try std.testing.expectEqualStrings(" · uploaded", plan.badge(2));
    try std.testing.expectEqualStrings("report-final.pdf was shared earlier with peer@example.test, old@example.test. A new private copy will be shared with the recipients above; the earlier copy stays shared.\n", plan.copyNotes());
    try std.testing.expectError(error.InvalidAttachmentPlan, parseSelection(&plan, value, 2, 1));
    try std.testing.expect(!plan.valid);
    try std.testing.expectEqualStrings("report…l.pdf", try middle(a, "report-final.pdf", 12));
    try std.testing.expectEqualStrings("notes.txt", try middle(a, "notes.txt", 12));
}
