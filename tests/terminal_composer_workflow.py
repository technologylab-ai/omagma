#!/usr/bin/env python3
"""Focused local composer workflows in fixture-backed owned PTYs; no mail sent."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import tempfile

from terminal_integration import ACCOUNTS, FIXTURES, MANIFEST, ROOT, Client, require
from terminal_mouse import MouseTerminal, click, point
from terminal_mouse_screen import MouseScreen


def setup(binary, directory, forward=False):
    fixture = directory / "fixture"
    shutil.copytree(FIXTURES, fixture, ignore=shutil.ignore_patterns("__pycache__"))
    source_path = fixture / "accounts/personal.json"
    source = json.loads(source_path.read_text())
    source["identities"] = [
        {"address": ACCOUNTS[0], "name": "Configured Primary", "signature": "Primary fixture signature", "isDefault": True},
        {"address": "alias@example.test", "name": "Fictional Alias", "signature": "Alias fixture signature", "isDefault": False},
    ]
    if forward:
        message = next(item for item in source["messages"] if item["id"] == "shared-msg-003")
        message["internalDate"] = str(max(int(item["internalDate"]) for item in source["messages"]) + 60000)
        message["labelIds"] = ["INBOX", "UNREAD"]
    source_path.write_text(json.dumps(source, ensure_ascii=False))
    configuration = json.loads((ROOT / "tests/fixtures/all-accounts.json").read_text())
    configuration["accounts"][0].update(senderName="Configured Primary", signature="Primary fixture signature")
    config = directory / "synthetic-config.json"
    config.write_text(json.dumps(configuration))
    config.chmod(0o600)
    extra = ("--fixture-root", str(fixture), "--config", str(config))
    with Client(binary, directory, extra=extra) as client:
        client.request("mail.list", limit=32)
        body = client.request("mail.read", messageId="shared-msg-003" if forward else "shared-msg-096")
        client.request("contacts.list")
        client.request("accounts.identities")
    return extra, body


def start(binary, directory, extra, body):
    terminal = MouseTerminal(binary, directory, extra=extra, columns=160, rows=40, screen_type=MouseScreen)
    first_line = body["bodyText"].splitlines()[0]
    terminal.until(lambda: first_line in terminal.text() and terminal.screen.mouse_modes == {1002, 1004, 1006})
    return terminal


def composer(terminal, key=b"c"):
    terminal.send(key)
    terminal.until(lambda: "Subject:" in terminal.text() and "[f Alias]" in terminal.text()
                   and "Attachments " in terminal.text() and "Ctrl+S Review" in terminal.text())
    # Current-cell reconstruction may observe the upper half of a VT frame
    # before its lower attachment controls/footer arrive in the next read.
    terminal.gap(.05)


def saved(terminal, literal):
    terminal.until(lambda: literal in terminal.text() and "Draft saved locally" in terminal.text()
                   and "autosave pending" not in terminal.text() and "Saving locally" not in terminal.text())


def draft(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        drafts = client.request("draft.list")["drafts"]
        require(len(drafts) == 1, "composer created another local draft")
        result = client.request("draft.read", draftId=drafts[0]["id"])
        require(client.request("cache.stats")["fixtureSends"] == 0, "composer workflow sent mail")
        return result


def add_files(terminal, directory, existing=0):
    for number, data in enumerate((b"Synthetic first attachment\n", bytes(range(128))), 1):
        path = directory / f"added-{number}.txt"
        path.write_bytes(data)
        if number == 1:
            terminal.send(b"A")
        else:
            click(terminal, *point(terminal, "[Add A]"))
        terminal.until(lambda: "Attach file path:" in terminal.text())
        terminal.send(str(path).encode() + b"\r")
        terminal.until(lambda: f"Attachments {existing + number}" in terminal.text()
                       and f"Attached added-{number}.txt" in terminal.text())


def open_retained(terminal, subject):
    click(terminal, *point(terminal, "Drafts"))
    terminal.until(lambda: subject in terminal.text())
    terminal.send(b"\r")
    terminal.until(lambda: "Subject:" in terminal.text() and "[f Alias]" in terminal.text()
                   and "Attachments " in terminal.text() and "Ctrl+S Review" in terminal.text())
    terminal.gap(.05)


def completion_aliases(binary, directory):
    extra, body = setup(binary, directory)
    terminal = start(binary, directory, extra, body)
    try:
        composer(terminal)
        terminal.send(b"ialex@")
        terminal.until(lambda: "alex@" in terminal.text() and "Draft changed" in terminal.text())
        saved(terminal, "alex@")
        incomplete = draft(binary, directory, extra)
        require(incomplete["recoveryFields"][0] == "alex@", "partial recipient was lost by autosave")
        require(incomplete["from"]["name"] == "Configured Primary", "primary sender name not honored")
        terminal.send(b"\x7f" * 5 + b"al")
        terminal.until(lambda: "Recipients ·" in terminal.text() and "alex-personal@example.org" in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "To: alex-personal@example.org" in terminal.text())
        # Tab keeps its field behavior while editing; type a useful subject.
        terminal.send(b"\t" * 3 + b"Composer workflow fixture\tTyped reply text.")
        terminal.send(b"\x1b")
        terminal.gap(.06)
        terminal.send(b"f")
        terminal.until(lambda: "From: alias@example.test" in terminal.text() and "Alias fixture signature" in terminal.text())
        add_files(terminal, directory)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text() and "Attachment 2: added-2.txt" in terminal.text())
        retained = draft(binary, directory, extra)
        require(retained.get("recoveryFields") is None, "validated review retained unfinished fields")
        require(retained["from"]["address"] == "alias@example.test", "alias disappeared during review")
        require(retained["to"][0]["address"] == "alex-personal@example.org", "completion inserted wrong recipient")
        require(retained["bodyText"].startswith("Typed reply text."), "signature moved above typed text")
        require("Primary fixture signature" not in retained["bodyText"], "alias cycling duplicated the old signature")
        require(retained["bodyText"].count("Alias fixture signature") == 1, "alias signature duplicated")
        require([item["filename"] for item in retained["attachments"]] == ["added-1.txt", "added-2.txt"], "multiple files lost during review")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    terminal = start(binary, directory, extra, body)
    try:
        open_retained(terminal, "Composer workflow fixture")
        require("Attachments 2" in terminal.text() and "From: alias@example.test" in terminal.text(), "reopening lost files or From")
        reopened = draft(binary, directory, extra)
        require(reopened["bodyText"] == retained["bodyText"], "reopening injected another signature")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    print("PASS composer: partial autosave, cached completion, alias/signature, multiple files, validated review/reopen")


def crash_recovery(binary, directory):
    extra, body = setup(binary, directory)
    terminal = start(binary, directory, extra, body)
    try:
        composer(terminal)
        terminal.send(b"ialex@\t\t\tRecovery fixture\tWork in progress")
        terminal.until(lambda: "Work in progress" in terminal.text() and "Draft changed" in terminal.text())
        saved(terminal, "Work in progress")
        retained = draft(binary, directory, extra)
        require(retained["recoveryFields"][0] == "alex@", "autosave refused unfinished address")
        # The owned child has core dumps disabled and no desktop connection.
        # SIGKILL proves persistence without relying on graceful exit saving.
        os.killpg(terminal.process.pid, signal.SIGKILL)
        terminal.process.wait(timeout=5)
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    terminal = start(binary, directory, extra, body)
    try:
        open_retained(terminal, "Recovery fixture")
        require("alex@" in terminal.text() and "Work in progress" in terminal.text(), "incomplete draft was not restored after crash")
        require(draft(binary, directory, extra)["recoveryFields"] == retained["recoveryFields"], "crash recovery changed raw fields")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    print("PASS composer: incomplete raw fields survive owned SIGKILL and reopen without sending")


def forward_files(binary, directory):
    extra, body = setup(binary, directory, forward=True)
    require(len(body["attachments"]) == 1, "forward fixture lacks its known original attachment")
    terminal = start(binary, directory, extra, body)
    try:
        composer(terminal, b"F")
        require("Attachments 1" in terminal.text(), "forward omitted original attachment")
        terminal.send(b"ialex@example.org\x1b")
        terminal.gap(.06)
        add_files(terminal, directory, existing=1)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text() and "Attachment 3: added-2.txt" in terminal.text())
        retained = draft(binary, directory, extra)
        require(retained["subject"].startswith("Fwd:"), "forward lacks Fwd subject")
        require(not retained["threadId"] and not retained["inReplyTo"], "forward incorrectly retained reply threading")
        require(len(retained["attachments"]) == 3, "forward lost original or newly attached files")
        original = retained["attachments"][0]
        raw = base64.urlsafe_b64decode(original["data"] + "=" * (-len(original["data"]) % 4))
        require(hashlib.sha256(raw).hexdigest() == MANIFEST["attachmentExpected"]["sha256"], "forward changed original attachment bytes")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    print("PASS composer: forward downloads exact original file and retains two new files without sending")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-composer-workflow-") as temporary:
        for name, case in (("completion-aliases", completion_aliases), ("crash-recovery", crash_recovery), ("forward-files", forward_files)):
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            case(args.binary.resolve(), directory)


if __name__ == "__main__":
    main()
