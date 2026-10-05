const std = @import("std");
const b = @import("../bounded.zig");
const recipients = @import("recipients.zig");
const types = @import("types.zig");

pub const max_raw_bytes = types.Limits.request_bytes;
pub const max_body_bytes = types.Limits.body_bytes;
pub const max_headers_bytes = 32 * 1024;
pub const max_parts = 128;
pub const max_depth = 16;
pub const max_attachments = 32;
/// Last millisecond of year 9999, within the terminal timestamp formatter's range.
pub const max_received_at_ms: i64 = 253402300799999;
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Attachment = struct { id: []const u8 = "", filename: []const u8, mime_type: []const u8, content_id: []const u8 = "", size: usize = 0, data: []const u8 };
pub const ParsedMessage = struct {
    headers: []const Header = &.{},
    from: []const recipients.Mailbox = &.{},
    to: []const recipients.Mailbox = &.{},
    cc: []const recipients.Mailbox = &.{},
    bcc: []const recipients.Mailbox = &.{},
    reply_to: []const recipients.Mailbox = &.{},
    subject: []const u8 = "",
    date: []const u8 = "",
    message_id: []const u8 = "",
    in_reply_to: []const u8 = "",
    references: []const u8 = "",
    body_text: []const u8 = "",
    body_html: []const u8 = "",
    calendar: ?[]const u8 = null,
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
        };
    }
    return .{
        .id = try allocator.dupe(u8, id),
        .threadId = try allocator.dupe(u8, thread),
        .from = if (parsed.from.len == 1) .{ .address = try allocator.dupe(u8, parsed.from[0].address.slice()), .name = try allocator.dupe(u8, parsed.from[0].name.slice()) } else .{ .address = "" },
        .replyTo = try dtoAddresses(parsed.reply_to, allocator),
        .to = try dtoAddresses(parsed.to, allocator),
        .cc = try dtoAddresses(parsed.cc, allocator),
        .subject = parsed.subject,
        .snippet = try sanitizeText(if (b.optional(value, "snippet")) |v| try b.string(v) else "", allocator),
        .bodyText = parsed.body_text,
        .bodyHtml = if (parsed.body_html.len == 0) null else parsed.body_html,
        .messageId = parsed.message_id,
        .references = parsed.references,
        .inReplyTo = parsed.in_reply_to,
        .labels = labels,
        .receivedAt = received,
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
fn dtoAddresses(source: []const recipients.Mailbox, allocator: std.mem.Allocator) ![]const types.Address {
    const out = try allocator.alloc(types.Address, source.len);
    for (source, out) |*item, *dest| dest.* = .{ .address = try allocator.dupe(u8, item.address.slice()), .name = try allocator.dupe(u8, item.name.slice()) };
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
        if (list.items.len == 64) return error.TooManyHeaders;
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

fn gmailHeaders(payload: std.json.Value, allocator: std.mem.Allocator) ![]const Header {
    const field = b.optional(payload, "headers") orelse return &.{};
    if (field != .array or field.array.items.len > 64) return error.TooManyHeaders;
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

fn addressList(raw: []const u8, allocator: std.mem.Allocator) ![]const recipients.Mailbox {
    var list: recipients.List = .{};
    try recipients.parse(raw, &list);
    for (list.items[0..list.count]) |*mailbox| try mailbox.name.set(try decodeHeader(mailbox.name.slice(), allocator));
    return try allocator.dupe(recipients.Mailbox, list.slice());
}
fn envelope(headers: []const Header, allocator: std.mem.Allocator) !ParsedMessage {
    return .{
        .headers = headers,
        .from = try addressList(try header(headers, "From"), allocator),
        .to = try addressList(try header(headers, "To"), allocator),
        .cc = try addressList(try header(headers, "Cc"), allocator),
        .bcc = try addressList(try header(headers, "Bcc"), allocator),
        .reply_to = try addressList(try header(headers, "Reply-To"), allocator),
        .subject = try decodeHeader(try header(headers, "Subject"), allocator),
        .date = try allocator.dupe(u8, try header(headers, "Date")),
        .message_id = try allocator.dupe(u8, try header(headers, "Message-ID")),
        .in_reply_to = try allocator.dupe(u8, try header(headers, "In-Reply-To")),
        .references = try allocator.dupe(u8, try header(headers, "References")),
    };
}

const Context = struct {
    allocator: std.mem.Allocator,
    parts: usize = 0,
    decoded: usize = 0,
    plain: std.ArrayList(u8) = .empty,
    html: std.ArrayList(u8) = .empty,
    calendar: ?[]const u8 = null,
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
        const disposition = try header(headers, "Content-Disposition");
        const attached = filename.len > 0 or std.ascii.startsWithIgnoreCase(disposition, "attachment");
        if (std.ascii.eqlIgnoreCase(mime_type, "text/calendar")) {
            if (self.calendar != null) return error.AmbiguousCalendarPart;
            self.calendar = try convertCharset(data, parameter(try header(headers, "Content-Type"), "charset") orelse "utf-8", self.allocator);
        }
        if (attached or (!std.ascii.eqlIgnoreCase(mime_type, "text/plain") and !std.ascii.eqlIgnoreCase(mime_type, "text/html") and !std.ascii.eqlIgnoreCase(mime_type, "text/calendar"))) {
            if (self.attachments.items.len == max_attachments) return error.TooManyAttachments;
            try self.attachments.append(self.allocator, .{ .filename = try decodeHeader(filename, self.allocator), .mime_type = try self.allocator.dupe(u8, mime_type), .content_id = try self.allocator.dupe(u8, try header(headers, "Content-ID")), .size = data.len, .data = data });
        }
        if (attached) return;
        if (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "text/html")) {
            const text = try convertCharset(data, parameter(try header(headers, "Content-Type"), "charset") orelse "utf-8", self.allocator);
            const target = if (std.ascii.eqlIgnoreCase(mime_type, "text/plain")) &self.plain else &self.html;
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
                            const part = std.mem.trimEnd(u8, entity.body[begin..offset], "\r\n");
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
        if (b.optional(part, "parts")) |children| {
            if (children != .array or children.array.items.len > max_parts) return error.TooManyMimeParts;
            for (children.array.items) |child| try self.gmailPart(child, depth + 1);
        }
        const body = b.optional(part, "body") orelse return;
        const declared = if (b.optional(body, "size")) |v| try b.integer(v) else 0;
        if (declared < 0 or declared > max_body_bytes) return error.BodyTooLarge;
        const filename = if (b.optional(part, "filename")) |v| try b.string(v) else "";
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
                if (external_data == null) {
                    if (filename.len == 0 and (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "text/html") or std.ascii.eqlIgnoreCase(mime_type, "text/calendar"))) return error.ExternalBodyRequired;
                    if (self.attachments.items.len == max_attachments) return error.TooManyAttachments;
                    try self.attachments.append(self.allocator, .{ .id = try self.allocator.dupe(u8, text), .filename = try decodeHeader(filename, self.allocator), .mime_type = try self.allocator.dupe(u8, mime_type), .size = @intCast(declared), .data = "" });
                    return;
                }
            }
        }
        const data = external_data orelse if (b.optional(body, "data")) |v| try b.string(v) else "";
        if (data.len == 0) {
            if (declared != 0) return error.BodySizeMismatch;
            return;
        }
        const decoded = try decodeBase64Url(data, self.allocator);
        if (b.optional(body, "size") != null and @as(usize, @intCast(declared)) != decoded.len) return error.BodySizeMismatch;
        try self.accountBytes(decoded.len);
        const old_count = self.attachments.items.len;
        try self.add(headers, mime_type, filename, decoded);
        if (self.attachments.items.len > old_count) self.attachments.items[old_count].id = try self.allocator.dupe(u8, external_id orelse part_id);
    }
    fn finish(self: *Context, result: *ParsedMessage) !void {
        result.body_html = try self.html.toOwnedSlice(self.allocator);
        const source = if (self.plain.items.len > 0) try self.plain.toOwnedSlice(self.allocator) else try htmlToText(result.body_html, self.allocator);
        result.body_text = try sanitizeText(source, self.allocator);
        result.calendar = self.calendar;
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
    if (!latin and !windows) return error.UnsupportedCharset;
    const table = [_]u21{ 0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178 };
    var output: std.ArrayList(u8) = .empty;
    for (data) |c| {
        const cp: u21 = if (windows and c >= 128 and c < 160) table[c - 128] else c;
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

pub fn sanitizeText(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    if (input.len > max_body_bytes) return error.BodyTooLarge;
    var output: std.ArrayList(u8) = .empty;
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
    calendar: ?[]const u8 = null,
    message_id: []const u8,
    date: []const u8,
    in_reply_to: []const u8 = "",
    references: []const u8 = "",
    attachments: []const Attachment = &.{},
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
    var chunk: [57]u8 = undefined;
    var used: usize = 0;
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
    if (input.len > 16) return error.TooManyAttachments;
    const attachments = try a.alloc(Attachment, input.len);
    var total: usize = 0;
    for (input, attachments) |item, *dest| {
        try validateAttachment(item.filename, item.mimeType);
        const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(std.mem.trimEnd(u8, item.data, "=")) catch return error.InvalidBase64;
        if (decoded_size > max_body_bytes - total) return error.AttachmentsTooLarge;
        if (item.size != decoded_size) return error.BodySizeMismatch;
        const data = try decodeBase64Url(item.data, a);
        total += data.len;
        dest.* = .{ .filename = item.filename, .mime_type = item.mimeType, .size = data.len, .data = data };
    }
    return attachments;
}
fn attachmentPart(writer: *std.Io.Writer, attachment: Attachment) !void {
    try writer.print("Content-Type: {s}\r\nContent-Disposition: attachment;\r\n filename*0*=UTF-8''", .{attachment.mime_type});
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
    try writer.writeAll("\r\nContent-Transfer-Encoding: base64\r\n\r\n");
    var offset: usize = 0;
    while (offset < attachment.data.len) {
        const end = @min(offset + 57, attachment.data.len);
        try emitBase64Line(writer, attachment.data[offset..end]);
        offset = end;
    }
}

pub fn encode(compose: Compose, out: []u8) ![]const u8 {
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
    if (compose.attachments.len > 16) return error.TooManyAttachments;
    var attachment_bytes: usize = 0;
    for (compose.attachments) |attachment| {
        try validateAttachment(attachment.filename, attachment.mime_type);
        if (attachment.data.len > max_body_bytes - attachment_bytes) return error.AttachmentsTooLarge;
        attachment_bytes += attachment.data.len;
        if (attachment.size != 0 and attachment.size != attachment.data.len) return error.BodySizeMismatch;
    }
    var writer = std.Io.Writer.fixed(out);
    try writer.writeAll("From: ");
    try writeMailbox(&writer, &compose.from);
    try writer.writeAll("\r\n");
    try writeAddressHeader(&writer, "To", &compose.envelope.to);
    try writeAddressHeader(&writer, "Cc", &compose.envelope.cc);
    try writeAddressHeader(&writer, "Bcc", &compose.envelope.bcc);
    try writer.writeAll("Subject: ");
    try encodedWords(&writer, compose.subject);
    try writer.print("\r\nDate: {s}\r\nMessage-ID: {s}\r\nMIME-Version: 1.0\r\n", .{ compose.date, compose.message_id });
    if (compose.in_reply_to.len > 0) try writer.print("In-Reply-To: {s}\r\n", .{compose.in_reply_to});
    try writeReferences(&writer, compose.references);
    if (compose.html != null or compose.calendar != null or compose.attachments.len > 0) {
        const mixed = compose.calendar != null or compose.attachments.len > 0;
        try writer.print("Content-Type: multipart/{s}; boundary=\"omagma-v1-part\"\r\n\r\n--omagma-v1-part\r\n", .{if (mixed) @as([]const u8, "mixed") else "alternative"});
        if (compose.html != null and mixed) {
            try writer.writeAll("Content-Type: multipart/alternative; boundary=\"omagma-v1-alt\"\r\n\r\n--omagma-v1-alt\r\n");
            try textPart(&writer, "text/plain", compose.body);
            try writer.writeAll("--omagma-v1-alt\r\n");
            try textPart(&writer, "text/html", compose.html.?);
            try writer.writeAll("--omagma-v1-alt--\r\n");
        } else try textPart(&writer, "text/plain", compose.body);
        if (compose.calendar) |ics| {
            try writer.writeAll("--omagma-v1-part\r\n");
            try textPart(&writer, "text/calendar; method=REPLY", ics);
        } else if (compose.html != null and !mixed) {
            try writer.writeAll("--omagma-v1-part\r\n");
            try textPart(&writer, "text/html", compose.html.?);
        }
        for (compose.attachments) |attachment| {
            try writer.writeAll("--omagma-v1-part\r\n");
            try attachmentPart(&writer, attachment);
        }
        try writer.writeAll("--omagma-v1-part--\r\n");
    } else try textPart(&writer, "text/plain", compose.body);
    return writer.buffered();
}

pub fn base64Url(raw: []const u8, out: []u8) ![]const u8 {
    if (raw.len > max_raw_bytes) return error.MessageTooLarge;
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    if (size > out.len) return error.OutputTooSmall;
    return std.base64.url_safe_no_pad.Encoder.encode(out, raw);
}

test "literal MIME quoted printable charset and HTML text decode independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "From: \"Doe, Jane\" <jane@example.test>\r\nTo: self@example.test\r\nSubject: =?UTF-8?Q?Ol=C3=A1?=\r\nMessage-ID: <literal@example.test>\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCaf=E9\r\nline=\r\n two\r\n";
    const parsed = try parse(raw, a);
    try std.testing.expectEqualStrings("Olá", parsed.subject);
    try std.testing.expectEqualStrings("Café\nline two\n", parsed.body_text);
    try std.testing.expectEqualStrings("Doe, Jane", parsed.from[0].name.slice());
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
