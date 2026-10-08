#!/usr/bin/env python3
"""All dialog action groups in isolated fixture PTYs; no desktop/live mail.

Run in the root agent's cooperative host window. Each case uses a fresh private
fixture directory. Explicit Send/RSVP acceptance below reaches only mock data.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
import sys

from terminal_composer_workflow import setup as composer_setup
from terminal_file_dialog import fixture_setup, start_ready, open_popup, popup_text
from terminal_integration import ACCOUNTS, Client, require
from terminal_invitations import InvitationFixture
from terminal_mouse import start, MouseTerminal
from terminal_mouse_screen import MouseScreen


TAB = b"\t"
BACKTAB = b"\x1b[Z"
ENTER = b"\r"
SELECTED = ("rgb", 57, 43, 48)


def focused(terminal, label):
    position = terminal.screen.locate(label)
    return position is not None and terminal.screen.styles[position["row"]][position["column"]][1] == SELECTED


def focus(terminal, keys, label):
    terminal.send(keys)
    terminal.until(lambda: focused(terminal, label))


def message(binary, directory, source, message_id="shared-msg-096"):
    with Client(binary, directory, extra=source.options()) as client:
        return client.request("mail.read", messageId=message_id, cacheOnly=True)


def labels_and_files(binary, directory):
    source = fixture_setup(binary, directory)
    for account in ACCOUNTS:
        source.data[account]["baseline"]["labels"] = [{"id": "Label_demo", "name": "Projects", "type": "user"}]
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        client.request("labels.list")
    terminal = start_ready(binary, directory, source)
    try:
        terminal.send(b"m")
        terminal.until(lambda: "Choose label" in terminal.text() and "Projects" in terminal.text())
        focus(terminal, TAB, "[+ Add]")
        focus(terminal, TAB, "[- Remove]")
        focus(terminal, BACKTAB, "[+ Add]")
        terminal.send(ENTER)
        terminal.until(lambda: "Choose label" not in terminal.text() and "Mail action: 1 applied" in terminal.text())
        require("Label_demo" in message(binary, directory, source)["labels"], "focused Add did not apply the chosen label")
        terminal.send(b"m")
        terminal.until(lambda: "Choose label" in terminal.text())
        focus(terminal, TAB + TAB, "[- Remove]")
        terminal.send(ENTER)
        terminal.until(lambda: "Choose label" not in terminal.text() and "Mail action: 1 applied" in terminal.text())
        require("Label_demo" not in message(binary, directory, source)["labels"], "focused Remove did not remove the chosen label")
        terminal.send(b"m")
        terminal.until(lambda: "Choose label" in terminal.text())
        terminal.send(BACKTAB + b"q-not-a-label")
        terminal.until(lambda: "q-not-a-label" in terminal.text() and "No matching labels" in terminal.text())
        require(terminal.process.poll() is None, "q in the label filter quit instead of entering text")
        terminal.send(ENTER)
        focus(terminal, TAB, "[Back]")  # Disabled Add/Remove are skipped.
        terminal.send(ENTER)
        terminal.until(lambda: "Choose label" not in terminal.text())
        terminal.send(b"B")
        terminal.until(lambda: "Received attachments" in terminal.text())
        focus(terminal, TAB, "[s Save]")
        terminal.send(ENTER)
        title = open_popup(terminal, received=True)
        require("[Save]" in popup_text(terminal, title), "Save button did not open the save-file dialog")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Received attachments" in terminal.text() and "Save attachment ·" not in terminal.text())
        focus(terminal, TAB, "[o Save & open]")
        terminal.send(ENTER)
        title = open_popup(terminal, received=True)
        require("[Save & open]" in popup_text(terminal, title), "Open button lost save-and-open intent")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Received attachments" in terminal.text() and "Save attachment ·" not in terminal.text())
        terminal.resize(30, 22)
        terminal.until(lambda: "[s Save]" in terminal.text() and "[o Open]" in terminal.text() and "[Back]" in terminal.text())
        focus(terminal, TAB, "[Back]")
        terminal.send(ENTER)
        terminal.until(lambda: "Received attachments" not in terminal.text())
        terminal.resize(160, 42)
        terminal.until(lambda: "Fictional file-dialog message 096." in terminal.text())
        terminal.send(b"L")
        terminal.until(lambda: "Links · explicit browser open" in terminal.text())
        focus(terminal, TAB, "[Open]")
        focus(terminal, TAB, "[Back]")
        terminal.send(ENTER)
        terminal.until(lambda: "Links · explicit browser open" not in terminal.text())
        terminal.finish()
        print("PASS dialog controls: label Add/Remove/filter, reverse focus, received Save/Open and Links, narrow buttons")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def contacts_alias_and_send(binary, directory):
    extra, body = composer_setup(binary, directory)
    terminal = MouseTerminal(binary, directory, extra=extra, columns=160, rows=40,
                             screen_type=MouseScreen, environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    terminal.until(lambda: body["bodyText"].splitlines()[0] in terminal.text())
    try:
        terminal.send(b"a")
        terminal.until(lambda: "Contacts ·" in terminal.text() and "Alex Personal Fixture" in terminal.text())
        terminal.send(b"n")
        terminal.until(lambda: "Name:" in terminal.text() and "[Save]" in terminal.text())
        terminal.send(b"Unsent Contact")
        focus(terminal, BACKTAB, "[Cancel]")
        terminal.send(ENTER)
        terminal.until(lambda: "Name:" not in terminal.text())
        terminal.send(b"n")
        terminal.until(lambda: "Name:" in terminal.text())
        terminal.send(b"Keyboard Contact\tnew-contact@example.test")
        focus(terminal, TAB, "[Save]")
        terminal.send(ENTER)
        terminal.until(lambda: "Contact saved" in terminal.text() and "Name:" not in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            contacts = client.request("contacts.list", cacheOnly=True)["contacts"]
            require(any(value["name"] == "Keyboard Contact" for value in contacts), "Enter on contact Save did not save")
            require(not any(value["name"] == "Unsent Contact" for value in contacts), "Cancel unexpectedly saved contact text")
        terminal.send(b"q")
        terminal.until(lambda: "Contacts ·" not in terminal.text())
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "[f Alias]" in terminal.text())
        focus(terminal, BACKTAB, "[f Alias]")
        terminal.send(ENTER)
        terminal.until(lambda: "From: alias@example.test" in terminal.text())
        terminal.send(TAB + b"irecipient@example.test\t\t\tKeyboard-only send\tThis is a fixture body.")
        terminal.send(b"\x1b")
        terminal.gap(.06)
        terminal.send(b"\x13")
        terminal.until(lambda: "Review send" in terminal.text() and focused(terminal, "[Back]"))
        terminal.send(ENTER)
        terminal.until(lambda: "Review send" not in terminal.text() and "Subject:" in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            require(client.request("cache.stats")["fixtureSends"] == 0, "safe initial review Enter sent mail")
        terminal.resize(80, 30)
        terminal.until(lambda: "[Preview p]" in terminal.text())
        terminal.send(b"p")
        terminal.until(lambda: "[Back]" in terminal.text() and "Subject:" not in terminal.text())
        focus(terminal, TAB, "[Preview p]")
        focus(terminal, TAB, "[Back]")
        terminal.send(ENTER)
        terminal.until(lambda: "Subject:" in terminal.text())
        terminal.resize(160, 40)
        terminal.until(lambda: "Outgoing preview" in terminal.text())
        terminal.send(b"\x13")
        terminal.until(lambda: "Review send" in terminal.text() and focused(terminal, "[Back]"))
        focus(terminal, TAB, "[y Send]")
        focus(terminal, BACKTAB, "[Back]")
        focus(terminal, TAB, "[y Send]")
        terminal.send(ENTER)
        terminal.until(lambda: "Saved by mock provider" in terminal.text() and "Review send" not in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            require(client.request("cache.stats")["fixtureSends"] == 1, "focused review Enter did not send exactly once")
        terminal.finish(expected_sends=1)
        print("PASS dialog controls: contact Save/Cancel, Alias, narrow Preview/Back, safe default review, explicit focused Send")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def trash_review(binary, directory):
    source = fixture_setup(binary, directory)
    terminal = start_ready(binary, directory, source)
    try:
        terminal.send(b"D")
        terminal.until(lambda: "Move selected mail to Trash?" in terminal.text() and focused(terminal, "[Cancel]"))
        terminal.send(ENTER)
        terminal.until(lambda: "Move selected mail to Trash?" not in terminal.text())
        require("TRASH" not in message(binary, directory, source)["labels"], "default Cancel Enter trashed mail")
        terminal.send(b"D")
        terminal.until(lambda: "Move selected mail to Trash?" in terminal.text())
        focus(terminal, TAB, "[y Confirm]")
        focus(terminal, BACKTAB, "[Cancel]")
        focus(terminal, TAB, "[y Confirm]")
        terminal.send(ENTER)
        terminal.until(lambda: "Move selected mail to Trash?" not in terminal.text() and "Mail action: 1 applied" in terminal.text())
        require("TRASH" in message(binary, directory, source)["labels"], "explicit focused confirmation did not move mail to Trash")
        terminal.finish()
        print("PASS dialog controls: Trash defaults Cancel and mutates only after deliberate focus and Enter")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def invitation_review(binary, directory):
    source = InvitationFixture(directory)
    # This is a focused positive UI workflow, not the separate decoder refusal
    # corpus. Ambiguous negative calendars must not poison mail-list setup.
    for account in ACCOUNTS:
        source.sources[account]["messages"] = [value for value in source.sources[account]["messages"]
            if not value["id"].startswith("invite-") or value["id"] == "invite-named-calendar"]
        source.save(account)
    with Client(binary, directory, extra=source.options()) as client:
        client.request("mail.list", limit=32)
        client.request("mail.read", messageId="invite-named-calendar")
    terminal = start(binary, directory, source)
    try:
        terminal.until(lambda: "Mail ·" in terminal.text())
        terminal.send(b'/subject:"Fictional named-calendar"\r')
        terminal.until(lambda: "Fictional named-calendar" in terminal.text())
        terminal.send(b"I")
        terminal.until(lambda: "Review invitation reply" in terminal.text() and focused(terminal, "[Cancel]"))
        terminal.send(ENTER)
        terminal.until(lambda: "Review invitation reply" not in terminal.text())
        with Client(binary, directory, extra=source.options()) as client:
            require(client.request("cache.stats")["fixtureSends"] == 0, "default RSVP Enter sent a response")
        terminal.send(b"I")
        terminal.until(lambda: "Review invitation reply" in terminal.text())
        focus(terminal, TAB, "[a Accept]")
        focus(terminal, TAB, "[t Tentative]")
        focus(terminal, TAB, "[d Decline]")
        focus(terminal, BACKTAB, "[t Tentative]")
        terminal.send(ENTER)
        terminal.until(lambda: "Saved by mock provider" in terminal.text() and "Review invitation reply" not in terminal.text())
        with Client(binary, directory, extra=source.options()) as client:
            operations = client.request("operation.list")["operations"]
            require(len(operations) == 1 and "PARTSTAT=TENTATIVE" in operations[0]["icalendar"], "focused Tentative changed reviewed RSVP choice")
            require(client.request("cache.stats")["fixtureSends"] == 1, "focused RSVP Enter submitted more than once")
        terminal.finish(expected_sends=1)
        print("PASS dialog controls: every RSVP button, safe Cancel default and exactly one explicitly chosen Tentative reply")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", action="append", choices=("labels-files", "contacts-compose-send", "trash", "invitation"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    cases = {"labels-files": labels_and_files, "contacts-compose-send": contacts_alias_and_send,
             "trash": trash_review, "invitation": invitation_review}
    with tempfile.TemporaryDirectory(prefix="omagma-dialog-controls-") as temporary:
        for name, run in cases.items():
            if args.case and name not in args.case:
                continue
            run(binary, Path(temporary) / name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
