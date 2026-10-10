const std = @import("std");
const b = @import("../bounded.zig");

pub const max_recipients = 32;
pub const max_incoming_recipients = 1024;
/// Inbound names are decoded by MIME after mailbox grammar is parsed. Slices
/// are caller-owned heap storage; incoming lists never enlarge outgoing stacks.
pub const IncomingMailbox = struct { address: []const u8, name: []const u8 };
pub const Mailbox = struct { address: b.Text(254) = .{}, name: b.Text(256) = .{} };
pub const List = struct {
    items: [max_recipients]Mailbox = @splat(.{}),
    count: u8 = 0,
    pub fn slice(self: *const List) []const Mailbox {
        return self.items[0..self.count];
    }
    pub fn contains(self: *const List, address: []const u8) bool {
        for (self.slice()) |*item| if (std.ascii.eqlIgnoreCase(item.address.slice(), address)) return true;
        return false;
    }
    pub fn append(self: *List, item: Mailbox) !void {
        try validateAddress(item.address.slice());
        try validateHeader(item.name.slice());
        if (self.contains(item.address.slice())) return;
        if (self.count == max_recipients) return error.TooManyRecipients;
        self.items[self.count] = item;
        self.count += 1;
    }
};
pub const Envelope = struct { to: List = .{}, cc: List = .{}, bcc: List = .{} };

pub fn validateHeader(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    for (value) |c| if (c < 32 or c == 127) return error.HeaderInjection;
}

/// Human-editable RFC mailbox form. MIME serialization performs any wire
/// encoding later; quoting here protects commas, comments and angle brackets
/// while keeping Unicode display names intact through the composer parser.
pub fn formatDisplay(allocator: std.mem.Allocator, address: []const u8, name: []const u8) ![]u8 {
    try validateAddress(address);
    return formatDisplayName(allocator, address, name);
}

/// Preserve received display names before reply selection. Incoming addresses
/// have different size bounds; only selected outgoing recipients use SMTP
/// validation in addIncomingExternal.
pub fn formatIncomingDisplay(allocator: std.mem.Allocator, address: []const u8, name: []const u8) ![]u8 {
    try validateAddressSyntax(address, true);
    return formatDisplayName(allocator, address, name);
}

fn formatDisplayName(allocator: std.mem.Allocator, address: []const u8, name: []const u8) ![]u8 {
    try validateHeader(name);
    if (name.len > 256) return error.RecipientTooLarge;
    if (std.mem.trim(u8, name, " ").len == 0) return allocator.dupe(u8, address);
    var quoted = name[0] == ' ' or name[name.len - 1] == ' ';
    var extra: usize = 0;
    for (name) |byte| {
        if (std.mem.indexOfScalar(u8, "()<>[]:;@\\,.\"", byte) != null) quoted = true;
        if (byte == '\\' or byte == '"') extra += 1;
    }
    if (!quoted) return std.fmt.allocPrint(allocator, "{s} <{s}>", .{ name, address });
    const result = try allocator.alloc(u8, name.len + extra + address.len + 5);
    var writer: std.Io.Writer = .fixed(result);
    try writer.writeByte('"');
    for (name) |byte| {
        if (byte == '\\' or byte == '"') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.print("\" <{s}>", .{address});
    return result;
}

/// ASCII addr-spec, including quoted local parts and address literals. SMTPUTF8
/// mailboxes are rejected explicitly; UTF-8 display names are supported.
pub fn validateAddress(address: []const u8) !void {
    return validateAddressSyntax(address, false);
}
/// RFC 5322 address headers do not impose SMTP's 64-octet local-part limit.
/// Retain the 254-byte address bound and all syntax/injection checks. Only an
/// explicit conversion to an outgoing Mailbox applies the SMTP local limit.
fn validateAddressSyntax(address: []const u8, incoming: bool) !void {
    if (address.len == 0 or address.len > 254) return error.InvalidAddress;
    var quote = false;
    var escape = false;
    var at: ?usize = null;
    for (address, 0..) |c, i| {
        if (c < 32 or c >= 127) return error.InvalidAddress;
        if (escape) {
            escape = false;
            continue;
        }
        if (quote and c == '\\') {
            escape = true;
            continue;
        }
        if (c == '"') quote = !quote else if (c == '@' and !quote) {
            if (at != null) return error.InvalidAddress;
            at = i;
        }
    }
    if (quote or escape) return error.InvalidAddress;
    const split = at orelse return error.InvalidAddress;
    const local = address[0..split];
    const domain = address[split + 1 ..];
    if (local.len == 0 or (!incoming and local.len > 64) or domain.len == 0) return error.InvalidAddress;
    if (local[0] == '"') {
        if (local.len < 2 or local[local.len - 1] != '"') return error.InvalidAddress;
        var escaped = false;
        for (local[1 .. local.len - 1]) |c| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') escaped = true else if (c == '"') return error.InvalidAddress;
        }
        if (escaped) return error.InvalidAddress;
    } else {
        if (local[0] == '.' or local[local.len - 1] == '.') return error.InvalidAddress;
        var dot = false;
        for (local) |c| {
            if (c == '.') {
                if (dot) return error.InvalidAddress;
                dot = true;
            } else {
                if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-/=?^_`{|}~", c) == null) return error.InvalidAddress;
                dot = false;
            }
        }
    }
    if (domain[0] == '[') {
        if (domain.len < 3 or domain[domain.len - 1] != ']') return error.InvalidAddress;
        for (domain[1 .. domain.len - 1]) |c| if (!std.ascii.isAlphanumeric(c) and c != ':' and c != '.') return error.InvalidAddress;
    } else {
        var labels = std.mem.splitScalar(u8, domain, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidAddress;
            for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidAddress;
        }
    }
}

/// Parses commas outside quoted phrases, comments, angle brackets and groups.
/// No truncation or lossy recipient fallback is permitted.
pub fn parse(raw: []const u8, out: *List) !void {
    out.* = .{};
    var sink: OutgoingSink = .{ .out = out };
    try scan(raw, &sink);
}
const OutgoingSink = struct {
    out: *List,
    fn appendToken(self: *OutgoingSink, raw: []const u8) !void {
        try self.out.append(try mailbox(raw));
    }
};
const IncomingSink = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(IncomingMailbox) = .empty,
    fn appendToken(self: *IncomingSink, raw: []const u8) !void {
        if (self.list.items.len == max_incoming_recipients) return error.TooManyIncomingRecipients;
        const item = try incomingMailbox(raw, self.allocator);
        errdefer {
            self.allocator.free(item.address);
            self.allocator.free(item.name);
        }
        try self.list.append(self.allocator, item);
    }
};
pub fn deinitIncoming(items: []const IncomingMailbox, allocator: std.mem.Allocator) void {
    for (items) |item| {
        allocator.free(item.address);
        allocator.free(item.name);
    }
    allocator.free(items);
}
pub fn parseIncoming(raw: []const u8, allocator: std.mem.Allocator) ![]IncomingMailbox {
    var sink: IncomingSink = .{ .allocator = allocator };
    errdefer {
        for (sink.list.items) |item| {
            allocator.free(item.address);
            allocator.free(item.name);
        }
        sink.list.deinit(allocator);
    }
    try scan(raw, &sink);
    return try sink.list.toOwnedSlice(allocator);
}
fn scan(raw: []const u8, out: anytype) !void {
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
    for (raw) |c| if ((c < 32 and c != '\t') or c == 127) return error.HeaderInjection;
    if (raw.len > 16 * 1024) return error.RecipientHeaderTooLarge;
    var quote = false;
    var escape = false;
    var comment: usize = 0;
    var angle = false;
    var group = false;
    var literal = false;
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        if (escape) {
            escape = false;
            continue;
        }
        if ((quote or comment > 0) and c == '\\') {
            escape = true;
            continue;
        }
        if (comment > 0) {
            if (c == '(') {
                comment += 1;
                if (comment > 8) return error.InvalidRecipients;
            } else if (c == ')') comment -= 1;
            continue;
        }
        if (c == '"') {
            quote = !quote;
            continue;
        }
        if (quote) continue;
        if (literal and c != ']') continue;
        switch (c) {
            '[' => {
                if (literal) return error.InvalidRecipients;
                literal = true;
            },
            ']' => {
                if (!literal) return error.InvalidRecipients;
                literal = false;
            },
            '(' => comment = 1,
            ')' => return error.InvalidRecipients,
            '<' => {
                if (angle) return error.InvalidRecipients;
                angle = true;
            },
            '>' => {
                if (!angle) return error.InvalidRecipients;
                angle = false;
            },
            ':' => if (!angle) {
                if (group or std.mem.indexOfScalar(u8, raw[start..i], '@') != null) return error.InvalidRecipients;
                group = true;
                start = i + 1;
            },
            ',', ';' => if (!angle) {
                if (c == ';' and !group) return error.InvalidRecipients;
                const token = std.mem.trim(u8, raw[start..i], " \t");
                if (token.len != 0) try out.appendToken(token) else if (c == ',') {
                    const previous = std.mem.trimEnd(u8, raw[0..start], " \t");
                    if (previous.len == 0 or previous[previous.len - 1] != ';') return error.InvalidRecipients;
                }
                start = i + 1;
                if (c == ';') group = false;
            },
            else => {},
        }
    }
    if (quote or escape or comment != 0 or angle or group or literal) return error.InvalidRecipients;
    const last = std.mem.trim(u8, raw[start..], " \t");
    if (last.len > 0) try out.appendToken(last) else if (raw.len > 0 and raw[raw.len - 1] == ',') return error.InvalidRecipients;
}

fn mailbox(raw: []const u8) !Mailbox {
    var clean: [2048]u8 = undefined;
    var used: usize = 0;
    var depth: usize = 0;
    var quote = false;
    var escape = false;
    for (raw) |c| {
        if (escape) {
            if (depth == 0) {
                if (used == clean.len) return error.RecipientTooLarge;
                clean[used] = c;
                used += 1;
            }
            escape = false;
            continue;
        }
        if (c == '\\' and (quote or depth > 0)) {
            escape = true;
            if (depth == 0) {
                if (used == clean.len) return error.RecipientTooLarge;
                clean[used] = c;
                used += 1;
            }
            continue;
        }
        if (depth > 0) {
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
            continue;
        }
        if (!quote and c == '(') {
            depth = 1;
            continue;
        }
        if (c == '"') quote = !quote;
        if (used == clean.len) return error.RecipientTooLarge;
        clean[used] = if (c == '\t') ' ' else c;
        used += 1;
    }
    const token = std.mem.trim(u8, clean[0..used], " ");
    var out: Mailbox = .{};
    if (unquotedAngle(token)) |left| {
        const right = std.mem.lastIndexOfScalar(u8, token, '>') orelse return error.InvalidRecipients;
        if (right <= left or std.mem.trim(u8, token[right + 1 ..], " ").len != 0) return error.InvalidRecipients;
        const address = std.mem.trim(u8, token[left + 1 .. right], " ");
        try validateAddress(address);
        try out.address.set(address);
        const name = std.mem.trim(u8, token[0..left], " ");
        if (name.len > 1 and name[0] == '"' and name[name.len - 1] == '"') {
            var decoded: [256]u8 = undefined;
            var n: usize = 0;
            var pos: usize = 1;
            while (pos < name.len - 1) : (pos += 1) {
                if (name[pos] == '\\') {
                    pos += 1;
                    if (pos >= name.len - 1) return error.InvalidRecipients;
                }
                if (n == decoded.len) return error.RecipientTooLarge;
                decoded[n] = name[pos];
                n += 1;
            }
            try out.name.set(decoded[0..n]);
        } else {
            if (name.len > 256) return error.RecipientTooLarge;
            try out.name.set(name);
        }
    } else {
        try validateAddress(token);
        try out.address.set(token);
    }
    return out;
}
/// Strip comments and parse mailbox grammar before decoding RFC 2047 words.
/// Temporary storage is proportional to the already bounded header token.
fn incomingMailbox(raw: []const u8, allocator: std.mem.Allocator) !IncomingMailbox {
    const clean = try allocator.alloc(u8, raw.len);
    defer allocator.free(clean);
    var used: usize = 0;
    var depth: usize = 0;
    var quote = false;
    var escape = false;
    for (raw) |c| {
        if (escape) {
            if (depth == 0) {
                clean[used] = c;
                used += 1;
            }
            escape = false;
            continue;
        }
        if (c == '\\' and (quote or depth > 0)) {
            escape = true;
            if (depth == 0) {
                clean[used] = c;
                used += 1;
            }
            continue;
        }
        if (depth > 0) {
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
            continue;
        }
        if (!quote and c == '(') {
            depth = 1;
            continue;
        }
        if (c == '"') quote = !quote;
        clean[used] = if (c == '\t') ' ' else c;
        used += 1;
    }
    const token = std.mem.trim(u8, clean[0..used], " ");
    var address = token;
    var name: []const u8 = "";
    if (unquotedAngle(token)) |left| {
        const right = std.mem.lastIndexOfScalar(u8, token, '>') orelse return error.InvalidRecipients;
        if (right <= left or std.mem.trim(u8, token[right + 1 ..], " ").len != 0) return error.InvalidRecipients;
        address = std.mem.trim(u8, token[left + 1 .. right], " ");
        name = std.mem.trim(u8, token[0..left], " ");
    }
    try validateAddressSyntax(address, true);
    const address_copy = try allocator.dupe(u8, address);
    errdefer allocator.free(address_copy);
    const name_copy = if (name.len > 1 and name[0] == '"' and name[name.len - 1] == '"') decoded: {
        const bytes = try allocator.alloc(u8, name.len - 2);
        errdefer allocator.free(bytes);
        var n: usize = 0;
        var pos: usize = 1;
        while (pos < name.len - 1) : (pos += 1) {
            if (name[pos] == '\\') {
                pos += 1;
                if (pos >= name.len - 1) return error.InvalidRecipients;
            }
            bytes[n] = name[pos];
            n += 1;
        }
        // Copy exact owned slices so deallocation also works with accounting
        // allocators; this avoids retaining raw encoded-word padding.
        const result = try allocator.dupe(u8, bytes[0..n]);
        allocator.free(bytes);
        break :decoded result;
    } else try allocator.dupe(u8, name);
    return .{ .address = address_copy, .name = name_copy };
}

fn unquotedAngle(token: []const u8) ?usize {
    var quoted = false;
    var escaped = false;
    for (token, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quoted and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') quoted = !quoted else if (!quoted and c == '<') return i;
    }
    return null;
}

fn isSelf(address: []const u8, account: []const u8, aliases: []const []const u8) bool {
    if (std.ascii.eqlIgnoreCase(address, account)) return true;
    for (aliases) |alias| if (std.ascii.eqlIgnoreCase(address, alias)) return true;
    return false;
}

fn addExternal(out: *List, source: *const List, account: []const u8, aliases: []const []const u8, other: ?*const List) !void {
    for (source.slice()) |item| {
        if (isSelf(item.address.slice(), account, aliases)) continue;
        if (other) |list| if (list.contains(item.address.slice())) continue;
        try out.append(item);
    }
}

pub fn reply(account: []const u8, aliases: []const []const u8, from: []const u8, reply_to: []const u8, to: []const u8, cc: []const u8, all: bool, out: *Envelope) !void {
    try validateAddress(account);
    if (aliases.len > max_recipients) return error.TooManyAliases;
    for (aliases) |alias| try validateAddress(alias);
    out.* = .{};
    var sender: List = .{};
    var original_to: List = .{};
    var original_cc: List = .{};
    try parse(if (reply_to.len != 0) reply_to else from, &sender);
    if (sender.count == 0) return error.MissingReplyRecipient;
    try parse(to, &original_to);
    try parse(cc, &original_cc);
    try addExternal(&out.to, &sender, account, aliases, null);
    // Replying to our own sent mail addresses the original To recipients.
    if (out.to.count == 0) try addExternal(&out.to, &original_to, account, aliases, null) else if (all) try addExternal(&out.cc, &original_to, account, aliases, &out.to);
    if (all) try addExternal(&out.cc, &original_cc, account, aliases, &out.to);
    if (out.to.count == 0 and out.cc.count == 0) return error.MissingReplyRecipient;
    if (@as(usize, out.to.count) + out.cc.count > max_recipients) return error.TooManyRecipients;
}

fn addIncomingExternal(out: *List, source: []const IncomingMailbox, account: []const u8, aliases: []const []const u8, other: ?*const List) !void {
    for (source) |item| {
        if (isSelf(item.address, account, aliases)) continue;
        if (other) |list| if (list.contains(item.address)) continue;
        var outgoing: Mailbox = .{};
        // Reading a header never grants permission to send to an address that
        // fails the outgoing SMTP/address or display-name limits.
        try validateAddress(item.address);
        try outgoing.address.set(item.address);
        try outgoing.name.set(item.name);
        try out.append(outgoing);
    }
}
/// Incoming participants are heap bounded separately from the final 32-recipient
/// send envelope. Ordinary replies need no original To/Cc parsing unless replying
/// to our own message; reply-all fails explicitly instead of dropping recipients.
pub fn replyIncoming(allocator: std.mem.Allocator, account: []const u8, aliases: []const []const u8, from: []const u8, reply_to: []const u8, to: []const u8, cc: []const u8, all: bool, out: *Envelope) !void {
    errdefer out.* = .{};
    try validateAddress(account);
    if (aliases.len > max_recipients) return error.TooManyAliases;
    for (aliases) |alias| try validateAddress(alias);
    out.* = .{};
    const sender = try parseIncoming(if (reply_to.len != 0) reply_to else from, allocator);
    defer deinitIncoming(sender, allocator);
    if (sender.len == 0) return error.MissingReplyRecipient;
    try addIncomingExternal(&out.to, sender, account, aliases, null);
    if (out.to.count == 0 or all) {
        const original_to = try parseIncoming(to, allocator);
        defer deinitIncoming(original_to, allocator);
        if (out.to.count == 0) try addIncomingExternal(&out.to, original_to, account, aliases, null) else try addIncomingExternal(&out.cc, original_to, account, aliases, &out.to);
    }
    if (all) {
        const original_cc = try parseIncoming(cc, allocator);
        defer deinitIncoming(original_cc, allocator);
        try addIncomingExternal(&out.cc, original_cc, account, aliases, &out.to);
    }
    if (out.to.count == 0 and out.cc.count == 0) return error.MissingReplyRecipient;
    if (@as(usize, out.to.count) + out.cc.count > max_recipients) return error.TooManyRecipients;
}

pub fn validateEnvelope(envelope: *const Envelope) !void {
    const total = @as(usize, envelope.to.count) + envelope.cc.count + envelope.bcc.count;
    if (total == 0) return error.MissingRecipient;
    if (total > max_recipients) return error.TooManyRecipients;
    for ([_]*const List{ &envelope.to, &envelope.cc, &envelope.bcc }) |list| for (list.slice()) |*item| {
        try validateAddress(item.address.slice());
        try validateHeader(item.name.slice());
    };
}

test "recipient grammar preserves quoted comma groups and literal mailboxes" {
    var list: List = .{};
    try parse("Team: \"Doe, Jane\" <jane@example.test>, Alex (team) <alex@example.test>;", &list);
    try std.testing.expectEqual(@as(u8, 2), list.count);
    try std.testing.expectEqualStrings("Doe, Jane", list.items[0].name.slice());
    try std.testing.expectEqualStrings("alex@example.test", list.items[1].address.slice());
    try validateAddress("\"local space\"@example.test");
    try std.testing.expectError(error.HeaderInjection, parse("safe@example.test\r\nBcc: hidden@example.test", &list));
    try std.testing.expectError(error.InvalidAddress, validateAddress("a..b@example.test"));
    try std.testing.expectError(error.InvalidRecipients, parse("\"broken <a@example.test>", &list));
}

test "reply-all uses Reply-To excludes aliases and never infers Bcc" {
    var envelope: Envelope = .{};
    try reply("self@example.test", &.{"alias@example.test"}, "Sender <from@example.test>", "reply@example.test", "SELF@example.test, alias@example.test, other@example.test, reply@example.test", "other@example.test, copy@example.test", true, &envelope);
    try std.testing.expectEqual(@as(u8, 1), envelope.to.count);
    try std.testing.expectEqual(@as(u8, 2), envelope.cc.count);
    try std.testing.expectEqual(@as(u8, 0), envelope.bcc.count);
    try std.testing.expectEqualStrings("reply@example.test", envelope.to.items[0].address.slice());
    try std.testing.expectEqualStrings("copy@example.test", envelope.cc.items[1].address.slice());
    try reply("self@example.test", &.{}, "self@example.test", "", "other@example.test", "", false, &envelope);
    try std.testing.expectEqualStrings("other@example.test", envelope.to.items[0].address.slice());
}
test "legal incoming tabs group continuation and quoted angle names preserve mailbox grammar" {
    var list: List = .{};
    try parse("Group: a@example.test;, \"Left < arrow\"\t<b@example.test>, c@[IPv6:2001:db8::1]", &list);
    try std.testing.expectEqual(@as(u8, 3), list.count);
    try std.testing.expectEqualStrings("Left < arrow", list.items[1].name.slice());
    try std.testing.expectEqualStrings("c@[IPv6:2001:db8::1]", list.items[2].address.slice());
}

test "incoming local parts preserve header syntax while outgoing SMTP limits remain literal" {
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@example.test";
    const boundary = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@example.test";
    try std.testing.expectEqual(@as(usize, 65), std.mem.indexOfScalar(u8, long, '@').?);
    try std.testing.expectEqual(@as(usize, 64), std.mem.indexOfScalar(u8, boundary, '@').?);
    try validateAddress(boundary);
    try std.testing.expectError(error.InvalidAddress, validateAddress(long));
    const incoming = try parseIncoming("Reply person <" ++ long ++ ">", std.testing.allocator);
    defer deinitIncoming(incoming, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), incoming.len);
    try std.testing.expectEqualStrings(long, incoming[0].address);
    var outgoing: List = .{};
    try std.testing.expectError(error.InvalidAddress, parse(long, &outgoing));
    var reply_out: Envelope = .{};
    try std.testing.expectError(error.InvalidAddress, replyIncoming(std.testing.allocator, "self@example.test", &.{}, "sender@example.test", long, "", "", false, &reply_out));
    try std.testing.expectEqual(@as(u8, 0), reply_out.to.count);
}

test "incoming 33 participants allow ordinary reply and refuse truncated reply-all" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var boundary: usize = 0;
    for (0..33) |i| {
        if (i == 32) boundary = bytes.items.len;
        if (i != 0) try bytes.appendSlice(std.testing.allocator, ", ");
        const entry = try std.fmt.allocPrint(std.testing.allocator, "member{d}@example.test", .{i});
        defer std.testing.allocator.free(entry);
        try bytes.appendSlice(std.testing.allocator, entry);
    }
    const incoming = try parseIncoming(bytes.items, std.testing.allocator);
    defer deinitIncoming(incoming, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 33), incoming.len);
    var outgoing: List = .{};
    try parse(bytes.items[0..boundary], &outgoing);
    try std.testing.expectEqual(@as(u8, 32), outgoing.count);
    try std.testing.expectError(error.TooManyRecipients, parse(bytes.items, &outgoing));
    var envelope_out: Envelope = .{};
    try replyIncoming(std.testing.allocator, "self@example.test", &.{}, "sender@example.test", "", bytes.items, "copy@example.test", false, &envelope_out);
    try std.testing.expectEqual(@as(u8, 1), envelope_out.to.count);
    try std.testing.expectEqual(@as(u8, 0), envelope_out.cc.count);
    try std.testing.expectError(error.TooManyRecipients, replyIncoming(std.testing.allocator, "self@example.test", &.{}, "sender@example.test", "", bytes.items, "", true, &envelope_out));
    try std.testing.expectEqual(@as(u8, 0), envelope_out.to.count);
    try std.testing.expectEqual(@as(u8, 0), envelope_out.cc.count);
    try replyIncoming(std.testing.allocator, "self@example.test", &.{"alias@example.test"}, "sender@example.test", "replies@example.test", "SELF@example.test, alias@example.test, teammate@example.test, replies@example.test, teammate@example.test", "colleague@example.test, TEAMMATE@example.test", true, &envelope_out);
    try std.testing.expectEqualStrings("replies@example.test", envelope_out.to.items[0].address.slice());
    try std.testing.expectEqual(@as(u8, 2), envelope_out.cc.count);
    try std.testing.expectEqual(@as(u8, 0), envelope_out.bcc.count);
}

test "incoming heap participant bound and empty groups have independent numeric oracles" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..1024) |i| {
        if (i != 0) try bytes.append(std.testing.allocator, ',');
        const entry = try std.fmt.allocPrint(std.testing.allocator, "u{d}@a", .{i});
        defer std.testing.allocator.free(entry);
        try bytes.appendSlice(std.testing.allocator, entry);
    }
    try std.testing.expect(bytes.items.len < 8192);
    const maximum = try parseIncoming(bytes.items, std.testing.allocator);
    defer deinitIncoming(maximum, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1024), maximum.len);
    try std.testing.expectEqualStrings("u1023@a", maximum[1023].address);
    try bytes.appendSlice(std.testing.allocator, ",u1024@a");
    try std.testing.expectError(error.TooManyIncomingRecipients, parseIncoming(bytes.items, std.testing.allocator));
    const groups = try parseIncoming("Undisclosed:;, Team: \"Doe, Jane\" <jane@example.test>, Alex (comment) <alex@example.test>;", std.testing.allocator);
    defer deinitIncoming(groups, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqualStrings("Doe, Jane", groups[0].name);
    try std.testing.expectError(error.InvalidRecipients, parseIncoming("Unclosed: jane@example.test", std.testing.allocator));
    try std.testing.expectError(error.HeaderInjection, parseIncoming("safe@example.test\r\nBcc: hidden@example.test", std.testing.allocator));
}
fn allocationProbe(a: std.mem.Allocator) !void {
    const list = try parseIncoming("\"Quoted \\\"name\\\"\" <a@example.test>, Team: b@example.test;", a);
    defer deinitIncoming(list, a);
    try std.testing.expectEqual(@as(usize, 2), list.len);
}
test "incoming parser cleans up every allocation failure and malformed final mailbox" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
    try std.testing.expectError(error.InvalidAddress, parseIncoming("a@example.test, b@example.test, invalid", std.testing.allocator));
}
