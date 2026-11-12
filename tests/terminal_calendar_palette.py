#!/usr/bin/env python3
"""Reversible Omagma Calendar looks, persisted in isolated synthetic sessions."""
import argparse
import json
from pathlib import Path
import tempfile

from terminal_calendar import Invitations, provider_state
from terminal_calendar_tui import start, wait_calendar
from terminal_html import screen_capture
from terminal_integration import Client, require


def config(owned, **fields):
    path = owned / "config/omagma/ui.json"
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(fields) + "\n")
    path.chmod(0o600)
    return path


def case(binary, root, captures=None, no_color=False, follow=False):
    fixture = Invitations(root)
    owned = root / "client"
    prefs = config(owned, theme="follow_omarchy" if follow else "omagma", calendarLook="orange_blue", readerLayout="right")
    terminal = start(binary, owned, fixture, columns=160, rows=42, no_color=no_color)
    try:
        mail_before = [list(row) for row in terminal.screen.styles]
        terminal.send(b"C")
        wait_calendar(terminal)
        with Client(binary, owned, extra=fixture.options()) as client:
            before = client.request("cache.stats")
        if no_color or follow:
            terminal.send(b"\x14")
            terminal.until(lambda: "Calendar look follows the current theme" in terminal.text())
            require(json.loads(prefs.read_text())["calendarLook"] == "orange_blue", "ignored toggle changed saved look")
        else:
            require("^T look" in terminal.text(), "Calendar footer does not reveal the appearance shortcut")
            for view, name in ((b"1", "Agenda"), (b"2", "Day"), (b"3", "Week")):
                terminal.send(view)
                wait_calendar(terminal, name)
                if captures:
                    captures.mkdir(parents=True, exist_ok=True)
                    (captures / (name.lower() + "-orange-blue.json")).write_text(json.dumps(screen_capture(terminal)) + "\n")
                with Client(binary, owned, extra=fixture.options()) as client:
                    toggle_before = client.request("cache.stats")["fixtureCalls"]
                terminal.send(b"\x14")
                terminal.until(lambda: "Calendar look: Classic" in terminal.text())
                with Client(binary, owned, extra=fixture.options()) as client:
                    require(client.request("cache.stats")["fixtureCalls"] == toggle_before, "appearance toggle contacted a provider")
                require(json.loads(prefs.read_text())["calendarLook"] == "classic_pastel", "Classic was not saved")
                if captures:
                    (captures / (name.lower() + "-classic.json")).write_text(json.dumps(screen_capture(terminal)) + "\n")
                terminal.send(b"\x14")
                terminal.until(lambda: "Calendar look: Orange & Blue" in terminal.text())
                require(json.loads(prefs.read_text())["calendarLook"] == "orange_blue", "second toggle did not undo the first")
            # A failed local save restores the exact prior choice.
            backup = prefs.with_suffix(".kept")
            prefs.rename(backup)
            prefs.mkdir()
            terminal.send(b"\x14")
            terminal.until(lambda: "UI preferences not saved" in terminal.text())
            prefs.rmdir()
            backup.rename(prefs)
            terminal.send(b"\x14")
            terminal.until(lambda: "Calendar look: Classic" in terminal.text())
            require(json.loads(prefs.read_text())["calendarLook"] == "classic_pastel", "failed save did not restore the previous in-memory look")
            terminal.send(b"1")
            wait_calendar(terminal)
            terminal.send(b"n")
            terminal.until(lambda: "New event" in terminal.text() and "[Ctrl+S Review]" in terminal.text())
            terminal.send(b"\x14")
            terminal.gap(.05)
            require(json.loads(prefs.read_text())["calendarLook"] == "classic_pastel", "Ctrl+T inside a form changed Calendar appearance")
            terminal.send(b"\x1b")
            wait_calendar(terminal)
        with Client(binary, owned, extra=fixture.options()) as client:
            after = client.request("cache.stats")
            require(after["fixtureSends"] == 0, "appearance change sent mail")
            require(provider_state(client)["writes"] == 0, "appearance change wrote Calendar")
        terminal.send(b"q")
        terminal.until(lambda: "Calendar ·" not in terminal.screen.lines()[0] and "Mail ·" in terminal.text())
        # Selected Calendar colors are frame-local; Mail keeps its palette.
        require(terminal.screen.styles[0][1] == mail_before[0][1], "Calendar appearance leaked into the Mail header")
        terminal.finish()
    except Exception:
        print(terminal.text(), flush=True)
        print("Preferences:", prefs.read_text(), flush=True)
        raise
    finally:
        terminal.close()
    if not no_color and not follow:
        terminal = start(binary, owned, fixture, columns=160, rows=42)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            terminal.send(b"\x14")
            terminal.until(lambda: "Calendar look: Orange & Blue" in terminal.text())
            require(json.loads(prefs.read_text())["calendarLook"] == "orange_blue", "Classic did not survive restart")
            terminal.finish()
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--captures", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-calendar-palette-") as temporary:
        for name, no_color, follow in (("omagma", False, False), ("mono", True, False), ("follow", False, True)):
            root = Path(temporary) / name
            root.mkdir()
            case(args.binary.resolve(), root, args.captures if name == "omagma" else None, no_color, follow)
            print(f"PASS Calendar look: {name}, reversible persisted toggle, no provider effects")


if __name__ == "__main__":
    main()
