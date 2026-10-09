#!/usr/bin/env python3
"""Upgrade notice and guidance in owned synthetic PTYs; never opens a desktop."""
import argparse
import json
from pathlib import Path
import sys
import tempfile

from terminal_html import screen_capture
from terminal_integration import require
from terminal_mouse import click, point
from terminal_mouse_screen import MouseScreen
from terminal_pty import Terminal


def start(binary, directory, columns=160, rows=40):
    return Terminal(binary, directory, environment={"OMAGMA_FIXTURE_UPDATES": "1",
        "NO_COLOR": None, "COLORTERM": "truecolor"}, screen_type=MouseScreen,
        columns=columns, rows=rows)


def capture(terminal, directory, name):
    if directory:
        terminal.gap(.12)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{name}.json").write_text(json.dumps(screen_capture(terminal)) + "\n")


def wait_card(terminal):
    terminal.until(lambda: all(value in terminal.text() for value in
                   ("Upgrade available", "0.2.8", "[How to update]", "[Dismiss]")))
    require("0.2.8" in terminal.text(), "fixture newer release is not visible")
    require("Operation failed" not in terminal.text(), "release load leaked a mail error")


def wait_guide(terminal):
    terminal.until(lambda: terminal.screen.locate("Updates · this installation") is not None)
    terminal.until(lambda: "omarchy plugin update" in terminal.text())
    # The title and command arrive before the footer in a large terminal frame.
    # Complete that actual frame before querying its button hit targets.
    terminal.until(lambda: "[Copy agent request]" in terminal.text()
                   and "[Back]" in terminal.text() and "Esc/q Back" in terminal.text())


def card_and_guide(binary, directory, capture_dir):
    terminal = start(binary, directory)
    try:
        wait_card(terminal)
        capture(terminal, capture_dir, "updates-card")
        # Mail selection remains usable and a normal interaction does not dismiss
        # this release (new-mail notices have a separate auto-hide policy).
        terminal.send(b"j")
        terminal.gap(.15)
        require(terminal.screen.locate("Upgrade available") is not None,
                "mail navigation incorrectly acknowledged the upgrade")
        capture(terminal, capture_dir, "updates-card")
        terminal.send(b"\t\t")
        capture(terminal, capture_dir, "updates-card-focused")
        terminal.send(b"\r")
        wait_guide(terminal)
        capture(terminal, capture_dir, "updates-guide")
        labels = ("[Copy commands]", "[Release notes]", "[Install guide]",
                  "[Check again]", "[Checks: daily]", "[Copy agent request]", "[Back]")
        for label in labels:
            require(terminal.screen.locate(label) is not None, f"update control absent: {label}")
        # Initial focus is Copy commands. Traverse every button, including the
        # controls on the second visual row, and activate with Enter.
        terminal.send(b"\r")
        terminal.until(lambda: "Copied to terminal clipboard" in terminal.text())
        terminal.send(b"\t\r")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        terminal.send(b"\t\r")
        terminal.gap(.15)
        require(terminal.screen.locate("Updates · this installation") is not None,
                "installation guide unexpectedly left the update screen")
        terminal.send(b"\t\r")
        terminal.until(lambda: "Release check completed" in terminal.text())
        terminal.send(b"\t\r")
        terminal.until(lambda: "[Checks: manual]" in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "[Checks: daily]" in terminal.text())
        terminal.send(b"\t\r")
        terminal.until(lambda: "Copied to terminal clipboard" in terminal.text())
        terminal.send(b"\t\r")
        wait_card(terminal)
        require(terminal.process.poll() is None, "Back exited the TUI")

        # Both card buttons and every guide control accept real SGR mouse hits.
        click(terminal, *point(terminal, "[How to update]"))
        wait_guide(terminal)
        for label in ("[Copy commands]", "[Release notes]", "[Install guide]", "[Check again]",
                      "[Checks: daily]", "[Copy agent request]"):
            click(terminal, *point(terminal, label))
            terminal.gap(.15)
        terminal.until(lambda: "[Checks: manual]" in terminal.text())
        click(terminal, *point(terminal, "[Back]"))
        wait_card(terminal)
        # Compose has no card and no intercepted editing Tab/typing. Closing the
        # draft restores the still-available notification.
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "Compose" in terminal.text()
                       and "Ctrl+S Review" in terminal.screen.lines()[-2])
        require(terminal.screen.locate("Upgrade available") is None,
                "upgrade card distracted during composing")
        terminal.send(b"\x1b")
        wait_card(terminal)
        click(terminal, *point(terminal, "[Dismiss]"))
        terminal.until(lambda: terminal.screen.locate("Upgrade available") is None)
        # Dismissed notices remain discoverable through the searchable palette.
        terminal.send(b"\x10updates\r")
        wait_guide(terminal)
        terminal.send(b"q")
        terminal.until(lambda: terminal.screen.locate("Updates · this installation") is None)
        require(terminal.process.poll() is None, "q in Updates exited the app")
        require(terminal.screen.locate("Upgrade available") is None,
                "dismissed version reappeared after reopening its guide")
        terminal.finish()
        return {"keyboard": True, "mouse": True, "composeSuppression": True,
                "paletteAfterDismiss": True, "fixtureSends": 0,
                "captureSequence": {"before": "updates-card.json",
                    "focused": "updates-card-focused.json", "after": "updates-guide.json",
                    "events": ["Tab", "Tab", "Enter"],
                    "columns": 160, "rows": 40,
                    "runningVersion": "0.2.7", "illustrativeAvailableVersion": "0.2.8",
                    "automaticInstallation": False}}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        print(f"Owned TUI exit: {terminal.process.poll()}", file=sys.stderr)
        print(repr(bytes(terminal.output[-1600:])), file=sys.stderr)
        raise
    finally:
        terminal.close()


def narrow(binary, directory, capture_dir):
    terminal = start(binary, directory, columns=60, rows=20)
    try:
        terminal.until(lambda: terminal.screen.locate("[Updates]") is not None)
        require(terminal.screen.locate("Upgrade available") is None,
                "narrow terminal used an obstructing card")
        terminal.send(b"\t\r")
        terminal.until(lambda: "Updates · this installation" in terminal.text()
                       and "[Back]" in terminal.text())
        capture(terminal, capture_dir, "updates-narrow")
        terminal.send(b"\x1b")
        terminal.until(lambda: terminal.screen.locate("[Updates]") is not None)
        click(terminal, *point(terminal, "[Updates]"))
        terminal.until(lambda: "Updates · this installation" in terminal.text()
                       and "[Back]" in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: terminal.screen.locate("[Updates]") is not None)
        terminal.finish()
        return {"compactIndicator": True, "keyboard": True, "mouse": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-updates-ui-") as path:
        directory = Path(path)
        result = {"cardGuide": card_and_guide(binary, directory / "normal", args.capture),
                  "narrow": narrow(binary, directory / "narrow", args.capture)}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("PASS updates UI: keyboard/mouse controls, guide, dismissal, composition and narrow fallback")


if __name__ == "__main__":
    main()
