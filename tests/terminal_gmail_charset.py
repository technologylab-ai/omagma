#!/usr/bin/env python3
"""Gmail-transcoded legacy text and an already-cached body through owned PTYs."""
import argparse
import base64
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

IDENTIFIER = "legacy-charset-message"
PLAIN = "Guten Tag!\nDie Gebühr fällt heute an.\nMit freundlichen Grüßen\nUnsere Öffnungszeiten."
HTML = "<p>Formatted view: Die Gebühr fällt heute an.</p><p>Mit freundlichen Grüßen</p><p>Unsere Öffnungszeiten.</p>"


def part(kind, text):
    return {"mimeType": kind, "headers": [
        {"name": "Content-Type", "value": kind + '; charset="iso-8859-1"'},
        {"name": "Content-Transfer-Encoding", "value": "quoted-printable"},
    ], "body": {"size": len(text.encode("iso-8859-1")),
                "data": base64.urlsafe_b64encode(text.encode("utf-8")).decode().rstrip("=")}}


def exercise(binary, directory, old_binary=None, terminal_type=Terminal):
    provider = directory / "provider"
    shutil.copytree(FIXTURES / "accounts", provider / "accounts")
    path = provider / "accounts/personal.json"
    source = json.loads(path.read_text())
    source.update(generation=100, sync={"historyId": "100", "history": []}, messages=[{
        "id": IDENTIFIER, "threadId": "legacy-charset-thread", "internalDate": "1794900000000",
        "labelIds": ["INBOX", "UNREAD"], "snippet": "Independent metadata preview.",
        "payload": {"mimeType": "multipart/alternative", "headers": [
            {"name": "From", "value": "Example Office <office@example.test>"},
            {"name": "To", "value": ACCOUNTS[0]},
            {"name": "Subject", "value": "A correctly encoded legacy message"},
        ], "parts": [part("text/plain", PLAIN), part("text/html", HTML)]},
    }])
    path.write_text(json.dumps(source, ensure_ascii=False) + "\n")
    owned = directory / "client"
    options = ("--fixture-root", str(provider), "--prefetch-bodies", "0")
    with Client(old_binary or binary, owned, extra=options) as client:
        client.request("mail.list", label="INBOX")
        first = client.request("mail.read", messageId=IDENTIFIER)
        if old_binary:
            require("fÃ¤llt" in first["bodyText"] and "Grüßen" not in first["bodyText"],
                    "old executable did not reproduce the real encoding defect")
        else:
            require(first["bodyText"] == PLAIN and first["bodyHtml"] == HTML,
                    "fresh Gmail alternatives do not match the independent text oracle")
    cache = owned / "cache/fixtures" / hashlib.sha256(ACCOUNTS[0].encode()).hexdigest()
    index = cache / "index.json"
    state = json.loads(index.read_text())
    entry = next(e for e in state["entries"] if e["message"]["id"] == IDENTIFIER)
    body_path = next(p for p in cache.glob("mail-*.json")
                     if json.loads(p.read_text())["message"]["id"] == IDENTIFIER)
    record = json.loads(body_path.read_text())
    # Model an accepted revision-one cache without requiring an old download in CI.
    record["message"]["bodyText"] = "Old accepted body: fÃ¤llt GrÃ¼Ãen"
    record["message"]["bodyHtml"] = "<p>Old accepted body: fÃ¤llt GrÃ¼Ã\u009fen</p>"
    raw = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode()
    body_path.write_bytes(raw)
    entry.update(bytes=len(raw), bodyHash=hashlib.sha256(raw).hexdigest(), bodyDecoderRevision=1)
    index.write_text(json.dumps(state) + "\n")
    with Client(binary, owned, extra=options) as client:
        cached = client.request("mail.read", messageId=IDENTIFIER, cacheOnly=True)
        require(cached["bodyNeedsRefresh"] and "Old accepted body" in cached["bodyText"],
                "offline read lost the retained body or its refresh hint")
    terminal = terminal_type(binary, owned, extra=options, columns=140, rows=38, screen_type=AcceptanceScreen)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "Die Gebühr fällt heute an."))
        require("Old accepted body" not in terminal.text(), "normal TUI selection kept the stale body")
        terminal.send(b"lp")
        terminal.until(lambda: reader_contains(terminal.screen, "Formatted view:")
                       and reader_contains(terminal.screen, "Grüßen"))
        require("fÃ¤llt" not in terminal.text(), "formatted reader applied the charset twice")
        terminal.finish()
    finally:
        terminal.close()
    with Client(binary, owned, extra=options) as client:
        fixed = client.request("mail.read", messageId=IDENTIFIER, cacheOnly=True)
        require(fixed["bodyText"] == PLAIN and fixed["bodyHtml"] == HTML and not fixed.get("bodyNeedsRefresh", False),
                "corrected body did not survive cache reopening")
        require(set(fixed["labels"]) == {"INBOX", "UNREAD"} and fixed["unread"],
                "charset correction changed mailbox membership or read state")
        require(client.request("cache.stats")["fixtureSends"] == 0, "reading caused a send")
    source["messages"][0]["payload"]["parts"] = [part("text/plain", "UNEXPECTED_PROVIDER_BODY")]
    path.write_text(json.dumps(source) + "\n")
    terminal = terminal_type(binary, owned, extra=options, columns=140, rows=38, screen_type=AcceptanceScreen)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "Grüßen"))
        terminal.pump(.8)
        require("UNEXPECTED_PROVIDER_BODY" not in terminal.text(), "current body was fetched again after restart")
        terminal.finish()
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--old-binary", type=Path)
    args = parser.parse_args()
    terminal_type = Terminal
    if sys.platform == "darwin":
        from terminal_macos import DarwinTerminal
        terminal_type = DarwinTerminal
        tempfile.tempdir = str(Path("/tmp").resolve())
    with tempfile.TemporaryDirectory(prefix="omagma-gmail-charset-") as root:
        exercise(args.binary.resolve(), Path(root), args.old_binary.resolve() if args.old_binary else None, terminal_type)
    print("PASS Gmail charset: old-binary reproduction, offline cache, plain/formatted TUI correction and restart")


if __name__ == "__main__":
    main()
