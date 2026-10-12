//! Browser-owned OAuth sessions inject a bounded HTTP transport. Credentials
//! never enter this module: it holds only the verified account and capabilities.
const std = @import("std");
const gmail = @import("terminal/gmail.zig");
const j = @import("terminal/json.zig");
const types = @import("terminal/types.zig");
const auth = @import("terminal/auth.zig");
const recipients = @import("terminal/recipients.zig");
extern "env" fn http_request(session: u32, method_ptr: usize, method_len: usize, url_ptr: usize, url_len: usize, body_ptr: usize, body_len: usize, response_ptr: usize, response_capacity: usize, metadata_ptr: usize) u32;
extern "env" fn now_ms() f64;
const response_limit = 3 * 1024 * 1024;
var response_buffer: [response_limit]u8 = undefined;
var response_metadata: [2]u32 = undefined;
const readonly_scope = "https://www.googleapis.com/auth/gmail.readonly";
const send_scope = "https://www.googleapis.com/auth/gmail.send";
const modify_scope = "https://www.googleapis.com/auth/gmail.modify";
const full_scope = "https://mail.google.com/";
const contacts_read_scope = "https://www.googleapis.com/auth/contacts.readonly";
const contacts_write_scope = "https://www.googleapis.com/auth/contacts";
pub const contacts_limit = 100;
const people_list_url = "https://people.googleapis.com/v1/people/me/connections?personFields=names,emailAddresses,metadata&sources=READ_SOURCE_TYPE_CONTACT&pageSize=100&pageToken=";
const people_search_prefix = "https://people.googleapis.com/v1/people:searchContacts?readMask=names,emailAddresses,metadata&pageSize=30&query=";

fn timestamp(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    const ms = now_ms();
    const safe = if (std.math.isFinite(ms) and ms >= 0 and ms < 253402300800000) ms else 0;
    return .{ .nanoseconds = @as(i96, @intFromFloat(safe)) * std.time.ns_per_ms };
}
fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {}
const vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.now = timestamp;
    table.checkCancel = checkCancel;
    break :blk table;
};
pub const io: std.Io = .{ .userdata = null, .vtable = &vtable };

/// Exact mailbox mutation endpoints. Sending and mailbox changes have separate
/// authority and uncertainty handling; neither grants arbitrary Gmail writes.
fn mailboxRequest(method: std.http.Method, url: []const u8) bool {
    const root = "https://gmail.googleapis.com/gmail/v1/users/me/";
    if (!std.mem.startsWith(u8, url, root)) return false;
    const path = url[root.len..];
    if (method == .POST and std.mem.eql(u8, path, "labels")) return true;
    if ((method == .PATCH or method == .DELETE) and std.mem.startsWith(u8, path, "labels/")) {
        @import("bounded.zig").identifier(path[7..]) catch return false;
        return true;
    }
    if (method != .POST or !std.mem.startsWith(u8, path, "messages/")) return false;
    const rest = path[9..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    @import("bounded.zig").identifier(rest[0..slash]) catch return false;
    const action = rest[slash..];
    return std.mem.eql(u8, action, "/modify?fields=id,labelIds") or std.mem.eql(u8, action, "/modify") or std.mem.eql(u8, action, "/trash") or std.mem.eql(u8, action, "/untrash");
}

pub const SendBoundary = enum { none, marked, submitted };
pub const Session = struct {
    id: u32,
    nonce: []const u8,
    account: []const u8,
    client_id: []const u8,
    grant_id: []const u8,
    can_send: bool,
    can_modify: bool = false,
    can_contacts: bool = false,
    mailbox_submitted: bool = false,
    send_boundary: SendBoundary = .none,
    send_possible_submission: bool = false,
    temporary_allocator: ?std.mem.Allocator = null,
    pub fn capabilities(self: *const Session) []const []const u8 {
        return switch (@as(u3, @intFromBool(self.can_send)) | (@as(u3, @intFromBool(self.can_modify)) << 1) | (@as(u3, @intFromBool(self.can_contacts)) << 2)) {
            0 => &.{"mail-read"},
            1 => &.{ "mail-read", "mail-send" },
            2 => &.{ "mail-read", "mail-modify" },
            3 => &.{ "mail-read", "mail-send", "mail-modify" },
            4 => &.{ "mail-read", "contacts-read" },
            5 => &.{ "mail-read", "mail-send", "contacts-read" },
            6 => &.{ "mail-read", "mail-modify", "contacts-read" },
            7 => &.{ "mail-read", "mail-send", "mail-modify", "contacts-read" },
        };
    }
    pub fn transport(self: *Session) gmail.Transport {
        return .{ .context = self, .requestFn = request, .preparedRequestFn = requestPrepared, .temporary_allocator = self.temporary_allocator, .thread_limit = 30 };
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const encoded = if (body) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else "";
        return requestPrepared(ctx, a, method, url, encoded);
    }
    fn requestPrepared(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, encoded: []const u8) !j.Value {
        const self: *Session = @ptrCast(@alignCast(ctx));
        const people = std.mem.eql(u8, url, people_list_url) or std.mem.startsWith(u8, url, people_search_prefix);
        if (people) {
            if (method != .GET or !self.can_contacts) return error.PermissionDenied;
        } else if (!std.mem.startsWith(u8, url, "https://gmail.googleapis.com/gmail/v1/users/me/")) return error.InvalidHost;
        const sending = method == .POST and std.mem.eql(u8, url, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send");
        if (method != .GET and !(if (sending) self.can_send else self.can_modify and mailboxRequest(method, url))) return error.PermissionDenied;
        if (encoded.len > types.Limits.request_bytes) return error.RequestTooLarge;
        const method_name = @tagName(method);
        response_metadata = .{ 0, 0 };
        const result = http_request(self.id, @intFromPtr(method_name.ptr), method_name.len, @intFromPtr(url.ptr), url.len, @intFromPtr(encoded.ptr), encoded.len, @intFromPtr(&response_buffer), response_buffer.len, @intFromPtr(&response_metadata));
        const mutating = method != .GET;
        if (sending) {
            self.send_boundary = switch (result) {
                3, 4 => .none,
                5 => .marked,
                else => .submitted,
            };
            self.send_possible_submission = self.send_boundary == .submitted;
            if (result == 5) return error.SendCanceledBeforeSubmission;
        }
        // The host reports these only before initiating a provider request.
        if (result == 4) return if (sending) error.SendCanceledBeforeSubmission else error.Canceled;
        if (result == 3) return error.NotConnected;
        if (mutating and !sending) self.mailbox_submitted = true;
        if (result != 0) return if (mutating) error.UnknownOutcome else switch (result) {
            2 => error.ResponseTooLarge,
            3 => error.NotConnected,
            else => error.NetworkFailure,
        };
        if (response_metadata[0] > 599 or response_metadata[0] < 100 or response_metadata[1] > response_buffer.len) return if (mutating) error.UnknownOutcome else error.InvalidProviderResponse;
        return gmail.decodeResponse(a, method, url, @intCast(response_metadata[0]), response_buffer[0..response_metadata[1]]);
    }
    pub fn dispatch(self: *Session, a: std.mem.Allocator, cmd: []const u8, value: j.Value) !j.Value {
        self.mailbox_submitted = false;
        return gmail.dispatchAuthorized(io, a, self.account, self.capabilities(), self.transport(), cmd, value);
    }
    pub fn list(self: *Session, a: std.mem.Allocator, label: []const u8, query: []const u8) !j.Value {
        const request_value = try j.value(a, .{ .limit = @as(u32, 30), .label = label, .query = query });
        return gmail.listAuthorized(io, a, self.account, self.capabilities(), self.transport(), request_value);
    }
    pub fn read(self: *Session, a: std.mem.Allocator, id: []const u8) !types.Message {
        return gmail.readAuthorizedMessage(a, self.account, self.capabilities(), self.transport(), id);
    }
    pub fn raw(self: *Session, a: std.mem.Allocator, id: []const u8) ![]const u8 {
        return gmail.readAuthorizedRawMessage(a, self.account, self.capabilities(), self.transport(), id);
    }
    pub fn aliases(self: *Session, a: std.mem.Allocator) ![]const []const u8 {
        const value = try gmail.dispatchAuthorized(io, a, self.account, self.capabilities(), self.transport(), "accounts.aliases", j.object(a));
        return j.decode([]const []const u8, a, j.get(value, "aliases") orelse return error.InvalidProviderResponse);
    }
    pub fn attachmentSource(self: *Session) @import("terminal/conversation_source.zig").Attachments {
        return .{ .context = self, .fetchFn = fetchAttachment, .max_bytes = types.Limits.body_bytes };
    }
    fn fetchAttachment(ctx: *anyopaque, a: std.mem.Allocator, message: types.Message, expected: types.Attachment) !types.Attachment {
        const self: *Session = @ptrCast(@alignCast(ctx));
        return gmail.attachmentAuthorized(a, self.account, self.capabilities(), self.transport(), message.id, expected);
    }
    /// One bounded native-shaped People page, normalized with the same decoder
    /// as the native client. Contacts stay read-only in the browser adapter.
    pub fn contacts(self: *Session, a: std.mem.Allocator, query: []const u8) !j.Value {
        if (!self.can_contacts) return error.PermissionDenied;
        if (query.len > 4096) return error.QueryTooLarge;
        var url_buffer: [3 * 4096 + 256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&url_buffer);
        const search = query.len > 0;
        const temporary = self.temporary_allocator orelse a;
        if (search) {
            var warmup: std.heap.ArenaAllocator = .init(temporary);
            defer warmup.deinit();
            _ = try request(self, warmup.allocator(), .GET, people_search_prefix, null);
            try writer.writeAll(people_search_prefix);
            try @import("oauth.zig").percent(&writer, query);
        }
        var scope: std.heap.ArenaAllocator = .init(temporary);
        defer scope.deinit();
        const value = try request(self, scope.allocator(), .GET, if (search) writer.buffered() else people_list_url, null);
        const page = try @import("terminal/contact_record.zig").readPage(scope.allocator(), temporary, value, .{ .search = search, .limit = contacts_limit, .retain_provider = false });
        return j.value(a, .{ .contacts = page.contacts, .hasMore = page.nextCursor != null, .partial = page.partial, .contactWarnings = page.contactWarnings });
    }
    pub fn prepareSend(self: *Session, a: std.mem.Allocator, draft: types.Draft, operation_id: []const u8) !gmail.PreparedSend {
        const clock = now_ms();
        if (!std.math.isFinite(clock) or clock <= 0 or clock >= 253402300800000) return error.InvalidDate;
        return gmail.prepareDraftAuthorized(io, a, self.account, self.capabilities(), self.transport(), draft, operation_id);
    }
    pub fn submitPrepared(self: *Session, a: std.mem.Allocator, prepared: gmail.PreparedSend) !j.Value {
        self.send_boundary = .none;
        self.send_possible_submission = false;
        return gmail.sendPrepared(a, self.transport(), prepared);
    }
};
const Connect = struct {
    session: u32,
    nonce: []const u8,
    account: []const u8,
    clientId: []const u8,
    grantId: ?[]const u8 = null,
    capabilities: []const []const u8,
    scopes: []const []const u8,
    actualScopes: []const []const u8,
};
fn has(scopes: []const []const u8, expected: []const u8) bool {
    for (scopes) |scope| if (std.mem.eql(u8, scope, expected)) return true;
    return false;
}
pub fn connect(a: std.mem.Allocator, bytes: []const u8) !Session {
    if (bytes.len > 16 * 1024) return error.InvalidCredentialMetadata;
    const value = try std.json.parseFromSliceLeaky(Connect, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = 1024 });
    if (value.nonce.len != 36) return error.InvalidSessionNonce;
    for (value.nonce, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidSessionNonce;
        } else if (!std.ascii.isHex(byte)) return error.InvalidSessionNonce;
    }
    try recipients.validateAddress(value.account);
    if (value.session == 0 or value.clientId.len > 256 or value.capabilities.len > 6 or value.scopes.len > 8 or value.actualScopes.len > 8) return error.InvalidCredentialMetadata;
    const expected = try auth.scopesFor(a, value.capabilities);
    if (expected.len != value.scopes.len) return error.InvalidGrantRegistry;
    for (expected, value.scopes) |left, right| if (!std.mem.eql(u8, left, right)) return error.InvalidGrantRegistry;
    if (value.grantId) |grant_id| {
        if (!std.mem.endsWith(u8, value.clientId, ".apps.googleusercontent.com") or !std.mem.eql(u8, grant_id, &auth.grantIdentity(value.scopes))) return error.InvalidGrantRegistry;
    } else if (value.capabilities.len != 1 or !has(value.capabilities, "mail-read")) return error.PermissionDenied;
    const read_granted = has(value.actualScopes, readonly_scope) or has(value.actualScopes, modify_scope) or has(value.actualScopes, full_scope);
    const send_granted = has(value.actualScopes, send_scope) or has(value.actualScopes, modify_scope) or has(value.actualScopes, full_scope);
    const modify_granted = has(value.actualScopes, modify_scope) or has(value.actualScopes, full_scope);
    const contacts_granted = has(value.actualScopes, contacts_read_scope) or has(value.actualScopes, contacts_write_scope);
    if (!read_granted) return error.PermissionDenied;
    var session: Session = .{ .id = value.session, .nonce = value.nonce, .account = value.account, .client_id = value.clientId, .grant_id = value.grantId orelse "", .can_send = has(value.capabilities, "mail-send") and send_granted, .can_modify = has(value.capabilities, "mail-modify") and modify_granted, .can_contacts = (has(value.capabilities, "contacts-read") or has(value.capabilities, "contacts-write")) and contacts_granted };
    const profile = try session.transport().requestFn(&session, a, .GET, "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress", null);
    if (!std.ascii.eqlIgnoreCase(j.text(profile, "emailAddress"), value.account)) return error.WrongAccount;
    return session;
}
