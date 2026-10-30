const std = @import("std");
pub const Limits = struct {
    pub const runtime_bytes: usize = 64 * 1024 * 1024;
    pub const request_bytes: usize = 3 * 1024 * 1024;
    pub const body_bytes: usize = 2 * 1024 * 1024;
    /// Serialized full DTOs retained by one conversation response. Additional
    /// member IDs remain visible as small explicit metadata placeholders.
    pub const thread_bytes: usize = 4 * 1024 * 1024;
    pub const metadata_batch_bytes: usize = 4 * 1024 * 1024;
    pub const native = @import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos;
    pub const portable_attachments: usize = 16;
    /// Accumulated inline images are independent of user-added file slots.
    /// Bound metadata work while allowing long screenshot-rich reply chains;
    /// decoded-byte and encoded-MIME quotas still govern actual payload size.
    pub const related_resources: usize = 1024;
    /// Incoming descriptors include the sender's generated signature image.
    pub const message_attachments: usize = portable_attachments + related_resources + 1;
    /// Native files share the existing MIME descriptor budget with related
    /// parts. Payload admission still uses decoded and encoded byte limits.
    pub const attachments: usize = if (native) message_attachments - 1 else portable_attachments;
    pub fn validateComposeParts(files: usize, related: usize) !void {
        if (files > attachments or related > related_resources) return error.TooManyAttachments;
        if (native and files > message_attachments - 1 - related) return error.TooManyAttachments;
    }
    /// Informational source files excluded from a text-only forward.
    pub const omitted_attachment_count: usize = message_attachments;
    /// Combined decoded ordinary outgoing files. Incoming saves have their own cap.
    pub const attachment_bytes: usize = 25 * 1024 * 1024;
    pub const incoming_attachment_bytes: usize = @import("../attachment_limits.zig").incoming_bytes;
    pub const mime_upload_bytes: usize = 35 * 1024 * 1024;
    /// Native compose work can use transient memory up to the provider's MIME
    /// size ceiling. Browser/WASM keeps its smaller in-memory text allowance.
    pub const native_body_bytes: usize = mime_upload_bytes;
    pub const compose_body_bytes: usize = switch (@import("builtin").os.tag) {
        .linux, .macos => native_body_bytes,
        else => body_bytes,
    };
    pub const page: usize = 100;
    /// Gmail API submission allows 500 total To/Cc/Bcc destinations.
    pub const recipients: usize = if (native) 500 else 32;
    /// Gmail supports 10,000 mailbox labels; browser storage remains bounded.
    pub const labels: usize = if (native) 10000 else 512;
    pub const metadata: usize = 2000;
    pub const metadata_hard: usize = 10000;
    pub const disk_bytes: usize = 256 * 1024 * 1024;
    pub const disk_hard: usize = 1024 * 1024 * 1024;
};
pub const Options = struct {
    fixtures: bool = false,
    fixture_root: ?[]const u8 = null,
    fixture_scenario: []const u8 = "normal",
    cache_dir: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    grant_file: ?[]const u8 = null,
    ui_file: ?[]const u8 = null,
    // With a daemon, private UI state belongs to its encrypted store as well.
    remote_preferences: bool = false,
    account: ?[]const u8 = null,
    metadata_limit: usize = Limits.metadata,
    disk_limit: usize = Limits.disk_bytes,
    metadata_limit_set: bool = false,
    disk_limit_set: bool = false,
    use_persisted_policy: bool = false,
    body_prefetch_limit: usize = 32,
    body_prefetch_limit_set: bool = false,
    editor_mode: []const u8 = "auto",
    no_mouse: bool = false,
    /// Internal UI routing only: an explicit --backend socket, repeated in
    /// printed authorization commands. Never set for an auto-activated vault.
    backend_socket: ?[]const u8 = null,
};
pub const FetchPhase = enum(u8) { metadata, bodies, drive_reserving, drive_uploading, drive_sharing, mail_submitting };
pub const FetchProgress = struct { phase: FetchPhase, completed: usize, total: usize, fileIndex: ?usize = null, fileCount: ?usize = null };
/// Borrowed only for the synchronous callback. Consumers copy a bounded
/// preview; neither these slices nor provider response storage may escape it.
pub const FetchRow = struct {
    kind: enum { page, view, body },
    index: usize = 0,
    total: usize = 0,
    message: Message,
    failed: bool = false,
};
/// Report/row callbacks run synchronously and must not allocate, perform
/// network/storage work or wait deliberately. A short queue wake is allowed.
/// beforeMail is a separate explicit, cancellable transport boundary.
pub const ProgressSink = struct {
    ctx: *anyopaque,
    reportFn: *const fn (*anyopaque, FetchProgress) void,
    rowFn: ?*const fn (*anyopaque, FetchRow) void = null,
    /// Explicit cancellable boundary after mail_submitting, before the Gmail
    /// fence. A transport may wait for that final frame; reportFn never waits.
    beforeMailFn: ?*const fn (*anyopaque) anyerror!void = null,
    execution_budget: ?*@import("send_budget.zig").Budget = null,
    pub fn beforeMail(self: ProgressSink) !void {
        if (self.beforeMailFn) |function| try function(self.ctx);
    }
    pub fn report(self: ProgressSink, progress: FetchProgress) void {
        self.reportFn(self.ctx, progress);
    }
    pub fn row(self: ProgressSink, update: FetchRow) void {
        if (self.rowFn) |function| function(self.ctx, update);
    }
};
/// Private file identity only; no cache paths or account data cross the callback.
pub const CacheStamp = struct { inode: u64, size: u64, mtime_ns: i128 };
/// The caller owns returned JSON bytes. Requests share the agent CLI contract.
pub const Client = struct {
    ctx: *anyopaque,
    callFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,
    cachedFn: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8 = null,
    cacheStampFn: ?*const fn (*anyopaque, []const u8) anyerror!?CacheStamp = null,
    callProgressFn: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ProgressSink) anyerror![]const u8 = null,
    /// A receipt is accepted only after its consumer has safely applied it.
    /// This acknowledges consumption, not provider delivery; the request is
    /// borrowed only for this synchronous, non-fallible callback.
    sendReceiptFn: ?*const fn (*anyopaque, []const u8, bool) void = null,
    pub fn cacheStamp(self: Client, account: []const u8) !?CacheStamp {
        return (self.cacheStampFn orelse return error.CacheUnsupported)(self.ctx, account);
    }
    pub fn callCached(self: Client, allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
        return (self.cachedFn orelse return error.CacheUnsupported)(self.ctx, allocator, request);
    }
    pub fn call(self: Client, allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
        return self.callFn(self.ctx, allocator, request);
    }
    pub fn callWithProgress(self: Client, allocator: std.mem.Allocator, request: []const u8, sink: ProgressSink) ![]const u8 {
        return if (self.callProgressFn) |function| function(self.ctx, allocator, request, sink) else self.callFn(self.ctx, allocator, request);
    }
    pub fn sendReceipt(self: Client, request: []const u8, accepted: bool) void {
        if (self.sendReceiptFn) |function| function(self.ctx, request, accepted);
    }
};
pub const Address = struct { address: []const u8, name: []const u8 = "" };
pub const AttachmentDelivery = enum { attach, auto, drive };
pub const Attachment = struct {
    id: []const u8,
    filename: []const u8,
    mimeType: []const u8 = "application/octet-stream",
    size: usize = 0,
    data: []const u8 = "",
    /// Immutable account-scoped local content handle. The sender opens it
    /// through the account store, never as an arbitrary filesystem path.
    blobId: ?[]const u8 = null,
    /// Null preserves legacy attachment serialization and send fingerprints.
    delivery: ?AttachmentDelivery = null,
    contentId: ?[]const u8 = null,
    disposition: ?[]const u8 = null,
    contentLocation: ?[]const u8 = null,
};
pub const BodySource = enum { unknown, plain, html };
/// bodyText stays the editable source. Legacy drafts and omitted CLI fields
/// retain their literal meaning; fresh TUI composers opt into Markdown.
pub const BodyFormat = enum { plain, markdown };
pub const Message = struct {
    id: []const u8,
    threadId: []const u8,
    from: Address = .{ .address = "" },
    replyTo: []const Address = &.{},
    to: []const Address = &.{},
    cc: []const Address = &.{},
    subject: []const u8 = "",
    snippet: []const u8 = "",
    bodyText: []const u8 = "",
    bodyHtml: ?[]const u8 = null,
    bodyHtmlAmbiguous: bool = false,
    bodySource: BodySource = .unknown,
    messageId: []const u8 = "",
    references: []const u8 = "",
    inReplyTo: []const u8 = "",
    labels: []const []const u8 = &.{},
    receivedAt: i64 = 0,
    sentDate: ?[]const u8 = null,
    unread: bool = false,
    bodyCached: bool = false,
    bodyCacheError: []const u8 = "",
    /// A bounded decoder error code accompanies safe partial projections.
    /// Display-only envelope fallbacks never populate reply destinations.
    decodeWarning: []const u8 = "",
    metadataPartial: bool = false,
    /// False means absent/invalid labels must not replace prior membership.
    labelsVerified: bool = true,
    attachments: []const Attachment = &.{},
    invitation: ?[]const u8 = null,
    /// Independent wire oracle for synthetic fixture sends only. Production
    /// messages never populate or persist raw MIME through this field.
    fixtureRaw: ?[]const u8 = null,
};
/// Frozen source for an inline formatted reply/forward. bodyText in the draft
/// remains the separately editable personal note.
pub const Original = struct {
    version: u8 = 1,
    sourceMessageId: []const u8 = "",
    from: Address = .{ .address = "" },
    to: []const Address = &.{},
    cc: []const Address = &.{},
    subject: []const u8 = "",
    date: []const u8 = "",
    bodyText: []const u8 = "",
    bodyHtml: []const u8 = "",
    resources: []const Attachment = &.{},
};
pub const DraftSummaryCounts = struct { to: usize, cc: usize, bcc: usize, attachments: usize };
pub const Draft = struct {
    id: []const u8 = "",
    from: ?Address = null,
    /// Internal navigation metadata only. Exact saved draft sources omit it.
    summaryCounts: ?DraftSummaryCounts = null,
    /// Preserve the immutable source while optionally omitting it from wire MIME.
    includeOriginal: bool = true,
    /// Incomplete composer fields retained by local autosave. Such a draft
    /// requires a normal validated update before it can be submitted.
    recoveryFields: ?[]const []const u8 = null,
    to: []const Address = &.{},
    cc: []const Address = &.{},
    bcc: []const Address = &.{},
    subject: []const u8 = "",
    bodyText: []const u8 = "",
    bodyFormat: BodyFormat = .plain,
    threadId: []const u8 = "",
    inReplyTo: []const u8 = "",
    references: []const u8 = "",
    attachments: []const Attachment = &.{},
    original: ?Original = null,
    /// Informational warning retained through review of a text-only forward.
    /// These files are absent from the draft and never submitted to the sender.
    omittedAttachments: usize = 0,
};
pub const LabelColor = struct { backgroundColor: []const u8, textColor: []const u8 };
/// Bounded counts, never provider text. Kept with cached pages so an omitted
/// record cannot turn into an apparently complete empty address book offline.
pub const ContactReadWarnings = struct {
    omittedContacts: u32 = 0,
    partialContacts: u32 = 0,
    omittedEmails: u32 = 0,
    omittedNames: u32 = 0,
    sanitizedNames: u32 = 0,
    omittedMetadata: u32 = 0,
    invalidFields: u32 = 0,
    pub fn any(self: @This()) bool {
        inline for (@typeInfo(@This()).@"struct".field_names) |name| if (@field(self, name) != 0) return true;
        return false;
    }
    pub fn add(self: *@This(), other: @This()) void {
        inline for (@typeInfo(@This()).@"struct".field_names) |name| @field(self, name) +|= @field(other, name);
    }
};
pub const Contact = struct {
    resourceName: []const u8 = "",
    etag: []const u8 = "",
    name: []const u8 = "",
    emails: []const Address = &.{},
    readWarnings: ContactReadWarnings = .{},
    /// Bounded People fields for complete native reads. Partial/browser reads
    /// omit this object. Updates fetch a strictly decoded current provider
    /// version; cached fields are never a write precondition.
    provider: ?std.json.Value = null,
};

/// Immutable remote preparation receipt retained with a Gmail operation.
/// No resumable session URL or credential is serialized here.
pub const DriveFileReceipt = struct {
    index: usize,
    filename: []const u8,
    size: usize,
    state: []const u8,
    driveFileId: []const u8,
    link: ?[]const u8 = null,
    sharedWith: []const []const u8 = &.{},
    sharingUnconfirmedWith: ?[]const u8 = null,
};
