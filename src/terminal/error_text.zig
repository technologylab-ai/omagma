//! Human sentences for stable protocol error codes. The code stays the machine
//! contract; this text only explains it. Mirrors the TUI's status labels and
//! falls back to the code's own words, so no reply repeats a bare identifier.
const std = @import("std");
const Entry = struct { code: []const u8, text: []const u8 };
const entries = [_]Entry{
    .{ .code = "UnknownField", .text = "The request contains a field this command does not accept" },
    .{ .code = "MissingField", .text = "A required field is missing or empty" },
    .{ .code = "InvalidRequest", .text = "The request has a field with the wrong type or shape" },
    .{ .code = "InvalidField", .text = "A field has the wrong type or shape" },
    .{ .code = "UnsupportedCommand", .text = "This cmd is not a supported JSONL command" },
    .{ .code = "AccountDisabled", .text = "This account is configured but disabled" },
    .{ .code = "PermissionDenied", .text = "Permission required for this account" },
    .{ .code = "NotConnected", .text = "This account is not connected; authorize it with omagma terminal-auth authorize" },
    .{ .code = "InvalidGrant", .text = "Google sign-in expired or was revoked; reconnect this account" },
    .{ .code = "OAuthClientRequired", .text = "Account connection needs an OAuth client; follow the setup workflow" },
    .{ .code = "WrongAccount", .text = "Account authorization does not match this account" },
    .{ .code = "GrantClientMismatch", .text = "Account authorization does not match its OAuth client" },
    .{ .code = "CacheChanged", .text = "Mail changed while reading; try again" },
    .{ .code = "InvalidCursor", .text = "The cursor is stale or belongs to another view; restart without cursor" },
    .{ .code = "InvalidDraftCursor", .text = "The draft list changed; restart from the first page" },
    .{ .code = "CacheBoundaryGone", .text = "This cached boundary is no longer available" },
    .{ .code = "ThreadWindowChanged", .text = "The conversation changed; reopen the thread" },
    .{ .code = "ThreadWindowBoundary", .text = "No more messages in this direction" },
    .{ .code = "InvalidThreadWindow", .text = "The conversation window is invalid; reopen the thread" },
    .{ .code = "FollowUpChanged", .text = "The follow-up changed elsewhere; read reminder.list and retry with its version" },
    .{ .code = "FollowUpLimitReached", .text = "Follow-up limit reached (100 active); mark some done first" },
    .{ .code = "InvalidFollowUpDate", .text = "Enter a valid date as YYYY-MM-DD, today, tomorrow, +Nd or a weekday name" },
    .{ .code = "FollowUpVersionRequired", .text = "expectedVersion is required; use 0 for a new follow-up or the version from reminder.list" },
    .{ .code = "GmailDraftImportUnsupported", .text = "This Gmail draft cannot be imported completely; continue in Gmail" },
    .{ .code = "DraftPausedInGmail", .text = "This draft is paused in Gmail; check or take it back first" },
    .{ .code = "GmailDraftOutcomeUnknown", .text = "The Gmail draft upload is unconfirmed; check status and do not upload again" },
    .{ .code = "GmailDraftChanged", .text = "The Gmail draft handoff changed; read it again" },
    .{ .code = "GmailDraftConflict", .text = "The Gmail draft changed; check status before choosing a local copy" },
    .{ .code = "GmailDraftMissing", .text = "The Gmail copy is missing; it may have been sent or deleted" },
    .{ .code = "GmailCopyUnchecked", .text = "Acknowledge the Gmail copy warning before sending" },
    .{ .code = "GmailDraftAlreadyLinked", .text = "This draft already has a Gmail copy" },
    .{ .code = "FollowUpStoreCorrupt", .text = "Local follow-ups could not be read; saved data was kept" },
    .{ .code = "CacheMiss", .text = "This message or body is not cached" },
    .{ .code = "BodySizeMismatch", .text = "The mail body is incomplete" },
    .{ .code = "BodyNotCached", .text = "The body is not cached; read it without cacheOnly to download it" },
    .{ .code = "MessageBodyUnavailable", .text = "The body is unavailable; open it in Gmail or forward the original .eml" },
    .{ .code = "ComposeSourceRequired", .text = "The original is too large for this view; reply or forward loads the complete source" },
    .{ .code = "CalendarTooLarge", .text = "The calendar part exceeds the supported size" },
    .{ .code = "JsonTooDeep", .text = "The structure exceeds the supported nesting depth" },
    .{ .code = "JsonTooManyTokens", .text = "The structure exceeds the supported complexity" },
    .{ .code = "BodyTooLarge", .text = "The body exceeds the supported size" },
    .{ .code = "MessageTooLarge", .text = "The message exceeds the supported size" },
    .{ .code = "ResponseTooLarge", .text = "The response exceeds the supported size" },
    .{ .code = "RequestTooLarge", .text = "The request exceeds the supported size" },
    .{ .code = "TooManyHeaders", .text = "The mail headers exceed the supported limit" },
    .{ .code = "HeadersTooLarge", .text = "The mail headers exceed the supported limit" },
    .{ .code = "UnsupportedCharset", .text = "Unsupported mail character encoding" },
    .{ .code = "MessageBudgetExceeded", .text = "This message exceeds the decoding workspace" },
    .{ .code = "MetadataBudgetExceeded", .text = "The metadata batch budget was reached; read this message separately" },
    .{ .code = "ThreadBodyBudgetExceeded", .text = "The conversation body budget was reached; read single messages instead" },
    .{ .code = "ThreadTooLarge", .text = "The conversation has more than 100 messages" },
    .{ .code = "PartialMetadata", .text = "Some mail metadata is unavailable" },
    .{ .code = "UnsafeReplyMetadata", .text = "Reply addresses are unavailable; open the message in Gmail to reply" },
    .{ .code = "NotInvitation", .text = "No calendar request was found in this message" },
    .{ .code = "NotInvitationRequest", .text = "This calendar item is not a meeting request" },
    .{ .code = "NotAnAttendee", .text = "This account is not an invited attendee" },
    .{ .code = "InvitationChanged", .text = "The invitation changed since inspection; inspect it again" },
    .{ .code = "AmbiguousCalendarPart", .text = "The message has conflicting calendar requests" },
    .{ .code = "FileNotFound", .text = "Folder or file not found; check the path" },
    .{ .code = "AccessDenied", .text = "Cannot access this folder or file" },
    .{ .code = "NotRegularFile", .text = "Choose a regular file" },
    .{ .code = "AttachmentNotFound", .text = "The attachment could not be found in this message" },
    .{ .code = "MessageNotFound", .text = "The message could not be found in this account" },
    .{ .code = "DraftNotFound", .text = "The local draft could not be found in this account" },
    .{ .code = "OperationNotFound", .text = "No operation with this ID exists in this account" },
    .{ .code = "QueueNotFound", .text = "No queued send with this ID exists in this account" },
    .{ .code = "QueueNotDue", .text = "The queued send is not due yet; wait or pass wait:true" },
    .{ .code = "AttachmentsTooLarge", .text = "Attached files exceed the supported size" },
    .{ .code = "AttachmentPlanBlocked", .text = "The attachment plan has blockers; fix them first" },
    .{ .code = "InvalidAttachmentDelivery", .text = "File delivery must be attach, auto or drive" },
    .{ .code = "TooManyAttachments", .text = "Too many attached files for this draft" },
    .{ .code = "InvalidAttachment", .text = "An attachment could not be prepared" },
    .{ .code = "AmbiguousAttachment", .text = "The attachment reference matches several files" },
    .{ .code = "OriginalHtmlUnavailable", .text = "The original has no HTML; use a text quote instead of preserveFormatting" },
    .{ .code = "InvalidOriginalHtml", .text = "The original HTML cannot be preserved; use a text quote or forward the .eml" },
    .{ .code = "OriginalResourceUnavailable", .text = "An embedded image of the original is missing" },
    .{ .code = "AmbiguousOriginalHtml", .text = "The original has several HTML bodies" },
    .{ .code = "AmbiguousContentId", .text = "The original has conflicting embedded images" },
    .{ .code = "RenderedBodyTooLarge", .text = "Note and original exceed the supported size" },
    .{ .code = "MissingReplyRecipient", .text = "There is no external recipient to reply to" },
    .{ .code = "MissingRecipient", .text = "Add a recipient in to, cc or bcc" },
    .{ .code = "MissingMessageId", .text = "The message has no valid reply identifier" },
    .{ .code = "InvalidAddress", .text = "Enter a valid email address" },
    .{ .code = "InvalidRecipients", .text = "A recipient list is not a valid address list" },
    .{ .code = "IncompleteContact", .text = "The contact is incomplete; check it in Google Contacts before editing" },
    .{ .code = "InvalidLabelName", .text = "Enter a valid custom label name" },
    .{ .code = "DuplicateLabelName", .text = "A label with this name already exists" },
    .{ .code = "LabelNotFound", .text = "The label does not exist in this account" },
    .{ .code = "InvalidLabelConfirmation", .text = "confirmName does not match the label's current name" },
    .{ .code = "SystemLabelImmutable", .text = "Built-in mailbox labels cannot be edited" },
    .{ .code = "TooManyLabels", .text = "The account label limit was reached" },
    .{ .code = "UnverifiedSender", .text = "The sending identity is not verified for this account" },
    .{ .code = "VaultLocked", .text = "Encrypted mail is locked; run omagma vault unlock" },
    .{ .code = "VaultBusy", .text = "Encrypted mail is busy with another operation; retry later" },
    .{ .code = "BackendRequired", .text = "Start the encrypted mail service with omagma vault start" },
    .{ .code = "BackendStopped", .text = "The encrypted mail service stopped; start it again" },
    .{ .code = "VaultIdentityMismatch", .text = "Wrong encrypted mail service; check the selected vault" },
    .{ .code = "VaultOptionConflict", .text = "Encrypted mail is active; remove plaintext store path options" },
    .{ .code = "Timeout", .text = "The request timed out" },
    .{ .code = "Canceled", .text = "The request was canceled" },
    .{ .code = "RateLimited", .text = "Gmail rate limit reached; retry later" },
    .{ .code = "TransientFailure", .text = "The connection is temporarily unavailable; retry later" },
    .{ .code = "NetworkFailure", .text = "The network request failed" },
    .{ .code = "ProviderRejected", .text = "The provider rejected the request" },
    .{ .code = "PathAlreadyExists", .text = "The file already exists; choose a new path" },
    .{ .code = "OperationPending", .text = "Another operation for this item is still running" },
    .{ .code = "OutOfMemory", .text = "Not enough memory for this operation" },
    .{ .code = "CacheUnsupported", .text = "This command cannot run with cacheOnly" },
    .{ .code = "CachedMutationDenied", .text = "Mutations cannot run with cacheOnly" },
    .{ .code = "CacheWindowRequiresCached", .text = "beforeMessageId/afterMessageId require cacheOnly:true" },
    .{ .code = "ConflictingWindowSelectors", .text = "Use only one of cursor, anchorMessageId, beforeMessageId or afterMessageId" },
    .{ .code = "InvalidPageLimit", .text = "limit is outside its allowed range" },
    .{ .code = "InvalidPrefetchLimit", .text = "prefetchLimit must be from 0 to 64" },
    .{ .code = "InvalidSendDelay", .text = "delaySeconds must be from 0 to 30" },
    .{ .code = "InvalidInvitationStatus", .text = "status must be accepted, tentative or declined" },
    .{ .code = "InvalidBodyFormat", .text = "bodyFormat must be plain or markdown" },
    .{ .code = "InvalidTriageScope", .text = "scope must be message or conversation" },
    .{ .code = "InvalidContentDigest", .text = "expectedContentDigest must be the 64-character hex contentDigest" },
    .{ .code = "OperationConflict", .text = "This operationId was already used for different content; choose a new operationId" },
    .{ .code = "DraftReplaceWouldDropThreading", .text = "draft.update would drop the saved draft's recipients or reply threading" },
    .{ .code = "DryRunUnsupported", .text = "This command has no dryRun mode" },
    .{ .code = "InvalidView", .text = "view or detail is not one of this command's documented values" },
    .{ .code = "InvalidFields", .text = "fields must be a non-empty array of up to 64 field names" },
    .{ .code = "InvalidBodySelection", .text = "body must be both, text, html or none" },
    .{ .code = "InvalidMaxBodyBytes", .text = "maxBodyBytes must be a non-negative integer" },
    .{ .code = "InvalidCivilTime", .text = "Enter a valid date as YYYY-MM-DD, today, tomorrow, +Nd or a weekday name" },
    .{ .code = "RecoveryDraftRequiresUpdate", .text = "This recovery draft keeps raw fields; finish it with draft.update" },
    .{ .code = "ReadOnlyField", .text = "This field is read-only here; patch editable fields and pass expectedContentDigest to bind the edit to a reviewed draft" },
    .{ .code = "ReadOnlyFieldChanged", .text = "A read-only draft field (gmailLink or summaryCounts) differs from the saved draft; pass it back unchanged from draft.read or omit it" },
    .{ .code = "EmptyMutation", .text = "The request changes nothing; add unread, starred, addLabels or removeLabels" },
    .{ .code = "ConflictingReplyAll", .text = "replyAll and all disagree; send only one of them" },
    .{ .code = "DraftQueued", .text = "This draft has a pending queued send; cancel it before editing or sending again" },
    .{ .code = "CalendarNotFound", .text = "The calendar is not available for this account" },
    .{ .code = "EventNotFound", .text = "The event is not available in this calendar" },
    .{ .code = "InvalidCalendarDate", .text = "Enter a valid date as YYYY-MM-DD, today, tomorrow, +Nd or a weekday name" },
    .{ .code = "CalendarPermissionRequired", .text = "Calendar access is not authorized for this account" },
    .{ .code = "QueueCancelled", .text = "This queued send was cancelled" },
    .{ .code = "HistoryDeletionRequiresConfirmation", .text = "history.delete-source requires confirm:true" },
    .{ .code = "LiveProviderNotReady", .text = "The live provider is not ready for this account" },
};
pub fn sentence(code: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.code, code)) return entry.text;
    return null;
}
/// "InvalidPageLimit" -> "Invalid page limit". Keeps acronyms readable.
pub fn words(a: std.mem.Allocator, code: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (code, 0..) |byte, index| {
        const word_start = index + 1 < code.len and std.ascii.isLower(code[index + 1]);
        if (index > 0 and std.ascii.isUpper(byte) and (!std.ascii.isUpper(code[index - 1]) or word_start)) try out.append(a, ' ');
        try out.append(a, if (index > 0 and std.ascii.isUpper(byte) and word_start) std.ascii.toLower(byte) else byte);
    }
    return out.items;
}
/// Specific sentence, or the code's own words. Never just the identifier.
pub fn describe(a: std.mem.Allocator, code: []const u8) ![]const u8 {
    return sentence(code) orelse words(a, code);
}

test "error text: every code receives a sentence instead of its bare identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Invalid page limit", try words(a, "InvalidPageLimit"));
    try std.testing.expectEqualStrings("Fictional thing happened", try describe(a, "FictionalThingHappened"));
    try std.testing.expectEqualStrings("Missing RSVP owner", try words(a, "MissingRSVPOwner"));
    try std.testing.expect(!std.mem.eql(u8, "MissingField", try describe(a, "MissingField")));
    for (entries, 0..) |entry, index| for (entries[0..index]) |earlier| try std.testing.expect(!std.mem.eql(u8, entry.code, earlier.code));
}
