const std = @import("std");
const t = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const recipients = @import("terminal/recipients.zig");
const mime = @import("terminal/mime.zig");

test "native capacity: draft list metadata stays small with 1040 long filenames and exact sources reopen" {
    if (!t.Limits.native) return error.SkipZigTest;
    const summaries = @import("terminal/draft_summary.zig");
    const storage = @import("terminal/store.zig");
    const history = @import("terminal/operation_history.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filename = try a.alloc(u8, @import("terminal/mail_limits.zig").filename_bytes);
    @memset(filename, 'f');
    const files = try a.alloc(t.Attachment, t.Limits.attachments);
    for (files) |*file| file.* = .{ .id = "tiny", .filename = filename, .mimeType = "text/plain", .size = 1, .data = "AA" };
    var store = try storage.Store.open(std.testing.io, a, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/list-metadata", .{tmp.sub_path}), "self@example.test", .{ .fixtures = true });
    defer store.close();
    const operations = try a.alloc(storage.Operation, 6);
    var first_id: []const u8 = "";
    for (operations, 0..) |*operation, index| {
        const saved = try store.putDraft(.{ .to = &.{.{ .address = "peer@example.test" }}, .subject = "Complete filename metadata", .bodyText = "Exact source", .attachments = files }, null);
        if (index == 0) first_id = saved.id;
        operation.* = .{ .id = try std.fmt.allocPrint(a, "metadata-operation-{d}", .{index}), .draftId = saved.id, .hash = try a.dupe(u8, &try @import("terminal/send_outcome.zig").digest(a, saved, store.state.account, null)), .outcome = "applied" };
    }
    const old_previews = try a.alloc(t.Draft, operations.len);
    const old_file_metadata = try summaries.attachmentMetadata(a, files);
    for (old_previews, store.state.drafts) |*preview, saved| preview.* = .{ .id = saved.id, .subject = saved.subject, .attachments = old_file_metadata };
    try std.testing.expect(try summaries.encodedBytes(.{ .drafts = old_previews }) > t.Limits.request_bytes);
    const old_full_page = try a.alloc(t.Draft, 100);
    for (old_full_page, 0..) |*preview, index| preview.* = .{ .id = try std.fmt.allocPrint(a, "retained-{d}", .{index}), .attachments = old_file_metadata };
    try std.testing.expect(try summaries.encodedBytes(.{ .drafts = old_full_page }) > 32 * 1024 * 1024);
    try std.testing.expect(try summaries.encodedBytes(.{ .drafts = store.state.drafts }) < 16 * 1024);
    var response_buffer: [32 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&response_buffer);
    const active = try summaries.list(fixed.allocator(), store.state.drafts, &.{}, "", 100);
    try std.testing.expectEqual(@as(usize, 6), j.get(active, "drafts").?.array.items.len);
    for (j.get(active, "drafts").?.array.items) |row| {
        try std.testing.expectEqual(@as(i64, @intCast(files.len)), try j.integer(row, "attachmentCount", 0));
        try std.testing.expect(j.get(row, "attachments") == null and j.get(row, "to") == null);
        try std.testing.expect(try j.boolean(row, "summaryOnly", false));
    }
    store.state.operations = operations;
    try store.save();
    try history.compact(&store, true);
    try std.testing.expectEqual(@as(usize, 0), store.state.drafts.len);
    fixed.reset();
    const retained = try history.list(&store, fixed.allocator(), .draft, "", 100);
    try std.testing.expectEqual(@as(usize, 6), j.get(retained, "items").?.array.items.len);
    for (j.get(retained, "items").?.array.items) |item| try std.testing.expectEqual(@as(i64, @intCast(files.len)), try j.integer(j.get(item, "draft").?, "attachmentCount", 0));
    const exact = try store.draft(first_id);
    try std.testing.expectEqualStrings("Exact source", exact.bodyText);
    try std.testing.expectEqual(files.len, exact.attachments.len);
    try std.testing.expectEqualStrings(filename, exact.attachments[files.len - 1].filename);
    try std.testing.expectEqualStrings("AA", exact.attachments[files.len - 1].data);
}

test "native capacity: active draft list byte pagination preserves all 128 exact subjects" {
    const summaries = @import("terminal/draft_summary.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subject = try a.alloc(u8, @import("terminal/mail_limits.zig").subject_bytes);
    @memset(subject, '"'); // Escaped wire size, not source length, controls the page.
    const drafts = try a.alloc(t.Draft, 128);
    for (drafts, 0..) |*draft, index| draft.* = .{ .id = try std.fmt.allocPrint(a, "draft-{d}", .{index}), .subject = subject };
    var cursor: []const u8 = "";
    var seen: usize = 0;
    while (true) {
        const response = try summaries.list(a, drafts, &.{}, cursor, 100);
        try std.testing.expect(try summaries.encodedBytes(response) < t.Limits.request_bytes);
        const rows = j.get(response, "drafts").?.array.items;
        try std.testing.expect(rows.len > 0 and rows.len < 100);
        for (rows) |row| {
            try std.testing.expectEqualStrings(drafts[seen].id, j.text(row, "id"));
            try std.testing.expectEqualStrings(subject, j.text(row, "subject"));
            seen += 1;
        }
        cursor = j.text(response, "nextCursor");
        if (cursor.len == 0) break;
    }
    try std.testing.expectEqual(drafts.len, seen);
    try std.testing.expectError(error.InvalidDraftCursor, summaries.list(a, drafts, &.{}, "D:removed-source", 100));
}

test "native capacity: retained receipt byte pagination resumes before the unreturned candidate" {
    const summaries = @import("terminal/draft_summary.zig");
    const storage = @import("terminal/store.zig");
    const history = @import("terminal/operation_history.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calendar = try a.alloc(u8, 1024 * 1024);
    @memset(calendar, 'x');
    var store = try storage.Store.open(std.testing.io, a, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/receipt-pages", .{tmp.sub_path}), "self@example.test", .{ .fixtures = true });
    defer store.close();
    const operations = try a.alloc(storage.Operation, 4);
    for (operations, 0..) |*operation, index| operation.* = .{ .id = try std.fmt.allocPrint(a, "receipt-{d}", .{index}), .hash = "retained-hash", .outcome = "rejected", .icalendar = calendar };
    store.state.operations = operations;
    try store.save();
    try history.compact(&store, true);
    var cursor: []const u8 = "";
    var seen: [4]bool = @splat(false);
    var total: usize = 0;
    const response_buffer = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(response_buffer);
    while (true) {
        // A page budget bounds response retention even though more receipts
        // are present and must be examined to find the stopping cursor.
        var page_memory: std.heap.FixedBufferAllocator = .init(response_buffer);
        const page = try history.list(&store, page_memory.allocator(), .operation, cursor, 100);
        try std.testing.expect(try summaries.encodedBytes(page) < t.Limits.request_bytes);
        const rows = j.get(page, "items").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), rows.len);
        for (rows) |row| {
            const index = try std.fmt.parseInt(usize, j.text(row, "id")[8..], 10);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            total += 1;
            try std.testing.expectEqualStrings(calendar, j.text(row, "icalendar"));
        }
        cursor = try a.dupe(u8, j.text(page, "nextCursor"));
        if (cursor.len == 0) break;
    }
    try std.testing.expectEqual(@as(usize, 4), total);
}

test "native capacity: 100 recipients and 40 tiny files survive save reopen MIME and Gmail handoff" {
    if (!t.Limits.native) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var header: std.ArrayList(u8) = .empty;
    for (0..100) |index| try header.appendSlice(a, try std.fmt.allocPrint(a, "{s}Person {d} <person-{d}@example.test>", .{ if (index == 0) "" else ", ", index, index }));
    const addresses = try recipients.parseOutgoing(a, header.items);
    try std.testing.expectEqual(@as(usize, 100), addresses.len);
    const files = try a.alloc(t.Attachment, 40);
    for (files, 0..) |*file, index| file.* = .{ .id = try std.fmt.allocPrint(a, "file-{d}", .{index}), .filename = try std.fmt.allocPrint(a, "file-{d}.txt", .{index}), .mimeType = "text/plain", .size = 3, .data = "YWJj" };
    const storage = @import("terminal/store.zig");
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/capacity", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    defer store.close();
    const saved = try store.putDraft(.{ .to = addresses, .subject = "Capacity", .bodyText = "Exact body", .attachments = files }, null);
    const id = try a.dupe(u8, saved.id);
    store.close();
    store = try storage.Store.open(std.testing.io, a, root, "self@example.test", .{ .fixtures = true });
    const reopened = try store.draft(id);
    try std.testing.expectEqual(@as(usize, 100), reopened.to.len);
    try std.testing.expectEqual(@as(usize, 40), reopened.attachments.len);
    var spool = try @import("terminal/draft_gmail_spool.zig").create(&store, reopened, "<capacity@example.test>");
    defer spool.close();
    var sender: recipients.Mailbox = .{};
    try sender.address.set(store.state.account);
    const measured = try @import("terminal/send_spool.zig").measure(&store, .{ .from = sender, .destinations = .{ .to = reopened.to }, .subject = reopened.subject, .body = reopened.bodyText, .message_id = "<capacity@example.test>", .date = "Mon, 05 Oct 2026 12:00:00 +0000" }, reopened.attachments, &.{});
    try std.testing.expectEqual(spool.size, measured);
    var reader = try spool.reader();
    defer reader.close();
    const raw = try a.alloc(u8, spool.size);
    var offset: usize = 0;
    while (offset < raw.len) offset += try @TypeOf(reader).read(&reader, raw[offset..]);
    var end: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try @TypeOf(reader).read(&reader, &end));
    const parsed = try mime.parse(raw, a);
    try std.testing.expectEqual(@as(usize, 100), parsed.to.len);
    try std.testing.expectEqualStrings("person-99@example.test", parsed.to[99].address);
    try std.testing.expectEqual(@as(usize, 40), parsed.attachments.len);
    for (parsed.attachments) |file| try std.testing.expectEqualStrings("abc", file.data);
}

test "native capacity: reply all excludes over 32 aliases and enforces 500 combined destinations" {
    if (!t.Limits.native) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const participants = try a.alloc(t.Address, 100);
    const aliases = try a.alloc([]const u8, 40);
    for (participants, 0..) |*address, index| address.* = .{ .address = try std.fmt.allocPrint(a, "participant-{d}@example.test", .{index}) };
    for (aliases, participants[0..40]) |*alias, address| alias.* = address.address;
    const reply = try recipients.replyAddresses(a, "self@example.test", aliases, .{ .address = "sender@example.test" }, &.{}, participants, &.{}, true);
    try std.testing.expectEqual(@as(usize, 1), reply.to.len);
    try std.testing.expectEqual(@as(usize, 60), reply.cc.len);
    try std.testing.expectEqualStrings("participant-40@example.test", reply.cc[0].address);
    const maximum = try a.alloc(t.Address, 500);
    for (maximum, 0..) |*address, index| address.* = .{ .address = try std.fmt.allocPrint(a, "recipient-{d}@example.test", .{index}) };
    try @import("terminal/draft_codec.zig").validateDraft(.{ .to = maximum }, true);
    try std.testing.expectError(error.TooManyRecipients, @import("terminal/draft_codec.zig").validateDraft(.{ .to = maximum, .cc = &.{.{ .address = "extra@example.test" }} }, true));
}

test "native capacity: recipient ownership releases partial parser and reply allocations" {
    if (!t.Limits.native) return error.SkipZigTest;
    const Probe = struct {
        fn run(a: std.mem.Allocator) !void {
            const parsed = try recipients.parseOutgoing(a, "One <one@example.test>, Two <two@example.test>");
            defer recipients.deinitIncoming(parsed, a);
            const reply = try recipients.replyAddresses(a, "self@example.test", &.{}, .{ .address = "sender@example.test", .name = "Sender" }, &.{}, parsed, &.{}, true);
            defer reply.deinit(a);
            try std.testing.expectEqual(@as(usize, 2), reply.cc.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "native capacity: 120 calendar overrides clone save reopen and discard independently" {
    if (!t.Limits.native) return error.SkipZigTest;
    const sources = @import("terminal/calendar_sources.zig");
    const prefs = @import("terminal/preferences.zig");
    var value: prefs.Preferences = .{};
    defer value.calendar.deinit();
    const a = std.testing.allocator;
    for (0..120) |index| {
        var buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "calendar-{d}", .{index});
        try value.calendar.set(a, .{ .account = "self@example.test", .calendar_id = id }, index % 2 == 0, .green);
    }
    var pending = try value.calendar.clone(a);
    defer pending.deinit();
    const target: @import("terminal/calendar_types.zig").Target = .{ .account = "self@example.test", .calendar_id = "calendar-119" };
    try pending.set(a, target, true, .orange);
    try std.testing.expect(!value.calendar.find(target).?.visible);
    const bytes = try prefs.encode(a, &value);
    defer a.free(bytes);
    var reopened = try prefs.parse(a, bytes);
    defer reopened.calendar.deinit();
    try std.testing.expectEqual(@as(usize, 120), reopened.calendar.choices.items.len);
    try std.testing.expectEqual(sources.Color.green, reopened.calendar.find(target).?.color.?);
    try std.testing.expect(!reopened.calendar.find(target).?.visible);
}

test "native capacity: calendar source growth allocation failure preserves active documents" {
    if (!t.Limits.native) return error.SkipZigTest;
    const ui = @import("terminal/calendar_ui.zig");
    const a = std.testing.allocator;
    var state: ui.State = .{};
    defer state.deinit(a);
    try state.resizeSources(a, 2);
    try state.source_snapshots[0].replace(a, .{ .string = "old source" });
    for (0..2) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, state.resizeSources(failing.allocator(), 120));
        try std.testing.expectEqual(@as(usize, 2), state.source_snapshots.len);
        try std.testing.expectEqualStrings("old source", state.source_snapshots[0].value.string);
    }
    try state.resizeSources(a, 120);
    try std.testing.expectEqual(@as(usize, 120), state.source_snapshots.len);
    for (state.source_snapshots) |document| try std.testing.expect(document.value == .null);
}

test "native capacity: CLI attachment planning accepts 40 distinct tiny paths without truncation" {
    if (!t.Limits.native) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try a.alloc([]const u8, 40);
    for (paths, 0..) |*path, index| {
        const name = try std.fmt.allocPrint(a, "file-{d}.txt", .{index});
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "abc" });
        path.* = try temporary.dir.realPathFileAlloc(std.testing.io, name, a);
    }
    const Oracle = struct {
        calls: usize = 0,
        fn call(ctx: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            const request = try std.json.parseFromSliceLeaky(j.Value, allocator, raw, .{});
            try std.testing.expectEqualStrings("draft.create", j.text(request, "cmd"));
            const files = j.get(j.get(request, "draft").?, "attachments").?.array.items;
            try std.testing.expectEqual(@as(usize, 40), files.len);
            for (files, 0..) |file, index| {
                try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file-{d}.txt", .{index}), j.text(file, "filename"));
                try std.testing.expectEqualStrings("YWJj", j.text(file, "data"));
            }
            return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"id\":\"saved\"}}");
        }
    };
    var oracle: Oracle = .{};
    _ = try @import("terminal/cli_plan.zig").execute(std.testing.io, a, .{ .ctx = &oracle, .callFn = Oracle.call }, try j.value(a, .{ .cmd = "draft.create", .account = "self@example.test", .draft = .{ .bodyText = "Body" } }), .{ .attachments = paths });
    try std.testing.expectEqual(@as(usize, 1), oracle.calls);
}

test "native capacity: calendar discovery continues after 24 and named target bypasses discovery pagination" {
    if (!t.Limits.native) return error.SkipZigTest;
    const ct = @import("terminal/calendar_types.zig");
    const provider = @import("terminal/calendar_provider.zig");
    const service = @import("terminal/calendar_service.zig");
    const Oracle = struct {
        lists: usize = 0,
        gets: usize = 0,
        fn send(ctx: *anyopaque, a: std.mem.Allocator, request: provider.Request) anyerror!service.Response {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(provider.OperationKind.calendar_list, request.kind);
            if (std.mem.indexOf(u8, request.url, "calendarList?") != null) {
                self.lists += 1;
                const second = std.mem.indexOf(u8, request.url, "pageToken=next") != null;
                const entries = try a.alloc(j.Value, if (second) 20 else 250);
                for (entries, 0..) |*entry, index| entry.* = try j.value(a, .{ .id = try std.fmt.allocPrint(a, "calendar-{d}", .{index + @as(usize, if (second) 250 else 0)}), .summary = "Synthetic", .timeZone = "UTC", .accessRole = "reader", .selected = true });
                return .{ .account = request.target.account, .status = 200, .body = try j.encodeAlloc(a, .{ .items = entries, .nextPageToken = if (second) "" else "next" }, .{}) };
            }
            self.gets += 1;
            try std.testing.expectEqualStrings(provider.base_url ++ "/users/me/calendarList/named%2Foutside", request.url);
            return .{ .account = request.target.account, .status = 200, .body = "{\"id\":\"named/outside\",\"summary\":\"Named\",\"timeZone\":\"UTC\",\"accessRole\":\"reader\"}" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: Oracle = .{};
    const svc: service.Service = .{ .a = a, .grants = .{ .account = "self@example.test", .calendar_list = true, .read_events = true }, .transport = .{ .context = &oracle, .sendFn = Oracle.send }, .now_ms = 0 };
    const list = try svc.list();
    try std.testing.expect(list.complete);
    try std.testing.expectEqual(@as(usize, 270), list.calendars.len);
    try std.testing.expectEqualStrings("calendar-269", list.calendars[269].target.calendar_id);
    const target: ct.Target = .{ .account = "self@example.test", .calendar_id = "named/outside" };
    const named = try svc.loadCalendar(target);
    try std.testing.expect(named.target.eql(target));
    try std.testing.expectEqual(@as(usize, 2), oracle.lists);
    try std.testing.expectEqual(@as(usize, 1), oracle.gets);
    try std.testing.expectError(error.CalendarAccountMismatch, svc.loadCalendar(.{ .account = "other@example.test", .calendar_id = "named/outside" }));
    try std.testing.expectEqual(@as(usize, 1), oracle.gets);
}
