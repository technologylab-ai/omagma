//! Native command host. Mail source reads finish before the Calendar transport
//! acquires the single HTTP workspace. Durable callbacks only hold local locks.
const std = @import("std");
const Config = @import("../config.zig").Config;
const j = @import("json.zig");
const mail = @import("types.zig");
const auth = @import("auth.zig");
const native = @import("calendar_native.zig");
const commands = @import("calendar_commands.zig");
const service = @import("calendar_service.zig");
const persistence = @import("calendar_store.zig");
const t = @import("calendar_types.zig");
const cached = @import("calendar_cached.zig");

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    config: *const Config,
    options: mail.Options,
    cache_root: []const u8,
    access: @import("store_access.zig").Access = .{},
    source_context: *anyopaque,
    loadSourceFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, j.Value) anyerror!commands.InvitationInput,

    /// Mail has already been sent and its durable receipt is independent of
    /// this continuation. Its source is supplied before the Calendar client
    /// opens, preserving the one-network-workspace rule.
    pub fn syncRsvp(self: Host, request: j.Value, source: commands.InvitationInput, response: @import("calendar_provider.zig").RsvpResponse) !@import("calendar_rsvp.zig").Result {
        return (try self.rsvp(request, source, response, true)).?;
    }

    pub fn preflightRsvp(self: Host, request: j.Value, source: commands.InvitationInput, response: @import("calendar_provider.zig").RsvpResponse) !?@import("calendar_rsvp.zig").Result {
        return self.rsvp(request, source, response, false);
    }

    fn rsvp(self: Host, request: j.Value, source: commands.InvitationInput, response: @import("calendar_provider.zig").RsvpResponse, apply: bool) !?@import("calendar_rsvp.zig").Result {
        const account = try j.required(request, "account");
        if (self.options.fixtures and std.mem.eql(u8, self.options.fixture_scenario, "calendar-no-grant")) return error.CalendarPermissionRequired;
        if (!self.options.fixtures) _ = try self.checkGrant(request, "calendar.review", account);
        var store: persistence.Host = .{ .io = self.io, .allocator = self.backing_allocator, .result_allocator = self.allocator, .root = self.cache_root, .account = account, .options = self.options, .access = self.access };
        var inputs: Inputs = .{ .store = &store, .source = source };
        const callbacks: commands.HostInputs = .{ .io = self.io, .env = self.env, .context = &inputs, .loadInvitationFn = Inputs.sourceInput, .loadReviewFn = Inputs.reviewInput, .loadReceiptFn = Inputs.receiptInput, .loadPendingFn = Inputs.pendingInput };
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        if (self.options.fixtures) {
            var transport = try @import("calendar_fixture.zig").Provider.init(.{ .io = self.io, .allocator = self.backing_allocator, .root = self.cache_root, .account = account, .options = self.options, .now_ms = now, .access = self.access });
            if (std.mem.eql(u8, self.options.fixture_scenario, "calendar-offline")) return error.ConnectionRefused;
            const instance: service.Service = .{ .a = self.allocator, .grants = transport.grants(), .transport = transport.transport(), .persistence = store.persistence(), .cache = store.cache(), .now_ms = now };
            return if (apply) try @import("calendar_rsvp.zig").sync(instance, request, callbacks, response) else try @import("calendar_rsvp.zig").preflight(instance, request, callbacks, response);
        }
        const transport = try self.backing_allocator.create(native.Native);
        defer self.backing_allocator.destroy(transport);
        transport.* = .{};
        try transport.init(self.io, self.allocator, self.backing_allocator, self.config, account, "calendar.review", request);
        defer transport.close();
        const instance: service.Service = .{ .a = self.allocator, .grants = transport.grants, .transport = transport.transport(), .persistence = store.persistence(), .cache = store.cache(), .now_ms = now };
        return if (apply) try @import("calendar_rsvp.zig").sync(instance, request, callbacks, response) else try @import("calendar_rsvp.zig").preflight(instance, request, callbacks, response);
    }

    pub fn canSyncRsvp(self: Host, request: j.Value, account: []const u8) bool {
        if (self.options.fixtures) return !std.mem.eql(u8, self.options.fixture_scenario, "calendar-no-grant") and !std.mem.eql(u8, self.options.fixture_scenario, "calendar-readonly");
        _ = self.checkGrant(request, "calendar.review", account) catch return false;
        return true;
    }

    pub fn run(self: Host, request: j.Value) !j.Value {
        try commands.preflight(request);
        const account = try j.required(request, "account");
        const command = try j.required(request, "cmd");
        if (try j.boolean(request, "cacheOnly", false) and !cached.supported(command)) return error.CacheUnsupported;
        // Local grant checks precede even a read of the source mail. Native
        // repeats validation before credentials/network and verifies identity.
        const local_grants: ?service.Grants = if (!self.options.fixtures) try self.checkGrant(request, command, account) else null;
        var input: ?commands.InvitationInput = null;
        if (std.mem.eql(u8, command, "calendar.review") or std.mem.eql(u8, command, "calendar.invitation-plan")) {
            input = try self.loadSourceFn(self.source_context, self.allocator, account, request);
        }
        var store: persistence.Host = .{ .io = self.io, .allocator = self.backing_allocator, .result_allocator = self.allocator, .root = self.cache_root, .account = account, .options = self.options, .access = self.access };
        var inputs: Inputs = .{ .store = &store, .source = input };
        const callbacks: commands.HostInputs = .{ .io = self.io, .env = self.env, .context = &inputs, .loadInvitationFn = Inputs.sourceInput, .loadReviewFn = Inputs.reviewInput, .loadReceiptFn = Inputs.receiptInput, .loadPendingFn = Inputs.pendingInput };
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        if (self.options.fixtures) return self.fixtureRun(request, &store, callbacks, now);
        if (commands.localCommand(command)) return commands.dispatch(.{ .a = self.allocator, .grants = local_grants.?, .transport = .{ .context = &inputs, .sendFn = Inputs.localOnly }, .persistence = store.persistence(), .cache = store.cache(), .now_ms = now }, request, callbacks);
        if (try j.boolean(request, "cacheOnly", false)) return cached.dispatch(self.allocator, local_grants.?, &store, request, callbacks, "");
        const transport = try self.backing_allocator.create(native.Native);
        defer self.backing_allocator.destroy(transport);
        transport.* = .{};
        transport.init(self.io, self.allocator, self.backing_allocator, self.config, account, command, request) catch |err| {
            return self.offlineFallback(request, local_grants.?, &store, callbacks, err);
        };
        defer transport.close();
        const instance: service.Service = .{ .a = self.allocator, .grants = transport.grants, .transport = transport.transport(), .persistence = store.persistence(), .cache = store.cache(), .now_ms = now };
        return commands.dispatch(instance, request, callbacks) catch |err| {
            return self.offlineFallback(request, local_grants.?, &store, callbacks, err);
        };
    }

    fn checkGrant(self: Host, request: j.Value, command: []const u8, account: []const u8) !service.Grants {
        const allowed = try native.capabilitiesForCommand(command);
        const registry = try auth.loadConfigured(self.io, self.allocator, self.config, if (self.config.credential_store == .vault) "" else try j.required(request, "grantFile"));
        const grant = auth.find(&registry, account) orelse return error.CalendarPermissionRequired;
        for (allowed) |capability| if (grant.permits(capability)) return native.grantsFor(account, grant.capabilities, grant.scopes);
        return error.CalendarPermissionRequired;
    }

    fn offlineFallback(self: Host, request: j.Value, grants: service.Grants, store: *persistence.Host, inputs: commands.HostInputs, err: anyerror) !j.Value {
        if (!cached.supported(j.text(request, "cmd")) or !cached.connectionFailure(err)) return err;
        return cached.dispatch(self.allocator, grants, store, request, inputs, @errorName(err)) catch |cache_error| return switch (cache_error) {
            error.CalendarNotCached, error.CalendarEventNotCached => err,
            else => cache_error,
        };
    }

    fn fixtureRun(self: Host, request: j.Value, store: *persistence.Host, inputs: commands.HostInputs, now: i64) !j.Value {
        var transport = try @import("calendar_fixture.zig").Provider.init(.{ .io = self.io, .allocator = self.backing_allocator, .root = self.cache_root, .account = store.account, .options = self.options, .now_ms = now, .access = self.access });
        if (commands.localCommand(j.text(request, "cmd"))) return commands.dispatch(.{ .a = self.allocator, .grants = transport.grants(), .transport = .{ .context = store, .sendFn = Inputs.localOnly }, .persistence = store.persistence(), .cache = store.cache(), .now_ms = now }, request, inputs);
        if (try j.boolean(request, "cacheOnly", false)) return cached.dispatch(self.allocator, transport.grants(), store, request, inputs, "");
        if (std.mem.eql(u8, self.options.fixture_scenario, "calendar-offline")) return self.offlineFallback(request, transport.grants(), store, inputs, error.ConnectionRefused);
        const instance: service.Service = .{ .a = self.allocator, .grants = transport.grants(), .transport = transport.transport(), .persistence = store.persistence(), .cache = store.cache(), .now_ms = now };
        return commands.dispatch(instance, request, inputs);
    }
};

const Inputs = struct {
    store: *persistence.Host,
    source: ?commands.InvitationInput,

    fn localOnly(_: *anyopaque, _: std.mem.Allocator, _: @import("calendar_provider.zig").Request) anyerror!service.Response {
        return error.CalendarLocalReadOnly;
    }

    fn sourceInput(context: *anyopaque, _: std.mem.Allocator, account: []const u8, _: j.Value) anyerror!commands.InvitationInput {
        const self: *Inputs = @ptrCast(@alignCast(context));
        if (!std.ascii.eqlIgnoreCase(account, self.store.account)) return error.CalendarAccountMismatch;
        return self.source orelse error.NotInvitation;
    }
    fn reviewInput(context: *anyopaque, a: std.mem.Allocator, target: t.Target, operation_id: []const u8) anyerror!service.Review {
        const self: *Inputs = @ptrCast(@alignCast(context));
        return self.store.loadReview(a, target, operation_id);
    }
    fn receiptInput(context: *anyopaque, a: std.mem.Allocator, target: t.Target, operation_id: []const u8) anyerror!?service.Receipt {
        const self: *Inputs = @ptrCast(@alignCast(context));
        return self.store.loadReceipt(a, target, operation_id);
    }
    fn pendingInput(context: *anyopaque, a: std.mem.Allocator, target: t.Target, event_id: []const u8) anyerror!?service.Pending {
        const self: *Inputs = @ptrCast(@alignCast(context));
        return self.store.loadPending(a, target, event_id);
    }
};
