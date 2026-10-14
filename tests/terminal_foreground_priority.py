#!/usr/bin/env python3
"""Explicit mail actions outrank a held, post-metadata body prefetch.

Owned PTYs and the existing synthetic provider progress gate only. Run under
the coordinator's cooperative host reservation.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile
import time
import traceback

from build_info import read_build_info
from terminal_cache import cached, metrics
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen
from terminal_scroll_progress import fixture, contains


def run(binary, directory, action):
    source = fixture(directory)
    hold = source.root / "foreground-prefetch.hold"
    entered = source.root / "foreground-prefetch.entered"
    hold.write_text("Synthetic refresh held after metadata and first body commit\n")
    path = source.path(ACCOUNTS[0])
    document = json.loads(path.read_text())
    document["sync"]["fixtureProgress"] = {
        "phase": "bodies", "completed": 1,
        "fixtureHold": hold.name, "fixtureEntered": entered.name,
    }
    path.write_text(json.dumps(document) + "\n")
    terminal = MouseTerminal(binary, directory, extra=source.options("--prefetch-bodies", "32"),
                             columns=160, rows=40, screen_type=MouseScreen,
                             environment={"TZ": "UTC", "NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: entered.is_file() and "bodies 1/32" in terminal.text())
        terminal.until(lambda: contains(terminal, 96))
        with Client(binary, directory, extra=source.options()) as client:
            before = metrics(client)
            require(before["syncBodyGets"] == 1 and before["historyId"] == "",
                    "refresh did not stop after metadata and first body commit")
            require(cached(client, "cache.refresh-status")["refreshInProgress"],
                    "held refresh did not retain its lease")
        # Navigation alone keeps speculative work alive. The uncached selected
        # body remains queued until the user explicitly opens/replies/forwards.
        terminal.send(b"jj")
        terminal.until(lambda: "Mail body queued" in terminal.text())
        with Client(binary, directory, extra=source.options()) as client:
            require(cached(client, "cache.refresh-status")["refreshInProgress"],
                    "ordinary row navigation canceled the refresh")
        began = time.monotonic()
        terminal.send({"open": b"\r", "reply": b"r", "forward": b"f"}[action])
        if action == "open":
            terminal.until(lambda: contains(terminal, 94), seconds=5)
        elif action == "reply":
            terminal.until(lambda: "Re: Scroll fixture personal 094" in terminal.text(), seconds=5)
        else:
            terminal.until(lambda: "Choose original format" in terminal.text(), seconds=5)
            terminal.send(b"t")
            terminal.until(lambda: "Fwd: Scroll fixture personal 094" in terminal.text(), seconds=5)
        require(time.monotonic() - began < 5 and hold.is_file(),
                "foreground request waited for the held provider gate")
        with Client(binary, directory, extra=source.options()) as client:
            after = metrics(client)
            require(not cached(client, "cache.refresh-status")["refreshInProgress"],
                    "foreground action did not join and release the refresh")
            require(after["syncBodyGets"] == before["syncBodyGets"] and after["historyId"] == "",
                    "cancelled refresh advanced prefetch or claimed its checkpoint")
            message = client.request("mail.read", messageId="shared-msg-094", cacheOnly=True)
            require("body 094." in message["bodyText"], "foreground target was not retained")
            require(after["fixtureSends"] == 0, "foreground read unexpectedly sent mail")
            drafts = client.request("draft.list")["drafts"]
            require(len(drafts) == int(action != "open"), "foreground request duplicated or lost its draft")
        if action != "open":
            terminal.send(b"\x03")  # Idle compose saves and returns on Ctrl+C.
            terminal.until(lambda: terminal.screen.locate("Mail ·") is not None)
        terminal.finish()
        return {"target": "shared-msg-094", "prefetchBodies": 1,
                "refreshJoined": True, "gateStillHeld": True, "drafts": int(action != "open")}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        hold.unlink(missing_ok=True)
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    try:
        for action in ("open", "reply", "forward"):
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-foreground-priority-") as temporary:
                    result = run(binary, Path(temporary), action)
                receipt["cases"].append({"action": action, "passed": True, **result})
                print("PASS foreground priority:", action, flush=True)
            except Exception:
                receipt["cases"].append({"action": action, "passed": False, "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
