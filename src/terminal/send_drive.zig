//! Drive send progress, pinned send summary and preparation receipts. The
//! worker publishes numbers only; names come from the composer pinned at Send.
const std = @import("std");
const Value = std.json.Value;
const bounded = @import("../bounded.zig");

/// At most 16 Drive files per message.
pub const max_files = 16;
/// Pinned rows: every Drive file plus a few attached names.
pub const max_pinned = max_files + 4;
pub const Phase = enum(u8) { reserving, uploading, sharing, submitting };
pub const FileState = enum(u8) { waiting, reserved, uploading, uploaded, sharing, shared };

/// Maps FetchPhase tags by name so ordinary mail phases never match.
pub fn phaseOf(phase: anytype) ?Phase {
    const name = @tagName(phase);
    if (std.mem.eql(u8, name, "drive_reserving")) return .reserving;
    if (std.mem.eql(u8, name, "drive_uploading")) return .uploading;
    if (std.mem.eql(u8, name, "drive_sharing")) return .sharing;
    if (std.mem.eql(u8, name, "mail_submitting")) return .submitting;
    return null;
}

const empty_slot = std.math.maxInt(usize);
const Slot = struct {
    index: std.atomic.Value(usize) = .init(empty_slot),
    state: std.atomic.Value(u8) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
};
pub const FileProgress = struct { index: usize, state: FileState, completed: usize, total: usize };
pub const Snapshot = struct {
    phase: ?Phase = null,
    file_count: usize = 0,
    count: usize = 0,
    files: [max_files]FileProgress = undefined,
    pub fn find(self: *const Snapshot, index: usize) ?FileProgress {
        for (self.files[0..self.count]) |file| if (file.index == index) return file;
        return null;
    }
};

/// Single writer (worker), single reader (UI). Torn completed/total pairs
/// are clamped; the next event repaints the current values.
pub const Mailbox = struct {
    phase: std.atomic.Value(u8) = .init(0),
    file_count: std.atomic.Value(usize) = .init(0),
    slots: [max_files]Slot = @splat(.{}),

    /// UI thread only, before a send job starts.
    pub fn reset(self: *Mailbox) void {
        self.phase.store(0, .release);
        self.file_count.store(0, .release);
        for (&self.slots) |*slot| {
            slot.state.store(0, .release);
            slot.completed.store(0, .release);
            slot.total.store(0, .release);
            slot.index.store(empty_slot, .release);
        }
    }
    pub fn publish(self: *Mailbox, phase: Phase, file_index: ?usize, file_count: ?usize, completed: usize, total: usize) void {
        self.phase.store(@as(u8, @backingInt(phase)) + 1, .release);
        if (file_count) |count| self.file_count.store(@min(count, max_files), .release);
        const index = file_index orelse return;
        const slot = self.slotFor(index) orelse return;
        const done = total > 0 and completed >= total;
        const state: FileState = switch (phase) {
            .reserving => .reserved,
            .uploading => if (done) .uploaded else .uploading,
            .sharing => if (done) .shared else .sharing,
            .submitting => return,
        };
        slot.total.store(total, .release);
        slot.completed.store(@min(completed, total), .release);
        slot.state.store(@backingInt(state), .release);
    }
    fn slotFor(self: *Mailbox, index: usize) ?*Slot {
        for (&self.slots) |*slot| if (slot.index.load(.acquire) == index) return slot;
        for (&self.slots) |*slot| if (slot.index.load(.acquire) == empty_slot) {
            slot.index.store(index, .release);
            return slot;
        };
        return null;
    }
    pub fn snapshot(self: *const Mailbox) Snapshot {
        var result: Snapshot = .{};
        const phase = self.phase.load(.acquire);
        result.phase = if (phase == 0) null else @as(Phase, @fromBackingInt(phase - 1));
        result.file_count = self.file_count.load(.acquire);
        for (&self.slots) |*slot| {
            const index = slot.index.load(.acquire);
            if (index == empty_slot) continue;
            const total = slot.total.load(.acquire);
            result.files[result.count] = .{ .index = index, .state = @fromBackingInt(slot.state.load(.acquire)), .completed = @min(slot.completed.load(.acquire), total), .total = total };
            result.count += 1;
        }
        return result;
    }
};

/// Cuts at a UTF-8 boundary so bounded copies never split a character.
pub fn clip(raw: []const u8, limit: usize) []const u8 {
    if (raw.len <= limit) return raw;
    var end = limit;
    while (end > 0 and (raw[end] & 0xc0) == 0x80) end -= 1;
    return raw[0..end];
}

pub const PinnedFile = struct { index: usize = 0, name: bounded.Text(96) = .{}, size: u64 = 0, drive: bool = false };
/// The composer as reviewed at Send. Progress rows never borrow live strings.
pub const Pinned = struct {
    active: bool = false,
    subject: bounded.Text(160) = .{},
    account: bounded.Text(320) = .{},
    count: usize = 0,
    files: [max_pinned]PinnedFile = @splat(.{}),
    drive_count: usize = 0,
    attached_hidden: usize = 0,
    /// The phase last put on the status line; begin() clears it per send.
    announced: ?Phase = null,

    pub fn begin(self: *Pinned, subject: []const u8, account: []const u8) !void {
        self.* = .{};
        try self.subject.set(clip(subject, 160));
        try self.account.set(clip(account, 320));
        self.active = true;
    }
    /// Drive files are always kept; attached names fill the remaining rows.
    pub fn add(self: *Pinned, index: usize, name: []const u8, size: u64, drive: bool) !void {
        if (drive) self.drive_count += 1;
        if (self.count == max_pinned or (!drive and self.count - @min(self.count, self.drive_count) >= max_pinned - max_files)) {
            if (!drive) self.attached_hidden += 1;
            return;
        }
        self.files[self.count] = .{ .index = index, .size = size, .drive = drive };
        try self.files[self.count].name.set(clip(name, 96));
        self.count += 1;
    }
};

pub const ReceiptState = enum { reserved, uploading, uploaded, sharing, shared, uncertain, unknown };
pub const ReceiptFile = struct {
    index: usize = 0,
    name: bounded.Text(96) = .{},
    size: u64 = 0,
    state: ReceiptState = .unknown,
    shared_with: bounded.Text(512) = .{},
    unconfirmed: bounded.Text(320) = .{},
};
pub const Kind = enum { none, stopped, paused, shared_rejected, unknown };
/// A preparation outcome shown in place of the progress view. Nothing here
/// retries by itself; every button is an explicit user action.
pub const Failure = struct {
    kind: Kind = .none,
    code: bounded.Text(64) = .{},
    operation: bounded.Text(128) = .{},
    /// Shown only for the draft and account it belongs to.
    draft: bounded.Text(128) = .{},
    account: bounded.Text(320) = .{},
    can_retry: bool = false,
    focus: usize = 0,
    count: usize = 0,
    files: [max_files]ReceiptFile = @splat(.{}),

    pub fn anyShared(self: *const Failure) bool {
        for (self.files[0..self.count]) |file| if (file.state == .shared or file.shared_with.len > 0) return true;
        return false;
    }
};

fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn string(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}

/// Copies driveFiles receipts. Addresses are joined for display; a missing
/// or malformed list leaves no receipts rather than invented ones.
pub fn parseFiles(failure: *Failure, files: Value) !void {
    failure.count = 0;
    if (files != .array) return;
    for (files.array.items) |item| {
        if (failure.count == max_files) break;
        var file: ReceiptFile = .{};
        const index = field(item, "index");
        file.index = if (index == .integer and index.integer >= 0) @intCast(index.integer) else 0;
        const size = field(item, "size");
        file.size = if (size == .integer and size.integer >= 0) @intCast(size.integer) else 0;
        try file.name.set(clip(string(field(item, "filename")), 96));
        file.state = std.meta.stringToEnum(ReceiptState, string(field(item, "state"))) orelse .unknown;
        var joined: [512]u8 = undefined;
        var length: usize = 0;
        const shared = field(item, "sharedWith");
        if (shared == .array) for (shared.array.items) |address| {
            const raw = string(address);
            if (raw.len == 0) continue;
            const separator: []const u8 = if (length > 0) ", " else "";
            if (length + separator.len + raw.len > joined.len) break;
            @memcpy(joined[length..][0..separator.len], separator);
            length += separator.len;
            @memcpy(joined[length..][0..raw.len], raw);
            length += raw.len;
        };
        try file.shared_with.set(joined[0..length]);
        try file.unconfirmed.set(clip(string(field(item, "sharingUnconfirmedWith")), 320));
        failure.files[failure.count] = file;
        failure.count += 1;
    }
}

/// Per-file receipt wording; partial sharing lists both confirmed and
/// unconfirmed grants. An unconfirmed grant may have applied, so such a
/// file is never called private.
pub fn receipt(a: std.mem.Allocator, file: *const ReceiptFile) ![]const u8 {
    const confirmed = file.shared_with.slice();
    const pending = file.unconfirmed.slice();
    const base: []const u8 = switch (file.state) {
        .reserved => "not uploaded",
        .uploading => "upload interrupted",
        .uploaded => if (pending.len > 0) "uploaded" else "uploaded · private",
        .sharing, .shared, .uncertain => if (confirmed.len > 0) try std.fmt.allocPrint(a, "shared with {s}", .{confirmed}) else if (pending.len > 0 or file.state == .uncertain) "uploaded" else "uploaded · private",
        .unknown => "state not recorded",
    };
    if (pending.len == 0) return if (file.state == .uncertain) std.fmt.allocPrint(a, "{s} · sharing not confirmed", .{base}) else base;
    return std.fmt.allocPrint(a, "{s} · sharing with {s} unconfirmed", .{ base, pending });
}

pub const Reason = enum { network, unavailable, rate_limited, storage_full, api_quota, api_disabled, local_quota, access_expired, not_connected, permission_denied, file_unavailable, request_rejected, sharing_policy, sharing_blocked, sharing_unconfirmed, verification_pending, upload_incomplete, file_changed, recipients_changed, bcc, preparation_full, preparation_active, retired, budget_expired, interrupted, stopped, other };
pub fn reasonOf(code: []const u8) Reason {
    // Typed codes the backend emits for Drive preparation, including those
    // mapped from Drive's error reasons (drive_prepare.zig, store.zig,
    // transport errors); unknown codes are shown verbatim.
    const table = [_]struct { code: []const u8, reason: Reason }{
        .{ .code = "DriveNetwork", .reason = .network },
        .{ .code = "NetworkUnavailable", .reason = .network },
        .{ .code = "NetworkUnreachable", .reason = .network },
        .{ .code = "NetworkFailure", .reason = .network },
        .{ .code = "ConnectionFailed", .reason = .network },
        .{ .code = "ConnectionRefused", .reason = .network },
        .{ .code = "ConnectionResetByPeer", .reason = .network },
        .{ .code = "ConnectionTimedOut", .reason = .network },
        .{ .code = "TemporaryNameServerFailure", .reason = .network },
        .{ .code = "Timeout", .reason = .network },
        .{ .code = "DriveUnavailable", .reason = .unavailable },
        .{ .code = "DriveServerError", .reason = .unavailable },
        .{ .code = "DrivePreparationFailed", .reason = .unavailable },
        .{ .code = "RateLimited", .reason = .rate_limited },
        .{ .code = "DriveStorageFull", .reason = .storage_full },
        // dailyLimitExceeded: the project's Drive API quota, not storage.
        .{ .code = "DriveQuotaExceeded", .reason = .api_quota },
        .{ .code = "DriveApiDisabled", .reason = .api_disabled },
        .{ .code = "DiskQuotaExceeded", .reason = .local_quota },
        .{ .code = "DriveAccessExpired", .reason = .access_expired },
        .{ .code = "NotConnected", .reason = .access_expired },
        .{ .code = "InvalidGrant", .reason = .access_expired },
        .{ .code = "DriveNotConnected", .reason = .not_connected },
        // A generic 403 is not a grant problem; Connect Drive can't fix it.
        .{ .code = "DrivePermissionDenied", .reason = .permission_denied },
        .{ .code = "PermissionDenied", .reason = .permission_denied },
        .{ .code = "DriveFileUnavailable", .reason = .file_unavailable },
        .{ .code = "DriveRequestRejected", .reason = .request_rejected },
        .{ .code = "DriveSharingPolicy", .reason = .sharing_policy },
        .{ .code = "DriveSharingBlocked", .reason = .sharing_blocked },
        .{ .code = "DriveSharingOutcomeUnknown", .reason = .sharing_unconfirmed },
        .{ .code = "DriveSharingIncomplete", .reason = .sharing_unconfirmed },
        .{ .code = "DriveVerificationPending", .reason = .verification_pending },
        .{ .code = "DriveUploadExpired", .reason = .upload_incomplete },
        .{ .code = "DriveUploadIncomplete", .reason = .upload_incomplete },
        .{ .code = "DriveFileChanged", .reason = .file_changed },
        .{ .code = "DriveUnexpectedAccess", .reason = .file_changed },
        .{ .code = "DrivePermissionsTooLarge", .reason = .file_changed },
        .{ .code = "DriveRecipientsChanged", .reason = .recipients_changed },
        .{ .code = "DriveBccUnsupported", .reason = .bcc },
        .{ .code = "DrivePreparationFull", .reason = .preparation_full },
        // A new send refused while an earlier one of the same draft is unsettled.
        .{ .code = "DrivePreparationActive", .reason = .preparation_active },
        // Permanently fenced before Gmail (kind drivePreparationRetired).
        .{ .code = "DrivePreparationRetired", .reason = .retired },
        .{ .code = "DriveSubmissionBudgetExpired", .reason = .budget_expired },
        .{ .code = "InterruptedPreparation", .reason = .interrupted },
        .{ .code = "SendCanceledBeforeSubmission", .reason = .stopped },
        .{ .code = "PreparationStopped", .reason = .stopped },
        .{ .code = "Canceled", .reason = .stopped },
    };
    for (table) |entry| if (std.mem.eql(u8, code, entry.code)) return entry.reason;
    return .other;
}
/// What Drive reported and what helps, never a cause Drive didn't state.
/// Retry wording appears only when the backend allows a retry.
pub fn reason(a: std.mem.Allocator, failure: *const Failure, account: []const u8) ![]const u8 {
    const code = failure.code.slice();
    const unconfirmed = for (failure.files[0..failure.count]) |*file| {
        if (file.unconfirmed.len > 0) break file.unconfirmed.slice();
    } else "";
    return switch (reasonOf(code)) {
        .network => "Upload interrupted (network).",
        .unavailable => "Drive is unavailable right now.",
        .rate_limited => if (failure.can_retry) "Drive is limiting requests right now. Wait a few minutes, then retry preparation." else "Drive is limiting requests right now.",
        .storage_full => std.fmt.allocPrint(a, "Drive storage is full for {s}. Free up space in Drive, then send again.", .{account}),
        .api_quota => "Drive's daily request limit for Omagma's Google Cloud project was reached; this isn't your Drive storage. Send again later.",
        .api_disabled => "The Drive API isn't enabled for the Google Cloud project behind Omagma's sign-in. Enable it there, then send again.",
        .local_quota => "Omagma's local storage limit is full. Free cache space, then retry.",
        .access_expired => std.fmt.allocPrint(a, "Drive access expired for {s}.", .{account}),
        .not_connected => std.fmt.allocPrint(a, "Drive isn't connected for {s}.", .{account}),
        .permission_denied => std.fmt.allocPrint(a, "Drive denied this request for {s}. Check the files in Drive, or attach them instead.", .{account}),
        .file_unavailable => "Drive can't find a file prepared for this message. Check Drive, or attach the files instead.",
        .request_rejected => "Drive rejected a request for this message. Attach the files instead.",
        .sharing_policy => "Your organization's policy blocked this Drive request. Attach the files instead, or ask your administrator.",
        // invalidSharingRequest has several causes, and the grant may still
        // have applied: never claim a cause or that nothing was shared.
        .sharing_blocked => std.fmt.allocPrint(a, "Drive returned an error while sharing{s}{s}; sharing isn't confirmed. Drive doesn't say why: the address may not have a Google account, or a sharing setting may block it. Attach the files instead or change recipients.", .{ if (unconfirmed.len > 0) @as([]const u8, " with ") else "", unconfirmed }),
        .sharing_unconfirmed => "Sharing wasn't confirmed for every recipient.",
        .verification_pending => "Drive is still verifying an uploaded file. Retry in a moment.",
        .upload_incomplete => "A Drive upload didn't finish.",
        // A file may already have been shared earlier; never claim it wasn't.
        .file_changed => "A Drive file changed or has unexpected access. Sending stopped; check the file in Drive.",
        .recipients_changed => "Recipients changed after files were shared. Review the draft again.",
        .bcc => "Drive can't be used while Bcc has recipients.",
        // Only finished, cancelled or discarded sends free entries; sends whose
        // Gmail outcome is unknown stay tracked so they're never repeated.
        .preparation_full => std.fmt.allocPrint(a, "Too many unfinished Drive sends are tracked for {s}. Cancel queued sends, or edit or discard drafts whose send stopped, then {s}. Sends with an unknown Gmail outcome stay protected.", .{ account, if (failure.can_retry) @as([]const u8, "retry preparation") else "send again" }),
        // The earlier send keeps its own retry; this refused one never uploaded.
        .preparation_active => "An earlier send of this draft still has unfinished Drive preparation, so this send didn't start and nothing was uploaded for it. Retry that earlier send, or edit or discard the draft to retire it, then send again.",
        // Retired sends never reached Gmail; files keep their frozen access.
        .retired => "This send was retired because its draft was edited or discarded, or its queued send was cancelled; it can't resume. Files already in Drive stay there with the access shown below, and a new send uploads new copies.",
        .budget_expired => "Drive preparation ran out of time, so Omagma stopped before contacting Gmail; this send can't resume. Files already in Drive stay there with the access shown below.",
        .interrupted => "Preparation was interrupted before Gmail (Omagma stopped or restarted).",
        .stopped => "Sending stopped before Gmail.",
        .other => if (code.len > 0) std.fmt.allocPrint(a, "Drive preparation failed ({s}).", .{code}) else "Drive preparation failed.",
    };
}
/// The status line for a permanently fenced Drive send. It is never a
/// Gmail rejection; null for every other code.
pub fn retiredStatus(code: []const u8) ?[]const u8 {
    return switch (reasonOf(code)) {
        .retired => "Message not sent · this Drive send was retired · draft retained",
        .budget_expired => "Message not sent · Drive preparation ran out of time before Gmail · draft retained",
        else => null,
    };
}

/// Upload percentage and sizes with one decimal MiB.
pub fn uploadLine(a: std.mem.Allocator, completed: usize, total: usize) ![]const u8 {
    const percent = if (total == 0) @as(usize, 0) else @min(@as(usize, 100), completed * 100 / total);
    const mib: u64 = 1024 * 1024;
    const done_tenths = (@as(u64, completed) * 10) / mib;
    const total_tenths = (@as(u64, total) * 10 + mib / 2) / mib;
    return std.fmt.allocPrint(a, "uploading {d}% ({d}.{d} of {d}.{d} MiB)", .{ percent, done_tenths / 10, done_tenths % 10, total_tenths / 10, total_tenths % 10 });
}

test "send drive: progress mailbox keeps per-file states and ignores mail phases" {
    var mailbox: Mailbox = .{};
    const Fetch = enum { metadata, bodies, drive_reserving, drive_uploading, drive_sharing, mail_submitting };
    try std.testing.expectEqual(@as(?Phase, null), phaseOf(Fetch.bodies));
    try std.testing.expectEqual(@as(?Phase, .uploading), phaseOf(Fetch.drive_uploading));
    mailbox.publish(.reserving, null, 2, 0, 2);
    mailbox.publish(.uploading, 3, null, 13 * 1024 * 1024, 31 * 1024 * 1024);
    mailbox.publish(.uploading, 1, null, 5, 5);
    var state = mailbox.snapshot();
    try std.testing.expectEqual(@as(?Phase, .uploading), state.phase);
    try std.testing.expectEqual(@as(usize, 2), state.file_count);
    try std.testing.expectEqual(FileState.uploading, state.find(3).?.state);
    try std.testing.expectEqual(FileState.uploaded, state.find(1).?.state);
    mailbox.publish(.sharing, 3, null, 1, 3);
    state = mailbox.snapshot();
    try std.testing.expectEqual(FileState.sharing, state.find(3).?.state);
    mailbox.reset();
    try std.testing.expectEqual(@as(usize, 0), mailbox.snapshot().count);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("uploading 41% (13.0 of 31.0 MiB)", try uploadLine(arena.allocator(), 13 * 1024 * 1024, 31 * 1024 * 1024));
}

test "send drive: receipts report confirmed and unconfirmed sharing exactly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\[{"index":0,"filename":"report-final.pdf","size":32505856,"state":"shared","driveFileId":"f1","sharedWith":["peer@example.test","second@example.test"],"sharingUnconfirmedWith":"third@example.test"},
        \\{"index":2,"filename":"raw.zip","size":4,"state":"uploaded","driveFileId":"f2","sharedWith":[]},
        \\{"index":3,"filename":"notes.txt","size":4,"state":"sharing","driveFileId":"f3","sharedWith":[],"sharingUnconfirmedWith":"peer@example.test"},
        \\{"index":4,"filename":"deck.pdf","size":4,"state":"uncertain","driveFileId":"f4","sharedWith":[]}]
    ;
    var failure: Failure = .{ .kind = .stopped };
    try failure.code.set("DriveSharingBlocked");
    try parseFiles(&failure, try std.json.parseFromSliceLeaky(Value, a, raw, .{}));
    try std.testing.expectEqual(@as(usize, 4), failure.count);
    try std.testing.expect(failure.anyShared());
    try std.testing.expectEqualStrings("shared with peer@example.test, second@example.test · sharing with third@example.test unconfirmed", try receipt(a, &failure.files[0]));
    try std.testing.expectEqualStrings("uploaded · private", try receipt(a, &failure.files[1]));
    // A grant that may have applied is never reported as private.
    try std.testing.expectEqualStrings("uploaded · sharing with peer@example.test unconfirmed", try receipt(a, &failure.files[2]));
    try std.testing.expectEqualStrings("uploaded · sharing not confirmed", try receipt(a, &failure.files[3]));
    // invalidSharingRequest names no cause and may have applied: no policy
    // claim, no "not shared", only that sharing isn't confirmed.
    try std.testing.expectEqualStrings("Drive returned an error while sharing with third@example.test; sharing isn't confirmed. Drive doesn't say why: the address may not have a Google account, or a sharing setting may block it. Attach the files instead or change recipients.", try reason(a, &failure, "self@example.test"));
    // Codes emitted by the backend's Drive preparation and queue recovery,
    // including the typed codes mapped from Drive's error reasons.
    for ([_]struct { code: []const u8, text: []const u8 }{
        .{ .code = "InterruptedPreparation", .text = "Preparation was interrupted before Gmail (Omagma stopped or restarted)." },
        .{ .code = "DiskQuotaExceeded", .text = "Omagma's local storage limit is full. Free cache space, then retry." },
        .{ .code = "DriveVerificationPending", .text = "Drive is still verifying an uploaded file. Retry in a moment." },
        .{ .code = "NotConnected", .text = "Drive access expired for self@example.test." },
        .{ .code = "DriveAccessExpired", .text = "Drive access expired for self@example.test." },
        .{ .code = "DriveNotConnected", .text = "Drive isn't connected for self@example.test." },
        .{ .code = "DriveSharingOutcomeUnknown", .text = "Sharing wasn't confirmed for every recipient." },
        .{ .code = "DriveStorageFull", .text = "Drive storage is full for self@example.test. Free up space in Drive, then send again." },
        .{ .code = "DriveQuotaExceeded", .text = "Drive's daily request limit for Omagma's Google Cloud project was reached; this isn't your Drive storage. Send again later." },
        .{ .code = "DriveApiDisabled", .text = "The Drive API isn't enabled for the Google Cloud project behind Omagma's sign-in. Enable it there, then send again." },
        .{ .code = "DrivePermissionDenied", .text = "Drive denied this request for self@example.test. Check the files in Drive, or attach them instead." },
        .{ .code = "DriveFileUnavailable", .text = "Drive can't find a file prepared for this message. Check Drive, or attach the files instead." },
        .{ .code = "DriveRequestRejected", .text = "Drive rejected a request for this message. Attach the files instead." },
        .{ .code = "DriveSharingPolicy", .text = "Your organization's policy blocked this Drive request. Attach the files instead, or ask your administrator." },
        .{ .code = "DriveServerError", .text = "Drive is unavailable right now." },
        .{ .code = "RateLimited", .text = "Drive is limiting requests right now." },
        .{ .code = "DrivePreparationFull", .text = "Too many unfinished Drive sends are tracked for self@example.test. Cancel queued sends, or edit or discard drafts whose send stopped, then send again. Sends with an unknown Gmail outcome stay protected." },
        .{ .code = "DrivePreparationActive", .text = "An earlier send of this draft still has unfinished Drive preparation, so this send didn't start and nothing was uploaded for it. Retry that earlier send, or edit or discard the draft to retire it, then send again." },
        .{ .code = "SomethingNew", .text = "Drive preparation failed (SomethingNew)." },
    }) |case| {
        try failure.code.set(case.code);
        try std.testing.expectEqualStrings(case.text, try reason(a, &failure, "self@example.test"));
    }
    // Retired sends have their own status; nothing else does.
    try std.testing.expect(retiredStatus("DrivePreparationRetired") != null and retiredStatus("DriveSubmissionBudgetExpired") != null);
    try std.testing.expect(retiredStatus("SendCanceledBeforeSubmission") == null and retiredStatus("DriveSharingBlocked") == null);
    // Retry advice follows canRetryPreparation, never the code alone.
    failure.can_retry = true;
    try failure.code.set("RateLimited");
    try std.testing.expectEqualStrings("Drive is limiting requests right now. Wait a few minutes, then retry preparation.", try reason(a, &failure, "self@example.test"));
    failure.count = 0;
    try failure.code.set("DriveSharingBlocked");
    try std.testing.expectEqualStrings("Drive returned an error while sharing; sharing isn't confirmed. Drive doesn't say why: the address may not have a Google account, or a sharing setting may block it. Attach the files instead or change recipients.", try reason(a, &failure, "self@example.test"));
    var pinned: Pinned = .{};
    try pinned.begin("Q3 report", "self@example.test");
    for (0..30) |index| try pinned.add(index, "photo.jpg", 4, index == 29);
    try std.testing.expectEqual(@as(usize, 1), pinned.drive_count);
    try std.testing.expect(pinned.files[pinned.count - 1].drive);
    try std.testing.expectEqual(@as(usize, 25), pinned.attached_hidden);
    try std.testing.expectEqualStrings("ab", clip("ab\xc3\xa9", 3));
}
