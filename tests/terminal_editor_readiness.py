#!/usr/bin/env python3
"""Offline regression for successive received-editor raw-input handoffs."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from terminal_reader_editor import editor_input_ready


PROMPT = b"OWNED RECEIVED SNAPSHOT EDITOR:"


class EditorReadiness(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omagma-editor-readiness-")
        self.addCleanup(self.temporary.cleanup)
        self.terminal = SimpleNamespace(
            editor_log=Path(self.temporary.name) / "editor.json",
            output=bytearray(PROMPT + b" previous editor\r\n"),
        )
        self.output_start = len(self.terminal.output)

    def test_old_prompt_and_fresh_receipt_do_not_authorize_input(self):
        # The fixture publishes this receipt before tty.setraw(). A previous
        # editor's normal-screen prompt must not satisfy the current handoff.
        self.terminal.editor_log.write_text('{"entered": true}\n')
        self.assertIn(PROMPT, self.terminal.output)
        self.assertFalse(editor_input_ready(self.terminal, self.output_start))

    def test_fragmented_fresh_prompt_waits_until_raw_ready_marker_is_complete(self):
        self.terminal.editor_log.write_text('{"entered": true}\n')
        before = bytes(self.terminal.output)
        self.terminal.output.extend(b"\r\n" + PROMPT[:-1])
        self.assertFalse(editor_input_ready(self.terminal, self.output_start))
        # The fixture emits this prompt only after setraw() has completed.
        self.terminal.output.extend(PROMPT[-1:])
        self.assertTrue(editor_input_ready(self.terminal, self.output_start))
        self.assertEqual(self.terminal.output[:self.output_start], before)

    def test_each_successive_editor_requires_its_own_fresh_prompt(self):
        self.terminal.editor_log.write_text('{"entered": true}\n')
        for _ in range(4):
            baseline = len(self.terminal.output)
            self.assertFalse(editor_input_ready(self.terminal, baseline))
            self.terminal.output.extend(b"\r\n" + PROMPT + b"\r\n")
            self.assertTrue(editor_input_ready(self.terminal, baseline))

    def test_fresh_prompt_still_requires_the_current_entry_receipt(self):
        self.terminal.output.extend(PROMPT)
        self.assertFalse(editor_input_ready(self.terminal, self.output_start))
        self.terminal.editor_log.write_text('{"entered": true}\n')
        self.assertTrue(editor_input_ready(self.terminal, self.output_start))


if __name__ == "__main__":
    unittest.main()
