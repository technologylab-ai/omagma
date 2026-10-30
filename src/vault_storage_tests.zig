//! Synthetic, private temporary directories only. No application integration.
const std = @import("std");
const t = @import("terminal/vault_types.zig");
const crypto = @import("terminal/vault_crypto.zig");
const storage = @import("terminal/vault_storage.zig");
const stream = @import("terminal/vault_stream.zig");
const header = @import("terminal/vault_header.zig");
const io = std.testing.io;
const allocator = std.testing.allocator;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    directory: storage.Directory,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(base);
        const path = try std.fmt.allocPrint(allocator, "{s}/records", .{base});
        errdefer allocator.free(path);
        return .{ .tmp = tmp, .path = path, .directory = try storage.Directory.open(io, path, true) };
    }
    fn deinit(self: *Fixture) void {
        self.directory.close();
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};
fn record() !storage.Record {
    return .{ .account = "synthetic@example.test", .kind = .attachment, .handle = try storage.Handle.create(io) };
}
const Slice = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn source(self: *Slice) t.Source {
        return .{ .context = self, .readFn = read };
    }
    fn read(context: *anyopaque, output: []u8) !usize {
        const self: *Slice = @ptrCast(@alignCast(context));
        const count = @min(output.len, self.bytes.len - self.offset);
        @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};
const Capture = struct {
    bytes: [4096]u8 = @splat(0),
    count: usize = 0,
    writes: usize = 0,
    commits: usize = 0,
    aborts: usize = 0,
    fn sink(self: *Capture) t.StagingSink {
        return .{ .context = self, .writeFn = write, .commitFn = commit, .abortFn = abort };
    }
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.writes += 1;
        if (bytes.len > self.bytes.len - self.count) return error.FixtureTooLarge;
        @memcpy(self.bytes[self.count..][0..bytes.len], bytes);
        self.count += bytes.len;
    }
    fn commit(context: *anyopaque) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.commits += 1;
    }
    fn abort(context: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.aborts += 1;
        self.count = 0;
        std.crypto.secureZero(u8, &self.bytes);
    }
};
fn save(fixture: *Fixture, key: *const t.DataKey, identity: storage.Record, bytes: []const u8, workspace: *t.StreamWorkspace, replace: bool) !void {
    var source: Slice = .{ .bytes = bytes };
    try fixture.directory.seal(key, identity, bytes.len, source.source(), workspace, replace);
}
fn captureRecord(fixture: *Fixture, key: *const t.DataKey, identity: storage.Record, workspace: *t.StreamWorkspace) !Capture {
    var reader = try fixture.directory.reader(identity.handle);
    defer reader.close();
    var capture: Capture = .{};
    try reader.exportVerified(key, identity, capture.sink(), workspace);
    return capture;
}
fn expectContents(fixture: *Fixture, key: *const t.DataKey, identity: storage.Record, expected: []const u8, workspace: *t.StreamWorkspace) !void {
    const capture = try captureRecord(fixture, key, identity, workspace);
    try std.testing.expectEqualStrings(expected, capture.bytes[0..capture.count]);
    try std.testing.expectEqual(@as(usize, 1), capture.commits);
    try std.testing.expectEqual(@as(usize, 0), capture.aborts);
}
fn zero(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "vault storage: opaque private records roundtrip and replacement retains identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    const handle_text = identity.handle.text();
    try std.testing.expectEqualDeep(identity.handle, try storage.Handle.parse(&handle_text));
    try std.testing.expectError(error.InvalidVaultHandle, storage.Handle.parse("../plaintext"));
    for ([_][]const u8{ "", "\x00\xffBinary synthetic attachment\r\n", "replacement synthetic message" }, 0..) |plain, index| {
        try save(&fixture, &key, identity, plain, &workspace, index != 0);
        try expectContents(&fixture, &key, identity, plain, &workspace);
        try zero(&workspace.plaintext);
        const name = identity.handle.filename();
        const file = try fixture.directory.dir.openFile(io, &name, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        try std.testing.expectEqual(@as(u64, try t.sealedSize(plain.len)), stat.size);
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
        var bytes: [4096]u8 = undefined;
        const count = try file.readPositional(io, &.{&bytes}, 0);
        if (plain.len > 0) try std.testing.expect(std.mem.indexOf(u8, bytes[0..count], plain) == null);
    }
    try std.testing.expectError(error.PathAlreadyExists, save(&fixture, &key, identity, "do not overwrite", &workspace, false));
    try expectContents(&fixture, &key, identity, "replacement synthetic message", &workspace);
}

test "vault storage: account kind object vault and key substitutions fail before export" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    try save(&fixture, &key, identity, "synthetic credential", &workspace, false);
    var other_account = identity;
    other_account.account = "other@example.test";
    var other_kind = identity;
    other_kind.kind = .credentials;
    var other_object = identity;
    other_object.handle = try storage.Handle.create(io);
    for ([_]storage.Record{ other_account, other_kind, other_object }) |wrong| {
        var reader = try fixture.directory.reader(identity.handle);
        defer reader.close();
        var output: Capture = .{};
        try std.testing.expectError(error.VaultAuthenticationFailed, reader.exportVerified(&key, wrong, output.sink(), &workspace));
        try std.testing.expectEqual(@as(usize, 0), output.writes);
        try std.testing.expectEqual(@as(usize, 1), output.aborts);
    }
    for (0..3) |field| {
        var wrong = key;
        defer wrong.wipe();
        switch (field) {
            0 => wrong.bytes[0] ^= 1,
            1 => wrong.vault_id[0] ^= 1,
            else => wrong.key_id[0] ^= 1,
        }
        var reader = try fixture.directory.reader(identity.handle);
        defer reader.close();
        var output: Capture = .{};
        if (reader.exportVerified(&wrong, identity, output.sink(), &workspace)) |_| return error.AcceptedWrongKey else |_| {}
        try std.testing.expectEqual(@as(usize, 0), output.writes);
        try zero(&workspace.plaintext);
    }
}

test "vault storage: active readers block atomic replacement without disrupting verified export" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    try save(&fixture, &key, identity, "old complete snapshot", &workspace, false);
    {
        var reader = try fixture.directory.reader(identity.handle);
        defer reader.close();
        try std.testing.expectError(error.VaultBusy, save(&fixture, &key, identity, "replacement", &workspace, true));
        try std.testing.expectEqual(@as(usize, "old complete snapshot".len), try reader.verify(&key, identity, &workspace));
        const DuringExport = struct {
            directory: *storage.Directory,
            handle: storage.Handle,
            output: Capture = .{},
            blocked: bool = false,
            fn write(context: *anyopaque, bytes: []const u8) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                try Capture.write(&self.output, bytes);
                if (self.directory.begin(self.handle, "replacement".len, true, .{})) |value| {
                    var unexpected = value;
                    unexpected.deinit();
                    return error.ReplacedDuringExport;
                } else |err| {
                    if (err != error.VaultBusy) return err;
                    self.blocked = true;
                }
            }
            fn commit(context: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                try Capture.commit(&self.output);
            }
            fn abort(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                Capture.abort(&self.output);
            }
        };
        var destination: DuringExport = .{ .directory = &fixture.directory, .handle = identity.handle };
        try reader.exportVerified(&key, identity, .{ .context = &destination, .writeFn = DuringExport.write, .commitFn = DuringExport.commit, .abortFn = DuringExport.abort }, &workspace);
        try std.testing.expect(destination.blocked);
        try std.testing.expectEqualStrings("old complete snapshot", destination.output.bytes[0..destination.output.count]);
        try std.testing.expectEqual(@as(usize, 1), destination.output.commits);
        try std.testing.expectEqual(@as(usize, 0), destination.output.aborts);
    }
    try save(&fixture, &key, identity, "replacement", &workspace, true);
    try expectContents(&fixture, &key, identity, "replacement", &workspace);
    {
        var pending = try fixture.directory.begin(identity.handle, "pending".len, true, .{});
        defer pending.deinit();
        try std.testing.expectError(error.VaultBusy, fixture.directory.reader(identity.handle));
    }
    try expectContents(&fixture, &key, identity, "replacement", &workspace);
}

test "vault storage: early staging refusals wipe the whole borrowed workspace" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    try save(&fixture, &key, identity, "existing", &workspace, false);
    @memset(&workspace.plaintext, 0xa5);
    @memset(&workspace.ciphertext, 0x5a);
    try std.testing.expectError(error.PathAlreadyExists, save(&fixture, &key, identity, "refused", &workspace, false));
    try zero(&workspace.plaintext);
    try zero(&workspace.ciphertext);
    @memset(&workspace.plaintext, 0xa5);
    @memset(&workspace.ciphertext, 0x5a);
    var source: Slice = .{ .bytes = "unused" };
    try std.testing.expectError(error.VaultRecordTooLarge, fixture.directory.seal(&key, identity, t.max_stream_record_bytes + 1, source.source(), &workspace, true));
    try std.testing.expectEqual(@as(usize, 0), source.offset);
    var metadata = identity;
    metadata.kind = .mail_body;
    try std.testing.expectError(error.VaultRecordTooLarge, fixture.directory.seal(&key, metadata, t.max_record_bytes + 1, source.source(), &workspace, true));
    try std.testing.expectEqual(@as(usize, 0), source.offset);
    try zero(&workspace.plaintext);
    try zero(&workspace.ciphertext);
    try expectContents(&fixture, &key, identity, "existing", &workspace);
}

test "vault storage: a staged first write cannot replace a newly published reader snapshot" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    // Two initial writers may both observe absence before either publishes.
    // The second has no lock on the first one's inode and must not replace it.
    var delayed = try fixture.directory.begin(identity.handle, "delayed".len, true, .{});
    defer delayed.deinit();
    var plain: Slice = .{ .bytes = "delayed" };
    try save(&fixture, &key, identity, "first complete snapshot", &workspace, false);
    var reader = try fixture.directory.reader(identity.handle);
    defer reader.close();
    const handle_text = identity.handle.text();
    try std.testing.expectError(error.PathAlreadyExists, crypto.sealStream(io, &key, storage.binding(identity, &handle_text), plain.bytes.len, plain.source(), delayed.sink(), &workspace));
    var output: Capture = .{};
    try reader.exportVerified(&key, identity, output.sink(), &workspace);
    try std.testing.expectEqualStrings("first complete snapshot", output.bytes[0..output.count]);
    try std.testing.expectEqual(@as(usize, 1), output.commits);
}

test "vault storage: corrupt final marker truncation trailing data and plaintext never export a prefix" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    const plain = "complete synthetic message";
    const wire_size = try t.sealedSize(plain.len);
    for (0..4) |damage| {
        try save(&fixture, &key, identity, plain, &workspace, damage != 0);
        const name = identity.handle.filename();
        const file = try fixture.directory.dir.openFile(io, &name, .{ .mode = .read_write });
        switch (damage) {
            0 => {
                var byte: [1]u8 = undefined;
                _ = try file.readPositionalAll(io, &byte, wire_size - 1);
                byte[0] ^= 0x80;
                try file.writePositionalAll(io, &byte, wire_size - 1);
            },
            1 => try file.setLength(io, wire_size - 1),
            2 => try file.writePositionalAll(io, "x", wire_size),
            else => try file.writePositionalAll(io, "plaintext", 0),
        }
        file.close(io);
        var reader = try fixture.directory.reader(identity.handle);
        defer reader.close();
        var output: Capture = .{};
        if (reader.exportVerified(&key, identity, output.sink(), &workspace)) |_| return error.AcceptedDamagedRecord else |_| {}
        try std.testing.expectEqual(@as(usize, 0), output.writes);
        try std.testing.expectEqual(@as(usize, 1), output.aborts);
        try zero(&workspace.plaintext);
    }
}

const Failure = struct {
    step: storage.Step,
    fn visit(context: ?*anyopaque, step: storage.Step) !void {
        const self: *Failure = @ptrCast(@alignCast(context.?));
        if (step == self.step) return error.SyntheticPowerLoss;
    }
    fn faults(self: *Failure) storage.Faults {
        return .{ .context = self, .visit = visit };
    }
};

test "vault storage: every publication boundary reopens old or new with revision one" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var identity = try record();
    identity.kind = .cache_index;
    for ([_]storage.Step{ .created, .write, .file_synced, .published, .directory_synced }, 0..) |step, index| {
        try save(&fixture, &key, identity, "old index state", &workspace, index != 0);
        var failure: Failure = .{ .step = step };
        var writer: stream.Writer = undefined;
        if (writer.init(&fixture.directory, &key, identity, "new index state".len, &workspace, true, failure.faults())) |_| {
            defer writer.deinit();
            try writer.interface.writeAll("new index state");
            if (writer.finish()) |_| return error.MissedSyntheticCrash else |err| {
                if (step == .published or step == .directory_synced) {
                    try std.testing.expectEqual(error.VaultDurabilityUncertain, err);
                    try std.testing.expect(writer.output.state == .published or writer.output.state == .durable);
                } else try std.testing.expectEqual(error.SyntheticPowerLoss, err);
            }
        } else |err| try std.testing.expectEqual(error.SyntheticPowerLoss, err);
        fixture.directory.close();
        fixture.directory = try storage.Directory.open(io, fixture.path, false);
        const expected = if (step == .published or step == .directory_synced) "new index state" else "old index state";
        try expectContents(&fixture, &key, identity, expected, &workspace);
    }
}

test "vault storage: interrupted writer cleanup is exclusive and preserves old records and unrelated files" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    try save(&fixture, &key, identity, "old state", &workspace, false);
    try std.testing.expectError(error.VaultBusy, storage.Directory.open(io, fixture.path, false));
    var writer: stream.Writer = undefined;
    try writer.init(&fixture.directory, &key, identity, 3 * t.chunk_bytes, &workspace, true, .{});
    var block: [t.chunk_bytes]u8 = @splat(0x5a);
    try writer.interface.writeAll(&block);
    const scratch_name = writer.output.temp;
    try std.testing.expect((try fixture.directory.dir.statFile(io, &scratch_name, .{})).size > t.chunk_bytes);
    storage.AtomicFile.testing.crash(&writer.output);
    writer.deinit();
    try fixture.directory.dir.writeFile(io, .{ .sub_path = ".vault-tmp-not-owned.part", .data = "unrelated synthetic file", .flags = .{ .permissions = .fromMode(0o600) } });
    fixture.directory.close();
    fixture.directory = try storage.Directory.open(io, fixture.path, false);
    try std.testing.expectError(error.FileNotFound, fixture.directory.dir.statFile(io, &scratch_name, .{}));
    _ = try fixture.directory.dir.statFile(io, ".vault-tmp-not-owned.part", .{});
    try expectContents(&fixture, &key, identity, "old state", &workspace);
}

test "vault storage: counted writer rejects short or excessive input without replacing old data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    try save(&fixture, &key, identity, "old", &workspace, false);
    {
        var writer: stream.Writer = undefined;
        try writer.init(&fixture.directory, &key, identity, 4, &workspace, true, .{});
        defer writer.deinit();
        try writer.interface.writeAll("new");
        try std.testing.expectError(error.VaultLengthMismatch, writer.finish());
    }
    {
        var writer: stream.Writer = undefined;
        try writer.init(&fixture.directory, &key, identity, 2, &workspace, true, .{});
        defer writer.deinit();
        try std.testing.expectError(error.WriteFailed, writer.interface.writeAll("new"));
        try std.testing.expectEqual(error.VaultLengthMismatch, writer.failure.?);
    }
    try expectContents(&fixture, &key, identity, "old", &workspace);
}

test "vault storage: crash between body and index commits preserves a readable old index" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var index = try record();
    index.kind = .cache_index;
    const old_body = try record();
    const new_body = try record();
    const old_handle = old_body.handle.text();
    const new_handle = new_body.handle.text();
    try save(&fixture, &key, old_body, "old synthetic body", &workspace, false);
    try save(&fixture, &key, index, &old_handle, &workspace, false);
    try save(&fixture, &key, new_body, "new synthetic body", &workspace, false);
    // Process dies before saving the index. The unpublished logical update
    // leaves a complete orphan, never a new revision of the old body.
    fixture.directory.close();
    fixture.directory = try storage.Directory.open(io, fixture.path, false);
    try expectContents(&fixture, &key, index, &old_handle, &workspace);
    try expectContents(&fixture, &key, old_body, "old synthetic body", &workspace);
    try expectContents(&fixture, &key, new_body, "new synthetic body", &workspace);
    try save(&fixture, &key, index, &new_handle, &workspace, true);
    fixture.directory.close();
    fixture.directory = try storage.Directory.open(io, fixture.path, false);
    try expectContents(&fixture, &key, index, &new_handle, &workspace);
    try expectContents(&fixture, &key, new_body, "new synthetic body", &workspace);
}

test "vault storage: ciphertext changed during export aborts and truncates explicit plaintext output" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    var block: [t.chunk_bytes]u8 = @splat(0x37);
    var writer: stream.Writer = undefined;
    try writer.init(&fixture.directory, &key, identity, 2 * block.len, &workspace, false, .{});
    defer writer.deinit();
    try writer.interface.writeAll(&block);
    try writer.interface.writeAll(&block);
    try writer.finish();
    const exported = try fixture.tmp.dir.createFile(io, "explicit-partial-export", .{ .read = true, .permissions = .fromMode(0o600) });
    defer exported.close(io);
    const name = identity.handle.filename();
    const mutable = try fixture.directory.dir.openFile(io, &name, .{ .mode = .read_write });
    defer mutable.close(io);
    const Mutate = struct {
        output: storage.ExportFile,
        file: std.Io.File,
        writes: usize = 0,
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const destination = self.output.sink();
            try destination.writeFn(destination.context, bytes);
            self.writes += 1;
            try self.file.setLength(io, (try self.file.stat(io)).size - 1);
        }
        fn commit(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const destination = self.output.sink();
            try destination.commitFn(destination.context);
        }
        fn abort(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const destination = self.output.sink();
            destination.abortFn(destination.context);
        }
    };
    var mutate: Mutate = .{ .output = try storage.ExportFile.init(io, exported), .file = mutable };
    var reader = try fixture.directory.reader(identity.handle);
    defer reader.close();
    try std.testing.expectError(error.VaultRecordChanged, reader.exportVerified(&key, identity, .{ .context = &mutate, .writeFn = Mutate.write, .commitFn = Mutate.commit, .abortFn = Mutate.abort }, &workspace));
    try std.testing.expectEqual(@as(usize, 1), mutate.writes);
    try std.testing.expect(!mutate.output.committed);
    try std.testing.expect(mutate.output.abort_error == null);
    try std.testing.expectEqual(@as(u64, 0), (try exported.stat(io)).size);
    try zero(&workspace.plaintext);
}

test "vault storage: file permissions symlinks and hardlinks fail closed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    const identity = try record();
    try save(&fixture, &key, identity, "synthetic", &workspace, false);
    const name = identity.handle.filename();
    const file = try fixture.directory.dir.openFile(io, &name, .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.UnsafeCredentialPermissions, fixture.directory.reader(identity.handle));
    try file.setPermissions(io, .fromMode(0o600));
    try fixture.directory.dir.hardLink(&name, fixture.directory.dir, "second-link", io, .{});
    try std.testing.expectError(error.UnsafeCredentialFile, fixture.directory.reader(identity.handle));
    try fixture.directory.dir.deleteFile(io, "second-link");
    try fixture.directory.dir.deleteFile(io, &name);
    try fixture.directory.dir.symLink(io, "unrelated", &name, .{});
    try std.testing.expectError(error.SymbolicLinkNotAllowed, fixture.directory.reader(identity.handle));
    try std.testing.expectError(error.SymbolicLinkNotAllowed, save(&fixture, &key, identity, "must not replace symlink", &workspace, true));
}

test "vault storage: push JSON serialization exports through an explicit private file" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    var identity = try record();
    identity.kind = .cache_index;
    const value = .{ .account = "synthetic@example.test", .message = "hello" };
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try std.json.Stringify.value(value, .{}, &counter.writer);
    var writer: stream.Writer = undefined;
    try writer.init(&fixture.directory, &key, identity, @intCast(counter.fullCount()), &workspace, false, .{});
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.finish();
    const file = try fixture.tmp.dir.createFile(io, "explicit-export.json", .{ .read = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    var output = try storage.ExportFile.init(io, file);
    var reader = try fixture.directory.reader(identity.handle);
    defer reader.close();
    try reader.exportVerified(&key, identity, output.sink(), &workspace);
    try std.testing.expect(output.committed);
    var actual: [256]u8 = undefined;
    const size = try file.readPositional(io, &.{&actual}, 0);
    try std.testing.expectEqualStrings("{\"account\":\"synthetic@example.test\",\"message\":\"hello\"}", actual[0..size]);
}

test "vault storage: 50 MiB and above-metadata-limit attachments use one bounded workspace" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var workspace: t.StreamWorkspace = undefined;
    for ([_]usize{ 50 * 1024 * 1024, t.max_record_bytes + 1 }) |size| {
        const identity = try record();
        var block: [4093]u8 = @splat(0x6b);
        var writer: stream.Writer = undefined;
        try writer.init(&fixture.directory, &key, identity, size, &workspace, false, .{});
        defer writer.deinit();
        var left: usize = size;
        while (left != 0) {
            const count = @min(left, block.len);
            try writer.interface.writeAll(block[0..count]);
            left -= count;
        }
        try writer.finish();
        const Pattern = struct {
            count: usize = 0,
            committed: bool = false,
            fn write(context: *anyopaque, bytes: []const u8) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                for (bytes) |byte| if (byte != 0x6b) return error.WrongAttachmentByte;
                self.count += bytes.len;
            }
            fn commit(context: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.committed = true;
            }
            fn abort(_: *anyopaque) void {}
        };
        var pattern: Pattern = .{};
        var reader = try fixture.directory.reader(identity.handle);
        defer reader.close();
        try reader.exportVerified(&key, identity, .{ .context = &pattern, .writeFn = Pattern.write, .commitFn = Pattern.commit, .abortFn = Pattern.abort }, &workspace);
        try std.testing.expectEqual(@as(usize, size), pattern.count);
        try std.testing.expect(pattern.committed);
        try zero(&workspace.plaintext);
        try zero(&workspace.ciphertext);
        try std.testing.expect(@sizeOf(stream.Writer) < 4096);
        try std.testing.expect(@sizeOf(t.StreamWorkspace) == 128 * 1024);
    }
}

test "vault storage header: durable primary and backup preserve slots and wrong password cannot fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/durable-header", .{base});
    defer allocator.free(path);
    var store = try header.Store.open(io, path, true);
    defer store.close();
    var key = try crypto.createDataKey(io);
    defer key.wipe();
    var recovery = try crypto.createRecoveryKey(io);
    defer recovery.wipe();
    const scratch = try allocator.alloc(u8, try t.KdfParameters.fast_test.scratchBytes());
    defer allocator.free(scratch);
    const old: header.Header = .{ .vault_id = key.vault_id, .key_id = key.key_id, .root_record = try storage.Handle.create(io), .password = try crypto.testing.wrapPassword(io, scratch, "old synthetic password", &key), .recovery = try crypto.wrapRecovery(io, &recovery, &key) };
    try store.create(old, .{});
    try std.testing.expectError(error.PathAlreadyExists, store.create(old, .{}));
    var next = old;
    next.password = try crypto.testing.wrapPassword(io, scratch, "new synthetic password", &key);
    try store.save(next, .{});
    const loaded = try store.load();
    try std.testing.expect(!loaded.used_backup);
    try std.testing.expectEqualSlices(u8, &next.password, &loaded.header.password);
    try std.testing.expectEqualDeep(old.root_record, loaded.header.root_record);
    try std.testing.expectEqual(t.RecordKind.catalog, loaded.header.rootRecord().kind);
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.testing.unwrapPassword(io, scratch, "old synthetic password", &loaded.header.password, key.vault_id, key.key_id));
    try std.testing.expect(!(try store.load()).used_backup);
    var unlocked = try crypto.testing.unwrapPassword(io, scratch, "new synthetic password", &loaded.header.password, key.vault_id, key.key_id);
    defer unlocked.wipe();
    try std.testing.expectEqualSlices(u8, &key.bytes, &unlocked.bytes);
    const primary = try store.directory.dir.openFile(io, header.filename, .{ .mode = .read_write });
    try primary.writePositionalAll(io, "bad", 0);
    primary.close(io);
    const fallback = try store.load();
    try std.testing.expect(fallback.used_backup);
    try std.testing.expectEqualSlices(u8, &next.password, &fallback.header.password);
    try std.testing.expectError(error.VaultHeaderRepairRequired, store.save(next, .{}));
    var wrong_recovery = try crypto.createRecoveryKey(io);
    defer wrong_recovery.wipe();
    try std.testing.expectError(error.VaultAuthenticationFailed, store.unlockRecovery(&wrong_recovery));
    try std.testing.expect((try store.load()).used_backup);
    var rescued = try store.unlockRecovery(&recovery);
    defer rescued.key.wipe();
    try std.testing.expectEqualSlices(u8, &key.bytes, &rescued.key.bytes);
    try std.testing.expect(!(try store.load()).used_backup);
    try std.testing.expectError(error.VaultAuthenticationFailed, crypto.testing.unwrapPassword(io, scratch, "old synthetic password", &fallback.header.password, key.vault_id, key.key_id));
    var foreign = next;
    foreign.vault_id[0] ^= 1;
    @memcpy(foreign.password[24..40], &foreign.vault_id);
    @memcpy(foreign.recovery[24..40], &foreign.vault_id);
    try std.testing.expectError(error.VaultIdentityMismatch, store.save(foreign, .{}));
    foreign = next;
    foreign.key_id[0] ^= 1;
    @memcpy(foreign.password[40..56], &foreign.key_id);
    @memcpy(foreign.recovery[40..56], &foreign.key_id);
    try std.testing.expectError(error.VaultIdentityMismatch, store.save(foreign, .{}));
    var wire = try old.encode();
    for (0..wire.len) |index| {
        wire[index] ^= 0x80;
        if (header.Header.decode(&wire)) |_| return error.AcceptedCorruptHeader else |_| {}
        wire[index] ^= 0x80;
    }
    const PrimaryFailure = struct {
        step: storage.Step,
        hits: usize = 0,
        fn visit(context: ?*anyopaque, step: storage.Step) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (step == self.step) {
                self.hits += 1;
                // First occurrence writes the encrypted backup; second is
                // the primary replacement. Crash at each primary boundary.
                if (self.hits == 2) return error.SyntheticPowerLoss;
            }
        }
    };
    for ([_]storage.Step{ .created, .write, .file_synced, .published, .directory_synced }) |step| {
        try store.save(old, .{});
        var failure: PrimaryFailure = .{ .step = step };
        const expected_error = if (step == .published or step == .directory_synced) error.VaultDurabilityUncertain else error.SyntheticPowerLoss;
        try std.testing.expectError(expected_error, store.save(next, .{ .context = &failure, .visit = PrimaryFailure.visit }));
        store.close();
        store = try header.Store.open(io, path, false);
        const reopened = try store.load();
        try std.testing.expect(!reopened.used_backup);
        const expected_password = if (step == .published or step == .directory_synced) next.password else old.password;
        try std.testing.expectEqualSlices(u8, &expected_password, &reopened.header.password);
    }
    const BackupFailure = struct {
        hits: usize = 0,
        fn visit(context: ?*anyopaque, step: storage.Step) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (step == .created) {
                self.hits += 1;
                if (self.hits == 3) return error.SyntheticPowerLoss;
            }
        }
    };
    try store.save(old, .{});
    var backup_failure: BackupFailure = .{};
    try std.testing.expectError(error.VaultDurabilityUncertain, store.save(next, .{ .context = &backup_failure, .visit = BackupFailure.visit }));
    // A new primary is authoritative even while the backup refresh is pending.
    try std.testing.expectEqualSlices(u8, &next.password, &(try store.load()).header.password);
    var repaired = try store.unlockRecovery(&recovery);
    defer repaired.key.wipe();
    try store.directory.dir.deleteFile(io, header.filename);
    try std.testing.expectEqualSlices(u8, &next.password, &(try store.load()).header.password);
    try std.testing.expectError(error.PathAlreadyExists, store.create(next, .{}));
    var repaired_primary = try store.unlockRecovery(&recovery);
    defer repaired_primary.key.wipe();
    try std.testing.expect(!(try store.load()).used_backup);
    // An unknown primary format cannot silently downgrade via a v1 backup.
    const unknown = try store.directory.dir.openFile(io, header.filename, .{ .mode = .read_write });
    try unknown.writePositionalAll(io, &.{ 2, 0 }, 8);
    unknown.close(io);
    try std.testing.expectError(error.UnsupportedVaultVersion, store.load());
}
