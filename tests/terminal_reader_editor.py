#!/usr/bin/env python3
"""Received-mail editor snapshots in owned fictional PTYs; no desktop or live mail.

CASES and the module-local MouseTerminal factory are reusable by native Darwin
guardian adapters. Runtime suites require the coordinator's host reservation.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import signal
import sys
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_cache import digests
from terminal_html import screen_capture
from terminal_integration import Client, require
from terminal_mouse import MouseTerminal as OwnedMouseTerminal, click, list_point
from terminal_mouse_screen import MouseScreen
from terminal_reader import reader_contains


MouseTerminal = OwnedMouseTerminal
if sys.platform == "darwin":
    from terminal_macos import DarwinTerminal

    # The shared workflow runner may already have installed the guardian.
    if not issubclass(OwnedMouseTerminal, DarwinTerminal):
        class GuardianMouseTerminal(DarwinTerminal, OwnedMouseTerminal):
            pass

        MouseTerminal = GuardianMouseTerminal


ACCOUNT = "personal@example.com"
MESSAGE = "reader-editor-message-1"
SECOND = "reader-editor-message-2"
SUBJECT = "Fictional reader editor snapshot"
URL = ("https://example.org/reports/fictional-original-message/complete-plaintext/"
       "review-notes?section=received-reader&review=owned-pty-editor&literal="
       "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-keep-this-entire-url")
BODY = ("Reader editor fixture original body.\n\n"
        "This full message is independent of its metadata snippet.\n"
        + URL + "\n\nCafé and emoji 👋 remain original received text.\n"
        "Final original body line stays intact after local editor changes.\n")
SECOND_BODY = "Second fictional received body; mouse navigation after editor works.\n"
LOCAL_EDIT = "LOCAL SNAPSHOT EDIT ONLY. This must never replace received mail.\n"
MOUSE_MODES = {1002, 1004, 1006}


class ReaderScreen(MouseScreen):
    """Wait for synchronized VT frame completion before testing rendered state."""
    def __init__(self, columns=160, rows=42):
        super().__init__(columns, rows)
        self.frame_open = False
        self.completed_frames = 0

    def csi(self, sequence, final):
        super().csi(sequence, final)
        if sequence == "?2026" and final in {"h", "l"}:
            self.frame_open = final == "h"
            if final == "l":
                self.completed_frames += 1


# Development-only editor script is created inside each owned temporary case.
# It uses direct argv and the same controlling PTY; it opens no browser/network.
EDITOR_SCRIPT = r'''import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import termios
import time
import tty


def private_write(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(value)


def normalize(settings):
    return [*settings[:6], [x[0] if isinstance(x, bytes) else x for x in settings[6]]]


def main():
    path = Path(sys.argv[-1])
    log = Path(os.environ["OMAGMA_EDITOR_TEST_LOG"])
    settings = termios.tcgetattr(0)
    deadline = time.monotonic() + 5
    while os.tcgetpgrp(0) != os.getpgrp():
        if time.monotonic() >= deadline:
            raise RuntimeError("owned editor did not receive foreground terminal")
        time.sleep(.005)
    initial = path.read_bytes()
    file_stat, dir_stat = path.stat(), path.parent.stat()
    backup = path.with_name("message.txt~")
    private_write(backup, initial)
    receipt = {"syntheticOnly": True, "entered": True, "argv": sys.argv[1:-1],
        "path": str(path), "directory": str(path.parent), "filename": path.name,
        "initialText": initial.decode("utf-8"), "initialSha256": hashlib.sha256(initial).hexdigest(),
        "fileMode": stat.S_IMODE(file_stat.st_mode), "directoryMode": stat.S_IMODE(dir_stat.st_mode),
        "fileOwner": file_stat.st_uid, "directoryOwner": dir_stat.st_uid, "fileLinks": file_stat.st_nlink,
        "stdinIsTty": sys.stdin.isatty(), "stdoutIsTty": sys.stdout.isatty(),
        "pid": os.getpid(), "processGroup": os.getpgrp(), "sessionId": os.getsid(0),
        "foregroundGroup": os.tcgetpgrp(0), "terminalSettings": normalize(settings),
        "backupPath": str(backup), "backupCreated": backup.is_file()}
    private_write(log, (json.dumps(receipt, ensure_ascii=False) + "\n").encode())
    try:
        tty.setraw(0)
        os.write(1, b"\r\nOWNED RECEIVED SNAPSHOT EDITOR: s save, x quit, r save/nonzero, d delete, f FIFO, i invalid, l symlink\r\n")
        action = os.read(0, 1)
        code = 0
        if action in {b"s", b"r"}:
            replacement = path.with_name("replacement.txt")
            changed = os.environ["OMAGMA_READER_LOCAL_EDIT"].encode()
            private_write(replacement, changed)
            replacement.replace(path)
            receipt["editedSha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            code = 17 if action == b"r" else 0
        elif action == b"d":
            path.unlink()
        elif action == b"f":
            path.unlink()
            os.mkfifo(path, 0o600)
        elif action == b"i":
            private_write(path, b"\xff\x00invalid local snapshot")
        elif action == b"l":
            path.unlink()
            path.symlink_to(os.environ["OMAGMA_READER_OUTSIDE"])
        elif action != b"x":
            raise RuntimeError("unexpected owned editor fixture action")
        receipt.update(action=action.decode("ascii"), exitCode=code)
        private_write(log, (json.dumps(receipt, ensure_ascii=False) + "\n").encode())
        return code
    finally:
        termios.tcsetattr(0, termios.TCSANOW, settings)


raise SystemExit(main())
'''


def private_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def payload(message_id, subject, body, timestamp):
    data = body.encode()
    return {"id": message_id, "threadId": "thread-" + message_id,
        "labelIds": ["INBOX", "UNREAD"], "internalDate": str(timestamp),
        "snippet": "Metadata snippet is not the full reader/editor body.",
        "payload": {"mimeType": "text/plain", "headers": [
            {"name": "From", "value": "Alex Sender <alex@example.org>"},
            {"name": "To", "value": "Taylor Reader <personal@example.com>"},
            {"name": "Cc", "value": "Casey Copy <copy@example.org>"},
            {"name": "Subject", "value": subject},
            {"name": "Date", "value": "Mon, 08 Jun 2026 02:30:00 +0000"},
            {"name": "Message-ID", "value": "<" + message_id + "@example.org>"},
            {"name": "Content-Type", "value": "text/plain; charset=utf-8"},
            {"name": "Content-Transfer-Encoding", "value": "base64"}],
            "body": {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}}}


def prepare(binary, directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = directory.resolve()
    corpus = directory / "fixture"
    accounts = corpus / "accounts"
    accounts.mkdir(mode=0o700, parents=True)
    private_json(accounts / "personal.json", {"account": ACCOUNT,
        "messages": [payload(MESSAGE, SUBJECT, BODY, 1780871400000),
                     payload(SECOND, "Second fictional reader message", SECOND_BODY, 1780871300000)],
        "sync": {"historyId": "100"}})
    config = directory / "fictional-config.json"
    private_json(config, {"oauthClientFile": "", "chrome": "/nonexistent/fictional-browser",
        "chromeUserData": "", "accounts": [{"address": ACCOUNT, "profile": "Profile 1",
            "enabled": True, "required": True}]})
    script = directory / "owned_reader_editor_fixture.py"
    script.write_text(EDITOR_SCRIPT)
    script.chmod(0o600)
    outside = directory / "outside-sentinel.txt"
    outside.write_text("Independent fictional sentinel must remain untouched.\n")
    outside.chmod(0o600)
    extra = ("--fixture-root", str(corpus), "--config", str(config), "--prefetch-bodies", "0")
    with Client(binary, directory, extra=extra) as client:
        client.request("mail.list", limit=2, label="INBOX")
        require(client.request("mail.read", messageId=MESSAGE)["bodyText"] == BODY,
                "fixture full body differs from independent reader-editor oracle")
        require(client.request("mail.read", messageId=SECOND)["bodyText"] == SECOND_BODY,
                "second cached navigation fixture body differs")
    require(client.process.returncode == 0 and not client.stderr, "seed CLI failed cleanup")
    return directory, extra, script, outside


def state(binary, directory, extra):
    with Client(binary, directory, extra=extra) as client:
        result = {"message": client.request("mail.read", messageId=MESSAGE, cacheOnly=True),
            "drafts": client.request("draft.list")["drafts"],
            "operations": client.request("operation.list")["operations"],
            "queue": client.request("queue.list")["queue"],
            "sends": client.request("cache.stats", cacheOnly=True)["fixtureSends"]}
    require(client.process.returncode == 0 and not client.stderr, "oracle CLI failed cleanup")
    result["bodyDigests"] = digests(directory, ACCOUNT)
    require(result["message"]["bodyText"] == BODY and result["sends"] == 0,
            "received body/no-send baseline is invalid")
    return result


def capture(terminal, capture_dir, name, extra=None):
    if capture_dir is None:
        return
    capture_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_json(capture_dir / (name + ".json"),
                 {"syntheticOnly": True, **screen_capture(terminal), **(extra or {})})


def normalized_settings(settings):
    return [*settings[:6], [value[0] if isinstance(value, bytes) else value for value in settings[6]]]


def ready(terminal):
    return (not terminal.screen.frame_open
            and reader_contains(terminal.screen, BODY.splitlines()[0])
            and "Fetching" not in terminal.text())


def wait(terminal, phase, predicate):
    terminal.reader_editor_phase = phase
    try:
        terminal.until(predicate)
    except Exception as error:
        diagnostic = {"phase": phase, "frameOpen": terminal.screen.frame_open,
            "completedFrames": terminal.screen.completed_frames,
            "mouseModes": sorted(terminal.screen.mouse_modes),
            "mouseTrackingMode": terminal.screen.mouse_tracking_mode,
            "originalBodyVisible": reader_contains(terminal.screen, BODY.splitlines()[0]),
            "editorLogExists": terminal.editor_log.exists(), "processExitCode": terminal.process.poll()}
        print(json.dumps(diagnostic), file=sys.stderr)
        raise AssertionError(f"{phase}: {error}") from error


def start(binary, directory, extra, script, outside):
    literal = "$(touch " + str(directory / "must-not-exist") + ")"
    terminal = MouseTerminal(binary, directory, extra=extra, columns=160, rows=42,
        screen_type=ReaderScreen, environment={"TZ": "UTC0", "NO_COLOR": None, "COLORTERM": "truecolor",
            "EDITOR": shlex.join([sys.executable, str(script), "--literal", literal]),
            "OMAGMA_READER_LOCAL_EDIT": LOCAL_EDIT, "OMAGMA_READER_OUTSIDE": str(outside)})
    try:
        wait(terminal, "startup received body", lambda: ready(terminal))
        terminal.send(b"\r")
        wait(terminal, "startup focused reader", lambda: ready(terminal)
             and "V Select" in terminal.text() and "e Editor" in terminal.text())
        wait(terminal, "startup mouse reporting", lambda: terminal.screen.mouse_modes == MOUSE_MODES
             and terminal.screen.mouse_tracking_mode == 1002)
    except Exception:
        print(terminal.text(), file=sys.stderr)
        terminal.close()
        raise
    return terminal, literal


def editor_input_ready(terminal, output_start):
    # The receipt is written before setraw(). Earlier editor prompts remain
    # on the normal screen across TUI takeovers, so only a newly emitted
    # prompt proves this editor has completed its raw-input handoff.
    return (terminal.editor_log.exists()
            and b"OWNED RECEIVED SNAPSHOT EDITOR:" in terminal.output[output_start:])


def enter_editor(terminal, directory, literal, via_command=False):
    terminal.editor_log.unlink(missing_ok=True)
    output_start = len(terminal.output)
    terminal.send(b":view-editor\r" if via_command else b"e")
    wait(terminal, "external editor entered", lambda: editor_input_ready(terminal, output_start))
    entry = json.loads(terminal.editor_log.read_text())
    snapshot = Path(entry["path"])
    require(snapshot.name == "message.txt" and snapshot.parent.name.startswith("omagma-reader-"),
            "received editor opened a compose draft instead of its disposable snapshot")
    require(snapshot.resolve().is_relative_to(directory / "runtime"),
            "snapshot escaped its owned private runtime directory")
    require(entry["fileMode"] == 0o600 and entry["directoryMode"] == 0o700
            and entry["fileOwner"] == entry["directoryOwner"] == os.geteuid()
            and entry["fileLinks"] == 1, "snapshot owner/modes/link count are not private")
    require(entry["stdinIsTty"] and entry["stdoutIsTty"]
            and entry["foregroundGroup"] == entry["processGroup"],
            "editor did not own its controlling foreground PTY")
    require(entry["terminalSettings"] == normalized_settings(terminal.settings),
            "editor takeover did not restore the original terminal settings")
    require(entry["argv"] == ["--literal", literal] and not terminal.injection_sentinel.exists(),
            "editor argv was evaluated or changed")
    headers, separator, body = entry["initialText"].partition("\n\n")
    require(separator and body == BODY and URL in body and LOCAL_EDIT not in body,
            "snapshot lost the full original plain body/URL or retained a previous local edit")
    envelope = dict(line.split(": ", 1) for line in headers.splitlines())
    require(envelope.get("From") == "Alex Sender <alex@example.org>"
            and "Taylor Reader" in envelope.get("To", "") and ACCOUNT in envelope.get("To", "")
            and "Casey Copy" in envelope.get("Cc", "") and "copy@example.org" in envelope.get("Cc", "")
            and envelope.get("Subject") == SUBJECT and bool(envelope.get("Date")),
            "snapshot envelope is incomplete or differs from the received message")
    require(entry["backupCreated"] and Path(entry["backupPath"]).is_file(),
            "fixture did not create a private editor backup for cleanup")
    wait(terminal, "external editor mouse suspended", lambda: terminal.screen.mouse_modes == set())
    return entry


def discarded(entry, directory):
    require(not Path(entry["directory"]).exists() and not Path(entry["backupPath"]).exists(),
            "received snapshot or editor backup was retained after viewer exit")
    require(not list((directory / "runtime").glob("omagma-reader-*")),
            "viewer left another private snapshot directory behind")


def restored_controls(terminal):
    wait(terminal, "reader/mouse restored", lambda: ready(terminal)
         and terminal.screen.mouse_modes == MOUSE_MODES and terminal.screen.mouse_tracking_mode == 1002)
    terminal.send(b"?")
    terminal.until(lambda: not terminal.screen.frame_open and "Keyboard & mouse" in terminal.text())
    terminal.send(b"q")
    terminal.until(lambda: ready(terminal) and "Keyboard & mouse" not in terminal.text())
    # Observe an actual SGR click changing the received message, then restore it.
    click(terminal, *list_point(terminal, 1))
    terminal.until(lambda: not terminal.screen.frame_open
                   and reader_contains(terminal.screen, SECOND_BODY))
    click(terminal, *list_point(terminal, 0))
    terminal.until(lambda: ready(terminal))
    terminal.send(b"\r")
    wait(terminal, "focused reader restored", lambda: ready(terminal)
         and "V Select" in terminal.text() and "e Editor" in terminal.text())
    require(LOCAL_EDIT not in terminal.text(), "local editor changes appeared in the received reader")


def exercise(binary, directory, capture_dir, name, actions, via_command=False, interrupt=False):
    directory, extra, script, outside = prepare(binary, directory)
    outside_digest = hashlib.sha256(outside.read_bytes()).hexdigest()
    terminal = None
    try:
        terminal, literal = start(binary, directory, extra, script, outside)
        before = state(binary, directory, extra)
        require(not before["drafts"] and not before["operations"] and not before["queue"],
                "reader-editor fixture unexpectedly starts with local write state")
        observations = []
        for action in actions:
            if via_command:
                # A narrower viewport cannot be the source for a complete URL/body copy.
                terminal.resize(110, 30)
                terminal.until(lambda: ready(terminal))
            entry = enter_editor(terminal, directory, literal, via_command=via_command)
            capture(terminal, capture_dir, name + "-" + action + "-editor", {"editor": entry})
            if interrupt:
                result = terminal.finish(signal_mode=signal.SIGTERM)
                try:
                    os.kill(entry["pid"], 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("owned editor child was not reaped after TUI interruption")
            else:
                terminal.send(action.encode())
                notice = ("Editor exited with 17" if action == "r" else "Editor view closed")
                terminal.until(lambda: ready(terminal) and notice in terminal.text()
                               and "received mail unchanged" in terminal.text()
                               and "exitCode" in json.loads(terminal.editor_log.read_text()))
                ended = json.loads(terminal.editor_log.read_text())
                require(ended["exitCode"] == (17 if action == "r" else 0),
                        "editor fixture did not produce its intended exit outcome")
                if action in {"s", "r"}:
                    require(ended.get("editedSha256") == hashlib.sha256(LOCAL_EDIT.encode()).hexdigest()
                            and ended["editedSha256"] != ended["initialSha256"],
                            "save-discard oracle ran without a real local snapshot edit")
                restored_controls(terminal)
                result = None
            discarded(entry, directory)
            require(hashlib.sha256(outside.read_bytes()).hexdigest() == outside_digest,
                    "snapshot cleanup followed a symlink or changed an unrelated file")
            require(state(binary, directory, extra) == before,
                    "received editor changed cached bodies, labels, drafts, receipts, queue or send count")
            observations.append({"action": action, "openedVia": "command" if via_command else "reader-e",
                "privateSnapshot": True, "fullLiteralUrlAndEnvelope": True,
                "discarded": True, "receivedAndLocalWriteStateUnchanged": True})
            capture(terminal, capture_dir, name + "-" + action + "-returned")
        if not interrupt:
            result = terminal.finish()
        require(result["termiosRestored"] and result["exitCode"] == 0,
                "received editor workflow did not restore and exit its owned terminal")
        require(state(binary, directory, extra) == before, "received editor exit mutated persistent state")
        return {"observations": observations, "termiosRestored": True,
            "mouseAndInputRestored": not interrupt, "interruptionReaped": interrupt,
            "fixtureSends": 0, "snapshotBackupsRemoved": True}
    except Exception:
        if terminal is not None:
            print(terminal.text(), file=sys.stderr)  # Only owned fictional cells.
            capture(terminal, capture_dir, name + "-failure")
        raise
    finally:
        if terminal is not None:
            terminal.close()


def save_case(binary, directory, capture_dir=None):
    return exercise(binary, directory, capture_dir, "reader-editor-save", ("s",))


def cancel_case(binary, directory, capture_dir=None):
    return exercise(binary, directory, capture_dir, "reader-editor-cancel", ("x",), via_command=True)


def nonzero_case(binary, directory, capture_dir=None):
    return exercise(binary, directory, capture_dir, "reader-editor-nonzero", ("r",))


def invalid_case(binary, directory, capture_dir=None):
    return exercise(binary, directory, capture_dir, "reader-editor-invalid", ("d", "f", "i", "l"))


def interrupt_case(binary, directory, capture_dir=None):
    return exercise(binary, directory, capture_dir, "reader-editor-interrupt", ("signal",), interrupt=True)


CASES = (("reader-editor-save", save_case), ("reader-editor-cancel", cancel_case),
         ("reader-editor-nonzero", nonzero_case), ("reader-editor-invalid", invalid_case),
         ("reader-editor-interrupt", interrupt_case))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, help="Require this mode; otherwise use the binary's reported mode")
    parser.add_argument("--case", choices=[name for name, _ in CASES], action="append")
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "test binary absent")
    if args.output:
        require(not args.output.exists(), "preserve previous reader-editor receipt")
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt = {**read_build_info(binary, args.build_mode),
        "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "platform": sys.platform, "architecture": platform.machine(),
        "syntheticOnly": True, "liveWrites": False, "desktopUsed": False,
        "guardianTty": sys.platform == "darwin", "cases": [], "passed": False}
    selected = set(args.case or [name for name, _ in CASES])
    with tempfile.TemporaryDirectory(prefix="omagma-reader-editor-") as temporary:
        root = Path(temporary).resolve()
        for name, case in CASES:
            if name not in selected:
                continue
            result = {"name": name, "passed": False}
            began = time.monotonic()
            try:
                result.update(case(binary, root / name, args.capture_dir))
                result["passed"] = True
            except Exception as error:
                result["error"] = f"{type(error).__name__}: {error}"
            result["elapsedSeconds"] = round(time.monotonic() - began, 4)
            receipt["cases"].append(result)
            if args.output:
                private_json(args.output, receipt)
            print(json.dumps(result), flush=True)
            if not result["passed"]:
                return 1
    receipt["passed"] = len(receipt["cases"]) == len(selected)
    if args.output:
        private_json(args.output, receipt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
