#!/usr/bin/env python3
"""Owned fixture PTYs: Markdown defaults, source/preview, recovery and send.

Runs only against synthetic providers in isolated homes/cache/terminals. Every
fixture submission requires the real TUI's explicit review and y confirmation.
No desktop window/input, credentials, real mailbox or live provider is used.
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import traceback

from build_info import read_build_info
from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start
from terminal_polish_compose import panel_text
from terminal_file_dialog import capture

ORIGINAL = "ORIGINAL-MARKDOWN-MARKER\nLiteral **stars** and [unsafe](javascript:alert(1)).\nSecond original line.\n"
FILE_BYTES = b"\x00\xff\x80\r\n"
NEW_BODY = "# New heading 🌋\n\n**Bold new** body.\n\n- first\n  - child\n- second\n\n| Key | Value |\n| :--- | ---: |\n| Alpha | 42 |\n\n```zig\nconst count = 42; // <literal>\n```\n\nLiteral "


def fixture_setup(binary, directory):
    fixture = ProviderFixture(directory)
    for account in ACCOUNTS:
        message = next(value for value in fixture.data[account]["baseline"]["messages"] if value["id"] == "shared-msg-096")
        plain = copy.deepcopy(message["payload"])
        plain.update(partId="0", mimeType="text/plain", filename="", parts=[],
                     headers=[{"name": "Content-Type", "value": "text/plain; charset=utf-8"}],
                     body={"size": len(ORIGINAL.encode()), "data": base64.urlsafe_b64encode(ORIGINAL.encode()).decode().rstrip("=")})
        mixed = message["payload"]
        mixed.update(mimeType="multipart/mixed", body={"size": 0, "data": ""}, parts=[plain,
            {"partId": "1", "mimeType": "application/octet-stream", "filename": "original-fixture.bin",
             "headers": [{"name": "Content-Disposition", "value": "attachment; filename=original-fixture.bin"}],
             "body": {"size": len(FILE_BYTES), "data": base64.urlsafe_b64encode(FILE_BYTES).decode().rstrip("=")}}])
        for header in mixed["headers"]:
            if header["name"].lower() == "content-type":
                header["value"] = "multipart/mixed; boundary=markdown-original"
        fixture.stage(account, "baseline")
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.refresh", limit=32, prefetchLimit=32)
        original = client.request("mail.read", messageId="shared-msg-096")
        require(original["bodyText"] == ORIGINAL, "controlled incoming fixture was not literal plaintext")
    return fixture, original


def latest_draft(client):
    entries = client.request("draft.list")["drafts"]
    require(len(entries) == 1, "workflow unexpectedly created/replaced its draft identity")
    return client.request("draft.read", draftId=entries[0]["id"])


def paste(terminal, text):
    terminal.send(b"\x1b[200~" + text.encode() + b"\x1b[201~")


def normal(terminal):
    terminal.send(b"\x1b")
    terminal.gap(.08)


def wait_compose(terminal):
    terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text() and "Body:" in terminal.text())


def rendered(terminal, literal):
    terminal.until(lambda: "Outgoing preview" in terminal.text() and literal in panel_text(terminal, "Outgoing preview"))
    return panel_text(terminal, "Outgoing preview")


def confirm_and_check(terminal, client, expected_source, original, kind, expected_file, capture_dir):
    terminal.send(b"\x13")
    terminal.until(lambda: "Review send" in terminal.text() and "Sending account:" in terminal.text())
    saved = latest_draft(client)
    require(saved["bodyFormat"] == "markdown" and saved["bodyText"] == expected_source, "review changed Markdown source or interpretation")
    require("Markdown" in terminal.text() and "HTML + plain text" in terminal.text(), "review omitted actual outgoing format")
    if kind == "new":
        require("Bold new" in terminal.text() and "**Bold new**" not in terminal.text(), "send review showed raw source instead of rendered outgoing body")
    else:
        require(f"{kind.title()} rendered body." in terminal.text(), "send review omitted rendered new reply/forward prose")
    preview = client.request("draft.preview", draftId=saved["id"])
    capture(terminal, capture_dir, f"{kind}-review")
    require(client.request("cache.stats")["fixtureSends"] == 0, "mail was submitted before explicit confirmation")
    terminal.send(b"y")
    terminal.until(lambda: "Saved by mock provider" in terminal.text())
    operations = client.request("operation.list")["operations"]
    applied = [operation for operation in operations if operation["outcome"] == "applied"]
    require(len(applied) == 1, "explicit confirmation did not create exactly one applied fixture operation")
    sent = client.request("mail.read", messageId=applied[0]["messageId"])
    require(sent["bodyHtml"] == preview["bodyHtml"] and sent["bodyText"] == preview["plainText"], "rendered review/send alternatives differed")
    require(len(sent["attachments"]) == (1 if expected_file else 0), "submission changed genuine user attachment count")
    if expected_file:
        file = sent["attachments"][0]
        require(file["filename"] == expected_file and base64.urlsafe_b64decode(file["data"] + "===") == FILE_BYTES, "outgoing binary attachment changed filename or bytes")
    if kind == "reply":
        require(sent["threadId"] == original["threadId"] and sent["inReplyTo"] == original["messageId"], "reply submission lost original conversation headers")
    elif kind == "forward":
        require(sent["threadId"] != original["threadId"] and not sent["inReplyTo"] and not sent["references"], "forward joined the original conversation")
    require(client.request("cache.stats")["fixtureSends"] == 1, "submission was repeated")
    return terminal.finish(expected_sends=1)


def new_case(binary, directory, capture_dir=None):
    fixture, original = fixture_setup(binary, directory)
    attachment = directory / "new-fixture.bin"
    attachment.write_bytes(FILE_BYTES)
    terminal = start(binary, directory, fixture, columns=160, rows=42)
    try:
        terminal.until(lambda: "ORIGINAL-MARKDOWN-MARKER" in terminal.text())
        terminal.send(b"c")
        wait_compose(terminal)
        with Client(binary, directory, extra=fixture.options()) as client:
            fresh = latest_draft(client)
            require(fresh["bodyFormat"] == "markdown" and not fresh["bodyText"], "native new composer did not explicitly default to Markdown")
            terminal.send(b"ipeer@example.test\t\t\tMarkdown new fixture\t")
            paste(terminal, NEW_BODY)
            terminal.send(b"p")
            terminal.until(lambda: "Body: INSERT" in terminal.text() and "Literal p" in terminal.text())
            require("Outgoing preview" in terminal.text(), "printable p in INSERT switched away from outgoing preview")
            terminal.send(b"\x14")
            terminal.until(lambda: "Plain · Body:" in terminal.text() and "[Markdown Ctrl+T]" in terminal.text())
            normal(terminal)
            terminal.send(b"\x13")
            terminal.until(lambda: "Review send" in terminal.text() and "Format: Plain text" in terminal.text())
            plain = latest_draft(client)
            require(plain["bodyFormat"] == "plain" and plain["bodyText"] == NEW_BODY + "p", "Ctrl+T in INSERT changed source or was not persisted")
            normal(terminal)
            wait_compose(terminal)
            terminal.send(b"\x14")
            terminal.until(lambda: "MD · Body:" in terminal.text() and "[Plain Ctrl+T]" in terminal.text())
            html_panel = rendered(terminal, "Bold new")
            require("**Bold new**" not in html_panel and "const count = 42" in html_panel, "outgoing preview showed source markers or lost fenced code")
            capture(terminal, capture_dir, "new-source-and-outgoing-wide")
            # At narrow width, the actual preview is a temporary full pane.
            # Returning preserves the source field and insertion point.
            terminal.resize(80, 28)
            terminal.until(lambda: "Compose" in terminal.text() and "Body:" in terminal.text())
            terminal.send(b"p")
            rendered(terminal, "Bold new")
            capture(terminal, capture_dir, "new-outgoing-narrow")
            terminal.send(b"jk")
            normal(terminal)
            wait_compose(terminal)
            terminal.resize(160, 42)
            wait_compose(terminal)
            terminal.send(b"i typed")
            terminal.until(lambda: "Literal p typed" in terminal.text())
            normal(terminal)
            terminal.send(b"A")
            terminal.until(lambda: "Attach file · local draft" in terminal.text() and "Path:" in terminal.text())
            terminal.send(str(attachment).encode() + b"\r")
            terminal.until(lambda: "Attachments 1" in terminal.text())
            result = confirm_and_check(terminal, client, NEW_BODY + "p typed", original, "new", attachment.name, capture_dir)
        return result
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def conversation_case(binary, directory, kind, capture_dir=None):
    fixture, original = fixture_setup(binary, directory)
    terminal = start(binary, directory, fixture, columns=160, rows=42)
    try:
        terminal.until(lambda: "ORIGINAL-MARKDOWN-MARKER" in terminal.text())
        terminal.send(b"r" if kind == "reply" else b"f")
        wait_compose(terminal)
        with Client(binary, directory, extra=fixture.options()) as client:
            fresh = latest_draft(client)
            require(fresh["bodyFormat"] == "markdown", "native reply/forward composer did not default to Markdown")
            original_source = fresh["bodyText"]
            require("\\*\\*stars\\*\\*" in original_source, "literal original Markdown was not escaped in quote source")
            if kind == "reply":
                require(fresh["threadId"] == original["threadId"], "reply draft lost threading")
            else:
                require(not fresh["threadId"] and len(fresh["attachments"]) == 1, "forward draft lost independent conversation or original file")
            terminal.send(b"p")
            terminal.until(lambda: "Original message" in terminal.text())
            require("Literal **stars**" in panel_text(terminal, "Original message"), "Original selector rendered or rewrote incoming literal Markdown")
            terminal.send(b"p")
            terminal.until(lambda: "Plain-text alternative" in terminal.text())
            terminal.send(b"p")
            rendered(terminal, "ORIGINAL-MARKDOWN-MARKER")
            capture(terminal, capture_dir, f"{kind}-source-and-outgoing-wide")
            if kind == "forward":
                terminal.send(b"iforward-peer@example.test")
                normal(terminal)
            # All actual field focus stops remain accessible with Tab.
            terminal.send(b"\t\t\t\ti")
            # Fresh reply/forward caret must already be above the quotation.
            prefix = "Reply *rendered* body.\n\n" if kind == "reply" else "Forward **rendered** body.\n\n"
            paste(terminal, prefix)
            terminal.until(lambda: "Body: INSERT" in terminal.text() and "rendered" in terminal.text())
            normal(terminal)
            result = confirm_and_check(terminal, client, prefix + original_source, original, kind, "original-fixture.bin" if kind == "forward" else None, capture_dir)
        return result
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=("all", "new", "reply", "forward"), default="all")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--capture-dir", type=Path, help="Optional synthetic current-cell JSON/SVG/PNG captures")
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt = {"schemaVersion": 1, "suite": "terminal-markdown-compose", "synthetic": True, "liveProviderWrites": 0,
               "binarySha256": digest, **read_build_info(binary, None), "cases": []}
    def save():
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="omagma-markdown-compose-") as temporary:
        for name in ("new", "reply", "forward"):
            if args.case not in ("all", name):
                continue
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            try:
                cleanup = new_case(binary, directory, args.capture_dir) if name == "new" else conversation_case(binary, directory, name, args.capture_dir)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                save()
                raise
            receipt["cases"].append({"name": name, "status": "passed", **cleanup})
            save()
            print(f"PASS Markdown TUI {name}: native defaults, source/rendered preview and explicit fixture confirmation")
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed during the suite")
    receipt["binaryUnchanged"] = True
    save()


if __name__ == "__main__":
    main()
