//! Local abandonment is fenced permanently before its active Drive journal
//! is collected. Remote files and their permissions are never changed here.
const std = @import("std");
const storage = @import("store.zig");
const prepare = @import("drive_prepare.zig");

fn protected(store: *storage.Store, entry: storage.DriveSource) bool {
    for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and
        (std.mem.eql(u8, operation.id, entry.operationId) or std.mem.eql(u8, operation.draftId, entry.draftId))) return true;
    for (store.state.sendQueue) |queue| if ((queue.state == .queued or queue.state == .preparing or queue.state == .submitting or queue.state == .unknown) and
        (std.mem.eql(u8, queue.operationId, entry.operationId) or std.mem.eql(u8, queue.draftId, entry.draftId))) return true;
    return false;
}
pub fn source(store: *storage.Store, draft_id: []const u8, keep_digest: ?[]const u8, only_operation: ?[]const u8) !void {
    var selected: std.ArrayList(storage.DriveSource) = .empty;
    var retained: std.ArrayList(storage.DriveSource) = .empty;
    for (store.state.driveSources) |entry| {
        const matches = std.mem.eql(u8, entry.draftId, draft_id) and
            (only_operation == null or std.mem.eql(u8, only_operation.?, entry.operationId)) and
            (keep_digest == null or !std.mem.eql(u8, keep_digest.?, entry.hash));
        if (matches and !protected(store, entry)) try selected.append(store.allocator, entry) else try retained.append(store.allocator, entry);
    }
    if (selected.items.len == 0) return;
    var book = try prepare.Book.load(store.allocator, store);
    var operations: std.ArrayList(storage.Operation) = .empty;
    try operations.appendSlice(store.allocator, store.state.operations);
    for (selected.items) |entry| {
        if (try store.findOperation(store.allocator, entry.operationId)) |existing| {
            if (!std.mem.eql(u8, existing.hash, entry.hash) or existing.driveFiles == null) return error.InvalidDriveLedger;
            continue;
        }
        if (operations.items.len >= 1000) return error.OperationJournalFull;
        try operations.append(store.allocator, .{
            .id = try store.allocator.dupe(u8, entry.operationId),
            .hash = try store.allocator.dupe(u8, entry.hash),
            .draftId = try store.allocator.dupe(u8, entry.draftId),
            .outcome = "rejected",
            .kind = "drivePreparationRetired",
            .errorCode = "DrivePreparationRetired",
            .driveFiles = try book.receiptFiles(store.allocator, entry.operationId),
        });
    }
    // Publish the permanent same-operation fence, with exact confirmed and
    // unconfirmed viewers, BEFORE dropping mappings or resumable identities.
    store.state.operations = operations.items;
    try store.save();
    store.state.driveSources = retained.items;
    try store.save();
    try book.compact("");
    // The caller compacts at a safe boundary before retaining draft/queue
    // indexes. History compaction may replace those arrays.
}
pub fn requireSourceRetired(store: *storage.Store, draft_id: []const u8) !void {
    for (store.state.driveSources) |entry| if (std.mem.eql(u8, entry.draftId, draft_id)) {
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and
            (std.mem.eql(u8, operation.draftId, entry.draftId) or std.mem.eql(u8, operation.id, entry.operationId))) return error.UnknownOutcome;
        return error.DraftQueued;
    };
}
pub fn requireOperationRetired(store: *storage.Store, operation_id: []const u8) !void {
    for (store.state.driveSources) |entry| if (std.mem.eql(u8, entry.operationId, operation_id)) {
        if (try store.findOperation(store.allocator, operation_id)) |record| {
            if (std.mem.eql(u8, record.hash, entry.hash) and !std.mem.eql(u8, record.outcome, "unknown") and record.driveFiles != null) return;
            return error.UnknownOutcome;
        }
        for (store.state.operations) |record| if (std.mem.eql(u8, record.draftId, entry.draftId) and std.mem.eql(u8, record.outcome, "unknown")) return error.UnknownOutcome;
        return error.DraftQueued;
    };
}

test "attachment delivery: retirement refuses a full journal and crash after its fence preserves receipts" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |full| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const base = try tmp.dir.realPathFileAlloc(io, ".", a);
        const root = try std.fmt.allocPrint(a, "{s}/cache", .{base});
        try tmp.dir.writeFile(io, .{ .sub_path = "file.bin", .data = "Retirement fixture" });
        var store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
        defer store.close();
        const file = try @import("attachment_blob.zig").importDelivery(&store, try std.fmt.allocPrint(a, "{s}/file.bin", .{base}), "", .drive);
        const draft = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .attachments = &.{file} }, null);
        const digest = try @import("send_outcome.zig").digest(a, draft, store.state.account, null);
        try store.recordPreparedDraft(draft.id, "retired-op", &digest);
        var book = try prepare.Book.load(a, &store);
        const slot = try book.reserveFixture("retired-op", &digest, 0, file, &.{"peer@example.test"});
        try std.testing.expectError(error.Timeout, book.completeFixture(&.{slot}, &.{"peer@example.test"}, false, true, false));
        const frozen = try book.receiptFiles(a, "retired-op");
        const expected = try @import("json.zig").encodeAlloc(a, frozen, .{});
        if (full) {
            const operations = try a.alloc(storage.Operation, 1000);
            for (operations, 0..) |*operation, index| {
                const operation_id = try std.fmt.allocPrint(a, "unrelated-unknown-{d}", .{index});
                operation.* = .{ .id = operation_id, .hash = try a.dupe(u8, &storage.Store.hash(operation_id)) };
            }
            store.state.operations = operations;
            try store.save();
            try std.testing.expectError(error.OperationJournalFull, source(&store, draft.id, null, null));
            store.close();
            store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
            try std.testing.expectEqual(@as(usize, 1000), store.state.operations.len);
            try std.testing.expectEqual(@as(usize, 1), store.state.driveSources.len);
            book = try prepare.Book.load(a, &store);
            try std.testing.expectEqualStrings(expected, try @import("json.zig").encodeAlloc(a, try book.receiptFiles(a, "retired-op"), .{}));
            continue;
        }
        // Simulate a crash at the exact durable boundary, before active
        // mapping/ledger cleanup. The remote grant may already have happened.
        store.state.operations = try a.dupe(storage.Operation, &.{.{ .id = "retired-op", .hash = &digest, .draftId = draft.id, .outcome = "rejected", .kind = "drivePreparationRetired", .errorCode = "DrivePreparationRetired", .driveFiles = frozen }});
        try store.save();
        store.close();
        store = try storage.Store.open(io, a, root, "self@example.test", .{ .fixtures = true });
        book = try prepare.Book.load(a, &store);
        try std.testing.expect(book.ledger.entries.len == 1);
        try source(&store, draft.id, null, null);
        book = try prepare.Book.load(a, &store);
        try std.testing.expectEqual(@as(usize, 0), book.ledger.entries.len);
        try std.testing.expectEqual(@as(usize, 0), store.state.driveSources.len);
        try @import("operation_history.zig").compact(&store, true);
        const receipt = (try store.findOperation(a, "retired-op")).?;
        try std.testing.expectEqualStrings("drivePreparationRetired", receipt.kind);
        try std.testing.expect(receipt.rfcMessageId.len == 0 and receipt.messageId.len == 0);
        try std.testing.expectEqualStrings(expected, try @import("json.zig").encodeAlloc(a, receipt.driveFiles.?, .{}));
    }
}
