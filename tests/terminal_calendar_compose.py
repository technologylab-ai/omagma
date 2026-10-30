#!/usr/bin/env python3
"""Ordinary Calendar create/edit workflows in actual isolated native PTYs.

Run under the cooperative host reservation. Only the existing synthetic
Invitations provider is used; no OAuth, network or desktop writes occur.
Provider documents independently establish exact dates, guest/link content,
ETag binding and mutation counts rather than inferring success from a label.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import traceback

from build_info import read_build_info
from terminal_calendar import Invitations, provider_state
from terminal_calendar_tui import capture as default_capture, provider_counts, start as default_start, wait_calendar
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal, click, point
from terminal_reader_editor import ReaderScreen
from terminal_theme_picker import ThemeScreen


NO_COLOR = False


class ComposeScreen(ThemeScreen, ReaderScreen):
    """Actual synchronized cells plus the established SGR reverse oracle."""


def capture(terminal, destination, name):
    if not NO_COLOR:
        return default_capture(terminal, destination, name)
    if destination:
        terminal.gap(.1)
        destination.mkdir(parents=True, exist_ok=True)
        value = screen_capture(terminal)
        value["currentReverseCells"] = terminal.screen.reversed
        (destination / (name + ".json")).write_text(json.dumps(value) + "\n")


def start(binary, directory, fixture, **options):
    if not NO_COLOR:
        return default_start(binary, directory, fixture, **options)
    extra = fixture.options() + ("--account", ACCOUNTS[0])
    scenario = options.pop("scenario", None)
    if scenario:
        extra += ("--fixture-scenario", scenario)
    terminal = MouseTerminal(binary, directory, extra=extra,
                             screen_type=ComposeScreen, environment={"TZ": "UTC", "NO_COLOR": "1"}, **options)
    terminal.until(lambda: "Planning version" in terminal.text())
    terminal.gap(.2)
    return terminal


def row_text(terminal, literal):
    located = terminal.screen.locate(literal)
    return terminal.screen.lines()[located["row"]] if located else ""


def focused_field(terminal, label):
    return "▏" in row_text(terminal, label + ":")


def next_control(terminal, backward=False):
    # Observe each completed render. Queued Tab bursts can otherwise activate
    # a previous mouse target/focus under slow native Debug or hosted runners.
    before = terminal.screen.completed_frames
    terminal.send(b"\x1b[Z" if backward else b"\t")
    terminal.until(lambda: terminal.screen.completed_frames > before)


def focus_field(terminal, label):
    for _ in range(40):
        if focused_field(terminal, label):
            return
        if terminal.screen.locate(label + ":") is not None:
            click(terminal, *point(terminal, label + ":"))
            terminal.until(lambda: focused_field(terminal, label))
            return
        next_control(terminal)
    raise AssertionError("field was unreachable by keyboard scrolling: " + label)


def fill(terminal, label, value):
    focus_field(terminal, label)
    # Test fixtures use short prefilled fields; clear through real editor
    # shortcuts and paste literally, including punctuation and Unicode.
    before = terminal.screen.completed_frames
    terminal.send(b"\x05" + b"\x7f" * 128)
    terminal.send(b"\x1b[200~" + value.encode() + b"\x1b[201~")
    tail = value.rsplit("\n", 1)[-1][-12:]
    terminal.until(lambda: terminal.screen.completed_frames > before and focused_field(terminal, label)
                   and (not tail or tail in row_text(terminal, label + ":")))
    if value and "\n" not in value and len(value) < 24:
        require(value in row_text(terminal, label + ":"), "edited field did not display the requested value")


def toggle(terminal, literal, expected):
    for _ in range(40):
        if terminal.screen.locate(literal) is not None:
            click(terminal, *point(terminal, literal))
            terminal.until(lambda: expected in terminal.text())
            return
        next_control(terminal)
    raise AssertionError("toggle was unreachable by keyboard scrolling: " + literal)


def open_new(terminal):
    terminal.send(b"C")
    wait_calendar(terminal)
    terminal.send(b"n")
    terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))


def new_dates(offset=4):
    day = (datetime.now(timezone.utc) + timedelta(days=offset)).date()
    return day.isoformat(), (day + timedelta(days=1)).isoformat()


def ordinary_fields(terminal, title, start_day, end_day=None, all_day=False):
    fill(terminal, "Title", title)
    if all_day:
        toggle(terminal, "[ ] All day", "[x] All day")
    fill(terminal, "Start date", start_day)
    fill(terminal, "Last date (included)" if all_day else "End date", end_day or start_day)
    if not all_day:
        fill(terminal, "Start time", "17:30")
        fill(terminal, "End time", "18:15")
    if not all_day:
        fill(terminal, "Time zone", "UTC")


def review(terminal, title, binary, client_dir, fixture, writes, captures=None, name="review"):
    terminal.send(b"\x13")
    terminal.until(lambda: "Review new event" in terminal.text() or "Review event changes" in terminal.text())
    require(title in terminal.text(), "review omitted the event title")
    provider_counts(binary, client_dir, fixture, writes)
    capture(terminal, captures, "compose-" + name)


def confirm(terminal, expected_writes, binary, client_dir, fixture):
    # Long/narrow reviews require actually reaching the end before consent.
    for _ in range(40):
        terminal.send(b"\x04")
        terminal.gap(.02)
    terminal.send(b"y")
    terminal.until(lambda: "Event saved" in terminal.text() and "Saved in Calendar." in terminal.text())
    provider_counts(binary, client_dir, fixture, expected_writes)


def state(binary, directory, fixture):
    with Client(binary, directory, extra=fixture.options()) as client:
        return provider_state(client)


def find_saved(binary, directory, fixture, title):
    matches = [entry["value"] for entry in state(binary, directory, fixture)["events"]
               if entry["calendar_id"] == ACCOUNTS[0] and entry["value"].get("summary") == title]
    require(len(matches) == 1, "provider did not retain exactly one intended event")
    return matches[0]


def leave_saved(terminal):
    terminal.send(b"\x1b")
    terminal.until(lambda: "Saved in Calendar." not in terminal.text()
                   and any("Calendar · " + view in terminal.text() for view in ("Agenda", "Day", "Week")))


def timed(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional roadmap review café"
    first, _ = new_dates()
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        fill(terminal, "Location", "Studio 4")
        fill(terminal, "Notes", 'Discuss the next release. Bring "notes".')
        capture(terminal, captures, "compose-timed-form-132")
        review(terminal, title, binary, client_dir, fixture, 0, captures, "timed-review-132")
        # Backing out of review must not convert Enter/navigation into consent.
        terminal.send(b"\r")
        terminal.until(lambda: "New event" in terminal.text() and "Review new event" not in terminal.text())
        provider_counts(binary, client_dir, fixture, 0)
        review(terminal, title, binary, client_dir, fixture, 0)
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require(saved["start"]["dateTime"].startswith(first + "T17:30:00"), "timed event saved the wrong start")
        require(saved["end"]["dateTime"].startswith(first + "T18:15:00"), "timed event saved the wrong end")
        require(saved["location"] == "Studio 4" and 'Bring "notes".' in saved["description"],
                "location or literal escaped notes changed during review")
        capture(terminal, captures, "compose-timed-saved")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "beforeConfirmationWrites": 0, "timed": True, "literalNotes": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def all_day(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional planning retreat"
    first, last = new_dates(6)
    exclusive = (datetime.fromisoformat(last) + timedelta(days=1)).date().isoformat()
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first, last, all_day=True)
        require("Start time:" not in terminal.text() and "End time:" not in terminal.text(),
                "all-day form still exposes timed clock fields")
        capture(terminal, captures, "compose-all-day-form")
        review(terminal, title, binary, client_dir, fixture, 0)
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require(saved["start"] == {"date": first} and saved["end"] == {"date": exclusive},
                "inclusive UI last date was not translated exactly once to provider exclusive end")
        leave_saved(terminal)
        # Reopening an all-day event must show its inclusive UI last date.
        terminal.send(b"/" + title.encode() + b"\r")
        terminal.until(lambda: "Filter: " + title in terminal.text())
        terminal.send(b"e")
        terminal.until(lambda: "Edit event" in terminal.text() and "Last date (included):" in terminal.text())
        require(last in row_text(terminal, "Last date (included):"), "all-day edit exposed the exclusive provider date")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Edit event" not in terminal.text())
        terminal.finish()
        return {"writes": 1, "inclusiveEditorDates": True, "exclusiveProviderEnd": exclusive, "editRoundTrip": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def link_guests(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional cross-platform video call"
    first, _ = new_dates(3)
    join = "https://video.example.test/room?source=tui&literal=1"
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        fill(terminal, "Guests", "guest@example.test, GUEST@example.test")
        terminal.send(b"\x13")
        terminal.until(lambda: "appears more than once" in terminal.text() or "DuplicateCalendarAttendee" in terminal.text())
        provider_counts(binary, client_dir, fixture, 0)
        # Ordinary single-line Mail syntax; the provider still gets bare emails.
        fill(terminal, "Guests", '"Guest, One" <guest@example.test>, second@example.test')
        toggle(terminal, "Video: None", "Video: Generate Google Meet link")
        toggle(terminal, "Video: Generate Google Meet link", "Video: Paste meeting link")
        fill(terminal, "Meeting link", "http://unsafe.example.test/room")
        terminal.send(b"\x13")
        terminal.until(lambda: "complete HTTPS meeting link" in terminal.text() or "safe https" in terminal.text())
        provider_counts(binary, client_dir, fixture, 0)
        fill(terminal, "Meeting link", join)
        review(terminal, title, binary, client_dir, fixture, 0, captures, "link-guests-review")
        require("email 2 guests" in terminal.text(), "confirmation button hid the consequence of inviting guests")
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require({entry["email"] for entry in saved["attendees"]} == {"guest@example.test", "second@example.test"},
                "guest addresses were lost or combined")
        require(join in saved["description"], "pasted meeting link was not retained in the saved event")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "emailConsequenceInConfirmation": True, "duplicateGuestRejected": True,
                "safePastedLink": True, "guestCount": 2}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def cancel_narrow(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=48, rows=24)
    title = "Unsaved narrow event"
    first, _ = new_dates()
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        fill(terminal, "Notes", "Only local text, never saved.")
        require(focused_field(terminal, "Notes"), "narrow editor did not scroll to the Notes field")
        capture(terminal, captures, "compose-narrow-notes-48")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
        terminal.send(b"ordinary typing must not discard")
        terminal.gap(.1)
        require("Discard your unsaved event?" in terminal.text(), "plain typing dismissed the unsaved event guard")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Discard your unsaved event?" not in terminal.text() and "New event" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
        terminal.send(b"\x04")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text()
                       and "Discard your unsaved event?" not in terminal.text()
                       and not focused_field(terminal, "Title"))
        provider_counts(binary, client_dir, fixture, 0)
        terminal.finish()
        return {"writes": 0, "columns": 48, "fieldScrolling": True, "dirtyDiscardGuard": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def edit_latest(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    first, _ = new_dates(2)
    title = "Fictional editable appointment"
    # Establish an organizer-owned event through the same reviewed public API.
    with Client(binary, client_dir, extra=fixture.options()) as client:
        client.request("calendar.list")
        reviewed = client.request("calendar.event-review", calendarId=ACCOUNTS[0], operationId="seed-editable-event",
                                  sendUpdates="none", event={"summary": title, "start": first + "T13:00",
                                  "end": first + "T14:00", "timeZone": "UTC", "allDay": False, "conference": "none"})
        applied = client.request("calendar.event-apply", calendarId=ACCOUNTS[0], operationId=reviewed["operationId"],
                                 reviewHash=reviewed["reviewHash"])
        require(applied["state"] == "applied", "synthetic organizer-owned event was not created")
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.send(b"/" + title.encode() + b"\r")
        terminal.until(lambda: "Filter: " + title in terminal.text())
        # A different Calendar client changes the event after the agenda read.
        paths = list((client_dir / "cache").rglob("calendar-provider-fixture.json"))
        paths = [path for path in paths if json.loads(path.read_text())["account"] == ACCOUNTS[0]]
        require(len(paths) == 1, "provider account identity ambiguous")
        path = paths[0]
        saved = json.loads(path.read_text())
        event = next(entry["value"] for entry in saved["events"] if entry["value"].get("summary") == title)
        event_id = event["id"]
        event["etag"] = '"edited-before-opening-editor"'
        replacement = path.with_name(path.name + ".compose-test")
        replacement.write_text(json.dumps(saved) + "\n")
        replacement.chmod(0o600)
        replacement.replace(path)
        terminal.send(b"e")
        terminal.until(lambda: "Edit event" in terminal.text() and focused_field(terminal, "Title"))
        fill(terminal, "Start time", "15:30")
        fill(terminal, "End time", "16:45")
        review(terminal, title, binary, client_dir, fixture, 1, captures, "edit-review-latest-etag")
        state_files = list((client_dir / "cache").rglob("calendar-state.json"))
        bound = []
        for state_file in state_files:
            value = json.loads(state_file.read_text())
            if value.get("account") != ACCOUNTS[0]:
                continue
            bound += [entry["review"]["intent"] for entry in value["entries"] if entry.get("review")
                      and entry["review"]["intent"].get("event_id") == event_id
                      and entry["review"]["intent"].get("kind") == "update_event"]
        require(len(bound) == 1 and bound[0]["expected_etag"] == '"edited-before-opening-editor"',
                "editor used stale agenda ETag rather than the fresh event read")
        confirm(terminal, 2, binary, client_dir, fixture)
        edited = find_saved(binary, client_dir, fixture, title)
        require(edited["id"] == event_id and edited["start"]["dateTime"].startswith(first + "T15:30:00")
                and edited["end"]["dateTime"].startswith(first + "T16:45:00"),
                "moving the event created another event or saved different times")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 2, "freshEtag": True, "sameProviderEventId": True, "movedTime": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def fold_choice(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional repeated-hour appointment"
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, "2026-10-25")
        fill(terminal, "Start time", "02:30")
        fill(terminal, "End time", "03:30")
        fill(terminal, "Time zone", "Europe/Vienna")
        terminal.send(b"\x13")
        terminal.until(lambda: "occurs twice" in terminal.text() or "AmbiguousLocalTime" in terminal.text())
        provider_counts(binary, client_dir, fixture, 0)
        toggle(terminal, "Start occurrence: choose", "Start occurrence: first")
        toggle(terminal, "Start occurrence: first", "Start occurrence: second")
        capture(terminal, captures, "compose-fold-second-occurrence")
        review(terminal, title, binary, client_dir, fixture, 0)
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        actual_start = datetime.fromisoformat(saved["start"]["dateTime"].replace("Z", "+00:00"))
        actual_end = datetime.fromisoformat(saved["end"]["dateTime"].replace("Z", "+00:00"))
        require(actual_start == datetime(2026, 10, 25, 1, 30, tzinfo=timezone.utc),
                "second fold occurrence did not retain the reviewed +01:00 instant")
        require(actual_end == datetime(2026, 10, 25, 2, 30, tzinfo=timezone.utc),
                "fold event end was shifted into a different UTC instant")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "noImplicitFoldChoice": True, "selectedOccurrence": "second", "startUtc": actual_start.isoformat()}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def google_meet(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional Google Meet planning"
    first, _ = new_dates(2)
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        toggle(terminal, "Video: None", "Video: Generate Google Meet link")
        fill(terminal, "Guests", "guest@example.test")
        review(terminal, title, binary, client_dir, fixture, 0, captures, "google-meet-review")
        require("Google Meet" in terminal.text() and "email 1 guest" in terminal.text(),
                "Meet review hid conference generation or the invitation email consequence")
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        conference = saved.get("conferenceData", {})
        request = conference.get("createRequest", {})
        require(bool(request.get("requestId")) and request.get("conferenceSolutionKey", {}).get("type") == "hangoutsMeet",
                "Google Meet creation request was not persisted with the intended event")
        require(request.get("status", {}).get("statusCode") in ("pending", "success"),
                "conference status was not retained")
        video_links = [entry["uri"] for entry in conference.get("entryPoints", []) if entry.get("entryPointType") == "video"]
        if request["status"]["statusCode"] == "success":
            require(video_links and video_links[0].startswith("https://meet.google.com/"), "successful Meet has no video link")
        require(saved["attendees"][0]["email"] == "guest@example.test", "Meet event lost its invited guest")
        capture(terminal, captures, "compose-google-meet-saved")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "beforeConfirmationWrites": 0, "googleMeet": True,
                "conferenceStatus": request["status"]["statusCode"], "guestCount": 1}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def html_notes_readonly(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    first, _ = new_dates(2)
    original_title = "Fictional formatted appointment"
    title = "Updated formatted appointment"
    html = '<p>Bring <b>notes</b>.</p><p><a href="https://meet.example.test/existing">Join our meeting</a></p>'
    with Client(binary, client_dir, extra=fixture.options()) as client:
        reviewed = client.request("calendar.event-review", calendarId=ACCOUNTS[0], operationId="seed-formatted-event",
                                  sendUpdates="none", event={"summary": original_title, "start": first + "T13:00",
                                  "end": first + "T14:00", "timeZone": "UTC", "allDay": False,
                                  "description": html, "conference": "none"})
        applied = client.request("calendar.event-apply", calendarId=ACCOUNTS[0], operationId=reviewed["operationId"],
                                 reviewHash=reviewed["reviewHash"])
        require(applied["state"] == "applied", "formatted synthetic organizer event was not created")
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.send(b"/" + original_title.encode() + b"\r")
        terminal.until(lambda: "Filter: " + original_title in terminal.text())
        terminal.send(b"e")
        terminal.until(lambda: "Edit event" in terminal.text() and "formatted notes kept unchanged" in terminal.text())
        fill(terminal, "Title", title)
        click(terminal, *point(terminal, "Notes: formatted notes kept unchanged"))
        terminal.send(b"plain insertion must be ignored\x1b[200~<p>replacement must be ignored</p>\x1b[201~")
        terminal.gap(.15)
        require("formatted notes kept unchanged" in terminal.text() and "insertion must" not in terminal.text()
                and "replacement must" not in terminal.text(), "formatted notes accepted plain editing or paste")
        capture(terminal, captures, "compose-formatted-notes-readonly")
        review(terminal, title, binary, client_dir, fixture, 1, captures, "formatted-notes-review")
        require("formatted notes kept unchanged" in terminal.text(), "review hid the formatted-notes preservation policy")
        confirm(terminal, 2, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require(saved["description"] == html, "title-only edit flattened or replaced original formatted notes")
        require("https://meet.example.test/existing" in saved["description"], "editing removed the existing join link")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 2, "formattedNotesPreservedExactly": True, "readonlyMouseAndPaste": True,
                "existingJoinPreserved": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def edit_dst_review_twice(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    title = "Fictional autumn reschedule"
    with Client(binary, client_dir, extra=fixture.options()) as client:
        reviewed = client.request("calendar.event-review", calendarId=ACCOUNTS[0], operationId="seed-autumn-event",
                                  sendUpdates="none", event={"summary": title, "start": "2026-10-24T13:00",
                                  "end": "2026-10-24T14:00", "timeZone": "Europe/Vienna", "allDay": False,
                                  "conference": "none"})
        applied = client.request("calendar.event-apply", calendarId=ACCOUNTS[0], operationId=reviewed["operationId"],
                                 reviewHash=reviewed["reviewHash"])
        require(applied["state"] == "applied", "autumn synthetic event was not created")
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.send(b"\x07")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        terminal.send(b"\x05" + b"\x7f" * 10 + b"2026-10-24\r")
        wait_calendar(terminal)
        terminal.send(b"/" + title.encode() + b"\r")
        terminal.until(lambda: "Filter: " + title in terminal.text())
        terminal.send(b"e")
        terminal.until(lambda: "Edit event" in terminal.text() and focused_field(terminal, "Title"))
        require("Europe/Vienna" in row_text(terminal, "Time zone:"), "editor lost the provider event zone")
        fill(terminal, "Start date", "2026-11-05")
        fill(terminal, "End date", "2026-11-05")
        review(terminal, title, binary, client_dir, fixture, 1)
        terminal.send(b"\r")
        terminal.until(lambda: "Edit event" in terminal.text() and "Review event changes" not in terminal.text())
        review(terminal, title, binary, client_dir, fixture, 1, captures, "autumn-second-review")
        confirm(terminal, 2, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        actual = datetime.fromisoformat(saved["start"]["dateTime"].replace("Z", "+00:00"))
        require(actual == datetime(2026, 11, 5, 12, 0, tzinfo=timezone.utc),
                "repeated review reused October's hidden +02:00 offset for November")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 2, "reviewedTwice": True, "staleHiddenOffsets": False, "startUtc": actual.isoformat()}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def removed_guests(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional solo appointment"
    first, _ = new_dates(2)
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        fill(terminal, "Guests", "temporary@example.test")
        review(terminal, title, binary, client_dir, fixture, 0)
        require("email 1 guest" in terminal.text(), "first review did not disclose its temporary invitation")
        terminal.send(b"\r")
        terminal.until(lambda: "New event" in terminal.text() and "Review new event" not in terminal.text())
        fill(terminal, "Guests", "")
        review(terminal, title, binary, client_dir, fixture, 0, captures, "removed-guests-no-emails")
        require("& email" not in terminal.text() and "No guest update emails requested" in terminal.text(),
                "removing all new-event guests retained the previous email invitation policy")
        matching = []
        for path in (client_dir / "cache").rglob("calendar-state.json"):
            document = json.loads(path.read_text())
            if document.get("account") != ACCOUNTS[0]:
                continue
            matching.extend(entry["review"] for entry in document["entries"]
                            if entry.get("review") and entry["review"].get("ordinary_event", {}).get("draft", {}).get("summary") == title
                            and entry["review"]["ordinary_event"]["send_updates"] == "none")
        require(len(matching) == 1 and matching[0]["ordinary_event"]["send_updates"] == "none"
                and "sendUpdates=none" in matching[0]["request"]["url"],
                "actual prepared event request retained sendUpdates=all after guest removal")
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require(not saved.get("attendees"), "removed temporary guest was still invited")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "removedTemporaryGuest": True, "finalSendUpdates": "none", "beforeConfirmationWrites": 0}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()



def saved_entries(directory):
    documents = [json.loads(path.read_text()) for path in (directory / "cache").rglob("calendar-state.json")]
    return [entry for document in documents if document.get("account") == ACCOUNTS[0]
            for entry in document["entries"]]


def read_attempts(binary, directory, fixture, expected_writes, expected_attempts):
    document = state(binary, directory, fixture)
    require(document["writes"] == expected_writes and document["dispatch_attempts"] == expected_attempts,
            "read-only recovery or unconfirmed controls changed provider dispatch attempts")
    return document


def reach_review_end(terminal):
    # Recovery reserves Ctrl+D for its own explicit archive confirmation.
    # Plain navigation remains read-only in every outcome/review state.
    for _ in range(45):
        terminal.send(b"j")
        terminal.gap(.01)


def submit_unknown(terminal, binary, directory, fixture, title, captures=None):
    review(terminal, title, binary, directory, fixture, 0)
    reach_review_end(terminal)
    terminal.send(b"y")
    terminal.until(lambda: "Check Calendar outcome" in terminal.text() and "Outcome unknown" in terminal.text())
    read_attempts(binary, directory, fixture, 0, 1)
    entries = saved_entries(directory)
    require(len(entries) == 1 and entries[0]["state"]["operation"]["state"] == "unknown",
            "uncertain TUI save did not retain its exact durable operation")
    capture(terminal, captures, "compose-unknown-first-response")
    return entries[0]["review"]


def resume_pending(terminal, title):
    terminal.send(b"C")
    wait_calendar(terminal)
    terminal.send(b"n")
    terminal.until(lambda: "Check Calendar outcome" in terminal.text()
                   and "Resumed an uncertain save" in terminal.text() and title in terminal.text())


def recovery_retry(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    title = "Fictional recovered appointment"
    first, _ = new_dates(3)
    terminal = start(binary, client_dir, fixture, scenario="calendar-prewrite-unavailable", columns=132, rows=38)
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        original = submit_unknown(terminal, binary, client_dir, fixture, title, captures)
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    # A fresh process represents provider recovery. The saved request and
    # outcome survive exactly; the user still must check, review and confirm.
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    try:
        resume_pending(terminal, title)
        read_attempts(binary, client_dir, fixture, 0, 1)
        terminal.send(b"\x12")
        terminal.gap(.15)
        require("Retry this saved Calendar request?" not in terminal.text(),
                "retry became available before a read-only provider check")
        before = terminal.screen.completed_frames
        terminal.send(b"r")
        terminal.until(lambda: terminal.screen.completed_frames > before and
                       "No saved event found" in terminal.text())
        read_attempts(binary, client_dir, fixture, 0, 1)
        terminal.send(b"\x12")
        terminal.until(lambda: "Retry this saved Calendar request?" in terminal.text())
        read_attempts(binary, client_dir, fixture, 0, 1)
        capture(terminal, captures, "compose-identical-retry-confirmation")
        reach_review_end(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Event saved" in terminal.text() and "Saved in Calendar." in terminal.text())
        read_attempts(binary, client_dir, fixture, 1, 2)
        saved = find_saved(binary, client_dir, fixture, title)
        require(saved["id"] == original["intent"]["event_id"], "explicit retry changed stable event identity")
        entries = saved_entries(client_dir)
        require(len(entries) == 1 and entries[0]["state"]["operation"]["state"] == "applied"
                and entries[0]["state"]["operation"]["attempt"] == 1,
                "explicit retry lost its same-operation bounded attempt history")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "dispatchAttempts": 2, "readOnlyCheckWrites": 0,
                "explicitRetryConfirmation": True, "sameEventIdentity": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def recovery_restart(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    title = "Fictional pending leave"
    first, last = new_dates(5)
    terminal = start(binary, client_dir, fixture, scenario="calendar-prewrite-unavailable", columns=132, rows=38)
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first, last, all_day=True)
        original = submit_unknown(terminal, binary, client_dir, fixture, title)
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    try:
        resume_pending(terminal, title)
        require(first in terminal.text() and last in terminal.text(), "restored all-day review changed its inclusive dates")
        restored = saved_entries(client_dir)
        require(len(restored) == 1 and restored[0]["review"] == original,
                "opening New after restart replaced an uncertain saved request")
        read_attempts(binary, client_dir, fixture, 0, 1)
        terminal.send(b"new title must not be typed into recovered review")
        terminal.gap(.15)
        read_attempts(binary, client_dir, fixture, 0, 1)
        require(title in terminal.text() and "New event" not in terminal.text(),
                "pending operation unexpectedly became a writable new-event form")
        capture(terminal, captures, "compose-pending-restart-all-day")
        terminal.finish()
        return {"writes": 0, "dispatchAttempts": 1, "exactReviewRestored": True, "allDay": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def recovery_archive(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    title = "Fictional archived uncertainty"
    first, _ = new_dates(4)
    with Client(binary, client_dir, scenario="calendar-prewrite-unavailable", extra=fixture.options()) as client:
        reviewed = client.request("calendar.event-review", calendarId=ACCOUNTS[0], operationId="archive-uncertain-event",
                                  sendUpdates="none", event={"summary": title, "start": first + "T13:00",
                                  "end": first + "T14:00", "timeZone": "UTC", "allDay": False,
                                  "conference": "none"})
        applied = client.request("calendar.event-apply", calendarId=ACCOUNTS[0], operationId=reviewed["operationId"],
                                 reviewHash=reviewed["reviewHash"])
        require(applied["state"] == "unknown", "prewrite failure did not retain uncertainty")
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    try:
        resume_pending(terminal, title)
        terminal.send(b"\x04")
        terminal.until(lambda: "Archive this uncertain outcome?" in terminal.text())
        read_attempts(binary, client_dir, fixture, 0, 1)
        terminal.send(b"\x1b")
        terminal.until(lambda: "Review archiving uncertainty" in terminal.text()
                       and "Archive this uncertain outcome?" not in terminal.text())
        require(saved_entries(client_dir)[0]["state"]["operation"]["state"] == "unknown",
                "canceling the archive confirmation discarded uncertainty")
        terminal.send(b"\x04")
        terminal.until(lambda: "Archive this uncertain outcome?" in terminal.text())
        capture(terminal, captures, "compose-archive-uncertainty-confirmation")
        reach_review_end(terminal)
        terminal.send(b"y")
        terminal.until(lambda: "Uncertainty archived" in terminal.text())
        read_attempts(binary, client_dir, fixture, 0, 1)
        require(saved_entries(client_dir)[0]["state"]["operation"]["state"] == "archived",
                "confirmed archive did not retain a durable archived receipt")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Calendar · Agenda" in terminal.text() and "Check Calendar outcome" not in terminal.text()
                       and "Edit event" not in terminal.text())
        terminal.finish()
        return {"writes": 0, "dispatchAttempts": 1, "archiveConfirmation": True,
                "cancelKeptUnknown": True, "archivedReceiptRetained": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()

def cancel_fresh(binary, directory, captures):
    for columns, rows in ((132, 38), (48, 24)):
        owned = directory / str(columns)
        fixture = Invitations(owned)
        client_dir = owned / "client"
        terminal = start(binary, client_dir, fixture, columns=columns, rows=rows)
        try:
            open_new(terminal)
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            terminal.send(b"n")
            terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))
            cancel_point = point(terminal, "[Esc Cancel]")
            click(terminal, *cancel_point)
            wait_calendar(terminal)
            terminal.send(b"n")
            terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))
            fill(terminal, "Title", "Keep my typed event")
            cancel_point = point(terminal, "[Esc Cancel]")
            click(terminal, *cancel_point)
            terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
            capture(terminal, captures, "compose-cancel-dirty-" + str(columns))
            click(terminal, *cancel_point)
            terminal.gap(.15)
            require("Discard your unsaved event?" in terminal.text(), "old underlying Cancel discarded a modified event")
            click(terminal, *point(terminal, "[Esc Keep editing]"))
            terminal.until(lambda: "Discard your unsaved event?" not in terminal.text())
            require("Keep my typed event" in terminal.text(), "Keep editing lost typed title")
            terminal.send(b"\x1b")
            terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
            terminal.send(b"\x1b")
            terminal.until(lambda: "Discard your unsaved event?" not in terminal.text())
            terminal.send(b"\x1b")
            terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
            click(terminal, *point(terminal, "[Ctrl+D Discard]"))
            wait_calendar(terminal)
            terminal.send(b"n")
            terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))
            require("Keep my typed event" not in terminal.text(), "reopening New retained discarded fields")
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            terminal.gap(.3)
            require("[Esc Cancel]" not in terminal.text() and "Discard your unsaved event?" not in terminal.text(),
                    "late completion reopened a canceled event")
            provider_counts(binary, client_dir, fixture, 0)
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
    return {"writes": 0, "widths": [132, 48], "freshEscape": True, "freshMouseCancel": True,
            "discardModal": True, "noLateDialog": True}


def contacts_fixture(fixture):
    target = fixture.root / "contacts"
    target.mkdir()
    source = Path(__file__).parent / "fixtures" / "terminal" / "contacts"
    for key in ("personal", "work", "optional"):
        value = json.loads((source / (key + ".json")).read_text())
        if key == "work":
            value["connections"][0]["emailAddresses"].append({"value": "alex-work-alt@example.org", "type": "other"})
        (target / (key + ".json")).write_text(json.dumps(value) + "\n")


def open_guest_contacts(terminal, keyboard=True):
    focus_field(terminal, "Guests")
    if keyboard:
        terminal.send(b"\x00")  # Actual legacy Ctrl+Space -> vaxis Ctrl+@.
    else:
        if terminal.screen.locate("[Ctrl+Space Contacts · recent mail]") is None:
            next_control(terminal)
        click(terminal, *point(terminal, "[Ctrl+Space Contacts · recent mail]"))
    terminal.until(lambda: "Add a guest from Contacts" in terminal.text())


def guest_contacts(binary, directory, captures):
    for columns, rows in ((132, 38), (48, 24)):
        owned = directory / str(columns)
        fixture = Invitations(owned)
        contacts_fixture(fixture)
        client_dir = owned / "client"
        # Establish a complete saved address book for both exact account owners.
        with Client(binary, client_dir, extra=fixture.options()) as client:
            before_personal = client.request("contacts.list", ACCOUNTS[0])
            before_work = client.request("contacts.list", ACCOUNTS[1])
        terminal = start(binary, client_dir, fixture, columns=columns, rows=rows)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            terminal.send(b"ga")
            terminal.until(lambda: "Show calendars · all accounts" in terminal.text() and "9 checked" in terminal.text()
                           and "[Enter Apply]" in terminal.text() and "[Loading calendars" not in terminal.text())
            terminal.send(b"\r")
            terminal.until(lambda: "All accounts" in terminal.text() and "9 selected calendars" in terminal.text())
            terminal.send(b"n")
            terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))
            toggle(terminal, "[Calendar:", "Choose destination calendar")
            for _ in range(3):
                terminal.send(b"j")
                terminal.gap(.05)
            terminal.send(b"\r")
            terminal.until(lambda: "New event" in terminal.text() and ACCOUNTS[1] in terminal.text())
            first, _ = new_dates()
            ordinary_fields(terminal, "Guest address book " + str(columns), first)
            fill(terminal, "Guests", "typed@example.test")
            open_guest_contacts(terminal)
            terminal.until(lambda: "alex-work-alt@example.org" in terminal.text())
            require(ACCOUNTS[1] in terminal.text() and "Alex Work Fixture" in terminal.text(),
                    "guest picker used the Mail account instead of destination account")
            capture(terminal, captures, "compose-guests-work-" + str(columns))
            terminal.resize(29, 10)
            terminal.until(lambda: "resize terminal" in terminal.text())
            terminal.send(b"\r")
            terminal.gap(.1)
            terminal.resize(columns, rows)
            terminal.until(lambda: "Add a guest from Contacts" in terminal.text() and "alex-work-alt@example.org" in terminal.text())
            terminal.send(b"alex-work-alt\r")
            terminal.until(lambda: "Add a guest from Contacts" not in terminal.text())
            require("alex-work-alt@example.org" in row_text(terminal, "Guests:"), "explicit second email did not reach Guests")
            require("Alex Work" not in row_text(terminal, "Guests:"), "Calendar received a display mailbox instead of bare email")
            open_guest_contacts(terminal, keyboard=False)
            terminal.send(b"ALEX-WORK-ALT\r")
            terminal.until(lambda: "already a guest" in terminal.text())
            capture(terminal, captures, "compose-guests-duplicate-" + str(columns))
            click(terminal, *point(terminal, "[Esc Back]"))
            terminal.until(lambda: "Add a guest from Contacts" not in terminal.text())
            provider_counts(binary, client_dir, fixture, 0)
            review(terminal, "Guest address book " + str(columns), binary, client_dir, fixture, 0)
            # The exact durable review independently proves the chosen address
            # plus typed email; there has been no provider event write.
            entries = []
            for path in (client_dir / "cache").rglob("calendar-state.json"):
                document = json.loads(path.read_text())
                if document.get("account") == ACCOUNTS[1]:
                    entries += [entry["review"] for entry in document["entries"] if entry.get("review")]
            reviewed = next(item for item in entries if item["intent"]["kind"] == "insert_event")
            raw = json.dumps(reviewed)
            require("alex-work-alt@example.org" in raw and "typed@example.test" in raw and "alex-work@example.org" not in raw,
                    "review did not preserve exact manual and second contact addresses")
            terminal.send(b"\x1b")
            terminal.until(lambda: "[Esc Cancel]" in terminal.text() and "Review new event" not in terminal.text())
            terminal.send(b"\x1b")
            terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
            terminal.send(b"\x04")
            wait_calendar(terminal)
            with Client(binary, client_dir, extra=fixture.options()) as client:
                require(client.request("contacts.list", ACCOUNTS[0]) == before_personal, "guest selection changed Mail contacts")
                require(client.request("contacts.list", ACCOUNTS[1]) == before_work, "guest selection edited destination contacts")
                require(not client.request("draft.list")["drafts"], "Calendar guest picker created a Mail draft")
                require(provider_state(client, ACCOUNTS[1])["writes"] == 0, "reviewed contact choice wrote destination Calendar")
            provider_counts(binary, client_dir, fixture, 0)
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
    return {"writes": 0, "widths": [132, 48], "destinationAccount": True, "rawCtrlSpace": True,
            "explicitSecondEmail": True, "caseInsensitiveDedup": True, "reviewedOnly": True, "contactsUnchanged": True}

def guest_recent(binary, directory, captures):
    for columns, rows in ((132, 38), (48, 24)):
        owned = directory / str(columns)
        fixture = Invitations(owned)
        contacts_fixture(fixture)
        # Invitations starts with Inbox-only mail. Add an explicit synthetic
        # Sent message rather than assuming its fixture has correspondents.
        provider_file = fixture.root / "accounts" / (ACCOUNTS[1].split("@")[0] + ".json")
        provider = json.loads(provider_file.read_text())
        recent_message = fixture.message(ACCOUNTS[1], 99, False)
        recent_message.update(id="recent-guest-sent", threadId="recent-guest-thread", labelIds=["SENT"])
        for header in recent_message["payload"]["headers"]:
            if header["name"] == "From":
                header["value"] = ACCOUNTS[1]
            elif header["name"] == "To":
                header["value"] = "Robin Recent <robin.recent@example.test>"
        provider["messages"].append(recent_message)
        provider_file.write_text(json.dumps(provider) + "\n")
        client_dir = owned / "client"
        # Synthetic fixture only: cache the destination account's bounded Sent
        # head and contacts, then pick a sent recipient who is not saved.
        with Client(binary, client_dir, extra=fixture.options()) as client:
            saved = {email["address"].lower() for contact in client.request("contacts.list", ACCOUNTS[1])["contacts"]
                     for email in contact.get("emails", [])}
            sent_head = client.request("mail.list", ACCOUNTS[1], label="SENT", limit=32).get("messages", [])
            sent = [client.request("mail.read", ACCOUNTS[1], messageId=item["id"]) for item in sent_head]
            cached = {item["address"].lower() for item in client.request("mail.recipients", ACCOUNTS[1], cacheOnly=True)["recipients"]}
        excluded = saved | {account.lower() for account in ACCOUNTS}
        person = next((entry["address"] for message in sent for entry in message.get("to", [])
                       if isinstance(entry, dict) and entry.get("address", "").lower() in cached
                       and entry["address"].lower() not in excluded), None)
        require(person, "fixture has no cached Sent recipient outside saved contacts")
        terminal = start(binary, client_dir, fixture, columns=columns, rows=rows)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            terminal.send(b"ga")
            terminal.until(lambda: "Show calendars · all accounts" in terminal.text() and "9 checked" in terminal.text()
                           and "[Enter Apply]" in terminal.text() and "[Loading calendars" not in terminal.text())
            terminal.send(b"\r")
            terminal.until(lambda: "All accounts" in terminal.text() and "9 selected calendars" in terminal.text())
            terminal.send(b"n")
            terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))
            toggle(terminal, "[Calendar:", "Choose destination calendar")
            for _ in range(3):
                terminal.send(b"j")
                terminal.gap(.05)
            terminal.send(b"\r")
            terminal.until(lambda: "New event" in terminal.text() and ACCOUNTS[1] in terminal.text())
            first, _ = new_dates()
            ordinary_fields(terminal, "Guest recent mail " + str(columns), first)
            fill(terminal, "Guests", "typed@example.test")
            # Mail stays on ACCOUNTS[0]; the picker reads the Calendar destination.
            open_guest_contacts(terminal)
            terminal.until(lambda: "Add a guest from Contacts or recent mail" in terminal.text() and ACCOUNTS[1] in terminal.text()
                           and "Loading this account" not in terminal.text())
            terminal.send(person.encode())
            terminal.until(lambda: person in terminal.text() and "No matching contacts" not in terminal.text())
            capture(terminal, captures, "compose-guests-recent-" + str(columns))
            provider_counts(binary, client_dir, fixture, 0)
            terminal.send(b"\r")
            terminal.until(lambda: "Add a guest from Contacts" not in terminal.text())
            require(person in row_text(terminal, "Guests:"), "recent-mail recipient did not reach Guests")
            provider_counts(binary, client_dir, fixture, 0)
            review(terminal, "Guest recent mail " + str(columns), binary, client_dir, fixture, 0)
            entries = []
            for path in (client_dir / "cache").rglob("calendar-state.json"):
                document = json.loads(path.read_text())
                if document.get("account") == ACCOUNTS[1]:
                    entries += [entry["review"] for entry in document["entries"] if entry.get("review")]
            reviewed = next(item for item in entries if item["intent"]["kind"] == "insert_event")
            raw = json.dumps(reviewed)
            require(person in raw and "typed@example.test" in raw, "review did not keep typed guest and add the recent recipient")
            terminal.send(b"\x1b")
            terminal.until(lambda: "[Esc Cancel]" in terminal.text() and "Review new event" not in terminal.text())
            terminal.send(b"\x1b")
            terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
            terminal.send(b"\x04")
            wait_calendar(terminal)
            with Client(binary, client_dir, extra=fixture.options()) as client:
                require(not client.request("draft.list")["drafts"], "Calendar guest picker created a Mail draft")
                require(provider_state(client, ACCOUNTS[1])["writes"] == 0, "recent-mail guest choice wrote destination Calendar")
            provider_counts(binary, client_dir, fixture, 0)
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
    return {"writes": 0, "widths": [132, 48], "destinationAccount": True, "recentNotSaved": True,
            "typedGuestPreserved": True, "reviewedOnly": True}

def guest_fallback(binary, directory, captures):
    for columns, rows in ((132, 38), (48, 24)):
        for phase in ("empty", "unavailable"):
            owned = directory / (str(columns) + phase)
            fixture = Invitations(owned)
            if phase == "empty":
                (fixture.root / "contacts").mkdir()
                (fixture.root / "contacts" / "personal.json").write_text(json.dumps({"account": ACCOUNTS[0], "connections": []}) + "\n")
            client_dir = owned / "client"
            terminal = start(binary, client_dir, fixture, columns=columns, rows=rows)
            try:
                open_new(terminal)
                fill(terminal, "Guests", "manual@example.test")
                open_guest_contacts(terminal)
                if phase == "empty":
                    # Cached recent mail may still list correspondents; prove
                    # the empty address book with a query nothing matches.
                    terminal.until(lambda: "Loading this account" not in terminal.text())
                    terminal.send(b"zz-no-such-guest")
                    # A loaded-list miss is not claimed as a Contacts miss.
                    terminal.until(lambda: "No loaded match" in terminal.text() and "Ctrl+F Search Contacts" in terminal.text())
                    terminal.send(b"\x06")
                terminal.until(lambda: ("No matching contacts" if phase == "empty" else "Ctrl+R Retry") in terminal.text())
                require("Or type email addresses in Guests." in terminal.text(), "narrow picker hid manual email fallback")
                capture(terminal, captures, "compose-guests-" + phase + "-" + str(columns))
                # Empty/disabled Add has no changing paint; do not require a
                # new synchronized frame for each intermediate Tab stop.
                # Search, results, [Search Contacts], Add, then Back.
                terminal.send(b"\t\t\t\t\r")
                terminal.until(lambda: "Add a guest from Contacts" not in terminal.text())
                require("manual@example.test" in row_text(terminal, "Guests:"), "unavailable contact lookup changed typed guest")
                terminal.send(b"\x1b")
                terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
                terminal.send(b"\x04")
                wait_calendar(terminal)
                provider_counts(binary, client_dir, fixture, 0)
                terminal.finish()
            except Exception:
                print(terminal.text(), file=sys.stderr)
                raise
            finally:
                terminal.close()
    return {"writes": 0, "widths": [132, 48], "states": ["empty", "unavailable"], "manualFallbackVisible": True,
            "typedGuestPreserved": True, "backKeyboard": True}

def guest_search(binary, directory, captures):
    """Ctrl+F routing beside loaded local matches, partial warnings, named guests.

    The synthetic contacts fixture serves its whole address book to both
    contacts.list and contacts.search, so this PTY case proves only the TUI
    routing and display: the explicit search is dispatched and applied while
    loaded matches are already shown. It makes no beyond-the-head claim. The
    100-row head / 30-row search boundary is proven by the deterministic TUI
    unit tests and by root's production Gmail dispatch test
    (src/contact_isolation_tests.zig).
    """
    for columns, rows in ((132, 38), (48, 24)):
        owned = directory / str(columns)
        fixture = Invitations(owned)
        (fixture.root / "contacts").mkdir()
        def person(index, name, email):
            return {"resourceName": "people/guest-search-%03d" % index, "etag": "guest-search-v%d" % index,
                    "metadata": {"sources": [{"type": "CONTACT", "id": "guest-search-%03d" % index, "etag": "s%d" % index}]},
                    "names": [{"displayName": name}], "emailAddresses": [{"value": email}]}
        # One unreadable record (no resourceName) is omitted with a warning.
        connections = [{"names": [{"displayName": "Unreadable fixture"}], "emailAddresses": [{"value": "unreadable@example.test"}]},
                       person(0, "Morgan Beyond", "morgan.beyond@example.test"), person(1, "Robin Other", "robin.other@example.test")]
        (fixture.root / "contacts" / "personal.json").write_text(json.dumps({"account": ACCOUNTS[0], "connections": connections}) + "\n")
        client_dir = owned / "client"
        with Client(binary, client_dir, extra=fixture.options()) as client:
            head = client.request("contacts.list", ACCOUNTS[0])
        omitted = head.get("contactWarnings", {}).get("omittedContacts", 0)
        require(head.get("partial") is True and omitted >= 1, "fixture did not produce a successful partial contacts read")
        terminal = start(binary, client_dir, fixture, columns=columns, rows=rows)
        try:
            open_new(terminal)
            fill(terminal, "Guests", '"Typed, Person" <typed@example.test>')
            open_guest_contacts(terminal)
            terminal.until(lambda: "Loading this account" not in terminal.text())
            # The successful-but-partial head says so on its own row.
            terminal.until(lambda: "%d omitted" % omitted in terminal.text())
            # Typing filters loaded data only: local matches, no search yet.
            terminal.send(b"Morgan")
            terminal.until(lambda: "Loaded matches · Ctrl+F Search Contacts" in terminal.text()
                           and "morgan.beyond@example.test" in terminal.text())
            require("Contacts search" not in terminal.text(), "typing applied a provider search")
            provider_counts(binary, client_dir, fixture, 0)
            # Ctrl+F dispatches and applies the explicit search beside them.
            terminal.send(b"\x06")
            terminal.until(lambda: "Contacts search + recent mail" in terminal.text() and "Searching" not in terminal.text())
            require("morgan.beyond@example.test" in terminal.text() and "omitted" in terminal.text(),
                    "search hid the selected match or the partial contacts warning")
            capture(terminal, captures, "compose-guests-search-" + str(columns))
            terminal.send(b"\r")
            terminal.until(lambda: "Add a guest from Contacts" not in terminal.text())
            require("morgan.beyond@example.test" in row_text(terminal, "Guests:"), "searched contact did not reach Guests")
            fill(terminal, "Title", "Guest search " + str(columns))
            review(terminal, "Guest search " + str(columns), binary, client_dir, fixture, 0)
            entries = []
            for path in (client_dir / "cache").rglob("calendar-state.json"):
                document = json.loads(path.read_text())
                if document.get("account") == ACCOUNTS[0]:
                    entries += [entry["review"] for entry in document["entries"] if entry.get("review")]
            raw = json.dumps(next(item for item in entries if item["intent"]["kind"] == "insert_event"))
            require("morgan.beyond@example.test" in raw and "typed@example.test" in raw and "Typed, Person" not in raw,
                    "review did not keep bare typed and searched guest emails")
            terminal.send(b"\x1b")
            terminal.until(lambda: "Review new event" not in terminal.text())
            terminal.send(b"\x1b")
            terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
            terminal.send(b"\x04")
            wait_calendar(terminal)
            provider_counts(binary, client_dir, fixture, 0)
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
    return {"writes": 0, "widths": [132, 48], "explicitSearchWithLocalMatches": True, "partialWarning": True,
            "namedPaste": True, "headBoundary": "TUI unit + root production dispatch test, not this fixture"}


def guest_grammar(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional pasted guest list"
    first, _ = new_dates(5)
    try:
        open_new(terminal)
        ordinary_fields(terminal, title, first)
        duplicate, invalid = "appears more than once", "Check guests"

        def refused(raw, message, previous):
            # Alternate messages so every refusal is newly observed.
            fill(terminal, "Guests", raw)
            terminal.send(b"\x13")
            terminal.until(lambda: message in terminal.text() and previous not in terminal.text())
            require("Review new event" not in terminal.text(), "a refused guest list reached Review")

        # Ordinary Mail paste: a duplicate behind display names is refused.
        refused('Jane <jane@example.test>, "Doe, Jane" <JANE@example.test>', duplicate, invalid)
        # The field is one line (pasted line breaks become spaces); the shared
        # grammar still refuses the injected header and a ';'-joined list.
        refused('Jane <jane@example.test>\r\nBcc: hidden@example.test;', invalid, duplicate)
        refused('Jane <jane@example.test>, JANE@example.test', duplicate, invalid)
        refused('jane@example.test; alex@example.test', invalid, duplicate)
        refused('Alex <alex@example.test>, ALEX@example.test', duplicate, invalid)
        refused('Jane <jane@example.test>, not an email', invalid, duplicate)
        provider_counts(binary, client_dir, fixture, 0)
        fill(terminal, "Guests", '"Doe, Jane" <jane@example.test>, Alex Example <alex@example.test>')
        review(terminal, title, binary, client_dir, fixture, 0)
        require("email 2 guests" in terminal.text(), "named paste did not count two guests")
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require(sorted(entry["email"] for entry in saved["attendees"]) == ["alex@example.test", "jane@example.test"],
                "provider did not receive exactly the bare guest emails")
        leave_saved(terminal)
        terminal.finish()
        return {"writes": 1, "duplicateRefused": True, "invalidRefused": True, "injectionRefused": True,
                "semicolonRefused": True, "bareEmails": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def field_value(terminal, label):
    row = row_text(terminal, label + ":")
    require(row, "form field is not visible: " + label)
    return row.split(label + ":", 1)[1].replace("▏", " ").split()[0]


def shifted(day, days):
    return (datetime.fromisoformat(day) + timedelta(days=days)).date().isoformat()


def day_gap(start_day, end_day):
    return (datetime.fromisoformat(end_day) - datetime.fromisoformat(start_day)).days


def discard_new(terminal):
    terminal.send(b"\x1b")
    terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
    terminal.send(b"\x04")
    wait_calendar(terminal)
    terminal.send(b"n")
    terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))


def end_follows(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture, columns=132, rows=38)
    title = "Fictional moved start"
    first, _ = new_dates(9)
    try:
        open_new(terminal)
        fill(terminal, "Title", title)
        fill(terminal, "Time zone", "UTC")
        # Only Start fields are edited; End is observed, never filled. The
        # default can cross midnight, so compare with its shown day gap.
        gap = day_gap(field_value(terminal, "Start date"), field_value(terminal, "End date"))
        fill(terminal, "Start date", first)
        require(field_value(terminal, "End date") == shifted(first, gap), "untouched end date stayed behind the new start date")
        fill(terminal, "Start time", "23:30")
        overnight = shifted(first, 1)
        require(field_value(terminal, "End date") == overnight and field_value(terminal, "End time") == "00:30",
                "untouched one-hour end did not follow a late start")
        # Ctrl+S immediately after the start edit reviews the followed end.
        review(terminal, title, binary, client_dir, fixture, 0)
        terminal.send(b"\x1b")
        terminal.until(lambda: "[Esc Cancel]" in terminal.text() and "Review new event" not in terminal.text())
        # Back from review, End still follows; the repeated review saves it.
        fill(terminal, "Start time", "22:00")
        require(field_value(terminal, "End date") == first and field_value(terminal, "End time") == "23:00",
                "end stopped following after returning from review")
        review(terminal, title, binary, client_dir, fixture, 0, name="end-follows-repeated")
        confirm(terminal, 1, binary, client_dir, fixture)
        saved = find_saved(binary, client_dir, fixture, title)
        require(saved["start"]["dateTime"].startswith(first + "T22:00:00") and saved["end"]["dateTime"].startswith(first + "T23:00:00"),
                "start-only edits did not save the moved one-hour interval")
        leave_saved(terminal)
        # An end typed back to its own value is still explicit and stays put.
        terminal.send(b"n")
        terminal.until(lambda: "New event" in terminal.text() and focused_field(terminal, "Title"))
        fill(terminal, "Title", title + " explicit")
        kept_day, kept_time = field_value(terminal, "End date"), field_value(terminal, "End time")
        fill(terminal, "End time", kept_time)
        fill(terminal, "Start date", first)
        require(field_value(terminal, "End date") == kept_day and field_value(terminal, "End time") == kept_time,
                "an explicitly re-entered end moved with the start")
        # All-day keeps its shown day count while Start moves.
        discard_new(terminal)
        gap = day_gap(field_value(terminal, "Start date"), field_value(terminal, "End date"))
        toggle(terminal, "[ ] All day", "[x] All day")
        fill(terminal, "Start date", first)
        require(field_value(terminal, "Last date (included)") == shifted(first, gap), "all-day last date did not follow the start")
        capture(terminal, captures, "compose-end-follows-all-day")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Discard your unsaved event?" in terminal.text())
        terminal.send(b"\x04")
        wait_calendar(terminal)
        provider_counts(binary, client_dir, fixture, 1)
        terminal.finish()
        return {"writes": 1, "startOnly": True, "immediateReview": True, "repeatedReview": True,
                "explicitEndKept": True, "allDayFollows": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    global NO_COLOR
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("--case", choices=("timed", "all-day", "link-guests", "cancel-narrow", "edit-latest", "fold-choice",
                                          "google-meet", "html-notes-readonly", "edit-dst-review-twice", "removed-guests", "recovery-retry", "recovery-restart", "recovery-archive", "cancel-fresh", "guest-contacts", "guest-recent", "guest-fallback",
                                          "guest-search", "guest-grammar", "end-follows"))
    args = parser.parse_args()
    NO_COLOR = args.no_color
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "noColor": NO_COLOR, "cases": []}
    tasks = (("timed", timed), ("all-day", all_day), ("link-guests", link_guests),
             ("cancel-narrow", cancel_narrow), ("edit-latest", edit_latest), ("fold-choice", fold_choice),
             ("google-meet", google_meet), ("html-notes-readonly", html_notes_readonly),
             ("edit-dst-review-twice", edit_dst_review_twice), ("removed-guests", removed_guests),
             ("recovery-retry", recovery_retry), ("recovery-restart", recovery_restart),
             ("recovery-archive", recovery_archive), ("cancel-fresh", cancel_fresh), ("guest-contacts", guest_contacts), ("guest-recent", guest_recent), ("guest-fallback", guest_fallback),
             ("guest-search", guest_search), ("guest-grammar", guest_grammar), ("end-follows", end_follows))
    try:
        for name, task in tasks:
            if args.case and args.case != name:
                continue
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-compose-" + name + "-") as temporary:
                    result = task(binary, Path(temporary), args.capture_dir)
                receipt["cases"].append({"name": name, "status": "passed", **result})
                print("PASS Calendar composer:", name, flush=True)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
