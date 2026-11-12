#!/usr/bin/env python3
"""Reconnect an expired Google sign-in from the TUI, through owned PTYs.

Synthetic only: the sign-in-expired fixture scenario refuses the second
account like Google's token endpoint (invalid_rapt) until a fixture reconnect.
Consent runs Omagma's real loopback listener, PKCE, state and callback against
the config's explicit `fixtureConsentPage`, a synthetic consent page written by
this test that answers on loopback only. The configured `chrome` is a sentinel
that must never run. A FIFO or a directory at the fixture's reconnect marker
stands in for a credential store that hangs or fails after Google's callback. No desktop windows, real accounts, Google traffic or
credential stores are involved. Run under the cooperative host reservation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import termios
import time

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_pty import Terminal
from terminal_screen import Screen
import terminal_mouse

EXPIRED = "work@example.com"
OTHER = "personal@example.com"
CTRL_O = b"\x0f"
ESC = b"\x1b"
ENTER = b"\r"
SCENARIO = ("--fixture-scenario", "sign-in-expired")

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

# Stands in for the user's real browser: fixture consent must never run it.
BROWSER_SENTINEL = '''#!{python} -I
import sys
open({path!r}, "a").write(" ".join(sys.argv[1:2]) + "\\n")
'''


def launch(binary, directory, config, control, account, columns=120, rows=36):
    """The ordinary owned-PTY transport (patched for macOS by the workflow
    runner), with the sign-in-expired scenario and the consent control."""
    terminal = terminal_mouse.MouseTerminal(
        binary, directory, extra=("--config", str(config), *SCENARIO, "--account", account),
        environment={"OMAGMA_TEST_CONSENT": str(control), "TZ": "UTC", "NO_COLOR": None},
        screen_type=Screen, columns=columns, rows=rows)
    return terminal


def flat(terminal):
    return " ".join(terminal.text().split())


def pane(terminal, title):
    """A bordered pane's or dialog's words inside its own border, unwrapped."""
    lines = terminal.screen.lines()
    for top, line in enumerate(lines):
        left = line.find("╭─ " + title)
        if left >= 0:
            right = line.find("╮", left)
            parts = []
            for row in lines[top + 1:]:
                if row[left:left + 1] == "╰":
                    break
                parts.append(row[left + 1:right])
            return " ".join(" ".join(parts).split())
    return ""


def dialog(terminal):
    return pane(terminal, "Reconnect Google sign-in")


def has(terminal, literal):
    return literal in flat(terminal) or literal in dialog(terminal)


def resize(terminal, columns, rows):
    """Resize the owned PTY with a fresh plain cell model (the mouse
    transport's repaint resize expects a preserving screen type)."""
    Terminal.resize(terminal, columns, rows)


def quit_tui(terminal):
    deadline = time.monotonic() + 8
    while terminal.process.poll() is None and time.monotonic() < deadline:
        terminal.send(ESC)
        terminal.gap(.3)
        if terminal.process.poll() is None:
            terminal.send(b"q")
        terminal.gap(.5)
    require(terminal.process.returncode == 0, "TUI did not exit cleanly")
    require(termios.tcgetattr(terminal.slave) == terminal.settings, "TUI did not restore terminal settings")


def command(terminal, text):
    terminal.send(b":")
    terminal.gap(.15)
    terminal.send(text.encode())
    terminal.gap(.1)
    terminal.send(ENTER)


def setup(directory):
    directory.mkdir(parents=True)
    page = directory / "synthetic-consent-page"
    page.write_text(CONSENT_PAGE.format(python=sys.executable))
    page.chmod(0o700)
    sentinel = directory / "browser-sentinel"
    browser = directory / "must-not-run-browser"
    browser.write_text(BROWSER_SENTINEL.format(python=sys.executable, path=str(sentinel)))
    browser.chmod(0o700)
    config = directory / "fictional-config.json"
    config.write_text(json.dumps({"oauthClientFile": "", "chrome": str(browser), "fixtureConsentPage": str(page),
                                  "chromeUserData": "", "accounts": [
        {"address": OTHER, "profile": "Personal Profile", "enabled": True, "required": False},
        {"address": EXPIRED, "profile": "Work Profile", "enabled": True, "required": False}]}) + "\n")
    config.chmod(0o600)
    return config


def browser_never_ran(directory):
    require(not (directory / "browser-sentinel").exists(), "fixture consent launched the configured browser")


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
    return any((directory / "cache").glob("fixture-sign-in-*"))


def marker_path(directory, account=EXPIRED):
    """Where a fixture reconnect records itself: the test puts a FIFO (a
    store that never finishes) or a directory (a store that fails) there."""
    digest = hashlib.sha256(account.lower().encode()).hexdigest()[:16]
    path = directory / "cache" / f"fixture-sign-in-{digest}"
    # The cache directory must stay private, as Omagma creates it.
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    return path


def until_finishing(terminal, consent, directory, store):
    """Once this TUI has seen the refusal, make the store hang (a FIFO) or
    fail (a directory) — before then the marker would read as reconnected —
    and approve consent."""
    if store == "hang":
        os.mkfifo(marker_path(directory), 0o600)
    else:
        marker_path(directory).mkdir()
    terminal.send(CTRL_O)
    terminal.until(lambda: has(terminal, "[Reconnect · Enter]"))
    terminal.send(ENTER)
    consent.wait(1, terminal)
    # A failing store may pass through "storing" faster than a screen poll.
    if store == "hang":
        terminal.until(lambda: has(terminal, "storing the renewed sign-in"), 10)


def check_consent(entry):
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


def no_secrets(terminal, consent):
    """No code, state, PKCE value or synthetic credential reaches the screen,
    the PTY transcript or the TUI's argv."""
    transcript = bytes(terminal.output)
    proc = Path(f"/proc/{terminal.process.pid}/cmdline")
    require(terminal.process.poll() is None, "argv privacy check requires the owned TUI to be alive")
    argv = proc.read_bytes() if proc.exists() else subprocess.check_output(
        ["ps", "-ww", "-p", str(terminal.process.pid), "-o", "command="], timeout=5)
    require(bool(argv.strip()), "could not inspect the owned TUI's actual argv")
    require(os.fsencode(str(terminal.binary)) in argv, "argv snapshot does not identify the owned TUI executable")
    for entry in consent.entries():
        for secret in (entry.get("code"), entry.get("state"), entry.get("challenge")):
            if not secret:
                continue
            require(secret.encode() not in transcript, "an authorization value reached the PTY transcript")
            require(secret.encode() not in argv, "an authorization value reached the TUI argv")
        if entry.get("code"):
            require(all(entry["code"] not in argument for argument in entry["argv"]), "an authorization code reached browser argv")
    for word in (b"fixture.", b"code_verifier", b"refresh_token", b"access_token"):
        require(word not in transcript, f"{word!r} reached the PTY transcript")


def jsonl_case(binary, root):
    """The agent contract: Google's reason in auth.status, and a reconnect
    that cannot change the recorded grant fails before any consent."""
    directory = root / "jsonl"
    config = setup(directory)
    consent = Consent(directory)
    with Client(binary, directory, scenario="sign-in-expired", extra=("--config", str(config))) as client:
        require(client.request("auth.status", EXPIRED)["lastRefreshError"] is None, "an unobserved account reported a refusal")
        require(client.request("mail.refresh", EXPIRED, ok=False, limit=5)["code"] == "InvalidGrant", "expired sign-in was not refused")
        status = client.request("auth.status", EXPIRED)
        reason = status["lastRefreshError"]
        require(reason["error"] == "invalid_grant" and reason["subtype"] == "invalid_rapt", "Google's refusal was not kept")
        require(reason["kind"] == "reauthenticationRequired" and reason["description"] == "reauth related error (invalid_rapt)", "refusal was not classified")
        require(isinstance(reason["at"], int) and reason["at"] > 0, "refusal has no time")
        require("support.google.com" not in json.dumps(reason), "unsanitized Google field kept")
        require(client.request("auth.status", OTHER)["lastRefreshError"] is None, "refusal leaked to another account")
        grant = status["grant"]
        caps = grant["capabilities"]
        narrower = [name for name in caps if name != "mail-send"]
        for request, code in (({"capabilities": narrower, "reconnect": True}, "ReconnectCapabilitiesChanged"),
                              ({"capabilities": caps + ["drive-upload"], "reconnect": True}, "ReconnectCapabilitiesChanged"),
                              ({"capabilities": caps, "reconnect": True, "expectedGrantId": "0" * 64}, "GrantChanged"),
                              ({"capabilities": caps, "reconnect": True, "expectedGrantId": "x"}, "InvalidRequest"),
                              ({"capabilities": caps, "reconnect": True, "clientFile": "/other/registration.json"}, "ReconnectRegistrationChanged")):
            got = client.request("auth.authorize", EXPIRED, ok=False, **request)["code"]
            require(got == code, f"reconnect {sorted(request)} answered {got}, not {code}")
        require(not consent.entries(), "refused reconnects opened consent")
    browser_never_ran(directory)
    print("PASS reconnect JSONL: lastRefreshError kept and classified, changed grants and registrations refused before consent")


def mail_case(binary, root):
    directory = root / "mail"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, EXPIRED)
    try:
        # The refused refresh names the key in the account status and empty pane.
        terminal.until(lambda: has(terminal, "Google sign-in expired · Ctrl+O Reconnect"), 20)
        terminal.until(lambda: "No downloaded mail yet · Google sign-in expired · Ctrl+O Reconnect" in pane(terminal, "Mail"), 20)
        require(not marker_exists(directory), "scenario started reconnected")
        terminal.send(CTRL_O)
        terminal.until(lambda: has(terminal, "Reconnect Google sign-in") and has(terminal, "[Reconnect · Enter]"))
        require(has(terminal, "re-authentication policy"), "Google's reason kind not shown")
        require(has(terminal, 'Google said: "reauth related error (invalid_rapt)"'), "Google's description not shown")
        require(has(terminal, "mail-read, mail-modify, mail-send"), "kept permissions not shown")
        terminal.gap(.4)
        require(not consent.entries(), "consent opened before an explicit Enter")
        # Wrong Google account: refused, nothing stored, Try again offered.
        consent.choose("wrong")
        terminal.send(ENTER)
        terminal.until(lambda: has(terminal, "Google signed in a different account"))
        require(has(terminal, "[Try again · Enter]"), "wrong account did not offer Try again")
        check_consent(consent.wait(1, terminal))
        require(not marker_exists(directory), "a different account was stored")
        # Cancel while Chrome is open: the wait ends and the listener closes.
        consent.choose("ignore")
        terminal.send(ENTER)
        terminal.until(lambda: has(terminal, "Waiting for Google consent in Chrome · Esc Cancel"))
        port = consent.wait(2, terminal)["port"]
        terminal.send(ESC)
        terminal.until(lambda: has(terminal, "Reconnect canceled") and not has(terminal, "Reconnect Google sign-in"))
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
        # Declined consent changes nothing; reopening clears the old notice.
        consent.choose("deny")
        terminal.send(CTRL_O)
        terminal.until(lambda: has(terminal, "[Reconnect · Enter]"))
        require(not has(terminal, "Reconnect canceled"), "a stale notice stayed under the new dialog")
        terminal.send(ENTER)
        terminal.until(lambda: has(terminal, "You declined access in Google"))
        terminal.send(ESC)
        terminal.until(lambda: not has(terminal, "Reconnect Google sign-in"))
        # Approve: renewed and refreshed in this TUI, no restart.
        consent.choose("approve")
        terminal.send(CTRL_O)
        terminal.until(lambda: has(terminal, "[Reconnect · Enter]"))
        terminal.send(ENTER)
        approved = consent.wait(4, terminal)
        check_consent(approved)
        require(approved["status"] == "200", "callback was not accepted")
        terminal.until(lambda: has(terminal, "Reconnected work@example.com · same permissions renewed"))
        terminal.until(lambda: has(terminal, "Synthetic work thread"), 20)
        require(has(terminal, "Reconnected work@example.com"), "reconnect notice vanished before a key")
        require(not has(terminal, "Google sign-in expired"), "status still reports the expired sign-in")
        require(marker_exists(directory), "fixture reconnect was not recorded")
        no_secrets(terminal, consent)
        quit_tui(terminal)
        print("PASS reconnect mail: explicit Enter, wrong account, cancel, denial, renewal and refresh without restart")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    browser_never_ran(directory)
    # A later JSONL process uses the renewed sign-in; no mail was sent.
    with Client(binary, directory, scenario="sign-in-expired", extra=("--config", str(config))) as client:
        client.request("mail.refresh", EXPIRED, limit=5)
        require(client.request("auth.status", EXPIRED)["lastRefreshError"] is None, "status kept an obsolete refusal")
        require(client.request("cache.stats", EXPIRED, cacheOnly=True)["fixtureSends"] == 0, "reconnect sent mail")


def commands_case(binary, root):
    """Wording and discoverability: a healthy account is not called expired,
    :reconect suggests :reconnect, an unknown address is a sentence."""
    directory = root / "commands"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, EXPIRED)
    try:
        terminal.until(lambda: has(terminal, "Google sign-in expired · Ctrl+O Reconnect"), 20)
        command(terminal, "reconect")
        terminal.until(lambda: has(terminal, ":reconnect"))
        terminal.send(ESC)
        terminal.gap(.3)
        command(terminal, "reconnect nobody@example.com")
        terminal.until(lambda: has(terminal, "Not a configured account: nobody@example.com"))
        require(not has(terminal, "Reconnect Google sign-in"), "an unknown account opened the dialog")
        command(terminal, "reconnect personal@example.com")
        terminal.until(lambda: has(terminal, "[Reconnect · Enter]"))
        words = dialog(terminal)
        require("Account: personal@example.com" in words, "dialog shows another account")
        require("expired" not in words and "revoked" not in words, "a healthy account was described as expired")
        require("No refusal of this sign-in is recorded" in words, "neutral wording missing")
        terminal.send(ESC)
        terminal.until(lambda: not has(terminal, "Reconnect Google sign-in"))
        quit_tui(terminal)
        print("PASS reconnect commands: neutral healthy wording, :reconect suggestion, unknown address sentence")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    require(not consent.entries(), "wording checks opened consent")
    browser_never_ran(directory)


def sizes_case(binary, root):
    """Small terminals: the dialog fits, scrolls with j/k and always shows
    whole buttons; at 40x24 the footer keys stay visible."""
    directory = root / "sizes"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, EXPIRED, columns=40, rows=24)
    try:
        terminal.until(lambda: "work@example.com" in terminal.text(), 20)
        terminal.gap(1)
        terminal.send(CTRL_O)
        terminal.until(lambda: "Reconnect · Enter]" in terminal.text() or "[Reconnect]" in terminal.text())
        lines = terminal.screen.lines()
        require(any("Enter Reconnect" in line for line in lines[-2:]), "40x24 dialog covers the footer keys")
        require("[Cancel" in terminal.text() and "]" in terminal.text().split("[Cancel", 1)[1][:16], "40x24 Cancel button clipped")
        # Measured in cells, both full buttons fit one row at 40 columns.
        require(any("[Reconnect · Enter]" in line and "[Cancel · Esc]" in line for line in lines), "40x24 buttons stacked though they fit")
        resize(terminal, 32, 14)
        terminal.until(lambda: "[Reconnect]" in terminal.text() and "[Cancel]" in terminal.text())
        require("j More" in terminal.text(), "32x14 dialog does not offer scrolling")
        for _ in range(40):
            if "k Back" in terminal.text():
                break
            terminal.send(b"j")
            terminal.gap(.08)
        terminal.until(lambda: "changed in your mail." in dialog(terminal) and "k Back" in terminal.text())
        require("[Reconnect]" in terminal.text() and "[Cancel]" in terminal.text(), "32x14 buttons clipped after scrolling")
        resize(terminal, 120, 36)
        terminal.until(lambda: has(terminal, "[Reconnect · Enter]"))
        terminal.send(ESC)
        terminal.until(lambda: not has(terminal, "Reconnect Google sign-in"))
        quit_tui(terminal)
        print("PASS reconnect sizes: 40x24 keeps the footer, 32x14 scrolls with whole buttons")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    require(not consent.entries(), "size checks opened consent")


def calendar_case(binary, root):
    directory = root / "calendar"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, OTHER, columns=140, rows=38)
    try:
        terminal.until(lambda: has(terminal, OTHER), 20)
        terminal.send(b"C")
        terminal.until(lambda: has(terminal, "Calendar · "), 20)
        # Show every account's calendars: the expired account is named.
        terminal.until(lambda: has(terminal, "Up to date") or has(terminal, "Saved calendar"), 20)
        terminal.send(b"g")
        terminal.until(lambda: has(terminal, "Show calendars"))
        terminal.send(b"a")
        # Every account is listed first; the expired one is unavailable.
        terminal.until(lambda: has(terminal, "Some accounts unavailable"), 20)
        terminal.gap(.3)
        terminal.send(ENTER)
        terminal.until(lambda: has(terminal, "Not shown: work@example.com · Google sign-in expired · Ctrl+O Reconnect"), 20)
        terminal.send(CTRL_O)
        terminal.until(lambda: has(terminal, "Account: work@example.com") and has(terminal, "[Reconnect · Enter]"))
        require(has(terminal, "Enter Reconnect · Tab Choose"), "calendar footer does not name the dialog keys")
        require(not consent.entries(), "consent opened before an explicit Enter")
        terminal.send(ENTER)
        check_consent(consent.wait(1, terminal))
        terminal.until(lambda: not has(terminal, "Reconnect Google sign-in") and not has(terminal, "Not shown:"), 20)
        terminal.until(lambda: has(terminal, "Up to date"), 20)
        # The account's mail was refreshed after its calendars, in the background:
        # switching to it shows downloaded mail (account switches read the cache only).
        terminal.gap(1)
        terminal.send(b"q")
        terminal.until(lambda: has(terminal, "Accounts / mailboxes"), 20)
        terminal.send(b"2")
        terminal.until(lambda: has(terminal, "Synthetic work thread"), 20)
        require(not has(terminal, "Google sign-in expired"), "mail status still reports the expired sign-in")
        no_secrets(terminal, consent)
        quit_tui(terminal)
        print("PASS reconnect calendar: named account, Ctrl+O, consent, calendars and mail reloaded without restart")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    browser_never_ran(directory)


def finishing_case(binary, root):
    """After Google's callback the store never finishes (a FIFO stands in for
    a hung credential write): Esc and Enter wait, q arms quitting, and the
    commit's own bound ends it; the account is then checked with a refresh
    and the truth reported, never a consent text."""
    directory = root / "finishing"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, EXPIRED)
    try:
        terminal.until(lambda: has(terminal, "Google sign-in expired · Ctrl+O Reconnect"), 20)
        until_finishing(terminal, consent, directory, "hang")
        for key in (ESC, ENTER, b"\t"):
            terminal.send(key)
            terminal.gap(.3)
        require(has(terminal, "Reconnect Google sign-in") and has(terminal, "q twice quits anyway"), "finishing dialog closed on Esc/Enter")
        terminal.send(b"q")
        terminal.until(lambda: has(terminal, "q again quits anyway"))
        require(terminal.process.poll() is None, "one q quit while storing")
        started = time.monotonic()
        terminal.until(lambda: has(terminal, "Reconnected work@example.com · confirmed"), 45)
        elapsed = time.monotonic() - started
        require(elapsed < 40, f"the commit bound did not end the hung store ({elapsed:.1f}s)")
        for wrong in ("consent timed out", "Nothing was changed"):
            require(not has(terminal, wrong), f"a consent text after Google's callback: {wrong}")
        terminal.until(lambda: has(terminal, "Synthetic work thread"), 20)
        no_secrets(terminal, consent)
        quit_tui(terminal)
        print(f"PASS reconnect finishing: keys wait, q arms, a hung store ends after {elapsed:.0f}s and is checked with a refresh")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()
    browser_never_ran(directory)


def quit_case(binary, root):
    """While storing: q twice, SIGTERM and SIGHUP each quit promptly with the
    terminal restored, whatever the hung store does."""
    results = []
    for how in ("qq", signal.SIGTERM, signal.SIGHUP):
        name = how if isinstance(how, str) else how.name
        directory = root / f"quit-{name}"
        config = setup(directory)
        consent = Consent(directory)
        terminal = launch(binary, directory, config, consent.control, EXPIRED)
        try:
            terminal.until(lambda: has(terminal, "Google sign-in expired · Ctrl+O Reconnect"), 20)
            until_finishing(terminal, consent, directory, "hang")
            started = time.monotonic()
            if how == "qq":
                terminal.send(b"q")
                terminal.gap(.3)
                terminal.send(b"q")
            else:
                os.kill(terminal.process.pid, how)
            while terminal.process.poll() is None and time.monotonic() - started < 6:
                terminal.gap(.1)
            elapsed = time.monotonic() - started
            require(terminal.process.poll() is not None, f"{name} did not quit while storing")
            require(elapsed < 5, f"{name} took {elapsed:.1f}s to quit while storing")
            require(terminal.process.returncode == 0, f"{name} exit status {terminal.process.returncode}")
            require(termios.tcgetattr(terminal.slave) == terminal.settings, f"{name} did not restore the terminal")
            results.append(f"{name} {elapsed:.1f}s")
        except Exception:
            print(terminal.text(), file=sys.stderr)
            raise
        finally:
            terminal.close()
    print("PASS reconnect quit while storing: " + ", ".join(results) + ", terminal restored")


def store_failure_case(binary, root):
    """The durable write fails after Google's callback (the marker path is a
    directory): the dialog never says nothing changed; it checks the account
    with a refresh and reports that the renewed sign-in works."""
    directory = root / "store-failure"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, EXPIRED)
    try:
        terminal.until(lambda: has(terminal, "Google sign-in expired · Ctrl+O Reconnect"), 20)
        until_finishing(terminal, consent, directory, "fail")
        terminal.until(lambda: has(terminal, "Reconnected work@example.com · confirmed"), 20)
        for wrong in ("consent timed out", "Nothing was changed", "Not reconnected"):
            require(not has(terminal, wrong), f"store failure reported as: {wrong}")
        terminal.until(lambda: has(terminal, "Synthetic work thread"), 20)
        quit_tui(terminal)
        print("PASS reconnect store failure: checked with a refresh, reported as confirmed")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


def stale_case(binary, root):
    """Another process reconnects the account while this TUI still holds the
    refusal: the dialog no longer repeats Google's old reason."""
    directory = root / "stale"
    config = setup(directory)
    consent = Consent(directory)
    terminal = launch(binary, directory, config, consent.control, EXPIRED)
    try:
        terminal.until(lambda: has(terminal, "Google sign-in expired · Ctrl+O Reconnect"), 20)
        previous = os.environ.get("OMAGMA_TEST_CONSENT")
        os.environ["OMAGMA_TEST_CONSENT"] = str(consent.control)
        try:
            with Client(binary, directory, scenario="sign-in-expired", extra=("--config", str(config))) as client:
                status = client.request("auth.status", EXPIRED)
                renewed = client.request("auth.authorize", EXPIRED, capabilities=status["grant"]["capabilities"], reconnect=True, expectedGrantId=status["grant"]["grantId"])
                require(renewed["reconnected"] is True, "the other process did not reconnect")
        finally:
            if previous is None:
                os.environ.pop("OMAGMA_TEST_CONSENT", None)
            else:
                os.environ["OMAGMA_TEST_CONSENT"] = previous
        terminal.send(CTRL_O)
        terminal.until(lambda: has(terminal, "[Reconnect · Enter]"))
        words = dialog(terminal)
        require("re-authentication policy" not in words and "invalid_rapt" not in words, "an outdated refusal was repeated")
        require("another Omagma window" in words, "the vanished reason was not explained")
        terminal.send(ESC)
        terminal.until(lambda: not has(terminal, "Reconnect Google sign-in"))
        quit_tui(terminal)
        print("PASS reconnect stale: another process's reconnect outdates this TUI's refusal")
    except Exception:
        print(terminal.text(), file=sys.stderr)
        raise
    finally:
        terminal.close()


CASES = {"jsonl": jsonl_case, "mail": mail_case, "commands": commands_case, "sizes": sizes_case, "calendar": calendar_case,
         "finishing": finishing_case, "quit": quit_case, "store-failure": store_failure_case, "stale": stale_case}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=tuple(CASES), help="run only this case (repeatable)")
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "test binary absent")
    read_build_info(binary)
    with tempfile.TemporaryDirectory(prefix="omagma-reconnect-") as temporary:
        root = Path(temporary)
        for name in args.case or CASES:
            CASES[name](binary, root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
