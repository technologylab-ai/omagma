//! Embedded public JSONL contract; discovery never starts a mail session.
const std = @import("std");
const j = @import("json.zig");
const Value = j.Value;
pub const read_source = @embedFile("cli_api_read.json");
pub const write_source = @embedFile("cli_api_write.json");
pub const calendar_source = @embedFile("cli_api_calendar.json");
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
    // Embedded metadata already has a compile-time byte bound. Its growing
    // public command set must not invalidate discovery at an unrelated count.
    for (commands.items, 0..) |entry, index| {
        const name = try j.required(entry, "cmd");
        for (commands.items[0..index]) |old| if (std.mem.eql(u8, name, j.text(old, "cmd"))) return error.InvalidDiscoveryMetadata;
    }
    return .{ .commands = commands.items, .definitions = definitions };
}
/// Truncation, paging and warning markers that a fields projection always
/// keeps, so a lean read can never hide that it is incomplete.
pub const kept_markers = [_][]const u8{ "bodyTruncated", "bodyBytes", "bodyHtmlBytes", "quotedStripped", "partial", "hasMore", "nextCursor", "decodeWarning", "bodyCacheError", "metadataPartial", "complete", "stale", "readWarnings" };
const fields_description = "Optional output projection, accepted only on read commands: keep only these keys in each item of data.messages, data.events, data.contacts, data.drafts, data.items, data.queue, data.operations or data.entries, or in a single-object result. Truncation, paging and warning markers (bodyTruncated, bodyBytes, bodyHtmlBytes, quotedStripped, partial, hasMore, nextCursor, decodeWarning, bodyCacheError, metadataPartial, complete, stale, readWarnings) are always kept. Unknown names are ignored; the envelope is unchanged. Commands that change state refuse fields (UnknownField) and always return their complete result.";
/// Whether a command accepts the fields projection: reads only (the same
/// classification as client_contract), never a write or a dry run of one.
pub fn projectable(name: []const u8) bool {
    return @import("client_contract.zig").readOnlyEnvelope(name, false);
}
fn commonProperties(a: std.mem.Allocator, name: []const u8) !Value {
    var properties = try j.value(a, .{
        .id = .{ .type = .{ "string", "integer", "null" }, .maxLength = @as(usize, 256), .description = "Optional request correlation ID, echoed in its reply. A missing ID returns null." },
        .account = .{ .type = "string", .format = "email", .description = "Explicit configured, enabled account address from accounts.list. IDs, cursors and handles remain account-specific." },
        .grantFile = .{ .type = "string", .minLength = @as(usize, 1), .description = "Optional private terminal grant-registry path; defaults to --grant-file or the configured XDG/HOME grant registry." },
    });
    if (projectable(name)) try properties.object.put(a, "fields", try j.value(a, .{ .type = "array", .items = .{ .type = "string", .minLength = @as(usize, 1), .maxLength = @as(usize, 64) }, .minItems = @as(usize, 1), .maxItems = @as(usize, 64), .description = if (@import("client_contract.zig").conditionalMutation(name) != null) fields_description ++ " Not accepted together with reconcile:true." else fields_description }));
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
    try result.object.put(a, "x-max-request-bytes", .{ .integer = @intCast(if (@import("send_memory.zig").native and @import("send_memory.zig").command(name)) @import("send_memory.zig").record_bytes else @import("types.zig").Limits.request_bytes) });
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
/// Minified request schema without the shared id/grantFile block and build
/// metadata; account keeps only its type. Reads keep their fields projection.
fn compactSchema(a: std.mem.Allocator, catalogue: Catalogue, entry: Value) !Value {
    var schema = try requestSchema(a, catalogue, entry, true);
    for ([_][]const u8{ "$schema", "x-omagma-version", "x-max-request-bytes", "x-max-nesting" }) |key| _ = schema.object.orderedRemove(key);
    var properties = try j.copyObject(a, j.get(schema, "properties").?);
    for ([_][]const u8{ "id", "grantFile" }) |key| _ = properties.object.orderedRemove(key);
    if (j.get(properties, "fields")) |_| try properties.object.put(a, "fields", try j.value(a, .{ .type = "array", .items = .{ .type = "string" }, .description = "Read-only projection; markers are always kept." }));
    try properties.object.put(a, "account", try j.value(a, .{ .type = "string", .format = "email" }));
    try schema.object.put(a, "properties", properties);
    return schema;
}
/// Names the nearest command or namespace on stderr before a usage error.
/// The typed target is echoed only when it is a plain command-like word.
fn unknownTarget(a: std.mem.Allocator, catalogue: Catalogue, target: []const u8, flag: []const u8) error{UnknownCommand} {
    var names: std.ArrayList([]const u8) = .empty;
    for (catalogue.commands) |entry| {
        const name = j.text(entry, "cmd");
        names.append(a, name) catch break;
        const prefix = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
        var seen = false;
        for (names.items) |old| seen = seen or std.mem.eql(u8, old, prefix);
        if (!seen) names.append(a, prefix) catch break;
    }
    var plain = target.len != 0 and target.len <= 64;
    for (target) |byte| plain = plain and (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_');
    const shown = if (plain) target else "this name";
    if (@import("cli_contract.zig").nearest(target, names.items)) |suggestion| {
        std.debug.print("Unknown JSONL command {s}; did you mean: omagma cli {s} {s}?\n", .{ shown, flag, suggestion });
    } else std.debug.print("Unknown JSONL command {s}; list them with omagma cli --help commands.\n", .{shown});
    return error.UnknownCommand;
}
pub fn schemas(io: std.Io, a: std.mem.Allocator, target: ?[]const u8, compact: bool) !void {
    const catalogue = try load(a);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    if (target) |name| {
        const entry = catalogue.find(name) orelse return unknownTarget(a, catalogue, name, "--schema");
        if (compact) {
            try std.json.Stringify.value(try compactSchema(a, catalogue, entry), .{}, &writer.interface);
            try writer.interface.writeByte('\n');
        } else try writeSchema(&writer.interface, try requestSchema(a, catalogue, entry, true));
    } else if (compact) {
        // One minified request schema per line.
        for (catalogue.commands) |entry| {
            try std.json.Stringify.value(try compactSchema(a, catalogue, entry), .{}, &writer.interface);
            try writer.interface.writeByte('\n');
        }
    } else {
        var variants: Value = .{ .array = .init(a) };
        for (catalogue.commands) |entry| try variants.array.append(try requestSchema(a, catalogue, entry, false));
        var root = try j.value(a, .{ .@"$schema" = "https://json-schema.org/draft/2020-12/schema", .title = "Omagma public JSONL requests", .@"x-omagma-version" = @import("build_options").version, .@"x-max-request-bytes" = @import("send_memory.zig").record_bytes, .@"x-max-nesting" = 64 });
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
            if (!found) return unknownTarget(a, catalogue, target, "--help");
        }
        try writer.interface.writeAll("Omagma JSONL command catalogue\n\n");
        try list(&writer.interface, a, if (std.mem.eql(u8, target, "commands")) null else target, false);
        try writer.interface.writeAll("\nUse omagma cli --help COMMAND for a compact field card and example.\nUse omagma cli --schema COMMAND for every field, nested object and constraint.\n");
    } else {
        const entry = catalogue.find(target) orelse return unknownTarget(a, catalogue, target, "--help");
        try card(&writer.interface, a, catalogue, entry);
    }
    try writer.interface.flush();
}
fn resolveDefinition(catalogue: Catalogue, schema: Value) Value {
    var current = schema;
    for (0..8) |_| {
        const ref = j.text(current, "$ref");
        if (!std.mem.startsWith(u8, ref, "#/$defs/")) break;
        current = j.get(catalogue.definitions, ref["#/$defs/".len..]) orelse break;
    }
    return current;
}
/// "name:type", "name:a|b=default", "name:int 1..100" or "name:Draft".
fn fieldLabel(a: std.mem.Allocator, catalogue: Catalogue, name: []const u8, schema: Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}:", .{name});
    const resolved = resolveDefinition(catalogue, schema);
    const ref = j.text(schema, "$ref");
    if (j.get(resolved, "enum")) |values| {
        for (values.array.items, 0..) |value, index| try out.print(a, "{s}{s}", .{ if (index == 0) "" else "|", if (value == .string) value.string else "?" });
    } else if (j.get(resolved, "type")) |kind| {
        const text = if (kind == .string) kind.string else if (kind == .array and kind.array.items.len != 0 and kind.array.items[0] == .string) kind.array.items[0].string else "value";
        if (ref.len != 0 and std.mem.eql(u8, text, "object")) try out.appendSlice(a, ref["#/$defs/".len..]) else try out.appendSlice(a, if (std.mem.eql(u8, text, "integer")) "int" else if (std.mem.eql(u8, text, "boolean")) "bool" else text);
        if (j.get(resolved, "minimum")) |minimum| if (minimum == .integer) try out.print(a, " {d}..", .{minimum.integer});
        if (j.get(resolved, "maximum")) |maximum| if (maximum == .integer) {
            if (j.get(resolved, "minimum") == null) try out.appendSlice(a, " ..");
            try out.print(a, "{d}", .{maximum.integer});
        };
    } else try out.appendSlice(a, if (ref.len != 0) ref["#/$defs/".len..] else "value");
    if (j.get(schema, "default") orelse j.get(resolved, "default")) |default| switch (default) {
        .bool => |flag| try out.print(a, "={s}", .{if (flag) "true" else "false"}),
        .integer => |number| try out.print(a, "={d}", .{number}),
        .string => |text| if (text.len != 0) try out.print(a, "={s}", .{text}),
        else => {},
    };
    return out.items;
}
fn returnsNote(entry: Value) ?[]const u8 {
    const notes = j.get(entry, "notes") orelse return null;
    if (notes != .array) return null;
    for (notes.array.items) |note| if (note == .string) if (std.mem.indexOf(u8, note.string, "Returns ")) |start| {
        const sentence = note.string[start..];
        const end = std.mem.indexOf(u8, sentence, ". ") orelse sentence.len;
        var cut = @min(end, 140);
        while (cut > 0 and cut < sentence.len and (sentence[cut] & 0xC0) == 0x80) cut -= 1;
        return sentence[0..cut];
    };
    return null;
}
fn idempotency(entry: Value) []const u8 {
    const command = j.text(entry, "cmd");
    if (j.get(j.get(entry, "properties") orelse .null, "operationId") != null) return "operationId";
    if (j.get(j.get(entry, "properties") orelse .null, "undoToken") != null) return "undoToken";
    if (!@import("client_contract.zig").mayMutate(command)) return "read-only";
    return "none";
}
/// "no", "yes" or "only with reconcile:true", from client_contract alone.
fn mutatesText(command: []const u8) []const u8 {
    const contract = @import("client_contract.zig");
    if (contract.conditionalMutation(command) != null) return "only with reconcile:true";
    return if (contract.mayMutate(command)) "yes" else "no";
}
/// Compact discovery card (well under 1 KiB): what the command does, its
/// required and optional fields with types, defaults and enums, one example.
fn card(writer: anytype, a: std.mem.Allocator, catalogue: Catalogue, entry: Value) !void {
    const command = j.text(entry, "cmd");
    try writer.print("{s}: {s}\n", .{ command, j.text(entry, "summary") });
    var caps: std.ArrayList([]const u8) = .empty;
    if (j.get(entry, "capabilities")) |values| for (values.array.items) |value| try caps.append(a, try j.string(value));
    try writer.print("capabilities: {s} · mutates: {s} · idempotency: {s}\n", .{ if (caps.items.len == 0) "none" else try std.mem.join(a, ",", caps.items), mutatesText(command), idempotency(entry) });
    const properties = j.get(entry, "properties") orelse j.object(a);
    var required: std.ArrayList([]const u8) = .empty;
    if (!std.mem.eql(u8, command, "accounts.list")) try required.append(a, "account:email");
    var optional: std.ArrayList([]const u8) = .empty;
    const names = j.get(entry, "required");
    var it = properties.object.iterator();
    while (it.next()) |field| {
        if (j.boolean(field.value_ptr.*, "x-internal", false) catch false) continue;
        var needed = false;
        if (names) |required_names| for (required_names.array.items) |item| {
            needed = needed or (item == .string and std.mem.eql(u8, item.string, field.key_ptr.*));
        };
        try (if (needed) &required else &optional).append(a, try fieldLabel(a, catalogue, field.key_ptr.*, field.value_ptr.*));
    }
    try writer.print("required: {s}\n", .{try std.mem.join(a, ", ", required.items)});
    if (optional.items.len != 0) try writer.print("optional: {s}\n", .{try std.mem.join(a, ", ", optional.items)});
    if (returnsNote(entry)) |text| try writer.print("returns: {s}\n", .{text});
    if (j.get(entry, "examples")) |examples| if (examples == .array and examples.array.items.len != 0) {
        var shortest = examples.array.items[0];
        var shortest_bytes = (try std.json.Stringify.valueAlloc(a, shortest, .{})).len;
        for (examples.array.items[1..]) |example| {
            const bytes = (try std.json.Stringify.valueAlloc(a, example, .{})).len;
            if (bytes < shortest_bytes) {
                shortest = example;
                shortest_bytes = bytes;
            }
        }
        try writer.print("example: {s}\n", .{try std.json.Stringify.valueAlloc(a, shortest, .{})});
    };
    try writer.print("Complete request fields: omagma cli --schema {s} [--compact] (id{s}; unknown fields fail)\n", .{ command, if (projectable(command)) ", fields:[...]" else "; no fields: full result" });
}
/// One compact JSON index of every public command for agents.
pub fn manifest(io: std.Io, a: std.mem.Allocator) !void {
    const root = try manifestValue(a);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try std.json.Stringify.value(root, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
fn manifestValue(a: std.mem.Allocator) !Value {
    const catalogue = try load(a);
    var commands: Value = .{ .array = .init(a) };
    for (catalogue.commands) |entry| {
        const command = j.text(entry, "cmd");
        var required: Value = .{ .array = .init(a) };
        var optional: Value = .{ .array = .init(a) };
        if (!std.mem.eql(u8, command, "accounts.list")) try required.array.append(.{ .string = "account" });
        const names = j.get(entry, "required");
        if (j.get(entry, "properties")) |properties| {
            var it = properties.object.iterator();
            while (it.next()) |field| {
                if (j.boolean(field.value_ptr.*, "x-internal", false) catch false) continue;
                var needed = false;
                if (names) |required_names| for (required_names.array.items) |item| {
                    needed = needed or (item == .string and std.mem.eql(u8, item.string, field.key_ptr.*));
                };
                try (if (needed) &required else &optional).array.append(.{ .string = field.key_ptr.* });
            }
        }
        if (projectable(command)) try optional.array.append(.{ .string = "fields" });
        var row = try j.value(a, .{ .cmd = command, .summary = j.text(entry, "summary") });
        try row.object.put(a, "caps", j.get(entry, "capabilities") orelse Value{ .array = .init(a) });
        try row.object.put(a, "required", required);
        try row.object.put(a, "optional", optional);
        // Conditional commands count as mutating and name their trigger.
        try row.object.put(a, "mutates", .{ .bool = @import("client_contract.zig").mayMutate(command) });
        if (@import("client_contract.zig").conditionalMutation(command)) |trigger| try row.object.put(a, "mutatesWhen", .{ .string = trigger });
        try row.object.put(a, "idempotency", .{ .string = idempotency(entry) });
        try commands.array.append(row);
    }
    var root = try j.value(a, .{ .version = @import("build_options").version, .common = [_][]const u8{ "id", "account", "grantFile" }, .readFields = "fields:[...] projects read replies only; markers are always kept", .strict = true, .schema = "omagma cli --schema CMD [--compact]" });
    try root.object.put(a, "commands", commands);
    return root;
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

test "cli discovery: command cards stay compact and name required fields, types and an example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const catalogue = try load(a);
    for (catalogue.commands) |entry| {
        var out: std.Io.Writer.Allocating = .init(a);
        try card(&out.writer, a, catalogue, entry);
        const text = out.written();
        try std.testing.expect(std.mem.indexOf(u8, text, "required: ") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Complete request fields") != null);
        if (std.mem.startsWith(u8, j.text(entry, "cmd"), "mail.")) try std.testing.expect(text.len < 800);
        try std.testing.expect(text.len < 1600);
    }
    var out: std.Io.Writer.Allocating = .init(a);
    try card(&out.writer, a, catalogue, catalogue.find("mail.list").?);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "limit:int 1..100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "view:full|summary=full") != null);
    const compact = try compactSchema(a, catalogue, catalogue.find("mail.send").?);
    try std.testing.expect(j.get(j.get(compact, "properties").?, "grantFile") == null);
    try std.testing.expect(j.get(j.get(compact, "properties").?, "dryRun") != null);
}

test "cli discovery: manifest, cards and schemas derive mutates and fields from client_contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const contract = @import("client_contract.zig");
    const catalogue = try load(a);
    const root = try manifestValue(a);
    for (j.get(root, "common").?.array.items) |name| try std.testing.expect(!std.mem.eql(u8, name.string, "fields"));
    const rows = j.get(root, "commands").?.array.items;
    try std.testing.expectEqual(catalogue.commands.len, rows.len);
    for (rows, catalogue.commands) |row, entry| {
        const command = j.text(row, "cmd");
        try std.testing.expectEqualStrings(j.text(entry, "cmd"), command);
        try std.testing.expectEqual(contract.mayMutate(command), j.get(row, "mutates").?.bool);
        try std.testing.expectEqual(contract.conditionalMutation(command) != null, j.get(row, "mutatesWhen") != null);
        var lists_fields = false;
        for (j.get(row, "optional").?.array.items) |name| lists_fields = lists_fields or std.mem.eql(u8, name.string, "fields");
        try std.testing.expectEqual(projectable(command), lists_fields);
        const schema = try requestSchema(a, catalogue, entry, false);
        try std.testing.expectEqual(projectable(command), j.get(j.get(schema, "properties").?, "fields") != null);
        // A command that can dry-run or write never offers a projection.
        if (j.get(j.get(entry, "properties") orelse .null, "dryRun") != null) try std.testing.expect(contract.mayMutate(command) and !projectable(command));
        var out: std.Io.Writer.Allocating = .init(a);
        try card(&out.writer, a, catalogue, entry);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), try std.fmt.allocPrint(a, "mutates: {s} ", .{mutatesText(command)})) != null);
    }
    // The reviewed misclassifications stay fixed.
    for ([_][]const u8{ "draft.gmail-info", "calendar.freebusy", "calendar.invitation-plan" }) |command| try std.testing.expect(!contract.mayMutate(command));
    try std.testing.expect(contract.mayMutate("calendar.meet-event-reconcile"));
    try std.testing.expectEqualStrings("only with reconcile:true", mutatesText("invitation.inspect"));
}

test "meet notes: public authorization capabilities match the runtime grant set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const catalogue = try load(arena.allocator());
    const definition = j.get(catalogue.definitions, "ReadCapabilities") orelse return error.MissingCapabilities;
    const runtime = @import("auth.zig").allowed_capabilities;
    try std.testing.expectEqual(@as(i64, @intCast(runtime.len)), try j.integer(definition, "maxItems", 0));
    const values = j.get(j.get(definition, "items") orelse .null, "enum") orelse return error.MissingCapabilities;
    try std.testing.expectEqual(runtime.len, values.array.items.len);
    for (runtime) |capability| {
        var found = false;
        for (values.array.items) |value| found = found or std.mem.eql(u8, try j.string(value), capability);
        try std.testing.expect(found);
    }
}
