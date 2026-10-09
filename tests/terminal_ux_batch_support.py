"""Shared owned-fixture helpers for the ten-item UX acceptance batch.

These helpers read only checked-in fictional fixtures and task-owned directories.
They do not connect a desktop, network service or configured user account.
Run runtime cases only in a coordinator-granted cooperative host window.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile

from terminal_file_dialog import capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen

TAB = b"\t"
BACKTAB = b"\x1b[Z"
ENTER = b"\r"
ESC = b"\x1b"
SELECTED = ("rgb", 57, 43, 48)


class FocusScreen(MouseScreen):
    """Track actual current reverse-video cells independently of color.

    The shared HTML oracle has six style fields and deliberately omits reverse.
    Keep this seventh attribute separate so NO_COLOR focus is observable.
    """
    def __init__(self, columns=100, rows=24):
        self.reverse = False
        self.main_reverse = None
        super().__init__(columns, rows)
        self.reverse_cells = [[False] * columns for _ in range(rows)]

    def clear(self):
        super().clear()
        self.reverse_cells = [[False] * self.columns for _ in range(self.rows)]

    def sgr(self, sequence):
        super().sgr(sequence)
        try:
            values = [int(value) for value in sequence.replace(":", ";").split(";") if value] if sequence else [0]
        except ValueError:
            return
        index = 0
        while index < len(values):
            value = values[index]
            index += 1
            if value in (38, 48, 58) and index < len(values):
                mode = values[index]
                index += 1 + (3 if mode == 2 else 1 if mode == 5 else 0)
            elif value in (0, 27):
                self.reverse = False
            elif value == 7:
                self.reverse = True

    def draw(self, char):
        previous = self.anchor
        super().draw(char)
        if self.anchor is None:
            return
        y, x = self.anchor
        if self.anchor != previous or self.cells[y][x] == char:
            self.reverse_cells[y][x] = self.reverse
            if x + 1 < self.columns and self.cells[y][x + 1] == "":
                self.reverse_cells[y][x + 1] = self.reverse

    def linefeed(self):
        if self.y == self.bottom:
            del self.reverse_cells[self.top]
            self.reverse_cells.insert(self.bottom, [False] * self.columns)
        super().linefeed()

    def reverse_index(self):
        if self.y == self.top:
            del self.reverse_cells[self.bottom]
            self.reverse_cells.insert(self.top, [False] * self.columns)
        super().reverse_index()

    def resized(self, columns, rows):
        self.reverse_cells = [(self.reverse_cells[y][:columns] + [False] * max(0, columns - len(self.reverse_cells[y])))
                              if y < len(self.reverse_cells) else [False] * columns for y in range(rows)]
        super().resized(columns, rows)

    def csi(self, sequence, final):
        private = sequence.startswith("?")
        alternate = private and any(value in sequence[1:].split(";") for value in ("47", "1047", "1049"))
        restore = alternate and final == "l" and self.main is not None
        if alternate and final == "h" and self.main is None:
            self.main_reverse = self.reverse_cells
        saved = self.main_reverse if restore else None
        super().csi(sequence, final)
        if saved is not None:
            self.reverse_cells, self.main_reverse = saved, None


def command(terminal, value):
    terminal.send(b":" + value.encode() + ENTER)


def wait_ux_dialog(terminal, title, primary, *content, cancel="[Back]", filtered=True):
    """Observe a chooser's contents, controls and final hint across PTY reads."""
    footer = "Type filter" if filtered else "Tab Controls"
    expected = (title, primary, cancel, footer, *content)
    terminal.until(lambda: all(value in terminal.text() for value in expected))


def wait_send_review(terminal):
    terminal.until(lambda: "Review send" in terminal.text()
                   and "[Back]" in terminal.text() and "[y Send]" in terminal.text()
                   and "Tab Controls · Enter Activate · j/k Scroll · Esc/q Back" in terminal.text())


def focused(terminal, label):
    position = terminal.screen.locate(label)
    if position is None:
        return False
    y, x = position["row"], position["column"]
    return (terminal.screen.styles[y][x][1] == SELECTED
            or terminal.screen.reverse_cells[y][x])


def focus_button(terminal, label, backwards=False, limit=32):
    # Observe each focus transition, retaining the selected list row. No mouse
    # or application internals are used to reach any action.
    for _ in range(limit):
        if focused(terminal, label):
            return
        terminal.send(BACKTAB if backwards else TAB)
        terminal.gap(.04)
    require(False, f"action is not reachable with Tab/Shift+Tab: {label}")


def activate_button(terminal, label, backwards=False):
    focus_button(terminal, label, backwards)
    # This is a deliberate activation after reviewing the focused control,
    # separate from held-key/repeat guards at a newly opened write surface.
    terminal.gap(.26)
    terminal.send(ENTER)


def stats(binary, directory, extra=()):
    with Client(binary, directory, extra=extra) as client:
        return client.request("cache.stats")


def no_writes(binary, directory, extra=()):
    with Client(binary, directory, extra=extra) as client:
        require(client.request("cache.stats")["fixtureSends"] == 0, "a browse/edit/cancel interaction sent mail")
        require(client.request("operation.list")["operations"] == [], "a browse/edit/cancel interaction dispatched a provider write")


def read_mail(binary, directory, extra, identifier="shared-msg-096"):
    with Client(binary, directory, extra=extra) as client:
        return client.request("mail.read", messageId=identifier, cacheOnly=True)


def read_draft(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        rows = client.request("draft.list")["drafts"]
        require(len(rows) == 1, "workflow did not retain exactly one local draft")
        return client.request("draft.read", draftId=rows[0]["id"])


def private_preferences(directory, send_grace=None):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    value = {"schema": 1, "theme": "omagma"}
    if send_grace is not None:
        value["sendGraceSeconds"] = send_grace
    file = directory / "fixture-ui.json"
    file.write_text(json.dumps(value) + "\n")
    file.chmod(0o600)
    return ("--ui-file", str(file))


def start(binary, directory, extra, opening, columns=160, rows=40,
          send_grace=None, mono=False):
    settings = private_preferences(directory, send_grace)
    terminal = MouseTerminal(binary, directory, extra=(*extra, *settings),
                             columns=columns, rows=rows, screen_type=FocusScreen,
                             environment={"NO_COLOR": "1" if mono else None,
                                          "COLORTERM": "truecolor"})
    terminal.until(lambda: opening in terminal.text())
    return terminal


def compose(terminal, recipient="recipient@example.test", subject="UX batch fixture", body="Fixture note."):
    terminal.send(b"c")
    terminal.until(lambda: "Subject:" in terminal.text() and "Attachments 0" in terminal.text())
    terminal.send(b"i" + recipient.encode() + TAB * 3 + subject.encode() + TAB + body.encode())
    terminal.send(ESC)
    terminal.gap(.08)
    terminal.until(lambda: subject in terminal.text() and body in terminal.text())


def run_cases(binary, cases, selected=None, capture_dir=None):
    with tempfile.TemporaryDirectory(prefix="omagma-ux-batch-") as temporary:
        for name, case in cases:
            if selected and name not in selected:
                continue
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            case(binary.resolve(), directory, capture_dir)
            print(f"PASS UX batch: {name}", flush=True)


def diagnose(terminal):
    # Every current cell belongs to a synthetic fixture. Keep the terminal
    # context available on failure without historical VT dumps.
    print(terminal.text(), file=sys.stderr)
    destination = os.environ.get("OMAGMA_UX_VT_DIR")
    if destination:
        directory = Path(destination)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        receipt = directory / "failure.vt.json"
        receipt.write_text(json.dumps({"synthetic": True, "escapedOutput": bytes(terminal.output).decode("utf-8", errors="replace"),
                                       "currentCells": terminal.text().splitlines()}, ensure_ascii=True, indent=2) + "\n")
        receipt.chmod(0o600)
