"""Cheap ownership/parser tests; no browser, workload, or host-lock mutation."""
import importlib.util
import os
from pathlib import Path
import signal
import socket
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("short0219_guard", Path(__file__).with_name("resource_guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def row(pid, ppid, pgid, born="one", state="S"):
    return dict(pid=pid, ppid=ppid, pgid=pgid, born=born, state=state, rss=10, cpu=.1)


class ResourceGuardTests(unittest.TestCase):
    def test_linux_and_macos_cpu_clocks(self):
        self.assertEqual(guard.cpu_seconds("00:01.25"), 1.25)
        self.assertEqual(guard.cpu_seconds("01:02:03"), 3723)
        self.assertEqual(guard.cpu_seconds("2-01:02:03"), 176523)
        for invalid in ("", "NaN", "inf", "1:2:3:4", "-00:02"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                guard.cpu_seconds(invalid)

    def test_descendants_and_reparented_owned_sessions_only(self):
        table = {100: row(100, 77, 100), 101: row(101, 100, 100),
                 102: row(102, 101, 102), 103: row(103, 1, 100),
                 200: row(200, 1, 200), 201: row(201, 200, 200)}
        known = {}
        with patch.object(guard.os, "getpid", return_value=77), patch.object(guard.os, "getpgrp", return_value=77):
            selected = guard.owned_processes(table, 100, known)
            self.assertEqual(set(selected), {100, 101, 102, 103})
            table[102]["ppid"] = 1
            table.pop(100)
            self.assertEqual(set(guard.owned_processes(table, 100, known)), {101, 102, 103})

    def test_pid_reuse_and_zombie_are_not_live_ownership(self):
        table = {101: row(101, 1, 999, born="different"), 102: row(102, 1, 102, state="Z")}
        with patch.object(guard.os, "getpid", return_value=77), patch.object(guard.os, "getpgrp", return_value=77):
            self.assertEqual(guard.owned_processes(table, 100, {101: "original", 102: "one"}), {})
        self.assertIsNone(guard.identity(102, table))

    def test_signal_rechecks_birth_and_group(self):
        old = {101: row(101, 100, 100), 102: row(102, 100, 100), 103: row(103, 100, 100)}
        fresh = {101: row(101, 100, 100), 102: row(102, 100, 100, born="reused"),
                 103: row(103, 100, 999)}
        with patch.object(guard, "processes", return_value=fresh), patch.object(guard.os, "kill") as kill:
            guard.signal_owned(old, signal.SIGTERM, {pid: "one" for pid in old})
            kill.assert_called_once_with(101, signal.SIGTERM)

    def test_lease_requires_token_host_and_exact_live_birth(self):
        owner = dict(token="test-only", hostname=socket.gethostname(), pid=123, pidStartTicks=456)
        with patch.object(guard, "read_owner", return_value=owner), patch.object(guard, "identity", return_value="456"):
            self.assertEqual(guard.verify("test-only"), owner)
            with self.assertRaises(ValueError):
                guard.verify("wrong")
            owner["hostname"] = "another-host.invalid"
            with self.assertRaises(ValueError):
                guard.verify("test-only")
            owner["hostname"] = socket.gethostname()
        with patch.object(guard, "read_owner", return_value=owner), patch.object(guard, "identity", return_value="457"):
            with self.assertRaises(ValueError):
                guard.verify("test-only")

    def test_receipt_rejects_traversal_symlinks_and_previous_evidence(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(guard, "ROOT", Path(temporary)):
            root = Path(temporary)
            with self.assertRaises(ValueError):
                guard.safe_report(root / "video/cache/short0219/../../../escape.json")
            path = guard.safe_report(root / "video/cache/short0219/resources/test.json")
            path.write_text("preserved")
            with self.assertRaises(ValueError):
                guard.safe_report(path)
            target = root / "elsewhere"
            target.mkdir()
            (path.parent / "link").symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                guard.safe_report(path.parent / "link/escape.json")
            self.assertEqual(path.read_text(), "preserved")


if __name__ == "__main__":
    unittest.main()
