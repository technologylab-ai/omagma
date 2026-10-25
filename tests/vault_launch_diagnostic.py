#!/usr/bin/env python3
"""Disposable, synthetic native readiness diagnosis; never a release gate."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests/results/vault-launch-diagnostic"
TARGET = "vault launch: owned socket permissions become ready before the first status exchange"
BASE = "7399aeef5d0d2905e62d15794e1d5b2edae9cc56"
BASE_SOURCE_SHA256 = "b24980c78e69d6def3f695c17f0617fd154d00a9ee3b9d9c8f370197a1f05165"
LIMIT = 120
REPEATS = 20
CHILD = None
ROWS = []


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def marker(name):
    return 'Phase.log("' + name + '");'


def marked_source(original):
    begin = original.index('test "' + TARGET + '" {')
    end = original.index('\ntest "vault launch: unsafe path kinds', begin)
    test = original[begin:end]
    replacements = [
        ('    const io = std.testing.io;', '''    const Phase = struct {
        fn log(comptime name: []const u8) void {
            std.debug.print("VAULT-LAUNCH-PHASE {s}\\n", .{name});
        }
    };
    Phase.log("test-enter");
    defer Phase.log("test-cleanup-complete");
    const io = std.testing.io;'''),
        ('    defer temporary.cleanup();', '    defer { ' + marker('temporary-cleanup-begin') + ' temporary.cleanup(); ' + marker('temporary-cleanup-end') + ' }'),
        ('    try std.testing.expect(!try check.probe()); // The child\'s socket is not bound yet.', '    ' + marker('missing-probe-begin') + '\n    try std.testing.expect(!try check.probe());\n    ' + marker('missing-probe-end')),
        ('    var listener = try transport.Listener.init(io, path);', '    ' + marker('listener-init-begin') + '\n    var listener = try transport.Listener.init(io, path);\n    ' + marker('listener-init-end')),
        ('    defer listener.deinit();', '    defer { ' + marker('listener-deinit-begin') + ' listener.deinit(); ' + marker('listener-deinit-end') + ' }'),
        ('    try std.testing.expectError(error.UnsafeBackendSocket, check.probe());', '    ' + marker('unsafe-preexisting-probe-begin') + '\n    try std.testing.expectError(error.UnsafeBackendSocket, check.probe());\n    ' + marker('unsafe-preexisting-probe-end')),
        ('    try std.testing.expect(!try check.probe());', '    ' + marker('unsafe-owned-probe-begin') + '\n    try std.testing.expect(!try check.probe());\n    ' + marker('unsafe-owned-probe-end')),
        ('    try std.testing.expectError(error.UnsafeBackendSocket, check.client.request(a, .status, ""));', '    ' + marker('unsafe-direct-request-begin') + '\n    try std.testing.expectError(error.UnsafeBackendSocket, check.client.request(a, .status, ""));\n    ' + marker('unsafe-direct-request-end')),
        ('    try std.testing.expectError(error.Timeout, platform.deadline(io, .{ .clock = .awake, .raw = .fromMilliseconds(75) }, Check.wait, .{&check}));', '    ' + marker('deadline75-begin') + '\n    try std.testing.expectError(error.Timeout, platform.deadline(io, .{ .clock = .awake, .raw = .fromMilliseconds(75) }, Check.wait, .{&check}));\n    ' + marker('deadline75-joined')),
        ('            const peer_io = std.testing.io;', '            ' + marker('peer-function-enter') + '\n            defer ' + marker('peer-function-exit') + '\n            const peer_io = std.testing.io;'),
        ('            const stream = try server.server.accept(peer_io);', '            ' + marker('peer-accept-begin') + '\n            const stream = try server.server.accept(peer_io);\n            ' + marker('peer-accept-end')),
        ('            defer stream.close(peer_io);', '            defer { ' + marker('peer-stream-close-begin') + ' stream.close(peer_io); ' + marker('peer-stream-close-end') + ' }'),
        ('            var frame = try transport.readFrame(peer_io, peer_a, stream, transport.request_limit);', '            ' + marker('peer-read-begin') + '\n            var frame = try transport.readFrame(peer_io, peer_a, stream, transport.request_limit);\n            ' + marker('peer-read-end')),
        ('            try transport.writeFrame(peer_io, stream, .response, response, transport.response_limit);', '            ' + marker('peer-write-begin') + '\n            try transport.writeFrame(peer_io, stream, .response, response, transport.response_limit);\n            ' + marker('peer-write-end')),
        ('    var peer = try io.concurrent(Peer.respond, .{ &listener, expected, &requests });', '    ' + marker('peer-launch-begin') + '\n    var peer = try io.concurrent(Peer.respond, .{ &listener, expected, &requests });\n    ' + marker('peer-launch-end')),
        ('    defer peer.cancel(io) catch {};', '    defer { ' + marker('peer-cancel-begin') + ' peer.cancel(io) catch {}; ' + marker('peer-cancel-end') + ' }'),
        ('    try temporary.dir.setFilePermissions(io, "socket", .fromMode(0o600), .{ .follow_symlinks = false });', '    ' + marker('chmod600-begin') + '\n    try temporary.dir.setFilePermissions(io, "socket", .fromMode(0o600), .{ .follow_symlinks = false });\n    ' + marker('chmod600-end')),
        ('    try platform.deadline(io, platform.seconds(5), Check.wait, .{&check});', '    ' + marker('deadline5-begin') + '\n    try platform.deadline(io, platform.seconds(5), Check.wait, .{&check});\n    ' + marker('deadline5-joined')),
        ('    try peer.await(io);', '    ' + marker('peer-await-begin') + '\n    try peer.await(io);\n    ' + marker('peer-await-end')),
        ('    try std.testing.expectEqual(@as(usize, 1), requests.load(.acquire));', '    try std.testing.expectEqual(@as(usize, 1), requests.load(.acquire));\n    ' + marker('test-body-exit')),
    ]
    # Match original locations, not marker-expanded text from earlier entries.
    for index, (old, _) in enumerate(replacements):
        if test.count(old) != 1:
            raise AssertionError((old, test.count(old)))
        test = test.replace(old, f"__DIAGNOSTIC_{index}__", 1)
    for index, (_, new) in enumerate(replacements):
        test = test.replace(f"__DIAGNOSTIC_{index}__", new)
    return original[:begin] + test + original[end:]


def save():
    (OUT / "receipt.json").write_text(json.dumps(RECEIPT, indent=2) + "\n")


def stop_owned():
    global CHILD
    if CHILD is None:
        return
    if CHILD.poll() is None:
        CHILD.send_signal(signal.SIGTERM)  # Existing guardian owns its test PGID.
        try:
            CHILD.wait(timeout=5)
        except subprocess.TimeoutExpired:
            CHILD.kill()
            CHILD.wait(timeout=5)
    CHILD = None


def owned_processes(guardian_pid):
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True, timeout=5)
    records = [line.strip().split(None, 2) for line in listing.splitlines()]
    descendants = {guardian_pid}
    children = []
    for _ in range(8):
        added = [(int(f[0]), f[2]) for f in records if len(f) == 3 and int(f[1]) in descendants and int(f[0]) not in descendants]
        if not added:
            break
        children.extend(added)
        descendants.update(pid for pid, _ in added)
    return children


def sample_owned(guardian_pid, prefix):
    children = owned_processes(guardian_pid)
    (OUT / (prefix + "-owned-processes.json")).write_text(json.dumps(children, indent=2) + "\n")
    for pid, command in children:
        if Path(command).name not in ("vault-launch-test", "test"):
            continue
        log = OUT / (prefix + "-sample.log")
        with (OUT / (prefix + "-sample-command.log")).open("w") as output:
            try:
                subprocess.run(["/usr/bin/sample", str(pid), "1", "1", "-file", str(log)], stdout=output, stderr=subprocess.STDOUT, timeout=5)
            except subprocess.TimeoutExpired:
                output.write("Owned sample command exceeded 5 seconds\n")


def execute(variant, index, binary):
    global CHILD
    name = f"{variant}-{index:02d}"
    path = OUT / (name + ".log")
    started = time.monotonic()
    timed_out = False
    sampled = False
    with path.open("w") as output:
        CHILD = subprocess.Popen([sys.executable, str(ROOT / "tests/zig_test_guard.py"), "--", str(binary), "--cache-dir=" + str(binary.parent / "standalone-cache")], cwd=binary.parent, stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True, preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
        while CHILD.poll() is None:
            elapsed = time.monotonic() - started
            if elapsed >= LIMIT:
                timed_out = True
                output.write("DIAGNOSTIC outer120s watchdog requests guardian termination\n")
                output.flush()
                stop_owned()
                break
            if elapsed >= 10 and not sampled:
                sampled = True
                sample_owned(CHILD.pid, name)
            time.sleep(0.02)
        code = 124 if timed_out else CHILD.returncode
    stop_owned()
    text = path.read_text()
    identity = next((line.split("DIAGNOSTIC-BUILD ", 1)[1].split("\n", 1)[0] for line in text.splitlines() if "DIAGNOSTIC-BUILD " in line), None)
    passed = code == 0 and TARGET + "..." in text and "All 4 tests passed." in text and identity == "zig=0.17.0 mode=debug arch=aarch64 os=macos"
    row = {"variant": variant, "index": index, "exitCode": code, "passed": passed, "seconds": time.monotonic() - started,
           "watchdogSeconds": LIMIT, "sampled": sampled, "binarySha256": sha(binary), "binaryBuildIdentity": identity,
           "targetTestObserved": TARGET in text, "log": path.name, "logSha256": sha(path)}
    ROWS.append(row)
    save()
    print(json.dumps(row), flush=True)
    return passed



def execute_maker(variant, zig, wrapper, sdk):
    global CHILD
    name = variant + "-maker"
    path = OUT / (name + ".log")
    argv = [zig, "build", "--build-file", "vault_launch_diagnostic_build.zig", "test", "-Dsource=" + str(wrapper),
            "-Doptimize=debug", "-Dtarget=aarch64-macos.13.0", "-Dcpu=baseline", "-Dmacos-sdk=" + sdk,
            "-Dtest-watchdog=true", "--test-timeout", "120s", "-j2", "--summary", "all", "--verbose", "--cache-dir", str(wrapper.parent.parent / "maker-cache")]
    started = time.monotonic()
    wrapper_argv = [sys.executable, str(ROOT / "tests/zig_test_guard.py"), "--", *argv]
    timed_out = False
    try:
        with path.open("w") as output:
            CHILD = subprocess.Popen(wrapper_argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            sampled = False
            test_seen = None
            next_probe = 0.0
            while CHILD.poll() is None:
                elapsed = time.monotonic() - started
                if elapsed >= 420:
                    timed_out = True
                    output.write("DIAGNOSTIC compile/run watchdog requests outer guardian termination\n")
                    output.flush()
                    stop_owned()
                    break
                if elapsed >= next_probe and not sampled:
                    tests = [pid for pid, command in owned_processes(CHILD.pid) if Path(command).name in ("vault-launch-test", "test")]
                    if tests:
                        if test_seen is None or test_seen[0] != tests[0]:
                            test_seen = (tests[0], elapsed)
                        elif elapsed - test_seen[1] >= 10:
                            sampled = True
                            sample_owned(CHILD.pid, name)
                    next_probe = elapsed + 1
                time.sleep(0.05)
            code = 124 if timed_out else CHILD.returncode
    finally:
        stop_owned()
    text = path.read_text()
    passed = code == 0 and "4 pass" in text and "DIAGNOSTIC-BUILD zig=0.17.0 mode=debug arch=aarch64 os=macos" in text
    row = {"variant": variant, "runnerMode": "Maker server plus unchanged production guardian", "argv": argv, "outerGuardianArgv": wrapper_argv,
           "exitCode": code, "passed": passed, "seconds": time.monotonic() - started,
           "makerPerTestTimeoutSeconds": 120, "compileAndRunOuterSeconds": 420,
           "targetPresenceBasis": "same source/filter as standalone named-target assertion; four-test Maker count mandatory",
           "log": path.name, "logSha256": sha(path)}
    RECEIPT.setdefault("makerRuns", []).append(row)
    save()
    print(json.dumps(row), flush=True)
    return passed


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise AssertionError("Native Apple Silicon diagnostic only")
    zig = shutil.which("zig")
    version = subprocess.check_output([zig, "version"], text=True).strip()
    if version != "0.17.0":
        raise AssertionError(version)
    original = (ROOT / "src/terminal/vault_launch.zig").read_text()
    baseline = subprocess.check_output(["git", "show", "HEAD:src/terminal/vault_launch.zig"], cwd=ROOT, text=True)
    if original != baseline or sha(ROOT / "src/terminal/vault_launch.zig") != BASE_SOURCE_SHA256:
        raise AssertionError("Working source differs from diagnostic commit")
    RECEIPT.update({"diagnosticCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(), "baseCommit": BASE,
                    "host": platform.platform(), "compilerVersion": version, "compilerSha256": sha(zig), "sourceSha256": sha(ROOT / "src/terminal/vault_launch.zig"),
                    "target": "aarch64-macos.13.0", "backend": "LLVM", "repetitionsPerVariant": REPEATS, "runs": ROWS, "variants": []})
    save()
    sdk = os.environ["SDKROOT"]
    with tempfile.TemporaryDirectory(prefix="ovld-", dir="/tmp") as raw:
        directory = Path(raw).resolve()
        for variant in ("control", "phases"):
            source = directory / variant
            shutil.copytree(ROOT / "src", source / "src")
            if variant == "phases":
                (source / "src/terminal/vault_launch.zig").write_text(marked_source(original))
            wrapper = source / "src/diagnostic_root.zig"
            wrapper.write_text('''const std = @import("std");
const builtin = @import("builtin");
comptime { _ = @import("vault_activation_tests.zig"); }
test "vault launch: diagnostic build identity" {
    std.debug.print("DIAGNOSTIC-BUILD zig={s} mode={s} arch={s} os={s}\\n", .{builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag)});
}
''')
            options = source / "options.zig"
            options.write_text('pub const version: []const u8 = "0.2.13";\npub const tui = true;\npub const browser = false;\n')
            binary = source / "vault-launch-test"
            argv = [zig, "test", "-fllvm", "-Odebug", "-target", "aarch64-macos.13.0", "-mcpu", "baseline", "-lc", "-lproc",
                    "-F", sdk + "/System/Library/Frameworks", "-L", sdk + "/usr/lib", "-framework", "Security", "-framework", "CoreFoundation",
                    "--dep", "build_options", "-Mroot=" + str(wrapper), "-Mbuild_options=" + str(options), "--test-filter", "vault launch:",
                    "--test-no-exec", "-femit-bin=" + str(binary), "-j2"]
            compile_log = OUT / (variant + "-compile.log")
            started = time.monotonic()
            with compile_log.open("w") as output:
                try:
                    result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT, timeout=300)
                    code = result.returncode
                except subprocess.TimeoutExpired:
                    code = 124
            RECEIPT["variants"].append({"name": variant, "sourceSha256": sha(source / "src/terminal/vault_launch.zig"), "compileArgv": argv, "compileExitCode": code,
                                        "compileSeconds": time.monotonic() - started, "compileLogSha256": sha(compile_log)})
            save()
            if code:
                print(f"{variant}: compilation failed; preserved log", flush=True)
                continue
            execute_maker(variant, zig, wrapper, sdk)
            for index in range(REPEATS):
                if not execute(variant, index, binary):
                    break
    RECEIPT["passed"] = len(ROWS) == REPEATS * 2 and all(row["passed"] for row in ROWS) and len(RECEIPT.get("makerRuns", [])) == 2 and all(row["passed"] for row in RECEIPT["makerRuns"])
    save()
    return 0 if RECEIPT["passed"] else 1


RECEIPT = {}
if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise InterruptedError(signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        raise SystemExit(main())
    finally:
        stop_owned()
