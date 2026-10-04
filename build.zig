const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0")) @panic("Use exact Zig 0.16.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const m = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.abi == .musl,
        .strip = b.option(bool, "strip", "Strip debug information from the binary") orelse false,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    m.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "omagma", .root_module = m, .linkage = .static });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run omagma").dependOn(&run.step);
    const t = b.addTest(.{ .root_module = m });
    b.step("test", "Run correctness tests").dependOn(&b.addRunArtifact(t).step);
}
