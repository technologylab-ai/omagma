#!/usr/bin/env python3
"""Offline release prose selection; no GitHub calls or artifact publishing."""
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from publish_release import release_notes


class ReleaseNotes(unittest.TestCase):
    def test_reviewed_025_highlights_and_matching_links(self):
        text = release_notes("0.2.5", "0.17.0", "technologylab-ai/omagma")
        for phrase in ("Live cached mail updates", "`gg` across the cache", "Cleaner mail rendering",
                       "**experimental**", "Linux-only", "no new Google permission", "Zig 0.17.0"):
            self.assertIn(phrase, text)
        self.assertIn("/blob/v0.2.5/docs/TERMINAL.md", text)
        self.assertIn("omagma-0.2.5-OS-ARCH.tar.gz", text)
        self.assertNotIn("/blob/v0.2.4/", text)

    def test_specific_file_precedes_generic_feature_prose(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            notes = root / "docs/release-notes/8.7.6.md"
            notes.parent.mkdir(parents=True)
            notes.write_text("Reviewed synthetic release summary.\n")
            text = release_notes("8.7.6", "0.17.0", "example/project", root)
            self.assertTrue(text.startswith("Reviewed synthetic release summary.\n\n"))
            self.assertIn("/blob/v8.7.6/docs/INSTALL.md", text)
            self.assertNotIn("Includes the account-separated bar", text)

    def test_missing_version_file_uses_generic_current_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            text = release_notes("8.7.5", "0.17.0", "example/project", Path(temporary))
            for phrase in ("static musl", "native macOS", "**experimental**", "existing labels",
                           "an explicit action", "No tmux", "/blob/v8.7.5/"):
                self.assertIn(phrase, text)
            self.assertNotIn("0.2.4", text)
            self.assertNotIn("0.2.5", text)

    def test_empty_or_oversized_reviewed_notes_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            notes = root / "docs/release-notes/8.7.6.md"
            notes.parent.mkdir(parents=True)
            for content in ("  \n", "a" * (64 * 1024 + 1)):
                notes.write_text(content)
                with self.assertRaisesRegex(ValueError, "empty or oversized"):
                    release_notes("8.7.6", "0.17.0", "example/project", root)


if __name__ == "__main__":
    unittest.main()
