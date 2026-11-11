#!/usr/bin/env python3
"""Delete and RSVP from the Calendar view through owned PTYs; synthetic only.

Every write needs a dialog, an explicit choice and a separate confirmation:
no single key from the Calendar view changes Calendar. Uses the persistent
synthetic Calendar provider; no desktop windows, accounts, OAuth or network.
Run under this repository's cooperative measurement reservation.
"""
from __future__ import annotations

import argparse
import datetime
import json
from pathlib import Path
import tempfile
import time
import types

from build_info import read_build_info
from terminal_calendar import Invitations
from terminal_calendar_tui import capture, start, wait_calendar
from terminal_integration import ACCOUNTS, fixture_calendar_writes, require
from terminal_mouse import point, report
from terminal_theme_picker import focused

SHIFT_TAB = b"\x1b[Z"
CTRL_R = b"\x12"
CTRL_P = b"\x10"


def writes(owned):
    return fixture_calendar_writes(types.SimpleNamespace(directory=owned))


def provider_state(owned):
    for path in (owned / "cache").rglob("calendar-provider-fixture.json"):
        state = json.loads(path.read_text())
        if state["account"] == ACCOUNTS[0]:
            return state
    return None


def stored(owned, event_id):
    for entry in (provider_state(owned) or {"events": []})["events"]:
        if entry["value"]["id"] == event_id:
            return entry["value"]
    return None


def sent(owned):
    """Mutating requests as they reached the synthetic wire, oldest first."""
    return (provider_state(owned) or {}).get("requests", [])


def require_sent(owned, index, method, event_id, if_match, send_updates):
    request = sent(owned)[index]
    require(request["method"] == method and request["eventId"] == event_id, f"wire request {index} addressed {request}")
    require(request["ifMatch"] == if_match, f"wire request {index} carried If-Match {request['ifMatch']}, not {if_match}")
    require(request["query"] == "sendUpdates=" + send_updates, f"wire request {index} sent {request['query']}")


def settle(terminal):
    """A confirm acts only a moment after a step became visible."""
    terminal.gap(.7)


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
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Declined · Partner sync" in terminal.text())
        terminal.until(lambda: "×" in selected(terminal))
        require(writes(owned) == 1, "a confirmed RSVP did not write exactly once")
        answer = [a for a in stored(owned, "fixture-invite")["attendees"] if a["email"] == ACCOUNTS[0]]
        require(len(answer) == 1 and answer[0]["responseStatus"] == "declined", "the provider kept the old answer")
        require("Google was asked to email the organizer" in terminal.text() and "organizer emailed" not in terminal.text(),
                "the status claims an email as a fact")
        require_sent(owned, 0, "PATCH", "fixture-invite", '"fixture-seed-fixture-invite"', "all")
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
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Deleted · Roadmap review" in terminal.text())
        terminal.until(lambda: "Roadmap" not in selected(terminal))
        require(writes(owned) == 2 and stored(owned, "fixture-hosted")["status"] == "cancelled",
                "the confirmed delete did not reach the provider once")
        require_sent(owned, 1, "DELETE", "fixture-hosted", '"fixture-seed-fixture-hosted"', "none")
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
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Deleted series · Standup" in terminal.text())
        require(writes(owned) == 3 and stored(owned, "fixture-standup")["status"] == "cancelled",
                "the series delete did not target the series once")
        require_sent(owned, 2, "DELETE", "fixture-standup", '"fixture-seed-fixture-standup"', "all")
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
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Your response · Tentative" in terminal.text())
        office = [a for a in stored(owned, "fixture-office")["attendees"] if a["email"] == ACCOUNTS[0]]
        require(writes(owned) == 4 and office[0]["responseStatus"] == "tentative", "series answer missing")
        require_sent(owned, 3, "PATCH", "fixture-office", '"fixture-seed-fixture-office"', "none")
        # Back in the agenda every other occurrence shows the series answer.
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text() and "Up to date" in terminal.text())
        terminal.until(lambda: "~  ↻ Office hours" in terminal.text() and "?  ↻ Office hours" not in terminal.text())
        frame(frames, terminal, "rsvp-series-agenda")
        # Someone else's event without a guest entry: removed here only.
        clear_filter(terminal)
        pick(terminal, "Daily review")
        terminal.send(b"D")
        ready(terminal, "Organized by host@example.test")
        require("Remove from your calendar?" in terminal.text() and "[y Remove from my calendar]" in terminal.text(),
                "a copy of someone else's event is presented as a delete for everyone")
        frame(frames, terminal, "remove-copy")
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Removed from Personal · Daily review" in terminal.text())
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
        settle(terminal)
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
        # An answer and y typed together: y waits until the answer's effect
        # has been on screen for a moment, then confirms.
        terminal.send(b"ay")
        terminal.until(lambda: "press y again" in terminal.text())
        require(writes(owned) == 0, "y typed with the answer sent it before its consequence was shown")
        settle(terminal)
        terminal.send(b"y")
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
        settle(terminal)
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
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Deleted · Focus block" in terminal.text())
        require(writes(owned) == 2 and stored(owned, "fixture-focus")["status"] == "cancelled",
                "the identical retry did not delete exactly once")
        # Both attempts sent the identical conditional request (the first
        # reached the wire before Calendar answered 503).
        require(len(sent(owned)) == 3, "an extra request reached the wire")
        for index in (1, 2):
            require_sent(owned, index, "DELETE", "fixture-focus", '"fixture-seed-fixture-focus"', "none")
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
        require("Accept · a" in terminal.text() and "[y Accept" in terminal.text() and "[Esc]" in terminal.text(), "narrow chooser lost its keys")
        capture(terminal, captures, "calendar-rsvp-narrow-mono")
        frame(frames, terminal, "rsvp-narrow-40x12")
        # At 40x12 the title stays pinned above the choices and the
        # consequence above the button: the answer can really be sent.
        flat = " ".join(terminal.text().split())
        require("Partner sync" in flat and "Google emails your answer" in flat, "the 40x12 RSVP hides the event or what happens")
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Accepted · Partner sync" in terminal.text())
        require_sent(owned, 0, "PATCH", "fixture-invite", '"fixture-seed-fixture-invite"', "all")
        clear_filter(terminal)
        pick(terminal, "Roadmap")
        terminal.send(b"D")
        terminal.until(lambda: "Email 2 guests" in terminal.text() and "Checking" not in terminal.text())
        frame(frames, terminal, "delete-narrow-40x12")
        terminal.send(b"j\r")
        terminal.until(lambda: "[y Delete, no email]" in terminal.text())
        flat = " ".join(terminal.text().split())
        require("Roadmap review" in flat and "without emailing 2 guests" in flat, "the 40x12 delete hides the event or what happens")
        frame(frames, terminal, "delete-narrow-40x12-chosen")
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Deleted · Roadmap review" in terminal.text())
        require(writes(owned) == 2, "the 40x12 dialogs did not each write once")
        require_sent(owned, 1, "DELETE", "fixture-hosted", '"fixture-seed-fixture-hosted"', "none")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "narrow-40x12-mono", "writes": 2}


def guards(binary, directory, frames):
    """y, Enter, clicks and the wheel confirm only a dialog the user sees."""
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Focus block")
        # y typed right after D never confirms a dialog not yet (or only just) shown.
        for delay in (0, .02, .1, .25):
            terminal.send(b"D")
            time.sleep(delay)
            terminal.send(b"y")
            ready(terminal, "It has no guests, so no email is sent")
            terminal.gap(.3)
            require(writes(owned) == 0 and "Delete event?" in terminal.text(), f"y typed {delay}s after D deleted the event")
            terminal.send(b"\x1b")
            terminal.until(lambda: "Nothing was changed" in terminal.text())
        terminal.send(b"D")
        ready(terminal, "It has no guests, so no email is sent")
        # The wheel scrolls; Enter then still acts on Cancel.
        x, y = point(terminal, "It has no guests")
        for _ in range(3):
            report(terminal, x, y, button=65)
        terminal.gap(.3)
        require(focused(terminal, "[Esc Cancel]"), "the wheel moved the focus off Cancel")
        terminal.send(b"\r")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        require(writes(owned) == 0, "wheel and Enter deleted the event")
        # A held y (key repeat) never confirms: each early press restarts the wait.
        terminal.send(b"D")
        ready(terminal, "It has no guests, so no email is sent")
        held = time.monotonic()
        while time.monotonic() - held < 1.7:
            terminal.send(b"y")
            terminal.gap(.03)
        terminal.gap(.3)
        require(writes(owned) == 0, "holding y deleted the event")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        # A changed choice is a different write: shown and settled first.
        clear_filter(terminal)
        pick(terminal, "Partner")
        terminal.send(b"r")
        ready(terminal, "Your answer now")
        terminal.send(b"a")
        terminal.until(lambda: "[y Accept" in terminal.text())
        settle(terminal)
        terminal.send(b"xy")
        terminal.gap(.6)
        require(writes(owned) == 0, "y typed with a changed answer sent it")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        clear_filter(terminal)
        pick(terminal, "Roadmap")
        terminal.send(b"D")
        ready(terminal, "Email 2 guests")
        terminal.send(b"j\r")
        terminal.until(lambda: "[y Delete, no email]" in terminal.text())
        settle(terminal)
        terminal.send(b"k\ry")
        terminal.gap(.6)
        require(writes(owned) == 0, "y typed with a changed email choice deleted the event")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        clear_filter(terminal)
        pick(terminal, "Focus block")
        # Too small for Calendar: D opens nothing and y sends nothing.
        terminal.resize(24, 10)
        terminal.gap(.5)
        terminal.send(b"D")
        terminal.gap(.5)
        terminal.send(b"y")
        terminal.gap(1)
        require(writes(owned) == 0, "keys on a terminal too small to draw the dialog wrote Calendar")
        terminal.resize(140, 38)
        terminal.until(lambda: "Calendar · Agenda" in terminal.text())
        terminal.gap(.3)
        require("Delete event?" not in terminal.text(), "a dialog opened while it could not be drawn")
        # Too short to show the event, what happens and the button together.
        clear_filter(terminal)
        pick(terminal, "Roadmap")
        terminal.resize(40, 10)
        terminal.gap(.5)
        terminal.send(b"D")
        terminal.until(lambda: "Checking" not in terminal.text() and "Email 2 guests" in terminal.text())
        terminal.send(b"j\r")
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Enlarge the terminal" in terminal.text())
        frame(frames, terminal, "delete-short-refused")
        require(writes(owned) == 0, "a confirm on a dialog shown only in part wrote Calendar")
        terminal.send(b"\x1b")
        terminal.resize(140, 38)
        terminal.until(lambda: "Calendar · Agenda" in terminal.text())
        # Ctrl+P away from an event offers no Delete/RSVP.
        terminal.send(b"g")
        terminal.until(lambda: "Calendar · Calendars" in terminal.text())
        terminal.send(CTRL_P)
        terminal.until(lambda: "Delete event · D · select an event first" in terminal.text())
        terminal.send(b"j" * 25 + b"\r")
        terminal.until(lambda: "Select an event in the agenda" in terminal.text())
        require("Delete event?" not in terminal.text() and writes(owned) == 0, "Ctrl+P opened a delete for an unseen event")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "confirm-guards", "writes": 0}


def series_facts(binary, directory, frames):
    """A changed occurrence and its series each show their own facts; the
    series asks again whom to email and deletes the series itself."""
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Standup with partners")
        terminal.send(b"D")
        ready(terminal, "You organize it · 3 guests")
        require("Email 3 guests a cancellation" in terminal.text(), "the occurrence's own guests are not offered")
        terminal.send(SHIFT_TAB + b"\r")
        terminal.until(lambda: "You organize it · 1 guest" in terminal.text() and "Repeats daily · from" in terminal.text())
        require("Email 1 guest a cancellation" in terminal.text() and "3 guests" not in terminal.text(),
                "the series choice still shows the occurrence's facts")
        require("[y Delete…]" in terminal.text(), "the email choice was not asked again for the series")
        frame(frames, terminal, "delete-series-facts")
        terminal.send(b"\t\r")
        terminal.until(lambda: "[y Delete series & email 1 guest]" in terminal.text())
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Deleted series · Standup" in terminal.text())
        require(writes(owned) == 1, "the series delete did not write exactly once")
        require_sent(owned, 0, "DELETE", "fixture-standup", '"fixture-seed-fixture-standup"', "all")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "series-own-facts", "writes": writes(owned)}


def pending_series(binary, directory, frames):
    """An unconfirmed series delete is found from another occurrence, and a
    double click on Retry never sends twice."""
    fixture = Invitations(directory)
    owned = directory / "client"
    # Seed the synthetic calendar with the action events first.
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.finish()
    finally:
        terminal.close()
    terminal = start(binary, owned, fixture, scenario="calendar-prewrite-unavailable")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Standup")
        terminal.send(b"D")
        ready(terminal, "This event only")
        terminal.send(SHIFT_TAB + b"\r" + b"\t\r")
        terminal.until(lambda: "[y Delete series & email 1 guest]" in terminal.text())
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Calendar did not confirm the outcome" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "Delete unconfirmed" in terminal.text())
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    require(writes(owned) == 0, "the unavailable provider recorded a write")
    terminal = start(binary, owned, fixture, scenario="calendar-actions", columns=40, rows=12)
    try:
        terminal.until(lambda: terminal.ready())
        terminal.send(b"C")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text() and "Loading" not in terminal.text())
        # Another day's occurrence: the series delete covers it too.
        pick(terminal, "Standup")
        terminal.send(b"j")
        terminal.gap(.3)
        terminal.send(b"D")
        terminal.until(lambda: "whole series is saved but unconfirmed" in " ".join(terminal.text().split()))
        frame(frames, terminal, "series-pending-from-sibling")
        require(len(sent(owned)) == 1, "the unconfirmed series delete is not the only request on the wire")
        require_sent(owned, 0, "DELETE", "fixture-standup", '"fixture-seed-fixture-standup"', "all")
        terminal.send(b"r")
        terminal.until(lambda: "Retry" in terminal.text())
        x, y = point(terminal, "[Ctrl+R Retry]")
        # A double click on Retry opens its confirmation once and never confirms it.
        report(terminal, x + 3, y)
        report(terminal, x + 3, y, release=True)
        terminal.gap(.15)
        report(terminal, x + 3, y)
        report(terminal, x + 3, y, release=True)
        terminal.gap(1.5)
        frame(frames, terminal, "retry-double-click")
        require(len(sent(owned)) == 1 and writes(owned) == 0, "a double click on Retry sent the delete again")
        require(stored(owned, "fixture-standup")["status"] == "confirmed", "a double click deleted the series")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "series-pending-and-double-click", "writes": writes(owned)}


def midnight_ms():
    now = datetime.datetime.now(datetime.UTC)
    return int(datetime.datetime(now.year, now.month, now.day, tzinfo=datetime.UTC).timestamp() * 1000)


def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def provider_path(owned):
    for path in (owned / "cache").rglob("calendar-provider-fixture.json"):
        if json.loads(path.read_text())["account"] == ACCOUNTS[0]:
            return path
    return None


def status_line(terminal):
    return terminal.screen.lines()[-1]


def meeting_card(binary, directory, frames):
    """A due meeting card never covers a Delete/RSVP dialog: it waits (the
    status says so) while the dialog is open; once focused with M it covers
    the dialog and y does nothing there. Delete, RSVP, retry and archive."""
    fixture = Invitations(directory)
    owned = directory / "client"
    # Five minutes before Roadmap review (11:00): its card is due.
    (fixture.root / "calendar-notification-now-ms").write_text(str(midnight_ms() + 10 * 3600000 + 55 * 60000) + "\n")

    def open_calendar(terminal):
        terminal.send(b"C")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text() and "Loading" not in terminal.text(), seconds=15)
        terminal.until(lambda: "Starts in" in terminal.text(), seconds=12)
        terminal.gap(.2)

    def deferred(terminal):
        require("Starts in" not in terminal.text() and "Upcoming meeting" not in terminal.text(),
                "the meeting card was drawn over the dialog")
        require("Meeting due · M shows it" in status_line(terminal), "the held-back meeting is not announced")

    terminal = start(binary, owned, fixture, scenario="calendar-actions", columns=80, rows=24)
    try:
        open_calendar(terminal)
        # RSVP: the email toggle, the consequence and the button stay in view.
        pick(terminal, "Partner")
        terminal.send(b"r")
        ready(terminal, "Your answer now")
        terminal.send(b"a")
        terminal.until(lambda: "[y Accept" in terminal.text())
        deferred(terminal)
        require("Google emails your answer" in " ".join(terminal.text().split()), "the RSVP consequence is hidden")
        frame(frames, terminal, "rsvp-meeting-deferred")
        # M brings the card over the dialog: y now acts on the card, never
        # on the hidden dialog.
        terminal.send(b"M")
        terminal.until(lambda: "keys here" in terminal.text())
        settle(terminal)
        terminal.send(b"y")
        terminal.gap(.6)
        require(writes(owned) == 0, "y wrote through a meeting card covering the dialog")
        frame(frames, terminal, "rsvp-meeting-focused")
        terminal.send(b"\x1b")
        terminal.until(lambda: "keys here" not in terminal.text() and "[y Accept" in terminal.text())
        # Shown whole again: the wait starts over, then y sends.
        terminal.send(b"y")
        terminal.until(lambda: "press y again" in terminal.text())
        require(writes(owned) == 0, "y confirmed the moment the dialog reappeared")
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Accepted · Partner sync" in terminal.text())
        require_sent(owned, 0, "PATCH", "fixture-invite", '"fixture-seed-fixture-invite"', "all")
        # Delete with the card due.
        clear_filter(terminal)
        pick(terminal, "Focus block")
        terminal.send(b"D")
        ready(terminal, "It has no guests, so no email is sent")
        deferred(terminal)
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Deleted · Focus block" in terminal.text())
        require_sent(owned, 1, "DELETE", "fixture-focus", '"fixture-seed-fixture-focus"', "none")
        # The card returns once the dialog is closed.
        terminal.until(lambda: "Starts in" in terminal.text(), seconds=12)
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    # Retry and archive confirmations under the due card.
    terminal = start(binary, owned, fixture, scenario="calendar-prewrite-unavailable", columns=80, rows=24)
    try:
        open_calendar(terminal)
        pick(terminal, "Daily review")
        terminal.send(b"D")
        ready(terminal, "Organized by host@example.test")
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Calendar did not confirm the outcome" in terminal.text())
        terminal.send(b"r")
        terminal.until(lambda: "Ctrl+R" in terminal.text() and "Checking" not in terminal.text())
        terminal.send(CTRL_R)
        terminal.until(lambda: "Send the identical request once more?" in terminal.text())
        deferred(terminal)
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: len(sent(owned)) == 4)
        require_sent(owned, 3, "DELETE", "fixture-daily_" + str(midnight_ms() + 16 * 3600000), sent(owned)[2]["ifMatch"], "none")
        terminal.until(lambda: "Ctrl+D" in terminal.text() and "Sending" not in terminal.text())
        terminal.send(b"\x04")
        terminal.until(lambda: "Stop tracking this unconfirmed delete?" in terminal.text())
        deferred(terminal)
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Stopped tracking the unconfirmed delete" in terminal.text())
        frame(frames, terminal, "archive-meeting-deferred")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "meeting-card-defers", "writes": writes(owned)}


def split_series(binary, directory, frames):
    """A Google split series ID (`abc_R…`): an unconfirmed series delete is
    found from another occurrence by the provider series, the lookup is
    bounded, and the dialog resumes it."""
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.finish()
    finally:
        terminal.close()
    path = provider_path(owned)
    state = json.loads(path.read_text())
    begin = midnight_ms() + 15 * 3600000
    for series_id, summary in (("weeklysync", "Plain weekly sync"), ("weeklysync_R20261111T150000", "Imported weekly sync")):
        state["events"].append({"calendar_id": ACCOUNTS[0], "value": {
            "id": series_id, "iCalUID": series_id + "@example.test", "etag": '"imp-' + series_id + '"', "status": "confirmed",
            "organizer": {"email": ACCOUNTS[0], "self": True}, "summary": summary,
            "attendees": [{"email": ACCOUNTS[0], "self": True, "organizer": True, "responseStatus": "accepted"},
                          {"email": "guest-one@example.test", "responseStatus": "needsAction"}],
            "start": {"dateTime": iso(begin)}, "end": {"dateTime": iso(begin + 1800000)}, "sequence": 0,
            "recurrence": ["RRULE:FREQ=DAILY"]}})
    path.write_text(json.dumps(state))
    terminal = start(binary, owned, fixture, scenario="calendar-prewrite-unavailable")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        pick(terminal, "Imported weekly sync")
        terminal.send(b"D")
        ready(terminal, "This event only")
        terminal.send(SHIFT_TAB + b"\r" + b"\t\r")
        terminal.until(lambda: "[y Delete series & email 1 guest]" in terminal.text())
        settle(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Calendar did not confirm the outcome" in terminal.text())
        terminal.send(b"\x1b")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    require(sent(owned)[-1]["eventId"] == "weeklysync_R20261111T150000", "the split series was not the delete target")
    terminal = start(binary, owned, fixture, scenario="calendar-actions")
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        # The plain series that shares the ID prefix is not held back.
        pick(terminal, "Plain weekly sync")
        terminal.send(b"D")
        ready(terminal, "This event only")
        require("saved but unconfirmed" not in terminal.text(), "another series sharing the ID prefix was held back")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Nothing was changed" in terminal.text())
        clear_filter(terminal)
        # Another occurrence of the split series resumes its unconfirmed delete.
        pick(terminal, "Imported weekly sync")
        terminal.send(b"j")
        terminal.gap(.3)
        reads = json.loads(provider_path(owned).read_text())["reads"]
        terminal.send(b"D")
        terminal.until(lambda: "whole series is saved but unconfirmed" in " ".join(terminal.text().split()))
        terminal.gap(2)
        spent = json.loads(provider_path(owned).read_text())["reads"] - reads
        require(spent <= 6, f"resuming the unconfirmed series delete read Calendar {spent} times")
        frame(frames, terminal, "split-series-pending")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"case": "split-series-pending", "reads": spent}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--frames-dir", type=Path, help="write plain-text frames of the dialogs")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--case", action="append", help="run only this case (repeatable)")
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-calendar-actions-") as temp:
        root = Path(temp)
        results = []
        for name, run in (("main", lambda d: organizer_and_invitations(binary, d, args.capture_dir, args.frames_dir)),
                          ("conflict", lambda d: conflict(binary, d, args.frames_dir)),
                          ("uncertain", lambda d: uncertain(binary, d, args.frames_dir)),
                          ("permissions", lambda d: permissions(binary, d, args.frames_dir)),
                          ("narrow", lambda d: narrow(binary, d, args.capture_dir, args.frames_dir)),
                          ("guards", lambda d: guards(binary, d, args.frames_dir)),
                          ("series-facts", lambda d: series_facts(binary, d, args.frames_dir)),
                          ("pending-series", lambda d: pending_series(binary, d, args.frames_dir)),
                          ("meeting-card", lambda d: meeting_card(binary, d, args.frames_dir)),
                          ("split-series", lambda d: split_series(binary, d, args.frames_dir))):
            if args.case and name not in args.case:
                continue
            directory = root / name
            directory.mkdir()
            results.append(run(directory))
    receipt = {"build": read_build_info(binary), "cases": results}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS Calendar delete/RSVP TUI: dialogs, explicit choices, If-Match conflicts, "
          "read-only recovery, restart retry, permissions, 40x12 mono, confirm guards, "
          "series facts and series pending; no mail sent")


if __name__ == "__main__":
    main()
