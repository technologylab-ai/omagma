#!/usr/bin/env python3
"""Run the shared UX acceptance cases with the native Darwin guardian PTY.

The guardian keeps its controlling session alive until the ordinary harness has
observed terminal restoration. Mouse reporting and physical resize retain the
same shared oracles; no Linux resource sampler or desktop is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys
import tempfile
import time
from unittest.mock import patch

from build_info import build_mode, read_build_info
from terminal_integration import require
from terminal_macos import DarwinTerminal
from terminal_mouse import MouseTerminal
import terminal_mouse
import terminal_label_manager as label_manager
import terminal_ux_adversarial as adversarial
import terminal_ux_batch_compose as compose
import terminal_ux_batch_files_contacts as files
import terminal_ux_batch_navigation as navigation
import terminal_ux_batch_support as support
import terminal_ux_helpers_ui as helpers
import terminal_updates as updates_ui


class DarwinMouseTerminal(DarwinTerminal, MouseTerminal):
    """Existing guardian lifecycle with existing cell mouse/resize handling."""


CASES = (
    ("palette", navigation.palette),
    ("palette-mono", navigation.palette_mono),
    ("find-unread", navigation.find_and_unread),
    ("labels", navigation.labels),
    ("history", navigation.history),
    ("scope-trash", navigation.scope_trash),
    ("sender-completion-undo", compose.sender_completion_undo),
    ("attachment-reminder", compose.attachment_reminder),
    ("countdown-cancel", compose.countdown_cancel),
    ("countdown-due", compose.countdown_due),
    ("save-all", files.save_all),
    ("multi-select", files.multi_select),
    ("multi-preflight", files.multi_preflight),
    ("incoming-large", files.incoming_large),
    ("large-file", files.large_file),
    ("contact-multiple", files.contact_multiple_addresses),
    ("discard-draft", files.discard_draft),
    ("saved-searches", helpers.saved_searches),
    ("contact-second-address", helpers.contact_second_address),
    ("updates-card-guide", updates_ui.card_and_guide),
    ("updates-narrow", updates_ui.narrow),
    ("label-color-held-read", label_manager.colors_held_read),
    ("label-color-held-read-mouse", label_manager.colors_held_read_mouse),
    # The helper and adversarial cases use the same shared factory.
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="safe")
    parser.add_argument("--case", action="append")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin", "native UX acceptance requires Darwin")
    require(not args.output.exists(), "refusing previous native UX receipt overwrite")
    cases = (*CASES, *adversarial.CASES)
    names = [name for name, _ in cases]
    require(len(names) == len(set(names)), "duplicate native UX case names")
    require(not args.case or set(args.case) <= set(names), "unknown native UX case")
    selected = [(name, case) for name, case in cases if not args.case or name in args.case]
    binary = args.binary.resolve()
    receipt = {**read_build_info(binary, args.build_mode),
               "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "platform": "darwin", "architecture": platform.machine(),
               "syntheticOnly": True, "liveWrites": False, "desktopUsed": False,
               "guardianTty": True, "linuxResourceHarnessUsed": False,
               "cases": [], "passed": False}
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with patch.object(support, "MouseTerminal", DarwinMouseTerminal), \
            patch.object(helpers, "MouseTerminal", DarwinMouseTerminal), \
            patch.object(updates_ui, "Terminal", DarwinMouseTerminal), \
            patch.object(terminal_mouse, "MouseTerminal", DarwinMouseTerminal), \
            tempfile.TemporaryDirectory(prefix="omagma-macos-ux-") as temporary:
        # /var on Darwin is a symlink; file browsing uses the real owned spelling.
        root = Path(temporary).resolve()
        for name, case in selected:
            directory = root / name
            directory.mkdir(mode=0o700)
            result = {"name": name, "passed": False}
            started = time.monotonic()
            try:
                case(binary, directory, None)
                result["passed"] = True
            except Exception as failure:
                result["error"] = f"{type(failure).__name__}: {failure}"
            result["elapsedSeconds"] = round(time.monotonic() - started, 4)
            receipt["cases"].append(result)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")
            args.output.chmod(0o600)
            print(json.dumps(result), flush=True)
            if not result["passed"]:
                return 1
    receipt["passed"] = len(receipt["cases"]) == len(selected)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
