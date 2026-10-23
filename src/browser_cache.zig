//! Bounded, account/grant-scoped mail snapshots. Browser persistence transports
//! this schema; credentials, draft state and native file handles never enter it.
const std = @import("std");
const types = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const recipients = @import("terminal/recipients.zig");
const query = @import("terminal/cache_query.zig");
const policy = @import("terminal/mail_limits.zig");
const decoder_policy = @import("terminal/decoder_policy.zig");
const display_fields = @import("terminal/mail_display_fields.zig");
pub const snapshot_limit = 3 * 1024 * 1024;
pub const total_limit = 8 * 1024 * 1024;
pub const Binding = struct { account: []const u8, clientId: []const u8, grantId: []const u8 };
const Attachment = struct { id: []const u8, filename: []const u8, mimeType: []const u8 = "application/octet-stream", size: usize = 0, contentId: ?[]const u8 = null, disposition: ?[]const u8 = null, contentLocation: ?[]const u8 = null };
const Message = struct {
    id: []const u8,
    threadId: []const u8,
    from: types.Address = .{ .address = "" },
    replyTo: []const types.Address = &.{},
    to: []const types.Address = &.{},
    cc: []const types.Address = &.{},
    subject: []const u8 = "",
    snippet: []const u8 = "",
    bodyText: []const u8 = "",
    bodyHtml: ?[]const u8 = null,
    bodyHtmlAmbiguous: bool = false,
    bodySource: types.BodySource = .unknown,
    messageId: []const u8 = "",
    references: []const u8 = "",
    inReplyTo: []const u8 = "",
    labels: []const []const u8 = &.{},
    receivedAt: i64 = 0,
    sentDate: ?[]const u8 = null,
    unread: bool = false,
    bodyCached: bool = false,
    bodyCacheError: []const u8 = "",
    decodeWarning: []const u8 = "",
    metadataPartial: bool = false,
    labelsVerified: bool = true,
    attachments: []const Attachment = &.{},
};
const Contact = struct { resourceName: []const u8 = "", etag: []const u8 = "", name: []const u8 = "", emails: []const types.Address = &.{}, readWarnings: types.ContactReadWarnings = .{} };
const Document = struct { version: u8, decoderRevision: u32 = 0, account: []const u8, clientId: []const u8, grantId: []const u8, updatedAt: i64, messages: []Message, contacts: []Contact, contactsLoaded: bool, contactWarnings: types.ContactReadWarnings = .{} };
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    messages: []types.Message = &.{},
    contacts: []types.Contact = &.{},
    contacts_loaded: bool = false,
    contact_warnings: types.ContactReadWarnings = .{},
    updated_at: i64 = 0,
    loaded: bool = false,
    bytes: usize = 0,
    revision: u32 = 0,
    decoder_revision: u32 = decoder_policy.decoder_revision,
};
fn bounded(value: []const u8, limit: usize) !void {
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return error.InvalidBrowserCache;
}
fn address(value: types.Address, incoming: bool) !void {
    try bounded(value.name, policy.display_name_bytes);
    try bounded(value.address, if (incoming) policy.incoming_address_bytes else policy.outgoing_address_bytes);
    if (value.address.len > 0) {
        if (incoming) try recipients.validateIncomingAddress(value.address) else try recipients.validateAddress(value.address);
    }
}
fn addresses(values: []const types.Address, incoming: bool) !void {
    if (values.len > policy.incoming_recipients) return error.InvalidBrowserCache;
    for (values) |value| try address(value, incoming);
}
fn validateMessage(value: types.Message) !void {
    if (value.id.len == 0 or value.attachments.len > types.Limits.message_attachments or value.labels.len > 128) return error.InvalidBrowserCache;
    try bounded(value.id, 128);
    try bounded(value.threadId, 128);
    // Shared MIME decoding already distinguishes received header syntax from
    // sending limits. Cache admission must preserve that same distinction.
    try address(value.from, true);
    try addresses(value.to, true);
    try addresses(value.cc, true);
    try addresses(value.replyTo, true);
    try bounded(value.subject, policy.subject_bytes);
    try bounded(value.snippet, policy.snippet_bytes);
    try bounded(value.bodyText, 2 * 1024 * 1024);
    if (value.bodyHtml) |html| try bounded(html, 2 * 1024 * 1024);
    try bounded(value.messageId, policy.header_value_bytes);
    try bounded(value.references, policy.references_bytes);
    try bounded(value.inReplyTo, policy.header_value_bytes);
    try bounded(value.bodyCacheError, 512);
    try bounded(value.decodeWarning, 512);
    if (value.sentDate) |date| try bounded(date, policy.header_value_bytes);
    for (value.labels) |label| try bounded(label, 256);
    for (value.attachments) |file| {
        try bounded(file.id, 4096);
        try bounded(file.filename, policy.filename_bytes);
        try bounded(file.mimeType, policy.header_value_bytes);
        if (file.contentId) |id| try bounded(id, policy.header_value_bytes);
        if (file.disposition) |kind| try bounded(kind, policy.header_value_bytes);
        if (file.contentLocation) |location| try bounded(location, policy.header_value_bytes);
    }
}
fn copyAddress(a: std.mem.Allocator, value: types.Address) !types.Address {
    return .{ .address = try a.dupe(u8, value.address), .name = try a.dupe(u8, value.name) };
}
fn copyAddresses(a: std.mem.Allocator, values: []const types.Address) ![]types.Address {
    const result = try a.alloc(types.Address, values.len);
    for (values, result) |value, *dest| dest.* = try copyAddress(a, value);
    return result;
}
fn copyMessage(a: std.mem.Allocator, value: types.Message) !types.Message {
    try validateMessage(value);
    var result = value;
    inline for (.{ "id", "threadId", "subject", "snippet", "bodyText", "messageId", "references", "inReplyTo", "bodyCacheError", "decodeWarning" }) |field| @field(result, field) = try a.dupe(u8, @field(value, field));
    result.bodyHtml = if (value.bodyHtml) |html| try a.dupe(u8, html) else null;
    result.sentDate = if (value.sentDate) |date| try a.dupe(u8, date) else null;
    result.from = try copyAddress(a, value.from);
    result.to = try copyAddresses(a, value.to);
    result.cc = try copyAddresses(a, value.cc);
    result.replyTo = try copyAddresses(a, value.replyTo);
    const labels = try a.alloc([]const u8, value.labels.len);
    for (value.labels, labels) |label, *dest| dest.* = try a.dupe(u8, label);
    result.labels = labels;
    const files = try a.alloc(types.Attachment, value.attachments.len);
    for (value.attachments, files) |file, *dest| dest.* = .{ .id = try a.dupe(u8, file.id), .filename = try a.dupe(u8, file.filename), .mimeType = try a.dupe(u8, file.mimeType), .size = file.size, .contentId = if (file.contentId) |id| try a.dupe(u8, id) else null, .disposition = if (file.disposition) |kind| try a.dupe(u8, kind) else null, .contentLocation = if (file.contentLocation) |location| try a.dupe(u8, location) else null };
    result.attachments = files;
    result.fixtureRaw = null;
    result.invitation = null;
    return display_fields.canonicalizeMessageDisplay(a, result);
}
fn copyContact(a: std.mem.Allocator, value: types.Contact) !types.Contact {
    try bounded(value.resourceName, 256);
    try bounded(value.etag, 4096);
    try bounded(value.name, policy.display_name_bytes);
    try addresses(value.emails, false);
    return .{ .resourceName = try a.dupe(u8, value.resourceName), .etag = try a.dupe(u8, value.etag), .name = try a.dupe(u8, value.name), .emails = try copyAddresses(a, value.emails), .readWarnings = value.readWarnings };
}
pub const Store = struct {
    allocator: std.mem.Allocator,
    bindings: [3]?Binding = @splat(null),
    entries: [3]Entry,
    pub fn init(a: std.mem.Allocator) Store {
        return .{ .allocator = a, .entries = .{ .{ .arena = .init(a) }, .{ .arena = .init(a) }, .{ .arena = .init(a) } } };
    }
    pub fn deinit(self: *Store) void {
        for (&self.entries) |*entry| entry.arena.deinit();
        for (self.bindings) |binding| if (binding) |b| {
            self.allocator.free(b.account);
            self.allocator.free(b.clientId);
            self.allocator.free(b.grantId);
        };
    }
    pub fn bind(self: *Store, index: usize, binding: Binding) !void {
        if (index >= 3) return error.InvalidBrowserCache;
        const new_account = try self.allocator.dupe(u8, binding.account);
        errdefer self.allocator.free(new_account);
        const new_client = try self.allocator.dupe(u8, binding.clientId);
        errdefer self.allocator.free(new_client);
        const new_grant = try self.allocator.dupe(u8, binding.grantId);
        errdefer self.allocator.free(new_grant);
        if (self.bindings[index]) |old| {
            if (std.mem.eql(u8, old.account, binding.account) and std.mem.eql(u8, old.clientId, binding.clientId) and std.mem.eql(u8, old.grantId, binding.grantId)) {
                self.allocator.free(new_account);
                self.allocator.free(new_client);
                self.allocator.free(new_grant);
                return;
            }
            self.allocator.free(old.account);
            self.allocator.free(old.clientId);
            self.allocator.free(old.grantId);
            self.bindings[index] = null;
        }
        self.clear(index);
        self.bindings[index] = .{ .account = new_account, .clientId = new_client, .grantId = new_grant };
    }
    pub fn clear(self: *Store, index: usize) void {
        if (index >= 3) return;
        const revision_value = self.entries[index].revision +% 1;
        self.entries[index].arena.deinit();
        self.entries[index] = .{ .arena = .init(self.allocator), .revision = revision_value };
    }
    pub fn valid(self: *const Store, index: usize) bool {
        return index < 3 and self.entries[index].loaded;
    }
    pub fn revision(self: *const Store, index: usize) u32 {
        return if (index < 3) self.entries[index].revision else 0;
    }
    pub fn contactsLoaded(self: *const Store, index: usize) bool {
        return index < 3 and self.entries[index].contacts_loaded;
    }
    pub fn contactWarnings(self: *const Store, index: usize) types.ContactReadWarnings {
        return if (index < 3) self.entries[index].contact_warnings else .{};
    }
    pub fn updatedAt(self: *const Store, index: usize) i64 {
        return if (index < 3) self.entries[index].updated_at else 0;
    }
    /// Borrowed current inventory, for local recipient building and bounded
    /// native-protocol pagination. It never includes historical snapshots.
    pub fn retained(self: *const Store, index: usize) []const types.Message {
        return if (index < 3) self.entries[index].messages else &.{};
    }
    /// Only a confirmed provider receipt may replace mailbox membership. Body
    /// and envelope data remain attached to their existing message identity.
    pub fn applyLabels(self: *Store, index: usize, id: []const u8, labels: []const []const u8) !void {
        if (index >= 3 or labels.len > 64) return error.InvalidBrowserCache;
        try @import("bounded.zig").identifier(id);
        for (labels) |label| try bounded(label, 256);
        var position: ?usize = null;
        for (self.entries[index].messages, 0..) |message, row| if (std.mem.eql(u8, message.id, id)) {
            position = row;
            break;
        };
        const row = position orelse return;
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        const a = next.arena.allocator();
        const copied = try a.alloc([]const u8, labels.len);
        var unread = false;
        for (labels, copied) |label, *dest| {
            dest.* = try a.dupe(u8, label);
            unread = unread or std.mem.eql(u8, label, "UNREAD");
        }
        next.messages[row].labels = copied;
        next.messages[row].unread = unread;
        next.messages[row].labelsVerified = true;
        try self.commit(index, &next, id);
    }
    /// Deleting a custom label keeps every message and its cached body.
    pub fn dropLabel(self: *Store, index: usize, id: []const u8) !void {
        if (index >= 3) return error.InvalidBrowserCache;
        try @import("bounded.zig").identifier(id);
        if (self.entries[index].messages.len == 0) return;
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        for (next.messages) |*message| {
            const labels = @constCast(message.labels);
            var kept: usize = 0;
            for (labels) |label| if (!std.mem.eql(u8, label, id)) {
                labels[kept] = label;
                kept += 1;
            };
            message.labels = labels[0..kept];
        }
        try self.commit(index, &next, "");
    }
    fn copyEntry(self: *Store, index: usize) !Entry {
        if (index >= 3 or self.bindings[index] == null) return error.InvalidBrowserCache;
        var next: Entry = .{ .arena = .init(self.allocator), .updated_at = self.entries[index].updated_at, .loaded = true, .contacts_loaded = self.entries[index].contacts_loaded, .contact_warnings = self.entries[index].contact_warnings, .decoder_revision = self.entries[index].decoder_revision };
        errdefer next.arena.deinit();
        const a = next.arena.allocator();
        next.messages = try a.alloc(types.Message, self.entries[index].messages.len);
        for (self.entries[index].messages, next.messages) |value, *dest| dest.* = try copyMessage(a, value);
        next.contacts = try a.alloc(types.Contact, self.entries[index].contacts.len);
        for (self.entries[index].contacts, next.contacts) |value, *dest| dest.* = try copyContact(a, value);
        return next;
    }
    fn document(self: *Store, index: usize, entry: *const Entry, a: std.mem.Allocator) !Document {
        const binding = self.bindings[index] orelse return error.InvalidBrowserCache;
        const messages = try a.alloc(Message, entry.messages.len);
        for (entry.messages, messages) |m, *dest| {
            const files = try a.alloc(Attachment, m.attachments.len);
            for (m.attachments, files) |file, *target| target.* = .{ .id = file.id, .filename = file.filename, .mimeType = file.mimeType, .size = file.size, .contentId = file.contentId, .disposition = file.disposition, .contentLocation = file.contentLocation };
            dest.* = .{ .id = m.id, .threadId = m.threadId, .from = m.from, .replyTo = m.replyTo, .to = m.to, .cc = m.cc, .subject = m.subject, .snippet = m.snippet, .bodyText = m.bodyText, .bodyHtml = m.bodyHtml, .bodyHtmlAmbiguous = m.bodyHtmlAmbiguous, .bodySource = m.bodySource, .messageId = m.messageId, .references = m.references, .inReplyTo = m.inReplyTo, .labels = m.labels, .receivedAt = m.receivedAt, .sentDate = m.sentDate, .unread = m.unread, .bodyCached = m.bodyCached, .bodyCacheError = m.bodyCacheError, .decodeWarning = m.decodeWarning, .metadataPartial = m.metadataPartial, .labelsVerified = m.labelsVerified, .attachments = files };
        }
        const contact_values = try a.alloc(Contact, entry.contacts.len);
        for (entry.contacts, contact_values) |c, *dest| dest.* = .{ .resourceName = c.resourceName, .etag = c.etag, .name = c.name, .emails = c.emails, .readWarnings = c.readWarnings };
        return .{ .version = 1, .decoderRevision = entry.decoder_revision, .account = binding.account, .clientId = binding.clientId, .grantId = binding.grantId, .updatedAt = entry.updated_at, .messages = messages, .contacts = contact_values, .contactsLoaded = entry.contacts_loaded, .contactWarnings = entry.contact_warnings };
    }
    fn commit(self: *Store, index: usize, next: *Entry, protected_id: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var other: usize = 0;
        for (self.entries, 0..) |entry, cursor| if (cursor != index) {
            other += entry.bytes;
        };
        while (true) {
            _ = scratch.reset(.retain_capacity);
            const doc = try self.document(index, next, scratch.allocator());
            var buffer: [256]u8 = undefined;
            var counter: std.Io.Writer.Discarding = .init(&buffer);
            try std.json.Stringify.value(doc, .{}, &counter.writer);
            const size = counter.fullCount();
            if (size <= snapshot_limit and size + other <= total_limit) {
                next.bytes = @intCast(size);
                break;
            }
            var removed = false;
            var body_row = next.messages.len;
            while (body_row > 0) {
                body_row -= 1;
                const m = &next.messages[body_row];
                if (m.bodyCached and !std.mem.eql(u8, m.id, protected_id)) {
                    m.bodyText = "";
                    m.bodyHtml = null;
                    m.bodyCached = false;
                    m.bodyCacheError = "";
                    removed = true;
                    break;
                }
            }
            if (!removed and next.contacts.len > 0) {
                next.contacts = &.{};
                next.contacts_loaded = false;
                next.contact_warnings = .{};
                removed = true;
            }
            if (!removed and next.messages.len > 1) {
                var row = next.messages.len;
                while (row > 0) {
                    row -= 1;
                    if (!std.mem.eql(u8, next.messages[row].id, protected_id)) {
                        std.mem.copyForwards(types.Message, next.messages[row .. next.messages.len - 1], next.messages[row + 1 ..]);
                        next.messages = next.messages[0 .. next.messages.len - 1];
                        removed = true;
                        break;
                    }
                }
            }
            if (!removed) return error.BrowserCacheQuotaExceeded;
        }
        next.revision = self.entries[index].revision +% 1;
        self.entries[index].arena.deinit();
        self.entries[index] = next.*;
    }
    pub fn replaceList(self: *Store, index: usize, values: []const j.Value, updated_at: i64) !void {
        return self.replaceView(index, values, updated_at, "", false);
    }
    /// A complete, unfiltered provider folder enumerates membership exactly.
    /// Reconcile that known label while retaining bodies for other cached views.
    /// An incomplete head never proves an older message has left its folder.
    pub fn replaceView(self: *Store, index: usize, values: []const j.Value, updated_at: i64, label: []const u8, complete: bool) !void {
        if (values.len > 30 or updated_at < 0 or updated_at > 253402300800000) return error.InvalidBrowserCache;
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        const a = next.arena.allocator();
        const incoming = try a.alloc(types.Message, values.len);
        var verified_complete = complete;
        for (values, incoming, 0..) |value, *dest, row| {
            var parsed = try std.json.parseFromValueLeaky(types.Message, a, value, .{ .ignore_unknown_fields = true });
            for (incoming[0..row]) |old| if (std.mem.eql(u8, old.id, parsed.id)) return error.InvalidBrowserCache;
            verified_complete = verified_complete and !parsed.metadataPartial and parsed.labelsVerified;
            for (self.entries[index].messages) |old| if (std.mem.eql(u8, old.id, parsed.id)) {
                // This list-wide allowance omitted a decoded projection. It
                // says nothing new about a retained envelope or body.
                if (metadataOmitted(parsed) and std.mem.eql(u8, old.threadId, parsed.threadId)) {
                    const labels = parsed.labels;
                    const unread = parsed.unread;
                    const labels_verified = parsed.labelsVerified;
                    parsed = old;
                    parsed.metadataPartial = true;
                    parsed.labelsVerified = labels_verified;
                    if (labels_verified) {
                        parsed.labels = labels;
                        parsed.unread = unread;
                    }
                    if (!finalBodyRefusal(old.bodyCacheError)) parsed.decodeWarning = "MetadataBudgetExceeded";
                    break;
                }
                // A failed projection cannot prove that labels or ordering
                // changed. Keep prior membership marked as unverified.
                if (!parsed.labelsVerified) {
                    parsed.labels = old.labels;
                    parsed.unread = old.unread;
                }
                if (parsed.metadataPartial and parsed.receivedAt == 0) parsed.receivedAt = old.receivedAt;
                if ((!old.bodyCached and !finalBodyRefusal(old.bodyCacheError)) or !std.mem.eql(u8, old.threadId, parsed.threadId)) break;
                parsed.bodyText = old.bodyText;
                parsed.bodyHtml = old.bodyHtml;
                parsed.bodySource = old.bodySource;
                parsed.bodyHtmlAmbiguous = old.bodyHtmlAmbiguous;
                parsed.bodyCached = old.bodyCached;
                parsed.bodyCacheError = old.bodyCacheError;
                // A complete later metadata response clears the list-wide
                // allowance warning, while final body refusals stay visible.
                if (!metadataOmitted(old)) {
                    if (parsed.decodeWarning.len == 0) parsed.decodeWarning = old.decodeWarning;
                    parsed.metadataPartial = parsed.metadataPartial or old.metadataPartial;
                }
                parsed.attachments = old.attachments;
                parsed.messageId = old.messageId;
                parsed.references = old.references;
                parsed.inReplyTo = old.inReplyTo;
                break;
            };
            dest.* = try copyMessage(a, parsed);
        }
        const messages = try a.alloc(types.Message, @min(@as(usize, 300), incoming.len + next.messages.len));
        @memcpy(messages[0..incoming.len], incoming);
        var count = incoming.len;
        for (next.messages) |old| {
            var found = false;
            for (incoming) |fresh| if (std.mem.eql(u8, fresh.id, old.id)) {
                found = true;
                break;
            };
            if (!found and count < messages.len) {
                var retained_message = old;
                if (verified_complete and label.len > 0) {
                    var labels: std.ArrayList([]const u8) = .empty;
                    for (old.labels) |previous| if (!std.mem.eql(u8, previous, label)) try labels.append(a, previous);
                    retained_message.labels = labels.items;
                    if (std.mem.eql(u8, label, "UNREAD")) retained_message.unread = false;
                }
                messages[count] = retained_message;
                count += 1;
            }
        }
        next.messages = messages[0..count];
        next.updated_at = updated_at;
        try self.commit(index, &next, "");
    }
    pub fn saveRead(self: *Store, index: usize, message: types.Message) !void {
        if (index >= 3 or self.bindings[index] == null) return error.InvalidBrowserCache;
        try validateMessage(message);
        // A thread allowance describes this aggregate response, not the
        // individual message. It cannot replace a body or final decode result,
        // or reduce richer retained metadata to the small thread placeholder.
        if (transientBodyError(message.bodyCacheError)) {
            for (self.entries[index].messages) |old| if (std.mem.eql(u8, old.id, message.id)) {
                if (!message.labelsVerified or !std.mem.eql(u8, old.threadId, message.threadId)) return;
                var next = try self.copyEntry(index);
                errdefer next.arena.deinit();
                for (next.messages) |*stored| if (std.mem.eql(u8, stored.id, message.id)) {
                    const labels = try next.arena.allocator().alloc([]const u8, message.labels.len);
                    for (message.labels, labels) |label, *out| out.* = try next.arena.allocator().dupe(u8, label);
                    stored.labels = labels;
                    stored.labelsVerified = true;
                    stored.unread = message.unread;
                    break;
                };
                try self.commit(index, &next, message.id);
                return;
            };
        }
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        for (next.messages) |*stored| if (std.mem.eql(u8, stored.id, message.id)) {
            var refreshed = message;
            if (!refreshed.labelsVerified) {
                refreshed.labels = stored.labels;
                refreshed.unread = stored.unread;
            }
            if (refreshed.metadataPartial and refreshed.receivedAt == 0) refreshed.receivedAt = stored.receivedAt;
            stored.* = try copyMessage(next.arena.allocator(), refreshed);
            stored.bodyCached = message.bodyCacheError.len == 0;
            try self.commit(index, &next, message.id);
            return;
        };
        const messages = try next.arena.allocator().alloc(types.Message, @min(@as(usize, 300), next.messages.len + 1));
        messages[0] = try copyMessage(next.arena.allocator(), message);
        messages[0].bodyCached = message.bodyCacheError.len == 0;
        @memcpy(messages[1..], next.messages[0 .. messages.len - 1]);
        next.messages = messages;
        try self.commit(index, &next, message.id);
    }
    pub fn replaceContacts(self: *Store, index: usize, values: []const j.Value) !void {
        return self.replaceContactPage(index, values, .{});
    }
    pub fn replaceContactPage(self: *Store, index: usize, values: []const j.Value, warnings: types.ContactReadWarnings) !void {
        if (values.len > 100) return error.InvalidBrowserCache;
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        const a = next.arena.allocator();
        next.contacts = try a.alloc(types.Contact, values.len);
        for (values, next.contacts, 0..) |value, *dest, row| {
            dest.* = try copyContact(a, try std.json.parseFromValueLeaky(types.Contact, a, value, .{ .ignore_unknown_fields = true }));
            for (next.contacts[0..row]) |old| if (std.mem.eql(u8, old.resourceName, dest.resourceName)) return error.InvalidBrowserCache;
        }
        next.contacts_loaded = true;
        next.contact_warnings = warnings;
        try self.commit(index, &next, "");
    }
    pub fn dropContacts(self: *Store, index: usize) !void {
        if (index >= 3) return error.InvalidBrowserCache;
        if (!self.entries[index].contacts_loaded and self.entries[index].contacts.len == 0) return;
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        next.contacts = &.{};
        next.contacts_loaded = false;
        next.contact_warnings = .{};
        try self.commit(index, &next, "");
    }
    pub fn read(self: *const Store, index: usize, id: []const u8) !?types.Message {
        if (index >= 3) return error.InvalidBrowserCache;
        for (self.entries[index].messages) |m| if (!transientBodyError(m.bodyCacheError) and (m.bodyCached or finalBodyRefusal(m.bodyCacheError)) and std.mem.eql(u8, m.id, id)) return m;
        return null;
    }
    pub fn contacts(self: *const Store, index: usize, a: std.mem.Allocator) ![]const j.Value {
        if (index >= 3) return error.InvalidBrowserCache;
        const result = try a.alloc(j.Value, self.entries[index].contacts.len);
        for (self.entries[index].contacts, result) |c, *dest| dest.* = try j.value(a, Contact{ .resourceName = c.resourceName, .etag = c.etag, .name = c.name, .emails = c.emails, .readWarnings = c.readWarnings });
        return result;
    }
    pub fn list(self: *const Store, index: usize, a: std.mem.Allocator, label: []const u8, needle: []const u8) ![]const j.Value {
        const values = try self.listAll(index, a, label, needle);
        return values[0..@min(values.len, 30)];
    }
    pub fn listAll(self: *const Store, index: usize, a: std.mem.Allocator, label: []const u8, needle: []const u8) ![]const j.Value {
        return self.listAllScoped(index, a, label, needle, &.{});
    }
    /// IDs returned by a scoped provider list certify only that view's
    /// membership. They do not make a failed per-message label set complete.
    pub fn listAllScoped(self: *const Store, index: usize, a: std.mem.Allocator, label: []const u8, needle: []const u8, scoped_ids: []const []const u8) ![]const j.Value {
        if (index >= 3) return error.InvalidBrowserCache;
        try query.validate(needle);
        var matches: std.ArrayList(types.Message) = .empty;
        for (self.entries[index].messages) |m| {
            const matches_label = if (std.mem.eql(u8, label, "ARCHIVE"))
                m.labelsVerified and !hasLabel(m, "INBOX") and !hasLabel(m, "SENT") and !hasLabel(m, "TRASH") and !hasLabel(m, "SPAM")
            else if (std.mem.eql(u8, label, "UNREAD"))
                m.unread
            else
                label.len == 0 or hasLabel(m, label);
            var scoped = false;
            if (!m.labelsVerified) for (scoped_ids) |id| {
                if (std.mem.eql(u8, id, m.id)) {
                    scoped = true;
                    break;
                }
            };
            if (!matches_label and !scoped) continue;
            if (needle.len > 0 and !query.matches(m, needle)) continue;
            try matches.append(a, m);
        }
        std.mem.sort(types.Message, matches.items, {}, struct {
            fn less(_: void, left: types.Message, right: types.Message) bool {
                return left.receivedAt > right.receivedAt;
            }
        }.less);
        var result: std.ArrayList(j.Value) = .empty;
        for (matches.items) |message| try result.append(a, try j.value(a, message));
        return result.toOwnedSlice(a);
    }
    pub fn snapshot(self: *Store, index: usize, output: []u8) ![]u8 {
        if (!self.valid(index)) return error.BrowserCacheEmpty;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const doc = try self.document(index, &self.entries[index], scratch.allocator());
        var writer: std.Io.Writer = .fixed(output);
        try std.json.Stringify.value(doc, .{}, &writer);
        return output[0..writer.end];
    }
    pub fn restore(self: *Store, index: usize, bytes: []const u8, can_contacts: bool) !void {
        if (index >= 3 or bytes.len == 0 or bytes.len > snapshot_limit) return error.InvalidBrowserCache;
        const binding = self.bindings[index] orelse return error.InvalidBrowserCache;
        var next: Entry = .{ .arena = .init(self.allocator), .loaded = true };
        errdefer next.arena.deinit();
        const a = next.arena.allocator();
        const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
        if (doc.version != 1 or !std.mem.eql(u8, doc.account, binding.account) or !std.mem.eql(u8, doc.clientId, binding.clientId) or !std.mem.eql(u8, doc.grantId, binding.grantId) or doc.messages.len > 300 or doc.contacts.len > 100 or doc.updatedAt < 0 or doc.updatedAt > 253402300800000 or (!doc.contactsLoaded and doc.contacts.len > 0)) return error.InvalidBrowserCache;
        for (doc.contacts, 0..) |contact_value, row| for (doc.contacts[0..row]) |old| if (std.mem.eql(u8, old.resourceName, contact_value.resourceName)) return error.InvalidBrowserCache;
        next.messages = try a.alloc(types.Message, doc.messages.len);
        for (doc.messages, next.messages, 0..) |m, *dest, row| {
            for (doc.messages[0..row]) |old| if (std.mem.eql(u8, old.id, m.id)) return error.InvalidBrowserCache;
            const files = try a.alloc(types.Attachment, m.attachments.len);
            for (m.attachments, files) |file, *target| target.* = .{ .id = file.id, .filename = file.filename, .mimeType = file.mimeType, .size = file.size, .contentId = file.contentId, .disposition = file.disposition, .contentLocation = file.contentLocation };
            dest.* = try copyMessage(a, .{ .id = m.id, .threadId = m.threadId, .from = m.from, .replyTo = m.replyTo, .to = m.to, .cc = m.cc, .subject = m.subject, .snippet = m.snippet, .bodyText = m.bodyText, .bodyHtml = m.bodyHtml, .bodyHtmlAmbiguous = m.bodyHtmlAmbiguous, .bodySource = m.bodySource, .messageId = m.messageId, .references = m.references, .inReplyTo = m.inReplyTo, .labels = m.labels, .receivedAt = m.receivedAt, .sentDate = m.sentDate, .unread = m.unread, .bodyCached = m.bodyCached, .bodyCacheError = m.bodyCacheError, .decodeWarning = m.decodeWarning, .metadataPartial = m.metadataPartial, .labelsVerified = m.labelsVerified, .attachments = files });
            // Restore only changes retry eligibility; it never fetches mail.
            // Keep the prior display and membership until a successful read.
            if (doc.decoderRevision < decoder_policy.decoder_revision and decoder_policy.knownDecoderRefusal(dest.bodyCacheError) and decoder_policy.retriedByNewerDecoder(dest.bodyCacheError, doc.decoderRevision)) {
                dest.bodyCacheError = "";
                dest.bodyCached = false;
            }
        }
        if (can_contacts and doc.contactsLoaded) {
            next.contacts = try a.alloc(types.Contact, doc.contacts.len);
            for (doc.contacts, next.contacts) |c, *dest| dest.* = try copyContact(a, .{ .resourceName = c.resourceName, .etag = c.etag, .name = c.name, .emails = c.emails, .readWarnings = c.readWarnings });
            next.contacts_loaded = true;
            next.contact_warnings = doc.contactWarnings;
        }
        next.updated_at = doc.updatedAt;
        // An older application must not downgrade a newer snapshot's receipt.
        next.decoder_revision = @max(doc.decoderRevision, decoder_policy.decoder_revision);
        try self.commit(index, &next, "");
    }
};
fn hasLabel(message: types.Message, label: []const u8) bool {
    for (message.labels) |value| if (std.mem.eql(u8, value, label)) return true;
    return false;
}

pub fn transientBodyError(code: []const u8) bool {
    return std.mem.eql(u8, code, "BodyNotCached") or std.mem.eql(u8, code, "ThreadBodyBudgetExceeded");
}
fn finalBodyRefusal(code: []const u8) bool {
    return code.len > 0 and !transientBodyError(code);
}
fn metadataOmitted(message: types.Message) bool {
    return message.bodyCacheError.len == 0 and std.mem.eql(u8, message.decodeWarning, "MetadataBudgetExceeded");
}
