const std = @import("std");
const b = @import("../bounded.zig");
const recipients = @import("recipients.zig");
const types = @import("types.zig");
const markdown_logo = @import("markdown_logo.zig");
const byte_stream = @import("../byte_stream.zig");
pub const Source = byte_stream.Source;

pub const max_raw_bytes = types.Limits.request_bytes;
pub const max_body_bytes = types.Limits.body_bytes;
const utf8_bom = "\xef\xbb\xbf";
pub const max_headers_bytes = 32 * 1024;
pub const max_headers = 256;
pub const max_parts = 128;
pub const max_depth = 16;
pub const max_attachments = types.Limits.attachments + types.Limits.related_resources + 1;
/// Calendar discovery uses the same bound as the invitation parser. Other
/// attachment types remain governed by the ordinary attachment/body limits.
pub const max_calendar_bytes = 128 * 1024;
/// Last millisecond of year 9999, within the terminal timestamp formatter's range.
pub const max_received_at_ms: i64 = 253402300799999;
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Attachment = struct { id: []const u8 = "", filename: []const u8, mime_type: []const u8, content_id: []const u8 = "", disposition: []const u8 = "", content_location: []const u8 = "", size: usize = 0, data: []const u8 = "", source: ?Source = null };
pub const ParsedMessage = struct {
    headers: []const Header = &.{},
    from: []const recipients.IncomingMailbox = &.{},
    to: []const recipients.IncomingMailbox = &.{},
    cc: []const recipients.IncomingMailbox = &.{},
    bcc: []const recipients.IncomingMailbox = &.{},
    reply_to: []const recipients.IncomingMailbox = &.{},
    subject: []const u8 = "",
    date: []const u8 = "",
    message_id: []const u8 = "",
    in_reply_to: []const u8 = "",
    references: []const u8 = "",
    body_text: []const u8 = "",
    body_html: []const u8 = "",
    html_documents: usize = 0,
    body_source: types.BodySource = .unknown,
    calendar: ?[]const u8 = null,
    /// Valid calendar parts disagree. No invitation is offered, but the body
    /// and every attachment remain readable.
    calendar_ambiguous: bool = false,
    attachments: []const Attachment = &.{},
};

/// All result/scratch allocations belong to the caller. Use a job arena or
/// fixed allocator and reset it only once every result borrow is finished.
pub fn parse(raw: []const u8, allocator: std.mem.Allocator) !ParsedMessage {
    if (raw.len > max_raw_bytes) return error.MessageTooLarge;
    const entity = try splitEntity(raw, allocator);
    var result = try envelope(entity.headers, allocator);
    var context: Context = .{ .allocator = allocator };
    try context.rawPart(entity, 0);
    try context.finish(&result);
    return result;
}

/// Gmail FULL payload data has already been MIME-transfer decoded by Gmail;
/// decode only the API's base64url envelope before charset conversion.
pub fn parseGmail(message: std.json.Value, allocator: std.mem.Allocator) !ParsedMessage {
    return try parseGmailExternal(message, allocator, null);
}
fn parseGmailExternal(message: std.json.Value, allocator: std.mem.Allocator, external_bodies: ?std.json.Value) !ParsedMessage {
    const payload = try b.field(message, "payload");
    const headers = try gmailHeaders(payload, allocator);
    var result = try envelope(headers, allocator);
    var context: Context = .{ .allocator = allocator, .external_bodies = external_bodies };
    try context.gmailPart(payload, 0);
    try context.finish(&result);
    return result;
}

pub fn normalizeGmail(value: std.json.Value, allocator: std.mem.Allocator, externalBodies: ?std.json.Value) !types.Message {
    const received = try b.integer(try b.field(value, "internalDate"));
    if (received < 0 or received > max_received_at_ms) return error.InvalidDate;
    const parsed = try parseGmailExternal(value, allocator, externalBodies);
    const id = try b.string(try b.field(value, "id"));
    const thread = try b.string(try b.field(value, "threadId"));
    try b.identifier(id);
    try b.identifier(thread);
    const label_items = if (b.optional(value, "labelIds")) |labels_value| if (labels_value == .array) labels_value.array.items else return error.InvalidLabels else &.{};
    if (label_items.len > 64) return error.InvalidLabels;
    const labels = try allocator.alloc([]const u8, label_items.len);
    var unread = false;
    for (label_items, labels) |label, *dest| {
        const text = try b.string(label);
        if (text.len > 256) return error.InvalidLabels;
        try recipients.validateHeader(text);
        dest.* = try allocator.dupe(u8, text);
        unread = unread or std.mem.eql(u8, text, "UNREAD");
    }
    if (parsed.from.len > 1) return error.AmbiguousSender;
    const attachments = try allocator.alloc(types.Attachment, parsed.attachments.len);
    for (parsed.attachments, attachments, 0..) |item, *dest, i| {
        const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(item.data.len));
        dest.* = .{
            .id = if (item.id.len != 0) item.id else try std.fmt.allocPrint(allocator, "part-{d}", .{i + 1}),
            .filename = try safeFilename(item.filename, allocator),
            .mimeType = item.mime_type,
            .size = item.size,
            .data = std.base64.url_safe_no_pad.Encoder.encode(encoded, item.data),
            // Ordinary reading need not refuse a message for a malformed CID
            // it previously ignored. Formatted capture validates this field.
            .contentId = if (item.content_id.len == 0) null else contentId(item.content_id) catch item.content_id,
            .disposition = if (item.disposition.len == 0) null else item.disposition,
            .contentLocation = if (item.content_location.len == 0) null else item.content_location,
        };
    }
    return .{
        .id = try allocator.dupe(u8, id),
        .threadId = try allocator.dupe(u8, thread),
        .from = if (parsed.from.len == 1) .{ .address = try allocator.dupe(u8, parsed.from[0].address), .name = try allocator.dupe(u8, parsed.from[0].name) } else .{ .address = "" },
        .replyTo = try dtoAddresses(parsed.reply_to, allocator),
        .to = try dtoAddresses(parsed.to, allocator),
        .cc = try dtoAddresses(parsed.cc, allocator),
        .subject = parsed.subject,
        .snippet = try sanitizeText(if (b.optional(value, "snippet")) |v| try b.string(v) else "", allocator),
        .bodyText = parsed.body_text,
        .bodyHtml = if (parsed.body_html.len == 0) null else parsed.body_html,
        .bodyHtmlAmbiguous = parsed.html_documents > 1,
        .bodySource = parsed.body_source,
        .messageId = parsed.message_id,
        .references = parsed.references,
        .inReplyTo = parsed.in_reply_to,
        .labels = labels,
        .receivedAt = received,
        .sentDate = if (parsed.date.len == 0) null else parsed.date,
        .unread = unread,
        .attachments = attachments,
        .invitation = parsed.calendar,
    };
}
fn safeFilename(filename: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var offset: usize = 0;
    for (filename, 0..) |c, i| if (c == '/' or c == '\\') {
        offset = i + 1;
    };
    const base = std.mem.trim(u8, filename[offset..], " .\t\r\n");
    if (base.len > 512) return error.FilenameTooLarge;
    return try sanitizeText(if (base.len == 0) "attachment" else base, allocator);
}
fn dtoAddresses(source: []const recipients.IncomingMailbox, allocator: std.mem.Allocator) ![]const types.Address {
    const out = try allocator.alloc(types.Address, source.len);
    for (source, out) |*item, *dest| dest.* = .{ .address = try allocator.dupe(u8, item.address), .name = try allocator.dupe(u8, item.name) };
    return out;
}

const Entity = struct { headers: []const Header, body: []const u8 };
fn splitEntity(raw: []const u8, allocator: std.mem.Allocator) !Entity {
    const crlf = std.mem.indexOf(u8, raw, "\r\n\r\n");
    const lf = std.mem.indexOf(u8, raw, "\n\n");
    const split = if (crlf) |p| if (lf) |q| @min(p, q) else p else lf orelse return error.MissingHeaderBoundary;
    const separator: usize = if (crlf != null and split == crlf.?) 4 else 2;
    if (split > max_headers_bytes) return error.HeadersTooLarge;
    var list: std.ArrayList(Header) = .empty;
    var lines = std.mem.splitScalar(u8, raw[0..split], '\n');
    while (lines.next()) |physical| {
        const line = std.mem.trimEnd(u8, physical, "\r");
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\r') != null) return error.InvalidHeaders;
        if (line[0] == ' ' or line[0] == '\t') {
            if (list.items.len == 0) return error.InvalidHeaders;
            const previous = &list.items[list.items.len - 1];
            const continuation = std.mem.trim(u8, line, " \t");
            if (previous.value.len + continuation.len + 1 > 8192) return error.HeaderTooLarge;
            previous.value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ previous.value, continuation });
            continue;
        }
        if (list.items.len == max_headers) return error.TooManyHeaders;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaders;
        if (colon == 0) return error.InvalidHeaders;
        for (line[0..colon]) |c| if (c < 33 or c > 126 or c == ':') return error.InvalidHeaders;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len > 8192) return error.HeaderTooLarge;
        for (value) |c| if ((c < 32 and c != '\t') or c == 127) return error.InvalidHeaders;
        try list.append(allocator, .{ .name = try allocator.dupe(u8, line[0..colon]), .value = try allocator.dupe(u8, value) });
    }
    return .{ .headers = try list.toOwnedSlice(allocator), .body = raw[split + separator ..] };
}

pub const OriginalSource = struct { subject: []const u8, attachment: types.Attachment };
/// Only inspect headers: arbitrary MIME bodies need not be understood by the
/// terminal reader before the original can be enclosed without alteration.
pub fn originalSource(a: std.mem.Allocator, raw: []const u8) !OriginalSource {
    if (raw.len > max_body_bytes) return error.BodyTooLarge;
    const entity = try splitEntity(raw, a);
    if ((try header(entity.headers, "Subject")).len == 0 and (try header(entity.headers, "From")).len == 0 and (try header(entity.headers, "Date")).len == 0) return error.InvalidHeaders;
    // The reader, replies and this forward share one bounded display fallback.
    const decoded = try displayHeader(try header(entity.headers, "Subject"), a);
    const subject = if (decoded.len == 0 or decoded.len > 4000) "Original message" else decoded;
    var ascii = true;
    for (raw) |c| ascii = ascii and c < 128;
    const headers_utf8 = std.unicode.utf8ValidateSlice(raw[0 .. raw.len - entity.body.len]);
    const mime_type: []const u8 = if (!identityEncodingSafe(raw) or !headers_utf8) "application/octet-stream" else if (ascii) "message/rfc822" else "message/global";
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
    return .{ .subject = subject, .attachment = .{ .id = "", .filename = "original.eml", .mimeType = mime_type, .size = raw.len, .data = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw) } };
}
fn identityEncodingSafe(raw: []const u8) bool {
    var line: usize = 0;
    for (raw, 0..) |c, index| {
        if (c == 0) return false;
        if (c == '\r') {
            if (index + 1 >= raw.len or raw[index + 1] != '\n') return false;
        } else if (c == '\n') {
            if (index == 0 or raw[index - 1] != '\r') return false;
            line = 0;
        } else {
            line += 1;
            if (line > 998) return false;
        }
    }
    return true;
}

fn gmailHeaders(payload: std.json.Value, allocator: std.mem.Allocator) ![]const Header {
    const field = b.optional(payload, "headers") orelse return &.{};
    if (field != .array or field.array.items.len > max_headers) return error.TooManyHeaders;
    const out = try allocator.alloc(Header, field.array.items.len);
    var bytes: usize = 0;
    for (field.array.items, out) |entry, *dest| {
        const name = try b.string(try b.field(entry, "name"));
        const value = try b.string(try b.field(entry, "value"));
        bytes += name.len + value.len;
        if (bytes > max_headers_bytes or name.len == 0 or value.len > 8192) return error.HeadersTooLarge;
        for (name) |c| if (c < 33 or c > 126 or c == ':') return error.InvalidHeaders;
        dest.* = .{ .name = try allocator.dupe(u8, name), .value = try unfoldHeader(value, allocator) };
    }
    return out;
}
fn unfoldHeader(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    const out = try allocator.alloc(u8, value.len);
    var used: usize = 0;
    var pos: usize = 0;
    while (pos < value.len) : (pos += 1) {
        const c = value[pos];
        if (c == '\r' or c == '\n') {
            if (c == '\r') {
                if (pos + 1 >= value.len or value[pos + 1] != '\n') return error.InvalidHeaders;
                pos += 1;
            }
            if (pos + 1 >= value.len or (value[pos + 1] != ' ' and value[pos + 1] != '\t')) return error.InvalidHeaders;
            while (pos + 1 < value.len and (value[pos + 1] == ' ' or value[pos + 1] == '\t')) pos += 1;
            out[used] = ' ';
        } else {
            if ((c < 32 and c != '\t') or c == 127) return error.InvalidHeaders;
            out[used] = if (c == '\t') ' ' else c;
        }
        used += 1;
    }
    return std.mem.trim(u8, out[0..used], " ");
}

pub fn header(headers: []const Header, name: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
        if (found != null) return error.AmbiguousHeader;
        found = h.value;
    };
    return found orelse "";
}

fn addressList(raw: []const u8, allocator: std.mem.Allocator) ![]const recipients.IncomingMailbox {
    const list = try recipients.parseIncoming(raw, allocator);
    errdefer recipients.deinitIncoming(list, allocator);
    for (list) |*mailbox| {
        const decoded = try displayHeader(mailbox.name, allocator);
        errdefer allocator.free(decoded);
        if (decoded.len > 256) return error.CapacityExceeded;
        allocator.free(mailbox.name);
        mailbox.name = decoded;
    }
    return list;
}
fn envelope(headers: []const Header, allocator: std.mem.Allocator) !ParsedMessage {
    return .{
        .headers = headers,
        .from = try addressList(try header(headers, "From"), allocator),
        .to = try addressList(try header(headers, "To"), allocator),
        .cc = try addressList(try header(headers, "Cc"), allocator),
        .bcc = try addressList(try header(headers, "Bcc"), allocator),
        .reply_to = try addressList(try header(headers, "Reply-To"), allocator),
        .subject = try displayHeader(try header(headers, "Subject"), allocator),
        .date = try allocator.dupe(u8, try header(headers, "Date")),
        .message_id = try allocator.dupe(u8, try header(headers, "Message-ID")),
        .in_reply_to = try allocator.dupe(u8, try header(headers, "In-Reply-To")),
        .references = try allocator.dupe(u8, try header(headers, "References")),
    };
}

fn isAttached(headers: []const Header, filename: []const u8) !bool {
    const disposition = try header(headers, "Content-Disposition");
    return filename.len > 0 or std.ascii.startsWithIgnoreCase(disposition, "attachment");
}
/// Shared DTO IDs omit RFC angle brackets. Refuse values that cannot safely be
/// emitted as Content-ID or matched against a literal cid: reference.
pub fn contentId(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const id = if (trimmed.len >= 2 and trimmed[0] == '<' and trimmed[trimmed.len - 1] == '>') trimmed[1 .. trimmed.len - 1] else trimmed;
    if (id.len == 0 or id.len > 512) return error.InvalidContentId;
    for (id) |c| if (c <= 32 or c >= 127 or c == '<' or c == '>' or c == '"' or c == '\\') return error.InvalidContentId;
    return id;
}
fn dispositionToken(headers: []const Header) ![]const u8 {
    const value = try header(headers, "Content-Disposition");
    const token = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
    return if (std.ascii.eqlIgnoreCase(token, "inline")) "inline" else if (std.ascii.eqlIgnoreCase(token, "attachment")) "attachment" else "";
}

/// Some Outlook exports carry the calendar as a named binary .ics attachment.
/// Only explicit calendar MIME types or .ics octet-stream files qualify; a
/// conference URL or arbitrary body text never creates an invitation.
pub fn isCalendarPart(mime_type: []const u8, filename: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mime_type, "text/calendar") or
        std.ascii.eqlIgnoreCase(mime_type, "application/ics") or
        (std.ascii.eqlIgnoreCase(mime_type, "application/octet-stream") and
            filename.len >= 4 and std.ascii.eqlIgnoreCase(filename[filename.len - 4 ..], ".ics"));
}
fn calendarEnvelope(data: []const u8) bool {
    const value = std.mem.trim(u8, data, "\r\n");
    const begin = "BEGIN:VCALENDAR";
    const end = "END:VCALENDAR";
    return value.len > begin.len + end.len and
        std.ascii.eqlIgnoreCase(value[0..begin.len], begin) and
        (value[begin.len] == '\r' or value[begin.len] == '\n') and
        std.ascii.eqlIgnoreCase(value[value.len - end.len ..], end) and
        value[value.len - end.len - 1] == '\n';
}
fn calendarText(data: []const u8, charset: []const u8, a: std.mem.Allocator) ![]const u8 {
    // Calendar folds can split a multibyte character. Remove the one folding
    // whitespace byte before charset validation, preserving every logical
    // content-line byte (including any further whitespace).
    var unfolded: ?[]u8 = null;
    var used: usize = 0;
    var pos: usize = 0;
    while (pos < data.len) {
        const newline: usize = if (data[pos] == '\r' and pos + 1 < data.len and data[pos + 1] == '\n') 2 else if (data[pos] == '\n') 1 else 0;
        if (newline != 0 and pos + newline < data.len and (data[pos + newline] == ' ' or data[pos + newline] == '\t')) {
            if (unfolded == null) {
                unfolded = try a.alloc(u8, data.len);
                @memcpy(unfolded.?[0..pos], data[0..pos]);
                used = pos;
            }
            pos += newline + 1;
            continue;
        }
        if (unfolded) |output| {
            output[used] = data[pos];
            used += 1;
        }
        pos += 1;
    }
    return try convertCharset(if (unfolded) |output| output[0..used] else data, charset, a);
}
/// Accept repeated representations only when their literal calendar lines
/// match. Do not use UID alone: differing sequence, attendees or recurrence
/// could authorize a reply to a different request.
fn sameCalendar(left: []const u8, right: []const u8) bool {
    const first = std.mem.trimEnd(u8, left, "\r\n");
    const second = std.mem.trimEnd(u8, right, "\r\n");
    var i: usize = 0;
    var j: usize = 0;
    while (i < first.len and j < second.len) {
        if (first[i] == '\r' and i + 1 < first.len and first[i + 1] == '\n') i += 1;
        if (second[j] == '\r' and j + 1 < second.len and second[j + 1] == '\n') j += 1;
        if (first[i] != second[j]) return false;
        i += 1;
        j += 1;
    }
    return i == first.len and j == second.len;
}

const Context = struct {
    allocator: std.mem.Allocator,
    parts: usize = 0,
    decoded: usize = 0,
    plain: std.ArrayList(u8) = .empty,
    html: std.ArrayList(u8) = .empty,
    html_documents: usize = 0,
    calendar: ?[]const u8 = null,
    calendar_ambiguous: bool = false,
    attachments: std.ArrayList(Attachment) = .empty,
    external_bodies: ?std.json.Value = null,
    fn enter(self: *Context, depth: usize) !void {
        if (depth > max_depth) return error.MimeTooDeep;
        self.parts += 1;
        if (self.parts > max_parts) return error.TooManyMimeParts;
    }
    fn accountBytes(self: *Context, size: usize) !void {
        if (size > max_body_bytes or size > max_raw_bytes - self.decoded) return error.DecodedMessageTooLarge;
        self.decoded += size;
    }
    fn add(self: *Context, headers: []const Header, mime_type: []const u8, filename: []const u8, data: []const u8) !void {
        const attached = try isAttached(headers, filename);
        const decoded_filename = try displayHeader(filename, self.allocator);
        const calendar_type = std.ascii.eqlIgnoreCase(mime_type, "text/calendar");
        if (isCalendarPart(mime_type, decoded_filename)) {
            if (data.len > max_calendar_bytes) return error.CalendarTooLarge;
            const calendar: ?[]const u8 = calendarText(data, parameter(try header(headers, "Content-Type"), "charset") orelse "utf-8", self.allocator) catch |err| switch (err) {
                error.InvalidUtf8, error.InvalidCharsetData, error.UnsupportedCharset => if (calendar_type) return err else null,
                else => return err,
            };
            if (calendar) |value| {
                if (value.len > max_calendar_bytes) return error.CalendarTooLarge;
                // Binary .ics files need an actual VCALENDAR envelope. The
                // invitation parser performs full method/identity validation
                // before either inspection or submission.
                if (calendar_type or calendarEnvelope(value)) {
                    // Conflicting requests disable the invitation rather than
                    // guessing which event identity is meant. The rest of the
                    // message, including each named .ics file, stays readable.
                    if (self.calendar) |existing| {
                        if (!sameCalendar(existing, value)) self.calendar_ambiguous = true;
                    } else self.calendar = value;
                }
            }
        }
        if (attached or (!std.ascii.eqlIgnoreCase(mime_type, "text/plain") and !std.ascii.eqlIgnoreCase(mime_type, "text/html") and !std.ascii.eqlIgnoreCase(mime_type, "text/calendar"))) {
            if (self.attachments.items.len == max_attachments) return error.TooManyAttachments;
            try self.attachments.append(self.allocator, .{ .filename = decoded_filename, .mime_type = try self.allocator.dupe(u8, mime_type), .content_id = try self.allocator.dupe(u8, try header(headers, "Content-ID")), .disposition = try dispositionToken(headers), .content_location = try self.allocator.dupe(u8, try header(headers, "Content-Location")), .size = data.len, .data = data });
        }
        if (attached) return;
        if (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "text/html")) {
            const text = try convertCharset(data, parameter(try header(headers, "Content-Type"), "charset") orelse "utf-8", self.allocator);
            const target = if (std.ascii.eqlIgnoreCase(mime_type, "text/plain")) &self.plain else &self.html;
            if (std.ascii.eqlIgnoreCase(mime_type, "text/html")) self.html_documents += 1;
            if (text.len + @intFromBool(target.items.len != 0) > max_body_bytes - target.items.len) return error.BodyTooLarge;
            if (target.items.len != 0) try target.append(self.allocator, '\n');
            try target.appendSlice(self.allocator, text);
        }
    }
    fn rawPart(self: *Context, entity: Entity, depth: usize) anyerror!void {
        try self.enter(depth);
        const content_type = try header(entity.headers, "Content-Type");
        const mime_type = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
        if (mime_type.len > 0) try validateMimeType(mime_type);
        if (std.ascii.startsWithIgnoreCase(mime_type, "multipart/")) {
            const boundary = parameter(content_type, "boundary") orelse return error.MissingMimeBoundary;
            if (boundary.len == 0 or boundary.len > 200) return error.InvalidMimeBoundary;
            var marker: [204]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&marker, "--{s}", .{boundary});
            var start: ?usize = null;
            var closed = false;
            var offset: usize = 0;
            while (offset < entity.body.len) {
                const end = std.mem.indexOfScalarPos(u8, entity.body, offset, '\n') orelse entity.body.len;
                const line = std.mem.trimEnd(u8, entity.body[offset..end], "\r \t");
                if (std.mem.startsWith(u8, line, prefix)) {
                    const suffix = line[prefix.len..];
                    if (suffix.len == 0 or std.mem.eql(u8, suffix, "--")) {
                        if (start) |begin| {
                            // Exactly one newline belongs to the delimiter.
                            // Further trailing newlines belong to an enclosed
                            // original message and must survive byte-for-byte.
                            const end_at = if (offset >= begin + 2 and std.mem.eql(u8, entity.body[offset - 2 .. offset], "\r\n")) offset - 2 else if (offset > begin and entity.body[offset - 1] == '\n') offset - 1 else offset;
                            const part = entity.body[begin..end_at];
                            try self.rawPart(try splitEntity(part, self.allocator), depth + 1);
                        }
                        if (suffix.len != 0) {
                            closed = true;
                            break;
                        }
                        start = if (end < entity.body.len) end + 1 else end;
                    }
                }
                offset = if (end < entity.body.len) end + 1 else end;
            }
            if (!closed or start == null) return error.IncompleteMultipart;
            return;
        }
        const decoded = try decodeTransfer(entity.body, try header(entity.headers, "Content-Transfer-Encoding"), self.allocator);
        try self.accountBytes(decoded.len);
        const filename = (try filenameParameter(try header(entity.headers, "Content-Disposition"), "filename", self.allocator)) orelse (try filenameParameter(content_type, "name", self.allocator)) orelse "";
        try self.add(entity.headers, if (mime_type.len == 0) "text/plain" else mime_type, filename, decoded);
    }
    fn gmailPart(self: *Context, part: std.json.Value, depth: usize) anyerror!void {
        try self.enter(depth);
        const mime_type = if (b.optional(part, "mimeType")) |value| try b.string(value) else if (b.optional(part, "body") == null and b.optional(part, "parts") == null) return else return error.MissingMimeType;
        try validateMimeType(mime_type);
        const headers = try gmailHeaders(part, self.allocator);
        var child_count: usize = 0;
        if (b.optional(part, "parts")) |children| {
            if (children != .array or children.array.items.len > max_parts) return error.TooManyMimeParts;
            child_count = children.array.items.len;
            for (children.array.items) |child| try self.gmailPart(child, depth + 1);
        }
        const body = b.optional(part, "body") orelse return;
        const declared = if (b.optional(body, "size")) |v| try b.integer(v) else 0;
        if (declared < 0 or declared > types.Limits.incoming_attachment_bytes) return error.BodyTooLarge;
        const filename = if (b.optional(part, "filename")) |v| try b.string(v) else "";
        if (isCalendarPart(mime_type, filename) and declared > max_calendar_bytes) return error.CalendarTooLarge;
        const inline_data = if (b.optional(body, "data")) |v| try b.string(v) else "";
        const large = declared > max_body_bytes;
        // A large part may only remain an unloaded file descriptor. Senders
        // often put an unused Content-ID or Content-Location on an ordinary
        // explicit attachment; those stay listable. Inline parts and implicit
        // related resources keep the loaded-content cap.
        const disposition = try dispositionToken(headers);
        const referenced = (try header(headers, "Content-ID")).len != 0 or (try header(headers, "Content-Location")).len != 0;
        if (large and (inline_data.len != 0 or !(try isAttached(headers, filename)) or std.ascii.eqlIgnoreCase(disposition, "inline") or (referenced and !std.ascii.eqlIgnoreCase(disposition, "attachment")))) return error.BodyTooLarge;
        const part_id = if (b.optional(part, "partId")) |v| try b.string(v) else "";
        var external_id: ?[]const u8 = null;
        var external_data: ?[]const u8 = null;
        if (b.optional(body, "attachmentId")) |id| {
            const text = try b.string(id);
            if (text.len > 1024) return error.InvalidAttachmentId;
            if (text.len > 0) {
                external_id = text;
                if (self.external_bodies) |map| if (b.optional(map, text)) |v| {
                    external_data = if (v == .object) try b.string(try b.field(v, "data")) else try b.string(v);
                };
                if (large and external_data != null) return error.BodyTooLarge;
                if (external_data == null) {
                    if (isCalendarPart(mime_type, filename) or (filename.len == 0 and (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "text/html")))) return error.ExternalBodyRequired;
                    if (self.attachments.items.len == max_attachments) return error.TooManyAttachments;
                    try self.attachments.append(self.allocator, .{ .id = try self.allocator.dupe(u8, text), .filename = try displayHeader(filename, self.allocator), .mime_type = try self.allocator.dupe(u8, mime_type), .content_id = try self.allocator.dupe(u8, try header(headers, "Content-ID")), .disposition = try dispositionToken(headers), .content_location = try self.allocator.dupe(u8, try header(headers, "Content-Location")), .size = @intCast(declared), .data = "" });
                    return;
                }
            }
        }
        if (large) return error.BodyTooLarge;
        const data = external_data orelse if (b.optional(body, "data")) |v| try b.string(v) else "";
        if (data.len == 0) {
            if (declared != 0) return error.BodySizeMismatch;
            return;
        }
        const decoded = try decodeBase64Url(data, self.allocator);
        if (b.optional(body, "size") != null) {
            // Compatibility with understated Gmail inline-text metadata, not a
            // change to Google's documented byte-count contract. Complete,
            // validated decoded bytes still govern every existing size cap.
            // An absent/empty parts array is a leaf; size zero can understate
            // nonempty inline text. Empty or shorter bodies remain refused,
            // with one compatibility exception: for base64 UTF-8 inline text
            // whose original starts with a byte order mark, Gmail returns the
            // data without those three bytes but declares the original size.
            // The data cannot prove that a mark was removed, so a body truncated
            // by exactly three bytes in this shape is also accepted.
            const inline_text = child_count == 0 and external_id == null and
                (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "text/html")) and
                !(try isAttached(headers, filename));
            const expected: usize = @intCast(declared);
            const stripped_bom = inline_text and decoded.len + utf8_bom.len == expected and
                !std.mem.startsWith(u8, decoded, utf8_bom) and
                std.ascii.eqlIgnoreCase(parameter(try header(headers, "Content-Type"), "charset") orelse "", "utf-8") and
                std.ascii.eqlIgnoreCase(std.mem.trim(u8, try header(headers, "Content-Transfer-Encoding"), " \t"), "base64");
            if ((decoded.len < expected and !stripped_bom) or (!inline_text and decoded.len != expected)) return error.BodySizeMismatch;
        }
        try self.accountBytes(decoded.len);
        const old_count = self.attachments.items.len;
        try self.add(headers, mime_type, filename, decoded);
        if (self.attachments.items.len > old_count) self.attachments.items[old_count].id = try self.allocator.dupe(u8, external_id orelse part_id);
    }
    fn finish(self: *Context, result: *ParsedMessage) !void {
        result.body_html = try self.html.toOwnedSlice(self.allocator);
        result.html_documents = self.html_documents;
        result.body_source = if (self.plain.items.len > 0) .plain else if (result.body_html.len > 0) .html else .unknown;
        // htmlToText already returns owned sanitized text. A second sanitize
        // retained another full body in arena callers without changing bytes.
        result.body_text = if (self.plain.items.len > 0)
            try sanitizeText(try self.plain.toOwnedSlice(self.allocator), self.allocator)
        else
            try htmlToText(result.body_html, self.allocator);
        result.calendar = if (self.calendar_ambiguous) null else self.calendar;
        result.calendar_ambiguous = self.calendar_ambiguous;
        result.attachments = try self.attachments.toOwnedSlice(self.allocator);
    }
};

pub fn parameter(content_type: []const u8, name: []const u8) ?[]const u8 {
    var pos = std.mem.indexOfScalar(u8, content_type, ';') orelse return null;
    while (pos < content_type.len) {
        pos += 1;
        while (pos < content_type.len and (content_type[pos] == ' ' or content_type[pos] == '\t')) pos += 1;
        const start = pos;
        while (pos < content_type.len and content_type[pos] != '=' and content_type[pos] != ';') pos += 1;
        if (pos == content_type.len) return null;
        if (content_type[pos] != '=') continue;
        const key = std.mem.trim(u8, content_type[start..pos], " \t");
        pos += 1;
        while (pos < content_type.len and (content_type[pos] == ' ' or content_type[pos] == '\t')) pos += 1;
        var value_start = pos;
        var end = pos;
        if (pos < content_type.len and content_type[pos] == '"') {
            pos += 1;
            value_start = pos;
            while (pos < content_type.len and content_type[pos] != '"') : (pos += 1) {
                if (content_type[pos] == '\\') return null;
            }
            if (pos == content_type.len) return null;
            end = pos;
            pos += 1;
            while (pos < content_type.len and content_type[pos] != ';') pos += 1;
        } else {
            while (pos < content_type.len and content_type[pos] != ';') pos += 1;
            end = pos;
        }
        if (std.ascii.eqlIgnoreCase(key, name)) return std.mem.trim(u8, content_type[value_start..end], " \t");
    }
    return null;
}
fn filenameParameter(value: []const u8, name: []const u8, a: std.mem.Allocator) !?[]const u8 {
    var key: [64]u8 = undefined;
    var encoded = parameter(value, try std.fmt.bufPrint(&key, "{s}*", .{name}));
    if (encoded == null) {
        var joined: std.ArrayList(u8) = .empty;
        for (0..32) |index| {
            const item = parameter(value, try std.fmt.bufPrint(&key, "{s}*{d}*", .{ name, index })) orelse break;
            if (item.len > 2048 - joined.items.len) return error.FilenameTooLarge;
            try joined.appendSlice(a, item);
        }
        if (joined.items.len > 0) encoded = joined.items;
    }
    if (encoded) |data| {
        const first = std.mem.indexOfScalar(u8, data, '\'') orelse return error.InvalidAttachmentFilename;
        const second = std.mem.indexOfScalarPos(u8, data, first + 1, '\'') orelse return error.InvalidAttachmentFilename;
        const bytes = try a.alloc(u8, data.len - second - 1);
        var pos: usize = second + 1;
        var used: usize = 0;
        while (pos < data.len) : (pos += 1) {
            if (data[pos] == '%') {
                if (pos + 2 >= data.len) return error.InvalidAttachmentFilename;
                bytes[used] = std.fmt.parseInt(u8, data[pos + 1 .. pos + 3], 16) catch return error.InvalidAttachmentFilename;
                pos += 2;
            } else bytes[used] = data[pos];
            used += 1;
        }
        return try convertCharset(bytes[0..used], data[0..first], a);
    }
    return parameter(value, name);
}

pub fn decodeBase64Url(data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const source = std.mem.trimEnd(u8, data, "=");
    if (data.len - source.len > 2) return error.InvalidBase64;
    const len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(source) catch return error.InvalidBase64;
    if (len > max_body_bytes) return error.BodyTooLarge;
    const out = try allocator.alloc(u8, len);
    std.base64.url_safe_no_pad.Decoder.decode(out, source) catch return error.InvalidBase64;
    return out;
}

pub fn decodeTransfer(data: []const u8, encoding: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (data.len > max_raw_bytes) return error.BodyTooLarge;
    if (std.ascii.eqlIgnoreCase(encoding, "base64")) {
        const clean = try allocator.alloc(u8, data.len);
        var len: usize = 0;
        for (data) |c| if (c != ' ' and c != '\t' and c != '\r' and c != '\n') {
            clean[len] = c;
            len += 1;
        };
        const source = clean[0..len];
        const decoder = if (std.mem.indexOfScalar(u8, source, '=') != null) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder;
        const size = decoder.calcSizeForSlice(source) catch return error.InvalidBase64;
        if (size > max_body_bytes) return error.BodyTooLarge;
        const out = try allocator.alloc(u8, size);
        decoder.decode(out, source) catch return error.InvalidBase64;
        return out;
    }
    if (std.ascii.eqlIgnoreCase(encoding, "quoted-printable")) {
        const out = try allocator.alloc(u8, @min(data.len, max_body_bytes));
        var pos: usize = 0;
        var len: usize = 0;
        while (pos < data.len) : (pos += 1) {
            if (data[pos] == '=') {
                if (pos + 1 < data.len and data[pos + 1] == '\n') {
                    pos += 1;
                    continue;
                }
                if (pos + 2 < data.len and data[pos + 1] == '\r' and data[pos + 2] == '\n') {
                    pos += 2;
                    continue;
                }
                if (pos + 2 >= data.len) return error.InvalidQuotedPrintable;
                if (len == out.len) return error.BodyTooLarge;
                out[len] = std.fmt.parseInt(u8, data[pos + 1 ..][0..2], 16) catch return error.InvalidQuotedPrintable;
                pos += 2;
            } else {
                if (len == out.len) return error.BodyTooLarge;
                out[len] = data[pos];
            }
            len += 1;
        }
        return out[0..len];
    }
    if (encoding.len != 0 and !std.ascii.eqlIgnoreCase(encoding, "7bit") and !std.ascii.eqlIgnoreCase(encoding, "8bit") and !std.ascii.eqlIgnoreCase(encoding, "binary")) return error.UnsupportedTransferEncoding;
    if (data.len > max_body_bytes) return error.BodyTooLarge;
    return try allocator.dupe(u8, data);
}

pub fn convertCharset(data: []const u8, charset: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (data.len > max_body_bytes) return error.BodyTooLarge;
    if (std.ascii.eqlIgnoreCase(charset, "utf-8") or charset.len == 0) {
        if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
        return try allocator.dupe(u8, data);
    }
    if (std.ascii.eqlIgnoreCase(charset, "us-ascii") or std.ascii.eqlIgnoreCase(charset, "ascii")) {
        for (data) |c| if (c >= 128) return error.InvalidCharsetData;
        return try allocator.dupe(u8, data);
    }
    const latin = std.ascii.eqlIgnoreCase(charset, "iso-8859-1") or std.ascii.eqlIgnoreCase(charset, "latin1");
    const windows = std.ascii.eqlIgnoreCase(charset, "windows-1252") or std.ascii.eqlIgnoreCase(charset, "cp1252");
    // ISO-8859-15 is Latin-1 with eight replacements, including the euro sign.
    const latin9 = std.ascii.eqlIgnoreCase(charset, "iso-8859-15") or std.ascii.eqlIgnoreCase(charset, "latin9");
    if (!latin and !windows and !latin9) return error.UnsupportedCharset;
    const table = [_]u21{ 0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178 };
    var output: std.ArrayList(u8) = .empty;
    for (data) |c| {
        const cp: u21 = if (windows and c >= 128 and c < 160) table[c - 128] else if (latin9) switch (c) {
            0xa4 => 0x20ac,
            0xa6 => 0x160,
            0xa8 => 0x161,
            0xb4 => 0x17d,
            0xb8 => 0x17e,
            0xbc => 0x152,
            0xbd => 0x153,
            0xbe => 0x178,
            else => c,
        } else c;
        var encoded: [4]u8 = undefined;
        const count = try std.unicode.utf8Encode(cp, &encoded);
        if (count > max_body_bytes - output.items.len) return error.BodyTooLarge;
        try output.appendSlice(allocator, encoded[0..count]);
    }
    return try output.toOwnedSlice(allocator);
}

pub fn decodeHeader(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (input.len > 8192) return error.HeaderTooLarge;
    var output: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < input.len) {
        if (std.mem.startsWith(u8, input[pos..], "=?")) {
            const cs = std.mem.indexOfScalarPos(u8, input, pos + 2, '?') orelse return error.InvalidEncodedWord;
            if (cs + 3 > input.len or input[cs + 2] != '?') return error.InvalidEncodedWord;
            const end = std.mem.indexOfPos(u8, input, cs + 3, "?=") orelse return error.InvalidEncodedWord;
            const source = input[cs + 3 .. end];
            const decoded = switch (std.ascii.toUpper(input[cs + 1])) {
                'B' => try decodeTransfer(source, "base64", allocator),
                'Q' => blk: {
                    const escaped = try allocator.dupe(u8, source);
                    for (escaped) |*c| if (c.* == '_') {
                        c.* = ' ';
                    };
                    break :blk try decodeTransfer(escaped, "quoted-printable", allocator);
                },
                else => return error.InvalidEncodedWord,
            };
            try output.appendSlice(allocator, try convertCharset(decoded, input[pos + 2 .. cs], allocator));
            pos = end + 2;
            var whitespace = pos;
            while (whitespace < input.len and (input[whitespace] == ' ' or input[whitespace] == '\t')) whitespace += 1;
            if (std.mem.startsWith(u8, input[whitespace..], "=?")) pos = whitespace;
        } else {
            try output.append(allocator, input[pos]);
            pos += 1;
        }
        if (output.items.len > 8192) return error.HeaderTooLarge;
    }
    return try sanitizeText(output.items, allocator);
}

/// Display text for incoming Subject, display names and attachment filenames.
/// RFC 2047 section 6.3: a malformed encoded word must not prevent display.
/// Undecodable words, unknown charsets or invalid bytes fall back to the
/// sanitized literal header. Size bounds stay strict; addresses are parsed
/// separately and are never taken from this text.
pub fn displayHeader(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return decodeHeader(input, allocator) catch |err| switch (err) {
        error.InvalidEncodedWord, error.InvalidBase64, error.InvalidQuotedPrintable, error.UnsupportedCharset, error.InvalidCharsetData, error.InvalidUtf8 => {
            var literal: std.ArrayList(u8) = .empty;
            defer literal.deinit(allocator);
            var pos: usize = 0;
            while (pos < input.len) {
                const count = std.unicode.utf8ByteSequenceLength(input[pos]) catch 0;
                if (count != 0 and pos + count <= input.len and std.unicode.utf8ValidateSlice(input[pos..][0..count])) {
                    try literal.appendSlice(allocator, input[pos..][0..count]);
                    pos += count;
                } else {
                    try literal.appendSlice(allocator, "\u{FFFD}");
                    pos += 1;
                }
                if (literal.items.len > 8192) return error.HeaderTooLarge;
            }
            return try sanitizeText(literal.items, allocator);
        },
        else => return err,
    };
}

pub fn sanitizeText(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    if (input.len > max_body_bytes) return error.BodyTooLarge;
    var output: std.ArrayList(u8) = .empty;
    // Sanitization can only remove bytes or normalize CR to a single LF.
    // Reserve once so a valid large body does not retain every growth buffer.
    try output.ensureTotalCapacityPrecise(allocator, input.len);
    var pos: usize = 0;
    while (pos < input.len) {
        const count = try std.unicode.utf8ByteSequenceLength(input[pos]);
        const cp = try std.unicode.utf8Decode(input[pos..][0..count]);
        if (cp == '\r') {
            if (pos + 1 >= input.len or input[pos + 1] != '\n') try output.append(allocator, '\n');
        } else if (cp == '\n' or cp == '\t' or (cp >= 32 and !(cp >= 127 and cp <= 159) and cp != 0x061c and cp != 0x200e and cp != 0x200f and !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069))) {
            try output.appendSlice(allocator, input[pos..][0..count]);
        }
        pos += count;
    }
    return try output.toOwnedSlice(allocator);
}

fn entityCode(entity: []const u8) ?u21 {
    if (std.mem.eql(u8, entity, "amp")) return '&';
    if (std.mem.eql(u8, entity, "lt")) return '<';
    if (std.mem.eql(u8, entity, "gt")) return '>';
    if (std.mem.eql(u8, entity, "quot")) return '"';
    if (std.mem.eql(u8, entity, "apos") or std.mem.eql(u8, entity, "#39")) return '\'';
    if (std.mem.eql(u8, entity, "nbsp")) return ' ';
    if (entity.len > 1 and entity[0] == '#') {
        const hex = entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X');
        const number = std.fmt.parseInt(u21, entity[if (hex) @as(usize, 2) else 1..], if (hex) 16 else 10) catch return null;
        if (number > 0x10ffff or (number >= 0xd800 and number <= 0xdfff)) return null;
        return number;
    }
    return null;
}
fn htmlAttribute(tag: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag.len) {
        while (pos < tag.len and (std.ascii.isWhitespace(tag[pos]) or tag[pos] == '/')) pos += 1;
        const start = pos;
        while (pos < tag.len and !std.ascii.isWhitespace(tag[pos]) and tag[pos] != '=') pos += 1;
        const name = tag[start..pos];
        while (pos < tag.len and std.ascii.isWhitespace(tag[pos])) pos += 1;
        if (pos >= tag.len) return null;
        if (tag[pos] != '=') continue;
        pos += 1;
        while (pos < tag.len and std.ascii.isWhitespace(tag[pos])) pos += 1;
        if (pos == tag.len) return null;
        const quote: ?u8 = if (tag[pos] == '\'' or tag[pos] == '"') tag[pos] else null;
        if (quote != null) pos += 1;
        const value = pos;
        while (pos < tag.len and (if (quote) |q| tag[pos] != q else !std.ascii.isWhitespace(tag[pos]))) pos += 1;
        const end = pos;
        if (quote != null and pos < tag.len) pos += 1;
        if (std.ascii.eqlIgnoreCase(name, key)) return tag[value..end];
    }
    return null;
}

pub fn htmlToText(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (input.len > max_body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var output: std.ArrayList(u8) = .empty;
    try output.ensureTotalCapacityPrecise(allocator, input.len);
    var pos: usize = 0;
    var hidden: ?[]const u8 = null;
    var link: ?[]const u8 = null;
    var pre = false;
    while (pos < input.len) {
        if (input[pos] == '<') {
            if (std.mem.startsWith(u8, input[pos..], "<!--")) {
                const end = std.mem.indexOfPos(u8, input, pos + 4, "-->") orelse input.len;
                pos = @min(input.len, end + 3);
                continue;
            }
            var end = pos + 1;
            var quote: ?u8 = null;
            while (end < input.len) : (end += 1) {
                if (quote) |q| {
                    if (input[end] == q) quote = null;
                } else if (input[end] == '\'' or input[end] == '"') quote = input[end] else if (input[end] == '>') break;
            }
            if (end == input.len) break;
            const raw = std.mem.trim(u8, input[pos + 1 .. end], " \t\r\n");
            const closing = raw.len > 0 and raw[0] == '/';
            const tag = if (closing) raw[1..] else raw;
            var n: usize = 0;
            while (n < tag.len and std.ascii.isAlphanumeric(tag[n])) n += 1;
            const name = tag[0..n];
            if (hidden) |skip| {
                if (closing and std.ascii.eqlIgnoreCase(name, skip)) hidden = null;
            } else if (!closing and (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style") or std.ascii.eqlIgnoreCase(name, "head"))) {
                hidden = name;
            } else {
                if (std.ascii.eqlIgnoreCase(name, "pre")) pre = !closing;
                if (std.ascii.eqlIgnoreCase(name, "a")) {
                    if (!closing) {
                        const href = htmlAttribute(tag[n..], "href");
                        link = if (href) |url| if (std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "mailto:")) url else null else null;
                    } else if (link) |url| {
                        if (url.len > 4096 or url.len + 3 > max_body_bytes - output.items.len) return error.BodyTooLarge;
                        try output.appendSlice(allocator, " (");
                        try output.appendSlice(allocator, url);
                        try output.append(allocator, ')');
                        link = null;
                    }
                }
                const block = std.ascii.eqlIgnoreCase(name, "br") or std.ascii.eqlIgnoreCase(name, "p") or std.ascii.eqlIgnoreCase(name, "div") or std.ascii.eqlIgnoreCase(name, "li") or std.ascii.eqlIgnoreCase(name, "tr") or std.ascii.eqlIgnoreCase(name, "blockquote") or std.ascii.eqlIgnoreCase(name, "pre") or (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6');
                if (block and output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
                if (!closing and std.ascii.eqlIgnoreCase(name, "li")) try output.appendSlice(allocator, "- ");
                if (std.ascii.eqlIgnoreCase(name, "td") and closing) try output.append(allocator, '\t');
            }
            pos = end + 1;
            continue;
        }
        if (hidden != null) {
            pos += 1;
            continue;
        }
        if (input[pos] == '&') {
            if (std.mem.indexOfScalarPos(u8, input, pos + 1, ';')) |end| if (end - pos <= 16) {
                if (entityCode(input[pos + 1 .. end])) |cp| {
                    var encoded: [4]u8 = undefined;
                    const count = try std.unicode.utf8Encode(cp, &encoded);
                    try output.appendSlice(allocator, encoded[0..count]);
                    pos = end + 1;
                    continue;
                }
            };
        }
        const c = input[pos];
        if (pre or !std.ascii.isWhitespace(c)) try output.append(allocator, c) else if (output.items.len > 0 and output.items[output.items.len - 1] != ' ' and output.items[output.items.len - 1] != '\n') try output.append(allocator, ' ');
        pos += 1;
        if (output.items.len > max_body_bytes) return error.BodyTooLarge;
    }
    return try sanitizeText(std.mem.trim(u8, output.items, " \r\n\t"), allocator);
}

pub const ReplyHeaders = struct { in_reply_to: []const u8, references: []const u8 };
pub fn validMessageId(id: []const u8) bool {
    if (id.len < 5 or id.len > 512 or id[0] != '<' or id[id.len - 1] != '>') return false;
    var at = false;
    for (id[1 .. id.len - 1]) |c| {
        if (c <= 32 or c >= 127 or c == '<' or c == '>') return false;
        if (c == '@') at = true;
    }
    return at;
}
fn validateReferences(refs: []const u8) !void {
    if (refs.len > 8192) return error.ReferencesTooLarge;
    var words = std.mem.tokenizeAny(u8, refs, " \t");
    var count: usize = 0;
    while (words.next()) |id| {
        if (!validMessageId(id)) return error.InvalidMessageId;
        count += 1;
        if (count > 32) return error.TooManyReferences;
    }
}
pub fn threading(message_id: []const u8, references: []const u8, in_reply_to: []const u8, allocator: std.mem.Allocator) !ReplyHeaders {
    if (!validMessageId(message_id)) return error.MissingMessageId;
    try validateReferences(references);
    const chain = if (references.len > 0) references else if (validMessageId(in_reply_to)) in_reply_to else "";
    const joined = if (chain.len > 0) try std.fmt.allocPrint(allocator, "{s} {s}", .{ chain, message_id }) else try allocator.dupe(u8, message_id);
    try validateReferences(joined);
    return .{ .in_reply_to = try allocator.dupe(u8, message_id), .references = joined };
}

pub const Compose = struct {
    from: recipients.Mailbox,
    envelope: *const recipients.Envelope,
    subject: []const u8,
    body: []const u8,
    html: ?[]const u8 = null,
    /// Fixed public branding image, independent of the user's attachment quota.
    inline_logo: bool = false,
    /// First byte of the trusted generated branding CID value. Imported HTML
    /// can contain its own Omagma footer, so it must never be searched/rebound.
    logo_offset: ?usize = null,
    calendar: ?[]const u8 = null,
    message_id: []const u8,
    date: []const u8,
    in_reply_to: []const u8 = "",
    references: []const u8 = "",
    attachments: []const Attachment = &.{},
    related: []const Attachment = &.{},
};

fn encodedWords(writer: *std.Io.Writer, value: []const u8) !void {
    try recipients.validateHeader(value);
    if (value.len > 8192) return error.HeaderTooLarge;
    var ascii = true;
    for (value) |c| ascii = ascii and c < 128;
    if (ascii and value.len <= 900) {
        try writer.writeAll(value);
        return;
    }
    var pos: usize = 0;
    while (pos < value.len) {
        var end = @min(value.len, pos + 42);
        if (end < value.len) while ((value[end] & 0xc0) == 0x80) {
            end -= 1;
        };
        if (pos != 0) try writer.writeAll("\r\n ");
        try writer.writeAll("=?UTF-8?B?");
        var encoded: [56]u8 = undefined;
        try writer.writeAll(std.base64.standard.Encoder.encode(&encoded, value[pos..end]));
        try writer.writeAll("?=");
        pos = end;
    }
}
fn writeMailbox(writer: *std.Io.Writer, mailbox: *const recipients.Mailbox) !void {
    try recipients.validateAddress(mailbox.address.slice());
    const name = mailbox.name.slice();
    if (name.len > 0) {
        var ascii = true;
        for (name) |c| ascii = ascii and c < 128;
        if (ascii) {
            try writer.writeByte('"');
            for (name) |c| {
                if (c == '"' or c == '\\') try writer.writeByte('\\');
                try writer.writeByte(c);
            }
            try writer.writeAll("\" ");
        } else {
            try encodedWords(writer, name);
            try writer.writeByte(' ');
        }
    }
    try writer.print("<{s}>", .{mailbox.address.slice()});
}
pub fn writeAddressHeader(writer: *std.Io.Writer, name: []const u8, list: *const recipients.List) !void {
    if (list.count == 0) return;
    try writer.print("{s}: ", .{name});
    for (list.slice(), 0..) |*mailbox, i| {
        if (i != 0) try writer.writeAll(",\r\n ");
        try writeMailbox(writer, mailbox);
    }
    try writer.writeAll("\r\n");
}
fn writeReferences(writer: *std.Io.Writer, refs: []const u8) !void {
    if (refs.len == 0) return;
    try writer.writeAll("References:");
    var words = std.mem.tokenizeAny(u8, refs, " \t");
    while (words.next()) |id| try writer.print("\r\n {s}", .{id});
    try writer.writeAll("\r\n");
}
fn emitBase64Line(writer: *std.Io.Writer, bytes: []const u8) !void {
    var encoded: [76]u8 = undefined;
    try writer.writeAll(std.base64.standard.Encoder.encode(&encoded, bytes));
    try writer.writeAll("\r\n");
}
fn emitText(writer: *std.Io.Writer, text: []const u8) !void {
    return emitTextParts(writer, &.{text});
}
fn emitTextParts(writer: *std.Io.Writer, parts: []const []const u8) !void {
    var chunk: [57]u8 = undefined;
    var used: usize = 0;
    for (parts) |text| {
        var pos: usize = 0;
        while (pos < text.len) : (pos += 1) {
            const newline = text[pos] == '\r' or text[pos] == '\n';
            const bytes: [2]u8 = if (newline) .{ '\r', '\n' } else .{ text[pos], 0 };
            for (bytes[0..if (newline) @as(usize, 2) else 1]) |c| {
                chunk[used] = c;
                used += 1;
                if (used == chunk.len) {
                    try emitBase64Line(writer, &chunk);
                    used = 0;
                }
            }
            if (text[pos] == '\r' and pos + 1 < text.len and text[pos + 1] == '\n') pos += 1;
        }
    }
    if (used > 0) try emitBase64Line(writer, chunk[0..used]);
}
fn validateBody(body: []const u8) !void {
    if (body.len > max_body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    for (body) |c| if (c == 0) return error.InvalidBody;
}
fn textPart(writer: *std.Io.Writer, mime_type: []const u8, body: []const u8) !void {
    try writer.print("Content-Type: {s}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", .{mime_type});
    try emitText(writer, body);
}
pub fn validateAttachment(filename: []const u8, mime_type: []const u8) !void {
    try recipients.validateHeader(filename);
    if (filename.len == 0 or filename.len > 512 or std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..") or std.mem.indexOfAny(u8, filename, "/\\") != null) return error.InvalidAttachmentFilename;
    try validateMimeType(mime_type);
}
pub fn validateMimeType(mime_type: []const u8) !void {
    if (mime_type.len == 0 or mime_type.len > 127) return error.InvalidMimeType;
    var slash: ?usize = null;
    for (mime_type, 0..) |c, index| {
        if (c == '/') {
            if (slash != null) return error.InvalidMimeType;
            slash = index;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidMimeType;
    }
    if (slash == null or slash.? == 0 or slash.? == mime_type.len - 1) return error.InvalidMimeType;
}
pub fn composeAttachments(input: []const types.Attachment, a: std.mem.Allocator) ![]const Attachment {
    // Both the ordinary and related collections use this decoder. Their
    // separate category counts are checked by the composer before encoding.
    if (input.len > types.Limits.related_resources) return error.TooManyAttachments;
    const attachments = try a.alloc(Attachment, input.len);
    var total: usize = 0;
    for (input, attachments) |item, *dest| {
        try validateAttachment(item.filename, item.mimeType);
        const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(std.mem.trimEnd(u8, item.data, "=")) catch return error.InvalidBase64;
        if (decoded_size > max_body_bytes - total) return error.AttachmentsTooLarge;
        if (item.size != decoded_size) return error.BodySizeMismatch;
        const data = try decodeBase64Url(item.data, a);
        total += data.len;
        dest.* = .{ .filename = item.filename, .mime_type = item.mimeType, .content_id = if (item.contentId) |id| try contentId(id) else "", .disposition = item.disposition orelse "", .content_location = item.contentLocation orelse "", .size = data.len, .data = data };
    }
    return attachments;
}
fn attachmentPart(writer: *std.Io.Writer, attachment: Attachment, related: bool, boundary: []const u8) !void {
    // Related resources must display in the HTML even when the source client
    // tagged a referenced image as an attachment. The frozen snapshot keeps
    // that source disposition separately.
    try writer.print("Content-Type: {s}\r\nContent-Disposition: {s};\r\n filename*0*=UTF-8''", .{ attachment.mime_type, if (related) @as([]const u8, "inline") else "attachment" });
    const hex = "0123456789ABCDEF";
    var col: usize = 0;
    var segment: usize = 0;
    for (attachment.filename) |c| {
        const literal = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$&+-.^_`|~", c) != null;
        const length: usize = if (literal) 1 else 3;
        if (col + length > 54) {
            segment += 1;
            try writer.print(";\r\n filename*{d}*=", .{segment});
            col = 0;
        }
        col += length;
        if (literal) try writer.writeByte(c) else try writer.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
    }
    try writer.writeAll("\r\n");
    if (related and attachment.content_id.len > 0) try writer.print("Content-ID: <{s}>\r\n", .{try contentId(attachment.content_id)});
    if (related and attachment.content_location.len > 0) {
        try recipients.validateHeader(attachment.content_location);
        try writer.print("Content-Location: {s}\r\n", .{attachment.content_location});
    }
    if (std.ascii.eqlIgnoreCase(attachment.mime_type, "message/rfc822") or std.ascii.eqlIgnoreCase(attachment.mime_type, "message/global")) {
        if (attachment.source) |source| {
            try writer.writeAll("Content-Transfer-Encoding: 8bit\r\n\r\n");
            try emitIdentityStream(writer, source, attachment.size, boundary);
            try writer.writeAll("\r\n");
            return;
        }
        if (!identityEncodingSafe(attachment.data)) return error.UnsupportedOriginalEncoding;
        try writer.writeAll("Content-Transfer-Encoding: 8bit\r\n\r\n");
        try writer.writeAll(attachment.data);
        try writer.writeAll("\r\n");
        return;
    }
    try writer.writeAll("Content-Transfer-Encoding: base64\r\n\r\n");
    if (attachment.source) |source| return emitBase64Stream(writer, source, attachment.size);
    var offset: usize = 0;
    while (offset < attachment.data.len) {
        const end = @min(offset + 57, attachment.data.len);
        try emitBase64Line(writer, attachment.data[offset..end]);
        offset = end;
    }
}

fn emitBase64Stream(writer: *std.Io.Writer, source: Source, size: usize) !void {
    // A multiple of 57 produces the same 76-column base64 lines as the small
    // encoder. Short source reads never split/pad an intermediate base64 unit.
    var chunk: [57 * 256]u8 = undefined;
    var buffered: usize = 0;
    var consumed: usize = 0;
    while (true) {
        const n = try source.read(chunk[buffered..]);
        if (n == 0) break;
        if (n > size -| consumed) return error.BodySizeMismatch;
        consumed += n;
        buffered += n;
        const complete = buffered / 57 * 57;
        var offset: usize = 0;
        while (offset < complete) : (offset += 57) try emitBase64Line(writer, chunk[offset..][0..57]);
        std.mem.copyForwards(u8, &chunk, chunk[complete..buffered]);
        buffered -= complete;
    }
    if (consumed != size) return error.BodySizeMismatch;
    if (buffered > 0) try emitBase64Line(writer, chunk[0..buffered]);
}
fn emitIdentityStream(writer: *std.Io.Writer, source: Source, size: usize, boundary: []const u8) !void {
    var chunk: [16 * 1024]u8 = undefined;
    var marker_buffer: [74]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buffer, "--{s}", .{boundary});
    var line_bytes: usize = 0;
    var marker_matches = true;
    var cr = false;
    var consumed: usize = 0;
    while (true) {
        const n = try source.read(&chunk);
        if (n == 0) break;
        if (n > size -| consumed) return error.BodySizeMismatch;
        consumed += n;
        for (chunk[0..n]) |byte| {
            if (byte == 0 or (cr and byte != '\n')) return error.UnsupportedOriginalEncoding;
            if (byte == '\n') {
                if (!cr) return error.UnsupportedOriginalEncoding;
                line_bytes = 0;
                marker_matches = true;
                cr = false;
            } else if (byte == '\r') {
                cr = true;
            } else {
                if (line_bytes < marker.len and byte != marker[line_bytes]) marker_matches = false;
                line_bytes += 1;
                if (line_bytes == marker.len and marker_matches) return error.MimeBoundaryCollision;
                if (line_bytes > 998) return error.UnsupportedOriginalEncoding;
            }
        }
        try writer.writeAll(chunk[0..n]);
    }
    if (consumed != size) return error.BodySizeMismatch;
    if (cr) return error.UnsupportedOriginalEncoding;
}

/// Transport-only unique CID. The generated review HTML has a trusted branding
/// placeholder; binding it to the operation's RFC Message-ID changes no prose,
/// styling, attachments or remote-resource policy.
pub fn logoContentId(message_id: []const u8, out: []u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message_id, &digest, .{});
    return std.fmt.bufPrint(out, "omagma-logo.{s}@omagma.invalid", .{std.fmt.bytesToHex(digest, .lower)});
}
fn htmlPart(writer: *std.Io.Writer, html: []const u8, inline_logo: bool, logo_offset: ?usize, message_id: []const u8, related: []const Attachment) !void {
    if (!inline_logo and related.len == 0) return textPart(writer, "text/html", html);
    const needle = "<img src=\"cid:omagma-logo@omagma.invalid\"";
    const value_at: usize = if (!inline_logo) 0 else if (logo_offset) |offset| blk: {
        if (offset > html.len or markdown_logo.content_id.len > html.len - offset or !std.mem.eql(u8, html[offset..][0..markdown_logo.content_id.len], markdown_logo.content_id)) return error.MissingLogoReference;
        break :blk offset;
    } else blk: {
        const found = std.mem.indexOf(u8, html, needle) orelse return error.MissingLogoReference;
        if (std.mem.indexOf(u8, html[found + needle.len ..], needle) != null) return error.AmbiguousLogoReference;
        break :blk found + "<img src=\"cid:".len;
    };
    var cid_buffer: [128]u8 = undefined;
    const cid = try logoContentId(message_id, &cid_buffer);
    for (related) |resource| if (inline_logo and std.mem.eql(u8, resource.content_id, cid)) return error.AmbiguousContentId;
    try writer.writeAll("Content-Type: multipart/related; type=\"text/html\"; boundary=\"omagma-v1-related\"\r\n\r\n--omagma-v1-related\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n");
    if (inline_logo) {
        try emitTextParts(writer, &.{ html[0..value_at], cid, html[value_at + markdown_logo.content_id.len ..] });
        try writer.print("--omagma-v1-related\r\nContent-Type: image/png\r\nContent-Disposition: inline; filename=\"omagma-logo.png\"\r\nContent-ID: <{s}>\r\nContent-Transfer-Encoding: base64\r\n\r\n", .{cid});
        var offset: usize = 0;
        while (offset < markdown_logo.png.len) {
            const end = @min(offset + 57, markdown_logo.png.len);
            try emitBase64Line(writer, markdown_logo.png[offset..end]);
            offset = end;
        }
    } else try emitText(writer, html);
    for (related) |resource| {
        try writer.writeAll("--omagma-v1-related\r\n");
        try attachmentPart(writer, resource, true, "omagma-v1-related");
    }
    try writer.writeAll("--omagma-v1-related--\r\n");
}

pub fn encode(compose: Compose, out: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(out[0..@min(out.len, max_raw_bytes)]);
    try encodeInto(compose, &writer, max_body_bytes);
    return writer.buffered();
}
/// Serialize into an owned spool/writer. Attachment sources are consumed once
/// and must verify their immutable content at EOF. No base64 JSON envelope or
/// whole-message allocation is constructed. Caller flushes/publishes its spool
/// only after this succeeds and must discard it on any error.
pub fn encodeTo(compose: Compose, writer: *std.Io.Writer) !void {
    var limited: byte_stream.LimitedWriter = .init(writer, types.Limits.mime_upload_bytes);
    encodeInto(compose, &limited.interface, types.Limits.attachment_bytes) catch |err| {
        if (limited.exceeded) return error.MessageTooLarge;
        return err;
    };
}
fn encodeInto(compose: Compose, writer: *std.Io.Writer, attachment_limit: usize) !void {
    try recipients.validateEnvelope(compose.envelope);
    try recipients.validateAddress(compose.from.address.slice());
    try recipients.validateHeader(compose.from.name.slice());
    try recipients.validateHeader(compose.subject);
    try recipients.validateHeader(compose.date);
    if (!validMessageId(compose.message_id)) return error.InvalidMessageId;
    if (compose.in_reply_to.len > 0 and !validMessageId(compose.in_reply_to)) return error.InvalidMessageId;
    try validateReferences(compose.references);
    try validateBody(compose.body);
    if (compose.html) |html| try validateBody(html);
    if (compose.calendar) |calendar| try validateBody(calendar);
    if (compose.html != null and compose.calendar != null) return error.UnsupportedComposeParts;
    if ((compose.inline_logo or compose.related.len > 0) and compose.html == null) return error.UnsupportedComposeParts;
    if (compose.attachments.len > types.Limits.attachments or compose.related.len > types.Limits.related_resources) return error.TooManyAttachments;
    var attachment_bytes: usize = 0;
    for ([_][]const Attachment{ compose.attachments, compose.related }) |list| for (list) |attachment| {
        try validateAttachment(attachment.filename, attachment.mime_type);
        if (attachment.source != null and attachment.data.len != 0) return error.AmbiguousAttachmentSource;
        const size = if (attachment.source != null) attachment.size else attachment.data.len;
        if (size > attachment_limit - attachment_bytes) return error.AttachmentsTooLarge;
        attachment_bytes += size;
        if (attachment.source == null and attachment.size != 0 and attachment.size != attachment.data.len) return error.BodySizeMismatch;
    };
    var related_bytes: usize = 0;
    for (compose.related, 0..) |resource, index| {
        const size = if (resource.source != null) resource.size else resource.data.len;
        if (size > max_body_bytes - related_bytes) return error.AttachmentsTooLarge;
        related_bytes += size;
        if (std.ascii.startsWithIgnoreCase(resource.mime_type, "message/")) return error.UnsupportedRelatedType;
        if (resource.content_id.len == 0 and resource.content_location.len == 0) return error.MissingRelatedIdentity;
        if (resource.content_id.len > 0) _ = try contentId(resource.content_id);
        try recipients.validateHeader(resource.content_location);
        for (compose.related[0..index]) |previous| if ((resource.content_id.len > 0 and std.mem.eql(u8, resource.content_id, previous.content_id)) or (resource.content_location.len > 0 and std.mem.eql(u8, resource.content_location, previous.content_location))) return error.AmbiguousContentId;
    }
    var boundary_buffer: [70]u8 = undefined;
    const boundary = try outerBoundary(compose, &boundary_buffer);
    var eight_bit = false;
    for (compose.attachments) |attachment| if (std.ascii.eqlIgnoreCase(attachment.mime_type, "message/rfc822") or std.ascii.eqlIgnoreCase(attachment.mime_type, "message/global")) {
        eight_bit = eight_bit or attachment.source != null;
        for (attachment.data) |c| eight_bit = eight_bit or c >= 128;
    };
    try writer.writeAll("From: ");
    try writeMailbox(writer, &compose.from);
    try writer.writeAll("\r\n");
    try writeAddressHeader(writer, "To", &compose.envelope.to);
    try writeAddressHeader(writer, "Cc", &compose.envelope.cc);
    try writeAddressHeader(writer, "Bcc", &compose.envelope.bcc);
    try writer.writeAll("Subject: ");
    try encodedWords(writer, compose.subject);
    try writer.print("\r\nDate: {s}\r\nMessage-ID: {s}\r\nMIME-Version: 1.0\r\n", .{ compose.date, compose.message_id });
    if (compose.in_reply_to.len > 0) try writer.print("In-Reply-To: {s}\r\n", .{compose.in_reply_to});
    try writeReferences(writer, compose.references);
    if (compose.html != null or compose.calendar != null or compose.attachments.len > 0) {
        const mixed = compose.calendar != null or compose.attachments.len > 0;
        try writer.print("Content-Type: multipart/{s}; boundary=\"{s}\"\r\n", .{ if (mixed) @as([]const u8, "mixed") else "alternative", boundary });
        if (eight_bit) try writer.writeAll("Content-Transfer-Encoding: 8bit\r\n");
        try writer.print("\r\n--{s}\r\n", .{boundary});
        if (compose.html != null and mixed) {
            try writer.writeAll("Content-Type: multipart/alternative; boundary=\"omagma-v1-alt\"\r\n\r\n--omagma-v1-alt\r\n");
            try textPart(writer, "text/plain", compose.body);
            try writer.writeAll("--omagma-v1-alt\r\n");
            try htmlPart(writer, compose.html.?, compose.inline_logo, compose.logo_offset, compose.message_id, compose.related);
            try writer.writeAll("--omagma-v1-alt--\r\n");
        } else try textPart(writer, "text/plain", compose.body);
        if (compose.calendar) |ics| {
            try writer.print("--{s}\r\n", .{boundary});
            try textPart(writer, "text/calendar; method=REPLY", ics);
        } else if (compose.html != null and !mixed) {
            try writer.print("--{s}\r\n", .{boundary});
            try htmlPart(writer, compose.html.?, compose.inline_logo, compose.logo_offset, compose.message_id, compose.related);
        }
        for (compose.attachments) |attachment| {
            try writer.print("--{s}\r\n", .{boundary});
            try attachmentPart(writer, attachment, false, boundary);
        }
        try writer.print("--{s}--\r\n", .{boundary});
    } else try textPart(writer, "text/plain", compose.body);
}

test "original mail: exact message attachment and collision-safe outer MIME delimiter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = "From: source@example.test\r\nSubject: Original\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"omagma-v1-part\"\r\n\r\n--omagma-v1-part\r\nContent-Type: text/html\r\n\r\n<p><img src=\"cid:image@example.test\"></p>\r\n--omagma-v1-part--\r\n\r\n";
    const source = try originalSource(a, original);
    try std.testing.expectEqualStrings("message/rfc822", source.attachment.mimeType);
    var sender: recipients.Mailbox = .{};
    try sender.address.set("self@example.test");
    var envelope_out: recipients.Envelope = .{};
    var peer: recipients.Mailbox = .{};
    try peer.address.set("peer@example.test");
    try envelope_out.to.append(peer);
    const output = try a.alloc(u8, max_raw_bytes);
    const raw = try encode(.{ .from = sender, .envelope = &envelope_out, .subject = "Fwd: Original", .body = "My note", .message_id = "<forward@example.test>", .date = "Thu, 08 Oct 2026 12:00:00 +0000", .attachments = try composeAttachments(&.{source.attachment}, a) }, output);
    try std.testing.expect(std.mem.indexOf(u8, raw, "boundary=\"omagma-v1-part.") != null);
    const marker = "Content-Type: message/rfc822\r\n";
    const part_at = std.mem.indexOf(u8, raw, marker).?;
    const body_at = (std.mem.indexOfPos(u8, raw, part_at, "\r\n\r\n") orelse return error.MissingOriginalPart) + 4;
    try std.testing.expectEqualSlices(u8, original, raw[body_at..][0..original.len]);
    try std.testing.expect(std.mem.indexOf(u8, raw[part_at..body_at], "Content-Transfer-Encoding: 8bit") != null);
    const parsed = try parse(raw, a);
    try std.testing.expectEqualSlices(u8, original, parsed.attachments[0].data);
    const utf8 = try originalSource(a, "Subject: Original 🌋\r\n\r\n<p>Original</p>\r\n");
    try std.testing.expectEqualStrings("message/global", utf8.attachment.mimeType);
    const binary = try originalSource(a, "Subject: Binary\r\n\r\n\x00\xff\r\n");
    try std.testing.expectEqualStrings("application/octet-stream", binary.attachment.mimeType);
}

test "original mail: related resources keep original CID and only trusted logo offset is rebound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rendered = try @import("markdown_mail.zig").render(a, "**My note**");
    const html = try std.fmt.allocPrint(a, "{s}<img src=\"cid:omagma-logo@omagma.invalid\" alt=\"Original footer\">", .{rendered.html});
    var sender: recipients.Mailbox = .{};
    try sender.address.set("self@example.test");
    var envelope_out: recipients.Envelope = .{};
    var peer: recipients.Mailbox = .{};
    try peer.address.set("peer@example.test");
    try envelope_out.to.append(peer);
    const bytes = [_]u8{ 0, 255, 128, 13, 10 };
    const related = [_]Attachment{.{ .filename = "original-footer.png", .mime_type = "image/png", .content_id = "omagma-logo@omagma.invalid", .data = &bytes, .size = bytes.len }};
    const output = try a.alloc(u8, max_raw_bytes);
    const raw = try encode(.{ .from = sender, .envelope = &envelope_out, .subject = "Inline original", .body = rendered.plain, .html = html, .inline_logo = true, .logo_offset = rendered.logoOffset, .related = &related, .message_id = "<inline-original@example.test>", .date = "Thu, 08 Oct 2026 12:00:00 +0000" }, output);
    const parsed = try parse(raw, a);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body_html, "cid:omagma-logo@omagma.invalid\" alt=\"Original footer\"") != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expectEqualStrings("<omagma-logo@omagma.invalid>", parsed.attachments[1].content_id);
    try std.testing.expectEqualSlices(u8, &bytes, parsed.attachments[1].data);
}
fn boundaryClashes(raw: []const u8, boundary: []const u8) bool {
    var buffer: [74]u8 = undefined;
    const marker = std.fmt.bufPrint(&buffer, "--{s}", .{boundary}) catch return true;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, marker)) return true;
    return false;
}
fn outerBoundary(compose: Compose, buffer: []u8) ![]const u8 {
    const fixed = "omagma-v1-part";
    var collision = false;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(compose.message_id);
    for (compose.attachments) |attachment| {
        hasher.update(attachment.data);
        if (attachment.source != null) hasher.update(attachment.filename);
        collision = collision or attachment.source != null or boundaryClashes(attachment.data, fixed);
    }
    if (!collision) return fixed;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const prefix: [16]u8 = digest[0..16].*;
    const hex = std.fmt.bytesToHex(prefix, .lower);
    for (0..128) |attempt| {
        const candidate = try std.fmt.bufPrint(buffer, "omagma-v1-part.{s}.{d}", .{ hex, attempt });
        var valid = true;
        for (compose.attachments) |attachment| valid = valid and !boundaryClashes(attachment.data, candidate);
        if (valid) return candidate;
    }
    return error.MimeBoundaryCollision;
}

pub fn base64Url(raw: []const u8, out: []u8) ![]const u8 {
    if (raw.len > max_raw_bytes) return error.MessageTooLarge;
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    if (size > out.len) return error.OutputTooSmall;
    return std.base64.url_safe_no_pad.Encoder.encode(out, raw);
}

const SyntheticStream = struct {
    size: usize,
    offset: usize = 0,
    chunk_size: usize = 4093,
    eof: bool = false,
    fail_at_eof: bool = false,
    fn read(ctx: *anyopaque, output: []u8) anyerror!usize {
        const self: *SyntheticStream = @ptrCast(@alignCast(ctx));
        if (self.offset == self.size) {
            self.eof = true;
            if (self.fail_at_eof) return error.BlobChanged;
            return 0;
        }
        const n = @min(@min(output.len, self.chunk_size), self.size - self.offset);
        for (output[0..n], 0..) |*byte, index| byte.* = @truncate((self.offset + index) *% 31 +% 7);
        self.offset += n;
        return n;
    }
    fn source(self: *SyntheticStream) Source {
        return .{ .ctx = self, .readFn = read };
    }
};
test "attachment streaming: base64 short reads preserve bytes and verify exact EOF" {
    var raw: [1027]u8 = undefined;
    for (&raw, 0..) |*byte, index| byte.* = @truncate(index * 31 + 7);
    var expected_buffer: [2048]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buffer);
    var offset: usize = 0;
    while (offset < raw.len) : (offset += @min(57, raw.len - offset)) try emitBase64Line(&expected, raw[offset..][0..@min(57, raw.len - offset)]);
    for ([_]usize{ 1, 2, 3, 56, 57, 58, 4093 }) |chunk_size| {
        var source: SyntheticStream = .{ .size = raw.len, .chunk_size = chunk_size };
        var output: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);
        try emitBase64Stream(&writer, source.source(), raw.len);
        try std.testing.expectEqualStrings(expected.buffered(), writer.buffered());
        try std.testing.expect(source.eof);
    }
    var short: SyntheticStream = .{ .size = 10 };
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.BodySizeMismatch, emitBase64Stream(&sink.writer, short.source(), 11));
    var long: SyntheticStream = .{ .size = 12 };
    try std.testing.expectError(error.BodySizeMismatch, emitBase64Stream(&sink.writer, long.source(), 11));
    var changed: SyntheticStream = .{ .size = 12, .fail_at_eof = true };
    try std.testing.expectError(error.BlobChanged, emitBase64Stream(&sink.writer, changed.source(), 12));
}
test "attachment streaming: native MIME supports files above JSON cap with bounded writes" {
    var from: recipients.Mailbox = .{};
    try from.address.set("self@example.test");
    var to: recipients.List = .{};
    var peer: recipients.Mailbox = .{};
    try peer.address.set("peer@example.test");
    try to.append(peer);
    const envelope_out: recipients.Envelope = .{ .to = to };
    var source: SyntheticStream = .{ .size = 4 * 1024 * 1024 };
    var attachments = [_]Attachment{.{ .filename = "synthetic.bin", .mime_type = "application/octet-stream", .size = source.size, .source = source.source() }};
    const compose: Compose = .{ .from = from, .envelope = &envelope_out, .subject = "Streaming fixture", .body = "See the attachment.", .date = "Thu, 08 Oct 2026 12:00:00 +0000", .message_id = "<stream@example.test>", .attachments = &attachments };
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try encodeTo(compose, &discard.writer);
    try std.testing.expect(source.eof);
    try std.testing.expect(discard.fullCount() > max_raw_bytes);
    try std.testing.expect(discard.fullCount() < types.Limits.mime_upload_bytes);
    attachments[0].size = types.Limits.attachment_bytes + 1;
    source.offset = 0;
    try std.testing.expectError(error.AttachmentsTooLarge, encodeTo(compose, &discard.writer));
    try std.testing.expectEqual(@as(usize, 0), source.offset);
}
test "attachment streaming: identity source rejects controls and MIME delimiter collisions" {
    const Literal = struct {
        value: []const u8,
        offset: usize = 0,
        fn read(ctx: *anyopaque, out: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const n = @min(@min(out.len, 3), self.value.len - self.offset);
            @memcpy(out[0..n], self.value[self.offset..][0..n]);
            self.offset += n;
            return n;
        }
    };
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    var good: Literal = .{ .value = "Subject: Fixture\r\n\r\nOriginal\r\n" };
    try emitIdentityStream(&writer, .{ .ctx = &good, .readFn = Literal.read }, good.value.len, "outer");
    try std.testing.expectEqualStrings(good.value, writer.buffered());
    var bad: Literal = .{ .value = "Subject: Fixture\r\n\r\n--outer\r\n" };
    try std.testing.expectError(error.MimeBoundaryCollision, emitIdentityStream(&writer, .{ .ctx = &bad, .readFn = Literal.read }, bad.value.len, "outer"));
    bad = .{ .value = "Subject: Fixture\n\nOriginal" };
    try std.testing.expectError(error.UnsupportedOriginalEncoding, emitIdentityStream(&writer, .{ .ctx = &bad, .readFn = Literal.read }, bad.value.len, "outer"));
}
test "attachment streaming: Gmail large file metadata stays external while bodies retain their cap" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const large_file = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"large-file\",\"threadId\":\"large-file\",\"internalDate\":\"1791792000000\",\"payload\":{\"mimeType\":\"application/pdf\",\"filename\":\"large.pdf\",\"headers\":[],\"body\":{\"attachmentId\":\"external-large\",\"size\":4194304}}}", .{});
    const message = try normalizeGmail(large_file, a, null);
    try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
    try std.testing.expectEqual(@as(usize, 4194304), message.attachments[0].size);
    try std.testing.expectEqualStrings("external-large", message.attachments[0].id);
    try std.testing.expectEqualStrings("", message.attachments[0].data);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"large-body\",\"threadId\":\"large-body\",\"internalDate\":\"1791792000000\",\"payload\":{\"mimeType\":\"text/html\",\"headers\":[],\"body\":{\"attachmentId\":\"external-large\",\"size\":4194304}}}", .{});
    try std.testing.expectError(error.BodyTooLarge, normalizeGmail(body, a, null));
    const inline_file = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"inline-large\",\"threadId\":\"inline-large\",\"internalDate\":\"1791792000000\",\"payload\":{\"mimeType\":\"image/png\",\"filename\":\"image.png\",\"headers\":[{\"name\":\"Content-ID\",\"value\":\"<image@example.test>\"}],\"body\":{\"attachmentId\":\"external-large\",\"size\":4194304}}}", .{});
    try std.testing.expectError(error.BodyTooLarge, normalizeGmail(inline_file, a, null));
    // An explicit attachment stays an unloaded descriptor despite an unused
    // Content-ID or Content-Location.
    for ([_][]const u8{
        "{\"name\":\"Content-ID\",\"value\":\"<deck@example.test>\"}",
        "{\"name\":\"Content-Location\",\"value\":\"deck.pptx\"}",
    }) |reference| {
        const named = try std.fmt.allocPrint(a, "{{\"id\":\"named-large\",\"threadId\":\"named-large\",\"internalDate\":\"1791792000000\",\"payload\":{{\"mimeType\":\"application/vnd.openxmlformats-officedocument.presentationml.presentation\",\"filename\":\"deck.pptx\",\"headers\":[{{\"name\":\"Content-Disposition\",\"value\":\"attachment; filename=\\\"deck.pptx\\\"\"}},{s}],\"body\":{{\"attachmentId\":\"external-deck\",\"size\":31457280}}}}}}", .{reference});
        const listed = try normalizeGmail(try std.json.parseFromSliceLeaky(std.json.Value, a, named, .{}), a, null);
        try std.testing.expectEqual(@as(usize, 1), listed.attachments.len);
        try std.testing.expectEqualStrings("deck.pptx", listed.attachments[0].filename);
        try std.testing.expectEqual(@as(usize, 31457280), listed.attachments[0].size);
        try std.testing.expectEqualStrings("", listed.attachments[0].data);
    }
    // Inline disposition, inline data and loaded external data keep the cap.
    for ([_][]const u8{
        "{\"payload\":{\"mimeType\":\"image/png\",\"filename\":\"image.png\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"inline; filename=image.png\"},{\"name\":\"Content-ID\",\"value\":\"<image@example.test>\"}],\"body\":{\"attachmentId\":\"external-large\",\"size\":4194304}}}",
        "{\"payload\":{\"mimeType\":\"application/pdf\",\"filename\":\"large.pdf\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"attachment\"},{\"name\":\"Content-ID\",\"value\":\"<pdf@example.test>\"}],\"body\":{\"size\":4194304,\"data\":\"JVBERi0\"}}}",
    }) |source| try std.testing.expectError(error.BodyTooLarge, parseGmail(try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{}), a));
    const loaded = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"external-large\":{\"size\":5,\"data\":\"JVBERi0\"}}", .{});
    try std.testing.expectError(error.BodyTooLarge, parseGmailExternal(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"payload\":{\"mimeType\":\"application/pdf\",\"filename\":\"large.pdf\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"attachment\"},{\"name\":\"Content-ID\",\"value\":\"<pdf@example.test>\"}],\"body\":{\"attachmentId\":\"external-large\",\"size\":4194304}}}", .{}), a, loaded));
}

test "markdown mail: alternatives related approved CID and sixteen user files keep independent octets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rendered = try @import("markdown_mail.zig").render(a, "# Subject\n\n**Hello** fixture. Literal `cid:omagma-logo@omagma.invalid` remains.\n\n`<img src=\"cid:omagma-logo@omagma.invalid\">` stays literal too.");
    var sender: recipients.Mailbox = .{};
    try sender.address.set("self@example.test");
    var envelope_out: recipients.Envelope = .{};
    var peer: recipients.Mailbox = .{};
    try peer.address.set("peer@example.test");
    try envelope_out.to.append(peer);
    var files: [16]Attachment = undefined;
    for (&files, 0..) |*file, i| file.* = .{ .filename = try std.fmt.allocPrint(a, "file-{d}.bin", .{i}), .mime_type = "application/octet-stream", .data = &.{ 0, 0xff, 0x80, '\r', '\n' } };
    const output = try a.alloc(u8, max_raw_bytes);
    const compose: Compose = .{ .from = sender, .envelope = &envelope_out, .subject = "Synthetic", .body = rendered.plain, .html = rendered.html, .inline_logo = true, .message_id = "<markdown@example.test>", .date = "Mon, 05 Oct 2026 12:00:00 +0000", .attachments = &files };
    const raw = try encode(compose, output);
    for ([_][]const u8{ "Content-Type: multipart/mixed;", "Content-Type: multipart/alternative;", "Content-Type: multipart/related; type=\"text/html\";", "Content-ID: <omagma-logo.", "Content-Disposition: inline; filename=\"omagma-logo.png\"" }) |part| try std.testing.expect(std.mem.indexOf(u8, raw, part) != null);
    const plain_at = std.mem.indexOf(u8, raw, "Content-Type: text/plain;").?;
    const related_at = std.mem.indexOf(u8, raw, "Content-Type: multipart/related;").?;
    const html_at = std.mem.indexOf(u8, raw, "Content-Type: text/html;").?;
    const image_at = std.mem.indexOf(u8, raw, "Content-Type: image/png").?;
    try std.testing.expect(plain_at < related_at and related_at < html_at and html_at < image_at);
    const decoded = try parse(raw, a);
    var cid_buffer: [128]u8 = undefined;
    const cid = try logoContentId(compose.message_id, &cid_buffer);
    const bound_html = try std.mem.replaceOwned(u8, a, rendered.html, "<img src=\"cid:omagma-logo@omagma.invalid\"", try std.fmt.allocPrint(a, "<img src=\"cid:{s}\"", .{cid}));
    try std.testing.expectEqualStrings(try std.mem.replaceOwned(u8, a, bound_html, "\n", "\r\n"), decoded.body_html);
    try std.testing.expect(std.mem.indexOf(u8, decoded.body_html, "cid:omagma-logo@omagma.invalid</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded.body_html, "&lt;img src=&quot;cid:omagma-logo@omagma.invalid&quot;&gt;") != null);
    try std.testing.expectEqualStrings(rendered.plain, std.mem.trimEnd(u8, decoded.body_text, "\r\n"));
    try std.testing.expectEqual(@as(usize, 17), decoded.attachments.len);
    try std.testing.expectEqualStrings(cid, std.mem.trim(u8, decoded.attachments[0].content_id, "<>"));
    try std.testing.expectEqualSlices(u8, markdown_logo.png, decoded.attachments[0].data);
    for (decoded.attachments[1..]) |file| try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0x80, '\r', '\n' }, file.data);
    var standalone = compose;
    standalone.attachments = &.{};
    const no_files = try encode(standalone, output);
    try std.testing.expect(std.mem.indexOf(u8, no_files, "multipart/mixed") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_files, "multipart/alternative") != null);
    var second_cid_buffer: [128]u8 = undefined;
    const other_cid = try logoContentId("<other-markdown@example.test>", &second_cid_buffer);
    try std.testing.expect(!std.mem.eql(u8, cid, other_cid));
}

test "ISO-8859-15 text converts its euro and other replaced code points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("5 € ŠšŽžŒœŸ äöü ß", try convertCharset("5 \xa4 \xa6\xa8\xb4\xb8\xbc\xbd\xbe \xe4\xf6\xfc \xdf", "ISO-8859-15", a));
    try std.testing.expectEqualStrings("5 ¤ ¦¨´¸¼½¾", try convertCharset("5 \xa4 \xa6\xa8\xb4\xb8\xbc\xbd\xbe", "iso-8859-1", a));
    try std.testing.expectError(error.UnsupportedCharset, convertCharset("x", "iso-8859-2", a));
    // An HTML-only Latin-9 message keeps its body and its named attachment.
    const message = try parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"multipart/mixed\",\"headers\":[],\"parts\":[" ++
        "{\"mimeType\":\"text/html\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/html; charset=\\\"iso-8859-15\\\"\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"8bit\"}],\"body\":{\"size\":10,\"data\":\"PHA-NSCkPC9wPg\"}}," ++
        "{\"mimeType\":\"application/octet-stream\",\"filename\":\"rechnung.pdf\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"attachment; filename=\\\"rechnung.pdf\\\"\"}],\"body\":{\"attachmentId\":\"latin9-attachment\",\"size\":4}}]}}"), a);
    try std.testing.expect(std.mem.indexOf(u8, message.body_text, "5 €") != null);
    try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
    try std.testing.expectEqualStrings("rechnung.pdf", message.attachments[0].filename);
}

test "literal MIME quoted printable charset and HTML text decode independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "From: \"Doe, Jane\" <jane@example.test>\r\nTo: self@example.test\r\nSubject: =?UTF-8?Q?Ol=C3=A1?=\r\nMessage-ID: <literal@example.test>\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCaf=E9\r\nline=\r\n two\r\n";
    const parsed = try parse(raw, a);
    try std.testing.expectEqualStrings("Olá", parsed.subject);
    try std.testing.expectEqualStrings("Café\nline two\n", parsed.body_text);
    try std.testing.expectEqualStrings("Doe, Jane", parsed.from[0].name);
    const rendered = try htmlToText("<p>Hello &amp; café</p><script>secret()</script><p><a href=\"https://example.test/x\">Link</a></p>", a);
    try std.testing.expectEqualStrings("Hello & café\nLink (https://example.test/x)", rendered);
    try std.testing.expectError(error.UnsupportedCharset, convertCharset("bytes", "unknown", a));
}

test "RFC message encoder has independent headers and body octet oracles" {
    var envelope_out: recipients.Envelope = .{};
    try recipients.parse("receiver@example.test", &envelope_out.to);
    var from: recipients.Mailbox = .{};
    try from.address.set("sender@example.test");
    var output: [4096]u8 = undefined;
    const raw = try encode(.{ .from = from, .envelope = &envelope_out, .subject = "Olá", .body = "Hello\n", .message_id = "<send@example.test>", .date = "Mon, 05 Oct 2026 12:00:00 +0000", .in_reply_to = "<original@example.test>", .references = "<first@example.test> <original@example.test>" }, &output);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Subject: =?UTF-8?B?T2zDoQ==?=\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "In-Reply-To: <original@example.test>\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "SGVsbG8NCg==\r\n"));
    try std.testing.expectError(error.HeaderInjection, encode(.{ .from = from, .envelope = &envelope_out, .subject = "x\r\nBcc: hidden@example.test", .body = "ok", .message_id = "<send@example.test>", .date = "date" }, &output));
}

test "Gmail full payload is decoded once and validates declared size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":\"id\",\"threadId\":\"thread\",\"internalDate\":\"42\",\"labelIds\":[\"UNREAD\"],\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=utf-8\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"quoted-printable\"}],\"body\":{\"size\":7,\"data\":\"eCA9M0QgeQ\"}}}", .{});
    const normalized = try normalizeGmail(input.value, a, null);
    try std.testing.expectEqualStrings("x =3D y", normalized.bodyText);
    try std.testing.expectEqual(@as(i64, 42), normalized.receivedAt);
    try std.testing.expect(normalized.unread);
    try std.testing.expectError(error.MissingMessageId, threading("", "", "", a));
}
test "Gmail metadata omits bodies and labels while encoded names keep comma grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":\"metadata-1\",\"threadId\":\"thread-1\",\"internalDate\":\"42\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"=?UTF-8?B?RG9lLCBKYW5l?=\\r\\n \\t<jane@example.org>\"},{\"name\":\"To\",\"value\":\"self@example.test\"}]}}", .{});
    const result = try normalizeGmail(input.value, a, null);
    try std.testing.expectEqualStrings("Doe, Jane", result.from.name);
    try std.testing.expectEqualStrings("jane@example.org", result.from.address);
    try std.testing.expectEqual(@as(usize, 1), result.to.len);
    try std.testing.expectEqual(@as(usize, 0), result.labels.len);
    try std.testing.expectEqualStrings("", result.bodyText);
    try std.testing.expectError(error.InvalidHeaders, unfoldHeader("safe@example.test\r\nBcc: hidden@example.test", a));
}
test "Gmail internal dates stay inside independently specified calendar endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":\"date-1\",\"threadId\":\"thread-1\",\"internalDate\":\"0\",\"payload\":{\"headers\":[]}}", .{});
    var value = input.value;
    const first = try normalizeGmail(value, a, null);
    try std.testing.expectEqual(@as(i64, 0), first.receivedAt);
    try value.object.put(a, "internalDate", .{ .string = "253402300799999" });
    const last = try normalizeGmail(value, a, null);
    try std.testing.expectEqual(@as(i64, 253402300799999), last.receivedAt);
    for ([_][]const u8{ "-1", "253402300800000", "9223372036854775807" }) |invalid| {
        try value.object.put(a, "internalDate", .{ .string = invalid });
        try std.testing.expectError(error.InvalidDate, normalizeGmail(value, a, null));
    }
}
test "compose attachments preserve independent binary octets and RFC2231 UTF8 filename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var from: recipients.Mailbox = .{};
    try from.address.set("self@example.test");
    var destinations: recipients.Envelope = .{};
    try recipients.parse("recipient@example.test", &destinations.to);
    const attachments = try composeAttachments(&.{.{ .id = "", .filename = "résumé.bin", .mimeType = "application/octet-stream", .size = 7, .data = "AAF_gP8NCg" }}, a);
    var output: [8192]u8 = undefined;
    const raw = try encode(.{ .from = from, .envelope = &destinations, .subject = "Binary fixture", .body = "Plain body", .html = "<p>HTML body</p>", .message_id = "<fixture@example.test>", .date = "Mon, 05 Oct 2026 12:00:00 +0000", .attachments = attachments }, &output);
    try std.testing.expect(std.mem.indexOf(u8, raw, "filename*0*=UTF-8''r%C3%A9sum%C3%A9.bin\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "AAF/gP8NCg==\r\n") != null);
    const parsed = try parse(raw, a);
    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    try std.testing.expectEqualStrings("résumé.bin", parsed.attachments[0].filename);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 127, 128, 255, 13, 10 }, parsed.attachments[0].data);
    try std.testing.expectEqualStrings("Plain body", parsed.body_text);
    try std.testing.expectEqualStrings("<p>HTML body</p>", parsed.body_html);
    try std.testing.expectError(error.InvalidAttachmentFilename, validateAttachment("../../escape.bin", "application/octet-stream"));
    try std.testing.expectError(error.InvalidMimeType, validateAttachment("safe.bin", "text/plain\r\nBcc: injected@example.test"));
    try std.testing.expectError(error.BodySizeMismatch, composeAttachments(&.{.{ .id = "", .filename = "safe.bin", .size = 8, .data = "AAF_gP8NCg" }}, a));
}
test "incoming MIME types reject header controls and parameters in Gmail bare media type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try validateMimeType("application/vnd.fixture+json");
    try std.testing.expectError(error.InvalidMimeType, validateMimeType("text/plain\x1b]52;payload"));
    const source = try std.json.parseFromSlice(std.json.Value, a, "{\"payload\":{\"mimeType\":\"text/plain; charset=utf-8\",\"body\":{\"size\":1,\"data\":\"eA\"}}}", .{});
    try std.testing.expectError(error.InvalidMimeType, parseGmail(source.value, a));
}
test "encoded address name overflow is explicit and does not truncate via bar display helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const latin: [129]u8 = @splat(0xe9);
    var encoded: [172]u8 = undefined;
    const word = std.base64.standard.Encoder.encode(&encoded, &latin);
    const raw = try std.fmt.allocPrint(a, "From: =?ISO-8859-1?B?{s}?= <sender@example.test>\r\nTo: self@example.test\r\nContent-Type: text/plain\r\n\r\nBody", .{word});
    try std.testing.expectError(error.CapacityExceeded, parse(raw, a));
}

test "inbound literal long local and 33 member MIME headers preserve all addresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@example.test";
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, "From: sender@example.test\r\nReply-To: " ++ long ++ "\r\nTo: ");
    for (0..33) |i| {
        if (i != 0) try raw.appendSlice(a, ", ");
        try raw.appendSlice(a, try std.fmt.allocPrint(a, "member{d}@example.test", .{i}));
    }
    try raw.appendSlice(a, "\r\n\r\nLiteral body");
    const parsed = try parse(raw.items, a);
    try std.testing.expectEqual(@as(usize, 33), parsed.to.len);
    try std.testing.expectEqualStrings("member32@example.test", parsed.to[32].address);
    try std.testing.expectEqualStrings(long, parsed.reply_to[0].address);
    try std.testing.expectEqualStrings("Literal body", parsed.body_text);
}
test "inbound name wire size is distinct from decoded display name bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const word = "=?UTF-8?Q?=C3=A9=C3=A9=C3=A9=C3=A9=C3=A9=C3=A9=C3=A9=C3=A9=C3=A9?=";
    const name = word ++ " " ++ word ++ " " ++ word ++ " " ++ word ++ " " ++ word;
    try std.testing.expect(name.len > 256);
    const raw = "From: " ++ name ++ " <sender@example.test>\r\nTo: Undisclosed:;\r\n\r\nHello";
    const parsed = try parse(raw, a);
    try std.testing.expectEqual(@as(usize, 90), parsed.from[0].name.len);
    try std.testing.expectEqualStrings("ééééééééééééééééééééééééééééééééééééééééééééé", parsed.from[0].name);
    try std.testing.expectEqual(@as(usize, 0), parsed.to.len);
}

test "malformed encoded words fall back to literal display text and keep addresses strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("=?UTF-8?B?%%%?= Rechnung", try displayHeader("=?UTF-8?B?%%%?= Rechnung", a));
    try std.testing.expectEqualStrings("=?x-unknown?Q?Bob?=", try displayHeader("=?x-unknown?Q?Bob?=", a));
    try std.testing.expectEqualStrings("=?UTF-8?Q?bad=ZZ.pdf?=", try displayHeader("=?UTF-8?Q?bad=ZZ.pdf?=", a));
    try std.testing.expectEqualStrings("=?UTF-8?Q?unterminated", try displayHeader("=?UTF-8?Q?unterminated", a));
    try std.testing.expectEqualStrings("=?UTF-8?B?/w?= x", try displayHeader("=?UTF-8?B?/w?= x", a));
    try std.testing.expectEqualStrings("a\u{FFFD}b", try displayHeader("a\xffb", a));
    try std.testing.expectEqualStrings("Grüße", try displayHeader("=?UTF-8?Q?Gr=C3=BC=C3=9Fe?=", a));
    var oversized: [8202]u8 = @splat('x');
    oversized[0] = '=';
    oversized[1] = '?';
    try std.testing.expectError(error.HeaderTooLarge, displayHeader(&oversized, a));

    const message = try parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"multipart/mixed\",\"headers\":[" ++
        "{\"name\":\"From\",\"value\":\"=?x-unknown?Q?Bob?= <bob@example.test>\"}," ++
        "{\"name\":\"To\",\"value\":\"=?UTF-8?B?%%%?= <self@example.test>\"}," ++
        "{\"name\":\"Subject\",\"value\":\"=?UTF-8?B?%%%?= Rechnung\"}]," ++
        "\"parts\":[{\"mimeType\":\"text/plain\",\"headers\":[],\"body\":{\"size\":3,\"data\":\"YWJj\"}}," ++
        "{\"mimeType\":\"application/pdf\",\"filename\":\"=?UTF-8?Q?bad=ZZ.pdf?=\",\"headers\":[],\"body\":{\"attachmentId\":\"literal-name\",\"size\":4}}]}}"), a);
    try std.testing.expectEqualStrings("=?UTF-8?B?%%%?= Rechnung", message.subject);
    try std.testing.expectEqualStrings("bob@example.test", message.from[0].address);
    try std.testing.expectEqualStrings("=?x-unknown?Q?Bob?=", message.from[0].name);
    try std.testing.expectEqualStrings("self@example.test", message.to[0].address);
    try std.testing.expectEqualStrings("abc", message.body_text);
    try std.testing.expectEqualStrings("=?UTF-8?Q?bad=ZZ.pdf?=", message.attachments[0].filename);
    // Address syntax and header injection remain refusals.
    const invalid = parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"From\",\"value\":\"=?UTF-8?B?%%%?= <not an address>\"}],\"body\":{\"size\":3,\"data\":\"YWJj\"}}}"), a);
    if (invalid) |_| return error.TestExpectedError else |err| try std.testing.expect(err != error.InvalidEncodedWord and err != error.InvalidBase64);
}

test "decoded incoming display names accept literal 256 bytes and reject 257" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const word = "=?UTF-8?Q?AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA?=";
    var name: std.ArrayList(u8) = .empty;
    for (0..8) |i| {
        if (i != 0) try name.append(a, ' ');
        try name.appendSlice(a, word);
    }
    const raw = try std.fmt.allocPrint(a, "From: {s} <sender@example.test>\r\n\r\nBody", .{name.items});
    const accepted = try parse(raw, a);
    try std.testing.expectEqual(@as(usize, 256), accepted.from[0].name.len);
    const expected: [256]u8 = @splat('A');
    try std.testing.expectEqualStrings(&expected, accepted.from[0].name);
    try name.appendSlice(a, " =?UTF-8?Q?A?=");
    const refused = try std.fmt.allocPrint(a, "From: {s} <sender@example.test>\r\n\r\nBody", .{name.items});
    try std.testing.expectError(error.CapacityExceeded, parse(refused, a));
}

test "incoming raw and Gmail headers accept routing-rich mail within fixed budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = try a.alloc(Header, 257);
    var raw: std.ArrayList(u8) = .empty;
    for (values, 0..) |*value, i| {
        value.* = .{ .name = try std.fmt.allocPrint(a, "X-Routing-{d}", .{i}), .value = "route" };
        try raw.appendSlice(a, try std.fmt.allocPrint(a, "{s}: route\r\n", .{value.name}));
        if (i == 64 or i == 255) {
            const mail = try std.fmt.allocPrint(a, "{s}\r\nBody", .{raw.items});
            try std.testing.expectEqual(i + 1, (try splitEntity(mail, a)).headers.len);
            const encoded = try std.json.Stringify.valueAlloc(a, .{ .headers = values[0 .. i + 1] }, .{});
            const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{ .allocate = .alloc_always });
            const headers = try gmailHeaders(payload, a);
            try std.testing.expectEqual(i + 1, headers.len);
            try std.testing.expectEqualStrings("route", headers[i].value);
        }
    }
    try std.testing.expectError(error.TooManyHeaders, splitEntity(try std.fmt.allocPrint(a, "{s}\r\nBody", .{raw.items}), a));
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .headers = values }, .{});
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{ .allocate = .alloc_always });
    try std.testing.expectError(error.TooManyHeaders, gmailHeaders(payload, a));

    const long = try a.alloc(u8, 8192);
    @memset(long, 'x');
    const large = try std.json.Stringify.valueAlloc(a, .{ .headers = [_]Header{
        .{ .name = "X-Route-A", .value = long },
        .{ .name = "X-Route-B", .value = long },
        .{ .name = "X-Route-C", .value = long },
        .{ .name = "X-Route-D", .value = long },
    } }, .{});
    const oversized = try std.json.parseFromSliceLeaky(std.json.Value, a, large, .{ .allocate = .alloc_always });
    try std.testing.expectError(error.HeadersTooLarge, gmailHeaders(oversized, a));
}

const GmailSizeOracle = struct {
    fn json(a: std.mem.Allocator, source: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, a, source, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    }
    fn wrap(a: std.mem.Allocator, payload: std.json.Value) !std.json.Value {
        var value: std.json.Value = .{ .object = .empty };
        try value.object.put(a, "payload", payload);
        return value;
    }
    fn part(a: std.mem.Allocator, kind: []const u8, size: i64, data: []const u8) !std.json.Value {
        var body: std.json.Value = .{ .object = .empty };
        try body.object.put(a, "size", .{ .integer = size });
        try body.object.put(a, "data", .{ .string = data });
        var value: std.json.Value = .{ .object = .empty };
        try value.object.put(a, "mimeType", .{ .string = kind });
        try value.object.put(a, "headers", .{ .array = .init(a) });
        try value.object.put(a, "body", body);
        return value;
    }
    fn children(a: std.mem.Allocator, parent: *std.json.Value, parts: []const std.json.Value) !void {
        var values = std.json.Array.init(a);
        try values.appendSlice(parts);
        try parent.object.put(a, "parts", .{ .array = values });
    }
    fn filled(a: std.mem.Allocator, bytes: usize) ![]const u8 {
        const raw = try a.alloc(u8, bytes);
        @memset(raw, 'x');
        const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes));
        return std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
    }
};

test "Gmail inline size underestimates preserve literal full HTML and plain text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var html = try GmailSizeOracle.json(a, "{\"id\":\"size-html\",\"threadId\":\"size-thread\",\"internalDate\":\"42\",\"payload\":{\"mimeType\":\"text/html\",\"headers\":[],\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}");
    const first = try normalizeGmail(html, a, null);
    try std.testing.expectEqualStrings("<p>X</p>", first.bodyHtml.?);
    try std.testing.expectEqualStrings("X", first.bodyText);
    var payload = try b.field(html, "payload");
    var body = try b.field(payload, "body");
    // Pin zero-size metadata with nonempty data and the valid empty-parts form.
    try body.object.put(a, "size", .{ .integer = 0 });
    try GmailSizeOracle.children(a, &payload, &.{});
    try html.object.put(a, "payload", payload);
    const zero = try normalizeGmail(html, a, null);
    try std.testing.expectEqualStrings("<p>X</p>", zero.bodyHtml.?);
    try std.testing.expectEqualStrings("X", zero.bodyText);
    const plain = try GmailSizeOracle.json(a, "{\"id\":\"size-plain\",\"threadId\":\"size-thread\",\"internalDate\":\"42\",\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"inline\"}],\"body\":{\"size\":7,\"data\":\"YWJjZGVmZ2g\"}}}");
    try std.testing.expectEqualStrings("abcdefgh", (try normalizeGmail(plain, a, null)).bodyText);
}

test "Gmail external attached calendar binary and container sizes remain exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const external = try GmailSizeOracle.json(a, "{\"external-fixture\":{\"size\":8,\"data\":\"PHA-WDwvcD4\"}}");
    const cases = [_][]const u8{
        "{\"payload\":{\"mimeType\":\"text/html\",\"filename\":\"fixture.html\",\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"text/html\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"attachment\"}],\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Disposition\",\"value\":\"ATTACHMENT; filename=fixture.txt\"}],\"body\":{\"size\":7,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":7,\"attachmentId\":\"external-fixture\"}}}",
        "{\"payload\":{\"mimeType\":\"text/calendar\",\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"application/octet-stream\",\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"multipart/mixed\",\"parts\":[],\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"text/html\",\"parts\":[{\"mimeType\":\"text/plain\",\"body\":{\"size\":0}}],\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}}}",
    };
    for (cases) |source| try std.testing.expectError(error.BodySizeMismatch, parseGmailExternal(try GmailSizeOracle.json(a, source), a, external));
    const mixed = try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"multipart/mixed\",\"body\":{\"size\":0},\"parts\":[{\"mimeType\":\"text/html\",\"body\":{\"size\":7,\"data\":\"PHA-WDwvcD4\"}},{\"partId\":\"attachment-part\",\"mimeType\":\"text/plain\",\"filename\":\"fixture.txt\",\"body\":{\"size\":8,\"data\":\"YWJjZGVmZ2g\"}}]}}");
    const parsed = try parseGmail(mixed, a);
    try std.testing.expectEqualStrings("<p>X</p>", parsed.body_html);
    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    try std.testing.expectEqualStrings("attachment-part", parsed.attachments[0].id);
    try std.testing.expectEqualStrings("fixture.txt", parsed.attachments[0].filename);
    try std.testing.expectEqual(@as(usize, 8), parsed.attachments[0].size);
    try std.testing.expectEqualStrings("abcdefgh", parsed.attachments[0].data);
}

test "Gmail inline shorter empty invalid and declared-over-budget data stays refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":9,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"body\":{\"size\":9,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":1,\"data\":\"\"}}}",
    }) |source| try std.testing.expectError(error.BodySizeMismatch, parseGmail(try GmailSizeOracle.json(a, source), a));
    for ([_][]const u8{
        "{\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":-1,\"data\":\"PHA-WDwvcD4\"}}}",
        "{\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":2097153,\"data\":\"PHA-WDwvcD4\"}}}",
    }) |source| try std.testing.expectError(error.BodyTooLarge, parseGmail(try GmailSizeOracle.json(a, source), a));
    for ([_][]const u8{
        "{\"payload\":{\"mimeType\":\"text/plain\",\"body\":{\"size\":0,\"data\":\"?invalid\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"body\":{\"size\":0,\"data\":\"YWJjZGVmZ2g===\"}}}",
    }) |source| try std.testing.expectError(error.InvalidBase64, parseGmail(try GmailSizeOracle.json(a, source), a));
    try std.testing.expectError(error.ExternalBodyRequired, parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":8,\"attachmentId\":\"external-fixture\"}}}"), a));
    const empty = try parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"text/plain\",\"body\":{\"size\":0,\"data\":\"\"}}}"), a);
    try std.testing.expectEqualStrings("", empty.body_text);
}

test "Gmail base64 UTF-8 inline text may lack exactly a stripped byte order mark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const utf8_base64 = "[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=\\\"UTF-8\\\"\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}]";
    // Gmail returns BOM-less "abcdefgh" (8 bytes) but declares the original 11.
    const plain = try parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}"), a);
    try std.testing.expectEqualStrings("abcdefgh", plain.body_text);
    const alternative = try parseGmail(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"multipart/alternative\",\"headers\":[],\"parts\":[" ++
        "{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}," ++
        "{\"mimeType\":\"text/html\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/html; charset=utf-8\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}],\"body\":{\"size\":11,\"data\":\"PHA-WDwvcD4\"}}]}}"), a);
    try std.testing.expectEqualStrings("abcdefgh", alternative.body_text);
    try std.testing.expect(std.mem.indexOf(u8, alternative.body_html, "<p>X</p>") != null);

    // Every other shape keeps the exact or not-shorter rule, including three
    // bytes short. Missing charset/encoding headers are not assumed.
    for ([_][]const u8{
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":10,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":12,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":14,\"data\":\"77u_YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=utf-8\"}],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=utf-8\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"quoted-printable\"}],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=iso-8859-1\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"filename\":\"notes.txt\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/plain; charset=utf-8\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"},{\"name\":\"Content-Disposition\",\"value\":\"attachment\"}],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"application/octet-stream\",\"filename\":\"data.bin\",\"headers\":[{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"text/calendar\",\"filename\":\"invite.ics\",\"headers\":[{\"name\":\"Content-Type\",\"value\":\"text/calendar; charset=utf-8\"},{\"name\":\"Content-Transfer-Encoding\",\"value\":\"base64\"}],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"}}}",
        "{\"payload\":{\"mimeType\":\"multipart/mixed\",\"headers\":[],\"body\":{\"size\":11,\"data\":\"YWJjZGVmZ2g\"},\"parts\":[{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":8,\"data\":\"YWJjZGVmZ2g\"}}]}}",
    }) |source| try std.testing.expectError(error.BodySizeMismatch, parseGmail(try GmailSizeOracle.json(a, source), a));
    // An external inline body uses the fetched attachment data with an exact size.
    const external = try GmailSizeOracle.json(a, "{\"external-fixture\":{\"size\":8,\"data\":\"YWJjZGVmZ2g\"}}");
    try std.testing.expectError(error.BodySizeMismatch, parseGmailExternal(try GmailSizeOracle.json(a, "{\"payload\":{\"mimeType\":\"text/plain\",\"headers\":" ++ utf8_base64 ++ ",\"body\":{\"size\":11,\"attachmentId\":\"external-fixture\"}}}"), a, external));
}

test "Actual Gmail decoded leaf and accumulated text caps ignore smaller metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const too_large = try GmailSizeOracle.part(a, "text/plain", 1, try GmailSizeOracle.filled(a, 2097153));
    try std.testing.expectError(error.BodyTooLarge, parseGmail(try GmailSizeOracle.wrap(a, too_large), a));
    const text = try GmailSizeOracle.filled(a, 1048576);
    const first = try GmailSizeOracle.part(a, "text/html", 0, text);
    const second = try GmailSizeOracle.part(a, "text/html", 0, text);
    var parent = try GmailSizeOracle.part(a, "multipart/alternative", 0, "");
    try GmailSizeOracle.children(a, &parent, &.{ first, second });
    // Two one-MiB HTML parts plus the inter-part newline exceed two MiB.
    try std.testing.expectError(error.BodyTooLarge, parseGmail(try GmailSizeOracle.wrap(a, parent), a));
    const external_data = try GmailSizeOracle.filled(a, 1572864);
    var external_part = try GmailSizeOracle.part(a, "text/plain", 1572864, "");
    var external_body = try b.field(external_part, "body");
    try external_body.object.put(a, "attachmentId", .{ .string = "external-caps" });
    try external_part.object.put(a, "body", external_body);
    const html = try GmailSizeOracle.part(a, "text/html", 1, try GmailSizeOracle.filled(a, 1572865));
    try GmailSizeOracle.children(a, &parent, &.{ external_part, html });
    var map: std.json.Value = .{ .object = .empty };
    var attachment_body: std.json.Value = .{ .object = .empty };
    try attachment_body.object.put(a, "data", .{ .string = external_data });
    try attachment_body.object.put(a, "size", .{ .integer = 1572864 });
    try map.object.put(a, "external-caps", attachment_body);
    // Individually valid plain/html leaves total 3,145,729 decoded bytes.
    try std.testing.expectError(error.DecodedMessageTooLarge, parseGmailExternal(try GmailSizeOracle.wrap(a, parent), a, map));
}

test "Raw MIME and outgoing attachment bytes retain their independent rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nYWJjZGVmZ2g=\r\n";
    try std.testing.expectEqualStrings("abcdefgh", (try parse(raw, a)).body_text);
    try std.testing.expectError(error.BodySizeMismatch, composeAttachments(&.{.{ .id = "", .filename = "fixture.txt", .size = 7, .data = "YWJjZGVmZ2g" }}, a));
}

test "invitation MIME: named Outlook Teams and Zoom calendar attachments are actionable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Fictional Outlook-shaped data, including quoted Windows timezone names
    // and a folded Teams description. The conferencing service is irrelevant
    // to the calendar transport.
    const calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:teams-fixture@example.test\r\nDTSTAMP:20261007T090000Z\r\nDTSTART;TZID=\"W. Europe Standard Time\":20261012T100000\r\nORGANIZER;CN=\"Fixture Host\":MAILTO:host@example.test\r\nATTENDEE;CN=\"Fixture Guest\";RSVP=TRUE:MAILTO:self@example.test\r\nDESCRIPTION:Join the fixture meeting at https://teams.microsoft.com/\r\n l/meetup-join/fictional\r\nSUMMARY:Calendar fixture\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    for ([_][]const u8{ "text/calendar", "application/ics", "application/octet-stream" }) |kind| {
        const raw = try std.fmt.allocPrint(a, "From: host@example.test\r\nTo: self@example.test\r\nContent-Type: {s}; charset=utf-8; method=REQUEST; name=\"invite.ics\"\r\nContent-Disposition: attachment; filename=\"invite.ics\"\r\n\r\n{s}", .{ kind, calendar });
        const message = try parse(raw, a);
        try std.testing.expect(message.calendar != null);
        try std.testing.expect(std.mem.indexOf(u8, message.calendar.?, "https://teams.microsoft.com/l/meetup-join/fictional") != null);
        try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
        try std.testing.expectEqualStrings("invite.ics", message.attachments[0].filename);
        // Download keeps the original wire bytes even though calendar
        // discovery unfolds logical lines for validation and JSON storage.
        try std.testing.expectEqualStrings(calendar, message.attachments[0].data);
    }
    const zoom = try parse("Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"ZOOM.ICS\"\r\n\r\nBEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:zoom-fixture@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nDESCRIPTION:https://example.zoom.us/j/00000000000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", a);
    try std.testing.expect(zoom.calendar != null);
}

test "invitation MIME: named Gmail external calendar payloads require and preserve downloaded bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:external-fixture@example.test\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:self@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(calendar.len));
    const data = std.base64.url_safe_no_pad.Encoder.encode(encoded, calendar);
    var map: std.json.Value = .{ .object = .empty };
    var download: std.json.Value = .{ .object = .empty };
    try download.object.put(a, "data", .{ .string = data });
    try map.object.put(a, "calendar-download", download);
    for ([_][]const u8{ "text/calendar", "application/ics", "application/octet-stream" }) |kind| {
        var part = try GmailSizeOracle.part(a, kind, @intCast(calendar.len), "");
        try part.object.put(a, "filename", .{ .string = "invite.ics" });
        var body = try b.field(part, "body");
        try body.object.put(a, "attachmentId", .{ .string = "calendar-download" });
        try part.object.put(a, "body", body);
        const message = try GmailSizeOracle.wrap(a, part);
        try std.testing.expectError(error.ExternalBodyRequired, parseGmail(message, a));
        const parsed = try parseGmailExternal(message, a, map);
        try std.testing.expectEqualStrings(calendar, parsed.calendar.?);
        try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
        try std.testing.expectEqualStrings("calendar-download", parsed.attachments[0].id);
        try std.testing.expectEqualStrings(calendar, parsed.attachments[0].data);
    }
}

test "invitation MIME: equivalent repeats are accepted but differing requests remain ambiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fixture@example.test\r\nSEQUENCE:3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const repeated = "BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:fixture@\n example.test\nSEQUENCE:3\nEND:VEVENT\nEND:VCALENDAR";
    const conflict = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fixture@example.test\r\nSEQUENCE:4\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const raw = try std.fmt.allocPrint(a, "Content-Type: multipart/mixed; boundary=\"calendar-repeat\"\r\n\r\n--calendar-repeat\r\nContent-Type: text/calendar; method=REQUEST\r\n\r\n{s}\r\n--calendar-repeat\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=invite.ics\r\n\r\n{s}\r\n--calendar-repeat--\r\n", .{ first, repeated });
    const parsed = try parse(raw, a);
    try std.testing.expect(parsed.calendar != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    const ambiguous = try std.fmt.allocPrint(a, "Content-Type: multipart/mixed; boundary=\"calendar-repeat\"\r\n\r\n--calendar-repeat\r\nContent-Type: text/calendar\r\n\r\n{s}\r\n--calendar-repeat\r\nContent-Type: text/calendar\r\n\r\n{s}\r\n--calendar-repeat--\r\n", .{ first, conflict });
    const conflicting = try parse(ambiguous, a);
    try std.testing.expect(conflicting.calendar == null);
    try std.testing.expect(conflicting.calendar_ambiguous);
    try std.testing.expect(!parsed.calendar_ambiguous);
}

test "invitation MIME: conflicting calendars keep the body and files but offer no invitation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fixture@example.test\r\nSEQUENCE:3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const update = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fixture@example.test\r\nSEQUENCE:4\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    // Outlook shape: inline calendar alternative, a named .ics attachment that
    // disagrees with it, and an ordinary document.
    const raw = try std.fmt.allocPrint(a, "From: organizer@example.test\r\nSubject: Planning\r\nContent-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n" ++
        "--outer\r\nContent-Type: multipart/alternative; boundary=\"alt\"\r\n\r\n" ++
        "--alt\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nAgenda attached.\r\n" ++
        "--alt\r\nContent-Type: text/calendar; charset=utf-8; method=REQUEST\r\n\r\n{s}\r\n--alt--\r\n" ++
        "--outer\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=invite.ics\r\n\r\n{s}\r\n" ++
        "--outer\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=agenda.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERi0=\r\n--outer--\r\n", .{ request, update });
    const parsed = try parse(raw, a);
    try std.testing.expect(parsed.calendar == null);
    try std.testing.expect(parsed.calendar_ambiguous);
    try std.testing.expectEqualStrings("Agenda attached.", parsed.body_text);
    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expectEqualStrings("invite.ics", parsed.attachments[0].filename);
    try std.testing.expectEqualStrings(update, parsed.attachments[0].data);
    try std.testing.expectEqualStrings("agenda.pdf", parsed.attachments[1].filename);
    // A later repeat of the first request does not resolve the conflict.
    const repeated = try std.fmt.allocPrint(a, "Content-Type: multipart/mixed; boundary=\"r\"\r\n\r\n--r\r\nContent-Type: text/calendar\r\n\r\n{s}\r\n--r\r\nContent-Type: text/calendar\r\n\r\n{s}\r\n--r\r\nContent-Type: text/calendar\r\n\r\n{s}\r\n--r--\r\n", .{ request, update, request });
    try std.testing.expect((try parse(repeated, a)).calendar == null);
}

test "invitation MIME: calendar folds may divide UTF8 but ordinary attachments and HTML cannot fabricate RSVP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const divided = "Content-Type: text/calendar; charset=utf-8\r\n\r\nBEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:utf8-fixture@example.test\r\nSUMMARY:Caf\xc3\r\n \xa9\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const parsed = try parse(divided, a);
    try std.testing.expect(std.mem.indexOf(u8, parsed.calendar.?, "SUMMARY:Café\r\n") != null);
    const malformed = try parse("Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=invite.ics\r\n\r\n<html>https://example.zoom.us/j/00000000000</html>", a);
    try std.testing.expect(malformed.calendar == null);
    try std.testing.expectEqual(@as(usize, 1), malformed.attachments.len);
    const binary = try parse("Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=invite.ics\r\n\r\n\xff\x00", a);
    try std.testing.expect(binary.calendar == null);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0 }, binary.attachments[0].data);
    const link = try parse("Content-Type: text/html; charset=utf-8\r\n\r\n<p>Join Zoom Meeting</p><a href=\"https://example.zoom.us/j/00000000000\">Join</a>", a);
    try std.testing.expect(link.calendar == null);
    try std.testing.expect(!isCalendarPart("application/octet-stream", "notes.txt"));
    try std.testing.expect(!isCalendarPart("text/html", "invite.ics"));
    const oversized = try GmailSizeOracle.part(a, "text/calendar", 131073, "");
    try std.testing.expectError(error.CalendarTooLarge, parseGmail(try GmailSizeOracle.wrap(a, oversized), a));
}

test "MIME charset: numeric German and Windows punctuation bytes obey explicit declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Independent byte oracles avoid an encode/decode round trip and retain
    // explicit Latin/Windows declarations even when the octets resemble UTF8.
    try std.testing.expectEqualStrings("öüäß", try convertCharset(&.{ 0xf6, 0xfc, 0xe4, 0xdf }, "ISO-8859-1", a));
    try std.testing.expectEqualStrings("€ ‘–’", try convertCharset(&.{ 0x80, 0x20, 0x91, 0x96, 0x92 }, "windows-1252", a));
    try std.testing.expectEqualStrings("öü", try convertCharset(&.{ 0xc3, 0xb6, 0xc3, 0xbc }, "UTF-8", a));
    try std.testing.expectEqualStrings("Ã¶Ã¼", try convertCharset(&.{ 0xc3, 0xb6, 0xc3, 0xbc }, "ISO-8859-1", a));
    const declared = try parse("Content-Type: text/plain; charset = \"ISO-8859-1\"\r\n\r\nBen\xf6tigen f\xfcr", a);
    try std.testing.expectEqualStrings("Benötigen für", declared.body_text);
    try std.testing.expectEqualStrings("utf-8", parameter("text/calendar; charset = \"utf-8\"; method = \"REQUEST\"", "charset").?);
    try std.testing.expectEqualStrings("REQUEST", parameter("text/calendar; charset = \"utf-8\"; method = \"REQUEST\"", "method").?);
}

test "body provenance preserves plain preference and the legacy HTML text fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = try parse("Content-Type: text/html; charset=utf-8\r\n\r\n<p>Literal HTML</p>", a);
    try std.testing.expectEqual(types.BodySource.html, html.body_source);
    try std.testing.expectEqualStrings("Literal HTML", html.body_text);
    const both = try parse("Content-Type: multipart/alternative; boundary=fixture\r\n\r\n--fixture\r\nContent-Type: text/plain\r\n\r\nLiteral plain\r\n--fixture\r\nContent-Type: text/html\r\n\r\n<p>Literal HTML</p>\r\n--fixture--\r\n", a);
    try std.testing.expectEqual(types.BodySource.plain, both.body_source);
    try std.testing.expectEqualStrings("Literal plain", both.body_text);
    try std.testing.expectEqualStrings("<p>Literal HTML</p>", both.body_html);
    const full = try GmailSizeOracle.json(a, "{\"id\":\"source-html\",\"threadId\":\"source-thread\",\"internalDate\":\"42\",\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"size\":8,\"data\":\"PHA-WDwvcD4\"}}}");
    const normalized = try normalizeGmail(full, a, null);
    try std.testing.expectEqual(types.BodySource.html, normalized.bodySource);
    try std.testing.expectEqualStrings("X", normalized.bodyText);
    try std.testing.expectEqualStrings("<p>X</p>", normalized.bodyHtml.?);
    const legacy = try std.json.parseFromSliceLeaky(types.Message, a, "{\"id\":\"legacy\",\"threadId\":\"thread\",\"bodyText\":\"Literal old body\"}", .{});
    try std.testing.expectEqual(types.BodySource.unknown, legacy.bodySource);
}

test "HTML reader fallback keeps legacy literal escaped technical fragments byte compatible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = "<p>Use &lt;span class=&quot;sample&quot;&gt; and x &lt; y &amp;&amp; y &gt; z.</p><pre>std::vector&lt;T&gt;\n&lt;script&gt;literal&lt;/script&gt;</pre>";
    try std.testing.expectEqualStrings("Use <span class=\"sample\"> and x < y && y > z.\nstd::vector<T>\n<script>literal</script>", try htmlToText(html, a));
    const plain = try parse("Content-Type: text/plain; charset=utf-8\r\n\r\n<div>Literal technical body</div>", a);
    try std.testing.expectEqual(types.BodySource.plain, plain.body_source);
    try std.testing.expectEqualStrings("<div>Literal technical body</div>", plain.body_text);
    try std.testing.expectEqualStrings("", plain.body_html);
}
