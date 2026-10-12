const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @panic("Use exact Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information from native and browser binaries") orelse false;
    const macos_sdk = if (target.result.os.tag == .macos) b.option([]const u8, "macos-sdk", "Path to the macOS SDK for explicit deployment targets") orelse if (builtin.os.tag == .macos) std.mem.trim(u8, b.run(&.{ "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n\t") else @panic("macOS targets require -Dmacos-sdk=/absolute/SDK/path") else null;
    const test_filter = b.option([]const u8, "test-filter", "Run only correctness tests containing this text");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const tui_enabled = b.option(bool, "tui", "Include the libvaxis terminal client") orelse true;
    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_enabled = b.option(bool, "browser", "Build WebAssembly and embed its page for omagma server") orelse false;
    const browser_vaxis = if (browser_enabled) b.lazyDependency("vaxis", .{ .target = browser_target, .optimize = optimize }) else null;
    const browser_step = b.step("browser", "Build the browser TUI WebAssembly module");
    var browser_assets: ?std.Build.LazyPath = null;
    if (browser_vaxis) |v| {
        const browser_module = b.createModule(.{
            .root_source_file = b.path("src/browser.zig"),
            .target = browser_target,
            .optimize = optimize,
            .strip = strip,
        });
        browser_module.addImport("vaxis", v.module("vaxis"));
        const browser_options = b.addOptions();
        browser_options.addOption([]const u8, "version", @import("build.zig.zon").version);
        browser_options.addOption(bool, "tui", true);
        browser_module.addOptions("build_options", browser_options);
        const browser = b.addExecutable(.{ .name = "omagma", .root_module = browser_module, .use_llvm = true });
        browser.entry = .disabled;
        browser.rdynamic = true;
        browser.export_memory = true;
        browser.initial_memory = 96 * 1024 * 1024;
        browser.max_memory = 96 * 1024 * 1024;
        browser.stack_size = 2 * 1024 * 1024;
        browser_step.dependOn(&b.addInstallArtifact(browser, .{ .dest_dir = .{ .override = .{ .custom = "web-demo" } } }).step);
        const package = b.addSystemCommand(&.{"node"});
        package.addFileArg(b.path("web-demo/build.mjs"));
        package.addArg("--wasm");
        package.addArtifactArg(browser);
        package.addArg("--out-dir");
        browser_assets = package.addOutputDirectoryArg("site");
        for ([_][]const u8{ "app.mjs", "credentials.mjs", "transport.mjs", "bridge.mjs", "cache.mjs", "drafts.mjs", "index.html", "style.css", "package.json", "package-lock.json" }) |source| package.addFileInput(b.path(b.fmt("web-demo/{s}", .{source})));
        package.addFileInput(b.path("assets/omagma-logo.png"));
    }
    const vaxis = if (tui_enabled) b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize }) else null;
    const m = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.abi == .musl or target.result.os.tag == .macos,
        .strip = strip,
    });
    if (macos_sdk) |sdk| linkNativeKeychain(m, sdk);
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption(bool, "tui", vaxis != null);
    options.addOption(bool, "browser", browser_assets != null);
    m.addOptions("build_options", options);
    const generated = b.addWriteFiles();
    const assets_module = b.createModule(.{ .root_source_file = generated.add("browser_assets.zig", embeddedAssetSource(browser_assets != null)), .target = target, .optimize = optimize });
    if (browser_assets) |directory| _ = generated.addCopyDirectory(directory, "assets", .{});
    m.addImport("browser_assets", assets_module);
    const browser_export_module = b.createModule(.{ .root_source_file = b.path("src/browser_export_main.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos });
    if (macos_sdk) |sdk| linkNativeKeychain(browser_export_module, sdk);
    const browser_export = b.addExecutable(.{ .name = "omagma-browser-export", .root_module = browser_export_module, .linkage = if (target.result.os.tag == .linux) .static else null });
    b.step("browser-export", "Build the offline private browser connection exporter").dependOn(&b.addInstallArtifact(browser_export, .{}).step);
    const browser_export_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_export_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(browser_export_tests.root_module, sdk);
    b.step("test-browser-export", "Check private browser export with synthetic file credentials").dependOn(&b.addRunArtifact(browser_export_tests).step);
    const browser_server_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_server_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    b.step("test-browser-server", "Check bounded browser static HTTP handling").dependOn(&b.addRunArtifact(browser_server_tests).step);
    const browser_cache_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_cache_tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test-browser-cache", "Check bounded account-scoped browser snapshots").dependOn(&b.addRunArtifact(browser_cache_tests).step);
    const browser_provider_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_provider_tests.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(browser_provider_tests.root_module, sdk);
    b.step("test-browser-provider", "Check browser Client isolation and uncertain-send contracts").dependOn(&b.addRunArtifact(browser_provider_tests).step);
    const contact_isolation_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/contact_isolation_tests.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(contact_isolation_tests.root_module, sdk);
    b.step("test-contacts", "Check shared contact-page refusal isolation").dependOn(&b.addRunArtifact(contact_isolation_tests).step);
    const mailbox_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_mail_actions_tests.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(mailbox_tests.root_module, sdk);
    b.step("test-browser-mail-actions", "Check shared browser mailbox mutations and per-item undo").dependOn(&b.addRunArtifact(mailbox_tests).step);
    if (vaxis) |v| m.addImport("vaxis", v.module("vaxis"));
    const exe = b.addExecutable(.{ .name = "omagma", .root_module = m, .linkage = if (target.result.os.tag == .linux) .static else null, .use_llvm = if (vaxis != null) true else null });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run omagma").dependOn(&run.step);
    const t = b.addTest(.{ .root_module = m, .filters = test_filters, .use_llvm = if (vaxis != null) true else null });
    const correctness = b.step("test", "Run correctness tests");
    correctness.dependOn(&b.addRunArtifact(t).step);
    for ([_][]const u8{ "src/terminal_codec_tests.zig", "src/terminal_provider_tests.zig", "src/terminal_mail_acceptance_tests.zig", "src/terminal_ux_backend_tests.zig", "src/terminal_ux_helper_tests.zig", "src/platform_tests.zig", "src/updates_tests.zig" }) |path| {
        const terminal_test = b.addTest(.{ .filters = test_filters, .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
        terminal_test.root_module.addOptions("build_options", options);
        if (macos_sdk) |sdk| linkNativeKeychain(terminal_test.root_module, sdk);
        correctness.dependOn(&b.addRunArtifact(terminal_test).step);
    }

    const probes = b.step("probes", "Compile all standalone transport/auth/budget probes");
    for ([_][]const u8{ "src/auth_probe.zig", "src/transport_probe.zig", "src/terminal_stream_probe.zig", "tests/probes/callback_budget.zig" }) |path| {
        const probe = b.addExecutable(.{
            .name = std.fs.path.stem(path),
            .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }),
            .linkage = if (target.result.os.tag == .linux) .static else null,
        });
        if (std.mem.eql(u8, path, "tests/probes/callback_budget.zig")) {
            probe.root_module.addImport("oauth", b.createModule(.{ .root_source_file = b.path("src/oauth.zig"), .target = target, .optimize = optimize }));
        }
        if (macos_sdk) |sdk| linkNativeKeychain(probe.root_module, sdk);
        probes.dependOn(&b.addInstallArtifact(probe, .{}).step);
    }
}

fn embeddedAssetSource(enabled: bool) []const u8 {
    if (!enabled) return "pub fn assets(comptime Asset: type) [0]Asset { return .{}; }\n";
    return
    \\pub fn assets(comptime Asset: type) [9]Asset {
    \\    return .{
    \\        .{ .path = "/index.html", .mime = "text/html; charset=utf-8", .bytes = @embedFile("assets/index.html") },
    \\        .{ .path = "/app.mjs", .mime = "text/javascript; charset=utf-8", .bytes = @embedFile("assets/app.mjs") },
    \\        .{ .path = "/style.css", .mime = "text/css; charset=utf-8", .bytes = @embedFile("assets/style.css") },
    \\        .{ .path = "/omagma-logo.png", .mime = "image/png", .bytes = @embedFile("assets/omagma-logo.png") },
    \\        .{ .path = "/xterm.css", .mime = "text/css; charset=utf-8", .bytes = @embedFile("assets/xterm.css") },
    \\        .{ .path = "/omagma.wasm", .mime = "application/wasm", .bytes = @embedFile("assets/omagma.wasm") },
    \\        .{ .path = "/app.mjs.LEGAL.txt", .mime = "text/plain; charset=utf-8", .bytes = @embedFile("assets/app.mjs.LEGAL.txt") },
    \\        .{ .path = "/LICENSE-xterm.txt", .mime = "text/plain; charset=utf-8", .bytes = @embedFile("assets/LICENSE-xterm.txt") },
    \\        .{ .path = "/LICENSE-xterm-addon-fit.txt", .mime = "text/plain; charset=utf-8", .bytes = @embedFile("assets/LICENSE-xterm-addon-fit.txt") },
    \\    };
    \\}
    \\
    ;
}

fn linkNativeKeychain(module: *std.Build.Module, sdk: []const u8) void {
    module.addSystemFrameworkPath(.{ .cwd_relative = module.owner.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    module.addLibraryPath(.{ .cwd_relative = module.owner.fmt("{s}/usr/lib", .{sdk}) });
    module.linkSystemLibrary("proc", .{});
    module.linkFramework("Security", .{});
    module.linkFramework("CoreFoundation", .{});
}
