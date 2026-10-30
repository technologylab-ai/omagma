//! Private, resumable Drive preparation. Never sends mail and never retries a
//! mutation in the same invocation. A later explicit attempt reconciles IDs,
//! content and permissions before continuing. Session URLs stay in this ledger.
const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const http = @import("../http_client.zig");
const Store = @import("store.zig").Store;
const blob = @import("attachment_blob.zig");
const A = std.mem.Allocator;
const ledger_limit = 1024 * 1024;
const file_fields = "id,name,mimeType,size,sha256Checksum,ownedByMe,trashed,driveId,appProperties";
pub const Phase = enum { reserved, uploading, uploaded, sharing, shared };
pub const Entry = struct {
    operationId: []const u8,
    sourceDigest: []const u8,
    index: usize,
    fileId: []const u8,
    blobId: []const u8,
    filename: []const u8,
    mimeType: []const u8,
    size: usize,
    recipientDigest: []const u8,
    phase: Phase = .reserved,
    session: []const u8 = "",
    sharedBits: []const u8 = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    uncertainRecipient: ?usize = null,
};
const TargetSet = struct { digest: []const u8, addresses: []const []const u8 };
const Ledger = struct { schema: u8 = 1, account: []const u8, entries: []Entry = &.{}, targets: []TargetSet = &.{} };
pub const Transport = struct {
    ctx: *anyopaque,
    requestFn: *const fn (*anyopaque, std.http.Method, []const u8, ?[]const u8, ?http.Source, usize, []const u8, *http.DriveHeaders) anyerror!http.Response,
    fn request(self: Transport, method: std.http.Method, url: []const u8, body: ?[]const u8, source: ?http.Source, size: usize, mime_type: []const u8, headers: *http.DriveHeaders) !http.Response {
        return self.requestFn(self.ctx, method, url, body, source, size, mime_type, headers);
    }
};
pub const Network = struct {
    session: @import("gmail.zig").NetworkSession = undefined,
    pub fn init(self: *Network, io: std.Io, a: A, config: *const @import("../config.zig").Config, account: []const u8, req: j.Value, deadline: std.Io.Clock.Timestamp) !void {
        try self.session.initDrivePreparation(io, a, config, account, req, deadline);
    }
    pub fn close(self: *Network) void {
        self.session.close();
    }
    pub fn transport(self: *Network) Transport {
        return .{ .ctx = self, .requestFn = request };
    }
    const Bytes = struct {
        bytes: []const u8,
        offset: usize = 0,
        fn read(ctx: *anyopaque, out: []u8) !usize {
            const self: *Bytes = @ptrCast(@alignCast(ctx));
            const n = @min(out.len, self.bytes.len - self.offset);
            @memcpy(out[0..n], self.bytes[self.offset..][0..n]);
            self.offset += n;
            return n;
        }
    };
    fn request(ctx: *anyopaque, method: std.http.Method, url: []const u8, body: ?[]const u8, source: ?http.Source, size: usize, mime_type: []const u8, headers: *http.DriveHeaders) !http.Response {
        const self: *Network = @ptrCast(@alignCast(ctx));
        var bytes: Bytes = .{ .bytes = body orelse "" };
        const input: ?http.Source = if (body != null) .{ .ctx = &bytes, .readFn = Bytes.read } else source;
        const response = try self.session.client.requestDrive(url, method, self.session.network.access, input, if (body) |b| b.len else size, mime_type, self.session.response[0 .. 256 * 1024], headers);
        if (response.status == 401) self.session.invalidateAccess();
        return response;
    }
};
fn id(value: []const u8) !void {
    if (value.len == 0 or value.len > 256) return error.InvalidDriveFileId;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidDriveFileId;
}
fn accepted(response: http.Response) !void {
    if (response.status >= 200 and response.status < 300) return;
    if (response.status == 401) return error.DriveAccessExpired;
    const reason = responseReason(response.body);
    switch (reason) {
        .storage => return error.DriveStorageFull,
        .quota => return error.DriveQuotaExceeded,
        .rate => return error.RateLimited,
        .policy => return error.DriveSharingPolicy,
        .sharing => return error.DriveSharingBlocked,
        .disabled => return error.DriveApiDisabled,
        else => {},
    }
    return switch (response.status) {
        400 => error.DriveRequestRejected,
        403 => error.DrivePermissionDenied,
        404 => error.DriveFileUnavailable,
        429 => error.RateLimited,
        500...599 => error.DriveServerError,
        else => error.DrivePreparationFailed,
    };
}
const ProviderReason = enum { storage, quota, rate, policy, sharing, disabled, other };
fn responseReason(body: []const u8) ProviderReason {
    // Only categorical reasons leave this function. Never expose Google's
    // message text, which may include file names, addresses or request data.
    var scratch: [16 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const value = std.json.parseFromSliceLeaky(j.Value, fixed.allocator(), body, .{}) catch return .other;
    const failure = j.get(value, "error") orelse return .other;
    for ([_][]const u8{ "errors", "details" }) |key| {
        const list = j.get(failure, key) orelse continue;
        if (list != .array) continue;
        for (list.array.items[0..@min(32, list.array.items.len)]) |item| {
            const reason = j.text(item, "reason");
            if (std.mem.eql(u8, reason, "storageQuotaExceeded")) return .storage;
            if (std.mem.eql(u8, reason, "dailyLimitExceeded")) return .quota;
            if (std.mem.eql(u8, reason, "rateLimitExceeded") or std.mem.eql(u8, reason, "userRateLimitExceeded") or std.mem.eql(u8, reason, "sharingRateLimitExceeded")) return .rate;
            if (std.mem.eql(u8, reason, "domainPolicy")) return .policy;
            if (std.mem.eql(u8, reason, "invalidSharingRequest")) return .sharing;
            if (std.mem.eql(u8, reason, "accessNotConfigured") or std.mem.eql(u8, reason, "SERVICE_DISABLED")) return .disabled;
        }
    }
    return .other;
}
pub fn retryablePreparation(code: []const u8) bool {
    for ([_][]const u8{ "DriveStorageFull", "DriveQuotaExceeded", "DriveSharingPolicy", "DriveSharingBlocked", "DriveApiDisabled", "DrivePermissionDenied", "DriveFileUnavailable", "DriveRequestRejected", "DrivePreparationRetired", "DrivePreparationActive" }) |permanent| if (std.mem.eql(u8, code, permanent)) return false;
    return true;
}
fn json(a: A, response: http.Response) !j.Value {
    try accepted(response);
    if (response.body.len == 0) return error.InvalidProviderResponse;
    return std.json.parseFromSliceLeaky(j.Value, a, response.body, .{ .allocate = .alloc_if_needed });
}
pub fn recipientSet(a: A, draft: t.Draft) ![]const []const u8 {
    if (draft.bcc.len != 0) return error.DriveBccUnsupported;
    var values: std.ArrayList([]const u8) = .empty;
    for ([_][]const t.Address{ draft.to, draft.cc }) |list| for (list) |recipient| {
        try @import("recipients.zig").validateAddress(recipient.address);
        const lower = try std.ascii.allocLowerString(a, recipient.address);
        var duplicate = false;
        for (values.items) |previous| duplicate = duplicate or std.mem.eql(u8, previous, lower);
        if (!duplicate) try values.append(a, lower);
    };
    if (values.items.len == 0) return error.MissingRecipient;
    std.mem.sort([]const u8, values.items, {}, struct {
        fn less(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.less);
    return values.toOwnedSlice(a);
}
pub const Book = struct {
    store: *Store,
    a: A,
    ledger: Ledger,
    progress_sink: ?t.ProgressSink = null,
    progress_files: usize = 0,
    pub fn load(a: A, store: *Store) !Book {
        const raw = try store.readDocument(a, "drive-uploads.json", ledger_limit);
        const ledger = if (raw) |bytes| try std.json.parseFromSliceLeaky(Ledger, a, bytes, .{ .allocate = .alloc_if_needed }) else Ledger{ .account = store.state.account };
        if (ledger.schema != 1 or !std.mem.eql(u8, ledger.account, store.state.account) or ledger.entries.len > 128) return error.InvalidDriveLedger;
        if (ledger.targets.len > 128) return error.InvalidDriveLedger;
        for (ledger.targets, 0..) |target, target_index| {
            if (target.addresses.len == 0 or target.addresses.len > t.Limits.recipients) return error.InvalidDriveLedger;
            try @import("draft_codec.zig").validateAttachmentHandle(target.digest);
            const actual = Store.hash(try j.encodeAlloc(a, target.addresses, .{}));
            if (!std.mem.eql(u8, &actual, target.digest)) return error.InvalidDriveLedger;
            for (target.addresses, 0..) |address, index| {
                try @import("recipients.zig").validateAddress(address);
                if (index != 0 and !std.mem.lessThan(u8, target.addresses[index - 1], address)) return error.InvalidDriveLedger;
            }
            for (ledger.targets[0..target_index]) |previous| if (std.mem.eql(u8, previous.digest, target.digest)) return error.InvalidDriveLedger;
        }
        for (ledger.entries) |entry| {
            try id(entry.fileId);
            try @import("draft_codec.zig").validateAttachmentHandle(entry.blobId);
            try @import("draft_codec.zig").validateAttachmentHandle(entry.sourceDigest);
            try @import("draft_codec.zig").validateAttachmentHandle(entry.recipientDigest);
            try @import("mime.zig").validateAttachment(entry.filename, entry.mimeType);
            if (entry.size > t.Limits.disk_hard or entry.index >= t.Limits.attachments or entry.operationId.len == 0 or entry.operationId.len > 256) return error.InvalidDriveLedger;
            if (entry.session.len != 0) try http.validateDriveDestination(try std.Uri.parse(entry.session));
            if (entry.sharedBits.len != 128 or (entry.uncertainRecipient != null and entry.uncertainRecipient.? >= t.Limits.recipients)) return error.InvalidDriveLedger;
            for (entry.sharedBits) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidDriveLedger;
        }
        return .{ .store = store, .a = a, .ledger = ledger };
    }
    fn report(self: *Book, entry: Entry, phase: t.FetchPhase, completed: usize, total: usize) !void {
        if (self.progress_sink) |sink| sink.report(.{ .phase = phase, .completed = completed, .total = total, .fileIndex = entry.index, .fileCount = self.progress_files });
        try self.store.io.checkCancel();
    }
    fn save(self: *Book) !void {
        var temporary: std.heap.ArenaAllocator = .init(self.a);
        defer temporary.deinit();
        const bytes = try j.encodeAlloc(temporary.allocator(), self.ledger, .{});
        if (bytes.len > ledger_limit) return error.DrivePreparationFull;
        try self.store.writeDocument("drive-uploads.json", bytes);
    }
    pub fn reserve(self: *Book, transport: Transport, operation: []const u8, digest: []const u8, index: usize, file: t.Attachment, recipients: []const []const u8) !usize {
        const handle = file.blobId orelse return error.InvalidAttachmentDelivery;
        var temporary: std.heap.ArenaAllocator = .init(self.a);
        defer temporary.deinit();
        const a = temporary.allocator();
        const recipient_hash = Store.hash(try j.encodeAlloc(a, recipients, .{}));
        try self.compact(&recipient_hash);
        for (self.ledger.entries) |entry| if (std.mem.eql(u8, entry.operationId, operation) and !std.mem.eql(u8, entry.sourceDigest, digest)) return error.OperationConflict;
        var has_targets = false;
        for (self.ledger.targets) |target| has_targets = has_targets or std.mem.eql(u8, target.digest, &recipient_hash);
        if (!has_targets) {
            if (recipients.len == 0 or recipients.len > t.Limits.recipients or self.ledger.targets.len >= 128) return error.DrivePreparationFull;
            var targets: std.ArrayList(TargetSet) = .empty;
            try targets.appendSlice(self.a, self.ledger.targets);
            const owned = try self.a.alloc([]const u8, recipients.len);
            for (recipients, owned) |address, *destination| destination.* = try self.a.dupe(u8, address);
            try targets.append(self.a, .{ .digest = try self.a.dupe(u8, &recipient_hash), .addresses = owned });
            self.ledger.targets = targets.items;
            try self.save();
        }
        for (self.ledger.entries, 0..) |entry, slot| {
            if (!std.mem.eql(u8, entry.blobId, handle) or entry.size != file.size or !std.mem.eql(u8, entry.filename, file.filename) or !std.mem.eql(u8, entry.mimeType, file.mimeType)) continue;
            // One operation owns each resumable identity. Another live send
            // must not steal its only retry/receipt record, even while private.
            if (!std.mem.eql(u8, entry.operationId, operation) or entry.index != index) continue;
            if (@backingInt(entry.phase) < @backingInt(Phase.sharing) or std.mem.eql(u8, entry.recipientDigest, &recipient_hash)) {
                self.ledger.entries[slot].operationId = try self.a.dupe(u8, operation);
                self.ledger.entries[slot].sourceDigest = try self.a.dupe(u8, digest);
                self.ledger.entries[slot].recipientDigest = try self.a.dupe(u8, &recipient_hash);
                self.ledger.entries[slot].index = index;
                try self.pruneTargets(&recipient_hash);
                try self.save();
                return slot;
            }
        }
        if (self.ledger.entries.len >= 128) return error.DrivePreparationFull;
        // Reserve ledger capacity before contacting the provider, including a
        // worst-case private session URL and immutable source identity.
        const budget = @import("gmail_decode.zig").serializedBytes(self.ledger) + 8192;
        if (budget > ledger_limit) return error.DrivePreparationFull;
        var headers: http.DriveHeaders = .{};
        const generated = try json(a, try transport.request(.GET, "https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files", null, null, 0, "application/json", &headers));
        const ids = j.get(generated, "ids") orelse return error.InvalidProviderResponse;
        if (ids != .array or ids.array.items.len != 1) return error.InvalidProviderResponse;
        const file_id = try j.string(ids.array.items[0]);
        try id(file_id);
        var list: std.ArrayList(Entry) = .empty;
        try list.appendSlice(self.a, self.ledger.entries);
        try list.append(self.a, .{ .operationId = try self.a.dupe(u8, operation), .sourceDigest = try self.a.dupe(u8, digest), .index = index, .fileId = try self.a.dupe(u8, file_id), .blobId = try self.a.dupe(u8, handle), .filename = try self.a.dupe(u8, file.filename), .mimeType = try self.a.dupe(u8, file.mimeType), .size = file.size, .recipientDigest = try self.a.dupe(u8, &recipient_hash) });
        self.ledger.entries = list.items;
        try self.save();
        return self.ledger.entries.len - 1;
    }
    pub fn compact(self: *Book, keep_target: []const u8) !void {
        var retained: std.ArrayList(Entry) = .empty;
        for (self.ledger.entries) |entry| {
            if (try self.store.findOperation(self.a, entry.operationId)) |record| if ((std.mem.eql(u8, record.outcome, "applied") or std.mem.eql(u8, record.outcome, "rejected")) and record.driveFiles != null and std.mem.eql(u8, record.hash, entry.sourceDigest)) continue;
            try retained.append(self.a, entry);
        }
        const changed = retained.items.len != self.ledger.entries.len;
        self.ledger.entries = retained.items;
        const target_count = self.ledger.targets.len;
        try self.pruneTargets(keep_target);
        if (changed or target_count != self.ledger.targets.len) try self.save();
    }
    fn pruneTargets(self: *Book, keep_target: []const u8) !void {
        var retained: std.ArrayList(TargetSet) = .empty;
        for (self.ledger.targets) |target| {
            var needed = std.mem.eql(u8, target.digest, keep_target);
            for (self.ledger.entries) |entry| needed = needed or std.mem.eql(u8, target.digest, entry.recipientDigest);
            if (needed) try retained.append(self.a, target);
        }
        self.ledger.targets = retained.items;
    }
    pub fn reserveFixture(self: *Book, operation: []const u8, digest: []const u8, index: usize, file: t.Attachment, recipients: []const []const u8) !usize {
        if (!self.store.options.fixtures) return error.FixtureAccountRequired;
        const Fixture = struct {
            a: A,
            file_id: []const u8,
            fn request(ctx: *anyopaque, method: std.http.Method, url: []const u8, _: ?[]const u8, _: ?http.Source, _: usize, _: []const u8, _: *http.DriveHeaders) !http.Response {
                const state: *@This() = @ptrCast(@alignCast(ctx));
                if (method != .GET or std.mem.indexOf(u8, url, "/generateIds?") == null) return error.InvalidFixture;
                return .{ .status = 200, .body = try j.encodeAlloc(state.a, .{ .ids = [_][]const u8{state.file_id} }, .{}) };
            }
        };
        const operation_hash = Store.hash(operation);
        var fixture: Fixture = .{ .a = self.a, .file_id = try std.fmt.allocPrint(self.a, "synthetic-{s}-{d}", .{ operation_hash, index }) };
        return self.reserve(.{ .ctx = &fixture, .requestFn = Fixture.request }, operation, digest, index, file, recipients);
    }
    pub fn completeFixture(self: *Book, slots: []const usize, recipients: []const []const u8, interrupted_upload: bool, interrupted_share: bool, slow_progress: bool) !void {
        if (!self.store.options.fixtures) return error.FixtureAccountRequired;
        for (slots) |slot| {
            const entry = &self.ledger.entries[slot];
            if (interrupted_upload and entry.phase == .reserved) {
                entry.phase = .uploading;
                try self.save();
                return error.Timeout;
            }
            if (slow_progress and @backingInt(entry.phase) < @backingInt(Phase.uploaded)) {
                entry.phase = .uploading;
                try self.save();
                for (0..100) |step| {
                    try self.report(entry.*, .drive_uploading, entry.size * step / 100, entry.size);
                    try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(100) }).sleep(self.store.io);
                }
            }
            if (@backingInt(entry.phase) < @backingInt(Phase.uploaded)) entry.phase = .uploaded;
        }
        try self.save();
        for (slots) |slot| {
            const entry = &self.ledger.entries[slot];
            if (interrupted_share and entry.phase == .uploaded) {
                entry.phase = .sharing;
                if (recipients.len > 1) try self.markShared(entry, 0);
                entry.uncertainRecipient = if (recipients.len > 1) 1 else 0;
                try self.save();
                return error.Timeout;
            }
            for (recipients, 0..) |_, index| {
                try self.markShared(entry, index);
                if (slow_progress) {
                    try self.save();
                    try self.report(entry.*, .drive_sharing, index + 1, recipients.len);
                    try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(100) }).sleep(self.store.io);
                }
            }
            entry.phase = .shared;
            entry.uncertainRecipient = null;
        }
        try self.save();
    }
    pub fn slotFor(self: *const Book, file_id: []const u8) !usize {
        for (self.ledger.entries, 0..) |entry, slot| if (std.mem.eql(u8, entry.fileId, file_id)) return slot;
        return error.InvalidDriveLedger;
    }
    fn metadata(self: *Book, transport: Transport, entry: Entry, a: A) !?j.Value {
        _ = self;
        var headers: http.DriveHeaders = .{};
        const url = try std.fmt.allocPrint(a, "https://www.googleapis.com/drive/v3/files/{s}?fields={s}", .{ entry.fileId, file_fields });
        const response = try transport.request(.GET, url, null, null, 0, "application/json", &headers);
        if (response.status == 404) return null;
        const value = try json(a, response);
        if (!std.mem.eql(u8, j.text(value, "id"), entry.fileId) or !std.mem.eql(u8, j.text(value, "name"), entry.filename) or !std.mem.eql(u8, j.text(value, "mimeType"), entry.mimeType) or !try j.boolean(value, "ownedByMe", false) or try j.boolean(value, "trashed", false) or j.text(value, "driveId").len != 0) return error.DriveFileChanged;
        const properties = j.get(value, "appProperties") orelse return error.DriveFileChanged;
        if (!std.mem.eql(u8, j.text(properties, "omagmaSha256"), entry.blobId)) return error.DriveFileChanged;
        return value;
    }
    fn complete(entry: Entry, value: j.Value) !bool {
        const size = std.fmt.parseInt(usize, j.text(value, "size"), 10) catch return error.InvalidProviderResponse;
        if (size == entry.size and j.text(value, "sha256Checksum").len == 0 and entry.phase != .reserved) return error.DriveVerificationPending;
        return size == entry.size and std.mem.eql(u8, j.text(value, "sha256Checksum"), entry.blobId);
    }
    pub fn upload(self: *Book, transport: Transport, slot: usize, file: t.Attachment) !void {
        if (slot >= self.ledger.entries.len) return error.InvalidDriveLedger;
        var entry = &self.ledger.entries[slot];
        if (!std.mem.eql(u8, file.blobId orelse "", entry.blobId) or file.size != entry.size) return error.AttachmentChanged;
        var temporary: std.heap.ArenaAllocator = .init(self.a);
        defer temporary.deinit();
        const a = temporary.allocator();
        if (@backingInt(entry.phase) < @backingInt(Phase.uploaded)) try self.report(entry.*, .drive_uploading, 0, entry.size);
        const current = try self.metadata(transport, entry.*, a);
        if (current) |value| if (try complete(entry.*, value)) {
            if (@backingInt(entry.phase) < @backingInt(Phase.sharing)) {
                _ = try self.permissions(transport, entry.*, &.{}, a);
                try self.report(entry.*, .drive_uploading, entry.size, entry.size);
            }
            if (@backingInt(entry.phase) < @backingInt(Phase.uploaded)) {
                entry.phase = .uploaded;
                entry.session = "";
                try self.save();
            }
            return;
        };
        if (@backingInt(entry.phase) >= @backingInt(Phase.uploaded)) return error.DriveFileChanged;
        if (current) |value| if (j.text(value, "sha256Checksum").len != 0 and !std.mem.eql(u8, j.text(value, "size"), "0")) return error.DriveFileChanged;
        try blob.verify(self.store, file);
        if (current == null) {
            var headers: http.DriveHeaders = .{};
            const body = try j.encodeAlloc(a, .{ .id = entry.fileId, .name = entry.filename, .mimeType = entry.mimeType, .appProperties = .{ .omagmaSha256 = entry.blobId } }, .{});
            const response = try transport.request(.POST, "https://www.googleapis.com/drive/v3/files?ignoreDefaultVisibility=true&fields=id", body, null, 0, "application/json", &headers);
            try accepted(response);
        }
        _ = try self.permissions(transport, entry.*, &.{}, a);
        if (entry.session.len == 0) {
            var headers: http.DriveHeaders = .{ .upload_content_length = try std.fmt.allocPrint(a, "{d}", .{entry.size}) };
            const url = try std.fmt.allocPrint(a, "https://www.googleapis.com/upload/drive/v3/files/{s}?uploadType=resumable&fields={s}", .{ entry.fileId, file_fields });
            const response = try transport.request(.PATCH, url, "{}", null, 0, "application/json", &headers);
            try accepted(response);
            if (response.location.len == 0) return error.InvalidProviderResponse;
            entry.session = try self.a.dupe(u8, response.location);
            entry.phase = .uploading;
            try self.save();
        }
        var headers: http.DriveHeaders = .{ .content_range = try std.fmt.allocPrint(a, "bytes */{d}", .{entry.size}) };
        const status = try transport.request(.PUT, entry.session, null, null, 0, entry.mimeType, &headers);
        if (status.status == 404 or status.status == 410) {
            entry.session = "";
            entry.phase = .reserved;
            try self.save();
            return error.DriveUploadExpired;
        }
        var offset: usize = 0;
        if (status.status == 308) offset = try acknowledged(status.range, entry.size) else {
            try accepted(status);
            const value = (try self.metadata(transport, entry.*, a)) orelse return error.DriveFileChanged;
            if (!try complete(entry.*, value)) return error.DriveFileChanged;
            entry.phase = .uploaded;
            entry.session = "";
            try self.save();
            return;
        }
        try self.report(entry.*, .drive_uploading, offset, entry.size);
        var stream = try blob.Stream.init(self.store, file);
        defer stream.close();
        var scratch: [64 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var skipped: usize = 0;
        while (skipped < offset) {
            const n = try blob.Stream.read(&stream, scratch[0..@min(scratch.len, offset - skipped)]);
            if (n == 0) return error.AttachmentChanged;
            skipped += n;
        }
        while (offset < entry.size or (entry.size == 0 and offset == 0)) {
            const size = @min(8 * 1024 * 1024, entry.size - offset);
            var chunk: Chunk = .{ .stream = &stream, .remaining = size };
            const range = if (size == 0) try std.fmt.allocPrint(a, "bytes */0", .{}) else try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ offset, offset + size - 1, entry.size });
            headers = .{ .content_range = range };
            const response = try transport.request(.PUT, entry.session, null, .{ .ctx = &chunk, .readFn = Chunk.read }, size, entry.mimeType, &headers);
            if (chunk.remaining != 0) return error.BodySizeMismatch;
            offset += size;
            if (response.status == 308) {
                if (try acknowledged(response.range, entry.size) != offset or offset == entry.size) return error.InvalidDriveRange;
            } else {
                try accepted(response);
                if (offset != entry.size) return error.InvalidDriveRange;
                try self.report(entry.*, .drive_uploading, offset, entry.size);
                break;
            }
            try self.report(entry.*, .drive_uploading, offset, entry.size);
        }
        if (try blob.Stream.read(&stream, scratch[0..1]) != 0) return error.AttachmentChanged;
        stream.close();
        stream.file = null;
        stream.sealed = null;
        const final = (try self.metadata(transport, entry.*, a)) orelse return error.DriveFileChanged;
        if (!try complete(entry.*, final)) return error.DriveFileChanged;
        entry.phase = .uploaded;
        entry.session = "";
        try self.report(entry.*, .drive_uploading, entry.size, entry.size);
        try self.save();
    }
    /// Sequential permission changes, after every selected file has uploaded.
    /// Re-read complete ACLs before and after changes; unexpected access fails
    /// closed and is never silently removed or replaced with a public link.
    pub fn share(self: *Book, transport: Transport, slot: usize, recipients: []const []const u8) !void {
        if (slot >= self.ledger.entries.len) return error.InvalidDriveLedger;
        const entry = &self.ledger.entries[slot];
        if (@backingInt(entry.phase) < @backingInt(Phase.uploaded)) return error.DriveUploadIncomplete;
        var temporary: std.heap.ArenaAllocator = .init(self.a);
        defer temporary.deinit();
        const a = temporary.allocator();
        const recipient_hash = Store.hash(try j.encodeAlloc(a, recipients, .{}));
        if (!std.mem.eql(u8, &recipient_hash, entry.recipientDigest)) return error.DriveRecipientsChanged;
        const metadata_value = (try self.metadata(transport, entry.*, a)) orelse return error.DriveFileChanged;
        if (!try complete(entry.*, metadata_value)) return error.DriveFileChanged;
        const present = try self.permissions(transport, entry.*, recipients, a);
        if (entry.uncertainRecipient) |index| {
            if (index >= recipients.len) return error.InvalidDriveLedger;
            if (!present[index] and !std.ascii.eqlIgnoreCase(recipients[index], self.store.state.account)) return error.DriveSharingOutcomeUnknown;
        }
        // Persist this fence BEFORE the first permission mutation, including
        // when a lost response may already have granted a recipient access.
        entry.phase = .sharing;
        entry.sharedBits = try self.a.dupe(u8, "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
        entry.uncertainRecipient = null;
        for (recipients, present, 0..) |recipient, has_access, index| if (has_access or std.ascii.eqlIgnoreCase(recipient, self.store.state.account)) try self.markShared(entry, index);
        try self.save();
        var confirmed_count: usize = 0;
        for (recipients, present) |recipient, has_access| if (has_access or std.ascii.eqlIgnoreCase(recipient, self.store.state.account)) {
            confirmed_count += 1;
        };
        try self.report(entry.*, .drive_sharing, confirmed_count, recipients.len);
        for (recipients, 0..) |recipient, index| {
            if (present[index] or std.ascii.eqlIgnoreCase(recipient, self.store.state.account)) continue;
            var headers: http.DriveHeaders = .{};
            const url = try std.fmt.allocPrint(a, "https://www.googleapis.com/drive/v3/files/{s}/permissions?sendNotificationEmail=false&fields=id,type,role,emailAddress", .{entry.fileId});
            const body = try j.encodeAlloc(a, .{ .type = "user", .role = "reader", .emailAddress = recipient }, .{});
            entry.uncertainRecipient = index;
            try self.save();
            const response = try transport.request(.POST, url, body, null, 0, "application/json", &headers);
            if (switch (response.status) {
                // Drive documents invalidSharingRequest (400) even when a
                // grant succeeded but notification failed. Preserve uncertainty.
                401, 403, 404, 409, 412, 429 => true,
                else => false,
            }) {
                entry.uncertainRecipient = null;
                try self.save();
            }
            const value = try json(a, response);
            if (!std.mem.eql(u8, j.text(value, "type"), "user") or !std.mem.eql(u8, j.text(value, "role"), "reader") or !std.ascii.eqlIgnoreCase(j.text(value, "emailAddress"), recipient)) return error.InvalidProviderResponse;
            try self.markShared(entry, index);
            entry.uncertainRecipient = null;
            try self.save();
            confirmed_count += 1;
            try self.report(entry.*, .drive_sharing, confirmed_count, recipients.len);
        }
        try self.verifyShared(transport, slot, recipients);
        entry.phase = .shared;
        try self.save();
    }
    fn markShared(self: *Book, entry: *Entry, index: usize) !void {
        if (index >= t.Limits.recipients) return error.TooManyRecipients;
        const bits = try self.a.dupe(u8, entry.sharedBits);
        const nibble = index / 4;
        const value = std.fmt.charToDigit(bits[nibble], 16) catch return error.InvalidDriveLedger;
        bits[nibble] = "0123456789abcdef"[value | (@as(u8, 1) << @as(u3, @intCast(index % 4)))];
        entry.sharedBits = bits;
    }
    pub const Reuse = struct { kind: []const u8 = "none", newCopy: bool = false, sharedWith: []const []const u8 = &.{} };
    pub fn reuse(self: *const Book, a: A, file: t.Attachment, recipient_digest: ?[]const u8, operation_id: []const u8, index: usize) !Reuse {
        var result: Reuse = .{};
        const handle = file.blobId orelse return result;
        for (self.ledger.entries) |entry| {
            if (!std.mem.eql(u8, handle, entry.blobId) or file.size != entry.size or !std.mem.eql(u8, file.filename, entry.filename) or !std.mem.eql(u8, file.mimeType, entry.mimeType)) continue;
            const same_operation = std.mem.eql(u8, operation_id, entry.operationId);
            const same_targets = if (recipient_digest) |digest| std.mem.eql(u8, digest, entry.recipientDigest) else false;
            if (same_operation) {
                if (entry.index != index) continue;
                // A current binding wins over earlier copies, independent of
                // ledger order. Partial uploads never claim an uploaded badge.
                if (@backingInt(entry.phase) < @backingInt(Phase.sharing)) return .{ .kind = if (entry.phase == .uploaded) "private_upload" else "none" };
                if (same_targets) return .{ .kind = if (entry.phase == .shared and entry.uncertainRecipient == null) "shared_same_recipients" else "none", .sharedWith = try self.confirmed(a, entry) };
            }
            if (@backingInt(entry.phase) < @backingInt(Phase.sharing)) continue;
            if (!same_targets or !same_operation) {
                result.newCopy = true;
                if (result.sharedWith.len == 0) result.sharedWith = try self.confirmed(a, entry);
            }
        }
        return result;
    }
    fn confirmed(self: *const Book, a: A, entry: Entry) ![]const []const u8 {
        var addresses: std.ArrayList([]const u8) = .empty;
        for (self.ledger.targets) |target| if (std.mem.eql(u8, target.digest, entry.recipientDigest)) {
            for (target.addresses, 0..) |address, index| {
                const nibble = std.fmt.charToDigit(entry.sharedBits[index / 4], 16) catch return error.InvalidDriveLedger;
                if (nibble & (@as(u8, 1) << @as(u3, @intCast(index % 4))) != 0) try addresses.append(a, address);
            }
            break;
        };
        return addresses.toOwnedSlice(a);
    }
    pub fn receipts(self: *const Book, a: A, operation_id: []const u8) !j.Value {
        return @import("mail_response_value.zig").borrowed(a, try self.receiptFiles(a, operation_id));
    }
    pub fn receiptFiles(self: *const Book, a: A, operation_id: []const u8) ![]const t.DriveFileReceipt {
        var out: std.ArrayList(t.DriveFileReceipt) = .empty;
        for (self.ledger.entries) |entry| {
            if (!std.mem.eql(u8, entry.operationId, operation_id)) continue;
            var recipients: []const []const u8 = &.{};
            for (self.ledger.targets) |target| if (std.mem.eql(u8, target.digest, entry.recipientDigest)) {
                recipients = target.addresses;
                break;
            };
            if (recipients.len == 0) return error.InvalidDriveLedger;
            var shared: std.ArrayList([]const u8) = .empty;
            for (recipients, 0..) |recipient, index| {
                const nibble = std.fmt.charToDigit(entry.sharedBits[index / 4], 16) catch return error.InvalidDriveLedger;
                if (nibble & (@as(u8, 1) << @as(u3, @intCast(index % 4))) != 0) try shared.append(a, recipient);
            }
            try out.append(a, .{ .index = entry.index, .filename = entry.filename, .size = entry.size, .state = @tagName(entry.phase), .driveFileId = entry.fileId, .link = if (@backingInt(entry.phase) >= @backingInt(Phase.uploaded)) try std.fmt.allocPrint(a, "https://drive.google.com/file/d/{s}/view", .{entry.fileId}) else @as(?[]const u8, null), .sharedWith = shared.items, .sharingUnconfirmedWith = if (entry.uncertainRecipient) |index| (if (index < recipients.len) recipients[index] else null) else @as(?[]const u8, null) });
        }
        return out.toOwnedSlice(a);
    }
    pub fn verifyShared(self: *Book, transport: Transport, slot: usize, recipients: []const []const u8) !void {
        if (slot >= self.ledger.entries.len) return error.InvalidDriveLedger;
        var temporary: std.heap.ArenaAllocator = .init(self.a);
        defer temporary.deinit();
        const a = temporary.allocator();
        const entry = self.ledger.entries[slot];
        const value = (try self.metadata(transport, entry, a)) orelse return error.DriveFileChanged;
        if (!try complete(entry, value)) return error.DriveFileChanged;
        const present = try self.permissions(transport, entry, recipients, a);
        for (recipients, present) |recipient, has_access| if (!has_access and !std.ascii.eqlIgnoreCase(recipient, self.store.state.account)) return error.DriveSharingIncomplete;
    }
    fn permissions(self: *Book, transport: Transport, entry: Entry, recipients: []const []const u8, a: A) ![]bool {
        if (recipients.len > t.Limits.recipients) return error.TooManyRecipients;
        const present = try a.alloc(bool, recipients.len);
        @memset(present, false);
        var cursor: []const u8 = "";
        var pages: usize = 0;
        var owners: usize = 0;
        var total: usize = 0;
        while (true) {
            pages += 1;
            if (pages > 6) return error.DrivePermissionsTooLarge;
            var headers: http.DriveHeaders = .{};
            const url = try std.fmt.allocPrint(a, "https://www.googleapis.com/drive/v3/files/{s}/permissions?pageSize=100&fields=nextPageToken,permissions(id,type,role,emailAddress,deleted,permissionDetails)&pageToken={s}", .{ entry.fileId, try escaped(a, cursor) });
            const value = try json(a, try transport.request(.GET, url, null, null, 0, "application/json", &headers));
            const values = j.get(value, "permissions") orelse return error.InvalidProviderResponse;
            if (values != .array) return error.InvalidProviderResponse;
            for (values.array.items) |permission| {
                total += 1;
                if (total > t.Limits.recipients + 1) return error.DrivePermissionsTooLarge;
                if (try j.boolean(permission, "deleted", false) or !std.mem.eql(u8, j.text(permission, "type"), "user")) return error.DriveUnexpectedAccess;
                if (j.get(permission, "permissionDetails")) |details| {
                    if (details != .array) return error.InvalidProviderResponse;
                    for (details.array.items) |detail| if (try j.boolean(detail, "inherited", false)) return error.DriveUnexpectedAccess;
                }
                const email = try j.required(permission, "emailAddress");
                const role = try j.required(permission, "role");
                if (std.mem.eql(u8, role, "owner")) {
                    if (!std.ascii.eqlIgnoreCase(email, self.store.state.account)) return error.DriveUnexpectedAccess;
                    owners += 1;
                    continue;
                }
                if (!std.mem.eql(u8, role, "reader")) return error.DriveUnexpectedAccess;
                var known = false;
                for (recipients, 0..) |recipient, index| if (std.ascii.eqlIgnoreCase(email, recipient)) {
                    if (present[index]) return error.DriveUnexpectedAccess;
                    present[index] = true;
                    known = true;
                    break;
                };
                if (!known) return error.DriveUnexpectedAccess;
            }
            const next = j.text(value, "nextPageToken");
            if (next.len == 0) break;
            if (next.len > 2048 or std.mem.eql(u8, next, cursor)) return error.DrivePermissionsTooLarge;
            cursor = try a.dupe(u8, next);
        }
        if (owners != 1) return error.DriveUnexpectedAccess;
        return present;
    }
};
const Chunk = struct {
    stream: *blob.Stream,
    remaining: usize,
    fn read(ctx: *anyopaque, out: []u8) !usize {
        const self: *Chunk = @ptrCast(@alignCast(ctx));
        if (self.remaining == 0) return 0;
        const n = try blob.Stream.read(self.stream, out[0..@min(out.len, self.remaining)]);
        if (n == 0) return error.AttachmentChanged;
        self.remaining -= n;
        return n;
    }
};
pub fn acknowledged(range: []const u8, size: usize) !usize {
    if (range.len == 0) return 0;
    if (!std.mem.startsWith(u8, range, "bytes=0-") or range.len > 64) return error.InvalidDriveRange;
    const last = std.fmt.parseInt(usize, range[8..], 10) catch return error.InvalidDriveRange;
    if (last >= size) return error.InvalidDriveRange;
    return last + 1;
}
test "Drive preparation: acknowledged ranges cannot overrun or change origin" {
    try std.testing.expectEqual(@as(usize, 256), try acknowledged("bytes=0-255", 512));
    try std.testing.expectEqual(@as(usize, 0), try acknowledged("", 512));
    for ([_][]const u8{ "bytes=1-255", "bytes=0-512", "bytes=0-18446744073709551615", "bytes=0--1", "bytes=0-2junk" }) |range| try std.testing.expectError(error.InvalidDriveRange, acknowledged(range, 512));
}

fn escaped(a: A, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) try out.append(a, byte) else {
            try out.append(a, '%');
            try out.append(a, "0123456789ABCDEF"[byte >> 4]);
            try out.append(a, "0123456789ABCDEF"[byte & 15]);
        }
    }
    return out.toOwnedSlice(a);
}

test "attachment delivery: lost upload and share responses reconcile without duplicate files or grants" {
    const Oracle = struct {
        a: A,
        digest: []const u8,
        generated: usize = 0,
        creates: usize = 0,
        uploads: usize = 0,
        shares: usize = 0,
        exists: bool = false,
        uploaded: bool = false,
        shared: bool = false,
        lose_upload: bool = true,
        lose_share: bool = true,
        sharing_bad_request: bool = false,
        public_access: bool = false,
        changed_checksum: bool = false,
        fn reply(self: *@This(), status: u16, body: []const u8) http.Response {
            _ = self;
            return .{ .status = status, .body = body };
        }
        fn call(ctx: *anyopaque, method: std.http.Method, url: []const u8, body: ?[]const u8, source: ?http.Source, size: usize, content_type: []const u8, headers: *http.DriveHeaders) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expect(std.mem.startsWith(u8, url, "https://www.googleapis.com/"));
            if (std.mem.indexOf(u8, url, "/generateIds?") != null) {
                try std.testing.expectEqual(std.http.Method.GET, method);
                self.generated += 1;
                return self.reply(200, "{\"ids\":[\"reserved_synthetic_id\"]}");
            }
            if (std.mem.indexOf(u8, url, "/permissions?") != null) {
                if (method == .POST) {
                    try std.testing.expect(std.mem.indexOf(u8, url, "sendNotificationEmail=false") != null);
                    const request = try std.json.parseFromSliceLeaky(j.Value, self.a, body.?, .{});
                    try std.testing.expectEqualStrings("user", j.text(request, "type"));
                    try std.testing.expectEqualStrings("reader", j.text(request, "role"));
                    try std.testing.expectEqualStrings("peer@example.test", j.text(request, "emailAddress"));
                    self.shares += 1;
                    self.shared = true;
                    if (self.lose_share) {
                        self.lose_share = false;
                        if (self.sharing_bad_request) return self.reply(400, "{\"error\":{\"errors\":[{\"reason\":\"invalidSharingRequest\",\"message\":\"Synthetic notification failure after ACL change\"}]}}");
                        return error.Timeout;
                    }
                    return self.reply(200, "{\"id\":\"reader\",\"type\":\"user\",\"role\":\"reader\",\"emailAddress\":\"peer@example.test\"}");
                }
                try std.testing.expectEqual(std.http.Method.GET, method);
                if (self.public_access) return self.reply(200, "{\"permissions\":[{\"id\":\"owner\",\"type\":\"user\",\"role\":\"owner\",\"emailAddress\":\"self@example.test\"},{\"id\":\"public\",\"type\":\"anyone\",\"role\":\"reader\"}]}");
                return self.reply(200, if (self.shared) "{\"permissions\":[{\"id\":\"owner\",\"type\":\"user\",\"role\":\"owner\",\"emailAddress\":\"self@example.test\"},{\"id\":\"reader\",\"type\":\"user\",\"role\":\"reader\",\"emailAddress\":\"peer@example.test\"}]}" else "{\"permissions\":[{\"id\":\"owner\",\"type\":\"user\",\"role\":\"owner\",\"emailAddress\":\"self@example.test\"}]}");
            }
            if (method == .POST) {
                try std.testing.expectEqualStrings("https://www.googleapis.com/drive/v3/files?ignoreDefaultVisibility=true&fields=id", url);
                const request = try std.json.parseFromSliceLeaky(j.Value, self.a, body.?, .{});
                try std.testing.expectEqualStrings("reserved_synthetic_id", j.text(request, "id"));
                self.creates += 1;
                self.exists = true;
                return self.reply(200, "{\"id\":\"reserved_synthetic_id\"}");
            }
            if (method == .PATCH) {
                try std.testing.expectEqualStrings("19", headers.upload_content_length.?);
                var result = self.reply(200, "");
                result.location = "https://www.googleapis.com/upload/drive/v3/files/reserved_synthetic_id?uploadType=resumable&upload_id=private_fixture";
                return result;
            }
            if (method == .PUT) {
                if (source) |input| {
                    try std.testing.expectEqualStrings("application/octet-stream", content_type);
                    try std.testing.expectEqual(@as(usize, 19), size);
                    try std.testing.expectEqualStrings("bytes 0-18/19", headers.content_range.?);
                    var bytes: [32]u8 = undefined;
                    const n = try input.readFn(input.ctx, &bytes);
                    try std.testing.expectEqualStrings("Synthetic file data", bytes[0..n]);
                    try std.testing.expectEqual(@as(usize, 0), try input.readFn(input.ctx, &bytes));
                    self.uploads += 1;
                    self.uploaded = true;
                    if (self.lose_upload) {
                        self.lose_upload = false;
                        return error.Timeout;
                    }
                    return self.reply(200, "{\"id\":\"reserved_synthetic_id\"}");
                }
                try std.testing.expectEqual(@as(usize, 0), size);
                try std.testing.expectEqualStrings("bytes */19", headers.content_range.?);
                return self.reply(308, "");
            }
            try std.testing.expectEqual(std.http.Method.GET, method);
            if (!self.exists) return self.reply(404, "{}");
            const metadata_body = try std.fmt.allocPrint(self.a, "{{\"id\":\"reserved_synthetic_id\",\"name\":\"file.bin\",\"mimeType\":\"application/octet-stream\",\"size\":\"{d}\",\"sha256Checksum\":\"{s}\",\"ownedByMe\":true,\"trashed\":false,\"appProperties\":{{\"omagmaSha256\":\"{s}\"}}}}", .{ if (self.uploaded) @as(usize, 19) else 0, if (self.changed_checksum) "changed" else if (self.uploaded) self.digest else "", self.digest });
            return self.reply(200, metadata_body);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.bin", .data = "Synthetic file data" });
    var store = try Store.open(std.testing.io, a, try std.fmt.allocPrint(a, "{s}/cache", .{base}), "self@example.test", .{ .fixtures = true });
    defer store.close();
    const file = try blob.importDelivery(&store, try std.fmt.allocPrint(a, "{s}/file.bin", .{base}), "", .drive);
    _ = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .attachments = &.{file} }, null);
    var oracle: Oracle = .{ .a = a, .digest = file.blobId.? };
    const transport: Transport = .{ .ctx = &oracle, .requestFn = Oracle.call };
    var book = try Book.load(a, &store);
    const digest: [64]u8 = @splat('a');
    const slot = try book.reserve(transport, "explicit-operation", &digest, 0, file, &.{"peer@example.test"});
    try std.testing.expectError(error.Timeout, book.upload(transport, slot, file));
    book = try Book.load(a, &store);
    const resumed = try book.reserve(transport, "explicit-operation", &digest, 0, file, &.{"peer@example.test"});
    oracle.public_access = true;
    try std.testing.expectError(error.DriveUnexpectedAccess, book.upload(transport, resumed, file));
    try std.testing.expectEqual(@as(usize, 1), oracle.uploads);
    oracle.public_access = false;
    oracle.changed_checksum = true;
    try std.testing.expectError(error.DriveFileChanged, book.upload(transport, resumed, file));
    try std.testing.expectEqual(@as(usize, 1), oracle.uploads);
    oracle.changed_checksum = false;
    try book.upload(transport, resumed, file);
    try std.testing.expectError(error.Timeout, book.share(transport, resumed, &.{"peer@example.test"}));
    book = try Book.load(a, &store);
    oracle.shared = false;
    try std.testing.expectError(error.DriveSharingOutcomeUnknown, book.share(transport, resumed, &.{"peer@example.test"}));
    try std.testing.expectEqual(@as(usize, 1), oracle.shares);
    oracle.shared = true;
    try book.share(transport, resumed, &.{"peer@example.test"});
    try book.verifyShared(transport, resumed, &.{"peer@example.test"});
    try std.testing.expectEqual(Phase.shared, book.ledger.entries[resumed].phase);
    try std.testing.expectEqual(@as(usize, 1), oracle.generated);
    try std.testing.expectEqual(@as(usize, 1), oracle.creates);
    try std.testing.expectEqual(@as(usize, 1), oracle.uploads);
    try std.testing.expectEqual(@as(usize, 1), oracle.shares);
    // Google documents a400 invalidSharingRequest even after a successful
    // grant. Losing that uncertainty would permit a duplicate permission POST.
    oracle.shared = false;
    oracle.lose_share = true;
    oracle.sharing_bad_request = true;
    try std.testing.expectError(error.DriveSharingBlocked, book.share(transport, resumed, &.{"peer@example.test"}));
    book = try Book.load(a, &store);
    try std.testing.expectEqual(@as(?usize, 0), book.ledger.entries[resumed].uncertainRecipient);
    oracle.shared = false;
    try std.testing.expectError(error.DriveSharingOutcomeUnknown, book.share(transport, resumed, &.{"peer@example.test"}));
    try std.testing.expectEqual(@as(usize, 2), oracle.shares);
    oracle.shared = true;
    try book.share(transport, resumed, &.{"peer@example.test"});
    try std.testing.expectEqual(@as(usize, 2), oracle.shares);
}

test "attachment delivery: literal Drive reasons distinguish policy quota authorization and transient failures" {
    const cases = .{
        .{ @as(u16, 403), "storageQuotaExceeded", error.DriveStorageFull },
        .{ @as(u16, 403), "dailyLimitExceeded", error.DriveQuotaExceeded },
        .{ @as(u16, 403), "rateLimitExceeded", error.RateLimited },
        .{ @as(u16, 403), "sharingRateLimitExceeded", error.RateLimited },
        .{ @as(u16, 403), "domainPolicy", error.DriveSharingPolicy },
        .{ @as(u16, 403), "accessNotConfigured", error.DriveApiDisabled },
        .{ @as(u16, 400), "invalidSharingRequest", error.DriveSharingBlocked },
        .{ @as(u16, 401), "authError", error.DriveAccessExpired },
        .{ @as(u16, 403), "insufficientFilePermissions", error.DrivePermissionDenied },
        .{ @as(u16, 404), "notFound", error.DriveFileUnavailable },
        .{ @as(u16, 503), "backendError", error.DriveServerError },
    };
    inline for (cases) |case| {
        const body = "{\"error\":{\"errors\":[{\"reason\":\"" ++ case[1] ++ "\",\"message\":\"Private provider detail must not escape\"}]}}";
        try std.testing.expectError(case[2], accepted(.{ .status = case[0], .body = body }));
    }
    try std.testing.expectError(error.DriveApiDisabled, accepted(.{ .status = 403, .body = "{\"error\":{\"details\":[{\"reason\":\"SERVICE_DISABLED\"}]}}" }));
    try std.testing.expectError(error.DrivePermissionDenied, accepted(.{ .status = 403, .body = "malformed" }));
    try std.testing.expect(!retryablePreparation("DriveSharingBlocked"));
    try std.testing.expect(!retryablePreparation("DriveApiDisabled"));
    try std.testing.expect(retryablePreparation("DriveAccessExpired"));
    try std.testing.expect(retryablePreparation("RateLimited"));
}

test "attachment delivery: current reuse binding wins over earlier shared copies in either ledger order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const digest: [64]u8 = @splat('a');
    const handle: [64]u8 = @splat('b');
    const file: t.Attachment = .{ .id = "local", .blobId = &handle, .filename = "file.bin", .mimeType = "application/octet-stream", .size = 1, .delivery = .drive };
    var shared_bits: [128]u8 = @splat('0');
    shared_bits[0] = '1';
    for ([_]bool{ false, true }) |reverse| {
        var entries = [_]Entry{
            .{ .operationId = "earlier", .sourceDigest = &digest, .index = 0, .fileId = "earlier-file", .blobId = &handle, .filename = file.filename, .mimeType = file.mimeType, .size = 1, .recipientDigest = &digest, .phase = .shared, .sharedBits = &shared_bits },
            .{ .operationId = "current", .sourceDigest = &digest, .index = 1, .fileId = "current-file", .blobId = &handle, .filename = file.filename, .mimeType = file.mimeType, .size = 1, .recipientDigest = &digest, .phase = .uploaded },
        };
        if (reverse) std.mem.swap(Entry, &entries[0], &entries[1]);
        var targets = [_]TargetSet{.{ .digest = &digest, .addresses = &.{"peer@example.test"} }};
        const book: Book = .{ .store = undefined, .a = a, .ledger = .{ .account = "self@example.test", .entries = &entries, .targets = &targets } };
        const reused = try book.reuse(a, file, &digest, "current", 1);
        try std.testing.expectEqualStrings("private_upload", reused.kind);
        try std.testing.expect(!reused.newCopy and reused.sharedWith.len == 0);
        for (&entries) |*entry| if (std.mem.eql(u8, entry.operationId, "current")) {
            entry.phase = .uploading;
        };
        const partial = try book.reuse(a, file, &digest, "current", 1);
        try std.testing.expectEqualStrings("none", partial.kind);
        try std.testing.expect(!partial.newCopy and partial.sharedWith.len == 0);
    }
}
