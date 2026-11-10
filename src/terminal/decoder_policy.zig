//! Versioned retry policy for persisted incoming-mail decode refusals.
//! This module has no I/O; each cache decides when to apply the migration.
const std = @import("std");

/// Body refusal codes that a newer incoming-mail decoder may now accept.
/// Other refusals stay final. Append a revision; never reuse one.
const decoder_retries = [_]struct { revision: u32, code: []const u8 }{
    // Gmail declares base64 UTF-8 inline text with its stripped byte order mark.
    .{ .revision = 1, .code = "BodySizeMismatch" },
    // ISO-8859-15 text.
    .{ .revision = 2, .code = "UnsupportedCharset" },
    // Conflicting calendar parts no longer refuse the message.
    .{ .revision = 2, .code = "AmbiguousCalendarPart" },
    // Malformed encoded words in Subject, display names and filenames display
    // as literal text.
    .{ .revision = 2, .code = "InvalidEncodedWord" },
    .{ .revision = 2, .code = "InvalidBase64" },
    .{ .revision = 2, .code = "InvalidQuotedPrintable" },
    .{ .revision = 2, .code = "InvalidCharsetData" },
    .{ .revision = 2, .code = "InvalidUtf8" },
    // Received attachments are bounded at 50 MiB instead of 25 MiB.
    .{ .revision = 2, .code = "BodyTooLarge" },
    // Large external images and other unloaded binary parts, including inline
    // ones referenced by Content-ID, stay descriptors instead of refusing.
    .{ .revision = 3, .code = "BodyTooLarge" },
    // Wider shared header limits and explicit envelope/body isolation recover
    // previously refused readable messages once, without retrying each visit.
    .{ .revision = 4, .code = "AmbiguousSender" },
    .{ .revision = 4, .code = "AmbiguousHeader" },
    .{ .revision = 4, .code = "InvalidAddress" },
    .{ .revision = 4, .code = "InvalidRecipients" },
    .{ .revision = 4, .code = "TooManyIncomingRecipients" },
    .{ .revision = 4, .code = "CapacityExceeded" },
    .{ .revision = 4, .code = "HeadersTooLarge" },
    .{ .revision = 4, .code = "HeaderTooLarge" },
    .{ .revision = 4, .code = "ReferencesTooLarge" },
    .{ .revision = 4, .code = "TooManyReferences" },
    .{ .revision = 4, .code = "UnsupportedCharset" },
    // Long reply chains may retain up to 1024 inline resources. Revisit older
    // descriptor/part refusals once with the corresponding wider MIME budget.
    .{ .revision = 5, .code = "TooManyAttachments" },
    .{ .revision = 5, .code = "TooManyMimeParts" },
    // Gmail may return decoded newlines in an unstructured Subject scalar.
    // Retry previous whole-message refusals once with field-aware unfolding.
    .{ .revision = 6, .code = "InvalidHeaders" },
    // Received mail degrades per field and per part instead of refusing the
    // message: any header content or count, repeated headers, unreadable
    // addresses, unknown or mislabelled charsets, odd media types, long
    // filenames, oversized calendars and text parts, part/depth/attachment
    // counts and Gmail's advisory size field. Retry every such refusal once.
    .{ .revision = 7, .code = "InvalidHeaders" },
    .{ .revision = 7, .code = "TooManyHeaders" },
    .{ .revision = 7, .code = "HeadersTooLarge" },
    .{ .revision = 7, .code = "HeaderTooLarge" },
    .{ .revision = 7, .code = "AmbiguousHeader" },
    .{ .revision = 7, .code = "AmbiguousSender" },
    .{ .revision = 7, .code = "InvalidAddress" },
    .{ .revision = 7, .code = "InvalidRecipients" },
    .{ .revision = 7, .code = "RecipientHeaderTooLarge" },
    .{ .revision = 7, .code = "RecipientTooLarge" },
    .{ .revision = 7, .code = "TooManyIncomingRecipients" },
    .{ .revision = 7, .code = "CapacityExceeded" },
    .{ .revision = 7, .code = "UnsupportedCharset" },
    .{ .revision = 7, .code = "InvalidUtf8" },
    .{ .revision = 7, .code = "InvalidCharsetData" },
    .{ .revision = 7, .code = "InvalidMimeType" },
    .{ .revision = 7, .code = "MissingMimeType" },
    .{ .revision = 7, .code = "FilenameTooLarge" },
    .{ .revision = 7, .code = "CalendarTooLarge" },
    .{ .revision = 7, .code = "BodySizeMismatch" },
    .{ .revision = 7, .code = "BodyTooLarge" },
    .{ .revision = 7, .code = "DecodedMessageTooLarge" },
    .{ .revision = 7, .code = "ExternalBodyRequired" },
    .{ .revision = 7, .code = "TooManyAttachments" },
    .{ .revision = 7, .code = "TooManyMimeParts" },
    .{ .revision = 7, .code = "MimeTooDeep" },
};
pub const decoder_revision: u32 = decoder_retries[decoder_retries.len - 1].revision;

/// Refusals with a recorded decoder compatibility history. Browser snapshots
/// predate revisions but must never turn auth, storage or unknown errors into
/// a fetch merely because their recorded revision is absent.
pub fn knownDecoderRefusal(code: []const u8) bool {
    // This earlier compatibility fix predates the numbered retry table.
    if (std.mem.eql(u8, code, "MimeTooDeep")) return true;
    for (decoder_retries) |retry| if (std.mem.eql(u8, retry.code, code)) return true;
    return false;
}

pub fn retriedByNewerDecoder(code: []const u8, recorded: u32) bool {
    if (code.len == 0 or std.mem.eql(u8, code, "DiskQuotaExceeded")) return false;
    // Indexes from before revisions were recorded hold refusals from unknown
    // older decoders, some since fixed. Retry each of them once.
    if (recorded == 0) return true;
    for (decoder_retries) |retry| if (retry.revision > recorded and std.mem.eql(u8, retry.code, code)) return true;
    return false;
}

test "decoder policy: browser legacy eligibility excludes auth storage and unknown failures" {
    for ([_][]const u8{ "UnsupportedCharset", "HeaderTooLarge", "MimeTooDeep", "BodySizeMismatch", "TooManyAttachments", "TooManyMimeParts", "InvalidHeaders" }) |code| {
        try std.testing.expect(knownDecoderRefusal(code));
        try std.testing.expect(retriedByNewerDecoder(code, 0));
        try std.testing.expect(!retriedByNewerDecoder(code, decoder_revision));
    }
    for ([_][]const u8{ "", "NotConnected", "AuthenticationFailed", "PermissionDenied", "NetworkFailure", "DiskQuotaExceeded", "OutOfMemory", "UnknownFutureRefusal" }) |code| try std.testing.expect(!knownDecoderRefusal(code));
    for ([_][]const u8{ "TooManyAttachments", "TooManyMimeParts" }) |code| {
        try std.testing.expect(retriedByNewerDecoder(code, 4));
        try std.testing.expect(retriedByNewerDecoder(code, 6));
        try std.testing.expect(!retriedByNewerDecoder(code, 7));
    }
    try std.testing.expect(retriedByNewerDecoder("UnsupportedCharset", 6));
    try std.testing.expect(!retriedByNewerDecoder("ReferencesTooLarge", 4));
    try std.testing.expect(retriedByNewerDecoder("InvalidHeaders", 5));
    try std.testing.expect(retriedByNewerDecoder("InvalidHeaders", 6));
    try std.testing.expect(!retriedByNewerDecoder("InvalidHeaders", 7));
    for ([_][]const u8{ "AmbiguousSender", "InvalidAddress", "CalendarTooLarge", "BodySizeMismatch", "MimeTooDeep", "FilenameTooLarge" }) |code| {
        try std.testing.expect(retriedByNewerDecoder(code, 6));
        try std.testing.expect(!retriedByNewerDecoder(code, 7));
    }
}
