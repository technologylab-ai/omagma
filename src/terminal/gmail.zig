const std = @import("std");
const b = @import("../bounded.zig");
const http = @import("../http_client.zig");
const oauth = @import("../oauth.zig");
const keyring = @import("../keyring.zig");
const Config = @import("../config.zig").Config;
const auth = @import("auth.zig");
const types = @import("types.zig");
const j = @import("json.zig");
const mime = @import("mime.zig");
const recipients = @import("recipients.zig");
const invitation = @import("invitation.zig");

/// Tests inject this transport and fictional identity/capabilities. Production
/// execute constructs it only after token and Gmail account verification.
pub const Transport = struct {
    context: *anyopaque,
    requestFn: *const fn (*anyopaque, std.mem.Allocator, std.http.Method, []const u8, ?j.Value) anyerror!j.Value,
    progress_sink: ?types.ProgressSink = null,
    fn request(self: Transport, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        return try self.requestFn(self.context, a, method, url, body);
    }
    fn progress(self: Transport, phase: types.FetchPhase, completed: usize, total: usize) void {
        if (self.progress_sink) |sink| sink.report(.{ .phase = phase, .completed = completed, .total = total });
    }
    fn row(self: Transport, update: types.FetchRow) void {
        if (self.progress_sink) |sink| sink.row(update);
    }
};
const Network = struct {
    client: *http.Client,
    access: []const u8,
    access_storage: []u8,
    desktop: *const oauth.DesktopClient,
    refresh_token: []const u8,
    scopes: []const []const u8,
    refreshed_401: bool = false,
    response: []u8,
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *Network = @ptrCast(@alignCast(ctx));
        const json_body = if (body) |v| try std.json.Stringify.valueAlloc(a, v, .{}) else null;
        const mutating = method == .POST or method == .PATCH;
        var response = self.client.requestTerminal(url, method, self.access, json_body, self.response) catch |err| {
            if (mutating and !localRequestError(err)) return error.UnknownOutcome;
            return err;
        };
        if (response.status == 401 and !self.refreshed_401) {
            self.refreshed_401 = true;
            const token = oauth.refreshScoped(self.client.io, self.client, self.desktop, self.refresh_token, self.access_storage, self.scopes) catch |err| switch (err) {
                error.InvalidGrant, error.OutOfMemory, error.Canceled, error.Timeout => return err,
                else => return error.TokenRefreshFailed,
            };
            self.access = token.access_token;
            response = self.client.requestTerminal(url, method, self.access, json_body, self.response) catch |err| {
                if (mutating and !localRequestError(err)) return error.UnknownOutcome;
                return err;
            };
        }
        switch (response.status) {
            200...299 => {},
            400 => {
                if (method == .PATCH and std.mem.indexOf(u8, url, ":updateContact?") != null and contactPrecondition(a, response.body)) return error.ContactConflict;
                return error.ProviderRejected;
            },
            401 => return error.NotConnected,
            403 => return error.PermissionDenied,
            404 => return error.MessageNotFound,
            409, 412 => return error.ContactConflict,
            429 => return error.RateLimited,
            500...599 => if (mutating) return error.UnknownOutcome else return error.TransientFailure,
            else => return error.ProviderRejected,
        }
        if (response.body.len == 0) return if (mutating) error.UnknownOutcome else .null;
        b.preflight(response.body) catch |err| return if (mutating) error.UnknownOutcome else err;
        return std.json.parseFromSliceLeaky(j.Value, a, response.body, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = types.Limits.request_bytes }) catch |err| return if (mutating) error.UnknownOutcome else err;
    }
};
fn localRequestError(err: anyerror) bool {
    return err == error.FormTooLarge or err == error.InvalidToken or err == error.InvalidUrl or err == error.InvalidHost or err == error.InsecureUrl or err == error.UrlTooLarge or err == error.ResponseBufferTooLarge;
}
fn contactPrecondition(a: std.mem.Allocator, bytes: []const u8) bool {
    b.preflight(bytes) catch return false;
    const value = std.json.parseFromSliceLeaky(j.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = types.Limits.request_bytes }) catch return false;
    const detail = j.get(value, "error") orelse return false;
    if (std.mem.eql(u8, j.text(detail, "status"), "FAILED_PRECONDITION")) return true;
    const errors = array(detail, "errors") catch return false;
    for (errors) |item| if (std.mem.eql(u8, j.text(item, "reason"), "failedPrecondition")) return true;
    return false;
}

/// One bounded refresh owns one credential/client lifetime. Callers may reset
/// independent per-message arenas after committing each response; transport and
/// token buffers remain owned here until close joins every outstanding request.
pub const NetworkSession = struct {
    io: std.Io,
    client: http.Client,
    desktop: oauth.DesktopClient,
    refresh: []u8,
    access: []u8,
    response: []u8,
    token: []const u8,
    refresh_token: []const u8,
    scopes: []const []const u8,
    capabilities: []const []const u8,
    network: Network = undefined,
    initialized: bool = false,
    pub fn init(self: *NetworkSession, io: std.Io, a: std.mem.Allocator, config: *const Config, account: []const u8, cmd: []const u8, request: j.Value) !void {
        const index = config.index(account) orelse return error.UnknownAccount;
        if (!config.accounts[index].enabled) return error.AccountDisabled;
        try b.address(account);
        var registry: auth.Registry = .{};
        const bar_only = try j.boolean(request, "barGrantOnly", false) or try j.boolean(request, "auto", false);
        if (!bar_only) if (j.get(request, "grantFile")) |path| {
            registry = try auth.load(io, a, try j.string(path));
        };
        const grant = auth.find(&registry, account);
        const capability = requiredCapability(cmd) orelse return error.UnsupportedCommand;
        if (grant) |g| {
            if (!g.permits(capability)) return error.PermissionDenied;
        } else if (!std.mem.eql(u8, capability, "mail-read")) return error.PermissionDenied;
        const client_file = if (grant) |g| g.clientFile else config.client_file.slice();
        if (client_file.len == 0) return error.OAuthClientRequired;
        self.desktop = .{};
        errdefer self.desktop.wipe();
        try oauth.loadDesktop(io, client_file, &self.desktop);
        if (grant) |g| if (!std.mem.eql(u8, self.desktop.client_id.slice(), g.clientId)) return error.GrantClientMismatch;
        const refresh = try a.alloc(u8, 4096);
        errdefer std.crypto.secureZero(u8, refresh);
        const access = try a.alloc(u8, 4096);
        errdefer std.crypto.secureZero(u8, access);
        const refresh_token = if (grant) |g| (try keyring.lookupTerminal(io, account, g.clientId, g.grantId, refresh)) orelse return error.NotConnected else (if (bar_only) try keyring.lookupAutomatic(io, account, refresh) else try keyring.lookup(io, account, refresh)) orelse return error.NotConnected;
        self.client = try http.Client.init(io);
        errdefer self.client.deinit();
        const scopes: []const []const u8 = if (grant) |g| g.scopes else &.{oauth.readonly_scope};
        const tokens = try oauth.refreshScoped(io, &self.client, &self.desktop, refresh_token, access, scopes);
        const response = try a.alloc(u8, types.Limits.request_bytes);
        errdefer std.crypto.secureZero(u8, response);
        const profile_response = try self.client.requestTerminal("https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress", .GET, tokens.access_token, null, response);
        try oauth.verifyProfile(profile_response.status, profile_response.body, account);
        // The initialized HTTP client must never be copied: its inner allocator
        // borrows the workspace in this caller-stable storage.
        self.io = io;
        self.refresh = refresh;
        self.access = access;
        self.response = response;
        self.token = tokens.access_token;
        self.refresh_token = refresh_token;
        self.scopes = scopes;
        self.capabilities = if (grant) |g| g.capabilities else &.{"mail-read"};
        self.initialized = false;
    }
    pub fn transport(self: *NetworkSession) Transport {
        if (!self.initialized) {
            self.network = .{ .client = &self.client, .access = self.token, .access_storage = self.access, .desktop = &self.desktop, .refresh_token = self.refresh_token, .scopes = self.scopes, .response = self.response };
            self.initialized = true;
        }
        return .{ .context = &self.network, .requestFn = Network.request };
    }
    pub fn close(self: *NetworkSession) void {
        self.client.deinit();
        self.desktop.wipe();
        std.crypto.secureZero(u8, self.refresh);
        std.crypto.secureZero(u8, self.access);
        std.crypto.secureZero(u8, self.response);
    }
};
pub fn execute(io: std.Io, a: std.mem.Allocator, config: *const Config, account: []const u8, cmd: []const u8, request: j.Value) !j.Value {
    return executeProgress(io, a, config, account, cmd, request, null);
}
pub fn executeProgress(io: std.Io, a: std.mem.Allocator, config: *const Config, account: []const u8, cmd: []const u8, request: j.Value, progress_sink: ?types.ProgressSink) !j.Value {
    var session: NetworkSession = undefined;
    try session.init(io, a, config, account, cmd, request);
    defer session.close();
    var transport = session.transport();
    transport.progress_sink = progress_sink;
    return try dispatchAuthorized(io, a, account, session.capabilities, transport, cmd, request);
}

/// The cached attachment is an authoritative positional argument from core's
/// account-scoped message read, never a caller-supplied JSON request field.
pub fn executeAttachment(io: std.Io, a: std.mem.Allocator, config: *const Config, account: []const u8, request: j.Value, attachment: types.Attachment, progress_sink: ?types.ProgressSink) !types.Attachment {
    var session: NetworkSession = undefined;
    try session.init(io, a, config, account, "mail.attachment", request);
    defer session.close();
    var transport = session.transport();
    transport.progress_sink = progress_sink;
    return attachmentAuthorized(a, account, session.capabilities, transport, try j.required(request, "messageId"), attachment);
}

/// Gmail may rotate opaque attachment IDs between FULL reads of an immutable
/// message. Download the known token first; refreshing the message before that
/// GET would discard the only identity the caller actually selected.
pub fn attachmentAuthorized(a: std.mem.Allocator, account: []const u8, capabilities: []const []const u8, transport: Transport, message_id: []const u8, expected: types.Attachment) !types.Attachment {
    try recipients.validateAddress(account);
    if (!permits(capabilities, "mail-read")) return error.PermissionDenied;
    try mime.validateAttachment(expected.filename, expected.mimeType);
    if (expected.id.len == 0 or expected.id.len > 1024) return error.InvalidAttachmentId;
    if (expected.size > types.Limits.body_bytes) return error.BodyTooLarge;
    try b.identifier(message_id);
    if (expected.data.len > 0 or expected.size == 0) return expected;
    return downloadAttachment(a, transport, message_id, expected) catch |err| switch (err) {
        // Only an unavailable/invalid token warrants one fresh metadata read.
        // Auth, network, decoding and byte-count failures stay explicit.
        error.MessageNotFound, error.ProviderRejected => {
            const fresh = try read(a, transport, message_id);
            var resolved: ?types.Attachment = null;
            for (fresh.attachments) |candidate| {
                if (!std.mem.eql(u8, candidate.filename, expected.filename) or
                    !std.mem.eql(u8, candidate.mimeType, expected.mimeType) or candidate.size != expected.size) continue;
                if (resolved != null) return error.AmbiguousAttachment;
                resolved = candidate;
            }
            const selected = resolved orelse return error.AttachmentNotFound;
            if (selected.data.len > 0 or selected.size == 0) return selected;
            return downloadAttachment(a, transport, message_id, selected);
        },
        else => return err,
    };
}
fn downloadAttachment(a: std.mem.Allocator, transport: Transport, message_id: []const u8, attachment: types.Attachment) !types.Attachment {
    const value = try transport.request(a, .GET, try std.fmt.allocPrint(a, "{s}/attachments/{s}", .{ try messageUrl(a, message_id, ""), try escaped(a, attachment.id) }), null);
    const data = try j.required(value, "data");
    const decoded = try mime.decodeBase64Url(data, a);
    if (decoded.len != attachment.size) return error.BodySizeMismatch;
    // Gmail permits padded base64url. Every outgoing/shared Attachment DTO uses
    // the existing no-padding contract, including forward draft validation.
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(decoded.len));
    var result = attachment;
    result.data = std.base64.url_safe_no_pad.Encoder.encode(encoded, decoded);
    return result;
}

fn requiredCapability(cmd: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cmd, "mail.send") or std.mem.eql(u8, cmd, "draft.send")) return "mail-send";
    if (std.mem.eql(u8, cmd, "invitation.reply")) return "calendar-rsvp";
    if (std.mem.eql(u8, cmd, "contacts.upsert")) return "contacts-write";
    if (std.mem.eql(u8, cmd, "contacts.list") or std.mem.eql(u8, cmd, "contacts.search")) return "contacts-read";
    if (std.mem.eql(u8, cmd, "mail.modify-labels") or std.mem.eql(u8, cmd, "mail.archive") or std.mem.eql(u8, cmd, "mail.trash") or std.mem.eql(u8, cmd, "mail.restore") or std.mem.eql(u8, cmd, "mail.mark")) return "mail-modify";
    if (std.mem.eql(u8, cmd, "labels.list") or std.mem.eql(u8, cmd, "mail.labels") or std.mem.eql(u8, cmd, "accounts.identities")) return "mail-read";
    if (std.mem.eql(u8, cmd, "mail.refresh") or std.mem.eql(u8, cmd, "mail.read") or std.mem.eql(u8, cmd, "mail.thread") or std.mem.eql(u8, cmd, "mail.list") or std.mem.eql(u8, cmd, "mail.search") or std.mem.eql(u8, cmd, "mail.sync") or std.mem.eql(u8, cmd, "mail.attachment") or std.mem.eql(u8, cmd, "accounts.aliases")) return "mail-read";
    return null;
}
fn permits(capabilities: []const []const u8, name: []const u8) bool {
    for (capabilities) |capability| if (std.mem.eql(u8, capability, name)) return true;
    return false;
}
fn escaped(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len > 4096) return error.InvalidQuery;
    const bytes = try a.alloc(u8, text.len * 3);
    var writer = std.Io.Writer.fixed(bytes);
    try oauth.percent(&writer, text);
    return writer.buffered();
}
fn messageUrl(a: std.mem.Allocator, id: []const u8, suffix: []const u8) ![]const u8 {
    try b.identifier(id);
    return try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/messages/{s}{s}", .{ id, suffix });
}
fn array(value: j.Value, key: []const u8) ![]j.Value {
    const field = j.get(value, key) orelse return &.{};
    if (field != .array) return error.InvalidProviderResponse;
    return field.array.items;
}
const LabelResolver = struct {
    a: std.mem.Allocator,
    transport: Transport,
    entries: ?[]j.Value = null,
    fn resolve(self: *LabelResolver, text: []const u8) ![]const u8 {
        try recipients.validateHeader(text);
        if (text.len == 0 or text.len > 256) return error.InvalidLabel;
        for ([_][]const u8{ "INBOX", "SPAM", "TRASH", "UNREAD", "STARRED", "IMPORTANT", "SENT", "DRAFT", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS" }) |system| if (std.ascii.eqlIgnoreCase(text, system)) return system;
        if (self.entries == null) {
            const value = try self.transport.request(self.a, .GET, "https://gmail.googleapis.com/gmail/v1/users/me/labels?fields=labels(id,name,type)", null);
            self.entries = try array(value, "labels");
            if (self.entries.?.len > 10000) return error.TooManyLabels;
        }
        var found: ?[]const u8 = null;
        for (self.entries.?) |entry| {
            const id = try j.required(entry, "id");
            const name = try j.required(entry, "name");
            try b.identifier(id);
            if (std.mem.eql(u8, text, id) or std.mem.eql(u8, text, name)) {
                if (found) |previous| if (!std.mem.eql(u8, previous, id)) return error.AmbiguousLabel;
                found = id;
            }
        }
        return found orelse error.LabelNotFound;
    }
};
const ExternalBodiesBudget = struct { parts: usize = 0, bytes: usize = 0 };
fn externalBodies(a: std.mem.Allocator, transport: Transport, id: []const u8, payload: j.Value, map: *std.json.ObjectMap, depth: usize, budget: *ExternalBodiesBudget) anyerror!void {
    if (depth > mime.max_depth) return error.MimeTooDeep;
    budget.parts += 1;
    if (budget.parts > mime.max_parts) return error.TooManyMimeParts;
    const body = j.get(payload, "body");
    const mime_type = j.text(payload, "mimeType");
    if (body) |value| {
        const attachment = j.text(value, "attachmentId");
        const filename = j.text(payload, "filename");
        const calendar = mime.isCalendarPart(mime_type, filename);
        const inline_text = filename.len == 0 and (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "text/html"));
        if (attachment.len > 0 and (calendar or inline_text)) {
            if (attachment.len > 1024) return error.InvalidAttachmentId;
            const declared = if (j.get(value, "size")) |size| try b.integer(size) else 0;
            if (declared < 0 or declared > mime.max_body_bytes) return error.BodyTooLarge;
            if (calendar and declared > mime.max_calendar_bytes) return error.CalendarTooLarge;
            const declared_bytes: usize = @intCast(declared);
            if (!map.contains(attachment)) {
                if (declared_bytes > mime.max_raw_bytes - budget.bytes) return error.DecodedMessageTooLarge;
                const url = try std.fmt.allocPrint(a, "{s}/attachments/{s}", .{ try messageUrl(a, id, ""), try escaped(a, attachment) });
                const response = try transport.request(a, .GET, url, null);
                const encoded = try j.required(response, "data");
                const decoded = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(std.mem.trimEnd(u8, encoded, "=")) catch return error.InvalidBase64;
                if (decoded > mime.max_body_bytes) return error.BodyTooLarge;
                if (calendar and decoded > mime.max_calendar_bytes) return error.CalendarTooLarge;
                if (decoded > mime.max_raw_bytes - budget.bytes) return error.DecodedMessageTooLarge;
                budget.bytes += decoded;
                try map.put(a, attachment, response);
            }
        }
    }
    for (try array(payload, "parts")) |part| try externalBodies(a, transport, id, part, map, depth + 1, budget);
}
fn read(a: std.mem.Allocator, transport: Transport, id: []const u8) !types.Message {
    const value = try transport.request(a, .GET, try messageUrl(a, id, "?format=full"), null);
    if (!std.mem.eql(u8, j.text(value, "id"), id)) return error.MessageIdentityMismatch;
    var map: std.json.ObjectMap = .empty;
    var budget: ExternalBodiesBudget = .{};
    try externalBodies(a, transport, id, j.get(value, "payload") orelse return error.InvalidProviderResponse, &map, 0, &budget);
    return @import("gmail_decode.zig").normalize(value, a, .{ .object = map }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.MissingField, error.InvalidEncoding, error.UnsupportedEncoding, error.InvalidIdentifier => return error.MalformedMessage,
        else => return err,
    };
}
/// Internal typed read for bounded cache prefetch. Authorization and provider
/// identity checks match dispatchAuthorized, while large body strings avoid a
/// Message -> JSON Value -> Message round-trip in the caller's message arena.
pub fn readAuthorizedMessage(a: std.mem.Allocator, account: []const u8, capabilities: []const []const u8, transport: Transport, id: []const u8) !types.Message {
    try recipients.validateAddress(account);
    if (!permits(capabilities, "mail-read")) return error.PermissionDenied;
    return try read(a, transport, id);
}
fn aliases(a: std.mem.Allocator, transport: Transport) ![]const []const u8 {
    const entries = try identities(a, transport);
    const out = try a.alloc([]const u8, entries.len);
    for (entries, out) |identity, *address| address.* = identity.address;
    return out;
}
fn identities(a: std.mem.Allocator, transport: Transport) ![]const @import("store.zig").Identity {
    // users.settings.sendAs.list accepts the existing readonly/modify scope.
    // Its HTML signature is converted to bounded literal plaintext.
    const value = try transport.request(a, .GET, "https://gmail.googleapis.com/gmail/v1/users/me/settings/sendAs?fields=sendAs(sendAsEmail,displayName,signature,isPrimary,isDefault,verificationStatus)", null);
    const entries = try array(value, "sendAs");
    if (entries.len > 32) return error.TooManyAliases;
    var out: std.ArrayList(@import("store.zig").Identity) = .empty;
    for (entries) |entry| {
        const address = try j.required(entry, "sendAsEmail");
        try recipients.validateAddress(address);
        const name = j.text(entry, "displayName");
        const signature = j.text(entry, "signature");
        if (name.len > 256 or signature.len > 8192) return error.IdentityTooLarge;
        if (std.mem.eql(u8, j.text(entry, "verificationStatus"), "accepted") or try j.boolean(entry, "isPrimary", false)) try out.append(a, .{ .address = address, .name = try mime.sanitizeText(name, a), .signature = try mime.htmlToText(signature, a), .isDefault = try j.boolean(entry, "isDefault", false) });
    }
    return try out.toOwnedSlice(a);
}
fn appendAddresses(list: *recipients.List, addresses: []const types.Address) !void {
    if (addresses.len > 32) return error.TooManyRecipients;
    for (addresses) |address| {
        var mailbox: recipients.Mailbox = .{};
        try mailbox.address.set(address.address);
        try mailbox.name.set(address.name);
        try list.append(mailbox);
    }
}
fn date(io: std.Io, a: std.mem.Allocator, calendar: bool) ![]const u8 {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    if (now < 0) return error.InvalidDate;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now) };
    const day = seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    if (calendar) return try std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ year_day.year, @backingInt(month_day.month), month_day.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return try std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{ weekdays[(day.day + 4) % 7], month_day.day_index + 1, months[@backingInt(month_day.month) - 1], year_day.year, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}
fn send(io: std.Io, a: std.mem.Allocator, account: []const u8, transport: Transport, request: j.Value, draft: types.Draft, calendar: ?[]const u8, sender: ?[]const u8) !j.Value {
    const operation = try j.required(request, "operationId");
    if (operation.len > 256) return error.InvalidOperationId;
    try recipients.validateHeader(operation);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(account);
    hasher.update("\x00");
    hasher.update(operation);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const key = std.fmt.bytesToHex(digest, .lower);
    const rfc_id = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{key});
    var envelope: recipients.Envelope = .{};
    try appendAddresses(&envelope.to, draft.to);
    try appendAddresses(&envelope.cc, draft.cc);
    try appendAddresses(&envelope.bcc, draft.bcc);
    var from: recipients.Mailbox = .{};
    const chosen = if (draft.from) |identity| identity.address else account;
    if (draft.from) |identity| {
        try recipients.validateAddress(identity.address);
        try recipients.validateHeader(identity.name);
        if (!std.ascii.eqlIgnoreCase(chosen, account)) {
            var verified = false;
            for (try aliases(a, transport)) |alias| verified = verified or std.ascii.eqlIgnoreCase(chosen, alias);
            if (!verified) return error.UnverifiedSender;
        }
        try from.name.set(identity.name);
    }
    try from.address.set(sender orelse chosen);
    if (draft.threadId.len > 0) {
        try b.identifier(draft.threadId);
        if (!mime.validMessageId(draft.inReplyTo)) return error.MissingMessageId;
    }
    const bytes = try a.alloc(u8, types.Limits.request_bytes);
    const attachments = try mime.composeAttachments(draft.attachments, a);
    const prepared = try @import("markdown_mail.zig").prepare(a, draft);
    const raw = try mime.encode(.{ .from = from, .envelope = &envelope, .subject = draft.subject, .body = prepared.plain, .html = prepared.html, .inline_logo = prepared.html != null, .calendar = calendar, .message_id = rfc_id, .date = try date(io, a, false), .in_reply_to = draft.inReplyTo, .references = draft.references, .attachments = attachments }, bytes);
    const encoded_size = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    if (encoded_size > types.Limits.request_bytes - 1024) return error.FormTooLarge;
    const encoded = try a.alloc(u8, encoded_size);
    const body = try j.value(a, .{ .raw = try mime.base64Url(raw, encoded), .threadId = if (draft.threadId.len > 0) draft.threadId else @as(?[]const u8, null) });
    const value = transport.request(a, .POST, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", body) catch |err| {
        if (err == error.UnknownOutcome) return j.value(a, .{ .outcome = "unknown", .rfcMessageId = rfc_id, .errorCode = @errorName(err) });
        return err;
    };
    const id = j.required(value, "id") catch return j.value(a, .{ .outcome = "unknown", .rfcMessageId = rfc_id, .errorCode = "InvalidProviderReceipt" });
    b.identifier(id) catch return j.value(a, .{ .outcome = "unknown", .rfcMessageId = rfc_id, .errorCode = "InvalidProviderReceipt" });
    return j.value(a, .{ .outcome = "applied", .messageId = id, .threadId = j.text(value, "threadId"), .rfcMessageId = rfc_id }) catch return error.UnknownOutcome;
}

pub const RefreshPlan = struct {
    historyId: []const u8,
    messages: []const types.Message = &.{},
    labels: []const LabelUpdate = &.{},
    deleted: []const []const u8 = &.{},
    /// Typed messagesAdded IDs, distinct from labels/scoped-view metadata.
    /// Preserved even when replay finds their intermediate metadata cached.
    added: []const []const u8 = &.{},
    resync: bool = false,
    nextCursor: []const u8 = "",
    labelId: []const u8 = "",
    metadataGets: usize = 0,
    listCalls: usize = 0,
    historyPages: usize = 0,
    viewFetched: bool = false,
    viewIds: []const []const u8 = &.{},
    /// Only authoritatively projected IDs may survive a missing/expired history
    /// checkpoint. Requested query membership is separate from account retention.
    retentionIds: []const []const u8 = &.{},
    pub fn inboxArrivals(self: RefreshPlan) usize {
        if (self.resync) return 0;
        var count: usize = 0;
        for (self.added, 0..) |id, index| {
            if (containsId(self.added[0..index], id) or containsId(self.deleted, id)) continue;
            for (self.messages) |message| {
                if (!std.mem.eql(u8, id, message.id)) continue;
                if (containsId(message.labels, "INBOX") and !containsId(message.labels, "SENT")) count += 1;
                break;
            }
        }
        return count;
    }
};
pub const LabelUpdate = struct { id: []const u8, labels: []const []const u8 };
fn historyId(value: []const u8) !void {
    if (value.len == 0 or value.len > 32) return error.InvalidHistoryId;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidHistoryId;
}
fn containsId(list: []const []const u8, id: []const u8) bool {
    for (list) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}
fn fetchMetadata(a: std.mem.Allocator, transport: Transport, id: []const u8) !types.Message {
    const got = try transport.request(a, .GET, try messageUrl(a, id, "?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To&fields=id,threadId,labelIds,internalDate,snippet,payload(mimeType,headers)"), null);
    if (!std.mem.eql(u8, j.text(got, "id"), id)) return error.MessageIdentityMismatch;
    return @import("gmail_decode.zig").normalize(got, a, null);
}
fn messageIds(a: std.mem.Allocator, messages: []const types.Message) ![]const []const u8 {
    const ids = try a.alloc([]const u8, messages.len);
    for (messages, ids) |message, *id| id.* = message.id;
    return ids;
}
fn fetchView(a: std.mem.Allocator, transport: Transport, request: j.Value) !j.Value {
    const limit = try j.integer(request, "limit", 32);
    if (limit < 1 or limit > 100) return error.InvalidPageLimit;
    const query = j.text(request, "query");
    var resolver: LabelResolver = .{ .a = a, .transport = transport };
    const input = j.text(request, "label");
    const label = if (input.len > 0) try resolver.resolve(input) else "";
    const include = std.ascii.eqlIgnoreCase(label, "TRASH") or std.ascii.eqlIgnoreCase(label, "SPAM") or std.mem.indexOf(u8, query, "in:trash") != null or std.mem.indexOf(u8, query, "in:spam") != null or std.mem.indexOf(u8, query, "in:anywhere") != null;
    var url = try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults={d}&includeSpamTrash={s}&fields=messages(id),nextPageToken", .{ limit, if (include) @as([]const u8, "true") else "false" });
    if (query.len > 0) url = try std.fmt.allocPrint(a, "{s}&q={s}", .{ url, try escaped(a, query) });
    if (label.len > 0) url = try std.fmt.allocPrint(a, "{s}&labelIds={s}", .{ url, try escaped(a, label) });
    const result = try transport.request(a, .GET, url, null);
    const entries = try array(result, "messages");
    if (entries.len > limit) return error.InvalidPage;
    const ids = try a.alloc([]const u8, entries.len);
    for (entries, ids) |entry, *id| {
        id.* = try j.required(entry, "id");
        try b.identifier(id.*);
    }
    return j.value(a, .{ .ids = ids, .nextCursor = j.text(result, "nextPageToken"), .labelId = label });
}
fn bootstrap(io: std.Io, a: std.mem.Allocator, account: []const u8, capabilities: []const []const u8, transport: Transport, request: j.Value, resync: bool) !j.Value {
    const profile = try transport.request(a, .GET, "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=historyId", null);
    const checkpoint = try j.required(profile, "historyId");
    try historyId(checkpoint);
    // Capture before BOTH global retention and scoped enumeration. A narrow
    // search/folder can never define the replacement for the whole account.
    var global_req = try j.copyObject(a, request);
    _ = global_req.object.swapRemove("cursor");
    try global_req.object.put(a, "query", .{ .string = "" });
    try global_req.object.put(a, "label", .{ .string = "" });
    try global_req.object.put(a, "includeSpamTrash", .{ .bool = true });
    const global = try dispatchAuthorized(io, a, account, capabilities, transport, "mail.list", global_req);
    const recent = try j.decode([]const types.Message, a, j.get(global, "messages") orelse return error.InvalidProviderResponse);
    var messages: std.ArrayList(types.Message) = .empty;
    try messages.appendSlice(a, recent);
    var view_ids = try messageIds(a, recent);
    var next = j.text(global, "nextCursor");
    var label_id: []const u8 = "";
    var list_calls: usize = 1;
    if (j.text(request, "query").len != 0 or j.text(request, "label").len != 0) {
        const view = try fetchView(a, transport, request);
        list_calls += 1;
        view_ids = try j.decode([]const []const u8, a, j.get(view, "ids") orelse return error.InvalidProviderResponse);
        next = j.text(view, "nextCursor");
        label_id = j.text(view, "labelId");
        var extra: std.ArrayList([]const u8) = .empty;
        for (view_ids) |id| {
            var projected = false;
            for (messages.items) |message| projected = projected or std.mem.eql(u8, id, message.id);
            // Keep the TOTAL metadata budget at 100. Scoped IDs outside this
            // authoritative union remain explicitly uncached/incomplete, rather
            // than retaining their old labels under an advanced checkpoint.
            if (!projected and !containsId(extra.items, id) and recent.len + extra.items.len < 100) try extra.append(a, id);
        }
        if (extra.items.len != 0) transport.progress(.metadata, recent.len, recent.len + extra.items.len);
        for (extra.items) |id| {
            try io.checkCancel();
            try messages.append(a, try fetchMetadata(a, transport, id));
            transport.progress(.metadata, messages.items.len, recent.len + extra.items.len);
        }
    }
    return j.value(a, RefreshPlan{ .historyId = checkpoint, .messages = messages.items, .resync = resync, .nextCursor = next, .labelId = label_id, .metadataGets = messages.items.len, .listCalls = list_calls, .viewFetched = true, .viewIds = view_ids, .retentionIds = try messageIds(a, messages.items) });
}

fn refreshPlan(io: std.Io, a: std.mem.Allocator, account: []const u8, capabilities: []const []const u8, transport: Transport, request: j.Value) !j.Value {
    const start = j.text(request, "historyId");
    if (start.len == 0) return bootstrap(io, a, account, capabilities, transport, request, true);
    try historyId(start);
    const known = if (j.get(request, "knownIds")) |v| try j.decode([]const []const u8, a, v) else &.{};
    if (known.len > types.Limits.metadata_hard) return error.SyncLimitExceeded;
    var changed: std.ArrayList([]const u8) = .empty;
    var added: std.ArrayList([]const u8) = .empty;
    var deleted: std.ArrayList([]const u8) = .empty;
    var cursor: []const u8 = "";
    var checkpoint: []const u8 = start;
    var events: usize = 0;
    var pages: usize = 0;
    while (true) {
        if (pages == 8) return bootstrap(io, a, account, capabilities, transport, request, true);
        pages += 1;
        var url = try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId={s}&maxResults=100&fields=history(id,messagesAdded(message(id)),messagesDeleted(message(id)),labelsAdded(message(id)),labelsRemoved(message(id))),nextPageToken,historyId", .{start});
        if (cursor.len > 0) url = try std.fmt.allocPrint(a, "{s}&pageToken={s}", .{ url, try escaped(a, cursor) });
        const page = transport.request(a, .GET, url, null) catch |err| {
            if (err == error.MessageNotFound) return bootstrap(io, a, account, capabilities, transport, request, true);
            return err;
        };
        checkpoint = try j.required(page, "historyId");
        try historyId(checkpoint);
        for (try array(page, "history")) |record| {
            for ([_][]const u8{ "messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved" }) |kind| for (try array(record, kind)) |event| {
                events += 1;
                if (events > 256) return bootstrap(io, a, account, capabilities, transport, request, true);
                const id = try j.required(j.get(event, "message") orelse return error.InvalidProviderResponse, "id");
                try b.identifier(id);
                if (std.mem.eql(u8, kind, "messagesDeleted")) {
                    if (!containsId(deleted.items, id)) try deleted.append(a, id);
                } else {
                    if (!containsId(changed.items, id)) try changed.append(a, id);
                    if (std.mem.eql(u8, kind, "messagesAdded") and !containsId(added.items, id)) try added.append(a, id);
                }
            };
        }
        cursor = j.text(page, "nextPageToken");
        if (cursor.len > 4096) return error.InvalidCursor;
        if (cursor.len == 0) break;
    }
    if (changed.items.len > 100) return bootstrap(io, a, account, capabilities, transport, request, true);
    var messages: std.ArrayList(types.Message) = .empty;
    var labels: std.ArrayList(LabelUpdate) = .empty;
    var total: usize = 0;
    for (changed.items) |id| if (!containsId(deleted.items, id)) {
        total += 1;
    };
    var completed: usize = 0;
    if (total != 0) transport.progress(.metadata, 0, total);
    for (changed.items) |id| {
        if (containsId(deleted.items, id)) continue;
        try io.checkCancel();
        if (containsId(known, id) and !containsId(added.items, id)) {
            const minimal = transport.request(a, .GET, try messageUrl(a, id, "?format=minimal&fields=id,labelIds"), null) catch |err| {
                if (err == error.MessageNotFound) {
                    if (!containsId(deleted.items, id)) try deleted.append(a, id);
                    completed += 1;
                    transport.progress(.metadata, completed, total);
                    continue;
                }
                return err;
            };
            if (!std.mem.eql(u8, j.text(minimal, "id"), id)) return error.MessageIdentityMismatch;
            const label_ids = if (j.get(minimal, "labelIds")) |value| try j.decode([]const []const u8, a, value) else &.{};
            if (label_ids.len > 64) return error.InvalidLabels;
            for (label_ids) |label| {
                try recipients.validateHeader(label);
                if (label.len > 256) return error.InvalidLabels;
            }
            try labels.append(a, .{ .id = id, .labels = label_ids });
        } else {
            const got = fetchMetadata(a, transport, id) catch |err| {
                if (err == error.MessageNotFound) {
                    if (!containsId(deleted.items, id)) try deleted.append(a, id);
                    completed += 1;
                    transport.progress(.metadata, completed, total);
                    continue;
                }
                return err;
            };
            try messages.append(a, got);
        }
        completed += 1;
        transport.progress(.metadata, completed, total);
    }
    var plan: RefreshPlan = .{ .historyId = checkpoint, .messages = messages.items, .labels = labels.items, .deleted = deleted.items, .added = added.items, .metadataGets = messages.items.len, .historyPages = pages };
    if (try j.boolean(request, "forceView", false) or (events != 0 and j.text(request, "query").len != 0)) {
        const view = try fetchView(a, transport, request);
        plan.viewIds = try j.decode([]const []const u8, a, j.get(view, "ids") orelse return error.InvalidProviderResponse);
        plan.viewFetched = true;
        plan.listCalls = 1;
        plan.nextCursor = j.text(view, "nextCursor");
        plan.labelId = j.text(view, "labelId");
        var extra: std.ArrayList([]const u8) = .empty;
        for (plan.viewIds) |id| {
            var found = containsId(known, id);
            for (messages.items) |message| found = found or std.mem.eql(u8, id, message.id);
            if (!found and !containsId(extra.items, id) and plan.metadataGets + extra.items.len < 100) try extra.append(a, id);
        }
        if (extra.items.len != 0) transport.progress(.metadata, completed, completed + extra.items.len);
        const expanded_total = completed + extra.items.len;
        for (extra.items) |id| {
            try io.checkCancel();
            try messages.append(a, try fetchMetadata(a, transport, id));
            plan.metadataGets += 1;
            completed += 1;
            transport.progress(.metadata, completed, expanded_total);
        }
        plan.messages = messages.items;
    }
    return j.value(a, plan);
}

pub fn dispatchAuthorized(io: std.Io, a: std.mem.Allocator, account: []const u8, capabilities: []const []const u8, transport: Transport, cmd: []const u8, request: j.Value) !j.Value {
    try recipients.validateAddress(account);
    const capability = requiredCapability(cmd) orelse return error.UnsupportedCommand;
    if (!permits(capabilities, capability)) return error.PermissionDenied;
    if (std.mem.eql(u8, cmd, "mail.refresh")) return refreshPlan(io, a, account, capabilities, transport, request);
    if (std.mem.eql(u8, cmd, "mail.read")) {
        transport.progress(.bodies, 0, 1);
        const message = try read(a, transport, try j.required(request, "messageId"));
        transport.row(.{ .kind = .body, .message = message });
        transport.progress(.bodies, 1, 1);
        return j.value(a, message);
    }
    if (std.mem.eql(u8, cmd, "accounts.aliases")) return j.value(a, .{ .aliases = try aliases(a, transport) });
    if (std.mem.eql(u8, cmd, "accounts.identities")) return j.value(a, .{ .identities = try identities(a, transport) });
    if (std.mem.eql(u8, cmd, "labels.list")) {
        const response = try transport.request(a, .GET, "https://gmail.googleapis.com/gmail/v1/users/me/labels?fields=labels(id,name,type)", null);
        const entries = try array(response, "labels");
        if (entries.len > 512) return error.TooManyLabels;
        const labels = try a.alloc(@import("store.zig").Label, entries.len);
        for (entries, labels) |entry, *label| {
            const id = try j.required(entry, "id");
            const name = try j.required(entry, "name");
            try b.identifier(id);
            if (name.len > 512) return error.InvalidLabel;
            label.* = .{ .id = id, .name = try mime.sanitizeText(name, a), .type = j.text(entry, "type") };
        }
        return j.value(a, .{ .labels = labels });
    }
    if (std.mem.eql(u8, cmd, "mail.labels") or std.mem.eql(u8, cmd, "mail.modify-labels")) {
        const id = try j.required(request, "messageId");
        const modifying = std.mem.eql(u8, cmd, "mail.modify-labels");
        var body: ?j.Value = null;
        if (modifying) {
            var resolver: LabelResolver = .{ .a = a, .transport = transport };
            var add: std.ArrayList([]const u8) = .empty;
            var remove: std.ArrayList([]const u8) = .empty;
            for ([_][]const u8{ "addLabels", "removeLabels" }, [_]*std.ArrayList([]const u8){ &add, &remove }) |key, list| {
                for (try array(request, key)) |value| try list.append(a, try resolver.resolve(try j.string(value)));
            }
            if (add.items.len + remove.items.len > 64) return error.TooManyLabels;
            body = try j.value(a, .{ .addLabelIds = add.items, .removeLabelIds = remove.items });
        }
        const value = try transport.request(a, if (modifying) .POST else .GET, try messageUrl(a, id, if (modifying) "/modify?fields=id,labelIds" else "?format=minimal&fields=id,labelIds"), body);
        if (!std.mem.eql(u8, j.text(value, "id"), id)) return if (modifying) error.UnknownOutcome else error.MessageIdentityMismatch;
        const labels = j.decode([]const []const u8, a, j.get(value, "labelIds") orelse return if (modifying) error.UnknownOutcome else error.InvalidProviderResponse) catch return if (modifying) error.UnknownOutcome else error.InvalidProviderResponse;
        if (labels.len > 64) return if (modifying) error.UnknownOutcome else error.TooManyLabels;
        for (labels) |label| if (label.len > 256) return if (modifying) error.UnknownOutcome else error.InvalidLabel;
        return j.value(a, .{ .messageId = id, .labels = labels });
    }
    if (std.mem.eql(u8, cmd, "mail.list") or std.mem.eql(u8, cmd, "mail.search") or std.mem.eql(u8, cmd, "mail.sync")) {
        const limit = try j.integer(request, "limit", 30);
        if (limit < 1 or limit > types.Limits.page) return error.InvalidPageLimit;
        const query = j.text(request, "query");
        var resolver: LabelResolver = .{ .a = a, .transport = transport };
        const label_input = j.text(request, "label");
        const label = if (label_input.len > 0) try resolver.resolve(label_input) else "";
        const include_spam_trash = try j.boolean(request, "includeSpamTrash", false) or std.ascii.eqlIgnoreCase(label, "TRASH") or std.ascii.eqlIgnoreCase(label, "SPAM") or std.mem.indexOf(u8, query, "in:trash") != null or std.mem.indexOf(u8, query, "in:spam") != null or std.mem.indexOf(u8, query, "in:anywhere") != null;
        var url = try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults={d}&includeSpamTrash={s}&fields=messages(id,threadId),nextPageToken", .{ limit, if (include_spam_trash) @as([]const u8, "true") else "false" });
        for ([_][]const u8{ "query", "label", "cursor" }, [_][]const u8{ "q", "labelIds", "pageToken" }) |key, parameter| {
            const value = if (std.mem.eql(u8, key, "label")) label else j.text(request, key);
            if (value.len != 0) url = try std.fmt.allocPrint(a, "{s}&{s}={s}", .{ url, parameter, try escaped(a, value) });
        }
        const listed = try transport.request(a, .GET, url, null);
        const entries = try array(listed, "messages");
        if (entries.len > limit) return error.InvalidPage;
        const messages = try a.alloc(types.Message, entries.len);
        transport.progress(.metadata, 0, entries.len);
        for (entries, messages, 0..) |entry, *dest, index| {
            try io.checkCancel();
            const id = try j.required(entry, "id");
            const got = try transport.request(a, .GET, try messageUrl(a, id, "?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To&fields=id,threadId,labelIds,internalDate,snippet,payload(mimeType,headers)"), null);
            if (!std.mem.eql(u8, j.text(got, "id"), id)) return error.MessageIdentityMismatch;
            dest.* = try @import("gmail_decode.zig").normalize(got, a, null);
            transport.row(.{ .kind = .page, .index = index, .total = entries.len, .message = dest.* });
            transport.progress(.metadata, index + 1, entries.len);
        }
        return j.value(a, .{ .messages = messages, .nextCursor = if (j.get(listed, "nextPageToken")) |v| try j.string(v) else @as(?[]const u8, null), .labelId = label });
    }
    if (std.mem.eql(u8, cmd, "mail.thread")) {
        const id = try j.required(request, "threadId");
        try b.identifier(id);
        const value = try transport.request(a, .GET, try std.fmt.allocPrint(a, "https://gmail.googleapis.com/gmail/v1/users/me/threads/{s}?format=full", .{id}), null);
        const entries = try array(value, "messages");
        if (entries.len > 100) return error.ThreadTooLarge;
        const messages = try a.alloc(types.Message, entries.len);
        transport.progress(.bodies, 0, entries.len);
        for (entries, messages, 0..) |entry, *dest, index| {
            try io.checkCancel();
            if (!std.mem.eql(u8, j.text(entry, "threadId"), id)) return error.MessageIdentityMismatch;
            var map: std.json.ObjectMap = .empty;
            var budget: ExternalBodiesBudget = .{};
            try externalBodies(a, transport, j.text(entry, "id"), j.get(entry, "payload") orelse return error.InvalidProviderResponse, &map, 0, &budget);
            dest.* = try @import("gmail_decode.zig").normalize(entry, a, .{ .object = map });
            transport.progress(.bodies, index + 1, entries.len);
        }
        std.sort.heap(types.Message, messages, {}, struct {
            fn lessThan(_: void, left: types.Message, right: types.Message) bool {
                return left.receivedAt < right.receivedAt or (left.receivedAt == right.receivedAt and std.mem.lessThan(u8, left.id, right.id));
            }
        }.lessThan);
        return j.value(a, .{ .messages = messages });
    }
    if (std.mem.eql(u8, cmd, "mail.attachment")) {
        const id = try j.required(request, "messageId");
        const attachment_id = try j.required(request, "attachmentId");
        const message = try read(a, transport, id);
        for (message.attachments) |attachment| if (std.mem.eql(u8, attachment.id, attachment_id)) {
            return j.value(a, try attachmentAuthorized(a, account, capabilities, transport, id, attachment));
        };
        return error.AttachmentNotFound;
    }
    if (std.mem.eql(u8, cmd, "mail.send") or std.mem.eql(u8, cmd, "draft.send")) {
        const draft = try j.decode(types.Draft, a, j.get(request, "draft") orelse return error.MissingField);
        if (j.get(request, "icalendar") != null or j.get(request, "preparedCalendar") != null) return error.InvalidInvitationCommand;
        return try send(io, a, account, transport, request, draft, null, null);
    }
    if (std.mem.eql(u8, cmd, "invitation.reply")) {
        if (j.get(request, "preparedCalendar")) |prepared| {
            const calendar = try j.string(prepared);
            const draft = try j.decode(types.Draft, a, j.get(request, "draft") orelse return error.MissingField);
            var reply: invitation.Invitation = .{};
            try invitation.parseReply(calendar, account, try aliases(a, transport), &reply);
            if (draft.to.len != 1 or draft.cc.len != 0 or draft.bcc.len != 0 or !std.ascii.eqlIgnoreCase(draft.to[0].address, reply.organizer.slice())) return error.InvalidInvitationRecipient;
            return try send(io, a, account, transport, request, draft, calendar, reply.attendee.slice());
        }
        const message = try read(a, transport, try j.required(request, "messageId"));
        var invite: invitation.Invitation = .{};
        try invitation.parse(message.invitation orelse return error.NotInvitation, account, try aliases(a, transport), &invite);
        const status = std.meta.stringToEnum(invitation.Status, try j.required(request, "status")) orelse return error.InvalidInvitationStatus;
        const ics = try invitation.reply(&invite, status, try date(io, a, true), try a.alloc(u8, invitation.max_calendar_bytes));
        return try send(io, a, account, transport, request, .{ .to = &.{.{ .address = invite.organizer.slice() }}, .subject = try std.fmt.allocPrint(a, "{s}: {s}", .{ @tagName(status), message.subject }), .bodyText = try std.fmt.allocPrint(a, "Invitation response: {s}", .{@tagName(status)}) }, ics, invite.attendee.slice());
    }
    if (std.mem.eql(u8, cmd, "contacts.list") or std.mem.eql(u8, cmd, "contacts.search") or std.mem.eql(u8, cmd, "contacts.upsert")) return try contacts(a, transport, cmd, request);
    const id = try j.required(request, "messageId");
    if (std.mem.eql(u8, cmd, "mail.trash") or std.mem.eql(u8, cmd, "mail.restore")) {
        _ = try transport.request(a, .POST, try messageUrl(a, id, if (std.mem.eql(u8, cmd, "mail.trash")) "/trash" else "/untrash"), null);
        if (std.mem.eql(u8, cmd, "mail.restore")) _ = transport.request(a, .POST, try messageUrl(a, id, "/modify"), try j.value(a, .{ .addLabelIds = [_][]const u8{"INBOX"} })) catch return error.UnknownOutcome;
    } else {
        var add: std.ArrayList([]const u8) = .empty;
        var remove: std.ArrayList([]const u8) = .empty;
        if (std.mem.eql(u8, cmd, "mail.archive")) try remove.append(a, "INBOX");
        for ([_][]const u8{ "unread", "starred" }, [_][]const u8{ "UNREAD", "STARRED" }) |key, label| if (j.get(request, key) != null) {
            if (try j.boolean(request, key, false)) try add.append(a, label) else try remove.append(a, label);
        };
        var resolver: LabelResolver = .{ .a = a, .transport = transport };
        const requested_add = try array(request, "addLabels");
        const requested_remove = try array(request, "removeLabels");
        if (requested_add.len + requested_remove.len + add.items.len + remove.items.len > 64) return error.TooManyLabels;
        for (requested_add) |label| {
            const text = try j.string(label);
            try add.append(a, try resolver.resolve(text));
        }
        for (requested_remove) |label| {
            const text = try j.string(label);
            try remove.append(a, try resolver.resolve(text));
        }
        if (add.items.len + remove.items.len > 64) return error.TooManyLabels;
        _ = try transport.request(a, .POST, try messageUrl(a, id, "/modify"), try j.value(a, .{ .addLabelIds = add.items, .removeLabelIds = remove.items }));
    }
    const updated = read(a, transport, id) catch return error.UnknownOutcome;
    return j.value(a, updated) catch return error.UnknownOutcome;
}

fn contact(a: std.mem.Allocator, value: j.Value) !types.Contact {
    const name_entries = try array(value, "names");
    const email_entries = try array(value, "emailAddresses");
    if (name_entries.len > 32 or email_entries.len > 32) return error.ContactTooLarge;
    const emails = try a.alloc(types.Address, email_entries.len);
    for (email_entries, emails) |entry, *dest| {
        const address = try j.required(entry, "value");
        try recipients.validateAddress(address);
        dest.* = .{ .address = address };
    }
    var etag: []const u8 = "";
    if (j.get(value, "metadata")) |metadata| for (try array(metadata, "sources")) |source| if (std.mem.eql(u8, j.text(source, "type"), "CONTACT")) {
        etag = j.text(source, "etag");
    };
    const resource_name = try j.required(value, "resourceName");
    if (!std.mem.startsWith(u8, resource_name, "people/")) return error.InvalidContactIdentity;
    try b.identifier(resource_name[7..]);
    var name: []const u8 = "";
    for (name_entries) |entry| {
        if (name.len == 0) name = j.text(entry, "displayName");
        if (j.get(entry, "metadata")) |metadata| if (j.boolean(metadata, "primary", false) catch false) {
            name = j.text(entry, "displayName");
            break;
        };
    }
    if (name.len > 512 or etag.len > 4096) return error.ContactTooLarge;
    name = try mime.sanitizeText(name, a);
    return .{ .resourceName = resource_name, .etag = etag, .name = name, .emails = emails };
}
fn contacts(a: std.mem.Allocator, transport: Transport, cmd: []const u8, request: j.Value) !j.Value {
    if (std.mem.eql(u8, cmd, "contacts.upsert")) {
        const input = try j.decode(types.Contact, a, j.get(request, "contact") orelse return error.MissingField);
        try recipients.validateHeader(input.name);
        if (input.name.len > 256 or input.emails.len == 0 or input.emails.len > 32) return error.InvalidContact;
        const Email = struct { value: []const u8 };
        const emails = try a.alloc(Email, input.emails.len);
        for (input.emails, emails) |email, *dest| {
            try recipients.validateAddress(email.address);
            dest.* = .{ .value = email.address };
        }
        var body = try j.value(a, .{ .names = .{.{ .unstructuredName = input.name }}, .emailAddresses = emails });
        var method: std.http.Method = .POST;
        var url: []const u8 = "https://people.googleapis.com/v1/people:createContact?personFields=names,emailAddresses,metadata";
        if (input.resourceName.len > 0) {
            if (!std.mem.startsWith(u8, input.resourceName, "people/")) return error.InvalidContactIdentity;
            try b.identifier(input.resourceName[7..]);
            url = try std.fmt.allocPrint(a, "https://people.googleapis.com/v1/{s}?personFields=names,emailAddresses,metadata", .{input.resourceName});
            const current = try transport.request(a, .GET, url, null);
            const normalized = try contact(a, current);
            const expected = if (j.get(request, "expectedEtag")) |v| try j.string(v) else input.etag;
            if (expected.len == 0 or !std.mem.eql(u8, normalized.etag, expected)) return error.ContactConflict;
            try body.object.put(a, "metadata", j.get(current, "metadata") orelse return error.InvalidContactIdentity);
            try body.object.put(a, "resourceName", .{ .string = input.resourceName });
            method = .PATCH;
            url = try std.fmt.allocPrint(a, "https://people.googleapis.com/v1/{s}:updateContact?updatePersonFields=names,emailAddresses&personFields=names,emailAddresses,metadata", .{input.resourceName});
        }
        const response = try transport.request(a, method, url, body);
        const updated = contact(a, response) catch return error.UnknownOutcome;
        return j.value(a, updated) catch return error.UnknownOutcome;
    }
    const query = j.text(request, "query");
    const limit = try j.integer(request, "limit", 100);
    if (limit < 1 or limit > 100) return error.InvalidPageLimit;
    const search = std.mem.eql(u8, cmd, "contacts.search");
    const url = if (search) try std.fmt.allocPrint(a, "https://people.googleapis.com/v1/people:searchContacts?readMask=names,emailAddresses,metadata&pageSize=30&query={s}", .{try escaped(a, query)}) else try std.fmt.allocPrint(a, "https://people.googleapis.com/v1/people/me/connections?personFields=names,emailAddresses,metadata&sources=READ_SOURCE_TYPE_CONTACT&pageSize={d}&pageToken={s}", .{ limit, try escaped(a, j.text(request, "cursor")) });
    if (search) _ = try transport.request(a, .GET, "https://people.googleapis.com/v1/people:searchContacts?readMask=names,emailAddresses,metadata&pageSize=30&query=", null);
    const value = try transport.request(a, .GET, url, null);
    const entries = try array(value, if (search) "results" else "connections");
    if (entries.len > 100) return error.InvalidPage;
    const results = try a.alloc(types.Contact, entries.len);
    for (entries, results) |entry, *dest| dest.* = try contact(a, if (search) j.get(entry, "person") orelse return error.InvalidProviderResponse else entry);
    return j.value(a, .{ .contacts = results, .nextCursor = if (j.get(value, "nextPageToken")) |v| try j.string(v) else @as(?[]const u8, null) });
}
test "People stale-source response requires exact failedPrecondition reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(contactPrecondition(a, "{\"error\":{\"code\":400,\"errors\":[{\"reason\":\"failedPrecondition\"}]}}"));
    try std.testing.expect(contactPrecondition(a, "{\"error\":{\"code\":400,\"status\":\"FAILED_PRECONDITION\"}}"));
    try std.testing.expect(!contactPrecondition(a, "{\"error\":{\"code\":400,\"message\":\"failedPrecondition\",\"errors\":[{\"reason\":\"invalidArgument\"}]}}"));
}
test "user label names resolve exact provider IDs once and system IDs need no request" {
    const FakeLabels = struct {
        calls: usize = 0,
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            try std.testing.expectEqual(std.http.Method.GET, method);
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/labels?fields=labels(id,name,type)", url);
            try std.testing.expect(body == null);
            return j.value(a, .{ .labels = .{ .{ .id = "Label_42", .name = "Follow Up", .type = "user" }, .{ .id = "Label_43", .name = "Travel/2026", .type = "user" } } });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: FakeLabels = .{};
    var resolver: LabelResolver = .{ .a = arena.allocator(), .transport = .{ .context = &fake, .requestFn = FakeLabels.request } };
    try std.testing.expectEqualStrings("TRASH", try resolver.resolve("trash"));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqualStrings("Label_42", try resolver.resolve("Follow Up"));
    try std.testing.expectEqualStrings("Label_43", try resolver.resolve("Travel/2026"));
    try std.testing.expectEqualStrings("Label_42", try resolver.resolve("Label_42"));
    try std.testing.expectError(error.LabelNotFound, resolver.resolve("Unknown synthetic label"));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "network session HTTP allocator borrows its caller-stable owner" {
    var session: NetworkSession = undefined;
    session.client = try http.Client.init(std.testing.io);
    defer session.client.deinit();
    var out: [16]u8 = undefined;
    const result: ?http.Response = session.client.requestLoopback("http://127.0.0.1:0/", &out) catch null;
    try std.testing.expect(result == null);
    const owner: *anyopaque = &session.client.workspace;
    try std.testing.expect(session.client.inner != null);
    try std.testing.expectEqual(owner, session.client.inner.?.allocator.ptr);
}
const HistoryOracle = struct {
    mode: enum { unchanged, delta, expired, overflowing },
    history_calls: usize = 0,
    metadata_calls: usize = 0,
    minimal_calls: usize = 0,
    list_calls: usize = 0,
    omit_labels: bool = false,
    fn transport(self: *HistoryOracle) Transport {
        return .{ .context = self, .requestFn = request };
    }
    fn literal(a: std.mem.Allocator, raw: []const u8) !j.Value {
        return std.json.parseFromSliceLeaky(j.Value, a, raw, .{ .allocate = .alloc_always });
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        _ = body;
        try std.testing.expectEqual(std.http.Method.GET, method);
        const self: *HistoryOracle = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, url, "/history?") != null) {
            self.history_calls += 1;
            try std.testing.expect(std.mem.indexOf(u8, url, "startHistoryId=41") != null);
            if (self.mode == .expired) return error.MessageNotFound;
            if (self.mode == .unchanged) return literal(a, "{\"historyId\":\"73\",\"history\":[]}");
            if (self.mode == .overflowing) return literal(a, "{\"historyId\":\"73\",\"history\":[],\"nextPageToken\":\"endless\"}");
            if (self.history_calls == 1) return literal(a, "{\"historyId\":\"73\",\"nextPageToken\":\"page-two\",\"history\":[{\"id\":\"57\",\"messagesAdded\":[{\"message\":{\"id\":\"new\"}}],\"messagesDeleted\":[{\"message\":{\"id\":\"gone\"}}],\"labelsAdded\":[{\"message\":{\"id\":\"cached\"}}]}]}");
            try std.testing.expect(std.mem.indexOf(u8, url, "pageToken=page-two") != null);
            return literal(a, "{\"historyId\":\"73\",\"history\":[{\"id\":\"73\",\"messagesAdded\":[{\"message\":{\"id\":\"new\"}}],\"labelsRemoved\":[{\"message\":{\"id\":\"cached\"}}]}]}");
        }
        if (std.mem.indexOf(u8, url, "format=minimal") != null) {
            self.minimal_calls += 1;
            if (self.omit_labels) return literal(a, "{\"id\":\"cached\"}");
            return literal(a, "{\"id\":\"cached\",\"labelIds\":[\"INBOX\",\"STARRED\"]}");
        }
        if (std.mem.indexOf(u8, url, "format=metadata") != null) {
            self.metadata_calls += 1;
            return literal(a, "{\"id\":\"new\",\"threadId\":\"thread\",\"internalDate\":\"42\",\"labelIds\":[\"INBOX\"],\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"sender@example.test\"}]}}");
        }
        if (std.mem.indexOf(u8, url, "/profile?") != null) return literal(a, "{\"historyId\":\"89\"}");
        if (std.mem.indexOf(u8, url, "/messages?") != null) {
            self.list_calls += 1;
            return literal(a, "{\"messages\":[]}");
        }
        return error.UnexpectedMockRequest;
    }
};
test "history no-change neither relists nor refetches metadata or bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: HistoryOracle = .{ .mode = .unchanged };
    const request = try HistoryOracle.literal(a, "{\"historyId\":\"41\",\"knownIds\":[\"cached\"],\"limit\":32}");
    const plan = try j.decode(RefreshPlan, a, try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, oracle.transport(), "mail.refresh", request));
    try std.testing.expectEqualStrings("73", plan.historyId);
    try std.testing.expectEqual(@as(usize, 1), oracle.history_calls);
    try std.testing.expectEqual(@as(usize, 0), oracle.metadata_calls + oracle.minimal_calls + oracle.list_calls);
    try std.testing.expectEqual(@as(usize, 0), plan.messages.len + plan.labels.len + plan.deleted.len);
}
test "history pages deduplicate added IDs retain deletions and only get minimal labels for known mail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: HistoryOracle = .{ .mode = .delta };
    const request = try HistoryOracle.literal(a, "{\"historyId\":\"41\",\"knownIds\":[\"cached\",\"gone\"],\"limit\":32}");
    const plan = try j.decode(RefreshPlan, a, try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, oracle.transport(), "mail.refresh", request));
    try std.testing.expectEqualStrings("73", plan.historyId);
    try std.testing.expectEqual(@as(usize, 2), oracle.history_calls);
    try std.testing.expectEqual(@as(usize, 1), oracle.metadata_calls);
    try std.testing.expectEqual(@as(usize, 1), oracle.minimal_calls);
    try std.testing.expectEqual(@as(usize, 0), oracle.list_calls);
    try std.testing.expectEqualStrings("new", plan.messages[0].id);
    try std.testing.expectEqual(@as(usize, 1), plan.added.len);
    try std.testing.expectEqualStrings("new", plan.added[0]);
    try std.testing.expectEqualStrings("gone", plan.deleted[0]);
    try std.testing.expectEqualStrings("cached", plan.labels[0].id);
    try std.testing.expectEqualStrings("STARRED", plan.labels[0].labels[1]);
    // An authoritative MINIMAL response may omit an empty repeated label field.
    var no_labels: HistoryOracle = .{ .mode = .delta, .omit_labels = true };
    const empty = try j.decode(RefreshPlan, a, try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, no_labels.transport(), "mail.refresh", request));
    try std.testing.expectEqual(@as(usize, 0), empty.labels[0].labels.len);
}
test "expired and over-budget histories use bounded recent resync" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try HistoryOracle.literal(a, "{\"historyId\":\"41\",\"knownIds\":[],\"limit\":32}");
    var expired: HistoryOracle = .{ .mode = .expired };
    const plan = try j.decode(RefreshPlan, a, try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, expired.transport(), "mail.refresh", request));
    try std.testing.expect(plan.resync);
    try std.testing.expectEqualStrings("89", plan.historyId);
    try std.testing.expectEqual(@as(usize, 1), expired.list_calls);
    var overflow: HistoryOracle = .{ .mode = .overflowing };
    const bounded = try j.decode(RefreshPlan, a, try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, overflow.transport(), "mail.refresh", request));
    try std.testing.expect(bounded.resync);
    try std.testing.expectEqualStrings("89", bounded.historyId);
    try std.testing.expectEqual(@as(usize, 8), overflow.history_calls);
    try std.testing.expectEqual(@as(usize, 1), overflow.list_calls);
}

const ScopedResyncOracle = struct {
    expired: bool,
    global_lists: usize = 0,
    scoped_lists: usize = 0,
    metadata_gets: usize = 0,
    fn transport(self: *ScopedResyncOracle) Transport {
        return .{ .context = self, .requestFn = request };
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        _ = body;
        try std.testing.expectEqual(std.http.Method.GET, method);
        const self: *ScopedResyncOracle = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, url, "/history?") != null) {
            try std.testing.expect(self.expired);
            return error.MessageNotFound;
        }
        if (std.mem.indexOf(u8, url, "/profile?") != null) return HistoryOracle.literal(a, "{\"historyId\":\"99\"}");
        if (std.mem.indexOf(u8, url, "/messages?") != null) {
            if (std.mem.indexOf(u8, url, "labelIds=STARRED") != null) {
                self.scoped_lists += 1;
                try std.testing.expect(std.mem.indexOf(u8, url, "q=subject%3Aneedle") != null);
                return HistoryOracle.literal(a, "{\"messages\":[{\"id\":\"older-starred\"}]}");
            }
            self.global_lists += 1;
            try std.testing.expect(std.mem.indexOf(u8, url, "includeSpamTrash=true") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "labelIds=") == null);
            try std.testing.expect(std.mem.indexOf(u8, url, "&q=") == null);
            return HistoryOracle.literal(a, "{\"messages\":[{\"id\":\"recent-inbox\"},{\"id\":\"recent-sent\"}]}");
        }
        if (std.mem.indexOf(u8, url, "format=metadata") != null) {
            self.metadata_gets += 1;
            const pos = std.mem.indexOf(u8, url, "/messages/").? + "/messages/".len;
            const end = std.mem.indexOfScalarPos(u8, url, pos, '?').?;
            const id = url[pos..end];
            const time: []const u8 = if (std.mem.eql(u8, id, "recent-inbox")) "100" else if (std.mem.eql(u8, id, "recent-sent")) "90" else "10";
            return j.value(a, .{ .id = id, .threadId = "fictional-thread", .internalDate = time, .labelIds = [_][]const u8{if (std.mem.eql(u8, id, "older-starred")) "STARRED" else "INBOX"}, .payload = .{ .headers = [_]struct { name: []const u8, value: []const u8 }{.{ .name = "From", .value = "sender@example.test" }} } });
        }
        return error.UnexpectedMockRequest;
    }
};
test "expired and missing checkpoint narrow resync keeps account retention separate from query membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ true, false }) |expired| {
        var oracle: ScopedResyncOracle = .{ .expired = expired };
        const request = try j.value(a, .{ .historyId = if (expired) @as([]const u8, "41") else "", .query = "subject:needle", .label = "STARRED", .limit = @as(u8, 2) });
        const plan = try j.decode(RefreshPlan, a, try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, oracle.transport(), "mail.refresh", request));
        try std.testing.expect(plan.resync);
        try std.testing.expectEqualStrings("99", plan.historyId);
        try std.testing.expectEqual(@as(usize, 1), oracle.global_lists);
        try std.testing.expectEqual(@as(usize, 1), oracle.scoped_lists);
        try std.testing.expectEqual(@as(usize, 3), oracle.metadata_gets);
        try std.testing.expectEqual(@as(usize, 1), plan.viewIds.len);
        try std.testing.expectEqualStrings("older-starred", plan.viewIds[0]);
        try std.testing.expectEqual(@as(usize, 3), plan.retentionIds.len);
        try std.testing.expect(containsId(plan.retentionIds, "recent-inbox"));
        try std.testing.expect(containsId(plan.retentionIds, "recent-sent"));
        try std.testing.expectEqualStrings("subject:needle", j.text(request, "query"));
        try std.testing.expectEqualStrings("STARRED", j.text(request, "label"));
    }
}

test "automatic jobs ignore terminal registry and cannot gain write capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config: Config = undefined;
    try config.defaults("/tmp");
    const request = try HistoryOracle.literal(a, "{\"auto\":true,\"barGrantOnly\":false,\"grantFile\":\"/nonexistent/fictional-terminal-grants.json\"}");
    var session: NetworkSession = undefined;
    try std.testing.expectError(error.OAuthClientRequired, session.init(std.testing.io, a, &config, "personal@example.com", "mail.refresh", request));
    for ([_][]const u8{ "mail.send", "contacts.upsert", "mail.trash", "invitation.reply" }) |command| try std.testing.expectError(error.PermissionDenied, session.init(std.testing.io, a, &config, "personal@example.com", command, request));
}

test "typed cache prefetch refuses invalid identity and absent read permission before provider calls" {
    const Spy = struct {
        calls: usize = 0,
        fn request(ctx: *anyopaque, _: std.mem.Allocator, _: std.http.Method, _: []const u8, _: ?j.Value) anyerror!j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return error.UnexpectedProviderCall;
        }
    };
    var spy: Spy = .{};
    const transport: Transport = .{ .context = &spy, .requestFn = Spy.request };
    const a = std.testing.allocator;
    try std.testing.expectError(error.PermissionDenied, readAuthorizedMessage(a, "fictional@example.test", &.{"mail-send"}, transport, "body-id"));
    try std.testing.expectError(error.InvalidAddress, readAuthorizedMessage(a, "invalid-account", &.{"mail-read"}, transport, "body-id"));
    try std.testing.expectError(error.InvalidAddress, readAuthorizedMessage(a, "invalid..local@example.test", &.{"mail-read"}, transport, "body-id"));
    try std.testing.expectError(error.InvalidIdentifier, readAuthorizedMessage(a, "fictional@example.test", &.{"mail-read"}, transport, "invalid/id"));
    try std.testing.expectEqual(@as(usize, 0), spy.calls);
}

test "invitation Gmail: named external Teams calendars fetch through read-only transport" {
    const Oracle = struct {
        kind: []const u8,
        declared: usize = calendar.len,
        message_calls: usize = 0,
        attachment_calls: usize = 0,
        const calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:teams-external@example.test\r\nDTSTAMP:20261007T090000Z\r\nDTSTART:20261012T080000Z\r\nSUMMARY:Fictional Teams meeting\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;RSVP=TRUE:mailto:self@example.test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(std.http.Method.GET, method);
            try std.testing.expect(body == null);
            if (std.mem.eql(u8, url, "https://gmail.googleapis.com/gmail/v1/users/me/messages/meeting-fixture?format=full")) {
                self.message_calls += 1;
                return j.value(a, .{ .id = "meeting-fixture", .threadId = "meeting-thread", .internalDate = "0", .payload = .{
                    .mimeType = self.kind,
                    .filename = "invite.ics",
                    .headers = [_]mime.Header{ .{ .name = "From", .value = "host@example.test" }, .{ .name = "Content-Type", .value = self.kind } },
                    .body = .{ .attachmentId = "named-calendar", .size = self.declared },
                } });
            }
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/meeting-fixture/attachments/named-calendar", url);
            self.attachment_calls += 1;
            const storage = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(calendar.len));
            return j.value(a, .{ .size = calendar.len, .data = std.base64.url_safe_no_pad.Encoder.encode(storage, calendar) });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "text/calendar", "application/ics", "application/octet-stream" }) |kind| {
        var oracle: Oracle = .{ .kind = kind };
        const transport: Transport = .{ .context = &oracle, .requestFn = Oracle.request };
        const message = try readAuthorizedMessage(a, "self@example.test", &.{"mail-read"}, transport, "meeting-fixture");
        try std.testing.expectEqual(@as(usize, 1), oracle.message_calls);
        try std.testing.expectEqual(@as(usize, 1), oracle.attachment_calls);
        try std.testing.expectEqualStrings(Oracle.calendar, message.invitation.?);
        try std.testing.expectEqual(@as(usize, 1), message.attachments.len);
        try std.testing.expectEqualStrings("invite.ics", message.attachments[0].filename);
        try std.testing.expectEqualStrings(Oracle.calendar, try mime.decodeBase64Url(message.attachments[0].data, a));
        var invite: invitation.Invitation = .{};
        try invitation.parse(message.invitation.?, "self@example.test", &.{}, &invite);
        try std.testing.expectEqualStrings("teams-external@example.test", invite.uid.slice());
        try std.testing.expectEqualStrings("self@example.test", invite.attendee.slice());
        oracle.declared = 131073;
        try std.testing.expectError(error.CalendarTooLarge, readAuthorizedMessage(a, "self@example.test", &.{"mail-read"}, transport, "meeting-fixture"));
        try std.testing.expectEqual(@as(usize, 2), oracle.message_calls);
        try std.testing.expectEqual(@as(usize, 1), oracle.attachment_calls);
    }
}

test "invitation Gmail: calendar candidates share the cumulative external-body quota before downloads" {
    const Spy = struct {
        calls: usize = 0,
        fn request(ctx: *anyopaque, _: std.mem.Allocator, _: std.http.Method, _: []const u8, _: ?j.Value) anyerror!j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return error.UnexpectedProviderCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spy: Spy = .{};
    const transport: Transport = .{ .context = &spy, .requestFn = Spy.request };
    const payload = try j.value(a, .{ .mimeType = "application/octet-stream", .filename = "invite.ics", .body = .{ .size = 256, .attachmentId = "quota-calendar" } });
    var map: std.json.ObjectMap = .empty;
    var budget: ExternalBodiesBudget = .{ .bytes = mime.max_raw_bytes - 255 };
    try std.testing.expectError(error.DecodedMessageTooLarge, externalBodies(a, transport, "fixture", payload, &map, 0, &budget));
    try std.testing.expectEqual(@as(usize, 0), spy.calls);
}

test "wishlist: send-as verified identities signatures and sender wire" {
    const Oracle = struct {
        settings: usize = 0,
        sends: usize = 0,
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, url, "https://gmail.googleapis.com/gmail/v1/users/me/settings/sendAs?fields=sendAs(sendAsEmail,displayName,signature,isPrimary,isDefault,verificationStatus)")) {
                self.settings += 1;
                try std.testing.expectEqual(std.http.Method.GET, method);
                try std.testing.expect(body == null);
                return std.json.parseFromSliceLeaky(j.Value, a, "{\"sendAs\":[{\"sendAsEmail\":\"self@example.test\",\"displayName\":\"Self\",\"signature\":\"<b>Self</b><br>Example\",\"isPrimary\":true,\"isDefault\":true},{\"sendAsEmail\":\"alias@example.test\",\"displayName\":\"Alias\",\"verificationStatus\":\"accepted\",\"signature\":\"<script>unsafe</script><p>Alias</p>\"},{\"sendAsEmail\":\"pending@example.test\",\"verificationStatus\":\"pending\"}]}", .{});
            }
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", url);
            try std.testing.expectEqual(std.http.Method.POST, method);
            self.sends += 1;
            const encoded = try j.required(body orelse return error.MissingField, "raw");
            const raw = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded));
            try std.base64.url_safe_no_pad.Decoder.decode(raw, encoded);
            // Literal independent RFC expectation, not encoder/inverse pairing.
            try std.testing.expect(std.mem.startsWith(u8, raw, "From: \"Alias\" <alias@example.test>\r\n"));
            try std.testing.expect(std.mem.indexOf(u8, raw, "Subject: hi\r\n") != null);
            return std.json.parseFromSliceLeaky(j.Value, a, "{\"id\":\"sent-1\",\"threadId\":\"sent-thread\"}", .{});
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: Oracle = .{};
    const transport: Transport = .{ .context = &oracle, .requestFn = Oracle.request };
    const listed = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, transport, "accounts.identities", j.object(a));
    const rows = try array(listed, "identities");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("Self\nExample", j.text(rows[0], "signature"));
    try std.testing.expectEqualStrings("Alias", j.text(rows[1], "signature"));
    var draft: types.Draft = .{ .from = .{ .address = "pending@example.test", .name = "Pending" }, .to = &.{.{ .address = "peer@example.test" }}, .subject = "hi", .bodyText = "Hello" };
    var request = try j.value(a, .{ .operationId = "alias-check", .draft = draft });
    try std.testing.expectError(error.UnverifiedSender, dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-send"}, transport, "mail.send", request));
    try std.testing.expectEqual(@as(usize, 0), oracle.sends);
    draft.from = .{ .address = "alias@example.test", .name = "Alias" };
    request = try j.value(a, .{ .operationId = "verified-alias", .draft = draft });
    _ = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-send"}, transport, "mail.send", request);
    try std.testing.expectEqual(@as(usize, 1), oracle.sends);
    try std.testing.expectEqual(@as(usize, 3), oracle.settings);
}

test "markdown mail: authorized Gmail transport sends rendered alternatives and forbids readonly writes" {
    const Oracle = struct {
        calls: usize = 0,
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            try std.testing.expectEqual(std.http.Method.POST, method);
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", url);
            const encoded = try j.required(body orelse return error.MissingField, "raw");
            const raw = try mime.decodeBase64Url(encoded, a);
            try std.testing.expect(std.mem.indexOf(u8, raw, "Content-Type: multipart/alternative;") != null);
            try std.testing.expect(std.mem.indexOf(u8, raw, "Content-Type: multipart/related; type=\"text/html\";") != null);
            const decoded = try mime.parse(raw, a);
            try std.testing.expect(std.mem.startsWith(u8, decoded.body_text, "Hello fixture."));
            try std.testing.expect(std.mem.indexOf(u8, decoded.body_html, "<strong>Hello</strong> fixture.") != null);
            try std.testing.expect(std.mem.indexOf(u8, decoded.body_html, "<script>") == null);
            const cid = std.mem.trim(u8, decoded.attachments[0].content_id, "<>");
            try std.testing.expect(std.mem.indexOf(u8, decoded.body_html, try std.fmt.allocPrint(a, "src=\"cid:{s}\"", .{cid})) != null);
            return std.json.parseFromSliceLeaky(j.Value, a, "{\"id\":\"synthetic-sent\",\"threadId\":\"synthetic-thread\"}", .{});
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: Oracle = .{};
    const transport: Transport = .{ .context = &oracle, .requestFn = Oracle.request };
    const request = try j.value(a, .{ .operationId = "markdown-wire", .draft = .{ .to = [_]types.Address{.{ .address = "peer@example.test" }}, .bodyText = "**Hello** fixture.\n\n<script>literal</script>", .bodyFormat = "markdown", .bodyHtml = "<script>ignored caller HTML</script>" } });
    try std.testing.expectError(error.PermissionDenied, dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, transport, "mail.send", request));
    try std.testing.expectEqual(@as(usize, 0), oracle.calls);
    const receipt = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-send"}, transport, "mail.send", request);
    try std.testing.expectEqualStrings("applied", j.text(receipt, "outcome"));
    try std.testing.expectEqual(@as(usize, 1), oracle.calls);
}

test "forward attachment: cached opaque selection downloads directly and canonicalizes padded bytes" {
    const Oracle = struct {
        calls: usize = 0,
        data: []const u8,
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            try std.testing.expectEqual(std.http.Method.GET, method);
            try std.testing.expect(body == null);
            // A fresh FULL response would rotate this identity. No FULL read
            // should precede the selected immutable file's valid token GET.
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/forward-message/attachments/cached-token", url);
            return j.value(a, .{ .data = self.data });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { wire: []const u8, canonical: []const u8, bytes: []const u8 }{
        .{ .wire = "AA==", .canonical = "AA", .bytes = &.{0} },
        .{ .wire = "AP8=", .canonical = "AP8", .bytes = &.{ 0, 0xff } },
        .{ .wire = "AP8", .canonical = "AP8", .bytes = &.{ 0, 0xff } },
        .{ .wire = "AP-A", .canonical = "AP-A", .bytes = &.{ 0, 0xff, 0x80 } },
    }) |case| {
        var oracle: Oracle = .{ .data = case.wire };
        const transport: Transport = .{ .context = &oracle, .requestFn = Oracle.request };
        const expected: types.Attachment = .{ .id = "cached-token", .filename = "fixture.bin", .mimeType = "image/jpeg", .size = case.bytes.len };
        try std.testing.expectError(error.PermissionDenied, attachmentAuthorized(a, "self@example.test", &.{}, transport, "forward-message", expected));
        try std.testing.expectEqual(@as(usize, 0), oracle.calls);
        const file = try attachmentAuthorized(a, "self@example.test", &.{"mail-read"}, transport, "forward-message", expected);
        try std.testing.expectEqualStrings(case.canonical, file.data);
        try std.testing.expectEqualStrings(expected.id, file.id);
        try std.testing.expectEqualStrings(expected.filename, file.filename);
        try std.testing.expectEqual(expected.size, file.size);
        try std.testing.expectEqualSlices(u8, case.bytes, try mime.decodeBase64Url(file.data, a));
        try std.testing.expectEqual(@as(usize, 1), oracle.calls);
        // This is the strict shared forward/source contract that the old
        // provider response's '=' padding failed before any draft was saved.
        try @import("core.zig").validateDraft(.{ .bodyText = "Retained forward source", .attachments = &.{file} }, false);
    }
}

test "forward attachment: expired token resolves unique current metadata and refuses ambiguity or changed bytes" {
    const Oracle = struct {
        calls: usize = 0,
        ambiguous: bool = false,
        mismatch: bool = false,
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            try std.testing.expectEqual(std.http.Method.GET, method);
            try std.testing.expect(body == null);
            if (std.mem.endsWith(u8, url, "/attachments/cached-token")) return error.MessageNotFound;
            if (std.mem.endsWith(u8, url, "/attachments/fresh-token")) return j.value(a, .{ .data = if (self.mismatch) "AA==" else "AP8=" });
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/forward-message?format=full", url);
            var parts: j.Value = .{ .array = .init(a) };
            try parts.array.append(try j.value(a, .{ .partId = "0", .mimeType = "text/plain", .filename = "", .body = .{ .size = 5, .data = "VGV4dAo" } }));
            for (0..if (self.ambiguous) @as(usize, 2) else 1) |index| {
                try parts.array.append(try j.value(a, .{ .partId = if (index == 0) "1" else "2", .mimeType = "image/jpeg", .filename = "fixture.bin", .headers = .{.{ .name = "Content-Disposition", .value = "inline; filename=fixture.bin" }}, .body = .{ .size = 2, .attachmentId = if (index == 0) "fresh-token" else "another-fresh-token" } }));
            }
            var message = try j.value(a, .{ .id = "forward-message", .threadId = "forward-thread", .internalDate = "42", .payload = .{ .mimeType = "multipart/mixed", .headers = .{ .{ .name = "From", .value = "Sender <sender@example.test>" }, .{ .name = "Message-ID", .value = "<original@example.test>" } } } });
            try message.object.getPtr("payload").?.object.put(a, "parts", parts);
            return message;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected: types.Attachment = .{ .id = "cached-token", .filename = "fixture.bin", .mimeType = "image/jpeg", .size = 2 };
    var oracle: Oracle = .{};
    const transport: Transport = .{ .context = &oracle, .requestFn = Oracle.request };
    const resolved = try attachmentAuthorized(a, "self@example.test", &.{"mail-read"}, transport, "forward-message", expected);
    try std.testing.expectEqualStrings("fresh-token", resolved.id);
    try std.testing.expectEqualStrings("AP8", resolved.data);
    try std.testing.expectEqual(@as(usize, 3), oracle.calls);
    try @import("core.zig").validateDraft(.{ .bodyText = "Original source remains untouched", .attachments = &.{resolved} }, false);
    oracle = .{ .ambiguous = true };
    try std.testing.expectError(error.AmbiguousAttachment, attachmentAuthorized(a, "self@example.test", &.{"mail-read"}, transport, "forward-message", expected));
    try std.testing.expectEqual(@as(usize, 2), oracle.calls);
    oracle = .{ .mismatch = true };
    try std.testing.expectError(error.BodySizeMismatch, attachmentAuthorized(a, "self@example.test", &.{"mail-read"}, transport, "forward-message", expected));
    try std.testing.expectEqual(@as(usize, 3), oracle.calls);
}

test "wishlist: labels minimal snapshot and exact modify wire" {
    const Oracle = struct {
        calls: usize = 0,
        fn request(ctx: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (std.mem.eql(u8, url, "https://gmail.googleapis.com/gmail/v1/users/me/labels?fields=labels(id,name,type)")) {
                try std.testing.expectEqual(std.http.Method.GET, method);
                try std.testing.expect(body == null);
                return std.json.parseFromSliceLeaky(j.Value, a, "{\"labels\":[{\"id\":\"Label_42\",\"name\":\"Project\",\"type\":\"user\"}]}", .{});
            }
            if (std.mem.eql(u8, url, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1?format=minimal&fields=id,labelIds")) {
                try std.testing.expectEqual(std.http.Method.GET, method);
                try std.testing.expect(body == null);
                return std.json.parseFromSliceLeaky(j.Value, a, "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"UNREAD\",\"Label_old\"]}", .{});
            }
            try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify?fields=id,labelIds", url);
            try std.testing.expectEqual(std.http.Method.POST, method);
            const wire = try std.json.Stringify.valueAlloc(a, body orelse return error.MissingField, .{});
            try std.testing.expectEqualStrings("{\"addLabelIds\":[\"TRASH\"],\"removeLabelIds\":[\"INBOX\"]}", wire);
            return std.json.parseFromSliceLeaky(j.Value, a, "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\",\"TRASH\",\"Label_old\"]}", .{});
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: Oracle = .{};
    const transport: Transport = .{ .context = &oracle, .requestFn = Oracle.request };
    const labels = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, transport, "labels.list", j.object(a));
    try std.testing.expectEqualStrings("Project", j.text((try array(labels, "labels"))[0], "name"));
    const before = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, transport, "mail.labels", try j.value(a, .{ .messageId = "m1" }));
    try std.testing.expectEqualStrings("INBOX", try j.string((try array(before, "labels"))[0]));
    const request = try j.value(a, .{ .messageId = "m1", .addLabels = [_][]const u8{"TRASH"}, .removeLabels = [_][]const u8{"INBOX"} });
    try std.testing.expectError(error.PermissionDenied, dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, transport, "mail.modify-labels", request));
    try std.testing.expectEqual(@as(usize, 2), oracle.calls);
    const changed = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-modify"}, transport, "mail.modify-labels", request);
    try std.testing.expectEqualStrings("TRASH", try j.string((try array(changed, "labels"))[1]));
    try std.testing.expectEqual(@as(usize, 3), oracle.calls);
}

test "fetch progress: metadata fraction uses actual provider IDs not requested maximum" {
    const Recorder = struct {
        values: [8]types.FetchProgress = undefined,
        count: usize = 0,
        rows: [2]types.FetchRow = undefined,
        row_count: usize = 0,
        incremental: bool = true,
        fn report(ctx: *anyopaque, value: types.FetchProgress) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.count < self.values.len) {
                self.values[self.count] = value;
                self.count += 1;
            }
        }
        fn row(ctx: *anyopaque, value: types.FetchRow) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.incremental = self.incremental and self.count == self.row_count + 1 and value.index == self.row_count and value.total == 2 and value.kind == .page;
            if (self.row_count < self.rows.len) {
                self.rows[self.row_count] = value;
                self.row_count += 1;
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var oracle: ScopedResyncOracle = .{ .expired = false };
    var recorder: Recorder = .{};
    var transport = oracle.transport();
    transport.progress_sink = .{ .ctx = &recorder, .reportFn = Recorder.report, .rowFn = Recorder.row };
    _ = try dispatchAuthorized(std.testing.io, a, "self@example.test", &.{"mail-read"}, transport, "mail.list", try j.value(a, .{ .limit = @as(u8, 100), .includeSpamTrash = true }));
    try std.testing.expectEqual(@as(usize, 3), recorder.count);
    for (recorder.values[0..3], [_]usize{ 0, 1, 2 }) |value, completed| {
        try std.testing.expectEqual(types.FetchPhase.metadata, value.phase);
        try std.testing.expectEqual(completed, value.completed);
        try std.testing.expectEqual(@as(usize, 2), value.total);
    }
    try std.testing.expectEqual(@as(usize, 2), oracle.metadata_gets);
    try std.testing.expectEqual(@as(usize, 2), recorder.row_count);
    try std.testing.expect(recorder.incremental);
    try std.testing.expectEqualStrings("recent-inbox", recorder.rows[0].message.id);
    try std.testing.expectEqualStrings("recent-sent", recorder.rows[1].message.id);
    try std.testing.expectEqual(@as(usize, 0), recorder.rows[0].message.bodyText.len);
}

test "cache activity: only typed incoming Inbox additions count and replay keeps identity" {
    const messages = [_]types.Message{
        .{ .id = "new", .threadId = "t", .labels = &.{"INBOX"} },
        .{ .id = "label-only", .threadId = "t", .labels = &.{"INBOX"} },
        .{ .id = "tail", .threadId = "t", .labels = &.{"INBOX"} },
        .{ .id = "sent", .threadId = "t", .labels = &.{"SENT"} },
        .{ .id = "self-sent", .threadId = "t", .labels = &.{ "INBOX", "SENT" } },
        .{ .id = "archived", .threadId = "t", .labels = &.{} },
        .{ .id = "deleted", .threadId = "t", .labels = &.{"INBOX"} },
    };
    var plan: RefreshPlan = .{ .historyId = "2", .messages = &messages, .added = &.{ "new", "new", "sent", "self-sent", "archived", "deleted", "missing" }, .deleted = &.{"deleted"} };
    try std.testing.expectEqual(@as(usize, 1), plan.inboxArrivals());
    // A replay is classified by the same typed IDs, not an uncached-ID diff.
    try std.testing.expectEqual(@as(usize, 1), plan.inboxArrivals());
    plan.resync = true;
    try std.testing.expectEqual(@as(usize, 0), plan.inboxArrivals());
    plan.resync = false;
    plan.added = &.{};
    try std.testing.expectEqual(@as(usize, 0), plan.inboxArrivals());
}
