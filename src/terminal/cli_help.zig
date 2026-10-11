//! Contextual, credential-free help. Command families also drive argv validation.
const std = @import("std");
const Family = struct { name: []const u8, summary: []const u8, verbs: []const []const u8 };
const families = [_]Family{
    .{ .name = "mail", .summary = "Read, search, reply, forward and organize mail", .verbs = &.{ "list", "search", "read", "thread", "attachment", "attachment-save", "open", "sync", "refresh", "recipients", "reply", "forward", "send", "archive", "trash", "restore", "spam", "unspam", "mark", "batch", "undo", "triage-scope", "label-state", "prefetch", "drafts", "compose", "labels", "identities", "open-link", "open-attachment" } },
    .{ .name = "draft", .summary = "Create, review and send local drafts", .verbs = &.{ "list", "read", "create", "update", "preview", "open-preview", "recovery-save", "send", "queue", "discard" } },
    .{ .name = "queue", .summary = "Inspect, cancel or submit a staged send", .verbs = &.{ "list", "read", "cancel", "resume", "process", "send-now" } },
    .{ .name = "attachment", .summary = "Import, discard or open private attachment handles", .verbs = &.{ "import", "discard", "open" } },
    .{ .name = "contacts", .summary = "Read, search and update the address book", .verbs = &.{ "list", "search", "upsert" } },
    .{ .name = "labels", .summary = "Manage custom label definitions and colors", .verbs = &.{ "list", "create", "rename", "delete", "color", "palette" } },
    .{ .name = "invitations", .summary = "Inspect invitations or send an RSVP", .verbs = &.{ "inspect", "reply" } },
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
    try writer.interface.writeAll("  tui                 Interactive mail client\n  cli | agent         JSONL requests on stdin, replies on stdout\n");
    for (families) |f| try writer.interface.print("  {s:<19} {s}\n", .{ f.name, f.summary });
    try writer.interface.writeAll("  credentials         Inspect or migrate keyring/file storage\n  daemon | auth | status  Read-only Gmail bar and its authorization\n  version | --version Show the installed version\n\nStart with omagma cli --help for agent examples.\nUse omagma mail --help to choose an operation, then omagma mail read --help.\nUse omagma --help-all for the extended command overview.\n");
    try writer.interface.flush();
}
pub fn family(io: std.Io, mode: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    if (eq(mode, "tui")) {
        try writer.interface.writeAll("Experimental terminal mail · TUI\n\nUsage: omagma tui [--account ADDRESS] [--config FILE] [--grant-file FILE]\n                  [--cache-dir DIR] [--ui-file FILE] [--no-mouse]\n                  [--editor-mode auto|takeover] [--fixtures]\n\nPress ? in the TUI for searchable keyboard and mouse help.\nUse omagma cli --help for automation; omagma --help for other commands.\n");
    } else {
        var found = false;
        for (families) |f| if (eq(mode, f.name)) {
            found = true;
            try writer.interface.print("Experimental terminal mail · {s}\n{s}\n\nUsage: omagma {s} OPERATION [OPTIONS]\n\nOperations:\n", .{ mode, f.summary, mode });
            for (f.verbs) |verb| try writer.interface.print("  {s:<17} {s}\n", .{ verb, spec(mode, verb).summary });
            try writer.interface.print("\nUse omagma {s} OPERATION --help for fields and examples.\nUse omagma cli --help for the JSONL protocol.\n", .{mode});
        };
        if (!found) return error.UnknownCommand;
    }
    try writer.interface.flush();
}
const Spec = struct { summary: []const u8, flags: []const u8 = "", fields: []const u8 = "", example: ?[]const u8 = null, json_cmd: ?[]const u8 = null };
fn spec(mode: []const u8, verb: []const u8) Spec {
    if (eq(mode, "mail")) {
        if (eq(verb, "compose")) return spec("draft", "create");
        if (eq(verb, "drafts")) return spec("draft", "list");
        if (eq(verb, "labels")) return spec("labels", "list");
        if (eq(verb, "open-attachment")) return spec("attachment", "open");
        if (eq(verb, "list")) return .{ .summary = "List a bounded message page", .flags = "--label LABEL --query QUERY --limit 1..100 --cursor CURSOR --cached", .fields = "label?, query?, limit? (1..100), cursor?, cacheOnly? (boolean). Result: messages[], nextCursor.", .example = "{\"id\":\"inbox\",\"cmd\":\"mail.list\",\"account\":\"personal@example.com\",\"label\":\"INBOX\",\"limit\":5}" };
        if (eq(verb, "sync")) return .{ .summary = "List a provider message page; this is not a history refresh", .flags = "--label LABEL --query QUERY --limit 1..100 --cursor CURSOR", .fields = "label?, query?, limit? (1..100), cursor?. For downloaded mail use mail.list with cacheOnly:true; history refresh uses mail.refresh." };
        if (eq(verb, "search")) return .{ .summary = "Search downloaded mail or Gmail", .flags = "--query QUERY [--cached | --server] --limit 1..100 --cursor CURSOR", .fields = "query, limit?, cursor?, cacheOnly? (true: local, false/default: Gmail). Local search supports a subset of Gmail syntax.", .example = "{\"id\":\"search\",\"cmd\":\"mail.search\",\"account\":\"personal@example.com\",\"query\":\"is:unread\",\"limit\":5}" };
        if (eq(verb, "read")) return .{ .summary = "Read a full message, labels, attachments and invitation details", .flags = "--message-id ID [--cached]", .fields = "messageId, cacheOnly? (boolean). Result includes bodyText and attachments. Reading does not mark mail read.", .example = "{\"id\":\"read\",\"cmd\":\"mail.read\",\"account\":\"personal@example.com\",\"messageId\":\"RETURNED_MESSAGE_ID\"}" };
        if (eq(verb, "thread")) return .{ .summary = "Read a conversation in chronological order", .flags = "--thread-id ID [--cached]", .fields = "threadId, cacheOnly? (boolean). Result: messages[]. Cached conversations can be partial." };
        if (eq(verb, "attachment")) return .{ .summary = "Retrieve received attachment bytes or a private handle", .flags = "--message-id ID --attachment-id ID", .fields = "messageId, attachmentId. Result: filename/mimeType/size and data (base64url), or blobId for larger content." };
        if (eq(verb, "attachment-save")) return .{ .summary = "Stream a received attachment to a new private file", .flags = "--message-id ID --attachment-id ID --path NEW_ABSOLUTE_FILE", .fields = "messageId, attachmentId, path. Saving refuses overwrite and symlink traversal." };
        if (eq(verb, "reply") or eq(verb, "forward")) return .{ .summary = "Create a local reply, reply-all or unaddressed forward draft", .flags = "--message-id ID [--reply-all (reply)] [--format plain|markdown]\n  --preserve-formatting keeps original HTML/images inline\n  --original forwards as .eml (forward only; conflicts with --preserve-formatting)", .fields = "messageId, all? (reply-all), bodyFormat? (plain|markdown), preserveFormatting?; forward also accepts original?. Result is a local draft; this does not send mail." };
        if (eq(verb, "send")) return .{ .summary = "Submit a reviewed message with a stable operation identity", .flags = "--to ADDRESSES --subject TEXT (--body-file FILE | --body-stdin | --body TEXT)\n  --format plain|markdown --from ADDRESS --cc ADDRESSES --bcc ADDRESSES\n  --attach-file FILE (repeatable) --operation-id ID [--send-delay 0..30]", .fields = "draft (subject, bodyText, optional bodyFormat/from/attachments), operationId. Recipients: address-list strings or arrays of {address,name}. Direct send has no delay unless --send-delay is supplied. Result is a durable receipt; never automatically retry UnknownOutcome." };
        if (eq(verb, "spam") or eq(verb, "unspam")) return .{ .summary = "Move a message or reviewed conversation into/out of Spam", .flags = "--message-id ID [--scope message|conversation]", .json_cmd = "mail.batch", .fields = "messageIds (array), action (spam|unspam). For a conversation, first resolve mail.triage-scope and pass its exact IDs to mail.batch." };
        if (eq(verb, "archive") or eq(verb, "trash") or eq(verb, "restore")) return .{ .summary = "Change reversible mailbox labels", .flags = "--message-id ID [--scope message|conversation]", .fields = "messageId. JSONL conversation actions require mail.triage-scope followed by mail.batch with the resolved messageIds; direct scope does not expand targets." };
        if (eq(verb, "mark")) return .{ .summary = "Set read/star state or add/remove labels", .flags = "--message-id ID [--unread | --read] [--starred | --unstarred]\n  --add-label LABEL --remove-label LABEL [--scope message|conversation]", .fields = "messageId, unread?, starred? (booleans), addLabels?, removeLabels? (arrays). For a conversation, resolve mail.triage-scope then use mail.batch with action:mark." };
        if (eq(verb, "batch")) return .{ .summary = "Apply an action to explicit targets and receive per-message outcomes", .flags = "--message-ids ID,ID --action archive|trash|restore|spam|unspam|mark\n  --unread|--read --starred|--unstarred --add-label LABEL --remove-label LABEL", .fields = "messageIds (1..100 distinct IDs), action, optional unread/starred/addLabels/removeLabels. Result includes per-ID outcomes and undoToken." };
        if (eq(verb, "undo")) return .{ .summary = "Undo confirmed label changes from a batch", .flags = "--undo-token TOKEN [--message-ids ID,ID]", .fields = "undoToken, messageIds?. Only confirmed successful items are restored." };
        if (eq(verb, "triage-scope")) return .{ .summary = "Resolve the exact message/conversation targets before changing them", .flags = "--message-id ID --scope message|conversation", .fields = "messageId, scope. Result includes messageIds/count/threadId; incomplete or oversized conversations are refused." };
        if (eq(verb, "label-state")) return .{ .summary = "Inspect mixed/applied label membership across messages", .flags = "--message-ids ID,ID", .fields = "messageIds. Result includes per-label appliedCount and mixed state." };
        if (eq(verb, "identities")) return .{ .summary = "List verified Gmail send-as identities", .flags = "[--cached]", .fields = "cacheOnly?. Result: identities with address, name, signature and isDefault." };
        if (eq(verb, "recipients")) return .{ .summary = "List recent account-scoped recipient suggestions", .flags = "--cached", .fields = "cacheOnly:true. Suggestions combine downloaded contacts and retained mail, excluding the primary account." };
        if (eq(verb, "refresh")) return .{ .summary = "Refresh the bounded cache from Gmail history or recent mail", .flags = "--label LABEL --query QUERY --limit N --prefetch-bodies 0..64", .fields = "limit?, query?, label?, prefetchLimit? (0..64). Existing cache quotas remain in force." };
        if (eq(verb, "prefetch")) return .{ .summary = "Download a bounded recent message/body head", .flags = "--limit 0..64", .fields = "limit? (0..64). Updates the private account cache." };
        if (eq(verb, "open") or eq(verb, "open-link")) return .{ .summary = "Explicitly open Gmail or a URL in this account's Chrome profile", .flags = "[--message-id ID (open)] --url URL (open-link)", .fields = "messageId? (mail.open); url (browser.open). This launches a browser." };
    } else if (eq(mode, "draft")) {
        if (eq(verb, "create") or eq(verb, "update")) return .{ .summary = "Save a local draft without sending", .flags = "[--draft-id ID (update)] --to ADDRESSES --cc ADDRESSES --bcc ADDRESSES\n  --subject TEXT (--body-file FILE | --body-stdin | --body TEXT)\n  --format plain|markdown --from ADDRESS --attach-file FILE (repeatable)\n  --draft-file FILE supplies a structured draft", .fields = "draft (subject, bodyText, optional bodyFormat/from/attachments); update also requires draftId. Recipients: address-list strings or arrays of {address,name}. Update replaces editable fields: read and submit the complete draft rather than a partial patch." };
        if (eq(verb, "preview")) return .{ .summary = "Render a local draft without saving or sending", .flags = "--draft-id ID OR (--body-file FILE | --body-stdin | --body TEXT)\n  --format plain|markdown [--browser (saved draft only)]", .fields = "draftId or draft. Result: exact bodyText source, plainText, optional bodyHtml and bodyFormat.", .example = "{\"id\":\"preview\",\"cmd\":\"draft.preview\",\"account\":\"personal@example.com\",\"draft\":{\"bodyText\":\"**Hello**\",\"bodyFormat\":\"markdown\"}}" };
        if (eq(verb, "send") or eq(verb, "queue")) return .{ .summary = "Submit or stage a reviewed saved draft", .flags = "--draft-id ID --operation-id ID\n  --send-delay 0..30 (send) OR --delay-seconds 0..30 (queue, default 10)", .fields = "draftId, operationId; queue also accepts delaySeconds (0..30). Queue returns queueId/dueAtMs/state and requires explicit processing. Direct send has no delay unless --send-delay is supplied; send returns a durable receipt." };
        if (eq(verb, "recovery-save")) return .{ .summary = "Retain unfinished compose fields in an unsendable local draft", .flags = "--draft-file FILE [--draft-id ID]", .fields = "draft.recoveryFields: exactly five raw strings (To/Cc/Bcc/Subject/Body), optional attachments; draftId?." };
        if (eq(verb, "list")) return .{ .summary = "List local drafts", .fields = "No command-specific fields. Result: drafts[]." };
        return .{ .summary = "Read, discard or open a saved local draft preview", .flags = "--draft-id ID", .fields = "draftId. open-preview launches a private browser preview; discard removes only the local draft." };
    } else if (eq(mode, "queue")) {
        if (eq(verb, "list")) return .{ .summary = "List durable send intents and their states", .fields = "No command-specific fields." };
        if (eq(verb, "resume")) return .{ .summary = "Explicitly restart a staged send countdown", .flags = "--queue-id ID [--delay-seconds 0..30]", .fields = "queueId, delaySeconds?. No automatic submission after restart." };
        if (eq(verb, "process")) return .{ .summary = "Submit a due intent, optionally waiting for its deadline", .flags = "--queue-id ID [--wait]", .fields = "queueId, wait? (boolean). Unknown/submitting outcomes are never automatically retried." };
        if (eq(verb, "send-now")) return .{ .summary = "Submit the same reviewed intent immediately during its countdown", .flags = "--queue-id ID", .fields = "queueId. Skips the remaining delay; terminal outcomes never submit again." };
        return .{ .summary = "Inspect an intent or cancel it while retaining the unsent draft", .flags = "--queue-id ID", .fields = "queueId." };
    } else if (eq(mode, "attachment")) {
        if (eq(verb, "import")) return .{ .summary = "Import a private file as an immutable account attachment handle", .flags = "--path FILE [--mime-type TYPE]", .fields = "path, mimeType?. Result includes blobId for use in draft attachments." };
        if (eq(verb, "open")) return .{ .summary = "Explicitly open an already-saved file in a desktop viewer", .flags = "--path FILE", .fields = "path. This launches the configured desktop viewer." };
        return .{ .summary = "Discard an unreferenced account attachment handle", .flags = "--blob-id ID", .fields = "blobId. Referenced content cannot be discarded." };
    } else if (eq(mode, "contacts")) {
        if (eq(verb, "upsert")) return .{ .summary = "Create or update a contact with conflict detection", .flags = "--contact-file FILE [--expected-etag ETAG]", .fields = "contact; edits require resourceName and expectedEtag or contact.etag. Omitted emails on name-only edits preserve existing addresses." };
        return .{ .summary = "List/search live contacts or downloaded contacts", .flags = "[--query TEXT (search)] [--limit 1..100 (list)] [--cursor CURSOR] [--cached]", .fields = "query (search), limit? (list 1..100; live search max 30), cursor?, cacheOnly?. Result: contacts[], live nextCursor." };
    } else if (eq(mode, "labels")) {
        if (eq(verb, "list") or eq(verb, "palette")) return .{ .summary = "Read label definitions or Gmail's supported color palette", .flags = "[--cached (list)]", .fields = "cacheOnly? (list); palette needs no command-specific fields." };
        if (eq(verb, "create")) return .{ .summary = "Create a custom label definition", .flags = "--name NAME --operation-id ID [--background-color HEX --text-color HEX]", .fields = "name, operationId, color? {backgroundColor,textColor}." };
        if (eq(verb, "rename")) return .{ .summary = "Rename a custom label while preserving its ID and memberships", .flags = "--label-id ID --name NAME --operation-id ID", .fields = "labelId, name, operationId." };
        if (eq(verb, "color")) return .{ .summary = "Set a custom label's Gmail-compatible colors", .flags = "--label-id ID --background-color HEX --text-color HEX --operation-id ID", .fields = "labelId, operationId, color {backgroundColor,textColor}. Use labels.palette for supported values." };
        return .{ .summary = "Delete a custom label definition, preserving its messages", .flags = "--label-id ID --confirm-name NAME --operation-id ID", .fields = "labelId, confirmName (exact current name), operationId. System labels are protected." };
    } else if (eq(mode, "invitations")) {
        if (eq(verb, "reply")) return .{ .summary = "Send an invitation RSVP email", .flags = "--message-id ID --status accepted|tentative|declined --operation-id ID", .fields = "messageId, status (accepted|tentative|declined), operationId. Inspect first; this sends an RSVP email, not a Google Calendar update." };
        return .{ .summary = "Read validated invitation identities, times and joining details", .flags = "--message-id ID", .fields = "messageId. Result includes organizer/attendee, startDisplay/endDisplay/durationDisplay, joinUrl and attendeeStatus." };
    } else if (eq(mode, "operation")) {
        return .{ .summary = "Inspect durable outcomes and recovery-draft references", .flags = if (eq(verb, "read")) "--operation-id ID" else "", .fields = if (eq(verb, "read")) "operationId." else "No command-specific fields." };
    } else if (eq(mode, "cache")) {
        return .{ .summary = if (eq(verb, "clear")) "Clear retained mail while keeping drafts, contacts and operations" else "Inspect local cache limits, arrival activity or refresh state", .fields = "No command-specific fields. These operations do not fetch mail." };
    } else if (eq(mode, "terminal-auth")) {
        if (eq(verb, "authorize")) return .{ .summary = "Authorize explicitly requested terminal capabilities through Google consent", .flags = "--client-file FILE --capabilities mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp", .fields = "clientFile, capabilities (array); opens Google consent in this account's Chrome profile. See setup instructions for credential-store selection." };
        return .{ .summary = if (eq(verb, "status")) "Inspect locally configured grants and credential-store selection" else "Revoke this account's local terminal grant and selected-store credential", .fields = "No command-specific fields. Local revoke is not Google's account-wide revocation." };
    } else if (eq(mode, "updates")) {
        return .{ .summary = if (eq(verb, "automatic")) "Enable or disable automatic daily TUI release checks" else if (eq(verb, "check")) "Fetch official stable release metadata" else if (eq(verb, "guide")) "Show instructions for this installation; never installs files" else if (eq(verb, "dismiss")) "Dismiss the available-version notice" else "Read cached release metadata", .flags = if (eq(verb, "automatic")) "on|off [--json]" else "[--json]", .fields = "Standalone command: no JSONL account operation, account config or OAuth required." };
    }
    unreachable; // Every validated verb has contextual help.
}
fn reference(writer: anytype) !void {
    try writer.writeAll("\nFull command fields and examples:\n  https://github.com/technologylab-ai/omagma/blob/main/docs/AGENT-CLI.md\n");
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
    if (details.example) |example| try writer.interface.print("\nExample JSONL request (replace the fictional address and returned IDs):\n{s}\n", .{example});
    try reference(&writer.interface);
    try writer.interface.flush();
}
pub fn protocol(io: std.Io, target: ?[]const u8) !void {
    if (target) |cmd| {
        if (eq(cmd, "accounts.list")) {
            var buffer: [1024]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            try writer.interface.writeAll("Experimental terminal mail · accounts.list\nDiscover configured account addresses, enabled state and local capabilities.\n\nJSONL request:\n{\"id\":\"accounts\",\"cmd\":\"accounts.list\"}\n\nNo account field is required. Result: data.accounts[].\nConfigured capabilities are checked again before provider access.\n");
            try writer.interface.flush();
            return;
        }
        if (eq(cmd, "accounts.identities")) return command(io, "mail", "identities");
        if (eq(cmd, "browser.open")) return command(io, "mail", "open-link");
        const dot = std.mem.indexOfScalar(u8, cmd, '.') orelse return error.UnknownCommand;
        const namespace = cmd[0..dot];
        const mode = if (eq(namespace, "invitation")) "invitations" else if (eq(namespace, "auth")) "terminal-auth" else namespace;
        const verb = cmd[dot + 1 ..];
        if (eq(mode, "updates") or jsonAlias(mode, verb) != null) return error.UnknownCommand;
        if (!knownVerb(mode, verb) or spec(mode, verb).json_cmd != null) return error.UnknownCommand;
        return command(io, mode, verb);
    }
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
        \\Except accounts.list, every request requires account. id is optional and echoed.
        \\Use cacheOnly:true to forbid fetching. Default reads allow provider access and may reuse cached bodies.
        \\Sending requires a stable operationId; never automatically retry UnknownOutcome.
        \\
        \\3. Discover only the details you need:
        \\   omagma mail --help                 Choose a mail operation
        \\   omagma mail read --help            Flags, JSON fields and an example
        \\   omagma cli --help mail.read        The same operation by its JSONL name
        \\   omagma --help                      Other command families
        \\   omagma --help-all                  Extended command overview
        \\Use --fixtures with a private --cache-dir for a disconnected demonstration.
        \\
    );
    try reference(&writer.interface);
    try writer.interface.flush();
}
