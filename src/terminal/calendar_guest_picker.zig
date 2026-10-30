//! Account-bound Calendar guest projection over saved contacts, an explicit
//! bounded Contacts search and the local recent-mail recipient cache.
//! Choosing an address appends a bare email; it never replaces existing
//! guests or alters notification policy.
const std = @import("std");
const composer = @import("calendar_composer.zig");
const recipients = @import("recipients.zig");
const Value = std.json.Value;
pub const max_candidates = 1024;
pub const Source = enum { contact, recent };
pub const Candidate = struct { name: []const u8, address: []const u8, source: Source = .contact };
/// Mail Contacts' interpretation of a successful but partial read.
pub const Warnings = @import("types.zig").ContactReadWarnings;

fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn text(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn includes(value: []const u8, query: []const u8) bool {
    if (query.len > value.len) return false;
    for (0..value.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(value[i..][0..query.len], query)) return true;
    return false;
}
fn safeName(raw: []const u8) []const u8 {
    if (raw.len > 512) return "";
    recipients.validateHeader(raw) catch return "";
    return raw;
}
/// Appends one matching address unless it is already listed; returns true
/// once the bounded projection is full.
fn push(a: std.mem.Allocator, out: *std.ArrayList(Candidate), name: []const u8, address: []const u8, source: Source, filter: ?[]const u8) !bool {
    if (!validAddress(address)) return false;
    if (filter) |query| if (!includes(name, query) and !includes(address, query)) return false;
    for (out.items) |entry| if (std.ascii.eqlIgnoreCase(entry.address, address)) return false;
    try out.append(a, .{ .name = name, .address = address, .source = source });
    return out.items.len >= max_candidates;
}
fn contactItems(response: Value) ![]const Value {
    const contacts = field(response, "contacts");
    if (contacts != .array or contacts.array.items.len > max_candidates) return error.InvalidContactsResponse;
    return contacts.array.items;
}
fn recentItems(response: Value) ![]const Value {
    const values = field(response, "recipients");
    if (values != .array or values.array.items.len > max_candidates) return error.InvalidRecipientCandidates;
    return values.array.items;
}
/// Validates a contacts.list or contacts.search result and projects its addresses.
pub fn collect(a: std.mem.Allocator, response: Value, query: []const u8) ![]const Candidate {
    return combine(a, response, .null, .null, query);
}
/// What a successful contacts read says about its own completeness. `partial`
/// marks omitted or incompletely read provider records, with or without
/// counts; an ordinary next page (`nextCursor`) is a bounded head, not partial.
pub const ReadState = struct {
    warnings: Warnings = .{},
    partial: bool = false,
    pub fn incomplete(self: ReadState) bool {
        return self.partial or self.warnings.any();
    }
    /// Counts the picker can name; other warnings get generic partial text.
    pub fn counted(self: ReadState) bool {
        return self.warnings.omittedContacts > 0 or self.warnings.partialContacts > 0;
    }
    /// The head and search can report the same records. Keep the larger
    /// count per field rather than claim a distinct total across both reads.
    pub fn merge(self: *ReadState, other: ReadState) void {
        inline for (@typeInfo(Warnings).@"struct".field_names) |name|
            @field(self.warnings, name) = @max(@field(self.warnings, name), @field(other.warnings, name));
        self.partial = self.partial or other.partial;
    }
};
/// Counts decode exactly as Mail Contacts does; malformed counts or a
/// non-boolean `partial` fail closed rather than look complete.
pub fn readState(a: std.mem.Allocator, response: Value) !ReadState {
    const flag = field(response, "partial");
    if (flag != .null and flag != .bool) return error.InvalidContactsResponse;
    const value = field(response, "contactWarnings");
    return .{
        .warnings = if (value == .null) .{} else try @import("json.zig").decode(Warnings, a, value),
        .partial = flag == .bool and flag.bool,
    };
}
/// Validates a cached mail.recipients result before it is kept for a picker.
pub fn validateRecent(response: Value) !void {
    _ = try recentItems(response);
}
/// Any source may be `.null` (unavailable). Recent correspondents lead and
/// keep half of the bound, so a full address book cannot starve them. An
/// explicit Contacts search comes next, so its answer is never crowded out
/// by the loaded list; saved contacts and remaining recent addresses follow.
pub fn combine(a: std.mem.Allocator, contacts: Value, recent: Value, search: Value, query: []const u8) ![]const Candidate {
    const people = if (recent == .null) &[_]Value{} else try recentItems(recent);
    const book = if (contacts == .null) &[_]Value{} else try contactItems(contacts);
    const found = if (search == .null) &[_]Value{} else try contactItems(search);
    var out: std.ArrayList(Candidate) = .empty;
    defer out.deinit(a);
    var next: usize = 0;
    while (next < people.len and out.items.len < max_candidates / 2) : (next += 1) {
        if (try push(a, &out, safeName(text(field(people[next], "name"))), text(field(people[next], "address")), .recent, query)) return out.toOwnedSlice(a);
    }
    // An admitted provider answer already matches its exact query, possibly
    // on a field absent from our display DTO. Only local sources are filtered.
    for ([_]struct { []const Value, ?[]const u8 }{ .{ found, null }, .{ book, query } }) |pass| for (pass[0]) |contact| {
        const name = safeName(text(field(contact, "name")));
        const emails = field(contact, "emails");
        if (emails != .array) continue;
        for (emails.array.items) |email| if (try push(a, &out, name, text(field(email, "address")), .contact, pass[1])) return out.toOwnedSlice(a);
    };
    for (people[next..]) |person| {
        if (try push(a, &out, safeName(text(field(person, "name"))), text(field(person, "address")), .recent, query)) break;
    }
    return out.toOwnedSlice(a);
}
fn validAddress(address: []const u8) bool {
    @import("../bounded.zig").address(address) catch return false;
    return std.mem.indexOfAny(u8, address, "<>(),;:") == null;
}
/// Guests use Mail's address-list grammar. Unfinished text falls back to its
/// comma-separated pieces (bare or `Name <email>`), so a half-typed entry
/// cannot hide an address that is already listed.
pub fn contains(raw: []const u8, address: []const u8) bool {
    const Match = struct {
        wanted: []const u8,
        found: bool = false,
        /// Public: recipients.scanAddresses calls it from another file.
        pub fn visit(self: *@This(), value: []const u8) !void {
            self.found = self.found or std.ascii.eqlIgnoreCase(value, self.wanted);
        }
    };
    var match: Match = .{ .wanted = address };
    if (recipients.scanAddresses(raw, &match)) |_| return match.found else |_| {}
    var entries = std.mem.splitScalar(u8, raw, ',');
    while (entries.next()) |entry| {
        const piece = std.mem.trim(u8, entry, " \t\r\n");
        const left = std.mem.lastIndexOfScalar(u8, piece, '<');
        const bare = if (left != null and std.mem.endsWith(u8, piece, ">")) std.mem.trim(u8, piece[left.? + 1 .. piece.len - 1], " ") else piece;
        if (std.ascii.eqlIgnoreCase(bare, address)) return true;
    }
    return false;
}
fn guestCount(raw: []const u8) usize {
    const Count = struct {
        total: usize = 0,
        pub fn visit(self: *@This(), _: []const u8) !void {
            self.total += 1;
        }
    };
    var counted: Count = .{};
    if (recipients.scanAddresses(raw, &counted)) |_| return counted.total else |_| {}
    var entries = std.mem.splitScalar(u8, raw, ',');
    var total: usize = 0;
    while (entries.next()) |entry| if (std.mem.trim(u8, entry, " \t\r\n").len > 0) {
        total += 1;
    };
    return total;
}
pub fn append(a: std.mem.Allocator, raw: []const u8, address: []const u8) !?[]const u8 {
    if (!validAddress(address)) return error.CalendarInvalidGuest;
    if (contains(raw, address)) return null;
    const trimmed = std.mem.trimEnd(u8, raw, " \t\r\n");
    const separator: []const u8 = if (trimmed.len == 0) "" else if (std.mem.endsWith(u8, trimmed, ",")) (if (raw.len == trimmed.len) " " else "") else ", ";
    if (raw.len + separator.len + address.len > composer.guest_bytes) return error.CalendarFieldTooLong;
    if (guestCount(raw) >= composer.max_guests) return error.CalendarTooManyGuests;
    // Preserve even unfinished manually typed text. The exact Review validates
    // every token before it can save or send invitations.
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ raw, separator, address });
}

test "calendar composer: address book exposes distinct safe addresses and appends without replacing existing guests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const contacts = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Alex Example","emails":[{"address":"alex@example.test"},{"address":"alex.work@example.test"},{"address":"ALEX@example.test"},{"address":"bad\n@example.test"}]},{"name":"Other","emails":[{"address":"other@example.test"}]}]}
    , .{});
    const all = try collect(a, contacts, "");
    try std.testing.expectEqual(@as(usize, 3), all.len);
    const alex = try collect(a, contacts, "ALEX");
    try std.testing.expectEqual(@as(usize, 2), alex.len);
    try std.testing.expectEqualStrings("alex.work@example.test", alex[1].address);
    const before = "host@example.test, guest@example.test, ";
    const after = (try append(a, before, alex[1].address)).?;
    try std.testing.expectEqualStrings("host@example.test, guest@example.test, alex.work@example.test", after);
    try std.testing.expect((try append(a, after, "ALEX.WORK@example.test")) == null);
    try std.testing.expectEqualStrings("unfinished, alex@example.test", (try append(a, "unfinished", alex[0].address)).?);
    try std.testing.expectError(error.CalendarInvalidGuest, append(a, "", "Alex <alex@example.test>"));
}

test "calendar composer: guest projection merges recent mail with contacts, dedups and bounds without starving recent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recent = try std.json.parseFromSliceLeaky(Value, a,
        \\{"recipients":[{"name":"Robin Recent","address":"robin.recent@example.test"},{"name":"","address":"ALEX@example.test"},{"name":"Bad","address":"Robin <x@example.test>"}]}
    , .{});
    const contacts = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Alex Example","emails":[{"address":"alex@example.test"}]}]}
    , .{});
    // Either source alone remains usable when the other is unavailable.
    try std.testing.expectEqual(@as(usize, 2), (try combine(a, .null, recent, .null, "")).len);
    try std.testing.expectEqual(@as(usize, 1), (try combine(a, contacts, .null, .null, "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try combine(a, .null, .null, .null, "")).len);
    const both = try combine(a, contacts, recent, .null, "");
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqual(Source.recent, both[0].source);
    const robin = try combine(a, contacts, recent, .null, "ROBIN");
    try std.testing.expectEqual(@as(usize, 1), robin.len);
    try std.testing.expectEqualStrings("robin.recent@example.test", robin[0].address);
    try std.testing.expectEqualStrings("typed@example.test, robin.recent@example.test", (try append(a, "typed@example.test", robin[0].address)).?);
    try std.testing.expectError(error.InvalidRecipientCandidates, validateRecent(contacts));

    // A full address book cannot push the newest correspondent off the list,
    // and the merged projection stays within the shared bound.
    var book: std.ArrayList(u8) = .empty;
    try book.appendSlice(a, "{\"contacts\":[");
    for (0..max_candidates) |index| try book.print(a, "{s}{{\"name\":\"Saved {d}\",\"emails\":[{{\"address\":\"saved{d}@example.test\"}}]}}", .{ if (index == 0) "" else ",", index, index });
    try book.appendSlice(a, "]}");
    const full = try std.json.parseFromSliceLeaky(Value, a, book.items, .{});
    const merged = try combine(a, full, recent, .null, "");
    try std.testing.expectEqual(@as(usize, max_candidates), merged.len);
    try std.testing.expectEqualStrings("robin.recent@example.test", merged[0].address);
    try std.testing.expectEqual(@as(usize, 1), (try combine(a, full, recent, .null, "robin")).len);
}

test "calendar composer: explicit Contacts search reaches a saved contact beyond the loaded head and keeps partial warnings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The loaded head: 100 unrelated contacts and a provider cursor.
    var page: std.ArrayList(u8) = .empty;
    try page.appendSlice(a, "{\"contacts\":[");
    for (0..100) |index| try page.print(a, "{s}{{\"name\":\"Unrelated {d}\",\"emails\":[{{\"address\":\"unrelated{d}@example.test\"}}]}}", .{ if (index == 0) "" else ",", index, index });
    try page.appendSlice(a, "],\"nextCursor\":\"page-2\"}");
    const head = try std.json.parseFromSliceLeaky(Value, a, page.items, .{});
    const recent = try std.json.parseFromSliceLeaky(Value, a,
        \\{"recipients":[{"name":"Robin Recent","address":"robin.recent@example.test"}]}
    , .{});
    const search = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Morgan Beyond","emails":[{"address":"morgan.beyond@example.test"}]}],"contactWarnings":{"omittedContacts":1},"partial":true}
    , .{});
    try std.testing.expectEqual(@as(usize, 0), (try combine(a, head, recent, .null, "morgan")).len);
    const found = try combine(a, head, recent, search, "morgan");
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("morgan.beyond@example.test", found[0].address);
    // Loaded and searched copies of one person are a single row.
    const overlap = try std.json.parseFromSliceLeaky(Value, a, "{\"contacts\":[{\"name\":\"Unrelated 7\",\"emails\":[{\"address\":\"UNRELATED7@example.test\"}]}]}", .{});
    try std.testing.expectEqual(@as(usize, 1), (try combine(a, head, recent, overlap, "unrelated7@")).len);
    // Local filtering must not discard a query-bound provider answer that
    // matched a nickname or another field absent from the display DTO.
    try std.testing.expectEqual(@as(usize, 2), (try combine(a, head, recent, search, "robin")).len);
    try std.testing.expectEqual(@as(usize, 102), (try combine(a, head, recent, search, "")).len);
    // A full loaded book cannot crowd out the explicit search answer.
    var book: std.ArrayList(u8) = .empty;
    try book.appendSlice(a, "{\"contacts\":[");
    for (0..max_candidates) |index| try book.print(a, "{s}{{\"name\":\"Saved {d}\",\"emails\":[{{\"address\":\"saved{d}@example.test\"}}]}}", .{ if (index == 0) "" else ",", index, index });
    try book.appendSlice(a, "]}");
    const merged = try combine(a, try std.json.parseFromSliceLeaky(Value, a, book.items, .{}), recent, search, "");
    try std.testing.expectEqual(@as(usize, max_candidates), merged.len);
    try std.testing.expectEqualStrings("morgan.beyond@example.test", merged[1].address);
    // Omission counts use Mail's warning interpretation and fail closed.
    const warned = try readState(a, search);
    try std.testing.expect(warned.incomplete() and warned.counted() and warned.warnings.omittedContacts == 1);
    // A next-page cursor is an ordinary bounded head, not omitted data.
    try std.testing.expect(!(try readState(a, head)).incomplete());
    // partial:true without counts is still partial; other counts are uncounted.
    const flagged = try readState(a, try std.json.parseFromSliceLeaky(Value, a, "{\"contacts\":[],\"partial\":true}", .{}));
    try std.testing.expect(flagged.incomplete() and !flagged.counted());
    const emails_only = try readState(a, try std.json.parseFromSliceLeaky(Value, a, "{\"contacts\":[],\"contactWarnings\":{\"omittedEmails\":2}}", .{}));
    try std.testing.expect(emails_only.incomplete() and !emails_only.counted());
    var merged_state: ReadState = .{};
    merged_state.merge(try readState(a, head));
    merged_state.merge(flagged);
    try std.testing.expect(merged_state.partial);
    const counted_state: ReadState = .{ .warnings = .{ .omittedContacts = 2, .omittedEmails = 4 } };
    merged_state.merge(counted_state);
    merged_state.merge(counted_state);
    merged_state.merge(.{ .warnings = .{ .omittedContacts = 1, .partialContacts = 3, .omittedEmails = 1 } });
    try std.testing.expect(merged_state.partial);
    try std.testing.expectEqual(@as(u32, 2), merged_state.warnings.omittedContacts);
    try std.testing.expectEqual(@as(u32, 3), merged_state.warnings.partialContacts);
    try std.testing.expectEqual(@as(u32, 4), merged_state.warnings.omittedEmails);
    for ([_][]const u8{ "{\"contactWarnings\":{\"omittedContacts\":-1}}", "{\"partial\":\"yes\"}", "{\"partial\":1}" }) |raw| {
        if (readState(a, try std.json.parseFromSliceLeaky(Value, a, raw, .{}))) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "calendar composer: provider search membership survives hidden-field matches while local sources still filter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Bobby Local","emails":[{"address":"bobby.local@example.test"}]},{"name":"Robert Smith","emails":[{"address":"rsmith@example.test"}]}]}
    , .{});
    const recent = try std.json.parseFromSliceLeaky(Value, a,
        \\{"recipients":[{"name":"Bobby Recent","address":"bobby.recent@example.test"},{"name":"Other","address":"other@example.test"}]}
    , .{});
    const search = try std.json.parseFromSliceLeaky(Value, a,
        \\{"contacts":[{"name":"Robert Smith","emails":[{"address":"rsmith@example.test"},{"address":"rsmith.work@example.test"},{"address":"BOBBY.RECENT@example.test"},{"address":"bad\n@example.test"}]},{"name":"bad\nname","emails":[{"address":"another@example.test"}]},{"name":"Missing emails"}]}
    , .{});
    const local = try combine(a, head, recent, .null, "bobby");
    try std.testing.expectEqual(@as(usize, 2), local.len);
    const found = try combine(a, head, recent, search, "bobby");
    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expectEqual(Source.recent, found[0].source);
    try std.testing.expectEqualStrings("bobby.recent@example.test", found[0].address);
    try std.testing.expectEqualStrings("rsmith@example.test", found[1].address);
    try std.testing.expectEqualStrings("rsmith.work@example.test", found[2].address);
    try std.testing.expectEqualStrings("another@example.test", found[3].address);
    try std.testing.expectEqualStrings("", found[3].name);
    try std.testing.expectEqualStrings("bobby.local@example.test", found[4].address);
}

test "calendar composer: guest picker understands names and quoted commas already in Guests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "\"Doe, Jane\" <jane@example.test>, Alex Example <alex@example.test>";
    try std.testing.expect(contains(raw, "JANE@example.test") and contains(raw, "alex@example.test"));
    try std.testing.expect(!contains(raw, "Doe") and !contains(raw, "robin@example.test"));
    try std.testing.expectEqualStrings("\"Doe, Jane\" <jane@example.test>, Alex Example <alex@example.test>, robin@example.test", (try append(a, raw, "robin@example.test")).?);
    try std.testing.expect((try append(a, raw, "alex@EXAMPLE.test")) == null);
    // Unfinished text keeps its listed names visible to duplicate checks.
    try std.testing.expect(contains("\"Doe, Jane\" <jane@example.test>, half typed <", "jane@example.test"));
    // The 200-guest bound counts mailboxes, not commas inside names.
    var list: std.ArrayList(u8) = .empty;
    for (0..composer.max_guests - 1) |index| try list.print(a, "{s}\"Guest, {d}\" <guest{d}@example.test>", .{ if (index == 0) "" else ", ", index, index });
    const almost = (try append(a, list.items, "last@example.test")).?;
    try std.testing.expectError(error.CalendarTooManyGuests, append(a, almost, "extra@example.test"));
}
