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
from terminal_theme_picker import ThemeScreen


class CalendarScreen(ThemeScreen, ReaderScreen):
    """Preserve synchronized reader cells and actual SGR reverse selection."""


def start(binary, directory, fixture, scenario=None, columns=140, rows=38, no_color=False):
    extra = fixture.options() + ("--account", ACCOUNTS[0])
    if scenario:
        extra += ("--fixture-scenario", scenario)
    terminal = MouseTerminal(binary, directory, extra=extra, screen_type=CalendarScreen if no_color else ReaderScreen,
                             columns=columns, rows=rows, environment={"TZ": "UTC", "NO_COLOR": "1" if no_color else None, "COLORTERM": "truecolor"})
    terminal.until(lambda: "Planning version" in terminal.text())
    terminal.gap(.2)
    return terminal


def capture(terminal, destination, name):
    if destination:
        terminal.gap(.1)
        destination.mkdir(parents=True, exist_ok=True)
        value = screen_capture(terminal)
        if hasattr(terminal.screen, "reversed"):
            value["currentReverseCells"] = terminal.screen.reversed
        (destination / (name + ".json")).write_text(json.dumps(value) + "\n")


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


def combined_sources(binary, directory, captures):
    fixture = Invitations(directory)
    owned = directory / "client"
    terminal = start(binary, owned, fixture)
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        require("3 selected calendars" in terminal.text(), "provider-selected calendars were not combined by default")
        require("Company day" in terminal.text() and "Project planning" in terminal.text(), "combined view omitted read-only holidays or timed events")
        capture(terminal, captures, "calendar-combined-account")
        terminal.send(b"g")
        terminal.until(lambda: "Show calendars" in terminal.text() and "Holidays" in terminal.text())
        terminal.send(b"j \r")  # Uncheck Shared team, retaining Personal + Holidays.
        wait_calendar(terminal)
        require("2 selected calendars" in terminal.text(), "checkbox Apply did not choose the two requested sources")
        preferences = owned / "config" / "omagma" / "ui.json"
        saved = json.loads(preferences.read_text())
        override = next(source for source in saved["calendar"]["sources"] if source["calendarId"] == "fixture-shared-team")
        require(override["account"] == ACCOUNTS[0] and not override["visible"], "saved selection lost exact account/calendar identity")
        terminal.send(b"g ")
        terminal.gap(.1)
        terminal.send(b"\x1b")
        wait_calendar(terminal)
        require(json.loads(preferences.read_text())["calendar"] == saved["calendar"], "Esc changed persisted source choices")
        require("2 selected calendars" in terminal.text(), "Esc did not restore the previously applied source set")
        terminal.send(b"g")
        terminal.until(lambda: "Show calendars" in terminal.text())
        terminal.send(b"a")
        terminal.until(lambda: "Show calendars · all accounts" in terminal.text() and ACCOUNTS[1] in terminal.text())
        capture(terminal, captures, "calendar-combined-picker-all-accounts")
        terminal.send(b"\r")
        wait_calendar(terminal)
        require("All accounts" in terminal.text() and "8 selected calendars" in terminal.text(), "all-account source selection omitted enabled account calendars")
        require("A Personal" in terminal.text() and "C Holidays" in terminal.text() and "D Personal" in terminal.text(), "calendar legend lacks independent source identifiers")
        capture(terminal, captures, "calendar-combined-all-accounts")
        terminal.send(b"3")
        wait_calendar(terminal, "Week")
        capture(terminal, captures, "calendar-combined-week")
        terminal.send(b"q")
        terminal.finish()
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    terminal = start(binary, owned, fixture, no_color=True)
    try:
        terminal.send(b"C")
        wait_calendar(terminal)
        require("All accounts" in terminal.text() and "8 selected calendars" in terminal.text(), "source scope/visibility did not survive process restart")
        require("A Personal" in terminal.text() and "D Personal" in terminal.text(), "NO_COLOR source identities depend on color")
        require("Company day" in terminal.text(), "read-only all-day source disappeared after restart")
        capture(terminal, captures, "calendar-combined-no-color")
        terminal.send(b"b")
        terminal.until(lambda: "Google Calendar target validated" in terminal.text())
        terminal.send(b"q")
        terminal.finish()
        for account in ACCOUNTS:
            with Client(binary, owned, extra=fixture.options()) as client:
                require(provider_state(client, account)["writes"] == 0, "combined calendar browsing wrote provider data")
        return {"accounts": 3, "readOnlyHoliday": True, "persistentScope": True, "cancelRollback": True, "noColorIdentity": True, "browserOpen": True, "writes": 0}
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def picker_read_access(binary, directory, captures):
    fixture = Invitations(directory)
    for columns, rows in ((140, 38), (48, 24)):
        owned = directory / f"picker-access-{columns}"

        def choose_c(terminal):
            terminal.send(b"k" * 9 + b"jj")
            terminal.until(lambda: "C Imported own calendar" in terminal.text())

        def choose_g(terminal):
            terminal.send(b"k" * 9 + b"j" * 6)
            terminal.until(lambda: "[x] G Personal" in terminal.text())

        terminal = start(binary, owned, fixture, scenario="calendar-picker-owned-only", columns=columns, rows=rows)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            # Hold the next account catalogue before its store lock. Early
            # Enter and a click on visibly disabled Apply must keep discovery
            # alive; Cancel must restore the original view permanently.
            control = fixture.root / "calendar-priority-control.json"
            hold = fixture.root / "calendar-priority.hold"
            entered = fixture.root / "calendar-priority.entered"
            control.write_text(json.dumps({"account": ACCOUNTS[1], "kind": "calendar_list"}))
            hold.write_text("hold\n")
            terminal.send(b"ga")
            terminal.until(lambda: entered.exists() and "[Loading calendars…]" in terminal.text())
            click(terminal, *point(terminal, "[Loading calendars…]"))
            terminal.send(b"\r")
            terminal.until(lambda: "Loading account calendars · Apply" in terminal.text())
            require("Calendar · Calendars" in terminal.text() and "[Loading calendars…]" in terminal.text(), "early Apply changed the picker or stopped discovery")
            capture(terminal, captures, f"calendar-picker-loading-{columns}")
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            require("1 selected calendars" in terminal.text(), "Cancel changed the applied source scope")
            terminal.gap(.2)
            require("Calendar · Agenda" in terminal.text(), "canceled discovery reopened its picker")
            for path in (control, hold, entered):
                path.unlink(missing_ok=True)
            terminal.send(b"ga")
            terminal.until(lambda: "Show calendars · all accounts" in terminal.text() and "9 checked" in terminal.text() and "[Enter Apply]" in terminal.text())
            terminal.send(b"\r")
            wait_calendar(terminal)
            require("3 selected calendars" in terminal.text(), "unreadable calendars counted as displayed sources")
            terminal.send(b"g")
            choose_c(terminal)
            terminal.until(lambda: "[x] C Imported own calendar" in terminal.text() and "Not shown · no read access" in terminal.text())
            require("Showing 3 · 9 checked" in terminal.text(), "picker confused desired checks and displayed readable sources")
            capture(terminal, captures, f"calendar-picker-unreadable-checked-{columns}")
            terminal.send(b" ")
            terminal.until(lambda: "[ ] C Imported own calendar" in terminal.text() and "8 checked" in terminal.text())
            terminal.send(b" ")
            terminal.until(lambda: "[x] C Imported own calendar" in terminal.text() and "9 checked" in terminal.text() and "Selection restored" in terminal.text())
            require("Showing 3" in terminal.text(), "restoring the applied checkbox displayed an unreadable source")
            terminal.send(b" ")
            terminal.until(lambda: "[ ] C Imported own calendar" in terminal.text() and "8 checked" in terminal.text())
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            terminal.send(b"g")
            choose_c(terminal)
            terminal.until(lambda: "[x] C Imported own calendar" in terminal.text() and "9 checked" in terminal.text())
            click(terminal, *point(terminal, "C Imported own calendar"))
            terminal.until(lambda: "[ ] C Imported own calendar" in terminal.text() and "8 checked" in terminal.text())
            capture(terminal, captures, f"calendar-picker-unreadable-hidden-{columns}")
            terminal.send(b"\r")
            wait_calendar(terminal)
            preferences = owned / "config" / "omagma" / "ui.json"
            saved = json.loads(preferences.read_text())["calendar"]
            hidden = next(choice for choice in saved["sources"] if choice["account"] == ACCOUNTS[0] and choice["calendarId"] == ACCOUNTS[2])
            require(not hidden["visible"], "Apply did not persist the exact unreadable imported source")
            require(not any(choice["account"] == ACCOUNTS[2] and choice["calendarId"] == ACCOUNTS[2] and not choice["visible"] for choice in saved["sources"]), "hiding C also hid owning source G")
            terminal.send(b"g")
            choose_g(terminal)
            capture(terminal, captures, f"calendar-picker-own-source-g-{columns}")
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            terminal.send(b"q")
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
            for name in ("calendar-priority-control.json", "calendar-priority.hold", "calendar-priority.entered"):
                (fixture.root / name).unlink(missing_ok=True)

        for scenario, expected_count in (("calendar-picker-owned-only", 3), ("calendar-picker-restored", 8)):
            terminal = start(binary, owned, fixture, scenario=scenario, columns=columns, rows=rows)
            try:
                terminal.send(b"C")
                wait_calendar(terminal)
                require(f"{expected_count} selected calendars" in terminal.text(), "restart or restored grant changed the displayed source set")
                terminal.send(b"g")
                choose_c(terminal)
                terminal.until(lambda: "[ ] C Imported own calendar" in terminal.text() and "8 checked" in terminal.text())
                if scenario == "calendar-picker-owned-only":
                    terminal.send(b" ")
                    terminal.until(lambda: "No read access · this saved hidden source" in terminal.text())
                    require("[ ] C Imported own calendar" in terminal.text(), "initially hidden unreadable source enabled after restart")
                else:
                    require("no read access" not in terminal.text(), "restored read access remained unavailable")
                choose_g(terminal)
                terminal.send(b"\x1b")
                wait_calendar(terminal)
                terminal.send(b"q")
                terminal.finish()
            except Exception:
                print(terminal.text(), file=sys.stderr)
                raise
            finally:
                terminal.close()
        with Client(binary, owned, scenario="calendar-picker-owned-only", extra=fixture.options()) as client:
            imported = client.request("calendar.list", ACCOUNTS[0])["calendars"][2]
            original = client.request("calendar.list", ACCOUNTS[2])["calendars"][0]
            require(imported["calendar"]["target"]["calendar_id"] == original["calendar"]["target"]["calendar_id"], "fixture did not reproduce the same provider calendar across accounts")
            require(not imported["canRead"] and original["canRead"], "fixture failed to exercise imported-vs-owned grants")
            for account in ACCOUNTS:
                require(provider_state(client, account)["writes"] == 0, "picker visibility sent a Calendar mutation")
    return {"widths": [140, 48], "unreadableCheckedAndUnchecked": True,
            "keyboardAndMouse": True, "cancelRollback": True, "restoreAppliedCheck": True,
            "busyApplyParity": True, "cancelledDiscoveryStaysClosed": True,
            "restartPersistence": True, "restoredAccessStaysHidden": True,
            "sameCalendarDifferentAccountsIndependent": True, "writes": 0}


def source_priority(binary, directory, captures):
    fixture = Invitations(directory)
    for columns in (132, 48):
        owned = directory / f"source-priority-{columns}"
        preferences = owned / "config" / "omagma" / "ui.json"

        def saved():
            return json.loads(preferences.read_text()).get("calendar", {})

        def preferred():
            return saved().get("preferred")

        def choose(terminal, index, label):
            terminal.send(b"k" * 12 + b"j" * index)
            terminal.until(lambda: label in terminal.text())
            terminal.gap(.05)

        def apply(terminal):
            click(terminal, *point(terminal, "[Enter Apply]"))
            wait_calendar(terminal)

        def close(terminal):
            terminal.send(b"q")
            terminal.finish()

        terminal = start(binary, owned, fixture, scenario="calendar-picker-owned-only", columns=columns)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            terminal.send(b"gp")
            terminal.until(lambda: "* Priority" in terminal.text() and "[p Clear priority]" in terminal.text())
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            require(not preferences.exists() or preferred() is None, "Esc persisted a staged Priority-only choice")
            terminal.send(b"g")
            terminal.until(lambda: "Show calendars" in terminal.text() and "[p Priority]" in terminal.text())
            # Cancel, visibility, account, color, Priority: the fifth Tab makes
            # Priority an ordinary reachable button; Enter activates it.
            terminal.send(b"\t" * 5 + b"\r")
            terminal.until(lambda: "[p Clear priority]" in terminal.text() and "* Priority" in terminal.text())
            capture(terminal, captures, f"calendar-priority-picker-{columns}")
            apply(terminal)
            require("A*" in terminal.text(), "applied visible Priority is missing from source legend")
            require(preferred() == {"account": ACCOUNTS[0], "calendarId": ACCOUNTS[0]}, "Priority-only Apply lost exact source identity")
            require(saved().get("scope", "account") == "account" and not saved().get("sources", []), "Priority-only Apply changed visibility, colors, or account scope")
            terminal.send(b"g")
            terminal.until(lambda: "[p Clear priority]" in terminal.text())
            click(terminal, *point(terminal, "[p Clear priority]"))
            terminal.until(lambda: "Priority cleared" in terminal.text() and "[p Priority]" in terminal.text())
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            require("A*" in terminal.text() and preferred()["account"] == ACCOUNTS[0], "Esc did not restore the applied Priority after clearing")
            close(terminal)
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()

        terminal = start(binary, owned, fixture, scenario="calendar-picker-owned-only", columns=columns)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            require("A*" in terminal.text(), "Priority-only preference did not survive a fresh process")
            terminal.send(b"ga")
            terminal.until(lambda: "Show calendars · all accounts" in terminal.text() and "9 checked" in terminal.text() and "[Enter Apply]" in terminal.text())
            choose(terminal, 2, "C Imported own calendar")
            terminal.send(b"p")
            terminal.until(lambda: "No read access · cannot be Priority" in terminal.text())
            require(preferred()["account"] == ACCOUNTS[0], "refused unreadable source replaced saved Priority")
            choose(terminal, 6, "G Personal")
            terminal.send(b"p")
            terminal.until(lambda: "* Priority" in terminal.text() and "[p Clear priority]" in terminal.text())
            apply(terminal)
            expected_g = {"account": ACCOUNTS[2], "calendarId": ACCOUNTS[2]}
            require(preferred() == expected_g, "same-ID source from the owning account was not independently preferred")
            require("G*" in terminal.text() and "C*" not in terminal.text(), "same calendar ID gave a second account an unintended Priority badge")
            require(not saved().get("sources", []), "moving Priority created visibility/color overrides")
            terminal.send(b"g")
            choose(terminal, 6, "G Personal")
            terminal.send(b" p")  # Hide the selected Priority, then clear it.
            terminal.until(lambda: "[ ] G Personal" in terminal.text() and "[p Priority]" in terminal.text())
            terminal.send(b"p")  # Setting it while hidden must not show it.
            terminal.until(lambda: "hidden until shown" in terminal.text() and "Priority (hidden)" in terminal.text())
            capture(terminal, captures, f"calendar-priority-hidden-{columns}")
            apply(terminal)
            require("G*" not in terminal.text() and preferred() == expected_g, "hidden Priority was dropped or unexpectedly displayed")
            source_g = next(value for value in saved()["sources"] if value["account"] == ACCOUNTS[2] and value["calendarId"] == ACCOUNTS[2])
            require(not source_g["visible"], "setting Priority enabled its hidden source")
            close(terminal)
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()

        # The same imported C becomes readable. Choosing it is explicit; it
        # neither unhides owning G nor aliases its account-bound preference.
        terminal = start(binary, owned, fixture, scenario="calendar-picker-restored", columns=columns, no_color=True)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            require("G*" not in terminal.text(), "hidden Priority became shown after restart or restored access")
            terminal.send(b"g")
            choose(terminal, 6, "G Personal")
            terminal.until(lambda: "Priority (hidden)" in terminal.text())
            choose(terminal, 2, "C Imported own calendar")
            terminal.send(b"p")
            terminal.until(lambda: "[p Clear priority]" in terminal.text())
            apply(terminal)
            require(preferred() == {"account": ACCOUNTS[0], "calendarId": ACCOUNTS[2]}, "readable imported Priority used the owning account instead")
            require("C*" in terminal.text() and "G*" not in terminal.text(), "NO_COLOR lost exact readable source Priority")
            capture(terminal, captures, f"calendar-priority-no-color-{columns}")
            close(terminal)
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()

        # Losing read access keeps the user's preferred identity, but its
        # existing Priority can always be cleared, by mouse or keyboard.
        terminal = start(binary, owned, fixture, scenario="calendar-picker-owned-only", columns=columns, no_color=True)
        try:
            terminal.send(b"C")
            wait_calendar(terminal)
            require("C*" not in terminal.text(), "unreadable Priority appeared as an actually displayed source")
            terminal.send(b"g")
            choose(terminal, 2, "C Imported own calendar")
            terminal.until(lambda: "* Priority · not shown · no read access" in terminal.text())
            click(terminal, *point(terminal, "[p Clear priority]"))
            terminal.until(lambda: "Priority cleared" in terminal.text())
            terminal.send(b"\x1b")
            wait_calendar(terminal)
            require(preferred() == {"account": ACCOUNTS[0], "calendarId": ACCOUNTS[2]}, "Cancel forgot an unreadable applied Priority")
            terminal.send(b"g")
            choose(terminal, 2, "C Imported own calendar")
            terminal.send(b"p")
            terminal.until(lambda: "Priority cleared" in terminal.text())
            apply(terminal)
            require(preferred() is None, "clearing an existing unreadable Priority was not persisted")
            close(terminal)
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
        with Client(binary, owned, scenario="calendar-picker-owned-only", extra=fixture.options()) as client:
            for account in ACCOUNTS:
                require(provider_state(client, account)["writes"] == 0, "Priority UI wrote to Calendar")
            require(client.request("cache.stats")["fixtureSends"] == 0, "Priority UI sent RSVP mail")
    return {"widths": [132, 48], "priorityOnlyApplyAndFreshProcess": True,
            "keyboardTabMouse": True, "moveClearCancel": True,
            "sameCalendarDifferentAccountsIndependent": True, "hiddenStaysHidden": True,
            "unreadableNewRefusedExistingClearable": True, "noColorLegend": True, "writes": 0}


def sidebar_navigation(binary, directory, captures):
    fixture = Invitations(directory)
    for columns, rows in ((140, 38), (48, 20)):
        owned = directory / f"sidebar-{columns}"
        terminal = start(binary, owned, fixture, columns=columns, rows=rows)

        def sidebar_point(literal):
            # Desktop sidebars are at most36 cells wide; a focused narrow
            # sidebar fills the terminal. Exclude global header/status rows so
            # a list title or stale feedback can never stand in for the target.
            width = 36 if columns >= 120 else columns
            for y in range(3, rows - 3):
                cells = terminal.screen.cells[y]
                for x in range(width):
                    if cells[x] and "".join(cells[x:width]).startswith(literal):
                        return {"row": y, "column": x}
            return None

        def selected(literal):
            where = sidebar_point(literal)
            return where is not None and terminal.screen.styles[where["row"]][where["column"]][1] == ("rgb", 57, 43, 48)

        def sidebar_click(literal):
            where = sidebar_point(literal)
            require(where is not None, "expected sidebar-only mouse target absent")
            click(terminal, where["column"], where["row"])

        def follow_ups_open():
            # Neither the sidebar due badge nor generic status contains total.
            return any("Follow-ups ·" in line and "total" in line for line in terminal.screen.lines()) and "Enter Mail" in terminal.text()

        try:
            terminal.send(b"\x1b[Z")  # Mail list -> sidebar; never C or the palette.
            terminal.send(b"\x1b[B" * (len(ACCOUNTS) + 7))
            terminal.until(lambda: selected("Unread"))
            terminal.send(b"\x1b[B")
            terminal.until(lambda: selected("Contacts"))
            terminal.send(b"\x1b[B")
            terminal.until(lambda: selected("Calendar · C"))
            capture(terminal, captures, f"sidebar-calendar-{columns}")
            # Tab still changes panes; both directions preserve the selected
            # sidebar destination, including the full-screen narrow sidebar.
            terminal.send(b"\t\x1b[Z")
            terminal.until(lambda: selected("Calendar · C"))
            terminal.send(b"\x1b[Z\t")
            terminal.until(lambda: selected("Calendar · C"))
            terminal.send(b"\r")
            wait_calendar(terminal)
            terminal.send(b"q")
            terminal.until(lambda: selected("Calendar · C"))
            terminal.send(b"\x1b[B")
            terminal.until(lambda: selected("Follow-ups"))
            require(not follow_ups_open(), "Follow-ups was already open before Enter activation")
            terminal.send(b"\r")
            terminal.until(follow_ups_open)
            terminal.send(b"\x1b[Z")
            terminal.until(lambda: selected("Follow-ups"))
            capture(terminal, captures, f"sidebar-follow-ups-{columns}")
            terminal.send(b"\x1b[B")
            terminal.until(lambda: selected("LABELS"))
            terminal.send(b"\x1b[A")
            terminal.until(lambda: selected("Follow-ups"))
            terminal.send(b"\x1b[A")
            terminal.until(lambda: selected("Calendar · C"))
            terminal.send(b"\x1b[A")
            terminal.until(lambda: selected("Contacts"))
            # Restore ordinary mail before the independent mouse workflow;
            # its Follow-ups result must be a new observable transition.
            terminal.send(b"q\t")  # q keeps sidebar focus; Tab shows the list.
            terminal.until(lambda: "Mail ·" in terminal.text() and "Planning version" in terminal.text() and not follow_ups_open())
            terminal.send(b"\x1b[Z")
            terminal.until(lambda: selected("Contacts"))
            # Mouse targets use the same logical destination after scrolling.
            terminal.send(b"\x1b[B")
            terminal.until(lambda: selected("Calendar · C"))
            sidebar_click("Calendar · C")
            wait_calendar(terminal)
            terminal.send(b"q\x1b[B")
            terminal.until(lambda: selected("Follow-ups"))
            require(not follow_ups_open(), "Follow-ups was already open before mouse activation")
            sidebar_click("Follow-ups")
            terminal.until(follow_ups_open)
            terminal.send(b"q")
            terminal.gap(.1)
            terminal.send(b"q")
            terminal.finish()
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
        with Client(binary, owned, extra=fixture.options()) as client:
            # This workflow visits the current account only. Unvisited
            # accounts correctly have no provider fixture storage yet.
            require(provider_state(client)["writes"] == 0, "sidebar navigation wrote Calendar data")
        for path in (owned / "cache").rglob("calendar-provider-fixture.json"):
            require(json.loads(path.read_text())["writes"] == 0, "sidebar navigation wrote another Calendar source")
    return {"widths": [140, 48], "arrowOrder": True, "inverseOrder": True,
            "paneTabRetainsDestination": True, "calendarEnter": True,
            "followUpsEnter": True, "mouseParity": True, "writes": 0}


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
        terminal.until(lambda: "1/2 matches" in terminal.text() and
                       "Chrome profile" in " ".join(terminal.text().replace("│", " ").split()))
        capture(terminal, captures, "calendar-help-search-from-card")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Search help" in terminal.text() and "1/2 matches" not in terminal.text())
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
        terminal.until(lambda: "Show calendars" in terminal.text() and "Holidays" in terminal.text())
        capture(terminal, captures, "calendar-picker")
        terminal.send(b"jjo")
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
        terminal.until(lambda: "1/2 matches" in terminal.text() and "[q Back]" in terminal.text() and
                       "Chrome profile" in " ".join(terminal.text().replace("│", " ").split()))
        capture(terminal, captures, "calendar-help-search-48")
        terminal.send(b"\x1b")
        terminal.until(lambda: "Search help" in terminal.text() and "1/2 matches" not in terminal.text())
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


def wait_destination(terminal):
    terminal.until(lambda: "Calendar · Calendars" in terminal.text()
                   and "Choose destination calendar" in terminal.text()
                   and "A Personal" in terminal.text() and ACCOUNTS[0] in terminal.text()
                   and "[q Back]" in terminal.text() and "[Enter Select]" in terminal.text())


def plan(terminal, version, action):
    search_mail(terminal, version)
    terminal.send(b"A")
    wait_destination(terminal)
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
                wait_destination(terminal)
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
    parser.add_argument("--case", choices=("browse", "combined-sources", "picker-read-access", "source-priority", "sidebar-navigation", "lifecycle", "lost-response", "readonly", "narrow-confirm", "grid-coverage"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    cases = [("browse", browsing), ("combined-sources", combined_sources), ("picker-read-access", picker_read_access), ("source-priority", source_priority), ("sidebar-navigation", sidebar_navigation), ("lifecycle", lifecycle),
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
