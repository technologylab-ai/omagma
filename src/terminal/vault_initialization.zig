//! Explicit recovery from a headerless interrupted initialization. The marker
//! precedes all ciphertext. Discard retains the unreachable records in a new
//! private sibling directory; it never removes an existing header or user data.
const std = @import("std");
const storage = @import("vault_storage.zig");
const header = @import("vault_header.zig");
const private = @import("../keyring_file.zig");
const marker = "initialization.pending";
const contents = "omagma-vault-initialization-v1\n";

fn noHeaders(directory: *storage.Directory) !void {
    for ([_][]const u8{ header.filename, header.backup_filename }) |name| {
        if (directory.dir.statFile(directory.io, name, .{ .follow_symlinks = false })) |_| return error.PathAlreadyExists else |err| if (err != error.FileNotFound) return err;
    }
}
pub fn begin(directory: *storage.Directory) !void {
    try noHeaders(directory);
    var entries = directory.dir.iterate();
    while (try entries.next(directory.io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".vault-lock")) continue;
        if (std.mem.eql(u8, entry.name, marker)) return error.VaultInitializationIncomplete;
        return error.VaultRecoveryRequired;
    }
    var file = try storage.AtomicFile.init(directory.io, directory.dir, marker, contents.len, false, .{});
    defer file.deinit();
    try file.write(contents);
    try file.commit();
}
pub fn finish(directory: *storage.Directory) !void {
    directory.dir.deleteFile(directory.io, marker) catch |err| if (err == error.FileNotFound) return else return err;
    try storage.syncDirectory(directory.io, directory.dir);
}
/// Requires explicit CLI confirmation. Returns the retained records path, if
/// records existed. Caller owns the result; passwords and keys are unnecessary.
pub fn discard(io: std.Io, a: std.mem.Allocator, path: []const u8) !?[]u8 {
    var directory = try storage.Directory.open(io, path, false);
    defer directory.close();
    try noHeaders(&directory);
    const file = try storage.openPrivate(io, directory.dir, marker);
    defer file.close(io);
    var buffer: [contents.len + 1]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    if (!std.mem.eql(u8, contents, buffer[0..count])) return error.VaultRecoveryRequired;
    var has_records = false;
    var has_migration = false;
    var entries = directory.dir.iterate();
    while (try entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".vault-lock") or std.mem.eql(u8, entry.name, marker)) continue;
        if (std.mem.eql(u8, entry.name, "records") and entry.kind == .directory) {
            has_records = true;
        } else if (std.mem.eql(u8, entry.name, "migration") and entry.kind == .directory) {
            has_migration = true;
        } else return error.VaultRecoveryRequired;
    }
    var retained: ?[]u8 = null;
    errdefer if (retained) |bytes| a.free(bytes);
    if (has_records or has_migration) {
        const parent_path = std.fs.path.dirname(path) orelse return error.InvalidVaultPath;
        const parent = try private.directory(io, parent_path, false);
        defer parent.close(io);
        // Validate both directories before moving either opaque tree.
        for ([_][]const u8{ "records", "migration" }, [_]bool{ has_records, has_migration }) |child, exists| {
            if (!exists) continue;
            const child_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, child });
            defer a.free(child_path);
            const child_directory = try private.directory(io, child_path, false);
            child_directory.close(io);
        }
        var nonce: [12]u8 = undefined;
        try io.randomSecure(&nonce);
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "omagma-abandoned-init-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        retained = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent_path, name });
        try parent.createDir(io, name, .fromMode(0o700));
        const abandoned = try private.directory(io, retained.?, false);
        defer abandoned.close(io);
        try storage.syncDirectory(io, parent);
        if (has_records) try directory.dir.renamePreserve("records", abandoned, "records", io);
        if (has_migration) try directory.dir.renamePreserve("migration", abandoned, "migration", io);
        try storage.syncDirectory(io, abandoned);
        try storage.syncDirectory(io, parent);
        try storage.syncDirectory(io, directory.dir);
    }
    try finish(&directory);
    return retained;
}

test "vault initialization: discard is explicit headerless and retains interrupted ciphertext" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const parent_path = try std.fmt.allocPrint(a, "{s}/omagma-init-test-{s}", .{ @import("vault_paths.zig").temporary_root, std.fmt.bytesToHex(nonce, .lower) });
    defer a.free(parent_path);
    const parent = try private.directory(io, parent_path, true);
    parent.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, parent_path) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/vault", .{parent_path});
    defer a.free(path);
    {
        var directory = try storage.Directory.open(io, path, true);
        defer directory.close();
        try begin(&directory);
        try std.testing.expectError(error.VaultInitializationIncomplete, begin(&directory));
        try directory.dir.createDir(io, "records", .fromMode(0o700));
    }
    const retained = (try discard(io, a, path)).?;
    defer a.free(retained);
    const copied = try private.directory(io, retained, false);
    copied.close(io);
    {
        var directory = try storage.Directory.open(io, path, false);
        defer directory.close();
        try begin(&directory);
        const protected = try directory.dir.createFile(io, header.filename, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        protected.close(io);
    }
    try std.testing.expectError(error.PathAlreadyExists, discard(io, a, path));
}
