#!/usr/bin/env python3
"""Encrypted foreground priority and caller-owned background cancellation.

Synthetic providers and owned PTYs only; run under the coordinator's host
reservation. This module is also part of the vault_daemon process suite.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import traceback

from build_info import read_build_info
from terminal_integration import ACCOUNTS, require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen
from terminal_scroll_progress import contains, fixture

if sys.platform == "darwin":
    from terminal_macos import DarwinTerminal

    # The workflow runner can already have adapted the shared factory. Direct
    # invocation needs the same live PTY owner without adding a second one.
    if not issubclass(MouseTerminal, DarwinTerminal):
        class DarwinMouseTerminal(DarwinTerminal, MouseTerminal):
            pass

        MouseTerminal = DarwinMouseTerminal

CASES = ("disconnect", "ownership", "mutation", "open", "reply", "forward",
         "calendar-list-disconnect", "calendar-agenda-disconnect")
MAGIC = b"OMAVIPC1"


class Service:
    def __init__(self, binary, directory, parent_env, scenario=None):
        from vault_daemon import PASSWORD, displayed_recovery, prompt

        self.binary, self.root = binary, directory
        self.source = fixture(directory)
        self.backend = directory / "ipc" / "sock"
        self.vault = directory / "vault"
        self.env = dict(parent_env, HOME=str(directory / "home"),
                        XDG_CONFIG_HOME=str(directory / "config"),
                        XDG_CACHE_HOME=str(directory / "cache"))
        self.env.pop("XDG_RUNTIME_DIR", None)
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            Path(self.env[key]).mkdir(mode=0o700)
        self.serial = 0
        self.daemon = None
        self.hold = self.source.root / "priority.hold"
        self.entered = self.source.root / "priority.entered"
        self.calendar_hold = self.source.root / "calendar-priority.hold"
        self.calendar_entered = self.source.root / "calendar-priority.entered"
        prompt(binary, ["vault", "init", "--fixtures", "--vault-dir", str(self.vault)], self.env,
               [(b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD),
                (b"Confirm recovery key: ", displayed_recovery)])
        try:
            self.daemon = subprocess.Popen(
                [str(binary), "vault", "serve", "--fixtures", "--vault-dir", str(self.vault),
                 "--socket", str(self.backend), "--fixture-root", str(self.source.root),
                 *(["--fixture-scenario", scenario] if scenario else [])],
                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            deadline = time.monotonic() + 10
            while not self.backend.exists():
                require(self.daemon.poll() is None, "foreground fixture daemon exited before binding")
                require(time.monotonic() < deadline, "foreground fixture daemon did not bind")
                time.sleep(.02)
            prompt(binary, ["vault", "unlock", "--socket", str(self.backend)], self.env,
                   [(b"Vault password: ", PASSWORD)])
        except BaseException:
            self.close()
            raise

    def close(self):
        self.hold.unlink(missing_ok=True)
        self.calendar_hold.unlink(missing_ok=True)
        if self.daemon is not None:
            if self.daemon.poll() is None:
                self.daemon.terminate()
                try:
                    self.daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.daemon.kill()
                    self.daemon.wait()
            require(self.daemon.returncode == 0,
                    "foreground fixture daemon failed: " + self.daemon.stderr.read().decode(errors="replace"))
            self.daemon.stdout.close()
            self.daemon.stderr.close()

    def request(self, command, ok=True, **fields):
        self.serial += 1
        value = dict(id=f"foreground-{self.serial}", cmd=command, account=ACCOUNTS[0], **fields)
        result = subprocess.run([str(self.binary), "cli", "--backend", str(self.backend)],
                                env=self.env, input=json.dumps(value).encode() + b"\n",
                                capture_output=True, timeout=40)
        require(bool(result.stdout.strip()), "foreground RPC returned no response: " + result.stderr.decode())
        response = json.loads(result.stdout)
        require(response.get("id") == value["id"] and response.get("account") == ACCOUNTS[0],
                "foreground RPC lost request identity")
        require(response["ok"] == ok,
                f"{command} unexpected success={response['ok']}: {response.get('error', {}).get('code')}")
        return response["data"] if ok else response["error"]

    def submit(self, command, **fields):
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(10)
        peer.connect(str(self.backend))
        raw = json.dumps(dict(id="owned-refresh", cmd=command, account=ACCOUNTS[0], **fields)).encode()
        peer.sendall(b"OMAVIPC3" + bytes([1, 0, 0, 0]) + struct.pack("<I", len(raw)) + raw)
        return peer

    def gate(self, completed=None):
        document = json.loads(self.source.path(ACCOUNTS[0]).read_text())
        sync = document["sync"]
        for name in ("fixtureHold", "fixtureEntered", "fixtureProgress"):
            sync.pop(name, None)
        control = dict(fixtureHold=self.hold.name, fixtureEntered=self.entered.name)
        if completed is None:
            sync.update(control)
        else:
            sync["fixtureProgress"] = dict(phase="bodies", completed=completed, **control)
        self.source.path(ACCOUNTS[0]).write_text(json.dumps(document) + "\n")
        self.hold.write_text("Synthetic provider held for encrypted foreground acceptance\n")
        self.entered.unlink(missing_ok=True)

    def wait_entered(self, terminal=None):
        deadline = time.monotonic() + 5
        while not self.entered.exists():
            require(self.daemon.poll() is None, "foreground daemon exited before provider admission")
            require(time.monotonic() < deadline, "encrypted refresh did not reach held provider boundary")
            if terminal is None:
                time.sleep(.01)
            else:
                terminal.pump(.01)

    def calendar_gate(self, kind):
        control = self.source.root / "calendar-priority-control.json"
        control.write_text(json.dumps(dict(account=ACCOUNTS[0], kind=kind)) + "\n")
        control.chmod(0o600)
        self.calendar_hold.write_text("Synthetic Calendar provider remains held until released\n")
        self.calendar_hold.chmod(0o600)
        self.calendar_entered.unlink(missing_ok=True)

    def wait_calendar_entered(self):
        deadline = time.monotonic() + 5
        while not self.calendar_entered.exists():
            require(self.daemon.poll() is None, "daemon exited before Calendar provider admission")
            require(time.monotonic() < deadline, "Calendar read did not reach held provider boundary")
            time.sleep(.01)


def receive(peer):
    def exact(count):
        result = bytearray()
        while len(result) < count:
            part = peer.recv(count - len(result))
            require(part, "connected refresh lost its response after peer watcher cleanup")
            result.extend(part)
        return bytes(result)
    header = exact(16)
    require(header[:8] == MAGIC and header[8:12] == bytes([128, 0, 0, 0]), "invalid refresh response header")
    length = struct.unpack("<I", header[12:])[0]
    require(length <= 32 * 1024 * 1024, "refresh response exceeded transport bound")
    return json.loads(exact(length))


def disconnected_refresh(service):
    service.gate(completed=1)
    peer = service.submit("mail.refresh", limit=3, prefetchLimit=3, label="INBOX")
    try:
        service.wait_entered()
    finally:
        peer.close()
    began = time.monotonic()
    body = service.request("mail.read", messageId="shared-msg-094")
    elapsed = time.monotonic() - began
    require(elapsed < 5 and "body 094." in body["bodyText"], "disconnected refresh blocked foreground mail read")
    stats = service.request("cache.stats")
    require(service.hold.exists() and not stats["refreshInProgress"], "caller cancellation failed to join refresh")
    require(stats["syncBodyGets"] == 1 and stats["historyId"] == "", "canceled refresh advanced prefetch/checkpoint")
    require(stats["fixtureSends"] == 0, "foreground read sent synthetic mail")
    return dict(seconds=round(elapsed, 3), prefetchBodies=1, checkpoint="", refreshJoined=True)


def owned_refresh(service):
    service.gate(completed=1)
    with service.submit("mail.refresh", limit=3, prefetchLimit=3, label="INBOX") as owner:
        service.wait_entered()
        # A different same-user connection may vanish at any point. It does
        # not own the admitted refresh and cannot cancel that job.
        with socket.socket(socket.AF_UNIX) as unrelated:
            unrelated.connect(str(service.backend))
            unrelated.sendall(MAGIC[:4])
        require(not select.select([owner], [], [], 1)[0], "unrelated caller canceled active refresh")
        service.hold.unlink()
        response = receive(owner)
        require(response["ok"], "connected refresh failed after cancelling its EOF watcher")
    stats = service.request("cache.stats")
    require(stats["syncBodyGets"] == 3 and stats["historyId"] == "1000", "connected refresh did not finish/checkpoint")
    require(not stats["refreshInProgress"], "completed refresh retained ownership")
    return dict(unrelatedDisconnectIgnored=True, connectedResponse=True, prefetchBodies=3)


def disconnected_mutation(service):
    service.request("mail.refresh", limit=3, prefetchLimit=0, label="INBOX")
    service.gate(completed=0)
    peer = service.submit("mail.reply", messageId="shared-msg-094")
    try:
        service.wait_entered()
    finally:
        peer.close()
    refused = service.request("preferences.get", ok=False)
    require(refused["code"] == "VaultBusy", "caller disconnect interrupted an admitted draft mutation")
    service.hold.unlink()
    drafts = service.request("draft.list")["drafts"]
    require(len(drafts) == 1, "disconnected draft mutation was lost or duplicated")
    draft = service.request("draft.read", draftId=drafts[0]["id"])
    require(draft["subject"] == "Re: Scroll fixture personal 094", "disconnected mutation changed source identity")
    require(service.request("cache.stats")["fixtureSends"] == 0, "draft guard sent mail")
    return dict(admittedMutationContinued=True, drafts=1, automaticReplays=0)


def disconnected_calendar(service, command):
    """A remote reminder yields its admitted provider call, not only its client."""
    fields = dict(persistCache=False)
    kind = "calendar_list"
    if command == "calendar.agenda":
        kind = "agenda"
        fields.update(calendarId=ACCOUNTS[0], view="week", timeZone="UTC",
                      date=datetime.now(timezone.utc).date().isoformat())

    # Closing an unrelated same-user socket must never cancel the admitted read;
    # a connected owner must still get its complete response after gate release.
    service.calendar_gate(kind)
    with service.submit(command, **fields) as owner:
        service.wait_calendar_entered()
        with socket.socket(socket.AF_UNIX) as unrelated:
            unrelated.connect(str(service.backend))
            unrelated.sendall(MAGIC[:4])
        require(not select.select([owner], [], [], 1)[0],
                "unrelated caller canceled active Calendar read")
        service.calendar_hold.unlink()
        response = receive(owner)
        require(response["ok"], "connected Calendar read failed during peer watcher cleanup")
        snapshot = response["data"] if command == "calendar.list" else response["data"]["snapshot"]
        require(snapshot["complete"], "connected Calendar read did not complete its snapshot")

    service.calendar_gate(kind)
    peer = service.submit(command, **fields)
    try:
        service.wait_calendar_entered()
    finally:
        peer.close()
    began = time.monotonic()
    draft = service.request("draft.create", draft=dict(subject="After Calendar cancellation",
                                                       bodyText="Synthetic foreground draft"))
    elapsed = time.monotonic() - began
    require(elapsed < 5 and service.calendar_hold.exists(),
            "abandoned Calendar read retained the daemon lane until gate release")
    require(bool(draft["id"]), "foreground draft was not created after Calendar cancellation")
    drafts = service.request("draft.list")["drafts"]
    require(len(drafts) == 1 and drafts[0]["id"] == draft["id"],
            "Calendar cancellation lost or duplicated the foreground draft")
    require(service.request("cache.stats")["fixtureSends"] == 0,
            "Calendar cancellation sent synthetic mail")
    return dict(command=command, seconds=round(elapsed, 3), ownerDisconnected=True,
                unrelatedDisconnectIgnored=True, connectedResponse=True,
                gateStillHeld=True, providerJoined=True, drafts=1, automaticReplays=0)


def foreground(service, action):
    terminal = MouseTerminal(service.binary, service.root / "tui",
                             extra=("--backend", str(service.backend)),
                             environment={**service.env, "TZ": "UTC", "NO_COLOR": None, "COLORTERM": "truecolor"},
                             columns=160, rows=40, screen_type=MouseScreen)
    try:
        terminal.until(lambda: "Up to date" in terminal.text() and contains(terminal, 96), seconds=15)
        terminal.send(b"jj")
        terminal.until(lambda: contains(terminal, 94))
        before = service.request("cache.stats")
        service.gate()
        terminal.send(b"\x12")  # Ctrl+R starts this TUI's own refresh.
        service.wait_entered(terminal)
        began = time.monotonic()
        terminal.send({"open": b"\r", "reply": b"r", "forward": b"f"}[action])
        if action == "open":
            terminal.until(lambda: "/3 mails" in terminal.text() and contains(terminal, 94), seconds=5)
        elif action == "reply":
            terminal.until(lambda: "Re: Scroll fixture personal 094" in terminal.text(), seconds=5)
        else:
            terminal.until(lambda: "Choose original format" in terminal.text(), seconds=5)
            terminal.send(b"t")
            terminal.until(lambda: "Fwd: Scroll fixture personal 094" in terminal.text(), seconds=5)
        elapsed = time.monotonic() - began
        require(elapsed < 5 and service.hold.exists(), "encrypted foreground action waited for provider gate")
        after = service.request("cache.stats")
        require(not after["refreshInProgress"], "remote TUI cancellation did not join its daemon refresh")
        require(after["syncBodyGets"] == before["syncBodyGets"] and after["historyId"] == before["historyId"],
                "canceled TUI refresh advanced prefetch/checkpoint")
        require(after["fixtureSends"] == 0, "remote foreground action unexpectedly sent mail")
        drafts = service.request("draft.list")["drafts"]
        require(len(drafts) == int(action != "open"), "remote foreground action lost or duplicated draft")
        # Terminal.finish() checks a separate plaintext fixture client. This
        # remote suite verifies the actual daemon above and exits its own TUI.
        terminal.process.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while terminal.process.poll() is None and time.monotonic() < deadline:
            terminal.pump()
        require(terminal.process.poll() == 0, "remote TUI did not exit cleanly")
        require(termios.tcgetattr(terminal.slave) == terminal.settings, "remote TUI did not restore termios")
        require(not list((service.root / "tui").rglob("index.json")), "remote TUI created plaintext cache")
        return dict(seconds=round(elapsed, 3), target="shared-msg-094", refreshJoined=True,
                    gateStillHeld=True, drafts=len(drafts), termiosRestored=True)
    except BaseException:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        service.hold.unlink(missing_ok=True)
        terminal.close()


def run(binary, directory, parent_env, cases=CASES, receipt=None):
    results = [] if receipt is None else receipt["cases"]
    for case in cases:
        root = directory / ("fg-" + case)
        root.mkdir(mode=0o700)
        service = None
        try:
            service = Service(binary, root, parent_env)
            test = {"disconnect": disconnected_refresh, "ownership": owned_refresh, "mutation": disconnected_mutation}.get(case)
            if case.startswith("calendar-"):
                command = "calendar.list" if case == "calendar-list-disconnect" else "calendar.agenda"
                result = disconnected_calendar(service, command)
            else:
                result = test(service) if test else foreground(service, case)
            results.append(dict(case=case, passed=True, **result))
            print("PASS encrypted foreground priority:", case, flush=True)
        except BaseException:
            results.append(dict(case=case, passed=False, traceback=traceback.format_exc()))
            raise
        finally:
            if service is not None:
                service.close()
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = dict(build=read_build_info(binary), cases=[])
    try:
        with tempfile.TemporaryDirectory(prefix="omagma-vfg-", dir=str(Path("/tmp").resolve())) as temporary:
            run(binary, Path(temporary), os.environ, args.case or CASES, receipt)
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
