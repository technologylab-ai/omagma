const std = @import("std");
const t = @import("types.zig");
const timezone = @import("timezone.zig");
const unicode = @import("unicode_search.zig");

/// Local queries inspect literal metadata and already downloaded plaintext.
/// Whitespace joins terms with AND; double quotes preserve a phrase. No HTML,
/// encoded attachments, remote request, or implicit body download is involved.
const Terms = struct {
    query: []const u8,
    offset: usize = 0,
    count: usize = 0,
    fn next(self: *Terms) !?[]const u8 {
        while (self.offset < self.query.len and std.ascii.isWhitespace(self.query[self.offset])) self.offset += 1;
        if (self.offset == self.query.len) return null;
        if (self.count == 32) return error.InvalidQuery;
        self.count += 1;
        const start = self.offset;
        var quoted = false;
        while (self.offset < self.query.len) : (self.offset += 1) {
            const ch = self.query[self.offset];
            if (ch == '"') quoted = !quoted;
            if (!quoted and std.ascii.isWhitespace(ch)) break;
        }
        if (quoted) return error.InvalidQuery;
        return self.query[start..self.offset];
    }
};
fn unquote(value: []const u8) []const u8 {
    return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
}
pub fn find(haystack: []const u8, needle: []const u8) ?usize {
    return if (findRange(haystack, needle)) |range| range.start else null;
}
pub const Range = @import("unicode_search.zig").Range;
pub fn findRange(haystack: []const u8, needle: []const u8) ?Range {
    return @import("unicode_search.zig").find(haystack, needle);
}
pub fn findRangeAt(haystack: []const u8, needle: []const u8, offset: usize) ?Range {
    if (offset > haystack.len) return null;
    const relative = findRange(haystack[offset..], needle) orelse return null;
    return .{ .start = offset + relative.start, .end = offset + relative.end };
}
fn has(message: t.Message, label: []const u8) bool {
    for (message.labels) |value| if (std.ascii.eqlIgnoreCase(value, label)) return true;
    return false;
}
fn addressMatches(addresses: []const t.Address, term: Term, scratch: []unicode.Boundary) bool {
    for (addresses) |address| if (term.find(address.address, scratch) or term.find(address.name, scratch)) return true;
    return false;
}
const Operator = enum { any, from, to, cc, subject, body, label, is, has, in, filename, after, before, on, status };
const Term = struct {
    operator: Operator,
    value: []const u8,
    negative: bool,
    day: i64 = 0,
    needle: ?unicode.Needle = null,
    fn find(self: Term, text: []const u8, scratch: []unicode.Boundary) bool {
        return if (self.needle) |needle| needle.find(text, scratch) != null else unicode.find(text, self.value) != null;
    }
};
pub const Plan = struct {
    terms: [32]Term = undefined,
    count: usize = 0,
    needs_body: bool = false,
    needs_timezone: bool = false,
    scratch: []unicode.Boundary = &.{},
    /// Compile immutable folded needles once for this locked scan. All term
    /// strings together borrow at most 4096 query bytes; one boundary ring is
    /// sized to the longest folded term and reused between fields and rows.
    /// The returned plan is local to one scan, never shared between workers.
    pub fn prepared(self: Plan, a: std.mem.Allocator) !Plan {
        var result = self;
        var longest: usize = 0;
        for (result.terms[0..result.count]) |*term| switch (term.operator) {
            .any, .from, .to, .cc, .subject, .body, .filename => {
                term.needle = try unicode.Needle.init(a, term.value);
                longest = @max(longest, term.needle.?.values.len);
            },
            else => {},
        };
        result.scratch = try a.alloc(unicode.Boundary, longest);
        return result;
    }
    pub fn findRange(self: *const Plan, text: []const u8, value: []const u8) ?Range {
        if (value.len == 0) return null;
        for (self.terms[0..self.count]) |term| if (term.needle) |needle| {
            if (std.mem.eql(u8, term.value, value)) return needle.find(text, self.scratch);
        };
        return unicode.find(text, value);
    }
    pub fn matches(self: *const Plan, message: t.Message, zone: *const timezone.Zone) !bool {
        var local_day: ?i64 = null;
        for (self.terms[0..self.count]) |term| {
            const matched = switch (term.operator) {
                .any => anyMatches(message, term, self.scratch),
                .from => term.find(message.from.address, self.scratch) or term.find(message.from.name, self.scratch),
                .to => addressMatches(message.to, term, self.scratch),
                .cc => addressMatches(message.cc, term, self.scratch),
                .subject => term.find(message.subject, self.scratch),
                .body => term.find(message.bodyText, self.scratch),
                .label => has(message, term.value),
                .is => if (std.ascii.eqlIgnoreCase(term.value, "unread")) message.unread else if (std.ascii.eqlIgnoreCase(term.value, "read")) !message.unread else has(message, term.value),
                .has => message.attachments.len != 0,
                .status => message.metadataPartial or message.decodeWarning.len != 0 or message.bodyCacheError.len != 0 or !message.labelsVerified,
                .in => if (std.ascii.eqlIgnoreCase(term.value, "anywhere")) true else if (std.ascii.eqlIgnoreCase(term.value, "all")) !has(message, "TRASH") and !has(message, "SPAM") else if (std.ascii.eqlIgnoreCase(term.value, "archive")) !has(message, "INBOX") and !has(message, "TRASH") and !has(message, "SPAM") else has(message, if (std.ascii.eqlIgnoreCase(term.value, "drafts")) "DRAFT" else term.value),
                .filename => found: {
                    for (message.attachments) |attachment| if (term.find(attachment.filename, self.scratch)) break :found true;
                    break :found false;
                },
                .after, .before, .on => dated: {
                    if (message.receivedAt <= 0) break :dated false;
                    if (local_day == null) local_day = try zone.localDay(message.receivedAt);
                    break :dated switch (term.operator) {
                        .after => local_day.? >= term.day,
                        .before => local_day.? < term.day,
                        .on => local_day.? == term.day,
                        else => unreachable,
                    };
                },
            };
            if (matched == term.negative) return false;
        }
        return true;
    }
};
fn anyMatches(message: t.Message, term: Term, scratch: []unicode.Boundary) bool {
    for (message.labels) |label| if (term.find(label, scratch)) return true;
    return term.find(message.subject, scratch) or term.find(message.snippet, scratch) or term.find(message.bodyText, scratch) or term.find(message.from.address, scratch) or term.find(message.from.name, scratch);
}
/// Returned term strings borrow query. Compile once for each retained-cache
/// scan. Unknown operators/unsupported values are errors, never literal terms.
pub fn compile(query: []const u8) !Plan {
    if (query.len > 4096 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
    for (query) |byte| if ((byte < 32 and !std.ascii.isWhitespace(byte)) or byte == 127) return error.InvalidQuery;
    var result: Plan = .{};
    var terms: Terms = .{ .query = query };
    while (try terms.next()) |raw| {
        const negative = raw.len > 0 and raw[0] == '-';
        const token = if (negative) raw[1..] else raw;
        if (token.len == 0) return error.InvalidQueryValue;
        var term: Term = .{ .operator = .any, .value = unquote(token), .negative = negative };
        if (token[0] != '"') if (std.mem.indexOfScalar(u8, token, ':')) |split| {
            const field = token[0..split];
            var operator: ?Operator = null;
            inline for (std.meta.tags(Operator)) |item| if (item != .any and std.ascii.eqlIgnoreCase(field, @tagName(item))) {
                operator = item;
            };
            if (std.ascii.eqlIgnoreCase(field, "newer")) operator = .after;
            if (std.ascii.eqlIgnoreCase(field, "older")) operator = .before;
            term.operator = operator orelse return error.UnknownQueryOperator;
            term.value = unquote(token[split + 1 ..]);
        };
        if (term.value.len == 0 or std.mem.indexOfScalar(u8, term.value, '"') != null) return error.InvalidQueryValue;
        switch (term.operator) {
            .is => {
                var allowed = false;
                for ([_][]const u8{ "unread", "read", "starred", "important" }) |value| allowed = allowed or std.ascii.eqlIgnoreCase(value, term.value);
                if (!allowed) return error.InvalidQueryValue;
            },
            .has => if (!std.ascii.eqlIgnoreCase(term.value, "attachment")) return error.InvalidQueryValue,
            .status => if (!std.ascii.eqlIgnoreCase(term.value, "partial")) return error.InvalidQueryValue,
            .after, .before, .on => {
                term.day = timezone.dateDay(term.value) catch return error.InvalidQueryDate;
                result.needs_timezone = true;
            },
            .any, .body => result.needs_body = true,
            else => {},
        }
        result.terms[result.count] = term;
        result.count += 1;
    }
    return result;
}
pub fn matchesWithZone(message: t.Message, query: []const u8, zone: *const timezone.Zone) !bool {
    const plan = try compile(query);
    return plan.matches(message, zone);
}
/// Compatibility helper for synthetic/UTC callers. Production cache search
/// supplies the local display zone explicitly with Plan.matches.
pub fn matches(message: t.Message, query: []const u8) bool {
    return matchesWithZone(message, query, &.{}) catch false;
}
pub fn validate(query: []const u8) !void {
    _ = try compile(query);
}
pub fn diagnostic(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownQueryOperator => "Unknown cache operator; use from, to, cc, subject, body, label, is, in, has, filename, after, before, on or status",
        error.InvalidQueryDate => "Use a valid date: YYYY-MM-DD or YYYY/MM/DD (local calendar date)",
        error.InvalidQueryValue => "Cache query needs a value; is accepts read, unread, starred or important; has accepts attachment; status accepts partial",
        error.TimezoneUnavailable, error.TimezoneRangeUnavailable => "Local timezone unavailable for this date query",
        else => "Invalid cache query; use at most 32 terms and close quoted phrases",
    };
}
pub fn highlightTerm(query: []const u8) []const u8 {
    var terms: Terms = .{ .query = query };
    var metadata: []const u8 = "";
    while (terms.next() catch return "") |token| {
        if (token.len == 0 or token[0] == '-') continue;
        if (std.mem.indexOfScalar(u8, token, ':')) |split| {
            const field = token[0..split];
            if (!std.mem.eql(u8, field, "subject") and !std.mem.eql(u8, field, "body") and !std.mem.eql(u8, field, "from") and !std.mem.eql(u8, field, "to")) continue;
            if (std.mem.eql(u8, field, "body")) return unquote(token[split + 1 ..]);
            if (metadata.len == 0) metadata = unquote(token[split + 1 ..]);
            continue;
        }
        return unquote(token);
    }
    return metadata;
}
pub fn needsBody(query: []const u8) bool {
    return (compile(query) catch return false).needs_body;
}

test "wishlist: cache full text terms quoted phrases and exclusions" {
    const message: t.Message = .{ .id = "m", .threadId = "t", .from = .{ .address = "alice@example.test", .name = "Alice" }, .subject = "Weekly report", .bodyText = "The secret marmalade project", .labels = &.{ "INBOX", "UNREAD" }, .unread = true };
    try std.testing.expect(matches(message, "from:alice body:\"secret marmalade\" is:unread"));
    try std.testing.expect(!matches(message, "body:marmalade -in:inbox"));
    try std.testing.expect(matches(message, "subject:report -body:missing"));
    try std.testing.expect(!matches(message, "body:absent"));
    try std.testing.expectError(error.InvalidQuery, validate("body:\"unterminated"));
    try std.testing.expectEqualStrings("secret marmalade", highlightTerm("is:unread body:\"secret marmalade\""));
}
test "cache predicates: filename dates local midnight and diagnostics use metadata only" {
    const message: t.Message = .{ .id = "m", .threadId = "t", .receivedAt = 1780871400000, .attachments = &.{.{ .id = "a", .filename = "Budget June.PDF" }}, .labels = &.{"IMPORTANT"} };
    const zone = try timezone.Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    const plan = try compile("after:2026/06/08 before:2026-06-09 filename:\"june.pdf\" is:important has:attachment");
    try std.testing.expect(!plan.needs_body and plan.needs_timezone);
    try std.testing.expect(try plan.matches(message, &zone));
    try std.testing.expect(!try plan.matches(message, &.{}));
    try std.testing.expect(try matchesWithZone(message, "on:2026-06-08 -filename:secret", &zone));
    try std.testing.expect(!try matchesWithZone(message, "before:2026-06-08", &zone));
    try std.testing.expectError(error.UnknownQueryOperator, validate("subjet:budget"));
    try std.testing.expectError(error.InvalidQueryValue, validate("has:drive"));
    try std.testing.expectError(error.InvalidQueryValue, validate("from:"));
    try std.testing.expectError(error.InvalidQueryDate, validate("after:2026-02-29"));
    try std.testing.expectError(error.TimezoneUnavailable, matchesWithZone(message, "on:2026-06-08", &.{ .unavailable = true }));
    try validate("\"https://example.test\"");
    try std.testing.expect(!needsBody("filename:pdf after:2026-01-01"));
}

test "message isolation: partial cache query finds warnings without fetching bodies" {
    const plan = try compile("status:partial");
    try std.testing.expect(!plan.needs_body);
    try std.testing.expect(!try plan.matches(.{ .id = "good", .threadId = "t" }, &.{}));
    for ([_]t.Message{
        .{ .id = "metadata", .threadId = "t", .metadataPartial = true },
        .{ .id = "warning", .threadId = "t", .decodeWarning = "UnsupportedCharset" },
        .{ .id = "body", .threadId = "t", .bodyCacheError = "BodyTooLarge" },
        .{ .id = "labels", .threadId = "t", .labelsVerified = false },
    }) |message| {
        try std.testing.expect(try plan.matches(message, &.{}));
        try std.testing.expect(!matches(message, "-status:partial"));
    }
    try std.testing.expectError(error.InvalidQueryValue, compile("status:madeup"));
}

test "cache query reuse: ten thousand metadata and body rows share compiled Unicode needles without per-row allocation" {
    var cap: @import("capped_allocator.zig").CappedAllocator = .{ .backing = std.testing.allocator, .limit = 64 * 1024 };
    var arena: std.heap.ArenaAllocator = .init(cap.allocator());
    defer arena.deinit();
    const query = "from:STRASSE filename:résumé body:\"ΣΟΣ report\" -subject:discard";
    const plan = try (try compile(query)).prepared(arena.allocator());
    const allocated = cap.used;
    const peak = cap.peak;
    var matches_count: usize = 0;
    var expected_count: usize = 0;
    for (0..10000) |index| {
        const message: t.Message = .{
            .id = "synthetic",
            .threadId = "synthetic-thread",
            .from = .{ .address = if (index % 11 == 0) "other@example.test" else "straße@example.test" },
            .subject = if (index % 7 == 0) "Discard this" else "Keep this",
            .bodyText = if (index % 3 == 0) "Unrelated report" else "The σος REPORT remains literal",
            .attachments = if (index % 5 == 0) &.{} else &.{.{ .id = "a", .filename = "Résumé.pdf" }},
        };
        const expected = index % 11 != 0 and index % 7 != 0 and index % 3 != 0 and index % 5 != 0;
        try std.testing.expectEqual(expected, try plan.matches(message, &.{}));
        expected_count += @intFromBool(expected);
        matches_count += @intFromBool(try plan.matches(message, &.{}));
    }
    try std.testing.expectEqual(expected_count, matches_count);
    try std.testing.expectEqual(allocated, cap.used);
    try std.testing.expectEqual(peak, cap.peak);
    try std.testing.expectEqual(@as(usize, 0), cap.rejected);
    const text = "The σος REPORT remains literal";
    const range = plan.findRange(text, "ΣΟΣ report").?;
    try std.testing.expectEqualStrings("σος REPORT", text[range.start..range.end]);
    std.debug.print("compiled cache query compiler={s} optimize={s} rows=10000 allocator_peak={d} per_row_allocations=0\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), peak });
}

test "cache query reuse: maximum expanding query stays bounded and excludes partial source characters" {
    var query: [4096]u8 = undefined;
    for (0..query.len / 2) |i| @memcpy(query[i * 2 ..][0..2], "ΐ");
    var memory: [160 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const plan = try (try compile(&query)).prepared(fixed.allocator());
    try std.testing.expect(try plan.matches(.{ .id = "a", .threadId = "t", .subject = &query }, &.{}));
    try std.testing.expect(!try plan.matches(.{ .id = "a", .threadId = "t", .subject = query[0 .. query.len - 2] }, &.{}));
    const short = try (try compile("subject:s")).prepared(fixed.allocator());
    try std.testing.expect(!try short.matches(.{ .id = "a", .threadId = "t", .subject = "ß" }, &.{}));
    try std.testing.expect(try short.matches(.{ .id = "a", .threadId = "t", .subject = "ßS" }, &.{}));
    try std.testing.expect(fixed.end_index < memory.len);
}
