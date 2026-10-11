//! The local server supplies an in-memory connection bundle on an explicitly
//! authenticated browser request. Native storage remains selected and intact.
const std = @import("std");
const server = @import("browser_server.zig");
const exporter = @import("browser_export.zig");

const Context = struct {
    home: []const u8,
    config: []const u8,
    grants: []const u8,
    mutex: std.Io.Mutex = .init,

    fn load(opaque_context: *anyopaque, io: std.Io, output: []u8) anyerror![]const u8 {
        const self: *Context = @ptrCast(@alignCast(opaque_context));
        // The native credential helpers own shared bounded workspaces.
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        var workspace: [512 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &workspace);
        var fixed = std.heap.FixedBufferAllocator.init(&workspace);
        const result = try exporter.collect(io, fixed.allocator(), self.home, self.config, self.grants, output);
        return result.bytes;
    }
};

pub fn run(init: std.process.Init, io: std.Io, args: *std.process.Args.Iterator, assets: []const server.Asset) !void {
    var port: u16 = 8766;
    var config: ?[]const u8 = null;
    var grants: ?[]const u8 = null;
    while (args.next()) |option| {
        const value = args.next() orelse return error.ValueRequired;
        if (std.mem.eql(u8, option, "--port")) {
            port = try server.parsePort(value);
        } else if (std.mem.eql(u8, option, "--config")) config = value else if (std.mem.eql(u8, option, "--grant-file")) grants = value else return error.UnknownOption;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    var path_storage: [12 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&path_storage);
    const allocator = fixed.allocator();
    const base = init.environ_map.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    var context: Context = .{
        .home = home,
        .config = config orelse try std.fmt.allocPrint(allocator, "{s}/omagma/config.json", .{base}),
        .grants = grants orelse try std.fmt.allocPrint(allocator, "{s}/omagma/terminal-grants.json", .{base}),
    };
    var random: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &random);
    try io.randomSecure(&random);
    var nonce = std.fmt.bytesToHex(random, .lower);
    defer std.crypto.secureZero(u8, &nonce);
    return server.serve(io, assets, .{ .port = port, .connection = .{ .context = &context, .nonce = &nonce, .load = Context.load } });
}
