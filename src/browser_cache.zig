//! Bounded, account/grant-scoped mail snapshots. Browser persistence transports
//! this schema; credentials, draft state and native file handles never enter it.
const std = @import("std");
const types = @import("terminal/types.zig");
const j = @import("terminal/json.zig");
const recipients = @import("terminal/recipients.zig");
const query = @import("terminal/cache_query.zig");
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
    attachments: []const Attachment = &.{},
};
const Contact = struct { resourceName: []const u8 = "", etag: []const u8 = "", name: []const u8 = "", emails: []const types.Address = &.{} };
const Document = struct { version: u8, account: []const u8, clientId: []const u8, grantId: []const u8, updatedAt: i64, messages: []Message, contacts: []Contact, contactsLoaded: bool };
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    messages: []types.Message = &.{},
    contacts: []types.Contact = &.{},
    contacts_loaded: bool = false,
    updated_at: i64 = 0,
    loaded: bool = false,
    bytes: usize = 0,
    revision: u32 = 0,
};
fn bounded(value: []const u8, limit: usize) !void {
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return error.InvalidBrowserCache;
}
fn address(value: types.Address) !void {
    try bounded(value.name, 4096);
    try bounded(value.address, 254);
    if (value.address.len > 0) try recipients.validateAddress(value.address);
}
fn addresses(values: []const types.Address) !void {
    if (values.len > 1024) return error.InvalidBrowserCache;
    for (values) |value| try address(value);
}
fn validateMessage(value: types.Message) !void {
    if (value.id.len == 0 or value.attachments.len > 49 or value.labels.len > 128) return error.InvalidBrowserCache;
    try bounded(value.id, 128);
    try bounded(value.threadId, 128);
    try address(value.from);
    try addresses(value.to);
    try addresses(value.cc);
    try addresses(value.replyTo);
    try bounded(value.subject, 16 * 1024);
    try bounded(value.snippet, 16 * 1024);
    try bounded(value.bodyText, 2 * 1024 * 1024);
    if (value.bodyHtml) |html| try bounded(html, 2 * 1024 * 1024);
    try bounded(value.messageId, 4096);
    try bounded(value.references, 64 * 1024);
    try bounded(value.inReplyTo, 4096);
    try bounded(value.bodyCacheError, 512);
    for (value.labels) |label| try bounded(label, 256);
    for (value.attachments) |file| {
        try bounded(file.id, 4096);
        try bounded(file.filename, 4096);
        try bounded(file.mimeType, 256);
        if (file.contentId) |id| try bounded(id, 1024);
        if (file.disposition) |kind| try bounded(kind, 32);
        if (file.contentLocation) |location| try bounded(location, 4096);
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
    inline for (.{ "id", "threadId", "subject", "snippet", "bodyText", "messageId", "references", "inReplyTo", "bodyCacheError" }) |field| @field(result, field) = try a.dupe(u8, @field(value, field));
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
    return result;
}
fn copyContact(a: std.mem.Allocator, value: types.Contact) !types.Contact {
    try bounded(value.resourceName, 256);
    try bounded(value.etag, 4096);
    try bounded(value.name, 4096);
    try addresses(value.emails);
    return .{ .resourceName = try a.dupe(u8, value.resourceName), .etag = try a.dupe(u8, value.etag), .name = try a.dupe(u8, value.name), .emails = try copyAddresses(a, value.emails) };
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
    pub fn updatedAt(self: *const Store, index: usize) i64 {
        return if (index < 3) self.entries[index].updated_at else 0;
    }
    /// Borrowed current inventory, for local recipient building and bounded
    /// native-protocol pagination. It never includes historical snapshots.
    pub fn retained(self: *const Store, index: usize) []const types.Message {
        return if (index < 3) self.entries[index].messages else &.{};
    }
    fn copyEntry(self: *Store, index: usize) !Entry {
        if (index >= 3 or self.bindings[index] == null) return error.InvalidBrowserCache;
        var next: Entry = .{ .arena = .init(self.allocator), .updated_at = self.entries[index].updated_at, .loaded = true, .contacts_loaded = self.entries[index].contacts_loaded };
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
            dest.* = .{ .id = m.id, .threadId = m.threadId, .from = m.from, .replyTo = m.replyTo, .to = m.to, .cc = m.cc, .subject = m.subject, .snippet = m.snippet, .bodyText = m.bodyText, .bodyHtml = m.bodyHtml, .bodyHtmlAmbiguous = m.bodyHtmlAmbiguous, .bodySource = m.bodySource, .messageId = m.messageId, .references = m.references, .inReplyTo = m.inReplyTo, .labels = m.labels, .receivedAt = m.receivedAt, .sentDate = m.sentDate, .unread = m.unread, .bodyCached = m.bodyCached, .bodyCacheError = m.bodyCacheError, .attachments = files };
        }
        const contact_values = try a.alloc(Contact, entry.contacts.len);
        for (entry.contacts, contact_values) |c, *dest| dest.* = .{ .resourceName = c.resourceName, .etag = c.etag, .name = c.name, .emails = c.emails };
        return .{ .version = 1, .account = binding.account, .clientId = binding.clientId, .grantId = binding.grantId, .updatedAt = entry.updated_at, .messages = messages, .contacts = contact_values, .contactsLoaded = entry.contacts_loaded };
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
        for (values, incoming, 0..) |value, *dest, row| {
            var parsed = try std.json.parseFromValueLeaky(types.Message, a, value, .{ .ignore_unknown_fields = true });
            for (incoming[0..row]) |old| if (std.mem.eql(u8, old.id, parsed.id)) return error.InvalidBrowserCache;
            for (self.entries[index].messages) |old| if (old.bodyCached and std.mem.eql(u8, old.id, parsed.id) and std.mem.eql(u8, old.threadId, parsed.threadId)) {
                parsed.bodyText = old.bodyText;
                parsed.bodyHtml = old.bodyHtml;
                parsed.bodySource = old.bodySource;
                parsed.bodyHtmlAmbiguous = old.bodyHtmlAmbiguous;
                parsed.bodyCached = true;
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
                if (complete and label.len > 0) {
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
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        for (next.messages) |*stored| if (std.mem.eql(u8, stored.id, message.id)) {
            stored.* = try copyMessage(next.arena.allocator(), message);
            stored.bodyCached = true;
            try self.commit(index, &next, message.id);
            return;
        };
        const messages = try next.arena.allocator().alloc(types.Message, @min(@as(usize, 300), next.messages.len + 1));
        messages[0] = try copyMessage(next.arena.allocator(), message);
        messages[0].bodyCached = true;
        @memcpy(messages[1..], next.messages[0 .. messages.len - 1]);
        next.messages = messages;
        try self.commit(index, &next, message.id);
    }
    pub fn replaceContacts(self: *Store, index: usize, values: []const j.Value) !void {
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
        try self.commit(index, &next, "");
    }
    pub fn dropContacts(self: *Store, index: usize) !void {
        if (index >= 3) return error.InvalidBrowserCache;
        if (!self.entries[index].contacts_loaded and self.entries[index].contacts.len == 0) return;
        var next = try self.copyEntry(index);
        errdefer next.arena.deinit();
        next.contacts = &.{};
        next.contacts_loaded = false;
        try self.commit(index, &next, "");
    }
    pub fn read(self: *const Store, index: usize, id: []const u8) !?types.Message {
        if (index >= 3) return error.InvalidBrowserCache;
        for (self.entries[index].messages) |m| if (m.bodyCached and std.mem.eql(u8, m.id, id)) return m;
        return null;
    }
    pub fn contacts(self: *const Store, index: usize, a: std.mem.Allocator) ![]const j.Value {
        if (index >= 3) return error.InvalidBrowserCache;
        const result = try a.alloc(j.Value, self.entries[index].contacts.len);
        for (self.entries[index].contacts, result) |c, *dest| dest.* = try j.value(a, Contact{ .resourceName = c.resourceName, .etag = c.etag, .name = c.name, .emails = c.emails });
        return result;
    }
    pub fn list(self: *const Store, index: usize, a: std.mem.Allocator, label: []const u8, needle: []const u8) ![]const j.Value {
        const values = try self.listAll(index, a, label, needle);
        return values[0..@min(values.len, 30)];
    }
    pub fn listAll(self: *const Store, index: usize, a: std.mem.Allocator, label: []const u8, needle: []const u8) ![]const j.Value {
        if (index >= 3) return error.InvalidBrowserCache;
        try query.validate(needle);
        var matches: std.ArrayList(types.Message) = .empty;
        for (self.entries[index].messages) |m| {
            if (std.mem.eql(u8, label, "ARCHIVE")) {
                if (hasLabel(m, "INBOX") or hasLabel(m, "SENT") or hasLabel(m, "TRASH") or hasLabel(m, "SPAM")) continue;
            } else if (std.mem.eql(u8, label, "UNREAD")) {
                if (!m.unread) continue;
            } else if (label.len > 0 and !hasLabel(m, label)) continue;
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
            dest.* = try copyMessage(a, .{ .id = m.id, .threadId = m.threadId, .from = m.from, .replyTo = m.replyTo, .to = m.to, .cc = m.cc, .subject = m.subject, .snippet = m.snippet, .bodyText = m.bodyText, .bodyHtml = m.bodyHtml, .bodyHtmlAmbiguous = m.bodyHtmlAmbiguous, .bodySource = m.bodySource, .messageId = m.messageId, .references = m.references, .inReplyTo = m.inReplyTo, .labels = m.labels, .receivedAt = m.receivedAt, .sentDate = m.sentDate, .unread = m.unread, .bodyCached = m.bodyCached, .bodyCacheError = m.bodyCacheError, .attachments = files });
        }
        if (can_contacts and doc.contactsLoaded) {
            next.contacts = try a.alloc(types.Contact, doc.contacts.len);
            for (doc.contacts, next.contacts) |c, *dest| dest.* = try copyContact(a, .{ .resourceName = c.resourceName, .etag = c.etag, .name = c.name, .emails = c.emails });
            next.contacts_loaded = true;
        }
        next.updated_at = doc.updatedAt;
        try self.commit(index, &next, "");
    }
};
fn hasLabel(message: types.Message, label: []const u8) bool {
    for (message.labels) |value| if (std.mem.eql(u8, value, label)) return true;
    return false;
}
