#!/usr/bin/env python3
"""Native guardian-PTY acceptance for readers, composing and file browsing.

Reuse the existing synthetic behavior/deadline oracles while preserving Darwin's
controlling session until terminal restoration is observed. Linux /proc-based
resource cases are deliberately outside this adapter.
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
import terminal_arrivals
import terminal_html
import terminal_markdown_compose
import terminal_file_dialog
import terminal_growing_composer
import terminal_pty
from terminal_integration import require
from terminal_macos import DarwinTerminal
from terminal_mouse_screen import MouseScreen

CASES = ("gg-whole-cache", "accumulate-and-dismiss", "main-only-and-wheel",
         "anchor-later-window", "html-reader-ux", "markdown-new", "markdown-reply",
         "markdown-forward", "file-browser-keyboard", "growing-composer",
         "unknown-send-reopen")


def guardian_mouse_start(binary, directory, fixture, extra=(), environment=None, columns=160, rows=40):
    return DarwinTerminal(binary, directory, extra=fixture.options(*extra), columns=columns, rows=rows,
                          screen_type=MouseScreen, environment={"NO_COLOR": None, "COLORTERM": "truecolor", **(environment or {})})


def unknown_send_reopen(binary, directory):
    """Use the shared receipt/recovery oracle with the Darwin session owner."""
    directory.mkdir(mode=0o700)
    preferences = directory / "fixture-ui.json"
    preferences.write_text(json.dumps({"schema": 1, "sendGraceSeconds": 0}) + "\n")
    preferences.chmod(0o600)
    terminal = DarwinTerminal(binary, directory, columns=100, rows=24,
                              extra=("--fixture-scenario", "unknown-send", "--ui-file", str(preferences)))
    try:
        return terminal_pty.exercise(terminal, "unknown-send-reopen")
    except Exception as failure:
        failure.terminal_cells = {"currentCells": terminal.screen.lines(),
                                  "exitCode": terminal.process.poll()}
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="safe")
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin", "native feature acceptance requires Darwin")
    require(not args.output.exists(), "refusing previous native feature receipt overwrite")
    binary = args.binary.resolve()
    receipt = {**read_build_info(binary, args.build_mode),
               "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "platform": "darwin", "architecture": platform.machine(),
               "syntheticOnly": True, "liveWrites": False, "desktopUsed": False,
               "guardianTty": True, "linuxResourceHarnessUsed": False,
               "cases": [], "passed": False}
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    # Module-local factories only: CLI/background helpers keep their original
    # behavior, and the factories are restored even when a case fails.
    with patch.object(terminal_arrivals, "Terminal", DarwinTerminal), \
            patch.object(terminal_html, "Terminal", DarwinTerminal), \
            patch.object(terminal_markdown_compose, "start", guardian_mouse_start), \
            patch.object(terminal_file_dialog, "start", guardian_mouse_start), \
            patch.object(terminal_growing_composer, "Terminal", DarwinTerminal), \
            tempfile.TemporaryDirectory(prefix="omagma-macos-features-") as temporary:
        # Darwin's default temporary path starts with the system /var symlink.
        # The file browser deliberately refuses every symlink component, so
        # typed fixture paths must use their real owned directory spelling.
        root = Path(temporary).resolve()
        for case in args.case or CASES:
            result = {"name": case, "passed": False}
            started = time.monotonic()
            try:
                directory = root / case
                if case.startswith("markdown-") or case in ("file-browser-keyboard", "growing-composer"):
                    directory.mkdir(mode=0o700)
                if case == "html-reader-ux":
                    result.update(terminal_html.reader_ux_case(binary, directory))
                elif case == "markdown-new":
                    result.update(terminal_markdown_compose.new_case(binary, directory))
                elif case in ("markdown-reply", "markdown-forward"):
                    result.update(terminal_markdown_compose.conversation_case(binary, directory, case.removeprefix("markdown-")))
                elif case == "file-browser-keyboard":
                    result.update(terminal_file_dialog.keyboard_case(binary, directory, None))
                elif case == "growing-composer":
                    result.update(terminal_growing_composer.exercise(binary, directory))
                elif case == "unknown-send-reopen":
                    result.update(unknown_send_reopen(binary, directory))
                else:
                    terminal_arrivals.run(binary, directory, case)
                result["passed"] = True
            except Exception as failure:
                result["error"] = f"{type(failure).__name__}: {failure}"
                if case == "growing-composer":
                    result.update(terminal_growing_composer.persist_failure(failure, directory, args.output))
                elif isinstance(failure, terminal_html.HtmlFailure):
                    result["diagnostics"] = failure.diagnostics
                elif hasattr(failure, "file_dialog_cells"):
                    result["diagnostics"] = failure.file_dialog_cells
                elif hasattr(failure, "terminal_cells"):
                    result["diagnostics"] = failure.terminal_cells
                elif (directory / "last-screen.txt").is_file():
                    result["diagnostics"] = {"currentCells": (directory / "last-screen.txt").read_text().splitlines()}
            result["elapsedSeconds"] = round(time.monotonic() - started, 4)
            receipt["cases"].append(result)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")
            args.output.chmod(0o600)
            print(json.dumps(result), flush=True)
            if not result["passed"]:
                return 1

    receipt["passed"] = len(receipt["cases"]) == len(args.case or CASES)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    args.output.chmod(0o600)
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
