//! Bounded, account-local projection of known mail participants and contacts.
//! This reads retained metadata only; it never fetches bodies or other contacts.
const std = @import("std");
const t = @import("types.zig");
const recipients = @import("recipients.zig");
pub const max_candidates = 1024;
// At capacity, saved contacts may occupy a quarter of the projection. This
// keeps ordinary recent correspondents useful even with a large address book.
const reserved_contacts = max_candidates / 4;
const Known = struct { value: t.Address, recent: i64, saved: bool = false };
pub const Builder = struct {
    allocator: std.mem.Allocator,
    self_address: []const u8,
    self_aliases: []const []const u8 = &.{},
    known: std.ArrayList(Known) = .empty,
    indexes: std.StringHashMap(usize),
    saved_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, self_address: []const u8) Builder {
        return .{ .allocator = allocator, .self_address = self_address, .indexes = .init(allocator) };
    }
    pub fn deinit(self: *Builder) void {
        self.known.deinit(self.allocator);
        var keys = self.indexes.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.indexes.deinit();
    }
    fn add(self: *Builder, address: t.Address, recent: i64, saved: bool) !void {
        recipients.validateAddress(address.address) catch return;
        if (std.ascii.eqlIgnoreCase(address.address, self.self_address)) return;
        for (self.self_aliases) |alias| if (std.ascii.eqlIgnoreCase(address.address, alias)) return;
        var normalized: [254]u8 = undefined;
        if (address.address.len > normalized.len) return;
        const key = std.ascii.lowerString(normalized[0..address.address.len], address.address);
        const name = if (address.name.len <= 256) name: {
            recipients.validateHeader(address.name) catch break :name "";
            break :name address.name;
        } else "";
        if (self.indexes.get(key)) |index| {
            const entry = &self.known.items[index];
            entry.recent = @max(entry.recent, recent);
            if (name.len != 0 and (saved or entry.value.name.len == 0)) entry.value.name = name;
            if (saved and !entry.saved) self.saved_count += 1;
            entry.saved = entry.saved or saved;
            self.siftDown(index);
            return;
        }
        const candidate: Known = .{ .value = .{ .address = address.address, .name = name }, .recent = recent, .saved = saved };
        const full = self.known.items.len == max_candidates;
        if (full and ((saved and self.saved_count >= reserved_contacts) or !preferred(candidate, self.known.items[0]))) return;
        if (!full) try self.known.ensureUnusedCapacity(self.allocator, 1);
        const retained_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(retained_key);
        try self.indexes.put(retained_key, if (full) 0 else self.known.items.len);
        if (full) {
            var previous_key: [254]u8 = undefined;
            const removed = self.indexes.fetchRemove(std.ascii.lowerString(previous_key[0..self.known.items[0].value.address.len], self.known.items[0].value.address)).?;
            self.allocator.free(removed.key);
            if (self.known.items[0].saved) self.saved_count -= 1;
            self.known.items[0] = candidate;
            self.siftDown(0);
        } else {
            self.known.appendAssumeCapacity(candidate);
            self.siftUp(self.known.items.len - 1);
        }
        if (saved) self.saved_count += 1;
    }
    // A bounded min-heap makes newest retention independent of source order
    // (the synthetic outbox is appended chronologically) without quadratic
    // rescans when many newer participants arrive after the cache head.
    fn preferred(a: Known, b: Known) bool {
        if (a.saved != b.saved) return a.saved;
        return newer({}, a, b);
    }
    fn swap(self: *Builder, left: usize, right: usize) void {
        std.mem.swap(Known, &self.known.items[left], &self.known.items[right]);
        var key: [254]u8 = undefined;
        for ([_]usize{ left, right }) |index| {
            const address = self.known.items[index].value.address;
            self.indexes.getPtr(std.ascii.lowerString(key[0..address.len], address)).?.* = index;
        }
    }
    fn siftUp(self: *Builder, initial: usize) void {
        var index = initial;
        while (index != 0) {
            const parent = (index - 1) / 2;
            if (!preferred(self.known.items[parent], self.known.items[index])) return;
            self.swap(parent, index);
            index = parent;
        }
    }
    fn siftDown(self: *Builder, initial: usize) void {
        var index = initial;
        while (index * 2 + 1 < self.known.items.len) {
            var child = index * 2 + 1;
            if (child + 1 < self.known.items.len and preferred(self.known.items[child], self.known.items[child + 1])) child += 1;
            if (!preferred(self.known.items[index], self.known.items[child])) return;
            self.swap(index, child);
            index = child;
        }
    }
    pub fn mail(self: *Builder, message: t.Message) !void {
        try self.add(message.from, message.receivedAt, false);
        // Incoming Bcc must never turn into a recipient suggestion. Limit
        // broad address headers while keeping From and ordinary To/Cc useful.
        for (message.to[0..@min(message.to.len, 32)]) |address| try self.add(address, message.receivedAt, false);
        for (message.cc[0..@min(message.cc.len, 32)]) |address| try self.add(address, message.receivedAt, false);
    }
    pub fn contact(self: *Builder, value: t.Contact) !void {
        for (value.emails[0..@min(value.emails.len, 32)]) |address| try self.add(.{ .address = address.address, .name = value.name }, 0, true);
    }
    fn newer(_: void, a: Known, b: Known) bool {
        if (a.recent != b.recent) return a.recent > b.recent;
        if (a.saved != b.saved) return a.saved;
        return std.ascii.lessThanIgnoreCase(a.value.address, b.value.address);
    }
    pub fn result(self: *Builder) ![]const t.Address {
        std.mem.sort(Known, self.known.items, {}, newer);
        const values = try self.allocator.alloc(t.Address, self.known.items.len);
        for (self.known.items, values) |entry, *value| value.* = entry.value;
        return values;
    }
};

test "recipient cache: unsaved From To Cc correspondents are recent deduplicated and exclude self" {
    var builder = Builder.init(std.testing.allocator, "self@example.test");
    defer builder.deinit();
    try builder.mail(.{ .id = "old", .threadId = "old", .from = .{ .address = "caroline@example.test", .name = "Caroline Composer" }, .to = &.{.{ .address = "self@example.test" }}, .receivedAt = 10 });
    try builder.mail(.{ .id = "sent", .threadId = "sent", .from = .{ .address = "self@example.test" }, .to = &.{.{ .address = "new@example.test", .name = "New Correspondent" }}, .cc = &.{.{ .address = "CAROLINE@example.test" }}, .receivedAt = 30 });
    try builder.contact(.{ .name = "Caroline Saved", .emails = &.{.{ .address = "caroline@example.test" }} });
    const values = try builder.result();
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("caroline@example.test", values[0].address);
    try std.testing.expectEqualStrings("Caroline Saved", values[0].name);
    try std.testing.expectEqualStrings("new@example.test", values[1].address);
}

test "recipient cache: newest capped correspondents survive outbox order and saved contacts have bounded room" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var builder = Builder.init(a, "self@example.test");
    defer builder.deinit();
    for (0..1024) |index| try builder.mail(.{
        .id = "cached",
        .threadId = "cached",
        .from = .{ .address = try std.fmt.allocPrint(a, "peer-{d}@example.test", .{index}) },
        .receivedAt = @intCast(index + 1),
    });
    // An outbox recipient arrives after the retained cache's entire cap.
    try builder.mail(.{ .id = "sent", .threadId = "sent", .from = .{ .address = "self@example.test" }, .to = &.{.{ .address = "new-outbox@example.test" }}, .receivedAt = 10000 });
    try builder.mail(.{ .id = "ancient", .threadId = "ancient", .from = .{ .address = "ancient@example.test" }, .receivedAt = 0 });
    for (0..300) |index| try builder.contact(.{ .name = "Saved", .emails = &.{.{ .address = try std.fmt.allocPrint(a, "saved-{d}@example.test", .{index}) }} });
    const result = try builder.result();
    try std.testing.expectEqual(@as(usize, 1024), result.len);
    try std.testing.expectEqualStrings("new-outbox@example.test", result[0].address);
    var saved: usize = 0;
    var oldest_peer: ?usize = null;
    for (result) |value| {
        try std.testing.expect(!std.mem.eql(u8, value.address, "ancient@example.test"));
        if (std.mem.startsWith(u8, value.address, "saved-")) saved += 1;
        if (std.mem.startsWith(u8, value.address, "peer-")) {
            const end = std.mem.indexOfScalar(u8, value.address, '@').?;
            const index = try std.fmt.parseInt(usize, value.address[5..end], 10);
            oldest_peer = if (oldest_peer) |old| @min(old, index) else index;
        }
    }
    try std.testing.expectEqual(@as(usize, 256), saved);
    try std.testing.expectEqual(@as(?usize, 257), oldest_peer);
}
