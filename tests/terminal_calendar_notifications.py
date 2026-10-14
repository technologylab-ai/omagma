#!/usr/bin/env python3
"""Calendar reminders through the actual TUI in owned, synthetic PTYs.

Run only with the coordinator's cooperative host reservation and assigned build.
No Calendar view is opened to prepare the Mail-startup cases. Provider seeding
uses the existing fixture CLI; observations use completed native terminal frames.
The fixture clock advances event time without advancing real test deadlines.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time
import traceback

from build_info import read_build_info
from terminal_calendar import Invitations
from terminal_integration import ACCOUNTS, Client, ROOT, require
from terminal_mouse import MouseTerminal, click, point
from terminal_pty import compose_fixture, open_composer, saved_compose_frame
from terminal_reader import frame_title
from terminal_reader_editor import ReaderScreen


MINUTE = 60_000
CLOCK_FILE = "calendar-notification-now-ms"


class NotificationTerminal(MouseTerminal):
    def close(self):
        if sys.exc_info()[0]:
            print("Completed notification test screen:\n" + self.text(), file=sys.stderr, flush=True)
            print("TUI exit:", self.process.poll(), "Output tail:", repr(bytes(self.output[-1500:])),
                  file=sys.stderr, flush=True)
        super().close()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".pending")
    temporary.write_text(json.dumps(value, ensure_ascii=False) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def instant(milliseconds):
    return datetime.fromtimestamp(milliseconds / 1000, timezone.utc).isoformat(
        timespec="milliseconds").replace("+00:00", "Z")


def meeting(account, title, start, end, *, ident="notice-event", uid=None,
            calendar=None, response="accepted", link="https://meet.example.test/notice"):
    value = {
        "id": ident, "iCalUID": uid or ident + "@example.test",
        "etag": '"notice-fixture-1"', "sequence": 0, "status": "confirmed",
        "summary": title, "description": "Fictional notification regression.",
        "organizer": {"email": "host@example.test"},
        "attendees": [{"email": account, "self": True, "responseStatus": response}],
        "start": {"dateTime": instant(start)}, "end": {"dateTime": instant(end)},
    }
    if link:
        value["hangoutLink"] = link
    return {"calendar_id": calendar or account, "value": value}


class Fixture:
    def __init__(self, binary, directory):
        self.binary, self.directory = binary, directory
        self.mail = Invitations(directory)
        self.client_dir = directory / "client"
        self.config = directory / "accounts.json"
        atomic_json(self.config, json.loads((ROOT / "tests/fixtures/all-accounts.json").read_text()))
        self.preferences = directory / "ui.json"
        atomic_json(self.preferences, {"schema": 1, "theme": "omagma",
                                      "readerLayout": "right", "lastAccount": ACCOUNTS[0]})
        self.noon = int(datetime.now(timezone.utc).replace(
            hour=12, minute=0, second=0, microsecond=0).timestamp() * 1000)
        self.clock(self.noon)
        self.provider_paths = {}
        with self.client() as client:
            for account in ACCOUNTS:
                client.request("mail.refresh", account, label="INBOX", limit=30, prefetchLimit=3)
                client.request("calendar.list", account)
        for path in (self.client_dir / "cache").rglob("calendar-provider-fixture.json"):
            state = json.loads(path.read_text())
            self.provider_paths[state["account"]] = path
        require(set(self.provider_paths) == set(ACCOUNTS), "fixture Calendar stores are incomplete")
        self.events = {account: [] for account in ACCOUNTS}
        self.publish()

    def options(self):
        return (*self.mail.options(), "--config", str(self.config))

    def client(self, scenario=None):
        return Client(self.binary, self.client_dir, scenario=scenario, extra=self.options())

    def clock(self, now):
        self.now = now
        path = self.mail.root / CLOCK_FILE
        temporary = path.with_suffix(".pending")
        temporary.write_text(str(now) + "\n")
        temporary.chmod(0o600)
        temporary.replace(path)

    def publish(self):
        for account, events in self.events.items():
            atomic_json(self.provider_paths[account], {
                "schema": 1, "account": account, "generation": 0,
                "writes": 0, "events": events,
            })

    def cache_calendars(self):
        """Prime offline snapshots, never the Calendar TUI or notification state."""
        day = datetime.fromtimestamp(self.now / 1000, timezone.utc).date().isoformat()
        with self.client() as client:
            for account in ACCOUNTS:
                for calendar in (account, "fixture-shared-team", "fixture-readonly"):
                    client.request("calendar.agenda", account, calendarId=calendar,
                                   date=day, view="day", timeZone="UTC")

    def start(self, scenario=None, account=None, columns=140, rows=40, environment=None):
        extra = (*self.options(), "--account", account or ACCOUNTS[0],
                 "--ui-file", str(self.preferences))
        if scenario:
            extra += ("--fixture-scenario", scenario)
        terminal = NotificationTerminal(self.binary, self.client_dir, extra=extra,
                                 screen_type=ReaderScreen, columns=columns, rows=rows,
                                 environment={"TZ": "UTC", "NO_COLOR": None,
                                              "COLORTERM": "truecolor", **(environment or {})})
        try:
            terminal.until(lambda: settled(terminal) and "Planning version" in terminal.text())
        except BaseException:
            terminal.close()
            raise
        return terminal

    def untouched(self):
        for path in self.provider_paths.values():
            require(json.loads(path.read_text())["writes"] == 0,
                    "notification performed a Calendar mutation")
        with self.client() as client:
            for account in ACCOUNTS:
                require(client.request("cache.stats", account)["fixtureSends"] == 0,
                        "notification sent mail")


def settled(terminal):
    return not terminal.screen.frame_open


def visible(terminal, title):
    return settled(terminal) and title in terminal.text()


def wait_notice(terminal, title, minutes=None, remaining=False):
    def matches():
        text = terminal.text()
        if not visible(terminal, title):
            return False
        if minutes is not None and not re.search(r"\b" + str(minutes) + r"\s*(?:min(?:utes?)?|m)\b", text):
            return False
        return not remaining or re.search(r"remaining|left", text, re.I) is not None
    terminal.until(matches, seconds=12)
    require("Calendar · Agenda" not in terminal.text(), "notification opened Calendar instead of staying in Mail")


def absent_for(terminal, titles, seconds=1.2):
    """Check every completed observed frame, including transient reappearances."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        terminal.pump(.03)
        if settled(terminal):
            for title in titles:
                require(title not in terminal.text(), "unexpected Calendar notification: " + title)


def dismiss(terminal):
    terminal.until(lambda: settled(terminal) and terminal.screen.locate("Dismiss") is not None)
    # Let the card's occurrence-change guard settle before an intentional click.
    terminal.gap(.65)
    click(terminal, *point(terminal, "Dismiss"))


def startup_and_clock(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Mail startup clock meeting"
    start = fixture.noon + 10 * MINUTE + 1_000
    end = start + 30 * MINUTE
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], title, start, end)]
    fixture.publish()
    terminal = fixture.start()
    try:
        absent_for(terminal, [title])
        fixture.clock(start - 10 * MINUTE)
        wait_notice(terminal, title, 10)
        fixture.clock(start - 9 * MINUTE - 1)
        wait_notice(terminal, title, 10)
        fixture.clock(start - 9 * MINUTE)
        wait_notice(terminal, title, 9)
        fixture.clock(start)
        wait_notice(terminal, title, 30, remaining=True)
        fixture.clock(start + 15 * MINUTE)
        wait_notice(terminal, title, 15, remaining=True)
        fixture.clock(end - 1)
        wait_notice(terminal, title, 1, remaining=True)
        fixture.clock(end)
        terminal.until(lambda: settled(terminal) and title not in terminal.text())
        absent_for(terminal, [title])
        terminal.finish()
        fixture.untouched()
        return {"mailFirst": True, "fixedThemeTicks": True, "exactTenMinuteBoundary": True,
                "countdownCeiling": True, "startAndEnd": True, "typedInputToAdvanceClock": False}
    finally:
        terminal.close()


def dismiss_and_overlap(binary, directory):
    fixture = Fixture(binary, directory)
    start, end = fixture.noon + 5 * MINUTE, fixture.noon + 35 * MINUTE
    names = ["Overlap alpha meeting", "Overlap beta meeting"]
    fixture.events[ACCOUNTS[0]] = [
        meeting(ACCOUNTS[0], name, start, end, ident="overlap-" + str(index), uid="shared-uid@example.test")
        for index, name in enumerate(names)]
    fixture.publish()
    terminal = fixture.start()
    try:
        terminal.until(lambda: settled(terminal) and any(name in terminal.text() for name in names))
        first = next(name for name in names if name in terminal.text())
        second = next(name for name in names if name != first)
        terminal.send(b"M")
        terminal.gap(.7)
        terminal.send(b"n")
        wait_notice(terminal, second)
        terminal.send(b"\x1b")
        terminal.gap(.15)
        fixture.clock(fixture.now + 2_000)
        absent_for(terminal, [first], seconds=2.2)
        require(second in terminal.text(), "refresh changed the explicitly selected occurrence")
        terminal.send(b"M")
        terminal.gap(.7)
        terminal.send(b"n")
        wait_notice(terminal, first)
        terminal.send(b"\x1b")
        terminal.gap(.15)
        dismiss(terminal)
        wait_notice(terminal, second)
        require(first not in terminal.text(), "dismissing one occurrence dismissed neither or both")
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and all(name not in terminal.text() for name in names))
        fixture.clock(start + MINUTE)
        absent_for(terminal, names, seconds=2.2)
        terminal.send(b"\x12")
        absent_for(terminal, names, seconds=1.2)
        terminal.finish()
        fixture.untouched()
        return {"sameTimeDistinctIds": True, "sharedUid": True, "dismissedNoRepeat": True,
                "explicitNext": True, "selectedOccurrencePinnedAcrossRefresh": True}
    finally:
        terminal.close()


def accounts_and_calendars(binary, directory):
    fixture = Fixture(binary, directory)
    start, end = fixture.noon + 5 * MINUTE, fixture.noon + 35 * MINUTE
    names = ["Personal account reminder", "Work account reminder", "Shared calendar reminder"]
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], names[0], start, end, ident="same-provider-id")]
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], names[1], start, end, ident="same-provider-id")]
    fixture.events[ACCOUNTS[2]] = [meeting(ACCOUNTS[2], names[2], start, end,
                                          ident="same-provider-id", calendar="fixture-shared-team")]
    fixture.publish()
    terminal = fixture.start(account=ACCOUNTS[0])
    try:
        remaining = set(names)
        while remaining:
            terminal.until(lambda: settled(terminal) and any(name in terminal.text() for name in remaining), seconds=15)
            title = next(name for name in remaining if name in terminal.text())
            account = ACCOUNTS[names.index(title)]
            require(account in terminal.text(), "notification omitted its owning account")
            dismiss(terminal)
            terminal.until(lambda: settled(terminal) and title not in terminal.text())
            remaining.remove(title)
        absent_for(terminal, names)
        terminal.finish()
        fixture.untouched()
        return {"accounts": 3, "crossAccountIdCollision": True,
                "selectedSharedCalendar": True, "allAccountsServiced": True}
    finally:
        terminal.close()


def excluded_events(binary, directory):
    fixture = Fixture(binary, directory)
    account = ACCOUNTS[0]
    start, end = fixture.noon + 5 * MINUTE, fixture.noon + 35 * MINUTE
    canceled = meeting(account, "Canceled event must stay absent", start, end, ident="cancelled")
    canceled["value"]["status"] = "cancelled"
    declined = meeting(account, "Declined event must stay absent", start, end, ident="declined", response="declined")
    all_day = meeting(account, "All day must stay absent", start, end, ident="all-day")
    date = datetime.fromtimestamp(fixture.noon / 1000, timezone.utc).date()
    all_day["value"]["start"] = {"date": date.isoformat()}
    all_day["value"]["end"] = {"date": (date + timedelta(days=1)).isoformat()}
    expired = meeting(account, "Ended event must stay absent", fixture.noon - 30 * MINUTE,
                      fixture.noon, ident="ended")
    future = meeting(account, "Future event must stay absent", fixture.noon + 11 * MINUTE,
                     fixture.noon + 41 * MINUTE, ident="future")
    eligible = meeting(account, "Eligible event remains visible", start, end, ident="eligible")
    excluded = [canceled, declined, all_day, expired, future]
    fixture.events[account] = [*excluded, eligible]
    fixture.publish()
    terminal = fixture.start()
    try:
        wait_notice(terminal, eligible["value"]["summary"])
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and eligible["value"]["summary"] not in terminal.text())
        absent_for(terminal, [event["value"]["summary"] for event in excluded], seconds=2.2)
        terminal.finish()
        fixture.untouched()
        return {"cancelled": True, "declined": True, "allDay": True, "ended": True, "tooEarly": True}
    finally:
        terminal.close()


def account_permissions(binary, directory):
    fixture = Fixture(binary, directory)
    start, end = fixture.noon + 5 * MINUTE, fixture.noon + 35 * MINUTE
    enabled, disabled = "Readable account reminder", "Disabled account must stay absent"
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], enabled, start, end)]
    fixture.events[ACCOUNTS[2]] = [meeting(ACCOUNTS[2], disabled, start, end)]
    fixture.publish()
    config = json.loads(fixture.config.read_text())
    config["accounts"][2]["enabled"] = False
    atomic_json(fixture.config, config)
    # Calendar read permission is sufficient; neither write scope nor consent
    # UI is needed. A configured disabled account remains excluded.
    terminal = fixture.start(scenario="calendar-readonly")
    try:
        wait_notice(terminal, enabled, 5)
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and enabled not in terminal.text())
        absent_for(terminal, [enabled, disabled], seconds=2.2)
        terminal.finish()
    finally:
        terminal.close()
    # Same persisted data, but the active handshake now grants only Mail read.
    terminal = fixture.start(scenario="readonly")
    try:
        absent_for(terminal, [enabled, disabled], seconds=3.2)
        fixture.clock(fixture.now + MINUTE)
        absent_for(terminal, [enabled, disabled], seconds=2.2)
        require("Permission required" not in terminal.text(),
                "background reminder opened authorization UI without a Calendar grant")
        terminal.finish()
        config["accounts"][2]["enabled"] = True
        atomic_json(fixture.config, config)
        fixture.untouched()
        return {"calendarReadOnlySuffices": True, "disabledAccountExcluded": True,
                "mailOnlyGrantStaysQuiet": True}
    finally:
        terminal.close()


def calendar_view_preserved(binary, directory):
    fixture = Fixture(binary, directory)
    next_week = fixture.noon + 8 * 24 * 60 * MINUTE - 3 * 60 * MINUTE
    browsing = "Next week browsing stays put"
    notification = "Other account meeting now due"
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], browsing, next_week,
                                          next_week + 30 * MINUTE)]
    start = fixture.noon + 11 * MINUTE
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], notification, start,
                                          start + 30 * MINUTE)]
    fixture.publish()
    terminal = fixture.start()
    try:
        terminal.send(b"C")
        terminal.until(lambda: settled(terminal) and "Calendar · Agenda" in terminal.text()
                       and "Up to date" in terminal.text())
        terminal.send(b"l")
        terminal.until(lambda: visible(terminal, browsing))
        fixture.clock(start - 10 * MINUTE)
        terminal.until(lambda: visible(terminal, notification), seconds=12)
        require("Calendar · Agenda" in terminal.text() and browsing in terminal.text(),
                "background reminder replaced the Calendar period or visible agenda")
        require(ACCOUNTS[1] in terminal.text(), "background reminder lost the other account")
        terminal.send(b"/")
        terminal.until(lambda: settled(terminal) and "Loaded events /" in terminal.text())
        terminal.send(b"M calendar literal")
        terminal.until(lambda: settled(terminal) and "M calendar literal" in terminal.text())
        require(notification not in terminal.text() and "keys here" not in terminal.text(),
                "M in Calendar search focused the notification instead of entering text")
        terminal.send(b"\x1b")
        terminal.until(lambda: visible(terminal, notification) and browsing in terminal.text())
        terminal.send(b"M")
        terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
        terminal.gap(.7)
        terminal.send(b"\x04")
        terminal.until(lambda: settled(terminal) and notification not in terminal.text())
        require(browsing in terminal.text(), "dismissing reminder changed the Calendar selection")
        terminal.gap(.8)
        terminal.send(b"q")
        terminal.until(lambda: settled(terminal) and "Calendar · Agenda" not in terminal.text())
        terminal.finish()
        fixture.untouched()
        return {"visibleCalendarPeriodPreserved": True, "otherAccountRefresh": True,
                "literalMInCalendarSearch": True, "calendarMFocus": True}
    finally:
        terminal.close()


def focused_expiry(binary, directory):
    fixture = Fixture(binary, directory)
    start = fixture.noon + MINUTE
    names = ["Focused event expires first", "Other event must not be joined"]
    fixture.events[ACCOUNTS[0]] = [
        meeting(ACCOUNTS[0], names[0], start, start + MINUTE, ident="expires"),
        meeting(ACCOUNTS[0], names[1], start, start + 30 * MINUTE, ident="survives"),
    ]
    fixture.publish()
    terminal = fixture.start()
    try:
        terminal.until(lambda: settled(terminal) and "of 2" in terminal.text()
                       and any(name in terminal.text() for name in names))
        if names[0] not in terminal.text():
            terminal.gap(.65)
            click(terminal, *point(terminal, "Next"))
            wait_notice(terminal, names[0])
            terminal.send(b"\x1b")
            terminal.until(lambda: visible(terminal, names[0]) and "keys here" not in terminal.text())
        wait_notice(terminal, names[0])
        terminal.send(b"M")
        terminal.gap(.7)
        fixture.clock(start + MINUTE)
        terminal.gap(2.2)
        terminal.send(b"o")
        terminal.gap(.3)
        require("Join target validated" not in terminal.text(),
                "expiry retargeted focused Join to a different meeting")
        # The consumed key already closes the expired card's focus guard.
        wait_notice(terminal, names[1], 29, remaining=True)
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and names[1] not in terminal.text())
        terminal.finish()
        fixture.untouched()
        return {"focusPinsOccurrence": True, "expiryDoesNotRetargetJoin": True}
    finally:
        terminal.close()


def focused_provider_changes(binary, directory):
    fixture = Fixture(binary, directory)
    account = ACCOUNTS[0]
    canceled = meeting(account, "Focused occurrence canceled remotely", fixture.noon + 5 * MINUTE,
                       fixture.noon + 35 * MINUTE, ident="focus-cancel")
    moved = meeting(account, "Focused occurrence rescheduled remotely", fixture.noon + 6 * MINUTE,
                    fixture.noon + 36 * MINUTE, ident="focus-move")
    survivor = "Other account occurrence must survive"
    fixture.events[account] = [canceled, moved]
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], survivor, fixture.noon + 7 * MINUTE,
                                         fixture.noon + 37 * MINUTE, ident="focus-survivor")]
    fixture.publish()
    terminal = fixture.start()

    def wait_guard():
        terminal.until(lambda: settled(terminal) and "Meeting ended or changed · no action taken" in terminal.text()
                       and "keys here" in terminal.text(), seconds=12)

    try:
        # Account agendas arrive independently. Observe every occurrence before
        # testing which one survives a focused cancellation/reschedule: a card
        # selected before another account arrives intentionally stays selected.
        expected_accounts = {canceled["value"]["summary"]: account,
                             moved["value"]["summary"]: account,
                             survivor: ACCOUNTS[1]}
        terminal.until(lambda: settled(terminal) and "of 3" in terminal.text()
                       and any(title in terminal.text() for title in expected_accounts), seconds=12)
        current = next(title for title in expected_accounts if title in terminal.text())
        observed = {current}
        require(notification_account(terminal) == expected_accounts[current],
                "initial focused occurrence has the wrong account")
        # Start from whichever account arrived first, then deliberately select
        # the cancellation target after checking every occurrence and account.
        for _ in range(5):
            if observed == set(expected_accounts) and current == canceled["value"]["summary"]:
                break
            terminal.gap(.65)
            click(terminal, *point(terminal, "Next"))
            terminal.until(lambda: settled(terminal) and any(
                title != current and title in terminal.text() for title in expected_accounts), seconds=12)
            current = next(title for title in expected_accounts if title in terminal.text())
            require(notification_account(terminal) == expected_accounts[current],
                    "initial reminder cycle mixed occurrence and account")
            observed.add(current)
        require(observed == set(expected_accounts) and current == canceled["value"]["summary"],
                "initial reminder cycle did not observe all occurrences and select the cancellation target")
        terminal.send(b"\x1b")
        terminal.until(lambda: visible(terminal, current) and "keys here" not in terminal.text())
        terminal.send(b"M")
        terminal.gap(.7)
        canceled["value"].update(status="cancelled", sequence=1, etag='"focus-cancel-2"')
        fixture.publish()
        wait_guard()  # Observe a completed poll, without advancing the civil fixture clock.
        terminal.send(b"o")
        wait_notice(terminal, moved["value"]["summary"])
        require("Join target validated" not in terminal.text() and "keys here" not in terminal.text(),
                "canceled focused Join retargeted another occurrence")

        terminal.send(b"M")
        terminal.gap(.7)
        moved["value"].update(summary="New time requires a fresh meeting action", sequence=1,
                              etag='"focus-move-2"')
        moved["value"]["start"] = {"dateTime": instant(fixture.noon + 8 * MINUTE)}
        moved["value"]["end"] = {"dateTime": instant(fixture.noon + 38 * MINUTE)}
        fixture.publish()
        wait_guard()
        terminal.send(b"\x04")
        wait_notice(terminal, survivor)
        require("keys here" not in terminal.text(), "rescheduled dismissal transferred keyboard ownership")
        terminal.send(b"M")
        terminal.gap(.7)
        terminal.send(b"n")
        wait_notice(terminal, moved["value"]["summary"])
        require("keys here" in terminal.text(), "explicit Next lost the newly selected occurrence")

        # Revoking a link on the same occurrence must remove the old Join
        # action while preserving the user's chosen occurrence and its focus.
        moved["value"].pop("hangoutLink")
        moved["value"].update(summary="Focused occurrence now has no meeting link", sequence=2,
                              etag='"focus-move-3"')
        fixture.publish()
        wait_notice(terminal, moved["value"]["summary"])
        require("[o Join]" not in terminal.text() and "[Join]" not in terminal.text(),
                "same-occurrence link removal retained the old Join action")
        terminal.send(b"o")
        terminal.gap(.3)
        require("Join target validated" not in terminal.text()
                and moved["value"]["summary"] in terminal.text() and "keys here" in terminal.text(),
                "removed-link Join opened or selected another occurrence")

        moved["value"].update(summary="Focused occurrence replacement link", sequence=3,
                              etag='"focus-move-4"', hangoutLink="https://meet.example.test/replaced-focus-link")
        fixture.publish()
        wait_notice(terminal, moved["value"]["summary"])
        require("[o Join]" in terminal.text(), "replacement link did not restore the focused Join action")
        terminal.send(b"o")
        terminal.until(lambda: settled(terminal) and "Join target validated" in terminal.text())
        require("Profile 3" in terminal.text() and "Profile 1" not in terminal.text(),
                "updated focused occurrence joined the overlapping account instead")
        terminal.send(b"\x04")
        wait_notice(terminal, survivor)
        require("keys here" not in terminal.text(), "explicit dismissal focused the remaining occurrence")
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and survivor not in terminal.text())
        absent_for(terminal, [canceled["value"]["summary"], moved["value"]["summary"], survivor], seconds=2.2)
        terminal.finish()
        fixture.untouched()
        return {"focusedCancellationConsumesJoin": True, "focusedRescheduleConsumesDismiss": True,
                "otherOccurrenceSurvives": True, "removedLinkCannotJoin": True,
                "replacementLinkKeepsAccount": True, "fixedCivilClockPolling": True,
                "allOccurrencesObservedBeforeMutation": True,
                "fixtureSends": 0}
    finally:
        terminal.close()


def compose_input(binary, directory):
    fixture = Fixture(binary, directory)
    title = "No input stealing meeting"
    start = fixture.noon + 11 * MINUTE
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], title, start, start + 30 * MINUTE)]
    fixture.publish()
    terminal = fixture.start()
    try:
        open_composer(terminal)
        terminal.send(b"\t\t\t\tiLiteral ")
        terminal.until(lambda: settled(terminal) and "Literal" in terminal.text())
        fixture.clock(start - 5 * MINUTE)
        absent_for(terminal, [title, "M Meeting actions", "Upcoming meeting"], seconds=2.2)
        terminal.send(b"M o d tomorrow good")
        terminal.until(lambda: settled(terminal) and "Literal M o d tomorrow good" in terminal.text())
        pasted = "\nPasted M o d café 世界"
        terminal.send(b"\x1b[200~" + pasted.encode() + b"\x1b[201~")
        terminal.until(lambda: settled(terminal) and "Pasted M o d café 世界" in terminal.text())
        terminal.send(b"\rTyped after arrival")
        terminal.until(lambda: settled(terminal) and "Typed after arrival" in terminal.text())
        expected = "Literal M o d tomorrow good" + pasted + "\nTyped after arrival"
        require("Join target validated" not in terminal.text(), "notification stole a typed o to join")
        terminal.send(b"\x1b")
        terminal.gap(.3)
        terminal.send(b"q")
        terminal.until(lambda: settled(terminal) and "Compose" not in terminal.text()
                       and "Mail ·" in terminal.text())
        wait_notice(terminal, title, 5)
        terminal.finish()
        with fixture.client() as client:
            drafts = client.request("draft.list", ACCOUNTS[0])["drafts"]
            require(len(drafts) == 1, "reminder arrival did not retain exactly one authored draft")
            retained = client.request("draft.read", ACCOUNTS[0], draftId=drafts[0]["id"])
            require(retained["bodyText"] == expected,
                    "notification arrival changed typed or pasted Unicode draft text")
        fixture.untouched()
        return {"dueDuringInsert": True, "literalMAndOAndD": True, "savedTextRetained": True,
                "exactTypedAndPastedBody": True, "unicodePaste": True,
                "composeCardSuppressed": True, "cardReturnsInMail": True}
    finally:
        terminal.close()


def offline_cached(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Saved offline meeting"
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], title, fixture.noon + 5 * MINUTE,
                                         fixture.noon + 35 * MINUTE)]
    fixture.publish()
    fixture.cache_calendars()
    terminal = fixture.start(scenario="calendar-offline")
    try:
        absent_for(terminal, [title], seconds=3.2)
        fixture.clock(fixture.noon + 6 * MINUTE)
        absent_for(terminal, [title], seconds=2.2)
        terminal.finish()
        day = datetime.fromtimestamp(fixture.now / 1000, timezone.utc).date().isoformat()
        with fixture.client(scenario="calendar-offline") as client:
            cached = client.request("calendar.agenda", ACCOUNTS[0], calendarId=ACCOUNTS[0],
                                    date=day, view="day", timeZone="UTC", cacheOnly=True)
            require(any(event["summary"] == title for event in cached["snapshot"]["events"]),
                    "offline notification startup erased the saved Calendar event")
        fixture.untouched()
        return {"mailFirst": True, "staleCacheDoesNotRaiseNewNotice": True, "savedEventRetained": True}
    finally:
        terminal.close()


def review_countdown_arrival(binary, directory):
    fixture = Fixture(binary, directory)
    names = ["Meeting arrives during send review", "Meeting arrives during send countdown"]
    for index, title in enumerate(names):
        start = fixture.noon + (11 + index * 6) * MINUTE
        fixture.events[ACCOUNTS[1]].append(
            meeting(ACCOUNTS[1], title, start, start + 30 * MINUTE,
                    ident="send-arrival-" + str(index)))
    fixture.publish()
    terminal = fixture.start()

    def countdown():
        return "[Undo Ctrl+Z]" in terminal.text() and "Sending in" in terminal.text()

    try:
        compose_fixture(terminal)
        terminal.send(b"\x13")
        terminal.until(lambda: settled(terminal) and "Review send" in terminal.text()
                       and "[y Send]" in terminal.text() and "Sending account:" in terminal.text())
        fixture.clock(fixture.noon + MINUTE)
        absent_for(terminal, names + ["M Meeting actions", "keys here"], seconds=2.2)
        terminal.send(b"Mod")
        terminal.gap(.2)
        require("Review send" in terminal.text() and "[y Send]" in terminal.text(),
                "reminder arrival or its shortcuts escaped the explicit send review")
        require("Join target validated" not in terminal.text(), "send review input joined a meeting")
        terminal.send(b"y")  # Explicitly stage the synthetic draft's default ten-second Undo window.
        terminal.until(lambda: settled(terminal) and countdown())
        fixture.clock(fixture.noon + 7 * MINUTE)
        absent_for(terminal, names + ["M Meeting actions", "keys here"], seconds=2.2)
        terminal.send(b"Mod")
        terminal.gap(.1)
        require(countdown(), "reminder shortcuts changed the active send countdown")
        terminal.send(b"\x1a")
        terminal.until(lambda: settled(terminal) and not countdown()
                       and "Send cancelled · draft retained" in terminal.text())
        with fixture.client() as client:
            queued = client.request("queue.list", ACCOUNTS[0])["queue"]
            require(len(queued) == 1 and queued[0]["state"] == "canceled",
                    "Undo did not cancel exactly the reviewed durable send intent")
            require(queued[0]["dueAtMs"] - queued[0]["createdAtMs"] == 10_000,
                    "combined workflow changed the default send countdown")
            require(not client.request("operation.list", ACCOUNTS[0])["operations"],
                    "reminder arrival or Undo created a provider submission")
            require(client.request("cache.stats", ACCOUNTS[0])["fixtureSends"] == 0,
                    "meeting arrival bypassed the send Undo window")

        terminal.send(b"i Undo M o d retained")
        terminal.until(lambda: settled(terminal) and "Undo M o d retained" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.3)
        terminal.send(b"q")
        terminal.until(lambda: settled(terminal) and "Compose" not in terminal.text()
                       and "Mail ·" in terminal.text())
        wait_notice(terminal, names[0], 4)
        dismiss(terminal)
        wait_notice(terminal, names[1], 10)
        # Cross the canceled deadline while reminders continue polling. Undo
        # must cancel submission ownership, rather than merely hide the toast.
        terminal.gap(max(0, (queued[0]["dueAtMs"] - time.time() * 1000) / 1000) + .2)
        terminal.finish()
        with fixture.client() as client:
            after = client.request("queue.list", ACCOUNTS[0])["queue"]
            require(len(after) == 1 and after[0]["queueId"] == queued[0]["queueId"]
                    and after[0]["state"] == "canceled", "expired Undo intent became sendable again")
            retained = client.request("draft.read", ACCOUNTS[0], draftId=queued[0]["draftId"])
            require(retained["bodyText"] == "Reviewed synthetic PTY body. Undo M o d retained",
                    "review, countdown, or reminder arrival changed the retained draft")
            require(not client.request("operation.list", ACCOUNTS[0])["operations"],
                    "canceled countdown acquired a submission receipt after its deadline")
        fixture.untouched()
        return {"reviewArrival": True, "countdownArrival": True, "defaultGraceMs": 10_000,
                "undoDurablyCanceled": True, "originalDeadlineCrossed": True,
                "postUndoEditingRetained": True, "bothRemindersReturnInMail": True,
                "fixtureSends": 0}
    finally:
        terminal.close()


def editor_handoff(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Meeting across external editor"
    start, end = fixture.noon + 11 * MINUTE, fixture.noon + 41 * MINUTE
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], title, start, end)]
    fixture.publish()
    script = directory / "owned_notification_editor.py"
    script.write_text(r'''import json
import os
from pathlib import Path
import sys
import termios
import time
import tty

path = Path(sys.argv[-1])
log = Path(os.environ["OMAGMA_EDITOR_TEST_LOG"])
settings = termios.tcgetattr(0)
deadline = time.monotonic() + 5
while os.tcgetpgrp(0) != os.getpgrp():
    if time.monotonic() >= deadline:
        raise RuntimeError("editor did not receive foreground terminal")
    time.sleep(.005)
receipt = {"pid": os.getpid(), "processGroup": os.getpgrp(),
           "foregroundGroup": os.tcgetpgrp(0), "sessionId": os.getsid(0),
           "initialCanonical": bool(settings[3] & termios.ICANON),
           "initialEcho": bool(settings[3] & termios.ECHO), "input": ""}
def publish():
    temporary = log.with_suffix(".pending")
    temporary.write_text(json.dumps(receipt) + "\n")
    temporary.replace(log)
publish()
try:
    tty.setraw(0)
    os.write(1, b"\r\nOWNED REMINDER EDITOR: Ctrl+S saves\r\n")
    authored = bytearray()
    while True:
        char = os.read(0, 1)
        if char == b"\x13":
            break
        if not char:
            raise RuntimeError("editor input closed before save")
        authored.extend(char)
        os.write(1, char)
        receipt["input"] = authored.decode("utf-8", errors="replace")
        publish()
    path.write_bytes(bytes(authored) + b"\n")
    receipt["exited"] = True
    publish()
finally:
    termios.tcsetattr(0, termios.TCSANOW, settings)
''')
    script.chmod(0o600)
    terminal = fixture.start(environment={"EDITOR": shlex.join([sys.executable, str(script)])})

    def enter_editor():
        terminal.editor_log.unlink(missing_ok=True)
        terminal.send(b"e")
        terminal.until(lambda: terminal.editor_log.exists() and "OWNED REMINDER EDITOR:" in terminal.text())
        entry = json.loads(terminal.editor_log.read_text())
        require(entry["initialCanonical"] and entry["initialEcho"]
                and entry["foregroundGroup"] == entry["processGroup"],
                "external editor did not receive a restored foreground terminal")
        require(not terminal.screen.mouse_modes, "Omagma mouse tracking remained active inside editor")
        terminal.gap(.2)

    def clock_inside_editor(now):
        before = terminal.output_total
        fixture.clock(now)
        terminal.gap(2.2)
        require(terminal.output_total == before,
                "notification scheduler wrote into the external editor's terminal")
        require(not terminal.screen.mouse_modes, "notification tick restored mouse tracking inside editor")

    def save_editor(authored):
        terminal.send(authored.encode())
        terminal.until(lambda: json.loads(terminal.editor_log.read_text())["input"] == authored)
        terminal.send(b"\x13")
        terminal.until(lambda: json.loads(terminal.editor_log.read_text()).get("exited") is True)
        terminal.until(lambda: terminal.screen.mouse_tracking_mode == 1002)

    try:
        open_composer(terminal)
        enter_editor()
        clock_inside_editor(start - 10 * MINUTE)
        clock_inside_editor(start + 5 * MINUTE)
        authored = "Literal M o d editor text"
        save_editor(authored)
        terminal.until(lambda: settled(terminal) and saved_compose_frame(terminal, 0)
                       and "Editor returned" in terminal.text()
                       and authored in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: settled(terminal) and "Compose" not in terminal.text()
                       and "Mail ·" in terminal.text())
        # Saving/returning may preempt a Calendar read. Let the five-second
        # fixture-clock retry deadline elapse, as wall time would in production.
        fixture.clock(fixture.now + 5_000)
        wait_notice(terminal, title, 25, remaining=True)
        # A received-mail editor must also survive an active reminder expiring.
        terminal.send(b"\r")
        terminal.until(lambda: settled(terminal) and "Please join the planning meeting." in terminal.text())
        enter_editor()
        clock_inside_editor(end)
        save_editor("Received snapshot local edit only")
        terminal.until(lambda: settled(terminal) and "Please join the planning meeting." in terminal.text()
                       and "OWNED REMINDER EDITOR:" not in terminal.text())
        terminal.until(lambda: settled(terminal) and title not in terminal.text())
        absent_for(terminal, [title])
        require("Received snapshot local edit only" not in terminal.text(),
                "editor return replaced the received message with a disposable edit")
        terminal.finish()
        with fixture.client() as client:
            drafts = client.request("draft.list", ACCOUNTS[0])["drafts"]
            require(any(authored in json.dumps(client.request("draft.read", ACCOUNTS[0], draftId=draft["id"]))
                        for draft in drafts), "editor handoff lost the composed body")
        fixture.untouched()
        return {"composeEditor": True, "receivedEditor": True, "foregroundTtyRestored": True,
                "noEditorTerminalPollution": True, "literalInput": True,
                "dueStartEndWhileEditorOpen": True, "returnReconcilesCountdown": True,
                "foregroundPreemptionRetryAdvanceMs": 5_000, "returnRemainingMinutes": 25}
    finally:
        terminal.close()


def join_routing(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Work profile while reading personal"
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], title, fixture.noon + 5 * MINUTE,
                                         fixture.noon + 35 * MINUTE)]
    fixture.publish()
    terminal = fixture.start(account=ACCOUNTS[0])
    try:
        wait_notice(terminal, title)
        terminal.send(b"M")  # Explicitly focus the notification.
        terminal.gap(.7)
        terminal.send(b"o")
        terminal.until(lambda: settled(terminal) and "Join target validated" in terminal.text())
        require("Profile 1" in terminal.text(), "notification joined with the focused mailbox's profile")
        require("Profile 3" not in terminal.text(), "personal profile leaked into the work meeting result")
        require(title in terminal.text(), "Join dismissed the notification before the event ended")
        terminal.send(b"\x1b")
        terminal.finish()
        fixture.untouched()
        return {"focusedMailbox": ACCOUNTS[0], "meetingAccount": ACCOUNTS[1],
                "profile": "Profile 1", "explicitFocus": True, "joinKeepsNotice": True}
    finally:
        terminal.close()


def keyboard_dismiss(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Dismiss needs Ctrl shortcut"
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], title, fixture.noon + 5 * MINUTE,
                                         fixture.noon + 35 * MINUTE)]
    fixture.publish()
    terminal = fixture.start()
    try:
        wait_notice(terminal, title)
        terminal.send(b"\x04")
        terminal.gap(.3)
        require(title in terminal.text(), "passive Ctrl+D dismissed the card instead of scrolling Mail")
        require("M Meeting actions" in terminal.text() and "F8" not in terminal.text(),
                "notification did not advertise the laptop-friendly M shortcut")
        terminal.send(b"/")
        terminal.until(lambda: settled(terminal) and "Cache / " in terminal.text())
        terminal.send(b"M mail literal")
        terminal.until(lambda: settled(terminal) and "M mail literal" in terminal.text())
        require(title not in terminal.text() and "keys here" not in terminal.text(),
                "M in Mail search focused the notification instead of entering text")
        terminal.send(b"\x1b")
        wait_notice(terminal, title)
        terminal.send(b"M")
        terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
        terminal.send(b"m")
        terminal.gap(.2)
        require(title in terminal.text() and "keys here" in terminal.text(),
                "focused lowercase m escaped the card and opened Mail labels")
        terminal.send(b"M")
        terminal.until(lambda: settled(terminal) and "M Meeting actions" in terminal.text()
                       and "keys here" not in terminal.text())
        terminal.send(b"\x1b[109;2u")  # Shift+m from an enhanced keyboard protocol.
        terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
        terminal.send(b"M")
        terminal.until(lambda: settled(terminal) and "keys here" not in terminal.text())
        terminal.send(b"\x1b[19~")  # Undocumented compatibility alias.
        terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: settled(terminal) and "keys here" not in terminal.text())
        terminal.send(b"M")
        terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
        terminal.gap(.7)
        require("Ctrl+D" in terminal.text(), "focused Dismiss button omitted its actual Ctrl shortcut")
        terminal.send(b"d")
        terminal.gap(.3)
        require(title in terminal.text(), "plain d dismissed the notification")
        terminal.send(b"\x04")
        terminal.until(lambda: settled(terminal) and title not in terminal.text())
        fixture.clock(fixture.noon + 6 * MINUTE)
        absent_for(terminal, [title], seconds=2.2)
        terminal.finish()
        fixture.untouched()
        return {"passiveCtrlDDoesNotDismiss": True, "plainDDoesNotDismiss": True,
                "focusedCtrlDDismisses": True, "buttonDocumentsShortcut": True,
                "mFocusToggle": True, "f8CompatibilityAlias": True,
                "shiftedMEncoding": True, "focusedLowercaseMConsumed": True,
                "literalMInMailSearch": True}
    finally:
        terminal.close()

def join_after_account_switch(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Personal meeting remains owned after Mail switches"
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], title, fixture.noon + 5 * MINUTE,
                                         fixture.noon + 35 * MINUTE,
                                         link="https://meet.example.test/personal-after-switch")]
    fixture.publish()
    terminal = fixture.start(account=ACCOUNTS[0])

    def selected_message(sequence):
        # A reminder covers the reader's bottom border. Bound its still-visible
        # header from the top border rather than requiring an intact full pane.
        header = frame_title(terminal.screen, "Message ·")
        if header is None:
            return False
        row = terminal.screen.cells[header["row"]]
        left = next(x for x in range(header["column"], -1, -1) if row[x] in {"╭", "┌", "╔"})
        right = next(x for x in range(header["column"], terminal.columns) if row[x] in {"╮", "┐", "╗"})
        lines = ["".join(terminal.screen.cells[y][left + 1:right]).strip()
                 for y in range(header["row"] + 1, header["row"] + 7)]
        return (settled(terminal) and lines[0] == "Planning version " + str(sequence)
                and "To: " + ACCOUNTS[1] in lines)

    try:
        wait_notice(terminal, title)
        require("keys here" not in terminal.text(), "arrival took keyboard focus before the account switch")
        terminal.send(b"2")
        terminal.until(lambda: selected_message(4))
        terminal.send(b"j")
        terminal.until(lambda: selected_message(5))
        wait_notice(terminal, title)
        require("keys here" not in terminal.text(), "passive reminder intercepted ordinary Mail navigation")
        terminal.send(b"M")
        terminal.gap(.7)
        terminal.send(b"o")
        terminal.until(lambda: settled(terminal) and "Join target validated" in terminal.text())
        require("Profile 3" in terminal.text() and "Profile 1" not in terminal.text(),
                "Join followed the newly selected Mail account instead of the reminder's account")
        require(selected_message(5),
                "Join changed the selected Mail account or message")
        terminal.send(b"\x1b")
        terminal.gap(.15)
        terminal.send(b"j")
        terminal.until(lambda: selected_message(6))
        terminal.finish()
        fixture.untouched()
        return {"meetingAccount": ACCOUNTS[0], "mailAccountAfterSwitch": ACCOUNTS[1],
                "profile": "Profile 3", "mailSelectionPreserved": True,
                "mailNavigationResumes": True, "fixtureSends": 0}
    finally:
        terminal.close()


def repeated_dismissal(binary, directory):
    """Held dismissal keys must neither dismiss another occurrence nor open Mail."""
    results = {}
    for label, key in (("Enter", b"\r"), ("Ctrl+D", b"\x04")):
        case_dir = directory / label.replace("+", "-")
        case_dir.mkdir()
        fixture = Fixture(binary, case_dir)
        names = ["Repeat alpha meeting", "Repeat beta meeting"]
        fixture.events[ACCOUNTS[0]] = [
            meeting(ACCOUNTS[0], title, fixture.noon + 5 * MINUTE,
                    fixture.noon + 35 * MINUTE, ident="repeat-" + str(index))
            for index, title in enumerate(names)]
        fixture.publish()
        terminal = fixture.start()
        try:
            terminal.until(lambda: settled(terminal) and "of 2" in terminal.text()
                           and any(name in terminal.text() for name in names))
            first = next(name for name in names if name in terminal.text())
            second = next(name for name in names if name != first)
            terminal.send(b"M")
            terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
            terminal.gap(.8)
            deadline = time.monotonic() + 1.8  # Sustained beyond both activation guards.
            while time.monotonic() < deadline:
                terminal.send(key)
                terminal.gap(.05)
            require(second in terminal.text(), label + " repeats dismissed the next meeting")
            require(first not in terminal.text(), label + " failed to dismiss the first meeting")
            require("keys here" not in terminal.text(), "next reminder inherited keyboard focus")
            require("j/k Mail" in terminal.text(), label + " repeats opened the selected email")
            # A deliberate new M permits the next action even while the trailing
            # repeat guard would otherwise still be active.
            terminal.send(b"M" + key)
            terminal.until(lambda: settled(terminal) and second not in terminal.text())
            fixture.clock(fixture.noon + 6 * MINUTE)
            absent_for(terminal, names, seconds=2.2)
            terminal.finish()
            fixture.untouched()
            results[label] = {"repeatStreamSeconds": 1.8, "onlyFirstDismissed": True,
                              "nextRequiresFreshFocus": True, "freshFocusImmediatelyWorks": True,
                              "noMailActivation": True}
        finally:
            terminal.close()
    return results



def join_preempts_refresh(binary, directory):
    fixture = Fixture(binary, directory)
    title = "Join while Mail refresh is held"
    fixture.events[ACCOUNTS[1]] = [meeting(ACCOUNTS[1], title, fixture.noon + 5 * MINUTE,
                                         fixture.noon + 35 * MINUTE)]
    fixture.publish()
    hold, entered = (fixture.mail.root / name for name in ("notice-refresh.hold", "notice-refresh.entered"))
    terminal = fixture.start()
    try:
        wait_notice(terminal, title)
        mail_path = fixture.mail.root / "accounts" / "personal.json"
        document = json.loads(mail_path.read_text())
        document["sync"].update(fixtureHold=hold.name, fixtureEntered=entered.name)
        hold.write_text("Synthetic Mail refresh remains held until Join cancels it.\n")
        atomic_json(mail_path, document)
        terminal.send(b"\x12")
        terminal.until(entered.exists)
        began = time.monotonic()
        terminal.send(b"M")
        terminal.gap(.7)
        terminal.send(b"o")
        terminal.until(lambda: settled(terminal) and "Join target validated" in terminal.text(), seconds=5)
        elapsed = time.monotonic() - began
        require(hold.is_file() and elapsed < 5,
                "urgent Join waited for the held Mail refresh")
        require("Profile 1" in terminal.text(), "preempted Join used the mailbox profile")
        with fixture.client() as client:
            require(not client.request("cache.refresh-status", ACCOUNTS[0])["refreshInProgress"],
                    "Join left the canceled Mail refresh active")
        hold.unlink()
        terminal.send(b"\x1b")
        terminal.finish()
        fixture.untouched()
        return {"readOnlyRefreshPreempted": True, "providerGateRemainedHeld": True,
                "profile": "Profile 1", "seconds": round(elapsed, 3)}
    finally:
        hold.unlink(missing_ok=True)
        terminal.close()


def url_policy(binary, directory):
    fixture = Fixture(binary, directory)
    names = ["Plain in-person appointment", "Insecure meeting URL", "Credentialed meeting URL"]
    urls = ["", "http://meet.example.test/unsafe", "https://user:pass@meet.example.test/unsafe"]
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], title, fixture.noon + 5 * MINUTE,
                                          fixture.noon + 35 * MINUTE, ident="url-" + str(index), link=url)
                                    for index, (title, url) in enumerate(zip(names, urls))]
    fixture.publish()
    terminal = fixture.start()
    try:
        remaining = set(names)
        while remaining:
            terminal.until(lambda: settled(terminal) and any(title in terminal.text() for title in remaining))
            title = next(title for title in remaining if title in terminal.text())
            require("[Join]" not in terminal.text() and "[o Join]" not in terminal.text(),
                    "unsafe or absent meeting URL advertised Join")
            # A dismissal may leave the next card explicitly focused.
            if "keys here" not in terminal.text():
                terminal.send(b"M")
            terminal.gap(.7)
            terminal.send(b"o")
            terminal.gap(.2)
            require("Join target validated" not in terminal.text(), "unsafe or absent meeting URL reached browser.open")
            terminal.send(b"\r")  # Dismiss remains the default focused control.
            terminal.until(lambda: settled(terminal) and title not in terminal.text())
            remaining.remove(title)
        terminal.finish()
        fixture.untouched()
        return {"inPerson": True, "httpRejected": True, "urlCredentialsRejected": True}
    finally:
        terminal.close()


def rescheduled_and_stale(binary, directory):
    fixture = Fixture(binary, directory)
    account = ACCOUNTS[0]
    title = "Rescheduled meeting"
    event = meeting(account, title, fixture.noon + 5 * MINUTE, fixture.noon + 35 * MINUTE)
    fixture.events[account] = [event]
    fixture.publish()
    terminal = fixture.start()
    try:
        wait_notice(terminal, title)
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and title not in terminal.text())
        event["value"].update(sequence=1, etag='"notice-fixture-2"')
        event["value"]["start"] = {"dateTime": instant(fixture.noon + 6 * MINUTE)}
        event["value"]["end"] = {"dateTime": instant(fixture.noon + 36 * MINUTE)}
        fixture.publish()
        fixture.clock(fixture.now + 2_000)
        wait_notice(terminal, title)
        # Failed refreshes retain a reminder already shown, and expose staleness.
        fixture.provider_paths[account].write_text('{"broken":')
        fixture.clock(fixture.now + 2_000)
        terminal.until(lambda: visible(terminal, title) and
                       re.search(r"stale|cached|saved", terminal.text(), re.I) is not None, seconds=12)
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and title not in terminal.text())
        event["value"].update(summary="Same occurrence renamed", sequence=2, etag='"notice-fixture-3"')
        fixture.publish()
        fixture.clock(fixture.now + 2_000)
        absent_for(terminal, [title, "Same occurrence renamed"], seconds=3.2)
        terminal.finish()
        fixture.untouched()
        return {"rescheduleRealerts": True, "metadataOnlyStaysDismissed": True,
                "failedRefreshRetainsActive": True, "stalenessVisible": True}
    finally:
        # Preserve a valid provider document even after a failed assertion.
        fixture.publish()
        terminal.close()


def recurring_occurrences(binary, directory):
    fixture = Fixture(binary, directory)
    account = ACCOUNTS[0]
    names = ["Series first occurrence", "Series second occurrence"]
    for index, title in enumerate(names):
        start = fixture.noon + (5 + index * 60) * MINUTE
        event = meeting(account, title, start, start + 30 * MINUTE,
                        ident="series-instance-" + str(index), uid="same-series@example.test")
        event["value"].update(recurringEventId="same-series", originalStartTime={"dateTime": instant(start)})
        fixture.events[account].append(event)
    fixture.publish()
    terminal = fixture.start()
    try:
        wait_notice(terminal, names[0])
        dismiss(terminal)
        terminal.until(lambda: settled(terminal) and names[0] not in terminal.text())
        fixture.clock(fixture.noon + 55 * MINUTE)
        wait_notice(terminal, names[1], 10)
        require(names[0] not in terminal.text(), "ended first recurrence returned with the second instance")
        terminal.finish()
        fixture.untouched()
        return {"sameSeriesAndUid": True, "originalStartDistinguishesOccurrences": True}
    finally:
        terminal.close()


def midnight_window(binary, directory):
    fixture = Fixture(binary, directory)
    midnight = (fixture.noon // 86_400_000 + 1) * 86_400_000
    title = "Meeting across midnight"
    fixture.clock(midnight - 6 * MINUTE)
    fixture.events[ACCOUNTS[0]] = [meeting(ACCOUNTS[0], title, midnight + 4 * MINUTE,
                                         midnight + 34 * MINUTE)]
    fixture.publish()
    terminal = fixture.start()
    try:
        wait_notice(terminal, title, 10)
        fixture.clock(midnight + 5 * MINUTE)
        wait_notice(terminal, title, 29, remaining=True)
        terminal.finish()
        fixture.untouched()
        return {"nextDayStartsWithinLead": True, "survivesCivilDateRollover": True}
    finally:
        terminal.close()


def vault_startup(binary, directory, owner_binary=None):
    """Exercise discovery and idle reminder timing through an unlocked owner."""
    from vault_daemon import PASSWORD, displayed_recovery, prompt

    owner_binary = owner_binary or binary
    environment = dict(os.environ)
    for key, leaf in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_CACHE_HOME", "cache-home"), ("XDG_RUNTIME_DIR", "runtime")):
        path = directory / leaf
        path.mkdir(mode=0o700)
        environment[key] = str(path)
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
        environment.pop(key, None)
    vault = directory / "vault"
    backend = directory / "ipc" / "socket"
    prompt(owner_binary, ["vault", "init", "--fixtures", "--vault-dir", str(vault)], environment,
           [(b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD),
            (b"Confirm recovery key: ", displayed_recovery)])
    daemon = subprocess.Popen([str(owner_binary), "vault", "serve", "--fixtures", "--vault-dir", str(vault),
                               "--socket", str(backend)], env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    terminal = None
    try:
        deadline = time.monotonic() + 12
        while not backend.exists():
            require(daemon.poll() is None, "owned fixture vault exited before binding")
            require(time.monotonic() < deadline, "owned fixture vault did not bind")
            time.sleep(.02)
        prompt(binary, ["vault", "unlock", "--socket", str(backend)], environment,
               [(b"Vault password: ", PASSWORD)])
        # The built-in synthetic provider seeds Project planning at 09:00 UTC.
        # Its preparation goes through the owner; no sealed object is edited.
        request = {"id": "notice-vault-seed", "cmd": "calendar.list", "account": ACCOUNTS[0]}
        seeded = subprocess.run([str(binary), "cli", "--backend", str(backend)],
                                env=environment, input=json.dumps(request).encode() + b"\n",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        require(seeded.returncode == 0 and json.loads(seeded.stdout)["ok"],
                "fixture owner could not seed its Calendar provider")
        clock_root = directory / "clock-fixture"
        clock_root.mkdir(mode=0o700)
        now = int(datetime.now(timezone.utc).replace(hour=8, minute=55, second=0,
                                                   microsecond=0).timestamp() * 1000)
        clock_path = clock_root / CLOCK_FILE

        def advance_clock(value):
            pending = clock_path.with_suffix(".pending")
            pending.write_text(str(value) + "\n")
            pending.chmod(0o600)
            pending.replace(clock_path)

        advance_clock(now)
        terminal_root = directory / "terminal"
        terminal = NotificationTerminal(binary, terminal_root,
                                 extra=("--backend", str(backend), "--fixture-root", str(clock_root),
                                        "--account", ACCOUNTS[0], "--prefetch-bodies", "0"),
                                 screen_type=ReaderScreen, columns=140, rows=40,
                                 environment={**environment, "TZ": "UTC", "NO_COLOR": None,
                                              "COLORTERM": "truecolor"})
        wait_notice(terminal, "Project planning", 5)
        require("Vault password:" not in terminal.text(), "unlocked owner prompted again inside TUI startup")
        # No input is sent: a remote client has no local cache-stamp callback,
        # but its idle timer must update countdowns, expire cards and poll again.
        advance_clock(now + 4 * MINUTE)
        wait_notice(terminal, "Project planning", 1)
        advance_clock(now + 5 * MINUTE)
        wait_notice(terminal, "Project planning", 60, remaining=True)
        advance_clock(now + 65 * MINUTE)
        terminal.until(lambda: settled(terminal) and "Project planning" not in terminal.text())
        absent_for(terminal, ["Project planning", "Team check-in"])
        # The same built-in provider has Team check-in at 14:00 UTC. Its lead
        # boundary is hours beyond startup and requires fresh background work.
        advance_clock(now + 295 * MINUTE)
        wait_notice(terminal, "Team check-in", 10)
        require("Project planning" not in terminal.text(), "expired owner-backed meeting returned")
        # The shared Terminal.finish helper opens a separate plaintext fixture
        # client. Verify this remote owner's sends and restore the TTY directly.
        terminal.process.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while terminal.process.poll() is None and time.monotonic() < deadline:
            terminal.pump()
        require(terminal.process.poll() == 0, "owner-backed TUI did not exit cleanly")
        require(termios.tcgetattr(terminal.slave) == terminal.settings,
                "owner-backed TUI did not restore terminal settings")
        stats_request = {"id": "notice-vault-stats", "cmd": "cache.stats", "account": ACCOUNTS[0]}
        stats_result = subprocess.run([str(binary), "cli", "--backend", str(backend)],
                                      env=environment, input=json.dumps(stats_request).encode() + b"\n",
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        require(stats_result.returncode == 0 and json.loads(stats_result.stdout)["data"]["fixtureSends"] == 0,
                "owner-backed notification sent mail")
        require(not list(terminal_root.rglob("calendar-agenda.json")),
                "owner-backed notification wrote a local plaintext Calendar snapshot")
        require(not list(terminal_root.rglob("index.json")),
                "owner-backed notification wrote a local plaintext Mail index")
        return {"unlockedOwner": True, "mailFirst": True, "noSecondPassword": True,
                "idleCountdown": True, "idleStart": True, "idleExpiry": True,
                "idleLaterLead": True, "noLocalPlaintextSnapshots": True,
                "ownerBuild": read_build_info(owner_binary)}
    finally:
        if terminal is not None:
            terminal.close()
        if daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)
        daemon.stdout.close()
        daemon.stderr.close()


class OwnedNotificationVault:
    """One private synthetic owner and TUI; no production service or credentials."""
    def __init__(self, binary, directory, minute):
        from vault_daemon import PASSWORD, displayed_recovery, prompt

        self.binary, self.directory = binary, directory
        self.environment = dict(os.environ)
        for key, leaf in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_CACHE_HOME", "cache-home"), ("XDG_RUNTIME_DIR", "runtime")):
            path = directory / leaf
            path.mkdir(mode=0o700)
            self.environment[key] = str(path)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
            self.environment.pop(key, None)
        self.vault = directory / "vault"
        self.backend = directory / "ipc" / "socket"
        self.clock_root = directory / "clock-fixture"
        self.clock_root.mkdir(mode=0o700)
        self.terminal_root = directory / "terminal"
        self.daemon = self.terminal = None
        self.serial = 0
        self.nine = int(datetime.now(timezone.utc).replace(hour=9, minute=0, second=0,
                                                          microsecond=0).timestamp() * 1000)
        self.clock(self.nine + minute * MINUTE)
        try:
            prompt(binary, ["vault", "init", "--fixtures", "--vault-dir", str(self.vault)], self.environment,
                   [(b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD),
                    (b"Confirm recovery key: ", displayed_recovery)])
            self.start_owner()
            self.unlock()
            # Seed only the owner's provider documents. Each new TUI must still
            # perform its own discovery; no notification state is preloaded.
            for account in ACCOUNTS:
                self.request("calendar.list", account)
        except BaseException:
            self.close()
            raise

    def clock(self, now):
        self.now = now
        path = self.clock_root / CLOCK_FILE
        pending = path.with_suffix(".pending")
        pending.write_text(str(now) + "\n")
        pending.chmod(0o600)
        pending.replace(path)

    def start_owner(self):
        require(self.daemon is None, "test attempted to overlap two vault owners")
        self.daemon = subprocess.Popen(
            [str(self.binary), "vault", "serve", "--fixtures", "--vault-dir", str(self.vault),
             "--socket", str(self.backend)], env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + 10
        while not self.backend.exists():
            require(self.daemon.poll() is None, "owned notification vault exited before binding")
            require(time.monotonic() < deadline, "owned notification vault did not bind")
            if self.terminal is None:
                time.sleep(.02)
            else:
                self.terminal.pump(.02)
        require(not self.control("status")["unlocked"], "restarted notification owner retained an old key")

    def stop_owner(self):
        require(self.daemon is not None, "test has no owned daemon to stop")
        self.daemon.terminate()
        deadline = time.monotonic() + 5
        while self.daemon.poll() is None and time.monotonic() < deadline:
            if self.terminal is None:
                time.sleep(.02)
            else:
                self.terminal.pump(.02)
        require(self.daemon.poll() == 0, "owned notification daemon did not stop cleanly within5s")
        self.daemon.stdout.close()
        self.daemon.stderr.close()
        self.daemon = None
        require(not self.backend.exists(), "stopped notification owner left its socket bound")

    def control(self, verb):
        result = subprocess.run([str(self.binary), "vault", verb, "--socket", str(self.backend)],
                                env=self.environment, capture_output=True, timeout=15)
        require(result.returncode == 0 and result.stdout.strip(), "owned vault control failed: " + verb)
        reply = json.loads(result.stdout)
        require(reply["ok"], "owned vault control refused: " + verb)
        return reply["data"]

    def unlock(self):
        from vault_daemon import PASSWORD, prompt
        prompt(self.binary, ["vault", "unlock", "--socket", str(self.backend)], self.environment,
               [(b"Vault password: ", PASSWORD)])
        require(self.control("status")["unlocked"], "owned notification vault did not unlock")

    def request(self, command, account=ACCOUNTS[0], ok=True, **fields):
        self.serial += 1
        raw = dict(id="notification-lifecycle-" + str(self.serial), cmd=command, account=account, **fields)
        result = subprocess.run([str(self.binary), "cli", "--backend", str(self.backend)],
                                env=self.environment, input=json.dumps(raw).encode() + b"\n",
                                capture_output=True, timeout=15)
        require(result.returncode == 0 and result.stdout.strip(), "owned notification RPC did not finish")
        reply = json.loads(result.stdout)
        require(reply.get("id") == raw["id"] and reply.get("account") == account,
                "owned notification RPC lost its exact account or correlation")
        if ok is None:
            return reply
        require(reply["ok"] == ok, command + " returned unexpected lifecycle success: " + str(reply.get("error")))
        return reply["data"] if ok else reply["error"]

    def start_terminal(self, account=ACCOUNTS[0]):
        self.terminal = NotificationTerminal(
            self.binary, self.terminal_root,
            extra=("--backend", str(self.backend), "--fixture-root", str(self.clock_root),
                   "--account", account, "--prefetch-bodies", "0"),
            screen_type=ReaderScreen, columns=140, rows=40,
            environment={**self.environment, "TZ": "UTC", "NO_COLOR": None, "COLORTERM": "truecolor"})
        self.terminal.until(lambda: settled(self.terminal) and "Mail ·" in self.terminal.text()
                            and "Up to date" in self.terminal.text(), seconds=15)
        return self.terminal

    def wait_body(self, expected, draft_id=None):
        from vault_tui_exit import authored_body
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            listed = self.request("draft.list", ok=None)
            if not listed["ok"]:
                require(listed["error"]["code"] == "VaultBusy", "unlocked draft lookup failed")
            else:
                drafts = listed["data"]["drafts"]
                require(len(drafts) == 1, "lifecycle workflow did not retain exactly one draft")
                if draft_id is not None:
                    require(drafts[0]["id"] == draft_id, "restart changed the authored draft identity")
                loaded = self.request("draft.read", draftId=drafts[0]["id"], ok=None)
                if loaded["ok"] and authored_body(loaded["data"]) == expected:
                    return loaded["data"]
                if not loaded["ok"]:
                    require(loaded["error"]["code"] == "VaultBusy", "unlocked draft read failed")
            self.terminal.pump(.1)
        raise AssertionError("exact authored draft did not persist within12s after owner recovery")

    def finish(self):
        self.terminal.process.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while self.terminal.process.poll() is None and time.monotonic() < deadline:
            self.terminal.pump()
        require(self.terminal.process.poll() == 0, "notification lifecycle TUI did not exit within5s")
        require(termios.tcgetattr(self.terminal.slave) == self.terminal.settings,
                "notification lifecycle TUI did not restore termios")
        for account in ACCOUNTS:
            require(self.request("cache.stats", account)["fixtureSends"] == 0,
                    "notification lifecycle sent synthetic mail")
            require(not self.request("operation.list", account)["operations"],
                    "notification lifecycle created a provider submission receipt")
        for name in ("index.json", "calendar-agenda.json", "ui.json"):
            require(not list(self.terminal_root.rglob(name)), "remote notification TUI wrote plaintext " + name)

    def close(self):
        if self.terminal is not None:
            self.terminal.close()
            self.terminal = None
        if self.daemon is not None:
            if self.daemon.poll() is None:
                self.daemon.terminate()
                try:
                    self.daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.daemon.kill()
                    self.daemon.wait(timeout=5)
            self.daemon.stdout.close()
            self.daemon.stderr.close()
            self.daemon = None


def notification_account(terminal):
    header = frame_title(terminal.screen, "Upcoming meeting") or frame_title(terminal.screen, "Meeting now")
    if header is None:
        return None
    # The fixed full-size card has its account on inner row4; neighboring
    # mailbox/account labels elsewhere on screen cannot satisfy this oracle.
    row = "".join(terminal.screen.cells[header["row"] + 5][header["column"] - 2:])
    return next((account for account in ACCOUNTS if account in row), None)


def observe_notification_accounts(terminal, title, accounts, selected=None):
    """Verify each card's account without assuming which agenda arrived first."""
    expected = set(accounts)
    deadline = time.monotonic() + 12

    def ready():
        header = frame_title(terminal.screen, "Upcoming meeting") or frame_title(terminal.screen, "Meeting now")
        return (settled(terminal) and header is not None and title in terminal.text()
                and re.search(r"\bof " + str(len(expected)) + r"\b",
                              "".join(terminal.screen.cells[header["row"]])) is not None)

    terminal.until(ready, seconds=max(0, deadline - time.monotonic()))
    observed = set()
    for _ in range(2 * len(expected)):
        current = notification_account(terminal)
        require(current in expected, "reminder card has an unexpected or missing account")
        observed.add(current)
        if observed == expected and (selected is None or current == selected):
            break
        # Respect the existing occurrence-change guard before one deliberate
        # Next click; discovery and the whole account cycle share the 12s limit.
        terminal.gap(.65)
        terminal.until(ready, seconds=max(0, deadline - time.monotonic()))
        require(time.monotonic() < deadline, "reminder account discovery exceeded 12s")
        click(terminal, *point(terminal, "Next"))
        terminal.until(lambda: ready() and notification_account(terminal) != current,
                       seconds=max(0, deadline - time.monotonic()))
    else:
        raise AssertionError("reminder cycle did not recover every account and requested selection")
    require(time.monotonic() < deadline, "reminder account discovery exceeded 12s")
    if "keys here" in terminal.text():
        terminal.send(b"\x1b")
        terminal.until(lambda: ready() and "keys here" not in terminal.text(),
                       seconds=max(0, deadline - time.monotonic()))
    return observed


def vault_lock_reminder(binary, directory):
    owner = OwnedNotificationVault(binary, directory, minute=-5)
    try:
        terminal = owner.start_terminal(account=ACCOUNTS[1])
        wait_notice(terminal, "Project planning", 5)
        observe_notification_accounts(terminal, "Project planning", ACCOUNTS, selected=ACCOUNTS[0])
        terminal.send(b"M")
        terminal.until(lambda: settled(terminal) and "keys here" in terminal.text())
        terminal.gap(.7)
        began = time.monotonic()
        owner.control("lock")
        lock_seconds = time.monotonic() - began
        require(lock_seconds < 4 and not owner.control("status")["unlocked"],
                "locking the notification owner did not finish within4s")
        require(owner.request("calendar.list", ok=False)["code"] == "VaultLocked",
                "locked owner served new Calendar data")
        owner.clock(owner.nine - MINUTE)
        wait_notice(terminal, "Project planning", 1)
        terminal.until(lambda: settled(terminal) and "Saved details" in terminal.text(), seconds=12)
        terminal.send(b"o")
        terminal.until(lambda: settled(terminal) and "Could not open meeting" in terminal.text())
        require("Join target validated" not in terminal.text()
                and notification_account(terminal) == ACCOUNTS[0],
                "locked Join opened or retargeted the focused account")
        owner.unlock()
        terminal.send(b"o")
        terminal.until(lambda: settled(terminal) and "Join target validated" in terminal.text())
        require("Profile 3" in terminal.text() and "Profile 1" not in terminal.text(),
                "unlocked Join used the selected Mail account instead of the reminder account")
        # A new later event requires fresh agenda work after the lock. Keep
        # ordinary12s acceptance; never advance scheduler deadlines by ten minutes.
        owner.clock(owner.nine + 290 * MINUTE)
        terminal.until(lambda: settled(terminal) and "Meeting ended or changed" in terminal.text())
        terminal.send(b"\x1b")
        wait_notice(terminal, "Team check-in", 10)
        require("Vault password:" not in terminal.text(), "owner recovery injected a password prompt into Mail")
        owner.finish()
        return {"lockSeconds": round(lock_seconds, 3), "focusedJoinRefusedWhileLocked": True,
                "unlockedJoinProfile": "Profile 3", "mailAccount": ACCOUNTS[1],
                "freshLaterAgendaRecovered": True, "noPlaintextSnapshots": True, "fixtureSends": 0}
    finally:
        owner.close()


def vault_restart_compose(binary, directory):
    from vault_tui_exit import authored_body

    owner = OwnedNotificationVault(binary, directory, minute=-11)
    try:
        terminal = owner.start_terminal()
        # Enter compose before waiting for any reminder discovery to finish.
        # Partial startup discovery must recover too, rather than waiting10min.
        open_composer(terminal)
        initial = "Owned draft before daemon restart"
        terminal.send(b"\t\t\t\ti" + initial.encode())
        terminal.until(lambda: settled(terminal) and initial in terminal.text())
        terminal.send(b"\x1b")
        retained = owner.wait_body(initial)
        owner.stop_owner()
        stopped_suffix = "\nTyped with owner stopped: M o d café"
        terminal.send(b"i\x05\r" + stopped_suffix[1:].encode())
        terminal.until(lambda: settled(terminal) and "Typed with owner stopped" in terminal.text())
        owner.start_owner()
        require(owner.request("accounts.list", ok=False)["code"] == "VaultLocked",
                "restarted owner exposed data before explicit unlock")
        locked_suffix = "\nTyped while restarted owner locked: M o d 世界"
        terminal.send(b"\r" + locked_suffix[1:].encode())
        terminal.until(lambda: settled(terminal) and "Typed while restarted owner locked" in terminal.text())
        owner.clock(owner.nine - 5 * MINUTE)
        absent_for(terminal, ["Project planning", "Upcoming meeting", "keys here"], seconds=2.2)
        owner.unlock()
        expected = initial + stopped_suffix + locked_suffix
        restored = owner.wait_body(expected, retained["id"])
        require(restored["id"] == retained["id"], "owner reconnect created a replacement draft")
        terminal.send(b"\x1b")
        terminal.gap(.3)
        terminal.send(b"q")
        terminal.until(lambda: settled(terminal) and "Compose" not in terminal.text() and "Mail ·" in terminal.text())
        wait_notice(terminal, "Project planning", 5)
        observe_notification_accounts(terminal, "Project planning", ACCOUNTS)
        require("Vault password:" not in terminal.text(), "restarted owner prompted inside the composer")
        owner.finish()
        require(authored_body(owner.request("draft.read", draftId=retained["id"])) == expected,
                "clean exit lost the draft recovered after daemon restart")
        return {"ownerRestartedLocked": True, "typedWhileStoppedAndLocked": True,
                "exactUnicodeDraftRetained": True, "draftIdentityRetained": True,
                "allThreeAccountsRecoveredWithin12s": True, "noPlaintextSnapshots": True, "fixtureSends": 0}
    finally:
        owner.close()


CASES = {
    "mail-startup-clock": startup_and_clock,
    "dismiss-overlap": dismiss_and_overlap,
    "accounts-calendars": accounts_and_calendars,
    "account-permissions": account_permissions,
    "excluded-events": excluded_events,
    "calendar-view-preserved": calendar_view_preserved,
    "focused-expiry": focused_expiry,
    "focused-provider-changes": focused_provider_changes,
    "compose-input": compose_input,
    "review-countdown-arrival": review_countdown_arrival,
    "offline-cached": offline_cached,
    "editor-handoff": editor_handoff,
    "join-routing": join_routing,
    "join-account-switch": join_after_account_switch,
    "keyboard-dismiss": keyboard_dismiss,
    "repeated-dismissal": repeated_dismissal,
    "join-preempts-refresh": join_preempts_refresh,
    "url-policy": url_policy,
    "reschedule-stale": rescheduled_and_stale,
    "recurring-occurrences": recurring_occurrences,
    "midnight-window": midnight_window,
    "vault-startup": vault_startup,
    "vault-lock-reminder": vault_lock_reminder,
    "vault-restart-compose": vault_restart_compose,
    "old-vault-startup": None,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--old-daemon-binary", type=Path,
                        help="Earlier Calendar-capable owner for old-vault-startup")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "syntheticOnly": True, "cases": []}
    try:
        selected = args.case or [name for name in CASES
                                 if name != "old-vault-startup" or args.old_daemon_binary]
        for name in selected:
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-calendar-notice-") as temporary:
                    if name == "old-vault-startup":
                        require(args.old_daemon_binary is not None,
                                "old-vault-startup requires --old-daemon-binary")
                        details = vault_startup(binary, Path(temporary), args.old_daemon_binary.resolve())
                    else:
                        details = CASES[name](binary, Path(temporary))
                receipt["cases"].append({"name": name, "status": "passed", **details})
                print("PASS Calendar notifications:", name, flush=True)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
