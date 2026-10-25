#!/usr/bin/env python3
"""Owned-PTY active-draft paging; 128 fictional local drafts and no sends."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_mouse import click, point
from terminal_reader_editor import MouseTerminal, ReaderScreen
from terminal_reader_next_ux import capture


def exercise(binary, root, captures):
    with Client(binary, root) as client:
        ids = set()
        for index in range(128):
            draft = client.request("draft.create", draft={
                "to": [{"address": "peer@example.test"}],
                "subject": f"Paged local draft {index:03}",
                "bodyText": f"EXACT_AUTHORED_BODY_{index:03}",
                "attachments": [{"id": "tiny-file", "filename": "retained.txt", "size": 1,
                                 "mimeType": "text/plain", "data": "YQ"}]})
            ids.add(draft["id"])
        first = client.request("draft.list", limit=100)
        second = client.request("draft.list", cursor=first["nextCursor"], limit=100)
        rows = first["drafts"] + second["drafts"]
        require(len(first["drafts"]) == 100 and len(second["drafts"]) == 28,
                "128 active drafts did not produce two complete pages")
        require({row["id"] for row in rows} == ids and not second["nextCursor"],
                "draft paging skipped or duplicated saved drafts")
        require(all(row["summaryOnly"] and row["attachmentCount"] == 1
                    and "attachments" not in row and "bodyText" not in row for row in rows),
                "draft list returned heavy editable DTOs instead of navigation summaries")
        full_last = client.request("draft.read", draftId=rows[-1]["id"])
    terminal = MouseTerminal(binary, root, screen_type=ReaderScreen, columns=120, rows=40,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: "Ready" in terminal.text())
        terminal.send(b"h")
        terminal.until(lambda: terminal.screen.locate("MAILBOXES") is not None)
        x, y = point(terminal, "MAILBOXES")
        click(terminal, x + 2, y + 3)
        terminal.until(lambda: rows[0]["subject"] in terminal.text() and "1/100" in terminal.text())
        require("📎" in terminal.text(), "compact draft summary lost its attachment indicator")
        capture(terminal, captures, "drafts-first-page")
        terminal.send(b"Gj")
        terminal.until(lambda: rows[100]["subject"] in terminal.text() and "1/28" in terminal.text())
        terminal.send(b"k")
        terminal.until(lambda: rows[99]["subject"] in terminal.text() and "100/100" in terminal.text())
        terminal.send(b"]")
        terminal.until(lambda: rows[100]["subject"] in terminal.text() and "1/28" in terminal.text())
        terminal.send(b"[")
        terminal.until(lambda: rows[0]["subject"] in terminal.text() and "1/100" in terminal.text())
        terminal.send(b"]")
        terminal.until(lambda: "1/28" in terminal.text())
        terminal.send(b"G")
        terminal.until(lambda: rows[-1]["subject"] in terminal.text() and "28/28" in terminal.text())
        capture(terminal, captures, "drafts-last-page")
        terminal.send(b"\r")
        terminal.until(lambda: "Local draft · no mail sent" in terminal.text()
                       and rows[-1]["subject"] in terminal.text())
        expected = "EXACT_AUTHORED_BODY_" + rows[-1]["subject"].split()[-1]
        require(expected in terminal.text() and "retained.txt" in terminal.text(),
                "opening a compact summary did not load its exact body and file")
        terminal.send(b"q")
        terminal.until(lambda: "28/28" in terminal.text())
        terminal.send(b"gg")
        terminal.until(lambda: rows[0]["subject"] in terminal.text() and "1/100" in terminal.text())
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=rows[-1]["id"])
            require(saved["bodyText"] == expected and saved["attachments"] == full_last["attachments"],
                    "navigation or opening altered the saved draft")
        return {**terminal.finish(), "all128Listed": True, "nextPreviousAndEdges": True,
                "ggReturnsFirstPage": True, "fullDraftReadRetained": True}
    except Exception:
        print(terminal.text(), flush=True)
        capture(terminal, captures, "drafts-paging-failure")
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--captures", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    print(json.dumps(read_build_info(binary)), flush=True)
    with tempfile.TemporaryDirectory(prefix="omagma-draft-paging-") as temporary:
        print(json.dumps(exercise(binary, Path(temporary).resolve(), args.captures)), flush=True)


if __name__ == "__main__":
    main()
