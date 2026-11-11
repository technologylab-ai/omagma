//! Google's most recent refusal of each account's stored sign-in, kept so a
//! person or agent can tell an administrator's re-authentication policy from
//! a revoked or expired token. Values are oauth.TokenError diagnostics: a
//! fixed machine vocabulary and sanitized prose, never token material.
//!
//! A process keeps what it observed (bounded to the configured accounts). A
//! plaintext credential-store setup also keeps a private owner-only sidecar
//! beside the grant registry, so a later one-shot `terminal-auth status` can
//! explain an expired sign-in. The encrypted vault keeps the value in the
//! running backend's memory only; nothing is written outside the vault.
const std = @import("std");
const b = @import("../bounded.zig");
const oauth = @import("../oauth.zig");
const limits = @import("../limits.zig");
const j = @import("json.zig");

pub const Observed = enum(u8) { unknown, failed, ok };
pub const Slot = struct {
    account: b.Text(limits.max_address) = .{},
    observed: Observed = .unknown,
    at_ms: i64 = 0,
    value: oauth.TokenError = .{},
};
var lock: std.atomic.Mutex = .unlocked;
var slots: [limits.max_accounts]Slot = @splat(.{});
var stamp: u64 = 0;
var used: [limits.max_accounts]u64 = @splat(0);
pub const reservation_bytes = @sizeOf(@TypeOf(slots)) + @sizeOf(@TypeOf(used)) + 16;
pub const sidecar_name = "terminal-auth-diagnostics.json";
const max_sidecar_bytes = 8 * 1024;

fn acquire() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

/// Caller holds the lock. Reuses the account's slot, then a free one, then the
/// least recently written; the table never grows beyond the account limit.
fn slotFor(account: []const u8) ?*Slot {
    if (account.len == 0 or account.len > limits.max_address) return null;
    var oldest: usize = 0;
    for (&slots, 0..) |*slot, index| {
        if (slot.account.len != 0 and std.ascii.eqlIgnoreCase(slot.account.slice(), account)) {
            stamp +%= 1;
            used[index] = stamp;
            return slot;
        }
        if (used[index] < used[oldest]) oldest = index;
    }
    for (&slots, 0..) |*slot, index| if (slot.account.len == 0) {
        oldest = index;
        break;
    };
    slots[oldest] = .{};
    slots[oldest].account.set(account) catch return null;
    stamp +%= 1;
    used[oldest] = stamp;
    return &slots[oldest];
}

/// A refresh was refused. A missing body diagnostic still records the refusal.
pub fn recordFailure(account: []const u8, value: oauth.TokenError, at_ms: i64) void {
    acquire();
    defer lock.unlock();
    const slot = slotFor(account) orelse return;
    slot.observed = .failed;
    slot.at_ms = at_ms;
    slot.value = value;
    if (!slot.value.present()) slot.value.code.set("invalid_grant") catch {};
}

/// A verified refresh or authorization succeeded: the old reason is obsolete.
pub fn recordSuccess(account: []const u8) void {
    acquire();
    defer lock.unlock();
    const slot = slotFor(account) orelse return;
    slot.observed = .ok;
    slot.at_ms = 0;
    slot.value = .{};
}

pub fn observed(account: []const u8) Slot {
    acquire();
    defer lock.unlock();
    for (slots) |slot| if (slot.account.len != 0 and std.ascii.eqlIgnoreCase(slot.account.slice(), account)) return slot;
    return .{};
}

/// Test isolation only; production slots live for the process.
pub fn reset() void {
    acquire();
    defer lock.unlock();
    slots = @splat(.{});
    used = @splat(0);
}

pub const Report = struct {
    @"error": []const u8,
    subtype: []const u8,
    description: []const u8,
    kind: []const u8,
    at: i64,
};

fn report(a: std.mem.Allocator, value: *const oauth.TokenError, at_ms: i64) !Report {
    return .{
        .@"error" = try a.dupe(u8, value.code.slice()),
        .subtype = try a.dupe(u8, value.subtype.slice()),
        .description = try a.dupe(u8, value.description.slice()),
        .kind = value.kind(),
        .at = at_ms,
    };
}

/// lastRefreshError for auth.status: this process's own observation first;
/// an unobserved account falls back to the private sidecar when one is used.
pub fn status(io: std.Io, a: std.mem.Allocator, sidecar: ?[]const u8, account: []const u8) !?Report {
    const seen = observed(account);
    switch (seen.observed) {
        .failed => return try report(a, &seen.value, seen.at_ms),
        .ok => return null,
        .unknown => {},
    }
    const path = sidecar orelse return null;
    const entries = load(io, a, path) catch return null;
    for (entries) |entry| if (std.ascii.eqlIgnoreCase(entry.account.slice(), account)) return try report(a, &entry.value, entry.at_ms);
    return null;
}

/// The sidecar beside a plaintext grant registry path.
pub fn sidecarPath(a: std.mem.Allocator, grant_file: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(grant_file) orelse ".";
    return std.fs.path.join(a, &.{ parent, sidecar_name });
}

fn validateFile(stat: std.Io.File.Stat) !void {
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.InsecureDiagnosticsFile;
    if (stat.size > max_sidecar_bytes) return error.DiagnosticsTooLarge;
}

/// Read and re-sanitize every entry; a tampered file cannot add controls,
/// long token-like runs or more entries than the account limit.
fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]Slot {
    const dir = std.Io.Dir.cwd();
    const before = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return &.{} else return err;
    try validateFile(before);
    const file = try dir.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    try validateFile(try file.stat(io));
    var buffer: [max_sidecar_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const size = try file.readPositional(io, &.{&buffer}, 0);
    try b.preflight(buffer[0..size]);
    const parsed = try std.json.parseFromSliceLeaky(j.Value, a, buffer[0..size], .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = 1024 });
    if (try j.integer(parsed, "version", 0) != 1) return error.InvalidDiagnostics;
    const list = j.get(parsed, "accounts") orelse return error.InvalidDiagnostics;
    if (list != .array) return error.InvalidDiagnostics;
    var result: std.ArrayList(Slot) = .empty;
    for (list.array.items) |item| {
        if (result.items.len == limits.max_accounts) break;
        const account = j.text(item, "account");
        b.address(account) catch continue;
        var slot: Slot = .{ .observed = .failed, .at_ms = @max(0, try j.integer(item, "at", 0)), .value = oauth.TokenError.fromJson(0, item) };
        if (!slot.value.present()) continue;
        try slot.account.set(account);
        try result.append(a, slot);
    }
    return result.items;
}

fn save(io: std.Io, a: std.mem.Allocator, path: []const u8, entries: []const Slot) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    if (entries.len == 0) {
        dir.deleteFile(io, basename) catch |err| if (err != error.FileNotFound) return err;
        return;
    }
    const Row = struct { account: []const u8, @"error": []const u8, error_subtype: []const u8, error_description: []const u8, at: i64 };
    var rows: [limits.max_accounts]Row = undefined;
    for (entries, 0..) |*entry, index| rows[index] = .{ .account = entry.account.slice(), .@"error" = entry.value.code.slice(), .error_subtype = entry.value.subtype.slice(), .error_description = entry.value.description.slice(), .at = entry.at_ms };
    const bytes = try j.encodeAlloc(a, .{ .version = @as(u8, 1), .accounts = rows[0..entries.len] }, .{});
    if (bytes.len > max_sidecar_bytes) return error.DiagnosticsTooLarge;
    var atomic = try dir.createFileAtomic(io, basename, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Copy this process's observed failure into the sidecar. Best-effort for
/// callers: the diagnostic never decides whether an operation succeeds.
pub fn persist(io: std.Io, a: std.mem.Allocator, path: []const u8, account: []const u8) !void {
    const seen = observed(account);
    if (seen.observed != .failed) return;
    const existing = load(io, a, path) catch &.{};
    var next: std.ArrayList(Slot) = .empty;
    try next.append(a, seen);
    for (existing) |entry| if (!std.ascii.eqlIgnoreCase(entry.account.slice(), account) and next.items.len < limits.max_accounts) try next.append(a, entry);
    try save(io, a, path, next.items);
}

/// After a verified authorization: no entry for this account remains.
pub fn clearPersisted(io: std.Io, a: std.mem.Allocator, path: []const u8, account: []const u8) !void {
    const existing = load(io, a, path) catch &.{};
    var next: std.ArrayList(Slot) = .empty;
    var changed = false;
    for (existing) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.account.slice(), account)) {
            changed = true;
            continue;
        }
        try next.append(a, entry);
    }
    if (changed) try save(io, a, path, next.items);
}

fn googleRefusal(a: std.mem.Allocator, body: []const u8) !oauth.TokenError {
    return oauth.TokenError.fromJson(400, try std.json.parseFromSliceLeaky(j.Value, a, body, .{}));
}

test "auth diagnostics: Google's reason is kept bounded, sanitized and classified" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rapt = try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"reauth related error (invalid_rapt)\",\"error_uri\":\"https://support.google.com/a/answer/9368756\",\"error_subtype\":\"invalid_rapt\"}");
    try std.testing.expectEqualStrings("invalid_grant", rapt.code.slice());
    try std.testing.expectEqualStrings("invalid_rapt", rapt.subtype.slice());
    try std.testing.expectEqualStrings("reauth related error (invalid_rapt)", rapt.description.slice());
    try std.testing.expectEqualStrings("reauthenticationRequired", rapt.kind());
    const revoked = try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}");
    try std.testing.expectEqualStrings("expiredOrRevoked", revoked.kind());
    try std.testing.expectEqualStrings("", revoked.subtype.slice());
    // Echoed credentials, controls and an injected terminal escape never survive.
    const hostile = try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_subtype\":\"Bad Value\\u001b[2J\",\"error_description\":\"Bad\\u001b]52;c;x\\u0007 token 1//0gSyntheticRefreshTokenMaterial-abc_DEF and code 4/0AeanS0aSyntheticAuthorizationCode\\n\\tend\"}");
    try std.testing.expectEqualStrings("", hostile.subtype.slice());
    const text = hostile.description.slice();
    try std.testing.expect(std.mem.indexOf(u8, text, "Synthetic") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[redacted]") != null);
    for (text) |byte| try std.testing.expect(byte >= 32 and byte < 127);
    try std.testing.expect(std.mem.endsWith(u8, text, "end"));
    var words: std.ArrayList(u8) = .empty;
    for (0..80) |_| try words.appendSlice(a, "word ");
    const long = try googleRefusal(a, try std.fmt.allocPrint(a, "{{\"error\":\"invalid_grant\",\"error_description\":\"{s}\"}}", .{words.items}));
    try std.testing.expect(long.description.len <= 160);
    try std.testing.expect(std.mem.endsWith(u8, long.description.slice(), "..."));
}

test "auth diagnostics: observations, success and the private sidecar" {
    reset();
    defer reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    const sidecar = try sidecarPath(a, try std.fmt.allocPrint(a, "{s}/terminal-grants.json", .{root}));
    try std.testing.expect(try status(io, a, sidecar, "self@example.test") == null);
    recordFailure("self@example.test", try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"reauth related error (invalid_rapt)\",\"error_subtype\":\"invalid_rapt\"}"), 1234);
    const seen = (try status(io, a, null, "SELF@example.test")).?;
    try std.testing.expectEqualStrings("invalid_rapt", seen.subtype);
    try std.testing.expectEqual(@as(i64, 1234), seen.at);
    try persist(io, a, sidecar, "self@example.test");
    const stat = try std.Io.Dir.cwd().statFile(io, sidecar, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    // A new process has observed nothing and reads the sidecar.
    reset();
    const later = (try status(io, a, sidecar, "self@example.test")).?;
    try std.testing.expectEqualStrings("reauthenticationRequired", later.kind);
    try std.testing.expect(try status(io, a, null, "self@example.test") == null);
    // A verified success in this process hides the persisted older reason;
    // authorization clears it for every later process.
    recordSuccess("self@example.test");
    try std.testing.expect(try status(io, a, sidecar, "self@example.test") == null);
    try clearPersisted(io, a, sidecar, "self@example.test");
    reset();
    try std.testing.expect(try status(io, a, sidecar, "self@example.test") == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, sidecar, .{}));
    // A missing body diagnostic still records the refusal itself.
    recordFailure("other@example.test", .{}, 1);
    try std.testing.expectEqualStrings("invalid_grant", (try status(io, a, null, "other@example.test")).?.@"error");
}

test "auth diagnostics: a world-readable or oversized sidecar is not trusted" {
    reset();
    defer reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, sidecar_name, .{ .permissions = .fromMode(0o644) });
    try file.writeStreamingAll(io, "{\"version\":1,\"accounts\":[{\"account\":\"self@example.test\",\"error\":\"invalid_grant\",\"at\":1}]}");
    file.close(io);
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, sidecar_name });
    try std.testing.expect(try status(io, a, path, "self@example.test") == null);
    try std.testing.expectError(error.InsecureDiagnosticsFile, load(io, a, path));
}
