//! Google Meet automatic notes protocol. No credentials, persistence or I/O.
//! Calendar conference data supplies the meeting code; resolve it once to a
//! canonical space name before changing settings. Never PATCH a reusable code.
const std = @import("std");
const j = @import("json.zig");
const bounded = @import("../bounded.zig");

pub const scope = "https://www.googleapis.com/auth/meetings.space.settings";
pub const base_url = "https://meet.googleapis.com/v2/";
pub const max_response_bytes = 64 * 1024;
pub const notes_mask = "config.artifactConfig.smartNotesConfig.autoSmartNotesGeneration";
pub const update_mask = notes_mask ++ ",config.artifactConfig.transcriptionConfig.autoTranscriptionGeneration";

pub const Auto = enum { unspecified, on, off };
pub const Space = struct {
    name: []const u8,
    code: []const u8,
    notes: Auto,
    transcription: Auto,

    pub fn matches(self: Space, enabled: bool) bool {
        const expected: Auto = if (enabled) .on else .off;
        return self.notes == expected and (!enabled or self.transcription == .on);
    }
};
pub const Link = struct { event_id: []const u8, etag: []const u8, code: []const u8 };
pub const Kind = enum { resolve, read, configure };
pub const Request = struct {
    account: []const u8,
    kind: Kind,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
};

pub fn recurring(event: j.Value) bool {
    if (j.text(event, "recurringEventId").len != 0) return true;
    if (j.get(event, "originalStartTime")) |point| if (point != .null) return true;
    if (j.get(event, "recurrence")) |rules| {
        if (rules == .null) return false;
        return rules != .array or rules.array.items.len != 0;
    }
    return false;
}

pub fn validateCode(code: []const u8) !void {
    if (code.len == 0 or code.len > 128) return error.InvalidMeetCode;
    var segments = std.mem.splitScalar(u8, code, '-');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidMeetCode;
        for (segment) |byte| if (byte < 'a' or byte > 'z') return error.InvalidMeetCode;
        count += 1;
    }
    if (count != 3) return error.InvalidMeetCode;
}

pub fn validateName(name: []const u8) !void {
    const prefix = "spaces/";
    if (!std.mem.startsWith(u8, name, prefix) or name.len <= prefix.len or name.len > 256) return error.InvalidMeetSpace;
    for (name[prefix.len..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidMeetSpace;
}

fn codeFromUri(a: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const prefix = "https://meet.google.com/";
    if (!std.mem.startsWith(u8, uri, prefix) or uri.len > 4096) return error.InvalidMeetLink;
    const tail = uri[prefix.len..];
    const end = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
    const code = try std.ascii.allocLowerString(a, tail[0..end]);
    try validateCode(code);
    // Even ignored cosmetic query/fragment bytes must be safe literal text.
    for (uri) |byte| if (byte <= 32 or byte == 127) return error.InvalidMeetLink;
    return code;
}

/// This intentionally reads raw, freshly fetched Calendar JSON. Adding Meet
/// presentation fields to the persisted Calendar Event/Review shapes would
/// change historical review hashes and is not necessary to bind this action.
pub fn calendarLink(a: std.mem.Allocator, account: []const u8, event_id: []const u8, event: j.Value) !Link {
    try bounded.address(account);
    if (event != .object or !std.mem.eql(u8, j.text(event, "id"), event_id) or event_id.len == 0 or event_id.len > 1024) return error.MeetEventMismatch;
    const organizer = j.get(event, "organizer") orelse return error.MeetOrganizerRequired;
    if (!std.ascii.eqlIgnoreCase(j.text(organizer, "email"), account)) return error.MeetOrganizerRequired;
    if (std.mem.eql(u8, j.text(event, "status"), "cancelled")) return error.MeetEventCancelled;
    if (recurring(event)) return error.MeetRecurringSpace;
    if (j.text(event, "eventType").len != 0 and !std.mem.eql(u8, j.text(event, "eventType"), "default")) return error.MeetEventUnsupported;
    const etag = try j.required(event, "etag");
    if (etag.len > 1024) return error.MeetEventMismatch;
    const conference = j.get(event, "conferenceData") orelse return error.MeetConferencePending;
    if (j.get(conference, "createRequest")) |creation| if (j.get(creation, "status")) |status| {
        if (std.mem.eql(u8, j.text(status, "statusCode"), "pending")) return error.MeetConferencePending;
        if (std.mem.eql(u8, j.text(status, "statusCode"), "failure")) return error.MeetConferenceFailed;
    };
    const solution = j.get(conference, "conferenceSolution") orelse return error.MeetConferenceUnsupported;
    const key = j.get(solution, "key") orelse return error.MeetConferenceUnsupported;
    if (!std.mem.eql(u8, j.text(key, "type"), "hangoutsMeet")) return error.MeetConferenceUnsupported;
    const points = j.get(conference, "entryPoints") orelse return error.MeetConferencePending;
    if (points != .array or points.array.items.len > 32) return error.InvalidMeetLink;
    var result: ?[]const u8 = null;
    for (points.array.items) |point| {
        if (!std.mem.eql(u8, j.text(point, "entryPointType"), "video")) continue;
        const code = try codeFromUri(a, try j.required(point, "uri"));
        if (result) |existing| {
            if (!std.mem.eql(u8, existing, code)) return error.MeetEventMismatch;
        } else result = code;
    }
    const code = result orelse return error.MeetConferencePending;
    if (j.text(conference, "conferenceId").len != 0 and !std.ascii.eqlIgnoreCase(j.text(conference, "conferenceId"), code)) return error.MeetEventMismatch;
    if (j.text(event, "hangoutLink").len != 0) {
        const alternate = try codeFromUri(a, j.text(event, "hangoutLink"));
        if (!std.mem.eql(u8, alternate, code)) return error.MeetEventMismatch;
    }
    return .{ .event_id = try a.dupe(u8, event_id), .etag = try a.dupe(u8, etag), .code = code };
}

pub fn resolve(a: std.mem.Allocator, account: []const u8, code: []const u8) !Request {
    try bounded.address(account);
    try validateCode(code);
    return .{ .account = account, .kind = .resolve, .method = .GET, .url = try std.fmt.allocPrint(a, "{s}spaces/{s}", .{ base_url, code }) };
}
pub fn read(a: std.mem.Allocator, account: []const u8, name: []const u8) !Request {
    try bounded.address(account);
    try validateName(name);
    return .{ .account = account, .kind = .read, .method = .GET, .url = try std.fmt.allocPrint(a, "{s}{s}", .{ base_url, name }) };
}
pub fn configure(a: std.mem.Allocator, account: []const u8, name: []const u8, enabled: bool) !Request {
    try bounded.address(account);
    try validateName(name);
    return .{
        .account = account,
        .kind = .configure,
        .method = .PATCH,
        .url = try std.fmt.allocPrint(a, "{s}{s}?updateMask={s}", .{ base_url, name, if (enabled) update_mask else notes_mask }),
        // Turning AI notes off must not stop independently enabled transcripts.
        .body = if (enabled) try j.encodeAlloc(a, .{ .name = name, .config = .{ .artifactConfig = .{ .smartNotesConfig = .{ .autoSmartNotesGeneration = "ON" }, .transcriptionConfig = .{ .autoTranscriptionGeneration = "ON" } } } }, .{}) else try j.encodeAlloc(a, .{ .name = name, .config = .{ .artifactConfig = .{ .smartNotesConfig = .{ .autoSmartNotesGeneration = "OFF" } } } }, .{}),
    };
}

fn auto(value: j.Value, field: []const u8) !Auto {
    const raw = j.get(value, field) orelse return .unspecified;
    if (raw != .string) return error.InvalidMeetSettings;
    if (std.mem.eql(u8, raw.string, "ON")) return .on;
    if (std.mem.eql(u8, raw.string, "OFF")) return .off;
    if (std.mem.eql(u8, raw.string, "AUTO_GENERATION_TYPE_UNSPECIFIED")) return .unspecified;
    return error.InvalidMeetSettings;
}

pub fn decode(a: std.mem.Allocator, body: []const u8, expected_code: []const u8, expected_name: ?[]const u8) !Space {
    if (body.len > max_response_bytes) return error.MeetResponseTooLarge;
    try validateCode(expected_code);
    const value = try std.json.parseFromSliceLeaky(j.Value, a, body, .{});
    const name = try j.required(value, "name");
    try validateName(name);
    if (expected_name) |expected| if (!std.mem.eql(u8, name, expected)) return error.MeetSpaceMismatch;
    const code = try j.required(value, "meetingCode");
    try validateCode(code);
    if (!std.mem.eql(u8, code, expected_code)) return error.MeetSpaceMismatch;
    const uri_code = try codeFromUri(a, try j.required(value, "meetingUri"));
    if (!std.mem.eql(u8, code, uri_code)) return error.MeetSpaceMismatch;
    const config = j.get(value, "config") orelse j.object(a);
    const artifacts = j.get(config, "artifactConfig") orelse j.object(a);
    const notes = j.get(artifacts, "smartNotesConfig") orelse j.object(a);
    const transcription = j.get(artifacts, "transcriptionConfig") orelse j.object(a);
    return .{ .name = name, .code = code, .notes = try auto(notes, "autoSmartNotesGeneration"), .transcription = try auto(transcription, "autoTranscriptionGeneration") };
}

test "meet notes: narrow exact patch enables both independent features" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try configure(a, "self@example.test", "spaces/canonical_A2", true);
    try std.testing.expectEqual(std.http.Method.PATCH, request.method);
    try std.testing.expectEqualStrings(base_url ++ "spaces/canonical_A2?updateMask=" ++ update_mask, request.url);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    try std.testing.expectEqualStrings("spaces/canonical_A2", j.text(body, "name"));
    const config = j.get(body, "config").?;
    try std.testing.expectEqual(@as(usize, 1), config.object.count());
    const artifacts = j.get(config, "artifactConfig").?;
    try std.testing.expectEqual(@as(usize, 2), artifacts.object.count());
    try std.testing.expectEqualStrings("ON", j.text(j.get(artifacts, "smartNotesConfig").?, "autoSmartNotesGeneration"));
    try std.testing.expectEqualStrings("ON", j.text(j.get(artifacts, "transcriptionConfig").?, "autoTranscriptionGeneration"));
    try std.testing.expect(j.get(artifacts, "recordingConfig") == null);
}

test "meet notes: disabling notes preserves independent transcription and recording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try configure(a, "self@example.test", "spaces/canonical_A2", false);
    try std.testing.expectEqualStrings(base_url ++ "spaces/canonical_A2?updateMask=" ++ notes_mask, request.url);
    const body = try std.json.parseFromSliceLeaky(j.Value, a, request.body.?, .{});
    const artifacts = j.get(j.get(body, "config").?, "artifactConfig").?;
    try std.testing.expectEqual(@as(usize, 1), artifacts.object.count());
    try std.testing.expectEqualStrings("OFF", j.text(j.get(artifacts, "smartNotesConfig").?, "autoSmartNotesGeneration"));
    try std.testing.expect(j.get(artifacts, "transcriptionConfig") == null and j.get(artifacts, "recordingConfig") == null);
    try std.testing.expect((Space{ .name = "spaces/canonical_A2", .code = "abc-defg-hij", .notes = .off, .transcription = .on }).matches(false));
}

test "meet notes: exact space and meeting binding precedes a positive claim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "{\"name\":\"spaces/canonical_A2\",\"meetingCode\":\"abc-defg-hij\",\"meetingUri\":\"https://meet.google.com/abc-defg-hij\",\"config\":{\"artifactConfig\":{\"smartNotesConfig\":{\"autoSmartNotesGeneration\":\"ON\"},\"transcriptionConfig\":{\"autoTranscriptionGeneration\":\"OFF\"}}}}";
    const space = try decode(a, raw, "abc-defg-hij", "spaces/canonical_A2");
    try std.testing.expect(!space.matches(true));
    try std.testing.expect(!space.matches(false));
    try std.testing.expectError(error.MeetSpaceMismatch, decode(a, raw, "abc-defg-hij", "spaces/reused_code_target"));
    try std.testing.expectError(error.MeetSpaceMismatch, decode(a, raw, "klm-nopq-rst", null));
}

test "meet notes: omitted settings stay unconfirmed and path injection is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "{\"name\":\"spaces/canonical_A2\",\"meetingCode\":\"abc-defg-hij\",\"meetingUri\":\"https://meet.google.com/abc-defg-hij\"}";
    const space = try decode(a, raw, "abc-defg-hij", null);
    try std.testing.expectEqual(Auto.unspecified, space.notes);
    try std.testing.expect(!space.matches(true));
    for ([_][]const u8{ "spaces/../other", "spaces/name?updateMask=*", "https://evil.example.test/space", "spaces/name/extra", "spaces/" }) |name| try std.testing.expectError(error.InvalidMeetSpace, read(a, "self@example.test", name));
    for ([_][]const u8{ "ABC-defg-hij", "abc-defg-hij?x", "abc/defg/hij" }) |code| try std.testing.expectError(error.InvalidMeetCode, resolve(a, "self@example.test", code));
    try validateCode("a-b-c");
    try validateCode("longer-segments-permitted");
    for ([_][]const u8{ "abc--def", "-abc-def", "abc-def-", "abc-def", "a-b-c-d" }) |code| try std.testing.expectError(error.InvalidMeetCode, validateCode(code));
}
