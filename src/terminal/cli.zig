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
            if (!draftSourceCommand(command) and !plannedCommand(command)) return error.DryRunRequiresDraftSource;
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
    var strict = false;
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
            if (!jsonl) return unknownOption(arg);
            return schemaRequest(io, sa, args);
        }
        if (eq(arg, "--manifest")) {
            if (!jsonl) return unknownOption(arg);
            return @import("cli_api.zig").manifest(io, sa);
        }
        if (eq(arg, "--strict")) {
            if (!jsonl) return unknownOption(arg);
            strict = true;
            continue;
        }
        if (eq(arg, "--fixtures")) {
            options.fixtures = true;
            continue;
        }
        if (eq(arg, "--no-mouse")) {
            options.no_mouse = true;
            continue;
        }
        if (eq(arg, "--cached") or eq(arg, "--cache-only")) {
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
            const command = j.text(req, "cmd");
            // Saved-draft sends and label changes use the executor's own
            // dryRun plan; supplied sources keep the local file plan.
            if (plannedCommand(command)) {
                try req.object.put(sa, "dryRun", .{ .bool = true });
                continue;
            }
            if (!draftSourceCommand(command)) return error.DryRunRequiresDraftSource;
            dry_run = true;
            continue;
        }
        if (eq(arg, "--replace")) {
            if (interactive or jsonl or !eq(j.text(req, "cmd"), "draft.update")) return error.ReplaceRequiresDraftUpdate;
            try req.object.put(sa, "replace", .{ .bool = true });
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
            // Only a reply has recipients to widen; forwarding chooses none.
            if (!interactive and !jsonl and !eq(j.text(req, "cmd"), "mail.reply")) return error.ReplyAllRequiresReply;
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
        if (!valueOption(arg)) return unknownOption(arg);
        const v = args.next() orelse return error.ValueRequired;
        if (eq(arg, "--backend")) backend_path = v else if (eq(arg, "--config")) options.config_file = v else if (eq(arg, "--metrics-file")) metrics_file = v else if (eq(arg, "--grant-file")) options.grant_file = v else if (eq(arg, "--client-file")) try req.object.put(sa, "clientFile", .{ .string = v }) else if (eq(arg, "--capabilities")) {
            var values: j.Value = .{ .array = .init(sa) };
            var split = std.mem.splitScalar(u8, v, ',');
            while (split.next()) |part| try values.array.append(.{ .string = part });
            try req.object.put(sa, "capabilities", values);
        } else if (eq(arg, "--fixture-root")) options.fixture_root = v else if (eq(arg, "--fixture-scenario")) options.fixture_scenario = v else if (eq(arg, "--cache-dir")) options.cache_dir = v else if (eq(arg, "--ui-file")) options.ui_file = v else if (eq(arg, "--editor-mode")) options.editor_mode = v else if ((eq(arg, "--metadata-limit") or eq(arg, "--cache-messages"))) {
            options.metadata_limit = std.fmt.parseInt(usize, v, 10) catch return error.InvalidOptionValue;
            options.metadata_limit_set = true;
        } else if (eq(arg, "--prefetch-bodies")) {
            options.body_prefetch_limit = std.fmt.parseInt(usize, v, 10) catch return error.InvalidOptionValue;
            options.body_prefetch_limit_set = true;
            if (options.body_prefetch_limit > 64) return error.InvalidPrefetchLimit;
            // Only a refresh request carries the body head; other one-shot
            // commands use the same session option without an extra field.
            if (!interactive and !jsonl and eq(j.text(req, "cmd"), "mail.refresh")) try req.object.put(sa, "prefetchLimit", .{ .integer = @intCast(options.body_prefetch_limit) });
        } else if ((eq(arg, "--disk-limit-bytes") or eq(arg, "--cache-bytes"))) {
            options.disk_limit = std.fmt.parseInt(usize, v, 10) catch return error.InvalidOptionValue;
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
            // Calendar actions choose one event or its series; mail triage a
            // message or its conversation.
            if (eq(arg, "--scope") and eq(mode, "calendar")) {
                if (!eq(v, "event") and !eq(v, "series")) return error.InvalidCalendarScope;
            } else if (eq(arg, "--scope") and !eq(v, "message") and !eq(v, "conversation")) return error.InvalidTriageScope;
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
            try req.object.put(sa, "boundaryReceivedAt", .{ .integer = std.fmt.parseInt(i64, v, 10) catch return error.InvalidOptionValue });
        } else if (eq(arg, "--expected-content-digest")) {
            const command = j.text(req, "cmd");
            if (interactive or jsonl or (!eq(command, "draft.patch") and !eq(command, "draft.send") and !eq(command, "draft.queue"))) return error.ContentDigestRequiresSavedDraft;
            try req.object.put(sa, "expectedContentDigest", .{ .string = v });
        } else if (eq(arg, "--format")) {
            if (!eq(v, "markdown") and !eq(v, "plain")) return error.InvalidBodyFormat;
            if (interactive or jsonl) return error.FormatRequiresComposeCommand;
            source_format = v;
        } else if (eq(arg, "--from")) {
            try draft.object.put(sa, "from", .{ .string = v });
            has_draft = true;
        } else if (eq(arg, "--limit")) try req.object.put(sa, "limit", .{ .integer = std.fmt.parseInt(i64, v, 10) catch return error.InvalidOptionValue }) else if (eq(arg, "--cursor")) try req.object.put(sa, "cursor", .{ .string = v }) else if (eq(arg, "--query")) try req.object.put(sa, "query", .{ .string = v }) else if (eq(arg, "--label")) try req.object.put(sa, "label", .{ .string = v }) else if (eq(arg, "--message-id") or eq(arg, "--id")) try req.object.put(sa, "messageId", .{ .string = v }) else if (eq(arg, "--thread-id")) try req.object.put(sa, "threadId", .{ .string = v }) else if (eq(arg, "--draft-id")) try req.object.put(sa, "draftId", .{ .string = v }) else if (eq(arg, "--attachment-id")) try req.object.put(sa, "attachmentId", .{ .string = v }) else if (eq(arg, "--operation-id")) try req.object.put(sa, "operationId", .{ .string = v }) else if (eq(arg, "--status")) try req.object.put(sa, "status", .{ .string = v }) else if (eq(arg, "--to") or eq(arg, "--cc") or eq(arg, "--bcc")) {
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
        } else return unknownOption(arg);
    }
    if (try j.boolean(req, "original", false) and try j.boolean(req, "preserveFormatting", false)) return error.ConflictingForwardModes;
    const one_shot_command = j.text(req, "cmd");
    if (!interactive and !jsonl and (eq(one_shot_command, "mail.reply") or eq(one_shot_command, "mail.forward")) and has_draft) {
        // A reply or forward note is the top-level bodyText; the recipients,
        // subject and threading come from the original message.
        var it = draft.object.iterator();
        while (it.next()) |field| if (!eq(field.key_ptr.*, "bodyText")) return error.ReplyAcceptsOnlyBody;
        if (j.get(draft, "bodyText")) |body| try req.object.put(sa, "bodyText", body);
        has_draft = false;
    }
    if (j.get(req, "dryRun") != null and send_delay != null) return error.DryRunConflictsWithSendDelay;
    if (has_draft) {
        if (req.object.get("draft") != null) return error.ConflictingDraftOptions;
        try req.object.put(sa, "draft", draft);
    }
    if (source_format) |format| {
        const command = j.text(req, "cmd");
        if (eq(command, "mail.reply") or eq(command, "mail.forward")) {
            try req.object.put(sa, "bodyFormat", .{ .string = format });
        } else if (eq(command, "draft.create") or eq(command, "draft.update") or eq(command, "draft.preview") or eq(command, "draft.patch") or eq(command, "mail.send")) {
            if (eq(command, "draft.preview") and j.text(req, "draftId").len != 0 and req.object.get("draft") == null) return error.FormatRequiresDraftSource;
            var formatted = try j.copyObject(sa, req.object.get("draft") orelse draft);
            try formatted.object.put(sa, "bodyFormat", .{ .string = format });
            try req.object.put(sa, "draft", formatted);
        } else return error.FormatRequiresComposeCommand;
    }
    if (!interactive and !jsonl and eq(j.text(req, "cmd"), "draft.patch")) {
        // Patch flags and a --draft-file name only the fields to change.
        const changes = req.object.get("draft") orelse return error.PatchRequiresChanges;
        _ = req.object.orderedRemove("draft");
        try req.object.put(sa, "set", changes);
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
        const status = replyStatus(j.text(req, "cmd"), parsed);
        if (status != 0) return failed(status);
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
        // ok:true alone is not success for a send or RSVP: its outcome decides.
        const status = replyStatus(j.text(req, "cmd"), parsed);
        if (status != 0) return failed(status);
        return;
    }
    // --account fills in account only for frames that omit it. A malformed
    // process option is a usage error before any frame is read.
    const default_account: ?[]const u8 = if (options.account) |address| blk: {
        @import("recipients.zig").validateAddress(address) catch return error.InvalidAccountOption;
        break :blk address;
    } else null;
    var saw_unknown = false;
    var saw_failure = false;
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
        const request = if (oversized) "" else if (default_account) |address| try withAccount(frame.allocator(), bytes.items, address) else bytes.items;
        const response = try client.call(frame.allocator(), request);
        try output.interface.writeAll(response);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        if (strict) switch (strictStatus(frame.allocator(), request, response)) {
            0 => {},
            6 => saw_unknown = true,
            else => saw_failure = true,
        };
        if (eof) break;
    }
    // --strict: 6 when any reply may have applied an unknown outcome, else 3
    // when any reply failed or reported a send/RSVP that was not applied.
    if (saw_unknown) return failed(6);
    if (saw_failure) return failed(3);
}
/// Insert "account" into a frame that has none (and is not accounts.list).
/// Only top-level keys are scanned; values are skipped without allocation,
/// and an unparsable frame is passed on unchanged for the executor to refuse.
fn withAccount(a: std.mem.Allocator, raw: []const u8, account: []const u8) ![]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(a, raw);
    defer scanner.deinit();
    if ((scanner.next() catch return raw) != .object_begin) return raw;
    while (true) {
        const key = switch (scanner.nextAlloc(a, .alloc_if_needed) catch return raw) {
            .object_end => break,
            .string => |text| text,
            .allocated_string => |text| text,
            else => return raw,
        };
        if (eq(key, "account")) return raw;
        if (eq(key, "cmd")) {
            const command = switch (scanner.nextAlloc(a, .alloc_if_needed) catch return raw) {
                .string => |text| text,
                .allocated_string => |text| text,
                else => return raw,
            };
            if (eq(command, "accounts.list")) return raw;
        } else scanner.skipValue() catch return raw;
    }
    const open = std.mem.indexOfScalar(u8, raw, '{') orelse return raw;
    const rest = std.mem.trimStart(u8, raw[open + 1 ..], " \t\r");
    const field = try std.json.Stringify.valueAlloc(a, account, .{});
    return std.mem.concat(a, u8, &.{ raw[0 .. open + 1], "\"account\":", field, if (rest.len != 0 and rest[0] == '}') "" else ",", raw[open + 1 ..] });
}
/// Whether a reply frame reports ok:true, reading top-level keys only.
fn replyOk(a: std.mem.Allocator, response: []const u8) bool {
    var scanner = std.json.Scanner.initCompleteInput(a, response);
    defer scanner.deinit();
    if ((scanner.next() catch return false) != .object_begin) return false;
    while (true) {
        const key = switch (scanner.nextAlloc(a, .alloc_if_needed) catch return false) {
            .string => |text| text,
            .allocated_string => |text| text,
            else => return false,
        };
        if (eq(key, "ok")) return (scanner.next() catch return false) == .true;
        scanner.skipValue() catch return false;
    }
}
/// Exit status of the last failed one-shot or strict JSONL run; main exits
/// with it. See replyStatus for the documented table.
var exit_status: u8 = 0;
fn failed(status: u8) error{CommandFailed} {
    exit_status = status;
    return error.CommandFailed;
}
pub fn exitStatus() u8 {
    return if (exit_status == 0) 3 else exit_status;
}
const authorization_codes = [_][]const u8{ "PermissionDenied", "NotConnected", "InvalidGrant", "OAuthClientRequired", "WrongAccount", "GrantClientMismatch", "KeyringUnavailable", "KeyringLocked", "CredentialStorageAccessDenied", "VaultLocked", "BackendRequired", "DriveNotConnected", "DriveAccessExpired", "CalendarPermissionRequired", "CalendarReadPermissionRequired", "CalendarWritePermissionRequired", "MeetSettingsPermissionRequired" };
/// Commands whose ok:true reply is a send or RSVP receipt: success depends on
/// its outcome/state, not on ok alone.
fn sendCommand(command: []const u8) bool {
    for ([_][]const u8{ "mail.send", "draft.send", "draft.queue", "queue.process", "queue.send-now", "invitation.reply" }) |name| if (eq(command, name)) return true;
    return false;
}
/// Documented exit status of one reply frame:
///   0 ok (a send/RSVP was applied, staged or planned as sendable)
///   3 rejected or not applied (validation, refusal, blocked dry run, send
///     outcome rejected/blocked/preparationStopped/stopped, canceled queue)
///   4 authorization or capability missing
///   5 account, message, draft, label or other target not found
///   6 unknown outcome (UnknownOutcome, send outcome/state unknown or
///     submitting, or an interrupted write without a replay identity)
///   7 transient: the reply says retryable:true; repeat it later unchanged
pub fn replyStatus(command: []const u8, frame: j.Value) u8 {
    if (frame != .object) return 3;
    if (!(j.boolean(frame, "ok", false) catch false)) return errorStatus(command, j.get(frame, "error") orelse .null);
    return outcomeStatus(command, j.get(frame, "data") orelse .null);
}
fn errorStatus(command: []const u8, failure: j.Value) u8 {
    const code = j.text(failure, "code");
    if (eq(code, "UnknownOutcome")) return 6;
    for (authorization_codes) |auth| if (eq(code, auth)) return 4;
    if (eq(code, "UnknownAccount") or eq(code, "CacheMiss") or std.mem.endsWith(u8, code, "NotFound")) return 5;
    if (j.boolean(failure, "retryable", false) catch false) return 7;
    // The executor withholds retryable from an interrupted write that has no
    // operationId/undoToken: it may have been applied.
    if (@import("cli_contract.zig").interruption(code) and @import("client_contract.zig").mayMutate(command)) return 6;
    return 3;
}
fn outcomeStatus(command: []const u8, data: j.Value) u8 {
    if (calendarWriteCommand(command) and data == .object) {
        const state = j.text(data, "state");
        if (eq(state, "unknown")) return 6;
        if (eq(state, "rejected")) return 3;
        return 0;
    }
    if (!sendCommand(command) or data != .object) return 0;
    if (j.boolean(data, "dryRun", false) catch false) {
        // A dry run of an identity with a recorded receipt replays it.
        const replayed = j.text(j.get(data, "replay") orelse .null, "outcome");
        if (eq(replayed, "unknown")) return 6;
        if (eq(replayed, "rejected") or eq(j.text(data, "status"), "blocked")) return 3;
        return 0;
    }
    const outcome = j.text(data, "outcome");
    if (eq(outcome, "unknown")) return 6;
    if (eq(outcome, "rejected") or eq(outcome, "blocked") or eq(outcome, "preparationStopped") or eq(j.text(data, "status"), "stopped")) return 3;
    const state = j.text(data, "state");
    if (eq(state, "unknown") or eq(state, "submitting")) return 6;
    if (eq(state, "rejected") or eq(state, "canceled") or eq(state, "preparing")) return 3;
    if (eq(state, "queued")) {
        // Staging succeeds as queued unless its preparation stopped; a
        // processing command that leaves the item queued did not send it.
        if (!eq(command, "draft.queue")) return 3;
        const preparation = j.get(data, "preparation") orelse .null;
        if (eq(j.text(preparation, "outcome"), "preparationStopped") or eq(j.text(preparation, "status"), "stopped")) return 3;
    }
    return 0;
}
/// The cmd of a request frame, reading top-level keys only.
fn frameCommand(a: std.mem.Allocator, raw: []const u8) []const u8 {
    var scanner = std.json.Scanner.initCompleteInput(a, raw);
    defer scanner.deinit();
    if ((scanner.next() catch return "") != .object_begin) return "";
    while (true) {
        const key = switch (scanner.nextAlloc(a, .alloc_if_needed) catch return "") {
            .string => |text| text,
            .allocated_string => |text| text,
            else => return "",
        };
        if (!eq(key, "cmd")) {
            scanner.skipValue() catch return "";
            continue;
        }
        return switch (scanner.nextAlloc(a, .alloc_if_needed) catch return "") {
            .string => |text| text,
            .allocated_string => |text| text,
            else => "",
        };
    }
}
fn strictStatus(a: std.mem.Allocator, request: []const u8, response: []const u8) u8 {
    const frame = std.json.parseFromSliceLeaky(j.Value, a, response, .{}) catch return 3;
    return replyStatus(frameCommand(a, request), frame);
}
/// The offending option, when it is a plain option-looking word that cannot
/// carry private data; main names it with the nearest valid option.
pub var unknown_option: [48]u8 = undefined;
pub var unknown_option_len: usize = 0;
fn unknownOption(arg: []const u8) error{UnknownOption} {
    unknown_option_len = 0;
    var plain = arg.len > 2 and arg.len <= unknown_option.len and std.mem.startsWith(u8, arg, "--");
    for (arg) |byte| plain = plain and (std.ascii.isAlphanumeric(byte) or byte == '-');
    if (plain) {
        @memcpy(unknown_option[0..arg.len], arg);
        unknown_option_len = arg.len;
    }
    return error.UnknownOption;
}
pub fn nearestOption(arg: []const u8) ?[]const u8 {
    var candidates: [160][]const u8 = undefined;
    var count: usize = 0;
    for (value_options ++ boolean_options ++ [_][]const u8{ "--help", "--help-all", "--help-options", "--schema", "--manifest", "--compact", "--strict", "--calendar-id", "--event-id", "--date", "--view", "--time-zone", "--review-hash", "--send-updates", "--meet-ai-notes" }) |candidate| {
        if (count == candidates.len) break;
        candidates[count] = candidate;
        count += 1;
    }
    return @import("cli_contract.zig").nearest(arg, candidates[0..count]);
}
/// --schema [COMMAND] [--compact], in either order after --schema. Schemas
/// are offline: shared process options (and their values) are accepted and
/// ignored; anything else is named as not valid with --schema.
fn schemaRequest(io: std.Io, a: std.mem.Allocator, args: anytype) !void {
    var target: ?[]const u8 = null;
    var compact = false;
    while (args.next()) |arg| {
        if (eq(arg, "--compact")) {
            compact = true;
        } else if (target == null and !std.mem.startsWith(u8, arg, "-")) {
            target = arg;
        } else if (booleanOption(arg)) {
            continue;
        } else if (valueOption(arg)) {
            if (!args.skip()) return error.ValueRequired;
        } else {
            _ = unknownOption(arg) catch {};
            return error.SchemaOptionUnsupported;
        }
    }
    return @import("cli_api.zig").schemas(io, a, target, compact);
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
            try schemaRequest(io, a, &scan);
            return true;
        }
        if (jsonl and eq(arg, "--manifest")) {
            try @import("cli_api.zig").manifest(io, a);
            return true;
        }
        if (valueOption(arg)) {
            if (!scan.skip()) return false;
        } else if (!booleanOption(arg)) return false;
    }
    return false;
}
const boolean_options = [_][]const u8{ "--fixtures", "--no-mouse", "--cached", "--cache-only", "--server", "--json", "--browser", "--wait", "--original", "--preserve-formatting", "--all", "--reply-all", "--unread", "--read", "--starred", "--unstarred", "--body-stdin", "--rsvp-only", "--dry-run", "--strict", "--replace" };
fn booleanOption(arg: []const u8) bool {
    for (boolean_options) |flag| if (eq(arg, flag)) return true;
    return false;
}
fn draftSourceCommand(command: []const u8) bool {
    return eq(command, "mail.send") or eq(command, "draft.create") or eq(command, "draft.update") or eq(command, "draft.preview");
}
/// One-shot commands whose --dry-run is the executor's JSONL dryRun plan:
/// saved-draft sends and label changes (spam/unspam become mail.batch).
fn plannedCommand(command: []const u8) bool {
    for ([_][]const u8{ "draft.send", "draft.queue", "mail.archive", "mail.trash", "mail.restore", "mail.mark", "mail.batch", "mail.spam", "mail.unspam", "calendar.event-delete-review", "calendar.event-respond-review", "calendar.event-apply" }) |name| if (eq(command, name)) return true;
    return false;
}
/// Calendar writes whose ok:true reply carries a durable state that decides
/// the exit status (unknown 6, rejected 3), as for sends.
fn calendarWriteCommand(command: []const u8) bool {
    for ([_][]const u8{ "calendar.apply", "calendar.import", "calendar.update", "calendar.cancel", "calendar.reconcile", "calendar.event-apply", "calendar.event-reconcile", "calendar.event-retry" }) |name| if (eq(command, name)) return true;
    return false;
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
const value_options = [_][]const u8{
    "--backend",                 "--config",           "--metrics-file",         "--grant-file",    "--client-file",  "--capabilities",
    "--fixture-root",            "--fixture-scenario", "--cache-dir",            "--ui-file",       "--editor-mode",  "--metadata-limit",
    "--cache-messages",          "--prefetch-bodies",  "--disk-limit-bytes",     "--cache-bytes",   "--account",      "--action",
    "--undo-token",              "--url",              "--path",                 "--message-ids",   "--message-id",   "--id",
    "--before-message-id",       "--after-message-id", "--boundary-received-at", "--format",        "--from",         "--limit",
    "--cursor",                  "--query",            "--label",                "--thread-id",     "--draft-id",     "--attachment-id",
    "--operation-id",            "--status",           "--to",                   "--cc",            "--bcc",          "--subject",
    "--body",                    "--attach-file",      "--name",                 "--label-id",      "--confirm-name", "--body-file",
    "--draft-file",              "--event-file",       "--contact-file",         "--expected-etag", "--add-label",    "--remove-label",
    "--background-color",        "--text-color",       "--queue-id",             "--blob-id",       "--mime-type",    "--scope",
    "--send-delay",              "--delay-seconds",    "--next-attempt",         "--upload-file",   "--file",         "--attachment-mode",
    "--expected-content-digest",
};
fn valueOption(arg: []const u8) bool {
    if (calendarField(arg) != null) return true;
    for (value_options) |candidate| if (eq(arg, candidate)) return true;
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
        .{ .flag = "--meet-ai-notes", .key = "meetAiNotes" },
        .{ .flag = "--response", .key = "response" },
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

test "cli process: --account fills only frames without one and --strict reads reply status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filled = try withAccount(a, " {\"id\":1,\"cmd\":\"mail.list\",\"limit\":2}", "fictional@example.test");
    const value = try std.json.parseFromSliceLeaky(j.Value, a, filled, .{ .duplicate_field_behavior = .@"error" });
    try std.testing.expectEqualStrings("fictional@example.test", j.text(value, "account"));
    try std.testing.expectEqualStrings("{\"account\":\"fictional@example.test\"}", try withAccount(a, "{}", "fictional@example.test"));
    for ([_][]const u8{ "{\"cmd\":\"mail.list\",\"account\":\"other@example.test\"}", "{\"cmd\":\"accounts.list\"}", "not json", "[1]" }) |raw| try std.testing.expectEqualStrings(raw, try withAccount(a, raw, "fictional@example.test"));
    try std.testing.expect(replyOk(a, "{\"version\":1,\"id\":\"x\\\"y\",\"ok\":true,\"data\":{}}"));
    try std.testing.expect(!replyOk(a, "{\"version\":1,\"id\":null,\"ok\":false,\"error\":{\"code\":\"MissingField\"}}"));
    try std.testing.expectEqualStrings("draft.send", frameCommand(a, "{\"id\":{\"cmd\":\"x\"},\"cmd\":\"draft.send\",\"draftId\":\"d\"}"));
    try std.testing.expectEqualStrings("", frameCommand(a, "not json"));
    _ = failed(6) catch {};
    try std.testing.expectEqual(@as(u8, 6), exitStatus());
    _ = unknownOption("--fictional-flag") catch {};
    try std.testing.expectEqualStrings("--fictional-flag", unknown_option[0..unknown_option_len]);
    _ = unknownOption("private value with spaces") catch {};
    try std.testing.expectEqual(@as(usize, 0), unknown_option_len);
    try std.testing.expectEqualStrings("--cached", nearestOption("--cahced").?);
}
test "cli process: every documented exit status row is derived from the reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { command: []const u8, reply: []const u8, status: u8 };
    for ([_]Row{
        // 0: applied, staged or planned sendable; reads and other writes.
        .{ .command = "mail.send", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"applied\"}}", .status = 0 },
        .{ .command = "draft.queue", .reply = "{\"ok\":true,\"data\":{\"state\":\"queued\",\"resumeRequired\":false}}", .status = 0 },
        .{ .command = "queue.process", .reply = "{\"ok\":true,\"data\":{\"state\":\"applied\",\"operation\":{\"outcome\":\"applied\"}}}", .status = 0 },
        .{ .command = "draft.send", .reply = "{\"ok\":true,\"data\":{\"dryRun\":true,\"status\":\"planned\",\"sendable\":true}}", .status = 0 },
        .{ .command = "mail.read", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"unknown\"}}", .status = 0 },
        .{ .command = "invitation.reply", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"applied\",\"calendarSync\":{}}}", .status = 0 },
        // 3: rejected or not applied.
        .{ .command = "draft.send", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"rejected\"}}", .status = 3 },
        .{ .command = "invitation.reply", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"blocked\",\"errorCode\":\"CalendarPermissionRequired\"}}", .status = 3 },
        .{ .command = "draft.send", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"preparationStopped\",\"status\":\"stopped\",\"canRetryPreparation\":true}}", .status = 3 },
        .{ .command = "mail.send", .reply = "{\"ok\":true,\"data\":{\"status\":\"stopped\"}}", .status = 3 },
        .{ .command = "queue.process", .reply = "{\"ok\":true,\"data\":{\"state\":\"canceled\"}}", .status = 3 },
        .{ .command = "queue.send-now", .reply = "{\"ok\":true,\"data\":{\"state\":\"queued\",\"resumeRequired\":true}}", .status = 3 },
        .{ .command = "draft.queue", .reply = "{\"ok\":true,\"data\":{\"state\":\"queued\",\"resumeRequired\":true,\"preparation\":{\"outcome\":\"preparationStopped\",\"status\":\"stopped\"}}}", .status = 3 },
        .{ .command = "mail.send", .reply = "{\"ok\":true,\"data\":{\"dryRun\":true,\"status\":\"blocked\",\"sendable\":false}}", .status = 3 },
        .{ .command = "mail.read", .reply = "{\"ok\":false,\"error\":{\"code\":\"UnknownField\",\"retryable\":false}}", .status = 3 },
        .{ .command = "mail.send", .reply = "{\"ok\":false,\"error\":{\"code\":\"AttachmentPlanBlocked\"}}", .status = 3 },
        // 4 and 5.
        .{ .command = "mail.send", .reply = "{\"ok\":false,\"error\":{\"code\":\"PermissionDenied\"}}", .status = 4 },
        .{ .command = "mail.read", .reply = "{\"ok\":false,\"error\":{\"code\":\"MessageNotFound\"}}", .status = 5 },
        .{ .command = "mail.read", .reply = "{\"ok\":false,\"error\":{\"code\":\"UnknownAccount\"}}", .status = 5 },
        // 6: the change may have happened.
        .{ .command = "draft.send", .reply = "{\"ok\":false,\"error\":{\"code\":\"UnknownOutcome\",\"retryable\":false}}", .status = 6 },
        .{ .command = "mail.send", .reply = "{\"ok\":true,\"data\":{\"outcome\":\"unknown\"}}", .status = 6 },
        .{ .command = "queue.process", .reply = "{\"ok\":true,\"data\":{\"state\":\"submitting\"}}", .status = 6 },
        .{ .command = "draft.send", .reply = "{\"ok\":true,\"data\":{\"dryRun\":true,\"status\":\"planned\",\"replay\":{\"outcome\":\"unknown\"}}}", .status = 6 },
        .{ .command = "contacts.upsert", .reply = "{\"ok\":false,\"error\":{\"code\":\"Timeout\",\"hint\":\"verify\"}}", .status = 6 },
        // 7: the reply itself says the same request may succeed later.
        .{ .command = "mail.read", .reply = "{\"ok\":false,\"error\":{\"code\":\"Timeout\",\"retryable\":true}}", .status = 7 },
        .{ .command = "labels.create", .reply = "{\"ok\":false,\"error\":{\"code\":\"Timeout\",\"retryable\":true}}", .status = 7 },
        .{ .command = "mail.list", .reply = "{\"ok\":false,\"error\":{\"code\":\"RateLimited\",\"retryable\":true}}", .status = 7 },
        // Calendar writes: the durable state decides, as for sends.
        .{ .command = "calendar.event-apply", .reply = "{\"ok\":true,\"data\":{\"state\":\"applied\"}}", .status = 0 },
        .{ .command = "calendar.event-apply", .reply = "{\"ok\":true,\"data\":{\"dryRun\":true,\"state\":\"not_sent\"}}", .status = 0 },
        .{ .command = "calendar.event-apply", .reply = "{\"ok\":true,\"data\":{\"state\":\"rejected\",\"errorCode\":\"CalendarVersionConflict\"}}", .status = 3 },
        .{ .command = "calendar.event-apply", .reply = "{\"ok\":true,\"data\":{\"state\":\"unknown\"}}", .status = 6 },
        .{ .command = "calendar.event-reconcile", .reply = "{\"ok\":true,\"data\":{\"state\":\"unknown\",\"retryPossible\":true}}", .status = 6 },
        .{ .command = "calendar.event-abandon", .reply = "{\"ok\":true,\"data\":{\"state\":\"archived\"}}", .status = 0 },
        .{ .command = "calendar.event-delete-review", .reply = "{\"ok\":false,\"error\":{\"code\":\"CalendarWritePermissionRequired\"}}", .status = 4 },
        .{ .command = "calendar.event-respond-review", .reply = "{\"ok\":false,\"error\":{\"code\":\"CalendarOrganizerCannotRespond\"}}", .status = 3 },
        .{ .command = "calendar.event-delete-review", .reply = "{\"ok\":false,\"error\":{\"code\":\"CalendarNotFound\"}}", .status = 5 },
    }) |row| {
        const frame = try std.json.parseFromSliceLeaky(j.Value, a, row.reply, .{});
        std.testing.expectEqual(row.status, replyStatus(row.command, frame)) catch |err| {
            std.debug.print("{s} {s}\n", .{ row.command, row.reply });
            return err;
        };
    }
    // --strict collapses to 6 when any reply is unknown, else 3, else 0.
    try std.testing.expectEqual(@as(u8, 6), strictStatus(a, "{\"cmd\":\"draft.send\"}", "{\"ok\":true,\"data\":{\"outcome\":\"unknown\"}}"));
    try std.testing.expectEqual(@as(u8, 3), strictStatus(a, "{\"cmd\":\"draft.send\"}", "{\"ok\":true,\"data\":{\"outcome\":\"rejected\"}}"));
    try std.testing.expectEqual(@as(u8, 0), strictStatus(a, "{\"cmd\":\"mail.list\"}", "{\"ok\":true,\"data\":{}}"));
    try std.testing.expectEqual(@as(u8, 3), strictStatus(a, "{\"cmd\":\"mail.list\"}", "garbage"));
}
