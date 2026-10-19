#!/usr/bin/env python3
"""Capture public Calendar screenshots from a verified released executable.

All application cells come from real, synchronized PTY output. Providers,
Contacts, mail and clocks are synthetic; no desktop or live account is used.
"""
from __future__ import annotations

import argparse
import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "video/capture"), str(ROOT / "tests"), str(ROOT / "video/tools")]
from build_info import read_build_info
from tape import Recorder, privacy_scan, save
from terminal_integration import ACCOUNTS, Client, require

spec = importlib.util.spec_from_file_location("calendar_film_fixture", ROOT / "video/short0210/capture.py")
story = importlib.util.module_from_spec(spec)
spec.loader.exec_module(story)

WORK = ACCOUNTS[1]
INVITE = "Launch rehearsal"
REMINDER = "Briefing"
SELECTED = REMINDER
KNOWN = (*story.KNOWN, "launch-rehearsal@example.org")


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def part(kind, value, ident):
    raw = value.encode()
    return {"partId": ident, "mimeType": kind, "filename": "invitation.ics" if kind == "text/calendar" else "",
            "headers": [{"name": "Content-Type", "value": kind + "; charset=utf-8"}],
            "body": {"size": len(raw), "data": base64.urlsafe_b64encode(raw).decode().rstrip("=")}}


class PublicFixture(story.CalendarStory):
    def __init__(self, directory):
        super().__init__(directory)
        self.reminder_now = datetime.now(timezone.utc).replace(microsecond=0)
        today = self.reminder_now.replace(hour=0, minute=0, second=0)
        self.monday = today - timedelta(days=today.weekday())
        self.reminder_start = self.reminder_now + timedelta(minutes=10)
        self.reminder_end = self.reminder_start + timedelta(hours=1)
        require(self.reminder_start < self.monday + timedelta(days=7),
                "capture would cross the UTC week boundary; reproduce after midnight")
        invitation_start = max(self.monday + timedelta(days=1), today + timedelta(days=1)) + timedelta(hours=14, minutes=30)
        self.invitation_start = invitation_start
        self.hero_day = invitation_start.date().isoformat()
        self.offsite_day = (self.monday + timedelta(days=3)).date().isoformat()
        # Use the real persistent split preference: the reader must remain
        # wide enough for the native bordered invitation card (48+ columns).
        preferences = json.loads(self.preferences.read_text())
        preferences["listWidthPercent"] = 40
        write_json(self.preferences, preferences)
        for path in (self.root / "accounts").glob("*.json"):
            data = json.loads(path.read_text())
            account = data["account"]
            for index, message in enumerate(data["messages"]):
                message["internalDate"] = str(int((self.monday + timedelta(hours=8, minutes=-index * 30)).timestamp() * 1000))
            body = ("Hi Morgan,\n\nLet’s give the launch one calm rehearsal.\n"
                    "We’ll walk through the demo and leave time for questions.\n\n"
                    f"See you {invitation_start.strftime('%A')} at 14:30 UTC!\nMaya")
            ics = "\r\n".join(["BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:REQUEST", "BEGIN:VEVENT",
                "UID:launch-rehearsal@example.org", "DTSTAMP:" + self.reminder_now.strftime("%Y%m%dT%H%M%SZ"), "SEQUENCE:1",
                "SUMMARY:" + INVITE, "DTSTART:" + invitation_start.strftime("%Y%m%dT%H%M%SZ"),
                "DTEND:" + (invitation_start + timedelta(minutes=30)).strftime("%Y%m%dT%H%M%SZ"),
                "ORGANIZER;CN=Maya Chen:mailto:maya@example.org",
                f"ATTENDEE;CN=Morgan Hills;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:{account}",
                "LOCATION:Ember Studio · Online", "DESCRIPTION:A calm run-through of the launch demo.",
                "CONFERENCE:https://meet.example.org/ember-launch", "URL:https://meet.example.org/ember-launch",
                "END:VEVENT", "END:VCALENDAR", ""])
            data["messages"].append({"id": "launch-invitation", "threadId": "launch-thread", "historyId": "500",
                "internalDate": str(int((self.monday + timedelta(hours=7)).timestamp() * 1000)),
                "labelIds": ["INBOX", "UNREAD"], "snippet": "Let’s give the launch one calm rehearsal.", "sizeEstimate": 1800,
                "payload": {"partId": "", "mimeType": "multipart/mixed", "filename": "", "body": {"size": 0},
                    "headers": [{"name": "From", "value": "Maya Chen <maya@example.org>"},
                        {"name": "To", "value": account}, {"name": "Subject", "value": INVITE},
                        {"name": "Message-ID", "value": "<launch-invitation@example.org>"}],
                    "parts": [part("text/plain", body, "0"), part("text/calendar", ics, "1")]}})
            write_json(path, data)

    def seed(self, binary):
        super().seed(binary)
        titles = {"Studio focus": "Focus", "Design check-in": "Design", "Release review": "Release",
            "Coffee with Leo": "Coffee", "Product notes": "Notes", "Client briefing": REMINDER,
            "Planning block": "Plan", "Creative sync": "Standup", "Coffee with Maya": "Coffee",
            "Research notes": "Research", "Story workshop": "Story", "Design direction": "Direction",
            "Product research": "Research", "Team catch-up": "Team", "Launch planning": "Launch",
            "Lunch with Leo": "Lunch", "Copy workshop": "Copy", "Friday review": "Review",
            "Studio show & tell": "Demo", "Autumn holiday": "Autumn"}
        for path in (self.directory / "cache").rglob("calendar-provider-fixture.json"):
            state = json.loads(path.read_text())
            for row in state["events"]:
                event = row["value"]
                original = event["summary"]
                event["summary"] = titles[original]
                require(len(event["summary"]) <= 9, "compact Week title is too long")
                if original == "Client briefing":
                    event["start"] = {"dateTime": self.reminder_start.isoformat().replace("+00:00", "Z")}
                    event["end"] = {"dateTime": self.reminder_end.isoformat().replace("+00:00", "Z")}
            if state["account"] == ACCOUNTS[0]:
                brunch = copy.deepcopy(state["events"][0])
                event = brunch["value"]
                event.update(id="weekend-brunch", iCalUID="weekend-brunch@example.org", summary="Brunch",
                    description="A relaxed weekend lunch with friends.", location="Corner café",
                    htmlLink="https://calendar.google.com/calendar/event?eid=weekend-brunch",
                    start={"dateTime": (self.monday + timedelta(days=5, hours=11)).isoformat().replace("+00:00", "Z")},
                    end={"dateTime": (self.monday + timedelta(days=5, hours=12, minutes=30)).isoformat().replace("+00:00", "Z")})
                state["events"].append(brunch)
            write_json(path, state)

    def clock(self, value):
        path = self.root / "calendar-notification-now-ms"
        path.write_text(str(int(value.timestamp() * 1000)) + "\n")
        path.chmod(0o600)


def capture(binary, out, info):
    out.mkdir(parents=True, mode=0o700)
    tapes = out / "tapes"
    tapes.mkdir(mode=0o700)
    manifest = {"schema": "omagma.public-captures.v1", "release": "0.2.10", "binary": info,
        "accounts": ACCOUNTS, "syntheticOnly": True,
        "physicalDesktopUsed": False, "liveProviderWrites": 0, "fixtureSends": 0, "calendarWrites": 0,
        "assets": {}, "takes": {}}
    with tempfile.TemporaryDirectory(prefix="omagma-public-calendar-") as temporary:
        directory = Path(temporary)
        fixture = PublicFixture(directory)
        fixture.seed(binary)
        manifest["fixtureWeek"] = fixture.monday.date().isoformat() + "/" + (fixture.monday + timedelta(days=6)).date().isoformat()
        manifest["reminderClock"] = fixture.reminder_now.isoformat()
        manifest["reminderStart"] = fixture.reminder_start.isoformat()
        manifest["reminderEnd"] = fixture.reminder_end.isoformat()

        def start(name, rows=38):
            rec = story.begin(binary, directory, fixture, name, rows=rows)
            return rec

        def keep(rec, name, filename, evidence):
            story.stable(rec, name)
            text = rec.text()
            privacy_scan([text], known=KNOWN)
            write_json(out / (name + ".screen.json"), {"text": text, "evidence": evidence})
            manifest["assets"][name] = {"tape": "tapes/" + rec.name + ".json", "mark": name,
                "file": filename, "columns": rec.columns, "rows": rec.rows, "evidence": evidence}

        def finish(rec):
            try:
                result = rec.finish(expected_sends=0, client_extra=fixture.options())
                fixture.writes(binary, 0)
                save(tapes / (rec.name + ".json"), rec.tape(info), known=KNOWN)
                manifest["takes"][rec.name] = result
            finally:
                close(rec)

        def close(rec):
            if not getattr(rec, "_public_closed", False):
                try:
                    rec.close()
                finally:
                    rec._public_closed = True

        rec = start("week", rows=32)
        try:
            story.open_week(rec, fixture)
            story.select_event(rec, SELECTED)
            require("All accounts" in rec.text() and "optional" in rec.text() and SELECTED in rec.screen.lines()[-4],
                    "Week must show all three account groups and the selected event’s complete footer")
            require(REMINDER in rec.text() and "Brunch" in rec.text(), "Week must retain the future reminder event and weekend appointment")
            keep(rec, "week", "omagma-calendar-week.png", {"scope": "all_accounts", "selectedEvent": SELECTED,
                "visibleCalendars": 5, "accountGroups": 3})
            finish(rec)
        except BaseException:
            print(rec.text(), file=sys.stderr)
            save(tapes / "failed-week.json", rec.tape(info), known=KNOWN)
            close(rec)
            raise

        rec = start("review")
        try:
            story.open_week(rec, fixture)
            story.select_event(rec, SELECTED)
            rec.press("n", "event:new")
            rec.wait(lambda: "New event" in rec.text() and "Title:" in rec.text())
            story.press_visible(rec, "[Calendar:", lambda: "Choose destination calendar" in rec.text())
            rec.press("k" * 20 + "j" * 3, "event:work-primary", show=False)
            rec.gap(.15)
            rec.press("\r", "event:bind-work")
            rec.wait(lambda: "New event" in rec.text() and WORK in rec.text())
            for label, value in [("Title", story.HERO), ("Start date", fixture.hero_day), ("End date", fixture.hero_day),
                    ("Start time", "10:30"), ("End time", "11:15"), ("Time zone", "UTC"),
                    ("Location", "Ember Studio · Online"), ("Notes", "Choose the next milestones and share the plan.")]:
                story.fill(rec, label, value)
            story.add_contact(rec, "Maya", story.MAYA, None)
            story.add_contact(rec, "Leo", story.LEO, None)
            story.press_visible(rec, "Video: None", lambda: "Video: Generate Google Meet link" in rec.text())
            story.review(rec, fixture, binary, 0, "review-ready")
            require("email 2 guests" in rec.text() and "Google Meet" in rec.text(), "review omitted guests/Meet consequences")
            keep(rec, "review", "omagma-calendar-review.png", {"title": story.HERO, "guestsFromContacts": [story.MAYA, story.LEO],
                "googleMeet": "generation requested; link is created after confirmation", "saved": False,
                "review": fixture.review_proof[-1]})
            # The real dirty-form guard deliberately rejects generic Esc/q
            # cleanup. Leave review and explicitly discard only this synthetic
            # unsaved form; never confirm the Calendar operation.
            rec.press("\x1b", "review:back-to-editing", show=False)
            rec.wait(lambda: "New event" in rec.text() and "[Esc Cancel]" in rec.text())
            rec.press("\x1b", "event:cancel-unsaved", show=False)
            rec.wait(lambda: "Discard your unsaved event?" in rec.text())
            rec.press("\x04", "event:discard-unsaved", show=False)
            rec.wait(lambda: "Calendar · Week" in rec.text() and "Discard your unsaved event?" not in rec.text())
            finish(rec)
        except BaseException:
            print(rec.text(), file=sys.stderr)
            save(tapes / "failed-review.json", rec.tape(info), known=KNOWN)
            close(rec)
            raise

        # Enable reminders only for their own take, using the actual UTC
        # capture time. The same future appointment is already present in Week.
        fixture.clock(fixture.reminder_now)
        rec = start("reminder")
        try:
            # The Calendar reminder worker runs automatically over Mail.
            rec.wait(lambda: "Starts in 10 min" in rec.text() and REMINDER in rec.text() and "[Join]" in rec.text(), seconds=25)
            require("Inbox" in rec.text(), "reminder must retain contextual Mail UI")
            keep(rec, "reminder", "omagma-meeting-reminder.png", {"event": REMINDER, "minutesUntilStart": 10,
                "joinAvailable": True, "account": WORK, "clock": fixture.reminder_now.isoformat(),
                "start": fixture.reminder_start.isoformat(), "end": fixture.reminder_end.isoformat()})
            finish(rec)
        except BaseException:
            print(rec.text(), file=sys.stderr)
            save(tapes / "failed-reminder.json", rec.tape(info), known=KNOWN)
            close(rec)
            raise

        # A fresh owned PTY starts without a reminder clock; no persistent
        # dismissal or provider write is needed.
        (fixture.root / "calendar-notification-now-ms").unlink()
        rec = start("invitation")
        try:
            rec.click(*rec.locate(INVITE), "mail:select-inbox-invitation")
            rec.wait(lambda: INVITE in rec.text() and "See you " in rec.text())
            rec.press("\r", "mail:open-invitation")
            rec.wait(lambda: "Invitation" in rec.text() and INVITE in rec.text() and "I · Respond" in rec.text() and "" in rec.text())
            require("Cache search" not in rec.text() and "Inbox /" not in rec.text(), "invitation must open from normal Inbox")
            keep(rec, "invitation", "omagma-mail-invitation.png", {"subject": INVITE, "organizer": story.MAYA,
                "recipient": WORK, "start": fixture.invitation_start.isoformat(), "joinAvailable": True})
            finish(rec)
        except BaseException:
            print(rec.text(), file=sys.stderr)
            save(tapes / "failed-invitation.json", rec.tape(info), known=KNOWN)
            close(rec)
            raise
    manifest["allOwnedPtyAndCliChildrenReaped"] = True
    write_json(out / "capture-manifest.json", manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(digest == args.expected_sha256, "binary checksum does not match the verified release")
    info = {"sha256": digest, **read_build_info(binary)}
    require(info["appVersion"] == "0.2.10", "public screenshots require released v0.2.10")
    out = args.out.resolve()
    require(out.is_relative_to(ROOT / "video/cache/short0210") and not out.exists(), "use a fresh ignored capture directory")
    # A live coordinator may delegate its reservation across native captures,
    # social rasterization and website QA. Only the owner releases that token.
    token = os.environ.get("HOST_TOKEN", "")
    owns_reservation = not token
    if token:
        verified = subprocess.run([sys.executable, str(ROOT / "video/tools/host_lock.py"), "verify", token],
            capture_output=True, text=True)
        require(verified.returncode == 0, verified.stderr.strip())
    else:
        acquired = subprocess.run([sys.executable, str(ROOT / "video/tools/host_lock.py"), "acquire", "--pid", str(os.getpid()),
            "--purpose", "public Calendar screenshot capture and headless native rasterization"], capture_output=True, text=True)
        require(acquired.returncode == 0, acquired.stderr.strip())
        token = acquired.stdout.strip()
        os.environ["HOST_TOKEN"] = token
    try:
        capture(binary, out, info)
        subprocess.run(["node", str(ROOT / "scripts/public-captures/render.mjs"), "--capture", str(out)], check=True)
    finally:
        if owns_reservation:
            subprocess.run([sys.executable, str(ROOT / "video/tools/host_lock.py"), "release", token], check=True)


if __name__ == "__main__":
    main()
