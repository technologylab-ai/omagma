//! Source-retaining Store migration helpers. The local migration coordinator
//! checkpoints every planned handle before calling copy; no live path fallback.
const std = @import("std");
const Store = @import("store.zig").Store;
const storage = @import("vault_storage.zig");
const vt = @import("vault_types.zig");
const stream = @import("vault_stream.zig");
pub const Object = struct { name: []const u8, kind: vt.RecordKind, size: usize, sha256: [32]u8, handle: storage.Handle, mapped: bool = true };
/// The Store lock is already held. Pin and validate the exact private index
/// descriptor, so disappearance or replacement cannot become an empty source.
pub fn readIndex(io: std.Io, dir: std.Io.Dir, a: std.mem.Allocator) ![]const u8 {
    const file = storage.openPrivate(io, dir, "index.json") catch |err| return if (err == error.FileNotFound) error.MigrationIndexMissing else err;
    defer file.close(io);
    const before = try file.stat(io);
    if (before.size > @import("store.zig").index_read_bytes) return error.CacheLimitExceeded;
    const bytes = try a.alloc(u8, @intCast(before.size));
    errdefer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.MigrationSourceChanged;
    const after = try file.stat(io);
    const current = dir.statFile(io, "index.json", .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound) error.MigrationSourceChanged else err;
    if (!same(before, after) or !same(after, current)) return error.MigrationSourceChanged;
    try @import("../keyring_file.zig").privateFile(io, file);
    return bytes;
}
const BlobReference = struct { blobId: ?[]const u8 = null, size: usize = 0 };
const Body = struct { schema: u8 = 1, account: []const u8, message: struct { id: []const u8, attachments: []const BlobReference = &.{} } };
const Draft = struct { id: []const u8, attachments: []const BlobReference = &.{}, original: ?struct { resources: []const BlobReference = &.{} } = null };
fn same(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.inode == after.inode and before.size == after.size and before.mtime.toNanoseconds() == after.mtime.toNanoseconds() and before.ctime.toNanoseconds() == after.ctime.toNanoseconds();
}
fn privateFile(s: *Store, name: []const u8) !std.Io.File {
    if (name.len > 255) return error.MigrationSourceInvalid;
    var text: [255:0]u8 = undefined;
    @memcpy(text[0..name.len], name);
    text[name.len] = 0;
    return storage.openPrivate(s.io, s.dir, &text);
}
fn hashFile(io: std.Io, file: std.Io.File, size: usize, buffer: []u8) ![32]u8 {
    defer std.crypto.secureZero(u8, buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    var offset: usize = 0;
    while (true) {
        const n = try file.readPositional(io, &.{buffer}, offset);
        if (n == 0) break;
        if (n > size -| offset) return error.MigrationSourceChanged;
        offset += n;
        hash.update(buffer[0..n]);
    }
    if (offset != size) return error.MigrationSourceChanged;
    return hash.finalResult();
}
fn namesLess(_: void, left: Object, right: Object) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
fn objectNamed(objects: []const Object, name: []const u8) ?Object {
    var low: usize = 0;
    var high = objects.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, objects[middle].name, name)) {
            .eq => return objects[middle],
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return null;
}
fn attachmentReferences(a: std.mem.Allocator, objects: []const Object, attachments: []const BlobReference) !void {
    for (attachments) |attachment| if (attachment.blobId) |id| {
        const object = objectNamed(objects, try @import("attachment_blob.zig").filename(a, id)) orelse return error.MigrationRecordMissing;
        if (object.kind != .attachment or object.size != attachment.size) return error.MigrationSourceInvalid;
    };
}
fn blobReferences(a: std.mem.Allocator, objects: []const Object, ids: []const []const u8) !void {
    for (ids) |id| if (objectNamed(objects, try @import("attachment_blob.zig").filename(a, id)) == null) return error.MigrationRecordMissing;
}
fn validateRecords(s: *Store, objects: []const Object) !void {
    // Validate each source record in a fresh bounded lifetime. The complete
    // source index stays resident once; mail bodies never accumulate in an arena.
    var wiping: @import("vault_allocator.zig").WipingAllocator = .{ .backing = s.allocator };
    for (objects) |object| {
        if (object.kind == .attachment) continue;
        var scratch = std.heap.ArenaAllocator.init(wiping.allocator());
        defer scratch.deinit();
        const a = scratch.allocator();
        const file = try privateFile(s, object.name);
        defer file.close(s.io);
        const before = try file.stat(s.io);
        if (before.size != object.size) return error.MigrationSourceChanged;
        var hash_buffer: [64 * 1024]u8 = undefined;
        if (!std.mem.eql(u8, &try hashFile(s.io, file, object.size, &hash_buffer), &object.sha256)) return error.MigrationSourceChanged;
        var read_buffer: [8192]u8 = undefined;
        defer std.crypto.secureZero(u8, &read_buffer);
        var reader = file.reader(s.io, &read_buffer);
        var parser: std.json.Reader = .init(a, &reader.interface);
        defer parser.deinit();
        const options: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .max_value_len = 4096 };
        switch (object.kind) {
            .mail_body, .outbox => {
                const record = try std.json.parseFromTokenSourceLeaky(Body, a, &parser, options);
                if (record.schema != 1 or !std.mem.eql(u8, record.account, s.state.account)) return error.CacheIdentityMismatch;
                const name = try std.fmt.allocPrint(a, "{s}-{s}.json", .{ if (object.kind == .mail_body) @as([]const u8, "mail") else "outbox", Store.hash(record.message.id) });
                if (!std.mem.eql(u8, name, object.name)) return error.CacheIdentityMismatch;
                try attachmentReferences(a, objects, record.message.attachments);
            },
            .draft => {
                const draft = try std.json.parseFromTokenSourceLeaky(Draft, a, &parser, options);
                const name = try std.fmt.allocPrint(a, "draft-{s}.json", .{Store.hash(draft.id)});
                if (!@import("operation_history.zig").direct(object.name) and !std.mem.eql(u8, name, object.name)) return error.CacheIdentityMismatch;
                try attachmentReferences(a, objects, draft.attachments);
                if (draft.original) |original| try attachmentReferences(a, objects, original.resources);
            },
            .operation_ledger, .cache_index, .preferences => {
                _ = try std.json.parseFromTokenSourceLeaky(struct {}, a, &parser, options);
            },
            else => return error.MigrationSourceInvalid,
        }
        if (!same(before, try file.stat(s.io))) return error.MigrationSourceChanged;
    }
    var scratch = std.heap.ArenaAllocator.init(s.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for (s.state.entries) |entry| if (entry.bytes != 0) {
        const object = objectNamed(objects, try std.fmt.allocPrint(a, "mail-{s}.json", .{Store.hash(entry.message.id)})) orelse return error.MigrationRecordMissing;
        if (object.size != entry.bytes or !std.mem.eql(u8, &std.fmt.bytesToHex(object.sha256, .lower), entry.bodyHash)) return error.MigrationSourceChanged;
        if (entry.bodyBlobIds) |ids| try blobReferences(a, objects, ids);
    };
    for (s.state.drafts) |draft| {
        const source = objectNamed(objects, try s.activeDraftSourceName(a, draft.id)) orelse return error.MigrationRecordMissing;
        if (try @import("draft_pins.zig").load(s, a, draft.id)) |pins| {
            if (!std.mem.eql(u8, pins.hash, &std.fmt.bytesToHex(source.sha256, .lower))) return error.MigrationSourceChanged;
            try blobReferences(a, objects, pins.blobs);
        }
    }
    for (s.state.outbox) |message| if (objectNamed(objects, try std.fmt.allocPrint(a, "outbox-{s}.json", .{Store.hash(message.id)})) == null) return error.MigrationRecordMissing;
    for (s.state.relatedDraftBlobs) |references| {
        try blobReferences(a, objects, references.blobs);
        if (references.handle.len != 0 and objectNamed(objects, try @import("operation_history.zig").fileName(a, "pins", references.handle)) == null) return error.MigrationRecordMissing;
    }
    try validateHistory(s, objects);
}
fn validateHistory(s: *Store, objects: []const Object) !void {
    const history = @import("operation_history.zig");
    var next = s.state.history.head;
    var next_buffer: [64]u8 = undefined;
    var remaining = s.state.history.pages;
    while (next.len != 0) {
        var phase: std.heap.ArenaAllocator = .init(if (@import("send_memory.zig").native) @import("send_memory.zig").allocator() else s.allocator);
        defer phase.deinit();
        const a = phase.allocator();
        const page = try history.readPage(s, a, next);
        if (remaining == 0 or page.sequence != remaining) return error.InvalidHistory;
        remaining -= 1;
        for (page.records) |record| switch (record) {
            .draft => |retained| {
                const current = (try history.source(s, a, retained.summary.id)) orelse return error.InvalidHistory;
                if (!current.deleted) {
                    const source = objectNamed(objects, try history.fileName(a, "draft", current.handle)) orelse return error.MigrationRecordMissing;
                    if (source.kind != .draft or !std.mem.eql(u8, current.hash, &std.fmt.bytesToHex(source.sha256, .lower))) return error.MigrationSourceChanged;
                    try blobReferences(a, objects, current.blobs);
                }
            },
            .operation => |op| {
                if (try history.operation(s, a, op.id) == null) return error.InvalidHistory;
            },
            .queue => |entry| {
                if (try history.get(s, a, .queue, entry.queueId) == null) return error.InvalidHistory;
            },
            .blob => |entry| {
                const current = (try history.findBlob(s, a, entry.id)) orelse return error.InvalidHistory;
                if (!current.deleted) {
                    const object = objectNamed(objects, try @import("attachment_blob.zig").filename(a, entry.id)) orelse return error.MigrationRecordMissing;
                    if (object.kind != .attachment or object.size != current.size or !std.mem.eql(u8, &(try storage.Handle.parse(current.handle)).bytes, &object.handle.bytes)) return error.MigrationSourceChanged;
                }
            },
        };
        if (page.previous.len == 0) next = "" else {
            @memcpy(&next_buffer, page.previous);
            next = &next_buffer;
        }
    }
    if (remaining != 0) return error.InvalidHistory;
}
pub fn inventory(s: *Store, a: std.mem.Allocator) ![]Object {
    s.migration_inventory = null;
    try s.migrationSourceReady();
    if (s.vault != null) return error.MigrationSourceRequired;
    if (try s.diskBytes() > @import("types.zig").Limits.disk_hard) return error.MigrationDiskQuotaExceeded;
    var rows: std.ArrayList(Object) = .empty;
    var scratch: [64 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var legacy_blobs: usize = 0;
    var iterator = s.dir.iterate();
    while (try iterator.next(s.io)) |entry| {
        if (entry.kind != .file) return error.MigrationSourceInvalid;
        const file = try privateFile(s, entry.name);
        defer file.close(s.io);
        const before = try file.stat(s.io);
        if (std.mem.eql(u8, entry.name, "lock") or std.mem.eql(u8, entry.name, "refresh.lock")) {
            if (before.size != 0) return error.MigrationSourceInvalid;
            continue;
        }
        if (std.mem.eql(u8, entry.name, "index.json")) continue;
        const kind = Store.migrationRecordKind(entry.name) catch return error.MigrationSourceInvalid;
        const bound = try s.migrationRecordLimit(entry.name);
        if (before.size > bound) return error.CacheLimitExceeded;
        const size: usize = @intCast(before.size);
        const digest = try hashFile(s.io, file, size, &scratch);
        if (!same(before, try file.stat(s.io))) return error.MigrationSourceChanged;
        var blob: ?@import("operation_history.zig").Blob = null;
        if (kind == .attachment) {
            if (!std.mem.eql(u8, entry.name[5..69], &std.fmt.bytesToHex(digest, .lower))) return error.MigrationSourceChanged;
            var phase: std.heap.ArenaAllocator = .init(if (@import("send_memory.zig").native) @import("send_memory.zig").allocator() else a);
            defer phase.deinit();
            if (try @import("operation_history.zig").findBlob(s, phase.allocator(), entry.name[5..69])) |value| {
                if (!value.deleted) {
                    if (value.size != size) return error.MigrationSourceChanged;
                    blob = value;
                }
            }
            // Only old unindexed files require the bounded legacy map. New
            // imports have permanent paged identities, including empty files.
            if (blob == null) {
                legacy_blobs += 1;
                if (legacy_blobs > @import("store.zig").blob_limit) return error.AttachmentLimitExceeded;
            }
            const planned_handle = if (blob) |value| try storage.Handle.parse(value.handle) else try storage.Handle.create(s.io);
            try rows.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = kind, .size = size, .sha256 = digest, .handle = planned_handle, .mapped = blob == null });
        } else try rows.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = kind, .size = size, .sha256 = digest, .handle = if (@import("operation_history.zig").direct(entry.name)) try @import("operation_history.zig").handleOf(entry.name) else try storage.Handle.create(s.io) });
    }
    std.sort.heap(Object, rows.items, {}, namesLess);
    try validateRecords(s, rows.items);
    try @import("calendar_store.zig").verifyHistory(s, a);
    const result = try rows.toOwnedSlice(a);
    _ = try s.migrationCapacity(result);
    s.migration_inventory = result;
    return result;
}
pub fn validatePlan(source: *const Store, objects: []const Object) !void {
    const inventoried = source.migration_inventory orelse return error.MigrationInventoryRequired;
    if (inventoried.len != objects.len) return error.MigrationSourceChanged;
    for (inventoried, objects) |current, planned| {
        if (!std.mem.eql(u8, current.name, planned.name) or current.kind != planned.kind or current.size != planned.size or current.mapped != planned.mapped or !std.mem.eql(u8, &current.sha256, &planned.sha256)) return error.MigrationSourceChanged;
    }
}
pub fn verifyCiphertext(destination: *Store, object: *const Object) !void {
    const account = try destination.vaultContext();
    try account.requireSharedWorkspace();
    if (!destination.migration_destination or object.kind != try Store.migrationRecordKind(object.name) or object.size > try destination.migrationRecordLimit(object.name)) return error.MigrationDestinationRequired;
    if (std.mem.eql(u8, &account.entry.index.bytes, &object.handle.bytes)) return error.MigrationSourceInvalid;
    defer std.crypto.secureZero(u8, &account.owner.workspace.plaintext);
    var reader = try stream.Reader.init(&account.directory, account.owner.key, account.record(object.kind, object.handle), &account.owner.workspace.ciphertext, &account.reader_owner);
    defer reader.close();
    if (reader.size != object.size) return error.MigrationSourceChanged;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    while (true) {
        const n = try reader.read(&account.owner.workspace.plaintext);
        if (n == 0) break;
        hash.update(account.owner.workspace.plaintext[0..n]);
    }
    if (!std.mem.eql(u8, &hash.finalResult(), &object.sha256)) return error.MigrationSourceChanged;
}
pub fn copy(destination: *Store, source: *Store, object: *const Object) !void {
    try source.migrationSourceReady();
    if (!std.mem.eql(u8, source.state.account, destination.state.account)) return error.MigrationSourceRequired;
    const inventoried = source.migration_inventory orelse return error.MigrationInventoryRequired;
    const planned = objectNamed(inventoried, object.name) orelse return error.MigrationSourceChanged;
    if (planned.kind != object.kind or planned.size != object.size or !std.mem.eql(u8, &planned.sha256, &object.sha256)) return error.MigrationSourceChanged;
    const account = try destination.vaultContext();
    try account.requireSharedWorkspace();
    if (!destination.migration_destination or object.kind != try Store.migrationRecordKind(object.name) or object.size > try source.migrationRecordLimit(object.name)) return error.MigrationDestinationRequired;
    if (std.mem.eql(u8, &account.entry.index.bytes, &object.handle.bytes)) return error.MigrationSourceInvalid;
    const file = try privateFile(source, object.name);
    defer file.close(source.io);
    const before = try file.stat(source.io);
    if (before.size != object.size) return error.MigrationSourceChanged;
    if (!std.mem.eql(u8, &try hashFile(source.io, file, object.size, &account.owner.workspace.ciphertext), &object.sha256) or !same(before, try file.stat(source.io))) return error.MigrationSourceChanged;
    if (account.directory.dir.statFile(destination.io, &object.handle.filename(), .{ .follow_symlinks = false })) |_| {
        return verifyCiphertext(destination, object);
    } else |err| if (err != error.FileNotFound) return err;
    try destination.reserveVaultCiphertext(try vt.sealedSize(object.size));
    var output: stream.Writer = undefined;
    try output.initOwnedInPlace(&account.directory, account.owner.key, account.record(object.kind, object.handle), object.size, &account.owner.workspace.plaintext, &account.writer_owner, @import("vault_catalog.zig").Account.releaseWriter);
    defer output.deinit();
    defer std.crypto.secureZero(u8, &account.owner.workspace.ciphertext);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    var offset: usize = 0;
    while (true) {
        const n = try file.readPositional(source.io, &.{&account.owner.workspace.ciphertext}, offset);
        if (n == 0) break;
        if (n > object.size -| offset) return error.MigrationSourceChanged;
        offset += n;
        hash.update(account.owner.workspace.ciphertext[0..n]);
        try output.interface.writeAll(account.owner.workspace.ciphertext[0..n]);
    }
    if (offset != object.size or !same(before, try file.stat(source.io)) or !std.mem.eql(u8, &hash.finalResult(), &object.sha256)) return error.MigrationSourceChanged;
    output.finish() catch |err| {
        if (err == error.VaultDurabilityUncertain) account.owner.uncertain = true;
        return err;
    };
    try destination.accountMigrationCiphertext(try vt.sealedSize(object.size), 0);
    try verifyCiphertext(destination, object);
}
