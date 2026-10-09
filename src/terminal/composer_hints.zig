//! Advisory only: a literal attachment promise in newly authored text.
//! Never affects sending and never scans quoted original messages.
const std = @import("std");
const max_scan_bytes = 2 * 1024 * 1024;
fn contains(raw: []const u8, phrase: []const u8) bool {
    var start: usize = 0;
    while (start < raw.len) {
        const relative = std.ascii.findIgnoreCase(raw[start..], phrase) orelse return false;
        const index = start + relative;
        const end = index + phrase.len;
        if ((index == 0 or !std.ascii.isAlphanumeric(raw[index - 1])) and (end == raw.len or !std.ascii.isAlphanumeric(raw[end]))) return true;
        start = index + 1;
    }
    return false;
}
pub fn attachmentIntent(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body[0..@min(body.len, max_scan_bytes)], '\n');
    var fenced = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            fenced = !fenced;
            continue;
        }
        if (fenced or std.mem.startsWith(u8, line, ">")) continue;
        if (std.mem.eql(u8, line, "--") or std.ascii.startsWithIgnoreCase(line, "-----Original Message-----") or std.ascii.startsWithIgnoreCase(line, "---------- Original message") or std.ascii.startsWithIgnoreCase(line, "---------- Forwarded message") or std.ascii.startsWithIgnoreCase(line, "Begin forwarded message:") or (std.ascii.startsWithIgnoreCase(line, "On ") and std.ascii.endsWithIgnoreCase(line, "wrote:"))) break;
        // Keep this conservative: a generic mention of an attachment, a past
        // request, a negation, or source code is not a promise to attach one.
        if (contains(line, "not attached") or contains(line, "no attachment") or contains(line, "without attachment") or contains(line, "do not attach") or contains(line, "don't attach") or contains(line, "not attaching") or contains(line, "will attach later") or contains(line, "please attach") or contains(line, "could you attach") or contains(line, "can you attach")) continue;
        for ([_][]const u8{ "I've attached", "I have attached", "I attached", "I am attaching", "I'm attaching", "we've attached", "we have attached", "we attached", "we are attaching", "please find attached", "please see attached", "see the attached", "attached is", "attached are", "attached you'll find", "attached you will find", "in the attachment", "find the attachment", "im Anhang", "anbei", "beigefügt" }) |phrase| if (contains(line, phrase)) return true;
    }
    return false;
}
test "composer attachment hint: authored promises count and quoted originals do not" {
    try std.testing.expect(attachmentIntent("Hello,\nI've attached the revised plan.\nThanks"));
    try std.testing.expect(attachmentIntent("Please find attached our proposal."));
    try std.testing.expect(attachmentIntent("Die Unterlagen sind im Anhang."));
    try std.testing.expect(!attachmentIntent("Reply\n> I've attached the old plan."));
    try std.testing.expect(!attachmentIntent("Reply\nOn Monday, Alex wrote:\nI've attached the old plan."));
    try std.testing.expect(!attachmentIntent("Reply\n---------- Forwarded message ---------\nPlease find attached the old plan."));
    try std.testing.expect(!attachmentIntent("Reply\n---------- Original message ----------\nI've attached the old plan."));
    try std.testing.expect(!attachmentIntent("Please attach the document when ready."));
    try std.testing.expect(!attachmentIntent("I have not attached the document."));
    try std.testing.expect(!attachmentIntent("No attachment is needed.\n-- \nI've attached a signature."));
    try std.testing.expect(!attachmentIntent("```\nI've attached a fixture\n```"));
}
