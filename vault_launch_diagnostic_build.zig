const std = @import("std");
const production = @import("build.zig");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const source = b.option([]const u8, "source", "Private diagnostic root") orelse @panic("source required");
    const watchdog = b.option(bool, "test-watchdog", "Use unchanged production guardian") orelse false;
    if (!watchdog) @panic("diagnostic requires the production watchdog");
    const module = b.createModule(.{ .root_source_file = .{ .cwd_relative = source }, .target = target, .optimize = optimize, .link_libc = true });
    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.2.13");
    options.addOption(bool, "tui", true);
    options.addOption(bool, "browser", false);
    module.addOptions("build_options", options);
    if (target.result.os.tag == .macos) {
        const sdk = b.option([]const u8, "macos-sdk", "Native SDK") orelse @panic("SDK required");
        module.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
        module.linkSystemLibrary("proc", .{});
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    const artifact = b.addTest(.{ .name = "vault-launch-test", .root_module = module, .filters = &.{"vault launch:"}, .use_llvm = true });
    const run = production.guardedTestRun(b, artifact, watchdog);
    run.setCwd(.{ .cwd_relative = std.fs.path.dirname(source).? });
    b.step("test", "Run only focused readiness tests through the actual Maker/guardian protocol").dependOn(&run.step);
}
