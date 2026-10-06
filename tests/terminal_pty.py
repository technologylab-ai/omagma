#!/usr/bin/env python3
"""Own-PTY terminal/editor checks; never drives a desktop or user's terminal."""
from __future__ import annotations

import argparse
import base64
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import selectors
import shlex
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import time

from build_info import build_mode, read_build_info
from terminal_integration import Client
from terminal_screen import Screen
from terminal_help import scroll_help_to

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/terminal"
QUERIES = {b"\x1b[6n": b"\x1b[1;1R", b"\x1b[c": b"\x1b[?1;2c", b"\x1b[>c": b"\x1b[>0;136;0c",
           b"\x1b[14t": b"\x1b[4;480;1000t", b"\x1b[16t": b"\x1b[6;20;10t", b"\x1b[18t": b"\x1b[8;24;100t",
           b"\x1b[?u": b"\x1b[?0u", b"\x1b[>q": b"\x1bP>|Omagma-test(1.0)\x1b\\"}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def child_session():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class Terminal:
    def __init__(self, binary, directory, extra=(), history_limit=None, environment=None, screen_type=Screen, columns=100, rows=24):
        self.binary = binary
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.master, self.slave = os.openpty()
        self.columns, self.rows = columns, rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, rows * 20, columns * 10))
        self.settings = termios.tcgetattr(self.slave)
        self.output = bytearray()
        self.output_total = 0
        self.history_limit = history_limit
        self.screen = screen_type(columns, rows)
        self.scan_offset = 0
        self.query_replies = 0
        self.editor_log = self.directory / "editor.json"
        self.injection_sentinel = self.directory / "must-not-exist"
        editor = [sys.executable, str(FIXTURES / "editor_fixture.py"), "--label",
                  f"literal $(touch {self.injection_sentinel})"]
        env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8",
                   HOME=str(self.directory / "home"), TMPDIR=str(self.directory),
                   EDITOR=shlex.join(editor), OMAGMA_EDITOR_TEST_LOG=str(self.editor_log))
        for name in ["CONFIG", "CACHE", "DATA", "STATE"]:
            env[f"XDG_{name}_HOME"] = str(self.directory / name.lower())
        if environment:
            for name, value in environment.items():
                if value is None:
                    env.pop(name, None)
                else:
                    env[name] = value
        runtime = self.directory / "runtime"
        runtime.mkdir(mode=0o700, exist_ok=True)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        for name in ["DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"]:
            env.pop(name, None)
        self.process = subprocess.Popen([str(binary), "tui", "--fixtures", "--fixture-root", str(FIXTURES),
                                         "--cache-dir", str(self.directory / "cache"), *extra],
                                        stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                        cwd=self.directory, env=env, preexec_fn=child_session)
        os.set_blocking(self.master, False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.master, selectors.EVENT_READ)

    def send(self, data):
        os.write(self.master, data)

    def pump(self, seconds=.05):
        for _, _ in self.selector.select(seconds):
            try:
                data = os.read(self.master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    return
                raise
            old_length = len(self.output)
            self.output.extend(data)
            self.output_total += len(data)
            self.screen.feed(data)
            if self.history_limit is None:
                require(len(self.output) <= 8 * 1024**2, "TUI output exceeded diagnostic cap")
            recent = bytes(self.output[max(0, old_length - 32):])
            replies = dict(QUERIES)
            replies[b"\x1b[14t"] = f"\x1b[4;{self.rows * 20};{self.columns * 10}t".encode()
            replies[b"\x1b[18t"] = f"\x1b[8;{self.rows};{self.columns}t".encode()
            for query, reply in replies.items():
                start = max(0, old_length - 32)
                for match in re.finditer(re.escape(query), recent):
                    if start + match.end() > old_length:
                        self.send(reply)
                        self.query_replies += 1
            if self.history_limit is not None and len(self.output) > self.history_limit:
                del self.output[:-self.history_limit]

    def until(self, predicate, seconds=10):
        deadline = time.monotonic() + seconds
        while not predicate():
            require(time.monotonic() < deadline, "isolated PTY condition timed out")
            require(self.process.poll() is None, "TUI exited before expected state")
            self.pump()

    def text(self):
        return self.screen.text()

    def resize(self, columns, rows):
        # Resize only this harness's PTY. The foreground child receives SIGWINCH
        # from the kernel; a fresh cell model waits for the resulting redraw.
        require(20 <= columns <= 300 and 10 <= rows <= 100, "isolated PTY size is out of test bounds")
        self.columns, self.rows = columns, rows
        self.screen = type(self.screen)(columns, rows)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, rows * 20, columns * 10))

    def gap(self, seconds=.25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump(min(.05, deadline - time.monotonic()))

    def close(self):
        # The editor may outlive a failed TUI; clean the owned session either way.
        if self.editor_log.exists():
            editor = json.loads(self.editor_log.read_text())
            try:
                if os.getsid(editor["pid"]) == self.process.pid and os.getpgid(editor["pid"]) == editor["processGroup"]:
                    os.killpg(editor["processGroup"], signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        self.selector.close()
        os.close(self.master)
        os.close(self.slave)

    def finish(self, signal_mode=False, expected_sends=0, already_exited=False):
        if already_exited:
            require(self.process.poll() is not None, "exit oracle used before child actually exited")
        elif signal_mode:
            self.process.send_signal(signal.SIGINT if signal_mode is True else signal_mode)
        deadline = time.monotonic() + 5
        next_back = 0
        backs = 0
        while self.process.poll() is None and time.monotonic() < deadline:
            if not already_exited and not signal_mode and time.monotonic() >= next_back and backs < 5:
                # q now backs through reader/query/modal contexts. Esc first
                # leaves insert/text forms so cleanup never types literal q.
                self.send(b"\x1b")
                self.gap()
                if self.process.poll() is None:
                    self.send(b"q")
                backs += 1
                next_back = time.monotonic() + .4
            self.pump()
        require(self.process.poll() is not None, "TUI did not exit within5s")
        require(self.process.returncode == 0, "TUI did not exit cleanly after the owned workflow")
        restored = termios.tcgetattr(self.slave)
        # Check the complete saved termios tuple, including control characters.
        require(restored == self.settings, "TUI did not restore terminal settings")
        require(not self.injection_sentinel.exists(), "EDITOR argv was evaluated by a shell")
        with Client(self.binary, self.directory) as client:
            stats = client.request("cache.stats")
            require(stats["fixtureSends"] == expected_sends, "provider send count disagreed with explicit confirmation")
        return {"exitCode": self.process.returncode, "termiosRestored": True,
                "shellSubstitutionExecuted": False, "terminalQueryReplies": self.query_replies,
                "unconfirmedFixtureSends": 0, "observedFixtureSends": expected_sends, "outputBytes": self.output_total}


def open_composer(terminal):
    terminal.send(b"c")
    terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text())


def gmail_search(terminal, query):
    # These legacy workflows intentionally fetch older provider mail, so use
    # the explicit Gmail search key rather than the new retained-cache slash.
    terminal.send(b"\\")
    terminal.until(lambda: "Gmail \\ " in terminal.text())
    terminal.send(query.encode() + b"\r")
    terminal.until(lambda: "Gmail search" in terminal.screen.lines()[0])


def compose_fixture(terminal):
    open_composer(terminal)
    terminal.send(b"irecipient@example.org")
    terminal.until(lambda: "recipient@example.org" in terminal.text())
    terminal.send(b"\x1b")
    terminal.gap()
    terminal.send(b"\t\t\tiSynthetic PTY review")
    terminal.until(lambda: "Synthetic PTY review" in terminal.text())
    terminal.send(b"\x1b")
    terminal.gap()
    terminal.send(b"\tiReviewed synthetic PTY body.")
    terminal.until(lambda: "Reviewed synthetic PTY body." in terminal.text())
    terminal.send(b"\x1b")
    terminal.gap()


def retained_draft(terminal, expected_body):
    with Client(terminal.binary, terminal.directory) as client:
        drafts = client.request("draft.list")["drafts"]
        require(len(drafts) == 1, "composer did not retain exactly its local draft")
        draft = client.request("draft.read", draftId=drafts[0]["id"])
        actual_body = draft["bodyText"]
        if actual_body != expected_body:
            offset = next((index for index, pair in enumerate(zip(actual_body, expected_body)) if pair[0] != pair[1]),
                          min(len(actual_body), len(expected_body)))
            surrounding = slice(max(0, offset - 32), offset + 96)
            require(False, "retained draft body mismatch: " + json.dumps({
                "firstDifferingCharacter": offset, "actualBytes": len(actual_body.encode()),
                "expectedBytes": len(expected_body.encode()), "actualCharacters": len(actual_body),
                "expectedCharacters": len(expected_body), "actualContext": actual_body[surrounding],
                "expectedContext": expected_body[surrounding]}, ensure_ascii=True))
    return {"draftRetained": True, "bodyBytes": len(expected_body.encode())}


def long_invitation_fixture(directory):
    fixture = directory / "long-invitation-fixtures"
    (fixture / "accounts").mkdir(parents=True, mode=0o700)
    for name in ["personal", "work", "optional"]:
        shutil.copyfile(FIXTURES / "accounts" / f"{name}.json", fixture / "accounts" / f"{name}.json")
    path = fixture / "accounts/personal.json"
    data = json.loads(path.read_text())
    target = next(message for message in data["messages"] if message["id"] == "shared-msg-009")
    summary = "Synthetic long RSVP summary " + "topic " * 75
    uid = "fixture-" + "u" * 880 + "-UID-END@example.org"

    def folded(line):
        return "\r\n ".join(line[offset:offset+70] for offset in range(0, len(line), 70))

    def replace_calendar(part):
        if part.get("mimeType") == "text/calendar":
            value = part["body"]["data"]
            calendar = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode()
            calendar = calendar.replace("UID:fixture-meeting@example.org", folded("UID:" + uid))
            calendar = calendar.replace("SUMMARY:Synthetic meeting", folded("SUMMARY:" + summary))
            encoded = calendar.encode()
            part["body"].update(size=len(encoded), data=base64.urlsafe_b64encode(encoded).rstrip(b"=").decode())
            return 1
        return sum(replace_calendar(child) for child in part.get("parts", []))

    require(replace_calendar(target["payload"]) == 1, "long invitation fixture did not modify exactly one calendar part")
    path.write_text(json.dumps(data))
    return fixture


def exercise(terminal, action):
    terminal.until(lambda: "personal@example.com" in terminal.text())
    if action == "interrupt":
        return terminal.finish(signal_mode=True)
    if action == "edit-sigterm":
        open_composer(terminal)
        expected = "Synthetic unsaved termination body."
        terminal.send(b"\t\t\t\ti" + expected.encode())
        terminal.until(lambda: expected in terminal.text())
        result = terminal.finish(signal_mode=signal.SIGTERM)
        result.update(retained_draft(terminal, expected))
        return result
    if action == "utf8-fragments":
        open_composer(terminal)
        terminal.send(b"\t\t\t\ti")
        terminal.until(lambda: "Body: INSERT" in terminal.text())
        expected = ""
        for value, boundary in [("é", 1), ("e\u0301", 2), ("界", 1), ("界", 2),
                                ("👋", 1), ("👋", 2), ("👋", 3), ("👩‍💻", 6)]:
            data = value.encode()
            terminal.send(data[:boundary])
            terminal.gap(.06)
            terminal.send(data[boundary:] + b" ")
            terminal.gap(.06)
            expected += value + " "
        expected += "UTF8-END"
        terminal.send(b"UTF8-END")
        terminal.until(lambda: "UTF8-END" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap()
        result = terminal.finish()
        result.update(retained_draft(terminal, expected), explicitUtf8SplitBoundaries=8)
        return result
    if action == "fifo-local-attachment":
        open_composer(terminal)
        fifo = terminal.directory / "synthetic attachment fifo"
        os.mkfifo(fifo, 0o600)
        terminal.send(b"A")
        terminal.until(lambda: "Attach file path:" in terminal.text())
        started = time.monotonic()
        terminal.send(str(fifo).encode() + b"\r")
        terminal.until(lambda: "Operation failed" in terminal.text(), seconds=2)
        elapsed = time.monotonic() - started
        terminal.send(b"\x1b")
        terminal.gap()
        terminal.send(b"?")
        terminal.until(lambda: "Diagnostic: NotRegularFile" in terminal.text())
        terminal.send(b"q")
        terminal.gap()
        result = terminal.finish()
        with Client(terminal.binary, terminal.directory) as client:
            drafts = client.request("draft.list")["drafts"]
            require(len(drafts) == 1 and not client.request("draft.read", draftId=drafts[0]["id"])["attachments"],
                    "refused FIFO changed the draft attachments")
        result.update(fifoRefused=True, refusalSeconds=round(elapsed, 6))
        return result
    if action == "fifo-editor-readback":
        open_composer(terminal)
        expected = "Synthetic retained body before unsafe editor output."
        terminal.send(b"\t\t\t\ti" + expected.encode())
        terminal.until(lambda: expected in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap()
        terminal.send(b"e")
        terminal.until(lambda: terminal.editor_log.exists())
        terminal.send(b"f")
        terminal.until(lambda: "exitCode" in json.loads(terminal.editor_log.read_text()))
        started = time.monotonic()
        terminal.until(lambda: "Editor: NotRegularFile" in terminal.text(), seconds=2)
        elapsed = time.monotonic() - started
        result = terminal.finish()
        result.update(retained_draft(terminal, expected), fifoEditorReadbackRefused=True,
                      refusalSeconds=round(elapsed, 6))
        return result
    if action == "long-field-caret":
        open_composer(terminal)
        subject = "Café 👋 · " * 60 + "SUBJECT-END"
        terminal.send(b"\t\t\ti" + subject.encode())
        terminal.until(lambda: terminal.screen.locate("SUBJECT-END▏") is not None)
        subject_caret = terminal.screen.locate("SUBJECT-END▏")
        require(subject_caret["row"] == terminal.screen.locate("Subject:")["row"]
                and subject_caret["column"] < 59, "long Subject caret escaped its visible field")
        terminal.send(b"\x1b")
        terminal.gap()
        body = "Café 👋—" * 180 + "BODY-END"
        terminal.send(b"\ti" + body.encode())
        terminal.until(lambda: terminal.screen.locate("BODY-END▏") is not None)
        end_caret = terminal.screen.locate("BODY-END▏")
        require(terminal.screen.locate("Body:")["row"] < end_caret["row"] < 20 and end_caret["column"] < 59,
                "wrapped single-line body caret escaped the composer body pane")
        terminal.send(b"\x1b[H")
        terminal.until(lambda: terminal.screen.locate("▏Café") is not None)
        home_caret = terminal.screen.locate("▏Café")
        require(home_caret["column"] < 59 and home_caret["row"] > terminal.screen.locate("Body:")["row"],
                "Home did not scroll the wrapped body caret back into view")
        terminal.send(b"\x1b[F")
        terminal.until(lambda: terminal.screen.locate("BODY-END▏") is not None)
        terminal.send(b"\x1b[D" * 4)
        terminal.until(lambda: terminal.screen.locate("BODY▏-END") is not None)
        terminal.send(b"!")
        terminal.until(lambda: terminal.screen.locate("BODY!▏-END") is not None)
        terminal.send(b"\x1b")
        terminal.gap()
        result = terminal.finish()
        expected = body[:-4] + "!" + body[-4:]
        result.update(retained_draft(terminal, expected))
        with Client(terminal.binary, terminal.directory) as client:
            draft = client.request("draft.list")["drafts"][0]
            require(draft["subject"] == subject, "horizontal Subject scrolling changed persisted content")
        result.update(longSubjectCaret=subject_caret, wrappedBodyEndCaret=end_caret,
                      wrappedBodyHomeCaret=home_caret, bodyHasNewlines=False)
        return result
    if action == "save-incoming-attachment":
        terminal.until(lambda: "Ready" in terminal.text())
        gmail_search(terminal, "Synthetic personal message 003")
        terminal.until(lambda: "Synthetic personal message 003" in terminal.text() and "Ready" in terminal.text()
                       and "Gmail \\ Synthetic personal message 003" not in terminal.text())
        terminal.until(lambda: "Attachment 1:" in terminal.text() and "Ready" in terminal.text())
        destination = terminal.directory / "received fixture binary.bin"
        command = b":save-attachment 1 " + str(destination).encode() + b"\r"
        terminal.send(command)
        terminal.until(lambda: destination.exists() and "Saved attachment (" in terminal.text())
        expected = json.loads((FIXTURES / "manifest.json").read_text())["attachmentExpected"]
        contents = destination.read_bytes()
        require(len(contents) == expected["size"] and hashlib.sha256(contents).hexdigest() == expected["sha256"],
                "incoming attachment save changed decoded binary bytes or selected the wrong thread attachment")
        require(stat.S_IMODE(destination.stat().st_mode) == 0o600, "saved incoming attachment is not private")
        terminal.send(command)
        terminal.until(lambda: "File already exists" in terminal.text())
        require(destination.read_bytes() == contents, "duplicate attachment destination was overwritten")
        terminal.send(b":save-attachment 1 relative.bin\r")
        terminal.until(lambda: "Operation failed" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap()
        terminal.send(b"?")
        terminal.until(lambda: "Diagnostic: AttachmentSaveSyntax" in terminal.text())
        terminal.send(b"q")
        terminal.gap()
        require(not (terminal.directory / "relative.bin").exists(), "relative attachment path was accepted")
        result = terminal.finish()
        result.update(incomingAttachmentSha256=expected["sha256"], incomingAttachmentBytes=len(contents),
                      literalPathWithSpaces=True, privateMode=True, overwriteRefused=True, relativePathRefused=True)
        return result
    if action == "attach-detach":
        open_composer(terminal)
        data = b"Synthetic PTY attachment.\x00\x7f\x80\xff\n"
        path = terminal.directory / "fixture attachment.bin"
        path.write_bytes(data)
        terminal.send(b"A")
        terminal.until(lambda: "Attach file path:" in terminal.text())
        terminal.send(str(path).encode() + b"\r")
        terminal.until(lambda: "Attached fixture attachment.bin" in terminal.text())
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text() and "Attachment 1: fixture attachment.bin" in terminal.text())
        with Client(terminal.binary, terminal.directory) as client:
            drafts = client.request("draft.list")["drafts"]
            require(len(drafts) == 1, "attachment workflow created an extra draft")
            attachments = client.request("draft.read", draftId=drafts[0]["id"])["attachments"]
            require(len(attachments) == 1 and attachments[0]["filename"] == path.name and attachments[0]["size"] == len(data),
                    "attachment review/save lost file metadata")
            encoded = attachments[0]["data"]
            decoded = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
            require(hashlib.sha256(decoded).digest() == hashlib.sha256(data).digest(), "attachment review/save changed binary bytes")
        terminal.send(b"n")
        terminal.until(lambda: "Compose" in terminal.text())
        terminal.send(b":detach 1\r")
        terminal.until(lambda: "Attachment removed" in terminal.text())
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        require("fixture attachment.bin" not in terminal.text(), "detached attachment remained in send review")
        terminal.send(b"n")
        terminal.until(lambda: "Compose" in terminal.text())
        result = terminal.finish()
        with Client(terminal.binary, terminal.directory) as client:
            draft = client.request("draft.read", draftId=drafts[0]["id"])
            require(not draft["attachments"], "attachment detach was not persisted")
        result.update(attachmentDigestVerified=True, attachmentReviewShown=True, detachPersisted=True)
        return result
    if action in {"review-cancel", "review-send"}:
        compose_fixture(terminal)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        require("recipient@example.org" in terminal.text() and "Reviewed synthetic PTY body." in terminal.text(),
                "send review did not show the actual recipient and complete short body")
        if action == "review-cancel":
            terminal.send(b"n")
            terminal.until(lambda: "Compose" in terminal.text())
            result = terminal.finish()
            result.update(retained_draft(terminal, "Reviewed synthetic PTY body."))
        else:
            terminal.send(b"y")
            terminal.until(lambda: "Saved by mock provider" in terminal.text())
            result = terminal.finish(expected_sends=1)
        result["sendReviewShown"] = True
        result["explicitSendConfirmed"] = action == "review-send"
        return result
    if action == "unknown-send-reopen":
        compose_fixture(terminal)
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text())
        terminal.send(b"y")
        terminal.until(lambda: "Outcome unknown" in terminal.text())
        with Client(terminal.binary, terminal.directory) as client:
            operations = client.request("operation.list")["operations"]
            require(len(operations) == 1 and operations[0]["outcome"] == "unknown", "uncertain TUI submission lacks one durable receipt")
        terminal.send(b"q")
        terminal.until(lambda: "Mail ·" in terminal.text().splitlines()[2])
        terminal.send(b"h")
        terminal.until(lambda: "Accounts / mailboxes" in terminal.text())
        terminal.send(b"jjjjj")
        terminal.gap()
        terminal.send(b"\r")
        terminal.until(lambda: "Drafts" in terminal.text().splitlines()[0] and "Ready" in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "Compose" in terminal.text() and "Outcome unknown" in terminal.text())
        terminal.send(b"\x13")
        terminal.gap(.3)
        require("Sending account:" not in terminal.text(), "reopened uncertain draft allowed a fresh send review")
        result = terminal.finish()
        with Client(terminal.binary, terminal.directory) as client:
            require(client.request("operation.list")["operations"] == operations, "reopened uncertain draft generated a second submission")
        result.update(unknownReceiptPersisted=True, reopenResubmitBlocked=True)
        return result
    if action == "contact-create":
        terminal.until(lambda: "Ready" in terminal.text())
        terminal.send(b"a")
        terminal.until(lambda: "Contacts" in terminal.text() and "Alex Personal Fixture" in terminal.text())
        terminal.send(b"n")
        terminal.until(lambda: "Name:" in terminal.text() and "Email:" in terminal.text())
        terminal.send(b"PTY Contact Fixture\tpty-contact@example.org\x13")
        terminal.until(lambda: "PTY Contact Fixture" in terminal.text() and "Name:" not in terminal.text())
        terminal.send(b"q")
        terminal.gap()
        result = terminal.finish()
        with Client(terminal.binary, terminal.directory) as client:
            contacts = client.request("contacts.search", query="PTY Contact Fixture")["contacts"]
            require(len(contacts) == 1 and contacts[0]["emails"][0]["address"] == "pty-contact@example.org",
                    "interactive contact creation was not persisted")
            require(not client.request("contacts.search", "work@example.com", query="PTY Contact Fixture")["contacts"],
                    "interactive contact creation crossed accounts")
        result["accountScopedContactPersisted"] = True
        return result
    if action == "rsvp-cancel":
        terminal.until(lambda: "Ready" in terminal.text())
        gmail_search(terminal, "subject:Synthetic personal thread 002")
        terminal.until(lambda: "Invitation" in terminal.text() and "Ready" in terminal.text())
        terminal.send(b"I")
        terminal.until(lambda: "Review RSVP" in terminal.text() and "UID:" in terminal.text())
        for expected in ["personal@example.com", "organizer@example.org", "fixture-meeting@example.org"]:
            require(expected in terminal.text(), "RSVP review omitted identity or destination")
        terminal.send(b"\x1b")
        terminal.gap()
        result = terminal.finish()
        result["rsvpReviewShown"] = True
        result["rsvpSubmitted"] = False
        return result
    if action == "long-rsvp-review":
        terminal.until(lambda: "Ready" in terminal.text())
        gmail_search(terminal, "subject:Synthetic personal thread 002")
        terminal.until(lambda: "Invitation" in terminal.text() and "Ready" in terminal.text())
        terminal.send(b"I")
        terminal.until(lambda: "Review RSVP" in terminal.text() and "Attendee:" in terminal.text())

        def identities_visible():
            current = terminal.text()
            require("Account:" in current and "Attendee:" in current and "Organizer:" in current,
                    "RSVP review did not keep labelled account, attendee and organizer visible")
            require("personal@example.com" in current and "organizer@example.org" in current,
                    "long RSVP detail obscured the actual reply identity or destination")
            require("Accept" in current and "Tentative" in current and "Decline" in current and "Cancel" in current,
                    "long RSVP detail clipped response/cancellation controls")

        identities_visible()
        terminal.send(b"\x1b[F")
        terminal.until(lambda: "UID-END@example.org" in terminal.text())
        identities_visible()
        require("20261107T100000Z" in terminal.text(), "scrolled RSVP review omitted its recurring instance")
        terminal.send(b"\x1b")
        terminal.gap()
        result = terminal.finish()
        result.update(longInvitationIdentityAlwaysVisible=True, recurringDetailScrolled=True, rsvpSubmitted=False)
        return result
    if action == "account-page-navigation":
        terminal.until(lambda: "Ready" in terminal.text() and "Synthetic personal thread 031" in terminal.text())
        terminal.send(b"]")
        terminal.until(lambda: "Ready" in terminal.text() and "Synthetic personal thread 021" in terminal.text())
        terminal.send(b"[")
        terminal.until(lambda: "Ready" in terminal.text() and "Synthetic personal thread 031" in terminal.text())
        terminal.send(b"2")
        terminal.until(lambda: "Ready" in terminal.text() and "Synthetic work thread 031" in terminal.text())
        require("Synthetic personal thread" not in terminal.text(), "account switch retained previous account mail")
        terminal.send(b"?")
        scroll_help_to(terminal, "Click · wheel")
        scroll_help_to(terminal, "No editor save or paste sends mail.")
        require("Ctrl+C" in terminal.text() and "quit" in terminal.text(), "help clipped its interruption/quit guidance")
        terminal.send(b"q")
        terminal.gap()
        result = terminal.finish()
        result["accountAndPageGenerationIsolation"] = True
        result["completeHelpVisible"] = True
        return result
    if action == "mail-controls":
        gmail_search(terminal, "subject:Synthetic personal thread 002")
        terminal.until(lambda: "Synthetic personal thread 002" in terminal.text() and "Ready" in terminal.text()
                       and "Gmail \\ subject:Synthetic personal thread 002" not in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "3/3 mails" in terminal.text())
        for card in (2, 1):
            terminal.send(b"{")
            terminal.until(lambda card=card: f"▸ {card}/3" in terminal.text())
        terminal.send(b"t")
        terminal.until(lambda: "Literal terminal controls" in terminal.text())
        require(b"\x1b]52;c;ZmFrZQ==" not in terminal.output, "mail emitted clipboard OSC sequence")
        require(b"\x1b]8;;https://example.org" not in terminal.output, "mail emitted terminal hyperlink sequence")
        terminal.send(b"q")
        terminal.gap()
        result = terminal.finish()
        result["mailControlBytesExecuted"] = False
        return result
    open_composer(terminal)
    layout = {name: terminal.screen.locate(name + ":") for name in ["To", "Cc", "Bcc", "Subject", "Body"]}
    require(all(layout.values()), "composer fields did not render in current terminal cells")
    require([layout[n]["row"] for n in layout] == sorted(layout[n]["row"] for n in layout),
            "composer field positions overlap or reorder")
    require(all(layout[n]["column"] < 60 for n in layout), "composer fields escaped the left split pane")
    require("Draft preview" in terminal.text(), "split composer omitted its own draft preview")
    terminal.send(b"e")
    terminal.until(lambda: terminal.editor_log.exists())
    entered = json.loads(terminal.editor_log.read_text())
    require(entered["fileExists"] and entered["stdinIsTty"] and entered["stdoutIsTty"],
            "external editor did not receive a file and controlling PTY")
    require(any("$(touch " in arg for arg in entered["argv"]), "EDITOR quoting did not preserve literal argv")
    terminal.send({"save": b"s", "cancel": b"x", "save-error": b"r"}[action])
    terminal.until(lambda: "exitCode" in json.loads(terminal.editor_log.read_text()))
    # The restored paint can arrive with the editor-exit log; wait for state, not another frame.
    terminal.until(lambda: "Compose" in terminal.text() and
                   ("Editor returned" if action == "save" else "Editor exited 1") in terminal.text())
    if action in {"save", "save-error"}:
        terminal.until(lambda: "Reviewed fixture editor body." in terminal.text())
    require("Send complete" not in terminal.text(), "editor exit automatically sent the draft")
    result = terminal.finish()
    result.update(retained_draft(terminal, "Reviewed fixture editor body.\nCafé and emoji 👋 remain intact.\n"
                                 if action in {"save", "save-error"} else ""))
    result["composerLayout"] = layout
    result["editor"] = {key: json.loads(terminal.editor_log.read_text())[key]
                        for key in ["fileExists", "stdinIsTty", "stdoutIsTty", "action", "exitCode"]}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    cases = ["save", "cancel", "save-error", "interrupt", "mail-controls", "edit-sigterm", "attach-detach", "review-cancel",
             "review-send", "unknown-send-reopen", "contact-create", "rsvp-cancel", "account-page-navigation",
             "long-field-caret", "save-incoming-attachment", "long-rsvp-review",
             "utf8-fragments", "fifo-local-attachment", "fifo-editor-readback"]
    parser.add_argument("--case", action="append", choices=cases)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output or ROOT / "tests/results" / f"terminal-pty-{args.build_mode}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {**read_build_info(binary, args.build_mode), "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "synthetic": True, "desktopUsed": False, "isolatedPty": True, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-terminal-pty-") as directory:
        for name in args.case or cases:
            receipt = {"name": name}
            terminal = None
            try:
                extra = ("--fixture-scenario", "unknown-send") if name == "unknown-send-reopen" else ()
                if name == "long-rsvp-review":
                    extra = ("--fixture-root", str(long_invitation_fixture(Path(directory))))
                terminal = Terminal(binary, Path(directory) / name, extra=extra)
                receipt.update(exercise(terminal, name), passed=True)
            except Exception as error:
                receipt.update(passed=False, error=f"{type(error).__name__}: {error}")
                if terminal:
                    receipt.update(currentCells=terminal.text().splitlines(), outputBytes=len(terminal.output),
                                   exitCode=terminal.process.poll())
                    diagnostic = output.with_name(f"{output.stem}-{name}.vt.json")
                    diagnostic.write_text(json.dumps({"synthetic": True, "escapedOutput": bytes(terminal.output).decode("utf-8", errors="replace")},
                                                     ensure_ascii=True, indent=2) + "\n")
                    receipt["escapedDiagnosticFile"] = diagnostic.name
            finally:
                if terminal:
                    terminal.close()
            report["cases"].append(receipt)
            print(json.dumps(receipt), flush=True)
    report["passed"] = all(c["passed"] for c in report["cases"])
    output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
