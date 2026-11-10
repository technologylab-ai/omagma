#!/usr/bin/env python3
"""Decoded Gmail Subject scalars and persisted refusals through CLI and owned PTY.

Synthetic provider data only; never uses desktop input or a real mailbox.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

from terminal_integration import ACCOUNTS, FIXTURES, Client, require
from terminal_mail_acceptance import AcceptanceScreen
from terminal_pty import Terminal
from terminal_reader import reader_contains


GOOD = "decoded-subject"
BAD = "invalid-structured-header"
SUBJECT = "A colleague shared a story. More café…"
BODY = "Readable full body."


def exercise(binary, directory, old_binary=None, terminal_type=Terminal):
    provider = directory / "provider"
    shutil.copytree(FIXTURES / "accounts", provider / "accounts")
    path = provider / "accounts/personal.json"
    source = json.loads(path.read_text())
    # Hand-written API shape; neither the MIME encoder nor fixture generator
    # supplies the decoded header scalar or these literal base64url body bytes.
    good = {
        "id": GOOD, "threadId": "decoded-subject-thread", "internalDate": "1794300000000",
        "labelIds": ["INBOX", "UNREAD"], "snippet": "Only a preview, never the body oracle.",
        "payload": {"mimeType": "multipart/alternative", "headers": [
            {"name": "From", "value": "Example Updates <updates@example.test>"},
            {"name": "To", "value": ACCOUNTS[0]},
            {"name": "Subject", "value": "A colleague shared a story.\nMore café…"},
            {"name": "Message-ID", "value": "<decoded-subject@example.test>"},
        ], "parts": [
            {"mimeType": "text/plain", "headers": [], "body": {"size": 19, "data": "UmVhZGFibGUgZnVsbCBib2R5Lg"}},
            {"mimeType": "text/html", "headers": [], "body": {"size": 26, "data": "PHA-UmVhZGFibGUgZnVsbCBib2R5LjwvcD4"}},
        ]},
    }
    bad = json.loads(json.dumps(good))
    bad.update(id=BAD, threadId="invalid-header-thread", internalDate="1794290000000")
    bad["payload"]["headers"][0]["value"] = "updates@example.test\nBcc: hidden@example.test"
    bad["payload"]["headers"][2]["value"] = "Strict structured field"
    source.update(messages=[good, bad], generation=100, sync={"historyId": "100", "history": []})
    path.write_text(json.dumps(source, ensure_ascii=False) + "\n")
    client_root = directory / "client"
    options = ("--fixture-root", str(provider), "--prefetch-bodies", "0")
    with Client(old_binary or binary, client_root, extra=options) as client:
        client.request("mail.list", label="INBOX")
        if old_binary:
            refused = client.request("mail.read", messageId=GOOD)
            require(refused["bodyCacheError"] == "InvalidHeaders" and not refused["bodyText"],
                    "old binary did not reproduce the actual Subject failure")
            refused = client.request("mail.read", messageId=BAD)
            require(refused["bodyCacheError"] == "InvalidHeaders", "old structured refusal missing")
    cache = client_root / "cache/fixtures" / hashlib.sha256(ACCOUNTS[0].encode()).hexdigest()
    index = cache / "index.json"
    state = json.loads(index.read_text())
    state["decoderRevision"] = 5
    for entry in state["entries"]:
        require(entry["bytes"] == 0, "migration fixture unexpectedly contains a cached body")
        entry["bodyError"] = "InvalidHeaders"
        entry["message"].update(decodeWarning="InvalidHeaders", metadataPartial=True)
    index.write_text(json.dumps(state) + "\n")
    original_ids = {entry["message"]["id"] for entry in state["entries"]}
    with Client(binary, client_root, extra=options) as client:
        message = client.request("mail.read", messageId=GOOD)
        require(message["subject"] == SUBJECT, "decoded Subject was not flattened")
        require(message["bodyText"] == BODY and message["bodyHtml"] == "<p>" + BODY + "</p>", "body or HTML was lost")
        require(message["from"]["address"] == "updates@example.test" and message["to"][0]["address"] == ACCOUNTS[0], "envelope remains in display fallback")
        require(not message["decodeWarning"] and not message["bodyCacheError"] and not message["metadataPartial"], "old refusal survived successful refetch")
        # A decoded line break inside a structured field is display whitespace
        # too: the message stays readable and the text after it never becomes
        # a header or a recipient.
        hostile = client.request("mail.read", messageId=BAD)
        require(hostile["bodyText"] == BODY and not hostile["bodyCacheError"], "one odd header refused the whole message")
        require(hostile["from"]["address"] == "updates@example.test", "sender was not recovered from the odd header")
        require("hidden@example.test" not in json.dumps([hostile["from"], hostile["to"], hostile["cc"], hostile["replyTo"]]),
                "text after a decoded line break became a recipient")
        hostile_reply = client.request("mail.reply", messageId=BAD, all=True)
        require("hidden@example.test" not in json.dumps([hostile_reply["to"], hostile_reply["cc"], hostile_reply.get("bcc", [])]),
                "reply addressed an injected recipient")
        client.request("draft.discard", draftId=hostile_reply["id"])
        draft = client.request("mail.reply", messageId=GOOD)
        require(draft["subject"] == "Re: " + SUBJECT and draft["to"][0]["address"] == "updates@example.test", "reply cannot use normalized metadata")
        client.request("draft.discard", draftId=draft["id"])
        before = client.request("cache.stats", cacheOnly=True)
        client.restart()
        for identifier in (GOOD, BAD):
            client.request("mail.read", messageId=identifier)
        after = client.request("cache.stats", cacheOnly=True)
        require(after["fixtureCalls"] == before["fixtureCalls"] and after["syncBodyGets"] == before["syncBodyGets"], "restart refetched accepted body or current refusal")
        require(after["fixtureSends"] == 0, "reading or replying sent email")
    migrated = json.loads(index.read_text())
    require(migrated["decoderRevision"] == 7 and {entry["message"]["id"] for entry in migrated["entries"]} == original_ids, "migration lost retained identities")
    terminal = terminal_type(binary, client_root, extra=options, columns=160, rows=42, screen_type=AcceptanceScreen)
    try:
        terminal.until(lambda: not terminal.screen.frame_open and reader_contains(terminal.screen, BODY))
        text = terminal.text()
        require("Body unavailable" not in text and "InvalidHeaders" not in text, "recovered reader still shows refusal")
        require("updates@example.test" in text, "reader lost sender identity")
        terminal.finish()
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--old-binary", type=Path)
    args = parser.parse_args()
    terminal_type = Terminal
    if sys.platform == "darwin":
        from terminal_macos import DarwinTerminal
        terminal_type = DarwinTerminal
        tempfile.tempdir = str(Path("/tmp").resolve())
    with tempfile.TemporaryDirectory(prefix="omagma-subject-newlines-") as root:
        exercise(args.binary.resolve(), Path(root), args.old_binary.resolve() if args.old_binary else None, terminal_type)
    print("PASS Gmail Subject newlines: legacy recovery, strict structured headers, restart, reply and TUI body")


if __name__ == "__main__":
    main()
