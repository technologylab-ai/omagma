#!/usr/bin/env python3
"""Run synthetic first-use workflows on native Linux and macOS, once per suite."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import runpy
import subprocess
import sys
import tempfile
import time

from build_info import build_mode, read_build_info

ROOT = Path(__file__).resolve().parents[1]
# Keep the complete suite defaults: attachment groups and vault child suites
# must not be repeated separately or reduced to a smoke subset in CI.
SUITES = {
    "terminal_attachment_lifecycle": (),
    "terminal_formatted_original": (),
    "terminal_formatted_tui": (),
    "terminal_message_isolation": (),
    "terminal_calendar": (),
    "terminal_calendar_tui": (),
    "terminal_calendar_join_profile": (),
    "terminal_calendar_notifications": (),
    "terminal_calendar_review_stale": (),
    "terminal_invitation_calendar_ui": (),
    "terminal_invitation_notices": (),
    "terminal_invitation_reconcile": (),
    "terminal_reader_next_ux": (),
    "terminal_follow_ups": (),
    "terminal_foreground_priority": (),
    "terminal_gmail_drafts": ("--pty",),
    "vault_migration": (),
    "vault_daemon": (),
}
RECEIPT_SUITES = {
    "terminal_attachment_lifecycle": "--output",
    "terminal_formatted_original": "--receipt",
    "terminal_formatted_tui": "--receipt",
    "terminal_calendar": "--output",
    "terminal_calendar_tui": "--output",
    "terminal_calendar_notifications": "--output",
    "terminal_calendar_review_stale": "--output",
    "terminal_invitation_calendar_ui": "--output",
    "terminal_invitation_notices": "--output",
    "terminal_invitation_reconcile": "--output",
    "terminal_foreground_priority": "--output",
}


def run_suite(name, binary, output):
    if sys.platform == "darwin":
        # Adapt only the owned test transport, before suites import its factory.
        # The existing guardian preserves termios checks after the TUI exits.
        import terminal_mouse
        from terminal_macos import DarwinTerminal

        class DarwinMouseTerminal(DarwinTerminal, terminal_mouse.MouseTerminal):
            pass

        terminal_mouse.MouseTerminal = DarwinMouseTerminal
        # Avoid /var symlinks rejected by the file browser and long Unix socket
        # paths under Darwin's default per-user temporary directory.
        tempfile.tempdir = str(Path("/tmp").resolve())
    sys.argv = [str(ROOT / "tests" / f"{name}.py"), "--binary", str(binary), *SUITES[name]]
    if name in RECEIPT_SUITES:
        sys.argv.extend((RECEIPT_SUITES[name], str(output)))
    runpy.run_path(sys.argv[0], run_name="__main__")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--build-mode", required=True, type=build_mode)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--suite", choices=SUITES, action="append",
                        help="Run only this complete suite; repeat to select several (default: all)")
    parser.add_argument("--run-suite", choices=SUITES, help=argparse.SUPPRESS)
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    if sys.platform not in ("linux", "darwin"):
        parser.error("workflow regressions require native Linux or macOS")
    if args.run_suite:
        run_suite(args.run_suite, binary, output)
        return 0
    names = list(dict.fromkeys(args.suite or SUITES))
    suite_outputs = {name: output.with_name(f"{output.stem}-{name}.json") for name in names}
    if output.exists() or any(suite_outputs[name].exists() for name in names if name in RECEIPT_SUITES):
        parser.error("refusing previous workflow receipt overwrite; choose a fresh --output path")
    receipt = {
        **read_build_info(binary, args.build_mode),
        "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "platform": sys.platform, "architecture": platform.machine(),
        "syntheticOnly": True, "liveWrites": False, "desktopUsed": False,
        "guardianTty": sys.platform == "darwin",
        "canonicalShortTempRoot": sys.platform == "darwin",
        "linuxCombinedRssGate": sys.platform == "linux" and "vault_daemon" in names,
        "suites": [{"name": name, "status": "pending"} for name in names],
        "passed": False,
    }
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    def save():
        output.write_text(json.dumps(receipt, indent=2) + "\n")
        output.chmod(0o600)

    save()
    for result in receipt["suites"]:
        name = result["name"]
        result["status"] = "running"
        save()
        print(f"RUN {name} ({args.build_mode}, {sys.platform})", flush=True)
        started = time.monotonic()
        child = subprocess.run([
            sys.executable, "-u", str(Path(__file__).resolve()),
            "--run-suite", name, "--binary", str(binary),
            "--build-mode", args.build_mode, "--output", str(suite_outputs[name]),
        ], cwd=ROOT)
        result.update(status="passed" if child.returncode == 0 else "failed",
                      exitCode=child.returncode, elapsedSeconds=round(time.monotonic() - started, 3))
        if name in RECEIPT_SUITES:
            result["receipt"] = suite_outputs[name].name
        save()
        if child.returncode != 0:
            return 1
    receipt["passed"] = True
    save()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
