//! Contextual, credential-free help. Command families also drive argv validation.
const std = @import("std");
const Family = struct { name: []const u8, summary: []const u8, verbs: []const []const u8 };
const families = [_]Family{
    .{ .name = "mail", .summary = "Read, search, reply, forward and organize mail", .verbs = &.{ "list", "search", "read", "thread", "attachment", "attachment-save", "open", "sync", "refresh", "recipients", "reply", "forward", "send", "archive", "trash", "restore", "spam", "unspam", "mark", "batch", "undo", "triage-scope", "label-state", "prefetch", "drafts", "compose", "labels", "identities", "open-link", "open-attachment" } },
    .{ .name = "draft", .summary = "Create, review and send local drafts", .verbs = &.{ "list", "read", "create", "update", "patch", "preview", "open-preview", "recovery-save", "send", "queue", "discard", "restore" } },
    .{ .name = "queue", .summary = "Inspect, cancel or submit a staged send", .verbs = &.{ "list", "read", "cancel", "resume", "process", "send-now" } },
    .{ .name = "attachment", .summary = "Import, discard or open private attachment handles", .verbs = &.{ "import", "discard", "open" } },
    .{ .name = "contacts", .summary = "Read, search and update the address book", .verbs = &.{ "list", "search", "upsert" } },
    .{ .name = "labels", .summary = "Manage custom label definitions and colors", .verbs = &.{ "list", "create", "rename", "delete", "color", "palette" } },
    .{ .name = "invitations", .summary = "Inspect invitations or send an RSVP", .verbs = &.{ "inspect", "reply" } },
    .{ .name = "calendar", .summary = "Browse calendars, create meetings and review event changes", .verbs = &.{ "list", "agenda", "event", "freebusy", "invitation-plan", "review", "apply", "import", "update", "cancel", "reconcile", "event-review", "event-delete-review", "event-respond-review", "event-apply", "event-reconcile", "event-retry", "event-abandon", "event-pending", "meet-event-review", "meet-event-apply", "meet-event-reconcile", "meet-event-pending", "open", "event-open" } },
    .{ .name = "cache", .summary = "Inspect or clear retained mail", .verbs = &.{ "stats", "clear", "activity", "refresh-status" } },
    .{ .name = "operation", .summary = "Inspect recorded submission outcomes", .verbs = &.{ "list", "read" } },
    .{ .name = "terminal-auth", .summary = "Inspect, authorize or revoke terminal grants", .verbs = &.{ "status", "authorize", "revoke" } },
    .{ .name = "updates", .summary = "Check releases and installation-specific upgrade guidance", .verbs = &.{ "status", "check", "guide", "dismiss", "automatic" } },
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn knownVerb(mode: []const u8, verb: []const u8) bool {
    for (families) |f| if (eq(mode, f.name)) {
        for (f.verbs) |candidate| if (eq(verb, candidate)) return true;
        return false;
    };
    return false;
}
/// The closest valid operation of a known family, for a usage hint.
pub fn nearestVerb(mode: []const u8, verb: []const u8) ?[]const u8 {
    for (families) |f| if (eq(mode, f.name)) return @import("cli_contract.zig").nearest(verb, f.verbs);
    return null;
}
pub fn knownFamily(mode: []const u8) bool {
    for (families) |f| if (eq(mode, f.name)) return true;
    return false;
}
pub fn jsonFamily(mode: []const u8) []const u8 {
    return if (eq(mode, "invitations")) "invitation" else if (eq(mode, "terminal-auth")) "auth" else mode;
}
pub fn jsonAlias(mode: []const u8, verb: []const u8) ?[]const u8 {
    if (!eq(mode, "mail")) return null;
    if (eq(verb, "drafts")) return "draft.list";
    if (eq(verb, "compose")) return "draft.create";
    if (eq(verb, "labels")) return "labels.list";
    if (eq(verb, "identities")) return "accounts.identities";
    if (eq(verb, "open-link")) return "browser.open";
    if (eq(verb, "open-attachment")) return "attachment.open";
    return null;
}
pub fn overview(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("omagma {s} (Zig {s})\nExperimental terminal mail and Gmail bar\n\nUsage: omagma COMMAND [OPTIONS]\n\n", .{ @import("build_options").version, @import("builtin").zig_version_string });
    try writer.interface.writeAll("  tui                 Interactive mail client\n  server              Serve the bundled browser mail client locally\n  cli | agent         JSONL requests on stdin, replies on stdout\n");
    for (families) |f| try writer.interface.print("  {s:<19} {s}\n", .{ f.name, f.summary });
    try writer.interface.writeAll("  credentials         Inspect, migrate or export existing credentials\n  cache-refresh       Refresh enabled account caches without the TUI\n  daemon | auth | status  Read-only Gmail bar and its authorization\n  version | --version Show the installed version\n  build-info | budget Build and allocation diagnostics\n\nStart with omagma cli --help for agent examples.\nUse omagma mail --help to choose an operation, then omagma mail read --help.\nUse omagma --help-all for the extended command overview.\n");
    try writer.interface.flush();
}
pub fn family(io: std.Io, mode: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    if (eq(mode, "tui")) {
        try writer.interface.writeAll("Experimental terminal mail · TUI\n\nUsage: omagma tui [--account ADDRESS] [--config FILE] [--grant-file FILE]\n                  [--cache-dir DIR] [--ui-file FILE] [--no-mouse]\n                  [--editor-mode auto|takeover] [--fixtures]\n\nPress ? in the TUI for searchable keyboard and mouse help.\nUse omagma tui --help-all or --help-options for advanced process options.\nUse omagma cli --help for automation; omagma --help for other commands.\n");
    } else {
        var found = false;
        for (families) |f| if (eq(mode, f.name)) {
            found = true;
            try writer.interface.print("Experimental terminal mail · {s}\n{s}\n\nUsage: omagma {s} OPERATION [OPTIONS]\n\nOperations:\n", .{ mode, f.summary, mode });
            for (f.verbs) |verb| try writer.interface.print("  {s:<17} {s}\n", .{ verb, spec(mode, verb).summary });
            try writer.interface.print("\nUse omagma {s} OPERATION --help for flags and a shell example.\nUse omagma {s} OPERATION --help-all for advanced options and structured-file formats.\nUse omagma cli --help for the JSONL protocol.\n", .{ mode, mode });
        };
        if (!found) return error.UnknownCommand;
    }
    try writer.interface.flush();
}
/// Shared by mail send and draft create/update/preview; saving never uploads.
const file_flags = "\n\nFiles (each flag repeatable; combine freely):\n  --attach-file FILE      always attach\n  --upload-file FILE      always share from Drive\n  --file FILE             follow --attachment-mode attach|auto|drive (default attach);\n                          auto attaches what fits and shares the rest from Drive\n  --attach-file and --upload-file override --file for the same path; one path in both of them is refused\n  --dry-run               print the file plan and blockers from local metadata only:\n                          no import, authorization, network, save or send\n  Drive files are shared viewer-only with To/Cc when sent; Bcc with Drive is refused.\n  Sending Drive files needs the drive-upload grant: omagma terminal-auth authorize --help";
const draft_save_flags = "--draft-id ID (required for update; omitted for create)\n  --to ADDRESSES --cc ADDRESSES --bcc ADDRESSES\n  --subject TEXT (--body-file FILE | --body-stdin | --body TEXT)\n  --format plain|markdown --from ADDRESS\n  --draft-file FILE supplies a bare Draft object, not a JSONL request; recipient/body/file flags conflict, but --format is allowed";
const delivery_fields = "attachments[].delivery? (attach|auto|drive). Drive files are uploaded to the account's Drive and shared viewer-only with To/Cc; Bcc with Drive is refused; at most 16 Drive files. Preparation retries are explicit and reuse operationId; never automatically retry UnknownOutcome.";
const Spec = struct { summary: []const u8, flags: []const u8 = "", fields: []const u8 = "", example: ?[]const u8 = null, json_cmd: ?[]const u8 = null };
pub fn options(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        \\Shared terminal process options (TUI, JSONL and account-scoped one-shot commands)
        \\  --config FILE           Private config; default $XDG_CONFIG_HOME/omagma/config.json
        \\                          or $HOME/.config/omagma/config.json
        \\  --grant-file FILE       Terminal grants; default same config base /omagma/terminal-grants.json
        \\  --cache-dir DIR         Private cache; default $XDG_CACHE_HOME/omagma/terminal
        \\                          or $HOME/.cache/omagma/terminal
        \\  --account ADDRESS       Select an enabled account; supply it explicitly for one-shot tasks
        \\  --json                  One-shot replies already are JSON; compatibility flag
        \\
        \\Cache/resource options (existing stored quotas persist unless explicitly overridden)
        \\  --metadata-limit N      Alias --cache-messages; 1..10000, fresh default 2000
        \\  --disk-limit-bytes N    Alias --cache-bytes; 65536..1073741824 decimal bytes
        \\                          fresh default 268435456 (256 MiB)
        \\  --prefetch-bodies N     0..64, normally 32; applies to body fetching/refresh
        \\  --metrics-file FILE     Write allocation/HTML diagnostics to a private file on exit
        \\
        \\TUI-only controls
        \\  --ui-file FILE          Absolute preference path; default config base /omagma/ui.json
        \\  --editor-mode MODE      auto (default) or takeover
        \\  --no-mouse              Disable mouse interaction
        \\
        \\Disconnected fixtures
        \\  --fixtures              Synthetic accounts/provider, no Google requests or real sends
        \\  --fixture-root DIR      Fixture data root; requires --fixtures
        \\  --fixture-scenario NAME Fixture scenario; requires --fixtures
        \\
        \\In omagma cli, --account fills in account for request lines that omit it, and
        \\--strict exits at EOF with 6 if any reply had an unknown outcome, else 3 if
        \\any reply failed or reported a send/RSVP that was not applied, else 0.
        \\Command-specific data flags appear in COMMAND --help. For complete JSON objects,
        \\use omagma cli --help COMMAND or omagma cli --schema COMMAND.
        \\
    );
    try writer.interface.flush();
}
pub fn overviewFull(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll("Experimental terminal mail · complete one-shot command inventory\n\n");
    for (families) |f| {
        try writer.interface.print("  omagma {s} ", .{f.name});
        for (f.verbs, 0..) |verb, index| {
            if (index > 0) try writer.interface.writeByte('|');
            try writer.interface.writeAll(verb);
        }
        try writer.interface.writeByte('\n');
    }
    try writer.interface.writeAll("\nUse FAMILY OPERATION --help for scoped flags and an executable example.\nUse FAMILY OPERATION --help-all for advanced options and structured inputs.\nFor example: omagma mail recipients --help; omagma draft preview --help.\n\n");
    try writer.interface.flush();
    try options(io);
}
fn shellArguments(mode: []const u8, verb: []const u8) []const u8 {
    if (eq(mode, "mail")) {
        if (eq(verb, "compose")) return shellArguments("draft", "create");
        if (eq(verb, "list") or eq(verb, "sync")) return " --label INBOX --limit 5";
        if (eq(verb, "search")) return " --query 'is:unread' --server --limit 5";
        if (eq(verb, "read")) return " --message-id RETURNED_MESSAGE_ID";
        if (eq(verb, "thread")) return " --thread-id RETURNED_THREAD_ID";
        if (eq(verb, "attachment")) return " --message-id RETURNED_MESSAGE_ID --attachment-id RETURNED_ATTACHMENT_ID";
        if (eq(verb, "attachment-save")) return " --message-id RETURNED_MESSAGE_ID --attachment-id RETURNED_ATTACHMENT_ID --path NEW_PRIVATE_FILE";
        if (eq(verb, "reply") or eq(verb, "forward")) return " --message-id RETURNED_MESSAGE_ID --preserve-formatting";
        if (eq(verb, "send")) return " --to maya@example.org --subject Report --body-file note.md --file report.pdf --attachment-mode auto --operation-id UNIQUE_SEND_ID --dry-run";
        if (eq(verb, "archive") or eq(verb, "trash") or eq(verb, "restore") or eq(verb, "spam") or eq(verb, "unspam")) return " --message-id RETURNED_MESSAGE_ID --scope message";
        if (eq(verb, "mark")) return " --message-id RETURNED_MESSAGE_ID --starred";
        if (eq(verb, "batch")) return " --message-ids ID_ONE,ID_TWO --action archive";
        if (eq(verb, "undo")) return " --undo-token RETURNED_UNDO_TOKEN";
        if (eq(verb, "triage-scope")) return " --message-id RETURNED_MESSAGE_ID --scope conversation";
        if (eq(verb, "label-state")) return " --message-ids ID_ONE,ID_TWO";
        if (eq(verb, "recipients")) return " --cached";
        if (eq(verb, "refresh")) return " --label INBOX --limit 5 --prefetch-bodies 5";
        if (eq(verb, "prefetch")) return " --limit 5";
        if (eq(verb, "open")) return " --message-id RETURNED_MESSAGE_ID";
        if (eq(verb, "open-link")) return " --url https://example.org/";
        if (eq(verb, "open-attachment")) return shellArguments("attachment", "open");
    } else if (eq(mode, "draft")) {
        if (eq(verb, "create")) return " --to 'Maya Example <maya@example.org>' --subject Hello --body-file note.md --format markdown";
        if (eq(verb, "update")) return " --draft-id RETURNED_DRAFT_ID --draft-file complete-draft.json";
        if (eq(verb, "patch")) return " --draft-id RETURNED_DRAFT_ID --body-file new-note.md --expected-content-digest RETURNED_CONTENT_DIGEST";
        if (eq(verb, "preview")) return " --body '**Hello**' --format markdown";
        if (eq(verb, "recovery-save")) return " --draft-file recovery-fields.json";
        if (eq(verb, "send") or eq(verb, "queue")) return " --draft-id RETURNED_DRAFT_ID --operation-id UNIQUE_SEND_ID";
        if (!eq(verb, "list")) return " --draft-id RETURNED_DRAFT_ID";
    } else if (eq(mode, "queue")) {
        if (!eq(verb, "list")) return " --queue-id RETURNED_QUEUE_ID";
    } else if (eq(mode, "attachment")) {
        if (eq(verb, "import") or eq(verb, "open")) return " --path /absolute/private/document.pdf";
        return " --blob-id RETURNED_BLOB_ID";
    } else if (eq(mode, "contacts")) {
        if (eq(verb, "search")) return " --query Maya";
        if (eq(verb, "upsert")) return " --contact-file contact.json";
        return " --limit 5";
    } else if (eq(mode, "labels")) {
        if (eq(verb, "create")) return " --name Travel --operation-id UNIQUE_LABEL_ID";
        if (eq(verb, "rename")) return " --label-id RETURNED_LABEL_ID --name Travel --operation-id UNIQUE_LABEL_ID";
        if (eq(verb, "delete")) return " --label-id RETURNED_LABEL_ID --confirm-name Travel --operation-id UNIQUE_LABEL_ID";
        if (eq(verb, "color")) return " --label-id RETURNED_LABEL_ID --background-color '#f691b3' --text-color '#000000' --operation-id UNIQUE_LABEL_ID";
    } else if (eq(mode, "invitations")) {
        if (eq(verb, "reply")) return " --message-id RETURNED_MESSAGE_ID --status accepted --operation-id UNIQUE_RSVP_ID";
        return " --message-id RETURNED_MESSAGE_ID";
    } else if (eq(mode, "calendar")) {
        if (eq(verb, "list")) return "";
        if (eq(verb, "agenda") or eq(verb, "freebusy")) return " --calendar-id RETURNED_CALENDAR_ID --date 2026-10-13 --view week";
        if (eq(verb, "event") or eq(verb, "event-open")) return " --calendar-id RETURNED_CALENDAR_ID --event-id RETURNED_EVENT_ID";
        if (eq(verb, "open")) return "";
        if (eq(verb, "event-review")) return " --calendar-id RETURNED_CALENDAR_ID --event-file event.json --send-updates all --operation-id UNIQUE_EVENT_ID";
        if (eq(verb, "event-delete-review")) return " --calendar-id RETURNED_CALENDAR_ID --event-id RETURNED_EVENT_ID --expected-etag RETURNED_ETAG --scope event --send-updates all --operation-id UNIQUE_DELETE_ID";
        if (eq(verb, "event-respond-review")) return " --calendar-id RETURNED_CALENDAR_ID --event-id RETURNED_EVENT_ID --expected-etag RETURNED_ETAG --scope event --response declined --send-updates all --operation-id UNIQUE_RSVP_ID";
        if (eq(verb, "event-pending") or eq(verb, "meet-event-pending")) return " --calendar-id RETURNED_CALENDAR_ID";
        if (eq(verb, "meet-event-review")) return " --calendar-id RETURNED_CALENDAR_ID --event-file meeting.json --meet-ai-notes on --send-updates all --operation-id UNIQUE_MEET_EVENT_ID";
        if (eq(verb, "event-retry")) return " --calendar-id RETURNED_CALENDAR_ID --operation-id RETURNED_OPERATION_ID --review-hash RETURNED_REVIEW_HASH --next-attempt RETURNED_NEXT_ATTEMPT";
        if (eq(verb, "invitation-plan")) return " --calendar-id RETURNED_CALENDAR_ID --message-id RETURNED_MESSAGE_ID";
        if (eq(verb, "review")) return " --calendar-id RETURNED_CALENDAR_ID --message-id RETURNED_MESSAGE_ID --operation-id UNIQUE_CALENDAR_ID";
        return " --calendar-id RETURNED_CALENDAR_ID --operation-id RETURNED_OPERATION_ID --review-hash RETURNED_REVIEW_HASH";
    } else if (eq(mode, "operation")) {
        if (eq(verb, "read")) return " --operation-id RETURNED_OPERATION_ID";
    } else if (eq(mode, "terminal-auth")) {
        if (eq(verb, "authorize")) return " --client-file /absolute/private/terminal-registration.json --capabilities mail-read";
    } else if (eq(mode, "updates")) {
        return if (eq(verb, "automatic")) " on" else " --json";
    }
    return "";
}
pub fn expanded(io: std.Io, a: std.mem.Allocator, mode: []const u8, verb: []const u8) !void {
    try command(io, mode, verb);
    if (eq(mode, "updates")) return;
    try options(io);
    const name = jsonAlias(mode, verb) orelse try std.fmt.allocPrint(a, "{s}.{s}", .{ jsonFamily(mode), verb });
    if ((eq(mode, "draft") and (eq(verb, "create") or eq(verb, "update") or eq(verb, "preview") or eq(verb, "recovery-save"))) or (eq(mode, "mail") and (eq(verb, "send") or eq(verb, "compose")))) {
        try @import("cli_api.zig").sourceSchema(io, a, name, "draft");
    } else if (eq(mode, "draft") and eq(verb, "patch")) {
        try @import("cli_api.zig").sourceSchema(io, a, name, "set");
    } else if (eq(mode, "contacts") and eq(verb, "upsert")) try @import("cli_api.zig").sourceSchema(io, a, name, "contact");
}
fn spec(mode: []const u8, verb: []const u8) Spec {
    if (eq(mode, "mail")) {
        if (eq(verb, "compose")) return spec("draft", "create");
        if (eq(verb, "drafts")) return spec("draft", "list");
        if (eq(verb, "labels")) return spec("labels", "list");
        if (eq(verb, "open-attachment")) return spec("attachment", "open");
        if (eq(verb, "list")) return .{ .summary = "List a bounded message page", .flags = "--label LABEL --query QUERY --limit 1..100 (live default 30; cached default 32) --cursor CURSOR [--cached]\n  Cached windows: --before-message-id ID | --after-message-id ID\n  --boundary-received-at MILLISECONDS (fallback for an evicted anchor)", .fields = "label?, query?, limit? (1..100), cursor?, cacheOnly? (boolean). Result: messages[], nextCursor.", .example = "{\"id\":\"inbox\",\"cmd\":\"mail.list\",\"account\":\"personal@example.com\",\"label\":\"INBOX\",\"limit\":5}" };
        if (eq(verb, "sync")) return .{ .summary = "List a provider message page; this is not a history refresh", .flags = "--label LABEL --query QUERY --limit 1..100 (default 30) --cursor CURSOR", .fields = "label?, query?, limit? (1..100), cursor?. For downloaded mail use mail.list with cacheOnly:true; history refresh uses mail.refresh." };
        if (eq(verb, "search")) return .{ .summary = "Search downloaded mail or Gmail", .flags = "--query QUERY [--cached | --server] --label LABEL --limit 1..100 (live default 30; cached default 32) --cursor CURSOR\n  Cached windows: --before-message-id ID | --after-message-id ID\n  --boundary-received-at MILLISECONDS; window selectors cannot be combined with a cursor", .fields = "query, limit?, cursor?, cacheOnly? (true: local, false/default: Gmail). Local search supports a subset of Gmail syntax, plus status:partial for decode warnings and incomplete mail. Use a retained/all-mail view for unknown labels.", .example = "{\"id\":\"search\",\"cmd\":\"mail.search\",\"account\":\"personal@example.com\",\"query\":\"is:unread\",\"limit\":5}" };
        if (eq(verb, "read")) return .{ .summary = "Read a full message, labels, attachments and invitation details", .flags = "--message-id ID (alias --id) [--cached]", .fields = "messageId, cacheOnly? (boolean). Result includes bodyText, optional bodyHtml, bodySource, and attachments; bodySource \"plain\" does not mean bodyHtml is absent. Reading does not mark mail read.", .example = "{\"id\":\"read\",\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"RETURNED_MESSAGE_ID\"}" };
        if (eq(verb, "thread")) return .{ .summary = "Read a conversation in chronological order", .flags = "--thread-id ID [--cached]", .fields = "threadId, cacheOnly? (boolean). Result: messages[]. Cached conversations can be partial." };
        if (eq(verb, "attachment")) return .{ .summary = "Retrieve received attachment bytes or a private handle", .flags = "--message-id ID --attachment-id ID", .fields = "messageId, attachmentId. Result: filename/mimeType/size and data (base64url), or blobId for larger content." };
        if (eq(verb, "attachment-save")) return .{ .summary = "Stream a received attachment to a new private file", .flags = "--message-id ID --attachment-id ID --path NEW_FILE", .fields = "messageId, attachmentId, path. Saving refuses overwrite and symlink traversal." };
        if (eq(verb, "reply") or eq(verb, "forward")) return .{ .summary = "Create a local reply, reply-all or unaddressed forward draft", .flags = if (eq(verb, "reply")) "--message-id ID [--reply-all (alias --all)] [--format plain|markdown]\n  (--body TEXT | --body-file FILE | --body-stdin) note above the quote\n  --preserve-formatting keeps original HTML/images inline" else "--message-id ID [--format plain|markdown]\n  (--body TEXT | --body-file FILE | --body-stdin) note above the original\n  --preserve-formatting keeps original HTML/images inline\n  --original forwards as .eml (conflicts with --preserve-formatting)\n  A forward chooses no recipients: --reply-all is refused", .fields = "messageId, bodyText? (note), all? (reply-all, reply only), bodyFormat? (plain|markdown), preserveFormatting?; forward also accepts original? and JSON omitAttachments? (explicit text quote without files; conflicts with original/preserveFormatting). Recipients, subject and threading come from the original; change them afterwards with draft patch. Result is a local draft; this does not send mail." };
        if (eq(verb, "send")) return .{ .summary = "Submit a reviewed message with a stable operation identity", .flags = "--to ADDRESSES --subject TEXT (--body-file FILE | --body-stdin | --body TEXT)\n  --format plain|markdown --from ADDRESS --cc ADDRESSES --bcc ADDRESSES\n  --operation-id ID [--send-delay 0..30]\n  --draft-file FILE is an alternative to individual recipient/body/file flags; --format may accompany it" ++ file_flags, .fields = "draft (subject, bodyText, optional bodyFormat/from/attachments), operationId. Recipients: address-list strings or arrays of {address,name}. " ++ delivery_fields ++ " Direct send has no delay unless --send-delay is supplied; delayed one-shot send stages and waits. Result is a durable receipt: check data.outcome (applied, rejected, unknown or preparationStopped)." };
        if (eq(verb, "spam") or eq(verb, "unspam")) return .{ .summary = if (eq(verb, "spam")) "Move a message or reviewed conversation into Spam" else "Move a message or reviewed conversation out of Spam into Inbox", .flags = "--message-id ID (alias --id) [--scope message|conversation]\n  OR --message-ids ID,ID for an explicit batch", .json_cmd = "mail.batch", .fields = "messageIds (array), action (spam|unspam). For a conversation, first resolve mail.triage-scope and pass its exact IDs to mail.batch." };
        if (eq(verb, "archive") or eq(verb, "trash") or eq(verb, "restore")) return .{ .summary = if (eq(verb, "archive")) "Remove a message or reviewed conversation from Inbox" else if (eq(verb, "trash")) "Move a message or reviewed conversation to Trash" else "Return a message or reviewed conversation from Trash to Inbox", .flags = "--message-id ID (alias --id) [--scope message|conversation]\n  OR --message-ids ID,ID for an explicit batch\n  --dry-run resolves the label change per message and changes nothing", .fields = "messageId. JSONL conversation actions require mail.triage-scope followed by mail.batch with the resolved messageIds; direct scope does not expand targets." };
        if (eq(verb, "mark")) return .{ .summary = "Set read/star state or add/remove labels", .flags = "--message-id ID [--unread | --read] [--starred | --unstarred]\n  --add-label LABEL --remove-label LABEL (repeatable) [--scope message|conversation]\n  --message-ids ID,ID is an explicit-target alternative\n  --dry-run resolves the label change per message and changes nothing", .fields = "messageId, unread?, starred? (booleans), addLabels?, removeLabels? (arrays). For a conversation, resolve mail.triage-scope then use mail.batch with action:mark." };
        if (eq(verb, "batch")) return .{ .summary = "Apply an action to explicit targets and receive per-message outcomes", .flags = "--message-ids ID,ID --action archive|trash|restore|spam|unspam|mark\n  --unread|--read --starred|--unstarred --add-label LABEL --remove-label LABEL (repeatable)\n  OR --message-id ID --scope message|conversation as a single anchor", .fields = "messageIds (1..100 distinct IDs), action, optional unread/starred/addLabels/removeLabels. Result includes per-ID outcomes and undoToken." };
        if (eq(verb, "undo")) return .{ .summary = "Undo confirmed label changes from a batch", .flags = "--undo-token TOKEN [--message-ids ID,ID]", .fields = "undoToken, messageIds?. Only confirmed successful items are restored." };
        if (eq(verb, "triage-scope")) return .{ .summary = "Resolve the exact message/conversation targets before changing them", .flags = "--message-id ID --scope message|conversation", .fields = "messageId, scope. Result includes messageIds/count/threadId; incomplete or oversized conversations are refused." };
        if (eq(verb, "label-state")) return .{ .summary = "Inspect mixed/applied label membership across messages", .flags = "--message-ids ID,ID OR --message-id ID [--scope message|conversation]", .fields = "messageIds. Result includes per-label appliedCount and mixed state." };
        if (eq(verb, "identities")) return .{ .summary = "List verified Gmail send-as identities", .flags = "[--cached]", .fields = "cacheOnly?. Result: identities with address, name, signature and isDefault." };
        if (eq(verb, "recipients")) return .{ .summary = "List recent account-scoped recipient suggestions", .flags = "--cached", .fields = "cacheOnly:true. Suggestions combine downloaded contacts and retained mail, excluding the primary account." };
        if (eq(verb, "refresh")) return .{ .summary = "Refresh the bounded cache from Gmail history or recent mail", .flags = "--label LABEL --query QUERY --limit 1..100 (default 32)\n  --prefetch-bodies 0..64 (default min(limit,32))", .fields = "limit?, query?, label?, prefetchLimit? (0..64). Existing cache quotas remain in force." };
        if (eq(verb, "prefetch")) return .{ .summary = "Download a bounded recent message/body head", .flags = "--limit 0..64 (normally 32) --query QUERY --label LABEL", .fields = "limit? (0..64). Updates the private account cache." };
        if (eq(verb, "open")) return .{ .summary = "Open Gmail in this account's Chrome profile", .flags = "[--message-id ID]", .fields = "messageId?; omitted ID opens the inbox. This launches a browser." };
        if (eq(verb, "open-link")) return .{ .summary = "Open a literal HTTP(S) URL in this account's Chrome profile", .flags = "--url URL", .fields = "url. This launches a browser." };
    } else if (eq(mode, "draft")) {
        if (eq(verb, "create") or eq(verb, "update")) return .{ .summary = "Save a local draft without sending", .flags = if (eq(verb, "update")) draft_save_flags ++ "\n  Update replaces every editable field, files included: supply the complete draft, not only a new file\n  Guard: an update that would drop the saved recipients or reply threading is refused\n  (DraftReplaceWouldDropThreading); --replace allows it, draft patch changes only some fields" ++ file_flags else draft_save_flags ++ file_flags, .fields = "draft (subject, bodyText, optional bodyFormat/from/attachments); update also requires draftId and accepts replace? (boolean). Saving stores attachments[].delivery (attach|auto|drive) and never uploads; oversized Attach files are saved but block sending, and draft.delivery-plan reports blockers offline. Recipients: address-list strings or arrays of {address,name}. Update replaces editable fields: read and submit the complete draft rather than a partial patch. A passed-back contentDigest that no longer matches the saved draft is refused (ReviewedDraftChanged)." };
        if (eq(verb, "patch")) return .{ .summary = "Change only some fields of a saved local draft", .flags = "--draft-id ID [--expected-content-digest DIGEST]\n  --to ADDRESSES --cc ADDRESSES --bcc ADDRESSES --subject TEXT --from ADDRESS\n  (--body TEXT | --body-file FILE | --body-stdin) --format plain|markdown\n  --draft-file FILE supplies a bare partial Draft object (the fields to set)\n  Omitted fields (recipients, threading, files, original) stay exactly as saved", .fields = "draftId, set (the fields to change), expectedContentDigest? (refuses a changed draft with ReviewedDraftChanged), acknowledgementOnly?. set never accepts read-only contentDigest/gmailLink/summaryCounts/id or recoveryFields (ReadOnlyField). Sends nothing.", .example = "{\"id\":\"patch\",\"cmd\":\"draft.patch\",\"account\":\"personal@example.com\",\"draftId\":\"RETURNED_DRAFT_ID\",\"set\":{\"bodyText\":\"Thursday works.\"}}" };
        if (eq(verb, "preview")) return .{ .summary = "Render a local draft without saving or sending", .flags = "--draft-id ID [--browser] for a saved draft; Auto/Drive files add attachmentPlan (no --format/--dry-run)\n  OR --draft-file FILE as a bare Draft object\n  OR --to/--cc/--bcc ADDRESSES --subject TEXT --from ADDRESS\n     (--body-file FILE | --body-stdin | --body TEXT) --format plain|markdown\n     with the Files flags below; --format applies to supplied source, not a saved ID" ++ file_flags, .fields = "draftId or draft. Result: exact bodyText source, plainText, optional bodyHtml and bodyFormat; attachmentPlan only when a file uses Auto or Drive (Attach-only previews omit it). Preview never uploads.", .example = "{\"id\":\"preview\",\"cmd\":\"draft.preview\",\"account\":\"personal@example.com\",\"draft\":{\"bodyText\":\"**Hello**\",\"bodyFormat\":\"markdown\"}}" };
        if (eq(verb, "send") or eq(verb, "queue")) return .{ .summary = "Submit or stage a reviewed saved draft", .flags = "--draft-id ID --operation-id ID [--expected-content-digest DIGEST]\n  --send-delay 0..30 (send) OR --delay-seconds 0..30 (queue, default 10)\n  --dry-run returns the JSONL dryRun plan (status, sendable, contentDigest); nothing is sent or staged", .fields = "draftId, operationId, expectedContentDigest?, dryRun?; queue also accepts delaySeconds (0..30). Exit status follows data.outcome/state: 0 applied/staged, 3 rejected/blocked/stopped, 6 unknown. Queue returns queueId/dueAtMs/state and requires explicit processing. Direct send has no delay unless --send-delay is supplied; send returns a durable receipt. Saved Drive/Auto files upload only at submission and are shared viewer-only with To/Cc (drive-upload grant); check first with draft preview --draft-id ID or JSONL draft.delivery-plan. Retry preparationStopped only when canRetryPreparation is true, with the same operationId." };
        if (eq(verb, "recovery-save")) return .{ .summary = "Retain unfinished compose fields in an unsendable local draft", .flags = "--draft-file FILE [--draft-id ID]", .fields = "draft.recoveryFields: exactly five raw strings (To/Cc/Bcc/Subject/Body), optional attachments; draftId?." };
        if (eq(verb, "list")) return .{ .summary = "List local drafts", .fields = "No command-specific fields. Result: drafts[]." };
        if (eq(verb, "restore")) return .{ .summary = "Restore the draft kept by the last discard with keepForUndo", .flags = "[--draft-id ID]", .fields = "draftId? must match the kept draft. One per account (the terminal UI discards this way), until the next such discard, at most 7 days; draft.list names it in discarded." };
        return .{ .summary = if (eq(verb, "read")) "Read a saved local draft" else if (eq(verb, "discard")) "Discard a local draft without changing mailbox mail" else "Open a saved draft in a private account-profile browser preview", .flags = "--draft-id ID", .fields = "draftId. open-preview launches a browser; discard removes only the local draft, and keepForUndo:true keeps it for draft.restore (one per account, at most 7 days)." };
    } else if (eq(mode, "queue")) {
        if (eq(verb, "list")) return .{ .summary = "List durable send intents and their states", .fields = "No command-specific fields." };
        if (eq(verb, "resume")) return .{ .summary = "Explicitly restart a staged send countdown", .flags = "--queue-id ID [--delay-seconds 0..30 (default 10)]", .fields = "queueId, delaySeconds?. No automatic submission after restart." };
        if (eq(verb, "process")) return .{ .summary = "Submit a due intent, optionally waiting for its deadline", .flags = "--queue-id ID [--wait]", .fields = "queueId, wait? (boolean). Unknown/submitting outcomes are never automatically retried." };
        if (eq(verb, "send-now")) return .{ .summary = "Submit the same reviewed intent immediately during its countdown", .flags = "--queue-id ID", .fields = "queueId. Skips the remaining delay; terminal outcomes never submit again." };
        return .{ .summary = if (eq(verb, "read")) "Inspect a durable send intent" else "Cancel the countdown while retaining its unsent draft", .flags = "--queue-id ID", .fields = "queueId." };
    } else if (eq(mode, "attachment")) {
        if (eq(verb, "import")) return .{ .summary = "Import a private file as an immutable account attachment handle", .flags = "--path FILE [--mime-type TYPE (default application/octet-stream)]", .fields = "path, mimeType?, delivery? (attach|auto|drive). Imported files are bounded by the account disk quota. Result includes blobId and the same delivery for use in draft attachments; importing never uploads." };
        if (eq(verb, "open")) return .{ .summary = "Explicitly open an already-saved file in a desktop viewer", .flags = "--path FILE", .fields = "path: absolute private regular file; supported extensions pdf/txt/md/csv/png/jpg/jpeg/gif/webp. This launches the configured desktop viewer." };
        return .{ .summary = "Discard an unreferenced account attachment handle", .flags = "--blob-id ID", .fields = "blobId. Referenced content cannot be discarded." };
    } else if (eq(mode, "contacts")) {
        if (eq(verb, "upsert")) return .{ .summary = "Create or update a contact with conflict detection", .flags = "--contact-file FILE (bare Contact JSON object) [--expected-etag ETAG]", .fields = "contact; edits require resourceName and expectedEtag or contact.etag. Omitted emails on name-only edits preserve existing addresses." };
        if (eq(verb, "list")) return .{ .summary = "List live or downloaded contacts", .flags = "--limit 1..100 (live default 100) --cursor CURSOR [--cached] [--query TEXT]", .fields = "query filters cached contacts; live list paginates through nextCursor." };
        return .{ .summary = "Search live or downloaded contacts", .flags = "--query TEXT [--cached]", .fields = "Live search requests 30 results and has no cursor/limit paging. Cached search filters the downloaded snapshot." };
    } else if (eq(mode, "labels")) {
        if (eq(verb, "list") or eq(verb, "palette")) return .{ .summary = if (eq(verb, "list")) "Read label definitions, or membership for selected messages" else "List Gmail's supported label colors", .flags = "[--cached (list)] [--message-ids ID,ID OR --message-id ID --scope message|conversation (list membership)]", .fields = "cacheOnly? (list); selected message targets invoke mail.label-state instead. palette needs no command-specific fields." };
        if (eq(verb, "create")) return .{ .summary = "Create a custom label definition", .flags = "--name NAME --operation-id ID [--background-color HEX --text-color HEX]", .fields = "name, operationId, color? {backgroundColor,textColor}." };
        if (eq(verb, "rename")) return .{ .summary = "Rename a custom label while preserving its ID and memberships", .flags = "--label-id ID --name NAME --operation-id ID [--background-color HEX --text-color HEX]", .fields = "labelId, name, operationId; paired color flags also change its colors." };
        if (eq(verb, "color")) return .{ .summary = "Set a custom label's Gmail-compatible colors", .flags = "--label-id ID --background-color HEX --text-color HEX --operation-id ID", .fields = "labelId, operationId, color {backgroundColor,textColor}. Use labels.palette for supported values." };
        return .{ .summary = "Delete a custom label definition, preserving its messages", .flags = "--label-id ID --confirm-name NAME --operation-id ID", .fields = "labelId, confirmName (exact current name), operationId. System labels are protected." };
    } else if (eq(mode, "invitations")) {
        if (eq(verb, "reply")) return .{ .summary = "Reply to an invitation and update Calendar", .flags = "--message-id ID --status accepted|tentative|declined --operation-id ID [--rsvp-only]", .fields = "messageId, status (accepted|tentative|declined), operationId. Accept/Tentative checks Calendar before sending; a known blocker returns outcome:blocked without sending. rsvpOnly:true explicitly sends just the RSVP. Decline is email-only. Inspect first; reconcile partial results without resending." };
        return .{ .summary = "Read invitation details or check an uncertain RSVP in Sent", .flags = "--message-id ID [--cached | --reconcile]", .fields = "messageId; cacheOnly? reads retained source without network; reconcile? checks positive Sent evidence without resending. Result includes organizer/attendee, startDisplay/endDisplay/durationDisplay, joinUrl, attendeeStatus, confirmedResponse and responseOutcome; a published event adds description, reminders and remindersKnown." };
    } else if (eq(mode, "operation")) {
        return .{ .summary = if (eq(verb, "read")) "Read one durable outcome and its recovery-draft reference" else "List durable outcomes of active operations", .flags = if (eq(verb, "read")) "--operation-id ID" else "", .fields = if (eq(verb, "read")) "operationId." else "No command-specific fields." };
    } else if (eq(mode, "calendar")) {
        if (eq(verb, "list")) return .{ .summary = "List calendars and effective read/write permissions", .fields = "Optional Calendar consent is required; see docs/CALENDAR-PERMISSIONS.md." };
        if (eq(verb, "agenda") or eq(verb, "freebusy")) return .{ .summary = if (eq(verb, "agenda")) "Read a bounded day or week with server-expanded recurring events" else "Read busy periods with the separate FreeBusy capability", .flags = "--calendar-id ID --date YYYY-MM-DD [--view day|week] [--time-zone IANA_ZONE]", .fields = "date is a civil date in timeZone or the selected calendar's timezone. Agenda snapshots remain explicitly stale after a failed refresh." };
        if (eq(verb, "event")) return .{ .summary = "Inspect one event in an explicit account and calendar", .flags = "--calendar-id ID --event-id ID", .fields = "calendarId, eventId. This does not change the event." };
        if (eq(verb, "open")) return .{ .summary = "Open Google Calendar in the correct account Chrome profile", .flags = "[--calendar-id ID] [--cached]", .fields = "Explicit profile launch; optional calendar selection. No event changes." };
        if (eq(verb, "event-open")) return .{ .summary = "Open this event in the correct account Chrome profile", .flags = "--calendar-id ID --event-id ID [--cached]", .fields = "Loads an exact bound event and validates its Calendar browser link before opening." };
        if (eq(verb, "meet-event-review")) return .{ .summary = "Review a new event with a Google Meet link and automatic AI notes + transcript. Reads only and saves a local review.", .flags = "--account EMAIL\n--calendar-id ID\n--event-file FILE        Required. A new event requesting \"conference\": \"google_meet\".\n--meet-ai-notes on       Required. Turns on AI notes and transcription.\n--send-updates all|none\n--operation-id ID        A new, unique ID for this operation.", .fields = "There are no transcript, recording, sharing or language options. To create an event without AI notes, use event-review; Google's defaults then apply. Edits, pasted meeting links and recurring events are refused. If the meet-settings permission is missing, the review is refused here (MeetSettingsPermissionRequired), before any Calendar write. Google checks API enablement, plan and admin policy only when the setting is sent after the event is saved. The Meet change names only the AI notes and transcription settings in its field mask, never a wildcard. Recording and all other Meet settings stay unchanged. Use the account's primary calendar from calendar list. The event file is a bare object with the event-review fields, for example {\"summary\":\"Project kickoff\",\"start\":\"2026-10-22T10:00\",\"end\":\"2026-10-22T10:45\",\"timeZone\":\"Europe/Vienna\",\"attendees\":[\"colleague@example.com\"],\"conference\":\"google_meet\"}. Guests require --send-updates all; meet-event-apply then creates the event and Google emails them." };
        if (eq(verb, "meet-event-apply")) return .{ .summary = "Confirm a reviewed operation exactly: create the event, then send the AI notes setting to its Meet link.", .flags = "--account EMAIL\n--calendar-id ID\n--operation-id ID   From meet-event-review.\n--review-hash HASH  From meet-event-review.", .fields = "Inspect state even when ok is true. applied: the event was created and Google's read-back shows AI notes and transcription on. partial: the event was saved but AI notes are not confirmed. rejected: Calendar refused the event and nothing was changed. unknown: the event save could not be confirmed. not_sent: no request reached Google. calendar.state is not_sent, applied, rejected or unknown. meetAiNotes.state is on, waiting_for_link, refused, unknown or not_sent. on is a dated observation of Google's read-back, not a guarantee that the setting stays on. refused is final and does not show the current setting. If meetAiNotes.state is waiting_for_link and meet-event-reconcile reports the link is ready, running meet-event-apply again with the same operation ID and review hash sends only the first Meet settings request. It never writes Calendar again. An unknown AI notes outcome is never resent." };
        if (eq(verb, "meet-event-reconcile")) return .{ .summary = "Check a saved operation using Google reads only.", .flags = "--account EMAIL\n--calendar-id ID\n--operation-id ID\n--review-hash HASH", .fields = "Sends only Google GET requests and updates the local journal. It never writes Calendar, never changes Meet settings and never emails guests. It reports the same states as meet-event-apply. on is reported only when Google's read-back matches both settings. Otherwise an unknown outcome stays unknown; this release has no retry." };
        if (eq(verb, "meet-event-pending")) return .{ .summary = "Show the saved operation for a calendar or event without contacting Google.", .flags = "--account EMAIL\n--calendar-id ID\n--event-id ID   Optional; for an existing event.", .fields = "Reads the local journal only. Recorded states are what Omagma last observed, not Google's current settings." };
        if (eq(verb, "event-review")) return .{ .summary = "Review an ordinary event creation or conditional edit without writing", .flags = "--calendar-id ID --event-file FILE --send-updates none|all --operation-id ID\n  Editing also requires --event-id ID --expected-etag ETAG", .fields = "event-file is a bare object: summary,start,end,timeZone,allDay?,description?,location?,attendees?,conference?,joinUrl?,startOffset?,endOffset?. Local time YYYY-MM-DDTHH:MM[:SS[.mmm]]; all-day YYYY-MM-DD with exclusive end. conference none|google_meet|link. New guests require send-updates all. Missing attendees preserve existing guests. Inspect returned reviewHash and resolved times before event-apply." };
        if (eq(verb, "event-delete-review")) return .{ .summary = "Review deleting an existing event or its whole series; saves the exact conditional delete without changing Calendar", .flags = "--calendar-id ID --event-id ID --expected-etag ETAG --scope event|series --send-updates none|all --operation-id ID [--dry-run]", .fields = "Read the event first (calendar event, or this command with --dry-run, which needs no ETag and saves nothing) and pass its etag. scope event deletes this event or one occurrence; series deletes every event of the series (this-and-following is not supported). --send-updates all emails guests a cancellation and is only accepted for an event this calendar organizes that has guests; an attendee copy is removed from this calendar only (decline instead to tell the organizer). Inspect role, guestCount and consequence, then event-apply with the returned operation ID and review hash. No undo." };
        if (eq(verb, "event-respond-review")) return .{ .summary = "Review accepting, Maybe or declining an invitation in Calendar; saves the exact conditional response without sending it", .flags = "--calendar-id ID --event-id ID --expected-etag ETAG --scope event|series --response accepted|tentative|declined --send-updates none|all --operation-id ID [--dry-run]", .fields = "Only this calendar's own attendee response changes. --send-updates all asks Google to email your answer to the organizer; none sends no email. Refused for events this calendar organizes, attendee lists Google omitted, another person's calendar, private copies (use invitations reply) and an unchanged answer. A --dry-run without --response shows previousResponse. Then event-apply with the returned operation ID and review hash." };
        if (eq(verb, "event-pending")) return .{ .summary = "Resume a saved uncertain Calendar write by operation ID, or the one blocking an event", .flags = "--calendar-id ID [--operation-id ID | --event-id ID [--series-event-id SERIES] | --series-event-id SERIES]", .fields = "--operation-id opens exactly that write (a CalendarOperationPending refusal names it as blockingOperationId). --event-id finds the write to that event or its whole series (for a series ID, to one of its occurrences), then one to another occurrence (relation series). Series membership is the provider's recurringEventId: pass --series-event-id (\"\" when the event does not repeat), else the event is read once; seriesChecked:false says that read failed. --series-event-id alone finds the writes on that series (the series, a whole-series write or one to any occurrence); \"\" needs --event-id. Omit all for a pending creation. Returns pending:null or the complete saved review (action create_event, update_event, delete_event or respond_event), relation, attempt and nextAttempt; an invitation's own update is reported as blockedBy with its operationId and reviewHash: event-reconcile checks it, event-abandon stops tracking it. Local only unless the event must be read." };
        if (eq(verb, "event-retry")) return .{ .summary = "Explicitly retry the identical saved uncertain request with duplicate protection", .flags = "--calendar-id ID --operation-id ID --review-hash HASH --next-attempt INTEGER", .fields = "Reconcile first and inspect retryPossible. Use the returned nextAttempt once after explicit confirmation. The exact request, deterministic event ID, Meet request ID and edit If-Match remain fixed; replaying that attempt token cannot send again. No automatic retry. A Calendar 404 or unchanged ETag still means uncertainty, never proof that nothing was sent." };
        if (eq(verb, "event-abandon")) return .{ .summary = "Explicitly archive an uncertain outcome locally without claiming it was unsent", .flags = "--calendar-id ID --operation-id ID --review-hash HASH", .fields = "Returns archived and releases the pending-operation guard. A create or edit may still appear in Calendar; a delete or response may already be applied. No provider read or write; cannot reapply this saved form. Requires explicit user confirmation." };
        if (eq(verb, "event-apply") or eq(verb, "event-reconcile")) return .{ .summary = if (eq(verb, "event-apply")) "Apply an exact saved event review (create, edit, delete or response) once" else "Read the exact event to resolve an uncertain write without sending again", .flags = if (eq(verb, "event-apply")) "--calendar-id ID --operation-id ID --review-hash HASH [--dry-run]" else "--calendar-id ID --operation-id ID --review-hash HASH", .fields = "Use the exact event-review, event-delete-review or event-respond-review ID/hash. Inspect applied/rejected/unknown state (exit 0/3/6). --dry-run repeats apply's fresh checks and reports wouldSend without sending. An unknown outcome must be reconciled. When retryPossible, only the explicit identical-request event-retry is permitted; never invent a new operation ID for that uncertainty." };

        if (eq(verb, "invitation-plan") or eq(verb, "review")) return .{ .summary = if (eq(verb, "review")) "Freeze the exact Calendar change for a received invitation or .ics event and return its review hash. Writes nothing." else "Preview what a received invitation or .ics event would do in a calendar. Read-only: shows the decision, resolved times and reminders.", .flags = "--calendar-id ID --message-id ID\n  review also requires --operation-id UNIQUE_ID\n  Timezone review: --start-time-zone IANA_ZONE --end-time-zone IANA_ZONE\n  --accept-floating-time | --reinterpret-embedded-timezones (explicit choice only)", .fields = "An .ics event without attendees (METHOD:PUBLISH or no METHOD) becomes your own event on the account's primary calendar: no guests are added and no RSVP is sent. Run `calendar review` first, then `calendar import` with the exact hash it returned. Source comes from the account's received message. Review returns an operationId and reviewHash; no calendar write occurs. Ambiguous local times require resolution." };
        return .{ .summary = if (eq(verb, "reconcile")) "Check a previously uncertain calendar action without replaying it" else if (eq(verb, "cancel")) "Apply a reviewed invitation cancellation" else if (eq(verb, "update")) "Apply a reviewed invitation update" else if (eq(verb, "import")) "Add a reviewed invitation or .ics event to Google Calendar. Requires the exact review hash; sends no email." else "Apply the exact previously reviewed invitation action once", .flags = "--calendar-id ID --operation-id ID --review-hash HASH", .fields = "Use the ID and hash returned by calendar review. Outcomes survive restart; unknown outcomes must be reconciled, never blindly resent. Import/update/cancel must match the stored action." };
    } else if (eq(mode, "cache")) {
        return .{ .summary = if (eq(verb, "clear")) "Clear retained mail while keeping drafts, contacts and operations" else if (eq(verb, "stats")) "Inspect local cache limits, residency and counters" else if (eq(verb, "activity")) "Read the local Inbox arrival serial and last sync time" else "Check whether another client is refreshing this account", .fields = "No command-specific fields. These operations do not fetch mail." };
    } else if (eq(mode, "terminal-auth")) {
        if (eq(verb, "authorize")) return .{ .summary = "Authorize explicitly requested terminal capabilities through Google consent", .flags = "--capabilities CSV (complete capability set; mail-read is required) [--client-file FILE]\n  Mail: mail-read,mail-drafts,mail-send,mail-modify\n  Contacts: contacts-read,contacts-write\n  Invitations: calendar-rsvp (response email)\n  Calendar: calendar-read,calendar-write-owned,calendar-write-shared,calendar-freebusy\n  Drive: drive-upload (only files Omagma uploads)\n  Meet: meet-settings (optional settings permission for automatic AI notes)", .fields = "clientFile: an explicit --client-file wins; otherwise the client of this account's current terminal grant, else the configured oauthClientFile. Request the complete desired set, retaining every capability the account already has (for Drive, add drive-upload to the current list). Opens Google consent in this account's Chrome profile. Calendar is optional; see docs/CALENDAR-PERMISSIONS.md. See setup instructions for credential-store selection." };
        if (eq(verb, "status")) return .{ .summary = "Inspect locally configured grants, credential-store selection and Google's last sign-in refusal", .fields = "No command-specific fields. lastRefreshError is null or Google's sanitized reason for refusing the recorded terminal grant (kind reauthenticationRequired, expiredOrRevoked or invalidGrant), cleared by its next verified refresh; reconnect with Ctrl+O in the TUI or auth.authorize reconnect:true." };
        return .{ .summary = "Revoke this account's local terminal grant and selected-store credential", .fields = "No command-specific fields. Local revoke is not Google's account-wide revocation." };
    } else if (eq(mode, "updates")) {
        return .{ .summary = if (eq(verb, "automatic")) "Enable or disable automatic daily TUI release checks" else if (eq(verb, "check")) "Fetch official stable release metadata" else if (eq(verb, "guide")) "Show instructions for this installation; never installs files" else if (eq(verb, "dismiss")) "Dismiss the available-version notice" else "Read cached release metadata", .flags = if (eq(verb, "automatic")) "on|off [--json]" else "[--json]", .fields = "Standalone command: no JSONL account operation, account config or OAuth required." };
    }
    unreachable; // Every validated verb has contextual help.
}
fn reference(writer: anytype) !void {
    try writer.writeAll("\nComplete offline JSONL discovery:\n  omagma cli --help commands\n  omagma cli --help COMMAND\n  omagma cli --schema COMMAND\n  omagma cli --help-all\nAdditional documentation:\n  https://github.com/technologylab-ai/omagma/blob/main/docs/AGENT-CLI.md\n");
}
pub fn command(io: std.Io, mode: []const u8, verb: []const u8) !void {
    if (!knownVerb(mode, verb)) return error.UnknownCommand;
    const details = spec(mode, verb);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("Experimental terminal mail · {s} {s}\n{s}\n\nUsage: omagma {s} {s}{s} [OPTIONS]\n", .{ mode, verb, details.summary, mode, verb, if (eq(mode, "updates")) @as([]const u8, "") else " --account ADDRESS" });
    if (details.flags.len > 0) try writer.interface.print("\nOptions:\n  {s}\n", .{details.flags});
    if (!eq(mode, "updates")) {
        try writer.interface.writeAll("\nShared options: --config FILE --grant-file FILE --cache-dir DIR --fixtures\n");
        if (details.json_cmd orelse jsonAlias(mode, verb)) |alias| try writer.interface.print("\nJSONL cmd: {s}\n", .{alias}) else try writer.interface.print("\nJSONL cmd: {s}.{s}\n", .{ jsonFamily(mode), verb });
        try writer.interface.writeAll("Every request also needs account; id is optional and echoed in its reply.\n");
    }
    try writer.interface.print("{s}\n", .{details.fields});
    if (!eq(mode, "updates")) try writer.interface.writeAll("One-shot replies are JSON on stdout; diagnostics use stderr. --json is optional.\n");
    try writer.interface.print("\nShell example (replace the fictional address, paths and returned IDs):\n  omagma {s} {s}{s}{s}\n", .{ mode, verb, if (eq(mode, "updates")) @as([]const u8, "") else " --account personal@example.com", shellArguments(mode, verb) });
    try writer.interface.print("\nUse omagma {s} {s} --help-all for shared defaults, advanced options and structured inputs.\n", .{ mode, verb });
    if (details.example) |example| try writer.interface.print("\nExample JSONL request (replace the fictional address and returned IDs):\n{s}\n", .{example});
    try reference(&writer.interface);
    try writer.interface.flush();
}
pub fn protocol(io: std.Io, a: std.mem.Allocator, target: ?[]const u8) !void {
    if (target) |cmd| return @import("cli_api.zig").help(io, a, cmd);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        \\Experimental terminal mail · JSONL CLI for agents
        \\
        \\Usage: omagma cli|agent [--config FILE] [--grant-file FILE] [--cache-dir DIR]
        \\Send one JSON object per stdin line; receive one JSON reply per stdout line.
        \\The process stays open for more requests and exits on EOF. Diagnostics use stderr.
        \\
        \\1. Discover configured accounts and capabilities:
        \\   printf '%s\n' '{"id":"accounts","cmd":"accounts.list"}' | omagma cli
        \\
        \\2. Use a returned enabled account address in your next requests:
        \\{"id":"inbox","cmd":"mail.list","account":"personal@example.com","label":"INBOX","limit":5}
        \\{"id":"read","cmd":"mail.read","account":"personal@example.com","messageId":"RETURNED_MESSAGE_ID"}
        \\   Replace the fictional address and message ID with values from the replies.
        \\
        \\Replies: {"version":1,"id":...,"ok":true,"account":...,"data":...}
        \\Errors:  {"version":1,"id":...,"ok":false,"account":...,"error":{"code":...,"message":...}}
        \\Check ok on every reply; CLI exit status alone does not establish request success.
        \\Except accounts.list, every request requires account (omagma cli --account A fills
        \\it in for lines without one). id is optional and echoed. Unknown fields are rejected
        \\(UnknownField with didYouMean) and nothing runs.
        \\Use cacheOnly:true to forbid fetching. Default reads allow provider access and may reuse cached bodies.
        \\Lean reads: view:"summary" on lists, body:"text" on mail.read, fields:[...] projection
        \\(reads only; writes and dry runs always return their complete result).
        \\Sending requires a stable operationId; review with dryRun:true first and never
        \\automatically retry UnknownOutcome.
        \\
        \\3. Discover only the details you need:
        \\   omagma cli --help commands         Every supported JSONL cmd
        \\   omagma cli --help mail             Commands in one namespace
        \\   omagma cli --help mail.read        Compact card: fields, types, defaults, example
        \\   omagma cli --schema mail.read      Machine-readable request schema (--compact)
        \\   omagma cli --manifest              Compact JSON index of every command
        \\   omagma cli --help-options          Shared process paths, fixtures and resource limits
        \\   omagma cli --help-all              Complete offline JSONL reference
        \\Use --fixtures with a private --cache-dir for a disconnected demonstration.
        \\
    );
    try @import("cli_api.zig").list(&writer.interface, a, null, true);
    try reference(&writer.interface);
    try writer.interface.flush();
}
