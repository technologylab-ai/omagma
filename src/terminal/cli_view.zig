//! Response views requested by agents. Defaults stay compatible apart from
//! additive fields (rfcMessageId, ISO-8601 siblings of epoch values, hasMore,
//! resolvedDate); requested views only reshape an already committed result
//! and never change what was read, saved or sent.
const std = @import("std");
const j = @import("json.zig");
const Value = j.Value;
const A = std.mem.Allocator;

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn oneOf(command: []const u8, names: []const []const u8) bool {
    for (names) |name| if (eq(command, name)) return true;
    return false;
}
/// RFC 3339 UTC for an epoch in milliseconds (second precision).
pub fn isoInstant(a: A, milliseconds: i64) !?[]const u8 {
    const seconds = @divFloor(milliseconds, 1000);
    if (seconds < 0 or seconds > 253402300799) return null;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year_day.year, month_day.month.numeric(), @as(u8, month_day.day_index) + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() });
}
fn isoDate(a: A, days: i64) !?[]const u8 {
    const text = (try isoInstant(a, std.math.mul(i64, days, 86400000) catch return null)) orelse return null;
    return text[0..10];
}
fn integerField(value: Value, key: []const u8) ?i64 {
    const field = j.get(value, key) orelse return null;
    return if (field == .integer) field.integer else null;
}

const Body = enum { both, text, html, none };
const Options = struct {
    body: Body = .both,
    max_body_bytes: ?usize = null,
    strip_quoted: bool = false,
    attachment_data: bool = true,
    summary: bool = false,
    fn requested(self: Options) bool {
        return self.body != .both or self.max_body_bytes != null or self.strip_quoted or !self.attachment_data;
    }
};
fn options(request: Value) !Options {
    var result: Options = .{};
    if (j.get(request, "body")) |value| result.body = std.meta.stringToEnum(Body, try j.string(value)) orelse return error.InvalidBodySelection;
    if (j.get(request, "maxBodyBytes")) |value| {
        if (value != .integer or value.integer < 0 or value.integer > 64 * 1024 * 1024) return error.InvalidMaxBodyBytes;
        result.max_body_bytes = @intCast(value.integer);
    }
    result.strip_quoted = try j.boolean(request, "stripQuoted", false);
    result.attachment_data = try j.boolean(request, "attachmentData", true);
    const view = j.text(request, "view");
    const detail = j.text(request, "detail");
    result.summary = eq(view, "summary") or eq(detail, "summary");
    return result;
}
/// Reject malformed view options before dispatch, so nothing executes with a
/// view that would later be ignored.
pub fn validate(request: Value) !void {
    _ = try options(request);
    const command = j.text(request, "cmd");
    if (j.get(request, "view")) |value| {
        const view = try j.string(value);
        if (oneOf(command, &.{ "mail.list", "mail.search", "mail.sync", "mail.thread", "contacts.list", "contacts.search" })) {
            if (!eq(view, "full") and !eq(view, "summary")) return error.InvalidView;
        } else if (oneOf(command, &.{ "mail.archive", "mail.trash", "mail.restore", "mail.mark" })) {
            if (!eq(view, "receipt") and !eq(view, "message")) return error.InvalidView;
        }
    }
    if (j.get(request, "detail")) |value| if (!eq(try j.string(value), "full") and !eq(value.string, "summary")) return error.InvalidView;
    if (j.get(request, "fields")) |value| {
        if (value != .array or value.array.items.len == 0 or value.array.items.len > 64) return error.InvalidFields;
        for (value.array.items) |item| if (item != .string or item.string.len == 0 or item.string.len > 64) return error.InvalidFields;
    }
}
/// The longest prefix of at most limit bytes that ends on a UTF-8 boundary.
fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}
fn quoteLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return trimmed.len != 0 and trimmed[0] == '>';
}
fn blank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}
/// "On … wrote:" and its common localized forms (reader_tools folds the
/// English form; replies here may come from any client).
fn attribution(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.endsWith(u8, trimmed, "wrote:") or std.mem.endsWith(u8, trimmed, "a écrit :") or std.mem.endsWith(u8, trimmed, "a écrit:") or std.mem.endsWith(u8, trimmed, "escribió:")) return true;
    // German clients name the sender after the verb: "Am …, schrieb Alex <a@…>:".
    return std.mem.endsWith(u8, trimmed, ":") and (std.mem.indexOf(u8, trimmed, " schrieb ") != null or std.mem.endsWith(u8, trimmed, "schrieb:"));
}
fn underscoreRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 10) return false;
    for (trimmed) |byte| if (byte != '_') return false;
    return true;
}
fn headerLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    for ([_][]const u8{ "From:", "Sent:", "Von:", "Gesendet:", "De :", "De:", "Envoyé :", "Enviado:" }) |name| if (std.ascii.startsWithIgnoreCase(trimmed, name)) return true;
    return false;
}
pub const Stripped = struct { text: []const u8, removed: bool };
/// Plain-text body without reply history. Quoted lines are removed only when
/// an attribution line ("On … wrote:") introduces them or when they form the
/// trailing quoted block; inline replies between quotes stay intact. The text
/// is cut at "-----Original Message-----", or at an underscore rule that a
/// From:/Sent: header block follows. removed reports whether anything that
/// was not whitespace was dropped.
pub fn stripQuoted(a: A, text: []const u8) !Stripped {
    var all: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try all.append(a, line);
    var end = all.items.len;
    for (all.items, 0..) |line, index| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (eq(trimmed, "-----Original Message-----")) {
            end = index;
            break;
        }
        if (underscoreRule(line)) {
            var next = index + 1;
            while (next < all.items.len and blank(all.items[next])) next += 1;
            if (next < all.items.len and headerLine(all.items[next])) {
                end = index;
                break;
            }
        }
    }
    var removed = false;
    for (all.items[end..]) |line| removed = removed or !blank(line);
    const drop = try a.alloc(bool, end);
    @memset(drop, false);
    var index: usize = 0;
    while (index < end) {
        if (!quoteLine(all.items[index])) {
            index += 1;
            continue;
        }
        var stop = index;
        while (stop < end and (quoteLine(all.items[stop]) or blank(all.items[stop]))) stop += 1;
        // Blank lines that only trail the block belong to what follows.
        var last = stop;
        while (last > index and blank(all.items[last - 1])) last -= 1;
        var before = index;
        while (before > 0 and blank(all.items[before - 1])) before -= 1;
        const introduced = before > 0 and attribution(all.items[before - 1]);
        const trailing = stop == end;
        if (introduced or trailing) {
            for (index..last) |line| drop[line] = true;
            if (introduced) drop[before - 1] = true;
            removed = true;
        }
        index = stop;
    }
    var kept: std.ArrayList([]const u8) = .empty;
    for (all.items[0..end], drop) |line, dropped| if (!dropped) try kept.append(a, line);
    const joined = try std.mem.join(a, "\n", kept.items);
    return .{ .text = std.mem.trimEnd(u8, joined, " \t\r\n"), .removed = removed };
}
fn message(a: A, input: Value, selected: Options) !Value {
    if (input != .object) return input;
    var out = try j.copyObject(a, input);
    const rfc = j.text(input, "messageId");
    if (rfc.len != 0 and j.get(input, "rfcMessageId") == null) try out.object.put(a, "rfcMessageId", .{ .string = rfc });
    if (integerField(input, "receivedAt")) |stamp| if (stamp > 0) if (try isoInstant(a, stamp)) |text| try out.object.put(a, "receivedAtIso", .{ .string = text });
    if (!selected.requested()) return out;
    // Select first: truncation and quote flags describe only returned parts.
    if (selected.body == .text or selected.body == .none) _ = out.object.orderedRemove("bodyHtml");
    if (selected.body == .html or selected.body == .none) _ = out.object.orderedRemove("bodyText");
    if (j.get(out, "bodyText")) |value| if (value == .string) {
        var text = value.string;
        if (selected.strip_quoted) {
            const stripped = try stripQuoted(a, text);
            if (stripped.removed) try out.object.put(a, "quotedStripped", .{ .bool = true });
            text = stripped.text;
        }
        if (selected.max_body_bytes) |limit| if (text.len > limit) {
            try out.object.put(a, "bodyTruncated", .{ .bool = true });
            try out.object.put(a, "bodyBytes", .{ .integer = @intCast(text.len) });
            text = utf8Prefix(text, limit);
        };
        try out.object.put(a, "bodyText", .{ .string = text });
    };
    if (selected.max_body_bytes) |limit| if (j.get(out, "bodyHtml")) |value| if (value == .string and value.string.len > limit) {
        try out.object.put(a, "bodyTruncated", .{ .bool = true });
        try out.object.put(a, "bodyHtmlBytes", .{ .integer = @intCast(value.string.len) });
        try out.object.put(a, "bodyHtml", .{ .string = utf8Prefix(value.string, limit) });
    };
    if (!selected.attachment_data) if (j.get(out, "attachments")) |files| if (files == .array) {
        var trimmed: Value = .{ .array = .init(a) };
        for (files.array.items) |file| {
            if (file != .object or j.text(file, "data").len == 0) {
                try trimmed.array.append(file);
                continue;
            }
            var copy = try j.copyObject(a, file);
            _ = copy.object.orderedRemove("data");
            try copy.object.put(a, "dataOmitted", .{ .bool = true });
            try trimmed.array.append(copy);
        }
        try out.object.put(a, "attachments", trimmed);
    };
    return out;
}
fn putText(a: A, out: *Value, key: []const u8, source: Value) !void {
    const text = j.text(source, key);
    if (text.len != 0) try out.object.put(a, key, .{ .string = text });
}
fn compactAddress(a: A, address: Value) !Value {
    var out = j.object(a);
    try putText(a, &out, "address", address);
    try putText(a, &out, "name", address);
    return out;
}
/// One compact list row: identity, envelope, preview and state only.
fn messageRow(a: A, input: Value) !Value {
    var out = j.object(a);
    try putText(a, &out, "id", input);
    try putText(a, &out, "threadId", input);
    if (j.get(input, "from")) |from| if (from == .object and j.text(from, "address").len != 0) try out.object.put(a, "from", try compactAddress(a, from));
    if (j.get(input, "to")) |to| if (to == .array and to.array.items.len != 0) {
        var list: Value = .{ .array = .init(a) };
        for (to.array.items) |item| try list.array.append(try compactAddress(a, item));
        try out.object.put(a, "to", list);
    };
    try putText(a, &out, "subject", input);
    try putText(a, &out, "snippet", input);
    if (integerField(input, "receivedAt")) |stamp| if (stamp > 0) {
        try out.object.put(a, "receivedAt", .{ .integer = stamp });
        if (try isoInstant(a, stamp)) |text| try out.object.put(a, "receivedAtIso", .{ .string = text });
    };
    if (j.boolean(input, "unread", false) catch false) try out.object.put(a, "unread", .{ .bool = true });
    if (j.get(input, "labels")) |labels| if (labels == .array and labels.array.items.len != 0) try out.object.put(a, "labels", labels);
    if (j.get(input, "attachments")) |files| if (files == .array and files.array.items.len != 0) try out.object.put(a, "attachmentCount", .{ .integer = @intCast(files.array.items.len) });
    return out;
}
fn contactRow(a: A, input: Value) !Value {
    var out = j.object(a);
    try putText(a, &out, "resourceName", input);
    try putText(a, &out, "name", input);
    if (j.get(input, "emails")) |emails| if (emails == .array and emails.array.items.len != 0) {
        var list: Value = .{ .array = .init(a) };
        for (emails.array.items) |email| if (j.text(email, "address").len != 0) try list.array.append(.{ .string = j.text(email, "address") });
        try out.object.put(a, "emails", list);
    };
    return out;
}
fn pointIso(a: A, point: Value) !?[]const u8 {
    const value = integerField(point, "value") orelse return null;
    const kind = j.text(point, "kind");
    return if (eq(kind, "instant")) isoInstant(a, value) else if (eq(kind, "date")) isoDate(a, value) else null;
}
fn eventRow(a: A, input: Value) !Value {
    var out = j.object(a);
    try putText(a, &out, "id", input);
    try putText(a, &out, "summary", input);
    for ([_][]const u8{ "start", "end" }) |key| if (j.get(input, key)) |point| if (try pointIso(a, point)) |text| try out.object.put(a, key, .{ .string = text });
    if (eq(j.text(j.get(input, "start") orelse .null, "kind"), "date")) try out.object.put(a, "allDay", .{ .bool = true });
    try putText(a, &out, "location", input);
    if (j.text(input, "join_url").len != 0) try out.object.put(a, "joinUrl", .{ .string = j.text(input, "join_url") });
    try putText(a, &out, "organizer", input);
    const response = j.text(input, "response");
    if (response.len != 0 and !eq(response, "unknown")) try out.object.put(a, "response", .{ .string = response });
    if (j.text(input, "recurring_event_id").len != 0) try out.object.put(a, "recurringEventId", .{ .string = j.text(input, "recurring_event_id") });
    if (j.boolean(input, "cancelled", false) catch false) try out.object.put(a, "cancelled", .{ .bool = true });
    if (integerField(input, "attendee_count")) |count| if (count > 0) try out.object.put(a, "attendeeCount", .{ .integer = count });
    return out;
}
/// Adds startIso/endIso/originalStartIso beside calendar points and
/// createdAtIso/dueAtIso beside queue epochs. Point objects themselves stay
/// byte-identical: clients decode them as exact {kind,value,zone} records.
fn annotate(a: A, input: Value, depth: usize) !Value {
    if (depth > 8) return input;
    switch (input) {
        .array => |list| {
            var out: Value = .{ .array = .init(a) };
            for (list.items) |item| try out.array.append(try annotate(a, item, depth + 1));
            return out;
        },
        .object => |map| {
            var out = j.object(a);
            var it = map.iterator();
            while (it.next()) |field| try out.object.put(a, field.key_ptr.*, try annotate(a, field.value_ptr.*, depth + 1));
            for ([_][]const u8{ "start", "end", "original_start" }, [_][]const u8{ "startIso", "endIso", "originalStartIso" }) |key, name| if (j.get(input, key)) |point| if (point == .object and j.get(input, name) == null) if (try pointIso(a, point)) |text| try out.object.put(a, name, .{ .string = text });
            for ([_][]const u8{ "createdAtMs", "dueAtMs" }, [_][]const u8{ "createdAtIso", "dueAtIso" }) |key, name| if (integerField(input, key)) |stamp| if (stamp > 0 and j.get(input, name) == null) if (try isoInstant(a, stamp)) |text| try out.object.put(a, name, .{ .string = text });
            return out;
        },
        else => return input,
    }
}
fn hex(a: A, bytes: Value) !?[]const u8 {
    if (bytes == .string and bytes.string.len == 32) {
        const encoded = std.fmt.bytesToHex(bytes.string[0..32].*, .lower);
        return try a.dupe(u8, &encoded);
    }
    if (bytes != .array or bytes.array.items.len != 32) return null;
    const out = try a.alloc(u8, 64);
    for (bytes.array.items, 0..) |item, index| {
        if (item != .integer or item.integer < 0 or item.integer > 255) return null;
        _ = std.fmt.bufPrint(out[index * 2 ..][0..2], "{x:0>2}", .{@as(u8, @intCast(item.integer))}) catch return null;
    }
    return out;
}
fn mapArray(a: A, data: *Value, key: []const u8, row: *const fn (A, Value) anyerror!Value) !void {
    const list = j.get(data.*, key) orelse return;
    if (list != .array) return;
    var out: Value = .{ .array = .init(a) };
    for (list.array.items) |item| try out.array.append(try row(a, item));
    try data.object.put(a, key, out);
}
/// Requested keys plus every truncation/paging/warning marker present, so a
/// projection can never make an incomplete value look complete.
fn project(a: A, input: Value, keep: []const []const u8) !Value {
    if (input != .object) return input;
    var out = j.object(a);
    for (keep) |name| if (j.get(input, name)) |value| try out.object.put(a, name, value);
    for (@import("cli_api.zig").kept_markers) |name| if (j.get(input, name)) |value| if (signals(name, value)) try out.object.put(a, name, value);
    return out;
}
/// Whether a marker reports something an agent must see: a true flag (or
/// complete:false), a nonempty warning or cursor, a size or warning object.
fn signals(name: []const u8, value: Value) bool {
    return switch (value) {
        .bool => |flag| if (eq(name, "complete")) !flag else flag,
        .string => |text| text.len != 0,
        .null => false,
        else => true,
    };
}
const list_keys = [_][]const u8{ "messages", "events", "contacts", "drafts", "items", "queue", "operations", "entries", "accounts", "calendars", "identities", "recipients" };

pub fn shape(a: A, request: Value, data: Value, resolved_date: ?[]const u8) !Value {
    if (data != .object) return data;
    const command = j.text(request, "cmd");
    const selected = try options(request);
    var result = try j.copyObject(a, data);
    if (resolved_date) |date| try result.object.put(a, "resolvedDate", .{ .string = date });
    const listing = oneOf(command, &.{ "mail.list", "mail.search", "mail.sync" });
    if (listing or oneOf(command, &.{ "mail.thread", "reminder.list" })) {
        if (j.get(result, "messages")) |list| if (list == .array) {
            var out: Value = .{ .array = .init(a) };
            for (list.array.items) |item| try out.array.append(if (selected.summary) try messageRow(a, item) else try message(a, item, if (eq(command, "mail.thread")) selected else .{}));
            try result.object.put(a, "messages", out);
        };
        if (listing) if (j.get(result, "nextCursor")) |cursor| try result.object.put(a, "hasMore", .{ .bool = cursor == .string and cursor.string.len != 0 });
    } else if (eq(command, "mail.read")) {
        result = try message(a, result, selected);
    } else if (oneOf(command, &.{ "contacts.list", "contacts.search" }) and selected.summary) {
        try mapArray(a, &result, "contacts", contactRow);
        _ = result.object.orderedRemove("contactWarnings");
    } else if (std.mem.startsWith(u8, command, "calendar.")) {
        if (eq(command, "calendar.agenda") and selected.summary) if (j.get(result, "snapshot")) |snapshot| {
            var events: Value = .{ .array = .init(a) };
            if (j.get(snapshot, "events")) |list| if (list == .array) for (list.array.items) |event| try events.array.append(try eventRow(a, event));
            const calendar = j.get(result, "calendar") orelse Value.null;
            _ = result.object.orderedRemove("snapshot");
            _ = result.object.orderedRemove("calendar");
            var empty: std.ArrayList([]const u8) = .empty;
            var it = result.object.iterator();
            while (it.next()) |field| if (field.value_ptr.* == .string and field.value_ptr.string.len == 0) try empty.append(a, field.key_ptr.*);
            for (empty.items) |key| _ = result.object.orderedRemove(key);
            try result.object.put(a, "calendarId", .{ .string = j.text(j.get(calendar, "target") orelse .null, "calendar_id") });
            try putText(a, &result, "summary", calendar);
            if (j.text(calendar, "time_zone").len != 0) try result.object.put(a, "timeZone", .{ .string = j.text(calendar, "time_zone") });
            try result.object.put(a, "events", events);
        };
        if (eq(command, "calendar.invitation-plan")) if (j.get(result, "invitation")) |invitation| if (invitation == .object) {
            var copy = try j.copyObject(a, invitation);
            // The exact source is retained; its unfolded duplicate is not.
            _ = copy.object.orderedRemove("unfolded");
            if (try hex(a, j.get(invitation, "source_hash") orelse .null)) |text| try copy.object.put(a, "source_hash", .{ .string = text });
            try result.object.put(a, "invitation", copy);
        };
        result = try annotate(a, result, 0);
    } else if (eq(command, "draft.queue") or std.mem.startsWith(u8, command, "queue.") or eq(command, "history.queues")) {
        result = try annotate(a, result, 0);
    }
    // Writes and dry runs are refused before dispatch; never reshape one here.
    if (j.get(request, "fields")) |fields| if (fields == .array and @import("cli_contract.zig").projectionAllowed(request)) {
        const keep = try a.alloc([]const u8, fields.array.items.len);
        for (fields.array.items, keep) |item, *name| name.* = try j.string(item);
        var projected = false;
        for (list_keys) |key| if (j.get(result, key)) |list| if (list == .array) {
            var out: Value = .{ .array = .init(a) };
            for (list.array.items) |item| try out.array.append(try project(a, item, keep));
            try result.object.put(a, key, out);
            projected = true;
        };
        if (!projected) if (j.get(result, "snapshot")) |snapshot| if (j.get(snapshot, "events")) |list| if (list == .array) {
            var copy = try j.copyObject(a, snapshot);
            var out: Value = .{ .array = .init(a) };
            for (list.array.items) |item| try out.array.append(try project(a, item, keep));
            try copy.object.put(a, "events", out);
            try result.object.put(a, "snapshot", copy);
            projected = true;
        };
        if (!projected) result = try project(a, result, keep);
    };
    return result;
}

fn parse(a: A, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, raw, .{});
}
test "cli view: summary rows keep identity, preview and state and drop bodies and empty values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try parse(a, "{\"messages\":[{\"id\":\"m-1\",\"threadId\":\"t-1\",\"from\":{\"address\":\"alex@example.org\",\"name\":\"\"},\"to\":[{\"address\":\"self@example.test\",\"name\":\"Self\"}],\"subject\":\"Fictional\",\"snippet\":\"\",\"bodyText\":\"large body\",\"messageId\":\"<m-1@example.org>\",\"labels\":[\"INBOX\"],\"receivedAt\":1794042060000,\"unread\":false,\"attachments\":[{\"id\":\"1\"}]}],\"nextCursor\":\"L1\"}");
    const shaped = try shape(a, try parse(a, "{\"cmd\":\"mail.list\",\"view\":\"summary\"}"), data, null);
    const row = j.get(shaped, "messages").?.array.items[0];
    try std.testing.expectEqualStrings("m-1", j.text(row, "id"));
    try std.testing.expectEqualStrings("2026-11-07T09:01:00Z", j.text(row, "receivedAtIso"));
    try std.testing.expectEqual(@as(i64, 1), j.get(row, "attachmentCount").?.integer);
    for ([_][]const u8{ "bodyText", "snippet", "unread", "messageId" }) |absent| try std.testing.expect(j.get(row, absent) == null);
    try std.testing.expect(j.get(j.get(row, "from").?, "name") == null);
    try std.testing.expect(j.get(shaped, "hasMore").?.bool);
    // Defaults stay complete and only gain additive siblings.
    const full = j.get(try shape(a, try parse(a, "{\"cmd\":\"mail.list\"}"), data, null), "messages").?.array.items[0];
    try std.testing.expectEqualStrings("large body", j.text(full, "bodyText"));
    try std.testing.expectEqualStrings("<m-1@example.org>", j.text(full, "rfcMessageId"));
    try std.testing.expectEqualStrings("<m-1@example.org>", j.text(full, "messageId"));
    const projected = j.get(try shape(a, try parse(a, "{\"cmd\":\"mail.list\",\"fields\":[\"id\",\"subject\"]}"), data, null), "messages").?.array.items[0];
    try std.testing.expectEqual(@as(usize, 2), projected.object.count());
}
test "cli view: body selection, truncation, quote stripping and attachment data are explicit opt-ins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try parse(a, "{\"id\":\"m\",\"threadId\":\"t\",\"bodyText\":\"Thanks, café works.\\n\\nOn Tue, Alex wrote:\\n> Earlier\\n> text\\n\",\"bodyHtml\":\"<p>x</p>\",\"attachments\":[{\"id\":\"1\",\"filename\":\"a.txt\",\"data\":\"QUJD\"}]}");
    const text = try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"body\":\"text\",\"stripQuoted\":true,\"attachmentData\":false}"), data, null);
    try std.testing.expectEqualStrings("Thanks, café works.", j.text(text, "bodyText"));
    try std.testing.expect(j.get(text, "bodyHtml") == null and j.get(text, "quotedStripped").?.bool);
    const file = j.get(text, "attachments").?.array.items[0];
    try std.testing.expect(j.get(file, "data") == null and j.get(file, "dataOmitted").?.bool);
    // A cut inside a multi-byte character ends at the previous boundary.
    const cut = try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"maxBodyBytes\":12}"), data, null);
    try std.testing.expectEqualStrings("Thanks, caf", j.text(cut, "bodyText"));
    try std.testing.expect(j.get(cut, "bodyTruncated").?.bool);
    try std.testing.expectEqual(@as(i64, @intCast(j.text(data, "bodyText").len)), j.get(cut, "bodyBytes").?.integer);
    try std.testing.expect(j.get(cut, "bodyHtml") != null);
    const none = try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"body\":\"none\"}"), data, null);
    try std.testing.expect(j.get(none, "bodyText") == null and j.get(none, "bodyHtml") == null);
    const unchanged = try shape(a, try parse(a, "{\"cmd\":\"mail.read\"}"), data, null);
    try std.testing.expect(j.get(unchanged, "bodyHtml") != null and j.get(j.get(unchanged, "attachments").?.array.items[0], "data") != null);
    try std.testing.expectError(error.InvalidBodySelection, shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"body\":\"markdown\"}"), data, null));
}
test "cli view: calendar points, queue epochs and invitation hashes gain readable siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const agenda = try parse(a, "{\"calendar\":{\"target\":{\"calendar_id\":\"self@example.test\"},\"summary\":\"Fictional\",\"time_zone\":\"UTC\"},\"snapshot\":{\"events\":[{\"id\":\"e\",\"summary\":\"Sync\",\"start\":{\"kind\":\"instant\",\"value\":1794301200000,\"zone\":\"\"},\"end\":{\"kind\":\"date\",\"value\":20767},\"response\":\"unknown\"}]}}");
    const full = try shape(a, try parse(a, "{\"cmd\":\"calendar.agenda\"}"), agenda, "2026-11-10");
    const event = j.get(j.get(full, "snapshot").?, "events").?.array.items[0];
    try std.testing.expectEqualStrings("2026-11-10T09:00:00Z", j.text(event, "startIso"));
    try std.testing.expectEqualStrings("2026-11-10", j.text(event, "endIso"));
    // The point records stay exact for strict decoders.
    try std.testing.expectEqual(@as(usize, 3), j.get(event, "start").?.object.count());
    try std.testing.expectEqualStrings("2026-11-10", j.text(full, "resolvedDate"));
    const summary = try shape(a, try parse(a, "{\"cmd\":\"calendar.agenda\",\"detail\":\"summary\"}"), agenda, null);
    const row = j.get(summary, "events").?.array.items[0];
    try std.testing.expectEqualStrings("2026-11-10T09:00:00Z", j.text(row, "start"));
    try std.testing.expect(j.get(row, "response") == null and j.get(summary, "snapshot") == null);
    try std.testing.expectEqualStrings("self@example.test", j.text(summary, "calendarId"));
    const queued = try shape(a, try parse(a, "{\"cmd\":\"draft.queue\"}"), try parse(a, "{\"queueId\":\"q\",\"createdAtMs\":1794301200000,\"dueAtMs\":1794301210000}"), null);
    try std.testing.expectEqualStrings("2026-11-10T09:00:10Z", j.text(queued, "dueAtIso"));
    // The executor serializes the [32]u8 hash as an array of byte values.
    var hash: Value = .{ .array = .init(a) };
    for (0..32) |index| try hash.array.append(.{ .integer = @intCast(index) });
    var invitation_value = try j.value(a, .{ .source = "BEGIN", .unfolded = "BEGIN" });
    try invitation_value.object.put(a, "source_hash", hash);
    var plan_data = j.object(a);
    try plan_data.object.put(a, "invitation", invitation_value);
    const plan = try shape(a, try parse(a, "{\"cmd\":\"calendar.invitation-plan\"}"), plan_data, null);
    const invitation = j.get(plan, "invitation").?;
    try std.testing.expect(j.get(invitation, "unfolded") == null);
    try std.testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", j.text(invitation, "source_hash"));
}
test "cli view: quoted reply history is removed without touching ordinary text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try stripQuoted(a, "Hello\n\nSee you\n");
    try std.testing.expectEqualStrings("Hello\n\nSee you", plain.text);
    // Trailing whitespace alone is not removed quoted content.
    try std.testing.expect(!plain.removed);
    const outlook = try stripQuoted(a, "Short answer\n\n-----Original Message-----\nFrom: x\n");
    try std.testing.expectEqualStrings("Short answer", outlook.text);
    try std.testing.expect(outlook.removed);
    try std.testing.expectEqualStrings("I wrote: this stays", (try stripQuoted(a, "I wrote: this stays\n> quoted\n")).text);
    // Attribution-introduced history goes, localized forms included.
    const german = try stripQuoted(a, "Passt.\n\nAm Di., 10. Nov. schrieb Alex:\n> Termin?\n");
    try std.testing.expectEqualStrings("Passt.", german.text);
    try std.testing.expect(german.removed);
}
test "cli view: inline replies, quoted examples and underscore rules without headers are real content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Interleaved answers keep the questions they answer.
    const inline_reply = "> Can you do Thursday?\nYes, at 10.\n> And the agenda?\nAttached.";
    const kept = try stripQuoted(a, inline_reply);
    try std.testing.expectEqualStrings(inline_reply, kept.text);
    try std.testing.expect(!kept.removed);
    // A signature or form separator is not an Outlook original-message rule.
    const form = "Please sign here:\n__________________________\nName and date\nThanks";
    const unchanged = try stripQuoted(a, form);
    try std.testing.expectEqualStrings(form, unchanged.text);
    try std.testing.expect(!unchanged.removed);
    // The same rule followed by a header block starts the original message.
    const forwarded = try stripQuoted(a, "See below.\n________________________________\nFrom: Alex <alex@example.org>\nSent: Tuesday\nOld text");
    try std.testing.expectEqualStrings("See below.", forwarded.text);
    try std.testing.expect(forwarded.removed);
    // Quoted context in the middle stays; the attributed trailing block goes.
    const mixed = try stripQuoted(a, "As you said\n> the build is green\nso we ship.\n\nOn Mon, Alex wrote:\n> Ship it?\n> \n");
    try std.testing.expectEqualStrings("As you said\n> the build is green\nso we ship.", mixed.text);
    try std.testing.expect(mixed.removed);
}
test "cli view: truncation and quote flags describe only the body parts returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try parse(a, "{\"id\":\"m\",\"bodyText\":\"short\",\"bodyHtml\":\"<p>a much longer html alternative</p>\"}");
    const text = try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"body\":\"text\",\"maxBodyBytes\":10}"), data, null);
    try std.testing.expectEqualStrings("short", j.text(text, "bodyText"));
    for ([_][]const u8{ "bodyTruncated", "bodyHtmlBytes", "bodyHtml", "bodyBytes" }) |absent| try std.testing.expect(j.get(text, absent) == null);
    const html = try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"body\":\"html\",\"maxBodyBytes\":10}"), data, null);
    try std.testing.expect(j.get(html, "bodyTruncated").?.bool);
    try std.testing.expect(j.get(html, "bodyHtmlBytes") != null and j.get(html, "bodyText") == null);
    const quoted = try parse(a, "{\"id\":\"m\",\"bodyText\":\"Hi\\n\\nOn Mon, Alex wrote:\\n> old\",\"bodyHtml\":\"<p>x</p>\"}");
    try std.testing.expect(j.get(try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"body\":\"html\",\"stripQuoted\":true}"), quoted, null), "quotedStripped") == null);
}
test "cli view: projections keep truncation, paging and warning markers and never reshape writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try parse(a, "{\"id\":\"m\",\"bodyText\":\"0123456789abcdef\",\"decodeWarning\":\"UnsupportedCharset\",\"metadataPartial\":true,\"bodyCacheError\":\"BodyTooLarge\"}");
    const read = try shape(a, try parse(a, "{\"cmd\":\"mail.read\",\"maxBodyBytes\":4,\"stripQuoted\":true,\"fields\":[\"id\"]}"), data, null);
    try std.testing.expectEqualStrings("m", j.text(read, "id"));
    for ([_][]const u8{ "bodyTruncated", "bodyBytes", "decodeWarning", "metadataPartial", "bodyCacheError" }) |marker| try std.testing.expect(j.get(read, marker) != null);
    try std.testing.expect(j.get(read, "bodyText") == null);
    const page = try parse(a, "{\"messages\":[{\"id\":\"m\",\"subject\":\"s\",\"decodeWarning\":\"x\",\"metadataPartial\":true}],\"nextCursor\":\"L1\",\"partial\":true}");
    const listed = try shape(a, try parse(a, "{\"cmd\":\"mail.list\",\"fields\":[\"id\"]}"), page, null);
    const row = j.get(listed, "messages").?.array.items[0];
    try std.testing.expect(j.get(row, "subject") == null and j.get(row, "decodeWarning") != null and j.get(row, "metadataPartial") != null);
    try std.testing.expect(j.get(listed, "hasMore").?.bool and j.get(listed, "partial").?.bool);
    // A receipt is never projected, even if a caller bypassed the contract.
    const receipt = try parse(a, "{\"outcome\":\"unknown\",\"messageId\":\"\",\"canRetryPreparation\":false}");
    for ([_][]const u8{
        "{\"cmd\":\"draft.send\",\"fields\":[\"messageId\"]}",
        "{\"cmd\":\"mail.send\",\"dryRun\":true,\"fields\":[\"sendable\"]}",
        "{\"cmd\":\"invitation.inspect\",\"reconcile\":true,\"fields\":[\"summary\"]}",
    }) |raw| {
        const shaped = try shape(a, try parse(a, raw), receipt, null);
        try std.testing.expectEqualStrings("unknown", j.text(shaped, "outcome"));
        try std.testing.expect(j.get(shaped, "canRetryPreparation") != null);
    }
}
