//! Bounded, encrypted migration plan and progress. Handles are checkpointed
//! before copying any object; restart authenticates the same plan and never
//! invents new object identities or replays provider operations.
const std = @import("std");
const vt = @import("vault_types.zig");
const storage = @import("vault_storage.zig");
const stream = @import("vault_stream.zig");
const Hash = std.crypto.hash.sha2.Sha256;
pub const max_manifest_bytes = 16 * 1024 * 1024;
pub const max_objects = 3 * (10000 + 512);
pub const Object = struct { name: []const u8, kind: vt.RecordKind, size: usize, sha256: [32]u8, handle: storage.Handle };
pub const Account = struct { account: []const u8, present: bool, state_sha256: [32]u8, target_state_sha256: [32]u8, objects: []const Object, mail_count: usize = 0, draft_count: usize = 0, queued_count: usize = 0 };
pub const Source = struct { config: []const u8, grants: []const u8, cache: []const u8, preferences: ?[]const u8 = null, allow_empty_cache: bool = false, allow_missing_grants: bool = false, allow_missing_tokens: bool = false };
pub const Manifest = struct {
    schema: u8 = 1,
    vault_id: vt.Id,
    source: Source,
    identity_sha256: [32]u8,
    accounts: []const Account,
    pub fn objectCount(self: Manifest) usize {
        var count: usize = 0;
        for (self.accounts) |entry| count += entry.objects.len;
        return count;
    }
};
pub const Progress = struct { schema: u8 = 1, next_object: usize = 0, published_accounts: u8 = 0, verified: bool = false };

fn handle(root: storage.Handle, label: []const u8) storage.Handle {
    var hash: Hash = .init(.{});
    hash.update("omagma-vault-migration-journal-v1\x00");
    hash.update(&root.bytes);
    hash.update(label);
    var result: storage.Handle = undefined;
    hash.final(&result.bytes);
    return result;
}
pub const Journal = struct {
    directory: storage.Directory,
    allocator: std.mem.Allocator,
    key: *const vt.DataKey,
    workspace: *vt.StreamWorkspace,
    root: storage.Handle,
    occupied: ?*anyopaque = null,
    pub fn open(io: std.Io, a: std.mem.Allocator, vault_path: []const u8, key: *const vt.DataKey, workspace: *vt.StreamWorkspace, root: storage.Handle, create: bool) !Journal {
        const path = try std.fmt.allocPrint(a, "{s}/migration", .{vault_path});
        defer a.free(path);
        return .{ .directory = try storage.Directory.open(io, path, create), .allocator = a, .key = key, .workspace = workspace, .root = root };
    }
    pub fn close(self: *Journal) void {
        std.debug.assert(self.occupied == null);
        self.directory.close();
    }
    fn record(self: *const Journal, label: []const u8) storage.Record {
        return .{ .account = "omagma-vault-migration-v1", .kind = .operation_ledger, .handle = handle(self.root, label) };
    }
    fn write(self: *Journal, label: []const u8, value: anytype, limit: usize, replace: bool) !void {
        var count_buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &count_buffer);
        var count = std.Io.Writer.Discarding.init(&count_buffer);
        try std.json.Stringify.value(value, .{}, &count.writer);
        const size = count.fullCount();
        if (size > limit) return error.VaultMigrationPlanTooLarge;
        var output: stream.Writer = undefined;
        try output.init(&self.directory, self.key, self.record(label), @intCast(size), self.workspace, replace, .{});
        defer output.deinit();
        std.json.Stringify.value(value, .{}, &output.interface) catch |err| return output.failure orelse err;
        try output.finish();
    }
    fn read(self: *Journal, a: std.mem.Allocator, label: []const u8, limit: usize) ![]u8 {
        var input = try stream.Reader.init(&self.directory, self.key, self.record(label), &self.workspace.plaintext, &self.occupied);
        defer input.close();
        if (input.size > limit) return error.VaultMigrationPlanTooLarge;
        const bytes = try a.alloc(u8, input.size);
        errdefer {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        var position: usize = 0;
        while (position < bytes.len) {
            const n = try input.read(bytes[position..]);
            if (n == 0) return error.VaultTruncated;
            position += n;
        }
        var extra: [1]u8 = undefined;
        defer std.crypto.secureZero(u8, &extra);
        if (try input.read(&extra) != 0) return error.VaultLengthMismatch;
        return bytes;
    }
    pub fn createManifest(self: *Journal, manifest: Manifest) !void {
        try self.validateManifest(manifest);
        try self.write("manifest", manifest, max_manifest_bytes, false);
    }
    pub fn readManifest(self: *Journal, a: std.mem.Allocator) !Manifest {
        const bytes = try self.read(a, "manifest", max_manifest_bytes);
        // The caller's wiping arena owns both bytes and borrowed decoded text.
        const manifest = try std.json.parseFromSliceLeaky(Manifest, a, bytes, .{ .allocate = .alloc_if_needed, .duplicate_field_behavior = .@"error", .max_value_len = 4096 });
        try self.validateManifest(manifest);
        return manifest;
    }
    fn validateManifest(self: *const Journal, manifest: Manifest) !void {
        if (manifest.schema != 1 or !std.mem.eql(u8, &manifest.vault_id, &self.key.vault_id) or manifest.accounts.len == 0 or manifest.accounts.len > 3 or manifest.objectCount() > max_objects) return error.InvalidVaultMigration;
        for ([_][]const u8{ manifest.source.config, manifest.source.grants, manifest.source.cache }) |path| if (path.len < 2 or path.len > 4096 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidVaultMigration;
        if (manifest.source.preferences) |path| if (path.len < 2 or path.len > 4096 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidVaultMigration;
        for (manifest.accounts, 0..) |entry, index| {
            try @import("../bounded.zig").address(entry.account);
            for (manifest.accounts[0..index]) |previous| if (std.ascii.eqlIgnoreCase(previous.account, entry.account)) return error.InvalidVaultMigration;
            if (!entry.present and entry.objects.len != 0) return error.InvalidVaultMigration;
            var names: std.StringHashMap(void) = .init(self.allocator);
            defer names.deinit();
            var handles: std.StringHashMap(void) = .init(self.allocator);
            defer handles.deinit();
            for (entry.objects) |*object| {
                if (object.name.len == 0 or object.name.len > 512 or std.mem.indexOfAny(u8, object.name, "/\\\x00") != null or object.size > vt.max_record_bytes) return error.InvalidVaultMigration;
                if ((try names.getOrPut(object.name)).found_existing or (try handles.getOrPut(&object.handle.bytes)).found_existing) return error.InvalidVaultMigration;
            }
        }
    }
    pub fn readProgress(self: *Journal, a: std.mem.Allocator, manifest: Manifest) !Progress {
        const bytes = self.read(a, "progress", 1024) catch |err| if (err == error.FileNotFound) return .{} else return err;
        const progress = try std.json.parseFromSliceLeaky(Progress, a, bytes, .{ .allocate = .alloc_if_needed, .duplicate_field_behavior = .@"error" });
        try validateProgress(progress, manifest);
        return progress;
    }
    pub fn saveProgress(self: *Journal, progress: Progress, manifest: Manifest) !void {
        try validateProgress(progress, manifest);
        const name = self.record("progress").handle.filename();
        const exists = if (self.directory.dir.statFile(self.directory.io, &name, .{ .follow_symlinks = false })) |_| true else |err| if (err == error.FileNotFound) false else return err;
        try self.write("progress", progress, 1024, exists);
    }
};
fn validateProgress(progress: Progress, manifest: Manifest) !void {
    const all: u8 = (@as(u8, 1) << @as(u3, @intCast(manifest.accounts.len))) - 1;
    if (progress.schema != 1 or progress.next_object > manifest.objectCount() or progress.published_accounts & ~all != 0 or (progress.verified and (progress.next_object != manifest.objectCount() or progress.published_accounts != all))) return error.InvalidVaultMigration;
}

/// Hash canonical persisted values without allocating their serialized copy.
pub fn digest(value: anytype) ![32]u8 {
    var writer: HashWriter = .{ .writer = .{ .vtable = &.{ .drain = HashWriter.drain }, .buffer = &.{} } };
    try std.json.Stringify.value(value, .{}, &writer.writer);
    var result: [32]u8 = undefined;
    writer.hash.final(&result);
    return result;
}
const HashWriter = struct {
    writer: std.Io.Writer,
    hash: Hash = .init(.{}),
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HashWriter = @alignCast(@fieldParentPtr("writer", writer));
        self.hash.update(writer.buffer[0..writer.end]);
        writer.end = 0;
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.hash.update(bytes);
            count += bytes.len;
        }
        for (0..splat) |_| {
            self.hash.update(data[data.len - 1]);
            count += data[data.len - 1].len;
        }
        return count;
    }
};

test "vault migration: manifest and progress authenticate resume identity and completion" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const path = try std.fmt.allocPrint(a, "{s}/omagma-migration-journal-{s}", .{ @import("vault_paths.zig").temporary_root, std.fmt.bytesToHex(nonce, .lower) });
    defer a.free(path);
    const parent = try @import("../keyring_file.zig").directory(io, path, true);
    parent.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var key = try @import("vault_crypto.zig").createDataKey(io);
    defer key.wipe();
    const workspace = try a.create(vt.StreamWorkspace);
    defer {
        workspace.wipe();
        a.destroy(workspace);
    }
    const root = try storage.Handle.create(io);
    var journal = try Journal.open(io, a, path, &key, workspace, root, true);
    defer journal.close();
    const manifest: Manifest = .{ .vault_id = key.vault_id, .source = .{ .config = "/synthetic/config.json", .grants = "/synthetic/grants.json", .cache = "/synthetic/cache" }, .identity_sha256 = @splat(0x45), .accounts = &.{.{ .account = "personal@example.test", .present = true, .state_sha256 = @splat(0x56), .target_state_sha256 = @splat(0x57), .objects = &.{.{ .name = "draft-synthetic.json", .kind = .draft, .size = 22, .sha256 = @splat(0x67), .handle = try storage.Handle.create(io) }} }} };
    try journal.createManifest(manifest);
    try std.testing.expectError(error.PathAlreadyExists, journal.createManifest(manifest));
    var wiping: @import("vault_allocator.zig").WipingAllocator = .{ .backing = a };
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer arena.deinit();
    const recovered = try journal.readManifest(arena.allocator());
    try std.testing.expectEqualStrings(manifest.accounts[0].objects[0].name, recovered.accounts[0].objects[0].name);
    try std.testing.expectEqualSlices(u8, &manifest.accounts[0].objects[0].handle.bytes, &recovered.accounts[0].objects[0].handle.bytes);
    try std.testing.expect(!(try journal.readProgress(arena.allocator(), recovered)).verified);
    try std.testing.expectError(error.InvalidVaultMigration, journal.saveProgress(.{ .verified = true }, recovered));
    try journal.saveProgress(.{ .next_object = 1 }, recovered);
    try std.testing.expectEqual(@as(usize, 1), (try journal.readProgress(arena.allocator(), recovered)).next_object);
    try journal.saveProgress(.{ .next_object = 1, .published_accounts = 1, .verified = true }, recovered);
    try std.testing.expect((try journal.readProgress(arena.allocator(), recovered)).verified);
    const file = try storage.openPrivate(io, journal.directory.dir, &journal.record("manifest").handle.filename());
    defer file.close(io);
    const ciphertext = try a.alloc(u8, @intCast((try file.stat(io)).size));
    defer a.free(ciphertext);
    _ = try file.readPositionalAll(io, ciphertext, 0);
    try std.testing.expect(std.mem.indexOf(u8, ciphertext, "personal@example.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, ciphertext, "draft-synthetic") == null);
}
