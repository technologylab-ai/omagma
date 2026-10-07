#!/usr/bin/env python3
"""Native guardian-PTY acceptance for gg, arrivals and HTML reader UX.

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
from terminal_integration import require
from terminal_macos import DarwinTerminal

CASES = ("gg-whole-cache", "accumulate-and-dismiss", "main-only-and-wheel",
         "anchor-later-window", "html-reader-ux")


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
            tempfile.TemporaryDirectory(prefix="omagma-macos-features-") as temporary:
        for case in args.case or CASES:
            result = {"name": case, "passed": False}
            started = time.monotonic()
            try:
                directory = Path(temporary) / case
                if case == "html-reader-ux":
                    result.update(terminal_html.reader_ux_case(binary, directory))
                else:
                    terminal_arrivals.run(binary, directory, case)
                result["passed"] = True
            except Exception as failure:
                result["error"] = f"{type(failure).__name__}: {failure}"
                if isinstance(failure, terminal_html.HtmlFailure):
                    result["diagnostics"] = failure.diagnostics
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
