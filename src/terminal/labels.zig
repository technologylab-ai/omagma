const std = @import("std");
const storage = @import("store.zig");
const bounded = @import("../bounded.zig");
const t = @import("types.zig");
const j = @import("json.zig");

/// Gmail's documented palette, shared by CLI, API and TUI. Both fields are
/// required by users.labels; arbitrary RGB values must fail before mutation.
/// https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels#Color
pub const palette = [_][]const u8{
    "#000000", "#434343", "#666666", "#999999", "#cccccc", "#efefef", "#f3f3f3", "#ffffff",
    "#fb4c2f", "#ffad47", "#fad165", "#16a766", "#43d692", "#4a86e8", "#a479e2", "#f691b3",
    "#f6c5be", "#ffe6c7", "#fef1d1", "#b9e4d0", "#c6f3de", "#c9daf8", "#e4d7f5", "#fcdee8",
    "#efa093", "#ffd6a2", "#fce8b3", "#89d3b2", "#a0eac9", "#a4c2f4", "#d0bcf1", "#fbc8d9",
    "#e66550", "#ffbc6b", "#fcda83", "#44b984", "#68dfa9", "#6d9eeb", "#b694e8", "#f7a7c0",
    "#cc3a21", "#eaa041", "#f2c960", "#149e60", "#3dc789", "#3c78d8", "#8e63ce", "#e07798",
    "#ac2b16", "#cf8933", "#d5ae49", "#0b804b", "#2a9c68", "#285bac", "#653e9b", "#b65775",
    "#822111", "#a46a21", "#aa8831", "#076239", "#1a764d", "#1c4587", "#41236d", "#83334c",
    "#464646", "#e7e7e7", "#0d3472", "#b6cff5", "#0d3b44", "#98d7e4", "#3d188e", "#e3d7ff",
    "#711a36", "#fbd3e0", "#8a1c0a", "#f2b2a8", "#7a2e0b", "#ffc8af", "#7a4706", "#ffdeb5",
    "#594c05", "#fbe983", "#684e07", "#fdedc1", "#0b4f30", "#b3efd3", "#04502e", "#a2dcc1",
    "#c2c2c2", "#4986e7", "#2da2bb", "#b99aff", "#994a64", "#f691b2", "#ff7537", "#ffad46",
    "#662e37", "#ebdbde", "#cca6ac", "#094228", "#42d692", "#16a765",
};
fn paletteValue(value: []const u8) ![]const u8 {
    for (palette) |allowed| if (std.ascii.eqlIgnoreCase(value, allowed)) return allowed;
    return error.InvalidLabelColor;
}
pub fn color(value: t.LabelColor) !t.LabelColor {
    return .{ .backgroundColor = try paletteValue(value.backgroundColor), .textColor = try paletteValue(value.textColor) };
}
pub fn requestColor(a: std.mem.Allocator, request: j.Value) !?t.LabelColor {
    const value = j.get(request, "color") orelse return null;
    return try color(j.decode(t.LabelColor, a, value) catch return error.InvalidLabelColor);
}
pub fn sameColor(left: ?t.LabelColor, right: ?t.LabelColor) bool {
    if (left) |l| {
        const r = right orelse return false;
        return std.ascii.eqlIgnoreCase(l.backgroundColor, r.backgroundColor) and std.ascii.eqlIgnoreCase(l.textColor, r.textColor);
    }
    return right == null;
}

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

test "label collection: bounded documented palette requires both colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = (try requestColor(a, try j.value(a, .{ .color = .{ .backgroundColor = "#FB4C2F", .textColor = "#ffffff" } }))).?;
    try std.testing.expectEqualStrings("#fb4c2f", parsed.backgroundColor);
    try std.testing.expectError(error.InvalidLabelColor, requestColor(a, try j.value(a, .{ .color = .{ .backgroundColor = "#123456", .textColor = "#ffffff" } })));
    try std.testing.expectError(error.InvalidLabelColor, requestColor(a, try j.value(a, .{ .color = .{ .backgroundColor = "#fb4c2f" } })));
}
