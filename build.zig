const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @panic("Use exact Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only correctness tests containing this text");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const tui_enabled = b.option(bool, "tui", "Include the libvaxis terminal client") orelse true;
    const vaxis = if (tui_enabled) b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize }) else null;
    const m = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.abi == .musl or target.result.os.tag == .macos,
        .strip = b.option(bool, "strip", "Strip debug information from the binary") orelse false,
    });
    if (target.result.os.tag == .macos) linkNativeKeychain(m);
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption(bool, "tui", vaxis != null);
    m.addOptions("build_options", options);
    if (vaxis) |v| m.addImport("vaxis", v.module("vaxis"));
    const exe = b.addExecutable(.{ .name = "omagma", .root_module = m, .linkage = if (target.result.os.tag == .linux) .static else null, .use_llvm = if (vaxis != null) true else null });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run omagma").dependOn(&run.step);
    const t = b.addTest(.{ .root_module = m, .filters = test_filters, .use_llvm = if (vaxis != null) true else null });
    const correctness = b.step("test", "Run correctness tests");
    correctness.dependOn(&b.addRunArtifact(t).step);
    for ([_][]const u8{ "src/terminal_codec_tests.zig", "src/terminal_provider_tests.zig" }) |path| {
        const terminal_test = b.addTest(.{ .filters = test_filters, .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
        if (target.result.os.tag == .macos) linkNativeKeychain(terminal_test.root_module);
        correctness.dependOn(&b.addRunArtifact(terminal_test).step);
    }

    const probes = b.step("probes", "Compile all standalone transport/auth/budget probes");
    for ([_][]const u8{ "src/auth_probe.zig", "src/transport_probe.zig", "tests/probes/callback_budget.zig" }) |path| {
        const probe = b.addExecutable(.{
            .name = std.fs.path.stem(path),
            .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }),
            .linkage = if (target.result.os.tag == .linux) .static else null,
        });
        if (std.mem.eql(u8, path, "tests/probes/callback_budget.zig")) {
            probe.root_module.addImport("oauth", b.createModule(.{ .root_source_file = b.path("src/oauth.zig"), .target = target, .optimize = optimize }));
        }
        if (target.result.os.tag == .macos) linkNativeKeychain(probe.root_module);
        probes.dependOn(&b.addInstallArtifact(probe, .{}).step);
    }
}

fn linkNativeKeychain(module: *std.Build.Module) void {
    module.linkFramework("Security", .{});
    module.linkFramework("CoreFoundation", .{});
}
