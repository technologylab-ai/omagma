#!/usr/bin/env python3
"""New sender/completion/undo/reminder/countdown workflows in owned fixtures.

Provider submission is permitted only to the mock fixture and is asserted
exactly once in the explicit-due case. Never uses a desktop or live mailbox.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
import shutil

from terminal_composer_workflow import setup
from terminal_integration import ACCOUNTS, FIXTURES, ROOT, Client, require
from terminal_pty import wait_saved_compose
from terminal_ux_batch_support import (TAB, ENTER, ESC, activate_button, capture,
    command, compose, diagnose, focused, focus_button, no_writes, read_draft, run_cases,
    start, stats)


def beginning(body):
    return body["bodyText"].splitlines()[0]


def named_contact_setup(binary, directory, display_name):
    # Seed the provider source before any contacts/recipient cache is created.
    # Patching after composer_setup would leave its ready cached name intact.
    fixture = directory / "fixture"
    shutil.copytree(FIXTURES, fixture, ignore=shutil.ignore_patterns("__pycache__"))
    contacts_file = fixture / "contacts/personal.json"
    contacts = json.loads(contacts_file.read_text())
    contacts["connections"][0]["names"][0]["displayName"] = display_name
    contacts_file.write_text(json.dumps(contacts))
    account_file = fixture / "accounts/personal.json"
    account = json.loads(account_file.read_text())
    account["identities"] = [
        {"address": ACCOUNTS[0], "name": "Configured Primary", "signature": "Primary fixture signature", "isDefault": True},
        {"address": "alias@example.test", "name": "Fictional Alias", "signature": "Alias fixture signature", "isDefault": False}]
    account_file.write_text(json.dumps(account))
    configuration = json.loads((ROOT / "tests/fixtures/all-accounts.json").read_text())
    configuration["accounts"][0].update(senderName="Configured Primary", signature="Primary fixture signature")
    config_file = directory / "synthetic-config.json"
    config_file.write_text(json.dumps(configuration))
    config_file.chmod(0o600)
    extra = ("--fixture-root", str(fixture), "--config", str(config_file))
    with Client(binary, directory, extra=extra) as client:
        client.request("mail.list", limit=32)
        body = client.request("mail.read", messageId="shared-msg-096")
        client.request("contacts.list")
        recipients = client.request("mail.recipients", cacheOnly=True)["recipients"]
        require(any(value["address"] == "alex-personal@example.org" and value["name"] == display_name for value in recipients),
                "named-contact fixture did not reach the fresh recipient cache")
        client.request("accounts.identities")
    return extra, body


def send_review(terminal):
    terminal.send(b"\x13")
    terminal.until(lambda: "Review send" in terminal.text() and "[Back]" in terminal.text())


def countdown_active(terminal):
    return ("[Undo" in terminal.text() and
            re.search(r"(?i)(send(?:ing)?\s+(?:in|queued)|queued\s+send)", terminal.text()) is not None)


def queue_entries(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        return client.request("queue.list")["queue"]


def sender_completion_undo(binary, directory, capture_dir=None):
    display_name = 'Lee, "Jordan"'
    extra, body = named_contact_setup(binary, directory, display_name)
    terminal = start(binary, directory, extra, beginning(body))
    try:
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "Attachments 0" in terminal.text())
        terminal.send(b"ialex-p")
        terminal.until(lambda: "Recipients" in terminal.text() and "alex-personal@example.org" in terminal.text())
        terminal.send(ENTER)
        formatted = json.dumps(display_name) + " <alex-personal@example.org>"
        terminal.until(lambda: formatted in terminal.text())
        terminal.send(TAB * 3 + b"Completion and undo fixture" + TAB + b"Base note." + ESC)
        terminal.gap(.08)
        command(terminal, "sender")
        terminal.until(lambda: "sender" in terminal.text().lower() and "alias@example.test" in terminal.text())
        capture(terminal, capture_dir, "ux-sender-chooser")
        terminal.send(b"\x0e")  # Ctrl+N chooses the alias; Filter j stays data.
        activate_button(terminal, "[Use]")
        terminal.until(lambda: "From: alias@example.test" in terminal.text() and "Subject:" in terminal.text())
        # Paste is one observable edit. Undo/redo changes only the note and
        # keeps addressing/sender/original/attachments intact.
        terminal.send(b"i\x1b[200~\nAppended fixture text.\x1b[201~")
        terminal.until(lambda: "Appended fixture text." in terminal.text())
        terminal.send(b"\x1a")
        terminal.until(lambda: "Appended fixture text." not in terminal.text() and "Base note." in terminal.text())
        terminal.send(b"\x19")
        terminal.until(lambda: "Appended fixture text." in terminal.text())
        terminal.send(ESC)
        terminal.gap(.08)
        send_review(terminal)
        retained = read_draft(binary, directory, extra)
        require(retained["to"][0]["address"] == "alex-personal@example.org"
                and retained["to"][0]["name"] == display_name,
                "completion lost the contact's display name or chosen address")
        require(retained["from"]["address"] == "alias@example.test", "sender chooser changed the wrong identity")
        require("Base note.\nAppended fixture text." in retained["bodyText"],
                "compose undo/redo lost or changed pasted note text")
        terminal.send(ENTER)  # Review's initially focused Back is safe.
        terminal.until(lambda: "Review send" not in terminal.text() and "Subject:" in terminal.text())
        no_writes(binary, directory, extra)
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def attachment_reminder(binary, directory, capture_dir=None):
    extra, body = setup(binary, directory)
    terminal = start(binary, directory, extra, beginning(body))
    try:
        compose(terminal, subject="Attachment reminder fixture", body="Please see the attached document.")
        terminal.send(b"\x13")
        warning = "Your note mentions an attachment; no files are attached."
        terminal.until(lambda: "Review send" in terminal.text() and warning in terminal.text()
                       and "[y Send]" in terminal.text() and focused(terminal, "[Back]"))
        capture(terminal, capture_dir, "ux-attachment-reminder")
        focus_button(terminal, "[y Send]")  # Advisory is explicitly overrideable.
        focus_button(terminal, "[Back]", backwards=True)
        terminal.send(ENTER)
        terminal.until(lambda: "Review send" not in terminal.text() and "Subject:" in terminal.text())
        no_writes(binary, directory, extra)
        path = directory / "report.txt"
        path.write_text("Fictional attachment reminder evidence.\n")
        terminal.send(b"A")
        terminal.until(lambda: "Path:" in terminal.text() and "[Attach]" in terminal.text())
        terminal.send(b"\x15" + str(path).encode() + ENTER)
        terminal.until(lambda: "Attachments 1" in terminal.text() and "report.txt" in terminal.text())
        wait_saved_compose(terminal, 1)
        send_review(terminal)
        retained = read_draft(binary, directory, extra)
        require([a["filename"] for a in retained["attachments"]] == [path.name],
                "reminder attach path did not retain the chosen file")
        require(warning not in terminal.text(), "attachment warning repeated after a file was added")
        terminal.send(ENTER)
        no_writes(binary, directory, extra)
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def countdown_cancel(binary, directory, capture_dir=None):
    extra, body = setup(binary, directory)
    terminal = start(binary, directory, extra, beginning(body))  # default10s
    try:
        compose(terminal, subject="Cancel countdown fixture")
        send_review(terminal)
        activate_button(terminal, "[y Send]")
        terminal.until(lambda: countdown_active(terminal))
        require("Subject:" in terminal.text() and "Cancel countdown fixture" in terminal.text(),
                "countdown replaced the editing context with a blocking review")
        require(stats(binary, directory, extra)["fixtureSends"] == 0,
                "review confirmation submitted before the countdown elapsed")
        queued = queue_entries(binary, directory, extra)
        require(len(queued) == 1 and queued[0]["state"] == "queued"
                and queued[0]["dueAtMs"] - queued[0]["createdAtMs"] == 10000,
                "visible default countdown did not stage exactly one ten-second intent")
        require(queued[0]["draftId"] == read_draft(binary, directory, extra)["id"],
                "countdown staged a different local draft")
        capture(terminal, capture_dir, "ux-default-send-countdown")
        terminal.send(b"\x1a")
        terminal.until(lambda: not countdown_active(terminal) and "Subject:" in terminal.text())
        no_writes(binary, directory, extra)
        require(queue_entries(binary, directory, extra)[0]["state"] == "canceled",
                "Ctrl+Z hid countdown without canceling its durable queued intent")
        retained = read_draft(binary, directory, extra)
        require(retained["subject"] == "Cancel countdown fixture", "countdown cancellation discarded the local draft")
        # Cross the original deadline: cancelling the visible toast must also
        # cancel its delayed submission, not merely hide the UI affordance.
        terminal.gap(10.2)
        no_writes(binary, directory, extra)
        # Repeat, then reach Undo through ordinary focus traversal and Enter.
        send_review(terminal)
        activate_button(terminal, "[y Send]")
        terminal.until(lambda: countdown_active(terminal))
        undo = next(label for label in ("[Undo Ctrl+Z]", "[Undo]", "[Undo send]") if label in terminal.text())
        activate_button(terminal, undo)
        terminal.until(lambda: not countdown_active(terminal) and "Subject:" in terminal.text())
        no_writes(binary, directory, extra)
        require(all(entry["state"] == "canceled" for entry in queue_entries(binary, directory, extra)),
                "focused Undo left an active queued intent")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def countdown_due(binary, directory, capture_dir=None):
    extra, body = setup(binary, directory)
    terminal = start(binary, directory, extra, beginning(body), send_grace=1)
    try:
        compose(terminal, subject="Explicit due fixture")
        send_review(terminal)
        activate_button(terminal, "[y Send]")
        terminal.until(lambda: countdown_active(terminal))
        require(stats(binary, directory, extra)["fixtureSends"] == 0,
                "configured grace submitted synchronously on confirmation")
        terminal.until(lambda: "Send complete · provider accepted" in terminal.text() and not countdown_active(terminal))
        require(stats(binary, directory, extra)["fixtureSends"] == 1,
                "expired countdown did not submit exactly one fixture message")
        queued = queue_entries(binary, directory, extra)
        require(len(queued) == 1 and queued[0]["state"] == "applied"
                and queued[0]["operation"]["outcome"] == "applied",
                "expired countdown omitted its final durable submission receipt")
        terminal.gap(.2)
        terminal.send(b"\x1a")
        terminal.gap(.08)
        require(stats(binary, directory, extra)["fixtureSends"] == 1,
                "post-submission Undo retried or fabricated a send reversal")
        terminal.finish(expected_sends=1)
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def main():
    cases = (("sender-completion-undo", sender_completion_undo),
             ("attachment-reminder", attachment_reminder),
             ("countdown-cancel", countdown_cancel), ("countdown-due", countdown_due))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=[name for name, _ in cases], action="append")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    run_cases(args.binary, cases, args.case, args.capture_dir)


if __name__ == "__main__":
    main()
