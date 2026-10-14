#!/usr/bin/env python3
"""Owned-process supervisor oracles; --zig also checks the actual Maker protocol."""
from __future__ import annotations

import argparse
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

    def test_release_preserves_all_eight_unit_timeouts_and_opts_in(self):
        commands = [line for line in (ROOT / ".github/workflows/release.yml").read_text().splitlines()
                    if "--test-timeout" in line]
        self.assertEqual(len(commands), 8)
        for command in commands:
            self.assertIn("--test-timeout 120s", command)
            self.assertIn("-Dtest-watchdog=true", command)


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
    for ([_][]const u8{ "healthy", "timeout" }) |name| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
            .target = b.graph.host, .optimize = .Debug, .link_libc = true,
        }) });
        b.step(name, name).dependOn(&project.guardedTestRun(b, t, true).step);
    }
}
''')
        (directory / "healthy.zig").write_text('const std = @import("std");\n' + "\n".join(
            f'test "healthy {index}" {{ try (std.Io.Clock.Duration{{ .clock = .awake, '
            '.raw = .fromMilliseconds(600) }).sleep(std.testing.io); }' for index in range(4)))
        (directory / "timeout.zig").write_text('''const std = @import("std");
fn ignore(_: std.posix.SIG) callconv(.c) void {}
test "guard caught TERM must time out" {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = ignore },
        .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &action, null);
    while (true) try (std.Io.Clock.Duration{ .clock = .awake, .raw = .fromSeconds(1) }).sleep(std.testing.io);
}
test "guard following test still runs" {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "following-ran", .data = "yes" });
}
''')
        results = []
        for name, timeout in (("healthy", "2s"), ("timeout", "1s")):
            argv = [zig, "build", name, "-j2", "--summary", "all", "--test-timeout", timeout]
            child = subprocess.Popen(argv, cwd=directory, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            try:
                out, _ = child.communicate(timeout=180)
            except BaseException:
                if child.returncode is None:
                    # Let the guard clean its separate session before forcing
                    # the Maker group down. Even failure-path pipe drains are
                    # bounded if a broken guard leaves an inherited pipe open.
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        if child.returncode is None:
                            os.killpg(child.pid, signal.SIGKILL)
                        try:
                            child.communicate(timeout=2)
                        except subprocess.TimeoutExpired:
                            child.stdout.close()
                            child.wait(timeout=2)
                raise
            text = out.decode(errors="replace")
            print(f"Maker oracle {name}:\n{text}", flush=True)
            results.append({"case": name, "exitCode": child.returncode})
            if name == "healthy":
                assert child.returncode == 0 and "4/4 tests passed" in text, text
            else:
                assert child.returncode != 0, text
                assert "guard caught TERM must time out" in text and "timed out after" in text, text
                assert "1/2 tests passed" in text and "1 timed out" in text, text
                assert (directory / "following-ran").read_text() == "yes"
        return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", help="also run the tiny actual Maker oracle (local host lock required)")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(GuardTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.zig:
        print(json.dumps({"maker": maker_oracle(str(Path(args.zig).resolve()))}))
