//! Account-scoped terminal mail UI. libvaxis owns input/rendering; the same
//! bounded operation client serves this UI and the JSON CLI.
const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const editor = @import("editor.zig");
const files = @import("files.zig");
const input_loop = @import("input.zig");
const fetch_progress = @import("progress.zig");
const loading = @import("loading.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const timezone = @import("timezone.zig");
const selection = @import("selection.zig");
const cache_query = @import("cache_query.zig");
const preferences = @import("preferences.zig");
const reader_tools = @import("reader_tools.zig");
const text_layout = @import("text_layout.zig");
const html_view = @import("html_view.zig");
const mime = @import("mime.zig");
const recipients = @import("recipients.zig");
const completion = @import("completion.zig");
const path_completion = @import("path_completion.zig");
const invitation = @import("invitation.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Key = vaxis.Key;
const max_cols = 240;
const max_rows = 80;
const response_limit = types.Limits.runtime_bytes / 2;
const Event = union(enum) { fetch_progress, loading_tick, key_press: Key, mouse: vaxis.Mouse, winsize: vaxis.Winsize, paste_start, paste_end, operation_done, compose_idle, terminate };
const Loop = input_loop.Loop(Event);
const Mode = enum { browse, search, command, compose, review, contacts, contact_edit, help, trash_confirm, invitation, labels, attachment };
const Tone = enum { text, subject, sender, muted, accent, selected, warning, fetching, current, offline };
const Focus = layout.Focus;
const JobKind = enum { batch, undo, labels_list, refresh, list, cached_search, recipient_cache, recipient_refresh, read, thread, drafts, draft_read, draft_operations, compose, autosave, identities, save, save_review, save_back, send, contacts, contact_write, mutation, invitation_inspect, invitation, open, attachment_save };
const SyncState = enum { fetching, refreshing, cached, current, offline, failed };
const SyncStatus = struct {
    state: SyncState = .fetching,
    last_sync_at: i64 = 0,
    cache_ready: bool = false,
    error_code: [64]u8 = @splat(0),
    error_len: usize = 0,
};
const PendingCompose = enum { none, new, reply, reply_all, forward };
const ReaderMarkup = struct { prepared: ?html_view.Prepared = null, fallback: bool = false, attempted: bool = false };
const ContactsState = enum { loading, cached, current, denied, failed, busy };
const QueryScope = enum { cache, server };
const ScrollBoundary = struct { id: []const u8, received_at: i64 = 0 };
const ReaderOverlay = enum { none, links, attachments, save_attachment, open_attachment };
const StatusKind = enum { view, failure, action, unknown };
const StatusOwner = struct {
    mode: Mode = .browse,
    account: usize = 0,
    selection: u64 = 0,
    overlay: ReaderOverlay = .none,
    labels: bool = false,
};
fn mailRowCapacity(height: usize) usize {
    // Each card takes two rows; only the gaps between cards take a third.
    return @max((height +| 1) / 3, 1);
}
fn humanError(code: []const u8) []const u8 {
    const Label = struct { code: []const u8, label: []const u8 };
    const labels = [_]Label{
        .{ .code = "PermissionDenied", .label = "Permission required for this account" },
        .{ .code = "NotConnected", .label = "Connect this account" },
        .{ .code = "OAuthClientRequired", .label = "Account connection needs setup" },
        .{ .code = "WrongAccount", .label = "Account authorization does not match" },
        .{ .code = "GrantClientMismatch", .label = "Account authorization does not match" },
        .{ .code = "CacheBusy", .label = "Cache is busy · try again" },
        .{ .code = "CacheChanged", .label = "Mail changed · try again" },
        .{ .code = "InvalidCursor", .label = "Mail changed · reload this view" },
        .{ .code = "CacheBoundaryGone", .label = "This cached boundary is no longer available" },
        .{ .code = "CacheMiss", .label = "This body is not cached yet" },
        .{ .code = "BodySizeMismatch", .label = "Mail body is incomplete" },
        .{ .code = "BodyTooLarge", .label = "Mail body exceeds the supported size" },
        .{ .code = "MessageTooLarge", .label = "Mail exceeds the supported size" },
        .{ .code = "ResponseTooLarge", .label = "Mail exceeds the supported size" },
        .{ .code = "TooManyHeaders", .label = "Mail headers exceed the supported limit" },
        .{ .code = "HeadersTooLarge", .label = "Mail headers exceed the supported limit" },
        .{ .code = "UnsupportedCharset", .label = "Unsupported mail character encoding" },
        .{ .code = "DiskQuotaExceeded", .label = "Local cache limit reached" },
        .{ .code = "MissingReplyRecipient", .label = "No external recipient to reply to" },
        .{ .code = "MissingMessageId", .label = "Mail has no valid reply identifier" },
        .{ .code = "InvalidAddress", .label = "Enter a valid email address" },
        .{ .code = "UnverifiedSender", .label = "Sending identity is not verified" },
        .{ .code = "UnknownOutcome", .label = "Outcome unknown · check before retrying" },
        .{ .code = "Timeout", .label = "Request timed out" },
        .{ .code = "Canceled", .label = "Request canceled" },
        .{ .code = "RateLimited", .label = "Gmail rate limit · try later" },
        .{ .code = "TransientFailure", .label = "Connection temporarily unavailable" },
        .{ .code = "ProviderRejected", .label = "Provider rejected the request" },
        .{ .code = "PathAlreadyExists", .label = "File already exists · choose another path" },
        .{ .code = "OperationPending", .label = "Wait for the current operation" },
        .{ .code = "OutOfMemory", .label = "Operation exceeds the memory budget" },
    };
    for (labels) |label| if (same(code, label.code)) return label.label;
    return "Operation failed · ? shows diagnostic code";
}

fn backMode(mode: Mode, previous: Mode, picker: bool) Mode {
    return switch (mode) {
        .help => previous,
        .review => .compose,
        .trash_confirm, .invitation => .browse,
        .contact_edit => .contacts,
        .contacts => if (picker) .compose else .browse,
        else => mode,
    };
}

fn refreshWaiting(result: Value) bool {
    return truth(get(result, "coalesced")) and (truth(get(result, "refreshInProgress")) or truth(get(result, "inProgress")));
}

fn refreshIsCurrent(result: Value, requested_at: i64) bool {
    if (!truth(get(result, "coalesced")) or truth(get(result, "refreshed"))) return true;
    const checked = get(result, "lastSyncAt");
    return checked == .integer and checked.integer > 0 and checked.integer >= requested_at;
}

fn bodyRefusal(message: Value) ?[]const u8 {
    const code = text(get(message, "bodyCacheError"));
    if (code.len == 0) return null;
    // Codes originate from the backend's named refusals. Only fixed labels
    // enter this UI path; a corrupt cache cannot inject provider text here.
    const known = [_][]const u8{
        "BodySizeMismatch", "BodyTooLarge", "DecodedMessageTooLarge", "MessageTooLarge", "ResponseTooLarge", "DiskQuotaExceeded", "UnsupportedCharset", "TooManyHeaders", "HeadersTooLarge", "HeaderTooLarge", "TooManyMimeParts", "MimeTooDeep", "UnsupportedTransferEncoding", "InvalidBody", "InvalidUtf8", "InvalidCharsetData", "InvalidBase64", "InvalidQuotedPrintable", "InvalidEncodedWord", "MalformedMessage", "HeaderInjection", "InvalidAddress", "InvalidHeaders", "MissingHeaderBoundary", "IncompleteMultipart", "ExternalBodyRequired", "TooManyIncomingRecipients", "RecipientHeaderTooLarge", "AttachmentsTooLarge", "TooManyAttachments", "InvalidMimeBoundary", "InvalidMimeType", "InvalidAttachmentFilename", "InvalidAttachmentId", "FilenameTooLarge", "ReferencesTooLarge", "TooManyReferences", "AmbiguousCalendarPart", "AmbiguousHeader", "AmbiguousSender", "InvalidDate", "InvalidLabels", "InvalidMessageId", "MissingMimeBoundary", "MissingMimeType", "CapacityExceeded", "InvalidRecipients", "RecipientTooLarge",
    };
    if (code.len <= 64) for (known) |label| if (same(code, label)) return label;
    return "BodyUnavailable";
}

fn readerEnvelope(allocator: Allocator, to: []const u8, cc: []const u8, stamp: []const u8) ![]const u8 {
    return if (cc.len > 0) std.fmt.allocPrint(allocator, "To: {s}\nCc: {s}\n{s}", .{ to, cc, stamp }) else std.fmt.allocPrint(allocator, "To: {s}\n{s}", .{ to, stamp });
}

fn readerEnd(lines: usize, height: usize) usize {
    return lines -| @max(height, 1);
}

fn setMouseReporting(vx: *vaxis.Vaxis, writer: *Io.Writer, enabled: bool) !void {
    // Cell coordinates remain correct even when the actual terminal is wider
    // than our bounded screen. Pixel translation would use its capped width.
    const pixels = vx.caps.sgr_pixels;
    vx.caps.sgr_pixels = false;
    defer vx.caps.sgr_pixels = pixels;
    try vx.setMouseMode(writer, enabled);
    vx.state.mouse = enabled;
    vx.state.pixel_mouse = false;
    // Clicks, wheel and button-drag reports suffice; idle pointer movement
    // must not cause large message frames to repaint.
    // Multiplexers such as Herdr/Ghostty keep one mouse-event mode: turning
    // off 1003 clears it, rather than revealing the previously enabled 1002.
    // Reassert button tracking last so remote clicks and taps still arrive.
    if (enabled) try writer.writeAll("\x1b[?1003l\x1b[?1002h");
    try writer.flush();
}
const folders = [_][]const u8{ "Inbox", "Sent", "Drafts", "Archive", "Trash", "Spam", "All Mail", "Unread" };
const folder_labels = [_][]const u8{ "INBOX", "SENT", "DRAFT", "", "TRASH", "SPAM", "", "UNREAD" };
const HelpRow = struct { keys: []const u8 = "", action: []const u8 = "", section: []const u8 = "" };
const help_rows = [_]HelpRow{
    .{ .section = "NAVIGATION" },
    .{ .keys = "j / k · arrows", .action = "Move through the focused pane" },
    .{ .keys = "h / l · Tab", .action = "Change pane; Shift+Tab goes back" },
    .{ .keys = "Enter", .action = "Open mail or choose the focused item" },
    .{ .keys = "gg / G · Home / End", .action = "First or last mail; reader start or end" },
    .{ .keys = "Ctrl+D / Ctrl+U", .action = "Half-page down or up" },
    .{ .keys = "[ / ]", .action = "Previous or next page of mail" },
    .{ .keys = "1 / 2 / 3", .action = "Switch account" },
    .{ .keys = "Click · wheel", .action = "Choose an item or scroll the pointed pane" },
    .{ .keys = "Esc / q", .action = "Go back one view; quit from the mailbox" },
    .{ .keys = "?", .action = "Open or close this help" },
    .{ .section = "SEARCH & READING" },
    .{ .keys = "/", .action = "Search retained mail in the local cache" },
    .{ .keys = "\\", .action = "Search Gmail on the server" },
    .{ .keys = "q after a search", .action = "Clear the search and return to the mailbox" },
    .{ .keys = "J / K in the reader", .action = "Next or previous mail" },
    .{ .keys = "{ / } · t", .action = "Previous/next thread message; fold its body" },
    .{ .keys = "Q / S", .action = "Fold quoted history or a standard signature" },
    .{ .keys = "L / B", .action = "Choose a URL or received attachment" },
    .{ .keys = "j / k in the reader", .action = "Scroll the current message" },
    .{ .keys = "v", .action = "Place the reader on the right or below" },
    .{ .keys = "z", .action = "Expand or shrink the reader" },
    .{ .keys = "o", .action = "Open mail in this account's browser profile" },
    .{ .keys = ":save-attachment N /path", .action = "Save attachment N to a new file" },
    .{ .section = "MAIL ACTIONS" },
    .{ .keys = "Space / Ctrl+A", .action = "Select a message / the current page" },
    .{ .keys = "Ctrl+Z / :undo", .action = "Undo the last completed action for this account" },
    .{ .keys = "c / r / R · F", .action = "Compose, reply, reply-all or forward with files" },
    .{ .keys = "x / D / U", .action = "Archive, review Trash or restore mail" },
    .{ .keys = "s / u", .action = "Toggle starred or unread" },
    .{ .keys = "m", .action = "Choose a label; / filters, Enter adds, - removes" },
    .{ .keys = "I", .action = "Review a calendar invitation reply" },
    .{ .keys = "Ctrl+R", .action = "Refresh mail" },
    .{ .keys = "Ctrl+L", .action = "Reload theme and redraw the screen" },
    .{ .section = "CONTACTS" },
    .{ .keys = "a from the mailbox", .action = "Open this account's address book" },
    .{ .keys = "/ · n / e", .action = "Search contacts; create or edit a contact" },
    .{ .keys = "Enter · Esc / q", .action = "Open a contact or choose a recipient; go back" },
    .{ .keys = "Tab · Ctrl+S · Esc", .action = "Contact editor: change field, save or cancel" },
    .{ .section = "COMPOSE & SEND" },
    .{ .keys = "Tab / Shift+Tab · j / k", .action = "Choose a draft field in normal mode" },
    .{ .keys = "i / Enter · Esc", .action = "Start editing; Esc returns to normal mode" },
    .{ .keys = "e", .action = "Edit the body with $EDITOR" },
    .{ .keys = "a", .action = "Choose a recipient from contacts" },
    .{ .keys = "Ctrl+N / Ctrl+P · Enter", .action = "Choose a cached recipient suggestion while typing" },
    .{ .keys = "f · click From", .action = "Cycle verified sending aliases in normal mode" },
    .{ .keys = "A · click Add", .action = "Attach a file using its literal path" },
    .{ .keys = ":detach N · click [x]", .action = "Remove attachment N; wheel scrolls the list" },
    .{ .keys = "Ctrl+S / :send", .action = "Save the draft and review before sending" },
    .{ .keys = "y in send review", .action = "Explicitly send; Esc / q returns to the draft" },
    .{ .keys = "Esc / q in normal mode", .action = "Save the draft and go back" },
    .{ .keys = "Ctrl+C", .action = "Cancel work; idle drafts save/back, mailbox quits" },
    .{ .action = "Draft changes autosave locally after a short pause." },
    .{ .action = "No editor save or paste sends mail." },
    .{ .action = "Autosave only saves locally; it never sends mail." },
    .{ .action = "In a text field, q is text." },
    .{ .section = "PERSONALIZE" },
    .{ .keys = ":split right 60", .action = "Use 60% of horizontal space for the mail list" },
    .{ .keys = ":split below 40", .action = "Use 40% of vertical space for the mail list" },
    .{ .keys = ":bind n down", .action = "Remap n in mailbox mode; :unbind n restores it" },
    .{ .action = "Account, mailbox, selected mail and reader scroll restore on startup." },
};

const TextPosition = text_layout.Position;
fn positionAfter(win: vaxis.Window, clean: []const u8) TextPosition {
    return text_layout.after(clean, win.width, win.screen.width_method, .{});
}
fn horizontalStart(win: vaxis.Window, clean: []const u8, available: usize) usize {
    var cells: usize = 0;
    var iterator = vaxis.unicode.graphemeIterator(clean);
    while (iterator.next()) |gr| cells += @max(win.gwidth(gr.bytes(clean)), 1);
    var drop = cells -| available;
    iterator = vaxis.unicode.graphemeIterator(clean);
    var start: usize = 0;
    while (drop > 0) {
        const gr = iterator.next() orelse break;
        drop -|= @max(win.gwidth(gr.bytes(clean)), 1);
        start = gr.start + gr.len;
    }
    return start;
}

fn saveAttachmentResponse(io: Io, allocator: Allocator, response: []const u8, path: []const u8, expected_size: usize) !void {
    if (response.len > types.Limits.request_bytes) return error.ResponseTooLarge;
    const parsed = try std.json.parseFromSliceLeaky(Value, allocator, response, .{ .allocate = .alloc_always, .max_value_len = types.Limits.request_bytes });
    const ok = get(parsed, "ok");
    if (ok == .bool and !ok.bool) return; // The main thread displays its stable rejection code.
    if (!truth(ok)) return error.InvalidProviderResponse;
    const result = get(parsed, "data");
    const size = get(result, "size");
    const encoded = get(result, "data");
    if (size != .integer or size.integer < 0 or size.integer > @as(i64, @intCast(types.Limits.body_bytes)) or encoded != .string) return error.InvalidAttachment;
    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded.string) catch return error.InvalidAttachmentData;
    if (decoded_size != @as(usize, @intCast(size.integer)) or decoded_size != expected_size) return error.AttachmentSizeMismatch;
    const decoded = try allocator.alloc(u8, decoded_size);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded.string);
    // O_CREAT|O_EXCL rejects existing files and leaf symlinks. The explicit
    // user's path is the only output path; provider filenames are never used.
    const created = try path_completion.createExclusive(io, path);
    defer created.close(io);
    errdefer created.remove(io);
    try created.file.writeStreamingAll(io, decoded);
}

var signal_fd: std.atomic.Value(i32) = .init(-1);
var received_signal: std.atomic.Value(u8) = .init(0);
var active: std.atomic.Value(bool) = .init(false);
pub const reservation_bytes = @sizeOf(@TypeOf(signal_fd)) + @sizeOf(@TypeOf(received_signal)) + @sizeOf(@TypeOf(active));

pub fn recover() void {
    if (active.load(.acquire)) vaxis.recover();
}
fn onSignal(signal: std.posix.SIG) callconv(.c) void {
    received_signal.store(@intCast(@backingInt(signal)), .release);
    const fd = signal_fd.load(.acquire);
    if (fd >= 0) {
        const one: u64 = 1;
        _ = std.os.linux.write(fd, std.mem.asBytes(&one).ptr, 8);
    }
}

fn get(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn text(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn items(value: Value) []const Value {
    return if (value == .array) value.array.items else &.{};
}
fn integer(value: Value) i64 {
    return if (value == .integer) value.integer else 0;
}
fn truth(value: Value) bool {
    return value == .bool and value.bool;
}
fn timestamp(allocator: Allocator, zone: *const timezone.Zone, value_in: Value) ![]const u8 {
    return zone.format(allocator, if (value_in == .integer) value_in.integer else 0);
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// All terminal text passes here, including metadata and locally edited text.
/// Newlines survive only in bodies; terminal/bidi controls never survive.
fn safe(allocator: Allocator, input: []const u8, multiline: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Invalid bytes/controls shrink or replace with one byte; valid UTF8 is
    // copied unchanged. Reserve the exact input upper bound once so frame
    // arenas do not retain a geometric chain for a large plain fallback.
    try out.ensureTotalCapacityPrecise(allocator, input.len);
    var pos: usize = 0;
    while (pos < input.len) {
        const length = std.unicode.utf8ByteSequenceLength(input[pos]) catch {
            try out.append(allocator, '?');
            pos += 1;
            continue;
        };
        if (length > input.len - pos) break;
        const cp = std.unicode.utf8Decode(input[pos..][0..length]) catch {
            try out.append(allocator, '?');
            pos += 1;
            continue;
        };
        if ((cp == '\n' or cp == '\t') and multiline) {
            try out.append(allocator, @intCast(cp));
        } else if (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) {
            try out.append(allocator, ' ');
        } else try out.appendSlice(allocator, input[pos..][0..length]);
        pos += length;
    }
    // libvaxis retains a copy per cell in its previous-screen arena. Apply the
    // same grapheme bound to metadata printSegment and body writeCell paths.
    var graphemes = vaxis.unicode.graphemeIterator(out.items);
    while (graphemes.next()) |gr| if (gr.len > 128) {
        var limited: std.ArrayList(u8) = .empty;
        errdefer limited.deinit(allocator);
        try limited.ensureTotalCapacityPrecise(allocator, out.items.len);
        try limited.appendSlice(allocator, out.items[0..gr.start]);
        try limited.appendSlice(allocator, "�");
        while (graphemes.next()) |next_gr| try limited.appendSlice(allocator, if (next_gr.len > 128) "�" else next_gr.bytes(out.items));
        out.deinit(allocator);
        out = .empty;
        return limited.toOwnedSlice(allocator);
    };
    if (out.items.len == out.capacity) {
        const owned = out.items;
        out = .empty;
        return owned;
    }
    return out.toOwnedSlice(allocator);
}

const Field = struct {
    bytes: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    fn deinit(self: *Field, allocator: Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }
    fn set(self: *Field, allocator: Allocator, input_value: []const u8) !void {
        // Keep the previous value if the bounded allocator refuses growth.
        try self.bytes.ensureTotalCapacity(allocator, input_value.len);
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSliceAssumeCapacity(input_value);
        self.cursor = input_value.len;
    }
    fn value(self: *const Field) []const u8 {
        return self.bytes.items;
    }
    fn insert(self: *Field, allocator: Allocator, value_in: []const u8, limit: usize) !void {
        if (value_in.len > limit -| self.bytes.items.len) return error.InputTooLarge;
        if (!std.unicode.utf8ValidateSlice(value_in)) return error.InvalidUtf8;
        try self.bytes.insertSlice(allocator, self.cursor, value_in);
        self.cursor += value_in.len;
    }
    fn previous(self: *const Field) usize {
        var iterator = vaxis.unicode.graphemeIterator(self.bytes.items);
        var result: usize = 0;
        while (iterator.next()) |gr| {
            if (gr.start >= self.cursor) break;
            result = gr.start;
        }
        return result;
    }
    fn next(self: *const Field) usize {
        var iterator = vaxis.unicode.graphemeIterator(self.bytes.items);
        while (iterator.next()) |gr| if (gr.start + gr.len > self.cursor) return gr.start + gr.len;
        return self.bytes.items.len;
    }
    fn vertical(self: *Field, down: bool) void {
        const start = if (std.mem.lastIndexOfScalar(u8, self.bytes.items[0..self.cursor], '\n')) |index| index + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, self.bytes.items, self.cursor, '\n') orelse self.bytes.items.len;
        const target_start = if (down) blk: {
            if (end == self.bytes.items.len) return;
            break :blk end + 1;
        } else blk: {
            if (start == 0) return;
            break :blk if (std.mem.lastIndexOfScalar(u8, self.bytes.items[0 .. start - 1], '\n')) |index| index + 1 else 0;
        };
        const target_end = std.mem.indexOfScalarPos(u8, self.bytes.items, target_start, '\n') orelse self.bytes.items.len;
        var target_column: usize = 0;
        var current = vaxis.unicode.graphemeIterator(self.bytes.items[start..self.cursor]);
        while (current.next()) |gr| target_column += vaxis.gwidth.gwidth(gr.bytes(self.bytes.items[start..self.cursor]), .unicode);
        var column: usize = 0;
        var target = vaxis.unicode.graphemeIterator(self.bytes.items[target_start..target_end]);
        self.cursor = target_start;
        while (target.next()) |gr| {
            const width = vaxis.gwidth.gwidth(gr.bytes(self.bytes.items[target_start..target_end]), .unicode);
            if (column + width > target_column) break;
            column += width;
            self.cursor = target_start + gr.start + gr.len;
        }
    }
    fn handleKey(self: *Field, allocator: Allocator, key: Key, multiline: bool, limit: usize) !void {
        if (key.matches(Key.left, .{})) self.cursor = self.previous() else if (key.matches(Key.right, .{})) self.cursor = self.next() else if (multiline and key.matches(Key.up, .{})) self.vertical(false) else if (multiline and key.matches(Key.down, .{})) self.vertical(true) else if (key.matches(Key.home, .{})) self.cursor = if (std.mem.lastIndexOfScalar(u8, self.bytes.items[0..self.cursor], '\n')) |index| index + 1 else 0 else if (key.matches(Key.end, .{})) self.cursor = std.mem.indexOfScalarPos(u8, self.bytes.items, self.cursor, '\n') orelse self.bytes.items.len else if (key.matches(Key.backspace, .{})) {
            const from = self.previous();
            const count = self.cursor - from;
            std.mem.copyForwards(u8, self.bytes.items[from..], self.bytes.items[self.cursor..]);
            self.bytes.items.len -= count;
            self.cursor = from;
        } else if (key.matches(Key.delete, .{})) {
            const to = self.next();
            const count = to - self.cursor;
            std.mem.copyForwards(u8, self.bytes.items[self.cursor..], self.bytes.items[to..]);
            self.bytes.items.len -= count;
        } else if (multiline and key.matches(Key.enter, .{})) try self.insert(allocator, "\n", limit) else if (multiline and key.matches(Key.tab, .{})) try self.insert(allocator, "    ", limit) else if (!key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            if (key.text) |value_in| {
                for (value_in) |c| if (c == 0 or c == 0x1b or (!multiline and (c == '\r' or c == '\n'))) return error.InvalidInput;
                try self.insert(allocator, value_in, limit);
            }
        }
    }
};

const Compose = struct {
    fields: [5]Field = @splat(.{}),
    id: Field = .{},
    thread: Field = .{},
    reply: Field = .{},
    references: Field = .{},
    operation_id: Field = .{},
    operation_error: Field = .{},
    from: Field = .{},
    from_name: Field = .{},
    attachments: []const types.Attachment = &.{},
    attachment_arena: ?std.heap.ArenaAllocator = null,
    selected: usize = 0,
    body_scroll: usize = 0,
    attachment_scroll: usize = 0,
    attachment_height: usize = 0,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    completion_selected: usize = 0,
    signature: Field = .{},
    signature_custom: bool = false,
    new_draft: bool = false,
    insert_mode: bool = false,
    unknown_outcome: bool = false,
    fn deinit(self: *Compose, allocator: Allocator) void {
        for (&self.fields) |*field| field.deinit(allocator);
        self.id.deinit(allocator);
        self.thread.deinit(allocator);
        self.reply.deinit(allocator);
        self.references.deinit(allocator);
        self.operation_id.deinit(allocator);
        self.operation_error.deinit(allocator);
        self.from.deinit(allocator);
        self.from_name.deinit(allocator);
        self.signature.deinit(allocator);
        if (self.attachment_arena) |*arena| arena.deinit();
        self.attachment_arena = null;
        self.attachments = &.{};
    }
    fn mailboxes(allocator: Allocator, value: Value) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (items(value), 0..) |mailbox, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, text(get(mailbox, "address")));
        }
        return out.toOwnedSlice(allocator);
    }
    fn load(self: *Compose, allocator: Allocator, value_in: Value) !void {
        self.deinit(allocator);
        self.* = .{};
        for ([_][]const u8{ "to", "cc", "bcc" }, 0..) |name, index| {
            const raw = try mailboxes(allocator, get(value_in, name));
            defer allocator.free(raw);
            try self.fields[index].set(allocator, raw);
        }
        try self.fields[3].set(allocator, text(get(value_in, "subject")));
        try self.fields[4].set(allocator, text(get(value_in, "bodyText")));
        try self.id.set(allocator, text(get(value_in, "id")));
        try self.thread.set(allocator, text(get(value_in, "threadId")));
        try self.reply.set(allocator, text(get(value_in, "inReplyTo")));
        try self.references.set(allocator, text(get(value_in, "references")));
        try self.from.set(allocator, text(get(get(value_in, "from"), "address")));
        try self.from_name.set(allocator, text(get(get(value_in, "from"), "name")));
        const recovery_fields = get(value_in, "recoveryFields");
        if (recovery_fields != .null) {
            if (recovery_fields != .array or recovery_fields.array.items.len != self.fields.len) return error.InvalidRecoveryDraft;
            for (&self.fields, recovery_fields.array.items) |*field, raw| {
                if (raw != .string) return error.InvalidRecoveryDraft;
                try field.set(allocator, raw.string);
            }
        }
        const attachments = get(value_in, "attachments");
        if (attachments != .null) {
            if (attachments != .array or attachments.array.items.len > 16) return error.TooManyAttachments;
            self.attachment_arena = .init(allocator);
            self.attachments = try std.json.parseFromValueLeaky([]const types.Attachment, self.attachment_arena.?.allocator(), attachments, .{});
        }
    }
    fn addresses(allocator: Allocator, raw: []const u8) ![]types.Address {
        var list: recipients.List = .{};
        try recipients.parse(raw, &list);
        const result = try allocator.alloc(types.Address, list.count);
        for (list.slice(), 0..) |*mailbox, index| result[index] = .{
            .address = try allocator.dupe(u8, mailbox.address.slice()),
            .name = try allocator.dupe(u8, mailbox.name.slice()),
        };
        return result;
    }
    fn draft(self: *Compose, allocator: Allocator) !types.Draft {
        try recipients.validateHeader(self.fields[3].value());
        return .{
            .id = self.id.value(),
            .to = try addresses(allocator, self.fields[0].value()),
            .cc = try addresses(allocator, self.fields[1].value()),
            .bcc = try addresses(allocator, self.fields[2].value()),
            .subject = self.fields[3].value(),
            .bodyText = self.fields[4].value(),
            .threadId = self.thread.value(),
            .inReplyTo = self.reply.value(),
            .references = self.references.value(),
            .attachments = self.attachments,
            .from = if (self.from.value().len == 0) null else .{ .address = self.from.value(), .name = self.from_name.value() },
        };
    }
    fn recovery(self: *Compose, fields: *[5][]const u8) types.Draft {
        for (&self.fields, fields) |*field, *raw| raw.* = field.value();
        return .{
            .id = self.id.value(),
            .from = if (self.from.value().len == 0) null else .{ .address = self.from.value(), .name = self.from_name.value() },
            .threadId = self.thread.value(),
            .inReplyTo = self.reply.value(),
            .references = self.references.value(),
            .attachments = self.attachments,
            .recoveryFields = fields,
        };
    }
    fn replaceAttachments(self: *Compose, allocator: Allocator, input_attachments: []const types.Attachment) !void {
        if (input_attachments.len > 16) return error.TooManyAttachments;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc(types.Attachment, input_attachments.len);
        for (input_attachments, owned) |item, *copy| copy.* = .{
            .id = try arena.allocator().dupe(u8, item.id),
            .filename = try arena.allocator().dupe(u8, item.filename),
            .mimeType = try arena.allocator().dupe(u8, item.mimeType),
            .size = item.size,
            .data = try arena.allocator().dupe(u8, item.data),
        };
        if (self.attachment_arena) |*previous| previous.deinit();
        self.attachment_arena = arena;
        self.attachments = owned;
    }
};

const Job = struct {
    kind: JobKind = .list,
    request: []const u8 = "",
    response: ?[]const u8 = null,
    failure: ?anyerror = null,
    generation: u64 = 0,
    selection_generation: u64 = 0,
    account_index: usize = 0,
    contacts_generation: u64 = 0,
    requested_at: i64 = 0,
    saved_attachment_open: bool = false,
    progress: fetch_progress.Mailbox = .{},
    loading_rows: loading.Mailbox = .{},
    waiting_external: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
};

const App = struct {
    io: Io,
    allocator: Allocator,
    client: types.Client,
    options: types.Options,
    environ: *const std.process.Environ.Map,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    loop: *Loop,
    cancellation: Io.Event = .unset,
    account_arena: std.heap.ArenaAllocator,
    list_arena: std.heap.ArenaAllocator,
    read_arena: std.heap.ArenaAllocator,
    contact_arena: std.heap.ArenaAllocator,
    job_arena: std.heap.ArenaAllocator,
    frame: std.heap.ArenaAllocator,
    accounts: []const Value = &.{},
    account_index: usize = 0,
    account_positions: [3]usize = @splat(0),
    messages: []const Value = &.{},
    thread: []const Value = &.{},
    markup: []ReaderMarkup = &.{},
    html_stats: html_view.Stats = .{},
    mouse_hits: layout.HitMap = .{},
    contacts: []const Value = &.{},
    selected: usize = 0,
    top: usize = 0,
    reader_scroll: usize = 0,
    reader_lines: usize = 0,
    reader_height: usize = 0,
    reader_account: Field = .{},
    reader_message: Field = .{},
    reader_partial: bool = false,
    reader_is_thread: bool = false,
    reader_cards: [types.Limits.page]bool = @splat(true),
    reader_card_rows: [types.Limits.page]usize = @splat(0),
    reader_card: usize = 0,
    reader_anchor_card: bool = false,
    reader_card_pinned: bool = false,
    fold_quotes: bool = false,
    fold_signatures: bool = false,
    reader_overlay: ReaderOverlay = .none,
    reader_overlay_arena: ?std.heap.ArenaAllocator = null,
    reader_links: reader_tools.Links = .{},
    reader_choice: usize = 0,
    reader_path: Field = .{},
    reader_default_directory: Field = .{},
    path_candidates: path_completion.State = .{},
    reader_attachment_message: Field = .{},
    reader_attachment_id: Field = .{},
    reader_attachment_name: Field = .{},
    reader_attachment_size: usize = 0,
    attachment_open_after: bool = false,
    restore_message: Field = .{},
    restore_reader_scroll: ?usize = null,
    restore_reader_thread: bool = false,
    search_saved_valid: bool = false,
    search_saved_account: Field = .{},
    search_saved_label: Field = .{},
    search_saved_message: Field = .{},
    search_saved_folder: usize = 0,
    search_saved_selected: usize = 0,
    search_saved_top: usize = 0,
    search_saved_scroll: usize = 0,
    search_saved_focus: Focus = .list,
    search_saved_expanded: bool = false,
    search_saved_thread: bool = false,
    search_restore_pending: bool = false,
    body_cache_miss: bool = false,
    reader_cache_busy: bool = false,
    cache_busy: bool = false,
    view_generation: u64 = 0,
    view_ready: bool = false,
    list_cached: bool = false,
    list_partial: bool = false,
    cache_view_missing: bool = false,
    sync: [3]SyncStatus = @splat(.{}),
    help_scroll: usize = 0,
    help_lines: usize = 0,
    help_height: usize = 0,
    contacts_selected: usize = 0,
    contacts_generation: u64 = 0,
    contacts_query: Field = .{},
    contacts_account: Field = .{},
    contacts_state: ContactsState = .loading,
    contacts_cache_ready: bool = false,
    recipient_arena: ?std.heap.ArenaAllocator = null,
    recipient_values: []const Value = &.{},
    recipient_account: Field = .{},
    recipient_ready: bool = false,
    pending_recipient_cache: bool = false,
    pending_recipient_refresh: bool = false,
    recipient_refreshed: [3]bool = @splat(false),
    compose_original: bool = false,
    pending_contacts: bool = false,
    pending_cached_contacts: bool = false,
    folder: usize = 0,
    custom_label: Field = .{},
    mail_selection: selection.Selection = .{},
    action_notice: bool = false,
    undo_token: Field = .{},
    undo_account: Field = .{},
    labels: []const Value = &.{},
    label_arena: ?std.heap.ArenaAllocator = null,
    labels_account: Field = .{},
    pending_labels: bool = false,
    label_picker: bool = false,
    label_filtering: bool = false,
    label_filter: Field = .{},
    label_target: Field = .{},
    label_choice: usize = 0,
    search_highlight: Field = .{},
    search_matches: []const Value = &.{},
    navigation: usize = 0,
    focus: Focus = .list,
    mode: Mode = .browse,
    previous_mode: Mode = .browse,
    expanded: bool = false,
    drafts_list: bool = false,
    picker: bool = false,
    paste: bool = false,
    quit: bool = false,
    pending_list: bool = false,
    pending_remote_list: bool = false,
    pending_cached_list: bool = false,
    // Legacy state-only unit fixtures do not initialize an event loop. A
    // dedicated worker test opts into the same asynchronous production path.
    synchronous_cache_search: bool = @import("builtin").is_test,
    pending_cached_read: bool = false,
    pending_cached_thread: bool = false,
    pending_read: bool = false,
    pending_thread: bool = false,
    pending_page: bool = false,
    pending_page_account: usize = 0,
    pending_page_generation: u64 = 0,
    pending_page_forward: bool = true,
    pending_page_automatic: bool = false,
    pending_page_received_at: i64 = 0,
    pending_window_provider: bool = false,
    pending_page_boundary: Field = .{},
    page_loading: bool = false,
    page_loading_account: usize = 0,
    page_loading_generation: u64 = 0,
    page_loading_forward: bool = true,
    page_select_nearest: bool = false,
    page_relative: bool = false,
    page_relative_boundary: Field = .{},
    page_relative_received_at: i64 = 0,
    has_more_cached_before: ?bool = null,
    has_more_cached_after: ?bool = null,
    page_previous_generation: u64 = 0,
    page_previous_selected: usize = 0,
    page_previous_top: usize = 0,
    page_previous_cursor: Field = .{},
    page_previous_stack_depth: usize = 0,
    page_popped_cursor: ?[]u8 = null,
    pending_compose: PendingCompose = .none,
    pending_compose_account: [254]u8 = undefined,
    pending_compose_account_len: usize = 0,
    pending_compose_id: [256]u8 = undefined,
    pending_compose_id_len: usize = 0,
    invitation_review: invitation.Invitation = .{},
    invitation_operation_id: Field = .{},
    invitation_operation_error: Field = .{},
    invitation_unknown: bool = false,
    invitation_message_id: Field = .{},
    invitation_inspected_id: Field = .{},
    invitation_inspected_account: Field = .{},
    invitation_account: Field = .{},
    invitation_scroll: usize = 0,
    invitation_lines: usize = 0,
    invitation_height: usize = 0,
    invitation_confirm_ready: bool = false,
    attachment_destination: Field = .{},
    attachment_expected_size: usize = 0,
    generation: u64 = 0,
    selection_generation: u64 = 0,
    g_pending: bool = false,
    g_at: i64 = 0,
    query: Field = .{},
    query_scope: QueryScope = .cache,
    input_query_scope: QueryScope = .cache,
    input: Field = .{},
    cursor: Field = .{},
    next_cursor: Field = .{},
    previous_cursor: Field = .{},
    remote_cursor: Field = .{},
    // Explicit previous-page cursor stack, bounded by cache metadata budget.
    previous_cursors: std.ArrayList([]u8) = .empty,
    compose: Compose = .{},
    compose_active: bool = false,
    identity_arena: ?std.heap.ArenaAllocator = null,
    identities: []const Value = &.{},
    identities_account: Field = .{},
    pending_identities: bool = false,
    autosave_timer: ?Io.Future(void) = null,
    loading_timer: ?Io.Future(void) = null,
    loading_tick_pending: std.atomic.Value(bool) = .init(false),
    loading_frame: usize = 0,
    autosave_last_edit: std.atomic.Value(i64) = .init(0),
    autosave_started: i64 = 0,
    autosave_due: bool = false,
    autosave_revision: u64 = 0,
    contact_name: Field = .{},
    contact_email: Field = .{},
    contact_id: Field = .{},
    contact_etag: Field = .{},
    contact_field: usize = 0,
    editor_exit: ?u8 = null,
    status: [256]u8 = @splat(0),
    status_len: usize = 0,
    status_kind: StatusKind = .view,
    status_owner: StatusOwner = .{},
    status_error_code: [64]u8 = @splat(0),
    status_error_len: usize = 0,
    warning: bool = false,
    job: Job = .{},
    mono: bool = false,
    palette: theme.Palette = .{},
    reader_layout: layout.ReaderLayout = .right,
    preferences_file: Field = .{},
    ui_preferences: preferences.Preferences = .{},
    preferences_warning: bool = false,
    theme_warning: bool = false,
    zone: timezone.Zone = .{},

    fn deinit(self: *App) void {
        self.recipient_account.deinit(self.allocator);
        if (self.recipient_arena) |*arena| arena.deinit();
        self.custom_label.deinit(self.allocator);
        self.undo_token.deinit(self.allocator);
        self.undo_account.deinit(self.allocator);
        self.labels_account.deinit(self.allocator);
        self.label_filter.deinit(self.allocator);
        self.label_target.deinit(self.allocator);
        self.search_highlight.deinit(self.allocator);
        if (self.label_arena) |*arena| arena.deinit();
        self.cancelAutosaveTimer();
        self.cancelJob();
        self.clearMarkup();
        self.pending_page_boundary.deinit(self.allocator);
        self.page_previous_cursor.deinit(self.allocator);
        self.page_relative_boundary.deinit(self.allocator);
        if (self.reader_overlay_arena) |*arena| arena.deinit();
        self.reader_path.deinit(self.allocator);
        self.reader_default_directory.deinit(self.allocator);
        self.path_candidates.deinit();
        self.reader_attachment_message.deinit(self.allocator);
        self.reader_attachment_id.deinit(self.allocator);
        self.reader_attachment_name.deinit(self.allocator);
        self.restore_message.deinit(self.allocator);
        self.search_saved_account.deinit(self.allocator);
        self.search_saved_label.deinit(self.allocator);
        self.search_saved_message.deinit(self.allocator);
        self.clearHistory();
        self.previous_cursors.deinit(self.allocator);
        for ([_]*Field{ &self.query, &self.input, &self.cursor, &self.next_cursor, &self.previous_cursor, &self.remote_cursor, &self.reader_account, &self.reader_message, &self.contact_name, &self.contact_email, &self.contact_id, &self.contact_etag, &self.contacts_query, &self.contacts_account, &self.invitation_operation_id, &self.invitation_operation_error, &self.invitation_message_id, &self.invitation_inspected_id, &self.invitation_inspected_account, &self.invitation_account, &self.attachment_destination, &self.preferences_file }) |field| field.deinit(self.allocator);
        self.compose.deinit(self.allocator);
        self.identities_account.deinit(self.allocator);
        if (self.identity_arena) |*arena| arena.deinit();
        self.frame.deinit();
        self.job_arena.deinit();
        self.contact_arena.deinit();
        self.read_arena.deinit();
        self.list_arena.deinit();
        self.account_arena.deinit();
        self.zone.deinit(self.allocator);
    }
    fn account(self: *const App) []const u8 {
        return if (self.account_index < self.accounts.len) text(get(self.accounts[self.account_index], "address")) else "";
    }
    fn ensureMailSelection(self: *App) !void {
        var scope_buffer: [1024]u8 = undefined;
        const scope = try std.fmt.bufPrint(&scope_buffer, "{d}:{s}:{s}", .{ self.folder, @tagName(self.query_scope), self.activeLabel() });
        try self.mail_selection.ensureScope(self.account(), scope, self.query.value());
    }
    fn batchMail(self: *App, action: []const u8, unread: ?bool, starred: ?bool, add_labels: ?[]const []const u8, remove_labels: ?[]const []const u8) !void {
        if (self.drafts_list) return error.DraftNotMail;
        self.preemptReadOnly();
        if (self.job.future != null) return error.OperationPending;
        try self.ensureMailSelection();
        var identifiers: [100][]const u8 = undefined;
        var count = self.mail_selection.count;
        if (count > 0) {
            for (self.mail_selection.ids[0..count], 0..) |*identifier, index| identifiers[index] = identifier.slice();
        } else {
            const identifier = if (self.label_picker and self.label_target.value().len > 0) self.label_target.value() else self.readerReplyId();
            if (identifier.len == 0) return;
            identifiers[0] = identifier;
            count = 1;
        }
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), .{
            .cmd = "mail.batch",
            .account = self.account(),
            .messageIds = identifiers[0..count],
            .action = action,
            .unread = unread,
            .starred = starred,
            .addLabels = add_labels,
            .removeLabels = remove_labels,
        }, .{ .emit_null_optional_fields = false });
        const request_value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), encoded, .{});
        try self.start(.batch, request_value);
        self.label_picker = false;
    }
    fn undoMail(self: *App) !void {
        if (self.undo_token.value().len == 0 or !same(self.undo_account.value(), self.account())) {
            self.say(false, "No completed action to undo for this account", .{});
            return;
        }
        self.preemptReadOnly();
        if (self.job.future != null) return error.OperationPending;
        try self.start(.undo, .{ .cmd = "mail.undo", .account = self.account(), .undoToken = self.undo_token.value() });
    }
    fn labelMatches(self: *App, label_value: Value) bool {
        return cache_query.find(text(get(label_value, "name")), self.label_filter.value()) != null or self.label_filter.value().len == 0;
    }
    fn visibleLabelIndex(self: *App, selected: usize) ?usize {
        var found: usize = 0;
        for (self.labels, 0..) |label_value, index| if (self.labelMatches(label_value)) {
            if (found == selected) return index;
            found += 1;
        };
        return null;
    }
    fn visibleLabelCount(self: *App) usize {
        var count: usize = 0;
        for (self.labels) |label_value| if (self.labelMatches(label_value)) {
            count += 1;
        };
        return count;
    }
    fn replaceLabels(self: *App, response: []const u8) !void {
        if (self.label_arena) |*arena| arena.deinit();
        self.labels = &.{};
        self.label_arena = .init(self.allocator);
        const result_value = try self.data(self.label_arena.?.allocator(), response);
        self.labels = items(get(result_value, "labels"));
        if (self.labels.len > 512) return error.LabelLimitExceeded;
        try self.labels_account.set(self.allocator, self.account());
        self.pending_labels = false;
    }
    fn prepareLabels(self: *App) !void {
        if (same(self.labels_account.value(), self.account()) and self.labels.len > 0) return;
        self.labels = &.{};
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const labels_response = self.cached(arena.allocator(), .{ .cmd = "labels.list", .account = self.account(), .cacheOnly = true }) catch null;
        if (labels_response) |response| self.replaceLabels(response) catch {};
        if (!same(self.labels_account.value(), self.account()) or self.labels.len == 0) self.pending_labels = true;
    }
    fn openLabelPicker(self: *App) !void {
        if (self.drafts_list) return;
        try self.ensureMailSelection();
        try self.label_target.set(self.allocator, self.readerReplyId());
        try self.label_filter.set(self.allocator, "");
        self.label_choice = 0;
        self.label_filtering = false;
        self.label_picker = true;
        try self.prepareLabels();
        if (self.pending_labels) self.preemptReadOnly();
        try self.dispatchPending();
    }
    fn chooseLabel(self: *App, remove: bool) !void {
        const index = self.visibleLabelIndex(self.label_choice) orelse return;
        const label = [_][]const u8{text(get(self.labels[index], "id"))};
        if (label[0].len == 0) return error.InvalidLabel;
        try self.batchMail("mark", null, null, if (remove) null else &label, if (remove) &label else null);
    }
    fn onLabelPickerKey(self: *App, key: Key) !void {
        if (self.paste) {
            if (self.label_filtering) if (key.text) |raw| try self.label_filter.insert(self.allocator, try safe(self.frame.allocator(), raw, false), 256);
            return;
        }
        if (self.label_filtering) {
            if (key.matches(Key.escape, .{}) or key.matches(Key.enter, .{})) self.label_filtering = false else try self.label_filter.handleKey(self.allocator, key, false, 256);
            self.label_choice = 0;
            return;
        }
        const count = self.visibleLabelCount();
        if (key.matches(Key.escape, .{}) or key.matches('q', .{})) self.label_picker = false else if (key.matches('/', .{})) self.label_filtering = true else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.label_choice = @min(self.label_choice +| 1, count -| 1) else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.label_choice -|= 1 else if (key.matches(Key.home, .{})) self.label_choice = 0 else if (key.matches(Key.end, .{})) self.label_choice = count -| 1 else if (key.matches(Key.enter, .{}) or key.matches('+', .{})) try self.chooseLabel(false) else if (key.matches('-', .{})) try self.chooseLabel(true);
    }
    fn drawLabelPicker(self: *App, win: vaxis.Window) !void {
        if (!self.label_picker) return;
        const width = @min(win.width -| 2, 72);
        const height = @min(win.height -| 2, 24);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, " Choose label ", true);
        self.mouse_hits.clear();
        try self.line(inner, 0, try std.fmt.allocPrint(self.frame.allocator(), "Filter: {s}{s}", .{ self.label_filter.value(), if (self.label_filtering) "▏" else "" }), if (self.label_filtering) .selected else .muted);
        const rows: usize = inner.height -| 4;
        const count = self.visibleLabelCount();
        self.label_choice = @min(self.label_choice, count -| 1);
        const first = if (self.label_choice >= rows and rows > 0) self.label_choice - rows + 1 else 0;
        if (count == 0) try self.line(inner, 2, if (self.pending_labels or (self.job.future != null and self.job.kind == .labels_list)) "Loading labels…" else "No matching labels", .muted);
        for (first..@min(count, first + rows)) |choice| {
            const index = self.visibleLabelIndex(choice) orelse continue;
            try self.line(inner, choice - first + 2, text(get(self.labels[index], "name")), if (choice == self.label_choice) .selected else .text);
            self.mouseRows(inner, choice - first + 2, 1, .label_choice, choice);
        }
        if (inner.height > 1) {
            try self.line(inner, inner.height - 1, "[Add]  [Remove]  / Filter · Esc/q Back", .accent);
            self.mouseArea(inner.child(.{ .y_off = @intCast(inner.height - 1), .width = @min(inner.width, 5), .height = 1 }), .label_add, 0);
            if (inner.width > 7) self.mouseArea(inner.child(.{ .x_off = 7, .y_off = @intCast(inner.height - 1), .width = @min(inner.width - 7, 8), .height = 1 }), .label_remove, 0);
        }
    }
    fn onMailControls(self: *App, key: Key) !bool {
        if (self.mode != .browse) return false;
        try self.ensureMailSelection();
        if ((key.matches('q', .{}) or key.matches(Key.escape, .{})) and self.mail_selection.count > 0) {
            self.mail_selection.clear();
            self.say(false, "Selection cleared", .{});
            return true;
        }
        if (key.matches(' ', .{}) and self.focus == .list and !self.drafts_list) {
            const id = self.messageId();
            if (id.len > 0) {
                try self.mail_selection.toggle(id);
                try self.move(true, 1);
            }
            self.say(false, "{d} selected · x Archive · D Trash · m Label · :undo", .{self.mail_selection.count});
            return true;
        }
        if (key.matches('a', .{ .ctrl = true }) and self.focus == .list and !self.drafts_list) {
            self.mail_selection.clear();
            for (self.messages) |message| try self.mail_selection.toggle(text(get(message, "id")));
            self.say(false, "{d} selected on this page", .{self.mail_selection.count});
            return true;
        }
        if (key.matches('z', .{ .ctrl = true })) {
            try self.undoMail();
            return true;
        }
        if (key.matches('m', .{})) {
            try self.openLabelPicker();
            return true;
        }
        if (key.matches('x', .{})) {
            try self.batchMail("archive", null, null, null, null);
            return true;
        }
        if (key.matches('D', .{}) or key.matches('d', .{ .shift = true })) {
            self.mode = .trash_confirm;
            return true;
        }
        if (key.matches('U', .{}) or key.matches('u', .{ .shift = true })) {
            try self.batchMail("restore", null, null, null, null);
            return true;
        }
        if (key.matches('s', .{})) {
            var starred = false;
            if (self.selectedMessage()) |message| for (items(get(message, "labels"))) |label| {
                if (same(text(label), "STARRED")) starred = true;
            };
            try self.batchMail("mark", null, !starred, null, null);
            return true;
        }
        if (key.matches('u', .{})) {
            try self.batchMail("mark", if (self.selectedMessage()) |message| !truth(get(message, "unread")) else true, null, null, null);
            return true;
        }
        return false;
    }

    fn userLabelCount(self: *App) usize {
        var count: usize = 0;
        for (self.labels) |label_value| {
            if (same(text(get(label_value, "type")), "user")) count += 1;
        }
        return count;
    }
    fn userLabelIndex(self: *App, selected: usize) ?usize {
        var count: usize = 0;
        for (self.labels, 0..) |label_value, index| {
            if (!same(text(get(label_value, "type")), "user")) continue;
            if (count == selected) return index;
            count += 1;
        }
        return null;
    }
    fn mailboxTitle(self: *App) []const u8 {
        if (self.custom_label.value().len == 0) return folders[self.folder];
        for (self.labels) |label_value| if (same(text(get(label_value, "id")), self.custom_label.value())) return text(get(label_value, "name"));
        return self.custom_label.value();
    }
    fn chooseCustomLabel(self: *App, index: usize) !void {
        if (index >= self.labels.len) return;
        self.rememberWorkingContext();
        try self.custom_label.set(self.allocator, text(get(self.labels[index], "id")));
        self.folder = 6;
        self.query_scope = .cache;
        try self.query.set(self.allocator, "");
        self.clearHistory();
        try self.cursor.set(self.allocator, "");
        self.selected = 0;
        self.top = 0;
        self.generation +%= 1;
        self.focus = .list;
        try self.reload();
    }
    fn activeLabel(self: *const App) []const u8 {
        return if (self.custom_label.value().len > 0) self.custom_label.value() else folder_labels[self.folder];
    }
    fn say(self: *App, warning: bool, comptime format: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        var overflow = false;
        writer.print(format, args) catch {
            overflow = true;
        };
        const value_in = if (writer.buffered().len != 0) writer.buffered() else "Status unavailable";
        if (self.action_notice and !warning) return;
        if (self.status_kind == .unknown and (self.compose.unknown_outcome or self.invitation_unknown) and !warning) return;
        if (warning) self.action_notice = false;
        const shortened = overflow or value_in.len > self.status.len;
        var end = @min(value_in.len, self.status.len - @as(usize, if (shortened) 3 else 0));
        while (end > 0 and !std.unicode.utf8ValidateSlice(value_in[0..end])) end -= 1;
        @memcpy(self.status[0..end], value_in[0..end]);
        if (shortened) @memcpy(self.status[end..][0..3], "…");
        self.status_len = end + @as(usize, if (shortened) 3 else 0);
        self.warning = warning;
        self.status_kind = if (warning) .failure else .view;
        self.status_owner = self.statusContext();
        self.status_error_len = 0;
    }
    fn statusContext(self: *const App) StatusOwner {
        return .{ .mode = switch (self.mode) {
            .help, .command, .search => self.previous_mode,
            .attachment => .compose,
            else => self.mode,
        }, .account = self.account_index, .selection = self.selection_generation, .overlay = self.reader_overlay, .labels = self.label_picker };
    }
    fn clearObsoleteStatus(self: *App) void {
        if (self.status_kind == .action or self.status_kind == .unknown or self.action_notice) return;
        const current = self.statusContext();
        if (!std.meta.eql(current, self.status_owner)) self.say(false, "Ready", .{});
    }
    fn diagnostic(self: *App, code: []const u8) void {
        self.status_error_len = 0;
        if (code.len == 0 or code.len > self.status_error_code.len) return;
        for (code) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return;
        @memcpy(self.status_error_code[0..code.len], code);
        self.status_error_len = code.len;
    }
    fn sayError(self: *App, code: []const u8) void {
        self.say(true, "{s}", .{humanError(code)});
        self.diagnostic(code);
        if (same(code, "UnknownOutcome")) self.status_kind = .unknown;
    }
    fn sayFailure(self: *App, prefix: []const u8, code: []const u8) void {
        self.say(true, "{s} · {s}", .{ prefix, humanError(code) });
        self.diagnostic(code);
        if (same(code, "UnknownOutcome")) self.status_kind = .unknown;
    }
    fn sayAction(self: *App, warning: bool, comptime format: []const u8, args: anytype) void {
        self.say(warning, format, args);
        self.status_kind = .action;
        self.action_notice = true;
    }
    fn reloadTheme(self: *App) void {
        self.palette = theme.load(self.io, self.allocator, self.environ) catch |err| {
            self.palette = .{};
            self.theme_warning = true;
            self.say(true, "Theme fallback · {s}", .{@errorName(err)});
            return;
        };
        self.theme_warning = false;
    }
    fn loadPreferences(self: *App) void {
        const filename = preferences.path(self.allocator, self.environ, self.options.ui_file) catch |err| {
            self.preferences_warning = true;
            self.say(true, "UI preferences fallback · {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(filename);
        self.preferences_file.set(self.allocator, filename) catch {
            self.preferences_warning = true;
            self.say(true, "UI preferences fallback · OutOfMemory", .{});
            return;
        };
        const saved = preferences.load(self.io, self.allocator, filename) catch |err| {
            self.preferences_warning = true;
            self.say(true, "UI preferences fallback · {s}", .{@errorName(err)});
            return;
        };
        self.ui_preferences = saved;
        self.reader_layout = saved.readerLayout;
        self.preferences_warning = false;
    }
    fn setReaderLayout(self: *App, value_in: layout.ReaderLayout) void {
        self.reader_layout = value_in;
        const label = @tagName(value_in);
        self.saveUiPreferences();
        self.say(self.preferences_warning, "Reader {s} · {s}", .{ label, if (self.preferences_warning) "preference not saved" else "preference saved" });
    }
    fn saveUiPreferences(self: *App) void {
        if (self.preferences_file.value().len == 0) {
            self.preferences_warning = true;
            return;
        }
        self.ui_preferences.readerLayout = self.reader_layout;
        preferences.save(self.io, self.allocator, self.preferences_file.value(), self.ui_preferences) catch |err| {
            self.preferences_warning = true;
            self.say(true, "UI preferences not saved · {s}", .{@errorName(err)});
            return;
        };
        self.preferences_warning = false;
    }
    fn rememberWorkingContext(self: *App) void {
        if (self.account().len == 0 or self.compose_active or self.query.value().len > 0) return;
        var slot: ?usize = null;
        for (&self.ui_preferences.contexts, 0..) |*entry, index| {
            if (entry.*) |*context| {
                if (same(context.account.slice(), self.account())) {
                    slot = index;
                    break;
                }
            } else if (slot == null) slot = index;
        }
        const index = slot orelse return;
        var value: preferences.Context = .{ .folder = @intCast(self.folder), .selected = @intCast(@min(self.selected, 9999)), .readerScroll = @intCast(@min(self.reader_scroll, 10000000)) };
        value.account.set(self.account()) catch return;
        value.label.set(self.custom_label.value()) catch return;
        value.message.set(self.messageId()) catch return;
        self.ui_preferences.contexts[index] = value;
        self.ui_preferences.lastAccount.set(self.account()) catch {};
    }
    fn restoreWorkingContext(self: *App) !void {
        for (&self.ui_preferences.contexts) |*entry| if (entry.*) |*context| {
            if (!same(context.account.slice(), self.account())) continue;
            self.folder = context.folder;
            try self.custom_label.set(self.allocator, context.label.slice());
            self.selected = context.selected;
            self.restore_reader_scroll = context.readerScroll;
            try self.restore_message.set(self.allocator, context.message.slice());
            self.view_ready = false;
            break;
        };
    }
    fn restoreInitialContext(self: *App) !void {
        if (self.options.account == null and self.ui_preferences.lastAccount.len > 0) {
            for (self.accounts, 0..) |entry, index| if (same(text(get(entry, "address")), self.ui_preferences.lastAccount.slice())) {
                self.account_index = index;
                break;
            };
        }
        try self.restoreWorkingContext();
        try self.prepareLabels();
    }
    fn normalizeBrowseKey(self: *App, key: Key) Key {
        if (self.mode != .browse or self.paste or self.reader_overlay != .none) return key;
        for (&self.ui_preferences.bindings) |*entry| if (entry.*) |*binding| {
            const raw = binding.key.slice();
            const ctrl = std.mem.startsWith(u8, raw, "Ctrl+");
            const character = if (ctrl) raw[5..] else raw;
            if (!key.matches(character[0], .{ .ctrl = ctrl })) continue;
            const codepoint: u21 = switch (binding.action) {
                .down => 'j',
                .up => 'k',
                .left => 'h',
                .right => 'l',
                .next_mail => 'J',
                .previous_mail => 'K',
                .compose => 'c',
                .reply => 'r',
                .reply_all => 'R',
                .contacts => 'a',
                .cache_search => '/',
                .server_search => '\\',
                .layout => 'v',
                .expand => 'z',
                .help => '?',
                .thread_next => '}',
                .thread_previous => '{',
                .thread_fold => 't',
                .quote_fold => 'Q',
                .signature_fold => 'S',
                .links => 'L',
                .attachments => 'B',
            };
            return .{ .codepoint = codepoint };
        };
        return key;
    }
    fn onReaderCommand(self: *App, command: []const u8) !bool {
        if (std.mem.startsWith(u8, command, "split ")) {
            var parts = std.mem.tokenizeScalar(u8, command[6..], ' ');
            const orientation = parts.next() orelse return error.InvalidPaneRatio;
            const percent = try std.fmt.parseInt(u8, parts.next() orelse return error.InvalidPaneRatio, 10);
            if (percent < 25 or percent > 75 or parts.next() != null) return error.InvalidPaneRatio;
            if (same(orientation, "right")) self.ui_preferences.listWidthPercent = percent else if (same(orientation, "below")) self.ui_preferences.listHeightPercent = percent else return error.InvalidPaneRatio;
            self.saveUiPreferences();
            self.say(false, "Mail pane {s}: {d}% · preference saved", .{ orientation, percent });
            return true;
        }
        if (std.mem.startsWith(u8, command, "bind ")) {
            var parts = std.mem.tokenizeScalar(u8, command[5..], ' ');
            const name = parts.next() orelse return error.InvalidKeyBinding;
            const action = std.meta.stringToEnum(preferences.Action, parts.next() orelse return error.InvalidKeyBinding) orelse return error.InvalidKeyBinding;
            if (!preferences.validKey(name) or parts.next() != null) return error.InvalidKeyBinding;
            var slot: ?usize = null;
            for (&self.ui_preferences.bindings, 0..) |*entry, index| {
                if (entry.*) |*binding| {
                    if (same(binding.key.slice(), name)) {
                        slot = index;
                        break;
                    }
                } else if (slot == null) slot = index;
            }
            var binding: preferences.Binding = .{ .action = action };
            try binding.key.set(name);
            self.ui_preferences.bindings[slot orelse return error.TooManyKeyBindings] = binding;
            self.saveUiPreferences();
            self.say(false, "Bound {s} to {s} in mailbox mode", .{ name, @tagName(action) });
            return true;
        }
        if (std.mem.startsWith(u8, command, "unbind ")) {
            const name = std.mem.trim(u8, command[7..], " ");
            for (&self.ui_preferences.bindings) |*entry| if (entry.*) |*binding| if (same(binding.key.slice(), name)) {
                entry.* = null;
                break;
            };
            self.saveUiPreferences();
            self.say(false, "Removed binding {s}", .{name});
            return true;
        }
        if (same(command, "links")) {
            try self.openReaderLinks();
            return true;
        }
        if (same(command, "attachments")) {
            self.openReaderAttachments();
            return true;
        }
        return false;
    }
    fn closeReaderOverlay(self: *App) void {
        self.path_candidates.reset();
        self.reader_overlay = .none;
        self.reader_choice = 0;
        self.reader_path.bytes.clearRetainingCapacity();
        self.reader_path.cursor = 0;
        self.reader_default_directory.bytes.clearRetainingCapacity();
        self.reader_default_directory.cursor = 0;
        self.reader_links = .{};
        if (self.reader_overlay_arena) |*arena| _ = arena.reset(.free_all);
    }
    fn openReaderLinks(self: *App) !void {
        self.closeReaderOverlay();
        if (self.reader_overlay_arena == null) self.reader_overlay_arena = .init(self.allocator);
        const allocator = self.reader_overlay_arena.?.allocator();
        for (self.thread) |message| {
            const found = try reader_tools.links(text(get(message, "bodyText")), text(get(message, "bodyHtml")), allocator);
            for (found.values[0..found.count]) |url| self.reader_links.add(try allocator.dupe(u8, url));
            self.reader_links.truncated = self.reader_links.truncated or found.truncated;
        }
        self.reader_overlay = .links;
        self.reader_choice = 0;
        self.say(false, "Choose a literal URL · Enter opens in this account's profile", .{});
    }
    fn readerAttachmentCount(self: *App) usize {
        var count: usize = 0;
        for (self.thread) |message| count += items(get(message, "attachments")).len;
        return count;
    }
    fn readerAttachment(self: *App, selected: usize) ?struct { message: Value, attachment: Value } {
        var index: usize = 0;
        for (self.thread) |message| for (items(get(message, "attachments"))) |attachment| {
            if (index == selected) return .{ .message = message, .attachment = attachment };
            index += 1;
        };
        return null;
    }
    fn openReaderAttachments(self: *App) void {
        self.closeReaderOverlay();
        self.reader_overlay = .attachments;
        self.say(false, "Received attachments · s Save · o Save & open · Esc Back", .{});
    }
    fn readerAttachmentPrompt(self: *App, open_after: bool) !void {
        const chosen = self.readerAttachment(self.reader_choice) orelse return;
        const size = get(chosen.attachment, "size");
        if (size != .integer or size.integer < 0 or size.integer > types.Limits.body_bytes) return error.InvalidAttachment;
        if (text(get(chosen.message, "id")).len == 0 or text(get(chosen.message, "id")).len > 256 or text(get(chosen.attachment, "id")).len == 0 or text(get(chosen.attachment, "id")).len > 1024) return error.InvalidAttachment;
        try self.reader_attachment_message.set(self.allocator, text(get(chosen.message, "id")));
        try self.reader_attachment_id.set(self.allocator, text(get(chosen.attachment, "id")));
        try self.reader_attachment_name.set(self.allocator, text(get(chosen.attachment, "filename")));
        self.reader_attachment_size = @intCast(size.integer);
        self.reader_overlay = if (open_after) .open_attachment else .save_attachment;
        self.path_candidates.reset();
        const directory = try path_completion.downloadsDirectory(self.io, self.allocator, self.environ);
        defer self.allocator.free(directory);
        const destination = try path_completion.freshDestination(self.io, self.allocator, directory, self.reader_attachment_name.value());
        defer self.allocator.free(destination);
        try self.reader_default_directory.set(self.allocator, directory);
        try self.reader_path.set(self.allocator, destination);
    }
    fn finishReaderAttachment(self: *App) !void {
        if (!self.attachment_open_after) return;
        self.attachment_open_after = false;
        try self.start(.open, .{ .cmd = "attachment.open", .account = self.account(), .path = self.attachment_destination.value() });
        if (self.job.future != null and self.job.kind == .open) self.job.saved_attachment_open = true;
    }
    fn attachmentOpenFailed(self: *App, code: []const u8) void {
        self.action_notice = false;
        self.sayAction(true, "Attachment saved · could not open file: {s}", .{humanError(code)});
        self.diagnostic(code);
    }
    fn preemptReaderAction(self: *App) void {
        const interrupted_save = self.compose_active and self.job.future != null and self.job.kind == .autosave and self.compose.revision != self.compose.saved_revision;
        self.preemptReadOnly();
        if (interrupted_save) self.autosave_due = true;
    }
    fn onReaderOverlayKey(self: *App, key: Key) !bool {
        if (self.reader_overlay == .none) return false;
        if (self.reader_overlay == .save_attachment or self.reader_overlay == .open_attachment) {
            if (self.paste) {
                if (key.text) |raw| try self.reader_path.insert(self.allocator, try safe(self.frame.allocator(), raw, false), 4096) else if (key.matches(Key.enter, .{})) try self.reader_path.insert(self.allocator, " ", 4096);
                return true;
            }
            if (key.matches(Key.escape, .{})) {
                if (self.path_candidates.candidates.len > 1 and self.path_candidates.active(self.reader_path.value())) {
                    self.path_candidates.reset();
                    return true;
                }
                self.path_candidates.reset();
                self.reader_overlay = .attachments;
            } else if (key.matches(Key.tab, .{})) {
                try self.completePath(&self.reader_path, false);
            } else if (key.matches(Key.tab, .{ .shift = true })) {
                try self.completePath(&self.reader_path, true);
            } else if (key.matches('u', .{ .ctrl = true })) {
                try self.reader_path.set(self.allocator, "");
                self.path_candidates.reset();
            } else if (key.matches(Key.enter, .{})) {
                const path = self.reader_path.value();
                if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AttachmentSaveSyntax;
                const open_after = self.reader_overlay == .open_attachment;
                if (std.fs.path.dirname(path)) |parent| if (same(parent, self.reader_default_directory.value())) {
                    var directory = try path_completion.openDirectory(self.io, parent, true);
                    directory.close(self.io);
                };
                self.preemptReaderAction();
                if (self.job.future != null) return error.OperationPending;
                try self.attachment_destination.set(self.allocator, path);
                self.attachment_expected_size = self.reader_attachment_size;
                try self.start(.attachment_save, .{ .cmd = "mail.attachment", .account = self.account(), .messageId = self.reader_attachment_message.value(), .attachmentId = self.reader_attachment_id.value() });
                self.attachment_open_after = open_after;
                self.closeReaderOverlay();
            } else {
                self.path_candidates.reset();
                try self.reader_path.handleKey(self.allocator, key, false, 4096);
            }
            return true;
        }
        if (key.matches(Key.escape, .{}) or key.matches('q', .{})) {
            self.closeReaderOverlay();
            return true;
        }
        const count = if (self.reader_overlay == .links) self.reader_links.count else self.readerAttachmentCount();
        if (key.matches(Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
            self.reader_choice = @min(self.reader_choice +| 10, count -| 1);
            return true;
        }
        if (key.matches(Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
            self.reader_choice -|= 10;
            return true;
        }
        if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.reader_choice = @min(self.reader_choice +| 1, count -| 1) else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.reader_choice -|= 1 else if (key.matches(Key.home, .{})) self.reader_choice = 0 else if (key.matches(Key.end, .{})) self.reader_choice = count -| 1 else if (self.reader_overlay == .links and key.matches(Key.enter, .{}) and count > 0) {
            const url = self.reader_links.values[self.reader_choice];
            if (!reader_tools.safeUrl(url)) return error.InvalidBrowserUrl;
            self.preemptReaderAction();
            if (self.job.future != null) return error.OperationPending;
            try self.start(.open, .{ .cmd = "browser.open", .account = self.account(), .url = url });
            self.closeReaderOverlay();
        } else if (self.reader_overlay == .attachments and (key.matches('s', .{}) or key.matches(Key.enter, .{}))) try self.readerAttachmentPrompt(false) else if (self.reader_overlay == .attachments and key.matches('o', .{})) try self.readerAttachmentPrompt(true);
        return true;
    }
    fn onReaderKey(self: *App, key: Key) !bool {
        if (self.mode != .browse) return false;
        if (key.matches('L', .{}) or key.matches('l', .{ .shift = true })) {
            try self.openReaderLinks();
            return true;
        }
        if (key.matches('B', .{}) or key.matches('b', .{ .shift = true })) {
            self.openReaderAttachments();
            return true;
        }
        if (self.focus != .reader and !self.expanded) return false;
        if (key.matches('Q', .{}) or key.matches('q', .{ .shift = true })) {
            self.fold_quotes = !self.fold_quotes;
            self.reader_anchor_card = true;
            self.reader_card_pinned = true;
            return true;
        }
        if (key.matches('S', .{}) or key.matches('s', .{ .shift = true })) {
            self.fold_signatures = !self.fold_signatures;
            self.reader_anchor_card = true;
            self.reader_card_pinned = true;
            return true;
        }
        if (self.thread.len == 0) return false;
        if (key.matches('t', .{}) and self.thread.len > 1) {
            self.reader_cards[self.reader_card] = !self.reader_cards[self.reader_card];
            self.reader_anchor_card = true;
            self.reader_card_pinned = true;
            return true;
        }
        if (key.matches('}', .{}) or key.matches('{', .{})) {
            self.reader_card = if (key.matches('}', .{})) @min(self.reader_card +| 1, self.thread.len - 1) else self.reader_card -| 1;
            self.reader_anchor_card = true;
            self.reader_card_pinned = true;
            return true;
        }
        return false;
    }
    fn readerReplyId(self: *App) []const u8 {
        if ((self.focus == .reader or self.expanded) and self.reader_card < self.thread.len) return text(get(self.thread[self.reader_card], "id"));
        return self.messageId();
    }
    fn onReaderHit(self: *App, hit: layout.Hit) !bool {
        switch (hit.kind) {
            .reader_thread => {
                if (hit.index >= self.thread.len) return true;
                self.reader_card = hit.index;
                self.reader_cards[hit.index] = !self.reader_cards[hit.index];
                self.focus = .reader;
                self.reader_anchor_card = true;
                self.reader_card_pinned = true;
            },
            .reader_attachment => {
                self.openReaderAttachments();
                self.reader_choice = hit.index;
            },
            .reader_link => {
                try self.openReaderLinks();
            },
            .reader_picker => {
                const count = if (self.reader_overlay == .links) self.reader_links.count else self.readerAttachmentCount();
                self.reader_choice = @min(hit.index, count -| 1);
            },
            .reader_picker_save => try self.readerAttachmentPrompt(false),
            .reader_picker_open => try self.readerAttachmentPrompt(true),
            else => return false,
        }
        return true;
    }
    fn drawReaderOverlay(self: *App, win: vaxis.Window) !void {
        if (self.reader_overlay == .none) return;
        const width = @min(win.width -| 2, 100);
        const height = @min(win.height -| 2, 25);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, if (self.reader_overlay == .links) " Links · explicit browser open " else " Received attachments ", true);
        if (inner.height < 4) return;
        if (self.reader_overlay == .save_attachment or self.reader_overlay == .open_attachment) {
            try self.line(inner, 0, self.reader_attachment_name.value(), .subject);
            try self.line(inner, 2, if (self.reader_overlay == .open_attachment) "Save to a new absolute path, then open it:" else "Save to a new absolute path:", .accent);
            try self.editLine(inner, 3, "Path", &self.reader_path, true, .selected);
            try self.line(inner, inner.height - 1, "Tab Complete · Ctrl+U Clear · Enter Save · Esc Back", .muted);
            try self.drawPathCandidates(inner, &self.reader_path, 5, inner.height -| 6);
            return;
        }
        const count = if (self.reader_overlay == .links) self.reader_links.count else self.readerAttachmentCount();
        const visible = inner.height - 3;
        const top = self.reader_choice -| (visible - 1);
        if (count == 0) try self.line(inner, 1, if (self.reader_overlay == .links) "No safe HTTP(S) URLs found" else "No received attachments in this view", .muted);
        var index = top;
        while (index < count and index - top < visible) : (index += 1) {
            const label = if (self.reader_overlay == .links) self.reader_links.values[index] else blk: {
                const attachment = self.readerAttachment(index).?.attachment;
                break :blk try std.fmt.allocPrint(self.frame.allocator(), "{d}. {s} · {d} bytes", .{ index + 1, text(get(attachment, "filename")), if (get(attachment, "size") == .integer) get(attachment, "size").integer else 0 });
            };
            try self.line(inner, index - top, try self.fitLine(inner, label, inner.width), if (index == self.reader_choice) .selected else .text);
            self.mouseRows(inner, index - top, 1, .reader_picker, index);
        }
        if (self.reader_overlay == .links) {
            try self.line(inner, inner.height - 2, "Enter Open in account profile · j/k · Esc/q Back", .accent);
            if (self.reader_links.truncated) try self.line(inner, inner.height - 1, "First 128 safe destinations · chooser limit reached", .warning);
        } else {
            const save_width = @min(@as(u16, 16), inner.width);
            const save = inner.child(.{ .y_off = inner.height - 2, .width = save_width, .height = 1 });
            try self.line(save, 0, "[s Save]", .accent);
            self.mouseArea(save, .reader_picker_save, 0);
            if (inner.width > save_width) {
                const open = inner.child(.{ .x_off = save_width, .y_off = inner.height - 2, .height = 1 });
                try self.line(open, 0, "[o Save & open]", .accent);
                self.mouseArea(open, .reader_picker_open, 0);
            }
            try self.line(inner, inner.height - 1, "j/k Choose · Enter Save · Esc/q Back", .muted);
        }
    }
    fn syncFailed(self: *App, index: usize, code: []const u8) void {
        if (index >= self.sync.len) return;
        const status = &self.sync[index];
        status.state = if (status.cache_ready) .offline else .failed;
        status.error_len = @min(code.len, status.error_code.len);
        @memcpy(status.error_code[0..status.error_len], code[0..status.error_len]);
    }
    fn syncMetadata(self: *App, index: usize, result: Value) void {
        if (index >= self.sync.len) return;
        const status = &self.sync[index];
        if (get(result, "cacheReady") == .bool) status.cache_ready = truth(get(result, "cacheReady"));
        const checked = get(result, "lastSyncAt");
        if (checked == .integer and checked.integer >= 0 and checked.integer <= 253402300799999) status.last_sync_at = checked.integer;
    }
    fn syncLine(self: *App) ![]const u8 {
        if (self.contactsOpen()) {
            const label = switch (self.contacts_state) {
                .loading => "Loading contacts…",
                .cached => if (self.pending_contacts or (self.job.future != null and self.job.kind == .contacts)) "Refreshing cached contacts" else "Cached contacts",
                .current => "Contacts available",
                .denied => "Contacts permission required · contacts-read",
                .failed => "Contacts unavailable · cached entries retained",
                .busy => "Contacts cache is busy",
            };
            return std.fmt.allocPrint(self.frame.allocator(), " {s}{s}", .{ label, if (self.contacts.len > 0) try std.fmt.allocPrint(self.frame.allocator(), " · {d} available", .{self.contacts.len}) else "" });
        }
        if (self.statusContext().mode == .compose or self.statusContext().mode == .review) {
            if (self.compose.unknown_outcome) return " Outcome unknown · recovery draft protected";
            if (self.job.future != null and self.job.kind == .send) return " Submitting · waiting for the provider receipt";
            if (self.job.future != null and (self.job.kind == .autosave or self.job.kind == .save or self.job.kind == .save_review or self.job.kind == .save_back)) return " Saving draft locally · no mail sent";
            if (self.compose.revision != self.compose.saved_revision) return " Draft changes pending · no mail sent";
            return " Local draft · no mail sent";
        }
        const status = &self.sync[self.account_index];
        const elsewhere = self.job.future != null and self.job.kind == .refresh and self.job.account_index == self.account_index and self.job.waiting_external.load(.acquire);
        const label = if (self.job.future != null and self.job.kind == .cached_search and self.job.account_index == self.account_index) "Searching cached mail…" else if (elsewhere) (if (status.cache_ready) "Updating elsewhere · cached mail ready" else "Updating elsewhere · waiting for cached mail") else switch (status.state) {
            .fetching => "Fetching mail",
            .refreshing => "Refreshing cached mail",
            .cached => "Cached mail",
            .current => "Up to date",
            .offline => "Offline cached mail",
            .failed => "Mail unavailable",
        };
        const progress = self.job.progress.snapshot();
        const progress_label = if (self.job.future != null and self.job.account_index == self.account_index and progress.total > 0)
            try std.fmt.allocPrint(self.frame.allocator(), "{s} · {s} {d}/{d}", .{ label, if (progress.phase == .metadata) @as([]const u8, "metadata") else "bodies", progress.completed, progress.total })
        else
            label;
        const checked = if (status.last_sync_at > 0) try std.fmt.allocPrint(self.frame.allocator(), "Synced {s}", .{try timestamp(self.frame.allocator(), &self.zone, .{ .integer = status.last_sync_at })}) else if (self.zone.unavailable) "UTC fallback · local timezone unavailable" else if (status.cache_ready) "Sync time unknown" else "No cached mail";
        return std.fmt.allocPrint(self.frame.allocator(), " {s} · {s}{s}{s}{s}{s}{s}", .{ progress_label, checked, if (status.error_len > 0) " · " else "", if (status.error_len > 0) humanError(status.error_code[0..status.error_len]) else "", if (self.cache_busy or self.reader_cache_busy) " · cache read busy" else "", if (self.preferences_warning) " · UI prefs fallback" else "", if (self.theme_warning) " · theme fallback" else "" });
    }
    fn syncTone(self: *const App) Tone {
        if (self.contactsOpen()) return switch (self.contacts_state) {
            .loading => .fetching,
            .current => .current,
            .denied, .failed => .warning,
            else => .muted,
        };
        if (self.statusContext().mode == .compose or self.statusContext().mode == .review) {
            if (self.compose.unknown_outcome) return .warning;
            if (self.job.future != null and (self.job.kind == .send or self.job.kind == .autosave or self.job.kind == .save or self.job.kind == .save_review or self.job.kind == .save_back)) return .fetching;
            return .muted;
        }
        if (self.job.future != null and self.job.account_index == self.account_index and self.job.progress.snapshot().total > 0) return .fetching;
        if (self.job.future != null and self.job.kind == .cached_search and self.job.account_index == self.account_index) return .fetching;
        if (self.job.future != null and self.job.kind == .refresh and self.job.account_index == self.account_index and self.job.waiting_external.load(.acquire)) return .fetching;
        return switch (self.sync[self.account_index].state) {
            .fetching, .refreshing => .fetching,
            .current => .current,
            .offline => .offline,
            .failed => .warning,
            .cached => .muted,
        };
    }
    fn globalHeader(self: *App) ![]const u8 {
        const context = switch (self.mode) {
            .compose => "Compose",
            .review => "Review send",
            .attachment => "Compose · Attach file",
            .contacts => if (self.picker) "Choose recipient" else "Contacts",
            .contact_edit => "Edit contact",
            .help => "Help",
            .trash_confirm => "Review Trash",
            .invitation => "Review RSVP",
            .labels => "Choose label",
            .command => if (self.previous_mode == .compose) "Compose · Command" else "Mail · Command",
            .search => if (self.previous_mode == .contacts) "Contacts · Search" else if (self.input_query_scope == .cache) "Cache search" else "Gmail search",
            .browse => try std.fmt.allocPrint(self.frame.allocator(), "{s}{s} · {s}", .{ self.mailboxTitle(), if (self.cacheSearch()) " / Cache search" else if (self.query.value().len > 0) " / Gmail search" else "", if (self.expanded) @as([]const u8, "Reader expanded") else if (self.reader_layout == .right) "Reader right" else "Reader below" }),
        };
        const selected = if (self.mode == .browse and self.mail_selection.count > 0) try std.fmt.allocPrint(self.frame.allocator(), " · {d} selected", .{self.mail_selection.count}) else "";
        return std.fmt.allocPrint(self.frame.allocator(), " omagma · Experimental | {s} | {s}{s}{s}", .{ context, self.account(), selected, if (self.options.fixtures) " · Mock provider" else "" });
    }
    fn fittedGlobalHeader(self: *App, win: vaxis.Window) ![]const u8 {
        const full = try self.globalHeader();
        if (positionAfter(win, full).row == 0) return full;
        const context = switch (self.mode) {
            .browse => try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ self.mailboxTitle(), if (self.expanded) " · Expanded" else if (self.cacheSearch()) " · Cache search" else if (self.query.value().len > 0) " · Gmail search" else "" }),
            .compose => "Compose",
            .review => "Review send",
            .attachment => "Attach file",
            .contacts => if (self.picker) "Choose recipient" else "Contacts",
            .contact_edit => "Edit contact",
            .help => "Help",
            .trash_confirm => "Review Trash",
            .invitation => "Review RSVP",
            .labels => "Label",
            .command => "Command",
            .search => if (self.previous_mode == .contacts) "Contacts search" else if (self.input_query_scope == .cache) "Cache search" else "Gmail search",
        };
        const selected = if (self.mode == .browse and self.mail_selection.count > 0) try std.fmt.allocPrint(self.frame.allocator(), " · {d} selected", .{self.mail_selection.count}) else "";
        const mock = if (self.options.fixtures) @as([]const u8, " · Mock") else "";
        const compact = try std.fmt.allocPrint(self.frame.allocator(), " omagma | {s} | {s}{s}{s}", .{ context, self.account(), selected, mock });
        if (positionAfter(win, compact).row == 0) return compact;
        const no_brand = try std.fmt.allocPrint(self.frame.allocator(), " {s} | {s}{s}{s}", .{ self.account(), context, selected, mock });
        if (positionAfter(win, no_brand).row == 0) return no_brand;
        // Account and fixture/selection identity survive before decoration.
        // Both text pieces fit in character columns, never pixel offsets.
        const suffix = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ selected, mock });
        const suffix_width: u16 = @intCast(@min(suffix.len, win.width));
        const available = win.width -| suffix_width -| 4;
        const account_width = @min(available, @max(@as(u16, 12), available * 2 / 3));
        const context_width = available -| account_width;
        return std.fmt.allocPrint(self.frame.allocator(), " {s} | {s}{s}", .{ try self.fitLine(win, self.account(), account_width), try self.fitLine(win, context, context_width), suffix });
    }
    fn listTitle(self: *App) ![]const u8 {
        if (self.messages.len == 0) return if (self.loadingActive()) " Mail · Loading " else " Mail · Empty ";
        const before = self.has_more_cached_before orelse (self.previous_cursor.value().len > 0 or self.previous_cursors.items.len > 0);
        const after = (self.has_more_cached_after orelse false) or self.next_cursor.value().len > 0 or self.remote_cursor.value().len > 0;
        return std.fmt.allocPrint(self.frame.allocator(), " Mail · {d}/{d} {s}{s} ", .{ @min(self.selected + 1, self.messages.len), self.messages.len, if (before) @as([]const u8, "↑") else "", if (after) @as([]const u8, "↓") else "" });
    }
    fn clearReader(self: *App) void {
        self.closeReaderOverlay();
        self.reader_card = 0;
        self.reader_anchor_card = false;
        self.reader_card_pinned = false;
        self.reader_cards = @splat(true);
        self.clearMarkup();
        self.thread = &.{};
        _ = self.read_arena.reset(.retain_capacity);
        self.reader_scroll = 0;
        self.reader_lines = 0;
        self.reader_height = 0;
        self.reader_partial = false;
        self.reader_is_thread = false;
        self.body_cache_miss = false;
        self.reader_cache_busy = false;
        self.pending_cached_read = false;
        self.pending_cached_thread = false;
        self.reader_account.bytes.clearRetainingCapacity();
        self.reader_message.bytes.clearRetainingCapacity();
        self.reader_account.cursor = 0;
        self.reader_message.cursor = 0;
    }
    fn clearMarkup(self: *App) void {
        deinitMarkup(self.markup);
        self.markup = &.{};
    }
    fn deinitMarkup(markup: []ReaderMarkup) void {
        for (markup) |*view| if (view.prepared) |*prepared| prepared.deinit();
    }
    fn htmlEligible(self: *App, message: Value) bool {
        const source = text(get(message, "bodySource"));
        const html = text(get(message, "bodyHtml"));
        if (html.len == 0 or same(source, "plain")) return false;
        if (same(source, "html")) return true;
        if (source.len != 0 and !same(source, "unknown")) return false;
        // Old cached records carry no provenance. Rich markup is enabled
        // only when the unchanged legacy conversion exactly explains their
        // displayed text; uncertainty preserves the plain part.
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const converted = mime.htmlToText(html, allocator) catch return false;
        const safe_html = mime.sanitizeText(converted, allocator) catch return false;
        return same(safe_html, text(get(message, "bodyText")));
    }
    fn prepareMarkup(self: *App, allocator: Allocator, messages: []const Value) ![]ReaderMarkup {
        _ = self;
        const views = try allocator.alloc(ReaderMarkup, messages.len);
        for (views) |*view| view.* = .{};
        return views;
    }
    fn prepareVisibleMarkup(self: *App, view: *ReaderMarkup, message: Value) void {
        if (view.attempted) return;
        view.attempted = true;
        if (!self.htmlEligible(message)) return;
        self.html_stats.htmlDocumentBuilds += 1;
        view.prepared = html_view.Prepared.init(self.allocator, text(get(message, "bodyHtml"))) catch {
            self.html_stats.htmlFallbacks += 1;
            view.fallback = true;
            return;
        };
    }
    fn resumeMailboxReader(self: *App) !void {
        if (self.drafts_list or self.thread.len == 0) return;
        if (same(self.reader_account.value(), self.account()) and same(self.reader_message.value(), self.messageId())) return;
        // A composer may deliberately retain its original context across a
        // cache merge. Once it closes, the mailbox reader must match its row.
        self.clearReader();
        if (self.messages.len > 0) try self.preview(false);
    }
    fn clearHistory(self: *App) void {
        for (self.previous_cursors.items) |value_in| self.allocator.free(value_in);
        self.previous_cursors.clearRetainingCapacity();
    }
    fn selectedMessage(self: *App) ?Value {
        return if (self.selected < self.messages.len) self.messages[self.selected] else null;
    }
    fn messageId(self: *App) []const u8 {
        return if (self.selectedMessage()) |message| text(get(message, "id")) else "";
    }
    fn cacheSearch(self: *const App) bool {
        return self.query.value().len > 0 and self.query_scope == .cache;
    }
    fn beginSearch(self: *App, scope: QueryScope) !void {
        if (self.query.value().len == 0) {
            try self.search_saved_account.set(self.allocator, self.account());
            try self.search_saved_label.set(self.allocator, self.custom_label.value());
            try self.search_saved_message.set(self.allocator, self.messageId());
            self.search_saved_folder = self.folder;
            self.search_saved_selected = self.selected;
            self.search_saved_top = self.top;
            self.search_saved_scroll = self.reader_scroll;
            self.search_saved_focus = self.focus;
            self.search_saved_expanded = self.expanded;
            self.search_saved_thread = self.reader_is_thread;
            self.search_saved_valid = true;
        }
        self.previous_mode = .browse;
        self.mode = .search;
        self.input_query_scope = scope;
        try self.input.set(self.allocator, self.query.value());
    }
    fn data(self: *App, allocator: Allocator, response: []const u8) !Value {
        if (response.len > response_limit) return error.ResponseTooLarge;
        const parsed = try std.json.parseFromSliceLeaky(Value, allocator, response, .{ .allocate = .alloc_always, .max_value_len = response_limit });
        if (get(parsed, "ok") == .bool and !truth(get(parsed, "ok"))) {
            const code = text(get(get(parsed, "error"), "code"));
            self.sayError(if (code.len == 0) "OperationRejected" else code);
            return error.OperationRejected;
        }
        return if (get(parsed, "data") != .null) get(parsed, "data") else parsed;
    }
    fn cached(self: *App, allocator: Allocator, request_value: anytype) !?[]const u8 {
        const request = try std.json.Stringify.valueAlloc(allocator, request_value, .{});
        for (0..11) |attempt| {
            const response = self.client.callCached(allocator, request) catch |err| switch (err) {
                error.CacheMiss => {
                    self.cache_busy = false;
                    return null;
                },
                error.CacheBusy => {
                    try self.cacheBackoff(attempt);
                    continue;
                },
                else => return err,
            };
            if (response.len > response_limit) {
                allocator.free(response);
                return error.ResponseTooLarge;
            }
            var scratch: std.heap.ArenaAllocator = .init(self.allocator);
            defer scratch.deinit();
            const envelope = std.json.parseFromSliceLeaky(Value, scratch.allocator(), response, .{ .allocate = .alloc_always }) catch |err| {
                allocator.free(response);
                return err;
            };
            if (get(envelope, "ok") == .bool and !truth(get(envelope, "ok"))) {
                const code = text(get(get(envelope, "error"), "code"));
                if (same(code, "CacheBusy")) {
                    allocator.free(response);
                    try self.cacheBackoff(attempt);
                    continue;
                }
                if (same(code, "CacheMiss")) {
                    allocator.free(response);
                    self.cache_busy = false;
                    return null;
                }
                if (same(code, "PermissionDenied")) {
                    allocator.free(response);
                    self.cache_busy = false;
                    return error.PermissionDenied;
                }
                self.sayFailure("Cache unavailable", code);
                allocator.free(response);
                return error.OperationRejected;
            }
            self.cache_busy = false;
            return response;
        }
        unreachable;
    }
    fn cacheBackoff(self: *App, attempt: usize) !void {
        if (attempt == 10) {
            self.cache_busy = true;
            self.say(false, "Cache busy · local read queued", .{});
            return error.CacheBusy;
        }
        // Ten finite, cancellation-aware waits: at most20ms of backoff.
        // This is per-operation contention handling, never an idle timer.
        try self.io.sleep(.fromMilliseconds(2), .awake);
    }
    fn replaceList(self: *App, kind: JobKind, response: []const u8) !void {
        var replacement: std.heap.ArenaAllocator = .init(self.allocator);
        defer replacement.deinit();
        const result = try self.data(replacement.allocator(), response);
        const messages = items(get(result, if (kind == .drafts) "drafts" else "messages"));
        if (messages.len > types.Limits.page) return error.PageTooLarge;
        if (messages.len == 0 and self.pageLoadCurrent()) {
            const forward = self.page_loading_forward;
            const remote = text(get(result, "remoteCursor"));
            if (forward and self.page_relative and !self.cacheSearch() and remote.len > 0) {
                if (self.job.future != null) {
                    const automatic = self.page_select_nearest;
                    self.rollbackPageLoad();
                    try self.queuePage(true, automatic);
                    return;
                }
                self.page_relative = false;
                try self.cursor.set(self.allocator, remote);
                self.pending_window_provider = true; // Dispatch after local response arenas unwind.
                return;
            }
            self.rollbackPageLoad();
            if (forward) {
                try self.next_cursor.set(self.allocator, "");
                try self.remote_cursor.set(self.allocator, "");
            } else self.has_more_cached_before = false;
            self.say(false, "{s} of {s}", .{ if (forward) "End" else "Start", if (self.cacheSearch()) "cached matches" else "cached mailbox" });
            return;
        }
        const same_view = self.view_ready and self.view_generation == self.generation;
        const next_page = self.page_loading and self.page_loading_account == self.account_index and self.page_loading_generation == self.generation;
        const retained_search = kind == .cached_search and self.view_ready;
        const saved = if (next_page) "" else if (same_view or retained_search) self.messageId() else self.restore_message.value();
        var selected = if (next_page) @as(usize, 0) else @min(self.selected, messages.len -| 1);
        if (next_page and self.page_loading_forward) for (messages, 0..) |message, index| {
            var repeated = false;
            for (self.messages) |previous_message| repeated = repeated or same(text(get(previous_message, "id")), text(get(message, "id")));
            if (!repeated) {
                selected = index;
                break;
            }
        };
        if (next_page and !self.page_loading_forward and self.page_select_nearest) {
            selected = messages.len -| 1;
            var index = messages.len;
            while (index > 0) {
                index -= 1;
                var repeated = false;
                for (self.messages) |previous_message| repeated = repeated or same(text(get(previous_message, "id")), text(get(messages[index], "id")));
                if (!repeated) {
                    selected = index;
                    break;
                }
            }
        }
        for (messages, 0..) |message, index| if (saved.len > 0 and same(text(get(message, "id")), saved)) {
            selected = index;
            break;
        };
        const selected_id = if (selected < messages.len) text(get(messages[selected], "id")) else "";
        const retain_reader = self.compose_active or ((same_view or retained_search) and same(self.reader_account.value(), self.account()) and same(self.reader_message.value(), selected_id));
        var next: Field = .{};
        defer next.deinit(self.allocator);
        const server_snapshot = self.query.value().len > 0 and self.query_scope == .server and truth(get(result, "cached"));
        try next.set(self.allocator, text(get(result, if (server_snapshot) "remoteCursor" else "nextCursor")));
        var remote: Field = .{};
        defer remote.deinit(self.allocator);
        try remote.set(self.allocator, text(get(result, "remoteCursor")));
        var preceding: Field = .{};
        defer preceding.deinit(self.allocator);
        try preceding.set(self.allocator, if (server_snapshot) "" else text(get(result, "previousCursor")));
        if (!server_snapshot and (truth(get(result, "cached")) or get(result, "cursor") == .string)) try self.cursor.set(self.allocator, text(get(result, "cursor")));
        const previous = self.list_arena;
        self.list_arena = replacement;
        replacement = previous;
        self.messages = messages;
        try self.search_highlight.set(self.allocator, if (self.cacheSearch()) text(get(result, "highlightTerm")) else "");
        self.search_matches = items(get(result, "searchMatches"));
        try self.ensureMailSelection();
        self.list_cached = truth(get(result, "cached"));
        self.list_partial = truth(get(result, "partial"));
        self.cache_view_missing = truth(get(result, "viewIncomplete"));
        self.has_more_cached_before = if (get(result, "hasMoreCachedBefore") == .bool) truth(get(result, "hasMoreCachedBefore")) else null;
        self.has_more_cached_after = if (get(result, "hasMoreCachedAfter") == .bool) truth(get(result, "hasMoreCachedAfter")) else null;
        self.selected = selected;
        if (self.search_restore_pending) self.top = @min(self.search_saved_top, selected);
        if (next_page) {
            self.top = 0; // listDraw positions the selected edge in its viewport.
            self.completePageLoad();
        }
        self.view_ready = true;
        self.view_generation = self.generation;
        std.mem.swap(Field, &self.next_cursor, &next);
        std.mem.swap(Field, &self.previous_cursor, &preceding);
        std.mem.swap(Field, &self.remote_cursor, &remote);
        if (!retain_reader) self.clearReader();
        if (kind != .drafts) self.syncMetadata(self.account_index, result);
        if (!self.compose_active) self.say(false, "{s}", .{if (messages.len == 0 and self.list_cached and self.list_partial) "No rows in cached subset · Ready" else if (messages.len == 0) "No messages match this mailbox" else "Ready"});
    }
    fn replaceReader(self: *App, full_thread: bool, response: []const u8, cached_view: bool) !void {
        var replacement: std.heap.ArenaAllocator = .init(self.allocator);
        defer replacement.deinit();
        const result = try self.data(replacement.allocator(), response);
        const messages = if (full_thread) items(get(result, "messages")) else blk: {
            const one = try replacement.allocator().alloc(Value, 1);
            one[0] = result;
            break :blk one;
        };
        if (messages.len > types.Limits.page) return error.ThreadTooLarge;
        const markup = try self.prepareMarkup(replacement.allocator(), messages);
        errdefer deinitMarkup(markup);
        const same_reader = same(self.reader_account.value(), self.account()) and same(self.reader_message.value(), self.messageId()) and self.reader_is_thread == full_thread;
        var cards: [types.Limits.page]bool = @splat(!full_thread);
        var default_focus: usize = 0;
        var preserved_focus: ?usize = null;
        for (messages, 0..) |message, index| {
            const id = text(get(message, "id"));
            if (same(id, self.messageId())) default_focus = index;
            if (same_reader) for (self.thread, 0..) |previous_message, previous_index| {
                if (!same(id, text(get(previous_message, "id")))) continue;
                cards[index] = self.reader_cards[previous_index];
                if (previous_index == self.reader_card) preserved_focus = index;
                break;
            };
        }
        // A cached/full replacement can finish after the user chose another
        // thread card. Preserve that card by identity even when the mailbox's
        // originally selected message occurs later in the replacement.
        const focused = preserved_focus orelse default_focus;
        if (!same_reader and messages.len > 0) cards[focused] = true;
        try self.reader_account.set(self.allocator, self.account());
        try self.reader_message.set(self.allocator, self.messageId());
        self.clearMarkup();
        const previous = self.read_arena;
        self.read_arena = replacement;
        replacement = previous;
        self.thread = messages;
        self.markup = markup;
        self.reader_cards = cards;
        self.reader_card = focused;
        self.reader_partial = full_thread and cached_view and truth(get(result, "partial"));
        self.reader_is_thread = full_thread;
        self.body_cache_miss = false;
        self.reader_cache_busy = false;
        self.pending_cached_read = false;
        self.pending_cached_thread = false;
        if (!same_reader) {
            self.closeReaderOverlay();
            self.reader_scroll = 0;
            self.reader_anchor_card = full_thread and messages.len > 1;
            self.reader_card_pinned = self.reader_anchor_card;
        }
        if (self.restore_reader_scroll) |saved_scroll| {
            if (same(self.restore_message.value(), self.messageId())) self.reader_scroll = saved_scroll;
            self.reader_anchor_card = false;
            self.restore_reader_scroll = null;
            try self.restore_message.set(self.allocator, "");
            self.restore_reader_thread = false;
            self.search_restore_pending = false;
        }
        if (!self.compose_active) self.say(false, "Ready", .{});
    }
    fn cachedPreview(self: *App, full_thread: bool) !bool {
        const selected_value = self.selectedMessage() orelse return false;
        if (self.drafts_list) return false;
        const same_target = self.thread.len > 0 and same(self.reader_account.value(), self.account()) and same(self.reader_message.value(), self.messageId());
        if (same_target and (!full_thread or (self.reader_is_thread and !self.reader_partial))) return true;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const response = (if (full_thread) self.cached(arena.allocator(), .{ .account = self.account(), .cmd = "mail.thread", .threadId = text(get(selected_value, "threadId")) }) else self.cached(arena.allocator(), .{ .account = self.account(), .cmd = "mail.read", .messageId = text(get(selected_value, "id")) })) catch |err| {
            if (err == error.CacheBusy) {
                if (!same_target and !self.compose_active) self.clearReader();
                self.reader_cache_busy = true;
                self.pending_cached_read = true;
                self.pending_cached_thread = full_thread;
            }
            return err;
        };
        if (response) |bytes| {
            try self.replaceReader(full_thread, bytes, true);
            return true;
        }
        if (same_target) {
            // The full selected message remains useful even when a complete
            // thread is not cached or a short commit owns the store lock.
            self.reader_partial = full_thread;
            self.reader_is_thread = full_thread;
            return true;
        }
        if (!self.compose_active) {
            self.clearReader();
            self.body_cache_miss = true;
        }
        if (bodyRefusal(selected_value) != null) return true;
        return false;
    }
    fn loadCachedList(self: *App, anchor: []const u8) !bool {
        if (!self.synchronous_cache_search and self.cacheSearch() and cache_query.needsBody(self.query.value())) {
            try self.startCachedSearch(anchor);
            return self.view_ready or self.sync[self.account_index].cache_ready;
        }
        if (self.view_ready and self.view_generation != self.generation and !self.page_loading) {
            self.messages = &.{};
            self.view_ready = false;
            if (!self.compose_active) self.clearReader();
        }
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const response = self.cached(arena.allocator(), .{
            .account = self.account(),
            .cmd = if (self.cacheSearch()) "mail.search" else "mail.list",
            .cacheOnly = true,
            .limit = @as(usize, 32),
            .cursor = if (anchor.len > 0 or self.page_relative) "" else self.cursor.value(),
            .anchorMessageId = if (anchor.len > 0) anchor else self.restore_message.value(),
            .beforeMessageId = if (self.page_relative and !self.page_loading_forward) self.page_relative_boundary.value() else "",
            .afterMessageId = if (self.page_relative and self.page_loading_forward) self.page_relative_boundary.value() else "",
            .boundaryReceivedAt = if (self.page_relative) self.page_relative_received_at else 0,
            .query = if (self.folder == 3 and self.query.value().len == 0) "-in:inbox -in:trash" else self.query.value(),
            .label = self.activeLabel(),
        }) catch |err| {
            if (err == error.CacheBusy) self.pending_cached_list = true;
            return err;
        };
        if (response) |bytes| {
            self.pending_cached_list = false;
            try self.replaceList(.list, bytes);
            if (!self.compose_active and self.thread.len == 0 and self.messages.len > 0) {
                self.pending_read = false;
                const restoring_thread = self.search_restore_pending and self.restore_reader_thread;
                const hit = self.cachedPreview(restoring_thread) catch |err| {
                    if (err == error.CacheBusy) return self.sync[self.account_index].cache_ready;
                    return err;
                };
                self.pending_read = !hit and !self.cacheSearch();
                if (self.pending_read and restoring_thread) self.pending_thread = true;
            }
            return self.sync[self.account_index].cache_ready;
        }
        return false;
    }
    fn startCachedSearch(self: *App, anchor: []const u8) !void {
        try cache_query.validate(self.query.value());
        if (self.job.future != null and self.job.kind == .cached_search and self.job.generation == self.generation and self.job.account_index == self.account_index) return;
        self.preemptReadOnly();
        if (self.job.future != null) {
            self.pending_cached_list = true;
            self.say(false, "Cached search queued · retained mail remains usable", .{});
            return;
        }
        self.pending_cached_list = false;
        try self.start(.cached_search, .{
            .account = self.account(),
            .cmd = "mail.search",
            .cacheOnly = true,
            .limit = @as(usize, 32),
            .cursor = if (anchor.len > 0 or self.page_relative) "" else self.cursor.value(),
            .anchorMessageId = anchor,
            .beforeMessageId = if (self.page_relative and !self.page_loading_forward) self.page_relative_boundary.value() else "",
            .afterMessageId = if (self.page_relative and self.page_loading_forward) self.page_relative_boundary.value() else "",
            .boundaryReceivedAt = if (self.page_relative) self.page_relative_received_at else 0,
            .query = self.query.value(),
            .label = self.activeLabel(),
        });
    }
    fn boot(self: *App) !void {
        const request = try std.json.Stringify.valueAlloc(self.allocator, .{ .cmd = "accounts.list" }, .{});
        defer self.allocator.free(request);
        const response = try self.client.call(self.account_arena.allocator(), request);
        const result = try self.data(self.account_arena.allocator(), response);
        self.accounts = items(get(result, "accounts"));
        if (self.accounts.len == 0 or self.accounts.len > 3) return error.InvalidAccountList;
        var found = false;
        for (self.accounts, 0..) |account_value, index| {
            const address = text(get(account_value, "address"));
            try recipients.validateAddress(address);
            for (self.accounts[0..index]) |previous| if (same(address, text(get(previous, "address")))) return error.InvalidAccountList;
            if (self.options.account) |preferred| {
                if (same(preferred, address)) {
                    self.account_index = index;
                    found = true;
                }
            } else if (!found and (get(account_value, "enabled") == .null or truth(get(account_value, "enabled")))) {
                self.account_index = index;
                found = true;
            }
        }
        if (self.options.account != null and !found) return error.UnknownAccount;
        self.say(false, "Ready", .{});
    }
    fn start(self: *App, kind: JobKind, request_value: anytype) !void {
        if (self.job.future != null) {
            if (kind == .cached_search) self.pending_cached_list = true else if (kind == .refresh or kind == .list or kind == .drafts) self.pending_list = true else if (kind == .read or kind == .thread) self.pending_read = true else self.say(true, "Please wait for the current operation", .{});
            return;
        }
        _ = self.job_arena.reset(.retain_capacity);
        self.job = .{ .kind = kind, .generation = self.generation, .selection_generation = self.selection_generation, .account_index = self.account_index, .contacts_generation = self.contacts_generation, .requested_at = Io.Timestamp.now(self.io, .real).toMilliseconds() };
        self.job.request = try std.json.Stringify.valueAlloc(self.job_arena.allocator(), request_value, .{});
        if (self.job.request.len > types.Limits.request_bytes) return error.RequestTooLarge;
        if (kind == .refresh or kind == .list) {
            const status = &self.sync[self.account_index];
            status.state = if (status.cache_ready) .refreshing else .fetching;
            status.error_len = 0;
            self.say(false, "{s}", .{if (status.cache_ready) "Cached mail ready · fetching latest changes" else "Fetching mail…"});
        } else self.say(false, "{s}", .{switch (kind) {
            .cached_search => "Searching cached mail…",
            .recipient_cache => "Loading recent-mail recipients… · typing remains available",
            .recipient_refresh => "Updating recent sent-mail recipients… · typing remains available",
            .read => "Fetching body…",
            .thread => "Fetching thread…",
            else => "Working…",
        }});
        self.job.future = try self.io.concurrent(worker, .{self});
    }
    fn reportFetchProgress(ctx: *anyopaque, update: types.FetchProgress) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.job.progress.publish(update)) {
            const posted = self.loop.tryPostEvent(.fetch_progress) catch false;
            if (!posted) self.job.progress.acknowledged();
        }
    }
    fn reportFetchRow(ctx: *anyopaque, update: types.FetchRow) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        // A refresh enumerates global retention first; those rows must never
        // masquerade as the current folder/search. The backend separately
        // publishes the committed, authoritative scoped view.
        if (self.job.kind == .refresh and update.kind == .page) return;
        self.job.loading_rows.publish(update);
        if (!self.job.progress.wake_pending.swap(true, .acq_rel)) {
            const posted = self.loop.tryPostEvent(.fetch_progress) catch false;
            if (!posted) self.job.progress.acknowledged();
        }
    }
    fn fetchSink(self: *App) types.ProgressSink {
        return .{ .ctx = self, .reportFn = reportFetchProgress, .rowFn = reportFetchRow };
    }
    fn loadingActive(self: *const App) bool {
        if (self.mode != .browse or self.job.future == null or self.job.done.load(.acquire) or self.job.account_index != self.account_index or self.job.generation != self.generation) return false;
        return switch (self.job.kind) {
            .refresh, .list, .read, .thread, .cached_search => true,
            else => false,
        };
    }
    fn stopLoadingAnimation(self: *App) void {
        if (self.loading_timer) |*future| future.cancel(self.io);
        self.loading_timer = null;
        self.loading_tick_pending.store(false, .release);
    }
    fn loadingTimer(self: *App) void {
        while (true) {
            // Finite cancellation-aware sleep; no idle polling once loading
            // stops, and no infinite Threaded timeout sleep.
            self.io.sleep(.fromMilliseconds(180), .awake) catch return;
            if (!self.loading_tick_pending.swap(true, .acq_rel)) {
                const posted = self.loop.tryPostEvent(.loading_tick) catch false;
                if (!posted) self.loading_tick_pending.store(false, .release);
            }
        }
    }
    fn ensureLoadingAnimation(self: *App) !void {
        if (@import("builtin").is_test) return;
        if (!self.loadingActive()) return self.stopLoadingAnimation();
        if (self.loading_timer == null) self.loading_timer = try self.io.concurrent(loadingTimer, .{self});
    }
    fn hydrateArrivingMail(self: *App) !void {
        if (!self.loadingActive() or self.job.kind != .refresh or self.job.loading_rows.count() == 0) return;
        if (self.messages.len == 0 or !self.view_ready) {
            _ = self.loadCachedList(self.messageId()) catch |err| {
                if (err == error.CacheBusy) return;
                return err;
            };
        } else if (self.thread.len == 0 and !self.compose_active) {
            _ = self.cachedPreview(false) catch |err| {
                if (err == error.CacheBusy) return;
                return err;
            };
        }
    }
    fn worker(self: *App) void {
        self.job.response = (if (self.job.kind == .cached_search or self.job.kind == .recipient_cache) self.cachedSearchResponse() else if (self.job.kind == .refresh) self.refreshResponse() else self.client.callWithProgress(self.job_arena.allocator(), self.job.request, self.fetchSink())) catch |err| blk: {
            self.job.failure = err;
            break :blk null;
        };
        if (self.job.kind == .attachment_save) {
            if (self.job.response) |response| saveAttachmentResponse(self.io, self.job_arena.allocator(), response, self.attachment_destination.value(), self.attachment_expected_size) catch |err| {
                self.job.failure = err;
            };
        }
        self.job.done.store(true, .release);
        _ = self.loop.tryPostEvent(.operation_done) catch {};
    }
    fn cachedSearchResponse(self: *App) ![]const u8 {
        const allocator = self.job_arena.allocator();
        // This route is exclusively local, including errors. It cannot use
        // the provider client or transform a missing body into a download.
        for (0..11) |attempt| {
            try self.io.checkCancel();
            const response = self.client.callCached(allocator, self.job.request) catch |err| {
                if (err != error.CacheBusy or attempt == 10) return err;
                try self.io.sleep(.fromMilliseconds(2), .awake);
                continue;
            };
            if (response.len > response_limit) return error.ResponseTooLarge;
            var scratch: std.heap.ArenaAllocator = .init(self.allocator);
            defer scratch.deinit();
            const envelope = try std.json.parseFromSliceLeaky(Value, scratch.allocator(), response, .{ .allocate = .alloc_always });
            if (get(envelope, "ok") == .bool and !truth(get(envelope, "ok")) and same(text(get(get(envelope, "error"), "code")), "CacheBusy")) {
                if (attempt == 10) return error.CacheBusy;
                allocator.free(response);
                try self.io.sleep(.fromMilliseconds(2), .awake);
                continue;
            }
            return response;
        }
        unreachable;
    }
    fn workerData(allocator: Allocator, response: []const u8) !Value {
        if (response.len > response_limit) return error.ResponseTooLarge;
        const parsed = try std.json.parseFromSliceLeaky(Value, allocator, response, .{ .allocate = .alloc_always, .max_value_len = response_limit });
        if (get(parsed, "ok") != .bool or !truth(get(parsed, "ok"))) return error.ExternalRefreshStatusUnavailable;
        const result = get(parsed, "data");
        if (result != .object) return error.InvalidProviderResponse;
        return result;
    }
    fn refreshResponse(self: *App) ![]const u8 {
        const allocator = self.job_arena.allocator();
        const response = try self.client.callWithProgress(allocator, self.job.request, self.fetchSink());
        // Preserve ordinary error frames for the main thread's existing
        // sanitized failure handling; only a coalesced lease needs waiting.
        const initial = workerData(allocator, response) catch return response;
        if (!refreshWaiting(initial)) return response;
        self.job.waiting_external.store(true, .release);
        defer self.job.waiting_external.store(false, .release);
        _ = self.loop.tryPostEvent(.operation_done) catch {};
        const request = try std.json.parseFromSliceLeaky(Value, allocator, self.job.request, .{ .allocate = .alloc_always });
        const account_address = text(get(request, "account"));
        const status_request = try std.json.Stringify.valueAlloc(allocator, .{ .cmd = "cache.refresh-status", .account = account_address }, .{});
        const deadline = Io.Timestamp.now(self.io, .awake).toMilliseconds() + 30000;
        while (true) {
            try self.io.checkCancel();
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const status = try self.client.callCached(arena.allocator(), status_request);
            const state = try workerData(arena.allocator(), status);
            if (get(state, "refreshInProgress") != .bool) return error.InvalidProviderResponse;
            if (!truth(get(state, "refreshInProgress"))) break;
            const remaining = deadline - Io.Timestamp.now(self.io, .awake).toMilliseconds();
            if (remaining <= 0) return error.ExternalRefreshWaitTimedOut;
            try self.io.sleep(.fromMilliseconds(@min(remaining, 1000)), .awake);
        }
        const cached_request = try std.json.Stringify.valueAlloc(allocator, .{
            .cmd = "mail.list",
            .account = account_address,
            .limit = @as(usize, 32),
            .query = text(get(request, "query")),
            .label = text(get(request, "label")),
        }, .{});
        const cached_response = try self.client.callCached(allocator, cached_request);
        var envelope = try std.json.parseFromSliceLeaky(Value, allocator, cached_response, .{ .allocate = .alloc_always, .max_value_len = response_limit });
        if (get(envelope, "ok") != .bool or !truth(get(envelope, "ok"))) return cached_response;
        const result = envelope.object.getPtr("data") orelse return error.InvalidProviderResponse;
        if (result.* != .object) return error.InvalidProviderResponse;
        try result.object.put(allocator, "coalesced", .{ .bool = true });
        try result.object.put(allocator, "refreshInProgress", .{ .bool = false });
        try result.object.put(allocator, "refreshed", .{ .bool = false });
        return std.json.Stringify.valueAlloc(allocator, envelope, .{});
    }
    fn cancelJob(self: *App) void {
        self.stopLoadingAnimation();
        if (self.job.future) |*future| future.cancel(self.io);
        self.job.future = null;
        self.pending_list = false;
        self.pending_remote_list = false;
        self.pending_cached_list = false;
        self.pending_cached_read = false;
        self.pending_cached_thread = false;
        self.pending_contacts = false;
        self.pending_cached_contacts = false;
        self.pending_recipient_cache = false;
        self.pending_recipient_refresh = false;
        self.pending_read = false;
        self.pending_thread = false;
        self.pending_page = false;
        self.pending_window_provider = false;
        self.rollbackPageLoad();
        self.pending_compose = .none;
    }
    fn reload(self: *App) !void {
        if (self.job.future != null and self.job.kind == .cached_search and (!self.cacheSearch() or !cache_query.needsBody(self.query.value()))) self.preemptReadOnly();
        self.pending_read = false;
        self.pending_thread = false;
        self.drafts_list = self.folder == 2;
        if (self.drafts_list) return self.start(.drafts, .{ .account = self.account(), .cmd = "draft.list" });
        if (self.cacheSearch()) {
            _ = self.loadCachedList("") catch |err| if (err == error.CacheBusy) false else return err;
            return;
        }
        if (self.query.value().len > 0 and self.query_scope == .server) {
            if (self.cursor.value().len == 0) _ = self.loadCachedList("") catch |err| if (err == error.CacheBusy) false else return err;
            return self.fetchMailboxPage();
        }
        if (self.providerPageCursor(self.cursor.value())) return self.start(.list, .{
            .account = self.account(),
            .cmd = if (self.query.value().len > 0) "mail.search" else "mail.list",
            .limit = @as(usize, 32),
            .cursor = self.cursor.value(),
            .query = if (self.folder == 3 and self.query.value().len == 0) "-in:inbox -in:trash" else self.query.value(),
            .label = self.activeLabel(),
        });
        const anchor = if (self.view_ready and self.view_generation == self.generation) self.messageId() else "";
        _ = self.loadCachedList(anchor) catch |err| blk: {
            self.sayFailure("Cache unavailable", @errorName(err));
            break :blk false;
        };
        try self.refreshMailbox();
    }
    fn refreshMailbox(self: *App) !void {
        const status = &self.sync[self.account_index];
        status.state = if (status.cache_ready) .refreshing else .fetching;
        try self.start(.refresh, .{
            .account = self.account(),
            .cmd = "mail.refresh",
            .limit = @as(usize, 32),
            .query = if (self.folder == 3 and (self.query.value().len == 0 or self.cacheSearch())) "-in:inbox -in:trash" else if (self.cacheSearch()) "" else self.query.value(),
            .label = self.activeLabel(),
        });
    }
    fn fetchMailboxPage(self: *App) !void {
        try self.start(.list, .{
            .account = self.account(),
            .cmd = if (self.query.value().len > 0) "mail.search" else "mail.list",
            .cacheOnly = false,
            .limit = @as(usize, 32),
            .cursor = self.cursor.value(),
            .query = if (self.folder == 3 and self.query.value().len == 0) "-in:inbox -in:trash" else self.query.value(),
            .label = self.activeLabel(),
        });
    }
    fn preview(self: *App, full_thread: bool) !void {
        const selected_value = self.selectedMessage() orelse return;
        if (self.drafts_list) return;
        const cached_hit = self.cachedPreview(full_thread) catch |err| blk: {
            if (err == error.CacheBusy) {
                self.pending_read = false;
                self.pending_thread = false;
                return;
            }
            self.sayFailure("Cache unavailable", @errorName(err));
            break :blk false;
        };
        if (cached_hit and (!full_thread or !self.reader_partial)) {
            self.pending_read = false;
            self.pending_thread = false;
            self.pending_cached_read = false;
            self.pending_cached_thread = false;
            self.reader_cache_busy = false;
            return;
        }
        if (bodyRefusal(selected_value)) |reason| {
            self.pending_read = false;
            self.pending_thread = false;
            self.sayFailure("Selected body unavailable", reason);
            return;
        }
        if (self.cacheSearch() and !full_thread) {
            self.pending_read = false;
            self.pending_thread = false;
            return;
        }
        if (self.job.future != null) self.pending_thread = full_thread;
        if (full_thread) try self.start(.thread, .{ .account = self.account(), .cmd = "mail.thread", .threadId = text(get(selected_value, "threadId")) }) else try self.start(.read, .{ .account = self.account(), .cmd = "mail.read", .messageId = text(get(selected_value, "id")) });
    }
    fn finish(self: *App) !void {
        if (self.job.future == null or !self.job.done.load(.acquire)) return;
        self.job.future.?.await(self.io);
        self.job.future = null;
        defer if (self.job.future == null) {
            // Every retained DTO/string is copied into its owning view/field.
            // Completed response parsing scratch must not coexist with lazy
            // semantic document preparation on the following draw.
            self.job.request = "";
            self.job.response = null;
            _ = self.job_arena.reset(.free_all);
        };
        if (self.job.kind == .refresh) {
            const index = self.job.account_index;
            // A decoding/allocation error below must not leave a perpetual
            // refreshing phase after the owned worker has already stopped.
            self.syncFailed(index, "Refresh incomplete");
            var failure_code: []const u8 = "";
            if (self.job.failure) |err| {
                failure_code = @errorName(err);
            } else if (self.job.response) |response| {
                const envelope = try std.json.parseFromSliceLeaky(Value, self.job_arena.allocator(), response, .{ .allocate = .alloc_always });
                const result: ?Value = if (get(envelope, "ok") == .bool and !truth(get(envelope, "ok"))) blk: {
                    failure_code = text(get(get(envelope, "error"), "code"));
                    if (failure_code.len == 0) failure_code = "RefreshFailed";
                    break :blk null;
                } else get(envelope, "data");
                if (result) |value_in| {
                    self.syncMetadata(index, value_in);
                    self.sync[index].state = if (refreshIsCurrent(value_in, self.job.requested_at)) .current else .cached;
                    self.sync[index].error_len = 0;
                    if (index == self.account_index and !self.drafts_list) {
                        // A committed refresh advances cache cursor generation.
                        // Re-anchor the user's current view, never replay an old
                        // page/query response or use its now-stale cursor.
                        try self.cursor.set(self.allocator, "");
                        self.clearHistory();
                        _ = self.loadCachedList(self.messageId()) catch |err| if (err == error.CacheBusy) false else return err;
                        self.pending_remote_list = self.cache_view_missing;
                    }
                }
            }
            if (failure_code.len > 0) {
                // A failed bounded bootstrap may have committed useful bodies
                // without advancing its checkpoint. Read those short local
                // commits too, while retaining the failed/offline phase.
                if (index == self.account_index and !self.drafts_list) {
                    try self.cursor.set(self.allocator, "");
                    self.clearHistory();
                    _ = self.loadCachedList(self.messageId()) catch false;
                }
                self.syncFailed(index, failure_code);
                if (same(failure_code, "ExternalRefreshWaitTimedOut") or same(failure_code, "ExternalRefreshStatusUnavailable")) self.sync[index].state = .cached;
                if (index == self.account_index and !self.compose_active) self.sayFailure("Refresh failed · cached mail retained", failure_code);
            }
        } else if (((self.job.kind == .identities or self.job.kind == .labels_list or self.job.kind == .cached_search or self.job.kind == .recipient_cache or self.job.kind == .recipient_refresh) and self.job.account_index != self.account_index) or
            (self.job.kind == .contacts and (self.job.contacts_generation != self.contacts_generation or !self.contactsOpen() or self.job.account_index != self.account_index)) or
            (self.job.generation != self.generation and (self.job.kind == .list or self.job.kind == .cached_search or self.job.kind == .recipient_cache or self.job.kind == .recipient_refresh or self.job.kind == .drafts or self.job.kind == .read or self.job.kind == .thread or self.job.kind == .contacts or self.job.kind == .invitation_inspect)) or
            (self.job.selection_generation != self.selection_generation and (self.job.kind == .read or self.job.kind == .thread or self.job.kind == .invitation_inspect)))
        {
            // Account/query/list identity changed while the provider was busy.
            if (self.page_loading and self.page_loading_account == self.job.account_index and self.page_loading_generation == self.job.generation) self.completePageLoad();
        } else if (self.job.failure) |err| {
            if (self.pageLoadCurrent() and self.page_loading_generation == self.job.generation) self.rollbackPageLoad();
            if (self.job.kind == .send or self.job.kind == .invitation) {
                (if (self.job.kind == .send) &self.compose.operation_error else &self.invitation_operation_error).set(self.allocator, @errorName(err)) catch {};
                self.markUnknown(self.job.kind);
            } else if (self.job.kind == .draft_operations) self.say(true, "Receipt lookup failed · draft remains protected", .{}) else if (err != error.Canceled) {
                if (self.job.kind == .list) self.syncFailed(self.job.account_index, @errorName(err));
                if (self.job.kind == .contacts) self.contacts_state = if (err == error.PermissionDenied) .denied else .failed;
                if (self.job.kind == .open and self.job.saved_attachment_open) self.attachmentOpenFailed(@errorName(err)) else self.sayError(@errorName(err));
            }
        } else if (self.job.response) |response| {
            try self.apply(self.job.kind, response);
        }
        if (self.pending_contacts and self.contactsOpen()) try self.dispatchPending();
        if (self.job.future != null) return;
        try self.retryLocalCache();
        try self.dispatchPending();
    }
    fn retryLocalCache(self: *App) !void {
        // Retry only on an owned completion or subsequent user input. A busy
        // cache retains one local intent; it never schedules network fetching
        // merely because a short disk commit held the shared read lock.
        if (self.pending_cached_contacts and self.contactsOpen()) {
            try self.cachedContacts();
            return;
        }
        if (self.pending_cached_list) {
            _ = self.loadCachedList(self.messageId()) catch |err| if (err == error.CacheBusy) false else return err;
            return;
        }
        if (self.pending_cached_read) {
            const full_thread = self.pending_cached_thread;
            try self.preview(full_thread);
        }
    }
    fn dispatchPending(self: *App) !void {
        if (try self.dispatchComposer()) return;
        // At most six coalesced flags exist. Local cache hits may complete
        // without starting a future, so drain them rather than leaving the
        // next intent waiting for an event that will never arrive.
        for (0..6) |_| {
            if (self.job.future != null) return;
            if (self.label_picker and self.pending_labels) {
                self.pending_labels = false;
                try self.start(.labels_list, .{ .cmd = "labels.list", .account = self.account() });
            } else if (self.pending_contacts) {
                self.pending_contacts = false;
                if (self.contactsOpen() and same(self.contacts_account.value(), self.account())) {
                    self.contacts_state = if (self.contacts_cache_ready) .cached else .loading;
                    try self.start(.contacts, .{ .account = self.contacts_account.value(), .cmd = if (self.contacts_query.value().len == 0) "contacts.list" else "contacts.search", .query = self.contacts_query.value() });
                }
            } else if (self.pending_page) {
                try self.consumePendingPage();
            } else if (self.pending_window_provider) {
                try self.dispatchWindowProvider();
            } else if (self.pending_list) {
                self.pending_list = false;
                try self.reload();
            } else if (self.pending_remote_list) {
                self.pending_remote_list = false;
                try self.cursor.set(self.allocator, "");
                try self.fetchMailboxPage();
            } else if (self.pending_compose != .none) {
                const pending = self.pending_compose;
                self.pending_compose = .none;
                self.pending_read = false;
                self.pending_thread = false;
                if (!same(self.account(), self.pending_compose_account[0..self.pending_compose_account_len])) {
                    self.say(false, "Queued draft discarded after account change", .{});
                } else if (pending == .new) try self.composeNew(null) else {
                    // The user can move the cursor while a read is finishing.
                    // Reply to the captured identity, never the later selection.
                    var retained_original = same(self.reader_account.value(), self.account());
                    if (retained_original) {
                        retained_original = false;
                        for (self.thread) |message| retained_original = retained_original or same(text(get(message, "id")), self.pending_compose_id[0..self.pending_compose_id_len]);
                    }
                    if (!retained_original) self.clearReader();
                    if (pending == .forward) try self.start(.compose, .{ .account = self.account(), .cmd = "mail.forward", .messageId = self.pending_compose_id[0..self.pending_compose_id_len] }) else try self.start(.compose, .{ .account = self.account(), .cmd = "mail.reply", .messageId = self.pending_compose_id[0..self.pending_compose_id_len], .all = pending == .reply_all });
                }
            } else if (self.pending_read) {
                self.pending_read = false;
                const full_thread = self.pending_thread;
                self.pending_thread = false;
                try self.preview(full_thread);
            } else if (self.pending_labels) {
                self.pending_labels = false;
                try self.start(.labels_list, .{ .cmd = "labels.list", .account = self.account() });
            } else return;
        }
    }
    fn apply(self: *App, kind: JobKind, response: []const u8) !void {
        // Validate the envelope before replacing a valid cached view.
        _ = self.data(self.job_arena.allocator(), response) catch |err| {
            if (err == error.OperationRejected) {
                if (kind == .open and self.job.saved_attachment_open) {
                    var code_buffer: [64]u8 = undefined;
                    const code = self.status_error_code[0..self.status_error_len];
                    @memcpy(code_buffer[0..code.len], code);
                    self.attachmentOpenFailed(code_buffer[0..code.len]);
                }
                if (self.pageLoadCurrent() and (kind == .list or kind == .cached_search or kind == .drafts)) self.rollbackPageLoad();
                if (kind == .send or kind == .invitation) self.markUnknown(kind);
                if (kind == .list) self.syncFailed(self.job.account_index, self.status_error_code[0..self.status_error_len]);
                if (kind == .contacts) self.contacts_state = if (same(self.status_error_code[0..self.status_error_len], "PermissionDenied")) .denied else .failed;
                return;
            }
            return err;
        };
        switch (kind) {
            .labels_list => {
                try self.replaceLabels(response);
                self.say(false, "{s}", .{if (self.label_picker) "Choose label · Enter Add · - Remove" else "Ready"});
            },
            .batch, .undo => {
                const result_value = try self.data(self.job_arena.allocator(), response);
                if (kind == .batch and text(get(result_value, "undoToken")).len > 0) {
                    try self.undo_token.set(self.allocator, text(get(result_value, "undoToken")));
                    try self.undo_account.set(self.allocator, self.account());
                }
                self.mail_selection.clear();
                self.mode = .browse;
                self.say(truth(get(result_value, "partial")), "{s}: {d} applied, {d} restored{s} · :undo", .{
                    if (kind == .undo) "Undo" else "Mail action", integer(get(result_value, "appliedCount")), integer(get(result_value, "restoredCount")),
                    if (truth(get(result_value, "partial"))) " · some outcomes need review" else "",
                });
                self.generation +%= 1;
                self.action_notice = true;
                self.status_kind = .action;
                try self.cursor.set(self.allocator, "");
                self.clearHistory();
                _ = try self.loadCachedList("");
                self.pending_list = true;
            },
            .refresh => unreachable, // Refresh metadata/merge is handled by finish.
            .recipient_cache => {
                try self.replaceRecipients(response);
            },
            .recipient_refresh => {
                self.pending_recipient_cache = true;
            },
            .cached_search => {
                self.pending_cached_list = false;
                try self.replaceList(.cached_search, response);
                if (!self.compose_active and self.messages.len > 0 and self.thread.len == 0) self.pending_read = true;
            },
            .list, .drafts => {
                try self.replaceList(kind, response);
                if (kind == .list) {
                    self.sync[self.account_index].state = .current;
                    // A provider page outside newest-N retention is still a
                    // valid visible page. Never erase it with an empty local
                    // subset just because those older IDs were evicted.
                    self.pending_remote_list = false;
                    if (!self.compose_active and self.messages.len > 0 and self.thread.len == 0) self.pending_read = true;
                }
            },
            .read, .thread => {
                try self.replaceReader(kind == .thread, response, false);
            },
            .compose, .draft_read => {
                const result = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                self.cancelAutosaveTimer();
                self.autosave_due = false;
                try self.compose.load(self.allocator, result);
                self.compose.new_draft = kind == .compose;
                if (self.compose.from.value().len == 0) {
                    try self.compose.from.set(self.allocator, self.account());
                    try self.compose.from_name.set(self.allocator, text(get(self.accounts[self.account_index], "senderName")));
                }
                self.compose_active = true;
                self.mode = .compose;
                self.pending_read = false;
                self.pending_thread = false;
                if (kind == .draft_read or !self.compose_original) {
                    self.compose_original = false;
                    self.clearReader();
                }
                self.composeCachedContacts();
                self.pending_identities = true;
                if (kind == .compose) {
                    const signature_in = text(get(self.accounts[self.account_index], "signature"));
                    if (signature_in.len > 0) {
                        try self.setComposeSignature(signature_in);
                        try self.composerChanged();
                    }
                }
                self.say(false, "Draft retained · i Edit · e $EDITOR · Ctrl+S Review send", .{});
                if (kind == .draft_read) {
                    self.compose.unknown_outcome = true;
                    try self.inspectDraftOperations();
                } else _ = try self.dispatchComposer();
            },
            .identities => {
                try self.replaceIdentities(response);
                if (self.compose_active and self.compose.new_draft and self.compose.revision == 0 and !self.compose.unknown_outcome) {
                    for (self.identities) |identity| if (std.ascii.eqlIgnoreCase(text(get(identity, "address")), self.compose.from.value())) {
                        const signature_in = text(get(identity, "signature"));
                        if (signature_in.len > 0) {
                            try self.setComposeSignature(signature_in);
                            try self.composerChanged();
                        }
                        break;
                    };
                }
                self.say(false, "Verified sending identities ready · f chooses From", .{});
            },
            .autosave => {
                const result = try self.data(self.job_arena.allocator(), response);
                try self.compose.id.set(self.allocator, text(get(result, "id")));
                self.compose.saved_revision = self.autosave_revision;
                self.say(false, "{s}", .{if (self.compose.revision == self.compose.saved_revision) "Draft saved locally · no mail sent" else "Earlier changes saved · newer edits pending"});
            },
            .draft_operations => {
                const result = try self.data(self.job_arena.allocator(), response);
                if (get(result, "operations") != .array) return error.InvalidProviderResponse;
                self.compose.unknown_outcome = false;
                try self.compose.operation_id.set(self.allocator, "");
                try self.compose.operation_error.set(self.allocator, "");
                for (items(get(result, "operations"))) |operation| if (same(text(get(operation, "draftId")), self.compose.id.value())) {
                    if (same(text(get(operation, "outcome")), "unknown")) {
                        self.compose.unknown_outcome = true;
                        try self.compose.operation_id.set(self.allocator, text(get(operation, "id")));
                        try self.compose.operation_error.set(self.allocator, text(get(operation, "errorCode")));
                        break;
                    }
                };
                if (self.compose.unknown_outcome) self.markUnknown(.send) else self.say(false, "Receipts checked · Ctrl+S Review send", .{});
            },
            .save, .save_review, .save_back => {
                const result = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                try self.compose.id.set(self.allocator, text(get(result, "id")));
                self.compose.saved_revision = self.autosave_revision;
                self.mode = if (kind == .save_review) .review else if (kind == .save_back) .browse else .compose;
                if (kind == .save_back) self.compose_active = false;
                if (kind == .save and self.editor_exit != null) {
                    const exit_code = self.editor_exit.?;
                    self.editor_exit = null;
                    if (exit_code == 0) self.say(false, "Editor returned · draft retained · Ctrl+S Review send", .{}) else self.say(true, "Editor exited {d} · changed text retained · Ctrl+S Review send", .{exit_code});
                } else self.say(false, "{s}", .{if (kind == .save_review) "Review send · y Send · Esc Return to draft" else "Draft saved locally"});
                if (kind == .save_review) self.reader_scroll = 0;
                if (kind == .save_back and self.folder == 2) self.pending_list = true;
                if (kind == .save_back) try self.resumeMailboxReader();
            },
            .invitation_inspect => {
                const result = try self.data(self.job_arena.allocator(), response);
                self.invitation_review = .{};
                try self.invitation_review.uid.set(text(get(result, "uid")));
                try self.invitation_review.organizer.set(text(get(result, "organizer")));
                try self.invitation_review.attendee.set(text(get(result, "attendee")));
                try self.invitation_review.summary.set(text(get(result, "summary")));
                try self.invitation_review.start.set(text(get(result, "start")));
                try self.invitation_review.recurrence_id.set(text(get(result, "recurrenceId")));
                self.invitation_scroll = 0;
                self.invitation_confirm_ready = false;
                self.mode = .invitation;
                self.say(false, "Review RSVP · a Accept · t Tentative · d Decline · Esc Cancel", .{});
            },
            .send, .invitation => {
                const result = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                const outcome = text(get(result, "outcome"));
                const operation_id = text(get(result, "id"));
                if (operation_id.len > 0) try (if (kind == .send) &self.compose.operation_id else &self.invitation_operation_id).set(self.allocator, operation_id);
                try (if (kind == .send) &self.compose.operation_error else &self.invitation_operation_error).set(self.allocator, text(get(result, "errorCode")));
                if (!same(outcome, "applied") and !same(outcome, "rejected")) {
                    self.markUnknown(kind);
                } else if (same(outcome, "rejected")) {
                    if (kind == .send) self.compose.unknown_outcome = false else self.invitation_unknown = false;
                    self.say(true, "{s} · {s}", .{ if (kind == .send) "Submission rejected · draft retained" else "RSVP submission rejected", if (kind == .send) self.compose.operation_error.value() else self.invitation_operation_error.value() });
                    self.mode = if (kind == .send) .compose else .browse;
                } else {
                    self.mode = .browse;
                    if (kind == .send) self.compose_active = false;
                    self.sayAction(false, "{s}", .{if (self.options.fixtures) "Saved by mock provider" else "Submitted; recipient delivery is not confirmed"});
                    if (kind == .send) try self.resumeMailboxReader();
                }
            },
            .contacts => {
                try self.replaceContacts(response, false);
                self.say(false, "{d} contacts available", .{self.contacts.len});
            },
            .contact_write => {
                _ = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                self.sayAction(false, "Contact saved", .{});
                if (self.contactsOpen()) try self.loadContacts("");
            },
            .mutation => {
                _ = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                self.mode = .browse;
                self.pending_list = true;
                self.sayAction(false, "Change applied", .{});
            },
            .open => {
                self.action_notice = false;
                if (self.job.saved_attachment_open) self.sayAction(false, "{s}", .{if (self.options.fixtures) "Attachment saved · mock file-open validated" else "Attachment saved and opened"}) else self.sayAction(false, "{s}", .{if (self.options.fixtures) "Mock browser target validated" else "Opened in the configured browser profile"});
            },
            .attachment_save => {
                self.sayAction(false, "Saved attachment ({d} bytes) to {s}", .{ self.attachment_expected_size, self.attachment_destination.value() });
                try self.finishReaderAttachment();
            },
        }
    }
    fn chooseAccount(self: *App, index: usize) !void {
        if (index >= self.accounts.len or self.mode == .compose or self.mode == .review or self.mode == .contact_edit) return;
        if (self.job.future != null and self.job.kind != .refresh and self.job.kind != .list and self.job.kind != .cached_search and self.job.kind != .recipient_cache and self.job.kind != .recipient_refresh and self.job.kind != .drafts and self.job.kind != .read and self.job.kind != .thread and self.job.kind != .contacts) {
            self.say(true, "Wait for the current account's change to finish", .{});
            return;
        }
        if (self.job.future != null and (self.job.kind == .cached_search or self.job.kind == .recipient_cache or self.job.kind == .recipient_refresh)) self.preemptReadOnly();
        self.search_saved_valid = false;
        self.search_restore_pending = false;
        self.rememberWorkingContext();
        self.saveUiPreferences();
        self.account_positions[self.account_index] = self.selected;
        self.account_index = index;
        self.contacts_generation +%= 1;
        self.pending_contacts = false;
        self.pending_cached_contacts = false;
        self.pending_compose = .none;
        self.selected = self.account_positions[index];
        self.generation +%= 1;
        self.clearHistory();
        try self.cursor.set(self.allocator, "");
        try self.query.set(self.allocator, "");
        self.query_scope = .cache;
        self.input_query_scope = .cache;
        self.messages = &.{};
        self.clearReader();
        self.view_ready = false;
        self.sync[index].state = .cached;
        try self.restoreWorkingContext();
        try self.prepareLabels();
        try self.reload();
    }
    fn providerPageCursor(self: *const App, cursor_value: []const u8) bool {
        return std.mem.startsWith(u8, cursor_value, "L:") or (self.options.fixtures and std.mem.startsWith(u8, cursor_value, "1:"));
    }
    fn pageLoadCurrent(self: *const App) bool {
        return self.page_loading and self.page_loading_account == self.account_index and self.page_loading_generation == self.generation;
    }
    fn completePageLoad(self: *App) void {
        self.page_loading = false;
        self.page_relative = false;
        if (self.page_popped_cursor) |previous| self.allocator.free(previous);
        self.page_popped_cursor = null;
    }
    fn rollbackPageLoad(self: *App) void {
        if (!self.page_loading) return;
        if (self.pageLoadCurrent()) {
            self.cursor.set(self.allocator, self.page_previous_cursor.value()) catch {};
            self.selected = @min(self.page_previous_selected, self.messages.len -| 1);
            self.top = self.page_previous_top;
            self.generation = self.page_previous_generation;
            if (self.page_loading_forward) {
                while (self.previous_cursors.items.len > self.page_previous_stack_depth) {
                    self.allocator.free(self.previous_cursors.pop().?);
                }
            } else if (self.page_popped_cursor) |previous| {
                self.previous_cursors.append(self.allocator, previous) catch {
                    self.allocator.free(previous);
                };
                self.page_popped_cursor = null;
            }
        }
        self.completePageLoad();
    }
    fn queueNextPage(self: *App) !void {
        return self.queuePage(true, false);
    }
    fn queuePage(self: *App, forward: bool, automatic: bool) !void {
        if (self.pending_page and self.pending_page_account == self.account_index and self.pending_page_generation == self.generation and self.pending_page_forward == forward) return;
        if (self.messages.len == 0) return;
        try self.pending_page_boundary.set(self.allocator, text(get(self.messages[if (forward) self.messages.len - 1 else 0], "id")));
        self.pending_page_account = self.account_index;
        self.pending_page_generation = self.generation;
        self.pending_page_forward = forward;
        self.pending_page_automatic = automatic;
        const received = get(self.messages[if (forward) self.messages.len - 1 else 0], "receivedAt");
        self.pending_page_received_at = if (received == .integer) received.integer else 0;
        self.pending_page = true;
        self.say(false, "{s} page queued · cached mail remains usable", .{if (forward) "Next" else "Previous"});
    }
    fn consumePendingPage(self: *App) !void {
        if (!self.pending_page) return;
        if (self.pending_page_account != self.account_index or self.pending_page_generation != self.generation or self.mode != .browse) {
            self.pending_page = false;
            return;
        }
        var boundary: ?usize = null;
        for (self.messages, 0..) |message, index| if (same(text(get(message, "id")), self.pending_page_boundary.value())) {
            boundary = index;
            break;
        };
        if (boundary == null) {
            if (self.pending_page_automatic) {
                const forward = self.pending_page_forward;
                self.pending_page = false;
                try self.cacheWindow(forward, true, .{ .id = self.pending_page_boundary.value(), .received_at = self.pending_page_received_at });
                return;
            }
            _ = self.loadCachedList(self.pending_page_boundary.value()) catch false;
            if (self.job.future != null) return;
            for (self.messages, 0..) |message, index| if (same(text(get(message, "id")), self.pending_page_boundary.value())) {
                boundary = index;
                break;
            };
        }
        self.pending_page = false;
        if (boundary) |index| {
            if (self.pending_page_forward and index + 1 < self.messages.len) {
                self.selected = index + 1;
                self.selection_generation +%= 1;
                self.top = self.selected;
                try self.preview(false);
            } else if (!self.pending_page_forward and self.pending_page_automatic and index > 0) {
                self.selected = index - 1;
                self.selection_generation +%= 1;
                self.top = self.selected;
                try self.preview(false);
            } else if (self.pending_page_automatic) try self.scrollWindow(self.pending_page_forward) else try self.page(self.pending_page_forward);
        } else self.say(false, "Mail changed · scroll again to continue", .{});
    }
    fn scrollWindow(self: *App, forward: bool) !void {
        try self.cacheWindow(forward, true, null);
    }
    fn dispatchWindowProvider(self: *App) !void {
        if (!self.pending_window_provider or self.job.future != null) return;
        self.pending_window_provider = false;
        if (self.pageLoadCurrent() and !self.cacheSearch() and self.providerPageCursor(self.cursor.value())) {
            try self.fetchMailboxPage();
        } else self.rollbackPageLoad();
    }
    fn cacheWindow(self: *App, forward: bool, nearest: bool, boundary_override: ?ScrollBoundary) !void {
        if (self.pageLoadCurrent()) {
            if (forward == self.page_loading_forward) return;
            self.preemptReadOnly();
        }
        if (self.view_ready and self.view_generation != self.generation) {
            self.say(false, "Loading search results · retained mail remains usable", .{});
            return;
        }
        if (self.messages.len == 0 and boundary_override == null) return;
        if (!forward and self.has_more_cached_before == false and boundary_override == null) return;
        if (forward and self.cacheSearch() and self.has_more_cached_after == false and boundary_override == null) return;
        if (self.job.future != null) {
            if (self.job.kind == .refresh) {
                if (self.cacheSearch() and cache_query.needsBody(self.query.value())) {
                    try self.queuePage(forward, nearest);
                    return;
                }
            } else if (readOnlyJob(self.job.kind)) self.preemptReadOnly() else {
                try self.queuePage(forward, nearest);
                return;
            }
        }
        const boundary = boundary_override orelse blk: {
            const message = self.messages[if (forward) self.messages.len - 1 else 0];
            const received = get(message, "receivedAt");
            break :blk ScrollBoundary{ .id = text(get(message, "id")), .received_at = if (received == .integer) received.integer else 0 };
        };
        if (boundary.id.len == 0) return;
        if (forward and self.previous_cursors.items.len >= types.Limits.metadata_hard) return error.CursorHistoryTooLarge;
        try self.page_relative_boundary.set(self.allocator, boundary.id);
        try self.page_previous_cursor.set(self.allocator, self.cursor.value());
        self.page_previous_selected = self.selected;
        self.page_previous_top = self.top;
        self.page_previous_generation = self.generation;
        self.page_previous_stack_depth = self.previous_cursors.items.len;
        self.page_loading_account = self.account_index;
        self.page_loading_generation = self.generation;
        self.page_loading_forward = forward;
        self.page_select_nearest = nearest;
        self.page_relative = true;
        self.page_relative_received_at = boundary.received_at;
        self.page_loading = true;
        errdefer self.rollbackPageLoad();
        if (forward) {
            const previous = try self.allocator.dupe(u8, self.cursor.value());
            self.previous_cursors.append(self.allocator, previous) catch |err| {
                self.allocator.free(previous);
                return err;
            };
        } else self.page_popped_cursor = self.previous_cursors.pop();
        self.generation +%= 1;
        self.page_loading_generation = self.generation;
        self.pending_page = false;
        self.pending_read = false;
        self.pending_thread = false;
        _ = try self.loadCachedList("");
        try self.dispatchWindowProvider(); // Local response arena has finished; no idle intent.
        if (self.pending_read and self.job.future == null) {
            self.pending_read = false;
            try self.preview(false);
        }
        if (self.page_loading) self.say(false, "Loading {s} cached mail…", .{if (forward) "older" else "newer"});
    }
    fn page(self: *App, forward: bool) !void {
        if (!forward) {
            const previous = if (self.previous_cursor.value().len > 0) self.previous_cursor.value() else if (self.previous_cursors.items.len > 0) self.previous_cursors.items[self.previous_cursors.items.len - 1] else "";
            if (self.providerPageCursor(previous)) return self.cacheWindow(false, false, null);
        }
        if (self.pageLoadCurrent()) {
            if (!forward) self.preemptReadOnly();
            return; // One page per demand, even when several wheel events arrive.
        }
        if (self.view_ready and self.view_generation != self.generation) {
            self.say(false, "Loading search results · retained mail remains usable", .{});
            return;
        }
        const next = if (self.next_cursor.value().len > 0) self.next_cursor.value() else if (!self.cacheSearch()) self.remote_cursor.value() else "";
        if (forward and (next.len == 0 or same(next, self.cursor.value()))) return;
        if (forward and self.cacheSearch() and self.providerPageCursor(next)) return; // Cache search never downloads older mail.
        if (self.job.future != null) {
            if (self.job.kind == .refresh) {
                if (self.providerPageCursor(next) or (self.cacheSearch() and cache_query.needsBody(self.query.value()))) {
                    try self.queuePage(forward, false);
                    return;
                }
            } else if (readOnlyJob(self.job.kind)) self.preemptReadOnly() else {
                try self.queuePage(forward, false);
                return;
            }
        }
        if (forward and self.previous_cursors.items.len >= types.Limits.metadata_hard) return error.CursorHistoryTooLarge;
        try self.page_previous_cursor.set(self.allocator, self.cursor.value());
        self.page_previous_selected = self.selected;
        self.page_previous_top = self.top;
        self.page_previous_generation = self.generation;
        self.page_previous_stack_depth = self.previous_cursors.items.len;
        self.page_loading_account = self.account_index;
        self.page_loading_generation = self.generation;
        self.page_loading_forward = forward;
        self.page_select_nearest = false;
        self.page_relative = false;
        self.page_loading = true;
        errdefer self.rollbackPageLoad();
        if (forward) {
            const previous = try self.allocator.dupe(u8, self.cursor.value());
            self.previous_cursors.append(self.allocator, previous) catch |err| {
                self.allocator.free(previous);
                return err;
            };
            try self.cursor.set(self.allocator, next);
        } else if (self.previous_cursor.value().len > 0) {
            try self.cursor.set(self.allocator, self.previous_cursor.value());
            self.page_popped_cursor = self.previous_cursors.pop();
        } else {
            const previous = self.previous_cursors.pop() orelse {
                self.completePageLoad();
                return;
            };
            self.page_popped_cursor = previous;
            try self.cursor.set(self.allocator, previous);
        }
        self.generation +%= 1;
        self.page_loading_generation = self.generation;
        self.pending_page = false;
        self.pending_read = false;
        self.pending_thread = false;
        if (self.drafts_list or (self.query.value().len > 0 and self.query_scope == .server) or self.providerPageCursor(self.cursor.value())) {
            try self.reload();
        } else {
            _ = try self.loadCachedList("");
            if (self.pending_read and self.job.future == null) {
                self.pending_read = false;
                try self.preview(false);
            }
        }
        if (self.page_loading) self.say(false, "Loading {s} mail page…", .{if (forward) "next" else "previous"});
    }
    fn composeNew(self: *App, reply_all: ?bool) !void {
        self.compose_original = reply_all != null;
        if (reply_all == null and self.job.future != null and readOnlyJob(self.job.kind)) self.preemptReadOnly();
        const target_id = self.readerReplyId();
        if (self.job.future != null) {
            if (reply_all != null and target_id.len == 0) return;
            if (self.account().len > self.pending_compose_account.len or target_id.len > self.pending_compose_id.len) return error.InvalidIdentity;
            @memcpy(self.pending_compose_account[0..self.account().len], self.account());
            self.pending_compose_account_len = self.account().len;
            @memcpy(self.pending_compose_id[0..target_id.len], target_id);
            self.pending_compose_id_len = target_id.len;
            self.pending_compose = if (reply_all) |all| (if (all) .reply_all else .reply) else .new;
            self.say(false, "Draft requested · waiting for the current read", .{});
            return;
        }
        if (reply_all) |all| {
            if (target_id.len == 0) return;
            try self.start(.compose, .{ .account = self.account(), .cmd = "mail.reply", .messageId = target_id, .all = all });
        } else try self.start(.compose, .{ .account = self.account(), .cmd = "draft.create", .draft = types.Draft{} });
    }
    fn composeForward(self: *App) !void {
        self.compose_original = true;
        const target_id = self.readerReplyId();
        if (target_id.len == 0) return;
        if (self.job.future != null) {
            if (self.account().len > self.pending_compose_account.len or target_id.len > self.pending_compose_id.len) return error.InvalidIdentity;
            @memcpy(self.pending_compose_account[0..self.account().len], self.account());
            self.pending_compose_account_len = self.account().len;
            @memcpy(self.pending_compose_id[0..target_id.len], target_id);
            self.pending_compose_id_len = target_id.len;
            self.pending_compose = .forward;
            self.say(false, "Forward requested · waiting for the current read", .{});
            return;
        }
        try self.start(.compose, .{ .account = self.account(), .cmd = "mail.forward", .messageId = target_id });
    }
    fn cancelAutosaveTimer(self: *App) void {
        if (self.autosave_timer) |*future| future.cancel(self.io);
        self.autosave_timer = null;
    }
    fn autosaveTimer(self: *App, started: i64) void {
        while (true) {
            const deadline = @min(self.autosave_last_edit.load(.acquire) + 1500, started + 10000);
            const remaining = deadline - Io.Timestamp.now(self.io, .awake).toMilliseconds();
            if (remaining <= 0) break;
            self.io.sleep(.fromMilliseconds(remaining), .awake) catch return;
        }
        self.loop.postEvent(.compose_idle) catch {};
    }
    fn armAutosave(self: *App) !void {
        if (@import("builtin").is_test) return;
        const now = Io.Timestamp.now(self.io, .awake).toMilliseconds();
        self.autosave_last_edit.store(now, .release);
        if (self.autosave_timer == null) {
            self.autosave_started = now;
            self.autosave_timer = try self.io.concurrent(autosaveTimer, .{ self, now });
        }
    }
    fn onComposeIdle(self: *App) !void {
        self.cancelAutosaveTimer();
        const now = Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (now - self.autosave_last_edit.load(.acquire) < 1500 and now - self.autosave_started < 10000) {
            if (!@import("builtin").is_test) self.autosave_timer = try self.io.concurrent(autosaveTimer, .{ self, self.autosave_started });
            return;
        }
        try self.autosaveDraft();
    }
    fn composerChanged(self: *App) !void {
        self.compose.revision +%= 1;
        self.compose.completion_selected = 0;
        self.say(false, "Draft changed · autosave pending · no mail sent", .{});
        try self.armAutosave();
    }
    fn autosaveDraft(self: *App) !void {
        self.cancelAutosaveTimer();
        if (!self.compose_active or self.compose.unknown_outcome or self.compose.id.value().len == 0 or self.compose.revision == self.compose.saved_revision or self.mode == .review or self.mode == .browse) return;
        if (self.job.future != null) {
            self.autosave_due = true;
            return;
        }
        self.autosave_due = false;
        var fields: [5][]const u8 = undefined;
        self.autosave_revision = self.compose.revision;
        try self.start(.autosave, .{ .account = self.account(), .cmd = "draft.recovery-save", .draftId = self.compose.id.value(), .draft = self.compose.recovery(&fields) });
        self.say(false, "Saving draft locally… · typing remains available", .{});
    }
    fn composeCompletions(self: *const App) completion.Matches {
        if (!self.compose.insert_mode or self.compose.selected >= 3 or self.compose.unknown_outcome) return .{ .range = .{ .start = 0, .end = 0, .query = "" } };
        const field = &self.compose.fields[self.compose.selected];
        return completion.collectKnown(if (same(self.recipient_account.value(), self.account())) self.recipient_values else &.{}, if (same(self.contacts_account.value(), self.account()) and self.contacts_query.value().len == 0) self.contacts else &.{}, self.account(), field.value(), field.cursor);
    }
    fn acceptCompletion(self: *App, index: usize) !void {
        const matches = self.composeCompletions();
        if (index >= matches.len) return;
        const field = &self.compose.fields[self.compose.selected];
        const updated = try completion.replace(self.allocator, field.value(), matches.range, matches.values[index].address);
        defer self.allocator.free(updated);
        if (updated.len > 16 * 1024) return error.InputTooLarge;
        try field.set(self.allocator, updated);
        field.cursor = matches.range.start + matches.values[index].address.len;
        try self.composerChanged();
    }
    fn composeCachedContacts(self: *App) void {
        if (!same(self.recipient_account.value(), self.account())) {
            self.recipient_values = &.{};
            self.recipient_ready = false;
            self.recipient_account.set(self.allocator, self.account()) catch return;
        }
        self.pending_recipient_cache = true;
        if (!self.recipient_refreshed[self.account_index]) self.pending_recipient_refresh = true;
    }
    fn replaceRecipients(self: *App, response: []const u8) !void {
        var replacement: std.heap.ArenaAllocator = .init(self.allocator);
        defer replacement.deinit();
        const result = try self.data(replacement.allocator(), response);
        const values = get(result, "recipients");
        if (values != .array or values.array.items.len > @import("recipient_cache.zig").max_candidates) return error.InvalidRecipientCandidates;
        for (values.array.items) |value| {
            try recipients.validateAddress(text(get(value, "address")));
            try recipients.validateHeader(text(get(value, "name")));
        }
        if (self.recipient_arena) |*previous| previous.deinit();
        self.recipient_arena = replacement;
        replacement = .init(self.allocator);
        self.recipient_values = values.array.items;
        try self.recipient_account.set(self.allocator, self.account());
        self.recipient_ready = true;
    }
    fn recipientHint(self: *const App) []const u8 {
        if (self.pending_recipient_cache or self.pending_recipient_refresh or (self.job.future != null and (self.job.kind == .recipient_cache or self.job.kind == .recipient_refresh))) return "Fetching recent-mail suggestions… · keep typing";
        return "No matching recent-mail recipient · type an address";
    }
    fn replaceIdentities(self: *App, response: []const u8) !void {
        var replacement: std.heap.ArenaAllocator = .init(self.allocator);
        defer replacement.deinit();
        const result = try self.data(replacement.allocator(), response);
        const values = get(result, "identities");
        if (values != .array or values.array.items.len > 32) return error.InvalidIdentities;
        for (values.array.items) |identity| {
            try recipients.validateAddress(text(get(identity, "address")));
            try recipients.validateHeader(text(get(identity, "name")));
            if (text(get(identity, "signature")).len > 8192) return error.InvalidSignature;
        }
        if (self.identity_arena) |*previous| previous.deinit();
        self.identity_arena = replacement;
        replacement = .init(self.allocator);
        self.identities = values.array.items;
        try self.identities_account.set(self.allocator, self.account());
    }
    fn setComposeSignature(self: *App, signature_in: []const u8) !void {
        if (signature_in.len > 8192) return error.InvalidSignature;
        const clean = try safe(self.frame.allocator(), signature_in, true);
        const field = &self.compose.fields[4];
        const previous = self.compose.signature.value();
        const body = field.value();
        var insert_at = std.mem.indexOf(u8, body, "\n\n> ") orelse std.mem.indexOf(u8, body, "\n\n---------- Forwarded message ----------") orelse body.len;
        var suffix_at = insert_at;
        if (previous.len > 0) {
            const marker = try std.fmt.allocPrint(self.frame.allocator(), "\n\n-- \n{s}\n\n", .{previous});
            if (std.mem.count(u8, body, marker) != 1) {
                self.compose.signature_custom = true;
                return;
            }
            insert_at = std.mem.indexOf(u8, body, marker).?;
            suffix_at = insert_at + marker.len;
        }
        const marker = if (clean.len > 0) try std.fmt.allocPrint(self.frame.allocator(), "\n\n-- \n{s}\n\n", .{clean}) else "";
        const changed = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}{s}", .{ body[0..insert_at], marker, body[suffix_at..] });
        if (changed.len > types.Limits.body_bytes) return error.BodyTooLarge;
        const old_cursor = field.cursor;
        try field.set(self.allocator, changed);
        field.cursor = if (old_cursor <= insert_at) old_cursor else if (old_cursor >= suffix_at) insert_at + marker.len + (old_cursor - suffix_at) else insert_at + @min(old_cursor - insert_at, marker.len);
        self.compose.signature_custom = false;
        try self.compose.signature.set(self.allocator, clean);
    }
    fn cycleComposeIdentity(self: *App) !void {
        if (!self.canEditAttachments()) return;
        if (!same(self.identities_account.value(), self.account()) or self.identities.len == 0) {
            self.pending_identities = true;
            self.say(false, "Loading verified sending identities…", .{});
            _ = try self.dispatchComposer();
            return;
        }
        // Reopened drafts carry the body itself. Recognize only the exact
        // generated block for the currently verified identity; never infer
        // that an arbitrary user-written footer should be removed.
        if (self.compose.signature.value().len == 0) for (self.identities) |identity| {
            if (!std.ascii.eqlIgnoreCase(text(get(identity, "address")), self.compose.from.value())) continue;
            const signature_in = text(get(identity, "signature"));
            if (signature_in.len == 0) break;
            const marker = try std.fmt.allocPrint(self.frame.allocator(), "\n\n-- \n{s}\n\n", .{signature_in});
            if (std.mem.count(u8, self.compose.fields[4].value(), marker) == 1) try self.compose.signature.set(self.allocator, signature_in);
            break;
        };
        var chosen: usize = 0;
        for (self.identities, 0..) |identity, index| if (std.ascii.eqlIgnoreCase(text(get(identity, "address")), self.compose.from.value())) {
            chosen = (index + 1) % self.identities.len;
            break;
        };
        const identity = self.identities[chosen];
        try self.compose.from.set(self.allocator, text(get(identity, "address")));
        try self.compose.from_name.set(self.allocator, text(get(identity, "name")));
        if (self.compose.new_draft or self.compose.signature.value().len > 0 or self.compose.fields[4].value().len == 0) try self.setComposeSignature(text(get(identity, "signature"))) else self.compose.signature_custom = true;
        try self.composerChanged();
        self.say(false, "From: {s} · {s}", .{ self.compose.from.value(), if (self.compose.signature_custom) "edited body/signature retained" else "verified identity · draft changed" });
    }
    fn dispatchComposer(self: *App) !bool {
        if (self.job.future != null) return false;
        if (self.autosave_due) {
            try self.autosaveDraft();
            return self.job.future != null;
        }
        if (self.pending_recipient_cache and self.compose_active and !self.compose.unknown_outcome) {
            self.pending_recipient_cache = false;
            try self.start(.recipient_cache, .{ .account = self.account(), .cmd = "mail.recipients", .cacheOnly = true });
            return true;
        }
        if (self.pending_identities and self.compose_active and !self.compose.unknown_outcome) {
            self.pending_identities = false;
            try self.start(.identities, .{ .account = self.account(), .cmd = "accounts.identities" });
            return true;
        }
        if (self.pending_recipient_refresh and self.compose_active and !self.compose.unknown_outcome) {
            self.pending_recipient_refresh = false;
            self.recipient_refreshed[self.account_index] = true;
            // One bounded metadata-only Sent head per account/session. Never
            // search the provider on keystrokes or fetch full mailbox history.
            try self.start(.recipient_refresh, .{ .account = self.account(), .cmd = "mail.list", .label = "SENT", .limit = @as(usize, 32) });
            return true;
        }
        return false;
    }
    fn saveDraft(self: *App, kind: JobKind) !void {
        if (self.compose.unknown_outcome) {
            if (kind == .save_back) {
                self.mode = .browse;
                self.compose_active = false;
                self.say(true, "Outcome unknown · original recovery draft retained", .{});
                try self.resumeMailboxReader();
            } else self.markUnknown(.send);
            return;
        }
        self.preemptReadOnly();
        self.cancelAutosaveTimer();
        self.autosave_due = false;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        self.autosave_revision = self.compose.revision;
        const draft_value = self.compose.draft(arena.allocator()) catch |err| {
            if (kind == .save_review) return err;
            var fields: [5][]const u8 = undefined;
            try self.start(kind, .{ .account = self.account(), .cmd = "draft.recovery-save", .draftId = self.compose.id.value(), .draft = self.compose.recovery(&fields) });
            return;
        };
        try self.start(kind, .{ .account = self.account(), .cmd = "draft.update", .draftId = self.compose.id.value(), .draft = draft_value });
    }
    fn persistDraftAtExit(self: *App) !void {
        if (!self.compose_active or self.compose.id.value().len == 0 or self.compose.unknown_outcome) return;
        // A signal/EOF can arrive while text insertion or the picker is open.
        // Preserve valid edited fields through the same local draft operation.
        try self.saveDraft(.save);
        if (self.job.future) |*future| future.await(self.io);
        try self.finish();
        if (self.warning) return error.DraftPersistenceFailed;
    }
    fn canEditAttachments(self: *const App) bool {
        return !self.compose.unknown_outcome and (self.job.future == null or readOnlyJob(self.job.kind));
    }
    fn promptAttachment(self: *App) !void {
        if (!self.canEditAttachments()) return;
        self.previous_mode = .compose;
        self.mode = .attachment;
        self.path_candidates.reset();
        try self.input.set(self.allocator, "");
    }
    fn completePath(self: *App, field: *Field, backwards: bool) !void {
        const result = if (backwards) try self.path_candidates.shiftTab(self.io, self.allocator, field.value()) else try self.path_candidates.tab(self.io, self.allocator, field.value());
        if (result.path) |path| try field.set(self.allocator, path);
        if (result.matches == 0) self.say(false, "No matching regular files or directories", .{}) else self.say(false, "{d} path match{s} · Tab cycles · Enter accepts{s}", .{ result.matches, if (result.matches == 1) @as([]const u8, "") else "es", if (result.truncated) @as([]const u8, " · scan limit reached") else "" });
    }
    fn drawPathCandidates(self: *App, win: vaxis.Window, field: *const Field, first_row: usize, available: usize) !void {
        if (!self.path_candidates.active(field.value()) or self.path_candidates.candidates.len <= 1 or first_row >= win.height or available == 0) return;
        const visible = @min(@as(usize, 6), @min(available, self.path_candidates.candidates.len));
        const top = if (self.path_candidates.selected) |selected| selected -| (visible - 1) else 0;
        for (self.path_candidates.candidates[top .. top + visible], top..) |candidate, index| {
            const label = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ candidate.name, if (candidate.directory) @as([]const u8, "/") else "" });
            try self.line(win, first_row + index - top, try self.fitLine(win, label, win.width), if (self.path_candidates.selected != null and self.path_candidates.selected.? == index) .selected else .text);
        }
    }
    fn drawPathCompletion(self: *App, win: vaxis.Window) !void {
        if (self.mode != .attachment or !self.path_candidates.active(self.input.value()) or self.path_candidates.candidates.len <= 1) return;
        const width = @min(win.width -| 2, 78);
        const height = @min(win.height -| 4, 10);
        if (width < 10 or height < 4) return;
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = win.height - height - 2, .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, " Files · Tab cycles · literal paths ", true);
        try self.drawPathCandidates(inner, &self.input, 0, inner.height -| 1);
        try self.line(inner, inner.height - 1, if (self.path_candidates.truncated) "First matches · scan limit reached · Esc Back" else "Tab Next match · Enter Attach · Esc Back", .muted);
    }
    fn detachAttachment(self: *App, index: usize) !void {
        if (!self.canEditAttachments()) return;
        if (index >= self.compose.attachments.len) return error.InvalidAttachment;
        var retained: [16]types.Attachment = undefined;
        var count: usize = 0;
        for (self.compose.attachments, 0..) |item, attachment_index| if (attachment_index != index) {
            retained[count] = item;
            count += 1;
        };
        try self.compose.replaceAttachments(self.allocator, retained[0..count]);
        self.compose.attachment_scroll = @min(self.compose.attachment_scroll, count -| self.compose.attachment_height);
        try self.composerChanged();
        self.say(false, "Attachment removed · local draft · Ctrl+S Review", .{});
    }
    fn attachFile(self: *App, path: []const u8) !void {
        if (!self.canEditAttachments()) return;
        if (self.compose.attachments.len >= 16) return error.TooManyAttachments;
        const filename = std.fs.path.basename(path);
        if (filename.len == 0 or filename.len > 256 or same(filename, ".") or same(filename, "..") or std.mem.indexOfAny(u8, filename, "/\\") != null) return error.InvalidAttachment;
        try recipients.validateHeader(filename);
        var combined: usize = 0;
        for (self.compose.attachments) |item| combined = try std.math.add(usize, combined, item.size);
        if (combined > types.Limits.body_bytes) return error.BodyTooLarge;
        const file = try files.openRegular(self.io, self.allocator, Io.Dir.cwd(), path);
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size > types.Limits.body_bytes - combined) return error.InvalidAttachment;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const raw = try reader.interface.allocRemaining(arena.allocator(), .limited(types.Limits.body_bytes - combined));
        const encoded = try arena.allocator().alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
        _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
        var attachments: [16]types.Attachment = undefined;
        @memcpy(attachments[0..self.compose.attachments.len], self.compose.attachments);
        attachments[self.compose.attachments.len] = .{ .id = "", .filename = filename, .size = raw.len, .data = encoded };
        const updated = attachments[0 .. self.compose.attachments.len + 1];
        var draft_value = try self.compose.draft(arena.allocator());
        draft_value.attachments = updated;
        const request = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .account = self.account(), .cmd = "draft.update", .draftId = self.compose.id.value(), .draft = draft_value }, .{});
        if (request.len > types.Limits.request_bytes) return error.RequestTooLarge;
        try self.compose.replaceAttachments(self.allocator, updated);
        self.compose.attachment_scroll = updated.len -| @max(self.compose.attachment_height, 1);
        self.mode = .compose;
        try self.composerChanged();
        self.say(false, "Attached {s} · Ctrl+S reviews every attachment", .{filename});
    }
    fn saveIncomingAttachment(self: *App, arguments_in: []const u8) !void {
        if (self.job.future != null) return error.OperationBusy;
        const arguments_trimmed = std.mem.trimStart(u8, arguments_in, " \t");
        const separator = std.mem.indexOfAny(u8, arguments_trimmed, " \t") orelse return error.AttachmentSaveSyntax;
        const number = std.fmt.parseInt(usize, arguments_trimmed[0..separator], 10) catch return error.AttachmentSaveSyntax;
        // Everything after the numeric argument is a literal path, including
        // internal/trailing spaces. Quotes and variables are not interpreted.
        const path = std.mem.trimStart(u8, arguments_trimmed[separator..], " \t");
        if (number == 0 or path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AttachmentSaveSyntax;
        self.attachment_open_after = false;
        var index: usize = 0;
        for (self.thread) |message| for (items(get(message, "attachments"))) |attachment| {
            index += 1;
            if (index != number) continue;
            const size = get(attachment, "size");
            if (size != .integer or size.integer < 0 or size.integer > @as(i64, @intCast(types.Limits.body_bytes))) return error.InvalidAttachment;
            const message_id = text(get(message, "id"));
            const attachment_id = text(get(attachment, "id"));
            if (message_id.len == 0 or attachment_id.len == 0 or attachment_id.len > 1024) return error.InvalidAttachment;
            try self.attachment_destination.set(self.allocator, path);
            self.attachment_expected_size = @intCast(size.integer);
            // start serializes these identities before the worker can run;
            // later cursor movement cannot retarget the request or destination.
            try self.start(.attachment_save, .{ .account = self.account(), .cmd = "mail.attachment", .messageId = message_id, .attachmentId = attachment_id });
            return;
        };
        return error.AttachmentNotFound;
    }
    fn operationId(self: *App, allocator: Allocator) ![]const u8 {
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        return std.fmt.allocPrint(allocator, "tui-{s}", .{hex});
    }
    fn sendDraft(self: *App) !void {
        if (self.compose.unknown_outcome) {
            self.markUnknown(.send);
            return;
        }
        const id = try self.operationId(self.allocator);
        defer self.allocator.free(id);
        try self.compose.operation_id.set(self.allocator, id);
        try self.compose.operation_error.set(self.allocator, "");
        try self.start(.send, .{ .account = self.account(), .cmd = "draft.send", .draftId = self.compose.id.value(), .operationId = id });
    }
    fn inspectDraftOperations(self: *App) !void {
        self.compose.unknown_outcome = true;
        try self.start(.draft_operations, .{ .account = self.account(), .cmd = "operation.list", .draftId = self.compose.id.value() });
    }
    fn markUnknown(self: *App, kind: JobKind) void {
        if (kind == .send) {
            self.compose.unknown_outcome = true;
            self.compose.insert_mode = false;
            self.mode = .compose;
            self.say(true, "Outcome unknown · {s} · :receipt checks · q keeps draft", .{if (self.compose.operation_error.value().len > 0) self.compose.operation_error.value() else "Unconfirmed"});
        } else {
            self.invitation_unknown = true;
            self.mode = .browse;
            self.say(true, "RSVP outcome unknown · {s} · operation {s} · inspect before retrying", .{ if (self.invitation_operation_error.value().len > 0) self.invitation_operation_error.value() else "Unconfirmed", self.invitation_operation_id.value()[0..@min(self.invitation_operation_id.value().len, 64)] });
        }
        self.status_kind = .unknown;
        self.diagnostic("UnknownOutcome");
    }
    fn reviewInvitation(self: *App) !void {
        if (self.job.future != null) {
            self.say(false, "Wait for the selected message to finish loading", .{});
            return;
        }
        try self.invitation_inspected_id.set(self.allocator, self.messageId());
        try self.invitation_inspected_account.set(self.allocator, self.account());
        self.invitation_scroll = 0;
        self.invitation_confirm_ready = false;
        try self.start(.invitation_inspect, .{ .account = self.invitation_inspected_account.value(), .cmd = "invitation.inspect", .messageId = self.invitation_inspected_id.value() });
    }
    fn loadContacts(self: *App, query_in: []const u8) !void {
        try self.prepareContacts(query_in);
        if (self.job.future != null and self.job.kind == .refresh and self.job.waiting_external.load(.acquire)) {
            const pending = self.pending_contacts;
            const local = self.pending_cached_contacts;
            self.preemptReadOnly();
            self.pending_contacts = pending;
            self.pending_cached_contacts = local;
        }
        if (self.job.future == null) try self.dispatchPending();
    }
    fn contactsOpen(self: *const App) bool {
        return self.mode == .contacts or self.mode == .contact_edit or ((self.mode == .search or self.mode == .help) and self.previous_mode == .contacts);
    }
    fn replaceContacts(self: *App, response: []const u8, cached_view: bool) !void {
        var replacement: std.heap.ArenaAllocator = .init(self.allocator);
        defer replacement.deinit();
        const result = try self.data(replacement.allocator(), response);
        const contacts = items(get(result, "contacts"));
        if (contacts.len > 1024) return error.ContactListTooLarge;
        const previous = self.contact_arena;
        self.contact_arena = replacement;
        replacement = previous;
        self.contacts = contacts;
        self.contacts_selected = @min(self.contacts_selected, contacts.len -| 1);
        self.contacts_cache_ready = !cached_view or truth(get(result, "cacheReady"));
        self.contacts_state = if (cached_view and self.contacts_cache_ready) .cached else if (cached_view) .loading else .current;
    }
    fn cachedContacts(self: *App) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const response = self.cached(arena.allocator(), .{ .account = self.contacts_account.value(), .cmd = if (self.contacts_query.value().len == 0) "contacts.list" else "contacts.search", .query = self.contacts_query.value() }) catch |err| {
            if (err == error.PermissionDenied) {
                self.contacts_state = .denied;
                self.pending_contacts = false;
                self.pending_cached_contacts = false;
                self.say(true, "Contacts permission required · contacts-read", .{});
                return;
            }
            if (err == error.CacheBusy) {
                self.contacts_state = .busy;
                self.pending_cached_contacts = true;
                self.say(false, "Cache busy · contacts retry locally", .{});
                return;
            }
            self.contacts_state = .failed;
            self.pending_contacts = false;
            return err;
        };
        self.pending_cached_contacts = false;
        if (response) |bytes| try self.replaceContacts(bytes, true);
        self.pending_contacts = true;
        self.say(false, "{s}", .{if (self.contacts_cache_ready) "Cached contacts · refresh queued" else "Loading contacts · request queued"});
    }
    fn prepareContacts(self: *App, query_in: []const u8) !void {
        if (self.job.future != null and self.job.kind == .cached_search) self.preemptReadOnly();
        if (query_in.len > 4096) return error.InvalidQuery;
        try self.contacts_query.set(self.allocator, query_in);
        try self.contacts_account.set(self.allocator, self.account());
        self.contacts_generation +%= 1;
        self.contacts_selected = 0;
        self.contacts = &.{};
        _ = self.contact_arena.reset(.retain_capacity);
        self.contacts_cache_ready = false;
        self.contacts_state = .loading;
        self.pending_contacts = false;
        self.pending_cached_contacts = false;
        self.mode = .contacts;
        try self.cachedContacts();
    }
    fn leaveContacts(self: *App) void {
        self.contacts_generation +%= 1;
        self.pending_contacts = false;
        self.pending_cached_contacts = false;
        self.mode = backMode(.contacts, .browse, self.picker);
    }
    fn readOnlyJob(kind: JobKind) bool {
        return switch (kind) {
            .refresh, .list, .cached_search, .recipient_cache, .recipient_refresh, .read, .thread, .drafts, .draft_read, .draft_operations, .contacts, .invitation_inspect, .identities, .autosave, .labels_list => true,
            else => false,
        };
    }
    fn preemptReadOnly(self: *App) void {
        if (self.job.future == null or !readOnlyJob(self.job.kind)) return;
        const index = self.job.account_index;
        const refresh = self.job.kind == .refresh;
        self.cancelJob();
        if (refresh) {
            self.sync[index].state = if (self.sync[index].cache_ready) .cached else .failed;
            self.sync[index].error_len = 0;
        }
    }
    fn clearSearch(self: *App) !bool {
        if (self.query.value().len == 0) return false;
        try self.query.set(self.allocator, "");
        self.query_scope = .cache;
        self.input_query_scope = .cache;
        try self.cursor.set(self.allocator, "");
        self.clearHistory();
        self.generation +%= 1;
        if (self.search_saved_valid and same(self.search_saved_account.value(), self.account())) {
            self.folder = self.search_saved_folder;
            try self.custom_label.set(self.allocator, self.search_saved_label.value());
            self.selected = self.search_saved_selected;
            self.top = self.search_saved_top;
            self.focus = self.search_saved_focus;
            self.expanded = self.search_saved_expanded;
            try self.restore_message.set(self.allocator, self.search_saved_message.value());
            self.restore_reader_scroll = self.search_saved_scroll;
            self.restore_reader_thread = self.search_saved_thread;
            self.search_restore_pending = true;
        } else {
            self.selected = 0;
            self.top = 0;
        }
        self.search_saved_valid = false;
        return true;
    }
    fn browseBack(self: *App) !void {
        if (self.expanded) {
            self.expanded = false;
            return;
        }
        if (self.focus != .list) {
            self.focus = .list;
            return;
        }
        if (try self.clearSearch()) {
            try self.reload();
            return;
        }
        if (self.job.future != null and !readOnlyJob(self.job.kind)) {
            self.say(true, "Operation pending · wait for its result", .{});
            return;
        }
        self.quit = true;
    }
    fn editContact(self: *App, contact: ?Value) !void {
        const value_in: Value = contact orelse .null;
        try self.contact_name.set(self.allocator, text(get(value_in, "name")));
        const emails = items(get(value_in, "emails"));
        try self.contact_email.set(self.allocator, if (emails.len > 0) text(get(emails[0], "address")) else "");
        try self.contact_id.set(self.allocator, text(get(value_in, "resourceName")));
        try self.contact_etag.set(self.allocator, text(get(value_in, "etag")));
        self.contact_field = 0;
        self.mode = .contact_edit;
        self.say(false, "Edit contact · Tab Field · Ctrl+S Save · Esc Cancel", .{});
    }
    fn saveContact(self: *App) !void {
        try recipients.validateAddress(self.contact_email.value());
        try recipients.validateHeader(self.contact_name.value());
        self.preemptReadOnly();
        const addresses = [_]types.Address{.{ .address = self.contact_email.value() }};
        try self.start(.contact_write, .{
            .account = self.account(),
            .cmd = "contacts.upsert",
            .contact = types.Contact{ .name = self.contact_name.value(), .resourceName = self.contact_id.value(), .etag = self.contact_etag.value(), .emails = &addresses },
            .expectedEtag = self.contact_etag.value(),
        });
    }
    fn move(self: *App, down: bool, amount: usize) !void {
        if (self.focus == .reader) {
            self.scrollReader(down, amount);
        } else if (self.focus == .navigation) {
            const total = self.accounts.len + folders.len + 1 + self.userLabelCount();
            self.navigation = if (down) @min(self.navigation +| amount, total - 1) else self.navigation -| amount;
        } else {
            if (self.pageLoadCurrent()) {
                if (down == self.page_loading_forward) return;
                self.preemptReadOnly();
            }
            const previous = self.selected;
            if (self.pending_page and down != self.pending_page_forward) self.pending_page = false;
            if (down and self.messages.len > 0 and previous +| amount >= self.messages.len and !self.drafts_list) {
                try self.scrollWindow(true);
                return;
            }
            if (!down and self.messages.len > 0 and amount > previous and !self.drafts_list) {
                try self.scrollWindow(false);
                return;
            }
            self.selected = if (down) @min(self.selected +| amount, self.messages.len -| 1) else self.selected -| amount;
            self.selection_generation +%= 1;
            try self.preview(false);
        }
    }
    fn adjacentMail(self: *App, next: bool) !void {
        if (self.drafts_list or self.messages.len == 0) return;
        const selected = layout.stepMessage(self.messages.len, self.selected, next);
        if (selected == self.selected) {
            self.focus = .reader;
            try self.scrollWindow(next);
            return;
        }
        self.selected = selected;
        self.selection_generation +%= 1;
        self.reader_scroll = 0;
        self.reader_card_pinned = false;
        self.focus = .reader;
        // Mail navigation shares cache-relative windows with the list; braces
        // remain the separate within-thread card navigation.
        try self.preview(false);
    }
    fn enter(self: *App) !void {
        if (self.focus == .navigation) {
            if (self.navigation < self.accounts.len) try self.chooseAccount(self.navigation) else if (self.navigation < self.accounts.len + folders.len) {
                self.rememberWorkingContext();
                try self.custom_label.set(self.allocator, "");
                self.folder = self.navigation - self.accounts.len;
                self.clearHistory();
                try self.cursor.set(self.allocator, "");
                self.selected = 0;
                self.top = 0;
                self.generation +%= 1;
                self.focus = .list;
                try self.reload();
            } else if (self.navigation == self.accounts.len + folders.len) {
                self.picker = false;
                try self.loadContacts("");
            } else if (self.userLabelIndex(self.navigation - self.accounts.len - folders.len - 1)) |index| {
                try self.chooseCustomLabel(index);
            }
        } else if (self.drafts_list) {
            if (self.messageId().len > 0) try self.start(.draft_read, .{ .account = self.account(), .cmd = "draft.read", .draftId = self.messageId() });
        } else {
            self.focus = .reader;
            try self.preview(true);
        }
    }
    fn activateContact(self: *App) !void {
        if (self.contacts_selected >= self.contacts.len or self.contacts_state == .denied) return;
        if (!self.picker) return self.editContact(self.contacts[self.contacts_selected]);
        const emails = items(get(self.contacts[self.contacts_selected], "emails"));
        if (emails.len > 0) {
            const address = text(get(emails[0], "address"));
            try recipients.validateAddress(address);
            const target = &self.compose.fields[if (self.compose.selected < 3) self.compose.selected else 0];
            target.cursor = target.bytes.items.len;
            if (target.value().len > 0) try target.insert(self.allocator, ", ", 16 * 1024);
            try target.insert(self.allocator, address, 16 * 1024);
            try self.composerChanged();
        }
        self.leaveContacts();
    }
    fn onMouse(self: *App, mouse: vaxis.Mouse) !void {
        self.action_notice = false;
        if (self.options.no_mouse or mouse.type != .press or mouse.mods.shift or mouse.mods.alt or mouse.mods.ctrl) return;
        const wheel: ?bool = switch (mouse.button) {
            .wheel_down => true,
            .wheel_up => false,
            .left => null,
            else => return,
        };
        if (self.job.future != null and !readOnlyJob(self.job.kind)) return;
        if (self.label_picker) {
            if (wheel) |down| {
                self.label_choice = if (down) @min(self.label_choice +| 3, self.visibleLabelCount() -| 1) else self.label_choice -| 3;
            } else if (self.mouse_hits.at(mouse.col, mouse.row)) |hit| {
                switch (hit.kind) {
                    .label_choice => self.label_choice = hit.index,
                    .label_add => try self.chooseLabel(false),
                    .label_remove => try self.chooseLabel(true),
                    else => {},
                }
            }
            return;
        }
        if (self.reader_overlay != .none) {
            if (wheel) |down| {
                if (self.reader_overlay == .links or self.reader_overlay == .attachments) {
                    for (0..3) |_| _ = try self.onReaderOverlayKey(.{ .codepoint = if (down) Key.down else Key.up });
                }
            } else if (self.mouse_hits.at(mouse.col, mouse.row)) |hit| {
                _ = try self.onReaderHit(hit);
            }
            return;
        }
        if (self.mode == .help) {
            if (wheel) |down| self.help_scroll = if (down) @min(self.help_scroll +| 3, self.help_lines -| self.help_height) else self.help_scroll -| 3;
            return;
        }
        // Confirmation overlays and input prompts keep their explicit keys.
        // A click can never submit, discard, trash, or leave a draft.
        if (self.mode != .browse and self.mode != .contacts and self.mode != .compose and self.mode != .contact_edit) return;
        const hit = self.mouse_hits.at(mouse.col, mouse.row) orelse return;
        // Wheel gestures belong to the pane under the pointer. Row gaps and
        // provisional mail must remain scrollable without becoming clickable.
        if (wheel) |down| switch (hit.kind) {
            .mail, .mail_scroll => {
                if (self.mode != .browse) return;
                self.focus = .list;
                return self.move(down, 3);
            },
            .reader, .reader_thread, .reader_link, .reader_attachment => {
                if (self.mode == .browse) self.focus = .reader else if (self.mode != .compose) return;
                self.scrollReader(down, 3);
                return;
            },
            else => {},
        };
        switch (hit.kind) {
            .mail_scroll => {},
            .label_choice, .label_add, .label_remove => {},
            .custom_label => {
                if (self.mode == .browse and wheel == null) try self.chooseCustomLabel(hit.index);
            },
            .reader_thread, .reader_link, .reader_attachment, .reader_picker, .reader_picker_save, .reader_picker_open => {
                if (wheel == null) _ = try self.onReaderHit(hit);
            },
            .account, .folder, .contacts => {
                if (self.mode != .browse or wheel != null) return;
                self.focus = .navigation;
                self.navigation = switch (hit.kind) {
                    .account => hit.index,
                    .folder => self.accounts.len + hit.index,
                    .contacts => self.accounts.len + folders.len,
                    else => unreachable,
                };
                try self.enter();
            },
            .mail => {
                if (self.mode != .browse or hit.index >= self.messages.len) return;
                self.focus = .list;
                if (wheel) |down| return self.move(down, 3);
                self.selected = hit.index;
                self.selection_generation +%= 1;
                try self.preview(false);
            },
            .reader => {
                if (self.mode == .browse) self.focus = .reader else if (self.mode != .compose) return;
                if (wheel) |down| self.scrollReader(down, 3);
            },
            .contact => {
                if (self.mode != .contacts or self.contacts_state == .denied or hit.index >= self.contacts.len) return;
                if (wheel) |down| {
                    self.contacts_selected = if (down) @min(self.contacts_selected +| 3, self.contacts.len -| 1) else self.contacts_selected -| 3;
                } else {
                    self.contacts_selected = hit.index;
                    try self.activateContact();
                }
            },
            .compose_field => {
                if (self.mode != .compose or self.compose.unknown_outcome or wheel != null or hit.index >= self.compose.fields.len) return;
                self.compose.selected = hit.index;
                self.compose.insert_mode = true;
            },
            .compose_from => {
                if (self.mode != .compose or wheel != null) return;
                try self.cycleComposeIdentity();
            },
            .compose_completion => {
                if (self.mode != .compose or !self.canEditAttachments() or wheel != null) return;
                try self.acceptCompletion(hit.index);
            },
            .compose_attachment_add => {
                if (self.mode != .compose or wheel != null) return;
                try self.promptAttachment();
            },
            .compose_attachment_remove => {
                if (self.mode != .compose or !self.canEditAttachments()) return;
                if (wheel) |down| {
                    self.compose.attachment_scroll = if (down) @min(self.compose.attachment_scroll +| 1, self.compose.attachments.len -| self.compose.attachment_height) else self.compose.attachment_scroll -| 1;
                } else try self.detachAttachment(hit.index);
            },
            .compose_attachment_scroll => {
                if (self.mode != .compose) return;
                if (wheel) |down| self.compose.attachment_scroll = if (down) @min(self.compose.attachment_scroll +| 1, self.compose.attachments.len -| self.compose.attachment_height) else self.compose.attachment_scroll -| 1;
            },
            .contact_field => {
                if (self.mode != .contact_edit or wheel != null or hit.index > 1) return;
                self.contact_field = hit.index;
            },
        }
    }
    fn runEditor(self: *App) !void {
        // Vaxis uses an integer-only fake TTY for screen unit tests. Owned-PTY
        // integration exercises the real takeover path with an actual Tty.
        if (@import("builtin").is_test) return error.EditorUnavailableInScreenTest;
        self.cancelAutosaveTimer();
        self.preemptReadOnly();
        if (self.job.future != null) return;
        self.loop.stop();
        const writer = self.tty.writer();
        try self.vx.resetState(writer);
        try writer.flush();
        try std.posix.tcsetattr(self.tty.fd.handle, .FLUSH, self.tty.termios);
        const result = editor.edit(self.io, self.allocator, self.environ, self.compose.fields[4].value(), self.tty.fd.handle, &self.cancellation);
        // Own readback before fallible terminal restoration, so even a restore
        // failure cannot leak its buffer or discard a valid editor change.
        // Transfer rather than copy: bounded allocator exhaustion cannot lose
        // a valid body whose private editor file has already been removed.
        if (result) |value_in| {
            const field = &self.compose.fields[4];
            field.bytes.deinit(self.allocator);
            field.bytes = .fromOwnedSlice(value_in.body);
            field.cursor = value_in.body.len;
            self.compose.body_scroll = 0;
            self.compose.revision +%= 1;
            self.compose.selected = 4;
            self.compose.insert_mode = false;
            self.editor_exit = value_in.exit_code;
        } else |_| {}
        // Restore even when the child cannot start, fails or is interrupted.
        _ = try vaxis.Tty.makeRaw(self.tty.fd.handle);
        try self.vx.enterAltScreen(writer);
        try self.vx.enableDetectedFeatures(writer);
        try setMouseReporting(self.vx, writer, !self.options.no_mouse);
        if (self.tty.getWinsize()) |size| try self.resize(size) else |_| {}
        self.vx.queueRefresh();
        try self.loop.start();
        const value_in = result catch |err| {
            self.say(true, "Editor: {s} · draft retained", .{@errorName(err)});
            return;
        };
        if (value_in.exit_code == 0) self.say(false, "Editor returned · draft retained · Ctrl+S Review send", .{}) else self.say(true, "Editor exited {d} · changed text retained · Ctrl+S Review send", .{value_in.exit_code});
        try self.saveDraft(.save);
        if (received_signal.load(.acquire) != 0 and self.job.future != null) {
            // A termination during the editor still saves the local draft.
            self.job.future.?.await(self.io);
            try self.finish();
        }
    }
    fn onComposeKey(self: *App, key: Key) !void {
        if (self.job.future != null and !readOnlyJob(self.job.kind)) {
            if (key.matches('q', .{}) or key.matches(Key.escape, .{})) self.say(false, "Draft operation pending · wait for its result", .{});
            return;
        }
        if (key.matches('s', .{ .ctrl = true })) return self.saveDraft(.save_review);
        if (self.compose.unknown_outcome and !(key.matches(Key.escape, .{}) or key.matches('q', .{}) or key.matches(':', .{}))) {
            self.markUnknown(.send);
            return;
        }
        if (!self.compose.insert_mode) {
            if (key.matches('d', .{ .ctrl = true }) or key.matches(Key.page_down, .{})) {
                self.scrollReader(true, @max(self.reader_height / 2, 1));
                return;
            }
            if (key.matches('u', .{ .ctrl = true }) or key.matches(Key.page_up, .{})) {
                self.scrollReader(false, @max(self.reader_height / 2, 1));
                return;
            }
            if (key.matches('L', .{}) or key.matches('l', .{ .shift = true })) {
                try self.openReaderLinks();
                return;
            }
            if (key.matches('B', .{}) or key.matches('b', .{ .shift = true })) {
                self.openReaderAttachments();
                return;
            }
        }
        if (key.matches(Key.escape, .{})) {
            if (self.compose.insert_mode) self.compose.insert_mode = false else try self.saveDraft(.save_back);
        } else if (key.matches(Key.tab, .{})) {
            self.compose.selected = (self.compose.selected + 1) % 5;
        } else if (key.matches(Key.tab, .{ .shift = true })) {
            self.compose.selected = (self.compose.selected + 4) % 5;
        } else if (self.compose.insert_mode) {
            const matches = self.composeCompletions();
            if (self.compose.selected < 3 and matches.len == 0 and (key.matches('n', .{ .ctrl = true }) or key.matches('p', .{ .ctrl = true }))) {
                self.say(false, "{s}", .{self.recipientHint()});
                return;
            }
            if (matches.len > 0 and (key.matches('n', .{ .ctrl = true }) or key.matches(Key.down, .{}))) {
                self.compose.completion_selected = (self.compose.completion_selected + 1) % matches.len;
            } else if (matches.len > 0 and (key.matches('p', .{ .ctrl = true }) or key.matches(Key.up, .{}))) {
                self.compose.completion_selected = (self.compose.completion_selected + matches.len - 1) % matches.len;
            } else if (matches.len > 0 and key.matches(Key.enter, .{})) {
                try self.acceptCompletion(@min(self.compose.completion_selected, matches.len - 1));
            } else {
                const field = &self.compose.fields[self.compose.selected];
                const before_len = field.value().len;
                try field.handleKey(self.allocator, key, self.compose.selected == 4, if (self.compose.selected == 4) types.Limits.body_bytes else 16 * 1024);
                if (field.value().len != before_len) try self.composerChanged();
            }
        } else if (key.matches('i', .{}) or key.matches(Key.enter, .{})) self.compose.insert_mode = true else if (key.matches('e', .{})) try self.runEditor() else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.compose.selected = (self.compose.selected + 1) % 5 else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.compose.selected = (self.compose.selected + 4) % 5 else if (key.matches('a', .{})) {
            self.picker = true;
            try self.loadContacts("");
        } else if (key.matches('f', .{})) {
            try self.cycleComposeIdentity();
        } else if (key.matches('A', .{}) or key.matches('a', .{ .shift = true })) {
            try self.promptAttachment();
        } else if (key.matches('q', .{})) try self.saveDraft(.save_back) else if (key.matches(':', .{})) {
            self.previous_mode = .compose;
            self.mode = .command;
            try self.input.set(self.allocator, "");
        }
    }
    fn onKey(self: *App, original_key: Key) !void {
        self.action_notice = false;
        var key = original_key;
        if (self.label_picker) {
            try self.onLabelPickerKey(key);
            return;
        }
        if (self.reader_overlay != .none) {
            if (self.paste and self.reader_overlay != .save_attachment and self.reader_overlay != .open_attachment) return;
            _ = try self.onReaderOverlayKey(key);
            return;
        }
        if (!self.paste) key = self.normalizeBrowseKey(key);
        try self.retryLocalCache();
        if (self.paste) {
            const changing = self.job.future != null and !readOnlyJob(self.job.kind);
            if ((self.mode == .compose and (changing or self.compose.unknown_outcome)) or (self.mode == .contact_edit and changing)) {
                self.say(true, "Paste not applied while saving or protecting an uncertain draft", .{});
                return;
            }
            const field: ?*Field = switch (self.mode) {
                .compose => &self.compose.fields[self.compose.selected],
                .search, .command, .labels, .attachment => &self.input,
                .contact_edit => if (self.contact_field == 0) &self.contact_name else &self.contact_email,
                else => null,
            };
            if (field) |input_field| {
                const multiline = self.mode == .compose and self.compose.selected == 4;
                const limit = if (multiline) types.Limits.body_bytes else 16 * 1024;
                if (key.text) |raw| {
                    const cleaned = try safe(self.frame.allocator(), raw, multiline);
                    try input_field.insert(self.allocator, cleaned, limit);
                } else if (key.matches(Key.enter, .{})) try input_field.insert(self.allocator, if (multiline) "\n" else " ", limit) else if (key.matches(Key.tab, .{})) try input_field.insert(self.allocator, "    ", limit);
                if (self.mode == .compose) try self.composerChanged();
            }
            return;
        }
        if (self.mode == .help) {
            if (key.matches('q', .{}) or key.matches('?', .{}) or key.matches(Key.escape, .{})) self.mode = backMode(.help, self.previous_mode, self.picker) else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.help_scroll +|= 1 else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.help_scroll -|= 1 else if (key.matches(Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) self.help_scroll +|= @max(self.help_height / 2, 1) else if (key.matches(Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) self.help_scroll -|= @max(self.help_height / 2, 1) else if (key.matches(Key.home, .{})) self.help_scroll = 0 else if (key.matches(Key.end, .{}) or key.matches('G', .{}) or key.matches('g', .{ .shift = true })) self.help_scroll = self.help_lines -| self.help_height;
            return;
        }
        if (key.matches('c', .{ .ctrl = true })) {
            if (self.job.future != null) {
                const kind = self.job.kind;
                const index = self.job.account_index;
                const contacts_waiting = self.mode == .contacts and self.pending_contacts;
                self.cancelJob();
                if (kind == .send or kind == .invitation) self.markUnknown(kind) else {
                    if (kind == .refresh) {
                        self.sync[index].state = if (self.sync[index].cache_ready) .cached else .failed;
                        self.sync[index].error_len = 0;
                    }
                    self.say(false, "Operation canceled · retained data kept", .{});
                    if (contacts_waiting and readOnlyJob(kind)) {
                        self.pending_contacts = true;
                        try self.dispatchPending();
                    } else if (kind == .contacts) self.contacts_state = if (self.contacts_cache_ready) .cached else .failed;
                }
            } else if (self.mode == .compose or self.mode == .review) try self.saveDraft(.save_back) else self.quit = true;
            return;
        }
        if (key.matches('l', .{ .ctrl = true })) {
            self.reloadTheme();
            self.vx.queueRefresh();
            return;
        }
        if (key.matches('?', .{}) and (self.mode == .contacts or (self.mode == .compose and !self.compose.insert_mode))) {
            self.previous_mode = self.mode;
            self.mode = .help;
            self.help_scroll = 0;
            return;
        }
        if (self.mode == .compose) return self.onComposeKey(key);
        if (self.mode == .review) {
            if (key.matches(Key.escape, .{}) or key.matches('q', .{}) or key.matches('n', .{})) self.mode = backMode(.review, self.previous_mode, self.picker) else if (key.matches('y', .{}) and self.job.future == null) try self.sendDraft() else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.reader_scroll +|= 1 else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.reader_scroll -|= 1 else if (key.matches(Key.page_down, .{})) self.reader_scroll +|= self.vx.window().height / 2 else if (key.matches(Key.page_up, .{})) self.reader_scroll -|= self.vx.window().height / 2;
            return;
        }
        if (self.mode == .trash_confirm) {
            if (key.matches(Key.escape, .{}) or key.matches('n', .{}) or key.matches('q', .{})) self.mode = backMode(.trash_confirm, self.previous_mode, self.picker) else if (key.matches('y', .{})) {
                try self.batchMail("trash", null, null, null, null);
                self.mode = .browse;
            }
            return;
        }
        if (self.mode == .invitation) {
            if (self.job.future != null) return;
            if (key.matches(Key.escape, .{}) or key.matches('q', .{})) self.mode = backMode(.invitation, self.previous_mode, self.picker) else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.invitation_scroll +|= 1 else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.invitation_scroll -|= 1 else if (key.matches(Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) self.invitation_scroll +|= @max(self.invitation_height / 2, 1) else if (key.matches(Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) self.invitation_scroll -|= @max(self.invitation_height / 2, 1) else if (key.matches(Key.home, .{})) self.invitation_scroll = 0 else if (key.matches(Key.end, .{}) or key.matches('G', .{}) or key.matches('g', .{ .shift = true })) self.invitation_scroll = self.invitation_lines -| self.invitation_height else {
                const status = if (key.matches('a', .{})) "accepted" else if (key.matches('t', .{})) "tentative" else if (key.matches('d', .{})) "declined" else return;
                if (!self.invitation_confirm_ready) {
                    self.say(true, "Resize to review RSVP identity before confirmation", .{});
                    return;
                }
                if (self.invitation_unknown and same(self.invitation_account.value(), self.invitation_inspected_account.value()) and same(self.invitation_message_id.value(), self.invitation_inspected_id.value())) {
                    self.markUnknown(.invitation);
                    return;
                }
                const id = try self.operationId(self.allocator);
                defer self.allocator.free(id);
                try self.invitation_operation_id.set(self.allocator, id);
                try self.invitation_operation_error.set(self.allocator, "");
                try self.invitation_message_id.set(self.allocator, self.invitation_inspected_id.value());
                try self.invitation_account.set(self.allocator, self.invitation_inspected_account.value());
                self.invitation_unknown = false;
                try self.start(.invitation, .{ .account = self.invitation_inspected_account.value(), .cmd = "invitation.reply", .messageId = self.invitation_inspected_id.value(), .status = status, .operationId = id });
            }
            return;
        }
        if (self.mode == .contact_edit) {
            if (key.matches(Key.escape, .{})) {
                self.mode = backMode(.contact_edit, self.previous_mode, self.picker);
                return;
            }
            if (self.job.future != null and !readOnlyJob(self.job.kind)) return;
            // Contact name/email fields are always text insertion: q is data.
            if (key.matches('s', .{ .ctrl = true })) try self.saveContact() else if (key.matches(Key.tab, .{})) self.contact_field = 1 - self.contact_field else try (if (self.contact_field == 0) &self.contact_name else &self.contact_email).handleKey(self.allocator, key, false, 4096);
            return;
        }
        if (self.mode == .attachment and key.matches(Key.tab, .{})) return self.completePath(&self.input, false);
        if (self.mode == .attachment and key.matches(Key.tab, .{ .shift = true })) return self.completePath(&self.input, true);
        if (self.mode == .attachment and key.matches(Key.escape, .{}) and self.path_candidates.candidates.len > 1 and self.path_candidates.active(self.input.value())) {
            self.path_candidates.reset();
            return;
        }
        if (self.mode == .attachment and key.matches('u', .{ .ctrl = true })) {
            self.path_candidates.reset();
            return self.input.set(self.allocator, "");
        }
        if (self.mode == .search or self.mode == .command or self.mode == .labels or self.mode == .attachment) {
            if (key.matches(Key.escape, .{})) self.mode = self.previous_mode else if (key.matches(Key.enter, .{})) {
                const previous_mode = self.previous_mode;
                if (self.mode == .attachment) {
                    try self.attachFile(self.input.value());
                } else if (self.mode == .command) {
                    if (same(self.input.value(), "undo") and previous_mode == .browse) {
                        try self.undoMail();
                    } else if (try self.onReaderCommand(self.input.value())) {} else if (same(self.input.value(), "layout right")) {
                        self.setReaderLayout(.right);
                    } else if (same(self.input.value(), "layout below")) {
                        self.setReaderLayout(.below);
                    } else if (std.mem.startsWith(u8, self.input.value(), "save-attachment ") or std.mem.startsWith(u8, self.input.value(), "save-attachment\t")) {
                        try self.saveIncomingAttachment(self.input.value()[16..]);
                    } else if (same(self.input.value(), "receipt") and previous_mode == .compose) {
                        try self.inspectDraftOperations();
                    } else if (same(self.input.value(), "send") and previous_mode == .compose) try self.saveDraft(.save_review) else if (std.mem.startsWith(u8, self.input.value(), "detach ") and previous_mode == .compose) {
                        const number = try std.fmt.parseInt(usize, std.mem.trim(u8, self.input.value()[7..], " \t"), 10);
                        if (number == 0) return error.InvalidAttachment;
                        try self.detachAttachment(number - 1);
                    } else if (same(self.input.value(), "q")) {
                        self.mode = previous_mode;
                        if (previous_mode == .compose) try self.saveDraft(.save_back) else if (previous_mode == .contacts) self.leaveContacts() else {
                            self.mode = .browse;
                            try self.browseBack();
                        }
                    } else self.say(true, "Commands: :layout right|below; :save-attachment NUMBER /path; :send; :detach NUMBER; :q", .{});
                    if (self.mode == .command) self.mode = previous_mode;
                } else if (self.mode == .labels) {
                    const raw_label = std.mem.trim(u8, self.input.value(), " \t");
                    if (raw_label.len == 0 or (raw_label.len == 1 and raw_label[0] == '-')) return error.InvalidLabel;
                    const remove = raw_label[0] == '-';
                    const labels = [_][]const u8{if (remove) raw_label[1..] else raw_label};
                    if (remove) try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.mark", .messageId = self.messageId(), .removeLabels = &labels }) else try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.mark", .messageId = self.messageId(), .addLabels = &labels });
                    self.mode = .browse;
                } else if (previous_mode == .contacts) try self.loadContacts(self.input.value()) else {
                    const retain_cached_view = self.view_ready and self.input_query_scope == .cache and cache_query.needsBody(self.input.value());
                    try self.query.set(self.allocator, self.input.value());
                    self.query_scope = self.input_query_scope;
                    self.clearHistory();
                    try self.cursor.set(self.allocator, "");
                    self.generation +%= 1;
                    if (!retain_cached_view) {
                        self.selected = 0;
                        self.top = 0;
                    }
                    self.focus = .list;
                    self.expanded = false;
                    self.mode = .browse;
                    try self.reload();
                }
            } else try self.input.handleKey(self.allocator, key, false, 4096);
            return;
        }
        if (self.mode == .contacts) {
            if (key.matches(Key.escape, .{}) or key.matches('q', .{})) self.leaveContacts() else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.contacts_selected = @min(self.contacts_selected +| 1, self.contacts.len -| 1) else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.contacts_selected -|= 1 else if (key.matches(Key.home, .{})) self.contacts_selected = 0 else if (key.matches(Key.end, .{})) self.contacts_selected = self.contacts.len -| 1 else if (key.matches('d', .{ .ctrl = true }) or key.matches(Key.page_down, .{})) self.contacts_selected = @min(self.contacts_selected +| 8, self.contacts.len -| 1) else if (key.matches('u', .{ .ctrl = true }) or key.matches(Key.page_up, .{})) self.contacts_selected -|= 8 else if (key.matches('/', .{})) {
                self.previous_mode = .contacts;
                self.mode = .search;
                try self.input.set(self.allocator, "");
            } else if (key.matches('n', .{}) and self.contacts_state != .denied) try self.editContact(null) else if (key.matches('e', .{}) and self.contacts_selected < self.contacts.len and self.contacts_state != .denied) try self.editContact(self.contacts[self.contacts_selected]) else if (key.matches(Key.enter, .{}) and self.contacts_selected < self.contacts.len) try self.activateContact();
            return;
        }
        if (self.mode == .browse and key.matches('v', .{})) {
            self.setReaderLayout(if (self.reader_layout == .right) .below else .right);
            return;
        }
        if (self.mode == .browse and (self.focus == .reader or self.expanded)) {
            if (key.matches('J', .{}) or key.matches('j', .{ .shift = true })) return self.adjacentMail(true);
            if (key.matches('K', .{}) or key.matches('k', .{ .shift = true })) return self.adjacentMail(false);
        }
        const now = Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (self.g_pending and now - self.g_at > 750) self.g_pending = false;
        if (try self.onReaderKey(key)) return;
        if (try self.onMailControls(key)) return;
        if (key.matches('f', .{}) or key.matches('F', .{}) or key.matches('f', .{ .shift = true })) return self.composeForward();
        if (key.matches('g', .{})) {
            if (self.g_pending) {
                self.g_pending = false;
                self.selected = 0;
                self.top = 0;
                self.reader_scroll = 0;
                if (self.focus == .list) {
                    self.selection_generation +%= 1;
                    try self.preview(false);
                }
            } else {
                self.g_pending = true;
                self.g_at = now;
            }
            return;
        }
        self.g_pending = false;
        if (key.matches('j', .{}) or key.matches(Key.down, .{})) try self.move(true, 1) else if (key.matches('k', .{}) or key.matches(Key.up, .{})) try self.move(false, 1) else if (key.matches('d', .{ .ctrl = true }) or key.matches(Key.page_down, .{})) try self.move(true, @max(self.vx.window().height / 2, 1)) else if (key.matches('u', .{ .ctrl = true }) or key.matches(Key.page_up, .{})) try self.move(false, @max(self.vx.window().height / 2, 1)) else if (key.matches('h', .{}) or key.matches(Key.left, .{})) self.focus = switch (self.focus) {
            .navigation => .navigation,
            .list => .navigation,
            .reader => .list,
        } else if (key.matches(Key.tab, .{ .shift = true })) self.focus = switch (self.focus) {
            .navigation => .reader,
            .list => .navigation,
            .reader => .list,
        } else if (key.matches('l', .{}) or key.matches(Key.right, .{}) or key.matches(Key.tab, .{})) self.focus = switch (self.focus) {
            .navigation => .list,
            .list => .reader,
            .reader => .navigation,
        } else if (key.matches(Key.enter, .{})) try self.enter() else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true }) or key.matches(Key.end, .{})) {
            if (self.focus == .reader) self.reader_scroll = readerEnd(self.reader_lines, self.reader_height) else {
                self.selected = self.messages.len -| 1;
                self.selection_generation +%= 1;
                try self.preview(false);
            }
        } else if (key.matches(Key.home, .{})) {
            self.selected = 0;
            self.top = 0;
            self.reader_scroll = 0;
            self.selection_generation +%= 1;
            try self.preview(false);
        } else if (key.matches('[', .{})) try self.page(false) else if (key.matches(']', .{})) try self.page(true) else if (key.matches('/', .{})) {
            try self.beginSearch(.cache);
        } else if (key.matches('\\', .{})) {
            try self.beginSearch(.server);
        } else if (key.matches(':', .{})) {
            self.previous_mode = .browse;
            self.mode = .command;
            try self.input.set(self.allocator, "");
        } else if (key.matches('c', .{})) try self.composeNew(null) else if (key.matches('r', .{})) try self.composeNew(false) else if (key.matches('R', .{}) or key.matches('r', .{ .shift = true })) try self.composeNew(true) else if (key.matches('a', .{})) {
            self.picker = false;
            try self.loadContacts("");
        } else if (key.matches('z', .{})) {
            self.expanded = !self.expanded;
            self.focus = .reader;
        } else if (key.matches('?', .{})) {
            self.previous_mode = self.mode;
            self.mode = .help;
            self.help_scroll = 0;
        } else if (key.matches('r', .{ .ctrl = true })) {
            if (self.cacheSearch()) try self.refreshMailbox() else try self.reload();
        } else if (key.matches('x', .{}) and self.messageId().len > 0) try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.archive", .messageId = self.messageId() }) else if ((key.matches('D', .{}) or key.matches('d', .{ .shift = true })) and self.messageId().len > 0) self.mode = .trash_confirm else if (key.matches('U', .{}) or key.matches('u', .{ .shift = true })) try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.restore", .messageId = self.messageId() }) else if (key.matches('s', .{}) and self.messageId().len > 0) {
            var starred = false;
            for (items(get(self.selectedMessage().?, "labels"))) |label| if (same(text(label), "STARRED")) {
                starred = true;
                break;
            };
            try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.mark", .messageId = self.messageId(), .starred = !starred });
        } else if (key.matches('u', .{}) and self.messageId().len > 0) try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.mark", .messageId = self.messageId(), .unread = !truth(get(self.selectedMessage().?, "unread")) }) else if (key.matches('m', .{}) and self.messageId().len > 0) {
            self.previous_mode = .browse;
            self.mode = .labels;
            try self.input.set(self.allocator, "");
        } else if ((key.matches('I', .{}) or key.matches('i', .{ .shift = true })) and self.messageId().len > 0) try self.reviewInvitation() else if (key.matches('o', .{})) try self.start(.open, .{ .account = self.account(), .cmd = "mail.open", .messageId = self.messageId() }) else if (key.matches('q', .{}) or key.matches(Key.escape, .{})) {
            try self.browseBack();
        } else for (0..self.accounts.len) |index| if (key.matches(@intCast('1' + index), .{})) {
            try self.chooseAccount(index);
            break;
        };
    }

    fn style(self: *App, color: Tone) vaxis.Style {
        const bold = color == .subject or color == .accent or color == .selected or color == .fetching or color == .current or color == .offline;
        if (self.mono) return .{ .reverse = color == .selected, .bold = bold or color == .warning };
        return .{
            .fg = .{ .rgb = switch (color) {
                .text, .subject, .selected => self.palette.foreground,
                .muted => self.palette.muted,
                .accent => self.palette.accent,
                .warning => self.palette.red,
                .sender, .fetching => self.palette.cyan,
                .current => self.palette.green,
                .offline => self.palette.yellow,
            } },
            .bg = .{ .rgb = if (color == .selected) self.palette.selection else self.palette.background },
            .bold = bold,
        };
    }
    fn line(self: *App, win: vaxis.Window, row: usize, raw: []const u8, color: Tone) !void {
        if (row >= win.height or win.width == 0) return;
        const child = win.child(.{ .y_off = @intCast(row), .height = 1 });
        if (color == .selected) child.fill(.{ .style = self.style(.selected) });
        _ = child.printSegment(.{ .text = try safe(self.frame.allocator(), raw, false), .style = self.style(color) }, .{ .wrap = .none });
    }
    fn mouseArea(self: *App, win: vaxis.Window, kind: layout.HitKind, index: usize) void {
        if (win.x_off < 0 or win.y_off < 0) return;
        self.mouse_hits.add(.{ .x = @intCast(win.x_off), .y = @intCast(win.y_off), .width = win.width, .height = win.height }, kind, index);
    }
    fn mouseRows(self: *App, win: vaxis.Window, row: usize, height: u16, kind: layout.HitKind, index: usize) void {
        if (row >= win.height) return;
        self.mouseArea(win.child(.{ .y_off = @intCast(row), .height = height }), kind, index);
    }
    fn editLine(self: *App, win: vaxis.Window, row: usize, name: []const u8, field: *const Field, editing: bool, color: Tone) !void {
        if (!editing) return self.line(win, row, try std.fmt.allocPrint(self.frame.allocator(), "{s}: {s}", .{ name, field.value() }), color);
        if (row >= win.height or win.width == 0) return;
        const child = win.child(.{ .y_off = @intCast(row), .height = 1 });
        if (color == .selected) child.fill(.{ .style = self.style(color) });
        const label = try std.fmt.allocPrint(self.frame.allocator(), "{s}: ", .{name});
        _ = child.printSegment(.{ .text = label, .style = self.style(color) }, .{ .wrap = .none });
        const label_width: u16 = @intCast(@min(label.len, child.width));
        const content = child.child(.{ .x_off = label_width, .width = child.width - label_width });
        if (content.width == 0) return;
        const before = try safe(self.frame.allocator(), field.value()[0..field.cursor], false);
        const after = try safe(self.frame.allocator(), field.value()[field.cursor..], false);
        const viewport_start = horizontalStart(content, before, content.width -| 1);
        const shown = try std.fmt.allocPrint(self.frame.allocator(), "{s}▏{s}", .{ before[viewport_start..], after });
        _ = content.printSegment(.{ .text = shown, .style = self.style(color) }, .{ .wrap = .none });
    }
    fn panel(self: *App, win: vaxis.Window, x: u16, width: u16, title: []const u8, selected_panel: bool) vaxis.Window {
        const child = win.child(.{ .x_off = x, .width = width, .border = .{ .where = .all, .style = self.style(if (selected_panel) .accent else .muted) } });
        _ = win.child(.{ .x_off = x +| 2, .width = width -| 4, .height = 1 }).printSegment(.{ .text = title, .style = self.style(if (selected_panel) .accent else .muted) }, .{ .wrap = .none });
        return child.child(.{ .x_off = 1, .width = child.width -| 2 });
    }
    fn pane(self: *App, win: vaxis.Window, rect: layout.Rect, title: []const u8, selected_panel: bool) vaxis.Window {
        const area = win.child(.{ .x_off = rect.x, .y_off = rect.y, .width = rect.width, .height = rect.height });
        return self.panel(area, 0, rect.width, title, selected_panel);
    }
    fn fitLine(self: *App, win: vaxis.Window, raw: []const u8, columns: u16) ![]const u8 {
        if (columns == 0) return "";
        const clean = try safe(self.frame.allocator(), raw, false);
        var iterator = vaxis.unicode.graphemeIterator(clean);
        var width: usize = 0;
        var end: usize = 0;
        while (iterator.next()) |gr| {
            width += @max(win.gwidth(gr.bytes(clean)), 1);
            if (width > columns) break;
            end = gr.start + gr.len;
        }
        if (end == clean.len) return clean;
        iterator = vaxis.unicode.graphemeIterator(clean);
        width = 0;
        end = 0;
        while (iterator.next()) |gr| {
            width += @max(win.gwidth(gr.bytes(clean)), 1);
            if (width >= columns) break;
            end = gr.start + gr.len;
        }
        return std.fmt.allocPrint(self.frame.allocator(), "{s}…", .{clean[0..end]});
    }
    fn listStyle(self: *App, tone: Tone, selected: bool) vaxis.Style {
        var result = self.style(tone);
        if (selected) {
            if (self.mono) result.reverse = true else result.bg = .{ .rgb = self.palette.selection };
        }
        return result;
    }
    fn navigationDraw(self: *App, win: vaxis.Window) !void {
        const navigation_hit_start = self.mouse_hits.count;
        try self.line(win, 0, "ACCOUNTS", .muted);
        var row: usize = 1;
        for (self.accounts, 0..) |account_value, index| {
            if (row >= win.height or win.width <= 2) break;
            const address = try safe(self.frame.allocator(), text(get(account_value, "address")), false);
            const tone: Tone = if (self.focus == .navigation and self.navigation == index) .selected else if (index == self.account_index) .accent else .text;
            const address_win = win.child(.{ .x_off = 2, .y_off = @intCast(row), .width = win.width - 2 });
            // Continuation lines align with the address, leaving its selection
            // marker on the first line. A full final line occupies one row;
            // the print cursor's next-row position is not an extra blank row.
            const actual_rows = positionAfter(address_win, address).row + 1;
            const visible_rows: u16 = @intCast(@min(actual_rows, win.height - row));
            const account_win = win.child(.{ .y_off = @intCast(row), .height = visible_rows });
            if (tone == .selected) account_win.fill(.{ .style = self.style(tone) });
            try self.line(account_win, 0, if (index == self.account_index) "> " else "  ", tone);
            _ = try self.flowTone(address_win.child(.{ .height = visible_rows }), address, 0, 0, tone);
            self.mouseRows(win, row, visible_rows, .account, index);
            row += actual_rows;
        }
        row += 1;
        try self.line(win, row, "MAILBOXES", .muted);
        row += 1;
        for (folders, 0..) |name, index| {
            const value_in = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (index == self.folder) "> " else "  ", name });
            try self.line(win, row + index, value_in, if (self.focus == .navigation and self.navigation == self.accounts.len + index) .selected else if (index == self.folder) .accent else .text);
            self.mouseRows(win, row + index, 1, .folder, index);
        }
        try self.line(win, row + folders.len + 1, "Contacts", if (self.focus == .navigation and self.navigation == self.accounts.len + folders.len) .selected else .text);
        self.mouseRows(win, row + folders.len + 1, 1, .contacts, 0);
        var label_row = row + folders.len + 3;
        if (label_row + 2 >= win.height and self.focus == .navigation and self.navigation > self.accounts.len + folders.len) {
            win.fill(.{ .style = self.style(.text) });
            self.mouse_hits.count = navigation_hit_start;
            label_row = 0;
        }
        if (label_row < win.height and self.userLabelCount() > 0) {
            try self.line(win, label_row, "LABELS", .muted);
            const visible: usize = win.height - label_row - 1;
            const navigation_start = self.accounts.len + folders.len + 1;
            const focused_label = self.navigation -| navigation_start;
            const first = if (focused_label >= visible and visible > 0) focused_label - visible + 1 else 0;
            for (first..@min(first + visible, self.userLabelCount())) |choice| {
                const index = self.userLabelIndex(choice) orelse continue;
                const label_value = self.labels[index];
                const label_active = same(self.custom_label.value(), text(get(label_value, "id")));
                try self.line(win, label_row + 1 + choice - first, try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (label_active) "> " else "  ", text(get(label_value, "name")) }), if (self.focus == .navigation and self.navigation == navigation_start + choice) .selected else if (label_active) .accent else .text);
                self.mouseRows(win, label_row + 1 + choice - first, 1, .custom_label, index);
            }
        }
    }
    fn navigationWidth(self: *App, win: vaxis.Window) !u16 {
        var widest: u16 = 26;
        for (self.accounts) |account_value| {
            const clean = try safe(self.frame.allocator(), text(get(account_value, "address")), false);
            var columns: u16 = 6; // Selected prefix plus panel border and padding.
            var iterator = vaxis.unicode.graphemeIterator(clean);
            while (iterator.next()) |gr| columns +|= @max(win.gwidth(gr.bytes(clean)), 1);
            widest = @max(widest, columns);
        }
        return @min(widest, 36);
    }
    fn drawMailRow(self: *App, win: vaxis.Window, row: usize, index: usize) !void {
        if (row >= win.height or index >= self.messages.len) return;
        const value_in = self.messages[index];
        const sender = get(value_in, "from");
        const sender_text = if (text(get(sender, "name")).len > 0) text(get(sender, "name")) else text(get(sender, "address"));
        const selected = index == self.selected;
        const item = win.child(.{ .y_off = @intCast(row), .height = @min(@as(u16, 2), win.height -| @as(u16, @intCast(row))) });
        self.mouseArea(item, .mail, index);
        item.fill(.{ .style = self.style(if (selected) .selected else .text) });
        const stamp = try timestamp(self.frame.allocator(), &self.zone, get(value_in, "receivedAt"));
        const compact = if (stamp.len >= 16) stamp[5..16] else stamp;
        const date_width: u16 = if (win.width >= 48) @intCast(compact.len) else 0;
        const subject_width = win.width -| date_width -| @as(u16, if (date_width > 0) 1 else 0);
        const subject = text(get(value_in, "subject"));
        const subject_text = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (self.mail_selection.contains(text(get(value_in, "id")))) "[x] " else if (truth(get(value_in, "unread"))) "● " else "  ", if (subject.len == 0) "(no subject)" else subject });
        _ = item.child(.{ .height = 1, .width = subject_width }).printSegment(.{ .text = try self.fitLine(win, subject_text, subject_width), .style = self.listStyle(.subject, selected) }, .{ .wrap = .none });
        if (date_width > 0) _ = item.child(.{ .x_off = win.width - date_width, .height = 1, .width = date_width }).printSegment(.{ .text = compact, .style = self.listStyle(.muted, selected) }, .{ .wrap = .none });
        if (item.height < 2) return;
        const sender_limit = @min(win.width / 2, 28);
        const shown_sender = try self.fitLine(win, if (self.drafts_list) "Draft" else sender_text, sender_limit);
        const sender_line = item.child(.{ .y_off = 1, .height = 1 });
        const printed = sender_line.printSegment(.{ .text = shown_sender, .style = self.listStyle(.sender, selected) }, .{ .wrap = .none });
        var excerpt = self.searchExcerpt(value_in);
        var waiting = selected and self.loadingActive() and (self.job.kind == .read or self.job.kind == .thread);
        if (self.loadingActive()) for (&self.job.loading_rows.slots) |*slot| {
            const received = slot.metadata() orelse continue;
            if (!same(received.id.value(), text(get(value_in, "id")))) continue;
            switch (slot.bodyState()) {
                1 => {
                    if (slot.body_excerpt.value().len > 0) excerpt = slot.body_excerpt.value();
                    waiting = false;
                },
                0 => waiting = !truth(get(value_in, "bodyCached")),
                else => {},
            }
            break;
        };
        if (waiting) excerpt = try std.fmt.allocPrint(self.frame.allocator(), "Body pending {s}", .{loading.frame(self.loading_frame)});
        if (printed.col +| 3 < sender_line.width) {
            const snippet = try self.fitLine(win, excerpt, sender_line.width - printed.col - 3);
            _ = sender_line.child(.{ .x_off = printed.col }).printSegment(.{ .text = try std.fmt.allocPrint(self.frame.allocator(), " — {s}", .{snippet}), .style = self.listStyle(if (waiting) .fetching else .muted, selected) }, .{ .wrap = .none });
        }
    }
    fn drawIncomingWindow(self: *App, win: vaxis.Window) !bool {
        if (!self.loadingActive() or (self.job.kind != .list and self.job.kind != .refresh)) return false;
        if (self.messages.len > 0 and !self.pageLoadCurrent()) return false;
        var row: usize = 0;
        if (self.messages.len > 0) {
            // Keep the old focused row and reader until the replacement is
            // committed. Provisional incoming IDs have no interactive hit.
            try self.drawMailRow(win, 0, @min(self.selected, self.messages.len - 1));
            row = 3;
        }
        const reported = self.job.progress.snapshot();
        const known = if (self.job.loading_rows.count() > 0) self.job.loading_rows.count() else if (reported.phase == .metadata) @min(reported.total, loading.window) else 0;
        const visible = mailRowCapacity(@as(usize, win.height) -| row);
        const count = if (known > 0) @min(known, visible) else @min(@as(usize, 3), visible);
        for (0..count) |index| {
            const current = row + index * 3;
            if (current >= win.height) break;
            const item = win.child(.{ .y_off = @intCast(current), .height = @min(@as(u16, 2), win.height -| @as(u16, @intCast(current))) });
            item.fill(.{ .style = self.style(.text) });
            if (self.job.loading_rows.slots[index].metadata()) |received| {
                const subject = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (received.unread) @as([]const u8, "● ") else "  ", if (received.subject.value().len > 0) received.subject.value() else "(no subject)" });
                const stamp = try timestamp(self.frame.allocator(), &self.zone, .{ .integer = received.received_at });
                const compact = if (stamp.len >= 16) stamp[5..16] else stamp;
                const date_width: u16 = if (item.width >= 48) @intCast(compact.len) else 0;
                const subject_width = item.width -| date_width -| @as(u16, if (date_width > 0) 1 else 0);
                _ = item.child(.{ .height = 1, .width = subject_width }).printSegment(.{ .text = try self.fitLine(item, subject, subject_width), .style = self.style(.subject) }, .{ .wrap = .none });
                if (date_width > 0) _ = item.child(.{ .x_off = item.width - date_width, .height = 1, .width = date_width }).printSegment(.{ .text = compact, .style = self.style(.muted) }, .{ .wrap = .none });
                const slot = &self.job.loading_rows.slots[index];
                const sender = if (received.from_name.value().len > 0) received.from_name.value() else received.from_address.value();
                const detail = if (slot.bodyState() == 1) slot.body_excerpt.value() else received.snippet.value();
                const second = try std.fmt.allocPrint(self.frame.allocator(), "{s} — {s}{s}{s}", .{ sender, detail, if (slot.bodyState() == 0) " · " else "", if (slot.bodyState() == 0) loading.frame(self.loading_frame) else "" });
                try self.line(item, 1, try self.fitLine(item, second, item.width), if (slot.bodyState() == 1) .muted else .fetching);
            } else {
                try self.line(item, 0, try std.fmt.allocPrint(self.frame.allocator(), " {s} Fetching metadata…", .{loading.frame(self.loading_frame)}), .fetching);
                try self.line(item, 1, "   ▱▱▱▱▱▱▱▱▱▱▱▱  ▱▱▱▱▱▱▱▱", .muted);
            }
        }
        return true;
    }
    fn listDraw(self: *App, win: vaxis.Window) !void {
        self.mouseArea(win, .mail_scroll, 0);
        if (try self.drawIncomingWindow(win)) return;
        const count = mailRowCapacity(win.height);
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + count) self.top = self.selected + 1 - count;
        if (self.messages.len == 0) {
            const state = self.sync[self.account_index].state;
            try self.line(win, 1, if (state == .fetching) "Fetching mail…" else if (self.job.future != null and self.drafts_list) "Loading drafts…" else if (state == .failed or self.warning) "Mail unavailable; see status below" else if (self.list_cached and self.list_partial) "No rows in cached subset" else "No matching messages", if (state == .fetching) .fetching else .muted);
            return;
        }
        var index = self.top;
        while (index < self.messages.len and index < self.top + count) : (index += 1) try self.drawMailRow(win, (index - self.top) * 3, index);
    }
    fn searchExcerpt(self: *App, message: Value) []const u8 {
        for (self.search_matches) |match_value| {
            if (same(text(get(match_value, "messageId")), text(get(message, "id"))) and same(text(get(match_value, "field")), "body")) return text(get(match_value, "excerpt"));
        }
        return text(get(message, "snippet"));
    }
    fn flow(self: *App, win: vaxis.Window, value_in: []const u8, offset: usize, base_row: usize) !usize {
        return self.flowTone(win, value_in, offset, base_row, .text);
    }
    fn flowTone(self: *App, win: vaxis.Window, value_in: []const u8, offset: usize, base_row: usize, tone: Tone) !usize {
        const clean = try safe(self.frame.allocator(), value_in, true);
        return self.flowClean(win, clean, offset, base_row, tone, .{});
    }
    fn caretPosition(self: *App, win: vaxis.Window, raw: []const u8, raw_cursor: usize) !TextPosition {
        const clean = try safe(self.frame.allocator(), raw, true);
        const prefix = try safe(self.frame.allocator(), raw[0..@min(raw_cursor, raw.len)], true);
        return text_layout.caret(clean, @min(prefix.len, clean.len), win.width, win.screen.width_method, .words);
    }
    fn flowCaret(self: *App, win: vaxis.Window, raw: []const u8, raw_cursor: usize, offset: usize) !usize {
        const clean = try safe(self.frame.allocator(), raw, true);
        const prefix = try safe(self.frame.allocator(), raw[0..@min(raw_cursor, raw.len)], true);
        return self.flowClean(win, clean, offset, 0, .text, .{ .marker_at = @min(prefix.len, clean.len) });
    }
    fn flowClean(self: *App, win: vaxis.Window, clean: []const u8, offset: usize, base_row: usize, tone: Tone, options: text_layout.Options) usize {
        if (win.width == 0) return base_row;
        const highlight = if (self.cacheSearch()) self.search_highlight.value() else "";
        var next_match = cache_query.find(clean, highlight);
        var layout_options = options;
        layout_options.base_row = base_row;
        var iterator = text_layout.Iterator.init(clean, win.width, win.screen.width_method, layout_options);
        while (iterator.next()) |glyph| {
            while (next_match) |match_at| {
                if (glyph.byte_offset < match_at + highlight.len) break;
                const after = match_at + highlight.len;
                next_match = if (cache_query.find(clean[after..], highlight)) |relative| after + relative else null;
            }
            var cell_style = self.style(if (glyph.marker) .accent else tone);
            if (!glyph.marker) if (next_match) |match_at| if (glyph.byte_offset >= match_at and glyph.byte_offset < match_at + highlight.len) {
                if (self.mono) cell_style.reverse = true else {
                    cell_style.bg = .{ .rgb = self.palette.yellow };
                    cell_style.fg = .{ .rgb = self.palette.background };
                }
            };
            if (glyph.position.row >= offset and glyph.position.row - offset < win.height and glyph.columns <= win.width) win.writeCell(glyph.position.column, @intCast(glyph.position.row - offset), .{ .char = .{ .grapheme = glyph.text, .width = @intCast(@min(glyph.columns, 255)) }, .style = cell_style });
        }
        return iterator.position.row + 1;
    }
    fn readerDraw(self: *App, outer: vaxis.Window) !void {
        self.mouseArea(outer, .reader, 0);
        const browsing = self.mode == .browse or (self.mode == .help and self.previous_mode == .browse) or (self.mode == .command and self.previous_mode == .browse);
        const toolbar_rows: u16 = if (browsing and self.focus != .reader and !self.expanded and outer.height >= 18 and outer.width >= 60) 1 else 0;
        const summary_rows: u16 = if (browsing and self.thread.len > 1 and outer.height >= 6) 1 else 0;
        if (toolbar_rows > 0) try self.line(outer, 0, try self.fitLine(outer, "J/K Mail · {/} Thread · t Fold · L Links · B Files", outer.width), .accent);
        const partial_rows: u16 = if (self.reader_partial and outer.height >= 14) 1 else 0;
        if (partial_rows > 0) try self.line(outer, toolbar_rows + summary_rows, "Cached thread · partial", .muted);
        const header_rows = toolbar_rows + summary_rows + partial_rows;
        const win = outer.child(.{ .y_off = header_rows, .height = outer.height -| header_rows });
        self.reader_height = win.height;
        // Measure the new body before clamping a restored scroll position.
        // clearReader resets the old line count, not the persisted position.
        if (self.thread.len == 0) {
            if (self.reader_cache_busy) {
                try self.line(win, 1, "Cache busy · local read queued", .muted);
                try self.line(win, 3, "Input or refresh completion retries locally", .muted);
            } else if (self.body_cache_miss) {
                const fetching = self.job.future != null and (self.job.kind == .read or self.job.kind == .thread);
                const refused = if (self.selectedMessage()) |message| bodyRefusal(message) else null;
                try self.line(win, 1, if (refused) |reason| try std.fmt.allocPrint(self.frame.allocator(), "Body unavailable · {s}", .{reason}) else if (fetching or self.pending_read) try std.fmt.allocPrint(self.frame.allocator(), "{s} {s}", .{ loading.frame(self.loading_frame), if (fetching) "Fetching mail body…" else "Mail body queued…" }) else "Body not cached · Enter fetches full mail", if (refused != null) .warning else if (fetching or self.pending_read) .fetching else .muted);
                if (self.selectedMessage()) |message| {
                    try self.line(win, 3, text(get(message, "subject")), .text);
                    if (refused != null) try self.line(win, 4, "Snippet only · o Open in Gmail", .muted);
                    _ = try self.flow(win, text(get(message, "snippet")), 0, 5);
                }
            } else try self.line(win, 1, if (self.sync[self.account_index].state == .fetching) "Fetching mail · cached bodies appear here" else "Select mail · Enter opens the thread", .muted);
            return;
        }
        const painted_scroll = self.reader_scroll;
        const body_hit_start = self.mouse_hits.count;
        self.reader_lines = try self.readerBodyDraw(win);
        if (self.reader_anchor_card) {
            self.reader_scroll = self.reader_card_rows[self.reader_card];
            self.reader_anchor_card = false;
        }
        const clamped = @min(self.reader_scroll, self.readerScrollEnd());
        self.reader_scroll = clamped;
        if (clamped != painted_scroll) {
            // A wider layout can reduce wrapping below the old scroll
            // position. Repaint the corrected viewport once in this frame;
            // never wait for another key or schedule a redraw loop.
            win.fill(.{ .style = self.style(.text) });
            self.mouse_hits.count = body_hit_start;
            self.reader_lines = try self.readerBodyDraw(win);
        }
        if (summary_rows > 0) {
            var unread: usize = 0;
            for (self.thread) |message| unread += @intFromBool(truth(get(message, "unread")));
            const earlier = if (self.reader_card > 0 and self.reader_scroll >= self.reader_card_rows[self.reader_card]) try std.fmt.allocPrint(self.frame.allocator(), " · ↑{d} earlier", .{self.reader_card}) else "";
            const summary = try std.fmt.allocPrint(self.frame.allocator(), "{d}/{d} mails · {d} unread{s} · {s}", .{ self.reader_card + 1, self.thread.len, unread, earlier, try self.readerProgressText() });
            try self.line(outer, toolbar_rows, try self.fitLine(outer, summary, outer.width), .muted);
        }
    }
    fn readerScrollEnd(self: *const App) usize {
        const end = readerEnd(self.reader_lines, self.reader_height);
        return if (self.reader_card_pinned and self.reader_card < self.thread.len) @max(end, self.reader_card_rows[self.reader_card]) else end;
    }
    fn scrollReader(self: *App, down: bool, amount: usize) void {
        self.reader_anchor_card = false;
        self.reader_card_pinned = false;
        self.reader_scroll = if (down) @min(self.reader_scroll +| amount, readerEnd(self.reader_lines, self.reader_height)) else self.reader_scroll -| amount;
    }
    fn readerProgressText(self: *App) ![]const u8 {
        const visible_end = @min(self.reader_scroll +| self.reader_height, self.reader_lines);
        const percent: usize = if (self.reader_lines == 0) 0 else @intCast(@min(@as(u128, 100), @divTrunc(@as(u128, visible_end) * 100, self.reader_lines)));
        return std.fmt.allocPrint(self.frame.allocator(), "{d}% · {d}–{d}/{d}", .{ percent, if (self.reader_lines == 0) @as(usize, 0) else self.reader_scroll + 1, visible_end, self.reader_lines });
    }
    fn readerMouseRows(self: *App, win: vaxis.Window, row: usize, height: usize, kind: layout.HitKind, index: usize) void {
        const first = @max(row, self.reader_scroll);
        const end = @min(row +| height, self.reader_scroll +| win.height);
        if (end <= first) return;
        self.mouseRows(win, first - self.reader_scroll, @intCast(end - first), kind, index);
    }
    fn readerBodyDraw(self: *App, win: vaxis.Window) !usize {
        var row: usize = 0;
        var attachment_number: usize = 0;
        for (self.thread, 0..) |message, message_index| {
            self.reader_card_rows[message_index] = row;
            const from = get(message, "from");
            if (self.thread.len > 1) {
                const stamp = try timestamp(self.frame.allocator(), &self.zone, get(message, "receivedAt"));
                const heading = try std.fmt.allocPrint(self.frame.allocator(), "{s} {d}/{d} {s}{s} · {s}", .{ if (self.reader_cards[message_index]) "▾" else "▸", message_index + 1, self.thread.len, if (truth(get(message, "unread"))) "● " else "", if (text(get(from, "name")).len > 0) text(get(from, "name")) else text(get(from, "address")), if (stamp.len >= 16) stamp[5..16] else stamp });
                const block_start = row;
                row = try self.flowTone(win, try self.fitLine(win, heading, win.width), self.reader_scroll, row, if (message_index == self.reader_card) .accent else .sender);
                self.readerMouseRows(win, block_start, row - block_start, .reader_thread, message_index);
                if (!self.reader_cards[message_index]) {
                    attachment_number += items(get(message, "attachments")).len;
                    continue;
                }
            }
            const compact = win.height <= 12 or win.width < 60;
            const to = try Compose.mailboxes(self.frame.allocator(), get(message, "to"));
            const cc = try Compose.mailboxes(self.frame.allocator(), get(message, "cc"));
            const subject = text(get(message, "subject"));
            const shown_subject = if (subject.len == 0) "(no subject)" else subject;
            row = try self.flowTone(win, if (compact) try self.fitLine(win, shown_subject, win.width) else shown_subject, self.reader_scroll, row, .subject);
            const stamp = try timestamp(self.frame.allocator(), &self.zone, get(message, "receivedAt"));
            if (!compact or self.thread.len == 1) {
                const sender_line = try std.fmt.allocPrint(self.frame.allocator(), "From: {s} <{s}>{s}{s}", .{ text(get(from, "name")), text(get(from, "address")), if (compact and stamp.len > 0) " · " else "", if (compact) (if (stamp.len >= 16) stamp[5..16] else stamp) else "" });
                row = try self.flowTone(win, if (compact) try self.fitLine(win, sender_line, win.width) else sender_line, self.reader_scroll, row, .sender);
            }
            if (compact) {
                if (to.len > 0 or cc.len > 0) {
                    const envelope = try std.fmt.allocPrint(self.frame.allocator(), "To: {s}{s}{s}", .{ to, if (cc.len > 0) " · Cc: " else "", cc });
                    row = try self.flowTone(win, try self.fitLine(win, envelope, win.width), self.reader_scroll, row, .muted);
                }
            } else {
                const envelope = if (self.thread.len > 1) (if (cc.len > 0) try std.fmt.allocPrint(self.frame.allocator(), "To: {s}\nCc: {s}", .{ to, cc }) else try std.fmt.allocPrint(self.frame.allocator(), "To: {s}", .{to})) else try readerEnvelope(self.frame.allocator(), to, cc, stamp);
                row = try self.flowTone(win, envelope, self.reader_scroll, row, .muted);
            }
            row += 1;
            var rich_drawn = false;
            if (message_index < self.markup.len) {
                const view = &self.markup[message_index];
                self.prepareVisibleMarkup(view, message);
                if (view.prepared) |*prepared| {
                    const builds = prepared.layout_builds;
                    const ready = blk: {
                        prepared.ensure(win.width, win.screen.width_method) catch {
                            if (prepared.layout_builds != builds) self.html_stats.htmlFallbacks += 1;
                            view.fallback = true;
                            break :blk false;
                        };
                        break :blk true;
                    };
                    self.html_stats.htmlLayoutBuilds += prepared.layout_builds - builds;
                    if (ready) {
                        view.fallback = false;
                        row = prepared.drawHighlightedFolded(win, self.reader_scroll, row, self.palette, self.mono, self.fold_quotes, self.fold_signatures, self.search_highlight.value());
                        rich_drawn = true;
                    }
                }
                if (view.fallback) row = try self.flowTone(win, "Plain text · HTML layout unavailable", self.reader_scroll, row, .muted);
            }
            if (!rich_drawn) {
                const folded = try reader_tools.fold(self.frame.allocator(), text(get(message, "bodyText")), self.fold_quotes, self.fold_signatures);
                row = try self.flow(win, folded.text, self.reader_scroll, row);
            }
            var links_in_text: reader_tools.Links = .{};
            reader_tools.findLinks(text(get(message, "bodyText")), &links_in_text);
            if (links_in_text.count > 0 or std.mem.indexOf(u8, text(get(message, "bodyHtml")), "href=") != null) {
                const block_start = row;
                row = try self.flowTone(win, "Links · L chooses a literal URL to open", self.reader_scroll, row, .sender);
                self.readerMouseRows(win, block_start, row - block_start, .reader_link, 0);
            }
            for (items(get(message, "attachments"))) |attachment| {
                attachment_number += 1;
                const value_in = try std.fmt.allocPrint(self.frame.allocator(), "Attachment {d}: {s} · B Save/open", .{ attachment_number, text(get(attachment, "filename")) });
                const block_start = row;
                row = try self.flowTone(win, value_in, self.reader_scroll, row, .sender);
                self.readerMouseRows(win, block_start, row - block_start, .reader_attachment, attachment_number - 1);
            }
            if (get(message, "invitation") != .null) row = try self.flow(win, "Invitation · I Review RSVP\n", self.reader_scroll, row);
            row = try self.flow(win, "\n────────────────────\n", self.reader_scroll, row);
        }
        return row;
    }
    fn composeAttachmentsDraw(self: *App, win: vaxis.Window, row: usize, visible: usize) !void {
        self.compose.attachment_height = visible;
        self.compose.attachment_scroll = @min(self.compose.attachment_scroll, self.compose.attachments.len -| visible);
        if (row >= win.height or win.width == 0) return;
        const viewport = win.child(.{ .y_off = @intCast(row), .height = @intCast(visible + 1) });
        self.mouseArea(viewport, .compose_attachment_scroll, 0);
        const can_edit = self.canEditAttachments();
        const add = "[Add A]";
        const add_width: u16 = @intCast(@min(add.len, win.width));
        const add_x = win.width - add_width;
        const title = if (self.compose.attachments.len > visible and visible > 0)
            try std.fmt.allocPrint(self.frame.allocator(), "Attachments {d} · {d}–{d}", .{ self.compose.attachments.len, self.compose.attachment_scroll + 1, self.compose.attachment_scroll + visible })
        else
            try std.fmt.allocPrint(self.frame.allocator(), "Attachments {d}", .{self.compose.attachments.len});
        try self.line(viewport.child(.{ .width = add_x -| 1 }), 0, title, .muted);
        const add_button = viewport.child(.{ .x_off = add_x, .width = add_width, .height = 1 });
        try self.line(add_button, 0, add, if (can_edit) .accent else .muted);
        if (can_edit) self.mouseArea(add_button, .compose_attachment_add, 0);
        const end = @min(self.compose.attachment_scroll + visible, self.compose.attachments.len);
        for (self.compose.attachments[self.compose.attachment_scroll..end], self.compose.attachment_scroll..) |attachment, index| {
            const file_row = viewport.child(.{ .y_off = @intCast(index - self.compose.attachment_scroll + 1), .height = 1 });
            const remove_width: u16 = @min(3, file_row.width);
            const remove_x = file_row.width - remove_width;
            const size = if (attachment.size >= 1024 * 1024)
                try std.fmt.allocPrint(self.frame.allocator(), "{d}.{d} MiB", .{ attachment.size / (1024 * 1024), attachment.size % (1024 * 1024) * 10 / (1024 * 1024) })
            else if (attachment.size >= 1024)
                try std.fmt.allocPrint(self.frame.allocator(), "{d}.{d} KiB", .{ attachment.size / 1024, attachment.size % 1024 * 10 / 1024 })
            else
                try std.fmt.allocPrint(self.frame.allocator(), "{d} B", .{attachment.size});
            const size_right = remove_x -| 1;
            const size_width: u16 = @intCast(@min(size.len, size_right));
            const size_x = size_right - size_width;
            try self.line(file_row.child(.{ .width = size_x -| 1 }), 0, try std.fmt.allocPrint(self.frame.allocator(), "{d}. {s}", .{ index + 1, attachment.filename }), .text);
            try self.line(file_row.child(.{ .x_off = size_x, .width = size_width }), 0, size, .muted);
            const remove_button = file_row.child(.{ .x_off = remove_x, .width = remove_width });
            try self.line(remove_button, 0, "[x]", if (can_edit) .accent else .muted);
            if (can_edit) self.mouseArea(remove_button, .compose_attachment_remove, index);
        }
    }
    fn composeCompletionDraw(self: *App, win: vaxis.Window) !void {
        const matches = self.composeCompletions();
        if (win.width < 20) return;
        const row = self.compose.selected + 2;
        if (matches.len == 0) {
            if (!self.compose.insert_mode or self.compose.selected >= 3 or matches.range.query.len == 0) return;
            recipients.validateAddress(matches.range.query) catch {
                if (row < win.height) try self.line(win, row, self.recipientHint(), .muted);
            };
            return;
        }
        const visible: usize = @min(4, @min(matches.len, win.height -| (row + 2)));
        if (visible == 0) return;
        self.compose.completion_selected = @min(self.compose.completion_selected, matches.len - 1);
        const top = self.compose.completion_selected -| (visible - 1);
        const popup = win.child(.{ .y_off = @intCast(row), .height = @intCast(visible + 1) });
        popup.fill(.{ .style = self.style(.text) });
        try self.line(popup, 0, "Recipients · Ctrl+N/P · Enter accepts", .muted);
        for (matches.values[top .. top + visible], top..) |candidate, index| {
            const label = if (candidate.name.len > 0) try std.fmt.allocPrint(self.frame.allocator(), "{s} <{s}>", .{ candidate.name, candidate.address }) else candidate.address;
            try self.line(popup, index - top + 1, label, if (index == self.compose.completion_selected) .selected else .text);
            self.mouseRows(popup, index - top + 1, 1, .compose_completion, index);
        }
    }
    fn composeDraw(self: *App, win: vaxis.Window) !void {
        if (self.mode == .review) {
            const inner = self.panel(win, 0, win.width, " Review send · y SEND · Esc Back ", true);
            const review = try std.fmt.allocPrint(self.frame.allocator(), "Sending account: {s}\nFrom: {s}\nTo: {s}\nCc: {s}\nBcc: {s}\nSubject: {s}\nThread: {s}\n\n{s}", .{ self.account(), if (self.compose.from.value().len > 0) self.compose.from.value() else self.account(), self.compose.fields[0].value(), self.compose.fields[1].value(), self.compose.fields[2].value(), self.compose.fields[3].value(), self.compose.thread.value(), self.compose.fields[4].value() });
            const total = try self.flow(inner, review, self.reader_scroll, 0);
            var rows = total;
            for (self.compose.attachments, 0..) |attachment, index| {
                const label = try std.fmt.allocPrint(self.frame.allocator(), "Attachment {d}: {s} ({d} bytes)\n", .{ index + 1, attachment.filename, attachment.size });
                rows = try self.flow(inner, label, self.reader_scroll, rows);
            }
            self.reader_scroll = @min(self.reader_scroll, rows -| @as(usize, inner.height));
            return;
        }
        const split = win.width >= 90;
        const left_width = if (split) win.width * 3 / 5 else win.width;
        const title = if (self.compose.unknown_outcome) " Compose · protected recovery draft " else if (self.job.future != null and self.job.kind == .autosave) " Compose · saving locally… " else if (self.compose.revision != self.compose.saved_revision) " Compose · autosave pending " else " Compose · saved locally · not sent ";
        const left = self.panel(win, 0, left_width, title, true);
        const alias_width: u16 = @min(@as(u16, 9), left.width);
        const alias_x = left.width - alias_width;
        try self.line(left.child(.{ .width = alias_x -| 1 }), 0, try std.fmt.allocPrint(self.frame.allocator(), "From: {s}", .{if (self.compose.from.value().len > 0) self.compose.from.value() else self.account()}), .text);
        const alias_action = left.child(.{ .x_off = alias_x, .width = alias_width, .height = 1 });
        try self.line(alias_action, 0, "[f Alias]", if (self.compose.unknown_outcome) .muted else .accent);
        if (!self.compose.unknown_outcome) self.mouseArea(alias_action, .compose_from, 0);
        if (self.compose.unknown_outcome) try self.line(left, 1, try std.fmt.allocPrint(self.frame.allocator(), "Operation: {s}", .{self.compose.operation_id.value()}), .warning);
        const header_row: usize = if (self.compose.unknown_outcome) 2 else 1;
        for ([_][]const u8{ "To", "Cc", "Bcc", "Subject" }, 0..) |name, index| {
            const field = &self.compose.fields[index];
            const editing = self.compose.selected == index and self.compose.insert_mode;
            try self.editLine(left, index + header_row, name, field, editing, if (self.compose.selected == index and self.mode == .compose) .selected else .text);
            self.mouseRows(left, index + header_row, 1, .compose_field, index);
        }
        const body_row = header_row + 5;
        try self.line(left, body_row, if (self.compose.selected == 4 and self.compose.insert_mode) "Body: INSERT" else "Body:", if (self.compose.selected == 4 and self.mode == .compose) .selected else .muted);
        const end_row = left.height;
        // Keep recent files visible without turning the composer into a file
        // manager. Ordinary terminal sizes retain at least five body rows.
        const attachment_rows: usize = @min(self.compose.attachments.len, @min(3, end_row -| 14));
        const attachment_row = end_row -| (attachment_rows + 1);
        const body = left.child(.{ .y_off = @intCast(body_row + 1), .height = @intCast(attachment_row -| (body_row + 1)) });
        self.mouseArea(body, .compose_field, 4);
        // Measure the same sanitized graphemes and wrapping as the renderer.
        // Newline counts alone cannot keep a long single paragraph's caret in view.
        const value_in = self.compose.fields[4].value();
        const cursor_at = self.compose.fields[4].cursor;
        const editing_body = self.compose.selected == 4 and self.compose.insert_mode;
        if (editing_body and body.width > 0 and body.height > 0) {
            const caret = try self.caretPosition(body, value_in, cursor_at);
            if (caret.row < self.compose.body_scroll) self.compose.body_scroll = caret.row;
            if (caret.row -| self.compose.body_scroll >= body.height) self.compose.body_scroll = caret.row + 1 - body.height;
        }
        const body_lines = if (editing_body) try self.flowCaret(body, value_in, cursor_at, self.compose.body_scroll) else try self.flow(body, value_in, self.compose.body_scroll, 0);
        self.compose.body_scroll = @min(self.compose.body_scroll, body_lines -| @as(usize, body.height));
        try self.composeAttachmentsDraw(left, attachment_row, attachment_rows);
        if (split) {
            const right = self.panel(win, left_width, win.width - left_width, if (self.compose.unknown_outcome) " Submission receipt " else if (self.compose_original and self.thread.len > 0) " Original message " else " Draft preview ", false);
            if (self.compose.unknown_outcome) {
                const receipt = try std.fmt.allocPrint(self.frame.allocator(), "Outcome unknown\nOperation: {s}\nReason: {s}\n\nThe original recovery draft is protected.\nNo edit or automatic resend.\n\n:receipt checks the journal.\nq keeps it and returns to mail.", .{ self.compose.operation_id.value(), self.compose.operation_error.value() });
                _ = try self.flow(right, receipt, 0, 0);
            } else if (self.compose_original and self.thread.len > 0) try self.readerDraw(right) else {
                const preview_area = right.child(.{ .y_off = 1 });
                self.reader_height = preview_area.height;
                const clean = try safe(self.frame.allocator(), value_in, true);
                self.reader_lines = positionAfter(preview_area, clean).row + 1;
                self.reader_scroll = @min(self.reader_scroll, readerEnd(self.reader_lines, self.reader_height));
                _ = try self.flow(preview_area, value_in, self.reader_scroll, 0);
            }
        }
        try self.composeCompletionDraw(left);
    }
    fn contactsDraw(self: *App, win: vaxis.Window) !void {
        const title = try std.fmt.allocPrint(self.frame.allocator(), " {s} · {d}/{d} ", .{ if (self.picker) @as([]const u8, "Choose recipient") else "Contacts", if (self.contacts.len != 0) @min(self.contacts_selected + 1, self.contacts.len) else 0, self.contacts.len });
        const inner = self.panel(win, 0, win.width, title, true);
        if (self.mode == .contact_edit) {
            try self.line(inner, 1, try std.fmt.allocPrint(self.frame.allocator(), "Name: {s}▏", .{self.contact_name.value()}), if (self.contact_field == 0) .selected else .text);
            try self.line(inner, 3, try std.fmt.allocPrint(self.frame.allocator(), "Email: {s}▏", .{self.contact_email.value()}), if (self.contact_field == 1) .selected else .text);
            self.mouseRows(inner, 1, 1, .contact_field, 0);
            self.mouseRows(inner, 3, 1, .contact_field, 1);
            try self.line(inner, 6, "Tab Field · Ctrl+S Save · Esc Cancel", .accent);
            return;
        }
        const phase = switch (self.contacts_state) {
            .loading => if (self.job.future != null and self.job.kind == .contacts) "Loading contacts…" else "Loading contacts · request queued",
            .cached => if (self.job.future != null and self.job.kind == .contacts) "Refreshing cached contacts" else if (self.pending_contacts) "Cached contacts · refresh queued" else "Cached contacts",
            .current => "Available contacts",
            .denied => "Contacts permission required · contacts-read",
            .failed => "Contacts unavailable · retained entries remain usable",
            .busy => "Cache busy · contacts retry locally",
        };
        if (self.contacts_state != .current) try self.line(inner, 0, try self.fitLine(inner, phase, inner.width), if (self.contacts_state == .denied or self.contacts_state == .failed) .warning else if (self.contacts_state == .loading) .fetching else .muted);
        if (self.contacts_state == .denied) {
            try self.line(inner, 2, "A separate terminal contacts-read grant is required.", .text);
            try self.line(inner, 4, "? Help · Esc / q Back · no consent starts here", .muted);
            return;
        }
        if (self.contacts.len == 0 and self.contacts_cache_ready) try self.line(inner, 2, "No contacts · n Create contact", .muted);
        const first_row: usize = if (self.contacts_state == .current) 0 else 2;
        const stride: usize = if (inner.height >= 16) 3 else 2;
        const visible = @max((inner.height -| first_row) / stride, 1);
        const top = self.contacts_selected -| @as(usize, visible - 1);
        var index = top;
        while (index < self.contacts.len and index - top < visible) : (index += 1) {
            const contact = self.contacts[index];
            const row = first_row + (index - top) * stride;
            if (row >= inner.height) break;
            const item = inner.child(.{ .y_off = @intCast(row), .height = @min(@as(u16, 2), inner.height -| @as(u16, @intCast(row))) });
            const selected = index == self.contacts_selected;
            item.fill(.{ .style = self.style(if (selected) .selected else .text) });
            _ = item.child(.{ .height = 1 }).printSegment(.{ .text = try self.fitLine(item, text(get(contact, "name")), item.width), .style = self.listStyle(.subject, selected) }, .{ .wrap = .none });
            if (item.height > 1) _ = item.child(.{ .y_off = 1, .height = 1 }).printSegment(.{ .text = try self.fitLine(item, try Compose.mailboxes(self.frame.allocator(), get(contact, "emails")), item.width), .style = self.listStyle(.muted, selected) }, .{ .wrap = .none });
            self.mouseRows(inner, row, 2, .contact, index);
        }
    }
    fn contextHints(self: *const App) []const u8 {
        if (self.reader_overlay == .save_attachment or self.reader_overlay == .open_attachment) return " Tab Complete · Enter Save · Esc Attachments · Ctrl+U Clear · q is text";
        if (self.reader_overlay == .attachments) return " j/k Choose  s Save  o Save & open  Esc/q Back";
        if (self.reader_overlay == .links) return " j/k Choose URL  Enter Open in account profile  Esc/q Back";
        return switch (self.mode) {
            .contacts => " j/k Move  / Search  n New  e Edit  ? Help  Esc/q Back",
            .contact_edit => " Tab Field  Ctrl+S Save  Esc Contacts  q is text",
            .compose => if (self.compose.unknown_outcome) " Protected recovery draft · :receipt Check · q Keep/back" else if (self.compose.insert_mode) (if (self.compose.selected < 3) " INSERT · Ctrl+N/P Recipient · Enter Choose · Tab Field · Esc Normal" else " INSERT · Tab Field · Esc Normal · q is text") else " i Edit · Tab Field · A Attach · e $EDITOR · Ctrl+D/U Preview · L/B Links/files · Ctrl+S Review · q Save/back",
            .review => if (self.job.future != null and self.job.kind == .send) " Submission pending · awaiting receipt · q Draft" else " y Explicit send  j/k Scroll  Esc/q Return to draft",
            .help => " j/k Scroll  Home/End  Esc/q Return",
            .trash_confirm => " y Confirm Trash  n/Esc/q Cancel",
            .invitation => " a Accept  t Tentative  d Decline  Esc/q Cancel",
            .browse => if (self.expanded) " J/K Mail  {/} Thread  t Fold  L Links  B Files  z/Esc/q Shrink" else if (self.focus == .reader) " J/K Mail  j/k Scroll  {/} Thread  t Fold  L Links  B Files  Esc/q List" else if (self.focus == .navigation) " j/k Navigate  Enter Choose  l/Esc/q Mail  ? Help" else if (self.cacheSearch()) " Cache subset · / Cache  \\ Gmail  l Reader  c Compose  q Clear cache search" else if (self.query.value().len > 0) " Gmail search · / Cache  \\ Gmail  l Reader  c Compose  q Clear Gmail search" else " j/k Mail  h/l Pane  / Cache  \\ Gmail  c Compose  v Layout  ? Help  q Quit",
            else => " Esc Back",
        };
    }
    fn fittedHints(self: *const App, width: u16) []const u8 {
        if (self.mode == .attachment) return " Tab Complete · Enter Attach · Esc Back · Ctrl+U Clear";
        if (self.mode == .compose and !self.compose.insert_mode and !self.compose.unknown_outcome) {
            if (width < 60) return " i Edit · A Attach · Ctrl+S Review · q Save · ? Help";
            if (width < 90) return " i Edit · A Attach · Ctrl+S Review · q Save · Tab Field · e Editor · ? Help";
            if (width < 130) return " i Edit · A Attach · Ctrl+S Review · q Save · Ctrl+D/U Preview · Tab Field · a Contacts · ? Help";
        }
        if (self.mode == .compose and self.compose.insert_mode and width < 80) return " INSERT · Esc Normal · Tab Field · q is text";
        return self.contextHints();
    }
    fn overlay(self: *App, win: vaxis.Window, title: []const u8, body: []const u8) !void {
        const width = @min(win.width, 78);
        const height = @min(win.height, 20);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, title, true);
        _ = try self.flow(inner, body, 0, 0);
    }
    fn helpContent(self: *App, win: vaxis.Window, offset: usize, paint: bool) !usize {
        if (win.width == 0) return 0;
        var row: usize = 0;
        const aligned = win.width >= 62;
        const keys_width: u16 = if (aligned) 26 else win.width;
        for (help_rows) |entry| {
            if (entry.section.len > 0) {
                if (row > 0) row += 1;
                if (paint) _ = try self.flowTone(win, entry.section, offset, row, .accent);
                row += positionAfter(win, entry.section).row + 1;
            } else if (entry.keys.len == 0) {
                row += 1;
                if (paint) _ = try self.flowTone(win, entry.action, offset, row, .muted);
                row += positionAfter(win, entry.action).row + 1;
            } else if (aligned) {
                const keys = win.child(.{ .width = keys_width });
                const action = win.child(.{ .x_off = keys_width + 2, .width = win.width - keys_width - 2 });
                if (paint) {
                    _ = try self.flowTone(keys, entry.keys, offset, row, .sender);
                    _ = try self.flowTone(action, entry.action, offset, row, .text);
                }
                row += @max(positionAfter(keys, entry.keys).row, positionAfter(action, entry.action).row) + 1;
            } else {
                if (paint) _ = try self.flowTone(win, entry.keys, offset, row, .sender);
                row += positionAfter(win, entry.keys).row + 1;
                const action = win.child(.{ .x_off = 2, .width = win.width -| 2 });
                if (paint) _ = try self.flowTone(action, entry.action, offset, row, .text);
                row += positionAfter(action, entry.action).row + 1;
            }
        }
        return row;
    }
    fn helpDraw(self: *App, win: vaxis.Window) !void {
        const width = @min(win.width -| 2, 90);
        const height = @min(win.height -| 2, 42);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, " Keyboard & mouse ", true);
        if (inner.width <= 2 or inner.height <= 2) return;
        const content = inner.child(.{ .x_off = 1, .width = inner.width - 2, .height = inner.height - 2 });
        self.help_lines = try self.helpContent(content, 0, false);
        self.help_height = content.height;
        self.help_scroll = @min(self.help_scroll, self.help_lines -| self.help_height);
        _ = try self.helpContent(content, self.help_scroll, true);
        const footer = if (self.status_error_len > 0) try std.fmt.allocPrint(self.frame.allocator(), " Esc/q Back · Diagnostic: {s}", .{self.status_error_code[0..self.status_error_len]}) else try std.fmt.allocPrint(self.frame.allocator(), " j/k Scroll · Esc/q Back   {d}–{d}/{d}", .{ self.help_scroll + 1, @min(self.help_scroll + self.help_height, self.help_lines), self.help_lines });
        try self.line(inner, inner.height - 1, try self.fitLine(inner, footer, inner.width), .muted);
    }
    fn invitationDraw(self: *App, win: vaxis.Window) !void {
        const width = @min(win.width -| 2, 100);
        const height = @min(win.height -| 2, 30);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, " Review invitation reply ", true);
        const identity = try std.fmt.allocPrint(self.frame.allocator(), "Account: {s}\nAttendee: {s}\nOrganizer: {s}", .{ self.invitation_inspected_account.value(), self.invitation_review.attendee.slice(), self.invitation_review.organizer.slice() });
        const clean_identity = try safe(self.frame.allocator(), identity, true);
        const identity_rows = positionAfter(inner, clean_identity).row + 1;
        // Identity and confirmation controls are never clipped to make room
        // for event details. A very small viewport cannot authorize an RSVP.
        if (inner.width < 48 or identity_rows + 4 > inner.height) {
            self.invitation_height = 0;
            _ = try self.flow(inner, "Resize to review RSVP identity.\nNo RSVP can be submitted at this size.\n\nEsc Cancel", 0, 0);
            return;
        }
        self.invitation_confirm_ready = true;
        _ = try self.flow(inner.child(.{ .height = @intCast(identity_rows) }), clean_identity, 0, 0);
        const details = inner.child(.{ .y_off = @intCast(identity_rows + 1), .height = @intCast(inner.height - identity_rows - 3) });
        const review = try std.fmt.allocPrint(self.frame.allocator(), "Event: {s}\nStart: {s}\nUID: {s}\nRecurrence: {s}\n\nThis submits an RSVP email; it does not claim\nto update Google Calendar.", .{ self.invitation_review.summary.slice(), self.invitation_review.start.slice(), self.invitation_review.uid.slice(), self.invitation_review.recurrence_id.slice() });
        const clean_review = try safe(self.frame.allocator(), review, true);
        self.invitation_lines = positionAfter(details, clean_review).row + 1;
        self.invitation_height = details.height;
        self.invitation_scroll = @min(self.invitation_scroll, self.invitation_lines -| self.invitation_height);
        _ = try self.flow(details, clean_review, self.invitation_scroll, 0);
        try self.line(inner, inner.height - 2, "a Accept · t Tentative · d Decline · Esc Cancel", .accent);
        try self.line(inner, inner.height - 1, "j/k Scroll · Ctrl+D/U Page · Home/End", .muted);
    }
    fn resize(self: *App, original: vaxis.Winsize) !void {
        var size = original;
        size.cols = @min(@max(size.cols, 1), max_cols);
        size.rows = @min(@max(size.rows, 1), max_rows);
        try self.vx.resize(self.allocator, self.tty.writer(), size);
    }
    fn draw(self: *App) !void {
        try self.ensureLoadingAnimation();
        _ = self.frame.reset(.retain_capacity);
        self.clearObsoleteStatus();
        self.mouse_hits.clear();
        const win = self.vx.window();
        self.invitation_confirm_ready = false;
        win.clear();
        win.hideCursor();
        win.fill(.{ .style = self.style(.text) });
        if (win.width < 30 or win.height < 10) {
            try self.line(win, 0, "omagma · resize terminal · q quits", .accent);
            return;
        }
        try self.line(win, 0, try self.fittedGlobalHeader(win), .accent);
        try self.line(win, 1, try self.fitLine(win, try self.syncLine(), win.width), self.syncTone());
        const body = win.child(.{ .y_off = 2, .height = win.height -| 4 });
        if (self.mode == .compose or self.mode == .review or self.mode == .attachment) try self.composeDraw(body) else if (self.mode == .contacts or self.mode == .contact_edit or (self.mode == .search and self.previous_mode == .contacts)) try self.contactsDraw(body) else {
            const panes = layout.computeWithRatios(body.width, body.height, self.focus, self.reader_layout, self.expanded, try self.navigationWidth(body), self.ui_preferences.listWidthPercent, self.ui_preferences.listHeightPercent);
            if (panes.navigation) |rect| try self.navigationDraw(self.pane(body, rect, " Accounts / mailboxes ", self.focus == .navigation));
            if (panes.list) |rect| try self.listDraw(self.pane(body, rect, try self.listTitle(), self.focus == .list));
            if (panes.reader) |rect| {
                try self.readerDraw(self.pane(body, rect, " Thread / full body ", self.focus == .reader));
                if (self.thread.len == 1 and self.reader_lines > 0 and rect.width > 4) {
                    const title = try std.fmt.allocPrint(self.frame.allocator(), " Message · {s} ", .{try self.readerProgressText()});
                    const title_area = body.child(.{ .x_off = rect.x + 2, .y_off = rect.y, .width = rect.width - 4, .height = 1 });
                    _ = title_area.printSegment(.{ .text = try self.fitLine(title_area, title, title_area.width), .style = self.style(if (self.focus == .reader) .accent else .muted) }, .{ .wrap = .none });
                }
            }
        }
        if (self.mode == .search or self.mode == .command or self.mode == .labels or self.mode == .attachment) {
            const prompt = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}▏", .{ if (self.mode == .command) ":" else if (self.mode == .labels) "Label (name adds, -name removes): " else if (self.mode == .attachment) "Attach file path: " else if (self.previous_mode == .contacts) "Contacts / " else if (self.input_query_scope == .cache) "Cache / " else "Gmail \\ ", self.input.value() });
            try self.line(win, win.height - 2, prompt, .selected);
        } else try self.line(win, win.height - 2, try self.fitLine(win, self.fittedHints(win.width), win.width), .muted);
        try self.line(win, win.height - 1, try self.fitLine(win, self.status[0..self.status_len], win.width), if (self.warning) .warning else .muted);
        try self.drawReaderOverlay(win);
        try self.drawPathCompletion(win);
        try self.drawLabelPicker(win);
        if (self.mode == .help) try self.helpDraw(win) else if (self.mode == .trash_confirm) try self.overlay(win, " Move selected mail to Trash? ", "This moves the selected message to Trash.\nIt does not permanently delete mail.\n\ny Confirm · n / Esc Cancel") else if (self.mode == .invitation) {
            try self.invitationDraw(win);
        }
    }
};

fn signalTask(app: *App, file: Io.File) void {
    var bytes: [8]u8 = undefined;
    var read_buffer: [8]u8 = undefined;
    var reader = file.readerStreaming(app.io, &read_buffer);
    reader.interface.readSliceAll(&bytes) catch return;
    app.cancellation.set(app.io);
    _ = app.loop.tryPostEvent(.terminate) catch {};
}

pub fn run(io: Io, allocator: Allocator, client: types.Client, options: types.Options, environ: *const std.process.Environ.Map) !html_view.Stats {
    if (same(options.editor_mode, "embedded")) return error.EmbeddedEditorDeferred;
    if (!same(options.editor_mode, "auto") and !same(options.editor_mode, "takeover")) return error.InvalidEditorMode;
    var tty_buffer: [16 * 1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer {
        tty.deinit();
        vaxis.tty.global_tty = null;
    }
    var vx = try vaxis.init(io, allocator, @constCast(environ), .{});
    defer vx.deinit(allocator, tty.writer());
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);
    loop.init(io, allocator, &tty, &vx);
    defer loop.deinit();
    var app: App = .{
        .io = io,
        .allocator = allocator,
        .client = client,
        .options = options,
        .environ = environ,
        .vx = &vx,
        .tty = &tty,
        .loop = loop,
        .account_arena = .init(allocator),
        .list_arena = .init(allocator),
        .read_arena = .init(allocator),
        .contact_arena = .init(allocator),
        .job_arena = .init(allocator),
        .frame = .init(allocator),
        .mono = if (environ.get("NO_COLOR")) |value_in| value_in.len > 0 else false,
    };
    defer app.deinit();
    app.zone = timezone.load(io, allocator, environ) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => .{ .unavailable = true },
    };
    try app.boot();
    app.reloadTheme();
    app.loadPreferences();
    try app.restoreInitialContext();
    try app.prepareLabels();
    const raw_fd = std.os.linux.eventfd(0, 0x80000); // EFD_CLOEXEC, no nonblocking spin.
    if (std.os.linux.errno(raw_fd) != .SUCCESS) return error.SignalWakeFailed;
    const wake_file: Io.File = .{ .handle = @intCast(raw_fd), .flags = .{ .nonblocking = false } };
    defer wake_file.close(io);
    var old_handlers: [4]std.posix.Sigaction = undefined;
    const signals = [_]std.posix.SIG{ .TERM, .HUP, .INT, .QUIT };
    received_signal.store(0, .release);
    signal_fd.store(wake_file.handle, .release);
    for (signals, 0..) |signal, index| {
        var action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(signal, &action, &old_handlers[index]);
    }
    defer {
        signal_fd.store(-1, .release);
        for (signals, 0..) |signal, index| std.posix.sigaction(signal, &old_handlers[index], null);
    }
    var signal_future = try io.concurrent(signalTask, .{ &app, wake_file });
    defer signal_future.cancel(io);
    active.store(true, .release);
    defer active.store(false, .release);
    try loop.start();
    try loop.installResizeHandler();
    try vx.enterAltScreen(tty.writer());
    if (tty.getWinsize()) |size| try app.resize(size) else |_| {}
    _ = app.loadCachedList("") catch |err| blk: {
        app.sayFailure("Cache unavailable", @errorName(err));
        break :blk false;
    };
    app.sync[app.account_index].state = if (app.sync[app.account_index].cache_ready) .refreshing else .fetching;
    try app.draw();
    try vx.render(tty.writer());
    try tty.writer().flush();
    // The first colored phase and available cached bodies are already on
    // screen before terminal capability negotiation or any provider fetch.
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try setMouseReporting(&vx, tty.writer(), !options.no_mouse);
    try app.refreshMailbox();
    while (!app.quit and received_signal.load(.acquire) == 0) {
        app.finish() catch |err| app.sayError(@errorName(err));
        try app.draw();
        try vx.render(tty.writer());
        try tty.writer().flush();
        const event = loop.nextEvent() catch |err| switch (err) {
            error.Closed, error.EndOfStream => break,
            else => return err,
        };
        switch (event) {
            .key_press => |key| app.onKey(key) catch |err| app.sayError(@errorName(err)),
            .mouse => |mouse| app.onMouse(mouse) catch |err| app.sayError(@errorName(err)),
            .winsize => |size| try app.resize(size),
            .paste_start => app.paste = true,
            .paste_end => app.paste = false,
            .operation_done => {},
            .fetch_progress => {
                app.job.progress.acknowledged();
                app.hydrateArrivingMail() catch {};
            },
            .loading_tick => {
                app.loading_tick_pending.store(false, .release);
                if (app.loadingActive()) {
                    app.loading_frame +%= 1;
                    app.hydrateArrivingMail() catch {};
                }
            },
            .compose_idle => app.onComposeIdle() catch |err| app.sayFailure("Autosave failed · draft retained", @errorName(err)),
            .terminate => break,
        }
    }
    app.cancelJob();
    try app.persistDraftAtExit();
    app.rememberWorkingContext();
    app.saveUiPreferences();
    return app.html_stats;
}

test "terminal text removes control sequences and keeps safe Unicode" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cleaned = try safe(arena.allocator(), "hello\x1b]52;c;secret\x07\n世界\u{202e}", true);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "世界") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, '\n') != null);
    var cluster: [201]u8 = undefined;
    cluster[0] = 'a';
    for (0..100) |index| @memcpy(cluster[1 + index * 2 ..][0..2], "\u{0300}");
    try std.testing.expectEqualStrings("�", try safe(arena.allocator(), &cluster, false));
}

test "plain fallback sanitizer uses one input-sized reservation" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const cleaned = try safe(failing.allocator(), "Plain café 👋\nwith intact lines", true);
    defer failing.allocator().free(cleaned);
    try std.testing.expectEqualStrings("Plain café 👋\nwith intact lines", cleaned);
}

test "allocator refusal preserves the existing edited field" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var field: Field = .{};
    defer field.deinit(failing.allocator());
    try field.set(failing.allocator(), "original");
    const oversized: [1024]u8 = @splat('x');
    try std.testing.expectError(error.OutOfMemory, field.set(failing.allocator(), &oversized));
    try std.testing.expectEqualStrings("original", field.value());
    try std.testing.expectEqual(@as(usize, 8), field.cursor);
}

test "cached list merge preserves selected identity reader and unsaved compose context" {
    const allocator = std.testing.allocator;
    const NoProvider = struct {
        fn call(ctx: *anyopaque, _: Allocator, _: []const u8) ![]const u8 {
            const count: *u8 = @ptrCast(@alignCast(ctx));
            count.* += 1;
            return error.ProviderMustNotRun;
        }
    };
    var calls: u8 = 0;
    var app: App = .{
        .io = std.testing.io,
        .allocator = allocator,
        .client = .{ .ctx = &calls, .callFn = NoProvider.call },
        .options = .{ .fixtures = true },
        .environ = undefined,
        .vx = undefined,
        .tty = undefined,
        .loop = undefined,
        .account_arena = .init(allocator),
        .list_arena = .init(allocator),
        .read_arena = .init(allocator),
        .contact_arena = .init(allocator),
        .job_arena = .init(allocator),
        .frame = .init(allocator),
    };
    defer app.deinit();
    const account_value = try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always });
    app.accounts = items(account_value);
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"},{\"id\":\"b\"}],\"cached\":true,\"cacheReady\":true}}");
    try app.replaceReader(false, "{\"ok\":true,\"data\":{\"id\":\"a\",\"bodyText\":\"Cached full body\"}}", true);
    app.reader_scroll = 9;
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"new\"},{\"id\":\"a\"},{\"id\":\"b\"}],\"cached\":true,\"cacheReady\":true}}");
    try std.testing.expectEqual(@as(usize, 1), app.selected);
    try std.testing.expectEqualStrings("a", app.messageId());
    try std.testing.expectEqualStrings("Cached full body", text(get(app.thread[0], "bodyText")));
    try std.testing.expectEqual(@as(usize, 9), app.reader_scroll);
    const invalid_rejected = blk: {
        app.replaceList(.list, "{\"ok\":true,\"data\":{") catch break :blk true;
        break :blk false;
    };
    try std.testing.expect(invalid_rejected);
    try std.testing.expectEqualStrings("a", app.messageId());
    try std.testing.expectEqualStrings("Cached full body", text(get(app.thread[0], "bodyText")));
    app.compose_active = true;
    try app.compose.fields[3].set(allocator, "Unsaved subject");
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"new\"}],\"cached\":true,\"cacheReady\":true}}");
    try std.testing.expectEqualStrings("Unsaved subject", app.compose.fields[3].value());
    try std.testing.expectEqualStrings("Cached full body", text(get(app.thread[0], "bodyText")));
    app.compose_active = false;
    app.clearReader();
    try app.apply(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"old-online-only\",\"subject\":\"Provider page outside cache retention\"}]}}");
    try std.testing.expectEqualStrings("old-online-only", app.messageId());
    try std.testing.expect(!app.list_cached);
    try std.testing.expectEqual(@as(u8, 0), calls);
}

const CacheTestClient = struct {
    const Behavior = enum { transient, busy, miss, escaped_body, contacts, contacts_denied, cache_matches };
    behavior: Behavior = .transient,
    local_calls: usize = 0,
    provider_calls: usize = 0,
    response_bytes: usize = 0,
    cache_search_calls: usize = 0,
    body: []const u8 = "Local full body",

    fn provider(ctx: *anyopaque, _: Allocator, _: []const u8) ![]const u8 {
        const self: *CacheTestClient = @ptrCast(@alignCast(ctx));
        self.provider_calls += 1;
        return error.ProviderMustNotRun;
    }
    fn local(ctx: *anyopaque, allocator: Allocator, request: []const u8) ![]const u8 {
        const self: *CacheTestClient = @ptrCast(@alignCast(ctx));
        self.local_calls += 1;
        switch (self.behavior) {
            .busy => return error.CacheBusy,
            .miss => return allocator.dupe(u8, "{\"ok\":false,\"error\":{\"code\":\"CacheMiss\"}}"),
            .contacts => return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"contacts\":[{\"name\":\"Alex\",\"emails\":[{\"address\":\"alex@example.com\"}]},{\"name\":\"Sam\",\"emails\":[{\"address\":\"sam@example.com\"}]}],\"cached\":true,\"cacheReady\":true}}"),
            .contacts_denied => return allocator.dupe(u8, "{\"ok\":false,\"error\":{\"code\":\"PermissionDenied\"}}"),
            .cache_matches => {
                const parsed = try std.json.parseFromSlice(Value, allocator, request, .{});
                defer parsed.deinit();
                if (same(text(get(parsed.value, "cmd")), "mail.search")) {
                    if (!truth(get(parsed.value, "cacheOnly"))) return error.ExpectedCacheOnlySearch;
                    self.cache_search_calls += 1;
                    return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\",\"subject\":\"Needle in retained cache\"}],\"cached\":true,\"cacheReady\":true,\"partial\":true,\"searchMode\":\"cache\",\"searchScope\":\"metadata\"}}");
                }
            },
            .transient => {
                if (self.local_calls == 1) return error.CacheBusy;
                if (self.local_calls == 2) return allocator.dupe(u8, "{\"ok\":false,\"error\":{\"code\":\"CacheBusy\"}}");
            },
            .escaped_body => {},
        }
        const response = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true, .data = .{ .id = "a", .bodyText = self.body, .bodyCached = true } }, .{});
        self.response_bytes = response.len;
        return response;
    }
    fn app(self: *CacheTestClient, allocator: Allocator) App {
        return .{
            .io = std.testing.io,
            .allocator = allocator,
            .client = .{ .ctx = self, .callFn = provider, .cachedFn = local },
            .options = .{ .fixtures = true },
            .environ = undefined,
            .vx = undefined,
            .tty = undefined,
            .loop = undefined,
            .account_arena = .init(allocator),
            .list_arena = .init(allocator),
            .read_arena = .init(allocator),
            .contact_arena = .init(allocator),
            .job_arena = .init(allocator),
            .frame = .init(allocator),
        };
    }
};

test "cache contention retries locally and exhausted busy never becomes a network miss" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always }));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const hit = try app.cached(arena.allocator(), .{ .cmd = "mail.read", .account = "personal@example.com", .messageId = "a" }) orelse return error.ExpectedLocalHit;
    try std.testing.expectEqual(@as(usize, 3), client.local_calls);
    const value_in = try app.data(arena.allocator(), hit);
    try std.testing.expectEqualStrings("Local full body", text(get(value_in, "bodyText")));
    client.behavior = .miss;
    try std.testing.expect((try app.cached(arena.allocator(), .{ .cmd = "mail.read", .messageId = "a" })) == null);
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}],\"cached\":true,\"cacheReady\":true}}");
    client.behavior = .busy;
    client.local_calls = 0;
    try app.preview(false);
    try std.testing.expectEqual(@as(usize, 11), client.local_calls);
    try std.testing.expect(app.pending_cached_read);
    try std.testing.expect(app.reader_cache_busy);
    try std.testing.expect(!app.body_cache_miss);
    try std.testing.expect(!app.pending_read);
    try std.testing.expect(app.job.future == null);
    client.behavior = .transient;
    client.local_calls = 0;
    try app.retryLocalCache();
    try std.testing.expectEqualStrings("Local full body", text(get(app.thread[0], "bodyText")));
    try std.testing.expect(!app.pending_cached_read);
    try std.testing.expect(!app.reader_cache_busy);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "cached valid two MiB escaped body is not capped by outgoing request bytes" {
    const allocator = std.testing.allocator;
    const body = try allocator.alloc(u8, 2097152);
    defer allocator.free(body);
    @memset(body, '\n');
    var client: CacheTestClient = .{ .behavior = .escaped_body, .body = body };
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always }));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}],\"cached\":true,\"cacheReady\":true}}");
    try std.testing.expect(try app.cachedPreview(false));
    try std.testing.expect(client.response_bytes > 3145728);
    const retained = text(get(app.thread[0], "bodyText"));
    try std.testing.expectEqual(@as(usize, 2097152), retained.len);
    try std.testing.expectEqual(@as(u8, '\n'), retained[0]);
    try std.testing.expectEqual(@as(u8, '\n'), retained[retained.len - 1]);
    try std.testing.expect(!app.body_cache_miss);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "contacts opens from local cache and permission denial keeps pane without writes" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{ .behavior = .contacts };
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always }));
    app.picker = true;
    app.compose_active = true;
    try app.compose.fields[4].set(allocator, "Unsent body stays here");
    try app.prepareContacts("");
    try std.testing.expectEqual(Mode.contacts, app.mode);
    try std.testing.expectEqual(ContactsState.cached, app.contacts_state);
    try std.testing.expectEqual(@as(usize, 2), app.contacts.len);
    try std.testing.expect(app.pending_contacts);
    try std.testing.expect(app.job.future == null);
    const generation = app.contacts_generation;
    app.leaveContacts();
    try std.testing.expectEqual(Mode.compose, app.mode);
    try std.testing.expectEqual(generation + 1, app.contacts_generation);
    try std.testing.expect(!app.pending_contacts);
    try std.testing.expectEqualStrings("Unsent body stays here", app.compose.fields[4].value());
    app.picker = false;
    client.behavior = .contacts_denied;
    try app.prepareContacts("sam");
    try std.testing.expectEqual(Mode.contacts, app.mode);
    try std.testing.expectEqual(ContactsState.denied, app.contacts_state);
    try std.testing.expect(!app.pending_contacts and !app.pending_cached_contacts);
    try std.testing.expectEqual(@as(usize, 0), app.contacts.len);
    app.leaveContacts();
    try std.testing.expectEqual(Mode.browse, app.mode);
    try std.testing.expect(!app.quit);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "back stack returns one context and insertion q remains text" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always }));
    const contexts = [_]struct { mode: Mode, expected: Mode }{
        .{ .mode = .help, .expected = .contacts },
        .{ .mode = .review, .expected = .compose },
        .{ .mode = .trash_confirm, .expected = .browse },
        .{ .mode = .invitation, .expected = .browse },
    };
    for (contexts) |context| {
        try std.testing.expectEqual(context.expected, backMode(context.mode, .contacts, false));
        try std.testing.expect(!app.quit);
    }
    app.mode = .compose;
    app.compose.selected = 4;
    app.compose.insert_mode = true;
    try app.compose.fields[4].handleKey(allocator, .{ .codepoint = 'q', .text = "q" }, true, types.Limits.body_bytes);
    try std.testing.expectEqualStrings("q", app.compose.fields[4].value());
    app.mode = .contact_edit;
    app.contact_field = 0;
    try app.contact_name.handleKey(allocator, .{ .codepoint = 'q', .text = "q" }, false, 4096);
    try std.testing.expectEqualStrings("q", app.contact_name.value());
    app.mode = .browse;
    app.expanded = true;
    app.focus = .reader;
    try app.browseBack();
    try std.testing.expect(!app.expanded and app.focus == .reader and !app.quit);
    try app.browseBack();
    try std.testing.expect(app.focus == .list and !app.quit);
    app.folder = 1;
    const generation = app.generation;
    try app.query.set(allocator, "subject:needle");
    app.query_scope = .server;
    try app.cursor.set(allocator, "old-page");
    try app.previous_cursors.append(allocator, try allocator.dupe(u8, "previous-page"));
    try std.testing.expect(try app.clearSearch());
    try std.testing.expectEqualStrings("", app.query.value());
    try std.testing.expectEqual(QueryScope.cache, app.query_scope);
    try std.testing.expectEqualStrings("", app.cursor.value());
    try std.testing.expectEqual(@as(usize, 0), app.previous_cursors.items.len);
    try std.testing.expectEqual(generation + 1, app.generation);
    try std.testing.expectEqual(@as(usize, 1), app.folder);
    try std.testing.expectEqualStrings("personal@example.com", app.account());
    try std.testing.expect(!app.quit);
    try app.browseBack();
    try std.testing.expect(app.quit);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "cache search uses only retained local data and server cursors stay distinct" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{ .behavior = .cache_matches };
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always }));
    try app.query.set(allocator, "needle");
    app.query_scope = .cache;
    try app.reload();
    try std.testing.expectEqual(@as(usize, 1), client.cache_search_calls);
    try std.testing.expectEqualStrings("a", app.messageId());
    try std.testing.expectEqualStrings("Local full body", text(get(app.thread[0], "bodyText")));
    try std.testing.expect(app.job.future == null);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
    try app.beginSearch(.server);
    try std.testing.expectEqual(Mode.search, app.mode);
    try std.testing.expectEqual(QueryScope.server, app.input_query_scope);
    try std.testing.expectEqual(QueryScope.cache, app.query_scope);
    app.mode = .browse;
    app.query_scope = .server;
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}],\"cached\":true,\"cacheReady\":true,\"cursor\":\"C:old-query\",\"nextCursor\":\"C:next-query\",\"previousCursor\":\"C:previous-query\",\"remoteCursor\":\"L:server-page\"}}");
    try std.testing.expectEqualStrings("L:server-page", app.next_cursor.value());
    try std.testing.expectEqualStrings("", app.previous_cursor.value());
    try std.testing.expectEqualStrings("", app.cursor.value());
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "external refresh lease phase and completion do not claim old cache is current" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const held = try std.json.parseFromSliceLeaky(Value, allocator, "{\"coalesced\":true,\"refreshInProgress\":true,\"refreshed\":false,\"lastSyncAt\":1000}", .{});
    try std.testing.expect(refreshWaiting(held));
    try std.testing.expect(!refreshIsCurrent(held, 1500));
    const released = try std.json.parseFromSliceLeaky(Value, allocator, "{\"coalesced\":true,\"refreshInProgress\":false,\"refreshed\":false,\"lastSyncAt\":2000}", .{});
    try std.testing.expect(!refreshWaiting(released));
    try std.testing.expect(refreshIsCurrent(released, 1500));
    const old = try std.json.parseFromSliceLeaky(Value, allocator, "{\"coalesced\":true,\"refreshInProgress\":false,\"refreshed\":false,\"lastSyncAt\":1000}", .{});
    try std.testing.expect(!refreshWaiting(old));
    try std.testing.expect(!refreshIsCurrent(old, 1500));
    const owned = try std.json.parseFromSliceLeaky(Value, allocator, "{\"coalesced\":false,\"refreshInProgress\":false,\"refreshed\":true,\"lastSyncAt\":2000}", .{});
    try std.testing.expect(!refreshWaiting(owned));
    try std.testing.expect(refreshIsCurrent(owned, 1500));
}

test "compact reader envelope preserves recipients without doubled blank segments" {
    const allocator = std.testing.allocator;
    const to = "Alex <alex@example.com>, Sam <sam@example.net>";
    const no_cc = try readerEnvelope(allocator, to, "", "2026-10-05 12:00 UTC");
    defer allocator.free(no_cc);
    try std.testing.expectEqualStrings("To: Alex <alex@example.com>, Sam <sam@example.net>\n2026-10-05 12:00 UTC", no_cc);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, no_cc, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, no_cc, "\n"));
    const with_cc = try readerEnvelope(allocator, to, "Team <team@example.org>", "2026-10-05 12:00 UTC");
    defer allocator.free(with_cc);
    try std.testing.expectEqualStrings("To: Alex <alex@example.com>, Sam <sam@example.net>\nCc: Team <team@example.org>\n2026-10-05 12:00 UTC", with_cc);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, with_cc, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, with_cc, "\n"));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const injected = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"bodyCacheError\":\"provider private text \\u001b]52\"}", .{});
    try std.testing.expectEqualStrings("BodyUnavailable", bodyRefusal(injected).?);
}

test "persisted selected body refusal remains local and does not mark mailbox offline" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{ .behavior = .miss };
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{ .allocate = .alloc_always }));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\",\"subject\":\"Refused fictional body\",\"snippet\":\"Safe cached snippet\",\"bodyCacheError\":\"BodySizeMismatch\"}],\"cached\":true,\"cacheReady\":true}}");
    app.sync[0].state = .current;
    try app.preview(false);
    try std.testing.expect(app.body_cache_miss);
    try std.testing.expectEqualStrings("BodySizeMismatch", bodyRefusal(app.selectedMessage().?).?);
    try std.testing.expect(!app.pending_read);
    try std.testing.expect(app.job.future == null);
    try std.testing.expectEqual(SyncState.current, app.sync[0].state);
    try app.preview(true);
    try std.testing.expect(app.job.future == null);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
    client.behavior = .transient;
    client.local_calls = 0;
    try app.preview(false);
    try std.testing.expect(!app.body_cache_miss);
    try std.testing.expectEqualStrings("Local full body", text(get(app.thread[0], "bodyText")));
    try std.testing.expectEqual(SyncState.current, app.sync[0].state);
}

test "HTML reader provenance prefers plain and recognizes only exact legacy conversion" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const parse = struct {
        fn value(a: Allocator, raw: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
        }
    }.value;
    const plain = try parse(arena.allocator(), "{\"bodySource\":\"plain\",\"bodyText\":\"Real plain part\",\"bodyHtml\":\"<b>Different HTML</b>\"}");
    try std.testing.expect(!app.htmlEligible(plain));
    const explicit_html = try parse(arena.allocator(), "{\"bodySource\":\"html\",\"bodyText\":\"Legacy\",\"bodyHtml\":\"<p><b>Legacy</b></p>\"}");
    try std.testing.expect(app.htmlEligible(explicit_html));
    const legacy = try parse(arena.allocator(), "{\"bodyText\":\"Legacy\",\"bodyHtml\":\"<p><b>Legacy</b></p>\"}");
    try std.testing.expect(app.htmlEligible(legacy));
    const uncertain = try parse(arena.allocator(), "{\"bodySource\":\"unknown\",\"bodyText\":\"Independently supplied plain text\",\"bodyHtml\":\"<p><b>Legacy</b></p>\"}");
    try std.testing.expect(!app.htmlEligible(uncertain));
    const changed_whitespace = try parse(arena.allocator(), "{\"bodySource\":\"unknown\",\"bodyText\":\"A B\",\"bodyHtml\":\"<pre>A\\tB</pre>\"}");
    try std.testing.expect(!app.htmlEligible(changed_whitespace));
    app.accounts = items(try parse(app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]"));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}],\"cached\":true,\"cacheReady\":true}}");
    try app.replaceReader(false, "{\"ok\":true,\"data\":{\"id\":\"a\",\"bodySource\":\"html\",\"bodyText\":\"Styled body\",\"bodyHtml\":\"<p><b>Styled body</b></p>\"}}", true);
    try std.testing.expectEqual(@as(u64, 0), app.html_stats.htmlDocumentBuilds);
    try std.testing.expect(!app.markup[0].attempted and app.markup[0].prepared == null);
    app.prepareVisibleMarkup(&app.markup[0], app.thread[0]);
    try std.testing.expectEqual(@as(u64, 1), app.html_stats.htmlDocumentBuilds);
    try std.testing.expect(app.markup[0].attempted and app.markup[0].prepared != null);
    app.prepareVisibleMarkup(&app.markup[0], app.thread[0]);
    try std.testing.expectEqual(@as(u64, 1), app.html_stats.htmlDocumentBuilds);
    app.clearReader();
    try std.testing.expectEqual(@as(usize, 0), app.markup.len);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "reader end paints the last full viewport without a second key" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 40, .rows = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 10, .screen = &screen };
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}]}}");
    try app.replaceReader(false, "{\"ok\":true,\"data\":{\"id\":\"a\",\"subject\":\"Fixture\",\"bodyText\":\"0\\n1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\nTAIL-FIXTURE\"}}", true);
    try app.readerDraw(win);
    try std.testing.expectEqual(@as(usize, 10), app.reader_height); // Short reader spends no row on repeated key hints.
    app.focus = .reader;
    try app.move(true, std.math.maxInt(usize));
    try std.testing.expectEqual(readerEnd(app.reader_lines, app.reader_height), app.reader_scroll);
    screen.clear();
    try app.readerDraw(win);
    var tail_seen = false;
    for (1..screen.height) |row| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        for (0..screen.width) |col| try line.appendSlice(allocator, screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
        tail_seen = tail_seen or std.mem.indexOf(u8, line.items, "TAIL-FIXTURE") != null;
    }
    try std.testing.expect(tail_seen);
    app.reader_scroll = std.math.maxInt(usize); // Old out-of-range state clamps before painting.
    screen.clear();
    try app.readerDraw(win);
    try std.testing.expectEqual(readerEnd(app.reader_lines, app.reader_height), app.reader_scroll);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "wide account identity and plain reader replace prior layout cells" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(allocator, .{ .cols = 160, .rows = 36, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(allocator);
    app.vx = &vx;
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"123456789@example.com\"}]", .{}));
    const navigation_width = try app.navigationWidth(vx.window());
    try std.testing.expectEqual(@as(usize, 21), app.account().len);
    try std.testing.expectEqual(@as(u16, 27), navigation_width);
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\",\"subject\":\"Fictional subject\"}]}}");
    try app.replaceReader(false, "{\"ok\":true,\"data\":{\"id\":\"a\",\"subject\":\"Fictional subject\",\"bodyText\":\"Plain fictional text without any bars.\"}}", true);
    app.mode = .compose;
    try app.compose.fields[4].set(allocator, "Old composer caret");
    try app.draw();
    app.mode = .browse;
    app.reader_layout = .below;
    try app.draw();
    app.reader_layout = .right;
    const panes = layout.computeWithNavigation(160, 32, .list, .right, false, navigation_width);
    const rect = panes.reader.?;
    // A synthetic old border/caret anywhere in the new reader must clear.
    for (3..rect.height) |row| for (rect.x + 2..rect.x + rect.width - 2) |col| {
        vx.screen.writeCell(@intCast(col), @intCast(row + 2), .{ .char = .{ .grapheme = "│", .width = 1 } });
    };
    try app.draw();
    for (3..rect.height) |row| for (rect.x + 2..rect.x + rect.width - 2) |col| {
        const grapheme = vx.screen.readCell(@intCast(col), @intCast(row + 2)).?.char.grapheme;
        try std.testing.expect(!same(grapheme, "│") and !same(grapheme, "|") and !same(grapheme, "▏"));
    };
    var account_line: std.ArrayList(u8) = .empty;
    defer account_line.deinit(allocator);
    for (2..navigation_width - 2) |col| try account_line.appendSlice(allocator, vx.screen.readCell(@intCast(col), 4).?.char.grapheme);
    try std.testing.expectEqualStrings("> 123456789@example.com", account_line.items);
    try std.testing.expectEqual(layout.HitKind.account, app.mouse_hits.at(24, 4).?.kind);
    try std.testing.expect(app.mouse_hits.at(24, 5) == null);
    const mail_x: i16 = @intCast(panes.list.?.x + 2);
    try std.testing.expectEqual(layout.HitKind.mail, app.mouse_hits.at(mail_x, 3).?.kind);
    try std.testing.expectEqual(layout.HitKind.mail, app.mouse_hits.at(mail_x, 4).?.kind);
    try std.testing.expectEqual(layout.HitKind.mail_scroll, app.mouse_hits.at(mail_x, 5).?.kind);
    try std.testing.expectEqual(layout.HitKind.reader, app.mouse_hits.at(@intCast(rect.x + 2), 5).?.kind);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "local UI: exact width and wrapped account identities occupy only their visible hit rows" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 32, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 32, .height = 24, .screen = &screen };
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"alex.demo@long-company.example\"},{\"address\":\"morgan.example@long-company-exampl.example\"},{\"address\":\"optional@example.com\"}]", .{}));
    try app.navigationDraw(win);
    const expected = [_]struct { address: []const u8, row: usize }{
        .{ .address = "alex.demo@long-company.example", .row = 1 },
        .{ .address = "morgan.example@long-company-exampl.example", .row = 2 },
        .{ .address = "optional@example.com", .row = 4 },
    };
    for (expected) |account_value| for (account_value.address, 0..) |byte, index| {
        try std.testing.expectEqualStrings(&.{byte}, screen.readCell(@intCast(2 + index % 30), @intCast(account_value.row + index / 30)).?.char.grapheme);
    };
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 3).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 3).?.char.grapheme);
    try std.testing.expectEqual(@as(usize, 0), app.mouse_hits.at(2, 1).?.index);
    try std.testing.expectEqual(@as(usize, 1), app.mouse_hits.at(2, 2).?.index);
    try std.testing.expectEqual(@as(usize, 1), app.mouse_hits.at(2, 3).?.index);
    try std.testing.expectEqual(@as(usize, 2), app.mouse_hits.at(2, 4).?.index);
    try std.testing.expect(app.mouse_hits.at(2, 5) == null);
    for ("MAILBOXES", 0..) |byte, column| try std.testing.expectEqualStrings(&.{byte}, screen.readCell(@intCast(column), 6).?.char.grapheme);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "compose attachments: compact list shows file sizes and scrolls to all sixteen removal targets" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 70, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 70, .height = 12, .screen = &screen };
    var attachments: [16]types.Attachment = undefined;
    for (&attachments, 0..) |*attachment, index| attachment.* = .{ .id = "", .filename = if (index == 15) "final report.pdf" else "fixture.txt", .size = if (index == 15) 1536 else 12, .data = "Zml4dHVyZQ" };
    try app.compose.replaceAttachments(allocator, &attachments);
    app.mode = .compose;
    try app.composeAttachmentsDraw(win, 5, 3);
    try std.testing.expectEqual(layout.HitKind.compose_attachment_add, app.mouse_hits.at(65, 5).?.kind);
    try std.testing.expectEqual(layout.HitKind.compose_attachment_remove, app.mouse_hits.at(68, 6).?.kind);
    try std.testing.expectEqual(@as(usize, 0), app.mouse_hits.at(68, 6).?.index);
    for (0..20) |_| try app.onMouse(.{ .col = 2, .row = 7, .button = .wheel_down, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 13), app.compose.attachment_scroll);
    app.mouse_hits.clear();
    screen.clear();
    try app.composeAttachmentsDraw(win, 5, 3);
    try std.testing.expectEqual(@as(usize, 15), app.mouse_hits.at(68, 8).?.index);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    for (0..screen.height) |row| for (0..screen.width) |col| try rendered.appendSlice(allocator, screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "16. final report.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "1.5 KiB") != null);
    try app.onMouse(.{ .col = 68, .row = 8, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 15), app.compose.attachments.len);
    try std.testing.expectEqual(@as(usize, 12), app.compose.attachment_scroll);
    try app.onMouse(.{ .col = 65, .row = 5, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expectEqual(Mode.attachment, app.mode);
    try std.testing.expectEqual(Mode.compose, app.previous_mode);
    try std.testing.expect(app.job.future == null and !app.quit);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "compose attachments: protected recovery and pending writes block local attachment edits" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.mode = .compose;
    try app.compose.replaceAttachments(allocator, &.{.{ .id = "", .filename = "keep.txt", .size = 4, .data = "a2VlcA" }});
    app.compose.unknown_outcome = true;
    try app.detachAttachment(0);
    try app.attachFile("/path/that/must/not/be/opened");
    try app.promptAttachment();
    try std.testing.expectEqual(@as(usize, 1), app.compose.attachments.len);
    try std.testing.expectEqual(Mode.compose, app.mode);
    app.compose.unknown_outcome = false;
    app.job.kind = .save;
    app.job.future = .{ .any_future = null, .result = {} }; // A present completed job is sufficient for this guard.
    defer app.job.future = null;
    try app.detachAttachment(0);
    try app.attachFile("/path/that/must/not/be/opened");
    try app.promptAttachment();
    try std.testing.expectEqualStrings("keep.txt", app.compose.attachments[0].filename);
    try std.testing.expectEqual(Mode.compose, app.mode);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "compose attachments: complete composer handles the three-file viewport without integer narrowing" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    app.mode = .compose;
    try app.compose.fields[4].set(allocator, "Body space remains available\nSecond line\nThird line\nFourth line\nFifth line");
    try app.compose.replaceAttachments(allocator, &.{
        .{ .id = "", .filename = "first.txt", .size = 4, .data = "T25lCg" },
        .{ .id = "", .filename = "second.bin", .size = 128, .data = "AA" },
        .{ .id = "", .filename = "third.pdf", .size = 15, .data = "JVBERg" },
    });
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 160, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 160, .height = 40, .screen = &screen };
    try app.composeDraw(win);
    try std.testing.expectEqual(@as(usize, 3), app.compose.attachment_height);
    var removal_targets: usize = 0;
    var body_height: usize = 0;
    for (app.mouse_hits.areas[0..app.mouse_hits.count]) |hit| {
        if (hit.kind == .compose_attachment_remove) removal_targets += 1;
        if (hit.kind == .compose_field and hit.index == 4) body_height = hit.rect.height;
    }
    try std.testing.expectEqual(@as(usize, 3), removal_targets);
    try std.testing.expect(body_height >= 5);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "compose attachments: reply draft roundtrip preserves recipients threading body and remaining file" {
    const allocator = std.testing.allocator;
    var compose: Compose = .{};
    defer compose.deinit(allocator);
    try compose.fields[0].set(allocator, "alex@example.test");
    try compose.fields[1].set(allocator, "team@example.test");
    try compose.fields[3].set(allocator, "Re: Fictional report");
    try compose.fields[4].set(allocator, "Draft text after an editor save");
    try compose.id.set(allocator, "local-draft");
    try compose.thread.set(allocator, "fictional-thread");
    try compose.reply.set(allocator, "<fictional-message@example.test>");
    try compose.replaceAttachments(allocator, &.{.{ .id = "", .filename = "report.txt", .size = 6, .data = "cmVwb3J0" }});
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const draft_value = try compose.draft(arena.allocator());
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), draft_value, .{});
    const parsed = try std.json.parseFromSliceLeaky(Value, arena.allocator(), encoded, .{ .allocate = .alloc_always });
    var reopened: Compose = .{};
    defer reopened.deinit(allocator);
    try reopened.load(allocator, parsed);
    try std.testing.expectEqualStrings("alex@example.test", reopened.fields[0].value());
    try std.testing.expectEqualStrings("team@example.test", reopened.fields[1].value());
    try std.testing.expectEqualStrings("Draft text after an editor save", reopened.fields[4].value());
    try std.testing.expectEqualStrings("fictional-thread", reopened.thread.value());
    try std.testing.expectEqualStrings("<fictional-message@example.test>", reopened.reply.value());
    try std.testing.expectEqualStrings("report.txt", reopened.attachments[0].filename);
    try std.testing.expectEqualStrings("cmVwb3J0", reopened.attachments[0].data);
}

test "composer workflow: incomplete recipients recover without becoming a sendable draft" {
    const allocator = std.testing.allocator;
    var compose: Compose = .{};
    defer compose.deinit(allocator);
    try compose.fields[0].set(allocator, "alex@");
    try compose.fields[3].set(allocator, "Unfinished subject");
    try compose.fields[4].set(allocator, "Unfinished body survives restart");
    try compose.from.set(allocator, "alias@example.test");
    try compose.from_name.set(allocator, "Fictional Alias");
    try compose.replaceAttachments(allocator, &.{.{ .id = "", .filename = "notes.txt", .size = 5, .data = "bm90ZXM" }});
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var fields: [5][]const u8 = undefined;
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), compose.recovery(&fields), .{});
    const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), encoded, .{ .allocate = .alloc_always });
    var reopened: Compose = .{};
    defer reopened.deinit(allocator);
    try reopened.load(allocator, value);
    try std.testing.expectEqualStrings("alex@", reopened.fields[0].value());
    try std.testing.expectEqualStrings("Unfinished body survives restart", reopened.fields[4].value());
    try std.testing.expectEqualStrings("alias@example.test", reopened.from.value());
    try std.testing.expectEqualStrings("notes.txt", reopened.attachments[0].filename);
    try std.testing.expectError(error.InvalidAddress, reopened.draft(arena.allocator()));
    try reopened.fields[0].set(allocator, "alex@example.test");
    const validated = try reopened.draft(arena.allocator());
    try std.testing.expect(validated.recoveryFields == null);
    try std.testing.expectEqualStrings("alex@example.test", validated.to[0].address);
}

test "composer workflow: delayed autosave result retains newer edits and insertion context" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.mode = .compose;
    app.compose_active = true;
    app.compose.insert_mode = true;
    app.compose.selected = 4;
    app.compose.revision = 3;
    app.autosave_revision = 2;
    try app.compose.fields[4].set(allocator, "Newer text typed while snapshot was saving");
    try app.apply(.autosave, "{\"ok\":true,\"data\":{\"id\":\"recovered-local-draft\",\"bodyText\":\"Older snapshot\"}}");
    try std.testing.expectEqualStrings("Newer text typed while snapshot was saving", app.compose.fields[4].value());
    try std.testing.expectEqual(@as(u64, 2), app.compose.saved_revision);
    try std.testing.expectEqual(@as(u64, 3), app.compose.revision);
    try std.testing.expectEqual(Mode.compose, app.mode);
    try std.testing.expect(app.compose.insert_mode);
    try std.testing.expectEqual(@as(usize, 4), app.compose.selected);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "composer workflow: cached completion replaces one recipient and preserves later recipients" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.contacts_account.set(allocator, app.account());
    app.contacts = items(try std.json.parseFromSliceLeaky(Value, app.contact_arena.allocator(), "[{\"name\":\"Alex\",\"emails\":[{\"address\":\"alex@example.test\"}]},{\"name\":\"Alice\",\"emails\":[{\"address\":\"alice@example.test\"}]}]", .{}));
    app.mode = .compose;
    app.compose.insert_mode = true;
    try app.compose.fields[0].set(allocator, "al, last@example.test");
    app.compose.fields[0].cursor = 2;
    try app.onComposeKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try app.onComposeKey(.{ .codepoint = Key.enter });
    try std.testing.expectEqualStrings("alice@example.test, last@example.test", app.compose.fields[0].value());
    try std.testing.expectEqual(@as(u64, 1), app.compose.revision);
    try std.testing.expect(app.job.future == null);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "composer workflow: verified alias cycling replaces generated signatures and preserves files" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.compose.from.set(allocator, app.account());
    try app.compose.replaceAttachments(allocator, &.{.{ .id = "", .filename = "retain.txt", .size = 4, .data = "a2VlcA" }});
    try app.replaceIdentities("{\"ok\":true,\"data\":{\"identities\":[{\"address\":\"personal@example.test\",\"name\":\"Personal\",\"signature\":\"Primary signature\"},{\"address\":\"alias@example.test\",\"name\":\"Alias\",\"signature\":\"Alias signature\"}]}}");
    try app.cycleComposeIdentity();
    try std.testing.expectEqualStrings("alias@example.test", app.compose.from.value());
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Alias signature") != null);
    try app.cycleComposeIdentity();
    try std.testing.expectEqualStrings("personal@example.test", app.compose.from.value());
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Primary signature") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Alias signature") == null);
    try std.testing.expectEqualStrings("retain.txt", app.compose.attachments[0].filename);
    try std.testing.expect(app.job.future == null);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "composer workflow: reopening a draft does not inject a signature or duplicate its exact known footer" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    app.compose_active = true;
    app.mode = .compose;
    try app.compose.from.set(allocator, app.account());
    const existing = "\n\n-- \nPrimary signature\n\nQuoted fictional body";
    try app.compose.fields[4].set(allocator, existing);
    try app.apply(.identities, "{\"ok\":true,\"data\":{\"identities\":[{\"address\":\"personal@example.test\",\"signature\":\"Primary signature\"},{\"address\":\"alias@example.test\",\"signature\":\"Alias signature\"}]}}");
    try std.testing.expectEqualStrings(existing, app.compose.fields[4].value());
    try std.testing.expectEqual(@as(u64, 0), app.compose.revision);
    try app.cycleComposeIdentity();
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Primary signature") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Alias signature") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Quoted fictional body") != null);
}

test "composer workflow: alias signatures stay below typed reply text and preserve manual edits" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    app.compose.new_draft = true;
    try app.compose.fields[4].set(allocator, "\n\n> Original fictional text");
    try app.setComposeSignature("Primary signature");
    app.compose.fields[4].cursor = 0;
    try app.compose.fields[4].insert(allocator, "Thanks for the report.", types.Limits.body_bytes);
    try app.setComposeSignature("Alias signature");
    try std.testing.expect(std.mem.startsWith(u8, app.compose.fields[4].value(), "Thanks for the report.\n\n-- \nAlias signature\n\n"));
    try std.testing.expect(std.mem.endsWith(u8, app.compose.fields[4].value(), "> Original fictional text"));
    try std.testing.expect(std.mem.indexOf(u8, app.compose.fields[4].value(), "Primary signature") == null);
    try app.compose.fields[4].set(allocator, "Thanks.\n\n-- \nManually edited signature\n\n> Original fictional text");
    try app.setComposeSignature("Another default signature");
    try std.testing.expectEqualStrings("Thanks.\n\n-- \nManually edited signature\n\n> Original fictional text", app.compose.fields[4].value());
    try std.testing.expect(app.compose.signature_custom);
}

test "local UI: help aligns colored bindings and keeps the last instructions reachable when narrow" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 90, .rows = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 84, .height = 60, .screen = &screen };
    const wide_lines = try app.helpContent(win, 0, true);
    try std.testing.expectEqualStrings("j", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("M", screen.readCell(28, 1).?.char.grapheme);
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = app.palette.cyan }, screen.readCell(0, 1).?.style.fg));
    try std.testing.expect(vaxis.Color.eql(.{ .rgb = app.palette.foreground }, screen.readCell(28, 1).?.style.fg));
    win.width = 28;
    win.height = 8;
    screen.clear();
    const narrow_lines = try app.helpContent(win, 0, false);
    try std.testing.expect(narrow_lines > wide_lines);
    _ = try app.helpContent(win, narrow_lines - win.height, true);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    for (0..win.height) |row| {
        for (0..win.width) |column| try rendered.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "startup.") != null);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "reader tail remains visible in the resize frame after reduced wrapping" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 80, .rows = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 6, .screen = &screen };
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}]}}");
    var body: [2020]u8 = @splat('x');
    const tail = "TAIL-REFLOW-FIXTURE";
    @memcpy(body[body.len - tail.len ..], tail);
    const response = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true, .data = .{ .id = "a", .subject = "Fixture", .bodyText = @as([]const u8, &body) } }, .{});
    defer allocator.free(response);
    try app.replaceReader(false, response, true);
    try app.readerDraw(win);
    const original_lines = app.reader_lines;
    app.focus = .reader;
    try app.move(true, std.math.maxInt(usize));
    try std.testing.expect(app.reader_scroll > 100);
    win.width = 80;
    win.height = 20;
    screen.clear();
    try app.readerDraw(win);
    try std.testing.expect(app.reader_lines < original_lines);
    try std.testing.expectEqual(readerEnd(app.reader_lines, app.reader_height), app.reader_scroll);
    var tail_seen = false;
    for (1..screen.height) |row| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        for (0..screen.width) |col| try line.appendSlice(allocator, screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
        tail_seen = tail_seen or std.mem.indexOf(u8, line.items, tail) != null;
    }
    try std.testing.expect(tail_seen);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "mouse selects cached mail and respects disabled release and confirmation boundaries" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"},{\"id\":\"b\"}]}}");
    app.mouse_hits.add(.{ .x = 30, .y = 6, .width = 40, .height = 2 }, .mail, 1);
    const click: vaxis.Mouse = .{ .col = 35, .row = 7, .button = .left, .mods = .{}, .type = .press };
    app.options.no_mouse = true;
    try app.onMouse(click);
    try std.testing.expectEqual(@as(usize, 0), app.selected);
    app.options.no_mouse = false;
    var released = click;
    released.type = .release;
    try app.onMouse(released);
    try std.testing.expectEqual(@as(usize, 0), app.selected);
    app.mode = .trash_confirm;
    try app.onMouse(click);
    try std.testing.expectEqual(@as(usize, 0), app.selected);
    try std.testing.expectEqual(Mode.trash_confirm, app.mode);
    app.mode = .browse;
    try app.onMouse(click);
    try std.testing.expectEqual(@as(usize, 1), app.selected);
    try std.testing.expectEqual(Focus.list, app.focus);
    try std.testing.expectEqualStrings("Local full body", text(get(app.thread[0], "bodyText")));
    app.mouse_hits.add(.{ .x = 80, .y = 3, .width = 40, .height = 20 }, .reader, 0);
    app.reader_lines = 100;
    app.reader_height = 20;
    try app.onMouse(.{ .col = 90, .row = 5, .button = .wheel_down, .mods = .{}, .type = .press });
    try std.testing.expectEqual(Focus.reader, app.focus);
    try std.testing.expectEqual(@as(usize, 3), app.reader_scroll);
    try std.testing.expectEqual(@as(usize, 1), app.selected);
    try std.testing.expect(app.job.future == null and !app.quit);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "mouse wheel: pane gaps do not select mail and reader controls still scroll" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"},{\"id\":\"d\"}]}}");
    app.mouse_hits.add(.{ .x = 30, .y = 3, .width = 40, .height = 20 }, .mail_scroll, 0);
    const click: vaxis.Mouse = .{ .col = 35, .row = 5, .button = .left, .mods = .{}, .type = .press };
    try app.onMouse(click);
    try std.testing.expectEqual(@as(usize, 0), app.selected);
    var wheel = click;
    wheel.button = .wheel_down;
    try app.onMouse(wheel);
    try std.testing.expectEqual(@as(usize, 3), app.selected);
    try std.testing.expectEqual(Focus.list, app.focus);
    wheel.button = .wheel_up;
    try app.onMouse(wheel);
    try std.testing.expectEqual(@as(usize, 0), app.selected);
    app.reader_lines = 100;
    app.reader_height = 20;
    for ([_]layout.HitKind{ .reader_thread, .reader_link, .reader_attachment }) |kind| {
        app.mouse_hits.clear();
        app.mouse_hits.add(.{ .x = 80, .y = 3, .width = 40, .height = 20 }, kind, 0);
        try app.onMouse(.{ .col = 90, .row = 5, .button = .wheel_down, .mods = .{}, .type = .press });
    }
    try std.testing.expectEqual(@as(usize, 9), app.reader_scroll);
    try std.testing.expectEqual(Focus.reader, app.focus);
    try std.testing.expectEqual(ReaderOverlay.none, app.reader_overlay);
    try std.testing.expectEqual(@as(usize, 0), app.selected);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "mouse contact actions open local details or preserve recipient picker draft without writes" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{ .behavior = .contacts };
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    try app.prepareContacts("");
    app.mouse_hits.add(.{ .x = 2, .y = 5, .width = 76, .height = 2 }, .contact, 1);
    const click: vaxis.Mouse = .{ .col = 5, .row = 6, .button = .left, .mods = .{}, .type = .press };
    const expected_name = text(get(app.contacts[1], "name"));
    const expected_email = text(get(items(get(app.contacts[1], "emails"))[0], "address"));
    try app.onMouse(click);
    try std.testing.expectEqual(Mode.contact_edit, app.mode);
    try std.testing.expectEqualStrings(expected_name, app.contact_name.value());
    try std.testing.expectEqualStrings(expected_email, app.contact_email.value());
    app.mode = .contacts;
    app.picker = true;
    app.compose_active = true;
    app.compose.selected = 1;
    try app.compose.fields[4].set(allocator, "Unsent body retained");
    try app.onMouse(click);
    try std.testing.expectEqual(Mode.compose, app.mode);
    try std.testing.expectEqualStrings(expected_email, app.compose.fields[1].value());
    try std.testing.expectEqualStrings("Unsent body retained", app.compose.fields[4].value());
    try std.testing.expect(app.job.future == null and !app.quit);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "mouse reporting uses cells disables idle motion and restores through suspend" {
    const allocator = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.caps = .{ .sgr_pixels = true };
    vx.state = .{};
    var writer: Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try setMouseReporting(&vx, &writer.writer, true);
    try std.testing.expect(vx.state.mouse and !vx.state.pixel_mouse and vx.caps.sgr_pixels);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "1016h") == null);
    try std.testing.expect(std.mem.endsWith(u8, writer.written(), "\x1b[?1003l\x1b[?1002h"));
    try setMouseReporting(&vx, &writer.writer, false);
    try std.testing.expect(!vx.state.mouse and !vx.state.pixel_mouse);
    try std.testing.expect(std.mem.endsWith(u8, writer.written(), "\x1b[?1002;1003;1004;1006;1016l"));
    try setMouseReporting(&vx, &writer.writer, true);
    try std.testing.expect(vx.state.mouse and !vx.state.pixel_mouse);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, writer.written(), "\x1b[?1003l"));
}

test "local reader: collapsed thread navigation keeps focused reply identity without provider calls" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}]}}");
    try app.replaceReader(true, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\",\"subject\":\"FIRST-OPEN\",\"bodyText\":\"Fresh answer\\n> QUOTED-HISTORY\\n-- \\nSIGNATURE-TAIL\",\"unread\":true},{\"id\":\"b\",\"subject\":\"SECOND-CLOSED\",\"bodyText\":\"Other message\"}]}}", true);
    try std.testing.expect(app.reader_cards[0] and !app.reader_cards[1]);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 80, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 30, .screen = &screen };
    app.focus = .reader;
    app.fold_quotes = true;
    app.fold_signatures = true;
    _ = try app.readerBodyDraw(win);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    for (0..win.height) |row| for (0..win.width) |column| try rendered.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "FIRST-OPEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "SECOND-CLOSED") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "QUOTED-HISTORY") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "SIGNATURE-TAIL") == null);
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = '}' }));
    try std.testing.expectEqualStrings("b", app.readerReplyId());
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = 't' }));
    try std.testing.expect(app.reader_cards[1]);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "local reader: same thread replacement preserves focused identity folds and scroll across ordering" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"m093\"}]}}");
    const initial = "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"m091\",\"bodyText\":\"First\"},{\"id\":\"m092\",\"bodyText\":\"Second\"},{\"id\":\"m093\",\"bodyText\":\"Selected\"}]}}";
    try app.replaceReader(true, initial, true);
    app.focus = .reader;
    app.reader_card = 1;
    app.reader_cards[0] = true;
    app.reader_cards[1] = false;
    app.reader_cards[2] = true;
    app.reader_scroll = 17;
    app.reader_anchor_card = false;
    app.reader_card_pinned = true;
    // The originally selected m093 comes after focused m092. A later row
    // must never overwrite the user's focused card while refreshing it.
    try app.replaceReader(true, initial, false);
    try std.testing.expectEqualStrings("m092", app.readerReplyId());
    try std.testing.expectEqual(@as(usize, 1), app.reader_card);
    try std.testing.expect(app.reader_cards[0] and !app.reader_cards[1] and app.reader_cards[2]);
    try std.testing.expectEqual(@as(usize, 17), app.reader_scroll);
    try std.testing.expect(!app.reader_anchor_card and app.reader_card_pinned);
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = 't' }));
    try std.testing.expect(app.reader_cards[1]);
    app.reader_cards[0] = false;
    app.reader_scroll = 23;
    app.reader_anchor_card = false;
    // Match folds/focus by identity rather than carrying an old array index.
    try app.replaceReader(true, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"m092\"},{\"id\":\"m093\"},{\"id\":\"m091\"}]}}", true);
    try std.testing.expectEqualStrings("m092", app.readerReplyId());
    try std.testing.expectEqual(@as(usize, 0), app.reader_card);
    try std.testing.expect(app.reader_cards[0] and app.reader_cards[1] and !app.reader_cards[2]);
    try std.testing.expectEqual(@as(usize, 23), app.reader_scroll);
    // If the focused ID disappeared, the original selected message remains
    // the fallback; preserving by ID does not pin a stale numeric index.
    try app.replaceReader(true, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"m091\"},{\"id\":\"m093\"}]}}", false);
    try std.testing.expectEqualStrings("m093", app.readerReplyId());
    try std.testing.expectEqual(@as(usize, 1), app.reader_card);
    try std.testing.expect(!app.reader_cards[0] and app.reader_cards[1]);
    try std.testing.expectEqual(@as(usize, 23), app.reader_scroll);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "local reader: per account context restoration and key remaps leave text modes alone" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"},{\"address\":\"work@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"},{\"id\":\"b\"}]}}");
    app.selected = 1;
    app.reader_scroll = 14;
    app.folder = 1;
    app.rememberWorkingContext();
    app.account_index = 1;
    app.selected = 0;
    app.folder = 0;
    app.account_index = 0;
    try app.restoreWorkingContext();
    try std.testing.expectEqual(@as(usize, 1), app.folder);
    try std.testing.expectEqualStrings("b", app.restore_message.value());
    try std.testing.expectEqual(@as(?usize, 14), app.restore_reader_scroll);
    const body = "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24\n25\n26\n27\n28\n29\n30\n31\n32\n33\n34\n35\n36\n37\n38\n39";
    const response = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true, .data = .{ .id = "b", .bodyText = body } }, .{});
    defer allocator.free(response);
    try app.replaceReader(false, response, true);
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 60, .rows = 15, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 15, .screen = &screen };
    try app.readerDraw(win);
    try std.testing.expectEqual(@as(usize, 14), app.reader_scroll);
    var binding: preferences.Binding = .{ .action = .down };
    try binding.key.set("n");
    app.ui_preferences.bindings[0] = binding;
    try std.testing.expectEqual(@as(u21, 'j'), app.normalizeBrowseKey(.{ .codepoint = 'n' }).codepoint);
    app.mode = .compose;
    try std.testing.expectEqual(@as(u21, 'n'), app.normalizeBrowseKey(.{ .codepoint = 'n' }).codepoint);
    app.mode = .browse;
    app.reader_overlay = .save_attachment;
    try std.testing.expectEqual(@as(u21, 'n'), app.normalizeBrowseKey(.{ .codepoint = 'n' }).codepoint);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "local reader: received attachment picker retains every item and freezes prompted identity" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", home);
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.environ = &environment;
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"}]}}");
    try app.replaceReader(true, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\",\"attachments\":[{\"id\":\"one\",\"filename\":\"one.txt\",\"size\":12},{\"id\":\"two\",\"filename\":\"two.pdf\",\"size\":33}]},{\"id\":\"b\",\"attachments\":[{\"id\":\"three\",\"filename\":\"three.txt\",\"size\":42}]}]}}", true);
    try std.testing.expectEqual(@as(usize, 3), app.readerAttachmentCount());
    app.openReaderAttachments();
    app.reader_choice = 2;
    try app.readerAttachmentPrompt(false);
    try std.testing.expectEqualStrings("b", app.reader_attachment_message.value());
    try std.testing.expectEqualStrings("three", app.reader_attachment_id.value());
    app.reader_choice = 0;
    try std.testing.expectEqualStrings("three.txt", app.reader_attachment_name.value());
    try std.testing.expect(std.mem.endsWith(u8, app.reader_path.value(), "/Downloads/three.txt"));
    _ = try app.onReaderOverlayKey(.{ .codepoint = 'u', .mods = .{ .ctrl = true } });
    _ = try app.onReaderOverlayKey(.{ .codepoint = 'q', .text = "q" });
    try std.testing.expectEqualStrings("q", app.reader_path.value());
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "composer polish: body focus From action and attachment spacing match real input state" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    app.mode = .compose;
    app.compose.selected = 4;
    try app.compose.replaceAttachments(allocator, &.{.{ .id = "", .filename = "report.txt", .size = 29, .data = "eA" }});
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &screen };
    try app.composeDraw(win);
    try std.testing.expect(!screen.readCell(2, 1).?.style.bold); // From is plain.
    var body_selected = false;
    var gap_seen = false;
    for (0..screen.height) |row| {
        var text_row: std.ArrayList(u8) = .empty;
        defer text_row.deinit(allocator);
        for (0..screen.width) |column| try text_row.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
        if (std.mem.indexOf(u8, text_row.items, "Body:") != null) {
            body_selected = screen.readCell(2, @intCast(row)).?.style.bold;
            try std.testing.expectEqualDeep(app.style(.selected).bg, screen.readCell(70, @intCast(row)).?.style.bg);
        }
        gap_seen = gap_seen or std.mem.indexOf(u8, text_row.items, "29 B [x]") != null;
        try std.testing.expect(std.mem.indexOf(u8, text_row.items, "i Insert") == null);
    }
    try std.testing.expect(body_selected and gap_seen);
    app.reader_lines = 100;
    app.reader_height = 20;
    try app.onComposeKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(usize, 10), app.reader_scroll);
    app.compose.insert_mode = true;
    try app.onComposeKey(.{ .codepoint = 'L', .text = "L" });
    try app.onComposeKey(.{ .codepoint = 'B', .text = "B" });
    try std.testing.expectEqualStrings("LB", app.compose.fields[4].value());
    try std.testing.expectEqual(ReaderOverlay.none, app.reader_overlay);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "composer polish: saved file open intent has durable success and failure results" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.options.fixtures = true;
    app.mode = .compose;
    app.job.saved_attachment_open = true;
    app.sayAction(false, "Saved attachment", .{});
    try app.apply(.open, "{\"ok\":true,\"data\":{\"fixture\":true,\"opened\":false}}");
    try std.testing.expectEqualStrings("Attachment saved · mock file-open validated", app.status[0..app.status_len]);
    try std.testing.expectEqual(Mode.compose, app.mode);
    app.say(false, "Draft saved locally", .{});
    try std.testing.expectEqualStrings("Attachment saved · mock file-open validated", app.status[0..app.status_len]);
    app.job.saved_attachment_open = true;
    try app.apply(.open, "{\"ok\":false,\"error\":{\"code\":\"FileNotFound\"}}");
    try std.testing.expect(app.warning and app.action_notice);
    try std.testing.expect(std.mem.startsWith(u8, app.status[0..app.status_len], "Attachment saved · could not open file:"));
    try std.testing.expectEqualStrings("FileNotFound", app.status_error_code[0..app.status_error_len]);
    const length = app.status_len;
    app.say(false, "Ready", .{});
    try std.testing.expectEqual(length, app.status_len);
    try std.testing.expect(app.warning);
}

test "wishlist: cached body search worker retains navigation joins cancellation and never calls provider" {
    const HeldCache = struct {
        io: Io,
        entered: Io.Event = .unset,
        release: Io.Event = .unset,
        blocking: bool = true,
        canceled: std.atomic.Value(bool) = .init(false),
        provider_calls: std.atomic.Value(usize) = .init(0),
        cache_calls: std.atomic.Value(usize) = .init(0),
        fn provider(context: *anyopaque, _: Allocator, _: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.provider_calls.fetchAdd(1, .monotonic);
            return error.ProviderMustNotRun;
        }
        fn local(context: *anyopaque, allocator: Allocator, request: []const u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.cache_calls.fetchAdd(1, .monotonic);
            const parsed = try std.json.parseFromSlice(Value, allocator, request, .{});
            defer parsed.deinit();
            const cmd = text(get(parsed.value, "cmd"));
            if (same(cmd, "contacts.list")) return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"contacts\":[{\"name\":\"Cached Alex\",\"emails\":[]}],\"cached\":true,\"cacheReady\":true}}");
            if (same(cmd, "mail.read")) return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"id\":\"b\",\"bodyText\":\"Cached navigable second body\"}}");
            if (!same(cmd, "mail.search") or !truth(get(parsed.value, "cacheOnly"))) return error.ExpectedCacheOnlySearch;
            if (same(text(get(parsed.value, "query")), "body:missing")) return error.CacheMiss;
            self.entered.set(self.io);
            if (self.blocking) self.release.wait(self.io) catch |err| {
                if (err == error.Canceled) self.canceled.store(true, .release);
                return err;
            };
            return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"b\",\"subject\":\"Body result\"}],\"cached\":true,\"cacheReady\":true,\"partial\":true,\"highlightTerm\":\"needle\"}}");
        }
    };
    const allocator = std.testing.allocator;
    var cache: HeldCache = .{ .io = std.testing.io };
    var dummy_tty: vaxis.Tty = undefined;
    var dummy_vx: vaxis.Vaxis = undefined;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);
    loop.init(std.testing.io, allocator, &dummy_tty, &dummy_vx);
    defer loop.deinit();
    var factory: CacheTestClient = .{};
    var app = factory.app(allocator);
    app.client = .{ .ctx = &cache, .callFn = HeldCache.provider, .cachedFn = HeldCache.local };
    app.loop = loop;
    app.synchronous_cache_search = false;
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"},{\"id\":\"b\"}],\"cached\":true,\"cacheReady\":true}}");
    try app.replaceReader(false, "{\"ok\":true,\"data\":{\"id\":\"a\",\"bodyText\":\"Original retained body\"}}", true);
    try app.query.set(allocator, "body:needle");
    app.query_scope = .cache;
    app.generation +%= 1;
    try app.reload();
    try cache.entered.waitTimeout(app.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } });
    try std.testing.expectEqual(JobKind.cached_search, app.job.kind);
    try std.testing.expect(app.job.future != null);
    try std.testing.expectEqual(@as(usize, 2), app.messages.len);
    try std.testing.expectEqualStrings("Original retained body", text(get(app.thread[0], "bodyText")));
    try std.testing.expectEqual(Tone.fetching, app.syncTone());
    try app.move(true, 1);
    try std.testing.expectEqualStrings("b", app.messageId());
    try std.testing.expectEqualStrings("Cached navigable second body", text(get(app.thread[0], "bodyText")));
    try app.prepareContacts("");
    try std.testing.expect(cache.canceled.load(.acquire));
    try std.testing.expect(app.job.future == null);
    try std.testing.expectEqual(Mode.contacts, app.mode);
    try std.testing.expectEqualStrings("Cached Alex", text(get(app.contacts[0], "name")));
    app.leaveContacts();
    cache.blocking = false;
    try app.reload();
    app.job.future.?.await(app.io);
    try app.finish();
    try std.testing.expectEqualStrings("b", app.messageId());
    try std.testing.expectEqualStrings("needle", app.search_highlight.value());
    try std.testing.expectEqual(@as(usize, 0), cache.provider_calls.load(.acquire));
    try std.testing.expect(app.job.future == null);
    try app.query.set(allocator, "body:missing");
    app.generation +%= 1;
    try app.reload();
    app.job.future.?.await(app.io);
    try app.finish();
    try std.testing.expectEqualStrings("b", app.messageId());
    try std.testing.expectEqual(@as(usize, 0), cache.provider_calls.load(.acquire));
    try std.testing.expect(app.job.future == null);
    try app.query.set(allocator, "subject:fictional");
    app.generation +%= 1;
    _ = try app.loadCachedList("");
    try std.testing.expect(app.job.future == null); // Metadata remains synchronous.
    try std.testing.expectEqual(@as(usize, 0), cache.provider_calls.load(.acquire));
}

test "triage UI: empty label cache requests one refresh and action notices survive background status" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    try app.labels_account.set(allocator, app.account());
    try app.prepareLabels();
    try std.testing.expect(app.pending_labels);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
    app.say(false, "Mail action: 2 applied · :undo", .{});
    app.action_notice = true;
    app.say(false, "Working…", .{});
    app.say(false, "Ready", .{});
    try std.testing.expectEqualStrings("Mail action: 2 applied · :undo", app.status[0..app.status_len]);
    app.say(true, "PermissionDenied", .{});
    try std.testing.expectEqualStrings("PermissionDenied", app.status[0..app.status_len]);
    try std.testing.expect(!app.action_notice);
}

test "fetch progress: status shows honest batch counts for only the active account" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"},{\"address\":\"work@example.com\"}]", .{}));
    app.job.account_index = 0;
    app.job.future = .{ .any_future = null, .result = {} };
    defer app.job.future = null;
    _ = app.job.progress.publish(.{ .phase = .metadata, .completed = 1, .total = 100 });
    try std.testing.expect(std.mem.indexOf(u8, try app.syncLine(), "metadata 1/100") != null);
    try std.testing.expectEqual(Tone.fetching, app.syncTone());
    _ = app.job.progress.publish(.{ .phase = .bodies, .completed = 7, .total = 32 });
    try std.testing.expect(std.mem.indexOf(u8, try app.syncLine(), "bodies 7/32") != null);
    app.account_index = 1;
    try std.testing.expect(std.mem.indexOf(u8, try app.syncLine(), "7/32") == null);
    app.account_index = 0;
    app.job.future = null;
    try std.testing.expect(std.mem.indexOf(u8, try app.syncLine(), "7/32") == null);
}

const ScrollPagingClient = struct {
    provider_calls: usize = 0,
    page_calls: usize = 0,
    refuse: bool = false,
    fn provider(context: *anyopaque, _: Allocator, _: []const u8) ![]const u8 {
        const self: *ScrollPagingClient = @ptrCast(@alignCast(context));
        self.provider_calls += 1;
        return error.ProviderMustNotRun;
    }
    fn local(context: *anyopaque, allocator: Allocator, raw: []const u8) ![]const u8 {
        const self: *ScrollPagingClient = @ptrCast(@alignCast(context));
        const parsed = try std.json.parseFromSlice(Value, allocator, raw, .{});
        defer parsed.deinit();
        const request = parsed.value;
        if (same(text(get(request, "cmd")), "mail.read")) return std.json.Stringify.valueAlloc(allocator, .{ .ok = true, .data = .{ .id = text(get(request, "messageId")), .bodyText = "Cached scroll body" } }, .{});
        self.page_calls += 1;
        if (self.refuse) return allocator.dupe(u8, "{\"ok\":false,\"error\":{\"code\":\"InvalidCursor\"}}");
        const cursor_value = text(get(request, "cursor"));
        if (same(text(get(request, "beforeMessageId")), "a2")) return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a0\"},{\"id\":\"a1\"}],\"cursor\":\"C:first\",\"hasMoreCachedBefore\":false,\"cached\":true,\"cacheReady\":true}}");
        if (same(text(get(request, "beforeMessageId")), "b1")) return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"hasMoreCachedBefore\":false,\"hasMoreCachedAfter\":true,\"cached\":true,\"cacheReady\":true}}");
        if (same(cursor_value, "C:next") or same(cursor_value, "K:next") or same(text(get(request, "afterMessageId")), "a2")) return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a2\"},{\"id\":\"b1\"},{\"id\":\"b2\"}],\"cursor\":\"C:next\",\"previousCursor\":\"C:first\",\"cached\":true,\"cacheReady\":true}}");
        return allocator.dupe(u8, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"nextCursor\":\"C:next\",\"cached\":true,\"cacheReady\":true}}");
    }
    fn app(self: *ScrollPagingClient, allocator: Allocator) App {
        var factory: CacheTestClient = .{};
        var result = factory.app(allocator);
        result.client = .{ .ctx = self, .callFn = provider, .cachedFn = local };
        return result;
    }
};

test "scroll paging: tail demand selects first new ID and back restores bounded previous page" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"nextCursor\":\"C:next\",\"cached\":true,\"cacheReady\":true}}");
    app.selected = 1;
    try app.move(true, 1);
    try std.testing.expectEqualStrings("b1", app.messageId());
    try std.testing.expectEqual(@as(usize, 1), app.selected); // Repeated boundary a2 is skipped.
    try std.testing.expectEqual(@as(usize, 3), app.messages.len);
    try std.testing.expectEqual(@as(usize, 1), app.previous_cursors.items.len);
    try std.testing.expect(!app.page_loading);
    try app.page(false);
    try std.testing.expectEqualStrings("a1", app.messageId());
    try std.testing.expectEqual(@as(usize, 2), app.messages.len);
    try std.testing.expectEqual(@as(usize, 0), app.previous_cursors.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "scroll paging: crossing tail once and cursor refusal preserve retryable loaded snapshot" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{ .refuse = true };
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"nextCursor\":\"C:next\",\"cached\":true,\"cacheReady\":true}}");
    const generation = app.generation;
    try std.testing.expectError(error.OperationRejected, app.move(true, 20));
    try std.testing.expectEqualStrings("a1", app.messageId());
    try std.testing.expectEqual(@as(usize, 2), app.messages.len);
    try std.testing.expectEqual(generation, app.generation);
    try std.testing.expectEqualStrings("", app.cursor.value());
    try std.testing.expect(!app.page_loading);
    try std.testing.expectEqual(@as(usize, 0), app.previous_cursors.items.len);
    client.refuse = false;
    try app.move(true, 3);
    try std.testing.expectEqualStrings("b1", app.messageId());
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "scroll paging: queued refresh boundary advances without skipping shifted rows and isolates scope" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"},{\"address\":\"work@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"remoteCursor\":\"L:next\",\"cached\":true,\"cacheReady\":true}}");
    app.selected = 1;
    try app.queueNextPage();
    try app.queueNextPage();
    try std.testing.expect(app.pending_page);
    try std.testing.expectEqualStrings("a2", app.pending_page_boundary.value());
    // A refresh re-anchors the old tail inside a new cache page. Its immediate
    // successor is already present, so a demand must not skip a whole chunk.
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a2\"},{\"id\":\"b1\"},{\"id\":\"b2\"}],\"remoteCursor\":\"L:next\",\"cached\":true,\"cacheReady\":true}}");
    try app.consumePendingPage();
    try std.testing.expectEqualStrings("b1", app.messageId());
    try std.testing.expect(!app.pending_page);
    try std.testing.expectEqual(@as(usize, 0), client.page_calls);
    try app.queueNextPage();
    app.account_index = 1;
    try app.consumePendingPage();
    try std.testing.expect(!app.pending_page);
    try std.testing.expectEqual(@as(usize, 0), client.page_calls);
    app.account_index = 0;
    try app.queueNextPage();
    app.generation +%= 1;
    try app.consumePendingPage();
    try std.testing.expect(!app.pending_page);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "scroll paging: cache-only search tail never falls through to provider cursor" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.query.set(allocator, "body:cached");
    app.query_scope = .cache;
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"remoteCursor\":\"L:must-not-fetch\",\"cached\":true,\"cacheReady\":true}}");
    app.selected = 1;
    app.has_more_cached_after = false;
    try app.move(true, 20);
    try std.testing.expectEqualStrings("a2", app.messageId());
    try std.testing.expectEqual(@as(usize, 0), client.page_calls);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
    try app.next_cursor.set(allocator, "K:next");
    app.has_more_cached_after = null;
    try app.move(true, 3);
    try std.testing.expectEqualStrings("b1", app.messageId());
    try std.testing.expectEqual(@as(usize, 1), client.page_calls);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "cache windows: upward past first row selects nearest cached predecessor without history or network" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"b1\"},{\"id\":\"b2\"}],\"cursor\":\"C:stale-generation\",\"cached\":true,\"cacheReady\":true,\"hasMoreCachedBefore\":true}}");
    try std.testing.expectEqual(@as(usize, 0), app.previous_cursors.items.len);
    try app.move(false, 1);
    try std.testing.expectEqualStrings("a2", app.messageId());
    try std.testing.expectEqual(@as(usize, 1), app.selected);
    try std.testing.expectEqual(@as(usize, 2), app.messages.len);
    try std.testing.expectEqual(@as(usize, 1), client.page_calls);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
    try app.move(false, 1); // Still within the preceding cache window.
    try std.testing.expectEqualStrings("a1", app.messageId());
    try app.move(false, 3); // Known beginning does not repeatedly query or fetch.
    try std.testing.expectEqual(@as(usize, 1), client.page_calls);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "cache windows: automatic reverse skips old boundary and queued direction stays scoped" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a2\"},{\"id\":\"b1\"},{\"id\":\"b2\"}],\"cached\":true,\"cacheReady\":true}}");
    try app.move(false, 3);
    try std.testing.expectEqualStrings("a1", app.messageId());
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
    try app.queuePage(false, true);
    try std.testing.expect(!app.pending_page_forward);
    const boundary = app.pending_page_boundary.value();
    try std.testing.expectEqualStrings("a0", boundary);
    app.generation +%= 1;
    try app.consumePendingPage();
    try std.testing.expect(!app.pending_page);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "reader polish: J K traverse adjacent cache windows and keep reader focus" {
    const allocator = std.testing.allocator;
    var client: ScrollPagingClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a1\"},{\"id\":\"a2\"}],\"cached\":true,\"cacheReady\":true}}");
    app.selected = 1;
    app.focus = .reader;
    try app.adjacentMail(true);
    try std.testing.expectEqualStrings("b1", app.messageId());
    try std.testing.expectEqual(Focus.reader, app.focus);
    app.selected = 0;
    try app.adjacentMail(false);
    try std.testing.expectEqualStrings("a1", app.messageId());
    try std.testing.expectEqual(Focus.reader, app.focus);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "reader polish: search back restores account mailbox selected identity viewport and reader" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"}],\"cached\":true,\"cacheReady\":true}}");
    app.selected = 2;
    app.top = 1;
    app.folder = 1;
    app.focus = .reader;
    app.reader_scroll = 7;
    try app.custom_label.set(allocator, "Label_fictional");
    try app.beginSearch(.cache);
    try app.query.set(allocator, "subject:needle");
    app.selected = 0;
    app.top = 0;
    app.folder = 0;
    app.reader_scroll = 0;
    app.focus = .list;
    try app.custom_label.set(allocator, "");
    try std.testing.expect(try app.clearSearch());
    try std.testing.expectEqualStrings("personal@example.test", app.account());
    try std.testing.expectEqual(@as(usize, 1), app.folder);
    try std.testing.expectEqualStrings("Label_fictional", app.custom_label.value());
    try std.testing.expectEqualStrings("c", app.restore_message.value());
    try std.testing.expectEqual(@as(usize, 2), app.selected);
    try std.testing.expectEqual(@as(usize, 1), app.top);
    try std.testing.expectEqual(@as(?usize, 7), app.restore_reader_scroll);
    try std.testing.expectEqual(Focus.reader, app.focus);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "reader polish: small focused thread keeps body rows and Q S anchor the current card" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    try app.replaceList(.list, "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"c\"}]}}");
    const response = "{\"ok\":true,\"data\":{\"messages\":[{\"id\":\"a\",\"from\":{\"address\":\"a@example.test\"}},{\"id\":\"b\",\"from\":{\"address\":\"b@example.test\"}},{\"id\":\"c\",\"subject\":\"Compact thread\",\"from\":{\"address\":\"c@example.test\"},\"bodyText\":\"Hello onboarding instructions for the preview build.\\nSecond readable line.\\n> Quoted history\\n-- \\nSignature\"}]}}";
    try app.replaceReader(true, response, true);
    app.focus = .reader;
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 78, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 30, .screen = &screen };
    try app.readerDraw(win);
    try std.testing.expectEqual(app.reader_card_rows[2], app.reader_scroll);
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = 'Q' }));
    try app.readerDraw(win);
    try std.testing.expectEqual(app.reader_card_rows[2], app.reader_scroll);
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = 'S' }));
    try app.readerDraw(win);
    try std.testing.expectEqual(app.reader_card_rows[2], app.reader_scroll);
    win.height = 10; // Actual prior defect: tall clamp had erased the card pin.
    screen.clear();
    try app.readerDraw(win);
    try std.testing.expect(app.reader_scroll >= app.reader_card_rows[2]);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    for (0..win.height) |row| for (0..win.width) |column| try rendered.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "↑2 earlier") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Hello onboarding instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Second readable line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "J/K Mail") == null);
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = 'Q' }));
    try app.readerDraw(win);
    try std.testing.expectEqual(@as(usize, 2), app.reader_card);
    try std.testing.expect(try app.onReaderKey(.{ .codepoint = 'S' }));
    try app.readerDraw(win);
    try std.testing.expectEqual(@as(usize, 2), app.reader_card);
    try std.testing.expect(!app.reader_anchor_card);
}

test "status polish: long UTF8 status remains bounded and diagnostics are readable" {
    var client: CacheTestClient = .{};
    var app = client.app(std.testing.allocator);
    defer app.deinit();
    var long: [1600]u8 = undefined;
    for (0..400) |i| @memcpy(long[i * 4 ..][0..4], "🌋");
    app.say(false, "Saved {s}", .{long[0..]});
    try std.testing.expect(app.status_len <= app.status.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(app.status[0..app.status_len]));
    try std.testing.expect(std.mem.startsWith(u8, app.status[0..app.status_len], "Saved "));
    try std.testing.expect(std.mem.endsWith(u8, app.status[0..app.status_len], "…"));
    app.sayError("BodySizeMismatch");
    try std.testing.expectEqualStrings("Mail body is incomplete", app.status[0..app.status_len]);
    try std.testing.expectEqualStrings("BodySizeMismatch", app.status_error_code[0..app.status_error_len]);
    app.selection_generation += 1;
    app.clearObsoleteStatus();
    try std.testing.expectEqualStrings("Ready", app.status[0..app.status_len]);
}

test "status polish: view changes clear obsolete hints but preserve action and unknown outcomes" {
    var client: CacheTestClient = .{};
    var app = client.app(std.testing.allocator);
    defer app.deinit();
    app.mode = .contacts;
    app.say(false, "Contacts · n New · e Edit", .{});
    app.mode = .browse;
    app.clearObsoleteStatus();
    try std.testing.expectEqualStrings("Ready", app.status[0..app.status_len]);
    app.sayAction(false, "Change applied · :undo", .{});
    app.mode = .contacts;
    app.clearObsoleteStatus();
    try std.testing.expectEqualStrings("Change applied · :undo", app.status[0..app.status_len]);
    app.action_notice = false;
    app.markUnknown(.send);
    app.mode = .browse;
    app.clearObsoleteStatus();
    app.say(false, "Ready", .{});
    try std.testing.expectEqual(StatusKind.unknown, app.status_kind);
    try std.testing.expect(std.mem.indexOf(u8, app.status[0..app.status_len], "Outcome unknown") != null);
}

test "status polish: header context and list counts do not invent mailbox totals" {
    var client: CacheTestClient = .{};
    var app = client.app(std.testing.allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    app.reader_layout = .below;
    app.mode = .compose;
    const compose_header = try app.globalHeader();
    try std.testing.expect(std.mem.indexOf(u8, compose_header, "Compose") != null);
    try std.testing.expect(std.mem.indexOf(u8, compose_header, "Reader below") == null);
    app.mode = .contacts;
    try std.testing.expect(std.mem.indexOf(u8, try app.globalHeader(), "Contacts") != null);
    app.mode = .browse;
    app.messages = items(try std.json.parseFromSliceLeaky(Value, app.list_arena.allocator(), "[{\"id\":\"one\"},{\"id\":\"two\"},{\"id\":\"three\"}]", .{}));
    app.selected = 1;
    app.has_more_cached_before = true;
    app.has_more_cached_after = true;
    try std.testing.expectEqualStrings(" Mail · 2/3 ↑↓ ", try app.listTitle());
    app.sync[0] = .{ .state = .current, .cache_ready = true, .last_sync_at = 1791100800000 };
    const synced = try app.syncLine();
    try std.testing.expect(std.mem.indexOf(u8, synced, "Synced 2026-") != null);
    try std.testing.expect(std.mem.indexOf(u8, synced, "cache age") == null);
    app.mono = true;
    try std.testing.expect(app.listStyle(.muted, true).reverse);
}

test "status polish: compact header retains account and Mock while preview hints stay discoverable" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.options.fixtures = true;
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.com\"}]", .{}));
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &screen };
    const shown = try app.fittedGlobalHeader(win);
    try std.testing.expect(std.mem.indexOf(u8, shown, "personal@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Mock") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Experimental") == null);
    try std.testing.expectEqual(@as(usize, 0), positionAfter(win, shown).row);
    app.mode = .compose;
    const hints = app.fittedHints(100);
    for ([_][]const u8{ "A Attach", "Ctrl+S Review", "q Save", "Ctrl+D/U Preview", "Tab Field", "a Contacts", "? Help" }) |literal| try std.testing.expect(std.mem.indexOf(u8, hints, literal) != null);
}

test "status polish: two-row mail cards use the final row without a trailing gap" {
    try std.testing.expectEqual(@as(usize, 2), mailRowCapacity(5));
    try std.testing.expectEqual(@as(usize, 3), mailRowCapacity(8));
    try std.testing.expectEqual(@as(usize, 1), mailRowCapacity(2));
    try std.testing.expectEqual(@as(usize, 1), mailRowCapacity(4));
    try std.testing.expectEqual(@as(usize, 2), mailRowCapacity(6));
    try std.testing.expectEqual(@as(usize, 1), mailRowCapacity(0));
}

test "recipient preview: Ctrl N P works for unsaved correspondents without contacts and scopes results" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"},{\"address\":\"work@example.test\"}]", .{}));
    try app.replaceRecipients("{\"ok\":true,\"data\":{\"recipients\":[{\"address\":\"caroline-new@example.test\",\"name\":\"Caroline New\"},{\"address\":\"caroline-old@example.test\",\"name\":\"Caroline Old\"}]}}");
    app.mode = .compose;
    app.compose.insert_mode = true;
    try app.compose.fields[0].set(allocator, "caro, last@example.test");
    app.compose.fields[0].cursor = 4;
    try std.testing.expectEqual(@as(usize, 2), app.composeCompletions().len);
    try app.onComposeKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(usize, 1), app.compose.completion_selected);
    try app.onComposeKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(usize, 0), app.compose.completion_selected);
    try app.onComposeKey(.{ .codepoint = Key.enter });
    try std.testing.expectEqualStrings("caroline-new@example.test, last@example.test", app.compose.fields[0].value());
    try app.compose.fields[0].set(allocator, "caro");
    app.account_index = 1;
    try std.testing.expectEqual(@as(usize, 0), app.composeCompletions().len);
    try app.onComposeKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expect(std.mem.indexOf(u8, app.status[0..app.status_len], "No matching") != null);
    try std.testing.expectEqualStrings("caro", app.compose.fields[0].value());
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}

test "recipient preview: a fresh composer renders its draft and not unrelated inbox body" {
    const allocator = std.testing.allocator;
    var client: CacheTestClient = .{};
    var app = client.app(allocator);
    defer app.deinit();
    app.accounts = items(try std.json.parseFromSliceLeaky(Value, app.account_arena.allocator(), "[{\"address\":\"personal@example.test\"}]", .{}));
    app.thread = items(try std.json.parseFromSliceLeaky(Value, app.read_arena.allocator(), "[{\"id\":\"unrelated\",\"bodyText\":\"UNRELATED_INBOX_BODY\"}]", .{}));
    app.mode = .compose;
    app.compose_active = true;
    try app.compose.fields[4].set(allocator, "Own new draft body");
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 160, .rows = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 160, .height = 32, .screen = &screen };
    try app.composeDraw(win);
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(allocator);
    for (0..screen.height) |row| for (0..screen.width) |column| try visible.appendSlice(allocator, screen.readCell(@intCast(column), @intCast(row)).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Draft preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Own new draft body") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "UNRELATED_INBOX_BODY") == null);
    app.reader_lines = 100;
    app.reader_height = 20;
    app.selected = 7;
    try app.onComposeKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(usize, 10), app.reader_scroll);
    try std.testing.expectEqual(@as(usize, 7), app.selected);
    try app.onComposeKey(.{ .codepoint = 'u', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(usize, 0), app.reader_scroll);
    try std.testing.expectEqual(@as(usize, 0), client.provider_calls);
}
