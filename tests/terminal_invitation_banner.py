#!/usr/bin/env python3
"""Sticky RSVP discoverability in actual owned fixture PTYs; never sends mail."""
from __future__ import annotations

import argparse
import copy
from pathlib import Path
import sys
import tempfile

from terminal_cache import ProviderFixture
from terminal_file_dialog import b64, capture
from terminal_integration import ACCOUNTS, Client, require
from terminal_invitations import identity, invitation, part
from terminal_mouse import MouseTerminal, click, report
from terminal_theme_picker import ThemeScreen
from terminal_pty import wait_saved_compose
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
                if number == "095":
                    wire = wire.replace(b"DESCRIPTION:Join this fictional meeting at https://teams.microsoft.com/\r\n l/meetup-join/fictional", b"LOCATION:Meeting room 4")
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


def banner(terminal, mono=False, camera=True):
    where = terminal.screen.locate("I · Respond")
    area = reader_rectangle(terminal.screen)
    require(where is not None and area is not None, "sticky invitation action absent from reader")
    require(area["left"] <= where["column"] < area["right"]
            and area["top"] <= where["row"] < area["bottom"],
            "invitation action is outside the visible reader")
    # The title/action are inside a bordered card on roomy readers; compact
    # readers retain the low-height edge. Locate the actual top, not a fixed row.
    action_row = where["row"]
    left = area["left"]
    border_left = next((x for x in range(left, min(left + 3, area["right"]))
                        if action_row > area["top"] and terminal.screen.cells[action_row - 1][x] in {"╭", "┌", "╔"}), None)
    bordered = border_left is not None
    card_top = action_row - 1 if bordered else action_row
    if bordered:
        require(terminal.screen.cells[card_top + 4][border_left] in {"╰", "└", "╚"},
                "invitation card is not a complete compact five-row frame")
        require("Invitation" in "".join(terminal.screen.cells[card_top][left:area["right"]]),
                "invitation card has no readable type badge")
        require(terminal.screen.cells[action_row][border_left] in {"│", "║"},
                "invitation card hero is outside its border")
    else:
        expected_edge = "┃" if mono else "▌"
        require(any(terminal.screen.cells[action_row][column] == expected_edge
                    for column in range(left, min(left + 3, area["right"]))),
                "compact invitation has no distinct visual edge")
    card_row = "".join(terminal.screen.cells[action_row][left:area["right"]])
    require(("" in card_row) == camera,
            "video-call marker does not match the focused invitation's Join link")
    style = terminal.screen.styles[action_row][where["column"]]
    if mono:
        require(terminal.screen.reversed[action_row][where["column"]],
                "NO_COLOR invitation shortcut lacks current-cell reverse emphasis")
    else:
        require(style[0] == ("rgb", 255, 158, 97) and style[2],
                "invitation shortcut must use the theme's bold accent")
        require(style[1] != ("rgb", 57, 43, 48),
                "ordinary invitation must not look like a selected message")
    where = dict(where, card_top=card_top)

    return where


def review(terminal, account, case):
    terminal.until(lambda: "Meeting · review reply" in terminal.text() and "[v Details]" in terminal.text())
    text = terminal.text()
    hero = next(line for line in text.splitlines() if "Fictional calendar meeting" in line)
    require(("" in hero) == (case == "first"),
            "review card video marker does not match the inspected invitation")
    require(f"Account: {account}" in text and identity(case, account)["organizer"] in text,
            "RSVP callout reviewed a different message or account")
    require("UID:" not in text, "friendly meeting summary exposed protocol-only identifiers")
    terminal.send(b"v")
    terminal.until(lambda: identity(case, account)["uid"] in terminal.text() and "Sequence:" in terminal.text())
    terminal.send(b"\r")  # Existing review defaults to Cancel, never Accept.
    terminal.until(lambda: "Meeting · review reply" not in terminal.text())


def run(binary, directory, capture_dir=None, mono=False):
    source = fixture_setup(binary, directory)
    terminal = MouseTerminal(binary, directory, extra=source.options(), screen_type=ThemeScreen,
                             columns=160, rows=42,
                             environment={"NO_COLOR": "1" if mono else None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: reader_contains(terminal.screen, f"First meeting opening for {ACCOUNTS[0]}.")
                       and terminal.screen.locate("I · Respond") is not None)
        first = banner(terminal, mono)
        require("Labels:" in "\n".join(text for _, text in reader_rows(terminal.screen)),
                "busy label header missing from visual contrast fixture")
        require(first["card_top"] == first["row"] - 1,
                "roomy split reader did not render its bordered invitation card")
        edge_row = first["card_top"]
        before = "".join("".join(text.split()) for row, text in reader_rows(terminal.screen) if row < edge_row)
        require(before.endswith("Product/launchplanning9"),
                "invitation callout is not after the full label header")
        preceding = [(row, text) for row, text in reader_rows(terminal.screen)
                     if row < edge_row and text.strip()]
        require(preceding[-1][0] == edge_row - 2,
                "invitation callout must have exactly one blank row above it")
        opening = terminal.screen.locate(f"First meeting opening for {ACCOUNTS[0]}.")
        require(opening is not None and opening["row"] > first["card_top"] + 4,
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
        require("Meeting · review reply" not in terminal.text(), "wheel on banner opened review")
        banner(terminal, mono)
        terminal.send(b"I")
        review(terminal, ACCOUNTS[0], "first")
        # Load all cards, then prove the callout follows the actual focused card.
        terminal.send(b"\r")
        terminal.until(lambda: "3 mails" in terminal.text() or "/3 mails" in terminal.text())
        terminal.send(b"{")
        terminal.until(lambda: "2/3 mails" in terminal.text()
                       and reader_contains(terminal.screen, "I · Respond"))
        banner(terminal, mono, camera=False)
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
                       and "Fictional calendar meeting" not in terminal.text()
                       and reader_rectangle(terminal.screen) is not None)
        banner(terminal, mono)
        capture(terminal, capture_dir, "invitation-narrow-mono" if mono else "invitation-narrow")
        terminal.resize(160, 42)
        terminal.until(lambda: "Fictional calendar meeting" in terminal.text()
                       and reader_rectangle(terminal.screen) is not None)
        # New compose must not show an invitation hint for unrelated original mail.
        terminal.send(b"c")
        terminal.until(lambda: "Compose" in terminal.screen.lines()[0])
        wait_saved_compose(terminal)
        terminal.until(lambda: "I · Respond" not in terminal.text())
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
        print(f"PASS invitation callout ({'NO_COLOR' if mono else 'theme'}): below-label placement, themed bordered/compact card, "
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
