#!/usr/bin/env python3
"""Owned-PTY coverage for a large source -> formatted reply -> edit/reopen/send.

Only fictional fixture mail and a temporary editor are used. No GUI, account
configuration, Google connection or production send is involved.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import traceback

from build_info import read_build_info
from terminal_integration import Client, FIXTURES
from terminal_pty import Terminal, require


def encode(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def source_fixture(root):
    destination = root / "fixtures"
    shutil.copytree(FIXTURES, destination)
    file = destination / "accounts/personal.json"
    account = json.loads(file.read_text())
    message = account["messages"][0]
    message.update(id="growing-source", threadId="growing-thread",
                   snippet="A large original with 146 retained screenshots.")
    headers = [{"name": name, "value": value} for name, value in (
        ("From", "River Fixture <river@example.test>"),
        ("To", "personal@example.com"), ("Subject", "Growing chain source"),
        ("Message-ID", "<growing-source@example.test>"),
        ("Date", "Fri, 23 Oct 2026 12:00:00 +0000"))]
    image = (FIXTURES.parents[2] / "assets/omagma-logo.png").read_bytes()
    references = "".join(f'<img src="cid:shot-{index}@fixture">' for index in range(146))
    html = ("<!doctype html><html><body><p>Keep the complete original.</p><!--"
            + "x" * (3 * 1024 * 1024) + "-->" + references + "</body></html>").encode()
    plain = b"Keep the complete original and every screenshot."
    parts = [{"partId": "0", "mimeType": "multipart/alternative", "filename": "",
              "headers": [], "parts": [
                  {"partId": "0.0", "mimeType": "text/plain", "filename": "", "headers": [],
                   "body": {"size": len(plain), "data": encode(plain)}},
                  {"partId": "0.1", "mimeType": "text/html", "filename": "", "headers": [],
                   "body": {"size": len(html), "data": encode(html)}},
              ]}]
    for index in range(146):
        parts.append({"partId": str(index + 1), "mimeType": "image/png",
                      "filename": f"shot-{index}.png",
                      "headers": [{"name": "Content-ID", "value": f"<shot-{index}@fixture>"},
                                  {"name": "Content-Disposition", "value": "inline"}],
                      "body": {"size": len(image), "data": encode(image)}})
    # A received ordinary file is irrelevant to replying. The source chooser
    # must not try to download/forward this oversized file before choosing.
    parts.append({"partId": "ordinary", "mimeType": "application/pdf",
                  "filename": "large-received-report.pdf", "headers": [],
                  "body": {"size": 26 * 1024 * 1024, "attachmentId": "not-needed-for-reply"}})
    message["payload"] = {"partId": "", "mimeType": "multipart/related", "filename": "",
                          "headers": headers, "parts": parts}
    account["messages"] = [message]
    account["pages"] = [{"pageToken": "", "response": {
        "messages": [{"id": message["id"], "threadId": message["threadId"]}],
        "resultSizeEstimate": 1}}]
    file.write_text(json.dumps(account))
    return destination, hashlib.sha256(html).hexdigest()


def exercise(binary, root):
    fixtures, original_hash = source_fixture(root)
    source = root / "editor-body.txt"
    body = "Growing note " + "a" * (2 * 1024 * 1024 + 64) + "\nComplete note tail.\n"
    source.write_text(body)
    editor = root / "editor.py"
    editor.write_text("from pathlib import Path\nimport sys\n"
                      "Path(sys.argv[-1]).write_bytes(Path(sys.argv[1]).read_bytes())\n")
    preferences = root / "ui.json"
    preferences.write_text(json.dumps({"schema": 1, "sendGraceSeconds": 0}))
    preferences.chmod(0o600)
    terminal = Terminal(binary, root, columns=160, rows=40, history_limit=1024 * 1024,
                        extra=("--fixture-root", str(fixtures), "--ui-file", str(preferences)),
                        environment={"EDITOR": shlex.join([sys.executable, str(editor), str(source)])})
    try:
        terminal.until(lambda: "Growing chain source" in terminal.text() and "Ready" in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "Body unavailable" in terminal.text())
        terminal.send(b"r")
        terminal.until(lambda: "Keep formatting" in terminal.text())
        require("unavailable" not in terminal.text().split("Keep formatting")[0].splitlines()[-1].lower(),
                "large-source formatting choice remained disabled")
        terminal.send(b"k")
        terminal.until(lambda: "Compose" in terminal.text().splitlines()[0]
                       and "original is protected" in terminal.text())
        terminal.send(b"e")
        terminal.until(lambda: "Editor returned" in terminal.text() and "Growing note" in terminal.text(), seconds=30)
        terminal.send(b":preview-browser\r")
        terminal.until(lambda: "Mock browser target validated" in terminal.text(), seconds=30)
        previews = list(root.rglob("preview.html"))
        require(len(previews) == 1 and "Complete note tail." in previews[0].read_text(),
                "large ordinary composer preview did not preserve the authored HTML")
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text(), seconds=30)
        require("Preview unavailable" not in terminal.text(),
                "semantic screen limit incorrectly prevented a valid long note from review")
        terminal.send(b"n")
        terminal.until(lambda: "Compose" in terminal.text().splitlines()[0])
        terminal.send(b"q")
        terminal.until(lambda: "Compose" not in terminal.text().splitlines()[0])
        with Client(binary, root, extra=("--fixture-root", str(fixtures))) as client:
            summaries = client.request("draft.list")["drafts"]
            require(len(summaries) == 1, "large reply was not retained exactly once")
            draft = client.request("draft.read", draftId=summaries[0]["id"])
            require(draft["bodyText"] == body, "large editor note changed during saving")
            require(hashlib.sha256(draft["original"]["bodyHtml"].encode()).hexdigest() == original_hash,
                    "formatted source changed during native reply/save")
            resources = draft["original"]["resources"]
            require(len(resources) == 146 and all(x.get("blobId") and not x.get("data") for x in resources),
                    "screenshots were lost or copied inline through large UI frames")
            require(not draft["attachments"], "reply unexpectedly forwarded the ordinary PDF")
        # Reply returns to its reader context. Traverse reader -> list ->
        # sidebar before selecting local Drafts; a single h only reaches list.
        terminal.send(b"hh")
        terminal.until(lambda: "Accounts / mailboxes" in terminal.text())
        terminal.send(b"jjjjj")
        terminal.gap()
        terminal.send(b"\r")
        terminal.until(lambda: "Drafts" in terminal.text().splitlines()[0] and "Ready" in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "Compose" in terminal.text().splitlines()[0]
                       and "Local draft · no mail sent" in terminal.text().splitlines()[1], seconds=30)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text(), seconds=30)
        terminal.send(b"y")
        terminal.until(lambda: "Saved by mock provider" in terminal.text(), seconds=30)
        return {**terminal.finish(expected_sends=1), "sourceHtmlSha256": original_hash,
                "inlineImagesPreserved": 146, "noteBytes": len(body.encode()),
                "largeReaderRefusalStillAllowsFormattedReply": True,
                "sourceOversizedOrdinaryFileNotForwarded": True,
                "completeHtmlPreviewOpenedFromOrdinaryComposer": True,
                "savedReopenedAndReviewed": True}
    except Exception:
        (root / "last-screen.txt").write_text(terminal.text())
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", default="debug")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {**read_build_info(args.binary, args.build_mode), "synthetic": True, "desktopUsed": False}
    root = Path(tempfile.mkdtemp(prefix="omagma-growing-composer-"))
    try:
        report.update(exercise(args.binary.resolve(), root), passed=True)
        shutil.rmtree(root)
    except Exception as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}",
                      traceback=traceback.format_exc(), diagnosticDirectory=str(root))
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
