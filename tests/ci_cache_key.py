#!/usr/bin/env python3
"""Offline cache-invalidation checks; no compilation or network."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cache_inputs", ROOT / ".github/ci_cache_key.py")
inputs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inputs)


class CacheIdentity(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omagma-cache-key-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / ".github").mkdir()
        self.zon = self.root / "build.zig.zon"
        self.zon.write_text('.{ .version = "0.2.14", .dependencies = .{ .vaxis = .{ .url = "https://example.test/dependency", .hash = "pinned-dependency" } } }')
        self.compiler = self.root / ".github/zig-release.json"
        self.compiler.write_text(json.dumps({"version": "0.17.0", "artifacts": {"native": {"shasum": "a" * 64}}}))

    def test_version_bumps_and_formatting_preserve_dependency_cache(self):
        original = inputs.cache_key(self.root)
        self.zon.write_text(self.zon.read_text().replace('"0.2.14"', '"0.2.15"').replace(' .hash = ', '\n.hash='))
        self.assertEqual(inputs.cache_key(self.root), original)

    def test_dependency_changes_invalidate_cache(self):
        for old, new in (("pinned-dependency", "new-pin"), ("https://example.test/dependency", "https://example.test/new")):
            previous = self.zon.read_text()
            original = inputs.cache_key(self.root)
            self.zon.write_text(previous.replace(old, new))
            self.assertNotEqual(inputs.cache_key(self.root), original)
            self.zon.write_text(previous)

    def test_compiler_archive_and_native_sdk_changes_invalidate_cache(self):
        original = inputs.cache_key(self.root, "SDK1")
        self.assertNotEqual(inputs.cache_key(self.root, "SDK2"), original)
        self.compiler.write_text(self.compiler.read_text().replace("a" * 64, "b" * 64))
        self.assertNotEqual(inputs.cache_key(self.root, "SDK1"), original)

    def test_missing_dependency_pins_fail(self):
        self.zon.write_text('.{ .version = "0.2.14" }')
        with self.assertRaisesRegex(ValueError, "No pinned"):
            inputs.cache_key(self.root)


if __name__ == "__main__":
    unittest.main()
