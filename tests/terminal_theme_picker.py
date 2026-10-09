#!/usr/bin/env python3
"""Theme choice, live preview and hot-follow in owned fictional PTYs."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile

from terminal_cache import ProviderFixture
from terminal_html import screen_capture
from terminal_integration import Client, require
from terminal_mouse import MouseTerminal, click
from terminal_mouse_screen import MouseScreen
from terminal_ui import palette, theme_path, UI_FIXTURES


ORANGE = ("rgb", 255, 158, 97)
OMAGMA_SELECTED = ("rgb", 57, 43, 48)
TAB, BACKTAB, ENTER = b"\t", b"\x1b[Z", b"\r"


class ThemeScreen(MouseScreen):
    """Track reverse per physical cell as well as ordinary SGR colors."""
    def __init__(self, columns=100, rows=24):
        self.reverse = False
        super().__init__(columns, rows)
        self.reversed = [[False] * columns for _ in range(rows)]

    def clear(self):
        super().clear()
        self.reversed = [[self.reverse] * self.columns for _ in range(self.rows)]

    def sgr(self, sequence):
        super().sgr(sequence)
        try:
            values = [int(field) for field in sequence.replace(":", ";").split(";") if field] if sequence else [0]
        except ValueError:
            return
        index = 0
        while index < len(values):
            value = values[index]
            index += 1
            if value in (38, 48, 58) and index < len(values):
                mode = values[index]
                index += 1 + (3 if mode == 2 else 1 if mode == 5 else 0)
            elif value == 0:
                self.reverse = False
            elif value == 7:
                self.reverse = True
            elif value == 27:
                self.reverse = False

    def draw(self, char):
        previous = self.anchor
        super().draw(char)
        if self.anchor is not None:
            row, column = self.anchor
            if self.anchor != previous or self.cells[row][column] == char:
                self.reversed[row][column] = self.reverse
                if column + 1 < self.columns and self.cells[row][column + 1] == "":
                    self.reversed[row][column + 1] = self.reverse

    def resized(self, columns, rows):
        old = self.reversed
        super().resized(columns, rows)
        self.reversed = [(old[row][:columns] + [False] * max(0, columns - len(old[row])))
                         if row < len(old) else [False] * columns for row in range(rows)]


def setup(binary, directory, *, theme_file=True, preferences=True):
    source = ProviderFixture(directory)
    with Client(binary, directory, extra=source.options()) as client:
        client.request("mail.refresh", limit=32, prefetchLimit=0)
        client.request("mail.read", messageId="shared-msg-096")
    source.stage("personal@example.com", "baseline", held=True)
    path = theme_path(directory)
    if theme_file:
        shutil.copyfile(UI_FIXTURES / "theme-colors.toml", path)
    prefs = directory / "config/omagma/ui.json"
    prefs.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if preferences:
        # An old schema-1 file deliberately has no theme choice. Other
        # preferences must survive adding the new optional key.
        prefs.write_text(json.dumps({"schema": 1, "readerLayout": "right", "listWidthPercent": 60,
                                     "bindings": [{"key": "n", "action": "down"}]}) + "\n")
        prefs.chmod(0o600)
    return source, path, prefs


def start(binary, directory, source, *, no_color=False, columns=160, rows=40):
    terminal = MouseTerminal(binary, directory, extra=source.options(), screen_type=ThemeScreen,
                             environment={"NO_COLOR": "1" if no_color else None, "COLORTERM": "truecolor"},
                             columns=columns, rows=rows)
    terminal.until(lambda: "Synthetic personal message 096" in terminal.text())
    source.wait_entered(terminal.process, pump=terminal.pump)
    return terminal


def opened(terminal):
    return terminal.screen.locate("[Apply]") is not None and terminal.screen.locate("[Cancel]") is not None


def header_color(terminal, expected):
    location = terminal.screen.locate("omagma · Experimental")
    return location is not None and terminal.screen.styles[location["row"]][location["column"]][0] == expected


def selected(terminal, name):
    location = terminal.screen.locate(name)
    return (location is not None and location["column"] >= 2
            and terminal.screen.cells[location["row"]][location["column"] - 2] == "›")


def focused(terminal, button, *, no_color=False, background=OMAGMA_SELECTED):
    location = terminal.screen.locate(button)
    if location is None:
        return False
    row, column = location["row"], location["column"]
    return terminal.screen.reversed[row][column] if no_color else terminal.screen.styles[row][column][1] == background


def key_focus(terminal, keys, button, **options):
    terminal.send(keys)
    terminal.until(lambda: focused(terminal, button, **options))


def capture(terminal, directory, name):
    if directory is not None:
        terminal.gap(.12)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / (name + ".json")).write_text(json.dumps(screen_capture(terminal)) + "\n")


def signature(path):
    return path.read_bytes(), path.stat().st_mtime_ns


def picker_case(binary, directory, capture_dir):
    source, _, prefs = setup(binary, directory)
    before = signature(prefs)
    desktop = palette(UI_FIXTURES / "theme-colors.toml", "accent")
    terminal = start(binary, directory, source)
    try:
        require(header_color(terminal, desktop), "old UI settings did not default to following Omarchy")
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal) and selected(terminal, "Follow Omarchy"))
        require(header_color(terminal, desktop), "opening the picker changed the palette")
        terminal.send(b"k")
        terminal.until(lambda: selected(terminal, "Omagma") and header_color(terminal, ORANGE))
        capture(terminal, capture_dir, "omagma-preview")
        key_focus(terminal, TAB, "[Apply]")
        key_focus(terminal, TAB, "[Cancel]")
        key_focus(terminal, BACKTAB, "[Apply]")
        terminal.send(b"\x1b")
        terminal.until(lambda: not opened(terminal) and header_color(terminal, desktop))
        require(signature(prefs) == before, "Escape wrote preview preferences")
        terminal.send(b":theme\r")
        terminal.until(lambda: opened(terminal))
        terminal.send(b"k")
        terminal.until(lambda: header_color(terminal, ORANGE))
        key_focus(terminal, BACKTAB, "[Cancel]")
        terminal.send(ENTER)
        terminal.until(lambda: not opened(terminal) and header_color(terminal, desktop))
        require(signature(prefs) == before, "Cancel wrote preview preferences")
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal))
        terminal.send(b"k")
        key_focus(terminal, TAB, "[Apply]")
        terminal.send(ENTER)
        terminal.until(lambda: not opened(terminal) and prefs.exists()
                       and json.loads(prefs.read_text()).get("theme") == "omagma")
        saved = json.loads(prefs.read_text())
        require(saved["readerLayout"] == "right" and saved["listWidthPercent"] == 60
                and saved["bindings"] == [{"key": "n", "action": "down"}], "saving theme discarded existing UI preferences")
        require(stat.S_IMODE(prefs.stat().st_mode) == 0o600, "theme preference is not private 0600")
        require(header_color(terminal, ORANGE), "Apply lost the previewed orange palette")
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    source.stage("personal@example.com", "baseline", held=True)
    terminal = start(binary, directory, source)
    try:
        require(header_color(terminal, ORANGE), "saved Omagma theme did not restore after restart")
        terminal.send(b"\x0c")
        terminal.gap(.12)
        require(header_color(terminal, ORANGE), "Ctrl+L ignored the saved fixed theme")
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal) and selected(terminal, "Omagma"))
        before = signature(prefs)
        terminal.send(ENTER)
        terminal.until(lambda: not opened(terminal))
        require(signature(prefs) == before, "applying the unchanged theme rewrote preferences")
        terminal.finish()
    finally:
        terminal.close()
    print("PASS themes: old-settings default, live preview, Tab/reverse, Escape/Cancel, Apply, private persistence, restart, Ctrl+L")


def follow_case(binary, directory, capture_dir):
    source, path, prefs = setup(binary, directory, theme_file=False, preferences=False)
    terminal = start(binary, directory, source)
    try:
        require(header_color(terminal, ORANGE), "missing Omarchy theme did not use the built-in palette")
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal) and "No theme · using Omagma" in terminal.text())
        capture(terminal, capture_dir, "theme-fallback")
        require(not prefs.exists(), "opening a fallback picker created preferences")
        terminal.resize(30, 20)
        terminal.until(lambda: opened(terminal))
        require(terminal.screen.locate("[Apply]") is not None and terminal.screen.locate("[Cancel]") is not None,
                "minimum-width theme action clipped")
        key_focus(terminal, TAB, "[Apply]")
        key_focus(terminal, TAB, "[Cancel]")
        terminal.send(ENTER)
        terminal.until(lambda: not opened(terminal))
        terminal.resize(48, 20)
        clears = terminal.screen.full_physical_clears
        terminal.until(lambda: terminal.screen.full_physical_clears > clears and "Mail ·" in terminal.text()
                       and "j/k Mail  f Forward  m Labels  T Theme  ? Help" in terminal.screen.lines()[-2])
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal))
        omagma = terminal.screen.locate("Omagma")
        click(terminal, omagma["column"], omagma["row"])
        terminal.until(lambda: selected(terminal, "Omagma"))
        cancel = terminal.screen.locate("[Cancel]")
        click(terminal, cancel["column"], cancel["row"])
        terminal.until(lambda: not opened(terminal))
        require(not prefs.exists(), "mouse Cancel saved the preview")
        terminal.resize(160, 40)
        terminal.until(lambda: header_color(terminal, ORANGE))
        # The same TUI remains unattended. Its existing finite cache task
        # wakes bounded metadata checks; no Ctrl+L or keyboard input is used.
        shutil.copyfile(UI_FIXTURES / "theme-colors.toml", path)
        expected = palette(UI_FIXTURES / "theme-colors.toml", "accent")
        terminal.until(lambda: header_color(terminal, expected), seconds=7)
        shutil.copyfile(UI_FIXTURES / "theme-colors-reloaded.toml", path)
        expected = palette(UI_FIXTURES / "theme-colors-reloaded.toml", "accent")
        terminal.until(lambda: header_color(terminal, expected), seconds=7)
        path.unlink()
        terminal.until(lambda: header_color(terminal, ORANGE), seconds=7)
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal))
        terminal.send(b"k")
        apply = terminal.screen.locate("[Apply]")
        click(terminal, apply["column"], apply["row"])
        terminal.until(lambda: not opened(terminal) and prefs.exists()
                       and json.loads(prefs.read_text()).get("theme") == "omagma")
        shutil.copyfile(UI_FIXTURES / "theme-colors.toml", path)
        terminal.gap(3.1)
        require(header_color(terminal, ORANGE), "a fixed Omagma choice followed desktop changes")
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal))
        follow = terminal.screen.locate("Follow Omarchy")
        click(terminal, follow["column"], follow["row"])
        terminal.until(lambda: selected(terminal, "Follow Omarchy") and header_color(terminal, palette(UI_FIXTURES / "theme-colors.toml", "accent")))
        capture(terminal, capture_dir, "follow-preview")
        apply = terminal.screen.locate("[Apply]")
        click(terminal, apply["column"], apply["row"])
        terminal.until(lambda: not opened(terminal) and json.loads(prefs.read_text()).get("theme") == "follow_omarchy")
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    print("PASS themes: missing-theme fallback, 30/48-column controls, mouse, unattended follow/create/change/remove, fixed mode ignores changes")


def no_color_case(binary, directory, capture_dir):
    source, _, prefs = setup(binary, directory)
    terminal = start(binary, directory, source, no_color=True)
    try:
        before = signature(prefs)
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal) and "NO_COLOR" in terminal.text())
        terminal.send(b"k")
        key_focus(terminal, TAB, "[Apply]", no_color=True)
        key_focus(terminal, TAB, "[Cancel]", no_color=True)
        key_focus(terminal, BACKTAB, "[Apply]", no_color=True)
        capture(terminal, capture_dir, "theme-no-color")
        require(re.search(rb"\x1b\[[0-9;:]*[34]8[;:]2[;:]", bytes(terminal.output)) is None,
                "NO_COLOR theme preview emitted truecolor SGR")
        terminal.send(b"\x1b")
        terminal.until(lambda: not opened(terminal))
        require(signature(prefs) == before, "NO_COLOR canceled choice wrote preferences")
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    print("PASS themes: NO_COLOR keeps actual reverse button focus without truecolor or canceled preference writes")


def failed_save_case(binary, directory):
    source, _, prefs = setup(binary, directory)
    prefs.chmod(0o644)
    before = signature(prefs)
    terminal = start(binary, directory, source)
    desktop = palette(UI_FIXTURES / "theme-colors.toml", "accent")
    try:
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal))
        terminal.send(b"k")
        key_focus(terminal, TAB, "[Apply]")
        terminal.send(ENTER)
        terminal.until(lambda: opened(terminal) and "Not saved" in terminal.text())
        require(signature(prefs) == before and stat.S_IMODE(prefs.stat().st_mode) == 0o644,
                "theme Apply blindly replaced an insecure preference file")
        terminal.send(b"\x1b")
        terminal.until(lambda: not opened(terminal) and header_color(terminal, desktop))
        require(signature(prefs) == before, "Cancel after failed Apply changed preferences")
        terminal.finish()
    finally:
        terminal.close()
    require(signature(prefs) == before, "owner exit rewrote refused preferences")
    print("PASS themes: failed private preference save stays open, preserves file and cancels palette safely")


def quiet_case(binary, directory):
    source, _, _ = setup(binary, directory)
    terminal = start(binary, directory, source)
    try:
        source.release()
        terminal.until(lambda: "Up to date" in terminal.text())
        terminal.gap(.4)
        previous = terminal.output_total
        terminal.gap(4.2)  # Includes at least two ordinary Follow ticks.
        require(terminal.output_total == previous,
                "unchanged Omarchy metadata caused an idle terminal redraw")
        terminal.send(b"T")
        terminal.until(lambda: opened(terminal))
        terminal.send(b"\x1b")
        terminal.until(lambda: not opened(terminal))
        terminal.finish()
    finally:
        terminal.close()
    print("PASS themes: unchanged hot-follow stays physically quiet and input/owner exit remain responsive")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "theme test binary absent")
    with tempfile.TemporaryDirectory(prefix="omagma-theme-picker-") as temporary:
        root = Path(temporary)
        for name, function in (("picker", picker_case), ("follow", follow_case), ("no-color", no_color_case)):
            function(binary, root / name, args.capture_dir)
        failed_save_case(binary, root / "save-refused")
        quiet_case(binary, root / "quiet")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
