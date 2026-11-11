const std = @import("std");
const b = @import("bounded.zig");
const limits = @import("limits.zig");
const http = @import("http_client.zig");
const keyring = @import("keyring.zig");
const platform = @import("platform.zig");
pub const readonly_scope = "https://www.googleapis.com/auth/gmail.readonly";
pub const DesktopClient = struct {
    client_id: b.Text(4096) = .{},
    client_secret: b.Text(4096) = .{},
    pub fn wipe(self: *DesktopClient) void {
        self.client_id.wipe();
        self.client_secret.wipe();
    }
};
pub const TokenResult = struct { access_token: []const u8, expires_in: u32 };
/// Google's token-endpoint refusal reduced to a bounded diagnostic. Only the
/// machine vocabulary of `error`/`error_subtype` and a sanitized
/// `error_description` survive; the response body itself is never retained,
/// and anything shaped like a credential, code or identifier is redacted.
pub const TokenError = struct {
    status: u16 = 0,
    code: b.Text(48) = .{},
    subtype: b.Text(48) = .{},
    description: b.Text(160) = .{},
    pub fn present(self: *const TokenError) bool {
        return self.code.len != 0;
    }
    /// Stable classification for people and agents. Google uses the same
    /// "expired or revoked" text for revoked access, a password change and a
    /// Testing-mode project's seven-day grant limit; it cannot be narrowed.
    /// Only invalid_grant refusals are kept, so there is no fourth kind.
    pub fn kind(self: *const TokenError) []const u8 {
        if (std.mem.eql(u8, self.subtype.slice(), "invalid_rapt")) return "reauthenticationRequired";
        if (std.ascii.findIgnoreCase(self.description.slice(), "expired or revoked") != null) return "expiredOrRevoked";
        return "invalidGrant";
    }
    pub fn fromJson(status: u16, value: std.json.Value) TokenError {
        var result: TokenError = .{ .status = status };
        if (b.optional(value, "error")) |v| if (v == .string) machineWord(&result.code, v.string);
        if (b.optional(value, "error_subtype")) |v| if (v == .string) machineWord(&result.subtype, v.string);
        if (b.optional(value, "error_description")) |v| if (v == .string) prose(&result.description, v.string);
        return result;
    }
};
fn machineWord(out: *b.Text(48), raw: []const u8) void {
    if (raw.len == 0 or raw.len > 48) return;
    for (raw) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return;
    out.set(raw) catch {};
}
fn tokenAlphabet(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~+/=", c) != null;
}
/// Printable ASCII prose with single spaces. ASCII whitespace separates
/// words. Every other dropped byte (controls, DEL, any non-ASCII byte) is
/// shown as a space but cannot split a credential: token-alphabet pieces it
/// joins count as one run. A run is replaced as a whole when it looks like a
/// credential (see `credentialRun`); ordinary words, help URLs, hyphenated
/// words and long compounds stay readable.
fn prose(out: *b.Text(160), raw: []const u8) void {
    // 0 marks one or more dropped bytes between visible ones.
    var normalized: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &normalized);
    var length: usize = 0;
    var truncated = false;
    for (raw) |c| {
        const class: u8 = if (c > 32 and c < 127) c else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') ' ' else 0;
        if (class == ' ' or class == 0) {
            if (length == 0 or normalized[length - 1] == ' ') continue;
            if (normalized[length - 1] == 0) {
                if (class == ' ') normalized[length - 1] = ' ';
                continue;
            }
        }
        if (length == normalized.len) {
            truncated = true;
            break;
        }
        normalized[length] = class;
        length += 1;
    }
    const text = normalized[0..length];
    var buffer: [160]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var n: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        var end = index + 1;
        if (tokenAlphabet(text[index])) {
            while (end < text.len) {
                if (tokenAlphabet(text[end])) {
                    end += 1;
                } else if (text[end] == 0 and end + 1 < text.len and tokenAlphabet(text[end + 1])) {
                    end += 1;
                } else break;
            }
        }
        const word = if (tokenAlphabet(text[index]) and credentialRun(text[index..end])) "[redacted]" else text[index..end];
        if (n + word.len > buffer.len - 3) {
            truncated = true;
            break;
        }
        for (word, 0..) |c, offset| buffer[n + offset] = if (c == 0) ' ' else c;
        n += word.len;
        index = end;
    }
    while (n > 0 and buffer[n - 1] == ' ') n -= 1;
    if (truncated) {
        @memcpy(buffer[n..][0..3], "...");
        n += 3;
    }
    out.set(buffer[0..n]) catch {};
}
/// Prefixes of Google refresh tokens, access tokens, authorization codes,
/// JWTs, client secrets and API keys.
const credential_prefixes = [_][]const u8{ "1//", "ya29.", "4/0", "eyJ", "GOCSPX-", "AIza" };
/// A token-alphabet run (dropped bytes marked 0) that must not be shown:
/// one starting (or continuing after '=') with a known credential prefix, or
/// a 20+ character run with a piece no sentence contains — digits mixed into
/// a long piece, mixed case with more than two capitals, a long all-caps
/// piece or more than 12 digits. Pieces are split
/// at URL and word punctuation, so `support.google.com/a/answer/9368756`,
/// `account-recovery-verification-required` and German compounds stay.
fn credentialRun(run: []const u8) bool {
    var letters: usize = 0;
    for (run) |c| {
        if (c != 0) letters += 1;
    }
    for (run, 0..) |_, at| {
        if (at != 0 and run[at - 1] != '=') continue;
        for (credential_prefixes) |prefix| if (letters >= 8 and std.mem.startsWith(u8, run[at..], prefix)) return true;
    }
    if (letters < 20) return false;
    var pieces = std.mem.tokenizeAny(u8, run, "./-_~+=\x00");
    while (pieces.next()) |piece| if (!wordPiece(piece)) return true;
    return false;
}
fn wordPiece(piece: []const u8) bool {
    var upper: usize = 0;
    var lower: usize = 0;
    var digits: usize = 0;
    for (piece) |c| {
        if (std.ascii.isUpper(c)) upper += 1 else if (std.ascii.isLower(c)) lower += 1 else if (std.ascii.isDigit(c)) digits += 1;
    }
    // A number, or a short versioned word (oauth2, v1).
    if (digits > 0) return (upper == 0 and lower == 0 and digits <= 12) or piece.len <= 6;
    // A word, a Capitalized or camelCase word, or a short all-caps word.
    return upper <= 2 or (lower == 0 and upper <= 12);
}
/// One network worker owns token exchanges; the lock only guards a reader on
/// another thread. The value is a sanitized diagnostic, never token material.
var token_error_lock: std.atomic.Mutex = .unlocked;
var token_error: TokenError = .{};
fn publishTokenError(value: TokenError) void {
    while (!token_error_lock.tryLock()) std.atomic.spinLoopHint();
    defer token_error_lock.unlock();
    token_error = value;
}
/// The most recent token-endpoint refusal in this process, cleared on read.
pub fn takeTokenError() TokenError {
    while (!token_error_lock.tryLock()) std.atomic.spinLoopHint();
    defer token_error_lock.unlock();
    const value = token_error;
    token_error = .{};
    return value;
}
var json_workspace: [64 * 1024]u8 align(16) = undefined;
var token_body: [limits.token_response]u8 = undefined;
var form_buffer: [32 * 1024]u8 = undefined;
var desktop_body: [16 * 1024]u8 = undefined;

pub fn loadDesktop(io: std.Io, path: []const u8, desktop: *DesktopClient) !void {
    defer std.crypto.secureZero(u8, &desktop_body);
    const data = try std.Io.Dir.cwd().readFile(io, path, &desktop_body);
    if (data.len == desktop_body.len) return error.DesktopClientTooLarge;
    try parseDesktop(data, desktop);
}
pub fn loadDesktopWithSettings(io: std.Io, path: []const u8, desktop: *DesktopClient, settings: keyring.Settings) !void {
    if (settings.kind != .vault) return loadDesktop(io, path, desktop);
    desktop.wipe();
    const provider = settings.provider orelse return error.VaultLocked;
    const bytes = (try provider.read(.desktop_client, .{ .name = path })) orelse return error.OAuthClientRequired;
    return parseDesktop(bytes, desktop);
}
pub fn parseDesktop(data: []const u8, desktop: *DesktopClient) !void {
    if (data.len > desktop_body.len) return error.DesktopClientTooLarge;
    desktop.wipe();
    errdefer desktop.wipe();
    var fixed = std.heap.FixedBufferAllocator.init(&json_workspace);
    defer std.crypto.secureZero(u8, json_workspace[0..fixed.end_index]);
    const parsed = try b.parse(fixed.allocator(), data);
    defer parsed.deinit();
    const installed = try b.field(parsed.value, "installed");
    const id = try b.string(try b.field(installed, "client_id"));
    if (!std.mem.endsWith(u8, id, ".apps.googleusercontent.com")) return error.InvalidDesktopClient;
    try tokenValid(id);
    try desktop.client_id.set(id);
    const secret = try b.string(try b.field(installed, "client_secret"));
    try tokenValid(secret);
    try desktop.client_secret.set(secret);
    if (b.optional(installed, "auth_uri")) |v| if (!std.mem.eql(u8, try b.string(v), "https://accounts.google.com/o/oauth2/auth")) return error.InvalidDesktopClient;
    if (b.optional(installed, "token_uri")) |v| if (!std.mem.eql(u8, try b.string(v), "https://oauth2.googleapis.com/token")) return error.InvalidDesktopClient;
}
fn tokenValid(t: []const u8) !void {
    if (t.len == 0 or t.len > limits.secret) return error.InvalidToken;
    for (t) |c| if (c <= 32 or c >= 127) return error.InvalidToken;
}
pub fn pkceChallenge(verifier: []const u8, output: *[43]u8) void {
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(output, &digest);
}
pub fn percent(w: *std.Io.Writer, text: []const u8) !void {
    const digits = "0123456789ABCDEF";
    for (text) |c| if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try w.writeByte(c) else {
        const enc = [_]u8{ '%', digits[c >> 4], digits[c & 15] };
        try w.writeAll(&enc);
    };
}
fn formField(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    if (w.buffered().len != 0) try w.writeByte('&');
    try w.writeAll(name);
    try w.writeByte('=');
    try percent(w, value);
}
pub fn refresh(io: std.Io, client: *http.Client, desktop: *const DesktopClient, refresh_token: []const u8, out_access: []u8) !TokenResult {
    return try refreshScoped(io, client, desktop, refresh_token, out_access, &.{readonly_scope});
}
pub fn refreshScoped(io: std.Io, client: *http.Client, desktop: *const DesktopClient, refresh_token: []const u8, out_access: []u8, scopes: []const []const u8) !TokenResult {
    _ = io;
    try validateScopeSet(scopes);
    try tokenValid(refresh_token);
    var form = std.Io.Writer.fixed(&form_buffer);
    defer std.crypto.secureZero(u8, &form_buffer);
    defer std.crypto.secureZero(u8, &token_body);
    try formField(&form, "client_id", desktop.client_id.slice());
    try formField(&form, "client_secret", desktop.client_secret.slice());
    try formField(&form, "refresh_token", refresh_token);
    try formField(&form, "grant_type", "refresh_token");
    const response = try client.request("https://oauth2.googleapis.com/token", .POST, null, form.buffered(), &token_body);
    return try parseTokensScoped(response.status, response.body, out_access, null, scopes);
}
pub fn parseTokens(status: u16, data: []const u8, out_access: []u8, out_refresh: ?[]u8) !TokenResult {
    return try parseTokensScoped(status, data, out_access, out_refresh, &.{readonly_scope});
}
pub fn parseTokensScoped(status: u16, data: []const u8, out_access: []u8, out_refresh: ?[]u8, scopes: []const []const u8) !TokenResult {
    if (out_access.len > limits.secret) return error.InvalidSecretBuffer;
    errdefer std.crypto.secureZero(u8, out_access);
    if (out_refresh) |out| {
        std.crypto.secureZero(u8, out);
    }
    errdefer if (out_refresh) |out| {
        std.crypto.secureZero(u8, out);
    };
    try validateScopeSet(scopes);
    if (data.len > limits.token_response) return error.TokenResponseTooLarge;
    var fixed = std.heap.FixedBufferAllocator.init(&json_workspace);
    defer std.crypto.secureZero(u8, json_workspace[0..fixed.end_index]);
    const parsed = try b.parse(fixed.allocator(), data);
    defer parsed.deinit();
    if (status != 200) {
        publishTokenError(.fromJson(status, parsed.value));
        if (b.optional(parsed.value, "error")) |v| if (v == .string and std.mem.eql(u8, v.string, "invalid_grant")) return error.InvalidGrant;
        return error.TokenExchangeFailed;
    }
    publishTokenError(.{});
    if (!std.ascii.eqlIgnoreCase(try b.string(try b.field(parsed.value, "token_type")), "Bearer")) return error.InvalidTokenType;
    const access = try b.string(try b.field(parsed.value, "access_token"));
    try tokenValid(access);
    if (access.len > out_access.len) return error.TokenTooLarge;
    const expires = try b.integer(try b.field(parsed.value, "expires_in"));
    if (expires <= 0 or expires > 86400) return error.InvalidTokenExpiry;
    if (b.optional(parsed.value, "scope")) |scope| {
        var parts = std.mem.tokenizeScalar(u8, try b.string(scope), ' ');
        var seen: [8]bool = @splat(false);
        var count: usize = 0;
        while (parts.next()) |part| {
            var found = false;
            for (scopes, 0..) |expected, index| if (std.mem.eql(u8, part, expected)) {
                if (seen[index]) return error.UnexpectedScope;
                seen[index] = true;
                found = true;
                break;
            };
            if (!found) return error.UnexpectedScope;
            count += 1;
        }
        if (count != scopes.len) return error.UnexpectedScope;
    }
    if (out_refresh) |out| {
        const refresh_token = try b.string(b.optional(parsed.value, "refresh_token") orelse return error.MissingRefreshToken);
        try tokenValid(refresh_token);
        if (refresh_token.len > out.len) return error.TokenTooLarge;
        @memcpy(out[0..refresh_token.len], refresh_token);
        if (out.len > refresh_token.len) @memset(out[refresh_token.len..], 0);
    }
    std.crypto.secureZero(u8, out_access);
    @memcpy(out_access[0..access.len], access);
    return .{ .access_token = out_access[0..access.len], .expires_in = @intCast(expires) };
}
pub fn validateScopeSet(scopes: []const []const u8) !void {
    if (scopes.len == 0 or scopes.len > 9) return error.UnexpectedScope;
    const allowed = [_][]const u8{
        readonly_scope,
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.events.owned",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.events.freebusy",
        "https://www.googleapis.com/auth/meetings.space.settings",
    };
    for (scopes, 0..) |scope, index| {
        var valid = false;
        for (allowed) |option| valid = valid or std.mem.eql(u8, option, scope);
        if (!valid) return error.UnexpectedScope;
        for (scopes[0..index]) |previous| if (std.mem.eql(u8, previous, scope)) return error.UnexpectedScope;
    }
}
pub fn verifyIdentity(data: []const u8, expected: []const u8) !void {
    try b.address(expected);
    if (data.len > limits.token_response) return error.ProfileResponseTooLarge;
    var fixed = std.heap.FixedBufferAllocator.init(&json_workspace);
    defer std.crypto.secureZero(u8, json_workspace[0..fixed.end_index]);
    const parsed = try b.parse(fixed.allocator(), data);
    defer parsed.deinit();
    const address = try b.string(try b.field(parsed.value, "emailAddress"));
    try b.address(address);
    if (!std.ascii.eqlIgnoreCase(expected, address)) return error.WrongAccount;
}

pub fn verifyProfile(status: u16, data: []const u8, expected: []const u8) !void {
    switch (status) {
        200 => try verifyIdentity(data, expected),
        401 => return error.ProfileUnauthenticated,
        403 => return error.ProfileAccessDenied,
        429 => return error.ProfileRateLimited,
        500...599 => return error.ProfileTransientFailure,
        else => return error.ProfileVerificationFailed,
    }
}

pub const Callback = struct {
    expected_state: []const u8,
    completed: bool = false,
    pub fn parse(self: *Callback, head: []const u8, code: []u8) ![]const u8 {
        if (self.completed) return error.DuplicateCallback;
        if (head.len > 8192) return error.CallbackHeadersTooLarge;
        if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return error.InvalidCallback;
        const first_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.InvalidCallback;
        var parts = std.mem.splitScalar(u8, head[0..first_end], ' ');
        if (!std.mem.eql(u8, parts.next() orelse "", "GET")) return error.InvalidCallbackMethod;
        const target = parts.next() orelse return error.InvalidCallback;
        const version = parts.next() orelse return error.InvalidCallback;
        if (parts.next() != null or (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0"))) return error.InvalidCallback;
        if (target.len > 4096) return error.CallbackTargetTooLarge;
        if (std.mem.indexOfScalar(u8, target, '#') != null) return error.InvalidCallback;
        const query_at = std.mem.indexOfScalar(u8, target, '?') orelse return error.InvalidCallback;
        if (!std.mem.eql(u8, target[0..query_at], "/oauth2/callback")) return error.InvalidCallbackPath;
        var headers = std.mem.splitSequence(u8, head[first_end + 2 ..], "\r\n");
        while (headers.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidCallback;
            if (colon == 0) return error.InvalidCallback;
            for (line[0..colon]) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidCallback;
            for (line[colon + 1 ..]) |c| if ((c < 32 and c != '\t') or c == 127) return error.InvalidCallback;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) return error.InvalidCallback;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length") and !std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), "0")) return error.InvalidCallback;
        }
        var seen_keys: [16][128]u8 = undefined;
        var seen_len: [16]usize = undefined;
        var count: usize = 0;
        var pairs = std.mem.splitScalar(u8, target[query_at + 1 ..], '&');
        var state: [128]u8 = @splat(0);
        var state_len: ?usize = null;
        var code_len: ?usize = null;
        var callback_error: [128]u8 = undefined;
        var error_len: ?usize = null;
        while (pairs.next()) |pair| {
            if (count == 16 or pair.len == 0) return error.InvalidCallback;
            const eql = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidCallback;
            const key_len = try decode(pair[0..eql], &seen_keys[count]);
            const key = seen_keys[count][0..key_len];
            for (0..count) |i| if (std.mem.eql(u8, key, seen_keys[i][0..seen_len[i]])) return error.AmbiguousCallback;
            seen_len[count] = key_len;
            count += 1;
            const value = pair[eql + 1 ..];
            if (std.mem.eql(u8, key, "state")) state_len = try decode(value, &state) else if (std.mem.eql(u8, key, "code")) code_len = try decode(value, code) else if (std.mem.eql(u8, key, "error")) error_len = try decode(value, &callback_error) else {
                var ignored: [4096]u8 = undefined;
                _ = try decode(value, &ignored);
            }
        }
        const slen = state_len orelse return error.MissingState;
        if (slen != self.expected_state.len or self.expected_state.len > 128) return error.StateMismatch;
        var expected: [128]u8 = @splat(0);
        @memcpy(expected[0..self.expected_state.len], self.expected_state);
        if (!std.crypto.timing_safe.eql([128]u8, state, expected)) return error.StateMismatch;
        if (error_len != null) {
            if (code_len != null) return error.AmbiguousCallback;
            self.completed = true;
            if (std.mem.eql(u8, callback_error[0..error_len.?], "access_denied")) return error.AuthorizationDenied;
            return error.AuthorizationFailed;
        }
        const n = code_len orelse return error.MissingCode;
        if (n == 0) return error.MissingCode;
        self.completed = true;
        return code[0..n];
    }
};
fn decode(raw: []const u8, out: []u8) !usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (n == out.len) return error.CallbackValueTooLarge;
        const c = if (raw[i] == '%') blk: {
            if (i + 2 >= raw.len) return error.InvalidEscape;
            const decoded = std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16) catch return error.InvalidEscape;
            i += 2;
            break :blk decoded;
        } else if (raw[i] == '+') ' ' else raw[i];
        if (c < 32 or c == 127) return error.InvalidCallback;
        out[n] = c;
        n += 1;
    }
    return n;
}

var auth_access: [limits.secret]u8 = undefined;
var auth_refresh: [limits.secret]u8 = undefined;
var auth_code: [4096]u8 = undefined;
var auth_url: [8192]u8 = undefined;
var auth_header: [8192]u8 = undefined;
var auth_desktop: DesktopClient = .{};

pub fn authorize(io: std.Io, client_file: []const u8, address: []const u8, profile: []const u8, chrome: []const u8, credentials: keyring.Settings) !void {
    try authorizeScoped(io, client_file, address, profile, chrome, &.{readonly_scope}, null, credentials);
}
pub const TerminalCredential = struct { grant_id: []const u8, capture: ?*b.Text(limits.secret) = null, commit: ?*Commit = null };
pub const Notify = struct {
    context: *anyopaque,
    callFn: *const fn (*anyopaque) void,
};
/// A gate shared with a canceller in this process (the TUI): exactly one of
/// "cancel before Google's callback" and "commit after it" wins, so a
/// canceller never waits on a commit and a commit never starts once a
/// cancellation was promised.
pub const gate_open: u8 = 0;
pub const gate_canceled: u8 = 1;
pub const gate_committing: u8 = 2;
/// Everything after Google's callback — the token exchange, the identity
/// check and every durable write — shares this one bound.
pub const commit_seconds = 25;
/// Unit tests only: a shorter commit bound.
pub const TestBound = if (@import("builtin").is_test) struct {
    pub var ms: ?i64 = null;
} else struct {};
/// Once Google's callback has arrived, the exchange, identity check and the
/// durable store must finish: cancelling then would discard a credential
/// Google already issued, or report "unchanged" after it was stored. The
/// commit blocks cancellation of the current task and marks the process as
/// committing until the caller ends it after its own durable writes. Each
/// step runs in its own task under the shared commit_seconds bound, which
/// alone can interrupt it (including a blocked file or keyring write).
///
/// A failure is classified by how far the commit got: before the first
/// durable write nothing was stored (TokenExchangeFailed, or the specific
/// WrongAccount/UnexpectedScope); from the first durable write on, the
/// outcome is unknown (SignInStoreUnconfirmed) and the caller must check.
pub const Commit = struct {
    notify: ?Notify = null,
    gate: ?*std.atomic.Value(u8) = null,
    started: bool = false,
    storing: bool = false,
    deadline_ms: i64 = 0,
    previous: std.Io.CancelProtection = .unblocked,
    pub fn begin(self: *Commit, io: std.Io) error{Canceled}!void {
        if (self.started) return;
        self.previous = io.swapCancelProtection(.blocked);
        if (self.gate) |gate| if (gate.cmpxchgStrong(gate_open, gate_committing, .acq_rel, .acquire) != null) {
            _ = io.swapCancelProtection(self.previous);
            return error.Canceled;
        };
        self.started = true;
        const bound: i64 = if (comptime @import("builtin").is_test) (TestBound.ms orelse commit_seconds * std.time.ms_per_s) else commit_seconds * std.time.ms_per_s;
        self.deadline_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() + bound;
        committing_flag.store(true, .release);
        if (self.notify) |notify| notify.callFn(notify.context);
    }
    /// The first durable write starts now.
    pub fn store(self: *Commit) void {
        self.storing = true;
    }
    /// One bounded step of the commit; its failure is classified.
    pub fn step(self: *Commit, io: std.Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) anyerror!@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
        const left = self.deadline_ms - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (left <= 0) return self.classify(error.Timeout);
        return platform.deadline(io, .{ .clock = .awake, .raw = .fromMilliseconds(left) }, function, args) catch |err| return self.classify(err);
    }
    pub fn classify(self: *const Commit, err: anyerror) anyerror {
        if (err == error.OutOfMemory and !self.storing) return err;
        if (self.storing) {
            recordCause(err);
            return error.SignInStoreUnconfirmed;
        }
        return switch (err) {
            error.WrongAccount, error.UnexpectedScope => err,
            else => blk: {
                recordCause(err);
                break :blk error.TokenExchangeFailed;
            },
        };
    }
    pub fn end(self: *Commit, io: std.Io) void {
        if (!self.started) return;
        self.started = false;
        committing_flag.store(false, .release);
        _ = io.swapCancelProtection(self.previous);
    }
};
var committing_flag: std.atomic.Value(bool) = .init(false);
/// Whether this process is past a consent callback and storing its result.
pub fn committing() bool {
    return committing_flag.load(.acquire);
}
/// The underlying error name of the last classified commit failure (an
/// identifier, never provider text), for the error frame's `cause`.
var cause_lock: std.atomic.Mutex = .unlocked;
var cause_name: [64]u8 = undefined;
var cause_len: usize = 0;
fn recordCause(err: anyerror) void {
    while (!cause_lock.tryLock()) std.atomic.spinLoopHint();
    defer cause_lock.unlock();
    const name = @errorName(err);
    cause_len = @min(name.len, cause_name.len);
    @memcpy(cause_name[0..cause_len], name[0..cause_len]);
}
pub fn takeCommitCause(out: *[64]u8) []const u8 {
    while (!cause_lock.tryLock()) std.atomic.spinLoopHint();
    defer cause_lock.unlock();
    const len = cause_len;
    @memcpy(out[0..len], cause_name[0..len]);
    cause_len = 0;
    return out[0..len];
}
/// Unit-test-only consent page. Production always launches the configured
/// browser; no runtime option, environment variable or production
/// declaration can replace it or observe the consent URL.
pub const TestBrowser = if (@import("builtin").is_test) struct {
    pub var open: ?*const fn (std.Io, []const u8) anyerror!void = null;
} else struct {};
/// PKCE verifier and redirect for one consent. The verifier never leaves this
/// process: only its S256 challenge is placed in the consent URL.
const Flow = struct {
    verifier: [43]u8 = undefined,
    redirect_storage: [128]u8 = undefined,
    redirect: []const u8 = "",
    fn wipe(self: *Flow) void {
        std.crypto.secureZero(u8, &self.verifier);
    }
};
/// Shared consent: a loopback listener, PKCE, state, the browser launch in the
/// account's profile and one strictly verified callback. The returned code
/// lives in auth_code; the listener is closed on every return path.
fn consent(io: std.Io, flow: *Flow, client_id: []const u8, address: []const u8, profile: []const u8, chrome: []const u8, scopes: []const []const u8, wait: std.Io.Clock.Duration) ![]const u8 {
    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
    defer listener.deinit(io);
    flow.redirect = try std.fmt.bufPrint(&flow.redirect_storage, "http://127.0.0.1:{d}/oauth2/callback", .{listener.socket.address.getPort()});
    var random: [32]u8 = undefined;
    var state: [43]u8 = undefined;
    var challenge: [43]u8 = undefined;
    defer {
        std.crypto.secureZero(u8, &random);
        std.crypto.secureZero(u8, &state);
    }
    try io.randomSecure(&random);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&flow.verifier, &random);
    pkceChallenge(&flow.verifier, &challenge);
    try io.randomSecure(&random);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&state, &random);
    var url = std.Io.Writer.fixed(&auth_url);
    try url.writeAll("https://accounts.google.com/o/oauth2/v2/auth?");
    // formField counts the URL prefix, so write the first field explicitly.
    try url.writeAll("client_id=");
    try percent(&url, client_id);
    try formField(&url, "redirect_uri", flow.redirect);
    try formField(&url, "response_type", "code");
    var scope_bytes: [1024]u8 = undefined;
    var scope_writer = std.Io.Writer.fixed(&scope_bytes);
    for (scopes, 0..) |scope, index| {
        if (index != 0) try scope_writer.writeByte(' ');
        try scope_writer.writeAll(scope);
    }
    try formField(&url, "scope", scope_writer.buffered());
    try formField(&url, "code_challenge", &challenge);
    try formField(&url, "code_challenge_method", "S256");
    try formField(&url, "state", &state);
    try formField(&url, "access_type", "offline");
    try formField(&url, "prompt", "consent");
    try formField(&url, "login_hint", address);
    var profile_arg: [160]u8 = undefined;
    const arg = try std.fmt.bufPrint(&profile_arg, "--profile-directory={s}", .{profile});
    if (comptime @import("builtin").is_test) {
        if (TestBrowser.open) |open| try open(io, url.buffered()) else try platform.launchDetached(io, &.{ chrome, arg, url.buffered() });
    } else try platform.launchDetached(io, &.{ chrome, arg, url.buffered() });
    var callback: Callback = .{ .expected_state = &state };
    return try platform.deadline(io, wait, acceptCallback, .{ io, &listener, &callback });
}
pub fn authorizeScoped(io: std.Io, client_file: []const u8, address: []const u8, profile: []const u8, chrome: []const u8, scopes: []const []const u8, terminal: ?TerminalCredential, credentials: keyring.Settings) !void {
    try validateScopeSet(scopes);
    if (terminal == null and (scopes.len != 1 or !std.mem.eql(u8, scopes[0], readonly_scope))) return error.UnexpectedScope;
    try b.address(address);
    try b.profile(profile);
    defer {
        auth_desktop.wipe();
        std.crypto.secureZero(u8, &auth_access);
        std.crypto.secureZero(u8, &auth_refresh);
        std.crypto.secureZero(u8, &auth_code);
        std.crypto.secureZero(u8, &auth_url);
        std.crypto.secureZero(u8, &auth_header);
        std.crypto.secureZero(u8, &form_buffer);
        std.crypto.secureZero(u8, &token_body);
    }
    try loadDesktopWithSettings(io, client_file, &auth_desktop, credentials);
    var flow: Flow = .{};
    defer flow.wipe();
    const code = try consent(io, &flow, auth_desktop.client_id.slice(), address, profile, chrome, scopes, platform.seconds(limits.auth_seconds));
    // Google answered: finish the exchange and store, uncancellable but
    // bounded. A caller with its own durable writes owns the commit and ends
    // it afterwards.
    var local_commit: Commit = .{};
    const commit = if (terminal) |credential| credential.commit orelse &local_commit else &local_commit;
    defer local_commit.end(io);
    try commit.begin(io);
    try commit.step(io, exchangeStep, .{ io, code, &flow, scopes, address });
    commit.store();
    try commit.step(io, storeStep, .{ io, terminal, address, credentials });
}
/// Token exchange and Gmail identity proof; nothing is stored here.
fn exchangeStep(io: std.Io, code: []const u8, flow: *const Flow, scopes: []const []const u8, address: []const u8) anyerror!void {
    var client = try http.Client.init(io);
    defer client.deinit();
    var form = std.Io.Writer.fixed(&form_buffer);
    try formField(&form, "client_id", auth_desktop.client_id.slice());
    try formField(&form, "client_secret", auth_desktop.client_secret.slice());
    try formField(&form, "code", code);
    try formField(&form, "code_verifier", &flow.verifier);
    try formField(&form, "redirect_uri", flow.redirect);
    try formField(&form, "grant_type", "authorization_code");
    const token_response = try client.request("https://oauth2.googleapis.com/token", .POST, null, form.buffered(), &token_body);
    const tokens = try parseTokensScoped(token_response.status, token_response.body, &auth_access, &auth_refresh, scopes);
    const identity = try client.request("https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress", .GET, tokens.access_token, null, &token_body);
    try verifyProfile(identity.status, identity.body, address);
}
/// The verified refresh token into the selected store (or the caller's
/// capture for the vault, which writes it with the grant registry).
fn storeStep(io: std.Io, terminal: ?TerminalCredential, address: []const u8, credentials: keyring.Settings) anyerror!void {
    const refresh_token = std.mem.sliceTo(&auth_refresh, 0);
    if (terminal) |credential| {
        if (credential.capture) |capture| try capture.set(refresh_token) else try keyring.storeTerminal(io, credentials, address, auth_desktop.client_id.slice(), credential.grant_id, refresh_token);
    } else try keyring.store(io, credentials, address, auth_desktop.client_id.slice(), refresh_token);
}

/// Synthetic registration identity for --fixtures consent only.
pub const fixture_client_id = "omagma-fixture-consent.apps.googleusercontent.com";
/// --fixtures only: the same listener, PKCE, state, browser launch and
/// callback as authorizeScoped, then a synthetic exchange that contacts no
/// token endpoint and stores nothing. The synthetic consent page answers with
/// `fixture.<S256 challenge>.<base64url(signed-in address)>`, standing in for
/// Google's PKCE check and the Gmail profile identity, which is then verified
/// exactly as a real profile response.
pub fn authorizeFixture(io: std.Io, address: []const u8, profile: []const u8, consent_page: []const u8, scopes: []const []const u8, wait: std.Io.Clock.Duration, commit: ?*Commit) !void {
    try validateScopeSet(scopes);
    try b.address(address);
    try b.profile(profile);
    defer {
        std.crypto.secureZero(u8, &auth_code);
        std.crypto.secureZero(u8, &auth_url);
        std.crypto.secureZero(u8, &auth_header);
    }
    var flow: Flow = .{};
    defer flow.wipe();
    const code = try consent(io, &flow, fixture_client_id, address, profile, consent_page, scopes, wait);
    var local_commit: Commit = .{};
    defer local_commit.end(io);
    const owned = commit orelse &local_commit;
    try owned.begin(io);
    try owned.step(io, fixtureExchange, .{ code, @as([]const u8, &flow.verifier), address });
}
fn fixtureExchange(code: []const u8, verifier: []const u8, address: []const u8) !void {
    var parts = std.mem.splitScalar(u8, code, '.');
    if (!std.mem.eql(u8, parts.next() orelse "", "fixture")) return error.InvalidGrant;
    const challenge = parts.next() orelse return error.InvalidGrant;
    const encoded = parts.next() orelse return error.InvalidGrant;
    if (parts.next() != null or challenge.len != 43) return error.InvalidGrant;
    var expected: [43]u8 = undefined;
    pkceChallenge(verifier, &expected);
    if (!std.crypto.timing_safe.eql([43]u8, expected, challenge[0..43].*)) return error.InvalidGrant;
    var identity: [limits.max_address]u8 = undefined;
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.InvalidGrant;
    if (size == 0 or size > identity.len) return error.InvalidGrant;
    std.base64.url_safe_no_pad.Decoder.decode(identity[0..size], encoded) catch return error.InvalidGrant;
    b.address(identity[0..size]) catch return error.WrongAccount;
    var profile_json: [limits.max_address + 32]u8 = undefined;
    try verifyIdentity(try std.fmt.bufPrint(&profile_json, "{{\"emailAddress\":\"{s}\"}}", .{identity[0..size]}), address);
}
fn acceptCallback(io: std.Io, listener: *std.Io.net.Server, callback: *Callback) anyerror![]const u8 {
    for (0..2) |_| {
        const stream = try listener.accept(io);
        defer stream.close(io);
        const code = platform.deadline(io, platform.seconds(10), connectionCallback, .{ io, stream, callback }) catch |err| {
            if (err == error.AuthorizationDenied or err == error.AuthorizationFailed or err == error.Canceled) return err;
            continue;
        };
        return code;
    }
    return error.CallbackConnectionsExhausted;
}
fn connectionCallback(io: std.Io, stream: std.Io.net.Stream, callback: *Callback) anyerror![]const u8 {
    var read_buffer: [1024]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);
    var size: usize = 0;
    while (size < auth_header.len) {
        auth_header[size] = try reader.interface.takeByte();
        size += 1;
        if (size >= 4 and std.mem.eql(u8, auth_header[size - 4 .. size], "\r\n\r\n")) break;
    }
    const parsed = callback.parse(auth_header[0..size], &auth_code);
    var writer = std.Io.net.Stream.Writer.init(stream, io, &.{});
    const page = if (parsed) |_| "Authorization received. You can close this tab." else |_| "Authorization callback rejected. Return to the terminal.";
    try writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ if (parsed) |_| "200 OK" else |_| "400 Bad Request", page.len, page });
    try writer.interface.flush();
    return parsed;
}

test "PKCE S256 published vector" {
    var result: [43]u8 = undefined;
    pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", &result);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &result);
}
test "profile verification requires HTTP success and matching identity" {
    const body = "{\"emailAddress\":\"expected@example.invalid\"}";
    try verifyProfile(200, body, "expected@example.invalid");
    try std.testing.expectError(error.WrongAccount, verifyProfile(200, body, "other@example.invalid"));
    try std.testing.expectError(error.ProfileUnauthenticated, verifyProfile(401, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileAccessDenied, verifyProfile(403, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileRateLimited, verifyProfile(429, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileTransientFailure, verifyProfile(503, body, "expected@example.invalid"));
    try std.testing.expectError(error.ProfileVerificationFailed, verifyProfile(404, body, "expected@example.invalid"));
}
test "callback state, method, ambiguity and one-time completion" {
    var callback: Callback = .{ .expected_state = "expected" };
    var code: [128]u8 = undefined;
    try std.testing.expectError(error.StateMismatch, callback.parse("GET /oauth2/callback?code=secret&state=wrong HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallbackMethod, callback.parse("POST /oauth2/callback?code=secret&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.AmbiguousCallback, callback.parse("GET /oauth2/callback?code=secret&state=expected&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectEqualStrings("example/code", try callback.parse("GET /oauth2/callback?code=example%2Fcode&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.DuplicateCallback, callback.parse("GET /oauth2/callback?code=secret&state=expected HTTP/1.1\r\n\r\n", &code));
}
test "cancelled callback and unsafe queries" {
    var callback: Callback = .{ .expected_state = "expected" };
    var code: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidEscape, callback.parse("GET /oauth2/callback?code=%GG&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.AuthorizationDenied, callback.parse("GET /oauth2/callback?error=access_denied&state=expected HTTP/1.1\r\n\r\n", &code));
}
test "token parsing absent refresh revoked grant and account identity" {
    var access: [limits.secret]u8 = undefined;
    var refresh_token: [limits.secret]u8 = undefined;
    try std.testing.expectError(error.MissingRefreshToken, parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600}", &access, &refresh_token));
    try std.testing.expectError(error.InvalidGrant, parseTokens(400, "{\"error\":\"invalid_grant\"}", &access, null));
    try std.testing.expectError(error.WrongAccount, verifyIdentity("{\"emailAddress\":\"other@example.invalid\"}", "expected@example.invalid"));
    const result = try parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"synthetic-refresh\"}", &access, &refresh_token);
    try std.testing.expectEqualStrings("synthetic", result.access_token);
}

/// Synthetic listener lifecycle verification. No browser or Google requests.
pub fn callbackProbe(io: std.Io) !void {
    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const short: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) };
    {
        var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
        const address = listener.socket.address;
        var callback: Callback = .{ .expected_state = "synthetic-state" };
        try std.testing.expectError(error.Timeout, platform.deadline(io, short, acceptCallback, .{ io, &listener, &callback }));
        listener.deinit(io);
        try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    }
    {
        var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
        defer listener.deinit(io);
        var callback: Callback = .{ .expected_state = "synthetic-state" };
        var future = try io.concurrent(callbackWithTimeout, .{ io, short, &listener, &callback });
        defer _ = future.cancel(io) catch "";
        const stalled = try listener.socket.address.connect(io, .{ .mode = .stream });
        defer stalled.close(io);
        try std.testing.expectError(error.Timeout, future.await(io));
    }
    {
        var listener = try loopback.listen(io, .{ .kernel_backlog = 2 });
        const address = listener.socket.address;
        var callback: Callback = .{ .expected_state = "synthetic-state" };
        var future = try io.concurrent(callbackWithTimeout, .{ io, platform.seconds(2), &listener, &callback });
        defer _ = future.cancel(io) catch "";
        try syntheticCallback(io, address, "GET /oauth2/callback?code=synthetic-code&state=wrong HTTP/1.1\r\nHost: localhost\r\n\r\n", 400);
        try syntheticCallback(io, address, "GET /oauth2/callback?code=synthetic-code&state=synthetic-state HTTP/1.1\r\nHost: localhost\r\n\r\n", 200);
        const result = try future.await(io);
        try std.testing.expectEqualStrings("synthetic-code", result);
        listener.deinit(io);
        try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    }
    std.crypto.secureZero(u8, &auth_header);
    std.crypto.secureZero(u8, &auth_code);
}
fn callbackWithTimeout(io: std.Io, duration: std.Io.Clock.Duration, listener: *std.Io.net.Server, callback: *Callback) anyerror![]const u8 {
    return try platform.deadline(io, duration, acceptCallback, .{ io, listener, callback });
}
fn syntheticCallback(io: std.Io, address: std.Io.net.IpAddress, head: []const u8, expected_status: u16) !void {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer = std.Io.net.Stream.Writer.init(stream, io, &.{});
    try writer.interface.writeAll(head);
    try writer.interface.flush();
    var buffer: [1024]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &buffer);
    const first = (try reader.interface.takeDelimiter('\n')) orelse return error.EmptyCallbackResponse;
    var expected: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&expected, "HTTP/1.1 {d} ", .{expected_status});
    if (!std.mem.startsWith(u8, first, prefix)) return error.UnexpectedCallbackStatus;
    // Read the bounded reply through EOF before closing the client. Closing
    // after only the status line can reset a still-writing server connection,
    // turning a valid callback into a harness-induced response-write failure.
    var remainder: [1024]u8 = undefined;
    const remaining = try reader.interface.readSliceShort(&remainder);
    if (remaining == remainder.len) return error.CallbackResponseTooLarge;
}

// Static reservations exclude caller-provided tokens and response storage.
pub const reservation_bytes = @sizeOf(@TypeOf(json_workspace)) + @sizeOf(@TypeOf(token_body)) + @sizeOf(@TypeOf(form_buffer)) + @sizeOf(@TypeOf(desktop_body)) + @sizeOf(@TypeOf(auth_access)) + @sizeOf(@TypeOf(auth_refresh)) + @sizeOf(@TypeOf(auth_code)) + @sizeOf(@TypeOf(auth_url)) + @sizeOf(@TypeOf(auth_header)) + @sizeOf(DesktopClient) + @sizeOf(TokenError) + 64;

test "desktop client and token scope/capacity failures are explicit" {
    var desktop: DesktopClient = .{};
    defer desktop.wipe();
    try parseDesktop("{\"installed\":{\"client_id\":\"synthetic.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret\",\"token_uri\":\"https://oauth2.googleapis.com/token\"}}", &desktop);
    try std.testing.expectError(error.MissingField, parseDesktop("{\"web\":{\"client_id\":\"synthetic.apps.googleusercontent.com\"}}", &desktop));
    try std.testing.expectError(error.InvalidDesktopClient, parseDesktop("{\"installed\":{\"client_id\":\"synthetic.apps.googleusercontent.com\",\"client_secret\":\"synthetic-secret\",\"token_uri\":\"https://attacker.invalid/token\"}}", &desktop));
    var access: [32]u8 = @splat('x');
    try std.testing.expectError(error.UnexpectedScope, parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.modify\"}", &access, null));
    try std.testing.expectEqual(@as(u8, 0), access[0]);
    _ = try parseTokens(200, "{\"access_token\":\"synthetic\",\"token_type\":\"Bearer\",\"expires_in\":3600}", &access, null);
    try std.testing.expectEqual(@as(u8, 0), access[31]);
    try std.testing.expectError(error.DuplicateField, parseTokens(200, "{\"access_token\":\"a\",\"access_token\":\"b\"}", &access, null));
    var oversized: [limits.token_response + 1]u8 = @splat(' ');
    try std.testing.expectError(error.TokenResponseTooLarge, parseTokens(200, &oversized, &access, null));
}
test "callback rejects encoded duplicate keys controls and wrong path" {
    var callback: Callback = .{ .expected_state = "expected" };
    var code: [128]u8 = undefined;
    try std.testing.expectError(error.AmbiguousCallback, callback.parse("GET /oauth2/callback?code=synthetic&state=expected&%73tate=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallback, callback.parse("GET /oauth2/callback?code=%00&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallbackPath, callback.parse("GET /other?code=synthetic&state=expected HTTP/1.1\r\n\r\n", &code));
    try std.testing.expectError(error.InvalidCallback, callback.parse("GET /oauth2/callback?code=synthetic&state=expected HTTP/1.1\r\nContent-Length: 1\r\n\r\n", &code));
}
test "terminal scopes match complete returned grant without relaxing bar policy" {
    var access: [128]u8 = @splat(0x7f);
    const expected = [_][]const u8{ readonly_scope, "https://www.googleapis.com/auth/gmail.send" };
    const complete = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-access\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.readonly\"}";
    _ = try parseTokensScoped(200, complete, &access, null, &expected);
    try std.testing.expectError(error.UnexpectedScope, parseTokens(200, complete, &access, null));
    for (access) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const missing = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-access\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly\"}";
    try std.testing.expectError(error.UnexpectedScope, parseTokensScoped(200, missing, &access, null, &expected));
    const repeated = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-access\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.readonly\"}";
    try std.testing.expectError(error.UnexpectedScope, parseTokensScoped(200, repeated, &access, null, &expected));
    try std.testing.expectError(error.UnexpectedScope, authorizeScoped(std.testing.io, "/nonexistent-synthetic-client", "synthetic@example.test", "synthetic-profile", "/usr/bin/true", &expected, null, .{}));
}

test "calendar: optional scopes require the complete returned terminal grant and remain forbidden to the bar" {
    const expected = [_][]const u8{
        readonly_scope,
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.events.freebusy",
    };
    try validateScopeSet(&expected);
    const complete = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-calendar\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/calendar.events.freebusy https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly\"}";
    var access: [64]u8 = @splat(0x7f);
    _ = try parseTokensScoped(200, complete, &access, null, &expected);
    try std.testing.expectError(error.UnexpectedScope, parseTokens(200, complete, &access, null));
    for (access) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const incomplete = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-calendar\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly\"}";
    try std.testing.expectError(error.UnexpectedScope, parseTokensScoped(200, incomplete, &access, null, &expected));
    try std.testing.expectError(error.UnexpectedScope, authorizeScoped(std.testing.io, "/nonexistent-synthetic-client", "synthetic@example.test", "synthetic-profile", "/usr/bin/true", &expected, null, .{}));
}

test "meet notes: returned terminal permission must be complete and is rejected by the bar" {
    const expected = [_][]const u8{ readonly_scope, "https://www.googleapis.com/auth/meetings.space.settings" };
    try validateScopeSet(&expected);
    const complete = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-meet\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/meetings.space.settings https://www.googleapis.com/auth/gmail.readonly\"}";
    var access: [64]u8 = @splat(0x7f);
    _ = try parseTokensScoped(200, complete, &access, null, &expected);
    try std.testing.expectError(error.UnexpectedScope, parseTokens(200, complete, &access, null));
    for (access) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const incomplete = "{\"token_type\":\"Bearer\",\"access_token\":\"synthetic-meet\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/gmail.readonly\"}";
    try std.testing.expectError(error.UnexpectedScope, parseTokensScoped(200, incomplete, &access, null, &expected));
}
