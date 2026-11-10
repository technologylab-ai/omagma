//! Public JSONL request contract. Every request frame is checked against the
//! embedded catalogue before dispatch: an unknown or misspelled field fails
//! closed (nothing executes) instead of silently disappearing. Executor failures
//! are explained from the same metadata: the field, its expected shape, the
//! nearest valid name and a next step. Stable error codes never change.
const std = @import("std");
const j = @import("json.zig");
const api = @import("cli_api.zig");
const error_text = @import("error_text.zig");
const Value = j.Value;
const A = std.mem.Allocator;

/// Accepted by every command besides its own properties (see cli_api commonProperties).
pub const common_fields = [_][]const u8{ "id", "cmd", "account", "grantFile", "fields" };
/// Added by the native vault client transport; never public request data.
const envelope_fields = [_][]const u8{ "_vaultId", "_progress", "_cancelOnDisconnect" };
/// Private TUI commands outside the public catalogue and their accepted fields.
const Internal = struct { cmd: []const u8, fields: []const []const u8 };
const internal_commands = [_]Internal{
    .{ .cmd = "preferences.get", .fields = &.{} },
    .{ .cmd = "preferences.set", .fields = &.{"preferences"} },
    .{ .cmd = "mail.compose-source", .fields = &.{ "messageId", "cacheOnly" } },
};
/// Common mistakes whose intended field is not a near spelling.
const Synonym = struct { from: []const u8, to: []const u8 };
const synonyms = [_]Synonym{
    .{ .from = "body", .to = "bodyText" },             .{ .from = "text", .to = "bodyText" },                   .{ .from = "content", .to = "bodyText" },
    .{ .from = "title", .to = "summary" },             .{ .from = "replyAll", .to = "all" },                    .{ .from = "recipients", .to = "to" },
    .{ .from = "msgId", .to = "messageId" },           .{ .from = "message", .to = "messageId" },               .{ .from = "thread", .to = "threadId" },
    .{ .from = "draft_id", .to = "draftId" },          .{ .from = "html", .to = "bodyHtml" },                   .{ .from = "format", .to = "bodyFormat" },
    .{ .from = "simulate", .to = "dryRun" },           .{ .from = "validateOnly", .to = "dryRun" },             .{ .from = "noSend", .to = "dryRun" },
    .{ .from = "mail.compose", .to = "draft.create" }, .{ .from = "mail.drafts", .to = "draft.list" },          .{ .from = "mail.labels", .to = "labels.list" },
    .{ .from = "mail.get", .to = "mail.read" },        .{ .from = "mail.delete", .to = "mail.trash" },          .{ .from = "mail.spam", .to = "mail.batch" },
    .{ .from = "mail.unspam", .to = "mail.batch" },    .{ .from = "calendar.events", .to = "calendar.agenda" }, .{ .from = "contacts.get", .to = "contacts.search" },
};

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (eq(item, name)) return true;
    return false;
}

const Slice = struct { name: []const u8, bytes: []const u8 };
const sources = [_][]const u8{ api.read_source, api.write_source, api.calendar_source };
/// Byte slices of the embedded catalogue; only selected entries are parsed.
/// Lookups use the files' fixed two-space layout (command keys at six spaces,
/// definition names at four), so a request touches only its own entries;
/// a full scan remains the fallback and the test oracle.
pub const Catalogue = struct {
    a: A,
    commands: std.ArrayList(Slice) = .empty,
    definitions: std.ArrayList(Slice) = .empty,
    parsed: std.StringHashMapUnmanaged(Value) = .empty,
    scanned: bool = false,
    pub fn init(a: A) !Catalogue {
        return .{ .a = a };
    }
    fn full(self: *Catalogue) !void {
        if (self.scanned) return;
        for (sources) |source| try self.scan(source);
        self.scanned = true;
    }
    /// The complete JSON object that starts at source[start] ('{').
    fn object(self: *Catalogue, source: []const u8, start: usize) ![]const u8 {
        if (start >= source.len or source[start] != '{') return error.InvalidDiscoveryMetadata;
        var scanner = std.json.Scanner.initCompleteInput(self.a, source[start..]);
        defer scanner.deinit();
        try scanner.skipValue();
        return source[start..][0..scanner.cursor];
    }
    fn locateCommand(self: *Catalogue, name: []const u8) !?[]const u8 {
        const pattern = try std.fmt.allocPrint(self.a, "\n      \"cmd\": \"{s}\",\n", .{name});
        for (sources) |source| if (std.mem.indexOf(u8, source, pattern)) |at| {
            const open = std.mem.lastIndexOf(u8, source[0..at], "\n    {") orelse return null;
            return try self.object(source, open + "\n    ".len);
        };
        return null;
    }
    fn locateDefinition(self: *Catalogue, name: []const u8) !?[]const u8 {
        const pattern = try std.fmt.allocPrint(self.a, "\n    \"{s}\": {{", .{name});
        for (sources) |source| if (std.mem.indexOf(u8, source, pattern)) |at| return try self.object(source, at + pattern.len - 1);
        return null;
    }
    fn key(self: *Catalogue, scanner: *std.json.Scanner) !?[]const u8 {
        return switch (try scanner.nextAlloc(self.a, .alloc_if_needed)) {
            .object_end => null,
            .string => |text| text,
            .allocated_string => |text| text,
            else => error.InvalidDiscoveryMetadata,
        };
    }
    fn valueStart(source: []const u8, scanner: *std.json.Scanner) !usize {
        _ = try scanner.peekNextTokenType();
        return std.mem.indexOfScalarPos(u8, source, scanner.cursor, '{') orelse error.InvalidDiscoveryMetadata;
    }
    fn scan(self: *Catalogue, source: []const u8) !void {
        var scanner = std.json.Scanner.initCompleteInput(self.a, source);
        defer scanner.deinit();
        if (try scanner.next() != .object_begin) return error.InvalidDiscoveryMetadata;
        while (try self.key(&scanner)) |section| {
            if (eq(section, "commands")) {
                if (try scanner.next() != .array_begin) return error.InvalidDiscoveryMetadata;
                while (try scanner.peekNextTokenType() != .array_end) {
                    const start = try valueStart(source, &scanner);
                    if (try scanner.next() != .object_begin) return error.InvalidDiscoveryMetadata;
                    var name: ?[]const u8 = null;
                    while (try self.key(&scanner)) |field| {
                        if (!eq(field, "cmd")) {
                            try scanner.skipValue();
                            continue;
                        }
                        name = switch (try scanner.nextAlloc(self.a, .alloc_if_needed)) {
                            .string => |text| text,
                            .allocated_string => |text| text,
                            else => return error.InvalidDiscoveryMetadata,
                        };
                    }
                    try self.commands.append(self.a, .{ .name = name orelse return error.InvalidDiscoveryMetadata, .bytes = source[start..scanner.cursor] });
                }
                _ = try scanner.next();
            } else if (eq(section, "$defs")) {
                if (try scanner.next() != .object_begin) return error.InvalidDiscoveryMetadata;
                while (try self.key(&scanner)) |name| {
                    const start = try valueStart(source, &scanner);
                    try scanner.skipValue();
                    try self.definitions.append(self.a, .{ .name = name, .bytes = source[start..scanner.cursor] });
                }
            } else try scanner.skipValue();
        }
    }
    fn parse(self: *Catalogue, bytes: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.a, bytes, .{ .allocate = .alloc_if_needed, .max_value_len = 65536 });
    }
    pub fn command(self: *Catalogue, name: []const u8) !?Value {
        if (try self.locateCommand(name)) |bytes| {
            const value = try self.parse(bytes);
            if (eq(j.text(value, "cmd"), name)) return value;
        }
        try self.full();
        for (self.commands.items) |entry| if (eq(entry.name, name)) return try self.parse(entry.bytes);
        return null;
    }
    pub fn commandNames(self: *Catalogue) ![]const []const u8 {
        try self.full();
        const names = try self.a.alloc([]const u8, self.commands.items.len);
        for (self.commands.items, names) |entry, *name| name.* = entry.name;
        return names;
    }
    fn definition(self: *Catalogue, name: []const u8) !Value {
        if (self.parsed.get(name)) |value| return value;
        const bytes = (try self.locateDefinition(name)) orelse fallback: {
            try self.full();
            for (self.definitions.items) |entry| if (eq(entry.name, name)) break :fallback entry.bytes;
            return error.InvalidDiscoveryMetadata;
        };
        const value = try self.parse(bytes);
        try self.parsed.put(self.a, name, value);
        return value;
    }
    fn resolve(self: *Catalogue, schema: Value) !Value {
        var current = schema;
        var hops: usize = 0;
        while (j.get(current, "$ref")) |ref| : (hops += 1) {
            const text = try j.string(ref);
            if (hops > 16 or !std.mem.startsWith(u8, text, "#/$defs/")) return error.InvalidDiscoveryMetadata;
            current = try self.definition(text["#/$defs/".len..]);
        }
        return current;
    }
    /// Every conjunct or alternative that can describe one value: $ref targets
    /// and allOf/anyOf/oneOf/then/else members. if/not only constrain.
    fn flatten(self: *Catalogue, schema: Value, optional: bool, out: *std.ArrayList(Shape), depth: usize) !void {
        if (depth > 24) return error.InvalidDiscoveryMetadata;
        const resolved = try self.resolve(schema);
        if (resolved != .object) return;
        try out.append(self.a, .{ .schema = resolved, .optional = optional });
        for ([_][]const u8{ "allOf", "anyOf", "oneOf" }) |combinator| if (j.get(resolved, combinator)) |members| if (members == .array) for (members.array.items) |member| try self.flatten(member, optional or !eq(combinator, "allOf"), out, depth + 1);
        for ([_][]const u8{ "then", "else" }) |branch| if (j.get(resolved, branch)) |member| try self.flatten(member, true, out, depth + 1);
    }
    fn shapes(self: *Catalogue, schemas: []const Value) ![]Shape {
        var out: std.ArrayList(Shape) = .empty;
        for (schemas) |schema| try self.flatten(schema, false, &out, 0);
        return out.items;
    }
};
const Shape = struct { schema: Value, optional: bool };
fn internalField(schema: Value) bool {
    return j.boolean(schema, "x-internal", false) catch false;
}
/// Declared names across shapes; false when no shape declares properties.
fn declared(a: A, found: []const Shape, out: *std.ArrayList([]const u8), public_only: bool) !bool {
    var closed = false;
    for (found) |shape| if (j.get(shape.schema, "properties")) |properties| if (properties == .object) {
        closed = true;
        var it = properties.object.iterator();
        while (it.next()) |property| {
            if (public_only and internalField(property.value_ptr.*)) continue;
            if (!contains(out.items, property.key_ptr.*)) try out.append(a, property.key_ptr.*);
        }
    };
    return closed;
}
fn propertySchemas(a: A, found: []const Shape, name: []const u8) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    for (found) |shape| if (j.get(shape.schema, "properties")) |properties| if (j.get(properties, name)) |schema| try out.append(a, schema);
    return out.items;
}
fn join(a: A, path: []const u8, name: []const u8) ![]const u8 {
    return if (path.len == 0) name else std.fmt.allocPrint(a, "{s}.{s}", .{ path, name });
}

fn folded(byte: u8) u8 {
    return std.ascii.toLower(byte);
}
/// Equal after case folding and removing '_'/'-' (message_id == messageId).
fn looselyEqual(left: []const u8, right: []const u8) bool {
    var l: usize = 0;
    var r: usize = 0;
    while (true) {
        while (l < left.len and (left[l] == '_' or left[l] == '-')) l += 1;
        while (r < right.len and (right[r] == '_' or right[r] == '-')) r += 1;
        if (l == left.len or r == right.len) return l == left.len and r == right.len;
        if (folded(left[l]) != folded(right[r])) return false;
        l += 1;
        r += 1;
    }
}
fn distance(left: []const u8, right: []const u8) usize {
    if (left.len > 64 or right.len > 64) return std.math.maxInt(usize);
    var previous: [65]usize = undefined;
    var current: [65]usize = undefined;
    for (0..right.len + 1) |index| previous[index] = index;
    for (left, 0..) |l, row| {
        current[0] = row + 1;
        for (right, 0..) |r, column| current[column + 1] = @min(@min(previous[column + 1] + 1, current[column] + 1), previous[column] + @intFromBool(folded(l) != folded(r)));
        @memcpy(previous[0 .. right.len + 1], current[0 .. right.len + 1]);
    }
    return previous[right.len];
}
/// The intended valid name for a mistyped one, or null when nothing is close.
pub fn nearest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    for (synonyms) |synonym| if (std.ascii.eqlIgnoreCase(name, synonym.from) and contains(candidates, synonym.to)) return synonym.to;
    var best: ?[]const u8 = null;
    var best_score: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        if (looselyEqual(name, candidate)) return candidate;
        var score = distance(name, candidate);
        if (name.len >= 3 and candidate.len > name.len and std.ascii.startsWithIgnoreCase(candidate, name)) score = @min(score, 1);
        if (score < best_score) {
            best = candidate;
            best_score = score;
        }
    }
    return if (best_score <= @max(2, name.len / 3)) best else null;
}

fn unknownField(a: A, command: []const u8, path: []const u8, name: []const u8, valid: []const []const u8) !Value {
    const field = try join(a, path, name);
    var detail = j.object(a);
    try detail.object.put(a, "code", .{ .string = "UnknownField" });
    try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "{s} has no field '{s}'", .{ command, field }) });
    try detail.object.put(a, "field", .{ .string = field });
    if (nearest(name, valid)) |suggestion| try detail.object.put(a, "didYouMean", .{ .string = try join(a, path, suggestion) });
    var list: Value = .{ .array = .init(a) };
    for (valid) |item| try list.array.append(.{ .string = try join(a, path, item) });
    try detail.object.put(a, "validFields", list);
    try detail.object.put(a, "help", .{ .string = try std.fmt.allocPrint(a, "omagma cli --schema {s}", .{command}) });
    try detail.object.put(a, "retryable", .{ .bool = false });
    return detail;
}
fn unsupported(a: A, catalogue: *Catalogue, command: []const u8) !Value {
    var detail = j.object(a);
    try detail.object.put(a, "code", .{ .string = "UnsupportedCommand" });
    try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "'{s}' is not a JSONL command", .{command}) });
    try detail.object.put(a, "field", .{ .string = "cmd" });
    if (nearest(command, try catalogue.commandNames())) |suggestion| try detail.object.put(a, "didYouMean", .{ .string = suggestion });
    try detail.object.put(a, "help", .{ .string = "omagma cli --help commands" });
    try detail.object.put(a, "retryable", .{ .bool = false });
    return detail;
}

const Walker = struct {
    a: A,
    catalogue: *Catalogue,
    command: []const u8,
    fn walk(self: *Walker, path: []const u8, value: Value, schemas: []const Value, depth: usize) anyerror!?Value {
        if (depth > 32 or schemas.len == 0) return null;
        const found = try self.catalogue.shapes(schemas);
        switch (value) {
            .object => |map| {
                var names: std.ArrayList([]const u8) = .empty;
                if (!try declared(self.a, found, &names, false)) return null;
                var it = map.iterator();
                while (it.next()) |field| {
                    const name = field.key_ptr.*;
                    if (!contains(names.items, name)) {
                        var public: std.ArrayList([]const u8) = .empty;
                        _ = try declared(self.a, found, &public, true);
                        return try unknownField(self.a, self.command, path, name, public.items);
                    }
                    if (try self.walk(try join(self.a, path, name), field.value_ptr.*, try propertySchemas(self.a, found, name), depth + 1)) |detail| return detail;
                }
            },
            .array => |list| {
                var items: std.ArrayList(Value) = .empty;
                for (found) |shape| if (j.get(shape.schema, "items")) |item| try items.append(self.a, item);
                if (items.items.len == 0) return null;
                for (list.items, 0..) |item, index| if (try self.walk(try std.fmt.allocPrint(self.a, "{s}[{d}]", .{ path, index }), item, items.items, depth + 1)) |detail| return detail;
            },
            else => {},
        }
        return null;
    }
};

/// Reject unknown fields before dispatch. Returns the complete error object,
/// or null when every field is declared. A missing/non-string cmd is left to
/// the executor's existing MissingField/InvalidRequest contract.
pub fn check(a: A, request: Value) !?Value {
    if (request != .object) return null;
    const command_value = j.get(request, "cmd") orelse return null;
    if (command_value != .string) return null;
    const command = command_value.string;
    for (internal_commands) |internal| if (eq(internal.cmd, command)) {
        var it = request.object.iterator();
        while (it.next()) |field| {
            const name = field.key_ptr.*;
            if (contains(&common_fields, name) or contains(&envelope_fields, name) or contains(internal.fields, name)) continue;
            var valid: std.ArrayList([]const u8) = .empty;
            try valid.appendSlice(a, internal.fields);
            try valid.appendSlice(a, &common_fields);
            return try unknownField(a, command, "", name, valid.items);
        }
        return null;
    };
    var catalogue = try Catalogue.init(a);
    const entry = (try catalogue.command(command)) orelse return try unsupported(a, &catalogue, command);
    const found = try catalogue.shapes(&.{entry});
    var names: std.ArrayList([]const u8) = .empty;
    _ = try declared(a, found, &names, false);
    var walker: Walker = .{ .a = a, .catalogue = &catalogue, .command = command };
    var it = request.object.iterator();
    while (it.next()) |field| {
        const name = field.key_ptr.*;
        if (contains(&envelope_fields, name) or contains(&common_fields, name)) continue;
        if (!contains(names.items, name)) {
            var public: std.ArrayList([]const u8) = .empty;
            _ = try declared(a, found, &public, true);
            for (common_fields) |common| if (!eq(common, "cmd")) try public.append(a, common);
            return try unknownField(a, command, "", name, public.items);
        }
        if (try walker.walk(name, field.value_ptr.*, try propertySchemas(a, found, name), 1)) |detail| return detail;
    }
    return null;
}

/// Documented harmless aliases are rewritten after validation.
pub fn normalize(a: A, request: Value) !Value {
    const command = j.text(request, "cmd");
    if (eq(command, "mail.reply")) if (j.get(request, "replyAll")) |alias| {
        if (alias != .bool) return error.InvalidRequest;
        if (j.get(request, "all")) |all| if (all != .bool or all.bool != alias.bool) return error.ConflictingReplyAll;
        var copy = try j.copyObject(a, request);
        _ = copy.object.swapRemove("replyAll");
        try copy.object.put(a, "all", alias);
        return copy;
    };
    return request;
}

fn typeMatches(name: []const u8, value: Value) bool {
    if (eq(name, "string")) return value == .string;
    if (eq(name, "integer")) return value == .integer;
    if (eq(name, "number")) return value == .integer or value == .float or value == .number_string;
    if (eq(name, "boolean")) return value == .bool;
    if (eq(name, "object")) return value == .object;
    if (eq(name, "array")) return value == .array;
    if (eq(name, "null")) return value == .null;
    return true;
}
fn accepts(schema: Value, value: Value) ?bool {
    const declared_type = j.get(schema, "type") orelse return null;
    if (declared_type == .string) return typeMatches(declared_type.string, value);
    if (declared_type == .array) {
        for (declared_type.array.items) |item| if (item == .string and typeMatches(item.string, value)) return true;
        return false;
    }
    return null;
}
fn sameJson(left: Value, right: Value) bool {
    return switch (left) {
        .string => |text| right == .string and eq(text, right.string),
        .integer => |number| right == .integer and number == right.integer,
        .bool => |flag| right == .bool and flag == right.bool,
        .null => right == .null,
        else => false,
    };
}
fn civilDate(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    for (text, 0..) |byte, index| if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) return false;
    return true;
}
fn putList(a: A, detail: *Value, name: []const u8, items: []const []const u8) !void {
    var list: Value = .{ .array = .init(a) };
    for (items) |item| try list.array.append(.{ .string = item });
    try detail.object.put(a, name, list);
}
fn expectedTypes(a: A, found: []const Shape) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (found) |shape| if (j.get(shape.schema, "type")) |declared_type| {
        if (declared_type == .string) {
            if (!contains(names.items, declared_type.string)) try names.append(a, declared_type.string);
        } else if (declared_type == .array) for (declared_type.array.items) |item| if (item == .string and !contains(names.items, item.string)) try names.append(a, item.string);
    };
    return std.mem.join(a, " or ", names.items);
}
/// The first type/enum/range/required violation of one value, if any.
fn inspect(a: A, catalogue: *Catalogue, command: []const u8, path: []const u8, value: Value, schemas: []const Value, depth: usize) anyerror!?Value {
    if (depth > 32 or schemas.len == 0) return null;
    const found = try catalogue.shapes(schemas);
    var detail = j.object(a);
    var typed = false;
    var matched = false;
    for (found) |shape| if (accepts(shape.schema, value)) |ok| {
        typed = true;
        matched = matched or ok;
    };
    if (typed and !matched) {
        const expected = try expectedTypes(a, found);
        try detail.object.put(a, "field", .{ .string = path });
        try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "{s}: '{s}' must be of type {s}", .{ command, path, expected }) });
        try detail.object.put(a, "expected", .{ .string = expected });
        return detail;
    }
    var choices: std.ArrayList(Value) = .empty;
    var open_alternative = false;
    for (found) |shape| {
        if ((accepts(shape.schema, value) orelse true) == false) continue;
        if (j.get(shape.schema, "enum")) |values| {
            if (values == .array) try choices.appendSlice(a, values.array.items);
        } else if (j.get(shape.schema, "const")) |constant| try choices.append(a, constant) else if (j.get(shape.schema, "pattern") != null and value == .string) open_alternative = true;
    }
    if (choices.items.len != 0 and !open_alternative) {
        var allowed = false;
        for (choices.items) |choice| allowed = allowed or sameJson(choice, value);
        if (!allowed) {
            var list: Value = .{ .array = .init(a) };
            var texts: std.ArrayList([]const u8) = .empty;
            for (choices.items) |choice| {
                try list.array.append(choice);
                if (choice == .string) try texts.append(a, choice.string);
            }
            try detail.object.put(a, "field", .{ .string = path });
            try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "{s}: '{s}' must be one of {s}", .{ command, path, try std.mem.join(a, ", ", texts.items) }) });
            try detail.object.put(a, "enum", list);
            return detail;
        }
    }
    for (found) |shape| {
        const schema = shape.schema;
        if (value == .integer) {
            const minimum = j.get(schema, "minimum");
            const maximum = j.get(schema, "maximum");
            if ((minimum != null and minimum.? == .integer and value.integer < minimum.?.integer) or (maximum != null and maximum.? == .integer and value.integer > maximum.?.integer)) {
                try detail.object.put(a, "field", .{ .string = path });
                try detail.object.put(a, "expected", .{ .string = "integer" });
                if (minimum) |bound| try detail.object.put(a, "minimum", bound);
                if (maximum) |bound| try detail.object.put(a, "maximum", bound);
                try detail.object.put(a, "message", .{ .string = if (minimum != null and maximum != null) try std.fmt.allocPrint(a, "{s}: '{s}' must be an integer from {d} to {d}", .{ command, path, minimum.?.integer, maximum.?.integer }) else if (minimum) |bound| try std.fmt.allocPrint(a, "{s}: '{s}' must be at least {d}", .{ command, path, bound.integer }) else try std.fmt.allocPrint(a, "{s}: '{s}' must be at most {d}", .{ command, path, maximum.?.integer }) });
                return detail;
            }
        } else if (value == .string) {
            const text = value.string;
            if (j.get(schema, "minLength")) |bound| if (bound == .integer and text.len < bound.integer) {
                try detail.object.put(a, "field", .{ .string = path });
                try detail.object.put(a, "minLength", bound);
                try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "{s}: '{s}' must contain at least {d} byte(s)", .{ command, path, bound.integer }) });
                return detail;
            };
            if (j.get(schema, "maxLength")) |bound| if (bound == .integer and text.len > bound.integer) {
                try detail.object.put(a, "field", .{ .string = path });
                try detail.object.put(a, "maxLength", bound);
                try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "{s}: '{s}' must be at most {d} bytes", .{ command, path, bound.integer }) });
                return detail;
            };
            if (eq(j.text(schema, "format"), "date") and !civilDate(text) and !@import("cli_dates.zig").relative(text)) {
                try detail.object.put(a, "field", .{ .string = path });
                try detail.object.put(a, "expected", .{ .string = "YYYY-MM-DD" });
                try detail.object.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "{s}: '{s}' must be a date as YYYY-MM-DD, today, tomorrow, +Nd or a weekday name", .{ command, path }) });
                return detail;
            }
        }
    }
    switch (value) {
        .object => |map| {
            if (try missing(a, found, value, command, path)) |required| return required;
            var it = map.iterator();
            while (it.next()) |field| if (try inspect(a, catalogue, command, try join(a, path, field.key_ptr.*), field.value_ptr.*, try propertySchemas(a, found, field.key_ptr.*), depth + 1)) |nested| return nested;
        },
        .array => |list| {
            var items: std.ArrayList(Value) = .empty;
            for (found) |shape| if (j.get(shape.schema, "items")) |item| try items.append(a, item);
            for (list.items, 0..) |item, index| if (try inspect(a, catalogue, command, try std.fmt.allocPrint(a, "{s}[{d}]", .{ path, index }), item, items.items, depth + 1)) |nested| return nested;
        },
        else => {},
    }
    return null;
}
/// The first absent or empty required field among mandatory (non-alternative) shapes.
fn missing(a: A, found: []const Shape, value: Value, command: []const u8, path: []const u8) !?Value {
    var required: std.ArrayList([]const u8) = .empty;
    if (path.len == 0 and !eq(command, "accounts.list")) try required.append(a, "account");
    for (found) |shape| if (!shape.optional) if (j.get(shape.schema, "required")) |names| if (names == .array) for (names.array.items) |name| if (name == .string and !contains(required.items, name.string)) try required.append(a, name.string);
    for (required.items) |name| {
        const present = j.get(value, name);
        const empty = present != null and present.? == .string and present.?.string.len == 0;
        if (present != null and !empty) continue;
        const field = try join(a, path, name);
        var detail = j.object(a);
        try detail.object.put(a, "field", .{ .string = field });
        try detail.object.put(a, "message", .{ .string = if (empty) try std.fmt.allocPrint(a, "{s}: '{s}' must not be empty", .{ command, field }) else try std.fmt.allocPrint(a, "{s} requires '{s}'", .{ command, field }) });
        var joined: std.ArrayList([]const u8) = .empty;
        for (required.items) |item| try joined.append(a, try join(a, path, item));
        try putList(a, &detail, "required", joined.items);
        return detail;
    }
    return null;
}
const CodeField = struct { code: []const u8, field: []const u8 };
/// Executor codes that always concern one request field.
const code_fields = [_]CodeField{
    .{ .code = "InvalidPageLimit", .field = "limit" },                     .{ .code = "InvalidPrefetchLimit", .field = "prefetchLimit" },
    .{ .code = "InvalidSendDelay", .field = "delaySeconds" },              .{ .code = "InvalidInvitationStatus", .field = "status" },
    .{ .code = "InvalidFollowUpDate", .field = "dueDate" },                .{ .code = "InvalidBodyFormat", .field = "bodyFormat" },
    .{ .code = "InvalidTriageScope", .field = "scope" },                   .{ .code = "InvalidAttachmentDelivery", .field = "delivery" },
    .{ .code = "InvalidContentDigest", .field = "expectedContentDigest" }, .{ .code = "InvalidWindowBoundary", .field = "boundaryReceivedAt" },
    .{ .code = "FollowUpVersionRequired", .field = "expectedVersion" },    .{ .code = "HistoryDeletionRequiresConfirmation", .field = "confirm" },
    .{ .code = "InvalidLabelConfirmation", .field = "confirmName" },       .{ .code = "InvalidCalendarDate", .field = "date" },
    .{ .code = "ConflictingReplyAll", .field = "replyAll" },               .{ .code = "InvalidView", .field = "view" },
    .{ .code = "InvalidBodySelection", .field = "body" },                  .{ .code = "InvalidFields", .field = "fields" },
    .{ .code = "InvalidMaxBodyBytes", .field = "maxBodyBytes" },           .{ .code = "InvalidCivilTime", .field = "date" },
};
fn validationCode(code: []const u8) bool {
    return eq(code, "MissingField") or eq(code, "InvalidRequest") or eq(code, "InvalidField");
}
/// Field-level explanation for a failed request, from the catalogue only.
pub fn diagnose(a: A, catalogue: *Catalogue, request: Value, code: []const u8) !?Value {
    const command = j.text(request, "cmd");
    if (command.len == 0) {
        var detail = j.object(a);
        try detail.object.put(a, "field", .{ .string = "cmd" });
        try detail.object.put(a, "message", .{ .string = "Every request requires a string 'cmd'" });
        try detail.object.put(a, "help", .{ .string = "omagma cli --help commands" });
        return detail;
    }
    const entry = (try catalogue.command(command)) orelse return null;
    const found = try catalogue.shapes(&.{entry});
    if (validationCode(code)) {
        if (try missing(a, found, request, command, "")) |detail| return detail;
        var it = request.object.iterator();
        while (it.next()) |field| if (try inspect(a, catalogue, command, field.key_ptr.*, field.value_ptr.*, try propertySchemas(a, found, field.key_ptr.*), 1)) |detail| return detail;
        return null;
    }
    for (code_fields) |pair| if (eq(pair.code, code)) {
        var field = pair.field;
        var schemas = try propertySchemas(a, found, field);
        if (schemas.len == 0 and eq(field, "prefetchLimit")) {
            field = "limit";
            schemas = try propertySchemas(a, found, field);
        }
        var path = field;
        if (schemas.len == 0) if (j.get(request, "draft") != null) {
            const nested = try catalogue.shapes(try propertySchemas(a, found, "draft"));
            schemas = try propertySchemas(a, nested, field);
            path = try join(a, "draft", field);
        };
        if (schemas.len == 0) return null;
        const value = (if (eq(path, field)) j.get(request, field) else j.get(j.get(request, "draft") orelse .null, field)) orelse .null;
        if (try inspect(a, catalogue, command, path, value, schemas, 1)) |detail| return detail;
        // Describe the accepted shape even when the executor's rule is narrower.
        var detail = j.object(a);
        try detail.object.put(a, "field", .{ .string = path });
        for (try catalogue.shapes(schemas)) |shape| for ([_][]const u8{ "enum", "minimum", "maximum", "format" }) |name| if (j.get(shape.schema, name)) |constraint| if (detail.object.get(name) == null) try detail.object.put(a, name, constraint);
        return detail;
    };
    return null;
}

const Hint = struct { code: []const u8, text: []const u8 };
const hints = [_]Hint{
    .{ .code = "CalendarNotFound", .text = "Use a target.calendar_id from calendar.list for this account; \"primary\" selects the account's primary calendar" },
    .{ .code = "CalendarAccountMismatch", .text = "Use a target.calendar_id returned by calendar.list for this same account" },
    .{ .code = "LabelNotFound", .text = "List label IDs with labels.list (cacheOnly:true reads the downloaded list)" },
    .{ .code = "PathAlreadyExists", .text = "Choose a new destination path; existing files are never overwritten" },
    .{ .code = "UnknownAccount", .text = "Use an enabled address from accounts.list" },
    .{ .code = "AccountDisabled", .text = "Use an enabled address from accounts.list" },
    .{ .code = "MessageNotFound", .text = "Use an id returned by mail.list, mail.search or mail.thread for this same account" },
    .{ .code = "DraftNotFound", .text = "List local drafts with draft.list for this account" },
    .{ .code = "CacheMiss", .text = "Repeat without cacheOnly to fetch it from Gmail" },
    .{ .code = "BodyNotCached", .text = "Repeat without cacheOnly to fetch it from Gmail" },
    .{ .code = "UnknownOutcome", .text = "Do not retry or change operationId; inspect operation.read and the Sent folder first" },
    .{ .code = "ReviewedDraftChanged", .text = "Read the draft again with draft.read, review it and pass its new contentDigest" },
    .{ .code = "InvalidCursor", .text = "Restart the listing without cursor" },
    .{ .code = "QueueNotDue", .text = "Pass wait:true, or use queue.send-now to skip the countdown" },
    .{ .code = "OperationConflict", .text = "Replay the original request unchanged, or use a new operationId for different content" },
    .{ .code = "PermissionDenied", .text = "Check capabilities in accounts.list; widen grants only through the setup workflow" },
    .{ .code = "FollowUpChanged", .text = "Read reminder.list and retry with the returned version" },
    .{ .code = "MissingRecipient", .text = "Add at least one address to to, cc or bcc" },
    .{ .code = "DraftReplaceWouldDropThreading", .text = "Use draft.patch to change only some fields, or pass replace:true to replace the whole draft" },
    .{ .code = "VaultLocked", .text = "Run omagma vault unlock in an interactive terminal" },
    .{ .code = "CacheBusy", .text = "Retry after a short delay" },
    .{ .code = "RateLimited", .text = "Retry after a short delay" },
    .{ .code = "TransientFailure", .text = "Retry after a short delay" },
    .{ .code = "Timeout", .text = "Retry after a short delay; for sends inspect operation.read first" },
    .{ .code = "CacheWindowRequiresCached", .text = "Add cacheOnly:true or remove beforeMessageId/afterMessageId" },
    .{ .code = "EventNotFound", .text = "Use an event id returned by calendar.agenda for this calendar" },
};
const transient = [_][]const u8{ "CacheBusy", "Timeout", "RateLimited", "TransientFailure", "VaultBusy", "OperationPending", "CacheChanged", "NetworkUnreachable", "ConnectionRefused", "ConnectionTimedOut", "ConnectionResetByPeer" };
/// true: the same request may succeed later. false: retrying unchanged is
/// pointless or unsafe. null: depends on context, so the field is omitted.
pub fn retryable(code: []const u8) ?bool {
    if (contains(&transient, code)) return true;
    if (eq(code, "UnknownOutcome") or eq(code, "UnknownField") or eq(code, "UnsupportedCommand") or eq(code, "OperationConflict") or eq(code, "DraftReplaceWouldDropThreading") or eq(code, "PermissionDenied") or eq(code, "CacheWindowRequiresCached")) return false;
    for ([_][]const u8{ "Invalid", "Missing", "Conflicting", "Unknown" }) |prefix| if (std.mem.startsWith(u8, code, prefix)) return false;
    return null;
}
/// Complete error object for a failed request: stable code, a human sentence
/// and, when known, field-level details, a next step and retry guidance.
pub fn explain(a: A, request: ?Value, code: []const u8, message: []const u8, configured: []const []const u8) !Value {
    var detail = j.object(a);
    try detail.object.put(a, "code", .{ .string = code });
    try detail.object.put(a, "message", .{ .string = if (message.len == 0 or eq(message, code)) try error_text.describe(a, code) else message });
    if (request) |value| if (value == .object) {
        const field_code = validationCode(code) or for (code_fields) |pair| {
            if (eq(pair.code, code)) break true;
        } else false;
        if (field_code) {
            var catalogue = try Catalogue.init(a);
            if (try diagnose(a, &catalogue, value, code)) |found| {
                // A field-level diagnosis replaces the generic code sentence.
                var it = found.object.iterator();
                while (it.next()) |field| try detail.object.put(a, field.key_ptr.*, field.value_ptr.*);
                if (detail.object.get("help") == null and j.text(value, "cmd").len != 0) try detail.object.put(a, "help", .{ .string = try std.fmt.allocPrint(a, "omagma cli --schema {s}", .{j.text(value, "cmd")}) });
            }
        }
    };
    if (eq(code, "UnknownAccount")) try putList(a, &detail, "configured", configured);
    for (hints) |hint| if (eq(hint.code, code)) try detail.object.put(a, "hint", .{ .string = hint.text });
    if (retryable(code)) |flag| try detail.object.put(a, "retryable", .{ .bool = flag });
    return detail;
}

fn parseTest(a: A, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, raw, .{});
}
test "cli contract: unknown and misspelled fields fail closed with the nearest declared name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nested = (try check(a, try parseTest(a, "{\"cmd\":\"draft.create\",\"account\":\"fictional@example.test\",\"draft\":{\"to\":[\"alex@example.org\"],\"body\":\"Hi\"}}"))).?;
    try std.testing.expectEqualStrings("UnknownField", j.text(nested, "code"));
    try std.testing.expectEqualStrings("draft.body", j.text(nested, "field"));
    try std.testing.expectEqualStrings("draft.bodyText", j.text(nested, "didYouMean"));
    try std.testing.expectEqualStrings("draft.create has no field 'draft.body'", j.text(nested, "message"));
    try std.testing.expectEqualStrings("omagma cli --schema draft.create", j.text(nested, "help"));
    const top = (try check(a, try parseTest(a, "{\"cmd\":\"mail.read\",\"account\":\"fictional@example.test\",\"message_id\":\"m-1\"}"))).?;
    try std.testing.expectEqualStrings("message_id", j.text(top, "field"));
    try std.testing.expectEqualStrings("messageId", j.text(top, "didYouMean"));
    var listed = false;
    for (j.get(top, "validFields").?.array.items) |item| listed = listed or eq(item.string, "messageId");
    try std.testing.expect(listed);
    const event = (try check(a, try parseTest(a, "{\"cmd\":\"calendar.event-review\",\"account\":\"fictional@example.test\",\"calendarId\":\"primary\",\"operationId\":\"op-1\",\"sendUpdates\":\"none\",\"event\":{\"title\":\"Sync\",\"start\":\"2026-11-12T10:00\",\"end\":\"2026-11-12T10:30\",\"timeZone\":\"UTC\"}}"))).?;
    try std.testing.expectEqualStrings("event.title", j.text(event, "field"));
    try std.testing.expectEqualStrings("event.summary", j.text(event, "didYouMean"));
    // Mutation flags that a command does not declare never vanish silently.
    for ([_][]const u8{
        "{\"cmd\":\"mail.read\",\"account\":\"fictional@example.test\",\"messageId\":\"m-1\",\"dryRun\":true}",
        "{\"cmd\":\"mail.forward\",\"account\":\"fictional@example.test\",\"messageId\":\"m-1\",\"all\":true}",
        "{\"cmd\":\"mail.send\",\"account\":\"fictional@example.test\",\"operationId\":\"op\",\"draft\":{\"to\":\"alex@example.org\",\"attachments\":[{\"id\":\"\",\"filename\":\"a.txt\",\"inline\":true}]}}",
    }) |raw| try std.testing.expectEqualStrings("UnknownField", j.text((try check(a, try parseTest(a, raw))).?, "code"));
    const command = (try check(a, try parseTest(a, "{\"cmd\":\"mail.reed\",\"account\":\"fictional@example.test\"}"))).?;
    try std.testing.expectEqualStrings("UnsupportedCommand", j.text(command, "code"));
    try std.testing.expectEqualStrings("mail.read", j.text(command, "didYouMean"));
    // Declared, transport-envelope, private and malformed-cmd frames pass to the executor.
    for ([_][]const u8{
        "{\"id\":7,\"cmd\":\"mail.reply\",\"account\":\"fictional@example.test\",\"messageId\":\"m-1\",\"replyAll\":true}",
        "{\"cmd\":\"accounts.list\",\"_vaultId\":\"00\",\"_progress\":true}",
        "{\"cmd\":\"preferences.set\",\"preferences\":{\"anything\":{\"nested\":1}}}",
        "{\"cmd\":\"contacts.upsert\",\"account\":\"fictional@example.test\",\"contact\":{\"name\":\"Fictional\",\"emails\":[{\"address\":\"fictional@example.org\"}],\"provider\":{\"opaque\":[1]}}}",
        "{\"cmd\":7}",
        "{\"account\":\"fictional@example.test\"}",
    }) |raw| try std.testing.expect(try check(a, try parseTest(a, raw)) == null);
    try std.testing.expectEqualStrings("UnknownField", j.text((try check(a, try parseTest(a, "{\"cmd\":\"preferences.get\",\"extra\":1}"))).?, "code"));
}
test "cli contract: layout-anchored lookups select exactly the fully scanned entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var catalogue = try Catalogue.init(a);
    try catalogue.full();
    try std.testing.expect(catalogue.commands.items.len > 90 and catalogue.definitions.items.len > 30);
    for (catalogue.commands.items) |entry| try std.testing.expectEqualStrings(entry.bytes, (try catalogue.locateCommand(entry.name)).?);
    for (catalogue.definitions.items) |entry| try std.testing.expectEqualStrings(entry.bytes, (try catalogue.locateDefinition(entry.name)).?);
    try std.testing.expect(try catalogue.locateCommand("mail.fictional") == null);
}
test "cli contract: every catalogue example satisfies the strict request contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const catalogue = try api.load(a);
    var checked: usize = 0;
    for (catalogue.commands) |entry| if (j.get(entry, "examples")) |examples| for (examples.array.items) |example| {
        if (try check(a, example)) |detail| {
            std.debug.print("example for {s} rejected: {s}\n", .{ j.text(entry, "cmd"), j.text(detail, "message") });
            return error.ExampleViolatesContract;
        }
        checked += 1;
    };
    try std.testing.expect(checked > 50);
}
test "cli contract: failures name their field, constraint and next step without changing the code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const required = try explain(a, try parseTest(a, "{\"cmd\":\"mail.read\",\"account\":\"fictional@example.test\"}"), "MissingField", "MissingField", &.{});
    try std.testing.expectEqualStrings("MissingField", j.text(required, "code"));
    try std.testing.expectEqualStrings("messageId", j.text(required, "field"));
    try std.testing.expectEqualStrings("mail.read requires 'messageId'", j.text(required, "message"));
    const nested = try explain(a, try parseTest(a, "{\"cmd\":\"calendar.event-review\",\"account\":\"fictional@example.test\",\"calendarId\":\"primary\",\"operationId\":\"op-1\",\"sendUpdates\":\"none\",\"event\":{\"summary\":\"Sync\",\"start\":\"2026-11-12T10:00\",\"end\":\"2026-11-12T10:30\"}}"), "MissingField", "MissingField", &.{});
    try std.testing.expectEqualStrings("event.timeZone", j.text(nested, "field"));
    const limit = try explain(a, try parseTest(a, "{\"cmd\":\"mail.list\",\"account\":\"fictional@example.test\",\"limit\":500}"), "InvalidPageLimit", "InvalidPageLimit", &.{});
    try std.testing.expectEqualStrings("InvalidPageLimit", j.text(limit, "code"));
    try std.testing.expectEqualStrings("limit", j.text(limit, "field"));
    try std.testing.expectEqual(@as(i64, 100), j.get(limit, "maximum").?.integer);
    try std.testing.expectEqualStrings("mail.list: 'limit' must be an integer from 1 to 100", j.text(limit, "message"));
    try std.testing.expect(!j.get(limit, "retryable").?.bool);
    const typed = try explain(a, try parseTest(a, "{\"cmd\":\"mail.list\",\"account\":\"fictional@example.test\",\"limit\":\"3\"}"), "InvalidRequest", "Expected string command fields", &.{});
    try std.testing.expectEqualStrings("limit", j.text(typed, "field"));
    try std.testing.expectEqualStrings("integer", j.text(typed, "expected"));
    const status = try explain(a, try parseTest(a, "{\"cmd\":\"invitation.reply\",\"account\":\"fictional@example.test\",\"messageId\":\"m\",\"operationId\":\"op\",\"status\":\"yes\"}"), "InvalidInvitationStatus", "InvalidInvitationStatus", &.{});
    try std.testing.expectEqual(@as(usize, 3), j.get(status, "enum").?.array.items.len);
    const account = try explain(a, try parseTest(a, "{\"cmd\":\"mail.read\",\"account\":\"nobody@example.test\",\"messageId\":\"m\"}"), "UnknownAccount", "Choose an explicitly configured account", &.{ "one@example.test", "two@example.test" });
    try std.testing.expectEqual(@as(usize, 2), j.get(account, "configured").?.array.items.len);
    try std.testing.expect(j.get(account, "hint") != null);
    const busy = try explain(a, null, "CacheBusy", "", &.{});
    try std.testing.expect(j.get(busy, "retryable").?.bool);
    try std.testing.expect(!j.get(try explain(a, null, "UnknownOutcome", "Outcome is unknown; do not automatically retry", &.{}), "retryable").?.bool);
    try std.testing.expect(j.get(try explain(a, null, "ProviderRejected", "", &.{}), "retryable") == null);
    try std.testing.expectEqualStrings("The provider rejected the request", j.text(try explain(a, null, "ProviderRejected", "ProviderRejected", &.{}), "message"));
}
test "cli contract: nearest names prefer documented synonyms, loose spelling and short edits" {
    const fields = [_][]const u8{ "messageId", "threadId", "bodyText", "bodyFormat", "all", "summary" };
    try std.testing.expectEqualStrings("messageId", nearest("message_id", &fields).?);
    try std.testing.expectEqualStrings("messageId", nearest("mesageId", &fields).?);
    try std.testing.expectEqualStrings("bodyText", nearest("body", &fields).?);
    try std.testing.expectEqualStrings("all", nearest("replyAll", &fields).?);
    try std.testing.expectEqualStrings("summary", nearest("title", &fields).?);
    try std.testing.expect(nearest("fictionalUnrelatedName", &fields) == null);
}
