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

const DecodeMode = enum { bounded, compose };

fn scratchError(comptime mode: DecodeMode, err: anyerror) anyerror {
    return if (mode == .bounded and err == error.OutOfMemory) error.MessageBudgetExceeded else err;
}

fn decodeMime(comptime mode: DecodeMode, value: j.Value, a: std.mem.Allocator, external_bodies: ?j.Value) !types.Message {
    return if (mode == .compose) mime.normalizeGmailForCompose(value, a, external_bodies) else mime.normalizeGmail(value, a, external_bodies);
}

/// A compose-source decode is synchronous, just like the fixed workspace.
/// Reset releases and wipes failed attempts before envelope-only recovery.
/// Neither this arena nor a borrowed MIME result escapes the decode call.
const ComposeScratch = struct {
    arena: std.heap.ArenaAllocator,

    fn allocator(self: *ComposeScratch) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn reset(self: *ComposeScratch) void {
        _ = self.arena.reset(.free_all);
    }
};

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

fn refusedScratch(comptime mode: DecodeMode, value: j.Value, lease: anytype, failure: anyerror, body: bool) !types.Message {
    const err = scratchError(mode, failure);
    if (!messageRefusal(err)) return err;
    try identity(value);
    lease.reset();
    const a = lease.allocator();
    // Preserve independently valid envelope data after a body-only refusal.
    const source = projection(value, a, true, false) catch |projection_error| blk: {
        if (!messageRefusal(scratchError(mode, projection_error))) return projection_error;
        lease.reset();
        break :blk .null;
    };
    var out = if (source != .null) decodeMime(mode, source, a, null) catch |decode_error| blk: {
        if (!messageRefusal(scratchError(mode, decode_error))) return decode_error;
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
    return copyMessage(try refusedScratch(.bounded, value, &lease, err, body), a);
}

fn normalizeScratch(comptime mode: DecodeMode, value: j.Value, lease: anytype, externalBodies: ?j.Value, body: bool) !types.Message {
    const allocator = lease.allocator();
    var message = decodeMime(mode, value, allocator, externalBodies) catch |failure| {
        const err = scratchError(mode, failure);
        if (!messageRefusal(err)) return err;
        lease.reset();
        // Retry supported MIME once without destination/threading headers.
        // Neither failed attempt may consume the next message's scratch.
        if (envelopeRefusal(err)) {
            const safe = projection(value, allocator, false, true) catch |projection_error| return refusedScratch(mode, value, lease, projection_error, body);
            var recovered = decodeMime(mode, safe, allocator, externalBodies) catch |decode_error| return refusedScratch(mode, value, lease, decode_error, body);
            const header = minimal(value, allocator, err) catch |header_error| return refusedScratch(mode, value, lease, header_error, body);
            recovered.from = header.from;
            recovered.decodeWarning = @errorName(err);
            recovered.metadataPartial = true;
            recovered.labelsVerified = header.labelsVerified;
            return recovered;
        }
        return refusedScratch(mode, value, lease, err, body);
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
    const message = try normalizeScratch(.bounded, value, &lease, externalBodies, body);
    if (remaining) |budget| return retainMetadataMessage(message, allocator, budget);
    // Destination-copy OOM is a global application failure, never downgraded.
    return copyMessage(message, allocator);
}

/// The account-scoped provider supplies external Gmail attachment responses.
/// Every slice in the normalized message belongs to the caller's allocator.
pub fn normalize(value: std.json.Value, allocator: std.mem.Allocator, externalBodies: ?std.json.Value) !types.Message {
    return normalizeMode(value, allocator, externalBodies, true, null);
}

/// Explicit native reply/forward source capture can decode a long original
/// without the ordinary reader's fixed 16 MiB scratch ceiling. MIME byte/part
/// limits still apply; the result owns every byte in the caller's allocator.
/// Ordinary reads, metadata and browser callers retain their fixed workspace.
pub fn normalizeForCompose(value: j.Value, allocator: std.mem.Allocator, externalBodies: ?j.Value) !types.Message {
    const transient = @import("send_memory.zig");
    if (!transient.native) return normalize(value, allocator, externalBodies);
    try identity(value);
    var workspace: ComposeScratch = .{ .arena = .init(transient.allocator()) };
    defer workspace.arena.deinit();
    const message = try normalizeScratch(.compose, value, &workspace, externalBodies, true);
    // OS allocation failures and destination-copy OOM remain fatal. Only the
    // separate fixed workspace may convert OOM into MessageBudgetExceeded.
    return copyMessage(message, allocator);
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
    const partial = try copyMessage(try normalizeScratch(.bounded, value, &lease, null, true), a);
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

test "native compose source: large alternatives own their bytes without borrowing fixed scratch" {
    const transient = @import("send_memory.zig");
    if (!transient.native) return error.SkipZigTest;
    var output: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer output.deinit();
    const a = output.allocator();
    var message: types.Message = undefined;
    var expected_plain: [32]u8 = undefined;
    var expected_html: [32]u8 = undefined;
    const plain_size = 3 * 1024 * 1024 + 17;
    const html_size = 4 * 1024 * 1024 + 37;
    const baseline = transient.snapshot().allocatorUsedBytes;
    {
        var source: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer source.deinit();
        const input = source.allocator();
        const plain = try input.alloc(u8, plain_size);
        @memset(plain, 'p');
        @memcpy(plain[0..21], "Original plain start\n");
        @memcpy(plain[plain.len - 18 ..], "Original plain end");
        std.crypto.hash.sha2.Sha256.hash(plain, &expected_plain, .{});
        const html = try input.alloc(u8, html_size);
        @memset(html, 'h');
        const prefix = "<html><body><p>Original HTML start</p><p>";
        const suffix = "</p><img src=\"cid:screenshot@example.test\"><p>Original HTML end</p></body></html>";
        @memcpy(html[0..prefix.len], prefix);
        @memcpy(html[html.len - suffix.len ..], suffix);
        std.crypto.hash.sha2.Sha256.hash(html, &expected_html, .{});
        const plain_encoded = try input.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(plain.len));
        const html_encoded = try input.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(html.len));
        const parts = [_]j.Value{
            try j.value(input, .{ .mimeType = "text/plain", .body = .{ .size = plain.len, .data = std.base64.url_safe_no_pad.Encoder.encode(plain_encoded, plain) } }),
            try j.value(input, .{ .mimeType = "text/html", .body = .{ .size = html.len, .attachmentId = "external-html" } }),
            try j.value(input, .{ .mimeType = "image/png", .filename = "screenshot.png", .headers = .{ .{ .name = "Content-ID", .value = "<screenshot@example.test>" }, .{ .name = "Content-Disposition", .value = "inline" } }, .body = .{ .size = 102400, .attachmentId = "external-image" } }),
        };
        const value = try j.value(input, .{ .id = "large-source", .threadId = "large-thread", .internalDate = "42", .labelIds = [_][]const u8{ "INBOX", "UNREAD" }, .payload = .{ .mimeType = "multipart/alternative", .headers = .{ .{ .name = "From", .value = "sender@example.test" }, .{ .name = "Subject", .value = "Long illustrated source" }, .{ .name = "Message-ID", .value = "<source@example.test>" } }, .parts = &parts } });
        const external = try j.value(input, .{ .@"external-html" = .{ .data = std.base64.url_safe_no_pad.Encoder.encode(html_encoded, html) } });

        // Preserve the ordinary reader's refusal, including its metadata.
        const ordinary = try normalize(value, a, external);
        try std.testing.expectEqualStrings("BodyTooLarge", ordinary.bodyCacheError);
        try std.testing.expectEqualStrings("sender@example.test", ordinary.from.address);
        const leases = scratch.snapshot().leases;
        message = try normalizeForCompose(value, a, external);
        try std.testing.expectEqual(leases, scratch.snapshot().leases);
        try std.testing.expectEqual(baseline, transient.snapshot().allocatorUsedBytes);
        try std.testing.expectEqualStrings(plain, message.bodyText);
        try std.testing.expectEqualStrings(html, message.bodyHtml.?);

        var no_space: [0]u8 = .{};
        var failing: std.heap.FixedBufferAllocator = .init(&no_space);
        try std.testing.expectError(error.OutOfMemory, normalizeForCompose(value, failing.allocator(), external));
        try std.testing.expectEqual(baseline, transient.snapshot().allocatorUsedBytes);
    }
    // Both input and temporary decode storage are gone. Retained identity,
    // text and remote image descriptors must still be independently owned.
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message.bodyText, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected_plain, &actual);
    std.crypto.hash.sha2.Sha256.hash(message.bodyHtml.?, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected_html, &actual);
    try std.testing.expectEqualStrings("", message.bodyCacheError);
    try std.testing.expectEqualStrings("<source@example.test>", message.messageId);
    try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
    try std.testing.expectEqualStrings("external-image", message.attachments[0].id);
    try std.testing.expectEqualStrings("screenshot@example.test", message.attachments[0].contentId.?);
    try std.testing.expectEqual(@as(usize, 102400), message.attachments[0].size);
    try std.testing.expect(message.unread and message.labelsVerified);
    try std.testing.expect(!scratch.snapshot().active);
}

test "native compose source: malformed input recovers metadata but allocation failures stay fatal" {
    const transient = @import("send_memory.zig");
    if (!transient.native) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try j.value(a, .{ .id = "compose-source", .threadId = "compose-thread", .internalDate = "42", .labelIds = [_][]const u8{"INBOX"}, .payload = .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "sender@example.test" }, .{ .name = "Subject", .value = "Source subject" } }, .body = .{ .size = 4, .data = "Qm9keQ" } } });
    const baseline = transient.snapshot().allocatorUsedBytes;
    var no_space: [0]u8 = .{};
    var failing: std.heap.FixedBufferAllocator = .init(&no_space);
    var workspace: ComposeScratch = .{ .arena = .init(failing.allocator()) };
    defer workspace.arena.deinit();
    try std.testing.expectError(error.OutOfMemory, normalizeScratch(.compose, value, &workspace, null, true));

    var invalid = try j.copyObject(a, value);
    var payload = try j.copyObject(a, j.get(value, "payload").?);
    try payload.object.put(a, "body", try j.value(a, .{ .size = types.Limits.compose_body_bytes + 1, .data = "" }));
    try invalid.object.put(a, "payload", payload);
    const refused_message = try normalizeForCompose(invalid, a, null);
    try std.testing.expectEqualStrings("BodyTooLarge", refused_message.bodyCacheError);
    try std.testing.expectEqualStrings("Source subject", refused_message.subject);
    try std.testing.expectEqualStrings("sender@example.test", refused_message.from.address);
    try std.testing.expectEqual(baseline, transient.snapshot().allocatorUsedBytes);

    // A failed envelope may be retried after the first arena is wiped. The
    // caller's original tree must survive that reset unchanged.
    try payload.object.put(a, "body", j.get(j.get(value, "payload").?, "body").?);
    try payload.object.put(a, "headers", try j.value(a, .{.{ .name = "From", .value = "first@example.test, second@example.test" }}));
    try invalid.object.put(a, "payload", payload);
    const ambiguous = try normalizeForCompose(invalid, a, null);
    try std.testing.expectEqualStrings("Body", ambiguous.bodyText);
    try std.testing.expectEqualStrings("AmbiguousSender", ambiguous.decodeWarning);
    try std.testing.expect(ambiguous.metadataPartial);
    try std.testing.expectEqualStrings("", ambiguous.from.address);
    try std.testing.expectEqualStrings("Body", (try normalizeForCompose(value, a, null)).bodyText);
    try std.testing.expectEqual(baseline, transient.snapshot().allocatorUsedBytes);
}
