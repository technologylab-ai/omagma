//! Release discovery is independent of Gmail, configuration and account grants.
//! Call check on the application's single network worker, after mail work.
const std = @import("std");
const builtin = @import("builtin");
const b = @import("../bounded.zig");
const http = @import("../http_client.zig");
const files = @import("files.zig");
const j = @import("json.zig");

pub const release_page = "https://github.com/technologylab-ai/omagma/releases/latest";
pub const installation_page = "https://technologylab-ai.github.io/omagma/docs/install/";
pub const repository_page = "https://github.com/technologylab-ai/omagma";
pub const daily_seconds = 86400;
const state_bytes = 16 * 1024;
pub const Method = enum { unknown, source, omarchy_source, omarchy_bundle, homebrew, manual };
pub const InstallInfo = struct {
    method: Method = .unknown,
    os: b.Text(24) = .{},
    arch: b.Text(24) = .{},
    executable: b.Text(4096) = .{},
    pinned: bool = false,
};
pub const State = struct {
    latest: b.Text(64) = .{},
    title: b.Text(160) = .{},
    notes: b.Text(2048) = .{},
    releaseUrl: b.Text(256) = .{},
    dismissed: b.Text(64) = .{},
    brewAvailable: b.Text(64) = .{},
    checkedAt: i64 = 0,
    lastSuccessAt: i64 = 0,
    nextCheckAt: i64 = 0,
    blockedUntil: i64 = 0,
    errorMessage: b.Text(160) = .{},
    manualOnly: bool = false,
};
pub const Snapshot = struct { state: State = .{}, install: InstallInfo = .{}, fixtures: bool = false };
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pub fn parse(input: []const u8) !Version {
        const value = if (std.mem.startsWith(u8, input, "v")) input[1..] else input;
        if (value.len == 0 or value.len > 32) return error.InvalidReleaseVersion;
        var parts = std.mem.splitScalar(u8, value, '.');
        var numbers: [3]u32 = undefined;
        for (&numbers) |*number| {
            const part = parts.next() orelse return error.InvalidReleaseVersion;
            if (part.len == 0 or (part.len > 1 and part[0] == '0')) return error.InvalidReleaseVersion;
            for (part) |char| if (!std.ascii.isDigit(char)) return error.InvalidReleaseVersion;
            number.* = std.fmt.parseInt(u32, part, 10) catch return error.InvalidReleaseVersion;
        }
        if (parts.next() != null) return error.InvalidReleaseVersion;
        return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] };
    }
    pub fn order(self: Version, other: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |field| {
            const result = std.math.order(@field(self, field), @field(other, field));
            if (result != .eq) return result;
        }
        return .eq;
    }
};
pub fn isNewer(candidate: []const u8, current: []const u8) bool {
    const next = Version.parse(candidate) catch return false;
    const running = Version.parse(current) catch return false;
    return next.order(running) == .gt;
}
fn normalized(a: std.mem.Allocator, version: []const u8) ![]const u8 {
    const parsed = try Version.parse(version);
    return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ parsed.major, parsed.minor, parsed.patch });
}
pub fn now(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
pub fn due(state: *const State, timestamp: i64) bool {
    if (state.manualOnly) return false;
    if (timestamp < state.blockedUntil) return false;
    return state.nextCheckAt == 0 or timestamp >= state.nextCheckAt or timestamp < state.checkedAt;
}
pub fn available(snapshot: *const Snapshot, current: []const u8) bool {
    if (!isNewer(snapshot.state.latest.slice(), current)) return false;
    if (snapshot.install.method == .homebrew) {
        if (snapshot.install.pinned) return false;
        const formula = Version.parse(snapshot.state.brewAvailable.slice()) catch return false;
        const release = Version.parse(snapshot.state.latest.slice()) catch return false;
        if (formula.order(release) == .lt) return false;
    }
    return true;
}
pub fn visible(snapshot: *const Snapshot, current: []const u8) bool {
    return available(snapshot, current) and !std.mem.eql(u8, snapshot.state.latest.slice(), snapshot.state.dismissed.slice());
}
pub fn installationUrl(snapshot: *const Snapshot) []const u8 {
    if (std.mem.eql(u8, snapshot.install.os.slice(), "macos")) return "https://technologylab-ai.github.io/omagma/docs/macos/";
    return installation_page;
}

const Wire = struct {
    schema: u8 = 1,
    latest: []const u8 = "",
    title: []const u8 = "",
    notes: []const u8 = "",
    releaseUrl: []const u8 = "",
    dismissed: []const u8 = "",
    brewAvailable: []const u8 = "",
    checkedAt: i64 = 0,
    lastSuccessAt: i64 = 0,
    nextCheckAt: i64 = 0,
    blockedUntil: i64 = 0,
    errorMessage: []const u8 = "",
    manualOnly: bool = false,
};
fn wire(state: *const State) Wire {
    return .{ .latest = state.latest.slice(), .title = state.title.slice(), .notes = state.notes.slice(), .releaseUrl = state.releaseUrl.slice(), .dismissed = state.dismissed.slice(), .brewAvailable = state.brewAvailable.slice(), .checkedAt = state.checkedAt, .lastSuccessAt = state.lastSuccessAt, .nextCheckAt = state.nextCheckAt, .blockedUntil = state.blockedUntil, .errorMessage = state.errorMessage.slice(), .manualOnly = state.manualOnly };
}
pub fn parseState(a: std.mem.Allocator, bytes: []const u8) !State {
    if (bytes.len > state_bytes or !boundedJson(bytes)) return error.InvalidUpdateState;
    const parsed = try std.json.parseFromSlice(Wire, a, bytes, .{ .max_value_len = state_bytes });
    defer parsed.deinit();
    const input = parsed.value;
    if (input.schema != 1 or input.checkedAt < 0 or input.lastSuccessAt < 0 or input.nextCheckAt < 0 or input.blockedUntil < 0) return error.InvalidUpdateState;
    var state: State = .{ .checkedAt = input.checkedAt, .lastSuccessAt = input.lastSuccessAt, .nextCheckAt = input.nextCheckAt, .blockedUntil = input.blockedUntil, .manualOnly = input.manualOnly };
    inline for (.{ "latest", "dismissed", "brewAvailable" }) |name| {
        const value = @field(input, name);
        if (value.len != 0) _ = try Version.parse(value);
        try @field(state, name).set(value);
    }
    inline for (.{ "title", "notes", "errorMessage" }) |name| @field(state, name).display(@field(input, name));
    if (input.releaseUrl.len != 0 and !validReleaseUrl(input.releaseUrl, state.latest.slice())) return error.InvalidUpdateState;
    try state.releaseUrl.set(input.releaseUrl);
    return state;
}
fn statePath(a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const home = environ.get("HOME") orelse return error.HomeRequired;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const directory = environ.get("XDG_STATE_HOME") orelse try std.fmt.allocPrint(arena.allocator(), "{s}/.local/state", .{home});
    if (!std.fs.path.isAbsolute(directory) or directory.len > 4000) return error.InvalidUpdateStatePath;
    return std.fmt.allocPrint(a, "{s}/omagma/updates.json", .{directory});
}
pub fn load(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map) !State {
    const filename = try statePath(a, environ);
    defer a.free(filename);
    const file = files.openRegular(io, a, .cwd(), filename) catch |err| if (err == error.FileNotFound) return .{} else return err;
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureUpdateState;
    if (stat.size > state_bytes) return error.InvalidUpdateState;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .limited(state_bytes));
    defer a.free(bytes);
    return parseState(a, bytes);
}
pub fn save(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, snapshot: *const Snapshot) !void {
    if (snapshot.fixtures) return;
    const filename = try statePath(a, environ);
    defer a.free(filename);
    // Refuse replacing insecure or malformed existing state.
    _ = try load(io, a, environ);
    const parent = std.fs.path.dirname(filename) orelse return error.InvalidUpdateStatePath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    var directory = try std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false });
    defer directory.close(io);
    if ((try directory.stat(io)).permissions.toMode() & 0o077 != 0) return error.InsecureUpdateState;
    const bytes = try std.json.Stringify.valueAlloc(a, wire(&snapshot.state), .{});
    defer a.free(bytes);
    var atomic = try directory.createFileAtomic(io, "updates.json", .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
pub fn dismiss(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, snapshot: *Snapshot) !void {
    const previous = snapshot.state.dismissed;
    errdefer snapshot.state.dismissed = previous;
    try snapshot.state.dismissed.set(snapshot.state.latest.slice());
    try save(io, a, environ, snapshot);
}

fn validReleaseUrl(url: []const u8, version: []const u8) bool {
    const prefix = "https://github.com/technologylab-ai/omagma/releases/tag/";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const tag = url[prefix.len..];
    const expected = Version.parse(version) catch return false;
    const actual = Version.parse(tag) catch return false;
    return actual.order(expected) == .eq;
}
fn boundedJson(raw: []const u8) bool {
    var quote = false;
    var escaped = false;
    var depth: usize = 0;
    var separators: usize = 0;
    for (raw) |char| {
        if (quote) {
            if (escaped) escaped = false else if (char == '\\') escaped = true else if (char == '"') quote = false;
            continue;
        }
        switch (char) {
            '"' => quote = true,
            '{', '[' => {
                depth += 1;
                if (depth > 16) return false;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            ',', ':' => {
                separators += 1;
                if (separators > 4096) return false;
            },
            else => {},
        }
    }
    return depth == 0 and !quote;
}
pub fn applyRelease(a: std.mem.Allocator, state: *State, raw: []const u8) !void {
    if (raw.len > http.metadata_bytes or !boundedJson(raw)) return error.InvalidReleaseMetadata;
    const parsed = try std.json.parseFromSlice(j.Value, a, raw, .{ .max_value_len = http.metadata_bytes });
    defer parsed.deinit();
    const release = parsed.value;
    if (release != .object or try j.boolean(release, "draft", true) or try j.boolean(release, "prerelease", true)) return error.InvalidReleaseMetadata;
    const version = try normalized(a, try j.required(release, "tag_name"));
    defer a.free(version);
    const url = try j.required(release, "html_url");
    if (!validReleaseUrl(url, version)) return error.InvalidReleaseMetadata;
    var fresh = state.*;
    try fresh.latest.set(version);
    try fresh.releaseUrl.set(url);
    fresh.title.display(j.text(release, "name"));
    fresh.notes.display(j.text(release, "body"));
    state.* = fresh;
}
pub fn formulaVersion(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len > http.metadata_bytes or std.mem.indexOf(u8, raw, "class Omagma < Formula") == null) return error.InvalidFormulaMetadata;
    const prefix = "https://github.com/technologylab-ai/omagma/releases/download/v";
    const start = std.mem.indexOf(u8, raw, prefix) orelse return error.InvalidFormulaMetadata;
    const tail = raw[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, tail, '/') orelse return error.InvalidFormulaMetadata;
    return normalized(a, tail[0..end]);
}

pub const DetectionEvidence = struct { brewOwned: bool = false, pinned: bool = false, pluginBackendMatch: bool = false, pluginGit: bool = false, pluginBundle: bool = false, sourceCheckout: bool = false, bundle: bool = false };
pub fn classify(evidence: DetectionEvidence) Method {
    if (evidence.brewOwned) return .homebrew;
    if (evidence.pluginBackendMatch) {
        if (evidence.pluginGit) return .omarchy_source;
        if (evidence.pluginBundle) return .omarchy_bundle;
    }
    if (evidence.sourceCheckout) return .source;
    if (evidence.bundle) return .manual;
    return .unknown;
}
fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
fn receiptOwned(a: std.mem.Allocator, raw: []const u8) bool {
    if (raw.len > state_bytes or !boundedJson(raw)) return false;
    const parsed = std.json.parseFromSlice(j.Value, a, raw, .{ .max_value_len = state_bytes }) catch return false;
    defer parsed.deinit();
    const source = j.get(parsed.value, "source") orelse return false;
    return std.mem.eql(u8, j.text(source, "tap"), "renerocksai/tap");
}
pub fn detect(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map) !InstallInfo {
    var info: InstallInfo = .{};
    try info.os.set(@tagName(builtin.os.tag));
    try info.arch.set(@tagName(builtin.cpu.arch));
    var executable_buffer: [4096]u8 = undefined;
    const executable_count = std.process.executablePath(io, &executable_buffer) catch return info;
    const executable = executable_buffer[0..executable_count];
    try info.executable.set(executable);
    const bin_dir = std.fs.path.dirname(executable) orelse return info;
    const package_dir = std.fs.path.dirname(bin_dir) orelse return info;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    var evidence: DetectionEvidence = .{};
    if (std.mem.indexOf(u8, executable, "/Cellar/omagma/")) |cellar| {
        const receipt_path = try std.fmt.allocPrint(temporary, "{s}/INSTALL_RECEIPT.json", .{package_dir});
        const receipt = files.readBounded(io, temporary, .cwd(), receipt_path, state_bytes) catch "";
        evidence.brewOwned = receiptOwned(temporary, receipt);
        const pinned_path = try std.fmt.allocPrint(temporary, "{s}/var/homebrew/pinned/omagma", .{executable[0..cellar]});
        evidence.pinned = exists(io, pinned_path);
    }
    const source_root = if (std.mem.endsWith(u8, package_dir, "/zig-out")) std.fs.path.dirname(package_dir) else null;
    if (source_root) |root| {
        const zon_path = try std.fmt.allocPrint(temporary, "{s}/build.zig.zon", .{root});
        evidence.sourceCheckout = exists(io, zon_path) and exists(io, try std.fmt.allocPrint(temporary, "{s}/.git", .{root}));
        evidence.bundle = exists(io, try std.fmt.allocPrint(temporary, "{s}/manifest.json", .{root}));
    }
    if (environ.get("HOME")) |home| {
        const config_dir = environ.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(temporary, "{s}/.config", .{home});
        const plugin = try std.fmt.allocPrint(temporary, "{s}/omarchy/plugins/io.github.technologylab_ai.omagma", .{config_dir});
        const backend = try std.fmt.allocPrint(temporary, "{s}/zig-out/bin/omagma", .{plugin});
        var real_buffer: [4096]u8 = undefined;
        if (std.Io.Dir.cwd().realPathFile(io, backend, &real_buffer)) |size| {
            evidence.pluginBackendMatch = std.mem.eql(u8, real_buffer[0..size], executable);
            evidence.pluginGit = exists(io, try std.fmt.allocPrint(temporary, "{s}/.git", .{plugin}));
            evidence.pluginBundle = exists(io, try std.fmt.allocPrint(temporary, "{s}/manifest.json", .{plugin}));
        } else |_| {}
    }
    info.method = classify(evidence);
    info.pinned = evidence.pinned;
    return info;
}
pub fn init(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, fixtures: bool) !Snapshot {
    if (fixtures) return fixture(io);
    var result: Snapshot = .{ .install = try detect(io, a, environ) };
    result.state = load(io, a, environ) catch |err| blk: {
        if (err == error.Canceled) return err;
        var state: State = .{};
        state.errorMessage.display("Saved update status could not be read");
        state.manualOnly = true;
        break :blk state;
    };
    return result;
}
pub fn fixture(io: std.Io) Snapshot {
    var result: Snapshot = .{ .fixtures = true };
    result.install.method = .omarchy_source;
    result.install.os.set("linux") catch unreachable;
    result.install.arch.set("x86_64") catch unreachable;
    result.state.latest.set("0.2.8") catch unreachable;
    result.state.title.set("A little more lava") catch unreachable;
    result.state.notes.set("New features and quality-of-life improvements. Update when convenient.") catch unreachable;
    result.state.releaseUrl.set("https://github.com/technologylab-ai/omagma/releases/tag/v0.2.8") catch unreachable;
    result.state.checkedAt = now(io);
    result.state.lastSuccessAt = result.state.checkedAt;
    result.state.nextCheckAt = result.state.checkedAt + daily_seconds;
    return result;
}
pub fn check(io: std.Io, a: std.mem.Allocator, environ: *const std.process.Environ.Map, snapshot: *Snapshot) !void {
    if (snapshot.fixtures) {
        snapshot.state.checkedAt = now(io);
        snapshot.state.nextCheckAt = snapshot.state.checkedAt + daily_seconds;
        return;
    }
    if (now(io) < snapshot.state.blockedUntil) {
        snapshot.state.errorMessage.display("GitHub asked us to wait; cached update status is shown");
        return;
    }
    snapshot.state.checkedAt = now(io);
    snapshot.state.nextCheckAt = snapshot.state.checkedAt + daily_seconds;
    if (load(io, a, environ)) |persisted| mergePreferences(&snapshot.state, &persisted) else |err| {
        if (err == error.Canceled) return err;
    }
    // Persist the attempt before awaiting the network so cancellation/closing
    // the TUI does not turn repeated launches into repeated HTTP requests.
    save(io, a, environ, snapshot) catch |err| {
        if (err == error.Canceled) return err;
    };
    var client = http.Client.init(io) catch |err| {
        if (err == error.Canceled) return err;
        snapshot.state.errorMessage.display("Update check is temporarily unavailable");
        save(io, a, environ, snapshot) catch {};
        return;
    };
    defer client.deinit();
    var buffer: [http.metadata_bytes]u8 = undefined;
    checkNetwork(a, &client, &buffer, snapshot) catch |err| {
        if (err == error.Canceled) return err;
        snapshot.state.errorMessage.display(switch (err) {
            error.RateLimited => "GitHub is rate limiting update checks; try again later",
            error.ReleaseNotFound => "No stable release was found",
            error.InvalidReleaseMetadata => "Release information could not be verified",
            error.Timeout => "Update check timed out; mail remains available",
            else => "Could not check for updates; try again later",
        });
    };
    // Another terminal/CLI may dismiss a release or change automatic checking
    // while this worker awaits the network. Release checks do not own either
    // preference, so preserve the latest saved values before replacing cache.
    if (load(io, a, environ)) |persisted| mergePreferences(&snapshot.state, &persisted) else |err| {
        if (err == error.Canceled) return err;
    }
    save(io, a, environ, snapshot) catch |err| {
        if (err == error.Canceled) return err;
        snapshot.state.errorMessage.display("Update status is available, but could not be saved");
    };
}
pub fn mergePreferences(state: *State, persisted: *const State) void {
    state.dismissed = persisted.dismissed;
    state.manualOnly = persisted.manualOnly;
}
fn checkNetwork(a: std.mem.Allocator, client: *http.Client, buffer: []u8, snapshot: *Snapshot) !void {
    const response = try client.requestPublicMetadata(.latest_release, buffer);
    try applyResponse(a, &snapshot.state, response);
    if (snapshot.install.method == .homebrew) {
        // A previously cached formula cannot establish availability today.
        snapshot.state.brewAvailable.len = 0;
        const formula = try client.requestPublicMetadata(.homebrew_formula, buffer);
        if (formula.status != 200) return error.FormulaRequestFailed;
        const version = try formulaVersion(a, formula.body);
        defer a.free(version);
        try snapshot.state.brewAvailable.set(version);
    }
}
pub fn applyResponse(a: std.mem.Allocator, state: *State, response: http.Response) !void {
    if (response.status == 403 or response.status == 429) {
        state.blockedUntil = state.checkedAt + @max(response.retry_after, 3600);
        state.nextCheckAt = @max(state.nextCheckAt, state.checkedAt + response.retry_after);
        return error.RateLimited;
    }
    if (response.status == 404) return error.ReleaseNotFound;
    if (response.status != 200) return error.UpdateRequestFailed;
    try applyRelease(a, state, response.body);
    state.lastSuccessAt = state.checkedAt;
    state.blockedUntil = 0;
    state.errorMessage.len = 0;
}

pub fn methodName(method: Method) []const u8 {
    return switch (method) {
        .unknown => "Unknown or other package manager",
        .source => "Source checkout",
        .omarchy_source => "Omarchy plugin (Git source checkout)",
        .omarchy_bundle => "Omarchy release bundle",
        .homebrew => "Homebrew (renerocksai/tap/omagma)",
        .manual => "Manual release bundle",
    };
}
pub fn commands(a: std.mem.Allocator, snapshot: *const Snapshot) ![]const u8 {
    return a.dupe(u8, switch (snapshot.install.method) {
        .omarchy_source => "omarchy plugin update io.github.technologylab_ai.omagma\n# This updates source only. Rebuild the backend with the declared Zig pin.\n# After verifying the matching backend:\nomarchy-shell shell rescanPlugins\nomagma --version",
        .homebrew => if (snapshot.install.pinned) "# This Homebrew installation is pinned. Decide whether to unpin it first.\n# After explicitly unpinning when desired:\nbrew update\nbrew upgrade renerocksai/tap/omagma\nomagma --version" else "brew update\nbrew upgrade renerocksai/tap/omagma\nomagma --version",
        .omarchy_bundle => "# Prepare and verify a complete matching release bundle.\n# Switch your existing plugin activation symlink after verification.\nomarchy-shell shell rescanPlugins\nomagma --version",
        .source => "# Preserve your working checkout. Review the release and local changes.\n# Build with the exact Zig version declared in build.zig.zon.\n# Verify the new executable before replacing your owned command link.\nomagma --version",
        .manual, .unknown => "# Download the matching host OS/CPU release and SHA256SUMS.\n# Verify, stage and probe the new binary before switching your owned link.\nomagma --version",
    });
}
pub fn guide(a: std.mem.Allocator, snapshot: *const Snapshot) ![]const u8 {
    const steps = switch (snapshot.install.method) {
        .omarchy_source => "1. Save your work and close the TUI.\n2. Run the Omarchy plugin update command below. It updates the Git checkout only.\n3. Rebuild with the exact Zig pin in build.zig.zon; preserve local changes. Verify the new backend version.\n4. Rescan plugins so the bar and backend use the same version, then reopen.\nA source update alone does not replace or build the backend.",
        .omarchy_bundle => "1. Save your work and close the TUI.\n2. Download the complete matching Linux bundle and its SHA256SUMS from the same release. Verify its checksum.\n3. Extract into a fresh versioned folder; verify its manifest and included executable with --version.\n4. Switch the existing owned plugin symlink, rescan plugins, then reopen. Keep the previous bundle for rollback.\nThe Omarchy plugin update command is for Git checkouts; it cannot upgrade this release bundle.",
        .homebrew => "1. Save your work and close the TUI.\n2. Run brew update, then brew upgrade renerocksai/tap/omagma.\n3. Verify omagma --version and reopen.\nA release can reach GitHub before the Homebrew formula. Wait for the tap when its package is pending.\nPinned installations remain pinned until you explicitly unpin them.",
        .source => "1. Save your work and close the TUI.\n2. Review the release and your checkout's local changes. Preserve your working checkout.\n3. Build using the exact Zig version declared by that checkout's build.zig.zon.\n4. Verify the new executable, switch your owned command link and reopen.\nNo automatic pull, build or file replacement is performed.",
        .manual => "1. Save your work and close the TUI.\n2. Download the matching host OS/CPU release and SHA256SUMS from the same release. Verify the checksum.\n3. Stage in a new versioned folder and verify the new executable with --version.\n4. Switch your owned executable link and reopen. Keep the previous version for rollback.",
        .unknown => "The running executable's package owner could not be established. Do not replace files owned by another package manager.\nFor a manual installation: close the TUI, download the matching host OS/CPU bundle and SHA256SUMS, verify and stage it, probe --version, then switch your owned command link.\nFor a managed installation, use that manager's upgrade procedure. Ask an agent to inspect ownership first.",
    };
    const command_text = try commands(a, snapshot);
    defer a.free(command_text);
    return std.fmt.allocPrint(a, "Installation: {s}\nHost: {s} / {s}\n\n{s}\n\n{s}\n\nYour accounts, OAuth grants, keyring credentials, cached mail and local drafts stay in place. No new Gmail permission is needed for update checks.\nQueued sends remain paused after restarting. Protected send outcomes stay protected.\nUpdate the host running Omagma, including a remote host.\n\nRelease notes: {s}\nInstallation guide: {s}", .{ methodName(snapshot.install.method), snapshot.install.os.slice(), snapshot.install.arch.slice(), steps, command_text, release_page, installationUrl(snapshot) });
}
pub fn agentRequest(a: std.mem.Allocator, snapshot: *const Snapshot) ![]const u8 {
    return std.fmt.allocPrint(a, "Read {s} and its public installation instructions. Help me upgrade the Omagma installation on this host ({s}/{s}; detected: {s}; running {s}; latest stable {s}). Inspect ownership first. Save work and close Omagma before changing files. Preserve configuration, credentials, mail cache, drafts and local source changes. Use the verified matching release or the owning package manager, check --version, and reopen. No cloning prerequisite.", .{ repository_page, snapshot.install.os.slice(), snapshot.install.arch.slice(), methodName(snapshot.install.method), @import("build_options").version, snapshot.state.latest.slice() });
}
pub fn encode(a: std.mem.Allocator, snapshot: *const Snapshot) ![]const u8 {
    const command_text = try commands(a, snapshot);
    defer a.free(command_text);
    const guide_text = try guide(a, snapshot);
    defer a.free(guide_text);
    return std.json.Stringify.valueAlloc(a, .{
        .ok = true,
        .running = @import("build_options").version,
        .available = available(snapshot, @import("build_options").version),
        .noticeVisible = visible(snapshot, @import("build_options").version),
        .homebrewPending = snapshot.install.method == .homebrew and isNewer(snapshot.state.latest.slice(), @import("build_options").version) and !available(snapshot, @import("build_options").version) and !snapshot.install.pinned,
        .installation = .{ .method = @tagName(snapshot.install.method), .os = snapshot.install.os.slice(), .arch = snapshot.install.arch.slice(), .executable = snapshot.install.executable.slice(), .pinned = snapshot.install.pinned },
        .state = wire(&snapshot.state),
        .commands = command_text,
        .guide = guide_text,
        .releaseNotes = if (snapshot.state.releaseUrl.len != 0) snapshot.state.releaseUrl.slice() else release_page,
        .installationGuide = installationUrl(snapshot),
    }, .{});
}

test "updates: semantic versions reject pre-releases, malformed versions and downgrades" {
    try std.testing.expect(isNewer("v0.2.10", "0.2.9"));
    try std.testing.expect(!isNewer("0.2.6", "0.2.7"));
    try std.testing.expect(!isNewer("v0.2.7", "0.2.7"));
    for ([_][]const u8{ "0.3", "0.3.0-beta", "0.3.0+build", "00.3.0", "0.3.-1", "0.3.0/evil" }) |version| try std.testing.expectError(error.InvalidReleaseVersion, Version.parse(version));
}
test "updates: release metadata requires a stable release and official matching URL" {
    const a = std.testing.allocator;
    var state: State = .{};
    try applyRelease(a, &state, "{\"tag_name\":\"v0.2.8\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://github.com/technologylab-ai/omagma/releases/tag/v0.2.8\",\"name\":\"More lava\",\"body\":\"Hello\\u001b[31m\"}");
    try std.testing.expectEqualStrings("0.2.8", state.latest.slice());
    try std.testing.expect(std.mem.indexOfScalar(u8, state.notes.slice(), 27) == null);
    for ([_][]const u8{
        "{\"tag_name\":\"v0.2.8\",\"draft\":true,\"prerelease\":false,\"html_url\":\"https://github.com/technologylab-ai/omagma/releases/tag/v0.2.8\"}",
        "{\"tag_name\":\"v0.2.8\",\"draft\":false,\"prerelease\":true,\"html_url\":\"https://github.com/technologylab-ai/omagma/releases/tag/v0.2.8\"}",
        "{\"tag_name\":\"v0.2.8\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://example.test/v0.2.8\"}",
        "{\"tag_name\":\"v0.2.8\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://github.com/technologylab-ai/omagma/releases/tag/v0.2.9\"}",
    }) |raw| try std.testing.expectError(error.InvalidReleaseMetadata, applyRelease(a, &state, raw));
    try std.testing.expectEqualStrings("0.2.8", state.latest.slice());
}
test "updates: exact dismissal roundtrip, daily checks and Homebrew availability" {
    const a = std.testing.allocator;
    var snapshot: Snapshot = .{};
    try snapshot.state.latest.set("0.2.8");
    try std.testing.expect(visible(&snapshot, "0.2.7"));
    try snapshot.state.dismissed.set("0.2.8");
    const raw = try std.json.Stringify.valueAlloc(a, wire(&snapshot.state), .{});
    defer a.free(raw);
    snapshot.state = try parseState(a, raw);
    try std.testing.expect(!visible(&snapshot, "0.2.7"));
    try snapshot.state.latest.set("0.2.9");
    try std.testing.expect(visible(&snapshot, "0.2.7"));
    snapshot.install.method = .homebrew;
    try snapshot.state.brewAvailable.set("0.2.8");
    try std.testing.expect(!available(&snapshot, "0.2.7"));
    try snapshot.state.brewAvailable.set("0.2.9");
    try std.testing.expect(available(&snapshot, "0.2.7"));
    snapshot.install.pinned = true;
    try std.testing.expect(!available(&snapshot, "0.2.7"));
    snapshot.state.checkedAt = 100;
    snapshot.state.nextCheckAt = 200;
    try std.testing.expect(!due(&snapshot.state, 150));
    try std.testing.expect(due(&snapshot.state, 200));
    snapshot.state.manualOnly = true;
    try std.testing.expect(!due(&snapshot.state, 300));
}
test "updates: actual ownership outranks a manager merely being installed" {
    try std.testing.expectEqual(Method.unknown, classify(.{}));
    try std.testing.expectEqual(Method.source, classify(.{ .sourceCheckout = true, .pluginGit = true }));
    try std.testing.expectEqual(Method.omarchy_source, classify(.{ .sourceCheckout = true, .pluginBackendMatch = true, .pluginGit = true, .pluginBundle = true }));
    try std.testing.expectEqual(Method.omarchy_bundle, classify(.{ .pluginBackendMatch = true, .pluginBundle = true }));
    try std.testing.expectEqual(Method.homebrew, classify(.{ .brewOwned = true, .sourceCheckout = true }));
    const a = std.testing.allocator;
    try std.testing.expect(receiptOwned(a, "{\"source\":{\"tap\":\"renerocksai/tap\"}}"));
    try std.testing.expect(!receiptOwned(a, "{\"source\":{\"tap\":\"other/tap\"}}"));
    const version = try formulaVersion(a, "class Omagma < Formula\nurl \"https://github.com/technologylab-ai/omagma/releases/download/v0.2.8/omagma-macos.tar.gz\"");
    defer a.free(version);
    try std.testing.expectEqualStrings("0.2.8", version);
}
test "updates: private cache survives restarts and refuses insecure replacement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const absolute = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(absolute);
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", absolute);
    try environ.put("XDG_STATE_HOME", absolute);
    var snapshot: Snapshot = .{};
    try snapshot.state.latest.set("0.2.8");
    snapshot.state.checkedAt = 100;
    snapshot.state.nextCheckAt = 100 + daily_seconds;
    try save(io, a, &environ, &snapshot);
    try dismiss(io, a, &environ, &snapshot);
    const restored = try load(io, a, &environ);
    try std.testing.expectEqualStrings("0.2.8", restored.dismissed.slice());
    try std.testing.expect(!due(&restored, 200));
    const file = try temporary.dir.openFile(io, "omagma/updates.json", .{ .mode = .read_write });
    defer file.close(io);
    try std.testing.expectEqual(@as(u32, 0), (try file.stat(io)).permissions.toMode() & 0o077);
    try file.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.InsecureUpdateState, save(io, a, &environ, &snapshot));
    try snapshot.state.latest.set("0.2.9");
    try std.testing.expectError(error.InsecureUpdateState, dismiss(io, a, &environ, &snapshot));
    try std.testing.expectEqualStrings("0.2.8", snapshot.state.dismissed.slice());
    var synthetic = fixture(io);
    try check(io, a, &environ, &synthetic);
    try dismiss(io, a, &environ, &synthetic); // Never touches that insecure real cache.
}
test "updates: preference merge retains external dismissal and automatic-check choice" {
    var checked: State = .{};
    var saved: State = .{ .manualOnly = true };
    try checked.latest.set("0.2.9");
    try saved.dismissed.set("0.2.9");
    mergePreferences(&checked, &saved);
    try std.testing.expectEqualStrings("0.2.9", checked.latest.slice());
    try std.testing.expectEqualStrings("0.2.9", checked.dismissed.slice());
    try std.testing.expect(checked.manualOnly);
}
test "updates: guides preserve ownership and expose relevant instructions" {
    const a = std.testing.allocator;
    var snapshot: Snapshot = .{};
    for ([_]Method{ .omarchy_source, .omarchy_bundle, .homebrew, .source, .manual, .unknown }) |method| {
        snapshot.install.method = method;
        const text = try guide(a, &snapshot);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "close") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "credentials") != null);
        if (method == .omarchy_source) {
            try std.testing.expect(std.mem.indexOf(u8, text, "omarchy plugin update io.github.technologylab_ai.omagma") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "source only") != null);
        }
        if (method == .omarchy_bundle) try std.testing.expect(std.mem.indexOf(u8, text, "cannot upgrade this release bundle") != null);
        if (method == .homebrew) try std.testing.expect(std.mem.indexOf(u8, text, "brew upgrade renerocksai/tap/omagma") != null);
    }
    try snapshot.install.os.set("macos");
    try std.testing.expect(std.mem.endsWith(u8, installationUrl(&snapshot), "/macos/"));
}
test "updates: rate limits preserve metadata and wait for server retry delay" {
    const a = std.testing.allocator;
    var state: State = .{ .checkedAt = 100, .nextCheckAt = 100 + daily_seconds };
    try state.latest.set("0.2.8");
    try std.testing.expectError(error.RateLimited, applyResponse(a, &state, .{ .status = 429, .body = "throttled", .retry_after = 2 * daily_seconds }));
    try std.testing.expectEqualStrings("0.2.8", state.latest.slice());
    try std.testing.expectEqual(@as(i64, 100 + 2 * daily_seconds), state.blockedUntil);
    try std.testing.expect(!due(&state, 100 + daily_seconds));
    try std.testing.expect(due(&state, 100 + 2 * daily_seconds));
    try std.testing.expectError(error.UpdateRequestFailed, applyResponse(a, &state, .{ .status = 500, .body = "offline" }));
    try std.testing.expectEqualStrings("0.2.8", state.latest.slice());
}
