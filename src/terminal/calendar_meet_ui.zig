//! User-facing copy designed by Claude Opus 5.5 at xhigh.
const std = @import("std");
const j = @import("json.zig");
pub const checkboxOn = "[x] Auto Meet AI notes + transcript";
pub const checkboxOff = "[ ] Auto Meet AI notes + transcript";
pub const needsAccessWide = "[x] Auto Meet AI notes + transcript · needs Meet access";
pub const needsAccessNarrow = "! Meet AI notes: needs access";
pub const uncheckedWide = "Unchecked: Omagma sends no Meet setting; Google or your admin may still turn AI notes on.";
pub const uncheckedNarrow = "Unchecked: no override · Google defaults apply";
pub const reviewOn = "Auto AI notes + transcript · requested on for this Meet link, every time it's used. Set after the event is saved. Google starts them when you or a co-host joins Meet on the web, subject to participant consent and admin policy. Omagma doesn't join the meeting and can't guarantee capture after a disconnect.";
pub const success = "Saved in Calendar. Meet AI notes + transcript: on, confirmed by Google at {time}. Google decides when they run, and the setting can be changed later in Meet.";
pub const refusedTitle = "Event saved · Google refused the AI notes request";
pub const unknownTitle = "Event saved · AI notes request unconfirmed";
pub const waitingTitle = "Event saved · AI notes not sent yet";
pub const readyBody = "Meet link ready · the reviewed AI notes setting hasn't been sent.";
pub const finishButton = "[y Turn on AI notes for this Meet]";
pub const checkButton = "[r Check status · reads only]";
pub const backButton = "[Esc Back to Calendar]";
pub const scopeTitle = "Connect Meet settings · {account}";
pub const scopeBody = "Auto AI notes need Google's optional Meet settings permission, meet-settings (scope meetings.space.settings). Omagma uses it only to set and read the AI notes and transcription settings of Meet links this account organizes. Copy the command and run it in a terminal; it keeps this account's current capabilities and credential store. Google also requires the Meet REST API to be enabled in your Cloud project, and a Workspace plan and admin policy that allow AI notes; those are checked when the setting is sent. Your event form is kept.";
pub const scopeCopy = "[Enter Copy command]";
pub const scopeBack = "[Esc Back to form]";
pub const scopeRefresh = "[Ctrl+R Recheck access]";
pub const scopeUnknownCapabilities = "Couldn't read this account's current capabilities, so no command was built; a partial list would remove existing access. See Calendar permissions.";
pub const scopeRechecked = "Meet settings access found · Esc returns to your event; Ctrl+S reviews it.";
pub const statusCheckFailed = "Not confirmed · this check sent nothing. Check AI notes in Meet when you join.";
pub const calendarUnknown = "Outcome unknown · AI notes are set only after the event save is confirmed.";
pub const calendarRejected = "Not saved · {code} · No Meet settings changed.";
pub fn reason(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "MeetSettingsPermissionRequired")) return "This account hasn't granted Meet settings access, or it was revoked.";
    if (std.mem.eql(u8, code, "MeetApiDisabled")) return "The Google Meet REST API isn't enabled for this Cloud project.";
    if (std.mem.eql(u8, code, "MeetAiNotesNotAllowed")) return "This organizer's plan or admin policy doesn't allow automatic AI notes.";
    if (std.mem.eql(u8, code, "MeetNotOrganizer")) return "Only the organizer can set AI notes for this meeting.";
    if (std.mem.eql(u8, code, "MeetSpaceChanged")) return "This event's Meet link differs from the one Omagma saved; nothing was sent.";
    if (std.mem.eql(u8, code, "MeetLinkFailed")) return "Google couldn't create the Meet link, so AI notes weren't set. The event is saved without a Meet link.";
    return "Google refused the AI notes request";
}
pub fn title(result: j.Value, uncertain: bool) []const u8 {
    if (result == .null) return if (uncertain) "Check Calendar outcome" else "Review new event";
    const calendar = j.text(j.get(result, "calendar") orelse .null, "state");
    if (std.mem.eql(u8, calendar, "not_sent")) return "Review new event";
    if (std.mem.eql(u8, calendar, "rejected")) return "Event not saved";
    if (!std.mem.eql(u8, calendar, "applied")) return "Check Calendar outcome";
    const notes = j.text(j.get(result, "meetAiNotes") orelse .null, "state");
    if (std.mem.eql(u8, notes, "on")) return "Event saved";
    if (std.mem.eql(u8, notes, "refused")) return if ((j.get(j.get(result, "meetAiNotes") orelse .null, "providerError") orelse .null) != .null) refusedTitle else "Event saved · AI notes not turned on";
    if (std.mem.eql(u8, notes, "waiting_for_link") or std.mem.eql(u8, notes, "not_sent")) return waitingTitle;
    return unknownTitle;
}

pub const applyNotesUnknown = "AI notes outcome unknown · r reads Google; nothing is resent.";
pub const applyCalendarUnknown = "Outcome unknown · r checks Calendar only; nothing is resent.";
pub const checkUnchanged = "Check failed · nothing was sent. AI notes status unchanged.";
pub const scopeReviewRechecked = "Meet settings access found · Esc returns to your review.";
pub const waitingBody = "The Meet link isn't ready, so the AI notes setting hasn't been sent. r checks again and only reads. Omagma won't send it later on its own.";
pub const unknownBody = "AI notes outcome unknown · r reads Google; nothing is resent.";
pub const pendingCheckFailed = "Couldn't check for an unfinished save · nothing was sent";
pub const pendingBody = "The AI notes setting hasn't been sent. r checks again and only reads. Omagma won't send it later on its own.";
pub fn enumLabel(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "on")) "on" else if (std.mem.eql(u8, value, "off")) "off" else "not set";
}
