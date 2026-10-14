#!/usr/bin/env python3
"""Calendar acceptance through the actual CLI, with isolated synthetic providers.

Run under the cooperative host reservation. No credentials, browser, or real
Calendar service are used. Reopen the process at write boundaries to exercise
the durable review/outcome contract used by agents and the TUI.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import traceback

from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, require


COMMANDS = ("list", "agenda", "event", "freebusy", "invitation-plan", "review",
            "apply", "import", "update", "cancel", "reconcile")


class Invitations:
    def __init__(self, directory):
        self.root = directory / "provider"
        (self.root / "accounts").mkdir(parents=True, mode=0o700)
        for account in ACCOUNTS:
            messages = [self.message(account, sequence, sequence == 6) for sequence in (4, 5, 6)]
            content = {"account": account, "generation": 500,
                       "sync": {"historyId": "500", "history": []}, "messages": messages}
            (self.root / "accounts" / (account.split("@")[0] + ".json")).write_text(json.dumps(content) + "\n")

    @staticmethod
    def message(account, sequence, cancel):
        source = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:" + ("CANCEL" if cancel else "REQUEST") + "\r\n"
                  "BEGIN:VEVENT\r\nUID:cli-planning@example.test\r\nDTSTAMP:20261013T080000Z\r\n"
                  f"SEQUENCE:{sequence}\r\nORGANIZER:mailto:host@example.test\r\nATTENDEE:mailto:{account}\r\n"
                  "DTSTART:20261025T090000Z\r\nDTEND:20261025T100000Z\r\n"
                  f"SUMMARY:Planning version {sequence}\r\nLOCATION:Studio\r\n"
                  "CONFERENCE:https://meet.example.test/planning\r\n" +
                  ("STATUS:CANCELLED\r\n" if cancel else "") + "END:VEVENT\r\nEND:VCALENDAR\r\n")

        def part(kind, raw, filename="", index="0"):
            data = raw.encode()
            return {"partId": index, "mimeType": kind, "filename": filename,
                    "headers": [{"name": "Content-Type", "value": kind + "; charset=utf-8"}],
                    "body": {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}}

        return {"id": f"calendar-mail-{sequence}", "threadId": "calendar-thread", "internalDate": "1791885600000",
                "historyId": "500", "labelIds": ["INBOX"], "snippet": f"Planning version {sequence}",
                "sizeEstimate": len(source) + 500,
                "payload": {"partId": "", "mimeType": "multipart/mixed", "filename": "",
                            "body": {"size": 0}, "headers": [
                                {"name": "From", "value": "Host <host@example.test>"},
                                {"name": "To", "value": account},
                                {"name": "Subject", "value": f"Planning version {sequence}"},
                                {"name": "Message-ID", "value": f"<calendar-mail-{sequence}@example.test>"}],
                            "parts": [part("text/plain", "Please join the planning meeting.\n"),
                                      part("text/calendar", source, "invite.ics", "1")]}}

    def options(self):
        return ("--fixture-root", str(self.root), "--prefetch-bodies", "0")


def provider_state(client, account=ACCOUNTS[0]):
    matches = []
    for path in (client.directory / "cache").rglob("calendar-provider-fixture.json"):
        value = json.loads(path.read_text())
        if value["account"] == account:
            require(stat.S_IMODE(path.stat().st_mode) == 0o600, "calendar fixture storage is not private")
            matches.append(value)
    require(len(matches) == 1, "calendar fixture account storage missing or duplicated")
    return matches[0]


def confirmation(reviewed, calendar_id=ACCOUNTS[0]):
    return {"calendarId": calendar_id, "operationId": reviewed["operationId"], "reviewHash": reviewed["reviewHash"]}


def reads(binary, directory):
    fixture = Invitations(directory)
    today = datetime.now(timezone.utc).date().isoformat()
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        for account in ACCOUNTS:
            listed = client.request("calendar.list", account)
            require(listed["complete"] and len(listed["calendars"]) == 3, "calendar picker lost calendars/completeness")
            own, shared, readonly = listed["calendars"]
            require(own["calendar"]["target"]["account"] == account and own["canWrite"], "calendar owner/account routing failed")
            require(shared["canWrite"] and not shared["calendar"]["owned_scope_verified"], "shared calendar confused ACL owner with data ownership")
            require(readonly["canRead"] and not readonly["canWrite"], "read-only calendar advertised write access")
            for view in ("day", "week"):
                data = client.request("calendar.agenda", account, calendarId=account, date=today, view=view)
                snap = data["snapshot"]
                require(snap["complete"] and not snap["stale"], "fresh agenda marked partial/stale")
                require(len(snap["events"]) == (2 if view == "day" else 8), "agenda lost planning/recurring instances")
                require(snap["target"]["account"] == account, "agenda crossed accounts")
            holiday = client.request("calendar.agenda", account, calendarId="fixture-readonly", date=today)["snapshot"]["events"][0]
            require(holiday["start"]["kind"] == holiday["end"]["kind"] == "date", "all-day event became a timezone-dependent instant")
            for date, hours in (("2026-03-29", 23), ("2026-10-25", 25)):
                window = client.request("calendar.agenda", account, calendarId=account, date=date, timeZone="Europe/Vienna")["snapshot"]["window"]
                require(window["end_ms"] - window["start_ms"] == hours * 3600000, "civil day flattened across daylight saving")
            busy = client.request("calendar.freebusy", account, calendarId=account, date=today)
            require(busy["complete"] and len(busy["ranges"]) == 2, "availability omitted events")
        client.restart()
        detail = client.request("calendar.event", calendarId=ACCOUNTS[0], eventId="fixture-planning")["event"]
        require(detail["id"] == "fixture-planning", "event details did not survive process restart")
        require(provider_state(client)["writes"] == 0, "calendar browsing performed a mutation")
        require(client.request("cache.stats")["fixtureSends"] == 0, "calendar browsing sent mail")
    return {"accounts": 3, "dstDays": [23, 25], "views": ["day", "week"], "writes": 0}


def lifecycle(binary, directory, lost=False):
    fixture = Invitations(directory)
    with Client(binary, directory / "client", scenario="calendar-lost-response" if lost else None,
                extra=fixture.options()) as client:
        imported_id = None
        for index, verb in enumerate(("import", "update", "cancel")):
            message_id = f"calendar-mail-{index + 4}"
            reviewed = client.request("calendar.review", calendarId=ACCOUNTS[0], messageId=message_id, operationId=f"planning-{verb}")
            require(reviewed["action"] == verb + "_event" and len(reviewed["reviewHash"]) == 64,
                    "review selected the wrong action or omitted its exact confirmation")
            require(provider_state(client)["writes"] == index, "review changed the calendar")
            params = confirmation(reviewed)
            client.restart()
            wrong_hash = {**params, "reviewHash": "0" * 64}
            client.request("calendar.apply", ok=False, **wrong_hash)
            client.request("calendar.apply", ok=False, **params, source="untrusted replacement")
            client.request("calendar.apply", ACCOUNTS[1], ok=False, **confirmation(reviewed, ACCOUNTS[1]))
            require(provider_state(client)["writes"] == index, "invalid confirmation changed the provider")
            result = client.request("calendar." + verb, **params)
            require(result["state"] == ("unknown" if lost else "applied"), "mutation outcome omitted uncertainty")
            client.restart()
            if lost:
                result = client.request("calendar.reconcile", **params)
                require(result["state"] == "applied" and result["reconciled"], "committed lost response was not reconciled")
            replay = client.request("calendar.apply", **params)
            require(replay["state"] == "applied", "idempotent replay did not retain receipt")
            state = provider_state(client)
            require(state["writes"] == index + 1, "calendar action was repeated after restart")
            if imported_id is None:
                imported_id = result["providerId"]
            require(result["providerId"] == imported_id, "update/cancel created a different event")
            detail = client.request("calendar.event", calendarId=ACCOUNTS[0], eventId=imported_id)["event"]
            require(detail["cancelled"] == (verb == "cancel"), "calendar cancellation state is incorrect")
            if verb != "cancel":
                require(detail["summary"] == f"Planning version {index + 4}", "updated invitation content lost")
        require(client.request("cache.stats")["fixtureSends"] == 0, "adding invitation unexpectedly sent an RSVP email")
        client.request("calendar.review", ok=False, calendarId=ACCOUNTS[0], messageId="calendar-mail-4", operationId="stale-source")
        require(provider_state(client)["writes"] == 3, "older invitation resurrected a cancelled event")
    return {"mutations": 3, "restarts": 6, "lostResponses": lost, "duplicateWrites": 0}


def guards(binary, directory):
    fixture = Invitations(directory)
    with Client(binary, directory / "client", scenario="calendar-readonly", extra=fixture.options()) as client:
        listed = client.request("calendar.list")
        require(all(not item["canWrite"] for item in listed["calendars"]), "read-only grant still advertises writes")
        client.request("calendar.review", ok=False, calendarId=ACCOUNTS[0], messageId="calendar-mail-4", operationId="readonly")
        require(provider_state(client)["writes"] == 0, "read-only permission changed provider")
        client.request("calendar.agenda", ok=False, calendarId=ACCOUNTS[0], date="2026-02-30")
        client.request("calendar.agenda", ok=False, calendarId=ACCOUNTS[0], date="2026-10-13", timeZone="../../etc/passwd")
        client.request("calendar.event", ok=False, calendarId="absent-calendar", eventId="fixture-planning")
    return {"readOnly": True, "invalidDatesAndZones": True}


def offline(binary, directory):
    fixture = Invitations(directory)
    today = datetime.now(timezone.utc).date().isoformat()
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        missing = client.request("calendar.list", cacheOnly=True, ok=False)
        require(missing["code"] == "CalendarNotCached", "empty offline calendar pretended to be an empty provider list")
        live = client.request("calendar.agenda", calendarId=ACCOUNTS[0], date=today, view="week")

        def files():
            return {str(p.relative_to(client.directory / "cache")): p.read_bytes()
                    for p in (client.directory / "cache").rglob("*") if p.is_file()}

        before = files()
        client.restart()
        for automatic in (False, True):
            if automatic:
                client.scenario = "calendar-offline"
                client.restart()
            options = {} if automatic else {"cacheOnly": True}
            listed = client.request("calendar.list", **options)
            require(listed["cached"] and listed["stale"] and not any(item["canWrite"] for item in listed["calendars"]),
                    "cached ACLs advertised permission to mutate calendars")
            data = client.request("calendar.agenda", calendarId=ACCOUNTS[0], date=today, view="week", **options)
            require(data["cached"] and data["snapshot"]["stale"] and data["snapshot"]["events"] == live["snapshot"]["events"],
                    "offline refresh erased or altered retained events")
            require(bool(data["refreshError"]) == automatic, "offline outcome hid connection failure")
            detail = client.request("calendar.event", calendarId=ACCOUNTS[0], eventId="fixture-planning", **options)
            require(detail["cached"] and detail["stale"], "cached event masqueraded as fresh provider detail")
        require(files() == before, "offline browsing mutated the account store")
        client.request("calendar.freebusy", calendarId=ACCOUNTS[0], date=today, cacheOnly=True, ok=False)
        client.request("calendar.review", calendarId=ACCOUNTS[0], messageId="calendar-mail-4", operationId="offline-review", cacheOnly=True, ok=False)
        require(files() == before, "cache-only rejected command read mail or modified storage")
        client.request("calendar.agenda", calendarId=ACCOUNTS[1], date=today, cacheOnly=True, ok=False)
        require(provider_state(client)["writes"] == 0, "offline fallback sent a provider write")
    return {"explicitCacheOnly": True, "connectionFailureFallback": True, "writes": 0, "staleVisible": True}


def discoverability(binary, directory):
    with Client(binary, directory / "client") as client:
        def run(*args):
            result = subprocess.run([str(binary), *args], cwd=directory, env=client.environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
            require(result.returncode == 0, f"calendar CLI command failed: {args!r}: {result.stderr[:500]!r}")
            return result.stdout.decode()

        family = run("calendar", "--help")
        catalogue = run("cli", "--help", "calendar")
        for command in COMMANDS:
            require(command in family and "calendar." + command in catalogue, "calendar command is not discoverable")
            detail = run("cli", "--help", "calendar." + command)
            require("account" in detail, "command help omitted account field")
            schema = json.loads(run("cli", "--schema", "calendar." + command))
            require(schema, "calendar request schema is empty")
        once = json.loads(run("calendar", "list", "--fixtures", "--cache-dir", str(directory / "oneshot-cache"),
                              "--account", ACCOUNTS[0]))
        require(once.get("ok") and len(once["data"]["calendars"]) == 3, "one-shot calendar command not routed to shared host")
    return {"commands": len(COMMANDS), "jsonlAndShell": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    tasks = [("reads", reads), ("lifecycle", lifecycle), ("lost-response", lambda b, d: lifecycle(b, d, True)),
             ("guards", guards), ("offline", offline), ("discoverability", discoverability)]
    try:
        for name, task in tasks:
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-calendar-" + name + "-") as temporary:
                    result = task(binary, Path(temporary))
                receipt["cases"].append({"name": name, "status": "passed", **result})
                print("PASS calendar CLI:", name, flush=True)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
