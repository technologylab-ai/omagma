const std = @import("std");
const b = @import("../bounded.zig");
const j = @import("json.zig");
const mime = @import("mime.zig");
const types = @import("types.zig");
const limits = @import("mail_limits.zig");
const recipients = @import("recipients.zig");
const scratch = @import("../mail_scratch.zig");

/// Only message-local syntax/size failures may become partial rows. Identity,
/// authorization, cancellation, transport failures and allocator exhaustion
/// always retain their ordinary fatal behavior.
pub fn messageRefusal(err: anyerror) bool {
    return switch (err) {
        error.MessageBudgetExceeded, error.ThreadBodyBudgetExceeded, error.BodyTooLarge, error.DecodedMessageTooLarge, error.MessageTooLarge, error.ResponseTooLarge, error.CalendarTooLarge, error.JsonTooManyTokens, error.JsonTooDeep, error.UnsupportedCharset, error.TooManyMimeParts, error.MimeTooDeep, error.BodySizeMismatch, error.AmbiguousCalendarPart, error.AmbiguousHeader, error.AmbiguousSender, error.AttachmentsTooLarge, error.CapacityExceeded, error.ExternalBodyRequired, error.FilenameTooLarge, error.HeaderInjection, error.HeaderTooLarge, error.HeadersTooLarge, error.IncompleteMultipart, error.InvalidAttachmentFilename, error.InvalidAttachmentId, error.InvalidBase64, error.InvalidBody, error.InvalidCharsetData, error.InvalidDate, error.InvalidEncodedWord, error.InvalidHeaders, error.InvalidLabels, error.InvalidMessageId, error.InvalidMimeBoundary, error.InvalidMimeType, error.InvalidQuotedPrintable, error.InvalidUtf8, error.MissingHeaderBoundary, error.MissingMimeBoundary, error.MissingMimeType, error.ReferencesTooLarge, error.TooManyAttachments, error.TooManyHeaders, error.TooManyReferences, error.UnsupportedTransferEncoding, error.InvalidAddress, error.InvalidRecipients, error.RecipientHeaderTooLarge, error.RecipientTooLarge, error.TooManyIncomingRecipients, error.MalformedMessage, error.InvalidJson, error.MissingField, error.InvalidEncoding, error.UnsupportedEncoding, error.SyntaxError, error.ValueTooLong, error.UnexpectedEndOfInput, error.DuplicateField, error.LengthMismatch => true,
        else => false,
    };
}

fn identity(value: j.Value) !void {
    b.identifier(j.text(value, "id")) catch return error.MessageIdentityMismatch;
    b.identifier(j.text(value, "threadId")) catch return error.MessageIdentityMismatch;
}

fn envelopeRefusal(err: anyerror) bool {
    return switch (err) {
        error.AmbiguousSender, error.AmbiguousHeader, error.InvalidAddress, error.InvalidRecipients, error.RecipientHeaderTooLarge, error.RecipientTooLarge, error.TooManyIncomingRecipients, error.CapacityExceeded => true,
        else => false,
    };
}

fn envelopeHeader(name: []const u8) bool {
    inline for (.{ "From", "Sender", "Reply-To", "To", "Cc", "Bcc", "Message-ID", "References", "In-Reply-To" }) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) return true;
    }
    return false;
}

/// Copy only bounded projection keys; large MIME bodies remain borrowed.
fn projection(value: j.Value, a: std.mem.Allocator, metadata: bool, remove_envelope: bool) !j.Value {
    var out = j.object(a);
    for ([_][]const u8{ "id", "threadId", "internalDate", "labelIds", "snippet" }) |key| if (j.get(value, key)) |field| try out.object.put(a, key, field);
    const source = j.get(value, "payload") orelse return error.MissingField;
    if (source != .object) return error.InvalidJson;
    var payload = j.object(a);
    if (!metadata) for ([_][]const u8{ "partId", "mimeType", "filename", "body", "parts" }) |key| if (j.get(source, key)) |field| try payload.object.put(a, key, field);
    if (j.get(source, "headers")) |headers| {
        if (headers != .array or headers.array.items.len > limits.header_count) return error.TooManyHeaders;
        if (remove_envelope) {
            var retained: std.ArrayList(j.Value) = .empty;
            for (headers.array.items) |header| {
                if (!envelopeHeader(j.text(header, "name"))) try retained.append(a, header);
            }
            try payload.object.put(a, "headers", .{ .array = retained.toManaged(a) });
        } else try payload.object.put(a, "headers", headers);
    }
    try out.object.put(a, "payload", payload);
    return out;
}

pub fn verifiedLabels(value: j.Value, a: std.mem.Allocator) ![]const []const u8 {
    const items = j.get(value, "labelIds") orelse return error.InvalidLabels;
    if (items != .array or items.array.items.len > 64) return error.InvalidLabels;
    // Validate before allocating so malformed membership consumes no output.
    for (items.array.items) |label| {
        if (label != .string or label.string.len == 0 or label.string.len > 256) return error.InvalidLabels;
        recipients.validateHeader(label.string) catch return error.InvalidLabels;
    }
    const labels = try a.alloc([]const u8, items.array.items.len);
    for (items.array.items, labels) |label, *out| out.* = try a.dupe(u8, label.string);
    return labels;
}

fn display(comptime capacity: usize, a: std.mem.Allocator, text: []const u8, header: bool) ![]const u8 {
    var bounded: b.Text(capacity) = .{};
    const input = text[0..@min(text.len, limits.header_value_bytes)];
    if (header) b.header(capacity, &bounded, input) else bounded.display(input);
    return a.dupe(u8, bounded.slice());
}

/// This is display-only data, never an input to recipient derivation. Keep the
/// provider identity and any independently validated membership/date even when
/// the MIME envelope cannot be represented by the supported message model.
fn minimal(value: j.Value, a: std.mem.Allocator, err: anyerror) !types.Message {
    try identity(value);
    var out: types.Message = .{
        .id = try a.dupe(u8, j.text(value, "id")),
        .threadId = try a.dupe(u8, j.text(value, "threadId")),
        .subject = "Message unavailable",
        .snippet = try display(1024, a, j.text(value, "snippet"), false),
        .decodeWarning = @errorName(err),
        .metadataPartial = true,
        .labelsVerified = false,
    };
    out.labels = verifiedLabels(value, a) catch |failure| blk: {
        if (failure == error.OutOfMemory) return failure;
        break :blk &.{};
    };
    // An empty, explicitly supplied label array is still a verified result.
    out.labelsVerified = out.labels.len != 0 or if (j.get(value, "labelIds")) |labels| labels == .array and labels.array.items.len == 0 else false;
    for (out.labels) |label| out.unread = out.unread or std.mem.eql(u8, label, "UNREAD");
    const received = if (j.get(value, "internalDate")) |date| b.integer(date) catch -1 else -1;
    if (received >= 0 and received <= mime.max_received_at_ms) out.receivedAt = received;
    if (j.get(j.get(value, "payload") orelse .null, "headers")) |headers| if (headers == .array) {
        var subject = false;
        var sender = false;
        for (headers.array.items[0..@min(headers.array.items.len, limits.header_count)]) |header| {
            const name = j.text(header, "name");
            if (!subject and std.ascii.eqlIgnoreCase(name, "Subject")) {
                out.subject = try display(4096, a, j.text(header, "value"), true);
                subject = true;
            } else if (!sender and std.ascii.eqlIgnoreCase(name, "From")) {
                out.from.name = try display(limits.display_name_bytes, a, j.text(header, "value"), true);
                sender = true;
            }
        }
    };
    return out;
}

fn scratchError(err: anyerror) anyerror {
    return if (err == error.OutOfMemory) error.MessageBudgetExceeded else err;
}

/// Clone normalized data without serializing a second body-sized JSON copy.
/// Every returned string and nested array belongs to the destination allocator.
pub fn copyMessage(message: types.Message, a: std.mem.Allocator) !types.Message {
    return copyOwned(types.Message, message, a);
}
fn copyOwned(comptime T: type, value: T, a: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            var out: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| @field(out, name) = try copyOwned(FieldType, @field(value, name), a);
            break :blk out;
        },
        .pointer => |pointer| blk: {
            if (pointer.size != .slice or pointer.sentinel_ptr != null) @compileError("Message copies support ordinary owned slices only");
            if (pointer.child == u8) break :blk try a.dupe(u8, value);
            const out = try a.alloc(pointer.child, value.len);
            for (value, out) |item, *destination| destination.* = try copyOwned(pointer.child, item, a);
            break :blk out;
        },
        .array => |array| blk: {
            // Initializing by value preserves any sentinel; every element is
            // then recursively replaced with independently owned data.
            var out = value;
            for (value, &out) |item, *destination| destination.* = try copyOwned(array.child, item, a);
            break :blk out;
        },
        .optional => |optional| if (value) |item| try copyOwned(optional.child, item, a) else null,
        .void, .bool, .int, .float, .@"enum", .error_set => value,
        else => @compileError("Message copy-out requires explicit ownership for this field type: " ++ @typeName(T)),
    };
}

pub fn serializedBytes(value: anytype) usize {
    var buffer: [4096]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    std.json.Stringify.value(value, .{}, &counter.writer) catch unreachable;
    return @intCast(counter.fullCount());
}

/// A thread's aggregate allowance is separate from the per-message reader.
/// Small display fields identify omitted members. Verified labels retain
/// folder/unread meaning; shortened envelopes are never reply destinations.
pub fn threadPlaceholder(message: types.Message, a: std.mem.Allocator) !types.Message {
    return unavailablePlaceholder(message, a, "ThreadBodyBudgetExceeded");
}

pub fn retainThreadMessage(message: types.Message, a: std.mem.Allocator, remaining: *usize) !types.Message {
    const bytes = serializedBytes(message);
    if (bytes > remaining.*) return threadPlaceholder(message, a);
    remaining.* -= bytes;
    return copyMessage(message, a);
}

pub fn retainMetadataMessage(message: types.Message, a: std.mem.Allocator, remaining: *usize) !types.Message {
    const bytes = serializedBytes(message);
    if (bytes <= remaining.*) {
        remaining.* -= bytes;
        return copyMessage(message, a);
    }
    var placeholder = try unavailablePlaceholder(message, a, "MetadataBudgetExceeded");
    // A batch allowance is not a refusal of the individual message body.
    placeholder.bodyCacheError = "";
    return placeholder;
}

pub fn unavailablePlaceholder(message: types.Message, a: std.mem.Allocator, code: []const u8) !types.Message {
    // Separate from the complete-DTO allowance: at most 100 placeholders keep
    // 64 labels of 256 bytes each (1.6 MiB text plus bounded slice overhead).
    // These typed labels came from the decoder; reject invalid future callers
    // before copying, and never promote previously unverified membership.
    if (message.labels.len > 64) return error.InvalidLabels;
    for (message.labels) |label| if (label.len == 0 or label.len > 256) return error.InvalidLabels;
    return .{
        .id = try a.dupe(u8, message.id),
        .threadId = try a.dupe(u8, message.threadId),
        .from = .{ .address = "", .name = try display(256, a, message.from.name, false) },
        .subject = try display(1024, a, message.subject, false),
        .snippet = try display(512, a, message.snippet, false),
        .receivedAt = message.receivedAt,
        .labels = try copyOwned([]const []const u8, message.labels, a),
        .unread = message.unread,
        .bodyCacheError = code,
        .decodeWarning = code,
        .metadataPartial = true,
        .labelsVerified = message.labelsVerified,
    };
}

fn refusedScratch(value: j.Value, lease: *scratch.Lease, failure: anyerror, body: bool) !types.Message {
    const err = scratchError(failure);
    if (!messageRefusal(err)) return err;
    try identity(value);
    lease.reset();
    const a = lease.allocator();
    // Preserve independently valid envelope data after a body-only refusal.
    const source = projection(value, a, true, false) catch |projection_error| blk: {
        if (!messageRefusal(scratchError(projection_error))) return projection_error;
        lease.reset();
        break :blk .null;
    };
    var out = if (source != .null) mime.normalizeGmail(source, a, null) catch |decode_error| blk: {
        if (!messageRefusal(scratchError(decode_error))) return decode_error;
        lease.reset();
        break :blk try minimal(value, a, err);
    } else try minimal(value, a, err);
    out.decodeWarning = @errorName(err);
    out.metadataPartial = true;
    if (body) out.bodyCacheError = @errorName(err);
    if (j.get(value, "labelIds") == null) out.labelsVerified = false;
    return out;
}

pub fn refused(value: j.Value, a: std.mem.Allocator, err: anyerror, body: bool) !types.Message {
    // OOM from a provider/caller remains fatal. Only allocations made inside
    // this independently fixed decoder workspace may become a local refusal.
    if (!messageRefusal(err)) return err;
    var lease = scratch.acquire();
    defer lease.release();
    return copyMessage(try refusedScratch(value, &lease, err, body), a);
}

fn normalizeScratch(value: j.Value, lease: *scratch.Lease, externalBodies: ?j.Value, body: bool) !types.Message {
    const allocator = lease.allocator();
    var message = mime.normalizeGmail(value, allocator, externalBodies) catch |failure| {
        const err = scratchError(failure);
        if (!messageRefusal(err)) return err;
        lease.reset();
        // Retry supported MIME once without destination/threading headers.
        // Neither failed attempt may consume the next message's scratch.
        if (envelopeRefusal(err)) {
            const safe = projection(value, allocator, false, true) catch |projection_error| return refusedScratch(value, lease, scratchError(projection_error), body);
            var recovered = mime.normalizeGmail(safe, allocator, externalBodies) catch |decode_error| return refusedScratch(value, lease, scratchError(decode_error), body);
            const header = minimal(value, allocator, err) catch |header_error| return refusedScratch(value, lease, scratchError(header_error), body);
            recovered.from = header.from;
            recovered.decodeWarning = @errorName(err);
            recovered.metadataPartial = true;
            recovered.labelsVerified = header.labelsVerified;
            return recovered;
        }
        return refusedScratch(value, lease, err, body);
    };
    if (j.get(value, "labelIds") == null) {
        message.labelsVerified = false;
        message.metadataPartial = true;
        message.decodeWarning = "InvalidLabels";
    }
    return message;
}
fn normalizeMode(value: j.Value, allocator: std.mem.Allocator, externalBodies: ?j.Value, body: bool, remaining: ?*usize) !types.Message {
    try identity(value);
    var lease = scratch.acquire();
    defer lease.release();
    const message = try normalizeScratch(value, &lease, externalBodies, body);
    if (remaining) |budget| return retainMetadataMessage(message, allocator, budget);
    // Destination-copy OOM is a global application failure, never downgraded.
    return copyMessage(message, allocator);
}

/// The account-scoped provider supplies external Gmail attachment responses.
/// Every slice in the normalized message belongs to the caller's allocator.
pub fn normalize(value: std.json.Value, allocator: std.mem.Allocator, externalBodies: ?std.json.Value) !types.Message {
    return normalizeMode(value, allocator, externalBodies, true, null);
}

pub fn normalizeMetadata(value: j.Value, allocator: std.mem.Allocator) !types.Message {
    return normalizeMode(value, allocator, null, false, null);
}

pub fn normalizeMetadataBudgeted(value: j.Value, allocator: std.mem.Allocator, remaining: *usize) !types.Message {
    return normalizeMode(value, allocator, null, false, remaining);
}

test "message isolation: scratch exhaustion is local and owned DTOs survive reset while destination OOM stays fatal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try j.value(a, .{ .id = "scratch-message", .threadId = "scratch-thread", .internalDate = "42", .labelIds = [_][]const u8{"INBOX"}, .payload = .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "sender@example.test" }, .{ .name = "Subject", .value = "Retained subject" } }, .body = .{ .size = @as(usize, 4), .data = "Qm9keQ" } } });
    var lease = scratch.acquire();
    errdefer if (lease.live) lease.release();
    _ = try lease.allocator().alloc(u8, scratch.reservation_bytes);
    const partial = try copyMessage(try normalizeScratch(value, &lease, null, true), a);
    try std.testing.expectEqualStrings("MessageBudgetExceeded", partial.bodyCacheError);
    lease.release();
    const recovered = try normalize(value, a, null);
    try std.testing.expectEqualStrings("Body", recovered.bodyText);
    try std.testing.expectEqualStrings("Retained subject", partial.subject);
    try std.testing.expectEqualStrings("sender@example.test", partial.from.address);
    var no_space: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_space);
    try std.testing.expectError(error.OutOfMemory, normalize(value, failing.allocator(), null));
    try std.testing.expect(!scratch.snapshot().active);
    try std.testing.expectEqual(@as(usize, 0), scratch.snapshot().usedBytes);
}

test "message isolation: copied arrays and optional nested slices own every byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Shape = struct { chunks: [2][]const u8, nested: ?[1][]const u8, flag: bool, count: u16, mode: enum { first, second } };
    var first = "first".*;
    var second = "second".*;
    const source: Shape = .{ .chunks = .{ &first, &second }, .nested = .{&first}, .flag = true, .count = 42, .mode = .second };
    const owned = try copyOwned(Shape, source, arena.allocator());
    @memset(&first, 'x');
    @memset(&second, 'y');
    try std.testing.expectEqualStrings("first", owned.chunks[0]);
    try std.testing.expectEqualStrings("second", owned.chunks[1]);
    try std.testing.expectEqualStrings("first", owned.nested.?[0]);
    try std.testing.expect(owned.flag);
    try std.testing.expectEqual(@as(u16, 42), owned.count);
    try std.testing.expect(owned.mode == .second);
}

test "message isolation: quota placeholders retain bounded independently verified folder and unread labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: types.Message = .{ .id = "new-unread", .threadId = "thread", .from = .{ .address = "sender@example.test" }, .labels = &.{ "INBOX", "UNREAD", "Label_project" }, .unread = true, .bodyText = "Body" };
    var remaining: usize = 0;
    for ([_]types.Message{ try retainMetadataMessage(source, a, &remaining), try threadPlaceholder(source, a) }) |placeholder| {
        try std.testing.expect(placeholder.metadataPartial and placeholder.labelsVerified and placeholder.unread);
        try std.testing.expectEqual(@as(usize, 3), placeholder.labels.len);
        try std.testing.expectEqualStrings("INBOX", placeholder.labels[0]);
        try std.testing.expectEqualStrings("UNREAD", placeholder.labels[1]);
        try std.testing.expectEqualStrings("Label_project", placeholder.labels[2]);
        try std.testing.expectEqualStrings("", placeholder.from.address);
    }
    var unknown = source;
    unknown.labelsVerified = false;
    try std.testing.expect(!(try unavailablePlaceholder(unknown, a, "MetadataBudgetExceeded")).labelsVerified);
}
