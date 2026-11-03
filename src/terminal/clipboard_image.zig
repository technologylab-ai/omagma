//! Explicit image-only clipboard reads. The UI worker streams one private
//! staging file; AppKit is loaded only by the short-lived exec-self child.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");
const private_files = @import("../keyring_file.zig");

pub const max_bytes = @import("types.zig").Limits.attachment_bytes;
pub const max_pixels: u64 = 64 * 1024 * 1024;
/// TIFF-only Retina clipboards can hold uncompressed RGBA even when their PNG
/// is small. These source/decode allocations exist only in the native child;
/// neither this bound nor the PNG stream bound claims whole-family RSS.
pub const max_tiff_bytes: usize = @intCast(max_pixels * 4 + 1024 * 1024);
pub const max_edge: u32 = 32768;
pub const timeout_seconds = 10;
const png_signature = "\x89PNG\r\n\x1a\n";

pub const Capture = struct {
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    directory_path: []const u8,
    path: []const u8,
    size: usize = 0,

    pub fn deinit(self: *Capture, io: std.Io) void {
        if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        self.directory.deleteFile(io, std.fs.path.basename(self.path)) catch {};
        self.directory.close(io);
        std.Io.Dir.cwd().deleteDir(io, self.directory_path) catch {};
        self.allocator.free(self.path);
        self.allocator.free(self.directory_path);
        self.* = undefined;
    }
};

pub const Source = union(enum) { desktop, fixture: []const u8 };

pub fn localDesktop(environ: *const std.process.Environ.Map) bool {
    if (environ.get("SSH_CONNECTION") != null or environ.get("SSH_TTY") != null) return false;
    return switch (builtin.os.tag) {
        .macos => true,
        .linux => if (environ.get("WAYLAND_DISPLAY")) |display| display.len > 0 else false,
        else => false,
    };
}

fn filenameAt(a: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0 or seconds > 253402300799) return error.InvalidClock;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "clipboard-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.png", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

/// The caller keeps this one capture until the existing attachment import has
/// pinned its bytes, then destroys it. No screenshot enters JSON or UI history.
pub fn capture(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, source: Source) !Capture {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.ClipboardUnavailable;
    if (source == .desktop and !localDesktop(environ)) return error.ClipboardUnavailable;
    const base = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    if (!std.fs.path.isAbsolute(base)) return error.ClipboardUnavailable;
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, base, a);
    defer a.free(canonical);
    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const directory_path = try std.fmt.allocPrint(a, "{s}/omagma-clipboard-{s}", .{ canonical, std.fmt.bytesToHex(nonce, .lower) });
    errdefer a.free(directory_path);
    const directory = try private_files.directory(io, directory_path, true);
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        directory.close(io);
        std.Io.Dir.cwd().deleteDir(io, directory_path) catch {};
    }
    const name = try filenameAt(a, std.Io.Timestamp.now(io, .real).toSeconds());
    defer a.free(name);
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ directory_path, name });
    errdefer a.free(path);
    const file = try directory.createFile(io, name, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        directory.deleteFile(io, name) catch {};
    }
    try private_files.privateFile(io, file);

    var executable: [4096]u8 = undefined;
    var command: [4][]const u8 = undefined;
    const argv: []const []const u8 = if (source == .fixture or builtin.os.tag == .macos) blk: {
        const length = try std.process.executablePath(io, &executable);
        command[0] = executable[0..length];
        command[1] = "__clipboard-image";
        if (source == .fixture) {
            command[2] = "--fixtures";
            command[3] = source.fixture;
            break :blk &command;
        }
        break :blk command[0..2];
    } else &.{ "wl-paste", "--no-newline", "--type", "image/png" };
    const size = platform.deadline(io, platform.seconds(timeout_seconds), streamCommand, .{ io, environ, argv, file }) catch |err| return if (err == error.Timeout) error.ClipboardTimeout else err;
    try file.sync(io);
    return .{ .allocator = a, .directory = directory, .directory_path = directory_path, .path = path, .size = size };
}

fn streamCommand(io: std.Io, environ: *const std.process.Environ.Map, argv: []const []const u8, destination: std.Io.File) !usize {
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = environ, .pgid = if (builtin.os.tag == .macos) 0 else null, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch |err| return if (err == error.FileNotFound) error.ClipboardToolMissing else err;
    defer {
        platform.closePipes(&child, io);
        if (child.id) |pid| {
            if (builtin.os.tag == .macos) std.posix.kill(-pid, .KILL) catch {};
            platform.killOwned(io, &child);
        }
    }
    var buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var header: [33]u8 = undefined;
    var header_len: usize = 0;
    var size: usize = 0;
    while (true) {
        const count = child.stdout.?.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (count == 0) break;
        if (count > max_bytes -| size) return error.ClipboardImageTooLarge;
        const head_part = @min(count, header.len - header_len);
        @memcpy(header[header_len..][0..head_part], buffer[0..head_part]);
        header_len += head_part;
        if (size < header.len and header_len == header.len) _ = try pngDimensions(&header);
        try destination.writeStreamingAll(io, buffer[0..count]);
        size += count;
    }
    platform.closePipes(&child, io);
    const term = try platform.waitOwned(io, &child);
    switch (term) {
        .exited => |code| switch (code) {
            0 => {},
            1 => return error.NoClipboardImage,
            2 => return error.ClipboardUnavailable,
            3 => return error.ClipboardImageTooLarge,
            4 => return error.ClipboardDimensionsTooLarge,
            6 => return error.ClipboardToolMissing,
            7 => return error.ClipboardSourceTooLarge,
            else => return error.ClipboardReadFailed,
        },
        else => return error.ClipboardReadFailed,
    }
    if (size == 0) return error.NoClipboardImage;
    if (header_len < header.len) return error.ClipboardReadFailed;
    return size;
}

pub const Dimensions = struct { width: u32, height: u32 };
fn boundedDimensions(width: u32, height: u32) !Dimensions {
    if (width == 0 or height == 0) return error.ClipboardReadFailed;
    if (width > max_edge or height > max_edge or @as(u64, width) * height > max_pixels) return error.ClipboardDimensionsTooLarge;
    return .{ .width = width, .height = height };
}
pub fn pngDimensions(bytes: []const u8) !Dimensions {
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], png_signature) or !std.mem.eql(u8, bytes[12..16], "IHDR") or std.mem.readInt(u32, bytes[8..12], .big) != 13) return error.ClipboardReadFailed;
    return boundedDimensions(std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big));
}

/// Metadata-only admission before AppKit sees TIFF bytes. Clipboard screenshots
/// need one classic-TIFF image, unsigned 8-bit RGB/RGBA; other formats fail shut.
fn tiffSourceLength(length: usize) !void {
    if (length > max_tiff_bytes) return error.ClipboardSourceTooLarge;
}
pub fn tiffDimensions(bytes: []const u8) !Dimensions {
    try tiffSourceLength(bytes.len);
    if (bytes.len < 14) return error.ClipboardReadFailed;
    const order: std.builtin.Endian = if (std.mem.eql(u8, bytes[0..2], "II")) .little else if (std.mem.eql(u8, bytes[0..2], "MM")) .big else return error.ClipboardReadFailed;
    if (std.mem.readInt(u16, bytes[2..4], order) != 42) return error.ClipboardReadFailed;
    const offset: usize = std.mem.readInt(u32, bytes[4..8], order);
    if (offset < 8 or offset > bytes.len - 2) return error.ClipboardReadFailed;
    const entries: usize = std.mem.readInt(u16, bytes[offset..][0..2], order);
    if (entries > 4096 or entries * 12 + 6 > bytes.len - offset) return error.ClipboardReadFailed;
    if (std.mem.readInt(u32, bytes[offset + 2 + entries * 12 ..][0..4], order) != 0) return error.ClipboardReadFailed;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var bits = false;
    var samples: u32 = 3;
    var rgb = false;
    for (0..entries) |index| {
        const entry = bytes[offset + 2 + index * 12 ..][0..12];
        const tag = std.mem.readInt(u16, entry[0..2], order);
        const kind = std.mem.readInt(u16, entry[2..4], order);
        const count = std.mem.readInt(u32, entry[4..8], order);
        if (tag == 256 or tag == 257 or tag == 262 or tag == 277 or tag == 284) {
            if (count != 1 or (kind != 3 and kind != 4)) return error.ClipboardReadFailed;
            const value: u32 = if (kind == 3) std.mem.readInt(u16, entry[8..10], order) else std.mem.readInt(u32, entry[8..12], order);
            switch (tag) {
                256 => {
                    if (width != null) return error.ClipboardReadFailed;
                    width = value;
                },
                257 => {
                    if (height != null) return error.ClipboardReadFailed;
                    height = value;
                },
                262 => {
                    if (value != 2) return error.ClipboardReadFailed;
                    rgb = true;
                },
                277 => samples = value,
                284 => if (value != 1) return error.ClipboardReadFailed,
                else => unreachable,
            }
        } else if (tag == 258 or tag == 339) {
            if (kind != 3 or count == 0 or count > 4) return error.ClipboardReadFailed;
            const start: usize = if (count <= 2) 8 else std.mem.readInt(u32, entry[8..12], order);
            const data = if (count <= 2) entry else bytes;
            if (start > data.len or count * 2 > data.len - start) return error.ClipboardReadFailed;
            for (0..count) |sample| if (std.mem.readInt(u16, data[start + sample * 2 ..][0..2], order) != (if (tag == 258) @as(u16, 8) else 1)) return error.ClipboardReadFailed;
            if (tag == 258) bits = true;
        }
    }
    if (!bits or !rgb or samples < 3 or samples > 4) return error.ClipboardReadFailed;
    return boundedDimensions(width orelse return error.ClipboardReadFailed, height orelse return error.ClipboardReadFailed);
}

/// Internal pipe-only child entry. Fixture modes never access the user's
/// clipboard; Mac codec fixtures create their own uniquely named pasteboard.
pub fn worker(io: std.Io, arguments: []const []const u8, environ: *const std.process.Environ.Map) !void {
    if (arguments.len != 0) {
        if (arguments.len != 2 or !std.mem.eql(u8, arguments[0], "--fixtures")) return error.InvalidArgv;
        const mode = arguments[1];
        if (std.mem.eql(u8, mode, "missing")) return error.ClipboardToolMissing;
        if (std.mem.eql(u8, mode, "slow")) {
            try io.sleep(.fromMilliseconds(650), .awake);
            return std.Io.File.stdout().writeStreamingAll(io, @import("markdown_logo.zig").png);
        }
        if (std.mem.eql(u8, mode, "empty")) return error.NoClipboardImage;
        if (std.mem.eql(u8, mode, "unavailable")) return error.ClipboardUnavailable;
        if (std.mem.eql(u8, mode, "hang")) {
            try platform.seconds(timeout_seconds + 20).sleep(io);
            return;
        }
        if (std.mem.eql(u8, mode, "invalid")) return std.Io.File.stdout().writeStreamingAll(io, "not a PNG");
        if (std.mem.eql(u8, mode, "large")) {
            try std.Io.File.stdout().writeStreamingAll(io, @import("markdown_logo.zig").png);
            const zeros: [16384]u8 = @splat(0);
            var total: usize = @import("markdown_logo.zig").png.len;
            while (total <= max_bytes) {
                try std.Io.File.stdout().writeStreamingAll(io, &zeros);
                total += zeros.len;
            }
            return;
        }
        if (std.mem.eql(u8, mode, "mac-png") or std.mem.eql(u8, mode, "mac-tiff") or std.mem.eql(u8, mode, "mac-retina-tiff")) {
            if (comptime builtin.os.tag == .macos) return Darwin.run(io, mode);
            return error.ClipboardUnavailable;
        }
        if (!std.mem.eql(u8, mode, "png")) return error.InvalidArgv;
        return std.Io.File.stdout().writeStreamingAll(io, @import("markdown_logo.zig").png);
    }
    if (!localDesktop(environ)) return error.ClipboardUnavailable;
    if (comptime builtin.os.tag == .macos) return Darwin.run(io, null);
    return error.ClipboardUnavailable;
}

pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.NoClipboardImage => 1,
        error.ClipboardUnavailable => 2,
        error.ClipboardImageTooLarge => 3,
        error.ClipboardDimensionsTooLarge => 4,
        error.ClipboardToolMissing => 6,
        error.ClipboardSourceTooLarge => 7,
        else => 5,
    };
}

const Darwin = struct {
    const Id = ?*anyopaque;
    const Sel = *anyopaque;
    objc: std.DynLib,
    appkit: std.DynLib,
    getClass: *const fn ([*:0]const u8) callconv(.c) Id,
    selector: *const fn ([*:0]const u8) callconv(.c) Sel,
    send: *const fn () callconv(.c) void,
    fn open() !Darwin {
        var appkit = try std.DynLib.open("/System/Library/Frameworks/AppKit.framework/AppKit");
        errdefer appkit.close();
        var objc = try std.DynLib.open("/usr/lib/libobjc.A.dylib");
        errdefer objc.close();
        return .{ .appkit = appkit, .objc = objc, .getClass = objc.lookup(*const fn ([*:0]const u8) callconv(.c) Id, "objc_getClass") orelse return error.ClipboardUnavailable, .selector = objc.lookup(*const fn ([*:0]const u8) callconv(.c) Sel, "sel_registerName") orelse return error.ClipboardUnavailable, .send = objc.lookup(*const fn () callconv(.c) void, "objc_msgSend") orelse return error.ClipboardUnavailable };
    }
    fn close(self: *Darwin) void {
        self.objc.close();
        self.appkit.close();
    }
    fn zero(self: Darwin, receiver: Id, name: [*:0]const u8) Id {
        const function: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(self.send);
        return function(receiver, self.selector(name));
    }
    fn one(self: Darwin, receiver: Id, name: [*:0]const u8, value: Id) Id {
        const function: *const fn (Id, Sel, Id) callconv(.c) Id = @ptrCast(self.send);
        return function(receiver, self.selector(name), value);
    }
    fn integer(self: Darwin, receiver: Id, name: [*:0]const u8) isize {
        const function: *const fn (Id, Sel) callconv(.c) isize = @ptrCast(self.send);
        return function(receiver, self.selector(name));
    }
    fn string(self: Darwin, value: [*:0]const u8) Id {
        const function: *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id = @ptrCast(self.send);
        return function(self.getClass("NSString"), self.selector("stringWithUTF8String:"), value);
    }
    fn bytes(self: Darwin, data: Id, limit: usize) ![]const u8 {
        const length = self.integer(data, "length");
        if (length < 0) return error.ClipboardReadFailed;
        if (length > limit) return if (limit == max_tiff_bytes) error.ClipboardSourceTooLarge else error.ClipboardImageTooLarge;
        const function: *const fn (Id, Sel) callconv(.c) ?[*]const u8 = @ptrCast(self.send);
        const pointer = function(data, self.selector("bytes")) orelse return error.ClipboardReadFailed;
        return pointer[0..@intCast(length)];
    }
    fn png(self: Darwin, tiff: Id) !Id {
        const admitted = try tiffDimensions(try self.bytes(tiff, max_tiff_bytes));
        const bitmap = self.one(self.getClass("NSBitmapImageRep"), "imageRepWithData:", tiff) orelse return error.ClipboardReadFailed;
        const width = self.integer(bitmap, "pixelsWide");
        const height = self.integer(bitmap, "pixelsHigh");
        if (width <= 0 or height <= 0 or width > max_edge or height > max_edge) return error.ClipboardReadFailed;
        const decoded = try boundedDimensions(@intCast(width), @intCast(height));
        if (decoded.width != admitted.width or decoded.height != admitted.height) return error.ClipboardReadFailed;
        const function: *const fn (Id, Sel, usize, Id) callconv(.c) Id = @ptrCast(self.send);
        return function(bitmap, self.selector("representationUsingType:properties:"), 4, self.zero(self.getClass("NSDictionary"), "dictionary")) orelse error.ClipboardReadFailed;
    }
    fn seed(self: Darwin, board: Id, mode: []const u8) !void {
        const make: *const fn (Id, Sel, [*]const u8, usize) callconv(.c) Id = @ptrCast(self.send);
        const retina = std.mem.eql(u8, mode, "mac-retina-tiff");
        const tiff = retina or std.mem.eql(u8, mode, "mac-tiff");
        const source: []const u8 = if (retina) try syntheticRetinaTiff(std.heap.page_allocator) else @import("markdown_logo.zig").png;
        defer if (retina) std.heap.page_allocator.free(source);
        // dataWithBytes copies this fixture-only source; the private board is
        // seeded with TIFF alone, proving the genuine native fallback path.
        var data = make(self.getClass("NSData"), self.selector("dataWithBytes:length:"), source.ptr, source.len) orelse return error.ClipboardReadFailed;
        if (tiff and !retina) {
            const bitmap = self.one(self.getClass("NSBitmapImageRep"), "imageRepWithData:", data) orelse return error.ClipboardReadFailed;
            data = self.zero(bitmap, "TIFFRepresentation") orelse return error.ClipboardReadFailed;
        }
        _ = self.integer(board, "clearContents");
        const set: *const fn (Id, Sel, Id, Id) callconv(.c) bool = @ptrCast(self.send);
        if (!set(board, self.selector("setData:forType:"), data, self.string(if (tiff) "public.tiff" else "public.png"))) return error.ClipboardReadFailed;
    }
    fn run(io: std.Io, fixture: ?[]const u8) !void {
        var api = open() catch return error.ClipboardUnavailable;
        defer api.close();
        const pool = api.zero(api.zero(api.getClass("NSAutoreleasePool"), "alloc"), "init") orelse return error.ClipboardUnavailable;
        defer {
            const drain: *const fn (Id, Sel) callconv(.c) void = @ptrCast(api.send);
            drain(pool, api.selector("drain"));
        }
        var name: [96]u8 = undefined;
        const board = if (fixture != null) blk: {
            var nonce: [16]u8 = undefined;
            try io.randomSecure(&nonce);
            const value = try std.fmt.bufPrintSentinel(&name, "omagma-clipboard-fixture-{s}", .{std.fmt.bytesToHex(nonce, .lower)}, 0);
            break :blk api.one(api.getClass("NSPasteboard"), "pasteboardWithName:", api.string(value));
        } else api.zero(api.getClass("NSPasteboard"), "generalPasteboard");
        if (board == null) return error.ClipboardUnavailable;
        defer if (fixture != null) {
            const release: *const fn (Id, Sel) callconv(.c) void = @ptrCast(api.send);
            release(board, api.selector("releaseGlobally"));
        };
        if (fixture) |mode| try api.seed(board, mode);
        const direct = api.one(board, "dataForType:", api.string("public.png"));
        const data = if (direct != null) direct else try api.png(api.one(board, "dataForType:", api.string("public.tiff")) orelse return error.NoClipboardImage);
        const bytes_out = try api.bytes(data, max_bytes);
        _ = try pngDimensions(bytes_out);
        try std.Io.File.stdout().writeStreamingAll(io, bytes_out);
    }
};

const retina_width = 3840;
const retina_height = 2160;
const retina_header_bytes = 176;
fn retinaTiffHeader(header: *[retina_header_bytes]u8) void {
    @memset(header, 0);
    @memcpy(header[0..2], "II");
    std.mem.writeInt(u16, header[2..4], 42, .little);
    std.mem.writeInt(u32, header[4..8], 8, .little);
    const fields = [_]struct { tag: u16, kind: u16, count: u32 = 1, value: u32 }{
        .{ .tag = 256, .kind = 4, .value = retina_width },
        .{ .tag = 257, .kind = 4, .value = retina_height },
        .{ .tag = 258, .kind = 3, .count = 4, .value = 158 },
        .{ .tag = 259, .kind = 3, .value = 1 },
        .{ .tag = 262, .kind = 3, .value = 2 },
        .{ .tag = 273, .kind = 4, .value = retina_header_bytes },
        .{ .tag = 277, .kind = 3, .value = 4 },
        .{ .tag = 278, .kind = 4, .value = retina_height },
        .{ .tag = 279, .kind = 4, .value = retina_width * retina_height * 4 },
        .{ .tag = 284, .kind = 3, .value = 1 },
        .{ .tag = 338, .kind = 3, .value = 2 },
        .{ .tag = 339, .kind = 3, .count = 4, .value = 166 },
    };
    std.mem.writeInt(u16, header[8..10], fields.len, .little);
    for (fields, 0..) |field, i| {
        const entry = header[10 + i * 12 ..][0..12];
        std.mem.writeInt(u16, entry[0..2], field.tag, .little);
        std.mem.writeInt(u16, entry[2..4], field.kind, .little);
        std.mem.writeInt(u32, entry[4..8], field.count, .little);
        std.mem.writeInt(u32, entry[8..12], field.value, .little);
    }
    for (0..4) |i| {
        std.mem.writeInt(u16, header[158 + i * 2 ..][0..2], 8, .little);
        std.mem.writeInt(u16, header[166 + i * 2 ..][0..2], 1, .little);
    }
}
/// Fixture-only: one bounded, highly compressible uncompressed Retina image.
fn syntheticRetinaTiff(a: std.mem.Allocator) ![]u8 {
    const bytes = try a.alloc(u8, retina_header_bytes + retina_width * retina_height * 4);
    retinaTiffHeader(bytes[0..retina_header_bytes]);
    const pixel: [4]u8 = .{ 0x21, 0x72, 0xb0, 0xff };
    var i: usize = retina_header_bytes;
    while (i < bytes.len) : (i += 4) @memcpy(bytes[i..][0..4], &pixel);
    return bytes;
}

test "clipboard image: PNG admission rejects dimensions before a codec or stream" {
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..8], png_signature);
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 1920, .big);
    std.mem.writeInt(u32, png[20..24], 1080, .big);
    try std.testing.expectEqual(@as(u32, 1920), (try pngDimensions(&png)).width);
    std.mem.writeInt(u32, png[16..20], max_edge + 1, .big);
    try std.testing.expectError(error.ClipboardDimensionsTooLarge, pngDimensions(&png));
    try std.testing.expectError(error.ClipboardReadFailed, pngDimensions("not a clipboard image"));
}

test "clipboard image: filename and desktop routing are explicit and bounded" {
    const a = std.testing.allocator;
    const name = try filenameAt(a, 1793716325);
    defer a.free(name);
    try std.testing.expectEqualStrings("clipboard-20261103-143205.png", name);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("WAYLAND_DISPLAY", "wayland-fixture");
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) try std.testing.expect(localDesktop(&env));
    try env.put("SSH_CONNECTION", "fictional");
    try std.testing.expect(!localDesktop(&env));
}

test "clipboard image: classic TIFF metadata is bounded before native decoding" {
    var bytes: [80]u8 = @splat(0);
    @memcpy(bytes[0..2], "II");
    std.mem.writeInt(u16, bytes[2..4], 42, .little);
    std.mem.writeInt(u32, bytes[4..8], 8, .little);
    std.mem.writeInt(u16, bytes[8..10], 5, .little);
    const tags = [_]u16{ 256, 257, 258, 262, 277 };
    for (tags, 0..) |tag, index| {
        const entry = bytes[10 + index * 12 ..][0..12];
        std.mem.writeInt(u16, entry[0..2], tag, .little);
        std.mem.writeInt(u16, entry[2..4], if (index < 2) 4 else 3, .little);
        std.mem.writeInt(u32, entry[4..8], if (tag == 258) 3 else 1, .little);
        std.mem.writeInt(u32, entry[8..12], switch (tag) {
            256 => 1920,
            257 => 1080,
            258 => 74,
            262 => 2,
            277 => 3,
            else => unreachable,
        }, .little);
    }
    for (0..3) |index| std.mem.writeInt(u16, bytes[74 + index * 2 ..][0..2], 8, .little);
    try std.testing.expectEqual(@as(u32, 1920), (try tiffDimensions(&bytes)).width);
    std.mem.writeInt(u32, bytes[18..22], max_edge + 1, .little);
    try std.testing.expectError(error.ClipboardDimensionsTooLarge, tiffDimensions(&bytes));
    std.mem.writeInt(u32, bytes[18..22], 1920, .little);
    std.mem.writeInt(u32, bytes[70..74], 128, .little);
    try std.testing.expectError(error.ClipboardReadFailed, tiffDimensions(&bytes));
    std.mem.writeInt(u32, bytes[70..74], 0, .little);
    std.mem.writeInt(u16, bytes[2..4], 43, .little);
    try std.testing.expectError(error.ClipboardReadFailed, tiffDimensions(&bytes));
}

test "clipboard image: Retina TIFF source allowance is independent of PNG output" {
    try tiffSourceLength(max_tiff_bytes);
    try std.testing.expectError(error.ClipboardSourceTooLarge, tiffSourceLength(max_tiff_bytes + 1));
    var header: [retina_header_bytes]u8 = undefined;
    retinaTiffHeader(&header);
    const dimensions = try tiffDimensions(&header);
    try std.testing.expectEqual(@as(u32, retina_width), dimensions.width);
    try std.testing.expectEqual(@as(u32, retina_height), dimensions.height);
    const source_bytes = retina_header_bytes + retina_width * retina_height * 4;
    try std.testing.expect(source_bytes > max_bytes and source_bytes < max_tiff_bytes);
    // The boundary is metadata-only; it allocates neither 257 MiB nor a codec.
    try std.testing.expectEqual(@as(usize, 257 * 1024 * 1024), max_tiff_bytes);
}
