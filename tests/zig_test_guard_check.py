#!/usr/bin/env python3
"""Owned-process supervisor oracles; --zig also checks the actual Maker protocol."""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import zig_test_guard as guard

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "tests/zig_test_guard.py"


class GuardTests(unittest.TestCase):
    def launch(self, code, *args, **kwargs):
        child = subprocess.Popen([sys.executable, str(GUARD), "--", sys.executable,
                                  "-c", code, *args], start_new_session=True, **kwargs)
        self.addCleanup(self.cleanup, child)
        return child

    @staticmethod
    def cleanup(child):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream is not None:
                stream.close()

    def test_exact_stdio_argv_exit_code_and_progress_descriptor(self):
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, read_fd)
        self.addCleanup(os.close, write_fd)
        env = dict(os.environ, ZIG_PROGRESS=str(write_fd))
        code = ("import os,sys,json; os.write(int(os.environ['ZIG_PROGRESS']),b'progress'); "
                "os.write(2,json.dumps(sys.argv[1:]).encode()); "
                "os.write(1,sys.stdin.buffer.read()); sys.exit(23)")
        args = ["--seed=0x123", "--cache-dir=path with spaces", "--listen=-"]
        child = self.launch(code, *args, env=env, pass_fds=(write_fd,),
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        payload = b"\x05\0\0\0\x04\0\0\0\xff\0\x80\x01"
        out, err = child.communicate(payload, timeout=5)
        self.assertEqual((child.returncode, out, json.loads(err)), (23, payload, args))
        self.assertEqual(os.read(read_fd, 8), b"progress")

    def test_natural_signal_is_not_converted_to_an_exit_code(self):
        child = self.launch("import os,signal; os.kill(os.getpid(),signal.SIGTERM)")
        self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)

    def test_default_term_child_is_reaped_without_a_traceback(self):
        code = ("import os,signal,sys; signal.signal(signal.SIGTERM,signal.SIG_DFL); "
                "os.write(1,b'ready\\n'); sys.stdin.buffer.read()")
        child = self.launch(code, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=0)
        self.assertTrue(select.select([child.stdout], [], [], 5)[0])
        self.assertEqual(os.read(child.stdout.fileno(), 4096), b"ready\n")
        child.terminate()
        self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)
        for stream in (child.stdout, child.stderr):
            self.assertTrue(select.select([stream], [], [], 2)[0])
            self.assertEqual(os.read(stream.fileno(), 4096), b"")

    def term_with_descendant(self, default_term):
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                    start_new_session=True)
        self.addCleanup(self.cleanup, sentinel)
        descendant = ("import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                      "os.write(1,b'descendant ready\\n'); signal.pause()")
        handler = "signal.SIG_DFL" if default_term else "lambda *_:None"
        code = ("import os,signal,subprocess,sys; "
                f"signal.signal(signal.SIGTERM,{handler}); "
                "subprocess.Popen([sys.executable,'-c',sys.argv[1]]); "
                "os.write(1,b'parent ready\\n'); "
                # Model the test runner returning to its open protocol stdin.
                "sys.stdin.buffer.read()")
        child = self.launch(code, descendant, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=0)
        ready = b""
        deadline = time.monotonic() + 5
        while ready.count(b"\n") < 2:
            self.assertLess(time.monotonic(), deadline, "synthetic child readiness")
            if select.select([child.stdout], [], [], .1)[0]:
                chunk = os.read(child.stdout.fileno(), 4096)
                self.assertTrue(chunk)
                ready += chunk
        self.assertEqual(set(ready.splitlines()), {b"parent ready", b"descendant ready"})
        child.terminate()
        self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)
        # Both child and descendant held this pipe; EOF proves both released it.
        self.assertTrue(select.select([child.stdout], [], [], 2)[0])
        self.assertEqual(os.read(child.stdout.fileno(), 4096), b"")
        self.assertIsNone(sentinel.poll())

    def test_term_cleans_owned_ignoring_descendant_and_keeps_unrelated_process(self):
        self.term_with_descendant(default_term=False)

    def test_default_term_leader_still_kills_its_ignoring_descendant(self):
        self.term_with_descendant(default_term=True)

    def test_permission_error_for_exited_leader_reaps_before_returning(self):
        class Child:
            pid = 23456
            returncode = None
            def wait(self, timeout):
                self.returncode = -signal.SIGTERM
                self.timeout = timeout
                return self.returncode
        child = Child()
        with patch.object(guard.os, "killpg", side_effect=[None, PermissionError()]) as killpg, \
                patch.object(guard.time, "sleep"):
            guard.terminate_owned(child)
        self.assertEqual(child.timeout, 0)
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertEqual(killpg.call_args_list,
                         [unittest.mock.call(child.pid, signal.SIGTERM),
                          unittest.mock.call(child.pid, signal.SIGKILL)])

    def test_permission_error_for_live_child_is_not_suppressed(self):
        refusal = PermissionError("synthetic live-child permission refusal")
        class Child:
            pid = 23456
            returncode = None
            def wait(self, timeout):
                self.timeout = timeout
                raise subprocess.TimeoutExpired("synthetic-test", timeout)
        child = Child()
        with patch.object(guard.os, "killpg", side_effect=refusal) as killpg:
            with self.assertRaises(PermissionError) as caught:
                guard.terminate_owned(child)
        self.assertIs(caught.exception, refusal)
        self.assertEqual(child.timeout, 0)
        self.assertIsNone(child.returncode)
        killpg.assert_called_once_with(child.pid, signal.SIGTERM)

    def lifecycle(self, signal_during):
        handlers = {}
        calls = []

        def install(sig, handler):
            old = handlers.get(sig, signal.SIG_DFL)
            handlers[sig] = handler
            return old

        class Child:
            pid = 23456
            returncode = None
            def wait(self, timeout=None):
                if timeout is not None:
                    self.returncode = 7
                    handlers[signal.SIGTERM](signal.SIGTERM, None)
                else:
                    self.returncode = -signal.SIGKILL
                calls.append(("wait", timeout))
                return self.returncode

        child = Child()

        def spawn(*_args, **_kwargs):
            if signal_during == "spawn":
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            return child

        def killpg(pid, sig):
            self.assertIsNone(child.returncode, "must not signal a reaped PGID")
            calls.append((pid, sig))

        with patch.dict(os.environ, {}, clear=True), patch.object(guard.signal, "signal", install), \
                patch.object(guard.subprocess, "Popen", spawn), \
                patch.object(guard.os, "killpg", killpg), patch.object(guard.time, "sleep"):
            status = guard.supervise(["synthetic-test"])
        return status, calls

    def test_signal_during_spawn_is_handled_after_ownership_is_established(self):
        status, calls = self.lifecycle("spawn")
        self.assertEqual(status, -signal.SIGTERM)
        self.assertEqual(calls, [(23456, signal.SIGTERM), (23456, signal.SIGKILL), ("wait", None)])

    def test_simultaneous_signal_and_reaped_exit_never_signals_old_pgid(self):
        status, calls = self.lifecycle("wait")
        self.assertEqual(status, 7)
        self.assertEqual(calls, [("wait", .1)])

    def test_release_preserves_all_safe_unit_timeouts_and_opts_in(self):
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        commands = [line for line in gate.splitlines()
                    if "--test-timeout" in line and "test-native-send-stress" not in line
                    and "test-native-history-stress" not in line]
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertIn("--test-timeout 120s", command)
            self.assertIn("-Dtest-watchdog=true", command)
            self.assertIn("-Doptimize=safe", command)
        self.assertEqual(sum('zig build "$task_step" ' in command for command in commands), 1)
        self.assertEqual(sum("zig build test-browser-export " in command for command in commands), 1)
        for group, target in (("main", "test-main"), ("extra", "test-extra"), ("memory", "test-native-memory")):
            self.assertIn(f"unit-{group}) task_step={target} ;;", gate)

    def test_release_runs_growing_stress_separately_on_all_native_platforms(self):
        release = (ROOT / ".github/workflows/release.yml").read_text().split("\n  gates:", 1)[1]
        self.assertIn("platform: [linux-x86_64, linux-arm64, macos-arm64, macos-x86_64]", release)
        self.assertIn(", send,", release)
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        commands = [line for line in gate.splitlines() if "zig build test-native-send-stress " in line]
        self.assertEqual(len(commands), 1)
        self.assertIn("--test-timeout 300s", commands[0])
        self.assertIn("-Dtarget=", commands[0])
        self.assertIn("-Doptimize=safe", commands[0])
        self.assertIn("-Dtest-watchdog=true", commands[0])


    def test_retained_history_stress_is_mandatory_on_all_safe_native_platforms(self):
        release = (ROOT / ".github/workflows/release.yml").read_text().split("\n  gates:", 1)[1]
        self.assertIn("platform: [linux-x86_64, linux-arm64, macos-arm64, macos-x86_64]", release)
        for case in ("calendar", "sends-plain", "sends-vault", "files-plain", "files-vault"):
            self.assertIn("history-" + case, release)
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        stress = [line for line in gate.splitlines() if "zig build test-native-history-stress " in line]
        self.assertEqual(len(stress), 1)
        self.assertIn("-Dhistory-case=", stress[0])
        self.assertIn("--test-timeout 1200s", stress[0])
        self.assertIn("-Dtarget=", stress[0])
        self.assertIn("-Doptimize=safe", stress[0])
        self.assertIn("-Dtest-watchdog=true", stress[0])
        self.assertNotIn("continue-on-error", gate)
        native = (ROOT / ".github/workflows/macos-native.yml").read_text()
        for job in native.split("  native:", 1):
            self.assertNotIn("for mode in debug", job)
            commands = [line for line in job.splitlines() if "zig build test-native-history-stress " in line]
            self.assertEqual(len(commands), 1)
            self.assertTrue('-Doptimize="$mode"' in commands[0] or "-Doptimize=safe" in commands[0])
            self.assertIn("--test-timeout 1200s", commands[0])
            self.assertIn("-Dtest-watchdog=true", commands[0])
            ordinary = [line for line in job.splitlines() if "zig build test " in line]
            self.assertEqual(len(ordinary), 1)
            self.assertIn("--test-timeout 120s", ordinary[0])
            self.assertIn("-Doptimize=safe", ordinary[0])
            self.assertLess(job.index("python3 tests/terminal_workflow_regressions.py"),
                            job.index("zig build test "))

    def test_history_stress_runs_only_the_five_extracted_lifecycles(self):
        wrapper = (ROOT / "src/native_history_stress_tests.zig").read_text()
        self.assertEqual(wrapper.count('test "native history stress:'), 5)
        self.assertEqual(wrapper.count("try mail.retainedSendLifecycle("), 4)
        self.assertIn("try calendar.thousandCalendarIdentityScenario();", wrapper)
        http = (ROOT / "src/session_cache_integration_tests.zig").read_text()
        calendar = (ROOT / "src/calendar_identity_history_tests.zig").read_text()
        self.assertIn("pub fn retainedSendLifecycle(", http)
        self.assertIn("pub fn thousandCalendarIdentityScenario()", calendar)
        self.assertNotIn('test "retained history HTTP: 1001', http)
        self.assertNotIn('test "retained blobs HTTP: 4097', http)
        self.assertNotIn('test "calendar identity history: 1001', calendar)
        build = (ROOT / "build.zig").read_text()
        ordinary = build.split('const correctness =', 1)[1].split('const send_stress =', 1)[0]
        self.assertNotIn("native_history_stress_tests.zig", ordinary)
        stress = build.split('const history_stress =', 1)[1].split('const probes =', 1)[0]
        self.assertIn('.filters = &.{"native history stress:"}', stress)
        self.assertIn('b.option(HistoryCase, "history-case",', build)
        self.assertIn('orelse .all', build)
        self.assertIn('b.path("src/native_history_stress_tests.zig")', stress)
        self.assertIn('guardedTestRun(b, history_stress, test_watchdog)', stress)
        self.assertIn('prependRunEnvironment(b, history_run, "OMAGMA_HISTORY_CASE", @tagName(history_case));', stress)
        self.assertNotIn(".setEnvironmentVariable(", build)
        self.assertIn('std.testing.environ.getPosix("OMAGMA_HISTORY_CASE") orelse "all"', wrapper)
        for case in (".calendar", '.@"sends-plain"', '.@"sends-vault"', '.@"files-plain"', '.@"files-vault"'):
            self.assertEqual(wrapper.count(f"try selected({case});"), 1)

    def test_prepare_tests_compiles_all_roots_without_running_them(self):
        build = (ROOT / "build.zig").read_text()
        prepare = build.split("const prepare_tests =", 1)[1].split("const probes =", 1)[0]
        self.assertIn('b.step("prepare-tests",', prepare)
        for artifact in ("t", "extra_tests", "memory_tests", "browser_export_tests", "browser_server_tests",
                         "browser_cache_tests", "browser_provider_tests", "contact_isolation_tests",
                         "mailbox_tests", "send_stress", "history_stress"):
            self.assertIn(artifact, prepare)
        self.assertIn("prepare_tests.dependOn(&artifact.step)", prepare)
        self.assertNotIn("guardedTestRun", prepare)
        self.assertNotIn("addRunArtifact", prepare)
        self.assertNotIn("addSystemCommand", prepare)

    def test_ci_prepares_only_the_shared_history_artifact_without_running_it(self):
        build = (ROOT / "build.zig").read_text()
        prepare = build.split("const prepare_history =", 1)[1].split("const probes =", 1)[0]
        self.assertIn('b.step("prepare-history",', prepare)
        self.assertEqual(prepare.count(".dependOn("), 1)
        self.assertIn("prepare_history.dependOn(&history_stress.step)", prepare)
        self.assertNotIn("guardedTestRun", prepare)
        self.assertNotIn("addRunArtifact", prepare)
        self.assertNotIn("addSystemCommand", prepare)
        gate = (ROOT / ".github/workflows/native-gate.yml").read_text()
        self.assertNotIn("zig build prepare-tests ", gate)
        prepared = [step for step in gate.split("      - name:") if "zig build prepare-history " in step]
        self.assertEqual(len(prepared), 1)
        self.assertIn("if: inputs.gate == 'compile'", prepared[0])
        self.assertIn("-Doptimize=safe", prepared[0])
        self.assertIn("-Dtarget=", prepared[0])
        self.assertIn("-Dcpu=baseline", prepared[0])

    def test_maker_timeout_preserves_phase_markers_and_partial_output(self):
        failure = subprocess.TimeoutExpired(["synthetic-maker"], 180,
                                            output=b"partial protocol output\n")

        class Child:
            pid = 23456
            returncode = None

            def communicate(self, timeout):
                if timeout == 180:
                    raise failure
                self.returncode = -signal.SIGTERM
                return b"partial protocol output\ncleanup output\n", None

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "entered-healthy-0").write_text("yes")
            output = io.StringIO()
            child = Child()
            before_cleanup = []
            with patch.object(subprocess, "Popen", return_value=child), \
                    patch.object(os, "killpg", side_effect=lambda *_: before_cleanup.append(output.getvalue())) as killpg, \
                    contextlib.redirect_stdout(output):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    run_maker_phase(["synthetic-maker"], directory, "healthy", 180)
            self.assertIs(caught.exception, failure)
            killpg.assert_called_once_with(child.pid, signal.SIGTERM)
            self.assertEqual(len(before_cleanup), 1)
            text = before_cleanup[0]
            self.assertIn('"event": "start"', text)
            self.assertIn('"event": "error"', text)
            self.assertIn('"phase": "healthy"', text)
            self.assertIn('"enteredTests": ["entered-healthy-0"]', text)
            self.assertIn('"error": "TimeoutExpired"', text)
            self.assertIn("partial output before cleanup:\npartial protocol output", text)
            self.assertNotIn("cleanup output", text)


def entered_tests(directory):
    return sorted(path.name for path in directory.glob("entered-*"))


def run_maker_phase(argv, directory, phase, budget, *, env=None):
    started = time.monotonic()

    def receipt(event, **details):
        print(json.dumps({"makerPhase": {"phase": phase, "event": event,
              "budgetSeconds": budget, "elapsedSeconds": round(time.monotonic() - started, 3),
              "enteredTests": entered_tests(directory), **details}}), flush=True)

    def captured_output(label, output):
        text = output.decode(errors="replace") if isinstance(output, bytes) else output or ""
        print(f"Maker oracle {phase} {label}:\n{text}", flush=True)

    receipt("start", argv=argv)
    child = subprocess.Popen(argv, cwd=directory, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True, env=env)
    try:
        out, _ = child.communicate(timeout=budget)
    except BaseException as error:
        # Preserve the phase and partial diagnostics before cleanup can fail.
        receipt("error", error=type(error).__name__)
        captured_output("partial output before cleanup", getattr(error, "output", None))
        if child.returncode is None:
            # Let the guard clean its separate session before forcing the
            # Maker group down. Every failure-path pipe drain stays bounded.
            os.killpg(child.pid, signal.SIGTERM)
            try:
                out, _ = child.communicate(timeout=5)
                captured_output("output after cleanup", out)
            except subprocess.TimeoutExpired as cleanup_error:
                captured_output("partial output during cleanup", cleanup_error.output)
                if child.returncode is None:
                    os.killpg(child.pid, signal.SIGKILL)
                try:
                    out, _ = child.communicate(timeout=2)
                    captured_output("output after forced cleanup", out)
                except subprocess.TimeoutExpired as forced_error:
                    captured_output("partial output after forced cleanup", forced_error.output)
                    child.stdout.close()
                    child.wait(timeout=2)
        raise
    text = out.decode(errors="replace")
    captured_output("output", text)
    receipt("complete", exitCode=child.returncode)
    return child.returncode, text


def maker_oracle(zig):
    """Compile only tiny synthetic roots; local callers hold the host lock."""
    if subprocess.check_output([zig, "version"], text=True, timeout=10).strip() != "0.17.0":
        raise AssertionError("Maker oracle requires exact Zig 0.17.0")
    with tempfile.TemporaryDirectory(prefix="omagma-test-guard-") as temporary:
        directory = Path(temporary)
        (directory / "tests").mkdir()
        shutil.copyfile(GUARD, directory / "tests/zig_test_guard.py")
        shutil.copyfile(ROOT / "build.zig", directory / "project_build.zig")
        shutil.copyfile(ROOT / "build.zig.zon", directory / "build.zig.zon")
        (directory / "build.zig").write_text('''const std = @import("std");
const project = @import("project_build.zig");
pub fn build(b: *std.Build) void {
    const prepare = b.step("prepare", "Compile both oracle roots without running tests");
    for ([_][]const u8{ "healthy", "timeout" }) |name| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
            .target = b.graph.host, .optimize = .safe, .link_libc = true,
        }) });
        prepare.dependOn(&t.step);
        const run = project.guardedTestRun(b, t, true);
        project.prependRunEnvironment(b, run, "OMAGMA_HISTORY_CASE", "calendar");
        b.step(name, name).dependOn(&run.step);
    }
}
''')
        (directory / "healthy.zig").write_text('const std = @import("std");\n' + "\n".join(
            f'test "healthy {index}" {{ '
            'try std.testing.expectEqualStrings("worker-test-only", '
            'std.testing.environ.getPosix("OMAGMA_ENV_CACHE_SENTINEL") orelse "missing"); '
            'try std.testing.expectEqualStrings("calendar", '
            'std.testing.environ.getPosix("OMAGMA_HISTORY_CASE") orelse "missing"); '
            'try std.Io.Dir.cwd().writeFile(std.testing.io, '
            f'.{{ .sub_path = "entered-healthy-{index}", .data = "yes" }}); '
            'try (std.Io.Clock.Duration{ .clock = .awake, '
            '.raw = .fromMilliseconds(600) }).sleep(std.testing.io); }' for index in range(4)))
        (directory / "timeout.zig").write_text('''const std = @import("std");
fn ignore(_: std.posix.SIG) callconv(.c) void {}
test "guard caught TERM must time out" {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = ignore },
        .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &action, null);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "entered-timeout", .data = "yes" });
    while (true) try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromSeconds(1) }).sleep(std.testing.io);
}
test "guard following test still runs" {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "entered-following", .data = "yes" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "following-ran", .data = "yes" });
}
''')
        # Cold compiler/toolchain setup has its own budget. Neither compile
        # step may execute a test; cached Maker runs keep the short deadline.
        prepare_argv = [zig, "build", "prepare", "-j2", "--summary", "all"]
        producer_env = dict(os.environ, OMAGMA_ENV_CACHE_SENTINEL="producer-test-only")
        worker_env = dict(os.environ, OMAGMA_ENV_CACHE_SENTINEL="worker-test-only")
        code, text = run_maker_phase(prepare_argv, directory, "prepare", 900, env=producer_env)
        assert code == 0, text
        assert entered_tests(directory) == [], "prepare must compile without running tests"
        assert not (directory / "following-ran").exists()

        def check_configuration_sentinel():
            files = sorted(path for path in (directory / ".zig-cache/c").iterdir() if path.is_file())
            assert files, "Maker must produce cached configuration for the handoff check"
            for path in files:
                # Inspect only the harmless sentinel we supplied. Never print
                # configuration contents or inspect other environment values.
                assert b"producer-test-only" not in path.read_bytes(), \
                    "Build configuration retained the producer environment sentinel"
            return [path.name for path in files]

        prepared_configurations = check_configuration_sentinel()
        results = []
        for name, timeout in (("healthy", "2s"), ("timeout", "1s")):
            argv = [zig, "build", name, "-j2", "--summary", "all", "--test-timeout", timeout]
            code, text = run_maker_phase(argv, directory, name, 180, env=worker_env)
            results.append({"case": name, "exitCode": code})
            healthy_markers = [f"entered-healthy-{index}" for index in range(4)]
            if name == "healthy":
                assert code == 0 and "4/4 tests passed" in text, text
                assert entered_tests(directory) == healthy_markers
                # Leave compiler/build inputs unchanged and reuse their cache,
                # but require every test to execute again. A cached successful
                # Run step would leave these external observation files absent.
                for marker in healthy_markers:
                    (directory / marker).unlink()
                repeat_code, repeat_text = run_maker_phase(argv, directory, "healthy-cached", 180,
                                                         env=worker_env)
                assert repeat_code == 0 and "4/4 tests passed" in repeat_text, repeat_text
                assert entered_tests(directory) == healthy_markers, "Compilation cache suppressed test execution"
                results.append({"case": "healthy-cached", "exitCode": repeat_code,
                                "executedTests": len(healthy_markers)})
            else:
                assert code != 0, text
                assert "guard caught TERM must time out" in text and "timed out after" in text, text
                assert "1/2 tests passed" in text and "1 timed out" in text, text
                assert entered_tests(directory) == sorted([*healthy_markers, "entered-timeout", "entered-following"])
                assert (directory / "following-ran").read_text() == "yes"
        assert check_configuration_sentinel() == prepared_configurations, \
            "Worker must exercise the producer's cached configuration"
        results.append({"case": "runtime-environment", "producerSentinelCached": False,
                        "workerEnvironmentInherited": True, "publicSelectorApplied": True})
        return results


def cache_handoff_oracle(zig):
    """Exercise restored configuration caches in isolated, disposable paths."""
    if subprocess.check_output([zig, "version"], text=True, timeout=10).strip() != "0.17.0":
        raise AssertionError("Cache handoff oracle requires exact Zig 0.17.0")
    with tempfile.TemporaryDirectory(prefix="omagma-cache-handoff-") as temporary:
        directory = Path(temporary)
        source = directory / "source"
        source.mkdir()
        (source / "build.zig").write_text('''const std = @import("std");
pub fn build(b: *std.Build) void {
    _ = b.standardOptimizeOption(.{});
    _ = b.option(bool, "different", "Request a fresh build configuration");
    _ = b.step("empty", "No application compilation or test execution");
}
''')

        def run(path, phase, *options):
            argv = [zig, "build", "empty", "-Doptimize=safe", "-j2", "--summary", "all", *options]
            env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(path / ".ci-zig/global"))
            return run_maker_phase(argv, path, phase, 180, env=env)

        code, text = run(source, "cache-prime")
        assert code == 0, text
        # Reproduce the old CI cleanup, but only within this disposable fixture.
        for relative in (".zig-cache/tmp", ".ci-zig/global/tmp"):
            shutil.rmtree(source / relative, ignore_errors=True)
        restored = directory / "restored"
        shutil.copytree(source, restored)
        code, text = run(restored, "cache-missing-tmp", "-Ddifferent=true")
        assert code != 0 and "configuration failed: FileNotFound" in text, text
        # Keep all failed-case cache contents until the fixture ends. The repair
        # must only create missing directories, without invalidation/recompile.
        subprocess.run([sys.executable, str(ROOT / ".github/ci_cache_prepare.py")],
                       cwd=restored, check=True, timeout=10)
        code, text = run(restored, "cache-restored-tmp", "-Ddifferent=true")
        assert code == 0 and "1/1 steps succeeded" in text, text
        return {"missingTmpRejected": True, "restoredTmpSucceeded": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", help="also run the tiny actual Maker oracle (local host lock required)")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(GuardTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.zig:
        zig = str(Path(args.zig).resolve())
        print(json.dumps({"maker": maker_oracle(zig), "cacheHandoff": cache_handoff_oracle(zig)}))
