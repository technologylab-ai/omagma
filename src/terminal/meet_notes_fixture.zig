//! Persistent synthetic Meet service, separate from the production decoder.
//! Fixture accounts/counters are private and cannot contact Google.
const std = @import("std");
const j = @import("json.zig");
const p = @import("meet_notes_provider.zig");
const service = @import("meet_notes_service.zig");
const calendar = @import("calendar_service.zig");
const storage = @import("store.zig");

pub const document_name = "meet-provider-fixture.json";
const Config = @import("calendar_fixture.zig").Config;
const Space = struct { code: []const u8, name: []const u8, notes: bool = false, transcription: bool = false };
const State = struct { schema: u8 = 1, account: []const u8, patch_attempts: u64 = 0, writes: u64 = 0, reads: u64 = 0, spaces: []Space = &.{} };

pub fn enabled(scenario: []const u8) bool {
    return std.mem.startsWith(u8, scenario, "meet-") and !std.mem.eql(u8, scenario, "meet-no-permission");
}
pub const Provider = struct {
    config: Config,
    pub fn transport(self: *Provider) service.Transport {
        return .{ .context = self, .sendFn = send };
    }
    fn send(context: *anyopaque, out: std.mem.Allocator, request: p.Request) anyerror!calendar.Response {
        const self: *Provider = @ptrCast(@alignCast(context));
        if (!self.config.options.fixtures) return error.FixtureOnly;
        if (!std.ascii.eqlIgnoreCase(request.account, self.config.account)) return error.CalendarAccountMismatch;
        if (!enabled(self.config.options.fixture_scenario)) return error.MeetSettingsPermissionRequired;
        var arena = std.heap.ArenaAllocator.init(self.config.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var store = try self.config.access.open(self.config.io, a, self.config.root, self.config.account, self.config.options, false);
        defer store.close();
        var state = if (try store.readDocument(a, document_name, 512 * 1024)) |raw| try std.json.parseFromSliceLeaky(State, a, raw, .{ .allocate = .alloc_if_needed }) else State{ .account = self.config.account };
        if (state.schema != 1 or !std.mem.eql(u8, state.account, self.config.account) or state.spaces.len > 256) return error.InvalidFixtureState;
        const scenario = self.config.options.fixture_scenario;
        if (std.mem.eql(u8, scenario, "meet-read-unavailable")) return error.ConnectionRefused;
        if (std.mem.eql(u8, scenario, "meet-read-dropped")) return error.HttpConnectionClosing;
        if (std.mem.eql(u8, scenario, "meet-settings-revoked") and request.kind != .configure) return failure(out, self.config.account, 401, "authError", "Synthetic revoked Meet settings access.");
        if (std.mem.eql(u8, scenario, "meet-api-disabled")) return failure(out, self.config.account, 403, "accessNotConfigured", "Google Meet API is disabled for this synthetic project.");
        if (!std.mem.startsWith(u8, request.url, p.base_url ++ "spaces/")) return error.InvalidMeetPath;
        const tail = request.url[(p.base_url ++ "spaces/").len..];
        const id = tail[0 .. std.mem.indexOfScalar(u8, tail, '?') orelse tail.len];
        var selected: ?usize = null;
        for (state.spaces, 0..) |space, index| {
            if ((request.kind == .resolve and std.mem.eql(u8, space.code, id)) or (request.kind != .resolve and std.mem.eql(u8, space.name["spaces/".len..], id))) {
                selected = index;
                break;
            }
        }
        if (selected == null and request.kind == .resolve) {
            try p.validateCode(id);
            if (state.spaces.len == 256) return error.FixtureProviderFull;
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(id, &hash, .{});
            const hex = std.fmt.bytesToHex(hash, .lower);
            const expanded = try a.alloc(Space, state.spaces.len + 1);
            @memcpy(expanded[0..state.spaces.len], state.spaces);
            expanded[state.spaces.len] = .{ .code = try a.dupe(u8, id), .name = try std.fmt.allocPrint(a, "spaces/fixture_{s}", .{hex[0..16]}) };
            selected = state.spaces.len;
            state.spaces = expanded;
        }
        const index = selected orelse return failure(out, self.config.account, 404, "notFound", "Synthetic Meet space not found.");
        if (request.kind == .configure) {
            if (request.method != .PATCH or request.body == null) return error.InvalidMeetRequest;
            state.patch_attempts += 1;
            try store.writeDocument(document_name, try j.encodeAlloc(a, state, .{}));
            if (std.mem.eql(u8, scenario, "meet-rejected")) return failure(out, self.config.account, 403, "notesDisabledByPolicy", "The synthetic organizer policy refuses AI notes.");
            if (std.mem.eql(u8, scenario, "meet-unapplied-unknown") and state.patch_attempts == 1) return error.ConnectionResetByPeer;
            const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
            if (!std.mem.eql(u8, j.text(body, "name"), state.spaces[index].name)) return error.MeetSpaceMismatch;
            const artifacts = j.get(j.get(body, "config") orelse return error.InvalidMeetRequest, "artifactConfig") orelse return error.InvalidMeetRequest;
            if (j.get(artifacts, "recordingConfig") != null or (artifacts.object.count() != 1 and artifacts.object.count() != 2)) return error.InvalidMeetRequest;
            const notes = j.text(j.get(artifacts, "smartNotesConfig") orelse return error.InvalidMeetRequest, "autoSmartNotesGeneration");
            if (!std.mem.eql(u8, notes, "ON") and !std.mem.eql(u8, notes, "OFF")) return error.InvalidMeetRequest;
            const on = std.mem.eql(u8, notes, "ON");
            if (!std.mem.endsWith(u8, request.url, if (on) p.update_mask else p.notes_mask)) return error.InvalidMeetRequest;
            state.spaces[index].notes = on;
            if (on) {
                if (!std.mem.eql(u8, j.text(j.get(artifacts, "transcriptionConfig") orelse return error.InvalidMeetRequest, "autoTranscriptionGeneration"), "ON")) return error.InvalidMeetRequest;
                state.spaces[index].transcription = true;
            } else if (j.get(artifacts, "transcriptionConfig") != null) return error.InvalidMeetRequest;
            state.writes += 1;
            try store.writeDocument(document_name, try j.encodeAlloc(a, state, .{}));
            if (std.mem.eql(u8, scenario, "meet-lost-response")) return error.ConnectionResetByPeer;
            if (std.mem.eql(u8, scenario, "meet-malformed-response")) return response(out, self.config.account, 200, try j.value(a, .{ .name = "spaces/wrong_identity" }));
        } else {
            if (request.method != .GET or request.body != null) return error.InvalidMeetRequest;
            state.reads += 1;
            try store.writeDocument(document_name, try j.encodeAlloc(a, state, .{}));
        }
        const space = state.spaces[index];
        return response(out, self.config.account, 200, try j.value(a, .{ .name = space.name, .meetingCode = space.code, .meetingUri = try std.fmt.allocPrint(a, "https://meet.google.com/{s}", .{space.code}), .config = .{ .artifactConfig = .{ .smartNotesConfig = .{ .autoSmartNotesGeneration = if (space.notes) @as([]const u8, "ON") else "OFF" }, .transcriptionConfig = .{ .autoTranscriptionGeneration = if (space.transcription) @as([]const u8, "ON") else "OFF" }, .recordingConfig = .{ .autoRecordingGeneration = "OFF" } } } }));
    }
};
fn response(a: std.mem.Allocator, account: []const u8, status: u16, value: j.Value) !calendar.Response {
    return .{ .account = account, .status = status, .body = try j.encodeAlloc(a, value, .{}) };
}
fn failure(a: std.mem.Allocator, account: []const u8, status: u16, reason: []const u8, message: []const u8) !calendar.Response {
    return response(a, account, status, try j.value(a, .{ .@"error" = .{ .code = status, .message = message, .errors = [_]struct { reason: []const u8, message: []const u8 }{.{ .reason = reason, .message = message }} } }));
}
