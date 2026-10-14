#!/usr/bin/env python3
"""Native Calendar workflows through owned PTYs and synthetic durable providers.

No desktop windows, real accounts, OAuth, or external Calendar writes. Run under
this repository's cooperative measurement reservation. Optional captures contain
only fictional provider data, for independent visual review.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path
import sys
import tempfile
import traceback

from build_info import read_build_info
from terminal_calendar import Invitations, provider_state
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal, click, point
from terminal_reader_copy import clips
from terminal_reader_editor import ReaderScreen


def start(binary, directory, fixture, scenario=None, columns=140, rows=38):
    extra = fixture.options() + ("--account", ACCOUNTS[0])
    if scenario:
        extra += ("--fixture-scenario", scenario)
    terminal = MouseTerminal(binary, directory, extra=extra, screen_type=ReaderScreen,
                             columns=columns, rows=rows, environment={"TZ": "UTC", "NO_COLOR": None, "COLORTERM": "truecolor"})
    terminal.until(lambda: "Planning version" in terminal.text())
    terminal.gap(.2)
    return terminal


def capture(terminal, destination, name):
    if destination:
        terminal.gap(.1)
        destination.mkdir(parents=True, exist_ok=True)
        (destination / (name + ".json")).write_text(json.dumps(screen_capture(terminal)) + "\n")


def wait_calendar(terminal, view="Agenda"):
    terminal.until(lambda: "Calendar · " + view in terminal.text() and
                   ("Up to date" in terminal.text() or "Saved calendar" in terminal.text()))
    terminal.gap(.05)


def search_mail(terminal, version):
    terminal.send(b"/subject:\"Planning version " + str(version).encode() + b"\"\r")
    terminal.until(lambda: f"Planning version {version}" in terminal.text())
    terminal.gap(.4)


def provider_counts(binary, directory, fixture, writes):
    with Client(binary, directory, extra=fixture.options()) as client:
        require(provider_state(client)["writes"] == writes, "calendar provider mutation count changed unexpectedly")
        require(client.request("cache.stats")["fixtureSends"] == 0, "Calendar action unexpectedly sent RSVP mail")


def browsing(binary, directory, captures):
    fixture = Invitations(directory)
    terminal = start(binary, directory / "client", fixture)
    try:
        # The actual navigation mouse target, not only the letter shortcut.
        terminal.until(lambda: terminal.screen.locate("Calendar · C") is not None)
        click(terminal, *point(terminal, "Calendar · C"))
        wait_calendar(terminal)
        require("Project planning" in terminal.text() and "UTC" in terminal.text(), "agenda omitted event or display timezone")
        require("" in terminal.text(), "joinable agenda event omitted camera")
        capture(terminal, captures, "calendar-agenda-wide")
        terminal.send(b"2")
        wait_calendar(terminal, "Day")
        require("Project planning" in terminal.text(), "Day lost today's timed event")
        capture(terminal, captures, "calendar-day")
        terminal.send(b"3")
        wait_calendar(terminal, "Week")
        require("Mon" in terminal.text() and "Sun" in terminal.text(), "full Week did not draw seven date columns")
        capture(terminal, captures, "calendar-week-wide")
        terminal.resize(104, 30)
        terminal.until(lambda: "Sun" in terminal.text())
        capture(terminal, captures, "calendar-week-minimum-seven-days")
        terminal.resize(120, 38)
        terminal.until(lambda: "Sun" in terminal.text())
        capture(terminal, captures, "calendar-week-medium")
        terminal.resize(82, 28)
        terminal.until(lambda: "Week needs 104 cols" in terminal.text())
        capture(terminal, captures, "calendar-week-three-days")
        terminal.resize(48, 22)
        terminal.until(lambda: "more event" in terminal.text())
        require("Week needs 104 cols" in terminal.text(), "narrow Week omitted fallback explanation")
        require("more event" in terminal.text(), "narrow agenda hides later events without an indication")
        lines = terminal.screen.lines()
        marker = next(i for i, row in enumerate(lines) if "more event" in row)
        require(not any(name + " ·" in lines[marker - 1] for name in ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")), "agenda orphaned a day heading without its first event")
        capture(terminal, captures, "calendar-week-narrow")
        terminal.resize(140, 38)
        terminal.send(b"1")
        wait_calendar(terminal)
        terminal.send(b"/planning\r")
        terminal.until(lambda: "Filter: planning" in terminal.text() and "Loaded events /" not in terminal.text())
        require("Daily review" not in terminal.text(), "loaded search failed to filter unrelated events")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Event" in terminal.text() and "Event is already in this calendar" in terminal.text())
        require("09:00–10:00 UTC" in terminal.text() and "1h" in terminal.text(), "event card omitted exact interval, duration or zone")
        require("Event:" not in terminal.text() and "To RSVP" not in terminal.text(), "event card retained flat field dump")
        require("[o Join]" in terminal.text() and "" in terminal.text(), "event card omitted camera or Join")
        capture(terminal, captures, "calendar-event-detail")
        terminal.send(b"?")
        terminal.until(lambda: "Calendar · keyboard & mouse" in terminal.text())
        terminal.send(b"/cHrOmE\r")
        # The action column wraps independently inside the bordered help panel.
        terminal.until(lambda: "1/1 matches" in terminal.text() and
                       "Chrome profile" in " ".join(terminal.text().replace("│", " ").split()))
        capture(terminal, captures, "calendar-help-search-from-card")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Search help" in terminal.text() and "1/1 matches" not in terminal.text())
        terminal.send(b"\t\r")
        terminal.until(lambda: "Calendar · Event" in terminal.text() and "[o Join]" in terminal.text()
                       and "keyboard & mouse" not in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "or Tab to Join, then Enter" in terminal.text())
        terminal.send(b"o")
        terminal.until(lambda: "Join target validated" in terminal.text())
        require("Profile 3" in terminal.text(), "Join feedback omitted the configured Chrome profile")
        capture(terminal, captures, "calendar-event-join-feedback")
        for columns, rows in ((82, 28), (48, 22)):
            terminal.resize(columns, rows)
            terminal.until(lambda: "[q Back]" in terminal.text() and "Project planning" in terminal.text())
            capture(terminal, captures, f"calendar-event-detail-{columns}")
        terminal.resize(140, 38)
        terminal.send(b"q/\x1b")
        terminal.gap(.1)
        terminal.send(b"g")
        terminal.until(lambda: "Choose calendar" in terminal.text() and "Holidays" in terminal.text())
        capture(terminal, captures, "calendar-picker")
        terminal.send(b"jj\r")
        wait_calendar(terminal)
        require("Company day" in terminal.text() and "all-day" in terminal.text(), "all-day event lost civil-date presentation")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Event" in terminal.text() and "Company day" in terminal.text() and "all day" in terminal.text())
        require("all day" in terminal.text() and "In Holidays" in terminal.text(), "all-day details lost civil dates or calendar status")
        require("To RSVP" not in terminal.text() and "Response:" not in terminal.text() and "[o Join]" not in terminal.text(), "plain all-day entry shows irrelevant invitation actions")
        capture(terminal, captures, "calendar-all-day-detail")
        terminal.send(b"q3")
        wait_calendar(terminal, "Week")
        require("Company day" in terminal.text(), "all-day event absent from separate Week band")
        capture(terminal, captures, "calendar-week-all-day")
        terminal.send(b"\x10")
        terminal.until(lambda: "Previous period" in terminal.text() and "Search loaded events" in terminal.text())
        terminal.send(b"q?")
        terminal.until(lambda: "Calendar · keyboard & mouse" in terminal.text() and "Ctrl+P" in terminal.text())
        capture(terminal, captures, "calendar-help")
        terminal.resize(48, 24)
        terminal.send(b"/profile\r")
        terminal.until(lambda: "1/1 matches" in terminal.text() and "[q Back]" in terminal.text() and
                       "Chrome profile" in " ".join(terminal.text().replace("│", " ").split()))
        capture(terminal, captures, "calendar-help-search-48")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Search help" in terminal.text() and "1/1 matches" not in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Week" in terminal.text() and "keyboard & mouse" not in terminal.text())
        terminal.resize(140, 38)
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Week" not in terminal.text())
        # Shortcut opens Calendar again and Tab/Enter activates Mail return.
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.send(b"\x07\x05" + b"\x7f" * 10 + b"2026-02-30\r")
        terminal.until(lambda: "Choose a valid date" in terminal.text())
        require("Date YYYY-MM-DD" in terminal.text(), "invalid date closed date entry")
        target_day = (datetime.now(timezone.utc) + timedelta(days=15)).date().isoformat()
        terminal.send(b"\x05" + b"\x7f" * 10 + target_day.encode() + b"\r")
        wait_calendar(terminal)
        require(target_day in terminal.text(), "date jump did not navigate to requested civil date")
        capture(terminal, captures, "calendar-date-jump")
        terminal.send(b"t")
        wait_calendar(terminal)
        terminal.send(b"\t\r")
        terminal.until(lambda: "Calendar · Agenda" not in terminal.text())
        terminal.finish()
        provider_counts(binary, directory / "client", fixture, 0)
        return {"views": ["agenda", "day", "week"], "widths": [140, 120, 104, 82, 48], "mouse": True, "writes": 0}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def plan(terminal, version, action):
    search_mail(terminal, version)
    terminal.send(b"A")
    terminal.until(lambda: "Choose calendar" in terminal.text() and "Personal" in terminal.text())
    terminal.send(b"\r")
    terminal.until(lambda: "Action: " + {"import_missing": "Add to Calendar", "review_update": "Apply organizer's update", "review_cancel": "Apply organizer's cancellation"}.get(action, action) in terminal.text() and "[Enter Review]" in terminal.text())


def review_and_confirm(terminal, expected, captures=None, tag="calendar-import-review"):
    terminal.send(b"yyyy")
    terminal.gap(.2)
    require("[Enter Review]" in terminal.text() and "[y Confirm]" not in terminal.text(), "unadvertised y skipped the first review")
    click(terminal, *point(terminal, "[Enter Review]"))
    terminal.until(lambda: "Action: " + {"import_event": "Add to Calendar", "update_event": "Apply organizer's update", "cancel_event": "Apply organizer's cancellation"}.get(expected, expected) in terminal.text() and "[y Confirm]" in terminal.text())
    require(ACCOUNTS[0] in terminal.text() and "2026-10-25 09:00 UTC" in terminal.text()
            and "2026-10-25 10:00 UTC" in terminal.text(), "review lost account or exact event times")
    if expected == "cancel_event":
        require("This removes the event from Personal." in terminal.text(), "cancellation review does not explain removal")
    capture(terminal, captures, tag)
    # A second un-focused Enter must not turn review navigation into consent.
    terminal.send(b"\r")
    terminal.gap(.1)
    require("[y Confirm]" in terminal.text() and "Calendar action applied" not in terminal.text(), "unfocused Enter confirmed a write")
    # Explicit Tab/Enter reaches Confirm: first control Back, second Confirm.
    terminal.send(b"\t\t\r")


def lifecycle(binary, directory, captures, lost=False):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    scenario = "calendar-lost-response" if lost else None
    terminal = start(binary, client_dir, fixture, scenario=scenario)
    try:
        for index, (decision, action) in enumerate((("import_missing", "import_event"),
                                                  ("review_update", "update_event"),
                                                  ("review_cancel", "cancel_event"))):
            version = index + 4
            plan(terminal, version, decision)
            provider_counts(binary, client_dir, fixture, index)
            review_and_confirm(terminal, action, captures, "calendar-" + action + ("-lost" if lost else ""))
            if lost:
                terminal.until(lambda: "Outcome unknown" in terminal.text() and "[r Check Calendar]" in terminal.text())
                require("Action: " + {"import_event": "Add to Calendar", "update_event": "Apply organizer's update", "cancel_event": "Apply organizer's cancellation"}[action] in terminal.text(), "unknown outcome lost original action")
                capture(terminal, captures, "calendar-unknown")
                # Reopen the TUI at every unknown boundary. Durable saved review
                # recovery must select reconciliation rather than a new write.
                terminal.finish()
                terminal.close()
                terminal = start(binary, client_dir, fixture, scenario=scenario)
                search_mail(terminal, version)
                terminal.send(b"A")
                terminal.until(lambda: "Choose calendar" in terminal.text() and "Personal" in terminal.text())
                terminal.send(b"\r")
                terminal.until(lambda: "[r Check Calendar]" in terminal.text())
                terminal.send(b"r")
                terminal.until(lambda: "Calendar action reconciled" in terminal.text())
            else:
                terminal.until(lambda: "Calendar action applied" in terminal.text())
            terminal.until(lambda: not terminal.screen.frame_open
                           and "Calendar · Result" in terminal.text()
                           and "No RSVP email was sent." in terminal.text())
            capture(terminal, captures, "calendar-result-" + action + ("-lost" if lost else ""))
            require("[Enter Review]" not in terminal.text() and "[y Confirm]" not in terminal.text(), "completed action still offers review or submission")
            require("No RSVP email was sent." in terminal.text(), "calendar success failed to distinguish RSVP")
            if action == "cancel_event":
                require("Removed from Personal." in terminal.text(), "completed cancellation still describes a pending removal")
            provider_counts(binary, client_dir, fixture, index + 1)
            terminal.send(b"qq")
            terminal.until(lambda: "Calendar ·" not in terminal.screen.lines()[0])
            # Esc clears the prior server-search query before selecting next mail.
            terminal.send(b"\x1b")
            terminal.gap(.1)
        terminal.finish()
        return {"mutations": 3, "rsvpSends": 0, "restartReconcile": lost}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def readonly(binary, directory, captures):
    fixture = Invitations(directory)
    terminal = start(binary, directory / "client", fixture, scenario="calendar-readonly")
    try:
        plan(terminal, 4, "import_missing")
        click(terminal, *point(terminal, "[Enter Review]"))
        terminal.until(lambda: "Write access needed for Personal" in terminal.text())
        require("--capabilities" in terminal.text() and "calendar-write-owned" in terminal.text(), "write guide failed to add owned write scope")
        capture(terminal, captures, "calendar-permission-guide")
        terminal.send(b"\t\t\r")
        terminal.until(lambda: "Authorization command copied" in terminal.text())
        copied_command = clips(terminal)[-1]
        require("calendar-write-owned" in copied_command and "mail-send" in copied_command and "calendar-read" in copied_command,
                "copied permission command lost existing grants or omitted required write access")
        terminal.finish()
        provider_counts(binary, directory / "client", fixture, 0)
        return {"guide": True, "writes": 0, "copyCommand": True}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def narrow_confirmation(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    terminal = start(binary, client_dir, fixture)
    try:
        plan(terminal, 4, "import_missing")
        terminal.resize(48, 16)
        terminal.until(lambda: "[Enter Review]" in terminal.text())
        click(terminal, *point(terminal, "[Enter Review]"))
        terminal.until(lambda: "[y Confirm]" in terminal.text())
        terminal.send(b"y")
        terminal.until(lambda: "Read the complete calendar review" in terminal.text())
        provider_counts(binary, client_dir, fixture, 0)
        capture(terminal, captures, "calendar-review-narrow-guard")
        terminal.send(b"\x04" * 8)
        terminal.gap(.2)
        terminal.send(b"y")
        terminal.until(lambda: "Calendar action applied" in terminal.text())
        terminal.finish()
        provider_counts(binary, client_dir, fixture, 1)
        return {"width": 48, "rows": 16, "clippedConfirmationBlocked": True, "writesAfterReview": 1}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def grid_coverage(binary, directory, captures):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    with Client(binary, client_dir, extra=fixture.options()) as client:
        client.request("calendar.list")
        state = provider_state(client)
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    template = copy.deepcopy(state["events"][0])
    definitions = [("long", "Long planning 会議 🧭 with a long title", 9 * 60 + 30, 11 * 60 + 15),
                   ("overlap", "Overlap", 9 * 60 + 45, 10 * 60 + 45),
                   ("early", "Early start", 2 * 60, 3 * 60),
                   ("late", "Late call", 23 * 60, 24 * 60)]
    state["events"] = []
    for ident, title, begin, end in definitions:
        item = copy.deepcopy(template)
        item["calendar_id"] = ACCOUNTS[0]
        event = item["value"]
        event.update(id="fixture-grid-" + ident, iCalUID="grid-" + ident + "@example.test", summary=title)
        event["start"] = {"dateTime": (today + timedelta(minutes=begin)).isoformat().replace("+00:00", "Z")}
        event["end"] = {"dateTime": (today + timedelta(minutes=end)).isoformat().replace("+00:00", "Z")}
        state["events"].append(item)
    paths = [path for path in (client_dir / "cache").rglob("calendar-provider-fixture.json")
             if __import__("json").loads(path.read_text())["account"] == ACCOUNTS[0]]
    require(len(paths) == 1, "grid fixture account storage is ambiguous")
    paths[0].write_text(json.dumps(state) + "\n")
    terminal = start(binary, client_dir, fixture)
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        terminal.send(b"3")
        wait_calendar(terminal, "Week")
        # At38 rows the24 hours fit. No meeting can disappear off the grid.
        require("00:00" in terminal.text() and "23:00" in terminal.text(), "wide grid wastes room while hiding hours")
        require("09:30" in terminal.text() and "+1" in terminal.text(), "grid lost actual start minutes or overlap count")
        lines = terminal.screen.lines()
        row_10 = next(row for row in lines if row.startswith("10:00"))
        row_11 = next(row for row in lines if row.startswith("11:00"))
        require("│" in row_10[6:] and "+1" in row_10 and "Long" in row_11,
                "multi-hour meeting incorrectly appears free after start hour")
        capture(terminal, captures, "calendar-overlaps-wide")
        for columns in (104, 110):
            terminal.resize(columns, 38)
            terminal.until(lambda: "Sun" in terminal.text())
            camera_rows = [row for row in terminal.screen.lines() if row.startswith("09:00")]
            require(camera_rows and "" in camera_rows[0] and "Lo" in camera_rows[0] and "+1" in camera_rows[0], "narrow seven-day cell dropped camera, title or overlap count")
            capture(terminal, captures, f"calendar-camera-grid-{columns}")
        terminal.resize(82, 28)
        terminal.until(lambda: "Week needs 104 cols" in terminal.text())
        terminal.send(b"kkkk")
        terminal.gap(.15)
        require("↓1 later · j" in terminal.text(), "hidden later meeting has no accurate offscreen indication")
        capture(terminal, captures, "calendar-overlaps-compact")
        before = terminal.text()
        terminal.send(b"l")
        terminal.until(lambda: "Up to date" in terminal.text() and terminal.text() != before)
        expected = (today + timedelta(days=3)).date().isoformat()
        require(expected in terminal.text(), "compact three-day Next skipped four days")
        terminal.finish()
        provider_counts(binary, client_dir, fixture, 0)
        return {"minuteStarts": True, "durations": True, "overlapCounts": True, "hiddenHours": True, "compactStepDays": 3}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--case", choices=("browse", "lifecycle", "lost-response", "readonly", "narrow-confirm", "grid-coverage"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    cases = [("browse", browsing), ("lifecycle", lifecycle),
             ("lost-response", lambda b, d, c: lifecycle(b, d, c, True)), ("readonly", readonly), ("narrow-confirm", narrow_confirmation), ("grid-coverage", grid_coverage)]
    try:
        for name, task in cases:
            if args.case and args.case != name:
                continue
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-calendar-tui-") as tmp:
                    result = task(binary, Path(tmp), args.capture_dir)
                receipt["cases"].append({"name": name, "status": "passed", **result})
                print("PASS Calendar TUI:", name, flush=True)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
