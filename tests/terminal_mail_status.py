#!/usr/bin/env python3
"""Fictional owned-PTY unread/star gutters and readable reader-label checks."""
from __future__ import annotations

import argparse
import base64
from pathlib import Path
import tempfile

from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen
from terminal_reader import reader_contains, reader_rows
from terminal_repaint import panel_interiors
from terminal_scroll_progress import fixture, options


LABEL_ID = "Label_opaque_shared_8642"
LONG_LABEL_ID = "Label_opaque_long_7531"
LABEL_NAMES = {
    ACCOUNTS[0]: "Personal projects",
    ACCOUNTS[1]: "Work projects",
}
LONG_LABEL = "Éruption planning / a comfortably readable label that wraps across narrow reader widths"


def setup(binary, directory):
    source = fixture(directory)
    for account in ACCOUNTS[:2]:
        data = source.data[account]["baseline"]
        data["labels"] = [
            {"id": "INBOX", "name": "Inbox", "type": "system"},
            {"id": "UNREAD", "name": "UNREAD", "type": "system"},
            {"id": "STARRED", "name": "STARRED", "type": "system"},
            {"id": LABEL_ID, "name": LABEL_NAMES[account], "type": "user"},
            {"id": LONG_LABEL_ID, "name": LONG_LABEL, "type": "user"},
        ]
        for message in data["messages"]:
            number = int(message["id"].rsplit("-", 1)[1])
            if number not in (96, 95, 94):
                continue
            labels = ["INBOX", LABEL_ID]
            if number != 95:
                labels.append("UNREAD")
            if number in (96, 95):
                labels.append("STARRED")
            if number == 96:
                labels.append(LONG_LABEL_ID)
            message["labelIds"] = labels
            message["snippet"] = f"Status fixture excerpt {number:03}"
            payload = message["payload"]
            for header in payload["headers"]:
                if header["name"] == "Subject":
                    header["value"] = f"Status {number:03}"
                if header["name"] == "From":
                    header["value"] = "Row Sender <row-sender@example.test>"
            body = f"Status body {account} {number:03}.\nFictional mail only.\n".encode()
            payload["body"] = {
                "size": len(body),
                "data": base64.urlsafe_b64encode(body).decode().rstrip("="),
            }
        source.stage(account, "baseline")
    with Client(binary, directory, extra=options(source, 96)) as client:
        for account in ACCOUNTS[:2]:
            client.request("mail.refresh", account, limit=96, prefetchLimit=0, label="INBOX")
            client.request("labels.list", account)
            for number in (96, 95, 94):
                client.request("mail.read", account, messageId=f"shared-msg-{number:03}")
    return source


def start(binary, directory, source):
    return MouseTerminal(
        binary, directory, extra=options(source, 96), columns=160, rows=42,
        screen_type=MouseScreen,
        environment={"NO_COLOR": None, "COLORTERM": "truecolor"},
    )


def mail_panel(terminal):
    title = terminal.screen.locate("Mail ·")
    if title is None:
        return None
    return next((panel for panel in panel_interiors(terminal.screen)
                 if panel[0] <= title["column"] < panel[1]
                 and panel[2] - 1 == title["row"]), None)


def card(terminal, number):
    panel = mail_panel(terminal)
    if panel is None:
        return None
    left, right, top, bottom = panel
    literal = f"Status {number:03}"
    for row in range(top, bottom):
        if "".join(terminal.screen.cells[row][left:right]).startswith("   " + literal) or literal in "".join(terminal.screen.cells[row][left:right]):
            location = next((column for column in range(left, right)
                             if "".join(terminal.screen.cells[row][column:right]).startswith(literal)), None)
            if location is not None:
                # The framed pane keeps one cell of horizontal padding inside
                # its border; status positions are relative to the content.
                return {"left": left + 1, "right": right - 1, "row": row, "column": location}
    return None


def status_matches(terminal, number, unread, starred, bulk=False):
    target = card(terminal, number)
    if target is None:
        return False
    left, row = target["left"], target["row"]
    if target["column"] != left + 3 or row + 1 >= terminal.rows:
        return False
    first = terminal.screen.cells[row]
    second = terminal.screen.cells[row + 1]
    if first[left] != ("✓" if bulk else " ") or first[left + 1] != ("●" if unread else " ") or first[left + 2] != " ":
        return False
    if starred:
        if second[left] != "⭐" or second[left + 1] != "" or second[left + 2] != " ":
            return False
    elif any(cell.strip() for cell in second[left:left + 3]):
        return False
    if "".join(second[left + 3:target["right"]]).startswith("Row Sender") is False:
        return False
    # Current SGR cells prove emphasis; a historical escape sequence does not.
    for column in range(target["column"], target["column"] + len(f"Status {number:03}")):
        style = terminal.screen.styles[row][column]
        if style[2] is not unread or style[3]:
            return False
    return True


def labels_match(terminal, account, number=96):
    other = ACCOUNTS[1] if account == ACCOUNTS[0] else ACCOUNTS[0]
    joined = "\n".join(text for _, text in reader_rows(terminal.screen))
    return (reader_contains(terminal.screen, f"Status body {account} {number:03}.")
            and reader_contains(terminal.screen, "Labels: Inbox")
            and reader_contains(terminal.screen, LABEL_NAMES[account])
            and (number != 96 or reader_contains(terminal.screen, LONG_LABEL))
            and LABEL_NAMES[other] not in joined
            and LABEL_ID not in joined and LONG_LABEL_ID not in joined)


def list_status(binary, directory):
    source = setup(binary, directory)
    terminal = start(binary, directory, source)
    try:
        terminal.until(lambda: status_matches(terminal, 96, True, True)
                       and status_matches(terminal, 95, False, True)
                       and status_matches(terminal, 94, True, False)
                       and labels_match(terminal, ACCOUNTS[0])
                       and "Up to date" in terminal.screen.lines()[1])
        terminal.send(b" ")
        terminal.until(lambda: status_matches(terminal, 96, True, True, bulk=True)
                       and status_matches(terminal, 95, False, True)
                       and labels_match(terminal, ACCOUNTS[0], 95))
        focused = card(terminal, 95)
        unfocused = card(terminal, 96)
        require(terminal.screen.styles[focused["row"]][focused["column"]][1]
                != terminal.screen.styles[unfocused["row"]][unfocused["column"]][1],
                "focused read mail lacks its independent selection background")
        require(reader_contains(terminal.screen, "Read · ⭐ Starred"),
                "read/starred state absent from the selected reader header")
        terminal.send(b"q")
        terminal.until(lambda: status_matches(terminal, 96, True, True)
                       and status_matches(terminal, 95, False, True))
        terminal.send(b"gg")
        terminal.until(lambda: labels_match(terminal, ACCOUNTS[0]))
        terminal.send(b"s")
        terminal.until(lambda: status_matches(terminal, 96, True, False)
                       and reader_contains(terminal.screen, "● Unread")
                       and not reader_contains(terminal.screen, "Starred"))
        terminal.send(b"s")
        terminal.until(lambda: status_matches(terminal, 96, True, True)
                       and reader_contains(terminal.screen, "● Unread · ⭐ Starred"))
        terminal.send(b"u")
        terminal.until(lambda: status_matches(terminal, 96, False, True)
                       and reader_contains(terminal.screen, "Read · ⭐ Starred")
                       and not reader_contains(terminal.screen, "Unread"))
        require(terminal.screen.styles[card(terminal, 96)["row"]][card(terminal, 96)["column"]][2] is False,
                "selected read subject remained bold after marking it read")
        terminal.send(b"u")
        terminal.until(lambda: status_matches(terminal, 96, True, True)
                       and reader_contains(terminal.screen, "● Unread · ⭐ Starred"))
        # Preserve the actual VT cells while resizing. A fresh screen would
        # hide stale row styles and wide-glyph debris instead of detecting it.
        for columns, rows, layout in ((100, 30, "below"), (48, 24, "below"), (160, 42, "right")):
            terminal.resize(columns, rows)
            terminal.send(f":layout {layout}\r".encode())
            terminal.until(lambda: status_matches(terminal, 96, True, True)
                           and status_matches(terminal, 95, False, True))
            require(terminal.screen.wide_right_edge == 0,
                    "status star crossed the owned terminal's physical right edge")
        terminal.finish()
        with Client(binary, directory, extra=options(source, 96)) as client:
            for account in ACCOUNTS[:2]:
                message = client.request("mail.read", account, messageId="shared-msg-096", cacheOnly=True)
                require("STARRED" in message["labels"] and "UNREAD" in message["labels"],
                        "star/read presentation lost the independent cached labels")
                require(client.request("cache.stats", account, cacheOnly=True)["fixtureSends"] == 0,
                        "status-only workflow sent synthetic mail")
        print("PASS mail status: independent bulk/unread/star gutters; bold unread and normal selected read subjects; star/read changes and wide/narrow preserved resizes")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def reader_labels(binary, directory):
    source = setup(binary, directory)
    terminal = start(binary, directory, source)
    try:
        terminal.until(lambda: labels_match(terminal, ACCOUNTS[0]))
        require(reader_contains(terminal.screen, "● Unread · ⭐ Starred"),
                "unread/starred state absent from the reader header")
        terminal.send(b"2")
        terminal.until(lambda: labels_match(terminal, ACCOUNTS[1]))
        terminal.send(b"1")
        terminal.until(lambda: labels_match(terminal, ACCOUNTS[0]))
        # Expanded 48-column reading is narrow enough that the literal custom
        # label must wrap, while still leaving the fictional body navigable.
        terminal.send(b"z")
        terminal.until(lambda: "z/q Shrink" in terminal.screen.lines()[-2])
        terminal.resize(48, 24)
        terminal.until(lambda: labels_match(terminal, ACCOUNTS[0]))
        label_rows = [text for _, text in reader_rows(terminal.screen)
                      if "Labels:" in text or "Éruption" in text or "comfortably" in text
                      or "reader widths" in text]
        require(len(label_rows) >= 2, "narrow reader truncated labels instead of wrapping them")
        require(terminal.screen.wide_right_edge == 0,
                "wrapped label text crossed the owned terminal's physical right edge")
        terminal.resize(160, 42)
        terminal.until(lambda: labels_match(terminal, ACCOUNTS[0]))
        terminal.finish()
        print("PASS reader labels: friendly system/custom names, wrapped long Unicode labels, shared-ID account isolation and visible read/star state")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=("list-status", "reader-labels"))
    arguments = parser.parse_args()
    cases = {"list-status": list_status, "reader-labels": reader_labels}
    with tempfile.TemporaryDirectory(prefix="omagma-mail-status-") as directory:
        for name in (arguments.case,) if arguments.case else cases:
            cases[name](arguments.binary.resolve(), Path(directory) / name)


if __name__ == "__main__":
    main()
