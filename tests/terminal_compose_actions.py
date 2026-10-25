#!/usr/bin/env python3
"""Visible composer actions in an owned PTY, fictional mail and mock browser only."""
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
    body = "## Visible preview\n\nComplete fictional body.\nLast line."
    with Client(binary, root) as client:
        draft = client.request("draft.create", draft={
            "to": [{"address": "reader@example.test"}], "subject": "Visible composer actions",
            "bodyText": body, "bodyFormat": "markdown"})
    terminal = MouseTerminal(binary, root, screen_type=ReaderScreen, columns=120, rows=40,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: "Ready" in terminal.text())
        terminal.send(b"h")
        terminal.until(lambda: terminal.screen.locate("Drafts") is not None)
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Visible composer actions" in terminal.text())
        terminal.gap(.5)  # Drain initial mailbox/label jobs before opening the draft.
        terminal.send(b"\r")
        terminal.until(lambda: "[P Preview in browser]" in terminal.text()
                       and "Local draft · no mail sent" in terminal.text())
        sizes = ((38, 24), (64, 24), (90, 30), (120, 40), (180, 50))
        for columns, rows in sizes:
            terminal.resize(columns, rows)
            terminal.until(lambda: "[P Preview in browser]" in terminal.text()
                           and "[g Continue in Gmail]" in terminal.text())
            capture(terminal, captures, f"compose-actions-{columns}x{rows}")
        terminal.resize(64, 24)
        terminal.until(lambda: "[P Preview in browser]" in terminal.text())
        terminal.send(b"p")
        terminal.until(lambda: "[Back]" in terminal.text())
        require("[P Preview in browser]" in terminal.text()
                and "[g Continue in Gmail]" in terminal.text(), "full preview hid native actions")
        capture(terminal, captures, "compose-actions-full-preview")
        # Preview scroll -> inline toggle -> Back -> browser: Enter opens only
        # a local HTML preview through the fixture browser implementation.
        terminal.send(b"\t\t\t\r")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        previews = list(root.rglob("preview.html"))
        require(len(previews) == 1 and "Last line." in previews[0].read_text(),
                "keyboard browser button did not retain the complete body")
        terminal.send(b"q")
        terminal.until(lambda: "Subject:" in terminal.text())
        # INSERT must keep shortcut letters as authored text, with stable-width
        # labels that do not advertise currently inactive letter shortcuts.
        body_x, body_y = point(terminal, "Body:")
        click(terminal, body_x, body_y + 1)
        terminal.send(b"Pg")
        terminal.until(lambda: "[  Preview in browser]" in terminal.text())
        require("[  Continue in Gmail]" in terminal.text(), "INSERT advertised an active g shortcut")
        terminal.send(b"\x1b")
        terminal.gap(.1)
        click(terminal, *point(terminal, "To:"))
        terminal.send(b"\x05" + b"\x7f" * len("reader@example.test") + b"unfinished recipient <")
        terminal.until(lambda: "unfinished recipient <" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.1)
        preview_stamp = previews[0].stat().st_mtime_ns
        terminal.send(b"P")
        terminal.until(lambda: previews[0].stat().st_mtime_ns != preview_stamp
                       and "Mock browser target validated" in terminal.text())
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["recoveryFields"][0] == "unfinished recipient <",
                    "browser preview lost unfinished address text")
            require(saved["recoveryFields"][4] == body + "Pg", "INSERT shortcut letters changed the body")
            require(client.request("draft.gmail-info", draftId=draft["id"]).get("link") is None,
                    "preview unexpectedly uploaded a Gmail draft")
        # Complete the recipient, then exercise the mouse Gmail action. The
        # dialog itself is local review; only its explicit Upload row writes.
        click(terminal, *point(terminal, "To:"))
        terminal.send(b"\x05" + b"\x7f" * len("unfinished recipient <") + b"reader@example.test\x1b")
        terminal.gap(.1)
        click(terminal, *point(terminal, "[g Continue in Gmail]"))
        terminal.until(lambda: "Upload once" in terminal.text())
        with Client(binary, root) as client:
            require(client.request("draft.gmail-info", draftId=draft["id"]).get("link") is None,
                    "opening Gmail review performed an upload")
        terminal.send(b"\x1b")
        terminal.until(lambda: "[g Continue in Gmail]" in terminal.text())
        terminal.send(b"g")
        terminal.until(lambda: "Upload once" in terminal.text())
        terminal.send(b"j\r")
        terminal.until(lambda: "Draft is available in Gmail" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "[g Gmail status]" in terminal.text())
        terminal.resize(120, 40)
        terminal.until(lambda: "[g Gmail status]" in terminal.text())
        terminal.send(b"P")
        terminal.until(lambda: "Gmail may be newer" in terminal.text())
        capture(terminal, captures, "compose-actions-paused-local-preview")
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["gmailLink"]["paused"] and saved["bodyText"] == body + "Pg",
                    "paused browser preview changed local ownership or content")
        return {**terminal.finish(), "sizes": sizes, "nativeActionsVisible": True,
                "unfinishedRecipientsPreserved": True, "insertLettersAreText": True,
                "gmailRequiresExplicitUpload": True, "pausedPreviewIsSavedLocalCopy": True}
    except Exception:
        print(terminal.text())
        capture(terminal, captures, "compose-actions-failure")
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
    with tempfile.TemporaryDirectory(prefix="omagma-compose-actions-") as directory:
        print(json.dumps(exercise(binary, Path(directory).resolve(), args.captures)), flush=True)


if __name__ == "__main__":
    main()
