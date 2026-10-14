#!/usr/bin/env python3
"""Owned synthetic follow-up persistence, conflict and offline native UX checks."""
import argparse
import datetime
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile

from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start, click, point
from terminal_reader_context import command
from terminal_reader import reader_contains
from terminal_reader_next_ux import fixture, capture
from terminal_cache import ProviderFixture

MESSAGE = "shared-msg-096"


def entries(binary, root, source, account=ACCOUNTS[0]):
    with Client(binary, root, extra=source.options()) as client:
        return client.request("reminder.list", account)["entries"]


def lifecycle(binary, root, captures):
    source = fixture(binary, root)
    preferences = root / "ui" / "settings.json"
    extra = ("--ui-file", str(preferences), "--prefetch-bodies", "0")
    terminal = start(binary, root, source, extra=extra, columns=100, rows=30)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "PLAIN-ALTERNATIVE"))
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text() and "Tomorrow" in terminal.text())
        capture(terminal, captures, "follow-up-new-editor")
        terminal.send(b"\r")
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        saved = entries(binary, root, source)
        require(len(saved) == 1 and saved[0]["messageId"] == MESSAGE, "preset lost selected message identity")
        require(saved[0]["dueDate"] == (datetime.date.today() + datetime.timedelta(days=1)).isoformat(),
                "Tomorrow did not save the next local civil date")
        require(not entries(binary, root, source, ACCOUNTS[1]), "reminder leaked into another account")
        # Moving from the date field into presets must not skip to Done.
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        terminal.send(b"\x1b[B\r")
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        require(len(entries(binary, root, source)) == 1, "one Down from date unexpectedly removed the reminder")
        # Keyboard preset -> Tab -> Save must persist the date that was chosen.
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        terminal.send(b"\x1b[Bk\t\r")
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        today = datetime.date.today().isoformat()
        require(entries(binary, root, source)[0]["dueDate"] == today, "Tab Save ignored the selected Today preset")
        # Typing and tabbing through presets never silently replaces a date.
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        terminal.send(b"\x152030-05-17\t\x13")
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        require(entries(binary, root, source)[0]["dueDate"] == "2030-05-17", "Ctrl+S after Tab discarded the custom date")
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        click(terminal, *point(terminal, "Today"))
        terminal.until(lambda: today in terminal.text())
        click(terminal, *point(terminal, "[Ctrl+S Save date]"))
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        require(entries(binary, root, source)[0]["dueDate"] == today, "mouse Save ignored the selected preset")
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        capture(terminal, captures, "follow-up-existing-editor")
        terminal.send(b"\x15done\x13")
        terminal.until(lambda: "InvalidFollowUpDate" in terminal.text())
        require(entries(binary, root, source)[0]["dueDate"] == today, "typing done into Date removed or changed the reminder")
        terminal.send(b"\x152000-01-01\x13")
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        command(terminal, "follow-ups")
        terminal.until(lambda: "Overdue" in terminal.text() and "Follow-ups" in terminal.text())
        capture(terminal, captures, "follow-ups-due-list")
        terminal.resize(58, 22)
        terminal.gap(.2)
        require("Enter Mail" in terminal.screen.lines()[-2], "narrow follow-up list hides how to read its message")
        capture(terminal, captures, "follow-ups-narrow-list")
        terminal.resize(100, 30)
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()

    # The account document outlives all cached mail. Removing the synthetic
    # provider target also proves an unavailable message cannot eat its reminder.
    with Client(binary, root, extra=source.options()) as client:
        before = client.request("cache.stats")
        state = client.request("reminder.list")["entries"]
        require(state[0]["dueDate"] == "2000-01-01", "edited reminder did not survive TUI exit")
        require(client.request("cache.stats")["fixtureCalls"] == before["fixtureCalls"],
                "local reminder reads contacted the provider")
        cleared = client.request("cache.clear")
        require(cleared["followUpsPreserved"], "cache cleanup omitted follow-up retention")
        require(client.request("reminder.list")["entries"] == state, "cache cleanup erased reminder metadata")
    for account in ACCOUNTS:
        source.data[account]["baseline"]["messages"] = [message for message in source.data[account]["baseline"]["messages"]
                                                        if message["id"] != MESSAGE]
        source.stage(account, "baseline")
    terminal = start(binary, root, source, extra=extra + ("--fixture-scenario", "offline-refresh"), columns=100, rows=30)
    try:
        terminal.until(lambda: "Refresh failed" in terminal.text() or "Offline" in terminal.text())
        command(terminal, "follow-ups")
        terminal.until(lambda: "Overdue" in terminal.text() and "not available offline" in terminal.text() and "Reminder kept" in terminal.text())
        capture(terminal, captures, "follow-ups-offline-message")
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text())
        old = entries(binary, root, source)[0]
        with Client(binary, root, extra=source.options()) as client:
            client.request("reminder.set", messageId=MESSAGE, dueDate="2000-01-02", expectedVersion=old["version"])
        terminal.send(b"\x152000-01-03\x13")
        terminal.until(lambda: "Not saved · changed elsewhere" in terminal.text())
        require(entries(binary, root, source)[0]["dueDate"] == "2000-01-02", "stale editor overwrote newer date")
        capture(terminal, captures, "follow-ups-version-conflict")
        terminal.send(b"b")
        terminal.until(lambda: "Date YYYY-MM-DD" in terminal.text() and "2000-01-02" in terminal.text())
        terminal.send(b"\x152000-01-04\x13")
        terminal.until(lambda: "Local follow-up saved" in terminal.text() and "Date YYYY-MM-DD" not in terminal.text())
        require(entries(binary, root, source)[0]["dueDate"] == "2000-01-04", "offline edit required forgotten mail")
        terminal.send(b"\r")
        terminal.until(lambda: "not found" in terminal.text().lower() or "MessageNotFound" in terminal.text())
        require(len(entries(binary, root, source)) == 1, "missing provider message removed its reminder")
        terminal.send(b"q")
        terminal.send(b"d")
        terminal.until(lambda: "Follow-up done" in terminal.text() and "No follow-ups" in terminal.text())
        require(not entries(binary, root, source), "Done did not persist local completion")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    print("PASS local follow-ups: presets, edits, due list, restart, cache clear, isolation, offline target, stale version, explicit done")


def evicted_metadata(binary, root):
    source = ProviderFixture(root)
    extra = source.options("--metadata-limit", "1", "--prefetch-bodies", "0")
    old_id = "shared-msg-001"
    with Client(binary, root, extra=extra) as client:
        client.request("mail.read", messageId=MESSAGE)
        old = client.request("mail.read", messageId=old_id)
        retained = client.request("mail.list", cacheOnly=True)["messages"]
        require([item["id"] for item in retained] == [MESSAGE], "quota fixture did not evict older displayed metadata")
        saved = client.request("reminder.set", messageId=old_id, dueDate="2026-10-14", expectedVersion=0,
                               snapshot={"subject": "Untrusted caller", "threadId": "wrong"})["entry"]
        require(saved["subject"] == old["subject"] and saved["threadId"] == old["threadId"],
                "uncached follow-up trusted caller fields or lost exact provider identity")
        require([item["id"] for item in client.request("mail.list", cacheOnly=True)["messages"]] == [MESSAGE],
                "follow-up metadata read changed cache retention")
        client.request("reminder.done", messageId=old_id, expectedVersion=saved["version"])
        source.stage(ACCOUNTS[0], "baseline", held=True)
        try:
            with ThreadPoolExecutor(max_workers=1) as executor:
                pending = executor.submit(client.request, "reminder.set", messageId=old_id,
                                          dueDate="2026-10-15", expectedVersion=0, ok=False)
                source.wait_entered(client.process)
                with Client(binary, root, extra=extra) as concurrent:
                    # This must complete while the first provider read is held:
                    # the follow-up path must release the account Store lock.
                    concurrent.request("cache.clear")
                    concurrent.request("mail.read", messageId=old_id)
                    newer = concurrent.request("reminder.set", messageId=old_id, dueDate="2026-10-16", expectedVersion=0)
                source.release()
                require(pending.result(timeout=8)["code"] == "FollowUpChanged", "unlocked provider read overwrote a concurrent reminder")
                require(client.request("reminder.list")["entries"][0] == newer["entry"], "stale follow-up changed committed snapshot")
        finally:
            source.release()
            source.stage(ACCOUNTS[0], "baseline")
    with Client(binary, root, scenario="offline-refresh", extra=extra) as offline:
        entry = offline.request("reminder.list")["entries"][0]
        offline.request("reminder.set", messageId=old_id, dueDate="2026-10-17", expectedVersion=entry["version"])
        absent = offline.request("reminder.set", messageId="shared-msg-002", dueDate="2026-10-17", expectedVersion=0, ok=False)
        require(absent["code"] == "FollowUpMetadataUnavailableOffline", "uncached offline creation omitted reconnect explanation")
    print("PASS follow-up quota eviction: exact provider identity, no retention, unlocked fetch, concurrent version, offline edit/error")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-follow-ups-") as temporary:
        root = Path(temporary)
        evicted_metadata(args.binary.resolve(), root / "quota")
        lifecycle(args.binary.resolve(), root / "lifecycle", args.capture_dir)


if __name__ == "__main__":
    main()
