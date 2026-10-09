//! A private outgoing preview. Mail is escaped into an opaque sandboxed
//! srcdoc, with inherited and child CSP; it never shares the shell's origin.
//! CSP inheritance: https://www.w3.org/TR/CSP3/#security-inherit-csp
//! Sandbox: https://html.spec.whatwg.org/multipage/iframe-embed-object.html
const std = @import("std");
const t = @import("types.zig");
const markdown_mail = @import("markdown_mail.zig");
const logo = @import("markdown_logo.zig");

pub const filename = "preview.html";
pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const Result = struct { path: []const u8 };
const max_tag_bytes = 16384;
const max_tokens = 65536;
const csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; " ++
    "font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; " ++
    "worker-src 'none'; base-uri 'none'; form-action 'none'";
// The shell may create only local about: documents. The child then tightens
// its own frame policy to none; neither policy allows a network navigation.
const outer_csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; " ++
    "font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src about:; " ++
    "worker-src 'none'; base-uri 'none'; form-action 'none'";

const Out = struct {
    writer: *std.Io.Writer,
    count: usize = 0,
    fn raw(self: *Out, bytes: []const u8) !void {
        if (bytes.len > max_file_bytes - self.count) return error.PreviewTooLarge;
        try self.writer.writeAll(bytes);
        self.count += bytes.len;
    }
    /// The child document is an HTML attribute, not executable outer markup.
    fn escaped(self: *Out, bytes: []const u8) !void {
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            const replacement: ?[]const u8 = switch (byte) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => null,
            };
            if (replacement) |value| {
                try self.raw(bytes[start..index]);
                try self.raw(value);
                start = index + 1;
            }
        }
        try self.raw(bytes[start..]);
    }
    fn plain(self: *Out, bytes: []const u8) !void {
        // Plain-text body needs one HTML escape inside the srcdoc escape.
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            const replacement: ?[]const u8 = switch (byte) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                else => null,
            };
            if (replacement) |value| {
                try self.escaped(bytes[start..index]);
                try self.escaped(value);
                start = index + 1;
            }
        }
        try self.escaped(bytes[start..]);
    }
};

/// Exact output budget without allocating another HTML copy. The backend
/// can reserve this count instead of the maximum, preserving small caches.
pub fn byteSize(prepared: markdown_mail.Prepared, draft: t.Draft) !usize {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try render(&sink.writer, prepared, draft);
    return @intCast(sink.fullCount());
}

/// Caller reserves byteSize (or max_file_bytes) in its account store first.
/// The one fixed file is atomically replaced, never appended or accumulated.
pub fn writePreview(io: std.Io, allocator: std.mem.Allocator, account_store_dir: std.Io.Dir, prepared: markdown_mail.Prepared, draft: t.Draft) !Result {
    const directory_stat = try account_store_dir.stat(io);
    if (directory_stat.kind != .directory or directory_stat.permissions.toMode() & 0o077 != 0) return error.InsecurePreviewDirectory;
    const existing: ?std.Io.File.Stat = account_store_dir.statFile(io, filename, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) null else return err;
    if (existing) |stat| if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.UnsafePreviewPath;
    const source = prepared.html orelse prepared.plain;
    if (source.len > t.Limits.body_bytes or !std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidPreviewBody;
    if (prepared.resources.len > 64 or draft.to.len + draft.cc.len + draft.bcc.len > t.Limits.recipients) return error.PreviewTooLarge;
    if (draft.subject.len > 4096) return error.InvalidPreviewHeading;
    var atomic = try account_store_dir.createFileAtomic(io, filename, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    var buffer: [8192]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try render(&writer.interface, prepared, draft);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
    const parent: std.Io.File = .{ .handle = account_store_dir.handle, .flags = .{ .nonblocking = false } };
    try parent.sync(io);
    const path = try account_store_dir.realPathFileAlloc(io, filename, allocator);
    defer allocator.free(path);
    // realPathFileAlloc returns a sentinel allocation. The public ordinary
    // slice owns exactly its reported length, including for strict allocators.
    return .{ .path = try allocator.dupe(u8, path) };
}

fn addresses(out: *Out, values: []const t.Address) !void {
    for (values, 0..) |address, index| {
        if (address.address.len > 320 or address.name.len > 256) return error.InvalidPreviewHeading;
        if (index != 0) try out.raw(", ");
        if (address.name.len > 0) {
            try out.escaped(address.name);
            try out.raw(" &lt;");
        }
        try out.escaped(address.address);
        if (address.name.len > 0) try out.raw("&gt;");
    }
}

pub fn render(writer: *std.Io.Writer, prepared: markdown_mail.Prepared, draft: t.Draft) !void {
    var out: Out = .{ .writer = writer };
    const context = try Context.init(prepared);
    try out.raw("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><meta http-equiv=\"Content-Security-Policy\" content=\"");
    try out.escaped(outer_csp);
    try out.raw("\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Outgoing preview</title><style>" ++
        ":root{color-scheme:light dark;font-family:system-ui,sans-serif;background:Canvas;color:CanvasText}" ++
        "body{margin:0}header{padding:18px 24px;border-bottom:3px solid #ff9e61}" ++
        "h1{font-size:20px;margin:0 0 6px;overflow-wrap:anywhere}.cue{font-size:13px;margin:0 0 12px}" ++
        "dl{margin:0;display:grid;grid-template-columns:44px 1fr;gap:4px 12px;font-size:13px}" ++
        "dt{opacity:.65}dd{margin:0;overflow-wrap:anywhere}iframe{display:block;width:100%;height:calc(100vh - 200px);min-height:480px;border:0;background:white}" ++
        "</style></head><body><header><h1>");
    try out.escaped(if (draft.subject.len > 0) draft.subject else "(no subject)");
    try out.raw("</h1><p class=\"cue\">Outgoing preview · not sent · remote content blocked</p><dl>");
    if (draft.from) |from| {
        try out.raw("<dt>From</dt><dd>");
        try addresses(&out, &.{from});
        try out.raw("</dd>");
    }
    const fields = [_]struct { name: []const u8, values: []const t.Address }{
        .{ .name = "To", .values = draft.to }, .{ .name = "Cc", .values = draft.cc }, .{ .name = "Bcc", .values = draft.bcc },
    };
    for (fields) |field| if (field.values.len > 0) {
        try out.raw("<dt>");
        try out.raw(field.name);
        try out.raw("</dt><dd>");
        try addresses(&out, field.values);
        try out.raw("</dd>");
    };
    try out.raw("</dl></header><iframe title=\"Outgoing message\" sandbox=\"\" referrerpolicy=\"no-referrer\" srcdoc=\"");
    try out.escaped("<!doctype html><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><meta http-equiv=\"Content-Security-Policy\" content=\"");
    try out.escaped(csp);
    try out.escaped("\">");
    if (prepared.html) |html| {
        try childHtml(&out, html, &context);
    } else {
        try out.escaped("<pre style=\"white-space:pre-wrap;overflow-wrap:anywhere;padding:20px;font:15px/1.6 ui-monospace,monospace\">");
        try out.plain(prepared.plain);
        try out.escaped("</pre>");
    }
    try out.raw("\"></iframe></body></html>");
}

fn white(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 12;
}
fn equal(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
fn indexIgnoreCase(input: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len > input.len) return null;
    var index = start;
    while (index <= input.len - needle.len) : (index += 1) if (equal(input[index..][0..needle.len], needle)) return index;
    return null;
}
const Tag = struct { name: []const u8, start: usize, attributes: usize, end: usize, closing: bool };
fn tagAt(input: []const u8, start: usize) !?Tag {
    if (start + 1 >= input.len) return null;
    var index = start + 1;
    const closing = input[index] == '/';
    if (closing) index += 1;
    const begin = index;
    if (index == input.len or !std.ascii.isAlphabetic(input[index])) return null;
    while (index < input.len and (std.ascii.isAlphanumeric(input[index]) or input[index] == ':' or input[index] == '-')) : (index += 1) {}
    const name = input[begin..index];
    const attributes = index;
    var quote: u8 = 0;
    while (index < input.len) : (index += 1) {
        if (index - start > max_tag_bytes) return error.PreviewTooComplex;
        const byte = input[index];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') return .{ .name = name, .start = start, .attributes = attributes, .end = index + 1, .closing = closing } else if (byte == '<') return null;
    }
    return null;
}
fn dropTag(name: []const u8) bool {
    for ([_][]const u8{ "meta", "base", "link", "script", "iframe", "frame", "frameset", "object", "embed", "svg", "math" }) |blocked| if (equal(name, blocked)) return true;
    return false;
}
fn dropContents(name: []const u8) bool {
    for ([_][]const u8{ "script", "iframe", "object", "svg", "math" }) |blocked| if (equal(name, blocked)) return true;
    return false;
}
fn endOfBlocked(input: []const u8, tag: Tag) usize {
    var needle: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&needle, "</{s}", .{tag.name}) catch return input.len;
    var offset = tag.end;
    while (indexIgnoreCase(input, close, offset)) |start| {
        const candidate = tagAt(input, start) catch return input.len;
        if (candidate) |end| if (end.closing and equal(end.name, tag.name)) return end.end;
        offset = start + close.len;
    }
    return input.len;
}

const Attribute = struct { name: []const u8, start: usize, value_start: usize, value_end: usize, end: usize };
fn nextAttribute(input: []const u8, position: *usize, end: usize) ?Attribute {
    var index = position.*;
    // Malformed separators are consumed iteratively, never via recursive
    // calls controlled by received markup.
    while (index < end and (white(input[index]) or input[index] == '/' or input[index] == '=')) : (index += 1) {}
    if (index == end or input[index] == '>') return null;
    const start = index;
    while (index < end and !white(input[index]) and input[index] != '=' and input[index] != '/' and input[index] != '>') : (index += 1) {}
    const name = input[start..index];
    while (index < end and white(input[index])) : (index += 1) {}
    var value_start = index;
    var value_end = index;
    if (index < end and input[index] == '=') {
        index += 1;
        while (index < end and white(input[index])) : (index += 1) {}
        if (index < end and (input[index] == '\'' or input[index] == '"')) {
            const quote = input[index];
            index += 1;
            value_start = index;
            while (index < end and input[index] != quote) : (index += 1) {}
            value_end = index;
            if (index < end) index += 1;
        } else {
            value_start = index;
            while (index < end and !white(input[index]) and input[index] != '>') : (index += 1) {}
            value_end = index;
        }
    }
    position.* = index;
    return .{ .name = name, .start = start, .value_start = value_start, .value_end = value_end, .end = index };
}

const Image = struct { mime: []const u8, encoded: ?[]const u8 = null, bytes: ?[]const u8 = null };
const Context = struct {
    prepared: markdown_mail.Prepared,
    images: [64]?Image = @splat(null),
    fn init(prepared: markdown_mail.Prepared) !Context {
        if (prepared.resources.len > 64) return error.PreviewTooLarge;
        const source = prepared.html orelse prepared.plain;
        if (source.len > t.Limits.body_bytes or !std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidPreviewBody;
        var result: Context = .{ .prepared = prepared };
        // Verify retained bytes once even when one image is referenced many times.
        for (prepared.resources, 0..) |resource, index| result.images[index] = verifiedImage(resource.mimeType, resource.data);
        return result;
    }
};
fn rasterMime(input: []const u8) ?[]const u8 {
    for ([_][]const u8{ "image/png", "image/jpeg", "image/gif" }) |mime| if (equal(input, mime)) return mime;
    return null;
}
fn normalizedBase64(byte: u8) u8 {
    return switch (byte) {
        '-' => '+',
        '_' => '/',
        else => byte,
    };
}
fn verifiedImage(mime_input: []const u8, encoded_input: []const u8) ?Image {
    const mime = rasterMime(mime_input) orelse return null;
    const encoded = std.mem.trimEnd(u8, encoded_input, "=");
    if (encoded.len < 4 or encoded.len > (t.Limits.body_bytes + 2) / 3 * 4 or encoded.len % 4 == 1) return null;
    if (encoded_input.len - encoded.len > 2) return null;
    for (encoded) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/' or byte == '-' or byte == '_')) return null;
    var prefix: [16]u8 = undefined;
    const length = @min(encoded.len, prefix.len);
    for (encoded[0..length], prefix[0..length]) |byte, *dest| dest.* = normalizedBase64(byte);
    var decoded: [12]u8 = undefined;
    const size = std.base64.standard_no_pad.Decoder.calcSizeForSlice(prefix[0..length]) catch return null;
    std.base64.standard_no_pad.Decoder.decode(decoded[0..size], prefix[0..length]) catch return null;
    const valid = if (equal(mime, "image/png")) size >= 8 and std.mem.eql(u8, decoded[0..8], "\x89PNG\r\n\x1a\n") else if (equal(mime, "image/jpeg")) size >= 3 and std.mem.eql(u8, decoded[0..3], "\xff\xd8\xff") else size >= 6 and (std.mem.eql(u8, decoded[0..6], "GIF87a") or std.mem.eql(u8, decoded[0..6], "GIF89a"));
    if (!valid) return null;
    return .{ .mime = mime, .encoded = encoded };
}

/// Decode only bounded URL tokens. Prose, script text and source styles are
/// not globally searched/replaced; references remain tied to actual markup.
fn decodedUrl(input: []const u8, storage: *[4096]u8) ?[]const u8 {
    var index: usize = 0;
    var length: usize = 0;
    while (index < input.len) {
        if (input[index] >= 128) {
            if (length == storage.len) return null;
            storage[length] = input[index];
            length += 1;
            index += 1;
            continue;
        }
        var value: u21 = input[index];
        var consumed: usize = 1;
        if (input[index] == '&') {
            const end = std.mem.indexOfScalarPos(u8, input, index + 1, ';') orelse return null;
            if (end - index > 16) return null;
            const entity = input[index + 1 .. end];
            if (entity.len > 1 and entity[0] == '#') {
                const hex = entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X');
                value = std.fmt.parseInt(u21, entity[if (hex) @as(usize, 2) else 1..], if (hex) 16 else 10) catch return null;
            } else {
                value = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "colon")) ':' else return null;
            }
            consumed = end - index + 1;
        } else if (input[index] == '\\') {
            if (index + 1 == input.len) return null;
            var end = index + 1;
            while (end < input.len and end - index <= 6 and std.ascii.isHex(input[end])) : (end += 1) {}
            if (end > index + 1) {
                value = std.fmt.parseInt(u21, input[index + 1 .. end], 16) catch return null;
                if (end < input.len and white(input[end])) end += 1;
                consumed = end - index;
            } else {
                value = input[index + 1];
                consumed = 2;
            }
        }
        if (value == 0 or value < 32 or value == 127) return null;
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(value, &encoded) catch return null;
        if (count > storage.len - length) return null;
        @memcpy(storage[length..][0..count], encoded[0..count]);
        length += count;
        index += consumed;
    }
    var result = std.mem.trim(u8, storage[0..length], " \t\r\n");
    if (result.len >= 2 and ((result[0] == '\'' and result[result.len - 1] == '\'') or (result[0] == '"' and result[result.len - 1] == '"'))) result = result[1 .. result.len - 1];
    return result;
}
fn imageFor(input: []const u8, source_offset: ?usize, context: *const Context) ?Image {
    const prepared = context.prepared;
    // Data URLs borrow source bytes, never the decoder's stack scratch.
    const stable = std.mem.trim(u8, input, " \t\r\n\"'");
    if (std.ascii.startsWithIgnoreCase(stable, "data:")) {
        const separator = std.mem.indexOf(u8, stable, ";base64,") orelse return null;
        return verifiedImage(stable[5..separator], stable[separator + 8 ..]);
    }
    var storage: [4096]u8 = undefined;
    const url = decodedUrl(input, &storage) orelse return null;
    if (std.ascii.startsWithIgnoreCase(url, "cid:")) {
        if (source_offset != null and prepared.logoOffset != null and source_offset.? + 4 == prepared.logoOffset.?) return .{ .mime = "image/png", .bytes = logo.png };
        var identifier: [4096]u8 = undefined;
        var length: usize = 0;
        var index: usize = 4;
        while (index < url.len) : (index += 1) {
            var byte = url[index];
            if (byte == '%') {
                if (index + 2 >= url.len) return null;
                byte = std.fmt.parseInt(u8, url[index + 1 .. index + 3], 16) catch return null;
                index += 2;
            }
            if (byte == 0 or length == identifier.len) return null;
            identifier[length] = byte;
            length += 1;
        }
        for (prepared.resources, 0..) |resource, resource_index| if (resource.contentId) |cid| {
            if (std.mem.eql(u8, std.mem.trim(u8, cid, "<> \t"), identifier[0..length])) return context.images[resource_index];
        };
    } else for (prepared.resources, 0..) |resource, resource_index| if (resource.contentLocation) |location| {
        if (std.mem.eql(u8, location, url)) return context.images[resource_index];
    };
    return null;
}
fn dataUrl(out: *Out, image: Image) !void {
    try out.escaped("data:");
    try out.escaped(image.mime);
    try out.escaped(";base64,");
    if (image.bytes) |bytes| {
        var index: usize = 0;
        var encoded: [4096]u8 = undefined;
        while (index < bytes.len) {
            const end = @min(index + 3072, bytes.len);
            try out.escaped(std.base64.standard.Encoder.encode(&encoded, bytes[index..end]));
            index = end;
        }
    } else if (image.encoded) |encoded| {
        var chunk: [4096]u8 = undefined;
        var index: usize = 0;
        while (index < encoded.len) {
            const size = @min(chunk.len, encoded.len - index);
            for (encoded[index..][0..size], chunk[0..size]) |byte, *dest| dest.* = normalizedBase64(byte);
            try out.escaped(chunk[0..size]);
            index += size;
        }
        const padding = (4 - encoded.len % 4) % 4;
        try out.escaped("==="[0..padding]);
    }
}

fn css(out: *Out, source: []const u8, context: *const Context) !void {
    var index: usize = 0;
    var literal: usize = 0;
    var quote: u8 = 0;
    while (index < source.len) : (index += 1) {
        if (quote != 0) {
            if (source[index] == '\\') index += @intFromBool(index + 1 < source.len) else if (source[index] == quote) quote = 0;
            continue;
        }
        if (source[index] == '\'' or source[index] == '"') {
            quote = source[index];
            continue;
        }
        if (std.mem.startsWith(u8, source[index..], "/*")) {
            index = if (std.mem.indexOf(u8, source[index + 2 ..], "*/")) |end| index + end + 3 else source.len - 1;
            continue;
        }
        if (source.len - index < 4 or !equal(source[index..][0..4], "url(")) continue;
        var end = index + 4;
        var inner_quote: u8 = 0;
        while (end < source.len) : (end += 1) {
            if (source[end] == '\\') {
                end += @intFromBool(end + 1 < source.len);
                continue;
            }
            if (inner_quote != 0) {
                if (source[end] == inner_quote) inner_quote = 0;
            } else if (source[end] == '\'' or source[end] == '"') inner_quote = source[end] else if (source[end] == ')') break;
        }
        if (end == source.len) continue;
        try out.escaped(source[literal..index]);
        if (imageFor(source[index + 4 .. end], null, context)) |image| {
            try out.escaped("url(");
            try dataUrl(out, image);
            try out.escaped(")");
        } else try out.escaped("none");
        index = end;
        literal = end + 1;
    }
    try out.escaped(source[literal..]);
}

fn childTag(out: *Out, input: []const u8, tag: Tag, context: *const Context) !void {
    var position = tag.attributes;
    var literal = tag.start;
    while (nextAttribute(input, &position, tag.end - 1)) |attribute| {
        const name = attribute.name;
        const image_attribute = (equal(tag.name, "img") and equal(name, "src")) or equal(name, "background");
        const removed = std.ascii.startsWithIgnoreCase(name, "on") or equal(name, "src") or equal(name, "srcset") or equal(name, "href") or equal(name, "xlink:href") or equal(name, "ping") or equal(name, "action") or equal(name, "formaction") or equal(name, "srcdoc") or equal(name, "manifest") or equal(name, "poster");
        if (!image_attribute and !removed and !equal(name, "style")) continue;
        try out.escaped(input[literal..attribute.start]);
        if (image_attribute) {
            if (imageFor(input[attribute.value_start..attribute.value_end], attribute.value_start, context)) |image| {
                try out.escaped(name);
                try out.escaped("=\"");
                try dataUrl(out, image);
                try out.escaped("\"");
            }
        } else if (equal(name, "style")) {
            // Preserve the original attribute quoting/entity syntax. Only URL
            // functions change; no whole source HTML copy is allocated.
            try out.escaped(input[attribute.start..attribute.value_start]);
            try css(out, input[attribute.value_start..attribute.value_end], context);
            try out.escaped(input[attribute.value_end..attribute.end]);
        }
        literal = attribute.end;
    }
    try out.escaped(input[literal..tag.end]);
}

fn childHtml(out: *Out, input: []const u8, context: *const Context) !void {
    var offset: usize = 0;
    var tokens: usize = 0;
    while (offset < input.len) {
        tokens += 1;
        if (tokens > max_tokens) return error.PreviewTooComplex;
        if (std.mem.startsWith(u8, input[offset..], "<!--")) {
            const end = std.mem.indexOf(u8, input[offset + 4 ..], "-->") orelse return;
            offset += end + 7;
            continue;
        }
        if (input[offset] == '<') {
            if (try tagAt(input, offset)) |tag| {
                offset = tag.end;
                if (dropTag(tag.name)) {
                    if (!tag.closing and dropContents(tag.name)) offset = endOfBlocked(input, tag);
                    continue;
                }
                try childTag(out, input, tag, context);
                if (!tag.closing and equal(tag.name, "style")) {
                    const end = indexIgnoreCase(input, "</style", offset) orelse input.len;
                    try css(out, input[offset..end], context);
                    offset = end;
                }
                continue;
            }
        }
        const end = if (input[offset] == '<') offset + 1 else std.mem.indexOfScalarPos(u8, input, offset, '<') orelse input.len;
        try out.escaped(input[offset..end]);
        offset = end;
    }
}

test "preview file: private replacement preserves tables and separates untrusted mail from shell" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "private", .fromMode(0o700));
    const directory = try temporary.dir.openDir(io, "private", .{ .iterate = true });
    defer directory.close(io);
    const html = "<html><head><style>table{border-collapse:collapse}td{color:#123456}</style></head><body><table><tr><td>Original table</td></tr></table><script>parent.document.body.innerHTML='unsafe'</script><img src='https://example.test/tracker' onerror='alert(1)'><meta http-equiv='refresh' content='0;url=https://example.test/navigation'><a href='https://example.test/link'>Human link label</a></body></html>";
    const result = try writePreview(io, std.testing.allocator, directory, .{ .plain = "Original table", .html = html }, .{ .subject = "Quote \" </iframe><script>unsafe</script>" });
    defer std.testing.allocator.free(result.path);
    const file = try directory.openFile(io, filename, .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual((try file.stat(io)).size, @as(u64, try byteSize(.{ .plain = "Original table", .html = html }, .{ .subject = "Quote \" </iframe><script>unsafe</script>" })));
    const bytes = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(bytes);
    const output = try directory.readFile(io, filename, bytes);
    try std.testing.expect(std.fs.path.isAbsolute(result.path));
    try std.testing.expect(std.mem.indexOf(u8, output, "sandbox=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;table&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Original table") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "color:#123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "parent.document") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Human link label") != null);
    const next = try writePreview(io, std.testing.allocator, directory, .{ .plain = "Second <literal> & note" }, .{ .subject = "Second draft" });
    defer std.testing.allocator.free(next.path);
    try std.testing.expectEqualStrings(result.path, next.path);
    const replaced = try directory.readFile(io, filename, bytes);
    try std.testing.expect(std.mem.indexOf(u8, replaced, "Original table") == null);
    try std.testing.expect(std.mem.indexOf(u8, replaced, "Second &amp;lt;literal&amp;gt; &amp;amp; note") != null);
}

test "preview file: raster signatures and CID decoding prevent mislabeled SVG data" {
    try std.testing.expect(verifiedImage("image/png", "PHN2Zz48c2NyaXB0PmFsZXJ0KDEpPC9zY3JpcHQ+PC9zdmc+") == null);
    try std.testing.expect(verifiedImage("image/svg+xml", "iVBORw0KGgo=") == null);
    try std.testing.expect(verifiedImage("image/png", "iVBORw0KGgo=") != null);
    const resources = [_]t.Attachment{.{ .id = "image", .filename = "picture.png", .mimeType = "image/png", .data = "iVBORw0KGgo=", .contentId = "picture@example.test" }};
    const context = try Context.init(.{ .plain = "", .resources = &resources });
    const image = imageFor("c\\69 d:picture&#64;example.test", null, &context);
    try std.testing.expect(image != null);
    try std.testing.expect(imageFor("CID:picture%40example.test", null, &context) != null);
}

test "preview file: symlink targets are refused and output overflow keeps the old preview" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "private", .fromMode(0o700));
    const directory = try temporary.dir.openDir(io, "private", .{ .iterate = true });
    defer directory.close(io);
    const target = try directory.createFile(io, "sentinel", .{ .permissions = .fromMode(0o600) });
    try target.writeStreamingAll(io, "Preserve existing target.");
    target.close(io);
    try directory.symLink(io, "sentinel", filename, .{});
    try std.testing.expectError(error.UnsafePreviewPath, writePreview(io, std.testing.allocator, directory, .{ .plain = "Never written" }, .{}));
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Preserve existing target.", try directory.readFile(io, "sentinel", &bytes));
    try directory.deleteFile(io, filename);
    const first = try writePreview(io, std.testing.allocator, directory, .{ .plain = "Previous preview" }, .{});
    defer std.testing.allocator.free(first.path);
    const html = try std.testing.allocator.alloc(u8, 1000 * "<img src='cid:omagma-logo@omagma.invalid'>".len);
    defer std.testing.allocator.free(html);
    for (0..1000) |index| @memcpy(html[index * "<img src='cid:omagma-logo@omagma.invalid'>".len ..][0.."<img src='cid:omagma-logo@omagma.invalid'>".len], "<img src='cid:omagma-logo@omagma.invalid'>");
    const encoded = try std.testing.allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(logo.png.len));
    defer std.testing.allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, logo.png);
    const resources = [_]t.Attachment{.{ .id = "image", .filename = "logo.png", .mimeType = "image/png", .data = encoded, .contentId = logo.content_id }};
    try std.testing.expectError(error.PreviewTooLarge, writePreview(io, std.testing.allocator, directory, .{ .plain = "", .html = html, .resources = &resources }, .{}));
    const check = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(check);
    const previous = try directory.readFile(io, filename, check);
    try std.testing.expect(std.mem.indexOf(u8, previous, "Previous preview") != null);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(std.mem.eql(u8, entry.name, filename) or std.mem.eql(u8, entry.name, "sentinel"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
