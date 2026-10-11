const std = @import("std");
const exporter = @import("browser_export.zig");
const keyring = @import("keyring.zig");
pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        std.debug.print("omagma-browser-export: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn execute(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const first = args.next() orelse return error.OutputRequired;
    if (std.mem.eql(u8, first, "keychain-worker")) {
        var command: [5][]const u8 = undefined;
        for (&command) |*argument| argument.* = args.next() orelse return error.InvalidArgv;
        if (args.next() != null) return error.InvalidArgv;
        return keyring.runNativeWorker(init.io, &command);
    }
    var config: ?[]const u8 = null;
    var grants: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var option: ?[]const u8 = first;
    while (option) |name| : (option = args.next()) {
        const value = args.next() orelse return error.ValueRequired;
        if (std.mem.eql(u8, name, "--config")) config = value else if (std.mem.eql(u8, name, "--grant-file")) grants = value else if (std.mem.eql(u8, name, "--output")) output = value else return error.UnknownOption;
    }
    var workspace: [512 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &workspace);
    var fixed = std.heap.FixedBufferAllocator.init(&workspace);
    const result = try exporter.run(init.io, fixed.allocator(), init.environ_map.get("HOME") orelse return error.HomeRequired, config orelse return error.ConfigRequired, grants orelse return error.GrantFileRequired, output orelse return error.OutputRequired);
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("Exported browser connection file for {d} account(s).\n", .{result.exportedAccounts});
    try writer.interface.flush();
}
