#!/usr/bin/env python3
"""Independent practical queue recovery regressions in owned fixtures only.

Run native processes only in the coordinator's granted host reservation window.
Crash injection edits only the stopped, temporary fixture store: it models the
durable queue claim before an ordinary operation receipt can be written.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
from pathlib import Path

from build_info import read_build_info
from terminal_composer_workflow import setup
from terminal_file_dialog import FIRST, fixture_setup
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import click, point
from terminal_ux_batch_support import (ESC, ENTER, TAB, command, compose, diagnose,
    run_cases, start)


SUBJECT = "Independent interrupted queue fixture"
DRAFT = {"to": "reviewer@example.test", "subject": SUBJECT,
         "bodyText": "A reviewed fictional message, retained across restart."}


def seed(binary, directory, state="queued", delay=0, draft_value=None):
    extra, body = setup(binary, directory)
    with Client(binary, directory, extra=extra) as client:
        draft = client.request("draft.create", draft=DRAFT if draft_value is None else draft_value)
        queue = client.request("draft.queue", draftId=draft["id"],
                               operationId="independent-recovery", delaySeconds=delay)
        require(client.request("operation.list")["operations"] == [],
                "staging unexpectedly wrote a submission receipt")
    if state != "queued":
        index = (directory / "cache/fixtures" /
                 hashlib.sha256(ACCOUNTS[0].encode()).hexdigest() / "index.json")
        stored = json.loads(index.read_text())
        require(stored["operations"] == [] and len(stored["sendQueue"]) == 1,
                "crash injection requires one unsubmitted fixture intent")
        stored["sendQueue"][0]["state"] = state
        index.write_text(json.dumps(stored) + "\n")
        index.chmod(0o600)
    return extra, body["bodyText"].splitlines()[0], draft, queue


def expect_error(client, cmd, code, **params):
    result = client.request(cmd, ok=False, **params)
    require(result["code"] == code,
            f"{cmd}: expected {code}, got {result['code']}")


def protected_cli(binary, directory, capture_dir=None):
    extra, _, draft, queue = seed(binary, directory, "submitting")
    with Client(binary, directory, extra=extra) as client:
        require(client.request("operation.list")["operations"] == [],
                "restart invented a submission receipt")
        for _ in range(2):
            require(client.request("queue.process", queueId=queue["queueId"])["state"] == "submitting",
                    "repeated process replayed a claimed send")
        expect_error(client, "queue.read", "QueueNotFound", account=ACCOUNTS[1], queueId=queue["queueId"])
        expect_error(client, "queue.cancel", "SendAlreadySubmitted", queueId=queue["queueId"])
        expect_error(client, "queue.resume", "SendAlreadySubmitted", queueId=queue["queueId"], delaySeconds=0)
        expect_error(client, "draft.discard", "UnknownOutcome", draftId=draft["id"])
        expect_error(client, "draft.update", "UnknownOutcome", draftId=draft["id"],
                     draft={**DRAFT, "bodyText": "Changed while submission is uncertain"})
        for operation in (queue["operationId"], "different-id-same-content"):
            expect_error(client, "draft.send", "UnknownOutcome", draftId=draft["id"], operationId=operation)
            expect_error(client, "mail.send", "UnknownOutcome", draft=DRAFT, operationId=operation)
        expect_error(client, "mail.send", "OperationConflict",
                     draft={**DRAFT, "bodyText": "Changed after interruption"},
                     operationId=queue["operationId"])
        clone = client.request("draft.create", draft=DRAFT)
        expect_error(client, "draft.queue", "UnknownOutcome", draftId=clone["id"],
                     operationId="clone-new-id", delaySeconds=0)
        require(client.request("cache.stats")["fixtureSends"] == 0,
                "a fenced replay reached mock submission")
        require(client.request("draft.read", draftId=draft["id"])["bodyText"] == draft["bodyText"],
                "protected draft content changed")


def open_draft(terminal):
    terminal.until(lambda: terminal.screen.locate("Drafts") is not None)
    click(terminal, *point(terminal, "Drafts"))
    terminal.until(lambda: SUBJECT in terminal.text())
    terminal.send(ENTER)
    terminal.until(lambda: "Subject:" in terminal.text() and SUBJECT in terminal.text())
    # Let asynchronous operation + queue receipt inspection finish. Assertions
    # below target state and editing behavior rather than exact status copy.
    terminal.gap(.5)


def protected_tui(binary, directory, state):
    extra, opening, draft, queue = seed(binary, directory, state)
    terminal = start(binary, directory, extra, opening)
    try:
        open_draft(terminal)
        require("protected" in terminal.text().lower() or "unknown" in terminal.text().lower(),
                f"{state} queue with no operation receipt was shown as editable")
        terminal.send(b"iMUST_NOT_EDIT")
        terminal.gap(.15)
        require("MUST_NOT_EDIT" not in terminal.text(), "protected composer accepted edits")
        command(terminal, "receipt")
        terminal.gap(.5)
        require("protected" in terminal.text().lower() or "unknown" in terminal.text().lower(),
                "explicit receipt refresh removed the queue protection")
        terminal.send(b"iSTILL_PROTECTED")
        terminal.gap(.15)
        require("STILL_PROTECTED" not in terminal.text(), "receipt refresh allowed draft edits")
        with Client(binary, directory, extra=extra) as client:
            require(client.request("queue.read", queueId=queue["queueId"])["state"] == state,
                    "opening an interrupted draft changed or processed the queue")
            require(client.request("cache.stats")["fixtureSends"] == 0, "recovery sent mail")
            require(client.request("draft.read", draftId=draft["id"])["bodyText"] == draft["bodyText"],
                    "recovery changed the saved content")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def submitting_restart(binary, directory, capture_dir=None):
    protected_tui(binary, directory, "submitting")


def unknown_restart(binary, directory, capture_dir=None):
    protected_tui(binary, directory, "unknown")


def queued_cancel(binary, directory, capture_dir=None):
    extra, opening, draft, queue = seed(binary, directory)
    terminal = start(binary, directory, extra, opening)
    try:
        terminal.gap(.75)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("queue.read", queueId=queue["queueId"])["state"] == "queued",
                    "startup automatically processed a due queued intent")
            require(client.request("cache.stats")["fixtureSends"] == 0, "startup sent queued mail")
        open_draft(terminal)
        guidance = (("queued" in terminal.text().lower() or "pending send" in terminal.text().lower())
                    and "resume" in terminal.text().lower())
        command(terminal, "cancel-send")
        terminal.gap(.5)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("queue.read", queueId=queue["queueId"])["state"] == "canceled",
                    "TUI cancel did not durably cancel the recovered queue")
        terminal.send(b"iEDITABLE_AFTER_CANCEL")
        terminal.until(lambda: "EDITABLE_AFTER_CANCEL" in terminal.text())
        terminal.send(ESC)
        terminal.gap(.08)
        terminal.finish()
        with Client(binary, directory, extra=extra) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require("EDITABLE_AFTER_CANCEL" in json.dumps(saved), "canceled draft edit was lost on exit")
            require(client.request("cache.stats")["fixtureSends"] == 0, "cancel submitted the draft")
        require(guidance, "recovered queued draft lacks persistent explicit Resume/Cancel guidance")
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def queued_resume(binary, directory, capture_dir=None):
    extra, opening, draft, queue = seed(binary, directory)
    terminal = start(binary, directory, extra, opening, send_grace=1)
    try:
        open_draft(terminal)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("cache.stats")["fixtureSends"] == 0, "opening a queued draft sent it")
        command(terminal, "resume-send")
        terminal.until(lambda: "accepted" in terminal.text().lower() or "send complete" in terminal.text().lower(), seconds=6)
        with Client(binary, directory, extra=extra) as client:
            require(client.request("queue.read", queueId=queue["queueId"])["state"] == "applied",
                    "explicit resume did not finish its existing queue")
            client.request("queue.process", queueId=queue["queueId"])
            require(client.request("cache.stats")["fixtureSends"] == 1,
                    "resuming or reprocessing duplicated submission")
        terminal.finish(expected_sends=1)
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def queued_context_isolation(binary, directory, capture_dir=None):
    # Each branch starts with exactly one paused draft, then opens a second
    # draft either in the same account or in another configured account.
    for account_index in (0, 1):
        case = directory / ("same-account" if account_index == 0 else "other-account")
        case.mkdir(mode=0o700)
        # Match the normal TUI sender so an unchanged Back save remains
        # byte-equivalent and cannot legitimately cancel the queued intent.
        initial = {**DRAFT, "from": {"address": ACCOUNTS[0], "name": "Configured Primary"}}
        extra, opening, draft, queue = seed(binary, case, draft_value=initial)
        terminal = start(binary, case, extra, opening, send_grace=1)

        def retained():
            with Client(binary, case, extra=extra) as client:
                require(client.request("queue.read", queueId=queue["queueId"])["state"] == "queued",
                        "an unrelated draft action changed the original paused queue")
                require(client.request("draft.read", draftId=draft["id"])["bodyText"] == initial["bodyText"],
                        "leaving the queued draft changed its retained content")
                for account in ACCOUNTS[:2]:
                    require(client.request("cache.stats", account=account)["fixtureSends"] == 0,
                            "recovery context leaked a send into another draft or account")
                    require(client.request("operation.list", account=account)["operations"] == [],
                            "an unrelated draft action created a send operation")

        try:
            open_draft(terminal)
            terminal.until(lambda: "Queued send paused" in terminal.text())
            retained()
            terminal.send(b"q")
            terminal.until(lambda: "Subject:" not in terminal.text())
            terminal.gap(.2)
            retained()
            if account_index:
                terminal.send(b"2")
                terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0])
                terminal.gap(.2)
            subject = "Unrelated recovery context fixture"
            compose(terminal, subject=subject, body="This second draft must stay local.")
            terminal.gap(.5)
            require(f"From: {ACCOUNTS[account_index]}" in terminal.text(),
                    "second draft opened in an unexpected account")
            require("Queued send paused" not in terminal.text(),
                    "second draft retained the previous draft's paused-send hint")
            command(terminal, "actions")
            terminal.until(lambda: "Actions" in terminal.text() and "[Back]" in terminal.text())
            terminal.send(b"pending send")
            terminal.until(lambda: "pending send" in terminal.text())
            terminal.gap(.1)
            require("Resume pending send" not in terminal.text()
                    and "Cancel pending send" not in terminal.text(),
                    "second draft exposes the previous draft's recovery actions")
            terminal.send(ESC)
            terminal.until(lambda: "Actions" not in terminal.text())
            for action in ("resume-send", "cancel-send"):
                command(terminal, action)
                terminal.until(lambda: "NoPendingSend" in terminal.text())
                retained()
                # A rejected command remains in its editable command line.
                terminal.send(ESC)
                terminal.gap(.08)
                require(subject in terminal.text() and "Subject:" in terminal.text(),
                        "rejected recovery command left the unrelated draft")
            terminal.gap(1.2)  # Cross the one-second deadline a leaked resume would create.
            retained()
            terminal.finish()
            retained()
        except Exception:
            diagnose(terminal)
            raise
        finally:
            terminal.close()


def unread_mailbox_scope(binary, directory, capture_dir=None):
    branches = (
        ("Archive", 95, (92, 91, 92), {
            96: ["INBOX"], 95: [], 94: ["INBOX", "UNREAD"],
            93: ["TRASH", "UNREAD"], 92: ["UNREAD"], 91: ["UNREAD"]}),
        ("All Mail", 96, (93, 91, 93), {
            96: ["INBOX"], 95: ["TRASH", "UNREAD"], 94: ["SPAM", "UNREAD"],
            93: ["INBOX", "UNREAD"], 92: ["TRASH", "UNREAD"], 91: ["UNREAD"]}),
    )
    for folder, initial, expected, labels in branches:
        case = directory / folder.lower().replace(" ", "-")
        case.mkdir(mode=0o700)
        extra, _ = setup(binary, case)
        provider = case / "fixture/accounts/personal.json"
        source = json.loads(provider.read_text())
        source["sync"] = {"historyId": "1000", "history": []}

        def marker(number):
            return f"Independent unread scope message {number:03}."

        for mail in source["messages"]:
            number = int(mail["id"][-3:])
            mail["labelIds"] = labels.get(number, ["INBOX"])
            if number not in labels:
                continue
            body = (marker(number) + "\n").encode()
            mail["payload"].update(mimeType="text/plain", filename="", body={
                "size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")})
            mail["payload"].pop("parts", None)
            for header in mail["payload"]["headers"]:
                if header["name"].lower() == "content-type":
                    header["value"] = "text/plain; charset=utf-8"
        provider.write_text(json.dumps(source) + "\n")
        with Client(binary, case, extra=extra) as client:
            client.request("cache.clear")
            client.request("mail.refresh", limit=100, prefetchLimit=0)
            client.request("mail.list", limit=100)
            client.request("mail.list", label="TRASH", limit=100)
            client.request("mail.list", label="SPAM", limit=100)
            if folder == "Archive":
                client.request("mail.list", query="-in:inbox -in:trash", limit=100)
            baseline = {number: client.request("mail.read", messageId=f"shared-msg-{number:03}")
                        for number in labels}
        terminal = start(binary, case, extra, marker(96))
        try:
            terminal.until(lambda: terminal.screen.locate(folder) is not None)
            click(terminal, *point(terminal, folder))
            terminal.until(lambda: marker(initial) in terminal.text())
            for action, number in zip(("next-unread", "next-unread", "previous-unread"), expected):
                command(terminal, action)
                terminal.until(lambda: marker(number) in terminal.text())
                require("AnchorNotCached" not in terminal.text(),
                        f"{folder} unread search returned a target outside its displayed mailbox")
            with Client(binary, case, extra=extra) as client:
                for number, before in baseline.items():
                    after = client.request("mail.read", messageId=f"shared-msg-{number:03}", cacheOnly=True)
                    require(after["labels"] == before["labels"] and after["bodyText"] == before["bodyText"],
                            f"{folder} unread navigation changed labels or message content")
                require(client.request("operation.list")["operations"] == [],
                        "unread mailbox navigation dispatched a mail mutation")
                require(client.request("cache.stats")["fixtureSends"] == 0,
                        "unread mailbox navigation sent mail")
            terminal.finish()
        except Exception:
            diagnose(terminal)
            raise
        finally:
            terminal.close()


def unread_body_query(binary, directory, capture_dir=None):
    extra, _ = setup(binary, directory)
    extra = (*extra, "--metadata-limit", "40")
    provider = directory / "fixture/accounts/personal.json"
    source = json.loads(provider.read_text())
    source["sync"] = {"historyId": "1000", "history": []}
    token = "UnreadBodyNeedle"

    def marker(number):
        return f"Independent body-query message {number:03}."

    for mail in source["messages"]:
        number = int(mail["id"][-3:])
        mail["labelIds"] = ["INBOX"] + (["UNREAD"] if number in (93, 63) else [])
        body = (marker(number) + "\n" + token + "\n").encode()
        mail["payload"].update(mimeType="text/plain", filename="", body={
            "size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")})
        mail["payload"].pop("parts", None)
        for header in mail["payload"]["headers"]:
            if header["name"].lower() == "content-type":
                header["value"] = "text/plain; charset=utf-8"
    provider.write_text(json.dumps(source) + "\n")
    query = "body:" + token

    def retained_matches(client):
        matches = client.request("mail.search", query=query, label="INBOX", cacheOnly=True, limit=100)
        require([entry["id"] for entry in matches["messages"]]
                == [f"shared-msg-{number:03}" for number in range(96, 56, -1)],
                "body-query fixture no longer retains the full forty-message cached window")

    with Client(binary, directory, extra=extra) as client:
        client.request("cache.clear")
        # Establish history before starting the TUI; its ordinary refresh then
        # retains this valid forty-message cache rather than bootstrapping 32.
        client.request("mail.refresh", limit=40, prefetchLimit=40)
        retained_matches(client)
        baseline = {number: client.request("mail.read", messageId=f"shared-msg-{number:03}", cacheOnly=True)
                    for number in (96, 93, 63)}
    terminal = start(binary, directory, extra, marker(96))
    try:
        terminal.gap(.4)
        with Client(binary, directory, extra=extra) as client:
            retained_matches(client)
        terminal.send(b"/" + query.encode() + ENTER)
        terminal.until(lambda: "Cache search" in terminal.text() and marker(96) in terminal.text())
        terminal.gap(.2)
        for action, number in (("next-unread", 93), ("next-unread", 63), ("previous-unread", 93)):
            command(terminal, action)
            terminal.until(lambda: marker(number) in terminal.text())
            require("AnchorNotCached" not in terminal.text(),
                    "body-query unread navigation failed to reveal its anchored target")
        with Client(binary, directory, extra=extra) as client:
            retained_matches(client)
            for number, before in baseline.items():
                after = client.request("mail.read", messageId=f"shared-msg-{number:03}", cacheOnly=True)
                require(after["labels"] == before["labels"] and after["bodyText"] == before["bodyText"],
                        "body-query unread navigation changed labels or message content")
            require(client.request("operation.list")["operations"] == [],
                    "body-query unread navigation dispatched a mail mutation")
            require(client.request("cache.stats")["fixtureSends"] == 0,
                    "body-query unread navigation sent mail")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def save_all_stops_on_failure(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    extra = source.options()
    message = next(item for item in source.data[ACCOUNTS[0]]["baseline"]["messages"]
                   if item["id"] == "shared-msg-096")
    missing = next(part for part in message["payload"]["parts"]
                   if part.get("filename") == "meeting notes.txt")
    # Keep valid received attachment metadata, but make its payload unavailable
    # at the provider boundary. Only the copied fictional provider is edited.
    missing["body"] = {"size": missing["body"]["size"], "attachmentId": "independent-missing-payload"}
    source.stage(ACCOUNTS[0], "baseline")
    with Client(binary, directory, extra=extra) as client:
        client.request("cache.clear")
        client.request("mail.refresh", limit=32, prefetchLimit=4)
        received = client.request("mail.read", messageId="shared-msg-096")
        require(len(received["attachments"]) == 2, "failed-file fixture lost its metadata")
    destination = directory / "received"
    destination.mkdir(mode=0o700)
    terminal = start(binary, directory, extra, "Fictional file-dialog message 096.")
    try:
        command(terminal, "save-all " + str(destination))
        terminal.until(lambda: (destination / "report.txt").exists())
        terminal.gap(.8)
        require("saving attachments" not in terminal.text().lower(),
                "persistent Save All failure automatically restarted the failed attachment")
        require("meeting notes.txt" in terminal.text()
                and any(word in terminal.text().lower() for word in ("failed", "stopped", "error", "unavailable")),
                "Save All failure omitted the failed filename and explicit partial outcome")
        require((destination / "report.txt").read_bytes() == FIRST,
                "failure damaged the file already saved")
        require(sorted(path.name for path in destination.iterdir()) == ["report.txt"],
                "failed attachment left a partial file or repeated earlier saves")
        before = terminal.output_total
        terminal.gap(.8)
        require(terminal.output_total - before < 100_000, "failed attachment kept the TUI in a redraw/retry loop")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def delayed_scope_navigation(binary, directory, capture_dir=None):
    extra, body = setup(binary, directory)
    terminal = start(binary, directory, extra, body["bodyText"].splitlines()[0])
    try:
        command(terminal, "scope conversation")
        terminal.until(lambda: "whole conversation" in terminal.text().lower())
        lock = directory / "cache/fixtures" / hashlib.sha256(ACCOUNTS[0].encode()).hexdigest() / "lock"
        # Hold only our private cache briefly so the native async scope reply
        # arrives after the user moves. No timing sleeps or production network
        # mocks are added to source code.
        with lock.open("r+b") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            terminal.send(b"x")
            terminal.until(lambda: "Resolving exact conversation" in terminal.text())
            terminal.send(b"j")
            terminal.gap(.15)
            fcntl.flock(stream, fcntl.LOCK_UN)
        terminal.gap(.8)
        require("Review conversation action" not in terminal.text(),
                "stale scope reply opened a confirmation after the selection changed")
        with Client(binary, directory, extra=extra) as client:
            require(client.request("operation.list")["operations"] == [],
                    "moving during a scope lookup dispatched a mail mutation")
            require(client.request("cache.stats")["fixtureSends"] == 0, "scope navigation sent mail")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def checked_files_enter(binary, directory, capture_dir=None):
    extra, body = setup(binary, directory)
    folder = directory / "literal fixture files"
    folder.mkdir(mode=0o700)
    expected = {"a-first café.txt": b"First checked file.\n", "b-second.txt": b"Second checked file.\n"}
    for name, raw in expected.items():
        (folder / name).write_bytes(raw)
    terminal = start(binary, directory, extra, body["bodyText"].splitlines()[0])
    try:
        compose(terminal, subject="Independent checked selection Enter")
        terminal.send(b"A")
        terminal.until(lambda: "Path:" in terminal.text() and "[Attach]" in terminal.text())
        terminal.send(b"\x15" + str(folder).encode() + b"/" + ENTER)
        terminal.until(lambda: all(name in terminal.text() for name in expected))
        terminal.send(TAB * 4 + b" ")
        terminal.until(lambda: "1 selected" in terminal.text())
        terminal.send(b"\x1b[B ")
        terminal.until(lambda: "2 selected" in terminal.text())
        # Enter activates the current file row, not the Attach button. The
        # explicit checked set must still win over the highlighted filename.
        terminal.send(ENTER)
        terminal.until(lambda: "Attachments 2" in terminal.text() and "Path:" not in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            drafts = client.request("draft.list")["drafts"]
            require(len(drafts) == 1, "file-row Enter created another draft")
            draft = client.request("draft.read", draftId=drafts[0]["id"])
            require({entry["filename"] for entry in draft["attachments"]} == set(expected),
                    "file-row Enter silently omitted a checked attachment")
            require(client.request("cache.stats")["fixtureSends"] == 0, "attachment selection sent mail")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


CASES = (("protected-cli", protected_cli), ("submitting-restart", submitting_restart),
         ("unknown-restart", unknown_restart), ("queued-cancel", queued_cancel),
         ("queued-resume", queued_resume), ("queued-context-isolation", queued_context_isolation),
         ("unread-mailbox-scope", unread_mailbox_scope),
         ("unread-body-query", unread_body_query),
         ("save-all-stops-on-failure", save_all_stops_on_failure),
         ("delayed-scope-navigation", delayed_scope_navigation), ("checked-files-enter", checked_files_enter))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=[name for name, _ in CASES], action="append")
    args = parser.parse_args()
    print(json.dumps({"suite": "independent-ux-adversarial", "synthetic": True,
                      "liveProviderWrites": 0, **read_build_info(args.binary.resolve())}), flush=True)
    run_cases(args.binary, CASES, selected=args.case)


if __name__ == "__main__":
    main()
