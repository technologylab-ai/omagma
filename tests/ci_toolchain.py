#!/usr/bin/env python3
"""Offline CI compiler archive-cache oracles; no network, extraction or builds."""
from copy import deepcopy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("install_zig", ROOT / ".github/install_zig.py")
installer = importlib.util.module_from_spec(SPEC)
# Import must be usable without runner environment, downloads or extraction.
with patch.dict(os.environ, {}, clear=True), \
        patch("urllib.request.urlopen", side_effect=AssertionError("network during import")), \
        patch("tarfile.open", side_effect=AssertionError("extraction during import")):
    SPEC.loader.exec_module(installer)

ARCHIVE = b"synthetic official compiler archive"
ITEM = {"size": str(len(ARCHIVE)), "shasum": hashlib.sha256(ARCHIVE).hexdigest(),
        "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz"}


class TrackedStream(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.read_sizes = []

    def read(self, size=-1):
        self.read_sizes.append(size)
        return super().read(size)


class ToolchainCache(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omagma-ci-toolchain-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.archive = self.directory / "compiler.tar.xz"

    def test_valid_cache_rechecks_checksum_without_network(self):
        self.archive.write_bytes(ARCHIVE)
        with patch.object(installer.urllib.request, "urlopen") as network, \
                patch.object(installer, "read_verified_archive", wraps=installer.read_verified_archive) as verify:
            installer.ensure_archive(self.archive, ITEM)
            installer.ensure_archive(self.archive, ITEM)
        network.assert_not_called()
        self.assertEqual(verify.call_count, 2)
        self.assertEqual(self.archive.read_bytes(), ARCHIVE)

    def test_missing_corrupt_and_wrong_size_caches_download_verified_replacements(self):
        for cached in (None, b"!" * len(ARCHIVE), ARCHIVE[:-1], ARCHIVE + b"extra"):
            with self.subTest(cached=cached):
                if cached is None:
                    self.archive.unlink(missing_ok=True)
                else:
                    self.archive.write_bytes(cached)
                response = TrackedStream(ARCHIVE)
                with patch.object(installer.urllib.request, "urlopen", return_value=response) as network:
                    installer.ensure_archive(self.archive, ITEM)
                network.assert_called_once_with(ITEM["tarball"], timeout=180)
                self.assertEqual(response.read_sizes, [len(ARCHIVE) + 1])
                self.assertTrue(response.closed)
                self.assertEqual(self.archive.read_bytes(), ARCHIVE)

    def test_wrong_size_cache_is_not_read_into_memory(self):
        self.archive.write_bytes(ARCHIVE + b"extra")
        with patch.object(self.archive.__class__, "open", side_effect=AssertionError("read wrong-size cache")), \
                patch.object(installer, "download_archive") as download:
            installer.ensure_archive(self.archive, ITEM)
        download.assert_called_once_with(self.archive, ITEM)

    def test_invalid_download_does_not_overwrite_an_existing_verified_archive(self):
        for downloaded in (b"?" * len(ARCHIVE), ARCHIVE[:-1], ARCHIVE + b"extra"):
            with self.subTest(downloaded=downloaded):
                self.archive.write_bytes(ARCHIVE)
                response = TrackedStream(downloaded)
                with patch.object(installer.urllib.request, "urlopen", return_value=response):
                    with self.assertRaisesRegex(ValueError, "size/checksum mismatch"):
                        installer.download_archive(self.archive, ITEM)
                self.assertEqual(self.archive.read_bytes(), ARCHIVE)
                self.assertEqual(response.read_sizes, [len(ARCHIVE) + 1])

    def test_invalid_download_does_not_create_a_cache_entry(self):
        with patch.object(installer.urllib.request, "urlopen", return_value=io.BytesIO(b"corrupt")):
            with self.assertRaisesRegex(ValueError, "size/checksum mismatch"):
                installer.ensure_archive(self.archive, ITEM)
        self.assertFalse(self.archive.exists())

    def test_corrupt_cache_survives_rejected_replacement_for_inspection(self):
        corrupt = b"!" * len(ARCHIVE)
        self.archive.write_bytes(corrupt)
        with patch.object(installer.urllib.request, "urlopen", return_value=io.BytesIO(b"also corrupt")):
            with self.assertRaisesRegex(ValueError, "size/checksum mismatch"):
                installer.ensure_archive(self.archive, ITEM)
        self.assertEqual(self.archive.read_bytes(), corrupt)

    def test_stream_read_is_bounded_to_expected_size_plus_one(self):
        response = TrackedStream(ARCHIVE + b"extra" * 10000)
        with self.assertRaisesRegex(ValueError, "size/checksum mismatch"):
            installer.read_verified_archive(response, ITEM)
        self.assertEqual(response.read_sizes, [len(ARCHIVE) + 1])
        self.assertEqual(response.tell(), len(ARCHIVE) + 1)
        for size in (0, -1, -2):
            with self.subTest(size=size):
                response = TrackedStream(ARCHIVE)
                with self.assertRaisesRegex(ValueError, "Invalid Zig archive size"):
                    installer.read_verified_archive(response, dict(ITEM, size=str(size)))
                self.assertEqual(response.read_sizes, [])

    def test_main_retains_official_pin_and_url_guards_before_download(self):
        metadata = json.loads((ROOT / ".github/zig-release.json").read_text())
        invalid = deepcopy(metadata)
        invalid["artifacts"]["x86_64-linux"]["tarball"] = "https://example.test/compiler.tar.xz"
        for version, document, message in (
                ("0.16.0", metadata, "Expected exact Zig 0.17.0"),
                ("0.17.0", dict(metadata, version="0.16.0"), "Expected exact Zig 0.17.0"),
                ("0.17.0", invalid, "Expected official exact-release archive URL")):
            with self.subTest(version=version, message=message), \
                    patch.object(installer, "package_versions", return_value=("8.7.6", version)), \
                    patch.object(installer.json, "loads", return_value=document), \
                    patch.object(installer.platform, "system", return_value="Linux"), \
                    patch.object(installer.platform, "machine", return_value="x86_64"), \
                    patch.object(installer, "ensure_archive") as archive, \
                    patch.object(installer.tarfile, "open") as extract:
                with self.assertRaisesRegex(SystemExit, message):
                    installer.main()
                archive.assert_not_called()
                extract.assert_not_called()

    def test_main_extracts_verified_archive_then_checks_executable_version(self):
        tool_cache = self.directory / "tools"
        path_file = self.directory / "github-path"
        directory = self.directory / "omagma-zig"
        compiler = directory / "zig-x86_64-linux-0.17.0" / "zig"
        compiler.parent.mkdir(parents=True)
        compiler.write_bytes(b"synthetic compiler")
        expected_archive = tool_cache / "omagma-zig" / "x86_64-linux-0.17.0.tar.xz"
        for version in ("0.17.0\n", "0.16.0\n"):
            path_file.unlink(missing_ok=True)
            events = []
            with self.subTest(version=version), \
                    patch.dict(os.environ, {"RUNNER_TEMP": str(self.directory),
                                           "RUNNER_TOOL_CACHE": str(tool_cache),
                                           "GITHUB_PATH": str(path_file)}, clear=True), \
                    patch.object(installer.platform, "system", return_value="Linux"), \
                    patch.object(installer.platform, "machine", return_value="x86_64"), \
                    patch.object(installer, "ensure_archive") as archive, \
                    patch.object(installer.tarfile, "open") as extract, \
                    patch.object(installer.subprocess, "check_output", return_value=version) as run:
                archive.side_effect = lambda *args: events.append("verify")
                extract.side_effect = lambda *args: events.append("extract") or extract.return_value
                run.side_effect = lambda *args, **kwargs: events.append("version") or version
                if version.strip() == "0.17.0":
                    installer.main()
                    self.assertEqual(path_file.read_text(), str(compiler.parent) + "\n")
                else:
                    with self.assertRaisesRegex(SystemExit, "Compiler executable version mismatch"):
                        installer.main()
                    self.assertFalse(path_file.exists())
                archive.assert_called_once()
                self.assertEqual(archive.call_args.args[0], expected_archive)
                extract.assert_called_once_with(expected_archive)
                extract.return_value.__enter__.return_value.extractall.assert_called_once_with(directory, filter="data")
                run.assert_called_once_with([str(compiler), "version"], text=True, timeout=10)
                self.assertEqual(events, ["verify", "extract", "version"])


if __name__ == "__main__":
    unittest.main()
