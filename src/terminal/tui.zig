//! Account-scoped terminal mail UI. libvaxis owns input/rendering; the same
//! bounded operation client serves this UI and the JSON CLI.
const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const editor = @import("editor.zig");
const files = @import("files.zig");
const input_loop = @import("input.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const preferences = @import("preferences.zig");
const recipients = @import("recipients.zig");
const invitation = @import("invitation.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Key = vaxis.Key;
const max_cols = 240;
const max_rows = 80;
const response_limit = types.Limits.runtime_bytes / 2;
const Event = union(enum) { key_press: Key, winsize: vaxis.Winsize, paste_start, paste_end, operation_done, terminate };
const Loop = input_loop.Loop(Event);
const Mode = enum { browse, search, command, compose, review, contacts, contact_edit, help, trash_confirm, invitation, labels, attachment };
const Tone = enum { text, subject, sender, muted, accent, selected, warning, fetching, current, offline };
const Focus = layout.Focus;
const JobKind = enum { refresh, list, read, thread, drafts, draft_read, draft_operations, compose, save, save_review, save_back, send, contacts, contact_write, mutation, invitation_inspect, invitation, open, attachment_save };
const SyncState = enum { fetching, refreshing, cached, current, offline, failed };
const SyncStatus = struct {
    state: SyncState = .fetching,
    last_sync_at: i64 = 0,
    cache_ready: bool = false,
    error_code: [64]u8 = @splat(0),
    error_len: usize = 0,
};
const PendingCompose = enum { none, new, reply, reply_all };
const ContactsState = enum { loading, cached, current, denied, failed, busy };
const QueryScope = enum { cache, server };

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
const folders = [_][]const u8{ "Inbox", "Sent", "Drafts", "Archive", "Trash" };
const folder_labels = [_][]const u8{ "INBOX", "SENT", "DRAFT", "", "TRASH" };
const help_text =
    "j/k, arrows Move · h/l, Tab/Shift+Tab Pane\n" ++
    "gg/G First/last · Ctrl+D/U Half-page\n" ++
    "[ / ] Pages · Enter Open · z Expand reader\n" ++
    "Reader: J/K Next/previous mail · j/k Scroll\n" ++
    "v Right/below reader · :layout right|below\n" ++
    "1/2/3 Account · / Cache search · \\ Gmail search\n" ++
    "c/r/R Compose/reply/all · a Contacts; n/e New/edit\n" ++
    "x/D/U Archive/Trash/restore · s/u Star/unread\n" ++
    "m Label · I Review RSVP · o Open in browser\n" ++
    ":save-attachment NUMBER /literal/path Save\n" ++
    "Ctrl+R Refresh · Ctrl+L Reload theme/redraw\n" ++
    "COMPOSE: Tab,j/k Field · i/Enter Insert · Esc Normal\n" ++
    "e $EDITOR · A Attach · :detach NUMBER Remove\n" ++
    "a Choose contact · Ctrl+S/:send Review\n" ++
    "Review: y explicitly sends · Esc Back\n" ++
    "Esc/q Back · q quits mailbox\n" ++
    "Ctrl+C Cancel work; quit when idle\n" ++
    "No editor save or paste sends mail.";

const TextPosition = struct {
    row: usize = 0,
    column: u16 = 0,

    fn wrap(self: *TextPosition, width: u16, columns: u16) void {
        if (self.column +| width > columns) {
            self.row += 1;
            self.column = 0;
        }
    }
    fn advance(self: *TextPosition, width: u16, columns: u16) void {
        self.wrap(width, columns);
        self.column +|= width;
    }
    fn newline(self: *TextPosition) void {
        self.row += 1;
        self.column = 0;
    }
};

fn positionAfter(win: vaxis.Window, clean: []const u8) TextPosition {
    var position: TextPosition = .{};
    if (win.width == 0) return position;
    var iterator = vaxis.unicode.graphemeIterator(clean);
    while (iterator.next()) |gr| {
        const raw = gr.bytes(clean);
        if (same(raw, "\n")) position.newline() else position.advance(@max(win.gwidth(if (raw.len > 128) "�" else raw), 1), win.width);
    }
    return position;
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
    const file = try Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer Io.Dir.deleteFileAbsolute(io, path) catch {};
    try file.writeStreamingAll(io, decoded);
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
fn truth(value: Value) bool {
    return value == .bool and value.bool;
}
fn timestamp(allocator: Allocator, value_in: Value) ![]const u8 {
    const milliseconds = if (value_in == .integer) value_in.integer else 0;
    if (milliseconds <= 0 or milliseconds > 253402300799000) return "";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(milliseconds, 1000)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ year_day.year, month_day.month.numeric(), @as(u8, month_day.day_index) + 1, day.getHoursIntoDay(), day.getMinutesIntoHour() });
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// All terminal text passes here, including metadata and locally edited text.
/// Newlines survive only in bodies; terminal/bidi controls never survive.
fn safe(allocator: Allocator, input: []const u8, multiline: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
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
        if (cp == '\n' and multiline) {
            try out.append(allocator, '\n');
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
        try limited.appendSlice(allocator, out.items[0..gr.start]);
        try limited.appendSlice(allocator, "�");
        while (graphemes.next()) |next_gr| try limited.appendSlice(allocator, if (next_gr.len > 128) "�" else next_gr.bytes(out.items));
        out.deinit(allocator);
        out = .empty;
        return limited.toOwnedSlice(allocator);
    };
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
    attachments: []const types.Attachment = &.{},
    attachment_arena: ?std.heap.ArenaAllocator = null,
    selected: usize = 0,
    body_scroll: usize = 0,
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
    contacts: []const Value = &.{},
    selected: usize = 0,
    top: usize = 0,
    reader_scroll: usize = 0,
    reader_lines: usize = 0,
    reader_account: Field = .{},
    reader_message: Field = .{},
    reader_partial: bool = false,
    reader_is_thread: bool = false,
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
    pending_contacts: bool = false,
    pending_cached_contacts: bool = false,
    folder: usize = 0,
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
    pending_cached_read: bool = false,
    pending_cached_thread: bool = false,
    pending_read: bool = false,
    pending_thread: bool = false,
    pending_page: bool = false,
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
    contact_name: Field = .{},
    contact_email: Field = .{},
    contact_id: Field = .{},
    contact_etag: Field = .{},
    contact_field: usize = 0,
    editor_exit: ?u8 = null,
    status: [256]u8 = @splat(0),
    status_len: usize = 0,
    warning: bool = false,
    job: Job = .{},
    mono: bool = false,
    palette: theme.Palette = .{},
    reader_layout: layout.ReaderLayout = .right,
    preferences_file: Field = .{},
    preferences_warning: bool = false,
    theme_warning: bool = false,

    fn deinit(self: *App) void {
        self.cancelJob();
        self.clearHistory();
        self.previous_cursors.deinit(self.allocator);
        for ([_]*Field{ &self.query, &self.input, &self.cursor, &self.next_cursor, &self.previous_cursor, &self.remote_cursor, &self.reader_account, &self.reader_message, &self.contact_name, &self.contact_email, &self.contact_id, &self.contact_etag, &self.contacts_query, &self.contacts_account, &self.invitation_operation_id, &self.invitation_operation_error, &self.invitation_message_id, &self.invitation_inspected_id, &self.invitation_inspected_account, &self.invitation_account, &self.attachment_destination, &self.preferences_file }) |field| field.deinit(self.allocator);
        self.compose.deinit(self.allocator);
        self.frame.deinit();
        self.job_arena.deinit();
        self.contact_arena.deinit();
        self.read_arena.deinit();
        self.list_arena.deinit();
        self.account_arena.deinit();
    }
    fn account(self: *const App) []const u8 {
        return if (self.account_index < self.accounts.len) text(get(self.accounts[self.account_index], "address")) else "";
    }
    fn say(self: *App, warning: bool, comptime format: []const u8, args: anytype) void {
        const value_in = std.fmt.bufPrint(&self.status, format, args) catch "Operation failed";
        self.status_len = value_in.len;
        self.warning = warning;
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
        self.reader_layout = saved.readerLayout;
        self.preferences_warning = false;
    }
    fn setReaderLayout(self: *App, value_in: layout.ReaderLayout) void {
        self.reader_layout = value_in;
        const label = @tagName(value_in);
        if (self.preferences_file.value().len == 0) {
            self.preferences_warning = true;
            self.say(true, "Reader {s} · preference not saved", .{label});
            return;
        }
        preferences.save(self.io, self.allocator, self.preferences_file.value(), .{ .readerLayout = value_in }) catch |err| {
            self.preferences_warning = true;
            self.say(true, "Reader {s} · preference not saved: {s}", .{ label, @errorName(err) });
            return;
        };
        self.preferences_warning = false;
        self.say(false, "Reader {s} · preference saved", .{label});
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
        const status = &self.sync[self.account_index];
        const elsewhere = self.job.future != null and self.job.kind == .refresh and self.job.account_index == self.account_index and self.job.waiting_external.load(.acquire);
        const label = if (elsewhere) (if (status.cache_ready) "Updating elsewhere · cached mail ready" else "Updating elsewhere · waiting for cached mail") else switch (status.state) {
            .fetching => "Fetching mail",
            .refreshing => "Refreshing cached mail",
            .cached => "Cached mail",
            .current => "Up to date",
            .offline => "Offline cached mail",
            .failed => "Mail unavailable",
        };
        const age = if (status.last_sync_at > 0) blk: {
            const now = Io.Timestamp.now(self.io, .real).toMilliseconds();
            const seconds = @divTrunc(@max(now - status.last_sync_at, 0), 1000);
            break :blk try std.fmt.allocPrint(self.frame.allocator(), "cache age {d}{s}", .{ if (seconds >= 86400) @divTrunc(seconds, 86400) else if (seconds >= 3600) @divTrunc(seconds, 3600) else if (seconds >= 60) @divTrunc(seconds, 60) else seconds, if (seconds >= 86400) @as([]const u8, "d") else if (seconds >= 3600) "h" else if (seconds >= 60) "m" else "s" });
        } else if (status.cache_ready) "cache age unknown" else "no cached mail";
        return std.fmt.allocPrint(self.frame.allocator(), " {s} · {s}{s}{s}{s}{s}{s}", .{ label, age, if (status.error_len > 0) " · " else "", status.error_code[0..status.error_len], if (self.cache_busy or self.reader_cache_busy) " · cache read busy" else "", if (self.preferences_warning) " · UI prefs fallback" else "", if (self.theme_warning) " · theme fallback" else "" });
    }
    fn syncTone(self: *const App) Tone {
        if (self.job.future != null and self.job.kind == .refresh and self.job.account_index == self.account_index and self.job.waiting_external.load(.acquire)) return .fetching;
        return switch (self.sync[self.account_index].state) {
            .fetching, .refreshing => .fetching,
            .current => .current,
            .offline => .offline,
            .failed => .warning,
            .cached => .muted,
        };
    }
    fn clearReader(self: *App) void {
        self.thread = &.{};
        _ = self.read_arena.reset(.retain_capacity);
        self.reader_scroll = 0;
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
            self.say(true, "{s}", .{if (code.len == 0) "Operation rejected" else code});
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
            const parsed = std.json.parseFromSlice(Value, allocator, response, .{ .allocate = .alloc_always }) catch |err| {
                allocator.free(response);
                return err;
            };
            defer parsed.deinit();
            const envelope = parsed.value;
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
                self.say(true, "Cache: {s}", .{code});
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
        const same_view = self.view_ready and self.view_generation == self.generation;
        const saved = if (same_view) self.messageId() else "";
        var selected = @min(self.selected, messages.len -| 1);
        for (messages, 0..) |message, index| if (saved.len > 0 and same(text(get(message, "id")), saved)) {
            selected = index;
            break;
        };
        const selected_id = if (selected < messages.len) text(get(messages[selected], "id")) else "";
        const retain_reader = self.compose_active or (same_view and same(self.reader_account.value(), self.account()) and same(self.reader_message.value(), selected_id));
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
        self.list_cached = truth(get(result, "cached"));
        self.list_partial = truth(get(result, "partial"));
        self.cache_view_missing = truth(get(result, "viewIncomplete"));
        self.selected = selected;
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
        const same_reader = same(self.reader_account.value(), self.account()) and same(self.reader_message.value(), self.messageId()) and self.reader_is_thread == full_thread;
        try self.reader_account.set(self.allocator, self.account());
        try self.reader_message.set(self.allocator, self.messageId());
        const previous = self.read_arena;
        self.read_arena = replacement;
        replacement = previous;
        self.thread = messages;
        self.reader_partial = full_thread and cached_view and truth(get(result, "partial"));
        self.reader_is_thread = full_thread;
        self.body_cache_miss = false;
        self.reader_cache_busy = false;
        self.pending_cached_read = false;
        self.pending_cached_thread = false;
        if (!same_reader) self.reader_scroll = 0;
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
        if (self.view_ready and self.view_generation != self.generation) {
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
            .cursor = if (anchor.len > 0) "" else self.cursor.value(),
            .anchorMessageId = anchor,
            .query = if (self.folder == 3 and self.query.value().len == 0) "-in:inbox -in:trash" else self.query.value(),
            .label = folder_labels[self.folder],
        }) catch |err| {
            if (err == error.CacheBusy) self.pending_cached_list = true;
            return err;
        };
        if (response) |bytes| {
            self.pending_cached_list = false;
            try self.replaceList(.list, bytes);
            if (!self.compose_active and self.thread.len == 0 and self.messages.len > 0) {
                self.pending_read = false;
                const hit = self.cachedPreview(false) catch |err| {
                    if (err == error.CacheBusy) return self.sync[self.account_index].cache_ready;
                    return err;
                };
                self.pending_read = !hit and !self.cacheSearch();
            }
            return self.sync[self.account_index].cache_ready;
        }
        return false;
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
            if (kind == .refresh or kind == .list or kind == .drafts) self.pending_list = true else if (kind == .read or kind == .thread) self.pending_read = true else self.say(true, "Please wait for the current operation", .{});
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
        } else self.say(false, "Working…", .{});
        self.job.future = try self.io.concurrent(worker, .{self});
    }
    fn worker(self: *App) void {
        self.job.response = (if (self.job.kind == .refresh) self.refreshResponse() else self.client.call(self.job_arena.allocator(), self.job.request)) catch |err| blk: {
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
        const response = try self.client.call(allocator, self.job.request);
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
        if (self.job.future) |*future| future.cancel(self.io);
        self.job.future = null;
        self.pending_list = false;
        self.pending_remote_list = false;
        self.pending_cached_list = false;
        self.pending_cached_read = false;
        self.pending_cached_thread = false;
        self.pending_contacts = false;
        self.pending_cached_contacts = false;
        self.pending_read = false;
        self.pending_thread = false;
        self.pending_page = false;
        self.pending_compose = .none;
    }
    fn reload(self: *App) !void {
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
        if (std.mem.startsWith(u8, self.cursor.value(), "L:")) return self.start(.list, .{
            .account = self.account(),
            .cmd = if (self.query.value().len > 0) "mail.search" else "mail.list",
            .limit = @as(usize, 32),
            .cursor = self.cursor.value(),
            .query = if (self.folder == 3 and self.query.value().len == 0) "-in:inbox -in:trash" else self.query.value(),
            .label = folder_labels[self.folder],
        });
        const anchor = if (self.view_ready and self.view_generation == self.generation) self.messageId() else "";
        _ = self.loadCachedList(anchor) catch |err| blk: {
            self.say(true, "Cache: {s}", .{@errorName(err)});
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
            .label = folder_labels[self.folder],
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
            .label = folder_labels[self.folder],
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
            self.say(true, "Cache: {s}", .{@errorName(err)});
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
            self.say(true, "Selected body unavailable · {s}", .{reason});
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
                if (index == self.account_index and !self.compose_active) self.say(true, "Refresh failed · {s} · cached mail retained", .{failure_code});
            }
        } else if ((self.job.kind == .contacts and (self.job.contacts_generation != self.contacts_generation or !self.contactsOpen() or self.job.account_index != self.account_index)) or
            (self.job.generation != self.generation and (self.job.kind == .list or self.job.kind == .drafts or self.job.kind == .read or self.job.kind == .thread or self.job.kind == .contacts or self.job.kind == .invitation_inspect)) or
            (self.job.selection_generation != self.selection_generation and (self.job.kind == .read or self.job.kind == .thread or self.job.kind == .invitation_inspect)))
        {
            // Account/query/list identity changed while the provider was busy.
        } else if (self.job.failure) |err| {
            if (self.job.kind == .send or self.job.kind == .invitation) {
                (if (self.job.kind == .send) &self.compose.operation_error else &self.invitation_operation_error).set(self.allocator, @errorName(err)) catch {};
                self.markUnknown(self.job.kind);
            } else if (self.job.kind == .draft_operations) self.say(true, "Receipt lookup failed · draft remains protected", .{}) else if (err != error.Canceled) {
                if (self.job.kind == .list) self.syncFailed(self.job.account_index, @errorName(err));
                if (self.job.kind == .contacts) self.contacts_state = if (err == error.PermissionDenied) .denied else .failed;
                self.say(true, "{s}", .{@errorName(err)});
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
        // At most six coalesced flags exist. Local cache hits may complete
        // without starting a future, so drain them rather than leaving the
        // next intent waiting for an event that will never arrive.
        for (0..6) |_| {
            if (self.job.future != null) return;
            if (self.pending_contacts) {
                self.pending_contacts = false;
                if (self.contactsOpen() and same(self.contacts_account.value(), self.account())) {
                    self.contacts_state = if (self.contacts_cache_ready) .cached else .loading;
                    try self.start(.contacts, .{ .account = self.contacts_account.value(), .cmd = if (self.contacts_query.value().len == 0) "contacts.list" else "contacts.search", .query = self.contacts_query.value() });
                }
            } else if (self.pending_page) {
                self.pending_page = false;
                try self.page(true);
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
                    self.thread = &.{};
                    try self.start(.compose, .{ .account = self.account(), .cmd = "mail.reply", .messageId = self.pending_compose_id[0..self.pending_compose_id_len], .all = pending == .reply_all });
                }
            } else if (self.pending_read) {
                self.pending_read = false;
                const full_thread = self.pending_thread;
                self.pending_thread = false;
                try self.preview(full_thread);
            } else return;
        }
    }
    fn apply(self: *App, kind: JobKind, response: []const u8) !void {
        // Validate the envelope before replacing a valid cached view.
        _ = self.data(self.job_arena.allocator(), response) catch |err| {
            if (err == error.OperationRejected) {
                if (kind == .send or kind == .invitation) self.markUnknown(kind);
                if (kind == .list) self.syncFailed(self.job.account_index, self.status[0..self.status_len]);
                if (kind == .contacts) self.contacts_state = if (same(self.status[0..self.status_len], "PermissionDenied")) .denied else .failed;
                return;
            }
            return err;
        };
        switch (kind) {
            .refresh => unreachable, // Refresh metadata/merge is handled by finish.
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
                try self.compose.load(self.allocator, result);
                self.compose_active = true;
                self.mode = .compose;
                self.say(false, "Draft retained · i Edit · e $EDITOR · Ctrl+S Review send", .{});
                if (kind == .draft_read) {
                    self.compose.unknown_outcome = true;
                    try self.inspectDraftOperations();
                }
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
                    self.say(false, "{s}", .{if (self.options.fixtures) "Saved by mock provider" else "Submitted; recipient delivery is not confirmed"});
                    if (kind == .send) try self.resumeMailboxReader();
                }
            },
            .contacts => {
                try self.replaceContacts(response, false);
                self.say(false, "{s}", .{if (self.picker) "Choose recipient · Enter Add · Esc Back" else "Contacts · / Search · n New · e Edit"});
            },
            .contact_write => {
                _ = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                self.say(false, "Contact saved", .{});
                if (self.contactsOpen()) try self.loadContacts("");
            },
            .mutation => {
                _ = self.data(self.job_arena.allocator(), response) catch |err| {
                    if (err == error.OperationRejected) return;
                    return err;
                };
                self.mode = .browse;
                self.pending_list = true;
                self.say(false, "Change applied", .{});
            },
            .open => self.say(false, "{s}", .{if (self.options.fixtures) "Mock browser target validated" else "Opened in the configured browser profile"}),
            .attachment_save => self.say(false, "Saved attachment ({d} bytes) to {s}", .{ self.attachment_expected_size, self.attachment_destination.value() }),
        }
    }
    fn chooseAccount(self: *App, index: usize) !void {
        if (index >= self.accounts.len or self.mode == .compose or self.mode == .review or self.mode == .contact_edit) return;
        if (self.job.future != null and self.job.kind != .refresh and self.job.kind != .list and self.job.kind != .drafts and self.job.kind != .read and self.job.kind != .thread and self.job.kind != .contacts) {
            self.say(true, "Wait for the current account's change to finish", .{});
            return;
        }
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
        try self.reload();
    }
    fn page(self: *App, forward: bool) !void {
        if (self.job.future != null and self.job.kind != .refresh) return;
        if (forward) {
            const next = if (self.next_cursor.value().len > 0) self.next_cursor.value() else self.remote_cursor.value();
            if (next.len == 0) return;
            if (self.job.future != null and std.mem.startsWith(u8, next, "L:")) {
                self.pending_page = true;
                self.say(false, "Next provider page queued · cached mail remains usable", .{});
                return;
            }
            if (self.previous_cursors.items.len >= types.Limits.metadata_hard) return error.CursorHistoryTooLarge;
            try self.previous_cursors.append(self.allocator, try self.allocator.dupe(u8, self.cursor.value()));
            try self.cursor.set(self.allocator, next);
        } else {
            if (self.previous_cursor.value().len > 0) {
                try self.cursor.set(self.allocator, self.previous_cursor.value());
                if (self.previous_cursors.pop()) |previous| self.allocator.free(previous);
            } else {
                const previous = self.previous_cursors.pop() orelse return;
                defer self.allocator.free(previous);
                try self.cursor.set(self.allocator, previous);
            }
        }
        self.selected = 0;
        self.top = 0;
        self.generation +%= 1;
        if (self.drafts_list or (self.query.value().len > 0 and self.query_scope == .server) or std.mem.startsWith(u8, self.cursor.value(), "L:")) return self.reload();
        // Paging committed cache data is a local read, not a new refresh job.
        // The one already-active refresh may continue and later re-anchor it.
        _ = try self.loadCachedList("");
        if (self.pending_read and self.job.future == null) {
            self.pending_read = false;
            try self.preview(false);
        }
    }
    fn composeNew(self: *App, reply_all: ?bool) !void {
        if (self.job.future != null) {
            if (reply_all != null and self.messageId().len == 0) return;
            if (self.account().len > self.pending_compose_account.len or self.messageId().len > self.pending_compose_id.len) return error.InvalidIdentity;
            @memcpy(self.pending_compose_account[0..self.account().len], self.account());
            self.pending_compose_account_len = self.account().len;
            @memcpy(self.pending_compose_id[0..self.messageId().len], self.messageId());
            self.pending_compose_id_len = self.messageId().len;
            self.pending_compose = if (reply_all) |all| (if (all) .reply_all else .reply) else .new;
            self.say(false, "Draft requested · waiting for the current read", .{});
            return;
        }
        if (reply_all) |all| {
            if (self.messageId().len == 0) return;
            try self.start(.compose, .{ .account = self.account(), .cmd = "mail.reply", .messageId = self.messageId(), .all = all });
        } else try self.start(.compose, .{ .account = self.account(), .cmd = "draft.create", .draft = types.Draft{} });
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
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const draft_value = try self.compose.draft(arena.allocator());
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
    fn attachFile(self: *App, path: []const u8) !void {
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
        self.mode = .compose;
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
            .refresh, .list, .read, .thread, .drafts, .draft_read, .draft_operations, .contacts, .invitation_inspect => true,
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
        self.selected = 0;
        self.top = 0;
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
            self.reader_scroll = if (down) @min(self.reader_scroll +| amount, self.reader_lines -| 1) else self.reader_scroll -| amount;
        } else if (self.focus == .navigation) {
            const total = self.accounts.len + folders.len + 1;
            self.navigation = if (down) @min(self.navigation +| amount, total - 1) else self.navigation -| amount;
        } else {
            self.selected = if (down) @min(self.selected +| amount, self.messages.len -| 1) else self.selected -| amount;
            self.selection_generation +%= 1;
            try self.preview(false);
        }
    }
    fn adjacentMail(self: *App, next: bool) !void {
        if (self.drafts_list or self.messages.len == 0) return;
        const selected = layout.stepMessage(self.messages.len, self.selected, next);
        if (selected == self.selected) return;
        self.selected = selected;
        self.selection_generation +%= 1;
        self.reader_scroll = 0;
        self.focus = .reader;
        // This navigates mail, not a card within the current conversation.
        // Enter remains the explicit full-thread action for the new selection.
        try self.preview(false);
    }
    fn enter(self: *App) !void {
        if (self.focus == .navigation) {
            if (self.navigation < self.accounts.len) try self.chooseAccount(self.navigation) else if (self.navigation < self.accounts.len + folders.len) {
                self.folder = self.navigation - self.accounts.len;
                self.clearHistory();
                try self.cursor.set(self.allocator, "");
                self.selected = 0;
                self.top = 0;
                self.generation +%= 1;
                self.focus = .list;
                try self.reload();
            } else {
                self.picker = false;
                try self.loadContacts("");
            }
        } else if (self.drafts_list) {
            if (self.messageId().len > 0) try self.start(.draft_read, .{ .account = self.account(), .cmd = "draft.read", .draftId = self.messageId() });
        } else {
            self.focus = .reader;
            try self.preview(true);
        }
    }
    fn runEditor(self: *App) !void {
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
            self.compose.selected = 4;
            self.compose.insert_mode = false;
            self.editor_exit = value_in.exit_code;
        } else |_| {}
        // Restore even when the child cannot start, fails or is interrupted.
        _ = try vaxis.Tty.makeRaw(self.tty.fd.handle);
        try self.vx.enterAltScreen(writer);
        try self.vx.enableDetectedFeatures(writer);
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
    fn onKey(self: *App, key: Key) !void {
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
        if (self.mode == .compose) {
            if (self.job.future != null and !readOnlyJob(self.job.kind)) {
                if (key.matches('q', .{}) or key.matches(Key.escape, .{})) self.say(false, "Draft operation pending · wait for its result", .{});
                return;
            }
            if (key.matches('s', .{ .ctrl = true })) return self.saveDraft(.save_review);
            if (self.compose.unknown_outcome and !(key.matches(Key.escape, .{}) or key.matches('q', .{}) or key.matches(':', .{}))) {
                self.markUnknown(.send);
                return;
            }
            if (key.matches(Key.escape, .{})) {
                if (self.compose.insert_mode) self.compose.insert_mode = false else try self.saveDraft(.save_back);
            } else if (key.matches(Key.tab, .{})) {
                self.compose.selected = (self.compose.selected + 1) % 5;
            } else if (key.matches(Key.tab, .{ .shift = true })) {
                self.compose.selected = (self.compose.selected + 4) % 5;
            } else if (self.compose.insert_mode) {
                try self.compose.fields[self.compose.selected].handleKey(self.allocator, key, self.compose.selected == 4, if (self.compose.selected == 4) types.Limits.body_bytes else 16 * 1024);
            } else if (key.matches('i', .{}) or key.matches(Key.enter, .{})) self.compose.insert_mode = true else if (key.matches('e', .{})) try self.runEditor() else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.compose.selected = (self.compose.selected + 1) % 5 else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.compose.selected = (self.compose.selected + 4) % 5 else if (key.matches('a', .{})) {
                self.picker = true;
                try self.loadContacts("");
            } else if (key.matches('A', .{}) or key.matches('a', .{ .shift = true })) {
                self.previous_mode = .compose;
                self.mode = .attachment;
                try self.input.set(self.allocator, "");
            } else if (key.matches('q', .{})) try self.saveDraft(.save_back) else if (key.matches(':', .{})) {
                self.previous_mode = .compose;
                self.mode = .command;
                try self.input.set(self.allocator, "");
            }
            return;
        }
        if (self.mode == .review) {
            if (key.matches(Key.escape, .{}) or key.matches('q', .{}) or key.matches('n', .{})) self.mode = backMode(.review, self.previous_mode, self.picker) else if (key.matches('y', .{}) and self.job.future == null) try self.sendDraft() else if (key.matches('j', .{}) or key.matches(Key.down, .{})) self.reader_scroll +|= 1 else if (key.matches('k', .{}) or key.matches(Key.up, .{})) self.reader_scroll -|= 1 else if (key.matches(Key.page_down, .{})) self.reader_scroll +|= self.vx.window().height / 2 else if (key.matches(Key.page_up, .{})) self.reader_scroll -|= self.vx.window().height / 2;
            return;
        }
        if (self.mode == .trash_confirm) {
            if (key.matches(Key.escape, .{}) or key.matches('n', .{}) or key.matches('q', .{})) self.mode = backMode(.trash_confirm, self.previous_mode, self.picker) else if (key.matches('y', .{})) try self.start(.mutation, .{ .account = self.account(), .cmd = "mail.trash", .messageId = self.messageId() });
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
        if (self.mode == .search or self.mode == .command or self.mode == .labels or self.mode == .attachment) {
            if (key.matches(Key.escape, .{})) self.mode = self.previous_mode else if (key.matches(Key.enter, .{})) {
                const previous_mode = self.previous_mode;
                if (self.mode == .attachment) {
                    try self.attachFile(self.input.value());
                } else if (self.mode == .command) {
                    if (same(self.input.value(), "layout right")) {
                        self.setReaderLayout(.right);
                    } else if (same(self.input.value(), "layout below")) {
                        self.setReaderLayout(.below);
                    } else if (std.mem.startsWith(u8, self.input.value(), "save-attachment ") or std.mem.startsWith(u8, self.input.value(), "save-attachment\t")) {
                        try self.saveIncomingAttachment(self.input.value()[16..]);
                    } else if (same(self.input.value(), "receipt") and previous_mode == .compose) {
                        try self.inspectDraftOperations();
                    } else if (same(self.input.value(), "send") and previous_mode == .compose) try self.saveDraft(.save_review) else if (std.mem.startsWith(u8, self.input.value(), "detach ") and previous_mode == .compose and !self.compose.unknown_outcome) {
                        const number = try std.fmt.parseInt(usize, std.mem.trim(u8, self.input.value()[7..], " \t"), 10);
                        if (number == 0 or number > self.compose.attachments.len) return error.InvalidAttachment;
                        var retained: [16]types.Attachment = undefined;
                        var count: usize = 0;
                        for (self.compose.attachments, 0..) |item, index| if (index != number - 1) {
                            retained[count] = item;
                            count += 1;
                        };
                        try self.compose.replaceAttachments(self.allocator, retained[0..count]);
                        self.say(false, "Attachment removed · Ctrl+S Review send", .{});
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
                    try self.query.set(self.allocator, self.input.value());
                    self.query_scope = self.input_query_scope;
                    self.clearHistory();
                    try self.cursor.set(self.allocator, "");
                    self.generation +%= 1;
                    self.selected = 0;
                    self.top = 0;
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
            } else if (key.matches('n', .{}) and self.contacts_state != .denied) try self.editContact(null) else if (key.matches('e', .{}) and self.contacts_selected < self.contacts.len and self.contacts_state != .denied) try self.editContact(self.contacts[self.contacts_selected]) else if (key.matches(Key.enter, .{}) and self.contacts_selected < self.contacts.len) {
                if (self.picker) {
                    const emails = items(get(self.contacts[self.contacts_selected], "emails"));
                    if (emails.len > 0) {
                        const address = text(get(emails[0], "address"));
                        try recipients.validateAddress(address);
                        const target = &self.compose.fields[if (self.compose.selected < 3) self.compose.selected else 0];
                        target.cursor = target.bytes.items.len;
                        if (target.value().len > 0) try target.insert(self.allocator, ", ", 16 * 1024);
                        try target.insert(self.allocator, address, 16 * 1024);
                    }
                    self.leaveContacts();
                } else try self.editContact(self.contacts[self.contacts_selected]);
            }
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
            if (self.focus == .reader) self.reader_scroll = self.reader_lines -| 1 else {
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
        try self.line(win, 0, "ACCOUNTS", .muted);
        var row: usize = 1;
        for (self.accounts, 0..) |account_value, index| {
            const address = text(get(account_value, "address"));
            const value_in = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (index == self.account_index) "> " else "  ", address });
            // Use wrapped text so complete account identities remain accessible.
            const child = win.child(.{ .y_off = @intCast(@min(row, max_rows)) });
            const result = child.printSegment(.{ .text = try safe(self.frame.allocator(), value_in, false), .style = self.style(if (self.focus == .navigation and self.navigation == index) .selected else if (index == self.account_index) .accent else .text) }, .{ .wrap = .grapheme });
            row += @as(usize, result.row) + 1;
        }
        row += 1;
        try self.line(win, row, "MAILBOXES", .muted);
        row += 1;
        for (folders, 0..) |name, index| {
            const value_in = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (index == self.folder) "> " else "  ", name });
            try self.line(win, row + index, value_in, if (self.focus == .navigation and self.navigation == self.accounts.len + index) .selected else if (index == self.folder) .accent else .text);
        }
        try self.line(win, row + folders.len + 1, "Contacts", if (self.focus == .navigation and self.navigation == self.accounts.len + folders.len) .selected else .text);
    }
    fn listDraw(self: *App, win: vaxis.Window) !void {
        const count = @max(win.height / 3, 1);
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + count) self.top = self.selected + 1 - count;
        if (self.messages.len == 0) {
            const status = self.sync[self.account_index].state;
            try self.line(win, 1, if (status == .fetching) "Fetching mail…" else if (self.job.future != null and self.drafts_list) "Loading drafts…" else if (status == .failed or self.warning) "Mail unavailable; see status below" else if (self.list_cached and self.list_partial) "No rows in cached subset" else "No matching messages", if (status == .fetching) .fetching else .muted);
            if (status == .fetching) try self.line(win, 3, "j/k Move · h/l Pane · ? Help", .muted);
            return;
        }
        var index = self.top;
        while (index < self.messages.len and index < self.top + count) : (index += 1) {
            const value_in = self.messages[index];
            const row = (index - self.top) * 3;
            const sender = get(value_in, "from");
            const sender_text = if (text(get(sender, "name")).len > 0) text(get(sender, "name")) else text(get(sender, "address"));
            const selected = index == self.selected;
            const item = win.child(.{ .y_off = @intCast(row), .height = @min(@as(u16, 2), win.height -| @as(u16, @intCast(row))) });
            item.fill(.{ .style = self.style(if (selected) .selected else .text) });
            const stamp = try timestamp(self.frame.allocator(), get(value_in, "receivedAt"));
            const compact = if (stamp.len >= 16) stamp[5..16] else stamp;
            const date_width: u16 = if (win.width >= 48) @intCast(compact.len) else 0;
            const subject_width = win.width -| date_width -| @as(u16, if (date_width > 0) 1 else 0);
            const subject = text(get(value_in, "subject"));
            const subject_text = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}", .{ if (truth(get(value_in, "unread"))) "● " else "  ", if (subject.len == 0) "(no subject)" else subject });
            _ = item.child(.{ .height = 1, .width = subject_width }).printSegment(.{ .text = try self.fitLine(win, subject_text, subject_width), .style = self.listStyle(.subject, selected) }, .{ .wrap = .none });
            if (date_width > 0) _ = item.child(.{ .x_off = win.width - date_width, .height = 1, .width = date_width }).printSegment(.{ .text = compact, .style = self.listStyle(.muted, selected) }, .{ .wrap = .none });
            const sender_limit = @min(win.width / 2, 28);
            const shown_sender = try self.fitLine(win, if (self.drafts_list) "Draft" else sender_text, sender_limit);
            const sender_line = item.child(.{ .y_off = 1, .height = 1 });
            const printed = sender_line.printSegment(.{ .text = shown_sender, .style = self.listStyle(.sender, selected) }, .{ .wrap = .none });
            if (printed.col +| 3 < sender_line.width) {
                const snippet = try self.fitLine(win, text(get(value_in, "snippet")), sender_line.width - printed.col - 3);
                _ = sender_line.child(.{ .x_off = printed.col }).printSegment(.{ .text = try std.fmt.allocPrint(self.frame.allocator(), " — {s}", .{snippet}), .style = self.listStyle(.muted, selected) }, .{ .wrap = .none });
            }
        }
    }
    fn flow(self: *App, win: vaxis.Window, value_in: []const u8, offset: usize, base_row: usize) !usize {
        return self.flowTone(win, value_in, offset, base_row, .text);
    }
    fn flowTone(self: *App, win: vaxis.Window, value_in: []const u8, offset: usize, base_row: usize, tone: Tone) !usize {
        if (win.width == 0) return base_row;
        const clean = try safe(self.frame.allocator(), value_in, true);
        var iterator = vaxis.unicode.graphemeIterator(clean);
        var position: TextPosition = .{ .row = base_row };
        while (iterator.next()) |gr| {
            const raw = gr.bytes(clean);
            if (same(raw, "\n")) {
                position.newline();
                continue;
            }
            const grapheme = if (raw.len > 128) "�" else raw;
            const width = @max(win.gwidth(grapheme), 1);
            position.wrap(width, win.width);
            if (position.row >= offset and position.row - offset < win.height and width <= win.width) win.writeCell(position.column, @intCast(position.row - offset), .{ .char = .{ .grapheme = grapheme, .width = @intCast(@min(width, 255)) }, .style = self.style(tone) });
            position.column +|= width;
        }
        return position.row + 1;
    }
    fn readerDraw(self: *App, outer: vaxis.Window) !void {
        const browsing = self.mode == .browse or (self.mode == .help and self.previous_mode == .browse) or (self.mode == .command and self.previous_mode == .browse);
        const toolbar_rows: u16 = if (browsing) 1 else 0;
        if (browsing) try self.line(outer, 0, "J/K Mail · j/k Scroll · v Layout · z Expand", .accent);
        if (self.reader_partial) try self.line(outer, toolbar_rows, "Cached thread · partial", .muted);
        const header_rows = toolbar_rows + @as(u16, if (self.reader_partial) 1 else 0);
        const win = outer.child(.{ .y_off = header_rows, .height = outer.height -| header_rows });
        if (self.thread.len == 0) {
            if (self.reader_cache_busy) {
                try self.line(win, 1, "Cache busy · local read queued", .muted);
                try self.line(win, 3, "Input or refresh completion retries locally", .muted);
            } else if (self.body_cache_miss) {
                const fetching = self.job.future != null and (self.job.kind == .read or self.job.kind == .thread);
                const refused = if (self.selectedMessage()) |message| bodyRefusal(message) else null;
                try self.line(win, 1, if (refused) |reason| try std.fmt.allocPrint(self.frame.allocator(), "Body unavailable · {s}", .{reason}) else if (self.pending_read) "Body not cached · fetch queued" else if (fetching) "Body not cached · fetching" else "Body not cached · Enter fetches full mail", if (refused != null) .warning else if (fetching or self.pending_read) .fetching else .muted);
                if (self.selectedMessage()) |message| {
                    try self.line(win, 3, text(get(message, "subject")), .text);
                    if (refused != null) try self.line(win, 4, "Snippet only · o Open in Gmail", .muted);
                    _ = try self.flow(win, text(get(message, "snippet")), 0, 5);
                }
            } else try self.line(win, 1, if (self.sync[self.account_index].state == .fetching) "Fetching mail · cached bodies appear here" else "Select mail · Enter opens the thread", .muted);
            return;
        }
        var row: usize = 0;
        var attachment_number: usize = 0;
        for (self.thread) |message| {
            const from = get(message, "from");
            const to = try Compose.mailboxes(self.frame.allocator(), get(message, "to"));
            const cc = try Compose.mailboxes(self.frame.allocator(), get(message, "cc"));
            const subject = text(get(message, "subject"));
            row = try self.flowTone(win, if (subject.len == 0) "(no subject)" else subject, self.reader_scroll, row, .subject);
            const sender_line = try std.fmt.allocPrint(self.frame.allocator(), "From: {s} <{s}>", .{ text(get(from, "name")), text(get(from, "address")) });
            row = try self.flowTone(win, sender_line, self.reader_scroll, row, .sender);
            const envelope = try readerEnvelope(self.frame.allocator(), to, cc, try timestamp(self.frame.allocator(), get(message, "receivedAt")));
            row = try self.flowTone(win, envelope, self.reader_scroll, row, .muted);
            row += 1; // Exactly one visual blank before the unchanged body.
            row = try self.flow(win, text(get(message, "bodyText")), self.reader_scroll, row);
            for (items(get(message, "attachments"))) |attachment| {
                attachment_number += 1;
                const value_in = try std.fmt.allocPrint(self.frame.allocator(), "Attachment {d}: {s}\n:save-attachment {d} /absolute/path\n", .{ attachment_number, text(get(attachment, "filename")), attachment_number });
                row = try self.flow(win, value_in, self.reader_scroll, row);
            }
            if (get(message, "invitation") != .null) row = try self.flow(win, "Invitation · I Review RSVP\n", self.reader_scroll, row);
            row = try self.flow(win, "\n────────────────────\n", self.reader_scroll, row);
        }
        self.reader_lines = row;
        self.reader_scroll = @min(self.reader_scroll, row -| @as(usize, win.height));
    }
    fn composeDraw(self: *App, win: vaxis.Window) !void {
        if (self.mode == .review) {
            const inner = self.panel(win, 0, win.width, " Review send · y SEND · Esc Back ", true);
            const review = try std.fmt.allocPrint(self.frame.allocator(), "Sending account: {s}\nFrom: {s}\nTo: {s}\nCc: {s}\nBcc: {s}\nSubject: {s}\nThread: {s}\n\n{s}", .{ self.account(), self.account(), self.compose.fields[0].value(), self.compose.fields[1].value(), self.compose.fields[2].value(), self.compose.fields[3].value(), self.compose.thread.value(), self.compose.fields[4].value() });
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
        const left = self.panel(win, 0, left_width, if (self.mode == .review) " Review send " else " Compose · local draft ", true);
        try self.line(left, 0, try std.fmt.allocPrint(self.frame.allocator(), "From: {s}", .{self.account()}), .accent);
        if (self.compose.unknown_outcome) try self.line(left, 1, try std.fmt.allocPrint(self.frame.allocator(), "Operation: {s}", .{self.compose.operation_id.value()}), .warning);
        for ([_][]const u8{ "To", "Cc", "Bcc", "Subject" }, 0..) |name, index| {
            const field = &self.compose.fields[index];
            const editing = self.compose.selected == index and self.compose.insert_mode;
            try self.editLine(left, index + 2, name, field, editing, if (self.compose.selected == index and self.mode == .compose) .selected else .text);
        }
        try self.line(left, 7, if (self.compose.selected == 4 and self.compose.insert_mode) "Body: INSERT · Esc Normal" else "Body:", if (self.compose.selected == 4) .accent else .muted);
        const body = left.child(.{ .y_off = 8, .height = left.height -| 10 });
        // Measure the same sanitized graphemes and wrapping as the renderer.
        // Newline counts alone cannot keep a long single paragraph's caret in view.
        const value_in = self.compose.fields[4].value();
        const cursor_at = self.compose.fields[4].cursor;
        const editing_body = self.compose.selected == 4 and self.compose.insert_mode;
        if (editing_body and body.width > 0 and body.height > 0) {
            const before = try safe(self.frame.allocator(), value_in[0..cursor_at], true);
            var caret = positionAfter(body, before);
            caret.wrap(@max(body.gwidth("▏"), 1), body.width);
            if (caret.row < self.compose.body_scroll) self.compose.body_scroll = caret.row;
            if (caret.row -| self.compose.body_scroll >= body.height) self.compose.body_scroll = caret.row + 1 - body.height;
        }
        const body_text = if (editing_body) try std.fmt.allocPrint(self.frame.allocator(), "{s}▏{s}", .{ value_in[0..cursor_at], value_in[cursor_at..] }) else value_in;
        const body_lines = try self.flow(body, body_text, self.compose.body_scroll, 0);
        self.compose.body_scroll = @min(self.compose.body_scroll, body_lines -| @as(usize, body.height));
        if (left.height > 2) try self.line(left, left.height - 2, if (self.compose.unknown_outcome) "Protected recovery draft · :receipt Check · q Back" else "i Insert · Tab Field · a Contacts · e $EDITOR · Ctrl+S Review", .accent);
        if (split) {
            const right = self.panel(win, left_width, win.width - left_width, if (self.compose.unknown_outcome) " Submission receipt " else " Original thread / preview ", false);
            if (self.compose.unknown_outcome) {
                const receipt = try std.fmt.allocPrint(self.frame.allocator(), "Outcome unknown\nOperation: {s}\nReason: {s}\n\nThe original recovery draft is protected.\nNo edit or automatic resend.\n\n:receipt checks the journal.\nq keeps it and returns to mail.", .{ self.compose.operation_id.value(), self.compose.operation_error.value() });
                _ = try self.flow(right, receipt, 0, 0);
            } else if (self.thread.len > 0) try self.readerDraw(right) else {
                try self.line(right, 1, "Draft preview", .muted);
                _ = try self.flow(right.child(.{ .y_off = 3 }), value_in, 0, 0);
            }
        }
    }
    fn contactsDraw(self: *App, win: vaxis.Window) !void {
        const inner = self.panel(win, 0, win.width, if (self.picker) " Choose recipient " else " Contacts ", true);
        if (self.mode == .contact_edit) {
            try self.line(inner, 1, try std.fmt.allocPrint(self.frame.allocator(), "Name: {s}▏", .{self.contact_name.value()}), if (self.contact_field == 0) .selected else .text);
            try self.line(inner, 3, try std.fmt.allocPrint(self.frame.allocator(), "Email: {s}▏", .{self.contact_email.value()}), if (self.contact_field == 1) .selected else .text);
            try self.line(inner, 6, "Tab Field · Ctrl+S Save · Esc Cancel", .accent);
            return;
        }
        const phase = switch (self.contacts_state) {
            .loading => if (self.job.future != null and self.job.kind == .contacts) "Loading contacts…" else "Loading contacts · request queued",
            .cached => if (self.job.future != null and self.job.kind == .contacts) "Refreshing cached contacts" else if (self.pending_contacts) "Cached contacts · refresh queued" else "Cached contacts",
            .current => "Contacts ready",
            .denied => "Contacts permission required · contacts-read",
            .failed => "Contacts unavailable · retained entries remain usable",
            .busy => "Cache busy · contacts retry locally",
        };
        try self.line(inner, 0, phase, if (self.contacts_state == .denied or self.contacts_state == .failed) .warning else if (self.contacts_state == .loading) .fetching else .muted);
        if (self.contacts_state == .denied) {
            try self.line(inner, 2, "A separate terminal contacts-read grant is required.", .text);
            try self.line(inner, 4, "? Help · Esc / q Back · no consent starts here", .muted);
            return;
        }
        if (self.contacts.len == 0 and self.contacts_cache_ready) try self.line(inner, 2, "No contacts · n Create contact", .muted);
        const visible = @max((inner.height -| 2) / 2, 1);
        const top = self.contacts_selected -| @as(usize, visible - 1);
        var index = top;
        while (index < self.contacts.len and index - top < visible) : (index += 1) {
            const contact = self.contacts[index];
            try self.line(inner, 2 + (index - top) * 2, text(get(contact, "name")), if (index == self.contacts_selected) .selected else .text);
            try self.line(inner, 3 + (index - top) * 2, try Compose.mailboxes(self.frame.allocator(), get(contact, "emails")), .muted);
        }
    }
    fn contextHints(self: *const App) []const u8 {
        return switch (self.mode) {
            .contacts => " j/k Move  / Search  n New  e Edit  ? Help  Esc/q Back",
            .contact_edit => " Tab Field  Ctrl+S Save  Esc Contacts  q is text",
            .compose => if (self.compose.unknown_outcome) " Protected recovery draft · :receipt Check · q Keep/back" else if (self.compose.insert_mode) " INSERT · Tab Field · Esc Normal · q is text" else " i Edit  a Contacts  e $EDITOR  Ctrl+S Review  q Save/back",
            .review => if (self.job.future != null and self.job.kind == .send) " Submission pending · awaiting receipt · q Draft" else " y Explicit send  j/k Scroll  Esc/q Return to draft",
            .help => " j/k Scroll  Home/End  Esc/q Return",
            .trash_confirm => " y Confirm Trash  n/Esc/q Cancel",
            .invitation => " a Accept  t Tentative  d Decline  Esc/q Cancel",
            .browse => if (self.expanded) " J/K Mail  j/k Scroll  v Layout  z/Esc/q Shrink reader" else if (self.focus == .reader) " J/K Mail  j/k Scroll  h/Esc/q List  v Layout  z Expand  r Reply  ? Help" else if (self.focus == .navigation) " j/k Navigate  Enter Choose  l/Esc/q Mail  ? Help" else if (self.cacheSearch()) " Cache subset · / Cache  \\ Gmail  l Reader  c Compose  q Clear cache search" else if (self.query.value().len > 0) " Gmail search · / Cache  \\ Gmail  l Reader  c Compose  q Clear Gmail search" else " j/k Mail  h/l Pane  / Cache  \\ Gmail  c Compose  v Layout  ? Help  q Quit",
            else => " Esc Back",
        };
    }
    fn overlay(self: *App, win: vaxis.Window, title: []const u8, body: []const u8) !void {
        const width = @min(win.width, 78);
        const height = @min(win.height, 20);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, title, true);
        _ = try self.flow(inner, body, 0, 0);
    }
    fn helpDraw(self: *App, win: vaxis.Window) !void {
        const width = @min(win.width -| 2, 78);
        const height = @min(win.height -| 2, 20);
        const area = win.child(.{ .x_off = @intCast((win.width - width) / 2), .y_off = @intCast((win.height - height) / 2), .width = width, .height = height });
        area.fill(.{ .style = self.style(.text) });
        const inner = self.panel(area, 0, width, " Keys · j/k Scroll · Esc Back ", true);
        const clean = try safe(self.frame.allocator(), help_text, true);
        self.help_lines = positionAfter(inner, clean).row + 1;
        self.help_height = inner.height;
        self.help_scroll = @min(self.help_scroll, self.help_lines -| self.help_height);
        _ = try self.flow(inner, clean, self.help_scroll, 0);
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
        _ = self.frame.reset(.retain_capacity);
        const win = self.vx.window();
        self.invitation_confirm_ready = false;
        win.clear();
        win.hideCursor();
        win.fill(.{ .style = self.style(.text) });
        if (win.width < 30 or win.height < 10) {
            try self.line(win, 0, "omagma · resize terminal · q quits", .accent);
            return;
        }
        const header = try std.fmt.allocPrint(self.frame.allocator(), " omagma · Experimental   {s}   |   {s}{s}   |   Reader {s}{s}", .{ self.account(), folders[self.folder], if (self.cacheSearch()) " / Cache search" else if (self.query.value().len > 0) " / Gmail search" else "", @tagName(self.reader_layout), if (self.options.fixtures) "   ·   Mock provider" else "" });
        try self.line(win, 0, header, .accent);
        try self.line(win, 1, try self.syncLine(), self.syncTone());
        const body = win.child(.{ .y_off = 2, .height = win.height -| 4 });
        if (self.mode == .compose or self.mode == .review or self.mode == .attachment) try self.composeDraw(body) else if (self.mode == .contacts or self.mode == .contact_edit or (self.mode == .search and self.previous_mode == .contacts)) try self.contactsDraw(body) else {
            const panes = layout.compute(body.width, body.height, self.focus, self.reader_layout, self.expanded);
            if (panes.navigation) |rect| try self.navigationDraw(self.pane(body, rect, " Accounts / mailboxes ", self.focus == .navigation));
            if (panes.list) |rect| try self.listDraw(self.pane(body, rect, if (self.cacheSearch()) " Mail · Cache subset " else if (self.query.value().len > 0) " Mail · Gmail search " else " Mail · [ ] Page ", self.focus == .list));
            if (panes.reader) |rect| try self.readerDraw(self.pane(body, rect, " Thread / full body ", self.focus == .reader));
        }
        if (self.mode == .search or self.mode == .command or self.mode == .labels or self.mode == .attachment) {
            const prompt = try std.fmt.allocPrint(self.frame.allocator(), "{s}{s}▏", .{ if (self.mode == .command) ":" else if (self.mode == .labels) "Label (name adds, -name removes): " else if (self.mode == .attachment) "Attach file path: " else if (self.previous_mode == .contacts) "Contacts / " else if (self.input_query_scope == .cache) "Cache / " else "Gmail \\ ", self.input.value() });
            try self.line(win, win.height - 2, prompt, .selected);
        } else try self.line(win, win.height - 2, self.contextHints(), .muted);
        try self.line(win, win.height - 1, self.status[0..self.status_len], if (self.warning) .warning else .muted);
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

pub fn run(io: Io, allocator: Allocator, client: types.Client, options: types.Options, environ: *const std.process.Environ.Map) !void {
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
    try app.boot();
    app.reloadTheme();
    app.loadPreferences();
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
        app.say(true, "Cache: {s}", .{@errorName(err)});
        break :blk false;
    };
    app.sync[app.account_index].state = if (app.sync[app.account_index].cache_ready) .refreshing else .fetching;
    try app.draw();
    try vx.render(tty.writer());
    try tty.writer().flush();
    // The first colored phase and available cached bodies are already on
    // screen before terminal capability negotiation or any provider fetch.
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try app.refreshMailbox();
    while (!app.quit and received_signal.load(.acquire) == 0) {
        app.finish() catch |err| app.say(true, "{s}", .{@errorName(err)});
        try app.draw();
        try vx.render(tty.writer());
        try tty.writer().flush();
        const event = loop.nextEvent() catch |err| switch (err) {
            error.Closed, error.EndOfStream => break,
            else => return err,
        };
        switch (event) {
            .key_press => |key| app.onKey(key) catch |err| app.say(true, "{s} · retained data kept", .{@errorName(err)}),
            .winsize => |size| try app.resize(size),
            .paste_start => app.paste = true,
            .paste_end => app.paste = false,
            .operation_done => {},
            .terminate => break,
        }
    }
    app.cancelJob();
    try app.persistDraftAtExit();
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
