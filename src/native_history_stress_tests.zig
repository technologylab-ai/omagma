//! Long retained-history lifecycles have a mandatory native target and a
//! separate bounded per-test deadline. The build filter excludes imported
//! ordinary tests. Runtime selection lets shards reuse the same compiled binary.
const std = @import("std");
const mail = @import("session_cache_integration_tests.zig");
const calendar = @import("calendar_identity_history_tests.zig");

const HistoryCase = enum { all, calendar, @"sends-plain", @"sends-vault", @"files-plain", @"files-vault" };

fn selectedValue(raw: []const u8, expected: HistoryCase) !void {
    const actual = std.meta.stringToEnum(HistoryCase, raw) orelse return error.InvalidHistoryCase;
    if (actual != .all and actual != expected) return error.SkipZigTest;
}

fn selected(expected: HistoryCase) !void {
    try selectedValue(std.testing.environ.getPosix("OMAGMA_HISTORY_CASE") orelse "all", expected);
}

test "native history stress: 1001 Calendar imports retain revisions and cancelled fences in both stores" {
    try selected(.calendar);
    try calendar.thousandCalendarIdentityScenario();
}

test "native history stress: 1001 production sends survive restart and replay in plaintext" {
    try selected(.@"sends-plain");
    try mail.retainedSendLifecycle(false, false);
}

test "native history stress: 1001 production sends survive restart and replay in encrypted vault" {
    try selected(.@"sends-vault");
    try mail.retainedSendLifecycle(true, false);
}

test "native history stress: 4097 distinct files pass six production sends and shared pin cleanup in plaintext" {
    try selected(.@"files-plain");
    try mail.retainedSendLifecycle(false, true);
}

test "native history stress: 4097 distinct files pass six production sends and shared pin cleanup in encrypted vault" {
    try selected(.@"files-vault");
    try mail.retainedSendLifecycle(true, true);
}

test "native history selector: all admits every lifecycle and each shard admits exactly one" {
    const cases = [_]struct { raw: []const u8, case: HistoryCase }{
        .{ .raw = "calendar", .case = .calendar },
        .{ .raw = "sends-plain", .case = .@"sends-plain" },
        .{ .raw = "sends-vault", .case = .@"sends-vault" },
        .{ .raw = "files-plain", .case = .@"files-plain" },
        .{ .raw = "files-vault", .case = .@"files-vault" },
    };
    for (cases) |choice| {
        var passed: usize = 0;
        var skipped: usize = 0;
        for (cases) |candidate| {
            try selectedValue("all", candidate.case);
            selectedValue(choice.raw, candidate.case) catch |err| switch (err) {
                error.SkipZigTest => {
                    skipped += 1;
                    continue;
                },
                else => return err,
            };
            try std.testing.expectEqual(choice.case, candidate.case);
            passed += 1;
        }
        try std.testing.expectEqual(1, passed);
        try std.testing.expectEqual(4, skipped);
    }
}

test "native history selector: invalid values fail every lifecycle instead of skipping all" {
    for ([_][]const u8{ "", "unknown", "Calendar", "sends", "files-plain ", "ALL" }) |invalid| {
        for ([_]HistoryCase{ .calendar, .@"sends-plain", .@"sends-vault", .@"files-plain", .@"files-vault" }) |case| {
            try std.testing.expectError(error.InvalidHistoryCase, selectedValue(invalid, case));
        }
    }
}
