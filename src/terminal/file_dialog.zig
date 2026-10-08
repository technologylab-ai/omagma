//! An on-demand, bounded local file-browser snapshot. Names and paths are
//! owned by this state; no iterator name or open directory survives a refresh.
//! Files are opened and destinations created only by the existing backend.
const std = @import("std");
const completion = @import("path_completion.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_entries = 128;
pub const max_scanned = 4096;
pub const max_path = completion.max_path;
pub const max_name = 255;
pub const max_filter = 255;
pub const Mode = enum { open, save };
pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    directory: bool,
    /// Read-only metadata, never an authorization to open a mutable path.
    size: ?u64 = null,
};

/// The browser rejects controls rather than changing an on-disk filename.
/// In particular, rendering a sanitized name must never choose another file.
pub fn validText(raw: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(raw)) return false;
    var iterator = std.unicode.Utf8View.initUnchecked(raw).iterator();
    while (iterator.nextCodepoint()) |cp| {
        if (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x061c or
            cp == 0x200e or cp == 0x200f or cp == 0x2028 or cp == 0x2029 or
            (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return false;
    }
    return true;
}

fn validPath(raw: []const u8) bool {
    return raw.len > 0 and raw.len <= max_path and validText(raw);
}

fn validName(raw: []const u8) bool {
    return raw.len > 0 and raw.len <= max_name and validText(raw) and
        std.mem.indexOfScalar(u8, raw, '/') == null and
        !std.mem.eql(u8, raw, ".") and !std.mem.eql(u8, raw, "..");
}

fn matches(name: []const u8, filter: []const u8) bool {
    if (filter.len > name.len) return false;
    for (0..name.len - filter.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(name[offset .. offset + filter.len], filter)) return true;
    }
    return false;
}

// Normalize only after openDirectory has checked the original components.
// Normalizing first could silently remove a refused symlink/.. component.
fn normalized(raw: []const u8, storage: *[max_path]u8) ![]const u8 {
    const absolute = std.fs.path.isAbsolute(raw);
    var length: usize = 0;
    if (absolute) {
        storage[0] = '/';
        length = 1;
    }
    var starts: [128]usize = undefined;
    var depth: usize = 0;
    var parts = std.mem.splitScalar(u8, raw, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (depth > 0 and !std.mem.eql(u8, storage[starts[depth - 1]..length], "..")) {
                depth -= 1;
                length = if (starts[depth] == 0) 0 else starts[depth] - 1;
                if (absolute and length == 0) length = 1;
                continue;
            }
            if (absolute and depth == 0) continue;
        }
        if (depth == starts.len) return error.PathTooDeep;
        if (length > 0 and storage[length - 1] != '/') {
            if (length == storage.len) return error.InvalidFilePath;
            storage[length] = '/';
            length += 1;
        }
        if (part.len > storage.len - length) return error.InvalidFilePath;
        starts[depth] = length;
        depth += 1;
        @memcpy(storage[length .. length + part.len], part);
        length += part.len;
    }
    if (length == 0) {
        storage[0] = '.';
        length = 1;
    }
    return storage[0..length];
}

fn joined(directory: []const u8, name: []const u8, storage: *[max_path]u8) ![]const u8 {
    const slash: []const u8 = if (std.mem.endsWith(u8, directory, "/")) "" else "/";
    if (directory.len + slash.len + name.len > storage.len) return error.InvalidFilePath;
    return std.fmt.bufPrint(storage, "{s}{s}{s}", .{ directory, slash, name });
}

const Retained = struct {
    name_storage: [max_name]u8 = undefined,
    name_len: usize,
    directory: bool,
    size: ?u64 = null,

    fn name(self: *const Retained) []const u8 {
        return self.name_storage[0..self.name_len];
    }
    fn less(_: void, left: Retained, right: Retained) bool {
        if (left.directory != right.directory) return left.directory;
        return std.mem.lessThan(u8, left.name(), right.name());
    }
};

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    mode: Mode = .open,
    entries: []const Entry = &.{},
    selected: usize = 0,
    show_hidden: bool = false,
    /// All names examined, including hidden and unsupported entries.
    scanned: usize = 0,
    /// Supported, visible matches in the scanned part of the directory.
    matching: usize = 0,
    /// Counts are lower bounds when the scan ceiling was reached.
    scan_limited: bool = false,
    truncated: bool = false,
    directory_storage: [max_path]u8 = undefined,
    directory_len: usize = 0,
    filename_storage: [max_name]u8 = undefined,
    filename_len: usize = 0,
    filter_storage: [max_filter]u8 = undefined,
    filter_len: usize = 0,
    destination_storage: [max_path]u8 = undefined,

    pub fn deinit(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn reset(self: *State) void {
        if (self.arena) |*arena| _ = arena.reset(.retain_capacity);
        self.entries = &.{};
        self.selected = 0;
        self.show_hidden = false;
        self.scanned = 0;
        self.matching = 0;
        self.scan_limited = false;
        self.truncated = false;
        self.directory_len = 0;
        self.filename_len = 0;
        self.filter_len = 0;
    }

    pub fn directory(self: *const State) []const u8 {
        return self.directory_storage[0..self.directory_len];
    }

    pub fn filename(self: *const State) []const u8 {
        return self.filename_storage[0..self.filename_len];
    }

    pub fn filter(self: *const State) []const u8 {
        return self.filter_storage[0..self.filter_len];
    }

    /// Start with an existing directory, or a literal file path whose parent
    /// exists. Save may prefill a nonexistent leaf. This never creates a dir.
    pub fn open(self: *State, io: Io, allocator: Allocator, mode: Mode, initial_path: []const u8) !void {
        const raw = if (initial_path.len == 0) "." else initial_path;
        if (!validPath(raw)) return error.InvalidFilePath;
        var initial_name: [max_name]u8 = undefined;
        var initial_name_len: usize = 0;
        const direct: ?Io.Dir = completion.openDirectory(io, raw, false) catch |err| blk: {
            if (err != error.NotDir and err != error.FileNotFound) return err;
            const leaf = std.fs.path.basename(raw);
            if (!validName(leaf)) return error.InvalidFileName;
            @memcpy(initial_name[0..leaf.len], leaf);
            initial_name_len = leaf.len;
            const parent_path = std.fs.path.dirname(raw) orelse ".";
            var parent_dir = try completion.openDirectory(io, if (parent_path.len == 0) "." else parent_path, false);
            defer parent_dir.close(io);
            if (mode == .open) {
                const stat = try parent_dir.statFile(io, leaf, .{ .follow_symlinks = false });
                if (stat.kind != .file) return error.NotRegularFile;
            }
            try self.populate(io, allocator, if (parent_path.len == 0) "." else parent_path, "", false, false);
            break :blk null;
        };
        if (direct) |dir| {
            dir.close(io);
            try self.populate(io, allocator, raw, "", false, false);
        }
        self.mode = mode;
        self.filename_len = initial_name_len;
        @memcpy(self.filename_storage[0..initial_name_len], initial_name[0..initial_name_len]);
        if (initial_name_len > 0) for (self.entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, self.filename())) {
                self.selected = index;
                break;
            }
        };
    }

    /// Enter a checked directory and clear only the listing filter. Save's
    /// prefilled filename remains intact while browsing directories.
    pub fn browse(self: *State, io: Io, allocator: Allocator, path: []const u8) !void {
        try self.populate(io, allocator, path, "", self.show_hidden, false);
    }

    pub fn reload(self: *State, io: Io, allocator: Allocator) !void {
        try self.populate(io, allocator, self.directory(), self.filter(), self.show_hidden, true);
    }

    pub fn parent(self: *State, io: Io, allocator: Allocator) !void {
        if (self.directory_len == 0) return error.FileDialogNotOpen;
        var storage: [max_path]u8 = undefined;
        const path = try joined(self.directory(), "..", &storage);
        try self.browse(io, allocator, path);
    }

    /// Filtering rescans the directory, so a file outside the retained first
    /// 128 matches can still be found. ASCII case folds; other UTF-8 is literal.
    pub fn setFilter(self: *State, io: Io, allocator: Allocator, raw: []const u8) !void {
        if (raw.len > max_filter or !validText(raw)) return error.InvalidFileFilter;
        try self.populate(io, allocator, self.directory(), raw, self.show_hidden, false);
    }

    pub fn toggleHidden(self: *State, io: Io, allocator: Allocator) !void {
        try self.populate(io, allocator, self.directory(), self.filter(), !self.show_hidden, true);
    }

    pub fn setFilename(self: *State, raw: []const u8) !void {
        if (!validName(raw)) return error.InvalidFileName;
        @memmove(self.filename_storage[0..raw.len], raw);
        self.filename_len = raw.len;
    }

    pub fn select(self: *State, index: usize) void {
        self.selected = @min(index, self.entries.len -| 1);
    }

    pub fn move(self: *State, amount: isize) void {
        if (amount < 0) {
            const magnitude: usize = @intCast(-(amount + 1));
            self.selected -|= magnitude +| 1;
        } else {
            self.select(self.selected +| @as(usize, @intCast(amount)));
        }
    }

    /// Directories navigate. Open returns one path; Save copies a file's exact
    /// name into the filename field and requires a separate explicit Save.
    /// Returned slices belong to this state until refresh/reset/deinit.
    pub fn choose(self: *State, io: Io, allocator: Allocator) !?[]const u8 {
        if (self.selected >= self.entries.len) return null;
        const entry = self.entries[self.selected];
        if (entry.directory) {
            try self.browse(io, allocator, entry.path);
            return null;
        }
        if (self.mode == .save) {
            try self.setFilename(entry.name);
            return null;
        }
        return entry.path;
    }

    /// Only composes a literal destination. It never creates or overwrites it.
    /// The backend must perform its existing exclusive, checked-descriptor save.
    pub fn destination(self: *State) ![]const u8 {
        if (self.directory_len == 0) return error.FileDialogNotOpen;
        if (!validName(self.filename())) return error.InvalidFileName;
        return joined(self.directory(), self.filename(), &self.destination_storage);
    }

    fn populate(self: *State, io: Io, allocator: Allocator, raw_directory: []const u8, raw_filter: []const u8, hidden: bool, preserve_selection: bool) !void {
        if (!validPath(raw_directory)) return error.InvalidFilePath;
        if (raw_filter.len > max_filter or !validText(raw_filter)) return error.InvalidFileFilter;
        var dir = try completion.openDirectory(io, raw_directory, false);
        defer dir.close(io);
        var next_directory_storage: [max_path]u8 = undefined;
        const next_directory = try normalized(raw_directory, &next_directory_storage);
        var next_filter_storage: [max_filter]u8 = undefined;
        @memcpy(next_filter_storage[0..raw_filter.len], raw_filter);
        const next_filter = next_filter_storage[0..raw_filter.len];
        var old_name_storage: [max_name]u8 = undefined;
        const old_name = if (preserve_selection and self.selected < self.entries.len) blk: {
            const name = self.entries[self.selected].name;
            @memcpy(old_name_storage[0..name.len], name);
            break :blk old_name_storage[0..name.len];
        } else "";

        var retained: [max_entries]Retained = undefined;
        var count: usize = 0;
        var largest: usize = 0;
        var scanned: usize = 0;
        var matching: usize = 0;
        var iterator = dir.iterate();
        while (scanned < max_scanned) {
            const entry = (try iterator.next(io)) orelse break;
            scanned += 1;
            if (!validName(entry.name) or (!hidden and entry.name[0] == '.') or !matches(entry.name, next_filter)) continue;
            const kind = if (entry.kind == .unknown) (dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue).kind else entry.kind;
            if (kind != .directory and kind != .file) continue;
            // A directory near the path limit can still be inspected, but no
            // entry with a too-long resulting path is offered as a choice.
            const path_len = next_directory.len + @as(usize, if (std.mem.endsWith(u8, next_directory, "/")) 0 else 1) + entry.name.len;
            if (path_len > max_path) continue;
            matching += 1;
            var candidate: Retained = .{ .name_len = entry.name.len, .directory = kind == .directory };
            @memcpy(candidate.name_storage[0..entry.name.len], entry.name);
            if (count < max_entries) {
                retained[count] = candidate;
                if (count > 0 and Retained.less({}, retained[largest], candidate)) largest = count;
                count += 1;
            } else if (Retained.less({}, candidate, retained[largest])) {
                retained[largest] = candidate;
                largest = 0;
                for (retained[1..count], 1..) |value, index| {
                    if (Retained.less({}, retained[largest], value)) largest = index;
                }
            }
        }
        std.mem.sort(Retained, retained[0..count], {}, Retained.less);
        // Stat at most the retained snapshot for size. Ignore a disappeared
        // or substituted entry; the backend validates an opened file again.
        var live_count: usize = 0;
        for (retained[0..count]) |value| {
            const stat = dir.statFile(io, value.name(), .{ .follow_symlinks = false }) catch continue;
            const expected_kind: Io.File.Kind = if (value.directory) .directory else .file;
            if (stat.kind != expected_kind) continue;
            retained[live_count] = value;
            retained[live_count].size = if (value.directory) null else stat.size;
            live_count += 1;
        }

        if (self.arena == null) self.arena = .init(allocator);
        _ = self.arena.?.reset(.retain_capacity);
        self.entries = &.{};
        self.selected = 0;
        const a = self.arena.?.allocator();
        const entries = try a.alloc(Entry, live_count);
        var path_storage: [max_path]u8 = undefined;
        for (retained[0..live_count], entries, 0..) |value, *entry, index| {
            const name = try a.dupe(u8, value.name());
            const path = try a.dupe(u8, try joined(next_directory, name, &path_storage));
            entry.* = .{ .name = name, .path = path, .directory = value.directory, .size = value.size };
            if (old_name.len > 0 and std.mem.eql(u8, old_name, name)) self.selected = index;
        }
        @memcpy(self.directory_storage[0..next_directory.len], next_directory);
        self.directory_len = next_directory.len;
        @memcpy(self.filter_storage[0..next_filter.len], next_filter);
        self.filter_len = next_filter.len;
        self.entries = entries;
        self.show_hidden = hidden;
        self.scanned = scanned;
        self.matching = matching;
        self.scan_limited = scanned == max_scanned;
        self.truncated = self.scan_limited or matching > max_entries;
    }
};

test "file dialog: owned Unicode snapshot sorts directories first and hides unsafe names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ "旅行", "adir", "zdir" }) |name| try temporary.dir.createDir(io, name, .fromMode(0o700));
    for ([_][]const u8{ "éclair.txt", "zeta.md", "Alpha report.txt", ".secret", "bad\nname", "\xffbad", "invoice\u{202e}fdp" }) |name| {
        try std.testing.expect(validName(name) == (std.mem.eql(u8, name, "éclair.txt") or std.mem.eql(u8, name, "zeta.md") or std.mem.eql(u8, name, "Alpha report.txt") or std.mem.eql(u8, name, ".secret")));
        const file = temporary.dir.createFile(io, name, .{}) catch |err| {
            // APFS rejects invalid UTF-8 at creation. Keep the pure filter
            // assertion above, and exercise enumeration where the filesystem
            // can represent this deliberately unsafe fixture name.
            if (@import("builtin").os.tag == .macos and err == error.BadPathName and !std.unicode.utf8ValidateSlice(name)) continue;
            return err;
        };
        defer file.close(io);
        if (std.mem.eql(u8, name, "Alpha report.txt")) try file.writeStreamingAll(io, "hello");
    }
    try temporary.dir.symLink(io, "Alpha report.txt", "linked.txt", .{});
    try temporary.dir.symLink(io, "adir", "linked-dir", .{ .is_directory = true });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var state: State = .{};
    defer state.deinit();
    try state.open(io, allocator, .open, root);
    try std.testing.expectEqual(@as(usize, 6), state.entries.len);
    for ([_][]const u8{ "adir", "zdir", "旅行", "Alpha report.txt", "zeta.md", "éclair.txt" }, state.entries, 0..) |expected, entry, index| {
        try std.testing.expectEqualStrings(expected, entry.name);
        try std.testing.expectEqual(index < 3, entry.directory);
        try std.testing.expect(std.mem.endsWith(u8, entry.path, expected));
    }
    try std.testing.expectEqual(@as(?u64, 5), state.entries[3].size);
    try state.setFilter(io, allocator, "REPORT");
    try std.testing.expectEqual(@as(usize, 1), state.entries.len);
    try std.testing.expectEqualStrings("Alpha report.txt", state.entries[0].name);
    const chosen = (try state.choose(io, allocator)).?;
    try std.testing.expect(std.mem.endsWith(u8, chosen, "/Alpha report.txt"));
    try state.setFilter(io, allocator, "旅行");
    try std.testing.expectEqual(@as(usize, 1), state.entries.len);
    try std.testing.expect(state.entries[0].directory);
    try state.setFilter(io, allocator, ".secret");
    try std.testing.expectEqual(@as(usize, 0), state.entries.len);
    try state.toggleHidden(io, allocator);
    try std.testing.expectEqual(@as(usize, 1), state.entries.len);
    try std.testing.expectEqualStrings(".secret", state.entries[0].name);
    try state.setFilter(io, allocator, "");
    try state.reload(io, allocator);
    const capacity = state.arena.?.queryCapacity();
    for (0..16) |_| {
        try state.reload(io, allocator);
        try std.testing.expectEqual(@as(usize, 7), state.entries.len);
        try std.testing.expectEqualStrings("旅行", state.entries[2].name);
        try std.testing.expectEqual(capacity, state.arena.?.queryCapacity());
    }
    state.reset();
    try std.testing.expectEqual(@as(usize, 0), state.entries.len);
    try std.testing.expectEqualStrings("", state.directory());
}

test "file dialog: literal save name survives navigation and choosing never overwrites" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "child", .fromMode(0o700));
    const existing = try temporary.dir.createFile(io, "existing.txt", .{});
    try existing.writeStreamingAll(io, "unchanged");
    existing.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer allocator.free(root);
    const initial_path = try std.fmt.allocPrint(allocator, "{s}/new \"literal\" $file.pdf", .{root});
    defer allocator.free(initial_path);
    var state: State = .{};
    defer state.deinit();
    try state.open(io, allocator, .save, initial_path);
    try std.testing.expectEqualStrings("new \"literal\" $file.pdf", state.filename());
    try std.testing.expectEqualStrings(initial_path, try state.destination());
    try std.testing.expectEqual(@as(?[]const u8, null), try state.choose(io, allocator));
    try std.testing.expect(std.mem.endsWith(u8, state.directory(), "/child"));
    try std.testing.expectEqualStrings("new \"literal\" $file.pdf", state.filename());
    try state.parent(io, allocator);
    try std.testing.expectEqualStrings(root, state.directory());
    state.move(std.math.maxInt(isize));
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    try std.testing.expectEqual(@as(?[]const u8, null), try state.choose(io, allocator));
    try std.testing.expectEqualStrings("existing.txt", state.filename());
    const destination = try state.destination();
    try std.testing.expect(std.mem.endsWith(u8, destination, "/existing.txt"));
    // Selecting/composing a destination has performed no write. The backend
    // still rejects its existing leaf when explicitly asked to create it.
    const absolute = try temporary.dir.realPathFileAlloc(io, "existing.txt", allocator);
    defer allocator.free(absolute);
    try std.testing.expectError(error.PathAlreadyExists, completion.createExclusive(io, absolute));
    var contents: [16]u8 = undefined;
    const bytes = try temporary.dir.readFile(io, "existing.txt", &contents);
    try std.testing.expectEqualStrings("unchanged", bytes);
    state.move(std.math.minInt(isize));
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expectError(error.InvalidFileName, state.setFilename("../escape"));
    try std.testing.expectError(error.InvalidFileName, state.setFilename("bad\x1bname"));
    try std.testing.expectError(error.InvalidFileFilter, state.setFilter(io, allocator, "\xc2\x9b"));
}

test "file dialog: checked directory refuses symlinks before parent normalization" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "real", .fromMode(0o700));
    try temporary.dir.symLink(io, "real", "link", .{ .is_directory = true });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const refused = try std.fmt.allocPrint(allocator, "{s}/link/../real", .{root});
    defer allocator.free(refused);
    var state: State = .{};
    defer state.deinit();
    try state.open(io, allocator, .open, root);
    if (state.browse(io, allocator, refused)) |_| {
        return error.ExpectedSymlinkRefusal;
    } else |_| {}
    try std.testing.expectEqualStrings(root, state.directory());
    try std.testing.expectEqual(@as(usize, 1), state.entries.len);
    try std.testing.expectEqualStrings("real", state.entries[0].name);
    const checked_parent = try std.fmt.allocPrint(allocator, "{s}/real/../", .{root});
    defer allocator.free(checked_parent);
    try state.browse(io, allocator, checked_parent);
    try std.testing.expectEqualStrings(root, state.directory());
    var storage: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("/", try normalized("/../../", &storage));
    try std.testing.expectEqualStrings("../..", try normalized("../.././", &storage));
    try std.testing.expectEqualStrings(".", try normalized("./real/../", &storage));
    try std.testing.expect(!validText("\xff"));
    try std.testing.expect(!validText("a\u{2066}b"));
}

test "file dialog: retained quota preserves best sorted rows and filtering finds overflow" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file_count = max_entries + 16;
    for (0..file_count) |number| {
        var storage: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&storage, "entry-{d:0>3}.txt", .{file_count - number - 1});
        const file = try temporary.dir.createFile(io, name, .{});
        file.close(io);
    }
    try temporary.dir.createDir(io, "z-last-directory", .fromMode(0o700));
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var state: State = .{};
    defer state.deinit();
    try state.open(io, allocator, .open, root);
    try std.testing.expectEqual(@as(usize, max_entries), state.entries.len);
    try std.testing.expectEqual(@as(usize, file_count + 1), state.matching);
    try std.testing.expect(state.truncated);
    try std.testing.expect(!state.scan_limited);
    try std.testing.expectEqualStrings("z-last-directory", state.entries[0].name);
    try std.testing.expectEqualStrings("entry-000.txt", state.entries[1].name);
    try std.testing.expectEqualStrings("entry-126.txt", state.entries[max_entries - 1].name);
    try state.setFilter(io, allocator, "entry-143");
    try std.testing.expectEqual(@as(usize, 1), state.entries.len);
    try std.testing.expectEqualStrings("entry-143.txt", state.entries[0].name);
    try std.testing.expect(!state.truncated);
}

test "file dialog: scan ceiling limits work and reports lower-bound totals" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for (0..max_scanned + 3) |number| {
        var storage: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&storage, "entry-{d:0>4}.txt", .{number});
        const file = try temporary.dir.createFile(io, name, .{});
        file.close(io);
    }
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var state: State = .{};
    defer state.deinit();
    try state.open(io, allocator, .open, root);
    try std.testing.expectEqual(@as(usize, max_scanned), state.scanned);
    try std.testing.expectEqual(@as(usize, max_scanned), state.matching);
    try std.testing.expectEqual(@as(usize, max_entries), state.entries.len);
    try std.testing.expect(state.scan_limited);
    try std.testing.expect(state.truncated);
}
