#!/usr/bin/env python3
"""Delete and RSVP from the Calendar view through owned PTYs; synthetic only.

Every write needs a dialog, an explicit choice and a separate confirmation:
no single key from the Calendar view changes Calendar. Uses the persistent
synthetic Calendar provider; no desktop windows, accounts, OAuth or network.
Run under this repository's cooperative measurement reservation.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
import types

from build_info import read_build_info
from terminal_calendar import Invitations
from terminal_calendar_tui import capture, start, wait_calendar
from terminal_integration import ACCOUNTS, fixture_calendar_writes, require
from terminal_theme_picker import focused

SHIFT_TAB = b"\x1b[Z"
CTRL_R = b"\x12"


def writes(owned):
    return fixture_calendar_writes(types.SimpleNamespace(directory=owned))


def stored(owned, event_id):
    for path in (owned / "cache").rglob("calendar-provider-fixture.json"):
        state = json.loads(path.read_text())
        if state["account"] != ACCOUNTS[0]:
            continue
        for entry in state["events"]:
            if entry["value"]["id"] == event_id:
                return entry["value"]
    return None


def selected(terminal):
    return next((line for line in terminal.screen.lines() if "▸" in line), "")


def pick(terminal, query):
    """Filter the loaded events and select the first match."""
    terminal.send(b"/" + query.encode() + b"\r")
    terminal.until(lambda: query in selected(terminal))
    terminal.gap(.1)


def clear_filter(terminal):
    terminal.send(b"\x1b")
    terminal.until(lambda: "Filter:" not in terminal.screen.lines()[2])
    terminal.gap(.1)


def ready(terminal, marker):
    """The dialog shows its fresh plan (nothing changes while it loads)."""
    terminal.until(lambda: marker in terminal.text() and "Checking" not in terminal.text())
    terminal.gap(.1)


def frame(frames, terminal, name):
    if frames is not None:
        frames.mkdir(parents=True, exist_ok=True)
        (frames / (name + ".txt")).write_text("\n".join(terminal.screen.lines()) + "\n")


def organizer_and_invitations(binary, directory, captures, frames):
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        # RSVP: r opens a chooser in which Calendar keys only move or choose.
        pick(terminal, "Partner sync")
        require("[r RSVP]" in terminal.text() and "[D Delete]" in terminal.text(),
                "the selected invitation shows no RSVP/Delete buttons")
        terminal.send(b"r")
        ready(terminal, "Your answer now · Not answered")
        require("Invited by host@example.test" in terminal.text(), "chooser does not name the organizer")
        capture(terminal, captures, "calendar-rsvp-chooser")
        frame(frames, terminal, "rsvp-chooser")
        terminal.send(b"dtwoe")
        terminal.send(b"y")
        terminal.until(lambda: "Choose Accept, Maybe or Decline" in terminal.text())
        require(writes(owned) == 0, "stray keys or y without an answer wrote Calendar")
        terminal.send(b"x")
        terminal.until(lambda: "[y Decline · email organizer]" in terminal.text() and "(•) Decline" in terminal.text())
        require("Google emails your answer to" in terminal.text(), "chooser hides the organizer email")
        require("y sends it once" in terminal.screen.lines()[-1], "status still asks for a choice that was made")
        require(writes(owned) == 0, "choosing an answer wrote before its confirmation")
        frame(frames, terminal, "rsvp-decline-chosen")
        terminal.send(b"y")
        terminal.until(lambda: "Declined · Partner sync" in terminal.text())
        terminal.until(lambda: "×" in selected(terminal))
        require(writes(owned) == 1, "a confirmed RSVP did not write exactly once")
        answer = [a for a in stored(owned, "fixture-invite")["attendees"] if a["email"] == ACCOUNTS[0]]
        require(len(answer) == 1 and answer[0]["responseStatus"] == "declined", "the provider kept the old answer")
        frame(frames, terminal, "rsvp-declined-status")
        # The organizer has no RSVP; a delete with guests needs an email choice.
        clear_filter(terminal)
        pick(terminal, "Roadmap")
        terminal.send(b"r")
        terminal.until(lambda: "You organize this event, so there is no RSVP to send" in terminal.text())
        terminal.send(b"D")
        ready(terminal, "You organize it · 2 guests")
        require("Delete event?" in terminal.text() and "Email 2 guests a cancellation" in terminal.text(),
                "delete dialog does not offer the guest email choice")
        require("without emailing" not in terminal.text() and "emails 2 guests" not in terminal.text(),
                "the dialog claimed an email outcome before the choice was made")
        capture(terminal, captures, "calendar-delete-guests")
        frame(frames, terminal, "delete-guests-choice")
        terminal.send(b"y")
        terminal.until(lambda: "Choose whether Google emails the guests" in terminal.text())
        require(writes(owned) == 1, "a delete without an email choice wrote Calendar")
        terminal.send(b"j\r")
        terminal.until(lambda: "[y Delete, no email]" in terminal.text())
        frame(frames, terminal, "delete-no-email-chosen")
        terminal.send(b"y")
        terminal.until(lambda: "Deleted · Roadmap review" in terminal.text())
        terminal.until(lambda: "Roadmap" not in selected(terminal))
        require(writes(owned) == 2 and stored(owned, "fixture-hosted")["status"] == "cancelled",
                "the confirmed delete did not reach the provider once")
        # Enter on an untouched delete cancels, as in Mail's Trash dialog.
        clear_filter(terminal)
        pick(terminal, "Focus block")
        terminal.send(b"D")
        ready(terminal, "It has no guests, so no email is sent")
        require(focused(terminal, "[Esc Cancel]"), "an untouched delete did not focus Cancel")
        terminal.send(b"\r")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        require(writes(owned) == 2, "Enter on Cancel wrote Calendar")
        # One occurrence or the whole series; this-and-following is not offered.
        clear_filter(terminal)
        pick(terminal, "Standup")
        terminal.send(b"D")
        ready(terminal, "This event only")
        require("All events in the series" in terminal.text() and "This and following · not offered" in terminal.text(),
                "recurring delete does not explain its scope choices")
        capture(terminal, captures, "calendar-delete-series")
        terminal.send(SHIFT_TAB + b"\r")
        terminal.send(b"\t\r")
        terminal.until(lambda: "[y Delete series & email 1 guest]" in terminal.text())
        frame(frames, terminal, "delete-series-email")
        terminal.send(b"y")
        terminal.until(lambda: "Deleted series · Standup" in terminal.text())
        require(writes(owned) == 3 and stored(owned, "fixture-standup")["status"] == "cancelled",
                "the series delete did not target the series once")
        clear_filter(terminal)
        terminal.until(lambda: "Standup" not in "\n".join(terminal.screen.lines()[3:-2]))
        # From the event card: a Maybe for the whole series without an email.
        pick(terminal, "Office hours")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Event" in terminal.text() and "[r RSVP]" in terminal.text()
                       and "Loading event" not in terminal.text())
        terminal.send(b"r")
        ready(terminal, "Your answer now · Not answered")
        terminal.send(b"m" + b"\t" * 3 + b"\r" + b"\t\r")
        terminal.until(lambda: "[y Maybe series · no email]" in terminal.text())
        frame(frames, terminal, "rsvp-series-maybe")
        terminal.send(b"y")
        terminal.until(lambda: "Your response · Tentative" in terminal.text())
        office = [a for a in stored(owned, "fixture-office")["attendees"] if a["email"] == ACCOUNTS[0]]
        require(writes(owned) == 4 and office[0]["responseStatus"] == "tentative", "series answer missing")
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text())
        # Someone else's event without a guest entry: removed here only.
        clear_filter(terminal)
        pick(terminal, "Daily review")
        terminal.send(b"D")
        ready(terminal, "Organized by host@example.test")
        require("Remove from your calendar?" in terminal.text() and "[y Remove from my calendar]" in terminal.text(),
                "a copy of someone else's event is presented as a delete for everyone")
        frame(frames, terminal, "remove-copy")
        terminal.send(b"y")
        terminal.until(lambda: "Removed from your calendar · Daily review" in terminal.text())
        require(writes(owned) == 5, "removing a copy did not write exactly once")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "organizer-and-invitations", "writes": writes(owned), "mailSends": 0}


def conflict(binary, directory, frames):
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions-conflict")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Focus block")
        terminal.send(b"D")
        ready(terminal, "It has no guests, so no email is sent")
        terminal.send(b"y")
        terminal.until(lambda: "Not changed · the event was changed in Calendar after you opened it" in terminal.text())
        frame(frames, terminal, "delete-conflict")
        event = stored(owned, "fixture-focus")
        require(event["status"] == "confirmed" and event["location"] == "Moved by another client",
                "a concurrently changed event was deleted")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "if-match-conflict", "deleted": False}


def uncertain(binary, directory, frames):
    """A lost answer reconciles read-only; an unsent delete survives restart
    and is retried only after its own explicit confirmation."""
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions-lost-response")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Partner sync")
        terminal.send(b"r")
        ready(terminal, "Your answer now · Not answered")
        terminal.send(b"ay")
        terminal.until(lambda: "Calendar did not confirm the outcome" in terminal.text())
        require("[r Check Calendar]" in terminal.text(), "unknown outcome has no read-only check")
        frame(frames, terminal, "rsvp-unknown")
        terminal.send(b"r")
        terminal.until(lambda: "Confirmed: Accepted · Partner sync" in terminal.text())
        require(writes(owned) == 1, "the check resent the answer")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    terminal = start(binary, owned, fixture, scenario="calendar-prewrite-unavailable")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Focus block")
        terminal.send(b"D")
        ready(terminal, "It has no guests, so no email is sent")
        terminal.send(b"y")
        terminal.until(lambda: "Calendar did not confirm the outcome" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "Delete unconfirmed · it may already be done" in terminal.text())
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    require(writes(owned) == 1, "an unavailable provider recorded a delete")
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Focus block")
        terminal.send(b"D")
        terminal.until(lambda: "A delete of this event is saved but unconfirmed" in terminal.text())
        frame(frames, terminal, "delete-pending-after-restart")
        terminal.send(b"r")
        terminal.until(lambda: "Calendar still shows the event unchanged" in terminal.text())
        terminal.send(CTRL_R)
        terminal.until(lambda: "Send the identical request once more?" in terminal.text())
        require(writes(owned) == 1, "retry was sent before its own confirmation")
        frame(frames, terminal, "delete-retry-confirm")
        terminal.send(b"y")
        terminal.until(lambda: "Deleted · Focus block" in terminal.text())
        require(writes(owned) == 2 and stored(owned, "fixture-focus")["status"] == "cancelled",
                "the identical retry did not delete exactly once")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "unknown-reconcile-restart-retry", "writes": writes(owned)}


def permissions(binary, directory, frames):
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions-readonly")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Roadmap")
        require("[D Delete]" not in selected(terminal), "an unavailable delete is offered on the selected row")
        terminal.send(b"D")
        terminal.until(lambda: "has not allowed Omagma to change Calendar" in terminal.text())
        require("[Enter Show how to enable]" in terminal.text(), "missing permission has no way forward")
        frame(frames, terminal, "delete-missing-permission")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Permissions" in terminal.text() and "terminal-auth authorize" in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text())
        clear_filter(terminal)
        pick(terminal, "Company day")
        terminal.send(b"D")
        terminal.until(lambda: "This calendar is read-only for you" in terminal.text())
        terminal.send(b"\x1b")
        require(writes(owned) == 0, "a refused action wrote Calendar")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "missing-write-permission-and-read-only", "writes": 0}


def narrow(binary, directory, captures, frames):
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions", no_color=True)
    try:
        terminal.resize(40, 12)
        terminal.until(lambda: len(terminal.screen.lines()[0]) <= 40 and terminal.ready())
        terminal.send(b"C")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text() and "Loading" not in terminal.text())
        pick(terminal, "Partner")
        terminal.send(b"r")
        terminal.until(lambda: "( ) Accept · a" in terminal.text() and "Checking" not in terminal.text())
        terminal.send(b"a")
        terminal.until(lambda: "(•) Accept · a" in terminal.text() and "[y Accept" in terminal.text())
        require("a/m/x Choose · y Send" in terminal.text(), "narrow chooser lost its keys")
        capture(terminal, captures, "calendar-rsvp-narrow-mono")
        frame(frames, terminal, "rsvp-narrow-40x12")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        clear_filter(terminal)
        pick(terminal, "Roadmap")
        terminal.send(b"D")
        terminal.until(lambda: "Email 2 guests" in terminal.text() and "Checking" not in terminal.text())
        frame(frames, terminal, "delete-narrow-40x12")
        terminal.send(b"\x1b")
        require(writes(owned) == 0, "the narrow dialogs wrote Calendar")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "narrow-40x12-mono", "writes": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--frames-dir", type=Path, help="write plain-text frames of the dialogs")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-calendar-actions-") as temp:
        root = Path(temp)
        results = []
        for name, run in (("main", lambda d: organizer_and_invitations(binary, d, args.capture_dir, args.frames_dir)),
                          ("conflict", lambda d: conflict(binary, d, args.frames_dir)),
                          ("uncertain", lambda d: uncertain(binary, d, args.frames_dir)),
                          ("permissions", lambda d: permissions(binary, d, args.frames_dir)),
                          ("narrow", lambda d: narrow(binary, d, args.capture_dir, args.frames_dir))):
            directory = root / name
            directory.mkdir()
            results.append(run(directory))
    receipt = {"build": read_build_info(binary), "cases": results}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS Calendar delete/RSVP TUI: dialogs, explicit choices, If-Match conflicts, "
          "read-only recovery, restart retry, permissions and 40x12 mono; no mail sent")


if __name__ == "__main__":
    main()
