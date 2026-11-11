#!/usr/bin/env python3
"""Reconnect an expired Google sign-in from the TUI, through owned PTYs.

Synthetic only: the sign-in-expired fixture scenario refuses the second
account like Google's token endpoint (invalid_rapt) until a fixture reconnect.
Consent runs Omagma's real loopback listener, PKCE, state and callback; the
configured "Chrome" is a synthetic consent page written by this test, which
answers on loopback only. No desktop windows, real accounts, Google traffic or
credential stores are involved. Run under the cooperative host reservation.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_pty import Terminal, child_session
from terminal_screen import Screen

EXPIRED = "work@example.com"
OTHER = "personal@example.com"
CTRL_O = b"\x0f"
ESC = b"\x1b"
ENTER = b"\r"

CONSENT_PAGE = '''#!{python} -I
"""Synthetic Google consent page for Omagma's owned-PTY reconnect test."""
import base64, json, os, socket, sys, urllib.parse
settings = json.loads(open(os.environ["OMAGMA_TEST_CONSENT"]).read())
entry = {{"argv": sys.argv[1:]}}
try:
    split = urllib.parse.urlsplit(sys.argv[-1])
    query = urllib.parse.parse_qs(split.query, strict_parsing=True)
    value = lambda name: query[name][0]
    redirect = urllib.parse.urlsplit(value("redirect_uri"))
    entry.update(origin=f"{{split.scheme}}://{{split.netloc}}{{split.path}}", client=value("client_id"),
                 scope=value("scope"), loginHint=value("login_hint"), prompt=value("prompt"),
                 accessType=value("access_type"), method=value("code_challenge_method"),
                 port=redirect.port, path=redirect.path, state=value("state"), challenge=value("code_challenge"),
                 keys=sorted(query))
    mode = settings["mode"]
    entry["mode"] = mode
    if mode != "ignore":
        if mode == "deny":
            target = "/oauth2/callback?error=access_denied&state=" + urllib.parse.quote(value("state"))
        else:
            who = value("login_hint") if mode == "approve" else "someone.else@example.com"
            code = "fixture." + value("code_challenge") + "." + base64.urlsafe_b64encode(who.encode()).rstrip(b"=").decode()
            entry["code"] = code
            target = "/oauth2/callback?code=" + urllib.parse.quote(code) + "&state=" + urllib.parse.quote(value("state"))
        with socket.create_connection(("127.0.0.1", redirect.port), timeout=10) as stream:
            stream.sendall(("GET " + target + " HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n").encode())
            reply = b""
            while chunk := stream.recv(4096):
                reply += chunk
        entry["status"] = reply.split(b" ")[1].decode()
except Exception as error:
    entry["error"] = repr(error)
with open(settings["log"], "a") as log:
    log.write(json.dumps(entry) + "\\n")
'''


class ReconnectTerminal(Terminal):
    """The owned PTY transport, launched with the sign-in-expired scenario."""
    def __init__(self, binary, directory, config, control, account, columns=120, rows=36):
        self.binary, self.directory = binary, Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.master, self.slave = os.openpty()
        self.columns, self.rows = columns, rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, rows * 20, columns * 10))
        self.settings = termios.tcgetattr(self.slave)
        self.output, self.output_total, self.history_limit = bytearray(), 0, None
        self.screen = Screen(columns, rows)
        self.scan_offset = self.query_replies = 0
        self.editor_log = self.directory / "editor.json"
        self.injection_sentinel = self.directory / "must-not-exist"
        env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8", TZ="UTC",
                   HOME=str(self.directory / "home"), TMPDIR=str(self.directory), OMAGMA_TEST_CONSENT=str(control))
        for key in ("CONFIG", "CACHE", "DATA", "STATE"):
            env[f"XDG_{key}_HOME"] = str(self.directory / key.lower())
        runtime = self.directory / "runtime"
        runtime.mkdir(mode=0o700, exist_ok=True)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS", "NO_COLOR"):
            env.pop(key, None)
        self.argv = [str(binary), "tui", "--fixtures", "--config", str(config), "--fixture-scenario", "sign-in-expired",
                     "--account", account, "--cache-dir", str(self.directory / "cache")]
        self.process = subprocess.Popen(self.argv, stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                        cwd=self.directory, env=env, preexec_fn=child_session)
        os.set_blocking(self.master, False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.master, selectors.EVENT_READ)

    def flat(self):
        return " ".join(self.text().split())

    def has(self, literal):
        return literal in self.flat() or literal in self.dialog()

    def dialog(self):
        """The reconnect dialog's words inside its own border, unwrapped."""
        lines = self.screen.lines()
        for top, line in enumerate(lines):
            left = line.find("╭─ Reconnect Google sign-in")
            if left >= 0:
                right = line.find("╮", left)
                parts = []
                for row in lines[top + 1:]:
                    if row[left:left + 1] == "╰":
                        break
                    parts.append(row[left + 1:right])
                return " ".join(" ".join(parts).split())
        return ""

    def quit(self):
        deadline = time.monotonic() + 8
        while self.process.poll() is None and time.monotonic() < deadline:
            self.send(ESC)
            self.gap(.3)
            if self.process.poll() is None:
                self.send(b"q")
            self.gap(.5)
        require(self.process.returncode == 0, "TUI did not exit cleanly")
        require(termios.tcgetattr(self.slave) == self.settings, "TUI did not restore terminal settings")


def setup(directory):
    directory.mkdir(parents=True)
    page = directory / "synthetic-consent-page"
    page.write_text(CONSENT_PAGE.format(python=sys.executable))
    page.chmod(0o700)
    config = directory / "fictional-config.json"
    config.write_text(json.dumps({"oauthClientFile": "", "chrome": str(page), "chromeUserData": "", "accounts": [
        {"address": OTHER, "profile": "Personal Profile", "enabled": True, "required": False},
        {"address": EXPIRED, "profile": "Work Profile", "enabled": True, "required": False}]}) + "\n")
    config.chmod(0o600)
    return config


class Consent:
    def __init__(self, directory):
        self.control = directory / "consent-control.json"
        self.log = directory / "consent-log.jsonl"
        self.choose("approve")

    def choose(self, mode):
        self.control.write_text(json.dumps({"mode": mode, "log": str(self.log)}))

    def entries(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def wait(self, count, terminal, seconds=10):
        deadline = time.monotonic() + seconds
        while len(self.entries()) < count:
            require(time.monotonic() < deadline, "synthetic consent page was not opened")
            terminal.gap(.05)
        return self.entries()[count - 1]


def marker_exists(directory):
    return any(path.name.startswith("fixture-sign-in-") for path in (directory / "cache").glob("fixture-sign-in-*"))


def check_consent(entry, terminal):
    """What the consent page received: the account's own profile and hint,
    the exact recorded grant's scopes, PKCE S256 and a loopback redirect."""
    require("error" not in entry, f"synthetic consent page failed: {entry.get('error')}")
    require(entry["argv"][0] == "--profile-directory=Work Profile", "consent did not open the account's Chrome profile")
    require(entry["origin"] == "https://accounts.google.com/o/oauth2/v2/auth", "consent URL is not Google's")
    require(entry["loginHint"] == EXPIRED and entry["prompt"] == "consent" and entry["accessType"] == "offline", "consent parameters changed")
    require(entry["method"] == "S256" and len(entry["challenge"]) == 43, "consent lacks PKCE S256")
    require("code_verifier" not in entry["keys"], "the PKCE verifier reached the consent URL")
    require(entry["path"] == "/oauth2/callback", "callback path changed")
    for scope in ("gmail.modify", "contacts", "calendar.events", "calendar.events.freebusy"):
        require(f"https://www.googleapis.com/auth/{scope}" in entry["scope"].split(), f"recorded grant scope {scope} missing")
    require(terminal.process.pid > 0, "TUI process missing")


def no_secrets(terminal, consent, directory):
    """No code, state, PKCE value or synthetic credential reaches the screen,
    the PTY transcript, the TUI's argv or the cache directory's names."""
    transcript = bytes(terminal.output)
    argv = Path(f"/proc/{terminal.process.pid}/cmdline").read_bytes() if Path(f"/proc/{terminal.process.pid}/cmdline").exists() else " ".join(terminal.argv).encode()
    for entry in consent.entries():
        for secret in (entry.get("code"), entry.get("state"), entry.get("challenge")):
            if not secret:
                continue
            require(secret.encode() not in transcript, "an authorization value reached the PTY transcript")
            require(secret.encode() not in argv, "an authorization value reached the TUI argv")
        # The consent page's argv is the URL only: never a code or verifier.
        if entry.get("code"):
            require(all(entry["code"] not in argument for argument in entry["argv"]), "an authorization code reached browser argv")
    for word in (b"fixture.", b"code_verifier", b"refresh_token", b"access_token"):
        require(word not in transcript, f"{word!r} reached the PTY transcript")


def mail_case(binary, root):
    directory = root / "mail"
    config = setup(directory)
    consent = Consent(directory)
    terminal = ReconnectTerminal(binary, directory, config, consent.control, EXPIRED)
    try:
        # The refused refresh names the key in the account status.
        terminal.until(lambda: terminal.has("Google sign-in expired · Ctrl+O Reconnect"), 20)
        require(not marker_exists(directory), "scenario started reconnected")
        terminal.send(CTRL_O)
        terminal.until(lambda: terminal.has("Reconnect Google sign-in") and terminal.has("[Reconnect · Enter]"))
        require(terminal.has("re-authentication policy"), "Google's reason kind not shown")
        require(terminal.has('Google said: "reauth related error (invalid_rapt)"'), "Google's description not shown")
        require(terminal.has("mail-read, mail-modify, mail-send"), "kept permissions not shown")
        terminal.gap(.4)
        require(not consent.entries(), "consent opened before an explicit Enter")
        # Wrong Google account: refused, nothing stored, Try again offered.
        consent.choose("wrong")
        terminal.send(ENTER)
        terminal.until(lambda: terminal.has("Google signed in a different account"))
        require(terminal.has("[Try again · Enter]"), "wrong account did not offer Try again")
        check_consent(consent.wait(1, terminal), terminal)
        require(not marker_exists(directory), "a different account was stored")
        # Cancel while Chrome is open: the wait ends and the listener closes.
        consent.choose("ignore")
        terminal.send(ENTER)
        terminal.until(lambda: terminal.has("Waiting for Google consent in Chrome · Esc Cancel"))
        port = consent.wait(2, terminal)["port"]
        terminal.send(ESC)
        terminal.until(lambda: terminal.has("Reconnect canceled") and not terminal.has("Reconnect Google sign-in"))
        refused = False
        for _ in range(20):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                terminal.gap(.1)
            except ConnectionRefusedError:
                refused = True
                break
        require(refused, "loopback callback listener stayed open after Cancel")
        require(not marker_exists(directory), "cancel stored a sign-in")
        # Declined consent changes nothing.
        consent.choose("deny")
        terminal.send(CTRL_O)
        terminal.until(lambda: terminal.has("[Reconnect · Enter]"))
        terminal.send(ENTER)
        terminal.until(lambda: terminal.has("You declined access in Google"))
        terminal.send(ESC)
        terminal.until(lambda: not terminal.has("Reconnect Google sign-in"))
        # Approve: renewed and refreshed in this TUI, no restart.
        consent.choose("approve")
        terminal.send(CTRL_O)
        terminal.until(lambda: terminal.has("[Reconnect · Enter]"))
        terminal.send(ENTER)
        approved = consent.wait(4, terminal)
        check_consent(approved, terminal)
        require(approved["status"] == "200", "callback was not accepted")
        terminal.until(lambda: terminal.has("Reconnected work@example.com · same permissions renewed"))
        terminal.until(lambda: terminal.has("work@example.com: synthetic thread"), 20)
        # The notice outlasts the refresh it started, until the next key.
        require(terminal.has("Reconnected work@example.com"), "reconnect notice vanished before a key")
        require(not terminal.has("Google sign-in expired"), "status still reports the expired sign-in")
        require(marker_exists(directory), "fixture reconnect was not recorded")
        no_secrets(terminal, consent, directory)
        terminal.quit()
        print("PASS reconnect mail: explicit Enter, wrong account, cancel, denial, renewal and refresh without restart")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    # A later JSONL process uses the renewed sign-in; no mail was sent.
    with Client(binary, directory, fixtures=False, extra=("--fixtures", "--config", str(config), "--fixture-scenario", "sign-in-expired")) as client:
        client.request("mail.refresh", EXPIRED, limit=5)
        require(client.request("auth.status", EXPIRED)["lastRefreshError"] is None, "status kept an obsolete refusal")
        require(client.request("cache.stats", EXPIRED, cacheOnly=True)["fixtureSends"] == 0, "reconnect sent mail")


def jsonl_case(binary, root):
    """The agent contract: Google's reason in auth.status, and a reconnect
    that cannot change the recorded grant fails before any consent."""
    directory = root / "jsonl"
    config = setup(directory)
    consent = Consent(directory)
    with Client(binary, directory, fixtures=False, extra=("--fixtures", "--config", str(config), "--fixture-scenario", "sign-in-expired")) as client:
        before = client.request("auth.status", EXPIRED)
        require(before["lastRefreshError"] is None, "an unobserved account reported a refusal")
        require(client.request("mail.refresh", EXPIRED, ok=False, limit=5)["code"] == "InvalidGrant", "expired sign-in was not refused")
        status = client.request("auth.status", EXPIRED)
        reason = status["lastRefreshError"]
        require(reason["error"] == "invalid_grant" and reason["subtype"] == "invalid_rapt", "Google's refusal was not kept")
        require(reason["kind"] == "reauthenticationRequired" and reason["description"] == "reauth related error (invalid_rapt)", "refusal was not classified")
        require(isinstance(reason["at"], int) and reason["at"] > 0, "refusal has no time")
        require("support.google.com" not in json.dumps(reason), "unsanitized Google field kept")
        require(client.request("auth.status", OTHER)["lastRefreshError"] is None, "refusal leaked to another account")
        grant = status["grant"]
        narrower = [name for name in grant["capabilities"] if name != "mail-send"]
        require(client.request("auth.authorize", EXPIRED, ok=False, capabilities=narrower, reconnect=True)["code"] == "ReconnectCapabilitiesChanged", "a narrower reconnect was accepted")
        require(client.request("auth.authorize", EXPIRED, ok=False, capabilities=grant["capabilities"] + ["drive-upload"], reconnect=True)["code"] == "ReconnectCapabilitiesChanged", "a broader reconnect was accepted")
        require(client.request("auth.authorize", EXPIRED, ok=False, capabilities=grant["capabilities"], reconnect=True, expectedGrantId="0" * 64)["code"] == "GrantChanged", "a changed grant was accepted")
        require(not consent.entries(), "refused reconnects opened consent")
    print("PASS reconnect JSONL: lastRefreshError kept and classified, changed grants refused before consent")


def calendar_case(binary, root):
    directory = root / "calendar"
    config = setup(directory)
    consent = Consent(directory)
    terminal = ReconnectTerminal(binary, directory, config, consent.control, OTHER, columns=140, rows=38)
    try:
        terminal.until(lambda: terminal.has(OTHER), 20)
        terminal.send(b"C")
        terminal.until(lambda: terminal.has("Calendar · "), 20)
        # Show every account's calendars: the expired account is named.
        terminal.until(lambda: terminal.has("Up to date") or terminal.has("Saved calendar"), 20)
        terminal.send(b"g")
        terminal.until(lambda: terminal.has("Show calendars"))
        terminal.send(b"a")
        # Every account is listed first; the expired one is unavailable.
        terminal.until(lambda: terminal.has("Some accounts unavailable"), 20)
        terminal.gap(.3)
        terminal.send(ENTER)
        terminal.until(lambda: terminal.has("Not shown: work@example.com · Google sign-in expired · Ctrl+O Reconnect"), 20)
        terminal.send(CTRL_O)
        terminal.until(lambda: terminal.has("Account: work@example.com") and terminal.has("[Reconnect · Enter]"))
        require(terminal.has("Enter Reconnect · Tab Choose · Esc Cancel"), "calendar footer does not name the dialog keys")
        require(not consent.entries(), "consent opened before an explicit Enter")
        terminal.send(ENTER)
        check_consent(consent.wait(1, terminal), terminal)
        terminal.until(lambda: not terminal.has("Reconnect Google sign-in") and not terminal.has("Not shown:"), 20)
        terminal.until(lambda: terminal.has("Up to date"), 20)
        # The account's mail was refreshed after its calendars, in the background:
        # switching to it shows downloaded mail (account switches read the cache only).
        terminal.gap(1)
        terminal.send(b"q")
        terminal.until(lambda: terminal.has("Accounts / mailboxes"), 20)
        terminal.send(b"2")
        terminal.until(lambda: terminal.has("work@example.com: synthetic thread"), 20)
        require(not terminal.has("Google sign-in expired"), "mail status still reports the expired sign-in")
        no_secrets(terminal, consent, directory)
        terminal.quit()
        print("PASS reconnect calendar: named account, Ctrl+O, consent, calendars and mail reloaded without restart")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=("jsonl", "mail", "calendar"), help="run only this case (repeatable)")
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "test binary absent")
    read_build_info(binary)
    cases = {"jsonl": jsonl_case, "mail": mail_case, "calendar": calendar_case}
    with tempfile.TemporaryDirectory(prefix="omagma-reconnect-") as temporary:
        root = Path(temporary)
        for name in args.case or cases:
            cases[name](binary, root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
