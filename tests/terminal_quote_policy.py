#!/usr/bin/env python3
"""Owned-PTY quote folding, saved inclusion policy and exact-size review."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_mouse import click, point
from terminal_reader_editor import MouseTerminal, ReaderScreen
from terminal_reader_next_ux import capture


class QuoteScreen(ReaderScreen):
    """Do not mistake a queued render at the old size for a resize acknowledgement."""
    def __init__(self, columns=120, rows=40):
        super().__init__(columns, rows)
        self.frame_in_bounds = False
        self.complete_frame_in_bounds = False

    def csi(self, sequence, final):
        modes = sequence[1:].split(";") if sequence.startswith("?") else []
        synchronized = "2026" in modes and final in {"h", "l"}
        if synchronized and final == "h":
            self.frame_in_bounds = True
        if self.frame_open and final in {"H", "f", "G", "d"}:
            # Screen clamps these addresses. Check them before clamping: an
            # old wide frame's right border can otherwise land at our new edge.
            values = [int(value or "1") for value in sequence.split(";")]
            row = (values[0] or 1) if final in {"H", "f", "d"} else 1
            column = ((values[1] or 1) if len(values) > 1 else 1) if final in {"H", "f"} else ((values[0] or 1) if final == "G" else 1)
            if row > self.rows or column > self.columns:
                self.frame_in_bounds = False
        if synchronized and final == "l":
            self.complete_frame_in_bounds = self.frame_open and self.frame_in_bounds
        super().csi(sequence, final)

    def linefeed(self):
        if self.frame_open and self.y == self.bottom:
            self.frame_in_bounds = False
        super().linefeed()

    def compose_geometry_ready(self):
        if self.frame_open or not self.complete_frame_in_bounds:
            return False
        lines = self.lines()
        action_rows = 2 if self.columns < len("[P Preview in browser]  [g Continue in Gmail]") else 1
        bottom = self.rows - action_rows - 4
        split = self.columns >= 90
        left_width = self.columns * 3 // 5 if split else self.columns
        panes = ((0, left_width - 1), (left_width, self.columns - 1)) if split else ((0, self.columns - 1),)
        for left, right in panes:
            if (self.cells[2][left] != "╭" or self.cells[2][right] != "╮"
                    or self.cells[bottom][left] != "╰" or self.cells[bottom][right] != "╯"):
                return False
        return (self.locate("[f Alias]") == {"row": 3, "column": left_width - 11}
                and (not split or "Outgoing preview" in lines[2][left_width:])
                and lines[bottom + 1].startswith(("MIME:", "Message size:"))
                and lines[bottom + 2].startswith("[P Preview in browser]")
                and "Ctrl+S Review" in lines[-2]
                and "[z Expand]" in lines[4] and "[Q " in lines[4])


def check_resize_oracle():
    # Literal controls and cell positions from the 64x24 composer. The same
    # complete old frame fits a newly enlarged grid and satisfied the previous
    # caption-only wait, despite never acknowledging the new terminal size.
    frame = ("\x1b[?2026h\x1b[3;1H╭\x1b[3;64H╮"
             "\x1b[4;54H[f Alias]\x1b[5;3HIncluded [Q Omit]  [z Expand]"
             "\x1b[20;1H╰\x1b[20;64H╯\x1b[21;1HMIME: 0.1 / 35.0 MiB"
             "\x1b[22;1H[P Preview in browser]  [g Continue in Gmail]"
             "\x1b[23;1H e Editor  A Files  Ctrl+S Review  q Back"
             "\x1b[?2026l").encode()
    current = QuoteScreen(64, 24)
    current.feed(frame)
    require(current.compose_geometry_ready(), "current complete geometry was rejected")
    old = QuoteScreen(180, 50)
    old.feed(frame)
    require("[z Expand]" in old.text() and "[Q " in old.text() and not old.frame_open,
            "negative control no longer exercises the old caption-only predicate")
    require(not old.compose_geometry_ready(), "old complete geometry acknowledged a resize")
    for incomplete in (frame[:-len(b"\x1b[?2026l")], frame[len(b"\x1b[?2026h"):]):
        screen = QuoteScreen(64, 24)
        screen.feed(incomplete)
        require(not screen.compose_geometry_ready(), "partial render acknowledged a resize")
    # CUP clamps 180 to64 in the base model: the right corner still looks
    # correct. Raw cursor bounds must independently reject that old-wide frame.
    current.feed("\x1b[?2026h\x1b[3;180H╮\x1b[?2026l".encode())
    require(current.cells[2][63] == "╮" and not current.compose_geometry_ready(),
            "clamped old-wide cursor address acknowledged a resize")
    current.feed(frame)
    require(current.compose_geometry_ready(), "fresh geometry did not recover after a stale frame")


def open_draft(binary, root, restored=False):
    terminal = MouseTerminal(binary, root, screen_type=QuoteScreen, columns=120, rows=40,
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
    check_resize_oracle()
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
            terminal.until(terminal.screen.compose_geometry_ready)
            capture(terminal, captures, f"quoted-policy-{columns}x{rows}")
        terminal.resize(64,24)
        # p cycles the split pane when wide, but opens a full preview when
        # narrow. Wait for the actual narrow render before the single keypress.
        terminal.until(terminal.screen.compose_geometry_ready)
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
