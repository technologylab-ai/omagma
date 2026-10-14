//! Embedded public JSONL contract; discovery never starts a mail session.
const std = @import("std");
const j = @import("json.zig");
const Value = j.Value;
const read_source = @embedFile("cli_api_read.json");
const write_source = @embedFile("cli_api_write.json");
const calendar_source = @embedFile("cli_api_calendar.json");
comptime {
    if (read_source.len + write_source.len + calendar_source.len > 512 * 1024) @compileError("CLI discovery metadata exceeds its bound");
}
pub const Catalogue = struct {
    commands: []Value,
    definitions: Value,
    fn find(self: Catalogue, name: []const u8) ?Value {
        for (self.commands) |entry| if (std.mem.eql(u8, j.text(entry, "cmd"), name)) return entry;
        return null;
    }
};
pub fn load(a: std.mem.Allocator) !Catalogue {
    var commands: std.ArrayList(Value) = .empty;
    var definitions = j.object(a);
    for ([_][]const u8{ read_source, write_source, calendar_source }) |bytes| {
        const part = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = 65536 });
        const entries = j.get(part, "commands") orelse return error.InvalidDiscoveryMetadata;
        if (entries != .array) return error.InvalidDiscoveryMetadata;
        try commands.appendSlice(a, entries.array.items);
        const defs = j.get(part, "$defs") orelse return error.InvalidDiscoveryMetadata;
        if (defs != .object) return error.InvalidDiscoveryMetadata;
        var it = defs.object.iterator();
        while (it.next()) |field| {
            if (definitions.object.contains(field.key_ptr.*)) return error.InvalidDiscoveryMetadata;
            try definitions.object.put(a, field.key_ptr.*, field.value_ptr.*);
        }
    }
    if (commands.items.len > 96 or definitions.object.count() > 64) return error.InvalidDiscoveryMetadata;
    for (commands.items, 0..) |entry, index| {
        const name = try j.required(entry, "cmd");
        for (commands.items[0..index]) |old| if (std.mem.eql(u8, name, j.text(old, "cmd"))) return error.InvalidDiscoveryMetadata;
    }
    return .{ .commands = commands.items, .definitions = definitions };
}
fn commonProperties(a: std.mem.Allocator, name: []const u8) !Value {
    var properties = try j.value(a, .{
        .id = .{ .type = .{ "string", "integer", "null" }, .maxLength = @as(usize, 256), .description = "Optional request correlation ID, echoed in its reply. A missing ID returns null." },
        .account = .{ .type = "string", .format = "email", .description = "Explicit configured, enabled account address from accounts.list. IDs, cursors and handles remain account-specific." },
        .grantFile = .{ .type = "string", .minLength = @as(usize, 1), .description = "Optional private terminal grant-registry path; defaults to --grant-file or the configured XDG/HOME grant registry." },
    });
    try properties.object.put(a, "cmd", try j.value(a, .{ .type = "string", .@"const" = name }));
    return properties;
}
fn collectDefinitions(a: std.mem.Allocator, all: Value, value: Value, selected: *Value, depth: usize) !void {
    if (depth > 32) return error.InvalidDiscoveryMetadata;
    if (value == .object) {
        if (j.get(value, "$ref")) |ref_value| {
            const ref = try j.string(ref_value);
            const prefix = "#/$defs/";
            if (!std.mem.startsWith(u8, ref, prefix)) return error.InvalidDiscoveryMetadata;
            const name = ref[prefix.len..];
            if (!selected.object.contains(name)) {
                const definition = j.get(all, name) orelse return error.InvalidDiscoveryMetadata;
                try selected.object.put(a, name, definition);
                try collectDefinitions(a, all, definition, selected, depth + 1);
            }
        }
        var it = value.object.iterator();
        while (it.next()) |field| try collectDefinitions(a, all, field.value_ptr.*, selected, depth + 1);
    } else if (value == .array) for (value.array.items) |item| try collectDefinitions(a, all, item, selected, depth + 1);
}
pub fn requestSchema(a: std.mem.Allocator, catalogue: Catalogue, entry: Value, with_definitions: bool) !Value {
    const name = try j.required(entry, "cmd");
    var result = j.object(a);
    // Preserve command-specific alternatives and conditions, not only properties.
    for ([_][]const u8{ "properties", "required", "allOf", "anyOf", "oneOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas" }) |key| {
        if (j.get(entry, key)) |value| try result.object.put(a, key, value);
    }
    var properties = try commonProperties(a, name);
    if (j.get(entry, "properties")) |specific| {
        if (specific != .object) return error.InvalidDiscoveryMetadata;
        var it = specific.object.iterator();
        while (it.next()) |field| {
            if (properties.object.contains(field.key_ptr.*)) return error.InvalidDiscoveryMetadata;
            try properties.object.put(a, field.key_ptr.*, field.value_ptr.*);
        }
    }
    var required: Value = .{ .array = .init(a) };
    try required.array.append(.{ .string = "cmd" });
    if (!std.mem.eql(u8, name, "accounts.list")) try required.array.append(.{ .string = "account" });
    if (j.get(entry, "required")) |fields| {
        if (fields != .array) return error.InvalidDiscoveryMetadata;
        for (fields.array.items) |field| {
            const key = try j.string(field);
            if (!properties.object.contains(key)) return error.InvalidDiscoveryMetadata;
            try required.array.append(field);
        }
    }
    try result.object.put(a, "properties", properties);
    try result.object.put(a, "required", required);
    try result.object.put(a, "type", .{ .string = "object" });
    try result.object.put(a, "additionalProperties", .{ .bool = false });
    try result.object.put(a, "$schema", .{ .string = "https://json-schema.org/draft/2020-12/schema" });
    try result.object.put(a, "title", .{ .string = name });
    try result.object.put(a, "description", .{ .string = j.text(entry, "summary") });
    try result.object.put(a, "x-omagma-version", .{ .string = @import("build_options").version });
    try result.object.put(a, "x-max-request-bytes", .{ .integer = @import("types.zig").Limits.request_bytes });
    try result.object.put(a, "x-max-nesting", .{ .integer = 64 });
    for ([_][]const u8{ "capabilities", "notes" }) |key| if (j.get(entry, key)) |value| try result.object.put(a, if (std.mem.eql(u8, key, "notes")) "x-notes" else "x-capabilities", value);
    if (j.get(entry, "examples")) |examples| try result.object.put(a, "examples", examples);
    if (with_definitions) {
        var selected = j.object(a);
        try collectDefinitions(a, catalogue.definitions, result, &selected, 0);
        if (selected.object.count() > 0) try result.object.put(a, "$defs", selected);
    }
    return result;
}
fn writeSchema(writer: anytype, value: Value) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}
pub fn schemas(io: std.Io, a: std.mem.Allocator, target: ?[]const u8) !void {
    const catalogue = try load(a);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    if (target) |name| {
        const entry = catalogue.find(name) orelse return error.UnknownCommand;
        try writeSchema(&writer.interface, try requestSchema(a, catalogue, entry, true));
    } else {
        var variants: Value = .{ .array = .init(a) };
        for (catalogue.commands) |entry| try variants.array.append(try requestSchema(a, catalogue, entry, false));
        var root = try j.value(a, .{ .@"$schema" = "https://json-schema.org/draft/2020-12/schema", .title = "Omagma public JSONL requests", .@"x-omagma-version" = @import("build_options").version, .@"x-max-request-bytes" = @import("types.zig").Limits.request_bytes, .@"x-max-nesting" = 64 });
        try root.object.put(a, "oneOf", variants);
        try root.object.put(a, "$defs", catalogue.definitions);
        try writeSchema(&writer.interface, root);
    }
    try writer.interface.flush();
}
pub fn list(writer: anytype, a: std.mem.Allocator, namespace: ?[]const u8, compact: bool) !void {
    const catalogue = try load(a);
    var found = false;
    if (compact) {
        try writer.writeAll("Available JSONL commands (grouped):\n");
        var seen: [96][]const u8 = undefined;
        var count: usize = 0;
        for (catalogue.commands) |entry| {
            const name = j.text(entry, "cmd");
            const prefix = name[0..std.mem.indexOfScalar(u8, name, '.').?];
            var duplicate = false;
            for (seen[0..count]) |old| if (std.mem.eql(u8, old, prefix)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            seen[count] = prefix;
            count += 1;
            try writer.print("  {s}: ", .{prefix});
            var first = true;
            for (catalogue.commands) |candidate| {
                const cmd = j.text(candidate, "cmd");
                const dot = std.mem.indexOfScalar(u8, cmd, '.').?;
                if (!std.mem.eql(u8, prefix, cmd[0..dot])) continue;
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.writeAll(cmd[dot + 1 ..]);
            }
            try writer.writeByte('\n');
        }
        return;
    }
    for (catalogue.commands) |entry| {
        const name = j.text(entry, "cmd");
        if (namespace) |prefix| {
            const dot = std.mem.indexOfScalar(u8, name, '.').?;
            if (!std.mem.eql(u8, prefix, name[0..dot])) continue;
        }
        found = true;
        try writer.print("  {s:<23} {s}\n", .{ name, j.text(entry, "summary") });
    }
    if (!found) return error.UnknownCommand;
}
pub fn help(io: std.Io, a: std.mem.Allocator, target: []const u8) !void {
    const catalogue = try load(a);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    if (std.mem.eql(u8, target, "commands") or std.mem.indexOfScalar(u8, target, '.') == null) {
        if (!std.mem.eql(u8, target, "commands")) {
            var found = false;
            for (catalogue.commands) |entry| {
                const name = j.text(entry, "cmd");
                const dot = std.mem.indexOfScalar(u8, name, '.').?;
                if (std.mem.eql(u8, name[0..dot], target)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownCommand;
        }
        try writer.interface.writeAll("Omagma JSONL command catalogue\n\n");
        try list(&writer.interface, a, if (std.mem.eql(u8, target, "commands")) null else target, false);
        try writer.interface.writeAll("\nUse omagma cli --help COMMAND for every field, nested object and constraint.\nUse omagma cli --schema COMMAND for machine-readable request metadata.\n");
    } else {
        const entry = catalogue.find(target) orelse return error.UnknownCommand;
        try writer.interface.print("Omagma JSONL command: {s}\n{s}\n\nComplete request fields, constraints, examples and referenced object types:\n", .{ target, j.text(entry, "summary") });
        try writeSchema(&writer.interface, try requestSchema(a, catalogue, entry, true));
    }
    try writer.interface.flush();
}
pub fn full(io: std.Io, a: std.mem.Allocator) !void {
    const catalogue = try load(a);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll("Omagma complete public JSONL reference\nShared object definitions appear after the command schemas.\n\n");
    for (catalogue.commands) |entry| try writeSchema(&writer.interface, try requestSchema(a, catalogue, entry, false));
    try writer.interface.writeAll("\nShared object definitions ($defs):\n");
    try writeSchema(&writer.interface, catalogue.definitions);
    try writer.interface.flush();
}
pub fn sourceSchema(io: std.Io, a: std.mem.Allocator, name: []const u8, field: []const u8) !void {
    const catalogue = try load(a);
    const entry = catalogue.find(name) orelse return error.UnknownCommand;
    const properties = j.get(entry, "properties") orelse return error.InvalidDiscoveryMetadata;
    const source = j.get(properties, field) orelse return error.InvalidDiscoveryMetadata;
    var schema = try j.copyObject(a, source);
    try schema.object.put(a, "$schema", .{ .string = "https://json-schema.org/draft/2020-12/schema" });
    var selected = j.object(a);
    try collectDefinitions(a, catalogue.definitions, schema, &selected, 0);
    if (selected.object.count() > 0) try schema.object.put(a, "$defs", selected);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("\n--{s}-file accepts this bare JSON object, without cmd/account or a {s} wrapper:\n", .{ field, field });
    try writeSchema(&writer.interface, schema);
    try writer.interface.flush();
}
