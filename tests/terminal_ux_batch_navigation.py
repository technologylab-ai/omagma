#!/usr/bin/env python3
"""New palette/find/unread/history/label workflows in synthetic owned PTYs.

No desktop or user configuration is accessed. Runtime execution requires the
coordinator's cooperative host window; this file is independent acceptance.
"""
from __future__ import annotations

import argparse
import base64
import copy
import json
from pathlib import Path
import re
import shutil

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, ROOT, require
from terminal_ux_batch_support import (TAB, BACKTAB, ENTER, ESC, activate_button,
    capture, command, diagnose, focus_button, no_writes, read_mail, run_cases, start)

MARKER = "Owned UX current message 096."
TOKEN = "needleUX"


def fixtures(binary, directory):
    source = ProviderFixture(directory)
    (source.root / "contacts").mkdir(mode=0o700)
    for account in ACCOUNTS:
        key = account.split("@")[0]
        shutil.copyfile(ROOT / "tests/fixtures/terminal/contacts" / f"{key}.json",
                        source.root / "contacts" / f"{key}.json")
        data = source.data[account]["baseline"]
        data["labels"] = [
            {"id": "INBOX", "name": "Inbox", "type": "system"},
            {"id": "Label_demo", "name": "Projects", "type": "user"},
            {"id": "Label_travel", "name": "Travel", "type": "user"}]
        for mail in data["messages"]:
            number = int(mail["id"][-3:])
            if "INBOX" not in mail["labelIds"]:
                continue
            mail["labelIds"] = ["INBOX"]
            if number in (96, 93, 63):
                mail["labelIds"].append("UNREAD")
            if number in (96, 95):
                mail["labelIds"].append("Label_travel")
            if number == 96:
                mail["labelIds"].append("Label_demo")
            if number not in (96, 93, 63):
                continue
            content = f"Owned UX current message {number:03}.\n"
            if number == 96:
                content += (f"First {TOKEN} visible hit.\n" +
                            "\n".join(f"Fictional filler row {i:03}." for i in range(35)) +
                            f"\nSecond {TOKEN} later hit.\n" +
                            "\n".join(f"More fictional row {i:03}." for i in range(35)) +
                            f"\nThird {TOKEN} final hit.\n")
            data_bytes = content.encode()
            payload = mail["payload"]
            payload.update(mimeType="text/plain", filename="", body={
                "size": len(data_bytes), "data": base64.urlsafe_b64encode(data_bytes).decode().rstrip("=")})
            payload.pop("parts", None)
            for header in payload["headers"]:
                if header["name"].lower() == "content-type":
                    header["value"] = "text/plain; charset=utf-8"
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        for account in ACCOUNTS:
            # Establish the complete configured retained head and checkpoint.
            # A cold TUI bootstrap intentionally replaces a history-less list
            # seed with its normal 32-row head, evicting the cross-window hit.
            client.request("mail.refresh", account=account, limit=40, prefetchLimit=40)
            client.request("labels.list", account=account)
            for number in (96, 95, 94, 93, 63):
                client.request("mail.read", account=account, messageId=f"shared-msg-{number:03}")
    return source


def palette(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    terminal = start(binary, directory, source.options(), MARKER)
    try:
        command(terminal, "actions")
        terminal.until(lambda: "Actions" in terminal.text() and "[Back]" in terminal.text())
        require(ACCOUNTS[0] in terminal.text(), "palette omitted its account context")
        terminal.send(b"qjk-unmatched-query")
        terminal.until(lambda: "qjk-unmatched-query" in terminal.text())
        require(terminal.process.poll() is None, "palette printable query invoked browse commands")
        terminal.send(b"2")
        terminal.until(lambda: "qjk-unmatched-query2" in terminal.text())
        require(ACCOUNTS[0] in terminal.screen.lines()[0],
                "a printable account number in the palette changed its pinned account")
        terminal.resize(40, 12)
        terminal.until(lambda: "[Back]" in terminal.text() and "Actions" in terminal.text())
        capture(terminal, capture_dir, "ux-palette-40x12")
        activate_button(terminal, "[Back]")
        terminal.until(lambda: "Actions" not in terminal.text())
        terminal.resize(160, 40)
        terminal.until(lambda: MARKER in terminal.text())
        command(terminal, "actions")
        terminal.until(lambda: "Actions" in terminal.text())
        terminal.send(b"theme")
        terminal.until(lambda: "theme" in terminal.text().lower() and "[Run]" in terminal.text())
        focus_button(terminal, "[Run]")
        focus_button(terminal, "[Back]", backwards=True)
        focus_button(terminal, "[Run]")
        terminal.send(ENTER)
        terminal.until(lambda: "Theme" in terminal.text() and "[Cancel]" in terminal.text())
        activate_button(terminal, "[Cancel]")
        terminal.until(lambda: "[Apply]" not in terminal.text())
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def palette_mono(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    terminal = start(binary, directory, source.options(), MARKER, mono=True)
    try:
        command(terminal, "actions")
        terminal.until(lambda: "Actions" in terminal.text() and "[Back]" in terminal.text())
        terminal.send(b"qjk2")
        terminal.until(lambda: "qjk2" in terminal.text())
        terminal.resize(40, 12)
        terminal.until(lambda: "[Back]" in terminal.text())
        focus_button(terminal, "[Back]")
        position = terminal.screen.locate("[Back]")
        require(terminal.screen.reverse_cells[position["row"]][position["column"]],
                "NO_COLOR palette focus has no visible reverse-video state")
        require(all(style[0] is None and style[1] is None for row in terminal.screen.styles for style in row),
                "NO_COLOR palette still emitted color-dependent state")
        terminal.send(ENTER)
        terminal.until(lambda: "Actions" not in terminal.text())
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def find_and_unread(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    baseline = {n: read_mail(binary, directory, source.options(), f"shared-msg-{n:03}")
                for n in (96, 93, 63)}
    terminal = start(binary, directory, source.options(), MARKER)
    try:
        command(terminal, "find " + TOKEN)
        terminal.until(lambda: TOKEN in terminal.text() and "Find 1/3" in terminal.text()
                       and "First needleUX visible hit." in terminal.text())
        terminal.send(b"n")
        terminal.until(lambda: "Find 2/3" in terminal.text() and "Second needleUX later hit." in terminal.text())
        terminal.send(b"N")
        terminal.until(lambda: "Find 1/3" in terminal.text() and "First needleUX visible hit." in terminal.text())
        capture(terminal, capture_dir, "ux-find-current-message")
        terminal.send(ESC)
        terminal.gap(.05)
        command(terminal, "next-unread")
        terminal.until(lambda: "Owned UX current message 093." in terminal.text())
        command(terminal, "next-unread")
        terminal.until(lambda: "Owned UX current message 063." in terminal.text())
        command(terminal, "previous-unread")
        terminal.until(lambda: "Owned UX current message 093." in terminal.text())
        for n, before in baseline.items():
            after = read_mail(binary, directory, source.options(), f"shared-msg-{n:03}")
            require(after["labels"] == before["labels"] and after["bodyText"] == before["bodyText"],
                    "find/unread navigation changed mail or implicitly marked it read")
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def labels(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    identifiers = ("shared-msg-096", "shared-msg-095")
    before = {key: read_mail(binary, directory, source.options(), key) for key in identifiers}
    terminal = start(binary, directory, source.options(), MARKER)
    try:
        terminal.send(b"  m")  # Each selection advances: select96, select95.
        terminal.until(lambda: "Projects" in terminal.text() and "[Apply 0]" in terminal.text()
                       and "[Cancel]" in terminal.text())
        terminal.until(lambda: "[-]" in terminal.text() and "[x]" in terminal.text()
                       and "Reading current labels" not in terminal.text())
        text = terminal.text()
        require("[-]" in text and "[x]" in text,
                "selected messages do not expose mixed and common label membership")
        require("2" in text and ACCOUNTS[0] in text, "labels omitted count/account scope")
        terminal.send(b" ")  # Stage the selected label; opening/staging is local.
        for key in identifiers:
            require(read_mail(binary, directory, source.options(), key)["labels"] == before[key]["labels"],
                    "checkbox changed provider membership before Apply")
        activate_button(terminal, "[Cancel]")
        terminal.until(lambda: "[Cancel]" not in terminal.text())
        no_writes(binary, directory, source.options())
        terminal.send(b"m")
        terminal.until(lambda: "[Apply 0]" in terminal.text())
        terminal.until(lambda: "[-]" in terminal.text() and "Reading current labels" not in terminal.text())
        terminal.send(b"/Projects" + ENTER + b" ")
        terminal.until(lambda: "[x]" in terminal.text() and "Projects" in terminal.text())
        terminal.resize(40, 12)
        terminal.until(lambda: "[Apply 1]" in terminal.text() and "[Cancel]" in terminal.text())
        capture(terminal, capture_dir, "ux-staged-labels-40x12")
        activate_button(terminal, "[Apply 1]")
        terminal.until(lambda: "[Cancel]" not in terminal.text())
        for key in identifiers:
            terminal.until(lambda key=key: "Label_demo" in read_mail(binary, directory, source.options(), key)["labels"])
            after = read_mail(binary, directory, source.options(), key)
            require("INBOX" in after["labels"] and "Label_travel" in after["labels"]
                    and after["bodyText"] == before[key]["bodyText"],
                    "staged Apply changed unrelated membership/body")
        require("Label_demo" not in read_mail(binary, directory, source.options(), "shared-msg-094")["labels"],
                "label Apply touched mail outside selected scope")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def history(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    terminal = start(binary, directory, source.options(), MARKER)
    try:
        terminal.send(b"/subject:personal" + ENTER)
        terminal.until(lambda: "Cache search" in terminal.screen.lines()[0])
        terminal.gap(.1)
        terminal.send(b"q")
        terminal.until(lambda: "Cache search" not in terminal.screen.lines()[0])
        terminal.send(b"\\subject:personal" + ENTER)
        terminal.until(lambda: "Gmail search" in terminal.screen.lines()[0])
        terminal.gap(.1)
        terminal.send(b"q")
        terminal.until(lambda: "Gmail search" not in terminal.screen.lines()[0])
        command(terminal, "search-history")
        terminal.until(lambda: "Search history" in terminal.text() and "subject:personal" in terminal.text())
        require("Cache" in terminal.text() and "Gmail" in terminal.text(),
                "history erased search scope or conflated cache and server searches")
        capture(terminal, capture_dir, "ux-account-search-history")
        activate_button(terminal, "[Back]")
        terminal.until(lambda: "Search history" not in terminal.text())
        terminal.send(b"2")
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0])
        command(terminal, "search-history")
        terminal.until(lambda: "Search history" in terminal.text())
        require("subject:personal" not in terminal.text(), "search history leaked another account's queries")
        activate_button(terminal, "[Back]")
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def scope_trash(binary, directory, capture_dir=None):
    source = fixtures(binary, directory)
    expected_ids = {"shared-msg-094", "shared-msg-095", "shared-msg-096"}
    with Client(binary, directory, extra=source.options()) as client:
        resolved = client.request("mail.triage-scope", messageId="shared-msg-096", scope="conversation")
        require(resolved["complete"] and resolved["count"] == 3
                and set(resolved["messageIds"]) == expected_ids,
                "conversation fixture did not resolve its exact three message IDs")
        single = client.request("mail.triage-scope", messageId="shared-msg-096", scope="message")
        require(single["messageIds"] == ["shared-msg-096"] and single["count"] == 1,
                "message scope unexpectedly resolved other conversation messages")
    before = {key: read_mail(binary, directory, source.options(), key) for key in expected_ids}
    untouched = read_mail(binary, directory, source.options(), "shared-msg-093")
    terminal = start(binary, directory, source.options(), MARKER)
    try:
        command(terminal, "scope thread")
        terminal.gap(.1)
        terminal.send(b"D")
        terminal.until(lambda: "trash" in terminal.text().lower()
                       and any(label in terminal.text() for label in ("[Cancel]", "[Back]")))
        safe_button = "[Cancel]" if "[Cancel]" in terminal.text() else "[Back]"
        require(ACCOUNTS[0] in terminal.text()
                and re.search(r"3\s+(?:messages|mails|items)", terminal.text(), re.I),
                "conversation review omitted its actual account/count scope")
        capture(terminal, capture_dir, "ux-conversation-scope-review")
        terminal.send(ENTER)
        terminal.until(lambda: safe_button not in terminal.text())
        no_writes(binary, directory, source.options())
        for key, message in before.items():
            require(read_mail(binary, directory, source.options(), key)["labels"] == message["labels"],
                    "default review Enter trashed a conversation message")
        terminal.send(b"D")
        terminal.until(lambda: "trash" in terminal.text().lower() and safe_button in terminal.text())
        confirm = next(label for label in ("[y Confirm]", "[Confirm]", "[Trash]", "[y Trash]") if label in terminal.text())
        activate_button(terminal, confirm)
        terminal.until(lambda: safe_button not in terminal.text())
        for key, message in before.items():
            terminal.until(lambda key=key: "TRASH" in read_mail(binary, directory, source.options(), key)["labels"])
            after = read_mail(binary, directory, source.options(), key)
            require("INBOX" not in after["labels"] and after["bodyText"] == message["bodyText"],
                    "confirmed conversation Trash changed message content or retained Inbox")
        require(read_mail(binary, directory, source.options(), "shared-msg-093")["labels"] == untouched["labels"],
                "conversation action touched the adjacent unrelated message")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def main():
    cases = (("palette", palette), ("palette-mono", palette_mono), ("find-unread", find_and_unread),
             ("labels", labels), ("history", history), ("scope-trash", scope_trash))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=[name for name, _ in cases], action="append")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    run_cases(args.binary, cases, args.case, args.capture_dir)


if __name__ == "__main__":
    main()
