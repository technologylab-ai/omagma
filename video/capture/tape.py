"""Record a real TUI session as a 'tape' of screen states for the film.

A tape is the sequence of actual PTY screens the published executable drew:
cell text, SGR colors/attributes and the terminal cursor, each stamped with the
capture clock. Like a terminal with synchronized output, it keeps only
completed update batches, never a half-drawn screen. Marks record what the harness sent (keys, clicks) and when.
The timeline only re-times these states to the music; it never edits cells.
"""
from __future__ import annotations

import getpass
import hashlib
import json
from pathlib import Path
import re
import socket
import sys
import termios
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))

from terminal_html_screen import HtmlScreen  # noqa: E402
from terminal_integration import ACCOUNTS, Client, require  # noqa: E402
from terminal_pty import Terminal  # noqa: E402
from terminal_publication import DEFAULT_BG, DEFAULT_FG, color  # noqa: E402

BOLD, ITALIC, UNDERLINE, STRIKE = 1, 2, 4, 8
MOUSE_MODES = {1000, 1002, 1003, 1006}


class TapeScreen(HtmlScreen):
    """HtmlScreen plus the cursor visibility/shape and mouse-mode state."""

    def __init__(self, columns=100, rows=24):
        super().__init__(columns, rows)
        self.cursor_visible = True
        self.cursor_shape = 0
        self.mouse = set()
        self.synchronized = False  # inside a ?2026h … ?2026l update batch

    def csi(self, sequence, final):
        if final in ("h", "l") and sequence.startswith("?"):
            try:
                values = [int(v) for v in sequence[1:].split(";") if v]
            except ValueError:
                values = []
            for value in values:
                if value == 25:
                    self.cursor_visible = final == "h"
                elif value == 2026:
                    self.synchronized = final == "h"
                elif value in MOUSE_MODES:
                    (self.mouse.add if final == "h" else self.mouse.discard)(value)
        elif final == "q" and sequence.endswith(" "):
            try:
                self.cursor_shape = int(sequence[:-1] or 0)
            except ValueError:
                pass
            return
        super().csi(sequence, final)


class Recorder(Terminal):
    """An owned-PTY Terminal that appends a frame whenever the screen changes."""

    def __init__(self, binary, directory, name, extra=(), columns=132, rows=36, environment=None):
        env = {"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0"}
        env.update(environment or {})
        super().__init__(binary, directory, extra=extra, screen_type=TapeScreen, columns=columns, rows=rows, environment=env)
        self.name = name
        self.t0 = time.monotonic()
        self.frames, self.marks = [], []
        self.styles, self.style_index = [], {}
        self.last_rows, self.last_signature = None, None

    # -- recording ---------------------------------------------------------
    def now(self):
        return round(time.monotonic() - self.t0, 4)

    def pump(self, seconds=.05):
        super().pump(seconds)
        self.record()

    def style(self, raw):
        fg, bg, bold, italic, underline, strike = (*raw, False, False, False)[:6]
        key = (color(fg, DEFAULT_FG), None if bg is None else color(bg, DEFAULT_BG),
               (BOLD if bold else 0) | (ITALIC if italic else 0) | (UNDERLINE if underline else 0) | (STRIKE if strike else 0))
        if key not in self.style_index:
            self.style_index[key] = len(self.styles)
            self.styles.append(list(key))
        return self.style_index[key]

    def row_runs(self, y):
        """[column, text, style, cells] runs; wide glyphs get their own two-cell run."""
        cells, styles = self.screen.cells[y], self.screen.styles[y]
        runs, x = [], 0
        while x < self.columns:
            text = cells[x]
            if text == "":
                x += 1
                continue
            width = 2 if x + 1 < self.columns and cells[x + 1] == "" else 1
            index = self.style(styles[x])
            simple = width == 1 and len(text) == 1
            last = runs[-1] if runs else None
            if simple and last and last[4] and last[2] == index and last[0] + last[3] == x:
                last[1] += text
                last[3] += 1
            else:
                runs.append([x, text, index, width, simple])
            x += width
        # Blank runs without a background or line decoration paint nothing.
        return [run[:4] for run in runs
                if run[1].strip() or self.styles[run[2]][1] is not None or self.styles[run[2]][2] & (UNDERLINE | STRIKE)]

    def record(self):
        # A terminal shows a synchronized update atomically; never keep a half-drawn batch.
        if self.screen.synchronized:
            return
        rows = [self.row_runs(y) for y in range(self.rows)]
        cursor = [self.screen.x, self.screen.y, self.screen.cursor_shape] if self.screen.cursor_visible else None
        signature = hashlib.sha1(json.dumps([rows, cursor], ensure_ascii=False).encode()).digest()
        if signature == self.last_signature:
            return
        delta = rows if self.last_rows is None else [row if row != old else None for row, old in zip(rows, self.last_rows)]
        self.frames.append({"t": self.now(), "rows": delta, "cursor": cursor})
        self.last_rows, self.last_signature = rows, signature

    def mark(self, name, **info):
        self.record()
        self.marks.append({"name": name, "t": self.now(), "frame": len(self.frames) - 1, **info})

    # -- driving -----------------------------------------------------------
    def press(self, keys, name=None, show=True, settle=0):
        """Send keys (bytes or str) and mark them; `show` lets the film draw keycaps."""
        data = keys.encode() if isinstance(keys, str) else keys
        self.mark(name or f"key:{data.decode(errors='replace')}", keys=data.decode(errors="replace"), show=show)
        self.send(data)
        if settle:
            self.gap(settle)

    def type(self, text, name, delay=.035):
        """Type text one character at a time, so each keystroke is its own state."""
        self.mark(name, typed=text)
        for char in text:
            self.send(char.encode())
            self.gap(delay)
        self.mark(name + ":done")

    def click(self, column, row, name):
        self.mark(name, click=[column, row])
        self.send(f"\x1b[<0;{column + 1};{row + 1}M".encode())
        self.send(f"\x1b[<0;{column + 1};{row + 1}m".encode())

    def wheel(self, column, row, name, down=True):
        self.mark(name, wheel=[column, row, "down" if down else "up"])
        self.send(f"\x1b[<{65 if down else 64};{column + 1};{row + 1}M".encode())

    def wait(self, predicate, seconds=10, name=None):
        try:
            self.until(lambda: not self.screen.synchronized and predicate(), seconds)
        except AssertionError:
            print(f"--- {self.name}: timed out waiting for {name or 'condition'}; current screen:\n{self.text()}", file=sys.stderr)
            raise
        if name:
            self.mark(name)

    def line(self, index):
        return self.screen.lines()[index]

    def locate(self, text):
        found = self.screen.locate(text)
        require(found is not None, f"{self.name}: {text!r} is not on screen")
        return found["column"], found["row"]

    def finish(self, expected_sends=0, client_extra=()):
        """Leave the TUI with Esc/q, check a clean exit and restored termios, and count
        fixture sends against this take's own fixture root, across all accounts."""
        deadline, next_back, backs = time.monotonic() + 5, 0, 0
        while self.process.poll() is None and time.monotonic() < deadline:
            if time.monotonic() >= next_back and backs < 5:
                self.send(b"\x1b")
                self.gap()
                if self.process.poll() is None:
                    self.send(b"q")
                backs += 1
                next_back = time.monotonic() + .4
            self.pump()
        require(self.process.poll() is not None, f"{self.name}: TUI did not exit within 5 s")
        require(self.process.returncode == 0, f"{self.name}: TUI exited with {self.process.returncode}")
        require(termios.tcgetattr(self.slave) == self.settings, f"{self.name}: TUI did not restore terminal settings")
        require(not self.injection_sentinel.exists(), f"{self.name}: EDITOR argv was evaluated by a shell")
        with Client(self.binary, self.directory, extra=client_extra) as client:
            sends = sum(client.request("cache.stats", account)["fixtureSends"] for account in ACCOUNTS)
        require(sends == expected_sends, f"{self.name}: {sends} fixture sends, expected exactly {expected_sends}")
        return {"exitCode": 0, "termiosRestored": True, "observedFixtureSends": sends}

    # -- output ------------------------------------------------------------
    def tape(self, binary_info):
        return {"tape": self.name, "columns": self.columns, "rows": self.rows,
                "defaults": {"fg": DEFAULT_FG, "bg": DEFAULT_BG}, "styles": self.styles,
                "frames": self.frames, "marks": self.marks, "binary": binary_info,
                "environment": "omagma tui --fixtures, owned PTY, TERM=xterm-256color, COLORTERM=truecolor, TZ=UTC0, built-in palette"}


EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
ALLOWED_DOMAINS = re.compile(r"(^|\.)example\.(com|org|net)$")


def truncated_example(domain, following):
    """A pane may cut an address short ("holds@library.exam…"); accept only a visible
    prefix of an example.com/.org/.net domain that is followed by the ellipsis."""
    if following != "…":
        return False
    labels = domain.split(".")
    if "example".startswith(labels[-1]):
        return True
    return len(labels) >= 2 and labels[-2] == "example" and any(tld.startswith(labels[-1]) for tld in ("com", "org", "net"))


def privacy_scan(texts, extra_forbidden=(), known=()):
    """Refuse output that shows anything other than fictional example identities.

    `known` lists the fixture's fictional addresses; a pane may truncate or wrap
    one, so a visible prefix of a known address is accepted too."""
    forbidden = {str(Path.home()), getpass.getuser(), socket.gethostname(), *extra_forbidden}
    forbidden = {value for value in forbidden if value and len(value) >= 3}
    for text in texts:
        for match in EMAIL.finditer(text):
            domain = match.group(1).lower()
            visible = match.group(0).lower()
            if ALLOWED_DOMAINS.search(domain) or truncated_example(domain, text[match.end():match.end() + 1]) \
                    or any(address.startswith(visible) for address in known):
                continue
            require(False, f"non-fictional address in capture: {match.group(0)!r}")
        for value in forbidden:
            require(value not in text, "capture contains a local identity or path")


def tape_texts(tape):
    rows = [[] for _ in range(tape["rows"])]
    for frame in tape["frames"]:
        for y, runs in enumerate(frame["rows"]):
            if runs is not None:
                rows[y] = runs
                yield "".join(run[1] for run in runs)


def save(path, tape, known=()):
    privacy_scan(tape_texts(tape), known=known)
    Path(path).write_text(json.dumps(tape, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"tape {tape['tape']}: {len(tape['frames'])} frames, {len(tape['marks'])} marks, "
          f"{tape['frames'][-1]['t'] if tape['frames'] else 0:.1f} s -> {Path(path).name}")
