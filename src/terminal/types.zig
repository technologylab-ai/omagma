const std = @import("std");
pub const Limits = struct {
    pub const runtime_bytes: usize = 64 * 1024 * 1024;
    pub const request_bytes: usize = 3 * 1024 * 1024;
    pub const body_bytes: usize = 2 * 1024 * 1024;
    pub const page: usize = 100;
    pub const recipients: usize = 32;
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
};
pub const FetchPhase = enum(u8) { metadata, bodies };
pub const FetchProgress = struct { phase: FetchPhase, completed: usize, total: usize };
/// Borrowed only for the synchronous callback. Consumers copy a bounded
/// preview; neither these slices nor provider response storage may escape it.
pub const FetchRow = struct {
    kind: enum { page, view, body },
    index: usize = 0,
    total: usize = 0,
    message: Message,
    failed: bool = false,
};
/// Called synchronously by the worker. A sink must not allocate, perform
/// network/storage work or wait deliberately. A short existing queue wake
/// notification is allowed; the TUI stores atomics and coalesces that wake.
pub const ProgressSink = struct {
    ctx: *anyopaque,
    reportFn: *const fn (*anyopaque, FetchProgress) void,
    rowFn: ?*const fn (*anyopaque, FetchRow) void = null,
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
};
pub const Address = struct { address: []const u8, name: []const u8 = "" };
pub const Attachment = struct { id: []const u8, filename: []const u8, mimeType: []const u8 = "application/octet-stream", size: usize = 0, data: []const u8 = "" };
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
    bodySource: BodySource = .unknown,
    messageId: []const u8 = "",
    references: []const u8 = "",
    inReplyTo: []const u8 = "",
    labels: []const []const u8 = &.{},
    receivedAt: i64 = 0,
    unread: bool = false,
    bodyCached: bool = false,
    bodyCacheError: []const u8 = "",
    attachments: []const Attachment = &.{},
    invitation: ?[]const u8 = null,
};
pub const Draft = struct {
    id: []const u8 = "",
    from: ?Address = null,
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
};
pub const Contact = struct { resourceName: []const u8 = "", etag: []const u8 = "", name: []const u8 = "", emails: []const Address = &.{} };
