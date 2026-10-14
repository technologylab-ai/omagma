//! Positive evidence for an RSVP whose provider response was lost.
const std = @import("std");
const invitation = @import("invitation.zig");
const types = @import("types.zig");

pub fn validateMessageId(id: []const u8) !void {
    if (id.len < 3 or id.len > 256 or id[0] != '<' or id[id.len - 1] != '>') return error.InvalidMessageId;
    for (id[1 .. id.len - 1]) |c| if (!std.ascii.isAlphanumeric(c) and c != '@' and c != '.' and c != '-' and c != '_') return error.InvalidMessageId;
}

pub fn matches(account: []const u8, rfc_id: []const u8, submitted: []const u8, message: types.Message) bool {
    if (message.id.len == 0 or !std.mem.eql(u8, message.messageId, rfc_id)) return false;
    var sent = false;
    for (message.labels) |label| sent = sent or std.mem.eql(u8, label, "SENT");
    if (!sent) return false;
    const received = message.invitation orelse return false;
    var expected: invitation.Invitation = .{};
    var actual: invitation.Invitation = .{};
    invitation.parseDisplay(submitted, account, &.{}, &expected) catch return false;
    invitation.parseDisplay(received, account, &.{}, &actual) catch return false;
    if (expected.method != .reply or actual.method != .reply or expected.cancelled or actual.cancelled or
        expected.response_blocked or actual.response_blocked or expected.additional_events != 0 or actual.additional_events != 0 or
        expected.attendee.len == 0 or expected.attendee_status.len == 0 or expected.sequence != actual.sequence) return false;
    inline for (.{ "uid", "stamp", "recurrence_id", "recurrence_parameters", "start", "start_parameters", "end", "end_parameters", "duration" }) |field| {
        if (!std.mem.eql(u8, @field(expected, field).slice(), @field(actual, field).slice())) return false;
    }
    inline for (.{ "organizer", "attendee", "attendee_status" }) |field| {
        if (!std.ascii.eqlIgnoreCase(@field(expected, field).slice(), @field(actual, field).slice())) return false;
    }
    return true;
}

test "invitation receipt: only exact Sent identity and reviewed RSVP resolve uncertainty" {
    const account = "self@example.test";
    const ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:planning@example.test\r\nDTSTAMP:20261013T120000Z\r\nSEQUENCE:2\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:self@example.test\r\nDTSTART:20261014T130000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const id = "<omagma-receipt@mail.invalid>";
    var message: types.Message = .{ .id = "provider-id", .threadId = "thread", .messageId = id, .invitation = ics, .labels = &.{"SENT"} };
    try std.testing.expect(matches(account, id, ics, message));
    message.labels = &.{"INBOX"};
    try std.testing.expect(!matches(account, id, ics, message));
    message.labels = &.{"SENT"};
    message.messageId = "<other@mail.invalid>";
    try std.testing.expect(!matches(account, id, ics, message));
    message.messageId = id;
    inline for (.{
        .{ "ACCEPTED", "DECLINED" },
        .{ "self@example.test", "other@example.test" },
        .{ "host@example.test", "other@example.test" },
        .{ "planning@example.test", "different@example.test" },
        .{ "20261013T120000Z", "20261013T120001Z" },
        .{ "SEQUENCE:2", "SEQUENCE:3" },
        .{ "METHOD:REPLY", "METHOD:REQUEST" },
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, ics, change[0], change[1]);
        defer std.testing.allocator.free(changed);
        message.invitation = changed;
        try std.testing.expect(!matches(account, id, ics, message));
    }
    try validateMessageId(id);
    try std.testing.expectError(error.InvalidMessageId, validateMessageId("<x> OR in:inbox"));
}
