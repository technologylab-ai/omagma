//! Persistent synthetic Calendar provider for actual --fixtures command flows.
//! Every call uses a short account Store transaction in its fixtures namespace.
//! No real credentials, live namespace, network client or production calendar.
const std = @import("std");
const t = @import("calendar_types.zig");
const service = @import("calendar_service.zig");
const provider = @import("calendar_provider.zig");
const storage = @import("store.zig");
const options_type = @import("types.zig").Options;
const j = @import("json.zig");

pub const document_name = "calendar-provider-fixture.json";
pub const document_bytes = 4 * 1024 * 1024;
pub const Config = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    account: []const u8,
    options: options_type,
    now_ms: i64,
    access: @import("store_access.zig").Access = .{},
};
const StoredEvent = struct { calendar_id: []const u8, value: j.Value };
const State = struct {
    schema: u8 = 1,
    account: []const u8,
    generation: u64 = 0,
    writes: u64 = 0,
    dispatch_attempts: u64 = 0,
    events: []StoredEvent = &.{},
};

pub const Provider = struct {
    config: Config,
    pub fn init(config: Config) !Provider {
        if (!config.options.fixtures) return error.FixtureOnly;
        try @import("../bounded.zig").address(config.account);
        if (config.root.len == 0 or config.root.len > 4096) return error.InvalidFixtureRoot;
        return .{ .config = config };
    }
    pub fn grants(self: *const Provider) service.Grants {
        const readonly = std.mem.eql(u8, self.config.options.fixture_scenario, "readonly") or std.mem.eql(u8, self.config.options.fixture_scenario, "calendar-readonly");
        if (std.mem.eql(u8, self.config.options.fixture_scenario, "calendar-picker-owned-only")) return .{ .account = self.config.account, .calendar_list = true, .write_owned = true };
        return .{ .account = self.config.account, .calendar_list = true, .read_events = true, .write_owned = !readonly, .write_shared = !readonly, .free_busy = true };
    }
    pub fn transport(self: *Provider) service.Transport {
        return .{ .context = self, .sendFn = send };
    }
    fn send(context: *anyopaque, out: std.mem.Allocator, request: provider.Request) anyerror!service.Response {
        const self: *Provider = @ptrCast(@alignCast(context));
        if (!self.config.options.fixtures) return error.FixtureOnly;
        try request.target.validate();
        if (!std.ascii.eqlIgnoreCase(request.target.account, self.config.account)) return error.CalendarAccountMismatch;
        var phase = std.heap.ArenaAllocator.init(self.config.allocator);
        defer phase.deinit();
        const a = phase.allocator();
        const event_id = try validateRequest(a, request);
        try self.waitForReadFixture(a, request.kind);
        var store = try self.config.access.open(self.config.io, a, self.config.root, self.config.account, self.config.options, false);
        defer store.close();
        var state = if (try store.readDocument(a, document_name, document_bytes)) |bytes| try load(a, self.config.account, self.config.options.fixture_scenario, bytes) else initial: {
            const value = try seed(a, self.config.account, self.config.now_ms);
            try save(&store, a, value);
            break :initial value;
        };
        if (request.kind == .calendar_list) return response(out, self.config.account, 200, try calendars(a, self.config.account, self.config.options.fixture_scenario));
        const access = calendarAccess(self.config.account, request.target.calendar_id, self.config.options.fixture_scenario) orelse return failure(out, self.config.account, 404, "notFound");
        if (request.kind.mutating() and (access == .reader or !self.grants().write_shared)) return failure(out, self.config.account, 403, "forbidden");
        if (request.kind.mutating()) {
            state.dispatch_attempts += 1;
            try save(&store, a, state);
            if (std.mem.eql(u8, self.config.options.fixture_scenario, "calendar-prewrite-unavailable")) return failure(out, self.config.account, 503, "backendError");
        }
        switch (request.kind) {
            .calendar_list => unreachable,
            .event_lookup => {
                const uid = try query(a, request.url, "iCalUID") orelse return error.InvalidCalendarRequest;
                var items: std.ArrayList(j.Value) = .empty;
                for (state.events) |event| if (std.mem.eql(u8, event.calendar_id, request.target.calendar_id) and std.mem.eql(u8, j.text(event.value, "iCalUID"), uid)) try items.append(a, event.value);
                return response(out, self.config.account, 200, try pageItems(a, request.url, items.items));
            },
            .agenda => return response(out, self.config.account, 200, try pageItems(a, request.url, try agendaItems(a, state, request.target, try requestedWindow(a, request.url)))),
            .event_get => {
                if (findEvent(state, request.target.calendar_id, event_id)) |index| return response(out, self.config.account, 200, state.events[index].value);
                if (try findInstance(a, state, request.target, event_id)) |value| return response(out, self.config.account, 200, value);
                return failure(out, self.config.account, 404, "notFound");
            },
            .free_busy => return response(out, self.config.account, 200, try freeBusy(a, state, request)),
            .import_event, .insert_event => {
                const body = try parse(a, request.body.?);
                const uid = if (request.kind == .import_event) try j.required(body, "iCalUID") else try std.fmt.allocPrint(a, "{s}@google.com", .{try j.required(body, "id")});
                for (state.events) |event| if (std.mem.eql(u8, event.calendar_id, request.target.calendar_id) and std.mem.eql(u8, j.text(event.value, "iCalUID"), uid)) return failure(out, self.config.account, 409, "duplicate");
                if (state.events.len >= 128) return failure(out, self.config.account, 403, "quotaExceeded");
                var event = try j.copyObject(a, body);
                state.generation += 1;
                const id = if (request.kind == .insert_event) try j.required(body, "id") else try std.fmt.allocPrint(a, "fixture-imported-{d}", .{state.generation});
                try event.object.put(a, "iCalUID", .{ .string = uid });
                if (request.kind == .insert_event) try event.object.put(a, "organizer", try j.value(a, .{ .email = self.config.account, .self = true }));
                try event.object.put(a, "id", .{ .string = id });
                try event.object.put(a, "etag", .{ .string = try etag(a, state.generation) });
                try event.object.put(a, "status", .{ .string = "confirmed" });
                if (request.kind == .import_event) try event.object.put(a, "privateCopy", .{ .bool = true });
                if (j.get(body, "conferenceData") != null) try fixtureConference(a, &event, self.config.options.fixture_scenario);
                try event.object.put(a, "htmlLink", .{ .string = try std.fmt.allocPrint(a, "https://calendar.google.com/calendar/event?eid={s}", .{id}) });
                _ = try provider.decodeDocument(a, request.target, try std.json.Stringify.valueAlloc(a, event, .{}));
                const events = try a.alloc(StoredEvent, state.events.len + 1);
                @memcpy(events[0..state.events.len], state.events);
                events[state.events.len] = .{ .calendar_id = request.target.calendar_id, .value = event };
                state.events = events;
                try self.commit(&store, a, &state);
                if (self.lostResponse()) return error.ConnectionResetByPeer;
                return response(out, self.config.account, 200, event);
            },
            .update_event, .cancel_event => {
                const index = findEvent(state, request.target.calendar_id, event_id) orelse return failure(out, self.config.account, 404, "notFound");
                const original = state.events[index].value;
                if (!std.mem.eql(u8, request.if_match.?, j.text(original, "etag"))) return failure(out, self.config.account, 412, "conditionNotMet");
                var event = try j.copyObject(a, original);
                if (request.kind == .update_event) {
                    const changes = try parse(a, request.body.?);
                    if (changes != .object) return error.InvalidCalendarRequest;
                    var fields = changes.object.iterator();
                    while (fields.next()) |field| {
                        if (!patchField(field.key_ptr.*)) return failure(out, self.config.account, 400, "invalid");
                        if (std.mem.eql(u8, field.key_ptr.*, "extendedProperties")) {
                            try event.object.put(a, "extendedProperties", try mergeProperties(a, j.get(original, "extendedProperties"), field.value_ptr.*));
                        } else if (std.mem.eql(u8, field.key_ptr.*, "attendees") and try j.boolean(changes, "attendeesOmitted", false)) {
                            const attendees = j.get(original, "attendees") orelse return error.InvalidCalendarRequest;
                            if (attendees != .array or field.value_ptr.* != .array) return error.InvalidCalendarRequest;
                            const merged = try a.dupe(j.Value, attendees.array.items);
                            for (field.value_ptr.array.items) |changed| {
                                var matched = false;
                                for (merged) |*attendee| if (std.ascii.eqlIgnoreCase(j.text(attendee.*, "email"), j.text(changed, "email"))) {
                                    attendee.* = try j.copyObject(a, attendee.*);
                                    try attendee.object.put(a, "responseStatus", j.get(changed, "responseStatus") orelse return error.InvalidCalendarRequest);
                                    matched = true;
                                };
                                if (!matched) return error.InvalidCalendarRequest;
                            }
                            try event.object.put(a, "attendees", .{ .array = .fromOwnedSlice(a, merged) });
                        } else if (std.mem.eql(u8, field.key_ptr.*, "start") or std.mem.eql(u8, field.key_ptr.*, "end")) {
                            var endpoint = try j.copyObject(a, field.value_ptr.*);
                            // Google PATCH clears null keys; responses omit them.
                            for ([_][]const u8{ "date", "dateTime", "timeZone" }) |key| if (j.get(endpoint, key)) |entry| if (entry == .null) {
                                _ = endpoint.object.swapRemove(key);
                            };
                            try event.object.put(a, field.key_ptr.*, endpoint);
                        } else if (std.mem.eql(u8, field.key_ptr.*, "attendeesOmitted")) {
                            // Only the submitted response is partial; the fixture
                            // still retains the complete provider representation.
                        } else try event.object.put(a, field.key_ptr.*, field.value_ptr.*);
                    }
                } else try event.object.put(a, "status", .{ .string = "cancelled" });
                if (request.kind == .update_event and j.get(try parse(a, request.body.?), "conferenceData") != null) try fixtureConference(a, &event, self.config.options.fixture_scenario);
                state.generation += 1;
                try event.object.put(a, "etag", .{ .string = try etag(a, state.generation) });
                _ = try provider.decodeDocument(a, request.target, try std.json.Stringify.valueAlloc(a, event, .{}));
                state.events[index].value = event;
                try self.commit(&store, a, &state);
                if (self.lostResponse()) return error.ConnectionResetByPeer;
                if (request.kind == .cancel_event) return .{ .account = try out.dupe(u8, self.config.account), .status = 204 };
                return response(out, self.config.account, 200, event);
            },
        }
    }
    fn waitForReadFixture(self: *const Provider, a: std.mem.Allocator, kind: provider.OperationKind) !void {
        if (kind != .calendar_list and kind != .agenda) return;
        const root = self.config.options.fixture_root orelse return;
        const control_path = try std.fs.path.join(a, &.{ root, "calendar-priority-control.json" });
        const raw = std.Io.Dir.cwd().readFileAlloc(self.config.io, control_path, a, .limited(4096)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        const Control = struct { account: []const u8, kind: enum { calendar_list, agenda } };
        const control = try std.json.parseFromSliceLeaky(Control, a, raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
        if (!std.mem.eql(u8, control.account, self.config.account) or !std.mem.eql(u8, @tagName(control.kind), @tagName(kind))) return;
        // This synthetic provider gate precedes any Store lock. Its fixed
        // marker names cannot overwrite fixture data or reference files.
        const entered_path = try std.fs.path.join(a, &.{ root, "calendar-priority.entered" });
        const marker = std.Io.Dir.cwd().createFile(self.config.io, entered_path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| if (err == error.PathAlreadyExists) null else return err;
        if (marker) |file| file.close(self.config.io);
        const hold_path = try std.fs.path.join(a, &.{ root, "calendar-priority.hold" });
        const deadline: std.Io.Clock.Timestamp = .fromNow(self.config.io, .{ .clock = .awake, .raw = .fromSeconds(15) });
        while (true) {
            try self.config.io.checkCancel();
            std.Io.Dir.cwd().access(self.config.io, hold_path, .{}) catch |err| {
                if (err == error.FileNotFound) return;
                return err;
            };
            if (deadline.durationFromNow(self.config.io).raw.toNanoseconds() <= 0) return error.Timeout;
            try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(20) }).sleep(self.config.io);
        }
    }
    fn commit(self: *Provider, store: *storage.Store, a: std.mem.Allocator, state: *State) !void {
        _ = self;
        state.writes += 1;
        try save(store, a, state.*);
    }
    fn lostResponse(self: *const Provider) bool {
        return std.mem.eql(u8, self.config.options.fixture_scenario, "calendar-lost-response");
    }
};

fn parse(a: std.mem.Allocator, bytes: []const u8) !j.Value {
    if (bytes.len > t.Limits.response_bytes) return error.CalendarResponseTooLarge;
    try @import("../bounded.zig").preflight(bytes);
    return std.json.parseFromSliceLeaky(j.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}
fn load(a: std.mem.Allocator, account: []const u8, scenario: []const u8, bytes: []const u8) !State {
    if (bytes.len > document_bytes) return error.CalendarFixtureTooLarge;
    try @import("../bounded.zig").preflight(bytes);
    const state = try std.json.parseFromSliceLeaky(State, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    if (state.schema != 1 or !std.mem.eql(u8, state.account, account) or state.events.len > 128 or state.writes != state.generation or state.generation == std.math.maxInt(u64)) return error.InvalidCalendarFixture;
    for (state.events, 0..) |event, index| {
        if (calendarAccess(account, event.calendar_id, scenario) == null) return error.InvalidCalendarFixture;
        const id = try j.required(event.value, "id");
        for (state.events[0..index]) |previous| if (std.mem.eql(u8, previous.calendar_id, event.calendar_id) and std.mem.eql(u8, j.text(previous.value, "id"), id)) return error.InvalidCalendarFixture;
        const decoded = (try provider.decodeDocument(a, .{ .account = account, .calendar_id = event.calendar_id }, try std.json.Stringify.valueAlloc(a, event.value, .{}))).event;
        if (j.get(event.value, "recurrence")) |rules| {
            if (rules != .array or rules.array.items.len != 1 or rules.array.items[0] != .string or !std.mem.eql(u8, rules.array.items[0].string, "RRULE:FREQ=DAILY")) return error.InvalidCalendarFixture;
            if (decoded.start == null or decoded.end == null or decoded.start.?.kind != .instant or decoded.end.?.kind != .instant or decoded.end.?.value <= decoded.start.?.value or decoded.end.?.value - decoded.start.?.value > 86400000) return error.InvalidCalendarFixture;
        }
    }
    return state;
}
fn save(store: *storage.Store, a: std.mem.Allocator, state: State) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, state, .{});
    if (bytes.len > document_bytes) return error.CalendarFixtureTooLarge;
    try store.writeDocument(document_name, bytes);
}
fn response(a: std.mem.Allocator, account: []const u8, status: u16, value: j.Value) !service.Response {
    const body = try std.json.Stringify.valueAlloc(a, value, .{});
    if (body.len > t.Limits.response_bytes) return error.CalendarResponseTooLarge;
    return .{ .account = try a.dupe(u8, account), .status = status, .body = body };
}
fn failure(a: std.mem.Allocator, account: []const u8, status: u16, reason: []const u8) !service.Response {
    return response(a, account, status, try j.value(a, .{ .@"error" = .{ .code = status, .errors = [_]struct { reason: []const u8 }{.{ .reason = reason }} } }));
}
fn pickerAccessScenario(scenario: []const u8) bool {
    return std.mem.eql(u8, scenario, "calendar-picker-owned-only") or std.mem.eql(u8, scenario, "calendar-picker-restored");
}
fn calendars(a: std.mem.Allocator, account: []const u8, scenario: []const u8) !j.Value {
    if (pickerAccessScenario(scenario) and std.mem.eql(u8, account, "personal@example.com")) return j.value(a, .{ .items = .{
        .{ .id = account, .summary = "Personal", .timeZone = "UTC", .accessRole = "owner", .primary = true, .selected = true },
        .{ .id = "fixture-shared-team", .summary = "Shared team", .timeZone = "UTC", .accessRole = "owner", .dataOwner = "calendar-owner@example.test", .selected = true },
        .{ .id = "optional@example.com", .summary = "Imported own calendar", .timeZone = "UTC", .accessRole = "owner", .dataOwner = "optional@example.com", .selected = true },
    } });
    return j.value(a, .{ .items = .{
        .{ .id = account, .summary = "Personal", .timeZone = "UTC", .accessRole = "owner", .primary = true, .selected = true, .conferenceProperties = .{ .allowedConferenceSolutionTypes = .{"hangoutsMeet"} } },
        .{ .id = "fixture-shared-team", .summary = "Shared team", .timeZone = "UTC", .accessRole = "owner", .dataOwner = "calendar-owner@example.test", .selected = true },
        .{ .id = "fixture-readonly", .summary = "Holidays", .timeZone = "UTC", .accessRole = "reader", .selected = true },
    } });
}
fn calendarAccess(account: []const u8, id: []const u8, scenario: []const u8) ?t.Access {
    if (pickerAccessScenario(scenario) and std.mem.eql(u8, account, "personal@example.com") and std.mem.eql(u8, id, "optional@example.com")) return .owner;
    if (std.mem.eql(u8, account, id) or std.mem.eql(u8, id, "fixture-shared-team")) return .owner;
    if (std.mem.eql(u8, id, "fixture-readonly")) return .reader;
    return null;
}
fn etag(a: std.mem.Allocator, generation: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "\"fixture-version-{d}\"", .{generation});
}
fn findEvent(state: State, calendar_id: []const u8, id: []const u8) ?usize {
    for (state.events, 0..) |event, index| if (std.mem.eql(u8, event.calendar_id, calendar_id) and std.mem.eql(u8, j.text(event.value, "id"), id)) return index;
    return null;
}
fn query(a: std.mem.Allocator, url: []const u8, wanted: []const u8) !?[]const u8 {
    const at = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, url[at + 1 ..], '&');
    var found: ?[]const u8 = null;
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equal], wanted)) continue;
        if (found != null) return error.InvalidCalendarRequest;
        found = std.Uri.percentDecodeInPlace(try a.dupe(u8, pair[equal + 1 ..]));
    }
    return found;
}
fn pageItems(a: std.mem.Allocator, url: []const u8, items: []const j.Value) !j.Value {
    const offset = if (try query(a, url, "pageToken")) |token| blk: {
        if (!std.mem.startsWith(u8, token, "fixture-")) return error.InvalidCalendarRequest;
        break :blk std.fmt.parseInt(usize, token["fixture-".len..], 10) catch return error.InvalidCalendarRequest;
    } else 0;
    if (offset > items.len) return error.InvalidCalendarRequest;
    const end = @min(items.len, offset +| t.Limits.page_events);
    const next = if (end < items.len) try std.fmt.allocPrint(a, "fixture-{d}", .{end}) else "";
    return j.value(a, .{ .items = items[offset..end], .nextPageToken = next });
}
fn validateRequest(a: std.mem.Allocator, request: provider.Request) ![]const u8 {
    const method: std.http.Method = switch (request.kind) {
        .calendar_list, .event_lookup, .agenda, .event_get => .GET,
        .free_busy, .import_event, .insert_event => .POST,
        .update_event => .PATCH,
        .cancel_event => .DELETE,
    };
    if (request.method != method) return error.InvalidCalendarRequest;
    const conditional = request.kind == .update_event or request.kind == .cancel_event;
    const body = request.kind == .free_busy or request.kind == .import_event or request.kind == .insert_event or request.kind == .update_event;
    if (conditional != (request.if_match != null) or body != (request.body != null)) return error.InvalidCalendarRequest;
    if (request.kind == .calendar_list) {
        if (!std.mem.startsWith(u8, request.url, provider.base_url ++ "/users/me/calendarList?")) return error.InvalidCalendarPath;
        return "";
    }
    if (request.kind == .free_busy) {
        if (!std.mem.eql(u8, request.url, provider.base_url ++ "/freeBusy")) return error.InvalidCalendarPath;
        return "";
    }
    const marker = "fixture-event-marker";
    const bound = try provider.get(a, request.target, marker);
    const prefix = bound.url[0 .. bound.url.len - marker.len];
    if (request.kind == .event_lookup or request.kind == .agenda or request.kind == .insert_event) {
        const collection = try std.fmt.allocPrint(a, "{s}?", .{prefix[0 .. prefix.len - 1]});
        if (!std.mem.startsWith(u8, request.url, collection)) return error.CalendarIdentityMismatch;
        return "";
    }
    if (!std.mem.startsWith(u8, request.url, prefix)) return error.CalendarIdentityMismatch;
    const tail = request.url[prefix.len..];
    if (request.kind == .import_event) {
        if (!std.mem.eql(u8, tail, "import")) return error.InvalidCalendarPath;
        return "";
    }
    const id = tail[0 .. std.mem.indexOfScalar(u8, tail, '?') orelse tail.len];
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) return error.InvalidCalendarPath;
    return std.Uri.percentDecodeInPlace(try a.dupe(u8, id));
}
fn requestedWindow(a: std.mem.Allocator, url: []const u8) !t.Window {
    const window: t.Window = .{ .start_ms = try t.time.rfc3339(try query(a, url, "timeMin") orelse return error.InvalidCalendarRequest), .end_ms = try t.time.rfc3339(try query(a, url, "timeMax") orelse return error.InvalidCalendarRequest), .time_zone = try query(a, url, "timeZone") orelse "UTC" };
    try window.validate();
    return window;
}
fn seed(a: std.mem.Allocator, account: []const u8, now_ms: i64) !State {
    if (now_ms < 0 or now_ms > 253402214400000) return error.InvalidCalendarTime;
    const day = @divFloor(now_ms, 86400000) * 86400000;
    const events = try a.alloc(StoredEvent, 4);
    events[0] = .{ .calendar_id = account, .value = try timedEvent(a, "fixture-planning", "fixture-planning@example.test", "Project planning", day + 9 * 3600000, day + 10 * 3600000) };
    events[1] = .{ .calendar_id = "fixture-shared-team", .value = try timedEvent(a, "fixture-team", "fixture-team@example.test", "Team check-in", day + 14 * 3600000, day + 15 * 3600000) };
    events[2] = .{ .calendar_id = "fixture-readonly", .value = try j.value(a, .{ .id = "fixture-day", .iCalUID = "fixture-day@example.test", .etag = "\"fixture-seed-1\"", .status = "confirmed", .organizer = .{ .email = "calendar-owner@example.test" }, .summary = "Company day", .start = .{ .date = try t.time.format(a, .{ .kind = .date, .value = @divFloor(day, 86400000) }) }, .end = .{ .date = try t.time.format(a, .{ .kind = .date, .value = @divFloor(day, 86400000) + 1 }) }, .sequence = 0 }) };
    var recurring = try timedEvent(a, "fixture-daily", "fixture-daily@example.test", "Daily review", day + 16 * 3600000, day + 16 * 3600000 + 1800000);
    try recurring.object.put(a, "recurrence", try j.value(a, [_][]const u8{"RRULE:FREQ=DAILY"}));
    events[3] = .{ .calendar_id = account, .value = recurring };
    return .{ .account = account, .events = events };
}
fn timedEvent(a: std.mem.Allocator, id: []const u8, uid: []const u8, summary: []const u8, start: i64, end: i64) !j.Value {
    return j.value(a, .{ .id = id, .iCalUID = uid, .etag = "\"fixture-seed-1\"", .status = "confirmed", .organizer = .{ .email = "host@example.test" }, .summary = summary, .description = "Synthetic Calendar acceptance event.", .location = "Meeting room", .start = .{ .dateTime = try t.time.format(a, .{ .kind = .instant, .value = start }) }, .end = .{ .dateTime = try t.time.format(a, .{ .kind = .instant, .value = end }) }, .sequence = 0, .htmlLink = try std.fmt.allocPrint(a, "https://calendar.google.com/calendar/event?eid={s}", .{id}), .hangoutLink = "https://meet.example.test/fixture", .extendedProperties = .{ .private = .{ .fixtureProperty = "preserved" } } });
}
fn agendaItems(a: std.mem.Allocator, state: State, target: t.Target, window: t.Window) ![]const j.Value {
    var items: std.ArrayList(j.Value) = .empty;
    for (state.events) |stored| {
        if (!std.mem.eql(u8, stored.calendar_id, target.calendar_id) or std.mem.eql(u8, j.text(stored.value, "status"), "cancelled")) continue;
        const event = (try provider.decodeDocument(a, target, try std.json.Stringify.valueAlloc(a, stored.value, .{}))).event;
        if (j.get(stored.value, "recurrence") != null) {
            const begin = event.start.?.value;
            const duration = event.end.?.value - begin;
            var index = @max(0, @divFloor(window.start_ms - begin, 86400000));
            while (begin + index * 86400000 < window.end_ms) : (index += 1) {
                const first = begin + index * 86400000;
                if (first + duration <= window.start_ms) continue;
                if (items.items.len == t.Limits.snapshot_events) return error.TooManyCalendarEvents;
                try items.append(a, try expandedInstance(a, stored.value, event, first));
            }
        } else {
            const first = event.start.?.value * @as(i64, if (event.start.?.kind == .date) 86400000 else 1);
            const last = event.end.?.value * @as(i64, if (event.end.?.kind == .date) 86400000 else 1);
            if (last <= window.start_ms or first >= window.end_ms) continue;
            if (items.items.len == t.Limits.snapshot_events) return error.TooManyCalendarEvents;
            try items.append(a, stored.value);
        }
    }
    std.mem.sort(j.Value, items.items, {}, struct {
        fn lessThan(_: void, left: j.Value, right: j.Value) bool {
            const first = startMillis(left);
            const second = startMillis(right);
            return first < second or (first == second and std.mem.order(u8, j.text(left, "id"), j.text(right, "id")) == .lt);
        }
    }.lessThan);
    return items.items;
}
fn startMillis(value: j.Value) i64 {
    const start = j.get(value, "start").?;
    if (j.get(start, "date")) |date| return (@import("timezone.zig").dateDay(date.string) catch unreachable) * 86400000;
    return t.time.rfc3339(j.text(start, "dateTime")) catch unreachable;
}
fn expandedInstance(a: std.mem.Allocator, value: j.Value, event: t.Event, first: i64) !j.Value {
    var instance = try j.copyObject(a, value);
    _ = instance.object.swapRemove("recurrence");
    try instance.object.put(a, "id", .{ .string = try std.fmt.allocPrint(a, "{s}_{d}", .{ event.id, first }) });
    try instance.object.put(a, "recurringEventId", .{ .string = event.id });
    const start = try j.value(a, .{ .dateTime = try t.time.format(a, .{ .kind = .instant, .value = first }) });
    try instance.object.put(a, "originalStartTime", start);
    try instance.object.put(a, "start", start);
    const last = first + event.end.?.value - event.start.?.value;
    try instance.object.put(a, "end", try j.value(a, .{ .dateTime = try t.time.format(a, .{ .kind = .instant, .value = last }) }));
    return instance;
}
fn findInstance(a: std.mem.Allocator, state: State, target: t.Target, id: []const u8) !?j.Value {
    for (state.events) |stored| {
        if (!std.mem.eql(u8, stored.calendar_id, target.calendar_id) or j.get(stored.value, "recurrence") == null or std.mem.eql(u8, j.text(stored.value, "status"), "cancelled")) continue;
        const prefix = try std.fmt.allocPrint(a, "{s}_", .{j.text(stored.value, "id")});
        if (!std.mem.startsWith(u8, id, prefix)) continue;
        const first = std.fmt.parseInt(i64, id[prefix.len..], 10) catch return null;
        const event = (try provider.decodeDocument(a, target, try std.json.Stringify.valueAlloc(a, stored.value, .{}))).event;
        if (first < event.start.?.value or first > 253402214400000 or @mod(first - event.start.?.value, 86400000) != 0) return null;
        return try expandedInstance(a, stored.value, event, first);
    }
    return null;
}
fn freeBusy(a: std.mem.Allocator, state: State, request: provider.Request) !j.Value {
    const body = try parse(a, request.body.?);
    const window: t.Window = .{ .start_ms = try t.time.rfc3339(try j.required(body, "timeMin")), .end_ms = try t.time.rfc3339(try j.required(body, "timeMax")), .time_zone = j.text(body, "timeZone") };
    try window.validate();
    const requested = j.get(body, "items") orelse return error.InvalidCalendarRequest;
    if (requested != .array or requested.array.items.len != 1 or !std.mem.eql(u8, j.text(requested.array.items[0], "id"), request.target.calendar_id)) return error.CalendarIdentityMismatch;
    var ranges: std.ArrayList(j.Value) = .empty;
    for (try agendaItems(a, state, request.target, window)) |value| {
        const event = (try provider.decodeDocument(a, request.target, try std.json.Stringify.valueAlloc(a, value, .{}))).event;
        if (event.transparent) continue;
        const first = @max(window.start_ms, event.start.?.value * @as(i64, if (event.start.?.kind == .date) 86400000 else 1));
        const last = @min(window.end_ms, event.end.?.value * @as(i64, if (event.end.?.kind == .date) 86400000 else 1));
        try ranges.append(a, try j.value(a, .{ .start = try t.time.format(a, .{ .kind = .instant, .value = first }), .end = try t.time.format(a, .{ .kind = .instant, .value = last }) }));
    }
    var values = j.object(a);
    try values.object.put(a, request.target.calendar_id, try j.value(a, .{ .busy = ranges.items }));
    return j.value(a, .{ .timeMin = try j.required(body, "timeMin"), .timeMax = try j.required(body, "timeMax"), .calendars = values });
}
fn patchField(name: []const u8) bool {
    for ([_][]const u8{ "summary", "description", "location", "start", "end", "sequence", "extendedProperties", "attendees", "attendeesOmitted", "conferenceData" }) |field| if (std.mem.eql(u8, name, field)) return true;
    return false;
}
fn mergeProperties(a: std.mem.Allocator, previous: ?j.Value, changes: j.Value) !j.Value {
    if (changes != .object) return error.InvalidCalendarRequest;
    var result = if (previous) |value| try j.copyObject(a, value) else j.object(a);
    var groups = changes.object.iterator();
    while (groups.next()) |group| {
        var fields = if (j.get(result, group.key_ptr.*)) |old| try j.copyObject(a, old) else j.object(a);
        if (group.value_ptr.* != .object) return error.InvalidCalendarRequest;
        var items = group.value_ptr.object.iterator();
        while (items.next()) |item| {
            if (item.value_ptr.* == .null) _ = fields.object.swapRemove(item.key_ptr.*) else try fields.object.put(a, item.key_ptr.*, item.value_ptr.*);
        }
        try result.object.put(a, group.key_ptr.*, fields);
    }
    return result;
}

fn fixtureConference(a: std.mem.Allocator, event: *j.Value, scenario: []const u8) !void {
    var conference = j.get(event.*, "conferenceData") orelse return;
    const create = j.get(conference, "createRequest") orelse return;
    var updated = try j.copyObject(a, create);
    const status: []const u8 = if (std.mem.eql(u8, scenario, "calendar-meet-pending")) "pending" else if (std.mem.eql(u8, scenario, "calendar-meet-failure")) "failure" else "success";
    try updated.object.put(a, "status", try j.value(a, .{ .statusCode = status }));
    conference = try j.copyObject(a, conference);
    try conference.object.put(a, "createRequest", updated);
    if (!std.mem.eql(u8, status, "success")) {
        try event.object.put(a, "conferenceData", conference);
        return;
    }
    const link = "https://meet.google.com/abc-defg-hij";
    try conference.object.put(a, "entryPoints", try j.value(a, [_]struct { entryPointType: []const u8, uri: []const u8 }{.{ .entryPointType = "video", .uri = link }}));
    try event.object.put(a, "conferenceData", conference);
    try event.object.put(a, "hangoutLink", .{ .string = link });
}
