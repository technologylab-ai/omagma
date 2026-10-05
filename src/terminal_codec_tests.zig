const std = @import("std");
test {
    std.testing.refAllDecls(@import("terminal/recipients.zig"));
    std.testing.refAllDecls(@import("terminal/mime.zig"));
    std.testing.refAllDecls(@import("terminal/invitation.zig"));
    std.testing.refAllDecls(@import("terminal/gmail_decode.zig"));
}

test "synthetic Gmail corpus normalizes all account-scoped full payloads" {
    const codec = @import("terminal/gmail_decode.zig");
    for ([_][]const u8{ "personal", "work", "optional" }) |account| {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        const allocator = source_arena.allocator();
        const file = try std.fmt.allocPrint(allocator, "tests/fixtures/terminal/accounts/{s}.json", .{account});
        const storage = try allocator.alloc(u8, 512 * 1024);
        const text = try std.Io.Dir.cwd().readFile(std.testing.io, file, storage);
        try std.testing.expect(text.len < storage.len);
        const source = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        const messages = source.value.object.get("messages").?.array.items;
        try std.testing.expectEqual(@as(usize, 96), messages.len);
        for (messages) |message| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const normalized = try codec.normalize(message, arena.allocator(), source.value.object.get("externalBodies"));
            try std.testing.expect(normalized.bodyText.len > 0 or normalized.invitation != null);
            try std.testing.expect(std.unicode.utf8ValidateSlice(normalized.bodyText));
            if (std.mem.eql(u8, normalized.id, "shared-msg-001") or std.mem.eql(u8, normalized.id, "shared-msg-010")) {
                try std.testing.expect(std.mem.indexOf(u8, normalized.bodyText, "Literal =3D stays =3D.") != null);
            }
            if (std.mem.eql(u8, normalized.id, "shared-msg-003")) {
                try std.testing.expectEqualStrings("escape.txt", normalized.attachments[0].filename);
                try std.testing.expect(std.unicode.utf8ValidateSlice(normalized.attachments[0].data));
                const bytes = try @import("terminal/mime.zig").decodeBase64Url(normalized.attachments[0].data, arena.allocator());
                try std.testing.expectEqual(@as(usize, 72), bytes.len);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                var digest_text: [64]u8 = undefined;
                try std.testing.expectEqualStrings("1bd24f97a991cc5232c8b42a518a75b0a87d1df7e4bc18d0406141bf98d1ac34", try std.fmt.bufPrint(&digest_text, "{x}", .{&digest}));
            }
            if (std.mem.eql(u8, normalized.id, "shared-msg-008") or std.mem.eql(u8, normalized.id, "shared-msg-009")) {
                var invitation: @import("terminal/invitation.zig").Invitation = .{};
                const address = try std.fmt.allocPrint(arena.allocator(), "{s}@example.com", .{account});
                try @import("terminal/invitation.zig").parse(normalized.invitation.?, address, &.{}, &invitation);
            }
        }
    }
}

test "synthetic MIME limit corpus fails with explicit bounded errors" {
    const mime = @import("terminal/mime.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const storage = try a.alloc(u8, 256 * 1024);
    const source = try std.Io.Dir.cwd().readFile(std.testing.io, "tests/fixtures/terminal/mime-limits.json", storage);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    const cases = parsed.value.object.get("cases").?.object;
    const Case = struct { name: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .name = "declaredBodyOver2MiB", .expected = error.BodyTooLarge },
        .{ .name = "sizeMismatch", .expected = error.BodySizeMismatch },
        .{ .name = "unsupportedCharset", .expected = error.UnsupportedCharset },
        .{ .name = "depth33", .expected = error.MimeTooDeep },
        .{ .name = "parts513", .expected = error.TooManyMimeParts },
    }) |case| {
        var object: std.json.ObjectMap = .empty;
        try object.put(a, "payload", cases.get(case.name).?);
        try std.testing.expectError(case.expected, mime.parseGmail(.{ .object = object }, a));
    }
}
