#!/usr/bin/env python3
"""Owned-PTY quote folding, saved inclusion policy and exact-size review."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_mouse import click, point
from terminal_reader_editor import MouseTerminal
from terminal_compose_screen import ComposerScreen, check_compose_resize_oracle
from terminal_reader_next_ux import capture


def open_draft(binary, root, restored=False):
    terminal = MouseTerminal(binary, root, screen_type=ComposerScreen, columns=120, rows=40,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        if not restored:
            terminal.until(lambda: "Ready" in terminal.text())
            terminal.send(b"h")
            terminal.until(lambda: terminal.screen.locate("MAILBOXES") is not None)
            x, y = point(terminal, "MAILBOXES")
            click(terminal, x + 2, y + 3)  # sidebar Drafts, never the header title
        terminal.until(lambda: "Retained original policy" in terminal.text())
        terminal.gap(.5)
        terminal.send(b"\r")
        terminal.until(lambda: "[P Preview in browser]" in terminal.text()
                       and "Local draft · no mail sent" in terminal.text())
    except Exception:
        print(terminal.text(), flush=True)
        terminal.close()
        raise
    return terminal


def exercise(binary, root, captures):
    check_compose_resize_oracle()
    note = "## My exact note\n\nKeep this authored text."
    source = "\n".join(f"Retained quote line {i}" for i in range(40)) + "\nFINAL_ORIGINAL_SENTINEL"
    original = {"from": {"address": "author@example.test"}, "subject": "Synthetic prior message",
                "bodyText": source, "bodyHtml": "<p>" + source.replace("\n", "</p><p>") + "</p>"}
    with Client(binary, root) as client:
        draft = client.request("draft.create", draft={"to": [{"address": "peer@example.test"}],
                               "subject": "Retained original policy", "bodyText": note,
                               "bodyFormat": "markdown", "threadId": "quote-thread", "original": original})
    terminal = open_draft(binary, root)
    try:
        for columns, rows in ((38,24), (64,24), (90,30), (120,40), (180,50)):
            terminal.resize(columns, rows)
            terminal.until(lambda: terminal.screen.compose_geometry_ready()
                           and "[z Expand]" in terminal.screen.lines()[4] and "[Q " in terminal.screen.lines()[4])
            capture(terminal, captures, f"quoted-policy-{columns}x{rows}")
        terminal.resize(64,24)
        # p cycles the split pane when wide, but opens a full preview when
        # narrow. Wait for the actual narrow render before the single keypress.
        terminal.until(lambda: terminal.screen.compose_geometry_ready()
                           and "[z Expand]" in terminal.screen.lines()[4] and "[Q " in terminal.screen.lines()[4])
        terminal.send(b"p")
        terminal.until(lambda: "[Back]" in terminal.text() and "[z Expand]" in terminal.text())
        # Preview -> Back -> policy -> folding. Buttons also work without Q/z.
        terminal.send(b"\t\t\t\r")
        terminal.until(lambda: "Omitted" in terminal.text() and "[Q Include]" in terminal.text())
        terminal.send(b"\x1a")  # immediate policy Undo
        terminal.until(lambda: "Included" in terminal.text())
        terminal.send(b"Q")
        terminal.until(lambda: "Omitted" in terminal.text())
        terminal.send(b"P")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        previews = list(root.rglob("preview.html"))
        require(len(previews) == 1 and "FINAL_ORIGINAL_SENTINEL" not in previews[0].read_text(),
                "omitted original leaked into outgoing browser preview")
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["includeOriginal"] is False and saved["original"]["bodyText"] == source,
                    "omission lost its saved policy or exact retained original")
            require(saved["bodyText"] == note, "policy changed the authored note")
        first_exit = terminal.finish()
        with Client(binary, root) as client:
            saved_after_exit = client.request("draft.read", draftId=draft["id"])
            require(saved_after_exit["subject"] == "Retained original policy", "exit changed the saved draft subject")
    except Exception:
        print(terminal.text())
        capture(terminal, captures, "quoted-policy-failure")
        raise
    finally:
        terminal.close()
    terminal = open_draft(binary, root, restored=True)
    try:
        terminal.until(lambda: "Omitted" in terminal.text())
        require("not sent" in terminal.text(), "restarted omitted preview did not identify outgoing policy")
        terminal.send(b"Q")
        terminal.until(lambda: "Included" in terminal.text())
        terminal.send(b"P")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        require("FINAL_ORIGINAL_SENTINEL" in previews[0].read_text(),
                "restored original missing from the unfolded browser preview")
        terminal.send(b"\x13")
        terminal.until(lambda: "Review send" in terminal.text() and "bytes · exact" in terminal.text())
        require("without original" in terminal.text(), "exact review omitted the explicit size reduction choice")
        capture(terminal, captures, "quoted-policy-exact-review")
        terminal.send(b"z")
        terminal.until(lambda: "[z Fold original]" in terminal.text())
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["includeOriginal"] is True and saved["original"]["bodyText"] == source,
                    "restart and restoration failed exact source retention")
            require(saved["bodyText"] == note, "display folding changed the note")
        return {"firstExit": first_exit, **terminal.finish(), "policySurvivesRestart": True,
                "browserMatchesInclusion": True, "foldingChangesOnlyView": True, "exactSizeReview": True}
    except Exception:
        print(terminal.text())
        capture(terminal, captures, "quoted-policy-restart-failure")
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--captures", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    print(json.dumps(read_build_info(binary)), flush=True)
    with tempfile.TemporaryDirectory(prefix="omagma-quote-policy-") as directory:
        print(json.dumps(exercise(binary, Path(directory).resolve(), args.captures)), flush=True)


if __name__ == "__main__":
    main()
