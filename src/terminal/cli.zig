const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const core = @import("core.zig");
const files = @import("files.zig");
const CappedAllocator = @import("capped_allocator.zig").CappedAllocator;
const HtmlMetrics = struct {
    htmlDocumentBuilds: u64,
    htmlLayoutBuilds: u64,
    htmlFallbacks: u64,
};

pub fn run(init: std.process.Init, io: std.Io, mode: []const u8, args: *std.process.Args.Iterator) !void {
    var cap: CappedAllocator = .{ .backing = init.gpa, .limit = t.Limits.runtime_bytes };
    const a = cap.allocator();
    var setup = std.heap.ArenaAllocator.init(a);
    defer setup.deinit();
    const sa = setup.allocator();
    var options: t.Options = .{};
    var metrics_file: ?[]const u8 = null;
    var req = j.object(sa);
    var draft = j.object(sa);
    var has_draft = false;
    const interactive = std.mem.eql(u8, mode, "tui");
    const jsonl = std.mem.eql(u8, mode, "cli") or std.mem.eql(u8, mode, "agent");
    if (!interactive and !jsonl) {
        const verb = args.next() orelse return error.CommandRequired;
        if (eq(verb, "--help") or eq(verb, "-h")) {
            try help(io);
            return;
        }
        const family = if (std.mem.eql(u8, mode, "invitations")) "invitation" else if (std.mem.eql(u8, mode, "terminal-auth")) "auth" else mode;
        const command = if (std.mem.eql(u8, family, "mail") and std.mem.eql(u8, verb, "drafts")) "draft.list" else if (std.mem.eql(u8, family, "mail") and std.mem.eql(u8, verb, "compose")) "draft.create" else try std.fmt.allocPrint(sa, "{s}.{s}", .{ family, verb });
        try req.object.put(sa, "cmd", .{ .string = command });
    }
    while (args.next()) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) {
            try help(io);
            return;
        }
        if (eq(arg, "--fixtures")) {
            options.fixtures = true;
            continue;
        }
        if (eq(arg, "--no-mouse")) {
            options.no_mouse = true;
            continue;
        }
        if (eq(arg, "--cached")) {
            if (interactive or jsonl) return error.CachedFlagRequiresOneShotCommand;
            if (j.get(req, "cacheOnly")) |prior| if (prior == .bool and !prior.bool) return error.ConflictingSearchMode;
            try req.object.put(sa, "cacheOnly", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--server")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "mail.search")) return error.ServerFlagRequiresSearch;
            if (j.get(req, "cacheOnly")) |prior| if (prior == .bool and prior.bool) return error.ConflictingSearchMode;
            try req.object.put(sa, "cacheOnly", .{ .bool = false });
            continue;
        }
        if (eq(arg, "--json")) continue;
        if (eq(arg, "--all") or eq(arg, "--reply-all")) {
            try req.object.put(sa, "all", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--unread") or eq(arg, "--read")) {
            try req.object.put(sa, "unread", .{ .bool = eq(arg, "--unread") });
            continue;
        }
        if (eq(arg, "--starred") or eq(arg, "--unstarred")) {
            try req.object.put(sa, "starred", .{ .bool = eq(arg, "--starred") });
            continue;
        }
        if (eq(arg, "--body-stdin")) {
            const bytes = try readStdin(io, sa, t.Limits.body_bytes);
            try draft.object.put(sa, "bodyText", .{ .string = bytes });
            has_draft = true;
            continue;
        }
        const v = args.next() orelse return error.ValueRequired;
        if (eq(arg, "--config")) options.config_file = v else if (eq(arg, "--metrics-file")) metrics_file = v else if (eq(arg, "--grant-file")) options.grant_file = v else if (eq(arg, "--client-file")) try req.object.put(sa, "clientFile", .{ .string = v }) else if (eq(arg, "--capabilities")) {
            var values: j.Value = .{ .array = .init(sa) };
            var split = std.mem.splitScalar(u8, v, ',');
            while (split.next()) |part| try values.array.append(.{ .string = part });
            try req.object.put(sa, "capabilities", values);
        } else if (eq(arg, "--fixture-root")) options.fixture_root = v else if (eq(arg, "--fixture-scenario")) options.fixture_scenario = v else if (eq(arg, "--cache-dir")) options.cache_dir = v else if (eq(arg, "--ui-file")) options.ui_file = v else if (eq(arg, "--editor-mode")) options.editor_mode = v else if ((eq(arg, "--metadata-limit") or eq(arg, "--cache-messages"))) {
            options.metadata_limit = try std.fmt.parseInt(usize, v, 10);
            options.metadata_limit_set = true;
        } else if ((eq(arg, "--disk-limit-bytes") or eq(arg, "--cache-bytes"))) {
            options.disk_limit = try std.fmt.parseInt(usize, v, 10);
            options.disk_limit_set = true;
        } else if (eq(arg, "--account")) {
            options.account = v;
            try req.object.put(sa, "account", .{ .string = v });
        } else if (eq(arg, "--limit")) try req.object.put(sa, "limit", .{ .integer = try std.fmt.parseInt(i64, v, 10) }) else if (eq(arg, "--cursor")) try req.object.put(sa, "cursor", .{ .string = v }) else if (eq(arg, "--query")) try req.object.put(sa, "query", .{ .string = v }) else if (eq(arg, "--label")) try req.object.put(sa, "label", .{ .string = v }) else if (eq(arg, "--message-id") or eq(arg, "--id")) try req.object.put(sa, "messageId", .{ .string = v }) else if (eq(arg, "--thread-id")) try req.object.put(sa, "threadId", .{ .string = v }) else if (eq(arg, "--draft-id")) try req.object.put(sa, "draftId", .{ .string = v }) else if (eq(arg, "--attachment-id")) try req.object.put(sa, "attachmentId", .{ .string = v }) else if (eq(arg, "--operation-id")) try req.object.put(sa, "operationId", .{ .string = v }) else if (eq(arg, "--status")) try req.object.put(sa, "status", .{ .string = v }) else if (eq(arg, "--to") or eq(arg, "--cc") or eq(arg, "--bcc")) {
            try draft.object.put(sa, arg[2..], .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--subject")) {
            try draft.object.put(sa, "subject", .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--body")) {
            try draft.object.put(sa, "bodyText", .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--attach-file")) {
            var attachments = draft.object.get("attachments") orelse j.Value{ .array = .init(sa) };
            if (attachments.array.items.len == 16) return error.TooManyAttachments;
            var used: usize = 0;
            for (attachments.array.items) |attachment| used += @intCast(try j.integer(attachment, "size", 0));
            const raw = try files.readBounded(io, sa, std.Io.Dir.cwd(), v, t.Limits.body_bytes - used);
            const data = try sa.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(data, raw);
            try attachments.array.append(try j.value(sa, t.Attachment{ .id = "", .filename = std.fs.path.basename(v), .size = raw.len, .data = data }));
            try draft.object.put(sa, "attachments", attachments);
            has_draft = true;
        } else if (eq(arg, "--body-file")) {
            const body = try files.readBounded(io, sa, std.Io.Dir.cwd(), v, t.Limits.body_bytes);
            try draft.object.put(sa, "bodyText", .{ .string = body });
            has_draft = true;
        } else if (eq(arg, "--draft-file") or eq(arg, "--contact-file")) {
            const raw = try files.readBounded(io, sa, std.Io.Dir.cwd(), v, t.Limits.request_bytes);
            if (!core.boundedJson(raw)) return error.InvalidRequest;
            const value = try std.json.parseFromSliceLeaky(j.Value, sa, raw, .{});
            try req.object.put(sa, if (eq(arg, "--draft-file")) "draft" else "contact", value);
        } else if (eq(arg, "--expected-etag")) try req.object.put(sa, "expectedEtag", .{ .string = v }) else if (eq(arg, "--add-label") or eq(arg, "--remove-label")) {
            const key = if (eq(arg, "--add-label")) "addLabels" else "removeLabels";
            var values = if (req.object.get(key)) |x| x else j.Value{ .array = .init(sa) };
            try values.array.append(.{ .string = v });
            try req.object.put(sa, key, values);
        } else return error.UnknownOption;
    }
    if (has_draft) {
        if (req.object.get("draft") != null) return error.ConflictingDraftOptions;
        try req.object.put(sa, "draft", draft);
    }
    var session = try core.Session.init(io, a, init.environ_map, options);
    defer session.deinit();
    session.meter = &cap;
    var html_metrics: ?HtmlMetrics = null;
    defer if (metrics_file) |path| writeMetrics(io, path, &cap, html_metrics) catch {};
    if (interactive) {
        if (@import("build_options").tui) {
            const stats = try @import("tui.zig").run(io, a, session.client(), options, init.environ_map);
            html_metrics = .{
                .htmlDocumentBuilds = stats.htmlDocumentBuilds,
                .htmlLayoutBuilds = stats.htmlLayoutBuilds,
                .htmlFallbacks = stats.htmlFallbacks,
            };
        } else return error.TuiNotBuilt;
        return;
    }
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    if (!jsonl) {
        const raw = try std.json.Stringify.valueAlloc(sa, req, .{});
        const reply = try session.execute(sa, raw);
        try output.interface.writeAll(reply);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        const parsed = try std.json.parseFromSliceLeaky(j.Value, sa, reply, .{});
        if (!try j.boolean(parsed, "ok", false)) return error.CommandFailed;
        return;
    }
    var input_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &input_buffer);
    while (true) {
        var frame = std.heap.ArenaAllocator.init(a);
        defer frame.deinit();
        const fa = frame.allocator();
        var bytes: std.ArrayList(u8) = .empty;
        var oversized = false;
        var eof = false;
        while (true) {
            const byte = input.interface.takeByte() catch |err| if (err == error.EndOfStream) {
                eof = true;
                break;
            } else return err;
            if (byte == '\n') break;
            if (bytes.items.len < t.Limits.request_bytes) try bytes.append(fa, byte) else oversized = true;
        }
        if (eof and bytes.items.len == 0 and !oversized) break;
        const response = try session.execute(fa, if (oversized) "" else bytes.items);
        try output.interface.writeAll(response);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        if (eof) break;
    }
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn writeMetrics(io: std.Io, path: []const u8, cap: *CappedAllocator, html_metrics: ?HtmlMetrics) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const snapshot = cap.snapshot();
    try std.json.Stringify.value(.{
        .allocatorUsedBytes = snapshot.allocatorUsedBytes,
        .allocatorPeakBytes = snapshot.allocatorPeakBytes,
        .rejectedAllocations = snapshot.rejectedAllocations,
        .allocatorLimitBytes = snapshot.allocatorLimitBytes,
        .html = html_metrics,
    }, .{ .emit_null_optional_fields = false }, &writer);
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = .fromMode(0o600), .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, writer.buffered());
    try af.replace(io);
}
fn readStdin(io: std.Io, a: std.mem.Allocator, limit: usize) ![]const u8 {
    var buf: [8192]u8 = undefined;
    var r = std.Io.File.stdin().reader(io, &buf);
    return r.interface.allocRemaining(a, .limited(limit));
}
pub fn help(io: std.Io) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("Experimental terminal mail (account-scoped)\n  omagma tui [--fixtures] [--account ADDRESS] [--cache-dir DIR] [--ui-file FILE]\n  omagma cli|agent [--fixtures] [--fixture-root DIR] [--cache-dir DIR]\n  omagma mail list|search|read|thread|attachment|open|sync|refresh|compose|reply|send|archive|trash|restore|mark --account ADDRESS ...\n  omagma draft list|read|create|update|send|discard --account ADDRESS ...\n  omagma contacts list|search|upsert --account ADDRESS ...\n  omagma invitations inspect|reply --account ADDRESS --message-id ID --status accepted|tentative|declined --operation-id ID\n  omagma operation list|read --account ADDRESS [--operation-id ID]\n  omagma terminal-auth status|authorize|revoke --account ADDRESS ...\nJSONL requests require cmd and account; accounts.list discovers accounts.\nSearch: --cached searches local mail; --server searches Gmail. JSONL uses cacheOnly:true/false.\nUse --cached for local list/read/thread/contacts/cache-stats.\nSend requires an operation ID. Unknown outcomes are never retried automatically.\nUse --body-file FILE or --body-stdin; --to/--cc/--bcc accept address lists.\nRepeat --attach-file FILE to attach files (up to16, 2MiB combined, 3MiB request limit).\nLocal cache and drafts are private. No permanent-delete command exists.\n");
    try w.interface.flush();
}
