"""Current-size composer geometry for owned native PTY interaction tests."""
from terminal_integration import require
from terminal_reader_editor import ReaderScreen


PREVIEW_TITLES = ("Outgoing preview", "Draft preview", "Original message", "Plain-text alternative")


class ComposerScreen(ReaderScreen):
    """Reject queued old-size output before a width-dependent composer action."""
    def __init__(self, columns=120, rows=40):
        super().__init__(columns, rows)
        self.frame_in_bounds = False
        self.complete_frame_in_bounds = False

    def resized(self, columns, rows):
        # RepaintTerminal preserves cells and this object across SIGWINCH.
        # Old readiness must not survive even a resize back to the same size.
        super().resized(columns, rows)
        self.frame_in_bounds = False
        self.complete_frame_in_bounds = False

    def csi(self, sequence, final):
        modes = sequence[1:].split(";") if sequence.startswith("?") else []
        synchronized = "2026" in modes and final in {"h", "l"}
        if synchronized and final == "h":
            self.frame_in_bounds = True
        if self.frame_open and final in {"H", "f", "G", "d"}:
            # Check addresses before the underlying model clamps them.
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

    def compose_geometry_ready(self, *, gmail_status=False):
        """Full composer (not Review/full preview), with native meter/actions."""
        if self.frame_open or not self.complete_frame_in_bounds:
            return False
        if not (38 <= self.columns <= 240 and 22 <= self.rows <= 80):
            return False
        lines = self.lines()
        browser_labels = ("[P Preview in browser]", "[  Preview in browser]")
        gmail_labels = (("[g Gmail status]", "[  Gmail status]") if gmail_status
                        else ("[g Continue in Gmail]", "[  Continue in Gmail]"))
        action_rows = 2 if self.columns < len(browser_labels[0]) + 2 + len(gmail_labels[0]) else 1
        bottom = self.rows - action_rows - 4
        split = self.columns >= 90
        left_width = self.columns * 3 // 5 if split else self.columns
        panes = ((0, left_width - 1), (left_width, self.columns - 1)) if split else ((0, self.columns - 1),)
        for left, right in panes:
            if (self.cells[2][left] != "╭" or self.cells[2][right] != "╮"
                    or self.cells[bottom][left] != "╰" or self.cells[bottom][right] != "╯"):
                return False
        gmail_row = bottom + 2 + (action_rows - 1)
        gmail_column = 0 if action_rows == 2 else len(browser_labels[0]) + 2
        footers = (("Paused in Gmail", "Tab/Shift+Tab Buttons") if gmail_status
                   else (("INSERT",) if lines[bottom + 2].startswith(browser_labels[1]) else ("Ctrl+S Review",)))
        return ("Compose ·" in lines[2][:left_width]
                and (not gmail_status or "paused in Gmail" in lines[2][:left_width])
                and self.locate("[f Alias]") == {"row": 3, "column": left_width - 11}
                and (not split or any(title in lines[2][left_width:] for title in PREVIEW_TITLES))
                and lines[bottom + 1].startswith(("MIME:", "Message size"))
                and lines[bottom + 2].startswith(browser_labels)
                and lines[gmail_row][gmail_column:].startswith(gmail_labels)
                and any(footer in lines[-2] for footer in footers))


def check_compose_resize_oracle():
    # Literal controls from the real64x24 frame. Its old caption-only
    # predicates also accept it on an enlarged180x50 physical model.
    frame = ("\x1b[?2026h\x1b[3;1H╭─ Compose · Reply\x1b[3;64H╮"
             "\x1b[4;54H[f Alias]\x1b[5;3HIncluded [Q Omit]  [z Expand]"
             "\x1b[20;1H╰\x1b[20;64H╯\x1b[21;1HMIME: 0.1 / 35.0 MiB"
             "\x1b[22;1H[P Preview in browser]  [g Continue in Gmail]"
             "\x1b[23;1H e Editor  A Files  Ctrl+S Review  q Back"
             "\x1b[?2026l").encode()
    current = ComposerScreen(64, 24)
    current.feed(frame)
    require(current.compose_geometry_ready(), "current complete composer geometry was rejected")
    old = ComposerScreen(180, 50)
    old.feed(frame)
    require("[z Expand]" in old.text() and "[P Preview in browser]" in old.text() and not old.frame_open,
            "negative control no longer exercises the old caption-only predicates")
    require(not old.compose_geometry_ready(), "old complete geometry acknowledged a resize")
    for incomplete in (frame[:-len(b"\x1b[?2026l")], frame[len(b"\x1b[?2026h"):]):
        screen = ComposerScreen(64, 24)
        screen.feed(incomplete)
        require(not screen.compose_geometry_ready(), "partial render acknowledged a resize")
    current.feed("\x1b[?2026h\x1b[3;180H╮\x1b[?2026l".encode())
    require(current.cells[2][63] == "╮" and not current.compose_geometry_ready(),
            "clamped old-wide cursor address acknowledged a resize")
    current.feed(frame)
    require(current.compose_geometry_ready(), "fresh geometry did not recover after a stale frame")
    current.resized(64, 24)
    require(not current.compose_geometry_ready(), "physical resize retained prior frame readiness")
    current.feed(frame)
    require(current.compose_geometry_ready(), "fresh frame did not acknowledge physical resize")
    for source_row in (b"", b"Included [Q Omit]  [z Fold]", b"Omitted [Q Include]"):
        screen = ComposerScreen(64, 24)
        screen.feed(frame.replace(b"Included [Q Omit]  [z Expand]", source_row))
        require(screen.compose_geometry_ready(), "composer geometry depended on original/fold policy")
    for footer in ("Paused in Gmail · g Status · q Back",
                   "Tab/Shift+Tab Buttons · Enter Activate · Esc Body · Ctrl+S Review"):
        paused = ComposerScreen(64, 24)
        paused.feed(frame.replace("Compose · Reply".encode(), "Compose · New · paused in Gmail".encode())
                    .replace(b"[g Continue in Gmail]", b"[g Gmail status]")
                    .replace(b" e Editor  A Files  Ctrl+S Review  q Back", footer.encode()))
        require(paused.compose_geometry_ready(gmail_status=True) and not paused.compose_geometry_ready(),
                "paused composer geometry lost its explicit Gmail state or focused controls")
    for title in PREVIEW_TITLES:
        wide = ComposerScreen(180, 50)
        wide.feed(("\x1b[?2026h\x1b[3;1H╭─ Compose · New message\x1b[3;108H╮"
                   f"\x1b[3;109H╭─ {title}\x1b[3;180H╮\x1b[4;98H[f Alias]"
                   "\x1b[46;1H╰\x1b[46;108H╯\x1b[46;109H╰\x1b[46;180H╯"
                   "\x1b[47;1HMIME: 0.1 / 35.0 MiB"
                   "\x1b[48;1H[P Preview in browser]  [g Continue in Gmail]"
                   "\x1b[49;1HCtrl+S Review\x1b[?2026l").encode())
        require(wide.compose_geometry_ready(), "current preview title rejected composer geometry")


if __name__ == "__main__":
    check_compose_resize_oracle()
    print("PASS composer resize geometry: current, stale, incomplete, clamped, invalidated and policy-independent")
