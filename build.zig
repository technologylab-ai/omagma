const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0")) @panic("Use exact Zig 0.16.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const m = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "omagma", .root_module = m });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run omagma").dependOn(&run.step);
    const t = b.addTest(.{ .root_module = m });
    b.step("test", "Run correctness tests").dependOn(&b.addRunArtifact(t).step);
}
