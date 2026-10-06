#!/usr/bin/env python3
"""Focused synthetic reader/context interactions in owned PTYs only."""
import argparse
import base64
import copy
import json
import sys
from pathlib import Path
import tempfile

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start, click, point
from terminal_reader import reader_contains

FIRST = b"First fictional attachment\n"
SECOND = b"Second fictional attachment\n"
URI = "https://example.test/reader?one=1&two=2"


def fixture_setup(binary, directory):
    fixture = ProviderFixture(directory)
    for account in ACCOUNTS:
        source = fixture.data[account]["baseline"]
        message = next(value for value in source["messages"] if value["id"] == "shared-msg-096")
        text = (f"Synthetic {account} message 096.\nREADER-AUTHORED-TEXT\n{URI}\n"
                "On Monday Alex wrote:\n> READER-QUOTED-HISTORY\n-- \nREADER-SIGNATURE-TAIL\n")
        plain = copy.deepcopy(message["payload"])
        plain["partId"] = "0"
        plain["headers"] = [{"name": "Content-Type", "value": "text/plain; charset=utf-8"}]
        plain["body"] = {"size": len(text.encode()), "data": base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")}
        root = message["payload"]
        root["mimeType"] = "multipart/mixed"
        root["body"] = {"size": 0, "data": ""}
        for header in root["headers"]:
            if header["name"].lower() == "content-type": header["value"] = "multipart/mixed; boundary=fixture-reader"
        root["parts"] = [plain]
        for index, (name, data) in enumerate((("reader-one.txt", FIRST), ("reader-two.txt", SECOND)), 1):
            root["parts"].append({"partId": str(index), "mimeType": "application/octet-stream", "filename": name,
                "headers": [{"name": "Content-Disposition", "value": f'attachment; filename="{name}"'}],
                "body": {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}})
        fixture.stage(account, "baseline")
    with Client(binary, directory, extra=fixture.options()) as client:
        for account in ACCOUNTS:
            client.request("mail.refresh", account, limit=40, prefetchLimit=40)
            for message_id in ("shared-msg-096", "shared-msg-095", "shared-msg-094"):
                client.request("mail.read", account, messageId=message_id)
        client.request("mail.thread", ACCOUNTS[0], threadId="shared-thread-031")
    return fixture


def command(terminal, value):
    terminal.send(b":" + value.encode() + b"\r")
    terminal.gap(.12)


def quit_cleanly(terminal):
    terminal.finish()
    terminal.close()


def reader_case(binary, directory):
    fixture = fixture_setup(binary, directory)
    terminal = start(binary, directory, fixture)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "READER-AUTHORED-TEXT"))
        terminal.send(b"\r")
        terminal.until(lambda: "3/3" in terminal.text())
        require("READER-AUTHORED-TEXT" in terminal.text(), "selected thread body did not anchor into view")
        terminal.send(b"Q")
        terminal.until(lambda: "Quoted history folded" in terminal.text())
        require("READER-QUOTED-HISTORY" not in terminal.text(), "quote fold retained quoted payload")
        terminal.send(b"S")
        terminal.until(lambda: "Signature folded" in terminal.text())
        require("READER-SIGNATURE-TAIL" not in terminal.text(), "signature fold retained signature tail")
        terminal.send(b"{t")
        terminal.gap(.1)
        require("Synthetic" in terminal.text(), "thread navigation erased the reader")
        terminal.send(b"L")
        terminal.until(lambda: "Links · explicit browser open" in terminal.text() and URI in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        terminal.send(b"B")
        terminal.until(lambda: "Received attachments" in terminal.text() and "reader-two.txt" in terminal.text())
        destination = directory / "second received attachment.txt"
        click(terminal, *point(terminal, "reader-two.txt"))
        click(terminal, *point(terminal, "[s Save]"))
        terminal.until(lambda: "Save to a new absolute path:" in terminal.text())
        terminal.send(b"\x15" + str(destination).encode() + b"\r")
        terminal.until(lambda: destination.exists())
        require(destination.read_bytes() == SECOND, "click Save targeted the wrong received attachment")
        require(destination.stat().st_mode & 0o077 == 0, "received attachment permissions are not owner-only")
        terminal.send(b"B")
        terminal.until(lambda: "Received attachments" in terminal.text())
        terminal.send(b"jo")
        terminal.until(lambda: "then open it:" in terminal.text())
        opened = directory / "explicitly opened fixture.txt"
        terminal.send(b"\x15" + str(opened).encode() + b"\r")
        terminal.until(lambda: opened.exists() and "Attachment saved · mock file-open validated" in terminal.text())
        require(opened.read_bytes() == SECOND, "explicit Save & open targeted the wrong file")
        quit_cleanly(terminal)
        print("PASS reader: thread folding, explicit URL fixture, mouse save and explicit save/open")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        if terminal.process.poll() is None: terminal.close()


def context_case(binary, directory):
    fixture = fixture_setup(binary, directory)
    terminal = start(binary, directory, fixture)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "READER-AUTHORED-TEXT"))
        preferences = directory / "config" / "omagma" / "ui.json"
        command(terminal, "split right 60")
        terminal.until(lambda: preferences.exists() and json.loads(preferences.read_text())["listWidthPercent"] == 60)
        command(terminal, "bind n down")
        terminal.until(lambda: any(binding == {"key": "n", "action": "down"} for binding in json.loads(preferences.read_text())["bindings"]))
        terminal.send(b"n")
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[0]} message 095."))
        terminal.send(b"2")
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[1]} message 096."))
        click(terminal, *point(terminal, "Sent"))
        terminal.until(lambda: "|   Sent" in terminal.text())
        terminal.send(b"1")
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[0]} message 095."))
        quit_cleanly(terminal)
        preferences = directory / "config" / "omagma" / "ui.json"
        saved = json.loads(preferences.read_text())
        require(saved["listWidthPercent"] == 60, "split preference was not saved")
        require(any(binding == {"key": "n", "action": "down"} for binding in saved["bindings"]), "custom key mapping was not saved")
        require(any(context["account"] == ACCOUNTS[1] and context["folder"] == 1 for context in saved["contexts"]), "per-account mailbox was not saved")
        terminal = start(binary, directory, fixture)
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[0]} message 095."))
        terminal.send(b"n")
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[0]} message 094."))
        terminal.send(b"2")
        terminal.until(lambda: "|   Sent" in terminal.text())
        click(terminal, *point(terminal, "All Mail"))
        terminal.until(lambda: "All Mail" in terminal.screen.lines()[0])
        quit_cleanly(terminal)
        saved = json.loads(preferences.read_text())
        require(any(context["account"] == ACCOUNTS[1] and context["folder"] == 6 for context in saved["contexts"]), "new All Mail context was not saved")
        terminal = start(binary, directory, fixture)
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0] and "All Mail" in terminal.screen.lines()[0])
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[1]} message 096."))
        terminal.send(b"n")
        terminal.until(lambda: reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[1]} message 095."))
        quit_cleanly(terminal)
        print("PASS context: account mailbox/selected mail, Sent/All Mail restart, saved key and pane ratio")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        if terminal.process.poll() is None: terminal.close()


def search_case(binary, directory):
    fixture = fixture_setup(binary, directory)
    # Warm contacts so opening the pane can use its independent cached state.
    contacts_dir = fixture.root / "contacts"
    contacts_dir.mkdir(mode=0o700)
    from terminal_integration import ROOT
    import shutil
    for account in ACCOUNTS:
        name = account.split("@")[0]
        shutil.copyfile(ROOT / "tests" / "fixtures" / "terminal" / "contacts" / f"{name}.json", contacts_dir / f"{name}.json")
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("contacts.list", ACCOUNTS[0])
    terminal = start(binary, directory, fixture)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "READER-AUTHORED-TEXT"))
        terminal.send(b"/body:READER-AUTHORED-TEXT\r")
        terminal.until(lambda: "Cache search" in terminal.screen.lines()[0])
        terminal.until(lambda: "Searching cached mail" not in terminal.screen.lines()[1])
        require(reader_contains(terminal.screen, "READER-AUTHORED-TEXT"), "body-aware cache search lost cached reader")
        terminal.send(b"/body:never-present-fixture-term\r")
        terminal.until(lambda: "No rows in cached subset" in terminal.text() or "No matching messages" in terminal.text())
        terminal.send(b"a")
        terminal.until(lambda: "Contacts" in terminal.text() and "Alex Personal Fixture" in terminal.text())
        terminal.send(b"q")
        terminal.until(lambda: "Cache search" in terminal.screen.lines()[0])
        terminal.send(b"q")
        terminal.until(lambda: "Cache search" not in terminal.screen.lines()[0])
        terminal.until(lambda: reader_contains(terminal.screen, "READER-AUTHORED-TEXT"))
        quit_cleanly(terminal)
        print("PASS cached search: worker body matches, local empty result, contacts/back and retained reader")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        if terminal.process.poll() is None: terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=("reader", "context", "search", "all"), default="all")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-local-reader-") as temporary:
        root = Path(temporary)
        if args.case in ("reader", "all"): reader_case(args.binary.resolve(), root / "reader")
        if args.case in ("context", "all"): context_case(args.binary.resolve(), root / "context")
        if args.case in ("search", "all"): search_case(args.binary.resolve(), root / "search")


if __name__ == "__main__":
    main()
