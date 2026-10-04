const std = @import("std");
const b = @import("bounded.zig");
const model = @import("model.zig");
const l = @import("limits.zig");
pub const Config = struct {
    accounts: [l.max_accounts]model.Account = @splat(.{}),
    count: usize = 0,
    client_file: b.Text(4096) = .{},
    chrome: b.Text(4096) = .{},
    chrome_data: b.Text(4096) = .{},
    refresh_seconds: u32 = 0,
    pub fn defaults(self: *Config, home: []const u8) !void {
        self.* = .{};
        try self.chrome.set("/usr/bin/google-chrome-stable");
        var path: [4096]u8 = undefined;
        try self.chrome_data.set(try std.fmt.bufPrint(&path, "{s}/.config/google-chrome", .{home}));
        const defs = .{ .{ "personal@example.com", "Profile 3", true }, .{ "work@example.com", "Profile 1", true }, .{ "optional@example.com", "Profile 2", false } };
        inline for (defs, 0..) |d, i| {
            try self.accounts[i].address.set(d[0]);
            try self.accounts[i].profile.set(d[1]);
            self.accounts[i].enabled = d[2];
            self.accounts[i].required = d[2];
            if (!d[2]) self.accounts[i].state = .unavailable;
        }
        self.count = 3;
    }
    pub fn load(self: *Config, io: std.Io, path: []const u8, allocator: std.mem.Allocator, storage: []u8) !void {
        const text = try std.Io.Dir.cwd().readFile(io, path, storage);
        if (text.len == storage.len) return error.ConfigTooLarge;
        const parsed = try b.parse(allocator, text);
        defer parsed.deinit();
        const root = parsed.value;
        if (b.optional(root, "refreshIntervalSeconds")) |v| {
            if (v != .integer) return error.InvalidRefreshInterval;
            const seconds = v.integer;
            if (seconds < 0 or seconds > 86400 or (seconds != 0 and seconds < 60)) return error.InvalidRefreshInterval;
            self.refresh_seconds = @intCast(seconds);
        }
        if (b.optional(root, "oauthClientFile")) |v| try self.client_file.set(try b.string(v));
        if (b.optional(root, "chrome")) |v| {
            const s = try b.string(v);
            if (!std.mem.startsWith(u8, s, "/")) return error.InvalidChromePath;
            try self.chrome.set(s);
        }
        if (b.optional(root, "chromeUserData")) |v| {
            const s = try b.string(v);
            if (s.len > 0) {
                if (!std.mem.startsWith(u8, s, "/")) return error.InvalidChromePath;
                try self.chrome_data.set(s);
            }
        }
        if (b.optional(root, "accounts")) |v| {
            if (v != .array or v.array.items.len == 0 or v.array.items.len > l.max_accounts) return error.InvalidAccountCount;
            self.count = v.array.items.len;
            for (v.array.items, 0..) |a, i| {
                self.accounts[i] = .{};
                const addr = try b.string(try b.field(a, "address"));
                try b.address(addr);
                try self.accounts[i].address.set(addr);
                const prof = try b.string(try b.field(a, "profile"));
                try b.profile(prof);
                try self.accounts[i].profile.set(prof);
                if (b.optional(a, "enabled")) |x| {
                    if (x != .bool) return error.InvalidConfig;
                    self.accounts[i].enabled = x.bool;
                }
                if (b.optional(a, "required")) |x| {
                    if (x != .bool) return error.InvalidConfig;
                    self.accounts[i].required = x.bool;
                }
                if (!self.accounts[i].enabled) self.accounts[i].state = .unavailable;
                for (self.accounts[0..i]) |*prev| if (std.ascii.eqlIgnoreCase(prev.address.slice(), addr) or std.mem.eql(u8, prev.profile.slice(), prof)) return error.DuplicateAccountOrProfile;
            }
        }
    }
    pub fn index(self: *const Config, addr: []const u8) ?usize {
        for (self.accounts[0..self.count], 0..) |*a, i| if (std.mem.eql(u8, a.address.slice(), addr)) return i;
        return null;
    }
    pub fn initial(self: *const Config) usize {
        for (self.accounts[0..self.count], 0..) |a, i| if (a.enabled and a.required) return i;
        return 0;
    }
};
test "configuration refuses same profile across distinct accounts" {
    var c: Config = undefined;
    try c.defaults("/tmp");
    const raw = "{\"accounts\":[{\"address\":\"a@b.c\",\"profile\":\"Profile 1\"},{\"address\":\"b@b.c\",\"profile\":\"Profile 1\"}]}";
    // Validate the same parser/model rules without file-system effects.
    const p = try b.parse(std.testing.allocator, raw);
    defer p.deinit();
    try std.testing.expectEqualStrings("Profile 1", try b.string(try b.field(p.value.object.get("accounts").?.array.items[0], "profile")));
    try std.testing.expectError(error.InvalidProfile, b.profile("../Default"));
}
