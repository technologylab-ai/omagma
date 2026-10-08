#!/usr/bin/env python3
"""Sticky RSVP discoverability in actual owned fixture PTYs; never sends mail."""
from __future__ import annotations

import argparse
import copy
from pathlib import Path
import re
import sys
import tempfile

from terminal_cache import ProviderFixture
from terminal_file_dialog import b64, capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_invitations import identity, invitation, part
from terminal_mouse import click, report, start
from terminal_reader import reader_contains, reader_rectangle, reader_rows


def fixture_setup(binary, directory):
    source = ProviderFixture(directory)
    for account in ACCOUNTS:
        baseline = source.data[account]["baseline"]
        baseline["labels"] = [{"id": "INBOX", "name": "Inbox", "type": "system"}] + [
            {"id": f"Label_{number}", "name": f"Product / launch planning {number}", "type": "user"}
            for number in range(10)]
        for message in baseline["messages"]:
            number = message["id"][-3:]
            if number not in ("094", "095", "096"):
                continue
            case = "first" if number == "096" else "second"
            content = (f"{case.title()} meeting opening for {account}.\n\n" +
                       "\n".join(f"Fictional agenda line {row:03} for {case} meeting." for row in range(150)) +
                       f"\nLast {case} meeting line.\n")
            if number == "094":
                content = "Ordinary thread note without a calendar invitation.\n"
            headers = copy.deepcopy(message["payload"]["headers"])
            for header in headers:
                if header["name"].lower() == "subject":
                    header["value"] = "Fictional launch planning"
                if header["name"].lower() == "content-type":
                    header["value"] = "multipart/mixed; boundary=invitation-banner"
            plain = part("text/plain", content.encode())
            plain["partId"] = "text"
            parts = [plain]
            if number != "094":
                wire = invitation(case, account)
                external = f"calendar-{number}"
                parts.append(part("application/octet-stream", wire, "invite.ics", external))
                baseline.setdefault("externalBodies", {})[external] = {"size": len(wire), "data": b64(wire)}
            message["payload"] = {"partId": "", "mimeType": "multipart/mixed", "filename": "",
                                  "headers": headers, "body": {"size": 0}, "parts": parts}
            message["labelIds"] = ["INBOX", "UNREAD"] + [f"Label_{i}" for i in range(10)]
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        for account in ACCOUNTS:
            client.request("labels.list", account=account)
            client.request("mail.refresh", account=account, limit=32, prefetchLimit=3)
            client.request("mail.thread", account=account, threadId="shared-thread-031")
            require(client.request("cache.stats", account=account)["fixtureSends"] == 0,
                    "seeding invitation display sent mail")
    return source


def banner(terminal, mono=False):
    where = terminal.screen.locate("I · Respond")
    area = reader_rectangle(terminal.screen)
    require(where is not None and area is not None, "sticky invitation action absent from reader")
    require(area["left"] <= where["column"] < area["right"]
            and area["top"] <= where["row"] < area["bottom"],
            "invitation action is outside the visible reader")
    edge_row = where["row"] - (1 if terminal.screen.locate("Meeting invitation") else 0)
    expected_edge = "┃" if mono else "▌"
    edge = next((column for column in range(area["left"], min(area["left"] + 3, area["right"]))
                 if terminal.screen.cells[edge_row][column] == expected_edge), None)
    require(edge is not None, "callout has no distinct visual edge")
    style = terminal.screen.styles[where["row"]][where["column"]]
    if mono:
        # The existing six-field cell oracle tracks italic/underline/strike,
        # not reverse. Independently require the literal reverse-I wire token.
        require(re.search(rb"\x1b\[7m(?:\x1b\[[0-9;:]*m)*I\x1b\[27m", terminal.output) is not None,
                "NO_COLOR invitation shortcut lacks reverse emphasis")
    else:
        require(style[1] == ("rgb", 57, 43, 48), "callout does not use theme's tinted surface")
        require(style[0] != ("rgb", 255, 158, 97), "callout action blends into orange label text")
        body_row = next(row for row, _ in reader_rows(terminal.screen)
                        if not edge_row <= row <= where["row"])
        body_style = terminal.screen.styles[body_row][area["left"] + 3]
        require(style[1] != body_style[1], "callout surface blends into the body")
    return where


def review(terminal, account, case):
    terminal.until(lambda: "Review invitation reply" in terminal.text()
                   and identity(case, account)["uid"] in terminal.text())
    text = terminal.text()
    require(f"Account: {account}" in text and identity(case, account)["organizer"] in text,
            "RSVP callout reviewed a different message or account")
    terminal.send(b"\r")  # Existing review defaults to Cancel, never Accept.
    terminal.until(lambda: "Review invitation reply" not in terminal.text())


def run(binary, directory, capture_dir=None, mono=False):
    source = fixture_setup(binary, directory)
    terminal = start(binary, directory, source, columns=160, rows=42,
                     environment={"NO_COLOR": "1" if mono else None})
    try:
        terminal.until(lambda: reader_contains(terminal.screen, f"First meeting opening for {ACCOUNTS[0]}.")
                       and terminal.screen.locate("I · Respond") is not None)
        first = banner(terminal, mono)
        require("Labels:" in "\n".join(text for _, text in reader_rows(terminal.screen)),
                "busy label header missing from visual contrast fixture")
        edge_row = first["row"] - 1
        before = "".join("".join(text.split()) for row, text in reader_rows(terminal.screen) if row < edge_row)
        require(before.endswith("Product/launchplanning9"),
                "invitation callout is not immediately after the full label header")
        opening = terminal.screen.locate(f"First meeting opening for {ACCOUNTS[0]}.")
        require(opening is not None and opening["row"] > first["row"],
                "invitation callout must precede the message body")
        require(not reader_contains(terminal.screen, "Last first meeting line."),
                "fixture body did not exceed its initial viewport")
        capture(terminal, capture_dir, "invitation-first-frame-mono" if mono else "invitation-first-frame")
        click(terminal, first["column"], first["row"])
        review(terminal, ACCOUNTS[0], "first")
        terminal.send(b"G")
        terminal.until(lambda: reader_contains(terminal.screen, "Last first meeting line."))
        pinned = banner(terminal, mono)
        require(pinned["row"] <= reader_rectangle(terminal.screen)["top"] + 3,
                "invitation action did not pin after its header scrolled away")
        capture(terminal, capture_dir, "invitation-at-end-mono" if mono else "invitation-at-end")
        # Wheel on the callout belongs to the reader, never activates RSVP.
        current = banner(terminal, mono)
        report(terminal, current["column"], current["row"], button=64)
        terminal.gap(.08)
        require("Review invitation reply" not in terminal.text(), "wheel on banner opened review")
        banner(terminal, mono)
        terminal.send(b"I")
        review(terminal, ACCOUNTS[0], "first")
        # Load all cards, then prove the callout follows the actual focused card.
        terminal.send(b"\r")
        terminal.until(lambda: "3 mails" in terminal.text() or "/3 mails" in terminal.text())
        terminal.send(b"{")
        terminal.until(lambda: "2/3 mails" in terminal.text()
                       and reader_contains(terminal.screen, "I · Respond"))
        banner(terminal, mono)
        terminal.send(b"I")
        review(terminal, ACCOUNTS[0], "second")
        terminal.send(b"{")
        terminal.until(lambda: "1/3 mails" in terminal.text() and "I · Respond" not in terminal.text())
        terminal.send(b"}}")
        terminal.until(lambda: "3/3 mails" in terminal.text() and "I · Respond" in terminal.text())
        # Below, expanded and minimum laptop views retain the same visible cue.
        terminal.send(b"v")
        terminal.until(lambda: "Reader below" in terminal.screen.lines()[0]
                       and reader_contains(terminal.screen, "I · Respond"))
        banner(terminal, mono)
        capture(terminal, capture_dir, "invitation-below-mono" if mono else "invitation-below")
        terminal.send(b"z")
        terminal.gap(.08)
        banner(terminal, mono)
        terminal.resize(30, 10)
        terminal.until(lambda: "I · Respond" in terminal.text()
                       and "Meeting invitation" not in terminal.text()
                       and reader_rectangle(terminal.screen) is not None)
        banner(terminal, mono)
        capture(terminal, capture_dir, "invitation-narrow-mono" if mono else "invitation-narrow")
        terminal.resize(160, 42)
        terminal.until(lambda: "Meeting invitation" in terminal.text()
                       and reader_rectangle(terminal.screen) is not None)
        # New compose must not show an invitation hint for unrelated original mail.
        terminal.send(b"c")
        terminal.until(lambda: "Compose" in terminal.screen.lines()[0])
        require("I · Respond" not in terminal.text(), "composer displayed inactive RSVP action")
        terminal.send(b"\x1b")
        terminal.gap(.12)
        terminal.send(b"q")
        terminal.until(lambda: "Compose" not in terminal.screen.lines()[0])
        terminal.send(b"2")
        terminal.until(lambda: ACCOUNTS[1] in terminal.screen.lines()[0] and "I · Respond" in terminal.text())
        banner(terminal, mono)
        terminal.send(b"I")
        review(terminal, ACCOUNTS[1], "first")
        with Client(binary, directory, extra=source.options()) as client:
            for account in ACCOUNTS:
                require(client.request("cache.stats", account=account)["fixtureSends"] == 0,
                        "display, review, Cancel or account switch sent RSVP")
                require(client.request("operation.list", account=account)["operations"] == [],
                        "display/review created a write intent")
        terminal.finish()
        print(f"PASS invitation callout ({'NO_COLOR' if mono else 'theme'}): below-label placement, tinted distinct header, "
              "scroll/wheel pinning, exact thread/account review, below/expanded/narrow, compose suppression, zero sends")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        capture(terminal, capture_dir, "invitation-failure-mono" if mono else "invitation-failure")
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-invitation-banner-") as temporary:
        for mono in (False, True):
            run(args.binary.resolve(), Path(temporary) / ("mono" if mono else "theme"), args.capture_dir, mono)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
