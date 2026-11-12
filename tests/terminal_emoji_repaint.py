#!/usr/bin/env python3
"""Physical Mail/Calendar round trips with independently measured emoji widths.

Owned PTYs and fictional mail only. No desktop, credentials or provider writes.
"""
import argparse
import base64
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

import terminal_pty
from terminal_calendar import Invitations
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal
from terminal_reader_editor import ReaderScreen
from terminal_reader import reader_contains


class EmojiScreen(ReaderScreen):
    """VS16 widens these two narrow emoji bases in the modeled terminal.

    The application's width algorithm is never imported. CPR answers come from
    the physical cursor after parsing the actual output, not expected constants.
    """
    def __init__(self, columns=160, rows=48):
        super().__init__(columns, rows)
        self.replies = []
        self.reports = []

    def draw(self, char):
        if char == "\ufe0f" and self.anchor:
            y, x = self.anchor
            if self.cells[y][x] in ("⏱", "✈") and x + 1 < self.columns:
                self.cells[y][x] += char
                self.cells[y][x + 1] = ""
                self.styles[y][x + 1] = self.styles[y][x]
                self.x += 1
                if self.x >= self.columns:
                    self.x = self.columns - 1
                    self.pending_wrap = True
                return
        # A skin-tone modifier belongs to its preceding emoji's two cells.
        if "\U0001f3fb" <= char <= "\U0001f3ff" and self.anchor:
            y, x = self.anchor
            self.cells[y][x] += char
            return
        super().draw(char)

    def csi(self, sequence, final):
        if sequence == "6" and final == "n":
            self.reports.append((self.y, self.x))
            self.replies.append(f"\x1b[{self.y + 1};{self.x + 1}R".encode())
        elif sequence == "" and final == "c":
            # DA1 must follow the preceding CPR replies in wire order.
            self.replies.append(b"\x1b[?1;2c")
        super().csi(sequence, final)


class MeasuredTerminal(MouseTerminal):
    hold_probe = False
    deferred_probe = None

    def pump(self, seconds=.05):
        super().pump(seconds)
        replies, self.screen.replies = self.screen.replies, []
        for reply in replies:
            if self.hold_probe and reply.startswith(b"\x1b[3;"):
                self.deferred_probe = reply
            else:
                self.send(reply)


def fixture(binary, root, html=False):
    provider = Invitations(root)
    file = provider.root / "accounts/personal.json"
    source = json.loads(file.read_text())
    body = "\n".join(f"Readable body row {i}: red green blue amber violet cedar." for i in range(35)) + "\n"
    value = "<div style=\"display:none\">" + body + "</div>" if html else body
    raw = value.encode()
    message = source["messages"][0]
    message["payload"]["mimeType"] = "text/html" if html else "text/plain"
    message["payload"]["parts"] = []
    message["payload"]["body"] = {"size": len(raw), "data": base64.urlsafe_b64encode(raw).decode().rstrip("=")}
    message["payload"]["headers"] = [
        {"name": "From", "value": "Updates <updates@example.test>"},
        {"name": "To", "value": ACCOUNTS[0]},
        {"name": "Subject", "value": ""},
    ]
    source["messages"] = []
    for i in range(14):
        item = json.loads(json.dumps(message))
        item.update(id=f"emoji-redraw-{i}", threadId=f"emoji-thread-{i}", internalDate=str(1791885600000 - i * 1000))
        item["payload"]["headers"][2]["value"] = f"Fictional reminder {i} ⏱️ red green blue"
        source["messages"].append(item)
    file.write_text(json.dumps(source) + "\n")
    owned = root / "client"
    with Client(binary, owned, extra=provider.options()) as client:
        client.request("mail.list", label="INBOX")
        client.request("mail.read", messageId="emoji-redraw-0")
    preferences = owned / "config/omagma/ui.json"
    preferences.parent.mkdir(parents=True, exist_ok=True)
    preferences.write_text(json.dumps({"readerLayout": "right"}) + "\n")
    preferences.chmod(0o600)
    return provider, owned


def visible_cells(screen):
    # Both halves of an erased wide glyph are visual blanks. The independent
    # model retains an empty string for its continuation until overwritten.
    return [[cell or " " for cell in row] for row in screen.cells]


def exercise(binary, root, html=False, advertised=False, immediate=False):
    provider, owned = fixture(binary, root, html)
    queries = {k: v for k, v in terminal_pty.QUERIES.items() if k not in (b"\x1b[6n", b"\x1b[c")}
    if advertised:
        queries[b"\x1b[?2027$p"] = b"\x1b[?2027;1$y"
    with patch.dict(terminal_pty.QUERIES, queries, clear=True):
        terminal = MeasuredTerminal(binary, owned, extra=provider.options(), screen_type=EmojiScreen,
                                    columns=160, rows=48, environment={"TZ": "UTC", "TERM_PROGRAM": None,
                                    "VAXIS_FORCE_UNICODE": None, "VAXIS_FORCE_WCWIDTH": None, "VHS_RECORD": None})
        try:
            terminal.hold_probe = immediate
            terminal.until(lambda: reader_contains(terminal.screen, "Readable body row 0"))
            if immediate:
                terminal.until(lambda: terminal.deferred_probe is not None)
            else:
                terminal.gap(.15)
            for view in (b"1", b"2", b"3", b"1"):
                terminal.send(b"C")
                if terminal.deferred_probe is not None:
                    # The real key is queued before the width report, just as
                    # when the user navigates while negotiation is in flight.
                    terminal.hold_probe = False
                    terminal.send(terminal.deferred_probe)
                    terminal.deferred_probe = None
                terminal.until(lambda: "Calendar ·" in terminal.text() and "selected calendars" in terminal.text())
                terminal.send(view)
                terminal.gap(.1)
                terminal.send(b"q")
                terminal.until(lambda: reader_contains(terminal.screen, "Readable body row 0"))
                before = visible_cells(terminal.screen)
                clears = terminal.screen.full_physical_clears
                terminal.resize(159, 48)
                terminal.until(lambda: terminal.screen.full_physical_clears > clears)
                clears = terminal.screen.full_physical_clears
                terminal.resize(160, 48)
                terminal.until(lambda: terminal.screen.full_physical_clears > clears and reader_contains(terminal.screen, "Readable body row 0"))
                after = visible_cells(terminal.screen)
                changed = [(x, y) for y in range(4, 45) for x in range(160) if before[y][x] != after[y][x]]
                require(not changed, f"Mail/Calendar round trip left {len(changed)} wrong physical cells; first={changed[:6]}")
            terminal.finish()
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform == "darwin":
        from terminal_macos import DarwinTerminal
        global MeasuredTerminal
        if not issubclass(MeasuredTerminal, DarwinTerminal):
            class GuardianMeasuredTerminal(DarwinTerminal, MeasuredTerminal):
                pass
            MeasuredTerminal = GuardianMeasuredTerminal
        tempfile.tempdir = str(Path("/tmp").resolve())
    with tempfile.TemporaryDirectory(prefix="omagma-emoji-redraw-") as temporary:
        for html, advertised, immediate in ((False, False, False), (True, False, False), (False, True, False), (True, True, False), (False, False, True)):
            root = Path(temporary) / f"html-{html}-unicode-{advertised}-immediate-{immediate}"
            root.mkdir()
            exercise(args.binary.resolve(), root, html, advertised, immediate)
            print(f"PASS emoji repaint: html={html} advertisedUnicode={advertised} immediate={immediate}")


if __name__ == "__main__":
    main()
