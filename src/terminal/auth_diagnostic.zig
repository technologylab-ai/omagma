//! Google's most recent refusal of each account's terminal sign-in, kept so a
//! person or agent can tell an administrator's re-authentication policy from
//! a revoked or expired token. Values are oauth.TokenError diagnostics: a
//! fixed machine vocabulary and sanitized prose, never token material.
//!
//! Only the terminal grant's own credential is described: every entry carries
//! the grant identity it was observed with, and status reports it only for the
//! account's current grant. The bar's read-only credential and the background
//! cache refresh (which uses it) are never recorded here.
//!
//! A process keeps what it observed (bounded to the configured accounts). A
//! plaintext credential-store setup also keeps a private owner-only sidecar
//! beside the grant registry, so a later one-shot `terminal-auth status` can
//! explain an expired sign-in; the first verified refresh or authorization of
//! that grant in any process removes it again. The encrypted vault keeps the
//! value in the running backend's memory only; nothing is written outside it.
const std = @import("std");
const b = @import("../bounded.zig");
const oauth = @import("../oauth.zig");
const limits = @import("../limits.zig");
const j = @import("json.zig");

pub const Observed = enum(u8) { unknown, failed, ok };
pub const Slot = struct {
    account: b.Text(limits.max_address) = .{},
    /// Terminal grant identity whose credential was observed.
    grant: b.Text(64) = .{},
    observed: Observed = .unknown,
    /// This process already brought the sidecar in line with `observed`.
    sidecar_settled: bool = false,
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

/// A grant identity is the 64-character lowercase SHA-256 hex of auth.zig.
pub fn validGrant(grant: []const u8) bool {
    if (grant.len != 64) return false;
    for (grant) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
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

/// The terminal grant's refresh was refused. A missing body diagnostic still
/// records the refusal itself. Other credentials are never recorded.
pub fn recordFailure(account: []const u8, grant: []const u8, value: oauth.TokenError, at_ms: i64) void {
    if (!validGrant(grant)) return;
    acquire();
    defer lock.unlock();
    const slot = slotFor(account) orelse return;
    slot.grant.set(grant) catch return;
    slot.observed = .failed;
    slot.sidecar_settled = false;
    slot.at_ms = at_ms;
    slot.value = value;
    if (!slot.value.present()) slot.value.code.set("invalid_grant") catch {};
}

/// A verified refresh or authorization of the terminal grant succeeded: the
/// old reason is obsolete in memory now and in the sidecar at the next sync.
pub fn recordSuccess(account: []const u8, grant: []const u8) void {
    if (!validGrant(grant)) return;
    acquire();
    defer lock.unlock();
    const slot = slotFor(account) orelse return;
    const changed = slot.observed != .ok or !std.mem.eql(u8, slot.grant.slice(), grant);
    slot.grant.set(grant) catch return;
    slot.observed = .ok;
    if (changed) slot.sidecar_settled = false;
    slot.at_ms = 0;
    slot.value = .{};
}

/// The terminal grant was revoked locally: nothing is known any more.
pub fn forget(account: []const u8) void {
    acquire();
    defer lock.unlock();
    for (&slots, 0..) |*slot, index| if (slot.account.len != 0 and std.ascii.eqlIgnoreCase(slot.account.slice(), account)) {
        slot.* = .{};
        used[index] = 0;
    };
}

pub fn observed(account: []const u8) Slot {
    acquire();
    defer lock.unlock();
    for (slots) |slot| if (slot.account.len != 0 and std.ascii.eqlIgnoreCase(slot.account.slice(), account)) return slot;
    return .{};
}

/// Whether a verified success in this process still has to remove a
/// persisted refusal. At most one sidecar read per account and process.
pub fn needsPersistedClear(account: []const u8) bool {
    const seen = observed(account);
    return seen.observed == .ok and !seen.sidecar_settled;
}

fn settle(account: []const u8, state: Observed) void {
    acquire();
    defer lock.unlock();
    for (&slots) |*slot| if (slot.account.len != 0 and std.ascii.eqlIgnoreCase(slot.account.slice(), account) and slot.observed == state) {
        slot.sidecar_settled = true;
    };
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

/// lastRefreshError for auth.status about the account's current terminal
/// grant (null without one): this process's own observation of that grant
/// first, then the private sidecar when one is used.
pub fn status(io: std.Io, a: std.mem.Allocator, sidecar: ?[]const u8, account: []const u8, grant: ?[]const u8) !?Report {
    const current = grant orelse return null;
    if (!validGrant(current)) return null;
    const seen = observed(account);
    if (std.mem.eql(u8, seen.grant.slice(), current)) switch (seen.observed) {
        .failed => return try report(a, &seen.value, seen.at_ms),
        .ok => return null,
        .unknown => {},
    };
    const path = sidecar orelse return null;
    const entries = load(io, a, path) catch return null;
    for (entries) |entry| if (std.ascii.eqlIgnoreCase(entry.account.slice(), account) and std.mem.eql(u8, entry.grant.slice(), current)) return try report(a, &entry.value, entry.at_ms);
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

/// Read and re-sanitize every entry; a symlinked, shared or tampered file is
/// not trusted, and entries cannot add controls, long token-like runs, a
/// malformed grant identity or more rows than the account limit.
fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]Slot {
    const dir = std.Io.Dir.cwd();
    const before = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return &.{} else return err;
    try validateFile(before);
    const file = try dir.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    try validateFile(try file.stat(io));
    var buffer: [max_sidecar_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var size: usize = 0;
    while (size < buffer.len) {
        const count = try file.readPositional(io, &.{buffer[size..]}, size);
        if (count == 0) break;
        size += count;
    }
    try b.preflight(buffer[0..size]);
    const parsed = try std.json.parseFromSliceLeaky(j.Value, a, buffer[0..size], .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = 1024 });
    if (try j.integer(parsed, "version", 0) != 2) return error.InvalidDiagnostics;
    const list = j.get(parsed, "accounts") orelse return error.InvalidDiagnostics;
    if (list != .array) return error.InvalidDiagnostics;
    var result: std.ArrayList(Slot) = .empty;
    for (list.array.items) |item| {
        if (result.items.len == limits.max_accounts) break;
        const account = j.text(item, "account");
        b.address(account) catch continue;
        const grant = j.text(item, "grantId");
        if (!validGrant(grant)) continue;
        var slot: Slot = .{ .observed = .failed, .at_ms = @max(0, j.integer(item, "at", 0) catch 0), .value = oauth.TokenError.fromJson(0, item) };
        if (!slot.value.present()) continue;
        try slot.account.set(account);
        try slot.grant.set(grant);
        try result.append(a, slot);
    }
    return result.items;
}

/// Atomic owner-only replacement in the registry's directory. A symlink at
/// the sidecar's name is replaced, never followed or written through.
fn save(io: std.Io, a: std.mem.Allocator, path: []const u8, entries: []const Slot) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    if (entries.len == 0) {
        dir.deleteFile(io, basename) catch |err| if (err != error.FileNotFound) return err;
        return;
    }
    const Row = struct { account: []const u8, grantId: []const u8, @"error": []const u8, error_subtype: []const u8, error_description: []const u8, at: i64 };
    var rows: [limits.max_accounts]Row = undefined;
    for (entries, 0..) |*entry, index| rows[index] = .{ .account = entry.account.slice(), .grantId = entry.grant.slice(), .@"error" = entry.value.code.slice(), .error_subtype = entry.value.subtype.slice(), .error_description = entry.value.description.slice(), .at = entry.at_ms };
    const bytes = try j.encodeAlloc(a, .{ .version = @as(u8, 2), .accounts = rows[0..entries.len] }, .{});
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
    settle(account, .failed);
}

/// After a verified refresh or authorization: no entry for this account
/// remains for any later process.
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
    settle(account, .ok);
}

fn googleRefusal(a: std.mem.Allocator, body: []const u8) !oauth.TokenError {
    return oauth.TokenError.fromJson(400, try std.json.parseFromSliceLeaky(j.Value, a, body, .{}));
}
const grant_one = "1111111111111111111111111111111111111111111111111111111111111111";
const grant_two = "2222222222222222222222222222222222222222222222222222222222222222";

fn longestTokenRun(text: []const u8) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (text) |c| {
        run = if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~+/=", c) != null) run + 1 else 0;
        longest = @max(longest, run);
    }
    return longest;
}

test "reconnect diagnostics: Google's reason is kept bounded, sanitized and classified" {
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
    try std.testing.expectEqualStrings("invalidGrant", (try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"Bad Request\"}")).kind());
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

test "reconnect diagnostics: dropped bytes cannot split a credential into short visible pieces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 19-character pieces split by a control, a non-ASCII letter, a
    // zero-width space and DEL are one credential-shaped run: none of it
    // survives, neither joined nor as separate pieces.
    const split = try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"leak 1//0gAAAAAAAAAAAAAA\\u0001BBBBBBBBBBBBBBBBBBB\\u00e9CCCCCCCCCCCCCCCCCCC\\u200bDDDDDDDDDDDDDDDDDDD\\u007fEEEEEEEEEEEEEEEEEEE end\"}");
    const text = split.description.slice();
    try std.testing.expect(longestTokenRun(text) < 20);
    try std.testing.expectEqualStrings("leak [redacted] end", text);
    for (text) |byte| try std.testing.expect(byte >= 32 and byte < 127);
    // Ordinary words around dropped bytes stay readable, and ASCII
    // whitespace still separates short words.
    const words = try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"Zugriff f\\u00fcr\\u0001 Konto\\n\\tabgelehnt \\u200b(invalid_rapt)\"}");
    try std.testing.expectEqualStrings("Zugriff f r Konto abgelehnt (invalid_rapt)", words.description.slice());
}

test "reconnect diagnostics: only the current terminal grant's refusal is reported, then cleared" {
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
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    // No terminal grant identity: nothing is recorded or reported.
    recordFailure("self@example.test", "", .{}, 1);
    try std.testing.expectEqual(Observed.unknown, observed("self@example.test").observed);
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", null) == null);
    recordFailure("self@example.test", grant_one, try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_description\":\"reauth related error (invalid_rapt)\",\"error_subtype\":\"invalid_rapt\"}"), 1234);
    const seen = (try status(io, a, null, "SELF@example.test", grant_one)).?;
    try std.testing.expectEqualStrings("invalid_rapt", seen.subtype);
    try std.testing.expectEqual(@as(i64, 1234), seen.at);
    // Another grant identity (the account was re-authorized differently).
    try std.testing.expect(try status(io, a, null, "self@example.test", grant_two) == null);
    try persist(io, a, sidecar, "self@example.test");
    const stat = try std.Io.Dir.cwd().statFile(io, sidecar, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    // A new process has observed nothing and reads the sidecar for this grant only.
    reset();
    try std.testing.expectEqualStrings("reauthenticationRequired", (try status(io, a, sidecar, "self@example.test", grant_one)).?.kind);
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_two) == null);
    try std.testing.expect(try status(io, a, null, "self@example.test", grant_one) == null);
    // A verified refresh of that grant hides the reason at once and asks the
    // caller to remove the persisted copy, once.
    try std.testing.expect(!needsPersistedClear("self@example.test"));
    recordSuccess("self@example.test", grant_one);
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    try std.testing.expect(needsPersistedClear("self@example.test"));
    try clearPersisted(io, a, sidecar, "self@example.test");
    try std.testing.expect(!needsPersistedClear("self@example.test"));
    recordSuccess("self@example.test", grant_one);
    try std.testing.expect(!needsPersistedClear("self@example.test"));
    reset();
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, sidecar, .{}));
    // A missing body diagnostic still records the refusal itself; forget clears it.
    recordFailure("other@example.test", grant_two, .{}, 1);
    try std.testing.expectEqualStrings("invalid_grant", (try status(io, a, null, "other@example.test", grant_two)).?.@"error");
    forget("other@example.test");
    try std.testing.expect(try status(io, a, null, "other@example.test", grant_two) == null);
}

test "reconnect diagnostics: a symlinked, shared or oversized sidecar is not trusted and is replaced, never written through" {
    reset();
    defer reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const entry = "{\"version\":2,\"accounts\":[{\"account\":\"self@example.test\",\"grantId\":\"" ++ grant_one ++ "\",\"error\":\"invalid_grant\",\"at\":1}]}";
    const shared = try temporary.dir.createFile(io, sidecar_name, .{ .permissions = .fromMode(0o644) });
    try shared.writeStreamingAll(io, entry);
    shared.close(io);
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, sidecar_name });
    try std.testing.expect(try status(io, a, path, "self@example.test", grant_one) == null);
    try std.testing.expectError(error.InsecureDiagnosticsFile, load(io, a, path));
    try temporary.dir.deleteFile(io, sidecar_name);
    // A private target behind a symlink is neither read nor written through.
    const target = try temporary.dir.createFile(io, "elsewhere.json", .{ .permissions = .fromMode(0o600) });
    try target.writeStreamingAll(io, entry);
    target.close(io);
    try temporary.dir.symLink(io, "elsewhere.json", sidecar_name, .{});
    try std.testing.expect(try status(io, a, path, "self@example.test", grant_one) == null);
    recordFailure("self@example.test", grant_two, .{}, 7);
    try persist(io, a, path, "self@example.test");
    const replaced = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, replaced.kind);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(replaced.permissions.toMode() & 0o777)));
    var original: [256]u8 = undefined;
    try std.testing.expectEqualStrings(entry, try temporary.dir.readFile(io, "elsewhere.json", &original));
    reset();
    try std.testing.expectEqual(@as(i64, 7), (try status(io, a, path, "self@example.test", grant_two)).?.at);
    // Version-1 files of the first implementation carry no grant: ignored.
    const old = try temporary.dir.createFile(io, sidecar_name, .{ .permissions = .fromMode(0o600), .truncate = true });
    try old.writeStreamingAll(io, "{\"version\":1,\"accounts\":[{\"account\":\"self@example.test\",\"error\":\"invalid_grant\",\"at\":1}]}");
    old.close(io);
    try std.testing.expectError(error.InvalidDiagnostics, load(io, a, path));
    try std.testing.expect(try status(io, a, path, "self@example.test", grant_two) == null);
}
