#!/usr/bin/env python3
"""Native Week disclosure using isolated synthetic providers and owned PTYs.

Calendar snapshots, exact hour badges, visible-row unions, adaptive title rows,
read-only selection and destination account identity are verified independently
of screenshots. No live Calendar, contacts, desktop or OAuth writes occur.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
import traceback

from build_info import read_build_info
from terminal_calendar import Invitations, provider_state
from terminal_calendar_tui import capture, hour_gutter, start, wait_calendar
from terminal_integration import ACCOUNTS, Client, ROOT, require
from terminal_mouse import click, point


def seed(binary, directory):
    fixture = Invitations(directory)
    owned = directory / "client"
    data = json.loads((ROOT / "tests/fixtures/terminal/calendar/week-overlaps.json").read_text())
    mapping = dict(zip(("personal@example.com", "work@example.com", "optional@example.com"), ACCOUNTS))
    states = {}
    with Client(binary, owned, extra=fixture.options()) as client:
        for account in ACCOUNTS:
            client.request("calendar.list", account)
            states[account] = provider_state(client, account)
            states[account]["events"] = []
    for item in data["events"]:
        account = mapping[item["target"]["account"]]
        calendar = item["target"]["calendar_id"]
        calendar = mapping.get(calendar, calendar)
        def stamp(value):
            if value["kind"] == "date":
                return {"date": datetime.fromtimestamp(value["value"] * 86400, timezone.utc).date().isoformat()}
            return {"dateTime": datetime.fromtimestamp(value["value"] / 1000, timezone.utc).isoformat().replace("+00:00", "Z")}
        event = {"id": item["id"], "iCalUID": item["id"] + "@example.test", "etag": '"seed-1"',
                 "status": "confirmed", "organizer": {"email": account, "self": True},
                 "summary": item["summary"], "start": stamp(item["start"]), "end": stamp(item["end"]),
                 "htmlLink": "https://calendar.google.com/calendar/event?eid=" + item["id"],
                 "attendees": [{"email": account, "self": True, "responseStatus": "accepted"}]}
        if item.get("join_url"):
            event["hangoutLink"] = item["join_url"]
        states[account]["events"].append({"calendar_id": calendar, "value": event})
    template = copy.deepcopy(states[ACCOUNTS[0]]["events"][0])
    for ident, title, minute in (("notes", "Notes check", 10), ("vendor", "Vendor call", 15),
                                  ("quick", "Quick review", 20), ("special-visit", "Shared visit copy", 30)):
        event = copy.deepcopy(template)
        event["calendar_id"] = "fixture-shared-team" if ident == "special-visit" else ACCOUNTS[0]
        value = event["value"]
        value.update(id=ident, iCalUID=ident + "-extra@example.test", summary=title)
        value["start"] = {"dateTime": data["day"] + f"T10:{minute:02}:00Z"}
        value["end"] = {"dateTime": data["day"] + f"T10:{minute + 10:02}:00Z"}
        value["htmlLink"] = "https://calendar.google.com/calendar/event?eid=" + ident
        if ident == "vendor":
            value["attendees"][0]["responseStatus"] = "declined"
        states[ACCOUNTS[0]]["events"].append(event)
    for path in (owned / "cache").rglob("calendar-provider-fixture.json"):
        account = json.loads(path.read_text())["account"]
        path.write_text(json.dumps(states[account]) + "\n")
    preferences = owned / "config" / "omagma" / "ui.json"
    preferences.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    preferences.write_text(json.dumps({"calendar": {"preferred": {"account": ACCOUNTS[1], "calendarId": ACCOUNTS[1]}}}) + "\n")
    preferences.chmod(0o600)
    return fixture, owned, data["day"]


def open_week(terminal, day):
    terminal.send(b"C")
    wait_calendar(terminal)
    terminal.send(b"ga")
    terminal.until(lambda: "Show calendars · all accounts" in terminal.text() and
                   "[Enter Apply]" in terminal.text() and "[Loading calendars" not in terminal.text() and
                   "9 checked" in terminal.text())
    terminal.send(b"\r")
    wait_calendar(terminal)
    terminal.send(b"\x07\x05" + b"\x7f" * 12 + day.encode() + b"\r")
    wait_calendar(terminal)
    terminal.send(b"3")
    wait_calendar(terminal, "Week")
    terminal.until(lambda: "Also here:" in terminal.text() or "Hidden here:" in terminal.text() or "Home" in terminal.text())


def selected(terminal, literal):
    return literal in terminal.screen.lines()[-4]


def select_week_event(terminal, title):
    terminal.send(b"k" * 40)
    terminal.gap(.1)
    for _ in range(32):
        if selected(terminal, title):
            return
        before = terminal.screen.completed_frames
        terminal.send(b"j")
        terminal.until(lambda: terminal.screen.completed_frames > before)
    raise AssertionError("event was not selectable in Week: " + title)


def chooser(binary, directory, captures):
    fixture, owned, day = seed(binary, directory)
    terminal = start(binary, owned, fixture, columns=140, rows=38, no_color=True)
    try:
        open_week(terminal, day)
        # Fresh/date-reloaded passive selection cannot suppress a new start
        # from the saved exact Work Priority source.
        row10 = next(index for index, line in enumerate(terminal.screen.lines()) if line.startswith("10:00"))
        require("10:30" in terminal.screen.lines()[row10][6:24] and "Spe" in terminal.screen.lines()[row10][6:24],
                "passive initial routine hid the preferred new Work start")
        capture(terminal, captures, "week-passive-priority")
        select_week_event(terminal, "Weekly studio block")
        # Choosing the routine from11:00 pins only that bucket. The10:30 Work
        # start must stay visible at10:00 while the routine is revealed at11.
        row11 = next(index for index, line in enumerate(terminal.screen.lines()) if line.startswith("11:00"))
        col11 = terminal.screen.lines()[row11].find("+", 6, 24)
        require(col11 >= 0, "11:00 group is missing its count badge")
        click(terminal, col11, row11)
        terminal.until(lambda: "2 events" in terminal.text() and "11:00–12:00" in terminal.text())
        click(terminal, *point(terminal, "[Enter Select]"))
        terminal.until(lambda: "Calendar · Week" in terminal.text() and selected(terminal, "Weekly studio block"))
        row10 = next(index for index, line in enumerate(terminal.screen.lines()) if line.startswith("10:00"))
        row11 = next(index for index, line in enumerate(terminal.screen.lines()) if line.startswith("11:00"))
        require("Spe" in terminal.screen.lines()[row10][6:24] and "Weekly" in terminal.screen.lines()[row11][6:24],
                "single-bucket reveal covered another hour's preferred new start")
        capture(terminal, captures, "week-explicit-single-hour")
        require(("Also here:" in terminal.text() or "Hidden here:" in terminal.text()) and "[Space Show all 8]" in terminal.text(),
                "selected event's union count/secondary preview is not discoverable")
        capture(terminal, captures, "week-disclosure-no-color")
        old_selection = terminal.screen.lines()[-4]
        # An exact-hour badge omits Next-hour call; the keyboard union includes it.
        row = next(index for index, line in enumerate(terminal.screen.lines()) if line.startswith("10:00"))
        badge_col = terminal.screen.lines()[row].find("+", 6, 24)
        require(badge_col >= 0, "crowded first day has no prominent count badge")
        click(terminal, badge_col, row)
        terminal.until(lambda: "Calendar · Events here" in terminal.text() and "7 events" in terminal.text())
        require("10:00–11:00" in terminal.text() and "Time zone: UTC" in terminal.text(), "badge chooser lost exact hour/zone")
        require("Next-hour call" not in terminal.text(), "exact-hour chooser silently included an event in another hour")
        capture(terminal, captures, "week-exact-hour-chooser")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Calendar · Week" in terminal.text())
        require(terminal.screen.lines()[-4] == old_selection, "Escape changed the selected event/context")
        # Reach Show all with Tab and activate its actual button. Shift+Tab must
        # invert the cycle, and a successful choice returns focus to the event.
        button = point(terminal, "[Space Show all 8]")
        for _ in range(24):
            x, y = button
            if terminal.screen.reversed[y][x]:
                break
            before = terminal.screen.completed_frames
            terminal.send(b"\t")
            terminal.until(lambda: terminal.screen.completed_frames > before)
        else:
            raise AssertionError("Show all is absent from Tab order")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Events here" in terminal.text() and "8 events" in terminal.text())
        require("Shared visible rows" in terminal.text(), "keyboard chooser does not explain its selected-event scope")
        # Routine09:00, early10:05, notes10:10, vendor10:15, quick10:20,
        # personal shared-copy10:30, Work special-visit10:30, next-hour11:00.
        for _ in range(6):
            before = terminal.screen.completed_frames
            terminal.send(b"j")
            terminal.until(lambda: terminal.screen.completed_frames > before)
        terminal.until(lambda: "Special visit" in terminal.text() and ACCOUNTS[1] in terminal.text())
        capture(terminal, captures, "week-cross-account-choice")
        terminal.resize(48, 12)
        terminal.until(lambda: "enlarge terminal" in terminal.text())
        terminal.send(b"\r")
        terminal.gap(.1)
        require("Calendar · Events here" in terminal.text(), "small chooser selected an unseen event")
        capture(terminal, captures, "week-chooser-too-small")
        terminal.resize(48, 24)
        terminal.until(lambda: "Special visit" in terminal.text() and "Starts: 2026-10-19 10:30 UTC" in terminal.text()
                       and "Ends:   2026-10-19 11:00 UTC" in terminal.text())
        capture(terminal, captures, "week-chooser-48")
        click(terminal, *point(terminal, "[Enter Select]"))
        terminal.until(lambda: "Calendar · Week" in terminal.text() and selected(terminal, "Special visit"))
        # Selecting is inert: only the next normal Enter opens the exact Work
        # event; the identically named-ID Personal source must not be substituted.
        require("Calendar · Event |" not in terminal.text(), "Select opened details instead of revealing the event")
        # At48cols Week uses its agenda fallback; the exact chosen title is in
        # the actual content as well as the selected-event action rail.
        require(sum("Special visit" in line for line in terminal.screen.lines()) >= 2,
                "Select updated only the footer without revealing the event")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Event |" in terminal.text() and "Special visit" in terminal.text())
        require(ACCOUNTS[1] in terminal.text() and "Shared visit copy" not in terminal.text(), "ordinary Enter opened another account's same event ID")
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Week" in terminal.text())
        terminal.resize(140, 38)
        terminal.until(lambda: "Sun" in terminal.text())
        # All-day disclosure is separate from timed rows and uses civil ends.
        badge = point(terminal, "+1 all-day")
        click(terminal, *badge)
        terminal.until(lambda: "3 events" in terminal.text() and "All day" in terminal.text())
        require("Weekly studio block" not in terminal.text(), "all-day chooser included a timed event")
        capture(terminal, captures, "week-all-day-chooser")
        terminal.send(b"jj")  # Chronological Travel,Home,then hidden Work holiday.
        terminal.until(lambda: "Local holiday" in terminal.text())
        click(terminal, *point(terminal, "[Enter Select]"))
        terminal.until(lambda: "Calendar · Week" in terminal.text() and selected(terminal, "Local holiday"))
        day_header = next(index for index, line in enumerate(terminal.screen.lines()) if "Mon 10-19" in line)
        require(any("Local holiday" in line[6:24] for line in terminal.screen.lines()[day_header + 1:day_header + 3]),
                "hidden all-day choice was not promoted into its actual day band")
        terminal.send(b"\r")
        terminal.until(lambda: "Calendar · Event |" in terminal.text() and "Local holiday" in terminal.text())
        require(ACCOUNTS[1] in terminal.text() and "Holidays" in terminal.text(), "hidden all-day Select opened another source")
        terminal.send(b"q")
        terminal.until(lambda: "Calendar · Week" in terminal.text())
        select_week_event(terminal, "Overnight handover")
        terminal.send(b" ")
        terminal.until(lambda: "Calendar · Events here" in terminal.text() and "1 event ·" in terminal.text())
        terminal.resize(48, 24)
        terminal.until(lambda: "Starts: 2026-10-19 23:30 UTC" in terminal.text() and
                       "Ends:   2026-10-20 00:30 UTC" in terminal.text())
        require(all(any(cell.strip() for cell in row) or not any(reverse)
                    for row, reverse in zip(terminal.screen.cells, terminal.screen.reversed)),
                "erased blank rows retained stale reverse-video style after resize")
        capture(terminal, captures, "week-cross-midnight-48")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Calendar · Week" in terminal.text())
        terminal.finish()
        with Client(binary, owned, extra=fixture.options()) as client:
            for account in ACCOUNTS:
                require(provider_state(client, account)["writes"] == 0, "Week disclosure wrote Calendar data")
            require(client.request("cache.stats")["fixtureSends"] == 0, "Week disclosure sent mail")
        return {"exactHour": 7, "keyboardUnion": 8, "allDay": 3, "widths": [140, 48], "unseenSelectionBlocked": True,
                "crossAccountSameId": True, "passivePriority": True, "singleBucketReveal": True,
                "hiddenAllDayReveal": True, "crossMidnightDates": True, "tabSelectThenOrdinaryEnter": True, "writes": 0}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def expansion(binary, directory, captures):
    fixture, owned, day = seed(binary, directory)
    terminal = start(binary, owned, fixture, columns=140, rows=38)
    try:
        open_week(terminal, day)
        capture(terminal, captures, "week-passive-priority-color")
        select_week_event(terminal, "Weekly studio block")
        capture(terminal, captures, "week-crowded-140x38")
        expected_hours = [f"{hour:02}:00" for hour in range(24)]
        before_frame = terminal.screen.completed_frames
        terminal.resize(140, 60)
        terminal.until(lambda: terminal.screen.completed_frames > before_frame and "Notes" in terminal.text())
        require(hour_gutter(terminal) == expected_hours, "expanded grid hid an hour gutter label")
        lines = terminal.screen.lines()
        row10 = next(index for index, line in enumerate(lines) if line.startswith("10:00"))
        row11 = next(index for index, line in enumerate(lines) if line.startswith("11:00"))
        actual = [line[6:24] for line in lines[row10:row11]]
        require(len(actual) == 4 and sum(bool(part.strip()) for part in actual) == 4,
                "spare rows do not reveal four actual meeting titles")
        require(any("+3" in part for part in actual), "badge count did not exclude all four distinct visible titles")
        require("overlapping" not in terminal.text(), "Week falsely labels same-hour appointments as conflicts")
        capture(terminal, captures, "week-expanded-140x60")
        # Layout geometry is independent of selection.
        before = hour_gutter(terminal)
        terminal.send(b"jj")
        terminal.gap(.1)
        after = hour_gutter(terminal)
        require(before == after, "selection changed the allocated hour rows")
        before_frame = terminal.screen.completed_frames
        terminal.resize(104, 44)
        terminal.until(lambda: terminal.screen.completed_frames > before_frame and "Sun" in terminal.text())
        require(hour_gutter(terminal) == expected_hours, "populated seven-day resize hid an hour gutter label")
        capture(terminal, captures, "week-crowded-104")
        terminal.finish()
        with Client(binary, owned, extra=fixture.options()) as client:
            require(all(provider_state(client, account)["writes"] == 0 for account in ACCOUNTS), "adaptive Week mutated a provider")
        return {"adaptiveTitlesPerHour": 4, "visibleHours": 24, "selectionStableLayout": True, "writes": 0}
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
    parser.add_argument("--case", choices=("chooser", "expansion"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    try:
        for name, task in (("chooser", chooser), ("expansion", expansion)):
            if args.case and args.case != name:
                continue
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-week-") as tmp:
                    result = task(binary, Path(tmp), args.capture_dir)
                receipt["cases"].append({"name": name, "status": "passed", **result})
                print("PASS Calendar Week:", name, flush=True)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
