const std = @import("std");
const files = @import("files.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const b = @import("../bounded.zig");

pub const Action = enum { down, up, left, right, next_mail, previous_mail, compose, reply, reply_all, contacts, cache_search, server_search, layout, expand, help, thread_next, thread_previous, thread_fold, quote_fold, signature_fold, links, attachments };
pub const Context = struct { account: b.Text(254) = .{}, folder: u8 = 0, label: b.Text(256) = .{}, message: b.Text(256) = .{}, selected: u32 = 0, readerScroll: u32 = 0 };
pub const Binding = struct { key: b.Text(24) = .{}, action: Action };
pub const Preferences = struct {
    schema: u8 = 1,
    theme: theme.Mode = .follow_omarchy,
    readerLayout: layout.ReaderLayout = .right,
    listWidthPercent: u8 = 55,
    listHeightPercent: u8 = 40,
    lastAccount: b.Text(254) = .{},
    contexts: [3]?Context = @splat(null),
    bindings: [24]?Binding = @splat(null),
};
const max_bytes = 16384;
const ContextWire = struct { account: []const u8, folder: u8 = 0, label: []const u8 = "", message: []const u8 = "", selected: u32 = 0, readerScroll: u32 = 0 };
const BindingWire = struct { key: []const u8, action: Action };
const Wire = struct { schema: u8 = 1, theme: theme.Mode = .follow_omarchy, readerLayout: layout.ReaderLayout = .right, listWidthPercent: u8 = 55, listHeightPercent: u8 = 40, lastAccount: []const u8 = "", contexts: []const ContextWire = &.{}, bindings: []const BindingWire = &.{} };

pub fn validKey(key: []const u8) bool {
    const character = if (std.mem.startsWith(u8, key, "Ctrl+")) key[5..] else key;
    if (character.len != 1 or character[0] < 33 or character[0] > 126) return false;
    if (std.mem.eql(u8, key, "q") or std.ascii.eqlIgnoreCase(key, "Ctrl+c") or std.ascii.eqlIgnoreCase(key, "Ctrl+s")) return false;
    return true;
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Preferences {
    if (bytes.len > max_bytes) return error.UiPreferencesTooLarge;
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .max_value_len = max_bytes });
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedUiPreferences;
    const wire = parsed.value;
    if (wire.listWidthPercent < 25 or wire.listWidthPercent > 75 or wire.listHeightPercent < 25 or wire.listHeightPercent > 75) return error.InvalidPaneRatio;
    if (wire.contexts.len > 3 or wire.bindings.len > 24) return error.UiPreferencesTooManyEntries;
    var result: Preferences = .{ .theme = wire.theme, .readerLayout = wire.readerLayout, .listWidthPercent = wire.listWidthPercent, .listHeightPercent = wire.listHeightPercent };
    if (wire.lastAccount.len > 0) try b.address(wire.lastAccount);
    try result.lastAccount.set(wire.lastAccount);
    for (wire.contexts, 0..) |entry, index| {
        try b.address(entry.account);
        if (entry.folder >= 8 or entry.selected >= 10000 or entry.readerScroll > 10000000) return error.InvalidWorkingContext;
        var context: Context = .{ .folder = entry.folder, .selected = entry.selected, .readerScroll = entry.readerScroll };
        try context.account.set(entry.account);
        try context.label.set(entry.label);
        try context.message.set(entry.message);
        for (wire.contexts[0..index]) |prior| if (std.mem.eql(u8, prior.account, entry.account)) return error.DuplicateWorkingContext;
        result.contexts[index] = context;
    }
    for (wire.bindings, 0..) |entry, index| {
        if (!validKey(entry.key)) return error.InvalidKeyBinding;
        var binding: Binding = .{ .action = entry.action };
        try binding.key.set(entry.key);
        for (wire.bindings[0..index]) |prior| if (std.mem.eql(u8, prior.key, entry.key)) return error.DuplicateKeyBinding;
        result.bindings[index] = binding;
    }
    return result;
}

pub fn encode(allocator: std.mem.Allocator, value: *const Preferences) ![]const u8 {
    var contexts: [3]ContextWire = undefined;
    var context_count: usize = 0;
    for (&value.contexts) |*entry| if (entry.*) |*context| {
        contexts[context_count] = .{ .account = context.account.slice(), .folder = context.folder, .label = context.label.slice(), .message = context.message.slice(), .selected = context.selected, .readerScroll = context.readerScroll };
        context_count += 1;
    };
    var bindings: [24]BindingWire = undefined;
    var binding_count: usize = 0;
    for (&value.bindings) |*entry| if (entry.*) |*binding| {
        bindings[binding_count] = .{ .key = binding.key.slice(), .action = binding.action };
        binding_count += 1;
    };
    return std.json.Stringify.valueAlloc(allocator, Wire{ .theme = value.theme, .readerLayout = value.readerLayout, .listWidthPercent = value.listWidthPercent, .listHeightPercent = value.listHeightPercent, .lastAccount = value.lastAccount.slice(), .contexts = contexts[0..context_count], .bindings = bindings[0..binding_count] }, .{});
}

pub fn path(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, explicit: ?[]const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    const chosen = explicit orelse blk: {
        const home = environ.get("HOME") orelse return error.HomeRequired;
        const directory = environ.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(temp, "{s}/.config", .{home});
        break :blk try std.fmt.allocPrint(temp, "{s}/omagma/ui.json", .{directory});
    };
    if (!std.fs.path.isAbsolute(chosen) or chosen.len > 4096 or std.mem.indexOfScalar(u8, chosen, 0) != null) return error.InvalidUiPreferencesPath;
    return allocator.dupe(u8, chosen);
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, filename: []const u8) !Preferences {
    const file = files.openRegular(io, allocator, .cwd(), filename) catch |err| if (err == error.FileNotFound) return .{} else return err;
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureUiPreferences;
    if (stat.size > max_bytes) return error.UiPreferencesTooLarge;
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, filename: []const u8, value: Preferences) !void {
    if (!std.fs.path.isAbsolute(filename) or filename.len > 4096 or std.mem.indexOfScalar(u8, filename, 0) != null) return error.InvalidUiPreferencesPath;
    // Revalidate an existing file: malformed or insecure settings are never
    // silently replaced merely because the running UI chose its fallback.
    _ = try load(io, allocator, filename);
    const parent = std.fs.path.dirname(filename) orelse return error.InvalidUiPreferencesPath;
    const basename = std.fs.path.basename(filename);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidUiPreferencesPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureUiPreferencesDirectory;
    const bytes = try encode(allocator, &value);
    defer allocator.free(bytes);
    var atomic = try dir.createFileAtomic(io, basename, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

test "reader preferences roundtrip only schema and validated layout" {
    const allocator = std.testing.allocator;
    const right = try parse(allocator, "{\"schema\":1,\"readerLayout\":\"right\"}");
    const below = try parse(allocator, "{\"schema\":1,\"readerLayout\":\"below\"}");
    try std.testing.expectEqual(layout.ReaderLayout.right, right.readerLayout);
    try std.testing.expectEqual(layout.ReaderLayout.below, below.readerLayout);
    const encoded = try encode(allocator, &below);
    defer allocator.free(encoded);
    try std.testing.expectEqual(layout.ReaderLayout.below, (try parse(allocator, encoded)).readerLayout);
    try std.testing.expectError(error.UnsupportedUiPreferences, parse(allocator, "{\"schema\":2}"));
    try std.testing.expectError(error.InvalidEnumTag, parse(allocator, "{\"readerLayout\":\"overlay\"}"));
    try std.testing.expectError(error.UnknownField, parse(allocator, "{\"account\":\"personal@example.com\"}"));
}

test "local UI: theme choice survives private preference encoding and old settings follow Omarchy" {
    const allocator = std.testing.allocator;
    const old = try parse(allocator, "{\"schema\":1,\"readerLayout\":\"below\"}");
    try std.testing.expectEqual(theme.Mode.follow_omarchy, old.theme);
    const chosen = try parse(allocator, "{\"schema\":1,\"theme\":\"omagma\",\"listWidthPercent\":60}");
    const encoded = try encode(allocator, &chosen);
    defer allocator.free(encoded);
    const restored = try parse(allocator, encoded);
    try std.testing.expectEqual(theme.Mode.omagma, restored.theme);
    try std.testing.expectEqual(@as(u8, 60), restored.listWidthPercent);
    try std.testing.expectError(error.InvalidEnumTag, parse(allocator, "{\"theme\":\"not-a-theme\"}"));
}

test "local reader: working contexts and keys own parsed strings and preserve bounded ratios" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "{\"readerLayout\":\"below\",\"listWidthPercent\":60,\"contexts\":[{\"account\":\"personal@example.test\",\"folder\":1,\"message\":\"mail-42\",\"selected\":7,\"readerScroll\":19}],\"bindings\":[{\"key\":\"n\",\"action\":\"down\"}]}");
    try std.testing.expectEqualStrings("personal@example.test", value.contexts[0].?.account.slice());
    try std.testing.expectEqualStrings("mail-42", value.contexts[0].?.message.slice());
    const encoded = try encode(allocator, &value);
    defer allocator.free(encoded);
    const roundtrip = try parse(allocator, encoded);
    try std.testing.expectEqual(@as(u32, 19), roundtrip.contexts[0].?.readerScroll);
    try std.testing.expectEqualStrings("n", roundtrip.bindings[0].?.key.slice());
    try std.testing.expectError(error.InvalidPaneRatio, parse(allocator, "{\"listWidthPercent\":99}"));
    try std.testing.expectError(error.InvalidKeyBinding, parse(allocator, "{\"bindings\":[{\"key\":\"Ctrl+s\",\"action\":\"down\"}]}"));
}
