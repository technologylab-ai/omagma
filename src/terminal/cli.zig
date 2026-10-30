const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const core = @import("core.zig");
const help_info = @import("cli_help.zig");
const files = @import("files.zig");
const cli_files = @import("cli_files.zig");
const CappedAllocator = @import("capped_allocator.zig").CappedAllocator;
const HtmlMetrics = struct {
    htmlDocumentBuilds: u64,
    htmlLayoutBuilds: u64,
    htmlFallbacks: u64,
};

/// Discovery must precede account/vault routing in main. Keep the same
/// value-aware scan as run(), so a literal "--help" field is never an option.
pub fn discovery(io: std.Io, a: std.mem.Allocator, mode: []const u8, args: *std.process.Args.Iterator) !bool {
    var scan = args.*;
    var operation: ?[]const u8 = null;
    if (!eq(mode, "tui") and !eq(mode, "cli") and !eq(mode, "agent")) {
        const verb = scan.next() orelse return error.CommandRequired;
        if (eq(verb, "--help") or eq(verb, "-h") or eq(verb, "--help-all")) {
            try help_info.family(io, mode);
            if (eq(verb, "--help-all")) try help_info.options(io);
            return true;
        }
        if (eq(verb, "--help-options")) {
            try help_info.options(io);
            return true;
        }
        if (!knownVerb(mode, verb)) return error.UnknownCommand;
        operation = verb;
    }
    if (try helpBeforeInput(io, a, mode, operation, &scan)) return true;
    const command = if (operation) |verb|
        help_info.jsonAlias(mode, verb) orelse try std.fmt.allocPrint(a, "{s}.{s}", .{ help_info.jsonFamily(mode), verb })
    else
        "";
    try attachmentScopeBeforeRouting(command, &scan);
    return false;
}

/// Wrong-command file flags must win over an invalid vault activation too.
/// This scan borrows argv only; value strings are never interpreted as flags.
fn attachmentScopeBeforeRouting(command: []const u8, args: *std.process.Args.Iterator) !void {
    var scan = args.*;
    while (scan.next()) |arg| {
        if (valueOption(arg)) {
            if (!scan.skip()) return error.ValueRequired;
            if ((eq(arg, "--attach-file") or eq(arg, "--upload-file") or eq(arg, "--file") or eq(arg, "--attachment-mode")) and !draftSourceCommand(command)) return error.AttachmentsRequireDraftSource;
        } else if (eq(arg, "--dry-run")) {
            if (!draftSourceCommand(command)) return error.DryRunRequiresDraftSource;
        } else if (!booleanOption(arg)) return;
    }
}

pub fn run(init: @import("../fixed_runtime.zig").Context, io: std.Io, mode: []const u8, args: *std.process.Args.Iterator) !void {
    const cap = init.meter;
    const a = cap.allocator();
    var setup = std.heap.ArenaAllocator.init(commandBacking(a, mode, args));
    defer setup.deinit();
    const sa = setup.allocator();
    // Release status and upgrade guidance never initialize the mail session or
    // require account configuration, OAuth grants or keyring access.
    if (eq(mode, "updates")) return runUpdates(io, sa, init.environ_map, args);
    var options: t.Options = .{};
    var metrics_file: ?[]const u8 = null;
    var backend_path: ?[]const u8 = null;
    var req = j.object(sa);
    var draft = j.object(sa);
    var has_draft = false;
    var source_format: ?[]const u8 = null;
    var attachment_paths: std.ArrayList([]const u8) = .empty;
    var attachment_sources: std.ArrayList(cli_files.Source) = .empty;
    var attachment_mode: ?t.AttachmentDelivery = null;
    var dry_run = false;
    var send_delay: ?i64 = null;
    var browser_preview = false;
    const interactive = std.mem.eql(u8, mode, "tui");
    const jsonl = std.mem.eql(u8, mode, "cli") or std.mem.eql(u8, mode, "agent");
    var operation: ?[]const u8 = null;
    if (!interactive and !jsonl) {
        const verb = args.next() orelse return error.CommandRequired;
        if (eq(verb, "--help") or eq(verb, "-h")) {
            return help_info.family(io, mode);
        }
        if (eq(verb, "--help-all")) {
            try help_info.family(io, mode);
            return help_info.options(io);
        }
        if (eq(verb, "--help-options")) return help_info.options(io);
        if (!knownVerb(mode, verb)) return error.UnknownCommand;
        operation = verb;
        const command = help_info.jsonAlias(mode, verb) orelse try std.fmt.allocPrint(sa, "{s}.{s}", .{ help_info.jsonFamily(mode), verb });
        try req.object.put(sa, "cmd", .{ .string = command });
    }
    if (try helpBeforeInput(io, sa, mode, operation, args)) return;
    while (args.next()) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) {
            if (jsonl) {
                const target = args.next();
                return help_info.protocol(io, sa, if (target != null and !std.mem.startsWith(u8, target.?, "-")) target else null);
            }
            return if (operation) |verb| help_info.command(io, mode, verb) else help_info.family(io, mode);
        }
        if (eq(arg, "--help-all")) return if (jsonl) @import("cli_api.zig").full(io, sa) else help(io);
        if (eq(arg, "--schema")) {
            if (!jsonl) return error.UnknownOption;
            const target = args.next();
            if (args.next() != null) return error.UnknownOption;
            return @import("cli_api.zig").schemas(io, sa, target);
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
        if (eq(arg, "--reconcile")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "invitation.inspect")) return error.InvalidRequest;
            try req.object.put(sa, "reconcile", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--rsvp-only")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "invitation.reply")) return error.InvalidRequest;
            try req.object.put(sa, "rsvpOnly", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--server")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "mail.search")) return error.ServerFlagRequiresSearch;
            if (j.get(req, "cacheOnly")) |prior| if (prior == .bool and prior.bool) return error.ConflictingSearchMode;
            try req.object.put(sa, "cacheOnly", .{ .bool = false });
            continue;
        }
        if (eq(arg, "--json")) continue;
        if (eq(arg, "--dry-run")) {
            if (!draftSourceCommand(j.text(req, "cmd"))) return error.DryRunRequiresDraftSource;
            dry_run = true;
            continue;
        }
        if (eq(arg, "--browser")) {
            if (interactive or jsonl) return error.BrowserRequiresPreview;
            browser_preview = true;
            continue;
        }
        if (eq(arg, "--wait")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "queue.process")) return error.WaitRequiresQueueProcess;
            try req.object.put(sa, "wait", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--accept-floating-time") or eq(arg, "--reinterpret-embedded-timezones")) {
            if (interactive or jsonl or !eq(mode, "calendar")) return error.InvalidCalendarRequest;
            try req.object.put(sa, if (eq(arg, "--accept-floating-time")) "acceptFloatingTime" else "reinterpretEmbeddedTimezones", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--original")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "mail.forward")) return error.OriginalRequiresForward;
            try req.object.put(sa, "original", .{ .bool = true });
            continue;
        }
        if (eq(arg, "--preserve-formatting")) {
            const command = j.text(req, "cmd");
            if (interactive or jsonl or (!eq(command, "mail.reply") and !eq(command, "mail.forward"))) return error.PreserveFormattingRequiresReplyOrForward;
            try req.object.put(sa, "preserveFormatting", .{ .bool = true });
            continue;
        }
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
            const bytes = try readStdin(io, sa, t.Limits.compose_body_bytes);
            try draft.object.put(sa, "bodyText", .{ .string = bytes });
            has_draft = true;
            continue;
        }
        if (!valueOption(arg)) return error.UnknownOption;
        const v = args.next() orelse return error.ValueRequired;
        if (eq(arg, "--backend")) backend_path = v else if (eq(arg, "--config")) options.config_file = v else if (eq(arg, "--metrics-file")) metrics_file = v else if (eq(arg, "--grant-file")) options.grant_file = v else if (eq(arg, "--client-file")) try req.object.put(sa, "clientFile", .{ .string = v }) else if (eq(arg, "--capabilities")) {
            var values: j.Value = .{ .array = .init(sa) };
            var split = std.mem.splitScalar(u8, v, ',');
            while (split.next()) |part| try values.array.append(.{ .string = part });
            try req.object.put(sa, "capabilities", values);
        } else if (eq(arg, "--fixture-root")) options.fixture_root = v else if (eq(arg, "--fixture-scenario")) options.fixture_scenario = v else if (eq(arg, "--cache-dir")) options.cache_dir = v else if (eq(arg, "--ui-file")) options.ui_file = v else if (eq(arg, "--editor-mode")) options.editor_mode = v else if ((eq(arg, "--metadata-limit") or eq(arg, "--cache-messages"))) {
            options.metadata_limit = try std.fmt.parseInt(usize, v, 10);
            options.metadata_limit_set = true;
        } else if (eq(arg, "--prefetch-bodies")) {
            options.body_prefetch_limit = try std.fmt.parseInt(usize, v, 10);
            options.body_prefetch_limit_set = true;
            if (options.body_prefetch_limit > 64) return error.InvalidPrefetchLimit;
            if (!interactive and !jsonl) try req.object.put(sa, "prefetchLimit", .{ .integer = @intCast(options.body_prefetch_limit) });
        } else if ((eq(arg, "--disk-limit-bytes") or eq(arg, "--cache-bytes"))) {
            options.disk_limit = try std.fmt.parseInt(usize, v, 10);
            options.disk_limit_set = true;
        } else if (eq(arg, "--account")) {
            options.account = v;
            try req.object.put(sa, "account", .{ .string = v });
        } else if (eq(arg, "--next-attempt")) {
            if (interactive or jsonl or !eq(mode, "calendar")) return error.InvalidCalendarRequest;
            const attempt = std.fmt.parseInt(u32, v, 10) catch return error.InvalidCalendarRetry;
            if (attempt == 0 or attempt > 1_000_000) return error.InvalidCalendarRetry;
            try req.object.put(sa, "nextAttempt", .{ .integer = attempt });
        } else if (calendarField(arg)) |key| {
            if (interactive or jsonl or !eq(mode, "calendar")) return error.InvalidCalendarRequest;
            try req.object.put(sa, key, .{ .string = v });
        } else if (eq(arg, "--name") or eq(arg, "--label-id") or eq(arg, "--confirm-name")) {
            const key = if (eq(arg, "--label-id")) "labelId" else if (eq(arg, "--confirm-name")) "confirmName" else "name";
            try req.object.put(sa, key, .{ .string = v });
        } else if (eq(arg, "--background-color") or eq(arg, "--text-color")) {
            var color = j.get(req, "color") orelse j.object(sa);
            try color.object.put(sa, if (eq(arg, "--background-color")) "backgroundColor" else "textColor", .{ .string = v });
            try req.object.put(sa, "color", color);
        } else if (eq(arg, "--queue-id") or eq(arg, "--blob-id") or eq(arg, "--mime-type") or eq(arg, "--scope")) {
            const key = if (eq(arg, "--queue-id")) "queueId" else if (eq(arg, "--blob-id")) "blobId" else if (eq(arg, "--mime-type")) "mimeType" else "scope";
            if (eq(arg, "--scope") and !eq(v, "message") and !eq(v, "conversation")) return error.InvalidTriageScope;
            try req.object.put(sa, key, .{ .string = v });
        } else if (eq(arg, "--send-delay") or eq(arg, "--delay-seconds")) {
            if (interactive or jsonl) return error.SendDelayRequiresSend;
            const seconds = std.fmt.parseInt(i64, v, 10) catch return error.InvalidSendDelay;
            if (seconds < 0 or seconds > 30) return error.InvalidSendDelay;
            const command = j.text(req, "cmd");
            if (eq(command, "draft.queue") or eq(command, "queue.resume")) {
                try req.object.put(sa, "delaySeconds", .{ .integer = seconds });
            } else if (eq(arg, "--send-delay") and (eq(command, "mail.send") or eq(command, "draft.send"))) send_delay = seconds else return error.SendDelayRequiresSend;
        } else if (eq(arg, "--action") or eq(arg, "--undo-token") or eq(arg, "--url") or eq(arg, "--path")) {
            const key = if (eq(arg, "--action")) "action" else if (eq(arg, "--undo-token")) "undoToken" else arg[2..];
            try req.object.put(sa, key, .{ .string = v });
        } else if (eq(arg, "--message-ids")) {
            var values = req.object.get("messageIds") orelse j.Value{ .array = .init(sa) };
            var split = std.mem.splitScalar(u8, v, ',');
            while (split.next()) |id| try values.array.append(.{ .string = id });
            try req.object.put(sa, "messageIds", values);
        } else if ((eq(arg, "--message-id") or eq(arg, "--id")) and eq(j.text(req, "cmd"), "mail.batch")) {
            var values = req.object.get("messageIds") orelse j.Value{ .array = .init(sa) };
            try values.array.append(.{ .string = v });
            try req.object.put(sa, "messageIds", values);
        } else if (eq(arg, "--before-message-id") or eq(arg, "--after-message-id")) {
            try req.object.put(sa, if (eq(arg, "--before-message-id")) "beforeMessageId" else "afterMessageId", .{ .string = v });
        } else if (eq(arg, "--boundary-received-at")) {
            try req.object.put(sa, "boundaryReceivedAt", .{ .integer = try std.fmt.parseInt(i64, v, 10) });
        } else if (eq(arg, "--format")) {
            if (!eq(v, "markdown") and !eq(v, "plain")) return error.InvalidBodyFormat;
            if (interactive or jsonl) return error.FormatRequiresComposeCommand;
            source_format = v;
        } else if (eq(arg, "--from")) {
            try draft.object.put(sa, "from", .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--limit")) try req.object.put(sa, "limit", .{ .integer = try std.fmt.parseInt(i64, v, 10) }) else if (eq(arg, "--cursor")) try req.object.put(sa, "cursor", .{ .string = v }) else if (eq(arg, "--query")) try req.object.put(sa, "query", .{ .string = v }) else if (eq(arg, "--label")) try req.object.put(sa, "label", .{ .string = v }) else if (eq(arg, "--message-id") or eq(arg, "--id")) try req.object.put(sa, "messageId", .{ .string = v }) else if (eq(arg, "--thread-id")) try req.object.put(sa, "threadId", .{ .string = v }) else if (eq(arg, "--draft-id")) try req.object.put(sa, "draftId", .{ .string = v }) else if (eq(arg, "--attachment-id")) try req.object.put(sa, "attachmentId", .{ .string = v }) else if (eq(arg, "--operation-id")) try req.object.put(sa, "operationId", .{ .string = v }) else if (eq(arg, "--status")) try req.object.put(sa, "status", .{ .string = v }) else if (eq(arg, "--to") or eq(arg, "--cc") or eq(arg, "--bcc")) {
            try draft.object.put(sa, arg[2..], .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--subject")) {
            try draft.object.put(sa, "subject", .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--body")) {
            try draft.object.put(sa, "bodyText", .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--attach-file") or eq(arg, "--upload-file") or eq(arg, "--file")) {
            if (!draftSourceCommand(j.text(req, "cmd"))) return error.AttachmentsRequireDraftSource;
            if (attachment_paths.items.len == @import("types.zig").Limits.attachments) return error.TooManyAttachments;
            try attachment_paths.append(sa, v);
            try attachment_sources.append(sa, if (eq(arg, "--attach-file")) .attach_file else if (eq(arg, "--upload-file")) .upload_file else .file);
            has_draft = true;
        } else if (eq(arg, "--attachment-mode")) {
            if (!draftSourceCommand(j.text(req, "cmd"))) return error.AttachmentsRequireDraftSource;
            const chosen = try cli_files.parseMode(v);
            if (attachment_mode) |prior| if (prior != chosen) return error.ConflictingAttachmentMode;
            attachment_mode = chosen;
        } else if (eq(arg, "--body-file")) {
            const body = try files.readBounded(io, sa, std.Io.Dir.cwd(), v, t.Limits.compose_body_bytes);
            try draft.object.put(sa, "bodyText", .{ .string = body });
            has_draft = true;
        } else if (eq(arg, "--draft-file") or eq(arg, "--contact-file") or eq(arg, "--event-file")) {
            const raw = try files.readBounded(io, sa, std.Io.Dir.cwd(), v, if (eq(arg, "--draft-file")) @import("send_memory.zig").record_bytes else t.Limits.request_bytes);
            if (!core.boundedJson(raw)) return error.InvalidRequest;
            const value = try std.json.parseFromSliceLeaky(j.Value, sa, raw, .{});
            try req.object.put(sa, if (eq(arg, "--draft-file")) "draft" else if (eq(arg, "--event-file")) "event" else "contact", value);
        } else if (eq(arg, "--expected-etag")) try req.object.put(sa, "expectedEtag", .{ .string = v }) else if (eq(arg, "--add-label") or eq(arg, "--remove-label")) {
            const key = if (eq(arg, "--add-label")) "addLabels" else "removeLabels";
            var values = if (req.object.get(key)) |x| x else j.Value{ .array = .init(sa) };
            try values.array.append(.{ .string = v });
            try req.object.put(sa, key, values);
        } else return error.UnknownOption;
    }
    if (try j.boolean(req, "original", false) and try j.boolean(req, "preserveFormatting", false)) return error.ConflictingForwardModes;
    if (has_draft) {
        if (req.object.get("draft") != null) return error.ConflictingDraftOptions;
        try req.object.put(sa, "draft", draft);
    }
    if (source_format) |format| {
        const command = j.text(req, "cmd");
        if (eq(command, "mail.reply") or eq(command, "mail.forward")) {
            try req.object.put(sa, "bodyFormat", .{ .string = format });
        } else if (eq(command, "draft.create") or eq(command, "draft.update") or eq(command, "draft.preview") or eq(command, "mail.send")) {
            if (eq(command, "draft.preview") and j.text(req, "draftId").len != 0 and req.object.get("draft") == null) return error.FormatRequiresDraftSource;
            var formatted = try j.copyObject(sa, req.object.get("draft") orelse draft);
            try formatted.object.put(sa, "bodyFormat", .{ .string = format });
            try req.object.put(sa, "draft", formatted);
        } else return error.FormatRequiresComposeCommand;
    }
    const resolved_files = try cli_files.resolve(io, sa, attachment_paths.items, attachment_sources.items, attachment_mode);
    if (dry_run) {
        if (!draftSourceCommand(j.text(req, "cmd"))) return error.DryRunRequiresDraftSource;
        if (browser_preview or req.object.get("draft") == null) return error.DryRunRequiresDraftSource;
        // Local file metadata only: no session, vault, credentials, blob
        // import or provider request. The reply is the same JSON plan shape.
        const planned = try @import("attachment_dry_run.zig").run(io, sa, req, resolved_files.paths, resolved_files.deliveries);
        var dry_buffer: [4096]u8 = undefined;
        var dry_output = std.Io.File.stdout().writer(io, &dry_buffer);
        try dry_output.interface.writeAll(planned);
        try dry_output.interface.writeByte('\n');
        try dry_output.interface.flush();
        const parsed = try std.json.parseFromSliceLeaky(j.Value, sa, planned, .{});
        if (!try j.boolean(parsed, "ok", false)) return error.CommandFailed;
        return;
    }
    // Printed authorization hints repeat an explicit --backend; an
    // auto-activated vault is found again without one.
    options.backend_socket = backend_path;
    const activation = if (!options.fixtures and backend_path == null) try @import("vault_activation.zig").load(io, sa, init.environ_map) else null;
    if (activation) |selected| {
        // An active encrypted store is an explicit persistent choice. Never
        // silently switch to a plaintext folder because a stale command line
        // still contains paths from the previous setup.
        if (options.config_file != null or options.grant_file != null or options.cache_dir != null or options.ui_file != null or options.metadata_limit_set or options.disk_limit_set) return error.VaultOptionConflict;
        backend_path = selected.socketPath;
    }
    var session: ?core.Session = null;
    defer if (session) |*local| local.deinit();
    var backend: @import("vault_transport.zig").Client = .{ .io = io, .socket_path = backend_path orelse "", .expected_vault_id = if (activation) |selected| try selected.id() else null };
    options.remote_preferences = backend_path != null;
    const client = if (backend_path != null) backend.client() else local: {
        session = try core.Session.init(io, a, init.environ_map, options);
        session.?.meter = cap;
        break :local session.?.client();
    };
    var html_metrics: ?HtmlMetrics = null;
    defer if (metrics_file) |path| writeMetrics(io, path, cap, init.memory, html_metrics) catch {};
    if (interactive) {
        if (@import("build_options").tui) {
            const stats = try @import("tui.zig").run(io, a, client, options, init.environ_map);
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
        const reply = try @import("cli_plan.zig").execute(io, sa, client, req, .{ .attachments = resolved_files.paths, .deliveries = resolved_files.deliveries, .forced = resolved_files.forced, .backend_socket = options.backend_socket, .config_file = options.config_file, .grant_file = options.grant_file, .send_delay = send_delay, .browser = browser_preview });
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
        var frame_backing = a;
        var bytes: std.ArrayList(u8) = .empty;
        // Grow on the reclaiming allocator, not the reply arena: otherwise
        // older capacities can remain resident beside a large draft request.
        defer bytes.deinit(frame_backing);
        var oversized = false;
        var eof = false;
        while (true) {
            const byte = input.interface.takeByte() catch |err| if (err == error.EndOfStream) {
                eof = true;
                break;
            } else return err;
            if (byte == '\n') break;
            if (bytes.items.len == t.Limits.request_bytes) {
                // A large JSONL frame is staged outside the fixed pool before
                // its command can be inspected; execute then enforces the
                // command-specific allowance. Only actual bytes are retained.
                var expanded: std.ArrayList(u8) = .empty;
                const growing = @import("send_memory.zig").allocator();
                try expanded.appendSlice(growing, bytes.items);
                bytes.deinit(frame_backing);
                bytes = expanded;
                frame_backing = growing;
            }
            if (bytes.items.len < @import("send_memory.zig").record_bytes) try bytes.append(frame_backing, byte) else oversized = true;
        }
        if (eof and bytes.items.len == 0 and !oversized) break;
        var frame = std.heap.ArenaAllocator.init(@import("send_memory.zig").operationBacking(a, bytes.items, false));
        defer frame.deinit();
        const response = try client.call(frame.allocator(), if (oversized) "" else bytes.items);
        try output.interface.writeAll(response);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        if (eof) break;
    }
}
fn commandBacking(normal: std.mem.Allocator, mode: []const u8, args: *std.process.Args.Iterator) std.mem.Allocator {
    var scan = args.*;
    const verb = scan.next() orelse return normal;
    if (help_info.jsonAlias(mode, verb)) |alias| return @import("send_memory.zig").commandBacking(normal, alias);
    var bytes: [128]u8 = undefined;
    const command = std.fmt.bufPrint(&bytes, "{s}.{s}", .{ help_info.jsonFamily(mode), verb }) catch return normal;
    return @import("send_memory.zig").commandBacking(normal, command);
}
// Help is handled before reading a body file or waiting for stdin. Iterator
// copies borrow the same immutable argv, but retain their own position on POSIX.
fn helpBeforeInput(io: std.Io, a: std.mem.Allocator, mode: []const u8, operation: ?[]const u8, args: *std.process.Args.Iterator) !bool {
    var scan = args.*;
    const jsonl = eq(mode, "cli") or eq(mode, "agent");
    while (scan.next()) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) {
            if (jsonl) {
                const target = scan.next();
                try help_info.protocol(io, a, if (target != null and !std.mem.startsWith(u8, target.?, "-")) target else null);
            } else if (operation) |verb| try help_info.command(io, mode, verb) else try help_info.family(io, mode);
            return true;
        }
        if (eq(arg, "--help-all")) {
            if (jsonl) try @import("cli_api.zig").full(io, a) else if (operation) |verb| try help_info.expanded(io, a, mode, verb) else {
                try help_info.family(io, mode);
                try help_info.options(io);
            }
            return true;
        }
        if (eq(arg, "--help-options")) {
            try help_info.options(io);
            return true;
        }
        if (jsonl and eq(arg, "--schema")) {
            const target = scan.next();
            if (scan.next() != null) return error.UnknownOption;
            try @import("cli_api.zig").schemas(io, a, target);
            return true;
        }
        if (valueOption(arg)) {
            if (!scan.skip()) return false;
        } else if (!booleanOption(arg)) return false;
    }
    return false;
}
fn booleanOption(arg: []const u8) bool {
    for ([_][]const u8{ "--fixtures", "--no-mouse", "--cached", "--server", "--json", "--browser", "--wait", "--original", "--preserve-formatting", "--all", "--reply-all", "--unread", "--read", "--starred", "--unstarred", "--body-stdin", "--rsvp-only", "--dry-run" }) |flag| if (eq(arg, flag)) return true;
    return false;
}
fn draftSourceCommand(command: []const u8) bool {
    return eq(command, "mail.send") or eq(command, "draft.create") or eq(command, "draft.update") or eq(command, "draft.preview");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
// Reject misspelled one-shot verbs before loading configuration, accounts or
// credentials. JSONL command frames retain the shared executor's error contract.
fn knownVerb(mode: []const u8, verb: []const u8) bool {
    return help_info.knownVerb(mode, verb);
}
// Boolean flags have already been handled above. Check the name before taking
// a value so an unknown final flag stays UnknownOption rather than ValueRequired.
fn valueOption(arg: []const u8) bool {
    if (calendarField(arg) != null) return true;
    for ([_][]const u8{
        "--backend",           "--config",           "--metrics-file",         "--grant-file",    "--client-file",  "--capabilities",
        "--fixture-root",      "--fixture-scenario", "--cache-dir",            "--ui-file",       "--editor-mode",  "--metadata-limit",
        "--cache-messages",    "--prefetch-bodies",  "--disk-limit-bytes",     "--cache-bytes",   "--account",      "--action",
        "--undo-token",        "--url",              "--path",                 "--message-ids",   "--message-id",   "--id",
        "--before-message-id", "--after-message-id", "--boundary-received-at", "--format",        "--from",         "--limit",
        "--cursor",            "--query",            "--label",                "--thread-id",     "--draft-id",     "--attachment-id",
        "--operation-id",      "--status",           "--to",                   "--cc",            "--bcc",          "--subject",
        "--body",              "--attach-file",      "--name",                 "--label-id",      "--confirm-name", "--body-file",
        "--draft-file",        "--event-file",       "--contact-file",         "--expected-etag", "--add-label",    "--remove-label",
        "--background-color",  "--text-color",       "--queue-id",             "--blob-id",       "--mime-type",    "--scope",
        "--send-delay",        "--delay-seconds",    "--next-attempt",         "--upload-file",   "--file",         "--attachment-mode",
    }) |candidate| if (eq(arg, candidate)) return true;
    return false;
}
fn calendarField(arg: []const u8) ?[]const u8 {
    const fields = [_]struct { flag: []const u8, key: []const u8 }{
        .{ .flag = "--calendar-id", .key = "calendarId" },
        .{ .flag = "--event-id", .key = "eventId" },
        .{ .flag = "--date", .key = "date" },
        .{ .flag = "--view", .key = "view" },
        .{ .flag = "--time-zone", .key = "timeZone" },
        .{ .flag = "--start-time-zone", .key = "startTimeZone" },
        .{ .flag = "--end-time-zone", .key = "endTimeZone" },
        .{ .flag = "--review-hash", .key = "reviewHash" },
        .{ .flag = "--send-updates", .key = "sendUpdates" },
    };
    for (fields) |field| if (eq(arg, field.flag)) return field.key;
    return null;
}
fn writeMetrics(io: std.Io, path: []const u8, cap: *CappedAllocator, memory: *@import("../fixed_runtime.zig").Runtime, html_metrics: ?HtmlMetrics) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const snapshot = cap.snapshot();
    try std.json.Stringify.value(.{
        .allocatorUsedBytes = snapshot.allocatorUsedBytes,
        .allocatorPeakBytes = snapshot.allocatorPeakBytes,
        .rejectedAllocations = snapshot.rejectedAllocations,
        .allocatorLimitBytes = snapshot.allocatorLimitBytes,
        .html = html_metrics,
        .fixedMemory = memory.snapshot(),
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
    return help_info.overviewFull(io);
}

fn runUpdates(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, args: *std.process.Args.Iterator) !void {
    const updates = @import("updates.zig");
    const verb = args.next() orelse "status";
    if (eq(verb, "--help") or eq(verb, "-h")) return help_info.family(io, "updates");
    if (eq(verb, "--help-all")) return help_info.family(io, "updates");
    if (!eq(verb, "status") and !eq(verb, "check") and !eq(verb, "guide") and !eq(verb, "dismiss") and !eq(verb, "automatic")) return error.UnknownCommand;
    var automatic: ?bool = null;
    if (eq(verb, "automatic")) {
        const choice = args.next() orelse return error.ValueRequired;
        if (eq(choice, "--help") or eq(choice, "-h") or eq(choice, "--help-all")) return help_info.command(io, "updates", verb);
        automatic = if (eq(choice, "on")) true else if (eq(choice, "off")) false else return error.InvalidUpdatePreference;
    }
    var fixtures = false;
    var json = false;
    while (args.next()) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h") or eq(arg, "--help-all")) return help_info.command(io, "updates", verb);
        if (eq(arg, "--fixtures")) fixtures = true else if (eq(arg, "--json")) json = true else return error.UnknownOption;
    }
    var snapshot = try updates.init(io, a, environ, fixtures);
    if (eq(verb, "check")) try updates.check(io, a, environ, &snapshot);
    if (eq(verb, "dismiss")) try updates.dismiss(io, a, environ, &snapshot);
    if (automatic) |value| {
        snapshot.state.manualOnly = !value;
        try updates.save(io, a, environ, &snapshot);
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    if (json) {
        const encoded = try updates.encode(a, &snapshot);
        try output.interface.writeAll(encoded);
    } else if (eq(verb, "guide")) {
        try output.interface.writeAll(try updates.guide(a, &snapshot));
    } else {
        try output.interface.print("Omagma {s}\nInstallation: {s}\nLatest stable: {s}\n", .{ @import("build_options").version, updates.methodName(snapshot.install.method), if (snapshot.state.latest.len == 0) "Not checked yet" else snapshot.state.latest.slice() });
        if (snapshot.state.errorMessage.len != 0) try output.interface.print("Check: {s}\n", .{snapshot.state.errorMessage.slice()});
        if (updates.available(&snapshot, @import("build_options").version)) try output.interface.writeAll("Upgrade available. Run omagma updates guide for installation-specific instructions.\n") else if (snapshot.state.latest.len != 0) try output.interface.writeAll("No actionable upgrade for this installation.\n");
        try output.interface.print("Automatic checks: {s}\n", .{if (snapshot.state.manualOnly) "off" else "daily"});
    }
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
