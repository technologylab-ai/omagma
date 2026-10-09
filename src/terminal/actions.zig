//! The discoverable command surface shares the existing action executor.
//! Entries are literal, bounded and filtered locally; provider strings never
//! become commands or keyboard shortcuts.
const std = @import("std");

pub const Id = enum {
    compose,
    reply,
    reply_all,
    forward,
    archive,
    trash,
    star,
    unread,
    spam,
    unspam,
    labels,
    manage_labels,
    scope,
    find,
    next_unread,
    previous_unread,
    search_history,
    saved_searches,
    save_search,
    sender,
    preview_browser,
    contacts,
    add_contact,
    files,
    save_all,
    discard_draft,
    undo,
    send_grace,
    resume_send,
    cancel_send,
    help,
    theme,
    updates,
};
pub const Context = struct {
    mail: bool = false,
    composing: bool = false,
    draft: bool = false,
    search: bool = false,
    writable: bool = false,
    contacts_write: bool = false,
};
pub const Entry = struct {
    id: Id,
    name: []const u8,
    detail: []const u8,
    keys: []const u8 = "",
    needs_mail: bool = false,
    needs_compose: bool = false,
    needs_draft: bool = false,
    needs_search: bool = false,
    write: bool = false,
    contact_write: bool = false,

    pub fn available(self: Entry, context: Context) bool {
        return (!self.needs_mail or context.mail) and
            (!self.needs_compose or context.composing) and
            (!self.needs_draft or context.draft) and
            (!self.needs_search or context.search) and
            (!self.write or context.writable) and
            (!self.contact_write or context.contacts_write);
    }
};
pub const entries = [_]Entry{
    .{ .id = .compose, .name = "Compose", .detail = "Write a new message", .keys = "c" },
    .{ .id = .reply, .name = "Reply", .detail = "Reply to the focused message", .keys = "r", .needs_mail = true },
    .{ .id = .reply_all, .name = "Reply all", .detail = "Reply to its sender and recipients", .keys = "R", .needs_mail = true },
    .{ .id = .forward, .name = "Forward", .detail = "Choose formatted, quoted or original email", .keys = "f", .needs_mail = true },
    .{ .id = .archive, .name = "Archive", .detail = "Archive the reviewed message scope", .keys = "x", .needs_mail = true, .write = true },
    .{ .id = .trash, .name = "Move to Trash", .detail = "Review the exact messages first", .keys = "D", .needs_mail = true, .write = true },
    .{ .id = .star, .name = "Toggle star", .detail = "Change the focused message's star", .keys = "s", .needs_mail = true, .write = true },
    .{ .id = .unread, .name = "Toggle unread", .detail = "Change its current read state", .keys = "u", .needs_mail = true, .write = true },
    .{ .id = .spam, .name = "Mark as Spam", .detail = "Move the selected scope to Spam", .needs_mail = true, .write = true },
    .{ .id = .unspam, .name = "Not spam", .detail = "Remove Spam and return to Inbox", .needs_mail = true, .write = true },
    .{ .id = .labels, .name = "Assign labels", .detail = "Stage checked labels, then Apply", .keys = "m", .needs_mail = true, .write = true },
    .{ .id = .manage_labels, .name = "Manage labels", .detail = "Create, rename, color and delete custom labels", .keys = ":labels" },
    .{ .id = .scope, .name = "Message or conversation", .detail = "Choose what mail actions affect", .keys = ":scope", .needs_mail = true },
    .{ .id = .find, .name = "Find in message", .detail = "Highlight and jump through visible text", .keys = ":find", .needs_mail = true },
    .{ .id = .next_unread, .name = "Next unread", .detail = "Find the next unread cached message", .keys = ":next-unread" },
    .{ .id = .previous_unread, .name = "Previous unread", .detail = "Find the previous unread cached message", .keys = ":previous-unread" },
    .{ .id = .search_history, .name = "Search history", .detail = "Recent account-specific cache and server queries", .keys = ":search-history" },
    .{ .id = .saved_searches, .name = "Saved searches", .detail = "Open a named account-specific query", .keys = ":saved-searches" },
    .{ .id = .save_search, .name = "Save this search", .detail = "Name the current query and its scope", .keys = ":save-search", .needs_search = true },
    .{ .id = .sender, .name = "Choose sender", .detail = "Choose a verified sending identity", .keys = "f", .needs_compose = true },
    .{ .id = .preview_browser, .name = "Preview in browser", .detail = "Inspect the rendered outgoing email", .keys = ":preview-browser", .needs_compose = true },
    .{ .id = .contacts, .name = "Contacts", .detail = "Find or edit account contacts", .keys = "a" },
    .{ .id = .add_contact, .name = "Add sender to contacts", .detail = "Prefill a contact from this mail", .needs_mail = true, .contact_write = true },
    .{ .id = .files, .name = "Attachments", .detail = "Save or open received files", .keys = "B", .needs_mail = true },
    .{ .id = .save_all, .name = "Save attachments", .detail = "Choose files and a destination folder", .keys = ":save-all", .needs_mail = true },
    .{ .id = .discard_draft, .name = "Discard local draft", .detail = "Review and remove a saved draft", .keys = ":discard-draft", .needs_draft = true },
    .{ .id = .undo, .name = "Undo last mail action", .detail = "Reverse this account's completed operation", .keys = "Ctrl+Z", .needs_mail = true, .write = true },
    .{ .id = .send_grace, .name = "Send cancellation period", .detail = "Configure the local 0–30 second grace period", .keys = ":send-grace" },
    .{ .id = .resume_send, .name = "Resume pending send", .detail = "Explicitly restart a paused local countdown", .keys = ":resume-send", .needs_compose = true },
    .{ .id = .cancel_send, .name = "Cancel pending send", .detail = "Keep the queued draft without submitting", .keys = ":cancel-send", .needs_compose = true },
    .{ .id = .help, .name = "Help", .detail = "Search shortcuts and descriptions", .keys = "?" },
    .{ .id = .theme, .name = "Theme", .detail = "Preview Omagma or Follow Omarchy", .keys = "T" },
    .{ .id = .updates, .name = "Updates", .detail = "Check releases and see upgrade instructions for this installation", .keys = ":updates" },
};

pub const Matches = struct {
    indices: [entries.len]usize = undefined,
    len: usize = 0,
};
pub fn collect(query: []const u8, context: Context) Matches {
    var result: Matches = .{};
    const needle = std.mem.trim(u8, query, " \t");
    for (entries, 0..) |entry, index| {
        if (!entry.available(context)) continue;
        if (needle.len > 0 and std.ascii.findIgnoreCase(entry.name, needle) == null and
            std.ascii.findIgnoreCase(entry.detail, needle) == null and
            std.ascii.findIgnoreCase(entry.keys, needle) == null) continue;
        result.indices[result.len] = index;
        result.len += 1;
    }
    return result;
}

test "action palette: queries are literal and writes require a matching context" {
    try std.testing.expectEqual(@as(usize, 0), collect("spam", .{ .mail = true }).len);
    try std.testing.expectEqual(@as(usize, 2), collect("SPAM", .{ .mail = true, .writable = true }).len);
    try std.testing.expectEqual(@as(usize, 0), collect("sender", .{}).len);
    try std.testing.expectEqual(@as(usize, 1), collect("Choose sender", .{ .composing = true }).len);
    try std.testing.expectEqual(@as(usize, 0), collect("; rm", .{ .mail = true, .writable = true }).len);
}
