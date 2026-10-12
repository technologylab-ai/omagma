//! The per-message mailbox transaction, shared by native durable storage and
//! the browser's bounded journal. Adapters provide storage and transport only.
const std = @import("std");
const triage = @import("triage.zig");
const storage = @import("store.zig");

pub const Hooks = struct {
    context: *anyopaque,
    labelsFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const []const u8,
    prepareFn: *const fn (*anyopaque, []const u8, []const []const u8, triage.Delta, bool) anyerror!void,
    modifyFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const []const u8, triage.Delta) anyerror![]const []const u8,
    commitFn: *const fn (*anyopaque, bool, ?[]const []const u8, ?anyerror, bool) anyerror!void,
    submittedFn: ?*const fn (*anyopaque) bool = null,
};

pub fn knownRejection(err: anyerror) bool {
    return switch (err) {
        error.ProviderRejected, error.PermissionDenied, error.NotConnected, error.InvalidGrant, error.MessageNotFound, error.RateLimited, error.InvalidLabel, error.LabelNotFound, error.TooManyLabels, error.InvalidIdentifier, error.WrongAccount, error.GrantClientMismatch => true,
        else => false,
    };
}

pub fn canUndo(item: storage.UndoItem) bool {
    return std.mem.eql(u8, item.outcome, "applied") and !item.restored and !std.mem.eql(u8, item.errorCode, "UnknownOutcome");
}

pub const Summary = struct { appliedCount: usize = 0, restoredCount: usize = 0, partial: bool = false };

pub fn summarize(items: []const storage.UndoItem) Summary {
    var summary: Summary = .{};
    for (items) |item| {
        if (std.mem.eql(u8, item.outcome, "applied")) summary.appliedCount += 1;
        if (item.restored) summary.restoredCount += 1;
        // An unsuccessful undo preserves the original applied outcome. Its
        // separate failure must remain visible in the aggregate receipt.
        summary.partial = summary.partial or item.errorCode.len != 0;
    }
    summary.partial = summary.partial or summary.appliedCount != items.len;
    return summary;
}

pub fn run(hooks: Hooks, a: std.mem.Allocator, id: []const u8, delta: triage.Delta, undoing: bool) !void {
    const actual = hooks.labelsFn(hooks.context, a, id) catch |err| {
        try hooks.commitFn(hooks.context, undoing, null, err, true);
        return;
    };
    if (actual.len > 64) {
        try hooks.commitFn(hooks.context, undoing, null, error.TooManyLabels, true);
        return;
    }
    const before = a.alloc([]const u8, actual.len) catch |err| {
        try hooks.commitFn(hooks.context, undoing, null, err, true);
        return;
    };
    for (actual, before) |label, *copy| copy.* = a.dupe(u8, label) catch |err| {
        try hooks.commitFn(hooks.context, undoing, null, err, true);
        return;
    };
    if (delta.add.len + delta.remove.len == 0) {
        try hooks.commitFn(hooks.context, undoing, before, null, false);
        return;
    }
    // Persist the exact inverse and uncertainty before the provider boundary.
    hooks.prepareFn(hooks.context, id, before, delta, undoing) catch |err| {
        try hooks.commitFn(hooks.context, undoing, null, err, true);
        return;
    };
    const updated = hooks.modifyFn(hooks.context, a, id, before, delta) catch |err| {
        const preflight = if (hooks.submittedFn) |submitted| !submitted(hooks.context) else false;
        try hooks.commitFn(hooks.context, undoing, null, err, preflight);
        return;
    };
    hooks.commitFn(hooks.context, undoing, updated, null, false) catch return error.UnknownOutcome;
}
