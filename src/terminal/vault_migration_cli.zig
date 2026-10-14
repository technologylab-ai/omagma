//! Local-only onboarding orchestration. Its secret capture never becomes a
//! transport request or a JSON response. The caller supplies no-echo prompts.
const std = @import("std");
const Owner = @import("vault_owner.zig").Owner;
const vt = @import("vault_types.zig");
const t = @import("types.zig");
const journal = @import("vault_migration_journal.zig");
const identity = @import("vault_migration_identity.zig");
const migration = @import("vault_migration.zig");
const header = @import("vault_header.zig");
const activation = @import("vault_activation.zig");
const j = @import("json.zig");
pub const Prompts = struct {
    password: *const fn (std.Io, []const u8, []u8) anyerror![]const u8,
    new_password: *const fn (std.Io, []u8) anyerror![]const u8,
    recovery: *const fn (std.Io, *const vt.RecoveryKey) anyerror!void,
};
pub const Arguments = struct {
    source: ?journal.Source = null,
    resume_copy: bool = false,
    fixture_stop_after: ?usize = null,
    allow_unavailable_source: bool = false,
};
pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, verb: []const u8, vault_path: ?[]const u8, socket_path: []const u8, options: t.Options, args: Arguments, prompts: Prompts) !void {
    if (args.fixture_stop_after != null and !options.fixtures) return error.InvalidFixtureControl;
    var wiping: @import("vault_allocator.zig").WipingAllocator = .{ .backing = allocator };
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.eql(u8, verb, "inventory")) {
        if (args.resume_copy or args.fixture_stop_after != null) return error.UnknownOption;
        const metadata = try identity.Metadata.load(io, a, env, args.source orelse return error.VaultMigrationSourceRequired);
        const plan = try migration.inventory(io, a, allocator, metadata, options, false, null);
        const report = try Report.init(a, plan);
        return output(io, a, .{ .ok = true, .data = .{ .accounts = report.rows[0..report.count], .objects = report.objects, .plaintextBytes = report.bytes, .grants = metadata.registry.accounts.len, .credentialStore = @tagName(metadata.config.credential_store), .credentialsRead = false, .sourceRetained = true } });
    }
    const path = vault_path orelse return error.VaultDirectoryRequired;
    const owner = try a.create(Owner);
    owner.* = try Owner.initForMigration(io, allocator, env, path, options);
    defer owner.deinit();
    var password: [vt.max_password_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &password);
    if (std.mem.eql(u8, verb, "activate")) {
        if (args.source != null or args.resume_copy or args.fixture_stop_after != null) return error.UnknownOption;
        const id = std.fmt.bytesToHex(owner.known_vault_id orelse return error.VaultMigrationHeaderRequired, .lower);
        // Reject conflicting routing before prompting or running the KDF.
        const marker: activation.Marker = .{ .schema = 1, .vaultDirectory = path, .vaultId = &id, .socketPath = socket_path };
        _ = try activation.parse(a, try j.encodeAlloc(a, marker, .{}));
        if (try activation.load(io, a, env)) |previous| {
            if (!std.mem.eql(u8, previous.vaultDirectory, path) or !std.mem.eql(u8, previous.vaultId, &id) or !std.mem.eql(u8, previous.socketPath, socket_path)) return error.VaultAlreadyActive;
        }
        try owner.unlock(try prompts.password(io, "Vault password: ", &password));
        var log = try journal.Journal.open(io, a, path, &owner.key, &owner.workspace, owner.catalog_owner.?.root.handle, false);
        defer log.close();
        const manifest = try log.readManifest(a);
        const progress = try log.readProgress(a, manifest);
        try migration.verify(owner, a, &log, manifest, progress);
        var freshness = try migration.activationFreshness(owner, manifest);
        defer freshness.close();
        if (freshness.unavailable and !args.allow_unavailable_source) return error.VaultMigrationSourceUnavailable;
        try activation.publish(io, a, env, marker);
        return output(io, a, .{ .ok = true, .data = .{ .activated = true, .vaultId = &id, .sourceRetained = true, .sourceFreshness = if (freshness.unavailable) "unavailable-acknowledged" else "verified", .notice = "Original plaintext remains at the source; cleanup requires a separate explicit decision." } });
    }
    if (!std.mem.eql(u8, verb, "migrate")) return error.UnknownCommand;
    const source = args.source orelse return error.VaultMigrationSourceRequired;
    const exists = try headerExists(io, path);
    if (exists and !args.resume_copy) return error.VaultMigrationResumeRequired;
    if (!exists and args.resume_copy) return error.VaultMigrationHeaderRequired;
    const metadata = try identity.Metadata.load(io, a, env, source);
    var leases = try migration.SourceLeases.acquire(io, allocator, metadata, options, true);
    defer leases.close();
    // All source admission, capacity checks and exact credential capture happen
    // before password/recovery prompts. Account scratch is released immediately.
    const report = blk: {
        var check: std.heap.ArenaAllocator = .init(wiping.allocator());
        defer check.deinit();
        break :blk try Report.init(a, try migration.inventory(io, check.allocator(), allocator, metadata, options, true, &leases));
    };
    const captured = try identity.capture(io, a, metadata);
    const preflight = try j.encodeAlloc(a, .{ .preflight = .{ .accounts = report.rows[0..report.count], .objects = report.objects, .plaintextBytes = report.bytes, .grants = metadata.registry.accounts.len, .credentials = captured.token_count, .sourceRetained = true } }, .{});
    try std.Io.File.stderr().writeStreamingAll(io, preflight);
    try std.Io.File.stderr().writeStreamingAll(io, "\n");
    if (args.resume_copy) {
        try owner.unlock(try prompts.password(io, "Vault password: ", &password));
    } else {
        const secret = try prompts.new_password(io, &password);
        var recovery = try @import("vault_crypto.zig").createRecoveryKey(io);
        defer recovery.wipe();
        try prompts.recovery(io, &recovery);
        try owner.createConfigured(secret, &recovery, captured.config);
    }
    migration.copy(owner, a, metadata, captured, .{ .fixture_stop_after = args.fixture_stop_after, .leases = &leases }) catch |err| {
        if (err == error.VaultMigrationSourceChanged) try std.Io.File.stderr().writeStreamingAll(io, "Source changed since this migration began. Keep this vault for recovery and start a new migration in a new empty vault directory.\n");
        return err;
    };
    try owner.lock();
    return output(io, a, .{ .ok = true, .data = .{ .verified = true, .activated = false, .accounts = report.rows[0..report.count], .objects = report.objects, .grants = metadata.registry.accounts.len, .credentials = captured.token_count, .sourceRetained = true, .notice = "Original plaintext remains at the source. Verify the vault, then explicitly activate it; cleanup is a separate decision." } });
}
const Row = struct { account: []const u8, present: bool, objects: usize, mail: usize, drafts: usize, queued: usize };
const Report = struct {
    rows: [3]Row = undefined,
    count: usize = 0,
    objects: usize = 0,
    bytes: usize = 0,
    fn init(a: std.mem.Allocator, plan: migration.Inventory) !Report {
        var result: Report = .{ .count = plan.accounts.len, .objects = plan.object_count, .bytes = plan.plaintext_bytes };
        for (plan.accounts, 0..) |entry, i| result.rows[i] = .{ .account = try a.dupe(u8, entry.account), .present = entry.present, .objects = entry.objects.len, .mail = entry.mail_count, .drafts = entry.draft_count, .queued = entry.queued_count };
        return result;
    }
};

fn headerExists(io: std.Io, path: []const u8) !bool {
    var saved = header.Store.open(io, path, false) catch |err| if (err == error.FileNotFound) return false else return err;
    defer saved.close();
    for ([_][]const u8{ header.filename, header.backup_filename }) |name| {
        if (saved.directory.dir.statFile(io, name, .{ .follow_symlinks = false })) |_| return true else |err| if (err != error.FileNotFound) return err;
    }
    return false;
}
fn output(io: std.Io, a: std.mem.Allocator, value: anytype) !void {
    const bytes = try j.encodeAlloc(a, value, .{});
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
