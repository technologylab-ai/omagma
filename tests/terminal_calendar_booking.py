#!/usr/bin/env python3
"""Attendee-free appointments: real Calendar review/import, synthetic providers only."""
import argparse
import base64
import json
from pathlib import Path
import sys
import tempfile
from datetime import datetime, timezone

from terminal_calendar import Invitations, provider_state, confirmation
from terminal_integration import ACCOUNTS, Client, ROOT, require
from terminal_mouse import MouseTerminal, click, point
from terminal_calendar_tui import CalendarScreen
from terminal_theme_picker import focused
from terminal_html import screen_capture

TITLE = "Fictional haircut booking"
UID = "barber-booking@example.test"
NOTE = "Booked service. Please arrive on time."
BOOKING_URL = "https://bookings.example.test/manage"
IMPORTED_NOTE = NOTE + "\n\nJoin: " + BOOKING_URL


def fixture_setup(binary, directory, notes=NOTE):
    fixture = Invitations(directory)
    source_file = fixture.root / "accounts/personal.json"
    data = json.loads(source_file.read_text())
    message = data["messages"][0]
    raw = (ROOT / "tests/fixtures/terminal/calendar/booking-no-attendees.ics").read_text()
    raw = "\r\n".join(raw.splitlines()) + "\r\n"
    raw = raw.replace("12345678-1234-4234-9234-123456789abc", UID)
    raw = raw.replace("DESCRIPTION:" + NOTE, "DESCRIPTION:" + notes.replace("\\", "\\\\").replace("\n", "\\n"))
    part = next(p for p in message["payload"]["parts"] if p["mimeType"] == "text/calendar")
    part["body"] = {"size": len(raw.encode()), "data": base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")}
    message["id"] = "booking-confirmation"
    message["threadId"] = "booking-thread"
    message["snippet"] = TITLE
    next(h for h in message["payload"]["headers"] if h["name"] == "Subject")["value"] = TITLE
    data["messages"] = [message]
    source_file.write_text(json.dumps(data) + "\n")
    directory = directory / "client"
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.list", label="INBOX")
        client.request("mail.read", messageId="booking-confirmation")
        notice = client.request("invitation.inspect", messageId="booking-confirmation", cacheOnly=True)
        require(notice["attendeeCount"] == 0 and not notice["canReply"], "booking acquired an RSVP identity")
    return fixture, directory


def check_provider(binary, directory, fixture, writes):
    with Client(binary, directory, extra=fixture.options()) as client:
        state = provider_state(client)
        require(state["writes"] == writes, "booking Calendar write count changed unexpectedly")
        require(client.request("cache.stats")["fixtureSends"] == 0, "booking action sent RSVP mail")


def cli_case(binary, directory, lost=False):
    fixture, directory = fixture_setup(binary, directory)
    with Client(binary, directory, scenario="calendar-lost-response" if lost else None, extra=fixture.options()) as client:
        args = {"calendarId": ACCOUNTS[0], "messageId": "booking-confirmation"}
        plan = client.request("calendar.invitation-plan", **args)
        require(plan["decision"] == "import_missing" and not plan["timeError"], "attendee-free booking cannot be planned")
        require(plan["resolved"]["start"]["value"] == int(datetime(2026, 11, 10, 9, 15, tzinfo=timezone.utc).timestamp()*1000), "booking start was shifted")
        require(plan["resolved"]["end"]["value"] == int(datetime(2026, 11, 10, 10, 5, tzinfo=timezone.utc).timestamp()*1000), "booking end was shifted")
        blocked = client.request("invitation.reply", messageId="booking-confirmation", status="accepted", operationId="no-booking-rsvp", ok=False)
        require(blocked["code"] == "NotAnAttendee", "booking authorized RSVP")
        refused = client.request("calendar.review", calendarId="fixture-shared-team", messageId="booking-confirmation", operationId="booking-wrong-target", ok=False)
        require(refused["code"] == "CalendarBookingPrimaryRequired", "personal copy permitted an unverified secondary owner")
        review = client.request("calendar.review", **args, operationId="booking-reviewed")
        require(review["calendarOrganizer"] == ACCOUNTS[0] and review["invitation"]["organizer"] != ACCOUNTS[0], "review lost actual organizer or original provenance")
        require(provider_state(client)["writes"] == 0, "planning or review wrote the event")
        client.restart()
        result = client.request("calendar.import", **confirmation(review))
        if lost:
            require(result["state"] == "unknown", "lost booking response pretended to be final")
            require(provider_state(client)["writes"] == 1, "lost response did not preserve the one actual import")
            client.restart()
            with Client(binary, directory, scenario="calendar-readonly", extra=fixture.options()) as read_only:
                result = read_only.request("calendar.reconcile", **confirmation(review))
            require(result["state"] == "applied" and result["reconciled"], "unknown booking import failed read-only reconciliation")
        require(result["state"] == "applied", "saved booking review did not survive restart")
        detail = client.request("calendar.event", calendarId=ACCOUNTS[0], eventId=result["providerId"])["event"]
        require(detail["summary"] == TITLE and detail["location"] == "12 Example Street" and detail["description"] == IMPORTED_NOTE, "booking details were lost")
        require(not detail.get("attendees") and detail["organizer"] == ACCOUNTS[0], "booking must be a personal appointment with no guests")
        require(detail.get("private_copy") is False, "fixture must not invent an unrequested privateCopy flag")
        again = client.request("calendar.invitation-plan", **args)
        require(again["decision"] == "existing", "booking source UID did not prevent a duplicate")
        client.request("calendar.apply", **confirmation(review))
        require(provider_state(client)["writes"] == 1 and client.request("cache.stats")["fixtureSends"] == 0, "booking was duplicated or sent mail")
    print("PASS booking CLI: exact embedded-zone times, durable review/import, no guests, strict RSVP, UID duplicate check")


def capture(terminal, directory, name):
    if directory:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / (name + ".json")).write_text(json.dumps(screen_capture(terminal)) + "\n")


def tui_case(binary, directory, mono=False, lost=False, rejected=False, long_notes=False, captures=None, direct=False):
    notes = "\n".join(f"Long booking note line {i:03d}: read this detail." for i in range(36)) if long_notes else NOTE
    fixture, directory = fixture_setup(binary, directory, notes)
    scenario = "calendar-lost-response" if lost else "calendar-booking-rejected" if rejected else None
    terminal = MouseTerminal(binary, directory, extra=fixture.options() + (("--fixture-scenario", scenario) if scenario else ()), columns=120, rows=36, screen_type=CalendarScreen,
                             environment={"TZ": "Europe/Vienna", "NO_COLOR": "1" if mono else None, "COLORTERM": "truecolor"})
    tag = "mono" if mono else "unknown" if lost else "rejected" if rejected else "notes" if long_notes else "ready"
    try:
        terminal.until(lambda: TITLE in terminal.text())
        terminal.gap(.2)
        if direct:
            terminal.send(b"A")
        else:
            terminal.send(b"I")
            terminal.until(lambda: "Booked appointment" in terminal.text() and "[A Add to calendar]" in terminal.text())
            click(terminal, *point(terminal, "[A Add to calendar]"))
        ready = "Adds this as your own appointment. No reply is sent."
        terminal.until(lambda: ready in terminal.text() or "Read to the end of the notes" in terminal.text())
        shown = terminal.text()
        require("[Enter Review]" not in shown and "Calendar ID" not in shown and "UID" not in shown, "booking retained duplicate review/protocol wall")
        require("Calendar   Primary" in shown and ACCOUNTS[0] in shown and "Booked via" in shown, "compact card lost destination/provenance")
        require("2026-11-10 09:15–10:05 UTC" in shown, "card did not use exact reviewed times in the target zone")
        require("Enter Activate" not in terminal.text(), "unfocused Enter hint implies an action")
        check_provider(binary, directory, fixture, 0)
        terminal.send(b"\r")
        terminal.gap(.1)
        check_provider(binary, directory, fixture, 0)
        if not mono:
            date = terminal.screen.locate("2026-11-10")
            calendar = terminal.screen.locate("Calendar   Primary")
            require(date and calendar and terminal.screen.styles[date["row"]][date["column"]][0] != terminal.screen.styles[calendar["row"]][calendar["column"]][0], "booking card has no semantic color distinction")
        if long_notes:
            terminal.send(b"y")
            click(terminal, *point(terminal, "[y Add appointment]"))
            terminal.gap(.1)
            check_provider(binary, directory, fixture, 0)
            terminal.send(b"\x04" * 20)
            terminal.until(lambda: ready in terminal.text())
        capture(terminal, captures, tag)
        # A too-small viewport cannot submit, including after a previously full review.
        terminal.resize(40, 12)
        terminal.gap(.2)
        terminal.until(lambda: "Make the window larger" in terminal.text())
        terminal.send(b"y\r")
        terminal.gap(.1)
        check_provider(binary, directory, fixture, 0)
        terminal.resize(120, 36)
        terminal.gap(.2)
        if long_notes:
            terminal.send(b"\x04" * 20)
        terminal.until(lambda: ready in terminal.text())
        terminal.send(b"\t")
        terminal.until(lambda: focused(terminal, "[y Add appointment]", no_color=mono))
        terminal.send(b"\x1b[Z")
        terminal.until(lambda: focused(terminal, "[Esc Cancel]", no_color=mono))
        terminal.send(b"\t\t\r")
        if long_notes:
            terminal.send(b"\x04" * 20)
        terminal.until(lambda: "Calendar ID" in terminal.text() or "Source time" in terminal.text())
        terminal.send(b"\x04" * 8)
        terminal.until(lambda: "Organizer" in terminal.text() and "(you)" in terminal.text())
        capture(terminal, captures, tag + "-details")
        terminal.send(b"v")
        terminal.gap(.1)
        if long_notes:
            terminal.send(b"\x04" * 20)
            terminal.until(lambda: ready in terminal.text())
        if mono:
            terminal.send(b"y")
        else:
            click(terminal, *point(terminal, "[y Add appointment]"))
        if rejected:
            terminal.until(lambda: "Not added" in terminal.text() and "Google Calendar:" in terminal.text())
            require("organizer or an attendee" in " ".join(terminal.text().split()), "Google rejection explanation was dropped")
            if not mono:
                error = terminal.screen.locate("Not added")
                require(error and tuple(terminal.screen.styles[error["row"]][error["column"]][0]) == ("rgb", 255, 112, 112), "definitive rejection must use the error/red theme role")
            capture(terminal, captures, "provider-rejection")
            terminal.send(b"yr\r")
            terminal.gap(.2)
            check_provider(binary, directory, fixture, 0)
            terminal.send(b"v\x04\x04\x04")
            terminal.until(lambda: "participantIsNeitherOrganizerNorAttendee" in terminal.text())
        else:
            if lost:
                terminal.until(lambda: "[r Check Calendar]" in terminal.text())
                check_provider(binary, directory, fixture, 1)
                capture(terminal, captures, "unknown-result")
                terminal.send(b"y")
                terminal.gap(.1)
                check_provider(binary, directory, fixture, 1)
                click(terminal, *point(terminal, "[r Check Calendar]"))
            terminal.until(lambda: "Added to your primary calendar. No email sent." in terminal.text())
            require("[y Add appointment]" not in terminal.text(), "completed card still offers Add")
            capture(terminal, captures, "added-" + tag)
            terminal.resize(40, 12)
            terminal.gap(.2)
            terminal.until(lambda: "Make the window larger" in terminal.text() and "[Esc Close]" in terminal.text())
            require("[Esc Cancel]" not in terminal.text() and "[y Add appointment]" not in terminal.text(), "small completed card implies undo or another Add")
            terminal.send(b"y")
            terminal.gap(.1)
            check_provider(binary, directory, fixture, 1)
            terminal.resize(120, 36)
            terminal.gap(.2)
            terminal.send(b"\x1b")
            terminal.until(lambda: "[Esc Done]" not in terminal.text())
            terminal.send(b"A")
            terminal.until(lambda: "Already in your primary calendar. Nothing to add." in terminal.text())
            require("[y Add appointment]" not in terminal.text(), "same booking offered duplicate addition")
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    check_provider(binary, directory, fixture, 0 if rejected else 1)
    print("PASS booking modal:", tag, "one confirmation, exact target/time, semantic color, details, keyboard/mouse, no duplicate/reply")


def legacy_pending_case(binary, old_binary, directory):
    """Reconcile exact prior-candidate unknown bytes; never rewrite/replay them."""
    fixture, directory = fixture_setup(old_binary, directory)
    with Client(old_binary, directory, scenario="calendar-lost-response", extra=fixture.options()) as old:
        review = old.request("calendar.review", calendarId=ACCOUNTS[0], messageId="booking-confirmation", operationId="legacy-booking-unknown")
        result = old.request("calendar.import", **confirmation(review))
        require(result["state"] == "unknown" and provider_state(old)["writes"] == 1, "old candidate did not seed an actual unknown receipt")
    with Client(binary, directory, extra=fixture.options()) as client:
        plan = client.request("calendar.invitation-plan", calendarId=ACCOUNTS[0], messageId="booking-confirmation")
        require(plan["recovery"]["calendarOrganizer"] == "host@example.test", "old review organizer was rewritten to the new owner")
        result = client.request("calendar.reconcile", **confirmation(review))
        require(result["state"] == "applied" and result["reconciled"], "old frozen import could not be reconciled")
        client.request("calendar.apply", **confirmation(review))
        require(provider_state(client)["writes"] == 1, "old unknown was replayed under new semantics")
        event = client.request("calendar.event", calendarId=ACCOUNTS[0], eventId=result["providerId"])["event"]
        require(event["organizer"] == "host@example.test", "reconciliation disguised the old provider organizer")
        require(client.request("cache.stats")["fixtureSends"] == 0, "old receipt reconciliation sent mail")
    print("PASS booking legacy pending: exact previous payload/review preserved, read-only reconciliation, one original write")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--captures", type=Path)
    parser.add_argument("--old-binary", type=Path, help="Optional prior candidate for immutable unknown-receipt upgrade coverage")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-booking-") as tmp:
        root=Path(tmp);binary=args.binary.resolve()
        if args.old_binary:
            legacy_pending_case(binary, args.old_binary.resolve(), root/"legacy")
        cli_case(binary, root/"cli")
        cli_case(binary, root/"cli-lost", True)
        tui_case(binary, root/"tui", captures=args.captures, direct=True)
        tui_case(binary, root/"mono", True, captures=args.captures)
        tui_case(binary, root/"tui-lost", lost=True, captures=args.captures)
        tui_case(binary, root/"tui-rejected", rejected=True, captures=args.captures)
        tui_case(binary, root/"tui-notes", long_notes=True, captures=args.captures)


if __name__ == "__main__":main()
