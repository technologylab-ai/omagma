#!/usr/bin/env python3
"""Native macOS synthetic CLI/TTY checks with a live session owner.

Darwin revokes a controlling PTY when its session leader exits. A guardian keeps
the owned session alive while the existing terminal harness verifies the TUI's
restored termios, then exits after the harness acknowledges cleanup.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from terminal_integration import ACCOUNTS, Client, require
from terminal_pty import Terminal
from terminal_reader import reader_contains


def guardian():
    binary = os.environ["OMAGMA_GUARDIAN_BINARY"]
    if len(sys.argv) < 2 or sys.argv[1] != "tui":
        os.execv(binary, [binary, *sys.argv[1:]])
    state = Path(os.environ["OMAGMA_GUARDIAN_STATE"])
    release = Path(os.environ["OMAGMA_GUARDIAN_RELEASE"])
    for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: None)
    child = subprocess.Popen([binary, *sys.argv[1:]])
    def record(code):
        temporary = state.with_suffix(".tmp")
        temporary.write_text(json.dumps({"pid": child.pid, "exitCode": code}))
        temporary.replace(state)
    record(None)
    record(child.wait())
    deadline = time.monotonic() + 30
    while not release.exists() and time.monotonic() < deadline:
        time.sleep(.02)


class ChildStatus:
    def __init__(self, process, state):
        self.process, self.state = process, state

    def value(self):
        return json.loads(self.state.read_text()) if self.state.is_file() else None

    @property
    def pid(self):
        value = self.value()
        return value["pid"] if value else self.process.pid

    def poll(self):
        value = self.value()
        if value is not None and value["exitCode"] is not None:
            return value["exitCode"]
        return self.process.poll()

    @property
    def returncode(self):
        return self.poll()

    def send_signal(self, sig):
        value = self.value()
        require(value is not None and value["exitCode"] is None, "guardian child unavailable for signal test")
        os.kill(value["pid"], sig)


class DarwinTerminal(Terminal):
    def __init__(self, binary, directory, extra=(), history_limit=None, *,
                 columns=140, rows=34, screen_type=None, environment=None):
        directory = Path(directory).resolve()
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.guardian_state = directory / "guardian-state.json"
        self.guardian_release = directory / "guardian-release"
        launcher = directory / "guardian-launcher"
        launcher.write_text(f"#!{sys.executable}\nimport sys\nsys.path.insert(0,{str(Path(__file__).resolve().parent)!r})\nfrom terminal_macos import guardian\nguardian()\n")
        launcher.chmod(0o700)
        settings = {"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0", **(environment or {}),
            "OMAGMA_GUARDIAN_BINARY": str(binary), "OMAGMA_GUARDIAN_STATE": str(self.guardian_state),
            "OMAGMA_GUARDIAN_RELEASE": str(self.guardian_release)}
        options = {} if screen_type is None else {"screen_type": screen_type}
        super().__init__(launcher, directory, extra=extra, history_limit=history_limit,
                         columns=columns, rows=rows, environment=settings, **options)
        self.guardian_process = self.process
        self.process = ChildStatus(self.guardian_process, self.guardian_state)
        self.binary = binary

    def close(self):
        if self.process.poll() is None:
            value = self.process.value()
            if value:
                try:
                    os.kill(value["pid"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 3
                while self.process.poll() is None and time.monotonic() < deadline:
                    self.pump(.02)
                if self.process.poll() is None:
                    try:
                        os.kill(value["pid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        if self.process.poll() is not None:
            self.guardian_release.write_text("owned terminal restoration checked\n")
            try:
                self.guardian_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.guardian_process.kill()
                self.guardian_process.wait(timeout=5)
        self.process = self.guardian_process
        super().close()


def cli_case(binary, directory):
    with Client(binary, directory) as client:
        require(len(client.request("accounts.list", account=None)["accounts"]) == 3, "native account handshake")
        for account in ACCOUNTS:
            page = client.request("mail.list", account, limit=32, label="INBOX")
            require(len(page["messages"]) == 32, "native list window")
            message = client.request("mail.read", account, messageId=page["messages"][0]["id"])
            require(account in message["bodyText"], "native body crossed account")
            require(client.request("cache.stats", account)["fixtureSends"] == 0, "native fixture sent mail")
    require(client.process.returncode == 0 and not client.stderr, "native CLI cleanup")
    print("PASS macOS CLI:3 accounts/list/full bodies/isolation/zero sends/clean exit")


def tui_case(binary, directory, terminate=False, terminate_editor=False):
    terminal = DarwinTerminal(binary, directory)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "Synthetic personal@example.com message 096."))
        if not terminate:
            terminal.send(b"2")
            terminal.until(lambda: reader_contains(terminal.screen, "Synthetic work@example.com message 096."))
            terminal.send(b"j")
            terminal.until(lambda: reader_contains(terminal.screen, "Synthetic work@example.com message 095."))
            terminal.send(b"c")
            terminal.until(lambda: "Subject:" in terminal.text() and "Attach" in terminal.text())
            terminal.until(lambda: "MD · Body:" in terminal.text() and "[Plain Ctrl+T]" in terminal.text())
            terminal.send(b"e")
            terminal.until(lambda: "OMAGMA TEST EDITOR:" in terminal.text())
            if not terminate_editor:
                terminal.send(b"s")
                terminal.until(lambda: "Reviewed fixture editor body." in terminal.text() and "Attach" in terminal.text())
                terminal.until(lambda: "MD · Body:" in terminal.text() and "[Plain Ctrl+T]" in terminal.text())
        result = terminal.finish(signal_mode=signal.SIGTERM if terminate or terminate_editor else False)
        require(result["termiosRestored"], "native TUI did not restore live owned PTY")
        print("PASS macOS TUI:" + ("SIGTERM during editor/cancellation" if terminate_editor else "SIGTERM wake/cancellation" if terminate else "cached mail/account navigation/compose/editor save") + "/restored live tty/zero sends/clean exit")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    require(sys.platform == "darwin", "native macOS qualification requires Darwin")
    with tempfile.TemporaryDirectory(prefix="omagma-macos-native-") as temporary:
        root = Path(temporary).resolve()
        cli_case(args.binary.resolve(), root / "cli")
        tui_case(args.binary.resolve(), root / "tui")
        tui_case(args.binary.resolve(), root / "signal", terminate=True)
        tui_case(args.binary.resolve(), root / "editor-signal", terminate_editor=True)


if __name__ == "__main__":
    main()
