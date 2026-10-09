const std = @import("std");
const gmail = @import("gmail.zig");
const j = @import("json.zig");
const triage = @import("triage.zig");

const account = "synthetic@example.test";
const collection_url = "https://gmail.googleapis.com/gmail/v1/users/me/labels?fields=labels(id,name,type,color)";
const message_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1?format=minimal&fields=id,labelIds";
const modify_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify?fields=id,labelIds";

const Step = struct {
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
    response: []const u8,
};

/// The peer returns independent JSON wire examples. An unexpected collection,
/// message-body, send, or contacts request fails before a response is supplied.
const Peer = struct {
    steps: []const Step,
    calls: usize = 0,
    writes: usize = 0,

    fn transport(self: *Peer) gmail.Transport {
        return .{ .context = self, .requestFn = request };
    }

    fn request(context: *anyopaque, a: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?j.Value) !j.Value {
        const self: *Peer = @ptrCast(@alignCast(context));
        if (method != .GET) self.writes += 1;
        if (self.calls == self.steps.len) return error.UnexpectedTransportRequest;
        const step = self.steps[self.calls];
        self.calls += 1;
        try std.testing.expectEqual(step.method, method);
        try std.testing.expectEqualStrings(step.url, url);
        if (step.body) |expected| {
            try std.testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(a, body orelse return error.MissingRequestBody, .{}));
        } else try std.testing.expect(body == null);
        return std.json.parseFromSliceLeaky(j.Value, a, step.response, .{});
    }
};

fn expectStrings(expected: []const []const u8, value: j.Value) !void {
    try std.testing.expect(value == .array);
    try std.testing.expectEqual(expected.len, value.array.items.len);
    for (expected, value.array.items) |text, actual| try std.testing.expectEqualStrings(text, try j.string(actual));
}

test "live label metadata: provider colors do not invalidate label identities" {
    const Case = struct { field: []const u8, background: ?[]const u8 = null, foreground: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .field = "" },
        .{ .field = ",\"color\":null" },
        .{ .field = ",\"color\":{}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#4a86e8\"}" },
        .{ .field = ",\"color\":{\"textColor\":\"#ffffff\"}" },
        .{ .field = ",\"color\":\"blue\"" },
        .{ .field = ",\"color\":[]" },
        .{ .field = ",\"color\":{\"backgroundColor\":7,\"textColor\":\"#ffffff\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#gg0000\",\"textColor\":\"#ffffff\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#fff\",\"textColor\":\"#ffffff\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#4a86e8\",\"textColor\":\"#ffffff\"}", .background = "#4a86e8", .foreground = "#ffffff" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#123456\",\"textColor\":\"#abcdef\"}", .background = "#123456", .foreground = "#abcdef" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const wire = try std.fmt.allocPrint(a, "{s}{s}{s}", .{
            "{\"labels\":[{\"id\":\"Label_project\",\"name\":\"Project Ω\",\"type\":\"user\"",
            case.field,
            "},{\"id\":\"INBOX\",\"name\":\"INBOX\",\"type\":\"system\"}]}",
        });
        var peer: Peer = .{ .steps = &.{.{ .method = .GET, .url = collection_url, .response = wire }} };
        const result = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-read"}, peer.transport(), "labels.list", j.object(a));
        const labels = j.get(result, "labels") orelse return error.MissingLabels;
        try std.testing.expect(labels == .array);
        try std.testing.expectEqual(@as(usize, 2), labels.array.items.len);
        const project = labels.array.items[0];
        try std.testing.expectEqualStrings("Label_project", j.text(project, "id"));
        try std.testing.expectEqualStrings("Project Ω", j.text(project, "name"));
        try std.testing.expectEqualStrings("user", j.text(project, "type"));
        const color = j.get(project, "color") orelse .null;
        if (case.background) |background| {
            try std.testing.expectEqualStrings(background, j.text(color, "backgroundColor"));
            try std.testing.expectEqualStrings(case.foreground.?, j.text(color, "textColor"));
        } else try std.testing.expect(color == .null);
        try std.testing.expectEqualStrings("INBOX", j.text(labels.array.items[1], "id"));
        try std.testing.expectEqualStrings("INBOX", j.text(labels.array.items[1], "name"));
        try std.testing.expectEqualStrings("system", j.text(labels.array.items[1], "type"));
        try std.testing.expectEqual(@as(usize, 1), peer.calls);
        try std.testing.expectEqual(@as(usize, 0), peer.writes);
    }
}

test "live label metadata: empty message memberships accept omitted repeated fields" {
    for ([_]std.http.Method{ .GET, .POST }) |method| {
        for ([_][]const u8{ "{\"id\":\"m1\"}", "{\"id\":\"m1\",\"labelIds\":[]}" }) |wire| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const modifying = method == .POST;
            var peer: Peer = .{ .steps = &.{.{ .method = method, .url = if (modifying) modify_url else message_url, .body = if (modifying) "{\"addLabelIds\":[],\"removeLabelIds\":[\"STARRED\"]}" else null, .response = wire }} };
            const request = try j.value(a, .{ .messageId = "m1", .addLabels = [_][]const u8{}, .removeLabels = [_][]const u8{"STARRED"} });
            const result = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{ "mail-read", "mail-modify" }, peer.transport(), if (modifying) "mail.modify-labels" else "mail.labels", request);
            try std.testing.expectEqualStrings("m1", j.text(result, "messageId"));
            try expectStrings(&.{}, j.get(result, "labels") orelse return error.MissingLabels);
            try std.testing.expectEqual(@as(usize, 1), peer.calls);
            try std.testing.expectEqual(@as(usize, if (modifying) 1 else 0), peer.writes);
        }
    }
}

test "live label metadata: malformed memberships and wrong message identities remain errors" {
    const Case = struct { wire: []const u8, read_error: anyerror };
    const cases = [_]Case{
        .{ .wire = "{\"id\":\"another-message\",\"labelIds\":[]}", .read_error = error.MessageIdentityMismatch },
        .{ .wire = "{\"labelIds\":[]}", .read_error = error.MessageIdentityMismatch },
        .{ .wire = "{\"id\":\"m1\",\"labelIds\":null}", .read_error = error.InvalidProviderResponse },
        .{ .wire = "{\"id\":\"m1\",\"labelIds\":\"STARRED\"}", .read_error = error.InvalidProviderResponse },
        .{ .wire = "{\"id\":\"m1\",\"labelIds\":[7]}", .read_error = error.InvalidProviderResponse },
    };
    for ([_]std.http.Method{ .GET, .POST }) |method| {
        for (cases) |case| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const modifying = method == .POST;
            var peer: Peer = .{ .steps = &.{.{ .method = method, .url = if (modifying) modify_url else message_url, .body = if (modifying) "{\"addLabelIds\":[\"STARRED\"],\"removeLabelIds\":[]}" else null, .response = case.wire }} };
            const request = try j.value(a, .{ .messageId = "m1", .addLabels = [_][]const u8{"STARRED"}, .removeLabels = [_][]const u8{} });
            try std.testing.expectError(if (modifying) error.UnknownOutcome else case.read_error, gmail.dispatchAuthorized(std.testing.io, a, account, &.{ "mail-read", "mail-modify" }, peer.transport(), if (modifying) "mail.modify-labels" else "mail.labels", request));
            try std.testing.expectEqual(@as(usize, 1), peer.calls);
            try std.testing.expectEqual(@as(usize, if (modifying) 1 else 0), peer.writes);
        }
    }
}

test "live label metadata: invalid outbound colors never reach transport" {
    for ([_][]const u8{
        "null",
        "{}",
        "\"blue\"",
        "{\"backgroundColor\":\"#4a86e8\"}",
        "{\"backgroundColor\":\"#123456\",\"textColor\":\"#ffffff\"}",
        "{\"backgroundColor\":\"#4a86e8\",\"textColor\":\"#abcdef\"}",
        "{\"backgroundColor\":\"#gg0000\",\"textColor\":\"#ffffff\"}",
    }) |color| {
        for ([_][]const u8{ "labels.create", "labels.rename", "labels.color" }) |command| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const wire = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ "{\"labelId\":\"Label_project\",\"name\":\"Project Ω\",\"color\":", color, "}" });
            const request = try std.json.parseFromSliceLeaky(j.Value, a, wire, .{});
            var peer: Peer = .{ .steps = &.{} };
            try std.testing.expectError(error.InvalidLabelColor, gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-modify"}, peer.transport(), command, request));
            try std.testing.expectEqual(@as(usize, 0), peer.calls);
            try std.testing.expectEqual(@as(usize, 0), peer.writes);
        }
    }
}

test "live label metadata: system batch actions use only message membership endpoints" {
    const Case = struct {
        request: []const u8,
        before: []const u8,
        body: []const u8,
        after: []const u8,
        labels: []const []const u8,
    };
    const cases = [_]Case{
        .{
            .request = "{\"action\":\"mark\",\"starred\":true}",
            .before = "{\"id\":\"m1\"}",
            .body = "{\"addLabelIds\":[\"STARRED\"],\"removeLabelIds\":[]}",
            .after = "{\"id\":\"m1\",\"labelIds\":[\"STARRED\"]}",
            .labels = &.{"STARRED"},
        },
        .{
            .request = "{\"action\":\"mark\",\"starred\":false}",
            .before = "{\"id\":\"m1\",\"labelIds\":[\"STARRED\"]}",
            .body = "{\"addLabelIds\":[],\"removeLabelIds\":[\"STARRED\"]}",
            .after = "{\"id\":\"m1\"}",
            .labels = &.{},
        },
        .{
            .request = "{\"action\":\"archive\"}",
            .before = "{\"id\":\"m1\",\"labelIds\":[\"INBOX\",\"UNREAD\",\"Label_keep\"]}",
            .body = "{\"addLabelIds\":[],\"removeLabelIds\":[\"INBOX\"]}",
            .after = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\",\"Label_keep\"]}",
            .labels = &.{ "UNREAD", "Label_keep" },
        },
        .{
            .request = "{\"action\":\"mark\",\"unread\":false}",
            .before = "{\"id\":\"m1\",\"labelIds\":[\"UNREAD\",\"Label_keep\"]}",
            .body = "{\"addLabelIds\":[],\"removeLabelIds\":[\"UNREAD\"]}",
            .after = "{\"id\":\"m1\",\"labelIds\":[\"Label_keep\"]}",
            .labels = &.{"Label_keep"},
        },
        .{
            .request = "{\"action\":\"mark\",\"unread\":true}",
            .before = "{\"id\":\"m1\",\"labelIds\":[\"Label_keep\"]}",
            .body = "{\"addLabelIds\":[\"UNREAD\"],\"removeLabelIds\":[]}",
            .after = "{\"id\":\"m1\",\"labelIds\":[\"Label_keep\",\"UNREAD\"]}",
            .labels = &.{ "Label_keep", "UNREAD" },
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var peer: Peer = .{ .steps = &.{
            .{ .method = .GET, .url = message_url, .response = case.before },
            .{ .method = .POST, .url = modify_url, .body = case.body, .response = case.after },
        } };
        const request = try std.json.parseFromSliceLeaky(j.Value, a, case.request, .{});
        const delta = try gmail.resolveBatchLabels(a, peer.transport(), try triage.plan(a, request));
        // The first request must still be the selected message's GET: star,
        // unread, and archive never require the account's label collection.
        try std.testing.expectEqual(@as(usize, 0), peer.calls);
        const before = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-read"}, peer.transport(), "mail.labels", try j.value(a, .{ .messageId = "m1" }));
        try std.testing.expectEqualStrings("m1", j.text(before, "messageId"));
        const changed = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-modify"}, peer.transport(), "mail.modify-labels", try j.value(a, .{ .messageId = "m1", .addLabels = delta.add, .removeLabels = delta.remove }));
        try std.testing.expectEqualStrings("m1", j.text(changed, "messageId"));
        try expectStrings(case.labels, j.get(changed, "labels") orelse return error.MissingLabels);
        try std.testing.expectEqual(@as(usize, 2), peer.calls);
        try std.testing.expectEqual(@as(usize, 1), peer.writes);
    }
}

test "live label metadata: custom names resolve once despite unrelated provider colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var peer: Peer = .{ .steps = &.{.{
        .method = .GET,
        .url = "https://gmail.googleapis.com/gmail/v1/users/me/labels?fields=labels(id,name,type)",
        .response =
        \\{"labels":[
        \\{"id":"INBOX","name":"INBOX","type":"system"},
        \\{"id":"Label_project","name":"Project Ω","type":"user","color":{"backgroundColor":"#4a86e8"}},
        \\{"id":"Label_travel","name":"Travel","type":"user","color":{"backgroundColor":"#123456","textColor":"#abcdef"}},
        \\{"id":"Label_old","name":"Old","type":"user","color":null}
        \\]}
        ,
    }} };
    const delta = try gmail.resolveBatchLabels(a, peer.transport(), .{ .add = &.{ "STARRED", "Project Ω", "Travel" }, .remove = &.{ "INBOX", "Label_old" } });
    try expectStrings(&.{ "STARRED", "Label_project", "Label_travel" }, try j.value(a, delta.add));
    try expectStrings(&.{ "INBOX", "Label_old" }, try j.value(a, delta.remove));
    try std.testing.expectEqual(@as(usize, 1), peer.calls);
    try std.testing.expectEqual(@as(usize, 0), peer.writes);
}

test "live label metadata: invalid management preflight cannot dispatch a write" {
    for ([_][]const u8{ "{}", "null", "{\"unrelated\":[]}", "{\"labels\":null}", "{\"labels\":{}}", "{\"labels\":\"invalid\"}" }) |wire| {
        for ([_][]const u8{ "labels.create", "labels.rename", "labels.delete", "labels.color" }) |command| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const request = if (std.mem.eql(u8, command, "labels.create"))
                try j.value(a, .{ .name = "New project" })
            else if (std.mem.eql(u8, command, "labels.rename"))
                try j.value(a, .{ .labelId = "Label_project", .name = "Renamed project" })
            else if (std.mem.eql(u8, command, "labels.delete"))
                try j.value(a, .{ .labelId = "Label_project", .confirmName = "Project" })
            else
                try j.value(a, .{ .labelId = "Label_project", .color = .{ .backgroundColor = "#4a86e8", .textColor = "#ffffff" } });
            var peer: Peer = .{ .steps = &.{.{ .method = .GET, .url = collection_url, .response = wire }} };
            try std.testing.expectError(error.InvalidProviderResponse, gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-modify"}, peer.transport(), command, request));
            try std.testing.expectEqual(@as(usize, 1), peer.calls);
            try std.testing.expectEqual(@as(usize, 0), peer.writes);
        }
    }
}

test "live label metadata: rename and delete ignore malformed optional colors" {
    for ([_][]const u8{ "null", "{}", "\"blue\"", "{\"backgroundColor\":\"#4a86e8\"}", "{\"backgroundColor\":\"#gg0000\",\"textColor\":\"#ffffff\"}" }) |color| {
        for ([_]std.http.Method{ .PATCH, .DELETE }) |method| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const deleting = method == .DELETE;
            const definitions = try std.fmt.allocPrint(a, "{s}{s}{s}", .{
                "{\"labels\":[{\"id\":\"Label_project\",\"name\":\"Project Ω\",\"type\":\"user\",\"color\":",
                color,
                "},{\"id\":\"Label_unrelated\",\"name\":\"Unrelated\",\"type\":\"user\",\"color\":{}}]}",
            });
            const receipt = if (deleting) "null" else try std.fmt.allocPrint(a, "{s}{s}{s}", .{
                "{\"id\":\"Label_project\",\"name\":\"Renamed Ω\",\"type\":\"user\",\"color\":",
                color,
                "}",
            });
            // Collection operations must not dispatch separate message
            // membership mutations; DELETE itself has Gmail's label semantics.
            var peer: Peer = .{ .steps = &.{
                .{ .method = .GET, .url = collection_url, .response = definitions },
                .{ .method = method, .url = "https://gmail.googleapis.com/gmail/v1/users/me/labels/Label_project", .body = if (deleting) null else "{\"name\":\"Renamed Ω\"}", .response = receipt },
            } };
            const request = if (deleting)
                try j.value(a, .{ .labelId = "Label_project", .confirmName = "Project Ω" })
            else
                try j.value(a, .{ .labelId = "Label_project", .name = "Renamed Ω" });
            const result = try gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-modify"}, peer.transport(), if (deleting) "labels.delete" else "labels.rename", request);
            if (deleting) {
                try std.testing.expect(try j.boolean(result, "deleted", false));
                try std.testing.expectEqualStrings("Label_project", j.text(result, "labelId"));
            } else {
                const label = j.get(result, "label") orelse return error.MissingLabel;
                try std.testing.expectEqualStrings("Label_project", j.text(label, "id"));
                try std.testing.expectEqualStrings("Renamed Ω", j.text(label, "name"));
                try std.testing.expectEqualStrings("user", j.text(label, "type"));
                try std.testing.expect((j.get(label, "color") orelse .null) == .null);
            }
            try std.testing.expectEqual(@as(usize, 2), peer.calls);
            try std.testing.expectEqual(@as(usize, 1), peer.writes);
        }
    }
}

test "live label metadata: color writes require a matching provider acknowledgement" {
    const Case = struct { field: []const u8, matches: bool = false };
    const cases = [_]Case{
        .{ .field = "" },
        .{ .field = ",\"color\":null" },
        .{ .field = ",\"color\":\"blue\"" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#4a86e8\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#gg0000\",\"textColor\":\"#ffffff\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#fb4c2f\",\"textColor\":\"#ffffff\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#4a86e8\",\"textColor\":\"#000000\"}" },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#4a86e8\",\"textColor\":\"#ffffff\"}", .matches = true },
        .{ .field = ",\"color\":{\"backgroundColor\":\"#4A86E8\",\"textColor\":\"#FFFFFF\"}", .matches = true },
    };
    for ([_]std.http.Method{ .PATCH, .POST }) |method| {
        for (cases) |case| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const creating = method == .POST;
            const identifier = if (creating) "Label_created" else "Label_project";
            const name = if (creating) "New colored project" else "Project";
            const receipt = try std.fmt.allocPrint(a, "{s}{s}{s}", .{
                if (creating) "{\"id\":\"Label_created\",\"name\":\"New colored project\",\"type\":\"user\"" else "{\"id\":\"Label_project\",\"name\":\"Project\",\"type\":\"user\"",
                case.field,
                "}",
            });
            var peer: Peer = .{ .steps = &.{
                .{ .method = .GET, .url = collection_url, .response = "{\"labels\":[{\"id\":\"Label_project\",\"name\":\"Project\",\"type\":\"user\",\"color\":{}}]}" },
                .{
                    .method = method,
                    .url = if (creating) "https://gmail.googleapis.com/gmail/v1/users/me/labels" else "https://gmail.googleapis.com/gmail/v1/users/me/labels/Label_project",
                    .body = if (creating) "{\"name\":\"New colored project\",\"color\":{\"backgroundColor\":\"#4a86e8\",\"textColor\":\"#ffffff\"}}" else "{\"color\":{\"backgroundColor\":\"#4a86e8\",\"textColor\":\"#ffffff\"}}",
                    .response = receipt,
                },
            } };
            const request = if (creating)
                try j.value(a, .{ .name = "New colored project", .color = .{ .backgroundColor = "#4a86e8", .textColor = "#ffffff" } })
            else
                try j.value(a, .{ .labelId = "Label_project", .color = .{ .backgroundColor = "#4a86e8", .textColor = "#ffffff" } });
            const result = gmail.dispatchAuthorized(std.testing.io, a, account, &.{"mail-modify"}, peer.transport(), if (creating) "labels.create" else "labels.color", request);
            if (case.matches) {
                const label = j.get(try result, "label") orelse return error.MissingLabel;
                try std.testing.expectEqualStrings(identifier, j.text(label, "id"));
                try std.testing.expectEqualStrings(name, j.text(label, "name"));
                try std.testing.expectEqualStrings("user", j.text(label, "type"));
                const color = j.get(label, "color") orelse return error.MissingColor;
                try std.testing.expect(std.ascii.eqlIgnoreCase("#4a86e8", j.text(color, "backgroundColor")));
                try std.testing.expect(std.ascii.eqlIgnoreCase("#ffffff", j.text(color, "textColor")));
            } else try std.testing.expectError(error.UnknownOutcome, result);
            try std.testing.expectEqual(@as(usize, 2), peer.calls);
            try std.testing.expectEqual(@as(usize, 1), peer.writes);
        }
    }
}
