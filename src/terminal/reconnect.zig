//! Reconnect an expired Google sign-in from the TUI. A bounded, pure state
//! machine behind one modal dialog: the TUI reads the account's recorded grant
//! (auth.status), then, on an explicit Enter, its sole worker runs the same
//! `auth.authorize` command as `omagma terminal-auth authorize` with
//! reconnect:true, the recorded capability set and the recorded grant
//! identity. The backend refuses any other set, so consent can neither broaden
//! nor narrow access. No code, verifier, state or token ever reaches this
//! module, the screen or the status line: only account names, capability
//! names, error codes and Google's sanitized reason.
const std = @import("std");
const b = @import("../bounded.zig");
const Value = std.json.Value;

pub const Phase = enum { closed, checking, ready, waiting, verifying, succeeded, failed };
pub const max_capabilities = 16;
pub const consent_minutes = 3;
/// After Google's callback the backend finishes within its own bound; the
/// dialog stops promising an outcome after this long.
pub const finishing_seconds = 30;

pub const State = struct {
    phase: Phase = .closed,
    account_index: usize = 0,
    account: b.Text(254) = .{},
    profile: b.Text(128) = .{},
    capabilities: [max_capabilities]b.Text(32) = @splat(.{}),
    capability_count: usize = 0,
    grant_id: b.Text(64) = .{},
    store: b.Text(16) = .{},
    reason_kind: b.Text(32) = .{},
    reason_subtype: b.Text(48) = .{},
    reason_description: b.Text(160) = .{},
    failure: b.Text(64) = .{},
    /// The account's status has been requested from the worker.
    requested: bool = false,
    /// 0 primary action, 1 Cancel/Close.
    focus: u8 = 0,
    /// Opened from Calendar: reload its account lists after success.
    calendar: bool = false,
    /// Google's callback arrived; the worker is storing the result and can
    /// no longer be cancelled (the backend reports the authorizing phase).
    finishing: bool = false,
    /// Finishing took longer than finishing_seconds: the outcome is unknown
    /// and the dialog may be closed while the worker completes.
    unconfirmed: bool = false,
    /// q or Ctrl+C was pressed once while finishing; the next one quits.
    quit_armed: bool = false,
    /// The verification refresh has been started.
    verify_started: bool = false,
    /// The error behind an unconfirmed store, or the verification refresh's.
    detail: b.Text(64) = .{},
    /// This session last saw Google refuse the account (InvalidGrant).
    seen_refused: bool = false,
    /// A one-line notice inside the dialog (visible over mail and Calendar).
    notice: b.Text(96) = .{},
    /// First body line shown when the dialog is taller than the terminal.
    scroll: usize = 0,

    pub fn open(self: *State, index: usize, account: []const u8, calendar: bool) !void {
        self.* = .{};
        errdefer self.* = .{};
        try self.account.set(account);
        self.account_index = index;
        self.calendar = calendar;
        self.phase = .checking;
    }
    pub fn close(self: *State) void {
        self.* = .{};
    }
    pub fn active(self: *const State) bool {
        return self.phase != .closed;
    }
    /// The worker's auth.status data for this account. Without a recorded,
    /// enabled terminal grant there is nothing to renew: the dialog explains
    /// that instead of guessing a capability list.
    pub fn statusLoaded(self: *State, data: Value) !void {
        if (self.phase != .checking) return error.ReconnectStateChanged;
        if (!std.ascii.eqlIgnoreCase(text(data, "account"), self.account.slice())) return error.WrongAccount;
        try self.store.set(text(data, "credentialStore")[0..@min(text(data, "credentialStore").len, 16)]);
        const last = get(data, "lastRefreshError");
        if (last == .object) {
            self.reason_kind.set(clip(text(last, "kind"), 32)) catch {};
            self.reason_subtype.set(clip(text(last, "subtype"), 48)) catch {};
            self.reason_description.set(clip(text(last, "description"), 160)) catch {};
        }
        const grant = get(data, "grant");
        if (grant != .object) return self.fail("ReconnectRequiresGrant");
        if (get(grant, "enabled") == .bool and !get(grant, "enabled").bool) return self.fail("GrantDisabled");
        const list = get(grant, "capabilities");
        if (list != .array or list.array.items.len == 0 or list.array.items.len > max_capabilities) return self.fail("ReconnectRequiresGrant");
        for (list.array.items, 0..) |item, index| {
            if (item != .string or item.string.len == 0) return self.fail("ReconnectRequiresGrant");
            self.capabilities[index].set(item.string) catch return self.fail("ReconnectRequiresGrant");
        }
        self.capability_count = list.array.items.len;
        self.grant_id.set(text(grant, "grantId")) catch return self.fail("ReconnectRequiresGrant");
        if (self.grant_id.len != 64) return self.fail("ReconnectRequiresGrant");
        self.phase = .ready;
        self.focus = 0;
    }
    pub fn fail(self: *State, code: []const u8) void {
        self.failure.set(clip(code, 64)) catch {};
        self.phase = .failed;
        self.finishing = false;
        self.unconfirmed = false;
        self.quit_armed = false;
        self.scroll = 0;
        self.focus = 0;
    }
    /// Google approved but storing could not be confirmed: check the account
    /// with a refresh before saying anything about the outcome.
    pub fn verify(self: *State, cause: []const u8) void {
        self.detail.set(clip(cause, 64)) catch {};
        self.phase = .verifying;
        self.finishing = false;
        self.unconfirmed = false;
        self.quit_armed = false;
        self.verify_started = false;
        self.scroll = 0;
        self.focus = 1;
    }
    /// The finishing bound passed without a result.
    pub fn storeUnconfirmed(self: *State) void {
        if (self.finishing) self.unconfirmed = true;
    }
    /// Enter on the primary action: only a known grant can be renewed.
    pub fn canStart(self: *const State) bool {
        return (self.phase == .ready or (self.phase == .failed and retryable(self.failure.slice()))) and self.capability_count > 0 and self.grant_id.len == 64;
    }
    pub fn begin(self: *State) !void {
        if (!self.canStart()) return error.ReconnectUnavailable;
        self.failure = .{};
        self.detail = .{};
        self.notice = .{};
        self.phase = .waiting;
        self.finishing = false;
        self.unconfirmed = false;
        self.quit_armed = false;
        self.scroll = 0;
        self.focus = 1;
    }
    /// The worker reported Google's callback: from now on only its result
    /// closes the dialog; Esc, q and Ctrl+C are ignored.
    pub fn callbackArrived(self: *State) void {
        if (self.phase == .waiting) self.finishing = true;
    }
    pub fn cancellable(self: *const State) bool {
        return self.phase != .closed and !self.finishing;
    }
    /// Esc may close the dialog: always, except while finishing with the
    /// outcome still promised.
    pub fn closable(self: *const State) bool {
        return self.phase != .closed and (!self.finishing or self.unconfirmed);
    }
    /// The worker's auth.authorize reply. Success must name exactly the
    /// requested capabilities; anything else is reported, never assumed.
    pub fn finished(self: *State, data: Value) !void {
        if (self.phase != .waiting) return error.ReconnectStateChanged;
        if (!std.ascii.eqlIgnoreCase(text(data, "account"), self.account.slice())) return self.fail("WrongAccount");
        if (get(data, "authorized") != .bool or !get(data, "authorized").bool) return self.fail("AuthorizationFailed");
        const list = get(data, "capabilities");
        if (list != .array or list.array.items.len != self.capability_count) return self.fail("ReconnectCapabilitiesChanged");
        for (list.array.items) |item| {
            if (item != .string or !self.has(item.string)) return self.fail("ReconnectCapabilitiesChanged");
        }
        self.phase = .succeeded;
    }
    pub fn has(self: *const State, capability: []const u8) bool {
        for (self.capabilities[0..self.capability_count]) |*item| if (std.mem.eql(u8, item.slice(), capability)) return true;
        return false;
    }
    /// Capability names for the request; slices borrow this state.
    pub fn requestCapabilities(self: *const State, out: *[max_capabilities][]const u8) []const []const u8 {
        for (self.capabilities[0..self.capability_count], 0..) |*item, index| out[index] = item.slice();
        return out[0..self.capability_count];
    }
    pub fn capabilityText(self: *const State, a: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        for (self.capabilities[0..self.capability_count], 0..) |*item, index| {
            if (index > 0) try list.appendSlice(a, ", ");
            try list.appendSlice(a, item.slice());
        }
        return list.items;
    }
    /// Compact labels keep both buttons whole in narrow dialogs; the footer
    /// still names their keys.
    pub fn primaryLabel(self: *const State, compact: bool) []const u8 {
        return switch (self.phase) {
            .ready => if (compact) "[Reconnect]" else "[Reconnect · Enter]",
            .failed => if (self.canStart()) (if (compact) "[Try again]" else "[Try again · Enter]") else (if (compact) "[Close]" else "[Close · Enter]"),
            else => "",
        };
    }
    /// Empty while finishing: nothing may interrupt storing the result,
    /// until the outcome is no longer promised.
    pub fn secondaryLabel(self: *const State, compact: bool) []const u8 {
        if (self.finishing and !self.unconfirmed) return "";
        if (self.finishing) return if (compact) "[Close]" else "[Close · Esc]";
        return switch (self.phase) {
            .waiting, .checking, .ready => if (compact) "[Cancel]" else "[Cancel · Esc]",
            else => if (compact) "[Close]" else "[Close · Esc]",
        };
    }
    /// The footer; j/k is named only when the text actually scrolls.
    pub fn hints(self: *const State, scrollable: bool) []const u8 {
        if (self.finishing and self.unconfirmed) return "Storing has not finished · outcome unknown · Esc Close";
        if (self.finishing) return if (self.quit_armed) "Storing the renewed sign-in… · q again quits anyway" else "Google approved · storing the renewed sign-in… · q twice quits anyway";
        return switch (self.phase) {
            .checking => "Reading this account's sign-in… · Esc Cancel",
            .ready => if (scrollable) "Enter Reconnect · Tab Choose · j/k Scroll · Esc Cancel" else "Enter Reconnect · Tab Choose · Esc Cancel",
            .waiting => "Waiting for Google consent in Chrome · Esc Cancel",
            .verifying => "Checking the renewed sign-in with a refresh… · Esc Close",
            .failed => if (self.canStart()) (if (scrollable) "Enter Try again · Tab Choose · j/k Scroll · Esc Close" else "Enter Try again · Tab Choose · Esc Close") else (if (scrollable) "Enter Close · j/k Scroll · Esc Close" else "Enter Close · Esc Close"),
            else => "",
        };
    }
    /// One line describing why Google refused the stored sign-in. Without a
    /// recorded refusal it never claims the sign-in expired.
    pub fn reasonText(self: *const State) []const u8 {
        const kind = self.reason_kind.slice();
        if (std.mem.eql(u8, kind, "reauthenticationRequired")) return "Your Google Workspace requires signing in again (re-authentication policy)";
        if (std.mem.eql(u8, kind, "expiredOrRevoked")) return "The stored sign-in expired or was revoked (revoked access, a password change, or a Testing-mode app's 7-day limit)";
        if (kind.len > 0) return "Google refused the stored sign-in";
        if (self.seen_refused) return "No refusal of this sign-in is recorded any more; it may have been renewed in another Omagma window · Ctrl+R in the mailbox checks it · reconnecting renews it anyway";
        return "No refusal of this sign-in is recorded · reconnecting renews it anyway";
    }
};

/// Failures a person can retry by pressing Enter again.
pub fn retryable(code: []const u8) bool {
    for ([_][]const u8{ "AuthorizationDenied", "AuthorizationFailed", "WrongAccount", "Timeout", "Canceled", "UnexpectedScope", "InvalidGrant", "TokenExchangeFailed", "NotRenewed", "RenewalUnconfirmed", "CallbackConnectionsExhausted", "TransientFailure", "ConnectionRefused", "NetworkUnreachable", "ConnectionTimedOut", "MissingRefreshToken", "BackendStopped", "VaultOperationCanceled", "LaunchBusy" }) |item| if (std.mem.eql(u8, code, item)) return true;
    return false;
}

/// Plain sentences for every outcome; never a raw provider message.
pub fn failureText(code: []const u8) []const u8 {
    const Entry = struct { code: []const u8, text: []const u8 };
    const table = [_]Entry{
        .{ .code = "AuthorizationDenied", .text = "You declined access in Google. Nothing was changed." },
        .{ .code = "WrongAccount", .text = "Google signed in a different account. Nothing was stored; choose this account in Chrome." },
        .{ .code = "Timeout", .text = "Google consent timed out after 3 minutes. Nothing was changed." },
        .{ .code = "TokenExchangeFailed", .text = "Google approved, but exchanging the approval for a sign-in failed. Nothing was stored; try again." },
        .{ .code = "NotRenewed", .text = "Google approved, but the renewed sign-in was not stored: Google still refuses this account's stored sign-in. Try again." },
        .{ .code = "RenewalUnconfirmed", .text = "Google approved, but Omagma could not confirm that the renewed sign-in was stored: the check below failed. Check with omagma terminal-auth status, then try again if needed." },
        .{ .code = "Canceled", .text = "Reconnect canceled. Nothing was changed." },
        .{ .code = "UnexpectedScope", .text = "Google granted different permissions than this account had (a box was unchecked?). Nothing was stored; allow every requested permission." },
        .{ .code = "ReconnectRequiresGrant", .text = "This account has no recorded terminal grant to renew. Set it up with omagma terminal-auth authorize." },
        .{ .code = "ReconnectCapabilitiesChanged", .text = "The account's recorded permissions changed. Nothing was stored; open Reconnect again." },
        .{ .code = "GrantChanged", .text = "The account's recorded permissions changed. Nothing was stored; open Reconnect again." },
        .{ .code = "GrantDisabled", .text = "This account's terminal grant is disabled." },
        .{ .code = "ExecFailed", .text = "Chrome could not be started. Check the chrome path in the Omagma config." },
        .{ .code = "FileNotFound", .text = "Chrome or the OAuth client file was not found. Check the Omagma config." },
        .{ .code = "OAuthClientRequired", .text = "This account's OAuth client registration is missing. Check the Omagma config." },
        .{ .code = "SeparateTerminalClientRequired", .text = "Broader access needs a separate terminal OAuth client. Nothing was changed." },
        .{ .code = "VaultLocked", .text = "Encrypted mail is locked. Run omagma vault unlock, then try again." },
        .{ .code = "BackendStopped", .text = "The encrypted mail service stopped. Start it and try again." },
        .{ .code = "KeyringUnavailable", .text = "The selected credential store is unavailable in this session. Nothing was changed." },
        .{ .code = "KeyringLocked", .text = "The selected credential store is locked. Unlock it and try again." },
        .{ .code = "FixtureOnly", .text = "Synthetic fixtures do not authorize accounts." },
        .{ .code = "FixtureConsentPageRequired", .text = "Synthetic fixtures never open a browser; set fixtureConsentPage in the fixture config to a synthetic consent page." },
        .{ .code = "UnknownOutcome", .text = "The outcome is unknown. Check terminal-auth status before trying again." },
    };
    for (table) |entry| if (std.mem.eql(u8, entry.code, code)) return entry.text;
    return "Google sign-in was not renewed. Nothing was changed.";
}

fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn text(value: Value, key: []const u8) []const u8 {
    const field = get(value, key);
    return if (field == .string) field.string else "";
}
fn clip(raw: []const u8, limit: usize) []const u8 {
    var end = @min(raw.len, limit);
    while (end > 0 and !std.unicode.utf8ValidateSlice(raw[0..end])) end -= 1;
    return raw[0..end];
}

fn parse(a: std.mem.Allocator, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, raw, .{});
}
const grant_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "reconnect state: status, explicit start, success keeps the recorded capabilities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    try std.testing.expect(!state.active());
    try state.open(1, "work@example.com", false);
    try std.testing.expectEqual(Phase.checking, state.phase);
    // Nothing starts before the account's recorded grant is known.
    try std.testing.expect(!state.canStart());
    try std.testing.expectError(error.ReconnectUnavailable, state.begin());
    try state.statusLoaded(try parse(a, "{\"account\":\"work@example.com\",\"credentialStore\":\"keyring\",\"grant\":{\"grantId\":\"" ++ grant_id ++ "\",\"capabilities\":[\"mail-read\",\"mail-send\",\"calendar-read\"]},\"lastRefreshError\":{\"error\":\"invalid_grant\",\"subtype\":\"invalid_rapt\",\"description\":\"reauth related error (invalid_rapt)\",\"kind\":\"reauthenticationRequired\",\"at\":1}}"));
    try std.testing.expectEqual(Phase.ready, state.phase);
    try std.testing.expectEqualStrings("Your Google Workspace requires signing in again (re-authentication policy)", state.reasonText());
    try std.testing.expectEqualStrings("reauth related error (invalid_rapt)", state.reason_description.slice());
    try std.testing.expectEqualStrings("mail-read, mail-send, calendar-read", try state.capabilityText(a));
    try std.testing.expectEqualStrings("[Reconnect · Enter]", state.primaryLabel(false));
    var out: [max_capabilities][]const u8 = undefined;
    const request = state.requestCapabilities(&out);
    try std.testing.expectEqual(@as(usize, 3), request.len);
    try state.begin();
    try std.testing.expectEqual(Phase.waiting, state.phase);
    try std.testing.expectEqualStrings("Waiting for Google consent in Chrome · Esc Cancel", state.hints(false));
    try state.finished(try parse(a, "{\"account\":\"work@example.com\",\"authorized\":true,\"reconnected\":true,\"capabilities\":[\"calendar-read\",\"mail-read\",\"mail-send\"]}"));
    try std.testing.expectEqual(Phase.succeeded, state.phase);
}

test "reconnect state: denied, wrong account, timeout and cancel are retryable failures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const status = "{\"account\":\"work@example.com\",\"grant\":{\"grantId\":\"" ++ grant_id ++ "\",\"capabilities\":[\"mail-read\"]},\"lastRefreshError\":null}";
    for ([_][]const u8{ "AuthorizationDenied", "WrongAccount", "Timeout", "Canceled" }) |code| {
        var state: State = .{};
        try state.open(1, "work@example.com", true);
        try state.statusLoaded(try parse(a, status));
        try std.testing.expectEqualStrings("No refusal of this sign-in is recorded · reconnecting renews it anyway", state.reasonText());
        try state.begin();
        state.fail(code);
        try std.testing.expectEqual(Phase.failed, state.phase);
        try std.testing.expect(state.canStart());
        try std.testing.expectEqualStrings("[Try again · Enter]", state.primaryLabel(false));
        try std.testing.expect(!std.mem.eql(u8, failureText(code), failureText("SomethingElse")));
        try state.begin();
        try std.testing.expectEqual(Phase.waiting, state.phase);
    }
    // A reply that does not prove the same set is never treated as success.
    var state: State = .{};
    try state.open(1, "work@example.com", false);
    try state.statusLoaded(try parse(a, status));
    try state.begin();
    try state.finished(try parse(a, "{\"account\":\"work@example.com\",\"authorized\":true,\"capabilities\":[\"mail-read\",\"mail-send\"]}"));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expectEqualStrings("ReconnectCapabilitiesChanged", state.failure.slice());
    // A changed grant needs a fresh status read, not another consent.
    try std.testing.expect(!state.canStart());
    try state.open(1, "work@example.com", false);
    try state.statusLoaded(try parse(a, status));
    try state.begin();
    try state.finished(try parse(a, "{\"account\":\"other@example.com\",\"authorized\":true,\"capabilities\":[\"mail-read\"]}"));
    try std.testing.expectEqualStrings("WrongAccount", state.failure.slice());
}

test "reconnect state: no recorded grant, a disabled grant or a changed account cannot start" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    try state.open(0, "personal@example.com", false);
    try state.statusLoaded(try parse(a, "{\"account\":\"personal@example.com\",\"configured\":false}"));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expect(!state.canStart());
    try std.testing.expectEqualStrings("[Close · Enter]", state.primaryLabel(false));
    try state.open(0, "personal@example.com", false);
    try state.statusLoaded(try parse(a, "{\"account\":\"personal@example.com\",\"grant\":{\"enabled\":false,\"grantId\":\"" ++ grant_id ++ "\",\"capabilities\":[\"mail-read\"]}}"));
    try std.testing.expect(!state.canStart());
    // A disabled grant is named as such, not as a missing one.
    try std.testing.expectEqualStrings("GrantDisabled", state.failure.slice());
    try std.testing.expect(std.mem.indexOf(u8, failureText(state.failure.slice()), "disabled") != null);
    try state.open(0, "personal@example.com", false);
    try std.testing.expectError(error.WrongAccount, state.statusLoaded(try parse(a, "{\"account\":\"other@example.com\"}")));
    state.close();
    try std.testing.expect(!state.active());
}

test "reconnect state: after Google's callback the dialog cannot be cancelled and drops Cancel" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    try state.open(1, "work@example.com", false);
    try state.statusLoaded(try parse(a, "{\"account\":\"work@example.com\",\"grant\":{\"grantId\":\"" ++ grant_id ++ "\",\"capabilities\":[\"mail-read\"]},\"lastRefreshError\":null}"));
    // No recorded refusal: neutral wording, never "expired".
    try std.testing.expect(std.mem.indexOf(u8, state.reasonText(), "expired") == null);
    try std.testing.expectEqualStrings("[Reconnect]", state.primaryLabel(true));
    try std.testing.expectEqualStrings("[Cancel]", state.secondaryLabel(true));
    try state.begin();
    try std.testing.expect(state.cancellable());
    state.callbackArrived();
    try std.testing.expect(!state.cancellable());
    try std.testing.expectEqualStrings("", state.secondaryLabel(false));
    try std.testing.expect(std.mem.indexOf(u8, state.hints(false), "Esc") == null);
    try state.finished(try parse(a, "{\"account\":\"work@example.com\",\"authorized\":true,\"capabilities\":[\"mail-read\"]}"));
    try std.testing.expectEqual(Phase.succeeded, state.phase);
}

test "reconnect state: an unknown store outcome is checked, a finishing bound makes it closable, and consent texts are never reused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    try state.open(1, "work@example.com", false);
    try state.statusLoaded(try parse(a, "{\"account\":\"work@example.com\",\"grant\":{\"grantId\":\"" ++ grant_id ++ "\",\"capabilities\":[\"mail-read\"]},\"lastRefreshError\":null}"));
    try std.testing.expectEqualStrings("Enter Reconnect · Tab Choose · Esc Cancel", state.hints(false));
    try std.testing.expect(std.mem.indexOf(u8, state.hints(true), "j/k Scroll") != null);
    try state.begin();
    state.callbackArrived();
    try std.testing.expect(!state.closable());
    try std.testing.expect(std.mem.indexOf(u8, state.hints(false), "q twice quits anyway") != null);
    state.quit_armed = true;
    try std.testing.expect(std.mem.indexOf(u8, state.hints(false), "q again quits anyway") != null);
    // Past the bound: unknown, closable, still not cancellable.
    state.storeUnconfirmed();
    try std.testing.expect(state.closable() and !state.cancellable());
    try std.testing.expectEqualStrings("[Close · Esc]", state.secondaryLabel(false));
    state.verify("Timeout");
    try std.testing.expectEqual(Phase.verifying, state.phase);
    try std.testing.expect(state.closable() and !state.finishing and !state.quit_armed);
    try std.testing.expectEqualStrings("", state.primaryLabel(false));
    try std.testing.expectEqualStrings("Checking the renewed sign-in with a refresh… · Esc Close", state.hints(false));
    for ([_][]const u8{ "TokenExchangeFailed", "NotRenewed", "RenewalUnconfirmed" }) |code| {
        try std.testing.expect(retryable(code));
        try std.testing.expect(std.mem.startsWith(u8, failureText(code), "Google approved, but"));
        try std.testing.expect(std.mem.indexOf(u8, failureText(code), "consent timed out") == null);
        try std.testing.expect(std.mem.indexOf(u8, failureText(code), "Nothing was changed") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, failureText("FixtureConsentPageRequired"), "as chrome") == null);
    try std.testing.expect(std.mem.indexOf(u8, failureText("FixtureConsentPageRequired"), "fixtureConsentPage") != null);
    // A reason that disappeared is explained, not hidden.
    var renewed: State = .{};
    try renewed.open(1, "work@example.com", false);
    renewed.seen_refused = true;
    try std.testing.expect(std.mem.indexOf(u8, renewed.reasonText(), "another Omagma window") != null);
}
