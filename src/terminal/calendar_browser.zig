//! Browser targets are built only after account-bound Calendar reads. Event
//! htmlLink is provider data, never an invitation URL or a guessed UID encoding.
const std = @import("std");
const model = @import("../model.zig");
const open = @import("../open_target.zig");
const t = @import("calendar_types.zig");

pub fn calendar(account: *const model.Account) !open.Target {
    var bytes: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("https://calendar.google.com/calendar/r?authuser=");
    try open.encode(&writer, account.address.slice());
    return open.makeUrl(account, writer.buffered());
}

pub fn event(account: *const model.Account, expected: t.Target, expected_id: []const u8, value: t.Event) !open.Target {
    try expected.validate();
    if (!std.ascii.eqlIgnoreCase(account.address.slice(), expected.account) or !value.target.eql(expected) or !std.mem.eql(u8, value.id, expected_id)) return error.CalendarAccountMismatch;
    return eventUrl(account, value.html_url);
}

fn eventUrl(account: *const model.Account, raw: []const u8) !open.Target {
    if (raw.len == 0) return error.CalendarEventLinkUnavailable;
    // Reuse the shared strict HTTP URL and profile validation first.
    _ = open.makeUrl(account, raw) catch return error.InvalidCalendarEventLink;
    const uri = std.Uri.parse(raw) catch return error.InvalidCalendarEventLink;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or (uri.port != null and uri.port != 443)) return error.InvalidCalendarEventLink;
    var host_storage: [128]u8 = undefined;
    const host = (uri.host orelse return error.InvalidCalendarEventLink).toRaw(&host_storage) catch return error.InvalidCalendarEventLink;
    if (!std.ascii.eqlIgnoreCase(host, "calendar.google.com") and !std.ascii.eqlIgnoreCase(host, "www.google.com")) return error.InvalidCalendarEventLink;
    var path_storage: [4096]u8 = undefined;
    const path = uri.path.toRaw(&path_storage) catch return error.InvalidCalendarEventLink;
    // Current Calendar API htmlLink routes. An unfamiliar route remains a
    // visible error instead of opening a redirect or another Google product.
    if (!std.mem.eql(u8, path, "/calendar/event") and !std.mem.startsWith(u8, path, "/calendar/r/eventedit/")) return error.InvalidCalendarEventLink;
    const prefix_end = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    var bytes: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(raw[0..prefix_end]);
    var separator: u8 = '?';
    if (uri.query) |query| {
        var encoded_query: [4096]u8 = undefined;
        const query_text = query.toRaw(&encoded_query) catch return error.InvalidCalendarEventLink;
        // Iterate the original encoded query: decoding the whole query would
        // turn an encoded ampersand inside an opaque event ID into a new field.
        _ = query_text;
        const query_start = (std.mem.indexOfScalar(u8, raw, '?') orelse return error.InvalidCalendarEventLink) + 1;
        const query_end = std.mem.indexOfScalarPos(u8, raw, query_start, '#') orelse raw.len;
        var fields = std.mem.splitScalar(u8, raw[query_start..query_end], '&');
        while (fields.next()) |field| {
            if (field.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
            var key_storage: [256]u8 = undefined;
            const key_component: std.Uri.Component = .{ .percent_encoded = field[0..equals] };
            const key = key_component.toRaw(&key_storage) catch return error.InvalidCalendarEventLink;
            if (std.ascii.eqlIgnoreCase(key, "authuser")) continue;
            try writer.writeByte(separator);
            try writer.writeAll(field);
            separator = '&';
        }
    }
    try writer.writeByte(separator);
    try writer.writeAll("authuser=");
    try open.encode(&writer, account.address.slice());
    if (uri.fragment != null) {
        const fragment = std.mem.indexOfScalar(u8, raw, '#') orelse return error.InvalidCalendarEventLink;
        try writer.writeAll(raw[fragment..]);
    }
    return open.makeUrl(account, writer.buffered());
}

test "calendar browser: Calendar and provider event links retain account profile and replace authuser" {
    var account: model.Account = .{};
    try account.address.set("work+calendar@example.test");
    try account.profile.set("Profile 2");
    const home = try calendar(&account);
    try std.testing.expectEqualStrings("https://calendar.google.com/calendar/r?authuser=work%2Bcalendar%40example.test", home.url.slice());
    try std.testing.expectEqualStrings("--profile-directory=Profile 2", home.profile_arg.slice());
    const target: t.Target = .{ .account = account.address.slice(), .calendar_id = "shared" };
    const actual = try event(&account, target, "event-1", .{ .target = target, .id = "event-1", .html_url = "https://www.google.com/calendar/event?eid=opaque%26id&authuser=wrong%40example.test&%61uthuser=1#view" });
    try std.testing.expectEqualStrings("https://www.google.com/calendar/event?eid=opaque%26id&authuser=work%2Bcalendar%40example.test#view", actual.url.slice());
    try std.testing.expectEqualStrings(home.profile_arg.slice(), actual.profile_arg.slice());
    try std.testing.expectError(error.CalendarAccountMismatch, event(&account, .{ .account = "other@example.test", .calendar_id = "shared" }, "event-1", .{ .target = target, .id = "event-1" }));
    try std.testing.expectError(error.CalendarAccountMismatch, event(&account, target, "another", .{ .target = target, .id = "event-1" }));
    for ([_][]const u8{ "http://calendar.google.com/calendar/event?eid=id", "https://calendar.google.com.evil.test/calendar/event?eid=id", "https://calendar.google.com:444/calendar/event?eid=id", "https://www.google.com/url?q=https://evil.test", "https://user" ++ "@" ++ "calendar.google.com/calendar/event?eid=id", "https://calendar.google.com/calendar/event?eid=id\n", "https://meet.google.com/abc-defg-hij", "https://calendar.example.test/event/id" }) |url| try std.testing.expectError(error.InvalidCalendarEventLink, eventUrl(&account, url));
    try std.testing.expectError(error.CalendarEventLinkUnavailable, eventUrl(&account, ""));
}
