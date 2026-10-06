#!/usr/bin/env python3
"""Local timezone displays in isolated synthetic PTYs; runtime grant required."""
from __future__ import annotations

import argparse
import base64
import copy
from datetime import datetime
import json
from pathlib import Path
import tempfile
from zoneinfo import ZoneInfo

from probes.cache_refresh_fixture import repage
from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start
from terminal_reader import reader_contains

# Literal UTC wire values, not values obtained by reversing the UI formatter.
MAIL = (
    ("timezone-rollover", "TZ ROLLOVER", 1794095100000),  # 2026-11-07 23:45Z
    ("timezone-winter", "TZ WINTER", 1794054840000),      # 2026-11-07 12:34Z
    ("timezone-summer", "TZ SUMMER", 1780835640000),      # 2026-06-07 12:34Z
)
SYNC_MS = 1794054840000
THREAD = "timezone-thread"
CASES = ("vienna", "kathmandu", "utc", "localtime", "invalid")
EXPECTED = {
    "vienna": ("Europe/Vienna", (
        "2026-11-08 00:45 CET", "2026-11-07 13:34 CET", "2026-06-07 14:34 CEST")),
    "kathmandu": ("Asia/Kathmandu", (
        "2026-11-08 05:30 +0545", "2026-11-07 18:19 +0545", "2026-06-07 18:19 +0545")),
    "utc": ("UTC0", (
        "2026-11-07 23:45 UTC", "2026-11-07 12:34 UTC", "2026-06-07 12:34 UTC")),
    "invalid": ("Omagma/ZoneDoesNotExist", (
        "2026-11-07 23:45 UTC (TZ unavailable)",
        "2026-11-07 12:34 UTC (TZ unavailable)",
        "2026-06-07 12:34 UTC (TZ unavailable)")),
}


def expected_case(name):
    if name != "localtime":
        zone, stamps = EXPECTED[name]
        if name in ("vienna", "kathmandu"):
            require((Path("/usr/share/zoneinfo") / zone).is_file(), "fixture timezone database unavailable")
        return zone, stamps
    # An independent system-zone oracle permits this test to run on a host
    # whose localtime differs from the developer's Europe/Vienna setting.
    with Path("/etc/localtime").open("rb") as handle:
        zone = ZoneInfo.from_file(handle)
    stamps = tuple(datetime.fromtimestamp(ms / 1000, zone).strftime("%Y-%m-%d %H:%M %Z") for _, _, ms in MAIL)
    return None, stamps


def fixture_setup(binary, directory):
    fixture = ProviderFixture(directory)
    source = fixture.data[ACCOUNTS[0]]["baseline"]
    template = source["messages"][0]
    messages = []
    for message_id, subject, millis in MAIL:
        message = copy.deepcopy(template)
        body = f"BODY {subject}\nControlled fictional timezone message.\n".encode()
        message.update(id=message_id, threadId=THREAD, internalDate=str(millis),
                       labelIds=["INBOX", "UNREAD"], snippet=f"SNIPPET {subject}", sizeEstimate=len(body))
        message["payload"] = {
            "partId": "", "mimeType": "text/plain", "filename": "",
            "headers": [
                {"name": "From", "value": "Timezone Fixture <clock@example.org>"},
                {"name": "To", "value": ACCOUNTS[0]},
                {"name": "Subject", "value": subject},
                {"name": "Message-ID", "value": f"<{message_id}@example.org>"},
                {"name": "Content-Type", "value": "text/plain; charset=utf-8"},
            ],
            "body": {"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")},
        }
        messages.append(message)
    source["messages"] = messages
    repage(source)
    fixture.stage(ACCOUNTS[0], "baseline")
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.refresh", limit=3, prefetchLimit=3, label="INBOX")
        for message_id, _, millis in MAIL:
            message = client.request("mail.read", cacheOnly=True, messageId=message_id)
            require(message["receivedAt"] == millis, "seed changed UTC wire milliseconds")
        thread = client.request("mail.thread", cacheOnly=True, threadId=THREAD)
        require({item["id"] for item in thread["messages"]} == {item[0] for item in MAIL}, "seed lost timezone thread messages")
    require(client.process.returncode == 0 and not client.stderr, "timezone seed child cleanup failed")
    indices = []
    for path in (directory / "cache").rglob("index.json"):
        value = json.loads(path.read_text())
        if value.get("account") != ACCOUNTS[0]:
            continue
        # The owned fixture refresh is held below, so this known persisted
        # success stamp remains observable without replacing the process clock.
        value["lastSyncAt"] = SYNC_MS
        for view in value.get("views", []):
            view["lastSyncAt"] = SYNC_MS
        path.write_text(json.dumps(value, ensure_ascii=False) + "\n")
        indices.append(path)
    require(len(indices) == 1, "owned account cache index was not unique")
    fixture.stage(ACCOUNTS[0], "baseline", held=True)
    return fixture


def mail_rows(terminal):
    title = terminal.screen.locate("Mail ·")
    if title is None:
        return []
    y, x = title["row"], title["column"]
    cells = terminal.screen.cells
    left = next((i for i in range(x, -1, -1) if cells[y][i] in "╭┌╔"), None)
    right = next((i for i in range(x, terminal.columns) if cells[y][i] in "╮┐╗"), None)
    if left is None or right is None:
        return []
    bottom = next((i for i in range(y + 1, terminal.rows)
                   if cells[i][left] in "╰└╚" and cells[i][right] in "╯┘╝"), None)
    if bottom is None:
        return []
    return ["".join(cells[i][left + 1:right]) for i in range(y + 1, bottom)]


def list_dates_match(terminal, stamps):
    rows = mail_rows(terminal)
    return all(any(subject in row and stamp[5:16] in row for row in rows)
               for (_, subject, _), stamp in zip(MAIL, stamps))


def run_case(binary, directory, name):
    zone, stamps = expected_case(name)
    fixture = fixture_setup(binary, directory)
    terminal = start(binary, directory, fixture, environment={"TZ": zone}, columns=180, rows=40)
    try:
        fixture.wait_entered(terminal.process, pump=terminal.pump)
        terminal.until(lambda: list_dates_match(terminal, stamps) and reader_contains(terminal.screen, "BODY TZ ROLLOVER"))
        terminal.until(lambda: f"Synced {stamps[1]}" in terminal.screen.lines()[1])
        require(fixture.is_held(), "sync assertion raced released fixture refresh")
        if name == "invalid":
            require("TZ unavailable" in terminal.screen.lines()[1], "invalid timezone silently fell back to UTC")

        # A single-message preview shows the full local stamp. Thread cards
        # avoid a duplicate envelope date and use the matching compact stamp.
        require(reader_contains(terminal.screen, stamps[0]), "preview full date differs from compact list")
        terminal.send(b"\rz")
        terminal.until(lambda: reader_contains(terminal.screen, "3/3 mails")
                       and reader_contains(terminal.screen, f"▾ 3/3 ● Timezone Fixture · {stamps[0][5:16]}")
                       and reader_contains(terminal.screen, "BODY TZ ROLLOVER"))
        for index in (1, 2):
            # Earlier cards start folded; focus it, then expand its body.
            terminal.send(b"{t")
            terminal.until(lambda i=index: reader_contains(terminal.screen, f"{3 - i}/3 mails")
                           and reader_contains(terminal.screen, f"BODY {MAIL[i][1]}")
                           and reader_contains(terminal.screen, f"▾ {3 - i}/3 ● Timezone Fixture · {stamps[i][5:16]}"))
        require(fixture.is_held(), "thread assertions exceeded the bounded refresh hold")

        with Client(binary, directory, extra=fixture.options()) as client:
            for message_id, _, millis in MAIL:
                message = client.request("mail.read", cacheOnly=True, messageId=message_id)
                require(message["receivedAt"] == millis, "UI timezone leaked into backend/cache timestamps")
            require(client.request("cache.stats")["fixtureSends"] == 0, "timezone display sent mail")
        require(client.process.returncode == 0 and not client.stderr, "timezone oracle child cleanup failed")
        fixture.release()
        terminal.finish()
        print(f"PASS timezone:{name}: sync/list/preview/thread winter+summer+rollover, UTC storage unchanged, owned TTY restored")
    except Exception:
        print(terminal.text())
        raise
    finally:
        fixture.release()
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=CASES, action="append")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-terminal-timezone-") as temporary:
        for name in args.case or CASES:
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            run_case(args.binary.resolve(), directory, name)


if __name__ == "__main__":
    main()
