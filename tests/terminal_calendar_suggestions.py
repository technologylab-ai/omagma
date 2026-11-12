#!/usr/bin/env python3
"""Local guest completions in owned PTYs; never creates a real event or mail."""
import argparse
import json
from pathlib import Path
import tempfile

from terminal_calendar import Invitations, provider_state
from terminal_calendar_compose import start, open_new, focus_field, focused_field, row_text, fill
from terminal_integration import ACCOUNTS, Client, require
from terminal_html import screen_capture
from terminal_mouse import click, point


ADDRESS = "ameni@example.test"


def case(binary, root, columns, captures=None, zero_width_name=False):
    fixture = Invitations(root)
    file = fixture.root / "accounts/personal.json"
    source = json.loads(file.read_text())
    for message in source["messages"]:
        for header in message["payload"]["headers"]:
            if header["name"] == "From":
                header["value"] = ("Am" + "\u200b" * 70 if zero_width_name else "Ameni Example " * (6 if columns > 80 else 1)) + "<" + ADDRESS + ">"
    file.write_text(json.dumps(source) + "\n")
    (fixture.root / "contacts").mkdir()
    for key in ("personal", "work", "optional"):
        (fixture.root / "contacts" / (key + ".json")).write_text('{"connections":[]}\n')
    owned = root / "client"
    with Client(binary, owned, extra=fixture.options()) as client:
        client.request("mail.list", label="INBOX")
        client.request("contacts.list")
    if columns > 80:
        prefs = owned / "config/omagma/ui.json"
        prefs.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        prefs.write_text('{"theme":"omagma"}\n')
        prefs.chmod(0o600)
    terminal = start(binary, owned, fixture, columns=columns, rows=42 if columns > 80 else 26)
    try:
        open_new(terminal)
        focus_field(terminal, "Guests")
        require("Ctrl+Space" in terminal.text(), "Guests focus does not reveal its explicit picker shortcut")
        with Client(binary, owned, extra=fixture.options()) as client:
            calls_before_typing = client.request("cache.stats")["fixtureCalls"]
        terminal.send(b"a")
        terminal.gap(.03)
        require(ADDRESS not in terminal.text(), "suggestions appeared before two characters")
        terminal.send(b"m")
        terminal.until(lambda: ADDRESS in terminal.text())
        if captures:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / f"guests-{columns}{'-zero-width' if zero_width_name else ''}.json").write_text(json.dumps(screen_capture(terminal)) + "\n")
        address_row = next(row for row in terminal.screen.lines() if ADDRESS in row)
        require("Location:" not in address_row and "Ctrl+Space" not in address_row, "suggestion still looks like a form field")
        if columns > 80:
            click(terminal, *point(terminal, "Suggestions ·"))
            terminal.gap(.03)
            require("Add a guest from Contacts" not in terminal.text(), "popup header clicked through to hidden Browse all")
        with Client(binary, owned, extra=fixture.options()) as client:
            require(client.request("cache.stats")["fixtureCalls"] == calls_before_typing, "typing queried a provider instead of local sources")
        require("ameni@" not in row_text(terminal, "Guests:"), "typing silently replaced the partial name")
        # Enter without selecting a candidate remains normal field navigation.
        terminal.send(b"\r")
        terminal.until(lambda: not focused_field(terminal, "Guests"))
        require("am" in row_text(terminal, "Guests:") and ADDRESS not in row_text(terminal, "Guests:"), "unselected Enter added a person")
        fill(terminal, "Guests", "")
        terminal.send(b"am")
        terminal.until(lambda: ADDRESS in terminal.text())
        terminal.send(b"\x0e\x1b[D\r")
        terminal.until(lambda: not focused_field(terminal, "Guests"))
        require("am" in row_text(terminal, "Guests:") and ADDRESS not in row_text(terminal, "Guests:"), "cursor motion retained a stale selected person")
        fill(terminal, "Guests", "")
        terminal.send(b"am")
        terminal.until(lambda: ADDRESS in terminal.text())
        terminal.send(b"\x0e\x0e\r")  # Repeated Down stays on the last visible choice.
        terminal.until(lambda: ADDRESS in row_text(terminal, "Guests:") and focused_field(terminal, "Guests"))
        require("am," not in row_text(terminal, "Guests:"), "accepted address left the unfinished name behind")
        terminal.send(b"am")
        terminal.until(lambda: "No match" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "No match" not in terminal.text() and "New event" in terminal.text())
        terminal.send(b"x")
        terminal.gap(.03)
        require("Suggestions" not in terminal.text(), "Esc dismissal reopened while editing the same token")
        # Paste does not open suggestions, but Ctrl+Space still starts with
        # the unfinished entry and replaces it through the full picker.
        fill(terminal, "Guests", "a")
        require("Suggestions" not in terminal.text(), "pasting unexpectedly opened suggestions")
        terminal.send(b"\x00")
        terminal.until(lambda: "Add a guest from Contacts" in terminal.text() and ADDRESS in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "Add a guest from Contacts" not in terminal.text() and ADDRESS in row_text(terminal, "Guests:"))
        require("am," not in row_text(terminal, "Guests:"), "full picker appended beside the unfinished entry")
        require("a," not in row_text(terminal, "Guests:"), "full picker left a one-letter partial entry")
        # A click selects directly, preserving the same review-only boundary.
        fill(terminal, "Guests", "")
        terminal.send(b"am")
        terminal.until(lambda: ADDRESS in terminal.text())
        click(terminal, *point(terminal, ADDRESS))
        terminal.until(lambda: ADDRESS in row_text(terminal, "Guests:"))
        with Client(binary, owned, extra=fixture.options()) as client:
            require(client.request("cache.stats")["fixtureSends"] == 0, "guest completion sent mail")
            require(provider_state(client)["writes"] == 0, "guest completion saved an event")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
        terminal.send(b"\x04")
        terminal.until(lambda: "Calendar ·" in terminal.text() and "New event" not in terminal.text())
        terminal.finish()
    finally:
        terminal.close()


def clipped_address(binary, root):
    fixture = Invitations(root)
    path = fixture.root / "accounts/personal.json"
    source = json.loads(path.read_text())
    address = "ameni.with.a.long.address@long-domain.example.test"
    for message in source["messages"]:
        for header in message["payload"]["headers"]:
            if header["name"] == "From":
                header["value"] = "Ameni Example <" + address + ">"
    path.write_text(json.dumps(source) + "\n")
    owned = root / "client"
    with Client(binary, owned, extra=fixture.options()) as client:
        client.request("mail.list", label="INBOX")
    terminal = start(binary, owned, fixture, columns=48, rows=26)
    try:
        open_new(terminal)
        focus_field(terminal, "Guests")
        terminal.send(b"am")
        terminal.until(lambda: "Ctrl+Space Browse all" in terminal.text())
        terminal.send(b"\x0e\r")
        terminal.until(lambda: not focused_field(terminal, "Guests"))
        require("am" in row_text(terminal, "Guests:") and "ameni" not in row_text(terminal, "Guests:"), "a clipped address could be accepted")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
        terminal.send(b"\x04")
        terminal.until(lambda: "Calendar ·" in terminal.text() and "New event" not in terminal.text())
        terminal.finish()
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--captures", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-calendar-suggestions-") as temporary:
        for width, zero_width in ((132, False), (48, False), (132, True)):
            root = Path(temporary) / (str(width) + ("-zero-width" if zero_width else ""))
            root.mkdir()
            case(args.binary.resolve(), root, width, args.captures, zero_width)
            print(f"PASS guest suggestions: width={width}, local recent mail, explicit acceptance, picker replacement, no writes")
        root = Path(temporary) / "clipped"
        root.mkdir()
        clipped_address(args.binary.resolve(), root)
        print("PASS guest suggestions: clipped addresses cannot be accepted")


if __name__ == "__main__":
    main()
