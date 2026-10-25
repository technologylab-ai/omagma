#!/usr/bin/env python3
"""Owned PTY: recover unsaved edits after another fixture CLI sends the source."""
import argparse
import json
from pathlib import Path
import signal
import tempfile

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_mouse import click, point
from terminal_reader_editor import MouseTerminal, ReaderScreen
from terminal_reader_next_ux import capture


def exercise(binary, root, captures):
    original_body = "EXACT_ALREADY_SAVED_SOURCE"
    extra = " + UNSAVED_NEW_NOTE_🌋"
    with Client(binary, root) as client:
        source = client.request("draft.create", draft={
            "to": [{"address": "peer@example.test"}], "subject": "Concurrent settled recovery",
            "bodyText": original_body})
    terminal = MouseTerminal(binary, root, screen_type=ReaderScreen, columns=120, rows=40,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    stopped = False
    try:
        terminal.until(lambda: "Ready" in terminal.text())
        terminal.send(b"h")
        terminal.until(lambda: terminal.screen.locate("MAILBOXES") is not None)
        x, y = point(terminal, "MAILBOXES")
        click(terminal, x + 2, y + 3)
        terminal.until(lambda: "Concurrent settled recovery" in terminal.text())
        terminal.gap(.5)
        terminal.send(b"\r")
        terminal.until(lambda: "Local draft · no mail sent" in terminal.text()
                       and "Body:" in terminal.text() and "MIME:" in terminal.text()
                       and "calculating" not in terminal.text())
        x, y = point(terminal, "Body:")
        click(terminal, x, y + 1)
        terminal.send(b"\x05" + extra.encode())
        terminal.until(lambda: "UNSAVED_NEW_NOTE_" in terminal.text())
        # Pause only this owned fixture process, after the unsaved edit is
        # visible. This deterministically lets the second client win the race.
        terminal.process.send_signal(signal.SIGSTOP)
        stopped = True
        with Client(binary, root) as client:
            before = client.request("draft.read", draftId=source["id"])
            require(before["bodyText"] == original_body and not before.get("recoveryFields"),
                    "autosave ran before the controlled concurrent-send boundary")
            sent = client.request("draft.send", draftId=source["id"],
                                  operationId="fixture-external-settled-source")
            require(sent["outcome"] == "applied", "explicit external fixture send was not confirmed")
        terminal.process.send_signal(signal.SIGCONT)
        stopped = False
        terminal.until(lambda: "Previous draft sent elsewhere; edits saved as a new draft" in terminal.text())
        require("Review send" not in terminal.text(), "recovery resumed an old send review")
        require("Body: INSERT" in terminal.text(), "background recovery left INSERT")
        terminal.send(b"qQg")  # These remain text after the asynchronous fork.
        terminal.until(lambda: "NOTE_🌋qQg" in terminal.text())
        terminal.until(lambda: "Draft saved locally" in terminal.text())
        extra += "qQg"
        capture(terminal, captures, "settled-source-recovered")
        with Client(binary, root) as client:
            active = client.request("draft.list")["drafts"]
            require(len(active) == 1 and active[0]["id"] != source["id"],
                    "recovery did not create exactly one independent active draft")
            recovered_id = active[0]["id"]
            recovered = client.request("draft.read", draftId=recovered_id)
            require(recovered["recoveryFields"][4] == original_body + extra,
                    "recovery changed or lost the unsaved authored bytes")
            retained = client.request("draft.read", draftId=source["id"])
            require(retained["bodyText"] == original_body, "recovery overwrote the sent source")
            require(client.request("cache.stats")["fixtureSends"] == 1,
                    "recovery submitted an additional message")
        result = terminal.finish(expected_sends=1)
        with Client(binary, root) as client:
            restarted = client.request("draft.read", draftId=recovered_id)
            require((restarted.get("recoveryFields") or [None] * 4 + [restarted["bodyText"]])[4]
                    == original_body + extra, "safe exit lost the recovered note")
            require(client.request("cache.stats")["fixtureSends"] == 1,
                    "safe exit submitted an additional message")
        return {**result, "externalConfirmedFixtureSends": 1, "additionalSends": 0,
                "exactUnsavedNoteRecovered": True, "sentSourceUnchanged": True,
                "recoveredDraftSurvivesExit": True, "insertPreservedAcrossFork": True,
                "qQgRemainTextAndAutosave": True}
    except Exception:
        print(terminal.text(), flush=True)
        capture(terminal, captures, "settled-source-recovery-failure")
        raise
    finally:
        if stopped and terminal.process.poll() is None:
            terminal.process.send_signal(signal.SIGCONT)
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--captures", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    print(json.dumps(read_build_info(binary)), flush=True)
    with tempfile.TemporaryDirectory(prefix="omagma-settled-recovery-") as temporary:
        print(json.dumps(exercise(binary, Path(temporary).resolve(), args.captures)), flush=True)


if __name__ == "__main__":
    main()
