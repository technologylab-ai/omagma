#!/usr/bin/env python3
"""Synthetic layout/theme/reader checks in owned PTYs; requires host lock."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import tempfile
import time
import tomllib

from build_info import build_mode, read_build_info
from terminal_cache import ProviderFixture, seed, contains_body, status_color, FETCH_COLOR, metrics
from terminal_integration import ACCOUNTS, ROOT, Client, require
from terminal_pty import Terminal, retained_draft
from terminal_status_screen import StatusScreen
from terminal_help import scroll_help_to

UI_FIXTURES = ROOT / "tests/fixtures/terminal/ui"
CASES = ("layout-responsive", "preferences-private-safety", "reader-cached-next-previous", "theme-reload-no-color", "search-back-stack")


def mailbox_visible(terminal):
    header = terminal.text().splitlines()[0]
    return terminal.screen.locate("Mail ·") is not None and "Cache search" not in header and "Gmail search" not in header


def pane_coordinates(terminal):
    return terminal.screen.locate("Mail ·"), (terminal.screen.locate("Thread / full body") or terminal.screen.locate("Message ·"))


def layout(terminal, expected):
    def ready():
        mail, reader = pane_coordinates(terminal)
        if mail is None or reader is None:
            return False
        nav_width = 26 if terminal.columns >= 120 else 0
        if mail != {"row": 2, "column": nav_width + 3}:
            return False
        if expected == "below":
            list_height = max(7, (terminal.rows - 4) * 40 // 100)
            return reader["row"] == mail["row"] + list_height and reader["column"] == mail["column"]
        return reader["row"] == mail["row"] and reader["column"] > mail["column"]
    terminal.until(ready)
    mail, reader = pane_coordinates(terminal)
    if expected == "right":
        # Border/title padding and the leading title space cancel in width.
        left = mail["column"] - 3
        available = terminal.columns - left
        list_width = reader["column"] - mail["column"]
        require(abs(list_width - available * .55) <= 2, "right layout did not allocate balanced55% list width")
    return {"layout": expected, "columns": terminal.columns, "rows": terminal.rows,
            "mailTitle": mail, "readerTitle": reader}


def start(binary, directory, fixture, extra=(), environment=None, columns=160, rows=40):
    return Terminal(binary, directory, extra=fixture.options(*extra),
                    environment={"COLORTERM": "truecolor", "NO_COLOR": None, **(environment or {})},
                    screen_type=StatusScreen, columns=columns, rows=rows)


def command(terminal, text):
    terminal.send(b":" + text.encode() + b"\r")


def signature(path):
    info = path.lstat()
    if stat.S_ISREG(info.st_mode):
        return ("file", stat.S_IMODE(info.st_mode), hashlib.sha256(path.read_bytes()).hexdigest())
    if stat.S_ISLNK(info.st_mode):
        return ("symlink", os.readlink(path))
    if stat.S_ISFIFO(info.st_mode):
        return ("fifo", stat.S_IMODE(info.st_mode))
    if stat.S_ISDIR(info.st_mode):
        return ("directory", stat.S_IMODE(info.st_mode))
    raise AssertionError("unexpected synthetic preference file kind")


def config_sentinel(directory):
    path = directory / "config/omagma/config.json"
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    shutil.copyfile(ROOT / "tests/fixtures/all-accounts.json", path)
    path.chmod(0o600)
    return path, signature(path)


def preference(path, expected):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600, "layout preferences not private regular0600")
    data = json.loads(path.read_text())
    require(isinstance(data, dict) and data.get("readerLayout") == expected and data.get("schema") == 1,
            "saved reader layout disagrees with rendered layout/schema")
    # Private working-context persistence now deliberately remembers account
    # and message IDs. It must remain bounded UI state, not mail or credentials.
    require(set(data) == {"schema", "readerLayout", "listWidthPercent", "listHeightPercent",
                          "lastAccount", "contexts", "bindings"}, "UI preferences contain undocumented fields")
    for field in ("listWidthPercent", "listHeightPercent"):
        require(type(data[field]) is int and 25 <= data[field] <= 75, "pane ratio exceeded its public bound")
    require(data["lastAccount"] in ("", *ACCOUNTS), "preferences retained an unconfigured account")
    contexts = data["contexts"]
    require(isinstance(contexts, list) and len(contexts) <= 3, "working contexts exceeded three accounts")
    seen = set()
    for context in contexts:
        require(set(context) == {"account", "folder", "label", "message", "selected", "readerScroll"},
                "working context contains mail/credential fields")
        require(context["account"] in ACCOUNTS and context["account"] not in seen,
                "working context crossed configured accounts or duplicated one")
        seen.add(context["account"])
        require(type(context["folder"]) is int and 0 <= context["folder"] < 8, "context folder is invalid")
        require(type(context["selected"]) is int and 0 <= context["selected"] < 10000, "context selection exceeded its bound")
        require(type(context["readerScroll"]) is int and 0 <= context["readerScroll"] <= 10000000, "context scroll exceeded its bound")
        for field in ("label", "message"):
            require(isinstance(context[field], str) and len(context[field].encode()) <= 256,
                    "working context text exceeded its bound")
    bindings = data["bindings"]
    require(isinstance(bindings, list) and len(bindings) <= 24, "key bindings exceeded their bound")
    for binding in bindings:
        require(set(binding) == {"key", "action"} and isinstance(binding["key"], str)
                and len(binding["key"].encode()) <= 24 and isinstance(binding["action"], str),
                "key binding contains undocumented/private fields")
    return data


def palette(path, key):
    value = tomllib.loads(path.read_text())[key]
    require(isinstance(value, str) and len(value) == 7 and value[0] == "#", "invalid synthetic palette oracle")
    return ("rgb", *[int(value[offset:offset + 2], 16) for offset in (1, 3, 5)])


def theme_path(directory, home_fallback=False):
    state = directory / "home/.local/state" if home_fallback else directory / "state"
    path = state / "omarchy/current/theme/colors.toml"
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    return path


def title_bold(terminal, text):
    position = terminal.screen.locate(text)
    return position is not None and terminal.screen.styles[position["row"]][position["column"]][2]


def quit_key(terminal):
    terminal.until(lambda: mailbox_visible(terminal) and any(
        hint in terminal.text().splitlines()[-2] for hint in ("q Quit", "Esc/q List")))
    if "Esc/q List" in terminal.text().splitlines()[-2]:
        terminal.send(b"q")
        terminal.until(lambda: "q Quit" in terminal.text().splitlines()[-2])
        require(terminal.process.poll() is None, "reader q skipped the restored list")
    require("q Quit" in terminal.text().splitlines()[-2], "quit oracle is not in default list focus")
    terminal.send(b"q")
    deadline = time.monotonic() + 5
    while terminal.process.poll() is None and time.monotonic() < deadline:
        terminal.pump(.02)
    require(terminal.process.poll() is not None, "q from default inbox did not quit")
    return terminal.finish(already_exited=True)


def search(terminal, source, query):
    key, prompt, title = (b"/", "Cache / ", "Cache search") if source == "cache" else (b"\\", "Gmail \\ ", "Gmail search")
    terminal.send(key)
    terminal.until(lambda: prompt in terminal.text())
    terminal.send(query.encode() + b"\r")
    terminal.until(lambda: title in terminal.text())
    # The header changes immediately while the previous cached body remains
    # readable. Drain that render boundary, then wait for this query's worker
    # to commit before testing navigation of its result window.
    terminal.gap(.08)
    terminal.until(lambda: title in terminal.screen.lines()[0] and terminal.screen.lines()[-1].strip() == "Ready")
    return title


def search_back(terminal):
    if "Esc/q List" in terminal.text().splitlines()[-2]:
        terminal.send(b"q")
        terminal.until(lambda: "q Clear" in terminal.text().splitlines()[-2])
        require(terminal.process.poll() is None, "reader Back exited instead of returning to the search list")
    require("q Clear" in terminal.text().splitlines()[-2], "query Back oracle is not in its search list")
    terminal.send(b"q")


def run_case(binary, directory, name):
    result = {}
    fixture = ProviderFixture(directory)
    if name == "reader-cached-next-previous":
        # Delivered header count96 used to break full reading. Keep its body
        # and identity unchanged so normal reader selection proves usability.
        source = fixture.data[ACCOUNTS[0]]["baseline"]
        message = next(m for m in source["messages"] if m["id"] == "shared-msg-095")
        original_count = len(message["payload"]["headers"])
        message["payload"]["headers"] += [{"name": f"X-Fictional-{i:03}", "value": "Synthetic delivered header"}
                                          for i in range(96 - original_count)]
        # A fitting body has no scroll range. Keep the full identity line and
        # add enough fictional lines to make j/k viewport movement observable.
        body = (f"Synthetic {ACCOUNTS[0]} message 095.\n" +
                "Synthetic reader scrolling line café 👋.\n" * 80).encode()
        message["payload"]["body"] = {"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")}
        fixture.stage(ACCOUNTS[0], "baseline")
        (fixture.root / "contacts").mkdir(mode=0o700)
        for account in ACCOUNTS:
            key = account.split("@")[0]
            shutil.copyfile(ROOT / "tests/fixtures/terminal/contacts" / f"{key}.json", fixture.root / "contacts" / f"{key}.json")
    seed(binary, directory, fixture)
    if name == "reader-cached-next-previous":
        with Client(binary, directory, extra=fixture.options()) as client:
            contacts = client.request("contacts.list")["contacts"]
            require(bool(contacts), "fictional contacts cache not seeded")
            contact_name = contacts[0]["name"]
    fixture.stage(ACCOUNTS[0], "baseline", held=True)
    terminal = None
    try:
        if name == "layout-responsive":
            terminal = start(binary, directory, fixture)
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            terminal.until(lambda: contains_body(terminal, 96))
            checks = [layout(terminal, "right")]
            mail, _ = pane_coordinates(terminal)
            subject = terminal.screen.locate("Synthetic personal thread 031")
            require(subject is not None and subject["row"] == mail["row"] + 1,
                    "message subject was not the first content row")
            sender = terminal.screen.locate("Fixture account")
            require(sender is not None and sender["row"] == subject["row"] + 1,
                    "sender/snippet was not the second content row")
            require(sender["column"] >= mail["column"] - 1, "sender row leaked into another pane")
            left, right = mail["column"] - 2, pane_coordinates(terminal)[1]["column"] - 4
            require(not "".join(terminal.screen.cells[subject["row"] + 2][left:right]).strip(),
                    "mail separator third row was not blank")
            terminal.send(b"v")
            checks.append(layout(terminal, "below"))
            for columns, rows in ((100, 30), (82, 24)):
                terminal.resize(columns, rows)
                checks.append(layout(terminal, "below"))
                terminal.until(lambda: contains_body(terminal, 96))
            terminal.resize(70, 20)
            checks.append(layout(terminal, "below"))
            # The narrow split need not fit all headers/body simultaneously;
            # expanded-reader access still exposes the same cached message.
            terminal.send(b"z")
            terminal.until(lambda: pane_coordinates(terminal)[0] is None and contains_body(terminal, 96))
            terminal.send(b"z")
            layout(terminal, "below")
            terminal.resize(100, 24)
            checks.append(layout(terminal, "below"))
            terminal.send(b"v")
            checks.append(layout(terminal, "right"))
            terminal.until(lambda: contains_body(terminal, 96))
            require(fixture.is_held(), "layout/resize test ran after remote completed")
            result.update(geometry=checks, subjectFirst=True, senderSnippetSecond=True, blankSeparator=True,
                          selectedBodyPreserved=True, wideGlyphAtRightEdge=terminal.screen.wide_right_edge)
            result.update(terminal.finish(signal_mode=signal.SIGTERM))
        elif name == "preferences-private-safety":
            preference_dir = directory / "private preferences"
            preference_dir.mkdir(mode=0o700)
            path = preference_dir / "ui.json"
            cfg, cfg_signature = config_sentinel(directory)
            terminal = start(binary, directory, fixture, extra=("--ui-file", str(path)))
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            layout(terminal, "right")
            command(terminal, "layout below")
            layout(terminal, "below")
            preference(path, "below")
            terminal.finish(signal_mode=signal.SIGTERM)
            terminal.close()
            terminal = None
            fixture.stage(ACCOUNTS[0], "baseline", held=True)
            terminal = start(binary, directory, fixture, extra=("--ui-file", str(path)))
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            layout(terminal, "below")
            command(terminal, "layout right")
            layout(terminal, "right")
            preference(path, "right")
            terminal.finish(signal_mode=signal.SIGTERM)
            terminal.close()
            terminal = None
            require(signature(cfg) == cfg_signature, "layout persistence changed account configuration")
            refused = []
            for kind in ("malformed", "public-mode", "symlink", "fifo", "directory"):
                owned = directory / kind
                owned.mkdir(mode=0o700)
                alternate = ProviderFixture(owned)
                seed(binary, owned, alternate)
                alternate.stage(ACCOUNTS[0], "baseline", held=True)
                bad = owned / "ui.json"
                target = owned / "target.json"
                if kind == "malformed":
                    bad.write_text("this is not JSON\n")
                    bad.chmod(0o600)
                elif kind == "public-mode":
                    shutil.copyfile(path, bad)
                    bad.chmod(0o644)
                elif kind == "symlink":
                    shutil.copyfile(path, target)
                    target.chmod(0o600)
                    bad.symlink_to(target)
                elif kind == "fifo":
                    os.mkfifo(bad, 0o600)
                else:
                    bad.mkdir(mode=0o700)
                before = signature(bad)
                target_before = signature(target) if target.exists() else None
                began = time.monotonic()
                terminal = start(binary, owned, alternate, extra=("--ui-file", str(bad)))
                alternate.wait_entered(terminal.process, pump=terminal.pump)
                layout(terminal, "right")
                terminal.until(lambda: contains_body(terminal, 96))
                require("UI prefs fallback" in terminal.text(), "invalid preferences did not retain startup fallback warning")
                require(time.monotonic() - began < 3, "preference refusal blocked cache-first startup")
                terminal.send(b"v")
                terminal.until(lambda: "preference not saved" in terminal.text())
                require(signature(bad) == before, "invalid preferences were blindly overwritten")
                if target_before is not None:
                    require(signature(target) == target_before, "preferences followed/modified symlink target")
                terminal.finish(signal_mode=signal.SIGTERM)
                terminal.close()
                terminal = None
                refused.append({"kind": kind, "startupFallback": "right", "originalUnchanged": True})
            result.update(privateMode="0600", restartRestored="below", accountConfigUnchanged=True,
                          explicitUiFileSeparate=True, preferenceRefusals=refused)
        elif name == "reader-cached-next-previous":
            terminal = start(binary, directory, fixture)
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.send(b"l")
            terminal.gap()
            terminal.send(b"J")
            terminal.until(lambda: contains_body(terminal, 95))
            needle = f"Synthetic {ACCOUNTS[0]} message 095."
            before = terminal.screen.locate(needle)
            require(before is not None, "reader navigation body oracle not rendered")
            terminal.send(b"j")
            terminal.until(lambda: terminal.screen.locate(needle) is not None and terminal.screen.locate(needle)["row"] == before["row"] - 1)
            require(contains_body(terminal, 95), "lowercase body scroll selected another mail")
            terminal.send(b"k")
            terminal.until(lambda: terminal.screen.locate(needle) == before)
            terminal.send(b"K")
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.send(b"z")
            terminal.until(lambda: pane_coordinates(terminal)[0] is None and contains_body(terminal, 96))
            terminal.send(b"J")
            terminal.until(lambda: contains_body(terminal, 95))
            terminal.send(b"K")
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.send(b"]")
            terminal.until(lambda: contains_body(terminal, 64))
            terminal.send(b"[")
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.send(b"z")
            layout(terminal, "right")
            terminal.send(b"a")
            terminal.until(lambda: "Contacts" in terminal.text() and contact_name in terminal.text())
            require(fixture.is_held(), "contacts opened only after refresh completed")
            terminal.send(b"?")
            scroll_help_to(terminal, "Click · wheel")
            scroll_help_to(terminal, "No editor save or paste sends mail.")
            terminal.send(b"\x1b")
            terminal.gap()
            terminal.until(lambda: "Contacts" in terminal.text() and contact_name in terminal.text())
            terminal.send(b"\x1b")
            terminal.gap()
            terminal.until(lambda: contains_body(terminal, 96))
            search(terminal, "cache", "subject:Synthetic personal thread 031")
            terminal.until(lambda: "Synthetic personal thread 031" in terminal.text() and "Synthetic personal thread 030" not in terminal.text())
            terminal.send(b"q")
            terminal.until(lambda: "Synthetic personal thread 030" in terminal.text())
            require(terminal.process.poll() is None, "q quit rather than returning from active search")
            require(fixture.is_held(), "cached next/previous/page test completed after remote")
            terminal.until(lambda: "Esc/q List" in terminal.text() and contains_body(terminal, 96))
            terminal.send(b"q")
            terminal.until(lambda: "q Quit" in terminal.text())
            require(terminal.process.poll() is None, "q from restored reader skipped the list")
            result.update(nextPreviousBodiesBeforeRemote=True, lowercaseScrollPreservedMessage=True,
                          expandedNextPrevious=True, existingPageKeysPreserved=True, deliveredHeadersPreviewed=96,
                          contactsOpenedBeforeRemote=True, contactsHelpAndEscapeUsable=True, queryQReturnedToInbox=True,
                          searchRestoredReaderFocus=True, readerQReturnedToList=True)
            result.update(quit_key(terminal), defaultInboxQQuit=True)
            terminal.close()
            terminal = None
            with Client(binary, directory, extra=fixture.options()) as client:
                current_contacts = client.request("contacts.list", cacheOnly=True)["contacts"]
                require({item["resourceName"]: item for item in current_contacts} ==
                        {item["resourceName"]: item for item in contacts}, "contacts navigation/help changed cached contacts")
            denied = directory / "denied-contacts"
            denied.mkdir(mode=0o700)
            denied_fixture = ProviderFixture(denied)
            seed(binary, denied, denied_fixture)
            denied_fixture.stage(ACCOUNTS[0], "baseline", held=True)
            terminal = start(binary, denied, denied_fixture, extra=("--fixture-scenario", "readonly"))
            denied_fixture.wait_entered(terminal.process, pump=terminal.pump)
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.send(b"a")
            terminal.until(lambda: "Contacts" in terminal.text() and "Contacts permission required" in terminal.text())
            require(denied_fixture.is_held(), "scope denial waited for held refresh")
            terminal.send(b"\x1b")
            terminal.gap()
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.finish(signal_mode=signal.SIGTERM)
            result.update(deniedContactsPaneStillOpened=True, contactsMutationRequests=0)
        elif name == "theme-reload-no-color":
            theme = theme_path(directory)
            shutil.copyfile(UI_FIXTURES / "theme-colors.toml", theme)
            terminal = start(binary, directory, fixture)
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            first = palette(UI_FIXTURES / "theme-colors.toml", "cyan")
            status_color(terminal, "Refreshing cached mail", first)
            shutil.copyfile(UI_FIXTURES / "theme-colors-reloaded.toml", theme)
            terminal.send(b"\x0c")
            reloaded = palette(UI_FIXTURES / "theme-colors-reloaded.toml", "cyan")
            terminal.until(lambda: terminal.screen.foregrounds("Refreshing cached mail") == {reloaded})
            theme.write_text('foreground = "not-a-color"\ncyan = "invalid"\n')
            terminal.send(b"\x0c")
            terminal.until(lambda: terminal.screen.foregrounds("Refreshing cached mail") == {FETCH_COLOR})
            theme.unlink()
            terminal.send(b"\x0c")
            status_color(terminal, "Refreshing cached mail", FETCH_COLOR)
            require(fixture.is_held(), "theme reload test completed after remote")
            terminal.finish(signal_mode=signal.SIGTERM)
            terminal.close()
            terminal = None
            # Exercise the HOME fallback without inheriting a real STATE path.
            fallback_theme = theme_path(directory, home_fallback=True)
            shutil.copyfile(UI_FIXTURES / "theme-colors.toml", fallback_theme)
            fixture.stage(ACCOUNTS[0], "baseline", held=True)
            terminal = start(binary, directory, fixture, environment={"XDG_STATE_HOME": None})
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            status_color(terminal, "Refreshing cached mail", first)
            terminal.finish(signal_mode=signal.SIGTERM)
            terminal.close()
            terminal = None
            fixture.stage(ACCOUNTS[0], "baseline", held=True)
            terminal = start(binary, directory, fixture, environment={"NO_COLOR": "1", "XDG_STATE_HOME": None})
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            status_color(terminal, "Refreshing cached mail", None)
            terminal.until(lambda: contains_body(terminal, 96))
            result.update(customPaletteForeground=list(first), reloadedForeground=list(reloaded),
                          invalidAndMissingThemeFallback=list(FETCH_COLOR), noColorStatusRetained=True,
                          xdgStateAndHomeFallbackPaths=True,
                          actualThemeOrConfigEdited=False)
            result.update(terminal.finish(signal_mode=signal.SIGTERM))
        elif name == "search-back-stack":
            with Client(binary, directory, extra=fixture.options()) as client:
                before = metrics(client)
            terminal = start(binary, directory, fixture)
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.ui_stage = "reader-focus"
            terminal.send(b"l")
            terminal.until(lambda: title_bold(terminal, "Thread / full body") or title_bold(terminal, "Message ·"))
            terminal.send(b"q")
            terminal.until(lambda: title_bold(terminal, "Mail ·"))
            require(terminal.process.poll() is None and fixture.is_held(), "reader Back quit or awaited remote")
            terminal.send(b"l")
            terminal.gap()
            terminal.send(b"z")
            terminal.until(lambda: pane_coordinates(terminal)[0] is None)
            terminal.send(b"q")
            layout(terminal, "right")
            require(terminal.process.poll() is None, "expanded reader Back quit")
            terminal.ui_stage = "cache-search"
            search(terminal, "cache", "subject:Synthetic personal")
            terminal.until(lambda: contains_body(terminal, 96))
            terminal.ui_stage = "next-window"
            terminal.send(b"]")
            terminal.until(lambda: contains_body(terminal, 64))
            terminal.ui_stage = "previous-window"
            terminal.send(b"[")
            terminal.until(lambda: contains_body(terminal, 96))
            with Client(binary, directory, extra=fixture.options()) as client:
                after = metrics(client)
            for key in ("fixtureCalls", "syncCalls", "syncListCalls", "syncMetadataGets", "syncBodyGets"):
                require(after[key] == before[key], "cache search/page invoked provider while remote held")
            terminal.ui_stage = "query-back"
            search_back(terminal)
            terminal.until(lambda: mailbox_visible(terminal) and "Cache search" not in terminal.screen.lines()[0])
            require(fixture.is_held() and terminal.process.poll() is None, "cache-search Back did not stay interactive")
            terminal.ui_stage = "help"
            terminal.send(b"?")
            scroll_help_to(terminal, "Click · wheel")
            scroll_help_to(terminal, "No editor save or paste sends mail.")
            terminal.send(b"q")
            terminal.until(lambda: mailbox_visible(terminal) and "No editor save or paste sends mail." not in terminal.text())
            terminal.ui_stage = "default-quit"
            result.update(quit_key(terminal))
            terminal.close()
            terminal = None
            fixture.stage(ACCOUNTS[0], "baseline")
            terminal = start(binary, directory, fixture)
            terminal.until(lambda: "Up to date" in terminal.text() and contains_body(terminal, 96))
            # Mail33 is outside the retained newest40; it cannot appear by
            # merely relabeling a cache-only result as a Gmail search.
            terminal.ui_stage = "server-old-mail"
            search(terminal, "server", "subject:Synthetic personal thread 010")
            terminal.until(lambda: contains_body(terminal, 33))
            terminal.ui_stage = "query-back"
            search_back(terminal)
            terminal.until(lambda: mailbox_visible(terminal) and contains_body(terminal, 96))
            terminal.ui_stage = "server-paging"
            search(terminal, "server", "subject:Synthetic personal")
            terminal.until(lambda: contains_body(terminal, 96) and "Ready" in terminal.text())
            terminal.gap(.2)  # Separate observed render/input boundaries.
            terminal.ui_stage = "next-window"
            terminal.send(b"]")
            terminal.until(lambda: contains_body(terminal, 64))
            terminal.send(b"]")
            terminal.until(lambda: contains_body(terminal, 32))
            terminal.ui_stage = "query-back"
            search_back(terminal)
            terminal.until(lambda: mailbox_visible(terminal) and contains_body(terminal, 96))
            terminal.ui_stage = "compose-back"
            terminal.send(b"c")
            terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text())
            terminal.send(b"\t\t\t\tiq")
            terminal.send(b"\x1b")
            terminal.gap()
            terminal.send(b"q")
            terminal.until(lambda: mailbox_visible(terminal))
            require(terminal.process.poll() is None, "normal composer q quit rather than saving/back")
            result.update(retained_draft(terminal, "q"))
            result.update(quit_key(terminal), readerQReturnedToList=True, expandedQShrank=True,
                          cacheSearchProviderCalls=0, cacheSearchPageRetainedSubset=True,
                          gmailSearchReachedOlderUncachedMail=True, gmailSearchPagedBeyondCache=True,
                          queryAndHelpQBack=True, composerInsertQLiteral=True, composerNormalQSavedBack=True)
        else:
            raise AssertionError("unknown UI case")
    except Exception as error:
        if terminal is not None:
            error.ui_diagnostic = {"stage": getattr(terminal, "ui_stage", name), "currentCells": terminal.text().splitlines(), "outputBytes": terminal.output_total,
                                   "exitCode": terminal.process.poll(),
                                   "escapedSyntheticOutputTail": bytes(terminal.output[-262144:]).decode("utf-8", errors="replace")}
        raise
    finally:
        if terminal is not None:
            terminal.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    require(not args.output.exists(), "refusing to overwrite previous UI qualification receipt")
    info = read_build_info(args.binary, args.build_mode)
    report = {**info, "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "syntheticOnly": True, "desktopUsed": False, "actualThemeOrConfigEdited": False, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-ui-fixture-") as temporary:
        for name in (args.case,) if args.case else CASES:
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            started = time.monotonic()
            item = {"name": name}
            try:
                item.update(run_case(args.binary, directory, name), passed=True)
            except Exception as error:
                item.update(passed=False, error=f"{type(error).__name__}: {error}")
                if hasattr(error, "ui_diagnostic"): item.update(error.ui_diagnostic)
            item["elapsedSeconds"] = round(time.monotonic() - started, 4)
            report["cases"].append(item)
            print(json.dumps({key: value for key, value in item.items() if key != "escapedSyntheticOutputTail"}), flush=True)
            if not item["passed"]:
                break
    report["passed"] = len(report["cases"]) == (1 if args.case else len(CASES)) and all(item["passed"] for item in report["cases"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
