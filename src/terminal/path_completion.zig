//! Bounded native path completion and safe, literal received-file defaults.
//! No shell expansion, recursive walk, executable helper or symlink following.
const std = @import("std");
const files = @import("files.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const max_matches = 64;
pub const max_entries = 4096;
pub const max_path = 4096;
pub const Candidate = struct { path: []const u8, name: []const u8, directory: bool };
pub const Result = struct { path: ?[]const u8, matches: usize, truncated: bool };

fn validPath(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > max_path or !std.unicode.utf8ValidateSlice(raw)) return false;
    for (raw) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}

/// Open each directory component separately with NOFOLLOW. The resulting
/// descriptor remains tied to the checked directory even if a path is renamed.
pub fn openDirectory(io: Io, raw: []const u8, create: bool) !Io.Dir {
    if (!validPath(raw)) return error.InvalidFilePath;
    var dir = try Io.Dir.cwd().openDir(io, if (std.fs.path.isAbsolute(raw)) "/" else ".", .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, raw, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        depth += 1;
        if (depth > 128) return error.PathTooDeep;
        const next = dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false }) catch |err| next: {
            if (!create or err != error.FileNotFound or std.mem.eql(u8, part, "..")) return err;
            dir.createDir(io, part, .fromMode(0o700)) catch |mkdir_err| if (mkdir_err != error.PathAlreadyExists) return mkdir_err;
            break :next try dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        };
        dir.close(io);
        dir = next;
    }
    return dir;
}

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    candidates: []const Candidate = &.{},
    selected: ?usize = null,
    truncated: bool = false,
    last: [max_path]u8 = undefined,
    last_len: usize = 0,

    pub fn deinit(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn reset(self: *State) void {
        if (self.arena) |*arena| _ = arena.reset(.retain_capacity);
        self.candidates = &.{};
        self.selected = null;
        self.truncated = false;
        self.last_len = 0;
    }
    pub fn active(self: *const State, input: []const u8) bool {
        return self.candidates.len > 0 and std.mem.eql(u8, self.last[0..self.last_len], input);
    }
    fn remember(self: *State, input: []const u8) void {
        std.debug.assert(input.len <= self.last.len);
        @memcpy(self.last[0..input.len], input);
        self.last_len = input.len;
    }
    pub fn tab(self: *State, io: Io, allocator: Allocator, input: []const u8) !Result {
        if (input.len > max_path or (input.len > 0 and !validPath(input))) return error.InvalidFilePath;
        if (self.active(input) and self.candidates.len > 1) {
            const next = if (self.selected) |index| (index + 1) % self.candidates.len else 0;
            self.selected = next;
            const path = self.candidates[next].path;
            self.remember(path);
            return .{ .path = path, .matches = self.candidates.len, .truncated = self.truncated };
        }
        self.reset();
        if (self.arena == null) self.arena = .init(allocator);
        const a = self.arena.?.allocator();
        const slash = std.mem.lastIndexOfScalar(u8, input, '/');
        const prefix = if (slash) |index| input[0 .. index + 1] else "";
        const fragment = if (slash) |index| input[index + 1 ..] else input;
        var dir = try openDirectory(io, if (prefix.len > 0) prefix else ".", false);
        defer dir.close(io);
        var entries: std.ArrayList(Candidate) = .empty;
        var iterator = dir.iterate();
        var scanned: usize = 0;
        while (scanned < max_entries) : (scanned += 1) {
            const entry = (try iterator.next(io)) orelse break;
            if (!std.ascii.startsWithIgnoreCase(entry.name, fragment) or !validPath(entry.name) or (fragment.len == 0 and std.mem.startsWith(u8, entry.name, "."))) continue;
            const kind = if (entry.kind == .unknown) (try dir.statFile(io, entry.name, .{ .follow_symlinks = false })).kind else entry.kind;
            if (kind != .directory and kind != .file) continue;
            if (entries.items.len >= max_matches) {
                self.truncated = true;
                break;
            }
            const path = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, entry.name, if (kind == .directory) @as([]const u8, "/") else "" });
            if (path.len > max_path) continue;
            try entries.append(a, .{ .path = path, .name = try a.dupe(u8, entry.name), .directory = kind == .directory });
        }
        if (scanned == max_entries) self.truncated = true;
        std.mem.sort(Candidate, entries.items, {}, struct {
            fn less(_: void, left: Candidate, right: Candidate) bool {
                if (left.directory != right.directory) return left.directory;
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.less);
        self.candidates = entries.items;
        if (entries.items.len == 0) return .{ .path = null, .matches = 0, .truncated = self.truncated };
        if (entries.items.len == 1) {
            const path = entries.items[0].path;
            self.selected = 0;
            self.remember(path);
            return .{ .path = path, .matches = 1, .truncated = self.truncated };
        }
        var common = entries.items[0].path.len;
        for (entries.items[1..]) |entry| {
            common = @min(common, entry.path.len);
            var index: usize = 0;
            while (index < common and std.ascii.toLower(entries.items[0].path[index]) == std.ascii.toLower(entry.path[index])) : (index += 1) {}
            common = index;
        }
        while (common > 0 and !std.unicode.utf8ValidateSlice(entries.items[0].path[0..common])) common -= 1;
        const path = if (common > input.len) entries.items[0].path[0..common] else input;
        self.remember(path);
        return .{ .path = path, .matches = entries.items.len, .truncated = self.truncated };
    }
    pub fn shiftTab(self: *State, io: Io, allocator: Allocator, input: []const u8) !Result {
        if (!self.active(input) or self.candidates.len <= 1) _ = try self.tab(io, allocator, input);
        if (self.candidates.len == 0) return .{ .path = null, .matches = 0, .truncated = self.truncated };
        const selected = if (self.selected) |index| (index + self.candidates.len - 1) % self.candidates.len else self.candidates.len - 1;
        self.selected = selected;
        const path = self.candidates[selected].path;
        self.remember(path);
        return .{ .path = path, .matches = self.candidates.len, .truncated = self.truncated };
    }
};

pub fn filename(allocator: Allocator, raw: []const u8) ![]u8 {
    var offset: usize = 0;
    for (raw, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') offset = index + 1;
    }
    const base = std.mem.trim(u8, raw[offset..], " .\t\r\n");
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (base[0..@min(base.len, 200)]) |byte| if (byte >= 32 and byte != 127) try result.append(allocator, byte);
    while (result.items.len > 0 and !std.unicode.utf8ValidateSlice(result.items)) result.items.len -= 1;
    if (result.items.len == 0) try result.appendSlice(allocator, "attachment");
    return result.toOwnedSlice(allocator);
}

fn configuredDownloads(allocator: Allocator, raw: []const u8, home: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equal], " \t"), "XDG_DOWNLOAD_DIR")) continue;
        const quoted = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') continue;
        const value = quoted[1 .. quoted.len - 1];
        // This single standard user-dirs HOME token is parsed as data. The
        // attachment input itself never expands variables or quoted strings.
        if (std.mem.startsWith(u8, value, "$HOME/")) {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, value[6..] });
            if (validPath(path)) return path;
            allocator.free(path);
        } else if (validPath(value) and std.fs.path.isAbsolute(value)) return try allocator.dupe(u8, value);
    }
    return null;
}

pub fn downloadsDirectory(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const home = environ.get("HOME") orelse return error.HomeRequired;
    if (!validPath(home) or !std.fs.path.isAbsolute(home)) return error.InvalidHome;
    if (environ.get("XDG_DOWNLOAD_DIR")) |directory| if (validPath(directory) and std.fs.path.isAbsolute(directory)) return allocator.dupe(u8, directory);
    const config = environ.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (environ.get("XDG_CONFIG_HOME") == null) allocator.free(config);
    const path = try std.fmt.allocPrint(allocator, "{s}/user-dirs.dirs", .{config});
    defer allocator.free(path);
    const raw = files.readBounded(io, allocator, Io.Dir.cwd(), path, 4096) catch null;
    if (raw) |bytes| {
        defer allocator.free(bytes);
        if (try configuredDownloads(allocator, bytes, home)) |directory| return directory;
    }
    return std.fmt.allocPrint(allocator, "{s}/Downloads", .{home});
}

pub fn freshDestination(io: Io, allocator: Allocator, directory: []const u8, raw_name: []const u8) ![]u8 {
    if (!validPath(directory) or !std.fs.path.isAbsolute(directory)) return error.InvalidFilePath;
    const name = try filename(allocator, raw_name);
    defer allocator.free(name);
    var dir = openDirectory(io, directory, false) catch |err| {
        if (err == error.FileNotFound) return std.fs.path.join(allocator, &.{ directory, name });
        return err;
    };
    defer dir.close(io);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    const split = if (dot > 0 and name.len - dot <= 32) dot else name.len;
    for (0..1000) |number| {
        const candidate = if (number == 0) try allocator.dupe(u8, name) else try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ name[0..split], number, name[split..] });
        defer allocator.free(candidate);
        _ = dir.statFile(io, candidate, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return std.fs.path.join(allocator, &.{ directory, candidate });
            return err;
        };
    }
    return error.DownloadNameQuotaExceeded;
}

/// Called only after explicit Save. O_EXCL and checked parent descriptors
/// preserve no-overwrite and no-symlink behavior even across path replacement.
pub const Created = struct {
    file: Io.File,
    directory: Io.Dir,
    leaf: []const u8,
    pub fn close(self: Created, io: Io) void {
        self.file.close(io);
        self.directory.close(io);
    }
    pub fn remove(self: Created, io: Io) void {
        self.directory.deleteFile(io, self.leaf) catch {};
    }
};
pub fn createExclusive(io: Io, path: []const u8) !Created {
    if (!validPath(path) or !std.fs.path.isAbsolute(path)) return error.InvalidFilePath;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidFilePath;
    const leaf = std.fs.path.basename(path);
    if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidFilePath;
    var directory = try openDirectory(io, parent, false);
    errdefer directory.close(io);
    const file = try directory.createFile(io, leaf, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    return .{ .file = file, .directory = directory, .leaf = leaf };
}

test "path completion: common prefix and cycling are literal bounded and skip symlinks" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ "alpha report.txt", "alpha-summary.txt" }) |name| {
        const file = try temporary.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    try temporary.dir.symLink(std.testing.io, "alpha report.txt", "alpha-link", .{});
    const prefix = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/alp", .{temporary.sub_path});
    defer allocator.free(prefix);
    var state: State = .{};
    defer state.deinit();
    const first = try state.tab(std.testing.io, allocator, prefix);
    try std.testing.expectEqual(@as(usize, 2), first.matches);
    try std.testing.expect(std.mem.endsWith(u8, first.path.?, "/alpha"));
    const copied = try allocator.dupe(u8, first.path.?);
    defer allocator.free(copied);
    const second = try state.tab(std.testing.io, allocator, copied);
    try std.testing.expect(std.mem.endsWith(u8, second.path.?, "/alpha report.txt"));
    for (0..200) |_| {
        const input = try allocator.dupe(u8, state.last[0..state.last_len]);
        defer allocator.free(input);
        const next = try state.tab(std.testing.io, allocator, input);
        try std.testing.expectEqual(@as(usize, 2), next.matches);
    }
}
test "path completion: safe defaults preserve names and add nonexisting collision suffix" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const file = try temporary.dir.createFile(std.testing.io, "report.pdf", .{});
    file.close(std.testing.io);
    const destination = try freshDestination(std.testing.io, allocator, root, "../../report.pdf");
    defer allocator.free(destination);
    try std.testing.expect(std.mem.endsWith(u8, destination, "/report (1).pdf"));
    const created = try createExclusive(std.testing.io, destination);
    created.close(std.testing.io);
    try std.testing.expectError(error.PathAlreadyExists, createExclusive(std.testing.io, destination));
    const parsed = (try configuredDownloads(allocator, "XDG_DOWNLOAD_DIR=\"$HOME/My Downloads\"\n", root)).?;
    defer allocator.free(parsed);
    try std.testing.expect(std.mem.endsWith(u8, parsed, "/My Downloads"));
}

test "path completion: lowercase prefixes find exact filename spelling and mixed-case choices" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "README.md", .{});
    file.close(std.testing.io);
    const prefix = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/rea", .{temporary.sub_path});
    defer a.free(prefix);
    var state: State = .{};
    defer state.deinit();
    const unique = try state.tab(std.testing.io, a, prefix);
    try std.testing.expectEqual(@as(usize, 1), unique.matches);
    try std.testing.expect(std.mem.endsWith(u8, unique.path.?, "/README.md"));
    const second = try temporary.dir.createFile(std.testing.io, "readme.txt", .{});
    second.close(std.testing.io);
    state.reset();
    const common = try state.tab(std.testing.io, a, prefix);
    try std.testing.expectEqual(@as(usize, 2), common.matches);
    try std.testing.expect(std.mem.endsWith(u8, common.path.?, "/README."));
    const copied = try a.dupe(u8, common.path.?);
    defer a.free(copied);
    const chosen = try state.tab(std.testing.io, a, copied);
    try std.testing.expect(std.mem.endsWith(u8, chosen.path.?, "/README.md"));
}

test "path completion: candidate quota and symlink parent refusal stay bounded" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for (0..70) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "entry-{d:0>2}.txt", .{index});
        const file = try temporary.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    const prefix = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/entry-", .{temporary.sub_path});
    defer allocator.free(prefix);
    var state: State = .{};
    defer state.deinit();
    const found = try state.tab(std.testing.io, allocator, prefix);
    try std.testing.expectEqual(@as(usize, max_matches), found.matches);
    try std.testing.expect(found.truncated);
    try temporary.dir.createDir(std.testing.io, "real", .fromMode(0o700));
    try temporary.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });
    const link = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/link", .{temporary.sub_path});
    defer allocator.free(link);
    var blocked = false;
    if (openDirectory(std.testing.io, link, false)) |directory| directory.close(std.testing.io) else |_| blocked = true;
    try std.testing.expect(blocked);
}
