#!/usr/bin/env python3
"""Offline checks for Zig cache handoff preparation; no compiler or network."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / ".github/ci_cache_prepare.py"
SPEC = importlib.util.spec_from_file_location("cache_prepare", HELPER)
cache_prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache_prepare)


class CachePreparation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omagma-cache-prepare-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_missing_restored_temporary_directories_are_recreated(self):
        for relative in (".zig-cache/o", ".ci-zig/global/p"):
            (self.root / relative).mkdir(parents=True)
        cache_prepare.prepare(self.root)
        for relative in cache_prepare.TEMPORARY_DIRECTORIES:
            self.assertTrue((self.root / relative).is_dir())
            self.assertEqual(list((self.root / relative).iterdir()), [])

    def test_restore_preparation_preserves_existing_temporary_contents(self):
        for relative in cache_prepare.TEMPORARY_DIRECTORIES:
            directory = self.root / relative
            directory.mkdir(parents=True)
            (directory / "partial").write_bytes(b"unfinished configuration")
        cache_prepare.prepare(self.root)
        for relative in cache_prepare.TEMPORARY_DIRECTORIES:
            self.assertEqual((self.root / relative / "partial").read_bytes(),
                             b"unfinished configuration")

    def test_clean_removes_only_temporary_contents_and_keeps_empty_directories(self):
        for relative in cache_prepare.TEMPORARY_DIRECTORIES:
            directory = self.root / relative
            (directory / "nested").mkdir(parents=True)
            (directory / "nested/fixture").write_text("discard")
            (directory.parent / "compiled-object").write_bytes(b"retain")
        cache_prepare.prepare(self.root, clean=True)
        for relative in cache_prepare.TEMPORARY_DIRECTORIES:
            directory = self.root / relative
            self.assertTrue(directory.is_dir())
            self.assertEqual(list(directory.iterdir()), [])
            self.assertEqual((directory.parent / "compiled-object").read_bytes(), b"retain")

    def test_command_line_handles_cold_and_repeated_preparation(self):
        for arguments in ([], [], ["--clean"], ["--clean"]):
            subprocess.run([sys.executable, str(HELPER), *arguments],
                           cwd=self.root, check=True, capture_output=True)
        for relative in cache_prepare.TEMPORARY_DIRECTORIES:
            self.assertTrue((self.root / relative).is_dir())


if __name__ == "__main__":
    unittest.main()
