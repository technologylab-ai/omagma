#!/usr/bin/env python3
"""Searchable help in isolated owned PTYs; fictional mail and no desktop input."""
import argparse
from pathlib import Path
import sys
import tempfile

from terminal_integration import require
from terminal_local_ui import ACCOUNTS, setup
from terminal_mouse_screen import MouseScreen
from terminal_repaint import BuiltinTerminal


def run(binary, directory, columns, rows):
    config = setup(directory)
    terminal = BuiltinTerminal(binary, directory, config, columns=columns, rows=rows,
                               account=ACCOUNTS[0], screen_type=MouseScreen)
    try:
        terminal.until(lambda: terminal.screen.locate("Mail · 1/32") is not None)
        terminal.send(b"?")
        terminal.until(lambda: "Keyboard & mouse" in terminal.text())
        terminal.send(b"/lAbElS\r")
        terminal.until(lambda: "Find: lAbElS" in terminal.text() and "1/1 matches" in terminal.text()
                       and "Choose labels" in terminal.text())
        # Confirming leaves ordinary help controls active; searching never
        # changes the mailbox's query or issues a server request.
        terminal.send(b"n")
        terminal.until(lambda: "1/1 matches" in terminal.text())
        terminal.resize(48, 20)
        terminal.until(lambda: "1/1 matches" in terminal.text() and "Choose labels" in terminal.text())
        terminal.send(b"/ctrl+s\r")
        terminal.until(lambda: "1/2 matches" in terminal.text() and "Contact editor:" in terminal.text())
        terminal.send(b"n")
        terminal.until(lambda: "2/2 matches" in terminal.text() and "Save the draft" in terminal.text())
        terminal.send(b"N")
        terminal.until(lambda: "1/2 matches" in terminal.text() and "Contact editor:" in terminal.text())
        terminal.send(b"/personalize\r")
        terminal.until(lambda: "PERSONALIZE" in terminal.text() and "1/1 matches" in terminal.text())
        terminal.send(b"/zzzzq?n")
        terminal.until(lambda: "Find: zzzzq?n" in terminal.text() and "No matches" in terminal.text())
        require(terminal.process.poll() is None, "q or ? exited help while typing its search")
        terminal.send(b"\x1b")
        terminal.until(lambda: "/ Search help" in terminal.text() and "Find:" not in terminal.text())
        require("Keyboard & mouse" in terminal.text(), "first Escape left help instead of clearing search")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Keyboard & mouse" not in terminal.text())
        require(terminal.process.poll() is None, "Escape from help quit the TUI")
        terminal.send(b"?")
        terminal.until(lambda: "Keyboard & mouse" in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: "Keyboard & mouse" not in terminal.text())
        require(terminal.process.poll() is None, "q from help quit the TUI")
        terminal.finish()
        print(f"PASS searchable help {columns}x{rows}: action/key/section matches, resize, n/N, literal q, Escape/return")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "test binary absent")
    with tempfile.TemporaryDirectory(prefix="omagma-help-search-") as temporary:
        for columns, rows in ((160, 40), (48, 20)):
            run(binary, Path(temporary) / f"help-{columns}", columns, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
