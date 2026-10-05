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
    editor_mode: []const u8 = "auto",
    no_mouse: bool = false,
};
/// The caller owns returned JSON bytes. Requests share the agent CLI contract.
pub const Client = struct {
    ctx: *anyopaque,
    callFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,
    cachedFn: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8 = null,
    pub fn callCached(self: Client, allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
        return (self.cachedFn orelse return error.CacheUnsupported)(self.ctx, allocator, request);
    }
    pub fn call(self: Client, allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
        return self.callFn(self.ctx, allocator, request);
    }
};
pub const Address = struct { address: []const u8, name: []const u8 = "" };
pub const Attachment = struct { id: []const u8, filename: []const u8, mimeType: []const u8 = "application/octet-stream", size: usize = 0, data: []const u8 = "" };
pub const BodySource = enum { unknown, plain, html };
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
    to: []const Address = &.{},
    cc: []const Address = &.{},
    bcc: []const Address = &.{},
    subject: []const u8 = "",
    bodyText: []const u8 = "",
    threadId: []const u8 = "",
    inReplyTo: []const u8 = "",
    references: []const u8 = "",
    attachments: []const Attachment = &.{},
};
pub const Contact = struct { resourceName: []const u8 = "", etag: []const u8 = "", name: []const u8 = "", emails: []const Address = &.{} };
