#!/usr/bin/env python3
"""Owned-PTY coverage for a large source -> formatted reply -> edit/reopen/send.

Only fictional fixture mail and a temporary editor are used. No GUI, account
configuration, Google connection or production send is involved.
"""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import time
import traceback

from build_info import read_build_info
from terminal_integration import Client, FIXTURES
from terminal_pty import Terminal, require, saved_compose_frame

# These two operations process the complete multi-MiB fixture. A native Debug
# run measured 12s for capture and 31s for HTML export, beyond the old 10s/30s
# UI waits. Keep explicit slow-native margins here, not in Terminal.until or
# the ordinary workflow waits; successful receipts retain each actual duration.
CAPTURE_SECONDS = 60
HTML_PREVIEW_SECONDS = 120


class Stages:
    """Retain the exact wait and completed work when a slow PTY check fails."""
    def __init__(self):
        self.started = time.monotonic()
        self.current = "setup"
        self.timings = []

    @contextmanager
    def step(self, name, timeout=None):
        self.current = name
        started = time.monotonic()
        entry = {"stage": name, "startedSeconds": round(started - self.started, 4), "passed": False}
        if timeout is not None:
            entry["timeoutSeconds"] = timeout
        self.timings.append(entry)
        try:
            yield
            entry["passed"] = True
        finally:
            entry["elapsedSeconds"] = round(time.monotonic() - started, 4)

    def receipt(self):
        return {"stage": self.current, "elapsedSeconds": round(time.monotonic() - self.started, 4),
                "stageTimings": self.timings}


def persist_failure(failure, directory, output):
    """Keep full JSON evidence where the native CI artifact glob retains it."""
    data = getattr(failure, "growing_diagnostics", None)
    if data is None:
        saved = directory / "last-screen.json"
        if not saved.is_file():
            return {"traceback": traceback.format_exc()}
        data = json.loads(saved.read_text())
    destination = output.with_name(f"{output.stem}-growing-composer.vt.json")
    destination.write_text(json.dumps(data, ensure_ascii=True, indent=2) + "\n")
    destination.chmod(0o600)
    return {**{key: value for key, value in data.items() if key != "escapedOutput"},
            "escapedDiagnosticFile": destination.name}


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
    stages = Stages()
    terminal = None

    def wait(name, predicate, *, keys=None, seconds=10):
        with stages.step(name, seconds):
            if keys is not None:
                terminal.send(keys)
            terminal.until(predicate, seconds=seconds)

    try:
        with stages.step("create-fixture"):
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
        with stages.step("start-terminal"):
            terminal = Terminal(binary, root, columns=160, rows=40, history_limit=1024 * 1024,
                                extra=("--fixture-root", str(fixtures), "--ui-file", str(preferences)),
                                environment={"EDITOR": shlex.join([sys.executable, str(editor), str(source)])})
        wait("initial-mail-list", lambda: "Growing chain source" in terminal.text() and "Ready" in terminal.text())
        wait("bounded-reader-refusal", lambda: "Body unavailable" in terminal.text()
             and "j/k Scroll" in terminal.text().splitlines()[-2], keys=b"\r")
        wait("formatted-reply-choice", lambda: "Keep formatting" in terminal.text(), keys=b"r")
        with stages.step("verify-formatting-choice"):
            require("HTML · 146 embedded resources" in terminal.text()
                    and "Keep formatting unavailable" not in terminal.text(),
                    "large-source formatting choice did not retain all 146 resources")
        wait("capture-formatted-original", lambda: "Compose" in terminal.text().splitlines()[0]
             and "original is protected" in terminal.text() and saved_compose_frame(terminal),
             keys=b"k", seconds=CAPTURE_SECONDS)
        # The editor notice appears before its asynchronous draft save starts.
        # Composer commands are ignored until that save has returned: require
        # its observable receipt before requesting a preview, without retries.
        wait("editor-return-and-save", lambda: "Editor returned" in terminal.text()
             and "Growing note" in terminal.text() and saved_compose_frame(terminal),
             keys=b"e", seconds=30)
        wait("open-complete-html-preview", lambda: "Mock browser target validated" in terminal.text(),
             keys=b":preview-browser\r", seconds=HTML_PREVIEW_SECONDS)
        with stages.step("verify-complete-html-preview"):
            previews = list(root.rglob("preview.html"))
            require(len(previews) == 1 and "Complete note tail." in previews[0].read_text(),
                    "large ordinary composer preview did not preserve the authored HTML")
        wait("first-send-review", lambda: "Sending account:" in terminal.text(), keys=b"\x13", seconds=30)
        require("Preview unavailable" not in terminal.text(),
                "semantic screen limit incorrectly prevented a valid long note from review")
        wait("return-from-review", lambda: "Compose" in terminal.text().splitlines()[0], keys=b"n")
        wait("save-and-close-composer", lambda: "Compose" not in terminal.text().splitlines()[0], keys=b"q")
        with stages.step("verify-saved-original-and-note"), Client(binary, root, extra=("--fixture-root", str(fixtures))) as client:
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
        wait("open-mailbox-sidebar", lambda: "j/k Navigate" in terminal.text().splitlines()[-2], keys=b"hh")
        with stages.step("select-drafts-folder"):
            terminal.send(b"jjjjj")
            terminal.gap()
        wait("load-drafts-list", lambda: "Drafts" in terminal.text().splitlines()[0]
             and "Re: Growing chain source" in terminal.text() and "Ready" in terminal.text(), keys=b"\r")
        wait("reopen-saved-composer", lambda: "Compose" in terminal.text().splitlines()[0]
             and "Local draft · no mail sent" in terminal.text().splitlines()[1], keys=b"\r", seconds=30)
        wait("reopened-send-review", lambda: "Sending account:" in terminal.text(), keys=b"\x13", seconds=30)
        wait("confirmed-fixture-send", lambda: "Saved by mock provider" in terminal.text(), keys=b"y", seconds=30)
        with stages.step("verify-single-send-and-terminal-restoration"):
            finished = terminal.finish(expected_sends=1)
        return {**finished, **stages.receipt(), "sourceHtmlSha256": original_hash,
                "inlineImagesPreserved": 146, "noteBytes": len(body.encode()),
                "largeReaderRefusalStillAllowsFormattedReply": True,
                "sourceOversizedOrdinaryFileNotForwarded": True,
                "completeHtmlPreviewOpenedFromOrdinaryComposer": True,
                "savedReopenedAndReviewed": True}
    except Exception as failure:
        evidence = {"synthetic": True, **stages.receipt(), "traceback": traceback.format_exc()}
        if terminal is not None:
            evidence.update(currentCells=terminal.text().splitlines(),
                            escapedOutput=bytes(terminal.output).decode("utf-8", errors="replace"),
                            outputBytes=terminal.output_total, retainedOutputBytes=len(terminal.output),
                            frameOpen=terminal.screen.frame_open, parserState=terminal.screen.state,
                            exitCode=terminal.process.poll())
            (root / "last-screen.txt").write_text(terminal.text())
        failure.growing_diagnostics = evidence
        (root / "last-screen.json").write_text(json.dumps(evidence, ensure_ascii=True, indent=2) + "\n")
        (root / "last-screen.json").chmod(0o600)
        raise
    finally:
        if terminal is not None:
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
                      diagnosticDirectory=str(root), **persist_failure(error, root, args.output))
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
