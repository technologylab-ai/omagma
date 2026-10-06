const std = @import("std");
const b = @import("bounded.zig");
const model = @import("model.zig");
const Config = @import("config.zig").Config;
const platform = @import("platform.zig");
pub const Target = struct { url: b.Text(4096) = .{}, profile_arg: b.Text(160) = .{} };
pub fn encode(w: *std.Io.Writer, text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try w.writeByte(c) else try w.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
    }
}
pub fn make(account: *const model.Account, msg: ?*const model.Message, fallback: bool) !Target {
    try b.address(account.address.slice());
    try b.profile(account.profile.slice());
    var t: Target = .{};
    const profile_arg = try std.fmt.bufPrint(&t.profile_arg.bytes, "--profile-directory={s}", .{account.profile.slice()});
    t.profile_arg.len = @intCast(profile_arg.len);
    var w = std.Io.Writer.fixed(&t.url.bytes);
    try w.writeAll("https://mail.google.com/mail/u/0/?authuser=");
    try encode(&w, account.address.slice());
    if (msg) |m| {
        if (!fallback and m.thread_id.len > 0) {
            try b.identifier(m.thread_id.slice());
            try w.writeAll("#all/");
            try encode(&w, m.thread_id.slice());
        } else if (validMessageId(m.message_id.slice())) {
            try w.writeAll("#search/");
            try encode(&w, "rfc822msgid:");
            try encode(&w, std.mem.trim(u8, m.message_id.slice(), "<>"));
        } else try w.writeAll("#inbox");
    } else try w.writeAll("#inbox");
    t.url.len = @intCast(w.buffered().len);
    if (!std.mem.startsWith(u8, t.url.slice(), "https://mail.google.com/mail/u/0/?authuser=")) return error.InvalidTarget;
    return t;
}
pub fn validMessageId(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, "<>");
    if (text.len == 0 or text.len > 512) return false;
    var at: usize = 0;
    for (text) |c| {
        if (c <= 32 or c >= 127 or c == '<' or c == '>' or c == '"' or c == '\\') return false;
        if (c == '@') at += 1;
    }
    return at == 1 and text[0] != '@' and text[text.len - 1] != '@';
}
pub fn checkProfile(io: std.Io, config: *const Config, account: *const model.Account) !void {
    try b.profile(account.profile.slice());
    var path: [4096]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path, "{s}/{s}", .{ config.chrome_data.slice(), account.profile.slice() });
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{}) catch return error.ProfileMissing;
    dir.close(io);
    std.Io.Dir.accessAbsolute(io, config.chrome.slice(), .{ .execute = true }) catch return error.ChromeMissing;
}
pub fn launch(io: std.Io, config: *const Config, account: *const model.Account, target: *const Target) !void {
    try checkProfile(io, config, account);
    try platform.launchDetached(io, &.{ config.chrome.slice(), target.profile_arg.slice(), target.url.slice() });
}

/// Explicit links from the terminal reader use the same account Chrome
/// profile as Gmail. Only complete HTTP(S) URLs can become a launch argument.
pub fn makeUrl(account: *const model.Account, raw: []const u8) !Target {
    try b.address(account.address.slice());
    try b.profile(account.profile.slice());
    if (raw.len == 0 or raw.len > 4096 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidTarget;
    for (raw) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return error.InvalidTarget;
    const uri = std.Uri.parse(raw) catch return error.InvalidTarget;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidTarget;
    if (uri.user != null or uri.password != null) return error.InvalidTarget;
    const host = uri.host orelse return error.InvalidTarget;
    var host_buffer: [1024]u8 = undefined;
    const decoded_host = host.toRaw(&host_buffer) catch return error.InvalidTarget;
    if (decoded_host.len == 0) return error.InvalidTarget;
    for (decoded_host) |byte| if (byte <= 32 or byte == 127 or std.mem.indexOfScalar(u8, "@/\\?#<>\"", byte) != null) return error.InvalidTarget;
    var target: Target = .{};
    try target.url.set(raw);
    const profile_argument = try std.fmt.bufPrint(&target.profile_arg.bytes, "--profile-directory={s}", .{account.profile.slice()});
    target.profile_arg.len = @intCast(profile_argument.len);
    return target;
}

/// The caller chose this saved file explicitly. Do not delegate executable or
/// active-document types to desktop associations from the mail reader.
pub fn openSavedAttachment(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidFilePath;
    const extension = std.fs.path.extension(path);
    var allowed = false;
    for ([_][]const u8{ ".pdf", ".txt", ".md", ".csv", ".png", ".jpg", ".jpeg", ".gif", ".webp" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) allowed = true;
    }
    if (!allowed) return error.AttachmentOpenUnsupported;
    const file = try @import("terminal/files.zig").openRegular(io, allocator, .cwd(), path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureAttachmentFile;
    try platform.launchDetached(io, &.{ "/usr/bin/xdg-open", path });
}

test "reader links retain account profile and reject active schemes credentials and controls" {
    var account: model.Account = .{};
    try account.address.set("work@example.com");
    try account.profile.set("Profile 2");
    const target = try makeUrl(&account, "https://example.org/document?id=42#section");
    try std.testing.expectEqualStrings("--profile-directory=Profile 2", target.profile_arg.slice());
    try std.testing.expectEqualStrings("https://example.org/document?id=42#section", target.url.slice());
    for ([_][]const u8{ "javascript:alert(1)", "file:///tmp/file", "https://user:password@example.org/", "https:///empty-host", "https://example.org/\n", "https://example.org\\evil", "https://example%40other.org/" }) |url| {
        try std.testing.expectError(error.InvalidTarget, makeUrl(&account, url));
    }
}
test "account-specific Chrome argv and Message-ID fallback" {
    var a: model.Account = .{};
    try a.address.set("work@example.com");
    try a.profile.set("Profile 1");
    var m: model.Message = .{};
    try m.thread_id.set("abc123");
    try m.message_id.set("<a+b@example.com>");
    var t = try make(&a, &m, false);
    try std.testing.expectEqualStrings("--profile-directory=Profile 1", t.profile_arg.slice());
    try std.testing.expectEqualStrings("https://mail.google.com/mail/u/0/?authuser=work%40example.com#all/abc123", t.url.slice());
    t = try make(&a, &m, true);
    try std.testing.expect(std.mem.endsWith(u8, t.url.slice(), "#search/rfc822msgid%3Aa%2Bb%40example.com"));
    try m.thread_id.set("../../evil");
    try std.testing.expectError(error.InvalidIdentifier, make(&a, &m, false));
}
