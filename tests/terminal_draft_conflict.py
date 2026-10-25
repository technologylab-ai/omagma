#!/usr/bin/env python3
"""Owned PTY: a preflight saved-draft conflict preserves both clients' text."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, require
from terminal_gmail_drafts import upload
from terminal_markdown_compose import direct_send_settings
from terminal_mouse import click, point
from terminal_reader_editor import MouseTerminal, ReaderScreen
from terminal_reader_next_ux import capture


def exercise(binary, root, captures, with_warning=False):
    local = "ORIGINAL_LOCAL_NOTE"
    remote = "OTHER_CLIENT_CURRENT_NOTE"
    extra = " + DIRTY_LOCAL_ADDITION_🌋"
    with Client(binary, root) as client:
        source = client.request("draft.create", draft={
            "to": [{"address": "peer@example.test"}], "subject": "Concurrent draft conflict",
            "bodyText": local})
        inherited_link = None
        if with_warning:
            linked = upload(client, source)
            taken_back = client.request("draft.gmail-take-back", draftId=source["id"],
                                        expectedVersion=linked["link"]["version"])
            inherited_link = taken_back["link"]
            require(not inherited_link["paused"], "fixture takeback left source paused")
    terminal = MouseTerminal(binary, root, screen_type=ReaderScreen, columns=120, rows=40,
                             extra=direct_send_settings(root),
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: "Ready" in terminal.text())
        terminal.send(b"h")
        terminal.until(lambda: terminal.screen.locate("MAILBOXES") is not None)
        x, y = point(terminal, "MAILBOXES")
        click(terminal, x + 2, y + 3)
        terminal.until(lambda: "Concurrent draft conflict" in terminal.text())
        terminal.gap(.5)
        terminal.send(b"\r")
        terminal.until(lambda: "Local draft · no mail sent" in terminal.text())
        terminal.send(b"\x13")
        terminal.until(lambda: "Review send" in terminal.text() and "bytes · exact" in terminal.text())
        if with_warning:
            require("[g I checked Gmail]" in terminal.text(), "source Gmail warning was not loaded")
            terminal.send(b"g")
            terminal.until(lambda: "[g Acknowledged]" in terminal.text())
        with Client(binary, root) as client:
            client.request("draft.update", draftId=source["id"], draft={
                "to": [{"address": "peer@example.test"}], "subject": "Concurrent draft conflict",
                "bodyText": remote, "original": {"from": {"address": "author@example.test"},
                    "bodyText": "REMOTE_ONLY_ORIGINAL", "bodyHtml": "<p>REMOTE_ONLY_ORIGINAL</p>"}})
            if with_warning:
                inherited_link = client.request("draft.read", draftId=source["id"])["gmailLink"]
        terminal.send(b"y")  # The reviewed digest must fail before any provider write.
        terminal.until(lambda: "changed elsewhere" in terminal.text() and ":resolve-draft" in terminal.text())
        require("Submission receipt" not in terminal.text(), "known preflight refusal became an unknown send")
        x, y = point(terminal, "Body:")
        click(terminal, x, y + 1)
        terminal.send(b"\x1b")
        terminal.gap(.1)
        lock = root / "cache/fixtures" / hashlib.sha256(ACCOUNTS[0].encode()).hexdigest() / "lock"
        # Hold only this fixture's native cache so the read response arrives
        # after a clean reload has started and new editing keys have arrived.
        # One PTY write preserves key order; no runtime timing hooks are added.
        with lock.open("r+b") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            try:
                terminal.send(b":reload-draft\ri\x05" + extra.encode())
                terminal.until(lambda: "DIRTY_LOCAL_ADDITION" in terminal.text(), seconds=.20)
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)
        terminal.until(lambda: "Save local copy" in terminal.text() and "Reload saved draft" in terminal.text())
        require(local in terminal.text() and remote not in terminal.text(),
                "pending reload overwrote newer local keystrokes")
        for columns, rows in ((38, 24), (64, 24), (120, 40)):
            terminal.resize(columns, rows)
            terminal.until(lambda: "Save local copy" in terminal.text() and "[Use choice]" in terminal.text())
            capture(terminal, captures, f"draft-conflict-{columns}x{rows}")
        # Back is the default. Tab enters the list, j selects Reload.
        terminal.send(b"\tj\r")
        terminal.until(lambda: "Local edits are unsaved" in terminal.text())
        with Client(binary, root) as client:
            require(client.request("draft.read", draftId=source["id"])["bodyText"] == remote,
                    "rejected reload or autosave overwrote the other client's source")
            require(len(client.request("draft.list")["drafts"]) == 1, "reload silently made a copy")
        terminal.send(b"\x13")  # Reopen resolution while preserving INSERT.
        terminal.until(lambda: "Save local copy" in terminal.text())
        terminal.send(b"\t\r")  # Explicitly keep the local snapshot independently.
        terminal.until(lambda: "Local edits saved as a new draft" in terminal.text())
        require("Body: INSERT" in terminal.text(), "manual copy acknowledgement left INSERT")
        if with_warning:
            require("Gmail copy kept" in terminal.text(), "copy acknowledgement did not expose inherited warning")
            with Client(binary, root) as client:
                fresh = [row for row in client.request("draft.list")["drafts"] if row["id"] != source["id"]]
                require(len(fresh) == 1, "warning recovery did not create exactly one new draft")
                fresh_copy = client.request("draft.read", draftId=fresh[0]["id"])
                fresh_link = fresh_copy.get("gmailLink")
                require(fresh_link is not None and fresh_link["draftId"] == fresh_copy["id"]
                        and fresh_link["version"] == 1 and fresh_link["paused"] is False,
                        "recovery acknowledgement did not create a fresh warning identity")
        terminal.send(b"qQg")
        terminal.until(lambda: "ADDITION_🌋qQg" in terminal.text())
        terminal.until(lambda: "Draft saved locally" in terminal.text())
        extra += "qQg"
        capture(terminal, captures, "draft-copy-insert-preserved")
        with Client(binary, root) as client:
            active = client.request("draft.list")["drafts"]
            copies = [row for row in active if row["id"] != source["id"]]
            require(len(copies) == 1, "explicit copy did not create exactly one new draft")
            copied_id = copies[0]["id"]
            copied = client.request("draft.read", draftId=copied_id)
            require(copied["recoveryFields"][4] == local + extra, "local copy changed authored bytes")
            require(copied.get("original") is None, "local copy inherited the other client\'s newly added original")
            if with_warning:
                kept_link = copied.get("gmailLink")
                require(kept_link is not None and kept_link["draftId"] == copied_id
                        and kept_link["version"] > 1 and kept_link["paused"] is False,
                        "recovery copy lost or misidentified the Gmail warning")
                for key in ("remoteDraftId", "remoteMessageId", "attemptMessageId", "uploadedDigest"):
                    require(kept_link[key] == inherited_link[key], "recovery changed remote Gmail provenance")
                require(not kept_link.get("sendAcknowledgedDigest") and not kept_link.get("lastImportedDraftId"),
                        "recovery inherited old acknowledgement or import bookkeeping")
            require(client.request("draft.read", draftId=source["id"])["bodyText"] == remote,
                    "local copy altered the other client's saved source")
            require(client.request("cache.stats")["fixtureSends"] == 0, "preflight conflict submitted mail")
        if with_warning:
            terminal.send(b"\x13")
            terminal.until(lambda: "Review send" in terminal.text() and "bytes · exact" in terminal.text())
            require("Gmail copy kept:" in terminal.text() and "[g I checked Gmail]" in terminal.text(),
                    "actual recovery acknowledgement did not restore the visible send warning")
            terminal.send(b"y")
            terminal.gap(.1)
            with Client(binary, root) as client:
                require(client.request("cache.stats")["fixtureSends"] == 0,
                        "recovery copy sent without a fresh Gmail acknowledgement")
            terminal.send(b"g")
            terminal.until(lambda: "[g Acknowledged]" in terminal.text())
            terminal.send(b"\x1b")
            terminal.until(lambda: "Body:" in terminal.text())
            x, y = point(terminal, "Body:")
            click(terminal, x, y + 1)
            later = " + AFTER_GMAIL_ACK"
            terminal.send(b"\x05" + later.encode())
            terminal.until(lambda: "AFTER_GMAIL_ACK" in terminal.text())
            terminal.send(b"\x13")
            terminal.until(lambda: "Review send" in terminal.text() and "bytes · exact" in terminal.text())
            require("[g I checked Gmail]" in terminal.text() and "[g Acknowledged]" not in terminal.text(),
                    "new typing retained a Gmail acknowledgement for old content")
            terminal.send(b"y")
            terminal.gap(.1)
            extra += later
            capture(terminal, captures, "recovery-copy-warning-requires-fresh-ack")
            with Client(binary, root) as client:
                require(client.request("cache.stats")["fixtureSends"] == 0,
                        "new local content sent using an old Gmail acknowledgement")
                require(client.request("draft.read", draftId=source["id"])["gmailLink"] == inherited_link,
                        "recovery changed the original source's Gmail ownership")
        result = terminal.finish()
        with Client(binary, root) as client:
            copied = client.request("draft.read", draftId=copied_id)
            require((copied.get("recoveryFields") or [None] * 4 + [copied["bodyText"]])[4] == local + extra,
                    "exit lost the independently recovered note")
            if with_warning:
                require(copied.get("gmailLink", {}).get("paused") is False,
                        "restart lost the inherited Gmail-copy warning")
        return {**result, "preflightRefusedWithoutSend": True, "dirtyReloadRefused": True,
                "bothClientsTextRetained": True, "explicitCopySurvivesExit": True,
                "inflightReloadKeystrokesRetained": True, "manualCopyPreservesInsert": True,
                "qQgRemainTextAndAutosave": True, "inheritedGmailWarning": with_warning,
                "freshGmailAcknowledgementRequiredAfterRecoveryAndEdit": with_warning}
    except Exception:
        print(terminal.text(), flush=True)
        capture(terminal, captures, "draft-conflict-failure")
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--captures", type=Path)
    parser.add_argument("--case", action="append", choices=("plain", "gmail-warning"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    print(json.dumps(read_build_info(binary)), flush=True)
    for case in args.case or ("plain", "gmail-warning"):
        with tempfile.TemporaryDirectory(prefix="omagma-draft-conflict-") as temporary:
            captures = args.captures / case if args.captures else None
            print(json.dumps({"case": case, **exercise(binary, Path(temporary).resolve(), captures,
                                                      with_warning=case == "gmail-warning")}), flush=True)


if __name__ == "__main__":
    main()
