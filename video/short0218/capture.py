#!/usr/bin/env python3
"""Record released Omagma UI with fictional providers, never desktop input.

Requires the coordinator's live HOST_TOKEN. Every take has an independent
temporary home. Captures preserve the executable's completed cells and its
actual generated browser preview; no application UI is reconstructed here.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import html as html_text
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import traceback
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "video/short0218"), str(ROOT / "video/capture"),
               str(ROOT / "tests"), str(ROOT / "video/tools")]

from build_info import read_build_info
from capture_terminal import CaptureRecorder, self_test
from host_lock import identity, owner, start_ticks
from tape import save, tape_texts
from terminal_calendar import Invitations, provider_state
import terminal_calendar_compose as form
from terminal_clipboard_image import PreviewDocument
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, require

spec = importlib.util.spec_from_file_location("short0210_calendar_source", ROOT / "video/short0210/capture.py")
calendar_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calendar_source)
CalendarStory = calendar_source.CalendarStory
WORK, MAYA, LEO = ACCOUNTS[1], calendar_source.MAYA, calendar_source.LEO
KNOWN = (*ACCOUNTS, MAYA, LEO, "host@example.test", "barber-booking@example.test",
         "bookings@example.org", "bookings.example.test", "calendar-owner@example.org", "studio@example.org")
BEFORE = "Hi Maya, here's the new mark for slide one:"
AFTER = "Ember orange, as promised. — Morgan"
PASTE_SUBJECT = "New mark for the launch deck 🌋"
BOOKING_SUBJECT = "Your haircut is booked ✂️"


def reserve():
    lock = owner()
    who = identity(lock) if lock else None
    require(lock and lock.get("token") == os.environ.get("HOST_TOKEN") and who
            and start_ticks(who[0]) == who[1], "matching live coordinator HOST_TOKEN required")


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def fixture_story(binary, directory):
    story = CalendarStory(directory)
    story.seed(binary)
    return story


def start(binary, directory, story, name, scenario=None, columns=132, rows=36):
    extra = (*story.options(), "--account", WORK, "--ui-file", str(story.preferences))
    if scenario:
        extra += ("--fixture-scenario", scenario)
    rec = CaptureRecorder(binary, directory, name, extra=extra, columns=columns, rows=rows)
    rec.wait(lambda: "A clear plan for next week" in rec.text() and "Up to date" in rec.text())
    return rec


def draft(binary, directory, extra=()):
    with Client(binary, directory, extra=extra) as client:
        rows = client.request("draft.list", WORK)["drafts"]
        require(len(rows) == 1, "capture must retain exactly one local draft")
        result = client.request("draft.read", WORK, draftId=rows[0]["id"])
        require(client.request("cache.stats", WORK)["fixtureSends"] == 0, "draft capture sent mail")
        return result


def source_body(value):
    fields = value.get("recoveryFields")
    return fields[4] if fields else value["bodyText"]


def persisted(rec, binary, directory, extra, predicate):
    deadline = time.monotonic() + 8
    while True:
        rec.pump(0)
        value = draft(binary, directory, extra)
        rec.pump(0)
        if predicate(value):
            return value
        require(time.monotonic() < deadline, "capture draft did not persist expected source")
        rec.pump(.05)


def pane_roi(rec, needle=None):
    where = rec.screen.locate(needle) if needle else None
    grid, panes = rec.screen.cells, []
    for y, line in enumerate(grid):
        for x, glyph in enumerate(line):
            if glyph not in ("╭", "┌"):
                continue
            right = next((col for col in range(x + 1, rec.columns) if grid[y][col] in ("╮", "┐")), None)
            bottom = next((row for row in range(y + 1, rec.rows) if grid[row][x] in ("╰", "└")), None)
            if right is None or bottom is None or grid[bottom][right] not in ("╯", "┘"):
                continue
            if where and not (x <= where["column"] <= right and y <= where["row"] <= bottom):
                continue
            panes.append([x, y, right - x + 1, bottom - y + 1])
    return min(panes, key=lambda p: p[2] * p[3]) if panes else [0, 0, rec.columns, rec.rows]


def mark(rec, manifest, out, key, needle=None, rois=None):
    rec.wait(lambda: needle is None or needle in rec.text())
    rec.mark(key)
    manifest["assets"][key] = {
        "tape": rec.name + ".json", "mark": key, "frame": rec.marks[-1]["frame"],
        "cellROIs": {"focus": pane_roi(rec, needle), **(rois or {})},
    }
    write_json(out / (key + "-screen.json"), screen_capture(rec))


def preserve(rec, info, out):
    captured = rec.tape(info)
    inline_ids = {match for text in tape_texts(captured)
                  for match in re.findall(r"clipboard-[0-9a-f]{32}@omagma\.invalid", text)}
    for cid in getattr(rec, "fixture_inline_ids", ()):
        require(re.fullmatch(r"clipboard-[0-9a-f]{32}@omagma\.invalid", cid), "unexpected private inline ID")
        inline_ids.update(cid[index:] for index in range(cid.index("@")))
    write_json(out / (rec.name + "-final-screen.json"), screen_capture(rec))
    try:
        save(out / (rec.name + ".json"), captured, known=(*KNOWN, *inline_ids))
    finally:
        rec.close()


def clipboard(binary, directory, out, manifest):
    story = fixture_story(binary, directory)
    rec = start(binary, directory, story, "clipboard", "clipboard-png", columns=100, rows=30)
    try:
        rec.press("c", "compose.open")
        rec.wait(lambda: "Subject:" in rec.text() and "Body:" in rec.text())
        rec.press(("i" + MAYA + "\t\t\t" + PASTE_SUBJECT + "\t"), "compose.headers", show=False)
        rec.press(b"\x1b[200~" + BEFORE.encode() + b"\x1b[201~", "compose.paragraph", show=False)
        rec.wait(lambda: BEFORE in rec.text() and "Body: INSERT" in rec.text())
        initial = persisted(rec, binary, directory, story.options(),
                            lambda d: source_body(d).startswith(BEFORE) and not d["attachments"])
        retained_tail = source_body(initial)[len(BEFORE):]
        mark(rec, manifest, out, "clipboard.before", BEFORE)
        rec.press(b"\x16", "clipboard.paste")
        rec.wait(lambda: "Pasted clipboard-" in rec.text() and " · inline" in rec.text())
        mark(rec, manifest, out, "clipboard.marker", " · inline")
        # The already-inserted marker owns the cursor; type literal characters
        # after it and retain each genuine completed native update for the edit.
        rec.press(b"\r\r", "clipboard.paragraph-spacing", show=False)
        before_typing = len(rec.frames)
        rec.type(AFTER, "clipboard.paragraph-two", delay=.035)
        typed_frames = len(rec.frames) - before_typing
        require(typed_frames >= 10, "paragraph typing did not retain ten intermediate native frames")
        value = persisted(rec, binary, directory, story.options(),
                          lambda d: len(d["attachments"]) == 1 and AFTER in source_body(d))
        attachment = value["attachments"][0]
        rec.fixture_inline_ids = [attachment["contentId"]]
        marker = f'![{attachment["filename"]}](cid:{attachment["contentId"]})'
        require(source_body(value) == BEFORE + "\n\n" + marker + "\n\n" + AFTER + retained_tail,
                "actual paste did not preserve the cursor and following paragraph")
        require(attachment["disposition"] == "inline" and attachment["mimeType"] == "image/png",
                "capture image is not inline PNG")
        mark(rec, manifest, out, "clipboard.after", " · inline",
             {"composer": [0, 2, 60, 24], "body": [1, 9, 58, 11]})
        rec.press(b"\x1b", "compose.normal", show=False)
        rec.wait(lambda: "i Edit" in rec.text() and "Body: INSERT" not in rec.text())
        rec.press("P", "clipboard.browser")
        rec.wait(lambda: "Mock browser target validated" in rec.text())
        paths = list(directory.rglob("preview.html"))
        require(len(paths) == 1, "expected one actual browser preview")
        html = paths[0].read_bytes()
        images = PreviewDocument(html.decode()).matching_images(attachment["filename"])
        require(len(images) == 1, "actual preview must have one authored image")
        document, attrs, offset = images[0]
        visible_document = html_text.unescape(document)
        visible_offset = len(html_text.unescape(document[:offset]))
        require(visible_document.index(BEFORE) < visible_offset < visible_document.index(AFTER),
                "browser preview moved inline image")
        png = base64.b64decode(attrs["src"].split(",", 1)[1], validate=True)
        require(png == (ROOT / "src/terminal/omagma-logo.png").read_bytes(), "fixture image bytes changed")
        (out / "inline-preview.html").write_bytes(html)
        (out / "inline-image.png").write_bytes(png)
        manifest["browser"] = {"file": "inline-preview.html", "sourceSha256": hashlib.sha256(html).hexdigest(),
                               "image": "inline-image.png", "imageSha256": hashlib.sha256(png).hexdigest(),
                               "imageAlt": attachment["filename"], "before": BEFORE, "after": AFTER,
                               "provenance": "Unmodified application-generated sandboxed browser preview"}
        manifest["proofs"]["clipboard"] = {"sourceBody": source_body(value), "bodyFormat": value["bodyFormat"],
            "contentId": attachment["contentId"], "fixtureSends": 0, "userClipboardRead": False,
            "typedIntermediateFrames": typed_frames}
        manifest["cleanup"]["clipboard"] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest["buildInfo"], out)


def drive(binary, directory, out, manifest, review_only=False):
    story = fixture_story(binary, directory)
    take = "drive-access" if review_only else "drive"
    rec = start(binary, directory, story, take, "drive-progress", columns=100, rows=32)
    try:
        rec.press("c", "drive.compose")
        rec.wait(lambda: "Subject:" in rec.text())
        rec.press("i" + MAYA + "\t" + LEO + "\t\tThis week at Ember Studio\tA little planning, focused work, and a good conversation.\x1b",
                  "drive.headers", show=False)
        persisted(rec, binary, directory, story.options(), lambda d: not d["attachments"] and "conversation." in source_body(d))
        documents = directory / "Documents"
        documents.mkdir()
        artifact = documents / "launch-film-master.mov"
        with artifact.open("wb") as stream:
            stream.truncate(26 * 1024 * 1024)
        matches = ["launch-notes.md", "launch-overview.pdf", "launch-photos.png",
                   "launch-plan.txt", "launch-slides.pdf", "launch-storyboard.txt"]
        for index, name in enumerate(matches):
            payload = (("Ember Studio\n" * (240 + index * 100)).encode()
                       if not name.endswith(".png") else (ROOT / "src/terminal/omagma-logo.png").read_bytes())
            (documents / name).write_bytes(payload)
        (documents / "budget.csv").write_text("item,value\n")
        rec.press("A", "drive.browse")
        rec.wait(lambda: "Attach file · local draft" in rec.text())
        rec.press(b"\x15Documents/\r", "drive.folder", show=False)
        rec.wait(lambda: "budget.csv" in rec.text() and artifact.name in rec.text())
        rec.press(b"\x15Documents/launch", "drive.filter", show=False)
        rec.wait(lambda: all(name in rec.text() for name in matches) and artifact.name in rec.text()
                 and "budget.csv" not in rec.text())
        mark(rec, manifest, out, "drive.picker", "Attach file · local draft")
        # Ctrl+P moves to/chooses the already first selected listing entry and
        # fills the exact path. Enter then imports that single genuine file.
        rec.press(b"\x10", "drive.file", show=False)
        rec.wait(lambda: "Documents/" + artifact.name in rec.text())
        rec.press(b"\r", "drive.attach")
        rec.wait(lambda: "Too large to attach" in rec.text() and "Drive all (d)" in rec.text())
        mark(rec, manifest, out, "drive.choice", "Too large to attach")
        rec.press("d", "drive.choose")
        rec.wait(lambda: "[Drv     ]" in rec.text())
        persisted(rec, binary, directory, story.options(),
                  lambda d: len(d["attachments"]) == 1 and d["attachments"][0]["delivery"] == "drive")
        mark(rec, manifest, out, "drive.selected", "[Drv     ]")
        rec.press(b"\x13", "drive.review.open")
        rec.wait(lambda: "From Drive 1" in rec.text() and "[y Send]" in rec.text())
        mark(rec, manifest, out, "drive.review", "From Drive 1")
        for index in range(25):
            if ("Viewer-only access for exactly:" in rec.text() and "Restricted link" in rec.text()
                    and MAYA in rec.text() and LEO in rec.text()):
                break
            previous = rec.text()
            rec.press("j", "drive.access-scroll", show=False)
            rec.wait(lambda: rec.text() != previous)
            if review_only:
                mark(rec, manifest, out, "drive.access-scroll-" + str(index + 1), "Review send")
        require(MAYA in rec.text() and LEO in rec.text(), "review omitted exact sharing recipients")
        require("Restricted link" in rec.text(), "review did not display restricted sharing policy")
        mark(rec, manifest, out, "drive.access", "Viewer-only access for exactly:")
        if review_only:
            with Client(binary, directory, scenario="drive-progress", extra=story.options()) as client:
                sends = sum(client.request("cache.stats", account)["fixtureSends"] for account in ACCOUNTS)
                writes = sum(provider_state(client, account)["writes"] for account in ACCOUNTS)
            ledgers = list((directory / "cache").rglob("drive-uploads.json"))
            require(sends == writes == 0 and not ledgers, "read-only access capture sent, uploaded or changed Calendar")
            manifest["proofs"][take] = {"fixtureSends": sends, "calendarWrites": writes,
                "driveUploadLedgers": len(ledgers), "sourceBytes": artifact.stat().st_size,
                "to": MAYA, "cc": LEO, "bcc": [], "viewerAndRestrictedVisible": True}
            manifest["cleanup"][take] = rec.finish(client_extra=story.options())
            return
        rec.press("y", "drive.confirm")
        rec.wait(lambda: "Sending in " in rec.text() and "[Send now" in rec.text())
        mark(rec, manifest, out, "drive.countdown", "Sending in ")
        countdown_start = time.monotonic()
        rec.gap(2.15)  # Deliberate real on-screen contract hold, not readiness.
        countdown_hold = time.monotonic() - countdown_start
        require("Sending in " in rec.text(), "countdown did not stay visible for the contract hold")
        rec.press(b"\x13", "drive.send-now")
        rec.wait(lambda: "Message: waits for uploads" in rec.text() and "uploading" in rec.text(), seconds=35)
        mark(rec, manifest, out, "drive.upload", "Message: waits for uploads")
        samples = []
        def percent():
            found = re.search(r"uploading (\d+)%", rec.text())
            return int(found.group(1)) if found else -1
        for target in (0, 18, 36, 54, 72, 90):
            rec.wait(lambda: percent() >= target, seconds=15)
            samples.append({"percent": percent(), "captureTime": rec.now()})
            mark(rec, manifest, out, "drive.progress-" + str(target), "Message: waits for uploads")
        rec.wait(lambda: "Send complete · provider accepted" in rec.text(), seconds=35)
        mark(rec, manifest, out, "drive.complete", "Send complete")
        with Client(binary, directory, scenario="drive-progress", extra=story.options()) as client:
            history = client.request("history.operations", WORK)["items"]
            require(len(history) == 1 and history[0]["outcome"] == "applied", "fixture send did not complete once")
            receipt = client.request("operation.read", WORK, operationId=history[0]["id"])
            require(receipt["driveFiles"][0]["sharedWith"] == sorted([MAYA, LEO]), "Drive did not share exactly with To+Cc")
            require(client.request("cache.stats", WORK)["fixtureSends"] == 1, "Drive take sent other than one fixture message")
        manifest["proofs"]["drive"] = {**receipt, "countdownVisibleSeconds": countdown_hold,
            "progressSamples": samples, "sourceBytes": artifact.stat().st_size,
            "pickerFilter": "launch", "matchingFilenames": [artifact.name, *matches]}
        manifest["cleanup"]["drive"] = rec.finish(expected_sends=1, client_extra=story.options())
    finally:
        preserve(rec, manifest["buildInfo"], out)


def booking_spec(manifest):
    day = datetime.fromisoformat(manifest["storyDateUtc"]).date() + timedelta(days=1)
    first = datetime.combine(day, datetime.min.time()).replace(hour=10, minute=15, tzinfo=ZoneInfo("Europe/Vienna"))
    last = first + timedelta(minutes=50)
    return {"day": day.isoformat(), "summary": "Haircut", "uid": "barber-booking@example.test",
            "start": first.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "end": last.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "localStart": first.strftime("%Y%m%dT%H%M%S"), "localEnd": last.strftime("%Y%m%dT%H%M%S")}


def booking(binary, directory, out, manifest):
    fixture = Invitations(directory)
    planned = booking_spec(manifest)
    path = fixture.root / "accounts/personal.json"
    account = json.loads(path.read_text())
    message = account["messages"][0]
    raw = (ROOT / "tests/fixtures/terminal/calendar/booking-no-attendees.ics").read_text()
    raw = raw.replace("12345678-1234-4234-9234-123456789abc", planned["uid"])
    raw = raw.replace("SUMMARY:Fictional haircut booking", "SUMMARY:Haircut")
    raw = raw.replace("20261110T101500", planned["localStart"]).replace("20261110T110500", planned["localEnd"])
    raw = raw.replace("host@example.test", "bookings@example.org")
    raw = "\r\n".join(raw.splitlines()) + "\r\n"
    for part in message["payload"]["parts"]:
        if part["mimeType"] == "text/calendar":
            data = raw.encode()
        else:
            data = b"Hi Morgan,\n\nYour haircut is booked.\nBooked service. Please arrive on time.\n\nEmber Studio\n"
        part["body"] = {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}
    for header in message["payload"]["headers"]:
        if header["name"] == "From": header["value"] = "Ember Studio <bookings@example.org>"
        elif header["name"] == "Subject": header["value"] = BOOKING_SUBJECT
    message.update(id="booking-confirmation", threadId="booking-thread", snippet="Your haircut is booked.")
    account["messages"] = [message]
    write_json(path, account)
    client = directory / "client"
    with Client(binary, client, extra=fixture.options()) as connection:
        connection.request("mail.list", label="INBOX")
        connection.request("mail.read", messageId=message["id"])
        notice = connection.request("invitation.inspect", messageId=message["id"], cacheOnly=True)
        require(not notice["canReply"], "booking unexpectedly acquired RSVP identity")
    rec = CaptureRecorder(binary, client, "booking", extra=fixture.options(), columns=100, rows=30)
    try:
        rec.wait(lambda: BOOKING_SUBJECT in rec.text() and "Booked service." in rec.text())
        mark(rec, manifest, out, "booking.mail", "Your haircut")
        rec.press("A", "booking.open")
        rec.wait(lambda: "Adds this as your own appointment. No reply is sent." in rec.text()
                 and "[y Add appointment]" in rec.text())
        with Client(binary, client, extra=fixture.options()) as connection:
            require(provider_state(connection)["writes"] == 0, "booking wrote before confirmation")
        mark(rec, manifest, out, "booking.review", "[y Add appointment]")
        rec.press("y", "booking.confirm")
        rec.wait(lambda: "Added to your primary calendar. No email sent." in rec.text())
        mark(rec, manifest, out, "booking.complete", "Added to your primary calendar.")
        with Client(binary, client, extra=fixture.options()) as connection:
            state = provider_state(connection)
            require(state["writes"] == 1, "booking did not create exactly one event")
            require(connection.request("cache.stats")["fixtureSends"] == 0, "booking sent mail")
        manifest["proofs"]["booking"] = {"calendarWrites": state["writes"], "fixtureSends": 0,
                                          "events": state["events"], "identity": planned}
        manifest["cleanup"]["booking"] = rec.finish(client_extra=fixture.options())
    finally:
        preserve(rec, manifest["buildInfo"], out)


def meet(binary, directory, out, manifest):
    story = fixture_story(binary, directory)
    rec = start(binary, directory, story, "meet", "meet-ready", rows=42)
    try:
        form.open_new(rec)
        first, _ = form.new_dates()
        form.ordinary_fields(rec, "Launch review", first)
        form.toggle(rec, "Video: None", "Video: Generate Google Meet")
        mark(rec, manifest, out, "meet.unchecked", "[ ] Auto Meet AI notes")
        x, y = rec.locate("[ ] Auto Meet AI notes")
        rec.click(x + 1, y, "meet.enable-notes")
        rec.wait(lambda: "[x] Auto Meet AI notes" in rec.text())
        mark(rec, manifest, out, "meet.checked", "[x] Auto Meet AI notes")
        rec.press(b"\x13", "meet.review.open")
        rec.wait(lambda: "Review new event" in rec.text())
        mark(rec, manifest, out, "meet.review", "Review new event")
        for _ in range(35):
            rec.send(b"\x04")
            rec.pump(.01)
        rec.press("y", "meet.confirm")
        rec.wait(lambda: "confirmed by Google" in rec.text())
        mark(rec, manifest, out, "meet.complete", "confirmed by Google")
        with Client(binary, directory, scenario="meet-ready", extra=story.options()) as connection:
            state = provider_state(connection, WORK)
            require(state["writes"] == 1, "Meet capture created more than one event")
            require(connection.request("cache.stats", WORK)["fixtureSends"] == 0, "Meet capture sent mail")
        paths = list((directory / "cache").rglob("meet-provider-fixture.json"))
        require(len(paths) == 1, "Meet provider proof missing or duplicated")
        configured = json.loads(paths[0].read_text())
        require(configured["patch_attempts"] == configured["writes"] == 1,
                "Meet setting was not applied exactly once")
        require(len(configured["spaces"]) == 1 and configured["spaces"][0]["notes"]
                and configured["spaces"][0]["transcription"], "Meet notes/transcription were not enabled")
        manifest["proofs"]["meet"] = {"calendarWrites": state["writes"], "meet": configured, "fixtureSends": 0}
        manifest["cleanup"]["meet"] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest["buildInfo"], out)


def nowline(binary, directory, out, manifest):
    story = CalendarStory(directory)
    now = datetime.now(timezone.utc)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    story.monday = today - timedelta(days=today.weekday())
    story.seed(binary)
    current_hour = now.replace(minute=0, second=0, microsecond=0)
    haircut = booking_spec(manifest)
    tomorrow = today + timedelta(days=1)
    events = [
        (WORK, "fixture-shared-team", today + timedelta(hours=max(0, now.hour - 3)), 60, "Focus", False),
        (WORK, WORK, current_hour, 120, "Sync", True),
        (WORK, WORK, current_hour + timedelta(hours=2), 45, "Call", True),
        (ACCOUNTS[2], ACCOUNTS[2], tomorrow + timedelta(hours=15), 45, "Review", True),
        (WORK, WORK, today + timedelta(days=2, hours=9), 60, "Plan", False),
    ]
    for path in (directory / "cache").rglob("calendar-provider-fixture.json"):
        state = json.loads(path.read_text())
        state["events"] = []
        for index, (account, calendar, first, duration, title, online) in enumerate(events):
            if state["account"] == account:
                last = first + timedelta(minutes=duration)
                ident = "studio-now-" + str(index)
                value = {
                    "id": ident, "iCalUID": ident + "@example.org", "etag": '"story-1"', "status": "confirmed",
                    "summary": title, "organizer": {"email": MAYA},
                    "start": {"dateTime": first.isoformat().replace("+00:00", "Z")},
                    "end": {"dateTime": last.isoformat().replace("+00:00", "Z")},
                    "attendees": [{"email": account, "self": True, "responseStatus": "accepted"}]}
                if online: value["hangoutLink"] = "https://meet.example.org/ember-now"
                state["events"].append({"calendar_id": calendar, "value": value})
        if state["account"] == ACCOUNTS[0]:
            state["events"].append({"calendar_id": ACCOUNTS[0], "value": {
                "id": "studio-haircut", "iCalUID": haircut["uid"], "etag": '"story-1"', "status": "confirmed",
                "summary": haircut["summary"], "organizer": {"email": "bookings@example.org"},
                "start": {"dateTime": haircut["start"]}, "end": {"dateTime": haircut["end"]}}})
        write_json(path, state)
    rec = start(binary, directory, story, "nowline", columns=120, rows=36)
    try:
        rec.press("C", "now.calendar")
        rec.wait(lambda: "Calendar · Agenda" in rec.text())
        rec.press("t3", "now.week")
        rec.wait(lambda: "Calendar · Week" in rec.text() and rec.screen.locate("now") is not None)
        # Initial selection belongs to the first account (tomorrow's haircut),
        # so start at the earliest of our six known timed events before moving
        # to the current meeting. Forward-only navigation cannot reach it.
        rec.press("k" * 6, "now.first-event", show=False)
        rec.wait(lambda: "Focus" in rec.screen.lines()[-4])
        rec.press("j", "now.select", show=False)
        rec.wait(lambda: "Sync" in rec.screen.lines()[-4])
        require("Sync" in rec.screen.lines()[-4], "current meeting did not retain selection")
        require("Haircut" in rec.text(), "week did not show the identical booked appointment")
        mark(rec, manifest, out, "calendar.week", "now")
        where = rec.screen.locate("now")
        row = where["row"]
        underlines = [column for column, style in enumerate(rec.screen.styles[row]) if style[4] and style[6] is not None]
        require(underlines, "native now line lost explicit underline color")
        mark(rec, manifest, out, "calendar.now", "now", {"now": [0, max(0, row - 1), rec.columns, min(3, rec.rows - max(0, row - 1))]})
        manifest["proofs"]["nowline"] = {"captureUtc": datetime.now(timezone.utc).isoformat(),
            "seedUtc": now.isoformat(), "row": row, "nativeUnderlineColumns": underlines,
            "nativeUnderlineColors": [rec.screen.styles[row][column][6] for column in underlines],
            "clock": "Actual operating-system real time; notification fixture clock is not used",
            "eventCount": 6, "bookingIdentity": haircut, "filtered": False}
        manifest["cleanup"]["nowline"] = rec.finish(client_extra=story.options())
    finally:
        preserve(rec, manifest["buildInfo"], out)


TAKES = {"clipboard": clipboard, "drive": drive, "booking": booking, "meet": meet, "nowline": nowline,
         "drive-access": lambda *arguments: drive(*arguments, review_only=True)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--takes", default="clipboard,booking,drive,nowline,meet")
    args = parser.parse_args()
    reserve()
    self_test()
    binary = args.binary.resolve()
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == args.expected_sha256, "capture binary changed")
    selected = args.takes.split(",")
    require(all(name in TAKES for name in selected) and len(set(selected)) == len(selected), "unknown/duplicate take")
    out = args.out.resolve()
    require(not out.exists(), "preserve previous capture attempts: output already exists")
    out.mkdir(parents=True)
    manifest = {"schema": "omagma.video.capture.v1", "binarySha256": args.expected_sha256,
                "buildInfo": read_build_info(binary), "assets": {}, "proofs": {}, "cleanup": {},
                "synthetic": True, "liveProviderWrites": 0, "userClipboardRead": False,
                "storyDateUtc": datetime.now(timezone.utc).date().isoformat()}
    try:
        for name in selected:
            reserve()
            print("CAPTURE " + name, flush=True)
            with tempfile.TemporaryDirectory(prefix="omagma-video0218-" + name + "-") as temporary:
                TAKES[name](binary, Path(temporary), out, manifest)
            write_json(out / "capture-manifest.json", manifest)
            print("CAPTURE PASS " + name, flush=True)
    except Exception:
        manifest["failure"] = traceback.format_exc()
        write_json(out / "capture-manifest.json", manifest)
        raise
    print("Captured unchanged released UI, fictional providers only: " + ", ".join(selected))


if __name__ == "__main__":
    main()
