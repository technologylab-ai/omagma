#!/usr/bin/env python3
"""Expired Calendar reviews recover in the TUI without invented unknown writes.

Owned PTYs and isolated synthetic provider files only. Run under the shared
host reservation; no production accounts, credentials or desktop interaction.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import sys
import tempfile
import traceback

from build_info import read_build_info
from terminal_calendar import Invitations, confirmation
from terminal_calendar_tui import capture, plan, provider_counts, start
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import click, point


def document(directory, name):
    matches = []
    for path in (directory / "cache").rglob(name):
        value = json.loads(path.read_text())
        if value.get("account") == ACCOUNTS[0]:
            matches.append((path, value))
    require(len(matches) == 1, f"synthetic {name} account storage is ambiguous")
    return matches[0]


def replace_fixture(path, value):
    replacement = path.with_name(path.name + ".review-test")
    replacement.write_text(json.dumps(value) + "\n")
    replacement.chmod(0o600)
    replacement.replace(path)


def reviewed(terminal, directory):
    click(terminal, *point(terminal, "[Enter Review]"))
    terminal.until(lambda: "[y Confirm]" in terminal.text())
    terminal.send(b"\x04" * 4)
    terminal.gap(.15)
    _, saved = document(directory, "calendar-state.json")
    matching = [entry for entry in saved["entries"]
                if entry["identity"]["uid"] == "cli-planning@example.test"]
    require(len(matching) == 1, "review identity missing or duplicated")
    return matching[0]["review"]["intent"]["operation_id"]


def assert_no_submission(binary, directory, fixture, expected_writes, rejected_review):
    provider_counts(binary, directory, fixture, expected_writes)
    _, saved = document(directory, "calendar-state.json")
    for entry in saved["entries"]:
        operation = entry.get("state", {}).get("operation")
        if operation:
            require(operation["state"] != "unknown", "stale review invented an unknown journal claim")
            require(operation["intent"]["operation_id"] != rejected_review,
                    "stale review acquired a submission claim")


def scenario(binary, directory, captures, updating):
    fixture = Invitations(directory)
    client_dir = directory / "client"
    imported_id = None
    if updating:
        with Client(binary, client_dir, extra=fixture.options()) as client:
            initial = client.request("calendar.review", calendarId=ACCOUNTS[0],
                                     messageId="calendar-mail-4", operationId="prepare-update-fixture")
            applied = client.request("calendar.apply", **confirmation(initial))
            require(applied["state"] == "applied", "initial synthetic import failed")
            imported_id = applied["providerId"]
    terminal = start(binary, client_dir, fixture)
    try:
        plan(terminal, 5 if updating else 4, "review_update" if updating else "import_missing")
        stale_id = reviewed(terminal, client_dir)
        path, state = document(client_dir, "calendar-provider-fixture.json")
        if updating:
            events = [entry["value"] for entry in state["events"]
                      if entry["calendar_id"] == ACCOUNTS[0] and entry["value"]["id"] == imported_id]
            require(len(events) == 1, "imported fixture event missing")
            # A calendar client edits this event after the TUI's exact review.
            events[0]["etag"] = '"external-edit-after-review"'
            events[0]["summary"] = "Edited in another calendar client"
        else:
            # The same invitation arrives in the destination through another
            # client after lookup/review, before this TUI receives consent.
            event = copy.deepcopy(state["events"][0])
            event["calendar_id"] = ACCOUNTS[0]
            event["value"].update(id="external-copy-before-confirmation",
                                   iCalUID="cli-planning@example.test", sequence=4,
                                   summary="Already added elsewhere", etag='"external-existing"',
                                   organizer={"email": "host@example.test"})
            event["value"].pop("recurrence", None)
            state["events"].append(event)
        replace_fixture(path, state)
        terminal.send(b"y")
        terminal.until(lambda: "Review no longer valid" in terminal.text() and
                       "[Enter Review]" in terminal.text())
        require("[r Check Calendar]" not in terminal.text() and "Outcome unknown" not in terminal.text(),
                "a refusal before submission was presented as an unknown write")
        require("[y Confirm]" not in terminal.text(), "obsolete consent remained active")
        assert_no_submission(binary, client_dir, fixture, int(updating), stale_id)
        capture(terminal, captures, "calendar-stale-update" if updating else "calendar-stale-import")
        terminal.send(b"ry")
        terminal.gap(.1)
        require("[Enter Review]" in terminal.text(), "stale review accepted old Confirm or reconciliation input")
        # Enter obtains a new plan. A further explicit review and confirmation
        # are necessary when an update remains appropriate.
        terminal.send(b"\r")
        if updating:
            terminal.until(lambda: "Review the proposed Calendar action" in terminal.text() and
                           "Action: Apply organizer's update" in terminal.text())
            fresh_id = reviewed(terminal, client_dir)
            require(fresh_id != stale_id, "fresh review reused the expired operation identity")
            terminal.send(b"y")
            terminal.until(lambda: "Calendar action applied" in terminal.text())
            provider_counts(binary, client_dir, fixture, 2)
        else:
            terminal.until(lambda: "Action: Already in this calendar" in terminal.text())
            assert_no_submission(binary, client_dir, fixture, 0, stale_id)
        capture(terminal, captures, "calendar-stale-update-recovered" if updating else "calendar-stale-import-existing")
        terminal.finish()
        return {"staleReviewClaimed": False, "inventedUnknown": False,
                "freshPlan": True, "freshReviewedUpdate": updating, "writes": 2 if updating else 0}
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
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    try:
        for updating in (False, True):
            name = "stale-update" if updating else "stale-import"
            try:
                with tempfile.TemporaryDirectory(prefix="omagma-calendar-stale-") as tmp:
                    result = scenario(binary, Path(tmp), args.capture_dir, updating)
                receipt["cases"].append({"name": name, "status": "passed", **result})
                print("PASS Calendar review recovery:", name, flush=True)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                raise
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
