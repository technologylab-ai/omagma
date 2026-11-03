#!/usr/bin/env python3
"""Explicit image paste in owned PTYs; synthetic bytes/private Mac pasteboards only."""
from __future__ import annotations

import argparse
import base64
from email import policy
from email.parser import BytesParser
import hashlib
from html.parser import HTMLParser
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

from build_info import read_build_info
from terminal_integration import Client, ROOT, require
from terminal_mouse import click, point
from terminal_reader_editor import MouseTerminal
from terminal_compose_screen import ComposerScreen
from terminal_pty import open_composer, send_review_ready, wait_saved_compose
from terminal_reader_next_ux import capture

CASES = ("clipboard-inline", "clipboard-plain", "clipboard-errors", "clipboard-cancel", "clipboard-helper", "clipboard-regular-typing")
IMAGE = ROOT / "src/terminal/omagma-logo.png"
BEFORE = "First paragraph."
AFTER = "Following paragraph typed while capture runs."


class PreviewDocument(HTMLParser):
    """Inspect actual image elements, including the sandboxed preview srcdoc."""
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.source = source
        self.images = []
        self.children = []
        self.feed(source)

    def handle_starttag(self, tag, pairs):
        attrs = dict(pairs)
        if tag == "iframe" and attrs.get("srcdoc"):
            self.children.append(PreviewDocument(attrs["srcdoc"]))
        if tag == "img":
            line, column = self.getpos()
            offset = sum(map(len, self.source.splitlines(keepends=True)[:line - 1])) + column
            self.images.append((attrs, offset))

    def matching_images(self, alt):
        matches = [(self.source, attrs, offset) for attrs, offset in self.images if attrs.get("alt") == alt]
        for child in self.children:
            matches.extend(child.matching_images(alt))
        return matches


def narrow_clipboard(terminal, captures, name, dormant=False, check_tab=False):
    terminal.resize(64, 24)
    terminal.until(lambda: terminal.screen.compose_geometry_ready()
                   and terminal.screen.locate("[x]") is not None
                   and ("not in body, won't be sent" if dormant else " · inline") in terminal.text())
    require("[Upload all]" not in terminal.text(), "inline-only composer offered a bulk Drive action")
    if check_tab:
        target = terminal.screen.locate("[x]")
        before = terminal.screen.styles[target["row"]][target["column"]]
        terminal.send(b"\t\t")  # Body -> Add -> image's only action, Remove.
        def removal_focused():
            where = terminal.screen.locate("[x]")
            return where is not None and terminal.screen.styles[where["row"]][where["column"]] != before
        terminal.until(removal_focused)
        # Reachability is observable without activating Detach and losing its
        # owned blob, which correctly has no attachment-undo operation.
    capture(terminal, captures, name)
    if check_tab:
        # Reverse the same two controls and restore the original body INSERT
        # context; Esc would leave normal mode and the caller's Esc would then
        # save/close the composer instead of opening its browser preview.
        terminal.send(b"\x1b[Z\x1b[Z")
        terminal.until(lambda: "Body: INSERT" in terminal.text())
    terminal.resize(180, 46)
    terminal.until(lambda: terminal.screen.compose_geometry_ready())


def stages(directory):
    return list((Path(directory) / "runtime").glob("omagma-clipboard-*"))


def descendants(pid):
    result = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True,
                            timeout=3, check=True)
    pairs = [tuple(map(int, line.split())) for line in result.stdout.splitlines() if line.strip()]
    owned = {pid}
    while True:
        children = {child for child, parent in pairs if parent in owned}
        if children <= owned:
            return owned - {pid}
        owned |= children


def saved(binary, directory):
    with Client(binary, directory) as client:
        drafts = client.request("draft.list")["drafts"]
        require(len(drafts) == 1, "clipboard paste changed the local draft count")
        result = client.request("draft.read", draftId=drafts[0]["id"])
        require(client.request("cache.stats")["fixtureSends"] == 0, "clipboard paste sent mail")
        return result


def body(draft):
    return (draft.get("recoveryFields") or [None] * 4 + [draft["bodyText"]])[4]


def saved_until(binary, directory, predicate, terminal):
    deadline = time.monotonic() + 8
    while True:
        # The independent CLI can observe persistence only if the owned TUI
        # keeps draining its bounded output channel and processing events.
        terminal.pump(0)
        result = saved(binary, directory)
        terminal.pump(0)
        if predicate(result):
            return result
        require(time.monotonic() < deadline, "clipboard draft did not autosave expected state")
        terminal.gap(.05)


def start(binary, directory, scenario="png", captures=None):
    terminal = MouseTerminal(binary, directory, extra=("--fixture-scenario", "clipboard-" + scenario),
                             screen_type=ComposerScreen, columns=180, rows=46,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: "Ready" in terminal.text())
        open_composer(terminal)
        wait_saved_compose(terminal, 0)
        require(body(saved(binary, directory)) == "", "fresh clipboard fixture composer has unexpected body text")
        # This is a new empty composer: no synthetic Delete-key burst or
        # cursor-clearing escape stream is needed to enter the first paragraph.
        terminal.send(b"ipeer@example.test\t\t\tClipboard fixture\t" + BEFORE.encode())
        terminal.until(lambda: BEFORE in terminal.text() and "Body: INSERT" in terminal.text())
        return terminal
    except Exception:
        print(terminal.text(), flush=True)
        capture(terminal, captures, "clipboard-startup-failure-" + scenario)
        try:
            terminal.finish()
        except Exception as cleanup:
            print("Startup cleanup: " + repr(cleanup), flush=True)
        finally:
            terminal.close()
        raise


def close(terminal, expected_sends=0):
    try:
        terminal.finish(expected_sends=expected_sends)
    finally:
        terminal.close()


def inline_case(binary, directory, captures=None):
    terminal = start(binary, directory, "slow", captures)
    expected_sends = 0
    try:
        terminal.send(b"\x16\r\r" + AFTER.encode())
        terminal.until(lambda: "Pasted clipboard-" in terminal.text())
        draft = saved_until(binary, directory, lambda d: len(d["attachments"]) == 1, terminal)
        file = draft["attachments"][0]
        require(file["mimeType"] == "image/png" and file["disposition"] == "inline"
                and file["delivery"] == "attach" and re.fullmatch(r"clipboard-[0-9a-f]{32}@omagma.invalid", file["contentId"]),
                "inline image metadata is not an owned pinned PNG")
        marker = f'![{file["filename"]}](cid:{file["contentId"]})'
        source = body(draft)
        require(source == BEFORE + "\n\n" + marker + "\n\n" + AFTER,
                "delayed image paste did not preserve the captured insertion anchor and following typing")
        to_text = draft["recoveryFields"][0] if draft.get("recoveryFields") else ", ".join(recipient["address"] for recipient in draft["to"])
        require(to_text == "peer@example.test" and draft["subject"] == "Clipboard fixture", "paste changed header fields")
        require(file["size"] == IMAGE.stat().st_size, "clipboard PNG size changed")
        require(not stages(directory), "successful inline paste left a plaintext staging file")
        require("^V image" in terminal.text(), "composer does not discover image paste")
        capture(terminal, captures, "clipboard-inline-after-paste")
        narrow_clipboard(terminal, captures, "clipboard-inline-narrow", check_tab=True)
        # Browser preview must contain the same PNG in the authored position.
        terminal.send(b"\x1b")
        terminal.gap(.08)
        terminal.send(b"P")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        previews = list(Path(directory).rglob("preview.html"))
        require(len(previews) == 1, "clipboard browser preview was not materialized")
        actual_images = PreviewDocument(previews[0].read_text()).matching_images(file["filename"])
        require(len(actual_images) == 1, "browser preview did not contain exactly one authored screenshot element")
        document, image_attrs, image_offset = actual_images[0]
        require(document.index(BEFORE) < image_offset < document.index(AFTER),
                "HTML preview moved the screenshot element out of its authored paragraph position")
        uri = image_attrs.get("src", "")
        require(uri.startswith("data:image/png;base64,"), "authored screenshot was not resolved to a private data image")
        require(hashlib.sha256(base64.b64decode(uri.split(",", 1)[1], validate=True)).digest()
                == hashlib.sha256(IMAGE.read_bytes()).digest(), "authored screenshot element has different PNG bytes")
        # One Undo removes only the marker insertion, leaving typed-after text;
        # the dormant blob remains available to Redo and is omitted from wire.
        terminal.send(b"\x1a")
        terminal.until(lambda: "not in body, won't be sent" in terminal.text())
        undone = saved_until(binary, directory, lambda d: marker not in body(d), terminal)
        require(body(undone) == BEFORE + "\n\n" + AFTER and len(undone["attachments"]) == 1,
                "image Undo discarded following text or forgot the dormant image")
        capture(terminal, captures, "clipboard-inline-after-undo")
        narrow_clipboard(terminal, captures, "clipboard-inline-dormant-narrow", dormant=True)
        terminal.send(b"\x19")
        terminal.until(lambda: " · inline" in terminal.text() and "not in body, won't be sent" not in terminal.text())
        saved_until(binary, directory, lambda d: marker in body(d), terminal)
        # One explicit mock-provider send reaches the real outgoing MIME path.
        # Parse it independently of Omagma's renderer/parser as an external
        # oracle for the exact screenshot bytes, CID uniqueness and position.
        terminal.send(b"\x13")
        terminal.until(lambda: send_review_ready(terminal))
        terminal.send(b"y")
        terminal.until(lambda: "Sending in " in terminal.text() and "[Send now" in terminal.text())
        require("nothing sent yet" in terminal.text(), "explicit fixture countdown was not retained")
        terminal.send(b"\x13")  # Deliberate Send now, without waiting at the 10s boundary.
        expected_sends = 1
        terminal.until(lambda: "Send complete · provider accepted" in terminal.text())
        with Client(binary, directory) as client:
            history = client.request("history.operations")
            require(len(history["items"]) == 1 and not history["nextCursor"],
                    "image send did not retain exactly one operation receipt")
            sent = history["items"][0]
            require(sent["outcome"] == "applied" and sent["draftId"] == draft["id"],
                    "image send receipt lost its exact draft association")
            received = client.request("mail.read", messageId=sent["messageId"])
            require(client.request("cache.stats")["fixtureSends"] == 1,
                    "one explicit image send did not produce exactly one mock submission")
        encoded_raw = received["fixtureRaw"]
        raw = base64.urlsafe_b64decode(encoded_raw + "=" * (-len(encoded_raw) % 4))
        mail = BytesParser(policy=policy.default).parsebytes(raw)
        images = [part for part in mail.walk()
                  if str(part.get("Content-ID", "")).strip("<>") == file["contentId"]]
        require(len(images) == 1 and images[0].get_content_disposition() == "inline"
                and images[0].get_content_type() == "image/png", "sent MIME did not have exactly one related screenshot")
        require(images[0].get_payload(decode=True) == IMAGE.read_bytes(), "sent PNG bytes changed")
        html_parts = [part.get_content() for part in mail.walk() if part.get_content_type() == "text/html"]
        plain_parts = [part.get_content() for part in mail.walk() if part.get_content_type() == "text/plain"]
        require(len(html_parts) == 1 and len(plain_parts) == 1, "sent image lost the plain/HTML alternatives")
        sent_html, sent_plain = html_parts[0], plain_parts[0]
        require(sent_html.count("cid:" + file["contentId"]) == 1
                and sent_html.index(BEFORE) < sent_html.index("cid:" + file["contentId"]) < sent_html.index(AFTER),
                "sent HTML duplicated or moved the screenshot")
        require(sent_plain.index(BEFORE) < sent_plain.index("[Image: " + file["filename"] + "]") < sent_plain.index(AFTER)
                and "cid:" + file["contentId"] not in sent_plain, "plain alternative exposed CID syntax or changed paragraph order")
    finally:
        close(terminal, expected_sends=expected_sends)


def plain_case(binary, directory, captures=None):
    terminal = start(binary, directory, captures=captures)
    try:
        terminal.send(b"\x14")
        terminal.until(lambda: "Plain" in terminal.text() and "[Markdown Ctrl+T]" in terminal.text())
        terminal.send(b"\x16")
        terminal.until(lambda: "inline paste needs a Markdown body" in terminal.text())
        draft = saved_until(binary, directory, lambda d: len(d["attachments"]) == 1, terminal)
        require(draft["bodyFormat"] == "plain" and body(draft) == BEFORE,
                "Plain image paste reinterpreted or edited authored source")
        require(draft["attachments"][0].get("contentId") is None
                and draft["attachments"][0]["mimeType"] == "image/png", "Plain paste created a CID image")
        # Terminal text paste stays ordinary text even if a raw Ctrl+V appears.
        terminal.send(b"\x1b[200~\x16 bracketed text\x1b[201~")
        terminal.until(lambda: "bracketed text" in terminal.text())
        unchanged = saved_until(binary, directory, lambda d: "bracketed text" in body(d), terminal)
        require(len(unchanged["attachments"]) == 1, "Ctrl+V inside bracketed paste read an image")
        require(not stages(directory), "ordinary clipboard attachment left a staging file")
    finally:
        close(terminal)


def errors_case(binary, directory, captures=None):
    for mode, copy in (("empty", "No image on clipboard. Use your terminal's paste for text."),
                       ("missing", "Image paste needs wl-paste (wl-clipboard)."),
                       ("unavailable", "Image paste unavailable here: needs a local Wayland or macOS clipboard."),
                       ("invalid", "Couldn't read clipboard image."),
                       ("large", "Clipboard image exceeds 25 MiB. Save it and attach with A."),
                       ("hang", "Couldn't read clipboard image.")):
        owned = Path(directory) / mode
        terminal = start(binary, owned, mode, captures)
        try:
            terminal.send(b"\x16")
            terminal.until(lambda: copy in terminal.text(), seconds=13)
            require(not stages(owned), "failed clipboard capture leaked a staging file")
            draft = saved_until(binary, owned, lambda d: body(d) == BEFORE, terminal)
            require(not draft["attachments"], "failed capture attached bytes or inserted a marker")
            # Assert the explicit outcome remains after the independent local
            # autosave acknowledgement has completed, including the10s timeout.
            terminal.gap(.1)
            require(copy in terminal.text(), "autosave erased the explicit clipboard outcome")
        finally:
            close(terminal)
    # Changing the prefix must cancel before local import and preserve edits.
    owned = Path(directory) / "stale-prefix"
    terminal = start(binary, owned, "slow", captures)
    try:
        terminal.send(b"\x16\x01\x1b[3~Changed: ")
        terminal.until(lambda: "Image paste canceled: text before it changed. Paste again." in terminal.text())
        draft = saved_until(binary, owned, lambda d: body(d).startswith("Changed: "), terminal)
        require(not draft["attachments"] and not stages(owned), "stale paste imported an image or left staging")
    finally:
        close(terminal)


def cancel_case(binary, directory, captures=None):
    terminal = start(binary, directory, "hang", captures)
    try:
        terminal.send(b"\x16")
        terminal.until(lambda: bool(stages(directory)) and bool(descendants(terminal.process.pid)))
        owned_children = descendants(terminal.process.pid)
        staged = stages(directory)
        require(len(staged) == 1 and stat.S_IMODE(staged[0].stat().st_mode) == 0o700
                and staged[0].stat().st_uid == os.getuid(),
                "clipboard staging directory is not unique and owner-only")
        paths = list(staged[0].iterdir())
        require(len(paths) == 1 and stat.S_IMODE(paths[0].stat().st_mode) == 0o600
                and paths[0].stat().st_uid == os.getuid() and paths[0].stat().st_nlink == 1,
                "clipboard plaintext staging is not owner-only")
        terminal.send(b"\x16\x16")
        terminal.gap(.1)
        require(descendants(terminal.process.pid) == owned_children and stages(directory) == staged,
                "repeated shortcut started another clipboard worker")
        terminal.send(b"\x03")
        terminal.until(lambda: "Operation canceled" in terminal.text())
        require(not descendants(terminal.process.pid) and not stages(directory),
                "cancel left a clipboard helper or plaintext staging file")
        draft = saved_until(binary, directory, lambda d: body(d) == BEFORE, terminal)
        require(not draft["attachments"], "canceled capture changed the draft")
    finally:
        close(terminal)


def regular_typing_case(binary, directory, captures=None):
    # The deliberate fixture delays are in plan/import, after clipboard capture
    # succeeds; this reproduces the exact previous swallowed-input interval.
    for header in (False, True):
        owned = Path(directory) / ("header" if header else "plain-body")
        terminal = start(binary, owned, "slow-attach", captures)
        try:
            if header:
                terminal.send(b"\x1b[Z" * 4 + b"\x05")
                terminal.until(lambda: "INSERT" in terminal.text() and "Recipient" in terminal.text())
            else:
                terminal.send(b"\x14")
                terminal.until(lambda: "[Markdown Ctrl+T]" in terminal.text())
            terminal.send(b"\x16")
            terminal.until(lambda: "Checking the selected files" in terminal.text())
            terminal.send(b", second" if header else b"\r\rTyped during planning.")
            terminal.until(lambda: "Importing attachment 1/1" in terminal.text())
            terminal.send(b"@example.test" if header else b"\r\rTyped during import.")
            terminal.until(lambda: "inline paste needs a Markdown body" in terminal.text())
            draft = saved_until(binary, owned, lambda d: len(d["attachments"]) == 1, terminal)
            fields = draft.get("recoveryFields")
            if header:
                to_text = fields[0] if fields else ", ".join(recipient["address"] for recipient in draft["to"])
                require(to_text == "peer@example.test, second@example.test" and body(draft) == BEFORE,
                        "header typing during clipboard planning/import was lost or moved into the body")
            else:
                require(body(draft) == BEFORE + "\n\nTyped during planning.\n\nTyped during import."
                        and draft["bodyFormat"] == "plain", "Plain typing during clipboard planning/import was lost")
            require(draft["attachments"][0].get("contentId") is None and not stages(owned),
                    "regular typing converted image policy or leaked staging")
            capture(terminal, captures, "clipboard-regular-typing-" + ("header" if header else "plain"))
        finally:
            close(terminal)


def helper_case(binary, directory, captures=None):
    # Direct child fixtures exercise real binary dispatch without touching the
    # global clipboard. Darwin uses only a uniquely named synthetic pasteboard.
    directory.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, HOME=str(directory), SSH_TTY="fixture-no-local-clipboard")
    modes = ("png", "mac-png", "mac-tiff", "mac-retina-tiff") if sys.platform == "darwin" else ("png",)
    for mode in modes:
        result = subprocess.run([str(binary), "__clipboard-image", "--fixtures", mode],
                                env=env, capture_output=True, timeout=12)
        require(result.returncode == 0 and not result.stderr, "private clipboard helper fixture failed")
        dimensions = (3840).to_bytes(4, "big") + (2160).to_bytes(4, "big") if mode == "mac-retina-tiff" else IMAGE.read_bytes()[16:24]
        require(result.stdout[:8] == b"\x89PNG\r\n\x1a\n" and result.stdout[16:24] == dimensions,
                "private clipboard helper changed screenshot dimensions")
        require(len(result.stdout) <= 25 * 1024 * 1024,
                "private TIFF conversion exceeded the parent PNG stream allowance")
        if mode in {"png", "mac-png"}:
            require(result.stdout == IMAGE.read_bytes(), "PNG helper changed exact source bytes")
    rejected = subprocess.run([str(binary), "__clipboard-image"], env=env,
                              capture_output=True, timeout=12)
    require(rejected.returncode == 2 and not rejected.stdout and not rejected.stderr,
            "SSH clipboard helper attempted to read the host's clipboard")


def run_case(case, binary, directory, captures=None):
    {"clipboard-inline": inline_case, "clipboard-plain": plain_case,
     "clipboard-errors": errors_case, "clipboard-cancel": cancel_case, "clipboard-helper": helper_case, "clipboard-regular-typing": regular_typing_case}[case](binary, Path(directory), captures)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    build = read_build_info(binary)
    with tempfile.TemporaryDirectory(prefix="omagma-clipboard-fixtures-") as temporary:
        for case in args.case or CASES:
            run_case(case, binary, Path(temporary) / case, args.capture_dir)
    print(f"clipboard image fixtures passed: {build['appVersion']}")


if __name__ == "__main__":
    main()
