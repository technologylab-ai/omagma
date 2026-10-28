const std = @import("std");
const builtin = @import("builtin");

const HistoryCase = enum { all, calendar, @"sends-plain", @"sends-vault", @"files-plain", @"files-vault" };

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @panic("Use exact Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information from native and browser binaries") orelse false;
    const macos_sdk = if (target.result.os.tag == .macos) b.option([]const u8, "macos-sdk", "Path to the macOS SDK for explicit deployment targets") orelse if (builtin.os.tag == .macos) std.mem.trim(u8, b.run(&.{ "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n\t") else @panic("macOS targets require -Dmacos-sdk=/absolute/SDK/path") else null;
    const test_watchdog = b.option(bool, "test-watchdog", "Supervise native test timeout cleanup (requires Python 3)") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Run only correctness tests containing this text");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const history_case = b.option(HistoryCase, "history-case", "Run one retained-history lifecycle, or all five") orelse .all;
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
    b.step("test-browser-export", "Check private browser export with synthetic file credentials").dependOn(&guardedTestRun(b, browser_export_tests, test_watchdog).step);
    const browser_server_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_server_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    b.step("test-browser-server", "Check bounded browser static HTTP handling").dependOn(&guardedTestRun(b, browser_server_tests, test_watchdog).step);
    const browser_cache_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_cache_tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test-browser-cache", "Check bounded account-scoped browser snapshots").dependOn(&guardedTestRun(b, browser_cache_tests, test_watchdog).step);
    const browser_provider_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_provider_tests.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(browser_provider_tests.root_module, sdk);
    b.step("test-browser-provider", "Check browser Client isolation and uncertain-send contracts").dependOn(&guardedTestRun(b, browser_provider_tests, test_watchdog).step);
    const contact_isolation_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/contact_isolation_tests.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(contact_isolation_tests.root_module, sdk);
    b.step("test-contacts", "Check shared contact-page refusal isolation").dependOn(&guardedTestRun(b, contact_isolation_tests, test_watchdog).step);
    const mailbox_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/browser_mail_actions_tests.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    if (macos_sdk) |sdk| linkNativeKeychain(mailbox_tests.root_module, sdk);
    b.step("test-browser-mail-actions", "Check shared browser mailbox mutations and per-item undo").dependOn(&guardedTestRun(b, mailbox_tests, test_watchdog).step);
    if (vaxis) |v| m.addImport("vaxis", v.module("vaxis"));
    const exe = b.addExecutable(.{ .name = "omagma", .root_module = m, .linkage = if (target.result.os.tag == .linux) .static else null, .use_llvm = if (vaxis != null) true else null });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run omagma").dependOn(&run.step);
    const t = b.addTest(.{ .root_module = m, .filters = test_filters, .use_llvm = if (vaxis != null) true else null });
    const correctness = b.step("test", "Run correctness tests");
    const main_correctness = b.step("test-main", "Run application and TUI correctness tests");
    main_correctness.dependOn(&guardedTestRun(b, t, test_watchdog).step);
    correctness.dependOn(main_correctness);

    // Import the extra suites into one root so shared modules and their tests
    // are compiled and run once instead of in thirty-one separate binaries.
    const extra_tests = b.addTest(.{ .filters = test_filters, .root_module = b.createModule(.{ .root_source_file = b.path("src/correctness_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }) });
    extra_tests.root_module.addOptions("build_options", options);
    if (macos_sdk) |sdk| linkNativeKeychain(extra_tests.root_module, sdk);
    const extra_correctness = b.step("test-extra", "Run shared terminal, Calendar and vault correctness tests");
    extra_correctness.dependOn(&guardedTestRun(b, extra_tests, test_watchdog).step);
    correctness.dependOn(extra_correctness);

    // This root exercises the application's real one-MiB worker stack;
    // retain separate LLVM code generation so aggregate-copy regressions are gated.
    const memory_tests = b.addTest(.{ .filters = test_filters, .root_module = b.createModule(.{ .root_source_file = b.path("src/native_memory_ux_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }), .use_llvm = true });
    memory_tests.root_module.addOptions("build_options", options);
    if (macos_sdk) |sdk| linkNativeKeychain(memory_tests.root_module, sdk);
    const memory_correctness = b.step("test-native-memory", "Run native worker stack correctness tests with LLVM");
    memory_correctness.dependOn(&guardedTestRun(b, memory_tests, test_watchdog).step);
    correctness.dependOn(memory_correctness);

    // This complete growing-store chain intentionally performs many large
    // operations. Qualification gives this new stress target its own bounded
    // deadline; ordinary correctness tests retain their existing timeout.
    const send_stress = b.addTest(.{
        .filters = &.{"native growing thread stress:"},
        .root_module = b.createModule(.{ .root_source_file = b.path("src/native_send_stress_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }),
    });
    send_stress.root_module.addOptions("build_options", options);
    if (macos_sdk) |sdk| linkNativeKeychain(send_stress.root_module, sdk);
    b.step("test-native-send-stress", "Verify a complete growing native mail chain near Gmail's size limit").dependOn(&guardedTestRun(b, send_stress, test_watchdog).step);

    // Disk-backed lifetime histories deliberately cross the former admission
    // ceilings. Keep these mandatory qualification cases out of ordinary
    // correctness roots, whose per-test deadline remains 120 seconds.
    // Select the lifecycle at runtime so all five shards share one binary.
    const history_stress = b.addTest(.{
        .filters = &.{"native history stress:"},
        .root_module = b.createModule(.{ .root_source_file = b.path("src/native_history_stress_tests.zig"), .target = target, .optimize = optimize, .link_libc = target.result.abi == .musl or target.result.os.tag == .macos }),
    });
    history_stress.root_module.addOptions("build_options", options);
    if (macos_sdk) |sdk| linkNativeKeychain(history_stress.root_module, sdk);
    const history_run = guardedTestRun(b, history_stress, test_watchdog);
    history_run.setEnvironmentVariable("OMAGMA_HISTORY_CASE", @tagName(history_case));
    b.step("test-native-history-stress", "Verify retained mail, blob and Calendar histories across restart and replay").dependOn(&history_run.step);

    const prepare_tests = b.step("prepare-tests", "Compile all native test artifacts without running tests or probes");
    for ([_]*std.Build.Step.Compile{ t, extra_tests, memory_tests, browser_export_tests, browser_server_tests, browser_cache_tests, browser_provider_tests, contact_isolation_tests, mailbox_tests, send_stress, history_stress }) |artifact| {
        prepare_tests.dependOn(&artifact.step);
    }

    const prepare_history = b.step("prepare-history", "Compile the shared retained-history test artifact without running tests");
    prepare_history.dependOn(&history_stress.step);

    const probes = b.step("probes", "Compile all standalone transport/auth/budget probes");
    for ([_][]const u8{ "src/auth_probe.zig", "src/transport_probe.zig", "src/terminal_stream_probe.zig", "src/calendar_http_probe.zig", "tests/probes/callback_budget.zig" }) |path| {
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

/// Keep Maker's per-test protocol/timer; bound its TERM-based child cleanup.
/// Public so the tiny test-tooling oracle exercises this exact build wiring.
pub fn guardedTestRun(b: *std.Build, artifact: *std.Build.Step.Compile, enabled: bool) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    // Compile results may be restored from CI caches; test execution must
    // produce fresh evidence even when the binary and inputs are unchanged.
    run.has_side_effects = true;
    if (enabled) {
        switch (run.stdio) {
            .zig_test => {},
            else => @panic("test-watchdog requires native server-mode Zig tests"),
        }
        const original = run.argv.toOwnedSlice(b.allocator) catch @panic("OOM");
        run.addArg("python3");
        run.addFileArg(b.path("tests/zig_test_guard.py"));
        run.addArg("--");
        run.argv.appendSlice(b.allocator, original) catch @panic("OOM");
    }
    return run;
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
