const std = @import("std");
const storage = @import("store.zig");
const bounded = @import("../bounded.zig");

/// System identities and friendly names are reserved. Provider type remains
/// authoritative for additional system labels not listed here.
pub fn reserved(name: []const u8) bool {
    for ([_][]const u8{ "INBOX", "SENT", "DRAFT", "DRAFTS", "TRASH", "SPAM", "UNREAD", "STARRED", "IMPORTANT", "CHAT", "CHATS", "YELLOW_STAR", "ALL", "ALL MAIL", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS" }) |system| {
        if (std.ascii.eqlIgnoreCase(name, system)) return true;
    }
    return false;
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 256 or !std.unicode.utf8ValidateSlice(name) or std.mem.trim(u8, name, " \t\r\n").len != name.len) return error.InvalidLabelName;
    const view = std.unicode.Utf8View.initUnchecked(name);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x2028 or cp == 0x2029 or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return error.InvalidLabelName;
    }
    if (reserved(name)) return error.SystemLabelImmutable;
}

pub fn validateId(id: []const u8) !void {
    try bounded.identifier(id);
    if (reserved(id)) return error.SystemLabelImmutable;
}

pub fn custom(definitions: []const storage.Label, id: []const u8) !storage.Label {
    try validateId(id);
    for (definitions) |label| if (std.mem.eql(u8, label.id, id)) {
        if (!std.ascii.eqlIgnoreCase(label.type, "user") or reserved(label.name)) return error.SystemLabelImmutable;
        return label;
    };
    return error.LabelNotFound;
}

pub fn unique(definitions: []const storage.Label, name: []const u8, except_id: []const u8) !void {
    try validateName(name);
    for (definitions) |label| {
        if (!std.mem.eql(u8, label.id, except_id) and std.ascii.eqlIgnoreCase(label.name, name)) return if (std.ascii.eqlIgnoreCase(label.type, "system")) error.SystemLabelImmutable else error.DuplicateLabelName;
    }
}

test "label collection: UTF-8 names controls reserved names and strict custom identities" {
    try validateName("Travel/Österreich 🌋");
    try std.testing.expectError(error.InvalidLabelName, validateName(""));
    try std.testing.expectError(error.InvalidLabelName, validateName(" trailing "));
    try std.testing.expectError(error.InvalidLabelName, validateName("name\r\nBcc: other@example.test"));
    try std.testing.expectError(error.InvalidLabelName, validateName("bad\xc2\x85name"));
    try std.testing.expectError(error.SystemLabelImmutable, validateName("inbox"));
    const definitions = [_]storage.Label{ .{ .id = "Label_7", .name = "Project", .type = "user" }, .{ .id = "SOME_SYSTEM", .name = "Provider system", .type = "system" } };
    try std.testing.expectError(error.SystemLabelImmutable, custom(&definitions, "SOME_SYSTEM"));
    try std.testing.expectError(error.DuplicateLabelName, unique(&definitions, "project", ""));
    try unique(&definitions, "Project", "Label_7");
}
