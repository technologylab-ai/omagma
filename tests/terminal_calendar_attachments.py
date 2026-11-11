#!/usr/bin/env python3
"""Published .ICS attachments: synthetic Gmail -> review -> personal Calendar import."""
import argparse
import base64
import json
from datetime import date
from pathlib import Path
import sys
import tempfile

from terminal_calendar import Invitations, confirmation, provider_state
from terminal_calendar_booking import check_provider
from terminal_calendar_tui import CalendarScreen
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, ROOT, require
from terminal_mouse import MouseTerminal, click, point

TITLE = "Utility payment due"
MESSAGE = "published-payment"


def setup(binary, root, ordinary=False, unsupported=False, long=False, inline=False, prime=True, cancelled=False, huge=False):
    fixture = Invitations(root)
    path = fixture.root / "accounts/personal.json"
    source = json.loads(path.read_text())
    message = source["messages"][0]
    raw = (ROOT / "tests/fixtures/terminal/calendar/published-payment.ics").read_bytes()
    if ordinary:
        raw = raw.replace(b"METHOD:PUBLISH\r\n", b"").replace(b'ORGANIZER;CN="Example Utility":MAILTO:billing@example.test\r\n', b"")
    if unsupported:
        raw = raw.replace(b"ACTION:DISPLAY", b"ACTION:EMAIL")
    if long:
        raw = raw.replace(b"DESCRIPTION:\\nYour fictional", ("DESCRIPTION:" + "\\n".join(f"Fictional payment detail {n:03d}" for n in range(45)) + "\\nYour fictional").encode())
    if huge:
        # More than the card's 4096 bytes of notes, folded as RFC 5545 asks.
        notes = "".join(f"Fictional payment detail {n:03d}. " for n in range(160))
        folded = "\r\n ".join(notes[i:i + 70] for i in range(0, len(notes), 70))
        raw = raw.replace(b"DESCRIPTION:\\nYour fictional", ("DESCRIPTION:" + folded + "\\nYour fictional").encode())
    if cancelled:
        raw = raw.replace(b"CLASS:PUBLIC\r\n", b"CLASS:PUBLIC\r\nSTATUS:CANCELLED\r\n")
    parts = message["payload"]["parts"]
    calendar = parts[1]
    calendar["mimeType"] = "text/plain"
    calendar["filename"] = "PAYMENT.ICS"
    calendar["headers"] = [{"name": "Content-Type", "value": "text/plain"},
                           {"name": "Content-Disposition", "value": "attachment; filename=PAYMENT.ICS"}]
    encoded = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    if inline:
        calendar["body"] = {"size": len(raw), "data": encoded}
    else:
        calendar["body"] = {"size": len(raw), "attachmentId": "payment-source"}
        source["externalBodies"] = {"payment-source": {"size": len(raw), "data": encoded}}
    # A separate inaccessible PDF must not prevent calendar preview/import.
    parts.append({"partId": "2", "mimeType": "application/pdf", "filename": "bill.pdf", "headers": [],
                  "body": {"size": 50000, "attachmentId": "unloaded-bill"}})
    message["id"] = MESSAGE
    message["threadId"] = "payment-thread"
    message["snippet"] = TITLE
    for header in message["payload"]["headers"]:
        if header["name"] == "Subject": header["value"] = TITLE
        if header["name"] == "From": header["value"] = "Example Utility <billing@example.test>"
    source["messages"] = [message]
    path.write_text(json.dumps(source) + "\n")
    directory = root / "client"
    if not prime:
        return fixture, directory
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.list", label="INBOX")
        message = client.request("mail.read", messageId=MESSAGE)
        require(message["invitation"] is not None, "text/plain uppercase ICS not discovered")
        require(len(message["attachments"]) == 2, "calendar or PDF attachment lost")
        notice = client.request("invitation.inspect", messageId=MESSAGE, cacheOnly=True)
        require(notice["method"] == "publish" and not notice["canReply"] and notice["attendeeCount"] == 0, "published event acquired RSVP")
    return fixture, directory


def cli_case(binary, root, ordinary=False, lost=False, unsupported=False, inline=False):
    fixture, directory = setup(binary, root, ordinary=ordinary, unsupported=unsupported, inline=inline)
    with Client(binary, directory, scenario="calendar-lost-response" if lost else None, extra=fixture.options()) as client:
        args = {"calendarId": ACCOUNTS[0], "messageId": MESSAGE}
        plan = client.request("calendar.invitation-plan", **args)
        require(plan["decision"] == "import_missing" and not plan["timeError"], "published event cannot be planned")
        first = (date(2026, 11, 23) - date(1970, 1, 1)).days
        require(plan["resolved"]["start"]["value"] == first and plan["resolved"]["end"]["value"] == first + 1, "exclusive all-day span shifted")
        invite = plan["invitation"]
        require(invite["reminders"] == ([] if unsupported else [{"method": "popup", "minutes": 2160}]), "reminder conversion changed")
        require(invite["unsupported_reminders"] == int(unsupported), "unsupported reminder omitted from review")
        refused = client.request("invitation.reply", messageId=MESSAGE, status="accepted", operationId="no-publish-rsvp", ok=False)
        require(refused["code"] == ("InvalidCalendar" if ordinary else "NotInvitationRequest"), "published/ordinary file authorized RSVP")
        refused = client.request("calendar.review", calendarId="fixture-shared-team", messageId=MESSAGE, operationId="wrong-target", ok=False)
        require(refused["code"] == "CalendarBookingPrimaryRequired", "personal event could enter secondary calendar")
        review = client.request("calendar.review", **args, operationId="published-review")
        require(review["calendarOrganizer"] == ACCOUNTS[0], "personal import uses wrong owner")
        require(provider_state(client)["writes"] == 0, "view/review wrote calendar")
        client.restart()
        result = client.request("calendar.import", **confirmation(review))
        if lost:
            require(result["state"] == "unknown" and provider_state(client)["writes"] == 1, "unknown import outcome mishandled")
            client.restart()
            result = client.request("calendar.reconcile", **confirmation(review))
        require(result["state"] == "applied", "confirmed import did not apply")
        saved = next(event["value"] for event in provider_state(client)["events"] if event["value"]["id"] == result["providerId"])
        require(saved["start"] == {"date": "2026-11-23"} and saved["end"] == {"date": "2026-11-24"}, "Google payload changed exclusive dates")
        require(saved["description"] == invite["description"] and saved["summary"] == invite["summary"], "import lost full notes/title")
        require(saved["reminders"] == {"useDefault": False, "overrides": invite["reminders"]}, "Google reminders differ from review")
        require(not saved.get("attendees") and saved["organizer"]["email"] == ACCOUNTS[0], "personal import invented guests")
        require(client.request("calendar.invitation-plan", **args)["decision"] == "existing", "repeat import not deduplicated")
        client.request("calendar.apply", **confirmation(review))
        require(provider_state(client)["writes"] == 1 and client.request("cache.stats")["fixtureSends"] == 0, "duplicate write or email sent")
    print("PASS published Calendar CLI:", "ordinary" if ordinary else "PUBLISH", "lost" if lost else "unsupported" if unsupported else "inline" if inline else "external")


def tui_case(binary, root, captures=None, unsupported=False, ordinary=False, long=False):
    fixture, directory = setup(binary, root, unsupported=unsupported, ordinary=ordinary, long=long)
    terminal = MouseTerminal(binary, directory, extra=fixture.options(), columns=120, rows=36, screen_type=CalendarScreen,
                             environment={"TZ": "Europe/Vienna", "NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: TITLE in terminal.text())
        terminal.gap(.2)
        terminal.send(b"A")
        terminal.until(lambda: "[y Add event]" in terminal.text())
        terminal.gap(.4)
        shown = terminal.text()
        require("Mon 23 Nov 2026" in shown and "24 Nov" not in shown and "all day" in shown.lower(), "all-day exclusive end displayed as an extra day")
        date_cell = terminal.screen.locate("Mon 23 Nov 2026")
        calendar_cell = terminal.screen.locate("Calendar   Primary")
        require(date_cell and calendar_cell and terminal.screen.styles[date_cell["row"]][date_cell["column"]][0] != terminal.screen.styles[calendar_cell["row"]][calendar_cell["column"]][0], "event card lost semantic colors")
        require("Booked via" not in shown and "Add appointment" not in shown and "Accept" not in shown, "published event presented as booking or invitation")
        if not long:
            require(("1 unsupported reminder" in shown.lower() and "won't be added" in shown.lower()) if unsupported else "36 hours before" in shown, "reminder consequence missing")
        check_provider(binary, directory, fixture, 0)
        terminal.send(b"\r")
        terminal.gap(.15)
        check_provider(binary, directory, fixture, 0)
        if long:
            terminal.send(b"y")
            terminal.gap(.15)
            check_provider(binary, directory, fixture, 0)
            terminal.send(b"\x04" * 20)
            terminal.gap(.3)
        if captures:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / (root.name + ".json")).write_text(json.dumps(screen_capture(terminal)) + "\n")
        click(terminal, *point(terminal, "[y Add event]"))
        terminal.until(lambda: "Added to your primary calendar" in terminal.text())
        require("[y Add event]" not in terminal.text(), "completed import still offers Add")
        check_provider(binary, directory, fixture, 1)
        terminal.send(b"\x1b")
        terminal.gap(.15)
        terminal.send(b"A")
        terminal.until(lambda: "Already in your primary calendar" in terminal.text())
        check_provider(binary, directory, fixture, 1)
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    print("PASS published Calendar TUI:", root.name)



def details_case(binary, root, ordinary=False):
    """I on a published event shows its details in usual terminals and an
    honest, sized request only in a genuinely small one; nothing is written."""
    fixture, directory = setup(binary, root, ordinary=ordinary)
    sender = "Sent by · Example Utility <billing@example.test>" if ordinary else "From · billing@example.test"
    expected = (TITLE, "Mon 23 Nov 2026", "all day", "Account · " + ACCOUNTS[0], sender,
                "A adds it to your primary calendar", "Reminder · 36 hours before",
                "Notes · Your fictional utility payment is due.", "[A Add to calendar]")
    for columns, rows in ((80, 24), (100, 30), (160, 45)):
        terminal = MouseTerminal(binary, directory, extra=fixture.options(), columns=columns, rows=rows, screen_type=CalendarScreen,
                                 environment={"TZ": "Europe/Vienna", "NO_COLOR": None, "COLORTERM": "truecolor"})
        try:
            terminal.until(lambda: TITLE in terminal.text())
            terminal.gap(.2)
            terminal.send(b"I")
            terminal.until(lambda: "Calendar event · details" in terminal.text() and "[Esc Close]" in terminal.text())
            terminal.gap(.2)
            shown = terminal.text()
            for refusal in ("Resize", "RSVP identity", "Make the terminal", "No RSVP can"):
                require(refusal not in shown, f"{columns}x{rows}: published event details asked to resize: {refusal}")
            for value in expected:
                require(value in shown, f"{columns}x{rows}: published event details omitted {value!r}")
            if columns == 100:
                # Genuinely small: the card names the size it needs, says
                # nothing of an RSVP, and returns when the terminal grows.
                terminal.resize(40, 12)
                terminal.until(lambda: "Make the terminal at least 40×" in terminal.text())
                require("RSVP" not in terminal.text(), "published event too-small notice mentioned an RSVP")
                terminal.resize(columns, rows)
                terminal.until(lambda: "Notes · Your fictional utility payment is due." in terminal.text())
                require("Make the terminal" not in terminal.text(), "details stayed hidden after growing the terminal")
            terminal.send(b"\x1b")
            terminal.until(lambda: "Calendar event · details" not in terminal.text())
            # Viewing details opens no Calendar and sends nothing.
            with Client(binary, directory, extra=fixture.options()) as client:
                require(client.request("cache.stats")["fixtureSends"] == 0, "viewing published event details sent mail")
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
    print("PASS published Calendar details:", "ordinary" if ordinary else "PUBLISH", "80x24 100x30 160x45 and 40x12")


def truth_case(binary, root, cancelled=False, unsupported=False):
    """Every sentence on the I card is true for that event: a cancelled event
    has no A, so its shortened notes cannot point to A; an event whose only
    alarm is unsupported says it will have no reminders, like the A review."""
    fixture, directory = setup(binary, root, cancelled=cancelled, huge=cancelled, unsupported=unsupported)
    terminal = MouseTerminal(binary, directory, extra=fixture.options(), columns=120, rows=36, screen_type=CalendarScreen,
                             environment={"TZ": "Europe/Vienna", "NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: TITLE in terminal.text())
        terminal.gap(.2)
        terminal.send(b"I")
        terminal.until(lambda: "Calendar event · details" in terminal.text() and "[Esc Close]" in terminal.text())
        terminal.gap(.2)
        terminal.send(b"G")
        terminal.gap(.3)
        shown = terminal.text()
        if cancelled:
            require("Event cancelled · nothing to add" in shown and "shortened here" in shown, "cancelled card lost its facts")
            for refused in ("A shows the complete notes", "A adds it", "[A Add to calendar]"):
                require(refused not in shown, f"cancelled card promised what A cannot do: {refused}")
        if unsupported:
            # The sentence wraps inside the card, beside the mailbox columns.
            lines = terminal.screen.lines()
            at = next((index for index, line in enumerate(lines) if "won't be added · this event will have no" in line), None)
            whole = at is not None and ("will have no reminders" in lines[at] or (at + 1 < len(lines) and "│  reminders" in lines[at + 1]))
            require(whole and "[A Add to calendar]" in shown,
                    "an event with only unsupported alarms did not say it will have no reminders")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Calendar event · details" not in terminal.text())
        with Client(binary, directory, extra=fixture.options()) as client:
            require(client.request("cache.stats")["fixtureSends"] == 0, "viewing event details sent mail")
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    print("PASS published Calendar card truth:", "cancelled" if cancelled else "unsupported alarms only")


def legacy_case(binary, old_binary, root):
    fixture, directory = setup(binary, root, prime=False)
    with Client(old_binary, directory, extra=fixture.options()) as old:
        old.request("mail.list", label="INBOX")
        message = old.request("mail.read", messageId=MESSAGE)
        require(message.get("invitation") is None and len(message["attachments"]) == 2, "legacy fixture already recognized plain-text calendar")
        original_body = message["bodyText"]
    with Client(binary, directory, extra=fixture.options()) as client:
        notice = client.request("invitation.inspect", messageId=MESSAGE)
        require(notice["method"] == "publish" and not notice["canReply"], "explicit view failed to upgrade retained ICS")
        message = client.request("mail.read", messageId=MESSAGE, cacheOnly=True)
        require(message["invitation"] is not None and message["bodyText"] == original_body and len(message["attachments"]) == 2, "cache upgrade lost mail body/files")
        require(client.request("cache.stats")["fixtureSends"] == 0, "legacy calendar preview sent mail")
    print("PASS published Calendar legacy cache: explicit view upgrades calendar, body and PDF preserved")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--captures", type=Path)
    parser.add_argument("--old-binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-calendar-files-") as tmp:
        root = Path(tmp)
        if args.old_binary:
            legacy_case(binary, args.old_binary.resolve(), root / "legacy-cache")
        cli_case(binary, root / "publish")
        cli_case(binary, root / "inline", inline=True)
        cli_case(binary, root / "ordinary", ordinary=True)
        cli_case(binary, root / "unknown", lost=True)
        cli_case(binary, root / "unsupported", unsupported=True)
        details_case(binary, root / "publish-details")
        details_case(binary, root / "ordinary-details", ordinary=True)
        truth_case(binary, root / "cancelled-truth", cancelled=True)
        truth_case(binary, root / "unsupported-truth", unsupported=True)
        tui_case(binary, root / "publish-tui", args.captures)
        tui_case(binary, root / "ordinary-tui", args.captures, ordinary=True)
        tui_case(binary, root / "unsupported-tui", args.captures, unsupported=True)
        tui_case(binary, root / "long-tui", args.captures, long=True)


if __name__ == "__main__": main()
