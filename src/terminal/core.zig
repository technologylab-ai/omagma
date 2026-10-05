const std = @import("std");
const t = @import("types.zig");
const j = @import("json.zig");
const recipients = @import("recipients.zig");
const invitation = @import("invitation.zig");
const storage = @import("store.zig");
const Config = @import("../config.zig").Config;
const Value = std.json.Value;

pub const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: t.Options,
    config: Config,
    cache_root: []const u8,
    env: *const std.process.Environ.Map,
    meter: ?*@import("capped_allocator.zig").CappedAllocator = null,
    pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, options: t.Options) !Session {
        var s: Session = .{ .io = io, .allocator = a, .options = options, .config = undefined, .cache_root = undefined, .env = env };
        const home = env.get("HOME") orelse return error.HomeRequired;
        try s.config.defaults(home);
        if (options.fixtures) for (s.config.accounts[0..s.config.count]) |*account| {
            account.enabled = true;
        };
        var parse_arena = std.heap.ArenaAllocator.init(a);
        defer parse_arena.deinit();
        const pa = parse_arena.allocator();
        const cfg = options.config_file orelse if (!options.fixtures) try std.fmt.allocPrint(pa, "{s}/omagma/config.json", .{env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(pa, "{s}/.config", .{home})}) else null;
        if (cfg) |path| {
            const buf = try pa.alloc(u8, 16 * 1024);
            try s.config.load(io, path, pa, buf);
        }
        s.cache_root = try a.dupe(u8, options.cache_dir orelse try std.fmt.allocPrint(pa, "{s}/omagma/terminal", .{env.get("XDG_CACHE_HOME") orelse try std.fmt.allocPrint(pa, "{s}/.cache", .{home})}));
        if (options.metadata_limit == 0 or options.metadata_limit > t.Limits.metadata_hard or options.disk_limit < 64 * 1024 or options.disk_limit > t.Limits.disk_hard) return error.InvalidCacheLimit;
        if (!std.mem.eql(u8, options.fixture_scenario, "normal") and !options.fixtures) return error.FixtureOptionRequiresFixtures;
        if (options.fixture_root != null and !options.fixtures) return error.FixtureOptionRequiresFixtures;
        if (options.fixtures and std.mem.indexOfScalar(u8, options.fixture_scenario, '/') != null) return error.InvalidFixtureScenario;
        return s;
    }
    pub fn deinit(s: *Session) void {
        s.allocator.free(s.cache_root);
    }
    pub fn client(s: *Session) t.Client {
        return .{ .ctx = s, .callFn = call };
    }
    fn call(ctx: *anyopaque, out_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const s: *Session = @ptrCast(@alignCast(ctx));
        return s.execute(out_allocator, raw);
    }
    pub fn execute(s: *Session, out_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(s.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const request = if (raw.len > t.Limits.request_bytes or !boundedJson(raw)) null else std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always, .max_value_len = t.Limits.request_bytes }) catch null;
        if (request == null or request.? != .object) return failure(out_allocator, .null, "", "InvalidRequest", "Expected a bounded JSON object");
        var req = request.?;
        const account = j.text(req, "account");
        const id = j.get(req, "id") orelse .null;
        for ([_][]const u8{ "cmd", "account", "cursor", "query", "label", "messageId", "threadId", "draftId", "operationId", "status", "expectedEtag", "grantFile", "clientFile", "preparedCalendar" }) |key| if (j.get(req, key)) |field| {
            if (field != .string) return failure(out_allocator, id, account, "InvalidRequest", "Expected string command fields");
        };
        if (!s.options.fixtures and j.get(req, "grantFile") == null) try req.object.put(a, "grantFile", .{ .string = s.options.grant_file orelse try std.fmt.allocPrint(a, "{s}/omagma/terminal-grants.json", .{s.env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{s.env.get("HOME") orelse return error.HomeRequired})}) });
        if ((id != .null and id != .string and id != .integer) or (id == .string and id.string.len > 256)) return failure(out_allocator, .null, account, "InvalidRequest", "id must be a bounded string or integer");
        const data = s.dispatch(a, req) catch |err| return failureForError(out_allocator, id, account, err);
        return successResponse(out_allocator, id, account, j.text(req, "cmd"), s.options.fixtures, data);
    }
    fn failure(a: std.mem.Allocator, id: Value, account: []const u8, code: []const u8, message: []const u8) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .id = id, .ok = false, .account = account, .@"error" = .{ .code = code, .message = message } }, .{});
    }
    fn failureForError(a: std.mem.Allocator, id: Value, account: []const u8, err: anyerror) ![]const u8 {
        return failure(a, id, account, @errorName(err), errorMessage(err)) catch |encoding_error| {
            // A failed error frame must not replace the warning that a remote
            // mutation may already have happened, including at CLI exit.
            if (err == error.UnknownOutcome) return error.UnknownOutcome;
            return encoding_error;
        };
    }
    fn successResponse(a: std.mem.Allocator, id: Value, account: []const u8, cmd: []const u8, fixtures: bool, data: Value) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .id = id, .ok = true, .account = account, .data = data }, .{}) catch |err| {
            if (!fixtures) for ([_][]const u8{ "contacts.upsert", "mail.mark", "mail.archive", "mail.trash", "mail.restore", "mail.send", "draft.send", "invitation.reply" }) |mutation| {
                if (std.mem.eql(u8, cmd, mutation)) return failureForError(a, id, account, error.UnknownOutcome);
            };
            return err;
        };
    }
    fn errorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.PermissionDenied => "This account lacks the required capability; authorize terminal access separately",
            error.UnknownAccount => "Choose an explicitly configured account",
            error.UnknownOutcome => "Outcome is unknown; do not automatically retry",
            error.OperationConflict => "This operation identity was already used for different content",
            error.CacheBusy => "Another client is using this account cache; retry later",
            else => @errorName(err),
        };
    }
    fn dispatch(s: *Session, a: std.mem.Allocator, req: Value) !Value {
        const cmd = try j.required(req, "cmd");
        if (std.mem.eql(u8, cmd, "accounts.list")) {
            const Account = struct { address: []const u8, enabled: bool, capabilities: []const []const u8 };
            var list: std.ArrayList(Account) = .empty;
            const registry = if (!s.options.fixtures) try @import("auth.zig").load(s.io, a, try j.required(req, "grantFile")) else @import("auth.zig").Registry{};
            for (s.config.accounts[0..s.config.count]) |*account| {
                const grant = @import("auth.zig").find(&registry, account.address.slice());
                try list.append(a, .{ .address = account.address.slice(), .enabled = account.enabled, .capabilities = if (s.options.fixtures and !s.scenario("readonly")) &.{ "mail-read", "mail-modify", "mail-send", "contacts-read", "contacts-write", "calendar-rsvp" } else if (grant) |g| if (g.enabled) g.capabilities else &.{} else &.{"mail-read"} });
            }
            return j.value(a, .{ .accounts = list.items });
        }
        const address = try j.required(req, "account");
        const index = s.config.index(address) orelse return error.UnknownAccount;
        if (!s.config.accounts[index].enabled) return error.AccountDisabled;
        try recipients.validateAddress(address);
        if (std.mem.startsWith(u8, cmd, "auth.")) {
            if (s.options.fixtures) {
                if (!std.mem.eql(u8, cmd, "auth.status")) return error.FixtureOnly;
                return j.value(a, .{ .configured = true, .fixture = true });
            }
            return @import("auth.zig").run(s.io, a, &s.config, s.env, req);
        }
        var store = try storage.Store.open(s.io, a, s.cache_root, address, s.options);
        defer store.close();
        if (std.mem.eql(u8, cmd, "cache.stats")) {
            const meter = if (s.meter) |m| m.snapshot() else null;
            return j.value(a, .{ .metadataEntries = store.state.entries.len, .metadataLimit = s.options.metadata_limit, .diskBytes = try store.diskBytes(), .diskLimitBytes = s.options.disk_limit, .bodyLimitBytes = t.Limits.body_bytes, .runtimeReservationBytes = t.Limits.runtime_bytes, .terminalHeapLimitBytes = t.Limits.runtime_bytes, .fixedBackendReservationBytes = @import("../limits.zig").app_reservation, .allocatorUsedBytes = if (meter) |m| m.allocatorUsedBytes else null, .allocatorPeakBytes = if (meter) |m| m.allocatorPeakBytes else null, .rejectedAllocations = if (meter) |m| m.rejectedAllocations else null, .fixtureCalls = store.state.fixtureCalls, .fixtureSends = store.state.fixtureSends, .generation = store.state.generation });
        }
        if (std.mem.eql(u8, cmd, "cache.clear")) {
            try store.clearMail();
            return j.value(a, .{ .cleared = true, .draftsPreserved = true, .operationsPreserved = true });
        }
        if (std.mem.eql(u8, cmd, "operation.list")) return j.value(a, .{ .operations = store.state.operations });
        if (std.mem.eql(u8, cmd, "operation.read")) {
            const operation_id = try j.required(req, "operationId");
            for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, operation_id)) return j.value(a, operation);
            return error.OperationNotFound;
        }
        if (std.mem.eql(u8, cmd, "draft.list")) return j.value(a, .{ .drafts = store.state.drafts });
        if (std.mem.eql(u8, cmd, "draft.read")) return j.value(a, try store.draft(try j.required(req, "draftId")));
        if (std.mem.eql(u8, cmd, "draft.discard")) {
            try store.discardDraft(try j.required(req, "draftId"));
            return j.value(a, .{ .discarded = true });
        }
        if (std.mem.eql(u8, cmd, "draft.create") or std.mem.eql(u8, cmd, "draft.update")) {
            const draft = try decodeDraft(a, j.get(req, "draft") orelse return error.MissingField);
            try validateDraft(draft, false);
            return j.value(a, try store.putDraft(draft, if (std.mem.eql(u8, cmd, "draft.update")) try j.required(req, "draftId") else null));
        }
        if (std.mem.eql(u8, cmd, "mail.send") or std.mem.eql(u8, cmd, "draft.send")) {
            const draft = if (std.mem.eql(u8, cmd, "draft.send")) try store.draft(try j.required(req, "draftId")) else try decodeDraft(a, j.get(req, "draft") orelse return error.MissingField);
            return s.send(a, &store, req, draft, null);
        }
        if (std.mem.eql(u8, cmd, "mail.reply")) {
            const message = try s.read(a, &store, try j.required(req, "messageId"), req);
            const threading = try @import("mime.zig").threading(message.messageId, message.references, message.inReplyTo, a);
            var envelope: recipients.Envelope = .{};
            const aliases = if (!s.options.fixtures) try j.decode([]const []const u8, a, j.get(try s.remote(a, address, "accounts.aliases", req), "aliases") orelse return error.InvalidProviderResponse) else &.{};
            try recipients.reply(address, aliases, try addressHeader(a, &.{message.from}), try addressHeader(a, message.replyTo), try addressHeader(a, message.to), try addressHeader(a, message.cc), try j.boolean(req, "all", false), &envelope);
            const d: t.Draft = .{ .to = try listAddresses(a, &envelope.to), .cc = try listAddresses(a, &envelope.cc), .subject = if (std.ascii.startsWithIgnoreCase(message.subject, "Re:")) message.subject else try std.fmt.allocPrint(a, "Re: {s}", .{message.subject}), .bodyText = try quote(a, message.bodyText), .threadId = message.threadId, .inReplyTo = threading.in_reply_to, .references = threading.references };
            try validateDraft(d, false);
            return j.value(a, try store.putDraft(d, null));
        }
        if (std.mem.eql(u8, cmd, "mail.list") or std.mem.eql(u8, cmd, "mail.search") or std.mem.eql(u8, cmd, "mail.sync")) return s.listMail(a, &store, req);
        if (std.mem.eql(u8, cmd, "mail.read")) return j.value(a, try s.read(a, &store, try j.required(req, "messageId"), req));
        if (std.mem.eql(u8, cmd, "mail.open")) {
            const id = j.text(req, "messageId");
            var message: @import("../model.zig").Message = .{};
            if (id.len > 0) {
                try s.capability(a, address, req, "mail-read");
                const m = if (store.find(id)) |cached| cached.message else try s.read(a, &store, id, req);
                try message.thread_id.set(m.threadId);
                try message.message_id.set(m.messageId);
            }
            const target = try @import("../open_target.zig").make(&s.config.accounts[index], if (id.len > 0) &message else null, false);
            if (!s.options.fixtures) try @import("../open_target.zig").launch(s.io, &s.config, &s.config.accounts[index], &target);
            return j.value(a, .{ .opened = !s.options.fixtures, .fixture = s.options.fixtures, .url = target.url.slice(), .profile = target.profile_arg.slice() });
        }
        if (std.mem.eql(u8, cmd, "mail.thread")) {
            try s.capability(a, address, req, "mail-read");
            if (!s.options.fixtures) {
                const result = try s.remote(a, address, cmd, req);
                for (try array(result, "messages")) |v| try store.put(try j.decode(t.Message, a, v), true);
                try store.save();
                return result;
            }
            const thread = try j.required(req, "threadId");
            const source = try s.fixture(a, address);
            var messages: std.ArrayList(t.Message) = .empty;
            for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "threadId"), thread)) {
                var m = try s.normalize(a, source, v);
                if (store.find(m.id)) |existing| {
                    m.labels = existing.message.labels;
                    m.unread = existing.message.unread;
                }
                try store.put(m, true);
                try messages.append(a, m);
            };
            for (store.state.outbox) |entry| if (std.mem.eql(u8, entry.threadId, thread)) {
                if (try store.readOutbox(entry.id)) |sent| try messages.append(a, sent);
            };
            if (messages.items.len == 0) return error.MessageNotFound;
            std.mem.sort(t.Message, messages.items, {}, olderFirst);
            try store.save();
            return j.value(a, .{ .messages = messages.items });
        }
        if (std.mem.eql(u8, cmd, "mail.attachment")) {
            if (!s.options.fixtures) {
                try s.capability(a, address, req, "mail-read");
                return s.remote(a, address, cmd, req);
            }
            const m = try s.read(a, &store, try j.required(req, "messageId"), req);
            const id = try j.required(req, "attachmentId");
            for (m.attachments) |attachment| if (std.mem.eql(u8, attachment.id, id)) return j.value(a, attachment);
            return error.AttachmentNotFound;
        }
        if (std.mem.eql(u8, cmd, "mail.archive") or std.mem.eql(u8, cmd, "mail.trash") or std.mem.eql(u8, cmd, "mail.restore") or std.mem.eql(u8, cmd, "mail.mark")) {
            try s.capability(a, address, req, "mail-modify");
            if (!s.options.fixtures) {
                const id = try j.required(req, "messageId");
                // Discard cached state before dispatch, including uncertain outcomes.
                try store.invalidate(id);
                store.state.generation += 1;
                try store.save();
                return s.remote(a, address, cmd, req);
            }
            if (s.scenario("rejected-mutation")) return error.ProviderRejected;
            var m = try s.read(a, &store, try j.required(req, "messageId"), req);
            var labels: std.ArrayList([]const u8) = .empty;
            try labels.appendSlice(a, m.labels);
            if (std.mem.eql(u8, cmd, "mail.archive")) removeLabel(&labels, "INBOX");
            if (std.mem.eql(u8, cmd, "mail.trash")) {
                removeLabel(&labels, "INBOX");
                try addLabel(a, &labels, "TRASH");
            }
            if (std.mem.eql(u8, cmd, "mail.restore")) {
                removeLabel(&labels, "TRASH");
                try addLabel(a, &labels, "INBOX");
            }
            if (j.get(req, "unread")) |_| {
                if (try j.boolean(req, "unread", false)) try addLabel(a, &labels, "UNREAD") else removeLabel(&labels, "UNREAD");
            }
            if (j.get(req, "starred")) |_| {
                if (try j.boolean(req, "starred", false)) try addLabel(a, &labels, "STARRED") else removeLabel(&labels, "STARRED");
            }
            if (j.get(req, "addLabels")) |v| for (try valueArray(v)) |label| {
                const text = try j.string(label);
                try recipients.validateHeader(text);
                try addLabel(a, &labels, text);
            };
            if (j.get(req, "removeLabels")) |v| for (try valueArray(v)) |label| removeLabel(&labels, try j.string(label));
            m.labels = labels.items;
            m.unread = hasLabel(m, "UNREAD");
            store.state.fixtureCalls += 1;
            store.state.generation += 1;
            // Labels do not change the immutable body. Retain its existing
            // residency/hash without allocating an atomic second body copy.
            if (!store.updateOutboxMetadata(m)) try store.put(m, false);
            try store.save();
            return j.value(a, m);
        }
        if (std.mem.eql(u8, cmd, "contacts.list") or std.mem.eql(u8, cmd, "contacts.search") or std.mem.eql(u8, cmd, "contacts.upsert")) return s.contacts(a, &store, req, cmd);
        if (std.mem.eql(u8, cmd, "invitation.reply") or std.mem.eql(u8, cmd, "invitation.inspect")) {
            try s.capability(a, address, req, if (std.mem.eql(u8, cmd, "invitation.inspect")) "mail-read" else "calendar-rsvp");
            const m = try s.read(a, &store, try j.required(req, "messageId"), req);
            const ics = m.invitation orelse return error.NotInvitation;
            var invite: invitation.Invitation = .{};
            const aliases = if (!s.options.fixtures) try j.decode([]const []const u8, a, j.get(try s.remote(a, address, "accounts.aliases", req), "aliases") orelse return error.InvalidProviderResponse) else &.{};
            try invitation.parse(ics, address, aliases, &invite);
            if (std.mem.eql(u8, cmd, "invitation.inspect")) return j.value(a, .{ .uid = invite.uid.slice(), .organizer = invite.organizer.slice(), .attendee = invite.attendee.slice(), .sequence = invite.sequence, .recurrenceId = invite.recurrence_id.slice(), .summary = invite.summary.slice(), .start = invite.start.slice() });
            const status = std.meta.stringToEnum(invitation.Status, try j.required(req, "status")) orelse return error.InvalidInvitationStatus;
            const buf = try a.alloc(u8, invitation.max_calendar_bytes);
            const reply = try invitation.reply(&invite, status, try utcStamp(s.io, a), buf);
            const d: t.Draft = .{ .to = &.{.{ .address = invite.organizer.slice() }}, .subject = try std.fmt.allocPrint(a, "{s}: {s}", .{ @tagName(status), m.subject }), .bodyText = try std.fmt.allocPrint(a, "Invitation response: {s}", .{@tagName(status)}) };
            return s.send(a, &store, req, d, reply);
        }
        return error.UnsupportedCommand;
    }
    fn scenario(s: *Session, name: []const u8) bool {
        return std.mem.eql(u8, s.options.fixture_scenario, name);
    }
    fn capability(s: *Session, a: std.mem.Allocator, address: []const u8, req: Value, name: []const u8) !void {
        if (s.options.fixtures) {
            if (s.scenario("readonly") and !std.mem.eql(u8, name, "mail-read")) return error.PermissionDenied;
            return;
        }
        const registry = try @import("auth.zig").load(s.io, a, try j.required(req, "grantFile"));
        if (@import("auth.zig").find(&registry, address)) |grant| {
            if (!grant.permits(name)) return error.PermissionDenied;
        } else if (!std.mem.eql(u8, name, "mail-read")) return error.PermissionDenied;
    }
    fn remote(s: *Session, a: std.mem.Allocator, address: []const u8, cmd: []const u8, req: Value) !Value {
        return @import("../platform.zig").deadline(s.io, @import("../platform.zig").seconds(30), @import("gmail.zig").execute, .{ s.io, a, &s.config, address, cmd, req });
    }
    fn fixture(s: *Session, a: std.mem.Allocator, address: []const u8) !Value {
        if (!s.options.fixtures) return error.LiveProviderNotReady;
        if (s.options.fixture_root) |root| {
            const key = if (std.mem.eql(u8, address, "personal@example.com")) "personal" else if (std.mem.eql(u8, address, "work@example.com")) "work" else if (std.mem.eql(u8, address, "optional@example.com")) "optional" else return error.FixtureAccountRequired;
            const path = try std.fmt.allocPrint(a, "{s}/accounts/{s}.json", .{ root, key });
            const raw = try std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(16 * 1024 * 1024));
            const source = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always, .max_value_len = t.Limits.request_bytes });
            if (!std.mem.eql(u8, j.text(source, "account"), address)) return error.FixtureIdentityMismatch;
            return source;
        }
        // Complete fictional fixtures are shipped in development. Built-in
        // fixtures keep installed bundles useful without a tests directory.
        var messages: std.ArrayList(Value) = .empty;
        var i: usize = 96;
        while (i > 0) : (i -= 1) {
            const id = try std.fmt.allocPrint(a, "demo-{d}", .{i});
            const body = try std.fmt.allocPrint(a, "Hello from {s}!\n\nA complete synthetic message, with café and emoji 🌋.\n", .{address});
            const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(body.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, body);
            const account_key = storage.Store.hash(address);
            var payload = try j.value(a, .{ .mimeType = "text/plain", .headers = .{ .{ .name = "From", .value = "Alex Fixture <alex@example.org>" }, .{ .name = "To", .value = address }, .{ .name = "Subject", .value = try std.fmt.allocPrint(a, "{s}: synthetic thread {d} 🌋", .{ address, (i - 1) / 3 }) }, .{ .name = "Message-ID", .value = try std.fmt.allocPrint(a, "<demo-{d}-{s}@example.org>", .{ i, account_key[0..12] }) } }, .body = .{ .size = body.len, .data = encoded } });
            if (i == 3 or i == 8) {
                var parts: j.Value = .{ .array = .init(a) };
                try parts.array.append(payload);
                const content = if (i == 3) "Synthetic attachment: flowing magma 🌋\n" else try std.fmt.allocPrint(a, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//omagma//Synthetic//EN\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:demo-magma-meeting@example.org\r\nSEQUENCE:2\r\nDTSTAMP:20261004T120000Z\r\nDTSTART:20261107T100000Z\r\nSUMMARY:Demo magma meeting 🌋\r\nORGANIZER:mailto:organizer@example.org\r\nATTENDEE;RSVP=TRUE:mailto:{s}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", .{address});
                const data = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(content.len));
                _ = std.base64.url_safe_no_pad.Encoder.encode(data, content);
                try parts.array.append(try j.value(a, .{ .partId = "demo-part-1", .mimeType = if (i == 3) "text/plain" else "text/calendar", .filename = if (i == 3) "demo-magma.txt" else "", .body = .{ .size = content.len, .data = data } }));
                const headers = j.get(payload, "headers").?;
                payload = try j.value(a, .{ .mimeType = "multipart/mixed", .headers = headers, .parts = parts });
            }
            try messages.append(a, try j.value(a, .{ .id = id, .threadId = try std.fmt.allocPrint(a, "demo-thread-{d}", .{(i - 1) / 3}), .internalDate = try std.fmt.allocPrint(a, "{d}", .{1791100800000 + i * 60000}), .labelIds = [_][]const u8{ "INBOX", "UNREAD" }, .snippet = body, .payload = payload }));
        }
        return j.value(a, .{ .account = address, .messages = messages.items });
    }
    fn normalize(_: *Session, a: std.mem.Allocator, source: Value, v: Value) !t.Message {
        return @import("gmail_decode.zig").normalize(v, a, j.get(source, "externalBodies"));
    }
    fn read(s: *Session, a: std.mem.Allocator, store: *storage.Store, id: []const u8, req: Value) !t.Message {
        try s.capability(a, store.state.account, req, "mail-read");
        if (s.options.fixtures) if (try store.readOutbox(id)) |sent| return sent;
        if (try store.read(id)) |cached| {
            var m = cached;
            if (store.find(id)) |entry| {
                m.labels = entry.message.labels;
                m.unread = entry.message.unread;
            }
            return m;
        }
        if (!s.options.fixtures) {
            const m = try j.decode(t.Message, a, try s.remote(a, store.state.account, "mail.read", req));
            try store.put(m, true);
            try store.save();
            return m;
        }
        const source = try s.fixture(a, store.state.account);
        for (try array(source, "messages")) |v| if (std.mem.eql(u8, j.text(v, "id"), id)) {
            var m = try s.normalize(a, source, v);
            if (store.find(id)) |existing| {
                m.labels = existing.message.labels;
                m.unread = existing.message.unread;
            }
            store.state.fixtureCalls += 1;
            try store.put(m, true);
            try store.save();
            return m;
        };
        return error.MessageNotFound;
    }
    fn listMail(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        try s.capability(a, store.state.account, req, "mail-read");
        if (!s.options.fixtures) return s.liveList(a, store, req);
        const limit = try j.integer(req, "limit", 30);
        if (limit < 1 or limit > t.Limits.page) return error.InvalidPageLimit;
        const query = j.text(req, "query");
        const label = j.text(req, "label");
        if (query.len > 4096 or label.len > 256) return error.InvalidQuery;
        const filter = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ store.state.account, query, label });
        const key = storage.Store.hash(filter);
        const cursor = j.text(req, "cursor");
        var offset: usize = 0;
        if (cursor.len > 0) {
            var parts = std.mem.splitScalar(u8, cursor, ':');
            const version = parts.next() orelse return error.InvalidCursor;
            const generation = parts.next() orelse return error.InvalidCursor;
            const position = parts.next() orelse return error.InvalidCursor;
            const digest = parts.next() orelse return error.InvalidCursor;
            if (!std.mem.eql(u8, version, "1") or parts.next() != null or !std.mem.eql(u8, digest, &key) or (std.fmt.parseInt(u64, generation, 10) catch return error.InvalidCursor) != store.state.generation) return error.InvalidCursor;
            offset = std.fmt.parseInt(usize, position, 10) catch return error.InvalidCursor;
        }
        const source = try s.fixture(a, store.state.account);
        var messages: std.ArrayList(t.Message) = .empty;
        var matched: usize = 0;
        var next: bool = false;
        var candidates: std.ArrayList(t.Message) = .empty;
        for (try array(source, "messages")) |v| {
            var m = try s.normalize(a, source, v);
            if (store.find(m.id)) |e| {
                m.labels = e.message.labels;
                m.unread = e.message.unread;
            }
            try candidates.append(a, m);
        }
        try candidates.appendSlice(a, store.state.outbox);
        std.mem.sort(t.Message, candidates.items, {}, newerFirst);
        for (candidates.items) |message| {
            var m = message;
            if (label.len > 0 and !hasLabel(m, label)) continue;
            if (label.len == 0 and query.len == 0 and hasLabel(m, "TRASH")) continue;
            if (query.len > 0 and !matches(m, query)) continue;
            matched += 1;
            if (matched <= offset) continue;
            if (messages.items.len == limit) {
                next = true;
                break;
            }
            try store.put(m, false);
            m.bodyText = "";
            m.bodyHtml = null;
            m.invitation = null;
            m.attachments = &.{};
            try messages.append(a, m);
        }
        if (offset > matched) return error.InvalidCursor;
        store.state.fixtureCalls += 1;
        try store.save();
        return j.value(a, .{ .messages = messages.items, .nextCursor = if (next) try std.fmt.allocPrint(a, "1:{d}:{d}:{s}", .{ store.state.generation, offset + messages.items.len, key }) else @as(?[]const u8, null) });
    }
    fn liveList(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value) !Value {
        const query = j.text(req, "query");
        const label = j.text(req, "label");
        const filter = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ store.state.account, query, label });
        const key = storage.Store.hash(filter);
        var request = req;
        const cursor = j.text(req, "cursor");
        if (cursor.len > 0) {
            var parts = std.mem.splitScalar(u8, cursor, ':');
            const version = parts.next() orelse return error.InvalidCursor;
            const generation = parts.next() orelse return error.InvalidCursor;
            const digest = parts.next() orelse return error.InvalidCursor;
            const payload = parts.next() orelse return error.InvalidCursor;
            if (!std.mem.eql(u8, version, "L") or parts.next() != null or !std.mem.eql(u8, digest, &key) or (std.fmt.parseInt(u64, generation, 10) catch return error.InvalidCursor) != store.state.generation) return error.InvalidCursor;
            const n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return error.InvalidCursor;
            if (n > 4096) return error.InvalidCursor;
            const decoded = try a.alloc(u8, n);
            std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return error.InvalidCursor;
            try request.object.put(a, "cursor", .{ .string = decoded });
        }
        var result = try s.remote(a, store.state.account, try j.required(req, "cmd"), request);
        for (try array(result, "messages")) |v| try store.put(try j.decode(t.Message, a, v), false);
        const remote_cursor = j.text(result, "nextCursor");
        if (remote_cursor.len > 0) {
            if (remote_cursor.len > 4096) return error.InvalidCursor;
            const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(remote_cursor.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, remote_cursor);
            try result.object.put(a, "nextCursor", .{ .string = try std.fmt.allocPrint(a, "L:{d}:{s}:{s}", .{ store.state.generation, key, encoded }) });
        }
        try store.save();
        return result;
    }
    fn contacts(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, cmd: []const u8) !Value {
        const write = std.mem.eql(u8, cmd, "contacts.upsert");
        try s.capability(a, store.state.account, req, if (write) "contacts-write" else "contacts-read");
        if (!s.options.fixtures) {
            if (write) {
                store.state.contacts = &.{};
                try store.save();
            }
            const result = try s.remote(a, store.state.account, cmd, req);
            // Provider writes already validate the contact receipt. Return it
            // directly; refresh the invalidated cache on the next contacts read
            // rather than risking a cache failure after a successful create.
            if (write) return result;
            store.state.contacts = try j.decode([]t.Contact, a, j.get(result, "contacts") orelse return error.InvalidProviderResponse);
            try store.save();
            return result;
        }
        if (store.state.contacts.len == 0) {
            if (s.options.fixture_root) |root| {
                const key = if (std.mem.eql(u8, store.state.account, "personal@example.com")) "personal" else if (std.mem.eql(u8, store.state.account, "work@example.com")) "work" else "optional";
                const raw = try std.Io.Dir.cwd().readFileAlloc(s.io, try std.fmt.allocPrint(a, "{s}/contacts/{s}.json", .{ root, key }), a, .limited(4 * 1024 * 1024));
                const source = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
                var list: std.ArrayList(t.Contact) = .empty;
                for (try array(source, "connections")) |v| {
                    const names = try array(v, "names");
                    var addresses: std.ArrayList(t.Address) = .empty;
                    for (try array(v, "emailAddresses")) |email| try addresses.append(a, .{ .address = j.text(email, "value") });
                    const metadata = j.get(v, "metadata") orelse .null;
                    const sources = try array(metadata, "sources");
                    try list.append(a, .{ .resourceName = j.text(v, "resourceName"), .etag = if (sources.len > 0) j.text(sources[0], "etag") else j.text(v, "etag"), .name = if (names.len > 0) j.text(names[0], "displayName") else "", .emails = addresses.items });
                }
                store.state.contacts = list.items;
            } else store.state.contacts = try a.dupe(t.Contact, &.{.{ .resourceName = "people/demo-alex", .etag = "demo-1", .name = "Alex Fixture", .emails = &.{.{ .address = "alex@example.org" }} }});
            store.state.fixtureCalls += 1;
            try store.save();
        }
        if (!write) {
            const query = j.text(req, "query");
            var contacts_list: std.ArrayList(t.Contact) = .empty;
            for (store.state.contacts) |contact| {
                var match = query.len == 0 or containsIgnoreCase(contact.name, query);
                for (contact.emails) |email| match = match or containsIgnoreCase(email.address, query);
                if (match) try contacts_list.append(a, contact);
            }
            return j.value(a, .{ .contacts = contacts_list.items });
        }
        if (s.scenario("rejected-mutation")) return error.ProviderRejected;
        const v = j.get(req, "contact") orelse return error.MissingField;
        for ([_][]const u8{ "resourceName", "etag", "name" }) |key| if (j.get(v, key)) |field| {
            if (field != .string) return error.InvalidRequest;
        };
        var c: t.Contact = .{ .resourceName = j.text(v, "resourceName"), .etag = j.text(v, "etag"), .name = j.text(v, "name"), .emails = try decodeAddresses(a, j.get(v, "emails") orelse return error.MissingField) };
        try recipients.validateHeader(c.name);
        if (c.name.len > 256 or c.emails.len == 0) return error.InvalidContact;
        var pos: ?usize = null;
        for (store.state.contacts, 0..) |old, i| if (std.mem.eql(u8, old.resourceName, c.resourceName)) {
            pos = i;
            break;
        };
        if (pos) |i| {
            const expected = j.text(req, "expectedEtag");
            if (!std.mem.eql(u8, if (expected.len > 0) expected else c.etag, store.state.contacts[i].etag)) return error.ContactConflict;
        } else {
            if (c.resourceName.len > 0) return error.ContactNotFound;
            if (store.state.contacts.len == 1024) return error.ContactLimitExceeded;
            c.resourceName = try store.nextId("people/contact");
        }
        c.etag = try store.nextId("contact-version");
        if (pos) |i| store.state.contacts[i] = c else {
            var list: std.ArrayList(t.Contact) = .empty;
            try list.appendSlice(a, store.state.contacts);
            try list.append(a, c);
            store.state.contacts = list.items;
        }
        store.state.fixtureCalls += 1;
        try store.save();
        return j.value(a, c);
    }
    fn send(s: *Session, a: std.mem.Allocator, store: *storage.Store, req: Value, draft: t.Draft, calendar: ?[]const u8) !Value {
        try s.capability(a, store.state.account, req, if (calendar != null) "calendar-rsvp" else "mail-send");
        try validateDraft(draft, true);
        const operation_id = try j.required(req, "operationId");
        if (operation_id.len > 256) return error.InvalidOperationId;
        try recipients.validateHeader(operation_id);
        var canonical = draft;
        canonical.id = "";
        const payload = try std.json.Stringify.valueAlloc(a, .{ .draft = canonical, .calendar = if (calendar) |ics| try calendarIdentity(a, ics) else null }, .{});
        const digest = storage.Store.hash(payload);
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.id, operation_id)) {
            if (!std.mem.eql(u8, operation.hash, &digest)) return error.OperationConflict;
            return j.value(a, operation);
        };
        for (store.state.operations) |operation| if (std.mem.eql(u8, operation.outcome, "unknown") and (std.mem.eql(u8, operation.hash, &digest) or (draft.id.len > 0 and std.mem.eql(u8, operation.draftId, draft.id)))) return j.value(a, operation);
        if (store.state.operations.len == 1000) return error.OperationJournalFull;
        // Persist uncertainty before dispatch, including on process failure.
        var operations: std.ArrayList(storage.Operation) = .empty;
        try operations.appendSlice(a, store.state.operations);
        const wire_identity = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ store.state.account, operation_id });
        const wire_hash = storage.Store.hash(wire_identity);
        if (s.options.fixtures) {
            var from: recipients.Mailbox = .{};
            try from.address.set(store.state.account);
            var envelope: recipients.Envelope = .{};
            const lists = [_][]const t.Address{ draft.to, draft.cc, draft.bcc };
            const targets = [_]*recipients.List{ &envelope.to, &envelope.cc, &envelope.bcc };
            for (lists, targets) |addresses, target| for (addresses) |address| {
                var mailbox: recipients.Mailbox = .{};
                try mailbox.address.set(address.address);
                try mailbox.name.set(address.name);
                try target.append(mailbox);
            };
            const mime = @import("mime.zig");
            const wire = try a.alloc(u8, mime.max_raw_bytes);
            _ = try mime.encode(.{ .from = from, .envelope = &envelope, .subject = draft.subject, .body = draft.bodyText, .calendar = calendar, .message_id = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{wire_hash}), .date = "Mon, 05 Oct 2026 12:00:00 +0000", .in_reply_to = draft.inReplyTo, .references = draft.references, .attachments = try mime.composeAttachments(draft.attachments, a) }, wire);
        }
        // Keep direct-send content as a recoverable draft before uncertainty is recorded.
        const saved_draft = if (std.mem.eql(u8, j.text(req, "cmd"), "draft.send")) draft else try store.putDraft(draft, null);
        try operations.append(a, .{ .id = operation_id, .hash = try a.dupe(u8, &digest), .draftId = saved_draft.id, .rfcMessageId = try std.fmt.allocPrint(a, "<omagma-{s}@mail.invalid>", .{wire_hash}), .icalendar = calendar orelse "" });
        store.state.operations = operations.items;
        try store.save();
        const operation = &store.state.operations[store.state.operations.len - 1];
        if (!s.options.fixtures) {
            var request = req;
            try request.object.put(a, "draft", try j.value(a, draft));
            if (calendar) |ics| try request.object.put(a, "preparedCalendar", .{ .string = ics });
            const result = s.remote(a, store.state.account, if (calendar != null) "invitation.reply" else "mail.send", request) catch |err| {
                operation.errorCode = @errorName(err);
                operation.outcome = switch (err) {
                    error.FormTooLarge, error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.OAuthClientRequired, error.WrongAccount, error.InvalidGrant, error.UnexpectedScope, error.GrantClientMismatch, error.MessageNotFound, error.ContactConflict, error.RateLimited => "rejected",
                    else => "unknown",
                };
                store.save() catch {
                    operation.outcome = "unknown";
                };
                return j.value(a, operation.*);
            };
            const outcome = j.text(result, "outcome");
            operation.outcome = if (std.mem.eql(u8, outcome, "applied")) "applied" else if (std.mem.eql(u8, outcome, "rejected")) "rejected" else "unknown";
            operation.messageId = j.text(result, "messageId");
            operation.errorCode = j.text(result, "errorCode");
            store.save() catch {
                operation.outcome = "unknown";
            };
            return j.value(a, operation.*);
        }
        store.state.fixtureCalls += 1;
        if (s.scenario("rejected-mutation")) operation.outcome = "rejected" else if (s.scenario("unknown-send")) operation.outcome = "unknown" else {
            store.state.fixtureSends += 1;
            operation.messageId = try store.nextId("sent");
            operation.outcome = if (s.scenario("applied-lost")) "unknown" else "applied";
            const sent: t.Message = .{ .id = operation.messageId, .threadId = if (draft.threadId.len > 0) draft.threadId else operation.messageId, .from = .{ .address = store.state.account }, .to = draft.to, .cc = draft.cc, .subject = draft.subject, .snippet = utf8Prefix(draft.bodyText, 240), .bodyText = draft.bodyText, .messageId = operation.rfcMessageId, .inReplyTo = draft.inReplyTo, .references = draft.references, .labels = &.{"SENT"}, .receivedAt = std.Io.Timestamp.now(s.io, .real).toMilliseconds(), .attachments = draft.attachments, .invitation = calendar };
            // Copy the receipt first: put() can grow the entries slice, never operations.
            store.putOutbox(sent) catch {
                operation.outcome = "unknown";
            };
            store.state.generation += 1;
        }
        store.save() catch {
            operation.outcome = "unknown";
        };
        return j.value(a, operation.*);
    }
};

fn array(v: Value, key: []const u8) ![]Value {
    return valueArray(j.get(v, key) orelse return error.InvalidProviderResponse);
}
fn valueArray(v: Value) ![]Value {
    return if (v == .array) v.array.items else error.InvalidRequest;
}
pub fn decodeAddresses(a: std.mem.Allocator, v: Value) ![]const t.Address {
    var list: std.ArrayList(t.Address) = .empty;
    if (v == .string) {
        var parsed: recipients.List = .{};
        try recipients.parse(v.string, &parsed);
        return listAddresses(a, &parsed);
    }
    const values = try valueArray(v);
    if (values.len > t.Limits.recipients) return error.TooManyRecipients;
    for (values) |item| {
        const address = if (item == .string) item.string else try j.required(item, "address");
        if (item == .object) if (j.get(item, "name")) |field| {
            if (field != .string) return error.InvalidRequest;
        };
        const name = if (item == .string) "" else j.text(item, "name");
        try recipients.validateAddress(address);
        try recipients.validateHeader(name);
        if (name.len > 256) return error.InvalidAddress;
        try list.append(a, .{ .address = address, .name = name });
    }
    return list.items;
}
pub fn decodeDraft(a: std.mem.Allocator, v: Value) !t.Draft {
    if (v != .object) return error.InvalidRequest;
    for ([_][]const u8{ "id", "subject", "bodyText", "threadId", "inReplyTo", "references" }) |key| if (j.get(v, key)) |field| {
        if (field != .string) return error.InvalidRequest;
    };
    var draft = try j.decode(t.Draft, a, try j.value(a, .{ .id = j.text(v, "id"), .subject = j.text(v, "subject"), .bodyText = j.text(v, "bodyText"), .threadId = j.text(v, "threadId"), .inReplyTo = j.text(v, "inReplyTo"), .references = j.text(v, "references") }));
    draft.to = if (j.get(v, "to")) |x| try decodeAddresses(a, x) else &.{};
    draft.cc = if (j.get(v, "cc")) |x| try decodeAddresses(a, x) else &.{};
    draft.bcc = if (j.get(v, "bcc")) |x| try decodeAddresses(a, x) else &.{};
    draft.attachments = if (j.get(v, "attachments")) |x| try j.decode([]const t.Attachment, a, x) else &.{};
    _ = try @import("mime.zig").composeAttachments(draft.attachments, a);
    return draft;
}
pub fn validateDraft(d: t.Draft, send: bool) !void {
    if (d.to.len + d.cc.len + d.bcc.len > t.Limits.recipients) return error.TooManyRecipients;
    if (send and d.to.len + d.cc.len + d.bcc.len == 0) return error.MissingRecipient;
    if (d.bodyText.len > t.Limits.body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(d.bodyText)) return error.InvalidUtf8;
    if (d.attachments.len > 16) return error.TooManyAttachments;
    var attachment_bytes: usize = 0;
    for (d.attachments) |attachment| {
        if (attachment.filename.len == 0 or attachment.filename.len > 256 or std.mem.indexOfAny(u8, attachment.filename, "/\\") != null) return error.InvalidAttachment;
        try recipients.validateHeader(attachment.filename);
        try recipients.validateHeader(attachment.mimeType);
        if (attachment.mimeType.len == 0 or attachment.mimeType.len > 128 or std.mem.indexOfScalar(u8, attachment.mimeType, '/') == null) return error.InvalidAttachment;
        const n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(attachment.data) catch return error.InvalidAttachment;
        attachment_bytes = std.math.add(usize, attachment_bytes, n) catch return error.BodyTooLarge;
        if (attachment_bytes > t.Limits.body_bytes or n != attachment.size) return error.InvalidAttachment;
        // Validate every encoded byte without allocating a second binary copy.
        for (attachment.data) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidAttachment;
    }
    try recipients.validateHeader(d.subject);
    try recipients.validateHeader(d.inReplyTo);
    try recipients.validateHeader(d.references);
    try recipients.validateHeader(d.threadId);
    if (d.subject.len > 4096 or d.references.len > 8192) return error.HeaderTooLarge;
    for ([_][]const t.Address{ d.to, d.cc, d.bcc }) |list| for (list) |address| {
        try recipients.validateAddress(address.address);
        try recipients.validateHeader(address.name);
    };
}
fn listAddresses(a: std.mem.Allocator, list: *const recipients.List) ![]const t.Address {
    const result = try a.alloc(t.Address, list.count);
    for (list.slice(), result) |*src, *dst| dst.* = .{ .address = try a.dupe(u8, src.address.slice()), .name = try a.dupe(u8, src.name.slice()) };
    return result;
}
fn addressHeader(a: std.mem.Allocator, list: []const t.Address) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    for (list, 0..) |address, i| {
        if (i > 0) try bytes.appendSlice(a, ", ");
        try bytes.appendSlice(a, address.address);
    }
    return bytes.items;
}
fn quote(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, "\n\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len + 3 > t.Limits.body_bytes - bytes.items.len) return error.BodyTooLarge;
        try bytes.appendSlice(a, "> ");
        try bytes.appendSlice(a, line);
        try bytes.append(a, '\n');
    }
    return bytes.items;
}
fn hasLabel(m: t.Message, label: []const u8) bool {
    for (m.labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}
fn removeLabel(list: *std.ArrayList([]const u8), label: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], label)) _ = list.orderedRemove(i) else i += 1;
    }
}
fn addLabel(a: std.mem.Allocator, list: *std.ArrayList([]const u8), label: []const u8) !void {
    for (list.items) |l| if (std.mem.eql(u8, l, label)) return;
    if (list.items.len == 64) return error.TooManyLabels;
    try list.append(a, label);
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}
fn matches(m: t.Message, q: []const u8) bool {
    if (std.mem.eql(u8, q, "-in:inbox -in:trash")) return !hasLabel(m, "INBOX") and !hasLabel(m, "TRASH");
    if (std.mem.startsWith(u8, q, "from:")) return containsIgnoreCase(m.from.address, q[5..]);
    if (std.mem.startsWith(u8, q, "subject:")) return containsIgnoreCase(m.subject, q[8..]);
    if (std.mem.eql(u8, q, "is:unread")) return m.unread;
    if (std.mem.eql(u8, q, "in:trash")) return hasLabel(m, "TRASH");
    return containsIgnoreCase(m.subject, q) or containsIgnoreCase(m.snippet, q) or containsIgnoreCase(m.bodyText, q) or containsIgnoreCase(m.from.address, q);
}
pub fn boundedJson(raw: []const u8) bool {
    var quote_open = false;
    var escaped = false;
    var depth: usize = 0;
    var separators: usize = 0;
    for (raw) |c| {
        if (quote_open) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quote_open = false;
            continue;
        }
        switch (c) {
            '"' => quote_open = true,
            '[', '{' => {
                depth += 1;
                if (depth > 64) return false;
            },
            ']', '}' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            ',', ':' => {
                separators += 1;
                if (separators > 65536) return false;
            },
            else => {},
        }
    }
    return !quote_open and depth == 0;
}
fn utcStamp(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    if (seconds < 0 or seconds > 253402300799) return error.InvalidClock;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}
fn calendarIdentity(a: std.mem.Allocator, ics: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitSequence(u8, ics, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "DTSTAMP:")) continue;
        try out.appendSlice(a, line);
        try out.appendSlice(a, "\r\n");
    }
    return out.items;
}

fn olderFirst(_: void, a: t.Message, b: t.Message) bool {
    return a.receivedAt < b.receivedAt;
}
fn newerFirst(_: void, a: t.Message, b: t.Message) bool {
    return a.receivedAt > b.receivedAt;
}
fn utf8Prefix(bytes: []const u8, limit: usize) []const u8 {
    var n = @min(bytes.len, limit);
    while (n > 0 and !std.unicode.utf8ValidateSlice(bytes[0..n])) : (n -= 1) {}
    return bytes[0..n];
}

test "post-dispatch allocation failure preserves live mutation ambiguity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    const receipt: Value = .{ .string = "applied-provider-receipt" };
    for ([_][]const u8{ "contacts.upsert", "mail.mark", "mail.archive", "mail.trash", "mail.restore", "mail.send", "draft.send", "invitation.reply" }) |cmd| {
        try std.testing.expectError(error.UnknownOutcome, Session.successResponse(a, .null, "self@example.test", cmd, false, receipt));
    }
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "mail.read", false, receipt));
    try std.testing.expectError(error.OutOfMemory, Session.successResponse(a, .null, "self@example.test", "contacts.upsert", true, receipt));
    try std.testing.expectError(error.UnknownOutcome, Session.failureForError(a, .null, "self@example.test", error.UnknownOutcome));
    try std.testing.expect(failing.has_induced_failure);
}
