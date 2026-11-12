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
//! The grant identity names a capability set, not one authorization: a
//! reconnect keeps it. Every observation therefore carries its time, and a
//! refusal is current only while it is newer than the grant's latest
//! known-good time (a verified refresh or an authorization, in any process).
//! A refused request is timed by when its credential was read, so a request
//! that still used the replaced token can never outdate a reconnect.
//!
//! A process keeps what it observed (bounded to the configured accounts). A
//! plaintext credential-store setup also keeps a private owner-only sidecar
//! beside the grant registry (one row per account: the latest refusal and the
//! latest known-good time), updated under an exclusive lock, so a later
//! one-shot `terminal-auth status` or another open TUI sees the same truth.
//! The encrypted vault keeps the value in the running backend's memory only;
//! nothing is written outside it.
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
    /// This process already brought the sidecar in line with `observed`
    /// (or tried once: an unwritable directory is not retried forever).
    sidecar_settled: bool = false,
    /// Unix milliseconds: when the refused credential was read, or when the
    /// verified success happened.
    at_ms: i64 = 0,
    value: oauth.TokenError = .{},
};
var lock: std.atomic.Mutex = .unlocked;
var slots: [limits.max_accounts]Slot = @splat(.{});
var stamp: u64 = 0;
var used: [limits.max_accounts]u64 = @splat(0);
pub const reservation_bytes = @sizeOf(@TypeOf(slots)) + @sizeOf(@TypeOf(used)) + 16;
pub const sidecar_name = "terminal-auth-diagnostics.json";
pub const lock_name = "terminal-auth-diagnostics.lock";
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

/// The terminal grant's refresh was refused. `at_ms` is when the refused
/// credential was read. A missing body diagnostic still records the refusal
/// itself. Other credentials are never recorded.
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

/// A verified refresh or authorization of the terminal grant succeeded at
/// `at_ms`: the old reason is obsolete in memory now and in the sidecar at
/// the next sync.
pub fn recordSuccess(account: []const u8, grant: []const u8, at_ms: i64) void {
    if (!validGrant(grant)) return;
    acquire();
    defer lock.unlock();
    const slot = slotFor(account) orelse return;
    const changed = slot.observed != .ok or !std.mem.eql(u8, slot.grant.slice(), grant);
    if (changed) slot.at_ms = 0;
    slot.grant.set(grant) catch return;
    slot.observed = .ok;
    if (changed) slot.sidecar_settled = false;
    slot.at_ms = @max(slot.at_ms, at_ms);
    slot.value = .{};
}

/// Another process proved the grant good at `ok_at`, after this process's
/// refusal: that refusal is obsolete, and the sidecar already says so.
fn supersede(account: []const u8, grant: []const u8, ok_at: i64) void {
    acquire();
    defer lock.unlock();
    for (&slots) |*slot| if (slot.account.len != 0 and std.ascii.eqlIgnoreCase(slot.account.slice(), account) and slot.observed == .failed and std.mem.eql(u8, slot.grant.slice(), grant) and slot.at_ms <= ok_at) {
        slot.observed = .ok;
        slot.at_ms = ok_at;
        slot.value = .{};
        slot.sidecar_settled = true;
    };
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

/// Whether a verified success in this process still has to bring the
/// sidecar in line. At most one sidecar update per observation and process.
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

/// One sidecar row: an account's grant, its latest refusal (when newer than
/// its latest known-good time) and that known-good time.
const Entry = struct {
    account: b.Text(limits.max_address) = .{},
    grant: b.Text(64) = .{},
    refused_at: i64 = 0,
    value: oauth.TokenError = .{},
    ok_at: i64 = 0,
    fn refused(self: *const Entry) bool {
        return self.refused_at > 0 and self.value.present() and self.refused_at > self.ok_at;
    }
};

/// lastRefreshError for auth.status about the account's current terminal
/// grant (null without one). This process's observation and the sidecar
/// are merged by time: the newest refusal is reported only if it is newer
/// than every known-good time of that grant. A refusal this process holds
/// that another process has since outdated is dropped from memory too.
pub fn status(io: std.Io, a: std.mem.Allocator, sidecar: ?[]const u8, account: []const u8, grant: ?[]const u8) !?Report {
    const current = grant orelse return null;
    if (!validGrant(current)) return null;
    const seen = observed(account);
    const mine = std.mem.eql(u8, seen.grant.slice(), current);
    var fail_at: i64 = 0;
    var fail_value: oauth.TokenError = .{};
    var ok_at: i64 = 0;
    var side_ok: i64 = 0;
    if (mine) switch (seen.observed) {
        .failed => {
            fail_at = seen.at_ms;
            fail_value = seen.value;
        },
        .ok => ok_at = seen.at_ms,
        .unknown => {},
    };
    if (sidecar) |path| if (find(load(io, a, path) catch &.{}, account)) |entry| if (std.mem.eql(u8, entry.grant.slice(), current)) {
        side_ok = entry.ok_at;
        ok_at = @max(ok_at, entry.ok_at);
        if (entry.refused() and entry.refused_at > fail_at) {
            fail_at = entry.refused_at;
            fail_value = entry.value;
        }
    };
    if (mine and seen.observed == .failed and side_ok >= seen.at_ms) supersede(account, current, side_ok);
    if (fail_at == 0 or fail_at <= ok_at) return null;
    return try report(a, &fail_value, fail_at);
}

fn find(entries: []const Entry, account: []const u8) ?Entry {
    for (entries) |entry| if (std.ascii.eqlIgnoreCase(entry.account.slice(), account)) return entry;
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
fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]Entry {
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
    var result: std.ArrayList(Entry) = .empty;
    for (list.array.items) |item| {
        if (result.items.len == limits.max_accounts) break;
        const account = j.text(item, "account");
        b.address(account) catch continue;
        const grant = j.text(item, "grantId");
        if (!validGrant(grant)) continue;
        if (find(result.items, account) != null) continue;
        var entry: Entry = .{ .ok_at = @max(0, j.integer(item, "okAt", 0) catch 0), .value = oauth.TokenError.fromJson(0, item) };
        if (entry.value.present()) entry.refused_at = @max(0, j.integer(item, "at", 0) catch 0);
        if (entry.refused_at == 0) entry.value = .{};
        if (entry.refused_at == 0 and entry.ok_at == 0) continue;
        try entry.account.set(account);
        try entry.grant.set(grant);
        try result.append(a, entry);
    }
    return result.items;
}

/// Atomic owner-only replacement in the registry's directory. A symlink at
/// the sidecar's name is replaced, never followed or written through.
fn save(io: std.Io, a: std.mem.Allocator, path: []const u8, entries: []const Entry) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    if (entries.len == 0) {
        dir.deleteFile(io, basename) catch |err| if (err != error.FileNotFound) return err;
        return;
    }
    const Row = struct { account: []const u8, grantId: []const u8, @"error": ?[]const u8 = null, error_subtype: ?[]const u8 = null, error_description: ?[]const u8 = null, at: ?i64 = null, okAt: ?i64 = null };
    var rows: [limits.max_accounts]Row = undefined;
    for (entries, 0..) |*entry, index| {
        rows[index] = .{ .account = entry.account.slice(), .grantId = entry.grant.slice(), .okAt = if (entry.ok_at > 0) entry.ok_at else null };
        if (entry.refused()) {
            rows[index].@"error" = entry.value.code.slice();
            rows[index].error_subtype = entry.value.subtype.slice();
            rows[index].error_description = entry.value.description.slice();
            rows[index].at = entry.refused_at;
        }
    }
    const bytes = try j.encodeAlloc(a, .{ .version = @as(u8, 2), .accounts = rows[0..entries.len] }, .{ .emit_null_optional_fields = false });
    if (bytes.len > max_sidecar_bytes) return error.DiagnosticsTooLarge;
    var atomic = try dir.createFileAtomic(io, basename, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Every read-modify-write of the sidecar holds this exclusive lock, so two
/// processes cannot interleave and resurrect an outdated refusal. Bounded:
/// a busy lock gives up (the diagnostic is best-effort) instead of waiting.
fn lockSidecar(io: std.Io, path: []const u8) !std.Io.File {
    const parent = std.fs.path.dirname(path) orelse ".";
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    const file = try @import("../native_file.zig").openAt(io, dir, lock_name, .{ .read_write = true, .create = true, .mode = 0o600 });
    errdefer file.close(io);
    for (0..40) |_| {
        if (try file.tryLock(io, .exclusive)) return file;
        try io.sleep(.fromMilliseconds(25), .awake);
    }
    return error.DiagnosticsBusy;
}
fn unlockSidecar(io: std.Io, file: std.Io.File) void {
    file.unlock(io);
    file.close(io);
}

/// Copy this process's observed refusal into the sidecar, unless the sidecar
/// already knows the grant was good at or after the refused credential was
/// read. One attempt per observation; best-effort for callers: the
/// diagnostic never decides whether an operation succeeds.
pub fn persist(io: std.Io, a: std.mem.Allocator, path: []const u8, account: []const u8) !void {
    const seen = observed(account);
    if (seen.observed != .failed) return;
    defer settle(account, .failed);
    const held = try lockSidecar(io, path);
    defer unlockSidecar(io, held);
    const existing = load(io, a, path) catch &.{};
    var row: Entry = .{ .grant = seen.grant, .refused_at = seen.at_ms, .value = seen.value };
    try row.account.set(account);
    var next: std.ArrayList(Entry) = .empty;
    for (existing) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.account.slice(), account)) {
            if (next.items.len + 1 < limits.max_accounts) try next.append(a, entry);
            continue;
        }
        if (!std.mem.eql(u8, entry.grant.slice(), seen.grant.slice())) continue;
        if (entry.ok_at >= seen.at_ms) {
            supersede(account, seen.grant.slice(), entry.ok_at);
            return;
        }
        row.ok_at = entry.ok_at;
        if (entry.refused() and entry.refused_at > row.refused_at) {
            row.refused_at = entry.refused_at;
            row.value = entry.value;
        }
    }
    try next.append(a, row);
    try save(io, a, path, next.items);
}

/// After a verified refresh or an authorization of the grant: record its
/// known-good time so no process reports an older refusal. `always` (an
/// authorization) writes it even without a persisted refusal, which outdates
/// refusals other open processes still hold in memory. An unreadable or
/// version-1 sidecar is replaced (or removed). One attempt per observation.
pub fn markOk(io: std.Io, a: std.mem.Allocator, path: []const u8, account: []const u8, always: bool) !void {
    const seen = observed(account);
    if (seen.observed != .ok) return;
    defer settle(account, .ok);
    const held = try lockSidecar(io, path);
    defer unlockSidecar(io, held);
    var unreadable = false;
    const existing = load(io, a, path) catch blk: {
        unreadable = true;
        break :blk &.{};
    };
    var next: std.ArrayList(Entry) = .empty;
    var found: ?Entry = null;
    for (existing) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.account.slice(), account)) found = entry else try next.append(a, entry);
    }
    const outdated = if (found) |entry| entry.refused() or !std.mem.eql(u8, entry.grant.slice(), seen.grant.slice()) else false;
    if (!always and !outdated) {
        if (unreadable) try save(io, a, path, next.items);
        return;
    }
    var row: Entry = .{ .grant = seen.grant, .ok_at = seen.at_ms };
    try row.account.set(account);
    if (found) |entry| if (std.mem.eql(u8, entry.grant.slice(), seen.grant.slice())) {
        row.ok_at = @max(row.ok_at, entry.ok_at);
        // A refusal another process saw after this success stays current.
        if (entry.refused() and entry.refused_at > row.ok_at) {
            row.refused_at = entry.refused_at;
            row.value = entry.value;
        }
    };
    try next.append(a, row);
    try save(io, a, path, next.items);
}

/// The terminal grant was revoked: no row for the account remains, and an
/// unreadable or version-1 sidecar is replaced (or removed).
pub fn removePersisted(io: std.Io, a: std.mem.Allocator, path: []const u8, account: []const u8) !void {
    const held = try lockSidecar(io, path);
    defer unlockSidecar(io, held);
    var unreadable = false;
    const existing = load(io, a, path) catch blk: {
        unreadable = true;
        break :blk &.{};
    };
    var next: std.ArrayList(Entry) = .empty;
    var changed = unreadable;
    for (existing) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.account.slice(), account)) changed = true else try next.append(a, entry);
    }
    if (changed) try save(io, a, path, next.items);
}

fn googleRefusal(a: std.mem.Allocator, body: []const u8) !oauth.TokenError {
    return oauth.TokenError.fromJson(400, try std.json.parseFromSliceLeaky(j.Value, a, body, .{}));
}
fn described(a: std.mem.Allocator, description: []const u8) ![]const u8 {
    const quoted = try std.json.Stringify.valueAlloc(a, description, .{});
    const body = try std.fmt.allocPrint(a, "{{\"error\":\"invalid_grant\",\"error_description\":{s}}}", .{quoted});
    return (try googleRefusal(a, body)).description.slice();
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
    const hostile = try googleRefusal(a, "{\"error\":\"invalid_grant\",\"error_subtype\":\"Bad Value\\u001b[2J\",\"error_description\":\"Bad\\u001b]52;c;x\\u0007 token 1/" ++ "/0gSyntheticRefreshTokenMaterial-abc_DEF and code 4/0AeanS0aSyntheticAuthorizationCode\\n\\tend\"}");
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
    const leak = try described(a, "leak 1//0gAAAAAAAAAAAAAA\u{1}BBBBBBBBBBBBBBBBBBB\u{e9}CCCCCCCCCCCCCCCCCCC\u{200b}DDDDDDDDDDDDDDDDDDD\u{7f}EEEEEEEEEEEEEEEEEEE end");
    try std.testing.expectEqualStrings("leak [redacted] end", leak);
    try std.testing.expect(longestTokenRun(leak) < 20);
    for (leak) |byte| try std.testing.expect(byte >= 32 and byte < 127);
    // No known prefix: a long all-caps run joined by a no-break space.
    try std.testing.expectEqualStrings("nbsp [redacted] end", try described(a, "nbsp AAAAAAAAAAAAAAAAAAA\u{a0}BBBBBBBBBBBBBBBBBBB end"));
    try std.testing.expectEqualStrings("escape ]52;c;[redacted] end", try described(a, "escape \u{1b}]52;c;QUFBQUFBQUFBQUFBQUFBQQ==\u{7} end"));
    // Ordinary words around dropped bytes stay readable, and ASCII
    // whitespace still separates short words.
    try std.testing.expectEqualStrings("Zugriff f r Konto abgelehnt (invalid_rapt)", try described(a, "Zugriff f\u{fc}r\u{1} Konto\n\tabgelehnt \u{200b}(invalid_rapt)"));
}

test "reconnect diagnostics: credentials are redacted by shape, while help URLs, hyphenated words and compounds stay readable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Kept: what Google and administrators actually write.
    for ([_][]const u8{
        "See https://support.google.com/a/answer/9368756 for details",
        "account-recovery-verification-required by your administrator",
        "Das Authentifizierungstoken ist abgelaufen",
        "ACCESS_TOKEN_SCOPE_INSUFFICIENT for this request",
        "oauth2-client-configuration-mismatch detected",
    }) |kept| try std.testing.expectEqualStrings(kept, try described(a, kept));
    try std.testing.expectEqualStrings("Zugriff verweigert: Zur cksetzungsverfahren erforderlich", try described(a, "Zugriff verweigert: Zur\u{fc}cksetzungsverfahren erforderlich"));
    // Redacted: refresh/access tokens, codes, JWTs, base64, hex identifiers,
    // after '=' in a URL query too, even when shorter than 20 characters.
    for ([_][2][]const u8{
        .{ "rt 1//0abcdefghijklmno end", "rt [redacted] end" },
        .{ "at ya29.a0AfB_byC end", "at [redacted] end" },
        .{ "code 4/0AeanS0aSynth end", "code [redacted] end" },
        .{ "dot jwt eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl end", "dot jwt [redacted] end" },
        .{ "b64 QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo+/= end", "b64 [redacted] end" },
        .{ "grant 39e5a31e6b2dff8d873274a9f0d0ec65acc686f0946ba64f3e79f11bba64383c end", "grant [redacted] end" },
        .{ "see /callback?refresh_token=1//0gSecretValue end", "see /callback?[redacted] end" },
        .{ "split by spaces 1//0gAAAAAAAAAAAAAA AAAAAAAAAAAAAAAAAAAA BBBBBBBBBBBBBBBBBBB end", "split by spaces [redacted] [redacted] BBBBBBBBBBBBBBBBBBB end" },
    }) |case| try std.testing.expectEqualStrings(case[1], try described(a, case[0]));
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
    // caller to bring the sidecar in line, once.
    try std.testing.expect(!needsPersistedClear("self@example.test"));
    recordSuccess("self@example.test", grant_one, 2000);
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    try std.testing.expect(needsPersistedClear("self@example.test"));
    try markOk(io, a, sidecar, "self@example.test", false);
    try std.testing.expect(!needsPersistedClear("self@example.test"));
    recordSuccess("self@example.test", grant_one, 2100);
    try std.testing.expect(!needsPersistedClear("self@example.test"));
    reset();
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    // A missing body diagnostic still records the refusal itself; forget clears it.
    recordFailure("other@example.test", grant_two, .{}, 1);
    try std.testing.expectEqualStrings("invalid_grant", (try status(io, a, null, "other@example.test", grant_two)).?.@"error");
    forget("other@example.test");
    try std.testing.expect(try status(io, a, null, "other@example.test", grant_two) == null);
    // Revoking removes the account's row; the sidecar disappears with it.
    try removePersisted(io, a, sidecar, "self@example.test");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, sidecar, .{}));
}

test "reconnect diagnostics: a refusal older than the grant's latest known-good time is dropped, in memory and across processes" {
    reset();
    defer reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const sidecar = try sidecarPath(a, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/terminal-grants.json", .{temporary.sub_path}));
    // An open TUI saw the refusal of a credential read at 100 and persisted it.
    recordFailure("self@example.test", grant_one, .{}, 100);
    try persist(io, a, sidecar, "self@example.test");
    // Another process reconnects the same grant (same identity) at 200.
    const tui = observed("self@example.test");
    reset();
    recordSuccess("self@example.test", grant_one, 200);
    try markOk(io, a, sidecar, "self@example.test", true);
    // Back in the TUI: its memory still holds the refusal; the dialog's
    // status read reports nothing and drops the outdated refusal.
    reset();
    recordFailure("self@example.test", grant_one, tui.value, tui.at_ms);
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    try std.testing.expectEqual(Observed.ok, observed("self@example.test").observed);
    // A request that still used the old credential (read at 150) and is
    // refused afterwards can never re-persist the outdated refusal.
    recordFailure("self@example.test", grant_one, .{}, 150);
    try persist(io, a, sidecar, "self@example.test");
    reset();
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
    // A refusal of the renewed credential (read at 300) is current again.
    recordFailure("self@example.test", grant_one, .{}, 300);
    try persist(io, a, sidecar, "self@example.test");
    reset();
    try std.testing.expectEqual(@as(i64, 300), (try status(io, a, sidecar, "self@example.test", grant_one)).?.at);
    // An authorization writes its known-good time even without a persisted
    // refusal of its own, so an earlier-refused process learns of it.
    recordSuccess("self@example.test", grant_one, 400);
    try markOk(io, a, sidecar, "self@example.test", true);
    reset();
    try std.testing.expect(try status(io, a, sidecar, "self@example.test", grant_one) == null);
}

test "reconnect diagnostics: a version-1 or unreadable sidecar is replaced on the next success, and a busy or unwritable sidecar is tried once" {
    reset();
    defer reset();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, sidecar_name });
    const old = try temporary.dir.createFile(io, sidecar_name, .{ .permissions = .fromMode(0o600) });
    try old.writeStreamingAll(io, "{\"version\":1,\"accounts\":[{\"account\":\"self@example.test\",\"error\":\"invalid_grant\",\"at\":1}]}");
    old.close(io);
    recordSuccess("self@example.test", grant_one, 10);
    try markOk(io, a, path, "self@example.test", false);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
    // A held lock: persistence gives up after a bounded wait, once.
    const dir = try std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temporary.sub_path}), .{});
    defer dir.close(io);
    const held = try @import("../native_file.zig").openAt(io, dir, lock_name, .{ .read_write = true, .create = true, .mode = 0o600 });
    defer held.close(io);
    try held.lock(io, .exclusive);
    recordFailure("self@example.test", grant_one, .{}, 20);
    try std.testing.expectError(error.DiagnosticsBusy, persist(io, a, path, "self@example.test"));
    try std.testing.expect(observed("self@example.test").sidecar_settled);
    held.unlock(io);
    // An unwritable directory: one attempt per observation, then settled.
    recordSuccess("self@example.test", grant_one, 30);
    const missing = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/absent/{s}", .{ temporary.sub_path, sidecar_name });
    try std.testing.expect(needsPersistedClear("self@example.test"));
    try std.testing.expectError(error.FileNotFound, markOk(io, a, missing, "self@example.test", true));
    try std.testing.expect(!needsPersistedClear("self@example.test"));
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
