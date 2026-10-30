//! One-shot file flags resolve to one delivery per canonical file before any
//! import, dry-run or provider request. Flag order changes only display order.
const std = @import("std");
const t = @import("types.zig");

pub const Source = enum { attach_file, upload_file, file };
/// Parallel slices in first-appearance order. Null is the legacy Attach
/// serialization, so ordinary --attach-file drafts keep their fingerprints.
pub const Resolved = struct {
    paths: []const []const u8 = &.{},
    deliveries: []const ?t.AttachmentDelivery = &.{},
    /// True where --attach-file chose Attach; hints never move these files.
    forced: []const bool = &.{},
};

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

pub fn parseMode(value: []const u8) !t.AttachmentDelivery {
    return std.meta.stringToEnum(t.AttachmentDelivery, value) orelse error.InvalidAttachmentMode;
}

/// Compare files by canonical absolute path. A missing file fails here,
/// before any blob import or plan request.
pub fn resolve(io: std.Io, a: std.mem.Allocator, paths: []const []const u8, sources: []const Source, mode: ?t.AttachmentDelivery) !Resolved {
    if (paths.len != sources.len) return error.InvalidRequest;
    if (mode != null and std.mem.indexOfScalar(Source, sources, .file) == null) return error.AttachmentModeRequiresFile;
    const canonical = try a.alloc([]const u8, paths.len);
    for (paths, 0..) |path, index| canonical[index] = try std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
    return resolveCanonical(a, paths, canonical, sources, mode);
}

pub fn resolveCanonical(a: std.mem.Allocator, paths: []const []const u8, canonical: []const []const u8, sources: []const Source, mode: ?t.AttachmentDelivery) !Resolved {
    if (paths.len != sources.len or canonical.len != sources.len) return error.InvalidRequest;
    var has_file = false;
    for (sources) |source| has_file = has_file or source == .file;
    if (mode != null and !has_file) return error.AttachmentModeRequiresFile;
    var out_paths: std.ArrayList([]const u8) = .empty;
    var out_deliveries: std.ArrayList(?t.AttachmentDelivery) = .empty;
    var out_forced: std.ArrayList(bool) = .empty;
    for (canonical, 0..) |key, index| {
        var counts = [_]usize{ 0, 0, 0 };
        var first = true;
        for (canonical, 0..) |other, other_index| if (eq(other, key)) {
            counts[@backingInt(sources[other_index])] += 1;
            if (other_index < index) first = false;
        };
        for (counts) |count| if (count > 1) return error.DuplicateAttachmentFile;
        if (counts[@backingInt(Source.attach_file)] != 0 and counts[@backingInt(Source.upload_file)] != 0) return error.ConflictingAttachmentDelivery;
        if (!first) continue;
        // An explicit flag wins over --file regardless of argument order.
        const delivery: ?t.AttachmentDelivery = if (counts[@backingInt(Source.upload_file)] != 0) .drive else if (counts[@backingInt(Source.attach_file)] != 0) null else switch (mode orelse .attach) {
            .attach => null,
            .auto => .auto,
            .drive => .drive,
        };
        try out_paths.append(a, paths[index]);
        try out_deliveries.append(a, delivery);
        try out_forced.append(a, counts[@backingInt(Source.attach_file)] != 0);
    }
    return .{ .paths = out_paths.items, .deliveries = out_deliveries.items, .forced = out_forced.items };
}

test "CLI files: explicit flags win independent of order and duplicates are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const u8{ "deck.pdf", "./raw.zip", "raw.zip", "contract.pdf" };
    const canonical = [_][]const u8{ "/work/deck.pdf", "/work/raw.zip", "/work/raw.zip", "/work/contract.pdf" };
    const forward = try resolveCanonical(a, &paths, &canonical, &.{ .file, .file, .upload_file, .attach_file }, .auto);
    try std.testing.expectEqual(@as(usize, 3), forward.paths.len);
    try std.testing.expectEqualStrings("./raw.zip", forward.paths[1]);
    try std.testing.expectEqual(@as(?t.AttachmentDelivery, .auto), forward.deliveries[0]);
    try std.testing.expectEqual(@as(?t.AttachmentDelivery, .drive), forward.deliveries[1]);
    try std.testing.expectEqual(@as(?t.AttachmentDelivery, null), forward.deliveries[2]);
    try std.testing.expect(!forward.forced[0] and !forward.forced[1] and forward.forced[2]);
    const reversed = try resolveCanonical(a, &.{ "raw.zip", "./raw.zip" }, &.{ "/work/raw.zip", "/work/raw.zip" }, &.{ .upload_file, .file }, .attach);
    try std.testing.expectEqual(@as(usize, 1), reversed.paths.len);
    try std.testing.expectEqual(@as(?t.AttachmentDelivery, .drive), reversed.deliveries[0]);
    try std.testing.expectError(error.ConflictingAttachmentDelivery, resolveCanonical(a, &.{ "a", "b" }, &.{ "/x", "/x" }, &.{ .upload_file, .attach_file }, null));
    try std.testing.expectError(error.DuplicateAttachmentFile, resolveCanonical(a, &.{ "a", "./a" }, &.{ "/x", "/x" }, &.{ .file, .file }, null));
    try std.testing.expectError(error.DuplicateAttachmentFile, resolveCanonical(a, &.{ "a", "a" }, &.{ "/x", "/x" }, &.{ .attach_file, .attach_file }, null));
    try std.testing.expectError(error.AttachmentModeRequiresFile, resolveCanonical(a, &.{"a"}, &.{"/x"}, &.{.upload_file}, .drive));
    const drive_mode = try resolveCanonical(a, &.{"a"}, &.{"/x"}, &.{.file}, .drive);
    try std.testing.expectEqual(@as(?t.AttachmentDelivery, .drive), drive_mode.deliveries[0]);
    try std.testing.expectError(error.InvalidAttachmentMode, parseMode("x"));
    try std.testing.expectEqual(t.AttachmentDelivery.auto, try parseMode("auto"));
}

test "CLI files: canonical comparison uses the real file path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "report.pdf", .data = "%PDF-synthetic\n", .flags = .{ .permissions = .fromMode(0o600) } });
    const absolute = try tmp.dir.realPathFileAlloc(io, "report.pdf", a);
    const dotted = try std.fmt.allocPrint(a, "{s}/./report.pdf", .{std.fs.path.dirname(absolute).?});
    try std.testing.expectError(error.DuplicateAttachmentFile, resolve(io, a, &.{ absolute, dotted }, &.{ .file, .file }, null));
    const winner = try resolve(io, a, &.{ dotted, absolute }, &.{ .file, .upload_file }, .attach);
    try std.testing.expectEqual(@as(usize, 1), winner.paths.len);
    try std.testing.expectEqual(@as(?t.AttachmentDelivery, .drive), winner.deliveries[0]);
}
