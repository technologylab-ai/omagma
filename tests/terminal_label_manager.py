#!/usr/bin/env python3
"""Custom label collection UI in owned fixture PTYs; no desktop or live writes."""
from __future__ import annotations
import argparse
from pathlib import Path
import sys
import tempfile

from terminal_dialog_controls import focused, focus, TAB, BACKTAB, ENTER
from terminal_file_dialog import capture, fixture_setup, start_ready
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import click, start


def label_data(binary, directory, source, account=ACCOUNTS[0]):
    with Client(binary, directory, extra=source.options()) as client:
        return client.request("labels.list", account=account, cacheOnly=True)["labels"]


def open_manager(terminal):
    terminal.send(b":labels\r")
    terminal.until(lambda: "Manage labels" in terminal.text() and "[n New]" in terminal.text())


def collection(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    for account in ACCOUNTS:
        source.data[account]["baseline"]["labels"] = [
            {"id": "INBOX", "name": "Inbox", "type": "system"},
            {"id": "CATEGORY_UPDATES", "name": "Updates", "type": "system"},
            {"id": "Label_demo", "name": "Projects", "type": "user"},
            {"id": "Label_travel", "name": "Travel 🌋", "type": "user"}]
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        client.request("labels.list")
        original = client.request("mail.read", messageId="shared-msg-096", cacheOnly=True)
    terminal = start_ready(binary, directory, source)
    try:
        # Heading opens definitions; m remains membership assignment only.
        heading = terminal.screen.locate("LABELS")
        require(heading is not None, "LABELS heading absent")
        click(terminal, heading["column"] + 2, heading["row"])
        terminal.until(lambda: "Manage labels" in terminal.text() and "Projects" in terminal.text())
        require("CATEGORY_UPDATES" not in terminal.text(), "system label leaked into collection dialog")
        capture(terminal, capture_dir, "label-manager-wide")
        for label in ("[n New]", "[r Rename]", "[c Color]", "[d Delete]", "[o Open]", "[q Back]"):
            focus(terminal, TAB, label)
        terminal.send(ENTER)
        terminal.until(lambda: "Manage labels" not in terminal.text())
        terminal.send(b"m")
        terminal.until(lambda: "Labels · staged changes" in terminal.text() and "Projects" in terminal.text())
        require("CATEGORY_UPDATES" not in terminal.text(), "system state leaked into membership picker")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Labels · staged changes" not in terminal.text())
        open_manager(terminal)
        terminal.send(b"n")
        terminal.until(lambda: "New label" in terminal.text() and "Name:" in terminal.text())
        terminal.send(b"qjk Collection\t")
        terminal.until(lambda: focused(terminal, "[Save Ctrl+S]"))
        terminal.send(ENTER)
        terminal.until(lambda: "Label created" in terminal.text() and "qjk Collection" in terminal.text())
        labels = label_data(binary, directory, source)
        created = next(value for value in labels if value["name"] == "qjk Collection")
        created_id = created["id"]
        # Rename is prefilled; Ctrl+U clears the name as ordinary field editing.
        terminal.send(b"r")
        terminal.until(lambda: "Rename label" in terminal.text() and "Was: qjk Collection" in terminal.text())
        capture(terminal, capture_dir, "label-manager-rename")
        terminal.send(b"\x01" + b"\x1b[3~" * len("qjk Collection") + b"qjk Renamed\t\r")
        terminal.until(lambda: "Label renamed" in terminal.text() and "qjk Renamed" in terminal.text())
        labels = label_data(binary, directory, source)
        renamed = next(value for value in labels if value["id"] == created_id)
        require(renamed["name"] == "qjk Renamed", "rename changed the wrong label or lost stable ID")
        terminal.send(b"q")
        terminal.until(lambda: "Manage labels" not in terminal.text())
        terminal.send(b"m/qjk Renamed\r")
        terminal.until(lambda: "[ ]" in terminal.text() and "qjk Renamed" in terminal.text())
        terminal.send(b" \x13")
        terminal.until(lambda: "Mail action: 1 applied" in terminal.text() and "Labels · staged changes" not in terminal.text())
        with Client(binary, directory, extra=source.options()) as client:
            require(created_id in client.request("mail.read", messageId="shared-msg-096", cacheOnly=True)["labels"],
                    "new definition could not be assigned through normal m picker")
        open_manager(terminal)
        terminal.send(b"/qjk Renamed\ro")
        terminal.until(lambda: "Manage labels" not in terminal.text() and "qjk Renamed" in terminal.screen.lines()[0])
        open_manager(terminal)
        terminal.send(b"/qjk Renamed\r")
        # Safe initial Enter cancels; repeat d must not delete.
        terminal.send(b"d")
        terminal.until(lambda: "Delete label?" in terminal.text() and "Emails are kept" in terminal.text()
                       and focused(terminal, "[Cancel]"))
        capture(terminal, capture_dir, "label-manager-delete-review")
        terminal.send(b"d\r")
        terminal.until(lambda: "Manage labels" in terminal.text() and "Delete label?" not in terminal.text())
        require(any(value["id"] == created_id for value in label_data(binary, directory, source)),
                "Cancel/default Enter deleted the collection")
        terminal.send(b"d")
        terminal.until(lambda: "Delete label?" in terminal.text())
        focus(terminal, TAB, "[y Delete]")
        terminal.send(ENTER)
        terminal.until(lambda: "Label deleted" in terminal.text() and "Delete label?" not in terminal.text())
        require(not any(value["id"] == created_id for value in label_data(binary, directory, source)),
                "explicit focused Delete did not remove definition")
        # Existing body and original Inbox membership remain untouched.
        with Client(binary, directory, extra=source.options()) as client:
            after = client.request("mail.read", messageId="shared-msg-096", cacheOnly=True)
            require(after["bodyText"] == original["bodyText"] and "INBOX" in after["labels"]
                    and created_id not in after["labels"],
                    "collection deletion did not preserve mail/body and remove only its membership")
        terminal.send(b"q")
        terminal.until(lambda: "Manage labels" not in terminal.text())
        require("Inbox" in terminal.screen.lines()[0], "deleting the active label did not return to Inbox")
        open_manager(terminal)
        terminal.send(b"/qjk-no-match\r")
        terminal.until(lambda: "No matching labels" in terminal.text())
        focus(terminal, TAB, "[n New]")
        focus(terminal, TAB, "[q Back]")  # Disabled Rename/Delete/Open are skipped.
        terminal.send(ENTER)
        terminal.until(lambda: "Manage labels" not in terminal.text())
        # Account isolation and controls survive small laptop terminals.
        terminal.send(b"2")
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0])
        open_manager(terminal)
        terminal.until(lambda: "Projects" in terminal.text() and "qjk Renamed" not in terminal.text())
        terminal.resize(30, 10)
        terminal.until(lambda: all(label in terminal.text() for label in
                                 ("[n New]", "[r Ren]", "[c Col]", "[d Del]", "[o Op]", "[q Back]")))
        capture(terminal, capture_dir, "label-manager-narrow")
        terminal.send(b"q")
        terminal.until(lambda: "Manage labels" not in terminal.text())
        require(terminal.process.poll() is None, "Back from label manager quit the app")
        terminal.finish()
        print("PASS label manager: heading/m separation, all buttons, create/rename/delete, safe Cancel, stable IDs, mail preserved, account isolation, narrow controls")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def empty_and_drafts(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    source.data[ACCOUNTS[0]]["baseline"]["labels"] = [{"id": "INBOX", "name": "Inbox", "type": "system"}]
    source.stage(ACCOUNTS[0], "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        client.request("labels.list")
    terminal = start_ready(binary, directory, source)
    try:
        open_manager(terminal)
        terminal.until(lambda: "No custom labels" in terminal.text())
        capture(terminal, capture_dir, "label-manager-empty")
        focus(terminal, TAB, "[n New]")
        focus(terminal, TAB, "[q Back]")
        focus(terminal, BACKTAB, "[n New]")
        terminal.send(ENTER)
        terminal.until(lambda: "New label" in terminal.text())
        terminal.send(b"q-not-saved\x1b")
        terminal.until(lambda: "Manage labels" in terminal.text() and "New label" not in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: "Manage labels" not in terminal.text())
        drafts = terminal.screen.locate("Drafts")
        require(drafts is not None, "Drafts mailbox target absent")
        click(terminal, drafts["column"] + 2, drafts["row"])
        terminal.until(lambda: "Drafts" in terminal.screen.lines()[0])
        open_manager(terminal)
        terminal.until(lambda: "No custom labels" in terminal.text())
        terminal.send(b"n")
        terminal.until(lambda: "New label" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "New label" not in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: "Manage labels" not in terminal.text())
        require(not any(value.get("type") == "user" for value in label_data(binary, directory, source)),
                "cancelled empty/draft edits created definitions")
        terminal.finish()
        print("PASS label manager: system-only collection, disabled action traversal, literal text Cancel, works from local Drafts without mail")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def readonly(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    source.data[ACCOUNTS[0]]["baseline"]["labels"] = [{"id": "Label_demo", "name": "Projects", "type": "user"}]
    source.stage(ACCOUNTS[0], "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        client.request("labels.list")
    terminal = start(binary, directory, source, extra=("--fixture-scenario", "readonly"), columns=160, rows=42)
    try:
        terminal.until(lambda: "Fictional file-dialog message 096." in terminal.text())
        open_manager(terminal)
        terminal.until(lambda: "Read-only" in terminal.text())
        capture(terminal, capture_dir, "label-manager-readonly")
        terminal.send(b"nrdc")
        require("New label" not in terminal.text() and "Rename label" not in terminal.text()
                and "Delete label?" not in terminal.text(), "read-only account offered collection mutations")
        focus(terminal, TAB, "[o Open]")
        focus(terminal, TAB, "[q Back]")
        terminal.send(ENTER)
        terminal.until(lambda: "Manage labels" not in terminal.text())
        with Client(binary, directory, scenario="readonly", extra=source.options()) as client:
            require(client.request("operation.list")["operations"] == [], "disabled read-only buttons dispatched a write")
        terminal.finish()
        print("PASS label manager: read-only account browses labels, write buttons disabled and zero journal operations")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def colors(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    for account in ACCOUNTS:
        source.data[account]["baseline"]["labels"] = [
            {"id": "INBOX", "name": "Inbox", "type": "system"},
            {"id": "Label_demo", "name": "Projects", "type": "user",
             "color": {"backgroundColor": "#4a86e8", "textColor": "#ffffff"}}]
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        for account in ACCOUNTS:
            client.request("labels.list", account=account)
        before = client.request("mail.read", messageId="shared-msg-096", cacheOnly=True)
    terminal = start_ready(binary, directory, source)
    try:
        open_manager(terminal)
        focus(terminal, TAB, "[n New]")
        focus(terminal, TAB, "[r Rename]")
        focus(terminal, TAB, "[c Color]")
        terminal.send(ENTER)
        terminal.until(lambda: "Color · Projects" in terminal.text() and "· current" in terminal.text()
                       and "[Save color]" in terminal.text() and focused(terminal, "[Back]"))
        capture(terminal, capture_dir, "label-color-safe-default")
        terminal.send(ENTER)
        terminal.until(lambda: "Color · Projects" not in terminal.text() and "Manage labels" in terminal.text())
        with Client(binary, directory, extra=source.options()) as client:
            require(client.request("operation.list")["operations"] == [],
                    "opening color management/default Back changed a label")
        terminal.send(b"c")
        terminal.until(lambda: "Color · Projects" in terminal.text())
        terminal.send(TAB + b"#a479e2")
        terminal.until(lambda: "Purple #a479e2" in terminal.text())
        terminal.resize(40, 12)
        terminal.until(lambda: "[Save color]" in terminal.text() and "[Back]" in terminal.text())
        capture(terminal, capture_dir, "label-color-narrow")
        focus(terminal, TAB + TAB, "[Save color]")
        terminal.send(ENTER)
        terminal.until(lambda: "Label color: applied" in terminal.text())
        labels = label_data(binary, directory, source)
        changed = next(label for label in labels if label["id"] == "Label_demo")
        require(changed["name"] == "Projects" and changed["color"] == {
            "backgroundColor": "#a479e2", "textColor": "#000000"},
            "color chooser lost definition identity or its valid readable color pair")
        with Client(binary, directory, extra=source.options()) as client:
            other = client.request("labels.list", account=ACCOUNTS[1], cacheOnly=True)["labels"]
            untouched = next(label for label in other if label["id"] == "Label_demo")
            require(untouched["color"]["backgroundColor"] == "#4a86e8", "label color crossed account boundaries")
            after = client.request("mail.read", messageId="shared-msg-096", cacheOnly=True)
            require(after["labels"] == before["labels"] and after["bodyText"] == before["bodyText"],
                    "definition color update changed message membership/content")
            require(client.request("cache.stats")["fixtureSends"] == 0, "color management sent mail")
        terminal.finish()
        print("PASS label color: Tab/Enter, safe Back, named valid color, narrow controls, readable text pair, account and membership isolation")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=("collection", "empty-drafts", "readonly", "colors"), action="append")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-label-manager-") as temporary:
        for name, run in (("collection", collection), ("empty-drafts", empty_and_drafts), ("readonly", readonly), ("colors", colors)):
            if not args.case or name in args.case:
                run(args.binary.resolve(), Path(temporary) / name, args.capture_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
