//! Authored CID image identities and source markers. No payload or I/O lives here.
const std = @import("std");
const t = @import("types.zig");
const mime = @import("mime.zig");
const A = std.mem.Allocator;

pub const Marker = struct { label: []const u8, url: []const u8, end: usize };
pub const Removed = struct { source: []const u8, count: usize, cursor: usize };
pub const Span = struct { start: usize, end: usize };
/// A normalized line may have new indentation but keeps its content bytes.
/// Scopes are stack-owned by the renderer; aliases are sorted by view address.
pub const SourceAlias = struct { view: []const u8, start: usize };
pub const SourceScope = struct { aliases: []const SourceAlias, parent: ?*const SourceScope = null };
pub const Capture = struct {
    source: []const u8,
    spans: *std.ArrayList(Span),
    allocator: A,
    scope: ?*const SourceScope = null,

    pub fn offset(self: Capture, token: []const u8) !usize {
        const base = @intFromPtr(self.source.ptr);
        const address = @intFromPtr(token.ptr);
        if (address >= base and address - base <= self.source.len and token.len <= self.source.len - (address - base)) return address - base;
        var scope = self.scope;
        // Rendering depth is bounded; malformed/cyclic scope metadata cannot
        // turn source-position recovery into an unbounded walk.
        for (0..32) |_| {
            const current = scope orelse return error.InvalidMarkerOrigin;
            var low: usize = 0;
            var high = current.aliases.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (@intFromPtr(current.aliases[middle].view.ptr) <= address) low = middle + 1 else high = middle;
            }
            if (low > 0) {
                const alias = current.aliases[low - 1];
                const relative = address - @intFromPtr(alias.view.ptr);
                if (relative <= alias.view.len and token.len <= alias.view.len - relative) {
                    if (alias.start > self.source.len or alias.view.len > self.source.len - alias.start) return error.InvalidMarkerOrigin;
                    return alias.start + relative;
                }
            }
            scope = current.parent;
        }
        return error.InvalidMarkerOrigin;
    }
};

pub fn clipboardCid(value: []const u8) bool {
    const id = mime.contentId(value) catch return false;
    const prefix = "clipboard-";
    const suffix = "@omagma.invalid";
    if (id.len != prefix.len + 32 + suffix.len or !std.mem.startsWith(u8, id, prefix) or !std.mem.endsWith(u8, id, suffix)) return false;
    for (id[prefix.len..][0..32]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn isClipboardInline(file: t.Attachment) bool {
    return std.mem.eql(u8, file.mimeType, "image/png") and
        std.mem.eql(u8, file.disposition orelse "", "inline") and
        clipboardCid(file.contentId orelse return false);
}

fn imageType(value: []const u8) bool {
    inline for (.{ "image/png", "image/jpeg", "image/gif", "image/webp" }) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}

/// The same exact source token is used by rendering and explicit Detach.
/// A CID image has no optional title or remote URL interpretation.
pub fn marker(text: []const u8) ?Marker {
    if (!std.mem.startsWith(u8, text, "![")) return null;
    var end: usize = 2;
    while (end < text.len) : (end += 1) {
        if (text[end] == '\\' and end + 1 < text.len) {
            end += 1;
            continue;
        }
        if (text[end] == ']') break;
        if (text[end] == '\n' or text[end] == '\r' or end > 4096) return null;
    }
    if (end + 2 >= text.len or text[end] != ']' or text[end + 1] != '(') return null;
    const start = end + 2;
    const close = std.mem.indexOfScalar(u8, text[start..@min(text.len, start + 1540)], ')') orelse return null;
    const url = text[start..][0..close];
    var id: [512]u8 = undefined;
    _ = cidUrl(url, &id) orelse return null;
    return .{ .label = text[2..end], .url = url, .end = start + close + 1 };
}

pub fn cidUrl(url: []const u8, buffer: *[512]u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "cid:")) return null;
    var i: usize = 4;
    var n: usize = 0;
    while (i < url.len) : (i += 1) {
        var byte = url[i];
        if (byte == '%') {
            if (i + 2 >= url.len) return null;
            byte = std.fmt.parseInt(u8, url[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        }
        if (n == buffer.len) return null;
        buffer[n] = byte;
        n += 1;
    }
    return mime.contentId(buffer[0..n]) catch null;
}

/// RFC 2392 references use URI escaping, independently of MIME header brackets.
/// Rendering the resolved owned identity avoids percent/angle-bracket aliases
/// that would name a different part in a recipient or the local preview.
pub fn reference(raw: []const u8, buffer: *[1540]u8) ![]const u8 {
    const id = try mime.contentId(raw);
    @memcpy(buffer[0..4], "cid:");
    var n: usize = 4;
    const hex = "0123456789ABCDEF";
    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~@", byte) != null) {
            buffer[n] = byte;
            n += 1;
        } else {
            buffer[n] = '%';
            buffer[n + 1] = hex[byte >> 4];
            buffer[n + 2] = hex[byte & 15];
            n += 3;
        }
    }
    return buffer[0..n];
}

pub const Plan = struct {
    a: A,
    files: []const t.Attachment,
    used: []bool,
    index: std.StringHashMap(usize),
    capture: ?Capture = null,

    pub fn init(a: A, files: []const t.Attachment) !Plan {
        if (files.len > t.Limits.attachments) return error.TooManyAttachments;
        var plan: Plan = .{ .a = a, .files = files, .used = try a.alloc(bool, files.len), .index = .init(a) };
        errdefer plan.deinit();
        @memset(plan.used, false);
        for (files, 0..) |file, i| if (file.contentId) |raw| {
            const id = mime.contentId(raw) catch continue;
            const slot = try plan.index.getOrPut(id);
            if (slot.found_existing) {
                if (clipboardCid(id)) return error.AmbiguousContentId;
                slot.value_ptr.* = std.math.maxInt(usize);
            } else slot.value_ptr.* = i;
        };
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.index.deinit();
        self.a.free(self.used);
    }

    pub fn resolve(self: *Plan, url: []const u8) !?t.Attachment {
        var buffer: [512]u8 = undefined;
        const id = cidUrl(url, &buffer) orelse return null;
        const i = self.index.get(id) orelse return null;
        if (i == std.math.maxInt(usize)) return error.AmbiguousContentId;
        if (std.mem.eql(u8, id, "omagma-logo@omagma.invalid") or
            (std.mem.startsWith(u8, id, "omagma-logo.") and std.mem.endsWith(u8, id, "@omagma.invalid"))) return error.AmbiguousContentId;
        const file = self.files[i];
        if (!imageType(file.mimeType) or !std.mem.eql(u8, file.disposition orelse "", "inline") or file.size == 0 or (file.blobId == null and file.data.len == 0)) return error.InvalidInlineImage;
        if (file.delivery != null and file.delivery.? != .attach) return error.InlineImageRequiresAttachment;
        self.used[i] = true;
        return file;
    }

    /// The canonical block/inline parser calls this only for an actual owned
    /// image. Borrowed source slices preserve exact byte offsets through
    /// quotes, lists, tables and emphasis without a second Markdown grammar.
    pub fn record(self: *Plan, token: []const u8) !void {
        const capture = self.capture orelse return;
        const start = try capture.offset(token);
        if (capture.spans.items.len == t.Limits.related_resources * 16) return error.MarkdownTooComplex;
        try capture.spans.append(capture.allocator, .{ .start = start, .end = start + token.len });
    }
};

pub fn removeSpans(a: A, source: []const u8, found: []const Span, old_cursor: usize) !Removed {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var cursor: usize = 0;
    var caret = @min(old_cursor, source.len);
    // Recover a boundary if an older caller left a stale byte position.
    while (caret > 0 and caret < source.len and source[caret] & 0xc0 == 0x80) caret -= 1;
    var mapped = caret;
    var removed_bytes: usize = 0;
    for (found) |span| {
        if (span.start < cursor or span.end < span.start or span.end > source.len) return error.InvalidMarkerOrigin;
        var start = span.start;
        var end = span.end;
        // A pasted image is its own paragraph. Remove one newly surplus
        // blank line without changing the surrounding prose or examples.
        if (start >= 2 and end + 2 <= source.len and std.mem.eql(u8, source[start - 2 .. start], "\n\n") and std.mem.eql(u8, source[end .. end + 2], "\n\n")) start -= 2;
        if (end < source.len and source[end] == '\n' and start == cursor) end += 1;
        if (start < cursor) start = cursor;
        try out.appendSlice(a, source[cursor..start]);
        // Use the effective deletion, including collapsed blank lines. A
        // caret inside it moves to its start; later carets shift by all bytes
        // actually removed before them, retaining their UTF-8 boundary.
        if (caret >= end) mapped = caret - removed_bytes - (end - start) else if (caret >= start) mapped = start - removed_bytes;
        removed_bytes += end - start;
        cursor = end;
    }
    try out.appendSlice(a, source[cursor..]);
    return .{ .source = try out.toOwnedSlice(a), .count = found.len, .cursor = mapped };
}

test "parser tabs: normalized image origins exclude generated indentation and preserve bounds" {
    const source = "image-token";
    const view = try std.testing.allocator.dupe(u8, "  image-token");
    defer std.testing.allocator.free(view);
    var aliases = [_]SourceAlias{.{ .view = view[2..], .start = 0 }};
    const scope: SourceScope = .{ .aliases = &aliases };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(std.testing.allocator);
    const capture: Capture = .{ .source = source, .spans = &spans, .allocator = std.testing.allocator, .scope = &scope };
    try std.testing.expectEqual(@as(usize, 0), try capture.offset(view[2..]));
    try std.testing.expectEqual(@as(usize, 6), try capture.offset(view[8..]));
    try std.testing.expectError(error.InvalidMarkerOrigin, capture.offset(view[0..3]));
    aliases[0].start = source.len;
    try std.testing.expectError(error.InvalidMarkerOrigin, capture.offset(view[2..]));
}
