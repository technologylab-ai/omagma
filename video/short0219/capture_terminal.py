"""Promo-only faithful terminal capture, including SGR58 underline color.

Application output stays unchanged. The extra fourth tape-style field is the
terminal's explicit underline color; absent/default values retain foreground.
"""
from __future__ import annotations

from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "video/capture"), str(ROOT / "tests")]

from tape import BOLD, ITALIC, STRIKE, UNDERLINE, Recorder, TapeScreen
from terminal_pty import Terminal
from terminal_publication import DEFAULT_BG, DEFAULT_FG, color


class CaptureScreen(TapeScreen):
    def __init__(self, columns=132, rows=36):
        super().__init__(columns, rows)
        self.style = (*self.style, None)
        self.styles = [[self.style] * columns for _ in range(rows)]
        self.completed_frames = 0

    def csi(self, sequence, final):
        was_open = self.frame_open
        super().csi(sequence, final)
        if was_open and sequence.startswith("?") and "2026" in sequence[1:].split(";") and final == "l":
            self.completed_frames += 1

    def sgr(self, sequence):
        underline_color = self.style[6]
        self.style = self.style[:6]
        try:
            values = [int(v) for v in sequence.replace(":", ";").split(";") if v] if sequence else [0]
            ordinary, index = [], 0
            while index < len(values):
                value = values[index]
                index += 1
                if value in (38, 48, 58) and index < len(values):
                    first = index - 1
                    mode = values[index]
                    count = 3 if mode == 2 else 1 if mode == 5 else 0
                    index = min(len(values), index + 1 + count)
                    chunk = values[first:index]
                    if value == 58:
                        if mode == 2 and len(chunk) == 5:
                            underline_color = ("rgb", *chunk[2:])
                        elif mode == 5 and len(chunk) == 3:
                            underline_color = ("indexed", chunk[2])
                    else:
                        ordinary.extend(chunk)
                elif value == 59:
                    underline_color = None
                else:
                    if value == 0:
                        underline_color = None
                    ordinary.append(value)
            if ordinary:
                super().sgr(";".join(map(str, ordinary)))
        finally:
            self.style = (*self.style, underline_color)


class CaptureRecorder(Recorder):
    def __init__(self, binary, directory, name, extra=(), columns=132, rows=36, environment=None):
        env = {"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0"}
        env.update(environment or {})
        Terminal.__init__(self, binary, directory, extra=extra, screen_type=CaptureScreen,
                          columns=columns, rows=rows, environment=env)
        self.name = name
        self.t0 = time.monotonic()
        self.frames, self.marks = [], []
        self.styles, self.style_index = [], {}
        self.last_rows, self.last_signature = None, None

    def style(self, raw):
        fg, bg, bold, italic, underline, strike = raw[:6]
        explicit = raw[6] if len(raw) > 6 else None
        key = (color(fg, DEFAULT_FG), None if bg is None else color(bg, DEFAULT_BG),
               (BOLD if bold else 0) | (ITALIC if italic else 0)
               | (UNDERLINE if underline else 0) | (STRIKE if strike else 0),
               None if explicit is None else color(explicit, DEFAULT_FG))
        if key not in self.style_index:
            self.style_index[key] = len(self.styles)
            self.styles.append(list(key))
        return self.style_index[key]


def self_test():
    screen = CaptureScreen(60, 4)
    screen.feed(b"\x1b[38;2;230;235;241;58;2;255;40;104;4mMeeting")
    assert screen.styles[0][0][0] == ("rgb", 230, 235, 241)
    assert screen.styles[0][0][1] is None
    assert screen.styles[0][0][4] is True
    assert screen.styles[0][0][6] == ("rgb", 255, 40, 104)
    screen.feed(b"\x1b[58:2::10:20:30m Color\x1b[59m Default\x1b[58;5;1m Index\x1b[0m Reset")
    assert screen.styles[0][8][6] == ("rgb", 10, 20, 30)
    assert screen.styles[0][14][6] is None
    assert screen.styles[0][22][6] == ("indexed", 1)
    assert screen.styles[0][28][6] is None
    recorder = object.__new__(CaptureRecorder)
    recorder.styles, recorder.style_index = [], {}
    index = recorder.style(screen.styles[0][0])
    assert recorder.styles[index] == ["#e6ebf1", None, UNDERLINE, "#ff2868"]
    print("PASS promo SGR58: RGB/colon/index/default/reset and distinct foreground/background")


if __name__ == "__main__":
    self_test()
