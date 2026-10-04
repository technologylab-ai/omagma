const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @panic("Use exact Zig 0.17.0");
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
    run.addPassthruArgs();
    b.step("run", "Run omagma").dependOn(&run.step);
    const t = b.addTest(.{ .root_module = m });
    b.step("test", "Run correctness tests").dependOn(&b.addRunArtifact(t).step);

    const probes = b.step("probes", "Compile all standalone transport/auth/budget probes");
    for ([_][]const u8{ "src/auth_probe.zig", "src/transport_probe.zig", "tests/probes/callback_budget.zig" }) |path| {
        const probe = b.addExecutable(.{
            .name = std.fs.path.stem(path),
            .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl }),
            .linkage = .static,
        });
        if (std.mem.eql(u8, path, "tests/probes/callback_budget.zig")) {
            probe.root_module.addImport("oauth", b.createModule(.{ .root_source_file = b.path("src/oauth.zig"), .target = target, .optimize = optimize }));
        }
        probes.dependOn(&b.addInstallArtifact(probe, .{}).step);
    }
}
