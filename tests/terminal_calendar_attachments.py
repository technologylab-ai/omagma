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


def setup(binary, root, ordinary=False, unsupported=False, long=False, inline=False, prime=True):
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
        tui_case(binary, root / "publish-tui", args.captures)
        tui_case(binary, root / "ordinary-tui", args.captures, ordinary=True)
        tui_case(binary, root / "unsupported-tui", args.captures, unsupported=True)
        tui_case(binary, root / "long-tui", args.captures, long=True)


if __name__ == "__main__": main()
