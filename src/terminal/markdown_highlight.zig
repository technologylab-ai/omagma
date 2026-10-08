//! A bounded lexical colour pass for email code fences. It never parses,
//! executes, loads grammars or changes the code's bytes; unknown languages
//! receive the same escaped literal treatment without colours.
const std = @import("std");
pub const Kind = enum { literal, keyword, string, comment, number };
pub const Token = struct { text: []const u8, kind: Kind = .literal };
pub const Lexer = struct {
    source: []const u8,
    language: []const u8,
    pos: usize = 0,

    pub fn next(self: *Lexer) ?Token {
        if (self.pos == self.source.len) return null;
        const start = self.pos;
        const s = self.source;
        if (!known(self.language)) {
            self.pos = s.len;
            return .{ .text = s };
        }
        const hash_comments = oneOf(self.language, &.{ "python", "py", "bash", "sh", "shell", "ruby", "rb", "yaml", "yml" });
        const sql = oneOf(self.language, &.{"sql"});
        if ((hash_comments and s[start] == '#') or (start + 1 < s.len and ((sql and std.mem.startsWith(u8, s[start..], "--")) or (!sql and !hash_comments and std.mem.startsWith(u8, s[start..], "//"))))) {
            while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            return .{ .text = s[start..self.pos], .kind = .comment };
        }
        if (!hash_comments and start + 1 < s.len and std.mem.startsWith(u8, s[start..], "/*")) {
            self.pos += 2;
            while (self.pos < s.len) : (self.pos += 1) {
                if (self.pos + 1 < s.len and std.mem.startsWith(u8, s[self.pos..], "*/")) {
                    self.pos += 2;
                    break;
                }
            }
            return .{ .text = s[start..self.pos], .kind = .comment };
        }
        if (s[start] == '"' or s[start] == '\'' or s[start] == '`') {
            const quote = s[start];
            self.pos += 1;
            while (self.pos < s.len) {
                const c = s[self.pos];
                self.pos += 1;
                if (c == '\\' and self.pos < s.len) self.pos += 1 else if (c == quote) break;
            }
            return .{ .text = s[start..self.pos], .kind = .string };
        }
        if (std.ascii.isDigit(s[start]) and (start == 0 or !word(s[start - 1]))) {
            self.pos += 1;
            while (self.pos < s.len and (std.ascii.isAlphanumeric(s[self.pos]) or s[self.pos] == '.' or s[self.pos] == '_')) self.pos += 1;
            return .{ .text = s[start..self.pos], .kind = .number };
        }
        if (word(s[start])) {
            self.pos += 1;
            while (self.pos < s.len and word(s[self.pos])) self.pos += 1;
            const text = s[start..self.pos];
            return .{ .text = text, .kind = if (keyword(text, sql)) .keyword else .literal };
        }
        self.pos += 1;
        while (self.pos < s.len and !word(s[self.pos]) and std.mem.indexOfScalar(u8, "\"'`#/", s[self.pos]) == null and !(sql and s[self.pos] == '-')) self.pos += 1;
        return .{ .text = s[start..self.pos] };
    }
};
fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}
fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(value, choice)) return true;
    return false;
}
pub fn known(language: []const u8) bool {
    return oneOf(language, &.{ "zig", "javascript", "js", "typescript", "ts", "json", "python", "py", "bash", "sh", "shell", "sql", "rust", "rs", "c", "cpp", "c++", "go", "java", "ruby", "rb", "yaml", "yml" });
}
fn keyword(text: []const u8, sql: bool) bool {
    if (sql) return oneOf(text, &.{ "select", "from", "where", "join", "on", "as", "and", "or", "not", "null", "insert", "into", "values", "update", "set", "delete", "create", "table", "order", "by", "group", "having", "limit", "distinct", "case", "when", "then", "else", "end" });
    for ([_][]const u8{ "const", "var", "let", "fn", "function", "def", "pub", "return", "if", "else", "elif", "for", "while", "break", "continue", "switch", "match", "try", "catch", "defer", "errdefer", "struct", "enum", "union", "class", "import", "from", "as", "export", "async", "await", "true", "false", "null", "undefined", "None", "True", "False", "and", "or", "not", "in", "is", "new", "throw", "throws", "comptime", "test", "void", "int", "bool", "float", "double", "char", "static", "private", "public", "protected", "package", "func", "type", "interface", "impl", "use", "mut", "self", "Self", "do", "done", "then", "fi", "echo", "local" }) |choice| if (std.mem.eql(u8, text, choice)) return true;
    return false;
}

test "markdown mail: lexical highlighting preserves source bytes and unknown languages" {
    const source = "const n = 42; // <tag>\nconst s = \"<script>\";";
    var lexer: Lexer = .{ .source = source, .language = "zig" };
    var offset: usize = 0;
    var kinds: [5]bool = @splat(false);
    while (lexer.next()) |token| {
        try std.testing.expectEqualStrings(source[offset .. offset + token.text.len], token.text);
        offset += token.text.len;
        kinds[@backingInt(token.kind)] = true;
    }
    try std.testing.expectEqual(source.len, offset);
    for (kinds) |seen| try std.testing.expect(seen);
    lexer = .{ .source = source, .language = "unknown-language" };
    try std.testing.expectEqualStrings(source, lexer.next().?.text);
    try std.testing.expect(lexer.next() == null);
}
